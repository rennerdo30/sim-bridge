# Sim Bridge relay

The relay requires Node.js 22+. From `server/`, install locked dependencies with `npm ci`
and run isolated checks with `npm test`. Start with an owner secret supplied through
`SIM_BRIDGE_ACCESS_KEY`; keep that configuration private. `PORT` defaults to 8787.
Use a separately selected disposable port for tests, never an operating paired relay.

## Memory-only state and restart behavior

All enrollment records, hashed device tokens/verifiers, routing metadata, encrypted messages,
commands, upload acknowledgements, APNs subscriptions, and pending push jobs exist only in
this process's RAM. SQLite is opened explicitly as `:memory:` with MEMORY journal and temp
storage to retain transactions and foreign-key erasure without writing a database, WAL,
journal, temporary database, or application log file. Diagnostics are generic console messages;
request addresses, identifiers, paths, credentials, ciphertext, and message content are omitted.
A process supervisor, proxy, hosting platform, swap, or crash-dump mechanism has its own
logging/storage behavior; this software cannot certify those external systems.

`SIM_BRIDGE_DATABASE` and `SIM_BRIDGE_LOG_FILE` are obsolete and ignored. Their values are
not logged. The relay does not open, import, alter, migrate, or delete old files, even when
those settings point at an existing database or log. Static application/font files and
explicitly configured TLS/APNs keys are read as configuration; they are not runtime queues.

Restart discards bearer sessions, delivery queues and the relay's current authorization
snapshot. Pairing survives on devices: each keeps its independent signing key and a
server-signed identity certificate, while the Android owner gateway durably keeps the current
membership/revocation policy. The gateway restores that policy through a fresh authenticated
bootstrap; clients then resume the same device/bridge identities without sharing a QR code
again. Until the gateway reconnects, clients wait and preserve their keys, message history,
preferences and native outbox/journals. Recovery never falls back to invitation enrollment.
Ciphertext catch-up and APNs subscriptions remain volatile and must be refreshed after restart.
This source is deployment preparation; it does not migrate an existing installation by itself.

| State | Maximum lifetime/count |
| --- | --- |
| Encrypted message catch-up buffer | Five minutes after relay acceptance; 500 messages per bridge |
| Encrypted commands, including terminal results | Five minutes after relay acceptance; 200 commands per bridge; the gateway also validates sealed command freshness |
| Encrypted APNs previews | Five minutes after acceptance; 2000 pending deliveries globally; up to eight attempts within that deadline |
| Payload-free upload acknowledgements | 24 hours; latest 2000 per gateway, possibly pruned sooner by count |
| Enrollments, token/verifier hashes and APNs subscription tokens | Until device/bridge erasure or process termination; at most 16 devices per bridge |
| Bearer sessions | At most eight per device; evicting a session closes its associated event streams |
| Identity proof challenges | 30 seconds, single-use; 1000 globally; 120 requests per source per minute |
| Gateway policy proposals | One per bridge; HTTP waits at most eight seconds; timeout leaves authorization frozen until the exact proposed policy is committed/reconciled |
| Event connections | Two per device/owner dashboard and 1000 globally; stalled writers close after 30 seconds |
| Authentication rate-limit source buckets | One-minute windows, removed within the next one-minute maintenance sweep; not associated with a bridge; device write buckets are cleared on revocation |

Expired queues are removed by due-time work and checked again before serving requests.
Pending push expiry remains scheduled while HTTP/2 delivery is in flight and cancels that
request at the deadline. These are logical queue limits, not forensic RAM-zeroization claims.
Operators may shorten the limits with `SIM_BRIDGE_TRANSIENT_TTL_MS` and
`SIM_BRIDGE_RECEIPT_TTL_MS`; positive integer values are capped at five minutes and 24 hours,
respectively. Omitted/invalid values retain those ceilings. Device-local retention is separate.

Gateway `POST /v1/messages` may supply an opaque `uploadId` (1–128 ASCII letters, digits,
`_`, `:`, or `-`). Retries within the receipt window return the original `{id, seq, receivedAt}`
acknowledgement without storing or sending another preview. The receipt contains no envelope,
SMS content, number, or bridge key and therefore does not extend ciphertext retention.
The ID is scoped to the authenticated gateway and must not encode sensitive content.
An upload acknowledgement proves relay acceptance, not recipient delivery or notification success.
Message cursors remain monotonic within the process. `GET /v1/messages?since=<seq>` reports
`expired:true` when the supplied nonzero cursor predates content removed by retention.

