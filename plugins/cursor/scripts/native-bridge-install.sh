#!/bin/sh
# Installs the native bridge pinned in <plugin>/rogue-hook.json - SHARED, started detached by
# native-bridge.sh whenever the pinned version is missing.
#
#   sh native-bridge-install.sh <plugin-root>
#
# ONE COPY IS EDITABLE: scripts/shared/native-bridge-install.sh (see sync-shared-scripts.sh).
#
# Downloads through GET /api/v1/hooks/download with the API key, then installs only a file whose
# sha256 matches the pin and whose --version reports the pinned version, by an atomic rename into
# ~/.rogue/bin/rogue-hook/<version>/rogue-hook. Any failure leaves nothing at that path, so the
# script bridge keeps handling events. A failed attempt is retried after
# ROGUE_NATIVE_BRIDGE_RETRY seconds (default 900, numeric zero = every time), never per event.
# Every attempt's outcome is appended to ~/.rogue/hook-binary.log.

ROOT="${1:-}"
case "$ROOT" in /*) ;; *) exit 0 ;; esac

# Git Bash stand-down: native-bridge-install.ps1 owns native Windows.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) exit 0 ;;
esac

. "$ROOT/scripts/native-bridge.sh" 2>/dev/null || exit 0
VERSION="$(rogue_native_pinned_version "$ROOT")"
[ -n "$VERSION" ] || exit 0
DIR="$(rogue_native_dir)"
DEST="$DIR/$VERSION/rogue-hook"
[ -x "$DEST" ] && exit 0

mkdir -p "$HOME/.rogue" "$DIR" 2>/dev/null || exit 0
LOG="$HOME/.rogue/hook-binary.log"
say() { printf '%s rogue-hook %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$VERSION" "$1" >> "$LOG" 2>/dev/null; }

# One attempt at a time, and not again until the retry interval has passed.
LOCK="$DIR/.lock-$VERSION"
if ! mkdir "$LOCK" 2>/dev/null; then
  [ -n "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ] || exit 0
  rmdir "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null || exit 0
fi
TMP=""
trap 'rmdir "$LOCK" 2>/dev/null; [ -n "$TMP" ] && rm -f "$TMP"' EXIT
STAMP="$DIR/.attempt-$VERSION"
RETRY="${ROGUE_NATIVE_BRIDGE_RETRY:-900}"
case "$RETRY" in ''|*[!0-9]*) RETRY=900 ;; esac
[ "${#RETRY}" -gt 9 ] && RETRY=900
if [ "$RETRY" -gt 0 ] && [ -r "$STAMP" ]; then
  LAST="$(head -n 1 "$STAMP" 2>/dev/null | tr -d '[:space:]')"
  NOW="$(date -u +%s)"
  case "$LAST" in ''|*[!0-9]*) LAST="" ;; esac
  if [ -n "$LAST" ] && [ "${#LAST}" -le 18 ] && [ "$LAST" -le "$NOW" ] && [ $((NOW - LAST)) -lt "$RETRY" ]; then
    exit 0
  fi
fi
date -u +%s > "$STAMP" 2>/dev/null

give_up() { say "$1; the script bridge handles events"; exit 0; }

pinned() { sed -n "s/^[[:space:]]*\"$1\"[[:space:]]*:[[:space:]]*\"\([0-9a-f]*\)\".*/\1/p" "$ROOT/rogue-hook.json" 2>/dev/null | head -n 1; }
sha256() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1" 2>/dev/null; } | cut -d ' ' -f 1; }

# macOS ships one universal binary, so its arch is only a label for the route.
case "$(uname -s)-$(uname -m)" in
  Darwin-*) OS=darwin ARCH=arm64 PLATFORM=darwin-universal ;;
  Linux-x86_64|Linux-amd64) OS=linux ARCH=amd64 PLATFORM=linux-amd64 ;;
  Linux-aarch64|Linux-arm64) OS=linux ARCH=arm64 PLATFORM=linux-arm64 ;;
  *) give_up "unsupported platform $(uname -s)-$(uname -m)" ;;
esac
WANT="$(pinned "$PLATFORM")"
[ -n "$WANT" ] || give_up "no pinned sha256 for $PLATFORM"

# Same env file rule as the hooks: the first trusted file holding ROGUE_API_KEY is used alone.
if [ -r "$ROOT/scripts/env-file.sh" ]; then
  . "$ROOT/scripts/env-file.sh"
  for _env_file in /etc/rogue/env "$ROOT/env" "$HOME/.rogue-env"; do
    if rogue_env_is_trusted "$_env_file" && grep -Eq "^[[:space:]]*(export[[:space:]]+)?ROGUE_API_KEY=[\"']?[^\"'[:space:]]" "$_env_file"; then
      . "$_env_file"; break
    fi
  done
fi
[ -n "${ROGUE_API_KEY:-}" ] || give_up "no ROGUE_API_KEY"
command -v curl >/dev/null 2>&1 || give_up "no curl"

BASE="${ROGUE_BASE_URL:-https://api.rogue.security}"
URL="$(curl -fsS --max-time 15 -H "x-rogue-api-key: $ROGUE_API_KEY" \
  "${BASE%/}/api/v1/hooks/download?version=$VERSION&os=$OS&arch=$ARCH" 2>/dev/null |
  sed -n 's/.*"url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed 's/\\u0026/\&/g')"
[ -n "$URL" ] || give_up "no download URL for $PLATFORM"

mkdir -p "$DIR/$VERSION" 2>/dev/null || give_up "cannot create $DIR/$VERSION"
TMP="$DIR/$VERSION/.rogue-hook.download.$$"
curl -fsS --max-time 120 -o "$TMP" "$URL" 2>/dev/null || give_up "download failed"
GOT="$(sha256 "$TMP")"
[ "$GOT" = "$WANT" ] || give_up "sha256 mismatch: got $GOT, pinned $WANT"
chmod 755 "$TMP" 2>/dev/null
# Catches a binary this machine cannot run (noexec mount, wrong arch) before a hook would exec it.
[ "$("$TMP" --version 2>/dev/null)" = "rogue-hook $VERSION" ] || give_up "downloaded binary does not run here"
mv -f "$TMP" "$DEST" 2>/dev/null || give_up "cannot install $DEST"
TMP=""
rm -f "$STAMP" 2>/dev/null
say "installed ($PLATFORM)"
exit 0
