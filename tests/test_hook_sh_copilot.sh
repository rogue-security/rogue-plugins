#!/usr/bin/env bash
# tests/test_hook_sh_copilot.sh — end-to-end for the Copilot bash dispatcher
# (plugins/copilot/scripts/hook.sh): env file → hook.sh → mock server → stdout.
# Holds the dispatcher to the verbatim-relay + header + fail-open contract, and
# to the Copilot-specific invariant that it ALWAYS exits 0 (preToolUse is
# fail-closed on the CLI side, so a non-zero exit would deny the tool).
#
# Cases 4b-4e also cover the ONE out-of-band exception to pure relay — the
# JetBrains silent-block alert: that it fires only for a userPromptSubmitted
# block in the IDE, never for a natively-rendered decision or an allow, that the
# block-shape match is strict enough not to trip on a body that merely carries
# "block" elsewhere, that surface detection survives Linux's 15-char `comm`
# truncation, and that the composed AppleScript literal is correctly escaped.
#
# Copilot runs the `bash` command on macOS/Linux; override with TEST_SH=dash to
# exercise strict POSIX and catch bashisms.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO/plugins/copilot/scripts/hook.sh"
SH="${TEST_SH:-sh}"

PORT=$((RANDOM % 10000 + 30000))
HEADERS_FILE="$(mktemp)"
ENV_FILE="$(mktemp)"
OUT_FILE="$(mktemp)"
# Optional directory prepended to the dispatcher's PATH (see make_ps_shim).
TEST_BIN=""

cleanup() {
  [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null || true
  rm -f "$ENV_FILE" "$HEADERS_FILE" "$OUT_FILE"
}
trap cleanup EXIT

cat > "$ENV_FILE" <<EOF
export ROGUE_API_KEY=test-key
export ROGUE_ACTOR_EMAIL=test@example.com
export ROGUE_ACTOR_NAME='Test User'
export ROGUE_BASE_URL=http://127.0.0.1:${PORT}
EOF

# Run with a clean HOME holding our env file. Clear ROGUE_* from the process env
# so only the file drives resolution (process env would otherwise win). Writes
# stdout to $OUT_FILE and RETURNS the dispatcher's exit code (so the caller can
# assert exit 0 — command substitution would hide it in a subshell).
run_dispatcher() {
  local tmp_home rc
  tmp_home="$(mktemp -d)"
  cp "$ENV_FILE" "$tmp_home/.rogue-env"
  # Optionally pre-seed the subagent→parent cache (~/.rogue/copilot-submap/<id>,
  # "<parent>\n<displayName>") the dispatcher writes after its first resolve.
  # Reading it back is a real production path, and unlike the transcript scraper
  # (whose "[^"]*" regex can never yield a quote) it can carry ANY display name —
  # which is how the '"' + '\' case below reaches the tagger.
  if [ -n "${SEED_SUBMAP_ID:-}" ]; then
    mkdir -p "$tmp_home/.rogue/copilot-submap"
    printf '%s' "${SEED_SUBMAP_VALUE:-}" > "$tmp_home/.rogue/copilot-submap/$SEED_SUBMAP_ID"
  fi
  set +e
  HOME="$tmp_home" \
    ROGUE_API_KEY='' ROGUE_ACTOR_EMAIL='' ROGUE_ACTOR_NAME='' ROGUE_BASE_URL='' \
    ROGUE_LOG_FILE="$tmp_home/hook.log" \
    ROGUE_FLUSH_WAIT_ITERS="${ROGUE_FLUSH_WAIT_ITERS:-}" \
    ROGUE_COPILOT_STATE_DIR="${ROGUE_COPILOT_STATE_DIR:-}" \
    ROGUE_SUBAGENT_RESOLVE_ITERS="${ROGUE_SUBAGENT_RESOLVE_ITERS:-}" \
    PATH="${TEST_BIN:+$TEST_BIN:}$PATH" \
    "$SH" "$HOOK" "$1" <<< "$2" > "$OUT_FILE"
  rc=$?
  set -e
  LAST_HOME="$tmp_home"
  # KEEP_HOME=1 preserves the run's HOME so a caller can assert on hook.log.
  [ "${KEEP_HOME:-0}" = "1" ] || rm -rf "$tmp_home"
  return $rc
}

# Build a throwaway `ps` shim so in_jetbrains_ide's ancestry walk can be driven
# from a test (the real ancestry under the test runner has no copilot process).
# $1 = what `ps -o comm=` should report for every ancestor. Echoes the dir; the
# caller prepends it via TEST_BIN and removes it afterwards.
make_ps_shim() {
  local d
  d="$(mktemp -d)"
  cat > "$d/ps" <<EOF
#!/bin/sh
case "\$*" in
  *comm*) echo '$1' ;;
  *ppid*) echo 1 ;;
esac
exit 0
EOF
  chmod +x "$d/ps"
  printf '%s' "$d"
}

