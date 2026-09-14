# Plugin log shipper — implementation design

Capability A from [log-shipping.md](log-shipping.md). This is the build spec: what
files, what contract, what each step does and why. Review this before code lands.

Storage decision is settled: hook logs go to a **separate dataset in the log store**, not into
the endpoint agent's table. the log store is append-only, so at-least-once
delivery just means an occasional duplicate event and there is **no client-side
dedup work** — a query can collapse on `(log_source_id, log_file, ts, raw)` if it
ever matters.

## Files

```text
plugins/{rogue,codex,cursor,copilot,antigravity,kiro}/scripts/ship-logs.sh    byte-identical ×6
plugins/{rogue,codex,cursor,copilot,antigravity,kiro}/scripts/ship-logs.ps1   byte-identical ×6
plugins/gemini/scripts/ship-logs.mjs                                     Node-only, per repo rule
tests/test_ship_logs.sh
tests/test_ship_logs.ps1
```

Callers (one line each, no `hooks.json` change anywhere):

| plugin | call site |
|---|---|
| claude, codex, copilot, antigravity, kiro | `scripts/heartbeat.sh` / `heartbeat.ps1` |
| gemini | `scripts/heartbeat.mjs` |
| cursor | the inline beacon block in `hook.sh` / `hook.ps1` (it has no heartbeat script) |

**Every one of those call sites now runs on a PER-TURN trigger as well as a session
one** — `Stop` (claude, codex, antigravity), `agentStop` (copilot), `stop` (cursor),
`AfterAgent` (gemini). Before that, a session left open for days shipped exactly ONCE,
at its start, when the log was still nearly empty. Only the claude plugin got a new
`hooks.json` group for it; the rest fire from inside the dispatcher, because Codex,
Copilot and Gemini fingerprint the hook definition and would have skipped every Rogue
hook until each user re-approved via `/hooks`.

**The shipper call sits OUTSIDE the beacon throttle** that the per-turn trigger
introduced (`scripts/shared/beacon.{sh,ps1}`, 900 s default). A throttled beacon still
means a turn happened, and the log is worth draining either way; the shipper's own
interval is what limits it.

**Never behind an agent-specific gate.** `plugins/rogue/scripts/heartbeat.sh` opened
with `[ -z "${CLAUDE_CODE_ENTRYPOINT:-}" ] && exit 0`; a shipper call anywhere below
that inherits it and every future guard, so a Claude build that stopped exporting one
env var would silently stop shipping logs with no other symptom. The heartbeat's
guards decide whether to *beacon*, which is a different question from whether to
ship.

As implemented, that gate now wraps **only the beacon POST** (both `.sh` and `.ps1`,
in lockstep) and the shipper call sits outside it. The beacon fires exactly when it
did before — the gate moved, its condition did not — and only the Claude plugin needed
this: Codex deliberately has no entrypoint gate, and the others have none either.

**The call sits after the beacon POST when both run**, so the roster row for this
install exists before its logs arrive. That is an ordering *preference*, not a
prerequisite: the backend resolves-or-creates the `log_source` row from the identity
fields the shipper itself sends (§9), which is precisely why the call can be outside
the gate rather than sequenced behind the POST.

No extra backgrounding anywhere except Cursor. The four `heartbeat.*` callers are
already spawned detached, so they invoke the shipper inline; Cursor's call site is
inside the **synchronous** dispatcher, which is holding Cursor's session-start
decision on stdout, so there it must be detached with the same double-fork the
heartbeat uses. The PowerShell callers spawn a child process rather than dot-sourcing
or `[scriptblock]::Create`-ing in place, because in-process the shipper's `$script:`
writes resolve against the *caller's* scope and its `exit 0` would end the caller —
which in `cursor/scripts/hook.ps1` means exiting before the relayed response is
printed. Gemini's caller imports the module in-process instead, since ESM scope is
its own and `main()` does not exit.

`scripts/build-release.sh` needs **no change**: every plugin is staged with
`cp -R plugins/<x>`, so a new file in `scripts/` ships automatically.

**No heartbeat payload or identity change, and no new client-side identifier.** The
heartbeat DOES need the one call-site edit described above — without it nothing
invokes the shipper. What does not change is its `/hooks/status` body: the backend
does a resolve-or-create of a `log_source` row from the shipper's identity fields
and forwards only that row's random id (§9), so no new field is needed anywhere in
the beacon.

## Argument contract

```sh
sh   ship-logs.sh  <plugin-root> <shipper-slug> <shipper-version> <agent-family>
ps   ship-logs.ps1 <plugin-root> <shipper-slug> <shipper-version> <agent-family>
node ship-logs.mjs <plugin-root> <shipper-slug> <shipper-version> <agent-family>
```

All per-plugin variation lives in the arguments — that is what lets the five copies
be **byte-identical** and lets `cmp` enforce lockstep instead of review. The
plugin-root var name is the one thing that genuinely differs
(`CLAUDE_PLUGIN_ROOT`, `PLUGIN_ROOT`, `CURSOR_PLUGIN_ROOT`, `extensionPath`, …) and
the caller already holds it. `<shipper-version>` is likewise already resolved by
the heartbeat.

**`<agent-family>` is passed in and never derived from the slug.** The two are
deliberately different vocabularies — Codex's log slug is `codex` but its
`agent_family` is `openai`, and the roster labels are `gemini_cli` /
`github_copilot` where the slugs are `gemini` / `copilot` (see **The hook log** in
`CLAUDE.md`). The heartbeat already hardcodes the family in its `/hooks/status`
body (`plugins/rogue/scripts/heartbeat.sh:60`), so it is free to pass, and a
slug→family table inside a byte-identical script would be one more thing to keep in
lockstep.

**No-argument invocation implies `ROGUE_SHIP_ALL=1`.** A bare
`sh .../ship-logs.sh` has no slug, so "ship my own log" is not a question it can
answer — an earlier draft said the slug falls back to `unknown`, which would make
it look for `unknown.log` and ship nothing. Since the only caller without arguments
is a human collecting diagnostics, no-args means *collect everything*, with
`shipper` / `shipper_version` reported as `unknown` in the envelope. The plugin root
is still derived from `$0`/`$PSCommandPath` so the bundled `env` is not skipped.
`/rogue:status` passes the arguments explicitly — see **Support use**.

## Flow

```text
 1. Git Bash stand-down: uname = MINGW*/MSYS*/CYGWIN* → exit 0   (ps1 owns Windows)
 2. load ONE env file, the first holding ROGUE_API_KEY — the SAME rule the dispatchers use:
      /etc/rogue/env            (POSIX)   |  C:\ProgramData\rogue\env  (Windows, MDM)
      <plugin-root>/env
      $HOME/.rogue-env          (POSIX)   |  %USERPROFILE%\.rogue-env   (Windows)
    its values override the process env
 3. no ROGUE_API_KEY → exit 0
 4. resolve which log file(s) to ship — own slug only by default
 5. mkdir -p ~/.rogue/ship
 6. per-file: throttle check on .last-<key>; too recent → skip this file
 7. per-file: acquire .lock-<key> (mkdir); stamp .last-<key> immediately
 8. host from hostname; actor_email/actor_name INHERITED, never re-resolved (§9)
 9. ship chunks until drained or the run budget is spent
10. release the lock; exit 0
```

Every path `exit 0`, no `set -e`. Two separate disciplines, both load-bearing:

- **No `set -e`** because non-zero is *normal* here: `curl` returns 7 with no
  network, `grep` returns 1 on no match. Under `set -e` either aborts the script
  mid-run, skipping the state write and the lock release.
- **`exit 0` on every path** because a non-zero exit means something to the caller.
  Repo-wide rule with real teeth elsewhere — Copilot's `preToolUse` is
  fail-**closed**, so a non-zero hook exit *denies the tool*. The shipper is not on
  that path, but the rule is uniform on purpose: a broken shipper must be silence,
  never a failure, and never the reason enforcement breaks.

### 5. Which file — its own, not everyone's

**Each plugin's shipper uploads only its own agent's log.** Claude's copy ships
`claude.log`; Cursor's ships `cursor.log`.

An earlier draft had every copy ship all six known logs, for coverage: if an
agent's own shipper never runs, only another agent's copy can retrieve its log. The
concrete case was Claude's heartbeat exiting at the `CLAUDE_CODE_ENTRYPOINT` gate —
**which the call-site fix above already eliminates**, taking the main justification
with it. What remained (logs from an uninstalled plugin, still on disk) is not
worth the costs:

- **Least astonishment.** A Cursor-only install reading and uploading a file
  written by another vendor's tooling is a bad line in a security review.
- **Data minimisation.** "The Cursor plugin uploads the Cursor plugin's own
  diagnostic log" is a sentence that fits in a DPA. The other one needs a
  paragraph.
