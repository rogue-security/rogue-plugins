# Rogue Security plugin for Kiro

Real-time AI agent detection and response (AIDR) for Kiro — the IDE, the CLI
(2.x and 3.0 engines) and Kiro Crew. One family, `kiro`; three surfaces,
`kiro_ide`, `kiro_cli`, `kiro_crew`.

Installed by `install.sh --kiro` under `~/.rogue/plugins/kiro/` — outside every
Kiro path, so a Kiro upgrade or a `.kiro/` reset never removes it. The installer
writes the hook files that point Kiro at the bridge; this directory holds the
bridge and its helpers.

## The bridge

```
scripts/hook.sh  <hookEvent> <surface>      # macOS / Linux
scripts/hook.ps1 <hookEvent> <surface>      # Windows (Windows PowerShell 5.1+)
```

A Kiro hook runs the bridge with the event JSON on stdin. The bridge POSTs it to
`/api/v1/hooks/kiro` (`x-rogue-event` = the canonical hook event,
`x-rogue-agent` = the surface, plus the API key, actor and install-identity
headers every plugin sends) and answers in Kiro's native form:

| Rogue decision | PreToolUse | UserPromptSubmit | Stop, every other event |
| --- | --- | --- | --- |
| allow | exit 0, no output | exit 0, no output | exit 0, no output |
| block | **exit 2**, reason on stderr, empty stdout | exit 0, `{"decision":"block","reason":…}` on stdout | exit 0, no output — a block on Stop would tell Kiro to keep working |

Any error — no API key, network failure, timeout, non-200, empty body — is
exit 0 with an empty stdout. `ROGUE_HOOK_TIMEOUT` (seconds, default 8) caps the
request under the hook file's 10s.

Both engines' dialects are accepted: the 2.x camelCase trigger names
(`agentSpawn`, `preToolUse`, `stop`, …) are sent as their canonical PascalCase
event, and when a 2.x body carries no `session_id` the bridge copies
`KIRO_SESSION_ID` from the hook's environment into it.

One line per event lands in `~/.rogue/logs/kiro.log`
(`provider=kiro surface=<surface> event=<Event> outcome=… http=… rc=… raw=…`),
see `docs/hook-log-format.md`. The shared shipper (`scripts/ship-logs.sh` /
`.ps1`, a byte-identical copy of `scripts/shared/`) uploads it in the
background, and knows `kiro` as one of the per-agent logs its support form
collects.

## Roster heartbeat

`scripts/heartbeat.sh <surface> <trigger>` (`heartbeat.ps1` on Windows) is
spawned detached by the bridge on `SessionStart` (unthrottled) and on every
`Stop` (throttled by the shared `scripts/beacon.sh`). It POSTs
`/api/v1/hooks/status` so this install shows up in the Coding Agents roster,
then runs the log shipper. The body is built by one function that the status
script reuses - `rogue_kiro_status_body` in `scripts/kiro-host.sh`,
`Get-StatusBody` in `heartbeat.ps1` - because the backend fingerprints the row
on host, actor, family and agent, and a second copy of the fields is a second
chance to open a second row for one install:

