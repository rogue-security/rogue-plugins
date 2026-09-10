#!/bin/sh
# Rogue Security hook bridge for Google Antigravity — POSIX sh implementation.
# Usage: hook.sh <eventName>   (PreToolUse, PostToolUse, PreInvocation,
# PostInvocation, Stop)
#
# Reads one Antigravity hook event JSON on stdin, POSTs it to the rogue-api
# /hooks/antigravity route, and relays the native Antigravity decision shape
# verbatim on stdout. PURE RELAY: no block-detection regex, no local modal.
# There are exactly TWO stdin mutations: PreInvocation/PostInvocation/Stop append
# the transcript tail (see augment_with_transcript) so the backend can read
# recent turn content, and a subagent's events get their conversationId rewritten
# to the parent's (see reattribute_subagent).
#
# FAIL-OPEN IS SAFETY-CRITICAL. PreToolUse must always resolve to an explicit
# decision — never a bare `{}` — so `fail_open_default` emits
# {"decision":"allow"} for PreToolUse and {} for every other event. This
# script MUST always `exit 0`; never `set -e`; never let curl propagate a
# non-zero exit. A block is carried in the relayed JSON body on stdout, never
# via the exit code.
#
# Exactly-one-runs (Windows): unlike Copilot (which selects one command per
# platform), both the sh entry and the PowerShell entry may run on a given
# Antigravity machine. Under Git Bash (uname MINGW*/MSYS*/CYGWIN*) this script
# stands down by emitting NOTHING and exiting 0, so it never contributes a
# decision when the PowerShell handler also runs on the same invocation.
# ROGUE_FORCE_UNAME overrides uname (for tests).
#
# Credential resolution: the first env file holding ROGUE_API_KEY is used alone,
# and its values override the process env:
#   1. /etc/rogue/env            (machine, MDM-provisioned)
#   2. ${PLUGIN_ROOT}/env        (bundled into a compiled customer plugin)
#   3. $HOME/.rogue-env          (per-user / installer-written)

# ── Shape of this file ─────────────────────────────────────────────────────
# Everything is a function; `main` at the bottom is the only thing that runs, and
# it reads as the pipeline it is (stand down → configure → read → enrich → post).
# The state that pipeline threads between its steps lives in the few globals
# below, declared here rather than materialising mid-file.
#
# ORDER IS LOAD-BEARING inside `main`, in three places: the Git Bash stand-down
# has to precede every other action, the env files have to be sourced before any
# default derived from them, and stdin is only read once a key exists to POST it
# with. See the comments on each step.

EVENT=""          # hook event name, from $1
PLUGIN_ROOT=""    # <root> of this plugin, derived from $0
BODY=""           # the hook payload, as received then enriched
SURFACE=""        # antigravity | antigravity_ide | antigravity_cli, or empty
URL=""            # where to POST it
SUBAGENT_ID=""    # set by reattribute_subagent when this event is a subagent's
SUBAGENT_NAME=""

# --- Git Bash stand-down: emit NOTHING so the PowerShell handler owns Windows.
# Must run before ANY other work (env sourcing, actor resolution, POST) so a
# machine running both handlers never double-POSTs / double-decides.
stand_down_under_git_bash() {
  _uname="${ROGUE_FORCE_UNAME:-$(uname -s 2>/dev/null)}"
  case "$_uname" in
    MINGW*|MSYS*|CYGWIN*) exit 0 ;;   # empty stdout — no decision contributed
  esac
}

# Self-locate the plugin root from $0 (the path we were invoked with:
# <root>/scripts/hook.sh).
locate_plugin_root() {
  PLUGIN_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd)"
  [ -n "$PLUGIN_ROOT" ] || PLUGIN_ROOT="."
}

# Every default derived from the environment is computed HERE, after the
# sourcing, because the env file must be able to set any of them — computing them
# at file scope would freeze the built-in default before the file is read.
load_env() {
  # The first env file holding ROGUE_API_KEY is used alone: machine, bundled, user.
  for _env_file in /etc/rogue/env "${PLUGIN_ROOT}/env" "$HOME/.rogue-env"; do
    if [ -r "$_env_file" ] && grep -Eq '^[[:space:]]*(export[[:space:]]+)?ROGUE_API_KEY=' "$_env_file"; then
      . "$_env_file"; break
    fi
  done

  # Log destination — ONE FILE PER AGENT. Every Rogue plugin shares ~/.rogue, so
  # a machine running Antigravity + Claude Code + Cursor + … used to interleave
  # all of them into a single hook.log with no way to tell whose line was whose.
  # Precedence: explicit file → directory override → per-agent default.
  ROGUE_LOG_DIR="${ROGUE_LOG_DIR:-$HOME/.rogue/logs}"
  ROGUE_LOG_FILE="${ROGUE_LOG_FILE:-$ROGUE_LOG_DIR/antigravity.log}"
  # Size cap. Over it, the current log is renamed to <file>.1 - exactly one
  # generation kept, so worst case on disk is 2x this. A NUMERIC ZERO disables
  # rotation; a NON-NUMERIC value falls back to this default, so a typo can
  # never leave the log growing unbounded.
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
  # IDE store reads: off entirely with 0, read-but-never-attach with `log`.
  DB_PROMPT_MODE="${ROGUE_ANTIGRAVITY_DB_PROMPT:-1}"
  MISS_DIR="${ROGUE_ANTIGRAVITY_DBPROMPT_DIR:-$HOME/.rogue/antigravity-dbprompt}"
  BRAIN_DIR="${ROGUE_ANTIGRAVITY_BRAIN_DIR:-$HOME/.gemini/antigravity-cli/brain}"
  SUBMAP_DIR="${ROGUE_ANTIGRAVITY_SUBMAP_DIR:-$HOME/.rogue/antigravity-submap}"
  # Trim a trailing slash so a user-set ROGUE_BASE_URL with one doesn't yield
  # "//" in the composed URL (mirrors hook.ps1's .TrimEnd('/')).
  ROGUE_BASE_URL="${ROGUE_BASE_URL%/}"
  URL="${ROGUE_API_URL:-${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/antigravity}"
}

