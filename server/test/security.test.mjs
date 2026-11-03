import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { connect } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { startRelay, envelope as validEnvelope, ownerKey as accessKey, workerTarget } from '../test-support/relay.mjs';
import { enroll, newIdentity } from '../test-support/identities.mjs';

let base, port, fixture;
const createBridge = body => fixture.createResponse(body);
const joinBridge = body => fixture.joinResponse(body);
async function withRelay(run, extraEnv = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'sim-bridge-security-'));
  const database = join(directory, 'relay.sqlite');
  const settings = { ...extraEnv, SIM_BRIDGE_DATABASE: database, SIM_BRIDGE_LOG_FILE: join(directory, 'relay.log') };
  try {
    fixture = await startRelay(settings); base = fixture.base; port = fixture.port;
    await run({ database, directory, restart: async () => {
      await fixture.stop(); fixture = await startRelay(settings); base = fixture.base; port = fixture.port;
    } });
  } finally { await fixture?.stop(); await rm(directory, { recursive: true, force: true }); }
}

test('a client cannot promote itself to SIM gateway or publish messages', async () => {
  await withRelay(async () => {
    assert.equal((await createBridge({
      bridgeId: 'escalation-bridge',
      inviteToken: 'derived-verifier',
      deviceName: 'Gateway',
      capabilities: { smsGateway: true },
    })).status, 201);

    const joined = await joinBridge({
      bridgeId: 'escalation-bridge',
      inviteToken: 'derived-verifier',
      deviceName: 'Client',
      capabilities: { smsGateway: false },
    });
    assert.equal(joined.status, 201);
    const { token } = await joined.json();

    const promoted = await fetch(`${base}/v1/devices/me`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` },
      body: JSON.stringify({ capabilities: { smsGateway: true } }),
    });
    assert.equal(promoted.status, 200);
    assert.equal((await promoted.json()).device.capabilities.smsGateway, false);

    const forged = await fetch(`${base}/v1/messages`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` },
      body: JSON.stringify({ envelope: validEnvelope }),
    });
    assert.equal(forged.status, 403);
  });
});

test('RAM verifier and credential references retain hashed security invariants', async () => {
  await withRelay(async () => {
    await createBridge({ bridgeId: 'hashed-bridge', inviteToken: 'secret-verifier-value', capabilities: { smsGateway: true } });
    const response = await fetch(`${base}/v1/admin/debug/self-test`, { method: 'POST', headers: { 'x-relay-key': accessKey } });
    const result = await response.json();
    assert.equal(result.ok, true);
    assert.equal(result.checks.verifiersHashed, true);
    assert.equal(result.checks.tokenReferences, true);
    assert.equal(result.checks.databaseParity, true);
  });
});

test('a bridge cannot be created with a guessable enrollment verifier', async () => {
  await withRelay(async () => {
    for (const inviteToken of ['', 'short', undefined]) {
      const response = await createBridge({
        bridgeId: 'weak-verifier-bridge',
        inviteToken,
        deviceName: 'Gateway',
        capabilities: { smsGateway: true },
      });
      assert.equal(response.status, 400, `verifier ${JSON.stringify(inviteToken)} must be refused`);
    }
    // Otherwise sha256('') would match a join request that omits the field.
    const enrolled = await joinBridge({ bridgeId: 'weak-verifier-bridge' });
    assert.equal(enrolled.status, 409, 'absent authority must wait rather than create membership');
  });
});



