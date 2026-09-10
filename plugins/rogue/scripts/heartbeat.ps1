# Rogue presence heartbeat (Windows / PowerShell).
#
# Native-Windows analogue of heartbeat.sh. Fired (detached) from SessionStart and
# from Stop. POSTs /api/v1/hooks/status so this install shows up in the dashboard's
# Coding Agents roster and so the org learns which plugin version is running. Pure
# side-effect: fire-and-forget, never blocks Claude Code, always exits 0.
#
# Credential resolution mirrors hook.ps1: the first env file holding ROGUE_API_KEY
# is used alone (machine, bundled, user) and overrides the process env.
#
# TWO TRIGGERS, ONE SCRIPT, exactly as in heartbeat.sh. SessionStart fires once per
# session; Stop fires once per TURN, so its beacon is throttled. Keep the two
# halves in lockstep: the throttle interval, the stamp path and the
# SessionStart-is-never-throttled rule all have to agree, or a machine's beacon
# cadence would depend on its operating system.

# Must precede every statement, so it sits above $ErrorActionPreference. The
# default keeps an older hooks.json - which passes no argument - behaving exactly
# as it does today.
param([string]$Trigger = 'SessionStart')

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

function Dbg { param([string]$Msg) if ($env:ROGUE_DEBUG) { [Console]::Error.WriteLine("[rogue-heartbeat] $Msg") } }

# ── beacon throttle ────────────────────────────────────────────────────────
# Mirrors heartbeat.sh stage for stage, and now literally so: the rule itself lives
# in scripts/beacon.ps1, a byte-identical copy of scripts/shared/beacon.ps1 shared
# with the other four PowerShell plugins, whose sh twin scripts/beacon.sh is what
# heartbeat.sh loads. Same arrangement as ship-logs.ps1, and for the same reason -
# all six plugins now beacon on a per-turn trigger, and eleven hand-written copies
# of these semantics would drift silently in one of two directions, "no beacon ever
# again" or "a beacon on every turn". Every per-plugin difference is an argument:
# the stamp slug, and whether this trigger is the session one.
#
# SessionStart is never throttled: it fires once per session, and a brand-new
# session is exactly when the roster most wants the update. Only the per-turn
# trigger is rate-limited.
#
# The plugin root and the library load sit UP HERE, above the credential loading and
# above the ROGUE_PS_LIB_ONLY seam, so the tests can exercise the real wiring - the
# library that actually ships, not a stand-in - without the load running a beacon.
# Both are pure: reading an env var and defining functions.
$pluginRoot = $env:CLAUDE_PLUGIN_ROOT
if (-not $pluginRoot) { try { $pluginRoot = (Get-Location).Path } catch { $pluginRoot = '.' } }

# The param() lands in the caller's scope when this file is dot-sourced, so the
# trigger is copied to a $script: variable. PowerShell variable names are
# case-insensitive, which is exactly how the tests' own -Trigger parameter would
# otherwise be clobbered.
$script:trigger = $Trigger
$script:beaconUnthrottled = ($script:trigger -eq 'SessionStart')

# Loaded as a SCRIPTBLOCK from the file's text, never dot-sourced by path and never
# with -File: running a .ps1 directly is subject to ExecutionPolicy and to a
# GPO-enforced policy that -ExecutionPolicy Bypass cannot override. Dot-invoking the
# scriptblock defines the library's functions in THIS scope with no policy involved,
# the same trick hooks.json uses for the dispatchers.
#
# A missing or unparseable library degrades to an UNTHROTTLED beacon - today's
# behaviour on every plugin, and the safe direction: a beacon too often is noise,
# while a beacon never again is a roster row indistinguishable from an uninstalled
# plugin.
$beaconLib = Join-Path $pluginRoot 'scripts\beacon.ps1'
if (Test-Path -LiteralPath $beaconLib) {
    try { . ([scriptblock]::Create((Get-Content -Raw -LiteralPath $beaconLib))) } catch { }
}
if (-not (Get-Command Request-RogueBeaconSlot -ErrorAction SilentlyContinue)) {
    function Initialize-RogueBeacon { param([hashtable]$Creds = @{}) }
    function Request-RogueBeaconSlot { param([string]$Slug, [bool]$Unthrottled = $false) return $true }
}

# Test seam: everything above is pure and safe to dot-source on any platform;
# everything below reads credentials and POSTs. Same seam hook.ps1 uses.
if ($env:ROGUE_PS_LIB_ONLY) { return }

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