# The last POSTed request body, as the raw string the mock received.
posted_body() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["body"])' "$HEADERS_FILE"
}
# One top-level field of the last POSTed body ('' when absent).
posted_field() {
  posted_body | python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1],""))' "$1"
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

# One inbound header of the last POST ('' when absent). mock_server.py records
# them lowercased, which is what curl sends anyway.
header_value() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["headers"].get(sys.argv[2], ""))' "$HEADERS_FILE" "$1"
}

assert_header() {
  local key="$1" expected="$2" label="$3"
  assert_eq "$(header_value "$key")" "$expected" "$label"
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

# ── Case 1: preToolUse deny relayed verbatim + headers + path + exit 0 ──────
start_mock '{"permissionDecision":"deny","permissionDecisionReason":"blocked"}'
set +e; run_dispatcher preToolUse '{"toolName":"bash","toolArgs":{"command":"rm -rf /"}}'; LAST_RC=$?; set -e
out=$(cat "$OUT_FILE")
assert_eq "$out" '{"permissionDecision":"deny","permissionDecisionReason":"blocked"}' "preToolUse deny relayed verbatim"
assert_eq "$LAST_RC" "0" "preToolUse deny still exits 0 (fail-closed safety)"
assert_header "x-rogue-event"       "preToolUse"       "x-rogue-event is the verbatim Copilot event name"
assert_header "x-rogue-api-key"     "test-key"         "x-rogue-api-key forwarded"
assert_header "x-rogue-actor-email" "test@example.com" "x-rogue-actor-email forwarded"
assert_header "x-rogue-actor-name"  "Test User"        "x-rogue-actor-name forwarded (with space)"
assert_no_header "x-rogue-source"   "no x-rogue-source header (cursor-only)"
# Fleet-liveness trio: the same host/version/agent the heartbeat sends, on EVERY
# event, so the roster row is refreshed by ordinary traffic and not only at
# session start. `agent` must stay the PLUGIN_REPOS key, or the backend stops
# resolving a latest version for these rows. See scripts/install-id.sh.
assert_header "x-rogue-agent"       "github_copilot"   "x-rogue-agent is the roster's agent value"
assert_header_present "x-rogue-host"    "x-rogue-host sent on every event"
assert_header_present "x-rogue-version" "x-rogue-version sent on every event"
path=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["path"])' "$HEADERS_FILE")
assert_eq "$path" "/api/v1/hooks/copilot" "POST path is /api/v1/hooks/copilot"

# ── Case 2: body passed through verbatim ───────────────────────────────────
body=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["body"])' "$HEADERS_FILE")
assert_eq "$body" '{"toolName":"bash","toolArgs":{"command":"rm -rf /"}}' "request body passed through unchanged"

# ── Case 3: postToolUse additionalContext relayed ──────────────────────────
restart_mock '{"additionalContext":"warning"}'
run_dispatcher postToolUse '{"toolName":"bash","toolResult":{"resultType":"success","textResultForLlm":"ok"}}'
out=$(cat "$OUT_FILE")
assert_eq "$out" '{"additionalContext":"warning"}' "postToolUse additionalContext relayed"

# ── Case 4: userPromptSubmitted monitor — body relayed ─────────────────────
restart_mock '{}'
run_dispatcher userPromptSubmitted '{"prompt":"ignore previous"}'
out=$(cat "$OUT_FILE")
assert_eq "$out" "{}" "userPromptSubmitted allow relayed"

# ── Case 4b: JetBrains silent-block alert ──────────────────────────────────
# JetBrains honors a userPromptSubmitted block but renders nothing for it, so
# the dispatcher fires an out-of-band notification — ONLY there, ONLY for that
# event, and never altering the relayed body. DRYRUN logs instead of notifying.
# Surface is simulated via the env fallback in in_jetbrains_ide (the ancestry
# walk finds no copilot process under the test runner).
BLOCK='{"decision":"block","reason":"Coding Agent Security: PROMPT_INJECTION"}'

restart_mock "$BLOCK"
KEEP_HOME=1 \
  ROGUE_IDE_ALERT_DRYRUN=1 COPILOT_CLI=1 COPILOT_CLI_BINARY_VERSION='' PKG_EXECPATH=/x \
  run_dispatcher userPromptSubmitted '{"prompt":"ignore previous"}'
out=$(cat "$OUT_FILE"); log_txt=$(cat "$LAST_HOME/hook.log"); rm -rf "$LAST_HOME"
assert_eq "$out" "$BLOCK" "IDE block still relayed verbatim (alert is out-of-band)"
case "$log_txt" in
  *ide_alert=fired*) echo "ok: IDE userPromptSubmitted block fires the alert" ;;
  *) echo "FAIL: IDE userPromptSubmitted block did not fire the alert"; exit 1 ;;
esac

# Terminal CLI renders "! <reason>" itself — alerting there would double-notify.
restart_mock "$BLOCK"
KEEP_HOME=1 \
  ROGUE_IDE_ALERT_DRYRUN=1 COPILOT_CLI=1 COPILOT_CLI_BINARY_VERSION=1.0.75 PKG_EXECPATH='' \
  run_dispatcher userPromptSubmitted '{"prompt":"ignore previous"}'