// Cloudflare routes only hostnames bound to the Worker, so the edge enforces this.
test('requests with a foreign Host header are refused (DNS rebinding)', { skip: workerTarget }, async () => {
  await withRelay(async () => {
    // `fetch` refuses to send a custom Host header, so speak HTTP directly.
    const statusFor = host => new Promise((resolve, reject) => {
      const socket = connect(port, '127.0.0.1', () => {
        socket.write(`GET /health HTTP/1.1\r\nHost: ${host}\r\nConnection: close\r\n\r\n`);
      });
      let response = '';
      socket.setTimeout(5000, () => { socket.destroy(); reject(new Error('timeout')); });
      socket.on('data', chunk => { response += chunk; });
      socket.on('end', () => resolve(Number(response.split(' ')[1])));
      socket.on('error', reject);
    });

    for (const hostile of [
      'attacker.example.com',
      'relay.evil.io',
      '127.0.0.1.attacker.com',
      'sim-bridge.example.org',
    ]) {
      assert.equal(await statusFor(hostile), 403, `${hostile} must be refused`);
    }
    // Names a home router actually hands out must keep working, or the phones
    // and the dashboard lose access to their own relay.
    for (const legitimate of [
      `127.0.0.1:${port}`,
      'localhost',
      '192.168.1.20',
      'mac.home',
      'mac-mini.local',
      'relay.lan',
      'raspberrypi',
    ]) {
      assert.equal(await statusFor(legitimate), 200, `${legitimate} must be allowed`);
    }
  });
});

test('no wildcard CORS grant is issued', async () => {
  await withRelay(async () => {
    for (const response of [
      await fetch(`${base}/health`),
      await fetch(`${base}/v1/bridges`, { method: 'OPTIONS' }),
    ]) {
      assert.equal(response.headers.get('access-control-allow-origin'), null);
    }
  });
});

test('internal failures never leak details to the caller', async () => {
  await withRelay(async () => {
    const malformed = await fetch(`${base}/v1/bridges/join`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: 'not json at all',
    });
    assert.equal(malformed.status, 400);
    const body = await malformed.json();
    assert.equal(body.error, 'Request body must be valid JSON');
    for (const leak of ['position', 'SQLITE', 'Buffer', '/Users/']) {
      assert.ok(!JSON.stringify(body).includes(leak), `leaked ${leak}`);
    }
  });
});

test('envelopes are accepted only in the exact expected shape', async () => {
  await withRelay(async () => {
    const created = await createBridge({
      bridgeId: 'envelope-bridge',
      inviteToken: 'derived-verifier',
      deviceName: 'Gateway',
      capabilities: { smsGateway: true },
    });
    const { token } = await created.json();
    const post = envelope => fetch(`${base}/v1/messages`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` },
      body: JSON.stringify({ envelope }),
    });

    assert.equal((await post(validEnvelope)).status, 201);
    assert.equal((await post({ ...validEnvelope, smuggled: 'extra' })).status, 400,
      'unknown keys must be rejected so nothing rides through to other phones');
    assert.equal((await post({ ...validEnvelope, nonce: '<script>' })).status, 400);
    assert.equal((await post({ ...validEnvelope, mac: 'A'.repeat(500) })).status, 400);
    assert.equal((await post({ ...validEnvelope, ciphertext: 'A'.repeat(50 * 1024) })).status, 400);
  });
});

test('a phone fetches only messages it has not seen', async () => {
  await withRelay(async () => {
    const created = await createBridge({
      bridgeId: 'cursor-bridge',
      inviteToken: 'derived-verifier',
      deviceName: 'Gateway',
      capabilities: { smsGateway: true },
    });
    const { token } = await created.json();
    const publish = () => fetch(`${base}/v1/messages`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` },
      body: JSON.stringify({ envelope: validEnvelope }),
    });
    const fetchSince = since => fetch(`${base}/v1/messages?since=${since}`, {
      headers: { authorization: `Bearer ${token}` },
    }).then(response => response.json());

    for (let i = 0; i < 3; i += 1) await publish();
    const first = await fetchSince(0);
    assert.equal(first.messages.length, 3, 'a new phone gets the whole history');
    assert.ok(first.latestSeq > 0);
    assert.ok(first.messages.every(item => typeof item.seq === 'number'));

    const idle = await fetchSince(first.latestSeq);
    assert.deepEqual(idle.messages, [], 'an up-to-date phone transfers nothing');
    assert.equal(idle.latestSeq, first.latestSeq);

    await publish();
    const incremental = await fetchSince(first.latestSeq);
    assert.equal(incremental.messages.length, 1, 'only the new message is sent');
    assert.ok(incremental.messages[0].seq > first.latestSeq);
  });
});

