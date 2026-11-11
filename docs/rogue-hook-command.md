# Calling rogue-hook directly from hooks.json

Spike result for FIRE-3012 (epic FIRE-3008). Release 2 deletes every bash,
PowerShell and Node script from the plugins, so each `hooks.json` must start
the native bridge at its fixed path with no script in between. A plugin ships
one hook file for every OS, so the command string has to work on macOS, Linux
and Windows.

## Result

Use **one entry per event, with the same string on every OS**:

```
~/.rogue/bin/rogue-hook <family> <Event>
```

Every shell these agents use expands `~` to the user's home and finds the
binary there:

- `sh`, `dash`, `bash`, `zsh` and Git Bash do tilde expansion. A space in the
  home path is safe, because tilde results are not split into words.
- Windows PowerShell 5.1 resolves `~` to `%USERPROFILE%` and adds `.exe` on
  its own, so on Windows the same string runs
  `%USERPROFILE%\.rogue\bin\rogue-hook.exe`. pwsh 7 also resolves `~`
  (checked on macOS only).

There is no entry for the other OS, so the wrong-OS entry cannot error, block
or double an event.

The family's shell decides whether the entry also needs a ` ; exit 0` guard:

| Family | Final command | Guard needed |
|---|---|---|
| Claude Code | `~/.rogue/bin/rogue-hook claude <Event> ; exit 0` | yes |
| Codex | `"command": "~/.rogue/bin/rogue-hook codex <Event> ; exit 0"` with no `commandWindows` | yes |
| Cursor | `~/.rogue/bin/rogue-hook cursor <event>` | no, and the guard breaks it |
| Gemini CLI | `~/.rogue/bin/rogue-hook gemini <Event> ; exit 0` | yes |

Only hook events get a foreground entry. Today's Claude heartbeat and
auto-update entries run detached (`sh -c '( nohup ... & )' ; exit 0`), and the
Claude adapter never starts a heartbeat itself. `rogue-hook heartbeat` is
synchronous: a beacon POST with a 10s timeout, then log shipping, then an
update check that can wait on `install.sh` for up to 60s. As a foreground
SessionStart entry it would hold every session start for up to the hook
timeout, and the agent can kill it while the installer runs. A shell detach
cannot be written once for sh and PowerShell, so no release-2 plugin may list
`rogue-hook heartbeat` or any other background job as an entry. That work
moves into the binary: FIRE-3010 drops the heartbeat, and FIRE-3011 and
FIRE-3013 run log shipping and updates on the binary's own timer. Until those
land, the binary must detach any such work itself (`spawn_self`) and return at
once.

## Which shell runs the command

Each cell was observed by a stub `rogue-hook` that logs its argv, its stdin
size and its parent process command line. Cells marked "code" were read from
the agent's own bundle, and the exact spawn string was then replayed.

| Family | macOS | Linux | Windows |
|---|---|---|---|
| Claude Code | `/bin/sh -c` | `/bin/sh -c` (dash) | Git Bash `bash.exe -c`; `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command` when Git Bash is missing, or with `"shell": "powershell"` |
| Codex | `$SHELL -c` (zsh here) | `$SHELL -c` | `powershell.exe -NoProfile -Command`, using `commandWindows` if set and `command` otherwise |
| Cursor desktop (code) | `$SHELL -c`, payload on stdin | `$SHELL -c`, payload on stdin | pwsh, or else `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -c`, payload piped in from a temp file: `Get-Content ... \| & { $input \| <command> }` |
| Cursor CLI (code) | `$SHELL -c "<command> <<'CURSOR_HOOK_EOF' ..."` (payload in a heredoc), or the bare command with the payload on stdin when the `hooks_stdin_transport` flag is on | same | not checked |
| Gemini CLI | `bash -c` | `bash -c` (code) | `%ComSpec%` if it is PowerShell, else pwsh, else `powershell.exe -NoProfile -NonInteractive -Command` (code) |

## Why one entry and not two

Today every plugin has an `sh` entry and a `powershell` entry, and the
scripts stand down on the wrong OS. Once the scripts are gone, nothing stands
down. The tests showed what the second entry does then:

- **Claude, macOS and Linux:** `"%USERPROFILE%\...\rogue-hook.exe"` fails
  (exit 1 `fg: no job control` in macOS sh, exit 127 `not found` in dash).
  `"shell": "powershell"` runs pwsh when it is installed and fails, or cannot
  start without it. Each one shows a `hook error` notice.
- **Claude, Windows:** Git Bash runs both entries. The `%USERPROFILE%` entry
  fails there, and a `$HOME/...` entry would run the same `.exe` twice. Without
  Git Bash, a failing `PreToolUse` or `PermissionRequest` entry **blocks the
  tool call**.
- **Gemini:** the PowerShell entry is a bash syntax error (exit 2), and
  Gemini **blocked the whole agent turn** (`Agent execution blocked`).
- **Codex:** `commandWindows` makes a second entry unnecessary. On Windows it
  runs in PowerShell, not `cmd`, so a `%USERPROFILE%` form does not expand,
  while `~/...` works with or without `commandWindows`.

## Why the guard, and why not for Cursor

The binary exits 0 on every path and blocks through JSON on stdout, so
` ; exit 0` only matters when the binary is missing or cannot start:

- **Claude:** a missing binary exits 127 and shows a `hook error` notice.
  On Windows without Git Bash it blocks `PreToolUse`. With the guard the
  outcome is `success`, tested in sh, Git Bash and PowerShell.
- **Gemini:** a missing binary exits 127, and Gemini treats any exit other
  than 0 or 1 as deny, so the agent turn is blocked. With the guard the turn
  ran normally. On PowerShell, Gemini appends its own
  `; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }`, which comes after the
  guard and does no harm.