log_txt=$(cat "$LAST_HOME/hook.log"); rm -rf "$LAST_HOME"
case "$log_txt" in
  *ide_alert=fired*) echo "FAIL: alert fired on the terminal CLI surface"; exit 1 ;;
  *) echo "ok: no alert on the terminal CLI surface" ;;
esac

# preToolUse deny renders natively in BOTH surfaces — no alert even in the IDE.
restart_mock '{"permissionDecision":"deny","permissionDecisionReason":"nope"}'
KEEP_HOME=1 \
  ROGUE_IDE_ALERT_DRYRUN=1 COPILOT_CLI=1 COPILOT_CLI_BINARY_VERSION='' PKG_EXECPATH=/x \
  run_dispatcher preToolUse '{"toolName":"bash"}'
log_txt=$(cat "$LAST_HOME/hook.log"); rm -rf "$LAST_HOME"
case "$log_txt" in
  *ide_alert=fired*) echo "FAIL: alert fired for a natively-rendered preToolUse deny"; exit 1 ;;
  *) echo "ok: no alert for preToolUse deny (Copilot renders it)" ;;
esac

# An allow must never alert, IDE or not.
restart_mock '{}'
KEEP_HOME=1 \
  ROGUE_IDE_ALERT_DRYRUN=1 COPILOT_CLI=1 COPILOT_CLI_BINARY_VERSION='' PKG_EXECPATH=/x \
  run_dispatcher userPromptSubmitted '{"prompt":"hello"}'
log_txt=$(cat "$LAST_HOME/hook.log"); rm -rf "$LAST_HOME"
case "$log_txt" in
  *ide_alert=fired*) echo "FAIL: alert fired on an allow"; exit 1 ;;
  *) echo "ok: no alert on an allow" ;;
esac

# ROGUE_IDE_ALERT=0 is an escape hatch for users who don't want the popup.
restart_mock "$BLOCK"
KEEP_HOME=1 \
  ROGUE_IDE_ALERT=0 ROGUE_IDE_ALERT_DRYRUN=1 COPILOT_CLI=1 COPILOT_CLI_BINARY_VERSION='' PKG_EXECPATH=/x \
  run_dispatcher userPromptSubmitted '{"prompt":"ignore previous"}'
out=$(cat "$OUT_FILE"); log_txt=$(cat "$LAST_HOME/hook.log"); rm -rf "$LAST_HOME"
assert_eq "$out" "$BLOCK" "ROGUE_IDE_ALERT=0 still relays the block verbatim"
case "$log_txt" in
  *ide_alert=fired*) echo "FAIL: ROGUE_IDE_ALERT=0 did not suppress the alert"; exit 1 ;;
  *) echo "ok: ROGUE_IDE_ALERT=0 suppresses the alert" ;;
esac

# ── Case 4c: the block-shape match must be STRICT ──────────────────────────
# The response body is server-controlled and carries sibling fields. A loose
# glob (*'"decision"'*'"block"'*) matches this ALLOW body — the literal
# substring "block" appears verbatim as another field's value — and would pop a
# modal on a prompt that was never blocked. The dispatcher must require the
# actual "decision" : "block" pair.
ALLOW_QUOTING_BLOCK='{"decision":"allow","reason":"no findings","rulesetMode":"block"}'
restart_mock "$ALLOW_QUOTING_BLOCK"
KEEP_HOME=1 \
  ROGUE_IDE_ALERT_DRYRUN=1 COPILOT_CLI=1 COPILOT_CLI_BINARY_VERSION='' PKG_EXECPATH=/x \
  run_dispatcher userPromptSubmitted '{"prompt":"hello"}'
out=$(cat "$OUT_FILE"); log_txt=$(cat "$LAST_HOME/hook.log"); rm -rf "$LAST_HOME"
assert_eq "$out" "$ALLOW_QUOTING_BLOCK" 'allow body carrying a "block" sibling value is relayed verbatim'
case "$log_txt" in
  *ide_alert=fired*) echo 'FAIL: alert fired on an allow carrying a "block" sibling value'; exit 1 ;;
  *) echo '  ok: no alert on an allow carrying a "block" sibling value' ;;
esac

# ── Case 4d: surface detection survives Linux `comm` truncation ────────────
# Linux caps comm at TASK_COMM_LEN-1 = 15 chars, so copilot-language-server is
# reported as "copilot-languag": a pattern matching only the full name can NEVER
# hit there. The env fallback is deliberately set to the TERMINAL shape, so only
# the ancestry walk can produce a positive here.
PS_SHIM="$(make_ps_shim copilot-languag)"
restart_mock "$BLOCK"
KEEP_HOME=1 TEST_BIN="$PS_SHIM" \
  ROGUE_IDE_ALERT_DRYRUN=1 COPILOT_CLI=1 COPILOT_CLI_BINARY_VERSION=1.0.75 PKG_EXECPATH='' \
  run_dispatcher userPromptSubmitted '{"prompt":"ignore previous"}'
