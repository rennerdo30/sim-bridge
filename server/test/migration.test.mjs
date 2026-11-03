import assert from 'node:assert/strict';
import test from 'node:test';
import { createHash, randomBytes } from 'node:crypto';
import { createMemoryDatabase } from '../src/sqlite-node.mjs';
import { createRecovery } from '../src/recovery.mjs';
import { newIdentity, enroll, commitPolicy } from '../test-support/identities.mjs';

const hash = value => createHash('sha256').update(value).digest('hex');
class RequestError extends Error { constructor(status, message) { super(message); this.status = status; } }

function liveLegacy({ gatewayOwner = true } = {}) {
  const database = createMemoryDatabase(), bridge = { id: 'known-legacy-bridge', inviteTokenHash: hash('known-invitation'), createdAt: '2025-01-01T00:00:00.000Z', joinable: true };
  const bridges = new Map([[bridge.id, bridge]]), devices = new Map(), tokens = new Map(), messages = new Map([[bridge.id, []]]), commands = new Map([[bridge.id, []]]);
  database.prepare('INSERT INTO bridges (id, invite_token, created_at, joinable) VALUES (?, ?, ?, 1)').run(bridge.id, bridge.inviteTokenHash, bridge.createdAt);
  for (const [id, gateway, owner, token] of [['known-gateway-id', true, gatewayOwner, 'known-opaque-gateway-token'], ['known-client-id', false, !gatewayOwner, 'known-opaque-client-token']]) {
    const device = { id, bridgeId: bridge.id, name: 'Synthetic legacy device', capabilities: { smsGateway: gateway }, isOwner: owner, lastSeenAt: bridge.createdAt };
    devices.set(id, device); tokens.set(hash(token), id);
    database.prepare('INSERT INTO devices (id, bridge_id, name, capabilities, last_seen_at, is_owner) VALUES (?, ?, ?, ?, ?, ?)').run(id, bridge.id, device.name, JSON.stringify(device.capabilities), device.lastSeenAt, owner ? 1 : 0);
    database.prepare('INSERT INTO device_tokens (token_hash, device_id) VALUES (?, ?)').run(hash(token), id);
  }
  const revokeDevice = id => {
    devices.delete(id); for (const [token, deviceId] of tokens) if (deviceId === id) tokens.delete(token);
    database.prepare('DELETE FROM devices WHERE id = ?').run(id); recovery.revoke(id);
  };
  const recovery = createRecovery({ accessKey: 'synthetic-operator-secret', database, bridges, devices, tokens, messages, commands,
    events: { emit() {}, online: () => true }, read: async req => req.body,
    reply: (res, status, body) => { res.response = new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } }); },
    authorizeOwner: req => req.headers['x-relay-key'] === 'synthetic-operator-secret', clientAddress: () => 'synthetic', publicDevice: device => ({ id: device.id, isOwner: device.isOwner, capabilities: device.capabilities }),
    capabilities: value => ({ smsGateway: value.smsGateway === true, calls: value.calls === true, callControl: value.callControl === true, multiSim: value.multiSim === true }),
    cleanName: value => value || 'Synthetic', secret: () => randomBytes(32).toString('base64url'), RequestError, revokeDevice,
    eraseBridge: id => { for (const device of [...devices.values()]) if (device.bridgeId === id) revokeDevice(device.id); database.prepare('DELETE FROM bridges WHERE id = ?').run(id); bridges.delete(id); } });
  const request = async (path, { method = 'GET', token, owner = false, body } = {}) => {
    const req = { method, body, headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(owner ? { 'x-relay-key': 'synthetic-operator-secret' } : {}) } }, res = {};
    try {
      if (method === 'GET' && path === '/v1/auth/policy') return new Response(JSON.stringify(recovery.policy(devices.get(tokens.get(hash(token))))));
      assert.equal(await recovery.handle(req, res, new URL(path, 'http://localhost')), true);
      return res.response;
    } catch (error) { if (!(error instanceof RequestError)) throw error; return new Response(JSON.stringify({ error: error.message, code: error.code }), { status: error.status }); }
  };
  return { recovery, request, bridge, devices, tokens, close() { recovery.stop(); database.close(); } };
}

