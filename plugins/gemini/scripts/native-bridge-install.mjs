#!/usr/bin/env node
// Rogue Security — installs the native bridge for the first time. Started detached by
// native-bridge.mjs whenever ~/.rogue/bin/rogue-hook[.exe] is missing and the plugin ships
// rogue-hook.json. Node twin of scripts/shared/native-bridge-install.sh; read that file for the
// contract.
//
//   node native-bridge-install.mjs <plugin-root>
//
// Downloads through GET /api/v1/hooks/download with the API key, then installs only a file whose
// sha256 matches the pin and whose --version reports the pinned version, by an atomic rename onto
// ~/.rogue/bin/rogue-hook[.exe], with the route's signature staged beside it for the macOS
// endpoint, under the binary's own update lock and only while that path is still empty. Any
// failure leaves nothing at that path, so the script bridge keeps handling events.
// A failed attempt is retried after ROGUE_NATIVE_BRIDGE_RETRY seconds (default 900, numeric zero =
// every time), never per event. Every attempt's outcome is appended to ~/.rogue/hook-binary.log.

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { HOME, IS_WIN, loadEnvFiles, nativePathIsProtected } from "./shared.mjs";
import { EXE, nativeDir, pinnedVersion } from "./native-bridge.mjs";

const ROOT = process.argv[2] || "";
const now = () => Math.floor(Date.now() / 1000);

let version = "";
let tmp = "";
process.on("exit", () => {
  if (tmp) for (const f of [tmp, `${tmp}.sig`]) fs.rmSync(f, { force: true });
});

// The lock is taken without waiting and released by the OS when its holder dies; the installer runs
// again under it with ROGUE_NATIVE_BRIDGE_LOCKED=1.
const PERL_LOCK =
  '$^F = 255; open(my $l, ">>", shift) or exit 0; flock($l, LOCK_EX | LOCK_NB) or exit 0; exec @ARGV or exit 0';
// std's LockFileEx in the binary covers the whole file, so this byte-range lock conflicts with it.
const PS_LOCK =
  "$f = [IO.File]::Open($env:ROGUE_NATIVE_BRIDGE_LOCK, 'OpenOrCreate', 'ReadWrite', 'ReadWrite'); " +
  "try { $f.Lock(0, 1) } catch { exit 0 }; & $env:ROGUE_NATIVE_BRIDGE_NODE $env:ROGUE_NATIVE_BRIDGE_SELF $env:ROGUE_NATIVE_BRIDGE_ROOT; exit 0";

// Node has no file-lock API: flock(1) or perl takes the binary's own update lock on macOS and
// Linux, PowerShell on Windows. Returns whether a locked run happened.
function runLocked(lockFile) {
  const self = [process.execPath, process.argv[1], ROOT];
  const env = { ...process.env, ROGUE_NATIVE_BRIDGE_LOCKED: "1" };
  const opts = { env, stdio: "ignore", windowsHide: true };
  if (IS_WIN) {
    Object.assign(env, {
      ROGUE_NATIVE_BRIDGE_LOCK: lockFile,
      ROGUE_NATIVE_BRIDGE_NODE: self[0],
      ROGUE_NATIVE_BRIDGE_SELF: self[1],
      ROGUE_NATIVE_BRIDGE_ROOT: self[2],
    });
    return !spawnSync("powershell", ["-NoProfile", "-NonInteractive", "-Command", PS_LOCK], opts).error;
  }
  const flock = spawnSync("flock", ["-n", lockFile, ...self], opts);
  if (flock.error?.code !== "ENOENT") return true;
  return !spawnSync("perl", ["-MFcntl=:flock", "-e", PERL_LOCK, lockFile, ...self], opts).error;
}

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

// Under x64 emulation on ARM64 Windows (an x64 Git Bash starts the hooks), the process environment
// and process.arch both say x64; the registry keeps the machine's own arch.
function windowsArch() {
  const key = "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment";
  const r = spawnSync("reg", ["query", key, "/v", "PROCESSOR_ARCHITECTURE"], { encoding: "utf8", windowsHide: true });
  const native = /PROCESSOR_ARCHITECTURE\s+REG_SZ\s+(\S+)/.exec(r.stdout || "")?.[1];
  return native || process.env.PROCESSOR_ARCHITEW6432 || process.env.PROCESSOR_ARCHITECTURE || "";
}

// macOS ships one universal binary, so its arch is only a label for the route.
function platform() {
  if (process.platform === "darwin") return { os: "darwin", arch: "arm64", key: "darwin-universal" };
  const cpu = IS_WIN ? windowsArch() : process.arch;
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
  const dest = path.join(dir, EXE);
  if (fs.existsSync(dest)) return;
  try {
    makeDir(path.join(HOME, ".rogue"));
  } catch {
    return;
  }
  // One install or update at a time: the binary's own lock, so this never races a self-update.
  if (process.env.ROGUE_NATIVE_BRIDGE_LOCKED !== "1") {
    if (!runLocked(path.join(HOME, ".rogue", ".self-update.lock"))) giveUp("no flock or perl to take the update lock");
    return;
  }
  // The holder before this one may have installed it.
  if (fs.existsSync(dest)) return;
  // Same rule as the hand-off, before and after creating the install directory: another user must
  // not be able to replace any directory above it.
  const unsafe = () => giveUp(`${dir} is not protected from other users`);
  if (!nativePathIsProtected(dest)) unsafe();

  const stamp = path.join(HOME, ".rogue", ".native-bridge-attempt");
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
  let signature = "";
  try {
    const resp = await fetch(
      `${base}/api/v1/hooks/download?version=${version}&os=${os}&arch=${arch}`,
      { headers: { "x-rogue-api-key": apiKey }, signal: AbortSignal.timeout(15000) },
    );
    if (resp.ok) ({ url = "", signature = "" } = (await resp.json()) || {});
  } catch {
    /* handled below */
  }
  if (typeof url !== "string" || !url) giveUp(`no download URL for ${key}`);

  // Staged beside the binary's own updates: on the same volume, so the rename is atomic.
  const stage = path.join(HOME, ".rogue", "updates");
  try {
    makeDir(stage);
    makeDir(dir);
  } catch {
    giveUp(`cannot create ${dir}`);
  }
  if (!nativePathIsProtected(dest)) unsafe();
  tmp = path.join(stage, `rogue-hook.first.${process.pid}${IS_WIN ? ".exe" : ""}`);
  let data;
  try {
    const resp = await fetch(url, { signal: AbortSignal.timeout(120000) });
    if (!resp.ok) throw new Error(`http ${resp.status}`);
    data = Buffer.from(await resp.arrayBuffer());
    fs.writeFileSync(tmp, data, { mode: 0o755 });
  } catch {
    giveUp("download failed");
  }
  // The macOS endpoint's extension denies every rename into ~/.rogue/bin. It installs the binary
  // itself when the release's signature lies beside the source as <source>.sig.
  if (typeof signature === "string" && signature) {
    try {
      fs.writeFileSync(`${tmp}.sig`, signature);
    } catch {
      giveUp("cannot stage the signature");
    }
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
    // After the extension installs the binary, the rename still fails with EPERM.
    let landed = "";
    try {
      landed = crypto.createHash("sha256").update(fs.readFileSync(dest)).digest("hex");
    } catch {
      /* handled below */
    }
    if (landed !== want) giveUp(`cannot install ${dest}`);
  }
  fs.rmSync(stamp, { force: true });
  say(`installed (${key})`);
}

main()
  .catch(() => {})
  .finally(() => process.exit(0));
