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

// The MDM-managed machine file, named once so setup.mjs and the readers cannot
// disagree about which path is policy.
export const MACHINE_ENV_FILE = IS_WIN ? "C:\\ProgramData\\rogue\\env" : "/etc/rogue/env";

// ── Credential resolution ────────────────────────────────────────────────────
// Only root or the current user may supply configuration, and nobody else may
// write it; the machine file must be root's (env-file.sh's rule). Windows has no
// POSIX owner or mode, so the machine file is skipped there: the ACL check the
// PowerShell readers make has no Node equivalent.
export function isTrustedEnvFile(file) {
  let st;
  try {
    st = fs.statSync(file);
  } catch {
    return false;
  }
  if (!st.isFile()) return false;
  const system = file === "/etc/rogue/env" || file === "C:\\ProgramData\\rogue\\env";
  if (IS_WIN) return !system;
  if (st.uid !== 0 && (system || st.uid !== process.getuid())) return false;
  return (st.mode & 0o022) === 0;
}

// A candidate file "holds a key" when ROGUE_API_KEY is assigned a non-empty value.
export function envFileHasKey(file) {
  try {
    return /^[ \t]*(?:export[ \t]+)?ROGUE_API_KEY=["']?[^"'\s]/m.test(
      fs.readFileSync(file, "utf8"),
    );
  } catch {
    return false;
  }
}

// Same env-file rule as the other monorepo plugins: the first trusted file holding
// ROGUE_API_KEY is used alone, and its values override the process env:
//   /etc/rogue/env (machine, MDM) → <ext>/env (bundled) → ~/.rogue-env (per-user)
export function loadEnvFiles() {
  const merged = {};
  for (const k of Object.keys(process.env)) {
    if (k.startsWith("ROGUE_") && process.env[k]) merged[k] = process.env[k];
  }
  const files = [
    MACHINE_ENV_FILE,
    path.join(EXT_ROOT, "env"),
    path.join(HOME, ".rogue-env"),
  ];
  for (const f of files) {
    if (!isTrustedEnvFile(f)) continue;
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
    if (!String(vals.ROGUE_API_KEY || "").trim()) continue;
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

// ── Git identity from the config FILES ─────────────────────────────────────
// The git binary is never run: on a Mac without the Command Line Tools `git` is a
// stub that opens the installer dialog. Same rule as scripts/shared/git-identity.sh
// and .ps1: $XDG_CONFIG_HOME/git/config, then ~/.gitconfig, a later value
// overriding an earlier one as git does, each file followed by its [include] path
// entries (one level; includeIf is not evaluated).
// git syntax: a backslash escapes the next character, quotes toggle a region in
// which # and ; are literal, and a comment ends the value outside one.
function gitConfigValue(raw) {
  const s = raw.trim();
  let out = "";
  let quoted = false;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    // git decodes \n, \t and \b as control characters. A control character cannot
    // travel in an HTTP header value and would split git-identity.sh's two-line scan
    // output, so all three land as a space; every other escape is the literal
    // character, as git reads it.
    if (c === "\\" && i + 1 < s.length) {
      const e = s[++i];
      out += e === "n" || e === "t" || e === "b" ? " " : e;
    }
    else if (c === '"') quoted = !quoted;
    else if (!quoted && (c === "#" || c === ";")) break;
    else out += c;
  }
  return out.trim();
}

function readGitConfig(file, id, depth) {
  let text;
  try {
    text = fs.readFileSync(file, "utf8");
  } catch {
    return;
  }
  let section = "";
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line[0] === "#" || line[0] === ";") continue;
    if (line[0] === "[") {
      section = line.slice(1).replace(/[\]\s"].*$/, "").toLowerCase();
      continue;
    }
    const eq = line.indexOf("=");
    if (eq < 1) continue;
    const key = line.slice(0, eq).trim().toLowerCase();
    const val = gitConfigValue(line.slice(eq + 1));
    if (section === "include" && key === "path" && depth === 0) {
      const inc = val.startsWith("~/")
        ? path.join(HOME, val.slice(2))
        : path.resolve(path.dirname(file), val);
      readGitConfig(inc, id, 1);
    } else if (section === "user" && val) {
      if (key === "email") id.email = val;
      else if (key === "name") id.name = val;
    }
  }
}

export function gitIdentity() {
  const id = { email: "", name: "" };
  const xdg = process.env.XDG_CONFIG_HOME || path.join(HOME, ".config");
  for (const f of [path.join(xdg, "git", "config"), path.join(HOME, ".gitconfig")]) {
    readGitConfig(f, id, 0);
  }
  return id;
}

// Actor cascade, one implementation for hook.mjs and heartbeat.mjs so the event
// row and the roster row can never carry different identities:
//   env file → git config files → <login>@<hostname> / <login>.
export function resolveActor(env) {
  // Trimmed before the presence test: a whitespace-only ROGUE_ACTOR_* must fall
  // through to the git/login cascade rather than ship as blank, and the stored value
  // has to match what the shippers (which trim) send for the same install.
  let email = (env.ROGUE_ACTOR_EMAIL || "").trim();
  let name = (env.ROGUE_ACTOR_NAME || "").trim();
  if (!email || !name) {
    const git = gitIdentity();
    email = email || git.email;
    name = name || git.name;
  }
  let login = "";
  try {
    login = os.userInfo().username || "";
  } catch {
    /* no passwd entry for this uid */
  }
  const host = os.hostname() || "";
  if (!email) email = login && host ? `${login}@${host}` : login || host;
  return { email: email || "unknown", name: name || login || "unknown" };
}

// The actor as a request-header value. fetch() rejects any code unit above 0xFF
// (a Hebrew or CJK git user.name failed the hook open), so the UTF-8 bytes are
// spelled as one char each: the same bytes curl puts on the wire for the sh bridges.
export function headerBytes(value) {
  return Buffer.from(String(value), "utf8").toString("latin1");
}
