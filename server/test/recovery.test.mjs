import assert from 'node:assert/strict';
import test from 'node:test';
import { request as httpRequest } from 'node:http';
import { setTimeout as delay } from 'node:timers/promises';
import { startRelay, ownerKey, envelope } from '../test-support/relay.mjs';
import { newIdentity, identityProof, enroll, commitPolicy } from '../test-support/identities.mjs';
import { createIdentityAuthority } from '../src/identity.mjs';

async function isolated() {
  const relay = await startRelay();
  const request = (path, { method = 'GET', token, certificate, owner = false, body } = {}) => fetch(relay.base + path, {
    method, headers: { 'content-type': 'application/json', ...(owner ? { 'x-relay-key': ownerKey } : {}),
      ...(token ? { authorization: `Bearer ${token}` } : {}), ...(certificate ? { 'x-device-certificate': certificate } : {}) },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }), signal: AbortSignal.timeout(12_000),
  });
  const streams = [];
  const connect = async session => {
    const req = httpRequest(relay.base + '/v1/events', { headers: { authorization: `Bearer ${session.token}`, 'x-device-certificate': session.certificate } });
    const res = await new Promise((resolve, reject) => { req.once('response', resolve); req.once('error', reject); req.end(); });
    assert.equal(res.statusCode, 200); res.resume();
    const closed = new Promise(resolve => res.once('end', resolve));
    const stop = () => { res.destroy(); req.destroy(); }; stop.closed = closed; streams.push(stop); return stop;
  };
  const create = async (bridgeId = 'recovery-bridge') => {
    const identity = newIdentity();
    const response = await enroll(request, identity, 'create', { bridgeId, inviteToken: 'synthetic-recovery-invite', deviceName: 'Synthetic authority', capabilities: { smsGateway: true } }, { owner: true });
    assert.equal(response.status, 201); const gateway = { ...await response.json(), identity };
    assert.equal((await request('/v1/messages', gateway)).status, 409, 'initial provisional session is restricted');
    const committed = await commitPolicy(request, gateway, gateway); assert.equal(committed.status, 200);
    return gateway;
  };
  const proposal = async gateway => {
    for (let i = 0; i < 100; i++) {
      const response = await request('/v1/auth/policy', gateway); assert.equal(response.status, 200);
      const value = await response.json(); if (value.proposalId) return value; await delay(10);
    }
    throw new Error('No gateway policy proposal arrived');
  };
  const join = async gateway => {
    const identity = newIdentity();
    const joining = enroll(request, identity, 'join', { bridgeId: gateway.bridge.id, inviteToken: 'synthetic-recovery-invite', deviceName: 'Synthetic member', capabilities: { smsGateway: false } });
    const next = await proposal(gateway); assert.equal((await commitPolicy(request, gateway, next)).status, 200);
    const response = await joining; assert.equal(response.status, 201); return { ...await response.json(), identity };
  };
  const prove = async (session, operation, payloadJson = '') => identityProof(request, session.identity, operation, payloadJson, session.certificate);
  return { ...relay, request, connect, create, proposal, join, prove,
    async stop() { streams.forEach(stop => stop()); await relay.stop(); } };
}

