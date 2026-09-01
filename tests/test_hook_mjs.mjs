// Tests for the Gemini CLI hook dispatcher (plugins/gemini/scripts/hook.mjs).
// Self-contained: uses node:test + a local http server, no external deps.
//   node --test tests/test_hook_mjs.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import os from "node:os";
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const HOOK = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  "plugins",
  "gemini",
  "scripts",
  "hook.mjs",
);

// A throwaway HOME so the hook never reads the developer's real ~/.rogue-env.
function freshHome() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "rogue-gem-"));
}

// Run hook.mjs <event> with `payload` on stdin and `env` overrides; resolve stdout.
function runHook(event, payload, env) {
  return new Promise((resolve) => {
    const home = freshHome();
    const child = spawn(process.execPath, [HOOK, event], {
      env: {
        PATH: process.env.PATH,
        HOME: home,
        USERPROFILE: home,
        ...env,
      },
    });
    let out = "";
    child.stdout.on("data", (c) => (out += c));
    child.on("close", () => {
      fs.rmSync(home, { recursive: true, force: true });
      resolve(out);
    });
    child.stdin.end(payload ?? "");
  });
}

// Start a one-shot server that records the request and replies with `body`.
// `seen.raw` keeps the inbound bytes UNDECODED — the subagent-attribution tests
// assert the POSTed body is byte-identical to what was piped in on stdin.
function startServer(status, body) {
  return new Promise((resolve) => {
    const seen = {};
    const server = http.createServer((req, res) => {
      // SessionStart also spawns the DETACHED heartbeat (hook.mjs fireHeartbeat),
      // which POSTs its own body to /api/v1/hooks/status and races the event
      // POST. Answer it, but never let it overwrite what the event POST recorded,
      // or a SessionStart assertion reads the heartbeat's body instead.
      const isHeartbeat = (req.url || "").endsWith("/hooks/status");
      if (!isHeartbeat) seen.headers = req.headers;
      const chunks = [];
      req.on("data", (c) => chunks.push(c));
      req.on("end", () => {
        if (!isHeartbeat) {
          seen.raw = Buffer.concat(chunks);
          seen.body = seen.raw.toString("utf8");
        }
        res.writeHead(status, { "Content-Type": "application/json" });
        res.end(body);
      });
    });
    server.listen(0, "127.0.0.1", () =>
      resolve({ server, seen, port: server.address().port }),
    );
  });
}

// Same as runHook, but keeps the sandbox long enough to read the hook log back.
// The log is the whole subject of the surface tests below, and runHook deletes it.
function runHookReadLog(event, payload, env) {
  return new Promise((resolve) => {
    const home = freshHome();
    const child = spawn(process.execPath, [HOOK, event], {
      env: { PATH: process.env.PATH, HOME: home, USERPROFILE: home, ...env },
    });
    let out = "";
    child.stdout.on("data", (c) => (out += c));
    child.on("close", () => {
      const logFile = path.join(home, ".rogue", "logs", "gemini.log");
      const lines = fs.existsSync(logFile)
        ? fs.readFileSync(logFile, "utf8").split("\n").filter(Boolean)
        : [];
      fs.rmSync(home, { recursive: true, force: true });
      resolve({ out, lines });
    });
    child.stdin.end(payload ?? "");
  });
}

// One file per agent family means every surface of that family appends to the same
// gemini.log, and until this token nothing on the line said which one wrote it.
// Gemini has exactly ONE surface, so the value is a constant - but it must still
// appear, be spelled the way the heartbeat spells it, and sit where the sh and
// PowerShell dispatchers put it, or a reader cannot use one rule for all six.
test("every line carries surface=gemini_cli, between provider= and event=", async () => {
  const { lines } = await runHookReadLog("BeforeTool", "{}", {});
  assert.equal(lines.length, 1);
  assert.match(
    lines[0],
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z provider=gemini surface=gemini_cli event=BeforeTool outcome=unconfigured$/,
  );
});

