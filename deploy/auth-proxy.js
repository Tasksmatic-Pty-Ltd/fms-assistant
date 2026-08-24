#!/usr/bin/env node
// fms-assistant auth reverse proxy — the LOGIN GATE in front of the harness
// web UI.
//
// The browser stays on THIS origin for everything, so there is never a
// cross-origin redirect (Turbo / same-origin rules cannot interfere):
//   - /users/sign_in* (GET/POST)  → proxied to Rails; the login page's HTML
//     asset URLs (/assets/*) are REWRITTEN to the FMS origin, so the login
//     page renders here but pulls its public files straight from Rails.
//   - everything else             → FMS session cookie validated against Rails
//     GET /assistant/session_status; 401 → 302 to /users/sign_in on this
//     origin, 200 → proxied to the harness (streaming, WebSocket kept).
//
// IMPORTANT: the harness's OWN static files live under /assets/* too (Vite
// output), so /assets/* is NEVER routed to Rails — only the login page's HTML
// is rewritten to point its assets at the FMS origin directly.
//
// Env:
//   PORT          listen port (default 3082)
//   TARGET        the harness web URL (default http://127.0.0.1:3081)
//   FMS_ORIGIN    the Rails app origin (default http://127.0.0.1:3000)
import http from 'node:http';
import zlib from 'node:zlib';

const PORT = Number(process.env.PORT || 3082);
const TARGET = process.env.TARGET || 'http://127.0.0.1:3081';
const FMS_ORIGIN = process.env.FMS_ORIGIN || 'http://127.0.0.1:3000';

const target = new URL(TARGET);
const fms = new URL(FMS_ORIGIN);

// Paths proxied to Rails WITHOUT a session check — the login flow itself.
function isPublicFmsPath(pathname) {
  return pathname === '/users/sign_in' || pathname.startsWith('/users/sign_in/') ||
         pathname === '/favicon.ico';
}

// The employee this instance belongs to. An instance carries exactly ONE
// employee's MCP token (FMS_MCP_TOKEN), so "someone is signed in" is NOT
// enough — the signed-in user must BE this owner, or any FMS user reaching
// the assistant URL would query with the token owner's whole Ability.
// Required, fail-closed: without it every request is refused with a clear
// reason instead of silently opening the instance to everyone.
//
// Trimmed, and blank-after-trim treated as unset (matches the Rails side:
// AssistantAccess.external_owner_username does `.to_s.strip.presence`). A
// stray space in a .env line is invisible in a terminal — without this, FMS
// could show the button (its comparison is symmetric) while this exact
// verbatim check still 403s the person who clicked it.
const OWNER_USERNAME = process.env.FMS_OWNER_USERNAME?.trim() || undefined;

// => { ok, username, reason } — ok means a valid FMS session AND (when the
// instance declares an owner) the signed-in user IS that owner.
function checkSession(cookieHeader) {
  return new Promise((resolve) => {
    const req = http.request(
      `${FMS_ORIGIN}/assistant/session_status`,
      { method: 'GET', headers: { Cookie: cookieHeader || '' } },
      (res) => {
        let body = '';
        res.on('data', (c) => (body += c));
        res.on('end', () => {
          if (res.statusCode !== 200) return resolve({ ok: false, username: null, reason: 'no-session' });
          let identity = null;
          try { identity = JSON.parse(body).user || null; } catch { identity = null; }
          const username = identity && identity.username;
          if (!OWNER_USERNAME) return resolve({ ok: false, username, reason: 'unconfigured' });
          if (username !== OWNER_USERNAME) return resolve({ ok: false, username, reason: 'mismatch' });
          resolve({ ok: true, username, reason: null });
        });
      },
    );
    req.on('error', () => resolve({ ok: false, username: null, reason: 'no-session' }));
    req.setTimeout(5000, () => { req.destroy(); resolve({ ok: false, username: null, reason: 'no-session' }); });
    req.end();
  });
}

