#!/usr/bin/env bash
# Rogue Security hook bridge for Kiro (IDE, CLI, Crew) — bash implementation.
# Usage: hook.sh <hookEvent> <surface>
#   hookEvent  the Kiro hook event this command was installed under. Either
#              dialect is accepted: the 2.x engine's camelCase trigger names
#              (agentSpawn, userPromptSubmit, preToolUse, postToolUse, stop) or
#              the 3.0/IDE PascalCase ones (SessionStart, UserPromptSubmit,
#              PreToolUse, PostToolUse, Stop, PostFileCreate/Save/Delete).
#   surface    kiro_ide | kiro_cli | kiro_crew. No Kiro payload names its
#              surface, so the installer fixes it here, as the Codex bridge does.
#
# Reads one Kiro hook event JSON on stdin, POSTs it to the rogue-api /hooks/kiro
# route, and translates Rogue's decision into Kiro's NATIVE form — which, unlike
# every other family, is the process exit code:
#
#   PreToolUse block         exit 2, reason on stderr, EMPTY stdout
#   UserPromptSubmit block   exit 0, {"decision":"block","reason":…} on stdout
#   Stop                     exit 0, empty stdout — ALWAYS. A block on Stop tells
#                            Kiro to keep working, the opposite of a guardrail.
#   everything else          exit 0, empty stdout (findings are still persisted)
#
# The route already answers {} for every event that cannot block on this
# surface (Stop, and UserPromptSubmit anywhere but the IDE), so the table above
# is a second fence, not the only one.
#
# FAIL-OPEN IS SAFETY-CRITICAL. Exit 2 is a hard deny and stdout is injected
# into the model's context on some events, so on ANY error (missing key,
# network failure, timeout, non-200, empty body) this script exits 0 with an
# empty stdout. Never `set -e`; never let curl propagate a non-zero exit.
#
# Measured (2026-09-03, kiro-cli 2.21.0 / IDE 1.0.437, FIRE-2030): exit 2 on
# PreToolUse blocks on every surface, but the stderr reason reaches the model on
# the 2.x engine only; exit 2 on UserPromptSubmit blocks nowhere, the JSON
# decision blocks on the IDE only (model-mediated); timeout and exit 1 are both
# fail-open. Hence the two transports.
#
# Credential resolution: the first env file holding ROGUE_API_KEY is used alone,
# and its values override the process env:
#   1. /etc/rogue/env            (machine, MDM-provisioned)
#   2. ${PLUGIN_ROOT}/env        (bundled into a compiled customer plugin)
#   3. $HOME/.rogue-env          (per-user / installer-written)

locate_plugin_root() {
  PLUGIN_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd)"
  [ -n "$PLUGIN_ROOT" ] || PLUGIN_ROOT="${KIRO_PLUGIN_ROOT:-${PLUGIN_ROOT:-.}}"
}

load_env() {
  [ -r "${PLUGIN_ROOT}/scripts/env-file.sh" ] || return 0
  . "${PLUGIN_ROOT}/scripts/env-file.sh"
  # The first trusted env file holding ROGUE_API_KEY is used alone: machine, bundled, user.
  for _env_file in /etc/rogue/env "${PLUGIN_ROOT}/env" "$HOME/.rogue-env"; do
    if rogue_env_is_trusted "$_env_file" && grep -Eq '^[[:space:]]*(export[[:space:]]+)?ROGUE_API_KEY=' "$_env_file"; then
      . "$_env_file"; break
    fi
  done
}

canonical_event() {
  case "$1" in
    agentSpawn|SessionStart)             echo SessionStart ;;
    userPromptSubmit|UserPromptSubmit)   echo UserPromptSubmit ;;
    preToolUse|PreToolUse)               echo PreToolUse ;;
    postToolUse|PostToolUse)             echo PostToolUse ;;
    stop|Stop)                           echo Stop ;;
    *)                                   printf '%s\n' "$1" ;;
  esac
}
initialize_context() {
  EVENT=$(canonical_event "$EVENT_ARG")

  # A closed vocabulary. An unrecognised argument leaves the log token OUT (the
  # hook-log contract forbids a placeholder) and lands on kiro_cli on the wire,
  # which is what the route defaults an unknown x-rogue-agent to anyway.
  case "$SURFACE_ARG" in
    kiro_ide|kiro_cli|kiro_crew) SURFACE="$SURFACE_ARG" ;;
    *)                           SURFACE="" ;;
  esac

  # Log destination — ONE FILE PER AGENT under ~/.rogue/logs (see
  # docs/hook-log-format.md). Precedence: explicit file → directory → default.
  ROGUE_LOG_DIR="${ROGUE_LOG_DIR:-$HOME/.rogue/logs}"
  ROGUE_LOG_FILE="${ROGUE_LOG_FILE:-$ROGUE_LOG_DIR/kiro.log}"
  # Size cap; over it the log is renamed to <file>.1 (one generation kept). A
  # numeric zero disables rotation; a non-numeric or oversized value falls back to
  # the default so a typo can never leave the log growing unbounded. The clamp
  # mirrors the other five sh dispatchers byte for byte.
  ROGUE_LOG_MAX_BYTES="${ROGUE_LOG_MAX_BYTES:-10485760}"
  case "$ROGUE_LOG_MAX_BYTES" in ""|*[!0-9]*) ROGUE_LOG_MAX_BYTES=10485760 ;; esac
  _lcap="$ROGUE_LOG_MAX_BYTES"
  while [ "${_lcap#0}" != "$_lcap" ]; do _lcap="${_lcap#0}"; done
  if [ "${#_lcap}" -gt 18 ]; then ROGUE_LOG_MAX_BYTES=10485760; fi
}

