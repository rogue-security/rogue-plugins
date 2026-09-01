# Rogue Security hook bridge for GitHub Copilot CLI — PowerShell implementation.
#
# Cross-platform sibling of hook.sh. hooks.json fires the `bash` command on
# macOS/Linux and this `powershell` command on Windows (Copilot prefers pwsh 7+
# but falls back to Windows PowerShell 5.1 — so this stays 5.1-compatible).
# PURE RELAY: reads one Copilot hook event JSON on stdin, POSTs it to
# /api/v1/hooks/copilot, relays the native Copilot decision verbatim — the
# response body is NEVER rewritten, Copilot renders the native deny shape. There
# is one narrow OUT-OF-BAND exception: a userPromptSubmitted block inside
# JetBrains, which the IDE honors but renders nowhere, so we additionally show a
# local alert (see Test-JetBrainsIde / Show-BlockNotification) while still
# relaying the body unchanged.
#
# FAIL-OPEN IS SAFETY-CRITICAL. Copilot's preToolUse is fail-CLOSED: a non-zero
# exit denies the tool. This script emits `{}` on every failure path and always
# exits 0; the loader in hooks.json additionally wraps the call in try/catch and
# `; exit 0`. A block is carried in the relayed JSON body, never the exit code.
#
# Loaded via [scriptblock]::Create((Get-Content ...)) rather than -File, so it
# runs regardless of ExecutionPolicy/GPO. Because it is a scriptblock (not a
# file), $PSCommandPath is empty — hooks.json passes the plugin root as the 2nd
# argument.
#
# Credential resolution (later file wins; process env wins over all):
#   1. ${PLUGIN_ROOT}\env          (baked into a compiled customer plugin)
#   2. C:\ProgramData\rogue\env    (MDM-provisioned; mirrors /etc/rogue/env)
#   3. %USERPROFILE%\.rogue-env    (user / installer-written)

param([string]$EventName = '', [string]$PluginRoot = '')

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
# machine running Copilot CLI + Claude Code + Cursor + … used to interleave all of
# them into a single hook.log with no way to tell whose line was whose.
# Precedence: ROGUE_LOG_FILE → ROGUE_LOG_DIR/copilot.log → default, each read from
# the merged credential map (so process env still wins, but the env files count).
# $HOME backs up USERPROFILE so this file can also be dot-sourced on macOS/Linux
# through the ROGUE_PS_LIB_ONLY seam below (tests).
#
# Resolved by Initialize-Logging AFTER the credential files are parsed, exactly
# like hook.sh resolves these after sourcing them — so `~/.rogue-env`,
# `C:\ProgramData\rogue\env` (MDM) and a bundled `env` can all relocate the log.
# Reading $env: directly here instead would silently ignore every one of those
# files, which is a real defect for a fleet that relocates logs by policy AND
# would make the log shipper and the dispatcher disagree on the path.
# Declared (not resolved) at file scope so the ROGUE_PS_LIB_ONLY seam below can
# dot-source the helpers, and so Log is safe to call before initialisation.
# The one surface this plugin has. A closed-vocabulary slug, lowercase, no space
# and no '=', so a reader finds the value by scanning to the next 'key=' token. It
# matches what heartbeat reports as the roster agent for this plugin.
$script:surface = 'github_copilot'
$script:logFile = $null
$script:logMaxBytes = 10485760

function Initialize-Logging {
    # $Creds is the merged credential map (bundled env → MDM → per-user file, then
    # process env last), so precedence is already correct by the time we read it.
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
        if ($d) { $f = Join-Path $d 'copilot.log' }
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
        # A constant: this plugin has exactly one surface, so there is nothing to
        # detect and nothing that can fail. Written through the same conditional as
        # the multi-surface plugins so all six dispatchers share one emit shape.
        $surfaceToken = if ($script:surface) { " surface=$($script:surface)" } else { '' }
        [System.IO.File]::AppendAllText(
            $logFile,
            "$stamp provider=copilot$surfaceToken event=$EventName $Msg`n",
            (New-Object System.Text.UTF8Encoding $false))
    } catch {}
}

