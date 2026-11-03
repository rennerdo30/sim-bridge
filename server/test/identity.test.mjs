import assert from 'node:assert/strict';
import test from 'node:test';
import { generateKeyPairSync, sign } from 'node:crypto';
import { createIdentityAuthority } from '../src/identity.mjs';

const identity = () => {
  const keys = generateKeyPairSync('ed25519');
  return { ...keys, raw: keys.publicKey.export({ type: 'spki', format: 'der' }).subarray(-32).toString('base64url') };
};
const claims = key => ({ bridgeId: 'synthetic-bridge', incarnation: 'synthetic-incarnation', deviceId: 'synthetic-device',
  publicKey: key.raw, smsGateway: true, isOwner: true, authority: true });
const proof = (authority, certificate, key, operation, payloadJson = '') => {
  const challenge = authority.challenge(certificate, operation, payloadJson);
  return { certificate, challengeId: challenge.challengeId, payloadJson,
    signature: sign(null, Buffer.from(challenge.signingPayload), key.privateKey).toString('base64url') };
};

test('identity certificates survive a process boot only with stable operator configuration and retain immutable claims', () => {
  const key = identity(), first = createIdentityAuthority('synthetic-owner-configuration');
  const second = createIdentityAuthority('synthetic-owner-configuration'), changed = createIdentityAuthority('different-owner-configuration');
  const certificate = first.issue(claims(key));
  assert.deepEqual(second.inspect(certificate), first.inspect(certificate));
  assert.equal(changed.inspect(certificate), null);
  assert.equal(first.inspect(certificate + 'A'), null);
  const body = JSON.parse(Buffer.from(certificate.split('.')[0], 'base64url'));
  body.authority = false;
  assert.equal(first.inspect(Buffer.from(JSON.stringify(body)).toString('base64url') + '.' + certificate.split('.')[1]), null);
  assert.throws(() => first.issue({ ...claims(key), smsGateway: false }));
  first.stop(); second.stop(); changed.stop();
});

test('device proofs bind exact payload bytes, operation, certificate, fresh boot and single-use challenge', () => {
  const key = identity(), attacker = identity(), authority = createIdentityAuthority('synthetic-owner-configuration');
  const certificate = authority.issue(claims(key));
  const valid = proof(authority, certificate, key, 'resume');
  assert.equal(authority.consume(valid, 'resume').deviceId, 'synthetic-device');
  assert.equal(authority.consume(valid, 'resume'), null);
  const forged = proof(authority, certificate, attacker, 'resume');
  assert.equal(authority.consume(forged, 'resume'), null);
  const bound = proof(authority, certificate, key, 'bootstrap', '{"revision":4}');
  assert.equal(authority.consume({ ...bound, payloadJson: '{"revision":3}' }, 'bootstrap'), null);
  const wrongOperation = proof(authority, certificate, key, 'resume');
  assert.equal(authority.consume(wrongOperation, 'bootstrap'), null);
  const oldBoot = proof(authority, certificate, key, 'resume');
  const next = createIdentityAuthority('synthetic-owner-configuration');
  assert.equal(next.consume(oldBoot, 'resume'), null);
  authority.stop(); next.stop();
});

test('proof challenges expire, are bounded and disappear when their device is revoked', () => {
  let now = 0;
  const key = identity(), authority = createIdentityAuthority('synthetic-owner-configuration', { now: () => now, maxChallenges: 1 });
  const certificate = authority.issue(claims(key));
  const expired = proof(authority, certificate, key, 'resume');
  assert.deepEqual(authority.challenge(certificate, 'resume'), { limited: true });
  now = 30_000;
  assert.equal(authority.consume(expired, 'resume'), null);
  const revoked = proof(authority, certificate, key, 'resume');
  authority.revoke('synthetic-device');
  assert.equal(authority.consume(revoked, 'resume'), null);
  authority.stop();
});

test('unauthenticated enrollment challenges cannot starve certified gateway proofs', () => {
  const key = identity(), authority = createIdentityAuthority('synthetic-owner-configuration', { maxChallenges: 4, maxEnrollmentChallenges: 2, maxPerSubject: 2 });
  const certificate = authority.issue(claims(key));
  for (let i = 0; i < 2; i++) assert.ok(authority.enrollmentChallenge(identity().raw, 'join').challengeId);
  assert.deepEqual(authority.enrollmentChallenge(identity().raw, 'join'), { limited: true });
  assert.ok(authority.challenge(certificate, 'resume').challengeId);
  assert.ok(authority.challenge(certificate, 'resume').challengeId);
  assert.deepEqual(authority.challenge(certificate, 'resume'), { limited: true }, 'one subject cannot take every slot');
  assert.ok(authority.challenge(authority.issue({ ...claims(identity()), deviceId: 'second-device' }), 'resume').challengeId);
  authority.stop();
});
