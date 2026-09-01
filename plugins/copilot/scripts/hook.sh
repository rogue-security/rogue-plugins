#!/usr/bin/env bash
# Rogue Security hook bridge for GitHub Copilot CLI — bash implementation.
# Usage: hook.sh <eventName>   (any of Copilot's 14 hook events)
#
# Reads one Copilot hook event JSON on stdin, POSTs it to the rogue-api
# /hooks/copilot route, and relays the native Copilot decision verbatim on
# stdout. PURE RELAY: the response body is NEVER rewritten — Copilot renders the
# native deny shape ({"permissionDecision":"deny",...}) itself. There is one
# narrow OUT-OF-BAND exception: a userPromptSubmitted block inside JetBrains,
# which the IDE honors but renders nowhere, so we additionally show a local
# alert (see in_jetbrains_ide / notify_block) while still relaying the body
# unchanged. There are exactly TWO stdin enrichments: a re-attributed subagent
# event gets its sessionId rewritten (see reattribute_subagent), and
# agentStop/subagentStop get the transcript tail appended (see
# augment_with_transcript) so the backend can read the final message. The
# subagent's agent tag is NOT one of them — it rides in the x-rogue-agent-*
# headers.
#
# Copilot selects the `bash` command on macOS/Linux and the `powershell` command
# on Windows (see hooks.json), so — unlike the Claude bridge — there is no
# exactly-one-runs arbitration and no Git-Bash stand-down: exactly one script
# runs per platform, chosen by Copilot.
#
# FAIL-OPEN IS SAFETY-CRITICAL HERE. Copilot's preToolUse hook is fail-CLOSED: a
# non-zero exit (or exit 2) DENIES the tool call. So this script MUST always
# `exit 0` and emit `{}` on any error (missing key, network failure, non-200,
# empty body). Never `set -e`; never let curl propagate a non-zero exit. A block
# is carried in the relayed JSON body on stdout, never via the exit code.
#
# Credential resolution (later file wins; process env wins over all):
#   1. ${PLUGIN_ROOT}/env        (baked into a compiled customer plugin)
#   2. /etc/rogue/env            (MDM-provisioned)
#   3. $HOME/.rogue-env          (per-user / installer-written)

EVENT="$1"

# Self-locate the plugin root from $0 (the path Copilot invoked us with:
# <root>/scripts/hook.sh). Fall back to the env token if that ever fails.
PLUGIN_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd)"
[ -n "$PLUGIN_ROOT" ] || PLUGIN_ROOT="${COPILOT_PLUGIN_ROOT:-${PLUGIN_ROOT:-.}}"

# Env precedence (later wins): bundled → MDM → per-user.
[ -r "${PLUGIN_ROOT}/env" ] && . "${PLUGIN_ROOT}/env"
[ -r /etc/rogue/env ]       && . /etc/rogue/env
[ -r "$HOME/.rogue-env" ]   && . "$HOME/.rogue-env"

# Log destination — ONE FILE PER AGENT. Every Rogue plugin shares ~/.rogue, so a
# machine running Copilot CLI + Claude Code + Cursor + … used to interleave all of
# them into a single hook.log with no way to tell whose line was whose.
# Precedence: explicit file → directory override → per-agent default.
ROGUE_LOG_DIR="${ROGUE_LOG_DIR:-$HOME/.rogue/logs}"
ROGUE_LOG_FILE="${ROGUE_LOG_FILE:-$ROGUE_LOG_DIR/copilot.log}"
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
# NOTE: `_lsz` is not function-local (POSIX sh has no `local`) but is used
# NOWHERE else in this file — unlike `_p`/`_n`, which are shared (see below).
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
# The one surface this plugin has. A closed-vocabulary slug, lowercase, no space
# and no `=`, so a reader finds the value by scanning to the next `key=` token. It
# matches what heartbeat reports as the roster agent for this plugin.
SURFACE="github_copilot"

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
    # SURFACE is a constant here: this plugin has exactly one surface, so there is
    # nothing to detect and nothing that can fail. It is still written through the
    # same `${SURFACE:+ …}` expansion as the multi-surface plugins so all six
    # dispatchers share one emit shape.
    printf '%s provider=copilot%s event=%s %s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SURFACE:+ surface=$SURFACE}" \
      "$EVENT" "$*" >> "$ROGUE_LOG_FILE" 2>/dev/null )
}
sanitize() { printf '%s' "$1" | tr -d '\000-\037\177'; }

