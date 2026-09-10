#!/usr/bin/env node
// Rogue Security - hook-log shipper (Gemini CLI). Siblings: scripts/shared/ship-logs.sh
// and scripts/shared/ship-logs.ps1, whose behaviour this mirrors exactly.
//
// Uploads the un-shipped tail of ~/.rogue/logs/gemini.log to /api/v1/hooks/logs, so
// a support engineer can read it WITHOUT an endpoint agent on the box. Design and
// rationale for every rule here: docs/plugin-log-shipper.md.
//
//   node ship-logs.mjs <plugin-root> <shipper-slug> <shipper-version> <agent-family>
//
// NO ARGUMENTS -> collect EVERY known agent's log (ROGUE_SHIP_ALL is implied: with no
// slug there is no "own log" to pick), reporting shipper "unknown".
//
// ONE implementation, not a pair, and NOT part of scripts/sync-shared-scripts.sh:
// Gemini CLI guarantees Node 20+ on PATH (every install method requires it; the
// Homebrew formula declares `node` a dependency), which is the same reason hook.mjs
// exists instead of a hook.sh/hook.ps1 pair. There is no sibling copy to keep in
// lockstep, so there is nothing to sync - but the STATE FORMAT is shared with the sh
// shipper and must stay byte-compatible: under ROGUE_SHIP_ALL, Gemini's shipper
// writes ~/.rogue/ship/claude.state that Claude's sh shipper reads next session.
// That is precisely why `head=` is base64 of a byte range rather than a checksum -
// base64 is identical across all three languages by construction, where a CRC would
// have to be reimplemented bit-for-bit in POSIX sh.
//
// Node built-ins only: global fetch, node:fs/os/path. No dependencies, no build step.
// Fail-open everywhere, always exit 0 - a broken shipper must be silence.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { shellUnquote, IS_WIN } from "./shared.mjs";

// ── constants ──────────────────────────────────────────────────────────────
const SHIP_ENDPOINT_PATH = "/api/v1/hooks/logs";
const KNOWN_LOG_SLUGS = ["claude", "codex", "cursor", "gemini", "copilot", "antigravity", "kiro"];
// Bytes scanned when fingerprinting a log's first line. NOT 200: a real log line is
// timestamp + provider + event + up to 400 chars of `raw=`, i.e. commonly 500-700
// bytes, so a 200-byte window would find no newline in a typical log's first line and
// the whole rotation check would silently never engage.
const HEAD_WINDOW_BYTES = 4096;
// Windows of maxLineBytes scanned when hunting the end of an over-long line: 256 MiB
// at the defaults. Past that the shipper stalls rather than advancing - see
// findLineEnd / sendOversizeLine.
const MAX_SCAN_WINDOWS = 64;
const LOCK_STALE_SECONDS = 600;
const MAX_CHUNKS_PER_DRAIN = 64;
const HTTP_TIMEOUT_MS = 15000;

const HOME = os.homedir() || process.env.HOME || process.env.USERPROFILE || ".";

// ── env files ──────────────────────────────────────────────────────────────
// Same platform-aware rule as every dispatcher: the first env file holding
// ROGUE_API_KEY is used alone, and its values override the process env. Takes the
// root as an argument rather than using shared.mjs's EXT_ROOT-bound loadEnvFiles(),
// so the documented four-argument contract is real on this implementation too and a
// support run can point at any install.
function loadEnv(pluginRoot) {
  const merged = {};
  for (const varName of Object.keys(process.env)) {
    if (varName.startsWith("ROGUE_") && process.env[varName]) merged[varName] = process.env[varName];
  }
  const envFiles = [
    IS_WIN ? "C:\\ProgramData\\rogue\\env" : "/etc/rogue/env",
    pluginRoot ? path.join(pluginRoot, "env") : null,
    path.join(HOME, ".rogue-env"),
  ];
  for (const envFile of envFiles) {
    if (!envFile) continue;
    let text;
    try {
      text = fs.readFileSync(envFile, "utf8");
    } catch {
      continue;
    }
    const vals = {};
    for (const line of text.split(/\r?\n/)) {
      const assignment = line.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
      if (assignment) vals[assignment[1]] = shellUnquote(assignment[2]);
    }
    if (!vals.ROGUE_API_KEY) continue;
    Object.assign(merged, vals);
    break;
  }
  return merged;
}

