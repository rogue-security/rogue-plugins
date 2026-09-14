#!/usr/bin/env bash
# Rogue Security — credential storage helper
# Writes ~/.rogue-env (mode 600). Sourced by the dispatcher at hook fire time.
#
# Usage: setup.sh <api-key> <email> <name>
set -euo pipefail

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