- **Uninstall would not mean uninstall** — remove the Claude plugin, keep Cursor,
  and `claude.log` keeps being uploaded.
- **Less code**: the six-name allowlist and its "never glob `*.log`" guard both
  disappear.

Path resolution matches the dispatchers exactly, or the shipper reads a path
nothing writes:

- `ROGUE_LOG_FILE` set → that file. **All six agents write to it in this mode**, and
  its basename is arbitrary (`/var/log/rogue-all.log`), so neither the envelope nor
  the filename can attribute the chunk — see **Attribution is per line** below.
- else `ROGUE_LOG_DIR`, else `$HOME/.rogue/logs`, file `<slug>.log`.

**`ROGUE_SHIP_ALL=1` restores the ship-everything behaviour** for the support case
— on a call with a customer, one invocation collects the whole machine. Manual and
opt-in, never the default.

#### Attribution is per line, not per file

`ROGUE_LOG_FILE` collapse mode breaks any file-level identity scheme, and the break
is silent in the worst way: one chunk holds interleaved `provider=claude`,
`provider=codex`, `provider=cursor` lines, so tagging it with the shipping plugin's
`agent_family` would file **Claude lines under `openai`**, and the server cannot
recover the family from a basename that is not a known slug.

So the server attributes **each line**, keyed on its `provider=` token, and the
envelope's `agent_family` is a **hint used only as a fallback** for a line that has
no `provider=` (a torn line, or a future format change). In the normal per-file
configuration every line in `claude.log` says `provider=claude`, so per-line and
per-file agree and nothing changes; collapse mode simply works.

This costs nothing on the server — the ingest already emits one event per
line, so deriving that line's `log_source` alongside its other fields is the same
loop. It costs nothing on the client either: no slug table, no per-line work, no
new field.

> **This reverses my earlier recommendation to delete `provider=`.** That
> recommendation rested on one finding — nothing consumed the token, so it was
> write-only overhead. Per-line attribution gives it a consumer, and a load-bearing
> one: it is the *only* thing that can attribute a line in collapse mode. Keep it.
> The alternative is coherent but worse — declare `ROGUE_LOG_FILE` unsupported for
> shipping, so any fleet that set it (it exists purely for pre-split back-compat,
> and MDM configs are exactly where it would live) silently ships nothing.

### 7–8. Throttle and lock

`~/.rogue/ship/` holds all state, keyed per log file (`<key>` = the log's basename
minus `.log`, so `ROGUE_LOG_FILE` collapse mode shares one key across agents,
which is correct — it is one file):

```text
<key>.state      offset= head= size= path= for that log file (see §10)
.last-<key>      unix seconds of the last attempt
.lock-<key>/     directory used as a mutex
```

**Keyed per file, not global.** A shared `.last` plus per-agent shipping would
starve: whichever agent starts a session first stamps it and blocks every other
agent for the whole interval.

#### The throttle, and why it exists at all

`ROGUE_SHIP_MIN_INTERVAL`, **default 900 s**. `.last-<key>` is a one-line Unix
timestamp:

```text
$ cat ~/.rogue/ship/.last-claude
1786512847
```

Content rather than the file's mtime because reading mtime portably needs `stat`,
whose flags differ between BSD and GNU — the same reason phase 1 reads size with
`wc -c`.

It is **not** a bandwidth measure. A run with nothing new makes **no HTTP request
at all** (offset equals size, nothing to send), so the happy path is already free.
The throttle exists to bound *our own worst case*:

- **Crash-loop guard.** `.last-<key>` is stamped the instant the lock is taken,
  **before any upload**. So a shipper that dies before persisting its offset — a
  bug in our code, a killed process, an OOM — reruns at most once per interval
  instead of on every single session start. Without it, a build that uploads 1 MiB
  and then crashes before writing state would re-upload that megabyte on all 50 of
  a heavy user's daily sessions, forever, until a fix propagates (24 h on the
  auto-update cycle at best, and only after they restart sessions). With it, the
  blast radius is 4 runs an hour.
- **Rate ceiling per machine**, for the same reason, on any future bug that makes
  the shipper chattier than intended.

**Why 900 s and not less:** the trigger is not a timer, it is a *turn* — so the
interval is the floor on how fresh a log can be, and 15 minutes puts a support
request inside the window while it is still warm. Going to 60 s would multiply the
crash-loop ceiling by 15 for no practical gain.

This paragraph used to argue from *session start* being the only trigger, and
concluded that "someone in one four-hour session ships nothing during it no matter
what the interval says". That was true and was the bug: a long session's log sat on
disk unshipped for its whole lifetime. Every plugin now also ships on a per-turn
trigger, so the interval finally does the job this number was chosen for.

#### The lock

`mkdir .lock-<key>` — creating a directory is a single atomic filesystem operation,
succeed-or-fail-because-it-exists with no gap. The naive shell version
(`if [ ! -e lock ]; then touch lock; fi`) is two operations and both processes can
pass the test before either touches. `New-Item -ItemType Directory` fails the same
way on Windows, so one implementation covers both.

What it protects is the window between **reading the state file** and **writing the
new offset back** — which includes the HTTP request, up to 15 s. Two sessions of
the same agent starting together (two terminal tabs, common) would otherwise both
read `offset=5000`, both upload bytes 5000–5400, both write `offset=5400`:
duplicate rows, plus a real chance of a torn state file. In `ROGUE_LOG_FILE`
collapse mode the contenders are different agents instead, and the same lock
covers it because the key is the file.

- Cannot acquire → skip that file silently.
- A lock whose mtime is **older than 600 s is stale**: remove it, one retry. A
  killed shipper must not wedge the feature permanently.
- Released via `trap … EXIT INT TERM` / `try/finally`, so an early return still
  releases it.
- **A `.last-<key>` in the future** (clock stepped back, bad write) is treated as
  stale rather than blocking shipping until the clock catches up.

### 9. Identity — send the PII, store the id

The privacy boundary is **Rogue → the log store**, not plugin → Rogue. Every hook POST and
every heartbeat already sends `host` + `actor_email` to our own API, so sending
them to `/hooks/logs` adds no new exposure. What must stay clean is the log store's
dataset, whose retention and access controls are not the main database's.

So the shipper sends the identity fields as-is and the **backend resolves them to an
opaque id before ingesting**:

```text
plugin  → POST /hooks/logs   host, actor_email, actor_name, agent_family,
                             log_file, chunk
backend → resolve-or-create log_source row for
          (org_id, host, actor_email, family-of-this-line)  → random uuid
store   ← log_source_id, log_file, offset, chunk                  (no PII)
```

#### A log file is coarser than a `coding_agent` row

The first draft said "look up `coding_agent` by `(host | actor-email | family)`,
the triple the roster dedups on". **That is wrong on both halves**, and the second
half is the interesting one.

The roster's real dedup key is **four** parts, not three —
`` `${hostname}|${actorEmail ?? "anon"}|${family}|${agent}` ``
(the roster fingerprint the hooks router computes, which the database column
comment repeats). `agent` is the
*surface*: `claude_code` | `claude_desktop` | `cowork`, `codex_cli` | `codex_app`,
`antigravity_ide` | `antigravity_cli`.

But **one log file is written by every surface of its family.** All three Claude
surfaces share one plugin install, one `$HOME`, and therefore one
`~/.rogue/logs/claude.log`. So a chunk of that file does not belong to one
`coding_agent` row — it belongs to *all* the rows for that host, actor and family.
Sending the shipping session's own surface (which the heartbeat does know, from
`CLAUDE_CODE_ENTRYPOINT`) would attach a multi-surface chunk to whichever surface
happened to open a session first. That is not under-specified, it is incorrect.

**So the log's identity is genuinely the triple** — the same granularity as the file
name — and the fix is to stop pretending it is a `coding_agent.id`:

- The shipper sends `agent_family` (new field, and the reason it is now an
  argument) as a fallback hint; per-line `provider=` drives the real attribution.
- The backend keeps a **`log_source` table** — `id` (random uuid), `org_id`,
  `hostname`, `actor_email`, `agent_family`, unique on the four — and resolves or
  creates a row per `(org, host, actor, family)`. Only `log_source_id` reaches
  the log store.
- "Show me this roster row's plugin log" is a lookup of that row's own columns in
  `log_source`. No schema change to `coding_agent`, no PII crossing over.
- The UI surfaces plugin logs at machine + family granularity, which is what the
  file actually is. A roster row for `claude_desktop` shows the same log as
  `claude_code` on that machine — correct, not a bug.

**If per-surface attribution is ever needed**, the only honest way is to stamp the
surface into each *line* at hook time (the dispatcher knows it) and let the server
split. That is phase-1 format scope, deliberately not done here.

