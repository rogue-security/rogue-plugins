# Rogue presence heartbeat (Windows / PowerShell) — Kiro plugin.
#
# Native-Windows analogue of heartbeat.sh. Fired (detached, via Start-Process) by
# hook.ps1 from SessionStart and from every Stop. POSTs /api/v1/hooks/status so
# this install shows up in the Coding Agents roster and the org learns which
# plugin version runs. Fire-and-forget: never blocks Kiro, always exits 0.
#
# Takes the surface positionally, as the Antigravity heartbeat does: no Kiro
# payload names it, so the installer fixed it in the hook file and hook.ps1 passes
# it through. The body must carry the same value as the per-event x-rogue-agent
# header or the backend keys two roster rows for one install. The trigger tells
# the beacon whether to throttle: SessionStart never is, Stop (once per TURN) is.
#
# Main-and-functions, like hook.ps1: everything below is a function and only
# `Invoke-Main` runs. Shared state lives in the script-scoped variables declared
# under it, and every write to one is `$script:`-qualified — an unqualified
# assignment inside a function writes to a local copy that vanishes on return.
#
# The validated surface is `$surface`, NOT `$agent`: PowerShell variable names
# are case-insensitive, so a file-scope `$agent = ''` would overwrite the
# `$Agent` parameter before Resolve-Surface ever read it, and every install
# would report kiro_cli. (It did, until the heartbeat was run under test.)
param([string]$Agent = '', [string]$Trigger = 'SessionStart')

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

$pluginRoot = ''
$creds      = @{}
$apiKey     = ''
$baseUrl    = ''
$actorName  = ''
$actorEmail = ''
$ver        = 'unknown'   # plugin version, from plugin.json
$surface    = ''          # which of the three surfaces this install reports for
$kiroVer    = 'unknown'   # the Kiro build itself (kiro-cli --version / the IDE install)
$kiroDefault = ''         # the CLI's default agent, empty off the CLI or when unset

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

# Self-locate from $PSCommandPath (<root>\scripts\heartbeat.ps1); fall back to env, then CWD.
function Resolve-PluginRoot {
    if ($PSCommandPath) { $script:pluginRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent }
    if (-not $script:pluginRoot) { $script:pluginRoot = $env:KIRO_PLUGIN_ROOT }
    if (-not $script:pluginRoot) {
        try { $script:pluginRoot = (Get-Location).Path } catch { $script:pluginRoot = '.' }
    }
}

# ── beacon throttle ────────────────────────────────────────────────────────
# The rule lives in scripts/beacon.ps1, a byte-identical copy of
# scripts/shared/beacon.ps1 shared with the other PowerShell plugins, whose sh
# twin scripts/beacon.sh is what heartbeat.sh loads.
#
# Loaded as a SCRIPTBLOCK from the file's text, never with -File or a path
# dot-source: running a .ps1 directly is subject to ExecutionPolicy and to a
# GPO-enforced policy that -ExecutionPolicy Bypass cannot override.
#
# THE DOT-INVOKE ITSELF CANNOT LIVE IN A FUNCTION (see the Antigravity heartbeat
# for the full reasoning): dot-sourcing runs in the CALLER's scope, so this
# returns the scriptblock and Invoke-Main dot-invokes it.
#
# A missing or unparseable library degrades to an UNTHROTTLED beacon - the safe
# direction: a beacon too often is noise, while a beacon never again is a roster
# row indistinguishable from an uninstalled plugin.
function Get-BeaconLibrary {
    $lib = Join-Path $script:pluginRoot 'scripts\beacon.ps1'
    if (-not (Test-Path -LiteralPath $lib)) { return $null }
    try { return [scriptblock]::Create((Get-Content -Raw -LiteralPath $lib)) } catch { return $null }
}

