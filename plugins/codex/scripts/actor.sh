#!/usr/bin/env bash
# Sourceable. Resolves ROGUE_ACTOR_{EMAIL,NAME} from a cascade.
# Cascade: env → git config files (scripts/git-identity.sh) → login@hostname / login
# → marker "unknown", never blank.
# Sourced by hook.sh and heartbeat.sh after PLUGIN_ROOT is set.

# Trimmed before the presence test: a whitespace-only ROGUE_ACTOR_* must fall
# through to the git/login cascade rather than ship as blank, and the stored value
# has to match what ship-logs.sh (which trims) sends for the same install.
# Parameter expansion only - this runs on every hook event, so no subshell.
_rogue_trim() {
  _rogue_tv="$1"
  while :; do case "$_rogue_tv" in [[:space:]]*) _rogue_tv="${_rogue_tv#?}" ;; *) break ;; esac; done
  while :; do case "$_rogue_tv" in *[[:space:]]) _rogue_tv="${_rogue_tv%?}" ;; *) break ;; esac; done
}
_rogue_trim "${ROGUE_ACTOR_EMAIL:-}"; ROGUE_ACTOR_EMAIL="$_rogue_tv"
_rogue_trim "${ROGUE_ACTOR_NAME:-}";  ROGUE_ACTOR_NAME="$_rogue_tv"
unset _rogue_tv

if [ -z "${ROGUE_ACTOR_EMAIL:-}" ] || [ -z "${ROGUE_ACTOR_NAME:-}" ]; then
  ROGUE_GIT_EMAIL=""; ROGUE_GIT_NAME=""
  if [ -r "${PLUGIN_ROOT:-}/scripts/git-identity.sh" ]; then
    . "${PLUGIN_ROOT}/scripts/git-identity.sh"
    rogue_git_identity
  fi
  [ -n "${ROGUE_ACTOR_EMAIL:-}" ] || ROGUE_ACTOR_EMAIL="$ROGUE_GIT_EMAIL"
  [ -n "${ROGUE_ACTOR_NAME:-}" ]  || ROGUE_ACTOR_NAME="$ROGUE_GIT_NAME"

  _rogue_login="${USER:-${USERNAME:-$(whoami 2>/dev/null)}}"
  _rogue_host="$(hostname 2>/dev/null)"
  if [ -z "${ROGUE_ACTOR_EMAIL:-}" ]; then
    if [ -n "$_rogue_login" ] && [ -n "$_rogue_host" ]; then ROGUE_ACTOR_EMAIL="$_rogue_login@$_rogue_host"
    else ROGUE_ACTOR_EMAIL="${_rogue_login:-$_rogue_host}"; fi
  fi
  [ -n "${ROGUE_ACTOR_NAME:-}" ] || ROGUE_ACTOR_NAME="$_rogue_login"
  unset _rogue_login _rogue_host
fi
: "${ROGUE_ACTOR_EMAIL:=unknown}"
: "${ROGUE_ACTOR_NAME:=unknown}"

export ROGUE_ACTOR_EMAIL ROGUE_ACTOR_NAME
