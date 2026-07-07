// Minimal port check: exit 0 if 127.0.0.1:8080 is open, else 1. No deps, fast cold start vs PowerShell.
const net = require('net');
const port = parseInt(process.env.PROXY_PORT || '8080', 10);
const timeout = 2000;
const s = net.createConnection(port, '127.0.0.1', () => { s.destroy(); process.exit(0); });
s.setTimeout(timeout, () => { s.destroy(); process.exit(1); });
s.on('error', () => { process.exit(1); });
