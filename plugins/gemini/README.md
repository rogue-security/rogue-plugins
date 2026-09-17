# Rogue Security — Gemini CLI extension

Real-time AI agent detection and response (AIDR) for [Gemini CLI](https://geminicli.com).

This extension routes Gemini CLI hook events through the Rogue Security
evaluation pipeline. Prompts, tool calls (including MCP), tool results, and the
final model response are evaluated against your organization's active rulesets;
a blocking verdict stops the action with a structured `decision`/`reason` that
Gemini renders natively.

## What it monitors

The extension registers these Gemini CLI hook events:

| Event | Evaluated | Blocks | Notes |
|-------|:---------:|:------:|-------|
| `BeforeAgent` | ✅ | ✅ | the user prompt |
| `BeforeTool` | ✅ | ✅ | tool calls — **MCP calls ride here** (`mcp_context`) |
| `AfterTool` | ✅ | ✅ | tool results — **MCP results ride here** |
| `AfterAgent` | ✅ | ✅ | the model's final response (fires once per turn) |
| `BeforeModel` | ✅ | — | metadata only (captures the model name) |
| `SessionStart` | — | — | fires the dashboard heartbeat; emits a setup hint if unconfigured |

`AfterModel` is intentionally **not** registered: per the Gemini hook spec it
fires once per streamed response chunk, so evaluating it would score partial /
duplicated content. The model's identity comes from `BeforeModel` and its final
response from `AfterAgent`.

## Design

- **One cross-platform Node script.** Gemini CLI guarantees Node 20+ on PATH, so
  the hook (`scripts/hook.mjs`) is plain ESM using Node built-ins only — global
  `fetch`, `node:fs/os/path/child_process`. No `curl`, no `jq`, no dependencies,
  no build step, and no sh/PowerShell dual-dispatcher to keep in lockstep.
- **Pure relay.** The Rogue backend emits Gemini's native decision shapes
  (`{"decision":"deny"|"block","reason":...}`, `toolConfig.mode:"NONE"`), so the
  hook relays the response verbatim and Gemini renders the block. Fail-open: any
  missing key / network error / bad response returns `{}` (allow) and exits 0.
- **Shared credentials.** Reads `~/.rogue-env` (mode 600) from disk each
  invocation — the SAME file the Claude Code, Codex, and Cursor Rogue plugins
  use. One env file is read: the first of `/etc/rogue/env`
  (`C:\ProgramData\rogue\env` on Windows), `<ext>/env`, and `~/.rogue-env` that
  holds `ROGUE_API_KEY`.

## Install

The extension is distributed from the [`rogue-plugins`](https://github.com/qualifire-dev/rogue-plugins)
monorepo. The one-line installer detects Gemini CLI and installs it alongside
any other Rogue coding-agent plugins:

```bash
curl -fsSL https://raw.githubusercontent.com/qualifire-dev/rogue-plugins/main/install.sh | bash
```

Then, inside Gemini CLI:

1. Run `/setup` to configure your API key (or run
   `node ~/.gemini/extensions/rogue/scripts/setup.mjs "<API_KEY>" "<EMAIL>" "<NAME>"`).
2. **Trust the hooks once** — open `/hooks` and trust the Rogue entries (Gemini
   skips new/changed command hooks until reviewed).
3. Restart Gemini CLI so the hooks load.
4. Run `/status` to verify.

Upgrades: re-run the one-line installer.

## Verify

Inside Gemini CLI, run `/status`. You should see HTTP 200 against the ping
endpoint, your active rulesets, and a tail of recent hook activity
(`~/.rogue/logs/gemini.log` — each Rogue plugin logs to its own file, capped at
10 MiB with one `.1` rotation kept). `ROGUE_LOG_MAX_BYTES` overrides that cap and
`0` turns rotation off; `ROGUE_LOG_FILE` / `ROGUE_LOG_DIR` relocate the log. All
three are read from the env file in use, which overrides the process environment.

## Uninstall

```bash
gemini extensions uninstall rogue
```

Credentials in `~/.rogue-env` are left in place — they're shared with the other
Rogue plugins.
