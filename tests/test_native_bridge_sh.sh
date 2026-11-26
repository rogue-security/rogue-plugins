#!/usr/bin/env bash
# tests/test_native_bridge_sh.sh — the hand-off seam: native-bridge-install.sh downloads the
# native bridge for the first time through a mock /api/v1/hooks/download, verifies it against the
# pin and installs it at ~/.rogue/bin/rogue-hook; hook.sh then hands every event to it. A stub
# script stands in for the binary so this needs no Rust build.
#
# Override with TEST_SH=dash to catch bashisms (hooks.json runs every script via `sh`).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SH="${TEST_SH:-sh}"
WORK="$(mktemp -d)"
PLUGIN="$WORK/plugin"
SRV="$WORK/srv"
export HOME="$WORK/home"
BIN_DIR="$HOME/.rogue/bin"
BIN="$BIN_DIR/rogue-hook"
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
installed() { [ -x "$BIN" ] && echo present || echo absent; }
reported() { "$BIN" --version 2>/dev/null; }
staged() { ls -A "$HOME/.rogue/updates" 2>/dev/null; }

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
for _ in $(seq 1 100); do [ "$(installed)" = present ] && case "$(log)" in *installed*) break ;; esac; sleep 0.1; done
check "the detached download installed it" "present" "$(installed)"
check "at the fixed path" "rogue-hook 0.1.0" "$(reported)"
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
mkdir -p "$WORK/kill-home/.rogue/bin"; cp "$BIN" "$WORK/kill-home/.rogue/bin/"
check "the kill switch works from the env file" '{}' "$(hook PreToolUse '{}' HOME="$WORK/kill-home")"
rm -f "$PLUGIN/rogue-hook.json"
check "an installed binary gets the event with no pin" "{\"native\":\"claude PreToolUse root=$PLUGIN\",\"stdin\":{}}" "$(hook PreToolUse '{}')"
pin 0.1.0 "$(sha "$SRV/blob")"
check "heartbeat hands off" "{\"native\":\"heartbeat claude root=$PLUGIN\",\"stdin\":}" \
  "$(env CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_ROOT="$PLUGIN" "$SH" "$PLUGIN/scripts/heartbeat.sh" SessionStart </dev/null)"

echo "a binary another user could replace never runs"
chmod o+w "$BIN"
check "other-writable binary keeps the script" '{}' "$(hook PreToolUse '{}' ROGUE_API_KEY='' ROGUE_NATIVE_BRIDGE_RETRY=0)"
chmod 755 "$BIN"
chmod g+w "$BIN_DIR"
check "group-writable directory keeps the script" '{}' "$(hook PreToolUse '{}' ROGUE_API_KEY='' ROGUE_NATIVE_BRIDGE_RETRY=0)"
chmod 755 "$BIN_DIR"
check "a protected binary runs again" "{\"native\":\"claude PreToolUse root=$PLUGIN\",\"stdin\":{}}" "$(hook PreToolUse '{}')"

echo "an install root with a directory above it another user could replace: no exec, no installer"
chmod g+w "$HOME/.rogue"
check "group-writable ancestor keeps the script" '{}' "$(hook PreToolUse '{}' ROGUE_API_KEY='' ROGUE_NATIVE_BRIDGE_RETRY=0)"
mv "$BIN" "$WORK/saved-bin"
: > "$SRV/requests"
check "a missing binary there keeps the script" '{}' "$(hook PreToolUse '{}' ROGUE_API_KEY='' ROGUE_NATIVE_BRIDGE_RETRY=0)"
sleep 2
check "no installer was started" "" "$(cat "$SRV/requests")"
install
check "the installer refuses it too" "" "$(cat "$SRV/requests")"
contains "and logs why" "rogue-hook 0.1.0: $BIN_DIR is not protected from other users" "$(log)"
check "nothing written for it" "absent" "$(installed)"
chmod g-w "$HOME/.rogue"
mv "$WORK/saved-bin" "$BIN"

