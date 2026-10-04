#!/usr/bin/env node
// Test harness for plugins/gemini/scripts/ship-logs.mjs.
//
// Stubs globalThis.fetch so the Node shipper writes its request bodies to $CAP with
// exactly the same naming the fake `curl` in tests/test_ship_logs.sh uses - which is
// what lets one suite assert against both implementations. Same role as
// tests/log_probe.ps1 plays for the PowerShell dispatchers.
//
//   CAP=<dir> [FAKE_CODE=500] node tests/ship_probe.mjs <root> <slug> <ver> <family>

import fs from "node:fs";
import path from "node:path";
import { main } from "../plugins/gemini/scripts/ship-logs.mjs";

const cap = process.env.CAP || ".";
const code = Number(process.env.FAKE_CODE || 200);

globalThis.fetch = async (_url, opts) => {
  let n = 0;
  while (fs.existsSync(path.join(cap, `body.${n}`))) n++;
  try {
    fs.writeFileSync(path.join(cap, `body.${n}`), opts && opts.body ? opts.body : "");
  } catch {}
  return { status: code, ok: code >= 200 && code < 300 };
};

await main(process.argv.slice(2));
process.exit(0);
