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

function applyPushedWhitelist(whitelistPath, newManagedEntries) {
    const { extraLines } = readCurrent(whitelistPath);
    fs.writeFileSync(whitelistPath, render(newManagedEntries, extraLines), 'utf-8');
}

function getReportableExtras(whitelistPath) {
    const { extraLines } = readCurrent(whitelistPath);
    return extractDomains(extraLines);
}

module.exports = { applyPushedWhitelist, getReportableExtras, parse, render };