# ── JetBrains silent-block alert ───────────────────────────────────────────
# Copilot's JetBrains harness HONORS a userPromptSubmitted block
# ({"decision":"block","reason":R}) but renders NOTHING for it — no reason, no
# row: the chat just goes dead (verified 2026-07-28 on PyCharm 2026.2 /
# github-copilot-intellij 1.14.1; `reason`, `message`, `systemMessage`,
# `displayMessage`, `userMessage` and `additionalContext` were all probed and
# none surfaced). The terminal CLI prints "! <reason>" natively, and every other
# blocking event (preToolUse deny, postToolUse, agentStop) renders in BOTH
# surfaces — so this one narrow case is the sole exception to the pure-relay
# rule, and the alert is gated to it. Without it the user cannot see WHY the
# turn died, nor learn the `rgx!` escape hatch. Remove once JetBrains renders
# the reason natively (tracked upstream), exactly as Claude's modal was removed
# once Claude Desktop rendered blocks itself.
#
# Detected surface (measured hook env, both harnesses set COPILOT_CLI=1):
#   terminal CLI : parent process `copilot`,  COPILOT_CLI_BINARY_VERSION set
#   JetBrains    : parent process `copilot-language-server` (the IDE embeds the
#                  CLI harness), COPILOT_CLI_BINARY_VERSION unset, PKG_EXECPATH
#                  and GITHUB_COPILOT_RIPGREP_PATH_OVERRIDE set.
# Walk a few levels because hooks.json invokes us through a shell.
# NOTE: _p/_n are NOT function-local (POSIX sh has no `local`) and the same names
# are reused by wait_for_transcript_flush and reattribute_subagent below. That is
# safe only because this helper runs LAST, after both — do not reorder the call
# sites without renaming these.
in_jetbrains_ide() {
  _p=$PPID
  _n=0
  while [ -n "$_p" ] && [ "$_p" -gt 1 ] 2>/dev/null && [ "$_n" -lt 5 ]; do
    # Linux caps `comm` at TASK_COMM_LEN-1 = 15 chars, so copilot-language-server
    # (23 chars) is reported as "copilot-languag" — matching only the full name
    # can NEVER succeed there. Match the truncated prefix too. macOS BSD
    # `ps -o comm=` prints the full executable PATH, so the *copilot) arm must
    # stay SECOND: ".../copilot-language-server" matches both patterns and the
    # IDE arm has to win. Ordering is load-bearing.
    case "$(ps -o comm= -p "$_p" 2>/dev/null)" in
      *copilot-langua*) return 0 ;;
      *copilot)         return 1 ;;
    esac
    _p=$(ps -o ppid= -p "$_p" 2>/dev/null | tr -d ' ')
    _n=$((_n + 1))
  done
  # Fallback when ps is unavailable/restricted (hidepid=2, containers): the env
  # shape still separates them. The real discriminator is
  # COPILOT_CLI_BINARY_VERSION being UNSET; if a future CLI build stops exporting
  # it the terminal would false-positive into alerting — a duplicate
  # notification, not a safety failure.
  [ -z "${COPILOT_CLI_BINARY_VERSION:-}" ] &&
    [ -n "${PKG_EXECPATH:-}${GITHUB_COPILOT_RIPGREP_PATH_OVERRIDE:-}" ]
}

