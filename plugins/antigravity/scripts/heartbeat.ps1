# Rogue presence heartbeat (Windows / PowerShell) — Google Antigravity plugin.
#
# Native-Windows analogue of heartbeat.sh. Fired (detached, via Start-Process) by
# hook.ps1 - from the first PreInvocation of a CONVERSATION, and from every Stop.
# POSTs /api/v1/hooks/status so this install shows up in the Coding Agents roster
# and the org learns which plugin version runs. Fire-and-forget: never blocks
# Antigravity, always exits 0.
#
# Takes the surface positionally so hook.ps1 can pass what it read off the
# event's transcriptPath (see the surface block below), and the trigger so the
# beacon knows whether to throttle.
#
# TWO TRIGGERS, ONE SCRIPT, as in heartbeat.sh - but Antigravity has no SessionStart
# event, so the mapping is its own and lives in hook.ps1's Invoke-Heartbeat:
# `SessionStart` for the first invocation of a new conversation (never throttled),
# `Stop` for every agent run's end (the per-TURN trigger, throttled). This replaced a
# beacon on every PreInvocation with invocationNum == 0, which looked per-session and
# was not - invocationNum resets on each new prompt.
#
# Main-and-functions, like hook.ps1: everything below is a function and only
# `Invoke-Main` runs. Shared state lives in the script-scoped variables declared
# under it, and every write to one is `$script:`-qualified — an unqualified
# assignment inside a function writes to a local copy that vanishes on return.
param([string]$Agent = '', [string]$Trigger = 'SessionStart')

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

$pluginRoot = ''
$creds      = @{}
$apiKey     = ''
$baseUrl    = ''
$actorName  = ''
$actorEmail = ''
$ver        = 'unknown'   # plugin version, from the bundled VERSION file
$agent      = ''          # which of the three surfaces this install reports for

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

