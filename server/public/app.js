let relayKey = '';
const PRESENCE_WINDOW_MS = 16000;
const EVENT_IDLE_MS = 45000;
const EVENT_RETRY_MAX_MS = 30000;
const EVENT_FRAME_MAX = 4096;
const LATENCY_SAMPLES = 10;
const $ = id => document.getElementById(id);
const toast = message => { $('toast').textContent = message; $('toast').classList.add('show'); setTimeout(() => $('toast').classList.remove('show'), 2200); };
const request = async (path, options = {}) => {
  const response = await fetch(path, { ...options, redirect: 'error', cache: 'no-store', headers: { 'x-relay-key': relayKey, 'content-type': 'application/json', ...(options.headers || {}) } });
  const data = await response.json();
  if (!response.ok) {
    const explanation = {
      gateway_unavailable: 'Connect the Android gateway to save this authorization change.',
      pairing_recovery_pending: 'Waiting for the Android gateway to restore pairing.',
      policy_pending: 'Authorization change awaiting gateway confirmation. Keep the gateway connected; success has not been confirmed.',
    }[data.code || data.error];
    throw new Error(explanation || data.error || `Request failed (${response.status})`);
  }
  return data;
};
const duration = seconds => { const days = Math.floor(seconds / 86400); const hours = Math.floor(seconds % 86400 / 3600); const minutes = Math.floor(seconds % 3600 / 60); return [days && `${days}d`, hours && `${hours}h`, `${minutes}m`].filter(Boolean).join(' '); };
const recent = value => Date.now() - Date.parse(value) < PRESENCE_WINDOW_MS;
const escapeText = value => String(value ?? '').replace(/[&<>'"]/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;' }[char]));
const render = data => {
  $('relayName').textContent = data.relayName;
  $('bridges').textContent = data.counts.bridges;
  $('devices').textContent = data.counts.devices;
  $('gateways').textContent = data.counts.gateways;
  $('messages').textContent = data.counts.encryptedMessages;
  $('pending').textContent = data.counts.pendingCommands;
  $('uptime').textContent = duration(data.uptimeSeconds);
  $('protocol').textContent = `v${data.protocolVersion} · server ${data.version}`;
  $('storage').textContent = 'RAM only · gateway restores pairing';
  $('discovery').textContent = data.discoveryService || 'Disabled';
  $('relayId').textContent = data.relayId;
  $('transport').textContent = {
    tls: 'TLS · encrypted in transit',
    'trusted-proxy': 'HTTPS at trusted proxy',
  }[data.security.transport] || 'Cleartext · keep on a trusted LAN';
  $('deviceCount').textContent = `${data.devices.length} device${data.devices.length === 1 ? '' : 's'}`;
  $('deviceList').innerHTML = data.devices.length
    ? data.devices.map(device => `<div class="device"><span class="device-icon">${device.capabilities.smsGateway ? 'SIM' : 'APP'}</span><div><strong>${escapeText(device.name)}</strong><small>${device.capabilities.smsGateway ? 'SIM gateway' : 'Client'} · ${escapeText(new Date(device.lastSeenAt).toLocaleString())}</small></div><span class="row-actions"><span class="status">${(device.eventConnected ?? recent(device.lastSeenAt)) ? 'Online' : 'Idle'}</span><button class="secondary small" data-revoke="${escapeText(device.id)}" data-name="${escapeText(device.name)}">Revoke</button></span></div>`).join('')
    : '<p class="empty">No phones have joined this relay.</p>';
  $('bridgeList').innerHTML = (data.bridges || []).length
    ? data.bridges.map(bridge => `<div class="device"><span class="device-icon">${bridge.joinable ? 'OPEN' : 'LOCK'}</span><div><strong>${escapeText(bridge.id.slice(0, 12))}…</strong><small>Created ${escapeText(new Date(bridge.createdAt).toLocaleString())}</small></div><span class="row-actions"><span class="status">${bridge.joinable ? 'Accepting devices' : 'Locked'}</span><button class="secondary small" data-lock="${escapeText(bridge.id)}" data-joinable="${bridge.joinable ? 'false' : 'true'}">${bridge.joinable ? 'Lock' : 'Unlock'}</button><button class="secondary small" data-erase="${escapeText(bridge.id)}">Delete bridge</button></span></div>`).join('')
    : '<p class="empty">No bridges on this relay.</p>';
};
let refreshing = null;
let refreshPending = false;
const refresh = () => {
  refreshPending = true;
  if (refreshing) return refreshing;
  refreshing = (async () => {
    while (refreshPending && relayKey) {
      refreshPending = false;
      render(await request('/v1/admin/status'));
    }
  })().finally(() => {
    refreshing = null;
    if (refreshPending && relayKey) queueMicrotask(() => { void refresh().catch(() => streamHealth(false)); });
  });
  return refreshing;
};
let eventAbort = null;
const streamHealth = online => {
  $('healthLabel').textContent = online ? 'Online · event connection' : 'Relay unavailable · reconnecting';
  document.querySelector('.health').className = `health ${online ? 'online' : 'offline'}`;
};
const stopEvents = () => { eventAbort?.abort(); eventAbort = null; };
const startEvents = () => {
  stopEvents();
  const lifetime = eventAbort = new AbortController();
  const ownerKey = relayKey;
  const pause = milliseconds => new Promise(resolve => {
    if (lifetime.signal.aborted) return resolve();
    const done = () => { clearTimeout(timer); lifetime.signal.removeEventListener('abort', done); resolve(); };
    const timer = setTimeout(done, milliseconds);
    lifetime.signal.addEventListener('abort', done, { once: true });
  });
  void (async () => {
    let failures = 0;
    while (!lifetime.signal.aborted) {
      const attempt = new AbortController();
      const abort = () => attempt.abort();
      lifetime.signal.addEventListener('abort', abort, { once: true });
      let idle;
      const armIdle = () => { clearTimeout(idle); idle = setTimeout(abort, EVENT_IDLE_MS); };
      let reader;
      try {
        armIdle();
        const response = await fetch('/v1/admin/events', {
          headers: { 'x-relay-key': ownerKey, accept: 'text/event-stream' },
          signal: attempt.signal, redirect: 'error', cache: 'no-store',
        });
        if (response.status === 401 || response.status === 403) {
          if (eventAbort === lifetime) {
            relayKey = '';
            $('dashboard').classList.add('hidden');
            $('loginPanel').classList.remove('hidden');
            toast('Owner access rejected. Unlock the dashboard again.');
          }
          lifetime.abort();
          break;
        }
        if (!response.ok || !response.headers.get('content-type')?.startsWith('text/event-stream')) {
          throw new Error('Event connection unavailable');
        }
        reader = response.body.getReader();
        const decoder = new TextDecoder('utf-8', { fatal: true });
        let buffer = '', data = '', frameSize = 0;
        while (!lifetime.signal.aborted) {
          const chunk = await reader.read();
          if (chunk.done) throw new Error('Event connection ended');
          armIdle();
          buffer += decoder.decode(chunk.value, { stream: true });
          let newline;
          while ((newline = buffer.indexOf('\n')) !== -1) {
            if (newline > EVENT_FRAME_MAX) throw new Error('Oversized event line');
            const line = buffer.slice(0, newline).replace(/\r$/, '');
            buffer = buffer.slice(newline + 1);
            if (line === '') {
              if (data) {
                const type = JSON.parse(data).type;
                if (type === 'ready' || type === 'status') {
                  failures = 0;
                  streamHealth(true);
                  void refresh().catch(() => streamHealth(false));
                }
              }
              data = ''; frameSize = 0;
            } else if (line.startsWith(':')) {
              streamHealth(true); // Liveness only: never fetch status on heartbeat.
            } else {
              frameSize += line.length;
              if (frameSize > EVENT_FRAME_MAX) throw new Error('Oversized event frame');
              if (line.startsWith('data:')) data += `${data ? '\n' : ''}${line.slice(5).replace(/^ /, '')}`;
            }
          }
          if (buffer.length > EVENT_FRAME_MAX) throw new Error('Oversized event line');
        }
      } catch {
        if (!lifetime.signal.aborted) streamHealth(false);
      } finally {
        clearTimeout(idle);
        attempt.abort();
        await reader?.cancel().catch(() => {});
        lifetime.signal.removeEventListener('abort', abort);
      }
      if (!lifetime.signal.aborted) {
        await pause(Math.min(1000 * 2 ** Math.min(failures++, 5), EVENT_RETRY_MAX_MS));
      }
    }
  })();
};
window.addEventListener('pagehide', stopEvents);
window.addEventListener('pageshow', event => { if (event.persisted && relayKey) startEvents(); });
const checkHealth = async () => { try { const started = performance.now(); await fetch('/health', { cache: 'no-store' }); $('healthLabel').textContent = `Online · ${Math.round(performance.now() - started)} ms`; document.querySelector('.health').className = 'health online'; } catch { $('healthLabel').textContent = 'Relay unavailable'; document.querySelector('.health').className = 'health offline'; } };
$('connectButton').addEventListener('click', async () => { relayKey = $('relayKey').value; $('connectButton').disabled = true; try { await refresh(); $('loginPanel').classList.add('hidden'); $('dashboard').classList.remove('hidden'); $('relayKey').value = ''; startEvents(); toast('Dashboard unlocked'); } catch (error) { relayKey = ''; toast(error.message); } finally { $('connectButton').disabled = false; } });
$('relayKey').addEventListener('keydown', event => { if (event.key === 'Enter') $('connectButton').click(); });
$('refreshButton').addEventListener('click', async () => { try { await refresh(); toast('Status refreshed'); } catch (error) { toast(error.message); } });