# Fire a modal alert carrying the block reason — the same `display alert as
# critical` the Claude plugin used before Claude Desktop rendered blocks itself
# (see git history: plugins/rogue/scripts/security-alert.sh). A banner was tried
# first and rejected: osascript posts it as *Script Editor*, complete with a
# "Show" button that opens Script Editor's iCloud folder.
# ALWAYS DETACHED: a modal waits for the click, so running it inline would stall
# the dispatcher until dismissed. Backgrounded, it can never change our exit code
# or delay the relay — which matters on this fail-open-critical path.
# ROGUE_IDE_ALERT=0 disables; ROGUE_IDE_ALERT_DRYRUN=1 logs without alerting;
# ROGUE_IDE_ALERT_DRYRUN=2 additionally logs the fully-escaped literal that would
# be handed to osascript (real newlines rendered as '|') so the escaping of
# server-controlled reason text is covered by a test rather than a one-off probe.
notify_block() {
  [ "${ROGUE_IDE_ALERT:-1}" = "0" ] && return 0
  # head -c truncates BYTES; hook.ps1's .Substring(0,400) truncates UTF-16 chars,
  # so a non-ASCII reason cuts at a slightly different point (accepted
  # divergence). head -c can also split a multi-byte UTF-8 sequence — osascript
  # and notify-send both tolerate the stray byte.
  _msg=$(sanitize "$1" | head -c 400)
  [ -n "$_msg" ] || _msg="Prompt blocked by Rogue Security."
  log "ide_alert=fired"
  [ "${ROGUE_IDE_ALERT_DRYRUN:-0}" = "1" ] && return 0
  # API reasons carry literal "\n" (backslash + n, straight from the JSON
  # string) and are two paragraphs — the findings text and the `rgx!` override
  # hint. Convert to real newlines FIRST (AppleScript accepts them inside a
  # double-quoted literal, verified) then escape backslashes and quotes for that
  # literal. The call site deliberately does NOT collapse "\n" to a space, or
  # this conversion would be dead code and the alert would render as one blob.
  _msg=$(printf '%s' "$_msg" | awk '{gsub(/\\n/,"\n")}1')
  _esc=$(printf '%s' "$_msg" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
  if [ "${ROGUE_IDE_ALERT_DRYRUN:-0}" = "2" ]; then
    log "ide_alert=escaped msg=$(sanitize "$(printf '%s' "$_esc" | tr '\n' '|')")"
    return 0
  fi
  if command -v osascript >/dev/null 2>&1; then
    # NEVER wrap this in `tell application "System Events"` (as the deleted
    # Claude security-alert.sh did): a cross-app tell is an Automation request,
    # so macOS attributes it to the HOST app and prompts ""PyCharm" wants access
    # to control "System Events"" on first block — a consent dialog in front of a
    # security alert, which many users will simply deny, silently killing the
    # alert forever. A bare `display alert` needs no permission; `activate`
    # targets osascript ITSELF (also permission-free) and brings it to the front.
    # stdin is redirected too: a leaked fd would hold Copilot's pipe open past
    # our exit. (nohup only shields the child from SIGHUP, not from a
    # process-group SIGTERM — a non-issue since we return immediately after
    # spawning, well inside the 30s timeoutSec.)
    ( nohup osascript -e 'activate' \
        -e "display alert \"Rogue Security\" message \"$_esc\" as critical buttons {\"Dismiss\"} default button \"Dismiss\" giving up after 30" \
        </dev/null >/dev/null 2>&1 & ) 2>/dev/null
  elif command -v notify-send >/dev/null 2>&1; then
    ( nohup notify-send -u critical "Rogue Security — prompt blocked" "$_msg" </dev/null >/dev/null 2>&1 & ) 2>/dev/null
  fi
  return 0
}

# agentStop / subagentStop carry no message content inline — only a
# transcriptPath pointing at the session's events.jsonl. Append the last ~256KB
# of that file, base64-encoded, as "transcriptTailB64" so the backend can extract
# the final assistant reply / subagent message. base64 output has no JSON-special
# characters, so appending it by re-closing the object is safe. Fail-open: any
# problem (no path, unreadable, empty) returns the body unchanged.
# $1 = original JSON body; echoes the (possibly augmented) body.
# The agentStop/subagentStop hook fires as soon as Copilot decides the turn
# ended, which can be BEFORE it has flushed the turn's final assistant.message
# line to events.jsonl (observed ~5-50ms lag). A naive tail then captures a
# stale transcript missing the very reply we need to evaluate — the reply is
# silently dropped. File appends are ordered, so once the turn's closing
# "assistant.turn_end" line is on disk, every earlier line of the turn (incl.
# the final assistant.message) is too. Poll (bounded) until the last non-hook
# line is an assistant.turn_end. Our own agentStop hook.start/hook.end lines are
# excluded so they can't be mistaken for the turn boundary. Fail-open: on
# timeout we proceed with whatever is on disk.
# $1 = transcript path.
wait_for_transcript_flush() {
  _wtp="$1"
  _n=0
  # ~5s cap (50 * 0.1s), well inside the 30s hook budget. This covers the disk
  # FLUSH lag between Copilot writing the completed assistant.message line and
  # our read (~5-64ms observed) — NOT streaming time: agentStop fires only after
  # the turn completes, so the message is already written when we poll. The gap
  # is generous purely for slow/loaded disks. ROGUE_FLUSH_WAIT_ITERS overrides
  # the count (tests set it low to exercise the fail-open path).
  _max=${ROGUE_FLUSH_WAIT_ITERS:-50}
  while [ "$_n" -lt "$_max" ]; do   # the happy path returns in 0-1 iters
    _last=$(tail -c 262144 "$_wtp" 2>/dev/null | grep -v '"hook\.' | grep -v '^[[:space:]]*$' | tail -1)
    case "$_last" in
      *'"assistant.turn_end"'*) return 0 ;;
    esac
    sleep 0.1
    _n=$((_n + 1))
  done
  return 0
}

