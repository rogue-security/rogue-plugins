#!/usr/bin/env bash
# Usage: heartbeat.sh [surface] [TriggerEvent]     (default trigger SessionStart)
#
# Rogue presence heartbeat (Google Antigravity plugin). Fired detached by hook.sh -
# from the first PreInvocation of a CONVERSATION, and from every Stop. POSTs
# /api/v1/hooks/status so this install shows up in the dashboard's Coding Agents
# roster and the org learns which plugin version runs (drives the "outdated" badge).
# Fire-and-forget: never blocks Antigravity, always exits 0.
#
# TWO TRIGGERS, ONE SCRIPT, as in every other plugin - but Antigravity has no
# SessionStart event, so the mapping is its own:
#
#   SessionStart  the first PreInvocation of a new conversation (invocationNum 0 AND
#                 initialNumSteps <= 1). Never throttled, so a fresh install or a new
#                 conversation updates the roster at once.
#   Stop          every agent run's end. Throttled, and the per-TURN trigger.
#
# This REPLACED a heartbeat on every PreInvocation with invocationNum == 0, which
# looked per-session and was not: invocationNum resets on each new prompt, so a
# 10-prompt session sent 10 unthrottled beacons. It also shipped the hook log a turn
# LATE - PreInvocation of turn N runs before turn N's own transcript rows exist, so
# only turns 1..N-1 were ever on disk to upload. Stop is after the rows are written,
# which is why the per-turn work moved there.
#
# Main-and-functions, like hook.sh: everything below is a function and only
# `main "$@"` runs. The one ordering that matters is the same as the
# dispatcher's — the env files are sourced before anything derived from them.
set -u

PLUGIN_ROOT=""
AGENT=""               # which of the three surfaces this install is reporting for
VER="unknown"          # plugin version, from the bundled VERSION file
HOST="unknown"         # hostname; both set by resolve_version via install-id.sh
TRIGGER="SessionStart" # which hook fired us; anything else is rate-limited

# Self-locate the plugin root from $0 (<root>/scripts/heartbeat.sh).
locate_plugin_root() {
  PLUGIN_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd)"
  [ -n "$PLUGIN_ROOT" ] || PLUGIN_ROOT="."
}

load_env() {
  # The first env file holding ROGUE_API_KEY is used alone: machine, bundled, user.
  for _env_file in /etc/rogue/env "${PLUGIN_ROOT}/env" "$HOME/.rogue-env"; do
    if [ -r "$_env_file" ] && grep -Eq '^[[:space:]]*(export[[:space:]]+)?ROGUE_API_KEY=' "$_env_file"; then
      . "$_env_file"; break
    fi
  done
  # Trim a trailing slash so a user-set ROGUE_BASE_URL with one doesn't yield
  # "//" in the composed URL (mirrors hook.ps1's .TrimEnd('/')). Guarded for
  # unset since this script runs under `set -u`.
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

# Host + plugin version, shared with hook.sh so its per-event headers and this
# body describe the same install (same fingerprint, one roster row).
# See install-id.sh.
resolve_version() {
  [ -r "${PLUGIN_ROOT}/scripts/install-id.sh" ] && . "${PLUGIN_ROOT}/scripts/install-id.sh"
  VER="${ROGUE_INSTALL_VERSION:-unknown}"
  HOST="${ROGUE_INSTALL_HOST:-unknown}"
  return 0
}

# Surface: $1 when the caller knows it. hook.sh reads it off the event's
# transcriptPath, which is the only reliable source — three products (the 2.0
# app, the IDE, the `agy` CLI) share one install, so the filesystem
# fallback below cannot tell which one is running and picks the CLI whenever it
# is installed alongside another. Validated, not trusted verbatim: the value ends
# up in a roster row.
resolve_surface() {
  AGENT="${1:-}"
  case "$AGENT" in
    antigravity|antigravity_ide|antigravity_cli) return 0 ;;
  esac
  # No surface passed (a manual run, or an older hook.sh): fall back to the
  # environment. Default to the 2.0 app — the current flagship; flip to the CLI
  # surface if the `agy` binary is on PATH or the CLI's config dir exists.
  AGENT="antigravity"
  if command -v agy >/dev/null 2>&1 || [ -d "$HOME/.gemini/antigravity-cli" ]; then
    AGENT="antigravity_cli"
  fi
}

esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# ── beacon throttle ────────────────────────────────────────────────────────
# The rule lives in scripts/beacon.sh, a byte-identical copy of
# scripts/shared/beacon.sh shared with the other four sh-side plugins. Every
# per-plugin difference is an argument: the stamp slug, and whether this trigger is
# the session one. The knob (ROGUE_HEARTBEAT_MIN_INTERVAL, numeric zero disables,
# non-numeric falls back to the default) is read from the environment inside the
# library, which is correct because load_env ran first.
#
# `-r` guarded so a partial or older install degrades to an unthrottled beacon -
# today's behaviour - rather than erroring out under `set -u`.
load_beacon() {
  if [ -r "${PLUGIN_ROOT}/scripts/beacon.sh" ]; then
    . "${PLUGIN_ROOT}/scripts/beacon.sh"
  else
    rogue_beacon_claim() { return 0; }
  fi
  return 0
}

# Family is the fixed enum "antigravity"; surface rides the agent field.
#
# The stamp slug is `antigravity`, the log file's name, and NOT $AGENT: the three
# surfaces (the 2.0 app, the IDE, the agy CLI) share one install and one log, so they
# must share one throttle window too - a per-surface stamp would let a machine with
# two of them installed beacon twice as often as configured.
post_heartbeat() {
  # rogue_beacon_claim writes the stamp itself, BEFORE the request - deciding and
  # stamping are one call so a caller cannot leave the window permanently open by
  # forgetting the second half.
  _unthrottled=0
  [ "$TRIGGER" = "SessionStart" ] && _unthrottled=1
  rogue_beacon_claim antigravity "$_unthrottled" || return 0
  _body=$(printf '{"agent_family":"antigravity","agent":"%s","version":"%s","host":"%s","actor_email":"%s","actor_name":"%s"}' \
    "$(esc "$AGENT")" "$(esc "$VER")" "$(esc "$HOST")" \
    "$(esc "${ROGUE_ACTOR_EMAIL:-}")" "$(esc "${ROGUE_ACTOR_NAME:-}")")

  curl -sS --max-time 10 -X POST \
    "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/status" \
    -H "x-rogue-api-key: $ROGUE_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$_body" \
    >/dev/null 2>&1 || true
}

# ── ship the hook log ──────────────────────────────────────────────────────
# AFTER post_heartbeat, deliberately: the heartbeat is what creates or refreshes
# the roster row an uploaded log attaches to, so this order means the server has
# somewhere to put the logs before they arrive. This script is ALREADY detached by
# the dispatcher, so the upload delays nothing a user sees.
#
# This heartbeat fires once per USER TURN (from Stop), plus once at the start of a
# conversation, so a 10-prompt session calls this eleven times. That is fine and
# needs no gate here: the shipper's own 15-minute throttle is per log file and is
# stamped before any upload, so the extra calls exit having made no request at all.
# It is also deliberately OUTSIDE the beacon throttle above - a throttled beacon
# still means a turn happened, and the log is worth draining either way.
#
# The actor is PASSED IN, never re-resolved — a second cascade would key the log's
# source row differently from the roster row this script just posted, and the logs
# would attach to nothing. `-r` guarded so a partial install is a silent no-op.
ship_logs() {
  [ -r "${PLUGIN_ROOT}/scripts/ship-logs.sh" ] || return 0
  ROGUE_ACTOR_EMAIL="${ROGUE_ACTOR_EMAIL:-}" ROGUE_ACTOR_NAME="${ROGUE_ACTOR_NAME:-}" \
    sh "${PLUGIN_ROOT}/scripts/ship-logs.sh" \
      "${PLUGIN_ROOT}" antigravity "$VER" antigravity >/dev/null 2>&1 || true
  return 0
}

main() {
  TRIGGER="${2:-SessionStart}"
  locate_plugin_root
  load_env          # sources the env files, then normalises the base URL
  require_api_key   # exits 0 when this install is not configured
  load_actor
  resolve_version
  resolve_surface "${1:-}"
  load_beacon       # after load_env, so the library sees the interval knob
  post_heartbeat
  ship_logs
  exit 0
}

main "$@"
