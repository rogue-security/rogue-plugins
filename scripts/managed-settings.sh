#!/usr/bin/env bash
set -euo pipefail
# Generate plugins/rogue/managed-settings.json from plugins/rogue/hooks/hooks.json.
#
# Claude Code runs hooks from its managed settings even under --bare, CLAUDE_CODE_SIMPLE,
# --safe-mode, --setting-sources and a user's disableAllHooks; plugin hooks run under none
# of those. An admin install (install.sh --managed, or the Rogue endpoint agent) renders
# this template into the managed-settings.d drop-in directory, with @ROGUE_BRIDGE_ROOT@
# replaced by the root-owned copy of plugins/rogue.
#
# Each managed command differs from its plugin twin in four ways:
#   - POSIX only: managed hooks are installed on macOS and Linux.
#   - No auto-update.sh (the admin's installer owns updates), no warn.sh (its
#     "run /rogue:setup" hint is wrong when the machine env file is what is missing)
#     and no hook-binary.sh (managed hooks never hand off to the user-writable binary).
#   - The bridge path is literal. Claude Code substitutes ${CLAUDE_PLUGIN_ROOT} only in
#     plugin hooks; in a managed hook the variable would come from the user's environment.
#   - A fixed PATH and no shell start-up files, so a user cannot shadow curl or sh.
#
# Usage: scripts/managed-settings.sh [--check]

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$REPO/plugins/rogue/managed-settings.json"

render() {
  jq --indent 2 '
    def managed:
      "/usr/bin/env -u BASH_ENV -u ENV PATH=/usr/bin:/bin:/usr/sbin:/sbin CLAUDE_PLUGIN_ROOT='"'@ROGUE_BRIDGE_ROOT@'"' ROGUE_HOOK_SOURCE=managed /bin/"
      + (gsub("\"\\$\\{CLAUDE_PLUGIN_ROOT\\}|\"\\$CLAUDE_PLUGIN_ROOT"; "\"@ROGUE_BRIDGE_ROOT@")
         | if test("CLAUDE_PLUGIN_ROOT") then error("unquoted CLAUDE_PLUGIN_ROOT in hook command: \(.)") end);
    def kept: (.command // "") | startswith("sh ") and (test("/scripts/(auto-update|warn|hook-binary)\\.sh") | not);
    {hooks: (.hooks
      | map_values(map(.hooks |= map(select(kept) | .command |= managed)) | map(select(.hooks | length > 0)))
      | with_entries(select(.value | length > 0)))}
  ' "$REPO/plugins/rogue/hooks/hooks.json"
}

case "${1:-}" in
  --check|"") rendered="$(render)" ;;
  *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac
if [ "${1:-}" = --check ]; then
  printf '%s\n' "$rendered" | cmp -s - "$OUTPUT" \
    || { echo "plugins/rogue/managed-settings.json is stale; run scripts/managed-settings.sh" >&2; exit 1; }
else
  printf '%s\n' "$rendered" > "$OUTPUT"
fi
