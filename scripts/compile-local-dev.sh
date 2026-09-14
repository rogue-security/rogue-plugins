#!/usr/bin/env bash
# Build a plugin zip from the LOCAL working tree — no GitHub fetch.
#
# Use this to test in-progress hook/script changes against Claude Desktop
# (or Cowork with --cowork) before cutting a release.
#
# Usage:
#   bash scripts/compile-local-dev.sh [--key rsk_xxx] [--cowork] [--out PATH]
#
# Args:
#   --key KEY        Optional. Bake ROGUE_API_KEY into the zip. Omit for an
#                    unconfigured plugin (end-user must run /rogue:setup).
#   --mode ask|block PreToolUse enforcement mode (default: ask). Only used with --key.
#   --out PATH       Output zip path (default: ./rogue-aidr-local-<sha>.zip)
#   --base-url URL   Override ROGUE_BASE_URL (rare).
#   --cowork         Strip hook events outside Cowork's manifest allow-list.
#                    Off by default — Claude Desktop accepts the full set.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO_ROOT/plugins/rogue"
[ -d "$SRC/.claude-plugin" ] || { echo "missing $SRC/.claude-plugin (run from repo root)" >&2; exit 1; }

KEY=""; MODE="ask"; OUT=""; BASE_URL=""; COWORK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --key)      KEY="$2"; shift 2 ;;
    --mode)     MODE="$2"; shift 2 ;;
    --out)      OUT="$2"; shift 2 ;;
    --base-url) BASE_URL="$2"; shift 2 ;;
    --cowork)   COWORK=1; shift ;;
    -h|--help)  sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

case "$MODE" in ask|block) ;; *) echo "Bad --mode: $MODE" >&2; exit 2 ;; esac

command -v python3 >/dev/null 2>&1 || { echo "missing required tool: python3" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STAGE="$WORK/rogue"
mkdir -p "$STAGE"
cp -R "$SRC"/. "$STAGE"/

# Optional Cowork allow-list filter — mirrors compile-customer-plugin.sh.
if [ "$COWORK" = "1" ]; then
  python3 - "$STAGE" <<'PY'
import json, os, sys
stage = sys.argv[1]
COWORK_ALLOW = {
    "PreToolUse", "PostToolUse", "Stop", "SubagentStop",
    "SessionStart", "SessionEnd", "UserPromptSubmit",
    "PreCompact", "Notification",
}
hp = os.path.join(stage, "hooks", "hooks.json")
with open(hp) as f:
    data = json.load(f)
hooks = data.get("hooks", {})
kept = {k: v for k, v in hooks.items() if k in COWORK_ALLOW}
dropped = sorted(set(hooks) - set(kept))
data["hooks"] = kept
with open(hp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
if dropped:
    print("-> stripped non-cowork events: " + ", ".join(dropped), file=sys.stderr)
PY
fi

# Generate marketplace.json so the drag-drop UI accepts the zip — same pattern
# as compile-customer-plugin.sh.
python3 - "$STAGE" <<'PY'
import json, os, sys
stage = sys.argv[1]
pjp = os.path.join(stage, ".claude-plugin", "plugin.json")
mjp = os.path.join(stage, ".claude-plugin", "marketplace.json")
with open(pjp) as f:
    p = json.load(f)
plugin_entry = {k: v for k, v in p.items()}
plugin_entry["source"] = "./"
market = {
    "name": f"{p['name']}-marketplace",
    "owner": p.get("author", {"name": p.get("name", "unknown")}),
    "plugins": [plugin_entry],
}
with open(mjp, "w") as f:
    json.dump(market, f, indent=2)
    f.write("\n")
PY

SHA=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
DIRTY=""
if ! git -C "$REPO_ROOT" diff --quiet 2>/dev/null || ! git -C "$REPO_ROOT" diff --cached --quiet 2>/dev/null; then
  DIRTY="-dirty"
fi

# Optionally bake the API key + config into ${CLAUDE_PLUGIN_ROOT}/env. Hooks
# source this when no /etc/rogue/env holds a key, and then read ~/.rogue-env
# not at all.
#
# Deliberately NO actor pre-seed here. This file used to emit
#   : "${ROGUE_ACTOR_EMAIL:=$(git config --global user.email)}"
# which runs at hook-fire time and short-circuits the dispatcher's cascade with
# whatever git identity the process has — inside Claude Cowork that is the
# sandbox's synthetic "Claude <noreply@anthropic.com>", so every user was
# reported as Claude. plugins/rogue/scripts/actor.sh now derives identity itself
# (CLAUDE_CODE_USER_EMAIL first, synthetic values rejected). Don't add it back.
if [ -n "$KEY" ]; then
  {
    echo "# Compiled by compile-local-dev.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# Source: local working tree (git ${SHA}${DIRTY})"
    printf 'export ROGUE_API_KEY=%q\n'              "$KEY"
    printf 'export ROGUE_PRETOOLUSE_ON_BLOCK=%q\n'  "$MODE"
    [ -n "$BASE_URL" ] && printf 'export ROGUE_BASE_URL=%q\n' "$BASE_URL"
    echo 'export ROGUE_AUTO_UPDATE=0'
  } > "$STAGE/env"
  chmod 600 "$STAGE/env"
fi

[ -n "$OUT" ] || OUT="$PWD/rogue-aidr-local-${SHA}${DIRTY}.zip"
rm -f "$OUT"

if command -v zip >/dev/null 2>&1; then
  ( cd "$STAGE" && zip -qr "$OUT" . )
else
  ( cd "$STAGE" && python3 - "$OUT" <<'PY'
import os, sys, zipfile
out = sys.argv[1]
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk('.'):
        for f in files:
            p = os.path.join(root, f)
            z.write(p, os.path.relpath(p, '.'))
PY
  )
fi

SIZE=$(wc -c < "$OUT" | awk '{print $1}')
KEY_INFO="no"
[ -n "$KEY" ] && KEY_INFO="yes (...${KEY: -4})"
COWORK_INFO="off"
[ "$COWORK" = "1" ] && COWORK_INFO="on (Cowork-only events kept)"

cat <<EOF

OK  wrote $OUT  ($SIZE bytes)

  Source:        local working tree (git ${SHA}${DIRTY})
  Cowork filter: $COWORK_INFO
  Mode:          $MODE
  Key baked:     $KEY_INFO

Install (Claude Desktop):
  1. In Claude Code's plugins UI, drag-and-drop this zip.
  2. Restart Claude Code. Run /rogue:status to verify.

EOF
