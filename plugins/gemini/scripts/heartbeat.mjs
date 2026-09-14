#!/usr/bin/env node
// Rogue Security — Gemini CLI presence heartbeat.
//
// Usage: heartbeat.mjs [TriggerEvent]     (default SessionStart)
//
// Spawned detached by hook.mjs on SessionStart and on AfterAgent. POSTs
// /api/v1/hooks/status so this install shows up in the dashboard's Coding Agents
// roster (Connected / version / host / user) and the org learns which plugin version
// runs. Pure side-effect: fire-and-forget, never blocks Gemini, exits 0 on every path.
//
// The roster dedups one row per (host | actor-email | family | agent), so we
// always send a stable host + actor-email. Family is the fixed enum "gemini";
// the surface rides `agent` as "gemini_cli" (drives the dashboard version badge).
//
// TWO TRIGGERS, ONE SCRIPT, as in every other plugin. SessionStart fires once per
// session; AfterAgent fires once per TURN. AfterAgent exists because a session left
// open for days used to produce exactly one beacon and one log upload for its whole
// lifetime - the roster row went stale and the hook log sat on disk unshipped.
// Everything below is unchanged for SessionStart; the only difference on an
// AfterAgent is that the beacon POST is rate-limited (claimBeaconSlot) so a per-turn
// trigger does not become a per-turn request. The log shipper needs no such gate: it
// already throttles itself, and a run with nothing new makes no request at all.
//
// THE THROTTLE IS INLINED HERE rather than shared. The other five plugins load
// scripts/beacon.{sh,ps1}, a synced copy of scripts/shared/, because they ship two
// dispatchers each; Gemini CLI guarantees Node 20+, so there is a single
// implementation and nothing to keep in lockstep - the same rule as ship-logs.mjs.
// The SEMANTICS still have to match the shared library exactly, since all six
// plugins write their stamps into one ~/.rogue/beacon directory.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { EXT_ROOT, loadEnvFiles, resolveActor, installId } from "./shared.mjs";

// ── beacon throttle ─────────────────────────────────────────────────────────
// A NUMERIC ZERO DISABLES the throttle; a non-numeric value falls back to the
// default. Same rule as ROGUE_LOG_MAX_BYTES and ROGUE_SHIP_MIN_INTERVAL, so there is
// one convention across the whole plugin. All digits is not the same as
// representable: Number() turns a value wider than 2^53 into an imprecise float and a
// long enough one into Infinity, which would read as "never throttled" and loose a
// beacon on every turn - matching the sh copy's 18-digit clamp and the PowerShell
// copy's TryParse.
function beaconInterval(env) {
  const raw = env.ROGUE_HEARTBEAT_MIN_INTERVAL;
  if (typeof raw !== "string" || !/^[0-9]+$/.test(raw)) return 900;
  const parsed = Number(raw);
  if (!Number.isSafeInteger(parsed)) return 900;
  return parsed;
}

// Per-agent-family, under the ~/.rogue tree all six plugins share - so a machine
// running several coding agents throttles each family's beacon separately.
function beaconStampPath() {
  return path.join(os.homedir(), ".rogue", "beacon", ".last-gemini");
}

// 0700 dir / 0600 file, matching the log tree and beacon.sh's `umask 077`: this file
// says when a machine was active, and nothing else on the box needs to read that.
function writeBeaconStamp() {
  try {
    const p = beaconStampPath();
    fs.mkdirSync(path.dirname(p), { recursive: true, mode: 0o700 });
    fs.writeFileSync(p, `${Math.floor(Date.now() / 1000)}\n`, { mode: 0o600 });
  } catch {
    /* best-effort, exactly as in beacon.sh */
  }
}

