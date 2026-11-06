// Rogue Security — hand-off from the Gemini script bridge to the native bridge (rogue-hook).
// Node twin of scripts/shared/native-bridge.sh; read that file for the contract.
//
//   nativeHandoff(EXT_ROOT, "gemini", ["gemini", EVENT], { settings, budgetMs, failOpen });
//
// The plugin pins one rogue-hook version in <root>/rogue-hook.json. When that version is installed
// under ~/.rogue/bin/rogue-hook/<version>/, the binary does the caller's whole job: it reads this
// process's stdin, and its stdout, stderr and exit code are relayed byte for byte. When it is not,
// native-bridge-install.mjs is started detached to download it, and the caller carries on.
//
// No pin, managed hooks, a relative plugin root, a kill switch or a binary (or its directory) that
// another user could replace all mean: stay on the script. The last never starts the installer.
//   ROGUE_NATIVE_BRIDGE=0         every family stays on its script bridge
//   ROGUE_NATIVE_BRIDGE_GEMINI=0  Gemini does
//   ROGUE_NATIVE_BRIDGE_DIR       install root instead of ~/.rogue/bin/rogue-hook

import fs from "node:fs";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { HOME, IS_WIN, isProtected } from "./shared.mjs";

export function pinnedVersion(root) {
  try {
    const pin = fs.readFileSync(path.join(root, "rogue-hook.json"), "utf8");
    return pin.match(/^\s*"version"\s*:\s*"([0-9][0-9A-Za-z.-]*)"/m)?.[1] || "";
  } catch {
    return "";
  }
}

export function nativeDir(settings = {}) {
  return (
    settings.ROGUE_NATIVE_BRIDGE_DIR ||
    process.env.ROGUE_NATIVE_BRIDGE_DIR ||
    path.join(HOME, ".rogue", "bin", "rogue-hook")
  );
}

export const EXE = IS_WIN ? "rogue-hook.exe" : "rogue-hook";

function runnable(file) {
  try {
    if (!fs.statSync(file).isFile()) return false;
    if (!IS_WIN) fs.accessSync(file, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

// The binary gets the payload and the API key: it runs only if no other user can replace it.
function protectedBinary(file) {
  try {
    return isProtected(fs.statSync(file)) && isProtected(fs.statSync(path.dirname(file)));
  } catch {
    return false;
  }
}

// Writes all of `buf` to a file descriptor, waiting out a full non-blocking pipe.
function writeAll(fd, buf) {
  let off = 0;
  while (off < buf.length) {
    try {
      off += fs.writeSync(fd, buf, off);
    } catch (e) {
      if (e.code !== "EAGAIN") return;
    }
  }
}

// Returns only when the script bridge should keep the job; otherwise exits with the binary's answer.
// `settings` is the merged env (process env plus the env file in use), so the kill switches work from
// an env file. `budgetMs` sits below the agent's hook timeout: a stuck binary is killed and the
// caller's `failOpen` answer is written instead.
export function nativeHandoff(root, family, args, { settings = {}, budgetMs = 18000, failOpen = "{}" } = {}) {
  const setting = (k) => settings[k] ?? process.env[k] ?? "";
  if (process.env.ROGUE_HOOK_SOURCE === "managed") return;
  if (setting("ROGUE_NATIVE_BRIDGE") === "0") return;
  if (setting(`ROGUE_NATIVE_BRIDGE_${family.toUpperCase()}`) === "0") return;
  // A relative root resolves against the agent's working directory - a repository could plant its
  // own pin and binary there.
  if (!root || !path.isAbsolute(root)) return;
  const version = pinnedVersion(root);
  if (!version) return;
  const bin = path.join(nativeDir(settings), version, EXE);

  if (!runnable(bin)) {
    const installer = path.join(root, "scripts", "native-bridge-install.mjs");
    if (fs.existsSync(installer)) {
      try {
        spawn(process.execPath, [installer, root], {
          detached: true,
          stdio: "ignore",
          windowsHide: true,
        }).unref();
      } catch {
        /* the next event tries again */
      }
    }
    return;
  }
  if (!protectedBinary(bin)) return;

  // stdin is inherited, so the binary reads the agent's payload bytes untouched. The answer is
  // captured rather than inherited so a killed binary can be replaced by the fail-open answer.
  const r = spawnSync(bin, args, {
    env: { ...process.env, ROGUE_PLUGIN_ROOT: root },
    stdio: ["inherit", "pipe", "pipe"],
    timeout: budgetMs,
    killSignal: "SIGKILL",
    maxBuffer: 64 * 1024 * 1024,
    windowsHide: true,
  });
  // Never ran (vanished or not executable since the check): the script keeps the job.
  if (r.error && !r.pid) return;
  if (r.error || r.status === null) {
    writeAll(1, Buffer.from(failOpen));
    process.exit(0);
  }
  writeAll(1, r.stdout);
  writeAll(2, r.stderr);
  process.exit(r.status);
}