function Test-SyntheticActor {
    # Duplicated from hook.ps1 (heartbeat.ps1 is standalone, like its copy of
    # ConvertFrom-ShellQuoted). Keep in lockstep with actor.sh's
    # _rogue_is_synthetic: empty/whitespace, "claude", "claude code" and
    # "noreply@anthropic.com" are the sandbox identity, never a human.
    param([string]$Value)
    if ($null -eq $Value) { return $true }
    $v = ($Value -replace '\s+', ' ').Trim().ToLowerInvariant()
    return ($v -eq '' -or $v -eq 'claude' -or $v -eq 'claude code' -or $v -eq 'noreply@anthropic.com')
}

function Select-ActorValue {
    param([string[]]$Candidates)
    if ($null -eq $Candidates) { return '' }
    foreach ($c in $Candidates) { if (-not (Test-SyntheticActor $c)) { return $c } }
    return ''
}

try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

# Stand down on non-Windows (pwsh on macOS/Linux runs heartbeat.sh instead).
if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { exit 0 }
# CLAUDE_CODE_ENTRYPOINT used to `exit 0` right here. It now guards only the beacon
# POST below, in lockstep with heartbeat.sh: this script also ships the hook log, and
# the entrypoint decides whether there is a SESSION to report presence for, which is
# a different question from whether the log on disk is worth uploading. Behaviour of
# the beacon itself is unchanged - it still fires exactly when it did.
# ($pluginRoot was resolved above the seam, because the beacon library loads from it.)

# -- credential resolution --------------------------------------------------
$creds = @{}
foreach ($k in 'ROGUE_API_KEY','ROGUE_ACTOR_EMAIL','ROGUE_ACTOR_NAME','ROGUE_BASE_URL',
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

# Resolved HERE - after the env files are parsed so they can set it, and before the
# API-key check below so the ordering cannot regress into reading it too early again.
Initialize-RogueBeacon $creds

$apiKey = $creds['ROGUE_API_KEY']
if (-not $apiKey) { Dbg 'not configured -> no-op'; exit 0 }

$baseUrl = $creds['ROGUE_BASE_URL']; if (-not $baseUrl) { $baseUrl = 'https://api.rogue.security' }
$baseUrl = $baseUrl.TrimEnd('/')

# -- actor resolution (mirrors actor.sh / hook.ps1: first non-synthetic wins) -
# Screen the WHOLE address before splitting it. Taking the local-part first
# smuggles the sandbox identity past the screen: noreply@anthropic.com is
# rejected as an email, but its local-part "noreply" is not on the list.
$hostMail = Select-ActorValue @($env:CLAUDE_CODE_USER_EMAIL)
$actorName = Select-ActorValue @(
    $creds['ROGUE_ACTOR_NAME'],
    (($hostMail -split '@')[0])
)
if (-not $actorName) {
    $gitName = ''
    try { $gitName = (& git config --global user.name 2>$null | Out-String).Trim() } catch {}
    # POSIX ends this cascade at `whoami`. Windows deliberately does NOT shell out
    # to whoami.exe: its output is DOMAIN\user, a different identity string that
    # would re-fingerprint every existing roster row, and it costs a process per
    # hook. [Environment]::UserName is the true twin — it reads the process token,
    # so it still answers in the service contexts where USERNAME is unset.
    $actorName = Select-ActorValue @($gitName, $env:USERNAME, [Environment]::UserName)
}
if (-not $actorName) { $actorName = 'unknown' }

$actorEmail = Select-ActorValue @($creds['ROGUE_ACTOR_EMAIL'], $env:CLAUDE_CODE_USER_EMAIL)
if (-not $actorEmail) {
    $gitEmail = ''
    try { $gitEmail = (& git config --global user.email 2>$null | Out-String).Trim() } catch {}
    $actorEmail = Select-ActorValue @($gitEmail)
}
if (-not $actorEmail) {
    # Same fallback the roster host below already uses: COMPUTERNAME can be unset
    # in service contexts, where the sh twin's `hostname` still answers.
    $dnsHost = ''
    try { $dnsHost = [System.Net.Dns]::GetHostName() } catch {}
    $hostForActor = Select-ActorValue @($env:COMPUTERNAME, $dnsHost)
    if ($hostForActor) { $actorEmail = "unknown@$hostForActor" } else { $actorEmail = 'unknown' }
}

# -- plugin version (regex from manifest, no python) ------------------------
$ver = 'unknown'
$pj = Join-Path $pluginRoot '.claude-plugin\plugin.json'
if (Test-Path -LiteralPath $pj) {
    $m = [regex]::Match((Get-Content -Raw -LiteralPath $pj), '"version"\s*:\s*"([0-9]+\.[0-9]+\.[0-9]+)')
    if ($m.Success) { $ver = $m.Groups[1].Value }
}

# -- agent display label from entrypoint (family is the fixed enum "claude") -
# One table, in scripts/surface.ps1, shared with hook.ps1 - which stamps the
# matching SLUG on each log line and sends this same id as x-rogue-agent. Two
# copies of this mapping would eventually drift, and a log line naming a different
# surface than the roster row for the same session is worse than a line that names
# none. That table also checks CLAUDE_CODE_IS_COWORK FIRST: Cowork spawns Claude
# Code with CLAUDE_CODE_ENTRYPOINT=local-agent, so entrypoint matching alone
# reported every LOCAL Cowork install under the CLI surface.
#
# It answers a surface ID, not a display label: the id doubles as the backend's
# latest-version key (PLUGIN_REPOS), which a label never matched - so every Claude
# row carried update_available=false however old the install was. The literal below
# is a last-resort guard for a damaged install, not a second copy of the mapping.
$agent = ''
try {
    $surfaceLib = Join-Path $pluginRoot 'scripts\surface.ps1'
    if (Test-Path -LiteralPath $surfaceLib) {
        . $surfaceLib
        $agent = [string](Get-RogueSurfaceAgentId)
    }
} catch { $agent = '' }
if (-not $agent) { $agent = 'claude_code' }

$host_ = $env:COMPUTERNAME; if (-not $host_) { try { $host_ = [System.Net.Dns]::GetHostName() } catch { $host_ = 'unknown' } }

$body = @{
    agent_family = 'claude'
    agent        = $agent
    version      = $ver
    host         = $host_
    actor_email  = [string]$actorEmail
    actor_name   = [string]$actorName
} | ConvertTo-Json -Compress

# The beacon, and ONLY the beacon, is gated on there being a session (see the note
# where that check used to live). Request-RogueBeaconSlot writes the stamp itself,
# BEFORE the request below - deciding and stamping are one call so a caller cannot
# leave the window permanently open by forgetting the second half.
if ($env:CLAUDE_CODE_ENTRYPOINT -and
    (Request-RogueBeaconSlot -Slug 'claude' -Unthrottled $script:beaconUnthrottled)) {
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        Invoke-WebRequest -Uri "$baseUrl/api/v1/hooks/status" -Method Post `
            -Headers @{ 'x-rogue-api-key' = $apiKey } -ContentType 'application/json' `
            -Body $bytes -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop | Out-Null
        Dbg 'heartbeat sent'
    } catch { Dbg "heartbeat failed: $($_.Exception.Message)" }
}

