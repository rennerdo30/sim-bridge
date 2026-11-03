// Invalidation hints only: content stays in the authenticated REST endpoints.
export function createEventStreams({ heartbeatMs = 15000, blockedMs = 30000,
  maxPerDevice = 2, maxTotal = 1000, maxStreamMs = 0, rotationGraceMs = 30000, onPresence = () => {} } = {}) {
  const streams = new Set();
  // Devices whose stream the relay just rotated: they count as online for a
  // short grace period, so a planned reconnect announces no presence change.
  const rotating = new Map();
  const count = deviceId => [...streams].filter(s => s.device.id === deviceId).length;
  const endGrace = deviceId => { clearTimeout(rotating.get(deviceId)); rotating.delete(deviceId); };
  const close = (stream, rotated = false) => {
    if (!streams.delete(stream)) return;
    clearInterval(stream.heartbeat);
    clearTimeout(stream.timeout);
    clearTimeout(stream.rotation);
    stream.res.removeListener('drain', stream.drain);
    stream.res.removeListener('close', stream.closed);
    stream.res.removeListener('error', stream.closed);
    stream.pending.clear();
    if (!stream.res.writableEnded && !stream.res.destroyed) stream.res.end();
    const deviceId = stream.device.id;
    if (count(deviceId) > 0) return;
    if (rotated && !stream.admin) {
      endGrace(deviceId);
      const timer = setTimeout(() => {
        rotating.delete(deviceId);
        if (count(deviceId) === 0) onPresence(deviceId, false);
      }, rotationGraceMs);
      timer.unref?.();
      rotating.set(deviceId, timer);
      return;
    }
    endGrace(deviceId);
    onPresence(deviceId, false);
  };
  const send = (stream, type) => {
    if (!streams.has(stream)) return;
    if (stream.blocked) { stream.pending.add(type); return; }
    let accepted;
    try { accepted = stream.res.write(`data: ${JSON.stringify({ type })}\n\n`); }
    catch { close(stream); return; }
    if (!accepted) {
      stream.blocked = true;
      stream.timeout = setTimeout(() => close(stream), blockedMs);
      stream.timeout.unref?.();
    }
  };
  const open = (res, device, headers, admin = false, tokenHash, resume = false) => {
    // A planned reconnect of a device that is still online needs no fresh
    // producer snapshot; anything else is announced as before.
    const resumed = !admin && resume && (rotating.has(device.id) || count(device.id) > 0);
    // A phone that changed networks reconnects while the proxy still holds its
    // old stream open; the newest connection from the same device wins.
    if (!admin) {
      const own = [...streams].filter(s => s.device.id === device.id);
      while (own.length >= maxPerDevice) close(own.shift());
    }
    if (streams.size >= maxTotal || count(device.id) >= maxPerDevice) return false;
    res.writeHead(200, { ...headers, 'content-type': 'text/event-stream; charset=utf-8',
      'cache-control': 'no-store', 'connection': 'keep-alive', 'x-accel-buffering': 'no' });
    res.flushHeaders?.();
    const stream = { res, device, admin, tokenHash, pending: new Set(), blocked: false };
    stream.closed = () => close(stream);
    stream.drain = () => {
      stream.blocked = false;
      clearTimeout(stream.timeout);
      for (const type of stream.pending) {
        stream.pending.delete(type);
        send(stream, type);
        if (stream.blocked) break;
      }
    };
    streams.add(stream);
    if (!admin) endGrace(device.id);
    res.on('drain', stream.drain);
    res.on('close', stream.closed);
    res.on('error', stream.closed);
    stream.heartbeat = setInterval(() => {
      if (stream.blocked) return;
      let accepted;
      try { accepted = res.write(': heartbeat\n\n'); }
      catch { close(stream); return; }
      if (!accepted) {
        stream.blocked = true;
        stream.timeout = setTimeout(() => close(stream), blockedMs);
        stream.timeout.unref?.();
      }
    }, heartbeatMs);
    stream.heartbeat.unref?.();
    // Where the host cannot observe client disconnects (Cloudflare Durable
    // Objects), streams end after a bounded lifetime so an abandoned one cannot
    // hold presence or a stream slot. Clients reconnect at once on this hint.
    if (maxStreamMs > 0) {
      stream.rotation = setTimeout(() => { send(stream, 'reconnect'); close(stream, true); }, maxStreamMs);
      stream.rotation.unref?.();
    }
    send(stream, 'ready');
    // Each subscriber needs a fresh producer snapshot, including a visible UI
    // attached beside an already-connected headless gateway after buffer expiry.
    if (!admin && !resumed) onPresence(device.id, true);
    return true;
  };
  return {
    open: (res, device, headers, tokenHash, resume = false) => open(res, device, headers, false, tokenHash, resume),
    online: deviceId => count(deviceId) > 0 || rotating.has(deviceId),
    openAdmin: (res, headers) => open(res, { id: '__relay_owner__', capabilities: {} }, headers, true),
    notifyAdmin() { for (const stream of streams) if (stream.admin) send(stream, 'status'); },
    emit(bridgeId, type, targetId) {
      for (const stream of streams) {
        if (stream.admin) { send(stream, 'status'); continue; }
        if (stream.device.bridgeId !== bridgeId) continue;
        if (['commands', 'policy'].includes(type) && stream.device.id !== targetId) continue;
        send(stream, type);
      }
    },
    revoke(deviceId) { endGrace(deviceId); for (const stream of [...streams]) if (stream.device.id === deviceId) close(stream); },
    revokeToken(tokenHash) { for (const stream of [...streams]) if (stream.tokenHash === tokenHash) close(stream); },
    stop() { for (const stream of [...streams]) close(stream); for (const deviceId of [...rotating.keys()]) endGrace(deviceId); },
    get size() { return streams.size; },
  };
}
