# Rogue Security hook dispatcher for Cursor — PowerShell implementation.
#
# Cross-platform sibling of hook.sh. hooks.json loads this WITHOUT -File so the
# PowerShell ExecutionPolicy never applies (running a scriptblock built from a
# string is not subject to policy, unlike invoking a .ps1 on disk — this also
# survives a GPO-enforced policy, which -ExecutionPolicy Bypass does not):
#
#   powershell -NoProfile -NonInteractive -Command \
#     "& ([scriptblock]::Create((Get-Content -Raw -LiteralPath (Join-Path $env:CURSOR_PLUGIN_ROOT 'scripts/hook.ps1')))) <event>"
#
# CURSOR_PLUGIN_ROOT (the plugin root) is exposed as a process ENVIRONMENT
# VARIABLE, so PowerShell resolves $env:CURSOR_PLUGIN_ROOT at runtime via
# Join-Path — it must NOT be single-quoted (single quotes are literal in
# PowerShell and would never expand). Cursor runs this entry from a cwd that is
# NOT the plugin root, so a relative path would not resolve here. Join-Path also
# keeps the absolute path intact when it contains spaces.
#
# This script OWNS native Windows. It stands down on non-Windows (pwsh on
# macOS/Linux) because hook.sh runs there.
#
# Fail-open everywhere: missing API key, network error, non-200, empty body, or
# non-JSON response all yield `{}` on stdout, exit 0.
#
# The relayed body is byte-for-byte what Cursor sent, with the single
# `rogueFilePreImageB64` exception (see Add-FilePreImage). Subagent identity
# therefore rides in HEADERS: `x-rogue-parent-session-id` / `x-rogue-agent-id`,
# resolved from Cursor's own transcript tree (see Resolve-RogueParentSession).
#
# Set ROGUE_DEBUG=1 (process/user env var) to emit diagnostics to stderr;
# Cursor shows stderr in its hook log without treating it as the response.
#
# Logs every invocation to $env:ROGUE_LOG_FILE (default
# %USERPROFILE%\.rogue\logs\cursor.log), mirroring hook.sh.
#
# Credential resolution, the Windows analogue of hook.sh's search: the first env
# file holding ROGUE_API_KEY is used alone, and its values override the process env:
#   1. C:\ProgramData\rogue\env         (machine, MDM-provisioned; mirrors /etc/rogue/env)
#   2. ${CURSOR_PLUGIN_ROOT}\env        (bundled into a compiled customer plugin)
#   3. %USERPROFILE%\.rogue-env         (user / installer-written)

param([string]$EventName = '')

$ErrorActionPreference = 'SilentlyContinue'
# Invoke-WebRequest renders a progress bar that, when stdout/stderr is
# redirected (always true under a Cursor hook), can slow the call 10-50x or
# effectively hang it. Silencing progress is the standard fix.
$ProgressPreference = 'SilentlyContinue'

function Write-Raw {
    # Write raw UTF-8 bytes to stdout, bypassing [Console]::Out whose encoding
    # may be a legacy codepage (e.g. CP437) that mangles non-ASCII output back
    # into mojibake. Cursor reads the hook's stdout as UTF-8.
    param([string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $stdout = [Console]::OpenStandardOutput()
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
}
function Dbg { param([string]$Msg) if ($env:ROGUE_DEBUG) { [Console]::Error.WriteLine("[rogue] $Msg"); [Console]::Error.Flush() } }

# Errors the hook survives, NOT gated on ROGUE_DEBUG (mirrors hook.sh's err):
# this dispatcher keeps no log file, so a debug-gated message would mean nobody
# ever learns the install reports itself imprecisely. stderr only — stdout is the
# hook's JSON channel.
function Err { param([string]$Msg) [Console]::Error.WriteLine("[rogue] error: $Msg"); [Console]::Error.Flush() }

function Emit-Json {
    param([string]$Data)
    if (-not $Data) { Write-Raw '{}'; return }
    Write-Raw $Data
}

function ConvertFrom-ShellQuoted {
    # Decode one shell "word" the way `hook.sh` would when it `source`s the env
    # file, so values round-trip across both dispatchers. The env files are
    # written either POSIX single-quoted with `'\''` escapes (install.ps1) or
    # via bash `printf %q`, which emits backslash escapes and double quotes
    # (install.sh). A naive outer-quote strip mangles values like O'Brien
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
    # Cursor on non-UTF-8 Windows locales double-encodes assistant text
    # (UTF-8 -> CP1252 -> UTF-8): e.g. "—" arrives as "â€"" and "'" as "â€™".
    # We can't change the client's system locale, so repair it here: re-encode
    # the string as CP1252 and decode as UTF-8, with BOTH steps STRICT (throw on
    # any unmappable char / invalid byte). Genuine mojibake round-trips to valid
    # UTF-8 and is repaired; already-correct text (café, 😀, plain ASCII) fails
    # the strict round-trip and is returned unchanged — so this is a safe no-op
    # for well-behaved clients.
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

# ── hook log ───────────────────────────────────────────────────────────────
# `Dbg` above only writes to stderr under ROGUE_DEBUG, which Cursor keeps in its
# own per-session log — useless for after-the-fact diagnosis and unavailable to
# /rogue:status. So every invocation also gets one durable line here, in the same
# format hook.sh writes: "<ts> provider=cursor event=<E> <k=v>".
#
# ONE FILE PER AGENT. Every Rogue plugin shares ~/.rogue, so a single hook.log
# would interleave Cursor with Claude Code / Codex / … and lose attribution.
# Precedence: ROGUE_LOG_FILE → ROGUE_LOG_DIR/cursor.log → default, each read from
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
$script:surface = 'cursor'
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
        if ($d) { $f = Join-Path $d 'cursor.log' }
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

# Strip control characters: the logged text is SERVER-CONTROLLED (a block reason
# can carry anything), and a raw newline or CR would forge extra log lines.
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
            "$stamp provider=cursor$surfaceToken event=$EventName $Msg`n",
            (New-Object System.Text.UTF8Encoding $false))
    } catch {}
}