echo "an install root reached through a symlink: only root's own link is followed"
ln -s "$BIN_DIR" "$WORK/link"
check "our own symlink keeps the script" '{}' \
  "$(hook PreToolUse '{}' ROGUE_NATIVE_BRIDGE_DIR="$WORK/link" ROGUE_API_KEY='' ROGUE_NATIVE_BRIDGE_RETRY=0)"
mkdir -p "$WORK/empty-bin"; ln -s "$WORK/empty-bin" "$WORK/empty-link"
: > "$SRV/requests"
check "a missing binary under it keeps the script" '{}' \
  "$(hook PreToolUse '{}' ROGUE_NATIVE_BRIDGE_DIR="$WORK/empty-link" ROGUE_API_KEY='' ROGUE_NATIVE_BRIDGE_RETRY=0)"
sleep 2
check "and starts no installer" "" "$(cat "$SRV/requests")"
check "nothing written under it" "" "$(ls -A "$WORK/empty-bin")"
# Only root can chown a link, so a stat wrapper reports root as its owner when asked without -L.
# (On macOS every case here also runs through /var, a link root owns.)
mkdir -p "$WORK/root-stat"
cat > "$WORK/root-stat/stat" <<EOF
#!/bin/sh
real=\$(PATH=/usr/bin:/bin command -v stat)
case "\$1:\$2" in -c:%u|-f:%u) ;; *) exec "\$real" "\$@" ;; esac
flag=\$1; shift 2
for p; do
  if [ "\$p" = "$WORK/link" ]; then echo 0; else "\$real" "\$flag" '%u' "\$p" || exit 1; fi
done
EOF
chmod 755 "$WORK/root-stat/stat"
check "a root-owned symlink is followed" "{\"native\":\"claude PreToolUse root=$PLUGIN\",\"stdin\":{}}" \
  "$(hook PreToolUse '{}' ROGUE_NATIVE_BRIDGE_DIR="$WORK/link" PATH="$WORK/root-stat:$PATH")"
rm "$WORK/link"

echo "already installed: no download, and a binary that updated itself is never replaced"
printf '#!/bin/sh\necho "rogue-hook 9.9.9"\n' > "$BIN"
install
check "no request" "" "$(cat "$SRV/requests")"
check "the newer binary stays" "rogue-hook 9.9.9" "$(reported)"
rm -f "$BIN"

echo "an update lock held by the binary: the installer leaves the work to it"
LOCKFILE="$HOME/.rogue/.self-update.lock"
# Waited for, not killed: flock(1) hands the lock to its command, which would outlive it.
if command -v flock >/dev/null 2>&1; then
  flock "$LOCKFILE" sleep 3 & HOLDER=$!
else
  perl -MFcntl=:flock -e 'open(my $l, ">>", shift) or die; flock($l, LOCK_EX) or die; sleep 3' "$LOCKFILE" & HOLDER=$!
fi
sleep 1
install
check "no request while it is held" "" "$(cat "$SRV/requests")"
check "nothing installed" "absent" "$(installed)"
wait "$HOLDER" 2>/dev/null || true
install
check "installed once it is free" "rogue-hook 0.1.0" "$(reported)"
rm -f "$BIN"

echo "a download that does not match the pin is never installed"
stub 0.2.0
pin 0.2.0 "0000000000000000000000000000000000000000000000000000000000000000"
install
check "no binary" "absent" "$(installed)"
contains "log reports mismatch" "sha256 mismatch" "$(log)"
check "no temp file left" "" "$(staged)"
check "the event stays on the script" "{}" "$(hook PreToolUse '{}' ROGUE_API_KEY='' ROGUE_NATIVE_BRIDGE_RETRY=999999 ROGUE_NATIVE_BRIDGE_DIR="$BIN_DIR" HOME="$WORK/empty")"

