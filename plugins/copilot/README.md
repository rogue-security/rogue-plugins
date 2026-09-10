# Rogue Security AIDR — GitHub Copilot CLI plugin

Real-time AI agent detection and response for **GitHub Copilot CLI**. Observes
every lifecycle event and POSTs it to the Rogue backend
(`https://api.rogue.security/api/v1/hooks/copilot`) for prompt-injection,
secret-exfiltration, and destructive-command detection. Risky tool calls are
**denied** at `preToolUse` before they execute.

## What ships

- **`hooks.json`** — registers `sessionStart`, `userPromptSubmitted`,
  `preToolUse`, and `postToolUse`. Copilot runs the `bash` command on
  macOS/Linux and the `powershell` command on Windows, so exactly one dispatcher
  runs per platform (no arbitration needed).
- **`scripts/hook.sh` / `scripts/hook.ps1`** — the dual dispatcher. Pure relay:
  POSTs the event and relays the backend's native Copilot decision verbatim
  (`{"permissionDecision":"deny",...}` at `preToolUse`). Always exits 0 — Copilot's
  `preToolUse` is fail-closed, so a dead dispatcher must fail *open*, never deny.
- **`scripts/setup.sh` / `setup.ps1`** — write the shared `~/.rogue-env` (mode 600).
- **`scripts/heartbeat.sh` / `heartbeat.ps1`** — detached presence beacon.
- **`commands/setup.md`** (`/rogue:setup`) and **`skills/status/SKILL.md`**
  (`/rogue:status`).

## Runtime

Copilot CLI is a compiled binary with **no guaranteed Node runtime**, so this
plugin uses the **bash + PowerShell dual dispatcher** (like the Claude/Codex/Cursor
plugins), not the single-Node model used for Gemini CLI. On Windows, Copilot
prefers PowerShell 7+ but falls back to Windows PowerShell 5.1 — `hook.ps1` stays
5.1-compatible.

## JetBrains

Rogue covers JetBrains through Copilot's **CLI/Agent** provider, which embeds the
same hook engine as the terminal CLI (`copilot-language-server` reads
`~/.copilot/installed-plugins`, so the plugin you installed above is already
active — there is no separate IDE-side install).

> ⚠️ **Select the CLI/Agent provider.** With the IDE's built-in **Local** agent
> selected, the IDE runs its *own* hook engine, which reads only
> `<git-root>/.github/hooks/**/*.json`, supports 4 events, discards hook
> decisions, and refuses plugin-provided hooks outright ("Refusing to execute
> hook from untrusted workspace folder"). That means **zero Rogue coverage** —
> nothing is observed and nothing can be blocked. `/rogue:status` is unreachable
> there too, so there is no in-IDE warning we can show you.

**Blocked-prompt alert.** JetBrains honors a blocked prompt but renders nothing
for it — the chat simply goes dead, with no reason and no hint about the `rgx!`
override. So on that one case the dispatcher also shows a local desktop alert
carrying the reason (`display alert` on macOS, `notify-send` on Linux,
`WScript.Shell.Popup` on Windows). It is the only thing either dispatcher ever
does beyond relaying the backend's response, and it is scoped tightly: prompt
blocks only, JetBrains only — every other decision (a denied tool call, a
withheld tool result, a blocked reply) already renders natively in both the IDE
and the terminal, and never alerts.

Set `ROGUE_IDE_ALERT=0` in `~/.rogue-env` to turn the alert off. Blocks are still
enforced — they just become invisible in JetBrains again.

## Install

```
copilot plugin marketplace add qualifire-dev/rogue-plugins
copilot plugin install rogue@rogue-copilot
```

Then run `/rogue:setup`, open `/hooks` to **trust** the Rogue entries once, restart
Copilot CLI, and run `/rogue:status` to verify.

## Credentials

Shared `~/.rogue-env` (mode 600), read from disk at each invocation. One env file
is used: the first of `/etc/rogue/env` (`C:\ProgramData\rogue\env`),
`${PLUGIN_ROOT}/env`, and `~/.rogue-env` that holds `ROGUE_API_KEY`. The same file
is used by every Rogue plugin.
