#!/bin/sh
# Installs the native hook dispatcher pinned in rogue-hook.json as
# $CLAUDE_PLUGIN_DATA/rogue-hook. hook.sh hands every event to that binary when it
# exists, so it does the same work without jq, sed or a dozen subprocesses per event.
# Fired detached from SessionStart. Fail-safe: whenever no binary matching the pin is
# installed, hook.sh keeps handling events itself.
#
# The binary is downloaded through GET /api/v1/hooks/binary with the API key and must
# match the pinned sha256 and report the pinned version before it replaces anything.
# The last run's outcome is written to ~/.rogue/hook-binary.log.

[ -z "${CLAUDE_CODE_ENTRYPOINT:-}" ] && exit 0

# Git Bash stand-down: hook-binary.ps1 owns native Windows (same reason as hook.sh).
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) exit 0 ;;
esac

[ -n "${CLAUDE_PLUGIN_DATA:-}" ] || exit 0
BIN="$CLAUDE_PLUGIN_DATA/rogue-hook"
PIN="${CLAUDE_PLUGIN_ROOT:-}/rogue-hook.json"

mkdir -p "$HOME/.rogue" 2>/dev/null || exit 0
exec >"$HOME/.rogue/hook-binary.log" 2>&1
date "+%F %T"

# rogue-hook.json is written by the release workflow with one "key": "value" per line.
pinned() { sed -n "s/^ *\"$1\": *\"\([^\"]*\)\".*/\1/p" "$PIN" 2>/dev/null | head -n 1; }
sha256() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } | cut -d ' ' -f 1; }
use_scripts() { rm -f "$BIN"; echo "$1; hook.sh handles events"; exit 0; }

VERSION=$(pinned version)
[ -n "$VERSION" ] || use_scripts "no pinned version"

# macOS ships one universal binary, so its arch is only a label for the route.
case "$(uname -s)-$(uname -m)" in
  Darwin-*) OS=darwin ARCH=arm64 PLATFORM=darwin-universal ;;
  Linux-x86_64|Linux-amd64) OS=linux ARCH=amd64 PLATFORM=linux-amd64 ;;
  Linux-aarch64|Linux-arm64) OS=linux ARCH=arm64 PLATFORM=linux-arm64 ;;
  *) use_scripts "unsupported platform $(uname -s)-$(uname -m)" ;;
esac
WANT=$(pinned "$PLATFORM")
[ -n "$WANT" ] || use_scripts "no pinned sha256 for $PLATFORM"

if [ -f "$BIN" ] && [ "$(sha256 "$BIN")" = "$WANT" ]; then
  echo "rogue-hook $VERSION already installed"
  exit 0
fi
# Never leave a binary that does not match the pin in charge while the download runs.
rm -f "$BIN"

# Same env file rule as the hooks: the first trusted file holding ROGUE_API_KEY is used alone.
_env_lib="$(dirname -- "$0")/env-file.sh"
if [ -r "$_env_lib" ]; then
  . "$_env_lib"
  for _env_file in /etc/rogue/env "${CLAUDE_PLUGIN_ROOT:-}/env" "$HOME/.rogue-env"; do
    if rogue_env_is_trusted "$_env_file" && grep -Eq "^[[:space:]]*(export[[:space:]]+)?ROGUE_API_KEY=[\"']?[^\"'[:space:]]" "$_env_file"; then
      . "$_env_file"; break
    fi
  done
fi
[ -n "${ROGUE_API_KEY:-}" ] || use_scripts "no ROGUE_API_KEY"

BASE="${ROGUE_BASE_URL:-https://api.rogue.security}"
URL=$(curl -fsS --max-time 15 -H "x-rogue-api-key: $ROGUE_API_KEY" \
  "${BASE%/}/api/v1/hooks/binary?version=$VERSION&os=$OS&arch=$ARCH" |
  sed -n 's/.*"url": *"\([^"]*\)".*/\1/p')
[ -n "$URL" ] || use_scripts "no download URL for rogue-hook $VERSION $PLATFORM"

mkdir -p "$CLAUDE_PLUGIN_DATA" || use_scripts "cannot create $CLAUDE_PLUGIN_DATA"
TMP="$BIN.download.$$"
trap 'rm -f "$TMP"' EXIT
curl -fsS --max-time 60 -o "$TMP" "$URL" || use_scripts "download failed"
GOT=$(sha256 "$TMP")
[ "$GOT" = "$WANT" ] || use_scripts "sha256 mismatch: got $GOT, pinned $WANT"
chmod 755 "$TMP"
# Catches a binary this machine cannot run (noexec mount, unexpected arch) before hook.sh would exec it.
[ "$("$TMP" --version 2>/dev/null)" = "rogue-hook $VERSION" ] || use_scripts "downloaded binary does not run here"
mv -f "$TMP" "$BIN" || use_scripts "cannot install $BIN"
echo "installed rogue-hook $VERSION ($PLATFORM)"
exit 0
