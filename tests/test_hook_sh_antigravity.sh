#!/usr/bin/env bash
# tests/test_hook_sh_antigravity.sh — end-to-end for the Antigravity POSIX-sh
# dispatcher (plugins/antigravity/scripts/hook.sh): env file → hook.sh → mock
# server → stdout. Holds the dispatcher to the verbatim-relay + header +
# per-event fail-open + Git-Bash-stand-down + PreInvocation-heartbeat contract.
#
# Antigravity CLI runs the `sh` command on macOS/Linux; override with
# TEST_SH=dash to exercise strict POSIX and catch bashisms.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO/plugins/antigravity/scripts/hook.sh"
ACTOR="$REPO/plugins/antigravity/scripts/actor.sh"
INSTALL_ID="$REPO/plugins/antigravity/scripts/install-id.sh"
SH="${TEST_SH:-sh}"

PORT=$((RANDOM % 10000 + 30000))
HEADERS_FILE="$(mktemp)"
ENV_FILE="$(mktemp)"
OUT_FILE="$(mktemp)"

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

# Run with a clean HOME holding our env file. Clears ROGUE_* from the process
# env so only the file drives resolution (process env would otherwise win).
# Writes stdout to $OUT_FILE and RETURNS the dispatcher's exit code (command
# substitution would otherwise hide it in a subshell).
run_dispatcher() {
  local tmp_home rc
  tmp_home="$(mktemp -d)"
  cp "$ENV_FILE" "$tmp_home/.rogue-env"
  set +e
  HOME="$tmp_home" \
    ROGUE_API_KEY='' ROGUE_ACTOR_EMAIL='' ROGUE_ACTOR_NAME='' ROGUE_BASE_URL='' \
    ROGUE_LOG_FILE="$tmp_home/hook.log" \
    ROGUE_FORCE_UNAME="${ROGUE_FORCE_UNAME:-}" \
    ROGUE_ANTIGRAVITY_BRAIN_DIR="${ROGUE_ANTIGRAVITY_BRAIN_DIR:-}" \
    ROGUE_ANTIGRAVITY_SUBMAP_DIR="${ROGUE_ANTIGRAVITY_SUBMAP_DIR:-}" \
    ROGUE_ANTIGRAVITY_NODE="${ROGUE_ANTIGRAVITY_NODE:-}" \
    ROGUE_ANTIGRAVITY_DB_PROMPT="${ROGUE_ANTIGRAVITY_DB_PROMPT:-}" \
    ROGUE_ANTIGRAVITY_DBPROMPT_DIR="${ROGUE_ANTIGRAVITY_DBPROMPT_DIR:-}" \
    "$SH" "$HOOK" "$1" <<< "$2" > "$OUT_FILE"
  rc=$?
  set -e
  rm -rf "$tmp_home"
  return $rc
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

stop_mock() {
  [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null || true
  wait "$MOCK_PID" 2>/dev/null || true
  MOCK_PID=""
}

assert_eq() {
  if [ "$1" != "$2" ]; then echo "FAIL [$3]: expected <$2> but got <$1>" >&2; exit 1; fi
  echo "  ok: $3"
}

# The agent tag rides in HEADERS (`x-rogue-agent-id` + `x-rogue-agent-name-b64`),
# never in the body — the POSTed event must stay byte-identical to Antigravity's,
# so the stored raw payload is the vendor's event and nothing we synthesised.
agent_tag() {   # -> "<agentId> <decoded name>" or "-" when untagged
  python3 -c '
import base64, json, sys
d = json.load(open(sys.argv[1]))
h = d["headers"]
if "x-rogue-agent-id" not in h: print("-"); raise SystemExit
nb64 = h.get("x-rogue-agent-name-b64", "")
name = base64.b64decode(nb64).decode("utf-8") if nb64 else ""
print(h["x-rogue-agent-id"], name)
# The body must carry no tag of ours.
body = json.loads(d["body"])
assert "agentId" not in body and "agentNameB64" not in body, "agent tag leaked into the body"' "$HEADERS_FILE"
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

# ── Case 1: PreToolUse deny relayed verbatim + headers + path + exit 0 ─────
start_mock '{"decision":"deny","reason":"x"}'
set +e; run_dispatcher PreToolUse '{"toolName":"bash","toolArgs":{"command":"rm -rf /"}}'; LAST_RC=$?; set -e
out=$(cat "$OUT_FILE")
assert_eq "$out" '{"decision":"deny","reason":"x"}' "PreToolUse deny relayed verbatim"
assert_eq "$LAST_RC" "0" "PreToolUse deny still exits 0"
assert_header "x-rogue-event"       "PreToolUse"       "x-rogue-event is the verbatim Antigravity event name"
assert_header "x-rogue-api-key"     "test-key"         "x-rogue-api-key forwarded"
assert_header "x-rogue-actor-email" "test@example.com" "x-rogue-actor-email forwarded"
assert_header "x-rogue-actor-name"  "Test User"        "x-rogue-actor-name forwarded (with space)"
assert_no_header "x-rogue-source"   "no x-rogue-source header (cursor-only)"
# Fleet-liveness trio: the same host/version/agent the heartbeat sends, on EVERY
# event, so the roster row is refreshed by ordinary traffic and not only at the
# session's first PreInvocation. This payload has no transcriptPath, so the
# surface falls back to the 2.0 app, matching the backend's own default.
assert_header "x-rogue-agent"       "antigravity"      "x-rogue-agent falls back to the 2.0 surface"
assert_header_present "x-rogue-host"    "x-rogue-host sent on every event"
assert_header_present "x-rogue-version" "x-rogue-version sent on every event"
path=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["path"])' "$HEADERS_FILE")
assert_eq "$path" "/api/v1/hooks/antigravity" "POST path is /api/v1/hooks/antigravity"
body=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["body"])' "$HEADERS_FILE")
assert_eq "$body" '{"toolName":"bash","toolArgs":{"command":"rm -rf /"}}' "request body passed through unchanged"

# ── Case 2: missing ROGUE_API_KEY on PreToolUse → {"decision":"allow"} ──────
TMP_HOME="$(mktemp -d)"
set +e
out=$(HOME="$TMP_HOME" ROGUE_API_KEY='' ROGUE_LOG_FILE="$TMP_HOME/h.log" "$SH" "$HOOK" PreToolUse <<< '{}')
rc=$?
set -e
rm -rf "$TMP_HOME"
assert_eq "$out" '{"decision":"allow"}' "unconfigured PreToolUse fails open to decision:allow"
assert_eq "$rc" "0" "unconfigured PreToolUse exits 0"

# ── Case 3: missing key on PostToolUse → {} ─────────────────────────────────
TMP_HOME="$(mktemp -d)"
set +e
out=$(HOME="$TMP_HOME" ROGUE_API_KEY='' ROGUE_LOG_FILE="$TMP_HOME/h.log" "$SH" "$HOOK" PostToolUse <<< '{}')
rc=$?
set -e
rm -rf "$TMP_HOME"
assert_eq "$out" "{}" "unconfigured PostToolUse fails open to {}"
assert_eq "$rc" "0" "unconfigured PostToolUse exits 0"

# ── Case 4: non-200 on PreToolUse → {"decision":"allow"} ───────────────────
restart_mock '{"decision":"deny"}' 500
set +e; run_dispatcher PreToolUse '{"toolName":"bash"}'; LAST_RC=$?; set -e
out=$(cat "$OUT_FILE")
assert_eq "$out" '{"decision":"allow"}' "non-200 PreToolUse fails open to decision:allow"
assert_eq "$LAST_RC" "0" "non-200 PreToolUse exits 0"

# ── Case 5: unreachable server on PreToolUse → {"decision":"allow"} ────────
stop_mock
set +e; run_dispatcher PreToolUse '{"toolName":"bash"}'; LAST_RC=$?; set -e
out=$(cat "$OUT_FILE")
assert_eq "$out" '{"decision":"allow"}' "unreachable server PreToolUse fails open to decision:allow"
assert_eq "$LAST_RC" "0" "unreachable server PreToolUse exits 0"

# ── Case 6: Git Bash stand-down (ROGUE_FORCE_UNAME=MINGW64) → EMPTY stdout ──
set +e
out=$(ROGUE_FORCE_UNAME=MINGW64 "$SH" "$HOOK" PreToolUse <<< '{}')
rc=$?
set -e
assert_eq "$out" "" "Git Bash stand-down emits EMPTY stdout (no decision contributed)"
assert_eq "$rc" "0" "Git Bash stand-down exits 0"

# ── Case 7: PreInvocation with invocationNum:0 → heartbeat.sh invoked ──────
# hook.sh self-locates PLUGIN_ROOT from $0 (dirname of the invoked path), so to
# assert the heartbeat launch without depending on (or clobbering) the real
# heartbeat.sh — owned by a concurrent task and not guaranteed to exist yet —
# stage a throwaway plugin root: copy the hook.sh under test + the real
# actor.sh into <tmp>/scripts/, plus a STUB heartbeat.sh that just touches a
# marker file. Invoking hook.sh via that path makes PLUGIN_ROOT resolve to the
# tmp root, so "${PLUGIN_ROOT}/scripts/heartbeat.sh" hits our stub.
restart_mock '{}'
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/scripts"
cp "$HOOK" "$STAGE/scripts/hook.sh"
cp "$ACTOR" "$STAGE/scripts/actor.sh"
cp "$INSTALL_ID" "$STAGE/scripts/install-id.sh"
MARKER="$STAGE/heartbeat-fired"
# The stub records BOTH arguments: the heartbeat is told which surface fired it
# (three products share one install and only the hook can tell them apart, from the
# event's transcriptPath) AND which trigger, since a per-turn Stop beacon is
# throttled where a new conversation's is not.
cat > "$STAGE/scripts/heartbeat.sh" <<EOF
#!/bin/sh
printf '%s|%s' "\$1" "\$2" > "$MARKER"
EOF
chmod +x "$STAGE/scripts/hook.sh" "$STAGE/scripts/heartbeat.sh"

# Run the staged hook.sh (PLUGIN_ROOT resolves to $STAGE) and echo its exit code.
# The hook log goes to a path OUTSIDE the per-run sandbox, so an assertion can read
# the line back after the run (the sandbox is deleted below). Truncated per call so
# each case reads only its own output.
LAST_LOG="$(mktemp -d)/antigravity.log"

run_staged() {
  local tmp_home rc
  tmp_home="$(mktemp -d)"
  cp "$ENV_FILE" "$tmp_home/.rogue-env"
  : > "$LAST_LOG"
  set +e
  HOME="$tmp_home" \
    ROGUE_API_KEY='' ROGUE_ACTOR_EMAIL='' ROGUE_ACTOR_NAME='' ROGUE_BASE_URL='' \
    ROGUE_LOG_FILE="$LAST_LOG" \
    "$SH" "$STAGE/scripts/hook.sh" "$1" <<< "$2" > "$OUT_FILE"
  rc=$?
  set -e
  rm -rf "$tmp_home"
  return $rc
}

# A NEW CONVERSATION is invocationNum 0 AND initialNumSteps <= 1. invocationNum
# alone is not per-session - it resets on every prompt - so gating on it sent an
# unthrottled beacon per turn AND shipped the log a turn late, since PreInvocation
# runs before the turn's own transcript rows exist.
set +e; run_staged PreInvocation '{"invocationNum":0,"initialNumSteps":0}'; rc=$?; set -e
assert_eq "$rc" "0" "PreInvocation invocationNum:0 exits 0"
# heartbeat.sh is launched via a backgrounded `nohup ... &`; give it a moment
# to actually run before asserting the marker.
for _ in $(seq 1 30); do
  [ -f "$MARKER" ] && break
  sleep 0.1
done
if [ -f "$MARKER" ]; then
  echo "  ok: a new conversation's PreInvocation launches heartbeat.sh"
else
  echo "FAIL [heartbeat launch]: marker file $MARKER was never created" >&2
  exit 1
fi
# No transcriptPath: the launcher passes the SAME fallback the event headers carry
# (the 2.0 app), never an empty surface. Handing the heartbeat nothing let it sniff
# the filesystem and pick antigravity_cli whenever `agy` was installed, so one
# first-PreInvocation wrote `antigravity` from the event and `antigravity_cli` from
# the heartbeat: two roster rows for one install.
assert_eq "$(cat "$MARKER")" "antigravity|SessionStart" \
  "no transcriptPath -> heartbeat gets the headers' fallback surface, trigger SessionStart"

# initialNumSteps 1: the pending prompt has already been recorded as a step, so this
# is still the start of a conversation.
rm -f "$MARKER"
restart_mock '{}'
set +e; run_staged PreInvocation '{"invocationNum":0,"initialNumSteps":1}'; rc=$?; set -e
assert_eq "$rc" "0" "initialNumSteps:1 exits 0"
for _ in $(seq 1 30); do [ -s "$MARKER" ] && break; sleep 0.1; done
assert_eq "$(cat "$MARKER" 2>/dev/null)" "antigravity|SessionStart" "initialNumSteps:1 is still a session start"

# A CONTINUATION (invocationNum 0 but steps already recorded, e.g. `agy -c`) fires
# NOTHING here: its Stop covers it, and treating it as a session start would hand an
# unthrottled beacon to every resumed conversation.
rm -f "$MARKER"
restart_mock '{}'
set +e; run_staged PreInvocation '{"invocationNum":0,"initialNumSteps":18}'; rc=$?; set -e
assert_eq "$rc" "0" "a continuation's PreInvocation exits 0"
sleep 0.5
if [ -f "$MARKER" ]; then
  echo "FAIL [heartbeat]: a continuation invocation fired a SessionStart beacon" >&2
  exit 1
fi
echo "  ok: invocationNum:0 with steps already recorded fires no heartbeat"

# Stop is the PER-TURN trigger, and it is what makes a long session keep reporting:
# on PreInvocation alone the log shipper riding inside heartbeat.sh only ever saw
# turns 1..N-1, because PreInvocation runs before turn N's rows are written.
rm -f "$MARKER"
restart_mock '{}'
set +e; run_staged Stop '{"executionNum":0,"terminationReason":"NO_TOOL_CALL"}'; rc=$?; set -e
assert_eq "$rc" "0" "Stop exits 0"
for _ in $(seq 1 30); do [ -s "$MARKER" ] && break; sleep 0.1; done
assert_eq "$(cat "$MARKER" 2>/dev/null)" "antigravity|Stop" "Stop launches the heartbeat with the Stop trigger"
rm -f "$MARKER"

# The surface rides the transcriptPath: without it every surface on a machine
# with the CLI installed collapses into one antigravity_cli roster row.
for surface in antigravity_cli antigravity_ide antigravity; do
  rm -f "$MARKER"
  case "$surface" in
    antigravity_cli) dir=antigravity-cli ;;
    antigravity_ide) dir=antigravity-ide ;;
    *)               dir=antigravity ;;
  esac
  restart_mock '{}'
  set +e
  run_staged PreInvocation "$(printf '{"invocationNum":0,"initialNumSteps":0,"transcriptPath":"/h/.gemini/%s/brain/c/x/transcript_full.jsonl"}' "$dir")"
  rc=$?; set -e
  assert_eq "$rc" "0" "$surface heartbeat exits 0"
  for _ in $(seq 1 30); do [ -s "$MARKER" ] && break; sleep 0.1; done
  assert_eq "$(cat "$MARKER" 2>/dev/null)" "$surface|SessionStart" "heartbeat is told the $surface surface"
  # The SAME resolution stamps the log line. One value, two consumers: if these
  # ever disagree, a line and the roster row for one session name different
  # surfaces - worse than the line naming none. (The unconfigured path has no
  # payload to resolve from and correctly emits no token at all; that case is
  # covered in tests/test_hook_logs.sh.)
  logged=$(sed -n 's/.*provider=antigravity surface=\([a-z_]*\) event=.*/\1/p' \
             "$LAST_LOG" 2>/dev/null | tail -1)
  assert_eq "$logged" "$surface" "the log line is stamped surface=$surface"
