#!/usr/bin/env bash
# tests/test_native_bridge_sh.sh — the hand-off seam: native-bridge-install.sh downloads the pinned
# native bridge through a mock /api/v1/hooks/download, verifies it against the pin and installs it
# under ~/.rogue/bin/rogue-hook/<version>/; hook.sh then hands every event to it. A stub script
# stands in for the binary so this needs no Rust build.
#
# Override with TEST_SH=dash to catch bashisms (hooks.json runs every script via `sh`).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SH="${TEST_SH:-sh}"
WORK="$(mktemp -d)"
PLUGIN="$WORK/plugin"
SRV="$WORK/srv"
export HOME="$WORK/home"
BIN_DIR="$HOME/.rogue/bin/rogue-hook"
mkdir -p "$HOME" "$SRV"
cp -R "$REPO/plugins/rogue" "$PLUGIN"
rm -f "$PLUGIN/rogue-hook.json"
unset ROGUE_NATIVE_BRIDGE_DIR ROGUE_NATIVE_BRIDGE ROGUE_NATIVE_BRIDGE_CLAUDE

cleanup() {
  [ -n "${MOCK_PID:-}" ] && { kill "$MOCK_PID"; wait "$MOCK_PID"; } 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# The mock picks a free port and reports it once listening.
python3 "$REPO/tests/native_bridge_server.py" 0 "$SRV" &
MOCK_PID=$!
for _ in $(seq 1 100); do
  [ -s "$SRV/port" ] && break
  kill -0 "$MOCK_PID" 2>/dev/null || break
  sleep 0.1
done
if [ ! -s "$SRV/port" ]; then
  if kill -0 "$MOCK_PID" 2>/dev/null; then echo "FAIL: mock server did not report its port within 10s"
  else echo "FAIL: mock server exited before reporting its port"; fi
  exit 1
fi
PORT="$(cat "$SRV/port")"

cat > "$HOME/.rogue-env" <<EOF2
export ROGUE_API_KEY=test-key
export ROGUE_BASE_URL=http://127.0.0.1:${PORT}
EOF2
chmod 600 "$HOME/.rogue-env"

# Stub binary: answers --version (or never does, with STUB_HANG) and echoes its arguments and stdin
# as the hook answer.
stub() { # <version>
  printf '#!/bin/sh\n[ "$1" = --version ] && [ -n "$STUB_HANG" ] && exec sleep 30\n[ "$1" = --version ] && { echo "rogue-hook %s"; exit 0; }\nprintf "{\\"native\\":\\"%%s %%s root=%%s\\",\\"stdin\\":%%s}" "$1" "$2" "$ROGUE_PLUGIN_ROOT" "$(cat)"\n' "$1" > "$SRV/blob"
}
sha() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } | cut -d ' ' -f 1; }
pin() { # <version> <sha256 for this platform>
  local platform
  case "$(uname -s)-$(uname -m)" in
    Darwin-*) platform=darwin-universal ;;
    Linux-x86_64) platform=linux-amd64 ;;
    *) platform=linux-arm64 ;;
  esac
  printf '{\n  "version": "%s",\n  "sha256": {\n    "%s": "%s"\n  }\n}\n' "$1" "$platform" "$2" > "$PLUGIN/rogue-hook.json"
}
install() { # [extra env...]
  : > "$SRV/requests"
  env ROGUE_API_KEY='' ROGUE_BASE_URL='' ROGUE_NATIVE_BRIDGE_RETRY=0 "$@" \
    "$SH" "$PLUGIN/scripts/native-bridge-install.sh" "$PLUGIN"
}
hook() { # <event> <payload> [extra env...]
  local event="$1" payload="$2"; shift 2
  printf '%s' "$payload" | env CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_ROOT="$PLUGIN" \
    ROGUE_BASE_URL=http://127.0.0.1:9 "$@" "$SH" "$PLUGIN/scripts/hook.sh" "$event"
}
log() { cat "$HOME/.rogue/hook-binary.log" 2>/dev/null; }
installed() { [ -x "$BIN_DIR/$1/rogue-hook" ] && echo present || echo absent; }

fails=0
check() { # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "  ok: $1"; else echo "FAIL: $1 (expected [$2], got [$3])"; fails=$((fails + 1)); fi
}
contains() { # <label> <needle> <haystack>
  case "$3" in *"$2"*) echo "  ok: $1" ;; *) echo "FAIL: $1 ([$2] not in [$3])"; fails=$((fails + 1)) ;; esac
}

