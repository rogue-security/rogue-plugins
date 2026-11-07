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
$python = if ($onWindows) { 'python' } else { 'python3' }
# The mock picks a free port and reports it once listening.
$server = Start-Process $python -ArgumentList @((Join-Path $repo 'tests/native_bridge_server.py'), 0, $srv) -PassThru
$portFile = Join-Path $srv 'port'
foreach ($i in 1..100) { if ((Test-Path -LiteralPath $portFile) -or $server.HasExited) { break }; Start-Sleep -Milliseconds 100 }
if (-not (Test-Path -LiteralPath $portFile)) {
    if ($server.HasExited) { Write-Host "FAIL: mock server exited (code $($server.ExitCode)) before reporting its port" }
    else { Write-Host 'FAIL: mock server did not report its port within 10s' }
    if (-not $server.HasExited) { Stop-Process -Id $server.Id -Force }
    Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
    exit 1
}
$port = [IO.File]::ReadAllText($portFile).Trim()
[IO.File]::WriteAllText((Join-Path $sbHome '.rogue-env'), "export ROGUE_API_KEY=test-key`nexport ROGUE_BASE_URL=http://127.0.0.1:$port`n")
if (-not $onWindows) { & chmod 600 (Join-Path $sbHome '.rogue-env') }

# The stub answers --version (never, with STUB_HANG), echoes its arguments, ROGUE_PLUGIN_ROOT and
# stdin, writes "err" to stderr and exits 2 when the first argument is "kiro" (the one family that
# denies by exit code). With STUB_SLEEP=<s> it first writes half an answer and sleeps.
function New-Stub {
    param([string]$Version)
    $blob = Join-Path $srv 'blob'
    if ($onWindows) {
        $src = @"
using System; using System.IO; using System.Text;
public static class Stub {
    public static int Main(string[] a) {
        if (a.Length > 0 && a[0] == "--version") {
            if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("STUB_HANG"))) System.Threading.Thread.Sleep(30000);
            Console.Out.Write("rogue-hook $Version\n"); return 0;
        }
        var input = new MemoryStream(); Console.OpenStandardInput().CopyTo(input);
        var o = Console.OpenStandardOutput();
        var nap = Environment.GetEnvironmentVariable("STUB_SLEEP");
        if (!string.IsNullOrEmpty(nap)) {
            var part = Encoding.UTF8.GetBytes("{\"partial\":"); o.Write(part, 0, part.Length); o.Flush();
            System.Threading.Thread.Sleep(int.Parse(nap) * 1000);
        }
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
        $sh = "#!/bin/sh`n[ `"`$1`" = --version ] && [ -n `"`$STUB_HANG`" ] && exec sleep 30`n" +
            "[ `"`$1`" = --version ] && { echo `"rogue-hook $Version`"; exit 0; }`n" +
            "[ -n `"`$STUB_SLEEP`" ] && { printf '{`"partial`":'; sleep `"`$STUB_SLEEP`"; }`n" +
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
    # As in the hooks: otherwise Windows PowerShell writes module-loading progress to the redirected stderr.
    $Code = "`$ProgressPreference = 'SilentlyContinue'; " + $Code
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
function Invoke-Handoff {
    param([string[]]$Arguments, [string]$Stdin = '', [hashtable]$Env = @{}, [string]$Settings = '@{}', [string]$Root = $plugin, [int]$BudgetMs = 10000)
    $argList = ($Arguments | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ','
    $lib = (Join-Path $Root 'scripts/native-bridge.ps1').Replace("'", "''")
    $code = ". ([scriptblock]::Create((Get-Content -Raw -LiteralPath '$lib'))); " +
        "Invoke-RogueNativeHandoff -Root '$($Root.Replace("'", "''"))' -Family $($Arguments[0]) -Arguments @($argList) -Settings $Settings -BudgetMs $BudgetMs -FailOpen '{}'; " +
        "[Console]::Out.Write('kept')"
    Invoke-Fresh -Code $code -Stdin $Stdin -Env $Env
}
function Invoke-Install {
    param([hashtable]$Env = @{})
    $installer = (Join-Path $plugin 'scripts/native-bridge-install.ps1').Replace("'", "''")
    [IO.File]::WriteAllText((Join-Path $srv 'requests'), '')
    Invoke-Fresh -Code "& ([scriptblock]::Create((Get-Content -Raw -LiteralPath '$installer'))) '$($plugin.Replace("'", "''"))'" -Env $Env | Out-Null
}
function Get-Installed { param([string]$Version, [string]$Dir = $binDir) Test-Path -LiteralPath (Join-Path (Join-Path $Dir $Version) $exe) -PathType Leaf }
# Lets every identity write $Path (Everyone on Windows, group and other elsewhere), or restores it.
function Set-Exposed {
    param([string]$Path, [bool]$On)
    if (-not $onWindows) { & chmod $(if ($On) { 'go+w' } else { 'go-w' }) $Path; return }
    $acl = Get-Acl -LiteralPath $Path
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule ((New-Object System.Security.Principal.SecurityIdentifier 'S-1-1-0'), 'Write', 'Allow')
    if ($On) { $acl.AddAccessRule($rule) } else { [void]$acl.RemoveAccessRule($rule) }
    Set-Acl -LiteralPath $Path -AclObject $acl
}
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
    # The log line follows the rename, so wait for both.
    foreach ($i in 1..100) { if ((Get-Installed '0.1.0') -and (Get-Log).Contains('installed')) { break }; Start-Sleep -Milliseconds 100 }
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

    Write-Host 'a child that outlives the budget: only the fail-open answer is written'
    $r = Invoke-Handoff @('claude', 'PreToolUse') '{}' @{ STUB_SLEEP = '5' } -BudgetMs 1500
    Check 'fail-open answer alone' '{}' $r.Out
    Check 'exit 0' 0 $r.Code

    Write-Host 'ROGUE_NATIVE_BRIDGE_DIR from the env file in use'
    $empty = Join-Path $work 'empty'
    New-Item -ItemType Directory -Force -Path $empty | Out-Null
    $r = Invoke-Handoff @('claude', 'PreToolUse') '{}' @{ HOME = $empty; USERPROFILE = $empty } "@{ ROGUE_NATIVE_BRIDGE_DIR = '$($binDir.Replace("'", "''"))' }"
    Check 'the hand-off finds the binary there' "{`"native`":`"claude PreToolUse root=$root`",`"stdin`":{}}" $r.Out
    $altHome = Join-Path $work 'alt-home'
    $altDir = Join-Path $work 'alt-bin'
    New-Item -ItemType Directory -Force -Path $altHome | Out-Null
    [IO.File]::WriteAllText((Join-Path $altHome '.rogue-env'), "export ROGUE_API_KEY=test-key`nexport ROGUE_BASE_URL=http://127.0.0.1:$port`nexport ROGUE_NATIVE_BRIDGE_DIR=$altDir`n")
    if (-not $onWindows) { & chmod 600 (Join-Path $altHome '.rogue-env') }
    Invoke-Install @{ HOME = $altHome; USERPROFILE = $altHome }
    Check 'the installer installs there' $true (Get-Installed '0.1.0' $altDir)

    Write-Host 'a binary another user could replace never runs'
    $bin = Join-Path (Join-Path $binDir '0.1.0') $exe
    Set-Exposed $bin $true
    Check 'exposed binary keeps the script' 'kept' (Invoke-Handoff @('claude', 'PreToolUse') '{}').Out
    Set-Exposed $bin $false
    if (-not $onWindows) {
        Set-Exposed (Split-Path -Parent $bin) $true
        Check 'exposed directory keeps the script' 'kept' (Invoke-Handoff @('claude', 'PreToolUse') '{}').Out
        Set-Exposed (Split-Path -Parent $bin) $false
    }
    Check 'a protected binary runs again' "{`"native`":`"claude PreToolUse root=$root`",`"stdin`":{}}" (Invoke-Handoff @('claude', 'PreToolUse') '{}').Out

    Write-Host 'inside the retry interval no installer is started'
    $probeRoot = Join-Path $work 'probe-plugin'
    New-Item -ItemType Directory -Force -Path (Join-Path $probeRoot 'scripts') | Out-Null
    Copy-Item -LiteralPath (Join-Path $plugin 'scripts/native-bridge.ps1'), (Join-Path $plugin 'scripts/env-file.ps1') -Destination (Join-Path $probeRoot 'scripts')
    [IO.File]::WriteAllText((Join-Path $probeRoot 'rogue-hook.json'), "{`n  `"version`": `"0.9.0`"`n}`n")
    $started = Join-Path $work 'installer-started'
    [IO.File]::WriteAllText((Join-Path $probeRoot 'scripts/native-bridge-install.ps1'), "[IO.File]::WriteAllText('$($started.Replace("'", "''"))', 'yes')")
    [IO.File]::WriteAllText((Join-Path $binDir '.attempt-0.9.0'), '0')
    Check 'kept' 'kept' (Invoke-Handoff @('claude', 'PreToolUse') '{}' @{ ROGUE_NATIVE_BRIDGE_RETRY = '900' } -Root $probeRoot).Out
    Start-Sleep -Seconds 3
    Check 'no installer started' $false (Test-Path -LiteralPath $started)
    Check 'kept' 'kept' (Invoke-Handoff @('claude', 'PreToolUse') '{}' @{ ROGUE_NATIVE_BRIDGE_RETRY = '0' } -Root $probeRoot).Out
    foreach ($i in 1..100) { if (Test-Path -LiteralPath $started) { break }; Start-Sleep -Milliseconds 100 }
    Check 'with no retry interval it is' $true (Test-Path -LiteralPath $started)

    if (-not $onWindows) {
        # On Windows the exe alone is held to the ACL rule; off Windows every directory above it too.
        Write-Host 'an install root with a directory above it another user could replace: no exec, no installer'
        $above = Join-Path (Join-Path $sbHome '.rogue') 'bin'
        Set-Exposed $above $true
        Check 'group-writable ancestor keeps the script' 'kept' (Invoke-Handoff @('claude', 'PreToolUse') '{}').Out
        Set-Pin '0.6.0' (Get-Sha (Join-Path $srv 'blob'))
        [IO.File]::WriteAllText((Join-Path $srv 'requests'), '')
        Check 'a missing binary there keeps the script' 'kept' (Invoke-Handoff @('claude', 'PreToolUse') '{}').Out
        Start-Sleep -Seconds 3
        Check 'no installer was started' '' ([IO.File]::ReadAllText((Join-Path $srv 'requests')))
        Invoke-Install
        Check 'the installer refuses it too' '' ([IO.File]::ReadAllText((Join-Path $srv 'requests')))
        Contains 'and logs why' "rogue-hook 0.6.0: $(Join-Path $binDir '0.6.0') is not protected from other users" (Get-Log)
        Check 'nothing written for it' 0 @(Get-ChildItem -Force -LiteralPath $binDir | Where-Object { $_.Name -like '*0.6.0' }).Count
        Set-Exposed $above $false

        Write-Host "an install root reached through a symlink: only root's own link is followed"
        $link = Join-Path $work 'link'
        New-Item -ItemType SymbolicLink -Path $link -Target $binDir | Out-Null
        $viaLink = "@{ ROGUE_NATIVE_BRIDGE_DIR = '$($link.Replace("'", "''"))' }"
        Check 'our own symlink keeps the script' 'kept' (Invoke-Handoff @('claude', 'PreToolUse') '{}' @{} $viaLink).Out
        Set-Pin '0.7.0' (Get-Sha (Join-Path $srv 'blob'))
        [IO.File]::WriteAllText((Join-Path $srv 'requests'), '')
        Check 'a missing binary under it keeps the script' 'kept' (Invoke-Handoff @('claude', 'PreToolUse') '{}' @{} $viaLink).Out
        Start-Sleep -Seconds 3
        Check 'and starts no installer' '' ([IO.File]::ReadAllText((Join-Path $srv 'requests')))
        Check 'nothing written under it' 0 @(Get-ChildItem -Force -LiteralPath $binDir | Where-Object { $_.Name -like '*0.7.0' }).Count
        Set-Pin '0.1.0' (Get-Sha (Join-Path $srv 'blob'))
        # Only root can chown a link, so a stat wrapper reports root as its owner when asked without -L.
        # (On macOS every case here also runs through /var, a link root owns.)
        $wrapDir = Join-Path $work 'root-stat'
        New-Item -ItemType Directory -Force -Path $wrapDir | Out-Null
        $wrap = "#!/bin/sh`nreal=`$(PATH=/usr/bin:/bin command -v stat)`n" +
            "case `"`$1:`$2`" in -c:%u|-f:%u) ;; *) exec `"`$real`" `"`$@`" ;; esac`n" +
            "flag=`$1; shift 2`nfor p; do`n" +
            "  if [ `"`$p`" = '$link' ]; then echo 0; else `"`$real`" `"`$flag`" '%u' `"`$p`" || exit 1; fi`ndone`n"
        [IO.File]::WriteAllText((Join-Path $wrapDir 'stat'), $wrap)
        & chmod 755 (Join-Path $wrapDir 'stat')
        $r = Invoke-Handoff @('claude', 'PreToolUse') '{}' @{ PATH = "$wrapDir$([IO.Path]::PathSeparator)$env:PATH" } $viaLink
        Check 'a root-owned symlink is followed' "{`"native`":`"claude PreToolUse root=$root`",`"stdin`":{}}" $r.Out
        Remove-Item -LiteralPath $link -Force
    } else {
        Write-Host 'Windows: every directory from the version directory up to the install root'
        $verDir = Join-Path $binDir '0.1.0'
        Set-Exposed $verDir $true
        Check 'a directory another user can write keeps the script' 'kept' (Invoke-Handoff @('claude', 'PreToolUse') '{}').Out
        Set-Exposed $verDir $false
        $junction = Join-Path $work 'jbin'
        New-Item -ItemType Junction -Path $junction -Target $binDir | Out-Null
        Check 'a junction in the chain keeps the script' 'kept' (Invoke-Handoff @('claude', 'PreToolUse') '{}' @{} "@{ ROGUE_NATIVE_BRIDGE_DIR = '$($junction.Replace("'", "''"))' }").Out
        # Removes the junction alone, never what it points at.
        [IO.Directory]::Delete($junction)
        Check 'the default path still hands off' "{`"native`":`"claude PreToolUse root=$root`",`"stdin`":{}}" (Invoke-Handoff @('claude', 'PreToolUse') '{}').Out
    }

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

    Write-Host 'a failed attempt is not retried inside the retry interval'
    Invoke-Install @{ ROGUE_NATIVE_BRIDGE_RETRY = '900' }
    Check 'no request' '' ([IO.File]::ReadAllText((Join-Path $srv 'requests')))

    Write-Host 'a binary that never answers --version is killed and not installed'
    New-Stub '0.5.0'
    Set-Pin '0.5.0' (Get-Sha (Join-Path $srv 'blob'))
    Invoke-Install @{ STUB_HANG = '1' }
    Check 'no binary' $false (Get-Installed '0.5.0')
    Contains 'log reports it' '0.5.0: downloaded binary does not run here' (Get-Log)
    Check 'no temp file left' 0 @(Get-ChildItem -Force -LiteralPath (Join-Path $binDir '0.5.0')).Count
    Check 'the lock is released' $false (Test-Path -LiteralPath (Join-Path $binDir '.lock-0.5.0'))
} finally {
    if ($server) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
}
if ($script:fails -gt 0) { Write-Host "FAIL: $($script:fails) check(s)"; exit 1 }
Write-Host 'OK: native bridge hand-off and install (PowerShell)'
