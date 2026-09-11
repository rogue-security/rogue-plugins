# Managed Deployment Guide

How to roll out Rogue Security AIDR to a managed Claude Code fleet, using
the Claude management UI for plugin distribution and an MDM (Kandji, Jamf,
etc.) to provision the machine env file: the org API key plus the assigned
user's identity.

If you are an individual user installing for yourself, see the [README](../README.md)
and run `/rogue:setup` instead — this guide doesn't apply.

## Overview

Two artifacts get deployed independently. Both must land for the plugin to
produce correctly-attributed events:

```
┌────────────────────┐
│ Security Admin     │
└─────────┬──────────┘
          │ 1. compile-customer-plugin.sh --key <rsk_…>
          ▼
┌────────────────────┐         ┌────────────────────────┐
│ rogue-aidr-…zip    │  upload │ Claude Management UI   │
│ (API key baked in) │────────▶│  pushes plugin to org  │
└────────────────────┘         └───────────┬────────────┘
                                           │
┌────────────────────┐                     │
│ MDM (Kandji/Jamf)  │  push script        │
│  key + user vars   │─────────────────────┤
└────────────────────┘                     ▼
                               ┌────────────────────────┐
                               │ User Device            │
                               │  ~/.claude/plugins/…   │  (plugin)
                               │  /etc/rogue/env        │  (key + identity)
                               │                        │
                               │  hook fires → POSTs    │
                               │  org key + real actor  │
                               └────────────────────────┘
```

End state: every Claude Code event from every managed user POSTs to Rogue
with the org's API key and the user's real identity, with no manual setup
required from the end user.

## Prerequisites