done
rm -rf "$STAGE"

# ── Case 8: PreInvocation with invocationNum != 0 → heartbeat NOT invoked ──
restart_mock '{}'
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/scripts"
cp "$HOOK" "$STAGE/scripts/hook.sh"
cp "$ACTOR" "$STAGE/scripts/actor.sh"
cp "$INSTALL_ID" "$STAGE/scripts/install-id.sh"
MARKER="$STAGE/heartbeat-fired"
cat > "$STAGE/scripts/heartbeat.sh" <<EOF
#!/bin/sh
touch "$MARKER"
EOF
chmod +x "$STAGE/scripts/hook.sh" "$STAGE/scripts/heartbeat.sh"

tmp_home="$(mktemp -d)"
cp "$ENV_FILE" "$tmp_home/.rogue-env"
set +e
HOME="$tmp_home" \
  ROGUE_API_KEY='' ROGUE_ACTOR_EMAIL='' ROGUE_ACTOR_NAME='' ROGUE_BASE_URL='' \
  ROGUE_LOG_FILE="$tmp_home/hook.log" \
  "$SH" "$STAGE/scripts/hook.sh" PreInvocation <<< '{"invocationNum":3}' > "$OUT_FILE"
rc=$?
set -e
rm -rf "$tmp_home"
assert_eq "$rc" "0" "PreInvocation invocationNum:3 exits 0"
sleep 0.3
if [ -f "$MARKER" ]; then
  echo "FAIL [heartbeat non-launch]: marker file was created for invocationNum!=0" >&2
  exit 1
