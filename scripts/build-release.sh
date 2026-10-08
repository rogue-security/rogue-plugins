#!/usr/bin/env bash
set -euo pipefail
# Build the release tarball for rogue-plugin-claude.
# Output: dist/rogue-plugin-claude.tar.gz
#
# The package is cross-platform by content: it ships BOTH the POSIX-sh scripts
# (hook.sh, heartbeat.sh, …) and their PowerShell siblings (hook.ps1, …), and
# hooks.json registers an `sh` entry and a PowerShell entry for every event.
# There is therefore nothing OS-specific to split — one tarball serves macOS,
# Linux, and Windows. The filename has NO version and NO OS suffix so the
# GitHub Releases /latest/download/ asset URL stays stable.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DIST="$ROOT/dist"
# Every version comes from ONE reader, so the manifest we publish and the
# tarballs we build beside it cannot disagree. See scripts/plugin-versions.sh.
VERSIONS_JSON=$("$ROOT/scripts/plugin-versions.sh" "$ROOT")

plugin_version() { # <slug>
  printf '%s' "$VERSIONS_JSON" | tr -d ' \t\n\r' \
    | grep -oE "\"$1\":\"[0-9]+\.[0-9]+\.[0-9]+\"" | head -1 \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'
}

PLUGIN_VERSION=$(plugin_version claude)
echo "→ plugin version: $PLUGIN_VERSION"

rm -rf "$DIST"
mkdir -p "$DIST"

COMMON_FILES=(
  ".claude-plugin"
  "plugins"
  "README.md"
  "LICENSE"
)

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
TOPDIR="$STAGE/rogue-plugin-claude"
mkdir -p "$TOPDIR"

for f in "${COMMON_FILES[@]}"; do
  [ -e "$f" ] || { echo "✗ missing: $f" >&2; exit 1; }
  cp -R "$f" "$TOPDIR/"
done

OUT="$DIST/rogue-plugin-claude.tar.gz"
tar -czf "$OUT" -C "$STAGE" "rogue-plugin-claude"
SIZE=$(wc -c < "$OUT" | awk '{print $1}')
echo "✓ $OUT  ($SIZE bytes, version $PLUGIN_VERSION)"

# ── Codex plugin tarball ────────────────────────────────────────────────────
# Primary Codex install path is `codex plugin marketplace add <repo>` (git), but
# we also ship a versionless tarball so /releases/latest/download URLs are stable
# (used by compiled-key MDM bundles and any download-based install).
if [ -d "plugins/codex" ]; then
  CODEX_VERSION=$(plugin_version codex)
  echo "→ codex plugin version: $CODEX_VERSION"
  # Single cross-platform tarball (no OS suffix), matching the claude artifact —
  # the package ships both .sh and .ps1, so /latest/download/ stays stable.
  CXSTAGE=$(mktemp -d)
  CXTOP="$CXSTAGE/rogue-plugin-codex"
  mkdir -p "$CXTOP/plugins" "$CXTOP/.agents/plugins"
  cp .agents/plugins/marketplace.json "$CXTOP/.agents/plugins/"
  cp -R plugins/codex "$CXTOP/plugins/"
  cp README.md LICENSE "$CXTOP/" 2>/dev/null || true
  CXOUT="$DIST/rogue-plugin-codex.tar.gz"
  tar -czf "$CXOUT" -C "$CXSTAGE" "rogue-plugin-codex"
  CXSIZE=$(wc -c < "$CXOUT" | awk '{print $1}')
  echo "✓ $CXOUT  ($CXSIZE bytes, version $CODEX_VERSION)"
  rm -rf "$CXSTAGE"
fi

