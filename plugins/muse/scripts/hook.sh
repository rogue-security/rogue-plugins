#!/usr/bin/env bash
# Usage: hook.sh EventName /absolute/path/to/node
PLUGIN_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
EVENT="${1:-unknown}"
NODE="${2:-node}"
. "$PLUGIN_ROOT/scripts/env-file.sh"
for file in /etc/rogue/env "$PLUGIN_ROOT/env" "$HOME/.rogue-env"; do
  if rogue_env_is_trusted "$file" && grep -Eq "^[[:space:]]*(export[[:space:]]+)?ROGUE_API_KEY=[\"']?[^\"'[:space:]]" "$file"; then
    . "$file"; break
  fi
done
ROGUE_LOG_FILE="${ROGUE_LOG_FILE:-${ROGUE_LOG_DIR:-$HOME/.rogue/logs}/muse.log}"
log() {
  ( umask 077
    mkdir -p "$(dirname "$ROGUE_LOG_FILE")"
    if [ -f "$ROGUE_LOG_FILE" ] && [ "$(wc -c < "$ROGUE_LOG_FILE")" -ge 10485760 ]; then mv -f "$ROGUE_LOG_FILE" "$ROGUE_LOG_FILE.1"; fi
    printf '%s provider=muse surface=muse_code event=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$EVENT" "$*" >> "$ROGUE_LOG_FILE"
  ) 2>/dev/null
}
if [ -z "${ROGUE_API_KEY:-}" ]; then log outcome=unconfigured; echo '{}'; exit 0; fi
. "$PLUGIN_ROOT/scripts/actor.sh"
. "$PLUGIN_ROOT/scripts/install-id.sh"
RAW=$(curl -sS -X POST "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/muse" \
  -H "x-rogue-api-key: $ROGUE_API_KEY" -H "x-rogue-event: $EVENT" \
  -H "x-rogue-agent: muse_code" -H "x-rogue-host: $ROGUE_INSTALL_HOST" \
  -H "x-rogue-version: $ROGUE_INSTALL_VERSION" \
  -H "x-rogue-actor-email: $ROGUE_ACTOR_EMAIL" -H "x-rogue-actor-name: $ROGUE_ACTOR_NAME" \
  -H 'Content-Type: application/json' --data-binary @- --max-time 5 -w '\n%{http_code}' 2>/dev/null)
RC=$?
CODE=$(printf '%s' "$RAW" | tail -n1)
if [ "$RC" -ne 0 ] || [ "$CODE" != 200 ]; then
  log "outcome=fail-open http=$CODE rc=$RC"; echo '{}'; exit 0
fi
RESP=$(printf '%s' "$RAW" | sed '$d' | "$NODE" "$PLUGIN_ROOT/scripts/response.mjs" "$EVENT" 2>/dev/null) || { log "outcome=fail-open http=$CODE reason=invalid-response"; echo '{}'; exit 0; }
[ -n "$RESP" ] || RESP='{}'
OUTCOME=allow
[ "$RESP" = '{}' ] || OUTCOME=block
log "outcome=$OUTCOME http=$CODE rc=$RC raw=$(printf '%s' "$RESP" | tr -d '\000-\037\177' | head -c 400)"
printf '%s\n' "$RESP"
case "$EVENT" in
  SessionStart|Stop|SessionEnd)
    ( nohup sh "$PLUGIN_ROOT/scripts/ship-logs.sh" "$PLUGIN_ROOT" muse "$ROGUE_INSTALL_VERSION" muse </dev/null >/dev/null 2>&1 & ) ;;
esac
exit 0