# Trim the log before appending. Rotation lives on the WRITE PATH and not in a
# periodic job on purpose: an UNCONFIGURED install writes a line per event and
# never runs anything else, so a cap enforced anywhere else would not hold.
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
    # `${SURFACE:+ surface=$SURFACE}` expands to NOTHING when the slug is empty -
    # which is the normal case for an event whose payload carries no transcriptPath,
    # and for every line written before read_body. Never `surface=`, never
    # `surface=unknown`.
    printf '%s provider=antigravity%s event=%s %s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SURFACE:+ surface=$SURFACE}" \
      "$EVENT" "$*" >> "$ROGUE_LOG_FILE" 2>/dev/null )
}
sanitize() { printf '%s' "$1" | tr -d '\000-\037\177'; }

# Per-event fail-open default. PreToolUse must resolve to an explicit
# decision (never a bare {}), or Antigravity would treat it as ambiguous;
# every other event is audit/monitor-only and fails open to a clean {}.
fail_open_default() {
  case "$EVENT" in
    PreToolUse) printf '{"decision":"allow"}' ;;
    *)          printf '{}' ;;
  esac
}

# PreInvocation/PostInvocation/Stop carry no message content inline — only a
# transcriptPath pointing at the session's transcript.jsonl. Append the last
# ~256KB of that file, base64-encoded, as "transcriptTailB64" so the backend
# can extract recent turn content. base64 output has no JSON-special
# characters, so appending it by re-closing the object is safe. Fail-open:
# any problem (no path, unreadable, empty) returns the body unchanged.
#
# Antigravity's transcript.jsonl line schema is undocumented — there is no
# known "turn end" marker line to poll for (unlike Copilot's events.jsonl, see
# plugins/copilot/scripts/hook.sh), so this wait is schema-agnostic: it polls
# file SIZE stability instead of a marker line, and is hard time-bounded
# (~2s). On timeout it fails open and tails whatever is on disk rather than
# hanging or guessing at an undocumented marker format.
# $1 = transcript path.
wait_for_transcript_flush() {
  _wtp="$1"
  _n=0
  _prev_size=-1
  # ~2s cap (20 * 0.1s), well inside the 30s hook budget. Returns as soon as
  # the file size is unchanged across two 0.1s-spaced reads (a schema-agnostic
  # proxy for "the writer has finished flushing"). ROGUE_FLUSH_WAIT_ITERS
  # overrides the iteration count (tests set it low to exercise fail-open).
  _max=${ROGUE_FLUSH_WAIT_ITERS:-20}
  while [ "$_n" -lt "$_max" ]; do
    _size=$(wc -c < "$_wtp" 2>/dev/null | tr -d '[:space:]')
    [ -n "$_size" ] || _size=0
    if [ "$_n" -gt 0 ] && [ "$_size" = "$_prev_size" ]; then
      return 0
    fi
    _prev_size="$_size"
    sleep 0.1
    _n=$((_n + 1))
  done
  return 0
}

# Read a top-level JSON string field out of the raw hook body.
#
# NOT line-based, on purpose: the body is squashed to one line first because a
# pretty-printed payload puts the key and its value on separate lines, and a
# per-line sed then matches nothing. JSON's optional `\/` escape is undone for
# the same reason — a serializer that emits it yields a path that fails every
# file test. Both modes failed silently, which is how the IDE surface came to
# post 100% of its Pre/PostInvocation events with no transcript at all.
#
# On a compact body this is exactly the previous behaviour (one line, greedy
# `.*` → last occurrence of the key).
# $1 = field name, $2 = body.
json_field() {
  printf '%s' "$2" \
    | tr '\n\r\t' '   ' \
    | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
    | sed 's|\\/|/|g'
}

# Which Antigravity product fired this event, from the state dir its transcript
# lives in: the `-ide` dir is the Antigravity IDE, the bare one is Antigravity 2.0
# (both current products, independently versioned). Slash-anchored and ordered
# specific → general because the bare segment is a prefix of the other two.
# Mirrors the backend's surfaceFromTranscript (antigravity-hook-parser.ts); an
# unattributable payload yields empty so the caller keeps its own fallback.
surface_from_transcript() {
  case "$1" in
    */antigravity-cli/*) printf 'antigravity_cli' ;;
    */antigravity-ide/*) printf 'antigravity_ide' ;;
    */antigravity/*)     printf 'antigravity' ;;
  esac
}

# The surfaces disagree on which file transcriptPath names: the IDE points at
# `transcript.jsonl`, the 2.0 app and the `agy` CLI at `transcript_full.jsonl`.
# Both are written to the same logs dir with the same row schema, so the sibling
# is a valid substitute when the named file can't be read.
transcript_sibling() {
  case "$1" in
    */transcript.jsonl)      printf '%stranscript_full.jsonl' "${1%transcript.jsonl}" ;;
    */transcript_full.jsonl) printf '%stranscript.jsonl' "${1%transcript_full.jsonl}" ;;
  esac
}

