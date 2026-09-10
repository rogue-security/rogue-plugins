#!/usr/bin/env bash
# Usage: heartbeat.sh [TriggerEvent]     (default SessionStart)
#
# Rogue presence heartbeat (Codex plugin). Fired in the background from
# SessionStart and from Stop.
#
# POSTs /api/v1/hooks/status so this install shows up in the dashboard's Coding
# Agents roster (Connected / version / host / user) and so the org learns which
# plugin version is running (drives the "outdated" badge). Fire-and-forget: never
# blocks Codex, never affects allow/deny, exits 0 on every path.
#
# TWO TRIGGERS, ONE SCRIPT, exactly as in the Claude plugin. SessionStart fires it
# once per session; Stop fires it once per TURN. Stop exists because a session left
# open for days used to produce exactly one beacon and one log upload for its whole
# lifetime - the roster row went stale and the hook log sat on disk unshipped.
# Everything below is unchanged for SessionStart; the only difference on a Stop is
# that the beacon POST is rate-limited (scripts/beacon.sh) so a per-turn trigger
# does not become a per-turn request. The log shipper needs no such gate: it
# already throttles itself, and a run with nothing new makes no request at all.
#
# THE STOP TRIGGER IS SPAWNED BY hook.sh, NOT BY hooks.json, unlike the Claude
# plugin's. Codex hashes the whole hook definition and skips untrusted command
# hooks until the user reviews them via /hooks, so a new hooks.json entry would
# silently disable EVERY Rogue hook on every existing install until each user
# re-approved. The dispatcher already runs on Stop, so firing from there leaves the
# command strings byte-identical and trust intact.
set -u

# Which hook fired us. Anything other than SessionStart is treated as a
# high-frequency trigger and throttled; defaulting to SessionStart keeps the
# existing hooks.json entry - which passes no argument - behaving exactly as it
# does today.
TRIGGER="${1:-SessionStart}"

# Codex sets PLUGIN_ROOT to the installed plugin directory.
PLUGIN_ROOT="${PLUGIN_ROOT:-}"

# The first env file holding ROGUE_API_KEY is used alone: machine, bundled, user.
for _env_file in /etc/rogue/env "${PLUGIN_ROOT}/env" "$HOME/.rogue-env"; do
  if [ -r "$_env_file" ] && grep -Eq "^[[:space:]]*(export[[:space:]]+)?ROGUE_API_KEY=[\"']?[^\"'[:space:]]" "$_env_file"; then
    . "$_env_file"; break
  fi
done

# Not configured → no-op (mirrors hook.sh fail-open on missing key).
[ -n "${ROGUE_API_KEY:-}" ] || exit 0

[ -r "${PLUGIN_ROOT}/scripts/actor.sh" ] && . "${PLUGIN_ROOT}/scripts/actor.sh"
# Host + version + surface. Shared with hook.sh, which sends the same three as
# headers on every event: same values, same roster row. See install-id.sh.
[ -r "${PLUGIN_ROOT}/scripts/install-id.sh" ] && . "${PLUGIN_ROOT}/scripts/install-id.sh"

# Family is the fixed enum "openai"; the surface rides the agent field.
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
BODY=$(printf '{"agent_family":"openai","agent":"%s","version":"%s","host":"%s","actor_email":"%s","actor_name":"%s"}' \
  "$(esc "${ROGUE_INSTALL_AGENT:-codex_cli}")" "$(esc "${ROGUE_INSTALL_VERSION:-unknown}")" \
  "$(esc "${ROGUE_INSTALL_HOST:-unknown}")" \
  "$(esc "${ROGUE_ACTOR_EMAIL:-}")" "$(esc "${ROGUE_ACTOR_NAME:-}")")

# ── beacon throttle ────────────────────────────────────────────────────────
# The rule lives in scripts/beacon.sh, a byte-identical copy of
# scripts/shared/beacon.sh shared with the other four sh-side plugins. Every
# per-plugin difference is an argument: the stamp slug (`codex`, matching the log
# file, NOT the roster family `openai`), and whether this trigger is the session
# one. The knob (ROGUE_HEARTBEAT_MIN_INTERVAL, numeric zero disables, non-numeric
# falls back to the default) is read from the environment inside the library, which
# is correct because the env files were sourced above.
#
# `-r` guarded so a partial or older install degrades to an unthrottled beacon -
# today's behaviour - rather than erroring out under `set -u`.
BEACON_UNTHROTTLED=0
[ "$TRIGGER" = "SessionStart" ] && BEACON_UNTHROTTLED=1
if [ -r "${PLUGIN_ROOT}/scripts/beacon.sh" ]; then
  . "${PLUGIN_ROOT}/scripts/beacon.sh"
else
  rogue_beacon_claim() { return 0; }
fi

# rogue_beacon_claim writes the stamp itself, BEFORE the request - deciding and
# stamping are one call so a caller cannot leave the window permanently open by
# forgetting the second half.
if rogue_beacon_claim codex "$BEACON_UNTHROTTLED"; then
  curl -sS --max-time 10 -X POST \
    "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/status" \
    -H "x-rogue-api-key: $ROGUE_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$BODY" \
    >/dev/null 2>&1 || true
fi

# ── ship the hook log ──────────────────────────────────────────────────────
# See plugins/rogue/scripts/heartbeat.sh for why this runs after the POST (the
# roster row must exist first), why it needs no extra backgrounding (hooks.json
# already detaches this script) and why the actor is passed in rather than
# re-resolved (a second cascade would key the log's source row differently from
# the roster row just posted).
#
# The SLUG AND THE FAMILY DIFFER HERE and that is not a mistake: the log file is
# `codex.log` (slug `codex`, matching the `provider=` token the dispatcher writes)
# while the roster family is `openai`, exactly as this script's own body reports.
# The shipper never derives one from the other - both are arguments.
if [ -r "${PLUGIN_ROOT}/scripts/ship-logs.sh" ]; then
  ROGUE_ACTOR_EMAIL="${ROGUE_ACTOR_EMAIL:-}" ROGUE_ACTOR_NAME="${ROGUE_ACTOR_NAME:-}" \
    sh "${PLUGIN_ROOT}/scripts/ship-logs.sh" \
      "${PLUGIN_ROOT}" codex "${ROGUE_INSTALL_VERSION:-unknown}" openai >/dev/null 2>&1 || true
fi

exit 0