// A NON-NUMERIC value falls back to the default - a typo must never disable shipping
// or blow a size cap. ZERO differs per knob: there is no useful reading of "a
// zero-byte upload" (the offset would never advance and the file would never drain -
// a silent permanent stall), while a zero interval genuinely means "no throttle" and
// the documented support one-liner relies on it.
function numberOrDefault(value, fallback, allowZero) {
  if (typeof value !== "string" || !/^[0-9]+$/.test(value)) return fallback;
  // All digits is not the same as representable: Number() turns a value wider
  // than 2^53 into an imprecise float and a long enough one into Infinity,
  // which no byte count ever reaches. Fall back, matching the sh copy's
  // 18-digit clamp and the PowerShell copy's TryParse.
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed)) return fallback;
  if (!allowZero && parsed <= 0) return fallback;
  return parsed;
}

// SHIPPING IS UNCONDITIONAL. There is no ROGUE_SHIP_LOGS flag: a configured install
// uploads its hook log, and the only things that stop a given run are the ones that
// were always able to - no API key, no resolvable actor, the self-throttle, or simply
// no new bytes on disk. It was opt-in while /api/v1/hooks/logs was undeployed, since a
// default-on client would have POSTed into a permanent 404 and appended an
// `outcome=fail http=404` line to the very file it was draining. The route now exists
// (an empty body is answered 422 with a body-schema validation error, where a genuinely
// unknown hooks path is answered a bare 404), so the gate is gone rather than flipped.
//
// What the 2xx contract still requires of the server is unchanged and load-bearing:
// the offset advances only on 2xx and the client then forgets those bytes, so a 2xx
// sent before a durable write is a permanent, silent gap. See
// docs/log-shipping-backend.md.

// ── low-level file reads ───────────────────────────────────────────────────
function fileSize(filePath) {
  try {
    const stats = fs.statSync(filePath);
    return stats.isFile() ? stats.size : 0;
  } catch {
    return 0;
  }
}

// Read [offset, offset+count) as raw bytes, or null on any failure.
//
// No share-mode dance is needed here, unlike ship-logs.ps1: libuv opens files with
// FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE on Windows, so holding this
// handle cannot make the dispatcher's rotation rename fail. That failure mode is real
// and severe (phase 1 swallows a failed rotation, so the log would grow past its cap
// forever) - it just does not arise from Node.
function readRange(filePath, offset, count) {
  if (count <= 0) return Buffer.alloc(0);
  let fd = null;
  try {
    fd = fs.openSync(filePath, "r");
    const buffer = Buffer.alloc(count);
    let bytesRead = 0;
    while (bytesRead < count) {
      const justRead = fs.readSync(fd, buffer, bytesRead, count - bytesRead, offset + bytesRead);
      if (justRead <= 0) break;
      bytesRead += justRead;
    }
    return bytesRead === count ? buffer : buffer.subarray(0, bytesRead);
  } catch {
    return null;
  } finally {
    if (fd !== null) {
      try {
        fs.closeSync(fd);
      } catch {}
    }
  }
}

// Bytes AFTER the last 0x0A: 0 when the chunk already ends on a line boundary, the
// whole length when it holds no newline at all.
function trailingFragmentLength(buffer) {
  if (!buffer || buffer.length === 0) return 0;
  const lastNewline = buffer.lastIndexOf(10);
  if (lastNewline < 0) return buffer.length;
  return buffer.length - 1 - lastNewline;
}

// base64 of the file's FIRST LINE INCLUDING its newline, or "" when no newline exists
// within the first HEAD_WINDOW_BYTES bytes ("unknown" - the caller then falls back to
// `size < offset` alone).
//
// A LINE, not a fixed prefix: logs are append-only, so once a newline exists at byte
// k, bytes 0..k never change again. A fixed 200-byte window instead misfires on a
// young file - one short line hashes N bytes, and once more lines arrive the same
// window spans several, so the head "changes", the offset resets and the file is
// re-shipped every run.
function firstLineFingerprint(filePath) {
  const headWindow = readRange(filePath, 0, HEAD_WINDOW_BYTES + 1);
  if (!headWindow || headWindow.length === 0) return "";
  const newlineIndex = headWindow.indexOf(10);
  if (newlineIndex < 0) return "";
  return headWindow.subarray(0, newlineIndex + 1).toString("base64");
}

