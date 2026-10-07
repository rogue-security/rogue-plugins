import { readFileSync } from 'node:fs';

// Only native denies are relayed; audit-only callbacks cannot restart a finished turn.
let out = {};
try {
  const r = JSON.parse(readFileSync(0, 'utf8'));
  if (!r || Array.isArray(r) || typeof r !== 'object') throw new Error('Invalid hook response');
  const h = r.hookSpecificOutput;
  switch (process.argv[2]) {
    case 'UserPromptSubmit':
      if (r.decision === 'block' && typeof r.reason === 'string') out = { decision: 'block', reason: r.reason };
      break;
    case 'PreToolUse':
      if (h?.permissionDecision === 'deny' && typeof h.permissionDecisionReason === 'string') out = { hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: h.permissionDecisionReason } };
      break;
    case 'PermissionRequest':
      if (h?.decision?.behavior === 'deny' && typeof h.decision.message === 'string') out = { hookSpecificOutput: { hookEventName: 'PermissionRequest', decision: { behavior: 'deny', message: h.decision.message } } };
      break;
    case 'PostToolUse':
      if (r.continue === false && typeof r.stopReason === 'string') out = { continue: false, stopReason: r.stopReason };
      break;
  }
} catch { process.exitCode = 1; }
process.stdout.write(JSON.stringify(out));
