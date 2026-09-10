#!/usr/bin/env bash
# Usage: hook.sh <EventName>
# Reads JSON payload on stdin, POSTs to Rogue, relays response. Fail-open: any failure → "{}".
# Logs every invocation to $ROGUE_LOG_FILE (default ~/.rogue/logs/claude.log).

EVENT="$1"

# Git Bash stand-down: on native Windows hook.ps1 owns event handling. Git Bash's
# `~` maps to %USERPROFILE% — the SAME creds hook.ps1 reads — so without this both
# would POST (and double-alert on a block). macOS/Linux/WSL fall through and run.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) echo '{}'; exit 0 ;;
esac

# The first env file holding ROGUE_API_KEY is used alone: machine, bundled, user.
for _env_file in /etc/rogue/env "${CLAUDE_PLUGIN_ROOT:-}/env" "$HOME/.rogue-env"; do
  if [ -r "$_env_file" ] && grep -Eq "^[[:space:]]*(export[[:space:]]+)?ROGUE_API_KEY=[\"']?[^\"'[:space:]]" "$_env_file"; then
    . "$_env_file"; break
  fi
done

[ -z "${CLAUDE_CODE_ENTRYPOINT:-}" ] && echo '{}' && exit 0

# Which SURFACE of Claude wrote this line - cli, desktop or cowork. One file per
# agent family means every surface on the machine appends to the same claude.log,
# and nothing on the line said which one. The mapping is shared with heartbeat.sh
# (see scripts/surface.sh) precisely so the line and the roster row it belongs to
# can never name different surfaces. Sourcing is guarded and the result may be
# empty; an empty SURFACE omits the token rather than writing surface=unknown.
# Unreachable here in practice: the gate above already returned when the
# entrypoint was unset, and any non-empty value maps to a slug.
SURFACE=""
if [ -r "${CLAUDE_PLUGIN_ROOT}/scripts/surface.sh" ]; then
  . "${CLAUDE_PLUGIN_ROOT}/scripts/surface.sh"
  SURFACE=$(rogue_surface_slug 2>/dev/null)
fi

