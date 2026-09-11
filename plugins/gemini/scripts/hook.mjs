#!/usr/bin/env node
// Rogue Security — Gemini CLI hook dispatcher.
//
// Usage: node hook.mjs <EventName>
//   Reads the Gemini hook JSON payload on stdin, POSTs it to Rogue, and relays
//   the response verbatim on stdout. The backend already emits Gemini's native
//   decision shapes ({"decision":"deny"|"block", "reason":...} / toolConfig), so
//   this dispatcher is a PURE RELAY — Gemini renders the block itself.
//
// The POSTed body is BYTE-FOR-BYTE the bytes read from stdin. The dispatcher
// does parse those bytes (into a local, for subagent attribution — see
// resolveSubagentId), but the parse result never reaches the request: everything
// it derives travels as a HEADER. Never re-serialize the payload into `body`.
//
// One cross-platform script replaces the sh + PowerShell dual-dispatcher used by
// the Claude/Codex/Cursor plugins: Gemini CLI guarantees Node 20+ on PATH (every
// install method requires it; Homebrew declares `node` as a dependency), so we
// use Node built-ins only (global fetch, node:fs/path/child_process) — no
// curl, no jq, no dependencies, no build step.
//
// Fail-open by design: any missing key / network error / bad response prints
// "{}" (allow) and exits 0. stdout carries ONLY the final JSON, per the Gemini
// hook contract; everything else goes to the log file.

import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import {
  HOME,
  SCRIPT_DIR,
  SURFACE,
  loadEnvFiles,
  resolveActor,
  installId,
} from "./shared.mjs";

const EVENT = process.argv[2] || "unknown";

// Agent slug: names this plugin's log file AND is stamped on every line inside
// it. Deliberately the plugin's common name, NOT the roster's `agent` label
// ("gemini_cli", which the server keys its version lookup on) — see
// heartbeat.mjs. Keep the two independent.
const PROVIDER = "gemini";
// The one surface this extension has - Gemini CLI. A closed-vocabulary slug,
// lowercase, no space and no "=", so a reader finds the value by scanning to the
// next "key=" token, and it matches what heartbeat.mjs reports as the roster agent.
// A constant here: there is nothing to detect and nothing that can fail. It is
// still emitted through the same conditional the multi-surface plugins use, so all
// six dispatchers share one emit shape and an empty value omits the token entirely
// rather than writing "surface=" or "surface=unknown". Imported from shared.mjs
// because installId() sends the same value as x-rogue-agent and heartbeat.mjs sends
// it as the roster agent - one literal, three consumers.

// ── Emit + exit ────────────────────────────────────────────────────────────
// stdout must be ONLY the final JSON object. Always exit 0 — a blocking verdict
// is carried in the relayed JSON body, not the exit code.
function emit(obj) {
  process.stdout.write(typeof obj === "string" ? obj : JSON.stringify(obj));
  process.exit(0);
}

// ── Resolved configuration ───────────────────────────────────────────────────
// Read the env files ONCE, here at module load, because the log destination below
// is derived from them. `loadEnvFiles()` returns a MERGED OBJECT and deliberately
// does not mutate `process.env`, so reading `process.env.ROGUE_LOG_DIR` directly
// would silently ignore `~/.rogue-env` / `/etc/rogue/env` — the exact bug this
// replaced. The merge is the process env with the first env file holding
// ROGUE_API_KEY laid over it (see shared.mjs).
// Wrapped: a throw here would kill the hook before it could emit anything, and
// Gemini must always get a body. An empty env degrades to "unconfigured".
let ENV = {};
try {
  ENV = loadEnvFiles();
} catch {
  /* fail-open: no credentials and no overrides */
}

