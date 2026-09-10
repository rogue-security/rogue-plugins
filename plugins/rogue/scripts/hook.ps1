# Rogue Security hook dispatcher for Claude Code - PowerShell implementation.
#
# Cross-platform sibling of hook.sh. hooks.json fires BOTH an `sh` entry and a
# PowerShell entry for every event; exactly one does real work per machine:
#
#   * macOS / Linux / WSL         -> hook.sh runs (curl POST); `powershell` is
#                                   absent so this entry fails to spawn.
#   * native Windows + Git Bash   -> hook.sh STANDS DOWN (uname is MINGW/MSYS/
#                                   CYGWIN) so this script owns Windows.
#   * native Windows, no Git Bash -> `sh` is not found (clean fail-open); this
#                                   script runs.
#
# hooks.json loads this WITHOUT -File so the PowerShell ExecutionPolicy never
# applies (running a scriptblock built from a string is not subject to policy,
# unlike invoking a .ps1 on disk - this also survives a GPO-enforced policy,
# which -ExecutionPolicy Bypass does not):
#
#   powershell -NoProfile -NonInteractive -Command \
#     "& ([scriptblock]::Create((Get-Content -Raw -LiteralPath (Join-Path (Get-Item Env:CLAUDE_PLUGIN_ROOT).Value 'scripts/hook.ps1')))) <Event>" ; exit 0
#
# CLAUDE_PLUGIN_ROOT is a process ENVIRONMENT VARIABLE, read dollar-free as
# (Get-Item Env:CLAUDE_PLUGIN_ROOT).Value - on Windows-with-Git-Bash the whole
# command string is parsed by bash first, which would expand and mangle a
# double-quoted $env:CLAUDE_PLUGIN_ROOT.
#
# This script mirrors hook.sh stage-for-stage: collect creds, resolve actor,
# POST stdin to /api/v1/hooks/claude, detect + log a block decision, relay the
# server response verbatim, and — on Claude Cowork ONLY, where the client shows
# no hook-authored text — fire a native modal carrying the reason as a
# side-channel (see Test-WantAlert). The CLI and the Desktop app render blocks
# themselves and deliberately get no modal.
#
# Fail-open everywhere: missing API key, network error, non-200, empty body all
# yield `{}` on stdout, exit 0. Claude Code must never block because Rogue
# infrastructure is unavailable.
#
# Credential resolution, the Windows analogue of hook.sh's search: the first env
# file holding ROGUE_API_KEY is used alone, and its values override the process env:
#   1. C:\ProgramData\rogue\env    (machine, MDM-provisioned; mirrors /etc/rogue/env)
#   2. ${CLAUDE_PLUGIN_ROOT}\env   (bundled into a compiled customer plugin)
#   3. %USERPROFILE%\.rogue-env    (user / installer-written)

param([string]$EventName = '')

$ErrorActionPreference = 'SilentlyContinue'
# Invoke-WebRequest renders a progress bar that, when stdout/stderr is redirected
# (always true under a hook), can slow the call 10-50x or effectively hang it.
$ProgressPreference = 'SilentlyContinue'