test('owner key and enrollment attempts are rate limited', async () => {
  await withRelay(async () => {
    let sawLimit = false;
    for (let attempt = 0; attempt < 20; attempt += 1) {
      const response = await fetch(`${base}/v1/admin/status`, {
        headers: { 'x-relay-key': `wrong-guess-${attempt}` },
      });
      if (response.status === 429) { sawLimit = true; break; }
    }
    assert.ok(sawLimit, 'owner key guessing must be throttled');

    let sawJoinLimit = false;
    for (let attempt = 0; attempt < 20; attempt += 1) {
      const response = await joinBridge({ bridgeId: 'nope', inviteToken: `guess-${attempt}` });
      if (response.status === 429) { sawJoinLimit = true; break; }
    }
    assert.ok(sawJoinLimit, 'enrollment guessing must be throttled');
  });
});

test('a revoked device loses its bearer immediately; restart cannot reuse it', async () => {
  await withRelay(async ({ restart }) => {
    const created = await createBridge({
      bridgeId: 'revoke-bridge',
      inviteToken: 'derived-verifier',
      deviceName: 'Gateway',
      capabilities: { smsGateway: true },
    });
    const { token, device } = await created.json();
    assert.equal((await fetch(`${base}/v1/devices`, {
      headers: { authorization: `Bearer ${token}` },
    })).status, 200);

    const revoked = await fetch(`${base}/v1/admin/devices/${device.id}/revoke`, {
      method: 'POST',
      headers: { 'x-relay-key': accessKey },
    });
    assert.equal(revoked.status, 200);
    assert.equal((await fetch(`${base}/v1/devices`, {
      headers: { authorization: `Bearer ${token}` },
    })).status, 401);

    await restart();
    assert.equal((await fetch(`${base}/v1/devices`, {
      headers: { authorization: `Bearer ${token}` },
    })).status, 401, 'old bearer sessions cannot survive RAM loss');
  });
});

test('only the owner phone can remove another phone from the bridge', async () => {
  await withRelay(async ({ restart }) => {
    const created = await createBridge({
      bridgeId: 'ownership-bridge',
      inviteToken: 'derived-verifier',
      deviceName: 'Android gateway',
      capabilities: { smsGateway: true },
    });
    const { token: ownerToken, device: owner } = await created.json();
    assert.equal(owner.isOwner, true, 'the creating phone owns the bridge');

    const joinedFirst = await joinBridge({
      bridgeId: 'ownership-bridge',
      inviteToken: 'derived-verifier',
      deviceName: 'iPhone',
    });
    const { token: clientToken, device: client } = await joinedFirst.json();
    assert.equal(client.isOwner, false);

    const joinedSecond = await joinBridge({
      bridgeId: 'ownership-bridge',
      inviteToken: 'derived-verifier',
      deviceName: 'Spare iPhone',
    });
    const { device: spare } = await joinedSecond.json();

    const remove = (token, id) => fetch(`${base}/v1/devices/${id}/remove`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` },
      body: '{}',
    });

    // A non-owner must not be able to evict the phones still in your hands.
    assert.equal((await remove(clientToken, owner.id)).status, 403);
    assert.equal((await remove(clientToken, spare.id)).status, 403);
    // Nor may the owner remove itself by this route.
    assert.equal((await remove(ownerToken, owner.id)).status, 400);

    assert.equal((await remove(ownerToken, client.id)).status, 200);
    assert.equal((await fetch(`${base}/v1/devices`, {
      headers: { authorization: `Bearer ${clientToken}` },
    })).status, 401, 'the removed phone loses access at once');

    const remaining = await fetch(`${base}/v1/devices`, {
      headers: { authorization: `Bearer ${ownerToken}` },
    });
    assert.deepEqual(
      (await remaining.json()).devices.map(item => item.name).sort(),
      ['Android gateway', 'Spare iPhone'],
    );
    await restart();
    for (const token of [clientToken, ownerToken]) {
      assert.equal((await fetch(`${base}/v1/devices`, { headers: { authorization: `Bearer ${token}` } })).status, 401);
    }
  });
});

test('leaving a bridge drops the device instead of stranding it', async () => {
  await withRelay(async () => {
    const created = await createBridge({
      bridgeId: 'leaving-bridge',
      inviteToken: 'derived-verifier',
      deviceName: 'Owner',
      capabilities: { smsGateway: true },
    });
    const { token: ownerToken } = await created.json();
    const joined = await joinBridge({
      bridgeId: 'leaving-bridge',
      inviteToken: 'derived-verifier',
      deviceName: 'iPhone',
    });
    const { token: clientToken } = await joined.json();

    const left = await fetch(`${base}/v1/devices/me/leave`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${clientToken}` },
      body: '{}',
    });
    assert.equal(left.status, 200);
    assert.equal((await fetch(`${base}/v1/devices`, {
      headers: { authorization: `Bearer ${clientToken}` },
    })).status, 401);

    const remaining = await fetch(`${base}/v1/devices`, {
      headers: { authorization: `Bearer ${ownerToken}` },
    });
    assert.deepEqual((await remaining.json()).devices.map(item => item.name), ['Owner']);
  });
});

