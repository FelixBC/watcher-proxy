// Pulls a new version of watcher-proxy from GitHub and applies it with no
// human interaction (plan 0001, AC7). Triggered by poll-hub.js when the hub
// reports a newer agent_version than this machine is running; also safe to
// run standalone/manually.
//
// GOLDEN RULE, non-negotiable: Windows is flipped to normal, unfiltered
// internet BEFORE the proxy process is stopped for any reason below. If this
// script crashes or the machine loses power mid-update, the worst case is
// "unfiltered internet, will self-heal to filtered once a proxy comes back"
// — never "no internet." This mirrors WatchdogLoop.ps1's own ordering.
'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { execFileSync, spawn } = require('child_process');
const net = require('net');

const { BRAIN_DIR, downloadFile } = require('./hub-client');
const { appendEvent } = require('./event-log');
const { readChosenPort, writeChosenPort, selectScaffoldPort, PORT_CANDIDATES } = require('./proxy-port');

const ROOT_DIR = path.join(BRAIN_DIR, '..');
const VERSION_PATH = path.join(ROOT_DIR, 'VERSION');
const UPDATE_LOG_PATH = path.join(BRAIN_DIR, 'update.log');

// All update work happens INSIDE WatcherBrain (which InstallWatcher.bat adds to
// the Windows Defender exclusion). A prior silent crash was consistent with
// Defender killing node while it unzipped in %TEMP% — outside the exclusion.
// Keeping the temp zip + extract here removes that whole failure mode.
const UPDATE_DIR = path.join(BRAIN_DIR, '_update');
// Single-flight lock: poll-hub fires every couple of minutes, and an update
// can take longer than that (slow disk/network), so without a lock each poll
// would spawn ANOTHER self-update on top of the running one — several racing
// to back up, stop the proxy and copy files at once. This guarantees one at a
// time; a stale lock (older than LOCK_STALE_MS, e.g. a run that was killed) is
// ignored so a machine can never get stuck unable to update.
const LOCK_PATH = path.join(BRAIN_DIR, 'update.lock');
const LOCK_STALE_MS = 20 * 60 * 1000;

// Raised for the risky window (flip -> stop proxy -> copy -> restart) and
// cleared in finally. Every watchdog layer honors it: SetProxyByAvailability
// forces NORMAL internet while it exists (so it never re-points Windows at the
// proxy we're about to kill), and WatchdogLoop / CheckAndStartProxy leave the
// proxy alone. This is what actually holds the GOLDEN RULE during an update —
// the single upfront flipToNormalInternet() is otherwise undone within ~5s by
// the watchdog re-enabling the proxy the instant it sees it still listening,
// after which we kill the proxy for the copy and Windows is left pointing at a
// dead 127.0.0.1:8080 = internet fully down.
const UPDATING_FLAG_PATH = path.join(BRAIN_DIR, 'updating.flag');

// Nelson can mark a machine "unplugged" (intentionally unfiltered) from the
// dashboard. The watchdog forces normal internet AND kills the proxy while this flag
// exists (plan 0001), so a cutover would fight it — we defer the update, and never
// force the proxy back on, while it's set.
const UNPLUGGED_FLAG_PATH = path.join(BRAIN_DIR, 'unplugged.flag');

// Post-update health is a GENEROUS CEILING, not a tight fit. waitForHealthy
// EARLY-RETURNS the instant the port opens, so a healthy proxy costs only its real
// startup time; this total only bounds how long we wait for a genuinely-dead version
// before rolling back. On real hardware the post-swap cold-start (node re-scanned by
// Defender over the freshly-copied tree) was ~60-90s (worst 91s in the field logs
// that produced the 44-min loop) — the old blind 15s rolled back a proxy that was
// coming up fine. 300s covers slower fleet HW with margin. See docs/plans/0006.
// COUPLING: the watchdog .ps1 layers treat updating.flag as stale after
// STALE_FLAG_MINUTES (15) — keep patient + rollback + overhead well under that; if
// you grow this window, re-derive STALE_FLAG_MINUTES in the three .ps1 consumers.
const HEALTH_POLL_MS = 3000;
const PATIENT_HEALTH_RETRIES = 100; // ~300s ceiling (early-returns the instant the port opens)
// Plan 0007 blue-green: returning to the home port after the scaffold cutover can
// hit the OS still holding the just-freed port (TIME_WAIT) — a fresh proxy then
// EADDRINUSE→exit(0)s. So the return-home step RE-SPAWNS on a cadence until it
// binds, bounded by this ceiling. The scaffold proxy keeps filtering the whole
// time, so there is no gap regardless of how long the home port takes to free.
// BURST = health polls per spawn attempt before re-spawning.
const HOME_REBIND_CEILING_MS = 300 * 1000; // ~5min, matches the patient health window
const HOME_REBIND_BURST_RETRIES = 2;       // ~6s per spawn attempt
// R4: after killing the old home proxy, wait this long for the OS to actually release
// the port before trusting a listener there as "our new one". If it never frees (a
// silently-failed kill / stuck old proxy), we adopt the live scaffold as home instead.
const PORT_CLOSE_RETRIES = 20; // ~60s (× HEALTH_POLL_MS)

// Failed-version cooldown marker. Written ONLY when a genuine update to a version
// fails its post-update health check and we roll back (NOT on a pre-swap download/
// checksum failure — that's transient infra, not the version's fault). poll-hub.js
// reads it before re-triggering and will NOT re-run self-update for the SAME failed
// version within the cooldown, so a bad version can't re-loop every 2-min poll (the
// ~44-min loop's engine). A strictly newer version bypasses it (forward-only).
// Runtime-created + plain (not Hidden+System) → a normal writeFileSync is fine.
const UPDATE_FAILED_PATH = path.join(BRAIN_DIR, 'update-failed.json');