// ── Logging (file only; stdout is reserved for Gemini) ───────────────────────
// ONE FILE PER AGENT. Every Rogue plugin shares ~/.rogue, so a machine running
// Gemini CLI + Claude Code + Cursor + … used to interleave all of them into a
// single hook.log with no way to tell whose line was whose. Precedence:
// explicit file → directory override → per-agent default.
const LOG_DIR = ENV.ROGUE_LOG_DIR || path.join(HOME, ".rogue", "logs");
const LOG_FILE = ENV.ROGUE_LOG_FILE || path.join(LOG_DIR, `${PROVIDER}.log`);
// Size cap. Over it, the current log is renamed to <file>.1 (exactly one
// generation kept, so worst case on disk is 2x this). A NUMERIC ZERO disables
// rotation; a NON-NUMERIC value falls back to the default rather than disabling
// it, so a typo can never leave the log growing unbounded. `Number("00") === 0`,
// so any zero-padded zero disables too — matching the sh dispatchers' `-gt 0`
// test and PowerShell's [int64]::TryParse.
// Enforced on the WRITE PATH and not by a periodic job on purpose: an
// UNCONFIGURED install writes a line per event and never runs anything else, so
// a cap enforced anywhere else would not hold.
//
// isSafeInteger, not a bare Number(): an all-digit value can be far too wide to
// represent, and Number() turns those into Infinity, which no file size ever
// reaches — rotation would be silently off and the log would grow unbounded.
// An unrepresentable value is a typo, so it takes the default like a
// non-numeric one. The sh dispatchers clamp at 18 digits against the identical
// bug (dash calls it an "Illegal number" and answers FALSE); PowerShell already
// landed on the default because its cast error is silenced, and uses TryParse
// so that is stated rather than accidental.
const LOG_MAX_BYTES = (() => {
  const n = /^\d+$/.test(ENV.ROGUE_LOG_MAX_BYTES ?? "")
    ? Number(ENV.ROGUE_LOG_MAX_BYTES)
    : NaN;
  return Number.isSafeInteger(n) ? n : 10 * 1024 * 1024;
})();
// eslint-disable-next-line no-control-regex
const CONTROL_CHARS = /[\x00-\x1f\x7f]/g;
const sanitize = (s) => String(s ?? "").replace(CONTROL_CHARS, "");
function rotateLog() {
  if (LOG_MAX_BYTES <= 0) return;
  try {
    if (fs.statSync(LOG_FILE).size >= LOG_MAX_BYTES) {
      fs.renameSync(LOG_FILE, `${LOG_FILE}.1`);
    }
  } catch {
    /* no file yet, or rotation lost a race — either way just append */
  }
}
function log(msg) {
  try {
    // 0700 dir / 0600 file, matching the `umask 077` the sh dispatchers use.
    // The log carries the server's block reason, which quotes the content that
    // tripped the rule, so it must not land 0644 where every other account on
    // the box can read it. `mode` applies only when this call CREATES the path,
    // so an existing log from an older version keeps its mode (and Windows
    // ignores it, which is fine: another standard user cannot read the profile
    // directory anyway).
    fs.mkdirSync(path.dirname(LOG_FILE), { recursive: true, mode: 0o700 });
    rotateLog();
    const ts = new Date().toISOString().replace(/\.\d+Z$/, "Z");
    const surfaceToken = SURFACE ? ` surface=${SURFACE}` : "";
    fs.appendFileSync(
      LOG_FILE,
      `${ts} provider=${PROVIDER}${surfaceToken} event=${EVENT} ${msg}\n`,
      { mode: 0o600 },
    );
  } catch {
    /* logging is best-effort */
  }
}

// ── Detached heartbeat (SessionStart + AfterAgent) ──────────────────────────
// Fire-and-forget so it never adds latency to session start or to a turn.
//
// The TRIGGER is passed through, because heartbeat.mjs rate-limits its beacon on
// anything that is not SessionStart: AfterAgent fires once per turn, and without the
// distinction a long session would either beacon on every turn or (if it were
// throttled unconditionally) miss the update a brand-new session most wants.
function fireHeartbeat(trigger) {
  try {
    const child = spawn(
      process.execPath,
      [path.join(SCRIPT_DIR, "heartbeat.mjs"), trigger],
      { detached: true, stdio: "ignore" },
    );
    child.unref();
  } catch {
    /* best-effort */
  }
}

