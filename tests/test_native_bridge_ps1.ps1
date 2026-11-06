# tests/test_native_bridge_ps1.ps1 - the PowerShell half of the hand-off seam:
# native-bridge-install.ps1 downloads the pinned native bridge through a mock
# /api/v1/hooks/download, verifies it against the pin and installs it under the bridge dir;
# Invoke-RogueNativeHandoff then hands it the event with stdin, stdout, stderr and the exit code
# passed through. A stub stands in for the binary (a C# console app on Windows, a shell script
# elsewhere), so this runs under pwsh on any OS and under Windows PowerShell 5.1.
#
#   pwsh -NoProfile -File tests/test_native_bridge_ps1.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$script:fails = 0
function Check {
    param([string]$Label, $Expected, $Actual)
    if ($Expected -ceq $Actual) { Write-Host "  ok: $Label" }
    else { Write-Host "FAIL: $Label (expected [$Expected], got [$Actual])"; $script:fails++ }
}
function Contains {
    param([string]$Label, [string]$Needle, [string]$Haystack)
    if ($Haystack -and $Haystack.Contains($Needle)) { Write-Host "  ok: $Label" }
    else { Write-Host "FAIL: $Label ([$Needle] not in [$Haystack])"; $script:fails++ }
}

$onWindows = -not ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows)
$shell = if ($PSVersionTable.PSVersion.Major -ge 6) { 'pwsh' } else { 'powershell' }
$exe = if ($onWindows) { 'rogue-hook.exe' } else { 'rogue-hook' }
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('rogue-native-' + [guid]::NewGuid().ToString('N'))
$plugin = Join-Path $work 'plugin'
$srv = Join-Path $work 'srv'
$sbHome = Join-Path $work 'home'
$binDir = Join-Path (Join-Path (Join-Path $sbHome '.rogue') 'bin') 'rogue-hook'
New-Item -ItemType Directory -Force -Path $srv, $sbHome | Out-Null
Copy-Item -Recurse -LiteralPath (Join-Path $repo 'plugins/rogue') -Destination $plugin
Remove-Item -LiteralPath (Join-Path $plugin 'rogue-hook.json') -ErrorAction SilentlyContinue
$port = Get-Random -Minimum 30000 -Maximum 40000
$python = if ($onWindows) { 'python' } else { 'python3' }
$server = Start-Process $python -ArgumentList @((Join-Path $repo 'tests/native_bridge_server.py'), $port, $srv) -PassThru
Start-Sleep -Milliseconds 800
[IO.File]::WriteAllText((Join-Path $sbHome '.rogue-env'), "export ROGUE_API_KEY=test-key`nexport ROGUE_BASE_URL=http://127.0.0.1:$port`n")
if (-not $onWindows) { & chmod 600 (Join-Path $sbHome '.rogue-env') }

