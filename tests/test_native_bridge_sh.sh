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
PORT=$((RANDOM % 10000 + 30000))
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

cat > "$HOME/.rogue-env" <<EOF2
export ROGUE_API_KEY=test-key
export ROGUE_BASE_URL=http://127.0.0.1:${PORT}
EOF2
chmod 600 "$HOME/.rogue-env"

python3 "$REPO/tests/native_bridge_server.py" "$PORT" "$SRV" &
MOCK_PID=$!
for _ in $(seq 1 50); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.1; done

# Stub binary: answers --version and echoes its arguments and stdin as the hook answer.
stub() { # <version>
  printf '#!/bin/sh\n[ "$1" = --version ] && { echo "rogue-hook %s"; exit 0; }\nprintf "{\\"native\\":\\"%%s %%s root=%%s\\",\\"stdin\\":%%s}" "$1" "$2" "$ROGUE_PLUGIN_ROOT" "$(cat)"\n' "$1" > "$SRV/blob"
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
check "script answer" "{}" "$(hook PreToolUse '{}' ROGUE_API_KEY='' ROGUE_NATIVE_BRIDGE_RETRY=0)"
for _ in $(seq 1 50); do [ "$(installed 0.1.0)" = present ] && break; sleep 0.1; done
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

echo "a missing route answer installs nothing"
stub 0.4.0
pin 0.4.0 "$(sha "$SRV/blob")"
env ROGUE_API_KEY='' ROGUE_NATIVE_BRIDGE_RETRY=0 ROGUE_BASE_URL='' HOME="$WORK/nokey" \
  "$SH" "$PLUGIN/scripts/native-bridge-install.sh" "$PLUGIN"
check "no binary without an API key" "absent" "$(installed 0.4.0)"

[ "$fails" -eq 0 ] || { echo "FAIL: $fails check(s)"; exit 1; }
echo "OK: native bridge hand-off and install"
