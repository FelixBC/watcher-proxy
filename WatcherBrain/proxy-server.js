const http = require('http');
const https = require('https');
const net = require('net');
const fs = require('fs');
const path = require('path');
const url = require('url');

// Configuration
const CONFIG = {
    PORT: process.env.PROXY_PORT || 8080,
    // Whitelist is in parent directory (one level up from WatcherBrain)
    WHITELIST_FILE: path.join(__dirname, '..', 'whitelist.txt'),
    LOG_FILE: path.join(__dirname, 'blocked-requests.log'),
    ERROR_PAGE: path.join(__dirname, 'error-page.html')
};

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

// Reload whitelist periodically (every 30 seconds)
setInterval(() => {
    loadWhitelist();
}, 30000);

// Watch whitelist file for changes
if (fs.existsSync(CONFIG.WHITELIST_FILE)) {
    fs.watchFile(CONFIG.WHITELIST_FILE, (curr, prev) => {
        if (curr.mtime !== prev.mtime) {
            console.log('Whitelist file changed, reloading...');
            loadWhitelist();
        }
    });
}

// Start server
loadWhitelist();
server.listen(CONFIG.PORT, () => {
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