test('live opaque-session upgrade preserves IDs and immutable roles, and requires gateway durable commit', async () => {
  const fixture = liveLegacy();
  try {
    const identity = newIdentity();
    const response = await enroll(fixture.request, identity, 'upgrade', {}, { token: 'known-opaque-gateway-token' });
    assert.equal(response.status, 200); const gateway = { ...await response.json(), identity };
    assert.equal(gateway.device.id, 'known-gateway-id'); assert.equal(gateway.bridge.id, fixture.bridge.id);
    assert.equal((await commitPolicy(fixture.request, gateway, gateway)).status, 200);
    const legacyClient = fixture.devices.get('known-client-id');
    assert.throws(() => fixture.recovery.authorize(undefined, legacyClient, '/v1/messages'), error => error.code === 'legacy_upgrade_required');
    const clientKey = newIdentity();
    const upgrading = enroll(fixture.request, clientKey, 'upgrade', { isOwner: true, capabilities: { smsGateway: true } }, { token: 'known-opaque-client-token' });
    await new Promise(resolve => setImmediate(resolve));
    const proposal = fixture.recovery.policy(fixture.devices.get('known-gateway-id'));
    assert.ok(proposal.proposalId); assert.equal((await commitPolicy(fixture.request, gateway, proposal)).status, 200);
    const completed = await upgrading; assert.equal(completed.status, 200); const client = await completed.json();
    assert.equal(client.device.id, 'known-client-id');
    const claims = fixture.recovery.identity.inspect(client.certificate);
    assert.equal(claims.isOwner, false); assert.equal(claims.smsGateway, false); assert.equal(claims.authority, false);
    const retry = await enroll(fixture.request, clientKey, 'upgrade', {}, { token: 'known-opaque-client-token' });
    assert.equal(retry.status, 200); assert.equal((await retry.json()).certificate, client.certificate);
    assert.equal((await enroll(fixture.request, newIdentity(), 'upgrade', {}, { token: 'known-opaque-client-token' })).status, 409);
  } finally { fixture.close(); }
});

test('shared invitation or a non-owner gateway never proves migration authority without operator approval', async () => {
  const fixture = liveLegacy({ gatewayOwner: false });
  try {
    const key = newIdentity();
    assert.equal((await enroll(fixture.request, key, 'upgrade', { inviteToken: 'known-invitation', isOwner: true }, {})).status, 401);
    assert.equal((await enroll(fixture.request, key, 'upgrade', {}, { token: 'known-opaque-gateway-token' })).status, 409);
    const approved = await enroll(fixture.request, key, 'upgrade', {}, { token: 'known-opaque-gateway-token', owner: true });
    assert.equal(approved.status, 200); const gateway = { ...await approved.json(), identity: key };
    assert.equal(fixture.recovery.identity.inspect(gateway.certificate).isOwner, true);
    assert.equal((await commitPolicy(fixture.request, gateway, gateway)).status, 200);
  } finally { fixture.close(); }
});

test('revoking an un-upgraded legacy mapping disables its bearer and prevents later upgrade resurrection', async () => {
  const fixture = liveLegacy();
  try {
    const identity = newIdentity();
    const initial = await enroll(fixture.request, identity, 'upgrade', {}, { token: 'known-opaque-gateway-token' });
    const gateway = { ...await initial.json(), identity }; assert.equal((await commitPolicy(fixture.request, gateway, gateway)).status, 200);
    const revoked = fixture.recovery.mutation(fixture.bridge, 'revoke', fixture.devices.get('known-client-id'));
    const proposal = fixture.recovery.policy(fixture.devices.get('known-gateway-id'));
    assert.equal((await commitPolicy(fixture.request, gateway, proposal)).status, 200); await revoked;
    assert.equal(fixture.devices.has('known-client-id'), false);
    assert.equal((await enroll(fixture.request, newIdentity(), 'upgrade', {}, { token: 'known-opaque-client-token' })).status, 401);
  } finally { fixture.close(); }
});
