#!/usr/bin/env sh
# Contract test for THE LOG SHIPPER — plugins/*/scripts/ship-logs.sh.
# Design and rationale for every rule asserted here: docs/plugin-log-shipper.md.
#
# NO MOCK SERVER and no network: a fake `curl` earlier on PATH records the request
# body to a file and returns a scripted HTTP code, which is what lets a case assert
# the exact bytes that would have gone over the wire. HOME is redirected per case,
# so the developer's real ~/.rogue is never read or written.
#
# Run under dash as well as bash — `sh tests/test_ship_logs.sh`, then
# `SH=dash sh tests/test_ship_logs.sh`. The trailing-fragment arithmetic is exactly
# the kind of thing that differs between one shell's awk and another's, and a
# one-byte error there is silent (a stray leading newline on the next chunk, never
# an error message).
#
# The invariants worth protecting, in rough order of how badly they fail:
#   * a chunk NEVER ends mid-line, and the chunks concatenate back to the file
#   * the offset advances ONLY on 2xx — anything else re-sends, nothing is ever
#     marked exported on unconfirmed data
#   * rotation is detected by `head` as well as by `size < offset`, and a rotated
#     generation is drained BEFORE the offset resets
#   * the shipper has no actor cascade of its own (a wrong identity uploads and
#     stores logs that join to nothing)

set -u
REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SH="${SH:-sh}"
FAILS=0
T="$(mktemp -d "${TMPDIR:-/tmp}/rogue-shiptest.XXXXXX")" || exit 1
# Split, not one trap for all three: a bare `trap 'rm -rf …' INT` runs the handler
# and then CONTINUES with the next statement, so a Ctrl-C would delete the fixtures
# and let every remaining case run against a missing fake `curl` - a wall of
# confusing failures instead of a stop.
trap 'rm -rf "$T"' EXIT
trap 'rm -rf "$T"; exit 130' INT
trap 'rm -rf "$T"; exit 143' TERM

pass() { echo "  ok: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected [$2], got [$3])"; fi; }

SLUGS='claude codex cursor gemini copilot antigravity kiro'
# The six plugins that ship the POSIX-sh copy (gemini ships ship-logs.mjs).
SH_PLUGINS='rogue codex cursor copilot antigravity kiro'

# ── the fake curl ──────────────────────────────────────────────────────────
# The shipper invokes: curl … --data-binary @<body> -o /dev/null -w '%{http_code}'
# so the stub copies the body aside and prints a status code. FAKE_CODE=000 is how
# a transport failure or a timeout looks to the caller (real curl prints 000 and
# exits non-zero; the shipper keys off the code either way).
mkdir -p "$T/bin"
cat > "$T/bin/curl" <<'STUB'
#!/bin/sh
n=0
while [ -e "$CAP/body.$n" ]; do n=$((n + 1)); done
for a in "$@"; do
  case "$a" in @*) cp "${a#@}" "$CAP/body.$n" 2>/dev/null ;; esac
done
printf '%s' "${FAKE_CODE:-200}"
STUB
chmod +x "$T/bin/curl"

# Resolved BEFORE the shim is installed, and not hardcoded to /usr/bin/tail: the
# shim is on PATH for every case, so a host whose tail lives elsewhere (/bin/tail on
# Alpine and BusyBox, a store path on NixOS) would fail every case, not just this one.
# EXPORTED, so the shim reads it from the environment instead of interpolating it:
# the heredoc below is quoted (every runtime `$` in it must survive verbatim), and
# `tail` alone inside the shim would re-enter the shim itself through PATH.
export REAL_TAIL="$(command -v tail)"

# A one-shot `tail` shim used by exactly one case: it rotates the log the first
# time the shipper reads a byte range, which is the only way to exercise the
# rotation-during-read guard from outside the script. Inert unless ROTATE_TARGET
# is set, so every other case runs against the real tail.
cat > "$T/bin/tail" <<'STUB'
#!/bin/sh
if [ -n "${ROTATE_TARGET:-}" ] && [ ! -e "$ROTATE_TARGET.rotated" ]; then
  # Only the ranged read (`tail -c +N`) — not the single-byte boundary probe.
  case "${1:-}" in
    -c) case "${2:-}" in
          +*) : > "$ROTATE_TARGET.rotated"
              mv "$ROTATE_TARGET" "$ROTATE_TARGET.1" 2>/dev/null
              printf 'ROTATED-UNDER-US provider=claude event=X outcome=allow\n' > "$ROTATE_TARGET" ;;
        esac ;;
  esac
fi
exec "${REAL_TAIL:-/usr/bin/tail}" "$@"
STUB
chmod +x "$T/bin/tail"

# ── per-case fixtures ──────────────────────────────────────────────────────
CASE=""; LOG=""
new_case() {
  CASE="$T/$1"
  mkdir -p "$CASE/home/.rogue/logs" "$CASE/cap"
  LOG="$CASE/home/.rogue/logs/claude.log"
}

# ROGUE_SHIP_MIN_INTERVAL=0 on every run by default: without it the second run of a
# case is skipped by the 15-minute throttle, and "nothing was re-sent" would pass
# for entirely the wrong reason.
#
# Nothing opts these runs in. Shipping is unconditional - there is no ROGUE_SHIP_LOGS
# flag - so a configured install with new bytes on disk uploads them, and the cases
# below assert that rather than an opt-in.
ship_as() { # <plugin> <slug|-> <version> <family> [VAR=val …]
  _p="$1"; _s="$2"; _v="$3"; _fam="$4"; shift 4
  ( cd "$REPO" || exit 1
    export HOME="$CASE/home" CAP="$CASE/cap" PATH="$T/bin:$PATH"
    export ROGUE_API_KEY=test-key ROGUE_ACTOR_EMAIL=amos@rogue.security ROGUE_ACTOR_NAME=amos
    export ROGUE_SHIP_MIN_INTERVAL=0 ROGUE_BASE_URL=http://127.0.0.1:1
    export ROGUE_LOG_FILE='' ROGUE_LOG_DIR='' ROGUE_SHIP_ALL=''
    export ROGUE_SHIP_MAX_BYTES='' ROGUE_SHIP_MAX_RUN_BYTES='' ROGUE_SHIP_MAX_LINE_BYTES=''
    for kv in "$@"; do export "${kv?}"; done
    _root="${SHIP_ROOT:-$REPO/plugins/$_p}"
    if [ "$_s" = "-" ]; then "$SH" "$REPO/plugins/$_p/scripts/ship-logs.sh"
    else "$SH" "$REPO/plugins/$_p/scripts/ship-logs.sh" "$_root" "$_s" "$_v" "$_fam"; fi )
}
ship() { ship_as rogue claude 9.9.9 claude "$@"; }

