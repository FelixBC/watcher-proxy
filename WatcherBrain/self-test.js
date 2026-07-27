// Plan 0003 (Capa 4 — staging QA gate): the acceptance self-test suite.
//
// ONLY a machine the hub marked `is_staging` runs this (poll-hub.js gates on
// staging.flag, set from the poll RESPONSE — cross-repo contract). The cutover
// check spawns a REAL second proxy instance, so this suite must NEVER run on a
// production banca. It runs ONCE per running version (cached in
// selftest-state.json) and the result travels in the poll body as
// `selftest: { persistencia|filtro|config|whitelist|cutover|recovery:
// "pass"|"fail"|"skip" }`.
//
// Design rules (spec forks, LOCKED):
//   - runSelfTest() NEVER throws: every check is individually wrapped and a
//     throw becomes "fail". maybeRunSelfTest() additionally never throws around
//     the cache/lock plumbing — a self-test problem must never crash the poll.
//   - Reversible-only (fork B2): the cutover check exercises the real plan-0007
//     scaffold machinery (selectScaffoldPort + proxy-server.js's
//     WATCHER_OVERRIDE_PORT / WATCHER_NO_PERSIST_PORT mode) by spawning a
//     SECOND proxy on a scratch port, verifying it serves AND filters, then
//     retiring it. It never touches the live registry, never rewrites
//     proxy-port.txt, and never stops the live home proxy — if the scratch
//     instance dies, live filtering is untouched.
//   - The IRREVERSIBLE surfaces (BackToNormal teardown / SOS uninstall,
//     RestoreInternetNow, SetProxyByAvailability) are only checked for
//     PRESENCE + SYNTAX — never executed (an agent that uninstalls itself
//     can't report; those are validated by hand outside the gate).
//
// NOTE on mirrors: proxy-server.js does not export its whitelist grammar or
// isWhitelisted (requiring it would START a proxy), and self-update.js exports
// only { main } while registering process-wide uncaughtException handlers that
// flip internet settings (requiring it from the poll process would change the
// poll's crash behavior). The functional filter test therefore goes through
// the RUNNING proxy over real CONNECT requests — the actual isWhitelisted
// path, end to end — and the two small mirrors below (whitelist grammar,
// scaffold spawn/kill) are copies of the canonical code, each labeled with its
// source of truth.
'use strict';

const fs = require('fs');
const path = require('path');
const net = require('net');
const { execFileSync, spawn } = require('child_process');

const { BRAIN_DIR, readCredential } = require('./hub-client');
const { readChosenPort, selectScaffoldPort, PORT_FILE } = require('./proxy-port');
const { parse: parseWhitelistRegions, getReportableExtras } = require('./whitelist-merge');
const { appendEvent } = require('./event-log');

const ROOT_DIR = path.join(BRAIN_DIR, '..');

// --- State files the persistence check asserts on (paths grounded in
// proxy-server.js CONFIG, poll-hub.js and proxy-port.js) ---
const WHITELIST_PATH = path.join(ROOT_DIR, 'whitelist.txt');
const RECENT_VISITS_PATH = path.join(BRAIN_DIR, 'recent-visits.json');
const FIRST_VISIT_PATH = path.join(BRAIN_DIR, 'first-visit.json');
const LASTGOOD_PATH = path.join(BRAIN_DIR, 'whitelist-lastgood.txt');
const WHITELIST_VERSION_PATH = path.join(BRAIN_DIR, 'whitelist-version.txt');
// hub-credential.json is read via hub-client.readCredential() — its CONTENTS are a
// secret and must never be logged/echoed; we only assert it parses and has its shape.

// --- Machine-mode flags (grounded in self-update.js / WatchdogLoop.ps1) ---
const UNPLUGGED_FLAG_PATH = path.join(BRAIN_DIR, 'unplugged.flag');
const UPDATING_FLAG_PATH = path.join(BRAIN_DIR, 'updating.flag');
const UPDATE_LOCK_PATH = path.join(BRAIN_DIR, 'update.lock');