# Echo a readable transcript path (the named one, else its sibling), waiting
# briefly for one to appear. The wait is not paranoia: a brand-new conversation
# creates its transcript ~1s AFTER the first PreInvocation fires (verified on
# the IDE surface), so returning empty immediately drops the FIRST prompt of
# every session — the one that opens the audit trail. ~2s cap, well inside the
# 30s hook budget; ROGUE_TRANSCRIPT_WAIT_ITERS overrides it for tests.
resolve_transcript_path() {
  _rtp="$1"
  _rta=$(transcript_sibling "$_rtp")
  _rtn=0
  _rtmax=${ROGUE_TRANSCRIPT_WAIT_ITERS:-20}
  while :; do
    [ -r "$_rtp" ] && { printf '%s' "$_rtp"; return 0; }
    [ -n "$_rta" ] && [ -r "$_rta" ] && { printf '%s' "$_rta"; return 0; }
    [ "$_rtn" -ge "$_rtmax" ] && return 1
    sleep 0.1
    _rtn=$((_rtn + 1))
  done
}

augment_with_transcript() {
  _body="$1"
  _tp=$(json_field transcriptPath "$_body")
  [ -n "$_tp" ] || { log "tail=none reason=no-path"; printf '%s' "$_body"; return; }
  _rp=$(resolve_transcript_path "$_tp") || {
    log "tail=none reason=unreadable path=$_tp"
    printf '%s' "$_body"; return
  }
  wait_for_transcript_flush "$_rp"
  _b64=$(tail -c 262144 "$_rp" 2>/dev/null | base64 2>/dev/null | tr -d '\r\n')
  [ -n "$_b64" ] || { log "tail=none reason=empty path=$_rp"; printf '%s' "$_body"; return; }
  log "tail=${#_b64} path=$_rp"
  printf '%s,"transcriptTailB64":"%s"}' "${_body%\}}" "$_b64"
}

# ── IDE prompt recovery ────────────────────────────────────────────────────
# The IDE writes transcript.jsonl only at invocation boundaries and Stop, so at
# PreInvocation the pending prompt is NOT on disk (verified: six 10s hook windows
# held while rows sat pending in memory, zero change). It IS already committed to
# Antigravity's own conversation store, so db-prompt.mjs reads it there and we
# append it for the backend to evaluate. IDE only — the 2.0 app and the CLI write
# the transcript live, so their existing tail already carries the prompt.
#
# Off by default for anything but the IDE, and killable without a reinstall
# (`DB_PROMPT_MODE`, set in load_env):
#   ROGUE_ANTIGRAVITY_DB_PROMPT=0    never read
#   ROGUE_ANTIGRAVITY_DB_PROMPT=log  read and log, never attach

# Absolute path of a runtime that can load node:sqlite, or empty. The resolver
# caches its answer (including "none"), so the steady-state cost is one file read.
resolve_js_runtime() {
  [ -r "${PLUGIN_ROOT}/scripts/resolve-runtime.sh" ] || return 0
  sh "${PLUGIN_ROOT}/scripts/resolve-runtime.sh" "$1" 2>/dev/null
}

# ── What the store actually delivered this turn ─────────────────────────────
# `rogueDbPromptCapable` describes the MACHINE, not the turn, and the backend reads
# it on `Stop` as "this turn already arrived, don't re-emit the tail". That is right
# for a successful read and wrong for a failed one: a locked DB, schema drift or a
# blown deadline would cost the whole turn silently, with the tail in hand.
#
# So a read that could NOT reach the content (db-prompt.mjs exit 3, as opposed to
# exit 0 = "read, nothing new") leaves a marker here, and `Stop` turns whatever it
# finds into `rogueDbPromptMissed` / `rogueDbStepsMissed` so the backend rebuilds
# exactly the missing halves from the transcript. No marker means delivered, which
# keeps the behaviour identical for an older backend that ignores these fields.
#
# Markers are per conversation (under `MISS_DIR`, set in load_env) and consumed at
# `Stop`. A crash before `Stop` leaves one behind and costs the NEXT turn a
# duplicated message rather than a lost one — the safe direction.

# Conversation ids are UUIDs; anything else is filtered out rather than trusted,
# because this value becomes a path component.
miss_marker() {
  _mkid=$(printf '%s' "$1" | tr -dc '0-9a-zA-Z_-' | cut -c1-64)
  [ -n "$_mkid" ] || return 1
  printf '%s/%s.missed-%s' "$MISS_DIR" "$_mkid" "$2"
}

# $1 = kind (prompt|steps), $2 = body.
mark_store_miss() {
  _msf=$(miss_marker "$(json_field conversationId "$2")" "$1") || return 0
  mkdir -p "$MISS_DIR" 2>/dev/null || return 0
  : > "$_msf" 2>/dev/null || true
}

# A later read of the same half succeeded, so the content IS delivered and the
# earlier failure is void. Without this a transient lock or deadline on the first
# invocation of a turn would still make `Stop` replay that half from the transcript,
# duplicating what a subsequent invocation delivered. Cleared only on a real attach:
# "nothing new" says nothing about what an earlier failure missed.
# $1 = kind (prompt|steps), $2 = body.
clear_store_miss() {
  _csf=$(miss_marker "$(json_field conversationId "$2")" "$1") || return 0
  [ -f "$_csf" ] || return 0
  rm -f "$_csf" 2>/dev/null || true
}