# ── File pre-image (preToolUse only) — lockstep with hook.sh ───────────────
# Cursor's preToolUse carries the FULL post-edit file and NO baseline, so the
# payload alone cannot say which part of the file this edit is responsible for.
# The file on disk still holds the PRE-edit content at this point, so we attach
# it as `rogueFilePreImageB64` and the API can compare the two.
#
# A NON-EXISTENT FILE YIELDS AN EMPTY PRE-IMAGE, AND THAT IS THE CREATE SIGNAL —
# no Cursor payload field distinguishes a create from an overwrite.
#
# MULTI-HUNK EDITS NEED NO SPECIAL HANDLING: Cursor emits one full cycle PER
# HUNK, so by hunk 2 the file on disk already contains hunk 1 and the pre-image
# IS the correct per-hunk baseline. Never "fix" this into reading the whole
# turn's pre-state.
#
# Fail-open in every branch. An OVER-CAP file sends NO pre-image rather than a
# truncated one: a partial pre-image is worse than none, because it
# misrepresents the file's pre-edit state instead of admitting we don't know it.
$RogueFilePreImageMaxBytes = 262144

# Every file the agent writes gets a pre-image, subject to the size cap above.
# The extension list below is the one exclusion: base64 of a PNG or a zip is
# pure payload with no text in it to compare, and binaries are also the files
# most likely to be large. An UNKNOWN extension is treated as text — the cost of
# shipping a binary we failed to recognize is bytes, while the cost of skipping
# a text file is losing the comparison entirely.
#
# COST: for a file write this roughly doubles the request body, since the event
# payload already carries the post-edit content. The size cap bounds the worst
# case; nothing is sent for a file above it.
#
# Mirrors hook.sh's _is_binary_path. GetExtension returns the LAST extension, so
# `.tar.gz` matches on `.gz` exactly as the shell glob does.
function Test-RogueBinaryPath {
    param([string]$Path)
    if (-not $Path) { return $false }
    $ext = ''
    try { $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant() } catch { return $false }
    if (-not $ext) { return $false }
    $binary = @(
        # images
        '.png','.jpg','.jpeg','.gif','.bmp','.tif','.tiff','.ico','.icns','.webp','.avif','.heic','.psd',
        # fonts
        '.ttf','.otf','.woff','.woff2','.eot',
        # archives and packages
        '.zip','.tar','.gz','.tgz','.bz2','.xz','.zst','.7z','.rar','.jar','.war','.ear',
        '.whl','.egg','.nupkg','.dmg','.iso','.pkg','.deb','.rpm',
        # audio and video
        '.mp3','.wav','.flac','.ogg','.m4a','.mp4','.mov','.avi','.mkv','.webm',
        # compiled artifacts
        '.exe','.dll','.so','.dylib','.o','.a','.lib','.obj','.pdb','.class','.pyc','.pyo','.wasm','.node','.bin',
        # documents and databases
        '.pdf','.doc','.docx','.xls','.xlsx','.ppt','.pptx','.db','.sqlite','.sqlite3','.mdb'
    )
    return $binary -contains $ext
}

# Run jq with UTF-8 on the wire in both directions. PS 5.1 defaults native
# command encoding to the OEM code page, which silently mangles non-ASCII text
# on the round trip. Returns $null when jq is absent or exits non-zero, which is
# the caller's signal to use its own fallback.
function Invoke-RogueJq {
    param([string]$Body, [string[]]$JqArgs)
    if (-not (Get-Command jq -ErrorAction SilentlyContinue)) { return $null }
    $prevOut = $OutputEncoding
    $prevConsole = $null
    try { $prevConsole = [Console]::OutputEncoding } catch {}
    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $OutputEncoding = $utf8
        try { [Console]::OutputEncoding = $utf8 } catch {}
        $out = ($Body | & jq @JqArgs 2>$null) -join "`n"
        if ($LASTEXITCODE -ne 0) { return $null }
        return $out
    } catch {
        return $null
    } finally {
        $OutputEncoding = $prevOut
        if ($prevConsole) { try { [Console]::OutputEncoding = $prevConsole } catch {} }
    }
}

