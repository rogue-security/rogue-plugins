#!/bin/sh
# Static lint for plugins/antigravity/hooks.json.
#
# Unlike the Claude/Copilot dispatchers, Antigravity commands do NOT end in
# '; exit 0' (the scripts themselves always exit 0, and Antigravity has no
# documented "visible hook error on non-zero exit" behavior) -- see the plan
# note at docs/superpowers/plans/2026-07-20-rogue-antigravity-plugin.md:960.
# This test enforces the structural invariants instead: valid JSON, the
# top-level "rogue" key, exactly the five events, matcher ".*" on the two
# tool events, exactly two handlers (sh + powershell) per event each passing
# the matching Event arg, and timeout 30 on every handler.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS_JSON="$ROOT/plugins/antigravity/hooks.json"

if [ ! -f "$HOOKS_JSON" ]; then
    echo "FAIL: $HOOKS_JSON does not exist"
    exit 1
fi

python3 - "$HOOKS_JSON" <<'EOF'
import json, sys

path = sys.argv[1]
with open(path) as f:
    data = json.load(f)   # raises on invalid JSON

failures = []

def fail(msg, cmd=None):
    failures.append(msg + (f"\n    command: {cmd}" if cmd else ""))

if "rogue" not in data:
    fail("top-level key 'rogue' is missing")
    print(f"FAIL: {len(failures)} problem(s) in {path}\n")
    for f in failures:
        print(f"  - {f}")
    sys.exit(1)

hooks = data["rogue"]

EXPECTED_EVENTS = {
    "PreToolUse", "PostToolUse", "PreInvocation", "PostInvocation", "Stop",
}

got = set(hooks.keys())
if got != EXPECTED_EVENTS:
    fail(f"event set mismatch: missing={EXPECTED_EVENTS - got} extra={got - EXPECTED_EVENTS}")

MATCHER_REQUIRED = {"PreToolUse", "PostToolUse"}

# The two event kinds take DIFFERENT array shapes, and getting it wrong is a
# fatal parse error for the whole file (all five events go dead while the CLI
# keeps running normally):
#   matcher events     -> [ { "matcher": ".*", "hooks": [ <handler>, ... ] } ]
#   matcher-less events-> [ <handler>, ... ]                  (FLAT, no wrapper)
# Wrapping a matcher-less event in { "hooks": [...] } yields
#   invalid hook "rogue": command hook must specify 'command'
# so this lint pins the flat shape. See plugins/antigravity/CLAUDE.md.
def handler_groups(event, arr):
    """Yield (where, handlers) pairs for one event's registration array."""
    if event in MATCHER_REQUIRED:
        for gi, g in enumerate(arr):
            where = f"[{event}][{gi}]"
            if not isinstance(g, dict):
                fail(f"{where} must be a {{matcher, hooks}} object")
                continue
            if g.get("matcher") != ".*":
                fail(f"{where} matcher must be '.*', got {g.get('matcher')!r}")
            entries = g.get("hooks")
            if not isinstance(entries, list):
                fail(f"{where} 'hooks' must be an array")
                continue
            yield where, entries
        return

    # Matcher-less: the array itself is the handler list.
    for hi, h in enumerate(arr):
        if not isinstance(h, dict):
            fail(f"[{event}][{hi}] must be a handler object")
            continue
        if "hooks" in h:
            fail(f"[{event}][{hi}] must be a FLAT handler, not a {{'hooks': [...]}} group "
                 "(Antigravity rejects the nested form and drops the whole file)")
        if "matcher" in h:
            fail(f"[{event}][{hi}] must not carry a matcher, got {h.get('matcher')!r}")
    yield f"[{event}]", arr

for event, arr in hooks.items():
    if not isinstance(arr, list) or not arr:
        fail(f"[{event}] must be a non-empty array")
        continue

    for where_g, entries in handler_groups(event, arr):
        if len(entries) != 2:
            fail(f"{where_g} must have exactly 2 handlers, got {len(entries)}")

        sh_entries = []
        ps_entries = []

        for h in entries:
            cmd = h.get("command", "")
            where = f"{where_g}"

            if h.get("type") != "command":
                fail(f"{where} non-command hook type: {h.get('type')}", cmd)

            if h.get("timeout") != 30:
                fail(f"{where} timeout must be 30, got {h.get('timeout')}", cmd)

            if cmd.startswith("sh "):
                sh_entries.append(cmd)
                if "scripts/hook.sh" not in cmd:
                    fail(f"{where} sh entry must reference scripts/hook.sh", cmd)
                if event not in cmd:
                    fail(f"{where} sh entry must pass '{event}' as the Event arg", cmd)
            elif cmd.startswith("powershell"):
                ps_entries.append(cmd)
                if "hook.ps1" not in cmd:
                    fail(f"{where} powershell entry must reference hook.ps1", cmd)
                if event not in cmd:
                    fail(f"{where} powershell entry must pass '{event}' as the Event arg", cmd)
                # `&` gives hook.ps1 no script scope, so it never sees its API key (FIRE-3368).
                if '-Command ". ([scriptblock]::Create(' not in cmd:
                    fail(f"{where} powershell entry must dot-source hook.ps1, not call it with &", cmd)
            else:
                fail(f"{where} command starts with neither 'sh ' nor 'powershell'", cmd)

        if len(sh_entries) != 1:
            fail(f"{where_g} must have exactly 1 sh entry, got {len(sh_entries)}")
        if len(ps_entries) != 1:
            fail(f"{where_g} must have exactly 1 powershell entry, got {len(ps_entries)}")

        # Antigravity dispatchers always exit 0 themselves -- unlike
        # Claude/Copilot, the command string must NOT append '; exit 0'.
        for cmd in sh_entries + ps_entries:
            if cmd.rstrip().endswith("; exit 0"):
                fail(f"{where_g} command must NOT end with '; exit 0' (Antigravity scripts self-exit 0)", cmd)

if failures:
    print(f"FAIL: {len(failures)} problem(s) in {path}\n")
    for f in failures:
        print(f"  - {f}")
    sys.exit(1)

total = sum(
    len(g["hooks"]) if event in MATCHER_REQUIRED else 1
    for event, gs in hooks.items()
    for g in gs
)
print(f"OK: {total} hook commands across {len(hooks)} events pass the antigravity hooks.json lint")
EOF
status=$?
exit $status
