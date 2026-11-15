$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
$Scripts = [IO.Path]::Combine($Repo, 'plugins', 'cortex', 'scripts')
$script:fails = 0
$PsExe = (Get-Process -Id $PID).Path
function Check { param([string]$Name, [scriptblock]$Test)
    $ok = $false; try { $ok = [bool](& $Test) } catch {}
    if ($ok) { Write-Host "ok   $Name" } else { Write-Host "FAIL $Name"; $script:fails++ }
}
function Run { param([string[]]$Arguments) $ErrorActionPreference = 'Continue'; & $PsExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Scripts 'install.ps1') @Arguments *> $null; $LASTEXITCODE -eq 0 }
function Read-Text { param([string]$Path) [IO.File]::ReadAllText($Path) }
$H = Join-Path ([IO.Path]::GetTempPath()) ("cortex-ps1 ' home-" + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $H | Out-Null
$env:USERPROFILE = $H
$env:CORTEX_HOME = Join-Path $H 'custom cortex'
$env:SNOWFLAKE_HOME = Join-Path $H 'unused snowflake'
foreach ($name in 'ROGUE_API_KEY', 'ROGUE_BASE_URL', 'ROGUE_LOG_FILE', 'ROGUE_LOG_DIR', 'VSCODE_ESM_ENTRYPOINT') { [Environment]::SetEnvironmentVariable($name, $null) }
$Root = [IO.Path]::Combine($env:CORTEX_HOME, 'plugins', 'rogue-security')
$Hooks = [IO.Path]::Combine($Root, 'hooks', 'hooks.json')
try {
    $env:ROGUE_INSTALL_LIB_ONLY = '1'
    . (Join-Path $Repo 'install.ps1')
    Remove-Item Env:ROGUE_INSTALL_LIB_ONLY
    $env:LOCALAPPDATA = Join-Path $H 'Local'
    $bin = [IO.Path]::Combine($env:LOCALAPPDATA, 'cortex', 'bin')
    $version = [IO.Path]::Combine($env:LOCALAPPDATA, 'cortex', '1.2.45+build')
    New-Item -ItemType Directory -Force -Path $bin, $version | Out-Null
    $exe = Join-Path $version 'cortex.exe'
    [IO.File]::WriteAllText($exe, '')
    [IO.File]::WriteAllText((Join-Path $bin 'cortex.cmd'), ('@"' + $exe + '" %*'))
    Check 'unmarked cortex is not detected' { -not (Test-CortexCliInstalled) }
    [IO.File]::WriteAllText((Join-Path $version 'cortex-version.txt'), '1.2.45+build')
    Check 'official shim detected without a PATH refresh' { Test-CortexCliInstalled }
    Check 'fresh install into CORTEX_HOME'  { Run @() }
    Check 'hooks file has nine events' { @((Read-Text $Hooks | ConvertFrom-Json).hooks.PSObject.Properties).Count -eq 9 }
    Check 'status passes' { Run @('-Status') }
    $envFile = Join-Path $Root 'env'
    [IO.File]::WriteAllText($envFile, "# preserved credentials")
    Check 'repeat install preserves bundled env' { (Run @()) -and (Read-Text $envFile) -ceq '# preserved credentials' }
    New-Item -ItemType Directory -Path (Join-Path (Split-Path $Root) '.rogue-security.lock') | Out-Null
    Check 'concurrent install fails without losing plugin' { -not (Run @()) -and (Run @('-Status')) }
    Remove-Item -Force -LiteralPath (Join-Path (Split-Path $Root) '.rogue-security.lock')
    $settings = Join-Path $env:CORTEX_HOME 'settings.json'
    [IO.File]::WriteAllText($settings, '{"ownHooks": true}')
    $foreign = Join-Path (Split-Path $Root) 'foreign'
    New-Item -ItemType Directory -Path $foreign | Out-Null
    Check 'uninstall preserves settings and other plugins' { (Run @('-Uninstall')) -and (Read-Text $settings) -ceq '{"ownHooks": true}' -and (Test-Path $foreign) -and -not (Test-Path $Root) }
    Check 'status fails after uninstall' { -not (Run @('-Status')) }
    # hook.ps1 against an in-process mock of the Rogue API.
    Run @() | Out-Null
    # Runs the exact command stored in hooks.json, with this engine standing in for `powershell`.
    function Invoke-Hook {
        param([string]$EventName)
        $ErrorActionPreference = 'Continue'
        $cmd = @((Read-Text $Hooks | ConvertFrom-Json).hooks.$EventName)[0].hooks[0].command
        ('{"tool_name":"write_file"}' | & $PsExe -NoProfile -NonInteractive -Command $cmd | Out-String).Trim()
    }
    Check 'unconfigured hook allows' { (Invoke-Hook 'PreToolUse') -eq '{}' }
    function Start-Mock { param([string]$Body, [int]$Status = 200)
        $port = Get-Random -Minimum 30000 -Maximum 40000
        $job = Start-Job -ArgumentList $port, $Body, $Status {
            param($port, $body, $status)
            $l = New-Object Net.HttpListener; $l.Prefixes.Add("http://localhost:$port/"); $l.Start()
            while ($true) {
                $pending = $l.GetContextAsync()
                while (-not $pending.Wait(200)) {}
                $c = $pending.GetAwaiter().GetResult(); $c.Request.InputStream.CopyTo([IO.Stream]::Null)
                $c.Response.StatusCode = $status
                $b = [Text.Encoding]::UTF8.GetBytes($body); $c.Response.OutputStream.Write($b, 0, $b.Length); $c.Response.Close()
            }
        }
        for ($i = 0; $i -lt 100; $i++) {
            try { Invoke-WebRequest -Uri "http://localhost:$port/" -Method Post -UseBasicParsing -TimeoutSec 1 | Out-Null; break }
            catch { if ($_.Exception.Response) { break }; Start-Sleep -Milliseconds 200 }
        }
        $envFile = Join-Path $H '.rogue-env'
        [IO.File]::WriteAllText($envFile, "ROGUE_API_KEY='rg_test'`nROGUE_BASE_URL='http://localhost:$port'`n")
        if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { & chmod 600 $envFile }
        return $job
    }
    $deny = '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"no"}}'
    $job = Start-Mock $deny
    Check 'relays a native deny' { (Invoke-Hook 'PreToolUse') -eq $deny }
    Stop-Job $job; $job = Start-Mock '{}'
    Check 'relays an allow' { (Invoke-Hook 'UserPromptSubmit') -eq '{}' }
    foreach ($invalid in '<html>proxy</html>', '{not-json}', '[]', 'null', '"text"') {
        Stop-Job $job; $job = Start-Mock $invalid
        Check "fails open on $invalid" { (Invoke-Hook 'PreToolUse') -eq '{}' }
    }
    Stop-Job $job; $job = Start-Mock ('  ' + $deny)
    Check 'relays a whitespace-prefixed deny' { (Invoke-Hook 'PreToolUse') -eq $deny }
    $env:VSCODE_ESM_ENTRYPOINT = 'vs/code/electron-utility/sharedProcess/sharedProcessMain'
    Check 'Desktop marker is recognized' { (Invoke-Hook 'PreToolUse') -eq $deny -and ((Get-Content ([IO.Path]::Combine($H, '.rogue', 'logs', 'cortex.log')) | Select-String 'surface=cortex_code_desktop').Count -ge 1) }
    Remove-Item Env:VSCODE_ESM_ENTRYPOINT
    Stop-Job $job; $job = Start-Mock $deny 500
    Check 'fails open on a server error' { (Invoke-Hook 'PreToolUse') -eq '{}' }
    Stop-Job $job
    Check 'fails open when unreachable' { (Invoke-Hook 'PreToolUse') -eq '{}' }
    Check 'logs every outcome' { (Get-Content ([IO.Path]::Combine($H, '.rogue', 'logs', 'cortex.log')) | Select-String 'surface=cortex_code_cli').Count -ge 5 }
} finally {
    Get-Job -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $H
}
if ($script:fails) { Write-Host "$($script:fails) failed"; exit 1 }
Write-Host 'all Cortex Code PowerShell tests passed'