// Bytes from `offset` through the first newline at/after it.
// Returns { length, hitEof }: length 0 = not found.
//
// THE SEARCH SPANS WINDOWS, and that is load-bearing. An earlier version probed a
// single maxLineBytes window and, on a miss, advanced the offset by maxLineBytes and
// probed again - which lands the offset MID-LINE, so the next probe finds the newline
// a few bytes ahead and ships the TAIL of the over-long line as if it were a short
// line. Verified on the sh side: a 406-byte line against ROGUE_SHIP_MAX_LINE_BYTES=100
// shipped its last 6 bytes as a chunk. Any advance that does not land exactly after a
// newline makes every subsequent read a fragment, so the only safe skip target is the
// next newline. Windows overlap by a byte, so no newline falls between two of them.
function findLineEnd(filePath, offset, maxLineBytes) {
  let bytesScanned = 0;
  for (let window = 0; window < MAX_SCAN_WINDOWS; window++) {
    const probe = readRange(filePath, offset + bytesScanned, maxLineBytes + 1);
    if (!probe || probe.length === 0) return { length: 0, hitEof: true };
    const newlineIndex = probe.indexOf(10);
    if (newlineIndex >= 0) return { length: bytesScanned + newlineIndex + 1, hitEof: false };
    // Short read: the window hit EOF without a newline.
    if (probe.length <= maxLineBytes) return { length: 0, hitEof: true };
    bytesScanned += maxLineBytes;
  }
  return { length: 0, hitEof: false };
}

function epochSeconds() {
  return Math.floor(Date.now() / 1000);
}

// ── the shipper ────────────────────────────────────────────────────────────
class Shipper {
  constructor(argv) {
    this.pluginRoot = argv[0] || "";
    this.shipperSlug = (argv[1] || "").trim();
    this.shipperVersion = (argv[2] || "").trim() || "unknown";
    this.agentFamily = (argv[3] || "").trim();
    this.shipAllLogs = false;
    if (!this.pluginRoot) {
      // Self-locate so the BUNDLED env file is still read on a no-argument run.
      this.pluginRoot = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
    }
    if (!this.shipperSlug) {
      // No slug -> "ship my own log" is not a question this run can answer, so it
      // means "collect everything" (the support invocation). Defaulting the slug to
      // `unknown` instead would look for unknown.log and ship nothing at all.
      this.shipperSlug = "unknown";
      this.shipAllLogs = true;
    }
    this.heldLockDir = "";
    this.runBytesSent = 0;
  }

  // Our own diagnostics land in the SHIPPING plugin's log file, tagged
  // `event=ShipLogs`, and ONLY for notable outcomes (a failure or a skip) - never on
  // the happy path, because a line per run would mean every run has new bytes to
  // ship, destroying the "an idle machine makes no HTTP request at all" property that
  // makes the throttle cheap.
  //
  // The shipper NEVER rotates that file even if its own line pushes it over the cap:
  // renaming a log we may be part-way through reading is exactly the
  // rotation-under-us hazard firstLineFingerprint re-checks for. Rotation stays the
  // dispatcher's job.
  log(message) {
    // ALSO to stderr under ROGUE_DEBUG, and unconditionally - before the selfLogFile
    // gate below. The no-argument support invocation has no slug, so it has no log
    // file of its own to write to, and every failure reason (`http=<code>`,
    // `reason=no-actor`) used to vanish on exactly the run a support engineer is told
    // to make. The file is where the outcome is durable; stderr is where it is visible.
    this.debug(message);
    if (!this.selfLogFile) return;
    try {
      fs.mkdirSync(path.dirname(this.selfLogFile), { recursive: true });
      const timeStamp = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
      fs.appendFileSync(
        this.selfLogFile,
        `${timeStamp} provider=${this.shipperSlug} event=ShipLogs ${message}\n`,
      );
    } catch {}
  }

  debug(message) {
    if (process.env.ROGUE_DEBUG) process.stderr.write(`[rogue-ship] ${message}\n`);
  }

