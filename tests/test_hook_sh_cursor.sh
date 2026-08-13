#!/usr/bin/env bash
# tests/test_hook_sh_cursor.sh — end-to-end for the Cursor sh dispatcher
# (plugins/cursor/scripts/hook.sh): env file → hook.sh → mock server → stdout.
#
# The suite exists for the subagent → parent session attribution, and its
# LOAD-BEARING assertion is on every case: THE POSTED BODY IS BYTE-IDENTICAL TO
# THE PIPED STDIN. That property is what let us prove the empty-conversation_id
# bug belonged to Cursor and not to us, so all new information rides in HEADERS
# (`x-rogue-parent-session-id`, `x-rogue-agent-id`). The ONE permitted body
# exception is `rogueFilePreImageB64` on preToolUse, and case 12 asserts that
# exception explicitly so a second one cannot be added silently.
#
# The other invariant under test is that binding is DETERMINISTIC: the child's
# own conversation_id is looked up as a FILENAME under
# ~/.cursor/projects/*/agent-transcripts/*/subagents/, so two concurrent
# subagents each find their own file (case 4). Nothing here may ever become
# "pick the newest file", and the subagentStart marker decides only WHETHER TO
# WAIT, never the answer.
#
# Cursor runs `sh ./scripts/hook.sh <event>`; override with TEST_SH=dash to
# exercise strict POSIX and catch bashisms.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO/plugins/cursor/scripts/hook.sh"
SH="${TEST_SH:-sh}"

PORT=$((RANDOM % 10000 + 30000))
HEADERS_FILE="$(mktemp)"
ENV_FILE="$(mktemp)"
OUT_FILE="$(mktemp)"
HOMES=()

cleanup() {
  if [ -n "${MOCK_PID:-}" ]; then
    kill "$MOCK_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true   # absorb the job-control "Terminated" notice
  fi
  rm -f "$ENV_FILE" "$HEADERS_FILE" "$OUT_FILE"
  for h in "${HOMES[@]:-}"; do [ -n "$h" ] && rm -rf "$h"; done
  [ -n "${NOJQ_DIR:-}" ] && rm -rf "$NOJQ_DIR"
  return 0
}
trap cleanup EXIT

cat > "$ENV_FILE" <<EOF
export ROGUE_API_KEY=test-key
export ROGUE_ACTOR_EMAIL=test@example.com
export ROGUE_ACTOR_NAME='Test User'
export ROGUE_BASE_URL=http://127.0.0.1:${PORT}
EOF

# The workspace every payload claims, and the slug hook.sh derives from it
# (leading "/" stripped, "/" and "." → "-"). The path need not exist: only the
# derived slug is ever used, as a directory name under ~/.cursor/projects.
WS='/Users/test/work/proj'
SLUG='Users-test-work-proj'

# ── harness ────────────────────────────────────────────────────────────────

# A fresh HOME carrying the env file. Kept for the caller (cache assertions need
# the same HOME across two runs); cleaned up at exit.
new_home() {
  local d
  d="$(mktemp -d)"
  cp "$ENV_FILE" "$d/.rogue-env"
  HOMES+=("$d")
  printf '%s' "$d"
}

# $1 home, $2 slug, $3 parent id, $4 child id — the transcript file Cursor writes
# ~1.1s after a subagent's first hook. Its NAME is the whole mechanism.
make_child_file() {
  mkdir -p "$1/.cursor/projects/$2/agent-transcripts/$3/subagents"
  : > "$1/.cursor/projects/$2/agent-transcripts/$3/subagents/$4.jsonl"
}

# $1 home, $2 slug, $3 parent id — the subagentStart marker (mtime is the clock).
make_marker() {
  mkdir -p "$1/.rogue/cursor-spawn/$2"
  : > "$1/.rogue/cursor-spawn/$2/$3"
}

# $1 home, $2 child id, $3 parent id — pre-seed the resolution cache.
seed_cache() {
  mkdir -p "$1/.rogue/cursor-parent"
  printf '%s' "$3" > "$1/.rogue/cursor-parent/$2"
}

