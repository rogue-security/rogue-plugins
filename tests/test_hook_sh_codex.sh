#!/usr/bin/env bash
# tests/test_hook_sh_codex.sh — end-to-end for the Codex dispatcher (plugins/codex/scripts/hook.sh):
# env file → hook.sh → mock server → stdout and ~/.rogue/logs/codex.log. Holds it to the relay
# contract: the body only on HTTP 200 with a non-empty body, `{}` otherwise, the request headers,
# the surface, the unconfigured and fail-open paths, and the per-turn heartbeat on Stop.
#
# Runs under tests/conformance.sh against either bridge. hooks.json runs the dispatcher with bash;
# TEST_SH=dash checks it stays POSIX.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/tests/lib/bridge.sh"
PLUGIN_ROOT="$REPO/plugins/codex"
HOOK="$PLUGIN_ROOT/scripts/hook.sh"
SH="${TEST_SH:-bash}"
VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([0-9.]*\)".*/\1/p' "$PLUGIN_ROOT/.codex-plugin/plugin.json")"

PORT=$((RANDOM % 10000 + 30000))
WORK="$(mktemp -d)"
HEADERS_FILE="$WORK/headers.json"
CALLS="$WORK/calls"
FAILS=0

cleanup() {
  [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null
  wait 2>/dev/null
  rm -rf "$WORK"
  return 0
}
trap cleanup EXIT

pass() { echo "  ok: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected [$2], got [$3])"; fi; }

start_mock() { # <response> [status] [delay]
  [ -n "${MOCK_PID:-}" ] && { kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null; }
  rm -f "$HEADERS_FILE" "$CALLS"
  MOCK_RESPONSE="$1" MOCK_STATUS="${2:-200}" MOCK_DELAY="${3:-0}" MOCK_CALLS="$CALLS" \
    python3 "$REPO/tests/mock_server.py" "$PORT" "$HEADERS_FILE" &
  MOCK_PID=$!
  for _ in $(seq 1 50); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && return 0; sleep 0.1; done
  echo "mock server failed to start" >&2; exit 1
}

# run <event> <payload> [env-file line...] — the dispatcher in a fresh HOME whose ~/.rogue-env
# holds the key, the mock's URL and any extra lines. Leaves stdout in $OUT_FILE, the exit code in
# $RC and the log lines without their timestamp (and the native bridge's token) in $LOG.
run() {
  local event="$1" payload="$2"; shift 2
  local home="$WORK/home"
  rm -rf "$home"; mkdir -p "$home"
  { echo "export ROGUE_API_KEY=test-key"
    echo "export ROGUE_ACTOR_EMAIL=test@example.com"
    echo "export ROGUE_ACTOR_NAME='Test User'"
    echo "export ROGUE_BASE_URL=http://127.0.0.1:$PORT"
    for l in "$@"; do echo "$l"; done
  } > "$home/.rogue-env"
  chmod 600 "$home/.rogue-env"
  OUT_FILE="$WORK/out"
  printf '%s' "$payload" | env -u ROGUE_API_KEY -u ROGUE_BASE_URL -u ROGUE_API_URL \
    -u ROGUE_CODEX_SURFACE -u ROGUE_LOG_FILE -u ROGUE_LOG_DIR -u ROGUE_ACTOR_EMAIL \
    -u ROGUE_ACTOR_NAME HOME="$home" PLUGIN_ROOT="$PLUGIN_ROOT" \
    "$SH" "$HOOK" "$event" > "$OUT_FILE" 2>/dev/null
  RC=$?
  LOG="$(sed -E 's/^[^ ]+ //; s/ bridge=native//' "$home/.rogue/logs/codex.log" 2>/dev/null)"
}

stdout_is() { # <label> <printf format> [args...] — the exact bytes expected on stdout
  printf "$2" "${@:3}" > "$WORK/want"
  if cmp -s "$WORK/want" "$OUT_FILE"; then pass "$1"
  else fail "$1 (expected [$(od -c "$WORK/want" | head -3)], got [$(od -c "$OUT_FILE" | head -3)])"; fi
  check "$1: exit 0" 0 "$RC"
}

header() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["headers"].get(sys.argv[2], ""))' "$HEADERS_FILE" "$1" 2>/dev/null; }
req_path() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["path"])' "$HEADERS_FILE" 2>/dev/null; }
req_body() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["body"])' "$HEADERS_FILE" 2>/dev/null; }

DENY='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"blocked"}}'
PRE='{"session_id":"s-1","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"rm -rf /"}}'

