#!/usr/bin/env bash
# Usage: hook.sh <EventName>
# Reads one Codex hook event JSON on stdin, POSTs it to the rogue-api
# /hooks/openai route, relays the native Codex response verbatim on stdout.
# Fail-open: any failure → "{}". Logs every invocation to $ROGUE_LOG_FILE
# (default ~/.rogue/logs/codex.log).
#
# Unlike the Claude bridge this is a PURE RELAY: no block-detection regex and no
# security-alert modal. Codex surfaces the native deny shape itself (the Claude
# modal exists only because the Claude app doesn't display the block reason).

EVENT="$1"

# Codex sets PLUGIN_ROOT to the installed plugin directory.
PLUGIN_ROOT="${PLUGIN_ROOT:-}"

# The first env file holding ROGUE_API_KEY is used alone: machine, bundled, user.
for _env_file in /etc/rogue/env "${PLUGIN_ROOT}/env" "$HOME/.rogue-env"; do
  if [ -r "$_env_file" ] && grep -Eq "^[[:space:]]*(export[[:space:]]+)?ROGUE_API_KEY=[\"']?[^\"'[:space:]]" "$_env_file"; then
    . "$_env_file"; break
  fi
done

# Log destination — ONE FILE PER AGENT. Every Rogue plugin shares ~/.rogue, so a
# machine running Codex + Claude Code + Cursor + … used to interleave all of them
# into a single hook.log with no way to tell whose line was whose. Precedence:
# explicit file → directory override → per-agent default.
ROGUE_LOG_DIR="${ROGUE_LOG_DIR:-$HOME/.rogue/logs}"
ROGUE_LOG_FILE="${ROGUE_LOG_FILE:-$ROGUE_LOG_DIR/codex.log}"
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
    # `${SURFACE:+ surface=$SURFACE}` expands to NOTHING when the slug is empty, so
    # an undetermined surface leaves the line exactly as older versions wrote it -
    # never `surface=` and never `surface=unknown`.
    printf '%s provider=codex%s event=%s %s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SURFACE:+ surface=$SURFACE}" \
      "$EVENT" "$*" >> "$ROGUE_LOG_FILE" 2>/dev/null )
}
sanitize() { printf '%s' "$1" | tr -d '\000-\037\177'; }

# Which SURFACE of Codex wrote this - codex_app or codex_cli. Resolved HERE, above
# the first log() call, so even an unconfigured install stamps it; the same value is
# reused for the x-rogue-agent header below, and heartbeat.sh reads the same table
# (scripts/surface.sh) so a log line and the roster row for one session cannot name
# different surfaces. Guarded: no surface.sh, no token - never a broken hook.
SURFACE=""
if [ -r "${PLUGIN_ROOT}/scripts/surface.sh" ]; then
  . "${PLUGIN_ROOT}/scripts/surface.sh"
  SURFACE=$(codex_surface_slug 2>/dev/null)
fi

if [ -z "${ROGUE_API_KEY:-}" ]; then
  log "outcome=unconfigured"
  echo '{}'
  exit 0
fi

. "${PLUGIN_ROOT}/scripts/actor.sh"
# Host + version + surface, resolved exactly as heartbeat.sh does. Sent on every
# event so the fleet roster's row stays fresh between session starts, which are
# the only moments the heartbeat runs. See install-id.sh.
. "${PLUGIN_ROOT}/scripts/install-id.sh"
# A degraded value is still sent (never a hard failure — see install-id.sh), but
# it is worth knowing about: an "unknown" host or version means this install
# reports itself imprecisely to the fleet roster.
[ -n "${ROGUE_INSTALL_ID_ERROR:-}" ] && log "error=install-id $ROGUE_INSTALL_ID_ERROR"

# ── per-turn presence heartbeat + log ship (Stop only) ─────────────────────
# SessionStart's heartbeat is spawned by hooks.json; this is its per-TURN twin, and
# it is fired from HERE rather than from a second hooks.json entry on purpose: Codex
# hashes the whole hook definition and skips untrusted command hooks until the user
# reviews them via /hooks, so adding an entry would silently disable every Rogue
# hook on every existing install until each user re-approved. The dispatcher already
# runs on Stop, so this leaves the command strings byte-identical and trust intact.
#
# Stop exists as a trigger because a session left open for days used to produce
# exactly one beacon and one log upload for its whole lifetime - the roster row went
# stale and the hook log sat on disk unshipped. heartbeat.sh throttles the beacon
# itself (scripts/beacon.sh, 900s default) and the shipper throttles itself, so a
# per-turn trigger is not a per-turn request.
#
# DETACHED double-fork with every fd redirected: this is the synchronous dispatcher
# and Codex is waiting on our stdout for the relayed decision, so nothing here may
# be awaited. </dev/null in particular - the child must not touch the event JSON
# still queued on our own stdin.
#
# PLUGIN_ROOT is EXPORTED explicitly rather than assumed. heartbeat.sh reads it from
# its own environment (`PLUGIN_ROOT="${PLUGIN_ROOT:-}"`) and everything it needs
# hangs off it - the bundled env file, actor.sh, surface.sh, the manifest version and
# the shipper. Codex does put it in the environment today, but the hooks.json entry
# ALSO substitutes it as a `${PLUGIN_ROOT}` template placeholder, so a build that
# only did the substitution would leave the child rootless: an unversioned beacon
# that ships nothing, failing silently.
if [ "$EVENT" = "Stop" ] && [ -r "${PLUGIN_ROOT}/scripts/heartbeat.sh" ]; then
  ( export PLUGIN_ROOT
    nohup sh "${PLUGIN_ROOT}/scripts/heartbeat.sh" Stop </dev/null >/dev/null 2>&1 & )
fi

URL="${ROGUE_API_URL:-${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/openai}"

# Capture body + HTTP status. -w appends a final line "<code>"; on any curl/transport
# failure curl exits non-zero and the code is 000. We relay the body ONLY on a clean
# HTTP 200 so an error page (401/404/500) is never handed to Codex as a hook decision.
RAW=$(curl -sS -X POST "$URL" \
  -H "x-rogue-api-key: $ROGUE_API_KEY" \
  -H "x-rogue-event: $EVENT" \
  -H "x-rogue-agent: $ROGUE_INSTALL_AGENT" \
  -H "x-rogue-host: $ROGUE_INSTALL_HOST" \
  -H "x-rogue-version: $ROGUE_INSTALL_VERSION" \
  -H "x-rogue-actor-email: $ROGUE_ACTOR_EMAIL" \
  -H "x-rogue-actor-name: $ROGUE_ACTOR_NAME" \
  -H 'Content-Type: application/json' \
  --data-binary @- --max-time 8 -w '\n%{http_code}')
RC=$?
CODE=$(printf '%s' "$RAW" | tail -n1)
BODY=$(printf '%s' "$RAW" | sed '$d')

log "outcome_raw=$(sanitize "$BODY" | head -c 400) http=$CODE rc=$RC"

# Fail-open on transport error or any non-200: emit a clean allow.
if [ "$RC" -ne 0 ] || [ "$CODE" != "200" ] || [ -z "$BODY" ]; then
  log "outcome=allow http=$CODE rc=$RC"
  echo '{}'
  exit 0
fi

# rogue-api already returns the correct native Codex shape; relay it verbatim.
printf '%s' "$BODY"
