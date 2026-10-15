#!/usr/bin/env bash
# Muse installer and bridge: settings.json keeps every byte except Rogue's one
# managed_hooks_path line, foreign pointers are refused, and hook.sh relays the
# API's native response or fails open.
set -u
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$REPO/plugins/muse/scripts/install.sh"
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1" >&2; fails=$((fails + 1)); }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }
json_ok() { python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" 2>/dev/null; }

H="$(mktemp -d "${TMPDIR:-/tmp}/muse-home-' space-XXXX")"
trap 'rm -rf "$H"; [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null' EXIT
export HOME="$H" XDG_CONFIG_HOME="$H/.config"
S="$XDG_CONFIG_HOME/muse/settings.json"
HOOKS="$H/.rogue/plugins/muse/hooks.json"
run() { bash "$INSTALL" "$@" >/dev/null 2>"$H/err"; }

# Fresh install, then a repeat that changes nothing.
check "fresh install" 'run'
check "fresh settings point at hooks" 'json_ok "$S" && grep -q "\"managed_hooks_path\": \"$HOOKS\"" "$S"'
check "hooks file is valid JSON with ten events" 'json_ok "$HOOKS" && [ "$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))[\"hooks\"]))" "$HOOKS")" = 10 ]'
cp "$S" "$H/before"
check "repeat install is a no-op" 'run && cmp -s "$S" "$H/before"'
check "status passes" 'run --status'

# The stored command runs from a home path holding a quote and a space.
cmd="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["hooks"]["Stop"][0]["hooks"][0]["command"])' "$HOOKS")"
check "stored hook command runs" '[ "$(echo "{}" | sh -c "$cmd")" = "{}" ] && grep -q "event=Stop outcome=unconfigured" "$H/.rogue/logs/muse.log"'

# Existing Muse-style settings (no final newline): one added line, exact restore on uninstall.
rm -rf "$XDG_CONFIG_HOME/muse"; mkdir -p "$XDG_CONFIG_HOME/muse"
printf '{\n  "schema_version": 1,\n  "provider": "meta",\n  "hooks": {\n    "PreToolUse": [{"hooks": [{"type": "command", "command": "echo foreign"}]}]\n  }\n}' > "$S"
cp "$S" "$H/original"
check "install into existing settings" 'run'
check "only the pointer line is added" '[ "$(diff "$H/original" "$S" | grep -c "^[<>]")" = 1 ] && json_ok "$S"'
check "uninstall restores exact bytes" 'run --uninstall && cmp -s "$S" "$H/original" && [ ! -e "$HOOKS" ]'
check "status fails after uninstall" '! run --status'

# Muse may rewrite settings with the pointer as the last member.
printf '{\n  "provider": "meta",\n  "managed_hooks_path": "%s"\n}\n' "$HOOKS" > "$S"
check "uninstall of a last-member pointer leaves valid JSON" 'run --uninstall && json_ok "$S" && ! grep -q managed_hooks_path "$S"'

# Compact and empty objects.
printf '{"provider":"meta"}' > "$S"
check "compact settings stay valid" 'run && json_ok "$S" && grep -q "\"provider\":\"meta\"" "$S"'
printf '{}' > "$S"
check "empty object gains only the pointer" 'run && [ "$(python3 -c "import json,sys; print(*json.load(open(sys.argv[1])))" "$S")" = managed_hooks_path ]'

# Refusals leave settings untouched.
for doc in '[]' '{"managed_hooks_path": "/etc/corp/hooks.json"}' '{"managed_hooks_path": null}'; do
  printf '%s' "$doc" > "$S"
  check "refuses $doc" '! run && [ "$(cat "$S")" = "$doc" ]'
done
check "a refusal releases the lock" '[ ! -e "$S.rogue-lock" ]'
printf '{}' > "$S"; mkdir "$S.rogue-lock"
check "refuses while locked" '! run && grep -q "remove $S.rogue-lock and retry" "$H/err" && [ "$(cat "$S")" = "{}" ]'
rmdir "$S.rogue-lock"

# hook.sh relays the native response and fails open.
run
PORT=$((RANDOM % 10000 + 30000))
printf "ROGUE_API_KEY='rg_test'\nROGUE_BASE_URL='http://127.0.0.1:%s'\n" "$PORT" > "$H/.rogue-env"; chmod 600 "$H/.rogue-env"
start_mock() {
  [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null && wait "$MOCK_PID" 2>/dev/null
  MOCK_RESPONSE="$1" MOCK_STATUS="${2:-200}" python3 "$REPO/tests/mock_server.py" "$PORT" "$H/headers.json" >/dev/null 2>&1 &
  MOCK_PID=$!
  for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && return; sleep 0.1; done
}
hook() { echo '{"tool_name":"write_file"}' | bash "$H/.rogue/plugins/muse/scripts/hook.sh" "$1"; }
deny='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"no"}}'
start_mock "$deny"
check "relays a native deny" '[ "$(hook PreToolUse)" = "$deny" ]'
check "sends the event header" 'grep -q "PreToolUse" "$H/headers.json"'
start_mock '{}'
check "relays an allow" '[ "$(hook UserPromptSubmit)" = "{}" ]'
start_mock "$deny" 500
check "fails open on a server error" '[ "$(hook PreToolUse)" = "{}" ]'
kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null; MOCK_PID=""
check "fails open when unreachable" '[ "$(hook PreToolUse)" = "{}" ]'

[ "$fails" = 0 ] && echo "all Muse shell tests passed" || { echo "$fails failed" >&2; exit 1; }