function Write-Raw {
    # Write raw UTF-8 bytes to stdout, bypassing [Console]::Out whose encoding may
    # be a legacy codepage (e.g. CP437) that mangles non-ASCII output. Claude Code
    # reads the hook's stdout as UTF-8.
    param([string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $stdout = [Console]::OpenStandardOutput()
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
}
function Dbg { param([string]$Msg) if ($env:ROGUE_DEBUG) { [Console]::Error.WriteLine("[rogue] $Msg"); [Console]::Error.Flush() } }

function Emit-Json {
    param([string]$Data)
    if (-not $Data) { Write-Raw '{}'; return }
    Write-Raw $Data
}

function ConvertFrom-ShellQuoted {
    # Decode one shell "word" the way hook.sh would when it `source`s the env file,
    # so values round-trip across both dispatchers. The env files are written either
    # POSIX single-quoted with `'\''` escapes (install.ps1 / setup.ps1) or via bash
    # `printf %q`, which emits backslash escapes and double quotes (install.sh /
    # setup.sh). A naive outer-quote strip mangles values like O'Brien
    # ('O'\''Brien') or "Your Name" (Your\ Name); this walks the string honoring
    # single quotes, double quotes, and backslash escapes instead.
    param([string]$Val)
    if ($null -eq $Val) { return $Val }
    $sb = [System.Text.StringBuilder]::new()
    $i = 0; $n = $Val.Length
    $state = 'normal'   # normal | single | double
    while ($i -lt $n) {
        $c = $Val[$i]
        switch ($state) {
            'single' {
                if ($c -eq "'") { $state = 'normal' } else { [void]$sb.Append($c) }
            }
            'double' {
                if ($c -eq '"') { $state = 'normal' }
                elseif ($c -eq '\' -and ($i + 1) -lt $n -and ('"\$`'.IndexOf($Val[$i+1]) -ge 0)) {
                    [void]$sb.Append($Val[$i+1]); $i++
                } else { [void]$sb.Append($c) }
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

function Repair-DoubleEncodedUtf8 {
    # Claude Code on non-UTF-8 Windows locales can double-encode assistant text
    # (UTF-8 -> CP1252 -> UTF-8): e.g. "-" arrives as """ and "'" as "".
    # Re-encode as CP1252 and decode as UTF-8, with BOTH steps STRICT (throw on any
    # unmappable char / invalid byte). Genuine mojibake round-trips to valid UTF-8
    # and is repaired; already-correct text (cafe, an emoji, plain ASCII) fails the strict
    # round-trip and is returned unchanged - a safe no-op for well-behaved clients.
    param([string]$Text)
    if (-not $Text) { return $Text }
    try {
        $cp1252 = [System.Text.Encoding]::GetEncoding(1252,
            [System.Text.EncoderFallback]::ExceptionFallback,
            [System.Text.DecoderFallback]::ExceptionFallback)
        $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
        $repaired = $strictUtf8.GetString($cp1252.GetBytes($Text))
        if ($repaired -ne $Text) { Dbg "repaired double-encoded UTF-8"; return $repaired }
    } catch { Dbg "no double-encode repair (text already valid UTF-8)" }
    return $Text
}

# -- logging ----------------------------------------------------------------
# ONE FILE PER AGENT (mirrors hook.sh). Every Rogue plugin shares ~/.rogue, so a
# machine running Claude Code + Codex + Cursor + … used to interleave all of them
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
# Which SURFACE of Claude wrote each line - cli, desktop or cowork. One file per
# agent family means every surface on the machine appends to the same claude.log,
# and nothing on the line said which one. The mapping is shared with heartbeat.ps1
# (scripts/surface.ps1) so a line and the roster row for the same session can never
# name different surfaces. An empty value OMITS the token; it is never written as
# `surface=` or `surface=unknown`.
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
        if ($d) { $f = Join-Path $d 'claude.log' }
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
            "$stamp provider=claude$surfaceToken event=$EventName $Msg`n",
            (New-Object System.Text.UTF8Encoding $false))
    } catch {}
}

function Test-SyntheticActor {
    # True when the value is empty/whitespace or a known synthetic sandbox
    # identity. Mirrors actor.sh's _rogue_is_synthetic: case-insensitive, with
    # internal whitespace runs squeezed so "Claude  Code" matches too.
    #
    # In Claude Cowork the agent runs as unix user `claude` inside a sandbox whose
    # git identity is Anthropic's synthetic one (user.name=Claude /
    # user.email=noreply@anthropic.com), so those values must never be reported as
    # the acting human.
    param([string]$Value)
    if ($null -eq $Value) { return $true }
    $v = ($Value -replace '\s+', ' ').Trim().ToLowerInvariant()
    return ($v -eq '' -or $v -eq 'claude' -or $v -eq 'claude code' -or $v -eq 'noreply@anthropic.com')
}

function Select-ActorValue {
    # First non-synthetic candidate, or '' when every one is rejected. Callers
    # invoke it in stages so an expensive candidate (git config) is only computed
    # when the cheap ones have already been rejected.
    param([string[]]$Candidates)
    if ($null -eq $Candidates) { return '' }
    foreach ($c in $Candidates) { if (-not (Test-SyntheticActor $c)) { return $c } }
    return ''
}

function Test-WantAlert {
    # True when a native block modal should be fired for this event. Twin of
    # hook.sh's _rogue_want_alert — keep the two in lockstep; there is no shared
    # seam between the shells, so any drift is divergent behaviour per platform
    # (the same trap install-id.sh documents for the actor/surface cascade).
    #
    # Claude Code CLI and the Claude Desktop app render hook block messages
    # themselves, so a modal there would double-report — that is why c31ee5a
    # deleted this path. Claude Cowork, which was not a surface then, breaks the
    # "pure relay" claim: its client discards hook-authored text on every
    # documented channel (decision/reason, continue/stopReason, systemMessage,
    # exit-2 stderr all stop the turn with NO text), so the OS modal is the only
    # channel that reaches the user. Cowork CLOUD runs the hook in a headless
    # Linux container and is excluded, so the log stays honest.
    #
    # Windows Cowork has NOT been observed in the wild; this keeps the twin
    # honest rather than claiming verified behaviour. Unlike the sh side there is
    # no capability probe: security-alert.ps1 uses a native WScript.Shell popup
    # rather than an external binary, so alert_launched / alert_error logging is
    # what catches a UI failure.
    param([string]$InstallAgent, [string]$HookEvent)
    # 1. Cowork only. Takes the surface the roster already resolved (the
    #    CLAUDE_CODE_IS_COWORK-first cascade) rather than re-deriving it.
    if ($InstallAgent -ne 'claude_cowork') { return $false }
    # 2. Local execution only. CLAUDE_CODE_REMOTE=true marks the cloud container.
    if ($env:CLAUDE_CODE_REMOTE) { return $false }
    # 3. Escape hatches, so the blast radius can change without a release:
    #    ROGUE_ALERT=0 disables; ROGUE_ALERT_EVENTS is a space-separated event
    #    allowlist (see CLAUDE.md on narrowing to UserPromptSubmit).
    if ($env:ROGUE_ALERT -eq '0') { return $false }
    if ($env:ROGUE_ALERT_EVENTS) {
        $allowed = @($env:ROGUE_ALERT_EVENTS -split '\s+' | Where-Object { $_ })
        if ($allowed -notcontains $HookEvent) { return $false }
    }
    return $true
}

# Test seam: dot-sourcing with ROGUE_PS_LIB_ONLY=1 loads the functions above
# (e.g. ConvertFrom-ShellQuoted, Rotate-Log) without running the dispatcher.
# Production never sets this, so the hook always runs its main body.
if ($env:ROGUE_PS_LIB_ONLY) { return }

# Windows PowerShell 5.1 may negotiate only TLS 1.0/1.1 by default, which modern
# HTTPS endpoints reject ("Could not create SSL/TLS secure channel"). Add TLS 1.2
# without clobbering any protocols already enabled.
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

# -- stand down on non-Windows (pwsh on macOS/Linux) ------------------------
# $IsWindows exists only in PowerShell 6+. In 5.1 (Windows-only) it is $null, so
# guard on the version to avoid a false stand-down there.
if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { Write-Raw '{}'; exit 0 }

# Run only when Claude Code is the one invoking the hook (mirrors hook.sh's gate;
# matches the "run hooks only when claude executes them" fix).
if (-not $env:CLAUDE_CODE_ENTRYPOINT) { Write-Raw '{}'; exit 0 }

if (-not $EventName) { Dbg "no event name -> {}"; Write-Raw '{}'; exit 0 }
Dbg "event=$EventName"

# -- plugin root ------------------------------------------------------------
$pluginRoot = $env:CLAUDE_PLUGIN_ROOT
if (-not $pluginRoot) { try { $pluginRoot = (Get-Location).Path } catch { $pluginRoot = '.' } }
Dbg "pluginRoot=$pluginRoot"

# Resolve the surface before the first Log call. Guarded on both sides: a damaged
# install with no surface.ps1, or a resolver that throws, leaves the slug empty and
# the token is simply omitted - logging must never change the hook's outcome.
try {
    $surfaceLib = Join-Path $pluginRoot 'scripts\surface.ps1'
    if (Test-Path -LiteralPath $surfaceLib) {
        . $surfaceLib
        $script:surface = [string](Get-RogueSurfaceSlug)
    }
} catch { $script:surface = '' }
Dbg "surface=$($script:surface)"

# -- credential resolution ---------------------------------------------------
$creds = @{}
foreach ($k in 'ROGUE_API_KEY','ROGUE_ACTOR_EMAIL','ROGUE_ACTOR_NAME','ROGUE_BASE_URL',
               'ROGUE_LOG_FILE','ROGUE_LOG_DIR','ROGUE_LOG_MAX_BYTES') {
    $val = [Environment]::GetEnvironmentVariable($k)
    if ($val) { $creds[$k] = $val }
}
# The first env file holding ROGUE_API_KEY is used alone: machine, bundled, user.
$credFiles = @(
    'C:\ProgramData\rogue\env',
    (Join-Path $pluginRoot 'env'),
    (Join-Path $env:USERPROFILE '.rogue-env')
)
foreach ($f in $credFiles) {
    if (-not $f) { continue }
    if (-not (Test-Path -LiteralPath $f)) { Dbg "cred file absent: $f"; continue }
    $fileVals = @{}
    foreach ($line in (Get-Content -LiteralPath $f)) {
        if ($line -match '^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.+)$') {
            # Decode shell quoting/escaping so the value round-trips with the
            # `source`-based parse in hook.sh (mirrors shlex.split).
            $fileVals[$Matches[1]] = ConvertFrom-ShellQuoted ($Matches[2].Trim())
        }
    }
    if (-not $fileVals['ROGUE_API_KEY']) { Dbg "cred file skipped: $f"; continue }
    Dbg "cred file in use: $f"
    foreach ($k in $fileVals.Keys) { $creds[$k] = $fileVals[$k] }
    break
}

# Logging is initialised HERE - after the credential files are parsed, so they can
# relocate the log - but BEFORE the API-key check below, so an unconfigured
# install still records `outcome=unconfigured`.
Initialize-Logging $creds
Dbg "logFile=$logFile cap=$logMaxBytes"

$apiKey = $creds['ROGUE_API_KEY']
if (-not $apiKey) {
    Dbg "no API key after cred resolution -> fail-open"
    Log "outcome=unconfigured"
    if ($EventName -eq 'SessionStart') {
        # Mirrors warn.sh's nudge (there is no warn.ps1 - this covers its job).
        Write-Raw '{"systemMessage": "[Rogue Security] Not configured. Run /rogue:setup to connect your API key."}'
    } else {
        Write-Raw '{}'
    }
    exit 0
}
$keyTail = if ($apiKey.Length -ge 4) { $apiKey.Substring($apiKey.Length - 4) } else { '****' }
Dbg "apiKey present (tail $keyTail)"

$baseUrl = $creds['ROGUE_BASE_URL']
if (-not $baseUrl) { $baseUrl = 'https://api.rogue.security' }
$baseUrl = $baseUrl.TrimEnd('/')

# -- actor resolution (mirrors actor.sh, first NON-SYNTHETIC candidate wins) --
#   EMAIL: ROGUE_ACTOR_EMAIL -> CLAUDE_CODE_USER_EMAIL -> git config user.email
#          -> marker unknown@<COMPUTERNAME>
#   NAME:  ROGUE_ACTOR_NAME -> local-part of CLAUDE_CODE_USER_EMAIL
#          -> git config user.name -> USERNAME / [Environment]::UserName
#          -> marker unknown
# The explicit ROGUE_ACTOR_* values are screened too - compiled bundles already
# in the field bake a git-config pre-seed into ${CLAUDE_PLUGIN_ROOT}\env, so a
# plugin update can only fix them if we distrust a poisoned value. See actor.sh.
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

# -- install identity: host + version + surface label ------------------------
# The fleet roster keys an install on host + actor + family + agent, and until
# now only heartbeat.ps1 ever sent them, once, at session start. A session still
# working a day later therefore aged out as disconnected. Sending the same three
# as headers on EVERY event lets the backend refresh this exact row from ordinary
# hook traffic. Resolved exactly as heartbeat.ps1 does (its sh sibling shares
# scripts/install-id.sh instead; PowerShell has no such seam here). Any drift
# between the two is a duplicate roster row.
$installError = @()
$hostName = $env:COMPUTERNAME
if (-not $hostName) { try { $hostName = [System.Net.Dns]::GetHostName() } catch { $hostName = '' } }
if (-not $hostName) { $hostName = 'unknown'; $installError += 'host-unresolved' }

$pluginVersion = 'unknown'
$pluginJson = Join-Path $pluginRoot '.claude-plugin\plugin.json'
if (Test-Path -LiteralPath $pluginJson) {
    $m = [regex]::Match((Get-Content -Raw -LiteralPath $pluginJson), '"version"\s*:\s*"([0-9]+\.[0-9]+\.[0-9]+)')
    if ($m.Success) { $pluginVersion = $m.Groups[1].Value }
    # Manifest is there but carries no semver: schema drift, not a bad install.
    else { $installError += "version-unparsed:$pluginJson" }
} else {
    $installError += "manifest-missing:$pluginJson"
}

# The surface AGENT ID for the roster / x-rogue-agent header. Read from the
# SHARED table in scripts/surface.ps1 rather than inlined, so this can never
# disagree with hook.ps1's own `surface=` log slug or heartbeat.ps1's roster
# row for the same session. That table checks CLAUDE_CODE_IS_COWORK ahead of
# the entrypoint (Cowork's entrypoint is `local-agent`, not a *cowork* value),
# and answers a snake_case id, not a display label: the id IS the backend's
# PLUGIN_REPOS key, and a label matched none, so every Claude row read as up
# to date. The literal is the last-resort guard for a damaged install.
$installAgent = ''
try { if (Get-Command Get-RogueSurfaceAgentId -ErrorAction SilentlyContinue) { $installAgent = [string](Get-RogueSurfaceAgentId) } } catch { $installAgent = '' }
if (-not $installAgent) { $installAgent = 'claude_code' }

# A degraded value is still SENT rather than failing the hook: it identifies the
# install well enough to keep the roster fresh, and no liveness bookkeeping is
# worth breaking a session over. But "unknown" in the roster is a real symptom,
# so it is reported as an error once per event.
if ($installError.Count) { Log "error=install-id $($installError -join ',')" }

# -- payload from stdin -----------------------------------------------------
$payload = [Console]::In.ReadToEnd()
if (-not $payload) { $payload = '{}' }
# Claude Code sends a UTF-8 payload, but the console often reads stdin under a
# legacy OEM codepage (e.g. IBM437), which mojibakes it. Round-trip back through
# the ACTUAL input encoding to recover the original bytes, then decode as UTF-8.
Dbg "InputEncoding=$([Console]::InputEncoding.WebName) CP=$([Console]::InputEncoding.CodePage)"
try {
    $raw = [Console]::InputEncoding.GetBytes($payload)
    $payload = [System.Text.Encoding]::UTF8.GetString($raw)
} catch { Dbg "utf8 re-decode failed: $($_.Exception.Message)" }
# A leading UTF-8 BOM is invalid JSON and the API 400s it. Strip it.
$payload = $payload.TrimStart([char]0xFEFF)
$payload = Repair-DoubleEncodedUtf8 $payload

# -- POST (fail-open) -------------------------------------------------------
$headers = @{
    'x-rogue-api-key'     = $apiKey
    'x-rogue-event'       = $EventName
    'x-rogue-actor-email' = $actorEmail
    'x-rogue-actor-name'  = $actorName
    'x-rogue-host'        = $hostName
    'x-rogue-version'     = $pluginVersion
    'x-rogue-agent'       = $installAgent
}
$url = "$baseUrl/api/v1/hooks/claude"
Dbg "POST $url actor=$actorEmail"
# Send an explicit UTF-8 byte array: Windows PowerShell 5.1's Invoke-WebRequest
# re-encodes a string body (commonly to Latin-1), which corrupts non-ASCII content
# and can reintroduce a BOM. GetBytes() never emits a BOM.
$bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
$resp = ''
try {
    $r = Invoke-WebRequest -Uri $url -Method Post `
        -Headers $headers -ContentType 'application/json' -Body $bodyBytes `
        -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
    Dbg "HTTP $($r.StatusCode), body length $($r.Content.Length)"
    if ($r.StatusCode -eq 200) {
        # Decode explicitly as UTF-8. Invoke-WebRequest's .Content mis-decodes as
        # ISO-8859-1 when the server omits a charset; RawContentStream has the bytes.
        try { $resp = [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) }
        catch { $resp = [string]$r.Content }
    }
} catch {
    Dbg "POST failed: $($_.Exception.Message)"
    $resp = ''
}

# Always log the raw response so block-detection bugs are diagnosable from the log
# alone (mirrors hook.sh).
$respHead = if ($resp.Length -gt 400) { $resp.Substring(0, 400) } else { $resp }
Log "raw=$(Sanitize $respHead)"

# -- block detection (mirrors hook.sh's pure-text scan) ---------------------
# Covers every block-decision shape Claude Code's hook protocol emits:
#   "decision":"block"           UserPromptSubmit, Stop (top-level)
#   "continue":false             legacy block signal
#   "permissionDecision":"deny"  PreToolUse (inside hookSpecificOutput)
#   "behavior":"deny"            PermissionRequest (inside hookSpecificOutput.decision)
$blockRe = '"decision"\s*:\s*"block"|"continue"\s*:\s*false|"permissionDecision"\s*:\s*"deny"|"behavior"\s*:\s*"deny"'
$fireAlert = $false
if ($resp -imatch $blockRe) {
    # Extract reason (first match across the field names the formatter uses).
    $reason = $null
    foreach ($field in 'permissionDecisionReason','reason','stopReason','message') {
        if ($resp -match ('"' + $field + '"\s*:\s*"([^"]*)"')) { $reason = $Matches[1]; break }
    }
    if (-not $reason) { $reason = 'prompt blocked' }

    Log "outcome=block reason=`"$(Sanitize $reason)`""
    if (Test-WantAlert $installAgent $EventName) {
        switch ($EventName) {
            'UserPromptSubmit'              { $noun = 'prompt' }
            { $_ -in 'PreToolUse','PermissionRequest' } { $noun = 'tool call' }
            default                         { $noun = 'action' }
        }
        # No leading emoji here, unlike hook.sh's "⛔ Rogue blocked this …": the
        # title crosses a process boundary as an environment variable into a
        # Start-Process child, and Windows console/codepage handling makes a
        # non-ASCII round-trip there unreliable. A deliberate divergence from the
        # sh twin, not drift — do not "fix" it into lockstep.
        $alertTitle = "Rogue blocked this $noun"
        $alertMsg = "Why:`n$reason"
        if ($reason -notlike '*rgx!*') {
            $alertMsg += "`n`nTo allow it: prepend `"rgx!`" to your prompt and resend (marks it a false positive)."
        }
        $fireAlert = $true
    } else {
        # Logged with the gate's inputs so a future surface change is diagnosable
        # from the log alone (mirrors hook.sh's alert_skipped line).
        $ccCowork = if ($env:CLAUDE_CODE_IS_COWORK) { $env:CLAUDE_CODE_IS_COWORK } else { 'unset' }
        $ccRemote = if ($env:CLAUDE_CODE_REMOTE) { $env:CLAUDE_CODE_REMOTE } else { 'unset' }
        Log "alert_skipped=1 entrypoint=$($env:CLAUDE_CODE_ENTRYPOINT) cowork=$ccCowork remote=$ccRemote agent=$installAgent"
    }
} else {
    Log "outcome=allow"
}

# Relay the decision to Claude FIRST and flush it, BEFORE launching the modal, so
# the block is delivered even if the modal lingers on screen. The modal runs in a
# separate, non-blocking Start-Process (its own handles), so it can never hold
# Claude's stdout open or delay the decision — the sibling hook.sh detaches its
# backgrounded alert's fds for the same reason.
Emit-Json $resp

if ($fireAlert) {
    # Launch the modal detached (separate process, own handles) so the hook returns
    # immediately. Title/msg/severity ride env vars (the child inherits them), so the
    # launched command is constant.
    #
    # Pass it as a Base64 (UTF-16LE) -EncodedCommand, NOT -Command. Start-Process
    # joins -ArgumentList with spaces and does NOT quote elements, so a -Command
    # string containing spaces/quotes/parens (like the scriptblock bootstrap) reaches
    # the child mangled and never runs (this is why the alert silently didn't show).
    # A Base64 blob has no spaces, so it survives the array-join intact. EncodedCommand
    # also sidesteps ExecutionPolicy/GPO (no -File on disk).
    try {
        $alert = Join-Path $pluginRoot 'scripts\security-alert.ps1'
        if (Test-Path -LiteralPath $alert) {
            $env:ROGUE_ALERT_TITLE = $alertTitle
            $env:ROGUE_ALERT_MSG = $alertMsg
            $env:ROGUE_ALERT_SEVERITY = 'critical'
            $alertEsc = $alert.Replace("'", "''")
            $boot = "& ([scriptblock]::Create((Get-Content -Raw -LiteralPath '$alertEsc')))"
            $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($boot))
            Start-Process -FilePath 'powershell' -WindowStyle Hidden -ArgumentList @(
                '-NoProfile', '-NonInteractive', '-EncodedCommand', $enc) | Out-Null
            Log "alert_launched=1 entrypoint=$($env:CLAUDE_CODE_ENTRYPOINT)"
        } else {
            Log "alert_skipped=missing_script"
        }
    } catch { Log "alert_error=$(Sanitize $_.Exception.Message)" }
}
exit 0