# ── Cursor plugin tarball ───────────────────────────────────────────────────
# Cursor has no plugin CLI, so the one-line installer downloads THIS tarball and
# copies plugins/cursor/ into ~/.cursor/plugins/local/rogue. Versionless name keeps
# the /releases/latest/download/ URL stable. Cross-platform by content (the hook is
# python3). The Team Marketplace imports the repo directly, not this tarball.
if [ -d "plugins/cursor" ]; then
  CURSOR_VERSION=$(plugin_version cursor)
  echo "→ cursor plugin version: $CURSOR_VERSION"
  CRSTAGE=$(mktemp -d)
  CRTOP="$CRSTAGE/rogue-plugin-cursor"
  mkdir -p "$CRTOP/plugins" "$CRTOP/.cursor-plugin"
  cp .cursor-plugin/marketplace.json "$CRTOP/.cursor-plugin/"
  cp -R plugins/cursor "$CRTOP/plugins/"
  cp README.md LICENSE "$CRTOP/" 2>/dev/null || true
  CROUT="$DIST/rogue-plugin-cursor.tar.gz"
  tar -czf "$CROUT" \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    -C "$CRSTAGE" "rogue-plugin-cursor"
  CRSIZE=$(wc -c < "$CROUT" | awk '{print $1}')
  echo "✓ $CROUT  ($CRSIZE bytes, version $CURSOR_VERSION)"
  rm -rf "$CRSTAGE"
fi

# ── Gemini CLI extension tarball ─────────────────────────────────────────────
# Gemini has no plugin CLI marketplace; the one-line installer downloads THIS
# tarball, extracts it, and runs `gemini extensions install <dir>`. So — unlike
# the Claude/Codex/Cursor tarballs, which stage the plugin UNDER plugins/<x>/ —
# the Gemini archive's TOP DIR *is* the extension: gemini-extension.json sits at
# the archive root, which is what `gemini extensions install` requires.
# Versionless name keeps the /releases/latest/download/ URL stable. Cross-platform
# by content (one Node .mjs hook; no OS-specific scripts to split).
if [ -d "plugins/gemini" ]; then
  GEMINI_VERSION=$(plugin_version gemini)
  echo "→ gemini extension version: $GEMINI_VERSION"
  GMSTAGE=$(mktemp -d)
  GMTOP="$GMSTAGE/rogue-plugin-gemini"
  mkdir -p "$GMTOP"
  # Copy the extension CONTENTS to the archive top dir (manifest at root).
  cp -R plugins/gemini/. "$GMTOP/"
  cp LICENSE "$GMTOP/" 2>/dev/null || true
  GMOUT="$DIST/rogue-plugin-gemini.tar.gz"
  tar -czf "$GMOUT" -C "$GMSTAGE" "rogue-plugin-gemini"
  GMSIZE=$(wc -c < "$GMOUT" | awk '{print $1}')
  echo "✓ $GMOUT  ($GMSIZE bytes, version $GEMINI_VERSION)"
  rm -rf "$GMSTAGE"
fi

# ── Google Antigravity plugin tarball ────────────────────────────────────────
# Antigravity has no plugin-CLI marketplace; the one-line installer downloads
# THIS tarball, extracts it, copies it into ~/.gemini/config/plugins/rogue, and
# (if `agy` is on PATH) also runs `agy plugin install <dir>`. Like Gemini — and
# unlike the Claude/Codex/Cursor tarballs, which stage the plugin UNDER
# plugins/<x>/ — the archive's TOP DIR *is* the plugin: plugin.json sits at the
# archive root. Antigravity's plugin.json has NO `version` field (schema is
# additionalProperties:false), so the version lives in a bundled VERSION file
# instead. Versionless tarball name keeps the /releases/latest/download/ URL
# stable. Cross-platform by content (ships both hook.sh and hook.ps1).
if [ -d "plugins/antigravity" ]; then
  AGV_VER=$(plugin_version antigravity)
  echo "→ antigravity plugin version: $AGV_VER"
  AGVSTAGE=$(mktemp -d)
  AGVTOP="$AGVSTAGE/rogue-plugin-antigravity"
  mkdir -p "$AGVTOP"
  # Copy the plugin CONTENTS to the archive top dir (manifest at root).
  cp -R plugins/antigravity/. "$AGVTOP/"
  cp LICENSE "$AGVTOP/" 2>/dev/null || true
  AGVOUT="$DIST/rogue-plugin-antigravity.tar.gz"
  tar -czf "$AGVOUT" \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    -C "$AGVSTAGE" "rogue-plugin-antigravity"
  AGVSIZE=$(wc -c < "$AGVOUT" | awk '{print $1}')
  echo "✓ $AGVOUT  ($AGVSIZE bytes, version $AGV_VER)"
  rm -rf "$AGVSTAGE"
