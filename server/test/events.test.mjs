import assert from 'node:assert/strict';
import test from 'node:test';
import { request as httpRequest } from 'node:http';
import { EventEmitter } from 'node:events';
import { createConnection } from 'node:net';
import { setTimeout as delay } from 'node:timers/promises';
import { createEventStreams } from '../src/events.mjs';
import { startRelay, envelope, ownerKey, workerTarget } from '../test-support/relay.mjs';

async function stream(relay, token, admin = false) {
  const events = [];
  let response;
  const request = httpRequest(relay.base + (admin ? '/v1/admin/events' : '/v1/events'), {
    headers: admin ? { 'x-relay-key': ownerKey } : { authorization: `Bearer ${token}` },
  });
  const connected = new Promise((resolve, reject) => {
    request.once('error', reject);
    request.once('response', res => {
      response = res;
      if (res.statusCode !== 200) { res.resume(); reject(new Error(`Stream status ${res.statusCode}`)); return; }
      assert.match(res.headers['content-type'], /text\/event-stream/);
      assert.equal(res.headers['cache-control'], 'no-store');
      assert.equal(res.headers['access-control-allow-origin'], undefined);
      let pending = '';
      res.setEncoding('utf8');
      res.on('data', chunk => {
        pending += chunk;
        let at;
        while ((at = pending.indexOf('\n\n')) >= 0) {
          const frame = pending.slice(0, at); pending = pending.slice(at + 2);
          if (frame.startsWith('data: ')) events.push(JSON.parse(frame.slice(6)));
        }
      });
      resolve();
    });
  });
  request.end(); await connected;
  const closed = new Promise(resolve => response.once('end', resolve));
  const wait = async type => {
    for (let i = 0; i < 100; i++) { if (events.some(event => event.type === type)) return; await delay(10); }
    throw new Error(`No ${type} stream hint arrived.`);
  };
  await wait('ready');
  return { events, wait, closed, stop: () => { response.destroy(); request.destroy(); } };
}

test('HTTP SSE is header-authenticated, bridge-scoped, target-scoped and revocation-aware', async () => {
  const relay = await startRelay(); const streams = [];
  try {
    assert.equal((await relay.request('/v1/events')).status, 401);
    const gateway = await relay.create(); const client = await relay.join();
    const otherGateway = await relay.join('isolated-bridge', true);
    const outsider = await relay.create('different-bridge');
    assert.equal((await relay.request(`/v1/events?token=${client.token}`)).status, 400);
    const gatewayEvents = await stream(relay, gateway.token); streams.push(gatewayEvents);
    const clientEvents = await stream(relay, client.token); streams.push(clientEvents);
    const otherEvents = await stream(relay, otherGateway.token); streams.push(otherEvents);
    const outsideEvents = await stream(relay, outsider.token); streams.push(outsideEvents);
    await delay(30); streams.forEach(item => { item.events.length = 0; });
    const roster = await (await relay.request('/v1/devices', { token: client.token })).json();
    assert.ok(roster.devices.every(device => device.online && device.eventConnected));
    await relay.request('/v1/messages', { method: 'POST', token: gateway.token, body: { envelope } });
    await Promise.all([gatewayEvents.wait('messages'), clientEvents.wait('messages'), otherEvents.wait('messages')]);
    await delay(30); assert.equal(outsideEvents.events.length, 0);
    streams.forEach(item => { item.events.length = 0; });
    await relay.request('/v1/commands', { method: 'POST', token: client.token, body: { targetDeviceId: gateway.device.id, envelope } });
    await gatewayEvents.wait('commands'); await delay(30);
    for (const other of [clientEvents, otherEvents, outsideEvents]) assert.equal(other.events.some(event => event.type === 'commands'), false);
    for (const item of streams) for (const event of item.events) assert.deepEqual(Object.keys(event), ['type']);
    streams.forEach(item => { item.events.length = 0; });
    for (let i = 0; i < 5; i++) await relay.request('/v1/devices', { token: client.token });
    await delay(30); assert.equal(gatewayEvents.events.some(event => event.type === 'devices'), false, 'roster reads must not feed back into events');
    await relay.request(`/v1/devices/${client.device.id}/remove`, { method: 'POST', token: gateway.token, body: {} });
    await clientEvents.closed;
    assert.equal((await relay.request('/v1/events', { token: client.token })).status, 401);
    await gatewayEvents.wait('devices');
  } finally { streams.forEach(item => item.stop()); await relay.stop(); }
});

