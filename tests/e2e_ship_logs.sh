#!/usr/bin/env sh
# END-TO-END test for the log shipper. Complements tests/test_ship_logs.sh rather
# than repeating it:
#
#   * that suite is a CONTRACT test - it replaces `curl` with a stub, so it asserts
#     what the shipper WOULD send. Fast, no network, runs under dash and bash in CI.
#   * this one runs the REAL pipeline: the real dispatcher writes the log, the real
#     rotation in hook.sh renames it, the real shipper POSTs over real HTTP with real
#     curl, and a real server (tests/e2e_receiver.mjs) rebuilds the file from the
#     wire. The assertion is `cmp` between what is on disk and what the server got.
#
# That difference matters because the stub can never catch a class of bug the wire
# can: a body curl refuses to send, an envelope that is not valid JSON once a log
# line contains a quote or a backslash, a base64 line-wrap that survives `tr -d` in
# one shell but not another, or a chunk that arrives but is not what was read.
#
#   sh tests/e2e_ship_logs.sh          # needs `node` (the receiver) and `curl`
#
# Everything happens under one sandbox dir with its own $HOME, so the developer's
# real ~/.rogue and ~/.rogue-env are never read or written.
set -u

REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

# Scrub every knob the shipper reads from the environment. NOT optional hygiene: a
# developer running this almost certainly has ROGUE_API_KEY exported for their own
# install, and the process env supplies every knob the env file in use does not set
# - so without this the sandbox could run with the developer's own values (and a leaked
# ROGUE_LOG_DIR would point the "sandboxed" run at their real logs). Found the hard
# way: the receiver logged a rejected key that this script never set.
unset ROGUE_API_KEY ROGUE_BASE_URL ROGUE_ACTOR_EMAIL ROGUE_ACTOR_NAME \
      ROGUE_LOG_FILE ROGUE_LOG_DIR ROGUE_LOG_MAX_BYTES ROGUE_SHIP_LOGS \
      ROGUE_SHIP_MIN_INTERVAL ROGUE_SHIP_MAX_BYTES ROGUE_SHIP_MAX_RUN_BYTES \
      ROGUE_SHIP_MAX_LINE_BYTES ROGUE_SHIP_ALL ROGUE_DEBUG 2>/dev/null

FAILS=0
pass() { echo "  ok: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected [$2], got [$3])"; fi; }

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found (the receiver needs it)"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "SKIP: curl not found"; exit 0; }

SB="$(mktemp -d "${TMPDIR:-/tmp}/rogue-e2e.XXXXXX")" || exit 1
RECV="$SB/recv"
export HOME="$SB/home"
mkdir -p "$HOME" "$RECV"

RECEIVER_PID=""
cleanup() {
  [ -n "$RECEIVER_PID" ] && kill "$RECEIVER_PID" 2>/dev/null
  rm -rf "$SB" 2>/dev/null
}
trap 'cleanup' EXIT INT TERM

# ── the receiver ───────────────────────────────────────────────────────────
E2E_API_KEY=e2e-key node "$REPO/tests/e2e_receiver.mjs" "$RECV" >"$SB/recv.out" 2>&1 &
RECEIVER_PID=$!
# Poll for the port file rather than sleeping a fixed amount: a fixed sleep is either
# slower than needed or flaky on a loaded machine, and both are avoidable.
_waited=0
while [ ! -s "$RECV/port" ]; do
  _waited=$((_waited + 1))
  [ "$_waited" -gt 100 ] && { echo "FAIL: the receiver never started"; cat "$SB/recv.out"; exit 1; }
  sleep 0.1
done
PORT="$(cat "$RECV/port")"
BASE="http://127.0.0.1:$PORT"
echo "receiver on $BASE"

