// Cloudflare Workers host for the relay.
//
// Every request is forwarded to one Durable Object instance, which keeps the
// whole relay in instance memory exactly like the Node process does. The
// object never calls its storage API: relay state is lost on eviction or
// deploy, which the gateway-backed recovery protocol already handles.
import { EventEmitter } from 'node:events';
import { Buffer } from 'node:buffer';
import initSqlJs from 'sql.js/dist/sql-wasm-browser.js';
import sqlWasm from 'sql.js/dist/sql-wasm-browser.wasm';
import { createRelay, RelayConfigurationError } from './relay.mjs';
import { createWasmMemoryDatabase } from './sqlite-wasm.mjs';
import { createFetchApnsSender } from './apns-fetch.mjs';
import { log } from './logger.mjs';

const RELAY_OBJECT_NAME = 'relay';
/** Bytes buffered for a slow event-stream reader before backpressure applies. */
const STREAM_HIGH_WATER_BYTES = 64 * 1024;
/** Just above the relay's 64 KiB request limit, so it can still answer 413. */
const MAX_BUFFERED_BODY_BYTES = 64 * 1024 + 1;
/**
 * Durable Objects do not reliably learn about client disconnects, so event
 * streams are rotated: an abandoned stream lingers at most this long.
 */
const STREAM_LIFETIME_MS = 4 * 60_000;
const encoder = new TextEncoder();

export default {
  async fetch(request, env) {
    // Refuse an announced oversized body here, before streaming it on.
    if (Number(request.headers.get('content-length')) > MAX_BUFFERED_BODY_BYTES) {
      return Response.json({ error: 'Request too large' }, {
        status: 413,
        headers: { 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' },
      });
    }
    const relay = env.RELAY.get(env.RELAY.idFromName(RELAY_OBJECT_NAME));
    return relay.fetch(request);
  },
};

export class RelayObject {
  constructor(state, env) {
    this.env = env;
    this.relay = null;
    this.starting = null;
  }

  async start() {
    // sql.js treats workerd as a browser Web Worker and reads self.location
    // while loading; the value is unused because the module is supplied here.
    const hadLocation = 'location' in globalThis;
    if (!hadLocation) globalThis.location = { href: 'https://relay.invalid/' };
    let SQL;
    try {
      SQL = await initSqlJs({
        instantiateWasm(imports, done) {
          WebAssembly.instantiate(sqlWasm, imports).then(instance => done(instance, sqlWasm));
          return {};
        },
      });
    } finally {
      if (!hadLocation) delete globalThis.location;
    }
    const env = { ...this.env };
    globalThis.__simBridgeTestDiagnostics = env.SIM_BRIDGE_TEST_DIAGNOSTICS === '1';
    return createRelay({
      env,
      database: createWasmMemoryDatabase(SQL),
      apnsSender: createFetchApnsSender(env),
      // Clients always reach a Worker over Cloudflare's HTTPS edge.
      tls: true,
      discovery: false,
      // Cloudflare delivers only requests for hostnames routed to this Worker.
      routedByHost: true,
      streamMaxMs: STREAM_LIFETIME_MS,
      defaultRelayName: 'Sim Bridge relay',
      readStatic: async file => {
        const response = await this.env.ASSETS.fetch(new Request(`https://assets.invalid/${file}`));
        return response.ok ? new Uint8Array(await response.arrayBuffer()) : null;
      },
    });
  }

  async fetch(request) {
    if (!this.relay) {
      this.starting ??= this.start();
      try {
        this.relay = await this.starting;
      } catch (error) {
        this.starting = null;
        log.error(error instanceof RelayConfigurationError ? error.message : 'Relay could not be initialized');
        return Response.json({ error: 'The relay is not configured' }, { status: 503 });
      }
    }
    return serve(this.relay.handler, request);
  }
}

/** Runs a Node-style (req, res) handler for one Fetch API request. */
async function serve(handler, request) {
  const url = new URL(request.url);
  const req = nodeRequest(request, url, await readBody(request));
  const res = new StreamingResponse();
  // Fires when the client disconnects, which a long-lived event stream needs
  // to release presence; a stream that is merely unread never signals this.
  request.signal?.addEventListener('abort', () => res.closeFromClient(), { once: true });
  const finished = Promise.resolve()
    .then(() => handler(req, res))
    .catch(error => {
      log.error('Unhandled request failure');
      if (globalThis.__simBridgeTestDiagnostics) console.error(error?.stack ?? error);
      if (!res.headersSent) {
        res.writeHead(500, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'The relay could not complete this request' }));
      }
    });
  // Streams such as /v1/events stay open after their headers are sent.
  await Promise.race([res.headersReady, finished]);
  if (!res.headersSent) {
    return Response.json({ error: 'The relay could not complete this request' }, { status: 500 });
  }
  return new Response(res.readable, { status: res.statusCode, headers: res.responseHeaders });
}