rotate_log() {
  [ -f "$ROGUE_LOG_FILE" ] || return 0
  [ "$ROGUE_LOG_MAX_BYTES" -gt 0 ] || return 0
  # `wc -c` not `stat`: BSD and GNU stat take different flags for file size.
  _lsz=$(wc -c < "$ROGUE_LOG_FILE" 2>/dev/null | tr -d '[:space:]')
  case "$_lsz" in ''|*[!0-9]*) return 0 ;; esac
  [ "$_lsz" -ge "$ROGUE_LOG_MAX_BYTES" ] && mv -f "$ROGUE_LOG_FILE" "$ROGUE_LOG_FILE.1" 2>/dev/null
  return 0
}
log() {
  # 0700 dir / 0600 file: the line carries the server's block reason, which
  # quotes the content that tripped the rule.
  ( umask 077
    mkdir -p "$(dirname "$ROGUE_LOG_FILE")" 2>/dev/null
    rotate_log
    printf '%s provider=kiro%s event=%s %s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SURFACE:+ surface=$SURFACE}" \
      "$EVENT" "$*" >> "$ROGUE_LOG_FILE" 2>/dev/null )
}
sanitize() { printf '%s' "$1" | tr -d '\000-\037\177'; }

require_api_key() {
  if [ -z "${ROGUE_API_KEY:-}" ]; then
    log "outcome=unconfigured"
    exit 0
  fi
}

load_identity() {
  [ -r "${PLUGIN_ROOT}/scripts/actor.sh" ] && . "${PLUGIN_ROOT}/scripts/actor.sh"
  # Host + version + surface, resolved exactly as heartbeat.sh does, so the fleet
  # roster row is refreshed by ordinary hook traffic. install-id.sh reads SURFACE.
  [ -r "${PLUGIN_ROOT}/scripts/install-id.sh" ] && . "${PLUGIN_ROOT}/scripts/install-id.sh"
  [ -n "${ROGUE_INSTALL_ID_ERROR:-}" ] && log "error=install-id $ROGUE_INSTALL_ID_ERROR"
  ROGUE_INSTALL_AGENT="${ROGUE_INSTALL_AGENT:-${SURFACE:-kiro_cli}}"
}

resolve_request() {
  URL="${ROGUE_API_URL:-${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/kiro}"

  # curl budget, in seconds. The hook file gives the command 10s and the route
  # evaluates within 3s, so 8s leaves room for the network without ever letting
  # Kiro's own timeout be what fails us open. Tests shorten it. Zero falls back to
  # the default too: `curl --max-time 0` means NO timeout, which would hand the
  # budget to Kiro's 10s. `-gt` also rejects a value too wide for the shell's int.
  HOOK_TIMEOUT="${ROGUE_HOOK_TIMEOUT:-8}"
  case "$HOOK_TIMEOUT" in ''|*[!0-9]*) HOOK_TIMEOUT=8 ;; esac
  [ "$HOOK_TIMEOUT" -gt 0 ] 2>/dev/null || HOOK_TIMEOUT=8
}

# The 2.x engine sends no session_id in the body; it exposes KIRO_SESSION_ID in
# the hook's environment instead. Copy it into the body under the field the 3.0
# engine uses, so the route sees one shape. A body that already carries the
# field is left untouched, byte for byte.
#
# ONE mutation path, string concat, so the posted bytes never depend on whether
# jq is on PATH and the vendor's bytes are preserved (jq would re-serialise the
# whole body compact). It matches hook.ps1's Add-KiroSessionId line for line.
# The value is env-controlled text spliced into JSON, so anything outside a bare
# token charset is refused outright.
#
# "Already carries the field" is a SUBSTRING check: without a JSON parser there
# is no cheap way to tell a top-level key from a NESTED key of the same name (an
# MCP tool's arguments, say). Prompt text cannot trip it — a quote inside a JSON
# string is escaped. The false positive skips the injection, which is fail-open:
# the event is still recorded, just without a session id (the 2.x behaviour of
# today). Fail-open everywhere else too.
# $1 = body; echoes the (possibly augmented) body.
inject_session_id() {
  _body="$1"
  case "$_body" in *'"session_id"'*) printf '%s' "$_body"; return ;; esac
  case "${KIRO_SESSION_ID:-}" in
    ''|*[!A-Za-z0-9_.:-]*) printf '%s' "$_body"; return ;;
  esac
  # Trim trailing whitespace so the single-'}' strip lands on the real closing
  # brace, then again inside so `{\n}` is seen as the empty object it is.
  _body="${_body%"${_body##*[![:space:]]}"}"
  case "$_body" in *'}') : ;; *) printf '%s' "$1"; return ;; esac
  _pre="${_body%\}}"
  _pre="${_pre%"${_pre##*[![:space:]]}"}"
  if [ "$_pre" = "{" ]; then _sep=""; else _sep=","; fi
  printf '%s%s"session_id":"%s"}' "$_pre" "$_sep" "$KIRO_SESSION_ID"
}

