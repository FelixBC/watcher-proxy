// Single source of truth for which LOCAL port the proxy listens on.
//
// We deliberately AVOID 8080 — it's the default many other programs grab, and on
// a PC that already runs one, our proxy and theirs would fight for the port (the
// loser can't serve, and Windows could end up pointed at a non-proxy = internet
// broken). Instead we use an OBSCURE port from the IANA dynamic/private range
// (49152-65535), which is almost never taken, so the port is essentially always
// ours.
//
// The port is chosen ONCE at install time (`node proxy-port.js select`): the first
// FREE candidate is written to proxy-port.txt. From then on every piece reads that
// file — the proxy binds it, the watchdogs/CheckPort probe it, and Windows is
// pointed at 127.0.0.1:<that port>. Choosing at install (before any proxy starts)
// avoids the logon "thundering herd" race: all the launchers read the same fixed
// port, exactly one binds it, and the rest hit EADDRINUSE and exit cleanly (the
// single-instance guarantee in proxy-server.js). The fallback list only matters on
// the rare machine where the primary is already occupied at install.
'use strict';
const fs = require('fs');
const net = require('net');
const path = require('path');

// Obscure ports in the dynamic/private range — never assigned to real services.
// First is the primary; the rest are fallbacks tried (only) at install time.
const PORT_CANDIDATES = [49732, 53187, 61045];
const PRIMARY_PORT = PORT_CANDIDATES[0];
const PORT_FILE = path.join(__dirname, 'proxy-port.txt');

function readChosenPort() {
    try {
        const p = parseInt(fs.readFileSync(PORT_FILE, 'utf-8').trim(), 10);
        if (Number.isInteger(p) && p > 0 && p < 65536) return p;
    } catch (_) { /* fall through to the primary */ }
    return PRIMARY_PORT;
}

function writeChosenPort(port) {
    // Hidden+System-safe (see the disguise note in CLAUDE.md and self-update.js's
    // writeFileInPlace): the install marks proxy-port.txt +h +s (InstallWatcher.bat),
    // and a plain writeFileSync (CREATE_ALWAYS) EPERMs against those attributes — which
    // silently no-op'd every rewrite. Overwrite IN PLACE (r+ + truncate) when the file
    // already exists so the attributes are preserved and the write actually lands.
    try {
        const data = String(port);
        if (!fs.existsSync(PORT_FILE)) {
            fs.writeFileSync(PORT_FILE, data, 'utf-8');
            return;
        }
        const buf = Buffer.from(data, 'utf-8');
        const fd = fs.openSync(PORT_FILE, 'r+');
        try {
            // Write-then-truncate (never leave the file momentarily empty) — see the
            // durability note in whitelist-merge.js's writeInPlace.
            fs.writeSync(fd, buf, 0, buf.length, 0);
            fs.ftruncateSync(fd, buf.length);
        } finally {
            fs.closeSync(fd);
        }
    } catch (_) { /* best effort */ }
}

// Can we bind this port on 127.0.0.1 right now? (Brief listen + close.)
function isFree(port) {
    return new Promise((resolve) => {
        const srv = net.createServer();
        srv.once('error', () => resolve(false));
        srv.once('listening', () => srv.close(() => resolve(true)));
        try { srv.listen(port, '127.0.0.1'); } catch (_) { resolve(false); }
    });
}

// First free candidate, or the primary if somehow all are taken (proxy-server will
// then EADDRINUSE→exit 0, and the watchdog fail-open keeps internet normal).
async function selectFreePort() {
    for (const p of PORT_CANDIDATES) {
        if (await isFree(p)) return p;
    }
    return PRIMARY_PORT;
}

// The SECOND port used only during a plan-0007 blue-green OTA cutover: the new
// version listens here (port B) while the OLD version keeps filtering on the
// persisted home port (A), so there's no gap where nothing is listening. Drawn
// from the SAME fixed candidate pool as normal selection — never a random search,
// so it stays inside the obscure/dynamic range reasoned about above. Returns null
// (NOT a fallback port) when nothing in the pool qualifies; the caller
// (self-update.js) reads null as "no scaffold free" and degrades to the
// same-port cutover path instead of forcing a port that isn't actually free.
async function selectScaffoldPort(homePort) {
    for (const p of PORT_CANDIDATES) {
        if (p === homePort) continue;
        if (await isFree(p)) return p;
    }
    return null;
}

// CLI: `node proxy-port.js select` → choose a free port, write it, print it.
if (require.main === module && process.argv[2] === 'select') {
    selectFreePort().then((p) => {
        writeChosenPort(p);
        process.stdout.write(String(p));
        process.exit(0);
    }).catch(() => { writeChosenPort(PRIMARY_PORT); process.exit(0); });
}

module.exports = { PORT_CANDIDATES, PRIMARY_PORT, PORT_FILE, readChosenPort, writeChosenPort, isFree, selectFreePort, selectScaffoldPort };