## Authenticated event streams

`GET /v1/events` uses `Authorization: Bearer <device token>` and modern clients also send
`x-device-certificate` in request headers. Tokens in
query parameters are rejected. The response is `text/event-stream` with `Cache-Control:
no-store`, no cross-origin grants, and the existing Host validation. Each data frame is:

```text
data: {"type":"ready"}

```

Only the type is sent, never a body, number, identifier, token, key, or ciphertext. Types are
`ready`, `messages`, `commands`, `devices`, and `policy`. `ready` follows every successful connection
so a client can fetch a current snapshot and catch mutations preceding stream setup.
`messages` is scoped to all members of that bridge, including a gateway's visible client UI.
`commands` reaches only the addressed gateway device. `devices` reports enrollment,
capability, joinability, every device-stream attachment, last-stream disconnection, and revocation
changes. Roster responses include `online` and `eventConnected`, both meaning an authenticated
stream is currently attached; they do not establish hardware readiness or carrier availability.
`policy` reaches only the bridge's designated gateway authority. It fetches the proposal,
durably saves/verifies the exact policy bytes, then signs the commit. Policy coordination runs
independently of ordinary message synchronization so a mutation cannot deadlock its own worker.

Comments (`: heartbeat`) arrive every 15 seconds for liveness. They request no REST fetch.
REST reads do not emit another roster/status hint, preventing a fetch feedback loop. Slow
writers coalesce the finite hint types and are disconnected if backpressure persists.
Closing/revoking streams removes listeners and timers. Reconnect with bounded backoff and
fetch on `ready`. Recoverable 409 responses preserve pairing and trigger bounded recovery;
`device_revoked` stops automatic authorization attempts. An unmapped legacy token requires
explicit operator migration and is not silently interpreted as a revoked modern identity.

The owner dashboard uses `GET /v1/admin/events` with `x-relay-key` in the header. Its data types
are `ready` and `status`; comments are liveness-only. Owner credentials are never placed in
stream URLs. The dashboard retains its unlock key only in browser memory.

## Erasure and administration

The owner-authenticated dashboard/API proposes revocation to the gateway. Success is reported
only after the gateway durably commits the new policy. Offline authority returns 409
`gateway_unavailable`. A pending policy freezes member authorization/side effects; an
eight-second timeout returns `policy_pending` and never restores the old allowlist. Once
committed, revocation invalidates tokens, closes event streams, removes related queues and
closes enrollment. Reopening enrollment is an explicit owner action: a holder of the old
shared invitation can seek fresh membership if the owner deliberately reopens it.

`DELETE /v1/bridges/<bridge-id>` requires the relay owner's `x-relay-key`. An ordinary device
bearer token does not authorize it. Erasure also requires gateway durable confirmation.
The gateway retains an inactive incarnation tombstone; the relay retains that authorization
tombstone only in RAM. Bridge/member records and queued messages, commands, acknowledgements
and APNs state are erased from Maps/in-memory SQLite; tokens are invalidated and streams
closed. Other bridges remain intact. After cold restart the trusted gateway restores its
tombstone rather than recreating the erased bridge.
In-flight push requests are cancelled; a notification already accepted by Apple cannot be
recalled. This action does not erase content/keys already held by devices or external logs,
and does not delete an old on-disk database left by an earlier version. Existing files require
a separately authorized operator cleanup. Never include real data in tests or public reports.

## Pairing recovery and migration

The full wire contract is [PAIRING-RECOVERY-PROTOCOL.md](../PAIRING-RECOVERY-PROTOCOL.md).
Certificates are unpadded base64url JSON plus a dot and HMAC-SHA256 tag. Claims bind version,
issuer, bridge incarnation, device ID, raw Ed25519 public key and immutable SMS/owner/authority
roles. The signing key uses a dedicated context derived from `SIM_BRIDGE_ACCESS_KEY`;
changing that operator configuration invalidates certificates. No key is derived from the
shared bridge encryption key, and no relay-generated key file is written.

