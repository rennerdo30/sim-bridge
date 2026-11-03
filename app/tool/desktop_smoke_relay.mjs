#!/usr/bin/env node
// Disposable fixture only: no physical SIM, relay persistence, APNs, or
// credential files. Every event/command body belongs to this synthetic bridge.
import { spawn } from 'node:child_process';
import { createCipheriv, createDecipheriv, createHmac, createHash, generateKeyPairSync, randomBytes, sign } from 'node:crypto';
import { createServer } from 'node:net';
import { createServer as createControlServer } from 'node:http';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';

const port = Number(process.env.SIM_BRIDGE_SMOKE_PORT || 18798);
if (!Number.isInteger(port) || port < 1024 || port > 65535 || port === 8787) {
  console.error('Use a disposable port from 1024–65535; live port 8787 is forbidden.');
  process.exit(1);
}
const controlPort = port + 1;
if (controlPort > 65535 || controlPort === 8787) throw new Error('Unsafe fixture control port');
const signing = generateKeyPairSync('ed25519');
const publicKey = signing.publicKey.export({ format: 'jwk' }).x;
let gateway, gatewayId, policyJson, streamAbort, control;
let policyWork = Promise.resolve();
const serverRoot = fileURLToPath(new URL('../../server/', import.meta.url));
const base = `http://127.0.0.1:${port}`;
const key = Buffer.alloc(32);
const derive = label => createHmac('sha256', key).update(label).digest('base64url');
const bridgeId = derive('simbridge/bridge-id/v1');
const inviteToken = derive('simbridge/invite-auth/v1');
const ownerKey = randomBytes(32).toString('base64url');
const requests = new AbortController();
let relay;
let childExited;
let childEnded = false;
let presence;
let readline;
let stopping = false;

function stop() {
  stopping = true;
  requests.abort();
  streamAbort?.abort();
  readline?.close();
  process.stdin.destroy();
}
process.once('SIGINT', stop);
process.once('SIGTERM', stop);

async function checkPortAvailable() {
  const probe = createServer();
  await new Promise((resolve, reject) => {
    probe.once('error', () => reject(new Error(`Scratch port ${port} is unavailable; no existing relay was changed.`)));
    probe.listen(port, '0.0.0.0', resolve);
  });
  await new Promise((resolve, reject) => probe.close(error => error ? reject(error) : resolve()));
}

