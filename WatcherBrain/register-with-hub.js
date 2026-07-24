// Runs once, at install time: exchanges the plaintext MASTER CODE (captured by
// AskIdentity.ps1 into a transient, Admin/SYSTEM-only file whose path arrives in
// WATCHER_MASTER_CODE_FILE) for a unique per-machine credential. HubConfig.json
// now supplies ONLY the HubUrl;
// the enrollment secret is gone — the hub validates the master code by scrypt
// hash-compare instead.
//
// Enrollment is synchronous and one-shot: the plaintext is used here exactly
// once, then InstallWatcher.bat Step 7 turns it into a salted uninstall hash and
// deletes it. Because the plaintext is never persisted, this can NOT be retried
// later from poll-hub.js (poll simply no-ops when there is no credential). If
// the hub is unreachable now, this fails cleanly with no credential written —
// no half-state, and the golden rule is untouched (nothing here arms internet).
// Safe to call repeatedly — no-ops if hub-credential.json already exists.
'use strict';

const os = require('os');
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { readHubConfig, readCredential, writeCredential, postJson } = require('./hub-client');

// Optional friendly name + zone chosen at install (popup writes these next to
// the install root, one level up from WatcherBrain). Blank/missing = fall back
// to the Windows hostname on the dashboard side.
function readTrimmedFile(filePath) {
    try {
        if (!fs.existsSync(filePath)) return null;
        const v = fs.readFileSync(filePath, 'utf-8').replace(/^﻿/, '').trim();
        return v.length > 0 ? v : null;
    } catch (e) {
        return null;
    }
}

// Stable per-PC fingerprint so a reinstall re-claims this machine's existing
// dashboard row instead of creating a duplicate ghost. Windows MachineGuid
// lives at HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid and survives
// reinstalling Watcher (it's tied to the Windows install/hardware, not to us).
// Returns null on any failure - the hub then falls back to old always-insert
// behavior, so registration still works, just without de-duplication.
function getHardwareId() {
    try {
        const out = execFileSync(
            'reg.exe',
            ['query', 'HKLM\\SOFTWARE\\Microsoft\\Cryptography', '/v', 'MachineGuid'],
            { encoding: 'utf-8', timeout: 10000 }
        );
        // Output line looks like: "    MachineGuid    REG_SZ    <guid>"
        const m = out.match(/MachineGuid\s+REG_SZ\s+([0-9a-fA-F-]{36})/);
        return m ? m[1].toLowerCase() : null;
    } catch (e) {
        return null;
    }
}

// Single-word outcome for InstallWatcher.bat / WinConfigWizard.ps1 to read after
// this process exits (Step 7 there redirects our own stdout/stderr to nul, so this
// file - not console text - is the one reliable, structured signal of WHY
// enrollment did or didn't happen). Written on every run, success or failure, so a
// stale reason from a previous attempt is never read as this run's outcome.
// Non-secret, per-machine state - see .gitignore.
const REGISTER_STATUS_PATH = path.join(__dirname, 'register-status.txt');

function writeRegisterStatus(reason) {
    try {
        fs.writeFileSync(REGISTER_STATUS_PATH, `${reason}\n`, 'utf-8');
    } catch (e) {
        // Best-effort only - never let status bookkeeping block the real install.
    }
}

// Classifies a postJson() rejection by the hub's actual HTTP status (attached by
// hub-client.js) instead of the raw error text, so the wizard can show the RIGHT
// distinct message instead of lumping every registration failure into one generic
// "reintentar" screen. Mirrors src/app/api/agent/register/route.ts's contract:
// 401 = bad master code, 409 = this hardware_id already holds a credential
// (anti-hijack - see route.ts's H2 comment), 429 = rate limited.
function classifyRegisterError(err) {
    const status = err && err.statusCode;
    if (status === 401) return 'bad_code';
    if (status === 409) return 'already_enrolled';
    if (status === 429) return 'rate_limited';
    if (status === 400) return 'invalid_request';
    if (typeof status === 'number' && status >= 500) return 'server_error';
    return 'network_error';
}

async function registerIfNeeded() {
    const existing = readCredential();
    if (existing) {
        writeRegisterStatus('ok');
        return existing;
    }

    const config = readHubConfig();
    // Plaintext master code captured at install. Used here ONCE and never persisted.
    // FIX 1: it no longer lives in the user-readable install tree - the elevated
    // installer writes it to an Admin/SYSTEM-only %TEMP% path and passes that path
    // via WATCHER_MASTER_CODE_FILE. Fall back to the old install-root location only
    // if the env var is absent (e.g. run standalone). Without a code there is
    // nothing to enroll with, so fail cleanly rather than register unauthenticated.
    const masterCodeFile = process.env.WATCHER_MASTER_CODE_FILE
        || path.join(__dirname, '..', 'master-code.plain');
    const masterCode = readTrimmedFile(masterCodeFile);
    if (!masterCode) {
        throw new Error(`no master code available for enrollment (${masterCodeFile} missing/empty)`);
    }
    const label = `${os.hostname()}`;
    const hardwareId = getHardwareId();
    const customName = readTrimmedFile(path.join(__dirname, '..', 'machine-name.txt'));
    const zone = readTrimmedFile(path.join(__dirname, '..', 'machine-zone.txt'));
    const bancaCode = readTrimmedFile(path.join(__dirname, '..', 'machine-code.txt'));

    // CROSS-REPO CONTRACT: POST {HubUrl}/api/agent/register with `master_code`
    // as PLAINTEXT. The hub validates it by scrypt hash-compare against its
    // stored hash before issuing a credential. Field names below are the contract.
    const result = await postJson(config.HubUrl, '/api/agent/register', {
        master_code: masterCode,
        label,
        hardware_id: hardwareId,
        custom_name: customName,
        zone,
        banca_code: bancaCode,
    });

    if (!result || !result.machine_id || !result.credential) {
        throw new Error('hub did not return a machine_id/credential on registration');
    }

    writeCredential(result.machine_id, result.credential);
    return { machine_id: result.machine_id, credential: result.credential };
}

if (require.main === module) {
    registerIfNeeded()
        .then((cred) => {
            writeRegisterStatus('ok');
            console.log(`Registered as machine ${cred.machine_id}`);
            process.exit(0);
        })
        .catch((err) => {
            writeRegisterStatus(classifyRegisterError(err));
            console.error('Registration failed:', err.message);
            process.exit(1);
        });
}

module.exports = { registerIfNeeded, classifyRegisterError };
