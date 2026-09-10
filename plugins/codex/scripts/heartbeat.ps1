# Rogue presence heartbeat (Windows / PowerShell) — Codex plugin.
#
# Native-Windows analogue of heartbeat.sh. Fired (detached) from SessionStart and
# from Stop. POSTs /api/v1/hooks/status so this install shows up in the Coding
# Agents roster and the org learns which plugin version runs (drives the "outdated"
# badge). Fire-and-forget: never blocks Codex, always exits 0.
#
# TWO TRIGGERS, ONE SCRIPT, exactly as in heartbeat.sh. SessionStart fires once per
# session; Stop fires once per TURN, so its beacon is throttled. Keep the two halves
# in lockstep - both load the same shared beacon library, so the throttle interval,
# the stamp path and the SessionStart-is-never-throttled rule cannot disagree
# between operating systems.
#
# The Stop trigger is spawned by hook.ps1, not by a second hooks.json entry: Codex
# hashes the whole hook definition and skips untrusted command hooks until reviewed
# via /hooks, so a new entry would silently disable every Rogue hook on every
# existing install until each user re-approved.

# Must precede every statement. The default keeps the existing hooks.json entry -
# which passes no argument - behaving exactly as it does today.
param([string]$Trigger = 'SessionStart')

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

function Dbg { param([string]$Msg) if ($env:ROGUE_DEBUG) { [Console]::Error.WriteLine("[rogue-heartbeat] $Msg") } }

