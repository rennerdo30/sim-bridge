import { randomUUID } from 'node:crypto';
import { TRANSIENT_TTL_MS } from './memory.mjs';

export const MAX_APNS_BYTES = 4096;
export const pushPayload = (encrypted, messageId) => ({
  aps: { alert: { title: 'New Sim Bridge message', body: 'Open Sim Bridge to view' }, 'mutable-content': 1, sound: 'default' },
  encrypted, messageId,
});
export function validNotification(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).length !== 4 ||
      value.v !== 1 || !['ciphertext', 'nonce', 'mac'].every(key => typeof value[key] === 'string' && /^[A-Za-z0-9_-]+={0,2}$/.test(value[key]))) return false;
  return Buffer.from(value.nonce, 'base64url').length === 12 && Buffer.from(value.mac, 'base64url').length === 16 &&
    Buffer.byteLength(JSON.stringify(pushPayload(value, '00000000-0000-0000-0000-000000000000'))) <= MAX_APNS_BYTES;
}

export function createPushQueue(database, sender, { now = Date.now, maxJobs = 2000,
  lifetimeMs = TRANSIENT_TTL_MS, onChange = () => {}, scheduleTimer = setTimeout, cancelTimer = clearTimeout } = {}) {
  database.exec(`CREATE TABLE IF NOT EXISTS push_subscriptions (
    device_id TEXT PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
    token TEXT NOT NULL, environment TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS push_jobs (
    id TEXT PRIMARY KEY, device_id TEXT NOT NULL REFERENCES push_subscriptions(device_id) ON DELETE CASCADE,
    payload TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, next_at INTEGER NOT NULL, created_at INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS push_jobs_due_idx ON push_jobs(next_at);`);
  let active = false, stopped = false, timer;
  lifetimeMs = Math.min(TRANSIENT_TTL_MS, Math.max(1, lifetimeMs));
  const inflight = new Map();
  const cancelCleared = () => {
    for (const [id, controller] of inflight) if (!database.prepare('SELECT id FROM push_jobs WHERE id = ?').get(id)) controller.abort();
  };
  const expire = () => {
    const result = database.prepare('DELETE FROM push_jobs WHERE created_at <= ?').run(now() - lifetimeMs);
    if (result.changes) { cancelCleared(); onChange(); }
  };
  const schedule = () => {
    cancelTimer(timer);
    timer = undefined;
    if (stopped) return;
    const next = database.prepare(sender && !active
      ? 'SELECT MIN(MIN(next_at, created_at + ?)) AS at FROM push_jobs'
      : 'SELECT MIN(created_at + ?) AS at FROM push_jobs').get(lifetimeMs).at;
    if (next === null) return;
    timer = scheduleTimer(() => {
      timer = undefined; expire();
      if (active) schedule(); else drain().catch(() => {});
    }, Math.max(0, next - now()));
    timer?.unref?.();
  };
  const register = (deviceId, token, environment) => {
    database.transaction(() => {
      database.prepare('DELETE FROM push_jobs WHERE device_id = ?').run(deviceId);
      database.prepare('INSERT INTO push_subscriptions VALUES (?, ?, ?) ON CONFLICT(device_id) DO UPDATE SET token = excluded.token, environment = excluded.environment').run(deviceId, token.toLowerCase(), environment);
    })();
    cancelCleared();
    schedule();
    onChange();
  };
  const enqueue = (bridgeId, encrypted, messageId) => {
    database.transaction(() => {
      const payload = JSON.stringify(pushPayload(encrypted, messageId));
      const timestamp = now();
      for (const row of database.prepare('SELECT p.device_id FROM push_subscriptions p JOIN devices d ON d.id = p.device_id WHERE d.bridge_id = ?').all(bridgeId)) {
        database.prepare('INSERT INTO push_jobs (id, device_id, payload, next_at, created_at) VALUES (?, ?, ?, ?, ?)').run(randomUUID(), row.device_id, payload, timestamp, timestamp);
      }
      database.prepare('DELETE FROM push_jobs WHERE id IN (SELECT id FROM push_jobs ORDER BY created_at DESC, rowid DESC LIMIT -1 OFFSET ?)').run(maxJobs);
    })();
    cancelCleared();
    schedule();
    onChange();
  };
  const drain = async () => {
    if (active || stopped) return;
    cancelTimer(timer); timer = undefined;
    active = true;
    try {
      expire();
      schedule(); // Expiry remains armed even while delivery awaits HTTP/2.
      if (!sender) return;
      const jobs = database.prepare('SELECT j.*, p.token, p.environment FROM push_jobs j JOIN push_subscriptions p ON p.device_id = j.device_id WHERE next_at <= ? ORDER BY next_at LIMIT 20').all(now());
      for (const job of jobs) {
        if (stopped) break;
        if (!database.prepare('SELECT id FROM push_jobs WHERE id = ?').get(job.id)) continue;
        if (now() - job.created_at >= lifetimeMs) {
          database.prepare('DELETE FROM push_jobs WHERE id = ?').run(job.id); continue;
        }
        let result;
        const controller = new AbortController();
        inflight.set(job.id, controller);
        try { result = await sender({ ...job, expiresAt: job.created_at + lifetimeMs }, job.payload, { signal: controller.signal }); }
        catch { result = { retry: true }; }
        finally { inflight.delete(job.id); }
        if (stopped) break;
        // Replacing/revoking a subscription while HTTP/2 delivery is in flight
        // must never remove its replacement or resurrect cleared work.
        if (!database.prepare('SELECT id FROM push_jobs WHERE id = ?').get(job.id)) continue;
        if (result.invalid) database.prepare('DELETE FROM push_subscriptions WHERE device_id = ? AND token = ? AND environment = ?').run(job.device_id, job.token, job.environment);
        if (result.retry && job.attempts < 7 && now() - job.created_at < lifetimeMs) {
          database.prepare('UPDATE push_jobs SET attempts = attempts + 1, next_at = ? WHERE id = ?').run(now() + Math.min(300000, 5000 * 2 ** job.attempts), job.id);
        } else database.prepare('DELETE FROM push_jobs WHERE id = ?').run(job.id);
      }
    } finally { active = false; schedule(); onChange(); }
  };
  return { register, enqueue, drain, expire, changed: () => { cancelCleared(); schedule(); },
    stop: () => { stopped = true; cancelTimer(timer); for (const controller of inflight.values()) controller.abort(); }, enabled: Boolean(sender) };
}
