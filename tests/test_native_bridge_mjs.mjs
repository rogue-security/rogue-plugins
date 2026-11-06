// tests/test_native_bridge_mjs.mjs — the Gemini hand-off seam, Node twin of test_native_bridge_sh.sh:
// native-bridge-install.mjs downloads the pinned native bridge through a mock
// /api/v1/hooks/download, verifies it against the pin and installs it under
// ~/.rogue/bin/rogue-hook/<version>/; hook.mjs, heartbeat.mjs and ship-logs.mjs then hand their job
// to it. A stub script stands in for the binary so this needs no Rust build.
//   node --test tests/test_native_bridge_mjs.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const REPO = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
// Real path: the scripts derive their root from import.meta.url, which resolves symlinks.
const WORK = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "rogue-nb-mjs-")));
const PLUGIN = path.join(WORK, "plugin");
const HOME = path.join(WORK, "home");
const EMPTY = path.join(WORK, "empty");
const BIN_DIR = path.join(HOME, ".rogue", "bin", "rogue-hook");
const PLATFORM =
  process.platform === "darwin"
    ? "darwin-universal"
    : process.arch === "arm64"
      ? "linux-arm64"
      : "linux-amd64";
fs.cpSync(path.join(REPO, "plugins", "gemini"), PLUGIN, { recursive: true });
fs.rmSync(path.join(PLUGIN, "rogue-hook.json"), { force: true });
fs.mkdirSync(HOME, { recursive: true });
fs.mkdirSync(EMPTY, { recursive: true });

// The mock: the download route answers a presigned URL to /blob, which serves the stub binary.
let blob = Buffer.alloc(0);
let requests = [];
const server = http.createServer((req, res) => {
  req.resume();
  if (req.method === "POST") return res.end("{}");
  requests.push(`${req.url} key=${req.headers["x-rogue-api-key"]}`);
  if (req.url.startsWith("/api/v1/hooks/download?")) {
    const url = `http://127.0.0.1:${server.address().port}/blob?X-Amz-Signature=abc&X-Amz-Expires=300`;
    return res.end(JSON.stringify({ url }));
  }
  res.end(blob);
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const BASE = `http://127.0.0.1:${server.address().port}`;
fs.writeFileSync(
  path.join(HOME, ".rogue-env"),
  `export ROGUE_API_KEY=test-key\nexport ROGUE_BASE_URL=${BASE}\n`,
  { mode: 0o600 },
);

// Stub binary: answers --version, echoes its arguments, the plugin root and stdin as the answer, and
// exits with STUB_EXIT after writing "stub-stderr" when that is set.
function stub(version) {
  blob = Buffer.from(
    `#!/bin/sh\n[ "$1" = --version ] && { echo "rogue-hook ${version}"; exit 0; }\n` +
      `[ -n "$STUB_SLEEP" ] && sleep "$STUB_SLEEP"\n` +
      `printf '{"native":"%s root=%s","stdin":%s}' "$*" "$ROGUE_PLUGIN_ROOT" "$(cat)"\n` +
      `[ -n "$STUB_EXIT" ] && { printf stub-stderr >&2; exit "$STUB_EXIT"; }\nexit 0\n`,
  );
}
const sha = (buf) => crypto.createHash("sha256").update(buf).digest("hex");
function pin(version, digest) {
  fs.writeFileSync(
    path.join(PLUGIN, "rogue-hook.json"),
    `{\n  "version": "${version}",\n  "sha256": {\n    "${PLATFORM}": "${digest}"\n  }\n}\n`,
  );
}
const installed = (v) => fs.existsSync(path.join(BIN_DIR, v, "rogue-hook"));
const binaryLog = () => {
  try {
    return fs.readFileSync(path.join(HOME, ".rogue", "hook-binary.log"), "utf8");
  } catch {
    return "";
  }
};

// Runs node <args> with a scrubbed env; async, so the in-process mock keeps answering.
function run(args, { env = {}, stdin = "", cwd = WORK } = {}) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, args, {
      cwd,
      env: { PATH: process.env.PATH, HOME, USERPROFILE: HOME, ...env },
    });
    let out = "";
    let err = "";
    child.stdout.on("data", (c) => (out += c));
    child.stderr.on("data", (c) => (err += c));
    child.on("close", (code) => resolve({ out, err, code }));
    child.stdin.end(stdin);
  });
}
const script = (name) => path.join(PLUGIN, "scripts", name);
async function install(env = {}) {
  requests = [];
  await run([script("native-bridge-install.mjs"), PLUGIN], {
    env: { ROGUE_NATIVE_BRIDGE_RETRY: "0", ...env },
  });
}
const hook = (event, payload, env = {}) =>
  run([script("hook.mjs"), event], {
    stdin: payload,
    env: { ROGUE_BASE_URL: "http://127.0.0.1:9", ...env },
  });
