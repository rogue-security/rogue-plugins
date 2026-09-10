---
name: status
description: Check Rogue Security AIDR connection, active rulesets, and configuration
---

# Rogue Security Status

Verify the current Rogue Security integration. Reads one env file: the first of `/etc/rogue/env` (MDM) and `~/.rogue-env` (per-user) that holds `ROGUE_API_KEY`.

## Step 1: Source credentials and report what was found

```bash
# The first env file holding ROGUE_API_KEY is used alone.
for f in /etc/rogue/env "$HOME/.rogue-env"; do
  [ -r "$f" ] && grep -Eq "^[[:space:]]*(export[[:space:]]+)?ROGUE_API_KEY=[\"']?[^\"'[:space:]]" "$f" && { . "$f"; echo "  in use: $f"; break; }
  [ -r "$f" ] && echo "  $f  (no ROGUE_API_KEY, not read)"
done
[ -n "$ROGUE_API_KEY" ] && echo "API key resolved: ...${ROGUE_API_KEY: -4}" || { echo "API key: not resolved"; }
```

If `ROGUE_API_KEY` is empty, stop and tell the user to run `/rogue:setup`.

## Step 2: Ping the API

```bash
for f in /etc/rogue/env "$HOME/.rogue-env"; do [ -r "$f" ] && grep -Eq "^[[:space:]]*(export[[:space:]]+)?ROGUE_API_KEY=[\"']?[^\"'[:space:]]" "$f" && { . "$f"; break; }; done
curl -s -w "\n%{http_code}" -H "x-rogue-api-key: $ROGUE_API_KEY" \
  "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/ping"
```

## Step 3: Fetch active config

```bash
for f in /etc/rogue/env "$HOME/.rogue-env"; do [ -r "$f" ] && grep -Eq "^[[:space:]]*(export[[:space:]]+)?ROGUE_API_KEY=[\"']?[^\"'[:space:]]" "$f" && { . "$f"; break; }; done
curl -s -H "x-rogue-api-key: $ROGUE_API_KEY" \
  "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/config"
```

Parse the JSON and show: mode (enforce/monitor), fail-open setting, active rulesets.

## Step 4: Show identity + recent hook activity

```bash
for f in /etc/rogue/env "$HOME/.rogue-env"; do [ -r "$f" ] && grep -Eq "^[[:space:]]*(export[[:space:]]+)?ROGUE_API_KEY=[\"']?[^\"'[:space:]]" "$f" && { . "$f"; break; }; done
echo "Actor email: ${ROGUE_ACTOR_EMAIL:-(unset)}"
echo "Actor name:  ${ROGUE_ACTOR_NAME:-(unset)}"
echo "--- recent hook activity ---"
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
  log="$dir/cursor.log"
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
  $logPath = Join-Path $logDir 'cursor.log'
}
"Log: $logPath"
Get-Content -Tail 20 $logPath -ErrorAction SilentlyContinue
```

A `ROGUE_LOG_DIR` set in `~/.rogue-env` or `C:\ProgramData\rogue\env` also wins over
the default — check those files if this shows no activity on a healthy connection.

Each Rogue plugin logs to its **own** file under `~/.rogue/logs/`, so this reads
`cursor.log` only — a sibling agent's activity lives in `claude.log`,
`codex.log`, and so on. `<file>.1` is the previous rotation, if any. An empty or
missing file with a healthy connection just means no events have fired yet.

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
ROGUE_SHIP_MIN_INTERVAL=0 ROGUE_DEBUG=1 sh "${CURSOR_PLUGIN_ROOT:-$HOME/.cursor/plugins/local/rogue}/scripts/ship-logs.sh"
```
- Windows (PowerShell):
```powershell
$root = $env:CURSOR_PLUGIN_ROOT
if (-not $root) { $root = Join-Path $env:USERPROFILE '.cursor\plugins\local\rogue' }
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
PowerShell 5.1. Same shape `hook.ps1` uses to start the shipper.

The explicit fallback path matters here: `CURSOR_PLUGIN_ROOT` is set for hook
subprocesses, but a slash command runs in the agent's own shell, where it may be
absent. `~/.cursor/plugins/local/rogue` is where the one-line installer puts the
plugin; a Team Marketplace install lives elsewhere, so check `~/.cursor/plugins/`
if that path does not exist.

Run with **no arguments**, which is the support form: it uploads *every* agent's
log in the log directory, not just `cursor.log`. Each line is attributed by its
own `provider=` token, so a mixed upload is still filed per agent.

`ROGUE_SHIP_MIN_INTERVAL=0` waives the 15-minute throttle for this one run;
`ROGUE_DEBUG=1` prints one line per upload. Report what it prints. Expect **no
output at all** when everything already shipped — that is success. Nothing is
re-sent, because the upload resumes from a stored byte offset that only advances
on a confirmed 2xx.

Report failures as-is rather than retrying: `http=401` is a bad API key
(`/rogue:setup`), `http=000` is a network or proxy problem, and
`outcome=skip reason=no-actor` means identity is unresolved.

## Step 5: Summary

Combine credential sources, connection status, and identity into one clean summary. If everything looks good, confirm the integration is active. Block/allow/ask policy is managed server-side — direct the user to the dashboard to view or change it.

## Step 6: False-positive escape hatch

Tell the user: prepend `rgx!` to a prompt to allow it through and mark the previous detection as a false positive in the dashboard.