# $1 conversation id — a minimal Cursor tool payload. `transcript_path` is null
# here exactly as it is on real events, INCLUDING ordinary parent ones; nothing
# in the dispatcher may branch on it.
payload_for() {
  printf '{"conversation_id":"%s","session_id":"%s","workspace_roots":["%s"],"transcript_path":null}' \
    "$1" "$1" "$WS"
}

# $1 home, $2 event, $3 payload. Pipes the payload as raw bytes (no heredoc
# newline) so the body-identity assertion is exact. Clears ROGUE_* from the
# process env so only the env file drives credential resolution. TEST_PATH, when
# set, REPLACES the dispatcher's PATH (see make_nojq_path).
LAST_PAYLOAD=""
TEST_PATH=""
run_hook() {
  local rc
  LAST_PAYLOAD="$3"
  set +e
  printf '%s' "$3" | env \
    HOME="$1" \
    ROGUE_API_KEY='' ROGUE_ACTOR_EMAIL='' ROGUE_ACTOR_NAME='' ROGUE_BASE_URL='' \
    ROGUE_CURSOR_PARENT_ITERS="${ROGUE_CURSOR_PARENT_ITERS:-}" \
    PATH="${TEST_PATH:-$PATH}" \
    "$SH" "$HOOK" "$2" > "$OUT_FILE"
  rc=$?
  set -e
  return $rc
}

# A PATH holding everything the dispatcher needs EXCEPT jq, so its anchored
# text-scan fallbacks run instead. jq (on macOS 26: /usr/bin/jq) sits in the same
# directory as the rest of the toolchain, so hiding it means rebuilding PATH as a
# symlink farm rather than dropping a directory.
make_nojq_path() {
  local d b src
  d="$(mktemp -d)"
  for b in "$SH" sh dirname basename date mkdir cat sed grep tr head base64 sleep curl stat rm; do
    src="$(command -v "$b" 2>/dev/null || true)"
    if [ -z "$src" ]; then echo "FAIL [nojq farm]: '$b' is not on PATH" >&2; exit 1; fi
    ln -s "$src" "$d/$(basename "$src")" 2>/dev/null || true
  done
  if PATH="$d" command -v jq >/dev/null 2>&1; then
    echo "FAIL [nojq farm]: jq is still reachable" >&2; exit 1
  fi
  printf '%s' "$d"
}

start_mock() {
  MOCK_RESPONSE="${1:-{\}}" MOCK_STATUS="${2:-200}" \
    python3 "$REPO/tests/mock_server.py" "$PORT" "$HEADERS_FILE" &
  MOCK_PID=$!
  for _ in $(seq 1 50); do
    nc -z 127.0.0.1 "$PORT" 2>/dev/null && return 0
    sleep 0.1
  done
  echo "mock server failed to start" >&2; exit 1
}

# mock_server.py OVERWRITES the record file per request, so every case that
# asserts on a POST must restart (or at least re-clear) between assertions.
restart_mock() {
  [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null || true
  wait "$MOCK_PID" 2>/dev/null || true
  rm -f "$HEADERS_FILE"
  start_mock "$@"
}

assert_eq() {
  if [ "$1" != "$2" ]; then echo "FAIL [$3]: expected <$2> but got <$1>" >&2; exit 1; fi
  echo "  ok: $3"
}

posted_body() {
  python3 -c 'import json,sys; sys.stdout.write(json.load(open(sys.argv[1]))["body"])' "$HEADERS_FILE"
}

assert_header() {
  local actual
  actual=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["headers"].get(sys.argv[2], ""))' "$HEADERS_FILE" "$1")
  assert_eq "$actual" "$2" "$3"
}

assert_no_header() {
  local actual
  actual=$(python3 -c 'import json,sys; print(sys.argv[2] in json.load(open(sys.argv[1]))["headers"])' "$HEADERS_FILE" "$1")
  assert_eq "$actual" "False" "$2"
}

# THE load-bearing assertion. Compares the raw bytes the mock recorded against
# the exact bytes we piped in.
assert_body_identical() {
  local got
  got="$(posted_body)"
  assert_eq "$got" "$LAST_PAYLOAD" "$1"
}