# The Gemini shipper is Node, not sh - one implementation instead of a pair, because
# Gemini CLI guarantees Node 20+. tests/ship_probe.mjs stubs fetch so it captures
# bodies with the same naming as the fake curl.
ship_mjs() { # <slug> <version> <family> [VAR=val …]
  _s="$1"; _v="$2"; _fam="$3"; shift 3
  ( cd "$REPO" || exit 1
    export HOME="$CASE/home" CAP="$CASE/cap"
    export ROGUE_API_KEY=test-key ROGUE_ACTOR_EMAIL=amos@rogue.security ROGUE_ACTOR_NAME=amos
    export ROGUE_SHIP_MIN_INTERVAL=0 ROGUE_BASE_URL=http://127.0.0.1:1
    export ROGUE_LOG_FILE='' ROGUE_LOG_DIR='' ROGUE_SHIP_ALL=''
    export ROGUE_SHIP_MAX_BYTES='' ROGUE_SHIP_MAX_RUN_BYTES='' ROGUE_SHIP_MAX_LINE_BYTES=''
    for kv in "$@"; do export "${kv?}"; done
    node tests/ship_probe.mjs "$REPO/plugins/gemini" "$_s" "$_v" "$_fam" )
}

# A FUNCTION, not an inline `case` in a command substitution: the `)` that closes a
# case pattern also closes `$( … )`, so `$(case "$x" in *y*) … esac)` is a syntax
# error in both sh and dash.
contains() { # <needle> <haystack> -> yes|no
  case "$2" in *"$1"*) printf 'yes' ;; *) printf 'no' ;; esac
}
bodies()   { _n=0; while [ -e "$CASE/cap/body.$_n" ]; do _n=$((_n + 1)); done; printf '%s' "$_n"; }
# Lexical canonicalisation, matching what the shippers store in `path=`.
canon()    { printf '%s' "${1:-}" | sed -e 's#/\./#/#g' -e 's#//*#/#g'; }
numf()     { sed -n "s/.*\"$2\":\([0-9][0-9]*\).*/\1/p" "$CASE/cap/body.$1"; }
strf()     { sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p" "$CASE/cap/body.$1"; }
boolf()    { sed -n "s/.*\"$2\":\([a-z][a-z]*\).*/\1/p" "$CASE/cap/body.$1"; }
b64of()    { sed -n 's/.*"content_b64":"\([^"]*\)".*/\1/p' "$CASE/cap/body.$1"; }
# `base64 -d` on GNU, `-D` on older macOS. Probed once, so a decode failure cannot
# be mistaken for an empty chunk.
B64D='-d'; printf 'eA==' | base64 -d >/dev/null 2>&1 || B64D='-D'
content()  { b64of "$1" | base64 "$B64D" 2>/dev/null; }
state()    { sed -n "s/^$1=//p" "$CASE/home/.rogue/ship/claude.state" 2>/dev/null; }
seed()     { _i="$1"; while [ "$_i" -le "$2" ]; do
               printf '2026-08-12T00:00:%02dZ provider=%s event=PreToolUse outcome=allow n=%s\n' \
                 "$_i" "${3:-claude}" "$_i" >> "${4:-$LOG}"
               _i=$((_i + 1)); done; }
# Bytes of one seeded line, so a size expectation reads as arithmetic and not a
# magic number.
LINEB=$(printf '2026-08-12T00:00:01Z provider=claude event=PreToolUse outcome=allow n=1\n' | wc -c | tr -d ' ')

echo "== the six sh copies match scripts/shared/ship-logs.sh"
# Every per-plugin difference is an ARGUMENT, which is what lets `cmp` enforce
# lockstep instead of review. scripts/shared/ is the ONLY editable copy; the plugin
# copies are committed (three plugins install straight from a git clone with no build
# step) and regenerated by scripts/sync-shared-scripts.sh.
for name in ship-logs.sh ship-logs.ps1; do
  src="$REPO/scripts/shared/$name"
  if [ ! -f "$src" ]; then fail "missing $src"; continue; fi
  for p in $SH_PLUGINS; do
    f="$REPO/plugins/$p/scripts/$name"
    if [ ! -f "$f" ]; then fail "missing $f"; continue; fi
    if cmp -s "$src" "$f"; then pass "$p/$name is in sync"
    else fail "$p/scripts/$name is a stale copy — run scripts/sync-shared-scripts.sh"; fi
  done
done

echo
echo "== a first run ships the whole file"
new_case first
seed 1 3
ship
check "one request" "1" "$(bodies)"
check "envelope offset is 0" "0" "$(numf 0 offset)"
check "bytes = file size" "$(wc -c < "$LOG" | tr -d ' ')" "$(numf 0 bytes)"
check "state offset = file size" "$(wc -c < "$LOG" | tr -d ' ')" "$(state offset)"
check "log_file is a basename only" "claude.log" "$(strf 0 log_file)"
check "shipper slug" "claude" "$(strf 0 shipper)"
check "shipper_version" "9.9.9" "$(strf 0 shipper_version)"
check "agent_family from the caller" "claude" "$(strf 0 agent_family)"
check "rotated=false" "false" "$(boolf 0 rotated)"
check "content round-trips byte-exact" "$(cat "$LOG")" "$(content 0)"
# One log file is written by EVERY surface of its family (all three Claude
# surfaces share one $HOME and one claude.log), so a surface on the envelope would
# attach a multi-surface chunk to whichever surface opened a session first.
if grep -q '"agent"' "$CASE/cap/body.0"; then fail "envelope carries an agent/surface field"
else pass "no agent/surface field is sent"; fi
# canon(), not "$LOG" raw: `path=` is normalized (// and /./ collapsed) so that the
# sh, PowerShell and Node shippers - which share ~/.rogue/ship - agree on the
# identity of one file. See the xnorm case for what regressing this costs.
check "state records the normalized absolute path" "$(canon "$LOG")" "$(state path)"

echo
echo "== nothing new means no HTTP request at all"
# The property the 15-minute throttle rests on: an idle machine costs nothing.
ship
check "a second run with no new lines sends nothing" "1" "$(bodies)"

echo
echo "== an append ships only the new bytes"
before=$(wc -c < "$LOG" | tr -d ' ')
seed 4 5
ship
check "exactly one more request" "2" "$(bodies)"
check "starting at the previous offset" "$before" "$(numf 1 offset)"
check "carrying only the new lines" "$((LINEB * 2))" "$(numf 1 bytes)"

echo
echo "== the offset advances ONLY on 2xx"
for code in 500 404 000; do
  new_case "http$code"
  seed 1 3
  ship "FAKE_CODE=$code"
  check "$code produced a request" "1" "$(bodies)"
  check "$code did not advance the offset" "" "$(state offset)"
  ship
  check "$code re-sends the same range next run" "2" "$(bodies)"
  check "$code re-sends from 0" "0" "$(numf 1 offset)"
done

echo
echo "== rotation: the unshipped tail of .1 is drained, THEN the offset resets"
new_case rotate
seed 1 2
ship                                   # lines 1-2 shipped
seed 3 4                               # lines 3-4 not shipped yet…
mv "$LOG" "$LOG.1"                     # …and now they only exist in .1
seed 5 6
ship
check "two more requests (.1 tail, then the live log)" "3" "$(bodies)"
check ".1 tail is flagged rotated" "true" "$(boolf 1 rotated)"
check ".1 tail carries the unshipped lines" "$((LINEB * 2))" "$(numf 1 bytes)"
check "the live log then ships from 0" "0" "$(numf 2 offset)"
check "the live request is not flagged rotated" "false" "$(boolf 2 rotated)"
check "state ends up on the live file" "$(wc -c < "$LOG" | tr -d ' ')" "$(state offset)"

echo
echo "== rotation detected by head when the new file already passed the old offset"
# The silent data-loss hole a size-only check misses: rotation resets the file to
# zero length, but if the new file grows PAST the old offset before the next run,
# size > offset and no rotation is detected — so the new file's first `offset`
# bytes are skipped, with nothing to indicate they were missed. This is the case
# that justifies head= existing at all.
new_case growpast
seed 1 6
ship
off1=$(state offset)
mv "$LOG" "$LOG.1"
seed 10 20                             # new generation, comfortably larger
size2=$(wc -c < "$LOG" | tr -d ' ')
if [ "$size2" -le "$off1" ]; then fail "fixture wrong: new file must exceed the old offset"; fi
n_before=$(bodies)
ship
if [ "$(bodies)" -le "$n_before" ]; then fail "no request after a grow-past rotation"; else
  pass "the grow-past rotation was detected"
  # The whole new file must be re-shipped from 0, not [off1, size2).
  last=$(( $(bodies) - 1 ))
  check "the last request covers the new file from 0" "0" "$(numf $last offset)"
  check "…for its full size" "$size2" "$(numf $last bytes)"
fi

echo
echo "== a .1 whose head does not match the stored head is skipped, not shipped"
new_case badone
seed 1 3
ship
printf 'A DIFFERENT GENERATION provider=claude event=X outcome=allow\n' > "$LOG.1"
: > "$LOG"; seed 7 8
ship
check "two requests total: the live log only" "2" "$(bodies)"
check "the second is not flagged rotated" "false" "$(boolf 1 rotated)"
check "and it ships the live file from 0" "0" "$(numf 1 offset)"

echo
echo "== truncation in place resets to 0 and ships no bogus .1"
new_case truncate
seed 1 4
ship
: > "$LOG"
seed 9 9
ship
check "one more request" "2" "$(bodies)"
check "from offset 0" "0" "$(numf 1 offset)"
check "not flagged rotated" "false" "$(boolf 1 rotated)"

echo
echo "== a young file is not re-shipped (head is the first LINE, not 200 bytes)"
# Fingerprinting a fixed prefix instead misfires here: one short line hashes N
# bytes, and once three more lines arrive the same window spans lines 1-3, so the
# head "changes", the offset resets, and the whole file is re-shipped every run.
new_case young
printf 'tiny provider=claude event=X outcome=allow\n' > "$LOG"
ship
seed 2 4
ship
check "two requests, not a re-ship" "2" "$(bodies)"
check "the second starts after the first line" "$(printf 'tiny provider=claude event=X outcome=allow\n' | wc -c | tr -d ' ')" "$(numf 1 offset)"

echo
echo "== rotation DURING a read is discarded, and the offset does not move"
new_case toctou
seed 1 4
ship_as rogue claude 9.9.9 claude "ROTATE_TARGET=$LOG"
check "nothing was sent" "0" "$(bodies)"
check "no offset was persisted" "" "$(state offset)"

echo
echo "== chunks end on line boundaries and reassemble byte-exactly"
new_case boundary
seed 1 8
ship "ROGUE_SHIP_MAX_BYTES=$((LINEB * 2 - 5))"   # a cap that lands mid-line
n=$(bodies)
if [ "$n" -lt 3 ]; then fail "expected several chunks (got $n)"; else pass "$n chunks"; fi
i=0; partial=no; : > "$CASE/rebuilt"
while [ "$i" -lt "$n" ]; do
  lb=$(content "$i" | tail -c 1 | od -An -tu1 | tr -d ' \n')
  [ "$lb" = "10" ] || partial=yes
  # A redirect, not a command substitution, so the chunk's own trailing newline is
  # preserved — re-adding one would inflate the rebuild by a byte per chunk.
  content "$i" >> "$CASE/rebuilt"
  i=$((i + 1))
done
check "no chunk ends mid-line" "no" "$partial"
if cmp -s "$LOG" "$CASE/rebuilt"; then pass "the chunks reproduce the file byte-exactly"
else fail "chunks do not reproduce the file ($(wc -c < "$LOG" | tr -d ' ') vs $(wc -c < "$CASE/rebuilt" | tr -d ' '))"; fi
check "the file is fully drained in one run" "$(wc -c < "$LOG" | tr -d ' ')" "$(state offset)"

echo
echo "== the run budget bounds one run, and the next run resumes"
new_case runbudget
seed 1 20
ship "ROGUE_SHIP_MAX_BYTES=$LINEB" "ROGUE_SHIP_MAX_RUN_BYTES=$((LINEB * 3))"
check "the run stopped at the budget" "$((LINEB * 3))" "$(state offset)"
ship "ROGUE_SHIP_MAX_BYTES=$LINEB" "ROGUE_SHIP_MAX_RUN_BYTES=$((LINEB * 3))"
check "the next run resumes where it stopped" "$((LINEB * 6))" "$(state offset)"

echo
echo "== .1 larger than one request drains across chunks, and a spent budget does NOT reset"
# Skipping the rest of a rotated generation is silent loss, so a run that runs out
# of budget mid-.1 must leave the offset inside .1 rather than jumping to the live
# file.
new_case onechunks
seed 1 12
ship "ROGUE_SHIP_MAX_BYTES=$((LINEB * 2))"      # ships everything
seed 13 24                                       # 12 more lines, unshipped
mv "$LOG" "$LOG.1"
seed 90 91
one_size=$(wc -c < "$LOG.1" | tr -d ' ')
# Bodies accumulate across every run of a case, so the window for "that run" has to
# start where the previous run left off — iterating from body.0 also inspects the
# first run's (correctly un-rotated) requests.
first_run=$(bodies)
ship "ROGUE_SHIP_MAX_BYTES=$LINEB" "ROGUE_SHIP_MAX_RUN_BYTES=$((LINEB * 2))"
check "the offset is still inside .1" "yes" "$([ "$(state offset)" -lt "$one_size" ] && echo yes || echo no)"
check "state still fingerprints the .1 generation" "yes" \
  "$([ -n "$(state head)" ] && echo yes || echo no)"
rot_only=yes
i="$first_run"; while [ "$i" -lt "$(bodies)" ]; do
  [ "$(boolf "$i" rotated)" = "true" ] || rot_only=no
  i=$((i + 1))
done
check "every request in that run was a .1 chunk" "yes" "$rot_only"
# Now let it finish: .1 drains, then the live file ships.
ship "ROGUE_SHIP_MAX_BYTES=$((LINEB * 4))"
ship "ROGUE_SHIP_MAX_BYTES=$((LINEB * 4))"
check "the live file is eventually fully shipped" "$(wc -c < "$LOG" | tr -d ' ')" "$(state offset)"

echo
echo "== a line longer than one request is sent whole, never split"
new_case longline
{ printf '2026-08-12T00:00:01Z provider=claude event=PreToolUse raw='
  i=0; while [ "$i" -lt 500 ]; do printf 'x'; i=$((i + 1)); done; printf '\n'; } > "$LOG"
ship "ROGUE_SHIP_MAX_BYTES=100"
check "one oversized request" "1" "$(bodies)"
check "larger than the per-request cap" "yes" "$([ "$(numf 0 bytes)" -gt 100 ] && echo yes || echo no)"
check "ending on a line boundary" "10" "$(content 0 | tail -c 1 | od -An -tu1 | tr -d ' \n')"
check "the file is drained" "$(wc -c < "$LOG" | tr -d ' ')" "$(state offset)"

echo
echo "== a line over ROGUE_SHIP_MAX_LINE_BYTES is skipped FORWARD, and draining continues"
# A corrupt line must not park the file forever, which is why this skips instead
# of retrying.
new_case oversize
{ printf 'HUGE '; i=0; while [ "$i" -lt 400 ]; do printf 'y'; i=$((i + 1)); done; printf '\n'; } > "$LOG"
seed 2 3
# Measured BEFORE the run: the shipper appends its own `outcome=skip` line to this
# same log (that is where its diagnostics belong), so the post-run `wc -c` is larger
# than what the run had to drain. The skip line itself ships on a later run.
size_before=$(wc -c < "$LOG" | tr -d ' ')
ship "ROGUE_SHIP_MAX_BYTES=50" "ROGUE_SHIP_MAX_LINE_BYTES=100"
sent=""; i=0
while [ "$i" -lt "$(bodies)" ]; do sent="$sent$(content "$i")"; i=$((i + 1)); done
check "the monster line was not sent" "no" "$(contains 'HUGE' "$sent")"
# The regression this case exists for: skipping by a fixed window instead of to the
# next newline left the offset MID-LINE, and the monster's last few bytes then
# shipped as if they were a short line — so asserting only that the WHOLE line was
# absent passed while the bug was live.
check "no fragment of it was sent either" "no" "$(contains 'yyy' "$sent")"
check "the following lines still shipped" "yes" "$(contains 'n=2' "$sent")"
check "the file drained past the skip" "$size_before" "$(state offset)"
if grep -q 'outcome=skip reason=oversize-line' "$LOG"; then pass "the skip is recorded in the hook log"
else fail "no outcome=skip reason=oversize-line line was written"; fi

echo
echo "== the trailing-fragment arithmetic is exact"
# The one-liner `awk 'BEGIN{RS="\n"} END{print length($0)}'` is WRONG on its own:
# $0 in END is the LAST RECORD, not the text after the final separator, so a\nb\n
# yields 1 where it must yield 0. A chunk trimmed one byte short would leave the
# offset lagging one byte per run forever, and the symptom is a stray leading
# newline on the next chunk rather than an error. Asserted end-to-end: a file whose
# every line is shipped must round-trip, whatever the cap lands on.
for capoff in 0 1 2 3; do
  new_case "frag$capoff"
  seed 1 5
  ship "ROGUE_SHIP_MAX_BYTES=$((LINEB * 2 + capoff))"
  i=0; : > "$CASE/rebuilt"
  while [ "$i" -lt "$(bodies)" ]; do content "$i" >> "$CASE/rebuilt"; i=$((i + 1)); done
  if cmp -s "$LOG" "$CASE/rebuilt"; then pass "cap=2 lines+$capoff reassembles exactly"
  else fail "cap=2 lines+$capoff lost or duplicated bytes"; fi
done

echo
echo "== a chunk with a trailing newline is NOT trimmed by a byte"
# The regression that the arithmetic above got wrong, stated directly: with a cap
# that is an exact multiple of the line length, the first chunk must be the whole
# cap — not cap-1.
new_case exactcap
seed 1 4
ship "ROGUE_SHIP_MAX_BYTES=$((LINEB * 2))"
check "the first chunk is exactly two whole lines" "$((LINEB * 2))" "$(numf 0 bytes)"
check "the second starts exactly there" "$((LINEB * 2))" "$(numf 1 offset)"

echo
echo "== each plugin ships only its OWN log"
new_case ownonly
for s in $SLUGS; do seed 1 2 "$s" "$CASE/home/.rogue/logs/$s.log"; done
ship
check "one request" "1" "$(bodies)"
check "…for claude.log" "claude.log" "$(strf 0 log_file)"

echo
echo "== ROGUE_SHIP_ALL=1 collects every agent's log"
new_case shipall
for s in $SLUGS; do seed 1 2 "$s" "$CASE/home/.rogue/logs/$s.log"; done
ship "ROGUE_SHIP_ALL=1"
check "seven requests" "7" "$(bodies)"
# agent_family is a FALLBACK HINT for a line with no provider= token, so it is sent
# only for the caller's OWN log: on a foreign log the shipping plugin's family
# would mislabel every line (a codex line filed under `claude`).
own_fam=""; foreign_fam="none"
i=0; while [ "$i" -lt 7 ]; do
  lf=$(strf "$i" log_file); fam=$(strf "$i" agent_family)
  if [ "$lf" = "claude.log" ]; then own_fam="$fam"
  elif [ -n "$fam" ]; then foreign_fam="$fam"; fi
  i=$((i + 1))
done
check "the caller's own log carries agent_family" "claude" "$own_fam"
check "a foreign log omits agent_family" "none" "$foreign_fam"

echo
echo "== agent_family is the value the CALLER passed, never derived from the slug"
# codex's log slug is `codex` but its roster family is `openai`; a slug->family
# table inside a byte-identical script would be one more thing to keep in lockstep.
new_case family
seed 1 2 codex "$CASE/home/.rogue/logs/codex.log"
ship_as codex codex 9.9.9 openai
check "one request" "1" "$(bodies)"
check "shipper stays codex" "codex" "$(strf 0 shipper)"
check "agent_family is openai" "openai" "$(strf 0 agent_family)"

echo
echo "== ROGUE_LOG_FILE collapse mode: one file, and NO agent_family"
# All six agents write to this one path and its basename is arbitrary, so neither
# the envelope nor the filename can attribute a chunk — the server keys on each
# line's own provider= token instead.
new_case collapse
mix="$CASE/home/all.log"
seed 1 1 claude "$mix"; seed 2 2 codex "$mix"; seed 3 3 cursor "$mix"
ship "ROGUE_LOG_FILE=$mix"
check "one request" "1" "$(bodies)"
check "no agent_family" "" "$(strf 0 agent_family)"
check "log_file is that basename" "all.log" "$(strf 0 log_file)"
check "every line survives byte-exact" "$(cat "$mix")" "$(content 0)"

echo
echo "== a no-argument run collects everything and reports shipper=unknown"
new_case noargs
for s in $SLUGS; do seed 1 2 "$s" "$CASE/home/.rogue/logs/$s.log"; done
ship_as rogue - x x
check "seven requests" "7" "$(bodies)"
check "shipper is unknown" "unknown" "$(strf 0 shipper)"
allblank=yes; i=0
while [ "$i" -lt 7 ]; do [ -z "$(strf "$i" agent_family)" ] || allblank=no; i=$((i + 1)); done
check "no agent_family anywhere (no slug means no family)" "yes" "$allblank"

echo
echo "== state is keyed to the PATH, not just the basename"
# /a/claude.log and /b/claude.log key alike, so relocating ROGUE_LOG_DIR would
# otherwise point the shipper at a different file holding the previous file's offset.
new_case pathkey
seed 1 3
ship
mkdir -p "$CASE/home/other"
printf 'DIFFERENT FILE SAME BASENAME provider=claude event=X outcome=allow\n' > "$CASE/home/other/claude.log"
ship "ROGUE_LOG_DIR=$CASE/home/other"
check "the relocated file ships from 0" "0" "$(numf 1 offset)"
check "with its own content" "DIFFERENT FILE SAME BASENAME provider=claude event=X outcome=allow" "$(content 1)"

echo
echo "== a deleted or corrupt state file re-ships (duplicates, never loss)"
new_case badstate
seed 1 3
ship
rm -f "$CASE/home/.rogue/ship/claude.state"
ship
check "re-shipped from 0 after the state vanished" "0" "$(numf 1 offset)"
printf 'offset=not-a-number\nhead=\n' > "$CASE/home/.rogue/ship/claude.state"
ship
check "re-shipped from 0 on a corrupt offset" "0" "$(numf 2 offset)"

echo
echo "== the throttle"
new_case throttle
seed 1 3
ship "ROGUE_SHIP_MIN_INTERVAL=99999"
check "the first run is not throttled" "1" "$(bodies)"
seed 4 4
ship "ROGUE_SHIP_MIN_INTERVAL=99999"
check "the second run inside the interval is skipped" "1" "$(bodies)"
# A stamp in the FUTURE (clock stepped back, a bad write) is stale, not a reason to
# stop shipping until the clock catches up.
printf '99999999999\n' > "$CASE/home/.rogue/ship/.last-claude"
ship "ROGUE_SHIP_MIN_INTERVAL=99999"
check "a future .last is treated as stale" "2" "$(bodies)"
# …and it must come from the ENV FILE too, not only process env: ~/.rogue-env is
# the documented place to set it, and phase 1 shipped a bug of exactly this shape.
# Every staged file carries ROGUE_API_KEY: a file without it is not the one in use.
new_case throttle_envfile
seed 1 3
printf 'export ROGUE_API_KEY=test-key
export ROGUE_SHIP_MIN_INTERVAL=99999\n' > "$CASE/home/.rogue-env"
chmod 600 "$CASE/home/.rogue-env"
ship "ROGUE_SHIP_MIN_INTERVAL="
check "the first run ships" "1" "$(bodies)"
seed 4 4
ship "ROGUE_SHIP_MIN_INTERVAL="
check "~/.rogue-env can set the interval" "1" "$(bodies)"

echo
echo "== the lock"
new_case lock
seed 1 3
mkdir -p "$CASE/home/.rogue/ship/.lock-claude"
printf '%s\n' "$(date -u +%s)" > "$CASE/home/.rogue/ship/.lock-claude/ts"
ship
check "a held lock skips the file" "0" "$(bodies)"
# A killed shipper must not wedge the feature permanently.
printf '%s\n' "$(( $(date -u +%s) - 3600 ))" > "$CASE/home/.rogue/ship/.lock-claude/ts"
ship
check "a lock older than 600s is reclaimed" "1" "$(bodies)"
check "…and released again" "no" \
  "$([ -d "$CASE/home/.rogue/ship/.lock-claude" ] && echo yes || echo no)"
# A MARKER-LESS LOCK IS A LIVE LOCK, not a stale one. `mkdir` and the `ts` write are
# two operations, so a lock taken microseconds ago legitimately has no marker yet;
# reading that as stale let a second run delete a live lock and re-upload the same
# byte range. A fresh directory with no `ts` must therefore block, and only its own
# age may reclaim it.
new_case lock_nomarker
seed 1 3
mkdir -p "$CASE/home/.rogue/ship/.lock-claude"
ship
check "a fresh lock with no ts marker still blocks" "0" "$(bodies)"
# Backdated with touch, since the directory's mtime is the only age available here.
touch -t 200001010000 "$CASE/home/.rogue/ship/.lock-claude"
ship
check "…but an old one with no ts marker is reclaimed" "1" "$(bodies)"
new_case lock_otherkey
seed 1 3
mkdir -p "$CASE/home/.rogue/ship/.lock-codex"
printf '%s\n' "$(date -u +%s)" > "$CASE/home/.rogue/ship/.lock-codex/ts"
ship
check "a lock on a different key does not block" "1" "$(bodies)"

echo
echo "== identity"
new_case actor
seed 1 3
ship
check "actor_email is the inherited value" "amos@rogue.security" "$(strf 0 actor_email)"
check "actor_name is the inherited value" "amos" "$(strf 0 actor_name)"
check "host is non-empty" "yes" "$([ -n "$(strf 0 host)" ] && echo yes || echo no)"
check "host matches hostname" "$(hostname 2>/dev/null || echo unknown)" "$(strf 0 host)"

# The shipper must have NO cascade of its own. The six plugins' cascades are not
# the same (actor.sh falls back to `hostname`, Cursor's hook.sh to
# `$USER@$(hostname)`), so an independent re-resolve does not merely risk drift —
# it produces it, and the heartbeat's roster row and the log's log_source row then
# never meet. Nothing errors; the logs just attach to nothing.
new_case noactor
seed 1 3
mkdir -p "$CASE/root/scripts"
ship "SHIP_ROOT=$CASE/root" "ROGUE_ACTOR_EMAIL=" "ROGUE_ACTOR_NAME="
check "no identity means no upload" "0" "$(bodies)"
if grep -q 'outcome=skip reason=no-actor' "$LOG"; then pass "the skip is recorded"
else fail "no outcome=skip reason=no-actor line was written"; fi
check "no offset was persisted either" "" "$(state offset)"

# A NAME with no email is still an inherited identity, and the plugin that lands
# here is a real one: `plugins/cursor` ships a shipper and NO actor.sh, so every
# empty-email run on it reaches this branch. The PowerShell and Node copies (which
# have no actor.sh on any platform) canonicalise to `anon` and ship, so skipping
# here made Cursor the only place on a machine that shipped nothing in that state.
new_case nameonly
seed 1 3
mkdir -p "$CASE/root/scripts"
ship "SHIP_ROOT=$CASE/root" "ROGUE_ACTOR_EMAIL=" "ROGUE_ACTOR_NAME=Amos"
check "a name with no email still ships" "1" "$(bodies)"
check "…under the canonical anon email" "anon" "$(strf 0 actor_email)"
check "…carrying the name it was given" "Amos" "$(strf 0 actor_name)"

# Absent, empty and whitespace-only must all produce ONE canonical value, matching
# the roster fingerprint's `actorEmail ?? "anon"` extended to cover "" and "   ".
# The failure is silent: the log_source row and the roster row key differently and
# the logs attach to nothing.
i=0
for variant in 'unset' 'empty' 'blank'; do
  new_case "anon-$variant"
  seed 1 2
  mkdir -p "$CASE/root/scripts"
  case "$variant" in
    unset) printf ':\n' > "$CASE/root/scripts/actor.sh" ;;
    empty) printf 'ROGUE_ACTOR_EMAIL=""\nexport ROGUE_ACTOR_EMAIL\n' > "$CASE/root/scripts/actor.sh" ;;
    blank) printf 'ROGUE_ACTOR_EMAIL="   "\nexport ROGUE_ACTOR_EMAIL\n' > "$CASE/root/scripts/actor.sh" ;;
  esac
  ship "SHIP_ROOT=$CASE/root" "ROGUE_ACTOR_EMAIL=" "ROGUE_ACTOR_NAME="
  check "$variant actor_email canonicalises to anon" "anon" "$(strf 0 actor_email)"
  # The identity-leak assertion belongs HERE, not in the noactor case above: this is
  # the only place a body is actually sent while no identity was resolved, so it is
  # the only place a private cascade could put `hostname` or `whoami` on the wire.
  # (The noactor case asserted the same thing against zero bodies, which passed
  # whatever the shipper did - `bodies` was already asserted to be 0 one line up.)
  #
  # Scoped to the ACTOR fields, not the whole body: `host` carries the hostname by
  # design (asserted above), so scanning the envelope would fail on the field that is
  # supposed to be there and say nothing about identity.
  for field in actor_email actor_name; do
    for forbidden in "$(hostname 2>/dev/null)" "$(whoami 2>/dev/null)"; do
      [ -n "$forbidden" ] || continue
      case "$(strf 0 "$field")" in
        *"$forbidden"*) fail "$variant $field names this machine ($forbidden) instead of anon" ;;
        *) pass "$variant $field does not name this machine ($forbidden)" ;;
      esac
    done
  done
