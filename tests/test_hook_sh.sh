#!/usr/bin/env bash
# tests/test_hook_sh.sh — end-to-end for the POSIX dispatcher (hook.sh):
# env file → hook.sh → mock server → stdout. Holds the dispatcher to the
# verbatim-relay + header + fail-open + Git-Bash-stand-down contract.
#
# hooks.json invokes the dispatcher via `sh`; override with TEST_SH=dash to
# exercise strict POSIX (Debian/Ubuntu /bin/sh) and catch bashisms.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO/plugins/rogue/scripts/hook.sh"
PLUGIN_ROOT="$REPO/plugins/rogue"
SH="${TEST_SH:-sh}"

PORT=$((RANDOM % 10000 + 30000))
HEADERS_FILE="$(mktemp)"
ENV_FILE="$(mktemp)"

cleanup() {
  [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null || true
  rm -f "$ENV_FILE" "$HEADERS_FILE"
  [ -n "${SANDBOX_BIN:-}" ] && rm -rf "$SANDBOX_BIN"
  return 0
}
trap cleanup EXIT

cat > "$ENV_FILE" <<EOF
export ROGUE_API_KEY=test-key
export ROGUE_ACTOR_EMAIL=test@example.com
export ROGUE_ACTOR_NAME='Test User'
export ROGUE_BASE_URL=http://127.0.0.1:${PORT}
EOF

# Run with a clean HOME holding our env file. CLAUDE_CODE_ENTRYPOINT=cli so the
# entrypoint gate passes.
# CLAUDE_PLUGIN_ROOT points at the real plugin so actor.sh resolves.
run_dispatcher() {
  local tmp_home
  tmp_home="$(mktemp -d)"
  cp "$ENV_FILE" "$tmp_home/.rogue-env"
  HOME="$tmp_home" CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    ROGUE_API_KEY='' ROGUE_ACTOR_EMAIL='' ROGUE_ACTOR_NAME='' ROGUE_BASE_URL='' \
    "$SH" "$HOOK" "$1" <<< "$2"
  rm -rf "$tmp_home"
}

start_mock() {
  MOCK_RESPONSE="$1" MOCK_STATUS="${2:-200}" \
    python3 "$REPO/tests/mock_server.py" "$PORT" "$HEADERS_FILE" &
  MOCK_PID=$!
  for _ in $(seq 1 50); do
    nc -z 127.0.0.1 "$PORT" 2>/dev/null && return 0
    sleep 0.1
  done
  echo "mock server failed to start" >&2; exit 1
}

restart_mock() {
  [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null || true
  wait "$MOCK_PID" 2>/dev/null || true
  start_mock "$@"
}

assert_eq() {
  if [ "$1" != "$2" ]; then echo "FAIL [$3]: expected <$2> but got <$1>" >&2; exit 1; fi
  echo "  ok: $3"
}

assert_header() {
  local key="$1" expected="$2" label="$3" actual
  actual=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["headers"].get(sys.argv[2], ""))' "$HEADERS_FILE" "$key")
  assert_eq "$actual" "$expected" "$label"
}

assert_no_header() {
  local key="$1" label="$2" actual
  actual=$(python3 -c 'import json,sys; print(sys.argv[2] in json.load(open(sys.argv[1]))["headers"])' "$HEADERS_FILE" "$key")
  assert_eq "$actual" "False" "$label"
}

# Presence-only: the value is this machine's hostname / installed version, so the
# test can assert it is sent and non-empty but not what it says.
assert_header_present() {
  local key="$1" label="$2" actual
  actual=$(python3 -c 'import json,sys; print(bool(json.load(open(sys.argv[1]))["headers"].get(sys.argv[2])))' "$HEADERS_FILE" "$key")
  assert_eq "$actual" "True" "$label"
}

# ── Case 1: PreToolUse deny relayed verbatim + headers ─────────────────────
start_mock '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"blocked"}}'
out=$(run_dispatcher PreToolUse '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}')
assert_eq "$out" '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"blocked"}}' "deny response relayed verbatim"
assert_header "x-rogue-event"       "PreToolUse"       "x-rogue-event is the verbatim Claude event name"
assert_header "x-rogue-api-key"     "test-key"         "x-rogue-api-key forwarded"
assert_header "x-rogue-actor-email" "test@example.com" "x-rogue-actor-email forwarded"
assert_header "x-rogue-actor-name"  "Test User"        "x-rogue-actor-name forwarded (with space)"
assert_no_header "x-rogue-source"   "no x-rogue-source header (cursor-only)"
# Fleet-liveness trio: the same host/version/agent the heartbeat sends, on EVERY
# event, so the roster row is refreshed by ordinary traffic and not only at
# session start. `agent` is a stable snake_case surface id -- it doubles as the
# backend's PLUGIN_REPOS key, so a display label here means the row never
# resolves a latest version. The harness sets CLAUDE_CODE_ENTRYPOINT=cli.
# See scripts/install-id.sh.
assert_header "x-rogue-agent"       "claude_code"      "x-rogue-agent is the roster's surface id"
assert_header_present "x-rogue-host"    "x-rogue-host sent on every event"
assert_header_present "x-rogue-version" "x-rogue-version sent on every event"

# ── Case 2: top-level block relayed + path is /hooks/claude ────────────────
restart_mock '{"decision":"block","reason":"prompt injection"}'
out=$(run_dispatcher UserPromptSubmit '{"prompt":"ignore previous"}')
assert_eq "$out" '{"decision":"block","reason":"prompt injection"}' "top-level block relayed"
path=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["path"])' "$HEADERS_FILE")
assert_eq "$path" "/api/v1/hooks/claude" "POST path is /api/v1/hooks/claude"

