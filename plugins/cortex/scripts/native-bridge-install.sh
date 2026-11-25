#!/bin/sh
# Installs the native bridge for the first time - SHARED, started detached by native-bridge.sh
# whenever ~/.rogue/bin/rogue-hook is missing and the plugin ships rogue-hook.json.
#
#   sh native-bridge-install.sh <plugin-root>
#
# ONE COPY IS EDITABLE: scripts/shared/native-bridge-install.sh (see sync-shared-scripts.sh).
#
# rogue-hook.json is the trust root for this first download only: once installed, the binary
# updates itself from the Rogue API and checks each release's signature. Downloads through
# GET /api/v1/hooks/download with the API key, then installs only a file whose sha256 matches the
# pin and whose --version reports the pinned version, by an atomic rename onto
# ~/.rogue/bin/rogue-hook. It holds the binary's own update lock (~/.rogue/.self-update.lock) and
# installs only while that path is still empty, so it never replaces a binary that updated itself.
# Any failure leaves nothing at that path, so the script bridge keeps handling events. A failed
# attempt is retried after ROGUE_NATIVE_BRIDGE_RETRY seconds (default 900, numeric zero = every
# time), never per event. Every attempt's outcome is appended to ~/.rogue/hook-binary.log.

ROOT="${1:-}"
case "$ROOT" in /*) ;; *) exit 0 ;; esac

# Git Bash stand-down: native-bridge-install.ps1 owns native Windows.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) exit 0 ;;
esac

. "$ROOT/scripts/native-bridge.sh" 2>/dev/null || exit 0
# Same env file rule as the hooks, read first so ROGUE_NATIVE_BRIDGE_DIR resolves as theirs does: the first trusted file holding ROGUE_API_KEY is used alone.
if [ -r "$ROOT/scripts/env-file.sh" ]; then
  . "$ROOT/scripts/env-file.sh"
  for _env_file in /etc/rogue/env "$ROOT/env" "$HOME/.rogue-env"; do
    if rogue_env_is_trusted "$_env_file" && grep -Eq "^[[:space:]]*(export[[:space:]]+)?ROGUE_API_KEY=[\"']?[^\"'[:space:]]" "$_env_file"; then
      . "$_env_file"; break
    fi
  done
fi
VERSION="$(rogue_native_pinned_version "$ROOT")"
[ -n "$VERSION" ] || exit 0
DIR="$(rogue_native_dir)"
DEST="$DIR/rogue-hook"
[ -e "$DEST" ] && exit 0

# The hand-off runs only a binary in a directory nobody else can write.
umask 022
mkdir -p "$HOME/.rogue" 2>/dev/null || exit 0
LOG="$HOME/.rogue/hook-binary.log"
say() { printf '%s rogue-hook %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$VERSION" "$1" >> "$LOG" 2>/dev/null; }
give_up() { say "$1; the script bridge handles events"; exit 0; }

# One install or update at a time: the binary's own OS file lock, so this never races a
# self-update. Taken without waiting (whoever holds it is already doing the work), and released by
# the OS if this process dies. The script runs again under it.
if [ "${ROGUE_NATIVE_BRIDGE_LOCKED:-}" != 1 ]; then
  ROGUE_NATIVE_BRIDGE_LOCKED=1; export ROGUE_NATIVE_BRIDGE_LOCKED
  LOCK="$HOME/.rogue/.self-update.lock"
  if command -v flock >/dev/null 2>&1; then
    # A held lock makes flock exit 1; this step always exits 0.
    flock -n "$LOCK" sh "$0" "$ROOT"
    exit 0
  elif command -v perl >/dev/null 2>&1; then
    # $^F keeps the lock's descriptor open across exec.
    exec perl -MFcntl=:flock -e '$^F = 255; open(my $l, ">>", shift) or exit 0; flock($l, LOCK_EX | LOCK_NB) or exit 0; exec @ARGV or exit 0' \
      "$LOCK" sh "$0" "$ROOT"
  fi
  give_up "no flock or perl to take the update lock"
fi
# The holder before this one may have installed it.
[ -e "$DEST" ] && exit 0

# Same rule as the hand-off, before and after creating the install directory: another user must not
# be able to replace any directory above it.
command -v rogue_nearest_dir_is_protected >/dev/null 2>&1 || exit 0
unsafe() { say "$DIR is not protected from other users; the script bridge handles events"; exit 0; }
rogue_nearest_dir_is_protected "$DEST" || unsafe

STAMP="$HOME/.rogue/.native-bridge-attempt"
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

[ -n "${ROGUE_API_KEY:-}" ] || give_up "no ROGUE_API_KEY"
command -v curl >/dev/null 2>&1 || give_up "no curl"

BASE="${ROGUE_BASE_URL:-https://api.rogue.security}"
URL="$(curl -fsS --max-time 15 -H "x-rogue-api-key: $ROGUE_API_KEY" \
  "${BASE%/}/api/v1/hooks/download?version=$VERSION&os=$OS&arch=$ARCH" 2>/dev/null |
  sed -n 's/.*"url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed 's/\\u0026/\&/g')"
[ -n "$URL" ] || give_up "no download URL for $PLATFORM"

# Staged beside the binary's own updates: on the same volume, so the rename is atomic.
STAGE="$HOME/.rogue/updates"
mkdir -p "$STAGE" "$DIR" 2>/dev/null || give_up "cannot create $DIR"
rogue_nearest_dir_is_protected "$DEST" || give_up "$DIR is not protected from other users"
TMP="$STAGE/rogue-hook.first.$$"
trap 'rm -f "$TMP" "$TMP.version"' EXIT
curl -fsS --max-time 120 -o "$TMP" "$URL" 2>/dev/null || give_up "download failed"
GOT="$(sha256 "$TMP")"
[ "$GOT" = "$WANT" ] || give_up "sha256 mismatch: got $GOT, pinned $WANT"
chmod 755 "$TMP" 2>/dev/null
# Catches a binary this machine cannot run (noexec mount, wrong arch) before a hook would exec it.
# Bounded like native-bridge-install.mjs: one that stalls is killed rather than holding the lock.
"$TMP" --version >"$TMP.version" 2>/dev/null &
PROBE=$!
WAITED=0
while kill -0 "$PROBE" 2>/dev/null && [ "$WAITED" -lt 10 ]; do sleep 1; WAITED=$((WAITED + 1)); done
kill -9 "$PROBE" 2>/dev/null
wait "$PROBE" 2>/dev/null
REPORTED="$(cat "$TMP.version" 2>/dev/null)"
[ "$REPORTED" = "rogue-hook $VERSION" ] || give_up "downloaded binary does not run here"
mv -f "$TMP" "$DEST" 2>/dev/null || give_up "cannot install $DEST"
rm -f "$STAMP" 2>/dev/null
say "installed ($PLATFORM)"
exit 0