// --- Recovery surfaces (presence + syntax ONLY — never executed) ---
const RESTORE_BAT_PATH = path.join(BRAIN_DIR, 'RestoreInternetNow.bat');
const SETPROXY_PS1_PATH = path.join(BRAIN_DIR, 'SetProxyByAvailability.ps1');
const BACKTONORMAL_BAT_PATH = path.join(ROOT_DIR, 'BackToNormal.bat'); // the SOS gate lives here
const EMERGENCY_HASH_PATH = path.join(BRAIN_DIR, 'emergency-code.hash');
const CODE_CRYPTO_PATH = path.join(BRAIN_DIR, 'agent-code-crypto.js');

// --- This suite's own runtime state (gitignored; runtime-created plain files,
// so normal writeFileSync is fine — same reasoning as update-failed.json) ---
const STATE_PATH = path.join(BRAIN_DIR, 'selftest-state.json');
const SUITE_LOCK_PATH = path.join(BRAIN_DIR, 'selftest.lock');

const CHECKS = ['persistencia', 'filtro', 'config', 'whitelist', 'cutover', 'recovery'];

// A host that can NEVER legitimately be whitelisted (.invalid is RFC-2606
// reserved). The proxy checks the whitelist BEFORE any DNS/socket work, so the
// blocked verdict is deterministic even with no internet. Self-documenting on
// the dashboard if the blocked line ever gets uploaded.
const BAD_HOST = 'selftest-bloqueo-esperado.invalid';

// Health cadence mirrors self-update.js (HEALTH_POLL_MS). The scratch proxy's
// cold start measured ~60-90s on real fleet HW (Defender re-scan — see plan
// 0006), so the ceiling is 180s: generous margin, but deliberately below
// self-update's 300s patient window and the suite lock's stale threshold.
const HEALTH_POLL_MS = 3000;
const SCRATCH_HEALTH_RETRIES = 60; // ~180s ceiling (early-returns when the port opens)
const PORT_CLOSE_RETRIES = 10;     // ~30s for the scratch proxy to release its port

// Stale thresholds mirror their owners: updating.flag ↔ the watchdogs'
// STALE_FLAG_MINUTES (15), update.lock ↔ self-update's LOCK_STALE_MS (20 min).
const UPDATING_FLAG_STALE_MS = 15 * 60 * 1000;
const UPDATE_LOCK_STALE_MS = 20 * 60 * 1000;
// Single-flight for the suite itself: poll instances fire every ~2 min and a
// suite can take ~5 min worst-case, so without this each poll would stack
// another run (two concurrent runs could even race selectScaffoldPort onto the
// same port). Stale > worst-case suite duration so a killed run self-heals.
const SUITE_LOCK_STALE_MS = 12 * 60 * 1000;
// A result containing "skip" is an ENVIRONMENT verdict (unplugged, target
// unreachable), not a verdict on the build — retry after this window instead
// of freezing the gate on it forever. "pass"/"fail" results stay cached for
// the whole version (the spec's run-once-per-version; a fail is a deliberate
// halt for a human, never auto-retried).
const SKIP_RETRY_MS = 30 * 60 * 1000;

const REG_KEY = 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings';

// ---------------------------------------------------------------------------
// Small shared helpers
// ---------------------------------------------------------------------------

// In-process TCP probe — same shape as poll-hub.js/self-update.js checkTcpOpen.
function checkTcpOpen(host, port, timeoutMs) {
    return new Promise((resolve) => {
        const sock = new net.Socket();
        let settled = false;
        const finish = (ok) => {
            if (settled) return;
            settled = true;
            try { sock.destroy(); } catch (_) {}
            resolve(ok);
        };
        sock.setTimeout(timeoutMs);
        sock.once('connect', () => finish(true));
        sock.once('timeout', () => finish(false));
        sock.once('error', () => finish(false));
        try { sock.connect(port, host); } catch (_) { finish(false); }
    });
}

async function waitForTcpOpen(port, retries, delayMs) {
    for (let i = 0; i < retries; i++) {
        if (await checkTcpOpen('127.0.0.1', port, 2000)) return true;
        await new Promise((r) => setTimeout(r, delayMs));
    }
    return false;
}