// ── Block detection (for the log only; the body is relayed verbatim) ─────────
function describeOutcome(bodyText) {
  try {
    const j = JSON.parse(bodyText);
    const decision = j?.decision;
    const toolMode = j?.hookSpecificOutput?.toolConfig?.mode;
    if (decision === "deny" || decision === "block" || toolMode === "NONE") {
      const reason =
        j?.reason ?? j?.systemMessage ?? j?.stopReason ?? "blocked";
      return `outcome=block reason="${sanitize(reason)}"`;
    }
  } catch {
    /* non-JSON / empty → treated as allow */
  }
  return "outcome=allow";
}

// ── Subagent attribution (x-rogue-agent-id) ─────────────────────────────────
//
// A Gemini subagent's OWN hook events are shape-identical to the main agent's,
// and worse, they are shape-IDENTICAL in their identifying fields too:
// LocalAgentExecutor.executionContext (:347508-347510) hands the subagent the
// PARENT's Config and geminiClient and changes only promptId, so createBaseInput
// (:362493-362495) reads `session_id` off the parent's Config and
// `transcript_path` off the parent's recording service. A subagent's BeforeTool
// and the main agent's BeforeTool are byte-comparable. Nothing in the payload
// separates them, and nothing derived from it can.
//
// What the transcripts DO record is which delegations exist, on a bookkeeping
// rule rather than a timing one:
//
//   a delegation appears in the subagent directory when it STARTS,
//   and in the parent transcript when it ENDS,
//   so (started minus finished) is what is running right now.
//
//   dir      = dirname(transcript_path) / sanitize(session_id)
//   started  = the .jsonl basenames in dir   (each IS a subagent session UUID)
//   finished = those recorded in the parent transcript
//   agentId  = the single remaining one, or nothing
//
// Both sides are append-only records upstream writes for its own reasons, so
// NO timestamp of any kind is read or compared: not file mtimes, not record
// timestamps. The answer is the same however long a hook takes and whatever the
// filesystem does with timestamp resolution.
//
// THAT SET IS NOT WHO FIRED THE EVENT. It is only which delegations are
// unfinished, and the main agent keeps running tools inside that window:
//
//   1. invoke_agent is parallelizable (_isParallelizable, :346515-346525,
//      returns false only for edit tools, update_topic and an explicit
//      wait_for_previous: true), and the scheduler dequeues a maximal run of
//      parallelizable calls and executes them together (:346493). A batch of
//      [invoke_agent, run_shell_command] runs the shell concurrently with the
//      delegation, and the shell's AfterTool fires while the delegation is live.
//   2. The parent's completion record — the ONLY "finished" marker — is written
//      once per MODEL RESPONSE, after the whole scheduler run resolves
//      (:387589 then :387623), not once per batch. A response whose calls split
//      into several batches (any edit tool forces a split) leaves the delegation
//      "live" for every later batch in that response, BeforeTool included.
//
// So `live.length === 1` is not evidence that this event came from inside that
// subagent, and tagging an ordinary tool event on it hands a main-agent
// run_shell_command or replace the subagent's UUID. A wrong id is worse than a
// missing one — it is a false attribution in an audit trail — so ordinary tool
// events carry no tag at all. Recovering per-tool attribution needs a signal
// upstream does not currently emit; it cannot be inferred here.
//
// Bundle citations (Gemini CLI 0.58.0, @google/gemini-cli chunk-MFLFXOVQ.js):
//   :285586-285603  ChatRecordingService.initialize — a subagent's transcript is
//                   `<chats>/<sanitizeFilenamePart(parentSessionId)>/<sessionId>.jsonl`,
//                   while the main session file sits directly in `<chats>/`.
//   :347622         the subagent's sessionId IS its agentId (randomUUID), so the
//                   filename is a real per-instance id, not a slug two runs share.
//   :331632         recordCompletedToolCalls stamps `agentId` on the parent's
//                   completed invoke_agent record. That record is "finished".
//   :340820-340824  the AfterTool payload carries only llmContent/returnDisplay/
//                   error — the tool response's `data.agentId` (:348714) is NOT
//                   relayed, which is why the id is resolved from disk at all.
const PARENT_MAX_BYTES = 32 * 1024 * 1024; // over this, send no header
const CANDIDATE_HEAD_BYTES = 64 * 1024; // enough for a subagent's first record