log_txt=$(cat "$LAST_HOME/hook.log"); rm -rf "$LAST_HOME" "$PS_SHIM"
case "$log_txt" in
  *ide_alert=fired*) echo "  ok: Linux-truncated 'copilot-languag' parent detected as the IDE" ;;
  *) echo "FAIL: Linux-truncated 'copilot-languag' parent not detected as the IDE"; exit 1 ;;
esac

# ...and the terminal CLI still wins over an IDE-shaped env. macOS BSD
# `ps -o comm=` prints the full executable path, so the *copilot) arm has to
# match a trailing path component — and must stay SECOND in the case, since
# ".../copilot-language-server" would also match *copilot*.
PS_SHIM="$(make_ps_shim /opt/homebrew/bin/copilot)"
restart_mock "$BLOCK"
KEEP_HOME=1 TEST_BIN="$PS_SHIM" \
  ROGUE_IDE_ALERT_DRYRUN=1 COPILOT_CLI=1 COPILOT_CLI_BINARY_VERSION='' PKG_EXECPATH=/x \
  run_dispatcher userPromptSubmitted '{"prompt":"ignore previous"}'
log_txt=$(cat "$LAST_HOME/hook.log"); rm -rf "$LAST_HOME" "$PS_SHIM"
case "$log_txt" in
  *ide_alert=fired*) echo "FAIL: a plain 'copilot' parent (terminal CLI) alerted anyway"; exit 1 ;;
  *) echo "  ok: full-path 'copilot' parent (terminal CLI) suppresses the alert" ;;
esac

# ── Case 4e: composed AppleScript literal — newlines + escaping ────────────
# ROGUE_IDE_ALERT_DRYRUN=2 logs the exact string that would be interpolated into
# the `display alert ... message "…"` literal (real newlines rendered as '|').
# Two invariants: the API's literal "\n" (backslash + n, straight out of the
# JSON) becomes a REAL newline so the two-paragraph reason renders as written
# (the call site must not pre-collapse it to a space), and every backslash is
# doubled for the AppleScript literal so server-controlled text cannot break out
# of it. (A literal '"' can't be exercised here: the raw-text reason extractor
# stops at the first quote, so one never reaches the escaper.)
NL_BLOCK='{"decision":"block","reason":"Rogue blocked.\nPath C:\\temp; use rgx!"}'
restart_mock "$NL_BLOCK"
KEEP_HOME=1 \
  ROGUE_IDE_ALERT_DRYRUN=2 COPILOT_CLI=1 COPILOT_CLI_BINARY_VERSION='' PKG_EXECPATH=/x \
  run_dispatcher userPromptSubmitted '{"prompt":"ignore previous"}'
out=$(cat "$OUT_FILE"); log_txt=$(cat "$LAST_HOME/hook.log"); rm -rf "$LAST_HOME"
assert_eq "$out" "$NL_BLOCK" "DRYRUN=2 still relays the block verbatim"
if printf '%s' "$log_txt" | grep -qF 'ide_alert=escaped msg=Rogue blocked.|Path C:\\\\temp; use rgx!'; then
  echo '  ok: literal \n becomes a real newline and backslashes are doubled'
else
  echo "FAIL [alert escaping]: log was <$log_txt>" >&2; exit 1
fi

# ── Case 5: unconfigured (no API key) → {} without calling server ──────────
TMP_HOME="$(mktemp -d)"
set +e
out=$(HOME="$TMP_HOME" ROGUE_API_KEY='' ROGUE_LOG_FILE="$TMP_HOME/h.log" "$SH" "$HOOK" preToolUse <<< '{}')
rc=$?
set -e
rm -rf "$TMP_HOME"
assert_eq "$out" "{}" "unconfigured fails open"
assert_eq "$rc" "0" "unconfigured exits 0"

# ── Case 6: non-200 → fail-open {} + exit 0 ────────────────────────────────
restart_mock '{"permissionDecision":"deny"}' 500
set +e; run_dispatcher preToolUse '{"toolName":"bash"}'; LAST_RC=$?; set -e
out=$(cat "$OUT_FILE")
assert_eq "$out" "{}" "non-200 fails open"
assert_eq "$LAST_RC" "0" "non-200 exits 0"

# ── Case 7: sessionStart unconfigured → additionalContext hint, no server ──
TMP_HOME="$(mktemp -d)"
out=$(HOME="$TMP_HOME" ROGUE_API_KEY='' ROGUE_LOG_FILE="$TMP_HOME/h.log" "$SH" "$HOOK" sessionStart <<< '{}')
rm -rf "$TMP_HOME"
case "$out" in
  *'"additionalContext"'*'Rogue Security'*'/rogue:setup'*) echo "  ok: sessionStart unconfigured emits hint" ;;
  *) echo "FAIL [sessionStart hint]: got <$out>" >&2; exit 1 ;;
esac

