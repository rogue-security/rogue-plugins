import { accessSync, constants, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
const root = join(homedir(), '.rogue/plugins/muse');
const events = ['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PermissionRequest', 'PostToolUse', 'PostToolUseFailure', 'Stop', 'SessionEnd', 'SubagentStart', 'SubagentStop'];
try {
  const config = JSON.parse(readFileSync(join(process.env.XDG_CONFIG_HOME || join(homedir(), '.config'), 'muse/settings.json'), 'utf8'));
  const commands = JSON.parse(readFileSync(join(root, 'installed-commands.json'), 'utf8'));
  if (!Array.isArray(commands) || commands.length !== events.length) throw new Error('Missing install receipt');
  for (const file of ['hook.sh', 'response.mjs', 'env-file.sh', 'actor.sh', 'install-id.sh']) accessSync(join(root, 'scripts', file), constants.R_OK);
  for (const [i, event] of events.entries()) {
    if (!config.hooks?.[event]?.some(entry => entry.hooks?.some(h => h.type === 'command' && h.command === commands[i] && h.timeout === 6))) throw new Error(`Missing ${event} hook`);
  }
  console.log('Muse hooks installed. Start a new session to verify live traffic.');
} catch (e) { console.error(e.message); process.exitCode = 1; }