augment_with_transcript() {
  _body="$1"
  _tp=$(printf '%s' "$_body" | sed -n 's/.*"transcriptPath"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  [ -n "$_tp" ] || { printf '%s' "$_body"; return; }
  [ -r "$_tp" ] || { printf '%s' "$_body"; return; }
  wait_for_transcript_flush "$_tp"
  _b64=$(tail -c 262144 "$_tp" 2>/dev/null | base64 2>/dev/null | tr -d '\r\n')
  [ -n "$_b64" ] || { printf '%s' "$_body"; return; }
  # Trim trailing whitespace (a pretty-printed stop payload can end in spaces or
  # a newline after the closing brace) so the single-'}' strip lands on the real
  # closing brace. Without it "${_body%\}}" no-ops and we emit invalid JSON
  # ({...}  ,"transcriptTailB64":...). Mirrors hook.ps1's $payload.TrimEnd().
  _body="${_body%"${_body##*[![:space:]]}"}"
  printf '%s,"transcriptTailB64":"%s"}' "${_body%\}}" "$_b64"
}

# ── Subagent re-attribution ────────────────────────────────────────────────
# A Copilot subagent's OWN hook events (its preToolUse/postToolUse/
# userPromptSubmitted/agentStop) arrive with sessionId = the model's tool-call
# id (`toolu_…` for Claude models, `call_…` for GPT models) and carry NO parent
# reference. Persisted verbatim they become an ORPHANED audit log named after
# that id instead of appearing in the conversation that spawned them. The only
# place the link exists is the PARENT session's events.jsonl, where a
# `subagent.started` line records this id as its toolCallId/agentId — and the
# parent session id IS that transcript's directory name. Resolve it and rewrite
# the outgoing sessionId so the subagent's turns land in the right session,
# tagged via the x-rogue-agent-id / x-rogue-agent-name-b64 headers (see the POST
# below). Fail-open: unresolved → leave the body untouched (i.e. today's orphaned
# behavior — never worse).
SUBAGENT_ID=""
SUBAGENT_NAME=""
SUBAGENT_NAME_B64=""
COPILOT_STATE_DIR="${ROGUE_COPILOT_STATE_DIR:-$HOME/.copilot/session-state}"

# $1 = subagent id. Echoes "<parentSessionId>\n<displayName>" on success.
resolve_subagent_parent() {
  _sub="$1"
  [ -d "$COPILOT_STATE_DIR" ] || return 1
  for _f in "$COPILOT_STATE_DIR"/*/events.jsonl; do
    [ -r "$_f" ] || continue
    _line=$(grep '"subagent.started"' "$_f" 2>/dev/null | grep "\"$_sub\"" | head -1)
    [ -n "$_line" ] || continue
    _parent=$(basename "$(dirname "$_f")")
    [ -n "$_parent" ] || continue
    _name=$(printf '%s' "$_line" | sed -n 's/.*"agentDisplayName":"\([^"]*\)".*/\1/p' | head -1)
    [ -n "$_name" ] || _name=$(printf '%s' "$_line" | sed -n 's/.*"agentName":"\([^"]*\)".*/\1/p' | head -1)
    printf '%s\n%s' "$_parent" "$_name"
    return 0
  done
  return 1
}

# Rewrite BODY's subagent sessionId to its parent and set SUBAGENT_ID/NAME.
reattribute_subagent() {
  _sid=$(printf '%s' "$BODY" | sed -n 's/.*"sessionId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  case "$_sid" in
    toolu_*|call_*) : ;;
    *) return ;;   # a UUID → main-agent session, nothing to re-attribute
  esac

  # Resolve once per subagent, then cache (a subagent fires many events).
  _cache_dir="$HOME/.rogue/copilot-submap"
  _cache_file="$_cache_dir/$_sid"
  _map=""
  if [ -r "$_cache_file" ]; then
    _map=$(cat "$_cache_file" 2>/dev/null)
  else
    # Bounded retry for the flush race: the parent's subagent.started line may
    # not be on disk yet when the subagent's first event fires. No state dir →
    # don't spin (fail-open immediately).
    _n=0
    _max=${ROGUE_SUBAGENT_RESOLVE_ITERS:-20}   # ~2s at 0.1s/iter
    [ -d "$COPILOT_STATE_DIR" ] || _max=0
    while [ "$_n" -lt "$_max" ]; do
      _map=$(resolve_subagent_parent "$_sid") && [ -n "$_map" ] && break
      _map=""
      sleep 0.1
      _n=$((_n + 1))
    done
    [ -n "$_map" ] && { mkdir -p "$_cache_dir" 2>/dev/null; printf '%s' "$_map" > "$_cache_file" 2>/dev/null; }
  fi

  [ -n "$_map" ] || { log "subagent=$_sid outcome=unresolved"; return; }

  _parent=$(printf '%s' "$_map" | sed -n '1p')
  SUBAGENT_NAME=$(printf '%s' "$_map" | sed -n '2p')
  [ -n "$_parent" ] || return
  SUBAGENT_ID="$_sid"
  # The name travels base64-encoded: a display name is arbitrary vendor text, and
  # HTTP header values are ISO-8859-1 by spec, so an accent or an emoji sent raw
  # is undefined behavior across proxies. Encoded here, emitted at the POST below.
  if [ -n "$SUBAGENT_NAME" ]; then
    SUBAGENT_NAME_B64=$(printf '%s' "$SUBAGENT_NAME" | base64 2>/dev/null | tr -d '\r\n')
  fi
  # Tolerate whitespace around the key/colon (a pretty-printed payload) and
  # normalize to compact form; a non-matching rewrite would leave the body
  # orphaned even though we resolved the parent.
  BODY=$(printf '%s' "$BODY" | sed "s/\"sessionId\"[[:space:]]*:[[:space:]]*\"$_sid\"/\"sessionId\":\"$_parent\"/")
  log "subagent=$_sid parent=$_parent name=$(sanitize "$SUBAGENT_NAME")"
}

# Not configured: emit the SessionStart hint (so the user knows to run setup) or a
# clean allow for every other event. Never POST without a key.
if [ -z "${ROGUE_API_KEY:-}" ]; then
  log "outcome=unconfigured"
  if [ "$EVENT" = "sessionStart" ]; then
    printf '{"additionalContext":"[Rogue Security] Not configured. Run /rogue:setup to connect your API key."}'
  else
    echo '{}'
  fi
  exit 0
fi

[ -r "${PLUGIN_ROOT}/scripts/actor.sh" ] && . "${PLUGIN_ROOT}/scripts/actor.sh"
# Host + version + surface, resolved exactly as heartbeat.sh does. Sent on every
# event so the fleet roster's row stays fresh between session starts, which are
# the only moments the heartbeat runs. See install-id.sh.
[ -r "${PLUGIN_ROOT}/scripts/install-id.sh" ] && . "${PLUGIN_ROOT}/scripts/install-id.sh"
# A degraded value is still sent (never a hard failure — see install-id.sh), but
# it is worth knowing about: an "unknown" host or version means this install
# reports itself imprecisely to the fleet roster.
[ -n "${ROGUE_INSTALL_ID_ERROR:-}" ] && log "error=install-id $ROGUE_INSTALL_ID_ERROR"

URL="${ROGUE_API_URL:-${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/copilot}"

# Buffer stdin so we can enrich it (agentStop/subagentStop) before POSTing.
BODY="$(cat)"
# Re-attribute a subagent's event to its parent session BEFORE any tail
# augmentation (a subagent agentStop has no transcriptPath, so augment no-ops).
reattribute_subagent
case "$EVENT" in
  agentStop|subagentStop) BODY="$(augment_with_transcript "$BODY")" ;;