# One JSON string field: jq when it is on PATH, the regex only when it is not.
# jq is preferred because it understands nesting and unescaping, both of which
# the regex gets only by luck — `file_path` sits under `tool_input` on a tool
# event, and the regex takes whichever copy appears first. The regex stays safe
# for this narrow use because a `"` inside a JSON string value is always
# backslash-escaped, so `"file_path":"…"` cannot match text that merely appears
# inside the file CONTENT the same payload carries. Lockstep with hook.sh's
# _json_string_field.
function Get-RogueJsonStringField {
    param([string]$Body, [string]$JqFilter, [string]$Key)
    $viaJq = Invoke-RogueJq $Body @('-r', ($JqFilter + ' // empty'))
    if ($null -ne $viaJq) { return $viaJq.Trim() }
    $m = [regex]::Match($Body, '"' + [regex]::Escape($Key) + '"\s*:\s*"([^"]*)"')
    if (-not $m.Success) { return '' }
    # JSON-escaped backslashes in a Windows path are the norm, so unescape the
    # two sequences a path can legitimately contain (jq has already done this on
    # the other branch). hook.sh instead BAILS on a backslash: it only ever runs
    # on POSIX, where such a path is pathological. The divergence is deliberate,
    # not a lockstep slip.
    return $m.Groups[1].Value.Replace('\\', '\').Replace('\/', '/')
}

function Add-FilePreImage {
    # Deliberately NOT ConvertTo-Json on the whole payload: a full parse +
    # reserialize could alter the vendor's JSON in ways we don't control (and
    # truncates below its default -Depth 2). Every failure path returns the body
    # unchanged — we lose the pre-image, never the relay.
    param([string]$Body)
    try {
        # Only the file-writing tools have a file to pre-image. A preToolUse for
        # Shell, Read, Grep or an MCP call carries no relevant path. `Edit` is
        # listed defensively — Cursor has only ever been observed sending
        # `Write`.
        $tool = Get-RogueJsonStringField $Body '.tool_name' 'tool_name'
        if ($tool -ne 'Write' -and $tool -ne 'Edit') { return $Body }
        $path = Get-RogueJsonStringField $Body '.tool_input.file_path // .file_path' 'file_path'
        if (-not $path) { return $Body }
        # Rooted paths only: a relative path would resolve against the hook's
        # cwd, and a wrongly-"missing" file reads as a CREATE — the one wrong
        # answer that is worse than no answer, since it claims the whole file
        # is new.
        if ($path -notmatch '^([A-Za-z]:[\\/]|\\\\)') { return $Body }
        if (Test-RogueBinaryPath $path) { return $Body }

        $b64 = ''
        if (Test-Path -LiteralPath $path) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $Body }
            # FileShare ReadWrite: the editor may still hold the file open.
            $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
            try {
                $len = $fs.Length
                if ($len -gt $RogueFilePreImageMaxBytes) {
                    Dbg "pre-image $len B over cap -> sending none"
                    return $Body
                }
                if ($len -gt 0) {
                    $buf = New-Object byte[] ([int]$len)
                    # LOOP: FileStream.Read is only guaranteed to return at least one
                    # byte, not the count asked for. A single call that came up short
                    # used to be base64-encoded and attached as if it were the WHOLE
                    # file - the truncated pre-image the header above rules out, and a
                    # divergence from hook.sh, whose `base64 < "$_fp"` always consumes
                    # everything. A short total sends NO pre-image rather than a
                    # partial one: not knowing the pre-edit state is safe, while
                    # misreporting it is not. (Read-Range in ship-logs.ps1 carries the
                    # same loop, for the same reason.)
                    $read = 0
                    while ($read -lt [int]$len) {
                        $n = $fs.Read($buf, $read, [int]$len - $read)
                        if ($n -le 0) { break }
                        $read += $n
                    }
                    if ($read -ne [int]$len) {
                        Dbg "pre-image short read ($read of $len B) -> sending none"
                        return $Body
                    }
                    $b64 = [Convert]::ToBase64String($buf, 0, $read)
                }
            } finally { $fs.Close() }
        }
        Dbg "pre-image attached for $path ($($b64.Length) b64 chars)"

        # Same jq-or-string-concat duality as hook.sh: jq when it is on PATH,
        # otherwise strip the trailing '}', append, re-close. `$b64` is passed
        # as its own argument (base64 carries '+', '/' and '='); the jq filter
        # is single-quoted so PS leaves its own $b64 reference alone.
        $out = Invoke-RogueJq $Body @('-c', '--arg', 'b64', $b64, '. + {rogueFilePreImageB64:$b64}')
        # Only trust a complete object back; anything else falls through.
        if ($out -and $out.StartsWith('{') -and $out.EndsWith('}')) { return $out }

        # Trim trailing whitespace so the single-'}' strip lands on the real
        # closing brace, then strip exactly ONE '}' (TrimEnd('}') would strip ALL
        # of them and corrupt a body ending in "}}") — mirrors hook.sh.
        $p = $Body.TrimEnd()
        if (-not $p.EndsWith('}')) { return $Body }
        $p = $p.Substring(0, $p.Length - 1)
        # An empty object needs no separator ({} -> {"rogueFilePreImageB64":…}).
        $sep = ','
        if ($p -eq '{') { $sep = '' }
        return $p + $sep + '"rogueFilePreImageB64":"' + $b64 + '"}'
    } catch {
        Dbg "pre-image failed: $($_.Exception.Message)"
        return $Body
    }
}

# ── File read capture (beforeReadFile only), lockstep with hook.sh ─────────
# Cursor sends `beforeReadFile` with an empty `content` for some file types.
# Attach the file's own bytes as `rogueFileReadB64` so the request carries the
# file and not just its path. Over the cap a truncatable type is truncated and
# every other type is skipped, as the pre-image does. Every failure path
# returns the body unchanged.
$RogueFileReadMaxBytes = 1048576

function Test-RogueReadCapturePath {
    param([string]$Path)
    if (-not $Path) { return $false }
    $ext = [System.IO.Path]::GetExtension($Path)
    if (-not $ext) { return $false }
    return @('.pdf', '.svg') -contains $ext.ToLowerInvariant()
}

# Extensions whose bytes stay usable when they are cut short. An over-cap file
# NOT on this list is sent whole or not at all, as the pre-image does.
function Test-RogueReadCaptureTruncatable {
    param([string]$Path)
    if (-not $Path) { return $false }
    $ext = [System.IO.Path]::GetExtension($Path)
    if (-not $ext) { return $false }
    return @('.svg') -contains $ext.ToLowerInvariant()
}

