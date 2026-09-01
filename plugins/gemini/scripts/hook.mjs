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
// use Node built-ins only (global fetch, node:fs/os/path/child_process) — no
// curl, no jq, no dependencies, no build step.
//
// Fail-open by design: any missing key / network error / bad response prints
// "{}" (allow) and exits 0. stdout carries ONLY the final JSON, per the Gemini
// hook contract; everything else goes to the log file.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import {
  HOME,
  SCRIPT_DIR,
  SURFACE,
  loadEnvFiles,
  gitConfig,
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
// replaced. Precedence inside the merge: bundled env → MDM → per-user, then
// process env wins (see shared.mjs).
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

// Actor cascade (mirrors scripts/actor.sh): env → git --global → host/user.
function resolveActor(env) {
  const email =
    env.ROGUE_ACTOR_EMAIL ||
    gitConfig("user.email") ||
    os.hostname() ||
    "unknown";
  let name = env.ROGUE_ACTOR_NAME || gitConfig("user.name");
  if (!name) {
    try {
      name = os.userInfo().username;
    } catch {
      name = "unknown";
    }
  }
  return { email, name: name || "unknown" };
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
// A Gemini subagent's OWN hook events are shape-identical to the main agent's:
// createBaseInput emits only session_id / transcript_path / cwd /
// hook_event_name / timestamp, and nothing in the payload names the delegation
// that is running. But Gemini's own transcript records do, and the rule is a
// BOOKKEEPING one rather than a timing one:
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
// Bundle citations (Gemini CLI 0.55.1, @google/gemini-cli chunk-TBDX7VEE.js):
//   :285510-285531  ChatRecordingService.initialize — a subagent's transcript is
//                   `<chats>/<sanitizeFilenamePart(parentSessionId)>/<sessionId>.jsonl`,
//                   while the main session file sits directly in `<chats>/`.
//   :253978-253980  sanitizeFilenamePart = part.replace(/[^a-zA-Z0-9_-]/g, "_").
//   :331296         recordCompletedToolCalls stamps `agentId` (the subagent's
//                   session UUID, i.e. its filename) on the parent's completed
//                   invoke_agent record. That record is the "finished" marker.
//
// THE ONE ASSUMPTION: the parent's completion record must land BEFORE the main
// agent's next tool hook. It does structurally, not by timing margin —
// recordCompletedToolCalls is documented (:331283-331284) as running "before
// sending responses to Gemini" and its caller (:347827) invokes it as soon as
// scheduleAgentTools resolves, so the model roundtrip that produces the next
// tool call cannot precede it. If upstream ever reordered that, a finished
// delegation would stay "live" and a MAIN-agent tool row would be tagged with a
// subagent's UUID. That is the only route in this design to a WRONG id; every
// other failure yields no header at all. A main-agent row carrying a subagent
// UUID is the signature to look for after a Gemini version bump.
//
// The same ordering is what makes the delegation report itself work: the
// AfterTool invoke_agent hook fires before the completion record is written, so
// the finishing delegation is still "live" and its report row gets the id.

// Cost guards. A session that never delegates pays one ENOENT and stops.
const PARENT_MAX_BYTES = 32 * 1024 * 1024; // over this, send no header
const CANDIDATE_HEAD_BYTES = 64 * 1024; // enough for a subagent's first record

// Which events may carry the tag. Only a tool event can be fired BY a subagent.
// BeforeAgent/AfterAgent/BeforeModel/SessionStart/... are never a subagent's,
// and BeforeAgent carries the developer's prompt, where a wrong tag is worst.
//
// `BeforeTool invoke_agent` (the main agent's delegation REQUEST) is excluded as
// a CORRECTNESS GUARD, not merely for semantics: in a parallel batch of two
// invoke_agent calls the first delegation's file already exists when the
// second's BeforeTool fires, so the rule would hand the FIRST agent's id to the
// SECOND agent's request. Suppressing the event removes the case entirely.
// (Delegations are parallelizable: _isParallelizable, :346148, returns false
// only for edit tools, update_topic, and an explicit wait_for_previous: true.)
// `AfterTool invoke_agent` is included — that one IS the subagent's own report.
function isAgentTaggableEvent(parsed) {
  if (EVENT === "AfterTool") return true;
  if (EVENT === "BeforeTool") return parsed.tool_name !== "invoke_agent";
  return false;
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
      const prompt = call?.args?.prompt;
      if (call?.name === "invoke_agent" && typeof prompt === "string" && prompt) {
        out.push(JSON.stringify(prompt).slice(1, -1));
      }
    }
  }
  return out;
}

// Fallback "finished" key for a delegation that ended WITHOUT an agentId: that
// value is read out of the tool RESPONSE, so an errored / cancelled / max-turns
// agent can be recorded without one, and it would otherwise stay "live" for the
// rest of the session and mis-tag every later main-agent tool call. `args` comes
// from the REQUEST and is always there, and the subagent's first `user` record
// embeds the delegated prompt verbatim inside its context preamble.
//
// Compared JSON-escaped against the raw head, so no parse of a possibly
// truncated head is needed and a multi-line prompt still matches. An unreadable
// head returns false, i.e. the candidate stays live and the usual
// unique-or-nothing guard applies.
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

// Returns the running delegation's session UUID, or undefined. NEVER throws:
// every failure path is "no header", because a wrong agent id is worse than a
// missing one and a throw here would cost the POST itself.
function resolveSubagentId(parsed) {
  try {
    if (!parsed || typeof parsed !== "object") return undefined;
    if (!isAgentTaggableEvent(parsed)) return undefined;

    const transcript = parsed.transcript_path;
    const session = parsed.session_id;
    if (typeof transcript !== "string" || !transcript) return undefined;
    if (typeof session !== "string" || !session) return undefined;

    // Upstream's own sanitizer (:253978-253980); it also makes the joined path
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

    // Zero → a main-agent event. Two or more → concurrent delegations, which the
    // rule cannot separate. Both send nothing.
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
