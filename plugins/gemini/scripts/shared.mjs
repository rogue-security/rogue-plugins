// Rogue Security — Gemini CLI shared helpers.
//
// Common cross-platform paths and credential plumbing shared by hook.mjs and
// heartbeat.mjs. This module lives alongside them in <ext>/scripts/, so its
// import.meta.url resolves SCRIPT_DIR / EXT_ROOT to exactly the locations the
// callers expect. Node built-ins only; ESM (.mjs) throughout — imported with an
// explicit "./shared.mjs" specifier (static ESM-to-ESM import, stable on every
// Node the Gemini CLI supports, i.e. Node 20+).

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

// shared.mjs sits in <ext>/scripts/ — the same directory as hook.mjs and
// heartbeat.mjs — so these constants match the callers' original values.
export const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
export const EXT_ROOT = path.dirname(SCRIPT_DIR);
export const HOME =
  os.homedir() || process.env.HOME || process.env.USERPROFILE || ".";
export const IS_WIN = process.platform === "win32";

// ── Shell-quoted value decode (round-trips the `export KEY=value` form the other
// plugins write with printf %q / single-quoting). ────────────────────────────
export function shellUnquote(raw) {
  const v = raw.trim();
  if (v.length >= 2 && v[0] === "'" && v[v.length - 1] === "'") {
    // POSIX single-quote: '...' with '\'' representing a literal quote.
    return v.slice(1, -1).replace(/'\\''/g, "'");
  }
  if (v.length >= 2 && v[0] === '"' && v[v.length - 1] === '"') {
    return v.slice(1, -1).replace(/\\(["\\$`])/g, "$1");
  }
  return v;
}

// ── Credential resolution ────────────────────────────────────────────────────
// Same env-file rule as the other monorepo plugins: the first file holding
// ROGUE_API_KEY is used alone, and its values override the process env:
//   /etc/rogue/env (machine, MDM) → <ext>/env (bundled) → ~/.rogue-env (per-user)
export function loadEnvFiles() {
  const merged = {};
  for (const k of Object.keys(process.env)) {
    if (k.startsWith("ROGUE_") && process.env[k]) merged[k] = process.env[k];
  }
  const files = [
    IS_WIN ? "C:\\ProgramData\\rogue\\env" : "/etc/rogue/env",
    path.join(EXT_ROOT, "env"),
    path.join(HOME, ".rogue-env"),
  ];
  for (const f of files) {
    let text;
    try {
      text = fs.readFileSync(f, "utf8");
    } catch {
      continue;
    }
    const vals = {};
    for (const line of text.split(/\r?\n/)) {
      const m = line.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
      if (m) vals[m[1]] = shellUnquote(m[2]);
    }
    if (!vals.ROGUE_API_KEY) continue;
    Object.assign(merged, vals);
    break;
  }
  return merged;
}

/**
 * This install's fleet identity: { host, version, agent }.
 *
 * heartbeat.mjs sends these in its /hooks/status body; hook.mjs sends the same
 * three as x-rogue-host / x-rogue-version / x-rogue-agent on EVERY event, which
 * is what keeps the roster row fresh between session starts (the only time the
 * heartbeat fires). Resolved in ONE place because the backend keys the row on
 * host + actor + family + agent: any disagreement between the two senders is a
 * duplicate row for one install.
 *
 * `agent` is the surface and also the PLUGIN_REPOS key the backend resolves the
 * latest version from, so it stays "gemini_cli".
 */
// Gemini ships one surface, so this is a constant rather than a detection - but it
// is still declared in exactly one place, because it has three consumers: hook.mjs
// stamps it as each log line's `surface=` token and sends it as x-rogue-agent (via
// installId below), and heartbeat.mjs sends it as the roster's `agent`. A log line
// and the roster row for one install naming different surfaces is worse than a line
// naming none, and that is what a second literal would eventually produce.
export const SURFACE = "gemini_cli";

export function installId() {
  // `error` names whatever could not be resolved, or is null when all of it was.
  // Returned rather than logged: this helper is shared with heartbeat.mjs, which
  // is detached with its output discarded, so only hook.mjs has somewhere to put
  // it. Nothing here fails the hook — a degraded value still identifies the
  // install well enough to keep the roster fresh.
  const manifestPath = path.join(EXT_ROOT, "gemini-extension.json");
  let version = "unknown";
  let error = null;
  try {
    const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
    if (typeof manifest.version === "string") {
      version = manifest.version;
    } else {
      // Manifest is there but carries no version: schema drift, not a bad install.
      error = `version-missing:${manifestPath}`;
    }
  } catch (cause) {
    error = `manifest-unreadable:${manifestPath} (${cause.code ?? cause.message})`;
  }

  let host = "unknown";
  try {
    host = os.hostname() || "unknown";
  } catch {
    /* falls through to the error below */
  }
  if (host === "unknown") {
    error = error ? `host-unresolved,${error}` : "host-unresolved";
  }

  return { host, version, agent: SURFACE, error };
}

export function gitConfig(key) {
  try {
    return execFileSync("git", ["config", "--global", key], {
      timeout: 2000,
      stdio: ["ignore", "pipe", "ignore"],
    })
      .toString()
      .trim();
  } catch {
    return "";
  }
}
