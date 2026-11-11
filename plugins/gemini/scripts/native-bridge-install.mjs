#!/usr/bin/env node
// Rogue Security — installs the native bridge pinned in <plugin>/rogue-hook.json. Started detached
// by native-bridge.mjs whenever the pinned version is missing. Node twin of
// scripts/shared/native-bridge-install.sh; read that file for the contract.
//
//   node native-bridge-install.mjs <plugin-root>
//
// Downloads through GET /api/v1/hooks/download with the API key, then installs only a file whose
// sha256 matches the pin and whose --version reports the pinned version, by an atomic rename into
// ~/.rogue/bin/rogue-hook/<version>/rogue-hook[.exe]. Any failure leaves nothing at that path, so
// the script bridge keeps handling events. A failed attempt is retried after
// ROGUE_NATIVE_BRIDGE_RETRY seconds (default 900, numeric zero = every time), never per event.
// Every attempt's outcome is appended to ~/.rogue/hook-binary.log.

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { HOME, IS_WIN, loadEnvFiles, nativePathIsProtected } from "./shared.mjs";
import { EXE, nativeDir, pinnedVersion } from "./native-bridge.mjs";

const ROOT = process.argv[2] || "";
const now = () => Math.floor(Date.now() / 1000);

let version = "";
let lock = "";
let tmp = "";
process.on("exit", () => {
  if (tmp) fs.rmSync(tmp, { force: true });
  if (lock) fs.rmSync(lock, { recursive: true, force: true });
});

function say(msg) {
  const ts = new Date().toISOString().replace(/\.\d+Z$/, "Z");
  try {
    fs.appendFileSync(path.join(HOME, ".rogue", "hook-binary.log"), `${ts} rogue-hook ${version}: ${msg}\n`);
  } catch {
    /* best-effort */
  }
}

// Creates `dir` and its missing parents under umask 022, like the sh and PowerShell installers, so
// no directory is ever group- or other-writable, not even between mkdir and a chmod.
function makeDir(dir) {
  if (IS_WIN) return void fs.mkdirSync(dir, { recursive: true });
  const old = process.umask(0o022);
  try {
    fs.mkdirSync(dir, { recursive: true });
  } finally {
    process.umask(old);
  }
}

function giveUp(why) {
  say(`${why}; the script bridge handles events`);
  process.exit(0);
}

// macOS ships one universal binary, so its arch is only a label for the route. An x64 Node on an
// ARM64 Windows machine reports x64 and keeps the real arch in PROCESSOR_ARCHITEW6432.
function platform() {
  if (process.platform === "darwin") return { os: "darwin", arch: "arm64", key: "darwin-universal" };
  const cpu = IS_WIN
    ? process.env.PROCESSOR_ARCHITEW6432 || process.env.PROCESSOR_ARCHITECTURE || ""
    : process.arch;
  const arch = { x64: "amd64", AMD64: "amd64", arm64: "arm64", ARM64: "arm64" }[cpu];
  const os = IS_WIN ? "windows" : process.platform;
  if (!arch || !["linux", "windows"].includes(os)) giveUp(`unsupported platform ${os}-${cpu}`);
  return { os, arch, key: `${os}-${arch}` };
}