/**
 * Reads the request body completely before the relay sees the request. The
 * relay may answer early (for example 403 or 400) without reading a body; if
 * the Durable Object responded while the Worker was still streaming that body
 * to it, workerd aborts the stream and the client receives a 500. Reading stops
 * just past the relay's own limit, which then answers 413.
 */
async function readBody(request) {
  if (!request.body) return [];
  const chunks = [];
  let size = 0;
  const reader = request.body.getReader();
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(Buffer.from(value));
      size += value.byteLength;
      if (size > MAX_BUFFERED_BODY_BYTES) {
        await reader.cancel();
        break;
      }
    }
  } finally {
    reader.releaseLock?.();
  }
  return chunks;
}

function nodeRequest(request, url, body) {
  const headers = Object.fromEntries([...request.headers].map(([name, value]) => [name.toLowerCase(), value]));
  headers.host = url.host;
  return {
    method: request.method,
    url: url.pathname + url.search,
    headers,
    // Cloudflare sets this header at its edge; a client cannot supply it.
    socket: { remoteAddress: request.headers.get('cf-connecting-ip') || 'unknown' },
    async *[Symbol.asyncIterator]() {
      yield* body;
    },
  };
}

/** The subset of Node's ServerResponse that the relay uses, over a ReadableStream. */
class StreamingResponse extends EventEmitter {
  constructor() {
    super();
    this.statusCode = 200;
    this.responseHeaders = new Headers();
    this.headersSent = false;
    this.writableEnded = false;
    this.destroyed = false;
    this.blocked = false;
    this.headersReady = new Promise(resolve => { this.markHeadersReady = resolve; });
    this.readable = new ReadableStream({
      start: controller => { this.controller = controller; },
      pull: () => {
        if (this.blocked) { this.blocked = false; this.emit('drain'); }
      },
      cancel: () => this.closeFromClient(),
    }, new ByteLengthQueuingStrategy({ highWaterMark: STREAM_HIGH_WATER_BYTES }));
  }

  writeHead(status, headers = {}) {
    if (this.headersSent) return this;
    this.statusCode = status;
    for (const [name, value] of Object.entries(headers)) {
      // Hop-by-hop headers are managed by the Workers runtime.
      if (['connection', 'keep-alive', 'transfer-encoding'].includes(name.toLowerCase())) continue;
      if (value !== undefined) this.responseHeaders.set(name, String(value));
    }
    this.headersSent = true;
    this.markHeadersReady();
    return this;
  }

  flushHeaders() { if (!this.headersSent) this.writeHead(this.statusCode); }

  write(chunk) {
    if (this.writableEnded || this.destroyed) throw new Error('Stream closed');
    if (!this.headersSent) this.writeHead(this.statusCode);
    this.controller.enqueue(typeof chunk === 'string' ? encoder.encode(chunk) : new Uint8Array(chunk));
    if (this.controller.desiredSize <= 0) { this.blocked = true; return false; }
    return true;
  }

  end(chunk) {
    if (this.writableEnded || this.destroyed) return this;
    if (chunk !== undefined && chunk !== null) this.write(chunk);
    else if (!this.headersSent) this.writeHead(this.statusCode);
    this.writableEnded = true;
    try { this.controller.close(); } catch {}
    this.emit('finish');
    this.emit('close');
    return this;
  }

  destroy() {
    if (this.destroyed) return this;
    this.destroyed = true;
    try { this.controller.close(); } catch {}
    this.emit('close');
    return this;
  }

  closeFromClient() {
    if (this.destroyed || this.writableEnded) return;
    this.destroyed = true;
    this.emit('close');
  }
}