done

# THE SAME VARIANTS THROUGH THE NODE SHIPPER. Running them only through the sh copy
# hid a real divergence: the Node one treated an empty or whitespace-only email as
# "no identity" and shipped nothing, so a Gemini install whose git config carries no
# user.email was silent while every other plugin on that machine shipped under
# `anon`. There is no actor.sh here to stage the value in — Gemini's caller passes it
# in the child's env — so the variants are the env value itself.
if ! command -v node >/dev/null 2>&1; then
  echo "NOTE: node not found — skipping the Node identity cases"
else
  # Staged in an ENV FILE rather than the process env, and that is not incidental:
  # loadEnv merges a process-env var only when it is truthy, so an exported EMPTY
  # string is indistinguishable from unset there. An env file's `KEY=""` is a value
  # that IS present and empty — the Node analogue of an actor.sh that resolved
  # nothing, which is what the sh variants above stage.
  for variant in 'empty' 'blank'; do
    new_case "anon-mjs-$variant"
    glog="$CASE/home/.rogue/logs/gemini.log"
    seed 1 2 gemini "$glog"
    case "$variant" in
      empty) printf 'export ROGUE_API_KEY=test-key
export ROGUE_ACTOR_EMAIL=""\n' > "$CASE/home/.rogue-env" ;;
      blank) printf 'export ROGUE_API_KEY=test-key