test('cold recovery waits for gateway and restores pairing identity without restoring transient content', async () => {
  let relay = await isolated();
  try {
    const gateway = await relay.create(); await relay.connect(gateway); const client = await relay.join(gateway);
    await relay.request('/v1/messages', { ...gateway, method: 'POST', body: { envelope, uploadId: 'synthetic-upload' } });
    await relay.request('/v1/commands', { ...client, method: 'POST', body: { targetDeviceId: gateway.device.id, envelope } });
    await relay.request('/v1/devices/me/push', { ...client, method: 'POST', body: { token: 'a'.repeat(64), environment: 'sandbox' } });
    const previousProof = await relay.prove(client, 'resume');
    const previousPolicy = gateway.policyJson;
    await relay.stop(); relay = await isolated();
    let response = await relay.request('/v1/devices', client);
    assert.equal(response.status, 409); assert.equal((await response.json()).code, 'pairing_recovery_pending');
    response = await relay.request('/v1/auth/resume', { method: 'POST', body: await relay.prove(client, 'resume') });
    assert.equal(response.status, 409);
    response = await relay.request('/v1/auth/bootstrap', { method: 'POST', body: await relay.prove(client, 'bootstrap', previousPolicy) });
    assert.equal(response.status, 400, 'member certificate cannot establish authority');
    response = await relay.request('/v1/auth/bootstrap', { method: 'POST', body: await relay.prove(gateway, 'bootstrap', previousPolicy) });
    assert.equal(response.status, 200); const restoredGateway = await response.json();
    assert.equal(restoredGateway.device.id, gateway.device.id); assert.equal(restoredGateway.bridge.id, gateway.bridge.id);
    assert.equal((await relay.request('/v1/auth/resume', { method: 'POST', body: previousProof })).status, 401, 'old boot proof is never valid');
    response = await relay.request('/v1/auth/resume', { method: 'POST', body: await relay.prove(client, 'resume') });
    assert.equal(response.status, 200); const restoredClient = await response.json();
    assert.equal(restoredClient.device.id, client.device.id); assert.equal(restoredClient.bridge.id, client.bridge.id);
    assert.notEqual(restoredClient.token, client.token);
    assert.equal((await (await relay.request('/v1/messages', restoredClient)).json()).messages.length, 0);
    assert.equal((await (await relay.request('/v1/messages', restoredClient)).json()).latestSeq, 0);
    assert.equal((await (await relay.request('/v1/admin/status', { owner: true })).json()).counts.pushSubscriptions, 0);
    assert.equal((await relay.request('/v1/devices', client)).status, 409, 'old bearer alone needs session resume');
    assert.equal((await relay.request('/v1/auth/resume', { method: 'POST', body: await relay.prove({ ...client, identity: newIdentity() }, 'resume') })).status, 401);
  } finally { await relay.stop(); }
});

test('durably revoked certificates stay denied after restart and revocation closes reusable invitations', async () => {
  let relay = await isolated();
  try {
    const gateway = await relay.create(); await relay.connect(gateway); const client = await relay.join(gateway);
    const stalePolicy = gateway.policyJson, staleProof = await relay.prove(client, 'resume');
    const removing = relay.request(`/v1/admin/devices/${client.device.id}/revoke`, { method: 'POST', owner: true, body: {} });
    const pending = await relay.proposal(gateway); assert.equal(JSON.parse(pending.policyJson).joinable, false);
    assert.equal((await commitPolicy(relay.request, gateway, pending)).status, 200); assert.equal((await removing).status, 200);
    assert.equal((await relay.request('/v1/auth/resume', { method: 'POST', body: staleProof })).status, 401);
    assert.equal((await relay.request('/v1/auth/bootstrap', { method: 'POST', body: await relay.prove(gateway, 'bootstrap', stalePolicy) })).status, 409);
    await relay.stop(); relay = await isolated();
    assert.equal((await relay.request('/v1/auth/bootstrap', { method: 'POST', body: await relay.prove(gateway, 'bootstrap', gateway.policyJson) })).status, 200);
    const denied = await relay.request('/v1/auth/resume', { method: 'POST', body: await relay.prove(client, 'resume') });
    assert.equal(denied.status, 401); assert.equal((await denied.json()).code, 'device_revoked');
    const invite = await enroll(relay.request, newIdentity(), 'join', { bridgeId: gateway.bridge.id, inviteToken: 'synthetic-recovery-invite', capabilities: { smsGateway: false } });
    assert.equal(invite.status, 403); assert.equal((await invite.json()).code, 'enrollment_locked');
  } finally { await relay.stop(); }
});

test('lost policy commit leaves authorization frozen; an old warm snapshot cannot cancel the pending revocation', async () => {
  const relay = await isolated();
  try {
    const gateway = await relay.create(); await relay.connect(gateway); const client = await relay.join(gateway);
    const previous = gateway.policyJson;
    const removing = relay.request(`/v1/devices/${client.device.id}/remove`, { ...gateway, method: 'POST', body: {} });
    const pending = await relay.proposal(gateway);
    gateway.policyJson = pending.policyJson; // Durable write succeeded; commit transport is lost.
    const response = await removing;
    assert.equal(response.status, 409); assert.equal((await response.json()).code, 'policy_pending');
    assert.equal((await relay.request('/v1/commands', { ...client, method: 'POST', body: { targetDeviceId: gateway.device.id, envelope } })).status, 409);
    assert.equal((await relay.request('/v1/auth/bootstrap', { method: 'POST', body: await relay.prove(gateway, 'bootstrap', previous) })).status, 409);
    assert.equal((await relay.request('/v1/messages', client)).status, 409, 'stale snapshot cannot unfreeze');
    assert.equal((await relay.request('/v1/auth/bootstrap', { method: 'POST', body: await relay.prove(gateway, 'bootstrap', gateway.policyJson) })).status, 200);
    const denied = await relay.request('/v1/devices', client); assert.equal(denied.status, 401); assert.equal((await denied.json()).code, 'device_revoked');
  } finally { await relay.stop(); }
});