test("the surface slug is what heartbeat.mjs reports as the roster agent", async () => {
  // Three consumers, one vocabulary. If these drift, a log line and the roster row
  // for the same install name different surfaces - worse than the line naming none.
  // The literal lives in shared.mjs and nowhere else: installId() sends it as
  // x-rogue-agent, hook.mjs stamps it on each log line, heartbeat.mjs sends it as
  // the roster agent. A re-declaration in either consumer is the drift this guards.
  const dir = path.dirname(HOOK);
  const shared = fs.readFileSync(path.join(dir, "shared.mjs"), "utf8");
  assert.match(shared, /export const SURFACE = "gemini_cli";/);
  assert.match(shared, /agent: SURFACE/);

  const heartbeat = fs.readFileSync(path.join(dir, "heartbeat.mjs"), "utf8");
  assert.match(heartbeat, /agent: install\.agent/);
  // Prose may name the surface; a second assignment of it is the drift.
  assert.doesNotMatch(heartbeat, /agent:\s*"gemini_cli"/);

  const hook = fs.readFileSync(HOOK, "utf8");
  assert.match(hook, /\bSURFACE,/);
  assert.doesNotMatch(hook, /const SURFACE =/);
});

test("the token is emitted through the optional form, never as a placeholder", async () => {
  // The other five dispatchers omit the whole token when they cannot determine a
  // surface. Gemini always can, so the guard here is that the emit is written in
  // that same conditional form rather than pasted into the template - a constant
  // that is later made conditional must not start writing `surface=` or
  // `surface=unknown`, both of which a reader cannot tell from a real value.
  const hook = fs.readFileSync(HOOK, "utf8");
  assert.match(hook, /SURFACE \? ` surface=\$\{SURFACE\}` : ""/);
  const { lines } = await runHookReadLog("BeforeTool", "{}", {});
  assert.doesNotMatch(lines[0], /surface=unknown|surface=(\s|$)/);
});

test("no API key → fail-open {}", async () => {
  const out = await runHook("BeforeAgent", '{"prompt":"hi"}', {});
  assert.equal(out, "{}");
});

test("SessionStart unconfigured → systemMessage hint, no POST", async () => {
  const out = await runHook("SessionStart", "", {});
  const j = JSON.parse(out);
  assert.match(j.systemMessage, /Rogue Security/);
  assert.match(j.systemMessage, /\/setup/);
});

test("relays server body verbatim and sends the right headers", async () => {
  const denyBody = JSON.stringify({ decision: "deny", reason: "blocked by test" });
  const { server, seen, port } = await startServer(200, denyBody);
  try {
    const out = await runHook("BeforeTool", '{"tool_name":"run_shell_command"}', {
      ROGUE_API_KEY: "rsk_test",
      ROGUE_ACTOR_EMAIL: "dev@example.com",
      ROGUE_ACTOR_NAME: "Dev",
      ROGUE_BASE_URL: `http://127.0.0.1:${port}`,
    });
    assert.equal(out, denyBody, "stdout must be the server body verbatim");
    assert.equal(seen.headers["x-rogue-event"], "BeforeTool");
    assert.equal(seen.headers["x-rogue-api-key"], "rsk_test");
    assert.equal(seen.headers["x-rogue-actor-email"], "dev@example.com");
    assert.equal(seen.headers["x-rogue-actor-name"], "Dev");
    // Fleet-liveness trio: the same host/version/agent the heartbeat sends, on
    // EVERY event, so the roster row is refreshed by ordinary traffic and not
    // only at SessionStart. `agent` must stay the PLUGIN_REPOS key, or the
    // backend stops resolving a latest version for these rows. Host and version
    // are machine-specific, so they are only asserted non-empty (see installId).
    assert.equal(seen.headers["x-rogue-agent"], "gemini_cli");
    assert.ok(seen.headers["x-rogue-host"], "x-rogue-host sent on every event");
    assert.ok(seen.headers["x-rogue-version"], "x-rogue-version sent on every event");
    assert.equal(seen.body, '{"tool_name":"run_shell_command"}');
  } finally {
    server.close();
  }
});

test("allow response ({}) relays verbatim", async () => {
  const { server, port } = await startServer(200, "{}");
  try {
    const out = await runHook("AfterTool", '{"tool_name":"x"}', {
      ROGUE_API_KEY: "rsk_test",
      ROGUE_BASE_URL: `http://127.0.0.1:${port}`,
    });
    assert.equal(out, "{}");
  } finally {
    server.close();
  }
});

test("non-200 → fail-open {}", async () => {
  const { server, port } = await startServer(500, "boom");
  try {
    const out = await runHook("BeforeAgent", '{"prompt":"hi"}', {
      ROGUE_API_KEY: "rsk_test",
      ROGUE_BASE_URL: `http://127.0.0.1:${port}`,
    });
    assert.equal(out, "{}");
  } finally {
    server.close();
  }
});