# ── credentials, written by the REAL setup script ──────────────────────────
# Not a hand-rolled env file: setup.sh's quoting is what hook.sh and ship-logs.sh
# both have to parse, so writing it any other way would test a format nothing ships.
#
# `bash`, matching its shebang, NOT `sh`. setup.sh quotes values with printf '%q',
# which is a bash builtin extension: under dash it produces nothing and the file is
# never written. That is invisible on macOS, where /bin/sh IS bash in POSIX mode, and
# fails on every Linux runner — which is exactly how CI caught it after this suite
# passed locally.
bash "$REPO/plugins/rogue/scripts/setup.sh" e2e-key amos@rogue.security amos >/dev/null 2>&1
check "setup.sh wrote ~/.rogue-env" "yes" "$([ -f "$HOME/.rogue-env" ] && echo yes || echo no)"

LOG="$HOME/.rogue/logs/claude.log"

# ── phase 1: real dispatcher runs produce the log ──────────────────────────
# ROGUE_LOG_MAX_BYTES is small so hook.sh's OWN rotation fires - the rotation under
# test is the shipped product's, not one the test performed.
dispatch() { # <n> <extra-payload-text>
  _i=1
  while [ "$_i" -le "${1:-1}" ]; do
    printf '{"session_id":"e2e","tool_name":"Bash","tool_input":{"command":"echo %s%s"}}' \
      "$_i" "${2:-}" |
      env CLAUDE_PLUGIN_ROOT="$REPO/plugins/rogue" CLAUDE_CODE_ENTRYPOINT=cli \
        ROGUE_BASE_URL="$BASE" ROGUE_LOG_MAX_BYTES=4096 \
        sh "$REPO/plugins/rogue/scripts/hook.sh" PreToolUse >/dev/null 2>&1
    _i=$((_i + 1))
  done
}

# Nothing opts these runs in: shipping is unconditional, so a configured install with
# new bytes on disk uploads them. That default is asserted on its own further down,
# against the real server, because every case here would pass vacuously against a
# shipper that did nothing.
ship() { # [VAR=val …]
  env ROGUE_BASE_URL="$BASE" ROGUE_SHIP_MIN_INTERVAL=0 "$@" \
    sh "$REPO/plugins/rogue/scripts/ship-logs.sh" "$REPO/plugins/rogue" claude 9.9.9 claude \
    >/dev/null 2>&1
}

envelopes() { # count of accepted log envelopes
  [ -f "$RECV/envelopes.jsonl" ] || { printf '0'; return; }
  grep -c '"kind":"logs"' "$RECV/envelopes.jsonl" 2>/dev/null | tr -d ' \n'
}
rejected() {
  [ -f "$RECV/envelopes.jsonl" ] || { printf '0'; return; }
  grep -c '"kind":"logs-rejected"' "$RECV/envelopes.jsonl" 2>/dev/null | tr -d ' \n'
}
state_offset() { sed -n 's/^offset=//p' "$HOME/.rogue/ship/claude.state" 2>/dev/null; }
log_bytes() { wc -c < "$LOG" 2>/dev/null | tr -d ' '; }

echo
echo "== a real dispatcher writes the log, and the real shipper uploads it"
dispatch 5
check "the dispatcher actually ran (the server saw its POSTs)" "yes" \
  "$([ -s "$RECV/other.log" ] && echo yes || echo no)"
check "…and wrote a log file" "yes" "$([ -s "$LOG" ] && echo yes || echo no)"
before_bytes="$(log_bytes)"
ship
check "one upload" "1" "$(envelopes)"
check "the API key was accepted" "no" "$([ -f "$RECV/bad_key.log" ] && echo yes || echo no)"
check "every body was valid JSON" "no" "$([ -f "$RECV/bad_json.log" ] && echo yes || echo no)"
check "the offset reached the file size" "$before_bytes" "$(state_offset)"
if cmp -s "$LOG" "$RECV/reassembled-claude.log"; then
  pass "the server rebuilt the log byte-for-byte from the wire"
else
  fail "the rebuilt log differs from the file on disk"
fi