async function until(fn, ms = 10000) {
  for (const end = Date.now() + ms; Date.now() < end; ) {
    if (fn()) return true;
    await new Promise((r) => setTimeout(r, 100));
  }
  return fn();
}

test.after(() => {
  server.close();
  fs.rmSync(WORK, { recursive: true, force: true });
});

const posix = { skip: process.platform === "win32" && "the stub binary is a shell script" };

test("no pin: nothing installed, no download, the script keeps the event", posix, async () => {
  stub("0.1.0");
  await install();
  assert.deepEqual(requests, []);
  assert.equal((await hook("BeforeTool", "{}", { ROGUE_API_KEY: "", HOME: EMPTY })).out, "{}");
});

test("pin, binary missing: hook.mjs answers itself and starts the download", posix, async () => {
  pin("0.1.0", sha(blob));
  requests = [];
  const r = await hook("BeforeTool", "{}", { ROGUE_API_KEY: "", ROGUE_NATIVE_BRIDGE_RETRY: "0" });
  assert.equal(r.out, "{}");
  assert.ok(await until(() => installed("0.1.0")), "the detached download installed it");
  assert.match(binaryLog(), /rogue-hook 0\.1\.0: installed/);
  assert.match(requests[0], /^\/api\/v1\/hooks\/download\?version=0\.1\.0&os=/);
  assert.match(requests[0], /key=test-key$/);
  assert.match(requests[1], /^\/blob\?X-Amz-Signature=abc&X-Amz-Expires=300 /);
  assert.equal(fs.statSync(path.join(BIN_DIR, "0.1.0", "rogue-hook")).mode & 0o111, 0o111);
});

test("binary present: every script hands its job, payload and plugin root to it", posix, async () => {
  const r = await hook("BeforeTool", '{"tool_name":"run_shell_command"}');
  assert.equal(
    r.out,
    `{"native":"gemini BeforeTool root=${PLUGIN}","stdin":{"tool_name":"run_shell_command"}}`,
  );
  assert.equal(r.code, 0);
  const hb = await run([script("heartbeat.mjs"), "AfterAgent"]);
  assert.equal(hb.out, `{"native":"heartbeat gemini AfterAgent root=${PLUGIN}","stdin":}`);
  const ship = await run([script("ship-logs.mjs"), PLUGIN, "gemini", "1.2.3", "gemini"]);
  assert.equal(ship.out, `{"native":"ship-logs gemini 1.2.3 root=${PLUGIN}","stdin":}`);
});

test("stdout, stderr and the exit code are relayed as the binary wrote them", posix, async () => {
  const r = await hook("BeforeTool", "{}", { STUB_EXIT: "3" });
  assert.equal(r.out, `{"native":"gemini BeforeTool root=${PLUGIN}","stdin":{}}`);
  assert.equal(r.err, "stub-stderr");
  assert.equal(r.code, 3);
});