test("200 with malformed (non-JSON) body → fail-open {}", async () => {
  const { server, port } = await startServer(200, "not json <html>oops");
  try {
    const out = await runHook("BeforeTool", '{"tool_name":"x"}', {
      ROGUE_API_KEY: "rsk_test",
      ROGUE_BASE_URL: `http://127.0.0.1:${port}`,
    });
    assert.equal(out, "{}", "malformed 200 body must not be relayed verbatim");
  } finally {
    server.close();
  }
});

test("unreachable endpoint → fail-open {}", async () => {
  const out = await runHook("BeforeAgent", '{"prompt":"hi"}', {
    ROGUE_API_KEY: "rsk_test",
    // 127.0.0.1:1 is not listening → connection refused → fail-open.
    ROGUE_BASE_URL: "http://127.0.0.1:1",
  });
  assert.equal(out, "{}");
});

// Start a server that COLLECTS every request (keyed by url). SessionStart also
// fires the detached heartbeat to /hooks/status, so a one-shot server would
// race — this lets us pick out the /hooks/gemini request deterministically.
function startCollectingServer(status, body) {
  return new Promise((resolve) => {
    const requests = [];
    const server = http.createServer((req, res) => {
      let b = "";
      req.on("data", (c) => (b += c));
      req.on("end", () => {
        requests.push({ url: req.url, headers: req.headers, body: b });
        res.writeHead(status, { "Content-Type": "application/json" });
        res.end(body);
      });
    });
    server.listen(0, "127.0.0.1", () =>
      resolve({ server, requests, port: server.address().port }),
    );
  });
}

test("SessionStart configured → POSTs the event and relays body", async () => {
  const relayed = JSON.stringify({ systemMessage: "welcome" });
  const { server, requests, port } = await startCollectingServer(200, relayed);
  try {
    const out = await runHook("SessionStart", '{"session_id":"s1"}', {
      ROGUE_API_KEY: "rsk_test",
      ROGUE_ACTOR_EMAIL: "dev@example.com",
      ROGUE_ACTOR_NAME: "Dev",
      ROGUE_BASE_URL: `http://127.0.0.1:${port}`,
    });
    // The /hooks/gemini POST must have happened with the SessionStart event.
    const gem = requests.find((r) => r.url.endsWith("/api/v1/hooks/gemini"));
    assert.ok(gem, "SessionStart must POST to /api/v1/hooks/gemini");
    assert.equal(gem.headers["x-rogue-event"], "SessionStart");
    assert.equal(gem.body, '{"session_id":"s1"}');
    // …and the server body is relayed verbatim on stdout.
    assert.equal(out, relayed);
  } finally {
    server.close();
  }
});

test("SessionEnd → POSTs with x-rogue-event SessionEnd", async () => {
  const { server, seen, port } = await startServer(200, "{}");
  try {
    const out = await runHook("SessionEnd", '{"session_id":"s1"}', {
      ROGUE_API_KEY: "rsk_test",
      ROGUE_BASE_URL: `http://127.0.0.1:${port}`,
    });
    assert.equal(seen.headers["x-rogue-event"], "SessionEnd");
    assert.equal(out, "{}");
  } finally {
    server.close();
  }
});

// ── Subagent attribution (x-rogue-agent-id) ─────────────────────────────────
// The dispatcher resolves the running delegation as (subagent files present)
// minus (delegations the parent transcript records as finished), and sends the
// single remaining session UUID as x-rogue-agent-id. These fixtures are literal
// transcript records copied in shape from a real Gemini 0.55.1 session; NO
// timestamp, mtime or ordering is manipulated anywhere, because the rule reads
// none.

const SESSION_ID = "d0fc529c-7537-40db-8302-ae175ef23655";
const SUB_A = "f2401533-ab7c-4e7c-9a75-603c29d9e9c6";
const SUB_B = "9db87efe-1f9e-4b8a-a41b-9367fb677095";
const PROMPT_A = "How do I create a custom subagent?\nGive me the details.";
const PROMPT_B = "Write a poem about the sea.";

// The parent's completed invoke_agent record. recordCompletedToolCalls stamps
// `agentId` with the subagent's session UUID; an abnormally terminated
// delegation is recorded WITHOUT it (agentId comes from the tool response).
function completionRecord(prompt, agentId) {
  return JSON.stringify({
    id: "3cd90726-47e3-432a-ba34-bb9ccbbced71",
    timestamp: "2026-08-13T09:25:14.818Z",
    type: "gemini",
    content: "",
    toolCalls: [
      {
        id: "invoke_agent__call_500699",
        name: "invoke_agent",
        args: { agent_name: "cli_help", prompt, wait_for_previous: true },
        status: "success",
        ...(agentId ? { agentId } : {}),
      },
    ],
  });
}

