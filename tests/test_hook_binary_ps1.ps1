# tests/test_hook_binary_ps1.ps1 - Windows end-to-end for the native dispatcher hand-off:
# hook-binary.ps1 downloads the pinned exe through a mock /api/v1/hooks/binary, verifies
# it and installs it into CLAUDE_PLUGIN_DATA; hook.ps1 then hands it the event with stdin
# and stdout passed through as raw bytes. A C# stub compiled here stands in for the exe.
#
# Windows PowerShell 5.1 only (Add-Type -OutputType ConsoleApplication); both scripts are
# loaded the way hooks.json loads them, from a scriptblock in a fresh powershell process.
#
#   powershell -NoProfile -File tests/test_hook_binary_ps1.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$script:fails = 0
function Check {
    param([string]$Label, $Expected, $Actual)
    if ($Expected -ceq $Actual) { Write-Host "  ok: $Label" }
    else { Write-Host "FAIL: $Label (expected [$Expected], got [$Actual])"; $script:fails++ }
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('rogue-hookbin-' + [guid]::NewGuid().ToString('N'))
$plugin = Join-Path $work 'plugin'
$data = Join-Path $work 'data'
$srv = Join-Path $work 'srv'
$sbHome = Join-Path $work 'home'
New-Item -ItemType Directory -Force -Path $data, $srv, $sbHome | Out-Null
Copy-Item -Recurse -LiteralPath (Join-Path $repo 'plugins\rogue') -Destination $plugin
$bin = Join-Path $data 'rogue-hook.exe'
$port = Get-Random -Minimum 30000 -Maximum 40000
$server = Start-Process python -ArgumentList @((Join-Path $repo 'tests\hook_binary_server.py'), $port, $srv) -PassThru -WindowStyle Hidden

function New-Stub {
    param([string]$Version)
    $src = @"
using System; using System.IO; using System.Text;
public static class Stub {
    public static int Main(string[] a) {
        if (a.Length > 0 && a[0] == "--version") { Console.Out.Write("rogue-hook $Version\n"); return 0; }
        var input = new MemoryStream(); Console.OpenStandardInput().CopyTo(input);
        var o = Console.OpenStandardOutput();
        var head = Encoding.UTF8.GetBytes("{\"native\":\"" + string.Join(" ", a) + "\",\"stdin\":");
        o.Write(head, 0, head.Length); var b = input.ToArray(); o.Write(b, 0, b.Length); o.WriteByte(125); o.Flush();
        return 0;
    }
}
"@
    $out = Join-Path $work "stub-$Version.exe"
    Add-Type -TypeDefinition $src -OutputAssembly $out -OutputType ConsoleApplication
    Copy-Item -LiteralPath $out -Destination (Join-Path $srv 'blob') -Force
}
function Get-Sha { param([string]$Path) (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() }
function Set-Pin {
    param([string]$Version, [string]$Sha)
    $pin = '{"version":"' + $Version + '","sha256":{"windows-amd64":"' + $Sha + '","windows-arm64":"' + $Sha + '"}}'
    [IO.File]::WriteAllText((Join-Path $plugin 'rogue-hook.json'), $pin)
}

# Runs one of the plugin scripts as hooks.json does and returns its stdout bytes as UTF-8 text.
function Invoke-Plugin {
    param([string]$Script, [string]$Arguments = '', [string]$Stdin = '', [hashtable]$Env = @{})
    $psi = New-Object System.Diagnostics.ProcessStartInfo 'powershell'
    $psi.Arguments = "-NoProfile -NonInteractive -Command `"& ([scriptblock]::Create((Get-Content -Raw -LiteralPath (Join-Path (Get-Item Env:CLAUDE_PLUGIN_ROOT).Value 'scripts/$Script')))) $Arguments`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $vars = @{
        CLAUDE_CODE_ENTRYPOINT = 'cli'; CLAUDE_PLUGIN_ROOT = $plugin; CLAUDE_PLUGIN_DATA = $data
        USERPROFILE = $sbHome; ROGUE_API_KEY = 'test-key'; ROGUE_BASE_URL = "http://127.0.0.1:$port"
    }
    foreach ($k in $Env.Keys) { $vars[$k] = $Env[$k] }
    foreach ($k in $vars.Keys) { $psi.EnvironmentVariables[$k] = $vars[$k] }
    $p = [System.Diagnostics.Process]::Start($psi)
    $in = [Text.Encoding]::UTF8.GetBytes($Stdin)
    $p.StandardInput.BaseStream.Write($in, 0, $in.Length)
    $p.StandardInput.Close()
    $buf = New-Object IO.MemoryStream
    $p.StandardOutput.BaseStream.CopyTo($buf)
    $p.WaitForExit()
    [Text.Encoding]::UTF8.GetString($buf.ToArray())
}
function Install { Set-Content -LiteralPath (Join-Path $srv 'requests') -Value $null; [void](Invoke-Plugin 'hook-binary.ps1') }
function Read-Log { Get-Content -Raw -LiteralPath (Join-Path $sbHome '.rogue\hook-binary.log') }
function Read-Requests { [string](Get-Content -Raw -LiteralPath (Join-Path $srv 'requests')) }

try {
    for ($i = 0; $i -lt 50; $i++) {
        try { (New-Object Net.Sockets.TcpClient('127.0.0.1', $port)).Close(); break } catch { Start-Sleep -Milliseconds 100 }
    }

    Write-Host 'no pin: nothing installed'
    New-Stub '0.1.0'
    Install
    Check 'no binary' $false (Test-Path -LiteralPath $bin)
    Check 'log names the reason' $true ((Read-Log) -match 'no pinned version')

    Write-Host 'matching pin: downloaded with the API key, verified and installed'
    Set-Pin '0.1.0' (Get-Sha (Join-Path $srv 'blob'))
    Install
    Check 'binary installed' $true (Test-Path -LiteralPath $bin)
    Check 'log reports install' $true ((Read-Log) -match 'installed rogue-hook 0\.1\.0')
    Check 'lookup carries version, platform and key' $true ((Read-Requests) -match '/api/v1/hooks/binary\?version=0\.1\.0&os=windows&arch=(amd64|arm64) key=test-key')
    Check 'presigned URL fetched intact' $true ((Read-Requests) -match '/blob\?X-Amz-Signature=abc&X-Amz-Expires=300')

    Write-Host 'hook.ps1 hands the event and raw payload bytes to the exe'
    $payload = '{"prompt":"caf' + [char]0xE9 + ' ' + [char]0x2713 + '"}'
    Check 'native response relayed byte for byte' ('{"native":"claude UserPromptSubmit","stdin":' + $payload + '}') (Invoke-Plugin 'hook.ps1' 'UserPromptSubmit' $payload)

    Write-Host 'already installed: no download'
    Install
    Check 'log reports current' $true ((Read-Log) -match 'already installed')
    Check 'no request' '' ((Read-Requests).Trim())

    Write-Host 'new pin whose download does not match: old exe moved aside, scripts take over'
    New-Stub '0.2.0'
    Set-Pin '0.2.0' ('0' * 64)
    Install
    Check 'no binary' $false (Test-Path -LiteralPath $bin)
    Check 'log reports mismatch' $true ((Read-Log) -match 'sha256 mismatch')
    Check 'hook.ps1 runs itself again' '{}' (Invoke-Plugin 'hook.ps1' 'PreToolUse' '{}' @{ ROGUE_API_KEY = ''; ROGUE_BASE_URL = '' })

    Write-Host 'exe that reports another version is not installed'
    Set-Pin '0.3.0' (Get-Sha (Join-Path $srv 'blob'))
    Install
    Check 'no binary' $false (Test-Path -LiteralPath $bin)
    Check 'log reports it' $true ((Read-Log) -match 'does not run here')
} finally {
    Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
}

if ($script:fails -gt 0) { Write-Host "FAIL: $script:fails check(s)"; exit 1 }
Write-Host 'OK: hook binary install and hand-off (Windows)'
exit 0