else
  echo "  ok: PreInvocation invocationNum!=0 does not launch heartbeat.sh"
fi
rm -rf "$STAGE"

# ── Case 9: PreInvocation transcript-tail enrichment (augment_with_transcript) ─
# Fixture rows use the real transcript_full.jsonl schema (source/type/step_index,
# no `role` key) — see plugins/antigravity/CLAUDE.md.
TDIR="$(mktemp -d)"
printf '%s\n' \
  '{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","created_at":"2026-07-20T09:00:00Z","content":"<USER_REQUEST>\nhi\n</USER_REQUEST>"}' \
  '{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"2026-07-20T09:00:02Z","content":"ANTIGRAVITY final"}' \
  > "$TDIR/transcript.jsonl"
restart_mock '{}'
PAYLOAD=$(printf '{"invocationNum":1,"transcriptPath":"%s"}' "$TDIR/transcript.jsonl")
set +e; run_dispatcher PreInvocation "$PAYLOAD"; LAST_RC=$?; set -e
assert_eq "$LAST_RC" "0" "PreInvocation transcript enrichment exits 0"
body=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["body"])' "$HEADERS_FILE")
valid=$(printf '%s' "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("transcriptTailB64" in d)')
assert_eq "$valid" "True" "PreInvocation body is valid JSON with transcriptTailB64"
b64=$(printf '%s' "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("transcriptTailB64",""))')
decoded=$(python3 -c 'import base64,sys; print(base64.b64decode(sys.argv[1]).decode("utf-8","replace"))' "$b64")
case "$decoded" in
  *'ANTIGRAVITY final'*) echo "  ok: transcriptTailB64 decodes to the transcript" ;;
  *) echo "FAIL [PreInvocation tail decode]: <$decoded>" >&2; exit 1 ;;
esac
rm -rf "$TDIR"

# ── Case 10: the tool events do NOT get transcript enrichment ──────────────
# PreToolUse: the call's args are already inline and the result row does not
# exist yet. PostToolUse: Antigravity IGNORES this event's output entirely (its
# contract accepts only `{}`; deny / injectSteps / terminationBehavior were all
# verified no-ops), so a finding raised on the tool result here could not stop
# it reaching the model. Tool output is instead read from the transcript on the
# following PostInvocation, which CAN terminate the loop first. Enriching either
# tool event would pay the flush wait + a ~350KB body on every tool call for
# nothing. See plugins/antigravity/CLAUDE.md.
TDIR="$(mktemp -d)"
printf '%s\n' '{"step_index":3,"source":"MODEL","type":"RUN_COMMAND","content":"should not appear"}' > "$TDIR/transcript.jsonl"
for ev in PreToolUse PostToolUse; do
  restart_mock '{}'
  PAYLOAD=$(printf '{"stepIdx":3,"toolCall":{"name":"run_command","args":{"CommandLine":"id"}},"transcriptPath":"%s"}' "$TDIR/transcript.jsonl")
  set +e; run_dispatcher "$ev" "$PAYLOAD"; LAST_RC=$?; set -e
  assert_eq "$LAST_RC" "0" "$ev with transcriptPath still exits 0"
  body=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["body"])' "$HEADERS_FILE")
  case "$body" in
    *transcriptTailB64*) echo "FAIL [$ev tail]: $ev must not be enriched; body=<$body>" >&2; exit 1 ;;
    *) echo "  ok: $ev body is not enriched with transcript tail" ;;
  esac
done
rm -rf "$TDIR"

