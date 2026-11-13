#!/usr/bin/env bash
# Rogue Security - Snowflake Cortex Code hook installer (CLI and Desktop).
# Cortex Code loads every plugin under <cortex dir>/plugins, including its
# hooks/hooks.json, so installing is copying this plugin there. No user settings
# file is edited, and other hooks and plugins are untouched.
#
# Usage: bash install.sh [--uninstall | --status]
set -u

if [ -n "${CORTEX_HOME:-}" ]; then CORTEX_DIR="$CORTEX_HOME"
elif [ -n "${SNOWFLAKE_HOME:-}" ]; then CORTEX_DIR="$SNOWFLAKE_HOME/cortex"
else CORTEX_DIR="$HOME/.snowflake/cortex"; fi
DEST="$CORTEX_DIR/plugins/rogue-security"
MODE="${1:-install}"

die() { echo "$*" >&2; exit 1; }

case "$(uname -s)" in Darwin|Linux) ;; *) die "Cortex Code hook installation supports macOS and Linux only" ;; esac
case "$MODE" in install|--uninstall|--status) ;; *) die "usage: bash install.sh [--uninstall | --status]" ;; esac

if [ "$MODE" = --status ]; then
  for f in .cortex-plugin/plugin.json hooks/hooks.json scripts/hook.sh scripts/env-file.sh scripts/actor.sh scripts/install-id.sh; do
    [ -r "$DEST/$f" ] || die "Missing $DEST/$f"
  done
  for e in SessionStart UserPromptSubmit PreToolUse PermissionRequest PostToolUse Stop SubagentStart SubagentStop SessionEnd; do
    grep -q "scripts/hook.sh\\\\\" $e\"" "$DEST/hooks/hooks.json" || die "hooks.json does not relay $e"
  done
  echo "Cortex Code hooks installed in $DEST. Start a new Cortex Code session to verify live traffic."
  exit 0
fi

if [ "$MODE" = --uninstall ]; then
  rm -rf "$DEST" || die "Cannot remove $DEST"
  echo "Removed Rogue Cortex Code hooks; credentials and other Cortex Code settings preserved."
  exit 0
fi

SOURCE="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
[ "$SOURCE" != "$DEST" ] || { echo "Cortex Code hooks already installed in $DEST."; exit 0; }
[ ! -e "$DEST" ] || [ -d "$DEST" ] || die "Refusing non-directory: $DEST"
mkdir -p "$CORTEX_DIR/plugins" || die "Cannot create $CORTEX_DIR/plugins"
# One installer at a time, so a concurrent run cannot lose the bridge's env file.
LOCK="$CORTEX_DIR/plugins/.rogue-security.lock"
mkdir "$LOCK" 2>/dev/null || die "Another Cortex Code installer is running, or a previous run was interrupted. If none is running, remove $LOCK and retry."
# Stage beside the destination, then swap, so Cortex never loads a half-copied plugin.
NEW="$CORTEX_DIR/plugins/.rogue-security.new-$$"
trap 'rm -rf "$NEW" "$NEW.old" "$LOCK"' EXIT
mkdir "$NEW" && cp -R "$SOURCE/.cortex-plugin" "$SOURCE/hooks" "$SOURCE/scripts" "$NEW/" || die "Cannot copy the bridge to $NEW"
chmod -R go-w "$NEW"
# An update keeps a credential file placed in the bridge folder.
[ ! -f "$DEST/env" ] || cp -p "$DEST/env" "$NEW/env" || die "Cannot keep $DEST/env"
if [ -d "$DEST" ]; then mv "$DEST" "$NEW.old" || die "Cannot replace $DEST"; fi
# DEST is gone at this point, so the rename cannot nest NEW inside an existing folder.
[ ! -e "$DEST" ] && mv "$NEW" "$DEST" || { [ -d "$NEW.old" ] && [ ! -e "$DEST" ] && mv "$NEW.old" "$DEST"; die "Cannot install $DEST"; }
echo "Installed Rogue Cortex Code hooks in $DEST. Start a new Cortex Code session (CLI or Desktop)."