// true = send this beacon (and the stamp has been written); false = skip it.
// Deciding and stamping are ONE call on purpose: a caller that forgot the stamp would
// leave the window permanently open and the throttle would silently do nothing. The
// stamp is written BEFORE the request, which makes this a crash-loop guard as much as
// a rate limit - a beacon that hangs or dies still costs the next turn its attempt.
//
// A SessionStart trigger is NEVER throttled: it fires once per session, and a new
// session is exactly when the roster wants the update (a re-install with a new
// version, the same user on a different surface).
//
// Every unreadable, corrupt, empty or FUTURE stamp answers "send". A stamp we cannot
// trust must never be able to silence presence reporting - on the roster that is
// indistinguishable from an uninstalled plugin.
function claimBeaconSlot(env, unthrottled) {
  if (unthrottled) {
    writeBeaconStamp();
    return true;
  }
  const interval = beaconInterval(env);
  if (interval > 0) {
    try {
      const raw = fs.readFileSync(beaconStampPath(), "utf8").split("\n")[0].trim();
      if (/^[0-9]+$/.test(raw)) {
        const last = Number(raw);
        const now = Math.floor(Date.now() / 1000);
        if (Number.isSafeInteger(last) && last <= now && now - last < interval) {
          return false;
        }
      }
    } catch {
      /* no stamp, or unreadable -> not throttled */
    }
  }
  writeBeaconStamp();
  return true;
}


async function main() {
  const env = loadEnvFiles();
  const apiKey = env.ROGUE_API_KEY || "";
  if (!apiKey) return; // not configured → no-op

  // Same cascade hook.mjs runs, so the roster row and the event rows agree.
  const { email, name } = resolveActor(env);

  const base = (env.ROGUE_BASE_URL || "https://api.rogue.security").replace(
    /\/+$/,
    "",
  );
  // Same three values hook.mjs sends as headers on every event, so both writers
  // land on one roster row (see installId).
  const install = installId();
  const body = JSON.stringify({
    agent_family: "gemini",
    agent: install.agent,
    version: install.version,
    host: install.host,
    actor_email: email,
    actor_name: name || "",
  });

  // Which hook fired us. Anything other than SessionStart is a high-frequency
  // trigger and is throttled; the default keeps a manual run (and any older
  // hook.mjs, which passes no argument) behaving as it always did.
  const trigger = process.argv[2] || "SessionStart";

  if (claimBeaconSlot(env, trigger === "SessionStart")) {
    try {
      await fetch(`${base}/api/v1/hooks/status`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "x-rogue-api-key": apiKey,
        },
        body,
        signal: AbortSignal.timeout(10000),
      });
    } catch {
      /* fire-and-forget */
    }
  }

  // ── ship the hook log ──────────────────────────────────────────────────────
  // AFTER the status POST, as in every other plugin: the heartbeat is what creates
  // or refreshes the roster row an uploaded log attaches to, so this order means
  // the server has somewhere to put the logs before they arrive.
  //
  // Runs on BOTH triggers and deliberately OUTSIDE the beacon throttle above: a
  // throttled beacon still means a turn happened, and the log is worth draining
  // either way. This is the whole point of the AfterAgent trigger - on SessionStart
  // alone, a long session's log never left the disk.
  //
  // IN-PROCESS, unlike the sh and PowerShell callers, which spawn a child. Those
  // have to: a sourced sh script shares every variable, and a PowerShell
  // scriptblock resolves `$script:` against the caller's scope. An ESM module has
  // neither problem - its scope is its own - and ship-logs.mjs only calls
  // process.exit from the `argv[1] === this file` auto-run branch, which an import
  // does not take. So this saves a whole node startup for free. This script is
  // already spawned detached by hook.mjs, so nothing a user sees waits on it.
  //
  // THE ACTOR MUST BE PUT INTO process.env FIRST. It is resolved into module
  // locals above (never process.env), and the shipper reads it from the
  // environment because it deliberately has no cascade of its own - the plugins'
  // cascades differ, so a re-resolve would key the log's source row differently
  // from the roster row just posted and the logs would attach to nothing. Note
  // loadEnvFiles() returns a merged object WITHOUT mutating process.env, which is
  // exactly why this assignment is needed rather than assumed.
  try {
    process.env.ROGUE_ACTOR_EMAIL = email;
    process.env.ROGUE_ACTOR_NAME = name || "";
    const shipper = await import("./ship-logs.mjs");
    await shipper.main([EXT_ROOT, "gemini", install.version, "gemini"]);
  } catch {
    /* a missing or broken shipper must never affect the heartbeat */
  }
}

main().finally(() => process.exit(0));
