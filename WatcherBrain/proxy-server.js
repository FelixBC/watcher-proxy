const http = require('http');
const https = require('https');
const net = require('net');
const fs = require('fs');
const path = require('path');
const url = require('url');
const { appendEvent, pruneByTime } = require('./event-log');
const { readChosenPort, writeChosenPort } = require('./proxy-port');

// Crash breadcrumbs: if the proxy dies from an unhandled error, record WHY
// before exiting so the watchdog's restart isn't a mystery later. Exit so the
// watchdog (which owns restart) brings it back cleanly.
process.on('uncaughtException', (e) => {
    try { appendEvent('proxy-crash', e && e.message ? e.message : String(e)); } catch (_) {}
    process.exit(1);
});
process.on('unhandledRejection', (e) => {
    try { appendEvent('proxy-crash', 'promesa sin manejar: ' + (e && e.message ? e.message : String(e))); } catch (_) {}
    process.exit(1);
});

// Configuration
const CONFIG = {
    // Obscure port chosen at install (proxy-port.txt), NOT 8080 — see proxy-port.js.
    // Plan-0007 scaffold mode: self-update spawns a SECOND proxy instance on a
    // scaffold port by setting WATCHER_OVERRIDE_PORT in its env; that instance
    // must NOT read/bind the persisted home port, so the override wins here.
    PORT: (() => {
        const override = parseInt(process.env.WATCHER_OVERRIDE_PORT, 10);
        return (Number.isInteger(override) && override > 0 && override < 65536) ? override : readChosenPort();
    })(),
    // Whitelist is in parent directory (one level up from WatcherBrain)
    WHITELIST_FILE: path.join(__dirname, '..', 'whitelist.txt'),
    LOG_FILE: path.join(__dirname, 'blocked-requests.log'),
    // Persisted timestamp of the last log clear, so retention survives reboots
    // (an interval-only timer resets on every restart and, on a PC that reboots
    // daily, would never actually fire — see LOG_RETENTION_MS below).
    LOG_CLEAR_STAMP: path.join(__dirname, 'blocked-log-cleared-at.txt'),
    // Rolling buffer of the last few ALLOWED hosts, so the dashboard can show
    // what the terminal has been used for. Bounded on purpose (see recordVisit).
    VISITS_FILE: path.join(__dirname, 'recent-visits.json'),
    // First ALLOWED page opened each day (its "first page after the session").
    FIRST_VISIT_FILE: path.join(__dirname, 'first-visit.json'),
    // PLAN 0008: on-disk copy of the last VALID whitelist. Survives a reboot/power-loss
    // so a cold start with an empty/corrupt live whitelist can fall back to it and keep
    // filtering, instead of failing open. Protected from OTA overwrite (self-update.js).
    LASTGOOD_FILE: path.join(__dirname, 'whitelist-lastgood.txt'),
    ERROR_PAGE: path.join(__dirname, 'error-page.html')
};

// Keep only the last N allowed hosts. Small on purpose: the poll ships this
// straight into a bounded column on the machine row (no growing history).
const MAX_VISITS = 25; // rolling buffer of recent allowed pages (matches the blocked-list depth in the fleet)

// Keep the local blocked-requests log to ~15 days so it can't grow forever.
// The dashboard/DB is the durable history; this file is just the buffer the
// agent uploads from, so a full clear here loses nothing already reported.
const LOG_RETENTION_MS = 15 * 24 * 60 * 60 * 1000;

// Whitelist storage
let whitelist = {
    domains: new Set(),
    exactUrls: new Set()
};

// Filter mode: 'filtering' (enforce the whitelist) or 'failopen' (allow ALL).
// PLAN 0008 / golden rule: the catastrophe is NO INTERNET, not "no filter". If the
// whitelist is unusable AND there is no last-known-good anywhere, we must NOT block
// every site (that makes the banca unable to work) — we FAIL OPEN (let everything
// through) so internet is never lost. Filtering resumes automatically when a valid
// whitelist returns; the state is logged so the fleet can see a machine is unfiltered.
let filterMode = 'filtering';