export ROGUE_ACTOR_EMAIL="   "\n' > "$CASE/home/.rogue-env" ;;
    esac
    chmod 600 "$CASE/home/.rogue-env"
    ship_mjs gemini 9.9.9 gemini "ROGUE_ACTOR_EMAIL=" "ROGUE_ACTOR_NAME="
    check "$variant actor_email canonicalises to anon (Node)" "anon" "$(strf 0 actor_email)"
  done
  # An identity that was NEVER PASSED is a different thing from one resolved as
  # empty: it means the caller resolved nothing at all, which must still skip. `env
  # -u` rather than `KEY=`, because an empty export is dropped by loadEnv's truthy
  # test and would therefore look identical to the case above — and because the
  # DEVELOPER's own shell may export ROGUE_ACTOR_EMAIL, which would otherwise leak
  # into this case and make it ship.
  new_case anon-mjs-absent
  glog="$CASE/home/.rogue/logs/gemini.log"
  seed 1 2 gemini "$glog"
  ( cd "$REPO" || exit 1
    export HOME="$CASE/home" CAP="$CASE/cap"
    export ROGUE_API_KEY=test-key ROGUE_SHIP_MIN_INTERVAL=0
    export ROGUE_BASE_URL=http://127.0.0.1:1
    env -u ROGUE_ACTOR_EMAIL -u ROGUE_ACTOR_NAME \
      node tests/ship_probe.mjs "$REPO/plugins/gemini" gemini 9.9.9 gemini ) >/dev/null 2>&1
  check "an actor that was never passed still skips (Node)" "0" "$(bodies)"
