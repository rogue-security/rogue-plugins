#!/usr/bin/env bash
# Usage: hook.sh EventName
# Relays one Cortex Code hook event to Rogue. Cortex Code speaks Claude Code's hook
# protocol, so the API's reply is already Cortex's native decision JSON. Every path
# exits 0: a Rogue outage never blocks a session.
PLUGIN_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
EVENT="${1:-unknown}"
. "$PLUGIN_ROOT/scripts/env-file.sh"
for file in /etc/rogue/env "$PLUGIN_ROOT/env" "$HOME/.rogue-env"; do
  if rogue_env_is_trusted "$file" && grep -Eq "^[[:space:]]*(export[[:space:]]+)?ROGUE_API_KEY=[\"']?[^\"'[:space:]]" "$file"; then
    . "$file"; break
  fi
done
. "$PLUGIN_ROOT/scripts/install-id.sh"
ROGUE_LOG_FILE="${ROGUE_LOG_FILE:-${ROGUE_LOG_DIR:-$HOME/.rogue/logs}/cortex.log}"
log() {
  ( umask 077
    mkdir -p "$(dirname "$ROGUE_LOG_FILE")"
    if [ -f "$ROGUE_LOG_FILE" ] && [ "$(wc -c < "$ROGUE_LOG_FILE")" -ge 10485760 ]; then mv -f "$ROGUE_LOG_FILE" "$ROGUE_LOG_FILE.1"; fi
    printf '%s provider=cortex surface=%s event=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ROGUE_INSTALL_AGENT" "$EVENT" "$*" >> "$ROGUE_LOG_FILE"
  ) 2>/dev/null
}
if [ -z "${ROGUE_API_KEY:-}" ]; then log outcome=unconfigured; echo '{}'; exit 0; fi
. "$PLUGIN_ROOT/scripts/actor.sh"
ROGUE_ACTOR_EMAIL=$(printf '%s' "$ROGUE_ACTOR_EMAIL" | tr -d '\000-\037\177')
ROGUE_ACTOR_NAME=$(printf '%s' "$ROGUE_ACTOR_NAME" | tr -d '\000-\037\177')
ROGUE_INSTALL_HOST=$(printf '%s' "$ROGUE_INSTALL_HOST" | tr -d '\000-\037\177')
RAW=$(curl -sS -X POST "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/cortex" \
  -H "x-rogue-api-key: $ROGUE_API_KEY" -H "x-rogue-event: $EVENT" \
  -H "x-rogue-agent: $ROGUE_INSTALL_AGENT" -H "x-rogue-host: $ROGUE_INSTALL_HOST" \
  -H "x-rogue-version: $ROGUE_INSTALL_VERSION" \
  -H "x-rogue-actor-email: $ROGUE_ACTOR_EMAIL" -H "x-rogue-actor-name: $ROGUE_ACTOR_NAME" \
  -H 'Content-Type: application/json' --data-binary @- --max-time 8 -w '\n%{http_code}' 2>/dev/null)
RC=$?
CODE=$(printf '%s' "$RAW" | tail -n1)
# Ship this machine's hook log after session and turn boundaries, whatever the relay's outcome.
ship_logs() {
  case "$EVENT" in
    SessionStart|Stop|SessionEnd)
      ( nohup sh "$PLUGIN_ROOT/scripts/ship-logs.sh" "$PLUGIN_ROOT" cortex "$ROGUE_INSTALL_VERSION" cortex </dev/null >/dev/null 2>&1 & ) ;;
  esac
}
if [ "$RC" -ne 0 ] || [ "$CODE" != 200 ]; then
  log "outcome=fail-open http=$CODE rc=$RC ${ROGUE_INSTALL_ID_ERROR:+id_error=$ROGUE_INSTALL_ID_ERROR}"; echo '{}'; ship_logs; exit 0
fi
RESP=$(printf '%s' "$RAW" | sed '$d')
[ -n "$RESP" ] || RESP='{}'
# Cortex adds non-JSON stdout to the model's context; a proxy page must never reach it. The API
# always answers with a JSON object, so anything that does not open and close one fails open.
case "$(printf '%s' "$RESP" | tr -d '[:space:]')" in
  \{*\}) ;;
  *) log "outcome=fail-open http=$CODE rc=$RC nonjson=1"; echo '{}'; ship_logs; exit 0 ;;
esac
OUTCOME=allow
[ "$RESP" = '{}' ] || OUTCOME=block
log "outcome=$OUTCOME http=$CODE rc=$RC raw=$(printf '%s' "$RESP" | tr -d '\000-\037\177' | head -c 400)"
printf '%s\n' "$RESP"
ship_logs
exit 0