# ── Case 12: subagent re-attribution ───────────────────────────────────────
# A subagent's events arrive with its OWN conversationId and no parent
# reference, so persisted verbatim they orphan into a separate audit session.
# The dispatcher resolves the parent from the INVOKE_SUBAGENT row in some
# parent transcript (the parent id IS that transcript's directory name),
# rewrites conversationId, and tags the event with the agentId/agentNameB64 body
# headers the backend's enrichFromHeaders turns into subagent_id/subagent_name.
PARENT="11111111-1111-1111-1111-111111111111"
CHILD="22222222-2222-2222-2222-222222222222"
OTHER="33333333-3333-3333-3333-333333333333"
TB="$(mktemp -d)"
mkdir -p "$TB/$PARENT/.system_generated/logs" "$TB/$PARENT/.system_generated/messages" \
         "$TB/$OTHER/.system_generated/logs"
# The spawn record: ids appear inside the row's JSON-string content, so the
# quotes around them are escaped — the dispatcher must not rely on bare quoting.
printf '%s\n' \
  '{"step_index":20,"source":"MODEL","type":"PLANNER_RESPONSE","tool_calls":[{"name":"invoke_subagent","args":{"Subagents":[{"Role":"Poet for AAPL","TypeName":"Poet"}]}}]}' \
  "{\"step_index\":21,\"source\":\"MODEL\",\"type\":\"INVOKE_SUBAGENT\",\"content\":\"Created the following subagents:\\n{\\n  \\\"conversationId\\\":  \\\"$CHILD\\\"\\n}\"}" \
  > "$TB/$PARENT/.system_generated/logs/transcript_full.jsonl"
printf '{"sender": "%s", "recipient": "%s", "renderDetails": {"messageTitle": "Message from Poet for AAPL (Poet)"}}\n' \
  "$CHILD" "$PARENT" > "$TB/$PARENT/.system_generated/messages/msg1.json"
# A DIFFERENT conversation that merely mentions the child id in its
# CONVERSATION_HISTORY summary — must never be read as a parent link.
printf '%s\n' \
  "{\"step_index\":0,\"source\":\"SYSTEM\",\"type\":\"CONVERSATION_HISTORY\",\"content\":\"## Conversation $CHILD: Poems\"}" \
  > "$TB/$OTHER/.system_generated/logs/transcript_full.jsonl"

TSM="$(mktemp -d)"
restart_mock '{}'
PAYLOAD=$(printf '{"conversationId":"%s","invocationNum":1,"initialNumSteps":1}' "$CHILD")
set +e
ROGUE_ANTIGRAVITY_BRAIN_DIR="$TB" ROGUE_ANTIGRAVITY_SUBMAP_DIR="$TSM" \
  run_dispatcher PreInvocation "$PAYLOAD"; LAST_RC=$?
set -e
assert_eq "$LAST_RC" "0" "subagent re-attribution exits 0"
got=$(python3 -c 'import json,sys; print(json.loads(json.load(open(sys.argv[1]))["body"])["conversationId"])' "$HEADERS_FILE")
assert_eq "$got" "$PARENT" "subagent conversationId is rewritten to the parent"
assert_eq "$(agent_tag)" "$CHILD Poet for AAPL" "headers carry the agent id + base64 name, body untouched"
assert_eq "$(sed -n '1p' "$TSM/$CHILD")" "$PARENT" "parent is cached for the subagent"

# ── Case 13: a main-agent conversation is untouched and sends no headers ────
# Its id is in no INVOKE_SUBAGENT row. Verdict is cached as 'main' so an
# ordinary conversation scans once, not on all ~18 events of every turn.
restart_mock '{}'
PAYLOAD=$(printf '{"conversationId":"%s","invocationNum":1,"initialNumSteps":1}' "$PARENT")
set +e
ROGUE_ANTIGRAVITY_BRAIN_DIR="$TB" ROGUE_ANTIGRAVITY_SUBMAP_DIR="$TSM" \
  run_dispatcher PreInvocation "$PAYLOAD"; LAST_RC=$?
set -e
assert_eq "$LAST_RC" "0" "main-agent event exits 0"
got=$(python3 -c 'import json,sys; print(json.loads(json.load(open(sys.argv[1]))["body"])["conversationId"])' "$HEADERS_FILE")
assert_eq "$got" "$PARENT" "main-agent conversationId is left alone"
assert_eq "$(agent_tag)" "-" "a main-agent event carries no agent headers at all"
assert_eq "$(cat "$TSM/$PARENT")" "main" "main-agent verdict is cached"

# ── Case 14: a CONVERSATION_HISTORY mention is not a parent link ────────────
# $OTHER's transcript names $CHILD but has no INVOKE_SUBAGENT row, and $OTHER
# itself was never spawned — so it must resolve to 'main', not to a parent.
TSM2="$(mktemp -d)"
restart_mock '{}'
PAYLOAD=$(printf '{"conversationId":"%s","invocationNum":1}' "$OTHER")
set +e
ROGUE_ANTIGRAVITY_BRAIN_DIR="$TB" ROGUE_ANTIGRAVITY_SUBMAP_DIR="$TSM2" \
  run_dispatcher PreInvocation "$PAYLOAD"; LAST_RC=$?
set -e
assert_eq "$(cat "$TSM2/$OTHER")" "main" "a CONVERSATION_HISTORY mention is not treated as a spawn"
assert_eq "$(agent_tag)" "-" "no agent tag from a history mention"

# ── Case 15: re-attribution survives alongside transcript enrichment ────────
# Both stdin mutations apply to the same event; the rewrite must happen BEFORE
# the tail is appended (augment_with_transcript re-closes the JSON by hand).
mkdir -p "$TB/$CHILD/.system_generated/logs"
printf '%s\n' '{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"<USER_REQUEST>\nAAPL\n</USER_REQUEST>"}' \
  > "$TB/$CHILD/.system_generated/logs/transcript_full.jsonl"
restart_mock '{}'
PAYLOAD=$(printf '{"conversationId":"%s","invocationNum":1,"initialNumSteps":1,"transcriptPath":"%s"}' \
  "$CHILD" "$TB/$CHILD/.system_generated/logs/transcript_full.jsonl")
set +e
ROGUE_ANTIGRAVITY_BRAIN_DIR="$TB" ROGUE_ANTIGRAVITY_SUBMAP_DIR="$TSM" \
  run_dispatcher PreInvocation "$PAYLOAD"; LAST_RC=$?