async function waitForTcpClosed(port, retries, delayMs) {
    for (let i = 0; i < retries; i++) {
        if (!(await checkTcpOpen('127.0.0.1', port, 2000))) return true;
        await new Promise((r) => setTimeout(r, delayMs));
    }
    return false;
}

// The port Windows currently points at, or null. MIRROR of self-update.js's
// getRegistryProxyPort (reg.exe, not PowerShell — same AMSI-avoidance reasoning).
function getRegistryProxyPort() {
    try {
        const out = execFileSync('reg.exe', ['query', REG_KEY, '/v', 'ProxyServer'], { encoding: 'utf-8' });
        const m = out.match(/127\.0\.0\.1:(\d+)/);
        if (m) return parseInt(m[1], 10);
    } catch (_) { /* unset / no proxy configured */ }
    return null;
}

function getRegistryProxyEnable() {
    try {
        const out = execFileSync('reg.exe', ['query', REG_KEY, '/v', 'ProxyEnable'], { encoding: 'utf-8' });
        const m = out.match(/ProxyEnable\s+REG_DWORD\s+0x([0-9a-fA-F]+)/i);
        if (m) return parseInt(m[1], 16);
    } catch (_) { /* missing value */ }
    return null;
}

// MIRROR of proxy-server.js's parseWhitelistContent (not exported there;
// requiring proxy-server.js would start a listener). Keep byte-for-byte in
// sync with that grammar — it defines what the proxy actually enforces.
function parseWhitelistContent(content) {
    const domains = new Set();
    const exactUrls = new Set();
    for (let line of content.split('\n')) {
        line = line.split('#')[0].trim();
        if (!line) continue;
        if (line.startsWith('http://') || line.startsWith('https://')) {
            exactUrls.add(line.toLowerCase());
        } else {
            domains.add(line.toLowerCase().replace(/^https?:\/\//, '').split('/')[0]);
        }
    }
    return { domains, exactUrls };
}

// MIRROR of the domain-match section of proxy-server.js's isWhitelisted — used
// only to PICK a known-good candidate host; the actual verdicts come from the
// running proxy itself (see connectVerdict).
function isHostInParsed(parsed, host) {
    const h = String(host).toLowerCase();
    for (const domain of parsed.domains) {
        if (h === domain || h.endsWith('.' + domain)) return true;
    }
    return false;
}

// Issue a real CONNECT through the proxy at 127.0.0.1:proxyPort and classify
// the outcome. This exercises the genuine isWhitelisted path end to end:
//   - blocked host  → the proxy answers "HTTP/1.1 404 Not Found" immediately
//     (whitelist check runs before any DNS), verdict "blocked";
//   - allowed host  → "HTTP/1.1 200 Connection Established" once the tunnel to
//     the target is up, verdict "allowed";
//   - allowed-but-unreachable target / dead network → the proxy just drops the
//     socket (tunnel error), verdict "no-response" — NOT a filter verdict;
//   - nothing listening on proxyPort → verdict "no-proxy".
function connectVerdict(proxyPort, host, timeoutMs) {
    return new Promise((resolve) => {
        const sock = new net.Socket();
        let buffer = '';
        let settled = false;
        const finish = (verdict) => {
            if (settled) return;
            settled = true;
            try { sock.destroy(); } catch (_) {}
            resolve(verdict);
        };
        sock.setTimeout(timeoutMs);
        sock.once('connect', () => {
            sock.write('CONNECT ' + host + ':443 HTTP/1.1\r\nHost: ' + host + ':443\r\n\r\n');
        });
        sock.on('data', (chunk) => {
            buffer += chunk.toString('utf-8');
            const m = buffer.match(/^HTTP\/1\.[01]\s+(\d{3})/);
            if (!m) return;
            if (m[1] === '200') finish('allowed');
            else if (m[1] === '404') finish('blocked');
            else finish('no-response');
        });
        sock.once('timeout', () => finish('no-response'));
        sock.once('end', () => finish('no-response'));
        sock.once('error', () => finish('no-proxy'));
        try { sock.connect(proxyPort, '127.0.0.1'); } catch (_) { finish('no-proxy'); }
    });
}

function isFlagFresh(flagPath, staleMs) {
    try {
        return (Date.now() - fs.statSync(flagPath).mtimeMs) < staleMs;
    } catch (_) {
        return false; // missing/unstattable → not active
    }
}

function isUnplugged() {
    return fs.existsSync(UNPLUGGED_FLAG_PATH);
}

// ---------------------------------------------------------------------------
// The six checks (spec AC4). Each returns "pass"|"fail"|"skip"; any throw is
// converted to "fail" by runCheck below.
// ---------------------------------------------------------------------------

// persistencia: the key per-machine state files EXIST and PARSE. A missing or
// corrupt file throws / short-circuits → "fail" (spec: archivo corrupto → fail).
function checkPersistencia() {
    // recent-visits.json — written by the running proxy; must be a JSON array.
    const visits = JSON.parse(fs.readFileSync(RECENT_VISITS_PATH, 'utf-8'));
    if (!Array.isArray(visits)) return 'fail';

    // first-visit.json — {day, host, at, ...}; must be a JSON object.
    const firstVisit = JSON.parse(fs.readFileSync(FIRST_VISIT_PATH, 'utf-8'));
    if (!firstVisit || typeof firstVisit !== 'object' || Array.isArray(firstVisit)) return 'fail';

    // hub-credential.json — via the REAL reader (null on missing/corrupt).
    // Never log its contents anywhere; shape-check only.
    const cred = readCredential();
    if (!cred || !cred.machine_id || !cred.credential) return 'fail';

    // whitelist-lastgood.txt — the plan-0008 cold-boot safety net. Must parse
    // to a USABLE whitelist (≥1 entry), same usability rule as proxy-server.js.
    const lastGood = parseWhitelistContent(fs.readFileSync(LASTGOOD_PATH, 'utf-8'));
    if (lastGood.domains.size === 0 && lastGood.exactUrls.size === 0) return 'fail';

    // proxy-port.txt — must hold a valid port. Checked RAW on purpose:
    // readChosenPort() silently falls back to the primary, which would mask a
    // corrupt file here.
    const rawPort = parseInt(fs.readFileSync(PORT_FILE, 'utf-8').trim(), 10);
    if (!Number.isInteger(rawPort) || rawPort <= 0 || rawPort >= 65536) return 'fail';

    // whitelist-version.txt — the hub-sync watermark; must parse to a number.
    const wlVersion = parseInt(fs.readFileSync(WHITELIST_VERSION_PATH, 'utf-8').trim(), 10);
    if (!Number.isFinite(wlVersion)) return 'fail';

    return 'pass';
}

// filtro (functional): through the LIVE proxy, a known-bad host must come back
// blocked (the proxy's own 404) and a known-good, actually-whitelisted host
// must tunnel (200). This tests OUTPUTS of the real isWhitelisted path — a
// proxy that is "up" but failing open (filterMode='failopen') fails here.
async function checkFiltro() {
    if (isUnplugged()) return 'skip'; // intentionally unfiltered — no verdict on the build

    const livePort = getRegistryProxyPort() || readChosenPort();

    // Known-bad: deterministic (no DNS involved), so any non-"blocked" outcome
    // is a real filter failure (fail-open, whitelist poisoned, or proxy down).
    const blockedVerdict = await connectVerdict(livePort, BAD_HOST, 5000);
    if (blockedVerdict !== 'blocked') return 'fail';

    // Known-good: pick candidates that ARE in the effective whitelist (prefer
    // globally-reliable hosts when whitelisted; else the first whitelist
    // domains, which sit in the hub-managed block at the top of the file).
    const raw = fs.existsSync(WHITELIST_PATH) ? fs.readFileSync(WHITELIST_PATH, 'utf-8') : '';
    const parsed = parseWhitelistContent(raw);
    const candidates = [];
    for (const h of ['www.google.com', 'google.com', 'www.microsoft.com', 'microsoft.com', 'www.cloudflare.com', 'cloudflare.com']) {
        if (isHostInParsed(parsed, h)) candidates.push(h);
    }
    for (const d of parsed.domains) {
        if (candidates.length >= 6) break;
        if (!candidates.includes(d) && d.includes('.')) candidates.push(d);
    }
    if (candidates.length === 0) return 'fail'; // no whitelisted domain at all → nothing can be allowed

    let sawUnreachable = false;
    for (const host of candidates) {
        const verdict = await connectVerdict(livePort, host, 10000);
        if (verdict === 'allowed') return 'pass';
        // A WHITELISTED host answered with the block page → over-blocking. Real fail.
        if (verdict === 'blocked') return 'fail';
        sawUnreachable = true; // target/internet down — not a filter verdict
    }
    // Every candidate was unreachable: we could not DISPROVE the filter, but we
    // could not prove the allow path either (likely the staging PC briefly lost
    // internet). "skip" → the gate holds and the suite retries (SKIP_RETRY_MS).
    return sawUnreachable ? 'skip' : 'fail';
}

// config: the obscure per-machine port is actually listening AND Windows'
// registry points at it (ProxyEnable=1, ProxyServer=127.0.0.1:<home port>).
// The suite never runs mid-cutover (maybeRunSelfTest defers on updating.flag),
// so in steady state registry port === proxy-port.txt port — even after a
// home-rebind-deferred adopt, which rewrites proxy-port.txt to match.
async function checkConfig() {
    if (isUnplugged()) return 'skip'; // unplug legitimately sets ProxyEnable=0

    const homePort = readChosenPort();
    const listening = await checkTcpOpen('127.0.0.1', homePort, 2000);
    if (!listening) return 'fail';

    if (getRegistryProxyEnable() !== 1) return 'fail';
    const regPort = getRegistryProxyPort();
    if (regPort === null || regPort !== homePort) return 'fail';

    return 'pass';
}

// whitelist (merge invariant): the effective list the proxy loads = the
// hub-managed shared block + this machine's local extras. Every entry from
// BOTH regions (parsed with the real whitelist-merge.js splitter) must be
// representable in the proxy grammar's parse of the whole file.
function checkWhitelistMerge() {
    if (!fs.existsSync(WHITELIST_PATH)) return 'fail';
    const content = fs.readFileSync(WHITELIST_PATH, 'utf-8');

    const regions = parseWhitelistRegions(content);        // real merge-side parse
    const effective = parseWhitelistContent(content);      // real proxy-side grammar
    const managed = regions.managedEntries.map((l) => l.split('#')[0].trim()).filter(Boolean);
    const extras = getReportableExtras(WHITELIST_PATH);    // the exact list the poll reports

    // The hub has pushed at least once (whitelist-version.txt exists) → the
    // managed markers must be present, or pushes are silently not landing.
    if (fs.existsSync(WHITELIST_VERSION_PATH) && content.indexOf('==WATCHER-FLEET-MANAGED-START==') === -1) {
        return 'fail';
    }

    // An entirely empty effective list means the proxy is running on the
    // fail-open floor — the merge produced nothing usable.
    if (managed.length + extras.length === 0) return 'fail';

    for (const entry of [...managed, ...extras]) {
        const e = entry.toLowerCase();
        if (e.startsWith('http://') || e.startsWith('https://')) {
            if (!effective.exactUrls.has(e)) return 'fail';
        } else {
            const domain = e.replace(/^https?:\/\//, '').split('/')[0];
            if (!effective.domains.has(domain)) return 'fail';
        }
    }
    return 'pass';
}

// MIRROR of self-update.js's spawnProxy({persist:false}) — the REAL plan-0007
// scaffold mode: proxy-server.js binds WATCHER_OVERRIDE_PORT instead of the
// persisted home port, and WATCHER_NO_PERSIST_PORT=1 guarantees it never
// rewrites proxy-port.txt. detached+unref so a kill failure can't wedge the
// poll process (the finally kill + self-update's own sweepScaffoldOrphans are
// the backstops for a stray instance).
function spawnScratchProxy(port) {
    const env = { ...process.env, WATCHER_OVERRIDE_PORT: String(port), WATCHER_NO_PERSIST_PORT: '1' };
    const child = spawn(process.execPath, ['proxy-server.js'], {
        cwd: BRAIN_DIR, env, detached: true, stdio: 'ignore'
    });
    child.on('error', () => {}); // waitForTcpOpen is the real signal (same as self-update)
    child.unref();
    return child;
}

// MIRROR of self-update.js's killListenerOnPort — scoped by BOTH the listening
// port AND the proxy-server.js command line, so it can never touch the live
// home proxy or a non-watcher process. Used only as the fallback when killing
// our own scratch child by PID didn't land.
function killWatcherListenerOnPort(port) {
    const ps =
        "$ErrorActionPreference='SilentlyContinue';" +
        'netstat -ano | ForEach-Object {' +
        ' $f = $_ -split \'\\s+\' | Where-Object { $_ };' +
        ' if ($f.Length -ge 5 -and $f[3] -eq \'LISTENING\' -and $f[1] -like \'*:' + port + '\') {' +
        ' $procId = $f[4];' +
        ' $p = Get-CimInstance Win32_Process -Filter (\'ProcessId=\' + $procId);' +
        ' if ($p -and $p.CommandLine -like \'*proxy-server.js*\') { Stop-Process -Id $procId -Force } } }';
    try {
        execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', ps], { stdio: 'ignore' });
    } catch (_) { /* best effort — a missing/already-dead listener is fine */ }
}

// cutover: "if another update comes, does this build know how to act?" —
// exercise the blue-green machinery REVERSIBLY. SAFETY JUDGMENT (flagged for
// review): rather than swapping the LIVE registry through a full same-version
// cutover (which, if it failed mid-flip, could leave Windows pointed at a dead
// port = the exact fail-closed the golden rule forbids), we validate the
// half of plan 0007 that decides an update's fate WITHOUT touching the live
// path: pick a real scaffold port, spawn the CURRENT build on it in true
// scaffold mode, prove it serves AND filters, retire it, and prove the live
// side (home proxy + registry + proxy-port.txt) came through untouched. The
// live registry flip itself stays covered by the real OTA E2E on HW (plan
// 0007's gate), not by an automated suite running unattended every release.
async function checkCutover() {
    if (isUnplugged()) return 'skip';                                   // watchdog kills proxies while unplugged
    if (isFlagFresh(UPDATING_FLAG_PATH, UPDATING_FLAG_STALE_MS)) return 'skip'; // a REAL cutover owns the machine

    const homePort = readChosenPort();
    const regPortBefore = getRegistryProxyPort();
    const portFileBefore = fs.existsSync(PORT_FILE) ? fs.readFileSync(PORT_FILE, 'utf-8') : null;

    // The REAL scaffold selector. null = the whole pool is squatted, which
    // means a genuine update would be forced onto the gap-prone same-port
    // degrade path — worth failing the gate over.
    const scaffoldPort = await selectScaffoldPort(homePort);
    if (scaffoldPort === null) return 'fail';

    let child = null;
    let result = 'fail';
    try {
        child = spawnScratchProxy(scaffoldPort);

        // The new-instance cold start is the very thing plan 0006/0007 fought;
        // give it the measured window (~60-90s on fleet HW) with margin.
        const up = await waitForTcpOpen(scaffoldPort, SCRATCH_HEALTH_RETRIES, HEALTH_POLL_MS);

        // The scratch instance must FILTER, not just listen (a proxy that comes
        // up fail-open would pass a bare port probe).
        const filters = up && (await connectVerdict(scaffoldPort, BAD_HOST, 5000)) === 'blocked';

        // Retire it: our own child first (precise), scoped PS kill as fallback.
        try { if (child.pid) process.kill(child.pid); } catch (_) { /* already gone */ }
        let retired = await waitForTcpClosed(scaffoldPort, PORT_CLOSE_RETRIES, HEALTH_POLL_MS);
        if (!retired) {
            killWatcherListenerOnPort(scaffoldPort);
            retired = await waitForTcpClosed(scaffoldPort, PORT_CLOSE_RETRIES, HEALTH_POLL_MS);
        }

        // Survival: the LIVE side must be exactly as we found it.
        const homeAlive = await checkTcpOpen('127.0.0.1', homePort, 2000);
        const regPortAfter = getRegistryProxyPort();
        const portFileAfter = fs.existsSync(PORT_FILE) ? fs.readFileSync(PORT_FILE, 'utf-8') : null;

        if (up && filters && retired && homeAlive
            && regPortAfter === regPortBefore
            && portFileAfter === portFileBefore) {
            result = 'pass';
        }
    } finally {
        // Belt-and-suspenders: never leave a scratch instance behind on failure.
        try { if (child && child.pid) process.kill(child.pid); } catch (_) { /* already gone */ }
    }
    return result;
}

// recovery: the escape hatches are PRESENT and syntactically VALID. Never
// executed — RestoreInternetNow/SetProxyByAvailability rewrite live proxy
// settings and BackToNormal is the uninstall path (irreversible = manual
// validation per fork B2).
function checkRecovery() {
    // RestoreInternetNow.bat — exists and still delegates to the safety script
    // (that delegation IS its entire job).
    const restore = fs.readFileSync(RESTORE_BAT_PATH, 'utf-8');
    if (!restore.trim() || !/SetProxyByAvailability\.ps1/i.test(restore)) return 'fail';

    // SetProxyByAvailability.ps1 — must COMPILE. [ScriptBlock]::Create parses
    // without executing; a syntax error exits 1 (execFileSync throws → "fail").
    const quotedPs1 = SETPROXY_PS1_PATH.replace(/'/g, "''");
    execFileSync('powershell.exe', [
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command',
        "try { $null = [ScriptBlock]::Create((Get-Content -LiteralPath '" + quotedPs1 + "' -Raw)) } catch { exit 1 }; exit 0"
    ], { stdio: 'ignore', timeout: 30000 });

    // The SOS gate: BackToNormal.bat with its emergency-code branch intact...
    const backToNormal = fs.readFileSync(BACKTONORMAL_BAT_PATH, 'utf-8');
    if (!/emergency-code\.hash/i.test(backToNormal) || !/agent-code-crypto\.js/i.test(backToNormal)) return 'fail';

    // ...the fleet-wide emergency hash present and well-formed ({salt, hash} —
    // shape only, contents never logged)...
    const emergency = JSON.parse(fs.readFileSync(EMERGENCY_HASH_PATH, 'utf-8'));
    if (!emergency || typeof emergency.salt !== 'string' || typeof emergency.hash !== 'string'
        || emergency.salt.length === 0 || emergency.hash.length === 0) return 'fail';

    // ...and the verifier the gate shells out to must at least COMPILE
    // (`node --check` parses without executing).
    execFileSync(process.execPath, ['--check', CODE_CRYPTO_PATH], { stdio: 'ignore', timeout: 30000 });

    return 'pass';
}

// ---------------------------------------------------------------------------
// Suite driver
// ---------------------------------------------------------------------------

async function runCheck(fn) {
    try {
        const r = await fn();
        return (r === 'pass' || r === 'fail' || r === 'skip') ? r : 'fail';
    } catch (_) {
        return 'fail'; // any throw in any check is a fail for THAT check only
    }
}

// The suite. NEVER throws; always returns all six keys, each "pass"|"fail"|"skip".
// Checks run sequentially (cheapest first, the scratch-proxy cycle second to
// last) so an early hard failure still leaves a fully-populated report.
async function runSelfTest() {
    return {
        persistencia: await runCheck(checkPersistencia),
        filtro: await runCheck(checkFiltro),
        config: await runCheck(checkConfig),
        whitelist: await runCheck(checkWhitelistMerge),
        cutover: await runCheck(checkCutover),
        recovery: await runCheck(checkRecovery),
    };
}

// --- once-per-version cache + single-flight (used by poll-hub.js) ---

function readState() {
    try {
        const s = JSON.parse(fs.readFileSync(STATE_PATH, 'utf-8'));
        return (s && typeof s === 'object') ? s : null;
    } catch (_) {
        return null; // missing/corrupt → as if never run
    }
}

function writeState(state) {
    try { fs.writeFileSync(STATE_PATH, JSON.stringify(state), 'utf-8'); } catch (_) { /* best effort */ }
}

function hasSkip(results) {
    return CHECKS.some((c) => results[c] === 'skip');
}

function isRecent(iso, windowMs) {
    const t = Date.parse(iso || '');
    return Number.isFinite(t) && (Date.now() - t) < windowMs;
}

// Exclusive-create lock. Polarity is deliberately OPPOSITE to self-update's
// acquireLock: there, an unmanageable lock must not block updates (fail-open);
// here, an unmanageable lock must not run the suite (a duplicate concurrent
// run is worse than a 2-minute deferral — the next poll simply retries).
function acquireSuiteLock() {
    try {
        if (fs.existsSync(SUITE_LOCK_PATH)) {
            const age = Date.now() - fs.statSync(SUITE_LOCK_PATH).mtimeMs;
            if (age < SUITE_LOCK_STALE_MS) return false; // another instance is mid-suite
            try { fs.unlinkSync(SUITE_LOCK_PATH); } catch (_) {}
        }
        const fd = fs.openSync(SUITE_LOCK_PATH, 'wx'); // atomic create-or-EEXIST
        fs.writeSync(fd, Buffer.from(new Date().toISOString(), 'utf-8'));
        fs.closeSync(fd);
        return true;
    } catch (_) {
        return false;
    }
}

function releaseSuiteLock() {
    try { fs.unlinkSync(SUITE_LOCK_PATH); } catch (_) {}
}

// What poll-hub.js calls each staging poll. Returns the cached-or-fresh result
// object to report, or null when there is nothing to report yet (first run in
// progress, or deferred). NEVER throws.
//
// Policy:
//   - cached result for THIS running version → reuse it (run-once-per-version),
//     except a skip-containing result older than SKIP_RETRY_MS, which re-runs
//     (skips are environment verdicts, not build verdicts — see SKIP_RETRY_MS).
//   - defer entirely (report the cache if any, run nothing) while a real update
//     owns the machine (updating.flag / update.lock — the suite is post-cutover
//     by spec) or while intentionally unplugged (would only manufacture fails).
//   - single-flight across the 2-min poll instances via selftest.lock.
async function maybeRunSelfTest(runningVersion) {
    try {
        const state = readState();
        const cached = (state && state.version === runningVersion && state.results) ? state.results : null;
        if (cached && (!hasSkip(cached) || isRecent(state.finishedAt, SKIP_RETRY_MS))) return cached;

        if (isFlagFresh(UPDATING_FLAG_PATH, UPDATING_FLAG_STALE_MS)) return cached;
        if (isFlagFresh(UPDATE_LOCK_PATH, UPDATE_LOCK_STALE_MS)) return cached;
        if (isUnplugged()) return cached;

        if (!acquireSuiteLock()) return cached;
        try {
            // Another instance may have finished between our read and the lock.
            const fresh = readState();
            if (fresh && fresh.version === runningVersion && fresh.results
                && (!hasSkip(fresh.results) || isRecent(fresh.finishedAt, SKIP_RETRY_MS))) {
                return fresh.results;
            }

            appendEvent('selftest-start', 'version ' + runningVersion);
            const startedAt = new Date().toISOString();
            writeState({ version: runningVersion, startedAt }); // crash forensics: a run began
            const results = await runSelfTest();
            writeState({ version: runningVersion, startedAt, finishedAt: new Date().toISOString(), results });
            appendEvent('selftest-done', CHECKS.map((c) => c + ':' + results[c]).join(' '));
            return results;
        } finally {
            releaseSuiteLock();
        }
    } catch (e) {
        // The suite must never take the poll down with it — swallow, breadcrumb, move on.
        try { appendEvent('selftest-error', e && e.message); } catch (_) {}
        return null;
    }
}

// Manual QA entry point (staging HW verification): `node self-test.js` prints
// the six results as JSON. NOTE: this runs the REAL suite, including the
// scratch-proxy cutover cycle — intended for the staging PC, never a banca.
if (require.main === module) {
    runSelfTest().then((results) => {
        console.log(JSON.stringify(results, null, 2));
    });
}

module.exports = { runSelfTest, maybeRunSelfTest, CHECKS, STATE_PATH };