fi

echo
echo "== shipping is unconditional, and knob clamping"
new_case default-on
seed 1 3
# NOTHING opts this in. A configured install with new bytes ships them, which is the
# whole of the policy now that /api/v1/hooks/logs is deployed. Asserted first, from a
# clean case, because every other assertion in this file would pass vacuously against
# a shipper that uploads nothing.
ship
check "a configured install ships with no flag at all" "1" "$(bodies)"
# Compared against the file's own size rather than a literal: the fixture's line
# count is a detail of `seed`, and a drained file means offset == size.
check "…and records the whole file as drained" "$(wc -c < "$LOG" | tr -d ' ')" "$(state offset)"

new_case unconfigured
seed 1 3
ship "ROGUE_API_KEY="
check "an unconfigured install is still silent" "0" "$(bodies)"
check "…leaving no state" "" "$(state offset)"

# ROGUE_SHIP_LOGS IS GONE, and a value left behind on a machine that had it must not
# change anything. An install that upgrades into this version keeps whatever the
# operator once wrote in ~/.rogue-env or an MDM /etc/rogue/env, and the shipper is
# required to ignore all of it - inline and in a file, `0`, `00` and non-numeric alike.
# Anything else would leave a fleet silently half-off with no knob left to explain it.
new_case retired-flag
seed 1 3
ship "ROGUE_SHIP_LOGS=0"
check "an inline 0 no longer disables" "1" "$(bodies)"
new_case retired-flag-file
seed 1 3
printf 'export ROGUE_API_KEY=test-key
export ROGUE_SHIP_LOGS=0\n' > "$CASE/home/.rogue-env"
chmod 600 "$CASE/home/.rogue-env"
ship
check "a 0 in an env file no longer disables" "1" "$(bodies)"
new_case retired-flag-file-padded
seed 1 3
printf 'export ROGUE_API_KEY=test-key
export ROGUE_SHIP_LOGS=00\n' > "$CASE/home/.rogue-env"
chmod 600 "$CASE/home/.rogue-env"
ship
check "a zero-padded 00 in a file no longer disables" "1" "$(bodies)"
# The Node shipper must agree: it shares ~/.rogue/ship and the same documented
# semantics, and a policy honored on one implementation only is not one.
if command -v node >/dev/null 2>&1; then
  new_case retired-flag-mjs
  glog="$CASE/home/.rogue/logs/gemini.log"
  seed 1 3 gemini "$glog"
  printf 'export ROGUE_API_KEY=test-key
