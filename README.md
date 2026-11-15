# Rogue Security — Claude Code Plugin

Real-time AI agent detection and response (AIDR) for [Claude Code](https://claude.com/code).
Observes every prompt, tool call, permission request, and subagent — flags
prompt injections, secret exfiltration, and destructive commands before they
reach production.

## Install

One-line installer (recommended):

**macOS / Linux:**

```bash
curl -fsSL https://raw.githubusercontent.com/qualifire-dev/rogue-plugins/main/install.sh | bash
```

**Windows** (PowerShell 5.1+, run as your normal user):

```powershell
iwr -useb https://raw.githubusercontent.com/qualifire-dev/rogue-plugins/main/install.ps1 | iex
```

Pass credentials via environment variables before the one-liner when running non-interactively:

```powershell
$env:ROGUE_API_KEY='rsk_xxx'; $env:ROGUE_ACTOR_EMAIL='you@co.com'; iwr -useb https://raw.githubusercontent.com/qualifire-dev/rogue-plugins/main/install.ps1 | iex
```

The one installer detects every supported coding agent and installs the matching
Rogue plugin into each — **Claude Code**, **OpenAI Codex**, **Cursor**,
**Gemini CLI**, **GitHub Copilot CLI**, **Google Antigravity**, **Kiro**, and
**Snowflake Cortex Code** (macOS and Linux) —
writing the shared `~/.rogue-env` (`%USERPROFILE%\.rogue-env` on
Windows) once. On a machine whose `/etc/rogue/env` (`C:\ProgramData\rogue\env`)
already holds `ROGUE_API_KEY` it prompts for nothing and writes no user file:
that machine file is the one the hooks read, and its key is validated in place.
A machine file that is not root-owned (SYSTEM/Administrators on Windows) or is
writable by others is skipped by Kiro and the log shipper, so the installer
warns and falls back to the user file. Claude and Codex install through
their native plugin CLIs (`claude plugin install` / `codex plugin add`);
**Cursor has no plugin CLI**, so
its plugin is copied into `~/.cursor/plugins/local/rogue` from the release tarball;
**Gemini CLI** installs from the release tarball via its native
`gemini extensions install`. **Kiro** (IDE, CLI on both engines, Crew) has no
plugin CLI either: the bridge is copied to `~/.rogue/plugins/kiro` — outside every
Kiro path — and the installer writes the files that point Kiro at it
(`~/.kiro/hooks/rogue.json`, two Crew wrappers beside it, a hooks block merged
into every custom agent config, and a `rogue` agent that becomes the CLI default
only when none was set; see `plugins/kiro/README.md`). The installer validates
and writes your API key, confirms your actor identity, and on macOS/Linux
configures a `Rogue Security` status badge below the Claude prompt
(🟢 connected / 🔴 not set up).

On macOS, Linux, and WSL, `install.sh` requires Node.js to merge Kiro CLI 2.x agent hooks. Without Node.js, the installer skips those hooks and CLI 2.x sessions are not covered. Install Node.js and re-run the installer. The Windows `install.ps1` merge uses PowerShell and does not require Node.js.

To target specific agents instead of all detected ones, pass `--claude`, `--codex`,
`--cursor`, `--gemini`, `--copilot`, `--antigravity`, `--kiro` and/or `--cortex` (PowerShell:
`-Claude` / `-Codex` / `-Cursor` / `-Gemini` / `-Copilot` / `-Antigravity` / `-Kiro`; Cortex Code
has no Windows bridge):

```bash
curl -fsSL https://raw.githubusercontent.com/qualifire-dev/rogue-plugins/main/install.sh | bash -s -- --cursor
```

For org-wide Cursor rollout, import this repo as a Cursor **Team Marketplace**
(Dashboard → marketplaces) — that is Cursor's native managed/auto-update path, separate
from the per-developer one-liner above.

Native Windows support requires no WSL or Git Bash: every hook ships both a POSIX
`sh` script and a PowerShell sibling, and exactly one runs per machine.

Manual install (inside Claude Code v2.1+):

```
/plugin marketplace add qualifire-dev/rogue-plugins
/plugin install rogue@rogue-marketplace
/rogue:setup
```

Get an API key at <https://app.rogue.security/settings/api-keys>.

## What it ships

```
.claude-plugin/plugin.json   — plugin manifest
hooks/hooks.json             — 11 lifecycle hooks; each fires an sh + a PowerShell entry
skills/setup/SKILL.md        — /rogue:setup slash command
skills/status/SKILL.md       — /rogue:status slash command
scripts/hook.sh              — POSIX-sh + curl dispatcher (macOS/Linux/WSL)
scripts/hook.ps1             — PowerShell dispatcher (native Windows)
scripts/setup.sh / setup.ps1 — credential storage helpers
```

### Hooks covered

`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`,
`PostToolUseFailure`, `PermissionRequest`, `Stop`, `SessionEnd`,
`SubagentStart`, `SubagentStop`, `ConfigChange`.

All hooks are `type: "command"`. Each event registers **two** entries — a POSIX
`sh` one (`hook.sh`, for macOS/Linux/WSL) and a PowerShell one (`hook.ps1`, for
native Windows) — and exactly one does real work per machine (`hook.sh` stands
down under Git Bash so the PowerShell entry owns Windows). They read one env file
at runtime — the first of `/etc/rogue/env` / `C:\ProgramData\rogue\env` (MDM),
`${CLAUDE_PLUGIN_ROOT}/env` (bundled), and `~/.rogue-env` /
`%USERPROFILE%\.rogue-env` (per-user) that holds `ROGUE_API_KEY` — then POST the
event payload to
`https://api.rogue.security/api/v1/hooks/claude`.

If `ROGUE_API_KEY` is empty, hooks return `{}` (allow) — fail-open by design,
so Claude Code never hangs on Rogue infrastructure issues.

## Slash commands

| Command | Purpose |
| ------- | ------- |
| `/rogue:setup` | Walks through API-key entry, identity detection, and credential storage |
| `/rogue:status` | Pings the API, fetches active rulesets, shows mode + actor identity |

## Credentials

Credentials live in **one file**: `~/.rogue-env` (mode `600`). Hooks source it
on every fire — no shell-rc patching, no environment leakage to other tools.

```
export ROGUE_API_KEY=rsk_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
export ROGUE_ACTOR_EMAIL=you@company.com
export ROGUE_ACTOR_NAME='Your Name'
```

System-wide MDM deployment can drop the same exports into `/etc/rogue/env` —
hooks check that path first, and when it holds `ROGUE_API_KEY` they read no other
file. Values in the file in use override the process environment.

When the file in use carries no `ROGUE_ACTOR_*`, every hook resolves the actor
at fire time: `user.email` / `user.name` from
`${XDG_CONFIG_HOME:-~/.config}/git/config` then `~/.gitconfig` (read as files;
`git` itself is never run), then `<login>@<hostname>`. Every level is set by
the local user, so the actor is a self-reported label: authoritative
attribution is the API key's organization and the enrolled endpoint.

To revoke: `rm ~/.rogue-env` (per-user) or `sudo rm /etc/rogue/env` (MDM).

## False positive escape hatch

Prepend `rgx!` to any prompt to allow it through and mark the previous
detection as a false positive in the dashboard. Per-prompt only.

## Dashboard

<https://app.rogue.security/aidr>

## Requirements

- Claude Code v2.1+
- **macOS / Linux / WSL:** POSIX `sh` and `curl` on `PATH` (both present by default)
- **Windows:** PowerShell 5.1+ (built in). No WSL or Git Bash required — the
  PowerShell dispatcher uses `Invoke-WebRequest`. `git` is needed for the
  installer (Claude clones the marketplace).

## License

Proprietary. Copyright © Qualifire, Inc. All rights reserved. See [`LICENSE`](./LICENSE).

## Muse Code

The Muse bridge needs only bash and curl on macOS or Linux, or Windows PowerShell on Windows; it does not need Node.js, jq or Python. Install with `bash install.sh --muse` or `install.ps1 -Muse` after publishing the `rogue-plugin-muse.tar.gz` asset. From a checkout, `bash plugins/muse/scripts/install.sh` (or `install.ps1`) installs the local bundle; configure the existing trusted Rogue credential file first.

Rogue's hooks live in a Rogue-owned managed hooks file, `~/.rogue/plugins/muse/hooks.json`. The installer adds a single `managed_hooks_path` line to Muse's `settings.json` and changes nothing else. It refuses to replace a managed hooks path another tool already set, rejects settings that are not a JSON object, keeps a private backup and refuses concurrent runs. Start a new Muse session afterward. Check the wiring with `install.sh --status`. To uninstall, run `bash ~/.rogue/plugins/muse/scripts/install.sh --uninstall`; it removes the hooks file and Rogue's pointer, and keeps credentials.

Prompts, tool calls and permission requests can be denied. Post-tool denies stop further work after the tool has run. Stop and SubagentStop are audit-only. The HTTP bridge fails open after five seconds or on error responses, and Muse ignores output it cannot parse, all beneath Muse's six-second hook timeout. Native Muse 1.4.3 behavior was verified on macOS, and Muse 1.4.8 loaded the managed hooks file and enforced a prompt block. The Windows bridge is tested under PowerShell 7 on Linux; native Windows Muse and Linux native parity remain unverified. Logs are stored in `~/.rogue/logs/muse.log` and shipped through the existing hook-log transport.

## Snowflake Cortex Code

The Cortex Code bridge needs only bash and curl on macOS or Linux; native Windows is not supported yet. Install with `bash install.sh --cortex` after publishing the `rogue-plugin-cortex.tar.gz` asset. From a checkout, `bash plugins/cortex/scripts/install.sh` installs the local bundle; configure the existing trusted Rogue credential file first.

One install covers the Cortex Code CLI and the Desktop app. Both auto-load every plugin under `~/.snowflake/cortex/plugins/` (or `$CORTEX_HOME`, then `$SNOWFLAKE_HOME/cortex`), so the installer copies the bridge to `plugins/rogue-security` there and edits no settings file. It swaps the folder in from a staged copy, keeps the bridge's `env` file across reinstalls and refuses concurrent runs. Start a new Cortex Code session afterward. Check the install with `install.sh --status`. To uninstall, run `bash ~/.snowflake/cortex/plugins/rogue-security/scripts/install.sh --uninstall`; it removes only the plugin folder, including a key stored in the bridge's own `env` file, and keeps `~/.rogue-env` and `/etc/rogue/env`.

Cortex Code uses Claude Code's hook protocol, so events go to `/api/v1/hooks/cortex`. Prompts, tool calls (including Snowflake SQL) and permission requests can be denied. Post-tool denies end the turn after the tool has run. Stop and SubagentStop are audit-only. Each hook has a ten-second Cortex Code timeout; the bridge's request stops after eight seconds and fails open on errors and on responses that are not JSON objects. Cortex Code runs no hooks when `disableAllHooks` is set, and in sandbox mode it skips hooks outside the project directory. Cortex Code CLI 1.2.41 and Desktop 1.25.4 were verified on macOS for prompt blocks and session events; tool-call denies are covered by API tests but have not been tested in a live model turn. Logs are stored in `~/.rogue/logs/cortex.log` and shipped through the existing hook-log transport.

## Grok Bot

Grok Bot needs no install. A Cursor team admin points the team's Grok Bot inference hooks at `https://api.rogue.security/api/v1/hooks/grok-bot` with an `X-Rogue-Api-Key` header. See [`plugins/grok-bot/README.md`](./plugins/grok-bot/README.md).
