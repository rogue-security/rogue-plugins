#!/usr/bin/env bash
# Sourceable. Resolves the three values that identify THIS install to the fleet
# roster, alongside the actor from actor.sh:
#
#   ROGUE_INSTALL_HOST     hostname
#   ROGUE_INSTALL_VERSION  plugin version from the manifest ("unknown" if unreadable)
#   ROGUE_INSTALL_AGENT    surface, stored as the roster's `agent`
#
# hook.sh sends them as x-rogue-host / x-rogue-version / x-rogue-agent on EVERY
# event and heartbeat.sh in its /hooks/status body. Resolved in ONE place because
# the backend keys the row on host + actor + family + agent: any disagreement
# between the two senders is a duplicate row for one install.
#
# Resolution NEVER fails the hook. Whatever could not be resolved is recorded in
# ROGUE_INSTALL_ID_ERROR (`host-unresolved`, `manifest-missing:<path>`,
# `version-unparsed:<path>`); hook.sh logs it per event.
ROGUE_INSTALL_ID_ERROR=""

rogue_install_id_error() {
  ROGUE_INSTALL_ID_ERROR="${ROGUE_INSTALL_ID_ERROR:+$ROGUE_INSTALL_ID_ERROR,}$1"
}

ROGUE_INSTALL_HOST="$(hostname 2>/dev/null)"
if [ -z "$ROGUE_INSTALL_HOST" ]; then
  ROGUE_INSTALL_HOST="unknown"
  rogue_install_id_error "host-unresolved"
fi

# Version from the manifest WITHOUT python3 (the /usr/bin/python3 stub fails
# silently on a fresh macOS). grep/sed are always present.
ROGUE_INSTALL_VERSION="unknown"
_rogue_pj="${PLUGIN_ROOT:-}/plugin.json"
if [ -r "$_rogue_pj" ]; then
  _rogue_v=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9][^"]*"' "$_rogue_pj" 2>/dev/null \
               | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  if [ -n "$_rogue_v" ]; then
    ROGUE_INSTALL_VERSION="$_rogue_v"
  else
    rogue_install_id_error "version-unparsed:$_rogue_pj"
  fi
else
  rogue_install_id_error "manifest-missing:$_rogue_pj"
fi
unset _rogue_pj _rogue_v

ROGUE_INSTALL_AGENT="muse_code"
export ROGUE_INSTALL_HOST ROGUE_INSTALL_VERSION ROGUE_INSTALL_AGENT ROGUE_INSTALL_ID_ERROR
