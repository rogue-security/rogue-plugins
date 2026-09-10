# Rogue Security hook bridge for OpenAI Codex — PowerShell implementation.
#
# Cross-platform sibling of hook.sh. hooks.json fires a bash `command` on
# macOS/Linux and this `commandWindows` on Windows. PURE RELAY: reads one Codex
# hook event JSON on stdin, POSTs it to /api/v1/hooks/openai, relays the native
# Codex response verbatim. Unlike the Claude bridge there is NO block-detection
# and NO security-alert modal — Codex surfaces the native deny shape itself.
#
# Fail-open everywhere: missing API key, network error, non-200, empty body all
# yield `{}` on stdout, exit 0. A Codex session must never break because Rogue
# infrastructure is unavailable.
#
# Credential resolution: the first env file holding ROGUE_API_KEY is used alone,
# and its values override the process env:
#   1. C:\ProgramData\rogue\env    (machine, MDM-provisioned; mirrors /etc/rogue/env)
#   2. ${PLUGIN_ROOT}\env          (bundled into a compiled customer plugin)
#   3. %USERPROFILE%\.rogue-env    (user / installer-written)

param([string]$EventName = '')

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

function Write-Raw {
    param([string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $stdout = [Console]::OpenStandardOutput()
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
}
function Dbg { param([string]$Msg) if ($env:ROGUE_DEBUG) { [Console]::Error.WriteLine("[rogue] $Msg") } }

function ConvertFrom-ShellQuoted {
    # Decode one shell "word" the way hook.sh would when it sources the env file,
    # so values round-trip across both bridges (POSIX single-quoted or bash %q).
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

# ── logging ────────────────────────────────────────────────────────────────
# ONE FILE PER AGENT (mirrors hook.sh). Every Rogue plugin shares ~/.rogue, so a
# machine running Codex + Claude Code + Cursor + … used to interleave all of them
# into a single hook.log with no way to tell whose line was whose.
#
# Resolved by Initialize-Logging AFTER the credential files are parsed, exactly
# like hook.sh resolves these after sourcing them — so `~/.rogue-env`,
# `C:\ProgramData\rogue\env` (MDM) and a bundled `env` can all relocate the log.
# Reading $env: directly here instead would silently ignore every one of those
# files, which is a real defect for a fleet that relocates logs by policy AND
# would make the log shipper and the dispatcher disagree on the path.
# Declared (not resolved) at file scope so the ROGUE_PS_LIB_ONLY seam below can
# dot-source the helpers, and so Log is safe to call before initialisation.
# Which SURFACE of Codex wrote each line - codex_app or codex_cli. Resolved from
# the credential map (scripts/surface.ps1), the same table heartbeat.ps1 reads, so a
# log line and the roster row for one session cannot name different surfaces. Empty
# OMITS the token; it is never written as `surface=` or `surface=unknown`.
$script:surface = ''
$script:logFile = $null
$script:logMaxBytes = 10485760

function Initialize-Logging {
    # $Creds is the resolved credential map (process env, then the chosen env file
    # over it), so precedence is already correct by the time we read it.
    # $HOME backs up USERPROFILE so this also works dot-sourced on macOS/Linux.
    param([hashtable]$Creds = @{})
    $f = $Creds['ROGUE_LOG_FILE']
    if (-not $f) {
        $d = $Creds['ROGUE_LOG_DIR']
        if (-not $d) {
            $userHome = $env:USERPROFILE
            if (-not $userHome) { $userHome = $HOME }
            if ($userHome) { $d = Join-Path (Join-Path $userHome '.rogue') 'logs' }
        }
        if ($d) { $f = Join-Path $d 'codex.log' }
    }
    $script:logFile = $f
    # Size cap. Over it, the current log is renamed to <file>.1 - exactly one
    # generation kept, so worst case on disk is 2x this. A NUMERIC ZERO disables
    # rotation; a NON-NUMERIC value falls back to this default, so a typo can
    # never leave the log growing unbounded ([int64]'00' is 0, so a zero-padded
    # zero disables too — matching hook.sh's `-gt 0` test).
    $cap = $Creds['ROGUE_LOG_MAX_BYTES']
    # TryParse, NOT a plain [int64] cast: the cast raises "Value was either too
    # large or too small for an Int64" on an all-digit value too wide for 64
    # bits. The file-scope $ErrorActionPreference = 'SilentlyContinue' swallows
    # that error and the assignment is skipped, so the cap happens to keep its
    # default - the right answer, but reached by accident and invisible if the
    # preference ever changes. TryParse states the fallback instead, and keeps
    # this reading like the other two dispatchers, where the same input IS a
    # live bug (sh disables rotation, Node yields Infinity). '00' still parses
    # to 0, so a zero-padded zero keeps disabling rotation.
    $capValue = [int64]0
    if ($cap -match '^[0-9]+$' -and [int64]::TryParse($cap, [ref]$capValue)) { $script:logMaxBytes = $capValue }
    else { $script:logMaxBytes = 10485760 }
}

function Sanitize { param([string]$S) if ($null -eq $S) { return '' } ($S -replace '[\x00-\x1f\x7f]', '') }

# Rotation is enforced on the WRITE PATH rather than by a periodic job because an
# UNCONFIGURED install writes a line per event and never runs anything else - a
# cap enforced anywhere else would not hold.
function Rotate-Log {
    if (-not $logFile -or $logMaxBytes -le 0) { return }
    try {
        $fi = Get-Item -LiteralPath $logFile -ErrorAction SilentlyContinue
        if ($fi -and $fi.Length -ge $logMaxBytes) {
            # Delete the previous generation first: `Move-Item -Force` onto an
            # EXISTING destination is not reliable on Windows PowerShell 5.1, and
            # with -ErrorAction SilentlyContinue a failure here would silently
            # stop all further rotation and let the live log grow unbounded.
            Remove-Item -LiteralPath "$logFile.1" -Force -ErrorAction SilentlyContinue
            Move-Item -LiteralPath $logFile -Destination "$logFile.1" -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

function Log {
    param([string]$Msg)
    try {
        if (-not $logFile) { return }
        $dir = Split-Path $logFile
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Rotate-Log
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        # AppendAllText with an explicit BOM-less UTF-8, NOT `Add-Content -Encoding
        # UTF8`: on Windows PowerShell 5.1 that switch writes a UTF-8 BOM when it
        # creates the file, so the first line of every new log (and of every file
        # produced by a rotation) would start with EF BB BF and fail any parser
        # that anchors on the timestamp. "`n" keeps the line ending identical to
        # what the sh dispatchers write, so one log format covers both platforms.
        # Empty slug -> empty string, so the line is byte-identical to what an
        # older version wrote. Optional means optional.
        $surfaceToken = if ($script:surface) { " surface=$($script:surface)" } else { '' }
        [System.IO.File]::AppendAllText(
            $logFile,
            "$stamp provider=codex$surfaceToken event=$EventName $Msg`n",
            (New-Object System.Text.UTF8Encoding $false))
    } catch {}
}

# Test seam: dot-sourcing with ROGUE_PS_LIB_ONLY=1 loads the functions above
# (e.g. ConvertFrom-ShellQuoted, Rotate-Log) without running the dispatcher.
# Production never sets this, so the hook always runs its main body.
if ($env:ROGUE_PS_LIB_ONLY) { return }

# Windows PowerShell 5.1 may negotiate only TLS 1.0/1.1 by default; add TLS 1.2.
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

# Stand down on non-Windows (pwsh on macOS/Linux runs hook.sh instead).
if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { Write-Raw '{}'; exit 0 }

if (-not $EventName) { Write-Raw '{}'; exit 0 }
Dbg "event=$EventName"

$pluginRoot = $env:PLUGIN_ROOT
if (-not $pluginRoot) { try { $pluginRoot = (Get-Location).Path } catch { $pluginRoot = '.' } }

# ── credential resolution ──────────────────────────────────────────────────
$creds = @{}
foreach ($k in 'ROGUE_API_KEY','ROGUE_ACTOR_EMAIL','ROGUE_ACTOR_NAME','ROGUE_BASE_URL','ROGUE_API_URL','ROGUE_CODEX_SURFACE',
               'ROGUE_LOG_FILE','ROGUE_LOG_DIR','ROGUE_LOG_MAX_BYTES') {
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

# Logging is initialised HERE - after the credential files are parsed, so they can
# relocate the log - but BEFORE the API-key check below, so an unconfigured
# install still records `outcome=unconfigured`.
# Before the first Log call, so even an unconfigured install stamps the surface.
# Guarded on both sides: a damaged install with no surface.ps1, or a resolver that
# throws, leaves the slug empty and the token is omitted - logging must never change
# the hook's outcome.
try {
    $surfaceLib = Join-Path $pluginRoot 'scripts\surface.ps1'
    if (Test-Path -LiteralPath $surfaceLib) {
        . $surfaceLib
        $script:surface = [string](Get-CodexSurfaceSlug $creds)
    }
} catch { $script:surface = '' }

Initialize-Logging $creds
Dbg "logFile=$logFile cap=$logMaxBytes"

$apiKey = $creds['ROGUE_API_KEY']
if (-not $apiKey) {
    # warn.ps1 owns the SessionStart "Not configured" systemMessage (a separate
    # hooks.json entry fires it), so stay silent here to avoid a double banner.
    Log "outcome=unconfigured"
    Write-Raw '{}'
    exit 0
}

# Reuse the slug resolved above, so the header, the log token and the roster row are
# one value. The fallback covers a damaged install where surface.ps1 was missing:
# the header has always carried a surface and must keep carrying one, where the log
# token is optional.
$surface = $script:surface
if (-not $surface) { $surface = 'codex_cli' }

# URL: explicit ROGUE_API_URL wins, else base + path.
$url = $creds['ROGUE_API_URL']
if (-not $url) {
    $baseUrl = $creds['ROGUE_BASE_URL']; if (-not $baseUrl) { $baseUrl = 'https://api.rogue.security' }
    $url = "$($baseUrl.TrimEnd('/'))/api/v1/hooks/openai"
}

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

# ── per-turn presence heartbeat + log ship (Stop only) ─────────────────────
# The PowerShell twin of hook.sh's Stop block. SessionStart's heartbeat is spawned by
# hooks.json; this is its per-TURN sibling, fired from HERE rather than from a second
# hooks.json entry because Codex hashes the whole hook definition and skips untrusted
# command hooks until reviewed via /hooks - a new entry would silently disable every
# Rogue hook on every existing install until each user re-approved. heartbeat.ps1
# throttles the beacon itself (scripts/beacon.ps1, 900s default) and the shipper
# throttles itself, so a per-turn trigger is not a per-turn request.
#
# A SEPARATE, HIDDEN PROCESS, for the same two reasons every PowerShell caller in
# this repo spawns one: in-process, heartbeat.ps1's `$script:` writes would land on
# this dispatcher's variables and its `exit 0` would end the dispatcher before it
# relays the response. -EncodedCommand with the path in an env var, so the command is
# a constant with nothing to escape (Start-Process -ArgumentList quoting is
# unreliable on Windows PowerShell 5.1). Start-Process without -Wait returns
# immediately, so the relayed decision below is never delayed.
#
# PLUGIN_ROOT is set explicitly for the child: everything heartbeat.ps1 needs hangs
# off it (bundled env file, surface.ps1, the manifest version, the shipper), and
# $pluginRoot here may have come from the Get-Location fallback rather than the
# environment. Writing $env: in the dispatcher is safe - it only adds what the child
# reads, and this process exits a few lines below.
if ($EventName -eq 'Stop') {
    $hbScript = Join-Path $pluginRoot 'scripts\heartbeat.ps1'
    if (Test-Path -LiteralPath $hbScript) {
        try {
            $env:PLUGIN_ROOT          = $pluginRoot
            $env:ROGUE_HEARTBEAT_SCRIPT = $hbScript
            $hbInner = '& ([scriptblock]::Create((Get-Content -Raw -LiteralPath' +
                       ' $env:ROGUE_HEARTBEAT_SCRIPT))) Stop'
            $hbEncoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($hbInner))
            $hbExe = 'powershell'
            try { if ((Get-Process -Id $PID).Path) { $hbExe = (Get-Process -Id $PID).Path } } catch {}
            Start-Process -FilePath $hbExe `
                -ArgumentList '-NoProfile', '-NonInteractive', '-EncodedCommand', $hbEncoded `
                -WindowStyle Hidden -ErrorAction Stop | Out-Null
            Dbg 'stop heartbeat started'
        } catch { Dbg "stop heartbeat not started: $($_.Exception.Message)" }
    }
}
# ── install identity: host + version ───────────────────────────────────────
# The fleet roster keys an install on host + actor + family + agent ($surface
# above), and until now only heartbeat.ps1 ever sent host and version, once, at
# session start. A session still working a day later therefore aged out as
# disconnected. Sending them as headers on EVERY event lets the backend refresh
# this exact row from ordinary hook traffic. Resolved exactly as heartbeat.ps1
# does (its sh sibling shares scripts/install-id.sh instead; PowerShell has no
# such seam here). Any drift between the two is a duplicate roster row.
$installError = @()
$hostName = $env:COMPUTERNAME
if (-not $hostName) { try { $hostName = [System.Net.Dns]::GetHostName() } catch { $hostName = '' } }
if (-not $hostName) { $hostName = 'unknown'; $installError += 'host-unresolved' }

$pluginVersion = 'unknown'
$pluginJson = Join-Path $pluginRoot '.codex-plugin\plugin.json'
if (Test-Path -LiteralPath $pluginJson) {
    $m = [regex]::Match((Get-Content -Raw -LiteralPath $pluginJson), '"version"\s*:\s*"([0-9]+\.[0-9]+\.[0-9]+)')
    if ($m.Success) { $pluginVersion = $m.Groups[1].Value }
    # Manifest is there but carries no semver: schema drift, not a bad install.
    else { $installError += "version-unparsed:$pluginJson" }
} else {
    $installError += "manifest-missing:$pluginJson"
}
# A degraded value is still SENT rather than failing the hook: it identifies the
# install well enough to keep the roster fresh, and no liveness bookkeeping is
# worth breaking a session over. But "unknown" in the roster is a real symptom,
# so it is reported as an error once per event.
if ($installError.Count) { Log "error=install-id $($installError -join ',')" }


# ── payload from stdin (recover UTF-8, strip BOM) ──────────────────────────
$payload = [Console]::In.ReadToEnd()
if (-not $payload) { $payload = '{}' }
try {
    $raw = [Console]::InputEncoding.GetBytes($payload)
    $payload = [System.Text.Encoding]::UTF8.GetString($raw)
} catch {}
$payload = $payload.TrimStart([char]0xFEFF)

# ── POST (fail-open) → relay verbatim ──────────────────────────────────────
$headers = @{
    'x-rogue-api-key'     = $apiKey
    'x-rogue-event'       = $EventName
    'x-rogue-agent'       = $surface
    'x-rogue-actor-email' = $actorEmail
    'x-rogue-actor-name'  = $actorName
    'x-rogue-host'        = $hostName
    'x-rogue-version'     = $pluginVersion
}
$bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
$resp = ''
try {
    $r = Invoke-WebRequest -Uri $url -Method Post `
        -Headers $headers -ContentType 'application/json' -Body $bodyBytes `
        -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
    if ($r.StatusCode -eq 200) {
        try { $resp = [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) }
        catch { $resp = [string]$r.Content }
    }
} catch { Dbg "POST failed: $($_.Exception.Message)"; $resp = '' }

$respHead = if ($resp.Length -gt 400) { $resp.Substring(0, 400) } else { $resp }
Log "raw=$(Sanitize $respHead)"

if (-not $resp) { Write-Raw '{}'; exit 0 }
Write-Raw $resp
exit 0
