#!/bin/sh
# Rogue Security status for the Kiro plugin (IDE, CLI, Crew).
# Usage: sh ~/.rogue/plugins/kiro/scripts/status.sh
#
# Kiro has no slash-command surface for a /rogue:status skill, so the status
# command is this script: the one diagnostic path support has on a Kiro
# machine. It reports what the other plugins' status skills report -
# credential sources, the API key check, the hook log - plus what only Kiro
# needs: which surfaces are installed, whether the hook wiring install.sh
# wrote is still there, and which agent the 2.x engine runs by default (only
# agents carrying the Rogue hooks are covered there, ADR 0001).
#
# The connection check POSTs /hooks/status, which upserts a roster row
# fingerprinted on host|actor|family|agent - so the body is the heartbeat's:
# built by the one rogue_kiro_status_body in kiro-host.sh from the same
# actor.sh / install-id.sh / kiro-host.sh resolution, or this run would
# register a second row for the install it is checking.
#
# Exit 0 when configured and the API answered 200; 1 otherwise, so a managed
# rollout can verify a machine from a script.
set -u

PLUGIN_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd)"
[ -n "$PLUGIN_ROOT" ] || PLUGIN_ROOT="${KIRO_PLUGIN_ROOT:-.}"
KIRO_HOOKS_DIR="$HOME/.kiro/hooks"
KIRO_APP="${ROGUE_KIRO_APP:-/Applications/Kiro.app}"

CONFIGURED=0
HAVE_CLI=0
HAVE_IDE=0
HTTP_CODE=""

row() { printf '  %-38s %s\n' "$1" "$2"; }
surface_row() { printf '  %-12s%s\n' "$1" "$2"; }
# The first "<key>": "<string>" value in a JSON body, without jq.
json_str() { printf '%s' "$2" | sed -nE 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n1; }

# ── credentials (same env file rule as hook.sh) ─────────────────────────────
load_env() {
  [ -r "${PLUGIN_ROOT}/scripts/env-file.sh" ] || return 0
  . "${PLUGIN_ROOT}/scripts/env-file.sh"
  # The first trusted env file holding ROGUE_API_KEY is used alone: machine, bundled, user.
  for _env_file in /etc/rogue/env "${PLUGIN_ROOT}/env" "$HOME/.rogue-env"; do
    if rogue_env_is_trusted "$_env_file" && grep -Eq "^[[:space:]]*(export[[:space:]]+)?ROGUE_API_KEY=[\"']?[^\"'[:space:]]" "$_env_file"; then
      . "$_env_file"; break
    fi
  done
  ROGUE_BASE_URL="${ROGUE_BASE_URL:-https://api.rogue.security}"
  ROGUE_BASE_URL="${ROGUE_BASE_URL%/}"
  return 0
}

report_credentials() {
  echo "Credentials:"
  [ -r "${PLUGIN_ROOT}/env" ] && echo "  ${PLUGIN_ROOT}/env  (plugin bundle)"
  [ -r /etc/rogue/env ]       && echo "  /etc/rogue/env  (MDM)"
  [ -r "$HOME/.rogue-env" ]   && echo "  $HOME/.rogue-env  (per-user)"
  if [ -n "${ROGUE_API_KEY:-}" ]; then
    CONFIGURED=1
    echo "  API key resolved: ...$(printf '%s' "$ROGUE_API_KEY" | tail -c 4)"
  else
    echo "  API key: not resolved - run install.sh --kiro (managed users: contact your security admin)"
  fi
}

# ── surfaces: what is installed, and which Kiro build each runs ──────────────
report_surfaces() {
  echo "Surfaces:"
  if command -v kiro-cli >/dev/null 2>&1; then
    HAVE_CLI=1
    SURFACE=kiro_cli; . "${PLUGIN_ROOT}/scripts/kiro-host.sh"
    surface_row kiro_cli "kiro-cli $ROGUE_KIRO_VERSION"
  else
    surface_row kiro_cli "kiro-cli not found"
  fi
  if [ -d "$KIRO_APP" ]; then
    HAVE_IDE=1
    SURFACE=kiro_ide; . "${PLUGIN_ROOT}/scripts/kiro-host.sh"
    surface_row kiro_ide "Kiro.app $ROGUE_KIRO_VERSION"
  else
    surface_row kiro_ide "Kiro.app not found"
  fi
  surface_row kiro_crew "via kiro-cli, hooked by the Crew wrappers below"
}

# ── hook wiring: everything install.sh --kiro writes outside the plugin ──────
hook_file_status() {
  f="$KIRO_HOOKS_DIR/rogue.json"
  [ -f "$f" ] || { echo "MISSING - run install.sh --kiro"; return; }
  n=$(grep -c '"name": *"rogue-' "$f" 2>/dev/null)
  s=$(grep -oE 'hook\.sh[\\"]* [A-Za-z]+ kiro_[a-z]+' "$f" 2>/dev/null | head -n1 | awk '{print $NF}')
  echo "present (${n:-0} Rogue hooks, surface ${s:-unknown})"
}

