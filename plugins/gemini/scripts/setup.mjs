#!/usr/bin/env node
// Rogue Security — credential storage helper (Gemini CLI).
//
// Called by the /setup command. Writes the shared ~/.rogue-env (mode 600) —
// the SAME file the Claude/Codex/Cursor plugins read — so credentials are
// shared across every Rogue coding-agent integration on this machine.
//
// Usage: node setup.mjs <api-key> <email> <name>
//
// Hooks read the first of these that holds ROGUE_API_KEY, alone: /etc/rogue/env
// (C:\ProgramData\rogue\env on Windows) → <ext>/env → ~/.rogue-env (written here).

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const [apiKey, actorEmail = "", actorName = ""] = process.argv.slice(2);
if (!apiKey) {
  process.stderr.write("Usage: setup.mjs <api-key> <email> <name>\n");
  process.exit(1);
}

const HOME = os.homedir() || process.env.HOME || process.env.USERPROFILE || ".";
const ENV_FILE = path.join(HOME, ".rogue-env");

const q = (s) => `'${String(s).replace(/'/g, "'\\''")}'`;

const MANAGED = {
  ROGUE_API_KEY: apiKey,
  ROGUE_ACTOR_EMAIL: actorEmail,
  ROGUE_ACTOR_NAME: actorName,
};

for (const [key, value] of Object.entries(MANAGED)) {
  if (/[\r\n]/.test(String(value))) {
    process.stderr.write(
      `Refusing to write ${ENV_FILE}: the value for ${key} contains a line break\n`,
    );
    process.exit(1);
  }
}

const HEADER = [
  "# Managed by the Rogue plugins. Read by hook subprocesses at runtime.",
  "# Delete this file to revoke credentials.",
];
const OWNED = new RegExp(`^\\s*(?:export\\s+)?(?:${Object.keys(MANAGED).join("|")})\\s*=`);
const OWN_HEADER = /^\s*# (Managed by the [Rr]ogue|Delete this file to revoke credentials)/;

let preserved = [];
try {
  preserved = fs
    .readFileSync(ENV_FILE, "utf8")
    .split(/\r?\n/)
    .filter((line, index, all) => !(index === all.length - 1 && line === ""))
    .filter((line) => !OWNED.test(line) && !OWN_HEADER.test(line));
} catch (err) {
  if (err.code !== "ENOENT") {
    process.stderr.write(`Could not read ${ENV_FILE}: ${err.message}\n`);
    process.exit(1);
  }
}

const contents =
  [...HEADER, ...Object.entries(MANAGED).map(([k, v]) => `export ${k}=${q(v)}`), ...preserved]
    .join("\n") + "\n";

const TMP = `${ENV_FILE}.rogue-tmp.${process.pid}`;
try {
  fs.writeFileSync(TMP, contents, { mode: 0o600 });
  try {
    fs.chmodSync(TMP, 0o600);
  } catch {}
  fs.renameSync(TMP, ENV_FILE);
} catch (err) {
  try {
    fs.unlinkSync(TMP);
  } catch {}
  process.stderr.write(`Could not write ${ENV_FILE}: ${err.message}\n`);
  process.exit(1);
}

process.stdout.write("OK\n");
process.stdout.write(`ENV_FILE=${ENV_FILE}\n`);