echo
echo "== a non-2xx must not advance the offset, and the bytes arrive later"
# A REAL 500 from a real server, which is the case the stubbed suite can only
# approximate: on this path curl succeeds, the response is well-formed, and only the
# status says no. The offset must not move, and nothing may be recorded.
dispatch 2
printf '500\n' > "$RECV/status_code"
before_fail_offset="$(state_offset)"
accepted_before="$(envelopes)"
ship
check "nothing was accepted" "$accepted_before" "$(envelopes)"
check "the server did see the attempt" "1" "$(rejected)"
check "the offset did not move" "$before_fail_offset" "$(state_offset)"
printf '200\n' > "$RECV/status_code"
ship
check "the same range arrived once the server recovered" "$(log_bytes)" "$(state_offset)"
if cmp -s "$LOG" "$RECV/reassembled-claude.log"; then
  pass "…and still matches byte-for-byte (no duplicate, no gap)"
else
  fail "the rebuilt log differs after the recovery"
fi

echo
echo "== the dispatcher's own rotation, drained end to end"
# Traffic until hook.sh ITSELF crosses ROGUE_LOG_MAX_BYTES=4096 and renames the live
# log to .1 - the rotation under test is the shipped product's, not one this script
# performed. Then three more lines, so the live generation is non-empty too and both
# files exist at once, which is the state the shipper has to handle.
#
# EXACTLY ONE rotation, driven by a loop rather than a fixed line count. A fixed count
# large enough to be safe crosses the cap TWICE, and phase 1 deliberately keeps only
# one generation (worst case 2x the cap on disk), so the second rotation overwrites .1
# and gen1's un-shipped tail is gone from disk before the shipper ever runs. That is
# correct product behaviour and an incorrect test: the reassembly below could never
# match. Verified - it is what made this case fail first time round.
PADDING="-padding-padding-padding-padding-padding-padding-padding"
_batches=0
while [ ! -f "$LOG.1" ] && [ "$_batches" -lt 40 ]; do
  dispatch 4 "$PADDING"
  _batches=$((_batches + 1))
done
generation_one=""
if [ -f "$LOG.1" ]; then
  pass "hook.sh rotated the log by itself"
  generation_one="$LOG.1"
else
  fail "no rotation happened — raise the batch bound in this case"
fi
dispatch 3 "$PADDING"
check "…and only once (the live generation is still under the cap)" "yes" \
  "$([ "$(log_bytes)" -lt 4096 ] && echo yes || echo no)"
ship
if [ -n "$generation_one" ]; then
  cat "$generation_one" "$LOG" > "$SB/expected-both-generations"
  if cmp -s "$SB/expected-both-generations" "$RECV/reassembled-claude.log"; then
    pass "both generations arrived, in order, with nothing lost at the seam"
  else
    fail "the rotated generation and the live log did not reassemble in order"
  fi
  check "the offset now tracks the LIVE file" "$(log_bytes)" "$(state_offset)"
  check "the un-shipped tail of .1 was sent as rotated=true" "yes" \
    "$(grep -q '"rotated":true' "$RECV/envelopes.jsonl" && echo yes || echo no)"
fi

echo
echo "== every uploaded chunk ends on a line boundary"
# The invariant the whole design exists for: a chunk that ends mid-line becomes two
# corrupt records server-side. Checked on the REASSEMBLED file, which is where a
# boundary error would actually show up.
if [ -s "$RECV/reassembled-claude.log" ]; then
  check "the rebuilt file ends with a newline" "10" \
    "$(tail -c 1 "$RECV/reassembled-claude.log" | od -An -tu1 | tr -d ' \n')"
  check "no line lost its timestamp prefix" "0" \
    "$(grep -cv '^[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T' "$RECV/reassembled-claude.log" | tr -d ' \n')"
fi

echo
echo "== an idle machine makes no request at all"
idle_before="$(envelopes)"
ship
check "a run with nothing new uploads nothing" "$idle_before" "$(envelopes)"

echo
echo "== the throttle holds against the real clock"
dispatch 2
throttled_before="$(envelopes)"
# No ROGUE_SHIP_MIN_INTERVAL=0 override here, so the default 900s applies and the
# stamp written moments ago must suppress this run.
env ROGUE_BASE_URL="$BASE" sh "$REPO/plugins/rogue/scripts/ship-logs.sh" \
  "$REPO/plugins/rogue" claude 9.9.9 claude >/dev/null 2>&1
