import { connect } from 'node:http2';
import { createPrivateKey, sign } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { TRANSIENT_TTL_MS } from './memory.mjs';

const APNS_IDLE_MS = 10 * 60_000;

/** Node APNs sender over a reused HTTP/2 connection per environment. */
export function createApnsSender(env = process.env, openSession = connect) {
  const values = [env.SIM_BRIDGE_APNS_KEY_PATH, env.SIM_BRIDGE_APNS_KEY_ID, env.SIM_BRIDGE_APNS_TEAM_ID];
  if (values.every(value => !value)) return null;
  if (values.some(value => !value)) throw new Error('All APNs key configuration values are required');
  const key = createPrivateKey(readFileSync(values[0]));
  if (key.asymmetricKeyType !== 'ec' || key.asymmetricKeyDetails?.namedCurve !== 'prime256v1') throw new Error('APNs requires a P-256 private key');
  const topic = env.SIM_BRIDGE_APNS_TOPIC || 'dev.renner.simbridge';
  let jwt, issued = 0;
  const authorization = () => {
    const now = Math.floor(Date.now() / 1000);
    if (!jwt || now - issued >= 3000) {
      issued = now;
      const header = Buffer.from(JSON.stringify({ alg: 'ES256', kid: values[1] })).toString('base64url');
      const claims = Buffer.from(JSON.stringify({ iss: values[2], iat: issued })).toString('base64url');
      const unsigned = `${header}.${claims}`;
      jwt = `${unsigned}.${sign('sha256', Buffer.from(unsigned), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url')}`;
    }
    return `bearer ${jwt}`;
  };
  const sessions = new Map();
  const discard = (origin, session) => {
    const entry = sessions.get(origin);
    if (entry?.session === session) { clearTimeout(entry.timer); sessions.delete(origin); }
    try { session.destroy(); } catch {}
  };
  const idle = (origin, session) => {
    const entry = sessions.get(origin);
    if (entry?.session !== session) { try { session.destroy(); } catch {} return; }
    clearTimeout(entry.timer);
    entry.timer = setTimeout(() => discard(origin, session), APNS_IDLE_MS);
    entry.timer.unref?.();
  };
  const sessionFor = origin => {
    const entry = sessions.get(origin);
    if (entry && !entry.session.closed && !entry.session.destroyed) { clearTimeout(entry.timer); return entry.session; }
    if (entry) discard(origin, entry.session);
    const session = openSession(origin);
    session.on?.('error', () => discard(origin, session));
    session.on?.('goaway', () => discard(origin, session));
    session.on?.('close', () => { if (sessions.get(origin)?.session === session) sessions.delete(origin); });
    sessions.set(origin, { session });
    return session;
  };
  return (subscription, payload, { signal } = {}) => new Promise(resolve => {
    const remaining = (subscription.expiresAt ?? Date.now() + TRANSIENT_TTL_MS) - Date.now();
    if (remaining <= 0 || signal?.aborted) { resolve({ expired: true }); return; }
    const origin = subscription.environment === 'sandbox' ? 'https://api.sandbox.push.apple.com' : 'https://api.push.apple.com';
    let session;
    try { session = sessionFor(origin); } catch { resolve({ retry: true }); return; }
    let settled = false;
    // A healthy connection is kept for the next push, as Apple asks; any
    // failure or timeout discards it so the next push reconnects cleanly.
    const finish = result => {
      if (settled) return; settled = true; clearTimeout(timeout); signal?.removeEventListener('abort', abort);
      session.removeListener?.('error', failed);
      if (result.ok || result.invalid) idle(origin, session); else discard(origin, session);
      resolve(result);
    };
    const failed = () => finish({ retry: true });
    const abort = () => finish({ expired: true });
    const timeout = setTimeout(() => finish({ retry: true }), Math.min(15000, remaining));
    signal?.addEventListener('abort', abort, { once: true });
    session.on('error', failed);
    let request;
    try {
      request = session.request({ ':method': 'POST', ':path': `/3/device/${subscription.token}`, authorization: authorization(), 'apns-topic': topic, 'apns-push-type': 'alert', 'apns-priority': '10', 'apns-expiration': String(Math.floor((subscription.expiresAt ?? Date.now() + TRANSIENT_TTL_MS) / 1000)) });
    } catch { finish({ retry: true }); return; }
    let status = 0, body = '';
    request.on('response', headers => { status = Number(headers[':status']); });
    request.on('data', chunk => { if (body.length < 4096) body += chunk.toString(); });
    request.on('error', () => finish({ retry: true }));
    request.on('end', () => {
      let reason;
      try { reason = JSON.parse(body).reason; } catch {}
      finish({ ok: status === 200, invalid: status === 410 || ['BadDeviceToken', 'DeviceTokenNotForTopic', 'Unregistered'].includes(reason), retry: status === 429 || status >= 500 || status === 0 });
    });
    request.end(payload);
  });
}

