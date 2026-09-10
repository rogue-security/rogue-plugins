---
name: status
description: Check Rogue Security AIDR connection status, active rulesets, identity, and recent hook activity for Gemini CLI
---

# Rogue Security Status

Check the current status of the Rogue Security AIDR integration for Gemini CLI.
The hooks read exactly one env file: the first of `/etc/rogue/env` (MDM), the
extension's bundled `env` (managed installs), and `~/.rogue-env` (per-user setup)
that holds `ROGUE_API_KEY`. This command applies the same rule.

**Pick the command variant for the user's OS.** Use the macOS / Linux (bash)
commands by default; use the Windows (PowerShell) block at the end on native
Windows. There, the files are `C:\ProgramData\rogue\env` (MDM) and
`%USERPROFILE%\.rogue-env` (per-user).

## Step 1: Resolve credentials and report sources

```bash
ROGUE_ENV_IN_USE=""
# The first env file holding ROGUE_API_KEY is used alone.
for f in /etc/rogue/env "$HOME/.gemini/extensions/rogue/env" "$HOME/.rogue-env"; do
  [ -r "$f" ] && grep -Eq "^[[:space:]]*(export[[:space:]]+)?ROGUE_API_KEY=[\"']?[^\"'[:space:]]" "$f" && { . "$f"; ROGUE_ENV_IN_USE=$f; break; }
done
echo "Credential sources detected:"
for f in /etc/rogue/env "$HOME/.gemini/extensions/rogue/env" "$HOME/.rogue-env"; do
  [ -r "$f" ] || continue
  if grep -Eq "^[[:space:]]*(export[[:space:]]+)?ROGUE_API_KEY=[\"']?[^\"'[:space:]]" "$f"; then echo "  $f"; else echo "  $f  (no ROGUE_API_KEY, not read)"; fi
done
echo "In use: ${ROGUE_ENV_IN_USE:-(none holds ROGUE_API_KEY)}"
[ -n "${ROGUE_API_KEY:-}" ] && echo "API key resolved: ...${ROGUE_API_KEY: -4}" || echo "API key: not resolved"
```

If no source is found or `ROGUE_API_KEY` is empty, tell the user to run `/setup`
and stop here.

## Step 2: Test connection + register heartbeat

Hit the status endpoint with the resolved key. This validates the key, registers
this install in the dashboard's Coding Agents roster, and reports whether a newer
version exists. Read the extension version from the manifest without `python3`
(absent on a fresh macOS):

```bash
for f in /etc/rogue/env "$HOME/.gemini/extensions/rogue/env" "$HOME/.rogue-env"; do [ -r "$f" ] && grep -Eq "^[[:space:]]*(export[[:space:]]+)?ROGUE_API_KEY=[\"']?[^\"'[:space:]]" "$f" && { . "$f"; break; }; done
PJ="$HOME/.gemini/extensions/rogue/gemini-extension.json"
VER=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9][^"]*"' "$PJ" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
curl -s -w "\n%{http_code}" -X POST \
  "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/status" \
  -H "x-rogue-api-key: $ROGUE_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"agent_family\":\"gemini\",\"agent\":\"gemini_cli\",\"version\":\"${VER:-unknown}\",\"host\":\"$(hostname)\",\"actor_email\":\"${ROGUE_ACTOR_EMAIL:-}\",\"actor_name\":\"${ROGUE_ACTOR_NAME:-}\"}"
```

HTTP 200 = connected. Report `organization.name`, running vs latest version, and
`update_available`. HTTP 401 → key invalid (compare against the API keys
dashboard). No response → check network reachability to `api.rogue.security`.

## Step 3: Fetch configuration

```bash
for f in /etc/rogue/env "$HOME/.gemini/extensions/rogue/env" "$HOME/.rogue-env"; do [ -r "$f" ] && grep -Eq "^[[:space:]]*(export[[:space:]]+)?ROGUE_API_KEY=[\"']?[^\"'[:space:]]" "$f" && { . "$f"; break; }; done
curl -s -H "x-rogue-api-key: $ROGUE_API_KEY" \
  "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/config"
```