  resolveKnobs() {
    const env = this.env;
    this.minIntervalSeconds = numberOrDefault(env.ROGUE_SHIP_MIN_INTERVAL, 900, true);
    this.maxChunkBytes = numberOrDefault(env.ROGUE_SHIP_MAX_BYTES, 1048576, false);
    this.maxRunBytes = numberOrDefault(env.ROGUE_SHIP_MAX_RUN_BYTES, 10485760, false);
    this.maxLineBytes = numberOrDefault(env.ROGUE_SHIP_MAX_LINE_BYTES, 4194304, false);
    // Left as the constructor set it when unset or non-numeric, so a no-argument run
    // keeps its implied ship-everything.
    if (/^[0-9]+$/.test(env.ROGUE_SHIP_ALL || "") && Number(env.ROGUE_SHIP_ALL) !== 0) {
      this.shipAllLogs = true;
    }
    this.logDir = env.ROGUE_LOG_DIR || path.join(HOME, ".rogue", "logs");
    this.exactLogFile = env.ROGUE_LOG_FILE || "";
    this.selfLogFile =
      this.shipperSlug === "unknown"
        ? ""
        : this.exactLogFile || path.join(this.logDir, `${this.shipperSlug}.log`);
    this.apiKey = env.ROGUE_API_KEY || "";
    this.shipUrl =
      (env.ROGUE_BASE_URL || "https://api.rogue.security").replace(/\/+$/, "") + SHIP_ENDPOINT_PATH;
  }

  // The actor is INHERITED, never re-resolved. The shipper deliberately carries NO
  // cascade of its own: the six plugins' cascades are not the same (actor.sh falls
  // back to `hostname`, Cursor's hook.sh to "$USER@$(hostname)", and this plugin's
  // heartbeat.mjs to os.hostname()), so an independent re-resolve does not merely risk
  // drift - it produces it, and the heartbeat's roster row and this run's log_source
  // row then never meet. Nothing errors; the logs just attach to nothing.
  //
  // Gemini's heartbeat.mjs resolves the actor into MODULE LOCALS, never process.env,
  // which is why it must pass them explicitly in the child's env - see the caller.
  //
  // `anon` is the SAME canonical form the sh and PowerShell copies use, and the
  // divergence here was a real one: this returned false for an absent, empty or
  // whitespace-only email, so a Gemini install whose `git config user.email` is unset
  // shipped nothing while every other plugin on the same machine shipped under `anon`.
  // The value matters because it is the roster fingerprint's own fallback
  // (`actorEmail ?? "anon"`), so it joins to the row the heartbeat already created.
  //
  // The skip below now covers only the case it was written for: the env var was never
  // PASSED, i.e. the caller resolved no identity at all (`undefined`, not ""). An
  // empty string is a resolved-and-missing email, which `anon` names exactly.
  resolveActor() {
    if (this.env.ROGUE_ACTOR_EMAIL === undefined && this.env.ROGUE_ACTOR_NAME === undefined) {
      return false;
    }
    this.actorEmail = (this.env.ROGUE_ACTOR_EMAIL || "").trim() || "anon";
    this.actorName = (this.env.ROGUE_ACTOR_NAME || "").trim();
    this.hostName = os.hostname() || "unknown";
    return true;
  }

  // Each plugin's shipper uploads only ITS OWN agent's log; ROGUE_SHIP_ALL=1 restores
  // the collect-everything behaviour for support.
  targetLogFiles() {
    // ROGUE_LOG_FILE mode: ALL agents write to this one path, so it is the only file
    // regardless of ROGUE_SHIP_ALL.
    if (this.exactLogFile) return [this.exactLogFile];
    if (this.shipAllLogs) {
      return KNOWN_LOG_SLUGS.map((slug) => path.join(this.logDir, `${slug}.log`)).filter(
        (candidate) => fs.existsSync(candidate),
      );
    }
    return [path.join(this.logDir, `${this.shipperSlug}.log`)];
  }

  // `agent_family` is a FALLBACK HINT, not the key: the server attributes each line
  // off its own `provider=` token. Sent only for the caller's own log, and omitted for
  // a foreign log under ROGUE_SHIP_ALL and for a custom ROGUE_LOG_FILE - in both of
  // those the file's lines are mixed-provider, so the shipping plugin's family would
  // MISLABEL them (a claude line filed under `gemini`).
  familyForFile(baseName) {
    if (this.exactLogFile) return "";
    if (baseName !== `${this.shipperSlug}.log`) return "";
    return this.agentFamily;
  }

  stateKeyForPath(filePath) {
    const baseName = path.basename(filePath);
    return baseName.endsWith(".log") ? baseName.slice(0, -4) : baseName;
  }

