import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import {createHash} from 'node:crypto';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const temp=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'rogue-protection-test-')));
const fixturePlugins=path.join(temp,'plugins');
fs.cpSync(path.join(repo,'plugins'),fixturePlugins,{recursive:true});
function isolateEnv(directory) {
  for (const entry of fs.readdirSync(directory,{withFileTypes:true})) {
    const file=path.join(directory,entry.name);
    if (entry.isDirectory()) isolateEnv(file);
    else if (entry.name.endsWith('.sh')) fs.writeFileSync(file,fs.readFileSync(file,'utf8').replaceAll('/etc/rogue/env',path.join(temp,'empty-env')).replaceAll('$HOME/.rogue-env',path.join(temp,'empty-env')));
    else if (entry.name.endsWith('.mjs')) fs.writeFileSync(file,fs.readFileSync(file,'utf8').replaceAll('"/etc/rogue/env"',JSON.stringify(path.join(temp,'empty-env'))));
  }
}
isolateEnv(fixturePlugins);
let revision=1, paused=true, available=true, legacy=false, disconnect=false, malformedDecision;
const requests=[];
const server=http.createServer(async (req,res) => {
  let body=''; for await (const chunk of req) body+=chunk;
  requests.push({path:req.url, body, key:req.headers["x-rogue-api-key"], installationKey:req.headers["x-rogue-installation-key"]});
  if (disconnect) { req.socket.destroy(); return; }
  if (legacy && req.url.includes('/hooks/protection/')) { res.statusCode=404; res.end('{}'); return; }
  if (!available) { res.statusCode=503; res.end('{}'); return; }
  res.setHeader('content-type','application/json');
  if (req.url.endsWith('/enroll')) { res.end(JSON.stringify({apiKey:'installation_test_key', installation:{id:'test',type:'coding_agent',role:'coding'}})); return; }
  if (req.url.endsWith('/state')) {
    if (req.headers.accept === 'text/tab-separated-values') { res.setHeader('content-type','text/tab-separated-values'); res.end([1,revision,Number(paused),0,0,0,Math.floor(Date.now()/1000),revision,0].join('\t')); return; }
    res.end(JSON.stringify(malformedDecision ?? {protocolVersion:1,revision,serverTime:new Date().toISOString(),aidr:{paused,expiresAt:null,revision},aispm:{paused:false,expiresAt:null,revision:0}})); return;
  }
  if (req.url.endsWith('/ack')) { res.end('{"success":true}'); return; }
  res.end('{}');
});
await new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
const base=`http://127.0.0.1:${server.address().port}`;
function run(command,args,env, input) {
  return new Promise((resolve,reject) => {
    const child=spawn(command,args,{cwd:repo,env:{...process.env,HOME:temp,USERPROFILE:temp,...env},stdio:['pipe','pipe','pipe']});
    let out='',err=''; child.stdout.on('data',b=>out+=b); child.stderr.on('data',b=>err+=b);
    if (input !== undefined) child.stdin.end(input);
    const timeout=setTimeout(()=>{child.kill();reject(new Error(`Hook read stdin while paused: ${args[0]}`));},10000);
    child.once('exit',code=>{clearTimeout(timeout);resolve({code,out,err});});
  });
}
try {
  await test('every Unix bridge exits before reading paused stdin or sending an activity payload', async () => {
    for (const [plugin,slug,family] of [['rogue','claude','claude'],['codex','codex','openai'],['cursor','cursor','cursor'],['copilot','copilot','copilot'],['antigravity','antigravity','antigravity'],['kiro','kiro','kiro'],['gemini','gemini','gemini']]) {
      const root=path.join(fixturePlugins,plugin);
      const start=requests.length;
      const env={ROGUE_API_KEY:`provision_${slug}`,ROGUE_BASE_URL:base,ROGUE_PROTECTION_DIR:temp,CLAUDE_PLUGIN_ROOT:root,CODEX_PLUGIN_ROOT:root,CURSOR_PLUGIN_ROOT:root,PLUGIN_ROOT:root,CLAUDE_CODE_ENTRYPOINT:'cli',ROGUE_DEBUG:'',ROGUE_LOG_DIR:temp};
      const event=({cursor:'beforeShellExecution',copilot:'preToolUse',antigravity:'PreInvocation',gemini:'BeforeTool'})[plugin] || 'PreToolUse';
      const result=await run(plugin==='gemini'?process.execPath:'bash',[path.join(root,'scripts',plugin==='gemini'?'hook.mjs':'hook.sh'),event,'kiro_cli'],env);
      assert.equal(result.code,0,`${plugin}: ${result.err}`);
      assert.deepEqual(JSON.parse(result.out || '{}'),{},plugin);
      const calls=requests.slice(start);
      assert(calls.some(call=>call.path.endsWith('/state')),`${plugin} did not fetch its pause decision`);
      assert(calls.every(call=>call.path.includes('/hooks/protection/')),`${family} sent an activity payload`);
    }
  });
  await test('resume discards queued log bytes and ships only fresh content', async () => {
    const root=path.join(fixturePlugins,'codex');
    const directory=path.join(temp,fs.readdirSync(temp).find(name=>name.startsWith('codex-default-')));
    const log=path.join(directory,'codex.log');
    fs.writeFileSync(log, 'before\npaused-canary\n');
    revision=2; paused=false;
    fs.writeFileSync(path.join(directory,'attempt'),'0');
    const env={ROGUE_API_KEY:'provision_codex',ROGUE_BASE_URL:base,ROGUE_PROTECTION_DIR:temp,ROGUE_ACTOR_EMAIL:'qa@example.test',ROGUE_ACTOR_NAME:'QA',ROGUE_SHIP_MIN_INTERVAL:'0',ROGUE_DEBUG:'1'};
    const start=requests.length;
    const args=[path.join(root,'scripts/ship-logs.sh'),root,'codex','1.0.0','openai'];
    const resumed=await run('sh',args,env,'');
    assert.equal(resumed.code,0,resumed.err);
    assert(!requests.slice(start).some(call=>call.path.endsWith('/logs')), resumed.err);
    fs.appendFileSync(log,'fresh-canary\n');
    const fresh=await run('sh',args,env,'');
    assert.equal(fresh.code,0,fresh.err);
    const uploads=requests.slice(start).filter(call=>call.path.endsWith('/logs'));
    assert(uploads.length > 0, fresh.err);
    for (const upload of uploads) {
      assert.equal(upload.key,'installation_test_key');
      const content=Buffer.from(JSON.parse(upload.body).content_b64,'base64').toString();
      assert(!content.includes('paused-canary'));
    }
    assert(uploads.some(upload=>Buffer.from(JSON.parse(upload.body).content_b64,'base64').toString().includes('fresh-canary')));
    assert.equal(fs.readFileSync(log,'utf8'),'before\npaused-canary\nfresh-canary\n');
    revision=3; paused=true;
    fs.writeFileSync(path.join(directory,'attempt'),'0');
    await run('bash',[path.join(root,'scripts/hook.sh'),'PreToolUse'],{...env,PLUGIN_ROOT:root,CODEX_PLUGIN_ROOT:root});
  });
  await test('Gemini resume drops queued logs and sends fresh logs under the installation key', async () => {
    const root=path.join(fixturePlugins,'gemini');
    const directory=path.join(temp,`gemini-default-${createHash('sha256').update(`${base}\nprovision_gemini`).digest('hex')}`);
    const log=path.join(directory,'gemini.log');
    fs.writeFileSync(log,'paused-node-canary\n');
    revision++; paused=false;
    fs.writeFileSync(path.join(directory,'attempt'),'0');
    const env={ROGUE_DEBUG:'1',ROGUE_API_KEY:'provision_gemini',ROGUE_BASE_URL:base,ROGUE_PROTECTION_DIR:temp,ROGUE_ACTOR_EMAIL:'qa@example.test',ROGUE_ACTOR_NAME:'QA',ROGUE_SHIP_MIN_INTERVAL:'0'};
    const args=[path.join(root,'scripts/ship-logs.mjs'),root,'gemini','1.0.0','gemini'];
    const start=requests.length;
    const output=await run(process.execPath,args,env,''); assert.equal(output.code,0,output.err);
    assert(!requests.slice(start).some(call=>call.path.endsWith('/logs')));
    fs.appendFileSync(log,'fresh-node-canary\n');
    const freshOutput=await run(process.execPath,args,env,''); assert.equal(freshOutput.code,0,freshOutput.err);
    const uploads=requests.slice(start).filter(call=>call.path.endsWith('/logs'));
    assert(uploads.length>0, output.err + freshOutput.err + JSON.stringify({files:fs.readdirSync(directory),state:fs.readFileSync(path.join(directory,"state.json"),"utf8"),paths:requests.slice(start).map(call=>call.path)}));
    assert(uploads.every(call=>call.key==='installation_test_key' && !Buffer.from(JSON.parse(call.body).content_b64,'base64').toString().includes('paused-node-canary')));
    assert(uploads.some(call=>Buffer.from(JSON.parse(call.body).content_b64,'base64').toString().includes('fresh-node-canary')));
  });
  await test('PowerShell legacy enrollment works with the shipper error preference', {skip:!process.env.ROGUE_TEST_PWSH}, async () => {
    legacy=true;
    try {
      const profile=path.join(temp,'ps-legacy-profile'); fs.mkdirSync(profile);
      const script=`$ErrorActionPreference='SilentlyContinue'; . '${path.join(repo,'scripts/shared/protection.ps1')}'; $key=Initialize-RogueProtection -Key 'legacy_key' -BaseUrl '${base}' -Slug 'claude' -Family 'claude'; if ($key -ne 'legacy_key' -or -not (Enter-RogueProtection)) {exit 9}; Write-Output 'allowed'`;
      const result=await run(process.env.ROGUE_TEST_PWSH,['-NoProfile','-Command',script],{USERPROFILE:profile,ROGUE_PROTECTION_DIR:''},'');
      assert.equal(result.code,0,result.err); assert.match(result.out,/allowed/);
      const root=path.join(profile,'.rogue/protection');
      assert(fs.readdirSync(root).some(name=>fs.existsSync(path.join(root,name,'legacy-server'))));
    } finally {legacy=false;}
  });
  await test('PowerShell gate persists the same pause contract', {skip:!process.env.ROGUE_TEST_PWSH}, async () => {
    paused=true; revision++;
    const helper=path.join(repo,'scripts/shared/protection.ps1').replaceAll("'","''");
    const probe=path.join(temp,'probe.ps1');
    fs.writeFileSync(probe, `$ErrorActionPreference='Stop'\n. '${helper}'\n$key=Initialize-RogueProtection -Key 'ps_test_key' -BaseUrl '${base}' -Slug 'ps-test' -Family 'claude'\nif (Enter-RogueProtection) { throw ('Paused work started; directory=' + $script:RPDirectory + '; saved=' + (Get-Content -LiteralPath ($script:RPDirectory + '/state.json') -Raw -ErrorAction SilentlyContinue)) }\n[Console]::Out.Write('paused')\n`);
    const result=await run(process.env.ROGUE_TEST_PWSH,['-NoProfile','-File',probe],{ROGUE_PROTECTION_DIR:temp},'');
    assert.equal(result.code,0,result.err + JSON.stringify(requests.slice(-5).map(r=>({path:r.path,body:r.body})))); assert.equal(result.out,'paused');
  });
  await test('Gemini cancels buffered stdin without sending paused activity', async () => {
    available=true; paused=false; revision++;
    const root=path.join(fixturePlugins,'gemini');
    const start=requests.length;
    const child=spawn(process.execPath,[path.join(root,'scripts/hook.mjs'),'BeforeTool'],{cwd:repo,env:{...process.env,ROGUE_API_KEY:'buffered_gemini',ROGUE_BASE_URL:base,ROGUE_PROTECTION_DIR:temp,ROGUE_DEBUG:''},stdio:['pipe','pipe','pipe']});
    let out=''; child.stdout.on('data',b=>out+=b); child.stderr.resume();
    const exit=new Promise(resolve=>child.once('exit',resolve));
    child.stdin.write(JSON.stringify({session_id:'buffered-canary',hook_event_name:'BeforeTool',tool_name:'run_shell_command',tool_input:{command:'paused-buffer-canary'}}));
    let directory;
    for(let attempt=0;attempt<100;attempt++) {
      directory=fs.readdirSync(temp).map(name=>path.join(temp,name)).find(dir=>fs.existsSync(path.join(dir,`active.${child.pid}`)));
      if(directory) break;
      await new Promise(resolve=>setTimeout(resolve,25));
    }
    assert(directory,'hook did not enter guarded input collection');
    paused=true; revision++;
    fs.writeFileSync(path.join(directory,'state.json'),JSON.stringify({decision:{protocolVersion:1,revision,serverTime:new Date().toISOString(),aidr:{paused:true,expiresAt:null,revision},aispm:{paused:false,expiresAt:null,revision:0}},receivedAt:Date.now()}));
    const timeout=setTimeout(()=>child.kill(),3000);
    assert.equal(await exit,0); clearTimeout(timeout);
    assert.deepEqual(JSON.parse(out || '{}'),{});
    assert(!requests.slice(start).some(call=>call.path.endsWith('/hooks/gemini')));
  });
  await test('Gemini rejects malformed cached and remote decisions without clearing a valid pause',async()=>{
    const {Protection}=await import(path.join(fixturePlugins,'gemini/scripts/protection.mjs'));
    const directory=path.join(temp,'malformed-decisions'); fs.mkdirSync(directory);
    const client=new Protection(directory,base,'malformed_test_key');
    const decision={protocolVersion:1,revision,serverTime:new Date().toISOString(),aidr:{paused:true,expiresAt:null,revision},aispm:{paused:false,expiresAt:null,revision:0}};
    const saved=JSON.stringify({decision,receivedAt:Date.now()});
    const cases=[
      {...decision,aidr:{...decision.aidr,paused:null}},
      {...decision,aidr:{...decision.aidr,paused:'false'}},
      {...decision,aidr:{}},
      {...decision,aidr:{...decision.aidr,revision:-1}},
      {...decision,revision:1.5},
      {...decision,revision:-1},
      {...decision,serverTime:'invalid'},
      {...decision,aidr:{...decision.aidr,expiresAt:'invalid'}},
      {...decision,aispm:null},
    ];
    try {
      for (const invalid of cases) {
        fs.writeFileSync(client.file('state.json'),JSON.stringify({decision:invalid,receivedAt:Date.now()}));
        assert.equal(client.current(),false);
        assert.equal(client.enter(),false);
        const beforeAck=requests.length; await client.ack();
        assert.equal(requests.length,beforeAck);
        fs.writeFileSync(client.file('state.json'),saved);
        malformedDecision=invalid;
        await client.refresh();
        assert.equal(fs.readFileSync(client.file('state.json'),'utf8'),saved);
        assert.equal(client.current(),false);
        assert(!requests.slice(beforeAck).some(call=>call.path.endsWith('/ack')));
      }
      fs.writeFileSync(client.file('state.json'),JSON.stringify({decision:{...decision,aidr:{...decision.aidr,paused:false}},receivedAt:'invalid'}));
      assert.equal(client.current(),false);
      fs.writeFileSync(client.file('state.json'),JSON.stringify({decision:{...decision,aidr:{...decision.aidr,expiresAt:new Date(Date.now()-1000).toISOString()}},receivedAt:Date.now()}));
      assert.equal(client.current(),true,'a valid expired pause still resumes');
    } finally {malformedDecision=undefined;}
  });
  await test('Gemini keeps a saved pause when bookkeeping cannot be written',async()=>{
    const root=path.join(fixturePlugins,'gemini');
    const directory=path.join(temp,`gemini-default-${createHash('sha256').update(`${base}\nprovision_gemini`).digest('hex')}`);
    const saved=JSON.parse(fs.readFileSync(path.join(directory,'state.json'),'utf8'));
    saved.decision.aidr.paused=true; saved.decision.aidr.expiresAt=null;
    fs.writeFileSync(path.join(directory,'state.json'),JSON.stringify(saved));
    fs.rmSync(path.join(directory,'used'),{force:true}); fs.mkdirSync(path.join(directory,'used'));
    available=false;
    const start=requests.length;
    const result=await run(process.execPath,[path.join(root,'scripts/hook.mjs'),'BeforeTool'],{ROGUE_API_KEY:'provision_gemini',ROGUE_BASE_URL:base,ROGUE_PROTECTION_DIR:temp});
    assert.equal(result.code,0,result.err); assert.deepEqual(JSON.parse(result.out || '{}'),{});
    assert(!requests.slice(start).some(call=>call.path.endsWith('/hooks/gemini')));
    fs.rmdirSync(path.join(directory,'used')); available=true;
  });
  await test('changed provisioning credentials restore the existing installation',async()=>{
    paused=true; revision++;
    const root=path.join(fixturePlugins,'codex');
    const start=requests.length;
    const result=await run('sh',[path.join(root,'scripts/hook.sh'),'PreToolUse'],{ROGUE_API_KEY:'rotated_codex',ROGUE_BASE_URL:base,ROGUE_PROTECTION_DIR:temp,PLUGIN_ROOT:root});
    assert.equal(result.code,0,result.err);
    assert(requests.slice(start).some(call=>call.path.endsWith('/enroll') && call.key==='rotated_codex' && call.installationKey==='installation_test_key'));
    assert(!requests.slice(start).some(call=>call.path.endsWith('/hooks/openai')));
  });
  await test('rotation reuses live leases before acknowledging a pause',async()=>{
    available=true; paused=true; revision++;
    const {Protection}=await import(path.join(fixturePlugins,'gemini/scripts/protection.mjs'));
    const directory=path.join(temp,`gemini-default-${createHash('sha256').update(`${base}\nprovision_gemini`).digest('hex')}`);
    fs.writeFileSync(path.join(directory,`active.${process.pid}`),'0');
    fs.writeFileSync(path.join(directory,'attempt'),'0');
    fs.rmSync(path.join(directory,'ack'),{force:true});
    const start=requests.length;
    const client=await Protection.connect({ROGUE_API_KEY:'rotated_lease_gemini',ROGUE_BASE_URL:base,ROGUE_PROTECTION_DIR:temp});
    assert.equal(client.directory,directory);
    assert(!requests.slice(start).some(call=>call.path.endsWith('/ack') && JSON.parse(call.body).status==='applied'));
    fs.rmSync(path.join(directory,`active.${process.pid}`));
    await client.ack();
    assert(requests.slice(start).some(call=>call.path.endsWith('/ack') && JSON.parse(call.body).status==='applied'));
  });
  await test('a failed state save blocks work and reports failure rather than applied',async()=>{
    available=true; paused=true; revision++;
    const {Protection}=await import(path.join(fixturePlugins,'gemini/scripts/protection.mjs'));
    const directory=path.join(temp,'persist-failure'); fs.mkdirSync(directory);
    fs.mkdirSync(path.join(directory,'state.json'));
    const client=new Protection(directory,base,'installation_test_key');
    const start=requests.length;
    await client.refresh();
    assert.equal(client.current(),false);
    const acks=requests.slice(start).filter(call=>call.path.endsWith('/ack')).map(call=>JSON.parse(call.body));
    assert(acks.some(ack=>ack.status==='failed' && ack.error==='state_persistence_failed'));
    assert(!acks.some(ack=>ack.status==='applied'));
  });
  await test('offline key rotation never falls back to unscoped collection',async()=>{
    available=false;
    for (const [plugin,key] of [['codex','offline_rotated_codex'],['gemini','offline_rotated_gemini']]) {
      const root=path.join(fixturePlugins,plugin);
      const start=requests.length;
      const result=await run(plugin==='gemini'?process.execPath:'sh',[path.join(root,'scripts',plugin==='gemini'?'hook.mjs':'hook.sh'),plugin==='gemini'?'BeforeTool':'PreToolUse'],{ROGUE_API_KEY:key,ROGUE_BASE_URL:base,ROGUE_PROTECTION_DIR:temp,PLUGIN_ROOT:root});
      assert.equal(result.code,0,result.err);
      assert.deepEqual(JSON.parse(result.out || '{}'),{});
      assert(requests.slice(start).every(call=>call.path.includes('/hooks/protection/')));
    }
    available=true;
  });
  await test('every shell bridge cancels open stdin when its persisted decision changes', async () => {
    available=true; paused=false; revision=30;
    for (const plugin of ['rogue','codex','cursor','copilot','antigravity','kiro']) {
      const slug=plugin==='rogue'?'claude':plugin;
      const root=path.join(fixturePlugins,plugin);
      const directory=path.join(temp,`${slug}-default-${createHash('sha256').update(`${base}\nprovision_${slug}`).digest('hex')}`);
      fs.mkdirSync(directory,{recursive:true});
      fs.writeFileSync(path.join(directory,'decision'),`1 30 0 0 0 0 ${Math.floor(Date.now()/1000)} 30 0 ${Math.floor(Date.now()/1000)}\n`);
      fs.writeFileSync(path.join(directory,'attempt'),String(Math.floor(Date.now()/1000)));
      const env={...process.env,ROGUE_API_KEY:`provision_${slug}`,ROGUE_BASE_URL:base,ROGUE_PROTECTION_DIR:temp,PLUGIN_ROOT:root,CLAUDE_PLUGIN_ROOT:root,CODEX_PLUGIN_ROOT:root,CURSOR_PLUGIN_ROOT:root,ROGUE_ACTOR_EMAIL:'qa@example.test'};
      const event=({cursor:'beforeShellExecution',copilot:'preToolUse',antigravity:'PreInvocation'})[plugin] || 'PreToolUse';
      const child=spawn('sh',[path.join(root,'scripts/hook.sh'),event,'kiro_cli'],{env,stdio:['pipe','pipe','pipe']});
      let output=''; child.stdout.on('data',b=>output+=b); child.stderr.resume();
      child.stdin.write('{"private":"must-not-upload"');
      const start=requests.length;
      const change=setTimeout(()=>fs.writeFileSync(path.join(directory,'decision'),`1 31 1 0 0 0 ${Math.floor(Date.now()/1000)} 31 0 ${Math.floor(Date.now()/1000)}\n`),400);
      const timeout=setTimeout(()=>child.kill(),3000);
      const code=await new Promise(resolve=>child.once('exit',resolve));
      clearTimeout(change);clearTimeout(timeout);
      assert.equal(code,0,plugin);
      assert.deepEqual(JSON.parse(output || '{}'),{},plugin);
      assert(!requests.slice(start).some(call=>!call.path.includes('/hooks/protection/') && call.body.includes('must-not-upload')),plugin);
      assert(!fs.readdirSync(directory).some(name=>name.startsWith('input.')),plugin);
    }
    paused=true; revision=31;
  });
  await test('shell lease persistence failure rejects entry and reports failed', async () => {
    const directory=path.join(temp,'lease-failure'); fs.mkdirSync(directory);
    const now=Math.floor(Date.now()/1000);
    fs.writeFileSync(path.join(directory,'decision'),`1 31 0 0 0 0 ${now} 31 0 ${now}\n`);
    const start=requests.length;
    const script=`. '${path.join(repo,'scripts/shared/protection.sh')}'; mkdir "$ROGUE_PROTECTION_STATE/active.$$"; if rogue_protection_enter; then exit 9; fi`;
    const result=await run('sh',['-c',script],{ROGUE_PROTECTION_STATE:directory,ROGUE_PROTECTION_BASE:base,ROGUE_API_KEY:'installation_test_key'},'');
    assert.equal(result.code,0,result.err);
    assert(requests.slice(start).some(call=>call.path.endsWith('/ack') && JSON.parse(call.body).status==='failed'),JSON.stringify({result,calls:requests.slice(start)}));
  });
  await test('PowerShell rejects malformed decisions and lease write failures', {skip:!process.env.ROGUE_TEST_PWSH}, async () => {
    const directory=path.join(temp,'ps-lease-failure'); fs.mkdirSync(directory);
    fs.writeFileSync(path.join(directory,'state.json'),JSON.stringify({decision:{protocolVersion:1,revision:31,serverTime:new Date().toISOString()},receivedAt:new Date().toISOString()}));
    const script=`. '${path.join(repo,'scripts/shared/protection.ps1')}'; $script:RPDirectory='${directory}'; $script:RPBase='${base}'; $script:RPKey='installation_test_key'; if (Test-RogueProtectionCurrent) {exit 8}; $decision=@{protocolVersion=1;revision=31;serverTime=[DateTimeOffset]::UtcNow.ToString('o');aidr=@{paused=$false;revision=31};aispm=@{paused=$false;revision=0}}; Write-RogueProtectionFile "$script:RPDirectory/state.json" (@{decision=$decision;receivedAt=[DateTimeOffset]::UtcNow.ToString('o')}|ConvertTo-Json -Depth 8); if (-not (Test-RogueProtectionCurrent)) { throw "valid active decision rejected: $(Get-Content -Raw \"$script:RPDirectory/state.json\")" }; $null=New-Item -ItemType Directory "$script:RPDirectory/active.$PID"; if (Enter-RogueProtection) {exit 9}`;
    const start=requests.length;
    const result=await run(process.env.ROGUE_TEST_PWSH,['-NoProfile','-Command',script],{},'');
    assert.equal(result.code,0,result.err);
    assert(requests.slice(start).some(call=>call.path.endsWith('/ack') && JSON.parse(call.body).status==='failed'),JSON.stringify({result,calls:requests.slice(start)}));
  });
  await test('failed discard offset writes cannot certify a new shipping revision', async () => {
    available=true; paused=false; revision=40;
    for (const slug of ['codex','gemini']) {
      const root=path.join(fixturePlugins,slug);
      const directory=path.join(temp,`${slug}-default-${createHash('sha256').update(`${base}\nprovision_${slug}`).digest('hex')}`);
      const ship=path.join(directory,'ship');fs.mkdirSync(ship,{recursive:true});
      const state=path.join(ship,`${slug}.state`);
      fs.rmSync(state,{recursive:true,force:true});fs.mkdirSync(state);
      fs.writeFileSync(path.join(directory,`${slug}.log`),'paused-canary\n');
      fs.writeFileSync(path.join(directory,'attempt'),'0');
      const env={ROGUE_API_KEY:`provision_${slug}`,ROGUE_BASE_URL:base,ROGUE_PROTECTION_DIR:temp,ROGUE_ACTOR_EMAIL:'qa@example.test',ROGUE_ACTOR_NAME:'QA',ROGUE_SHIP_MIN_INTERVAL:'0'};
      const args=[path.join(root,`scripts/ship-logs.${slug==='gemini'?'mjs':'sh'}`),root,slug,'1.0.0',slug==='codex'?'openai':'gemini'];
      const start=requests.length;
      await run(slug==='gemini'?process.execPath:'sh',args,env,'');
      fs.rmSync(state,{recursive:true});
      await run(slug==='gemini'?process.execPath:'sh',args,env,'');
      assert(!requests.slice(start).some(call=>call.path.endsWith('/logs')),slug);
      assert(fs.readFileSync(state,'utf8').includes('revision=40'),slug);
    }
    paused=true;revision=41;
    const directory=path.join(temp,`codex-default-${createHash('sha256').update(`${base}\nprovision_codex`).digest('hex')}`);
    fs.writeFileSync(path.join(directory,'attempt'),'0');
    const root=path.join(fixturePlugins,'codex');
    await run('sh',[path.join(root,'scripts/hook.sh'),'PreToolUse'],{ROGUE_API_KEY:'provision_codex',ROGUE_BASE_URL:base,ROGUE_PROTECTION_DIR:temp,PLUGIN_ROOT:root});
  });
  await test('legacy enrollment survives transport failure and retries a future timestamp', async () => {
    const {Protection}=await import(path.join(fixturePlugins,'gemini/scripts/protection.mjs'));
    for (const language of ['sh','node', ...(process.env.ROGUE_TEST_PWSH ? ['ps'] : [])]) {
      const isolated=path.join(temp,`legacy-${language}`); fs.mkdirSync(isolated);
      const env={ROGUE_API_KEY:'legacy_key',ROGUE_BASE_URL:base,ROGUE_PROTECTION_DIR:isolated};
      const invoke=async () => {
        if (language==='node') { assert.equal(await Protection.connect(env),undefined); return; }
        const script=language==='sh'
          ? `. '${path.join(repo,'scripts/shared/protection.sh')}'; rogue_protection_init codex openai '${path.join(repo,'plugins/codex/scripts')}'; [ -z "$ROGUE_PROTECTION_STATE" ]`
          : `. '${path.join(repo,'scripts/shared/protection.ps1')}'; $null=Initialize-RogueProtection -Key 'legacy_key' -BaseUrl '${base}' -Slug codex -Family openai; if ($script:RPDirectory) { exit 9 }`;
        const result=await run(language==='sh'?'sh':process.env.ROGUE_TEST_PWSH,language==='sh'?['-c',script]:['-NoProfile','-Command',script],env,'');
        assert.equal(result.code,0,`${language}: ${result.err}`);
      };
      legacy=true; available=true; await invoke();
      const directory=path.join(isolated,fs.readdirSync(isolated)[0]);
      fs.writeFileSync(path.join(directory,'enroll-attempt'),String(language==='node'?Date.now()+3600000:Math.floor(Date.now()/1000)+3600));
      disconnect=true; legacy=false;
      const start=requests.length; await invoke();
      assert(requests.slice(start).some(call=>call.path.endsWith('/enroll')),language);
      assert(fs.existsSync(path.join(directory,'legacy-server')),language);
      disconnect=false;
    }
  });
  await test('PowerShell checkpoint failure reports failed and suppresses applied ACK', {skip:!process.env.ROGUE_TEST_PWSH}, async () => {
    const directory=path.join(temp,'ps-checkpoint'); fs.mkdirSync(directory);
    fs.mkdirSync(path.join(directory,'broken.state'));
    fs.writeFileSync(path.join(directory,'state.json'),JSON.stringify({decision:{protocolVersion:1,revision:50,serverTime:new Date().toISOString(),aidr:{paused:false,revision:50},aispm:{paused:false,revision:0}},receivedAt:new Date().toISOString()}));
    const script=`$env:ROGUE_PS_LIB_ONLY='1'; . '${path.join(repo,'scripts/shared/ship-logs.ps1')}'; . '${path.join(repo,'scripts/shared/protection.ps1')}'; $script:stateDir='${directory}'; $script:RPDirectory='${directory}'; $script:RPBase='${base}'; $script:RPKey='checkpoint_test_key'; $script:RPRevision=50; try { Write-ShipState broken 10 head 10 log; exit 9 } catch {}; Send-RogueProtectionAck; if (-not $script:RPPersistenceFailed) { exit 8 }`;
    const start=requests.length;
    const result=await run(process.env.ROGUE_TEST_PWSH,['-NoProfile','-Command',script],{},'');
    assert.equal(result.code,0,result.err);
    const acks=requests.slice(start).filter(call=>call.path.endsWith('/ack') && call.key==='checkpoint_test_key').map(call=>JSON.parse(call.body));
    assert(acks.some(ack=>ack.status==='failed')); assert(!acks.some(ack=>ack.status==='applied'));
  });
  await test('an unavailable enrollment never enables unscoped activity on retry', async () => {
    available=false;
    for (const slug of ['codex','gemini']) {
      const root=path.join(fixturePlugins,slug);
      const env={ROGUE_API_KEY:`unavailable_${slug}`,ROGUE_BASE_URL:base,ROGUE_PROTECTION_DIR:temp,PLUGIN_ROOT:root,CODEX_PLUGIN_ROOT:root};
      const start=requests.length;
      for (let attempt=0;attempt<2;attempt++) {
        const result=await run(slug==='gemini'?process.execPath:'sh',[path.join(root,`scripts/hook.${slug==='gemini'?'mjs':'sh'}`),slug==='gemini'?'BeforeTool':'PreToolUse'],env);
        assert.equal(result.code,0,result.err);assert.deepEqual(JSON.parse(result.out || '{}'),{});
      }
      assert(requests.slice(start).every(call=>call.path.includes('/hooks/protection/')));
    }
  });
  await test('a new shell invocation honors persisted pause while offline',async()=>{
    paused=true; revision++;
    const root=path.join(fixturePlugins,'codex');
    const env={ROGUE_API_KEY:'provision_codex',ROGUE_BASE_URL:base,ROGUE_PROTECTION_DIR:temp,PLUGIN_ROOT:root,CODEX_PLUGIN_ROOT:root,ROGUE_LOG_DIR:temp};
    const directory=path.join(temp,fs.readdirSync(temp).find(name=>name.startsWith('codex-default-')));
    fs.writeFileSync(path.join(directory,'attempt'),'0');
    const online=await run('bash',[path.join(root,'scripts/hook.sh'),'PreToolUse'],env);
    assert.equal(online.code,0); assert.deepEqual(JSON.parse(online.out),{});
    available=false;
    const result=await run('bash',[path.join(root,'scripts/hook.sh'),'PreToolUse'],env);
    assert.equal(result.code,0); assert.deepEqual(JSON.parse(result.out),{});
  });
} finally {
  for (const dir of fs.readdirSync(temp)) {
    for (const name of ['poll.pid','poll.lock/pid']) {
      try { const pid=Number(fs.readFileSync(path.join(temp,dir,name),'utf8')); if (pid>0) process.kill(pid); } catch {}
    }
  }
  server.closeAllConnections(); await new Promise(resolve=>server.close(resolve));
  fs.rmSync(temp,{recursive:true,force:true});
}
