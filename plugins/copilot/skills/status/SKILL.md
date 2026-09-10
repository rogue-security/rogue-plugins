---
name: status
description: Check Rogue Security AIDR connection status, active rulesets, and configuration for GitHub Copilot CLI
---

# Rogue Security Status (GitHub Copilot CLI)

Check the current status of the Rogue Security AIDR integration. The plugin hooks
read exactly one env file: the first of `/etc/rogue/env` (MDM-provisioned), the
plugin's bundled `env` (managed installs), and `~/.rogue-env` (per-user setup) that
holds `ROGUE_API_KEY`. This command applies the same rule.

The commands below are bash (macOS/Linux). **On Windows**, run the PowerShell
equivalents: read the key from `%USERPROFILE%\.rogue-env` (and
`C:\ProgramData\rogue\env` for MDM), then hit the same endpoints with
`Invoke-WebRequest` — e.g.
`Invoke-WebRequest "https://api.rogue.security/api/v1/hooks/config" -Headers @{ 'x-rogue-api-key' = $ROGUE_API_KEY } -UseBasicParsing`.

## Step 1: Source credentials and report what's found

```bash
ROGUE_ENV_IN_USE=""
# The first env file holding ROGUE_API_KEY is used alone.
for f in /etc/rogue/env "$HOME/.rogue-env"; do
  [ -n "$f" ] && [ -r "$f" ] && grep -Eq "^[[:space:]]*(export[[:space:]]+)?ROGUE_API_KEY=[\"']?[^\"'[:space:]]" "$f" && { . "$f"; ROGUE_ENV_IN_USE=$f; break; }
done
echo "Credential sources detected:"
[ -r /etc/rogue/env ]     && echo "  /etc/rogue/env  (MDM)"
[ -r "$HOME/.rogue-env" ] && echo "  $HOME/.rogue-env  (per-user)"
[ ! -r /etc/rogue/env ] && [ ! -r "$HOME/.rogue-env" ] && echo "  (none)"
for f in /etc/rogue/env "$HOME/.rogue-env"; do
  [ -n "$f" ] && [ -r "$f" ] && ! grep -Eq "^[[:space:]]*(export[[:space:]]+)?ROGUE_API_KEY=[\"']?[^\"'[:space:]]" "$f" && echo "  $f  (no ROGUE_API_KEY, not read)"
done
echo "In use: ${ROGUE_ENV_IN_USE:-(none holds ROGUE_API_KEY)}"
[ -n "$ROGUE_API_KEY" ] && echo "API key resolved: ...${ROGUE_API_KEY: -4}" || echo "API key: not resolved"
[ "${ROGUE_IDE_ALERT:-1}" = "0" ] && echo "ROGUE_IDE_ALERT=0  (JetBrains blocked-prompt alert disabled)"
```

If no sources are found OR `ROGUE_API_KEY` is empty: individual users run
`/rogue:setup`; managed users contact their security admin. Stop here in that case.

If `ROGUE_IDE_ALERT=0` is reported, mention it: in JetBrains a blocked prompt
renders nothing, so with the alert off a block looks like the chat silently dying.
Remove the line from `~/.rogue-env` to get the reason back.

## Step 2: Test connection + register heartbeat

```bash
for f in /etc/rogue/env "$HOME/.rogue-env"; do [ -r "$f" ] && grep -Eq "^[[:space:]]*(export[[:space:]]+)?ROGUE_API_KEY=[\"']?[^\"'[:space:]]" "$f" && { . "$f"; break; }; done
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
PJ="$HOME/.copilot/installed-plugins/rogue-copilot/rogue/plugin.json"
VER=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9][^"]*"' "$PJ" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
curl -s -w "\n%{http_code}" -X POST \
  "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/status" \
  -H "x-rogue-api-key: $ROGUE_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"agent_family\":\"copilot\",\"agent\":\"github_copilot\",\"version\":\"${VER:-unknown}\",\"host\":\"$(esc "$(hostname)")\",\"actor_email\":\"$(esc "${ROGUE_ACTOR_EMAIL:-}")\",\"actor_name\":\"$(esc "${ROGUE_ACTOR_NAME:-}")\"}"
```

`version` is read from `plugin.json` the same way `heartbeat.sh` reads it —
grep/sed, never `python3`, because the `/usr/bin/python3` stub fails silently on
a fresh macOS. Send it: without it the roster row has no running version, so the
server has nothing to compare against the latest release and `update_available`
is meaningless. If the file is missing, `unknown` is sent rather than the field
being dropped.

Report from the JSON response (HTTP 200 = connected): organization name, running
vs latest version, and whether `update_available` is `true`. On HTTP 401 the key
is invalid; no response → check network reachability to `api.rogue.security`.