export ROGUE_SHIP_LOGS=0\n' > "$CASE/home/.rogue-env"
  chmod 600 "$CASE/home/.rogue-env"
  ship_mjs gemini 9.9.9 gemini
  check "a 0 in an env file no longer disables (Node)" "1" "$(bodies)"
  new_case default-on-mjs
  glog="$CASE/home/.rogue/logs/gemini.log"
  seed 1 3 gemini "$glog"
  ship_mjs gemini 9.9.9 gemini
  check "a configured install ships with no flag at all (Node)" "1" "$(bodies)"
fi
# The debug stream must carry the reason, because a no-arg support run has no log
# file of its own to write to (SELF_LOG_FILE is empty when the slug is `unknown`).
new_case debug-reason
seed 1 3
check "a failure reports http= on stderr under ROGUE_DEBUG" "1" \
  "$(ship_as rogue - 9.9.9 claude "ROGUE_DEBUG=1" "ROGUE_SHIP_ALL=1" "FAKE_CODE=404" 2>&1 \
     | grep -c 'outcome=fail.*http=404')"
# A typo must never disable shipping or blow a size cap; a zero byte-cap would
# ship nothing forever, so it falls back rather than stalling the file.
for bad in 0 -1 abc 00; do
  new_case "cap-$bad"
  seed 1 3
  ship "ROGUE_SHIP_MAX_BYTES=$bad"
  check "ROGUE_SHIP_MAX_BYTES=$bad falls back to the default" "1" "$(bodies)"
  check "…and drains the file" "$(wc -c < "$LOG" | tr -d ' ')" "$(state offset)"
