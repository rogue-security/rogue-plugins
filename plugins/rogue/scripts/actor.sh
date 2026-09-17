#!/usr/bin/env bash
# Sourceable (POSIX sh clean — hook.sh runs under `sh`/dash). Resolves
# ROGUE_ACTOR_{EMAIL,NAME} from a cascade.
#
# Cascade (first NON-SYNTHETIC candidate wins):
#   EMAIL: $ROGUE_ACTOR_EMAIL → $CLAUDE_CODE_USER_EMAIL → git config file user.email
#          → "<login>@<hostname>" (marker "unknown" for a missing/synthetic part)
#   NAME:  $ROGUE_ACTOR_NAME → local-part of $CLAUDE_CODE_USER_EMAIL
#          → git config file user.name → login → marker "unknown"
#
# The git identity comes from the config FILES (scripts/git-identity.sh), never
# from the git binary: on a Mac without the Command Line Tools `git` is a stub
# that opens the installer dialog.
#
# CLAUDE_CODE_USER_EMAIL (the authenticated user, set by the Claude host) ranks
# ABOVE the git identity. In Claude Cowork the agent runs as unix user `claude`
# in a sandbox whose git identity is Anthropic's synthetic one
# (user.name=Claude / user.email=noreply@anthropic.com), so a git-first cascade
# reported every Cowork user as "Claude". On a normal dev machine there is no
# CLAUDE_CODE_USER_EMAIL, so the git identity is still what gets used.
#
# Every candidate is screened by _rogue_is_synthetic — INCLUDING one arriving in
# ROGUE_ACTOR_EMAIL/ROGUE_ACTOR_NAME. That is load-bearing, not paranoia:
# compiled bundles already deployed in the field (built before this fix by
# scripts/compile-{local-dev,customer-plugin}.sh) bake a
# `: "${ROGUE_ACTOR_EMAIL:=$(git config --global user.email)}"` pre-seed into
# ${CLAUDE_PLUGIN_ROOT}/env, which hook.sh sources BEFORE this file. Those
# bundles hand us the synthetic sandbox identity in ROGUE_ACTOR_*, so a plugin
# update can only fix them if the dispatcher distrusts that value. Do not
# "optimize away" the screen on the explicit vars.
#
# When every candidate is rejected we emit a clearly non-human marker
# ("unknown"), never a plausible-looking synthetic name.

# True (0) when the value is empty/whitespace or a known synthetic sandbox
# identity. Case-insensitive; internal whitespace runs are squeezed so
# "Claude  Code" matches too.
_rogue_is_synthetic() {
  _rogue_v=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ')
  _rogue_v=${_rogue_v# }
  _rogue_v=${_rogue_v% }
  case "$_rogue_v" in
    ''|claude|'claude code'|noreply@anthropic.com) return 0 ;;
  esac
  return 1
}

# -- git identity (both fields at once; the files are read only when needed) --
_rogue_git_loaded=0
_rogue_load_git() {
  [ "$_rogue_git_loaded" = 1 ] && return 0
  _rogue_git_loaded=1
  ROGUE_GIT_EMAIL=""; ROGUE_GIT_NAME=""
  _rogue_root="${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}"
  if [ -r "$_rogue_root/scripts/git-identity.sh" ]; then
    . "$_rogue_root/scripts/git-identity.sh"
    rogue_git_identity
  fi
  unset _rogue_root
}

# -- email ------------------------------------------------------------------
_rogue_email="${ROGUE_ACTOR_EMAIL:-}"
_rogue_is_synthetic "$_rogue_email" && _rogue_email=""

if [ -z "$_rogue_email" ]; then
  _rogue_email="${CLAUDE_CODE_USER_EMAIL:-}"
  _rogue_is_synthetic "$_rogue_email" && _rogue_email=""
fi
if [ -z "$_rogue_email" ]; then
  _rogue_load_git
  _rogue_email="$ROGUE_GIT_EMAIL"
  _rogue_is_synthetic "$_rogue_email" && _rogue_email=""
fi
if [ -z "$_rogue_email" ]; then
  _rogue_login="${USER:-${USERNAME:-$(whoami 2>/dev/null)}}"
  _rogue_is_synthetic "$_rogue_login" && _rogue_login="unknown"
  _rogue_host=$(hostname 2>/dev/null)
  _rogue_is_synthetic "$_rogue_host" && _rogue_host=""
  if [ -n "$_rogue_host" ]; then
    _rogue_email="$_rogue_login@$_rogue_host"
  else
    _rogue_email="$_rogue_login"
  fi
fi

# -- name -------------------------------------------------------------------
_rogue_name="${ROGUE_ACTOR_NAME:-}"
_rogue_is_synthetic "$_rogue_name" && _rogue_name=""

if [ -z "$_rogue_name" ]; then
  # Screen the WHOLE address before splitting it. Taking the local-part first
  # smuggles the sandbox identity past the screen: noreply@anthropic.com is
  # rejected as an email but its local-part "noreply" is not on the list, so the
  # hook would report actor unknown@<host> with the name "noreply".
  _rogue_hostmail="${CLAUDE_CODE_USER_EMAIL:-}"
  _rogue_is_synthetic "$_rogue_hostmail" && _rogue_hostmail=""
  _rogue_name="${_rogue_hostmail%%@*}"
  # Still screen the local-part itself: claude@corp.com is a real address whose
  # local-part is not a usable actor name.
  _rogue_is_synthetic "$_rogue_name" && _rogue_name=""
fi
if [ -z "$_rogue_name" ]; then
  _rogue_load_git
  _rogue_name="$ROGUE_GIT_NAME"
  _rogue_is_synthetic "$_rogue_name" && _rogue_name=""
fi
if [ -z "$_rogue_name" ]; then
  _rogue_name="${USER:-${USERNAME:-$(whoami 2>/dev/null)}}"
  _rogue_is_synthetic "$_rogue_name" && _rogue_name=""
fi
[ -n "$_rogue_name" ] || _rogue_name="unknown"

ROGUE_ACTOR_EMAIL="$_rogue_email"
ROGUE_ACTOR_NAME="$_rogue_name"
export ROGUE_ACTOR_EMAIL ROGUE_ACTOR_NAME

unset _rogue_v _rogue_email _rogue_name _rogue_host _rogue_hostmail _rogue_login _rogue_git_loaded
