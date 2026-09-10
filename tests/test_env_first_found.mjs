// tests/test_env_first_found.mjs — the env file rule on the Gemini readers: the
// first of machine (/etc/rogue/env) -> bundled (<ext>/env) -> user (~/.rogue-env)
// that holds ROGUE_API_KEY is used ALONE, and its values override the process env.
// Covers shared.mjs's loadEnvFiles (hook.mjs + heartbeat.mjs), hook.mjs end to end,
// and ship-logs.mjs's own loader through main().
//
// The scripts are copied into a sandbox with the machine path literal redirected -
// the only way to stage that candidate without root. Each case gets its own copy,
// so the module-level HOME constant is re-evaluated and nothing is cached across.
//   node --test tests/test_env_first_found.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";

const REPO = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const SCRIPTS = path.join(REPO, "plugins", "gemini", "scripts");
const MACHINE_EXPR = 'IS_WIN ? "C:\\\\ProgramData\\\\rogue\\\\env" : "/etc/rogue/env"';

// A sandbox: <root>/scripts/*.mjs with the machine path pointing at <root>/machine-env,
// plus an empty HOME. Returns the three candidate paths and the copied script dir.
function sandbox() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "rogue-envff-"));
  const scripts = path.join(root, "scripts");
  const home = path.join(root, "home");
  fs.mkdirSync(scripts);
  fs.mkdirSync(path.join(home, ".rogue", "logs"), { recursive: true });
  const machine = path.join(root, "machine-env");
  let redirected = 0;
  for (const f of fs.readdirSync(SCRIPTS)) {
    if (!f.endsWith(".mjs")) continue;
    let text = fs.readFileSync(path.join(SCRIPTS, f), "utf8");
    if (text.includes(MACHINE_EXPR)) {
      text = text.split(MACHINE_EXPR).join(JSON.stringify(machine));
      redirected++;
    }
    fs.writeFileSync(path.join(scripts, f), text);
  }
  assert.equal(redirected, 2, "shared.mjs and ship-logs.mjs both name the machine env file");
  return {
    root,
    scripts,
    home,
    machine,
    bundled: path.join(root, "env"),
    user: path.join(home, ".rogue-env"),
    cleanup: () => fs.rmSync(root, { recursive: true, force: true }),
  };
}

const write = (file, lines) => fs.writeFileSync(file, lines.join("\n") + "\n", { mode: 0o600 });

