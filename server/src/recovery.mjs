import { createHash, randomUUID } from 'node:crypto';
import { createIdentityAuthority, validDevicePublicKey } from './identity.mjs';

const hash = value => createHash('sha256').update(value).digest('hex');
const MAX_MEMBERS = 16;
const WAIT_MS = 8_000;

/** All state here is volatile. Only the gateway owns a durable policy ledger. */
export function createRecovery(context) {
  const { accessKey, bridges, devices, tokens, database, messages, commands, events,
    read, reply, authorizeOwner, clientAddress, publicDevice, capabilities, cleanName, secret,
    revokeDevice, eraseBridge, RequestError } = context;
  const identity = createIdentityAuthority(accessKey);
  const policies = new Map();
  const proposals = new Map();
  const fail = (status, code, message) => { const error = new RequestError(status, message); error.code = code; throw error; };
  const parse = value => { try { const parsed = JSON.parse(value); if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error(); return parsed; }
    catch { fail(400, 'invalid_policy', 'Invalid authorization payload'); } };
  const currentRevision = bridgeId => policies.get(bridgeId)?.policy.revision || 0;
  const session = (device, certificate = device.certificate) => {
    const previous = [...tokens].filter(([, id]) => id === device.id);
    // UI and headless engines can resume independently; retain at most eight
    // sessions for one identity, without an unbounded collection of hashes.
    for (const [tokenHash] of previous.slice(0, Math.max(0, previous.length - 7))) {
      events.revokeToken?.(tokenHash);
      tokens.delete(tokenHash); database.prepare('DELETE FROM device_tokens WHERE token_hash = ?').run(tokenHash);
    }
    const token = secret(); tokens.set(hash(token), device.id);
    database.prepare('INSERT INTO device_tokens (token_hash, device_id) VALUES (?, ?)').run(hash(token), device.id);
    return { bridge: { id: device.bridgeId, createdAt: bridges.get(device.bridgeId)?.createdAt }, device: publicDevice(device),
      token, certificate, bootId: identity.bootId, authorizationVersion: 2 };
  };
  const member = device => ({ certificate: device.certificate, name: device.name,
    capabilities: { ...capabilities(device.capabilities), smsGateway: device.capabilities.smsGateway === true } });
  const claimsFor = (device, bridge) => ({ bridgeId: bridge.id, incarnation: bridge.incarnation, deviceId: device.id,
    publicKey: device.publicKey, smsGateway: device.capabilities.smsGateway === true, isOwner: device.isOwner === true,
    authority: device.id === bridge.authorityDeviceId });
  const validatePolicy = (policyJson, actor) => {
    if (typeof policyJson !== 'string' || Buffer.byteLength(policyJson) > 60 * 1024) fail(400, 'invalid_policy', 'Invalid authorization policy');
    const policy = parse(policyJson);
    if (policy.v !== 1 || policy.issuer !== identity.issuer || policy.bridgeId !== actor.bridgeId || policy.incarnation !== actor.incarnation ||
        policy.authorityDeviceId !== actor.deviceId || !actor.authority || !actor.smsGateway || !Number.isSafeInteger(policy.revision) || policy.revision < 1 ||
        typeof policy.joinable !== 'boolean' || typeof policy.erased !== 'boolean' || !Array.isArray(policy.members) || policy.members.length > MAX_MEMBERS ||
        (!policy.erased && (!/^[0-9a-f]{64}$/.test(policy.inviteTokenHash || '') || typeof policy.createdAt !== 'string' || !Number.isFinite(Date.parse(policy.createdAt))))) {
      fail(400, 'invalid_policy', 'Invalid authorization policy');
    }
    const seen = new Set(), seenKeys = new Set(); let authorityFound = false;
    for (const entry of policy.members) {
      const claims = identity.inspect(entry.certificate);
      if (!claims || claims.bridgeId !== policy.bridgeId || claims.incarnation !== policy.incarnation || seen.has(claims.deviceId) || seenKeys.has(claims.publicKey) ||
          typeof entry.name !== 'string' || entry.name.length > 64 || !entry.capabilities || typeof entry.capabilities !== 'object' || Array.isArray(entry.capabilities) ||
          entry.capabilities.smsGateway !== claims.smsGateway || (claims.authority && claims.deviceId !== policy.authorityDeviceId)) fail(400, 'invalid_policy', 'Invalid policy member');
      seen.add(claims.deviceId);
      seenKeys.add(claims.publicKey);
      if (claims.authority && claims.deviceId === actor.deviceId && claims.publicKey === actor.publicKey) authorityFound = true;
    }
    if (policy.erased ? policy.members.length !== 0 || policy.joinable : !authorityFound) fail(400, 'invalid_policy', 'Policy authority is missing');
    return policy;
  };
  const applyState = (policyJson, policy) => {
    const old = policies.get(policy.bridgeId);
    if (old && old.policy.incarnation !== policy.incarnation) fail(409, 'device_revoked', 'Bridge incarnation is no longer active');
    if (policy.erased) {
      eraseBridge(policy.bridgeId);
      policies.set(policy.bridgeId, { policyJson, policy });
      identity.revoke(policy.authorityDeviceId);
      return;
    }
    // Preflight every identity before changing any relational or Map state.
    for (const entry of policy.members) {
      const claims = identity.inspect(entry.certificate), existing = devices.get(claims.deviceId);
      if (existing && (existing.bridgeId !== policy.bridgeId || (existing.publicKey && existing.publicKey !== claims.publicKey))) fail(409, 'invalid_policy', 'Conflicting policy identity');
    }
    let bridge = bridges.get(policy.bridgeId);
    if (!bridge) {
      bridge = { id: policy.bridgeId, createdAt: policy.createdAt, inviteTokenHash: policy.inviteTokenHash, joinable: policy.joinable };
      database.prepare('INSERT INTO bridges (id, invite_token, created_at, joinable) VALUES (?, ?, ?, ?)').run(bridge.id, bridge.inviteTokenHash, bridge.createdAt, bridge.joinable ? 1 : 0);
      bridges.set(bridge.id, bridge); messages.set(bridge.id, []); commands.set(bridge.id, []);
    }
    bridge.incarnation = policy.incarnation; bridge.authorityDeviceId = policy.authorityDeviceId;
    bridge.joinable = policy.joinable; bridge.inviteTokenHash = policy.inviteTokenHash;
    const accepted = new Set(policy.members.map(entry => identity.inspect(entry.certificate).deviceId));
    for (const device of [...devices.values()]) if (device.bridgeId === bridge.id && device.certificate && !accepted.has(device.id)) revokeDevice(device.id);
    for (const entry of policy.members) {
      const claims = identity.inspect(entry.certificate);
      let device = devices.get(claims.deviceId);
      if (device && (device.bridgeId !== bridge.id || (device.publicKey && device.publicKey !== claims.publicKey))) fail(409, 'invalid_policy', 'Conflicting policy identity');
      const fresh = !device;
      device ||= { id: claims.deviceId, bridgeId: bridge.id, lastSeenAt: new Date().toISOString() };
      Object.assign(device, { certificate: entry.certificate, publicKey: claims.publicKey, isOwner: claims.isOwner, name: entry.name,
        capabilities: { ...capabilities(entry.capabilities), smsGateway: claims.smsGateway } });
      devices.set(device.id, device);
      if (fresh) database.prepare('INSERT INTO devices (id, bridge_id, name, capabilities, last_seen_at, is_owner) VALUES (?, ?, ?, ?, ?, ?)')
        .run(device.id, bridge.id, device.name, JSON.stringify(device.capabilities), device.lastSeenAt, device.isOwner ? 1 : 0);
      else database.prepare('UPDATE devices SET name = ?, capabilities = ?, is_owner = ? WHERE id = ?').run(device.name, JSON.stringify(device.capabilities), device.isOwner ? 1 : 0, device.id);
    }
    database.prepare('UPDATE bridges SET joinable = ?, invite_token = ? WHERE id = ?').run(policy.joinable ? 1 : 0, policy.inviteTokenHash, bridge.id);
    policies.set(bridge.id, { policyJson, policy });
    events.emit(bridge.id, 'devices');
  };
  const apply = (policyJson, policy) => database.transaction(() => applyState(policyJson, policy))();
  const startProposal = (bridge, policy, key, initial = false) => {
    const previous = proposals.get(bridge.id);
    if (previous) { if (previous.key === key) return previous; fail(409, 'policy_pending', 'Gateway policy confirmation is pending'); }
    if (!initial && !events.online(bridge.authorityDeviceId)) fail(409, 'gateway_unavailable', 'Gateway must be online to commit this policy');
    let resolve;
    const completed = new Promise(done => { resolve = done; });
    const proposal = { id: randomUUID(), key, bridgeId: bridge.id, policyJson: JSON.stringify(policy), policy,
      baseRevision: currentRevision(bridge.id), resolve, completed };
    proposals.set(bridge.id, proposal);
    events.emit(bridge.id, 'policy', bridge.authorityDeviceId);
    return proposal;
  };
  const wait = async proposal => {
    let timer;
    try {
      const result = await Promise.race([proposal.completed, new Promise(resolve => { timer = setTimeout(() => resolve(false), WAIT_MS); timer.unref?.(); })]);
      if (!result) fail(409, 'policy_pending', 'Gateway policy confirmation is pending');
    } finally { clearTimeout(timer); }
  };
  const policyResponse = proposal => ({ policyJson: proposal.policyJson, proposalId: proposal.id, policyProposalId: proposal.id,
    baseRevision: proposal.baseRevision, revision: proposal.policy.revision });
  const enrollment = (input, operation) => {
    const payload = parse(input.payloadJson);
    const proof = identity.consume({ ...input, devicePublicKey: payload.devicePublicKey }, operation);
    if (!proof || proof.publicKey !== payload.devicePublicKey || !validDevicePublicKey(payload.devicePublicKey)) fail(401, 'invalid_identity_proof', 'Device identity proof was rejected');
    return payload;
  };
  const assertActive = claims => {
    const entry = policies.get(claims.bridgeId);
    if (!entry) fail(409, 'pairing_recovery_pending', 'Waiting for gateway pairing recovery');
    if (entry.policy.erased || entry.policy.incarnation !== claims.incarnation || !entry.policy.members.some(item => {
      const current = identity.inspect(item.certificate);
      return current && ['deviceId', 'publicKey', 'smsGateway', 'isOwner', 'authority'].every(field => current[field] === claims[field]);
    })) {
      fail(401, 'device_revoked', 'Device authorization was revoked');
    }
    if (proposals.has(claims.bridgeId)) fail(409, 'policy_pending', 'Gateway policy confirmation is pending');
    return devices.get(claims.deviceId);
  };
  const verifyProof = (input, operation) => {
    const claims = identity.consume(input, operation);
    if (!claims) fail(401, 'invalid_identity_proof', 'Device identity proof was rejected');
    if (claims.challengeContext !== currentRevision(claims.bridgeId)) fail(409, 'policy_pending', 'Authorization policy changed; obtain a fresh challenge');
    return claims;
  };
  const mutation = async (bridge, kind, target, extra = {}) => {
    const entry = policies.get(bridge.id);
    if (!entry || entry.policy.erased) fail(409, 'legacy_upgrade_required', 'Gateway identity upgrade is required');
    const next = structuredClone(entry.policy); next.revision++;
    if (kind === 'lock') next.joinable = extra.joinable;
    if (kind === 'revoke') {
      if (target.id === bridge.authorityDeviceId) { next.erased = true; next.joinable = false; next.members = []; delete next.inviteTokenHash; }
      else { next.members = next.members.filter(item => identity.inspect(item.certificate).deviceId !== target.id); next.joinable = false; }
    }
    if (kind === 'erase') { next.erased = true; next.joinable = false; next.members = []; delete next.inviteTokenHash; }
    const proposal = startProposal(bridge, next, JSON.stringify([kind, target?.id || '', extra]));
    if (kind === 'revoke') proposal.revokedDeviceId = target.id;
    await wait(proposal);
  };
  const handle = async (req, res, url) => {
    if (req.method !== 'POST' || !url.pathname.startsWith('/v1/auth/')) return false;
    const input = await read(req);
    if (url.pathname === '/v1/auth/challenge') {
      const claims = identity.inspect(input.certificate);
      const challenge = input.certificate
        ? identity.challenge(input.certificate, input.operation, input.payloadJson || '', claims ? currentRevision(claims.bridgeId) : undefined)
        : identity.enrollmentChallenge(input.devicePublicKey, input.operation, input.payloadJson || '');
      if (!challenge) fail(401, 'invalid_identity_proof', 'Device certificate or challenge request was rejected');
      if (challenge.limited) fail(429, 'challenge_limit', 'Too many identity challenges');
      reply(res, 200, challenge); return true;
    }
    if (url.pathname === '/v1/auth/resume') {
      const claims = verifyProof(input, 'resume');
      if (input.payloadJson !== '') fail(400, 'invalid_identity_proof', 'Resume payload must be empty');
      const device = assertActive(claims);
      reply(res, 200, session(device, input.certificate)); return true;
    }
    if (url.pathname === '/v1/auth/bootstrap') {
      const claims = verifyProof(input, 'bootstrap');
      const policy = validatePolicy(input.payloadJson, claims), old = policies.get(claims.bridgeId);
      const pending = proposals.get(claims.bridgeId);
      if (old?.policy.erased) fail(401, 'device_revoked', 'Bridge incarnation was erased');
      if (pending ? input.payloadJson !== pending.policyJson : old && input.payloadJson !== old.policyJson) fail(409, 'policy_pending', 'Policy snapshot is not the current committed proposal');
      apply(input.payloadJson, policy);
      if (pending?.revokedDeviceId) revokeDevice(pending.revokedDeviceId);
      if (pending) { proposals.delete(claims.bridgeId); pending.resolve(input.payloadJson === pending.policyJson); }
      if (policy.erased) { reply(res, 200, { erased: true, bootId: identity.bootId }); return true; }
      reply(res, 200, session(devices.get(claims.deviceId), input.certificate)); return true;
    }
    if (url.pathname === '/v1/auth/policy/commit') {
      const claims = verifyProof(input, 'policy_commit'), payload = parse(input.payloadJson), pending = proposals.get(claims.bridgeId);
      if (!claims.authority || !pending || pending.id !== payload.proposalId || pending.policyJson !== payload.policyJson || claims.incarnation !== pending.policy.incarnation || claims.deviceId !== pending.policy.authorityDeviceId) fail(409, 'policy_pending', 'Gateway policy proposal is not current');
      const policy = validatePolicy(payload.policyJson, claims);
      if (pending.baseRevision !== currentRevision(claims.bridgeId)) fail(409, 'policy_pending', 'Authorization policy changed');
      apply(payload.policyJson, policy); proposals.delete(claims.bridgeId); pending.resolve(true);
      if (pending.revokedDeviceId) revokeDevice(pending.revokedDeviceId);
      reply(res, 200, { committed: true, revision: policy.revision, policyJson: payload.policyJson, erased: policy.erased, bootId: identity.bootId }); return true;
    }
    if (url.pathname === '/v1/auth/upgrade') {
      const bearer = /^Bearer ([A-Za-z0-9_-]+)$/.exec(req.headers.authorization || '')?.[1];
      const device = devices.get(tokens.get(hash(bearer || '')));
      if (!device) fail(401, 'legacy_upgrade_required', 'A live authenticated legacy session or operator-approved recovery is required');
      const payload = enrollment(input, 'upgrade'), bridge = bridges.get(device.bridgeId);
      if (device.certificate && device.publicKey !== payload.devicePublicKey) fail(409, 'legacy_upgrade_required', 'Device signing identity is already bound');
      if (device.certificate) {
        const pending = proposals.get(bridge.id);
        if (pending?.key === `upgrade:${device.id}` && !policies.has(bridge.id)) reply(res, 200, { ...session(device), ...policyResponse(pending) });
        else { assertActive(identity.inspect(device.certificate)); reply(res, 200, session(device)); }
        return true;
      }
      if (!bridge.authorityDeviceId) {
        if (!device.capabilities.smsGateway || (!device.isOwner && !authorizeOwner(req, clientAddress(req)))) fail(409, 'legacy_upgrade_required', 'Operator approval is required to bind the gateway authority');
        bridge.incarnation = randomUUID(); bridge.authorityDeviceId = device.id; device.isOwner = true;
      }
      const candidate = { ...device, publicKey: payload.devicePublicKey };
      candidate.certificate = identity.issue(claimsFor(candidate, bridge));
      let proposal;
      if (!policies.has(bridge.id)) {
        const policy = { v: 1, issuer: identity.issuer, bridgeId: bridge.id, incarnation: bridge.incarnation, authorityDeviceId: device.id,
          revision: 1, joinable: bridge.joinable, erased: false, inviteTokenHash: bridge.inviteTokenHash, createdAt: bridge.createdAt, members: [member(candidate)] };
        proposal = startProposal(bridge, policy, `upgrade:${device.id}`, true);
        Object.assign(device, candidate);
        reply(res, 200, { ...session(device), ...policyResponse(proposal) }); return true;
      }
      const next = structuredClone(policies.get(bridge.id).policy); next.revision++;
      next.members = next.members.filter(item => identity.inspect(item.certificate).deviceId !== device.id); next.members.push(member(candidate));
      proposal = startProposal(bridge, next, `upgrade:${device.id}`); await wait(proposal);
      reply(res, 200, session(device)); return true;
    }
    return false;
  };
  const create = async (req, res) => {
    if (!authorizeOwner(req, clientAddress(req))) fail(401, 'operator_required', 'Invalid relay access key');
    const input = enrollment(await read(req), 'create');
    if (typeof input.bridgeId !== 'string' || !input.bridgeId || input.bridgeId.length > 128 || typeof input.inviteToken !== 'string' || input.inviteToken.length < 16 || input.capabilities?.smsGateway !== true) fail(400, 'gateway_required', 'A gateway signing identity is required to create a bridge');
    if (bridges.has(input.bridgeId)) {
      const bridge = bridges.get(input.bridgeId), device = devices.get(bridge.authorityDeviceId), pending = proposals.get(bridge.id);
      if (device?.publicKey === input.devicePublicKey && device.certificate) {
        if (pending?.key === `create:${device.id}`) reply(res, 201, { ...session(device), ...policyResponse(pending) });
        else { assertActive(identity.inspect(device.certificate)); reply(res, 201, session(device)); }
        return;
      }
      fail(409, 'bridge_exists', 'Bridge already exists');
    }
    if (policies.has(input.bridgeId)) fail(409, 'bridge_exists', 'Bridge incarnation is inactive');
    const bridge = { id: input.bridgeId, incarnation: randomUUID(), authorityDeviceId: randomUUID(), inviteTokenHash: hash(input.inviteToken), createdAt: new Date().toISOString(), joinable: true };
    const device = { id: bridge.authorityDeviceId, bridgeId: bridge.id, publicKey: input.devicePublicKey, name: cleanName(input.deviceName),
      capabilities: capabilities(input.capabilities), lastSeenAt: bridge.createdAt, isOwner: true };
    device.certificate = identity.issue(claimsFor(device, bridge));
    database.transaction(() => {
      database.prepare('INSERT INTO bridges (id, invite_token, created_at, joinable) VALUES (?, ?, ?, 1)').run(bridge.id, bridge.inviteTokenHash, bridge.createdAt);
      database.prepare('INSERT INTO devices (id, bridge_id, name, capabilities, last_seen_at, is_owner) VALUES (?, ?, ?, ?, ?, 1)').run(device.id, bridge.id, device.name, JSON.stringify(device.capabilities), device.lastSeenAt);
    })();
    bridges.set(bridge.id, bridge); devices.set(device.id, device); messages.set(bridge.id, []); commands.set(bridge.id, []);
    const policy = { v: 1, issuer: identity.issuer, bridgeId: bridge.id, incarnation: bridge.incarnation, authorityDeviceId: device.id,
      revision: 1, joinable: true, erased: false, inviteTokenHash: bridge.inviteTokenHash, createdAt: bridge.createdAt, members: [member(device)] };
    const pending = startProposal(bridge, policy, `create:${device.id}`, true);
    reply(res, 201, { ...session(device), ...policyResponse(pending) });
  };
  const join = async (req, res) => {
    const input = enrollment(await read(req), 'join'), bridge = bridges.get(input.bridgeId);
    if (!bridge || !policies.has(input.bridgeId)) fail(409, 'pairing_recovery_pending', 'Waiting for gateway pairing recovery');
    const existing = [...devices.values()].find(item => item.bridgeId === bridge.id && item.publicKey === input.devicePublicKey);
    if (existing?.certificate) { assertActive(identity.inspect(existing.certificate)); reply(res, 201, session(existing)); return; }
    if (typeof input.inviteToken !== 'string' || hash(input.inviteToken) !== bridge.inviteTokenHash) fail(401, 'invalid_invitation', 'Invalid invitation');
    if (!bridge.joinable) fail(403, 'enrollment_locked', 'Bridge enrollment is locked');
    const entry = policies.get(bridge.id), pending = proposals.get(bridge.id), key = `join:${input.devicePublicKey}`;
    let proposal = pending;
    if (!proposal) {
      if (entry.policy.members.length >= MAX_MEMBERS) fail(409, 'member_limit', 'Bridge device limit reached');
      const device = { id: randomUUID(), bridgeId: bridge.id, publicKey: input.devicePublicKey, name: cleanName(input.deviceName), capabilities: capabilities(input.capabilities), isOwner: false };
      device.certificate = identity.issue(claimsFor(device, bridge));
      const next = structuredClone(entry.policy); next.revision++; next.members.push(member(device));
      proposal = startProposal(bridge, next, key);
    } else if (proposal.key !== key) fail(409, 'policy_pending', 'Gateway policy confirmation is pending');
    await wait(proposal);
    const device = [...devices.values()].find(item => item.bridgeId === bridge.id && item.publicKey === input.devicePublicKey);
    if (!device) fail(409, 'policy_pending', 'Gateway did not approve this membership');
    reply(res, 201, session(device));
  };
  const restore = async (req, res) => {
    const input = await read(req);
    if (input.approveIdentityBindings !== true || typeof input.bridgeId !== 'string' || !input.bridgeId || input.bridgeId.length > 128 ||
        typeof input.inviteToken !== 'string' || input.inviteToken.length < 16 || typeof input.authorityDeviceId !== 'string' ||
        !Array.isArray(input.members) || input.members.length < 1 || input.members.length > MAX_MEMBERS ||
        typeof input.createdAt !== 'string' || !Number.isFinite(Date.parse(input.createdAt))) fail(400, 'operator_bindings_required', 'Explicit operator-approved identity bindings are required');
    if (bridges.has(input.bridgeId) || policies.has(input.bridgeId)) fail(409, 'bridge_exists', 'Bridge already exists');
    const bridge = { id: input.bridgeId, incarnation: randomUUID(), authorityDeviceId: input.authorityDeviceId,
      inviteTokenHash: hash(input.inviteToken), createdAt: input.createdAt, joinable: input.joinable === true };
    const seen = new Set(), keys = new Set(), candidates = [];
    for (const entry of input.members) {
      if (typeof entry.deviceId !== 'string' || !entry.deviceId || entry.deviceId.length > 128 || seen.has(entry.deviceId) || devices.has(entry.deviceId) ||
          !validDevicePublicKey(entry.devicePublicKey) || keys.has(entry.devicePublicKey) || typeof entry.isOwner !== 'boolean' ||
          !entry.capabilities || typeof entry.capabilities.smsGateway !== 'boolean' || typeof entry.name !== 'string') fail(400, 'operator_bindings_required', 'Invalid operator-approved device binding');
      seen.add(entry.deviceId); keys.add(entry.devicePublicKey);
      const device = { id: entry.deviceId, bridgeId: bridge.id, publicKey: entry.devicePublicKey, name: cleanName(entry.name),
        capabilities: capabilities(entry.capabilities), isOwner: entry.isOwner, lastSeenAt: new Date().toISOString() };
      if (device.id === bridge.authorityDeviceId && (!device.capabilities.smsGateway || !device.isOwner)) fail(400, 'gateway_required', 'Operator must approve an owner gateway authority');
      device.certificate = identity.issue(claimsFor(device, bridge)); candidates.push(device);
    }
    const authority = candidates.find(device => device.id === bridge.authorityDeviceId);
    if (!authority?.capabilities.smsGateway || !authority.isOwner) fail(400, 'gateway_required', 'Operator must approve an owner gateway authority');
    const policy = { v: 1, issuer: identity.issuer, bridgeId: bridge.id, incarnation: bridge.incarnation, authorityDeviceId: authority.id,
      revision: 1, joinable: bridge.joinable, erased: false, inviteTokenHash: bridge.inviteTokenHash, createdAt: bridge.createdAt, members: candidates.map(member) };
    database.transaction(() => {
      database.prepare('INSERT INTO bridges (id, invite_token, created_at, joinable) VALUES (?, ?, ?, ?)').run(bridge.id, bridge.inviteTokenHash, bridge.createdAt, bridge.joinable ? 1 : 0);
      database.prepare('INSERT INTO devices (id, bridge_id, name, capabilities, last_seen_at, is_owner) VALUES (?, ?, ?, ?, ?, 1)')
        .run(authority.id, bridge.id, authority.name, JSON.stringify(authority.capabilities), authority.lastSeenAt);
    })();
    bridges.set(bridge.id, bridge); devices.set(authority.id, authority); messages.set(bridge.id, []); commands.set(bridge.id, []);
    const proposal = startProposal(bridge, policy, `restore:${authority.id}`, true);
    reply(res, 201, { ...session(authority), ...policyResponse(proposal), certificates: candidates.map(device => ({ deviceId: device.id, certificate: device.certificate })) });
  };
  return { handle, create, join, restore, mutation, identity,
    /**
     * Drops a bridge that never received a gateway-committed policy, such as one
     * created but never bootstrapped. Only relay RAM is affected: no durable
     * gateway authorization exists to revoke, so this is not a revocation.
     */
    discardUncommitted(bridgeId) {
      if (policies.has(bridgeId)) return false;
      const proposal = proposals.get(bridgeId);
      proposals.delete(bridgeId); proposal?.resolve(false);
      eraseBridge(bridgeId);
      return true;
    },
    policy(device) {
      const bridge = bridges.get(device.bridgeId);
      if (!device.certificate || bridge.authorityDeviceId !== device.id) fail(403, 'authority_required', 'Only the gateway policy authority may fetch this ledger');
      const proposal = proposals.get(bridge.id);
      return proposal ? policyResponse(proposal) : { policyJson: policies.get(bridge.id)?.policyJson, proposalId: null, revision: currentRevision(bridge.id) };
    },
    authorize(certificate, device, path) {
      if (certificate) {
        const claims = identity.inspect(certificate);
        if (!claims) fail(401, 'invalid_identity_proof', 'Device certificate was rejected');
        const bridge = bridges.get(claims.bridgeId), authorityPath = path === '/v1/auth/policy' || path === '/v1/events';
        if (device && claims.deviceId !== device.id) fail(401, 'invalid_identity_proof', 'Certificate does not match this session');
        if (device && authorityPath && bridge?.authorityDeviceId === device.id && device.certificate === certificate) return;
        const active = assertActive(claims);
        if (!device) fail(409, 'session_expired', 'Resume this device signing identity');
        if (active !== device) fail(401, 'device_revoked', 'Device authorization was revoked');
      } else if (!device) fail(401, 'legacy_upgrade_required', 'Stored legacy pairing requires authorized upgrade');
      else if (!device.certificate && policies.has(device.bridgeId)) fail(401, 'legacy_upgrade_required', 'A signing identity upgrade is required before using this bridge');
      else if (device.certificate) {
        const bridge = bridges.get(device.bridgeId);
        if (proposals.has(device.bridgeId) && !(bridge.authorityDeviceId === device.id && ['/v1/auth/policy', '/v1/events'].includes(path))) fail(409, 'policy_pending', 'Gateway policy confirmation is pending');
      }
    },
    revoke(deviceId) { identity.revoke(deviceId); },
    stop() { identity.stop(); for (const proposal of proposals.values()) proposal.resolve(false); proposals.clear(); policies.clear(); },
    get pendingCount() { return proposals.size; }, get bootId() { return identity.bootId; } };
}
