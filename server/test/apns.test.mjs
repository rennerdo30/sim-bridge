import assert from 'node:assert/strict';
import test from 'node:test';
import Database from 'better-sqlite3';
import { generateKeyPairSync } from 'node:crypto';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { EventEmitter } from 'node:events';
import { createPushQueue, validNotification } from '../src/apns.mjs';
import { createApnsSender } from '../src/apns-http2.mjs';
const encrypted = { v: 1, ciphertext: 'AAAA', nonce: 'AAAAAAAAAAAAAAAA', mac: 'AAAAAAAAAAAAAAAAAAAAAA==' };
const count = (db, table) => db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get().n;
function fixture(t, sender = null, options = {}) {
  const db = new Database(':memory:'); db.pragma('foreign_keys = ON');
  db.exec("CREATE TABLE devices (id TEXT PRIMARY KEY, bridge_id TEXT); INSERT INTO devices VALUES ('client', 'bridge'), ('other', 'another');");
  let clock = 1000, scheduled = 0; const timers = new Map();
  const queue = createPushQueue(db, sender, { ...options, now: () => clock,
    scheduleTimer(callback, delay) { scheduled++; const handle = { unref() {} }; timers.set(handle, { callback, at: clock + delay }); return handle; },
    cancelTimer: handle => timers.delete(handle),
  });
  t.after(() => { queue.stop(); db.close(); });
  return { db, queue, timers, get scheduled() { return scheduled; },
    async advance(ms) { clock += ms; for (const [handle, timer] of [...timers]) if (timer.at <= clock && timers.delete(handle)) timer.callback(); for (let i = 0; i < 4; i++) await Promise.resolve(); },
  };
}
const register = queue => queue.register('client', 'a'.repeat(64), 'sandbox');
function senderEnv(t) {
  const dir = mkdtempSync(join(tmpdir(), 'sim-bridge-apns-key-')); const path = join(dir, 'synthetic.p8');
  const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  writeFileSync(path, privateKey.export({ type: 'pkcs8', format: 'pem' }), { mode: 0o600 });
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return { SIM_BRIDGE_APNS_KEY_PATH: path, SIM_BRIDGE_APNS_KEY_ID: 'synthetic', SIM_BRIDGE_APNS_TEAM_ID: 'synthetic' };
}
function deferredSender(capture, result = { retry: true }) {
  return async (_sub, _payload, { signal }) => new Promise(resolve => {
    capture.signal = signal; signal.addEventListener('abort', () => resolve(result), { once: true });
  });
}

test('notification rejects wrong AES-GCM lengths, plaintext fields and oversized payload', () => {
  assert.equal(validNotification(encrypted), true);
  for (const value of [null, { ...encrypted, v: 2 }, { ...encrypted, nonce: 'AAAA' }, { ...encrypted, mac: 'AAAA' }, { ...encrypted, sender: 'plaintext' }, { ...encrypted, ciphertext: 'A'.repeat(4096) }, { ...encrypted, nonce: '!'.repeat(16) }]) assert.equal(validNotification(value), false);
});

test('in-memory retry stays bridge-scoped; invalid token cleanup preserves another bridge', async t => {
  const calls = [];
  const f = fixture(t, async (sub, payload) => { calls.push({ sub, payload: JSON.parse(payload) }); return calls.length === 1 ? { retry: true } : { invalid: true }; });
  register(f.queue); f.queue.register('other', 'b'.repeat(64), 'production');
  f.queue.enqueue('bridge', encrypted, 'message'); await f.queue.drain();
  assert.equal(calls.length, 1); assert.equal(calls[0].sub.token, 'a'.repeat(64));
  assert.equal(calls[0].payload.messageId, 'message'); assert.equal(calls[0].sub.expiresAt, 301000);
  assert.deepEqual(f.db.prepare('SELECT attempts, next_at FROM push_jobs').get(), { attempts: 1, next_at: 6000 });
  await f.advance(4999); assert.equal(calls.length, 1); await f.advance(1); assert.equal(calls.length, 2);
  assert.equal(count(f.db, 'push_jobs'), 0);
  assert.deepEqual(f.db.prepare('SELECT device_id FROM push_subscriptions').all(), [{ device_id: 'other' }]); assert.equal(f.timers.size, 0);
});

test('idle queue schedules nothing and successful due work returns to idle', async t => {
  let sends = 0; const f = fixture(t, async () => { sends++; return { ok: true }; });
  assert.equal(f.scheduled, 0); register(f.queue); assert.equal(f.scheduled, 0);
  f.queue.enqueue('bridge', encrypted, 'message'); assert.equal(f.timers.size, 1);
  await f.advance(0); assert.equal(sends, 1); assert.equal(count(f.db, 'push_jobs'), 0); assert.equal(f.timers.size, 0);
  const scheduled = f.scheduled; await f.advance(86400000); assert.equal(f.scheduled, scheduled); assert.equal(sends, 1);
});

test('disabled sender expires previews; lifetime cannot exceed five minutes', async t => {
  const f = fixture(t, null, { lifetimeMs: 86400000 }); register(f.queue); f.queue.enqueue('bridge', encrypted, 'message');
  assert.equal(f.queue.enabled, false); assert.equal([...f.timers.values()][0].at, 301000);
  await f.advance(299999); assert.equal(count(f.db, 'push_jobs'), 1);
  await f.advance(1); assert.equal(count(f.db, 'push_jobs'), 0); assert.equal(f.timers.size, 0); assert.equal(count(f.db, 'push_subscriptions'), 1);
});