echo "no pin: nothing installed, no download, the script keeps the event"
stub 0.1.0
install
check "no request" "" "$(cat "$SRV/requests")"
check "hook.sh answers itself" "{}" "$(hook PreToolUse '{}' ROGUE_API_KEY='')"

echo "pin, binary missing: hook.sh still answers itself and starts the download"
pin 0.1.0 "$(sha "$SRV/blob")"
# Under a group-writable umask too: the install must still be one the hand-off accepts.
check "script answer" "{}" "$(umask 002; hook PreToolUse '{}' ROGUE_API_KEY='' ROGUE_NATIVE_BRIDGE_RETRY=0)"
# The log line follows the rename, so wait for both.
for _ in $(seq 1 100); do [ "$(installed 0.1.0)" = present ] && case "$(log)" in *installed*) break ;; esac; sleep 0.1; done
check "the detached download installed it" "present" "$(installed 0.1.0)"
contains "log reports install" "rogue-hook 0.1.0: installed" "$(log)"
contains "lookup carries version and platform" "/api/v1/hooks/download?version=0.1.0&os=" "$(head -n 1 "$SRV/requests")"
contains "lookup carries the API key" "key=test-key" "$(head -n 1 "$SRV/requests")"
contains "presigned URL is fetched intact" "/blob?X-Amz-Signature=abc&X-Amz-Expires=300" "$(sed -n 2p "$SRV/requests")"

echo "binary present: hook.sh hands the event, its payload and the plugin root to it"
check "native answer relayed" "{\"native\":\"claude PreToolUse root=$PLUGIN\",\"stdin\":{\"tool_name\":\"Bash\"}}" "$(hook PreToolUse '{"tool_name":"Bash"}')"
check "managed hooks never hand off" '{}' "$(hook PreToolUse '{}' ROGUE_HOOK_SOURCE=managed ROGUE_API_KEY='' HOME="$WORK/empty")"
check "ROGUE_NATIVE_BRIDGE=0 keeps the script" '{}' "$(hook PreToolUse '{}' ROGUE_NATIVE_BRIDGE=0 ROGUE_API_KEY='' HOME="$WORK/empty")"
check "ROGUE_NATIVE_BRIDGE_CLAUDE=0 keeps the script" '{}' "$(hook PreToolUse '{}' ROGUE_NATIVE_BRIDGE_CLAUDE=0 ROGUE_API_KEY='' HOME="$WORK/empty")"
check "a relative plugin root never hands off" '{}' "$(cd "$WORK" && printf '{}' | env CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_ROOT=plugin ROGUE_API_KEY='' HOME="$WORK/empty" "$SH" plugin/scripts/hook.sh PreToolUse)"
printf 'export ROGUE_NATIVE_BRIDGE=0\nexport ROGUE_API_KEY=test-key\nexport ROGUE_BASE_URL=http://127.0.0.1:9\n' > "$WORK/kill-env"
mkdir -p "$WORK/kill-home"; cp "$WORK/kill-env" "$WORK/kill-home/.rogue-env"; chmod 600 "$WORK/kill-home/.rogue-env"
mkdir -p "$WORK/kill-home/.rogue/bin"; cp -R "$BIN_DIR" "$WORK/kill-home/.rogue/bin/"
check "the kill switch works from the env file" '{}' "$(hook PreToolUse '{}' HOME="$WORK/kill-home")"
check "heartbeat hands off" "{\"native\":\"heartbeat claude root=$PLUGIN\",\"stdin\":}" \
  "$(env CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_ROOT="$PLUGIN" "$SH" "$PLUGIN/scripts/heartbeat.sh" SessionStart </dev/null)"

echo "a binary another user could replace never runs"
chmod o+w "$BIN_DIR/0.1.0/rogue-hook"
check "other-writable binary keeps the script" '{}' "$(hook PreToolUse '{}' ROGUE_API_KEY='' ROGUE_NATIVE_BRIDGE_RETRY=0)"
chmod 755 "$BIN_DIR/0.1.0/rogue-hook"
chmod g+w "$BIN_DIR/0.1.0"
check "group-writable directory keeps the script" '{}' "$(hook PreToolUse '{}' ROGUE_API_KEY='' ROGUE_NATIVE_BRIDGE_RETRY=0)"
chmod 755 "$BIN_DIR/0.1.0"
check "a protected binary runs again" "{\"native\":\"claude PreToolUse root=$PLUGIN\",\"stdin\":{}}" "$(hook PreToolUse '{}')"