Display:
- **Mode**: `settings.mode` (enforce or monitor)
- **Fail-open**: `settings.failOpen`
- **Gemini CLI events**: `tools.gemini_cli.monitoredEvents` and `tools.gemini_cli.blockingEvents`
- **Active rulesets**: for each ruleset, name, category, mode, severity

## Step 4: Show identity + recent hook activity

```bash
for f in /etc/rogue/env "$HOME/.gemini/extensions/rogue/env" "$HOME/.rogue-env"; do [ -r "$f" ] && grep -Eq "^[[:space:]]*(export[[:space:]]+)?ROGUE_API_KEY=[\"']?[^\"'[:space:]]" "$f" && { . "$f"; break; }; done
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
for f in /etc/rogue/env "$HOME/.gemini/extensions/rogue/env" "$HOME/.rogue-env"; do
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
  log="$dir/gemini.log"
fi
echo "Log: $log"
tail -n 20 "$log" 2>/dev/null || echo "(no hook log yet)"
```

Each Rogue plugin logs to its **own** file under `~/.rogue/logs/`, so this reads
`gemini.log` only — a sibling agent's activity lives in `claude.log`,
`cursor.log`, and so on. `<file>.1` is the previous rotation, if any.

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

**One SCRIPT, both platforms** — Gemini CLI guarantees Node 20+ on PATH, so the
shipper is a single Node script here rather than the sh/PowerShell pair the other
Rogue plugins ship, and there is no `.ps1` variant. The *invocation* still differs:
the bash form below uses `$HOME` and `VAR=value cmd` prefixing, neither of which
exists in PowerShell, so Windows gets its own form rather than being told to run a
command it cannot.

- macOS / Linux:
```bash
ROGUE_SHIP_MIN_INTERVAL=0 ROGUE_DEBUG=1 node "$HOME/.gemini/extensions/rogue/scripts/ship-logs.mjs"
```
- Windows (PowerShell):
```powershell
$ship = Join-Path $env:USERPROFILE '.gemini\extensions\rogue\scripts\ship-logs.mjs'
if (-not (Test-Path -LiteralPath $ship)) { "ship-logs.mjs not found at $ship - list %USERPROFILE%\.gemini\extensions and report what is there" }
else {
  "using $ship"
  # Set, run, unset: PowerShell has no `VAR=value command` prefix, and leaving these
  # in the session would waive the 15-minute throttle and keep debug output on for
  # every later run. No child process is needed here (unlike the other plugins,
  # whose shipper is a .ps1 that ends in `exit 0` and would end this session).
  $env:ROGUE_SHIP_MIN_INTERVAL = '0'; $env:ROGUE_DEBUG = '1'
  try { & node $ship } finally {
    Remove-Item Env:ROGUE_SHIP_MIN_INTERVAL, Env:ROGUE_DEBUG -ErrorAction SilentlyContinue
  }
}
```

Run with **no arguments**, which is the support form: it uploads *every* agent's
log in the log directory, not just `gemini.log`. Each line is attributed by its
own `provider=` token, so a mixed upload is still filed per agent — and the state
directory is shared with the other plugins' shippers, so a log another agent
already uploaded is not sent twice.

`ROGUE_SHIP_MIN_INTERVAL=0` waives the 15-minute throttle for this one run;
`ROGUE_DEBUG=1` prints one line per upload. Report what it prints. Expect **no
output at all** when everything already shipped — that is success. Nothing is
re-sent, because the upload resumes from a stored byte offset that only advances
on a confirmed 2xx.

Report failures as-is rather than retrying: `http=401` is a bad API key
(`/setup`), `http=0` is a network or proxy problem — the Node shipper reports a
transport failure or a timeout as `http=0`, where the other plugins' sh and
PowerShell shippers print curl's `000` — and
`outcome=skip reason=no-actor` means identity is unresolved.