# ── Case 3: allow {} relayed ───────────────────────────────────────────────
restart_mock '{}'
out=$(run_dispatcher PostToolUse '{"tool_name":"Read"}')
assert_eq "$out" "{}" "allow response relayed"

# ── Case 4: unconfigured (no API key) → {} without calling server ──────────
TMP_HOME="$(mktemp -d)"
out=$(HOME="$TMP_HOME" CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  ROGUE_API_KEY='' "$SH" "$HOOK" PreToolUse <<< '{}')
rm -rf "$TMP_HOME"
assert_eq "$out" "{}" "unconfigured fails open"

# ── Case 5: Git Bash stand-down (uname=MINGW) → {} before any work ──────────
STUB="$(mktemp -d)"
printf '#!/bin/sh\necho MINGW64_NT-10.0\n' > "$STUB/uname"
chmod +x "$STUB/uname"
out=$(PATH="$STUB:$PATH" "$SH" "$HOOK" PreToolUse <<< '{}')
rm -rf "$STUB"
assert_eq "$out" "{}" "Git Bash stand-down emits {}"

# ── Case 6: a poisoned actor identity in an env file is rejected ────────────
# End-to-end guard for the Cowork fix: compiled bundles already in the field bake
# `: "${ROGUE_ACTOR_EMAIL:=$(git config --global user.email)}"` into an env file
# that hook.sh sources BEFORE actor.sh, and inside the sandbox that git identity
# is Anthropic's synthetic one. The dispatcher must distrust it and fall through
# to CLAUDE_CODE_USER_EMAIL. (Cascade unit coverage lives in test_actor_sh.sh.)
restart_mock '{}'
TMP_HOME="$(mktemp -d)"
cat > "$TMP_HOME/.rogue-env" <<EOF
export ROGUE_API_KEY=test-key
export ROGUE_ACTOR_EMAIL=noreply@anthropic.com
export ROGUE_ACTOR_NAME=Claude
export ROGUE_BASE_URL=http://127.0.0.1:${PORT}
EOF
out=$(HOME="$TMP_HOME" CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  CLAUDE_CODE_USER_EMAIL='real.user@corp.com' \
  ROGUE_API_KEY='' ROGUE_ACTOR_EMAIL='' ROGUE_ACTOR_NAME='' ROGUE_BASE_URL='' \
  "$SH" "$HOOK" PreToolUse <<< '{}')
rm -rf "$TMP_HOME"
assert_eq "$out" "{}" "poisoned-actor run still relays the response"
assert_header "x-rogue-actor-email" "real.user@corp.com" "synthetic ROGUE_ACTOR_EMAIL replaced by CLAUDE_CODE_USER_EMAIL"
assert_header "x-rogue-actor-name"  "real.user"          "synthetic ROGUE_ACTOR_NAME replaced by its local-part"