## Step 3: Fetch configuration

```bash
for f in /etc/rogue/env "$HOME/.rogue-env"; do [ -r "$f" ] && grep -Eq "^[[:space:]]*(export[[:space:]]+)?ROGUE_API_KEY=[\"']?[^\"'[:space:]]" "$f" && { . "$f"; break; }; done
curl -s -H "x-rogue-api-key: $ROGUE_API_KEY" \
  "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/config"
```

Parse and display: **Mode** (`settings.mode`), **Fail-open** (`settings.failOpen`),
each **ruleset** in `rulesets` (name, category, mode, severity), and the Copilot
event set under `tools.github_copilot` (`monitoredEvents`, `blockingEvents`).

## Step 4: Show the recent hook log

Each Rogue plugin logs to its **own** file under `~/.rogue/logs/`, so this reads
`copilot.log` only — a sibling agent's activity lives in `claude.log`,
`cursor.log`, and so on. `<file>.1` is the previous rotation, if any.

```bash
# Same rule as the dispatcher: only the env file in use (the first holding
# ROGUE_API_KEY) is read, with the process environment for anything it does not
# set. Read with sed, never by sourcing - a status command must not execute an env
# file. Reading only $ROGUE_LOG_* would report "no activity" on exactly the
# machines that relocate their logs by policy, which are the ones support is
# called about.
ROGUE_ENV_IN_USE=""
for f in /etc/rogue/env "$HOME/.rogue-env"; do
  [ -n "$f" ] && [ -r "$f" ] && grep -Eq "^[[:space:]]*(export[[:space:]]+)?ROGUE_API_KEY=[\"']?[^\"'[:space:]]" "$f" && { ROGUE_ENV_IN_USE=$f; break; }
done
rogue_log_var() {
  v=$(sed -n "s/^[[:space:]]*\(export[[:space:]][[:space:]]*\)\{0,1\}$1=//p" \
        "${ROGUE_ENV_IN_USE:-/dev/null}" 2>/dev/null | tail -1 | sed "s/^['\"]//;s/['\"]$//")
  [ -n "$v" ] || eval "v=\${$1:-}"
  printf '%s' "$v"
}
log=$(rogue_log_var ROGUE_LOG_FILE)
if [ -z "$log" ]; then
  dir=$(rogue_log_var ROGUE_LOG_DIR)
  [ -n "$dir" ] || dir="$HOME/.rogue/logs"
  log="$dir/copilot.log"
fi
echo "Log: $log"
tail -n 20 "$log" 2>/dev/null || echo "(no hook log yet)"
```

On Windows, resolve the same precedence before reading:

```powershell
$logCfg = @{}
# Mirror the dispatcher's rule: the first of C:\ProgramData\rogue\env (MDM) and
# %USERPROFILE%\.rogue-env that holds ROGUE_API_KEY is read, with the process
# environment for anything it does not set. Parsed with a regex, never executed -
# a status command must not run an env file. Reading only $env: would report "no
# activity" on exactly the machines that relocate their logs by policy, which are
# the ones support is called about.
foreach ($f in @('C:\ProgramData\rogue\env', (Join-Path $env:USERPROFILE '.rogue-env'))) {
  if (-not (Test-Path -LiteralPath $f)) { continue }
  $fileVals = @{}
  foreach ($line in (Get-Content -LiteralPath $f)) {
    if ($line -match '^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.+)$') {
      $fileVals[$Matches[1]] = $Matches[2].Trim() -replace "^'(.*)'$",'$1' -replace '^"(.*)"$','$1'
    }
  }
  if (-not $fileVals['ROGUE_API_KEY']) { continue }
  $logCfg = $fileVals
  break
}
foreach ($v in 'ROGUE_LOG_FILE','ROGUE_LOG_DIR') {
  if (-not $logCfg[$v]) { $pv = [Environment]::GetEnvironmentVariable($v); if ($pv) { $logCfg[$v] = $pv } }
}
$logPath = $logCfg['ROGUE_LOG_FILE']
if (-not $logPath) {
  $logDir = $logCfg['ROGUE_LOG_DIR']
  if (-not $logDir) { $logDir = Join-Path (Join-Path $env:USERPROFILE '.rogue') 'logs' }
  $logPath = Join-Path $logDir 'copilot.log'
}
"Log: $logPath"
Get-Content -Tail 20 $logPath -ErrorAction SilentlyContinue
```

### Upload the log to Rogue support

**Only run this if the user asks for it, or asks for help with a problem that
needs the log read.** It uploads this machine's hook log to Rogue, where a
support engineer can read it without an endpoint agent on the box.

