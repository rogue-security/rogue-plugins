#!/usr/bin/env bash
# tests/test_hook_binary_sh.sh — end-to-end for the native dispatcher hand-off:
# hook-binary.sh downloads the pinned binary through a mock /api/v1/hooks/binary,
# verifies it, installs it into CLAUDE_PLUGIN_DATA, and hook.sh then execs it.
# A stub script stands in for the binary so this needs no Rust build.
#
# Override with TEST_SH=dash to catch bashisms (hooks.json runs both scripts via `sh`).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SH="${TEST_SH:-sh}"
PORT=$((RANDOM % 10000 + 30000))
WORK="$(mktemp -d)"
PLUGIN="$WORK/plugin"
DATA="$WORK/data"
SRV="$WORK/srv"
export HOME="$WORK/home"
mkdir -p "$HOME" "$SRV" "$DATA"
cp -R "$REPO/plugins/rogue" "$PLUGIN"

cleanup() {
  [ -n "${MOCK_PID:-}" ] && { kill "$MOCK_PID"; wait "$MOCK_PID"; } 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

cat > "$HOME/.rogue-env" <<EOF
export ROGUE_API_KEY=test-key
export ROGUE_BASE_URL=http://127.0.0.1:${PORT}
EOF
chmod 600 "$HOME/.rogue-env"

python3 "$REPO/tests/hook_binary_server.py" "$PORT" "$SRV" &
MOCK_PID=$!
for _ in $(seq 1 50); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.1; done

# Stub binary: answers --version and echoes the event and its stdin as the hook response.
stub() { # <version>
  printf '#!/bin/sh\n[ "$1" = --version ] && { echo "rogue-hook %s"; exit 0; }\nprintf "{\\"native\\":\\"%%s %%s\\",\\"stdin\\":%%s}" "$1" "$2" "$(cat)"\n' "$1" > "$SRV/blob"
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
install() {
  : > "$SRV/requests"
  CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PLUGIN_DATA="$DATA" \
    ROGUE_API_KEY='' ROGUE_BASE_URL='' "$SH" "$PLUGIN/scripts/hook-binary.sh"
}
hook() { # <event> <payload> [extra env...]
  local event="$1" payload="$2"; shift 2
  printf '%s' "$payload" | env CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_ROOT="$PLUGIN" \
    CLAUDE_PLUGIN_DATA="$DATA" ROGUE_BASE_URL=http://127.0.0.1:9 "$@" "$SH" "$PLUGIN/scripts/hook.sh" "$event"
}
log() { cat "$HOME/.rogue/hook-binary.log"; }

fails=0
check() { # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "  ok: $1"; else echo "FAIL: $1 (expected [$2], got [$3])"; fails=$((fails + 1)); fi
}
contains() { # <label> <needle> <haystack>
  case "$3" in *"$2"*) echo "  ok: $1" ;; *) echo "FAIL: $1 ([$2] not in [$3])"; fails=$((fails + 1)) ;; esac
}

echo "no pin: nothing installed and hook.sh keeps the event"
stub 0.1.0
install
check "no binary" "absent" "$([ -e "$DATA/rogue-hook" ] && echo present || echo absent)"
contains "log names the reason" "no pinned version" "$(log)"
check "no download attempted" "" "$(cat "$SRV/requests")"

echo "matching pin: downloaded with the API key, verified and installed"
pin 0.1.0 "$(sha "$SRV/blob")"
install
check "binary installed" "present" "$([ -x "$DATA/rogue-hook" ] && echo present || echo absent)"
contains "log reports install" "installed rogue-hook 0.1.0" "$(log)"
contains "lookup carries version and platform" "/api/v1/hooks/binary?version=0.1.0&os=" "$(head -n 1 "$SRV/requests")"
contains "lookup carries the API key" "key=test-key" "$(head -n 1 "$SRV/requests")"
contains "presigned URL is fetched intact" "/blob?X-Amz-Signature=abc&X-Amz-Expires=300" "$(sed -n 2p "$SRV/requests")"

echo "hook.sh hands the event and its payload to the binary"
check "native response relayed" '{"native":"claude PreToolUse","stdin":{"tool_name":"Bash"}}' "$(hook PreToolUse '{"tool_name":"Bash"}')"
check "managed hooks never hand off" '{}' "$(hook PreToolUse '{}' ROGUE_HOOK_SOURCE=managed HOME="$WORK/empty")"

echo "already installed: no download"
install
contains "log reports current" "rogue-hook 0.1.0 already installed" "$(log)"
check "no request" "" "$(cat "$SRV/requests")"

echo "new pin whose download does not match: old binary removed, scripts take over"
stub 0.2.0
pin 0.2.0 "0000000000000000000000000000000000000000000000000000000000000000"
install
check "no binary" "absent" "$([ -e "$DATA/rogue-hook" ] && echo present || echo absent)"
contains "log reports mismatch" "sha256 mismatch" "$(log)"
check "no temp file left" "" "$(ls "$DATA")"

echo "binary that reports another version is not installed"
pin 0.3.0 "$(sha "$SRV/blob")"
install
check "no binary" "absent" "$([ -e "$DATA/rogue-hook" ] && echo present || echo absent)"
contains "log reports it" "does not run here" "$(log)"

echo "outside Claude Code: nothing runs"
: > "$SRV/requests"
CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PLUGIN_DATA="$DATA" CLAUDE_CODE_ENTRYPOINT='' "$SH" "$PLUGIN/scripts/hook-binary.sh"
check "no request" "" "$(cat "$SRV/requests")"

[ "$fails" -eq 0 ] || { echo "FAIL: $fails check(s)"; exit 1; }
echo "OK: hook binary install and hand-off"
