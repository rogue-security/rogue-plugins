#!/usr/bin/env bash
set -euo pipefail

# Rogue Security — credential storage helper (GitHub Copilot CLI plugin).
# Called by the /rogue:setup command and the installer.
# Writes ~/.rogue-env (mode 600) which every plugin hook reads at runtime. The
# file is shared with the Claude/Codex/Cursor/Gemini plugins (same format).
#
# Usage: setup.sh <api-key> <email> <name>
#
# Hooks read the first of these that holds ROGUE_API_KEY, alone:
#   1) /etc/rogue/env       (machine, for MDM deployments)
#   2) ${PLUGIN_ROOT}/env   (bundled, for compiled customer plugins)
#   3) ~/.rogue-env         (per-user, written by this script)

API_KEY="${1:?Usage: setup.sh <api-key> <email> <name>}"
ACTOR_EMAIL="${2:-}"
ACTOR_NAME="${3:-}"

ENV_FILE="$HOME/.rogue-env"

. "$(dirname "$0")/env-file.sh"
rogue_write_env_file "$ENV_FILE" \
  ROGUE_API_KEY "$API_KEY" \
  ROGUE_ACTOR_EMAIL "$ACTOR_EMAIL" \
  ROGUE_ACTOR_NAME "$ACTOR_NAME"

echo "OK"
echo "ENV_FILE=$ENV_FILE"
