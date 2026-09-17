#!/usr/bin/env bash
# Rogue Security — credential storage helper
# Writes ~/.rogue-env (mode 600). Sourced by the dispatcher at hook fire time.
#
# Usage: setup.sh <api-key> <email> <name>
set -euo pipefail

ENV_FILE="$HOME/.rogue-env"
MACHINE_ENV_FILE="/etc/rogue/env"

. "$(dirname "$0")/env-file.sh"

# A trusted machine env file holding a key is read ALONE by every hook, so
# $ENV_FILE written here would never be consulted. Nothing to do.
if rogue_env_has_key "$MACHINE_ENV_FILE" && rogue_env_is_trusted "$MACHINE_ENV_FILE" 1; then
  echo "OK"
  echo "ENV_FILE=$MACHINE_ENV_FILE"
  echo "Credentials come from the machine env file $MACHINE_ENV_FILE - $ENV_FILE not written"
  exit 0
fi

API_KEY="${1:?Usage: setup.sh <api-key> <email> <name>}"
ACTOR_EMAIL="${2:-}"
ACTOR_NAME="${3:-}"

rogue_write_env_file "$ENV_FILE" \
  ROGUE_API_KEY "$API_KEY" \
  ROGUE_ACTOR_EMAIL "$ACTOR_EMAIL" \
  ROGUE_ACTOR_NAME "$ACTOR_NAME"

echo "OK"
echo "ENV_FILE=$ENV_FILE"