| field | value | from | stored by the roster today |
| --- | --- | --- | --- |
| `agent_family` | `kiro` | fixed | yes |
| `agent` | the surface argument (`kiro_ide` / `kiro_cli` / `kiro_crew`) | the hook file the event came through | yes, part of the row's fingerprint |
| `version` | this plugin's version | `plugin.json`, via `scripts/install-id.sh` | yes, drives the "outdated" badge |
| `host`, `actor_email`, `actor_name` | the install identity | `install-id.sh`, `actor.sh` | yes, the rest of the fingerprint |
| `agent_version` | the Kiro build the surface runs under | `scripts/kiro-host.sh`: `kiro-cli --version` for the CLI and Crew, the app bundle (`Info.plist`, or the install's `package.json` on Windows) for the IDE | **no** |
| `default_agent` | the CLI's `chat.defaultAgent`; **omitted** when none is set or off the CLI | `kiro-host.sh`: `kiro-cli settings chat.defaultAgent` | **no** |

`agent_version` and `default_agent` are sent ahead of the backend. The
`/hooks/status` schema in rogue-aidr-api (`StatusBodySchema`) lists neither,
and unknown body fields are stripped rather than rejected, so the POST lands
and the two values are dropped on arrival: the roster does not show the Kiro
build or the CLI default agent yet. Until the backend half (schema, a column
on `coding_agent`, the roster UI) ships in the monorepo, `status.sh` /
`status.ps1` on the machine is where both are visible. They are sent now
rather than later because the contract is the interesting part: `agent_version`
is what support needs when a Kiro release changes hook behaviour, and on the
2.x engine only agents that carry the Rogue hooks are covered (ADR 0001), so a
`default_agent` that moved away from `rogue` is an uncovered machine.

## Status

Kiro has no slash-command surface for a `/rogue:status` skill, so the status
command is a script:

```
sh ~/.rogue/plugins/kiro/scripts/status.sh
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.rogue\plugins\kiro\scripts\status.ps1"
```

It reports the credential sources and the resolved key (last four characters),
the installed surfaces with their Kiro builds, the hook wiring the installer
wrote (hook file, Crew wrappers, agent configs carrying the hooks, the 2.x
default agent and whether it is covered), the `/hooks/status` check (HTTP code,
organisation, running vs latest plugin version) and the last 20 lines of
`kiro.log`. It posts the heartbeat's own body, resolved through the same
helpers, so it refreshes the install's roster row rather than opening a second
one. Exit 0 when configured and the API answered 200, 1 otherwise, so a managed
rollout can verify a machine from a script.

## What the installer writes

`install.sh --kiro` (auto-detected from `kiro-cli`, `/Applications/Kiro.app` or
`~/.kiro`; `install.ps1 -Kiro` on Windows) wires one bridge into every surface.
Re-running upgrades in place: the bridge is replaced, its own `rogue-*` hook
entries are replaced, everything else is kept.

| Path | Read by | Surface | Notes |
| --- | --- | --- | --- |
| `~/.rogue/plugins/kiro/` | the hooks below | — | the bridge and its helpers, outside every Kiro path |
| `~/.kiro/hooks/rogue.json` | IDE 1.x, CLI 3.0 engine | `kiro_ide` | universal v1: `{version:"v1", hooks:[{name, trigger, action:{type:"command", command}, timeout:10}]}`, all eight monitored events, **no matcher** (`*` is an invalid regex there and the file fails to load) |
| `~/.kiro/hooks/rogue-crew-{pre,post}.sh` | Kiro Crew | `kiro_crew` | executable wrappers Crew imports by their `# event:` header — absolute path, no shell metacharacters (macOS/Linux only) |
| `~/.kiro/agents/*.json`, `./.kiro/agents/*.json` | CLI 2.x engine (the default) | `kiro_cli` | a `hooks` array in the same form, merged beside the user's own entries; a file that does not parse, or whose `hooks` is not an array, is skipped with a warning |
| `~/.kiro/agents/rogue.json` | CLI 2.x engine | `kiro_cli` | created with `kiro-cli agent create --name rogue` (Kiro's defaults + the hooks) and made the default with `kiro-cli agent set-default rogue` **only when `kiro-cli settings chat.defaultAgent` reports none**; a default the user chose is left alone and printed (ADR 0001) |

The 2.x engine's built-in default agent is not a file and cannot be shadowed, so
without the `rogue` agent a plain `kiro-cli chat` carries no hooks. `kiro-cli
agent create` refuses when the CLI is not logged in; the installer then says so,
names `kiro-cli login`, and never touches the default — it is switched only to a
`rogue.json` that exists and carries the hooks after the merge. The agent-config
merge runs on `node`; without it the hook file and the Crew wrappers are still
written and the 2.x gap is named.

Each file fixes the bridge's surface to the surface it is authoritative for: no
Kiro payload names its surface, and the IDE reads nothing but the hook file (the
prompt block is IDE-only, so that file must say `kiro_ide`). The 3.0 engine (the
IDE runs the same one) loads the hook file **and** the agent configs, so it
would run the bridge twice per event; the bridge drops the agent-hook copy — a
PascalCase `hook_event_name` arriving under a camelCase trigger can only be the
3.0 engine running a 2.x agent hook — and logs it as `outcome=duplicate`, so each
event is recorded once. The surviving copy is the hook file's, labelled
`kiro_ide`: a `kiro-cli --v3` session is therefore reported as `kiro_ide` (and
receives the IDE's prompt-block JSON, which the 3.0 CLI ignores) until the
hardware matrix (FIRE-2038) finds a run-time signal that tells the two hosts
apart. This is the one known mislabel.

## Versioning and release

`plugin.json` carries the version of record (`install-id.sh`, `hook.ps1` and
`heartbeat.ps1` read it there); `VERSION` beside it mirrors the value for
operators and the release page, and `scripts/plugin-versions.sh` refuses to
build a release while the two disagree. `release.yml` publishes the plugin as
`rogue-plugin-kiro.tar.gz` (the archive's top dir is this directory) and lists
the version in `versions.json` under slug `kiro`, which the backend maps
family `kiro` to when it decides whether a roster row is outdated.

## Credentials

One env file is read: the first of these that holds `ROGUE_API_KEY`. Its values
override the process environment on both bridges.

1. `/etc/rogue/env` (`C:\ProgramData\rogue\env`) — MDM-provisioned
2. `<root>/env` — baked into a compiled customer plugin
3. `~/.rogue-env` — per-user, written by the installer

## Tests

```
bash tests/test_hook_sh_kiro.sh            # bridge end to end against tests/mock_server.py
bash tests/test_status_kiro_sh.sh          # status.sh under a temp HOME with a fake kiro-cli and curl
sh tests/test_heartbeat_sh.sh              # beacon throttle + the kiro heartbeat body
bash tests/test_install_kiro_sh.sh         # install.sh --kiro under a temp HOME with a fake kiro-cli
pwsh tests/test_install_kiro_ps1.ps1       # the same wiring in install.ps1
TEST_SH=dash bash tests/test_hook_sh_kiro.sh
pwsh tests/test_hook_ps1_kiro.ps1          # the PowerShell bridge's decision table
sh tests/test_hook_logs.sh                 # hook-log contract, all dispatchers
```

`tests/fixtures/kiro/` holds the verbatim payload captures the suites feed the
bridge (kiro-cli 2.21.0 on both engines, Kiro IDE 1.0.437).
