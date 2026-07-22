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
const { applyPushedWhitelist, getReportableExtras } = require('./whitelist-merge');
const { appendEvent, readAll, pruneByTime } = require('./event-log');

const WHITELIST_PATH = path.join(BRAIN_DIR, '..', 'whitelist.txt');
const VERSION_PATH = path.join(BRAIN_DIR, '..', 'VERSION');
const WHITELIST_VERSION_PATH = path.join(BRAIN_DIR, 'whitelist-version.txt');
const UNPLUGGED_FLAG_PATH = path.join(BRAIN_DIR, 'unplugged.flag');
const BLOCKED_LOG_PATH = path.join(BRAIN_DIR, 'blocked-requests.log');
const LOG_CURSOR_PATH = path.join(BRAIN_DIR, 'poll-log-cursor.txt');
const VISITS_PATH = path.join(BRAIN_DIR, 'recent-visits.json');
const FIRST_VISIT_PATH = path.join(BRAIN_DIR, 'first-visit.json');
const NET_STATE_PATH = path.join(BRAIN_DIR, 'net-state.txt');
// Set when the hub asks for diagnostics; the NEXT poll uploads the event-log
// tail and clears it. Two-cycle handshake keeps it dead simple and pull-only.
const DIAG_PENDING_PATH = path.join(BRAIN_DIR, 'diag-pending.flag');
const LOCATION_PATH = path.join(BRAIN_DIR, 'location.json');
const LOCATE_PENDING_PATH = path.join(BRAIN_DIR, 'locate-pending.flag');
const TAMPER_CURSOR_PATH = path.join(BRAIN_DIR, 'tamper-cursor.txt');
const GET_LOCATION_PS = path.join(BRAIN_DIR, 'GetLocation.ps1');
const EVENTS_LOG_PATH = path.join(BRAIN_DIR, 'events.log');
const LOCATION_MAX_AGE_MS = 55 * 60 * 1000; // sample ~hourly

// Spread hub hits across this window (anti-thundering-herd). Sized to the ~2-min
// poll cadence: 30s decorrelates machines that fired together without stretching
// the effective interval much, and stays well under the "stale" threshold.
const POLL_JITTER_MS = 30 * 1000;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

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
    // Deliberately independent of the hub and of the local proxy: raw HTTPS
    // GETs via Node's https module (see hub-client.js) never go through
    // 127.0.0.1:8080, so this measures the PC's actual internet, not "can it
    // reach the filter."
    //
    // Try several well-known hosts and count internet as UP if ANY responds.
    // A single reference host can be slow/blocked for a moment and would
    // otherwise flag a perfectly-online till as "sin internet" on the
    // dashboard. Requiring only one success makes the signal far less jumpy.
    const hosts = [
        'https://www.google.com/generate_204',
        'https://raw.githubusercontent.com/',
        'https://www.cloudflare.com/',
        'https://www.microsoft.com/',
    ];
    const attempts = hosts.map((url) =>
        getText(url, 6000).then(
            () => true,
            () => false
        )
    );
    const results = await Promise.all(attempts);
    return results.some((ok) => ok);
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

// Last few allowed hosts the proxy recorded (bounded to 3 on the writer side).
function readRecentVisits() {
    try {
        if (!fs.existsSync(VISITS_PATH)) return [];
        const parsed = JSON.parse(fs.readFileSync(VISITS_PATH, 'utf-8'));
        if (!Array.isArray(parsed)) return [];
        return parsed
            .filter((v) => v && typeof v.host === 'string' && typeof v.at === 'string')
            .slice(0, 3);
    } catch (e) {
        return [];
    }
}

// Record only CHANGES in the machine's internet reachability, and interpret
// them for later auditing: internet gone while the proxy is UP means the
// machine/ISP lost connectivity — NOT the Watcher. This is the line that lets
// a reader tell the two apart.
function logInternetTransition(reachable, proxyRunning) {
    try {
        const prev = fs.existsSync(NET_STATE_PATH) ? fs.readFileSync(NET_STATE_PATH, 'utf-8').trim() : '';
        const now = reachable ? 'up' : 'down';
        if (prev !== now) {
            fs.writeFileSync(NET_STATE_PATH, now, 'utf-8');
            if (!reachable) {
                appendEvent('internet-lost', proxyRunning
                    ? 'proxy OK, sin salida a internet — ISP/maquina, no el Watcher'
                    : 'sin internet y proxy abajo');
            } else if (prev) {
                appendEvent('internet-back', 'salida a internet restablecida');
            }
        }
    } catch (e) { /* best effort */ }
}