function acquireLock() {
    try {
        if (fs.existsSync(LOCK_PATH)) {
            const age = Date.now() - fs.statSync(LOCK_PATH).mtimeMs;
            if (age < LOCK_STALE_MS) return false;
        }
        fs.writeFileSync(LOCK_PATH, new Date().toISOString(), 'utf-8');
        return true;
    } catch (e) {
        return true; // if we can't manage the lock, don't block updates
    }
}

function releaseLock() {
    try { fs.unlinkSync(LOCK_PATH); } catch (e) {}
}

// Failed-version cooldown (see UPDATE_FAILED_PATH note). recordFailedVersion is
// written ONLY when a genuine update fails its post-update health check and we roll
// back — poll-hub.js then refuses to re-trigger that SAME version until the cooldown
// passes (a strictly newer version bypasses it), so one failed health check can no
// longer re-fire every 2-min poll. clearFailedVersion drops the marker on success.
function recordFailedVersion(version) {
    try {
        fs.writeFileSync(UPDATE_FAILED_PATH, JSON.stringify({ version, failedAt: new Date().toISOString() }), 'utf-8');
    } catch (e) { log(`Could not record failed version: ${e.message}`); }
}

function clearFailedVersion() {
    try { fs.unlinkSync(UPDATE_FAILED_PATH); } catch (e) {}
}

async function downloadWithRetry(url, dest, timeoutMs, attempts, onEvent) {
    let lastErr;
    for (let i = 1; i <= attempts; i++) {
        try {
            await downloadFile(url, dest, timeoutMs, onEvent);
            return;
        } catch (e) {
            lastErr = e;
            log(`download attempt ${i}/${attempts} failed: ${e.message}`);
            await new Promise((r) => setTimeout(r, 3000));
        }
    }
    throw lastErr;
}

// Never overwritten by an update: machine identity/secrets, this machine's
// own local whitelist extras, and anything log/state-like that isn't code.
const PROTECTED_RELATIVE_PATHS = [
    'whitelist.txt',
    // Plan 0008: the on-disk last-known-good whitelist. Per-machine safety-net state,
    // written by the running proxy — an OTA must never overwrite it (it's what lets a
    // cold boot with a bad live whitelist keep filtering).
    'WatcherBrain/whitelist-lastgood.txt',
    'WatcherBrain/node',
    'WatcherBrain/HubConfig.json',
    'WatcherBrain/hub-credential.json',
    'WatcherBrain/uninstall-code.hash',
    'WatcherBrain/unplugged.flag',
    'WatcherBrain/updating.flag',
    'WatcherBrain/update-failed.json',
    'WatcherBrain/whitelist-version.txt',
    'WatcherBrain/proxy-port.txt',
    'WatcherBrain/poll-log-cursor.txt',
    'WatcherBrain/blocked-requests.log',
    'WatcherBrain/blocked-log-cleared-at.txt',
    // Per-machine visit state written by the RUNNING proxy on every allowed
    // request. Plan 0007 copies the new tree in while the old proxy is still live
    // (to keep filtering with no gap), so — unlike 0006's stop-then-copy — these
    // could be overwritten mid-write; protect them (they're machine state, never
    // code, exactly like blocked-requests.log above).
    'WatcherBrain/recent-visits.json',
    'WatcherBrain/first-visit.json',
    'WatcherBrain/update.log',
    'WatcherBrain/_update',
    'WatcherBrain/machine-name.txt',
    'WatcherBrain/machine-zone.txt',
    'WatcherBrain/machine-code.txt',
    'WatcherBrain/location.json',
    'WatcherBrain/locate-pending.flag',
    'WatcherBrain/tamper-cursor.txt',
    // Plan 0011: per-machine "guards last confirmed clean" marker. Runtime state, never code — an
    // OTA (incl. a rollback restore) must not touch it: rewriting it would rewrite the "último OK"
    // signal. poll-hub reads its CONTENT (not mtime) as a belt, this is the suspenders.
    'WatcherBrain/guards-ok.txt',
    // Plan 0013: the print-harvest cursor (last EventRecordID already posted). Runtime state, and
    // a rollback that REWOUND it would re-send prints the hub already stored — harmless only
    // because the hub dedups on (machine_id, at, record_id); protect it so we don't rely on that.
    'WatcherBrain/print-cursor.txt',
    // The per-machine "we have enabled the print log here at least once" marker. If an OTA
    // restored/erased it, the machine would forget its own baseline and read the NEXT real
    // disable as a debut — silently losing the tamper this plan exists to catch.
    'WatcherBrain/print-log-baselined.flag',
    // "We already reported the harvest as broken." A rollback restoring a stale one would cost a
    // missing line or a duplicate — small, but the other two markers are protected for the same
    // class of reason and an unexplained exception is worse than the line it saves.
    'WatcherBrain/print-harvest-failed.flag',
    '.git',
];

function log(message) {
    const line = `[${new Date().toISOString()}] ${message}\n`;
    try { fs.appendFileSync(UPDATE_LOG_PATH, line, 'utf-8'); } catch (e) { /* best effort */ }
    console.log(message);
}