# ── Case 8: agentStop augments the POST body with the transcript tail ──────
TDIR="$(mktemp -d)"
printf '%s\n' \
  '{"type":"user.message","timestamp":"2026-07-20T09:00:00.000Z","data":{"content":"hi","interactionId":"main-1"}}' \
  '{"type":"assistant.message","timestamp":"2026-07-20T09:00:02.000Z","data":{"content":"MAIN final","interactionId":"main-1"}}' \
  '{"type":"assistant.turn_end","timestamp":"2026-07-20T09:00:02.100Z"}' \
  > "$TDIR/events.jsonl"
restart_mock '{}'
AGENTSTOP_PAYLOAD=$(printf '{"sessionId":"u1","timestamp":1784538002000,"stopReason":"end_turn","transcriptPath":"%s"}' "$TDIR/events.jsonl")
set +e; run_dispatcher agentStop "$AGENTSTOP_PAYLOAD"; LAST_RC=$?; set -e
assert_eq "$LAST_RC" "0" "agentStop exits 0"
body=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["body"])' "$HEADERS_FILE")
# augmented body must still be valid JSON and carry transcriptTailB64
valid=$(printf '%s' "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("transcriptTailB64" in d)')
assert_eq "$valid" "True" "agentStop body is valid JSON with transcriptTailB64"
b64=$(printf '%s' "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("transcriptTailB64",""))')
decoded=$(python3 -c 'import base64,sys; print(base64.b64decode(sys.argv[1]).decode("utf-8","replace"))' "$b64")
case "$decoded" in
  *'MAIN final'*) echo "  ok: transcriptTailB64 decodes to the transcript" ;;
  *) echo "FAIL [agentStop tail decode]: <$decoded>" >&2; exit 1 ;;
esac
rm -rf "$TDIR"

# ── Case 8b: whitespace around the transcriptPath key/colon still augments ──
# JSON allows whitespace around keys and colons; the extractor must tolerate it
# and still produce transcriptTailB64 (regression guard for a pretty-printed
# stop payload).
TDIR="$(mktemp -d)"
printf '%s\n' \
  '{"type":"assistant.message","timestamp":"2026-07-20T09:00:02.000Z","data":{"content":"WS final","interactionId":"main-1"}}' \
  '{"type":"assistant.turn_end","timestamp":"2026-07-20T09:00:02.100Z"}' \
  > "$TDIR/events.jsonl"
restart_mock '{}'
WS_PAYLOAD=$(printf '{"sessionId":"u1", "transcriptPath" : "%s"}' "$TDIR/events.jsonl")
set +e; run_dispatcher agentStop "$WS_PAYLOAD"; LAST_RC=$?; set -e
assert_eq "$LAST_RC" "0" "whitespace-formatted agentStop exits 0"
body=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["body"])' "$HEADERS_FILE")
valid=$(printf '%s' "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("transcriptTailB64" in d)')
assert_eq "$valid" "True" "whitespace-formatted transcriptPath still yields transcriptTailB64"
rm -rf "$TDIR"

# ── Case 9: agentStop with unreadable transcriptPath → body unchanged, exit 0
restart_mock '{}'
set +e; run_dispatcher agentStop '{"sessionId":"u1","timestamp":1,"stopReason":"end_turn","transcriptPath":"/no/such/file.jsonl"}'; LAST_RC=$?; set -e
assert_eq "$LAST_RC" "0" "agentStop with missing transcript exits 0"
body=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["body"])' "$HEADERS_FILE")
case "$body" in
  *transcriptTailB64*) echo "FAIL [agentStop missing tail]: should not add tail; body=<$body>" >&2; exit 1 ;;
  *) echo "  ok: agentStop with missing transcript posts the body unchanged" ;;
esac

# ── Case 10: sessionStart configured → POSTs for audit and relays {} ────────
restart_mock '{}'
set +e; run_dispatcher sessionStart '{"source":"new"}'; LAST_RC=$?; set -e
out=$(cat "$OUT_FILE")
assert_eq "$out" "{}" "sessionStart configured relays {}"
assert_eq "$LAST_RC" "0" "sessionStart configured exits 0"
event=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["headers"].get("x-rogue-event",""))' "$HEADERS_FILE")
assert_eq "$event" "sessionStart" "sessionStart configured POSTs with x-rogue-event=sessionStart"
body=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["body"])' "$HEADERS_FILE")
assert_eq "$body" '{"source":"new"}' "sessionStart configured POSTs the payload body (proves it POSTed, not stale)"