test('an offline authority cannot promise permanent administrator revocation, locking or erasure', async () => {
  const relay = await isolated();
  try {
    const gateway = await relay.create();
    for (const [path, method, body] of [[`/v1/admin/devices/${gateway.device.id}/revoke`, 'POST', {}],
      [`/v1/admin/bridges/${gateway.bridge.id}/joinable`, 'POST', { joinable: false }], [`/v1/bridges/${gateway.bridge.id}`, 'DELETE', undefined]]) {
      const response = await relay.request(path, { owner: true, method, body });
      assert.equal(response.status, 409); assert.equal((await response.json()).code, 'gateway_unavailable');
    }
    assert.equal((await relay.request('/v1/devices', gateway)).status, 200);
  } finally { await relay.stop(); }
});

test('bridge erasure commits an inactive gateway tombstone and cannot reactivate the erased incarnation', async () => {
  let relay = await isolated();
  try {
    const gateway = await relay.create(); await relay.connect(gateway); const client = await relay.join(gateway);
    const previous = gateway.policyJson;
    const erasing = relay.request(`/v1/bridges/${gateway.bridge.id}`, { owner: true, method: 'DELETE' });
    const pending = await relay.proposal(gateway), tombstone = JSON.parse(pending.policyJson);
    assert.equal(tombstone.erased, true); assert.deepEqual(tombstone.members, []);
    assert.equal((await commitPolicy(relay.request, gateway, pending)).status, 200); assert.equal((await erasing).status, 200);
    assert.equal((await relay.request('/v1/auth/bootstrap', { method: 'POST', body: await relay.prove(gateway, 'bootstrap', previous) })).status, 401);
    await relay.stop(); relay = await isolated();
    const restored = await relay.request('/v1/auth/bootstrap', { method: 'POST', body: await relay.prove(gateway, 'bootstrap', gateway.policyJson) });
    assert.equal(restored.status, 200); assert.equal((await restored.json()).erased, true);
    assert.equal((await relay.request('/v1/auth/resume', { method: 'POST', body: await relay.prove(client, 'resume') })).status, 401);
    assert.equal((await (await relay.request('/v1/admin/status', { owner: true })).json()).counts.devices, 0);
  } finally { await relay.stop(); }
});

test('retrying enrollment with the same proven key retains identity; invitation knowledge cannot retrieve its certificate', async () => {
  const relay = await isolated();
  try {
    const gateway = await relay.create(); await relay.connect(gateway); const client = await relay.join(gateway);
    const retry = await enroll(relay.request, client.identity, 'join', { bridgeId: gateway.bridge.id, inviteToken: 'synthetic-recovery-invite', capabilities: { smsGateway: false } });
    assert.equal(retry.status, 201); assert.equal((await retry.json()).device.id, client.device.id);
    assert.equal((await (await relay.request('/v1/devices', gateway)).json()).devices.length, 2);
    const wrong = newIdentity(); wrong.publicKey = client.identity.publicKey;
    const stolen = await enroll(relay.request, wrong, 'join', { bridgeId: gateway.bridge.id, inviteToken: 'synthetic-recovery-invite', capabilities: { smsGateway: false } });
    assert.equal(stolen.status, 401);
    const creationRetry = await enroll(relay.request, gateway.identity, 'create', { bridgeId: gateway.bridge.id, inviteToken: 'synthetic-recovery-invite', capabilities: { smsGateway: true } }, { owner: true });
    assert.equal(creationRetry.status, 201); assert.equal((await creationRetry.json()).device.id, gateway.device.id);
  } finally { await relay.stop(); }
});