# Log destination — ONE FILE PER AGENT. Every Rogue plugin shares ~/.rogue, so a
# machine running Claude Code + Codex + Cursor + … used to interleave all of them
# into a single hook.log with no way to tell whose line was whose. Precedence:
# explicit file → directory override → per-agent default.
ROGUE_LOG_DIR="${ROGUE_LOG_DIR:-$HOME/.rogue/logs}"
ROGUE_LOG_FILE="${ROGUE_LOG_FILE:-$ROGUE_LOG_DIR/claude.log}"
# Size cap. Over it, the current log is renamed to <file>.1 - exactly one
# generation kept, so worst case on disk is 2x this. A NUMERIC ZERO disables
# rotation; a NON-NUMERIC value falls back to this default, so a typo can
# never leave the log growing unbounded. Enforced on the WRITE PATH rather
# than by a periodic job because an UNCONFIGURED install writes a line per
# event and never runs anything else - a cap enforced anywhere else would
# not hold.
ROGUE_LOG_MAX_BYTES="${ROGUE_LOG_MAX_BYTES:-10485760}"
# Clamp per the rule above: anything non-numeric becomes the default.
case "$ROGUE_LOG_MAX_BYTES" in ""|*[!0-9]*) ROGUE_LOG_MAX_BYTES=10485760 ;; esac
# An all-digit value can still overflow the shell's integer type: dash answers
# `[ "$cap" -gt 0 ]` with "Illegal number" on stderr and a FALSE, which reads
# as "rotation disabled" and lets the log grow unbounded. Node has the same
# bug through Number() -> Infinity; PowerShell is the only one that already
# lands on the default, and only because its cast error is silenced. All
# three clamp explicitly now. 18 digits is the widest value guaranteed to fit
# a signed 64-bit int; leading zeros are stripped first so "000...0" still
# reads as the rotation-disabling zero.
_lcap="$ROGUE_LOG_MAX_BYTES"
while [ "${_lcap#0}" != "$_lcap" ]; do _lcap="${_lcap#0}"; done
if [ "${#_lcap}" -gt 18 ]; then ROGUE_LOG_MAX_BYTES=10485760; fi
rotate_log() {
  [ -f "$ROGUE_LOG_FILE" ] || return 0
  # Arithmetic, not a glob: "00" must mean zero here exactly as [int64]"00"
  # and Number("00") do in the PowerShell and Node dispatchers.
  [ "$ROGUE_LOG_MAX_BYTES" -gt 0 ] || return 0
  # `wc -c` not `stat`: BSD and GNU stat take different flags for file size.
  _lsz=$(wc -c < "$ROGUE_LOG_FILE" 2>/dev/null | tr -d '[:space:]')
  case "$_lsz" in ''|*[!0-9]*) return 0 ;; esac
  [ "$_lsz" -ge "$ROGUE_LOG_MAX_BYTES" ] && mv -f "$ROGUE_LOG_FILE" "$ROGUE_LOG_FILE.1" 2>/dev/null
  return 0
}
log() {
  # 0700 dir / 0600 file. The logged text is not only ours: it carries the
  # server's block reason, which quotes the content that tripped the rule - a
  # secret, a command, a slice of a prompt. Under the default umask the log
  # lands 0644 and every other account on the box can read it. The umask
  # applies to what THIS call creates, so a 0644 log from an older version
  # keeps its mode; Windows needs no counterpart, since another standard user
  # cannot read %USERPROFILE% to begin with.
  ( umask 077
    mkdir -p "$(dirname "$ROGUE_LOG_FILE")" 2>/dev/null
    rotate_log
    # `${SURFACE:+ surface=$SURFACE}` expands to NOTHING when the slug is empty,
    # so an undetermined surface leaves the line exactly as older versions wrote
    # it - the token is optional, never `surface=` and never `surface=unknown`.
    printf '%s provider=claude%s event=%s %s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SURFACE:+ surface=$SURFACE}" \
      "$EVENT" "$*" >> "$ROGUE_LOG_FILE" 2>/dev/null )
}
sanitize() { printf '%s' "$1" | tr -d '\000-\037\177'; }

# True (0) when a native block modal should be fired for this event.
#
# Claude Code CLI and the Claude Desktop app both render hook block messages
# themselves, so a modal there would double-report — that is why c31ee5a deleted
# this path and called the plugin pure relay. Claude Cowork, which was not a
# surface then, breaks that claim: its client discards hook-authored text on
# EVERY documented channel. Measured 2026-08-18, one session per surface:
# `{"decision":"block","reason":R}`, `{"continue":false,"stopReason":R}`, a
# sibling `systemMessage`, and hook exit 2 with the message on stderr all stop
# the turn and show NO text. Only `hookSpecificOutput.additionalContext` renders,
# and only because the model relays it. So on Cowork the OS modal is the one
# channel that reaches the user.
#
# Cowork CLOUD sessions run the hook inside a headless Linux container (root,
# HOME=/root, no osascript, no DISPLAY, no DBUS), where a modal can never be
# seen. They are excluded explicitly rather than left to fail silently, so
# ~/.rogue/hook.log stays honest about what the user was and was not told.
_rogue_want_alert() {
  # 1. Cowork only. Reuse install-id.sh's surface resolution instead of
  #    re-deriving it: it already checks CLAUDE_CODE_IS_COWORK first (Cowork
  #    spawns Claude Code with CLAUDE_CODE_ENTRYPOINT=local-agent, NOT a *cowork*
  #    value) and falls back to a *cowork* entrypoint match, which is what cloud
  #    sessions ("remote_cowork") carry. A second copy of that cascade here would
  #    drift from the roster's, exactly as install-id.sh warns.
  [ "${ROGUE_INSTALL_AGENT:-}" = "claude_cowork" ] || return 1
  # 2. Local execution only. CLAUDE_CODE_REMOTE=true marks the cloud container.
  [ -z "${CLAUDE_CODE_REMOTE:-}" ] || return 1
  # 3. Escape hatches, so the blast radius can be changed without a release:
  #    ROGUE_ALERT=0 disables the modal entirely; ROGUE_ALERT_EVENTS, when set, is
  #    a space-separated allowlist of event names. The latter exists because tool
  #    denials have only been confirmed to render in Cowork CLOUD — if they turn
  #    out to render in local Cowork too, this narrows to
  #    ROGUE_ALERT_EVENTS="UserPromptSubmit" (the one event with no visible
  #    channel) with no code change. See CLAUDE.md.
  [ "${ROGUE_ALERT:-1}" = "0" ] && return 1
  if [ -n "${ROGUE_ALERT_EVENTS:-}" ]; then
    case " $ROGUE_ALERT_EVENTS " in
      *" $EVENT "*) ;;
      *) return 1 ;;
    esac
  fi
  # 4. Capability is the final authority — the env vars above are undocumented
  #    and will move. A GUI channel that is not there means no modal, whatever
  #    the vars say. Only osascript is probed: local Cowork runs on the macOS
  #    host (CLAUDE_CODE_HOST_PLATFORM=darwin). security-alert.sh has a
  #    notify-send fallback, so add it here if a Linux Cowork host ever appears.
  command -v osascript >/dev/null 2>&1 || return 1
  return 0
}