#### A plain hash would not have been a privacy boundary

An earlier version of this section specified
`log_source_id = hash(org_id | host | actor_email | agent_family)` and called it
opaque. **It is not.** Hostnames and work emails are extremely low-entropy,
especially within one organisation: `firstname@rogue.security` over a known
employee list, `<firstname>-mbp` / `<firstname>-macbook` over the same list, six
known families. That is a few thousand candidates — a dictionary attack completes
in milliseconds, so anyone with store-only access recovers every hostname and email
exactly. It would have been pseudonymisation dressed up as removal, which is worse
than an honest plaintext field because it invites reliance it cannot support.

Three ways to fix it, in increasing strength:

1. **Salted hash** — no better. The salt must be stored, and whoever can query
   the store is inside the same system.
2. **HMAC under a server-held key** — genuinely resistant, and it keeps the
   derive-from-any-row property.
3. **A random id in a `log_source` table** — what this spec now requires.

(3) beats (2) on two counts beyond the crypto. **Erasure**: the store is append-only, so
an HMAC scheme cannot honour a delete request without rewriting immutable data,
whereas deleting the `log_source` row leaves the events permanently unlinkable —
which is precisely what "erase this person" requires. And **rotation**: there is no
key to rotate, leak, or fail to rotate.

Cost is one indexed lookup per distinct `(host, actor, family)` per request,
in-process cacheable, and at most six per chunk even in collapse mode.

**Note this reintroduces resolve-or-create**, which §9 removed a revision ago for a
different reason. That removal was about not inventing a `coding_agent` row with a
guessed `agent` surface. `log_source` has no surface column and no guessing: the
four fields all arrive in the request, and creating the row *is* the correct
behaviour when a machine ships before it beacons.

**The plugin carries no identifier of its own.** An earlier draft proposed a
generated `install_id` in `~/.rogue/install-id`; that was inventing a primary key
the database already has. Deleted. `machine_id` is likewise **not** sent — its only
job was joining to the endpoint agent's rows for the same device, and that belongs
on the roster row once (from the heartbeat), not in every log chunk.

**A chunk arriving before any heartbeat is fine.** It creates its own `log_source`
row from fields that are all present in the request, and the `coding_agent` row
joins to it whenever the heartbeat lands. The log ingest never touches
`coding_agent`, so it can never invent a roster row with a guessed `agent` surface
— which, given the four-part fingerprint, a `coding_agent` lookup would have had
to.

#### The actor is passed IN. The shipper never re-resolves it.

**Hard rule, and the most fragile thing in this document.** "The shipper resolves the
same cascade as the heartbeat, so the two cannot disagree" was hand-waving. Nothing
enforces it, and two of the six plugins already break it:

- **Cursor** resolves `actor_email` / `actor_name` as **shell locals** in
  `plugins/cursor/scripts/hook.sh:147-158` — never exported, so a child process
  inherits nothing.