# Mark that this machine CAN recover a prompt pre-send, and report whatever the
# store failed to deliver this turn. Rides `Stop`: it re-reads the whole turn from
# the transcript, and without the capability flag the backend cannot know the prompt
# was already recorded at `PreInvocation` — it re-emits it and every user message
# lands twice (observed on a live IDE session before this existed).
mark_db_prompt_capable() {
  _mbody="$1"
  [ "$DB_PROMPT_MODE" = "0" ] && { printf '%s' "$_mbody"; return; }
  _mtp=$(json_field transcriptPath "$_mbody")
  case "$_mtp" in */antigravity-ide/*) ;; *) printf '%s' "$_mbody"; return ;; esac

  # Consume the turn's markers even if no runtime resolves any more, so a stale one
  # cannot leak into a later turn.
  _mmissed=""
  _mcid=$(json_field conversationId "$_mbody")
  for _mkind in prompt steps; do
    _mmf=$(miss_marker "$_mcid" "$_mkind") || continue
    [ -f "$_mmf" ] || continue
    rm -f "$_mmf" 2>/dev/null || true
    case "$_mkind" in
      prompt) _mmissed="${_mmissed},\"rogueDbPromptMissed\":true" ;;
      steps)  _mmissed="${_mmissed},\"rogueDbStepsMissed\":true" ;;
    esac
  done

  [ -n "$(resolve_js_runtime "$_mtp")" ] || { printf '%s' "$_mbody"; return; }
  [ -n "$_mmissed" ] && log "dbstore=stop missed=${_mmissed#,}"
  printf '%s%s,"rogueDbPromptCapable":true}' "${_mbody%\}}" "$_mmissed"
}

# Read from the store and append the result, plus `rogueDbPromptCapable` (whether
# this machine can read it at all — the backend needs that to know whether `Stop`
# should still carry the turn). Fail-open at every step: any problem leaves the
# body exactly as it was.
#
# $1 = reader mode: `prompt` (PreInvocation — the pending prompt) or `steps`
#      (PostInvocation — what the finished invocation produced, i.e. the tool
#      results the NEXT model call would read).
# $2 = payload field to attach it as. $3 = body.
augment_from_store() {
  _mode="$1"; _field="$2"; _body="$3"
  _dbtp=$(json_field transcriptPath "$_body")
  case "$_dbtp" in */antigravity-ide/*) ;; *) printf '%s' "$_body"; return ;; esac
  [ "$DB_PROMPT_MODE" = "0" ] || [ -z "$_dbtp" ] && { printf '%s' "$_body"; return; }

  _rt=$(resolve_js_runtime "$_dbtp")
  if [ -z "$_rt" ]; then
    log "dbstore=none mode=$_mode reason=no-runtime"
    printf '%s' "$_body"; return
  fi

  # Hard wall independent of the reader's own deadline: these events gate the
  # developer's turn, so a hung runtime must never hold one open. The reader's
  # exit status is what separates "read it, nothing new" (0) from "could not read
  # it" (non-zero, including 137 from the kill below), so it is carried out of the
  # subshell explicitly — otherwise `$?` would be the watchdog's `kill`.
  _out=$(printf '%s' "$_body" | ELECTRON_RUN_AS_NODE=1 "$_rt" --no-warnings \
    --experimental-sqlite "${PLUGIN_ROOT}/scripts/db-prompt.mjs" "$_mode" 2>/dev/null &
    _pid=$!
    # `>/dev/null` is load-bearing, not tidiness: the watchdog inherits this
    # command substitution's stdout, and `$(...)` only returns at EOF on that
    # pipe. `kill "$_watch"` signals the subshell, not the `sleep` it forked, so
    # under bash-as-/bin/sh the orphaned `sleep` holds the write end open and
    # EVERY store read — including a 20ms one — blocks for the full second,
    # against the reader's own 150ms deadline. dash happens not to show it.
    ( sleep 1; kill -9 "$_pid" 2>/dev/null ) >/dev/null 2>&1 &
    _watch=$!
    wait "$_pid" 2>/dev/null
    _rc=$?
    kill "$_watch" 2>/dev/null
    exit "$_rc")
  _read_rc=$?

  # The reader's whole stdout vocabulary is base64-or-nothing. Anything else is
  # discarded unread, so its output can never become a hook decision.
  case "$_out" in
    "" ) if [ "$_read_rc" -eq 0 ]; then
           # Read fine, nothing to send: the ordinary case on a turn's later
           # invocations, which have no new prompt. The turn is accounted for.
           log "dbstore=miss mode=$_mode reason=nothing-new capable=1"
         else
           # The content is there and we did not get it, so `Stop` must still
           # carry this turn from the transcript.
           log "dbstore=fail mode=$_mode rc=$_read_rc capable=1"
           mark_store_miss "$_mode" "$_body"
         fi
         printf '%s,"rogueDbPromptCapable":true}' "${_body%\}}"; return ;;
    *[!A-Za-z0-9+/=]* ) log "dbstore=none mode=$_mode reason=bad-output"
         # Nothing is attached and no capability is claimed here, but `Stop` claims
         # it from the runtime alone — so record the miss or the turn is lost.
         mark_store_miss "$_mode" "$_body"
         printf '%s' "$_body"; return ;;
  esac

  if [ "$DB_PROMPT_MODE" = "log" ]; then
    log "dbstore=hit mode=$_mode len=${#_out} (not attached)"
    # Diagnostic mode reads without attaching, so nothing was delivered: recording
    # the miss is what keeps it observational instead of blinding the IDE.
    mark_store_miss "$_mode" "$_body"
    printf '%s,"rogueDbPromptCapable":true}' "${_body%\}}"
    return
  fi
  log "dbstore=hit mode=$_mode len=${#_out} runtime=$(basename "$_rt")"
  # This half is delivered, so any earlier failure for it no longer costs anything.
  clear_store_miss "$_mode" "$_body"
  printf '%s,"%s":"%s","rogueDbPromptCapable":true}' "${_body%\}}" "$_field" "$_out"
}

# ── Subagent re-attribution ────────────────────────────────────────────────
# An Antigravity subagent (define_subagent → invoke_subagent) runs as its OWN
# conversation: its PreInvocation/PreToolUse/PostToolUse/PostInvocation/Stop all
# arrive with conversationId = the subagent's own id and carry NO parent
# reference (verified: the payload has no parentConversationId / agentId field).
# Persisted verbatim they become an ORPHANED audit session instead of appearing
# in the conversation that spawned them.
#
# The link lives in the PARENT's transcript: the `invoke_subagent` tool RESULT
# row (type INVOKE_SUBAGENT) lists each spawned conversationId, and the parent
# conversation id IS that transcript's directory name. That row is written when
# the tool completes — i.e. before the subagent's first hook can fire — so a
# plain lookup suffices and no flush retry is needed.
#
# Unlike Copilot (whose subagent ids are `toolu_…`/`call_…`, distinguishable at a
# glance), an Antigravity subagent id is an ordinary UUID — there is no way to
# tell from the payload whether a lookup is even worth doing. So the verdict is
# cached per conversation, BOTH ways: a "main" marker for ordinary conversations
# stops them re-scanning on every one of their ~18 events per turn. One scan per
# conversation, ~25ms.
#
# Fail-open: unresolved → body untouched (today's orphaned behaviour, never
# worse). `SUBAGENT_ID` / `SUBAGENT_NAME` are the globals this writes for the POST
# headers; `BRAIN_DIR` / `SUBMAP_DIR` are set in load_env.

# The brain dir holding this event's own transcript — which is also where its
# PARENT conversation lives, since a subagent runs on the surface that spawned
# it. Derived per event because each product has its own brain dir, and the
# hardcoded default above names only the CLI's: subagents spawned in the IDE or
# the 2.0 app resolved no parent at all and orphaned into their own session.
# transcriptPath is `<brain>/<conversationId>/.system_generated/logs/…`.
brain_dir_from_transcript() {
  case "$1" in
    */brain/*/.system_generated/logs/*) printf '%s/brain' "${1%%/brain/*}" ;;
  esac
}

# Display name from the spawning call: `invoke_subagent`'s args carry a `Role`
# per subagent ("Cat Rhymer"), and the INVOKE_SUBAGENT result row lists the
# conversationIds in the SAME order (verified — the 1st id's own prompt is the
# 1st Prompt). So the name is the Nth Role where N is the id's position. This is
# available at spawn time, which matters: it is the only source present for a
# subagent's EARLY events.
#
# Caveat: with two `invoke_subagent` calls in one conversation the two lists are
# read in file order, which is not step order (see the sort in
# decodeTranscriptTail's counterpart), so positions could misalign. That affects
# only the display name — `x-rogue-subagent-id` is always exact.
# $1 = parent conversation id, $2 = subagent conversation id.
subagent_role_name() {
  _tf="$BRAIN_DIR/$1/.system_generated/logs/transcript_full.jsonl"
  [ -r "$_tf" ] || return 0
  # Position of $2 among the spawned ids. The ids sit inside the row's
  # JSON-STRING content, so their quotes are backslash-escaped — match the bare
  # UUID rather than a quoted one.
  _idx=$(grep '"INVOKE_SUBAGENT"' "$_tf" 2>/dev/null \
    | grep -o 'conversationId[^0-9a-f]*[0-9a-f-]\{36\}' \
    | grep -o '[0-9a-f-]\{36\}' \
    | grep -n "^$2\$" 2>/dev/null | head -1 | cut -d: -f1)
  [ -n "$_idx" ] || return 0
  grep '"invoke_subagent"' "$_tf" 2>/dev/null \
    | grep -o '"Role":"[^"]*"' \
    | sed -n "${_idx}p" \
    | sed 's/^"Role":"//; s/"$//'
}

# Fallback display name, from the parent's delivered-message records:
# messages/<uuid>.json carries {"sender": <child>, "renderDetails":
# {"messageTitle": "Message from <Role> (<TypeName>)"}}. Only exists once the
# subagent has reported back, so this is the late-but-richer source.
# $1 = parent conversation id, $2 = subagent conversation id.
subagent_message_name() {
  _md="$BRAIN_DIR/$1/.system_generated/messages"
  [ -d "$_md" ] || return 0
  for _mf in "$_md"/*.json; do
    [ -r "$_mf" ] || continue
    grep -q "\"$2\"" "$_mf" 2>/dev/null || continue
    sed -n 's/.*"messageTitle"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_mf" 2>/dev/null \
      | sed 's/^Message from //' | head -1
    return 0
  done
}

# $1 = parent conversation id, $2 = subagent conversation id.
subagent_display_name() {
  _nm=$(subagent_role_name "$1" "$2")
  [ -n "$_nm" ] || _nm=$(subagent_message_name "$1" "$2")
  printf '%s' "$_nm"
}

# Echo "<parentConversationId>\n<displayName>" when $1 was spawned as a subagent.
# Two-stage on purpose: the broad grep prunes to candidate files in one process
# (fast), then the INVOKE_SUBAGENT filter rejects the false positives — a
# conversation id also appears inside other conversations' CONVERSATION_HISTORY
# summaries, which must NOT be read as a parent link.
resolve_subagent_parent() {
  _sub="$1"
  [ -d "$BRAIN_DIR" ] || return 1
  for _f in $(grep -l "$_sub" "$BRAIN_DIR"/*/.system_generated/logs/transcript_full.jsonl 2>/dev/null); do
    grep '"INVOKE_SUBAGENT"' "$_f" 2>/dev/null | grep -q "$_sub" || continue
    _pd=${_f%/.system_generated/logs/transcript_full.jsonl}
    _parent=${_pd##*/}
    [ -n "$_parent" ] && [ "$_parent" != "$_sub" ] || continue
    printf '%s\n%s' "$_parent" "$(subagent_display_name "$_parent" "$_sub")"
    return 0
  done
  return 1
}

