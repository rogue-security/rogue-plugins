# Shipping the hook logs to the backend (phases 2–3)

Phase 1 (PR #29, merged first in this stack) gave every plugin its own log file at
`~/.rogue/logs/<agent>.log`, a shared line format, and a size cap. This document
is the design for getting those lines to the backend.

There are **two independent capabilities**, and they are independent on purpose:

| | ships from | auth | trigger | coverage |
|---|---|---|---|---|
| **A. Plugin shipper** | the plugin itself | `ROGUE_API_KEY` | its own detached session-start process | every machine that has a Rogue plugin |
| **B. Endpoint collector** | the endpoint agent | enrolled agent secret | a backend-dispatched task | machines that also run the endpoint agent |

**A is the baseline** — not every customer runs the endpoint agent, so a design that
depends on it leaves logs unreachable on exactly the installs we most often need
to debug (a fresh one-liner install that never showed up in the dashboard). **B
is an on-demand pull** for support and IR: "collect this machine's logs now",
whole file rather than the incremental tail, and it carries a real `machine_id`.
Neither blocks the other; either alone is useful.

## What the log is actually worth

The backend already receives every hook event. What `<agent>.log` adds is
**transport failures and local diagnostics** — the events that never reached the
API, plus outcomes the API never sees even when the request succeeded (a local
alert, a failed enrichment, an unresolved subagent):

```text
outcome=unconfigured          no API key on this machine
http=<code> rc=<rc>           non-2xx, or curl/Invoke-WebRequest transport failure
outcome=fail-open             timeout, unreachable, malformed body
ide_alert=fired               a JetBrains silent block we had to surface locally
dbstore=miss / tail=none      an enrichment that could not be produced
subagent=… outcome=unresolved  re-attribution that failed
```

So this is **client-side diagnostics**, not the security signal. That has two
consequences: the cadence can be lazy (nothing here is real-time), and the volume
is tiny — a busy day is single-digit KB. Do not build continuous streaming.

## Why the plugin can attribute its own logs

This was the original blocker: the plugins have no machine identity, and we
decided **not** to invent one (a generated UUID cannot be correlated to a host,
so it is worse than absent).

It turns out not to matter, because the heartbeat already solved it. Every plugin
POSTs `/api/v1/hooks/status` with `host` (`hostname`), `actor_email`, `actor_name`
and `agent_family`. A shipped log chunk carrying those same fields is attributable
with no `machine_id` at all — provided the shipper uses the *same* values, which is a
contract and not a coincidence: it **inherits** them from the caller rather than
running its own cascade. Gemini keeps its actor resolution inline (module locals)
and the Claude bridge's `actor.sh` screens sandbox identities the others do not, so
an independently-resolving shipper could produce a second identity for the same
machine and orphan the logs. See **The actor is passed IN** in
[plugin-log-shipper.md](plugin-log-shipper.md).

**Correction to an earlier version of this section**, which claimed the roster
"dedups one row per `(host | actor-email | family)`". It does not: the fingerprint
is four parts, `` `${hostname}|${actorEmail ?? "anon"}|${family}|${agent}` `` (computed by the hooks router), where `agent` is the surface
(`claude_code` | `claude_desktop` | `cowork`, `codex_cli` | `codex_app`, …). And
because every surface of a family shares one log file, a chunk cannot resolve to a
single row at all — it is coarser than the roster. See **A log file is coarser than
a `coding_agent` row** in [plugin-log-shipper.md](plugin-log-shipper.md) for the
`log_source` table that replaces the row lookup.

**`actorEmail` is canonicalized before BOTH identity paths** — the roster
fingerprint above and the `log_source` resolution a shipped chunk goes through.
Canonical means: trim surrounding whitespace, then map absent, empty and
whitespace-only to the literal `anon`. Case is preserved, deliberately: the
roster's existing fingerprints were computed on the raw case, so folding it would
re-key every install already registered. This is not a detail — a heartbeat that
registers `"  "` and a chunk that resolves `anon` produce two different rows for
one machine, and the logs then attach to a row nobody looks at. All three shippers
implement exactly this (`ship-logs.sh`'s `resolve_actor`, `Resolve-ShipActor`,
`resolveActor`), and `tests/test_ship_logs.sh` asserts the absent / empty /
whitespace-only trio collapses to one value.

`machine_id` remains the only way to join a plugin row to an `endpoint_agent` row
on the same host. That join is capability B's contribution; if we want it for
plugin-only machines too, the place for it is one field on the heartbeat's roster
row — **not** in every shipped log chunk.

**The backend and agent work is now specced separately** in
[log-shipping-backend.md](log-shipping-backend.md) — the `/hooks/logs` route, the
`log_source` mapping, the durability requirement, the redaction boundary and the
log-upload task checklist, in one place that can be handed to whoever picks it
up. The open questions at the end of this file are the ones it does not settle.

## Phase 2 — the plugin shipper (this repo)

**Superseded by [plugin-log-shipper.md](plugin-log-shipper.md)**, which is the
build spec: files, argument contract, flow, state format, wire format, knobs and
tests. This section used to hold a first-cut design; it was replaced rather than
patched because five decisions in it changed, and a stale spec next to a live one
is worse than no spec.

What changed, so a reader of the old version is not surprised:

| was | now | why |
|---|---|---|
| one agent-agnostic shipper uploads **all six** logs | each plugin ships **only its own** log; `ROGUE_SHIP_ALL=1` for support | the coverage argument rested on an agent's own shipper being unreachable, which the call-site fix removed. Cross-vendor file reads are a bad line in a security review |
| `machine_id` in every chunk (phase 2b) | **not sent at all** | a random `log_source_id` identifies the source; `machine_id`'s only job is the endpoint-agent device join, which belongs on the roster row once |
| `host`/`actor_email` stored alongside the chunk | sent to the API, mapped to a random `log_source_id`, **never forwarded to the log store** | the privacy boundary is Rogue→log store, not plugin→Rogue |
| `$HOME` → `~` rewritten in the scripts | **redaction is server-side** | policy belongs where it is readable and testable, and can change without a plugin release |
| `<slug>.offset`, rotation detected by `size < offset` | `<key>.state` with `offset=` **and** `head=` (first line) | `size < offset` alone silently skips the new file's first `offset` bytes when a rotated log grows past the old offset before the next run |
| one chunk per run, 3600 s throttle | chunks loop until drained, 900 s throttle | a 10 MiB generation at 1 MiB/run would take ten runs to catch up |

The two sections above — **what the log is worth** and **why the plugin can
attribute its own logs** — still hold and are the motivation for that spec.

## Phase 3 — coding-agent log-upload task worker (endpoint agent)

Capability B, in the endpoint agent. Independent of phase 2:
it needs nothing from the plugins and the plugins need nothing from it.

Its distinct value over the plugin shipper is the reason to build it anyway: it
is **pulled on demand** by the backend rather than pushed on a session that may
not happen for days, it uploads the **whole file** rather than the tail past an
offset, and it carries a real `machine_id`.

A new task worker module, registered in
the task registry, with a new task type added to its enum.
(`#[serde(other)] Unknown` already covers older agents, so an older install
reports `unsupported` instead of breaking). From
the agent's task worker: tasks are backend-dispatched — the agent
polls, receives a `PendingTask` (`id`, `type`, `task_key`, `payload`), runs a
`TaskWorker`, and reports `Running → Uploaded → Succeeded | AgentFailed |
AgentTimeout | Unsupported`. (`Uploaded` **is** a real variant of `TaskStatus`
alongside the other five, used by
`adhoc_scan_upload_worker.rs:172`. An earlier version of this list omitted it and
then used it in the flow below.) An install is per-machine and the backend addresses one at a time,
which is literally "a task that runs on a single computer in a fleet".

**Which files.** Resolve the log directory the same way the dispatchers do, or the
agent reads a path nothing writes to:

1. `ROGUE_LOG_DIR` / `ROGUE_LOG_FILE` from the env file in use (the first of
   `/etc/rogue/env` or `C:\ProgramData\rogue\env`, the bundled `env`, and
   `~/.rogue-env` that holds `ROGUE_API_KEY`) — the MDM file is the one that
   matters here, and phase 1 made all eleven dispatchers honor it.
2. Otherwise `~/.rogue/logs/` (`%USERPROFILE%\.rogue\logs\`).

**`ROGUE_LOG_FILE` is an exact path and takes precedence over the glob** — when it
is set, collect that one file (plus its `.1`) and do **not** glob the six default
names, because in that configuration those files do not exist: every agent writes to
the one path. This is the same precedence the eleven dispatchers implement and
`tests/test_hook_logs.sh` asserts ("ROGUE_LOG_FILE (exact path) beats
ROGUE_LOG_DIR"), and its basename is arbitrary — so, exactly as for the plugin
shipper, that file's lines are attributed per line off `provider=`, never per file.

Otherwise glob `<dir>/{claude,codex,cursor,gemini,copilot,antigravity,kiro}.log` plus each
`.1`. Ship `.1` **before** its live file so the batch stays chronological.

**Payload.** Let the task narrow the request, all optional:

```jsonc
{ "agents": ["claude", "copilot"],   // default: all present
  "since":  "2026-08-01T00:00:00Z",  // default: whole file
  "max_bytes": 5242880 }             // per-agent cap, oldest lines dropped first
```

**Format.** Reuse the existing `LogShipRequest`
(`machine_id`, `agent_version`, `records: Vec<Box<RawValue>>`) and the
`/api/v1/endpoint/logs` route rather than adding a third log path. Unlike the
plugin shipper this side has a real JSON serialiser, so it parses the lines
itself into the same record shape the server produces from `content_b64`:

> **Batching is not optional, and `max_bytes` alone does not cover it.**
> the existing endpoint-log upload schema caps `records` at **1000 items**. A 5 MiB hook log
> is on the order of 65k lines, so a single-request upload is rejected outright.
> The worker must batch by **record count as well as bytes** — 1000 records per
> request, looping — or the task needs its own endpoint and schema. This is the
> only hard blocker in this section.

```jsonc
{ "ts": "2026-08-11T11:26:16Z", "provider": "claude", "event": "PreToolUse",
  "fields": { "outcome": "unconfigured" },
  "raw": "<the original line>" }
```

**Reuse from `log_ship/`.** Take `redact::redact_home_path` and
`redact_pii_in_text`. Do **not** take `capture.rs`/`shipper.rs`: that is a
`tracing` subscriber with an in-memory ring and a 60 s flush loop, which is the
wrong shape for reading files off disk on demand.

**Ordering and failure.** Report `Running` first (the trait's `pre_run` does it),
then `Uploaded`, then `Succeeded`. A missing log directory is **success with zero
records**, not a failure — the common case is a machine with no coding agent
installed. Only an unreadable-but-present file or a failed POST is `AgentFailed`.

> **`Succeeded` currently over-claims, and the route is why.**
> the existing endpoint-log sink fires the store
> client's ingest **without `await`** inside its `try/catch` — so an
> async rejection is not even caught — and returns `accepted: events.length`
> unconditionally, including when the store client is absent or
> its dataset variable is unset. A 2xx therefore does not mean the records
> landed. For a fire-and-forget tracing sink that is a defensible trade; for an
> **on-demand support collection** it means the task reports `Succeeded` while the
> logs someone asked for were dropped.
>
> Two acceptable fixes: give the route a strict mode that awaits the ingest and
> fails the request on error (preferable — the plugin shipper needs the same
> guarantee for its offset contract, see
> [plugin-log-shipper.md](plugin-log-shipper.md) §10), or stop having the task
> status claim upload success and report "submitted" instead. Do not leave it
> claiming `Succeeded` on the current behaviour.

Never touch the live log: read-only, no truncation, **and no offset file** — the
plugin shipper owns `~/.rogue/ship/`, and a second writer there would make both
lose lines.

## Open questions for the backend

- ~~**One store or two?**~~ **Settled:** hook logs go to their own dataset in the log store.
- ~~**Dedup key.**~~ **Settled:** duplicates are acceptable for diagnostics on an
  append-only store, so neither client does dedup work. A query can collapse on
  `(log_source_id, log_file, ts, raw)` if it ever matters.
- **Which redactions does the API apply**, and are they per-tenant? The scripts now
  upload verbatim, so redaction is entirely server-side, and it must run over
  **every** parsed field plus the raw line — the log format carries `path=`
  (absolute transcript paths) and `name=` (subagent display names) as well as
  `raw=`. the endpoint agent's redaction helpers already walk
  every string value and rewrite home paths; reuse them. Neither covers `name=` (not
  a path) or the `raw=` policy, so those two need an explicit decision.
- **The shared env-file chain is sourced without any ownership or permission check**,
  in all eleven dispatchers, all six heartbeats and both auto-updaters
  (`[ -r /etc/rogue/env ] && . /etc/rogue/env`, no validation). A writable
  `/etc/rogue/env` — mode 666 on a misconfigured or MDM-templated box — redirects
  `ROGUE_BASE_URL` and exfiltrates `ROGUE_API_KEY` plus every hook payload. Raised
  against the shipper in review; declining to fix it there alone, because the shipper
  is the *least* valuable of those readers (a diagnostics log versus full prompts and
  tool calls) and a one-script check is a false sense of coverage. Wants its own PR: a
  `safe_source` helper in sh, PowerShell and Node, refusing world-writable and
  non-root-owned system paths, with tests. Not a blocker for either capability here.
- **`log_source` needs a table, not a hash.** Log-store rows carry a random
  `log_source_id` resolved from `(org_id, hostname, actor_email, agent_family)`. A
  plain hash of those was the first proposal and is not a privacy boundary — work
  emails and hostnames are low-entropy enough inside one org to dictionary in
  milliseconds. A random id also makes erasure work on an append-only store:
  deleting the mapping row leaves the events unlinkable. See
  [plugin-log-shipper.md](plugin-log-shipper.md) §9.
- **Does a 2xx from the log routes mean durably ingested?** Today it does not (see
  the endpoint-log sink note in phase 3). The plugin shipper advances its offset
  on 2xx and forgets those bytes forever, so `/hooks/logs` must await its ingest and
  fail the request on error. This is a correctness requirement, not a preference.
- Should a log-upload assignment be creatable from the dashboard
  (support clicks "collect logs" on a machine), or only by internal tooling? That
  decides whether B needs UI work at all.