esac

# ── per-turn presence heartbeat + log ship (agentStop only) ────────────────
# sessionStart's heartbeat is spawned by hooks.json; this is its per-TURN twin, and
# it is fired from HERE rather than from a second hooks.json entry on purpose:
# Copilot skips untrusted command hooks until the user reviews them via /hooks, so
# adding an entry would silently disable every Rogue hook on every existing install
# until each user re-approved. The dispatcher already runs on agentStop, so this
# leaves the command strings byte-identical and trust intact.
#
# It exists because a session left open for days used to produce exactly one beacon
# and one log upload for its whole lifetime - the roster row went stale and the hook
# log sat on disk unshipped. heartbeat.sh throttles the beacon itself
# (scripts/beacon.sh, 900s default) and the shipper throttles itself, so a per-turn
# trigger is not a per-turn request.
#
# MAIN AGENT ONLY. Copilot fires agentStop for a subagent too (with sessionId
# `toolu_…`), and SUBAGENT_ID is set by the time we get here, so this skips those:
# a subagent's stop is not a user turn, and one turn using three subagents would
# otherwise queue four beacons that the throttle then has to absorb.
#
# DETACHED double-fork with every fd redirected. This is the synchronous dispatcher
# and Copilot is waiting on our stdout, so nothing here may be awaited - and stdin is
# closed because the child must not touch the buffered event. heartbeat.sh
# self-locates its plugin root from $0, exactly as this script does, so there is
# nothing to pass but the trigger.
if [ "$EVENT" = "agentStop" ] && [ -z "$SUBAGENT_ID" ] &&
   [ -r "${PLUGIN_ROOT}/scripts/heartbeat.sh" ]; then
  ( nohup sh "${PLUGIN_ROOT}/scripts/heartbeat.sh" agentStop </dev/null >/dev/null 2>&1 & )