# ── JetBrains silent-block alert (mirrors hook.sh in_jetbrains_ide/notify_block) ──
# JetBrains honors a userPromptSubmitted block but renders NOTHING for it, so the
# chat dies with no reason and no `rgx!` hint. Every other blocking event renders
# natively in both surfaces, so this lone case is the sole exception to pure
# relay. Surface it out-of-band; the response is still relayed unchanged.
# Detection mirrors hook.sh: the IDE embeds the CLI harness, so both set
# COPILOT_CLI=1 — the parent process (copilot-language-server vs copilot) is the
# discriminator, with the env shape as fallback.
function Test-JetBrainsIde {
    # Windows Win32_Process.Name is NOT truncated ('copilot-language-server.exe'),
    # but the pattern is widened to '*copilot-langua*' to stay textually parallel
    # with hook.sh, where Linux caps `comm` at 15 chars. The 'copilot*' arm must
    # stay SECOND — the IDE name matches both patterns and the IDE arm has to win.
    # Up to 6 CIM queries (~100-300ms each), only on the block path, well inside
    # the 30s timeoutSec.
    try {
        $p = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId
        for ($i = 0; $i -lt 5 -and $p; $i++) {
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$p" -ErrorAction Stop
            if (-not $proc) { break }
            if ($proc.Name -like '*copilot-langua*') { return $true }
            if ($proc.Name -like 'copilot*') { return $false }
            $p = $proc.ParentProcessId
        }
    } catch { Dbg "ide detect failed: $($_.Exception.Message)" }
    # Fallback when the walk is unavailable (WMI/CIM disabled, or dot-sourced off
    # Windows by the test seam): the env shape still separates them. The real
    # discriminator is COPILOT_CLI_BINARY_VERSION being UNSET — if a future CLI
    # build stops exporting it the terminal would false-positive into alerting,
    # a duplicate notification rather than a safety failure.
    return (-not $env:COPILOT_CLI_BINARY_VERSION -and
            ($env:PKG_EXECPATH -or $env:GITHUB_COPILOT_RIPGREP_PATH_OVERRIDE))
}