# Only a parsed root event can prove this is the duplicate agent-config hook.
# Without a JSON runtime, send the event: duplicate telemetry beats a lost gate.
body_event() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -r 'if type == "object" and (.hook_event_name | type) == "string" then .hook_event_name else empty end' 2>/dev/null
  elif command -v node >/dev/null 2>&1; then
    printf '%s' "$1" | node -e 'try { const b = JSON.parse(require("fs").readFileSync(0,"utf8")); if (b && typeof b.hook_event_name === "string") process.stdout.write(b.hook_event_name); } catch {}' 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$1" | python3 -c 'import json,sys; b=json.load(sys.stdin); e=b.get("hook_event_name") if isinstance(b,dict) else None; print(e if isinstance(e,str) else "")' 2>/dev/null
  fi
}

skip_duplicate() {
  case "$EVENT_ARG" in
    agentSpawn|userPromptSubmit|preToolUse|postToolUse|stop)
      case "$(body_event "$BODY")" in
        [[:upper:]]*) log "outcome=duplicate engine=3.0 trigger=$EVENT_ARG"; exit 0 ;;
      esac ;;
  esac
}

maybe_heartbeat() {
  case "$EVENT" in
    SessionStart|Stop)
      if [ -r "${PLUGIN_ROOT}/scripts/heartbeat.sh" ]; then
        ( nohup sh "${PLUGIN_ROOT}/scripts/heartbeat.sh" "$ROGUE_INSTALL_AGENT" "$EVENT" \
            </dev/null >/dev/null 2>&1 & )
      fi ;;
  esac
}

post_request() {
  RAW=$(printf '%s' "$BODY" | curl -sS -X POST "$URL" \
    -H "x-rogue-api-key: $ROGUE_API_KEY" \
    -H "x-rogue-event: $EVENT" \
    -H "x-rogue-agent: $ROGUE_INSTALL_AGENT" \
    -H "x-rogue-host: ${ROGUE_INSTALL_HOST:-unknown}" \
    -H "x-rogue-version: ${ROGUE_INSTALL_VERSION:-unknown}" \
    -H "x-rogue-actor-email: ${ROGUE_ACTOR_EMAIL:-}" \
    -H "x-rogue-actor-name: ${ROGUE_ACTOR_NAME:-}" \
    -H 'Content-Type: application/json' \
    --data-binary @- --max-time "$HOOK_TIMEOUT" -w '\n%{http_code}' 2>/dev/null)
  RC=$?
  CODE=$(printf '%s' "$RAW" | tail -n1)
  RESP=$(printf '%s' "$RAW" | sed '$d')
}

finish() { log "outcome=$1${2:+ $2} http=$CODE rc=$RC raw=$(sanitize "$RESP" | head -c 400)"; }


is_block() { printf '%s' "$RESP" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"'; }

# The reason is a JSON string. jq decodes it exactly; the fallback captures the
# string body (escaped quotes included) and unescapes the common sequences with
# printf %b, which is enough for a terminal line.
block_reason() {
  _r=""
  if command -v jq >/dev/null 2>&1; then
    _r=$(printf '%s' "$RESP" | jq -r '.reason // empty' 2>/dev/null)
  else
    _r=$(printf '%s' "$RESP" \
      | sed -nE 's/.*"reason"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p' \
      | sed 's/\\"/"/g')
    _r=$(printf '%b' "$_r")
  fi
  [ -n "$_r" ] || _r="Blocked by Rogue Security"
  printf '%s' "$_r"
}

relay_decision() {
  if [ "$RC" -ne 0 ] || [ "$CODE" != "200" ] || [ -z "$RESP" ]; then
    finish allow
    exit 0
  fi

  if is_block; then
    case "$EVENT" in
      PreToolUse)
        finish block
        block_reason >&2
        printf '\n' >&2
        exit 2 ;;
      UserPromptSubmit)
        finish block
        printf '%s' "$RESP"
        exit 0 ;;
      *)
        # Stop and every audit-only event: recorded, never enforced.
        finish allow decision=block
        exit 0 ;;
    esac
  fi

  finish allow
  exit 0
}

main() {
  EVENT_ARG="${1:-}"
  SURFACE_ARG="${2:-}"
  locate_plugin_root
  load_env
  initialize_context
  require_api_key
  load_identity
  resolve_request
  BODY="$(inject_session_id "$(cat)")"
  skip_duplicate
  maybe_heartbeat
  post_request
  relay_decision
}

main "$@"
