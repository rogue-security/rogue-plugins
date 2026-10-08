#!/usr/bin/env bash
set -euo pipefail
# Print the per-plugin version manifest as JSON.
#
# THIS IS THE ONLY PLACE THE SEVEN VERSION FILES ARE READ. build-release.sh calls
# it once and derives every per-tarball echo from the result, so the manifest
# attached to a release and the tarballs beside it cannot disagree. Reading a
# version file twice is exactly how they would.
#
# Keys are the plugin SLUGS (the hook-log file basenames), not the roster's
# agent_family: codex's family is `openai`. See
# docs/superpowers/specs/2026-08-20-plugin-version-manifest-design.md.
#
# Every read fails hard. A manifest with a hole reads as "up to date" on the
# dashboard forever, which is strictly worse than a failed build.
#
# Usage: plugin-versions.sh [repo-root]     (root defaults to this script's parent)

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

# Validate the WHOLE value, never a substring of it.
#
# Both readers below used to pull a three-field SUBSTRING out of the value and
# discard the rest, which meant "1.2.3-beta" was published as "1.2.3" — a manifest
# asserting a version the plugin does not have. That is the same silent-lie class
# this manifest exists to end, and it quietly defeated the build-hard guarantee
# above. Antigravity's check was looser still: a `[0-9]*.[0-9]*.[0-9]*` GLOB, in
# which `*` is a wildcard, so "1a.2b.3c", "9.9.9junk" and "1.2.3.4.5" were all
# accepted and emitted VERBATIM.
#
# Bash `[[ =~ ]]` rather than a pipe into `grep -qE '^...$'`: grep anchors per
# LINE, so a value carrying an embedded newline could satisfy it on its first line
# alone, whereas `$` here means end of string. Neither reader can currently
# produce such a value, and this way it stays true if one ever could.
_require_bare_semver() { # <value> <where>
  if [[ ! "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "✗ $2: version must be exactly X.Y.Z, got \"$1\"" >&2
    exit 1
  fi
}

# Read a "version" field WITHOUT python3 or jq — the /usr/bin/python3 stub fails
# silently on a fresh macOS, and jq is absent from minimal images. Same approach
# as heartbeat.sh and the old build-release.sh reads.
read_json_version() { # <path-relative-to-root>
  local rel="$1" f="$ROOT/$1" field v
  [ -f "$f" ] || { echo "✗ missing $rel" >&2; exit 1; }
  # Capture the first COMPLETE field, value and all. `[^"]*` rather than a
  # digit-anchored subpattern on purpose: the first "version" field is the
  # authoritative one, so a malformed value must be caught here instead of being
  # stepped over in favour of some later well-formed field elsewhere in the file.
  field=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null | head -1) || true
  [ -n "$field" ] || { echo "✗ no \"version\" field in $rel" >&2; exit 1; }
  v=$(printf '%s' "$field" | sed -E 's/^"version"[[:space:]]*:[[:space:]]*"(.*)"$/\1/')
  _require_bare_semver "$v" "$rel"
  printf '%s' "$v"
}

# Antigravity's plugin.json cannot carry a version: its CLI schema is
# additionalProperties:false. The version of record is a bare VERSION file.
read_plain_version() { # <path-relative-to-root>
  local rel="$1" f="$ROOT/$1" v
  [ -f "$f" ] || { echo "✗ missing $rel" >&2; exit 1; }
  # Surrounding whitespace and a CRLF ending are stripped, not rejected — a
  # VERSION file saved by a Windows editor is legitimate. Anything left over has
  # to be exactly X.Y.Z.
  v=$(head -n1 "$f" | tr -d ' \t\r\n')
  _require_bare_semver "$v" "$rel"
  printf '%s' "$v"
}

MUSE_V=$(read_json_version "plugins/muse/plugin.json")
CLAUDE_V=$(read_json_version "plugins/rogue/.claude-plugin/plugin.json")
CODEX_V=$(read_json_version "plugins/codex/.codex-plugin/plugin.json")
CURSOR_V=$(read_json_version "plugins/cursor/.cursor-plugin/plugin.json")
COPILOT_V=$(read_json_version "plugins/copilot/plugin.json")
GEMINI_V=$(read_json_version "plugins/gemini/gemini-extension.json")
ANTIGRAVITY_V=$(read_plain_version "plugins/antigravity/VERSION")
# Kiro carries both: plugin.json is the version of record (install-id.sh,
# hook.ps1 and heartbeat.ps1 all read it there) and a bare VERSION file beside
# it for operators and the release page. Two files is one drift waiting to
# happen, so this refuses to publish while they disagree rather than pick one.
KIRO_V=$(read_json_version "plugins/kiro/plugin.json")
KIRO_FILE_V=$(read_plain_version "plugins/kiro/VERSION")
if [ "$KIRO_V" != "$KIRO_FILE_V" ]; then
  echo "✗ plugins/kiro: plugin.json says $KIRO_V but VERSION says $KIRO_FILE_V" >&2
  exit 1
fi

cat <<JSON
{
  "schema": 1,
  "plugins": {
    "claude": "$CLAUDE_V",
    "codex": "$CODEX_V",
    "cursor": "$CURSOR_V",
    "copilot": "$COPILOT_V",
    "gemini": "$GEMINI_V",
    "antigravity": "$ANTIGRAVITY_V",
    "kiro": "$KIRO_V",
    "muse": "$MUSE_V"
  }
}
JSON