test("a binary that outlives the budget is killed and the fail-open answer written", posix, async () => {
  const code = `import { nativeHandoff } from ${JSON.stringify(script("native-bridge.mjs"))};
    nativeHandoff(${JSON.stringify(PLUGIN)}, "gemini", ["gemini", "BeforeTool"], { budgetMs: 300, failOpen: "{}" });
    process.stdout.write("script kept the job");`;
  const started = Date.now();
  const r = await run(["--input-type=module", "-e", code], { env: { STUB_SLEEP: "5" } });
  assert.equal(r.out, "{}");
  assert.equal(r.code, 0);
  assert.ok(Date.now() - started < 4000, "the budget bounds the wait");
});

test("managed hooks, kill switches and a relative root keep the script", posix, async () => {
  const off = { ROGUE_API_KEY: "", HOME: EMPTY, ROGUE_NATIVE_BRIDGE_DIR: BIN_DIR };
  assert.equal((await hook("BeforeTool", "{}", { ...off, ROGUE_HOOK_SOURCE: "managed" })).out, "{}");
  assert.equal((await hook("BeforeTool", "{}", { ...off, ROGUE_NATIVE_BRIDGE: "0" })).out, "{}");
  assert.equal((await hook("BeforeTool", "{}", { ...off, ROGUE_NATIVE_BRIDGE_GEMINI: "0" })).out, "{}");
  // The shipper takes its root as an argument, so it is the script that can be handed a relative one.
  const rel = await run([script("ship-logs.mjs"), "plugin", "gemini", "1.2.3", "gemini"], {
    env: { ROGUE_API_KEY: "", HOME: EMPTY, ROGUE_NATIVE_BRIDGE_DIR: BIN_DIR },
  });
  assert.equal(rel.out, "");
  // The env file in use can turn the bridge off too.
  const kill = path.join(WORK, "kill-home");
  fs.mkdirSync(kill, { recursive: true });
  fs.writeFileSync(
    path.join(kill, ".rogue-env"),
    "export ROGUE_NATIVE_BRIDGE=0\nexport ROGUE_API_KEY=test-key\nexport ROGUE_BASE_URL=http://127.0.0.1:9\n",
    { mode: 0o600 },
  );
  assert.equal(
    (await hook("BeforeTool", "{}", { HOME: kill, ROGUE_NATIVE_BRIDGE_DIR: BIN_DIR })).out,
    "{}",
  );
});

test("already installed: no download", posix, async () => {
  await install();
  assert.deepEqual(requests, []);
});

test("a download that does not match the pin is never installed", posix, async () => {
  stub("0.2.0");
  pin("0.2.0", "0".repeat(64));
  await install();
  assert.equal(installed("0.2.0"), false);
  assert.match(binaryLog(), /sha256 mismatch/);
  assert.deepEqual(fs.readdirSync(path.join(BIN_DIR, "0.2.0")), [], "no temp file left");
  assert.equal(fs.existsSync(path.join(BIN_DIR, ".lock-0.2.0")), false, "the lock is released");
  const r = await hook("BeforeTool", "{}", {
    ROGUE_API_KEY: "",
    HOME: EMPTY,
    ROGUE_NATIVE_BRIDGE_DIR: BIN_DIR,
    ROGUE_NATIVE_BRIDGE_RETRY: "999999",
  });
  assert.equal(r.out, "{}", "the event stays on the script");
});

test("a binary that reports another version is not installed", posix, async () => {
  pin("0.3.0", sha(blob));
  await install();
  assert.equal(installed("0.3.0"), false);
  assert.match(binaryLog(), /0\.3\.0: downloaded binary does not run here/);
});

test("a failed attempt is not retried inside the retry interval", posix, async () => {
  await install({ ROGUE_NATIVE_BRIDGE_RETRY: "900" });
  assert.deepEqual(requests, []);
});

test("no API key installs nothing", posix, async () => {
  stub("0.4.0");
  pin("0.4.0", sha(blob));
  await install({ HOME: EMPTY });
  assert.equal(installed("0.4.0"), false);
  assert.deepEqual(requests, []);
});