  // The throttle is NOT a bandwidth measure - a run with nothing new makes no HTTP
  // request at all. It is a crash-loop guard: the stamp is written the instant the lock
  // is taken, BEFORE any upload, so a shipper that dies before persisting its offset
  // re-runs at most once per interval instead of on every session start.
  isWithinThrottleWindow(stateKey) {
    const stampFile = path.join(this.stateDir, `.last-${stateKey}`);
    let rawStamp;
    try {
      rawStamp = fs.readFileSync(stampFile, "utf8").split("\n")[0].trim();
    } catch {
      return false;
    }
    if (!/^[0-9]+$/.test(rawStamp)) return false;
    const lastRun = Number(rawStamp);
    const now = epochSeconds();
    // A stamp in the FUTURE (clock stepped back, a bad write) is stale, not a reason
    // to stop shipping until the clock catches up.
    if (lastRun > now) return false;
    return now - lastRun < this.minIntervalSeconds;
  }

  stampRunTime(stateKey) {
    try {
      fs.writeFileSync(path.join(this.stateDir, `.last-${stateKey}`), `${epochSeconds()}\n`);
    } catch {}
  }

  // mkdir is a single atomic filesystem operation - succeed, or fail because it
  // exists, with no gap. The age marker is a file INSIDE the lock rather than the
  // directory's own mtime, so all three implementations agree without needing `stat`.
  acquireLock(stateKey) {
    const lockDir = path.join(this.stateDir, `.lock-${stateKey}`);
    const take = () => {
      try {
        fs.mkdirSync(lockDir);
      } catch {
        return false;
      }
      this.heldLockDir = lockDir;
      try {
        fs.writeFileSync(path.join(lockDir, "ts"), `${epochSeconds()}\n`);
      } catch {}
      return true;
    };
    if (take()) return true;
    if (!fs.existsSync(lockDir)) return false;
    // A killed shipper must not wedge the feature permanently. An unreadable or
    // unparseable marker counts as stale: a lock we cannot age out is worse than one
    // reclaimed slightly early.
    let isStale = true;
    let sawMarker = false;
    try {
      const rawStamp = fs.readFileSync(path.join(lockDir, "ts"), "utf8").split("\n")[0].trim();
      if (/^[0-9]+$/.test(rawStamp)) {
        sawMarker = true;
        const lockStamp = Number(rawStamp);
        const now = epochSeconds();
        if (lockStamp <= now && now - lockStamp <= LOCK_STALE_SECONDS) isStale = false;
      }
    } catch {}
    if (!sawMarker) {
      // NO READABLE MARKER IS NOT PROOF OF A DEAD HOLDER. mkdirSync and the `ts` write
      // are two operations, so a lock taken milliseconds ago legitimately has no marker
      // yet - and treating that as stale let a second run delete a live lock, take it,
      // and upload the same byte range twice. Age the DIRECTORY instead; its own mtime
      // is free here, unlike the sh copy, which shells out to `find` because `stat`'s
      // flags differ between BSD and GNU. An unreadable timestamp reads as "not old
      // enough": one skipped cycle rather than a duplicate upload.
      isStale = false;
      try {
        if (epochSeconds() - Math.floor(fs.statSync(lockDir).mtimeMs / 1000) > LOCK_STALE_SECONDS) {
          isStale = true;
        }
      } catch {}
    }
    if (!isStale) return false;
    try {
      fs.rmSync(lockDir, { recursive: true, force: true });
    } catch {}
    return take();
  }

  releaseLock() {
    if (!this.heldLockDir) return;
    try {
      fs.rmSync(this.heldLockDir, { recursive: true, force: true });
    } catch {}
    this.heldLockDir = "";
  }

  readState(stateKey, normalizedPath) {
    const state = { offset: 0, head: "", size: 0, path: "" };
    let text;
    try {
      text = fs.readFileSync(path.join(this.stateDir, `${stateKey}.state`), "utf8");
    } catch {
      return state;
    }
    for (const line of text.split(/\r?\n/)) {
      const field = line.match(/^([a-z]+)=(.*)$/);
      if (!field) continue;
      if (field[1] === "offset") state.offset = /^[0-9]+$/.test(field[2]) ? Number(field[2]) : 0;
      else if (field[1] === "head") state.head = field[2];
      else if (field[1] === "size") state.size = /^[0-9]+$/.test(field[2]) ? Number(field[2]) : 0;
      else if (field[1] === "path") state.path = field[2];
    }
    // The key is a BASENAME, so /a/claude.log and /b/claude.log key alike: changing
    // ROGUE_LOG_DIR (an MDM edit, a relocated home) would otherwise point the shipper
    // at a different file holding the previous file's offset.
    if (state.path && state.path !== normalizedPath) {
      this.debug(
        `state path mismatch (${state.path} != ${normalizedPath}) -> treating state as absent`,
      );
      state.offset = 0;
      state.head = "";
      state.size = 0;
    }
    return state;
  }