echo "== relay: the body on HTTP 200, verbatim, with the request it answers"
start_mock "$DENY"
run PreToolUse "$PRE"
stdout_is "deny relayed verbatim, no trailing newline" "%s" "$DENY"
check "POST path" "/api/v1/hooks/openai" "$(req_path)"
check "payload forwarded verbatim" "$PRE" "$(req_body)"
check "x-rogue-api-key" "test-key" "$(header x-rogue-api-key)"
check "x-rogue-event is Codex's own event name" "PreToolUse" "$(header x-rogue-event)"
check "x-rogue-agent defaults to codex_cli" "codex_cli" "$(header x-rogue-agent)"
check "x-rogue-actor-email" "test@example.com" "$(header x-rogue-actor-email)"
check "x-rogue-actor-name" "Test User" "$(header x-rogue-actor-name)"
check "x-rogue-version is the manifest's" "$VERSION" "$(header x-rogue-version)"
check "x-rogue-host is this host" "$(hostname)" "$(header x-rogue-host)"
check "content-type" "application/json" "$(header content-type)"
if bridge_native; then
  case "$(header x-rogue-bridge)" in native/*) pass "x-rogue-bridge names the native bridge" ;;
    *) fail "x-rogue-bridge [$(header x-rogue-bridge)]" ;; esac
else
  check "no x-rogue-bridge from the script" "" "$(header x-rogue-bridge)"
fi
check "one log line on a relayed answer" \
  "provider=codex surface=codex_cli event=PreToolUse outcome_raw=$DENY http=200 rc=0" "$LOG"

start_mock "$(printf '{"decision":"block","reason":"x"}\n\n')"
run UserPromptSubmit '{"prompt":"hi"}'
stdout_is "trailing newlines dropped from the relayed body" "%s" '{"decision":"block","reason":"x"}'

echo "== fail open: {} unless HTTP 200 with a body"
for c in "500:oops" "201:{\"decision\":\"block\"}" "401:{\"error\":\"bad key\"}" "200:"; do
  code="${c%%:*}"; body="${c#*:}"
  start_mock "$body" "$code"
  run PostToolUse '{"tool_name":"Bash"}'
  stdout_is "HTTP $code body [$body] answers {}" '{}\n'
  check "HTTP $code logs the raw reply and the allow" \
    "provider=codex surface=codex_cli event=PostToolUse outcome_raw=$body http=$code rc=0
provider=codex surface=codex_cli event=PostToolUse outcome=allow http=$code rc=0" "$LOG"
done

kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null; MOCK_PID=""
run PreToolUse "$PRE"
stdout_is "server down answers {}" '{}\n'
check "server down logs http=000 rc=7" \
  "provider=codex surface=codex_cli event=PreToolUse outcome_raw= http=000 rc=7
provider=codex surface=codex_cli event=PreToolUse outcome=allow http=000 rc=7" "$LOG"

start_mock "$DENY" 200 12
t0=$(date +%s)
run PreToolUse "$PRE"
took=$(( $(date +%s) - t0 ))
stdout_is "a reply slower than 8 s answers {}" '{}\n'
if [ "$took" -ge 7 ] && [ "$took" -le 10 ]; then pass "gave up after the 8 s request timeout (${took}s)"
else fail "request timeout took ${took}s"; fi
check "timeout logs rc=28" \
  "provider=codex surface=codex_cli event=PreToolUse outcome_raw= http=000 rc=28
provider=codex surface=codex_cli event=PreToolUse outcome=allow http=000 rc=28" "$LOG"

echo "== URL: ROGUE_API_URL replaces the whole route"
start_mock '{}'
run PreToolUse "$PRE" "export ROGUE_API_URL=http://127.0.0.1:$PORT/custom/route"
check "ROGUE_API_URL used as is" "/custom/route" "$(req_path)"
stdout_is "allow relayed from ROGUE_API_URL" "%s" '{}'

echo "== surface: ROGUE_CODEX_SURFACE, closed to codex_app and codex_cli"
for c in codex_app:codex_app codex_cli:codex_cli "'codex app':codex_cli" desktop:codex_cli; do
  val="${c%:*}"; want="${c##*:}"
  start_mock '{}'
  run SessionStart '{"session_id":"s-1"}' "export ROGUE_CODEX_SURFACE=$val"
  check "ROGUE_CODEX_SURFACE=$val sends x-rogue-agent $want" "$want" "$(header x-rogue-agent)"
  check "ROGUE_CODEX_SURFACE=$val stamps surface=$want" \
    "provider=codex surface=$want event=SessionStart outcome_raw={} http=200 rc=0" "$LOG"
done

echo "== unconfigured: {} with no request"
start_mock "$DENY"
home="$WORK/home"; rm -rf "$home"; mkdir -p "$home"
printf '{}' | env -u ROGUE_API_KEY HOME="$home" PLUGIN_ROOT="$PLUGIN_ROOT" ROGUE_CODEX_SURFACE=codex_app \
  "$SH" "$HOOK" PreToolUse > "$WORK/out" 2>/dev/null
RC=$?; OUT_FILE="$WORK/out"
stdout_is "unconfigured answers {}" '{}\n'
check "unconfigured sends nothing" "" "$(cat "$CALLS" 2>/dev/null)"
check "unconfigured logs it with the surface" \
  "provider=codex surface=codex_app event=PreToolUse outcome=unconfigured" \
  "$(sed -E 's/^[^ ]+ //; s/ bridge=native//' "$home/.rogue/logs/codex.log")"

echo "== Stop starts the per-turn heartbeat without waiting for it"
start_mock '{}'
run Stop '{"session_id":"s-1","hook_event_name":"Stop"}'
stdout_is "Stop relays the answer" "%s" '{}'
for _ in $(seq 1 50); do grep -q '^/api/v1/hooks/status ' "$CALLS" 2>/dev/null && break; sleep 0.1; done
status="$(sed -n 's|^/api/v1/hooks/status ||p' "$CALLS" 2>/dev/null | head -1)"
check "the heartbeat posts the openai family and the surface" "openai codex_cli $VERSION" \
  "$(printf '%s' "$status" | python3 -c 'import json,sys; b=json.load(sys.stdin); print(b["agent_family"], b["agent"], b["version"])' 2>/dev/null)"
start_mock '{}'
run PreToolUse "$PRE"
sleep 1
check "no heartbeat on other events" "/api/v1/hooks/openai" "$(cut -d' ' -f1 "$CALLS" | sort -u | tr '\n' ' ' | sed 's/ $//')"

echo
if [ "$FAILS" -gt 0 ]; then echo "FAIL: $FAILS case(s)"; exit 1; fi
echo "OK: codex hook.sh (${ROGUE_TEST_BRIDGE:-script})"