# Neither identity header, in either direction — a main-agent event must look
# exactly like today's.
assert_no_identity_headers() {
  assert_no_header "x-rogue-parent-session-id" "$1 (no parent header)"
  assert_no_header "x-rogue-agent-id"          "$1 (no agent header)"
}

now_s() { date +%s; }

# ── Case 1: baseline relay — verbatim body, existing headers, no identity ──
start_mock '{}'
HOME1="$(new_home)"
run_hook "$HOME1" postToolUse "$(payload_for 11111111-1111-1111-1111-111111111111)"
assert_eq "$(cat "$OUT_FILE")" '{}' "allow response relayed verbatim"
assert_header "x-rogue-event"       "postToolUse"      "x-rogue-event is the verbatim Cursor event name"
assert_header "x-rogue-api-key"     "test-key"         "x-rogue-api-key forwarded"
assert_header "x-rogue-actor-email" "test@example.com" "x-rogue-actor-email forwarded"
assert_header "x-rogue-actor-name"  "Test User"        "x-rogue-actor-name forwarded (with space)"
assert_header "x-rogue-source"      "cursor"           "x-rogue-source: cursor"
path=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["path"])' "$HEADERS_FILE")
assert_eq "$path" "/api/v1/hooks/cursor" "POST path is /api/v1/hooks/cursor"
assert_body_identical "unresolved body posted byte-identical to stdin"

# ── Case 2: a main-agent conversation resolves nothing and never waits ─────
# A brand-new top-level conversation looks exactly like an unresolved child (its
# own agent-transcripts dir does not exist for ~9s), so the ONLY thing keeping it
# from paying the full budget is the marker gate.
restart_mock '{}'
HOME2="$(new_home)"
t0=$(now_s)
run_hook "$HOME2" preToolUse "$(payload_for 22222222-2222-2222-2222-222222222222)"
t1=$(now_s)
assert_no_identity_headers "main-agent event"
assert_body_identical "main-agent body posted byte-identical to stdin"
if [ $((t1 - t0)) -ge 2 ]; then
  echo "FAIL [main-agent event returns promptly]: took $((t1 - t0))s, budget is ~3s" >&2; exit 1
fi
echo "  ok: main-agent event returns promptly (no marker -> no wait)"

# ── Case 3: cache-cold resolution — both headers, parent is the DIR name ───
restart_mock '{}'
HOME3="$(new_home)"
CHILD_A=aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa
PARENT_A=99999999-9999-4999-8999-999999999999
make_child_file "$HOME3" "$SLUG" "$PARENT_A" "$CHILD_A"
run_hook "$HOME3" postToolUse "$(payload_for "$CHILD_A")"
assert_header "x-rogue-parent-session-id" "$PARENT_A" "parent header is the agent-transcripts directory name"
assert_header "x-rogue-agent-id"          "$CHILD_A"  "agent header is the child's OWN conversation id"
assert_body_identical "resolved child body posted byte-identical to stdin"
assert_eq "$(cat "$HOME3/.rogue/cursor-parent/$CHILD_A")" "$PARENT_A" "resolution cached at ~/.rogue/cursor-parent/<child>"

# ── Case 3b: a second event for the same child reuses the cache ───────────
# Proven by DELETING the transcript file first: only a cache read can still
# answer. A subagent fires 18-223 hooks per spawn, so this is the common path.
restart_mock '{}'
rm -rf "$HOME3/.cursor/projects"
run_hook "$HOME3" beforeShellExecution "$(payload_for "$CHILD_A")"
assert_header "x-rogue-parent-session-id" "$PARENT_A" "second event resolves from the cache, not the filesystem"
assert_header "x-rogue-agent-id"          "$CHILD_A"  "second event still carries the child id"
assert_body_identical "cached-resolution body posted byte-identical to stdin"