async function main() {
  if (!path.isAbsolute(ROOT)) return;
  version = pinnedVersion(ROOT);
  if (!version) return;
  const env = loadEnvFiles();
  const dir = nativeDir(env);
  const dest = path.join(dir, version, EXE);
  if (fs.existsSync(dest)) return;
  // Same rule as the hand-off, before and after creating the install directory: another user must
  // not be able to replace any directory above it.
  const versionDir = path.join(dir, version);
  const unsafe = () => giveUp(`${versionDir} is not protected from other users`);
  try {
    makeDir(path.join(HOME, ".rogue"));
  } catch {
    return;
  }
  if (!nativePathIsProtected(dest)) unsafe();
  try {
    makeDir(dir);
  } catch {
    return;
  }
  if (!nativePathIsProtected(dest)) unsafe();

  // One attempt at a time, and not again until the retry interval has passed.
  const lockDir = path.join(dir, `.lock-${version}`);
  try {
    fs.mkdirSync(lockDir);
  } catch {
    let stale = false;
    try {
      stale = Date.now() - fs.statSync(lockDir).mtimeMs > 10 * 60 * 1000;
    } catch {
      /* gone meanwhile */
    }
    if (!stale) return;
    try {
      fs.rmSync(lockDir, { recursive: true, force: true });
      fs.mkdirSync(lockDir);
    } catch {
      return;
    }
  }
  lock = lockDir;
  const stamp = path.join(dir, `.attempt-${version}`);
  const raw = process.env.ROGUE_NATIVE_BRIDGE_RETRY ?? "900";
  const retry = /^[0-9]{1,9}$/.test(raw) ? Number(raw) : 900;
  if (retry > 0) {
    try {
      const last = fs.readFileSync(stamp, "utf8").split("\n")[0].trim();
      if (/^[0-9]{1,18}$/.test(last) && Number(last) <= now() && now() - Number(last) < retry) return;
    } catch {
      /* no stamp yet */
    }
  }
  try {
    fs.writeFileSync(stamp, `${now()}\n`);
  } catch {
    /* best-effort */
  }

  const { os, arch, key } = platform();
  const pin = fs.readFileSync(path.join(ROOT, "rogue-hook.json"), "utf8");
  const want = pin.match(new RegExp(`^\\s*"${key}"\\s*:\\s*"([0-9a-f]+)"`, "m"))?.[1];
  if (!want) giveUp(`no pinned sha256 for ${key}`);

  // Same env file rule as the hooks: the first trusted file holding ROGUE_API_KEY is used alone.
  const apiKey = env.ROGUE_API_KEY || "";
  if (!apiKey) giveUp("no ROGUE_API_KEY");
  const base = (env.ROGUE_BASE_URL || "https://api.rogue.security").replace(/\/+$/, "");
  let url = "";
  try {
    const resp = await fetch(
      `${base}/api/v1/hooks/download?version=${version}&os=${os}&arch=${arch}`,
      { headers: { "x-rogue-api-key": apiKey }, signal: AbortSignal.timeout(15000) },
    );
    if (resp.ok) url = (await resp.json())?.url || "";
  } catch {
    /* handled below */
  }
  if (typeof url !== "string" || !url) giveUp(`no download URL for ${key}`);

  try {
    makeDir(versionDir);
  } catch {
    giveUp(`cannot create ${versionDir}`);
  }
  if (!nativePathIsProtected(dest)) unsafe();
  tmp = path.join(dir, version, `.rogue-hook.download.${process.pid}${IS_WIN ? ".exe" : ""}`);
  let data;
  try {
    const resp = await fetch(url, { signal: AbortSignal.timeout(120000) });
    if (!resp.ok) throw new Error(`http ${resp.status}`);
    data = Buffer.from(await resp.arrayBuffer());
    fs.writeFileSync(tmp, data, { mode: 0o755 });
  } catch {
    giveUp("download failed");
  }
  const got = crypto.createHash("sha256").update(data).digest("hex");
  if (got !== want) giveUp(`sha256 mismatch: got ${got}, pinned ${want}`);
  if (!IS_WIN) fs.chmodSync(tmp, 0o755);
  // Catches a binary this machine cannot run (noexec mount, wrong arch) before a hook hands to it.
  const probe = spawnSync(tmp, ["--version"], { timeout: 10000, windowsHide: true, encoding: "utf8" });
  if ((probe.stdout || "").replace(/\r?\n+$/, "") !== `rogue-hook ${version}`) {
    giveUp("downloaded binary does not run here");
  }
  try {
    fs.renameSync(tmp, dest);
  } catch {
    giveUp(`cannot install ${dest}`);
  }
  tmp = "";
  fs.rmSync(stamp, { force: true });
  say(`installed (${key})`);
}

main()
  .catch(() => {})
  .finally(() => process.exit(0));