function Add-FileReadBytes {
    # No ConvertTo-Json on the whole payload, as in Add-FilePreImage: a parse
    # and reserialize could alter the vendor's JSON, and -Depth truncates.
    param([string]$Body)
    try {
        # Get-RogueJsonStringField trims and the sh side's _json_string_field
        # does not, so a whitespace-only content fires here but not there.
        $content = Get-RogueJsonStringField $Body '.content' 'content'
        if ($content) { return $Body }

        $fp = Get-RogueJsonStringField $Body '.file_path // .tool_input.file_path' 'file_path'
        if (-not $fp) { return $Body }
        # Rooted paths only; a relative one would resolve against the hook's cwd.
        # Looser than Add-FilePreImage's Windows-shaped test on purpose: an
        # over-matching path here falls through to Test-Path and attaches
        # nothing, where the pre-image would report a real file as absent.
        if (-not [System.IO.Path]::IsPathRooted($fp)) { return $Body }
        if (-not (Test-RogueReadCapturePath $fp)) { return $Body }
        if (-not (Test-Path -LiteralPath $fp -PathType Leaf)) { return $Body }

        $len = (Get-Item -LiteralPath $fp).Length
        if ($len -le 0) { return $Body }
        if ($len -gt $RogueFileReadMaxBytes) {
            if (-not (Test-RogueReadCaptureTruncatable $fp)) {
                Dbg "read capture $len B over cap -> sending none"
                return $Body
            }
            Dbg "read capture $len B -> truncating to $RogueFileReadMaxBytes"
        }
        $take = [int][Math]::Min([int64]$len, [int64]$RogueFileReadMaxBytes)
        # Streamed rather than ReadAllBytes so an over-cap file is not fully
        # loaded just to discard most of it.
        $buf = New-Object byte[] $take
        $read = 0
        # FileShare ReadWrite, as in Add-FilePreImage. This fires on a READ, so
        # the editor is very likely holding the file and the default share mode
        # would throw and lose the capture.
        $fs = [System.IO.File]::Open($fp, 'Open', 'Read', 'ReadWrite')
        try {
            while ($read -lt $take) {
                $n = $fs.Read($buf, $read, $take - $read)
                if ($n -le 0) { break }
                $read += $n
            }
        } finally { $fs.Dispose() }
        if ($read -le 0) { return $Body }
        # A range index yields Object[] and ToBase64String takes byte[]. Cast
        # rather than rely on coercion, since 5.1 is the shipping runtime.
        if ($read -lt $take) { $buf = [byte[]]$buf[0..($read - 1)] }
        $b64 = [Convert]::ToBase64String($buf)
        if (-not $b64) { return $Body }
        Dbg "read capture attached for $fp ($($b64.Length) b64 chars)"

        # jq-or-concat, as in Add-FilePreImage. The base64 goes to jq as one
        # argument, and Windows caps a command line at 32,767 characters
        # (~24 KiB of file), so Invoke-RogueJq yields nothing and the concat
        # below is what runs. It is not dead code.
        $out = Invoke-RogueJq $Body @('-c', '--arg', 'b64', $b64, '. + {rogueFileReadB64:$b64}')
        if ($out -and $out.StartsWith('{') -and $out.EndsWith('}')) { return $out }

        $trimmed = $Body.TrimEnd()
        if (-not $trimmed.EndsWith('}')) { return $Body }
        $p = $trimmed.Substring(0, $trimmed.Length - 1)
        $sep = ','
        if ($p -eq '{') { $sep = '' }
        return $p + $sep + '"rogueFileReadB64":"' + $b64 + '"}'
    } catch {
        Dbg "read capture failed: $($_.Exception.Message)"
        return $Body
    }
}

# ── Subagent -> parent session attribution — lockstep with hook.sh ─────────
# A Cursor subagent's preToolUse / postToolUse / afterFileEdit /
# beforeShellExecution all arrive with conversation_id == session_id == THE
# CHILD'S OWN id, and no payload field names the parent. The one place the link
# exists is Cursor's transcript tree, where THE CHILD'S ID IS THE FILENAME:
#
#   %USERPROFILE%\.cursor\projects\<slug>\agent-transcripts\<parent>\subagents\<child>.jsonl
#
# so the parent is the grandparent directory's name. That makes this a KEY
# LOOKUP, not a search: two concurrent subagents each carry their own id and each
# find their own file. Never rank by mtime, never "pick the newest file".
#
# `transcript_path` is deliberately never read: it is JSON-null on ordinary
# parent events too, so branching on it would re-attribute main-agent traffic.
#
# Nothing here touches the payload. The resolved ids leave as headers only, so
# the relayed body stays byte-for-byte what Cursor sent.
$RogueSpawnMarkerTtlSeconds = 30   # observed subagentStart lead is 3.96-6.45s

function Get-RogueUserHome {
    if ($env:USERPROFILE) { return $env:USERPROFILE }
    return $env:HOME
}
function Get-RogueCursorProjectsDir {
    return [System.IO.Path]::Combine((Get-RogueUserHome), '.cursor', 'projects')
}
function Get-RogueParentCacheDir {
    return [System.IO.Path]::Combine((Get-RogueUserHome), '.rogue', 'cursor-parent')
}
function Get-RogueSpawnMarkerDir {
    return [System.IO.Path]::Combine((Get-RogueUserHome), '.rogue', 'cursor-spawn')
}

# A conversation id is a uuid. Anything outside that charset is not one, and it
# would also become a path component — so reject it rather than look it up.
function Test-RogueConversationId {
    param([string]$Id)
    if (-not $Id) { return $false }
    return ($Id -match '^[A-Za-z0-9-]+$')
}

