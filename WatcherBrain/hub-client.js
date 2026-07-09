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

const BRAIN_DIR = __dirname;
const HUB_CONFIG_PATH = path.join(BRAIN_DIR, 'HubConfig.json');
const CREDENTIAL_PATH = path.join(BRAIN_DIR, 'hub-credential.json');

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

        const req = https.request(
            {
                hostname: url.hostname,
                port: url.port || 443,
                path: url.pathname,
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Content-Length': payload.length,
                },
                timeout: timeoutMs || 15000,
                // Explicit belt-and-suspenders: never use a proxy agent for hub calls.
                agent: new https.Agent({ keepAlive: false }),
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
        const req = https.request(
            {
                hostname: url.hostname,
                port: 443,
                path: url.pathname + url.search,
                method: 'GET',
                timeout: timeoutMs || 15000,
                agent: new https.Agent({ keepAlive: false }),
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
// proxy-bypass guarantee.
function downloadFile(urlString, destPath, timeoutMs) {
    return new Promise((resolve, reject) => {
        const url = new URL(urlString);
        const file = fs.createWriteStream(destPath);
        const req = https.request(
            {
                hostname: url.hostname,
                port: 443,
                path: url.pathname + url.search,
                method: 'GET',
                timeout: timeoutMs || 60000,
                agent: new https.Agent({ keepAlive: false }),
            },
            (res) => {
                if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
                    file.close();
                    downloadFile(res.headers.location, destPath, timeoutMs).then(resolve, reject);
                    return;
                }
                if (res.statusCode !== 200) {
                    reject(new Error(`download ${urlString} returned ${res.statusCode}`));
                    return;
                }
                res.pipe(file);
                file.on('finish', () => file.close(() => resolve()));
            }
        );
        req.on('timeout', () => req.destroy(new Error('download timed out')));
        req.on('error', reject);
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
