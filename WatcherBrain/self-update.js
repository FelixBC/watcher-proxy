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
const { execFileSync } = require('child_process');

const { BRAIN_DIR, downloadFile } = require('./hub-client');
const { appendEvent } = require('./event-log');
const { readChosenPort } = require('./proxy-port');

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
    'WatcherBrain/node',
    'WatcherBrain/HubConfig.json',
    'WatcherBrain/hub-credential.json',
    'WatcherBrain/uninstall-code.hash',
    'WatcherBrain/unplugged.flag',
    'WatcherBrain/updating.flag',
    'WatcherBrain/whitelist-version.txt',
    'WatcherBrain/proxy-port.txt',
    'WatcherBrain/poll-log-cursor.txt',
    'WatcherBrain/blocked-requests.log',
    'WatcherBrain/blocked-log-cleared-at.txt',
    'WatcherBrain/update.log',
    'WatcherBrain/_update',
    'WatcherBrain/machine-name.txt',
    'WatcherBrain/machine-zone.txt',
    'WatcherBrain/machine-code.txt',
    'WatcherBrain/location.json',
    'WatcherBrain/locate-pending.flag',
    'WatcherBrain/tamper-cursor.txt',
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
        fs.ftruncateSync(fd, 0);
        fs.writeSync(fd, data, 0, data.length, 0);
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
        fs.ftruncateSync(fd, 0);
        fs.writeSync(fd, buf, 0, buf.length, 0);
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

function checkTcpOpenSync(host, port, timeoutMs) {
    try {
        execFileSync('powershell.exe', [
            '-NoProfile', '-NonInteractive',
            '-File', path.join(BRAIN_DIR, 'CheckPort.ps1'),
            '-Port', String(port), '-TimeoutMs', String(timeoutMs)
        ], { stdio: 'ignore' });
        return true; // CheckPort.ps1 exits 0 when the port is open
    } catch (e) {
        return false;
    }
}

async function waitForHealthy(retries, delayMs) {
    for (let i = 0; i < retries; i++) {
        if (checkTcpOpenSync('127.0.0.1', readChosenPort(), 2000)) return true;
        await new Promise((r) => setTimeout(r, delayMs));
    }
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

    log(`Update available (from hub): ${localVersion} -> ${argVersion}`);

    // Fresh workspace inside the Defender-excluded folder.
    try { fs.rmSync(UPDATE_DIR, { recursive: true, force: true }); } catch (e) {}
    fs.mkdirSync(UPDATE_DIR, { recursive: true });
    const tempZip = path.join(UPDATE_DIR, 'package.zip');
    const tempExtract = path.join(UPDATE_DIR, 'extract');

    const backupDir = backupCurrent(localVersion);
    log(`Backed up current install to ${backupDir}`);

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

        // GOLDEN RULE: normal internet before the proxy is touched. Raise the
        // updating flag FIRST (before the flip) so every watchdog layer forces
        // normal internet and keeps its hands off the proxy for the whole swap.
        // Without it, the watchdog re-enables the proxy the moment it sees it
        // still listening, then we kill it for the copy and Windows is left
        // pointing at a dead proxy. Cleared in finally.
        fs.writeFileSync(UPDATING_FLAG_PATH, new Date().toISOString(), 'utf-8');
        flipToNormalInternet();
        stopProxyAndWatchdog();

        fs.mkdirSync(tempExtract, { recursive: true });
        execFileSync('powershell.exe', [
            '-NoProfile', '-NonInteractive', '-Command',
            `Expand-Archive -Path '${tempZip}' -DestinationPath '${tempExtract}' -Force`
        ]);

        // The hub bundle has files at the extract root (no wrapper folder).
        copyTree(tempExtract, ROOT_DIR, '');
        writeFileInPlace(VERSION_PATH, argVersion); // hub is authoritative
        log('New files copied in.');

        startProxyAndWatchdog();

        const healthy = await waitForHealthy(5, 3000);
        if (!healthy) {
            log('Post-update health check FAILED — rolling back.');
            stopProxyAndWatchdog();
            restoreBackup(backupDir);
            writeFileInPlace(VERSION_PATH, localVersion);
            startProxyAndWatchdog();
            const rolledBackHealthy = await waitForHealthy(5, 3000);
            log(
                rolledBackHealthy
                    ? 'Rollback successful, previous version restored and healthy.'
                    : 'Rollback did not come up healthy either — watchdog will keep retrying; internet stays unfiltered until it does (fail-open holds regardless).'
            );
            if (rolledBackHealthy) {
                pruneOldBackups(MAX_BACKUPS_TO_KEEP);
            }
            return;
        }

        log(`Update to ${argVersion} successful and healthy.`);
        appendEvent('update-ok', `${localVersion} -> ${argVersion}`);
        pruneOldBackups(MAX_BACKUPS_TO_KEEP);
    } catch (e) {
        appendEvent('update-failed', `${argVersion}: ${describeError(e)}`);
        log(`Update failed with an error, attempting rollback: ${describeError(e)}`);
        try {
            stopProxyAndWatchdog();
            restoreBackup(backupDir);
            writeFileInPlace(VERSION_PATH, localVersion);
            startProxyAndWatchdog();
        } catch (rollbackErr) {
            log(`Rollback itself failed: ${rollbackErr.message}. Watchdog remains responsible for fail-open safety.`);
        }
    } finally {
        // Cleared only now — the proxy is healthy again (or rollback restored
        // it / left it down = fail-open). Dropping the flag lets the next
        // watchdog cycle restore filtering (PE=1) if the proxy is up.
        try { fs.unlinkSync(UPDATING_FLAG_PATH); } catch (e) {}
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
    process.exit(1);
});
process.on('unhandledRejection', (e) => {
    log(`FATAL unhandledRejection: ${e && e.stack ? e.stack : e}`);
    process.exit(1);
});
process.on('exit', (code) => {
    log(`Process exiting with code ${code}`);
});

if (require.main === module) {
    main();
}

module.exports = { main };
