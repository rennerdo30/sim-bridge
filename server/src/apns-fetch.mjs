import { TRANSIENT_TTL_MS } from './memory.mjs';

const APNS_TIMEOUT_MS = 15_000;
const JWT_LIFETIME_S = 3000;
const PERMANENT_TOKEN_FAILURES = ['BadDeviceToken', 'DeviceTokenNotForTopic', 'Unregistered'];

const base64url = bytes => btoa(String.fromCharCode(...new Uint8Array(bytes)))
  .replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
const text = value => base64url(new TextEncoder().encode(value));

/**
 * APNs sender for runtimes without node:http2, such as Cloudflare Workers.
 * The P-256 key is supplied as PEM text in SIM_BRIDGE_APNS_KEY (a secret),
 * because a Worker has no private file system. Returns null when push is not
 * configured; all key values must be configured together.
 */
export function createFetchApnsSender(env, request = fetch) {
  const values = [env.SIM_BRIDGE_APNS_KEY, env.SIM_BRIDGE_APNS_KEY_ID, env.SIM_BRIDGE_APNS_TEAM_ID];
  if (values.every(value => !value)) return null;
  if (values.some(value => !value)) throw new Error('All APNs key configuration values are required');
  const topic = env.SIM_BRIDGE_APNS_TOPIC || 'dev.renner.simbridge';
  const der = Uint8Array.from(atob(values[0].replace(/-----[^-]+-----/g, '').replace(/\s+/g, '')), c => c.charCodeAt(0));
  const key = crypto.subtle.importKey('pkcs8', der, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  let jwt, issued = 0;
  const authorization = async () => {
    const now = Math.floor(Date.now() / 1000);
    if (!jwt || now - issued >= JWT_LIFETIME_S) {
      const unsigned = `${text(JSON.stringify({ alg: 'ES256', kid: values[1] }))}.${text(JSON.stringify({ iss: values[2], iat: now }))}`;
      const signature = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, await key, new TextEncoder().encode(unsigned));
      jwt = `${unsigned}.${base64url(signature)}`;
      issued = now;
    }
    return `bearer ${jwt}`;
  };
  return async (subscription, payload, { signal } = {}) => {
    const expiresAt = subscription.expiresAt ?? Date.now() + TRANSIENT_TTL_MS;
    const remaining = expiresAt - Date.now();
    if (remaining <= 0 || signal?.aborted) return { expired: true };
    const origin = subscription.environment === 'sandbox' ? 'https://api.sandbox.push.apple.com' : 'https://api.push.apple.com';
    const timeout = AbortSignal.timeout(Math.min(APNS_TIMEOUT_MS, remaining));
    try {
      const response = await request(`${origin}/3/device/${subscription.token}`, {
        method: 'POST',
        headers: {
          authorization: await authorization(),
          'apns-topic': topic,
          'apns-push-type': 'alert',
          'apns-priority': '10',
          'apns-expiration': String(Math.floor(expiresAt / 1000)),
          'content-type': 'application/json',
        },
        body: payload,
        signal: signal ? AbortSignal.any([signal, timeout]) : timeout,
      });
      let reason;
      try { reason = (await response.json()).reason; } catch {}
      const status = response.status;
      return { ok: status === 200, invalid: status === 410 || PERMANENT_TOKEN_FAILURES.includes(reason), retry: status === 429 || status >= 500 };
    } catch {
      return signal?.aborted ? { expired: true } : { retry: true };
    }
  };
}