# ── Case 11: agentStop payload ending in a nested object ("}}") stays valid ─
# Guards the single-'}' strip: TrimEnd-all-braces would corrupt this body.
TDIR="$(mktemp -d)"
printf '%s\n' '{"type":"assistant.message","timestamp":"2026-07-20T09:00:02.000Z","data":{"content":"NESTED ok","interactionId":"main-1"}}' > "$TDIR/events.jsonl"
printf '%s\n' '{"type":"user.message","timestamp":"2026-07-20T09:00:00.000Z","data":{"content":"hi","interactionId":"main-1"}}' >> "$TDIR/events.jsonl"
printf '%s\n' '{"type":"assistant.turn_end","timestamp":"2026-07-20T09:00:02.100Z"}' >> "$TDIR/events.jsonl"
restart_mock '{}'
NESTED_PAYLOAD=$(printf '{"sessionId":"u1","timestamp":1784538002000,"transcriptPath":"%s","meta":{"k":"v"}}' "$TDIR/events.jsonl")
set +e; run_dispatcher agentStop "$NESTED_PAYLOAD"; LAST_RC=$?; set -e
assert_eq "$LAST_RC" "0" "agentStop with nested-object body exits 0"
body=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["body"])' "$HEADERS_FILE")
valid=$(printf '%s' "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("meta",{}).get("k")=="v" and "transcriptTailB64" in d)')
assert_eq "$valid" "True" "nested-object body stays valid JSON (meta preserved, tail added)"

# ── Case 12: flush-wait ignores our own hook.* lines to find the turn boundary ─
# agentStop hook.start/hook.end can already be in the transcript; the wait must
# skip them and still see assistant.turn_end as the last real line (return fast).
TDIR="$(mktemp -d)"
printf '%s\n' \
  '{"type":"user.message","timestamp":"2026-07-20T09:00:00.000Z","data":{"content":"hi","interactionId":"main-1"}}' \
  '{"type":"assistant.message","timestamp":"2026-07-20T09:00:02.000Z","data":{"content":"FLUSHED reply","interactionId":"main-1"}}' \
  '{"type":"assistant.turn_end","timestamp":"2026-07-20T09:00:02.100Z"}' \
  '{"type":"hook.start","timestamp":"2026-07-20T09:00:02.200Z"}' \
  > "$TDIR/events.jsonl"
restart_mock '{}'
START=$(date +%s)
set +e; run_dispatcher agentStop "$(printf '{"sessionId":"u1","timestamp":1784538002000,"stopReason":"end_turn","transcriptPath":"%s"}' "$TDIR/events.jsonl")"; LAST_RC=$?; set -e
ELAPSED=$(( $(date +%s) - START ))
assert_eq "$LAST_RC" "0" "agentStop with trailing hook.* lines exits 0"
body=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["body"])' "$HEADERS_FILE")
b64=$(printf '%s' "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("transcriptTailB64",""))')
decoded=$(python3 -c 'import base64,sys; print(base64.b64decode(sys.argv[1]).decode("utf-8","replace"))' "$b64")
case "$decoded" in
  *'FLUSHED reply'*) echo "  ok: turn_end detected past trailing hook lines; tail sent" ;;
  *) echo "FAIL [Case 12 tail]: <$decoded>" >&2; exit 1 ;;
esac
if [ "$ELAPSED" -le 2 ]; then echo "  ok: returned promptly (${ELAPSED}s) — no needless wait when flushed"; else echo "FAIL [Case 12]: waited ${ELAPSED}s despite turn_end present" >&2; exit 1; fi
rm -rf "$TDIR"

# ── Case 13: unflushed transcript (no turn_end) → bounded wait, then fail-open ─
# Last real line is a turn_start (final assistant.message not yet flushed). The
# dispatcher must NOT hang: it waits the bounded number of iterations then posts
# best-effort (exit 0). ROGUE_FLUSH_WAIT_ITERS keeps the test fast.
TDIR="$(mktemp -d)"
printf '%s\n' \
  '{"type":"user.message","timestamp":"2026-07-20T09:00:00.000Z","data":{"content":"hi","interactionId":"main-1"}}' \
  '{"type":"assistant.turn_start","timestamp":"2026-07-20T09:00:01.000Z","data":{"interactionId":"main-1"}}' \
  > "$TDIR/events.jsonl"
restart_mock '{}'
export ROGUE_FLUSH_WAIT_ITERS=2
START=$(date +%s)
set +e; run_dispatcher agentStop "$(printf '{"sessionId":"u1","timestamp":1784538002000,"stopReason":"end_turn","transcriptPath":"%s"}' "$TDIR/events.jsonl")"; LAST_RC=$?; set -e
ELAPSED=$(( $(date +%s) - START ))
unset ROGUE_FLUSH_WAIT_ITERS
assert_eq "$LAST_RC" "0" "unflushed agentStop fails open (exit 0)"
if [ "$ELAPSED" -le 3 ]; then echo "  ok: bounded wait honored (${ELAPSED}s), did not hang"; else echo "FAIL [Case 13]: waited ${ELAPSED}s (unbounded?)" >&2; exit 1; fi
rm -rf "$TDIR"
rm -rf "$TDIR"

