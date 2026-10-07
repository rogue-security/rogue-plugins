import { cpSync, existsSync, lstatSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';

const events = ['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PermissionRequest', 'PostToolUse', 'PostToolUseFailure', 'Stop', 'SessionEnd', 'SubagentStart', 'SubagentStop'];
const quote = s => `'${s.replaceAll("'", "'\\''")}'`;
const root = resolve(homedir(), '.rogue/plugins/muse');
const settings = join(process.env.XDG_CONFIG_HOME || join(homedir(), '.config'), 'muse/settings.json');
const receipt = join(root, 'installed-commands.json');
const uninstall = process.argv.includes('--uninstall');
if (process.platform !== 'darwin' && process.platform !== 'linux') throw new Error('Muse hook installation supports macOS and Linux only');
const plainFile = p => { if (existsSync(p) && !lstatSync(p).isFile()) throw new Error(`Refusing non-regular file: ${p}`); };
plainFile(settings);
plainFile(receipt);
mkdirSync(dirname(settings), { recursive: true, mode: 0o700 });
const lock = `${settings}.rogue-lock`;
mkdirSync(lock, { mode: 0o700 });
let temp;
try {
  const original = existsSync(settings) ? readFileSync(settings) : null;
  const config = original ? JSON.parse(original.toString()) : {};
  if (!config || Array.isArray(config) || typeof config !== 'object') throw new Error('Muse settings must be an object');
  if (config.hooks !== undefined && (!config.hooks || Array.isArray(config.hooks) || typeof config.hooks !== 'object')) throw new Error('Muse hooks must be an object');
  const hooks = config.hooks ?? {};
  const previous = existsSync(receipt) ? JSON.parse(readFileSync(receipt, 'utf8')) : [];
  if (!Array.isArray(previous) || previous.some(c => typeof c !== 'string')) throw new Error('Invalid Muse install receipt');
  const commands = events.map(e => `bash ${quote(join(root, 'scripts/hook.sh'))} ${e} ${quote(process.execPath)}`);
  const owned = new Set([...previous, ...commands]);
  for (const [event, entries] of Object.entries(hooks)) {
    if (!Array.isArray(entries)) throw new Error(`Invalid hook list for ${event}`);
    hooks[event] = entries.flatMap(entry => {
      if (!entry || typeof entry !== 'object' || !Array.isArray(entry.hooks)) return [entry];
      const remaining = entry.hooks.filter(h => !owned.has(h?.command));
      return remaining.length === entry.hooks.length ? [entry] : remaining.length ? [{ ...entry, hooks: remaining }] : [];
    });
    if (!hooks[event].length) delete hooks[event];
  }
  if (!uninstall) events.forEach((e, i) => { (hooks[e] ??= []).push({ hooks: [{ type: 'command', command: commands[i], timeout: 6 }] }); });
  if (Object.keys(hooks).length) config.hooks = hooks;
  else delete config.hooks;
  if (!uninstall) {
    const source = resolve(dirname(fileURLToPath(import.meta.url)), '..');
    if (source !== root) {
      mkdirSync(root, { recursive: true, mode: 0o700 });
      cpSync(join(source, 'scripts'), join(root, 'scripts'), { recursive: true });
      cpSync(join(source, 'plugin.json'), join(root, 'plugin.json'));
    }
  }
  plainFile(settings);
  const current = existsSync(settings) ? readFileSync(settings) : null;
  if (original === null ? current !== null : current === null || !original.equals(current)) throw new Error('Muse settings changed during installation; retry');
  if (original) writeFileSync(`${settings}.rogue-backup-${Date.now()}`, original, { mode: 0o600, flag: 'wx' });
  temp = `${settings}.rogue-${randomUUID()}`;
  writeFileSync(temp, JSON.stringify(config, null, 2) + '\n', { mode: 0o600, flag: 'wx' });
  renameSync(temp, settings);
  temp = undefined;
  if (!uninstall) writeFileSync(receipt, JSON.stringify(commands), { mode: 0o600 });
  else if (existsSync(receipt)) rmSync(receipt);
  console.log(uninstall ? 'Removed Rogue Muse hooks; credentials and other hooks preserved.' : `Installed Rogue Muse hooks in ${settings}. Start a new Muse session.`);
} finally {
  if (temp) rmSync(temp, { force: true });
  rmSync(lock, { recursive: true });
}
