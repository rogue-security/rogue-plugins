#!/usr/bin/env pwsh
# END-TO-END test for the Antigravity PowerShell hook AS hooks.json LAUNCHES IT: every
# `powershell` command is taken verbatim from plugins/antigravity/hooks.json and run
# through cmd.exe from the plugin root, with a real ~/.rogue-env and a real HTTP server
# (tests/e2e_receiver.mjs).
#
#   pwsh -NoProfile -File tests/e2e_hook_antigravity.ps1
#
# WHY THIS EXISTS. tests/test_hook_ps1_antigravity.ps1 dot-sources hook.ps1, so the
# script's `$script:` writes and its top-level declarations always share one scope
# there. The launch in hooks.json did not: `& ([scriptblock]::Create(...))` gives the
# scriptblock no script scope of its own, so `$script:apiKey` landed in the global
# scope while Assert-ApiKey read the scriptblock's empty `$apiKey`. Every event on
# every Windows machine logged `outcome=unconfigured`, failed open and never reached
# Rogue, while every unit test passed (FIRE-3368). Only running the real command
# catches that, so this must run on windows-latest; elsewhere it is a SKIP.
#
# %USERPROFILE% is redirected into a sandbox, so the developer's real ~/.rogue and
# ~/.rogue-env are never read or written.

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$pluginRoot = Join-Path $repo 'plugins/antigravity'
$failures = 0
$script:aborted = $false

function Pass { param([string]$M) Write-Host "  ok: $M" }
function Fail { param([string]$M) Write-Host "FAIL: $M"; $script:failures++ }

if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
    Write-Host 'SKIP: hook.ps1 stands down on non-Windows - this suite needs windows-latest.'
    exit 0
}
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host 'SKIP: node not found (the receiver needs it).'
    exit 0
}

# The env file in use overrides the process env, but the process env still supplies
# any knob the file leaves out, so a developer's own values must not leak in.
$hookKnobs = @('ROGUE_API_KEY', 'ROGUE_BASE_URL', 'ROGUE_API_URL', 'ROGUE_ACTOR_EMAIL', 'ROGUE_ACTOR_NAME',
               'ROGUE_LOG_FILE', 'ROGUE_LOG_DIR', 'ROGUE_LOG_MAX_BYTES', 'ROGUE_DEBUG')
$touchedVars = $hookKnobs + @('E2E_API_KEY', 'USERPROFILE')
$originalEnv = @{}
foreach ($name in $touchedVars) { $originalEnv[$name] = [System.Environment]::GetEnvironmentVariable($name) }
foreach ($knob in $hookKnobs) { Remove-Item "Env:$knob" -ErrorAction SilentlyContinue }

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("rogue-e2eagy-" + [System.Guid]::NewGuid().ToString('N'))
$recvDir = Join-Path $sandbox 'recv'
$sandboxHome = Join-Path $sandbox 'home'
New-Item -ItemType Directory -Path $recvDir -Force | Out-Null
New-Item -ItemType Directory -Path $sandboxHome -Force | Out-Null
$env:USERPROFILE = $sandboxHome
$receiver = $null

