#!/usr/bin/env bash
# Usage: heartbeat.sh [surface] [TriggerEvent]     (default trigger SessionStart)
#
# Rogue presence heartbeat (Kiro plugin). Fired detached by hook.sh from
# SessionStart and from every Stop. POSTs /api/v1/hooks/status so this install
# shows up in the dashboard's Coding Agents roster and the org learns which plugin
# version runs (drives the "outdated" badge). Fire-and-forget: never blocks Kiro,
# always exits 0.
#
# TWO TRIGGERS, ONE SCRIPT, as in every other plugin:
#
#   SessionStart  once per session (the 2.x engine calls it agentSpawn; hook.sh
#                 canonicalises before spawning us). Never throttled, so a fresh
#                 install or a new session updates the roster at once.
#   Stop          once per TURN. Throttled by scripts/beacon.sh so a per-turn spawn
#                 is not a per-turn request.
#
# The surface is an ARGUMENT, as for Antigravity: no Kiro payload names it, so the
# installer fixed it in the hook file and hook.sh passes it through, and the
# heartbeat body must carry the same value as the per-event x-rogue-agent header
# or the backend keys two roster rows for one install.
#
# Main-and-functions, like the Antigravity heartbeat: everything below is a
# function and only `main "$@"` runs. The one ordering that matters is the same
# as the dispatcher's — the env files are sourced before anything derived from
# them.
set -u

PLUGIN_ROOT=""
AGENT=""               # which of the three surfaces this install is reporting for
VER="unknown"          # plugin version, from plugin.json via install-id.sh
TRIGGER="SessionStart" # which hook fired us; anything else is rate-limited

# Self-locate the plugin root from $0 (<root>/scripts/heartbeat.sh).
locate_plugin_root() {
  PLUGIN_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd)"
  [ -n "$PLUGIN_ROOT" ] || PLUGIN_ROOT="${KIRO_PLUGIN_ROOT:-.}"
}

load_env() {
  [ -r "${PLUGIN_ROOT}/scripts/env-file.sh" ] || return 0
  . "${PLUGIN_ROOT}/scripts/env-file.sh"
  # The first trusted env file holding ROGUE_API_KEY is used alone: machine, bundled, user.
  for _env_file in /etc/rogue/env "${PLUGIN_ROOT}/env" "$HOME/.rogue-env"; do
    if rogue_env_is_trusted "$_env_file" && grep -Eq '^[[:space:]]*(export[[:space:]]+)?ROGUE_API_KEY=' "$_env_file"; then
      . "$_env_file"; break
    fi
  done
  # Trim a trailing slash so a user-set ROGUE_BASE_URL with one doesn't yield
  # "//" in the composed URL (mirrors heartbeat.ps1's .TrimEnd('/')).
  ROGUE_BASE_URL="${ROGUE_BASE_URL:-}"
  ROGUE_BASE_URL="${ROGUE_BASE_URL%/}"
  return 0
}

# Not configured → no-op (mirrors hook.sh fail-open on missing key).
require_api_key() {
  [ -n "${ROGUE_API_KEY:-}" ] || exit 0
}

load_actor() {
  [ -r "${PLUGIN_ROOT}/scripts/actor.sh" ] && . "${PLUGIN_ROOT}/scripts/actor.sh"
  return 0
}

# Surface: $1 when the caller knows it, validated against the closed vocabulary
# because the value ends up in a roster row. Default kiro_cli, which is what the
# route defaults an unknown x-rogue-agent to as well.
resolve_surface() {
  case "${1:-}" in
    kiro_ide|kiro_cli|kiro_crew) AGENT="$1" ;;
    *)                           AGENT="kiro_cli" ;;
  esac
}

# Host + plugin version, shared with hook.sh so its per-event headers and this
# body describe the same install (same fingerprint, one roster row).
# install-id.sh reads SURFACE, so resolve_surface runs first.
resolve_version() {
  SURFACE="$AGENT"
  [ -r "${PLUGIN_ROOT}/scripts/install-id.sh" ] && . "${PLUGIN_ROOT}/scripts/install-id.sh"
  VER="${ROGUE_INSTALL_VERSION:-unknown}"
  return 0
}