function ConvertFrom-ShellQuoted {
    param([string]$Val)
    if ($null -eq $Val) { return $Val }
    $sb = [System.Text.StringBuilder]::new()
    $i = 0; $n = $Val.Length; $state = 'normal'
    while ($i -lt $n) {
        $c = $Val[$i]
        switch ($state) {
            'single' { if ($c -eq "'") { $state = 'normal' } else { [void]$sb.Append($c) } }
            'double' {
                if ($c -eq '"') { $state = 'normal' }
                elseif ($c -eq '\' -and ($i + 1) -lt $n -and ('"\$`'.IndexOf($Val[$i+1]) -ge 0)) { [void]$sb.Append($Val[$i+1]); $i++ }
                else { [void]$sb.Append($c) }
            }
            default {
                if ($c -eq "'") { $state = 'single' }
                elseif ($c -eq '"') { $state = 'double' }
                elseif ($c -eq '\' -and ($i + 1) -lt $n) { [void]$sb.Append($Val[$i+1]); $i++ }
                else { [void]$sb.Append($c) }
            }
        }
        $i++
    }
    return $sb.ToString()
}

try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

# Stand down on non-Windows (pwsh on macOS/Linux runs heartbeat.sh instead).
if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { exit 0 }

$pluginRoot = $env:PLUGIN_ROOT
if (-not $pluginRoot) { try { $pluginRoot = (Get-Location).Path } catch { $pluginRoot = '.' } }

# ── beacon throttle ────────────────────────────────────────────────────────
# The rule lives in scripts/beacon.ps1, a byte-identical copy of
# scripts/shared/beacon.ps1 shared with the other four PowerShell plugins, whose sh
# twin scripts/beacon.sh is what heartbeat.sh loads. Every per-plugin difference is
# an argument: the stamp slug (`codex`, matching the log file, NOT the roster family
# `openai`), and whether this trigger is the session one.
#
# Loaded as a SCRIPTBLOCK from the file's text, never with -File or a path
# dot-source: running a .ps1 directly is subject to ExecutionPolicy and to a
# GPO-enforced policy that -ExecutionPolicy Bypass cannot override.
#
# A missing or unparseable library degrades to an UNTHROTTLED beacon - today's
# behaviour, and the safe direction: a beacon too often is noise, while a beacon
# never again is a roster row indistinguishable from an uninstalled plugin.
$beaconUnthrottled = ($Trigger -eq 'SessionStart')
$beaconLib = Join-Path $pluginRoot 'scripts\beacon.ps1'
if (Test-Path -LiteralPath $beaconLib) {
    try { . ([scriptblock]::Create((Get-Content -Raw -LiteralPath $beaconLib))) } catch { }
}
if (-not (Get-Command Request-RogueBeaconSlot -ErrorAction SilentlyContinue)) {
    function Initialize-RogueBeacon { param([hashtable]$Creds = @{}) }
    function Request-RogueBeaconSlot { param([string]$Slug, [bool]$Unthrottled = $false) return $true }
}

# ── credential resolution ──────────────────────────────────────────────────
$creds = @{}
foreach ($k in 'ROGUE_API_KEY','ROGUE_ACTOR_EMAIL','ROGUE_ACTOR_NAME','ROGUE_BASE_URL','ROGUE_CODEX_SURFACE',
               'ROGUE_HEARTBEAT_MIN_INTERVAL') {
    $val = [Environment]::GetEnvironmentVariable($k); if ($val) { $creds[$k] = $val }
}
# The first env file holding ROGUE_API_KEY is used alone: machine, bundled, user.
foreach ($f in @('C:\ProgramData\rogue\env', (Join-Path $pluginRoot 'env'), (Join-Path $env:USERPROFILE '.rogue-env'))) {
    if (-not $f -or -not (Test-Path -LiteralPath $f)) { continue }
    $fileVals = @{}
    foreach ($line in (Get-Content -LiteralPath $f)) {
        if ($line -match '^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.+)$') {
            $fileVals[$Matches[1]] = ConvertFrom-ShellQuoted ($Matches[2].Trim())
        }
    }
    if (-not $fileVals['ROGUE_API_KEY']) { continue }
    foreach ($k in $fileVals.Keys) { $creds[$k] = $fileVals[$k] }
    break
}

# Resolved HERE - after the env files are parsed so they can set the interval, and
# before the API-key check below so the ordering cannot regress into reading it too
# early. Reading $env:ROGUE_HEARTBEAT_MIN_INTERVAL at file scope silently ignores
# every env file, and there is no workaround from a user's shell: this script is
# spawned DETACHED, so its process environment comes from Codex.
Initialize-RogueBeacon $creds

$apiKey = $creds['ROGUE_API_KEY']
if (-not $apiKey) { Dbg 'not configured -> no-op'; exit 0 }

$baseUrl = $creds['ROGUE_BASE_URL']; if (-not $baseUrl) { $baseUrl = 'https://api.rogue.security' }
$baseUrl = $baseUrl.TrimEnd('/')

# ── actor resolution (mirrors actor.sh) ────────────────────────────────────
$actorName = $creds['ROGUE_ACTOR_NAME']
if (-not $actorName) { try { $actorName = (& git config --global user.name 2>$null | Out-String).Trim() } catch {} }
if (-not $actorName) { $actorName = $env:USERNAME }

$actorEmail = $creds['ROGUE_ACTOR_EMAIL']
if (-not $actorEmail) { try { $actorEmail = (& git config --global user.email 2>$null | Out-String).Trim() } catch {} }
if (-not $actorEmail) {
    if ($env:USERNAME -and $env:COMPUTERNAME) { $actorEmail = "$($env:USERNAME)@$($env:COMPUTERNAME)" }
    elseif ($env:USERNAME) { $actorEmail = $env:USERNAME } else { $actorEmail = $env:COMPUTERNAME }
}

# ── plugin version (regex from manifest, no python) ────────────────────────
$ver = 'unknown'
$pj = Join-Path $pluginRoot '.codex-plugin\plugin.json'
if (Test-Path -LiteralPath $pj) {
    $m = [regex]::Match((Get-Content -Raw -LiteralPath $pj), '"version"\s*:\s*"([0-9]+\.[0-9]+\.[0-9]+)')
    if ($m.Success) { $ver = $m.Groups[1].Value }
}

# Family is the fixed enum "openai"; surface rides the agent field.
# One table, in scripts/surface.ps1, shared with hook.ps1 - which stamps the same
# slug on each log line and sends it as x-rogue-agent. The literal is a last-resort
# guard for a damaged install, not a second copy of the mapping.
$agent = ''
try {
    $surfaceLib = Join-Path $pluginRoot 'scripts\surface.ps1'
    if (Test-Path -LiteralPath $surfaceLib) {
        . $surfaceLib
        $agent = [string](Get-CodexSurfaceSlug $creds)
    }
} catch { $agent = '' }
if (-not $agent) { $agent = 'codex_cli' }

$host_ = $env:COMPUTERNAME; if (-not $host_) { try { $host_ = [System.Net.Dns]::GetHostName() } catch { $host_ = 'unknown' } }

$body = @{
    agent_family = 'openai'
    agent        = $agent
    version      = $ver
    host         = $host_
    actor_email  = [string]$actorEmail
    actor_name   = [string]$actorName
} | ConvertTo-Json -Compress

# Request-RogueBeaconSlot writes the stamp itself, BEFORE the request - deciding and
# stamping are one call so a caller cannot leave the window permanently open by
# forgetting the second half.
if (Request-RogueBeaconSlot -Slug 'codex' -Unthrottled $beaconUnthrottled) {
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        Invoke-WebRequest -Uri "$baseUrl/api/v1/hooks/status" -Method Post `
            -Headers @{ 'x-rogue-api-key' = $apiKey } -ContentType 'application/json' `
            -Body $bytes -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop | Out-Null
        Dbg 'heartbeat sent'
    } catch { Dbg "heartbeat failed: $($_.Exception.Message)" }
}

# ── ship the hook log ──────────────────────────────────────────────────────
# See plugins/rogue/scripts/heartbeat.ps1 for why this is a separate process
# (in-process, the shipper's `$script:` writes would clobber this file's variables
# and its `exit 0` would kill the heartbeat), why the values travel as environment
# variables (no interpolation to escape) and why the actor is passed in rather than
# re-resolved (a second cascade would key the log's source row differently from the
# roster row just posted).
#
# SLUG `codex`, FAMILY `openai` - they differ here and that is not a mistake: the
# log file is codex.log and the dispatcher writes `provider=codex`, while the
# roster family is `openai`, exactly as this script's own body reports.
$shipScript = Join-Path $pluginRoot 'scripts\ship-logs.ps1'
if (Test-Path -LiteralPath $shipScript) {
    try {
        $env:ROGUE_ACTOR_EMAIL     = [string]$actorEmail
        $env:ROGUE_ACTOR_NAME      = [string]$actorName
        $env:ROGUE_SHIPPER_SCRIPT  = $shipScript
        $env:ROGUE_SHIPPER_ROOT    = $pluginRoot
        $env:ROGUE_SHIPPER_SLUG    = 'codex'
        $env:ROGUE_SHIPPER_VERSION = [string]$ver
        $env:ROGUE_SHIPPER_FAMILY  = 'openai'
        $inner = '& ([scriptblock]::Create((Get-Content -Raw -LiteralPath $env:ROGUE_SHIPPER_SCRIPT)))' +
                 ' $env:ROGUE_SHIPPER_ROOT $env:ROGUE_SHIPPER_SLUG' +
                 ' $env:ROGUE_SHIPPER_VERSION $env:ROGUE_SHIPPER_FAMILY'
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($inner))
        $psExe = 'powershell'
        try { if ((Get-Process -Id $PID).Path) { $psExe = (Get-Process -Id $PID).Path } } catch {}
        Start-Process -FilePath $psExe `
            -ArgumentList '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded `
            -WindowStyle Hidden -ErrorAction Stop | Out-Null
        Dbg 'log shipper started'
    } catch { Dbg "log shipper not started: $($_.Exception.Message)" }
}

exit 0