This normally needs no action: the log ships by itself in the background at
session start, at most once every 15 minutes per file, resuming from wherever the
last upload finished. Run it by hand only to push the newest lines *now*.

**Uploading needs no opt-in.** A configured install uploads its log on its own; the
commands below only make one run happen *now*, with its output visible. There is no
`ROGUE_SHIP_LOGS` flag any more — nothing here switches uploading on or off.

- macOS / Linux:
```bash
ROGUE_SHIP_MIN_INTERVAL=0 ROGUE_DEBUG=1 \
  sh "$HOME/.copilot/installed-plugins/rogue-copilot/rogue/scripts/ship-logs.sh"
```
- Windows (PowerShell):
```powershell
$root = Join-Path $env:USERPROFILE '.copilot\installed-plugins\rogue-copilot\rogue'
$env:ROGUE_SHIP_MIN_INTERVAL = '0'; $env:ROGUE_DEBUG = '1'
$env:ROGUE_SHIPPER_SCRIPT = Join-Path $root 'scripts\ship-logs.ps1'
# PASS THE ROOT. On a no-argument run the shipper self-locates its plugin root to
# read <root>\env, a candidate in the credential chain - and $PSCommandPath is
# EMPTY under [scriptblock]::Create, so it falls back to the current directory,
# which is the operator's cwd and has no env file. The bundled ROGUE_BASE_URL is
# then missed and identity can be absent entirely (outcome=skip reason=no-actor),
# on the one command support asks them to run. heartbeat.ps1 passes it for the
# same reason. The slug stays unset, which is what keeps this the
# collect-everything support invocation.
$env:ROGUE_SHIPPER_ROOT = $root
$encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes(
  '& ([scriptblock]::Create((Get-Content -Raw -LiteralPath $env:ROGUE_SHIPPER_SCRIPT))) $env:ROGUE_SHIPPER_ROOT'))
Start-Process -FilePath 'powershell' -NoNewWindow -Wait `
  -ArgumentList '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded
# One run only. The bash form scopes these to a single command; setting them as
# session variables would leave later runs from this session with the 15-minute
# throttle waived and debug output on.
Remove-Item Env:ROGUE_SHIP_MIN_INTERVAL, Env:ROGUE_DEBUG, Env:ROGUE_SHIPPER_SCRIPT, Env:ROGUE_SHIPPER_ROOT -ErrorAction SilentlyContinue
```

**A child process, never in-process.** `ship-logs.ps1` ends in `exit 0`, so
loading it into the current session would terminate *that* session rather than
the shipper. The script path travels as an environment variable and the command
itself is a constant, so a path containing a quote cannot alter it;
`-EncodedCommand` because `-ArgumentList` quoting is unreliable on Windows
PowerShell 5.1. Same shape `heartbeat.ps1` uses.

An absolute path, not a plugin-root variable: Copilot sets no root variable for a
slash command's shell. If that path does not exist, list
`~/.copilot/installed-plugins/` — the marketplace name is `rogue-copilot`, so the
plugin lands one level deeper than the other agents'.

**This is unavailable in the JetBrains IDE's Local agent**, which does not load
`~/.copilot/installed-plugins` at all — the same reason `/rogue:status` itself is
unreachable there. Ask the user to run it from the terminal CLI instead; both
write the same `copilot.log`.

Run with **no arguments**, which is the support form: it uploads *every* agent's
log in the log directory, not just `copilot.log`. Each line is attributed by its
own `provider=` token, so a mixed upload is still filed per agent.

`ROGUE_SHIP_MIN_INTERVAL=0` waives the 15-minute throttle for this one run;
`ROGUE_DEBUG=1` prints one line per upload. Report what it prints. Expect **no
output at all** when everything already shipped — that is success. Nothing is
re-sent, because the upload resumes from a stored byte offset that only advances
on a confirmed 2xx.

Report failures as-is rather than retrying: `http=401` is a bad API key
(`/rogue:setup`), `http=000` is a network or proxy problem, and
`outcome=skip reason=no-actor` means identity is unresolved.

## Step 5: Confirm hooks are trusted

Remind the user that Copilot CLI skips untrusted command hooks. If no events are
showing up in the dashboard, open `/hooks` in Copilot CLI and trust the Rogue
entries.

## Step 6: Summary

Present a clean summary: credential sources, connection status, mode + ruleset
count, the Copilot event set, and actor identity (`${ROGUE_ACTOR_EMAIL}` /
`${ROGUE_ACTOR_NAME}`).

## Step 7: False-positive escape hatch

> **Was a prompt blocked by mistake?** Prepend `rgx!` to your next prompt and
> resubmit. Rogue allows that one prompt and marks the previous detection as a
> false positive. The override is per-prompt only.
