#!/usr/bin/env bash
# Build a self-contained, pre-configured Rogue plugin ZIP.
#
# The resulting zip can be dragged into Claude Code without the customer
# running /rogue:setup — the API key is baked into an `env` file at the
# plugin root, which every hook sources when no /etc/rogue/env holds a key
# (~/.rogue-env is then not read at all).
#
# Actor identity (email/name) is intentionally NOT compiled in. It is
# derived per-user at hook-fire time from git config / $USER on the
# end-user's machine. Per-user ~/.rogue-env overrides still win.
#
# One-liner (admin runs this):
#   curl -fsSL https://raw.githubusercontent.com/qualifire-dev/rogue-plugins/main/scripts/compile-customer-plugin.sh \
#     | bash -s -- --key rsk_xxx
#
# Local / interactive (prompts for missing args):
#   bash scripts/compile-customer-plugin.sh
#
# Args:
#   --key KEY        ROGUE_API_KEY (required)
#   --mode ask|block PreToolUse enforcement mode (default: ask)
#   --from vX.Y.Z    Source release tag (default: latest GitHub release)
#   --out PATH       Output zip path (default: ./rogue-aidr-compiled-<ver>.zip)
#   --base-url URL   Override ROGUE_BASE_URL (rare)
#   --repo OWNER/REPO  Source repo (default: qualifire-dev/rogue-plugins)
#
# Output: a flat zip whose root contains .claude-plugin/, hooks/, scripts/,
# skills/, and env. Drag-drop or extract into ~/.claude/plugins/<name>/.

set -euo pipefail

REPO="qualifire-dev/rogue-plugins"
KEY=""; MODE=""; FROM=""; OUT=""; BASE_URL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --key)      KEY="$2"; shift 2 ;;
    --mode)     MODE="$2"; shift 2 ;;
    --from)     FROM="$2"; shift 2 ;;
    --out)      OUT="$2"; shift 2 ;;
    --base-url) BASE_URL="$2"; shift 2 ;;
    --repo)     REPO="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,30p' "$0" 2>/dev/null
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# When invoked via `curl | bash`, stdin is the piped script — prompts must
# read from the terminal directly.
TTY=/dev/tty
[ -r "$TTY" ] && [ -w "$TTY" ] || TTY=""

prompt_var() {
  local var="$1" label="$2" cur
  eval "cur=\${$var:-}"
  [ -n "$cur" ] && return 0
  if [ -z "$TTY" ]; then
    echo "Missing --${var,,} (no TTY available for interactive prompt)" >&2
    exit 2
  fi
  printf "%s: " "$label" > "$TTY"
  local value
  IFS= read -r value < "$TTY"
  eval "$var=\$value"
}

prompt_var KEY "Rogue API key (rsk_...)"

case "$MODE" in
  ""|ask|block) ;;
  *) echo "Bad --mode: $MODE (expected: ask|block)" >&2; exit 2 ;;
esac
MODE="${MODE:-ask}"

[ -n "$KEY" ] || { echo "API key required" >&2; exit 2; }

for tool in curl tar python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing required tool: $tool" >&2; exit 1; }
done

# Resolve release tag.
if [ -z "$FROM" ]; then
  echo "-> resolving latest release tag of $REPO..."
  FROM=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["tag_name"])')
  [ -n "$FROM" ] || { echo "could not resolve latest tag" >&2; exit 1; }
fi
echo "-> using release: $FROM"

TARBALL_URL="https://github.com/${REPO}/releases/download/${FROM}/rogue-plugin-claude.tar.gz"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "-> downloading $TARBALL_URL"
curl -fsSL "$TARBALL_URL" -o "$WORK/src.tar.gz"
tar -xzf "$WORK/src.tar.gz" -C "$WORK"

# Tarball layout: rogue-plugin-claude/plugins/rogue/...
SRC="$WORK/rogue-plugin-claude/plugins/rogue"
[ -d "$SRC/.claude-plugin" ] || { echo "unexpected tarball layout at $SRC" >&2; exit 1; }

# Flatten: plugin root becomes the zip root.
STAGE="$WORK/rogue"
mkdir -p "$STAGE"
cp -R "$SRC"/. "$STAGE"/

# Cowork's plugin-manifest validator has a narrower hook allow-list than the
# Claude Code runtime. Strip events outside that allow-list — purely for the
# Cowork-bound bundle; the source hooks.json (used by the marketplace install
# path) keeps the full set.
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
    print("-> stripped unsupported hook events: " + ", ".join(dropped), file=sys.stderr)
PY

# Cowork's drag-drop UI expects a marketplace zip, not a bare plugin. Generate
# a "single-plugin at root" marketplace.json next to plugin.json — same pattern
# as e.g. jarrodwatts-claude-stt: source "./" means the marketplace root *is*
# the plugin root.
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