## Step 5: Summary

Present a clean summary: credential sources, connection status, mode + ruleset
count, identity, and a snippet of recent hook activity. Confirm whether the
integration is active.

## Step 6: False-positive escape hatch

Tell the user: **Was a prompt blocked by mistake?** Prepend `rgx!` to the next
prompt and resubmit — Rogue allows that one prompt and marks the previous
detection as a false positive. The override is per-prompt only.

## Windows (PowerShell)

Run this single block instead of Steps 1–4. The log **upload** has its own
PowerShell form in *Upload the log to Rogue support* above — run that one when the
user asks for an upload.

```powershell
$creds = @{}
# The first env file holding ROGUE_API_KEY is used alone: machine, bundled, user.
foreach ($f in @('C:\ProgramData\rogue\env', "$env:USERPROFILE\.gemini\extensions\rogue\env", "$env:USERPROFILE\.rogue-env")) {
  if (-not $f -or -not (Test-Path -LiteralPath $f)) { continue }
  $fileVals = @{}
  foreach ($line in (Get-Content -LiteralPath $f)) {
    if ($line -match '^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.+)$') {
      $fileVals[$Matches[1]] = $Matches[2].Trim() -replace "^'(.*)'$",'$1' -replace '^"(.*)"$','$1'
    }
  }
  if (-not $fileVals['ROGUE_API_KEY']) { continue }
  Write-Host "  in use: $f"
  $creds = $fileVals
  break
}
$key = $creds['ROGUE_API_KEY']
if (-not $key) { 'API key: not resolved — run /setup'; return }
'API key resolved: ...' + $key.Substring([Math]::Max(0,$key.Length-4))
$base = if ($creds['ROGUE_BASE_URL']) { $creds['ROGUE_BASE_URL'].TrimEnd('/') } else { 'https://api.rogue.security' }
$pj = "$env:USERPROFILE\.gemini\extensions\rogue\gemini-extension.json"
$ver = 'unknown'; if (Test-Path $pj) { try { $ver = (Get-Content -Raw $pj | ConvertFrom-Json).version } catch {} }
$body = @{ agent_family='gemini'; agent='gemini_cli'; version=$ver; host=$env:COMPUTERNAME; actor_email=[string]$creds['ROGUE_ACTOR_EMAIL']; actor_name=[string]$creds['ROGUE_ACTOR_NAME'] } | ConvertTo-Json -Compress
try {
  $r = Invoke-WebRequest -Uri "$base/api/v1/hooks/status" -Method Post -Headers @{ 'x-rogue-api-key'=$key } -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -UseBasicParsing -TimeoutSec 10
  "Connected (HTTP $($r.StatusCode)): $($r.Content)"
} catch { "Status check failed: $($_.Exception.Message)" }
"Actor email: $($creds['ROGUE_ACTOR_EMAIL'])"
"Actor name:  $($creds['ROGUE_ACTOR_NAME'])"
# The process environment supplies only what the file in use does not set, exactly
# as in the dispatcher - so an operator who exported ROGUE_LOG_DIR for this session
# is still told where the log is.
foreach ($v in 'ROGUE_LOG_FILE','ROGUE_LOG_DIR') {
  if (-not $creds[$v]) { $pv = [Environment]::GetEnvironmentVariable($v); if ($pv) { $creds[$v] = $pv } }
}
$logPath = $creds['ROGUE_LOG_FILE']
if (-not $logPath) {
  $logDir = $creds['ROGUE_LOG_DIR']
  if (-not $logDir) { $logDir = Join-Path (Join-Path $env:USERPROFILE '.rogue') 'logs' }
  $logPath = Join-Path $logDir 'gemini.log'
}
"Log: $logPath"
Get-Content -Tail 20 $logPath -ErrorAction SilentlyContinue
```

Report the same fields as Step 2.