echo "an install root with a directory above it another user could replace: no exec, no installer"
chmod g+w "$HOME/.rogue/bin"
check "group-writable ancestor keeps the script" '{}' "$(hook PreToolUse '{}' ROGUE_API_KEY='' ROGUE_NATIVE_BRIDGE_RETRY=0)"
pin 0.6.0 "$(sha "$SRV/blob")"
: > "$SRV/requests"
check "a missing binary there keeps the script" '{}' "$(hook PreToolUse '{}' ROGUE_API_KEY='' ROGUE_NATIVE_BRIDGE_RETRY=0)"
sleep 2
check "no installer was started" "" "$(cat "$SRV/requests")"
install
check "the installer refuses it too" "" "$(cat "$SRV/requests")"
contains "and logs why" "rogue-hook 0.6.0: $BIN_DIR/0.6.0 is not protected from other users" "$(log)"
check "nothing written for it" "" "$(ls -A "$BIN_DIR" | grep 0.6.0)"
chmod g-w "$HOME/.rogue/bin"
pin 0.1.0 "$(sha "$SRV/blob")"

echo "an install root reached through another user's symlink: no exec"
ln -s "$BIN_DIR" "$WORK/link"
check "our own symlink is fine" "{\"native\":\"claude PreToolUse root=$PLUGIN\",\"stdin\":{}}" \
  "$(hook PreToolUse '{}' ROGUE_NATIVE_BRIDGE_DIR="$WORK/link")"
# Only root can chown a link, so a stat wrapper reports a foreign owner for it when asked without -L.
mkdir -p "$WORK/foreign-stat"
cat > "$WORK/foreign-stat/stat" <<EOF
#!/bin/sh
real=\$(PATH=/usr/bin:/bin command -v stat)
case "\$1:\$2" in -c:%u|-f:%u) ;; *) exec "\$real" "\$@" ;; esac
flag=\$1; shift 2
for p; do
  if [ "\$p" = "$WORK/link" ]; then echo 4242; else "\$real" "\$flag" '%u' "\$p" || exit 1; fi
done
EOF
chmod 755 "$WORK/foreign-stat/stat"
check "a foreign symlink keeps the script" '{}' \
  "$(hook PreToolUse '{}' ROGUE_NATIVE_BRIDGE_DIR="$WORK/link" PATH="$WORK/foreign-stat:$PATH" ROGUE_API_KEY='' ROGUE_NATIVE_BRIDGE_RETRY=0)"
rm "$WORK/link"

echo "already installed: no download"
install
check "no request" "" "$(cat "$SRV/requests")"

echo "a download that does not match the pin is never installed"
stub 0.2.0
pin 0.2.0 "0000000000000000000000000000000000000000000000000000000000000000"
install
check "no binary" "absent" "$(installed 0.2.0)"
contains "log reports mismatch" "sha256 mismatch" "$(log)"
check "no temp file left" "" "$(ls "$BIN_DIR/0.2.0" 2>/dev/null)"
check "the event stays on the script" "{}" "$(hook PreToolUse '{}' ROGUE_API_KEY='' ROGUE_NATIVE_BRIDGE_RETRY=999999 ROGUE_NATIVE_BRIDGE_DIR="$BIN_DIR" HOME="$WORK/empty")"

echo "a binary that reports another version is not installed"
pin 0.3.0 "$(sha "$SRV/blob")"
install
check "no binary" "absent" "$(installed 0.3.0)"
contains "log reports it" "does not run here" "$(log)"

echo "a failed attempt is not retried inside the retry interval"
install ROGUE_NATIVE_BRIDGE_RETRY=900
check "no request" "" "$(cat "$SRV/requests")"

echo "a binary that never answers --version is killed and not installed"
stub 0.5.0
pin 0.5.0 "$(sha "$SRV/blob")"
install STUB_HANG=1
check "no binary" "absent" "$(installed 0.5.0)"
contains "log reports it" "0.5.0: downloaded binary does not run here" "$(log)"
check "no temp file left" "" "$(ls -A "$BIN_DIR/0.5.0" 2>/dev/null)"
check "the lock is released" "absent" "$([ -e "$BIN_DIR/.lock-0.5.0" ] && echo present || echo absent)"

echo "a missing route answer installs nothing"
stub 0.4.0
pin 0.4.0 "$(sha "$SRV/blob")"
env ROGUE_API_KEY='' ROGUE_NATIVE_BRIDGE_RETRY=0 ROGUE_BASE_URL='' HOME="$WORK/nokey" \
  "$SH" "$PLUGIN/scripts/native-bridge-install.sh" "$PLUGIN"
check "no binary without an API key" "absent" "$(installed 0.4.0)"

[ "$fails" -eq 0 ] || { echo "FAIL: $fails check(s)"; exit 1; }
echo "OK: native bridge hand-off and install"