# ── ship the hook log ──────────────────────────────────────────────────────
# AFTER the status POST when both run, for the same reason as heartbeat.sh: the
# beacon creates or refreshes this install's roster row, so this order means it
# exists before the logs land. An ordering preference, NOT a prerequisite - the
# backend resolves-or-creates the log source from the identity fields the shipper
# sends - which is why shipping sits OUTSIDE the gate above.
#
# A SEPARATE PROCESS, not an in-process scriptblock, for two concrete reasons:
#   * a scriptblock created here resolves `$script:` against THIS file's scope, so
#     ship-logs.ps1's own $script:creds / $script:offset / $script:stateKey writes
#     would land on this script's variables;
#   * ship-logs.ps1 ends in `exit 0`, which in-process would terminate the
#     heartbeat instead of the shipper.
# The child loads it via [scriptblock]::Create so ExecutionPolicy/GPO never
# applies - the same trick hooks.json uses for the dispatchers, and the reason
# -File is not used anywhere in this repo.
#
# EVERY VALUE TRAVELS AS AN ENVIRONMENT VARIABLE and the command itself is a
# constant, so there is no string interpolation to escape: a plugin path or a
# version containing a quote cannot alter the command. -EncodedCommand for the
# same reason - Start-Process's -ArgumentList quoting is unreliable on Windows
# PowerShell 5.1 for anything containing spaces.
#
# The actor is PASSED IN, never re-resolved: this script resolved it into ordinary
# locals through a cascade of its own, and a second cascade inside the shipper
# would key the log's source row differently from the roster row just posted, so
# the logs would attach to nothing. Writing $env: here is safe - this process
# exits immediately below.
$shipScript = Join-Path $pluginRoot 'scripts\ship-logs.ps1'
if (Test-Path -LiteralPath $shipScript) {
    try {
        $env:ROGUE_ACTOR_EMAIL     = [string]$actorEmail
        $env:ROGUE_ACTOR_NAME      = [string]$actorName
        $env:ROGUE_SHIPPER_SCRIPT  = $shipScript
        $env:ROGUE_SHIPPER_ROOT    = $pluginRoot
        $env:ROGUE_SHIPPER_SLUG    = 'claude'
        $env:ROGUE_SHIPPER_VERSION = [string]$ver
        $env:ROGUE_SHIPPER_FAMILY  = 'claude'
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