echo "a binary that reports another version is not installed"
pin 0.3.0 "$(sha "$SRV/blob")"
install
check "no binary" "absent" "$(installed)"
contains "log reports it" "does not run here" "$(log)"

echo "a failed attempt is not retried inside the retry interval"
install ROGUE_NATIVE_BRIDGE_RETRY=900
check "no request" "" "$(cat "$SRV/requests")"

echo "a binary that never answers --version is killed and not installed"
stub 0.5.0
pin 0.5.0 "$(sha "$SRV/blob")"
install STUB_HANG=1
check "no binary" "absent" "$(installed)"
contains "log reports it" "0.5.0: downloaded binary does not run here" "$(log)"
check "no temp file left" "" "$(staged)"

echo "a missing route answer installs nothing"
stub 0.4.0
pin 0.4.0 "$(sha "$SRV/blob")"
env ROGUE_API_KEY='' ROGUE_NATIVE_BRIDGE_RETRY=0 ROGUE_BASE_URL='' HOME="$WORK/nokey" \
  "$SH" "$PLUGIN/scripts/native-bridge-install.sh" "$PLUGIN"
check "no binary without an API key" "absent" "$(installed)"

echo "a protected Mac: the extension denies the rename and installs the binary from its .sig"
# Stands in for the macOS endpoint's extension: every rename onto the hook fails with EPERM, and
# the extension writes the source itself only when <source>.sig holds the release's signature.
SIGNATURE='dW50cnVzdGVk+IGNvbW1lbnQ6/c2lnbmF0dXJl='
mkdir -p "$WORK/sysext"
cat > "$WORK/sysext/mv" <<SHIM
#!/bin/sh
for dest; do :; done
src=""; for a; do case "\$a" in -*) ;; *) [ -n "\$src" ] || src=\$a ;; esac; done
[ "\$dest" = "$BIN" ] || exec /bin/mv "\$@"
[ "\$(cat "\$src.sig" 2>/dev/null)" = "$SIGNATURE" ] && cp "\$src" "\$dest"
echo "mv: rename \$src to \$dest: Operation not permitted" >&2
exit 1
SHIM
chmod 755 "$WORK/sysext/mv"
stub 0.1.0
pin 0.1.0 "$(sha "$SRV/blob")"
rm -f "$BIN"
printf '%s' "$SIGNATURE" > "$SRV/signature"
install PATH="$WORK/sysext:$PATH"
check "the extension installed it" "rogue-hook 0.1.0" "$(reported)"
contains "log reports install" "rogue-hook 0.1.0: installed" "$(tail -n 1 "$HOME/.rogue/hook-binary.log")"
check "no temp file or signature left" "" "$(staged)"
rm -f "$BIN" "$SRV/signature"
install PATH="$WORK/sysext:$PATH"
check "no signature from the route: nothing installed" "absent" "$(installed)"
contains "log reports it" "cannot install $BIN" "$(tail -n 1 "$HOME/.rogue/hook-binary.log")"
check "no temp file left" "" "$(staged)"

echo "install.sh installs the binary from the pin of a plugin it installed"
stub 0.1.0
pin 0.1.0 "$(sha "$SRV/blob")"
rm -f "$BIN" "$HOME/.rogue/.native-bridge-attempt"
OUT="$(env ROGUE_API_KEY='' ROGUE_BASE_URL='' ROGUE_INSTALL_LIB_ONLY=1 \
  bash -c '. "$1/install.sh"; CURSOR_INSTALL_DIR="$2"; install_native_bridge' sh "$REPO" "$PLUGIN" 2>&1)"
check "installed at the fixed path" "rogue-hook 0.1.0" "$(reported)"
contains "and says so" "Native bridge" "$OUT"

[ "$fails" -eq 0 ] || { echo "FAIL: $fails check(s)"; exit 1; }
echo "OK: native bridge hand-off and install"