test('ready catches prior mutations; stream limits and first/last presence are bounded', async () => {
  const relay = await startRelay(); const streams = [];
  try {
    const gateway = await relay.create(); const client = await relay.join();
    await relay.request('/v1/messages', { method: 'POST', token: gateway.token, body: { envelope } });
    const first = await stream(relay, client.token); streams.push(first);
    assert.equal((await (await relay.request('/v1/messages', { token: client.token })).json()).messages.length, 1);
    const second = await stream(relay, client.token); streams.push(second);
    // A reconnect beyond the per-device limit replaces the oldest stream
    // instead of being refused, so a phone that changed networks recovers.
    const third = await stream(relay, client.token); streams.push(third);
    await first.closed;
    let roster = await (await relay.request('/v1/devices', { token: gateway.token })).json();
    assert.equal(roster.devices.find(item => item.id === client.device.id).online, true);
    second.stop(); await delay(40);
    roster = await (await relay.request('/v1/devices', { token: gateway.token })).json();
    assert.equal(roster.devices.find(item => item.id === client.device.id).online, true);
    third.stop();
    // Local workerd never reports this disconnect; the Worker relies on stream
    // rotation instead, which the unit test below covers.
    if (workerTarget) return;
    // A client disconnect reaches the relay asynchronously; allow it to arrive.
    let online = true;
    for (let i = 0; i < 100 && online; i++) {
      await delay(20);
      roster = await (await relay.request('/v1/devices', { token: gateway.token })).json();
      online = roster.devices.find(item => item.id === client.device.id).online;
    }
    assert.equal(online, false);
  } finally { streams.forEach(item => item.stop()); await relay.stop(); }
});

test('a second gateway stream requests a fresh producer snapshot after buffer expiry', async () => {
  const relay = await startRelay({ SIM_BRIDGE_TRANSIENT_TTL_MS: '100' }); const streams = [];
  try {
    const gateway = await relay.create();
    const headless = gateway.worker; streams.push(headless);
    await relay.request('/v1/messages', { method: 'POST', token: gateway.token, body: { envelope } });
    await delay(160);
    assert.equal((await (await relay.request('/v1/messages', { token: gateway.token })).json()).messages.length, 0);
    headless.events.length = 0;
    const visible = await stream(relay, gateway.token); streams.push(visible);
    await headless.wait('devices');
    assert.ok(visible.events.some(event => event.type === 'ready'));
  } finally { streams.forEach(item => item.stop()); await relay.stop(); }
});

test('owner bridge erasure closes all member streams and removes every RAM child without crossing bridges', async () => {
  const relay = await startRelay(); const streams = [];
  try {
    const gateway = await relay.create(); const client = await relay.join(); const outsider = await relay.create('unrelated-bridge');
    const gatewayEvents = await stream(relay, gateway.token); const clientEvents = await stream(relay, client.token);
    const outsideEvents = await stream(relay, outsider.token); streams.push(gatewayEvents, clientEvents, outsideEvents);
    await relay.request('/v1/devices/me/push', { method: 'POST', token: client.token, body: { token: 'a'.repeat(64), environment: 'sandbox' } });
    await relay.request('/v1/messages', { method: 'POST', token: gateway.token, body: { envelope, notification: envelope, uploadId: 'delete-ack' } });
    await relay.request('/v1/commands', { method: 'POST', token: client.token, body: { envelope, targetDeviceId: gateway.device.id } });
    await delay(30); outsideEvents.events.length = 0;
    assert.equal((await relay.request('/v1/bridges/isolated-bridge', { method: 'DELETE', token: outsider.token })).status, 401);
    assert.equal((await relay.request('/v1/bridges/isolated-bridge', { method: 'DELETE', owner: true })).status, 200);
    await Promise.all([gatewayEvents.closed, clientEvents.closed]);
    for (const token of [gateway.token, client.token]) assert.equal((await relay.request('/v1/devices', { token })).status, 401);
    assert.equal((await relay.request('/v1/devices', { token: outsider.token })).status, 200);
    const status = await (await relay.request('/v1/admin/status', { owner: true })).json();
    assert.equal(status.counts.bridges, 1); assert.equal(status.counts.devices, 1);
    for (const field of ['commands','encryptedMessages','uploadReceipts','pendingPushes','pushSubscriptions']) assert.equal(status.counts[field], 0, field);
    assert.equal((await (await relay.request('/v1/admin/debug/self-test', { method: 'POST', owner: true })).json()).ok, true);
    assert.equal(outsideEvents.events.length, 0);
  } finally { streams.forEach(item => item.stop()); await relay.stop(); }
});

test('admin SSE is owner-authenticated and receives mutation/expiry hints without a fetch feedback loop', async () => {
  const relay = await startRelay({ SIM_BRIDGE_TRANSIENT_TTL_MS: '100' }); let admin;
  try {
    assert.equal((await relay.request('/v1/admin/events')).status, 401);
    admin = await stream(relay, null, true);
    const gateway = await relay.create(); const client = await relay.join(); await admin.wait('status');
    await delay(30); // Consume both enrollment hints before testing read-only traffic.
    admin.events.length = 0;
    for (let i = 0; i < 5; i++) await relay.request('/v1/admin/status', { owner: true });
    await delay(30); assert.equal(admin.events.length, 0);
    await relay.request('/v1/commands', { method: 'POST', token: client.token, body: { envelope, targetDeviceId: gateway.device.id } });
    await admin.wait('status'); admin.events.length = 0;
    await delay(150); await admin.wait('status');
    assert.equal((await (await relay.request('/v1/admin/status', { owner: true })).json()).counts.commands, 0);
  } finally { admin?.stop(); await relay.stop(); }
});