test('a device from another bridge cannot be removed', async () => {
  await withRelay(async () => {
    const first = await createBridge({
      bridgeId: 'bridge-a',
      inviteToken: 'derived-verifier-a',
      deviceName: 'Owner A',
      capabilities: { smsGateway: true },
    });
    const { token: ownerA } = await first.json();
    const second = await createBridge({
      bridgeId: 'bridge-b',
      inviteToken: 'derived-verifier-b',
      deviceName: 'Owner B',
      capabilities: { smsGateway: true },
    });
    const { device: deviceB } = await second.json();

    const crossBridge = await fetch(`${base}/v1/devices/${deviceB.id}/remove`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${ownerA}` },
      body: '{}',
    });
    assert.equal(crossBridge.status, 404);
  });
});

test('the owner phone can close and reopen enrollment', async () => {
  await withRelay(async () => {
    const created = await createBridge({
      bridgeId: 'enrollment-bridge',
      inviteToken: 'derived-verifier',
      deviceName: 'Owner',
      capabilities: { smsGateway: true },
    });
    const { token: ownerToken } = await created.json();
    const joined = await joinBridge({
      bridgeId: 'enrollment-bridge',
      inviteToken: 'derived-verifier',
      deviceName: 'Client',
    });
    const { token: clientToken } = await joined.json();

    const setJoinable = (token, joinable) => fetch(`${base}/v1/bridges/joinable`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` },
      body: JSON.stringify({ joinable }),
    });

    assert.equal((await setJoinable(clientToken, false)).status, 403);
    assert.equal((await setJoinable(ownerToken, false)).status, 200);
    assert.equal((await joinBridge({
      bridgeId: 'enrollment-bridge',
      inviteToken: 'derived-verifier',
      deviceName: 'Uninvited',
    })).status, 403, 'a removed phone must not be able to walk back in');

    assert.equal((await setJoinable(ownerToken, true)).status, 200);
    assert.equal((await joinBridge({
      bridgeId: 'enrollment-bridge',
      inviteToken: 'derived-verifier',
      deviceName: 'Invited again',
    })).status, 201);
  });
});



test('a locked bridge refuses new devices even with the correct verifier', async () => {
  await withRelay(async () => {
    await createBridge({
      bridgeId: 'locked-bridge',
      inviteToken: 'derived-verifier',
      deviceName: 'Gateway',
      capabilities: { smsGateway: true },
    });
    const locked = await fetch(`${base}/v1/admin/bridges/locked-bridge/joinable`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-relay-key': accessKey },
      body: JSON.stringify({ joinable: false }),
    });
    assert.equal(locked.status, 200);
    const refused = await joinBridge({
      bridgeId: 'locked-bridge',
      inviteToken: 'derived-verifier',
      deviceName: 'Uninvited',
    });
    assert.equal(refused.status, 403);
  });
});

