#!/usr/bin/env python3
"""Generate plugins/rogue/managed-settings.json from plugins/rogue/hooks/hooks.json.

Claude Code runs hooks from its managed settings even under --bare, CLAUDE_CODE_SIMPLE,
--safe-mode, --setting-sources and a user's disableAllHooks; plugin hooks run under none
of those. An admin install (install.sh --managed, or the Rogue endpoint agent) renders
this template into the managed-settings.d drop-in directory, with @ROGUE_BRIDGE_ROOT@
replaced by the root-owned copy of plugins/rogue.

Each managed command differs from its plugin twin in four ways:
  - POSIX only: managed hooks are installed on macOS and Linux.
  - No auto-update.sh (the admin's installer owns updates) and no warn.sh (its
    "run /rogue:setup" hint is wrong when the machine env file is what is missing).
  - The bridge path is literal. Claude Code substitutes ${CLAUDE_PLUGIN_ROOT} only in
    plugin hooks; in a managed hook the variable would come from the user's environment.
  - A fixed PATH and no shell start-up files, so a user cannot shadow curl or sh.

Usage: scripts/managed-settings.py [--check]
"""
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
HOOKS_JSON = REPO / "plugins/rogue/hooks/hooks.json"
OUTPUT = REPO / "plugins/rogue/managed-settings.json"

ROOT = "@ROGUE_BRIDGE_ROOT@"
PREFIX = (
    "/usr/bin/env -u BASH_ENV -u ENV PATH=/usr/bin:/bin:/usr/sbin:/sbin "
    f"CLAUDE_PLUGIN_ROOT='{ROOT}' ROGUE_HOOK_SOURCE=managed "
)
SKIPPED_SCRIPTS = ("/scripts/auto-update.sh", "/scripts/warn.sh")


def managed_command(command):
    if not command.startswith("sh ") or any(s in command for s in SKIPPED_SCRIPTS):
        return None
    for var in ("${CLAUDE_PLUGIN_ROOT}", "$CLAUDE_PLUGIN_ROOT"):
        command = command.replace(f'"{var}', f'"{ROOT}')
    if "CLAUDE_PLUGIN_ROOT" in command:
        raise SystemExit(f"unquoted CLAUDE_PLUGIN_ROOT in hook command: {command}")
    return PREFIX + "/bin/" + command


def render():
    hooks = json.loads(HOOKS_JSON.read_text())["hooks"]
    managed = {}
    for event, groups in hooks.items():
        kept_groups = []
        for group in groups:
            kept = []
            for hook in group["hooks"]:
                command = managed_command(hook.get("command", ""))
                if command is not None:
                    kept.append({**hook, "command": command})
            if kept:
                kept_groups.append({**group, "hooks": kept})
        if kept_groups:
            managed[event] = kept_groups
    return json.dumps({"hooks": managed}, indent=2) + "\n"


def main():
    text = render()
    if sys.argv[1:] == ["--check"]:
        if OUTPUT.read_text() != text:
            print(f"{OUTPUT.relative_to(REPO)} is stale; run scripts/managed-settings.py",
                  file=sys.stderr)
            return 1
        return 0
    OUTPUT.write_text(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