set -e
assert_eq "$LAST_RC" "0" "re-attribution + enrichment exits 0"
both=$(python3 -c '
import json,sys,base64
b=json.loads(json.load(open(sys.argv[1]))["body"])
print(b["conversationId"], "transcriptTailB64" in b, "AAPL" in base64.b64decode(b.get("transcriptTailB64","")).decode("utf-8","replace"))
' "$HEADERS_FILE")
assert_eq "$both" "$PARENT True True" "body has the parent id AND a decodable tail"

# ── Case 15b: the brain dir is derived from the event, not assumed to be the CLI's
# Each product keeps its own brain dir. With ROGUE_ANTIGRAVITY_BRAIN_DIR unset the
# dispatcher must read it off the event's own transcriptPath, or a subagent
# spawned in the IDE / 2.0 app resolves no parent and orphans into its own
# session — the CLI-only default never sees it.
BB="$(mktemp -d)"
mkdir -p "$BB/antigravity-ide/brain/$PARENT/.system_generated/logs" \
         "$BB/antigravity-ide/brain/$CHILD/.system_generated/logs"
cp "$TB/$PARENT/.system_generated/logs/transcript_full.jsonl" \
   "$BB/antigravity-ide/brain/$PARENT/.system_generated/logs/transcript_full.jsonl"
printf '%s\n' '{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","content":"child"}' \
  > "$BB/antigravity-ide/brain/$CHILD/.system_generated/logs/transcript_full.jsonl"
TSM3="$(mktemp -d)"
restart_mock '{}'
PAYLOAD=$(printf '{"conversationId":"%s","invocationNum":1,"initialNumSteps":1,"transcriptPath":"%s"}' \
  "$CHILD" "$BB/antigravity-ide/brain/$CHILD/.system_generated/logs/transcript_full.jsonl")
set +e
ROGUE_ANTIGRAVITY_SUBMAP_DIR="$TSM3" run_dispatcher PreInvocation "$PAYLOAD"; LAST_RC=$?
set -e
assert_eq "$LAST_RC" "0" "brain dir from transcriptPath exits 0"
cid=$(python3 -c '
import json,sys
print(json.loads(json.load(open(sys.argv[1]))["body"])["conversationId"])' "$HEADERS_FILE")
assert_eq "$cid" "$PARENT" "a non-CLI surface subagent resolves its parent"
assert_eq "$(agent_tag)" "$CHILD Poet for AAPL" "and the tag names the subagent and its spawn-time Role"
rm -rf "$BB" "$TSM3"
rm -rf "$TB" "$TSM" "$TSM2"

# ── Case 16: enrichment survives every payload shape a serializer may emit ──
# The IDE surface posted 100% of its Pre/PostInvocation events with NO
# transcript while the 2.0 app and the CLI worked, so extraction is now held to
# the shapes that used to fail SILENTLY: pretty-printed (key and value on
# separate lines, which a per-line sed misses entirely) and a `\/`-escaped path
# (which fails every file test).
TDIR="$(mktemp -d)"
ROW='{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","content":"SHAPE final"}'
printf '%s\n' "$ROW" > "$TDIR/transcript_full.jsonl"

tail_decodes() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["body"])' "$HEADERS_FILE" | python3 -c '
import base64,json,sys
b=json.load(sys.stdin)
print("SHAPE final" in base64.b64decode(b.get("transcriptTailB64","")).decode("utf-8","replace"))
'
}

restart_mock '{}'
PAYLOAD=$(printf '{\n  "invocationNum": 1,\n  "transcriptPath":\n    "%s"\n}' "$TDIR/transcript_full.jsonl")
set +e; run_dispatcher PostInvocation "$PAYLOAD"; LAST_RC=$?; set -e
assert_eq "$LAST_RC" "0" "pretty-printed payload exits 0"
assert_eq "$(tail_decodes)" "True" "pretty-printed payload still gets the transcript tail"

restart_mock '{}'
PAYLOAD=$(printf '{"invocationNum":1,"transcriptPath":"%s"}' \
  "$(printf '%s' "$TDIR/transcript_full.jsonl" | sed 's|/|\\/|g')")
set +e; run_dispatcher PostInvocation "$PAYLOAD"; LAST_RC=$?; set -e
assert_eq "$LAST_RC" "0" "escaped-slash path exits 0"
assert_eq "$(tail_decodes)" "True" "an escaped transcriptPath still resolves"

# The IDE names transcript.jsonl, the CLI and 2.0 app name transcript_full.jsonl.
# A surface naming the one we cannot read falls back to its sibling.
restart_mock '{}'
PAYLOAD=$(printf '{"invocationNum":1,"transcriptPath":"%s"}' "$TDIR/transcript.jsonl")
set +e; ROGUE_TRANSCRIPT_WAIT_ITERS=1 run_dispatcher PostInvocation "$PAYLOAD"; LAST_RC=$?; set -e
assert_eq "$LAST_RC" "0" "sibling fallback exits 0"
assert_eq "$(tail_decodes)" "True" "an unreadable transcriptPath falls back to its sibling"

# ── Case 17: a transcript written AFTER the hook fires is still captured ────
# A brand-new conversation creates its transcript ~1s after its first
# PreInvocation fires, so without the appearance wait the FIRST prompt of every
# session — the one that opens the audit trail — is dropped.
LATE="$(mktemp -d)"
restart_mock '{}'
( sleep 0.5; printf '%s\n' "$ROW" > "$LATE/transcript.jsonl" ) &
WRITER_PID=$!
PAYLOAD=$(printf '{"invocationNum":1,"transcriptPath":"%s"}' "$LATE/transcript.jsonl")
set +e; run_dispatcher PreInvocation "$PAYLOAD"; LAST_RC=$?; set -e
wait "$WRITER_PID" 2>/dev/null || true
assert_eq "$LAST_RC" "0" "late-appearing transcript exits 0"
assert_eq "$(tail_decodes)" "True" "a transcript written after the hook fires is still tailed"

# A path that never appears fails open, bounded by the wait cap.
restart_mock '{}'
PAYLOAD=$(printf '{"invocationNum":1,"transcriptPath":"%s/nope.jsonl"}' "$LATE")
set +e; ROGUE_TRANSCRIPT_WAIT_ITERS=2 run_dispatcher PostInvocation "$PAYLOAD"; LAST_RC=$?; set -e
assert_eq "$LAST_RC" "0" "missing transcript exits 0"
body=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["body"])' "$HEADERS_FILE")
case "$body" in
  *transcriptTailB64*) echo "FAIL [missing transcript]: body was enriched; <$body>" >&2; exit 1 ;;
  *) echo "  ok: a transcript that never appears fails open, unenriched" ;;
esac
rm -rf "$TDIR" "$LATE"

# ── Case 18: IDE prompt recovery from the conversation store ────────────────
# The IDE writes transcript.jsonl only at invocation boundaries and Stop, so its
# PreInvocation cannot read the pending prompt from the tail. db-prompt.mjs reads
# it from Antigravity's own store instead. Everything here is IDE-gated: the 2.0
# app and the CLI must come out byte-identical to before.
DBT="$(mktemp -d)"
IDE_STATE="$DBT/antigravity-ide"
IDE_TP="$IDE_STATE/brain/CONV/.system_generated/logs/transcript.jsonl"
mkdir -p "$(dirname "$IDE_TP")" "$IDE_STATE/conversations"
printf '%s\n' '{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"<USER_REQUEST>\nfixture\n</USER_REQUEST>"}' > "$IDE_TP"
# Fixture store: the real schema, one developer prompt (source=4) and one row of
# our own injected text (source=6) that the reader must never pick up.
python3 - "$IDE_STATE/conversations/CONV.db" <<'PY'
import sqlite3, sys
def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F; n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n: return bytes(out)
def tag(num, wire): return varint((num << 3) | wire)
def msg(num, body): return tag(num, 2) + varint(len(body)) + body
def payload(text, source):
    return tag(1, 0) + varint(14) + msg(5, tag(3, 0) + varint(source)) + msg(19, msg(2, text.encode()))