try {
    $env:E2E_API_KEY = 'e2e-key'
    $receiver = Start-Process -FilePath 'node' `
        -ArgumentList @((Join-Path $repo 'tests/e2e_receiver.mjs'), $recvDir) `
        -PassThru -NoNewWindow `
        -RedirectStandardOutput (Join-Path $sandbox 'recv.out') `
        -RedirectStandardError (Join-Path $sandbox 'recv.err')
    $portFile = Join-Path $recvDir 'port'
    $port = ''
    for ($i = 0; $i -lt 100 -and -not $port; $i++) {
        if (Test-Path -LiteralPath $portFile) { $port = (Get-Content -Raw -LiteralPath $portFile).Trim() }
        if (-not $port) { Start-Sleep -Milliseconds 100 }
    }
    if (-not $port) { throw "the receiver never wrote a port file (see $sandbox\recv.err)" }

    # The format the installer writes. A sandbox file under %TEMP% inherits the user,
    # SYSTEM and Administrators ACL, which env-file.ps1's trust check accepts.
    Set-Content -LiteralPath (Join-Path $sandboxHome '.rogue-env') -Encoding Ascii -Value @(
        "export ROGUE_API_KEY='e2e-key'",
        "export ROGUE_ACTOR_EMAIL='e2e@rogue.security'",
        "export ROGUE_ACTOR_NAME='E2E'",
        "export ROGUE_BASE_URL='http://127.0.0.1:$port'"
    )

    $hooks = (Get-Content -Raw -LiteralPath (Join-Path $pluginRoot 'hooks.json') | ConvertFrom-Json).rogue
    $events = @($hooks.PSObject.Properties | ForEach-Object { $_.Name })
    if ($events.Count -eq 0) { throw 'hooks.json registers no events' }
    $otherLog = Join-Path $recvDir 'other.log'
    $hookLog = Join-Path (Join-Path (Join-Path $sandboxHome '.rogue') 'logs') 'antigravity.log'

    foreach ($event in $events) {
        # Tool events nest their handlers under a matcher group; the rest list them directly.
        $entries = @($hooks.$event | ForEach-Object { if ($_.hooks) { $_.hooks } else { $_ } })
        $command = @($entries | Where-Object { $_.command -like 'powershell*' })[0].command
        if (-not $command) { Fail "$event has no powershell handler"; continue }

        $payloadFile = Join-Path $sandbox "$event.json"
        Set-Content -LiteralPath $payloadFile -Encoding Ascii -Value ('{"hookEventName":"' + $event + '","conversationId":"e2e-' + $event + '"}')
        $outFile = Join-Path $sandbox "$event.out"
        $before = if (Test-Path -LiteralPath $otherLog) { @(Get-Content -LiteralPath $otherLog).Count } else { 0 }

        # cmd /s strips only the outer quotes, so the command reaches cmd.exe exactly as
        # Antigravity hands it over, quoting included.
        $child = Start-Process -FilePath 'cmd.exe' -ArgumentList ('/d /s /c "' + $command + '"') `
            -WorkingDirectory $pluginRoot -NoNewWindow -PassThru -Wait `
            -RedirectStandardInput $payloadFile -RedirectStandardOutput $outFile `
            -RedirectStandardError (Join-Path $sandbox "$event.err")

        $posts = @()
        if (Test-Path -LiteralPath $otherLog) {
            $posts = @(Get-Content -LiteralPath $otherLog | Select-Object -Skip $before |
                Where-Object { $_ -eq 'POST /api/v1/hooks/antigravity' })
        }
        $stdout = if (Test-Path -LiteralPath $outFile) { (Get-Content -Raw -LiteralPath $outFile) } else { '' }
        if ($child.ExitCode -ne 0) { Fail "$event exited $($child.ExitCode) (the hook must always exit 0)" }
        if ($posts.Count -eq 1) { Pass "$event posted the event to /api/v1/hooks/antigravity" }
        else { Fail "$event made $($posts.Count) POSTs to /api/v1/hooks/antigravity (expected 1); stdout [$stdout]" }
        # The receiver answers {}. Only PreToolUse fails open to something else
        # ({"decision":"allow"}), so only there does relaying {} prove the server answered.
        if ($event -eq 'PreToolUse') {
            if ("$stdout".Trim() -eq '{}') { Pass "$event relayed the server response" }
            else { Fail "$event printed [$stdout] instead of the server response {}" }
        }
    }

    $unconfigured = @()
    if (Test-Path -LiteralPath $hookLog) { $unconfigured = @(Select-String -LiteralPath $hookLog -SimpleMatch 'outcome=unconfigured') }
    if ($unconfigured.Count -eq 0) { Pass 'no event logged outcome=unconfigured' }
    else { Fail "$($unconfigured.Count) event(s) logged outcome=unconfigured with a key in ~/.rogue-env" }
} catch {
    $script:aborted = $true
    Write-Host "ABORTED: $($_.Exception.Message)"
} finally {
    foreach ($name in $touchedVars) { [System.Environment]::SetEnvironmentVariable($name, $originalEnv[$name]) }
    if ($receiver -and -not $receiver.HasExited) { try { $receiver.Kill() } catch {} }
    if ($failures -eq 0 -and -not $script:aborted) {
        try { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    } else {
        Write-Host "sandbox kept for diagnosis: $sandbox"
    }
}

Write-Host ''
if ($failures -eq 0 -and -not $script:aborted) {
    Write-Host 'All end-to-end Antigravity hook tests passed.'
    exit 0
}
if ($script:aborted) { Write-Host 'aborted before the suite finished.' }
Write-Host "$failures failure(s)."
exit 1