# Rewrite BODY's subagent conversationId to its parent and set SUBAGENT_ID/NAME.
reattribute_subagent() {
  _cid=$(json_field conversationId "$BODY")
  [ -n "$_cid" ] || return
  # Vendor-supplied text that becomes BOTH a path component and part of a `sed`
  # s/// expression below. Antigravity ids are UUIDs, so anything else is not an
  # id we can act on: a `/` would terminate the sed expression (stderr noise,
  # which Antigravity logs at E level for every event, and a silently skipped
  # rewrite that orphans the subagent), and `..` would escape SUBMAP_DIR. Same
  # allowlist the Copilot plugin applies to its tool-call ids; bail rather than
  # sanitize, since a mangled id must not alias another conversation's cache.
  case "$_cid" in
    *[!0-9A-Za-z_-]*) log "subagent=skip reason=bad-id"; return ;;
  esac

  # Search the surface's own brain dir; an explicit override still wins.
  if [ -z "${ROGUE_ANTIGRAVITY_BRAIN_DIR:-}" ]; then
    _bd=$(brain_dir_from_transcript "$(json_field transcriptPath "$BODY")")
    [ -n "$_bd" ] && BRAIN_DIR="$_bd"
  fi

  _cache_file="$SUBMAP_DIR/$_cid"
  _map=""
  if [ -r "$_cache_file" ]; then
    _map=$(cat "$_cache_file" 2>/dev/null)
    [ "$_map" = "main" ] && return          # known ordinary conversation
  else
    _map=$(resolve_subagent_parent "$_cid") || _map=""
    mkdir -p "$SUBMAP_DIR" 2>/dev/null
    # Cache the negative too, so an ordinary conversation scans only once.
    printf '%s' "${_map:-main}" > "$_cache_file" 2>/dev/null
  fi
  [ -n "$_map" ] && [ "$_map" != "main" ] || return

  _parent=$(printf '%s' "$_map" | sed -n '1p')
  SUBAGENT_NAME=$(printf '%s' "$_map" | sed -n '2p')
  [ -n "$_parent" ] || return
  # It lands in the sed REPLACEMENT, where `/` and `&` are equally special.
  # It is a brain-dir name so it should already be a UUID; bail if it is not.
  case "$_parent" in
    *[!0-9A-Za-z_-]*) log "subagent=skip reason=bad-parent"; return ;;
  esac
  SUBAGENT_ID="$_cid"
  # Tolerate whitespace around the key/colon (a pretty-printed payload) and
  # normalize to compact form; a non-matching rewrite would leave the body
  # orphaned even though the parent was resolved.
  BODY=$(printf '%s' "$BODY" | sed "s/\"conversationId\"[[:space:]]*:[[:space:]]*\"$_cid\"/\"conversationId\":\"$_parent\"/")
  log "subagent=$_cid parent=$_parent name=$(sanitize "$SUBAGENT_NAME")"
}