# ── Case 4: two subagents under ONE parent — each carries its OWN id ───────
# This is the case that proves the lookup is a KEY LOOKUP and not "newest file
# wins": both files live in the same subagents/ directory, so any ranking rule
# would hand at least one event the other child's id.
restart_mock '{}'
HOME4="$(new_home)"
CHILD_X=bbbbbbbb-1111-4111-8111-bbbbbbbbbbbb
CHILD_Y=cccccccc-1111-4111-8111-cccccccccccc
PARENT_XY=88888888-8888-4888-8888-888888888888
make_child_file "$HOME4" "$SLUG" "$PARENT_XY" "$CHILD_X"
sleep 0.05   # distinct mtimes, so a "newest wins" bug would be deterministic
make_child_file "$HOME4" "$SLUG" "$PARENT_XY" "$CHILD_Y"

run_hook "$HOME4" postToolUse "$(payload_for "$CHILD_X")"
assert_header "x-rogue-agent-id"          "$CHILD_X"  "concurrent subagent X carries X's id (older file)"
assert_header "x-rogue-parent-session-id" "$PARENT_XY" "concurrent subagent X resolves the shared parent"
restart_mock '{}'
run_hook "$HOME4" postToolUse "$(payload_for "$CHILD_Y")"
assert_header "x-rogue-agent-id"          "$CHILD_Y"  "concurrent subagent Y carries Y's id"
restart_mock '{}'
run_hook "$HOME4" afterFileEdit "$(payload_for "$CHILD_X")"
assert_header "x-rogue-agent-id"          "$CHILD_X"  "X still carries X's id after Y ran (no cross-talk)"

# ── Case 5: a child under an UNDERIVABLE slug — global glob fallback ───────
# Slug derivation has real exceptions on disk (numeric slugs, `empty-window`,
# `.code-workspace`-derived names). The filename is the key either way.
restart_mock '{}'
HOME5="$(new_home)"
CHILD_S=dddddddd-1111-4111-8111-dddddddddddd
PARENT_S=77777777-7777-4777-8777-777777777777
make_child_file "$HOME5" "1784115802260" "$PARENT_S" "$CHILD_S"
run_hook "$HOME5" postToolUse "$(payload_for "$CHILD_S")"
assert_header "x-rogue-parent-session-id" "$PARENT_S" "resolved under a non-derivable slug via the global glob"
assert_header "x-rogue-agent-id"          "$CHILD_S"  "child id unchanged by the fallback path"

# ── Case 6: live marker + file created mid-wait -> headers sent ────────────
# The child's file is born 0.811-1.627s after its first hook, and its creation is
# INDEPENDENT of hook returns, so this wait cannot self-deadlock.
restart_mock '{}'
HOME6="$(new_home)"
CHILD_W=eeeeeeee-1111-4111-8111-eeeeeeeeeeee
PARENT_W=66666666-6666-4666-8666-666666666666
make_marker "$HOME6" "$SLUG" "$PARENT_W"
( sleep 0.7; make_child_file "$HOME6" "$SLUG" "$PARENT_W" "$CHILD_W" ) &
SPAWNER=$!
run_hook "$HOME6" postToolUse "$(payload_for "$CHILD_W")"
wait "$SPAWNER" 2>/dev/null || true
assert_header "x-rogue-parent-session-id" "$PARENT_W" "live marker: waited and resolved once the file appeared"
assert_header "x-rogue-agent-id"          "$CHILD_W"  "mid-wait resolution carries the child id"
assert_body_identical "mid-wait body posted byte-identical to stdin"

# ── Case 7: live marker, file NEVER created -> fail open, POST still happens ──
restart_mock '{}'
HOME7="$(new_home)"
CHILD_N=ffffffff-1111-4111-8111-ffffffffffff
make_marker "$HOME7" "$SLUG" 55555555-5555-4555-8555-555555555555
ROGUE_CURSOR_PARENT_ITERS=5 run_hook "$HOME7" postToolUse "$(payload_for "$CHILD_N")"
assert_eq "$(cat "$OUT_FILE")" '{}' "budget expiry still relays the response (fail open)"
assert_no_identity_headers "budget expired"
assert_body_identical "fail-open body posted byte-identical to stdin"