// Delegated: the rows are re-rendered on every refresh, and the page's CSP
// forbids inline handlers.
$('deviceList').addEventListener('click', async event => {
  const button = event.target.closest('[data-revoke]');
  if (!button) return;
  const name = button.getAttribute('data-name');
  if (!confirm(`Revoke "${name}"? The Android gateway must save the change before revocation is confirmed. Enrollment will also close. Revoking the authority gateway deletes the entire bridge.`)) return;
  try {
    await request(`/v1/admin/devices/${encodeURIComponent(button.getAttribute('data-revoke'))}/revoke`, { method: 'POST', body: '{}' });
    toast(`Revoked ${name}`);
    await refresh();
  } catch (error) { toast(error.message); }
});
$('bridgeList').addEventListener('click', async event => {
  const erase = event.target.closest('[data-erase]');
  if (erase) {
    if (!confirm('Delete this bridge? The Android gateway must save the deletion. All devices lose access and pending relay work is removed. Copies already received on devices are unaffected.')) return;
    try {
      await request(`/v1/bridges/${encodeURIComponent(erase.getAttribute('data-erase'))}`, { method: 'DELETE' });
      toast('Bridge deleted');
      await refresh();
    } catch (error) { toast(error.message); }
    return;
  }
  const button = event.target.closest('[data-lock]');
  if (!button) return;
  const joinable = button.getAttribute('data-joinable') === 'true';
  try {
    await request(`/v1/admin/bridges/${encodeURIComponent(button.getAttribute('data-lock'))}/joinable`, { method: 'POST', body: JSON.stringify({ joinable }) });
    toast(joinable ? 'Bridge accepts new devices' : 'Bridge locked');
    await refresh();
  } catch (error) { toast(error.message); }
});

