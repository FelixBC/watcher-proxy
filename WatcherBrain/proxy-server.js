const http = require('http');
const https = require('https');
const net = require('net');
const fs = require('fs');
const path = require('path');
const url = require('url');
const { appendEvent, pruneByTime } = require('./event-log');

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
    PORT: process.env.PROXY_PORT || 8080,
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
    ERROR_PAGE: path.join(__dirname, 'error-page.html')
};

// Keep only the last N allowed hosts. Small on purpose: the poll ships this
// straight into a bounded column on the machine row (no growing history).
const MAX_VISITS = 3;

// Keep the local blocked-requests log to ~15 days so it can't grow forever.
// The dashboard/DB is the durable history; this file is just the buffer the
// agent uploads from, so a full clear here loses nothing already reported.
const LOG_RETENTION_MS = 15 * 24 * 60 * 60 * 1000;

// Whitelist storage
let whitelist = {
    domains: new Set(),
    exactUrls: new Set()
};

// Load and parse whitelist
function loadWhitelist() {
    try {
        if (!fs.existsSync(CONFIG.WHITELIST_FILE)) {
            console.warn(`Warning: Whitelist file not found at ${CONFIG.WHITELIST_FILE}`);
            console.warn('Creating default whitelist.txt file...');
            createDefaultWhitelist();
            return;
        }

        const content = fs.readFileSync(CONFIG.WHITELIST_FILE, 'utf-8');
        const lines = content.split('\n');
        
        whitelist.domains.clear();
        whitelist.exactUrls.clear();

        for (let line of lines) {
            // Remove comments and trim
            line = line.split('#')[0].trim();
            
            if (!line) continue;

            // Check if it's an exact URL (starts with http:// or https://)
            if (line.startsWith('http://') || line.startsWith('https://')) {
                whitelist.exactUrls.add(line.toLowerCase());
            } else {
                // It's a domain - normalize it
                const domain = line.toLowerCase().replace(/^https?:\/\//, '').split('/')[0];
                whitelist.domains.add(domain);
            }
        }

        console.log(`Loaded ${whitelist.domains.size} domains and ${whitelist.exactUrls.size} exact URLs from whitelist`);
    } catch (error) {
        console.error(`Error loading whitelist: ${error.message}`);
        console.error('Continuing with empty whitelist (all requests will be blocked)');
    }
}

function createDefaultWhitelist() {
    const defaultContent = `# URL Whitelist Configuration
# Add one URL or domain per line
# Lines starting with # are comments
# 
# Examples:
# google.com          (allows all Google subdomains)
# youtube.com         (allows all YouTube subdomains)
# https://github.com/specific-repo  (allows only this exact URL)

# Add your allowed domains/URLs below:
`;
    fs.writeFileSync(CONFIG.WHITELIST_FILE, defaultContent, 'utf-8');
    console.log('Created default whitelist.txt file');
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

// Server-level errors (e.g. port already in use) are a Watcher-side failure —
// record the reason so it's not just "proxy down" with no cause.
server.on('error', (err) => {
    try { appendEvent('proxy-error', err && err.message ? err.message : String(err)); } catch (_) {}
});

// Start server
loadWhitelist();
server.listen(CONFIG.PORT, () => {
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