# `workspace_roots` is an ARRAY, so it needs its own reader rather than
# Get-RogueJsonStringField. Lockstep with hook.sh's _workspace_root.
function Get-RogueWorkspaceRoot {
    param([string]$Body)
    $viaJq = Invoke-RogueJq $Body @('-r', '.workspace_roots[0] // empty')
    if ($viaJq) { return $viaJq.Trim() }
    $m = [regex]::Match($Body, '"workspace_roots"\s*:\s*\[\s*"([^"]*)"')
    if (-not $m.Success) { return '' }
    return $m.Groups[1].Value.Replace('\\', '\').Replace('\/', '/')
}

# Cursor's project-directory slug: the workspace path with the leading separator
# stripped and every "/" and "." turned into "-".
function Get-RogueWorkspaceSlug {
    param([string]$Body)
    $root = Get-RogueWorkspaceRoot $Body
    if (-not $root) { return '' }
    return ($root.TrimStart('/').Replace('/', '-').Replace('.', '-'))
}

# $ChildId's transcript file, if Cursor has written it. Slug-scoping is an
# OPTIMIZATION, not the mechanism: slug derivation has real exceptions on disk
# (numeric slugs, `empty-window`, `.code-workspace`-derived names), so a miss
# falls back to a scan of every project dir, which returns the SAME answer
# because the filename is the key.
function Get-RogueCursorParent {
    param([string]$ChildId, [string]$Slug)
    try {
        $projects = Get-RogueCursorProjectsDir
        $roots = @()
        if ($Slug) { $roots += [System.IO.Path]::Combine($projects, $Slug) }
        if (Test-Path -LiteralPath $projects) {
            foreach ($p in (Get-ChildItem -LiteralPath $projects -Directory -ErrorAction SilentlyContinue)) {
                if ($Slug -and $p.Name -eq $Slug) { continue }   # already first in line
                $roots += $p.FullName
            }
        }
        foreach ($r in $roots) {
            $transcripts = [System.IO.Path]::Combine($r, 'agent-transcripts')
            if (-not (Test-Path -LiteralPath $transcripts)) { continue }
            foreach ($d in (Get-ChildItem -LiteralPath $transcripts -Directory -ErrorAction SilentlyContinue)) {
                $f = [System.IO.Path]::Combine($d.FullName, 'subagents', ($ChildId + '.jsonl'))
                if (Test-Path -LiteralPath $f -PathType Leaf) { return $d.Name }
            }
        }
    } catch { Dbg "parent lookup failed: $($_.Exception.Message)" }
    return $null
}

# Any live marker under this workspace. The check is "is SOMETHING spawning",
# never "is MY parent spawning" — a child cannot know its parent before the
# lookup succeeds. Scoped per workspace because both sides derive the slug the
# same way from workspace_roots; unscoped only when this payload has no root.
function Test-RogueSpawnMarkerLive {
    param([string]$Slug)
    try {
        $root = Get-RogueSpawnMarkerDir
        if (-not (Test-Path -LiteralPath $root)) { return $false }
        $dirs = @()
        if ($Slug) {
            $dirs += [System.IO.Path]::Combine($root, $Slug)
        } else {
            foreach ($d in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
                $dirs += $d.FullName
            }
        }
        $cutoff = (Get-Date).AddSeconds(-$RogueSpawnMarkerTtlSeconds)
        foreach ($d in $dirs) {
            if (-not (Test-Path -LiteralPath $d)) { continue }
            foreach ($f in (Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue)) {
                if ($f.LastWriteTime -ge $cutoff) { return $true }
            }
        }
    } catch { Dbg "marker check failed: $($_.Exception.Message)" }
    return $false
}

# subagentStart fires ON THE PARENT (conversation_id == the parent's id, verified
# on all 9 real payloads) and 3.96-6.45s BEFORE the child's subagents file
# exists. That window is exactly what the marker covers. Every step is
# best-effort: a lost marker costs a wait that would not have happened, never a
# wrong answer.
function Write-RogueSpawnMarker {
    param([string]$Body)
    try {
        $id = Get-RogueJsonStringField $Body '.conversation_id' 'conversation_id'
        if (-not (Test-RogueConversationId $id)) { return }
        $slug = Get-RogueWorkspaceSlug $Body
        if (-not $slug) { $slug = '_' }
        $dir = [System.IO.Path]::Combine((Get-RogueSpawnMarkerDir), $slug)
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null
        }
        $file = [System.IO.Path]::Combine($dir, $id)
        [System.IO.File]::WriteAllText($file, '')
        Dbg "spawn marker $slug/$id"
    } catch { Dbg "spawn marker failed: $($_.Exception.Message)" }
}

# Best-effort only. subagentStop carries no subagent_id and a killed subagent
# never emits one, so nothing may depend on this running; the TTL is what
# actually retires a marker.
function Remove-RogueSpawnMarker {
    param([string]$Body)
    try {
        $id = Get-RogueJsonStringField $Body '.conversation_id' 'conversation_id'
        if (-not (Test-RogueConversationId $id)) { return }
        $slug = Get-RogueWorkspaceSlug $Body
        if (-not $slug) { $slug = '_' }
        $file = [System.IO.Path]::Combine((Get-RogueSpawnMarkerDir), $slug, $id)
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    } catch { Dbg "spawn marker cleanup failed: $($_.Exception.Message)" }
}

# Returns @{ Parent = <parent id>; Child = <child id> } or $null. Fail-open in
# every branch: unresolved means no headers and today's POST exactly.
function Resolve-RogueParentSession {
    param([string]$Body)
    try {
        $id = Get-RogueJsonStringField $Body '.conversation_id' 'conversation_id'
        if (-not (Test-RogueConversationId $id)) { return $null }

        # Cache, mirroring the Copilot dispatcher's submap: a subagent fires
        # 18-223 hooks per spawn and Cursor REUSES a child id across re-spawns,
        # so the scan runs once per subagent, ever. Only a subagent's first hook
        # can miss.
        $cacheDir = Get-RogueParentCacheDir
        $cacheFile = [System.IO.Path]::Combine($cacheDir, $id)
        if (Test-Path -LiteralPath $cacheFile -PathType Leaf) {
            $cached = ([System.IO.File]::ReadAllText($cacheFile)).Trim()
            if ($cached) { Dbg 'parent cache hit'; return @{ Parent = $cached; Child = $id } }
        }

        $slug = Get-RogueWorkspaceSlug $Body
        $parent = Get-RogueCursorParent $id $slug
        if (-not $parent) {
            # The child's file is born 0.811-1.627s after its first hook, and its
            # creation is INDEPENDENT of hook returns (one spawn's file appeared
            # 2.40s before any blocking hook fired), so this wait cannot
            # self-deadlock. hooks.json allows 120s per hook, so ~3s is 2.5% of
            # the budget.
            #
            # NEVER spin without a live marker: a brand-new TOP-LEVEL
            # conversation has no directory of its own for ~9s and so looks
            # exactly like an unresolved child.
            $max = 30   # ~3s at 100ms/iter
            if ($env:ROGUE_CURSOR_PARENT_ITERS) { $max = [int]$env:ROGUE_CURSOR_PARENT_ITERS }
            if (-not (Test-RogueSpawnMarkerLive $slug)) { $max = 0 }
            for ($n = 0; $n -lt $max; $n++) {
                Start-Sleep -Milliseconds 100
                $parent = Get-RogueCursorParent $id $slug
                if ($parent) { break }
            }
        }
        if (-not $parent) { return $null }

        if (-not (Test-Path -LiteralPath $cacheDir)) {
            New-Item -ItemType Directory -Path $cacheDir -Force -ErrorAction SilentlyContinue | Out-Null
        }
        try { [System.IO.File]::WriteAllText($cacheFile, $parent) } catch {}
        return @{ Parent = $parent; Child = $id }
    } catch {
        Dbg "parent resolution failed: $($_.Exception.Message)"
        return $null
    }
}