# ── Case 8: a marker older than the TTL is treated as absent (no wait) ─────
restart_mock '{}'
HOME8="$(new_home)"
CHILD_T=0a0a0a0a-1111-4111-8111-0a0a0a0a0a0a
make_marker "$HOME8" "$SLUG" 44444444-4444-4444-8444-444444444444
touch -t 200001010000 "$HOME8/.rogue/cursor-spawn/$SLUG/44444444-4444-4444-8444-444444444444"
t0=$(now_s)
run_hook "$HOME8" postToolUse "$(payload_for "$CHILD_T")"
t1=$(now_s)
assert_no_identity_headers "stale marker"
if [ $((t1 - t0)) -ge 2 ]; then
  echo "FAIL [stale marker does not arm the wait]: took $((t1 - t0))s" >&2; exit 1
fi
echo "  ok: stale marker does not arm the wait"

# ── Case 9: subagentStart writes the marker named by its OWN conversation_id ──
# subagentStart fires ON THE PARENT, so its conversation_id IS the parent's, and
# it must send no identity headers of its own.
restart_mock '{}'
HOME9="$(new_home)"
PARENT_M=33333333-3333-4333-8333-333333333333
run_hook "$HOME9" subagentStart "$(payload_for "$PARENT_M")"
assert_no_identity_headers "subagentStart"
assert_body_identical "subagentStart body posted byte-identical to stdin"
if [ ! -f "$HOME9/.rogue/cursor-spawn/$SLUG/$PARENT_M" ]; then
  echo "FAIL [subagentStart writes the marker]: no marker at ~/.rogue/cursor-spawn/$SLUG/$PARENT_M" >&2; exit 1
fi
echo "  ok: subagentStart writes ~/.rogue/cursor-spawn/<slug>/<parent id>"

# ── Case 9b: subagentStop clears it (best effort; the TTL is the real retire) ──
restart_mock '{}'
run_hook "$HOME9" subagentStop "$(payload_for "$PARENT_M")"
if [ -f "$HOME9/.rogue/cursor-spawn/$SLUG/$PARENT_M" ]; then
  echo "FAIL [subagentStop clears the marker]: marker still present" >&2; exit 1
fi
echo "  ok: subagentStop clears the marker"
assert_no_identity_headers "subagentStop"

# ── Case 10: parent-side events never resolve, even with a file on disk ────
# sessionEnd carries the PARENT's own conversation id; attributing it to itself
# would be meaningless, and waiting on it would tax every session.
restart_mock '{}'
HOME10="$(new_home)"
CHILD_P=1b1b1b1b-1111-4111-8111-1b1b1b1b1b1b
make_child_file "$HOME10" "$SLUG" 22222222-2222-4222-8222-222222222222 "$CHILD_P"
run_hook "$HOME10" sessionEnd "$(payload_for "$CHILD_P")"
assert_no_identity_headers "sessionEnd (parent-side event)"

# ── Case 11: the cache is read BEFORE any filesystem scan ─────────────────
# Seeded with a parent that has no file anywhere on disk, so only a cache read
# can produce this header.
restart_mock '{}'
HOME11="$(new_home)"
CHILD_C=2c2c2c2c-1111-4111-8111-2c2c2c2c2c2c
seed_cache "$HOME11" "$CHILD_C" cached-parent-id
run_hook "$HOME11" postToolUse "$(payload_for "$CHILD_C")"
assert_header "x-rogue-parent-session-id" "cached-parent-id" "cache is consulted before the filesystem"
assert_header "x-rogue-agent-id"          "$CHILD_C"         "cache hit still carries the child id"