// loadEnvFiles() from the sandbox copy, with HOME and the ROGUE_* process env staged.
async function resolve(sb, processEnv) {
  const saved = {};
  for (const k of ["HOME", "USERPROFILE", "ROGUE_API_KEY", "ROGUE_BASE_URL", "ROGUE_ACTOR_EMAIL"]) {
    saved[k] = process.env[k];
    delete process.env[k];
  }
  process.env.HOME = sb.home;
  process.env.USERPROFILE = sb.home;
  Object.assign(process.env, processEnv);
  try {
    const mod = await import(pathToFileURL(path.join(sb.scripts, "shared.mjs")).href);
    return mod.loadEnvFiles();
  } finally {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
}

test("loadEnvFiles: the machine file wins with all three present, nothing merged", async () => {
  const sb = sandbox();
  try {
    write(sb.machine, ["export ROGUE_API_KEY=machine-key", "export ROGUE_BASE_URL=http://machine.invalid"]);
    write(sb.bundled, ["export ROGUE_API_KEY=bundled-key", "export ROGUE_BASE_URL=http://bundled.invalid"]);
    write(sb.user, ["export ROGUE_API_KEY=user-key", "export ROGUE_BASE_URL=http://user.invalid", "export ROGUE_ACTOR_EMAIL=user@example.com"]);
    const env = await resolve(sb, { ROGUE_API_KEY: "process-key" });
    assert.equal(env.ROGUE_API_KEY, "machine-key");
    assert.equal(env.ROGUE_BASE_URL, "http://machine.invalid");
    assert.equal(env.ROGUE_ACTOR_EMAIL, undefined, "a setting only the user file carries has no effect");
  } finally {
    sb.cleanup();
  }
});

test("loadEnvFiles: a machine file without ROGUE_API_KEY is skipped whole", async () => {
  const sb = sandbox();
  try {
    write(sb.machine, ["export ROGUE_BASE_URL=http://machine.invalid"]);
    write(sb.bundled, ["export ROGUE_API_KEY=bundled-key", "export ROGUE_BASE_URL=http://bundled.invalid"]);
    write(sb.user, ["export ROGUE_API_KEY=user-key"]);
    const env = await resolve(sb, {});
    assert.equal(env.ROGUE_API_KEY, "bundled-key");
    assert.equal(env.ROGUE_BASE_URL, "http://bundled.invalid");
  } finally {
    sb.cleanup();
  }
});

test("loadEnvFiles: an empty ROGUE_API_KEY, quoted or bare, does not select the file", async () => {
  const sb = sandbox();
  try {
    write(sb.machine, ["export ROGUE_API_KEY=''", "export ROGUE_BASE_URL=http://machine.invalid"]);
    write(sb.bundled, ["ROGUE_API_KEY=", "export ROGUE_BASE_URL=http://bundled.invalid"]);
    write(sb.user, ["export ROGUE_API_KEY=user-key", "export ROGUE_BASE_URL=http://user.invalid"]);
    const env = await resolve(sb, {});
    assert.equal(env.ROGUE_API_KEY, "user-key");
    assert.equal(env.ROGUE_BASE_URL, "http://user.invalid");
  } finally {
    sb.cleanup();
  }
});

test("loadEnvFiles: the chosen file overrides the process env; unset keys are kept", async () => {
  const sb = sandbox();
  try {
    write(sb.user, ["export ROGUE_API_KEY=user-key"]);
    const env = await resolve(sb, { ROGUE_API_KEY: "process-key", ROGUE_BASE_URL: "http://process.invalid" });
    assert.equal(env.ROGUE_API_KEY, "user-key");
    assert.equal(env.ROGUE_BASE_URL, "http://process.invalid");
  } finally {
    sb.cleanup();
  }
});

test("loadEnvFiles: with no file holding a key, the process env remains", async () => {
  const sb = sandbox();
  try {
    const env = await resolve(sb, { ROGUE_API_KEY: "process-key" });
    assert.equal(env.ROGUE_API_KEY, "process-key");
  } finally {
    sb.cleanup();
  }
});

// hook.mjs end to end: the key that reaches the wire is the machine file's.
test("hook.mjs sends the machine file's key, not the user file's or the process env's", async () => {
  const sb = sandbox();
  const seen = {};
  const server = http.createServer((req, res) => {
    if ((req.url || "").endsWith("/hooks/gemini")) seen.key = req.headers["x-rogue-api-key"];
    req.on("data", () => {});
    req.on("end", () => {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end("{}");
    });
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    write(sb.machine, ["export ROGUE_API_KEY=machine-key", `export ROGUE_BASE_URL=${base}`]);
    write(sb.bundled, ["export ROGUE_API_KEY=bundled-key", `export ROGUE_BASE_URL=${base}`]);
    write(sb.user, ["export ROGUE_API_KEY=user-key", `export ROGUE_BASE_URL=${base}`]);
    const out = await new Promise((resolveOut) => {
      const child = spawn(process.execPath, [path.join(sb.scripts, "hook.mjs"), "BeforeTool"], {
        env: { PATH: process.env.PATH, HOME: sb.home, USERPROFILE: sb.home, ROGUE_API_KEY: "process-key" },
      });
      let stdout = "";
      child.stdout.on("data", (c) => (stdout += c));
      child.on("close", () => resolveOut(stdout));
      child.stdin.end('{"tool_name":"run_shell_command"}');
    });
    assert.equal(out, "{}", "the hook relayed the server body");
    assert.equal(seen.key, "machine-key");
  } finally {
    server.close();
    sb.cleanup();
  }
});

// ship-logs.mjs keeps its own loader; hold it to the same rule through main().
test("ship-logs.mjs uploads with the machine file's key and skips a keyless machine file", async () => {
  for (const { machineLines, expected } of [
    { machineLines: ["export ROGUE_API_KEY=machine-key"], expected: "machine-key" },
    { machineLines: ["export ROGUE_BASE_URL=http://machine.invalid"], expected: "bundled-key" },
  ]) {
    const sb = sandbox();
    const saved = { HOME: process.env.HOME, USERPROFILE: process.env.USERPROFILE, ROGUE_API_KEY: process.env.ROGUE_API_KEY };
    const savedFetch = globalThis.fetch;
    try {
      write(sb.machine, machineLines);
      write(sb.bundled, ["export ROGUE_API_KEY=bundled-key"]);
      write(sb.user, ["export ROGUE_API_KEY=user-key"]);
      fs.writeFileSync(path.join(sb.home, ".rogue", "logs", "gemini.log"), "2026-01-01T00:00:00Z provider=gemini event=BeforeTool\n");
      process.env.HOME = sb.home;
      process.env.USERPROFILE = sb.home;
      process.env.ROGUE_API_KEY = "process-key";
      process.env.ROGUE_ACTOR_EMAIL = "amos@example.com";
      let sentKey = null;
      globalThis.fetch = async (_url, opts) => {
        sentKey = opts.headers["x-rogue-api-key"];
        return { status: 200, ok: true };
      };
      const shipper = await import(pathToFileURL(path.join(sb.scripts, "ship-logs.mjs")).href);
      await shipper.main([sb.root, "gemini", "9.9.9", "gemini"]);
      assert.equal(sentKey, expected);
    } finally {
      globalThis.fetch = savedFetch;
      for (const [k, v] of Object.entries(saved)) {
        if (v === undefined) delete process.env[k];
        else process.env[k] = v;
      }
      delete process.env.ROGUE_ACTOR_EMAIL;
      sb.cleanup();
    }
  }
});