# Test seam: dot-sourcing with ROGUE_PS_LIB_ONLY=1 loads the functions above
# (e.g. ConvertFrom-ShellQuoted, Rotate-Log) without running the dispatcher.
# Production never sets this, so the hook always runs its main body.
if ($env:ROGUE_PS_LIB_ONLY) { return }

# Windows PowerShell 5.1 may negotiate only TLS 1.0/1.1 by default, which
# modern HTTPS endpoints reject ("Could not create SSL/TLS secure channel").
# Add TLS 1.2 without clobbering any protocols already enabled.
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

# ── stand down on non-Windows (pwsh on macOS/Linux) ────────────────────────
# $IsWindows exists only in PowerShell 6+. In 5.1 (Windows-only) it is $null,
# so guard on the version to avoid a false stand-down there.
if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { Write-Raw '{}'; exit 0 }

if (-not $EventName) { Dbg "no event name -> {}"; Write-Raw '{}'; exit 0 }
Dbg "event=$EventName"

# ── credential resolution ──────────────────────────────────────────────────
$creds = @{}
$pluginRoot = $env:CURSOR_PLUGIN_ROOT
if (-not $pluginRoot) { try { $pluginRoot = (Get-Location).Path } catch { $pluginRoot = '.' } }
Dbg "pluginRoot=$pluginRoot"

foreach ($k in 'ROGUE_API_KEY','ROGUE_ACTOR_EMAIL','ROGUE_ACTOR_NAME','ROGUE_BASE_URL',
               'ROGUE_LOG_FILE','ROGUE_LOG_DIR','ROGUE_LOG_MAX_BYTES',
               'ROGUE_HEARTBEAT_MIN_INTERVAL') {
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
    if ($EventName -eq 'sessionStart') {
        Write-Raw '{"additional_context": "Rogue Security plugin is installed but not configured. Run /rogue:setup to connect your API key."}'
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

# ── actor resolution: explicit creds → git config → username/hostname ──────
$actorName = $creds['ROGUE_ACTOR_NAME']
if (-not $actorName) { try { $actorName = (& git config --global user.name 2>$null | Out-String).Trim() } catch {} }
if (-not $actorName) { $actorName = $env:USERNAME }

$actorEmail = $creds['ROGUE_ACTOR_EMAIL']
if (-not $actorEmail) { try { $actorEmail = (& git config --global user.email 2>$null | Out-String).Trim() } catch {} }
if (-not $actorEmail) {
    if ($env:USERNAME -and $env:COMPUTERNAME) { $actorEmail = "$($env:USERNAME)@$($env:COMPUTERNAME)" }
    elseif ($env:USERNAME) { $actorEmail = $env:USERNAME }
    else { $actorEmail = $env:COMPUTERNAME }
}

# ── install identity: host + plugin version ────────────────────────────────
# The fleet roster keys an install on host + actor + family + agent, and until
# now only the heartbeat below ever sent those, once, at session start. A session
# still working a day later therefore aged out as disconnected. Sending the same
# values as headers on EVERY event lets the backend refresh this exact row from
# ordinary hook traffic. They must match the heartbeat body's values exactly, or
# the two writers create two rows for one install.
#
# Neither lookup can fail the hook: a degraded value still identifies the install
# well enough to keep the roster fresh, and no liveness bookkeeping is worth
# breaking a session over. Both log an error, because "unknown" in the roster is a real
# symptom worth chasing.
$hostName = $env:COMPUTERNAME
if (-not $hostName) { try { $hostName = [System.Net.Dns]::GetHostName() } catch { $hostName = '' } }
if (-not $hostName) {
    $hostName = 'unknown'
    Err 'hostname unresolved; reporting host=unknown to the fleet roster'
}

# Plugin version from the manifest.
$pluginVersion = 'unknown'
$pluginJson = Join-Path $pluginRoot '.cursor-plugin/plugin.json'
if (Test-Path -LiteralPath $pluginJson) {
    try {
        $v = (Get-Content -Raw -LiteralPath $pluginJson | ConvertFrom-Json).version
        if ($v -match '^[0-9]+\.[0-9]+\.[0-9]+') { $pluginVersion = $Matches[0] }
        # Manifest is there but carries no semver: schema drift, not a bad install.
        else { Err "no version in $pluginJson; reporting version=unknown to the fleet roster" }
    } catch {
        Err "plugin.json parse failed ($($_.Exception.Message)); reporting version=unknown"
    }
} else {
    Err "plugin manifest not found at $pluginJson; reporting version=unknown"
}

# ── payload from stdin ─────────────────────────────────────────────────────
$payload = [Console]::In.ReadToEnd()
if (-not $payload) { $payload = '{}' }
# Cursor sends a UTF-8 payload, but the console often reads stdin under a legacy
# OEM codepage (observed in the field: IBM437), which mojibakes it — e.g. the
# leading UTF-8 BOM (bytes EF BB BF) decodes to "∩╗┐", not a single U+FEFF.
# Chasing per-codepage code points is futile, so instead round-trip the string
# back through the ACTUAL input encoding to recover the original bytes, then
# decode them as real UTF-8. CP437↔Unicode is a bijection, so this also fully
# recovers any non-ASCII prompt text. No-op when the console is already UTF-8.
Dbg "InputEncoding=$([Console]::InputEncoding.WebName) CP=$([Console]::InputEncoding.CodePage)"
try {
    $raw = [Console]::InputEncoding.GetBytes($payload)
    $payload = [System.Text.Encoding]::UTF8.GetString($raw)
} catch { Dbg "utf8 re-decode failed: $($_.Exception.Message)" }

# After re-decoding, a UTF-8 BOM is a single U+FEFF char. Strip it: a
# BOM-prefixed body is invalid JSON and the API rejects it with HTTP 400.
$payload = $payload.TrimStart([char]0xFEFF)

# Repair Cursor's UTF-8 -> CP1252 -> UTF-8 double-encoding of assistant text,
# which happens on clients with a non-UTF-8 Windows locale (out of our control).
$payload = Repair-DoubleEncodedUtf8 $payload

# The two places this dispatcher adds to the vendor payload. Both only ever
# append a field; a failure leaves the body byte-identical.
if ($EventName -eq 'preToolUse') { $payload = Add-FilePreImage $payload }
if ($EventName -eq 'beforeReadFile') { $payload = Add-FileReadBytes $payload }

# Only the events a subagent actually fires resolve. sessionStart / sessionEnd /
# subagentStart / subagentStop are parent-side: they already carry the parent's
# own conversation id, so resolving would be pointless and waiting would tax
# every session start.
$attribution = $null
switch ($EventName) {
    'subagentStart'  { Write-RogueSpawnMarker $payload }
    'subagentStop'   { Remove-RogueSpawnMarker $payload }
    'sessionStart'   { }
    'sessionEnd'     { }
    default          { $attribution = Resolve-RogueParentSession $payload }
}

# ── POST (fail-open) ───────────────────────────────────────────────────────
$headers = @{
    'x-rogue-api-key'     = $apiKey
    'x-rogue-event'       = $EventName
    'x-rogue-actor-email' = $actorEmail
    'x-rogue-actor-name'  = $actorName
    'x-rogue-source'      = 'cursor'
    'x-rogue-host'        = $hostName
    'x-rogue-version'     = $pluginVersion
    'x-rogue-agent'       = 'cursor'
}
# Added CONDITIONALLY, and always as a pair: a subagent's events carry the
# parent's session id plus the child's own conversation id, a main agent's carry
# neither. Never add a key with an empty value — the backend prefers this header
# over the body's conversation_id, so an empty one would resolve to nothing.
if ($attribution) {
    $headers['x-rogue-parent-session-id'] = $attribution.Parent
    $headers['x-rogue-agent-id']          = $attribution.Child
}

$url = "$baseUrl/api/v1/hooks/cursor"
$parentDbg = if ($attribution) { $attribution.Parent } else { 'none' }
Dbg "POST $url actor=$actorEmail parent=$parentDbg"
# Send an explicit UTF-8 byte array: Windows PowerShell 5.1's Invoke-WebRequest
# re-encodes a string body (commonly to Latin-1), which corrupts non-ASCII
# prompt content and can reintroduce a BOM. GetBytes() never emits a BOM.
$bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
$resp = ''
$postError = ''
try {
    $r = Invoke-WebRequest -Uri $url -Method Post `
        -Headers $headers -ContentType 'application/json' -Body $bodyBytes `
        -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
    Dbg "HTTP $($r.StatusCode), body length $($r.Content.Length)"
    if ($r.StatusCode -eq 200) {
        # Decode the body explicitly as UTF-8. Invoke-WebRequest's .Content
        # mis-decodes as ISO-8859-1 when the server omits a charset, turning
        # UTF-8 punctuation (— ') into mojibake (â€" â€™). RawContentStream
        # holds the original bytes.
        try { $resp = [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) }
        catch { $resp = [string]$r.Content }
    }
} catch {
    Dbg "POST failed: $($_.Exception.Message)"
    # On a 4xx/5xx the body usually explains why; surface it under ROGUE_DEBUG.
    # PS7 stashes it in ErrorDetails.Message; PS5.1 needs the response stream.
    $errBody = $null
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
        $errBody = $_.ErrorDetails.Message
    } elseif ($_.Exception.Response) {
        try {
            $stream = $_.Exception.Response.GetResponseStream()
            $sr = New-Object System.IO.StreamReader($stream)
            $errBody = $sr.ReadToEnd(); $sr.Close()
        } catch {}
    }
    if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
        Dbg "error status: $([int]$_.Exception.Response.StatusCode)"
    }
    if ($errBody) { Dbg "error response body: $errBody" }
    $postError = $_.Exception.Message
    $resp = ''
}