crew_wrapper_status() {
  pre="$KIRO_HOOKS_DIR/rogue-crew-pre.sh"; post="$KIRO_HOOKS_DIR/rogue-crew-post.sh"
  [ -f "$pre" ] && [ -f "$post" ] || { echo "MISSING - run install.sh --kiro"; return; }
  [ -x "$pre" ] && [ -x "$post" ] && { echo "present, executable"; return; }
  echo "present, NOT executable - chmod +x $KIRO_HOOKS_DIR/rogue-crew-*.sh"
}

agent_carries_hooks() { grep -q '"rogue-preToolUse"' "$1" 2>/dev/null; }

hooked_agent_count() {
  n=0
  seen=""
  for dir in "$HOME/.kiro/agents" ./.kiro/agents; do
    [ -d "$dir" ] || continue
    resolved=$(CDPATH= cd -- "$dir" && pwd -P) || continue
    [ "$resolved" = "$seen" ] && continue
    seen="$resolved"
    for f in "$resolved"/*.json; do
      agent_carries_hooks "$f" && n=$((n + 1))
    done
  done
  echo "$n"
}

default_agent_status() {
  [ "$HAVE_CLI" = 1 ] || { echo "(kiro-cli not found)"; return; }
  SURFACE=kiro_cli; . "${PLUGIN_ROOT}/scripts/kiro-host.sh"
  name="$ROGUE_KIRO_DEFAULT_AGENT"
  [ -n "$name" ] || { echo "(none set) - plain 'kiro-cli chat' runs the built-in agent, which carries no hooks; run install.sh --kiro"; return; }
  if agent_carries_hooks "$HOME/.kiro/agents/$name.json" || agent_carries_hooks "./.kiro/agents/$name.json"; then
    echo "$name - covered"
  else
    echo "$name - NOT covered: switch with 'kiro-cli agent set-default rogue' or re-run install.sh --kiro"
  fi
}

report_wiring() {
  echo "Hook wiring:"
  row "~/.kiro/hooks/rogue.json" "$(hook_file_status)"
  row "~/.kiro/hooks/rogue-crew-{pre,post}.sh" "$(crew_wrapper_status)"
  row "agent configs with Rogue hooks" "$(hooked_agent_count) (~/.kiro/agents, ./.kiro/agents)"
  row "default agent (2.x engine)" "$(default_agent_status)"
}

# ── connection: the heartbeat's own body, so it lands on the heartbeat's row ─
status_body() {
  [ -r "${PLUGIN_ROOT}/scripts/actor.sh" ] && . "${PLUGIN_ROOT}/scripts/actor.sh"
  # The CLI's row when kiro-cli is present, the IDE's otherwise: the surface
  # the SessionStart heartbeat on this machine would report first.
  SURFACE=kiro_ide; [ "$HAVE_CLI" = 1 ] && SURFACE=kiro_cli
  . "${PLUGIN_ROOT}/scripts/install-id.sh"
  . "${PLUGIN_ROOT}/scripts/kiro-host.sh"
  rogue_kiro_status_body
}

explain_http() {
  case "$1" in
    200) echo "  organization: $(json_str id "$2")"
         latest=$(json_str latest_version "$2")
         upd="up to date"; hint=""
         case "$2" in *'"update_available":true'*) upd="update available"; hint=" - re-run install.sh --kiro to upgrade" ;; esac
         echo "  plugin $(json_str version "$2") (latest ${latest:-unknown}, $upd)$hint" ;;
    401) echo "  the API key is invalid - re-run install.sh --kiro with a key from the dashboard" ;;
    000) echo "  network: ${ROGUE_BASE_URL#*://} did not answer (proxy or firewall?)" ;;
    *)   echo "  unexpected response: $(printf '%s' "$2" | head -c 200)" ;;
  esac
}

report_connection() {
  echo "Connection:"
  [ "$CONFIGURED" = 1 ] || { echo "  skipped - no API key"; return; }
  command -v curl >/dev/null 2>&1 || { echo "  skipped - curl not found"; return; }
  raw=$(status_body | curl -sS -X POST "$ROGUE_BASE_URL/api/v1/hooks/status" \
    -H "x-rogue-api-key: $ROGUE_API_KEY" -H 'Content-Type: application/json' \
    --data-binary @- --max-time 10 -w '\n%{http_code}' 2>/dev/null)
  HTTP_CODE=$(printf '%s' "$raw" | tail -n1)
  body=$(printf '%s' "$raw" | sed '$d')
  echo "  POST /api/v1/hooks/status -> HTTP ${HTTP_CODE:-000}"
  explain_http "${HTTP_CODE:-000}" "$body"
}

# ── the hook log, honouring the dispatcher's relocation knobs ────────────────
report_log() {
  log="${ROGUE_LOG_FILE:-${ROGUE_LOG_DIR:-$HOME/.rogue/logs}/kiro.log}"
  echo "Log: $log"
  [ -s "$log" ] && tail -n 20 "$log" | sed 's/^/  /' || echo "  (no hook log yet)"
}

main() {
  echo "Rogue Security status (Kiro)"
  load_env
  report_credentials
  report_surfaces
  report_wiring
  report_connection
  report_log
  [ "$CONFIGURED" = 1 ] && [ "$HTTP_CODE" = 200 ]
}

main "$@"