# Older releases predate the ${CLAUDE_PLUGIN_ROOT}/env source line. Patch the
# bundled hooks idempotently so this script works against any release tag.
python3 - "$STAGE" <<'PY'
import json, os, re, sys
stage = sys.argv[1]
src_old = r'[ -r /etc/rogue/env ] && . /etc/rogue/env;'
src_new = r'[ -r "${CLAUDE_PLUGIN_ROOT}/env" ] && . "${CLAUDE_PLUGIN_ROOT}/env"; [ -r /etc/rogue/env ] && . /etc/rogue/env;'
hp = os.path.join(stage, "hooks", "hooks.json")
with open(hp) as f:
    data = json.load(f)
def walk(o):
    if isinstance(o, dict):
        if o.get("type") == "command" and isinstance(o.get("command"), str):
            c = o["command"]
            if "CLAUDE_PLUGIN_ROOT}/env" not in c and src_old in c:
                o["command"] = c.replace(src_old, src_new, 1)
        for v in o.values(): walk(v)
    elif isinstance(o, list):
        for v in o: walk(v)
walk(data)
with open(hp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

# Same for pretooluse.sh.
pp = os.path.join(stage, "scripts", "pretooluse.sh")
if os.path.exists(pp):
    with open(pp) as f:
        body = f.read()
    if "CLAUDE_PLUGIN_ROOT}/env" not in body:
        body = body.replace(
            '[ -r /etc/rogue/env ] && . /etc/rogue/env\n',
            '[ -r "${CLAUDE_PLUGIN_ROOT}/env" ] && . "${CLAUDE_PLUGIN_ROOT}/env"\n[ -r /etc/rogue/env ] && . /etc/rogue/env\n',
            1,
        )
        with open(pp, "w") as f:
            f.write(body)
PY

# Bake the API key + config into ${CLAUDE_PLUGIN_ROOT}/env. Actor identity is
# derived per-user at hook-fire time by plugins/rogue/scripts/actor.sh (and its
# hook.ps1 twin), so the same compiled zip works for every end user.
# ~/.rogue-env on the end-user's machine still overrides anything here because
# it's sourced after this file.
#
# Deliberately NO actor pre-seed here. This file used to emit
#   : "${ROGUE_ACTOR_EMAIL:=$(git config --global user.email)}"
# whose $( ) runs at hook-fire time and short-circuits the dispatcher's cascade.
# The comment that justified it ("hooks empirically run on the host, so hostname
# is a stable per-machine identifier") is exactly the assumption that broke:
# inside Claude Cowork the hook runs in a sandbox as unix user `claude`, with
# git configured as Anthropic's synthetic "Claude <noreply@anthropic.com>", so
# every Cowork user was reported as Claude while the real
# CLAUDE_CODE_USER_EMAIL sat unread. actor.sh now ranks CLAUDE_CODE_USER_EMAIL
# above git config and rejects synthetic identities (including any arriving via
# ROGUE_ACTOR_*, which is what lets a plugin update repair bundles already in
# the field that carry the old pre-seed). Don't add it back.
{
  echo "# Compiled by compile-customer-plugin.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# Source release: ${FROM}"
  printf 'export ROGUE_API_KEY=%q\n'      "$KEY"
  printf 'export ROGUE_PRETOOLUSE_ON_BLOCK=%q\n' "$MODE"
  [ -n "$BASE_URL" ] && printf 'export ROGUE_BASE_URL=%q\n' "$BASE_URL"
  # The bundled version is the truth — don't let auto-update clobber it.
  echo 'export ROGUE_AUTO_UPDATE=0'
} > "$STAGE/env"
chmod 600 "$STAGE/env"

VERSION_NO_V="${FROM#v}"
[ -n "$OUT" ] || OUT="$PWD/rogue-aidr-compiled-${VERSION_NO_V}.zip"
rm -f "$OUT"

# Flat zip: plugin contents at the zip root, no wrapping directory. This is
# what the Claude Code plugin UI's drag-drop validator expects.
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
KEY_TAIL="${KEY: -4}"

cat <<EOF

OK  wrote $OUT  (${SIZE} bytes)

  Plugin version: $FROM
  Mode:           $MODE
  Key tail:       ...${KEY_TAIL}
  Actor:          (resolved per-user at runtime from git config / \$USER)

!!  This zip embeds ROGUE_API_KEY in plaintext. Distribute over trusted
    channels only. To rotate: revoke the key in the dashboard and rebuild.

Customer install (drag-and-drop):
  1. In Claude Code's plugins UI, drag and drop this zip.
  2. Restart Claude Code. Run /rogue:status to verify the bundled key works.

  Zip layout is flat — .claude-plugin/, hooks/, scripts/, skills/, and the
  compiled env sit at the zip root, no wrapper directory.

EOF