`POST /v1/auth/challenge` returns exact UTF-8 `signingPayload` bytes for a certificate and
operation (`resume`, `bootstrap`, `policy_commit`), or an initial raw public key with
`create`, `join`, or `upgrade`. The signed seven-element JSON array is
`["simbridge/pop/v1", bootId, challengeId, nonce, operation, certificateOrPublicKeySHA256,
payloadSHA256]`. Issuer/roles are bound through the certificate hash. Base64url public keys
are 32 bytes; signatures are 64 bytes. Clients validate the array before signing. Proofs
bind exact `payloadJson` bytes, expire after 30 seconds, consume once and recheck current
policy revision. Resume requires an empty payload; bootstrap requires the gateway's exact
persisted ledger. Member certificates cannot bootstrap a bridge.

`GET /v1/auth/policy` is gateway-bearer authenticated. Signed
`POST /v1/auth/policy/commit` accepts proof payload JSON `{proposalId, policyJson}` after the
gateway has durably written/read back the inner policy. Initial creation/authority upgrade
returns a restricted provisional session and policy; only policy coordination/events work
before commit. New bridges require an owner gateway. Joining members receive their certificate
and session only after commit; retries prove the same signing key to retain the same identity.

Recovery errors include `pairing_recovery_pending`, `gateway_unavailable`, `policy_pending`
and `session_expired` (409); `device_revoked` (401) requires a loaded current policy proving
denial. `legacy_upgrade_required` preserves old credentials/journals and requests explicit
migration. A gateway is trusted to supply its latest durable ledger: after complete RAM loss,
the relay cannot detect a malicious authorized gateway freshly signing an outdated backup.
Recorded old proofs are rejected. Unavailable/corrupt/missing gateway policy must fail closed;
never synthesize a ledger from shared keys or a member certificate.

`POST /v1/auth/upgrade` binds a key to an authenticated live legacy mapping, preserving IDs
and existing roles. Shared invitation knowledge grants no ownership. A legacy gateway that
is not the recorded owner needs explicit operator approval for authority transfer. Other
live legacy mappings can upgrade during staging, but cannot use ordinary routes after the
gateway policy activates. Replacing a running legacy binary loses its mapping; migration
must be staged while bindings remain available or performed through explicit operator restore.

`POST /v1/admin/recovery/restore` requires `x-relay-key`, `approveIdentityBindings:true`, known
bridge/device IDs, original creation time, invitation verifier, authority ID, and explicit
member public-key/SMS/owner-role bindings. It reads no database and infers no authority from
shared-key possession. The operator receives provisional certificates/policy; the known
gateway must persist and commit before members may resume. This endpoint prepares a reviewed
operator path; running it against an existing installation requires separate authorization.

## Cloudflare Workers (recommended hosting)

The same relay runs as a Cloudflare Worker, so there is no server to operate or patch.
`src/worker.mjs` forwards every request to one Durable Object that holds the whole relay
in instance memory, using SQLite compiled to WebAssembly (`sql.js`) entirely in RAM. The
Durable Object never calls its storage API. Cloudflare requires every new Durable Object
class to be declared with a SQLite backend; it stays empty. Eviction, restarts and deploys
discard relay memory, which is the documented restart behaviour: clients keep their
identities and the Android gateway restores pairing. Pending relay work is lost.

```sh
cd server
npx wrangler login
npx wrangler secret put SIM_BRIDGE_ACCESS_KEY   # 32+ random characters, kept private
npm run deploy:worker
```

The Worker is then reachable at `https://sim-bridge-relay.<your-subdomain>.workers.dev`;
enter that URL in the apps. A custom domain can be added in the Cloudflare dashboard.
Cloudflare terminates HTTPS and routes only hostnames bound to the Worker, so the relay's
Host allowlist and trusted-proxy settings do not apply there. `wrangler.jsonc` disables
Workers observability so Cloudflare keeps no request logs for the relay; platform-level
logs and security telemetry remain subject to Cloudflare's terms.

Differences from the Node host:

- Durable Objects do not reliably report client disconnects, so event streams end after
  four minutes with a `reconnect` hint and clients reconnect immediately.
- There is no LAN discovery; clients enter the HTTPS URL.
- Optional iPhone push uses `fetch` with the key as PEM text in the
  `SIM_BRIDGE_APNS_KEY` secret, plus `SIM_BRIDGE_APNS_KEY_ID` and `SIM_BRIDGE_APNS_TEAM_ID`.
  APNs requires HTTP/2; delivery from a Worker has not been verified yet.