# ── main's steps ───────────────────────────────────────────────────────────

# Not configured: never POST without a key. Emit the per-event fail-open
# default so PreToolUse still resolves to an explicit allow decision. Exits the
# script, deliberately BEFORE stdin is read: there is nothing to do with it.
require_api_key() {
  [ -n "${ROGUE_API_KEY:-}" ] && return 0
  log "outcome=unconfigured"
  fail_open_default
  exit 0
}

# ROGUE_ACTOR_EMAIL / ROGUE_ACTOR_NAME, resolved by the shared cascade
# (env → git config --global → hostname/whoami).
load_actor() {
  [ -r "${PLUGIN_ROOT}/scripts/actor.sh" ] && . "${PLUGIN_ROOT}/scripts/actor.sh"
  return 0
}

# ROGUE_INSTALL_HOST / ROGUE_INSTALL_VERSION (shared with heartbeat.sh) plus the
# surface, which only this script can resolve — it reads the event's
# transcriptPath, exactly as the heartbeat's is derived. Sent as headers on every
# event so the fleet roster's row stays fresh between session starts, which are
# the only moments the heartbeat runs. Called after read_body: the surface needs
# the payload.
load_install_id() {
  [ -r "${PLUGIN_ROOT}/scripts/install-id.sh" ] && . "${PLUGIN_ROOT}/scripts/install-id.sh"
  # A degraded value is still sent (never a hard failure — see install-id.sh), but
  # it is worth knowing about: an "unknown" host or version means this install
  # reports itself imprecisely to the fleet roster.
  [ -n "${ROGUE_INSTALL_ID_ERROR:-}" ] && log "error=install-id $ROGUE_INSTALL_ID_ERROR"
  # ONE resolution, four consumers: the log token, the x-rogue-agent header, the
  # heartbeat's roster agent and enrich_body's IDE-only branch. transcriptPath is
  # the only reliable signal (three products share one install, so a filesystem
  # probe cannot tell which is running), and it is absent from some events.
  SURFACE=$(surface_from_transcript "$(json_field transcriptPath "$BODY")")
  # Two variables off that one call, because the two consumers differ on what an
  # unattributable payload means. The LOG token stays empty, and the line then
  # carries no `surface=` at all rather than claiming one. The HEADER and the
  # roster row are required fields, so they default to the 2.0 app - the same guess
  # the backend's parser makes, so the row matches the events it stores.
  ROGUE_INSTALL_AGENT="${SURFACE:-antigravity}"
  return 0
}

