---
description: Set up Rogue Security AIDR integration — configure API key, detect identity, and verify connection
---

# Rogue Security Setup (GitHub Copilot CLI)

Help the user set up their Rogue Security AIDR integration for GitHub Copilot CLI. Follow these steps in order.

The commands below are bash (macOS/Linux). **On Windows**, use the PowerShell
equivalents — the env file is `$env:USERPROFILE\.rogue-env`; check it with
`Test-Path`, validate the key with `Invoke-WebRequest`, and store credentials with
`scripts\setup.ps1` (instead of `scripts/setup.sh`). The Windows equivalent for
each step is shown after the bash block where it differs.

## Step 1: Check existing configuration

Check the machine env file first with `grep -q ROGUE_API_KEY /etc/rogue/env 2>/dev/null && echo machine || echo none` (Windows: `if (Test-Path "$env:ProgramData\rogue\env") { Select-String -Path "$env:ProgramData\rogue\env" -Pattern ROGUE_API_KEY -Quiet } else { $false }`). A machine env file that holds `ROGUE_API_KEY` and is owned by root (SYSTEM/Administrators on Windows) is the file the hooks read, alone, so credentials are already configured: say so and stop, without writing the user env file.

Otherwise check if `~/.rogue-env` exists with `test -f ~/.rogue-env && echo "exists" || echo "not found"`.

If already configured, tell the user and ask if they want to reconfigure. If not, continue.

## Step 2: Get the API key

Ask the user for their Rogue Security API key. It should start with `rsk_`.

If they don't have one, direct them to generate one at: https://app.rogue.security/settings/api-keys

## Step 3: Validate the API key

Read the key into a shell variable first (don't paste the literal key into the
command — it would leak into shell history and process listings), then validate:
```bash
read -rs ROGUE_API_KEY   # paste the key at the prompt; not echoed, not in history
curl -s -o /dev/null -w "%{http_code}" -H "x-rogue-api-key: $ROGUE_API_KEY" https://api.rogue.security/api/v1/hooks/ping
```

Windows (PowerShell):
```powershell
$sec = Read-Host -AsSecureString "Rogue API key"
$ROGUE_API_KEY = [System.Net.NetworkCredential]::new('', $sec).Password
(Invoke-WebRequest -Uri https://api.rogue.security/api/v1/hooks/ping -Headers @{ 'x-rogue-api-key' = $ROGUE_API_KEY } -UseBasicParsing).StatusCode
```

If the response is not `200`, tell the user the key is invalid and ask them to try again.

## Step 4: Detect identity

Run `git config user.email` and `git config user.name` to detect the user's git identity. Show what was detected and ask if it's correct.

## Step 5: Store credentials

Run the setup script with the API key, email, and name:
```bash
bash "${PLUGIN_ROOT}/scripts/setup.sh" "$ROGUE_API_KEY" "<EMAIL>" "<NAME>"
```

Windows (PowerShell):
```powershell
& "$env:PLUGIN_ROOT\scripts\setup.ps1" $ROGUE_API_KEY "<EMAIL>" "<NAME>"
```

This writes `~/.rogue-env` / `%USERPROFILE%\.rogue-env` (locked to the user). Hooks
read it at runtime — no shell profile changes needed. The file is shared with the
other Rogue plugins (Claude, Codex, Cursor, Gemini).

## Step 6: Trust the hooks (REQUIRED for Copilot CLI)

Copilot CLI **skips untrusted command hooks** until they are reviewed. Tell the user:

1. Open `/hooks` in Copilot CLI
2. Review and **trust** the Rogue Security hook entries

Until this is done, no events are sent. (Trust is recorded against the hook
definition; script-only plugin updates keep the same hook definition, so this is
a one-time step.)

**If the user works in JetBrains**, also tell them to select Copilot's
**CLI/Agent** provider. The IDE's built-in **Local** agent runs a separate hook
engine that reads only `<git-root>/.github/hooks/**/*.json` and refuses
plugin-provided hooks, so with Local selected Rogue sees and blocks **nothing** —
and cannot warn them from inside the IDE, since no hook ever runs.

## Step 7: Final instructions

Tell the user:

1. Credentials are stored in `~/.rogue-env` with restricted permissions (mode 600)
2. **Restart Copilot CLI** so the plugin loads the credentials
3. After restarting (and trusting via `/hooks`), run `/rogue:status` to verify
4. In **JetBrains**, a blocked prompt also raises a desktop alert with the reason,
   because the IDE renders nothing for it itself. Add `export ROGUE_IDE_ALERT=0`
   to `~/.rogue-env` to disable the alert — the block is still enforced, it just
   becomes invisible in the IDE again.
5. The AIDR dashboard is at https://app.rogue.security/aidr
