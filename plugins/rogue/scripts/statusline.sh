#!/usr/bin/env bash
# Rogue Security status badge — rendered below the Claude Code prompt via the
# `statusLine` setting. Reads the same credential files the hooks read and
# prints a teal "Rogue Security" label with a status circle:
#   🟢 [Rogue Security] when an API key is configured, 🔴 when it is not.
#
# NOTE: install.sh embeds a byte-identical copy of the badge body via heredoc
# (it writes ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/rogue-statusline.sh so
# the path is stable across plugin-cache upgrades). Keep the two in sync.
set -u

for f in /etc/rogue/env "$HOME/.rogue-env"; do
  if [ -r "$f" ] && grep -Eq '^[[:space:]]*(export[[:space:]]+)?ROGUE_API_KEY=' "$f"; then . "$f"; break; fi
done

if [ -n "${ROGUE_API_KEY:-}" ]; then
  dot='🟢'
else
  dot='🔴'
fi

printf '%s \033[38;2;74;176;227m[Rogue Security]\033[0m' "$dot"
