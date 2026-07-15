// Tiny local event log: a breadcrumb trail of "what happened" on this PC, so a
// misbehaving machine can be diagnosed later WITHOUT going in person — and so
// that reading it is enough to tell whether the WATCHER is failing or the
// MACHINE/ISP is. Records only key lifecycle + state-change events (proxy
// up/down, watchdog fail-open, internet lost/back, crashes, updates) — never
// traffic — so it stays a few lines a day. Bounded two ways so it can NEVER
// fill the disk: by time (drop entries older than RETAIN_DAYS) and by a hard
// byte ceiling as a backstop. Nothing is uploaded unless the dashboard asks
// (see poll-hub.js diag-pending handling). The PowerShell watchdog appends to
// the SAME file in the same format; pruning here trims those lines too.
'use strict';

const fs = require('fs');
const path = require('path');

const EVENTS_PATH = path.join(__dirname, 'events.log');
const RETAIN_DAYS = 15;
const RETAIN_MS = RETAIN_DAYS * 24 * 60 * 60 * 1000;
const MAX_BYTES = 128 * 1024; // hard ceiling backstop (~128 KB)
const KEEP_LINES = 600; // trim back to this if the byte ceiling is hit

// Each line starts with "[ISO-8601] ". Returns the timestamp ms, or null.
function lineTime(line) {
    const m = line.match(/^\[([^\]]+)\]/);
    if (!m) return null;
    const t = Date.parse(m[1]);
    return Number.isNaN(t) ? null : t;
}

// Drop entries older than RETAIN_DAYS. Time-based, so it's reboot-proof (no
// timer to reset) — a machine that reboots daily prunes on each startup.
function pruneByTime(nowMs) {
    try {
        if (!fs.existsSync(EVENTS_PATH)) return;
        const now = nowMs || Date.now();
        const cutoff = now - RETAIN_MS;
        const lines = fs.readFileSync(EVENTS_PATH, 'utf-8').split('\n').filter(Boolean);
        // Keep lines newer than the cutoff; keep undated lines (safety).
        const kept = lines.filter((l) => {
            const t = lineTime(l);
            return t === null || t >= cutoff;
        });
        if (kept.length !== lines.length) {
            fs.writeFileSync(EVENTS_PATH, kept.join('\n') + '\n', 'utf-8');
        }
    } catch (e) {
        /* best effort */
    }
}

function appendEvent(tag, detail) {
    try {
        const line = `[${new Date().toISOString()}] ${tag}${detail ? ' | ' + detail : ''}\n`;
        fs.appendFileSync(EVENTS_PATH, line, 'utf-8');
        const st = fs.statSync(EVENTS_PATH);
        if (st.size > MAX_BYTES) {
            pruneByTime();
            const after = fs.readFileSync(EVENTS_PATH, 'utf-8').split('\n').filter(Boolean);
            if (after.length > KEEP_LINES) {
                fs.writeFileSync(EVENTS_PATH, after.slice(-KEEP_LINES).join('\n') + '\n', 'utf-8');
            }
        }
    } catch (e) {
        /* best effort — diagnostics must never break the agent */
    }
}

function readTail(n) {
    try {
        if (!fs.existsSync(EVENTS_PATH)) return '';
        const lines = fs.readFileSync(EVENTS_PATH, 'utf-8').split('\n').filter(Boolean);
        return lines.slice(-n).join('\n');
    } catch (e) {
        return '';
    }
}

// The whole trail, capped by bytes from the end, for on-demand auditing.
function readAll(maxBytes) {
    try {
        if (!fs.existsSync(EVENTS_PATH)) return '';
        const text = fs.readFileSync(EVENTS_PATH, 'utf-8');
        const cap = maxBytes || 60000;
        return text.length > cap ? text.slice(-cap) : text;
    } catch (e) {
        return '';
    }
}

module.exports = { appendEvent, readTail, readAll, pruneByTime, EVENTS_PATH };