# ── Case 14: subagent event is re-attributed to its parent session ─────────
# A subagent's own preToolUse arrives with sessionId = the model tool-call id
# (toolu_…/call_…). The dispatcher must resolve the parent from the parent
# transcript's subagent.started line, rewrite the POST body's sessionId to the
# parent, and send the tag as the x-rogue-agent-id / x-rogue-agent-name-b64
# HEADERS (the same pair the Antigravity dispatcher emits) — never as body fields.
SDIR="$(mktemp -d)"
PARENT="11111111-2222-3333-4444-555555555555"
mkdir -p "$SDIR/$PARENT"
printf '%s\n' \
  '{"type":"user.message","timestamp":"2026-07-20T09:00:00.000Z","data":{"content":"go"}}' \
  '{"type":"subagent.started","agentId":"toolu_bdrk_TESTSUB","timestamp":"2026-07-20T09:00:01.000Z","data":{"agentName":"task","agentDisplayName":"Task Agent","toolCallId":"toolu_bdrk_TESTSUB"}}' \
  > "$SDIR/$PARENT/events.jsonl"
restart_mock '{}'
export ROGUE_COPILOT_STATE_DIR="$SDIR"
export ROGUE_SUBAGENT_RESOLVE_ITERS=3
# toolArgs is arbitrary tool input, so it carries the two values a JSON round-trip
# would rewrite: an integer wider than a double and a float that does not survive
# reformatting. This payload is what Case 14a below diffs against.
SUB_STDIN='{"sessionId":"toolu_bdrk_TESTSUB","toolName":"bash","toolArgs":{"command":"ls","id":12345678901234567890,"ratio":0.10}}'
set +e; run_dispatcher preToolUse "$SUB_STDIN"; LAST_RC=$?; set -e
unset ROGUE_COPILOT_STATE_DIR ROGUE_SUBAGENT_RESOLVE_ITERS
assert_eq "$LAST_RC" "0" "re-attributed subagent event exits 0"
assert_eq "$(posted_field sessionId)" "$PARENT" "subagent event sessionId rewritten to the parent session"
assert_header "x-rogue-agent-id" "toolu_bdrk_TESTSUB" "x-rogue-agent-id carries the real subagent id"
assert_eq "$(header_value x-rogue-agent-name-b64 | base64 -d)" "Task Agent" \
  "x-rogue-agent-name-b64 decodes to the display name"
# The tag must NOT also ride in the body: those fields are the legacy transport.
has=$(posted_body | python3 -c 'import json,sys; d=json.load(sys.stdin); print("agentId" in d or "agentNameB64" in d)')
assert_eq "$has" "False" "no agentId/agentNameB64 body fields (the tag is header-borne)"

# ── Case 14a: the POSTed body differs from stdin ONLY in sessionId ──────────
# The whole point of the header migration: the re-attribution sed is the one and
# only edit, so the vendor's own bytes (whitespace, escaping, number formatting
# inside toolArgs) reach the backend untouched. A re-serializing tagger would
# rewrite 12345678901234567890 and 0.10 here and fail this byte comparison.
EXPECTED_BODY="$(printf '%s' "$SUB_STDIN" | sed "s/toolu_bdrk_TESTSUB/$PARENT/")"
assert_eq "$(posted_body)" "$EXPECTED_BODY" \
  "re-attributed subagent body differs from the vendor's stdin only in sessionId"
rm -rf "$SDIR"

# ── Case 14b: a display name with " and \ survives as base64 ────────────────
# A display name is arbitrary vendor text, and HTTP header values are ISO-8859-1
# by spec — which is why the name is base64-encoded rather than sent raw. (It is
# seeded through the submap cache because the transcript scraper's "[^"]*" regex
# can never yield a quote.)
NASTY_NAME='Task "Agent" \ v2'
SUB_ID="call_NASTYNAME"
SEED_VALUE="$(printf '%s\n%s' "$PARENT" "$NASTY_NAME")"

restart_mock '{}'
set +e
SEED_SUBMAP_ID="$SUB_ID" SEED_SUBMAP_VALUE="$SEED_VALUE" \
  run_dispatcher preToolUse "{\"sessionId\":\"$SUB_ID\",\"toolName\":\"bash\",\"toolArgs\":{\"command\":\"ls\"}}"
LAST_RC=$?; set -e
assert_eq "$LAST_RC" "0" "subagent event with a quoted display name exits 0"
assert_header "x-rogue-agent-id" "$SUB_ID" "x-rogue-agent-id set for the seeded subagent"
assert_eq "$(header_value x-rogue-agent-name-b64 | base64 -d)" "$NASTY_NAME" \
  'x-rogue-agent-name-b64 round-trips a name with " and \'
assert_eq "$(posted_body)" "{\"sessionId\":\"$PARENT\",\"toolName\":\"bash\",\"toolArgs\":{\"command\":\"ls\"}}" \
  "body carries only the sessionId rewrite, whatever the name contains"

# ── Case 14c: an UNKNOWN display name omits the name header entirely ────────
# Never sent empty: the id header alone still attributes the rows.
restart_mock '{}'
set +e
SEED_SUBMAP_ID="$SUB_ID" SEED_SUBMAP_VALUE="$PARENT" \
  run_dispatcher preToolUse "{\"sessionId\":\"$SUB_ID\",\"toolName\":\"bash\"}"