- A Rogue API key for your organization
  ([dashboard](https://app.rogue.security/settings/api-keys)).
- Claude Code v2.1+ on user devices.
- Admin access to the Claude management UI (for plugin distribution).
- Admin access to your MDM (Kandji, Jamf, Workspace ONE, etc.).
- On the machine you use to compile: `bash`, `curl`, `python3`, `tar`,
  and either `zip` or python's stdlib zip module.

## Quickstart

If you already know the pieces, here are the four commands:

```bash
# 1. Compile the org bundle (on your machine)
curl -fsSL https://raw.githubusercontent.com/qualifire-dev/rogue-plugins/main/scripts/compile-customer-plugin.sh \
  | bash -s -- --key <your-rsk-key>

# 2. Upload rogue-aidr-compiled-<version>.zip via the Claude management UI

# 3. Deploy this as an MDM script (Kandji Custom Script body shown):
#    Replace $USER_EMAIL / $USER_FULL_NAME with your MDM's user variables.
#!/usr/bin/env bash
set -e
[ -n "$USER_EMAIL" ] && [ -n "$USER_FULL_NAME" ] || exit 0
ROGUE_API_KEY="<your-rsk-key>" ROGUE_ACTOR_EMAIL="$USER_EMAIL" ROGUE_ACTOR_NAME="$USER_FULL_NAME" \
  bash <(curl -fsSL https://raw.githubusercontent.com/qualifire-dev/rogue-plugins/main/scripts/mdm-provision-actor.sh)

# 4. On a test device, verify
/rogue:status
```

The rest of this doc explains each step and how to debug it.

## Step 1 — Compile the plugin bundle

On any machine you trust:

```bash
curl -fsSL https://raw.githubusercontent.com/qualifire-dev/rogue-plugins/main/scripts/compile-customer-plugin.sh \
  | bash -s -- --key <your-rsk-key>
```

Drops `rogue-aidr-compiled-<version>.zip` in the current directory. The zip
contains a flat marketplace layout (`.claude-plugin/marketplace.json` +
`.claude-plugin/plugin.json` at root) and an `env` file with the API key
and enforcement defaults.

| Flag | Default | What it does |
| --- | --- | --- |
| `--key KEY` | required | Bake this API key into the bundle |
| `--mode ask\|block` | `ask` | PreToolUse enforcement mode |
| `--from vX.Y.Z` | latest GitHub release | Pin to a specific release tag |
| `--out PATH` | `./rogue-aidr-compiled-<ver>.zip` | Output path |
| `--base-url URL` | `https://api.rogue.security` | Custom Rogue endpoint |
| `--repo OWNER/REPO` | `qualifire-dev/rogue-plugins` | Source mirror |

The script can also be downloaded and run locally — passing args
non-interactively or letting it prompt via `/dev/tty`.

**Important:** the API key is baked into `env` in plaintext inside the zip.
Treat the zip as a secret. Do not commit it, post it in shared channels,
or store it in world-readable build artifacts.

## Step 2 — Upload to the Claude management UI

In your org's Claude management UI:

1. Open the plugin/extension management view.
2. Drag-and-drop the compiled zip into the upload area, or use the upload
   button.
3. Confirm the plugin appears in your org's installed plugins list and is
   enabled.
4. Push it to your user group(s). Users receive it on their next Claude
   Code session start.

At this point users have the plugin and the API key. Until Step 3 lands the
hooks read the bundled `env`, and the actor is whatever the device's git config
or login name says.

## Step 3 — Deploy the MDM actor provisioning script

`scripts/mdm-provision-actor.sh` writes `/etc/rogue/env` on the target
device with the org API key and the assigned user's identity. It is the first
file the hooks look at, and once it holds `ROGUE_API_KEY` it is the only one
read: nothing from the bundled `env` is merged, so the script also pins
`ROGUE_AUTO_UPDATE=0` (pass `--mode block` if the bundle was compiled with
it). A file without the key is skipped whole, which is why the script refuses
to write one.

### Kandji (Custom Script)

Create a Custom Script Library item, scoped to your Mac fleet. Execution
frequency: every enforcement cycle (e.g. every 4h) so user reassignments
are picked up automatically.

Script body:

```bash
#!/usr/bin/env bash
set -e

# Guard against empty MDM placeholders (a misconfigured Kandji user
# binding would otherwise overwrite a previously-correct file with empty
# exports).
[ -n "$USER_EMAIL" ] || exit 0
[ -n "$USER_FULL_NAME" ] || exit 0

ROGUE_API_KEY="<your-rsk-key>" \
ROGUE_ACTOR_EMAIL="$USER_EMAIL" \
ROGUE_ACTOR_NAME="$USER_FULL_NAME" \
  bash <(curl -fsSL https://raw.githubusercontent.com/qualifire-dev/rogue-plugins/main/scripts/mdm-provision-actor.sh)
```

`$USER_EMAIL` and `$USER_FULL_NAME` are Kandji variables that resolve from
the assigned user on the asset record (configured via Kandji's directory
integration). Verify the variable names against your Kandji tenant's
Library → Custom Scripts → Variables reference.

### Jamf Pro (Policy script)

Upload `mdm-provision-actor.sh` to Jamf Pro under Settings → Computer
Management → Scripts. Set the script parameter labels:

- `Parameter 4` → "Email"
- `Parameter 5` → "Full name"
- `Parameter 6` → "API key"

Create a Policy that runs the script with the user's email and name passed
as parameters (typically populated by an LDAP/AD attribute mapping) and the
org API key as the third:

```bash
#!/usr/bin/env bash
set -e
EMAIL="$4"
NAME="$5"
KEY="$6"
[ -n "$EMAIL" ] && [ -n "$NAME" ] && [ -n "$KEY" ] || exit 0
bash <(curl -fsSL https://raw.githubusercontent.com/qualifire-dev/rogue-plugins/main/scripts/mdm-provision-actor.sh) \
  --email "$EMAIL" --name "$NAME" --key "$KEY"
```

### Other MDMs

The script accepts its inputs via either env vars (`ROGUE_API_KEY`,
`ROGUE_ACTOR_EMAIL`, `ROGUE_ACTOR_NAME`) or CLI args (`--key`, `--email`,
`--name`). Use whichever your MDM substitutes natively. `--mode`,
`--base-url` and `--auto-update` are optional.

### Offline / air-gapped fleets

Replace `bash <(curl …)` with an inline copy of `mdm-provision-actor.sh`
embedded directly in your MDM payload. The script has no network
dependencies — it only writes a local file.

## Step 4 — Verify

On a single test device after both deploys land:

```bash
# 1. MDM landed
ls -la /etc/rogue/env             # expect: -rw-r--r-- root wheel ...
grep -c ROGUE_API_KEY /etc/rogue/env   # expect: 1 (a keyless file is not read)
grep ACTOR /etc/rogue/env         # expect: ROGUE_ACTOR_EMAIL=alice@yourorg.com

# 2. Plugin landed
ls ~/.claude/plugins              # expect: a directory containing 'rogue'
test -f ~/.claude/plugins/*/env && echo "bundle env present"

# 3. End-to-end (inside a Claude Code session)
/rogue:status
```

`/rogue:status` pings the API with the resolved credentials and prints the
mode + identity it sees. If the email there matches the assigned user, the
full pipeline is healthy.

## How it all fits together

Every hook in the plugin runs this preamble before POSTing the event:

```sh
for _env_file in /etc/rogue/env "${CLAUDE_PLUGIN_ROOT:-}/env" "$HOME/.rogue-env"; do
  if [ -r "$_env_file" ] && grep -Eq "^[[:space:]]*(export[[:space:]]+)?ROGUE_API_KEY=[\"']?[^\"'[:space:]]" "$_env_file"; then
    . "$_env_file"; break
  fi
done
```

Three candidates. The first that holds `ROGUE_API_KEY` is sourced alone; its
values override the process environment, and a file without the key is skipped:

| Source | Written by | Carries |
| --- | --- | --- |
| `/etc/rogue/env` | MDM script (Step 3) | Org API key, identity, mode, auto-update pin; first candidate |
| `${CLAUDE_PLUGIN_ROOT}/env` | Compile script (Step 1) | Org API key, enforcement mode, auto-update pin; read until Step 3 lands |
| `~/.rogue-env` | User running `/rogue:setup` | Per-user; not used in managed deployments |

## Operations

### Rotating the API key

**MDM** — push the new `--key` through the MDM script. The next enforcement
cycle rewrites `/etc/rogue/env`, and every hook fire after that uses the new key;
revoke the old one in the dashboard afterward.

**Bundle** — recompile and re-upload as well, so a device the MDM has not
reached yet does not keep posting with the old key.

### Shipping plugin updates

When new plugin behavior ships (e.g. new hook events, schema changes),
recompile with `--from vX.Y.Z` to pin a specific release, then upload the
new zip to the Claude management UI. The compiled bundle sets
`ROGUE_AUTO_UPDATE=0` so user devices never auto-pull from GitHub — every
update is admin-controlled.

### User reassignment / device transfer

Kandji and Jamf re-run scripts on every enforcement cycle (default
~hourly). When the assigned user on a device changes, the next enforcement
overwrites `/etc/rogue/env` with the new identity. No manual cleanup.

### Removing the deployment

1. In the Claude management UI, remove the plugin from your org's user
   group(s).
2. In your MDM, remove or rescope the actor provisioning script.
3. Optionally push a one-off script that removes leftover state:

   ```bash
   sudo rm -f /etc/rogue/env
   sudo rmdir /etc/rogue 2>/dev/null || true
   ```

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `/rogue:status` shows the user's git identity, not the MDM-assigned one | MDM script didn't run yet, so the hooks read the bundled `env` (`/rogue:status` marks `/etc/rogue/env` "not read" when it lacks the key) | Force MDM enforcement: Kandji "Run library item now", Jamf `sudo jamf policy` |
| `/rogue:status` shows blank identity | MDM ran with empty placeholders, or fell back to a no-op | Verify MDM user binding; confirm the `[ -n "$USER_EMAIL" ]` guard in your payload |
| `/rogue:status` says "not configured" | Plugin didn't deploy, or `${CLAUDE_PLUGIN_ROOT}/env` was stripped | Re-upload via Claude management UI; verify zip has `env` at root |
| Events in dashboard carry the user's git identity, not the MDM-assigned one | Plugin landed before MDM script (race during rollout): the bundled `env` is read until `/etc/rogue/env` holds the key | Wait for next MDM enforcement cycle, or kick it manually |
| No events at all in dashboard | Hooks fail-open silently on curl timeout or network error | Check device can reach `api.rogue.security`; inspect `~/.rogue/auto-update.log` for clues |
| macOS modal alert doesn't fire on blocked prompts | Expected on every surface except **Claude Cowork local** — the CLI and the Desktop app render the block reason natively and are suppressed deliberately. Otherwise: a cloud Cowork session (`CLAUDE_CODE_REMOTE=true`, a headless container with no GUI), `ROGUE_ALERT=0`, an event excluded by `ROGUE_ALERT_EVENTS`, or no `osascript` on `PATH` | Read `~/.rogue/hook.log`: `alert_skipped=1` names the gate input that declined (`entrypoint=` / `cowork=` / `remote=` / `agent=`), and `alert_rc=<status>` (plus `alert_err="…"`) reports a modal that was attempted and failed. **No Automation permission is needed** — the alert does not use `tell application "System Events"`, so a Privacy & Security → Automation grant is not the fix |
| Plugin upload rejected by Claude management UI | Hooks file declares unsupported events, or marketplace.json missing | Recompile with the latest `compile-customer-plugin.sh` — the script filters hooks and generates marketplace.json |

## Security notes

- **Org-wide API key.** The bundle and `/etc/rogue/env` both carry a single
  API key shared by every user. Per-user attribution comes from the actor
  headers (set by MDM), not from per-user keys. Per-device keys are possible
  (`--key` per device), but then revocation happens via MDM, not re-compile.

- **`/etc/rogue/env` is world-readable** (`0644`, root-owned): the hooks run
  as each user and must read it, and it carries the org key. To narrow
  readers, change the script's `chmod` to `0640` and add a group whose
  members are the human users.

- **The compiled zip is sensitive.** Anyone with the file can extract the
  API key in cleartext. Distribute only through the Claude management UI;
  never over email, public Slack, or shared cloud folders. If you must
  store builds, encrypt at rest and gate access to the security team.

- **Auto-update is disabled in compiled bundles.** Devices will not silently
  pull new versions from GitHub on their own. This is intentional for
  managed deployments: every upgrade is an explicit admin action.

- **`rgx!` false-positive escape hatch is honored on all installs.** Users
  can prepend `rgx!` to any prompt to bypass a block. If you want this
  disabled for compliance reasons, that's a server-side policy change in
  the Rogue dashboard, not a plugin change.

## What's not covered

- **Hot-desk / shared devices.** This guide assumes one identity per
  device. For machines where multiple users sign in over time, identity
  provisioning should happen at user login (LaunchAgent, PAM hook) and
  write `~/.rogue-env`, with `/etc/rogue/env` absent: a machine file holding a
  key is read alone. Contact Rogue support for a reference setup.

- **Non-managed installs.** Users installing the plugin themselves via
  the public marketplace should follow the [README](../README.md) and run
  `/rogue:setup`.

- **Windows.** Natively supported (no WSL or Git Bash required). Each hook
  ships a PowerShell sibling (`hook.ps1`, `heartbeat.ps1`, `auto-update.ps1`,
  `setup.ps1`, `security-alert.ps1`) alongside the POSIX `sh` scripts, and
  exactly one runs per machine. Install with the PowerShell one-liner
  (`iwr -useb .../install.ps1 | iex`). Credentials live at
  `%USERPROFILE%\.rogue-env` (per-user) or `C:\ProgramData\rogue\env` (MDM);
  the block modal uses `WScript.Shell.Popup` (**not**
  `System.Windows.Forms.MessageBox`, which silently no-ops from the detached,
  hidden process the hook launches it in). On Linux the modal uses `notify-send`
  (silent fall-through if absent); everything else works. Note the modal itself
  fires **only in Claude Cowork local sessions** — the CLI and the Desktop app
  display block reasons natively and get no modal on any platform.

---

Issues or corrections: <https://github.com/qualifire-dev/rogue-plugins/issues>.