fi

# Capture body + HTTP status. -w appends a final line "<code>"; on any transport
# failure curl exits non-zero and the code is 000. Relay the body ONLY on a clean
# HTTP 200 so an error page (401/404/500) is never handed to Copilot as a decision.
# Every event POSTs the same seven headers; a re-attributed subagent event adds
# the agent tag as two more - x-rogue-agent-id and x-rogue-agent-name-b64, the
# same pair the Antigravity dispatcher sends. In HEADERS and not in the body so
# the POSTed event stays the vendor's own bytes: tagging the body meant a full jq
# re-serialization of arbitrary toolArgs. Both are omitted entirely, never sent
# empty, on a main-agent event. The local SUBAGENT_* variables keep Copilot's own
# terminology, since Copilot is what calls these subagents; the wire names match
# the aidr_message.agent_id/agent_name columns they land in.
#
# Conditional ARGUMENTS, not a conditional value: `-H "x-rogue-agent-id: "` and
# `-H "x-rogue-agent-id:"` mean an empty value and suppress-this-header to curl,
# and neither is "do not send it". EVENT was captured at the top of the file, so
# `set --` is free to rebuild the positional list here.
set -- -H "x-rogue-api-key: $ROGUE_API_KEY" \
       -H "x-rogue-event: $EVENT" \
       -H "x-rogue-agent: $ROGUE_INSTALL_AGENT" \
       -H "x-rogue-host: $ROGUE_INSTALL_HOST" \
       -H "x-rogue-version: $ROGUE_INSTALL_VERSION" \
       -H "x-rogue-actor-email: $ROGUE_ACTOR_EMAIL" \
       -H "x-rogue-actor-name: $ROGUE_ACTOR_NAME"
