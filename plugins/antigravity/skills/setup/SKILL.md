---
name: setup
description: Set up Rogue Security AIDR integration for Google Antigravity — configure API key, detect identity, and verify connection
---

# Rogue Security Setup (Google Antigravity)

Help the user set up their Rogue Security AIDR integration for Google Antigravity (IDE 2.0 and the `agy` CLI). Follow these steps in order.

**Pick the command variant for the user's OS.** Use the **macOS / Linux (bash)** commands by default; use the **Windows (PowerShell)** commands when the user is on native Windows. The plugin is installed at `~/.gemini/config/plugins/rogue` (IDE) or wherever `agy plugin install` placed it (CLI) — `%USERPROFILE%\.gemini\config\plugins\rogue` on Windows. Run the commands below from that directory; `cd` there first if the shell isn't already positioned there.

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

Read the key into a shell variable first (don't paste the literal key into the command — it would leak into shell history and process listings), then validate:

- macOS / Linux:
```bash
read -rs ROGUE_API_KEY   # paste the key at the prompt; not echoed, not in history
curl -s -o /dev/null -w "%{http_code}" -H "x-rogue-api-key: $ROGUE_API_KEY" https://api.rogue.security/api/v1/hooks/ping
```
- Windows (PowerShell):
```powershell
$sec = Read-Host -AsSecureString "Rogue API key"
$ROGUE_API_KEY = [System.Net.NetworkCredential]::new('', $sec).Password
try { (Invoke-WebRequest -Uri https://api.rogue.security/api/v1/hooks/ping -Headers @{ 'x-rogue-api-key' = $ROGUE_API_KEY } -UseBasicParsing -TimeoutSec 10).StatusCode } catch { $_.Exception.Response.StatusCode.value__ }
```

If the response is not `200`, tell the user the key is invalid and ask them to try again.

## Step 4: Detect identity

Run `git config --global user.email` and `git config --global user.name` (works the same in both shells) to detect the user's git identity. Show what was detected and ask if it's correct.

## Step 5: Store credentials

Run the setup script with the API key, email, and name, from the plugin's installed directory:

- macOS / Linux:
```bash
bash "./scripts/setup.sh" "$ROGUE_API_KEY" "<EMAIL>" "<NAME>"
```
- Windows (PowerShell):
```powershell
powershell -NoProfile -File "./scripts/setup.ps1" $ROGUE_API_KEY "<EMAIL>" "<NAME>"
```

Pass the key by variable (`$ROGUE_API_KEY`, captured in Step 3), never as a
literal — a literal lands in PSReadLine history and in the child process's
command line, where any local process can read it.

This writes `~/.rogue-env` (mode 600) on macOS/Linux, or `%USERPROFILE%\.rogue-env` (restricted to your user) on Windows. Hooks read this file at runtime — no shell profile changes needed. The file is shared with the other Rogue plugins (Claude Code, Codex, Cursor, Gemini CLI).

## Step 6: Final instructions

Tell the user:

1. Credentials are stored in `~/.rogue-env` (mode 600) on macOS/Linux, or `%USERPROFILE%\.rogue-env` (restricted to your user) on Windows
2. **A session restart may be needed** — restart Antigravity (IDE or `agy` CLI) so the hooks pick up the new credentials
3. After restarting, run `/status` to verify the connection
4. The AIDR dashboard is at https://app.rogue.security/aidr
