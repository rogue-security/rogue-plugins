---
name: setup
description: Set up Rogue Security AIDR integration — configure API key, detect identity, verify connection
---

# Rogue Security Setup

Help the user set up their Rogue Security AIDR integration for Cursor. Follow these steps in order.

**Pick the command variant for the user's OS.** Use the **macOS / Linux (bash)** commands by default; use the **Windows (PowerShell)** commands when the user is on native Windows (no WSL). On Windows, `${CURSOR_PLUGIN_ROOT}` is available as the `$env:CURSOR_PLUGIN_ROOT` environment variable.

## Step 1: Check existing configuration

Check the machine env file first:

- macOS / Linux: `grep -q ROGUE_API_KEY /etc/rogue/env 2>/dev/null && echo machine || echo none`
- Windows: `if (Test-Path "$env:ProgramData\rogue\env") { Select-String -Path "$env:ProgramData\rogue\env" -Pattern ROGUE_API_KEY -Quiet } else { $false }`

A machine env file that holds `ROGUE_API_KEY` and is owned by root (SYSTEM/Administrators on Windows) is the file the hooks read, alone, so credentials are already configured: say so and stop, without writing the user env file.

Otherwise check the user env file:

- macOS / Linux: `test -f ~/.rogue-env && echo exists || echo missing`
- Windows: `if (Test-Path "$env:USERPROFILE\.rogue-env") { 'exists' } else { 'missing' }`

If it exists, tell the user and ask if they want to reconfigure. If not, continue.

## Step 2: Get the API key

Ask the user for their Rogue Security API key (starts with `rsk_`). If they don't have one, direct them to https://app.rogue.security/settings/api-keys.

## Step 3: Validate the key

- macOS / Linux:
```bash
curl -s -o /dev/null -w "%{http_code}" -H "x-rogue-api-key: <KEY>" https://api.rogue.security/api/v1/hooks/ping
```
- Windows (PowerShell):
```powershell
try { (Invoke-WebRequest -Uri https://api.rogue.security/api/v1/hooks/ping -Headers @{ 'x-rogue-api-key' = '<KEY>' } -UseBasicParsing -TimeoutSec 10).StatusCode } catch { $_.Exception.Response.StatusCode.value__ }
```
Expect `200`. If not, the key is invalid — ask the user to try again.

## Step 4: Detect identity

```bash
git config --global user.email
git config --global user.name
```
(`git config` works the same in both shells.) Show what was detected and ask if it's correct.

## Step 5: Store credentials

- macOS / Linux:
```bash
bash "${CURSOR_PLUGIN_ROOT}/scripts/setup.sh" "<API_KEY>" "<EMAIL>" "<NAME>"
```
- Windows (PowerShell):
```powershell
powershell -NoProfile -File "$env:CURSOR_PLUGIN_ROOT\scripts\setup.ps1" "<API_KEY>" "<EMAIL>" "<NAME>"
```

## Step 6: Final instructions

Tell the user:

1. Credentials are stored in `~/.rogue-env` (mode 600) on macOS/Linux, or `%USERPROFILE%\.rogue-env` (restricted to your user) on Windows.
2. **Restart Cursor** (close all windows, reopen) — hooks read credentials at session start.
3. Run `/rogue:status` to verify the connection.
4. AIDR dashboard: https://app.rogue.security/aidr
