#!/usr/bin/env bash
# Sourceable. Resolves the values that identify THIS install to the fleet roster
# (sent as x-rogue-host / x-rogue-version / x-rogue-agent). Never fails the hook;
# what could not be resolved is recorded in ROGUE_INSTALL_ID_ERROR.
ROGUE_INSTALL_ID_ERROR=""
ROGUE_INSTALL_HOST="$(hostname 2>/dev/null)"
[ -n "$ROGUE_INSTALL_HOST" ] || { ROGUE_INSTALL_HOST="unknown"; ROGUE_INSTALL_ID_ERROR="host-unresolved"; }
ROGUE_INSTALL_VERSION=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+' "$PLUGIN_ROOT/.cortex-plugin/plugin.json" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+$')
[ -n "$ROGUE_INSTALL_VERSION" ] || { ROGUE_INSTALL_VERSION="unknown"; ROGUE_INSTALL_ID_ERROR="${ROGUE_INSTALL_ID_ERROR:+$ROGUE_INSTALL_ID_ERROR,}manifest-unreadable"; }
# Desktop runs hooks from its VS Code shared process, launched as bundle
# com.snowflake.coco, and marks its own terminals coco_desktop; everything else is the CLI.
case "${VSCODE_ESM_ENTRYPOINT:-}" in *sharedProcess*) _rogue_desktop=1 ;; *) _rogue_desktop= ;; esac
if [ -n "$_rogue_desktop" ] || [ "${CORTEX_CODE_CLIENT_SURFACE:-}" = coco_desktop ] || [ "${__CFBundleIdentifier:-}" = com.snowflake.coco ]; then
  ROGUE_INSTALL_AGENT="cortex_code_desktop"
else
  ROGUE_INSTALL_AGENT="cortex_code_cli"
fi
unset _rogue_desktop
export ROGUE_INSTALL_HOST ROGUE_INSTALL_VERSION ROGUE_INSTALL_AGENT ROGUE_INSTALL_ID_ERROR
