# Pairing recovery protocol

The Android gateway keeps durable authorization. The relay keeps only bounded
runtime state in memory. A relay restart clears pending delivery work and bearer
sessions, but does not require pairing again once the trusted gateway restores
its current membership policy. This protocol is preparation for deployment;
existing installations require the explicit migration described below.

## Identity and trust

Each device creates an independent Ed25519 key in device secure storage. Never
derive this key from the bridge root key or invitation: every paired member may
know those shared values. Device IDs, bridge IDs, encryption keys, and native SMS
journals stay unchanged during recovery.

The relay issues compact HMAC certificates using a domain-separated key derived
from stable operator configuration. Certificates bind issuer, bridge ID,
incarnation, device ID, raw 32-byte signing public key, gateway role, owner role,
and authority role. Only the Android owner gateway can be the durable authority.
The operator key is configuration, not a relay-generated persistence file;
changing it invalidates existing certificates and requires an explicit recovery.

Certificates prove identity, not current permission. The gateway's current policy
determines active membership. A client certificate cannot bootstrap a bridge.
After cold start, clients wait for the gateway rather than creating or joining
again. The gateway is trusted to keep the latest policy: without an external
durable anchor, the relay cannot detect a malicious authority signing an old
backup after a complete RAM reset. Restore current gateway storage, not stale
authorization backups.

## Wire contract

Base64url encoding is unpadded. Public keys are 32 bytes and signatures 64 bytes.
Certificate proof operation names are `resume`, `bootstrap`, and `policy_commit`.
Enrollment operations `create`, `join`, and `upgrade` bind a raw signing public
key instead of an already-issued certificate and prove possession of that key.

`POST /v1/auth/challenge` accepts `{certificate, operation, payloadJson}` where
`payloadJson` is the exact JSON string to be authorized, not a parsed object.
The response contains a challenge ID and exact UTF-8 `signingPayload`. It binds
the protocol version, issuer, boot ID, single-use random nonce, challenge ID,
operation, certificate SHA-256, and payload SHA-256. The client validates those
bindings against its intended request before signing the exact returned bytes.
Challenges are bounded, short-lived, RAM-only, and consumed once. Consumption
rechecks current incarnation, policy revision, and actor permission.

The signing string is the exact JSON encoding of the seven-element array
`["simbridge/pop/v1", bootId, challengeId, nonce, operation, bindingSha256, payloadSha256]`.
The binding is the certificate string for certificate operations and the raw
base64url public-key string for enrollment. Hashes are lowercase SHA-256 hex;
certificate claims bind the issuer. Challenge `expiresAt` is Unix milliseconds.

`POST /v1/auth/resume` and `POST /v1/auth/bootstrap` accept the certificate,
challenge ID, signature, and identical `payloadJson`. Resume has an empty string
payload; bootstrap carries the gateway's exact persisted policy JSON.
The response renews the bearer session without changing IDs or root keys.
Recovery also resets relay sequence cursors and re-registers volatile push
subscriptions; local message history and native execution journals remain.

The exact inner `policyJson` string contains:

```json
{
  "v": 1,
  "issuer": "operator-bound relay identity",
  "bridgeId": "existing bridge ID",
  "incarnation": "certificate-bound incarnation",
  "authorityDeviceId": "Android owner gateway device ID",
  "revision": 1,
  "joinable": false,
  "erased": false,
  "inviteTokenHash": "invitation hash",
  "createdAt": "original creation time",
  "members": [{"certificate": "opaque certificate", "name": "device name", "capabilities": {}}]
}
```

This example describes field shapes, not deployable credentials. There are at
most 16 active members; omitted members are denied. `erased: true` is an inactive
incarnation tombstone. Certificate-bound SMS, owner, gateway, and authority
permissions cannot be changed through runtime capability updates. Hardware
availability such as call control or multi-SIM can remain volatile.

`GET /v1/auth/policy`, authenticated by the authority bearer, returns
`{policyJson, proposalId, baseRevision, revision}`. The authority durably writes
and verifies the exact inner policy bytes before signing a `policy_commit`
proof whose `payloadJson` is JSON `{proposalId, policyJson}`.
`POST /v1/auth/policy/commit` consumes that proof. Initial create/upgrade returns
a certificate, initial policy, proposal ID, and restricted provisional session;
only policy coordination and events are available until durable commit.