con = sqlite3.connect(sys.argv[1])
con.execute("create table steps (idx integer primary key, step_type integer not null default 0, "
            "status integer not null default 0, step_format integer not null default 0, step_payload blob)")
def planner(text, source):   # step_type 15: the model's prose lives at 20.1
    return tag(1, 0) + varint(15) + msg(5, tag(3, 0) + varint(source)) + msg(20, msg(1, text.encode()))
def view_file(body, source): # step_type 8: view_file keeps its result under field 14
    return tag(1, 0) + varint(8) + msg(5, tag(3, 0) + varint(source)) + \
        msg(14, msg(1, b"file:///tmp/fixture.txt") + msg(4, body.encode()))
for idx, st, blob in [
    (0, 14, payload("fixture prompt from the store", 4)),
    (1, 15, b"\x08\x0f"),
    (2, 14, payload("[Rogue Security AIDR] This request was BLOCKED ...", 6)),
    (3, 8, view_file("untrusted file body", 2)),
    (4, 15, planner("here is what the file says", 2)),
]:
    con.execute("insert into steps (idx, step_type, status, step_format, step_payload) values (?,?,3,0,?)",
                (idx, st, blob))
con.commit(); con.close()
PY
IDE_BODY=$(printf '{"conversationId":"CONV","transcriptPath":"%s","initialNumSteps":1,"invocationNum":0}' "$IDE_TP")

posted() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["body"])' "$HEADERS_FILE"; }
field_present() { posted | python3 -c "import json,sys; print('$1' in json.load(sys.stdin))"; }

# A runtime with node:sqlite is required for the positive cases. Absent (CI, or a
# machine with no Antigravity), the negative cases still run.
#
# The probe MUST NOT touch the developer's real cache: resolve-runtime.sh writes
# its verdict to ${ROGUE_ANTIGRAVITY_RUNTIME_CACHE:-$HOME/.rogue/antigravity-runtime},
# and a `none` sentinel written from here would disable the IDE prompt gate in
# that user's own Antigravity sessions until they deleted the file.
ROGUE_ANTIGRAVITY_RUNTIME_CACHE="$DBT/runtime-cache"
export ROGUE_ANTIGRAVITY_RUNTIME_CACHE
RUNTIME=$(sh "$REPO/plugins/antigravity/scripts/resolve-runtime.sh" "$IDE_STATE" 2>/dev/null || true)
if [ -z "$RUNTIME" ] && [ -d "$HOME/.gemini/antigravity-ide" ]; then
  RUNTIME=$(sh "$REPO/plugins/antigravity/scripts/resolve-runtime.sh" "$HOME/.gemini/antigravity-ide" 2>/dev/null || true)
fi

