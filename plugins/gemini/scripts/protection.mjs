import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';

const read = (file) => { try { return fs.readFileSync(file, 'utf8'); } catch { return ''; } };
const alive = (pid) => { try { process.kill(Number(pid), 0); return Number(pid) > 0; } catch { return false; } };
const write = (file, value) => {
  const temp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(temp, value, { mode: 0o600 });
  fs.renameSync(temp, file);
};
const validDecision = (decision) => decision?.protocolVersion === 1
  && Number.isSafeInteger(decision.revision) && decision.revision >= 0
  && typeof decision.serverTime === 'string' && Number.isFinite(Date.parse(decision.serverTime))
  && ['aidr', 'aispm'].every(cap => {
    const value = decision[cap];
    return typeof value?.paused === 'boolean'
      && Number.isSafeInteger(value.revision) && value.revision >= 0
      && (value.expiresAt === null || (typeof value.expiresAt === 'string' && Number.isFinite(Date.parse(value.expiresAt))));
  });
export class Protection {
  constructor(directory, base, key) { this.directory=directory; this.base=base; this.key=key; this.revision=undefined; }
  file(name) { return path.join(this.directory, name); }
  state() {
    try {
      const saved = JSON.parse(read(this.file('state.json')));
      if (!validDecision(saved?.decision) || !Number.isFinite(saved.receivedAt) || saved.receivedAt < 0) return undefined;
      const now = Date.parse(saved.decision.serverTime) + Date.now() - saved.receivedAt;
      for (const cap of ['aidr','aispm']) {
        if (saved.decision[cap].expiresAt && Date.parse(saved.decision[cap].expiresAt) <= now) saved.decision[cap].paused=false;
      }
      return saved.decision;
    } catch { return undefined; }
  }
  current() {
    const state=this.state();
    if (this.persistenceFailed || fs.existsSync(this.file('persistence-failed'))) return false;
    return !!state && (!state.aidr.paused && (this.revision === undefined || this.revision === state.aidr.revision));
  }
  enter() {
    if (!this.current()) return false;
    write(this.file(`active.${process.pid}`), String(this.revision ?? 0));
    process.once('exit', () => { try { fs.unlinkSync(this.file(`active.${process.pid}`)); } catch {} });
    return this.current();
  }
  async request(route, body, installationKey) {
    const response=await fetch(`${this.base}/api/v1/hooks/protection/${route}`, {
      method: body === undefined ? 'GET' : 'POST', headers: {'x-rogue-api-key': this.key, 'content-type':'application/json', ...(installationKey ? {'x-rogue-installation-key':installationKey} : {})},
      body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(5000),
    });
    if (!response.ok) throw Object.assign(new Error('Protection request failed'), { status:response.status });
    return response.json();
  }
  async ack() {
    const state=this.state();
    if (!state || this.persistenceFailed || fs.existsSync(this.file('persistence-failed'))) return;
    for (const name of fs.readdirSync(this.directory).filter(name => name.startsWith('active.'))) {
      if (alive(name.slice(7))) return;
      fs.rmSync(this.file(name), { force:true });
    }
    const id=`${state.revision}:${state.aidr.paused}:${state.aispm.paused}`;
    if (read(this.file('ack')) === id) return;
    await this.request('ack', { protocolVersion:1, revision:state.revision, status:'applied', aidrPaused:state.aidr.paused, aispmPaused:state.aispm.paused });
    write(this.file('ack'), id);
  }
  async refresh() {
    const lock=this.file('refresh.lock');
    try { fs.writeFileSync(lock, String(process.pid), { flag:'wx', mode:0o600 }); }
    catch { if (!alive(read(lock))) fs.rmSync(lock, {force:true}); return; }
    try {
      write(this.file('attempt'), String(Date.now()));
      const state=await this.request('state');
      const previous=this.state();
      if (!validDecision(state)) return;
      if (!previous || state.revision >= previous.revision) {
        try {
          write(this.file('state.json'), JSON.stringify({ decision:state, receivedAt:Date.now() }));
          fs.rmSync(this.file('persistence-failed'),{force:true}); this.persistenceFailed=false;
        } catch {
          this.persistenceFailed=true;
          try { write(this.file('persistence-failed'),'1'); } catch {}
          try { await this.request('ack',{protocolVersion:1,revision:state.revision,status:'failed',aidrPaused:state.aidr.paused,aispmPaused:state.aispm.paused,error:'state_persistence_failed'}); } catch {}
        }
      }
    } catch {} finally { fs.rmSync(lock, {force:true}); }
    try { await this.ack(); } catch {}
  }
  static async connect(env, slug='gemini', family='gemini') {
    if (!env.ROGUE_API_KEY) return undefined;
    const base=(env.ROGUE_BASE_URL || 'https://api.rogue.security').replace(/\/+$/, '');
    const hash=createHash('sha256').update(`${base}\n${env.ROGUE_API_KEY}`).digest('hex');
    const directory=path.join(env.ROGUE_PROTECTION_DIR || path.join(os.homedir(), '.rogue/protection'), `${slug}-default-${hash}`);
    const client=new Protection(directory, base, env.ROGUE_API_KEY);
    try {
      fs.mkdirSync(directory, {recursive:true, mode:0o700});
      const linked=read(client.file('installation-directory'));
      if (path.dirname(linked) === path.dirname(directory) && path.basename(linked).startsWith(`${slug}-default-`) && read(path.join(linked,'base')) === base) client.directory=linked;
      let key=read(client.file('credential'));
      try { write(client.file('base'), base); } catch {}
      if (!key) {
        const root=path.dirname(directory);
        for (const name of fs.readdirSync(root).filter(name=>name.startsWith(`${slug}-default-`))) {
          const previous=path.join(root,name);
          if (previous === directory || read(path.join(previous,'base')) !== base) continue;
          const oldKey=read(path.join(previous,'credential'));
          if (!oldKey) continue;
          try {
            const restored=await client.request('enroll',{type:'coding_agent',name:slug,family,host:os.hostname(),version:env.ROGUE_INSTALL_VERSION || 'unknown'},oldKey);
            if (restored.apiKey !== oldKey) continue;
            key=oldKey; write(client.file('installation-directory'),previous);
            client.directory=previous;
            break;
          } catch (error) { if (error.status !== 403 && error.status !== 401) return client; }
        }
      }
      if (!key) {
        const elapsed=Date.now()-Number(read(client.file('enroll-attempt')));
        if (elapsed >= 0 && elapsed < 60000) return read(client.file('legacy-server')) ? undefined : client;
        const lock=client.file('enroll.lock');
        try { fs.writeFileSync(lock, String(process.pid), {flag:'wx', mode:0o600}); }
        catch { if (!alive(read(lock))) fs.rmSync(lock, {force:true}); return client; }
        try {
          write(client.file('enroll-attempt'), String(Date.now()));
          let enrollmentNonce=read(client.file('enrollment-nonce'));
          if (!enrollmentNonce) { enrollmentNonce=randomUUID(); write(client.file('enrollment-nonce'),enrollmentNonce); }
          const enrolled=await client.request('enroll', {enrollmentNonce,type:'coding_agent', name:slug, family, host:os.hostname(), version:env.ROGUE_INSTALL_VERSION || 'unknown'});
          fs.rmSync(client.file('legacy-server'),{force:true});
          key=enrolled.alreadyEnrolled ? env.ROGUE_API_KEY : enrolled.apiKey;
          if (typeof key !== 'string' || !key) return client;
          write(client.file('credential'), key);
        } finally { fs.rmSync(lock, {force:true}); }
      }
      client.key=key;
      try { write(client.file('used'), String(Date.now())); } catch {}
      if (Date.now()-Number(read(client.file('attempt'))) >= 15000) await client.refresh();
      client.revision=client.state()?.aidr.revision;
      const pollLock=client.file('poll-start.lock');
      let ownsPollLock=false;
      try { fs.writeFileSync(pollLock,String(process.pid),{flag:'wx',mode:0o600}); ownsPollLock=true; } catch { if (!alive(read(pollLock))) fs.rmSync(pollLock,{force:true}); }
      try { if (ownsPollLock && !alive(read(client.file('poll.pid')))) {
        const child=spawn(process.execPath, [fileURLToPath(import.meta.url), '--poll', directory, base], {detached:true, stdio:'ignore'});
        write(client.file('poll.pid'), String(child.pid));
        child.unref();
      } } finally { if (ownsPollLock) fs.rmSync(pollLock,{force:true}); }
      return client;
    } catch (error) {
      const key=read(client.file('credential'));
      if (!key) {
        if (error.status === 404) { try { write(client.file('legacy-server'),'1'); } catch {} return undefined; }
        if (error.status) fs.rmSync(client.file('legacy-server'),{force:true});
        return read(client.file('legacy-server')) ? undefined : client;
      }
      client.key=key; client.revision=client.state()?.aidr.revision; return client;
    }
  }
}
if (process.argv[2] === '--poll') {
  const client=new Protection(process.argv[3], process.argv[4], read(path.join(process.argv[3], 'credential')));
  while (Date.now()-Number(read(client.file('used'))) < 90000 || fs.readdirSync(client.directory).some(name=>name.startsWith('active.') && alive(name.slice(7)))) { await client.refresh(); await sleep(15000); }
}
