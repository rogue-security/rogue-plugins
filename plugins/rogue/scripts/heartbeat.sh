#!/usr/bin/env bash
# Usage: heartbeat.sh [TriggerEvent]     (default SessionStart)
#
# Rogue presence heartbeat. Fired in the background from SessionStart and Stop.
#
# POSTs /api/v1/hooks/status so this install shows up in the dashboard's Coding
# Agents roster (Connected / version / host / user) and so the org learns which
# plugin version is running. Pure side-effect: fire-and-forget, never blocks
# Claude Code, never affects allow/deny, and exits 0 on every path.
#
# The roster dedups one row per (host | actor-email | family), so we always
# send a stable x-rogue-host + x-rogue-actor-email.
#
# TWO TRIGGERS, ONE SCRIPT. SessionStart fires it once per session; Stop fires it
# once per TURN. Stop exists because a session that stays open for days used to
# produce exactly one beacon and one log upload for its whole lifetime - the
# roster row went stale and the hook log sat on disk unshipped. Everything below
# is unchanged for SessionStart; the only difference on a Stop is that the beacon
# POST is rate-limited (see the throttle) so a per-turn trigger does not become a
# per-turn request. The log shipper needs no such gate: it already throttles
# itself, and a run with nothing new makes no request at all.
set -u

# Which hook fired us. Anything other than SessionStart is treated as a
# high-frequency trigger and throttled; defaulting to SessionStart keeps an old
# hooks.json (which passes no argument) behaving exactly as it does today.
TRIGGER="${1:-SessionStart}"

# Git Bash stand-down: heartbeat.ps1 owns native Windows (same reason as hook.sh).
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) exit 0 ;;
esac

# The first env file holding ROGUE_API_KEY is used alone: machine, bundled, user.
for _env_file in /etc/rogue/env "${CLAUDE_PLUGIN_ROOT:-}/env" "$HOME/.rogue-env"; do
  if [ -r "$_env_file" ] && grep -Eq '^[[:space:]]*(export[[:space:]]+)?ROGUE_API_KEY=' "$_env_file"; then
    . "$_env_file"; break
  fi
done

# Not configured → no-op (mirrors hook.sh fail-open on missing key).
[ -n "${ROGUE_API_KEY:-}" ] || exit 0

# CLAUDE_CODE_ENTRYPOINT used to `exit 0` right here, ABOVE everything. It now
# guards only the beacon POST below, because this script also ships the hook log
# and those are different questions: the entrypoint decides whether there is a
# *session* to report presence for, while the log on disk is worth uploading
# regardless (a manual support run, or a future Claude build that stops exporting
# the var, would otherwise silently stop shipping logs with no other symptom).
# Moving it is behaviour-neutral for the beacon itself - both are bare `exit 0`
# guards ahead of any side effect, and the beacon still fires exactly when it did.

# Actor identity via the shared cascade (env → CLAUDE_CODE_USER_EMAIL → git →
# host/whoami marker), with synthetic sandbox identities screened out — see
# actor.sh. It is written `set -u`-safe, but nounset is relaxed across the source
# anyway so a future unguarded expansion there can never kill the heartbeat.
set +u
[ -r "${CLAUDE_PLUGIN_ROOT:-}/scripts/actor.sh" ] && . "${CLAUDE_PLUGIN_ROOT}/scripts/actor.sh"
set -u

# Host + version + surface label. Shared with hook.sh, which sends the same three
# as headers on every event: same values, same roster row. See install-id.sh.
[ -r "${CLAUDE_PLUGIN_ROOT:-}/scripts/install-id.sh" ] && . "${CLAUDE_PLUGIN_ROOT}/scripts/install-id.sh"

# POST /api/v1/hooks/status (GET route is gone). The former x-rogue-agent-*
# headers now ride the JSON body; x-rogue-api-key stays a header. Family is the
# fixed enum value "claude". Backslash- and quote-escape each value so a
# name/host with a " or \ can't break the JSON.
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
BODY=$(printf '{"agent_family":"claude","agent":"%s","version":"%s","host":"%s","actor_email":"%s","actor_name":"%s"}' \
  "$(esc "${ROGUE_INSTALL_AGENT:-claude_code}")" "$(esc "${ROGUE_INSTALL_VERSION:-unknown}")" \
  "$(esc "${ROGUE_INSTALL_HOST:-unknown}")" \
  "$(esc "${ROGUE_ACTOR_EMAIL:-}")" "$(esc "${ROGUE_ACTOR_NAME:-}")")