// The one event the live set can legitimately name: `AfterTool invoke_agent`,
// the delegation's own completion. It is a delegation event by its tool_name, so
// no main-agent tool call can wear the tag, and the id it takes is the id of a
// delegation that is by construction unfinished at that moment — its own.
//
// The two-delegation case resolves conservatively rather than wrongly: a
// parallel batch of two invoke_agent calls leaves both live when either report
// fires, so `live.length !== 1` sends nothing rather than handing agent 1's id
// to agent 2's report.
//
// Every other event is excluded. Non-tool events (BeforeAgent, AfterAgent,
// BeforeModel, SessionStart, …) are never a subagent's, and BeforeAgent carries
// the developer's prompt, where a wrong tag is worst. Ordinary tool events are
// excluded because the live set does not identify who fired them — see the
// window analysis above.
function isAgentTaggableEvent(parsed) {
  return EVENT === "AfterTool" && parsed.tool_name === "invoke_agent";
}

// Read a file as UTF-8, or null if it is missing, unreadable or over `maxBytes`.
function readCapped(file, maxBytes) {
  try {
    if (fs.statSync(file).size > maxBytes) return null;
    return fs.readFileSync(file, "utf8");
  } catch {
    return null;
  }
}

// The delegated prompts recorded in the parent, JSON-escaped for a raw-text
// substring test against a subagent file (see hasDelegatedPrompt). Only lines
// mentioning invoke_agent are parsed; the rest of the transcript is never JSON.
//
// ONLY records that lack an agentId contribute. A record that has one is already
// matched by the substring test on the id itself, so collecting its prompt adds
// no delegation to `finished` — it only widens what the prompt test matches, and
// a prompt is not unique to a delegation. Rerun the same prompt and the OLD
// completed record would mark the NEW live delegation finished, dropping the
// attribution of a delegation that is plainly running. A prompt collected here
// is instead the only trace an errored / cancelled / max-turns delegation left.
function delegatedPrompts(parentText) {
  const out = [];
  for (const line of parentText.split("\n")) {
    if (!line.includes("invoke_agent")) continue;
    let record;
    try {
      record = JSON.parse(line);
    } catch {
      continue;
    }
    for (const call of record?.toolCalls ?? []) {
      if (call?.name !== "invoke_agent") continue;
      if (typeof call?.agentId === "string" && call.agentId) continue;
      const prompt = call?.args?.prompt;
      if (typeof prompt === "string" && prompt) {
        out.push(JSON.stringify(prompt).slice(1, -1));
      }
    }
  }
  return out;
}

// Fallback "finished" key for a delegation that ended WITHOUT an agentId: that
// value is read out of the tool RESPONSE, so an errored / cancelled / max-turns
// agent can be recorded without one, and it would otherwise stay "live" for the
// rest of the session and suppress every later delegation's report. `args` comes
// from the REQUEST and is always there, and the subagent's first `user` record
// embeds the delegated prompt verbatim inside its context preamble.
//
// Compared JSON-escaped against the raw head, so no parse of a possibly
// truncated head is needed and a multi-line prompt still matches. An unreadable
// head returns false, i.e. the candidate stays live and the usual
// unique-or-nothing guard applies.
//
// A prompt is not an identifier, so this cannot prove WHICH delegation it
// finished: rerun a prompt whose earlier delegation ended without an agentId and
// the live rerun matches it too. That direction is deliberate — it costs the
// rerun its header, where the opposite default would leave a dead delegation
// live and hand ITS id to the rerun's report.
function hasDelegatedPrompt(file, escapedPrompts) {
  if (escapedPrompts.length === 0) return false;
  let head = "";
  try {
    const fd = fs.openSync(file, "r");
    try {
      const buf = Buffer.alloc(CANDIDATE_HEAD_BYTES);
      const n = fs.readSync(fd, buf, 0, CANDIDATE_HEAD_BYTES, 0);
      head = buf.subarray(0, n).toString("utf8");
    } finally {
      fs.closeSync(fd);
    }
  } catch {
    return false;
  }
  return escapedPrompts.some((p) => head.includes(p));
}