test('a command result can only be reported once', async () => {
  await withRelay(async () => {
    const created = await createBridge({
      bridgeId: 'command-bridge',
      inviteToken: 'derived-verifier',
      deviceName: 'Gateway',
      capabilities: { smsGateway: true },
    });
    const { token, device } = await created.json();
    const queued = await fetch(`${base}/v1/commands`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` },
      body: JSON.stringify({ targetDeviceId: device.id, envelope: validEnvelope }),
    });
    assert.equal(queued.status, 201);
    const { id } = await queued.json();
    const report = ok => fetch(`${base}/v1/commands/${id}/complete`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` },
      body: JSON.stringify({ ok }),
    });
    assert.equal((await report(true)).status, 200);
    assert.equal((await report(false)).status, 409, 'a settled command must not be rewritten');
  });
});

test('device names and capabilities remain typed; restart invalidates credentials', async () => {
  await withRelay(async ({ restart }) => {
    const created = await createBridge({
      bridgeId: 'types-bridge',
      inviteToken: 'derived-verifier',
      deviceName: 'Gateway',
      capabilities: { smsGateway: true },
    });
    const { token } = await created.json();
    const hostile = await joinBridge({
      bridgeId: 'types-bridge',
      inviteToken: 'derived-verifier',
      deviceName: 987.65,
      capabilities: 'not-an-object',
    });
    assert.equal(hostile.status, 400, 'non-text device names must be refused');

    const listed = await fetch(`${base}/v1/devices`, { headers: { authorization: `Bearer ${token}` } });
    for (const item of (await listed.json()).devices) {
      assert.equal(typeof item.name, 'string'); assert.equal(typeof item.capabilities, 'object');
    }
    await restart();
    assert.equal((await fetch(`${base}/v1/devices`, { headers: { authorization: `Bearer ${token}` } })).status, 401);
  });
});

test('push registration authentication, optional preview isolation and revocation hold in RAM', async () => {
  await withRelay(async () => {
    const gateway = await (await createBridge({ bridgeId: 'push-bridge', inviteToken: 'push-derived-verifier', capabilities: { smsGateway: true } })).json();
    const client = await (await joinBridge({ bridgeId: 'push-bridge', inviteToken: 'push-derived-verifier', capabilities: {} })).json();
    const post = (path, token, body) => fetch(`${base}${path}`, { method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: JSON.stringify(body) });
    const status = async () => (await (await fetch(`${base}/v1/admin/status`, { headers: { 'x-relay-key': accessKey } })).json()).counts;
    const subscription = { token: 'a'.repeat(64), environment: 'sandbox' };
    assert.equal((await post('/v1/devices/me/push', 'invalid', subscription)).status, 401);
    assert.equal((await post('/v1/devices/me/push', gateway.token, subscription)).status, 403);
    assert.equal((await post('/v1/devices/me/push', client.token, { ...subscription, token: 'bad' })).status, 400);
    assert.equal((await post('/v1/devices/me/push', client.token, subscription)).status, 200);
    for (const notification of [{ ...validEnvelope, plaintext: 'never accepted' }, { ...validEnvelope, ciphertext: 'A'.repeat(5000) }, undefined]) {
      assert.equal((await post('/v1/messages', gateway.token, { envelope: validEnvelope, notification })).status, 201);
    }
    assert.equal((await post('/v1/messages', gateway.token, { envelope: { invalid: true }, notification: validEnvelope })).status, 400);
    assert.equal((await status()).encryptedMessages, 3); assert.equal((await status()).pendingPushes, 0);
    assert.equal((await post('/v1/messages', gateway.token, { envelope: validEnvelope, notification: validEnvelope })).status, 201);
    assert.equal((await status()).pendingPushes, 1);
    assert.equal((await post(`/v1/devices/${client.device.id}/remove`, gateway.token, {})).status, 200);
    assert.equal((await status()).pendingPushes, 0); assert.equal((await status()).pushSubscriptions, 0);
  });
});