// execSync's default error.message is just "Command failed: <cmd>" with no
// indication of WHY - the actual reason lives in e.stderr/e.stdout, which
// are only populated if stdio wasn't set to 'ignore' on that call.
function describeError(e) {
    const stderr = e.stderr ? e.stderr.toString().trim() : '';
    const stdout = e.stdout ? e.stdout.toString().trim() : '';
    const detail = [stderr, stdout].filter(Boolean).join(' | ');
    return detail ? `${e.message} — ${detail}` : e.message;
}

// Backup folders are timestamped (WatcherBrain/_backup_<version>_<ts>), so
// they can't be listed in PROTECTED_RELATIVE_PATHS by exact name. Without
// this, copyTree(ROOT_DIR, backupDir) would walk into the backup directory
// it just created (backupDir lives under BRAIN_DIR, which is under
// ROOT_DIR) and copy it into itself, recursing until disk fills up - the
// same pattern this repo's own .gitignore already carves out for
// WatcherBrain/_backup_*/.
const BACKUP_DIR_RE = /^WatcherBrain\/_backup_/;

function isProtected(relativePath) {
    const normalized = relativePath.split(path.sep).join('/');
    if (BACKUP_DIR_RE.test(normalized)) return true;
    return PROTECTED_RELATIVE_PATHS.some(
        (p) => normalized === p || normalized.startsWith(p + '/')
    );
}

// Overwrite an EXISTING dest file in place (open r+ -> truncate -> write) instead
// of fs.copyFileSync. On Windows, copyFileSync opens the dest with CREATE_ALWAYS,
// which FAILS with EPERM when the dest carries the Hidden+System attributes the
// install's disguise sets on shipped files (BackToNormal.bat, whitelist.txt,
// VERSION, ...). That killed EVERY self-update: it copied the new tree over the
// old, hit "EPERM: operation not permitted, copyfile ...BackToNormal.bat" on the
// first hidden file, rolled back, and retried forever (flashing windows each try).
// Opening the existing file r+ preserves the attributes and avoids the EPERM;
// copyFileSync is only used to CREATE a brand-new file (nothing to preserve).
function overwriteFile(srcPath, destPath) {
    if (!fs.existsSync(destPath)) {
        fs.copyFileSync(srcPath, destPath);
        return;
    }
    const data = fs.readFileSync(srcPath);
    const fd = fs.openSync(destPath, 'r+');
    try {
        // Write-then-truncate (never truncate-first): an interrupted write then leaves
        // the new content, or new+old-tail — never an empty file. See writeInPlace in
        // whitelist-merge.js for why the empty window matters.
        fs.writeSync(fd, data, 0, data.length, 0);
        fs.ftruncateSync(fd, data.length);
    } finally {
        fs.closeSync(fd);
    }
}

// Same Hidden+System-safe write for a short string (VERSION). fs.writeFileSync
// would EPERM on the disguised (Hidden+System) VERSION file, so the version marker
// never advanced after a copy — write it in place instead.
function writeFileInPlace(destPath, content) {
    if (!fs.existsSync(destPath)) {
        fs.writeFileSync(destPath, content, 'utf-8');
        return;
    }
    const buf = Buffer.from(content, 'utf-8');
    const fd = fs.openSync(destPath, 'r+');
    try {
        // Write-then-truncate (never leave the file momentarily empty).
        fs.writeSync(fd, buf, 0, buf.length, 0);
        fs.ftruncateSync(fd, buf.length);
    } finally {
        fs.closeSync(fd);
    }
}

function copyTree(srcDir, destDir, relativeBase) {
    for (const entry of fs.readdirSync(srcDir, { withFileTypes: true })) {
        const rel = relativeBase ? `${relativeBase}/${entry.name}` : entry.name;
        if (isProtected(rel)) continue;

        const srcPath = path.join(srcDir, entry.name);
        const destPath = path.join(destDir, entry.name);

        if (entry.isDirectory()) {
            fs.mkdirSync(destPath, { recursive: true });
            copyTree(srcPath, destPath, rel);
        } else {
            fs.mkdirSync(path.dirname(destPath), { recursive: true });
            overwriteFile(srcPath, destPath);
        }
    }
}

// stdio left as default (piped) rather than 'ignore' on every call below,
// deliberately: an earlier version used 'ignore' throughout and a real
// failure on a real VM came back as a totally empty error message,
// impossible to diagnose. Piped stdio means a thrown error carries
// e.stderr/e.stdout, which main()'s catch block now logs.

// execFileSync with argv arrays throughout this file, deliberately, NOT
// execSync with a concatenated string - the string form goes through
// cmd.exe's own shell parsing before the target program ever sees it,
// which mangled a command with this much nested quoting.

const REG_KEY = 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings';