fi

# ── Kiro plugin tarball ──────────────────────────────────────────────────────
# Kiro has no plugin CLI or marketplace; the one-line installer downloads THIS
# tarball, extracts it, and copies it to ~/.rogue/plugins/kiro — outside every
# Kiro path — then writes the hook files that point Kiro at the bridge. Like
# Antigravity, the archive's TOP DIR *is* the plugin: plugin.json sits at the
# archive root. Versionless name keeps the /releases/latest/download/ URL
# stable. Cross-platform by content (ships both hook.sh and hook.ps1).
if [ -d "plugins/kiro" ]; then
  KIRO_VERSION=$(plugin_version kiro)
  echo "→ kiro plugin version: $KIRO_VERSION"
  KRSTAGE=$(mktemp -d)
  KRTOP="$KRSTAGE/rogue-plugin-kiro"
  mkdir -p "$KRTOP"
  cp -R plugins/kiro/. "$KRTOP/"
  cp LICENSE "$KRTOP/" 2>/dev/null || true
  KROUT="$DIST/rogue-plugin-kiro.tar.gz"
  tar -czf "$KROUT" -C "$KRSTAGE" "rogue-plugin-kiro"
  KRSIZE=$(wc -c < "$KROUT" | awk '{print $1}')
  echo "✓ $KROUT  ($KRSIZE bytes, version $KIRO_VERSION)"
  rm -rf "$KRSTAGE"
fi

# ── GitHub Copilot CLI plugin tarball ────────────────────────────────────────
# Primary Copilot install path is `copilot plugin marketplace add <repo>` (git),
# but we also ship a versionless tarball so /releases/latest/download URLs are
# stable (used by compiled-key MDM bundles). Like Claude/Codex — and UNLIKE the
# Gemini "archive-root-is-the-plugin" layout — the plugin is staged UNDER
# plugins/copilot/ alongside its marketplace file (.github/plugin/marketplace.json).
# Cross-platform by content (ships both hook.sh and hook.ps1).
if [ -d "plugins/copilot" ]; then
  COPILOT_VERSION=$(plugin_version copilot)
  echo "→ copilot plugin version: $COPILOT_VERSION"
  CPSTAGE=$(mktemp -d)
  CPTOP="$CPSTAGE/rogue-plugin-copilot"
  mkdir -p "$CPTOP/plugins" "$CPTOP/.github/plugin"
  cp .github/plugin/marketplace.json "$CPTOP/.github/plugin/"
  cp -R plugins/copilot "$CPTOP/plugins/"
  cp README.md LICENSE "$CPTOP/" 2>/dev/null || true
  CPOUT="$DIST/rogue-plugin-copilot.tar.gz"
  tar -czf "$CPOUT" -C "$CPSTAGE" "rogue-plugin-copilot"
  CPSIZE=$(wc -c < "$CPOUT" | awk '{print $1}')
  echo "✓ $CPOUT  ($CPSIZE bytes, version $COPILOT_VERSION)"
  rm -rf "$CPSTAGE"
fi

# Muse uses native command hooks; the archive root is the bridge bundle.
MUSE_STAGE=$(mktemp -d)
mkdir -p "$MUSE_STAGE/rogue-plugin-muse"
cp -R plugins/muse/. "$MUSE_STAGE/rogue-plugin-muse/"
cp LICENSE "$MUSE_STAGE/rogue-plugin-muse/"
tar -czf "$DIST/rogue-plugin-muse.tar.gz" -C "$MUSE_STAGE" rogue-plugin-muse
rm -rf "$MUSE_STAGE"

# ── Version manifest ────────────────────────────────────────────────────────
# The backend resolves every surface's "latest version" from THIS file, fetched
# from /releases/latest/download/versions.json. It is the reason a release name
# no longer has to encode any plugin's version.
printf '%s\n' "$VERSIONS_JSON" > "$DIST/versions.json"
echo "✓ $DIST/versions.json"

echo ""
echo "dist/:"
ls -la "$DIST"
