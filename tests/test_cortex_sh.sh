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
# The last log line, without the bridge=native token the native bridge adds or the trailing space
# hook.sh leaves when it has no install-id error to report.
last_log() { tail -n 1 "$H/.rogue/logs/cortex.log" | sed 's/ bridge=native / /; s/ *$//'; }
logged() { case "$(last_log)" in *" provider=cortex surface=cortex_code_cli $1") return 0 ;; *) return 1 ;; esac; }

mkdir -p "$H/.snowflake/cortex/plugins/other"; echo keep > "$H/.snowflake/cortex/plugins/other/x"
echo '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}' > "$H/.snowflake/cortex/hooks.json"
cp "$H/.snowflake/cortex/hooks.json" "$H/hooks.before"
check "fresh install" 'run && [ -r "$DEST/hooks/hooks.json" ] && [ -r "$DEST/.cortex-plugin/plugin.json" ]'
check "status passes" 'run --status'
printf "ROGUE_API_KEY=x\n" > "$DEST/env"; chmod 600 "$DEST/env"
check "repeat install succeeds and keeps the bridge env file" 'run && run --status && [ "$(cat "$DEST/env")" = "ROGUE_API_KEY=x" ]'
rm -f "$DEST/env"
check "user hooks and other plugins untouched" 'cmp -s "$H/hooks.before" "$H/.snowflake/cortex/hooks.json" && [ "$(cat "$H/.snowflake/cortex/plugins/other/x")" = keep ]'
check "no staging leftovers or lock" '[ -z "$(ls -A "$H/.snowflake/cortex/plugins" | grep "^\.rogue")" ]'
mkdir "$H/.snowflake/cortex/plugins/.rogue-security.lock"
check "refuses while another install holds the lock" '! run && grep -q "remove .*lock and retry" "$H/err"'
rmdir "$H/.snowflake/cortex/plugins/.rogue-security.lock"
check "nine events relayed" '[ "$(grep -c "scripts/hook.sh" "$DEST/hooks/hooks.json")" = 9 ]'

# The stored command, with Cortex's ${CORTEX_PLUGIN_ROOT} substituted, runs from a path holding a quote and a space.
cmd="$(sed -n 's/.*"command": "\(.* Stop\)",/\1/p' "$DEST/hooks/hooks.json" | sed 's/\\"/"/g')"
cmd="${cmd//\$\{CORTEX_PLUGIN_ROOT\}/$DEST}"
check "stored hook command runs unconfigured" '[ "$(echo "{}" | sh -c "$cmd")" = "{}" ] && logged "event=Stop outcome=unconfigured"'

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
payload='{"tool_name":"Bash","tool_input":{"command":"ls"}}'
hook() { printf '%s\n' "$payload" | env ${2:+$2} bash "$DEST/scripts/hook.sh" "$1"; }
request_was() { # <path> <agent> <body line>
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(not (d["path"], d["headers"]["x-rogue-agent"], d["body"]) == (sys.argv[2], sys.argv[3], sys.argv[4] + "\n"))' "$H/headers.json" "$@"
}
deny='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"no"}}'
start_mock "$deny"
check "relays a native deny" '[ "$(hook PreToolUse)" = "$deny" ]'
check "logs any other body as a block" 'logged "event=PreToolUse outcome=block http=200 rc=0 raw=$deny"'
check "posts the payload to the cortex route as cortex_code_cli" 'request_was /api/v1/hooks/cortex cortex_code_cli "$payload"'
check "sends event and CLI surface" 'grep -q "PreToolUse" "$H/headers.json" && grep -q "cortex_code_cli" "$H/headers.json"'
check "a CLI in a Desktop terminal stays the CLI" 'hook PreToolUse CORTEX_CODE_CLIENT_SURFACE=coco_desktop >/dev/null && grep -q "cortex_code_cli" "$H/headers.json"'
check "Desktop surface from its shared process" 'hook PreToolUse VSCODE_ESM_ENTRYPOINT=vs/code/electron-utility/sharedProcess/sharedProcessMain >/dev/null && grep -q "cortex_code_desktop" "$H/headers.json"'
start_mock '{}'
check "relays an allow" '[ "$(hook UserPromptSubmit)" = "{}" ]'
check "logs an allow" 'logged "event=UserPromptSubmit outcome=allow http=200 rc=0 raw={}"'
start_mock ''
check "an empty answer allows" '[ "$(hook PostToolUse)" = "{}" ] && logged "event=PostToolUse outcome=allow http=200 rc=0 raw={}"'
start_mock '{}' 204
check "only a 200 answers" '[ "$(hook PreToolUse)" = "{}" ] && logged "event=PreToolUse outcome=fail-open http=204 rc=0"'
start_mock '<html>proxy login</html>'
check "fails open on a non-JSON 200" '[ "$(hook UserPromptSubmit)" = "{}" ] && logged "event=UserPromptSubmit outcome=fail-open http=200 rc=0 nonjson=1"'
start_mock "  $deny"
check "relays a deny with leading whitespace" '[ "$(hook PreToolUse)" = "  $deny" ]'
for junk in '{not-json' '{not-json}'; do
  start_mock "$junk"
  check "fails open on $junk" '[ "$(hook UserPromptSubmit)" = "{}" ]'
done
start_mock "$deny" 500
check "fails open on a server error" '[ "$(hook PreToolUse)" = "{}" ] && logged "event=PreToolUse outcome=fail-open http=500 rc=0"'
kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null; MOCK_PID=""
check "fails open when unreachable" '[ "$(hook PreToolUse)" = "{}" ] && logged "event=PreToolUse outcome=fail-open http=000 rc=7"'

[ "$fails" = 0 ] && echo "all Cortex Code shell tests passed" || { echo "$fails failed" >&2; exit 1; }