function flipToNormalInternet() {
    // GOLDEN RULE — see file header. Done before anything else touches the
    // proxy process, mirroring WatchdogLoop.ps1's unplug ordering exactly.
    //
    // Uses reg.exe, NOT PowerShell's Set-ItemProperty/Remove-ItemProperty.
    // Confirmed by hand on two separate real VMs: the identical PowerShell
    // command reliably failed (sometimes an immediate empty error,
    // sometimes a multi-minute hang) specifically when run with its
    // working directory inside the Watcher folder - consistent with AMSI
    // (which scans PowerShell script *content*, not plain Win32 tools)
    // flagging "a script modifying Internet Settings proxy keys," which is
    // exactly the pattern browser/traffic-hijacking malware uses. reg.exe
    // has been reliable all session in InstallWatcher.bat/BackToNormal.bat,
    // which never had this problem because they were never rewritten as
    // PowerShell in the first place.
    execFileSync('reg.exe', ['add', REG_KEY, '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '0', '/f']);
    // Best-effort: the only goal is "make sure ProxyServer isn't set." If
    // it's already gone (the common case, since this often re-runs after a
    // previous pass already cleared it), that goal is met either way -
    // same intent as PowerShell's -ErrorAction SilentlyContinue. Swallow
    // unconditionally rather than pattern-match reg.exe's error text.
    try {
        execFileSync('reg.exe', ['delete', REG_KEY, '/v', 'ProxyServer', '/f']);
    } catch (e) { /* fine either way */ }
}

function stopProxyAndWatchdog() {
    execFileSync('powershell.exe', [
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', path.join(BRAIN_DIR, 'StopWatcherProcesses.ps1')
    ]);
}

function startProxyAndWatchdog() {
    execFileSync('wscript.exe', [path.join(BRAIN_DIR, 'RunWatchdogLoopHidden.vbs')]);
    execFileSync('wscript.exe', [path.join(BRAIN_DIR, 'StartWatcher.vbs'), 'nocheck']);
}

// In-process TCP reachability check: connect to host:port, resolve true if it
// accepts within timeoutMs, false otherwise. Replaces spawning a powershell
// (CheckPort.ps1) on EVERY check — that child-process launch added ~2.5s of
// overhead per check, stretching the patient window from its nominal
// retries×delay (~300s) to ~555s wall-clock (measured on the test PC). An
// in-process net.connect keeps each failing check ≈ the delay only, so the window
// is predictable and updating.flag isn't held longer than intended.
// (StartWatcher.vbs and the watchdog .ps1 scripts still use CheckPort.ps1 — unchanged.)
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

// Poll until a proxy is listening on `port` (127.0.0.1), or `retries` are spent.
// Takes an EXPLICIT port: plan 0007 waits for the scaffold port, then for the home
// port — never the same one at once — so it must not read the persisted port itself.
async function waitForHealthy(port, retries, delayMs) {
    for (let i = 0; i < retries; i++) {
        if (await checkTcpOpen('127.0.0.1', port, 2000)) return true;
        await new Promise((r) => setTimeout(r, delayMs));
    }
    return false;
}

// Inverse of waitForHealthy: poll until NOTHING is listening on `port` (the just-killed
// proxy actually released it), or retries are spent. R4: a silently-failed kill would
// otherwise leave the OLD proxy listening, and waitForHealthy would accept it as our
// freshly-spawned one — marking VERSION new while old code still runs.
async function waitForPortClosed(port, retries, delayMs) {
    for (let i = 0; i < retries; i++) {
        if (!(await checkTcpOpen('127.0.0.1', port, 2000))) return true;
        await new Promise((r) => setTimeout(r, delayMs));
    }
    return false;
}

// === Plan 0007 blue-green cutover helpers ===
// Registry writes use reg.exe (NOT PowerShell), symmetric to flipToNormalInternet
// above — same AMSI-avoidance reasoning (see that function's comment). During an
// update self-update OWNS every registry write; the watchdog only reacts (it forces
// normal internet if the port Windows points at goes dead — see
// SetProxyByAvailability.ps1's updating-flag branch).
function isUnplugged() {
    // Nelson marked this machine intentionally unfiltered from the dashboard.
    return fs.existsSync(UNPLUGGED_FLAG_PATH);
}

function setRegistryProxyOn(port) {
    // Golden rule: only ever called AFTER a proxy is confirmed listening on `port`,
    // so Windows never points at a dead proxy. Symmetric to flipToNormalInternet.
    // NOTE (green-loop R0): this NO LONGER no-ops on unplug. A silent no-op here while
    // the caller still went on to kill the home proxy left Windows pointing at a dead
    // home port = fail-CLOSED. Unplug is now handled at the cutover DECISION points
    // (abort before killing home; skip re-enable after a flip-to-normal) so we never
    // kill a proxy Windows is still pointed at.
    execFileSync('reg.exe', ['add', REG_KEY, '/v', 'ProxyServer', '/t', 'REG_SZ', '/d', `127.0.0.1:${port}`, '/f']);
    execFileSync('reg.exe', ['add', REG_KEY, '/v', 'ProxyOverride', '/t', 'REG_SZ', '/d', '<local>', '/f']);
    execFileSync('reg.exe', ['add', REG_KEY, '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '1', '/f']);
}

// The port Windows is CURRENTLY pointed at (ProxyServer = "127.0.0.1:NNNNN"), or null
// if unset / not our loopback proxy. The registry is the source of truth for the live
// proxy during a cutover, so the orphan sweep uses this to never kill the proxy Windows
// is actively routing through. reg.exe query (no PowerShell) — same AMSI-avoidance as
// flipToNormalInternet.
function getRegistryProxyPort() {
    try {
        const out = execFileSync('reg.exe', ['query', REG_KEY, '/v', 'ProxyServer'], { encoding: 'utf-8' });
        const m = out.match(/127\.0\.0\.1:(\d+)/);
        if (m) return parseInt(m[1], 10);
    } catch (_) { /* unset / no proxy configured */ }
    return null;
}

// Spawn a proxy DIRECTLY (not via StartWatcher.vbs, which launches through wscript
// detached and hides the node PID). detached + unref so the proxy OUTLIVES this
// self-update process — essential for the home proxy, which must keep filtering
// after we exit. process.execPath is the bundled node running this very script.
// persist:false sets WATCHER_NO_PERSIST_PORT so the scaffold proxy never rewrites
// proxy-port.txt (which must stay = home for the whole cutover).
function spawnProxy(port, { persist }) {
    const env = { ...process.env, WATCHER_OVERRIDE_PORT: String(port) };
    if (!persist) env.WATCHER_NO_PERSIST_PORT = '1';
    const child = spawn(process.execPath, ['proxy-server.js'], {
        cwd: BRAIN_DIR, env, detached: true, stdio: 'ignore'
    });
    // A spawn-level 'error' (e.g. execPath vanished) would otherwise be an unhandled
    // 'error' event → uncaughtException. Swallow it — waitForHealthy is the real signal.
    child.on('error', () => {});
    child.unref();
    return child;
}

// Kill ONLY our proxy-server.js instance listening on `port` — scoped by BOTH the
// listening port AND the command line, so the same-port degrade can never
// collaterally kill the scaffold proxy, and the pool sweep can never kill a
// non-watcher process that transiently holds a pool port. Best-effort.
function killListenerOnPort(port) {
    // netstat (NOT Get-NetTCPConnection, which is Win8+/Server2012+ only — this matches
    // the watchdog's Get-CimInstance compat floor) → the PID owning the LISTEN on this
    // port; then scope to OUR proxy-server.js by command line so we never kill a
    // collateral process. Every literal is single-quoted (no inner double-quotes) to
    // dodge the nested cmd/PowerShell quoting hazard this file documents at flipToNormal.
    // Best-effort: a missing/already-dead listener, or a swallowed error, is fine.
    const ps =
        `$ErrorActionPreference='SilentlyContinue';` +
        `netstat -ano | ForEach-Object {` +
        ` $f = $_ -split '\\s+' | Where-Object { $_ };` +
        ` if ($f.Length -ge 5 -and $f[3] -eq 'LISTENING' -and $f[1] -like '*:${port}') {` +
        ` $procId = $f[4];` +
        ` $p = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $procId);` +
        ` if ($p -and $p.CommandLine -like '*proxy-server.js*') { Stop-Process -Id $procId -Force } } }`;
    try {
        execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', ps], { stdio: 'ignore' });
    } catch (e) { /* best effort — a missing/already-dead listener is fine */ }
}

// Retire any of OUR proxies left listening on a NON-home pool port — an orphan a
// prior crashed/power-lost cutover may have stranded on a scaffold port. Scoped by
// killListenerOnPort to our proxy only, and never touches the home port. Run at the
// start of an update and again in finally, so a scaffold node never accumulates
// between updates.
function sweepScaffoldOrphans(homePort) {
    // Registry-aware defense (green-loop #1): never kill the proxy Windows is actively
    // routing filter traffic through, even if proxy-port.txt somehow disagrees (e.g. a
    // home-rebind-deferred adopt whose writeChosenPort failed). Killing it = fail-closed.
    const livePort = getRegistryProxyPort();
    for (const p of PORT_CANDIDATES) {
        if (p === homePort || p === livePort) continue;
        killListenerOnPort(p);
    }
}

// Return to the home port after the scaffold cutover. The just-freed home port may
// be briefly OS-held (TIME_WAIT), so a fresh proxy EADDRINUSE→exit(0)s; re-spawn on
// a cadence until it binds, bounded by the ceiling. The scaffold keeps filtering the
// WHOLE time, so there is no gap however long this takes. Heartbeats updating.flag
// each loop so the watchdog's 15-min stale guard measures THIS phase on its own
// clock, not the sum of both health windows.
async function respawnHomeUntilHealthy(homePort) {
    const deadline = Date.now() + HOME_REBIND_CEILING_MS;
    // Only (re)spawn when we DON'T already have a live child starting up. A node
    // that EADDRINUSE→exit(0)s (the port is briefly OS-held) flips childExited, so
    // the next loop re-spawns; a node still cold-starting stays, so a slow second
    // start does NOT trigger a spawn storm — we just keep waiting on the one child.
    let childExited = true;
    while (Date.now() < deadline) {
        if (childExited) {
            childExited = false;
            const child = spawnProxy(homePort, { persist: true });
            child.once('exit', () => { childExited = true; });
        }
        if (await waitForHealthy(homePort, HOME_REBIND_BURST_RETRIES, HEALTH_POLL_MS)) return true;
        try { fs.writeFileSync(UPDATING_FLAG_PATH, new Date().toISOString(), 'utf-8'); } catch (e) {}
    }
    return false;
}

// AC4 degrade: no scaffold port was free, so fall back to the 0006 same-port
// kill-and-rebind. This has a real (fail-OPEN) gap like 0006 but converges and
// never fails closed. The new files are already copied by main(); VERSION is still
// the old one. self-update sets PE here itself (the watchdog no longer re-enables
// during the flag). Returns true on success, false after a rollback to the old one.
async function sameportCutover(homePort, argVersion, localVersion, backupDir) {
    flipToNormalInternet();            // fail-open FIRST (golden rule), then kill
    killListenerOnPort(homePort);
    if (await respawnHomeUntilHealthy(homePort)) {
        // R0: if an unplug landed, leave normal internet (from the flip above) — don't
        // re-enable the proxy against an explicit unplug. Safe either way (already PE=0).
        if (!isUnplugged()) setRegistryProxyOn(homePort);  // new proxy healthy → point Windows at it
        writeFileInPlace(VERSION_PATH, argVersion);
        log(`Same-port degrade update to ${argVersion} successful and healthy.`);
        appendEvent('update-ok', `${localVersion} -> ${argVersion} (same-port degrade)`);
        return true;
    }
    // The new version never came up on the home port — roll back to the old one.
    log('Same-port degrade: new version did not come up — rolling back.');
    killListenerOnPort(homePort);
    restoreBackup(backupDir);
    writeFileInPlace(VERSION_PATH, localVersion);
    recordFailedVersion(argVersion);
    const restored = await respawnHomeUntilHealthy(homePort);
    if (restored && !isUnplugged()) setRegistryProxyOn(homePort);
    log(restored
        ? 'Rollback successful, previous version restored and healthy.'
        : 'Rollback not confirmed healthy — watchdog will keep retrying; fail-open holds.');
    return false;
}

function backupCurrent(version) {
    const backupDir = path.join(BRAIN_DIR, `_backup_${version}_${Date.now()}`);
    fs.mkdirSync(backupDir, { recursive: true });
    copyTree(ROOT_DIR, backupDir, '');
    return backupDir;
}

function restoreBackup(backupDir) {
    copyTree(backupDir, ROOT_DIR, '');
}

// Every update creates a new timestamped backup dir (above) and none were
// ever pruned, so they pile up under BRAIN_DIR forever, quietly filling disk
// over successive OTA updates. Called ONLY once the machine is confirmed
// healthy again (post-update or post-rollback) — never before the health
// check — and kept best-effort: only entries matching the exact backup name
// pattern are ever touched, and any failure here is swallowed so cleanup can
// never break the update or the golden rule.
const MAX_BACKUPS_TO_KEEP = 2;
const BACKUP_ENTRY_NAME_RE = /^_backup_/;

function pruneOldBackups(keep) {
    try {
        const entries = fs.readdirSync(BRAIN_DIR, { withFileTypes: true })
            .filter((e) => e.isDirectory() && BACKUP_ENTRY_NAME_RE.test(e.name))
            .map((e) => {
                const fullPath = path.join(BRAIN_DIR, e.name);
                let mtimeMs = 0;
                try { mtimeMs = fs.statSync(fullPath).mtimeMs; } catch (e2) { /* keep 0, sorts last */ }
                return { name: e.name, fullPath, mtimeMs };
            })
            .sort((a, b) => b.mtimeMs - a.mtimeMs); // newest first

        for (const entry of entries.slice(keep)) {
            try {
                fs.rmSync(entry.fullPath, { recursive: true, force: true });
                log(`Pruned old backup: ${entry.name}`);
            } catch (e) {
                log(`Could not prune backup ${entry.name}: ${e.message}`);
            }
        }
    } catch (e) {
        log(`Backup pruning skipped: ${e.message}`);
    }
}

async function main() {
    // Target comes from the hub via poll-hub.js: version, download URL, sha256.
    const [, , argVersion, argUrl, argSha] = process.argv;
    if (!argVersion || !argUrl) {
        log('self-update called without version/url — nothing to do.');
        return;
    }

    const localVersion = fs.existsSync(VERSION_PATH)
        ? fs.readFileSync(VERSION_PATH, 'utf-8').trim()
        : '0.0.0';
    if (argVersion === localVersion) {
        return; // already on this version
    }

    // Only one update at a time (see LOCK_PATH note above).
    if (!acquireLock()) {
        log('Another update is already in progress — skipping this trigger.');
        return;
    }

    // Don't run a cutover into an intentional unplug: while unplugged.flag exists the
    // watchdog forces normal internet + kills the proxy, which would fight the
    // cutover. Defer — the next poll re-triggers once the machine resumes. (An unplug
    // that lands MID-update instead is caught by the setRegistryProxyOn guard + the
    // health checks failing into a safe fail-open rollback.)
    if (fs.existsSync(UNPLUGGED_FLAG_PATH)) {
        log('Machine is unplugged (dashboard) — deferring the update until it resumes.');
        releaseLock();
        return;
    }

    log(`Update available (from hub): ${localVersion} -> ${argVersion}`);

    // Fresh workspace inside the Defender-excluded folder.
    try { fs.rmSync(UPDATE_DIR, { recursive: true, force: true }); } catch (e) {}
    fs.mkdirSync(UPDATE_DIR, { recursive: true });
    const tempZip = path.join(UPDATE_DIR, 'package.zip');
    const tempExtract = path.join(UPDATE_DIR, 'extract');

    const backupDir = backupCurrent(localVersion);
    log(`Backed up current install to ${backupDir}`);

    // AC5 fail-closed guard: only once we've actually STARTED mutating the install
    // may the catch's rollback (stop old proxy + restore) run. A failure BEFORE the
    // swap (download / checksum / extract to temp) must NOT tear down the still-
    // healthy old proxy for a transient blip — see the catch block.
    let swapStarted = false;

    try {
        log(`Starting download of ${argUrl} to ${tempZip}`);
        await downloadWithRetry(argUrl, tempZip, 60000, 3, (event, detail) => {
            log(`downloadFile: ${event} ${JSON.stringify(detail)}`);
        });
        log('Download finished.');

        // Verify the bytes BEFORE we touch anything on the machine.
        if (argSha) {
            const actual = crypto.createHash('sha256').update(fs.readFileSync(tempZip)).digest('hex');
            if (actual.toLowerCase() !== argSha.toLowerCase()) {
                throw new Error(`checksum mismatch: expected ${argSha}, got ${actual}`);
            }
            log('Checksum OK.');
        }

        // Extract to the Defender-excluded temp dir BEFORE we touch the proxy. A
        // corrupt/failed archive then fails while the OLD proxy is still up and
        // filtering, so the catch's !swapStarted branch can safely do nothing (no
        // proxy was stopped, nothing to restart). Only copyTree below mutates the
        // real install. (Extracting after the stop would leave filtering down for the
        // watchdog delay + a cold-start on a bad-archive failure — avoided by ordering.)
        fs.mkdirSync(tempExtract, { recursive: true });
        execFileSync('powershell.exe', [
            '-NoProfile', '-NonInteractive', '-Command',
            `Expand-Archive -Path '${tempZip}' -DestinationPath '${tempExtract}' -Force`
        ]);

        // === Plan 0007 — blue-green zero-gap cutover ===
        // The filter must never blink off. Rather than kill the old proxy on the
        // home port and cold-start the new one there (0006's ~60-90s dark gap), bring
        // the new proxy up on a scaffold port while the OLD keeps filtering on the
        // home port, switch Windows to the scaffold only once it is listening, kill
        // the old proxy, return to the now-free home, switch Windows back, and retire
        // the scaffold. Two proxies are alive ONLY inside this bounded,
        // updating.flag-gated window — the "one port ⇒ one proxy" relaxation captured
        // in ADR 0001.
        const homePort = readChosenPort();

        // Clear a scaffold-port orphan a prior crashed/power-lost cutover may have
        // stranded (belt-and-suspenders; the finally sweep is the primary). Scoped to
        // our proxy only — never the home port, never a non-watcher process.
        sweepScaffoldOrphans(homePort);

        // Copy the new tree in FIRST, while the OLD proxy is still filtering on the
        // home port. Node loaded its code at startup, so overwriting the files on
        // disk does not disturb the running old proxy — it keeps serving from memory.
        // From here the install is mutated: a failure now must restore the backup
        // (swapStarted gates the catch's rollback). VERSION is written LATE (only once
        // the home cutover is confirmed) so the fleet never sees the new version while
        // the machine still runs old code.
        // Raise the flag BEFORE the first install mutation so the watchdog is gated
        // for the WHOLE copy: it hands off the proxy LIFECYCLE (no start/kill) and
        // enforces the golden rule REACTIVELY (reads the port Windows points at,
        // forces normal internet only if it's dead). Without this, a proxy crash
        // during the copy could let the ungated watchdog launch a proxy from a
        // half-copied tree. self-update owns every registry write below.
        fs.writeFileSync(UPDATING_FLAG_PATH, new Date().toISOString(), 'utf-8');

        swapStarted = true;
        copyTree(tempExtract, ROOT_DIR, '');
        log('New files copied in (old proxy still filtering on the home port).');

        const scaffoldPort = await selectScaffoldPort(homePort);
        if (scaffoldPort === null) {
            // AC4: no scaffold port free (rare) — degrade to the 0006 same-port path.
            if (await sameportCutover(homePort, argVersion, localVersion, backupDir)) {
                clearFailedVersion();
                pruneOldBackups(MAX_BACKUPS_TO_KEEP);
            }
            return;
        }

        // --- Phase 1: bring the NEW proxy up on the scaffold port (old proxy still
        // filtering the home port). This VALIDATES the new version BEFORE any cutover. ---
        log(`Starting new proxy on scaffold port ${scaffoldPort} (home ${homePort} still filtering).`);
        spawnProxy(scaffoldPort, { persist: false });
        const bHealthy = await waitForHealthy(scaffoldPort, PATIENT_HEALTH_RETRIES, HEALTH_POLL_MS);
        if (!bHealthy) {
            // The new version never came up on the scaffold port. The OLD proxy on the
            // home port was NEVER stopped — it is still filtering. ZERO disruption.
            // Restore the old files (so disk matches the running old proxy), mark the
            // version failed, done. Strictly better than 0006, which had to kill first
            // and only THEN discover the version was bad.
            log('New version did not come up on the scaffold port — rolling back with ZERO disruption (old proxy never stopped).');
            killListenerOnPort(scaffoldPort);
            restoreBackup(backupDir);
            recordFailedVersion(argVersion);
            return;
        }

        // R0 — unplug abort: if Nelson marked this machine unfiltered while we were
        // validating the scaffold, do NOT cut over or kill the home proxy (that would
        // strand Windows on a soon-to-be-killed home port = fail-CLOSED). Leave the old
        // proxy filtering on home, retire the scaffold, and let the watchdog apply the
        // unplug (normal internet). The update re-triggers once the machine resumes.
        if (isUnplugged()) {
            log('Unplugged mid-update — aborting the cutover before touching the home proxy (old proxy left running).');
            killListenerOnPort(scaffoldPort);
            restoreBackup(backupDir);
            return;
        }

        // --- Cutover to the scaffold: point Windows at the new proxy. BOTH proxies
        // are live at this instant, so the flip is gap-free. Golden rule: we point at
        // the scaffold only AFTER it is confirmed listening. Then kill the old proxy
        // on the home port (scoped to our proxy on that port — never the scaffold). ---
        setRegistryProxyOn(scaffoldPort);
        log(`Windows switched to new proxy on ${scaffoldPort}; killing old proxy on home ${homePort}.`);
        killListenerOnPort(homePort);

        // --- Phase 2: return to the fixed home. Heartbeat first so the stale guard
        // measures this second start on its own clock. R4: CONFIRM the old proxy
        // actually released the home port before trusting a listener there — a
        // silently-failed kill would otherwise let waitForHealthy accept the OLD proxy
        // as our freshly-spawned one (VERSION marked new while old code still runs).
        // respawnHomeUntilHealthy then keeps re-spawning while the freed port is OS-held;
        // the scaffold keeps filtering the whole time, so there is no gap. ---
        fs.writeFileSync(UPDATING_FLAG_PATH, new Date().toISOString(), 'utf-8');
        log(`Returning to the home port ${homePort}.`);
        const homeFreed = await waitForPortClosed(homePort, PORT_CLOSE_RETRIES, HEALTH_POLL_MS);
        if (!homeFreed) {
            log(`Home port ${homePort} did not free after the kill (old proxy may be stuck) — adopting the live scaffold as home instead of risking a false health pass.`);
        }
        const homeHealthy = homeFreed && await respawnHomeUntilHealthy(homePort);
        if (!homeHealthy) {
            // Home didn't free (stuck old proxy), OR didn't rebind within the ceiling.
            // Either way Windows still points at the LIVE scaffold (new code), so there
            // is NO gap. AC1 (never drop the filter) outranks AC2 (no drift): adopt the
            // scaffold as the home so the watchdog keeps filtering through it after the
            // flag clears, record the new VERSION (the new code IS running on the
            // scaffold), and re-home on the next update. Do NOT tear down the live
            // filter to chase the home port.
            writeChosenPort(scaffoldPort);
            writeFileInPlace(VERSION_PATH, argVersion);
            log(`Home port did not come back; keeping the filter live on scaffold ${scaffoldPort} and adopting it as home (will re-home next update).`);
            appendEvent('update-ok', `${localVersion} -> ${argVersion} (home-rebind deferred; filtering on ${scaffoldPort})`);
            clearFailedVersion();
            pruneOldBackups(MAX_BACKUPS_TO_KEEP);
            return;
        }

        // --- Cutover back to the home port (both live → gap-free), retire the
        // scaffold, and only NOW record the new version. ---
        setRegistryProxyOn(homePort);
        killListenerOnPort(scaffoldPort);
        writeFileInPlace(VERSION_PATH, argVersion); // hub authoritative; home cutover confirmed
        log(`Update to ${argVersion} successful and healthy — back home on ${homePort}, scaffold retired.`);
        appendEvent('update-ok', `${localVersion} -> ${argVersion}`);
        clearFailedVersion(); // success → drop any stale failed-version marker
        pruneOldBackups(MAX_BACKUPS_TO_KEEP);
    } catch (e) {
        appendEvent('update-failed', `${argVersion}: ${describeError(e)}`);
        if (!swapStarted) {
            // Failure BEFORE the install was touched (download / checksum / extract to
            // the temp dir). The OLD proxy was never stopped — it is still filtering on
            // the home port (blue-green touches nothing until the copy). Do NOT tear it
            // down for a transient infra blip (e.g. Supabase/CDN hiccup); that would
            // drop a healthy machine for nothing. No cooldown marker either — the
            // version is not at fault.
            log(`Update aborted before touching the install (no rollback needed): ${describeError(e)}`);
        } else {
            // A throw somewhere in the cutover. Fail-open FIRST (golden rule), then
            // big-hammer recover: stop BOTH proxies (StopWatcherProcesses kills every
            // proxy-server.js — killing the home and any scaffold instance is correct
            // here), restore the old files, and hand the proxy back to the watchdog.
            log(`Update failed mid-cutover, rolling back: ${describeError(e)}`);
            try {
                flipToNormalInternet();
                stopProxyAndWatchdog();
                restoreBackup(backupDir);
                writeFileInPlace(VERSION_PATH, localVersion);
                startProxyAndWatchdog();
            } catch (rollbackErr) {
                log(`Rollback itself failed: ${rollbackErr.message}. Watchdog remains responsible for fail-open safety.`);
            }
        }
    } finally {
        // Cleared only now — the proxy is healthy again (or rollback restored it /
        // left it fail-open). Dropping the flag lets the next watchdog cycle resume
        // normal maintenance.
        try { fs.unlinkSync(UPDATING_FLAG_PATH); } catch (e) {}
        // Zero-zombie guarantee: retire any scaffold-port proxy still lingering
        // (scoped to a non-home pool port, our proxy only), so nothing accumulates
        // between updates. Reads the current home from proxy-port.txt, so if a
        // home-rebind-deferred degrade adopted the scaffold as home, that live proxy
        // is skipped.
        try { sweepScaffoldOrphans(readChosenPort()); } catch (e) {}
        try { fs.rmSync(UPDATE_DIR, { recursive: true, force: true }); } catch (e) {}
        releaseLock();
    }
}

// A prior investigation found this process dying silently mid-update with
// no JS error anywhere and a non-standard exit code (-1, not the usual
// uncaught-exception code of 1) — consistent with something that never
// reaches a normal catch block: an unhandled 'error' event, a native crash,
// or the process being killed by something external (antivirus real-time
// protection is a real candidate, since the temp zip/extract dirs below
// live in %TEMP%, outside the Defender exclusion InstallWatcher.bat adds
// for the WatcherBrain folder itself). These handlers exist purely to make
// sure that if it happens again, update.log has SOMETHING rather than
// nothing to diagnose from.
process.on('uncaughtException', (e) => {
    log(`FATAL uncaughtException: ${e && e.stack ? e.stack : e}`);
    // Golden rule on a fatal mid-cutover death: best-effort fail-open so we never
    // leave Windows pointing at a proxy we were about to move or kill. (A power loss
    // can't run this — that residual micro-window is documented in ADR 0001.)
    try { flipToNormalInternet(); } catch (_) {}
    process.exit(1);
});
process.on('unhandledRejection', (e) => {
    log(`FATAL unhandledRejection: ${e && e.stack ? e.stack : e}`);
    try { flipToNormalInternet(); } catch (_) {}
    process.exit(1);
});
process.on('exit', (code) => {
    log(`Process exiting with code ${code}`);
});

if (require.main === module) {
    main();
}

module.exports = { main };
