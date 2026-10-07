import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve, join } from 'node:path';
import { spawnSync } from 'node:child_process';
const root = resolve(import.meta.dirname, '..');
const run = (script, args = [], options = {}) => spawnSync(process.execPath, [join(root, 'plugins/muse/scripts', script), ...args], { encoding: 'utf8', ...options });

test('installation is idempotent, preserves foreign hooks and settings, and uninstalls only owned commands', () => {
  const home = mkdtempSync(join(tmpdir(), "muse-home-' space-"));
  try {
    const dir = join(home, '.config/muse'); mkdirSync(dir, { recursive: true });
    const file = join(dir, 'settings.json');
    const original = { model: 'personal-model', custom: { keep: true }, hooks: { PreToolUse: [{ matcher: 'bash', hooks: [{ type: 'command', command: 'echo foreign' }] }] } };
    writeFileSync(file, JSON.stringify(original));
    const env = { ...process.env, HOME: home, XDG_CONFIG_HOME: join(home, '.config') };
    for (let i = 0; i < 2; i++) assert.equal(run('install.mjs', [], { env }).status, 0);
    assert.equal(run('status.mjs', [], { env }).status, 0);
    const config = JSON.parse(readFileSync(file));
    assert.equal(config.hooks.PreToolUse.length, 2);
    assert.deepEqual(config.hooks.PreToolUse[0], original.hooks.PreToolUse[0]);
    assert.equal(Object.keys(config.hooks).length, 10);
    assert.equal(run('install.mjs', ['--uninstall'], { env }).status, 0);
    assert.deepEqual(JSON.parse(readFileSync(file)), original);
    assert.notEqual(run('status.mjs', [], { env }).status, 0);
    writeFileSync(file, '{invalid');
    assert.notEqual(run('install.mjs', [], { env }).status, 0);
    assert.equal(readFileSync(file, 'utf8'), '{invalid');
  } finally { rmSync(home, { recursive: true, force: true }); }
});

test('fresh settings and invalid settings do not lose configuration', () => {
  const home = mkdtempSync(join(tmpdir(), 'muse-new-'));
  try {
    const env = { ...process.env, HOME: home, XDG_CONFIG_HOME: join(home, '.config') };
    assert.equal(run('install.mjs', [], { env }).status, 0);
    const file = join(home, '.config/muse/settings.json');
    for (const invalid of [[], { hooks: [] }, { hooks: { PreToolUse: 'bad' } }]) {
      writeFileSync(file, JSON.stringify(invalid));
      assert.notEqual(run('install.mjs', [], { env }).status, 0);
      assert.deepEqual(JSON.parse(readFileSync(file)), invalid);
    }
  } finally { rmSync(home, { recursive: true, force: true }); }
});

test('response relay validates native JSON and neutralizes Stop even on a deny', () => {
  const forms = {
    UserPromptSubmit: { decision: 'block', reason: 'a "quoted" reason\nnext line' },
    PreToolUse: { hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: 'no' } },
    PermissionRequest: { hookSpecificOutput: { hookEventName: 'PermissionRequest', decision: { behavior: 'deny', message: 'no' } } },
    PostToolUse: { continue: false, stopReason: 'no' },
  };
  for (const [event, response] of Object.entries(forms)) assert.deepEqual(JSON.parse(run('response.mjs', [event], { input: JSON.stringify(response) }).stdout), response);
  for (const event of ['Stop', 'SubagentStop', 'Unknown']) assert.equal(run('response.mjs', [event], { input: JSON.stringify(forms.PostToolUse) }).stdout, '{}');
  for (const input of ['', 'bad', 'null', '[]', '{"decision":"block","reason":3}']) assert.equal(run('response.mjs', ['UserPromptSubmit'], { input }).stdout, '{}');
});

test('bridge forwards exact bytes and identity, and fails open on HTTP, JSON and timeout errors', async () => {
  const { createServer } = await import('node:http');
  const { spawn } = await import('node:child_process');
  const home = mkdtempSync(join(tmpdir(), 'muse-http-'));
  let mode = 'allow', received;
  const server = createServer(async (req, res) => {
    const chunks = []; for await (const c of req) chunks.push(c);
    received = { headers: req.headers, body: Buffer.concat(chunks).toString() };
    if (mode === 'timeout') return;
    res.statusCode = mode === 'http' ? 500 : 200;
    res.end(mode === 'malformed' ? 'not-json' : mode === 'deny' ? '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"blocked"}}' : '{}');
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const call = (input, event = 'PreToolUse') => new Promise((resolve, reject) => {
    const p = spawn('bash', [join(root, 'plugins/muse/scripts/hook.sh'), event, process.execPath], { env: { ...process.env, HOME: home } });
    let stdout = ''; p.stdout.on('data', d => stdout += d); p.stderr.resume();
    p.on('error', reject); p.on('exit', code => resolve({ code, stdout })); p.stdin.end(input);
  });
  try {
    const file = join(home, '.rogue-env');
    writeFileSync(file, `ROGUE_API_KEY='local-test-key'\nROGUE_BASE_URL='http://127.0.0.1:${server.address().port}'\nROGUE_ACTOR_EMAIL='muse@example.test'\n`, { mode: 0o600 });
    const body = JSON.stringify({ hook_event_name: 'PreToolUse', tool_input: { content: 'x'.repeat(300000) } });
    assert.deepEqual(await call(body), { code: 0, stdout: '{}\n' });
    assert.equal(received.body, body);
    assert.equal(received.headers['x-rogue-agent'], 'muse_code');
    assert.equal(received.headers['x-rogue-actor-email'], 'muse@example.test');
    mode = 'deny';
    assert.equal(JSON.parse((await call('{}')).stdout).hookSpecificOutput.permissionDecision, 'deny');
    assert.equal((await call('{}', 'Stop')).stdout, '{}\n');
    for (mode of ['http', 'malformed', 'timeout']) assert.deepEqual(await call('{}'), { code: 0, stdout: '{}\n' });
    const logs = readFileSync(join(home, '.rogue/logs/muse.log'), 'utf8');
    assert.ok(!logs.includes('local-test-key'));
    assert.match(logs, /outcome=fail-open http=200 reason=invalid-response/);
  } finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); rmSync(home, { recursive: true, force: true }); }
});