# ── beacon throttle ────────────────────────────────────────────────────────
# Only a high-frequency trigger is rate-limited. SessionStart stays unthrottled:
# it fires once per session, and a brand-new session is exactly when the roster
# most wants the update (a re-install with a new version, a different surface).
# Throttling it would have been a behaviour change for no gain.
#
# The rule itself lives in scripts/beacon.sh, a byte-identical copy of
# scripts/shared/beacon.sh shared with the other four sh-side plugins - the same
# arrangement as ship-logs.sh, and for the same reason: all six plugins now beacon
# on a per-turn trigger, and six hand-written copies of these semantics would
# drift silently in one of two directions, "no beacon ever again" or "a beacon on
# every turn". Every per-plugin difference is an ARGUMENT: the stamp slug here, and
# whether this trigger is the session one.
#
# The knob (ROGUE_HEARTBEAT_MIN_INTERVAL, numeric zero disables, non-numeric falls
# back to the default) is read from the environment inside the library, which is
# correct because the env files were sourced above.
#
# `-r` guarded so a partial or older install degrades to an unthrottled beacon -
# today's behaviour - rather than erroring out under `set -u`.
BEACON_UNTHROTTLED=0
[ "$TRIGGER" = "SessionStart" ] && BEACON_UNTHROTTLED=1
if [ -r "${CLAUDE_PLUGIN_ROOT:-}/scripts/beacon.sh" ]; then
  . "${CLAUDE_PLUGIN_ROOT}/scripts/beacon.sh"
else
  rogue_beacon_claim() { return 0; }
fi

# The beacon, and ONLY the beacon, is gated on there being a session (see the note
# where that check used to live). rogue_beacon_claim writes the stamp itself, BEFORE
# the request below - deciding and stamping are one call so a caller cannot leave
# the window permanently open by forgetting the second half.
if [ -n "${CLAUDE_CODE_ENTRYPOINT:-}" ] && rogue_beacon_claim claude "$BEACON_UNTHROTTLED"; then
  curl -sS --max-time 10 -X POST \
    "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/status" \
    -H "x-rogue-api-key: $ROGUE_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$BODY" \
    >/dev/null 2>&1 || true
fi

# ── ship the hook log ──────────────────────────────────────────────────────
# AFTER the heartbeat POST when both run: the beacon creates or refreshes the roster
# row for this install, so this order means it exists before the logs land. It is an
# ordering preference, NOT a prerequisite - the backend resolves-or-creates the log
# source from the identity fields the shipper itself sends - which is why shipping
# is deliberately OUTSIDE the gate above rather than sequenced behind the POST.
#
# This script is ALREADY detached by hooks.json, so the upload delays nothing a user
# sees and needs no second backgrounding; and the shipper's own 15-minute throttle
# means the common case is that it makes no request at all.
#
# The actor is PASSED IN, never re-resolved. The shipper deliberately carries no
# cascade of its own: the plugins' cascades differ (actor.sh ends at `hostname`,
# Cursor's at "$USER@$(hostname)"), so a re-resolve would key the log's source
# row differently from the roster row this script just posted, and the logs would
# attach to nothing. actor.sh exports both vars, so the child would inherit them
# anyway - the explicit prefix states the contract at the call site and also
# covers an install whose actor.sh predates that export.
#
# `-r` guarded so a partial or older install is a no-op rather than an error, and
# `|| true` because this script runs under `set -u` and must exit 0 regardless.
if [ -r "${CLAUDE_PLUGIN_ROOT:-}/scripts/ship-logs.sh" ]; then
  ROGUE_ACTOR_EMAIL="${ROGUE_ACTOR_EMAIL:-}" ROGUE_ACTOR_NAME="${ROGUE_ACTOR_NAME:-}" \
    sh "${CLAUDE_PLUGIN_ROOT}/scripts/ship-logs.sh" \
      "${CLAUDE_PLUGIN_ROOT}" claude "${ROGUE_INSTALL_VERSION:-unknown}" claude >/dev/null 2>&1 || true
fi

exit 0