// Write the gate failure response. No session → the same-origin login page
// (with return_to back here). Signed in but wrong/unconfigured owner → a
// plain 403 (redirecting would loop — they ARE logged in).
function writeGateFailure(res, gate, returnTo) {
  if (gate.reason === 'no-session') {
    res.writeHead(302, { Location: `/users/sign_in?return_to=${encodeURIComponent(returnTo)}` });
    res.end();
    return;
  }
  const msg = gate.reason === 'unconfigured'
    ? 'assistant instance not configured: FMS_OWNER_USERNAME is not set in the proxy environment'
    : `this assistant instance is bound to employee "${OWNER_USERNAME}"; sign in with that account`;
  res.writeHead(403, { 'Content-Type': 'text/plain' });
  res.end(msg);
}

// Rewrite absolute-root asset URLs in the login HTML so the browser pulls the
// login page's public files from Rails directly instead of this proxy (whose
// /assets/* must stay reserved for the harness).
function rewriteFmsAssets(body) {
  return body
    .replaceAll(/(src|href)="\/assets\//g, `$1="${FMS_ORIGIN}/assets/`)
    .replaceAll(/(src|href)="\/favicon\.ico"/g, `$1="${FMS_ORIGIN}/favicon.ico"`);
}

function backendOrigin(backend) {
  return backend === fms ? FMS_ORIGIN : `${target.protocol}//${target.host}`;
}

function proxyTo(backend, req, res, pathname) {
  const headers = { ...req.headers, host: backend.host };
  if (headers.origin) {
    // The browser's origin is THIS proxy (e.g. http://127.0.0.1:3082), but the
    // backends check it against the Host they see (which we rewrite to their
    // own): Rails' CSRF compares Origin to base_url, and the harness's /api
    // fence requires Origin.host === Host.host. Present the backend's own
    // origin so both checks pass, while the browser itself stays on ours.
    headers.origin = backendOrigin(backend);
  }
  const proxy = http.request({
    host: backend.hostname,
    port: backend.port || (backend.protocol === 'https:' ? 443 : 80),
    path: pathname,
    method: req.method,
    headers,
  }, (pRes) => {
    const type = String(pRes.headers['content-type'] || '');
    const rewrite = backend === fms && type.includes('text/html');
    if (rewrite) {
      const chunks = [];
      pRes.on('data', (c) => chunks.push(c));
      pRes.on('end', () => {
        const headers = { ...pRes.headers };
        delete headers['content-length']; // body length changes after rewrite
        res.writeHead(pRes.statusCode || 502, headers);
        res.end(rewriteFmsAssets(Buffer.concat(chunks).toString('utf8')));
      });
      pRes.on('error', () => res.end());
      return;
    }
    res.writeHead(pRes.statusCode || 502, pRes.headers);
    pRes.pipe(res);
  });
  proxy.on('error', () => {
    if (!res.headersSent) res.writeHead(502, { 'Content-Type': 'text/plain' });
    res.end('upstream unavailable');
  });
  req.pipe(proxy);
}

function requestUrl(req) {
  const proto = req.headers['x-forwarded-proto']?.split(',')[0].trim() || 'http';
  return `${proto}://${req.headers.host || ''}${req.url || ''}`;
}

const server = http.createServer(async (req, res) => {
  const pathname = req.url.split('?')[0];
  if (isPublicFmsPath(pathname)) {
    proxyTo(fms, req, res, req.url);
    return;
  }

  const gate = await checkSession(req.headers.cookie);
  if (!gate.ok) {
    writeGateFailure(res, gate, requestUrl(req));
    return;
  }

  // The composer's "文档" upload — /api/assistant/* — goes to Rails, not the
  // harness: the browser's FMS session cookie rides along and Rails resolves
  // the employee from it (the session check above already gated on it).
  if (pathname.startsWith('/api/assistant/')) {
    // The upload endpoint accepts the FMS session cookie (the login gate
    // already proved it valid), so a cross-site form POST would carry the
    // victim's cookie straight through. The composer upload is same-origin
    // with this proxy; refuse any Origin that is not this host. NEVER let an
    // unparseable Origin (e.g. "null" from an opaque origin, or a scheme-less
    // value from a script) crash the proxy — treat it as a mismatch → 403,
    // and let a curl/API client with no Origin through (it still needs a
    // valid session cookie).
    const originHeader = req.headers.origin;
    if (originHeader) {
      let originHost = null;
      try { originHost = new URL(originHeader).host; } catch { /* unparseable */ }
      if (!originHost || originHost !== req.headers.host) {
        res.writeHead(403, { 'Content-Type': 'text/plain' });
        res.end('cross-origin upload refused');
        return;
      }
    }
    proxyTo(fms, req, res, req.url);
    return;
  }

  proxyTo(target, req, res, req.url);
});

// WebSocket upgrade (the harness client uses WS for RPC/HMR transports).
server.on('upgrade', async (req, socket, head) => {
  // A browser disconnecting mid-handshake (ECONNRESET) must never crash the
  // proxy — swallow socket errors on both sides and just tear down.
  const safe = (s, other) => s.on('error', () => other?.destroy());
  safe(socket);
  console.error('[auth-proxy] upgrade', req.url, 'cookie=', req.headers.cookie ? req.headers.cookie.slice(0, 40) + '...' : '(none)');
  const gate = await checkSession(req.headers.cookie);
  console.error('[auth-proxy] upgrade result', gate.ok ? 'OK' : `${gate.reason}${gate.username ? ` (${gate.username})` : ''}`);
  if (!gate.ok) {
    if (gate.reason === 'no-session') {
      socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
    } else {
      const msg = gate.reason === 'unconfigured'
        ? 'assistant instance not configured: FMS_OWNER_USERNAME is not set in the proxy environment'
        : `this assistant instance is bound to employee "${OWNER_USERNAME}"; sign in with that account`;
      socket.write(`HTTP/1.1 403 Forbidden\r\ncontent-type: text/plain\r\ncontent-length: ${Buffer.byteLength(msg)}\r\n\r\n${msg}`);
    }
    socket.destroy();
    return;
  }
  const proxy = http.request({
    host: target.hostname,
    port: target.port || 80,
    path: req.url,
    method: 'GET',
    headers: { ...req.headers, host: target.host, ...(req.headers.origin ? { origin: backendOrigin(target) } : {}) },
  });
  safe(proxy);
  proxy.on('upgrade', (pRes, pSocket, pHead) => {
    safe(pSocket, socket);
    safe(socket, pSocket);
    // Forward the upstream's REAL 101 headers — the client validates
    // Sec-WebSocket-Accept against its own key, so a hand-crafted response
    // fails the handshake (which broke the harness RPC channel and made the
    // workspace list fail to load).
    const lines = ['HTTP/1.1 101 Switching Protocols'];
    for (const [k, v] of Object.entries(pRes.headers)) {
      lines.push(`${k}: ${Array.isArray(v) ? v.join(', ') : v}`);
    }
    socket.write(lines.join('\r\n') + '\r\n\r\n');
    if (pHead && pHead.length) socket.write(pHead);
    pSocket.pipe(socket).pipe(pSocket);
  });
  // A non-101 upstream answer (e.g. the harness rejecting the upgrade with
  // 403) currently left the client socket hanging — "WebSocket is closed
  // before the connection is established". Forward the status and log it.
  proxy.on('response', (pRes) => {
    console.error('[auth-proxy] upgrade upstream responded', pRes.statusCode, req.url);
    socket.write(`HTTP/1.1 ${pRes.statusCode} ${pRes.statusMessage || ''}\r\nconnection: close\r\n\r\n`);
    socket.destroy();
    pRes.resume();
  });
  proxy.on('error', () => socket.destroy());
  proxy.end();
});

// Bind 0.0.0.0, not loopback: docker-compose publishes $ASSISTANT_PORT:3082
// to the CONTAINER's eth0 address, so a 127.0.0.1 bind inside the container is
// unreachable from outside (the healthcheck, running in-container, would still
// pass and hide the breakage). Override with HOST for a host-only deployment.
const HOST = process.env.HOST || '0.0.0.0';
server.listen(PORT, HOST, () => {
  console.error(`[auth-proxy] listening on http://${HOST}:${PORT} -> ${TARGET} (login served on this origin, auth via ${FMS_ORIGIN})`);
});