# Exactly one line per invocation, always, so a relay/decision bug is
# diagnosable from the hook log alone without re-instrumenting the script
# (mirrors hook.sh's `log "rc=… raw=…"`). An empty `raw=` means fail-open: either
# the request threw (then `error=` says why) or the server answered non-200.
$respHead = if ($resp.Length -gt 400) { $resp.Substring(0, 400) } else { $resp }
if ($postError) { Log "raw=$(Sanitize $respHead) error=`"$(Sanitize $postError)`"" }
else            { Log "raw=$(Sanitize $respHead)" }

Emit-Json $resp

# ── presence heartbeat (sessionStart + stop) ────────────────────────────────
# POSTs /api/v1/hooks/status so this install shows in the dashboard's Coding
# Agents roster (Connected / version / host / user). Pure side-effect: response
# ignored, fully wrapped so it can never affect the already-emitted hook
# response. Runs AFTER Emit-Json; PowerShell has no reliable fire-and-forget
# across process exit, so this is a sync POST (10s cap). Creds/actor were already
# resolved above.
#
# TWO TRIGGERS, matching hook.sh. `sessionStart` fires once per session; `stop` fires
# once per TURN, and it exists because a session left open for days used to produce
# exactly one beacon and one log upload for its whole lifetime - the roster row went
# stale and the hook log sat on disk unshipped.
#
# There is no heartbeat.ps1 here to carry the trigger, so the throttle is applied
# inline via scripts/beacon.ps1 - a byte-identical copy of scripts/shared/beacon.ps1,
# the same library the other four PowerShell heartbeats load. `sessionStart` stays
# unthrottled. THE SYNC POST IS EXACTLY WHY THE THROTTLE MATTERS MORE HERE than
# anywhere else: on this plugin the beacon is not detached, so an unthrottled
# per-turn beacon would add its latency to every single turn.
$hbUnthrottled = $null
if     ($EventName -eq 'sessionStart') { $hbUnthrottled = $true }
elseif ($EventName -eq 'stop')         { $hbUnthrottled = $false }
if ($null -ne $hbUnthrottled) {
    # Loaded as a SCRIPTBLOCK from the file's text, at SCRIPT scope: dot-sourcing runs
    # in the caller's scope, so loading it inside a function would define the library
    # there and lose it on return. Never -File or a path dot-source - both are subject
    # to ExecutionPolicy and to a GPO-enforced policy that Bypass cannot override.
    #
    # A missing or unparseable library degrades to an UNTHROTTLED beacon - today's
    # behaviour, and the safe direction.
    $beaconLib = Join-Path $pluginRoot 'scripts\beacon.ps1'
    if (Test-Path -LiteralPath $beaconLib) {
        try { . ([scriptblock]::Create((Get-Content -Raw -LiteralPath $beaconLib))) }
        catch { Dbg "beacon library not loaded: $($_.Exception.Message)" }
    }
    if (-not (Get-Command Request-RogueBeaconSlot -ErrorAction SilentlyContinue)) {
        function Initialize-RogueBeacon { param([hashtable]$Creds = @{}) }
        function Request-RogueBeaconSlot { param([string]$Slug, [bool]$Unthrottled = $false) return $true }
    }
    # From the CREDENTIAL MAP, not $env: - the map is what carries the env files'
    # resolved precedence, and ROGUE_HEARTBEAT_MIN_INTERVAL rides its process-env
    # override list above so process env still wins.
    Initialize-RogueBeacon $creds

    try {
        # `agent` is "cursor" (not a display label): the server keys its
        # latest-version lookup (PLUGIN_REPOS) on this value, so the roster can
        # flag outdated installs. host/version come from the shared block above
        # so this body and the per-event headers describe the same install
        # (same fingerprint, one row).
        $hbBody = @{
            agent_family = 'cursor'
            agent        = 'cursor'
            version      = $pluginVersion
            host         = $hostName
            actor_email  = $actorEmail
            actor_name   = $actorName
        } | ConvertTo-Json -Compress

        $hbHeaders = @{
            'x-rogue-api-key' = $apiKey
            'x-rogue-source'  = 'cursor'
        }
        $hbUrl = "$baseUrl/api/v1/hooks/status"
        # Request-RogueBeaconSlot writes the stamp itself, BEFORE the request -
        # deciding and stamping are one call so a caller cannot leave the window
        # permanently open by forgetting the second half.
        if (Request-RogueBeaconSlot -Slug 'cursor' -Unthrottled $hbUnthrottled) {
            Dbg "heartbeat POST $hbUrl ver=$hbVer host=$hbHost"
            $hbBytes = [System.Text.Encoding]::UTF8.GetBytes($hbBody)
            $r = Invoke-WebRequest -Uri $hbUrl -Method Post `
                -Headers $hbHeaders -ContentType 'application/json' -Body $hbBytes `
                -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            Dbg "heartbeat HTTP $($r.StatusCode)"
            Log "heartbeat=$($r.StatusCode) ver=$hbVer"
        } else {
            # Logged, unlike the other plugins' silent throttle, because this is the
            # only plugin whose beacon decision happens in the dispatcher - so the
            # hook log is where an operator can see it at all. Matches hook.sh.
            Dbg 'heartbeat throttled'
            Log "heartbeat=throttled ver=$hbVer"
        }
        Dbg "heartbeat POST $hbUrl ver=$pluginVersion host=$hostName"
        $hbBytes = [System.Text.Encoding]::UTF8.GetBytes($hbBody)
        $r = Invoke-WebRequest -Uri $hbUrl -Method Post `
            -Headers $hbHeaders -ContentType 'application/json' -Body $hbBytes `
            -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        Dbg "heartbeat HTTP $($r.StatusCode)"
        Log "heartbeat=$($r.StatusCode) ver=$pluginVersion"
    } catch {
        Dbg "heartbeat POST failed: $($_.Exception.Message)"
        Log "heartbeat=fail ver=$pluginVersion error=`"$(Sanitize $_.Exception.Message)`""
    }

    # ── ship the hook log ────────────────────────────────────────────────────
    # A SEPARATE, HIDDEN PROCESS, and here that is doing two jobs at once. As in
    # the other PowerShell callers, in-process would let the shipper's `$script:`
    # writes land on this dispatcher's variables and its `exit 0` end the
    # dispatcher before it prints the relayed response. On top of that, unlike
    # heartbeat.ps1 this file IS the synchronous dispatcher - Cursor is waiting on
    # our stdout - so the upload must not be awaited at all. Start-Process without
    # -Wait returns immediately.
    #
    # After the heartbeat, so the roster row the log attaches to exists first.
    #
    # Runs on BOTH triggers and deliberately OUTSIDE the beacon throttle above: a
    # throttled beacon still means a turn happened, and the log is worth draining
    # either way. This is the whole point of the `stop` trigger - on `sessionStart`
    # alone, a long session's log never left the disk.
    #
    # Every value travels as an environment variable, so the command is a constant
    # with nothing to escape. The actor is passed in, never re-resolved: Cursor's
    # cascade ends at "$env:USERNAME@$env:COMPUTERNAME" where actor.sh ends at the
    # hostname, so a second cascade would key the log's source row differently
    # from the roster row just posted.
    $shipScript = Join-Path $pluginRoot 'scripts\ship-logs.ps1'
    if (Test-Path -LiteralPath $shipScript) {
        try {
            $env:ROGUE_ACTOR_EMAIL     = [string]$actorEmail
            $env:ROGUE_ACTOR_NAME      = [string]$actorName
            $env:ROGUE_SHIPPER_SCRIPT  = $shipScript
            $env:ROGUE_SHIPPER_ROOT    = $pluginRoot
            $env:ROGUE_SHIPPER_SLUG    = 'cursor'
            $env:ROGUE_SHIPPER_VERSION = [string]$hbVer
            $env:ROGUE_SHIPPER_FAMILY  = 'cursor'
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
}

exit 0
