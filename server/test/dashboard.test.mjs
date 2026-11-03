import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

const source = await readFile(new URL('../public/app.js', import.meta.url), 'utf8');
const settle = () => new Promise(resolve => setImmediate(resolve));

function dashboard({ eventStatus = 200, statusReply } = {}) {
  const nodes = new Map(), page = new Map(), calls = [], timers = new Map();
  const element = id => {
    if (!nodes.has(id)) nodes.set(id, {
      value: '', className: '', textContent: '', innerHTML: '', disabled: false,
      listeners: new Map(), classList: { add() {}, remove() {} },
      addEventListener(type, fn) { this.listeners.set(type, fn); },
    });
    return nodes.get(id);
  };
  const status = {
    relayName: 'Test relay', counts: { bridges: 0, devices: 0, gateways: 0,
      encryptedMessages: 0, pendingCommands: 0 }, uptimeSeconds: 1,
    protocolVersion: 2, version: 'test', security: { transport: 'tls' }, devices: [], bridges: [],
  };
  let writer;
  const stream = new ReadableStream({ start(controller) { writer = controller; } });
  const fetch = async (path, options = {}) => {
    calls.push({ path, options });
    if (path === '/v1/admin/events') {
      options.signal.addEventListener('abort', () => { try { writer.close(); } catch {} }, { once: true });
      return { status: eventStatus, ok: eventStatus === 200,
        headers: new Headers({ 'content-type': 'text/event-stream' }), body: stream };
    }
    if (path === '/v1/admin/status' && statusReply) await statusReply();
    return { status: 200, ok: true, json: async () => status };
  };
  const schedule = (fn, ms) => {
    const timer = setTimeout(() => { timers.delete(timer); fn(); }, ms);
    timer.unref(); timers.set(timer, ms); return timer;
  };
  const clear = timer => { timers.delete(timer); clearTimeout(timer); };
  vm.runInNewContext(source, {
    document: { getElementById: element, querySelector: () => element('health') },
    window: { addEventListener: (type, fn) => page.set(type, fn) },
    fetch, AbortController, TextDecoder, performance, queueMicrotask,
    setTimeout: schedule, clearTimeout: clear, confirm: () => false,
  });
  return {
    nodes, calls, timers,
    async unlock() { element('relayKey').value = 'disposable-owner-secret';
      await element('connectButton').listeners.get('click')(); await settle(); },
    async frame(value) { writer.enqueue(new TextEncoder().encode(value)); await settle(); await settle(); },
    async close() { page.get('pagehide')(); await settle(); for (const timer of timers.keys()) clear(timer); },
  };
}

test('owner dashboard uses header-authenticated events and never fetches on idle heartbeats', async () => {
  const ui = dashboard();
  try {
    await ui.unlock();
    const connection = ui.calls.find(call => call.path === '/v1/admin/events');
    assert.equal(connection.options.headers['x-relay-key'], 'disposable-owner-secret');
    assert.equal(connection.options.redirect, 'error');
    assert.equal(ui.nodes.get('storage').textContent, 'RAM only · gateway restores pairing');
    await ui.frame('data: {"type":"ready"}\n\n');
    const before = ui.calls.length;
    await ui.frame(': heartbeat\n\n: heartbeat\n\n');
    assert.equal(ui.calls.length, before);
    assert.equal(ui.nodes.get('healthLabel').textContent, 'Online · event connection');
    assert.ok([...ui.timers.values()].every(ms => ms === 45000 || ms === 2200));
    await ui.frame('data: {"type":"status"}\n\n');
    assert.equal(ui.calls.length, before + 1);
    assert.equal(ui.calls.at(-1).path, '/v1/admin/status');
  } finally { await ui.close(); }
});

test('owner authentication rejection stops reconnecting and requires unlocking again', async () => {
  const ui = dashboard({ eventStatus: 401 });
  try {
    await ui.unlock(); await settle();
    assert.equal(ui.calls.filter(call => call.path === '/v1/admin/events').length, 1);
    assert.ok([...ui.timers.values()].every(ms => ms === 2200));
    assert.match(ui.nodes.get('toast').textContent, /Owner access rejected/);
  } finally { await ui.close(); }
});

test('status changes arriving during a status fetch are coalesced without being dropped', async () => {
  let blocked = false, release;
  const ui = dashboard({ statusReply: () => blocked ? new Promise(resolve => { release = resolve; }) : undefined });
  try {
    await ui.unlock(); blocked = true;
    await ui.frame('data: {"type":"status"}\n\n');
    const before = ui.calls.length;
    await ui.frame('data: {"type":"status"}\n\ndata: {"type":"status"}\n\n');
    assert.equal(ui.calls.length, before);
    blocked = false; release(); await settle(); await settle();
    assert.equal(ui.calls.length, before + 1);
  } finally { await ui.close(); }
});