  // Write-to-temp-then-rename, so a crash mid-write cannot leave a half-written
  // offset. The temp sits in the SAME directory as the destination, or the rename is
  // not atomic.
  writeState(stateKey, offset, head, size, normalizedPath) {
    try {
      const destination = path.join(this.stateDir, `${stateKey}.state`);
      const tempFile = path.join(this.stateDir, `.state-tmp-${process.pid}`);
      fs.writeFileSync(
        tempFile,
        `offset=${offset}\nhead=${head}\nsize=${size}\npath=${normalizedPath}\n`,
      );
      fs.renameSync(tempFile, destination);
    } catch {}
  }

  async sendChunkRequest(bytes, offset, count, rotated) {
    const body = {
      host: this.hostName,
      actor_email: this.actorEmail,
      actor_name: this.actorName,
      shipper: this.shipperSlug,
      shipper_version: this.shipperVersion,
      log_file: this.targetBaseName,
      offset,
      bytes: count,
      rotated,
      content_b64: bytes.toString("base64"),
    };
    if (this.targetFamily) body.agent_family = this.targetFamily;
    this.debug(
      `POST ${this.shipUrl} file=${this.targetBaseName} offset=${offset} bytes=${count} rotated=${rotated}`,
    );
    let accepted = false;
    let httpCode = 0;
    try {
      const response = await fetch(this.shipUrl, {
        method: "POST",
        headers: { "Content-Type": "application/json", "x-rogue-api-key": this.apiKey },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(HTTP_TIMEOUT_MS),
      });
      httpCode = response.status;
      accepted = response.ok;
    } catch {
      accepted = false;
    }
    // The offset advances ONLY on 2xx. A non-2xx, a transport failure or a timeout
    // leaves the state untouched, so the same range is re-sent next run: nothing is
    // ever marked exported on unconfirmed data. This makes 2xx load-bearing - it must
    // mean DURABLY ACCEPTED on the server, not merely received.
    if (!accepted) {
      this.log(
        `outcome=fail file=${this.targetBaseName} offset=${offset} bytes=${count} http=${httpCode}`,
      );
    }
    return accepted;
  }

  // Returns the bytes the offset should advance by (NOT always the bytes sent - an
  // over-long line is skipped forward), or 0 when nothing shipped and the offset must
  // not move.
  async sendNextChunk(filePath, offset, rotated, expectedHead) {
    const fileBytes = fileSize(filePath);
    let wantBytes = fileBytes - offset;
    if (wantBytes <= 0) return 0;
    if (wantBytes > this.maxChunkBytes) wantBytes = this.maxChunkBytes;
    let chunk = readRange(filePath, offset, wantBytes);
    if (!chunk || chunk.length === 0) return 0;

    // Chunks end on line boundaries. Hitting the cap mid-line would put a line's first
    // half in chunk N and its second in chunk N+1 - two stored events, two corrupt
    // lines instead of one good one - and the same hazard exists at the tail from a
    // torn concurrent append.
    const fragmentBytes = trailingFragmentLength(chunk);
    const keepBytes = chunk.length - fragmentBytes;
    if (keepBytes <= 0) {
      return await this.sendOversizeLine(filePath, offset, rotated, expectedHead, fileBytes);
    }
    if (fragmentBytes > 0) chunk = chunk.subarray(0, keepBytes);

    // Rotation DURING the read (the TOCTOU). The dispatcher can rename the file
    // between our size read and this one, in which case the bytes above came from the
    // NEW file: shipping them labelled offset=<old> loses the old file's real tail and
    // then persists an offset over the top of it. The window is milliseconds and
    // rotation is once per generation, but the corruption is silent and permanent.
    if (firstLineFingerprint(filePath) !== expectedHead) {
      this.debug(`head changed under us -> discarding chunk at ${offset}`);
      return 0;
    }
    if (!(await this.sendChunkRequest(chunk, offset, chunk.length, rotated))) return 0;
    return chunk.length;
  }