- **Gemini** resolves them as **module locals** in `heartbeat.mjs:36-37` (a duplicate
  of `hook.mjs`'s `resolveActor`), never placed in `process.env`.

And the cascades are **not** the same, so an independent re-resolve does not merely
risk drift, it produces it. On a machine with no `git config --global user.email`:

| | fallback | value |
|---|---|---|
| `scripts/actor.sh` (claude, codex, copilot, antigravity) | `hostname` | `amos-mbp` |
| Cursor `hook.sh:151-158` | `$USER@$(hostname)` | `amos@amos-mbp` |

Two identities for one machine, so the heartbeat's roster row and the shipper's
`log_source` row would never meet. Nothing errors; the logs just attach to nothing.

So the resolution order is:

1. **Inherited `ROGUE_ACTOR_EMAIL` / `ROGUE_ACTOR_NAME` from the environment.** For
   the four `actor.sh` plugins this is automatic — `actor.sh` already ends with
   `export ROGUE_ACTOR_EMAIL ROGUE_ACTOR_NAME`, so a child of the heartbeat inherits
   the exact values the beacon sent.
2. **Otherwise, source `<plugin-root>/scripts/actor.sh` if it exists** — the manual
   support invocation, where no heartbeat ran to export anything.
3. **Otherwise skip the file** and log `outcome=skip reason=no-actor`. **Do not
   invent an identity and do not carry a private cascade.** A wrong identity creates
   an orphaned `log_source` row, which is strictly worse than not shipping: the
   logs are uploaded, billed and stored, and joined to nothing.

**Two caller changes fall out of this**, and they are the whole cost:

- `plugins/cursor/scripts/hook.sh` — `export actor_email`/`actor_name` as
  `ROGUE_ACTOR_EMAIL`/`ROGUE_ACTOR_NAME` before invoking the shipper (`hook.ps1`
  likewise).
- `plugins/gemini/scripts/heartbeat.mjs` — pass them in the child's env:
  `spawn(…, { env: { ...process.env, ROGUE_ACTOR_EMAIL: email, ROGUE_ACTOR_NAME: name } })`.

I chose passing over the alternative (give Cursor and Gemini a shared actor helper
that heartbeat and shipper both call). Passing is correct **by construction** — the
shipper uses the identical bytes the beacon used, because they *are* those bytes —
whereas a shared helper leaves two implementations, in two languages, free to drift
again. It also needs no new files.

*Out of scope, noted so nobody "tidies" it casually:* Cursor's `$USER@$(hostname)`
fallback differing from `actor.sh`'s `hostname` is pre-existing. It is not a roster
bug (the fingerprint includes the family, so those rows were always distinct) and
changing it would re-key existing Cursor installs. It is, however, exactly why the
shipper must not have a cascade of its own.

#### One canonical `actor_email`, or the join silently fails

The roster fingerprint uses `` `${actorEmail ?? "anon"}` `` (`hooks.ts:343`). If the
`log_source` lookup keys on the raw value instead, a machine whose email is absent
in one path and `""` in the other produces two different identities and the log
never joins its roster row. Nothing errors; the logs simply attach to nothing.

**So one function normalises the value, used by both paths**: trim whitespace, and
map empty to the literal `anon` — exactly `?? "anon"` extended to cover `""` and
`"   "`, which is what a shell `git config user.email` miss actually yields (the
heartbeat sends an empty string, not JSON null).

**Deliberately not lower-casing.** It would be more correct, and it is a *breaking*
change: the roster's existing fingerprints were computed on the raw case, so folding
it re-keys every install and every machine gets a duplicate row. If we want case
folding it is a migration of `coding_agent.fingerprint`, not a line in this spec —
and until then `log_source` must match the roster's behaviour rather than improve on
it, or the two disagree for anyone whose git email has a capital letter.

`host` is `hostname` — resolved locally, since every plugin's heartbeat uses exactly
that call with no cascade. `actor_email` / `actor_name` are **inherited, never
re-resolved** — see **The actor is passed IN** above for the order, the two caller
changes it requires, and why an independent cascade in the shipper would silently
orphan Cursor's logs.

### 10. Not re-reading what was already exported

State is one file per log, `~/.rogue/ship/<key>.state`, **four** `k=v` lines. Every persistence writes all four — a write that omitted `path=` would leave the next run unable to tell this file from another agent's log of the same basename, and one that omitted `size=` would drop the `.1` recovery gate:

```text
offset=12345          bytes the backend has ACCEPTED for this file
head=MjAyNi0w…        base64 of the file's FIRST LINE *including its newline*
size=98304            the file's size when that offset was persisted
path=/Users/…/claude.log   absolute path the offset belongs to
```

**`path=` exists because the key is a basename.** `/a/claude.log` and
`/b/claude.log` both key to `claude`, so changing `ROGUE_LOG_DIR` (an MDM policy
edit, a relocated home) would point the shipper at a different file holding the
previous file's offset. The `head` check turns that into a re-ship rather than
silent loss, but it is cheaper and clearer to detect it directly: **if `path` does
not match the file being shipped, treat the state as absent** (offset 0). Recording
the path rather than hashing it into the filename is deliberate — a digest would
have to be byte-identical across sh, PowerShell and Node, the same constraint that
rules out a checksum for `head`. Collapse mode still shares one key *and* one path,
so it keeps sharing one state file, which is correct.

**`path=` must be NORMALIZED, not merely absolute** — corrected during
implementation, where the first version simply prefixed `$PWD`. PowerShell's
`GetFullPath` and Node's `path.resolve` both *also* collapse duplicate separators
and `.`/`..` segments, so a lexical prefix left `/logs//claude.log` (what a
`ROGUE_LOG_DIR` with a trailing slash produces, and a very plausible MDM-pushed
value) comparing unequal to `/logs/claude.log` from another implementation. Each
shipper then read the other's state as a *different file*, reset the offset and
re-shipped the whole log — duplicate data on any machine with two agents
installed. The sh copy carries an explicit segment walk to match the other two.
Symlinks are still **not** resolved anywhere: that would make `/private/tmp` and
`/tmp` disagree on macOS, which is the same class of bug in the other direction.

```text
off, stored_head, stored_size, stored_path = read state
if stored_path != normalize(file): off = 0; stored_head = none  # different file
                                      # off = 0 also if absent or non-numeric
                                      # normalize: lexical, collapses // . ..,
                                      # never resolves symlinks
size = wc -c < file                   # NOT stat — BSD and GNU differ on flags
head = base64(first line of file)     # the COMPLETE first line INCLUDING its
                                      # \n, when that \n falls inside the 4096
                                      # byte window; the whole window otherwise.
                                      # Byte-for-byte identical in sh, PowerShell,
                                      # Node and the tests - an implementation
                                      # that dropped the \n would read an
                                      # unchanged file as rotated and re-upload it

rotated = (size < off) or (head is known and head != stored_head)

if rotated:
    # .1 is a whole generation (up to ROGUE_LOG_MAX_BYTES), so it needs the same
    # bounded chunk loop as the live file — one request cannot carry 10 MiB.
    if file.1 exists and base64(first line of file.1) == stored_head
       and size(file.1) >= stored_size:
        while off < size(file.1) and run budget remains:
            ship_one_chunk(file.1, off, rotated=true)
            on failure: return        # state untouched; next run resumes .1
            off += n; persist offset=off head=stored_head size=stored_size path=normalize(file)
        if off < size(file.1): return # budget spent — finish .1 next run, do NOT
                                      # reset, or the rest of it is lost
    off = 0; persist offset=0 head=<head> size=<size> path=normalize(file)  # .1 drained
while off < size and run budget remains:
    ship_one_chunk(file, off, rotated=false)
    on failure: return
    off += n; persist offset=off head=<head> size=<size> path=normalize(file)

ship_one_chunk(f, off, rotated):
    n     = min(size(f) - off, ROGUE_SHIP_MAX_BYTES)
    chunk = bytes [off, off+n)  →  temp file
    n     = n - trailing_fragment(chunk)         # whole lines only
    if base64(first line of f) != head_of(f): fail   # rotated under us — discard
    send(chunk, off, n, rotated)
```

**The offset advances only on 2xx.** A non-2xx, transport failure or timeout leaves
the state untouched, so the same range is re-sent next run. Nothing is ever marked
exported on unconfirmed data.

> **Requirement on the endpoint, not a client concern — but load-bearing for this
> contract.** A 2xx from `/hooks/logs` is the *only* thing that makes the plugin
> forget a byte range, so 2xx must mean **durably accepted**. The existing endpoint
> sink is the counter-example to copy from carefully:
> the existing endpoint-log sink fires the store
> client's ingest **without `await`** inside a `try/catch` — so an async
> rejection is not even caught — and returns `accepted: events.length`
> unconditionally, including when the store client is absent or the dataset env var is
> unset. Built that way, `/hooks/logs` would 200 on a dropped chunk and the shipper
> would advance its offset past data that never landed: **silent, permanent loss**,
> which is exactly what the offset design exists to prevent. The ingest must be
> awaited and its failure must produce a non-2xx.

**Chunks loop until the file is drained**, rather than one chunk per run. With a
10 MiB rotation cap and a 1 MiB per-request size, one-chunk-per-run would take ten
runs to catch up — so `ROGUE_SHIP_MAX_BYTES` is the per-*request* size and the loop
is bounded by `ROGUE_SHIP_MAX_RUN_BYTES` (default 10 MiB, i.e. one whole
generation) plus a hard iteration guard.

#### Why `head` is the first LINE, not the first N bytes

The obvious version — fingerprint the first 200 bytes — **misfires on a young
file**:

```text
run 1:  file is one 60-byte line     → head = b64(60 bytes)
run 2:  file now has 4 lines         → head = b64(bytes 0..200) spans lines 1–3
        head != stored_head          → "rotated!" → offset reset to 0
        → the whole file is re-shipped, every run, until it passes 200 bytes
```

Not data loss (duplicates), but it makes the check useless for exactly the small
files where it should be cheapest. A **line** is stable instead: logs are
append-only, so once a `\n` exists at byte *k*, bytes 0..*k* never change again. If
there is no `\n` yet (a partially written first line), the head is "unknown" and
the check falls back to `size < off` alone.

**The scan window is 4096 bytes, not the 200 an earlier draft of this document
specified** — corrected during implementation, where 200 turned out to describe a
feature that could never fire. A real hook line is a timestamp, `provider=`,
`event=`, `outcome=` and up to 400 characters of `raw=`, so **500–700 bytes is
typical**: within a 200-byte window a normal log's first line contains no newline
at all, the head is therefore permanently "unknown", and the rotation check
silently degrades to `size < off` forever — exactly the hole `head=` exists to
close. 4096 covers a long line with room to spare while staying a single small
read.

#### Why `head` exists at all

`size < off` alone has a **silent data-loss hole**. Rotation resets the file to
zero length, but if the new file grows *past* the old offset before the next run,
`size > off` and no rotation is detected:

```text
off = 10 MiB, everything shipped
dispatcher rotates at the cap → old file becomes .1, new file starts at 0
new file passes 10 MiB before the next run
size > off  →  looks like normal growth
we ship [10 MiB, size) and skip the new file's first 10 MiB — silently
```

At a 10 MiB cap and a 15-minute interval this needs an implausible write rate. An
admin who sets `ROGUE_LOG_MAX_BYTES=65536` makes it routine, and the symptom is
missing lines with nothing to indicate they were missed.

**A base64'd line, not a hash**, for one hard reason: all three languages share
`~/.rogue/ship/`. In `ROGUE_SHIP_ALL` mode Gemini's `.mjs` shipper writes state
that Claude's `.sh` shipper reads next session. A `cksum`/CRC would have to be
bit-identical across sh, PowerShell and Node — reimplementing POSIX `cksum` twice
for no gain. Base64 of a byte range is identical everywhere by construction, and
the comparison is string equality with no collision argument to make.

Rejected: **inode** (reliable on POSIX, but PS 5.1 cannot read a file id without
P/Invoke) and **Windows creation time** (NTFS file-system tunneling makes a file
recreated under the same name within 15 s inherit the old creation time, silently
defeating it).

#### The first-line fingerprint is not collision-free — accepted, with a second condition

A 4096-byte first-line window is not a digest, so two generations whose first lines
are byte-identical compare equal, and the shipper could accept the wrong `.1`, send
it at the old offset and then reset. Stated plainly rather than papered over:

- **What a collision requires.** A rotated log's first line begins with a
  second-resolution timestamp, then `provider=`, `event=`, `outcome=`. Two
  *consecutive* generations must match on all of it — same second, same event, same
  outcome. Between rotations the dispatcher writes a whole `ROGUE_LOG_MAX_BYTES`
  generation (10 MiB, ~130k lines), so this needs two 10 MiB bursts inside one
  second from a process that writes one line per hook event. Not reachable at the
  default; reachable only with an absurdly small cap.
- **What it costs when it happens.** Wrong bytes attributed to one offset, then a
  reset — garbled or duplicated lines in a diagnostics dataset. Not silent loss of
  the live log.
- **Second condition added:** `.1` is accepted only if `size(file.1) >=` the `size`
  recorded in state at the last accepted chunk. A different generation almost
  certainly has a different size, so the two conditions are independent.

**A collision-resistant digest was considered and rejected on portability**, not on
merit. It would have to be byte-identical across sh, PowerShell and Node, which
share `~/.rogue/ship/` — and sh has no guaranteed hasher (`sha256sum` on Linux,
`shasum` on macOS, `openssl` sometimes, none of them universal), while
`Get-FileHash` returns UPPERCASE hex and `shasum` lowercase. Making that safe needs
the state file to tag which algorithm produced the value and a fallback path when a
machine has no hasher — machinery whose failure modes are more likely than the
collision it prevents. If this ever needs revisiting, tag the kind (`head=sha256:…`
vs `head=b64:…`) rather than silently changing the encoding.

**Validating `.1`'s head against the stored head** is what stops a double rotation
from re-shipping a generation we already sent: if `.1` is not the file the offset
belongs to, skip it and reset.

#### Rotation *during* a read (the TOCTOU)

```text
t0   size = 5400, head = H
t1   dispatcher hits the cap → renames to .1, starts a new empty file
t2   we extract bytes [5000, 5400)  ←  from the NEW file
```

That ships the new file's first 400 bytes labelled `offset=5000`, loses the old
file's real tail, and then persists `offset=5400` over the top of it. Window is
milliseconds and rotation is once per 10 MiB, but the corruption is silent and
permanent.

**Fix: re-read the head after extracting the chunk** and discard the chunk if it
changed (the `if base64(first line) != head: return` line in the pseudocode). One
extra short read per chunk; the next run then handles the rotation properly.

#### Chunks end on line boundaries

Hitting `ROGUE_SHIP_MAX_BYTES` mid-line would put a line's first half in chunk *N*
and its second half in chunk *N+1* — two events, two corrupt lines instead of
one good one. Same hazard from a torn concurrent append at the tail.

So every chunk is **trimmed back to the last `\n`** and the offset advances by the
trimmed length. Byte length of the trailing fragment, without `jq` or `python3`:

```sh
LC_ALL=C awk 'BEGIN{RS="\n"} END{print length($0)}' "$chunk"
```

**That one-liner alone is wrong** and would have shipped a 1-byte-short chunk on
every run. With `RS="\n"`, `END{$0}` is the *last record*, not the text after the
final separator — verified under both `awk` and `dash`'s `awk`:

```text
printf 'a\nb\n' → prints 1   (must be 0: the chunk already ends on a boundary)
printf 'a\nb'   → prints 1   (correct)
```

So a newline-terminated chunk would lose its final byte, the offset would advance
one short, and the next chunk would re-send a stray `\n` — forever. Test the final
byte first:

```sh
if [ "$(tail -c 1 "$chunk" | od -An -tu1 | tr -d ' \n')" = "10" ]; then
  frag=0                                    # already ends on a line boundary
else
  frag=$(LC_ALL=C awk 'BEGIN{RS="\n"} END{print length($0)}' "$chunk")
fi
```

Verified against all four cases under `sh` and `dash`: `a\nb\n` → 0, `a\nb` → 1,
empty → 0, and a chunk with no newline at all → its whole length (which lands in the
"no newline in the chunk" branch below).

`LC_ALL=C` so `length()` counts bytes and not characters. Trivial in PowerShell and
Node (scan back for `0x0A`).

#### A line longer than one request

"If the chunk has no newline, ship it whole" was **incoherent** as written: the chunk
was already truncated to `ROGUE_SHIP_MAX_BYTES`, so "whole" shipped a *partial* line —
contradicting the rule it was an exception to. Resolved explicitly, because "never
send a partial line" is the invariant the server parser depends on:

```text
if the chunk [off, off+n) contains no \n:
    search forward for the next \n, in overlapping windows of
    ROGUE_SHIP_MAX_LINE_BYTES, bounded at 64 windows (256 MiB at the defaults)

    found, line <= MAX_LINE_BYTES  → send ONE oversized request carrying exactly
                                     that line
    found, line >  MAX_LINE_BYTES  → skip it: advance off PAST THAT \n, and log
                                     outcome=skip reason=oversize-line
    no \n, hit EOF, file is .1     → the generation is frozen, so this really is
                                     the final line. The CEILING STILL APPLIES: a
                                     tail over MAX_LINE_BYTES is skipped to EOF
                                     with outcome=skip reason=oversize-line, since
                                     the search that produced it may have spanned
                                     every window (256 MiB) and the receiver is
                                     promised at most one line's worth. Otherwise
                                     send it, sized by what was actually READ - the
                                     size snapshot predates the read and `.1` can
                                     be replaced by a fresh rotation in between
    no \n, hit EOF, file is live   → a line still being written. Send nothing and
                                     do not advance; next run picks it up
    no \n, scan bound exhausted    → STALL. Do not advance. Log
                                     outcome=stall reason=unbounded-line
```

Three of those five branches were wrong or missing in the first draft, and each was
found by a test rather than by review:

- **The search must span windows.** The first implementation probed one
  `MAX_LINE_BYTES` window and, on a miss, advanced the offset by that window and
  probed again. That lands the offset **mid-line**, and every read after it is a
  fragment: verified with a 406-byte line against `ROGUE_SHIP_MAX_LINE_BYTES=100`,
  which shipped the line's last 6 bytes as if it were a short line. The only safe
  skip target is the next `\n` — never a fixed amount.
- **An unterminated final line splits by file state.** On the live file it is a
  partial write and must be left alone; on a rotated `.1` the generation is frozen,
  so waiting for a newline that will never arrive stalls `.1` forever — and because
  the live log cannot reset until `.1` drains, that stalls the whole file.
- **An exhausted scan bound must stall, not advance.** Losing one file's
  diagnostics until someone looks at it is recoverable; advancing to a mid-line
  offset corrupts every subsequent chunk. It is logged on every run so a stalled
  file is visible rather than silent.

So `ROGUE_SHIP_MAX_BYTES` is the per-request size **for ordinary chunks**, with one
bounded, documented exception for a single line that cannot fit. The server must
accept a body above the normal cap; `ROGUE_SHIP_MAX_LINE_BYTES` is the real ceiling.

These branches are effectively unreachable in a healthy install — `raw=` is capped at
400 chars and every other token is bounded, so a line is a few hundred bytes. A
multi-megabyte line means something already went wrong (a binary blob appended, an
interleaved write from outside the plugin), which is exactly why the over-ceiling
case **skips forward instead of retrying**: a corrupt line must not park the file
forever.

#### The chunk never passes through a shell variable

sh variables cannot hold NUL bytes, and a stray NUL would silently truncate the
chunk. Extract straight to a temp file under `~/.rogue/ship/`, base64 the file, and
let only the base64 output (NUL-free by construction) live in a variable.

**And the request body cannot be an argument either** — corrected during
implementation, where the first version passed `curl -d "$body"`. A 1 MiB chunk is
~1.4 MiB once base64-encoded, and macOS caps `ARG_MAX` at 1 MiB for arguments *plus*
environment, so the largest ordinary chunk cannot be passed on a command line at
all — and an oversized line (up to `ROGUE_SHIP_MAX_LINE_BYTES`) misses by a wide
margin. The body is therefore assembled into a temp file and sent with
`--data-binary @file`, which also keeps the base64 out of the process table. The
PowerShell and Node implementations have no such limit (a byte array and a string
respectively) and are unaffected.

#### Windows file sharing — both directions

Two distinct failures, one of them nasty:

- Our `FileStream` **must** pass `FileShare.ReadWrite`, or the read fails
  intermittently whenever a dispatcher is appending.
- It must **also** pass `FileShare.Delete`, or holding the file open makes the
  dispatcher's `Move-Item` rotation fail — and phase 1 swallows that failure under
  `-ErrorAction SilentlyContinue`, so **the log would grow past the cap forever**.
  A log shipper causing unbounded log growth is the worst outcome in this document.

Open with `ReadWrite -bor Delete`, keep the open window as short as possible.

#### What this covers

| event | detected by | outcome |
|---|---|---|
| normal append | `head` matches, `size > off` | ship `[off, size)` in chunks |
| rotation, new file smaller than `off` | `size < off` | ship `.1` tail, then reset |
| rotation, new file already larger than `off` | `head != stored_head` | ship `.1` tail, then reset |
| rotation *while* we read | post-extract head re-check | discard chunk, retry next run |
| `> file` (truncate in place) | `size < off`; `.1` head will not match | reset to 0, no bogus `.1` ship |
| log `rm`'d, dispatcher recreates it | `.1` head will not match | reset to 0 (the unshipped tail is gone — unavoidable) |
| state file deleted or corrupt | `off = 0` | whole file re-shipped (duplicates, safe) |
| empty / 0-byte log | `size == off == 0` | no request |
| chunk cap hit mid-line | newline trim | chunk ends on a line boundary |
| **two rotations between runs** | — | **middle generation lost — accepted**; needs 20 MiB inside 15 min |

#### Delivery is at-least-once, deliberately

If the backend commits a chunk and the 2xx is lost in transit, the next run re-sends
that range. the store is append-only and hook logs go to their own dataset, so that is
a duplicate event, not corruption, and a query can collapse on
`(log_source_id, log_file, ts, raw)`. The alternative — advancing the offset
before confirmation — trades duplicates for silent loss, the wrong trade for
diagnostics.

Other invariants:

- **Oldest-first.** Chunks go in offset order; a failure stops the loop and leaves
  the rest for next run, so ordering is preserved and nothing is skipped.
- The live log is opened **read-only, never truncated**. Concurrent appends are
  safe: we only ever read `[off, off+n)`, a range already written.
- `<key>.state` is written **write-to-temp-then-`mv`** so a crash mid-write cannot
  leave a half-written offset (`mv` within a directory is atomic; on Windows,
  `Move-Item` after removing the destination, per phase 1's rotation note).

Byte range extraction:

```sh
tail -c +$((off + 1)) "$f" | head -c "$n"      # tail -c +N is 1-based
```

Both flags are already load-bearing elsewhere in this repo (`tail -c 262144` and
`head -c 400` in `plugins/copilot/scripts/hook.sh`), so this adds no new
portability assumption. PowerShell uses `FileStream.Seek` + `Read`; Node uses
`fs.readSync` with a position.

### Redaction happens server-side, not here

The chunk is uploaded **verbatim**. The scripts do no rewriting of the log body at
all — no `sed`, no `$HOME` → `~` substitution, no field stripping.

An earlier draft claimed only home paths and `reason=`/`raw=` need redacting and
that "nothing else in a line is personal". **That was wrong** — the real inventory,
grepped out of the current dispatchers rather than assumed:

| token | written by | risk |
|---|---|---|
| timestamp, `provider=`, `event=`, `outcome=`, `http=`, `rc=` | all | none |
| `raw=` / `reason=` | all (`hook.sh:692`) | up to 400 chars of Rogue's own API response; a finding can quote the prompt fragment that triggered it |
| `path=` | antigravity (`hook.sh:239,244,245`) | **absolute transcript paths** — `/Users/<name>/…`, plus project directory names |
| `name=` | copilot (`hook.sh:318`), antigravity (`hook.sh:576`) | **subagent display name** — arbitrary vendor-or-user-authored text, sanitized of control chars only |
| `subagent=`, `parent=`, `dbstore=`, `tail=`, `len=`, `mode=` | antigravity, copilot | opaque ids and counters |

So the requirement is **not** "redact two fields": server-side redaction must run
over **every parsed field and the raw line**, the way
the endpoint agent's redaction helper already does for the
endpoint agent — it walks every string value through one redaction function,
which rewrites `/Users/<name>`, `/home/<name>` and `C:\Users\<name>` to `~`. Reuse
it rather than growing a second implementation. Two gaps it does not cover today
and this ingest needs:

- **`name=`** is arbitrary text, not a path, so that redaction passes it through
  untouched. Needs its own decision — keep (it is a tool label, usually harmless),
  or drop under the same policy switch as `raw=`.
- **`raw=` / `reason=`** likewise. Whether it is kept, truncated or dropped is
  per-tenant policy.

Doing any of this in `sh` and PowerShell would mean the same substitutions written
three times, with a `sed` escaping hazard in one of them (a `$HOME` containing `&`,
`|` or `\` silently mangles the chunk) and no realistic way to unit-test a policy.
Server-side it is one function, one test file, and it can change without a plugin
release — which matters because the fleet updates on a 24 h auto-update cycle at
best.

**`raw` is stored redacted.** The parsed fields and the `raw` line are two
representations of the same bytes, so redacting one and keeping the other verbatim
redacts nothing. Redact the line first, then parse the redacted line.

**Tests must cover the real cases**, not a synthetic `$HOME` line: an antigravity
`tail=none reason=unreadable path=/Users/amos/…/transcript.jsonl` line, and a
copilot `subagent=… parent=… name=<display name>` line — asserting the home path is
gone from **both** `fields.path` and `raw`.

## Wire format

`POST ${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/logs`

Headers: `x-rogue-api-key`, `Content-Type: application/json`. Nothing else — no
`x-rogue-event` (not a hook event), no `x-rogue-source`, no `x-rogue-agent`.

```jsonc
{ "host":             "…",          // resolve-or-create a log_source row; only
  "actor_email":      "…",          //   its random id reaches the store — see §9
  "actor_name":       "…",
  "agent_family":     "claude",     // roster vocabulary: codex's family is `openai`
  "shipper":          "claude",     // which plugin's copy ran (log-slug vocabulary)
  "shipper_version":  "1.4.2",
  "log_file":         "claude.log", // basename only; the directory is site config
  "offset":           12345,        // byte offset this chunk starts at
  "bytes":            4096,
  "rotated":          false,        // true → this is the tail of <file>.1
  "content_b64":      "…" }         // base64 of the raw chunk, whole lines only
```

`shipper` and `log_file` are equal in the default configuration and differ only
under `ROGUE_SHIP_ALL` or `ROGUE_LOG_FILE`. Both are envelope-level hints; the
per-line `provider=` token remains authoritative for which agent a line came from.
`agent_family` is a **fallback hint, not the key**: attribution runs per line off
`provider=` (see **Attribution is per line**). It is sent when the caller passed one
— its own log — and omitted for a foreign log under `ROGUE_SHIP_ALL` and for a
custom `ROGUE_LOG_FILE`, because in both of those the shipping plugin's family is
not the chunk's family. The slug→family mapping (`codex` → `openai`, …) is server
vocabulary; a copy of it inside a byte-identical shell script is exactly the
lockstep liability this design avoids elsewhere.

**No `agent` (surface) field, deliberately** — see §9: one log file spans every
surface of its family, so a surface on the envelope would be a false precision.

**Why `content_b64` and not parsed records**, in order of weight:

1. `raw=` holds up to 400 characters of **our own API response**, including block
   reasons with arbitrary quotes and backslashes. Hand-concatenating that into JSON
   is the exact hazard `transcriptTailB64` already exists to avoid.
2. **No `jq`, no `python3`** — `jq` is absent from older macOS and minimal Linux
   images, and `/usr/bin/python3` is a stub that fails silently without Xcode CLT
   (repo-wide rule). `base64 | tr -d '\r\n'` is everywhere;
   `[Convert]::ToBase64String` and `Buffer.toString('base64')` need nothing.
3. Parsing on the server can be fixed without a plugin release. The line format is
   stable; the field set is not — phase 1 alone added three tokens.

Server side, per line: leading RFC3339 timestamp, `provider=`, `event=`, then
best-effort `k=v`, always keeping the whole line as `raw`. **`raw` is the redacted
line, never the original** — storing the untouched line beside redacted fields would
route every `path=`, `name=` and prompt fragment straight past the policy, making the
field-level redaction decorative. Redact first, parse second, and persist only
redacted values in both places. **Never drop a line**
— `raw=` is a space- and `=`-bearing free-text tail (Codex puts it mid-line), so a
strict k=v parse loses data. **`provider=` selects the line's `log_source`**; a line
without one falls back to the envelope's `agent_family`, and a line with an
unrecognised `provider=` is still stored, attributed to a family of `unknown` rather
than discarded.

PowerShell builds the body with `ConvertTo-Json -Compress`. That is allowed here
and is *not* the thing `CLAUDE.md` forbids: the prohibition is on re-serialising a
**relayed payload** (which would reshape a body the server must see verbatim). This
body is constructed fresh, so a real serialiser is strictly safer than manual
escaping. The sh side hand-builds it with the existing `esc()` sed helper because
it has no serialiser — the two produce the same *fields*, not the same bytes, and
only one ever runs on a given machine.

HTTP timeouts: 15 s connect+transfer, matching the dispatchers. Nothing is inside a
hook budget here, but a wedged upload holding the lock for minutes is worse than a
failed one.

## Environment knobs

All resolved from the env file in use, so `/etc/rogue/env` can set them
fleet-wide; the process env supplies what that file does not set:

| var | default | meaning |
|---|---|---|
| `ROGUE_SHIP_MIN_INTERVAL` | `900` | seconds between attempts, per log file |
| `ROGUE_SHIP_MAX_BYTES` | `1048576` | bytes per HTTP request (ordinary chunks) |
| `ROGUE_SHIP_MAX_RUN_BYTES` | `10485760` | bytes per file per run (one generation) |
| `ROGUE_SHIP_MAX_LINE_BYTES` | `4194304` | hard ceiling for a single oversized line |
| `ROGUE_SHIP_ALL` | `0` | `1` ships every known agent's log, not just this one |
| `ROGUE_BASE_URL` | `https://api.rogue.security` | as elsewhere |

Numeric parsing follows phase 1's rule, in all three languages: a non-numeric value
**falls back to the default** (a typo must not disable shipping or blow the size cap),
and zero-padding counts as its numeric value. A leading `-` is non-numeric under the
digits-only test phase 1 uses (`case $v in *[!0-9]*)`), so negatives already fall back
— but **zero does not**, and that differs per knob:

| knob | zero | why |
|---|---|---|
| `ROGUE_SHIP_MAX_BYTES` | **rejected → default** | a 0-byte request ships nothing, so the offset never advances and the file never drains. Silent permanent stall. |
| `ROGUE_SHIP_MAX_RUN_BYTES` | **rejected → default** | same |
| `ROGUE_SHIP_MAX_LINE_BYTES` | **rejected → default** | same |
| `ROGUE_SHIP_MIN_INTERVAL` | **honored — means "no throttle"** | intentional, and the documented support one-liner relies on it |

Note this deliberately diverges from phase 1's *rotation* cap, where numeric zero
means "disable rotation" — a meaningful setting there. There is no useful reading of
"a zero-byte upload", so the three byte caps require a positive value.

## Support use

Run by hand on a machine with no endpoint agent — the single most useful property
of this script:

```sh
# No arguments → collects every agent's log (ROGUE_SHIP_ALL is implied, since
# without a slug there is no "own log" to pick). Throttled like any other run.
sh ~/.claude/plugins/.../scripts/ship-logs.sh

# The actual support one-liner: ignore the throttle, and report the outcome even
# though a no-argument run has no log file of its own to write it to.
ROGUE_SHIP_MIN_INTERVAL=0 ROGUE_DEBUG=1 \
  sh ~/.claude/plugins/.../scripts/ship-logs.sh

# This agent only, attributed properly: pass what the heartbeat passes.
sh .../ship-logs.sh "$CLAUDE_PLUGIN_ROOT" claude 1.4.2 claude
```

No line above turns uploading on, because nothing has to: shipping is unconditional
(**Rollout**, below). `ROGUE_DEBUG=1` is on the support line for a
subtler reason: the shipper's own diagnostics go into the SHIPPING plugin's log file,
which a no-argument run does not have (its slug is `unknown`), so without the debug
stream `outcome=fail … http=<code>` and `outcome=skip reason=no-actor` would have
nowhere to land on exactly the run support is asked to make. `log()` therefore always
mirrors to stderr under `ROGUE_DEBUG`, before it checks whether it has a file.

**`http=000` means the request never got an HTTP response** — DNS failure, a refused
connection, a TLS error, a proxy swallowing it, or the client's own timeout. It is
`curl`'s own `%{http_code}` value when no status line was received, and the PowerShell
and Node implementations format their transport failures the same way (three digits,
`$httpCode.ToString('000')`) so one line format covers all three and an operator does
not have to learn a second vocabulary per platform. Distinguishing it from `http=404`
matters for support: `404` is a route that answered, `000` is a network path that did
not, and the fixes have nothing in common.

`/rogue:status` gains a final step offering exactly that, in all six status commands
(`plugins/{rogue,gemini,antigravity,copilot}/skills/status/SKILL.md`,
`plugins/{codex,cursor}/commands/status.md`), with the bash and PowerShell forms each
already carries. It documents the **no-argument** form: the support case is "collect
everything on this box", and a status command that filled in its own slug would ship
only its own agent's log — which is the one thing the operator running a support
collection does not want.

## Rollout

**Shipping is unconditional.** A configured install uploads its hook log; there is no
`ROGUE_SHIP_LOGS` flag and no way to opt a machine out. The only things that stop a
given run are the ones that always could: no API key, no resolvable actor, the
self-throttle, or no new bytes on disk.

It was opt-in for one reason, and that reason is gone: `/api/v1/hooks/logs` was not
deployed, and prod answers an unknown hooks path with `404 NOT_FOUND` *before* auth, so
a default-on client would have had every configured install POST into a permanent 404
once per session start — nothing lost, since the offset advances only on 2xx, but
nothing recovered either, while each failure appended an `outcome=fail … http=404` line
to the very file it was draining. **The route now exists** (probed 2026-08-18: an empty
body is answered `422` with `{"type":"validation","on":"body"}`, i.e. body validation
runs before auth and the route knows this schema, where `/api/v1/hooks/nonexistent`
still answers a bare `404 NOT_FOUND`), so the gate was removed rather than flipped.

**What was removed, so a reader of an older revision is not surprised:** the
`ROGUE_SHIP_LOGS` opt-in *and* its `=0` kill switch, which used to be the one place
where an env file deliberately beat process env. `flag_is_enabled` / `Test-FlagEnabled`
/ `flagIsEnabled`, `value_is_zero` / `Test-ValueIsZero` / `valueIsZero`, and the
`SHIP_DISABLED_BY_FILE` plumbing in all three implementations are gone with it. A value
left behind on an upgraded machine — inline or in `/etc/rogue/env` — is ignored, which
is asserted on purpose in all three test layers: an upgrade must not leave a fleet
silently half-off with no knob left to explain it. **There is therefore no
machine-level opt-out any more.** If one is ever needed again it is a new control, not
a resurrection of this one, and it wants a name that says what it does.

The 2xx contract on the server is unchanged and remains the one hard requirement:

1. `POST /api/v1/hooks/logs` deployed, authenticating `x-rogue-api-key`, and
   answering **2xx only after a durable write**. This is a correctness requirement,
   not a preference: the client forgets bytes the moment it sees a 2xx, so an
   accepted-then-dropped chunk is unrecoverable data loss with no error anywhere.
   the endpoint-log sink's un-awaited the store client's ingest call is exactly the shape
   this must not have.
2. The `log_source` mapping in place, so a chunk's `host` / `actor_email` /
   `agent_family` resolve to a row rather than being stored raw.
3. Server-side redaction over every parsed field **and** the raw line.

The feature is exercised by CI (a real receiver, real HTTP, on both platforms) and
reachable by hand for support with the one-liners above.
Endpoint contract, storage model and the task-worker side:
[log-shipping-backend.md](log-shipping-backend.md).

## Tests

`tests/test_ship_logs.sh` and `tests/test_ship_logs.ps1`, both wired into
`.github/workflows/validate.yml` (sh under **both `dash` and `bash`**, as phase 1's
log test is).

**No mock server in the contract tests.** The sh test puts a fake `curl` earlier on
`PATH` that records the request body to a file and exits with a scripted status.
Deterministic, no network, no new dependency, and it lets a test assert the exact
bytes that would have gone over the wire. Node stubs `globalThis.fetch`
(`tests/ship_probe.mjs`), which is why `ship-logs.mjs` must export its entry point
and auto-run only when it is `process.argv[1]`.

`tests/test_ship_logs.ps1` came out differently from the plan above: rather than
shadowing `Invoke-WebRequest`, it exercises the **pure helpers** through the
`ROGUE_PS_LIB_ONLY` seam (fragment maths, head fingerprint, path normalisation, knob
parsing, ranged reads, the window-spanning line scan, the state round trip) plus a
**structural layer** asserting each of the five callers starts the shipper, with the
right slug/family, in a child process. Shadowing the HTTP call would have added a
mock of the one thing the e2e test below covers for real, and the helpers are where
the Windows-only defects actually were — it found two on first run (see below).

**A separate END-TO-END test, `tests/e2e_ship_logs.sh`**, added because a stub can
only prove what the shipper *would* send. It runs the real pipeline: a real
dispatcher writes the log, `hook.sh`'s own rotation renames it, the real shipper
POSTs with real `curl`, and a real HTTP server (`tests/e2e_receiver.mjs`) decodes
`content_b64` and rebuilds the file — then `cmp` compares disk against wire. It also
drives the real caller (`heartbeat.sh`) rather than the shipper directly, which is
the only assertion that the feature is wired in at all. Both are in
`validate.yml`.

Cases:

- the five `ship-logs.sh` are byte-identical (`cmp`), likewise the five `.ps1`;
- **each shipper ships only its own slug** — with all six logs present, the claude
  copy POSTs `claude.log` and nothing else; `ROGUE_SHIP_ALL=1` ships all six;
- offset advances on 2xx; does **not** advance on 500, on a transport failure, or on
  a timeout;
- **nothing is re-sent** across two runs with no new lines (assert the second run
  makes no request at all);
- `size < off` ships `.1`'s tail with `rotated=true`, then resets — and a failed
  `.1` upload leaves the state alone so the next run retries;
- **the grow-past-offset rotation is caught**: ship, rotate, then write *more* than
  the old offset into the new file, and assert the next run detects it by `head`
  and re-ships from 0 rather than skipping the new file's first `off` bytes. The
  case a size-only check misses, so it is the test that justifies `head=`;
- **a young file is not re-shipped**: one short line, ship it, append three more
  lines, assert the next run ships only the new lines (the first-200-bytes version
  of `head` fails this — it is the regression test for first-**line** semantics);
- a `.1` whose head does **not** match the stored head is skipped, not shipped;
- truncation in place (`: > file`) resets to 0 and ships no `.1`;
- **rotation mid-read is discarded**: rotate the file between the size read and the
  chunk read (via a wrapper on the fake `curl`, or a pre-send hook) and assert the
  chunk is *not* sent and the offset does not move;
- **every chunk ends with `\n`** — cap set mid-line, assert no partial line is ever
  sent and that concatenating the chunks reproduces the file byte-exactly;
- **the trailing-fragment calculation is exact**, the case the first `awk` draft got
  wrong: a chunk of `a\nb\n` is trimmed by **0** bytes (not 1), `a\nb` by 1, an empty
  chunk by 0, and a chunk with no newline reports its whole length. Assert under
  **both `dash` and `bash`** — a 1-byte-short trim would leave the offset lagging one
  byte per run forever, and the symptom is a stray leading `\n` on the next chunk,
  not an error;
- **`.1` larger than one request is drained across several chunks in one run**, and a
  run that spends its budget mid-`.1` **does not reset** — assert the next run
  resumes `.1` at the stored offset rather than jumping to the live file (skipping the
  rest of a rotated generation is silent loss);
- **state keyed to the path**: ship `/a/claude.log`, then point `ROGUE_LOG_DIR` at
  `/b` with a different `claude.log`, and assert the second run starts at offset 0
  instead of inheriting `/a`'s offset;
- a single line longer than `ROGUE_SHIP_MAX_BYTES` is shipped as **one oversized
  request containing that whole line** — assert the body ends with `\n` and is larger
  than the cap, i.e. that we never emit a partial line to satisfy the cap;
- a line longer than `ROGUE_SHIP_MAX_LINE_BYTES` is **skipped forward past its
  newline** with `outcome=skip reason=oversize-line`, and the file keeps draining
  afterwards (assert the following lines still ship — a stall here is permanent);
- `ROGUE_SHIP_MAX_BYTES=0`, `=-1` and `=abc` all fall back to the default rather than
  stalling the file, while `ROGUE_SHIP_MIN_INTERVAL=0` is honored as "no throttle";
- the chunk loop drains a file larger than `ROGUE_SHIP_MAX_BYTES` **in one run**,
  stopping at `ROGUE_SHIP_MAX_RUN_BYTES`;
- `head=` written by one language is honored by another — generate state with the
  `.mjs` shipper, run the `.sh` one against it and assert it does not re-ship
  (they share `~/.rogue/ship/`, so the encoding must agree byte-for-byte);
- a crash between "chunk accepted" and "state written" re-sends the chunk rather
  than skipping it (kill after the fake curl succeeds, assert the range repeats);
- the lock serialises two concurrent runs of the same key; a lock older than 600 s
  is reclaimed; **two different keys do not block each other**;
- throttle honored per key, honored **from `~/.rogue-env`** (phase 1's actual bug),
  and a `.last-<key>` timestamped in the future is treated as stale;
- a configured install with new bytes **uploads with no flag set at all**, asserted
  first and from a clean case because every other assertion in the suite would pass
  vacuously against a shipper that did nothing; and a leftover `ROGUE_SHIP_LOGS=0`,
  inline or in an env file, **no longer disables anything** (see **Rollout**);
- a lock directory with **no readable `ts` marker** still blocks: creating the
  directory and writing the marker are two operations, so a lock taken microseconds
  ago legitimately has no marker, and reading that absence as stale let a second run
  delete a live lock and re-upload the same range. Only the lock directory's own age
  may reclaim an unmarked lock (`find -mmin` in sh — `stat`'s flags differ between
  BSD and GNU; the directory's own timestamp in PowerShell and Node);
- every outcome `log()` records also reaches **stderr under `ROGUE_DEBUG`**, so the
  no-argument support run — which has no log file of its own — still reports
  `http=<code>` and `reason=no-actor`;
- a chunk containing `"`, `\`, a newline and a UTF-8 multibyte character round-trips
  through base64 **byte-exact**; a chunk containing a NUL byte is not truncated
  (the temp-file path, not a shell variable);
- `host` / `actor_email` / `actor_name` in the envelope match what the heartbeat
  resolves on the same machine — if they drift, `log_source` resolves to a different row
  than the roster row does and the logs orphan (assert against `actor.sh`'s output);
- an **absent, empty and whitespace-only** `actor_email` all produce the same
  envelope value, so `log_source` and the roster fingerprint's `?? "anon"` cannot
  diverge (the failure is silent: logs attach to nothing);
- **the shipper has no actor cascade of its own**: with `ROGUE_ACTOR_EMAIL` unset and
  no `scripts/actor.sh` reachable, it **skips the file** and logs
  `outcome=skip reason=no-actor` — assert it does *not* fall back to `hostname`,
  `whoami` or `$USER@$(hostname)`. This is the regression test for the Cursor drift:
  `hook.sh`'s fallback is `$USER@$(hostname)` where `actor.sh`'s is `hostname`, so any
  private cascade produces a second identity for the same machine;
- **every caller passes down what it resolved**: `cursor/scripts/hook.sh` prefixes the
  invocation with `ROGUE_ACTOR_EMAIL=`/`ROGUE_ACTOR_NAME=` (its actor lives in plain
  shell locals, so without that the child inherits nothing and skips),
  `gemini/scripts/heartbeat.mjs` assigns them into `process.env` before importing the
  shipper (`loadEnvFiles()` deliberately does not mutate `process.env`), and the five
  PowerShell callers set them as `$env:` before spawning. A wiring assertion like
  phase 1's `Initialize-Logging` ones, because the failure is invisible at runtime —
  logs upload fine, attached to nothing;
- **`path=` agrees across implementations for the same file**: ship through a
  directory reached with a redundant `//` in one language and a `/./` in another, and
  assert the second run does not re-ship. The regression test for the normalisation
  bug above, and the reason macOS's trailing-slash `$TMPDIR` is left in the harness
  rather than cleaned up — it is what exposed it;
- **an unbounded line stalls rather than advancing**: assert `outcome=stall
  reason=unbounded-line` and that the offset is unchanged, with no chunk sent. The
  `.ps1` copy shipped the opposite (advance by one window) with no test to catch it;
- **the state file parses back on Windows**: write state, read it, assert the offset
  and size round-trip. Trivial-looking, and it caught a real defect — a nested
  `-match` inside the `if ($line -match '^offset=(.*)$')` branch overwrote the
  automatic `$Matches`, so both parsed as 0 and every Windows run re-shipped the whole
  log from byte 0, forever, with a state file that looked correct on disk;
- **the state file is BOM-less LF**: a UTF-8 BOM would make the sh parser read the
  first key as `﻿offset` and treat the offset as absent (same failure, other
  direction);
- `agent_family` is the value the **caller passed**, never derived from the slug —
  assert the codex copy sends `openai` while its `shipper` stays `codex`, the one
  case a naive slug→family assumption breaks;
- under `ROGUE_SHIP_ALL=1`, the caller's own log carries `agent_family` and a
  foreign log **omits** it; a custom `ROGUE_LOG_FILE` omits it too (its lines are
  mixed-provider, so the shipping plugin's family would mislabel them);
- a collapse-mode file round-trips: write interleaved `provider=claude` and
  `provider=codex` lines to one custom `ROGUE_LOG_FILE`, ship it, and assert the
  body carries no `agent_family` and every line survives byte-exact (the server-side
  half — one `log_source` per distinct provider — is asserted in the backend repo);
- **no `agent` / surface field is ever sent** (§9: a log file spans every surface of
  its family, so a surface on the envelope would be false precision);
- **no-argument invocation ships every log**, not `unknown.log`, and reports
  `shipper: "unknown"`;
- unconfigured (no API key) is a silent no-op.

## Not doing

- **No `hooks.json` entry.** Codex, Gemini and Copilot fingerprint the hook
  definition and skip untrusted command hooks until the user reviews `/hooks`, so a
  new entry would silently disable enforcement for every existing install until
  each user re-trusted it.
- **No shipper-only ownership/permission check on the env files.** The threat is real
  — a writable env file redirects `ROGUE_BASE_URL` and exfiltrates the API key — but
  it is a property of the **shared env-file chain**, not of this script. Eleven
  dispatchers, six heartbeats and both auto-updaters source the same three paths with
  the same bare `[ -r … ] && . …` and no validation (`plugins/rogue/scripts/hook.sh:15-17`).
  Adding a check here alone buys nothing: an attacker who can write `~/.rogue-env`
  already owns the dispatcher that reads it, and the dispatchers are the *better*
  target — they POST full prompts and tool calls, where the shipper posts a
  diagnostics log. So this belongs as one change across the whole chain (a
  `safe_source` helper in all three languages, plus the world-writable test cases),
  scoped as its own PR, and it is recorded in `log-shipping.md`'s open questions
  rather than solved asymmetrically here.
- **No content rewriting in the scripts.** Redaction is the API's job — see
  **Redaction happens server-side**. The scripts read bytes and upload bytes.
- **No log truncation or deletion.** Rotation already caps disk at 2× the cap per
  agent; a shipper that also deleted would race the dispatcher's append.
- **No retry loop inside one run.** A failed chunk stops the loop and waits for the
  next session. Simpler, and the data is not time-sensitive.
- **No streaming or per-event upload.** Volume is single-digit KB per busy day.