done

echo
echo "== payload safety"
new_case bytes
printf '2026-08-12T00:00:01Z provider=claude event=X outcome=block reason="he said \\"hi\\" \\ backslash" utf8=caf\303\251-\360\237\224\245\n' > "$LOG"
printf '2026-08-12T00:00:02Z provider=claude event=X outcome=allow\n' >> "$LOG"
ship
check "one request" "1" "$(bodies)"
check "quotes, backslashes and UTF-8 round-trip byte-exact" "$(cat "$LOG")" "$(content 0)"
# sh variables cannot hold NUL, so the chunk never passes through one; it is
# extracted to a temp file and only base64 output is ever piped.
new_case nulbyte
printf '2026-08-12T00:00:01Z provider=claude event=X raw=a\000b-after-nul\n' > "$LOG"
ship
check "a NUL byte does not truncate the chunk" "$(wc -c < "$LOG" | tr -d ' ')" "$(numf 0 bytes)"
check "…and survives the round-trip" "$(wc -c < "$LOG" | tr -d ' ')" "$(content 0 | wc -c | tr -d ' ')"

echo
echo "== the Node shipper and the sh shipper share one state format"
# All three implementations share ~/.rogue/ship/, so under ROGUE_SHIP_ALL Gemini's
# .mjs writes state that Claude's .sh reads next session. If `head=` or `path=` were
# encoded differently the second shipper would see "rotated" or "different file" and
# re-ship the whole log on every alternating run - which is exactly why head is
# base64 of a byte range and not a checksum (sh has no guaranteed hasher, and
# Get-FileHash returns UPPERCASE hex where shasum returns lowercase).
if ! command -v node >/dev/null 2>&1; then
  echo "NOTE: node not found — skipping the cross-language state cases"
