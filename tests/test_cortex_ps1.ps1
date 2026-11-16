$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
$Source = [IO.Path]::Combine($Repo, 'plugins', 'cortex')
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
$Bundle = Join-Path $H 'bundle'
Copy-Item -LiteralPath $Source -Destination $Bundle -Recurse
$Scripts = Join-Path $Bundle 'scripts'
# Only the disposable bundle skips machine credentials; production trust checks stay intact.
$reader = Join-Path $Scripts 'env-file.ps1'
$text = (Read-Text $reader).Replace("`r`n", "`n")
$text = $text.Replace('function Read-RogueEnvFile {' + "`n" + '    param([string]$Path)', 'function Read-RogueEnvFile {' + "`n" + '    param([string]$Path)' + "`n" + '    if ($Path -eq ''C:\ProgramData\rogue\env'') { return }')
if (-not $text.Contains('    if ($Path -eq ''C:\ProgramData\rogue\env'') { return }')) { throw 'Machine credential isolation was not applied' }
[IO.File]::WriteAllText($reader, $text)
$env:USERPROFILE = $H
$env:CORTEX_HOME = Join-Path $H 'custom cortex'
$env:SNOWFLAKE_HOME = Join-Path $H 'unused snowflake'
foreach ($name in 'ROGUE_API_KEY', 'ROGUE_BASE_URL', 'ROGUE_LOG_FILE', 'ROGUE_LOG_DIR', 'ROGUE_ACTOR_EMAIL', 'ROGUE_ACTOR_NAME', 'ROGUE_SHIP_ALL', 'VSCODE_ESM_ENTRYPOINT') { [Environment]::SetEnvironmentVariable($name, $null) }
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
    # Keep a real Cortex on PATH out of both assertions, including the positive case.
    function Get-Command { param([string]$Name) if ($Name -ne 'cortex') { throw 'Unexpected command lookup' } }
    Check 'Cortex lookup is isolated from PATH' { $null -eq (Get-Command cortex) }
    Check 'unmarked cortex is not detected' { -not (Test-CortexCliInstalled) }
    [IO.File]::WriteAllText((Join-Path $version 'cortex-version.txt'), '1.2.45+build')
    Check 'official shim detected without a PATH refresh' { Test-CortexCliInstalled }
    Remove-Item Function:Get-Command
    [IO.File]::WriteAllText((Join-Path $Bundle 'env'), '# bundled credentials')
    Check 'fresh install into CORTEX_HOME'  { Run @() }
    Check 'fresh install retains source env' { (Test-Path (Join-Path $Root 'env')) -and (Read-Text (Join-Path $Root 'env')) -ceq '# bundled credentials' }
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
    . ([scriptblock]::Create((Read-Text ([IO.Path]::Combine($Root, 'scripts', 'env-file.ps1')))))
    function Test-RogueEnvFile { return $true }
    function Get-Content { throw 'Machine credentials must never be read' }
    Check 'hook credential reader skips even a trusted machine env before reading' { @(Read-RogueEnvFile 'C:\ProgramData\rogue\env').Count -eq 0 }
    Remove-Item Function:Test-RogueEnvFile, Function:Get-Content
    Check 'unconfigured hook allows' { (Invoke-Hook 'PreToolUse') -eq '{}' }
    $requests = Join-Path $H 'requests.jsonl'
    function Start-Mock { param([string]$Body, [int]$Status = 200)
        $port = Get-Random -Minimum 30000 -Maximum 40000
        $job = Start-Job -ArgumentList $port, $Body, $Status, $requests {
            param($port, $body, $status, $requests)
            $l = New-Object Net.HttpListener; $l.Prefixes.Add("http://localhost:$port/"); $l.Start()
            while ($true) {
                $pending = $l.GetContextAsync()
                while (-not $pending.Wait(200)) {}
                $c = $pending.GetAwaiter().GetResult()
                $reader = New-Object IO.StreamReader($c.Request.InputStream)
                $requestBody = $reader.ReadToEnd(); $reader.Dispose()
                $record = @{ path = $c.Request.Url.AbsolutePath; email = $c.Request.Headers['x-rogue-actor-email']; name = $c.Request.Headers['x-rogue-actor-name']; body = $requestBody } | ConvertTo-Json -Compress
                [IO.File]::AppendAllText($requests, $record + "`n")
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
    $env:ROGUE_ACTOR_EMAIL = 'resolved@example.test'; $env:ROGUE_ACTOR_NAME = 'Resolved Actor'
    [IO.File]::AppendAllText((Join-Path $H '.rogue-env'), "ROGUE_ACTOR_EMAIL=''`nROGUE_ACTOR_NAME=''`n")
    $cursorLog = [IO.Path]::Combine($H, '.rogue', 'logs', 'cursor.log')
    [IO.File]::WriteAllText($cursorLog, "other agent private log`n")
    if ($PSVersionTable.PSVersion.Major -eq 5 -or $IsWindows) {
        Check 'SessionStart allows while starting its real background shipper' { (Invoke-Hook 'SessionStart') -eq '{}' }
        $uploads = @()
        for ($i = 0; $i -lt 100; $i++) {
            $records = @(Get-Content $requests | ForEach-Object { $_ | ConvertFrom-Json })
            $uploads = @($records | Where-Object { $_.path -eq '/api/v1/hooks/logs' })
            if ($uploads.Count) { break }
            Start-Sleep -Milliseconds 100
        }
        Check 'SessionStart uploads Cortex logs only, never the present Cursor log' {
            $uploads.Count -eq 1 -and ($uploads[0].body | ConvertFrom-Json).log_file -eq 'cortex.log' -and ($uploads[0].body | ConvertFrom-Json).shipper -eq 'cortex'
        }
        $start = @($records | Where-Object { $_.path -eq '/api/v1/hooks/cortex' })[-1]
        Check 'actual upload actor matches the hook despite empty file identity' {
            $uploads.Count -eq 1 -and ($uploads[0].body | ConvertFrom-Json).actor_email -eq $start.email -and ($uploads[0].body | ConvertFrom-Json).actor_name -eq $start.name -and $start.email -ne 'anon'
        }
    }
    # Run the lifecycle child command with only its final network drain replaced by a probe.
    $hookSource = Read-Text ([IO.Path]::Combine($Root, 'scripts', 'hook.ps1'))
    $assignment = ($hookSource -split "`n" | Where-Object { $_ -match '^\s*\$inner = ' }) -join "`n"
    . ([scriptblock]::Create($assignment))
    $env:ROGUE_SHIPPER_SCRIPT = [IO.Path]::Combine($Root, 'scripts', 'ship-logs.ps1')
    $env:ROGUE_SHIPPER_ROOT = $Root; $env:ROGUE_SHIPPER_VERSION = '1.0.0'
    $probe = 'Initialize-Args; Import-ShipEnv; Resolve-Knobs; $null = Resolve-ShipActor; @{slug=$script:ShipperSlug; files=@(Get-TargetLogFiles); email=$script:actorEmail; name=$script:actorName} | ConvertTo-Json -Compress'
    $shipSource = Read-Text $env:ROGUE_SHIPPER_SCRIPT
    Check 'shipper is ASCII for Windows PowerShell 5.1 without a BOM' { $shipSource -notmatch '[^\x00-\x7f]' }
    [IO.File]::WriteAllText($env:ROGUE_SHIPPER_SCRIPT, [regex]::Replace($shipSource, 'Invoke-Main\s*$', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $probe }))
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
    $shipped = (& $PsExe -NoProfile -NonInteractive -EncodedCommand $encoded | Out-String) | ConvertFrom-Json
    Check 'SessionStart shipper selects Cortex only with Cursor log present' { $shipped.slug -eq 'cortex' -and @($shipped.files).Count -eq 1 -and (Split-Path $shipped.files[0] -Leaf) -eq 'cortex.log' }
    Write-Host ('shipper probe: ' + ($shipped | ConvertTo-Json -Compress))
    Check 'empty env actor fields preserve resolved hook identity' { $shipped.email -eq 'resolved@example.test' -and $shipped.name -eq 'Resolved Actor' }
    $fileIdentity = (Read-Text (Join-Path $H '.rogue-env')).Replace("ROGUE_ACTOR_EMAIL=''", "ROGUE_ACTOR_EMAIL='configured@example.test'").Replace("ROGUE_ACTOR_NAME=''", "ROGUE_ACTOR_NAME='Configured Actor'")
    [IO.File]::WriteAllText((Join-Path $H '.rogue-env'), $fileIdentity)
    $shipped = (& $PsExe -NoProfile -NonInteractive -EncodedCommand $encoded | Out-String) | ConvertFrom-Json
    Check 'nonempty file actor cannot replace inherited hook identity' { $shipped.email -eq 'resolved@example.test' -and $shipped.name -eq 'Resolved Actor' }
    Remove-Item Env:ROGUE_ACTOR_EMAIL, Env:ROGUE_ACTOR_NAME
    $shipped = (& $PsExe -NoProfile -NonInteractive -EncodedCommand $encoded | Out-String) | ConvertFrom-Json
    Check 'standalone shipper still accepts file identity' { $shipped.email -eq 'configured@example.test' -and $shipped.name -eq 'Configured Actor' }
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