# ── Case 12: preToolUse is the ONE permitted body mutation ────────────────
# A resolved child's preToolUse may add `rogueFilePreImageB64` and NOTHING else.
# Asserting the exception by name is what stops a second one being added quietly.
restart_mock '{}'
HOME12="$(new_home)"
CHILD_E=3d3d3d3d-1111-4111-8111-3d3d3d3d3d3d
PARENT_E=11111111-1111-4111-8111-111111111111
make_child_file "$HOME12" "$SLUG" "$PARENT_E" "$CHILD_E"
TARGET="$HOME12/target.txt"
printf 'pre-edit content' > "$TARGET"
PRE_PAYLOAD=$(python3 -c '
import json,sys
print(json.dumps({
  "conversation_id": sys.argv[1],
  "session_id": sys.argv[1],
  "workspace_roots": [sys.argv[3]],
  "transcript_path": None,
  "tool_name": "Write",
  "tool_input": {"file_path": sys.argv[2], "content": "new"},
}, separators=(",", ":")))' "$CHILD_E" "$TARGET" "$WS")
run_hook "$HOME12" preToolUse "$PRE_PAYLOAD"
assert_header "x-rogue-parent-session-id" "$PARENT_E" "preToolUse still resolves the parent"
assert_header "x-rogue-agent-id"          "$CHILD_E"  "preToolUse still carries the child id"
diff_keys=$(posted_body | python3 -c '
import base64,json,sys
posted = json.load(sys.stdin)
sent = json.loads(sys.argv[1])
added = sorted(set(posted) - set(sent))
removed = sorted(set(sent) - set(posted))
changed = sorted(k for k in sent if posted.get(k) != sent[k])
b64 = posted.get("rogueFilePreImageB64", "")
ok_pre = base64.b64decode(b64).decode() == "pre-edit content"
print("added=%s removed=%s changed=%s preimage_ok=%s" % (added, removed, changed, ok_pre))' "$PRE_PAYLOAD")
assert_eq "$diff_keys" \
  "added=['rogueFilePreImageB64'] removed=[] changed=[] preimage_ok=True" \
  "preToolUse adds rogueFilePreImageB64 and nothing else (the only body exception)"

# ── Case 13: a non-preToolUse event NEVER carries a pre-image ─────────────
restart_mock '{}'
run_hook "$HOME12" afterFileEdit "$PRE_PAYLOAD"
assert_body_identical "afterFileEdit body posted byte-identical to stdin (no pre-image)"

# ── Case 14: a non-uuid conversation_id is never used as a path component ──
restart_mock '{}'
HOME14="$(new_home)"
run_hook "$HOME14" postToolUse '{"conversation_id":"../../etc/passwd","session_id":"x","workspace_roots":["'"$WS"'"]}'
assert_no_identity_headers "non-uuid conversation_id"
assert_body_identical "traversal-shaped id body posted byte-identical to stdin"

# ── Case 15: an unparseable payload fails open and still relays ───────────
restart_mock '{"permission":"deny"}'
HOME15="$(new_home)"
run_hook "$HOME15" postToolUse 'not json at all'
assert_eq "$(cat "$OUT_FILE")" '{"permission":"deny"}' "unparseable payload still relays the response"
assert_no_identity_headers "unparseable payload"
assert_body_identical "unparseable payload posted byte-identical to stdin"

# ── Case 16: resolution works with jq absent (the text-scan fallback) ─────
# jq is missing from older macOS and minimal Linux images, so `conversation_id`
# and `workspace_roots[0]` both have anchored-scan fallbacks. Only ONE path runs
# on a given machine, so the fallback needs its own coverage.
restart_mock '{}'
HOME16="$(new_home)"
CHILD_J=4e4e4e4e-1111-4111-8111-4e4e4e4e4e4e
PARENT_J=5f5f5f5f-5555-4555-8555-5f5f5f5f5f5f
make_child_file "$HOME16" "$SLUG" "$PARENT_J" "$CHILD_J"
NOJQ_DIR="$(make_nojq_path)"
TEST_PATH="$NOJQ_DIR" run_hook "$HOME16" postToolUse "$(payload_for "$CHILD_J")"
assert_header "x-rogue-parent-session-id" "$PARENT_J" "resolved without jq (anchored text scan)"
assert_header "x-rogue-agent-id"          "$CHILD_J"  "child id read without jq"
assert_body_identical "no-jq body posted byte-identical to stdin"
rm -rf "$NOJQ_DIR"; NOJQ_DIR=""

echo
echo "All Cursor hook.sh tests passed (SH=$SH)."
