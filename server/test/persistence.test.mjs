import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { startRelay, envelope } from '../test-support/relay.mjs';

test('legacy files are untouched and relay restart invalidates RAM sessions and queues', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'sim-bridge-ram-test-'));
  const oldDatabase = join(directory, 'old.sqlite');
  const oldLog = join(directory, 'old.log');
  const marker = 'existing private state: fixture only';
  await writeFile(oldDatabase, marker); await writeFile(oldLog, marker);
  let relay;
  try {
    const settings = { SIM_BRIDGE_DATABASE: oldDatabase, SIM_BRIDGE_LOG_FILE: oldLog };
    relay = await startRelay(settings);
    const gateway = await relay.create(); const client = await relay.join();
    await relay.request('/v1/devices/me/push', { method: 'POST', token: client.token, body: { token: 'a'.repeat(64), environment: 'sandbox' } });
    await relay.request('/v1/messages', { method: 'POST', token: gateway.token, body: { envelope, notification: envelope, uploadId: 'opaque-retry' } });
    await relay.request('/v1/commands', { method: 'POST', token: client.token, body: { envelope, targetDeviceId: gateway.device.id } });
    const status = await (await relay.request('/v1/admin/status', { owner: true })).json();
    assert.equal(status.security.persistence, 'memory-only');
    assert.equal(status.counts.pendingPushes, 1); assert.equal(status.counts.pendingCommands, 1);
    await relay.stop(); relay = await startRelay(settings);
    for (const token of [gateway.token, client.token]) assert.equal((await relay.request('/v1/devices', { token })).status, 401);
    const empty = await (await relay.request('/v1/admin/status', { owner: true })).json();
    for (const key of ['bridges','devices','encryptedMessages','commands','pendingPushes','pushSubscriptions','uploadReceipts']) assert.equal(empty.counts[key], 0, key);
    assert.equal(await readFile(oldDatabase, 'utf8'), marker); assert.equal(await readFile(oldLog, 'utf8'), marker);
    assert.deepEqual((await readdir(directory)).sort(), ['old.log','old.sqlite']);
    assert.equal((await relay.joinResponse({ bridgeId: 'isolated-bridge', inviteToken: 'synthetic-invite-verifier', capabilities: {} })).status, 409);
    assert.ok(gateway.policyJson.includes(client.certificate), 'gateway-side policy fixture survives relay RAM loss');
    // A fresh bridge may deliberately reuse the root identity, but old bearer tokens stay revoked.
    await relay.create();
    assert.equal((await relay.request('/v1/devices', { token: gateway.token })).status, 401);
  } finally { await relay?.stop(); await rm(directory, { recursive: true, force: true }); }
});

test('five-minute ceilings, expiry, payload-free dedup and monotonic cursors apply in RAM', async () => {
  const relay = await startRelay({ SIM_BRIDGE_TRANSIENT_TTL_MS: '100', SIM_BRIDGE_RECEIPT_TTL_MS: '1000' });
  try {
    const gateway = await relay.create(); const client = await relay.join();
    await relay.request('/v1/devices/me/push', { method: 'POST', token: client.token, body: { token: 'a'.repeat(64), environment: 'sandbox' } });
    const upload = body => relay.request('/v1/messages', { method: 'POST', token: gateway.token, body });
    const first = await (await upload({ envelope, notification: envelope, uploadId: 'retained-ack' })).json();
    await relay.request('/v1/commands', { method: 'POST', token: client.token, body: { targetDeviceId: gateway.device.id, envelope } });
    await delay(180);
    const status = await (await relay.request('/v1/admin/status', { owner: true })).json();
    assert.equal(status.counts.encryptedMessages, 0); assert.equal(status.counts.commands, 0); assert.equal(status.counts.pendingPushes, 0);
    assert.equal(status.counts.uploadReceipts, 1);
    assert.deepEqual(await (await upload({ envelope, notification: envelope, uploadId: 'retained-ack' })).json(), first);
    assert.deepEqual(Object.keys(first).sort(), ['id','receivedAt','seq']);
    assert.equal((await (await relay.request('/v1/admin/status', { owner: true })).json()).counts.encryptedMessages, 0);
    const next = await (await upload({ envelope, uploadId: 'second-ack' })).json();
    assert.ok(next.seq > first.seq, 'expiry must never reuse a message cursor');
    const gap = await (await relay.request('/v1/messages?since=0.5', { token: client.token })).json();
    assert.equal(gap.expired, true); assert.equal(gap.latestSeq, next.seq);
    await delay(1050);
    assert.equal((await (await relay.request('/v1/admin/status', { owner: true })).json()).counts.uploadReceipts, 0);
  } finally { await relay.stop(); }
});

test('console diagnostics contain no device, bridge, IP, token, envelope or legacy path values', async () => {
  const relay = await startRelay({ SIM_BRIDGE_LOG_LEVEL: 'debug', SIM_BRIDGE_DATABASE: '/nonexistent/private-legacy-location.sqlite', SIM_BRIDGE_LOG_FILE: '/nonexistent/private-legacy-location.log' });
  const gateway = await relay.create('sensitive-fixture-bridge');
  try {
    await relay.request('/v1/messages', { method: 'POST', token: gateway.token, body: { envelope } });
    await relay.request('/v1/admin/status', { owner: true });
    await relay.stop();
    for (const value of ['sensitive-fixture-bridge', gateway.token, gateway.device.id, '127.0.0.1', 'ciphertext=', 'private-legacy-location']) assert.equal(relay.output.includes(value), false, value);
  } finally { await relay.stop(); }
});
