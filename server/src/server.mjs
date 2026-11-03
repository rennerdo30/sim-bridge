import { createServer as createHttpServer } from 'node:http';
import { createServer as createHttpsServer } from 'node:https';
import { hostname } from 'node:os';
import { readFileSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { Bonjour } from 'bonjour-service';
import { log } from './logger.mjs';
import { createMemoryDatabase, createWasmDatabaseForNode } from './sqlite-node.mjs';
import { createApnsSender } from './apns-http2.mjs';
import { createRelay, RelayConfigurationError } from './relay.mjs';

const DEFAULT_PORT = 8787;
const SHUTDOWN_GRACE_MS = 5_000;
const DEFAULT_KEEP_ALIVE_MS = 95_000;
const publicRoot = new URL('../public/', import.meta.url);

// Ignore obsolete storage settings without reading, creating or deleting files.
if (process.env.SIM_BRIDGE_DATABASE || process.env.SIM_BRIDGE_LOG_FILE) {
  log.warn('Legacy persistence settings ignored; relay state is memory-only');
}

const tlsCertPath = process.env.SIM_BRIDGE_TLS_CERT;
const tlsKeyPath = process.env.SIM_BRIDGE_TLS_KEY;
if (Boolean(tlsCertPath) !== Boolean(tlsKeyPath)) {
  log.error('Both TLS certificate and key must be configured');
  process.exit(1);
}
const tlsEnabled = Boolean(tlsCertPath && tlsKeyPath);
const scheme = tlsEnabled ? 'https' : 'http';
// Containers and hosted servers have no LAN to advertise on.
const discoveryEnabled = !['off', 'false', '0'].includes(
  String(process.env.SIM_BRIDGE_DISCOVERY || 'on').toLowerCase(),
);

let apnsSender;
try { apnsSender = createApnsSender(); } catch {
  log.error('APNs configuration could not be initialized');
  process.exit(1);
}

let relay;
try {
  relay = createRelay({
    env: process.env,
    // SIM_BRIDGE_SQL_ENGINE=wasm runs the engine used on Cloudflare.
    database: process.env.SIM_BRIDGE_SQL_ENGINE === 'wasm' ? await createWasmDatabaseForNode() : createMemoryDatabase(),
    apnsSender,
    tls: tlsEnabled,
    discovery: discoveryEnabled,
    defaultRelayName: `Sim Bridge on ${hostname()}`,
    readStatic: file => readFile(new URL(file, publicRoot)).catch(() => null),
  });
} catch (error) {
  log.error(error instanceof RelayConfigurationError ? error.message : 'Relay could not be initialized');
  process.exit(1);
}

const port = Number(process.env.PORT || DEFAULT_PORT);
let server;
try {
  server = tlsEnabled
    ? createHttpsServer({ cert: readFileSync(tlsCertPath), key: readFileSync(tlsKeyPath) }, relay.handler)
    : createHttpServer(relay.handler);
} catch {
  log.error('TLS configuration could not be initialized');
  process.exit(1);
}

// An mDNS socket failure must never take the relay down.
let bonjour;
if (discoveryEnabled) {
  try {
    bonjour = new Bonjour({}, () => log.error('LAN discovery failed'));
    bonjour.server?.mdns?.on?.('error', () => log.error('LAN discovery failed'));
  } catch { log.error('LAN discovery unavailable, relay still reachable by address'); }
}
let advertisedService;

// Reverse proxies such as cloudflared keep idle origin connections far longer
// than Node's 5 s default; closing first makes the proxy reuse a dead socket.
const keepAlive = Number(process.env.SIM_BRIDGE_KEEP_ALIVE_MS);
server.keepAliveTimeout = keepAlive > 0 ? keepAlive : DEFAULT_KEEP_ALIVE_MS;
server.headersTimeout = server.keepAliveTimeout + 5_000;

server.listen(port, process.env.SIM_BRIDGE_LISTEN_HOST || '0.0.0.0', () => {
  log.info('Relay listening');
  if (!tlsEnabled && process.env.SIM_BRIDGE_TRUSTED_PROXIES) log.info('HTTPS is expected to terminate at the trusted proxy');
  else if (!tlsEnabled) log.warn('Running without TLS: credentials travel in cleartext, keep this relay on a trusted LAN');
  if (!bonjour) { log.info('LAN discovery disabled'); return; }
  try {
    advertisedService = bonjour.publish({
      name: relay.relayName,
      type: 'simbridge',
      protocol: 'tcp',
      port,
      txt: { version: '1', relayId: relay.relayId, scheme },
    });
    advertisedService.on?.('error', () => log.error('LAN discovery failed'));
    log.info('LAN discovery advertised');
  } catch {
    log.error('LAN discovery unavailable, relay still reachable by address');
  }
});
server.on('error', () => { log.error('Relay listener could not be initialized'); process.exit(1); });
server.on('clientError', (error, socket) => {
  log.debug('Client connection error');
  socket.destroy();
});

let shuttingDown = false;
const shutdown = () => {
  if (shuttingDown) return;
  shuttingDown = true;
  log.info('Shutting down');
  advertisedService?.stop?.();
  try { bonjour?.destroy(); } catch {}
  let finished = false;
  const finish = () => {
    if (finished) return;
    finished = true;
    relay.stop();
    log.flush().finally(() => process.exit(0));
  };
  server.close(finish);
  // A single half-open request would otherwise hold the process open forever.
  server.closeAllConnections?.();
  setTimeout(() => {
    log.warn('Forcing shutdown after grace period');
    finish();
  }, SHUTDOWN_GRACE_MS).unref();
};
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