# ── credential resolution ──────────────────────────────────────────────────
function Import-Credentials {
    $script:creds = @{}
    . ([scriptblock]::Create((Get-Content -Raw -LiteralPath (Join-Path $PluginRoot 'scripts/env-file.ps1'))))
    foreach ($k in 'ROGUE_API_KEY','ROGUE_ACTOR_EMAIL','ROGUE_ACTOR_NAME','ROGUE_BASE_URL',
                   'ROGUE_HEARTBEAT_MIN_INTERVAL') {
        $val = [Environment]::GetEnvironmentVariable($k); if ($val) { $script:creds[$k] = $val }
    }
    # The first env file holding ROGUE_API_KEY is used alone: machine, bundled, user.
    foreach ($f in @('C:\ProgramData\rogue\env', (Join-Path $pluginRoot 'env'), (Join-Path $env:USERPROFILE '.rogue-env'))) {
        if (-not $f -or -not (Test-Path -LiteralPath $f)) { continue }
        $fileVals = @{}
        foreach ($line in (Read-RogueEnvFile $f)) {
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
# Assert-ApiKey so the ordering cannot regress into reading it too early. This
# script is spawned DETACHED, so its process environment comes from Kiro, not from
# the user's shell.
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

# ── plugin version (regex from plugin.json, no python; same source as hook.ps1) ──
function Resolve-Version {
    $pj = Join-Path $pluginRoot 'plugin.json'
    if (Test-Path -LiteralPath $pj) {
        $m = [regex]::Match((Get-Content -Raw -LiteralPath $pj), '"version"\s*:\s*"([0-9]+\.[0-9]+\.[0-9]+)')
        if ($m.Success) { $script:ver = $m.Groups[1].Value }
    }
}

# ── surface: -Agent from hook.ps1, validated against the closed vocabulary
#    because the value ends up in a roster row. Default kiro_cli, which is what
#    the route defaults an unknown x-rogue-agent to as well. ──
function Resolve-Surface {
    if (@('kiro_ide', 'kiro_cli', 'kiro_crew') -ccontains $Agent) { $script:surface = $Agent; return }
    $script:surface = 'kiro_cli'
}

# -- what Kiro itself reports (mirrors scripts/kiro-host.sh) -------------------
# Two versions ride one body: `version` is the plugin's, `agent_version` is the
# Kiro build it runs under, so support can tell a current plugin from a stale
# Kiro once the backend stores the second (it does not yet; see README "Roster
# heartbeat"). The CLI (and Crew, which drives kiro-cli) answers `kiro-cli --version`;
# the IDE has no CLI, so its version is read from the install under
# %LOCALAPPDATA%\Programs\Kiro (ROGUE_KIRO_APP overrides the path for tests).
function Get-KiroCliVersion {
    if (-not (Get-Command kiro-cli -ErrorAction SilentlyContinue)) { return '' }
    try { $out = (& kiro-cli --version 2>$null | Out-String) } catch { return '' }
    $m = [regex]::Match([string]$out, '[0-9]+\.[0-9]+\.[0-9]+')
    if ($m.Success) { return $m.Value }
    return ''
}

function Get-KiroIdeVersion {
    $root = $env:ROGUE_KIRO_APP
    if (-not $root -and $env:LOCALAPPDATA) { $root = Join-Path $env:LOCALAPPDATA 'Programs\Kiro' }
    if (-not $root) { return '' }
    $pkg = Join-Path $root 'resources\app\package.json'
    if (-not (Test-Path -LiteralPath $pkg)) { return '' }
    $m = [regex]::Match((Get-Content -Raw -LiteralPath $pkg), '"version"\s*:\s*"([0-9]+\.[0-9]+\.[0-9]+)')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

# The real CLI prints the value quoted ("rogue") and errors out when none is set.
function Get-KiroDefaultAgent {
    if (-not (Get-Command kiro-cli -ErrorAction SilentlyContinue)) { return '' }
    try { $out = (& kiro-cli settings chat.defaultAgent 2>$null | Out-String) } catch { return '' }
    return ([string]$out).Trim().Trim('"')
}

# After Resolve-Surface: the surface picks which Kiro binary to ask, and only the
# CLI has a default agent (on the 2.x engine only agents carrying the Rogue hooks
# are covered, so a default that moved away from `rogue` is worth showing).
# Called from Send-Heartbeat AFTER the beacon claim: each probe is a kiro-cli
# process, and a throttled Stop must not pay for two of them.
function Resolve-KiroHost {
    switch ($surface) {
        'kiro_ide' { $script:kiroVer = Get-KiroIdeVersion; $script:kiroDefault = '' }
        'kiro_cli' { $script:kiroVer = Get-KiroCliVersion; $script:kiroDefault = Get-KiroDefaultAgent }
        default    { $script:kiroVer = Get-KiroCliVersion; $script:kiroDefault = '' }
    }
    if (-not $script:kiroVer) { $script:kiroVer = 'unknown' }
}

# The /hooks/status body, from the resolved script state. The ONE builder for
# this heartbeat and for status.ps1 (which loads this file through the seam):
# the backend fingerprints a roster row on host|actor|family|agent, so a second
# copy of these fields is a second chance to disagree on a segment and open a
# second row for one install. `default_agent` is absent, not empty, when the
# CLI has none set or the surface is not the CLI: "no field" reads as "not a
# CLI, or none set", which an empty string would blur.
function Get-StatusBody {
    $host_ = $env:COMPUTERNAME
    if (-not $host_) { try { $host_ = [System.Net.Dns]::GetHostName() } catch { $host_ = 'unknown' } }
    $fields = @{
        agent_family = 'kiro'
        agent = $surface
        version = $ver
        agent_version = $kiroVer
        host = $host_
        actor_email = [string]$actorEmail
        actor_name = [string]$actorName
    }
    if ($kiroDefault) { $fields['default_agent'] = $kiroDefault }
    return ($fields | ConvertTo-Json -Compress)
}

# The stamp slug is `kiro`, the log file's name, and NOT $surface: the three
# surfaces share one install and one log, so they must share one throttle window
# too - a per-surface stamp would let a machine with the IDE and the CLI both
# installed beacon twice as often as configured.
#
# Request-RogueBeaconSlot writes the stamp itself, BEFORE the request - deciding and
# stamping are one call so a caller cannot leave the window permanently open by
# forgetting the second half.
function Send-Heartbeat {
    if (-not (Request-RogueBeaconSlot -Slug 'kiro' -Unthrottled ($Trigger -eq 'SessionStart'))) {
        Dbg 'beacon throttled'
        return
    }
    Resolve-KiroHost
    $body = Get-StatusBody

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
# reasoning. This file keeps ALL its state in `$script:` variables, which is
# exactly what an in-process [scriptblock]::Create would resolve against, so the
# shipper's own `$script:` writes would land on this script's state, and its
# `exit 0` would end the heartbeat, not the shipper.
#
# Every value travels as an environment variable, so the command is a constant
# with nothing to escape. The actor is PASSED IN, never re-resolved: a second
# cascade would key the log's source row differently from the roster row just
# posted. No gate is needed: the shipper's own per-file throttle is stamped
# before any upload, so the per-turn calls make no request at all.
function Start-LogShipper {
    $shipScript = Join-Path $script:pluginRoot 'scripts\ship-logs.ps1'
    if (-not (Test-Path -LiteralPath $shipScript)) { return }
    try {
        $env:ROGUE_ACTOR_EMAIL     = [string]$script:actorEmail
        $env:ROGUE_ACTOR_NAME      = [string]$script:actorName
        $env:ROGUE_SHIPPER_SCRIPT  = $shipScript
        $env:ROGUE_SHIPPER_ROOT    = $script:pluginRoot
        $env:ROGUE_SHIPPER_SLUG    = 'kiro'
        $env:ROGUE_SHIPPER_VERSION = [string]$script:ver
        $env:ROGUE_SHIPPER_FAMILY  = 'kiro'
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
    # lose it on return. The stand-ins keep an install whose beacon.ps1 is missing or
    # unparseable on an unthrottled beacon.
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
    Send-Heartbeat     # claims the beacon slot, THEN asks Kiro for its version
    Start-LogShipper
    exit 0
}

# Test seam, as in hook.ps1: `if (-not …)` and never a bare `return`, which would
# unwind a test that dot-sources this file.
if (-not $env:ROGUE_PS_LIB_ONLY) { Invoke-Main }
