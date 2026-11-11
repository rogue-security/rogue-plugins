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

The same rules apply to the other SessionStart entries, for example
`~/.rogue/bin/rogue-hook heartbeat claude ; exit 0`.

## Which shell runs the command

Each cell was observed by a stub `rogue-hook` that logs its argv, its stdin
size and its parent process command line. Cells marked "code" were read from
the agent's own bundle, and the exact spawn string was then replayed.

| Family | macOS | Linux | Windows |
|---|---|---|---|
| Claude Code | `/bin/sh -c` | `/bin/sh -c` (dash) | Git Bash `bash.exe -c`; `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command` when Git Bash is missing, or with `"shell": "powershell"` |
| Codex | `$SHELL -c` (zsh here) | `$SHELL -c` | `powershell.exe -NoProfile -Command`, using `commandWindows` if set and `command` otherwise |
| Cursor desktop (code) | `$SHELL -c`, payload on stdin | `$SHELL -c`, payload on stdin | pwsh, or else `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -c`, payload piped in from a temp file: `Get-Content ... \| & { $input \| <command> }` |
| Cursor CLI (code) | `$SHELL -c "<command> <<'CURSOR_HOOK_EOF' ..."` (payload in a heredoc) | same | not checked |
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

## Requirements for the binary

- On Windows the launcher must be named `rogue-hook.exe`. PowerShell and Git
  Bash only find it by adding `.exe`.
- Read the whole of stdin and tolerate a UTF-8 BOM and a trailing CRLF. The
  Cursor Windows wrapper and PowerShell pipes add the CRLF.
- Keep blocking in the JSON answer with exit 0, because the guard hides exit
  codes.

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

- Git Bash uses an explicit `HOME` environment variable for `~`. Without one
  it uses `%USERPROFILE%`. PowerShell 5.1 ignores `HOMEDRIVE` and `HOMEPATH`
  and also uses `%USERPROFILE%`. A Windows user who sets `HOME` to another
  folder sends Claude (under Git Bash) to the wrong path. If that matters,
  the installer can also place the launcher under `$HOME`.
- Cursor desktop also loads Claude plugins (`claude-plugin` source, with
  `${CLAUDE_PLUGIN_ROOT}` substituted). So a machine with both agents can run
  `rogue-hook claude ...` from inside Cursor. Scripts behave the same way
  today, so this is not new with the binary.

## Coverage

| Family | macOS | Linux | Windows |
|---|---|---|---|
| Claude Code | real run, 2.1.322 | real run in a `node:22-bookworm` container, 2.1.322 | real run, 2.1.289, Git Bash and `"shell": "powershell"` |
| Codex | real run, 0.166.0 | real run in container, 0.167.1 | real run, 0.165.0 |
| Cursor | spawn forms replayed from Cursor 3.28.7 and CLI 2026.07.23 in zsh, bash and sh | replayed in bash and dash | desktop wrapper replayed in PowerShell 5.1 |
| Gemini CLI | real run, 0.58.0 | not run (code: `bash -c`) | not run (code: PowerShell) |

Real runs covered SessionStart, UserPromptSubmit, PreToolUse and Stop
(Gemini: SessionStart, BeforeAgent, BeforeTool, AfterAgent).

Not tested:

- No real Cursor agent run. The CLI on this Mac is not signed in, and the
  desktop app on the Windows lab needs a GUI session.
- Claude on Windows with Git Bash really uninstalled. PowerShell was forced
  with `"shell": "powershell"`, which runs the same string through the same
  PowerShell, but the blocking-without-Git-Bash rule was taken from the
  Claude Code docs and not reproduced.
- Antigravity, Kiro, Copilot and Muse. Their hook shells still need the same
  check before release 2. Kiro also denies with an exit code, so it must not
  get the guard.