# ROGUE_IDE_ALERT=0 disables; ROGUE_IDE_ALERT_DRYRUN=1 logs without alerting;
# ROGUE_IDE_ALERT_DRYRUN=2 additionally logs the fully-escaped literal (real
# newlines rendered as '|') so the escaping of server-controlled reason text is
# covered by a test rather than a one-off probe.
function Show-BlockNotification {
    param([string]$Reason)
    if ($env:ROGUE_IDE_ALERT -eq '0') { return }
    $msg = Sanitize $Reason
    if (-not $msg) { $msg = 'Prompt blocked by Rogue Security.' }
    # Truncates UTF-16 CHARS; hook.sh's `head -c 400` truncates BYTES, so a
    # non-ASCII reason cuts at a slightly different point. Accepted divergence —
    # the cap only exists to keep a runaway reason out of a modal.
    if ($msg.Length -gt 400) { $msg = $msg.Substring(0, 400) }
    Log 'ide_alert=fired'
    if ($env:ROGUE_IDE_ALERT_DRYRUN -eq '1') { return }
    # Windows analogue of hook.sh's `display alert as critical`, using the same
    # WScript.Shell.Popup the Claude plugin's security-alert.ps1 used: it
    # surfaces on the interactive desktop from a detached hidden process, needs
    # no assembly load, and dodges the window-station constraints that make
    # MessageBox::Show silently no-op there. Type 16 = OK button + stop icon.
    # ALWAYS DETACHED — a modal waits for the click, so inline would stall the
    # dispatcher; backgrounded, a lingering dialog can never block the hook.
    try {
        # API reasons carry literal "\n" (backslash + n, straight from the JSON
        # string) and are two paragraphs — findings text plus the `rgx!` hint.
        # Convert to real newlines FIRST (a PowerShell single-quoted literal may
        # span lines), then double the single quotes for that literal. The call
        # site deliberately does NOT collapse "\n" to a space, or this
        # conversion would be dead code (mirrors hook.sh notify_block).
        $safe = ($msg -replace '\\n', "`n") -replace "'", "''"
        if ($env:ROGUE_IDE_ALERT_DRYRUN -eq '2') {
            $flat = Sanitize ($safe -replace "`n", '|')
            Log "ide_alert=escaped msg=$flat"
            return
        }
        $inner = @"
try {
  `$w = New-Object -ComObject 'WScript.Shell'
  `$null = `$w.Popup('$safe', 0, 'Rogue Security - prompt blocked', 16)
} catch { }
"@
        $bytes = [System.Text.Encoding]::Unicode.GetBytes($inner)
        Start-Process -FilePath 'powershell' -WindowStyle Hidden `
            -ArgumentList '-NoProfile', '-NonInteractive', '-EncodedCommand',
                          ([Convert]::ToBase64String($bytes)) | Out-Null
    } catch { Dbg "notify failed: $($_.Exception.Message)" }
}

# Test seam: dot-sourcing with ROGUE_PS_LIB_ONLY=1 loads the functions above
# (Sanitize, Log, Test-JetBrainsIde, Show-BlockNotification,
# ConvertFrom-ShellQuoted) without running the dispatcher. Production never sets
# this, so the hook always runs its main body.
if ($env:ROGUE_PS_LIB_ONLY) { return }

# Windows PowerShell 5.1 may negotiate only TLS 1.0/1.1 by default; add TLS 1.2.
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

# Stand down on non-Windows (Copilot runs hook.sh there; this guards a stray pwsh).
if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { Write-Raw '{}'; exit 0 }

if (-not $EventName) { Write-Raw '{}'; exit 0 }
Dbg "event=$EventName"

if (-not $PluginRoot) { $PluginRoot = $env:COPILOT_PLUGIN_ROOT }
if (-not $PluginRoot) { try { $PluginRoot = (Get-Location).Path } catch { $PluginRoot = '.' } }

# ── credential resolution (later file wins; process env wins over all) ─────
$creds = @{}
foreach ($f in @((Join-Path $PluginRoot 'env'), 'C:\ProgramData\rogue\env', (Join-Path $env:USERPROFILE '.rogue-env'))) {
    if (-not $f -or -not (Test-Path -LiteralPath $f)) { continue }
    foreach ($line in (Get-Content -LiteralPath $f)) {
        if ($line -match '^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.+)$') {
            $creds[$Matches[1]] = ConvertFrom-ShellQuoted ($Matches[2].Trim())
        }
    }
}
# ROGUE_LOG_* ride the same list so a process-env value still beats the files,
# which is what makes the resolved precedence identical to hook.sh's.
foreach ($k in 'ROGUE_API_KEY','ROGUE_ACTOR_EMAIL','ROGUE_ACTOR_NAME','ROGUE_BASE_URL','ROGUE_API_URL',
               'ROGUE_LOG_FILE','ROGUE_LOG_DIR','ROGUE_LOG_MAX_BYTES') {
    $val = [Environment]::GetEnvironmentVariable($k); if ($val) { $creds[$k] = $val }
}

# Logging is initialised HERE - after the credential files are parsed, so they can
# relocate the log - but BEFORE the API-key check below, so an unconfigured
# install still records `outcome=unconfigured`.
Initialize-Logging $creds
Dbg "logFile=$logFile cap=$logMaxBytes"

$apiKey = $creds['ROGUE_API_KEY']

# Not configured: emit the SessionStart hint (so the user knows to run setup) or
# a clean allow for every other event. Never POST without a key. When a key IS
# present, sessionStart falls through to the POST path below (audit/persistence);
# the heartbeat runs from a separate hooks.json entry.
if (-not $apiKey) {
    Log 'outcome=unconfigured'
    if ($EventName -eq 'sessionStart') {
        Write-Raw '{"additionalContext":"[Rogue Security] Not configured. Run /rogue:setup to connect your API key."}'
    } else {
        Write-Raw '{}'
    }
    exit 0
}

# URL: explicit ROGUE_API_URL wins, else base + path.
$url = $creds['ROGUE_API_URL']
if (-not $url) {
    $baseUrl = $creds['ROGUE_BASE_URL']; if (-not $baseUrl) { $baseUrl = 'https://api.rogue.security' }
    $url = "$($baseUrl.TrimEnd('/'))/api/v1/hooks/copilot"
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

# ── payload from stdin (recover UTF-8, strip BOM) ──────────────────────────
$payload = [Console]::In.ReadToEnd()
if (-not $payload) { $payload = '{}' }
try {
    $raw = [Console]::InputEncoding.GetBytes($payload)
    $payload = [System.Text.Encoding]::UTF8.GetString($raw)
} catch {}
$payload = $payload.TrimStart([char]0xFEFF)

# ── Subagent re-attribution (mirrors hook.sh) ──────────────────────────────
# A Copilot subagent's own hook events arrive with sessionId = the model
# tool-call id (toolu_… / call_…) and no parent reference; persisted verbatim
# they orphan into a separate audit log. The parent link lives only in the
# parent session's events.jsonl (a subagent.started line naming this id; the
# parent id IS that transcript's directory name). Resolve it, rewrite the
# outgoing sessionId, and tag via the x-rogue-agent-id / x-rogue-agent-name-b64
# headers (see the POST below). Fail-open: unresolved → body untouched (today's
# orphaned behavior — never worse).
$subagentId = ''
$subagentName = ''
$copilotStateDir = $env:ROGUE_COPILOT_STATE_DIR
if (-not $copilotStateDir) {
    $copilotStateDir = Join-Path (Join-Path $env:USERPROFILE '.copilot') 'session-state'
}

function Resolve-SubagentParent {
    param([string]$Sub)
    if (-not (Test-Path -LiteralPath $copilotStateDir)) { return $null }
    foreach ($dir in (Get-ChildItem -LiteralPath $copilotStateDir -Directory -ErrorAction SilentlyContinue)) {
        $f = Join-Path $dir.FullName 'events.jsonl'
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $line = $null
        foreach ($ln in (Get-Content -LiteralPath $f -ErrorAction SilentlyContinue)) {
            if (($ln -like '*"subagent.started"*') -and ($ln -like ('*"' + $Sub + '"*'))) { $line = $ln; break }
        }
        if (-not $line) { continue }
        $name = ''
        $m = [regex]::Match($line, '"agentDisplayName":"([^"]*)"')
        if ($m.Success) { $name = $m.Groups[1].Value }
        else {
            $m2 = [regex]::Match($line, '"agentName":"([^"]*)"')
            if ($m2.Success) { $name = $m2.Groups[1].Value }
        }
        return [pscustomobject]@{ Parent = $dir.Name; Name = $name }
    }
    return $null
}

try {
    $sidMatch = [regex]::Match($payload, '"sessionId"\s*:\s*"([^"]*)"')
    if ($sidMatch.Success -and ($sidMatch.Groups[1].Value -match '^(toolu_|call_)')) {
        $sid = $sidMatch.Groups[1].Value
        $cacheDir = Join-Path (Join-Path $env:USERPROFILE '.rogue') 'copilot-submap'
        $cacheFile = Join-Path $cacheDir $sid
        $map = $null
        if (Test-Path -LiteralPath $cacheFile) {
            $c = @(Get-Content -LiteralPath $cacheFile -ErrorAction SilentlyContinue)
            if ($c.Count -ge 1 -and $c[0]) {
                $map = [pscustomobject]@{ Parent = $c[0]; Name = $(if ($c.Count -ge 2) { [string]$c[1] } else { '' }) }
            }
        }
        if (-not $map) {
            $max = 20
            if ($env:ROGUE_SUBAGENT_RESOLVE_ITERS) { try { $max = [int]$env:ROGUE_SUBAGENT_RESOLVE_ITERS } catch {} }
            if (-not (Test-Path -LiteralPath $copilotStateDir)) { $max = 0 }
            for ($i = 0; $i -lt $max; $i++) {
                $map = Resolve-SubagentParent $sid
                if ($map) { break }
                Start-Sleep -Milliseconds 100
            }
            if ($map) {
                try {
                    if (-not (Test-Path -LiteralPath $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }
                    Set-Content -LiteralPath $cacheFile -Value @($map.Parent, $map.Name) -Encoding UTF8
                } catch {}
            }
        }
        if ($map -and $map.Parent) {
            $subagentId = $sid
            $subagentName = $map.Name
            $payload = $payload -replace ('"sessionId"\s*:\s*"' + [regex]::Escape($sid) + '"'), ('"sessionId":"' + $map.Parent + '"')
            Log "subagent=$sid parent=$($map.Parent)"
        } else {
            Log "subagent=$sid outcome=unresolved"
        }
    }
} catch { Dbg "subagent re-attribution failed: $($_.Exception.Message)" }

# The agentStop/subagentStop hook can fire before Copilot has flushed the turn's
# final assistant.message line to events.jsonl (observed ~5-50ms lag), so a naive
# tail captures a stale transcript missing the very reply we need to evaluate —
# the reply is silently dropped. File appends are ordered, so once the turn's
# closing "assistant.turn_end" line is on disk, every earlier line of the turn
# (incl. the final assistant.message) is too. Poll (bounded) until the last
# non-hook line is an assistant.turn_end. Mirrors hook.sh's wait_for_transcript_flush.
function Wait-TranscriptFlush {
    param([string]$Path)
    # ~5s cap (50 * 100ms). Covers disk FLUSH lag after the completed
    # assistant.message is written — NOT streaming time (agentStop fires only
    # after the turn completes). ROGUE_FLUSH_WAIT_ITERS overrides the count
    # (tests set it low to exercise the fail-open path). Mirrors hook.sh.
    $max = 50
    if ($env:ROGUE_FLUSH_WAIT_ITERS) { try { $max = [int]$env:ROGUE_FLUSH_WAIT_ITERS } catch {} }
    for ($i = 0; $i -lt $max; $i++) {   # happy path returns in 0-1 iters
        try {
            $last = $null
            $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
            try {
                $len = $fs.Length
                $take = [Math]::Min(262144, $len)
                if ($take -gt 0) {
                    [void]$fs.Seek($len - $take, 'Begin')
                    $buf = New-Object byte[] $take
                    $read = 0
                    while ($read -lt $take) {
                        $n = $fs.Read($buf, $read, $take - $read)
                        if ($n -le 0) { break }
                        $read += $n
                    }
                    $txt = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
                    foreach ($ln in ($txt -split "`n")) {
                        $t = $ln.Trim()
                        if (-not $t) { continue }
                        if ($t -like '*"hook.*') { continue }
                        $last = $t
                    }
                }
            } finally { $fs.Close() }
            if ($last -and $last -like '*"assistant.turn_end"*') { return }
        } catch { return }
        Start-Sleep -Milliseconds 100
    }
}

# agentStop / subagentStop carry no message content inline — only a
# transcriptPath. Append the last ~256KB of that events.jsonl file, base64-
# encoded, as "transcriptTailB64" so the backend can extract the final message.
# base64 has no JSON-special chars, so re-closing the object is safe. Fail-open:
# any problem returns the payload unchanged.
if ($EventName -eq 'agentStop' -or $EventName -eq 'subagentStop') {
    try {
        $m = [regex]::Match($payload, '"transcriptPath"\s*:\s*"([^"]*)"')
        if ($m.Success) {
            $tp = $m.Groups[1].Value
            if ($tp -and (Test-Path -LiteralPath $tp)) {
                Wait-TranscriptFlush $tp
                $fs = [System.IO.File]::Open($tp, 'Open', 'Read', 'ReadWrite')
                try {
                    $len = $fs.Length
                    $take = [Math]::Min(262144, $len)
                    if ($take -gt 0) {
                        [void]$fs.Seek($len - $take, 'Begin')
                        $buf = New-Object byte[] $take
                        # Stream.Read may return fewer bytes than requested — loop
                        # until $take bytes are read (or EOF) so no trailing NULs
                        # leak into the base64.
                        $read = 0
                        while ($read -lt $take) {
                            $n = $fs.Read($buf, $read, $take - $read)
                            if ($n -le 0) { break }
                            $read += $n
                        }
                        if ($read -gt 0) {
                            $b64 = [Convert]::ToBase64String($buf, 0, $read)
                            # Strip exactly ONE trailing '}' (mirrors hook.sh's
                            # "${_body%\}}"). String.TrimEnd('}') would strip ALL
                            # trailing braces and corrupt a body ending in "}}".
                            $p = $payload.TrimEnd()
                            if ($p.EndsWith('}')) { $p = $p.Substring(0, $p.Length - 1) }
                            if ($b64) { $payload = $p + ',"transcriptTailB64":"' + $b64 + '"}' }
                        }
                    }
                } finally { $fs.Close() }
            }
        }
    } catch { Dbg "transcript augment failed: $($_.Exception.Message)" }
}

# ── per-turn presence heartbeat + log ship (agentStop only) ────────────────
# The PowerShell twin of hook.sh's agentStop block. sessionStart's heartbeat is
# spawned by hooks.json; this is its per-TURN sibling, fired from HERE rather than
# from a second hooks.json entry because Copilot skips untrusted command hooks until
# reviewed via /hooks - a new entry would silently disable every Rogue hook on every
# existing install until each user re-approved. heartbeat.ps1 throttles the beacon
# itself (scripts/beacon.ps1, 900s default) and the shipper throttles itself, so a
# per-turn trigger is not a per-turn request.
#
# MAIN AGENT ONLY: Copilot fires agentStop for a subagent too, and $subagentId is
# already resolved by this point, so this skips those - a subagent's stop is not a
# user turn.
#
# A SEPARATE, HIDDEN PROCESS, for the same two reasons every PowerShell caller here
# spawns one: in-process, heartbeat.ps1's `$script:` writes would land on this
# dispatcher's variables and its `exit 0` would end the dispatcher before it relays
# the response. -EncodedCommand with the path in an env var, so the command is a
# constant with nothing to escape (Start-Process -ArgumentList quoting is unreliable
# on Windows PowerShell 5.1). Start-Process without -Wait returns immediately.
#
# COPILOT_PLUGIN_ROOT is set explicitly because heartbeat.ps1 self-locates from
# $PSCommandPath, which is EMPTY under [scriptblock]::Create - the -File spawn in
# hooks.json has it, this one does not, and COPILOT_PLUGIN_ROOT is its documented
# next fallback. Without it the child would resolve its root from the CWD and find no
# bundled env, no manifest version and no shipper.
if ($EventName -eq 'agentStop' -and -not $subagentId) {
    $hbScript = Join-Path $pluginRoot 'scripts\heartbeat.ps1'
    if (Test-Path -LiteralPath $hbScript) {
        try {
            $env:COPILOT_PLUGIN_ROOT    = $pluginRoot
            $env:ROGUE_HEARTBEAT_SCRIPT = $hbScript
            $hbInner = '& ([scriptblock]::Create((Get-Content -Raw -LiteralPath' +
                       ' $env:ROGUE_HEARTBEAT_SCRIPT))) agentStop'
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
# The fleet roster keys an install on host + actor + family + agent, and until
# now only heartbeat.ps1 ever sent them, once, at session start. A session still
# working a day later therefore aged out as disconnected. Sending them as headers
# on EVERY event lets the backend refresh this exact row from ordinary hook
# traffic. Resolved exactly as heartbeat.ps1 does (its sh sibling shares
# scripts/install-id.sh instead; PowerShell has no such seam here). Any drift
# between the two is a duplicate roster row.
$installError = @()
$hostName = $env:COMPUTERNAME
if (-not $hostName) { try { $hostName = [System.Net.Dns]::GetHostName() } catch { $hostName = '' } }
if (-not $hostName) { $hostName = 'unknown'; $installError += 'host-unresolved' }

$pluginVersion = 'unknown'
$pluginJson = Join-Path $PluginRoot 'plugin.json'
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


# ── POST (fail-open) → relay verbatim ──────────────────────────────────────
$headers = @{
    'x-rogue-api-key'     = $apiKey
    'x-rogue-event'       = $EventName
    'x-rogue-actor-email' = $actorEmail
    'x-rogue-actor-name'  = $actorName
    'x-rogue-host'        = $hostName
    'x-rogue-version'     = $pluginVersion
    'x-rogue-agent'       = 'github_copilot'
}
# Every event POSTs the same seven headers; a re-attributed subagent event adds the
# agent tag as two more — x-rogue-agent-id and x-rogue-agent-name-b64, the same
# pair the Antigravity dispatcher sends. In HEADERS and not in the body so the
# POSTed event stays the vendor's own bytes. The name is base64 because a display
# name is arbitrary vendor text and HTTP header values are ISO-8859-1 by spec, so
# an accent or an emoji sent raw is undefined behavior across proxies. Both are
# omitted entirely, never sent empty, on a main-agent event. The local $subagent*
# variables keep Copilot's own terminology, since Copilot is what calls these
# subagents; the wire names match the aidr_message.agent_id/agent_name columns
# they land in. Mirrors hook.sh.
#
# The id is a bare token from Copilot (toolu_… / call_…); anything outside the
# token charset is not one, so BOTH headers are skipped rather than emitting a
# junk value.
if ($subagentId -and ($subagentId -match '^[A-Za-z0-9_-]+$')) {
    $headers['x-rogue-agent-id'] = $subagentId
    if ($subagentName) {
        $headers['x-rogue-agent-name-b64'] =
            [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($subagentName))
    }
}
$bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
$resp = ''
try {
    $r = Invoke-WebRequest -Uri $url -Method Post `
        -Headers $headers -ContentType 'application/json' -Body $bodyBytes `
        -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
    if ($r.StatusCode -eq 200) {
        try { $resp = [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) }
        catch { $resp = [string]$r.Content }
    }
} catch { Dbg "POST failed: $($_.Exception.Message)"; $resp = '' }

$respHead = if ($resp.Length -gt 400) { $resp.Substring(0, 400) } else { $resp }
Log "raw=$(Sanitize $respHead)"

if (-not $resp) { Write-Raw '{}'; exit 0 }

# The ONE case Copilot renders nowhere: a userPromptSubmitted block inside
# JetBrains (see Test-JetBrainsIde / Show-BlockNotification above). Surface the
# reason out-of-band, then relay unchanged — the response is never rewritten.
if ($EventName -eq 'userPromptSubmitted' -and
    $resp -match '"decision"\s*:\s*"block"' -and (Test-JetBrainsIde)) {
    # Keep the literal "\n" sequences intact — Show-BlockNotification converts
    # them to real newlines so the two-paragraph reason renders as written.
    $reason = ''
    if ($resp -match '"reason"\s*:\s*"([^"]*)"') { $reason = $Matches[1] }
    Show-BlockNotification $reason
}

Write-Raw $resp
exit 0