LAST_RC=$?; set -e
assert_eq "$LAST_RC" "0" "nameless subagent event exits 0"
assert_header "x-rogue-agent-id" "$SUB_ID" "x-rogue-agent-id still set without a name"
assert_no_header "x-rogue-agent-name-b64" "no x-rogue-agent-name-b64 when the display name is unknown"

# ── Case 14d: a subagent agentStop carries the tag AND the tail ─────────────
# The headers are independent of the body enrichment, so a re-attributed stop
# event ships the two agent headers and a transcriptTailB64 body.
SDIR="$(mktemp -d)"
mkdir -p "$SDIR/$PARENT"
printf '%s\n' \
  '{"type":"subagent.started","agentId":"toolu_bdrk_STOPSUB","timestamp":"2026-07-20T09:00:01.000Z","data":{"agentDisplayName":"Stop Agent","toolCallId":"toolu_bdrk_STOPSUB"}}' \
  '{"type":"assistant.message","timestamp":"2026-07-20T09:00:02.000Z","agentId":"toolu_bdrk_STOPSUB","data":{"content":"SUB final"}}' \
  '{"type":"assistant.turn_end","timestamp":"2026-07-20T09:00:02.100Z"}' \
  > "$SDIR/$PARENT/events.jsonl"
restart_mock '{}'
export ROGUE_COPILOT_STATE_DIR="$SDIR"
export ROGUE_SUBAGENT_RESOLVE_ITERS=3
set +e
run_dispatcher agentStop "$(printf '{"sessionId":"toolu_bdrk_STOPSUB","timestamp":1784538002000,"transcriptPath":"%s"}' "$SDIR/$PARENT/events.jsonl")"
LAST_RC=$?; set -e
unset ROGUE_COPILOT_STATE_DIR ROGUE_SUBAGENT_RESOLVE_ITERS
assert_eq "$LAST_RC" "0" "re-attributed agentStop exits 0"
both=$(posted_body | python3 -c 'import json,sys; d=json.load(sys.stdin); print("agentId" not in d and "transcriptTailB64" in d and d.get("sessionId")==sys.argv[1])' "$PARENT")
assert_eq "$both" "True" "re-attributed agentStop body is valid JSON with the tail and no body tag"
assert_header "x-rogue-agent-id" "toolu_bdrk_STOPSUB" "re-attributed agentStop carries the id header"
assert_eq "$(header_value x-rogue-agent-name-b64 | base64 -d)" "Stop Agent" \
  "re-attributed agentStop carries the display name header"
rm -rf "$SDIR"

# ── Case 15: unresolvable subagent id → fail-open (orphaned, never worse) ────
# No parent transcript names this id: the dispatcher must NOT hang and must POST
# the body unchanged (original sessionId), with no tag at all.
SDIR="$(mktemp -d)"   # empty state dir
restart_mock '{}'
export ROGUE_COPILOT_STATE_DIR="$SDIR"
export ROGUE_SUBAGENT_RESOLVE_ITERS=2
START=$(date +%s)
set +e; run_dispatcher preToolUse '{"sessionId":"call_UNKNOWNSUB","toolName":"bash","toolArgs":{"command":"ls"}}'; LAST_RC=$?; set -e
ELAPSED=$(( $(date +%s) - START ))
unset ROGUE_COPILOT_STATE_DIR ROGUE_SUBAGENT_RESOLVE_ITERS
assert_eq "$LAST_RC" "0" "unresolved subagent event exits 0"
assert_eq "$(posted_body)" '{"sessionId":"call_UNKNOWNSUB","toolName":"bash","toolArgs":{"command":"ls"}}' \
  "unresolved subagent event POSTs the body unchanged (fail-open, no tag)"
assert_no_header "x-rogue-agent-id"        "no x-rogue-agent-id header when unresolved"
assert_no_header "x-rogue-agent-name-b64"  "no x-rogue-agent-name-b64 header when unresolved"
if [ "$ELAPSED" -le 3 ]; then echo "  ok: bounded resolve wait honored (${ELAPSED}s)"; else echo "FAIL [Case 15]: waited ${ELAPSED}s (unbounded?)" >&2; exit 1; fi
rm -rf "$SDIR"

# ── Case 16: a main-agent (UUID) session is never tagged ────────────────────
# The tag exists only to repair a re-attributed subagent event; an ordinary event
# must stay a verbatim relay with neither agent header present.
restart_mock '{}'
set +e; run_dispatcher preToolUse '{"sessionId":"11111111-2222-3333-4444-555555555555","toolName":"bash"}'; LAST_RC=$?; set -e
assert_eq "$LAST_RC" "0" "main-agent event exits 0"
assert_eq "$(posted_body)" '{"sessionId":"11111111-2222-3333-4444-555555555555","toolName":"bash"}' \
  "main-agent event body is untouched"
assert_no_header "x-rogue-agent-id"       "no x-rogue-agent-id header on a main-agent event"
assert_no_header "x-rogue-agent-name-b64" "no x-rogue-agent-name-b64 header on a main-agent event"

echo
echo "All copilot hook.sh tests passed (SH=$SH)."