  // A single line longer than one request. "If the chunk has no newline, ship it
  // whole" was incoherent: the chunk was ALREADY truncated to the cap, so "whole"
  // shipped a PARTIAL line, contradicting the invariant the server parser depends on.
  // Both branches here are unreachable in a healthy install (`raw=` is capped at 400
  // chars), so a multi-megabyte line means something already went wrong.
  async sendOversizeLine(filePath, offset, rotated, expectedHead, fileBytes) {
    const { length: lineLength, hitEof } = findLineEnd(filePath, offset, this.maxLineBytes);
    if (lineLength > 0) {
      if (lineLength <= this.maxLineBytes) {
        const line = readRange(filePath, offset, lineLength);
        if (!line || line.length === 0) return 0;
        if (firstLineFingerprint(filePath) !== expectedHead) return 0;
        if (!(await this.sendChunkRequest(line, offset, line.length, rotated))) return 0;
        return line.length;
      }
      // Over the ceiling: skip PAST ITS NEWLINE, never by a fixed amount, so the new
      // offset lands exactly on the start of the next line.
      this.log(
        `outcome=skip reason=oversize-line file=${this.targetBaseName} offset=${offset} bytes=${lineLength}`,
      );
      return lineLength;
    }
    if (hitEof) {
      const remainingBytes = fileBytes - offset;
      if (remainingBytes <= 0) return 0;
      // A ROTATED generation is frozen, so its unterminated final line is complete and
      // will never grow: send it rather than stalling on .1 forever, which would also
      // stop the live log from ever resetting.
      if (rotated) {
        // The ceiling applies to this tail too. It is a line like any other, and the
        // newline search that produced it may have spanned every scan window - up to
        // MAX_SCAN_WINDOWS * maxLineBytes, 256 MiB at the defaults - so without this
        // the branch can post a single body far past the ~1 MiB (4 MiB for one
        // oversized line) the receiver is promised, after allocating it.
        if (remainingBytes > this.maxLineBytes) {
          this.log(
            `outcome=skip reason=oversize-line file=${this.targetBaseName} offset=${offset} bytes=${remainingBytes}`,
          );
          return remainingBytes;
        }
        const tail = readRange(filePath, offset, remainingBytes);
        if (!tail || tail.length === 0) return 0;
        if (!(await this.sendChunkRequest(tail, offset, tail.length, rotated))) return 0;
        return tail.length;
      }
      // A LIVE file's unterminated tail is a line still being written. Wait for its
      // newline instead of shipping half of it.
      return 0;
    }
    // The scan bound was exhausted without finding a newline. DO NOT ADVANCE: landing
    // the offset anywhere other than just after a newline turns every later read into
    // a fragment, so this file stalls until someone looks at it - a diagnostics-loss
    // bug, where advancing would be a corrupt-the-dataset bug. Logged every run
    // precisely so a stalled file is visible instead of silent.
    this.log(
      `outcome=stall reason=unbounded-line file=${this.targetBaseName} offset=${offset} scanned=${this.maxLineBytes * MAX_SCAN_WINDOWS}`,
    );
    return 0;
  }

  // Returns { offset, complete } - complete false means a failed upload OR a spent run
  // budget, and the caller must not treat the file as drained.
  async drainFile(
    filePath,
    fileBytes,
    rotated,
    expectedHead,
    persistHead,
    persistSize,
    normalizedPath,
    startOffset,
    stateKey,
  ) {
    let offset = startOffset;
    let iteration = 0;
    while (offset < fileBytes) {
      if (this.runBytesSent >= this.maxRunBytes) {
        this.debug("run budget spent");
        return { offset, complete: false };
      }
      if (++iteration > MAX_CHUNKS_PER_DRAIN) {
        this.debug("iteration guard");
        return { offset, complete: false };
      }
      const advanceBytes = await this.sendNextChunk(filePath, offset, rotated, expectedHead);
      if (advanceBytes <= 0) return { offset, complete: false };
      offset += advanceBytes;
      this.runBytesSent += advanceBytes;
      this.writeState(stateKey, offset, persistHead, persistSize, normalizedPath);
    }
    return { offset, complete: true };
  }