// Parse whitelist text into a {domains, exactUrls} pair. Pure, no side effects.
function parseWhitelistContent(content) {
    const domains = new Set();
    const exactUrls = new Set();
    for (let line of content.split('\n')) {
        line = line.split('#')[0].trim();
        if (!line) continue;
        if (line.startsWith('http://') || line.startsWith('https://')) {
            exactUrls.add(line.toLowerCase());
        } else {
            domains.add(line.toLowerCase().replace(/^https?:\/\//, '').split('/')[0]);
        }
    }
    return { domains, exactUrls };
}

// Read + parse a whitelist file → {content, domains, exactUrls}, or null if the file is
// missing/unreadable.
function readWhitelistFile(filePath) {
    try {
        if (!fs.existsSync(filePath)) return null;
        const content = fs.readFileSync(filePath, 'utf-8');
        const parsed = parseWhitelistContent(content);
        return { content, domains: parsed.domains, exactUrls: parsed.exactUrls };
    } catch (e) {
        return null;
    }
}

function isUsable(parsed) {
    return !!parsed && (parsed.domains.size > 0 || parsed.exactUrls.size > 0);
}

// Hidden+System-safe, write-then-truncate (never momentarily empty) — same durability
// idiom as whitelist-merge.js. Best-effort: the sidecar is a safety net, never break
// the proxy over it.
function writeFileSafe(filePath, content) {
    try {
        const buf = Buffer.from(content, 'utf-8');
        if (!fs.existsSync(filePath)) {
            fs.writeFileSync(filePath, buf);
            return;
        }
        const fd = fs.openSync(filePath, 'r+');
        try {
            fs.writeSync(fd, buf, 0, buf.length, 0);
            fs.ftruncateSync(fd, buf.length);
        } finally {
            fs.closeSync(fd);
        }
    } catch (e) { /* best effort */ }
}

// Persist the current valid whitelist as the on-disk last-known-good, if changed — so a
// cold boot with an empty/corrupt live whitelist falls back to it and RESUMES FILTERING.
function persistLastGood(content) {
    try {
        const cur = fs.existsSync(CONFIG.LASTGOOD_FILE) ? fs.readFileSync(CONFIG.LASTGOOD_FILE, 'utf-8') : null;
        if (cur !== content) writeFileSafe(CONFIG.LASTGOOD_FILE, content);
    } catch (e) { /* best effort */ }
}

function applyWhitelist(parsed, mode) {
    whitelist.domains = parsed.domains;
    whitelist.exactUrls = parsed.exactUrls;
    if (filterMode !== mode) {
        try {
            appendEvent(
                mode === 'failopen' ? 'filter-failopen' : 'filter-on',
                mode === 'failopen' ? 'whitelist inservible y sin respaldo — dejando pasar todo (internet preservado)' : 'filtro activo'
            );
        } catch (_) {}
    }
    filterMode = mode;
}

// Load the whitelist. Precedence (PLAN 0008), NEVER over-block:
//   1) live whitelist.txt if usable  →  filter
//   2) else, good one already IN MEMORY  →  keep it (last-known-good, runtime)
//   3) else, on-disk last-known-good sidecar  →  filter with it (survives reboot)
//   4) else nothing usable anywhere  →  FAIL OPEN (allow all; internet over filter)
function loadWhitelist() {
    const live = readWhitelistFile(CONFIG.WHITELIST_FILE);
    if (isUsable(live)) {
        applyWhitelist(live, 'filtering');
        persistLastGood(live.content);
        console.log(`Loaded ${whitelist.domains.size} domains and ${whitelist.exactUrls.size} exact URLs from whitelist`);
        return;
    }

    if (whitelist.domains.size > 0 || whitelist.exactUrls.size > 0) {
        console.error('Whitelist read as EMPTY/unusable — keeping the in-memory last-known-good (NOT over-blocking).');
        return;
    }

    const disk = readWhitelistFile(CONFIG.LASTGOOD_FILE);
    if (isUsable(disk)) {
        applyWhitelist(disk, 'filtering');
        console.error(`Live whitelist unusable — loaded last-known-good from disk (${whitelist.domains.size} domains). Filtering continues.`);
        return;
    }

    // Nothing usable anywhere → FAIL OPEN. Internet is never lost; filter resumes when a
    // valid whitelist returns (next reload flips back to 'filtering').
    applyWhitelist({ domains: new Set(), exactUrls: new Set() }, 'failopen');
    console.error('Whitelist unusable and no last-known-good — FAIL OPEN (allowing all; internet preserved, filter off).');
}

// Check if hostname is an IP address (IPv4 or IPv6)
function isIpAddress(hostname) {
    if (!hostname) return false;
    const v4 = /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(hostname);
    const v6 = hostname.includes(':');
    return v4 || v6;
}

// Check if URL is whitelisted
function isWhitelisted(url) {
    // PLAN 0008 fail-open floor: when the whitelist is unusable and we have no
    // last-known-good, allow EVERYTHING (internet over filter). Covers both the HTTP
    // request path and the HTTPS CONNECT path, since both gate on this function.
    if (filterMode === 'failopen') return true;
    try {
        const urlLower = url.toLowerCase();
        
        // Check exact URL match first
        if (whitelist.exactUrls.has(urlLower)) {
            return true;
        }

        // Parse URL to get hostname
        let hostname;
        try {
            const urlObj = new URL(url.startsWith('http') ? url : `http://${url}`);
            hostname = urlObj.hostname.toLowerCase();
        } catch (e) {
            // If URL parsing fails, try to extract domain manually
            hostname = urlLower.replace(/^https?:\/\//, '').split('/')[0].split(':')[0];
        }

        // Allow CONNECT to IP addresses (e.g. UltraViewer and other apps that connect by IP)
        if (isIpAddress(hostname)) return true;

        // Check domain match (including subdomains)
        for (const domain of whitelist.domains) {
            if (hostname === domain || hostname.endsWith('.' + domain)) {
                return true;
            }
        }

        return false;
    } catch (error) {
        console.error(`Error checking whitelist for ${url}:`, error.message);
        return false;
    }
}

// Log blocked request
function logBlockedRequest(url, ip) {
    const timestamp = new Date().toISOString();
    const logEntry = `[${timestamp}] BLOCKED: ${url} (from ${ip})\n`;
    
    try {
        fs.appendFileSync(CONFIG.LOG_FILE, logEntry, 'utf-8');
    } catch (error) {
        console.error(`Error writing to log file: ${error.message}`);
    }
}

// Record an ALLOWED host into the bounded rolling buffer (newest first, no
// consecutive duplicates). Fail-open: a write hiccup must never disturb the
// proxy path, so this only touches a tiny side file.
let recentVisits = [];
try {
    if (fs.existsSync(CONFIG.VISITS_FILE)) {
        const parsed = JSON.parse(fs.readFileSync(CONFIG.VISITS_FILE, 'utf-8'));
        if (Array.isArray(parsed)) recentVisits = parsed.slice(0, MAX_VISITS);
    }
} catch { /* start empty */ }

function recordVisit(host) {
    if (!host) return;
    if (recentVisits[0] && recentVisits[0].host === host) {
        recentVisits[0].at = new Date().toISOString(); // same site again → just refresh time
    } else {
        recentVisits.unshift({ host, at: new Date().toISOString() });
    }
    recentVisits = recentVisits.slice(0, MAX_VISITS);
    try {
        fs.writeFileSync(CONFIG.VISITS_FILE, JSON.stringify(recentVisits), 'utf-8');
    } catch { /* fail-open: dashboard nicety, never break the proxy */ }
    recordFirstOfDay(host);
}

// Hosts that phone home on their OWN at boot/idle — Windows/Office/Edge telemetry,
// connectivity probes, update channels, MSN/Bing new-tab junk, Chrome's updater.
// These fire without the cajero doing anything, so they mark ~power-on, not work.
// Used ONLY to tell "1ª página con ruido" (first anything) from "1ª sin ruido"
// (first REAL page ≈ when the cajero opened the banca). Substring match, lowercased.
// A lottery terminal never browses these as work, so false-positives are harmless;
// the banca (konfyanslotto/elite21) is deliberately absent → it counts as real.
const BACKGROUND_NOISE = [
    'msftconnecttest.com', 'msftncsi.com', 'connecttest', 'connectivitycheck', 'dns.google',
    'windowsupdate.com', 'update.microsoft', 'delivery.mp.microsoft', 'do.dsp.mp.microsoft',
    'dl.delivery.mp.microsoft', 'ctldl.windowsupdate.com', 'edgedl', 'time.windows.com',
    'events.data.microsoft.com', 'settings-win.data.microsoft.com', 'watson.telemetry',
    'vortex.data.microsoft', 'telemetry.microsoft', 'v10.events.data', 'v20.events.data',
    'edge.microsoft.com', 'edge-consumer-static', 'edge-mobile-static',
    'msn.com', 'img-s-msn-com', 'sfx.ms', 'live.net', 'login.live.com', 'skype',
    'microsoft365.com', 'officehub', 'officeapps.live.com', 'office.net', 'office365.com',
    'bing.com', 'clients2.google.com', 'clients4.google.com', 'update.googleapis',
    'gvt1.com', 'gvt2.com',
];
function isBackgroundNoise(host) {
    if (!host) return true; // no host → never counts as a real first page
    const h = String(host).toLowerCase();
    return BACKGROUND_NOISE.some((n) => h.includes(n));
}

// The first allowed hosts of the LOCAL calendar day, kept as TWO values so the
// fleet can show power-on vs. cajero-start: `host`/`at` = first ANYTHING (con
// ruido), `realHost`/`realAt` = first NON-noise page (sin ruido). Overwritten
// only when the day rolls over, so both survive watchdog restarts within the day.
// Cheap: once both are filled for the day it's a no-op (reads a tiny file).
function recordFirstOfDay(host) {
    try {
        const today = new Date().toLocaleDateString('en-CA'); // YYYY-MM-DD (local)
        const now = new Date().toISOString();
        let cur = null;
        if (fs.existsSync(CONFIG.FIRST_VISIT_FILE)) {
            cur = JSON.parse(fs.readFileSync(CONFIG.FIRST_VISIT_FILE, 'utf-8'));
        }
        if (!cur || cur.day !== today) cur = { day: today };
        let changed = false;
        if (!cur.host) { cur.host = host; cur.at = now; changed = true; }             // 1ª con ruido
        if (!cur.realHost && !isBackgroundNoise(host)) { cur.realHost = host; cur.realAt = now; changed = true; } // 1ª sin ruido
        if (changed) fs.writeFileSync(CONFIG.FIRST_VISIT_FILE, JSON.stringify(cur), 'utf-8');
    } catch { /* fail-open */ }
}

// Reboot-proof retention: clear blocked-requests.log only when at least
// LOG_RETENTION_MS has passed since the last clear, tracked by a persisted
// timestamp file. Called on startup AND on a daily interval, so it fires on
// the next run even if the PC rebooted before an in-memory timer could — a
// plain setInterval(15 days) would silently never trigger on a machine that
// restarts more often than that.
function readLastClearMs() {
    try {
        if (fs.existsSync(CONFIG.LOG_CLEAR_STAMP)) {
            const t = Date.parse(fs.readFileSync(CONFIG.LOG_CLEAR_STAMP, 'utf-8').trim());
            if (!Number.isNaN(t)) return t;
        }
    } catch (error) {
        console.error(`Error reading log-clear stamp: ${error.message}`);
    }
    return null;
}

function pruneBlockedRequestsLogIfDue() {
    try {
        const now = Date.now();
        const last = readLastClearMs();
        // First run ever: don't clear immediately, just anchor the timestamp.
        if (last === null) {
            fs.writeFileSync(CONFIG.LOG_CLEAR_STAMP, new Date(now).toISOString(), 'utf-8');
            return;
        }
        if (now - last < LOG_RETENTION_MS) return;
        if (fs.existsSync(CONFIG.LOG_FILE)) {
            fs.writeFileSync(CONFIG.LOG_FILE, '', 'utf-8');
        }
        fs.writeFileSync(CONFIG.LOG_CLEAR_STAMP, new Date(now).toISOString(), 'utf-8');
        console.log(`Blocked requests log cleared (retention ${LOG_RETENTION_MS / 86400000} days).`);
    } catch (error) {
        console.error(`Error pruning log file: ${error.message}`);
    }
}

// Read error page HTML
let errorPageHtml = null;
function getErrorPage() {
    if (errorPageHtml) return errorPageHtml;
    
    try {
        if (fs.existsSync(CONFIG.ERROR_PAGE)) {
            errorPageHtml = fs.readFileSync(CONFIG.ERROR_PAGE, 'utf-8');
        } else {
            // Default error page
            errorPageHtml = `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>404 Not Found</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
            display: flex;
            justify-content: center;
            align-items: center;
            min-height: 100vh;
            margin: 0;
            background: #f5f5f5;
            color: #333;
        }
        .container {
            text-align: center;
        }
        h1 {
            font-size: 6rem;
            margin: 0;
            color: #666;
            font-weight: 300;
        }
        p {
            font-size: 1.2rem;
            color: #999;
            margin-top: 1rem;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>404</h1>
        <p>Not Found</p>
    </div>
</body>
</html>`;
        }
    } catch (error) {
        console.error(`Error reading error page: ${error.message}`);
        errorPageHtml = '<h1>404</h1><p>Not Found</p>';
    }
    
    return errorPageHtml;
}

// Create proxy server
const server = http.createServer((req, res) => {
    const clientIp = req.headers['x-forwarded-for'] || 
                     req.connection.remoteAddress || 
                     req.socket.remoteAddress ||
                     'unknown';

    // Extract target URL from request
    // For HTTP proxy, the URL is in req.url (full URL like http://example.com/path)
    let targetUrl = req.url;
    
    // If req.url doesn't start with http:// or https://, construct it from headers
    if (!targetUrl.startsWith('http://') && !targetUrl.startsWith('https://')) {
        const host = req.headers['host'];
        if (host) {
            targetUrl = `http://${host}${targetUrl}`;
        }
    }

    // Parse the target URL
    let targetHost, targetPort, targetPath, targetProtocol;
    try {
        const urlObj = new URL(targetUrl);
        targetHost = urlObj.hostname;
        targetPort = urlObj.port || (urlObj.protocol === 'https:' ? 443 : 80);
        targetPath = urlObj.pathname + urlObj.search;
        targetProtocol = urlObj.protocol === 'https:' ? 'https' : 'http';
    } catch (e) {
        res.writeHead(400, { 'Content-Type': 'text/plain' });
        res.end('Invalid URL');
        return;
    }

    const fullUrl = `${targetProtocol}://${targetHost}${targetPath === '/' ? '' : targetPath}`;
    const domainUrl = `${targetProtocol}://${targetHost}`;

    // Check whitelist
    if (!isWhitelisted(fullUrl) && !isWhitelisted(domainUrl)) {
        logBlockedRequest(fullUrl, clientIp);
        res.writeHead(404, { 'Content-Type': 'text/html' });
        res.end(getErrorPage());
        return;
    }
    recordVisit(targetHost);

    // Create proxy request
    const options = {
        hostname: targetHost,
        port: targetPort,
        path: targetPath,
        method: req.method,
        headers: { ...req.headers }
    };

    // Remove proxy-specific headers
    delete options.headers['proxy-connection'];
    delete options.headers['connection'];
    delete options.headers['host'];

    const proxyReq = (targetProtocol === 'https' ? https : http).request(options, (proxyRes) => {
        // Forward status code and headers
        res.writeHead(proxyRes.statusCode, proxyRes.headers);
        // Pipe response
        proxyRes.pipe(res);
    });

    proxyReq.on('error', (err) => {
        console.error(`Proxy error for ${fullUrl}: ${err.message}`);
        if (!res.headersSent) {
            res.writeHead(500, { 'Content-Type': 'text/plain' });
            res.end('Proxy Error: ' + err.message);
        }
    });

    // Pipe request body
    req.pipe(proxyReq);
});

// Handle CONNECT method for HTTPS tunneling
server.on('connect', (req, socket, head) => {
    const clientIp = socket.remoteAddress || 'unknown';
    const [hostname, port] = req.url.split(':');
    const targetPort = parseInt(port) || 443;
    const fullUrl = `https://${hostname}:${targetPort}`;

    // Check whitelist
    if (!isWhitelisted(fullUrl)) {
        logBlockedRequest(fullUrl, clientIp);
        socket.write('HTTP/1.1 404 Not Found\r\n\r\n');
        socket.end();
        return;
    }
    recordVisit(hostname);

    // Create tunnel to target server
    const proxySocket = net.createConnection(targetPort, hostname, () => {
        socket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
        proxySocket.write(head);
        socket.pipe(proxySocket);
        proxySocket.pipe(socket);
    });

    proxySocket.on('error', (err) => {
        console.error(`Tunnel error for ${fullUrl}: ${err.message}`);
        socket.end();
    });

    socket.on('error', (err) => {
        console.error(`Socket error: ${err.message}`);
        proxySocket.end();
    });
});

// Reload whitelist periodically (every 60 sec; gentle on low-end PCs; watchFile still reloads on save)
setInterval(() => {
    loadWhitelist();
}, 60000);

// Enforce log retention: once now, then once a day. The daily check is cheap
// and, combined with the persisted timestamp, guarantees the 15-day clear
// happens on the next run regardless of how often the PC reboots.
pruneBlockedRequestsLogIfDue();
pruneByTime(); // trim the events.log audit trail to its time window too
const ONE_DAY_MS = 24 * 60 * 60 * 1000;
setInterval(pruneBlockedRequestsLogIfDue, ONE_DAY_MS);
setInterval(pruneByTime, ONE_DAY_MS);

// Watch whitelist file for changes
if (fs.existsSync(CONFIG.WHITELIST_FILE)) {
    fs.watchFile(CONFIG.WHITELIST_FILE, (curr, prev) => {
        if (curr.mtime !== prev.mtime) {
            console.log('Whitelist file changed, reloading...');
            loadWhitelist();
        }
    });
}

// The listen port IS our single-instance lock. On real hardware several logon
// layers (the logon task, the 5s watchdog, the 1-min safety net, the service)
// all race to start the proxy at once — before this, the losers hit EADDRINUSE
// but stayed alive-but-not-listening (the setInterval/watchFile timers keep the
// process up), leaking a dead node on every logon and, multiplied, driving the
// EADDRINUSE crash loop that took a real terminal's internet down. Now the loser
// exits CLEANLY (0): the one that bound 8080 keeps serving, so exactly one proxy
// runs no matter how many launchers fire, on any machine. Any OTHER server error
// is a genuine failure — record it and exit non-zero so the watchdog restarts us.
server.on('error', (err) => {
    if (err && err.code === 'EADDRINUSE') {
        try { appendEvent('proxy-dup-exit', `${CONFIG.PORT} ya en uso por otra instancia; saliendo limpio (0)`); } catch (_) {}
        process.exit(0);
    }
    try { appendEvent('proxy-error', err && err.message ? err.message : String(err)); } catch (_) {}
    process.exit(1);
});

// Start server
loadWhitelist();
server.listen(CONFIG.PORT, () => {
    // Record the port we actually bound so every checker/setter agrees on it.
    // Plan-0007 exception: the scaffold proxy (spawned by self-update with
    // WATCHER_NO_PERSIST_PORT=1) is transient and must NOT overwrite proxy-port.txt
    // with its scaffold port — self-update owns that file during the cutover, and
    // every watchdog/checker must keep reading the home port for the whole thing.
    if (process.env.WATCHER_NO_PERSIST_PORT !== '1') {
        try { writeChosenPort(CONFIG.PORT); } catch (_) {}
    }
    try { appendEvent('proxy-up', `escuchando 127.0.0.1:${CONFIG.PORT}`); } catch (_) {}
    console.log(`\n========================================`);
    console.log(`  Proxy Server Started Successfully`);
    console.log(`========================================`);
    console.log(`  Port: ${CONFIG.PORT}`);
    console.log(`  Whitelist: ${CONFIG.WHITELIST_FILE}`);
    console.log(`  Log File: ${CONFIG.LOG_FILE}`);
    console.log(`\n  Configure your browser/system to use:`);
    console.log(`  Proxy: localhost:${CONFIG.PORT}`);
    console.log(`\n  Press Ctrl+C to stop the server`);
    console.log(`========================================\n`);
});

// Handle graceful shutdown
process.on('SIGINT', () => {
    console.log('\nShutting down proxy server...');
    server.close(() => {
        console.log('Proxy server stopped.');
        process.exit(0);
    });
});

process.on('SIGTERM', () => {
    console.log('\nShutting down proxy server...');
    server.close(() => {
        console.log('Proxy server stopped.');
        process.exit(0);
    });
});