# The stub answers --version, echoes its arguments, ROGUE_PLUGIN_ROOT and stdin, writes "err" to
# stderr and exits 2 when the first argument is "kiro" (the one family that denies by exit code).
function New-Stub {
    param([string]$Version)
    $blob = Join-Path $srv 'blob'
    if ($onWindows) {
        $src = @"
using System; using System.IO; using System.Text;
public static class Stub {
    public static int Main(string[] a) {
        if (a.Length > 0 && a[0] == "--version") { Console.Out.Write("rogue-hook $Version\n"); return 0; }
        var input = new MemoryStream(); Console.OpenStandardInput().CopyTo(input);
        var o = Console.OpenStandardOutput();
        var head = Encoding.UTF8.GetBytes("{\"native\":\"" + string.Join(" ", a) + " root=" + Environment.GetEnvironmentVariable("ROGUE_PLUGIN_ROOT").Replace("\\", "/") + "\",\"stdin\":");
        o.Write(head, 0, head.Length); var b = input.ToArray(); o.Write(b, 0, b.Length); o.WriteByte(125); o.Flush();
        if (a.Length > 0 && a[0] == "kiro") { Console.Error.Write("err"); return 2; }
        return 0;
    }
}
"@
        $out = Join-Path $work "stub-$Version.exe"
        Add-Type -TypeDefinition $src -OutputAssembly $out -OutputType ConsoleApplication
        Copy-Item -LiteralPath $out -Destination $blob -Force
    } else {
        $sh = "#!/bin/sh`n[ `"`$1`" = --version ] && { echo `"rogue-hook $Version`"; exit 0; }`n" +
            "printf '{`"native`":`"%s %s root=%s`",`"stdin`":%s}' `"`$1`" `"`$2`" `"`$ROGUE_PLUGIN_ROOT`" `"`$(cat)`"`n" +
            "[ `"`$1`" = kiro ] && { printf err >&2; exit 2; }`nexit 0`n"
        [IO.File]::WriteAllText($blob, $sh)
    }
}
function Get-Sha { param([string]$Path) (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() }
function Set-Pin {
    param([string]$Version, [string]$Sha)
    $platforms = @('windows-amd64', 'windows-arm64', 'darwin-universal', 'linux-amd64', 'linux-arm64')
    $pairs = ($platforms | ForEach-Object { "    `"$_`": `"$Sha`"" }) -join ",`n"
    [IO.File]::WriteAllText((Join-Path $plugin 'rogue-hook.json'), "{`n  `"version`": `"$Version`",`n  `"sha256`": {`n$pairs`n  }`n}`n")
}

# Runs PowerShell code in a fresh process with the sandbox HOME; returns stdout, stderr and exit code.
function Invoke-Fresh {
    param([string]$Code, [string]$Stdin = '', [hashtable]$Env = @{})
    $psi = New-Object System.Diagnostics.ProcessStartInfo $shell, ('-NoProfile -NonInteractive -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Code)))
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables['HOME'] = $sbHome
    $psi.EnvironmentVariables['USERPROFILE'] = $sbHome
    foreach ($k in 'ROGUE_NATIVE_BRIDGE_DIR', 'ROGUE_NATIVE_BRIDGE', 'ROGUE_NATIVE_BRIDGE_CLAUDE', 'ROGUE_HOOK_SOURCE', 'ROGUE_API_KEY', 'ROGUE_BASE_URL') {
        $psi.EnvironmentVariables.Remove($k)
    }
    $psi.EnvironmentVariables['ROGUE_NATIVE_BRIDGE_RETRY'] = '0'
    foreach ($k in $Env.Keys) { $psi.EnvironmentVariables[$k] = $Env[$k] }
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Write($Stdin); $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return @{ Out = $out; Err = $err; Code = $p.ExitCode }
}
$lib = (Join-Path $plugin 'scripts/native-bridge.ps1').Replace("'", "''")
function Invoke-Handoff {
    param([string[]]$Arguments, [string]$Stdin = '', [hashtable]$Env = @{}, [string]$Settings = '@{}', [string]$Root = $plugin)
    $argList = ($Arguments | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ','
    $code = ". ([scriptblock]::Create((Get-Content -Raw -LiteralPath '$lib'))); " +
        "Invoke-RogueNativeHandoff -Root '$($Root.Replace("'", "''"))' -Family $($Arguments[0]) -Arguments @($argList) -Settings $Settings -BudgetMs 10000 -FailOpen '{}'; " +
        "[Console]::Out.Write('kept')"
    Invoke-Fresh -Code $code -Stdin $Stdin -Env $Env
}
function Invoke-Install {
    $installer = (Join-Path $plugin 'scripts/native-bridge-install.ps1').Replace("'", "''")
    [IO.File]::WriteAllText((Join-Path $srv 'requests'), '')
    Invoke-Fresh -Code "& ([scriptblock]::Create((Get-Content -Raw -LiteralPath '$installer'))) '$($plugin.Replace("'", "''"))'" | Out-Null
}
function Get-Installed { param([string]$Version) Test-Path -LiteralPath (Join-Path (Join-Path $binDir $Version) $exe) -PathType Leaf }
function Get-Log { $p = Join-Path (Join-Path $sbHome '.rogue') 'hook-binary.log'; if (Test-Path $p) { Get-Content -Raw $p } else { '' } }

try {
    Write-Host 'no pin: the script keeps the event, nothing is downloaded'
    New-Stub '0.1.0'
    Check 'kept' 'kept' (Invoke-Handoff @('claude', 'PreToolUse') '{}').Out
    Invoke-Install
    Check 'no request' '' ([IO.File]::ReadAllText((Join-Path $srv 'requests')))

    Write-Host 'pin, binary missing: kept, and the detached download installs it'
    Set-Pin '0.1.0' (Get-Sha (Join-Path $srv 'blob'))
    Check 'kept while missing' 'kept' (Invoke-Handoff @('claude', 'PreToolUse') '{}').Out
    foreach ($i in 1..100) { if (Get-Installed '0.1.0') { break }; Start-Sleep -Milliseconds 100 }
    Check 'installed' $true (Get-Installed '0.1.0')
    Contains 'log reports install' 'rogue-hook 0.1.0: installed' (Get-Log)
    Contains 'lookup carries version' '/api/v1/hooks/download?version=0.1.0&os=' (Get-Content -Raw (Join-Path $srv 'requests'))
    Contains 'lookup carries the API key' 'key=test-key' (Get-Content -Raw (Join-Path $srv 'requests'))

    Write-Host 'binary present: stdin, stdout and the plugin root go through untouched'
    $r = Invoke-Handoff @('claude', 'PreToolUse') '{"tool_name":"Bash","s":"hello"}'
    $root = $plugin.Replace('\', '/')
    Check 'native answer relayed' "{`"native`":`"claude PreToolUse root=$root`",`"stdin`":{`"tool_name`":`"Bash`",`"s`":`"hello`"}}" $r.Out
    Check 'exit 0' 0 $r.Code
    $r = Invoke-Handoff @('kiro', 'PreToolUse') '{}'
    Check 'exit code relayed' 2 $r.Code
    Check 'stderr relayed' 'err' $r.Err
    Check 'managed never hands off' 'kept' (Invoke-Handoff @('claude', 'PreToolUse') '{}' @{ ROGUE_HOOK_SOURCE = 'managed' }).Out
    Check 'ROGUE_NATIVE_BRIDGE=0 keeps the script' 'kept' (Invoke-Handoff @('claude', 'PreToolUse') '{}' @{ ROGUE_NATIVE_BRIDGE = '0' }).Out
    Check 'the family switch from the env file keeps the script' 'kept' (Invoke-Handoff @('claude', 'PreToolUse') '{}' @{} "@{ ROGUE_NATIVE_BRIDGE_CLAUDE = '0' }").Out
    Check 'a relative root never hands off' 'kept' (Invoke-Handoff @('claude', 'PreToolUse') '{}' @{} '@{}' 'plugin').Out

    Write-Host 'a download that does not match the pin is never installed'
    New-Stub '0.2.0'
    Set-Pin '0.2.0' ('0' * 64)
    Invoke-Install
    Check 'no binary' $false (Get-Installed '0.2.0')
    Contains 'log reports mismatch' 'sha256 mismatch' (Get-Log)

    Write-Host 'a binary that reports another version is not installed'
    Set-Pin '0.3.0' (Get-Sha (Join-Path $srv 'blob'))
    Invoke-Install
    Check 'no binary' $false (Get-Installed '0.3.0')
    Contains 'log reports it' 'does not run here' (Get-Log)
} finally {
    if ($server) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
}
if ($script:fails -gt 0) { Write-Host "FAIL: $($script:fails) check(s)"; exit 1 }
Write-Host 'OK: native bridge hand-off and install (PowerShell)'