else
  new_case xlang
  glog="$CASE/home/.rogue/logs/gemini.log"
  seed 1 3 gemini "$glog"
  ship_mjs gemini 9.9.9 gemini
  check "the Node shipper sent one request" "1" "$(bodies)"
  check "…reporting its own slug" "gemini" "$(strf 0 shipper)"
  gsize=$(wc -c < "$glog" | tr -d ' ')
  goff=$(sed -n 's/^offset=//p' "$CASE/home/.rogue/ship/gemini.state" 2>/dev/null)
  check "…and drained the file" "$gsize" "$goff"
  # Now the sh shipper, against the state Node just wrote.
  ship_as rogue gemini 9.9.9 gemini
  check "the sh shipper honors Node's state (no re-ship)" "1" "$(bodies)"
  # …and the reverse direction: sh writes, Node reads.
  new_case xlang2
  glog="$CASE/home/.rogue/logs/gemini.log"
  seed 1 3 gemini "$glog"
  ship_as rogue gemini 9.9.9 gemini
  check "the sh shipper sent one request" "1" "$(bodies)"
  ship_mjs gemini 9.9.9 gemini
  check "the Node shipper honors sh's state (no re-ship)" "1" "$(bodies)"
  seed 4 4 gemini "$glog"
  ship_mjs gemini 9.9.9 gemini
  check "…and picks up only the new line" "$((LINEB * 3))" "$(numf 1 offset)"

  # `path=` must NORMALIZE, not merely absolutise. This found a real bug: on macOS
  # $TMPDIR ends in a slash, so this suite's own paths contain `//`, which
  # path.resolve collapses and a lexical $PWD-prefix does not — the two shippers
  # then read each other's state as a DIFFERENT FILE and each re-shipped the whole
  # log. Same shape as a ROGUE_LOG_DIR with a trailing slash in an MDM env file, so
  # it is reachable without a test harness. Both directions, via a directory the
  # caller reaches through a redundant `//` and a `.`.
  new_case xnorm
  glog="$CASE/home/.rogue/logs/gemini.log"
  seed 1 3 gemini "$glog"
  ship_mjs gemini 9.9.9 gemini "ROGUE_LOG_DIR=$CASE/home/.rogue//logs"
  check "the Node shipper ships through a // path" "1" "$(bodies)"
  ship_as rogue gemini 9.9.9 gemini "ROGUE_LOG_DIR=$CASE/home/./.rogue/logs/"
  check "the sh shipper agrees it is the same file" "1" "$(bodies)"
  # $TMPDIR's own trailing slash is inside $glog too, so the expectation has to be
  # canonicalised the same way rather than compared raw.
  check "…and stored one canonical path" "$(canon "$glog")" \
    "$(sed -n 's/^path=//p' "$CASE/home/.rogue/ship/gemini.state" 2>/dev/null)"
fi

echo
echo "== the shipper leaves no litter in ~/.rogue/ship"
new_case litter
seed 1 3
ship
left=$(find "$CASE/home/.rogue/ship" -name '.tmp.*' -o -name '.state-tmp-*' 2>/dev/null | wc -l | tr -d ' ')
check "no temp dirs or half-written state files remain" "0" "$left"
check "no lock directory remains" "no" \
  "$([ -d "$CASE/home/.rogue/ship/.lock-claude" ] && echo yes || echo no)"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "All log-shipper contract tests passed (SH=$SH)."
  exit 0
fi
echo "$FAILS failure(s)."
exit 1
