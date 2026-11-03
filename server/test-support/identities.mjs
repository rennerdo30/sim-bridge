import { generateKeyPairSync, sign } from 'node:crypto';

export function newIdentity() {
  const key = generateKeyPairSync('ed25519');
  return { privateKey: key.privateKey, publicKey: key.publicKey.export({ type: 'spki', format: 'der' }).subarray(-32).toString('base64url') };
}
export async function identityProof(request, identity, operation, payloadJson = '', certificate) {
  const response = await request('/v1/auth/challenge', { method: 'POST', body: {
    ...(certificate ? { certificate } : { devicePublicKey: identity.publicKey }), operation, payloadJson } });
  if (response.status !== 200) throw new Error(`Identity challenge rejected (${response.status})`);
  const challenge = await response.json();
  return { ...(certificate ? { certificate } : { devicePublicKey: identity.publicKey }), challengeId: challenge.challengeId, payloadJson,
    signature: sign(null, Buffer.from(challenge.signingPayload), identity.privateKey).toString('base64url') };
}
export async function enroll(request, identity, operation, payload, options = {}) {
  const body = await identityProof(request, identity, operation, JSON.stringify({ ...payload, devicePublicKey: identity.publicKey }));
  return request(operation === 'create' ? '/v1/bridges' : operation === 'join' ? '/v1/bridges/join' : '/v1/auth/upgrade', { ...options, method: 'POST', body });
}
export async function commitPolicy(request, gateway, proposal) {
  // This test variable stands in for an atomic durable gateway write/readback.
  gateway.policyJson = proposal.policyJson;
  const payloadJson = JSON.stringify({ proposalId: proposal.proposalId, policyJson: proposal.policyJson });
  const body = await identityProof(request, gateway.identity, 'policy_commit', payloadJson, gateway.certificate);
  return request('/v1/auth/policy/commit', { method: 'POST', body });
}