$('latencyButton').addEventListener('click', async () => { const samples = []; $('testOutput').className = 'output'; $('testOutput').textContent = `Running ${LATENCY_SAMPLES} health requests…`; try { for (let i = 0; i < LATENCY_SAMPLES; i++) { const start = performance.now(); await fetch('/health', { cache: 'no-store' }); samples.push(performance.now() - start); } const average = samples.reduce((a, b) => a + b, 0) / samples.length; $('testOutput').className = 'output success'; $('testOutput').textContent = `PASS\nAverage ${average.toFixed(1)} ms · min ${Math.min(...samples).toFixed(1)} ms · max ${Math.max(...samples).toFixed(1)} ms`; } catch (error) { $('testOutput').className = 'output failure'; $('testOutput').textContent = `FAIL\n${error.message}`; } });
$('selfTestButton').addEventListener('click', async () => { $('testOutput').className = 'output'; $('testOutput').textContent = 'Checking relay invariants…'; try { const result = await request('/v1/admin/debug/self-test', { method: 'POST', body: '{}' }); $('testOutput').className = `output ${result.ok ? 'success' : 'failure'}`; $('testOutput').textContent = `${result.ok ? 'PASS' : 'FAIL'}\n${Object.entries(result.checks).map(([name, ok]) => `${ok ? '✓' : '✕'} ${name}`).join('\n')}`; } catch (error) { $('testOutput').className = 'output failure'; $('testOutput').textContent = `FAIL\n${error.message}`; } });
checkHealth();
// Idle status updates arrive on the authenticated event stream. Manual latency
// and refresh actions remain available without periodic network requests.