# What Kiro itself reports: its build (CLI from `kiro-cli --version`, IDE from
# the app bundle) and, on the CLI, the default agent. Two versions ride one
# body - `version` is the plugin's, `agent_version` is Kiro's - so support can
# tell a current plugin from a stale Kiro once the backend stores the second
# (it does not yet; see README "Roster heartbeat"). kiro-host.sh reads SURFACE too,
# and also defines rogue_kiro_status_body, the body builder shared with
# status.sh. Called from post_heartbeat AFTER the beacon claim: each probe is a
# kiro-cli process, and a throttled Stop must not pay for two of them.
resolve_kiro_host() {
  SURFACE="$AGENT"
  [ -r "${PLUGIN_ROOT}/scripts/kiro-host.sh" ] && . "${PLUGIN_ROOT}/scripts/kiro-host.sh"
  return 0
}

# ── beacon throttle ────────────────────────────────────────────────────────
# The rule lives in scripts/beacon.sh, a byte-identical copy of
# scripts/shared/beacon.sh shared with the other sh-side plugins. Every per-plugin
# difference is an argument: the stamp slug, and whether this trigger is the
# session one. The knob (ROGUE_HEARTBEAT_MIN_INTERVAL, numeric zero disables,
# non-numeric falls back to the default) is read from the environment inside the
# library, which is correct because load_env ran first.
#
# `-r` guarded so a partial or older install degrades to an unthrottled beacon -
# rather than erroring out under `set -u`.
load_beacon() {
  if [ -r "${PLUGIN_ROOT}/scripts/beacon.sh" ]; then
    . "${PLUGIN_ROOT}/scripts/beacon.sh"
  else
    rogue_beacon_claim() { return 0; }
  fi
  return 0
}

# Family is the fixed enum "kiro"; surface rides the agent field.
#
# The stamp slug is `kiro`, the log file's name, and NOT $AGENT: the three
# surfaces share one install and one log, so they must share one throttle window
# too - a per-surface stamp would let a machine with the IDE and the CLI both
# installed beacon twice as often as configured.
post_heartbeat() {
  # rogue_beacon_claim writes the stamp itself, BEFORE the request - deciding and
  # stamping are one call so a caller cannot leave the window permanently open by
  # forgetting the second half.
  _unthrottled=0
  [ "$TRIGGER" = "SessionStart" ] && _unthrottled=1
  rogue_beacon_claim kiro "$_unthrottled" || return 0
  resolve_kiro_host
  # No builder means no kiro-host.sh: a partial install has nothing to report
  # this turn, and the stamp already written keeps it from retrying every turn.
  command -v rogue_kiro_status_body >/dev/null 2>&1 || return 0
  _body=$(rogue_kiro_status_body)

  curl -sS --max-time 10 -X POST \
    "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/status" \
    -H "x-rogue-api-key: $ROGUE_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$_body" \
    >/dev/null 2>&1 || true
}

# ── ship the hook log ──────────────────────────────────────────────────────
# AFTER post_heartbeat, deliberately: the heartbeat is what creates or refreshes
# the roster row an uploaded log attaches to. This script is ALREADY detached by
# the dispatcher, so the upload delays nothing a user sees.
#
# Once per USER TURN (from Stop) plus once per session; no gate is needed here
# because the shipper's own per-file throttle is stamped before any upload, so
# the extra calls exit having made no request. Deliberately OUTSIDE the beacon
# throttle - a throttled beacon still means a turn happened, and the log is worth
# draining either way.
#
# The actor is PASSED IN, never re-resolved — a second cascade would key the
# log's source row differently from the roster row this script just posted.
ship_logs() {
  [ -r "${PLUGIN_ROOT}/scripts/ship-logs.sh" ] || return 0
  ROGUE_ACTOR_EMAIL="${ROGUE_ACTOR_EMAIL:-}" ROGUE_ACTOR_NAME="${ROGUE_ACTOR_NAME:-}" \
    sh "${PLUGIN_ROOT}/scripts/ship-logs.sh" \
      "${PLUGIN_ROOT}" kiro "$VER" kiro >/dev/null 2>&1 || true
  return 0
}

main() {
  TRIGGER="${2:-SessionStart}"
  locate_plugin_root
  load_env          # sources the env files, then normalises the base URL
  require_api_key   # exits 0 when this install is not configured
  load_actor
  resolve_surface "${1:-}"
  resolve_version   # after the surface: install-id.sh keys the agent on it
  load_beacon       # after load_env, so the library sees the interval knob
  post_heartbeat    # claims the beacon slot, THEN asks Kiro for its version
  ship_logs
  exit 0
}

main "$@"
