import { createHash, createHmac, createPublicKey, randomBytes, randomUUID, timingSafeEqual, verify } from 'node:crypto';

const digest = value => createHash('sha256').update(value).digest('hex');
const encodedBytes = (value, size) => {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]+$/.test(value)) return null;
  const bytes = Buffer.from(value, 'base64url');
  return bytes.length === size && bytes.toString('base64url') === value ? bytes : null;
};
export const validDevicePublicKey = value => Boolean(encodedBytes(value, 32));

// The certificate key is independent of every bridge content/enrollment key.
// Changing operator configuration intentionally invalidates old certificates.
export function createIdentityAuthority(accessKey, { now = Date.now, challengeMs = 30_000, maxChallenges = 1000, maxEnrollmentChallenges = 200, maxPerSubject = 8 } = {}) {
  const key = createHmac('sha256', accessKey).update('simbridge/identity-certificate-key/v1').digest();
  const issuer = digest(key);
  const bootId = randomUUID();
  const challenges = new Map();
  let timer;
  const sweep = () => {
    for (const [id, item] of challenges) if (item.expiresAt <= now()) challenges.delete(id);
    clearTimeout(timer);
    if (challenges.size) {
      let next = Infinity;
      for (const item of challenges.values()) next = Math.min(next, item.expiresAt);
      timer = setTimeout(sweep, Math.max(1, next - now()));
      timer.unref?.();
    }
  };
  const mac = body => createHmac('sha256', key).update('simbridge/identity-certificate/v1\n').update(body).digest();
  const issue = claims => {
    const value = { ...claims, v: 1, issuer };
    if (!validClaims(value)) throw new Error('Invalid identity claims');
    const body = Buffer.from(JSON.stringify(value)).toString('base64url');
    return `${body}.${mac(body).toString('base64url')}`;
  };
  const inspect = certificate => {
    if (typeof certificate !== 'string' || certificate.length > 4096) return null;
    const parts = certificate.split('.');
    if (parts.length !== 2 || !/^[A-Za-z0-9_-]+$/.test(parts[0])) return null;
    const supplied = encodedBytes(parts[1], 32);
    if (!supplied || !timingSafeEqual(supplied, mac(parts[0]))) return null;
    try {
      const bytes = Buffer.from(parts[0], 'base64url');
      if (bytes.toString('base64url') !== parts[0]) return null;
      const claims = JSON.parse(bytes.toString('utf8'));
      return validClaims(claims) && claims.issuer === issuer ? claims : null;
    } catch { return null; }
  };
  // Unauthenticated enrollment challenges draw from their own smaller pool, so
  // anyone holding a throwaway key cannot exhaust the slots that certified
  // gateways need for resume, bootstrap and policy commits.
  const makeChallenge = (claims, binding, operation, payloadJson, context, enrollment = false) => {
    sweep();
    if (!claims || typeof payloadJson !== 'string' || Buffer.byteLength(payloadJson) > 60 * 1024) return null;
    let pooled = 0, subject = 0;
    for (const item of challenges.values()) {
      if (item.enrollment === enrollment) pooled++;
      if (item.binding === binding) subject++;
    }
    if (challenges.size >= maxChallenges + maxEnrollmentChallenges || pooled >= (enrollment ? maxEnrollmentChallenges : maxChallenges) || subject >= maxPerSubject) return { limited: true };
    const challengeId = randomUUID(), nonce = randomBytes(32).toString('base64url');
    const certificateHash = digest(binding), payloadHash = digest(payloadJson);
    const signingPayload = JSON.stringify(['simbridge/pop/v1', bootId, challengeId, nonce, operation, certificateHash, payloadHash]);
    const item = { challengeId, nonce, bootId, expiresAt: now() + challengeMs, operation, certificateHash, payloadHash, signingPayload, claims, context, enrollment, binding };
    challenges.set(challengeId, item);
    sweep();
    return { challengeId, nonce, bootId, expiresAt: item.expiresAt, operation, certificateHash, payloadHash, signingPayload };
  };
  const challenge = (certificate, operation, payloadJson = '', context) => ['resume', 'bootstrap', 'policy_commit'].includes(operation)
    ? makeChallenge(inspect(certificate), certificate, operation, payloadJson, context) : null;
  const enrollmentChallenge = (publicKey, operation, payloadJson = '') => validDevicePublicKey(publicKey) && ['create', 'join', 'upgrade'].includes(operation)
    ? makeChallenge({ publicKey, deviceId: `pending:${digest(publicKey)}` }, publicKey, operation, payloadJson, undefined, true) : null;
  const consume = ({ certificate, devicePublicKey, challengeId, signature, payloadJson = '' }, operation) => {
    const item = challenges.get(challengeId);
    // A failed proof consumes its challenge too; it cannot be ground or replayed.
    challenges.delete(challengeId); sweep();
    if (!item || item.expiresAt <= now() || item.operation !== operation || typeof payloadJson !== 'string' ||
        item.certificateHash !== digest(certificate || devicePublicKey || '') || item.payloadHash !== digest(payloadJson)) return null;
    const bytes = encodedBytes(signature, 64);
    if (!bytes) return null;
    try {
      const publicKey = createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), encodedBytes(item.claims.publicKey, 32)]), type: 'spki', format: 'der' });
      return verify(null, Buffer.from(item.signingPayload), publicKey, bytes) ? { ...item.claims, challengeContext: item.context } : null;
    } catch { return null; }
  };
  return { issue, inspect, challenge, enrollmentChallenge, consume, issuer, bootId,
    revoke(deviceId) { for (const [id, item] of challenges) if (item.claims.deviceId === deviceId) challenges.delete(id); sweep(); },
    stop() { clearTimeout(timer); challenges.clear(); }, get size() { return challenges.size; } };
}

function validClaims(value) {
  return value && value.v === 1 && typeof value.issuer === 'string' && /^[0-9a-f]{64}$/.test(value.issuer) &&
    ['bridgeId', 'incarnation', 'deviceId'].every(key => typeof value[key] === 'string' && value[key].length > 0 && value[key].length <= 128) &&
    validDevicePublicKey(value.publicKey) && typeof value.authority === 'boolean' && typeof value.smsGateway === 'boolean' && typeof value.isOwner === 'boolean' &&
    (!value.authority || (value.smsGateway && value.isOwner));
}