if [ -n "$RUNTIME" ]; then
  export ROGUE_ANTIGRAVITY_NODE="$RUNTIME"
  export ROGUE_ANTIGRAVITY_DBPROMPT_DIR="$DBT/cache"

  restart_mock '{}'
  set +e; run_dispatcher PreInvocation "$IDE_BODY"; LAST_RC=$?; set -e
  assert_eq "$LAST_RC" "0" "IDE PreInvocation with a store exits 0"
  assert_eq "$(field_present rogueDbPromptB64)" "True" "IDE PreInvocation attaches rogueDbPromptB64"
  assert_eq "$(field_present rogueDbPromptCapable)" "True" "…and rogueDbPromptCapable"
  decoded=$(posted | python3 -c '
import base64, json, sys
env = json.loads(base64.b64decode(json.loads(sys.stdin.read())["rogueDbPromptB64"]))
print(env["v"], env["idx"], env["source"], env["stepFormat"], len(env["text"]))')
  assert_eq "$decoded" "1 0 4 0 29" "envelope carries v/idx/source/stepFormat and the prompt length"

  # Same (conversation, idx) again: a tool-loop turn re-reads the same row and
  # must not re-send it, which is also what stops us reading our own injection.
  restart_mock '{}'
  set +e; run_dispatcher PreInvocation "$IDE_BODY"; LAST_RC=$?; set -e
  assert_eq "$LAST_RC" "0" "repeat PreInvocation exits 0"
  assert_eq "$(field_present rogueDbPromptB64)" "False" "a repeated read is suppressed by the idx cache"
  assert_eq "$(field_present rogueDbPromptCapable)" "True" "but the machine still reports capable"

  # source=6 is our own injected block message; boundary 3 exposes it.
  rm -rf "$DBT/cache"
  restart_mock '{}'
  set +e; run_dispatcher PreInvocation "$(printf '{"conversationId":"CONV","transcriptPath":"%s","initialNumSteps":3,"invocationNum":0}' "$IDE_TP")"; LAST_RC=$?; set -e
  ownskip=$(posted | python3 -c '
import base64, json, sys
b = json.loads(sys.stdin.read())
env = json.loads(base64.b64decode(b["rogueDbPromptB64"])) if "rogueDbPromptB64" in b else {}
print(env.get("idx"), env.get("source"))')
  assert_eq "$ownskip" "0 4" "our own injected row (source=6) is never returned"

  # log mode reads but must not attach.
  restart_mock '{}'
  rm -rf "$DBT/cache"
  set +e; ROGUE_ANTIGRAVITY_DB_PROMPT=log run_dispatcher PreInvocation "$IDE_BODY"; LAST_RC=$?; set -e
  assert_eq "$(field_present rogueDbPromptB64)" "False" "DB_PROMPT=log reads without attaching"

  # kill switch
  restart_mock '{}'
  rm -rf "$DBT/cache"
  set +e; ROGUE_ANTIGRAVITY_DB_PROMPT=0 run_dispatcher PreInvocation "$IDE_BODY"; LAST_RC=$?; set -e
  assert_eq "$(field_present rogueDbPromptB64)" "False" "DB_PROMPT=0 disables the read entirely"
  assert_eq "$(field_present rogueDbPromptCapable)" "False" "…and claims no capability"

  # IDE Pre/PostInvocation must NOT tail the transcript (it can only hold the
  # previous turn there); Stop still must.
  restart_mock '{}'
  rm -rf "$DBT/cache"
  set +e; run_dispatcher PostInvocation "$IDE_BODY"; LAST_RC=$?; set -e
  assert_eq "$(field_present transcriptTailB64)" "False" "IDE PostInvocation no longer tails the transcript"

  # PostInvocation is the tool-output gate: it fires after the tool ran but before
  # the model call that reads the result, and it owns terminationBehavior. The
  # transcript has nothing at that moment, so the store supplies it.
  restart_mock '{}'
  rm -rf "$DBT/cache"
  set +e; run_dispatcher PostInvocation "$(printf '{"conversationId":"CONV","transcriptPath":"%s","initialNumSteps":3,"invocationNum":1}' "$IDE_TP")"; LAST_RC=$?; set -e
  assert_eq "$LAST_RC" "0" "IDE PostInvocation with produced steps exits 0"
  assert_eq "$(field_present rogueDbStepsB64)" "True" "IDE PostInvocation attaches rogueDbStepsB64"
  steps=$(posted | python3 -c '
import base64, json, sys
env = json.loads(base64.b64decode(json.loads(sys.stdin.read())["rogueDbStepsB64"]))
parts = [str(s["idx"]) + ":" + s["role"] for s in env["steps"]]
print(env["kind"], " ".join(parts))')
  assert_eq "$steps" "steps 3:tool 4:assistant" "the tool result and the prose arrive as separate steps, in order"
  # The idx high-water mark stops a tool-loop turn re-sending what it already sent.
  restart_mock '{}'
  set +e; run_dispatcher PostInvocation "$(printf '{"conversationId":"CONV","transcriptPath":"%s","initialNumSteps":3,"invocationNum":2}' "$IDE_TP")"; LAST_RC=$?; set -e
  assert_eq "$(field_present rogueDbStepsB64)" "False" "already-sent steps are not re-sent"
  restart_mock '{}'
  set +e; run_dispatcher Stop "$IDE_BODY"; LAST_RC=$?; set -e
  assert_eq "$(field_present transcriptTailB64)" "True" "IDE Stop still tails the transcript"
  # Regression: the flag describes the MACHINE, not the turn, so Stop must carry it
  # too. Without it the backend re-emits the prompt Stop's window contains and
  # every user message is stored twice — observed live before this assertion existed.
  assert_eq "$(field_present rogueDbPromptCapable)" "True" "IDE Stop declares the capability"
  assert_eq "$(field_present rogueDbPromptB64)" "False" "…without re-sending the prompt itself"
  assert_eq "$(field_present rogueDbPromptMissed)" "False" "…and reports nothing missed on a clean turn"
  assert_eq "$(field_present rogueDbStepsMissed)" "False" "…for either half"

  # ── A FAILED read must not be reported as a delivered turn ────────────────
  # The capability flag describes the machine, and the backend reads it on Stop as
  # "this turn already arrived". A read that could not reach the content (here: no
  # store file for the conversation at all — same class as a locked DB, drift, or a
  # blown deadline) therefore has to be recorded, or Stop suppresses its transcript
  # fallback and the whole turn is invisible with the tail in hand.
  MISSING_BODY=$(printf '{"conversationId":"NOSTORE","transcriptPath":"%s","initialNumSteps":1,"invocationNum":0}' "$IDE_TP")
  restart_mock '{}'
  rm -rf "$DBT/cache"
  set +e; run_dispatcher PreInvocation "$MISSING_BODY"; LAST_RC=$?; set -e
  assert_eq "$LAST_RC" "0" "an unreadable store still exits 0"
  assert_eq "$(field_present rogueDbPromptB64)" "False" "an unreadable store attaches nothing"
  restart_mock '{}'
  set +e; run_dispatcher Stop "$MISSING_BODY"; LAST_RC=$?; set -e
  assert_eq "$(field_present rogueDbPromptMissed)" "True" "Stop reports the prompt the store never delivered"
  assert_eq "$(field_present rogueDbStepsMissed)" "False" "…and only that half"
  assert_eq "$(field_present rogueDbPromptCapable)" "True" "…while still declaring the capability"

  # Consumed at Stop: a lingering marker would make the NEXT turn re-emit its tail.
  restart_mock '{}'
  set +e; run_dispatcher Stop "$MISSING_BODY"; LAST_RC=$?; set -e
  assert_eq "$(field_present rogueDbPromptMissed)" "False" "the marker is consumed, not sticky"

  # A steps read that fails is reported as the steps half, not the prompt.
  restart_mock '{}'
  set +e; run_dispatcher PostInvocation "$MISSING_BODY"; LAST_RC=$?; set -e
  restart_mock '{}'
  set +e; run_dispatcher Stop "$MISSING_BODY"; LAST_RC=$?; set -e
  assert_eq "$(field_present rogueDbStepsMissed)" "True" "Stop reports the steps the store never delivered"
  assert_eq "$(field_present rogueDbPromptMissed)" "False" "…without claiming the prompt was lost too"

  # "Nothing new" is NOT a failure: a turn's later invocations legitimately have no
  # new prompt (18 of 22 misses on a real machine were exactly this), and treating
  # them as failures would re-emit every turn's tail and duplicate messages.
  restart_mock '{}'
  rm -rf "$DBT/cache"
  set +e; run_dispatcher PreInvocation "$IDE_BODY"; LAST_RC=$?; set -e
  assert_eq "$(field_present rogueDbPromptB64)" "True" "first read of the turn attaches the prompt"
  restart_mock '{}'
  set +e; run_dispatcher PreInvocation "$IDE_BODY"; LAST_RC=$?; set -e
  assert_eq "$(field_present rogueDbPromptB64)" "False" "the repeat read sends nothing"
  restart_mock '{}'
  set +e; run_dispatcher Stop "$IDE_BODY"; LAST_RC=$?; set -e
  assert_eq "$(field_present rogueDbPromptMissed)" "False" "…and is not reported as a miss"

  # log mode reads without attaching, so the turn was NOT delivered — the mode has
  # to stay observational rather than blind the IDE.
  restart_mock '{}'
  rm -rf "$DBT/cache"
  set +e; ROGUE_ANTIGRAVITY_DB_PROMPT=log run_dispatcher PreInvocation "$IDE_BODY"; LAST_RC=$?; set -e
  restart_mock '{}'
  set +e; run_dispatcher Stop "$IDE_BODY"; LAST_RC=$?; set -e
  assert_eq "$(field_present rogueDbPromptMissed)" "True" "DB_PROMPT=log leaves Stop carrying the turn"

  # The reader's exit status is the signal the dispatcher branches on, so pin it.
  rm -rf "$DBT/cache"
  set +e
  printf '%s' "$IDE_BODY" | ELECTRON_RUN_AS_NODE=1 "$RUNTIME" --no-warnings --experimental-sqlite \
    "$REPO/plugins/antigravity/scripts/db-prompt.mjs" prompt >/dev/null 2>&1
  READER_RC=$?
  printf '%s' "$IDE_BODY" | ELECTRON_RUN_AS_NODE=1 "$RUNTIME" --no-warnings --experimental-sqlite \
    "$REPO/plugins/antigravity/scripts/db-prompt.mjs" prompt >/dev/null 2>&1
  REPEAT_RC=$?
  printf '%s' "$MISSING_BODY" | ELECTRON_RUN_AS_NODE=1 "$RUNTIME" --no-warnings --experimental-sqlite \
    "$REPO/plugins/antigravity/scripts/db-prompt.mjs" prompt >/dev/null 2>&1
  UNREAD_RC=$?
  set -e
  assert_eq "$READER_RC" "0" "the reader exits 0 when it emits"
  assert_eq "$REPEAT_RC" "0" "the reader exits 0 when there is genuinely nothing new"
  assert_eq "$UNREAD_RC" "3" "the reader exits 3 when it could not read the store"

  # ── A row with no message is not a failed read ────────────────────────────
  # Every tool the model picks produces a PLANNER_RESPONSE row with tool_calls and
  # NO prose. Reporting that as unread had Stop rebuild the turn from the transcript
  # and duplicate what later invocations delivered — the common case poisoning the
  # turn. Only a row that should have decoded and did not is a failure, so the
  # step_format guard below must still report one.
  python3 - "$IDE_STATE/conversations/TOOLONLY.db" "$IDE_STATE/conversations/DRIFT.db" <<'PY'
import sqlite3, sys
def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F; n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n: return bytes(out)
def tag(num, wire): return varint((num << 3) | wire)
def msg(num, body): return tag(num, 2) + varint(len(body)) + body
def make(path, step_format, blob):
    con = sqlite3.connect(path)
    con.execute("create table steps (idx integer primary key, step_type integer not null default 0, "
                "status integer not null default 0, step_format integer not null default 0, step_payload blob)")
    con.execute("insert into steps (idx, step_type, status, step_format, step_payload) values (5,15,3,?,?)",
                (step_format, blob))
    con.commit(); con.close()
# step_type 15 with an envelope but no prose at 20.1: "the model chose a tool".
make(sys.argv[1], 0, tag(1, 0) + varint(15) + msg(5, tag(3, 0) + varint(2)))
# Same row under a step_format we cannot read: real drift.
make(sys.argv[2], 1, tag(1, 0) + varint(15) + msg(5, tag(3, 0) + varint(2)))
PY
  toolonly_body() {
    printf '{"conversationId":"%s","transcriptPath":"%s","initialNumSteps":5,"invocationNum":1}' "$1" "$IDE_TP"
  }
  rm -rf "$DBT/cache"
  set +e
  printf '%s' "$(toolonly_body TOOLONLY)" | ELECTRON_RUN_AS_NODE=1 "$RUNTIME" --no-warnings \
    --experimental-sqlite "$REPO/plugins/antigravity/scripts/db-prompt.mjs" steps >/dev/null 2>&1
  TOOLONLY_RC=$?
  printf '%s' "$(toolonly_body DRIFT)" | ELECTRON_RUN_AS_NODE=1 "$RUNTIME" --no-warnings \
    --experimental-sqlite "$REPO/plugins/antigravity/scripts/db-prompt.mjs" steps >/dev/null 2>&1
  DRIFT_RC=$?
  set -e
  assert_eq "$TOOLONLY_RC" "0" "a tool-call-only planner row reads clean (nothing to deliver)"
  assert_eq "$DRIFT_RC" "3" "an unreadable step_format is still reported as drift"

  # …and end to end: such an invocation must leave Stop with nothing to rebuild.
  restart_mock '{}'
  rm -rf "$DBT/cache"
  set +e; run_dispatcher PostInvocation "$(toolonly_body TOOLONLY)"; LAST_RC=$?; set -e
  assert_eq "$(field_present rogueDbStepsB64)" "False" "a tool-call-only invocation attaches no steps"
  restart_mock '{}'
  set +e; run_dispatcher Stop "$(toolonly_body TOOLONLY)"; LAST_RC=$?; set -e
  assert_eq "$(field_present rogueDbStepsMissed)" "False" "…and is not reported as missed at Stop"

  # ── A transient failure is void once the content arrives ──────────────────
  # First read fails (no store file yet), a later one delivers the same half. Leaving
  # the marker in place would make Stop replay a half that was already sent.
  FLAKY_BODY=$(printf '{"conversationId":"FLAKY","transcriptPath":"%s","initialNumSteps":1,"invocationNum":0}' "$IDE_TP")
  restart_mock '{}'
  rm -rf "$DBT/cache"
  set +e; run_dispatcher PreInvocation "$FLAKY_BODY"; LAST_RC=$?; set -e
  assert_eq "$(field_present rogueDbPromptB64)" "False" "the flaky first read attaches nothing"
  cp "$IDE_STATE/conversations/CONV.db" "$IDE_STATE/conversations/FLAKY.db"
  restart_mock '{}'
  set +e; run_dispatcher PreInvocation "$FLAKY_BODY"; LAST_RC=$?; set -e
  assert_eq "$(field_present rogueDbPromptB64)" "True" "the retry delivers the prompt"
  restart_mock '{}'
  set +e; run_dispatcher Stop "$FLAKY_BODY"; LAST_RC=$?; set -e
  assert_eq "$(field_present rogueDbPromptMissed)" "False" "a delivered half clears the earlier failure"

  unset ROGUE_ANTIGRAVITY_NODE ROGUE_ANTIGRAVITY_DBPROMPT_DIR
else
  echo "  skip: no node:sqlite-capable runtime found; DB-prompt positive cases skipped"
fi

# A runtime that exists but cannot do the job must fail open, not hang or error.
restart_mock '{}'
set +e; ROGUE_ANTIGRAVITY_NODE=/bin/sh run_dispatcher PreInvocation "$IDE_BODY"; LAST_RC=$?; set -e
assert_eq "$LAST_RC" "0" "an unusable runtime still exits 0"
assert_eq "$(field_present rogueDbPromptB64)" "False" "an unusable runtime attaches nothing"
restart_mock '{}'
set +e; ROGUE_ANTIGRAVITY_NODE=/nonexistent/node run_dispatcher PreInvocation "$IDE_BODY"; LAST_RC=$?; set -e
assert_eq "$LAST_RC" "0" "a missing runtime still exits 0"
assert_eq "$(field_present rogueDbPromptB64)" "False" "a missing runtime attaches nothing"

# ── Case 19: the other two surfaces are untouched ───────────────────────────
# This is the regression guard for "IDE only". Their bodies must carry the
# transcript tail exactly as before and none of the new fields.
CLI_DIR="$(mktemp -d)"
printf '%s\n' '{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","content":"unchanged"}' \
  > "$CLI_DIR/transcript_full.jsonl"
for surface in antigravity-cli antigravity; do
  SDIR="$CLI_DIR/$surface/brain/C/.system_generated/logs"
  mkdir -p "$SDIR"
  cp "$CLI_DIR/transcript_full.jsonl" "$SDIR/transcript_full.jsonl"
  BODY_S=$(printf '{"conversationId":"C","transcriptPath":"%s/transcript_full.jsonl","initialNumSteps":1,"invocationNum":1}' "$SDIR")
  for ev in PreInvocation PostInvocation Stop; do
    restart_mock '{}'
    set +e; run_dispatcher "$ev" "$BODY_S"; LAST_RC=$?; set -e
    assert_eq "$LAST_RC" "0" "$surface $ev exits 0"
    assert_eq "$(field_present transcriptTailB64)" "True" "$surface $ev still tails the transcript"
    assert_eq "$(field_present rogueDbPromptB64)" "False" "$surface $ev sends no rogueDbPromptB64"
    assert_eq "$(field_present rogueDbPromptCapable)" "False" "$surface $ev sends no capability flag"
  done
done
rm -rf "$DBT" "$CLI_DIR"

echo
echo "All antigravity hook.sh tests passed (SH=$SH)."