# Buffer stdin so we can enrich it (PreInvocation/PostInvocation/Stop) before
# POSTing.
read_body() {
  BODY="$(cat)"
}

# Heartbeat, fired detached so the hook itself returns immediately regardless of
# heartbeat.sh's own latency.
#
# TWO TRIGGERS, because Antigravity has no SessionStart event and `invocationNum == 0`
# is NOT one: it resets on every new prompt, so gating on it alone sent an
# unthrottled beacon per turn, and it fires BEFORE the turn's own transcript rows
# exist, so the log shipper riding along uploaded only turns 1..N-1.
#
#   SessionStart  first invocation of a NEW CONVERSATION - invocationNum 0 AND
#                 initialNumSteps <= 1. Never throttled, so a fresh install or a new
#                 conversation reaches the roster at once.
#   Stop          every agent run's end: the per-TURN trigger, throttled by
#                 scripts/beacon.sh, and late enough that the turn's rows are on disk
#                 for the shipper.
#
# A continuation invocation (invocationNum 0 with more steps already recorded, e.g.
# `agy -c`) deliberately fires NOTHING here - its Stop covers it, and treating it as
# a session start would hand an unthrottled beacon to every resumed conversation.
#
# The surface is passed along because only the hook can know it: three products
# share this one install, each with its own state dir, and the surface is
# readable from the payload's transcriptPath (mirrors the backend's
# surfaceFromTranscript). heartbeat.sh alone can only guess from the filesystem,
# and on a machine with more than one installed it guesses wrong — collapsing
# every surface into one roster row.
# Pass the SAME surface the event headers carry (load_install_id, which runs
# first), never a freshly-derived one. An unattributable payload yields an empty
# surface, and heartbeat.sh's own fallback then sniffs the filesystem and picks
# antigravity_cli whenever `agy` is installed — so this event would report
# `antigravity` while its heartbeat reported `antigravity_cli`, and one install
# would own two roster rows. One resolution, one row.
maybe_heartbeat() {
  _hb_trigger=""
  case "$EVENT" in
    Stop) _hb_trigger="Stop" ;;
    PreInvocation)
      case "$BODY" in
        *'"invocationNum":0'*|*'"invocationNum": 0'*)
          # The step count is EXTRACTED and compared numerically, never glob-matched.
          # A glob is what a first attempt used and it is wrong in a way that reads as
          # correct: `*'"initialNumSteps":1'*` also matches 18, so every continuation
          # of a long conversation looked like a fresh one and got an unthrottled
          # beacon. Anchoring on the terminator instead would have to enumerate `,`
          # and `}` and both spacings, and still break on pretty-printed JSON.
          #
          # The boundary is the count BEFORE this invocation: 0 on a brand-new
          # conversation, 1 once the pending prompt has been recorded as a step.
          _hb_steps="$(printf '%s' "$BODY" \
            | sed -n 's/.*"initialNumSteps"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
            | head -1)"
          case "${_hb_steps:-}" in
            ''|*[!0-9]*) ;;
            *) [ "$_hb_steps" -le 1 ] && _hb_trigger="SessionStart" ;;
          esac ;;
      esac ;;
  esac
  [ -n "$_hb_trigger" ] || return 0
  # ROGUE_INSTALL_AGENT, not SURFACE: an unattributable payload leaves the log token
  # empty, and an empty first argument makes heartbeat.sh fall back to sniffing the
  # filesystem - which picks antigravity_cli whenever `agy` is installed, so the event
  # would report `antigravity` while its own heartbeat reported `antigravity_cli` and
  # one install would own two roster rows. Both come from the one resolution in
  # load_install_id; only this consumer needs the default applied.
  ( nohup sh "${PLUGIN_ROOT}/scripts/heartbeat.sh" "$ROGUE_INSTALL_AGENT" "$_hb_trigger" \
      </dev/null >/dev/null 2>&1 & )
}