function Initialize-Tls {
    try {
        [Net.ServicePointManager]::SecurityProtocol = `
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {}
}

# Stand down on non-Windows (pwsh on macOS/Linux runs heartbeat.sh instead).
function Stop-OnNonWindows {
    if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { exit 0 }
}

# Self-locate from $PSCommandPath (<root>\scripts\heartbeat.ps1); fall back to CWD.
function Resolve-PluginRoot {
    if ($PSCommandPath) { $script:pluginRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent }
    if (-not $script:pluginRoot) {
        try { $script:pluginRoot = (Get-Location).Path } catch { $script:pluginRoot = '.' }
    }
}

# ── beacon throttle ────────────────────────────────────────────────────────
# The rule lives in scripts/beacon.ps1, a byte-identical copy of
# scripts/shared/beacon.ps1 shared with the other four PowerShell plugins, whose sh
# twin scripts/beacon.sh is what heartbeat.sh loads.
#
# Loaded as a SCRIPTBLOCK from the file's text, never with -File or a path
# dot-source: running a .ps1 directly is subject to ExecutionPolicy and to a
# GPO-enforced policy that -ExecutionPolicy Bypass cannot override.
#
# THE DOT-INVOKE ITSELF CANNOT LIVE IN A FUNCTION, which is why this returns the
# scriptblock instead of loading it. PowerShell dot-sourcing runs in the CALLER's
# scope, so `. $sb` inside a helper defines the library's functions in that helper's
# scope and they vanish when it returns - Send-Heartbeat would then find no
# Request-RogueBeaconSlot at all. Invoke-Main dot-invokes the result, and function
# lookup is dynamic (call-stack based), so everything Invoke-Main calls can see them.
# Verified both halves of that behaviour before relying on it.
#
# A missing or unparseable library degrades to an UNTHROTTLED beacon - today's
# behaviour, and the safe direction: a beacon too often is noise, while a beacon
# never again is a roster row indistinguishable from an uninstalled plugin.
function Get-BeaconLibrary {
    $lib = Join-Path $script:pluginRoot 'scripts\beacon.ps1'
    if (-not (Test-Path -LiteralPath $lib)) { return $null }
    try { return [scriptblock]::Create((Get-Content -Raw -LiteralPath $lib)) } catch { return $null }
}

# ── credential resolution ──────────────────────────────────────────────────
function Import-Credentials {
    $script:creds = @{}
    foreach ($k in 'ROGUE_API_KEY','ROGUE_ACTOR_EMAIL','ROGUE_ACTOR_NAME','ROGUE_BASE_URL',
                   'ROGUE_HEARTBEAT_MIN_INTERVAL') {
        $val = [Environment]::GetEnvironmentVariable($k); if ($val) { $script:creds[$k] = $val }
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
        foreach ($k in $fileVals.Keys) { $script:creds[$k] = $fileVals[$k] }
        break
    }
    $script:apiKey = $script:creds['ROGUE_API_KEY']
}

# Resolved AFTER Import-Credentials so the env files can set the interval, and before
# Assert-ApiKey so the ordering cannot regress into reading it too early. Reading
# $env:ROGUE_HEARTBEAT_MIN_INTERVAL at file scope silently ignores every env file, and
# there is no workaround from a user's shell: this script is spawned DETACHED, so its
# process environment comes from Antigravity.
function Initialize-Beacon {
    Initialize-RogueBeacon $script:creds
}

# Not configured → no-op (mirrors heartbeat.sh).
function Assert-ApiKey {
    if ($apiKey) { return }
    Dbg 'not configured -> no-op'
    exit 0
}

function Resolve-BaseUrl {
    $script:baseUrl = $creds['ROGUE_BASE_URL']
    if (-not $script:baseUrl) { $script:baseUrl = 'https://api.rogue.security' }
    $script:baseUrl = $script:baseUrl.TrimEnd('/')
}

# ── actor resolution (mirrors actor.sh) ────────────────────────────────────
function Resolve-Actor {
    $script:actorName = $creds['ROGUE_ACTOR_NAME']
    if (-not $script:actorName) { try { $script:actorName = (& git config --global user.name 2>$null | Out-String).Trim() } catch {} }
    if (-not $script:actorName) { $script:actorName = $env:USERNAME }

    $script:actorEmail = $creds['ROGUE_ACTOR_EMAIL']
    if (-not $script:actorEmail) { try { $script:actorEmail = (& git config --global user.email 2>$null | Out-String).Trim() } catch {} }
    if (-not $script:actorEmail) {
        if ($env:USERNAME -and $env:COMPUTERNAME) { $script:actorEmail = "$($env:USERNAME)@$($env:COMPUTERNAME)" }
        elseif ($env:USERNAME) { $script:actorEmail = $env:USERNAME } else { $script:actorEmail = $env:COMPUTERNAME }
    }
}

# ── plugin version (from the bundled VERSION file, NOT plugin.json — the
#    Antigravity manifest schema is additionalProperties:false with no
#    version field, so the version lives in its own file at the plugin root) ──
function Resolve-Version {
    $versionFile = Join-Path $pluginRoot 'VERSION'
    if (Test-Path -LiteralPath $versionFile) {
        try {
            $first = Get-Content -LiteralPath $versionFile -TotalCount 1
            if ($first) { $script:ver = $first.Trim() }
        } catch {}
    }
}

# ── surface: -Agent when the caller knows it. hook.ps1 reads it off the event's
#    transcriptPath, the only reliable source — three products (the 2.0 app, the
#    IDE, the `agy` CLI) share one install, so the fallback below cannot
#    tell which is running and picks the CLI whenever it sits alongside another.
#    Validated, not trusted verbatim: the value ends up in a roster row. ──
function Resolve-Surface {
    $script:agent = $Agent
    if (@('antigravity', 'antigravity_ide', 'antigravity_cli') -contains $script:agent) { return }
    # Default to the 2.0 app — the current flagship; flip to the CLI surface if
    # the `agy` binary is on PATH or the CLI's config dir exists.
    $script:agent = 'antigravity'
    $agyCmd = Get-Command agy -ErrorAction SilentlyContinue
    $agyCliDir = Join-Path $env:USERPROFILE '.gemini\antigravity-cli'
    if ($agyCmd -or (Test-Path -LiteralPath $agyCliDir)) { $script:agent = 'antigravity_cli' }
}

# The stamp slug is `antigravity`, the log file's name, and NOT $agent: the three
# surfaces (the 2.0 app, the IDE, the agy CLI) share one install and one log, so they
# must share one throttle window too - a per-surface stamp would let a machine with
# two of them installed beacon twice as often as configured.
#
# Request-RogueBeaconSlot writes the stamp itself, BEFORE the request - deciding and
# stamping are one call so a caller cannot leave the window permanently open by
# forgetting the second half.
function Send-Heartbeat {
    if (-not (Request-RogueBeaconSlot -Slug 'antigravity' -Unthrottled ($Trigger -eq 'SessionStart'))) {
        Dbg 'beacon throttled'
        return
    }

    $host_ = $env:COMPUTERNAME
    if (-not $host_) { try { $host_ = [System.Net.Dns]::GetHostName() } catch { $host_ = 'unknown' } }

    $body = @{
        agent_family = 'antigravity'
        agent        = $agent
        version      = $ver
        host         = $host_
        actor_email  = [string]$actorEmail
        actor_name   = [string]$actorName
    } | ConvertTo-Json -Compress

    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        Invoke-WebRequest -Uri "$baseUrl/api/v1/hooks/status" -Method Post `
            -Headers @{ 'x-rogue-api-key' = $apiKey } -ContentType 'application/json' `
            -Body $bytes -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop | Out-Null
        Dbg 'heartbeat sent'
    } catch { Dbg "heartbeat failed: $($_.Exception.Message)" }
}

# AFTER Send-Heartbeat, deliberately: the heartbeat is what creates or refreshes
# the roster row an uploaded log attaches to.
#
# A SEPARATE PROCESS - see plugins/rogue/scripts/heartbeat.ps1 for the full
# reasoning. It matters more here than anywhere else in this repo: this file is
# main-and-functions and keeps ALL its state in `$script:` variables, which is
# exactly what an in-process [scriptblock]::Create would resolve against, so the
# shipper's own `$script:stateKey` / `$script:offset` writes would land on this
# script's own state. Its `exit 0` would also end the heartbeat, not the shipper.
#
# Every value travels as an environment variable, so the command is a constant with
# nothing to escape. The actor is PASSED IN, never re-resolved: Resolve-Actor
# already ran a cascade of its own, and a second one inside the shipper would key
# the log's source row differently from the roster row just posted.
#
# This runs once per USER TURN (from the Stop trigger) plus once at the start of a
# conversation. No gate is needed: the shipper's own 15-minute per-file throttle is
# stamped before any upload, so the extra calls make no request at all. It is also
# deliberately outside the beacon throttle - a throttled beacon still means a turn
# happened, and the log is worth draining either way.
function Start-LogShipper {
    $shipScript = Join-Path $script:pluginRoot 'scripts\ship-logs.ps1'
    if (-not (Test-Path -LiteralPath $shipScript)) { return }
    try {
        $env:ROGUE_ACTOR_EMAIL     = [string]$script:actorEmail
        $env:ROGUE_ACTOR_NAME      = [string]$script:actorName
        $env:ROGUE_SHIPPER_SCRIPT  = $shipScript
        $env:ROGUE_SHIPPER_ROOT    = $script:pluginRoot
        $env:ROGUE_SHIPPER_SLUG    = 'antigravity'
        $env:ROGUE_SHIPPER_VERSION = [string]$script:ver
        $env:ROGUE_SHIPPER_FAMILY  = 'antigravity'
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

# ── main ───────────────────────────────────────────────────────────────────
# Same order as heartbeat.sh: stand down, configure, then fire and forget.
function Invoke-Main {
    Initialize-Tls
    Stop-OnNonWindows
    Resolve-PluginRoot

    # Dot-invoked HERE and not in a helper: dot-sourcing runs in the caller's scope,
    # so a `. $sb` one call deeper would define the library in that helper's scope and
    # lose it on return. Function lookup is dynamic, so defining them in this scope is
    # enough for everything below to see them. The stand-ins keep an install whose
    # beacon.ps1 is missing or unparseable on today's unthrottled behaviour.
    $beaconLib = Get-BeaconLibrary
    if ($beaconLib) { . $beaconLib }
    if (-not (Get-Command Request-RogueBeaconSlot -ErrorAction SilentlyContinue)) {
        function Initialize-RogueBeacon { param([hashtable]$Creds = @{}) }
        function Request-RogueBeaconSlot { param([string]$Slug, [bool]$Unthrottled = $false) return $true }
    }

    Import-Credentials
    Initialize-Beacon  # after the env files are parsed so they can set the interval
    Assert-ApiKey      # exits 0 when this install is not configured
    Resolve-BaseUrl
    Resolve-Actor
    Resolve-Version
    Resolve-Surface
    Send-Heartbeat
    Start-LogShipper
    exit 0
}

# Test seam, as in hook.ps1: `if (-not …)` and never a bare `return`, which would
# unwind a test that dot-sources this file.
if (-not $env:ROGUE_PS_LIB_ONLY) { Invoke-Main }