- **Codex:** a missing binary is reported as a failed hook and Codex carries
  on. The guard keeps the failure silent.
- **Cursor:** the CLI appends the payload as a heredoc to the end of the
  command, so with the guard the heredoc feeds `exit 0` and the binary gets
  0 bytes of stdin. Cursor fails open on a non-zero exit and does not show
  hook errors in chat, so the bare command is correct.

The guard rules out exit-code verdicts, so never add it for a family that
denies with an exit code. Kiro is one (see `rogue-hook/src/cli.rs`).

Cursor CLI 2026.07.23 (`3143.index.js`) also contains a PowerShell
here-string form (`@'...'@ | & <command>`) and a `windows_temp_file` form, but
neither can run in that build: the here-string branch sits behind a constant
`false`, and the transport mode is only ever `stdin` or `argv_heredoc`. Both
reachable modes were replayed with the bare command in zsh, bash, sh and pwsh
on macOS. The heredoc mode is a parse error in pwsh whatever the command is,
so a Windows CLI that runs hooks in PowerShell must be using stdin mode.

## Requirements for the binary

- On Windows the launcher must be named `rogue-hook.exe`. PowerShell and Git
  Bash only find it by adding `.exe`.
- Read the whole of stdin and tolerate a UTF-8 BOM and a trailing CRLF. The
  Cursor Windows wrapper and PowerShell pipes add the CRLF.
- Keep blocking in the JSON answer with exit 0, because the guard hides exit
  codes.
- Return from SessionStart right away. Any background work (heartbeat, log
  shipping, update) must be detached by the binary, never by the entry.

## Rejected options

- **Exec form (Claude `args`):** no shell, so `~`, `$HOME` and `${HOME}` are
  passed through literally and the spawn fails with `ENOENT` on every OS.
  Only `${CLAUDE_PLUGIN_ROOT}`-style placeholders are substituted.
- **`"$HOME/.rogue/bin/rogue-hook"`:** works in sh, bash, zsh and Git Bash,
  but it is a parse error in PowerShell (Codex and Cursor on Windows, Claude
  without Git Bash).
- **`"%USERPROFILE%\.rogue\bin\rogue-hook.exe"`:** only `cmd.exe` expands it,
  and none of the tested families uses `cmd`.
- **`& "$env:USERPROFILE\.rogue\bin\rogue-hook.exe"`:** PowerShell only.

## Caveats

- **Known limit: the user controls `~`.** Every entry finds the binary
  through `~`, which the shell expands from the agent's `HOME` (or
  `%USERPROFILE%`), and the user sets that variable. Git Bash uses an explicit
  `HOME` and falls back to `%USERPROFILE%`. PowerShell 5.1 ignores
  `HOMEDRIVE` and `HOMEPATH` and uses `%USERPROFILE%`. A user who starts the
  agent with another home, for example `HOME=/tmp/x claude`, gets a missing
  binary (exit 127), the guard turns that into success, and `PreToolUse` runs
  with no Rogue check. This holds even when the hooks come from managed
  settings, which do not depend on `HOME`. The protected binary is untouched,
  so anti-tamper sees nothing, and the only signal is that the backend stops
  getting events from that session. Do not install a second launcher under
  `$HOME` to work around it: that adds a path anti-tamper does not protect.
- Cursor desktop also loads Claude plugins (`claude-plugin` source, with
  `${CLAUDE_PLUGIN_ROOT}` substituted). So a machine with both agents can run
  `rogue-hook claude ...` from inside Cursor. Scripts behave the same way
  today, so this is not new with the binary.

## Coverage

| Family | macOS | Linux | Windows |
|---|---|---|---|
| Claude Code | real run, 2.1.322 | real run in a `node:22-bookworm` container, 2.1.322 | real run, 2.1.289, Git Bash and `"shell": "powershell"` |
| Codex | real run, 0.166.0 | real run in container, 0.167.1 | real run, 0.165.0 |
| Cursor | not run; spawn forms replayed from Cursor 3.28.7 and CLI 2026.07.23 (heredoc and stdin modes) in zsh, bash, sh and pwsh | not run; replayed in bash and dash | not run; desktop wrapper replayed in PowerShell 5.1, CLI not checked |
| Gemini CLI | real run, 0.58.0 | not run (code: `bash -c`) | not run (code: PowerShell) |

Real runs covered SessionStart, UserPromptSubmit, PreToolUse and Stop
(Gemini: SessionStart, BeforeAgent, BeforeTool, AfterAgent).

**Open: the acceptance criterion "each command string is tested on macOS,
Windows and Linux" is not met for Cursor**, the second-largest family. Every
Cursor cell is a replayed spawn string, not a real agent run, and the CLI on
Windows was not checked at all. The Cursor command stays provisional until a
real run on each OS confirms the shell, the transport, the cwd and the
environment (`buildHookEnvironment`). Cursor fails open and shows no hook
errors, so a mismatch would leave installs unprotected with nothing to signal
it. Release 2 must not ship the Cursor entry before those runs.

Not tested:

- No real Cursor agent run. The CLI on this Mac is not signed in
  (`cursor-agent status` claims a login, but every request returns
  `Authentication required`), and the desktop app on the Windows lab needs a
  GUI session.
- Claude on Windows with Git Bash really uninstalled. PowerShell was forced
  with `"shell": "powershell"`, which runs the same string through the same
  PowerShell, but the blocking-without-Git-Bash rule was taken from the
  Claude Code docs and not reproduced.
- Antigravity, Kiro, Copilot and Muse. Their hook shells still need the same
  check before release 2. Kiro also denies with an exit code, so it must not
  get the guard.
