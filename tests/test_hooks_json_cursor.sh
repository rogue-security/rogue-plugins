#!/usr/bin/env bash
# tests/test_hooks_json_cursor.sh — static lint of the Cursor plugin's
# hooks.json. Asserts the dual-dispatcher registration (one `sh` entry + one
# PowerShell entry per event, so exactly one does real work per machine) and the
# per-hook timeout.
#
# The 120s timeout is LOAD-BEARING, not decoration: a subagent's first event may
# wait up to ~3s for Cursor to write the child's transcript file (see
# resolve_parent_session in scripts/hook.sh). 3s is 2.5% of this budget; cutting
# the timeout towards the wait would turn a resolvable subagent into a killed
# hook.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS="$REPO/plugins/cursor/hooks/hooks.json"

python3 - "$HOOKS" <<'PY'
import json, sys

path = sys.argv[1]
with open(path) as f:
    doc = json.load(f)   # raises on invalid JSON

errors = []

if doc.get("version") != 1:
    errors.append(f"top-level version must be 1, got {doc.get('version')!r}")

hooks = doc.get("hooks", {})
expected_events = {
    "sessionStart", "sessionEnd", "beforeSubmitPrompt", "preToolUse",
    "postToolUse", "postToolUseFailure", "beforeShellExecution",
    "afterShellExecution", "beforeMCPExecution", "afterMCPExecution",
    "beforeReadFile", "afterFileEdit", "afterAgentResponse", "afterAgentThought",
    "subagentStart", "subagentStop", "stop", "preCompact",
}
got_events = set(hooks.keys())
if got_events != expected_events:
    missing = sorted(expected_events - got_events)
    extra = sorted(got_events - expected_events)
    errors.append(f"events differ: missing={missing} extra={extra}")

# subagentStart is what arms the marker gate, and subagentStop is what clears it.
# Losing either registration silently costs every subagent its attribution, so
# call them out by name rather than leaving them inside the set comparison.
for required in ("subagentStart", "subagentStop"):
    if required not in got_events:
        errors.append(f"'{required}' must stay registered (it drives the spawn marker)")

for event, entries in sorted(hooks.items()):
    if not isinstance(entries, list) or len(entries) != 2:
        errors.append(f"{event}: expected exactly 2 entries (sh + PowerShell)")
        continue
    sh_entries = [e for e in entries if e.get("command", "").startswith("sh ./scripts/hook.sh ")]
    ps_entries = [e for e in entries if e.get("command", "").startswith("powershell ")]
    if len(sh_entries) != 1:
        errors.append(f"{event}: expected exactly 1 sh entry")
    if len(ps_entries) != 1:
        errors.append(f"{event}: expected exactly 1 PowerShell entry")
    for i, entry in enumerate(entries):
        tag = f"{event}[{i}]"
        cmd = entry.get("command")
        if not isinstance(cmd, str) or not cmd:
            errors.append(f"{tag}: missing 'command'")
            continue
        # The event name is passed as the dispatcher's argument and echoed back
        # as x-rogue-event; the server routes on it. The PowerShell entry closes
        # its -Command string after the argument, hence the trailing quote.
        if not cmd.rstrip().rstrip('"').endswith(event):
            errors.append(f"{tag}: command must end with the event name {event!r}")
        if entry.get("timeout") != 120:
            errors.append(f"{tag}: timeout must be 120 (the ~3s subagent wait lives inside it)")

if errors:
    for e in errors:
        print(f"FAIL: {e}")
    sys.exit(1)

print(f"  ok: {len(hooks)} events, each with an sh + PowerShell entry at timeout 120")
PY

echo
echo "Cursor hooks.json lint passed."