async function request(path, { body, token, owner = false } = {}) {
  const response = await fetch(base + path, {
    method: body === undefined ? 'GET' : 'POST',
    headers: {
      'content-type': 'application/json',
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(owner ? { 'x-relay-key': ownerKey } : {}),
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    signal: AbortSignal.any([requests.signal, AbortSignal.timeout(10000)]),
  });
  if (!response.ok) { const data = await response.json(); throw new Error(`Scratch relay status ${response.status}: ${data.code || 'request failed'}`); }
  return response.json();
}

function seal(clear) {
  const nonce = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', key, nonce);
  const ciphertext = Buffer.concat([cipher.update(JSON.stringify(clear), 'utf8'), cipher.final()]);
  // Dart's base64UrlEncode preserves padding. Match the production envelope.
  const encode = bytes => bytes.toString('base64url').padEnd(Math.ceil(bytes.length / 3) * 4, '=');
  return { v: 1, ciphertext: encode(ciphertext), nonce: encode(nonce), mac: encode(cipher.getAuthTag()) };
}

function open(envelope) {
  const decipher = createDecipheriv('aes-256-gcm', key, Buffer.from(envelope.nonce, 'base64url'));
  decipher.setAuthTag(Buffer.from(envelope.mac, 'base64url'));
  return JSON.parse(Buffer.concat([
    decipher.update(Buffer.from(envelope.ciphertext, 'base64url')), decipher.final(),
  ]).toString());
}

try {
  await checkPortAvailable();
  if (stopping) throw new Error('Fixture stopped');
  // Do not inherit operator TLS, APNs, access-key, database, or logging settings.
  const environment = Object.fromEntries(Object.entries(process.env).filter(([name]) => !name.startsWith('SIM_BRIDGE_')));
  async function launchRelay() {
    childEnded = false;
    relay = spawn(process.execPath, ['src/server.mjs'], {
      cwd: serverRoot, stdio: 'ignore', env: {
        ...environment, PORT: String(port), SIM_BRIDGE_ACCESS_KEY: ownerKey,
        SIM_BRIDGE_RELAY_NAME: 'Desktop smoke test (temporary)',
      },
    });
    childExited = new Promise(resolve => {
      relay.once('exit', () => { childEnded = true; resolve(); });
      relay.once('error', () => { childEnded = true; resolve(); });
    });
    let ready = false;
    for (let attempt = 0; attempt < 100 && !stopping; attempt++) {
      if (childEnded) throw new Error('Scratch relay exited before startup; check dependencies.');
      try { await request('/health'); ready = true; break; } catch { await delay(50); }
    }
    if (!ready || childEnded || stopping) throw new Error('Scratch relay did not become ready.');
  }
  async function proof(operation, payloadJson, certificate) {
    const binding = certificate || publicKey;
    const challenge = await request('/v1/auth/challenge', { body: {
      ...(certificate ? { certificate } : { devicePublicKey: publicKey }), operation, payloadJson,
    } });
    const fields = JSON.parse(challenge.signingPayload);
    const digest = value => createHash('sha256').update(value).digest('hex');
    if (fields.length !== 7 || fields[0] !== 'simbridge/pop/v1' || fields[1] !== challenge.bootId ||
        fields[2] !== challenge.challengeId || fields[3] !== challenge.nonce || fields[4] !== operation ||
        fields[5] !== digest(binding) || fields[6] !== digest(payloadJson)) throw new Error('Unexpected scratch proof');
    return { ...(certificate ? { certificate } : { devicePublicKey: publicKey }),
      challengeId: challenge.challengeId, payloadJson,
      signature: sign(null, Buffer.from(challenge.signingPayload), signing.privateKey).toString('base64url') };
  }
  async function commitPolicy() {
    const pending = await request('/v1/auth/policy', { token: gateway.token });
    if (!pending.proposalId) return;
    // This variable models the gateway's ledger, outside the restarted relay.
    // Real Android code writes protected device storage before signing the commit.
    policyJson = pending.policyJson;
    const result = await request('/v1/auth/policy/commit', { body: await proof('policy_commit',
      JSON.stringify({ proposalId: pending.proposalId, policyJson }), gateway.certificate) });
    if (result.erased) throw new Error('Scratch authority erased');
  }
  await launchRelay();
  gateway = await request('/v1/bridges', { owner: true, body: await proof('create', JSON.stringify({
    bridgeId, inviteToken, devicePublicKey: publicKey, authority: true, deviceName: 'Desktop test gateway',
    capabilities: { smsGateway: true, calls: true, callControl: true, multiSim: true },
  })) });
  gatewayId = gateway.device.id;
  policyJson = gateway.policyJson;
  await commitPolicy();
  async function upload(event) {
    await request('/v1/messages', { token: gateway.token, body: {
      envelope: seal({ ...event, v: 2, bridgeId, senderDeviceId: gatewayId, gatewayDeviceId: gatewayId }),
      uploadId: randomBytes(18).toString('base64url'),
    } });
  }
  async function incomingSms() {
    await upload({ kind: 'sms', eventId: randomBytes(18).toString('base64url'), direction: 'incoming',
      address: '+15550102001', body: 'Desktop smoke message. Verification code:246810',
      occurredAt: new Date().toISOString(), subscriptionId: 1 });
  }
  const publishState = () => upload({ kind: 'gateway_state', simProfiles: [{ subscriptionId: 1, slotIndex: 0,
    displayName: 'Test SIM', carrierName: 'Test carrier', phoneNumber: '+15550102000' }] });
  await publishState();
  await incomingSms();
  async function attachEvents() {
    streamAbort = new AbortController();
    const stream = await fetch(base + '/v1/events', {
      headers: { authorization: `Bearer ${gateway.token}`, 'x-device-certificate': gateway.certificate },
      signal: AbortSignal.any([requests.signal, streamAbort.signal]),
    });
    if (!stream.ok) throw new Error(`Scratch event stream status ${stream.status}`);
    presence = (async () => {
      const decoder = new TextDecoder();
      let pending = '';
      for await (const chunk of stream.body) {
        if (stopping) break;
        pending += decoder.decode(chunk, { stream: true });
        let boundary;
        while ((boundary = pending.indexOf('\n\n')) !== -1) {
          const frame = pending.slice(0, boundary);
          pending = pending.slice(boundary + 2);
          const data = frame.split('\n').filter(line => line.startsWith('data:')).map(line => line.slice(5).trim()).join('\n');
          if (!data) continue;
          const type = JSON.parse(data).type;
          if (type === 'policy' || type === 'ready') {
            policyWork = policyWork.then(commitPolicy).catch(() => { if (!stopping) console.error('Scratch policy confirmation failed.'); });
          }
          if (type === 'devices') {
            void policyWork.then(publishState).catch(() => {});
          }
        }
      }
    })().catch(() => {}); // Expected when deliberately restarting this fixture.
  }
  await attachEvents();
  async function restartRelay() {
    await policyWork;
    streamAbort.abort();
    await presence;
    relay.kill('SIGTERM');
    await childExited;
    await launchRelay();
    const restored = await request('/v1/auth/bootstrap', { body: await proof('bootstrap', policyJson, gateway.certificate) });
    if (restored.device.id !== gatewayId || restored.bridge.id !== bridgeId) throw new Error('Scratch recovery changed identity');
    gateway = { ...restored, certificate: gateway.certificate };
    await attachEvents();
    await publishState();
    await incomingSms();
    return { bridgeId, gatewayId, bootId: restored.bootId };
  }
  // Local fixture control has no owner credential or production endpoint. It
  // only restarts the child owned by this process, never an existing service.
  let restarting = false;
  control = createControlServer(async (req, res) => {
    if (req.method !== 'POST' || !['/restart', '/seed'].includes(req.url) || req.headers.origin || req.headers['x-smoke-fixture'] !== 'restart-owned-child') {
      res.writeHead(404).end(); return;
    }
    if (restarting) { res.writeHead(409).end(); return; }
    if (req.url === '/seed') {
      try { await incomingSms(); res.setHeader('content-type', 'application/json'); res.end(JSON.stringify({ seeded: true })); }
      catch { res.writeHead(500).end(); }
      return;
    }
    restarting = true;
    try { res.setHeader('content-type', 'application/json'); res.end(JSON.stringify(await restartRelay())); }
    catch { res.writeHead(500).end(); }
    finally { restarting = false; }
  });
  await new Promise((resolve, reject) => {
    control.once('error', reject); control.listen(controlPort, '127.0.0.1', resolve);
  });
  console.log(`READY: disposable relay at ${base}; encrypted synthetic SIM state and SMS published.`);
  console.log('Fixture recovery code: 52 zero digits. Commands: sms, roster, commands, quit. Ctrl-C also cleans up.');
  readline = createInterface({ input: process.stdin });
  for await (const line of readline) {
    if (stopping || line.trim() === 'quit') break;
    try {
      switch (line.trim()) {
        case 'sms': await incomingSms(); console.log('Published another encrypted synthetic SMS.'); break;
        case 'roster': {
          const data = await request('/v1/devices', { token: gateway.token });
          console.log(JSON.stringify(data.devices.map(({ name, capabilities }) => ({ name, capabilities }))));
          break;
        }
        case 'commands': {
          const data = await request('/v1/commands', { token: gateway.token });
          console.log(JSON.stringify(data.commands.map(record => {
            const clear = open(record.envelope);
            return { type: clear.type, protocol: clear.v, targetBound: clear.targetDeviceId === gatewayId,
              bridgeBound: clear.bridgeId === bridgeId, bodyMatches: clear.body === 'Desktop outgoing smoke',
              addressMatches: clear.address === '+15550102002' };
          })));
          break;
        }
      }
    } catch (error) {
      if (!stopping) console.error(`SMOKE ERROR: ${error.message}`);
    }
  }
} catch (error) {
  if (!stopping) { console.error(`SMOKE ERROR: ${error.message}`); process.exitCode = 1; }
} finally {
  stop();
  await new Promise(resolve => control ? control.close(resolve) : resolve());
  await presence;
  if (relay && !childEnded) {
    relay.kill('SIGTERM');
    const force = setTimeout(() => relay.kill('SIGKILL'), 6000);
    force.unref();
    await childExited;
    clearTimeout(force);
  }
  process.removeListener('SIGINT', stop);
  process.removeListener('SIGTERM', stop);
  console.log('Scratch relay stopped; its volatile state was discarded.');
}
