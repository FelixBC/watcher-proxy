// Minimal port check: exit 0 if the proxy's local port is open, else 1. No deps,
// fast cold start vs PowerShell. The port is the obscure one chosen at install
// (proxy-port.txt), NOT 8080 — see proxy-port.js.
const net = require('net');
const { readChosenPort } = require('./proxy-port');
const port = readChosenPort();
const timeout = 2000;
const s = net.createConnection(port, '127.0.0.1', () => { s.destroy(); process.exit(0); });
s.setTimeout(timeout, () => { s.destroy(); process.exit(1); });
s.on('error', () => { process.exit(1); });