check "the 15-minute throttle skipped the run" "$throttled_before" "$(envelopes)"

echo
echo "== shipping is unconditional, and a retired ROGUE_SHIP_LOGS cannot stop it"
# Asserted against the REAL server with fresh lines waiting, so an upload cannot be a
# stale-state artefact. The flag is gone, and a value left behind on a machine that
# once set it - inline or in an env file - must not silence that machine: an upgrade
# would otherwise leave a fleet half-off with no knob left to explain it.
dispatch 2
default_before="$(envelopes)"
env ROGUE_BASE_URL="$BASE" ROGUE_SHIP_MIN_INTERVAL=0 sh \
  "$REPO/plugins/rogue/scripts/ship-logs.sh" "$REPO/plugins/rogue" claude 9.9.9 claude \
  >/dev/null 2>&1
check "a configured install uploads with no flag set" "$((default_before + 1))" "$(envelopes)"
dispatch 2
stale_before="$(envelopes)"
printf 'export ROGUE_SHIP_LOGS=0\n' >> "$SB/home/.rogue-env"
ship
check "a stale ROGUE_SHIP_LOGS=0 in an env file no longer disables" \
  "$((stale_before + 1))" "$(envelopes)"

echo
echo "== the REAL caller fires the shipper (not just the shipper directly)"
# Everything above invokes ship-logs.sh itself, which proves the shipper works but
# NOT that anything in the product ever calls it - the state this feature was in
# until the callers were wired. So drive the actual production entry point:
# heartbeat.sh, which is what hooks.json spawns detached on SessionStart.
#
# It must upload, and it must NOT re-resolve the actor: the heartbeat resolves the
# identity and passes it down, so the envelope's actor has to match the one the
# heartbeat itself just reported in its roster POST.
new_home="$SB/home2"
mkdir -p "$new_home"
caller_before="$(envelopes)"
HOME="$new_home" bash "$REPO/plugins/rogue/scripts/setup.sh" \
  e2e-key caller@rogue.security "Caller Person" >/dev/null 2>&1
caller_log="$new_home/.rogue/logs/claude.log"
mkdir -p "$new_home/.rogue/logs"
printf '2026-08-12T00:00:01Z provider=claude event=PreToolUse outcome=allow n=1\n' > "$caller_log"
env HOME="$new_home" CLAUDE_PLUGIN_ROOT="$REPO/plugins/rogue" CLAUDE_CODE_ENTRYPOINT=cli \
  ROGUE_BASE_URL="$BASE" ROGUE_SHIP_MIN_INTERVAL=0 \
  bash "$REPO/plugins/rogue/scripts/heartbeat.sh" >/dev/null 2>&1
check "heartbeat.sh uploaded the log" "$((caller_before + 1))" "$(envelopes)"
check "…under the identity the heartbeat itself reported" "caller@rogue.security" \
  "$(sed -n 's/.*"kind":"logs".*"actor_email":"\([^"]*\)".*/\1/p' "$RECV/envelopes.jsonl" | tail -1)"
check "…and with the caller's slug and family" "claude" \
  "$(sed -n 's/.*"kind":"logs".*"shipper":"\([^"]*\)".*/\1/p' "$RECV/envelopes.jsonl" | tail -1)"
check "…reporting the plugin version, not \"unknown\"" "no" \
  "$(sed -n 's/.*"kind":"logs".*"shipper_version":"\([^"]*\)".*/\1/p' "$RECV/envelopes.jsonl" \
     | tail -1 | grep -q unknown && echo yes || echo no)"

echo
echo "== an unconfigured install ships nothing"
rm -f "$HOME/.rogue-env"
# Fresh lines FIRST, as in the opt-in case above. The previous `ship` drained the
# log, so without new bytes the shipper would make no request whether or not a key
# is configured, and this case would pass for the wrong reason.
dispatch 2
unconfigured_before="$(envelopes)"
ship
check "no API key -> no upload" "$unconfigured_before" "$(envelopes)"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "All end-to-end log-shipper tests passed."
  exit 0
fi
echo "$FAILS failure(s)."
exit 1