test('explicit operator restore preserves supplied device IDs and requires durable gateway acknowledgement', async () => {
  const relay = await isolated();
  try {
    const gatewayKey = newIdentity(), clientKey = newIdentity();
    const body = { approveIdentityBindings: true, bridgeId: 'known-bridge', inviteToken: 'synthetic-recovery-invite', createdAt: '2025-01-01T00:00:00.000Z', authorityDeviceId: 'known-gateway', joinable: false,
      members: [{ deviceId: 'known-gateway', devicePublicKey: gatewayKey.publicKey, name: 'Synthetic gateway', capabilities: { smsGateway: true }, isOwner: true },
        { deviceId: 'known-client', devicePublicKey: clientKey.publicKey, name: 'Synthetic client', capabilities: { smsGateway: false }, isOwner: false }] };
    assert.equal((await relay.request('/v1/admin/recovery/restore', { method: 'POST', body })).status, 401);
    assert.equal((await relay.request('/v1/admin/recovery/restore', { method: 'POST', owner: true, body: { ...body, approveIdentityBindings: false } })).status, 400);
    const response = await relay.request('/v1/admin/recovery/restore', { method: 'POST', owner: true, body }); assert.equal(response.status, 201);
    const gateway = { ...await response.json(), identity: gatewayKey }; assert.equal(gateway.device.id, 'known-gateway');
    assert.equal((await relay.request('/v1/messages', gateway)).status, 409);
    assert.equal((await commitPolicy(relay.request, gateway, gateway)).status, 200);
    const client = { identity: clientKey, certificate: gateway.certificates.find(item => item.deviceId === 'known-client').certificate };
    const resumed = await relay.request('/v1/auth/resume', { method: 'POST', body: await relay.prove(client, 'resume') });
    assert.equal(resumed.status, 200); assert.equal((await resumed.json()).device.id, 'known-client');
  } finally { await relay.stop(); }
});

test('proofs issued before a policy change are rechecked at consumption and repeated resume sessions stay bounded', async () => {
  const relay = await isolated();
  try {
    const gateway = await relay.create(); await relay.connect(gateway); const client = await relay.join(gateway);
    const clientEvents = await relay.connect(client);
    const stale = await relay.prove(client, 'resume');
    const locking = relay.request('/v1/bridges/joinable', { ...gateway, method: 'POST', body: { joinable: false } });
    assert.equal((await commitPolicy(relay.request, gateway, await relay.proposal(gateway))).status, 200);
    assert.equal((await locking).status, 200);
    const response = await relay.request('/v1/auth/resume', { method: 'POST', body: stale });
    assert.equal(response.status, 409); assert.equal((await response.json()).code, 'policy_pending');
    const sessions = [];
    for (let i = 0; i < 10; i++) {
      const resumed = await relay.request('/v1/auth/resume', { method: 'POST', body: await relay.prove(client, 'resume') });
      assert.equal(resumed.status, 200); sessions.push(await resumed.json());
    }
    assert.equal((await relay.request('/v1/devices', sessions[0])).status, 409, 'old sessions are evicted after the per-device bound');
    assert.equal((await relay.request('/v1/devices', sessions.at(-1))).status, 200);
    await Promise.race([clientEvents.closed, delay(1000).then(() => { throw new Error('Evicted bearer event stream remained open'); })]);
    assert.equal((await (await relay.request('/v1/admin/debug/self-test', { owner: true, method: 'POST', body: {} })).json()).ok, true);
  } finally { await relay.stop(); }
});

test('resume rejects extra payloads and bootstrap rejects duplicate keys, foreign bindings and altered certificate roles atomically', async () => {
  const relay = await isolated(), issuer = createIdentityAuthority(ownerKey);
  try {
    const gateway = await relay.create(); await relay.connect(gateway); const client = await relay.join(gateway);
    const extra = await relay.request('/v1/auth/resume', { method: 'POST', body: await relay.prove(client, 'resume', '{"unexpected":true}') });
    assert.equal(extra.status, 400);
    const ledger = JSON.parse(gateway.policyJson), originalClient = ledger.members.find(member => issuer.inspect(member.certificate).deviceId === client.device.id);
    const duplicate = structuredClone(ledger);
    duplicate.members.push({ ...originalClient, certificate: issuer.issue({ ...issuer.inspect(client.certificate), deviceId: 'different-id-same-key' }) });
    const foreign = structuredClone(ledger);
    foreign.members[1].certificate = issuer.issue({ ...issuer.inspect(client.certificate), bridgeId: 'different-bridge' });
    const altered = structuredClone(ledger), parts = altered.members[1].certificate.split('.');
    const claims = JSON.parse(Buffer.from(parts[0], 'base64url')); claims.isOwner = true;
    altered.members[1].certificate = Buffer.from(JSON.stringify(claims)).toString('base64url') + '.' + parts[1];
    for (const policy of [duplicate, foreign, altered]) {
      const response = await relay.request('/v1/auth/bootstrap', { method: 'POST', body: await relay.prove(gateway, 'bootstrap', JSON.stringify(policy)) });
      assert.equal(response.status, 400);
      assert.equal((await (await relay.request('/v1/devices', gateway)).json()).devices.length, 2);
      assert.equal((await (await relay.request('/v1/admin/debug/self-test', { owner: true, method: 'POST', body: {} })).json()).ok, true);
    }
  } finally { issuer.stop(); await relay.stop(); }
});
