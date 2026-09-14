#!/usr/bin/env bash
# Provision /etc/rogue/env (API key + end-user identity) on MDM-managed machines.
#
# Why: the compiled plugin's bundled env can't reliably derive end-user
# identity on managed/ephemeral machines (e.g. Cowork VMs) where hostname is
# random and git config is empty. The MDM (Kandji, Jamf, Intune, Workspace
# ONE, etc.) knows the assigned user — push that knowledge into
# /etc/rogue/env so the hook layer picks it up at runtime.
#
# The hooks read ONE env file: the first of /etc/rogue/env, <plugin-root>/env,
# ~/.rogue-env that holds ROGUE_API_KEY, and nothing from the others. So this
# file must carry the key to be read at all, and once it does it replaces the
# bundled env entirely — mode and the auto-update pin included.
#
# Usage — env vars (recommended for MDM payloads that substitute their own
# placeholders for the assigned user):
#
#   # Kandji Custom Script body example:
#   ROGUE_API_KEY="rsk_..." \
#   ROGUE_ACTOR_EMAIL="$USER_EMAIL" \
#   ROGUE_ACTOR_NAME="$USER_FULL_NAME" \
#     bash mdm-provision-actor.sh
#
# Usage — CLI args (handy for manual testing):
#
#   sudo bash mdm-provision-actor.sh \
#     --key rsk_... \
#     --email alice@example.com \
#     --name "Alice Smith"
#
# Required: --key / ROGUE_API_KEY, --email / ROGUE_ACTOR_EMAIL, --name / ROGUE_ACTOR_NAME.
# Optional flags / env vars:
#   --mode         / ROGUE_PRETOOLUSE_ON_BLOCK   "ask" or "block" (hook default when unset)
#   --base-url     / ROGUE_BASE_URL              custom Rogue endpoint
#   --auto-update  / ROGUE_AUTO_UPDATE           0 (default; matches compiled bundles) or 1
#
# Must run as root (writes to /etc/rogue/env).

set -euo pipefail

EMAIL="${ROGUE_ACTOR_EMAIL:-}"
NAME="${ROGUE_ACTOR_NAME:-}"
KEY="${ROGUE_API_KEY:-}"
MODE="${ROGUE_PRETOOLUSE_ON_BLOCK:-}"
BASE_URL="${ROGUE_BASE_URL:-}"
AUTO_UPDATE="${ROGUE_AUTO_UPDATE:-0}"

while [ $# -gt 0 ]; do
  case "$1" in
    --email)    EMAIL="$2"; shift 2 ;;
    --name)     NAME="$2"; shift 2 ;;
    --key)      KEY="$2"; shift 2 ;;
    --mode)     MODE="$2"; shift 2 ;;
    --base-url) BASE_URL="$2"; shift 2 ;;
    --auto-update) AUTO_UPDATE="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,37p' "$0" 2>/dev/null
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$KEY" ]   || { echo "ROGUE_API_KEY (or --key) required: the hooks skip an env file without it" >&2; exit 2; }
[ -n "$EMAIL" ] || { echo "ROGUE_ACTOR_EMAIL (or --email) required" >&2; exit 2; }
[ -n "$NAME" ]  || { echo "ROGUE_ACTOR_NAME (or --name) required" >&2; exit 2; }

case "$MODE" in
  ""|ask|block) ;;
  *) echo "Bad --mode: $MODE (expected: ask|block)" >&2; exit 2 ;;
esac
case "$AUTO_UPDATE" in
  0|1) ;;
  *) echo "Bad --auto-update: $AUTO_UPDATE (expected: 0|1)" >&2; exit 2 ;;
esac

[ "$(id -u)" -eq 0 ] || {
  echo "must run as root (writes /etc/rogue/env)" >&2
  exit 1
}

mkdir -p /etc/rogue
TMP=$(mktemp /etc/rogue/.env.XXXXXX)
trap 'rm -f "$TMP"' EXIT

{
  echo "# Provisioned by mdm-provision-actor.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'export ROGUE_API_KEY=%q\n' "$KEY"
  printf 'export ROGUE_ACTOR_EMAIL=%q\n' "$EMAIL"
  printf 'export ROGUE_ACTOR_NAME=%q\n'  "$NAME"
  [ -n "$MODE" ]     && printf 'export ROGUE_PRETOOLUSE_ON_BLOCK=%q\n' "$MODE"
  [ -n "$BASE_URL" ] && printf 'export ROGUE_BASE_URL=%q\n' "$BASE_URL"
  printf 'export ROGUE_AUTO_UPDATE=%s\n' "$AUTO_UPDATE"
} > "$TMP"

# Root-owned, world-readable: the hooks run as each user and must read it. To
# narrow readers, use 0640 under a group the human users belong to.
chmod 0644 "$TMP"
chown root:wheel "$TMP" 2>/dev/null || chown root:root "$TMP" 2>/dev/null || true
mv -f "$TMP" /etc/rogue/env
trap - EXIT

echo "wrote /etc/rogue/env  actor=$EMAIL ($NAME)"