- Usage: an always-connected gateway keeps the Durable Object active. One active object at
  128 MB uses about 11,000 of the 13,000 GB-seconds in the free daily allowance; check your
  account's usage, or use Workers Paid.

`npm run test:worker` runs the relay suite against the Worker in local `workerd`
(`wrangler dev`, isolated state, no operator `.env` files). Three Node-transport tests are
skipped there because Cloudflare's edge performs that HTTP parsing and Host routing.
`npm run test:wasm` runs the Node host on the WebAssembly SQLite engine.

## Running behind a reverse proxy or tunnel

The relay can run as plain HTTP behind a proxy that terminates HTTPS, such as a
Cloudflare Tunnel. Configure:

- `SIM_BRIDGE_ALLOWED_HOSTS`: the public hostname clients use, without scheme or port.
- `SIM_BRIDGE_TRUSTED_PROXIES`: comma-separated addresses or CIDR ranges of the proxy.
  Only a request whose socket peer is inside these ranges may supply the client address
  through `SIM_BRIDGE_CLIENT_IP_HEADER` (default `cf-connecting-ip`). Without it, every
  caller would share the proxy's rate-limit budget. Never trust a range that other
  containers or hosts can send from.
- `SIM_BRIDGE_DISCOVERY=off`: disables LAN Bonjour advertisement, which is meaningless on
  a hosted server and unavailable in most containers.
- `SIM_BRIDGE_KEEP_ALIVE_MS`: idle keep-alive timeout, default 95 seconds so it outlasts
  the proxy's pooled origin connections.
- `SIM_BRIDGE_LISTEN_HOST`: listen address, default `0.0.0.0`.

Do not put an interactive login (for example Cloudflare Access) or caching in front of the
`/v1/` API: phones call it directly and `/v1/events` is a long-lived event stream. An
access policy on the owner dashboard (`/` and `/v1/admin/`) is optional.

### Container deployment

`Dockerfile` builds a small runtime image containing only `src/`, `public/` and production
dependencies; `.dockerignore` keeps `.env*` files and `data/` out of the build context.
`deploy/docker-compose.yml` runs the relay with a memory cap, a read-only filesystem and no
published ports, next to a `cloudflared` connector on a private network whose subnet is the
only trusted proxy range:

```sh
cd server/deploy
cp relay.env.example relay.env     # owner key and public hostname
cp tunnel.env.example tunnel.env   # Cloudflare Tunnel token
docker compose up -d --build
```

Route the tunnel's public hostname to `http://relay:8787`. Both env files are gitignored.
The relay needs no volume because it keeps no state on disk; restarting the container has
the documented memory-only restart behaviour.

## Transport and optional iPhone push

Use HTTPS outside a trusted private network. Set `SIM_BRIDGE_TLS_CERT` and
`SIM_BRIDGE_TLS_KEY` together; hostnames beyond the default local/private allowlist require
an explicit `SIM_BRIDGE_ALLOWED_HOSTS` configuration. Owner/device credentials need protected
transport even though payloads are encrypted. Discovery advertises no owner credential or key.

APNs is optional. Configure only on the relay host:

- `SIM_BRIDGE_APNS_KEY_PATH`: Apple APNs P-256 `.p8` key outside this repository.
- `SIM_BRIDGE_APNS_KEY_ID` and `SIM_BRIDGE_APNS_TEAM_ID`: matching Apple identifiers.
- `SIM_BRIDGE_APNS_TOPIC`: iOS bundle identifier; default `dev.renner.simbridge`.

All three key values must be configured together. With no sender configured, subscriptions
and previews remain RAM-only and previews still expire within five minutes. Sandbox/production
key authorization must match the client registration and signed iOS `aps-environment`.

Authenticated clients register through `POST /v1/devices/me/push` with a 64-hex APNs token
and `environment: sandbox` or `production`; gateways cannot register. Replacing a subscription
clears its old pending/in-flight delivery. APNs receives an encrypted preview and generic
fallback alert, with a maximum 4096-byte payload. Invalid/oversized optional previews do not
reject the authoritative encrypted message. Network/server failures use due-time backoff;
there is no one-second polling loop. Permanent token failures remove the subscription.
A passing build/test does not establish live Apple delivery; test it separately on an
explicitly authorized paired, locked physical iPhone.