// Refresh location.json by running GetLocation.ps1, but only when it's stale
// (~hourly) or forced (a "locate now" request). Synchronous + time-boxed; any
// failure is swallowed so a poll never hangs or breaks on location.
function refreshLocationIfDue(force) {
    try {
        let due = force;
        if (!due) {
            const stat = fs.existsSync(LOCATION_PATH) ? fs.statSync(LOCATION_PATH) : null;
            due = !stat || (Date.now() - stat.mtimeMs > LOCATION_MAX_AGE_MS);
        }
        if (!due) return;
        const out = require('child_process').execFileSync(
            'powershell',
            ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', GET_LOCATION_PS],
            { timeout: 15000, encoding: 'utf-8' }
        );
        const parsed = JSON.parse(out.trim());
        if (parsed && typeof parsed.lat === 'number' && typeof parsed.lng === 'number') {
            fs.writeFileSync(
                LOCATION_PATH,
                JSON.stringify({ lat: parsed.lat, lng: parsed.lng, acc: parsed.acc ?? null, at: new Date().toISOString() }),
                'utf-8'
            );
        }
    } catch (e) {
        /* no fix this cycle — leave the last one (if any) in place */
    }
}

function readLocation() {
    try {
        if (!fs.existsSync(LOCATION_PATH)) return null;
        const v = JSON.parse(fs.readFileSync(LOCATION_PATH, 'utf-8'));
        if (v && typeof v.lat === 'number' && typeof v.lng === 'number') return v;
        return null;
    } catch (e) {
        return null;
    }
}

// Tamper events are lines in events.log tagged `tamper` (written by
// BackToNormal / watchdog before the agent might be killed). Return the ones
// newer than the cursor timestamp; the caller advances the cursor only AFTER a
// successful upload so nothing is lost if the poll fails.
function readNewTamperEvents() {
    try {
        if (!fs.existsSync(EVENTS_LOG_PATH)) return { events: [], maxTs: null };
        const sinceIso = fs.existsSync(TAMPER_CURSOR_PATH)
            ? fs.readFileSync(TAMPER_CURSOR_PATH, 'utf-8').trim()
            : '';
        const since = sinceIso ? Date.parse(sinceIso) : 0;
        const lines = fs.readFileSync(EVENTS_LOG_PATH, 'utf-8').split(/\r?\n/);
        const re = /^\[([^\]]+)\]\s*tamper\s*(?:\|\s*(.*))?$/i;
        const events = [];
        let maxTs = sinceIso || null;
        for (const line of lines) {
            const m = line.match(re);
            if (!m) continue;
            const ts = Date.parse(m[1]);
            if (Number.isNaN(ts) || (since && ts <= since)) continue;
            events.push({ at: new Date(ts).toISOString(), kind: 'tamper', detail: (m[2] || '').trim() });
            if (!maxTs || ts > Date.parse(maxTs)) maxTs = new Date(ts).toISOString();
        }
        return { events: events.slice(-20), maxTs };
    } catch (e) {
        return { events: [], maxTs: null };
    }
}

// The first allowed page of the day (written by the proxy). Sent as {host, at}.
function readFirstVisit() {
    try {
        if (!fs.existsSync(FIRST_VISIT_PATH)) return null;
        const v = JSON.parse(fs.readFileSync(FIRST_VISIT_PATH, 'utf-8'));
        if (v && typeof v.host === 'string' && typeof v.at === 'string') {
            return { host: v.host, at: v.at };
        }
        return null;
    } catch (e) {
        return null;
    }
}

function setUnpluggedFlag(resumeAtIso) {
    fs.writeFileSync(UNPLUGGED_FLAG_PATH, resumeAtIso || '', 'utf-8');
}

function clearUnpluggedFlag() {
    if (fs.existsSync(UNPLUGGED_FLAG_PATH)) fs.unlinkSync(UNPLUGGED_FLAG_PATH);
}

function triggerSelfUpdate(version, url, sha256) {
    const { spawn } = require('child_process');
    const child = spawn(
        process.execPath,
        [path.join(BRAIN_DIR, 'self-update.js'), version, url, sha256 || ''],
        { detached: true, stdio: 'ignore', cwd: BRAIN_DIR }
    );
    child.unref();
}