// Returns the reporting delegation's session UUID, or undefined. NEVER throws:
// every failure path is "no header", because a wrong agent id is worse than a
// missing one and a throw here would cost the POST itself.
//
// Only reached for `AfterTool invoke_agent` — the delegation's own completion,
// which fires before the parent's record of it is written, so the delegation
// that is reporting is still one of the unfinished ones. See isAgentTaggableEvent.
function resolveSubagentId(parsed) {
  try {
    if (!parsed || typeof parsed !== "object") return undefined;
    if (!isAgentTaggableEvent(parsed)) return undefined;

    const transcript = parsed.transcript_path;
    const session = parsed.session_id;
    if (typeof transcript !== "string" || !transcript) return undefined;
    if (typeof session !== "string" || !session) return undefined;

    // Upstream's own sanitizer (:254005-254007); it also makes the joined path
    // traversal-proof, since "/" and "." both become "_".
    const dir = path.join(
      path.dirname(transcript),
      session.replace(/[^a-zA-Z0-9_-]/g, "_"),
    );
    // No delegation in this session → ENOENT → no header, the common case.
    const started = fs
      .readdirSync(dir)
      .filter((f) => f.endsWith(".jsonl"))
      .map((f) => f.slice(0, -".jsonl".length));
    if (started.length === 0) return undefined;

    // Unreadable / absent (recording disabled, conversationFile nulled after
    // ENOSPC) or oversized: `finished` is uncomputable and every candidate would
    // look live, so send nothing.
    const parent = readCapped(transcript, PARENT_MAX_BYTES);
    if (parent === null) return undefined;

    // A subagent UUID appears in the parent on exactly one line, its completion
    // record, so the primary key is a plain substring test that needs no JSON
    // parsing at all. Everything recorded → nothing is running.
    const unresolved = started.filter((id) => !parent.includes(id));
    if (unresolved.length === 0) return undefined;

    // Only what the substring test missed pays for the prompt fallback.
    const prompts = delegatedPrompts(parent);
    const live = unresolved.filter(
      (id) => !hasDelegatedPrompt(path.join(dir, `${id}.jsonl`), prompts),
    );

    // Zero → the reporting delegation was already resolved by the prompt
    // fallback. Two or more → a parallel batch of delegations, which the rule
    // cannot separate. Both send nothing.
    if (live.length !== 1) return undefined;
    // The id is a filename, i.e. arbitrary bytes from disk. An invalid header
    // value makes fetch THROW, which would fail-open the whole POST — far worse
    // than no attribution. It must look like the vendor UUID it is, and the
    // backend rejects (never truncates) an id over 64 chars.
    const id = live[0];
    return /^[A-Za-z0-9_-]{1,64}$/.test(id) ? id : undefined;
  } catch {
    return undefined;
  }
}

// ── Read all of stdin ────────────────────────────────────────────────────────
function readStdin() {
  return new Promise((resolve) => {
    const chunks = [];
    process.stdin.on("data", (c) => chunks.push(c));
    process.stdin.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    process.stdin.on("error", () => resolve(""));
    // If nothing is piped, don't hang.
    if (process.stdin.isTTY) resolve("");
  });
}