if [ -z "${ROGUE_API_KEY:-}" ]; then
  log "outcome=unconfigured"
  echo '{}'
  exit 0
fi

. "${CLAUDE_PLUGIN_ROOT}/scripts/actor.sh"
# Host + version + surface label, resolved exactly as heartbeat.sh does. Sent on
# every event so the fleet roster's row stays fresh between session starts, which
# are the only moments the heartbeat runs. See install-id.sh.
. "${CLAUDE_PLUGIN_ROOT}/scripts/install-id.sh"
# A degraded value is still sent (never a hard failure — see install-id.sh), but
# it is worth knowing about: an "unknown" host or version means this install
# reports itself imprecisely to the fleet roster.
[ -n "${ROGUE_INSTALL_ID_ERROR:-}" ] && log "error=install-id $ROGUE_INSTALL_ID_ERROR"

RESP=$(curl -sS -X POST "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/claude" \
  -H "x-rogue-api-key: $ROGUE_API_KEY" \
  -H "x-rogue-event: $EVENT" \
  -H "x-rogue-agent: $ROGUE_INSTALL_AGENT" \
  -H "x-rogue-host: $ROGUE_INSTALL_HOST" \
  -H "x-rogue-version: $ROGUE_INSTALL_VERSION" \
  -H "x-rogue-actor-email: $ROGUE_ACTOR_EMAIL" \
  -H "x-rogue-actor-name: $ROGUE_ACTOR_NAME" \
  -H 'Content-Type: application/json' \
  --data-binary @- --max-time 15 || echo '{}')

# Always log raw response so block-detection bugs are diagnosable from
# ~/.rogue/logs/claude.log alone, without re-instrumenting the script.
log "raw=$(sanitize "$RESP" | head -c 400)"

# Pure-shell block detection. We deliberately do NOT use python3 — on a fresh
# macOS the stub at /usr/bin/python3 fails silently without Xcode CLT,
# producing empty parser output that masquerades as "allow". grep + sed are
# always present.
#
# Covers every block-decision shape Claude Code's hook protocol emits:
#   "decision":"block"           UserPromptSubmit, Stop (top-level)
#   "continue":false             legacy block signal
#   "permissionDecision":"deny"  PreToolUse (inside hookSpecificOutput)
#   "decision":"block"           PostToolUse (inside hookSpecificOutput)
#   "behavior":"deny"            PermissionRequest (inside hookSpecificOutput.decision)
BLOCK=0
if printf '%s' "$RESP" | grep -qiE '"decision"[[:space:]]*:[[:space:]]*"block"|"continue"[[:space:]]*:[[:space:]]*false|"permissionDecision"[[:space:]]*:[[:space:]]*"deny"|"behavior"[[:space:]]*:[[:space:]]*"deny"'; then
  BLOCK=1
fi