Ordinary membership mutations wait at most eight seconds for that commit before
returning a recoverable error. While a proposal is pending, authorization and
side effects are frozen. A timeout never restores the old allowlist: the gateway
may already have persisted the new policy and lost the acknowledgement.
Reconciliation must use the persisted policy. Policy work runs independently of
the gateway's ordinary message-sync lock, driven by targeted SSE `policy` hints
and initial `ready` catch-up, with bounded retries on failed work, not idle polls.

Joiners keep a stable signing identity through retries. The relay releases a
member certificate/session only after the gateway commits that member. A lost
join response can be recovered by proof of possession of the same signing key;
knowledge of the shared invitation alone never grants an existing certificate.
Automatic restart recovery never calls create/join or clears native queues.

## Revocation, erasure, and errors

Revocation closes enrollment (`joinable: false`). Reopening it is an explicit
owner action: a previously removed holder of the reusable invitation/root key
can seek fresh enrollment if the owner deliberately reopens that invitation.
Revocation does not rotate previously shared encryption keys.

Permanent revoke, lock, or erase requires the gateway to persist the new policy
before success is reported. Offline gateway means refusal/waiting, not an
unrecorded promise. Revoking or leaving from the authority gateway erases the
entire bridge, because no other member can replace its durable authority without
explicit operator recovery. The confirmation must explain that impact.
Bridge erase retains an inactive tombstone or securely
destroys authority credentials so an old certificate cannot reactivate it.
Revocation closes affected event streams and cancels pending deliveries.

Recoverable 409 codes are `pairing_recovery_pending`, `gateway_unavailable`,
`policy_pending`, and `session_expired`. `device_revoked` is terminal only after a current policy proves
denial. `legacy_upgrade_required` preserves credentials and journals and asks
for explicit operator migration. Unknown tokens after RAM reset are not proof
of revocation. Stream heartbeats are liveness signals, not REST-fetch triggers.

## Existing installation migration

`POST /v1/auth/upgrade` may bind a signing key only to an authenticated device in
an existing live legacy mapping. Authority upgrade requires existing gateway
and owner authorization. Shared encryption keys do not establish ownership.
A legacy bridge with a different owner topology needs explicit operator approval
of authority transfer, preserving IDs and SMS journals.

An upgrade endpoint in new source cannot recover mappings erased when replacing
the old binary. The deployment procedure must stage migration while those
bindings are still available or use explicit operator-authorized restore with
known identity/role bindings. No automatic import, read, deletion, or publication
of historical relay databases is permitted. Live deployment, operator identity
assignment, and migration completion remain separate verified steps.

The operator-only `POST /v1/admin/recovery/restore` requires `x-relay-key` and an
explicit `approveIdentityBindings: true` body with `bridgeId`, `authorityDeviceId`,
`inviteToken`, `createdAt`, `joinable`, and `members`. Each member supplies known
`deviceId`, `devicePublicKey`, `name`, `isOwner`, and `capabilities`. The approved
authority must be an owner gateway. It creates a new certificate incarnation
while preserving the supplied IDs. Its response provides certificates and a
restricted initial authority session/policy proposal; gateway durable commit is
still required before ordinary access. The operator must verify these bindings
through a trusted device channel, not infer them from an invitation. Public-key
preparation and certificate installation on existing devices are part of the
explicit migration; this endpoint does not complete those device steps by itself.

## Verification required

Test cold restart and gateway-late recovery; stable IDs/root keys/journals;
revoked member denial after restart; absent gateway refusal; commit ack loss and
timeout freeze; stale/replayed proof rejection; wrong key/role/issuer/payload;
erased incarnation refusal; retry without duplicate member; sequence reset and
push re-registration; migration without invitation-based ownership inference.
Check that server storage remains `:memory:` with no runtime file writes.

Cryptographic implementation references: [Node crypto](https://nodejs.org/docs/latest-v22.x/api/crypto.html),
[proof-of-possession claims](https://www.rfc-editor.org/rfc/rfc7800.html), and
[algorithm and validation guidance](https://www.rfc-editor.org/rfc/rfc8725.html).