async function main() {
  // Already merged at module load (the log destination depends on it) — reuse it
  // rather than re-reading the same three files.
  const env = ENV;
  const apiKey = env.ROGUE_API_KEY || "";

  // SessionStart: fire the detached roster heartbeat, then fall through to POST
  // the event like any other so it is captured for audit. SessionStart is
  // advisory in Gemini (its decision is ignored), so the relayed response can't
  // block — we still send it so nothing is dropped. Unconfigured → emit the
  // /setup hint and return without POSTing.
  if (EVENT === "SessionStart") {
    if (!apiKey) {
      log("outcome=unconfigured");
      return emit({
        systemMessage:
          "[Rogue Security] Not configured. Run /setup to connect your API key.",
      });
    }
    fireHeartbeat("SessionStart");
  }

  if (!apiKey) {
    log("outcome=unconfigured");
    return emit({});
  }

  // AfterAgent is the per-TURN heartbeat trigger: it fires when the agent has
  // finished replying, so the hook log's lines for this turn are already on disk for
  // the shipper that rides along inside heartbeat.mjs. Before this, SessionStart was
  // the only trigger, so a session left open for days produced exactly one beacon and
  // one log upload for its whole lifetime.
  //
  // It falls THROUGH to the POST below like any other event - this is an extra side
  // effect on an event we already relay, not a new branch. No hooks.json change was
  // needed (AfterAgent is already registered), which also means Gemini's hook-trust
  // fingerprint is untouched: a new command string would have left every existing
  // install's hooks unrun until the user re-reviewed them via /hooks.
  //
  // Chosen over SessionEnd, which Gemini explicitly "will not wait" for on exit -
  // the process can be gone before a detached child gets to send anything.
  if (EVENT === "AfterAgent") {
    fireHeartbeat("AfterAgent");
  }

  const payload = await readStdin();
  const actor = resolveActor(env);
  const base = (env.ROGUE_BASE_URL || "https://api.rogue.security").replace(
    /\/+$/,
    "",
  );
  const url = env.ROGUE_API_URL || `${base}/api/v1/hooks/gemini`;
  // Host + version + surface, resolved exactly as heartbeat.mjs does. Sent on
  // every event so the fleet roster's row stays fresh between session starts,
  // which are the only moments the heartbeat runs. See installId.
  const install = installId();
  // Still sent when degraded (never a hard failure — see installId), but an
  // "unknown" host or version means this install reports itself imprecisely to
  // the fleet roster, which is worth seeing in the hook log.
  if (install.error) log(`error=install-id ${install.error}`);

  // Inspect the relayed bytes in a LOCAL. The parse result is only ever read
  // from — `body: payload` below stays the exact bytes Gemini piped in.
  let parsed = null;
  try {
    parsed = JSON.parse(payload);
  } catch {
    parsed = null;
  }
  const agentId = resolveSubagentId(parsed);
  const agentLog = `agent=${agentId || "none"}`;

  let bodyText = "{}";
  try {
    const resp = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-rogue-api-key": apiKey,
        "x-rogue-event": EVENT,
        "x-rogue-actor-email": actor.email,
        "x-rogue-actor-name": actor.name,
        "x-rogue-host": install.host,
        "x-rogue-version": install.version,
        "x-rogue-agent": install.agent,
        // Only the id. The agent NAME is already inside the relayed bytes on the
        // one event that has one (AfterTool invoke_agent's tool_input.agent_name)
        // and the backend reads it from there, so a name header would duplicate a
        // field for zero information.
        ...(agentId ? { "x-rogue-agent-id": agentId } : {}),
      },
      body: payload,
      signal: AbortSignal.timeout(15000),
    });
    if (resp.ok) {
      const text = await resp.text();
      if (text && text.trim()) {
        try {
          JSON.parse(text); // relay only well-formed JSON; malformed → fail-open
          bodyText = text;
        } catch {
          bodyText = "{}";
        }
      }
      log(`http=${resp.status} ${agentLog} ${describeOutcome(bodyText)}`);
    } else {
      log(`http=${resp.status} ${agentLog} outcome=fail-open`);
      bodyText = "{}";
    }
  } catch (e) {
    log(`error="${sanitize(e && e.message)}" ${agentLog} outcome=fail-open`);
    bodyText = "{}";
  }

  return emit(bodyText);
}

main().catch((e) => {
  try {
    log(`error="${sanitize(e && e.message)}" outcome=fail-open`);
  } catch {
    /* ignore */
  }
  emit({});
});
