// Local master-code crypto for the Watcher agent. Uses ONLY node:crypto
// (scrypt) — no external dependencies, nothing to install.
//
// The master code is one shared secret Nelson controls. It is captured ONCE at
// install: sent in plaintext to the hub for enrollment (register-with-hub.js),
// then a salted scrypt hash of it is stored on the device as
// WatcherBrain/uninstall-code.hash so BackToNormal.bat can verify an uninstall
// attempt OFFLINE. The plaintext is NEVER persisted on the device — a banca
// worker who opens the folder finds only a useless salt+hash.
//
// CLI (the .bat files shell out to node; they can't call JS directly):
//   node agent-code-crypto.js store  <plainFile> <hashFile>
//       Read the plaintext code from <plainFile>, write {"salt","hash"} JSON to
//       <hashFile>, then DELETE <plainFile>. Exit 0 on success, 1 on failure.
//   node agent-code-crypto.js verify <hashFile>
//       Read the code from the WATCHER_UNINSTALL_CODE env var (kept OFF the
//       command line so it never shows up in the process list / tasklist) and
//       compare it against <hashFile>. Exit 0 on match; exit 1 on mismatch OR on
//       ANY problem — missing/corrupt hash file, missing env var — i.e. the
//       caller treats a non-zero exit as "deny" and this FAILS CLOSED.
'use strict';

const fs = require('fs');
const crypto = require('crypto');

// 16-byte random salt, 64-byte derived key. N/r/p keep Node's built-in scrypt
// defaults (16384/8/1) — strong and dependency-free.
const SALT_BYTES = 16;
const KEY_BYTES = 64;
const HEX_RE = /^[0-9a-fA-F]+$/;

// Returns { salt, hash } as lowercase hex strings. A fresh random salt on every
// call means the same code hashes differently on every machine.
function hashCode(code) {
    const salt = crypto.randomBytes(SALT_BYTES).toString('hex');
    const hash = crypto.scryptSync(String(code), salt, KEY_BYTES).toString('hex');
    return { salt, hash };
}

// Constant-time comparison via crypto.timingSafeEqual. Any malformed input
// (missing salt/hash, non-hex, odd/zero length) returns false rather than
// throwing, so callers can safely treat "can't verify" as "deny".
function verifyCode(code, salt, hash) {
    if (typeof code !== 'string' || typeof salt !== 'string' || typeof hash !== 'string') return false;
    if (!HEX_RE.test(salt) || !HEX_RE.test(hash)) return false;
    if (hash.length === 0 || hash.length % 2 !== 0) return false;
    const expected = Buffer.from(hash, 'hex');
    if (expected.length === 0) return false;
    let actual;
    try {
        actual = crypto.scryptSync(code, salt, expected.length);
    } catch (e) {
        return false;
    }
    if (actual.length !== expected.length) return false;
    return crypto.timingSafeEqual(actual, expected);
}

function readTrimmedFile(filePath) {
    // Strip a UTF-8 BOM (PowerShell's Set-Content can add one) and surrounding
    // whitespace so the stored hash is of the exact same string the user typed.
    return fs.readFileSync(filePath, 'utf-8').replace(/^﻿/, '').trim();
}

function cliStore(plainFile, hashFile) {
    if (!plainFile || !hashFile) {
        console.error('usage: agent-code-crypto.js store <plainFile> <hashFile>');
        return 1;
    }
    let code;
    try {
        code = readTrimmedFile(plainFile);
    } catch (e) {
        console.error('store: cannot read plaintext file:', e.message);
        return 1;
    }
    if (!code) {
        console.error('store: plaintext code is empty');
        return 1;
    }
    try {
        const { salt, hash } = hashCode(code);
        fs.writeFileSync(hashFile, JSON.stringify({ salt, hash }), 'utf-8');
    } catch (e) {
        console.error('store: cannot write hash file:', e.message);
        return 1;
    }
    // Scrub the plaintext no matter what — it must never persist. Best-effort:
    // the installer's .bat also deletes it as belt-and-suspenders.
    try { fs.unlinkSync(plainFile); } catch (e) { /* .bat will clean up */ }
    return 0;
}

function cliVerify(hashFile) {
    // FAIL CLOSED everywhere: any problem -> return 1 -> the .bat denies uninstall
    // and leaves the machine fully intact (golden rule).
    if (!hashFile) return 1;
    const code = (process.env.WATCHER_UNINSTALL_CODE || '').trim();
    if (code.length === 0) return 1;
    let parsed;
    try {
        parsed = JSON.parse(fs.readFileSync(hashFile, 'utf-8'));
    } catch (e) {
        return 1; // missing or corrupt hash file
    }
    if (!parsed || typeof parsed.salt !== 'string' || typeof parsed.hash !== 'string') return 1;
    return verifyCode(code, parsed.salt, parsed.hash) ? 0 : 1;
}

if (require.main === module) {
    const [, , cmd, arg1, arg2] = process.argv;
    let rc = 1;
    if (cmd === 'store') {
        rc = cliStore(arg1, arg2);
    } else if (cmd === 'verify') {
        rc = cliVerify(arg1);
    } else {
        console.error('usage: agent-code-crypto.js <store|verify> ...');
    }
    process.exit(rc);
}

module.exports = { hashCode, verifyCode };