// A subagent transcript: its header plus the first `user` record, which embeds
// the delegated prompt verbatim inside the context preamble. Nothing else in
// the file is ever read.
function subagentFile(uuid, prompt) {
  return `${JSON.stringify({
    sessionId: uuid,
    projectHash: "52b218b5",
    startTime: "2026-08-13T09:27:02.187Z",
    lastUpdated: "2026-08-13T09:27:02.187Z",
    kind: "subagent",
    directories: ["/tmp/project"],
  })}\n${JSON.stringify({
    id: "e4da2b35-0de8-419f-acdb-d37187939a9f",
    timestamp: "2026-08-13T09:27:05.698Z",
    type: "user",
    content: [{ text: `\n<loaded_context>\n...\n</loaded_context>\n${prompt}` }],
  })}\n`;
}

// Build chats/<parent>.jsonl + chats/<session id>/<uuid>.jsonl and return the
// transcript path. `subagents` is a list of [uuid, prompt] pairs.
function makeChats(parentRecords, subagents, { noSubDir = false } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "rogue-gem-chats-"));
  const chats = path.join(root, "chats");
  fs.mkdirSync(chats, { recursive: true });
  if (!noSubDir) {
    fs.mkdirSync(path.join(chats, SESSION_ID));
    for (const [uuid, prompt] of subagents) {
      fs.writeFileSync(
        path.join(chats, SESSION_ID, `${uuid}.jsonl`),
        subagentFile(uuid, prompt),
      );
    }
  }
  const transcript = path.join(chats, "session-2026-08-13T09-24-d0fc529c.jsonl");
  fs.writeFileSync(transcript, parentRecords.map((r) => `${r}\n`).join(""));
  return { root, transcript };
}

// POST one event and return the x-rogue-agent-id header (undefined = not sent).
// Asserts on every call that the body relayed is byte-identical to stdin.
async function agentIdFor(event, payload) {
  const { server, seen, port } = await startServer(200, "{}");
  try {
    await runHook(event, payload, {
      ROGUE_API_KEY: "rsk_test",
      ROGUE_BASE_URL: `http://127.0.0.1:${port}`,
    });
    assert.deepEqual(
      seen.raw,
      Buffer.from(payload, "utf8"),
      "the POSTed body must be the stdin bytes, unmodified",
    );
    return seen.headers["x-rogue-agent-id"];
  } finally {
    server.close();
  }
}

// Standard tool-event payload: only the base fields Gemini actually sends.
function toolPayload(transcript, toolName) {
  return JSON.stringify({
    session_id: SESSION_ID,
    transcript_path: transcript,
    cwd: "/tmp/project",
    hook_event_name: "BeforeTool",
    tool_name: toolName,
    tool_input: { command: "ls" },
  });
}