# ── Cowork block modal (_rogue_want_alert) ─────────────────────────────────
# The modal is a Cowork-ONLY side-channel: Cowork's client discards hook-authored
# text on every documented channel, so the OS dialog is the only thing the user
# sees. The CLI and the Desktop app render blocks natively and must NOT get one.
# Every case below also asserts the server body is still relayed verbatim and the
# dispatcher exits 0 — the modal must never become a substitute for the decision.
#
# Runs the dispatcher with a stubbed `osascript` on PATH and a per-case
# ROGUE_LOG_FILE, then reads the gate's verdict out of the log: `alert_rc=<status>`
# (the alert ran, status propagated from osascript, with `alert_err` on failure)
# vs `alert_skipped=1` (the gate declined). The alert is backgrounded, so alert_rc
# needs a short poll.
BLOCK_BODY='{"decision":"block","reason":"PII detected"}'

# A minimal bin dir holding every external the dispatcher chain needs and NOTHING
# else — critically, no osascript. Cases put their own stub ahead of it, so the
# capability probe sees exactly what the case intends. Listing the tools
# explicitly (rather than filtering /usr/bin) also documents the dispatcher's
# real dependency surface: hook.sh + actor.sh + git-identity.sh + install-id.sh +
# security-alert.sh. No git: the identity comes from the config files.
SANDBOX_BIN="$(mktemp -d)"
# "$SH" is in the list because TEST_SH=dash names an interpreter that is not
# called `sh` — without it the sandboxed PATH cannot find the shell under test.
for tool in "$SH" sh bash env curl date mkdir dirname tr grep sed head cat hostname whoami awk uname sleep; do
  src="$(command -v "$tool" 2>/dev/null)" || continue
  [ -n "$src" ] && ln -sf "$src" "$SANDBOX_BIN/$tool"
done

# Runs hook.sh with a stubbed osascript. Args: <stub-mode> <event> <payload>
# then extra `KEY=VAL` env assignments. Sets LOG_FILE / OUT for the caller.
# stub-mode: ok | fail | hang | none  (none = no osascript on PATH at all)
run_alert_case() {
  local mode="$1" event="$2" payload="$3"; shift 3
  local tmp_home stub
  tmp_home="$(mktemp -d)"; stub="$(mktemp -d)"
  cp "$ENV_FILE" "$tmp_home/.rogue-env"
  LOG_FILE="$tmp_home/hook.log"
  case "$mode" in
    ok)   printf '#!/bin/sh\nexit 0\n'            > "$stub/osascript" ;;
    # Emits on stderr and exits non-zero, the shape of a real failure (a TCC
    # denial prints "Not authorized to send Apple events"). Two lines, so the
    # fold-to-one-line before sanitizing is exercised too.
    fail) printf '#!/bin/sh\nprintf "Not authorized to send Apple events\\nto System Events.\\n" >&2\nexit 1\n' > "$stub/osascript" ;;
    # Outlives the dispatcher on purpose: the regression test for the fd leak.
    hang) printf '#!/bin/sh\nsleep 30\n'          > "$stub/osascript" ;;
  esac
  [ "$mode" = none ] || chmod +x "$stub/osascript"
  # PATH is the stub dir plus SANDBOX_BIN, never /usr/bin — a dev Mac ships a real
  # /usr/bin/osascript, which would both defeat the `none` case and pop an actual
  # dialog on the tester's screen.
  OUT=$(env -i HOME="$tmp_home" PATH="$stub:$SANDBOX_BIN" \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" ROGUE_LOG_FILE="$LOG_FILE" \
    CLAUDE_CODE_ENTRYPOINT=local-agent "$@" \
    "$SH" "$HOOK" "$event" <<< "$payload")
  ALERT_STUB="$stub"; ALERT_HOME="$tmp_home"
}

cleanup_alert_case() { rm -rf "$ALERT_STUB" "$ALERT_HOME"; }

