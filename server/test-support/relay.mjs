import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { request as httpRequest } from 'node:http';
import { setTimeout as delay } from 'node:timers/promises';
import { newIdentity, enroll, commitPolicy } from './identities.mjs';
export const ownerKey = 'isolated-memory-relay-test-owner';
export const envelope = { v: 1, ciphertext: 'AAAA', nonce: 'AAAAAAAAAAAAAAAA', mac: 'AAAAAAAAAAAAAAAAAAAAAA==' };
async function policyWorker(relay, gateway) {
  const events = [], errors = []; let response, stopped = false, busy = false, dirty = false;
  const coordinate = async () => {
    dirty = true; if (busy || stopped) return; busy = true;
    try { while (dirty && !stopped) {
      dirty = false;
      const result = await relay.request('/v1/auth/policy', { token: gateway.token, certificate: gateway.certificate });
      if (!result.ok) throw new Error(`Policy fetch rejected (${result.status})`);
      const proposal = await result.json();
      if (proposal.proposalId) { const committed = await commitPolicy(relay.request, gateway, proposal); if (!committed.ok) throw new Error(`Policy commit rejected (${committed.status})`); }
    } } catch (error) { if (!stopped) errors.push(error); } finally { busy = false; }
  };
  const request = httpRequest(relay.base + '/v1/events', { headers: { authorization: `Bearer ${gateway.token}`, 'x-device-certificate': gateway.certificate } });
  await new Promise((resolve, reject) => {
    request.once('error', reject);
    request.once('response', res => {
      response = res;
      if (res.statusCode !== 200) { res.resume(); reject(new Error(`Authority stream rejected (${res.statusCode})`)); return; }
      let pending = ''; res.setEncoding('utf8');
      res.on('data', chunk => { pending += chunk; let at;
        while ((at = pending.indexOf('\n\n')) >= 0) {
          const frame = pending.slice(0, at); pending = pending.slice(at + 2);
          if (!frame.startsWith('data: ')) continue;
          const event = JSON.parse(frame.slice(6)); events.push(event);
          if (event.type === 'ready' || event.type === 'policy') void coordinate();
        }
      });
      res.on('error', error => { if (!stopped) errors.push(error); }); resolve();
    }); request.end();
  });
  const closed = new Promise(resolve => response.once('end', resolve));
  const wait = async type => { for (let i = 0; i < 200; i++) { if (errors.length) throw errors[0]; if (events.some(event => event.type === type)) return; await delay(10); } throw new Error(`No authority ${type} signal`); };
  await wait('ready');
  return { events, errors, wait, closed, stop() { stopped = true; response.destroy(); request.destroy(); } };
}
/** RELAY_TEST_TARGET=worker runs every relay test against the Cloudflare Worker in local workerd. */
export const workerTarget = process.env.RELAY_TEST_TARGET === 'worker';

async function freePort() {
  const probe = createServer(); await new Promise((resolve, reject) => { probe.once('error', reject); probe.listen(0, '127.0.0.1', resolve); });
  const port = probe.address().port; await new Promise(resolve => probe.close(resolve));
  return port;
}

async function spawnWorker(port, settings, environment) {
  const state = await mkdtemp(join(tmpdir(), 'sim-bridge-worker-'));
  const vars = Object.entries(settings).flatMap(([name, value]) => ['--var', `${name}:${value}`]);
  const child = spawn(process.execPath, [fileURLToPath(new URL('../node_modules/wrangler/bin/wrangler.js', import.meta.url)), 'dev',
    '--ip', '127.0.0.1', '--port', String(port), '--inspector-port', String(await freePort()), '--persist-to', state,
    '--show-interactive-dev-session=false', '--env-file', fileURLToPath(new URL('./empty.env', import.meta.url)), ...vars], {
    cwd: new URL('..', import.meta.url), env: { ...environment, WRANGLER_SEND_METRICS: 'false', CI: '1',
      // Never load the operator's local .env/.dev.vars into an isolated test relay.
      CLOUDFLARE_LOAD_DEV_VARS_FROM_DOT_ENV: 'false', CLOUDFLARE_INCLUDE_PROCESS_ENV: 'false' }, stdio: ['ignore', 'pipe', 'pipe'], detached: true,
  });
  child.cleanup = () => rm(state, { recursive: true, force: true });
  return child;
}

