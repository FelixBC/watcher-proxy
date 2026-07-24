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
    try { fs.writeFileSync(PORT_FILE, String(port), 'utf-8'); } catch (_) { /* best effort */ }
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

// CLI: `node proxy-port.js select` → choose a free port, write it, print it.
if (require.main === module && process.argv[2] === 'select') {
    selectFreePort().then((p) => {
        writeChosenPort(p);
        process.stdout.write(String(p));
        process.exit(0);
    }).catch(() => { writeChosenPort(PRIMARY_PORT); process.exit(0); });
}

module.exports = { PORT_CANDIDATES, PRIMARY_PORT, PORT_FILE, readChosenPort, writeChosenPort, isFree, selectFreePort };
