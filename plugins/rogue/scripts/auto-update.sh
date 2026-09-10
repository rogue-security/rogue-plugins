#!/usr/bin/env bash
# Silent plugin auto-updater. Fires from the SessionStart hook in the
# background so it never blocks Claude Code startup. Compares the installed
# plugin version against the "claude" key of the latest release's versions.json;
# if newer, re-runs the one-line installer to upgrade in place. New version takes
# effect on the next session.
#
# Opt-outs:
#   ROGUE_AUTO_UPDATE=0       — disable entirely
#   ROGUE_PLUGIN_VERSION=<release> — pinned, never updates
#
# Runs at most once per 24h (cached in ~/.rogue/.auto-update-check).
# Silent on every failure path. All activity logs to ~/.rogue/auto-update.log
# for diagnostics.

[ -z "${CLAUDE_CODE_ENTRYPOINT:-}" ] && exit 0

# Git Bash stand-down: auto-update.ps1 owns native Windows (same reason as hook.sh).
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) exit 0 ;;
esac

set -u

LOG="$HOME/.rogue/auto-update.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || exit 0
exec >>"$LOG" 2>&1
date "+%F %T --- auto-update tick ---"

# Same env file rule as the hooks. The bundled ${CLAUDE_PLUGIN_ROOT}/env is where
# compiled/managed plugins pin flags like ROGUE_AUTO_UPDATE=0 or ROGUE_PLUGIN_VERSION.
# The first env file holding ROGUE_API_KEY is used alone: machine, bundled, user.
for _env_file in /etc/rogue/env "${CLAUDE_PLUGIN_ROOT:-}/env" "$HOME/.rogue-env"; do
  if [ -r "$_env_file" ] && grep -Eq '^[[:space:]]*(export[[:space:]]+)?ROGUE_API_KEY=' "$_env_file"; then
    . "$_env_file"; break
  fi
done

if [ "${ROGUE_AUTO_UPDATE:-1}" = "0" ]; then
  echo "ROGUE_AUTO_UPDATE=0, skipping"
  exit 0
fi
if [ -n "${ROGUE_PLUGIN_VERSION:-}" ]; then
  echo "ROGUE_PLUGIN_VERSION=$ROGUE_PLUGIN_VERSION pinned, skipping"
  exit 0
fi

# Rate-limit to once per day.
CACHE="$HOME/.rogue/.auto-update-check"
TTL=86400
if [ -f "$CACHE" ]; then
  NOW=$(date +%s 2>/dev/null || echo 0)
  MTIME=$(stat -f %m "$CACHE" 2>/dev/null || stat -c %Y "$CACHE" 2>/dev/null || echo 0)
  if [ $((NOW - MTIME)) -lt "$TTL" ]; then
    echo "checked within TTL, skipping"
    exit 0
  fi
fi
touch "$CACHE" 2>/dev/null

# ROGUE_PLUGIN_REPO is load-bearing beyond its default: rogue-ui's
# hooks-matcher.ts whitelists Rogue's own updater by matching a repo slug AND one
# of ROGUE_NON_INTERACTIVE / ROGUE_AUTO_UPDATE / ROGUE_INSTALLER_URL /
# ROGUE_PLUGIN_REPO. Drop it and this script starts reading as a suspicious hook
# on every install in the field.
REPO="${ROGUE_PLUGIN_REPO:-rogue-security/rogue-plugins}"

# True when $2 is strictly newer than $1, comparing X.Y.Z field by field as
# NUMBERS. The old code string-compared the release tag against "v${installed}",
# which cannot tell newer from older: once a release name stops carrying a
# version, a manifest sitting BEHIND the install would re-run the installer every
# 24h forever. Both inputs are bare X.Y.Z (plugin.json and the manifest are both
# validated to that shape), so three fields is the whole domain.
_rogue_newer() { # <installed> <candidate>
  _a="$1"; _b="$2"
  _a1=${_a%%.*}; _ar=${_a#*.}; _a2=${_ar%%.*}; _a3=${_ar##*.}
  _b1=${_b%%.*}; _br=${_b#*.}; _b2=${_br%%.*}; _b3=${_br##*.}
  [ "$_b1" -gt "$_a1" ] && return 0
  [ "$_b1" -lt "$_a1" ] && return 1
  [ "$_b2" -gt "$_a2" ] && return 0
  [ "$_b2" -lt "$_a2" ] && return 1
  [ "$_b3" -gt "$_a3" ] && return 0
  return 1
}

PLUGIN_JSON="${CLAUDE_PLUGIN_ROOT:-}/.claude-plugin/plugin.json"
if [ ! -f "$PLUGIN_JSON" ]; then
  echo "no plugin.json at $PLUGIN_JSON"
  exit 0
fi
# Read the version WITHOUT python3 — the /usr/bin/python3 stub fails silently on
# a fresh macOS (no Xcode CLT), which would mask updates. grep/sed are always
# present (same approach as heartbeat.sh / plugin-versions.sh).
INSTALLED=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9][^"]*"' "$PLUGIN_JSON" 2>/dev/null \
  | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
if [ -z "$INSTALLED" ]; then
  echo "no installed version found"
  exit 0
fi

# The release NAME is not a version — the monorepo ships six independently
# versioned plugins. versions.json is the contract; this plugin's key is "claude".
MANIFEST_URL="https://github.com/${REPO}/releases/latest/download/versions.json"
LATEST=$(curl -fsSL --max-time 5 "$MANIFEST_URL" 2>/dev/null \
  | tr -d ' \t\n\r' \
  | grep -oE '"claude":"[0-9]+\.[0-9]+\.[0-9]+"' | head -1 \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
if [ -z "$LATEST" ]; then
  echo "could not resolve latest claude version from $MANIFEST_URL"
  exit 0
fi

if ! _rogue_newer "$INSTALLED" "$LATEST"; then
  echo "up to date at $INSTALLED (manifest says $LATEST)"
  exit 0
fi

echo "upgrade available: $INSTALLED -> $LATEST, running installer"

# Re-run the one-line installer in non-interactive mode. Creds already in env
# from sourcing ~/.rogue-env above, so no prompts.
INSTALLER_URL="${ROGUE_INSTALLER_URL:-https://raw.githubusercontent.com/rogue-security/rogue-plugins/main/install.sh}"
unset ROGUE_BASE_URL
curl -fsSL --max-time 60 "$INSTALLER_URL" | ROGUE_NON_INTERACTIVE=1 bash
RC=$?
echo "installer exited rc=$RC"
