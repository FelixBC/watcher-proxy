// Tiny local event log: a breadcrumb trail of "what happened" on this PC, so a
// misbehaving machine can be diagnosed later WITHOUT going in person. Records
// only key lifecycle events (proxy up/down, watchdog fail-open, updates, hub
// errors) — not traffic — so it stays a few lines a day. Capped + self-pruned,
// so it can never fill the disk. Nothing is uploaded unless the dashboard asks
// (see poll-hub.js diag-pending handling).
'use strict';

const fs = require('fs');
const path = require('path');

const EVENTS_PATH = path.join(__dirname, 'events.log');
const MAX_BYTES = 64 * 1024; // ~64 KB ceiling
const KEEP_LINES = 400; // trim back to this on overflow

function appendEvent(tag, detail) {
    try {
        const line = `[${new Date().toISOString()}] ${tag}${detail ? ' | ' + detail : ''}\n`;
        fs.appendFileSync(EVENTS_PATH, line, 'utf-8');
        const st = fs.statSync(EVENTS_PATH);
        if (st.size > MAX_BYTES) {
            const lines = fs.readFileSync(EVENTS_PATH, 'utf-8').split('\n').filter(Boolean);
            fs.writeFileSync(EVENTS_PATH, lines.slice(-KEEP_LINES).join('\n') + '\n', 'utf-8');
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

module.exports = { appendEvent, readTail, EVENTS_PATH };