# Enrichment is per surface, because the surfaces differ in WHEN the transcript
# exists:
#   2.0 app / agy CLI — written live, so every one of the three events can read
#     the pending turn from the tail, exactly as before.
#   IDE — written only at invocation boundaries and Stop. Tailing it on
#     Pre/PostInvocation can only ever return the PREVIOUS turn, and waiting for
#     the current one cannot work (measured: the file appears ~4s later, at Stop),
#     so the wait was pure latency on the event that blocks the developer. The
#     prompt comes from the conversation store instead.
enrich_body() {
  _surface="$SURFACE"
  if [ "$_surface" = "antigravity_ide" ]; then
    case "$EVENT" in
      # The pending prompt, before the model call that would consume it.
      PreInvocation)  BODY="$(augment_from_store prompt rogueDbPromptB64 "$BODY")" ;;
      # What the finished invocation produced — its prose and, crucially, the tool
      # results the NEXT model call would read. This event owns `terminate`, so it is
      # the last point at which untrusted tool output can be stopped before the model
      # sees it (the transcript does not have it until the following boundary).
      PostInvocation) BODY="$(augment_from_store steps rogueDbStepsB64 "$BODY")" ;;
      # Kept as the fallback source for machines that cannot read the store; when the
      # capability flag is set the backend ignores it, because everything already
      # arrived from the store at the two events above.
      Stop)           BODY="$(augment_with_transcript "$BODY")"
                      BODY="$(mark_db_prompt_capable "$BODY")" ;;
    esac
  else
    case "$EVENT" in
      PreInvocation|PostInvocation|Stop) BODY="$(augment_with_transcript "$BODY")" ;;
    esac
  fi
}

# Capture body + HTTP status. -w appends a final line "<code>"; on any
# transport failure curl exits non-zero and the code is 000. Relay the body
# ONLY on a clean HTTP 200 so an error page (401/404/500) is never handed to
# Antigravity as a decision.
# The agent tag rides in HEADERS, never in the body: the POSTed event must stay
# byte-identical to what Antigravity handed us, so `rawPayload` is the vendor's
# own event and nothing we synthesised. (Copilot puts it in the body; that
# difference is known and deliberate here.)
#
# The name is base64 so an arbitrary subagent `Role` — accents, emoji — cannot
# produce an invalid header value; the id is a bare UUID and needs no encoding.
# Both are omitted entirely, never sent empty, on main-agent events. Passed via a
# positional set — the function's own, not the script's — so the curl call stays a
# single expression.
post_and_relay() {
  set --
  if [ -n "$SUBAGENT_ID" ]; then
    set -- -H "x-rogue-agent-id: $SUBAGENT_ID"
    if [ -n "$SUBAGENT_NAME" ]; then
      _agent_name_b64=$(printf '%s' "$SUBAGENT_NAME" | base64 2>/dev/null | tr -d '\r\n')
      [ -n "$_agent_name_b64" ] && set -- "$@" -H "x-rogue-agent-name-b64: $_agent_name_b64"
    fi
  fi

  _raw=$(printf '%s' "$BODY" | curl -sS -X POST "$URL" \
    -H "x-rogue-api-key: $ROGUE_API_KEY" \
    -H "x-rogue-event: $EVENT" \
    -H "x-rogue-actor-email: $ROGUE_ACTOR_EMAIL" \
    -H "x-rogue-actor-name: $ROGUE_ACTOR_NAME" \
    -H "x-rogue-host: $ROGUE_INSTALL_HOST" \
    -H "x-rogue-version: $ROGUE_INSTALL_VERSION" \
    -H "x-rogue-agent: $ROGUE_INSTALL_AGENT" \
    "$@" \
    -H 'Content-Type: application/json' \
    --data-binary @- --max-time 15 -w '\n%{http_code}')
  _rc=$?
  _code=$(printf '%s' "$_raw" | tail -n1)
  _resp=$(printf '%s' "$_raw" | sed '$d')

  log "http=$_code rc=$_rc raw=$(sanitize "$_resp" | head -c 400)"

  # Fail-open on transport error, any non-200, or an empty body: emit the
  # per-event default rather than relaying garbage as a decision.
  if [ "$_rc" -ne 0 ] || [ "$_code" != "200" ] || [ -z "$_resp" ]; then
    log "outcome=allow http=$_code rc=$_rc"
    fail_open_default
    return 0
  fi

  # rogue-api already returns the correct native Antigravity shape; relay it
  # verbatim.
  printf '%s' "$_resp"
}

# ── main ───────────────────────────────────────────────────────────────────
# The whole hook, in the order the steps must happen. Every step is fail-open on
# its own; the two that can end the run early (`stand_down_under_git_bash`,
# `require_api_key`) exit 0 with the right stdout for their case.
main() {
  EVENT="$1"

  stand_down_under_git_bash
  locate_plugin_root
  load_env               # sources the env files, then every default derived from them
  require_api_key        # exits before stdin is read when there is no key
  load_actor
  read_body
  load_install_id        # host + version + the surface, resolved once from the payload

  maybe_heartbeat
  # Re-attribute BEFORE enriching: augment_with_transcript re-closes the JSON
  # object by hand, so mutating conversationId afterwards would have to skip past
  # the appended base64 blob.
  reattribute_subagent
  enrich_body

  post_and_relay
  # This script MUST always exit 0: a block is carried in the relayed JSON body
  # on stdout, never in the exit code.
  exit 0
}

main "$@"