export async function startRelay(extra = {}) {
  const probe = createServer(); await new Promise((resolve, reject) => { probe.once('error', reject); probe.listen(0, '127.0.0.1', resolve); });
  const port = probe.address().port; await new Promise(resolve => probe.close(resolve));
  if (port === 8787) throw new Error('Live relay port is forbidden.');
  const environment = Object.fromEntries(Object.entries(process.env).filter(([name]) => !name.startsWith('SIM_BRIDGE_')));
  const settings = { ...extra, SIM_BRIDGE_ACCESS_KEY: ownerKey };
  const child = workerTarget
    ? await spawnWorker(port, settings, environment)
    : spawn(process.execPath, ['src/server.mjs'], { cwd: new URL('..', import.meta.url), env: { ...environment, ...(process.env.RELAY_TEST_SQL_ENGINE ? { SIM_BRIDGE_SQL_ENGINE: process.env.RELAY_TEST_SQL_ENGINE } : {}), ...settings, PORT: String(port) }, stdio: ['ignore', 'pipe', 'pipe'] });
  let output = ''; const gateways = new Map(), certificates = new Map();
  child.stdout.on('data', chunk => { output += chunk; }); child.stderr.on('data', chunk => { output += chunk; });
  const base = `http://127.0.0.1:${port}`;
  const stop = async () => {
    for (const gateway of gateways.values()) gateway.worker?.stop();
    if (child.exitCode !== null) return;
    const ended = new Promise(resolve => child.once('exit', resolve));
    // wrangler runs workerd as a child; signal the whole process group.
    if (workerTarget) { try { process.kill(-child.pid, 'SIGTERM'); } catch { child.kill('SIGTERM'); } } else child.kill('SIGTERM');
    await ended;
    if (child.cleanup) await child.cleanup();
  };
  let ready = false;
  const marker = workerTarget ? 'Ready on' : 'Relay listening';
  for (let i = 0; i < (workerTarget ? 600 : 100); i++) { if (child.exitCode !== null) break; try { if (output.includes(marker) && (await fetch(base + '/health', { signal: AbortSignal.timeout(workerTarget ? 5000 : 500) })).ok) { ready = true; break; } } catch {} await delay(workerTarget ? 50 : 20); }
  // Development-server banners are not relay output.
  if (workerTarget) output = '';
  if (!ready) { await stop(); throw new Error('Isolated relay did not start.'); }
  const request = (path, { method = 'GET', token, certificate = certificates.get(token), owner = false, body } = {}) => fetch(base + path, {
    method, headers: { ...(owner ? { 'x-relay-key': ownerKey } : {}), ...(token ? { authorization: `Bearer ${token}` } : {}), ...(certificate ? { 'x-device-certificate': certificate } : {}), 'content-type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }), signal: AbortSignal.timeout(10000),
  });
  const relay = { base, port, request, stop, gateways, get output() { return output; } };
  const createResponse = async payload => {
    const identity = newIdentity(); const response = await enroll(request, identity, 'create', payload, { owner: true }); if (response.status !== 201) return response;
    const gateway = { ...await response.json(), identity }; certificates.set(gateway.token, gateway.certificate);
    const committed = await commitPolicy(request, gateway, gateway); if (!committed.ok) throw new Error(`Initial gateway policy rejected (${committed.status})`);
    gateways.set(payload.bridgeId, gateway); gateway.worker = await policyWorker(relay, gateway);
    const { identity: _identity, worker: _worker, ...data } = gateway;
    return new Response(JSON.stringify(data), { status: 201, headers: { 'content-type': 'application/json' } });
  };
  const joinResponse = async payload => {
    const response = await enroll(request, newIdentity(), 'join', payload); if (response.status !== 201) return response;
    const data = await response.json(); certificates.set(data.token, data.certificate);
    return new Response(JSON.stringify(data), { status: 201, headers: { 'content-type': 'application/json' } });
  };
  const create = async (bridgeId = 'isolated-bridge', gateway = true) => {
    const response = await createResponse({ bridgeId, inviteToken: 'synthetic-invite-verifier', deviceName: 'Synthetic gateway', capabilities: { smsGateway: gateway } });
    if (response.status !== 201) throw new Error(`Synthetic bridge creation failed (${response.status})`);
    const data = await response.json(), authority = gateways.get(bridgeId);
    return { ...data, identity: authority.identity, worker: authority.worker, get policyJson() { return authority.policyJson; } };
  };
  const join = async (bridgeId = 'isolated-bridge', gateway = false) => {
    const response = await joinResponse({ bridgeId, inviteToken: 'synthetic-invite-verifier', deviceName: 'Synthetic client', capabilities: { smsGateway: gateway } });
    if (response.status !== 201) throw new Error(`Synthetic enrollment failed (${response.status})`); return response.json();
  };
  return Object.assign(relay, { createResponse, joinResponse, create, join });
}