if [ "$BLOCK" = "1" ]; then
  # Extract reason. First-match heuristic across the field names the formatter
  # uses (permissionDecisionReason for PreToolUse, reason for everything else,
  # stopReason for continue:false). Limitation: doesn't handle JSON-escaped
  # quotes inside reason text — Rogue's reasons don't contain them.
  REASON=$(printf '%s' "$RESP" | sed -E -n 's/.*"permissionDecisionReason"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -1)
  [ -z "$REASON" ] && REASON=$(printf '%s' "$RESP" | sed -E -n 's/.*"reason"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -1)
  [ -z "$REASON" ] && REASON=$(printf '%s' "$RESP" | sed -E -n 's/.*"stopReason"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -1)
  [ -z "$REASON" ] && REASON=$(printf '%s' "$RESP" | sed -E -n 's/.*"message"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -1)
  [ -z "$REASON" ] && REASON="prompt blocked"

  log "outcome=block reason=\"$(sanitize "$REASON")\""
  if _rogue_want_alert; then
    # A clear, self-explanatory alert: outcome+what in the title, the server
    # reason under a "Why:" label, then the override instruction. Naming the
    # blocked thing and the fix makes the modal actionable instead of dumping a
    # raw detection code.
    case "$EVENT" in
      UserPromptSubmit)             NOUN="prompt" ;;
      PreToolUse|PermissionRequest) NOUN="tool call" ;;
      *)                            NOUN="action" ;;
    esac
    ALERT_TITLE="⛔ Rogue blocked this $NOUN"
    ALERT_MSG="Why:
$REASON"
    # Only add the override line if the reason doesn't already explain rgx!,
    # so we don't print the instruction twice.
    case "$REASON" in
      *rgx!*) : ;;
      *) ALERT_MSG="$ALERT_MSG

To allow it: prepend \"rgx!\" to your prompt and resend (marks it a false positive)." ;;
    esac
    # Background the alert so hook.sh returns immediately. Capture the exit code
    # afterward so TCC denials / osascript failures become visible in the log.
    #
    # The trailing `>/dev/null 2>&1 </dev/null` redirects the SUBSHELL's own fds —
    # not just security-alert.sh's. Without it the subshell inherits hook.sh's
    # stdout/stderr (the pipe Claude reads) and, because it waits for the modal to
    # capture alert_rc, holds that pipe OPEN until the dialog is dismissed. Claude
    # waits for stdout EOF up to the hook `timeout`, so a dismissal slower than the
    # timeout makes Claude time the hook out and fail-open — silently letting a
    # blocked prompt through. Detaching the subshell's fds lets hook.sh reach EOF
    # the instant it exits, so the block applies regardless of when the modal
    # closes. This was a real leak, fixed in dbfd3ee; do not simplify it.
    #
    # Invoked with `bash`, not `sh`: security-alert.sh converts the literal "\n"
    # in API-relayed reasons to real newlines with a bash-only substitution.
    #
    # `2>&1 >/dev/null` (in THAT order) keeps the helper's stderr — stderr goes to
    # the substitution's pipe first, then stdout is discarded. A bare alert_rc is
    # not self-explanatory: osascript returns 1 for a TCC denial, a syntax error, a
    # missing GUI session AND for "User canceled" (-128). alert_err is what tells
    # them apart, so a non-zero rc is actionable from the log alone.
    ( ALERT_ERR=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/security-alert.sh" "$ALERT_TITLE" "$ALERT_MSG" critical 2>&1 >/dev/null)
      ALERT_RC=$?
      ALERT_LOG="alert_rc=$ALERT_RC entrypoint=${CLAUDE_CODE_ENTRYPOINT:-unset}"
      if [ "$ALERT_RC" != "0" ] && [ -n "$ALERT_ERR" ]; then
        # Fold to one line BEFORE sanitizing: sanitize deletes control characters
        # outright, so newlines would run the words together instead of separating
        # them. Bounded so a chatty failure can't flood the log.
        ALERT_ERR=$(printf '%s' "$ALERT_ERR" | tr '\n\r\t' '   ' | head -c 200)
        ALERT_LOG="$ALERT_LOG alert_err=\"$(sanitize "$ALERT_ERR")\""
      fi
      log "$ALERT_LOG" ) >/dev/null 2>&1 </dev/null &
  else
    # Logged with the three inputs to the gate so a future surface change is
    # diagnosable from hook.log alone, without re-instrumenting the dispatcher.
    log "alert_skipped=1 entrypoint=${CLAUDE_CODE_ENTRYPOINT:-unset} cowork=${CLAUDE_CODE_IS_COWORK:-unset} remote=${CLAUDE_CODE_REMOTE:-unset} agent=${ROGUE_INSTALL_AGENT:-unset}"
  fi
else
  log "outcome=allow"
fi

printf '%s' "$RESP"
