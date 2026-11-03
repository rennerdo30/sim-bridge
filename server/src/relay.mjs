import { createHash, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
import { BlockList, isIP } from 'node:net';
import { log } from './logger.mjs';
import { retention, TRANSIENT_TTL_MS, RECEIPT_TTL_MS } from './memory.mjs';
import { createEventStreams } from './events.mjs';
import { createRecovery } from './recovery.mjs';
import { createPushQueue, validNotification } from './apns.mjs';
import { consume, reset as resetRateLimit, startSweeping } from './rate-limit.mjs';

/** Invalid operator configuration; the host process must refuse to start. */
export class RelayConfigurationError extends Error {}

/**
 * Creates the transport-independent relay. The Node server and the
 * Cloudflare Durable Object both feed it Node-style request/response objects.
 *
 * @param {object} options
 * @param {Record<string, string|undefined>} options.env operator configuration
 * @param {object} options.database in-memory SQLite with a better-sqlite3 API
 * @param {Function|null} [options.apnsSender] optional APNs sender
 * @param {(file: string) => Promise<Uint8Array|null>} options.readStatic dashboard files
 * @param {boolean} [options.tls] whether clients reach the relay over HTTPS
 * @param {boolean} [options.discovery] whether LAN discovery is advertised
 * @param {string} [options.defaultRelayName]
 * @param {number} [options.streamMaxMs] bounded event-stream lifetime, 0 for none
 * @param {boolean} [options.routedByHost] the platform delivers only requests for
 *   hostnames bound to this relay (Cloudflare), which already prevents DNS rebinding
 */
export function createRelay(options) {
  const env = options.env;
  const relayId = randomUUID();
  const dashboardDisabled = ['off', 'false', '0'].includes(String(env.SIM_BRIDGE_DASHBOARD ?? 'on').toLowerCase());
  const startedAt = Date.now();
  const VERSION = '0.2.0';
  const PROTOCOL_VERSION = 2;
  const DEFAULT_PORT = 8787;
  const MAX_REQUEST_BYTES = 64 * 1024;
  const MAX_CIPHERTEXT_CHARS = 48 * 1024;
  const MAX_NONCE_CHARS = 64;
  const MAX_MAC_CHARS = 64;
  const MAX_DEVICE_NAME_CHARS = 64;
  const MAX_MESSAGES_PER_BRIDGE = 500;
  const MAX_COMMANDS_PER_BRIDGE = 200;
  const MAX_DEVICES_PER_BRIDGE = 16;
  const PRESENCE_WRITE_INTERVAL_MS = 10_000;
  const SHUTDOWN_GRACE_MS = 5_000;
  const MIN_ACCESS_KEY_LENGTH = 16;
  /** Both values are base64url-encoded HMAC-SHA256 output in a real client. */
  const MIN_VERIFIER_LENGTH = 16;
  const BASE64URL = /^[A-Za-z0-9_-]+={0,2}$/;
  const ENVELOPE_KEYS = ['v', 'ciphertext', 'nonce', 'mac'];

  /** Per-minute limits for the endpoints an attacker would grind against. */
  const RATE_LIMITS = {
    ownerKey: 10,
    join: 10,
    deviceWrite: 240,
  };

  const staticFiles = new Map([
    ['/', ['index.html', 'text/html; charset=utf-8']],
    ['/app.js', ['app.js', 'text/javascript; charset=utf-8']],
    ['/styles.css', ['styles.css', 'text/css; charset=utf-8']],
    ...[
      'BricolageGrotesque-SemiBold',
      'BricolageGrotesque-ExtraBold',
      'JetBrainsMono-Medium',
      'JetBrainsMono-Bold',
    ].map(name => [`/fonts/${name}.ttf`, [`fonts/${name}.ttf`, 'font/ttf']]),
  ]);

  const bridges = new Map();
  const devices = new Map();
  const tokens = new Map();
  const messages = new Map();
  const commands = new Map();
  const presenceWrittenAt = new Map();

  const secret = () => randomBytes(32).toString('base64url');
  const sha256 = value => createHash('sha256').update(String(value ?? '')).digest('hex');

  /**
   * Length-independent constant-time comparison. Hashing first means the
   * comparison never reveals the secret's length and never throws on a
   * length mismatch, which `timingSafeEqual` would.
   */
  const equalSecret = (left, right) => {
    if (typeof left !== 'string' || typeof right !== 'string') return false;
    return timingSafeEqual(
      createHash('sha256').update(left).digest(),
      createHash('sha256').update(right).digest(),
    );
  };

  // Ignore obsolete storage settings without reading, creating or deleting files.
  if (env.SIM_BRIDGE_DATABASE || env.SIM_BRIDGE_LOG_FILE) {
    log.warn('Legacy persistence settings ignored; relay state is memory-only');
  }
  const database = options.database;
  const transientTtlMs = retention(env.SIM_BRIDGE_TRANSIENT_TTL_MS, TRANSIENT_TTL_MS);
  const receiptTtlMs = retention(env.SIM_BRIDGE_RECEIPT_TTL_MS, RECEIPT_TTL_MS);
  const apnsSender = options.apnsSender ?? null;
  const pushQueue = createPushQueue(database, apnsSender, { lifetimeMs: transientTtlMs, onChange: () => eventStreams.notifyAdmin() });
  const eventStreams = createEventStreams({ maxStreamMs: options.streamMaxMs ?? 0, onPresence: deviceId => {
    const device = devices.get(deviceId);
    if (device) eventStreams.emit(device.bridgeId, 'devices');
  } });
  let expiryTimer;
  const latestSequences = new Map();
  const expiredSequences = new Map();
  const expireQueues = () => {
    const now = Date.now();
    const cutoff = new Date(now - transientTtlMs).toISOString();
    database.transaction(() => {
      database.prepare('DELETE FROM messages WHERE received_at <= ?').run(cutoff);
      const commandsExpired = database.prepare('DELETE FROM commands WHERE created_at <= ?').run(cutoff).changes;
      const receiptsExpired = database.prepare('DELETE FROM message_upload_receipts WHERE created_at <= ?').run(now - receiptTtlMs).changes;
      if (commandsExpired || receiptsExpired) eventStreams.notifyAdmin();
    })();
    for (const [bridgeId, items] of messages) {
      const fresh = items.filter(item => item.receivedAt > cutoff);
      if (fresh.length !== items.length) {
        expiredSequences.set(bridgeId, Math.max(expiredSequences.get(bridgeId) || 0, ...items.filter(item => item.receivedAt <= cutoff).map(item => item.seq)));
        messages.set(bridgeId, fresh); eventStreams.emit(bridgeId, 'messages');
      }
    }
    for (const [bridgeId, items] of commands) commands.set(bridgeId, items.filter(item => item.createdAt > cutoff));
  };
  const scheduleExpiry = () => {
    clearTimeout(expiryTimer);
    let next = Infinity;
    for (const items of messages.values()) for (const item of items) next = Math.min(next, Date.parse(item.receivedAt) + transientTtlMs);
    for (const items of commands.values()) for (const item of items) next = Math.min(next, Date.parse(item.createdAt) + transientTtlMs);
    const receipt = database.prepare('SELECT MIN(created_at) AS at FROM message_upload_receipts').get().at;
    if (receipt !== null) next = Math.min(next, receipt + receiptTtlMs);
    if (!Number.isFinite(next)) return;
    expiryTimer = setTimeout(() => { expireQueues(); scheduleExpiry(); }, Math.max(1, next - Date.now()));
    expiryTimer.unref?.();
  };

  const relayAccessKey = env.SIM_BRIDGE_ACCESS_KEY;
  if (!relayAccessKey || relayAccessKey.length < MIN_ACCESS_KEY_LENGTH) {
    throw new RelayConfigurationError('A sufficiently long relay owner access key must be configured');
  }

  const tlsEnabled = options.tls === true;
  const scheme = tlsEnabled ? 'https' : 'http';

  /**
   * Only serve callers that reached us by a local address. Without this a public
   * web page can point a hostname it controls at the relay's LAN address (DNS
   * rebinding) and drive the API as same-origin, which no CORS policy prevents.
   */
  const extraAllowedHosts = (env.SIM_BRIDGE_ALLOWED_HOSTS || '')
    .split(',')
    .map(value => value.trim().toLowerCase())
    .filter(Boolean);
  /**
   * Hosts that cannot be resolved from the public internet, so a page out there
   * cannot point one of these names at this relay. Router-assigned suffixes such
   * as `.home` and `.lan` are included because that is how phones and browsers
   * actually reach a machine on a home network; ICANN does not delegate them, so
   * they remain unreachable to an outside attacker.
   */
  const LOCAL_HOST_PATTERNS = [
    /^localhost$/,
    /^127\.\d+\.\d+\.\d+$/,
    /^\[?::1\]?$/,
    /^10\.\d+\.\d+\.\d+$/,
    /^192\.168\.\d+\.\d+$/,
    /^172\.(1[6-9]|2\d|3[01])\.\d+\.\d+$/,
    /^169\.254\.\d+\.\d+$/,
    // RFC 6598 shared address space, used by Tailscale and similar overlays.
    /^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d+\.\d+$/,
    /^\[?f[cde][0-9a-f]{2}:[0-9a-f:]*\]?$/,
    /\.local$/,
    /\.home$/,
    /\.home\.arpa$/,
    /\.lan$/,
    /\.internal$/,
    // A single-label name ("mac", "raspberrypi") has no public DNS equivalent.
    /^[a-z0-9-]+$/,
  ];
  const hostAllowed = header => {
    const host = String(header ?? '').toLowerCase().replace(/:\d+$/, '');
    if (!host) return false;
    if (extraAllowedHosts.includes(host)) return true;
    return LOCAL_HOST_PATTERNS.some(pattern => pattern.test(host));
  };

  /**
   * Behind a reverse proxy or tunnel every request arrives from the proxy's own
   * address, which would merge all callers into one rate-limit bucket. Only when
   * the socket peer is inside an explicitly trusted range is the proxy's client
   * address header used; anything else keeps the socket address.
   */
  const trustedProxies = new BlockList();
  let trustedProxyCount = 0;
  for (const entry of (env.SIM_BRIDGE_TRUSTED_PROXIES || '').split(',').map(value => value.trim()).filter(Boolean)) {
    const [address, prefixText] = entry.split('/');
    const family = isIP(address);
    const prefix = prefixText === undefined ? (family === 6 ? 128 : 32) : Number(prefixText);
    if (!family || !Number.isInteger(prefix) || prefix < 0 || prefix > (family === 6 ? 128 : 32)) {
      throw new RelayConfigurationError('Invalid trusted proxy range configured');
    }
    trustedProxies.addSubnet(address, prefix, family === 6 ? 'ipv6' : 'ipv4');
    trustedProxyCount++;
  }
  const clientAddressHeader = (env.SIM_BRIDGE_CLIENT_IP_HEADER || 'cf-connecting-ip').toLowerCase();
  const unmapped = address => address.startsWith('::ffff:') && isIP(address.slice(7)) === 4 ? address.slice(7) : address;
  const trustedPeer = address => {
    const family = isIP(address);
    return family !== 0 && trustedProxies.check(address, family === 6 ? 'ipv6' : 'ipv4');
  };
  const clientAddress = req => {
    const peer = unmapped(req.socket.remoteAddress || '');
    if (!peer) return 'unknown';
    if (!trustedProxyCount || !trustedPeer(peer)) return peer;
    const forwarded = String(req.headers[clientAddressHeader] ?? '').split(',').map(value => value.trim()).filter(Boolean).at(-1);
    return forwarded && isIP(unmapped(forwarded)) ? unmapped(forwarded) : peer;
  };

  const publicDevice = device => ({
    id: device.id,
    name: device.name,
    capabilities: device.capabilities,
    lastSeenAt: device.lastSeenAt,
    online: eventStreams.online(device.id),
    eventConnected: eventStreams.online(device.id),
    isOwner: device.isOwner === true,
  });

  const SECURITY_HEADERS = {
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
    'referrer-policy': 'no-referrer',
    'x-frame-options': 'DENY',
  };

  const reply = (res, status, value, extraHeaders) => {
    res.writeHead(status, {
      'content-type': 'application/json',
      ...SECURITY_HEADERS,
      ...extraHeaders,
    });
    res.end(JSON.stringify(value));
  };

  const serveStatic = async (res, pathname) => {
    const [file, contentType] = staticFiles.get(pathname);
    const body = await options.readStatic(file);
    if (!body) return reply(res, 404, { error: 'Not found' });
    res.writeHead(200, {
      'content-type': contentType,
      'content-security-policy':
        "default-src 'self'; connect-src 'self'; img-src 'self' data:; style-src 'self'; " +
        "font-src 'self'; script-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
      ...SECURITY_HEADERS,
    });
    res.end(body);
  };

  /** Client-safe error that carries its own HTTP status. */
  class RequestError extends Error {
    constructor(status, message) {
      super(message);
      this.status = status;
      this.expose = true;
    }
  }

  const ownerAuthorized = (req, scopeClient) => {
    const limit = consume('ownerKey', scopeClient, RATE_LIMITS.ownerKey);
    if (!limit.allowed) {
      throw new RequestError(429, 'Too many attempts, try again shortly');
    }
    if (!equalSecret(req.headers['x-relay-key'], relayAccessKey)) return false;
    resetRateLimit('ownerKey', scopeClient);
    return true;
  };

  const queueCount = map =>
    [...map.values()].reduce((total, items) => total + items.length, 0);

  const adminStatus = () => ({
    ok: true,
    version: VERSION,
    protocolVersion: PROTOCOL_VERSION,
    relayId,
    relayName: env.SIM_BRIDGE_RELAY_NAME || options.defaultRelayName,
    discoveryService: options.discovery ? '_simbridge._tcp.local' : null,
    uptimeSeconds: Math.floor((Date.now() - startedAt) / 1000),
    startedAt: new Date(startedAt).toISOString(),
    counts: {
      bridges: bridges.size,
      devices: devices.size,
      gateways: [...devices.values()].filter(item => item.capabilities.smsGateway).length,
      encryptedMessages: queueCount(messages),
      commands: queueCount(commands),
      pendingPushes: database.prepare('SELECT COUNT(*) AS n FROM push_jobs').get().n,
      pushSubscriptions: database.prepare('SELECT COUNT(*) AS n FROM push_subscriptions').get().n,
      uploadReceipts: database.prepare('SELECT COUNT(*) AS n FROM message_upload_receipts').get().n,
      eventStreams: eventStreams.size,
      pendingCommands: [...commands.values()]
        .flat()
        .filter(item => item.status === 'pending').length,
    },
    devices: [...devices.values()].map(device => ({
      ...publicDevice(device),
      bridgeId: device.bridgeId,
    })),
    bridges: [...bridges.values()].map(bridge => ({
      id: bridge.id,
      createdAt: bridge.createdAt,
      joinable: bridge.joinable,
    })),
    security: {
      transport: tlsEnabled ? 'tls' : trustedProxyCount ? 'trusted-proxy' : 'cleartext-lan-only',
      ownerAuthentication: true,
      deviceTokens: true,
      tokenStorage: 'sha256-hashed',
      verifierStorage: 'sha256-hashed',
      payloadVisibility: 'ciphertext-only',
      persistence: 'memory-only',
      transientRetentionSeconds: transientTtlMs / 1000,
      receiptRetentionSeconds: receiptTtlMs / 1000,
      hostAllowlist: true,
      rateLimited: true,
    },
  });

  const runSelfTest = () => {
    const checks = {
      randomSource: new Set(Array.from({ length: 64 }, secret)).size === 64,
      bridgeQueues: [...bridges.keys()].every(id => messages.has(id) && commands.has(id)),
      deviceReferences: [...devices.values()].every(device => bridges.has(device.bridgeId)),
      tokenReferences: [...tokens.values()].every(deviceId => devices.has(deviceId)),
      envelopes: [...messages.values()].flat().every(item => validEnvelope(item.envelope)) &&
        [...commands.values()].flat().every(item => validEnvelope(item.envelope)),
      verifiersHashed: [...bridges.values()].every(
        bridge => /^[0-9a-f]{64}$/.test(bridge.inviteTokenHash),
      ),
      retentionWithinLimits: [...messages.values()].every(
        items => items.length <= MAX_MESSAGES_PER_BRIDGE,
      ) && [...commands.values()].every(items => items.length <= MAX_COMMANDS_PER_BRIDGE),
      databaseParity:
        database.prepare('SELECT COUNT(*) AS count FROM bridges').get().count === bridges.size &&
        database.prepare('SELECT COUNT(*) AS count FROM devices').get().count === devices.size &&
        database.prepare('SELECT COUNT(*) AS count FROM messages').get().count === queueCount(messages) &&
        database.prepare('SELECT COUNT(*) AS count FROM commands').get().count === queueCount(commands),
      databaseTypes: [...devices.values()].every(
        device => typeof device.name === 'string' &&
          device.capabilities !== null &&
          typeof device.capabilities === 'object',
      ),
    };
    return { ok: Object.values(checks).every(Boolean), checks, testedAt: new Date().toISOString() };
  };

  const read = async req => {
    const chunks = [];
    let size = 0;
    for await (const chunk of req) {
      size += chunk.length;
      if (size > MAX_REQUEST_BYTES) throw new RequestError(413, 'Request too large');
      chunks.push(chunk);
    }
    try {
      const value = JSON.parse(Buffer.concat(chunks).toString() || '{}');
      if (value === null || typeof value !== 'object' || Array.isArray(value)) {
        throw new RequestError(400, 'Request body must be a JSON object');
      }
      return value;
    } catch (error) {
      if (error instanceof RequestError) throw error;
      throw new RequestError(400, 'Request body must be valid JSON');
    }
  };

  const base64urlWithin = (value, maxChars) =>
    typeof value === 'string' &&
    value.length > 0 &&
    value.length <= maxChars &&
    BASE64URL.test(value);

  /**
   * Envelopes are opaque to the relay, but their shape is not: accepting only the
   * four known keys stops a device from smuggling extra data through the relay to
   * every other phone, and stops oversized fields from filling the database.
   */
  const validEnvelope = value =>
    Boolean(value) &&
    typeof value === 'object' &&
    !Array.isArray(value) &&
    Object.keys(value).length === ENVELOPE_KEYS.length &&
    ENVELOPE_KEYS.every(key => Object.hasOwn(value, key)) &&
    value.v === 1 &&
    base64urlWithin(value.ciphertext, MAX_CIPHERTEXT_CHARS) &&
    base64urlWithin(value.nonce, MAX_NONCE_CHARS) &&
    base64urlWithin(value.mac, MAX_MAC_CHARS);

  const cleanDeviceName = value => {
    if (value === undefined || value === null) return 'Device';
    if (typeof value !== 'string') throw new RequestError(400, 'Device name must be text');
    const trimmed = value.trim().slice(0, MAX_DEVICE_NAME_CHARS);
    return trimmed || 'Device';
  };

  /**
   * Gateway authority is decided once, at enrollment, and never again. It is the
   * claim "this device holds the SIM", which grants the right to publish incoming
   * messages and to be targeted by commands — a device must not be able to award
   * it to itself later.
   */
  const enrollmentCapabilities = value => {
    if (value === undefined || value === null) return {};
    if (typeof value !== 'object' || Array.isArray(value)) {
      throw new RequestError(400, 'Capabilities must be an object');
    }
    return {
      smsGateway: value.smsGateway === true,
      calls: value.calls === true,
      callControl: value.callControl === true,
      multiSim: value.multiSim === true,
    };
  };

  /** Capabilities a device may change about itself after enrollment. */
  const MUTABLE_CAPABILITIES = ['callControl', 'multiSim', 'calls'];

  const pruneQueue = (map, bridgeId, limit, table) => {
    const items = map.get(bridgeId);
    if (!items || items.length <= limit) return;
    const excess = items.splice(0, items.length - limit);
    if (table === 'messages') expiredSequences.set(bridgeId, Math.max(expiredSequences.get(bridgeId) || 0, ...excess.map(item => item.seq)));
    const statement = database.prepare(`DELETE FROM ${table} WHERE id = ?`);
    database.transaction(() => {
      for (const item of excess) statement.run(item.id);
    })();
    log.info('Pruned queue past retention limit');
  };

  const touchPresence = device => {
    const now = Date.now();
    device.lastSeenAt = new Date(now).toISOString();
    // Coalesce metadata updates in the in-memory relational state.
    if (now - (presenceWrittenAt.get(device.id) ?? 0) < PRESENCE_WRITE_INTERVAL_MS) return;
    presenceWrittenAt.set(device.id, now);
    database
      .prepare('UPDATE devices SET last_seen_at = ? WHERE id = ?')
      .run(device.lastSeenAt, device.id);
  };

  const revokeDevice = deviceId => {
    const device = devices.get(deviceId);
    if (!device) return false;
    database.transaction(() => {
      database.prepare('DELETE FROM device_tokens WHERE device_id = ?').run(deviceId);
      database.prepare('DELETE FROM devices WHERE id = ?').run(deviceId);
    })();
    devices.delete(deviceId);
    eventStreams.revoke(deviceId);
    presenceWrittenAt.delete(deviceId);
    resetRateLimit('deviceWrite', deviceId);
    recovery?.revoke(deviceId);
    for (const [hash, id] of tokens) if (id === deviceId) tokens.delete(hash);
    for (const [bridgeId, items] of messages) {
      messages.set(bridgeId, items.filter(item => item.gatewayDeviceId !== deviceId));
    }
    for (const [bridgeId, items] of commands) {
      commands.set(
        bridgeId,
        items.filter(item => item.targetDeviceId !== deviceId && item.requestedBy !== deviceId),
      );
    }
    log.warn('Device revoked');
    pushQueue.changed();
    scheduleExpiry();
    eventStreams.emit(device.bridgeId, 'devices');
    return true;
  };

  const eraseBridge = bridgeId => {
    for (const member of [...devices.values()]) if (member.bridgeId === bridgeId) revokeDevice(member.id);
    database.prepare('DELETE FROM bridges WHERE id = ?').run(bridgeId);
    bridges.delete(bridgeId); messages.delete(bridgeId); commands.delete(bridgeId);
    latestSequences.delete(bridgeId); expiredSequences.delete(bridgeId);
    eventStreams.notifyAdmin(); scheduleExpiry();
  };
  const recovery = createRecovery({ accessKey: relayAccessKey, bridges, devices, tokens, database, messages, commands,
    events: eventStreams, read, reply, authorizeOwner: ownerAuthorized, clientAddress, publicDevice,
    capabilities: enrollmentCapabilities, cleanName: cleanDeviceName, secret, revokeDevice, eraseBridge, RequestError });

  async function route(req, res, url) {
    expireQueues();
    pushQueue.expire();
    const client = clientAddress(req);

    // SIM_BRIDGE_DASHBOARD=off hides the owner dashboard and admin API entirely,
    // so a relay on the public internet shows nothing beyond the app API.
    if (dashboardDisabled && (staticFiles.has(url.pathname) || url.pathname.startsWith('/v1/admin/'))) {
      return reply(res, 404, { error: 'Not found' });
    }
    if (req.method === 'GET' && staticFiles.has(url.pathname)) {
      return await serveStatic(res, url.pathname);
    }
    if (req.method === 'GET' && url.pathname === '/health') {
      return reply(res, 200, { ok: true, version: VERSION, protocolVersion: PROTOCOL_VERSION, authorizationVersion: 2, bootId: recovery.bootId });
    }
    if (req.method === 'POST' && url.pathname === '/v1/auth/challenge') {
      const limit = consume('identityProof', client, 120);
      if (!limit.allowed) return reply(res, 429, { error: 'Too many identity requests', code: 'challenge_limit' });
    }
    if (await recovery.handle(req, res, url)) return;

    if (url.pathname.startsWith('/v1/admin/')) {
      if (!ownerAuthorized(req, client)) {
        log.warn('Rejected admin request');
        return reply(res, 401, { error: 'Invalid relay access key' });
      }
      if (req.method === 'GET' && url.pathname === '/v1/admin/events') {
        if (url.search) return reply(res, 400, { error: 'Event credentials belong only in headers' });
        if (!eventStreams.openAdmin(res, SECURITY_HEADERS)) return reply(res, 429, { error: 'Event stream limit reached' });
        return;
      }
      if (req.method === 'GET' && url.pathname === '/v1/admin/status') {
        return reply(res, 200, adminStatus());
      }
      if (req.method === 'POST' && url.pathname === '/v1/admin/recovery/restore') return recovery.restore(req, res);
      if (req.method === 'POST' && url.pathname === '/v1/admin/debug/self-test') {
        const result = runSelfTest();
        log.info('Self-test run');
        return reply(res, 200, result);
      }
      const revoke = url.pathname.match(/^\/v1\/admin\/devices\/([^/]+)\/revoke$/);
      if (req.method === 'POST' && revoke) {
        const target = devices.get(revoke[1]);
        if (!target) return reply(res, 404, { error: 'Device not found' });
        await recovery.mutation(bridges.get(target.bridgeId), 'revoke', target);
        return reply(res, 200, { revoked: revoke[1] });
      }
      const lock = url.pathname.match(/^\/v1\/admin\/bridges\/([^/]+)\/joinable$/);
      if (req.method === 'POST' && lock) {
        const bridge = bridges.get(lock[1]);
        if (!bridge) return reply(res, 404, { error: 'Bridge not found' });
        const input = await read(req);
        if (typeof input.joinable !== 'boolean') {
          // An empty body would otherwise silently lock the bridge.
          return reply(res, 400, { error: 'A joinable value of true or false is required' });
        }
        await recovery.mutation(bridge, 'lock', null, { joinable: input.joinable });
        log.warn('Bridge enrollment setting changed');
        eventStreams.emit(bridge.id, 'devices');
        return reply(res, 200, { id: bridge.id, joinable: bridge.joinable });
      }
      return reply(res, 404, { error: 'Not found' });
    }

    if (req.method === 'POST' && url.pathname === '/v1/bridges') return recovery.create(req, res);
    if (req.method === 'POST' && url.pathname === '/v1/bridges/join') {
      const limit = consume('join', client, RATE_LIMITS.join);
      if (!limit.allowed) return reply(res, 429, { error: 'Too many attempts, try again shortly' });
      return recovery.join(req, res);
    }

    const erasure = url.pathname.match(/^\/v1\/bridges\/([^/]+)$/);
    if (req.method === 'DELETE' && erasure) {
      if (!ownerAuthorized(req, client)) return reply(res, 401, { error: 'Invalid relay access key' });
      let bridgeId;
      try { bridgeId = decodeURIComponent(erasure[1]); } catch { return reply(res, 400, { error: 'Invalid bridge identifier' }); }
      if (!bridges.has(bridgeId)) return reply(res, 404, { error: 'Bridge not found' });
      if (recovery.discardUncommitted(bridgeId)) return reply(res, 200, { erased: true, committed: false });
      await recovery.mutation(bridges.get(bridgeId), 'erase');
      return reply(res, 200, { erased: true });
    }
    if (url.pathname === '/v1/events' && url.search) return reply(res, 400, { error: 'Event credentials belong only in the Authorization header' });
    const bearer = /^Bearer ([A-Za-z0-9_-]+)$/.exec(req.headers.authorization || '')?.[1];
    const device = devices.get(tokens.get(sha256(bearer)));
    recovery.authorize(req.headers['x-device-certificate'], device, url.pathname);
    if (!device) return reply(res, 401, { error: 'Invalid device token', code: 'legacy_upgrade_required' });
    touchPresence(device);
    if (req.method === 'GET' && url.pathname === '/v1/auth/policy') return reply(res, 200, recovery.policy(device));
    if (req.method === 'GET' && url.pathname === '/v1/events') {
      // The resume marker only suppresses a presence announcement for a device that
      // is already online; it grants nothing.
      if (!eventStreams.open(res, device, SECURITY_HEADERS, sha256(bearer), req.headers['x-simbridge-resume'] === 'rotation')) return reply(res, 429, { error: 'Event stream limit reached' });
      return;
    }

    if (req.method === 'GET' && url.pathname === '/v1/devices') {
      const visible = [...devices.values()]
        .filter(item => item.bridgeId === device.bridgeId)
        .map(publicDevice);
      // Carried here so a phone does not need a second round trip per poll.
      const bridge = bridges.get(device.bridgeId);
      return reply(res, 200, {
        devices: visible,
        bridge: { joinable: bridge?.joinable === true },
      });
    }
    if (req.method === 'POST' && url.pathname === '/v1/devices/me/push') {
      if (device.capabilities.smsGateway) return reply(res, 403, { error: 'Only a client may register push notifications' });
      const writes = consume('deviceWrite', device.id, RATE_LIMITS.deviceWrite);
      if (!writes.allowed) return reply(res, 429, { error: 'Too many requests' });
      const input = await read(req);
      if (typeof input.token !== 'string' || !/^[0-9a-fA-F]{64}$/.test(input.token) ||
          !['sandbox', 'production'].includes(input.environment) || Object.keys(input).some(key => !['token', 'environment'].includes(key))) {
        return reply(res, 400, { error: 'Invalid push subscription' });
      }
      pushQueue.register(device.id, input.token, input.environment);
      return reply(res, 200, { registered: true, enabled: pushQueue.enabled });
    }
    if (req.method === 'POST' && url.pathname === '/v1/devices/me') {
      const input = await read(req);
      if (input.capabilities && typeof input.capabilities === 'object') {
        for (const key of MUTABLE_CAPABILITIES) {
          if (Object.hasOwn(input.capabilities, key)) {
            device.capabilities[key] = input.capabilities[key] === true;
          }
        }
        if (input.capabilities.smsGateway !== undefined &&
          input.capabilities.smsGateway !== device.capabilities.smsGateway) {
          log.warn('Refused gateway capability change');
        }
        database
          .prepare('UPDATE devices SET capabilities = ? WHERE id = ?')
          .run(JSON.stringify(device.capabilities), device.id);
      }
      eventStreams.emit(device.bridgeId, 'devices');
      return reply(res, 200, { device: publicDevice(device) });
    }
    // Leaving under your own steam. Any device may drop its own enrollment, and
    // doing so on "Leave bridge" is what stops abandoned rows piling up.
    if (req.method === 'POST' && url.pathname === '/v1/devices/me/leave') {
      await recovery.mutation(bridges.get(device.bridgeId), 'revoke', device);
      return reply(res, 200, { left: device.id });
    }
    // Removing a phone from the bridge. Restricted to the owner device so that a
    // lost or stolen phone cannot evict the ones still in your hands.
    const removeDevice = url.pathname.match(/^\/v1\/devices\/([^/]+)\/remove$/);
    if (req.method === 'POST' && removeDevice) {
      if (!device.isOwner) {
        log.warn('Refused device removal by a non-owner');
        return reply(res, 403, { error: 'Only the phone that created this bridge can remove devices' });
      }
      const target = devices.get(removeDevice[1]);
      if (!target || target.bridgeId !== device.bridgeId) {
        return reply(res, 404, { error: 'Device not found' });
      }
      if (target.id === device.id) {
        return reply(res, 400, { error: 'Leave the bridge from this phone instead' });
      }
      await recovery.mutation(bridges.get(device.bridgeId), 'revoke', target);
      return reply(res, 200, { removed: target.id });
    }
    if (req.method === 'POST' && url.pathname === '/v1/bridges/joinable') {
      if (!device.isOwner) {
        return reply(res, 403, { error: 'Only the phone that created this bridge can change this' });
      }
      const input = await read(req);
      if (typeof input.joinable !== 'boolean') {
        return reply(res, 400, { error: 'A joinable value of true or false is required' });
      }
      const bridge = bridges.get(device.bridgeId);
      if (!bridge) return reply(res, 404, { error: 'Bridge not found' });
      await recovery.mutation(bridge, 'lock', null, { joinable: input.joinable });
      log.warn('Bridge enrollment setting changed by owner device');
      eventStreams.emit(bridge.id, 'devices');
      return reply(res, 200, { joinable: bridge.joinable });
    }
    if (req.method === 'GET' && url.pathname === '/v1/bridges/me') {
      const bridge = bridges.get(device.bridgeId);
      if (!bridge) return reply(res, 404, { error: 'Bridge not found' });
      return reply(res, 200, {
        id: bridge.id,
        createdAt: bridge.createdAt,
        joinable: bridge.joinable,
      });
    }
    if (req.method === 'GET' && url.pathname === '/v1/messages') {
      const all = messages.get(device.bridgeId) ?? [];
      // `since` lets a phone fetch only what it has not seen. Without it every
      // poll re-sends and re-decrypts the entire bridge history.
      const since = Number(url.searchParams.get('since') ?? 0);
      const fresh = Number.isFinite(since) && since > 0
        ? all.filter(item => item.seq > since)
        : all;
      return reply(res, 200, {
        messages: fresh,
        // The client needs this even when nothing new arrived, so it can tell
        // "up to date" from "my cursor is stale after a prune".
        oldestSeq: all.length > 0 ? all[0].seq : 0,
        latestSeq: latestSequences.get(device.bridgeId) || 0,
        expired: since > 0 && since < (expiredSequences.get(device.bridgeId) || 0),
      });
    }
    if (req.method === 'POST' && url.pathname === '/v1/messages') {
      if (!device.capabilities.smsGateway) {
        return reply(res, 403, { error: 'Only a gateway may publish messages' });
      }
      const writes = consume('deviceWrite', device.id, RATE_LIMITS.deviceWrite);
      if (!writes.allowed) {
        log.warn('Device write rate limit reached');
        return reply(res, 429, { error: 'Too many requests' },
          { 'retry-after': String(writes.retryAfterSeconds) });
      }
      const input = await read(req);
      if (!validEnvelope(input.envelope)) {
        return reply(res, 400, { error: 'Invalid encrypted envelope' });
      }
      if (Object.hasOwn(input, 'uploadId') &&
          (typeof input.uploadId !== 'string' || !/^[A-Za-z0-9_:-]{1,128}$/.test(input.uploadId))) {
        return reply(res, 400, { error: 'Invalid upload identifier' });
      }
      if (input.uploadId) {
        const prior = database.prepare('SELECT response FROM message_upload_receipts WHERE device_id = ? AND upload_id = ?').get(device.id, input.uploadId);
        if (prior) return reply(res, 201, JSON.parse(prior.response));
      }
      // Push previews are optional: an invalid or oversized preview must not
      // discard the authoritative encrypted SMS after a gateway drains its inbox.
      const notification = validNotification(input.notification) ? input.notification : undefined;
      const item = {
        id: randomUUID(),
        gatewayDeviceId: device.id,
        envelope: input.envelope,
        receivedAt: new Date().toISOString(),
      };
      const inserted = database.transaction(() => {
        const result = database
        .prepare('INSERT INTO messages (id, bridge_id, gateway_device_id, envelope, received_at) VALUES (?, ?, ?, ?, ?)')
        .run(item.id, device.bridgeId, item.gatewayDeviceId, JSON.stringify(item.envelope), item.receivedAt);
        item.seq = Number(result.lastInsertRowid);
        latestSequences.set(device.bridgeId, item.seq);
        if (notification) pushQueue.enqueue(device.bridgeId, notification, item.id);
        if (input.uploadId) {
          database.prepare('INSERT INTO message_upload_receipts (device_id, upload_id, response, created_at) VALUES (?, ?, ?, ?)')
            .run(device.id, input.uploadId, JSON.stringify({ id: item.id, seq: item.seq, receivedAt: item.receivedAt }), Date.now());
          database.prepare('DELETE FROM message_upload_receipts WHERE device_id = ? AND upload_id IN (SELECT upload_id FROM message_upload_receipts WHERE device_id = ? ORDER BY rowid DESC LIMIT -1 OFFSET 2000)')
            .run(device.id, device.id);
        }
        return result;
      })();
      item.seq = Number(inserted.lastInsertRowid);
      messages.get(device.bridgeId).push(item);
      pruneQueue(messages, device.bridgeId, MAX_MESSAGES_PER_BRIDGE, 'messages');
      log.debug('Encrypted message stored');
      eventStreams.emit(device.bridgeId, 'messages');
      scheduleExpiry();
      return reply(res, 201, { id: item.id, seq: item.seq, receivedAt: item.receivedAt });
    }
    if (req.method === 'POST' && url.pathname === '/v1/commands') {
      const writes = consume('deviceWrite', device.id, RATE_LIMITS.deviceWrite);
      if (!writes.allowed) {
        return reply(res, 429, { error: 'Too many requests' },
          { 'retry-after': String(writes.retryAfterSeconds) });
      }
      const input = await read(req);
      const target = devices.get(input.targetDeviceId);
      if (!target || target.bridgeId !== device.bridgeId || !target.capabilities.smsGateway) {
        return reply(res, 400, { error: 'Target is not a bridge gateway' });
      }
      if (!validEnvelope(input.envelope)) {
        return reply(res, 400, { error: 'Invalid encrypted envelope' });
      }
      const item = {
        id: randomUUID(),
        targetDeviceId: target.id,
        requestedBy: device.id,
        envelope: input.envelope,
        status: 'pending',
        createdAt: new Date().toISOString(),
      };
      database
        .prepare('INSERT INTO commands (id, bridge_id, target_device_id, requested_by, envelope, status, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)')
        .run(item.id, device.bridgeId, item.targetDeviceId, item.requestedBy, JSON.stringify(item.envelope), item.status, item.createdAt);
      commands.get(device.bridgeId).push(item);
      pruneQueue(commands, device.bridgeId, MAX_COMMANDS_PER_BRIDGE, 'commands');
      log.info('Command queued');
      eventStreams.emit(device.bridgeId, 'commands', target.id);
      scheduleExpiry();
      return reply(res, 201, item);
    }
    if (req.method === 'GET' && url.pathname === '/v1/commands') {
      return reply(res, 200, {
        commands: (commands.get(device.bridgeId) ?? []).filter(
          item => item.targetDeviceId === device.id && item.status === 'pending',
        ),
      });
    }
    const complete = url.pathname.match(/^\/v1\/commands\/([^/]+)\/complete$/);
    if (req.method === 'POST' && complete) {
      const item = (commands.get(device.bridgeId) ?? []).find(
        command => command.id === complete[1] && command.targetDeviceId === device.id,
      );
      if (!item) return reply(res, 404, { error: 'Command not found' });
      if (item.status !== 'pending') {
        return reply(res, 409, { error: 'Command already reported' });
      }
      const input = await read(req);
      item.status = input.ok === true ? 'complete' : 'failed';
      item.completedAt = new Date().toISOString();
      database
        .prepare('UPDATE commands SET status = ?, completed_at = ? WHERE id = ?')
        .run(item.status, item.completedAt, item.id);
      log.debug('Command reported');
      eventStreams.notifyAdmin();
      return reply(res, 200, item);
    }
    return reply(res, 404, { error: 'Not found' });
  }

  async function handler(req, res) {
    if (!options.routedByHost && !hostAllowed(req.headers.host)) {
      log.warn('Rejected request with unexpected Host header');
      return reply(res, 403, { error: 'Relay is reachable on local networks only' });
    }
    if (req.method === 'OPTIONS') {
      // No CORS grants: the phones are native clients and the dashboard is
      // same-origin, so no browser needs cross-origin access to this API.
      res.writeHead(204, SECURITY_HEADERS);
      return res.end();
    }
    let url;
    try { url = new URL(req.url, `${scheme}://localhost`); }
    catch { return reply(res, 400, { error: 'Invalid request target' }); }
    try {
      return await route(req, res, url);
    } catch (error) {
      if (error instanceof RequestError) {
        log.debug('Rejected request');
        return reply(res, error.status, { error: error.message, ...(error.code ? { code: error.code } : {}) });
      }
      // Never hand internals (SQLite text, stack paths, parser output) to a caller.
      log.error('Unhandled request failure');
      // Isolated test relays only: never enabled for an operator relay, whose
      // logs must not carry exception text.
      if (env.SIM_BRIDGE_TEST_DIAGNOSTICS === '1') console.error(error?.stack ?? error);
      return reply(res, 500, { error: 'The relay could not complete this request' });
    }
  }

  const sweeper = startSweeping();
  return {
    handler,
    relayId,
    get relayName() { return env.SIM_BRIDGE_RELAY_NAME || options.defaultRelayName; },
    stop() {
      clearInterval(sweeper);
      clearTimeout(expiryTimer);
      recovery.stop();
      eventStreams.stop();
      pushQueue.stop();
      try { database.close(); } catch { log.error('Database did not close cleanly'); }
    },
  };
}
