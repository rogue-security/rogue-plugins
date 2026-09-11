#!/usr/bin/env bash
# Propagate the SHARED plugin scripts from scripts/shared/ into every plugin tree.
#
#   scripts/sync-shared-scripts.sh           # write the copies
#   scripts/sync-shared-scripts.sh --check   # fail if any copy is stale (CI)
#
# Why copies exist at all, since this is the obvious thing to want to de-duplicate:
# each plugin is DISTRIBUTED AS A SELF-CONTAINED DIRECTORY, and by six different
# mechanisms. Cursor, Gemini and Antigravity are installed by copying just their own
# plugin tree; on a Cursor-only machine nothing outside
# ~/.cursor/plugins/local/rogue exists, so a runtime `. "$SHARED/ship-logs.sh"`
# would source a path that is not there. Symlinks do not rescue it either: Windows
# needs admin or developer mode to create them, and they do not survive the release
# tarballs.
#
# And the copies must be COMMITTED, not generated at release time, because
# `claude plugin install` / `codex plugin add` / `copilot plugin install` git-clone
# this monorepo and consume plugins/<x>/ directly, with no build step of any kind.
#
# So: one editable source, committed byte-identical copies, and CI that fails when
# they drift (tests/test_ship_logs.sh cmp's them; --check is the same assertion in a
# form that names the fix). Editing a plugin's copy directly is the mistake this
# guards: the next sync silently reverts it.
set -euo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO/scripts/shared"

# Each row: <source basename> | <space-separated plugin dirs that get it>
# Gemini is deliberately absent from every row: it ships single Node
# implementations (plugins/gemini/scripts/ship-logs.mjs, and the beacon throttle
# inlined in heartbeat.mjs) because Gemini CLI guarantees Node 20+, which is why
# there is no sh/PowerShell pair to keep in lockstep there.
# actor.sh / actor.ps1 are shared by the plugins whose host supplies no identity;
# plugins/rogue keeps its own (it ranks CLAUDE_CODE_USER_EMAIL above git and
# screens the Cowork sandbox identity).
ROWS=(
  "ship-logs.sh|rogue codex cursor copilot antigravity kiro"
  "ship-logs.ps1|rogue codex cursor copilot antigravity kiro"
  "beacon.sh|rogue codex cursor copilot antigravity kiro"
  "beacon.ps1|rogue codex cursor copilot antigravity kiro"
  "env-file.sh|rogue codex cursor copilot antigravity kiro"
  "env-file.ps1|rogue codex cursor copilot antigravity kiro"
  "git-identity.sh|rogue codex cursor copilot antigravity kiro"
  "git-identity.ps1|rogue codex cursor copilot antigravity kiro"
  "actor.sh|codex cursor copilot antigravity kiro"
  "actor.ps1|codex cursor copilot antigravity kiro"
)

# An unrecognized argument is an ERROR, not a silent write: the two modes have
# opposite effects on the working tree, so a typo (`-check`, `--dry-run`) used to
# skip the comparison and overwrite the plugin copies instead of reporting drift.
CHECK=0
case "${1:-}" in
  --check) CHECK=1 ;;
  "")      CHECK=0 ;;
  *)       echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

fail=0
for row in "${ROWS[@]}"; do
  name="${row%%|*}"
  plugins="${row#*|}"
  src="$SRC/$name"
  if [ ! -f "$src" ]; then
    echo "::error::missing source $src" >&2
    fail=1
    continue
  fi
  for p in $plugins; do
    dest="$REPO/plugins/$p/scripts/$name"
    if [ "$CHECK" = 1 ]; then
      if ! cmp -s "$src" "$dest"; then
        echo "::error file=$dest::stale copy of scripts/shared/$name — run scripts/sync-shared-scripts.sh" >&2
        fail=1
      fi
    else
      mkdir -p "$(dirname "$dest")"
      cp "$src" "$dest"
      echo "synced plugins/$p/scripts/$name"
    fi
  done
done

[ "$fail" = 0 ] || exit 1
[ "$CHECK" = 1 ] && echo "all shared script copies are in sync"
exit 0
