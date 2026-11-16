#!/bin/sh
# Static lint for plugins/rogue/hooks/hooks.json command strings.
#
# Every command runs under three different shells depending on the machine:
# sh -c (macOS/Linux), Git Bash (Windows with Git), PowerShell 5.1 (Windows
# without Git Bash). A non-zero exit is a VISIBLE hook error in Claude Code,
# so every command must parse and exit 0 in all three. These checks encode
# the polyglot rules; a violation means a visible error on some platform.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS_JSON="$ROOT/plugins/rogue/hooks/hooks.json"

python3 - "$HOOKS_JSON" <<'EOF'
import json, re, sys

path = sys.argv[1]
data = json.load(open(path))
hooks = data["hooks"]

EXPECTED_EVENTS = {
    "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
    "PostToolUseFailure", "PermissionRequest", "Stop", "SessionEnd",
    "SubagentStart", "SubagentStop", "ConfigChange",
}

failures = []

def fail(msg, cmd=None):
    failures.append(msg + (f"\n    command: {cmd}" if cmd else ""))

got = set(hooks.keys())
if got != EXPECTED_EVENTS:
    fail(f"event set mismatch: missing={EXPECTED_EVENTS - got} extra={got - EXPECTED_EVENTS}")

def strip_quoted(s):
    # Remove '...' spans first (sh semantics: nothing nests inside), then "..." spans.
    s = re.sub(r"'[^']*'", "", s)
    s = re.sub(r'"[^"]*"', "", s)
    return s

for event, groups in hooks.items():
    entries = [h for g in groups for h in g["hooks"]]
    for h in entries:
        cmd = h["command"]
        where = f"[{event}]"

        if h.get("type") != "command":
            fail(f"{where} non-command hook type: {h.get('type')}")
        if h.get("timeout") != 20:
            fail(f"{where} timeout must be 20, got {h.get('timeout')}", cmd)

        # Must force exit 0 on every path (non-zero exit = visible error).
        if not cmd.rstrip().endswith("; exit 0"):
            fail(f"{where} command must end with '; exit 0'", cmd)

        # PowerShell 5.1 parse errors: || and && do not exist there.
        if "||" in cmd or "&&" in cmd:
            fail(f"{where} '||'/'&&' is a PowerShell 5.1 parse error", cmd)

        # Bare & or ( outside quotes: PS 5.1 parse error / sh backgrounding leak.
        bare = strip_quoted(cmd)
        if "&" in bare:
            fail(f"{where} bare '&' outside quotes (PS 5.1 parse error)", cmd)
        if "(" in bare or ")" in bare:
            fail(f"{where} bare parens outside quotes (PS 5.1 parse error)", cmd)

        # The plugin directory refuses commands it cannot read as plain words:
        # every entry names its interpreter and a script by a literal
        # ${CLAUDE_PLUGIN_ROOT} path, with no other variable, no `sh -c` and no
        # PowerShell `& (...)`, scriptblock or Invoke-Expression.
        plain = cmd.replace("${CLAUDE_PLUGIN_ROOT}", "")
        if "$" in plain:
            fail(f"{where} variable other than ${{CLAUDE_PLUGIN_ROOT}}", cmd)
        if cmd.startswith("powershell"):
            if not cmd.startswith('powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/'):
                fail(f"{where} powershell entry must run a plugin script with -File", cmd)
            if re.search(r"scriptblock|Invoke-Expression|\biex\b|&", cmd, re.I):
                fail(f"{where} powershell entry the plugin directory cannot read", cmd)
        elif not cmd.startswith('sh "${CLAUDE_PLUGIN_ROOT}/scripts/'):
            fail(f"{where} sh entry must run a plugin script directly", cmd)

    # Exactly-one-runs pairs: every group is either sh-only (warn) or sh+ps.
    for g in groups:
        cmds = [h["command"] for h in g["hooks"]]
        sh_cmds = [c for c in cmds if c.startswith("sh ")]
        ps_cmds = [c for c in cmds if c.startswith("powershell ")]
        if len(sh_cmds) + len(ps_cmds) != len(cmds):
            fail(f"[{event}] entry starts with neither 'sh ' nor 'powershell ': {cmds}")
        if len(sh_cmds) != 1 or len(ps_cmds) > 1:
            fail(f"[{event}] group must have exactly 1 sh entry and at most 1 ps entry: {cmds}")

if failures:
    print(f"FAIL: {len(failures)} problem(s) in {path}\n")
    for f in failures:
        print(f"  - {f}")
    sys.exit(1)

total = sum(len(g["hooks"]) for gs in hooks.values() for g in gs)
print(f"OK: {total} hook commands in {len(hooks)} events pass the cross-shell lint")
EOF
status=$?

# Behavioral smoke test on the host sh (mirrors macOS/Linux): every command
# must exit 0 and print nothing to stdout when its binary is missing or its
# script stands down. Run with a PATH that lacks powershell and an
# unconfigured HOME so hook.sh fail-opens to {} without network.
[ $status -eq 0 ] || exit $status

TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT

fails=0
count=0
while IFS= read -r cmd; do
    count=$((count + 1))
    out=$(printf '{}' | HOME="$TMP_HOME" CLAUDE_PLUGIN_ROOT="$ROOT/plugins/rogue" \
          ROGUE_BASE_URL="http://127.0.0.1:9" ROGUE_API_KEY="" \
          CLAUDE_CODE_ENTRYPOINT=cli sh -c "$cmd" 2>/dev/null)
    rc=$?
    if [ $rc -ne 0 ]; then
        echo "FAIL: exit $rc under sh: $cmd"
        fails=$((fails + 1))
    fi
    # stdout must be empty or JSON — anything else is shell noise Claude would choke on
    case "$out" in
        ''|'{'*) : ;;
        *) echo "FAIL: unexpected stdout [$out]: $cmd"; fails=$((fails + 1)) ;;
    esac
done <<EOF
$(python3 -c 'import json,sys; [print(h["command"]) for gs in json.load(open(sys.argv[1]))["hooks"].values() for g in gs for h in g["hooks"]]' "$HOOKS_JSON")
EOF

if [ $fails -ne 0 ]; then
    echo "FAIL: $fails command(s) misbehave under sh"
    exit 1
fi
echo "OK: all $count commands exit 0 with clean stdout under sh"