test('gateway upload IDs deduplicate acknowledgements and APNs per gateway in this process', async () => {
  await withRelay(async ({ restart }) => {
    const owner = await (await createBridge({ bridgeId: 'upload-retry', inviteToken: 'upload-retry-verifier', capabilities: { smsGateway: true } })).json();
    const client = await (await joinBridge({ bridgeId: 'upload-retry', inviteToken: 'upload-retry-verifier', capabilities: {} })).json();
    const post = (path, token, body) => fetch(`${base}${path}`, { method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: JSON.stringify(body) });
    await post('/v1/devices/me/push', client.token, { token: 'a'.repeat(64), environment: 'sandbox' });
    const body = { envelope: validEnvelope, notification: validEnvelope, uploadId: 'stable-event-1' };
    const first = await (await post('/v1/messages', owner.token, body)).json();
    assert.deepEqual(Object.keys(first).sort(), ['id', 'receivedAt', 'seq']);
    assert.deepEqual(await (await post('/v1/messages', owner.token, body)).json(), first);
    const secondGateway = await (await joinBridge({ bridgeId: 'upload-retry', inviteToken: 'upload-retry-verifier', capabilities: { smsGateway: true } })).json();
    assert.notEqual((await (await post('/v1/messages', secondGateway.token, body)).json()).id, first.id);
    const counts = (await (await fetch(`${base}/v1/admin/status`, { headers: { 'x-relay-key': accessKey } })).json()).counts;
    assert.equal(counts.encryptedMessages, 2); assert.equal(counts.pendingPushes, 2); assert.equal(counts.uploadReceipts, 2);
    assert.equal((await post('/v1/messages', owner.token, { ...body, uploadId: 'contains / invalid' })).status, 400);
    await restart();
    assert.equal((await post('/v1/messages', owner.token, body)).status, 401);
  });
});

// Cloudflare sets the client address itself; trusted proxies are a Node host setting.
test('client addresses come from a proxy header only when the peer is a trusted proxy', { skip: workerTarget }, async () => {
  const wrongKey = (relay, forwarded) => fetch(`${relay.base}/v1/admin/status`, {
    headers: { 'x-relay-key': 'wrong-guess', 'cf-connecting-ip': forwarded },
  });
  const untrusted = await startRelay();
  try {
    let limited = false;
    for (let attempt = 0; attempt < 15 && !limited; attempt += 1) {
      limited = (await wrongKey(untrusted, `203.0.113.${attempt + 1}`)).status === 429;
    }
    assert.ok(limited, 'a spoofed header from an untrusted peer must not escape the limit');
  } finally { await untrusted.stop(); }
  const proxied = await startRelay({ SIM_BRIDGE_TRUSTED_PROXIES: '127.0.0.1/32,::1' });
  try {
    for (let attempt = 0; attempt < 12; attempt += 1) await wrongKey(proxied, '203.0.113.7');
    assert.equal((await wrongKey(proxied, '203.0.113.7')).status, 429, 'the abusive client is limited');
    assert.equal((await wrongKey(proxied, '198.51.100.9')).status, 401, 'other clients behind the proxy keep their own budget');
  } finally { await proxied.stop(); }
});

test('a malformed bridge identifier in an erase request is a client error', async () => {
  const relay = await startRelay();
  try {
    const response = await fetch(`${relay.base}/v1/bridges/%E0%A4%A`, { method: 'DELETE', headers: { 'x-relay-key': accessKey } });
    assert.equal(response.status, 400);
  } finally { await relay.stop(); }
});

test('the owner can erase a bridge whose gateway never committed a policy', async () => {
  const relay = await startRelay();
  try {
    const created = await enroll(relay.request, newIdentity(), 'create', { bridgeId: 'synthetic-uncommitted', inviteToken: 'synthetic-invite-verifier', deviceName: 'Synthetic gateway', capabilities: { smsGateway: true } }, { owner: true });
    assert.equal(created.status, 201);
    const erased = await relay.request('/v1/bridges/synthetic-uncommitted', { method: 'DELETE', owner: true });
    assert.equal(erased.status, 200);
    assert.deepEqual(await erased.json(), { erased: true, committed: false });
    assert.equal((await relay.request('/v1/bridges/synthetic-uncommitted', { method: 'DELETE', owner: true })).status, 404);
  } finally { await relay.stop(); }
});

test('an oversized request body is refused with 413', async () => {
  const relay = await startRelay();
  try {
    const response = await fetch(`${relay.base}/v1/bridges/join`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ padding: 'x'.repeat(70 * 1024) }),
    });
    assert.equal(response.status, 413);
  } finally { await relay.stop(); }
});
