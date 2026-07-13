// Shared helpers for talking to the watcher-fleet hub.
//
// IMPORTANT: uses Node's built-in `https` module directly, NOT a library
// that might honor HTTP_PROXY/HTTPS_PROXY env vars or WinINET settings.
// Node's core http/https do not consult the Windows system proxy registry at
// all, so calls made here always go straight to the internet — they can
// never be blocked by this machine's own whitelist filter, and never need
// the hub's domain added to whitelist.txt. This is the fix for the
// bootstrap problem: the update/poll mechanism must not depend on the very
// thing it manages.
'use strict';

const fs = require('fs');
const path = require('path');
const https = require('https');
const http = require('http');

const BRAIN_DIR = __dirname;
const HUB_CONFIG_PATH = path.join(BRAIN_DIR, 'HubConfig.json');
const CREDENTIAL_PATH = path.join(BRAIN_DIR, 'hub-credential.json');

// Picks the transport by the URL's own scheme rather than hardcoding https.
// Production HubUrl is always https:// (Vercel), so this changes nothing
// there — it only makes a plain http:// HubUrl (a local/dev hub) actually
// work, instead of forcing a TLS handshake at the socket and failing with
// an opaque "wrong version number" OpenSSL error.
function transportFor(url) {
    return url.protocol === 'http:' ? http : https;
}

function readHubConfig() {
    if (!fs.existsSync(HUB_CONFIG_PATH)) {
        throw new Error(
            `HubConfig.json not found at ${HUB_CONFIG_PATH}. Copy HubConfig.example.json, ` +
            `fill in the real EnrollmentSecret, and place it here before packaging for install.`
        );
    }
    return JSON.parse(fs.readFileSync(HUB_CONFIG_PATH, 'utf-8'));
}

function readCredential() {
    if (!fs.existsSync(CREDENTIAL_PATH)) return null;
    try {
        return JSON.parse(fs.readFileSync(CREDENTIAL_PATH, 'utf-8'));
    } catch (e) {
        return null;
    }
}

function writeCredential(machineId, credential) {
    fs.writeFileSync(
        CREDENTIAL_PATH,
        JSON.stringify({ machine_id: machineId, credential }, null, 2),
        'utf-8'
    );
}

// POSTs JSON directly over HTTPS, bypassing any system/local proxy config.
function postJson(hubUrl, pathname, body, timeoutMs) {
    return new Promise((resolve, reject) => {
        const url = new URL(pathname, hubUrl);
        const payload = Buffer.from(JSON.stringify(body), 'utf-8');
        const transport = transportFor(url);

        const req = transport.request(
            {
                hostname: url.hostname,
                port: url.port || (url.protocol === 'http:' ? 80 : 443),
                path: url.pathname,
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Content-Length': payload.length,
                },
                timeout: timeoutMs || 15000,
                // Explicit belt-and-suspenders: never use a proxy agent for hub calls.
                agent: new transport.Agent({ keepAlive: false }),
            },
            (res) => {
                let data = '';
                res.on('data', (chunk) => (data += chunk));
                res.on('end', () => {
                    let parsed = null;
                    try { parsed = data ? JSON.parse(data) : null; } catch (e) { /* leave null */ }
                    if (res.statusCode >= 200 && res.statusCode < 300) {
                        resolve(parsed);
                    } else {
                        reject(new Error(`hub ${pathname} returned ${res.statusCode}: ${data}`));
                    }
                });
            }
        );

        req.on('timeout', () => req.destroy(new Error('hub request timed out')));
        req.on('error', reject);
        req.write(payload);
        req.end();
    });
}

// GETs raw text (used for the plain VERSION file on raw.githubusercontent.com),
// same proxy-bypass guarantee as postJson.
function getText(urlString, timeoutMs) {
    return new Promise((resolve, reject) => {
        const url = new URL(urlString);
        const transport = transportFor(url);
        const req = transport.request(
            {
                hostname: url.hostname,
                port: url.port || (url.protocol === 'http:' ? 80 : 443),
                path: url.pathname + url.search,
                method: 'GET',
                timeout: timeoutMs || 15000,
                agent: new transport.Agent({ keepAlive: false }),
            },
            (res) => {
                if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
                    getText(res.headers.location, timeoutMs).then(resolve, reject);
                    return;
                }
                let data = '';
                res.on('data', (chunk) => (data += chunk));
                res.on('end', () => {
                    if (res.statusCode >= 200 && res.statusCode < 300) resolve(data);
                    else reject(new Error(`GET ${urlString} returned ${res.statusCode}`));
                });
            }
        );
        req.on('timeout', () => req.destroy(new Error('request timed out')));
        req.on('error', reject);
        req.end();
    });
}

// Downloads a binary file (used for the update zip) to destPath, same
// proxy-bypass guarantee. `onEvent(name, detail)` is an optional diagnostic
// hook — self-update.js uses it to log each sub-step, since a prior crash
// investigation found the process dying silently somewhere in this call
// with no JS-level error at all (errorlevel -1, not the usual uncaught-
// exception code of 1 — consistent with something outside this promise's
// own reject path, e.g. an unhandled 'error' on the write stream, or the
// process being killed by something external like antivirus).
function downloadFile(urlString, destPath, timeoutMs, onEvent) {
    const emit = onEvent || (() => {});
    return new Promise((resolve, reject) => {
        const url = new URL(urlString);
        const transport = transportFor(url);
        emit('request-start', { url: urlString, destPath });

        const file = fs.createWriteStream(destPath);
        // Without this, an error on the write stream (disk full, EPERM,
        // antivirus lock on destPath, etc.) is an unhandled 'error' event —
        // Node throws it as an uncaught exception outside this promise's
        // reject path, which crashes the process before the caller's own
        // try/catch ever sees it. This is the single most likely cause of
        // the silent-crash bug: it would explain a dead process with no
        // JS error surfacing anywhere, exactly what was observed.
        file.on('error', (e) => {
            emit('file-stream-error', { message: e.message, code: e.code });
            reject(e);
        });

        const req = transport.request(
            {
                hostname: url.hostname,
                port: url.port || (url.protocol === 'http:' ? 80 : 443),
                path: url.pathname + url.search,
                method: 'GET',
                timeout: timeoutMs || 60000,
                agent: new transport.Agent({ keepAlive: false }),
            },
            (res) => {
                emit('response', { statusCode: res.statusCode, headers: res.headers });
                if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
                    file.close();
                    downloadFile(res.headers.location, destPath, timeoutMs, onEvent).then(resolve, reject);
                    return;
                }
                if (res.statusCode !== 200) {
                    reject(new Error(`download ${urlString} returned ${res.statusCode}`));
                    return;
                }

                let bytesReceived = 0;
                res.on('data', (chunk) => {
                    bytesReceived += chunk.length;
                });
                // A failure on the response stream itself (connection reset
                // mid-download, etc.) is separate from a write-stream error
                // and also needs its own handler for the same reason above.
                res.on('error', (e) => {
                    emit('response-stream-error', { message: e.message, code: e.code, bytesReceived });
                    reject(e);
                });

                res.pipe(file);
                file.on('finish', () => {
                    emit('finish', { bytesReceived });
                    file.close(() => resolve());
                });
            }
        );
        req.on('timeout', () => {
            emit('timeout', {});
            req.destroy(new Error('download timed out'));
        });
        req.on('error', (e) => {
            emit('request-error', { message: e.message, code: e.code });
            reject(e);
        });
        req.end();
    });
}

module.exports = {
    BRAIN_DIR,
    readHubConfig,
    readCredential,
    writeCredential,
    postJson,
    getText,
    downloadFile,
};
