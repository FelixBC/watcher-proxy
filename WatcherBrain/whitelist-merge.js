// Merges the hub's shared whitelist into the local whitelist.txt while
// preserving whatever this specific machine has added locally (plan 0001,
// AC2 — bulk push is additive-only w.r.t. per-machine extras).
//
// whitelist.txt is split into two regions:
//   1. a managed block (between the two markers below) — fully owned by the
//      hub; overwritten wholesale on every push.
//   2. everything else — this machine's own local additions, left alone by
//      every push and reported back to the hub each poll so Nelson can see
//      them (read-only in v1, per plan 0001 non-goals).
//
// If a whitelist.txt has no markers yet (fresh install, or a hand-edited
// legacy file), its entire existing content is treated as local extras the
// first time, and the managed block is inserted above it — no entries are
// lost in the migration.
'use strict';

const fs = require('fs');

const MARKER_START = '# ==WATCHER-FLEET-MANAGED-START== (pushed from the dashboard — do not hand-edit this block)';
const MARKER_END = '# ==WATCHER-FLEET-MANAGED-END==';

function parse(content) {
    const lines = content.split(/\r?\n/);
    const startIdx = lines.indexOf(MARKER_START);
    const endIdx = lines.indexOf(MARKER_END);

    if (startIdx === -1 || endIdx === -1 || endIdx < startIdx) {
        // No managed block yet: everything currently in the file is a local extra.
        return { managedEntries: [], extraLines: lines };
    }

    const managedEntries = lines
        .slice(startIdx + 1, endIdx)
        .map((l) => l.trim())
        .filter((l) => l.length > 0);

    const extraLines = [...lines.slice(0, startIdx), ...lines.slice(endIdx + 1)];
    return { managedEntries, extraLines };
}

function render(managedEntries, extraLines) {
    const block = [MARKER_START, ...managedEntries, MARKER_END];
    const extras = extraLines.join('\n').replace(/^\n+/, '');
    return `${block.join('\n')}\n\n${extras}`.replace(/\n{3,}/g, '\n\n').trimEnd() + '\n';
}

// Local extras reported to the hub: non-empty, non-comment lines only.
function extractDomains(extraLines) {
    return extraLines
        .map((l) => l.split('#')[0].trim())
        .filter((l) => l.length > 0);
}

function readCurrent(whitelistPath) {
    if (!fs.existsSync(whitelistPath)) return { managedEntries: [], extraLines: [] };
    return parse(fs.readFileSync(whitelistPath, 'utf-8'));
}

// Write `content` to an EXISTING file in place (open r+ → truncate → write)
// instead of fs.writeFileSync. On Windows, writeFileSync opens with CREATE_ALWAYS,
// which FAILS with EPERM when the target carries the Hidden+System attributes that
// the install's disguise sets on whitelist.txt — so every poll that tried to apply
// a pushed whitelist died with "EPERM: operation not permitted, open ...whitelist.txt"
// and the machine never synced with the hub. Opening the existing file r+ preserves
// those attributes and avoids the EPERM. Falls back to writeFileSync only when the
// file does not exist yet (a fresh file has nothing to preserve).
function writeInPlace(filePath, content) {
    if (!fs.existsSync(filePath)) {
        fs.writeFileSync(filePath, content, 'utf-8');
        return;
    }
    const buf = Buffer.from(content, 'utf-8');
    const fd = fs.openSync(filePath, 'r+');
    try {
        fs.ftruncateSync(fd, 0);
        fs.writeSync(fd, buf, 0, buf.length, 0);
    } finally {
        fs.closeSync(fd);
    }
}

function applyPushedWhitelist(whitelistPath, newManagedEntries) {
    const { extraLines } = readCurrent(whitelistPath);
    writeInPlace(whitelistPath, render(newManagedEntries, extraLines));
}

function getReportableExtras(whitelistPath) {
    const { extraLines } = readCurrent(whitelistPath);
    return extractDomains(extraLines);
}

module.exports = { applyPushedWhitelist, getReportableExtras, parse, render };
