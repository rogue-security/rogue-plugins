# Rogue Security AIDR — Google Antigravity plugin

Real-time AI agent detection and response (AIDR) for [Google Antigravity](https://antigravity.google)
(IDE 2.0 + the `agy` CLI). Observes every Antigravity lifecycle event and POSTs
it to the Rogue backend (`https://api.rogue.security/api/v1/hooks/antigravity`)
for prompt-injection, secret-exfiltration, and destructive-command detection.
Risky tool/shell/MCP calls are **denied** at `PreToolUse` before they execute;
a flagged model turn is terminated at `PostInvocation`.

## What it monitors

| Event | Evaluated | Blocks | Notes |
|-------|:---------:|:------:|-------|
| `PreToolUse` | ✅ | ✅ | tool/shell/MCP calls — denies before execution |
| `PostToolUse` | ✅ | — | tool/shell/MCP results |
| `PreInvocation` | ✅ | — | the user prompt / model invocation |
| `PostInvocation` | ✅ | ✅ | the model's turn — terminates it if flagged |
| `Stop` | ✅ | — | end of an agent run (payload carries `executionNum`; can fire more than once per session) |

## Design

- **Dual sh + PowerShell dispatcher** (`scripts/hook.sh` / `scripts/hook.ps1`),
  registered as two handlers per event so exactly one does real work per
  machine — the same arbitration used by the Claude, Codex, and Cursor
  plugins.
- **Pure relay.** The Rogue backend emits Antigravity's native decision shape
  per event; the dispatcher relays the response body verbatim and always
  exits 0. Fail-open on missing key / network error / non-200 / bad body:
  `PreToolUse` falls back to `{"decision":"allow"}`, every other event falls
  back to `{}`.
- **Shared credentials.** Reads `~/.rogue-env` (mode 600) from disk each
  invocation — the SAME file used by the Claude Code, Codex, Cursor, and
  Gemini CLI Rogue plugins. One env file is read: the first of `/etc/rogue/env`
  (`C:\ProgramData\rogue\env` on Windows), `<plugin-root>/env`, and
  `~/.rogue-env` that holds `ROGUE_API_KEY`.
- **Version** lives in the bundled `VERSION` file at the plugin root (the
  Antigravity `plugin.json` schema has no `version` field).

## Install

The plugin is distributed from the [`rogue-plugins`](https://github.com/qualifire-dev/rogue-plugins)
monorepo. The one-line installer detects Antigravity and installs it alongside
any other Rogue coding-agent plugins:

```bash
curl -fsSL https://raw.githubusercontent.com/qualifire-dev/rogue-plugins/main/install.sh | bash
```

This copies the plugin into `~/.gemini/config/plugins/rogue` (the directory
Antigravity IDE reads its plugins from), and — when the `agy` CLI is present —
also registers it via:

```bash
agy plugin install ~/.gemini/config/plugins/rogue
```

Then, inside Antigravity (IDE or `agy` CLI):

1. Run `/setup` to configure your API key (writes the shared `~/.rogue-env`).
2. Restart Antigravity so the hooks load.
3. Run `/status` to verify.

Upgrades: re-run the one-line installer.

## Verify

Run `/status`. You should see HTTP 200 against the ping endpoint, your active
rulesets, and a tail of recent hook activity (`~/.rogue/logs/antigravity.log` —
each Rogue plugin logs to its own file, capped at 10 MiB with one `.1` rotation
kept). `ROGUE_LOG_MAX_BYTES` overrides that cap and `0` turns rotation off;
`ROGUE_LOG_FILE` / `ROGUE_LOG_DIR` relocate the log. All three are read from the
env file in use, which overrides the process environment.

## Uninstall

Remove `~/.gemini/config/plugins/rogue` (and, if installed via the CLI,
`agy plugin uninstall rogue`). Credentials in `~/.rogue-env` are left in
place — they're shared with the other Rogue plugins.
