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
const os = require('os');
const { execFileSync } = require('child_process');

const { BRAIN_DIR, getText, downloadFile } = require('./hub-client');

const ROOT_DIR = path.join(BRAIN_DIR, '..');
const VERSION_PATH = path.join(ROOT_DIR, 'VERSION');
const UPDATE_LOG_PATH = path.join(BRAIN_DIR, 'update.log');

const REPO_RAW_VERSION_URL = 'https://raw.githubusercontent.com/FelixBC/watcher-proxy/main/VERSION';
const REPO_ZIP_URL = 'https://github.com/FelixBC/watcher-proxy/archive/refs/heads/main.zip';

// Never overwritten by an update: machine identity/secrets, this machine's
// own local whitelist extras, and anything log/state-like that isn't code.
const PROTECTED_RELATIVE_PATHS = [
    'whitelist.txt',
    'WatcherBrain/node',
    'WatcherBrain/HubConfig.json',
    'WatcherBrain/hub-credential.json',
    'WatcherBrain/unplugged.flag',
    'WatcherBrain/whitelist-version.txt',
    'WatcherBrain/poll-log-cursor.txt',
    'WatcherBrain/blocked-requests.log',
    'WatcherBrain/update.log',
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
            fs.copyFileSync(srcPath, destPath);
        }
    }
}

// stdio left as default (piped) rather than 'ignore' on every call below,
// deliberately: an earlier version used 'ignore' throughout and a real
// failure on a real VM came back as a totally empty error message,
// impossible to diagnose. Piped stdio means a thrown error carries
// e.stderr/e.stdout, which main()'s catch block now logs.

// execFileSync with argv arrays throughout this file, deliberately, NOT
// execSync with a concatenated string. Confirmed by hand on a real VM: the
// string form goes through cmd.exe's own shell parsing before powershell.exe
// ever sees it, and a command with this much nested quoting (single quotes
// for the registry path inside a double-quoted -Command block) came back
// with status 1 and completely empty stdout/stderr - cmd.exe mangled it
// before PowerShell could run at all. The array form bypasses shell string
// parsing entirely; the same command succeeded immediately once switched.

function flipToNormalInternet() {
    // GOLDEN RULE — see file header. Done before anything else touches the
    // proxy process, mirroring WatchdogLoop.ps1's unplug ordering exactly.
    execFileSync('powershell.exe', [
        '-NoProfile', '-NonInteractive', '-Command',
        "Set-ItemProperty -Path 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings' -Name ProxyEnable -Value 0 -Type DWord -ErrorAction SilentlyContinue; " +
        "Remove-ItemProperty -Path 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings' -Name ProxyServer -ErrorAction SilentlyContinue"
    ]);
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
        if (checkTcpOpenSync('127.0.0.1', 8080, 2000)) return true;
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

async function main() {
    const localVersion = fs.existsSync(VERSION_PATH)
        ? fs.readFileSync(VERSION_PATH, 'utf-8').trim()
        : '0.0.0';

    let remoteVersion;
    try {
        remoteVersion = (await getText(REPO_RAW_VERSION_URL, 10000)).trim();
    } catch (e) {
        log(`Update check failed (no local changes made): ${describeError(e)}`);
        return;
    }

    if (remoteVersion === localVersion) {
        return; // nothing to do
    }

    log(`Update available: ${localVersion} -> ${remoteVersion}`);

    const backupDir = backupCurrent(localVersion);
    log(`Backed up current install to ${backupDir}`);

    const tempZip = path.join(os.tmpdir(), `watcher-proxy-update-${Date.now()}.zip`);
    const tempExtract = path.join(os.tmpdir(), `watcher-proxy-update-extract-${Date.now()}`);

    try {
        await downloadFile(REPO_ZIP_URL, tempZip, 60000);

        // GOLDEN RULE: normal internet before the proxy is touched.
        flipToNormalInternet();
        stopProxyAndWatchdog();

        fs.mkdirSync(tempExtract, { recursive: true });
        execFileSync('powershell.exe', [
            '-NoProfile', '-NonInteractive', '-Command',
            `Expand-Archive -Path '${tempZip}' -DestinationPath '${tempExtract}' -Force`
        ]);

        const extractedRoot = fs
            .readdirSync(tempExtract, { withFileTypes: true })
            .find((e) => e.isDirectory());
        if (!extractedRoot) throw new Error('update archive had no root folder');

        copyTree(path.join(tempExtract, extractedRoot.name), ROOT_DIR, '');
        log('New files copied in.');

        startProxyAndWatchdog();

        const healthy = await waitForHealthy(5, 3000);
        if (!healthy) {
            log('Post-update health check FAILED — rolling back.');
            stopProxyAndWatchdog();
            restoreBackup(backupDir);
            startProxyAndWatchdog();
            const rolledBackHealthy = await waitForHealthy(5, 3000);
            log(
                rolledBackHealthy
                    ? 'Rollback successful, previous version restored and healthy.'
                    : 'Rollback did not come up healthy either — watchdog will keep retrying; internet stays unfiltered until it does (fail-open holds regardless).'
            );
            return;
        }

        log(`Update to ${remoteVersion} successful and healthy.`);
    } catch (e) {
        log(`Update failed with an error, attempting rollback: ${describeError(e)}`);
        try {
            stopProxyAndWatchdog();
            restoreBackup(backupDir);
            startProxyAndWatchdog();
        } catch (rollbackErr) {
            log(`Rollback itself failed: ${rollbackErr.message}. Watchdog remains responsible for fail-open safety.`);
        }
    } finally {
        try { fs.unlinkSync(tempZip); } catch (e) {}
        try { fs.rmSync(tempExtract, { recursive: true, force: true }); } catch (e) {}
    }
}

if (require.main === module) {
    main();
}

module.exports = { main };
