#!/usr/bin/env bash
# Emits a systemMessage at SessionStart if no ROGUE_API_KEY is configured.

# Codex sets PLUGIN_ROOT to the installed plugin directory.
PLUGIN_ROOT="${PLUGIN_ROOT:-}"

# The first env file holding ROGUE_API_KEY is used alone: machine, bundled, user.
for _env_file in /etc/rogue/env "${PLUGIN_ROOT}/env" "$HOME/.rogue-env"; do
  if [ -r "$_env_file" ] && grep -Eq '^[[:space:]]*(export[[:space:]]+)?ROGUE_API_KEY=' "$_env_file"; then
    . "$_env_file"; break
  fi
done

[ -n "${ROGUE_API_KEY:-}" ] || printf '{"systemMessage": "[Rogue Security] Not configured. Run /rogue:setup to connect your API key."}'