# Wait (briefly) for the backgrounded alert subshell to append its alert_rc line.
wait_for_log() {
  local pat="$1" i
  for i in $(seq 1 60); do
    grep -q "$pat" "$LOG_FILE" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

assert_log() {
  local pat="$1" label="$2"
  if grep -q "$pat" "$LOG_FILE" 2>/dev/null; then
    echo "  ok: $label"
  else
    echo "FAIL [$label]: no /$pat/ in hook.log:" >&2; cat "$LOG_FILE" >&2; exit 1
  fi
}

assert_no_log() {
  local pat="$1" label="$2"
  if grep -q "$pat" "$LOG_FILE" 2>/dev/null; then
    echo "FAIL [$label]: unexpected /$pat/ in hook.log:" >&2; cat "$LOG_FILE" >&2; exit 1
  fi
  echo "  ok: $label"
}

# ── Case 7: local Cowork fires the modal ───────────────────────────────────
# CLAUDE_CODE_IS_COWORK=1 is what identifies a LOCAL Cowork session: it spawns
# Claude Code with CLAUDE_CODE_ENTRYPOINT=local-agent, not a *cowork* value, so
# the entrypoint alone would file it as the CLI.
restart_mock "$BLOCK_BODY"
run_alert_case ok UserPromptSubmit '{"prompt":"a@b.com and c@d.com"}' CLAUDE_CODE_IS_COWORK=1
assert_eq "$OUT" "$BLOCK_BODY" "cowork-local: block relayed verbatim alongside the modal"
wait_for_log 'alert_rc=' || { echo "FAIL: alert never ran" >&2; cat "$LOG_FILE" >&2; exit 1; }
assert_log 'alert_rc=0 entrypoint=local-agent' "cowork-local: modal fired, alert_rc logged"
cleanup_alert_case

# ── Case 8: cloud Cowork does NOT fire (headless container) ────────────────
# Entrypoint remote_cowork resolves the surface, CLAUDE_CODE_REMOTE=true excludes
# it. Skipped explicitly so the log never implies the user was shown something.
restart_mock "$BLOCK_BODY"
run_alert_case ok UserPromptSubmit '{"prompt":"a@b.com"}' \
  CLAUDE_CODE_ENTRYPOINT=remote_cowork CLAUDE_CODE_REMOTE=true
assert_eq "$OUT" "$BLOCK_BODY" "cowork-cloud: block relayed verbatim"
assert_log 'alert_skipped=1 .*remote=true' "cowork-cloud: alert skipped, remote logged"
assert_no_log 'alert_rc=' "cowork-cloud: modal never launched"
cleanup_alert_case

# ── Case 9: the CLI never gets a modal (Claude renders blocks natively) ────
restart_mock "$BLOCK_BODY"
run_alert_case ok UserPromptSubmit '{"prompt":"a@b.com"}' CLAUDE_CODE_ENTRYPOINT=cli
assert_eq "$OUT" "$BLOCK_BODY" "cli: block relayed verbatim"
assert_log 'alert_skipped=1 entrypoint=cli cowork=unset remote=unset' \
  "cli: alert skipped with all three gate inputs logged"
assert_no_log 'alert_rc=' "cli: modal never launched"
cleanup_alert_case

# ── Case 10: the Desktop app never gets a modal either ────────────────────
restart_mock "$BLOCK_BODY"
run_alert_case ok UserPromptSubmit '{"prompt":"a@b.com"}' CLAUDE_CODE_ENTRYPOINT=desktop
assert_eq "$OUT" "$BLOCK_BODY" "desktop: block relayed verbatim"
assert_no_log 'alert_rc=' "desktop: modal never launched"
cleanup_alert_case

# ── Case 11: no osascript on PATH → capability gate declines ───────────────
# Capability is the final authority: the env vars are undocumented and will move.
restart_mock "$BLOCK_BODY"
run_alert_case none UserPromptSubmit '{"prompt":"a@b.com"}' CLAUDE_CODE_IS_COWORK=1
assert_eq "$OUT" "$BLOCK_BODY" "no-osascript: block relayed verbatim"
assert_log 'alert_skipped=1' "no-osascript: alert skipped even though Cowork vars are set"
cleanup_alert_case

# ── Case 12: an allow response fires nothing at all ────────────────────────
restart_mock '{}'
run_alert_case ok PostToolUse '{"tool_name":"Read"}' CLAUDE_CODE_IS_COWORK=1
assert_eq "$OUT" "{}" "allow: relayed verbatim"
assert_no_log 'alert_' "allow: neither fired nor skipped — the branch is untouched"
cleanup_alert_case

# ── Case 13: a failing osascript reports the REAL status, with the reason ──
# alert_rc exists to make TCC denials / AppleScript errors / missing GUI sessions
# visible in hook.log. security-alert.sh used to end both osascript branches with
# `|| true` and `exit 0`, so EVERY such failure logged as alert_rc=0 and the log
# line carried no signal at all. Assert the real code and the captured stderr —
# `alert_rc=` alone passes against the broken version.
restart_mock "$BLOCK_BODY"
run_alert_case fail PreToolUse '{"tool_name":"Bash"}' CLAUDE_CODE_IS_COWORK=1
assert_eq "$OUT" "$BLOCK_BODY" "osascript failure: block still relayed verbatim"
wait_for_log 'alert_rc=' || { echo "FAIL: alert never ran" >&2; cat "$LOG_FILE" >&2; exit 1; }
assert_log 'alert_rc=1 ' "osascript failure: the real non-zero status is logged, not 0"
# A bare rc can't distinguish a TCC denial from a user cancel (both exit 1), so the
# helper's stderr rides along.
assert_log 'alert_err="Not authorized to send Apple events to System Events."' \
  "osascript failure: stderr captured as alert_err, folded to one line"
cleanup_alert_case

# ── Case 13b: a SUCCESSFUL alert logs rc 0 and no spurious alert_err ───────
restart_mock "$BLOCK_BODY"
run_alert_case ok PreToolUse '{"tool_name":"Bash"}' CLAUDE_CODE_IS_COWORK=1
wait_for_log 'alert_rc=' || { echo "FAIL: alert never ran" >&2; cat "$LOG_FILE" >&2; exit 1; }
assert_log 'alert_rc=0 ' "osascript success: rc is 0"
assert_no_log 'alert_err' "osascript success: no alert_err on a clean run"
cleanup_alert_case

# ── Case 14: a HANGING modal must not delay the dispatcher ─────────────────
# Regression test for the fd leak fixed in dbfd3ee. The alert subshell waits for
# the modal to capture alert_rc; if its stdout is not detached it holds Claude's
# read pipe open until the dialog closes, Claude times the hook out, and the
# BLOCK FAILS OPEN. hook.sh must return the decision immediately regardless.
restart_mock "$BLOCK_BODY"
START=$(date +%s)
run_alert_case hang UserPromptSubmit '{"prompt":"a@b.com"}' CLAUDE_CODE_IS_COWORK=1
ELAPSED=$(( $(date +%s) - START ))
assert_eq "$OUT" "$BLOCK_BODY" "hanging modal: block relayed verbatim"
if [ "$ELAPSED" -lt 10 ]; then
  echo "  ok: hanging modal: dispatcher returned in ${ELAPSED}s (fds detached)"
else
  echo "FAIL: dispatcher waited ${ELAPSED}s on a hanging modal — subshell fds leaked" >&2
  exit 1
fi
# Targeted at our own stub path only — never a bare `pkill -f sleep`.
pkill -f "$ALERT_STUB/osascript" 2>/dev/null || true
cleanup_alert_case

# ── Case 15: ROGUE_ALERT_EVENTS narrows without a release ──────────────────
# The escape hatch for the open question: tool denials are confirmed to render in
# Cowork CLOUD but untested locally. If they render locally too, this narrows the
# modal to UserPromptSubmit — the one event with no visible channel — in config.
restart_mock "$BLOCK_BODY"
run_alert_case ok PreToolUse '{"tool_name":"Bash"}' \
  CLAUDE_CODE_IS_COWORK=1 ROGUE_ALERT_EVENTS=UserPromptSubmit
assert_eq "$OUT" "$BLOCK_BODY" "narrowed: block relayed verbatim"
assert_log 'alert_skipped=1' "narrowed: PreToolUse excluded by ROGUE_ALERT_EVENTS"
cleanup_alert_case

restart_mock "$BLOCK_BODY"
run_alert_case ok UserPromptSubmit '{"prompt":"a@b.com"}' \
  CLAUDE_CODE_IS_COWORK=1 ROGUE_ALERT_EVENTS=UserPromptSubmit
wait_for_log 'alert_rc=' || { echo "FAIL: alert never ran" >&2; cat "$LOG_FILE" >&2; exit 1; }
assert_log 'alert_rc=' "narrowed: UserPromptSubmit still allowed by ROGUE_ALERT_EVENTS"
cleanup_alert_case

# ── Case 16: ROGUE_ALERT=0 is a kill switch ────────────────────────────────
restart_mock "$BLOCK_BODY"
run_alert_case ok UserPromptSubmit '{"prompt":"a@b.com"}' CLAUDE_CODE_IS_COWORK=1 ROGUE_ALERT=0
assert_eq "$OUT" "$BLOCK_BODY" "ROGUE_ALERT=0: block relayed verbatim"
assert_log 'alert_skipped=1' "ROGUE_ALERT=0: modal disabled"
cleanup_alert_case

echo
echo "All hook.sh tests passed (SH=$SH)."