async function main() {
    const cred = readCredential();
    // Not enrolled (no credential on disk). We deliberately do NOT try to
    // re-register here: enrollment needs the plaintext master code, which is
    // captured ONCE at install and never persisted (only its scrypt hash is
    // kept, for uninstall). With no code to send, a re-register is impossible,
    // so the safe thing is to do NOTHING — make no local changes, never touch
    // the proxy/registry/whitelist. The machine keeps enforcing whatever state
    // it already had; the golden rule is untouched.
    if (!cred) {
        console.log('poll-hub: not enrolled (no credential); nothing to do.');
        return;
    }
    const config = readHubConfig();

    // Jitter: wait a random slice of a window BEFORE doing anything with the
    // hub, so machines whose 5-min timers accidentally lined up (a whole shop
    // powering on at 8am, everyone rebooting after an outage) don't all hit the
    // hub in the same second. Re-randomized every poll, so any accidental
    // alignment scatters on its own. Well under the "stale" threshold, so it
    // never risks a machine looking offline. State is read AFTER the wait, so
    // the report is fresh at send time.
    await sleep(Math.floor(Math.random() * POLL_JITTER_MS));

    const [internetReachable, proxyRunning] = await Promise.all([
        checkInternetReachable(),
        checkTcpOpen('127.0.0.1', 8080, 2000),
    ]);
    const unplugged = isLocallyUnplugged();
    // Filter is only meaningfully "active" if the proxy is up AND we're not
    // intentionally unplugged (matches WatchdogLoop.ps1's own logic).
    const filterActive = proxyRunning && !unplugged;

    // Audit breadcrumbs (local): internet reachability changes + time-based
    // pruning of the shared events.log so it never grows past its window.
    logInternetTransition(internetReachable, proxyRunning);
    pruneByTime();

    const body = {
        machine_id: cred.machine_id,
        credential: cred.credential,
        internet_reachable: internetReachable,
        proxy_running: proxyRunning,
        filter_active: filterActive,
        whitelist_version: readLocalWhitelistVersion(),
        extras: getReportableExtras(WHITELIST_PATH),
        logs: readNewBlockedLogLines(),
        recent_visits: readRecentVisits(),
    };
    const firstVisit = readFirstVisit();
    if (firstVisit) body.first_visit = firstVisit;

    // Location: refresh ~hourly (or now, if the hub asked via locate_requested
    // last cycle), then attach the latest fix if we have one.
    const locateForced = fs.existsSync(LOCATE_PENDING_PATH);
    refreshLocationIfDue(locateForced);
    if (locateForced) { try { fs.unlinkSync(LOCATE_PENDING_PATH); } catch (e) {} }
    const location = readLocation();
    if (location) body.location = location;

    // Tamper events (uninstall attempt, etc.) since the last upload.
    const tamper = readNewTamperEvents();
    if (tamper.events.length > 0) body.tamper_events = tamper.events;

    // If the hub asked for diagnostics last time, attach the event-log tail now.
    const diagPending = fs.existsSync(DIAG_PENDING_PATH);
    if (diagPending) {
        // Send the whole recent trail (bounded) so an auditor sees the full
        // picture, not just the last few lines.
        body.diagnostics = readAll(60000) || '(sin eventos registrados)';
    }

    const response = await postJson(config.HubUrl, '/api/agent/poll', body);

    // Diagnostics handshake: clear the flag once uploaded; set it when asked.
    if (diagPending) {
        try { fs.unlinkSync(DIAG_PENDING_PATH); } catch (e) {}
    }
    if (response.diag_requested) {
        try { fs.writeFileSync(DIAG_PENDING_PATH, '', 'utf-8'); } catch (e) {}
    }

    // Locate handshake: hub asks → force a fresh fix on the next poll.
    if (response.locate_requested) {
        try { fs.writeFileSync(LOCATE_PENDING_PATH, '', 'utf-8'); } catch (e) {}
    }
    // Tamper cursor advances ONLY after a successful post, so a failed poll
    // re-sends the events next time instead of dropping them.
    if (tamper.events.length > 0 && tamper.maxTs) {
        try { fs.writeFileSync(TAMPER_CURSOR_PATH, tamper.maxTs, 'utf-8'); } catch (e) {}
    }

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
    if (
        response.agent_version &&
        response.agent_version !== localAgentVersion &&
        response.agent_download_url
    ) {
        triggerSelfUpdate(response.agent_version, response.agent_download_url, response.agent_sha256);
    }
}

main().catch((err) => {
    // Anything above failing (hub down, network down, bad response) simply
    // means "no update this cycle" — never touch local state on failure.
    // Record it (bounded) so "the machine went quiet" is diagnosable later.
    try { appendEvent('hub-unreachable', err && err.message); } catch (e) {}
    console.error('poll-hub failed (no local changes made):', err.message);
    process.exit(1);
});