test("one live delegation → sends its UUID as x-rogue-agent-id", async () => {
  const { root, transcript } = makeChats([], [[SUB_A, PROMPT_A]]);
  try {
    assert.equal(
      await agentIdFor("AfterTool", toolPayload(transcript, "run_shell_command")),
      SUB_A,
    );
    assert.equal(
      await agentIdFor("BeforeTool", toolPayload(transcript, "run_shell_command")),
      SUB_A,
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("two live delegations → no header (concurrency is unattributable)", async () => {
  const { root, transcript } = makeChats(
    [],
    [
      [SUB_A, PROMPT_A],
      [SUB_B, PROMPT_B],
    ],
  );
  try {
    assert.equal(
      await agentIdFor("AfterTool", toolPayload(transcript, "run_shell_command")),
      undefined,
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("delegation recorded in the parent (agentId) → finished, no header", async () => {
  const { root, transcript } = makeChats(
    [completionRecord(PROMPT_A, SUB_A)],
    [[SUB_A, PROMPT_A]],
  );
  try {
    assert.equal(
      await agentIdFor("AfterTool", toolPayload(transcript, "run_shell_command")),
      undefined,
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("finished delegation + one live one → only the live UUID", async () => {
  const { root, transcript } = makeChats(
    [completionRecord(PROMPT_A, SUB_A)],
    [
      [SUB_A, PROMPT_A],
      [SUB_B, PROMPT_B],
    ],
  );
  try {
    assert.equal(
      await agentIdFor("AfterTool", toolPayload(transcript, "run_shell_command")),
      SUB_B,
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("abnormal termination (record without agentId) → prompt marks it finished", async () => {
  // The delegation is recorded but carries no agentId (errored / cancelled /
  // max-turns). Without the args.prompt fallback it would look live forever and
  // mis-tag every later main-agent tool call.
  const { root, transcript } = makeChats(
    [completionRecord(PROMPT_A, null)],
    [[SUB_A, PROMPT_A]],
  );
  try {
    assert.equal(
      await agentIdFor("AfterTool", toolPayload(transcript, "run_shell_command")),
      undefined,
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("no subagent directory → no header", async () => {
  const { root, transcript } = makeChats([], [], { noSubDir: true });
  try {
    assert.equal(
      await agentIdFor("AfterTool", toolPayload(transcript, "run_shell_command")),
      undefined,
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("parent transcript missing or oversized → no header", async () => {
  const missing = makeChats([], [[SUB_A, PROMPT_A]]);
  try {
    fs.rmSync(missing.transcript);
    assert.equal(
      await agentIdFor(
        "AfterTool",
        toolPayload(missing.transcript, "run_shell_command"),
      ),
      undefined,
      "unreadable parent → finished is uncomputable → no header",
    );
  } finally {
    fs.rmSync(missing.root, { recursive: true, force: true });
  }

  const big = makeChats([], [[SUB_A, PROMPT_A]]);
  try {
    // Sparse grow past the 32 MB cap; only statSync().size is consulted.
    fs.truncateSync(big.transcript, 32 * 1024 * 1024 + 1);
    assert.equal(
      await agentIdFor("AfterTool", toolPayload(big.transcript, "run_shell_command")),
      undefined,
    );
  } finally {
    fs.rmSync(big.root, { recursive: true, force: true });
  }
});

test("invoke_agent: BeforeTool sends no header, AfterTool sends the id", async () => {
  // BeforeTool invoke_agent is the MAIN agent's delegation request, and in a
  // parallel batch the first delegation's file already exists when the second's
  // BeforeTool fires — tagging it would attribute agent 1's id to agent 2.
  const { root, transcript } = makeChats([], [[SUB_A, PROMPT_A]]);
  try {
    assert.equal(
      await agentIdFor("BeforeTool", toolPayload(transcript, "invoke_agent")),
      undefined,
    );
    assert.equal(
      await agentIdFor("AfterTool", toolPayload(transcript, "invoke_agent")),
      SUB_A,
      "the delegation report IS the subagent's own output",
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("non-tool events never carry the tag", async () => {
  const { root, transcript } = makeChats([], [[SUB_A, PROMPT_A]]);
  const payload = JSON.stringify({
    session_id: SESSION_ID,
    transcript_path: transcript,
    cwd: "/tmp/project",
  });
  try {
    for (const event of ["SessionStart", "BeforeAgent", "AfterAgent", "BeforeModel"]) {
      assert.equal(await agentIdFor(event, payload), undefined, event);
    }
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("malformed / minimal payloads resolve to no header, never a failed POST", async () => {
  assert.equal(await agentIdFor("AfterTool", "not json at all"), undefined);
  assert.equal(await agentIdFor("AfterTool", '{"tool_name":"x"}'), undefined);
  assert.equal(
    await agentIdFor("AfterTool", '{"session_id":123,"transcript_path":null}'),
    undefined,
  );
});

test("body stays byte-identical even when a header is added", async () => {
  const { root, transcript } = makeChats([], [[SUB_A, PROMPT_A]]);
  // Pretty-printed, non-ASCII, trailing newline: anything re-serialized would
  // come back compacted and/or re-escaped.
  const payload = `${JSON.stringify(
    {
      session_id: SESSION_ID,
      transcript_path: transcript,
      tool_name: "run_shell_command",
      tool_input: { command: "echo 'héllo — 世界' # \\u0041" },
    },
    null,
    2,
  )}\n`;
  const { server, seen, port } = await startServer(200, "{}");
  try {
    await runHook("AfterTool", payload, {
      ROGUE_API_KEY: "rsk_test",
      ROGUE_BASE_URL: `http://127.0.0.1:${port}`,
    });
    assert.equal(seen.headers["x-rogue-agent-id"], SUB_A);
    assert.deepEqual(seen.raw, Buffer.from(payload, "utf8"));
  } finally {
    server.close();
    fs.rmSync(root, { recursive: true, force: true });
  }
});
