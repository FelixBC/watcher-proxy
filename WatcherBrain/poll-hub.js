// Runs every ~2 minutes via a scheduled task. Reports this machine's real
// state to the hub and applies whatever the hub says should be true
// (whitelist version, unplug/resume, available agent version).
//
// This script NEVER itself decides to take away internet or filtering — it
// only writes/clears small state files (whitelist.txt's managed block, the
// unplugged.flag). WatchdogLoop.ps1, which already owns "is the proxy
// healthy" every 5 seconds, is what actually acts on those files. That
// keeps exactly one piece of code responsible for the fail-open guarantee.
//
// If this whole script fails (hub unreachable, network down, anything) it
// exits non-zero and changes nothing locally — the machine keeps enforcing
// whatever whitelist/unplug state it already had. See plan 0001 AC6.
'use strict';

const fs = require('fs');
const path = require('path');
const net = require('net');
const { execSync } = require('child_process');

const { BRAIN_DIR, readHubConfig, readCredential, postJson, getText } = require('./hub-client');
const { registerIfNeeded } = require('./register-with-hub');
const { applyPushedWhitelist, getReportableExtras } = require('./whitelist-merge');

const WHITELIST_PATH = path.join(BRAIN_DIR, '..', 'whitelist.txt');
const VERSION_PATH = path.join(BRAIN_DIR, '..', 'VERSION');
const WHITELIST_VERSION_PATH = path.join(BRAIN_DIR, 'whitelist-version.txt');
const UNPLUGGED_FLAG_PATH = path.join(BRAIN_DIR, 'unplugged.flag');
const BLOCKED_LOG_PATH = path.join(BRAIN_DIR, 'blocked-requests.log');
const LOG_CURSOR_PATH = path.join(BRAIN_DIR, 'poll-log-cursor.txt');

function checkTcpOpen(host, port, timeoutMs) {
    return new Promise((resolve) => {
        const socket = new net.Socket();
        let done = false;
        const finish = (result) => {
            if (done) return;
            done = true;
            socket.destroy();
            resolve(result);
        };
        socket.setTimeout(timeoutMs);
        socket.once('connect', () => finish(true));
        socket.once('timeout', () => finish(false));
        socket.once('error', () => finish(false));
        socket.connect(port, host);
    });
}

async function checkInternetReachable() {
    // Deliberately independent of the hub and of the local proxy: a raw
    // HTTPS GET via Node's https module (see hub-client.js) never goes
    // through 127.0.0.1:8080, so this measures the PC's actual internet,
    // not "can it reach the filter."
    try {
        await getText('https://raw.githubusercontent.com/', 6000);
        return true;
    } catch (e) {
        return false;
    }
}

function readLocalWhitelistVersion() {
    if (!fs.existsSync(WHITELIST_VERSION_PATH)) return null;
    const raw = fs.readFileSync(WHITELIST_VERSION_PATH, 'utf-8').trim();
    const n = parseInt(raw, 10);
    return Number.isFinite(n) ? n : null;
}

function readLocalAgentVersion() {
    return fs.existsSync(VERSION_PATH) ? fs.readFileSync(VERSION_PATH, 'utf-8').trim() : '0.0.0';
}

function isLocallyUnplugged() {
    return fs.existsSync(UNPLUGGED_FLAG_PATH);
}

// Only NEW blocked lines since the last successful poll, so we never resend
// the whole log. Cursor is a byte offset into blocked-requests.log.
function readNewBlockedLogLines() {
    if (!fs.existsSync(BLOCKED_LOG_PATH)) return [];
    const stat = fs.statSync(BLOCKED_LOG_PATH);
    let cursor = 0;
    if (fs.existsSync(LOG_CURSOR_PATH)) {
        cursor = parseInt(fs.readFileSync(LOG_CURSOR_PATH, 'utf-8').trim(), 10) || 0;
    }
    // Log was rotated/cleared (e.g. the existing weekly clear) since our last read.
    if (cursor > stat.size) cursor = 0;

    const fd = fs.openSync(BLOCKED_LOG_PATH, 'r');
    const length = stat.size - cursor;
    let text = '';
    if (length > 0) {
        const buf = Buffer.alloc(length);
        fs.readSync(fd, buf, 0, length, cursor);
        text = buf.toString('utf-8');
    }
    fs.closeSync(fd);
    fs.writeFileSync(LOG_CURSOR_PATH, String(stat.size), 'utf-8');

    const lineRe = /^\[(.+?)\] BLOCKED: (\S+)/;
    return text
        .split(/\r?\n/)
        .map((line) => {
            const m = line.match(lineRe);
            if (!m) return null;
            return { occurred_at: m[1], blocked_url: m[2] };
        })
        .filter(Boolean);
}

function setUnpluggedFlag(resumeAtIso) {
    fs.writeFileSync(UNPLUGGED_FLAG_PATH, resumeAtIso || '', 'utf-8');
}

function clearUnpluggedFlag() {
    if (fs.existsSync(UNPLUGGED_FLAG_PATH)) fs.unlinkSync(UNPLUGGED_FLAG_PATH);
}

function triggerSelfUpdate() {
    const { spawn } = require('child_process');
    const child = spawn(
        process.execPath,
        [path.join(BRAIN_DIR, 'self-update.js')],
        { detached: true, stdio: 'ignore', cwd: BRAIN_DIR }
    );
    child.unref();
}

async function main() {
    const credentialFile = readCredential();
    const cred = credentialFile || (await registerIfNeeded());
    const config = readHubConfig();

    const [internetReachable, proxyRunning] = await Promise.all([
        checkInternetReachable(),
        checkTcpOpen('127.0.0.1', 8080, 2000),
    ]);
    const unplugged = isLocallyUnplugged();
    // Filter is only meaningfully "active" if the proxy is up AND we're not
    // intentionally unplugged (matches WatchdogLoop.ps1's own logic).
    const filterActive = proxyRunning && !unplugged;

    const body = {
        machine_id: cred.machine_id,
        credential: cred.credential,
        internet_reachable: internetReachable,
        proxy_running: proxyRunning,
        filter_active: filterActive,
        whitelist_version: readLocalWhitelistVersion(),
        extras: getReportableExtras(WHITELIST_PATH),
        logs: readNewBlockedLogLines(),
    };

    const response = await postJson(config.HubUrl, '/api/agent/poll', body);

    if (typeof response.whitelist_version === 'number' && response.whitelist_version !== body.whitelist_version) {
        applyPushedWhitelist(WHITELIST_PATH, response.whitelist_entries || []);
        fs.writeFileSync(WHITELIST_VERSION_PATH, String(response.whitelist_version), 'utf-8');
    }

    if (response.unplugged) {
        setUnpluggedFlag(response.unplug_resume_at || '');
    } else if (unplugged) {
        // Hub says we should be resumed and we're currently unplugged locally.
        clearUnpluggedFlag();
    }

    const localAgentVersion = readLocalAgentVersion();
    if (response.agent_version && response.agent_version !== localAgentVersion) {
        triggerSelfUpdate();
    }
}

main().catch((err) => {
    // Anything above failing (hub down, network down, bad response) simply
    // means "no update this cycle" — never touch local state on failure.
    console.error('poll-hub failed (no local changes made):', err.message);
    process.exit(1);
});
