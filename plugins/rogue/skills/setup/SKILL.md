---
description: Set up Rogue Security AIDR integration — configure API key, detect identity, and verify connection
disable-model-invocation: true
---

# Rogue Security Setup

Help the user set up their Rogue Security AIDR integration for Claude Code. Follow these steps in order:

**Pick the command variant for the user's OS.** Use the **macOS / Linux (bash)** commands by default; use the **Windows (PowerShell)** commands when the user is on native Windows (no WSL). On Windows, `${CLAUDE_PLUGIN_ROOT}` is available as the `$env:CLAUDE_PLUGIN_ROOT` environment variable.

## Step 1: Check existing configuration

Check the machine env file first:

- macOS / Linux: `grep -q ROGUE_API_KEY /etc/rogue/env 2>/dev/null && echo machine || echo none`
- Windows: `if (Test-Path "$env:ProgramData\rogue\env") { Select-String -Path "$env:ProgramData\rogue\env" -Pattern ROGUE_API_KEY -Quiet } else { $false }`

A machine env file that holds `ROGUE_API_KEY` and is owned by root (SYSTEM/Administrators on Windows) is the file the hooks read, alone, so credentials are already configured: say so and stop, without writing the user env file.

Otherwise check the user env file:

- macOS / Linux: `test -f ~/.rogue-env && echo "exists" || echo "not found"`
- Windows: `if (Test-Path "$env:USERPROFILE\.rogue-env") { 'exists' } else { 'not found' }`

If already configured, tell the user and ask if they want to reconfigure. If not, continue.

## Step 2: Get the API key

Ask the user for their Rogue Security API key. It should start with `rsk_`.

If they don't have one, direct them to generate one at: https://app.rogue.security/settings/api-keys

## Step 3: Validate the API key

Run this command to validate (replace `<KEY>` with the actual key):

- macOS / Linux:
```bash
curl -s -o /dev/null -w "%{http_code}" -H "x-rogue-api-key: <KEY>" https://api.rogue.security/api/v1/hooks/ping
```
- Windows (PowerShell):
```powershell
try { (Invoke-WebRequest -Uri https://api.rogue.security/api/v1/hooks/ping -Headers @{ 'x-rogue-api-key' = '<KEY>' } -UseBasicParsing -TimeoutSec 10).StatusCode } catch { $_.Exception.Response.StatusCode.value__ }
```

If the response is not `200`, tell the user the key is invalid and ask them to try again.

## Step 4: Detect identity

Run `git config user.email` and `git config user.name` to detect the user's git identity (these work the same in both shells). Show what was detected and ask if it's correct.

## Step 5: Store credentials

Run the setup script with the API key, email, and name:

- macOS / Linux:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" "<API_KEY>" "<EMAIL>" "<NAME>"
```
- Windows (PowerShell):
```powershell
powershell -NoProfile -File "$env:CLAUDE_PLUGIN_ROOT\scripts\setup.ps1" "<API_KEY>" "<EMAIL>" "<NAME>"
```

This writes `~/.rogue-env` (mode 600) on macOS/Linux, or `%USERPROFILE%\.rogue-env` (restricted to your user) on Windows. Hooks read this file at runtime — no shell profile changes needed.

## Step 6: Final instructions

Tell the user:

1. Credentials are stored in `~/.rogue-env` (mode 600) on macOS/Linux, or `%USERPROFILE%\.rogue-env` (restricted to your user) on Windows
2. **They must fully quit Claude Code (Cmd-Q on macOS) and reopen it** — hooks load credentials on session start
3. After restarting, they can run `/rogue:status` to verify the connection
4. The AIDR dashboard is at https://app.rogue.security/aidr
