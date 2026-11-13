#!/usr/bin/env bash
# Cortex Code installer and bridge: the plugin lands in Cortex's plugins folder
# (honoring CORTEX_HOME / SNOWFLAKE_HOME), install is idempotent, uninstall removes
# only the plugin, and hook.sh relays the API's native response or fails open.
set -u
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$REPO/plugins/cortex/scripts/install.sh"
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1" >&2; fails=$((fails + 1)); }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }

H="$(mktemp -d "${TMPDIR:-/tmp}/cortex-home-' space-XXXX")"
trap 'rm -rf "$H"; [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null' EXIT
export HOME="$H"; unset CORTEX_HOME SNOWFLAKE_HOME ROGUE_API_KEY ROGUE_BASE_URL ROGUE_ACTOR_EMAIL ROGUE_ACTOR_NAME
DEST="$H/.snowflake/cortex/plugins/rogue-security"
run() { bash "$INSTALL" "$@" >/dev/null 2>"$H/err"; }

mkdir -p "$H/.snowflake/cortex/plugins/other"; echo keep > "$H/.snowflake/cortex/plugins/other/x"
echo '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}' > "$H/.snowflake/cortex/hooks.json"
cp "$H/.snowflake/cortex/hooks.json" "$H/hooks.before"
check "fresh install" 'run && [ -r "$DEST/hooks/hooks.json" ] && [ -r "$DEST/.cortex-plugin/plugin.json" ]'
check "status passes" 'run --status'
printf "ROGUE_API_KEY=x\n" > "$DEST/env"; chmod 600 "$DEST/env"
check "repeat install succeeds and keeps the bridge env file" 'run && run --status && [ "$(cat "$DEST/env")" = "ROGUE_API_KEY=x" ]'
rm -f "$DEST/env"
check "user hooks and other plugins untouched" 'cmp -s "$H/hooks.before" "$H/.snowflake/cortex/hooks.json" && [ "$(cat "$H/.snowflake/cortex/plugins/other/x")" = keep ]'
check "no staging leftovers" '[ -z "$(ls -A "$H/.snowflake/cortex/plugins" | grep "^\.rogue")" ]'
check "nine events relayed" '[ "$(grep -c "scripts/hook.sh" "$DEST/hooks/hooks.json")" = 9 ]'

# The stored command, with Cortex's ${CORTEX_PLUGIN_ROOT} substituted, runs from a path holding a quote and a space.
cmd="$(sed -n 's/.*"command": "\(.* Stop\)",/\1/p' "$DEST/hooks/hooks.json" | sed 's/\\"/"/g')"
cmd="${cmd//\$\{CORTEX_PLUGIN_ROOT\}/$DEST}"
check "stored hook command runs unconfigured" '[ "$(echo "{}" | sh -c "$cmd")" = "{}" ] && grep -q "event=Stop outcome=unconfigured" "$H/.rogue/logs/cortex.log"'

check "uninstall removes only the plugin" 'run --uninstall && [ ! -e "$DEST" ] && [ -d "$H/.snowflake/cortex/plugins/other" ]'
check "status fails after uninstall" '! run --status'
check "CORTEX_HOME wins" 'CORTEX_HOME="$H/ch" run && [ -d "$H/ch/plugins/rogue-security" ]'
check "SNOWFLAKE_HOME is honored" 'SNOWFLAKE_HOME="$H/sf" run && [ -d "$H/sf/cortex/plugins/rogue-security" ]'

# hook.sh relays the native response, sends the surface, and fails open.
run
PORT=$((RANDOM % 10000 + 30000))
printf "ROGUE_API_KEY='rg_test'\nROGUE_BASE_URL='http://127.0.0.1:%s'\n" "$PORT" > "$H/.rogue-env"; chmod 600 "$H/.rogue-env"
start_mock() {
  [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null && wait "$MOCK_PID" 2>/dev/null
  MOCK_RESPONSE="$1" MOCK_STATUS="${2:-200}" python3 "$REPO/tests/mock_server.py" "$PORT" "$H/headers.json" >/dev/null 2>&1 &
  MOCK_PID=$!
  for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && return; sleep 0.1; done
}
hook() { echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | env ${2:+$2} bash "$DEST/scripts/hook.sh" "$1"; }
deny='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"no"}}'
start_mock "$deny"
check "relays a native deny" '[ "$(hook PreToolUse)" = "$deny" ]'
check "sends event and CLI surface" 'grep -q "PreToolUse" "$H/headers.json" && grep -q "cortex_code_cli" "$H/headers.json"'
check "a CLI in a Desktop terminal stays the CLI" 'hook PreToolUse CORTEX_CODE_CLIENT_SURFACE=coco_desktop >/dev/null && grep -q "cortex_code_cli" "$H/headers.json"'
check "Desktop surface from its shared process" 'hook PreToolUse VSCODE_ESM_ENTRYPOINT=vs/code/electron-utility/sharedProcess/sharedProcessMain >/dev/null && grep -q "cortex_code_desktop" "$H/headers.json"'
start_mock '{}'
check "relays an allow" '[ "$(hook UserPromptSubmit)" = "{}" ]'
start_mock '<html>proxy login</html>'
check "fails open on a non-JSON 200" '[ "$(hook UserPromptSubmit)" = "{}" ] && grep -q "nonjson=1" "$H/.rogue/logs/cortex.log"'
start_mock "$deny" 500
check "fails open on a server error" '[ "$(hook PreToolUse)" = "{}" ]'
kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null; MOCK_PID=""
check "fails open when unreachable" '[ "$(hook PreToolUse)" = "{}" ]'

[ "$fails" = 0 ] && echo "all Cortex Code shell tests passed" || { echo "$fails failed" >&2; exit 1; }
