// Shared HTTP network guards for the dsh-files upload surface. Mirrors the
// official dsh-files-button contract: loopback-only host by default, plus
// same-origin and same-site checks. The upload endpoint runs these before
// touching any session or path.
//
// Deployments behind a public domain / reverse tunnel (Caddy, frp) serve the
// GUI through `dsh web --trusted-host`, but this fence only sees the socket
// it owns: the official /api fence accepts those hosts while a hardcoded
// loopback check would reject every upload. `trustedHosts` reuses the same
// semantics — bare host matches any port, `host:port` matches exactly — and
// the Origin check compares the host part only, so TLS terminating upstream
// (plain HTTP socket, https browser Origin) still passes.
const LOOPBACK_HOSTNAMES = new Set(['127.0.0.1', 'localhost', '::1', '[::1]']);
/** Split a raw Host/Origin into host (with port), hostname and port; null for malformed input. */
export function parseHost(raw) {
    const input = raw.trim();
    if (input === '')
        return null;
    try {
        const url = new URL(/^[a-z][a-z\d+.-]*:\/\//i.test(input) ? input : `http://${input}`);
        return { host: url.host, hostname: url.hostname, port: url.port || null };
    }
    catch {
        return null;
    }
}
function isLoopbackHostname(hostname) {
    return LOOPBACK_HOSTNAMES.has(hostname);
}
/**
 * A configured trusted host entry accepts the request Host:
 * - bare `host` matches any port,
 * - `host:port` matches exactly (mirrors the official isTrustedAuthority semantics).
 */
function matchesTrusted(parsed, trustedHosts) {
    if (trustedHosts.length === 0)
        return false;
    return trustedHosts.some((entry) => {
        const parsedEntry = parseHost(entry);
        if (parsedEntry === null)
            return false;
        if (parsedEntry.port !== null)
            return parsed.host === parsedEntry.host;
        return parsed.hostname === parsedEntry.hostname;
    });
}
/**
 * Reject requests that are not loopback (or a configured trusted host),
 * same-origin and same-site. Returns a human-readable reason, or null when
 * the request passes.
 */
export function networkGuard(req, trustedHosts = []) {
    const rawHost = String(req.headers?.host ?? '');
    const parsedHost = parseHost(rawHost);
    if (parsedHost === null)
        return 'forbidden: malformed host';
    if (!isLoopbackHostname(parsedHost.hostname) && !matchesTrusted(parsedHost, trustedHosts)) {
        return 'forbidden: non-loopback host';
    }
    const origin = req.headers?.origin;
    if (origin !== undefined) {
        const parsedOrigin = parseHost(origin);
        // Origin 只比较 host 部分：TLS 在上游终结时 socket 是明文 http 而浏览器
        // Origin 是 https，scheme 参与比较会误杀同一部署（与官方栅栏一致）。
        if (parsedOrigin === null || parsedOrigin.hostname !== parsedHost.hostname) {
            return 'forbidden: cross-origin';
        }
    }
    const secFetchSite = req.headers?.['sec-fetch-site'];
    if (secFetchSite !== undefined && secFetchSite !== 'same-origin' && secFetchSite !== 'none') {
        return 'forbidden: cross-site';
    }
    return null;
}
/** Write a JSON error response. */
export function jsonError(res, status, error) {
    res.writeHead(status, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error }));
}
