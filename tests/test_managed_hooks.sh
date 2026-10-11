#!/usr/bin/env bash
# tests/test_managed_hooks.sh - managed-settings hooks (install.sh --managed and the
# Rogue endpoint agent): the template matches hooks.json, renders for a bridge root,
# and hook.sh sends each event once when both the managed and the plugin copy run.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SH="${TEST_SH:-sh}"
PORT=$((RANDOM % 10000 + 30000))
WORK="$(mktemp -d)"
HEADERS_FILE="$WORK/request.json"

cleanup() {
  [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "  ok: $*"; }

# ── Template ──────────────────────────────────────────────────────────────────
python3 "$REPO/scripts/managed-settings.py" --check || fail "managed-settings.json is stale"
ok "managed-settings.json matches hooks.json"

render() {
  ROGUE_INSTALL_LIB_ONLY=1 NO_COLOR=1 bash -c '. "$1/install.sh" </dev/null; render_managed_settings "$2" "$3"' \
    _ "$REPO" "$REPO/plugins/rogue/managed-settings.json" "$1"
}

ROOT="/Library/Rogue/claude-bridge"
render "$ROOT" > "$WORK/rendered.json"
python3 - "$WORK/rendered.json" "$ROOT" <<'PY' || fail "rendered drop-in"
import json, sys
text = open(sys.argv[1]).read()
root = sys.argv[2]
assert "@ROGUE_BRIDGE_ROOT@" not in text, "placeholder left"
hooks = json.loads(text)["hooks"]
commands = [h["command"] for groups in hooks.values() for g in groups for h in g["hooks"]]
assert "PreToolUse" in hooks and "UserPromptSubmit" in hooks and "SessionStart" in hooks
for c in commands:
    assert c.startswith("/usr/bin/env -u BASH_ENV -u ENV PATH=/usr/bin:/bin:/usr/sbin:/sbin "), c
    assert f"CLAUDE_PLUGIN_ROOT='{root}' ROGUE_HOOK_SOURCE=managed /bin/sh " in c, c
    assert f'"{root}/scripts/' in c, c
    assert "auto-update" not in c and "warn.sh" not in c and "powershell" not in c, c
PY
ok "renders absolute bridge paths, fixed PATH, no plugin-only hooks"

for bad in "relative/root" "/a'b" '/a"b' "/a|b" '/a\b' '/a$b' '/a`b'; do
  if render "$bad" >/dev/null 2>&1; then fail "accepted bridge root <$bad>"; fi
done
ok "refuses roots that would break the JSON, quoting or sed"

# ── Dispatcher: one copy per event ────────────────────────────────────────────
# hook.sh reads /etc/rogue/env and demands root ownership in managed mode. Unprivileged
# here, so a copy reads a temp machine file under the user's ownership.
PLUGIN="$WORK/plugin"
cp -R "$REPO/plugins/rogue" "$PLUGIN"
MACHINE_ENV="$WORK/machine-env"
sed -i.bak -e "s|/etc/rogue/env|$MACHINE_ENV|g" -e 's|_need_root=1;|_need_root=0;|' \
  "$PLUGIN/scripts/hook.sh"
cat > "$MACHINE_ENV" <<EOF
export ROGUE_API_KEY=machine-key
export ROGUE_BASE_URL=http://127.0.0.1:${PORT}
EOF
chmod 600 "$MACHINE_ENV"

MOCK_RESPONSE='{}' python3 "$REPO/tests/mock_server.py" "$PORT" "$HEADERS_FILE" &
MOCK_PID=$!
for _ in $(seq 1 50); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.1; done

HOME_DIR="$WORK/home"
mkdir -p "$HOME_DIR"
dispatch() { # dispatch <source: managed|plugin> <event> <session>
  rm -f "$HEADERS_FILE"
  local src=""
  [ "$1" = managed ] && src=managed
  HOME="$HOME_DIR" CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_ROOT="$PLUGIN" ROGUE_HOOK_SOURCE="$src" \
    ROGUE_API_KEY='' ROGUE_BASE_URL='' \
    "$SH" "$PLUGIN/scripts/hook.sh" "$2" <<< "{\"session_id\":\"$3\",\"hook_event_name\":\"$2\"}"
}
sent() { [ -f "$HEADERS_FILE" ]; }

dispatch plugin SessionStart s-plugin-only >/dev/null
sent || fail "plugin copy did not report a session with no managed hooks"
ok "plugin copy reports when managed hooks never fired"

dispatch managed SessionStart s-both >/dev/null
sent || fail "managed copy did not report"
python3 -c 'import json,sys; b=json.load(open(sys.argv[1]))["body"]; assert json.loads(b)["session_id"]=="s-both"' \
  "$HEADERS_FILE" || fail "managed copy did not forward the payload"
[ -f "$HOME_DIR/.rogue/managed-sessions/s-both" ] || fail "managed copy left no session mark"
ok "managed copy reports, forwards the payload and marks the session"

out=$(dispatch plugin PreToolUse s-both)
[ "$out" = "{}" ] || fail "plugin copy answered <$out> for a managed session"
sent && fail "plugin copy reported a session the managed copy owns"
grep -q "outcome=deferred-to-managed" "$HOME_DIR/.rogue/logs/claude.log" || fail "deferral not logged"
ok "plugin copy stands down for a managed session"

dispatch managed PreToolUse s-both >/dev/null
sent || fail "managed copy stopped reporting"
ok "managed copy keeps reporting"

# A user's own env file cannot configure, or redirect, the managed copy.
rm "$MACHINE_ENV"
printf 'export ROGUE_API_KEY=user-key\nexport ROGUE_BASE_URL=http://127.0.0.1:%s\n' "$PORT" > "$HOME_DIR/.rogue-env"
chmod 600 "$HOME_DIR/.rogue-env"
out=$(dispatch managed PreToolUse s-user)
[ "$out" = "{}" ] && ! sent || fail "managed copy used ~/.rogue-env"
dispatch plugin PreToolUse s-user >/dev/null
sent || fail "plugin copy stopped reading ~/.rogue-env"
ok "managed copy ignores ~/.rogue-env; the plugin copy still reads it"

echo "test_managed_hooks: all passed"