  async shipLogFile(filePath) {
    if (!fs.existsSync(filePath)) {
      this.debug(`no such log: ${filePath}`);
      return;
    }
    this.targetBaseName = path.basename(filePath);
    this.targetFamily = this.familyForFile(this.targetBaseName);
    const stateKey = this.stateKeyForPath(filePath);
    if (!stateKey) return;
    if (this.isWithinThrottleWindow(stateKey)) {
      this.debug(`throttled: ${stateKey}`);
      return;
    }
    if (!this.acquireLock(stateKey)) {
      this.debug(`locked: ${stateKey}`);
      return;
    }
    try {
      // Stamped the instant the lock is taken, BEFORE any upload - that is what makes
      // it a crash-loop guard rather than a bandwidth measure.
      this.stampRunTime(stateKey);

      // Lexical normalisation ONLY - path.resolve does not follow symlinks, and
      // neither does the sh side's normalize_path(). They compare this as a STRING, so
      // resolving links in one of them would make the two disagree about the same file
      // and re-ship it on alternating runs. What path.resolve DOES do is collapse
      // redundant separators and `.`/`..` segments, and the sh copy had to grow a
      // segment walk to match: while it merely prefixed $PWD, `/logs//gemini.log` from
      // one shipper compared unequal to `/logs/gemini.log` from the other, so each
      // read the other's state as a different file and re-shipped the whole log.
      const normalizedPath = path.resolve(filePath);
      const state = this.readState(stateKey, normalizedPath);
      const fileBytes = fileSize(filePath);
      const currentHead = firstLineFingerprint(filePath);
      this.runBytesSent = 0;
      let offset = state.offset;

      let rotated = fileBytes < offset;
      if (currentHead && state.head && currentHead !== state.head) rotated = true;

      if (rotated) {
        this.debug(`rotation detected for ${this.targetBaseName} (size=${fileBytes} off=${offset})`);
        const rotatedPath = `${filePath}.1`;
        if (fs.existsSync(rotatedPath) && state.head) {
          const rotatedHead = firstLineFingerprint(rotatedPath);
          const rotatedBytes = fileSize(rotatedPath);
          // Validating .1's head against the STORED head is what stops a double
          // rotation from re-shipping a generation we already sent. The size floor is
          // an independent second condition: a first-line window is not a digest, so
          // two generations whose first lines are byte-identical would compare equal,
          // and a different generation almost certainly has a different size.
          if (rotatedHead === state.head && rotatedBytes >= state.size) {
            // .1 is a WHOLE generation (up to ROGUE_LOG_MAX_BYTES), so it needs the
            // same bounded chunk loop as the live file.
            //
            // An incomplete drain means a failed upload or a spent budget, and BOTH
            // must return WITHOUT resetting the offset: resetting mid-.1 would throw
            // away the rest of a rotated generation, which is silent loss. The next
            // run re-detects the rotation and resumes .1 at the stored offset.
            const rotatedDrain = await this.drainFile(
              rotatedPath,
              rotatedBytes,
              true,
              rotatedHead,
              state.head,
              state.size,
              normalizedPath,
              offset,
              stateKey,
            );
            if (!rotatedDrain.complete) return;
            offset = rotatedDrain.offset;
          } else {
            this.debug(".1 does not match the stored head -> skipping it");
          }
        }
        offset = 0;
        this.writeState(stateKey, 0, currentHead, fileBytes, normalizedPath);
      }

      await this.drainFile(
        filePath,
        fileBytes,
        false,
        currentHead,
        currentHead,
        fileBytes,
        normalizedPath,
        offset,
        stateKey,
      );
    } finally {
      // finally, so an early return still releases the lock.
      this.releaseLock();
    }
  }

  async run() {
    this.env = loadEnv(this.pluginRoot);
    this.resolveKnobs();
    if (!this.apiKey) {
      this.debug("not configured -> no-op");
      return;
    }
    if (!this.resolveActor()) {
      // Do NOT invent an identity. A wrong one creates an orphaned log_source row,
      // which is strictly worse than not shipping: the logs are uploaded, billed and
      // stored, and joined to nothing.
      this.log("outcome=skip reason=no-actor");
      return;
    }
    this.stateDir = path.join(HOME, ".rogue", "ship");
    try {
      fs.mkdirSync(this.stateDir, { recursive: true });
    } catch {
      this.debug("cannot create the state dir");
      return;
    }
    for (const target of this.targetLogFiles()) {
      if (!target) continue;
      await this.shipLogFile(target);
    }
  }
}

export async function main(argv) {
  try {
    await new Shipper(argv).run();
  } catch (err) {
    if (process.env.ROGUE_DEBUG) process.stderr.write(`[rogue-ship] fatal: ${err}\n`);
  }
}

// Auto-run only when invoked directly, so tests can import main() and stub
// globalThis.fetch.
if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  main(process.argv.slice(2)).finally(() => process.exit(0));
}
