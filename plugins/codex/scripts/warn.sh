#!/usr/bin/env bash
# Emits a systemMessage at SessionStart if no ROGUE_API_KEY is configured.

# Codex sets PLUGIN_ROOT to the installed plugin directory.
PLUGIN_ROOT="${PLUGIN_ROOT:-}"

# The first trusted env file holding ROGUE_API_KEY is used alone: machine, bundled, user.
_env_lib="$(dirname -- "$0")/env-file.sh"
if [ -r "$_env_lib" ]; then
  . "$_env_lib"
  for _env_file in /etc/rogue/env "${PLUGIN_ROOT}/env" "$HOME/.rogue-env"; do
    if rogue_env_is_trusted "$_env_file" && grep -Eq "^[[:space:]]*(export[[:space:]]+)?ROGUE_API_KEY=[\"']?[^\"'[:space:]]" "$_env_file"; then
      . "$_env_file"; break
    fi
  done
fi

[ -n "${ROGUE_API_KEY:-}" ] || printf '{"systemMessage": "[Rogue Security] Not configured. Run /rogue:setup to connect your API key."}'