# The id is a bare token from Copilot (toolu_… / call_…). Anything outside the
# token charset is not one — skip BOTH headers rather than emit a junk value.
case "$SUBAGENT_ID" in
  ''|*[!A-Za-z0-9_-]*) : ;;
  *)
    set -- "$@" -H "x-rogue-agent-id: $SUBAGENT_ID"
    [ -n "$SUBAGENT_NAME_B64" ] && set -- "$@" -H "x-rogue-agent-name-b64: $SUBAGENT_NAME_B64"
    ;;
esac

RAW=$(printf '%s' "$BODY" | curl -sS -X POST "$URL" \
  "$@" \
  -H 'Content-Type: application/json' \
  --data-binary @- --max-time 15 -w '\n%{http_code}')
RC=$?
CODE=$(printf '%s' "$RAW" | tail -n1)
BODY=$(printf '%s' "$RAW" | sed '$d')

log "http=$CODE rc=$RC raw=$(sanitize "$BODY" | head -c 400)"

# Fail-open on transport error or any non-200: emit a clean allow.
if [ "$RC" -ne 0 ] || [ "$CODE" != "200" ] || [ -z "$BODY" ]; then
  log "outcome=allow http=$CODE rc=$RC"
  echo '{}'
  exit 0
fi

# The ONE case Copilot renders nowhere: a userPromptSubmitted block inside
# JetBrains (see in_jetbrains_ide). Surface the reason out-of-band, then relay
# unchanged — the response itself is never rewritten.
case "$EVENT" in
  userPromptSubmitted)
    # STRICT shape match, mirroring hook.ps1's '"decision"\s*:\s*"block"' regex.
    # A loose glob (*'"decision"'*'"block"'*) false-positives on an ALLOWED body
    # that merely carries "block" as some other field's value — e.g.
    # {"decision":"allow","reason":"no findings","rulesetMode":"block"} — popping
    # a modal on a prompt that was never blocked. The body is server-controlled,
    # so the pair, not the substrings, is the gate.
    if printf '%s' "$BODY" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' &&
       in_jetbrains_ide; then
      # Keep the literal "\n" sequences intact — notify_block converts them to
      # real newlines so the two-paragraph reason renders as written.
      _reason=$(printf '%s' "$BODY" \
        | sed -n 's/.*"reason"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
      notify_block "$_reason"
    fi
    ;;
esac

# rogue-api already returns the correct native Copilot shape (allow "{}" for
# audit-only events like sessionStart); relay it verbatim.
printf '%s' "$BODY"
exit 0