test('stream backpressure coalesces hints, heartbeat never adds fetch events, and cleanup removes listeners', async () => {
  class Response extends EventEmitter {
    frames = []; accepted = true; ended = false;
    writeHead() {} flushHeaders() {}
    write(frame) { this.frames.push(frame); return this.accepted; }
    end() { this.ended = true; }
  }
  const presence = []; const events = createEventStreams({ heartbeatMs: 10, blockedMs: 30, maxPerDevice: 1, onPresence: (...args) => presence.push(args) });
  const device = { id: 'synthetic', bridgeId: 'bridge', capabilities: {} }; const response = new Response();
  assert.equal(events.open(response, device, {}), true);
  await delay(15); assert.ok(response.frames.some(frame => frame.startsWith(': heartbeat')));
  assert.equal(response.frames.filter(frame => frame.startsWith('data:')).length, 1);
  response.accepted = false; events.emit('bridge', 'messages');
  for (let i = 0; i < 100; i++) events.emit('bridge', 'messages');
  assert.equal(response.frames.filter(frame => frame.includes('messages')).length, 1);
  response.accepted = true; response.emit('drain');
  assert.equal(response.frames.filter(frame => frame.includes('messages')).length, 2);
  response.accepted = false; events.emit('bridge', 'commands', device.id);
  await delay(45); assert.equal(events.size, 0); assert.equal(response.ended, true);
  assert.equal(response.listenerCount('drain'), 0); assert.equal(response.listenerCount('close'), 0); assert.equal(response.listenerCount('error'), 0);
  assert.deepEqual(presence, [[device.id, true],[device.id, false]]);
  events.stop();
});

// On Cloudflare the edge parses HTTP before the Worker runs.
test('malformed absolute request targets cannot crash the RAM-only relay', { skip: workerTarget }, async () => {
  const relay = await startRelay();
  try {
    const port = Number(new URL(relay.base).port);
    const response = await new Promise((resolve, reject) => {
      const socket = createConnection({ host: '127.0.0.1', port });
      let data = '';
      socket.on('error', reject);
      socket.on('data', chunk => { data += chunk; });
      socket.on('end', () => resolve(data));
      socket.on('connect', () => socket.write('GET http://[ HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n'));
    });
    assert.match(response, /^HTTP\/1\.1 400/);
    const gateway = await relay.create();
    assert.equal((await relay.request('/v1/devices', { token: gateway.token })).status, 200);
  } finally { await relay.stop(); }
});

test('bounded stream lifetime sends a reconnect hint, then releases presence', async () => {
  class Response extends EventEmitter {
    frames = []; ended = false;
    writeHead() {} flushHeaders() {}
    write(frame) { this.frames.push(frame); return true; }
    end() { this.ended = true; }
  }
  const presence = []; const events = createEventStreams({ heartbeatMs: 1000, maxStreamMs: 20, rotationGraceMs: 30, onPresence: (...args) => presence.push(args) });
  const response = new Response();
  assert.equal(events.open(response, { id: 'synthetic', bridgeId: 'bridge', capabilities: {} }, {}), true);
  await delay(30);
  assert.ok(response.frames.some(frame => frame.includes('"reconnect"')));
  assert.equal(response.ended, true);
  assert.equal(events.size, 0);
  // A client that never comes back is released only after the grace period.
  assert.equal(events.online('synthetic'), true);
  assert.deepEqual(presence, [['synthetic', true]]);
  await delay(40);
  assert.equal(events.online('synthetic'), false);
  assert.deepEqual(presence, [['synthetic', true], ['synthetic', false]]);
  events.stop();
});

test('a planned rotation that resumes announces no presence change', async () => {
  class Response extends EventEmitter {
    frames = []; ended = false;
    writeHead() {} flushHeaders() {}
    write(frame) { this.frames.push(frame); return true; }
    end() { this.ended = true; }
  }
  const presence = []; const device = { id: 'synthetic', bridgeId: 'bridge', capabilities: {} };
  const events = createEventStreams({ heartbeatMs: 1000, maxStreamMs: 20, rotationGraceMs: 200, onPresence: (...args) => presence.push(args) });
  assert.equal(events.open(new Response(), device, {}), true);
  await delay(30);
  const resumed = new Response();
  assert.equal(events.open(resumed, device, {}, undefined, true), true);
  assert.ok(resumed.frames.some(frame => frame.includes('"ready"')));
  // Observe for less than the resumed stream's own rotation plus its grace.
  await delay(100);
  assert.deepEqual(presence, [['synthetic', true]], 'the rotation is invisible to other devices');
  assert.equal(events.online('synthetic'), true);
  events.stop();
  // A resume marker cannot hide a device that was really offline.
  const fresh = createEventStreams({ heartbeatMs: 1000, onPresence: (...args) => presence.push(args) });
  assert.equal(fresh.open(new Response(), { id: 'other', bridgeId: 'bridge', capabilities: {} }, {}, undefined, true), true);
  assert.deepEqual(presence.at(-1), ['other', true]);
  fresh.stop();
});