test('count cap drops oldest jobs and device revocation cascades to jobs/subscription', t => {
  const f = fixture(t, null, { maxJobs: 2 }); register(f.queue);
  for (let i = 0; i < 4; i++) f.queue.enqueue('bridge', encrypted, String(i));
  assert.deepEqual(f.db.prepare('SELECT payload FROM push_jobs ORDER BY rowid').all().map(row => JSON.parse(row.payload).messageId), ['2', '3']);
  f.db.prepare("DELETE FROM devices WHERE id = 'client'").run(); f.queue.changed();
  assert.equal(count(f.db, 'push_jobs'), 0); assert.equal(count(f.db, 'push_subscriptions'), 0); assert.equal(f.timers.size, 0);
});

test('expiry aborts an in-flight job while delivery awaits a response', async t => {
  const capture = {}; const f = fixture(t, deferredSender(capture), { lifetimeMs: 50 });
  register(f.queue); f.queue.enqueue('bridge', encrypted, 'message'); const delivery = f.queue.drain();
  assert.equal(capture.signal.aborted, false); await f.advance(49); assert.equal(capture.signal.aborted, false);
  await f.advance(1); await delivery; assert.equal(capture.signal.aborted, true);
  assert.equal(count(f.db, 'push_jobs'), 0); assert.equal(f.timers.size, 0);
});

test('revocation aborts delivery without resurrecting cleared work', async t => {
  const capture = {}; const f = fixture(t, deferredSender(capture));
  register(f.queue); f.queue.enqueue('bridge', encrypted, 'message'); const delivery = f.queue.drain();
  f.db.prepare("DELETE FROM devices WHERE id = 'client'").run(); f.queue.changed(); await delivery;
  assert.equal(capture.signal.aborted, true); assert.equal(count(f.db, 'push_jobs'), 0); assert.equal(count(f.db, 'push_subscriptions'), 0);
});

test('subscription replacement cancels delivery without deleting the replacement', async t => {
  const capture = {}; const f = fixture(t, deferredSender(capture, { invalid: true }));
  register(f.queue); f.queue.enqueue('bridge', encrypted, 'message'); const delivery = f.queue.drain();
  f.queue.register('client', 'c'.repeat(64), 'production'); assert.equal(capture.signal.aborted, true); await delivery;
  assert.deepEqual(f.db.prepare('SELECT token, environment FROM push_subscriptions').get(), { token: 'c'.repeat(64), environment: 'production' });
  assert.equal(count(f.db, 'push_jobs'), 0);
});

test('queue stop aborts active delivery and cancels scheduled callbacks', async t => {
  const capture = {}; const f = fixture(t, deferredSender(capture));
  register(f.queue); f.queue.enqueue('bridge', encrypted, 'message'); const delivery = f.queue.drain();
  f.queue.stop(); await delivery; assert.equal(capture.signal.aborted, true); assert.equal(f.timers.size, 0);
});

test('count pruning aborts old in-flight work while retaining the newer preview', async t => {
  const capture = {}; let sends = 0;
  const f = fixture(t, async (sub, payload, options) => {
    sends++;
    if (sends === 1) return deferredSender(capture)(sub, payload, options);
    assert.equal(JSON.parse(payload).messageId, 'new');
    return { ok: true };
  }, { maxJobs: 1 });
  register(f.queue); f.queue.enqueue('bridge', encrypted, 'old'); const delivery = f.queue.drain();
  f.queue.enqueue('bridge', encrypted, 'new'); assert.equal(capture.signal.aborted, true); await delivery;
  assert.equal(count(f.db, 'push_jobs'), 1); await f.advance(0);
  assert.equal(sends, 2); assert.equal(count(f.db, 'push_jobs'), 0);
});

test('APNs sender opens no connection for expired or aborted work', async t => {
  let opened = 0; const sender = createApnsSender(senderEnv(t), () => { opened++; throw new Error('No networking allowed'); });
  const sub = { token: 'a'.repeat(64), environment: 'sandbox', expiresAt: Date.now() - 1 };
  assert.deepEqual(await sender(sub, '{}'), { expired: true }); const controller = new AbortController(); controller.abort();
  assert.deepEqual(await sender({ ...sub, expiresAt: Date.now() + 1000 }, '{}', { signal: controller.signal }), { expired: true }); assert.equal(opened, 0);
});

test('APNs socket timeout and expiration header respect preview deadline', async t => {
  t.mock.timers.enable({ apis: ['setTimeout', 'Date'], now: 10000 });
  let destroyed = false, headers, body; const request = new EventEmitter(); request.end = value => { body = value; };
  const session = new EventEmitter(); session.request = value => { headers = value; return request; }; session.destroy = () => { destroyed = true; };
  const sender = createApnsSender(senderEnv(t), origin => { assert.equal(origin, 'https://api.sandbox.push.apple.com'); return session; });
  const delivery = sender({ token: 'a'.repeat(64), environment: 'sandbox', expiresAt: 10050 }, '{}');
  assert.equal(headers['apns-expiration'], '10'); assert.match(headers.authorization, /^bearer [A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/); assert.equal(body, '{}');
  t.mock.timers.tick(49); assert.equal(destroyed, false); t.mock.timers.tick(1);
  assert.deepEqual(await delivery, { retry: true }); assert.equal(destroyed, true);
});

test('APNs sender abort closes the in-flight HTTP/2 session', async t => {
  let destroyed = false; const request = new EventEmitter(); request.end = () => {};
  const session = new EventEmitter(); session.request = () => request; session.destroy = () => { destroyed = true; };
  const sender = createApnsSender(senderEnv(t), () => session); const controller = new AbortController();
  const delivery = sender({ token: 'a'.repeat(64), environment: 'production', expiresAt: Date.now() + 1000 }, '{}', { signal: controller.signal });
  assert.equal(destroyed, false); controller.abort();
  assert.deepEqual(await delivery, { expired: true }); assert.equal(destroyed, true);
});
