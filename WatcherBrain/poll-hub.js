// Runs every ~2 minutes via a scheduled task. Reports this machine's real
// state to the hub and applies whatever the hub says should be true
// (whitelist version, unplug/resume, available agent version).
//
// This script NEVER itself decides to take away internet or filtering — it
// only writes/clears small state files (whitelist.txt's managed block, the
// unplugged.flag). WatchdogLoop.ps1, which already owns "is the proxy
// healthy" every 5 seconds, is what actually acts on those files. That
// keeps exactly one piece of code responsible for the fail-open guarantee.
//
// If this whole script fails (hub unreachable, network down, anything) it
// exits non-zero and changes nothing locally — the machine keeps enforcing
// whatever whitelist/unplug state it already had. See plan 0001 AC6.
'use strict';

const fs = require('fs');
const path = require('path');
const net = require('net');
const { execSync } = require('child_process');

const { BRAIN_DIR, readHubConfig, readCredential, postJson, getText } = require('./hub-client');
const { applyPushedWhitelist, getReportableExtras } = require('./whitelist-merge');
const { appendEvent, readAll, pruneByTime } = require('./event-log');
const { readChosenPort } = require('./proxy-port');
const { maybeRunSelfTest } = require('./self-test');

const WHITELIST_PATH = path.join(BRAIN_DIR, '..', 'whitelist.txt');
const VERSION_PATH = path.join(BRAIN_DIR, '..', 'VERSION');
const WHITELIST_VERSION_PATH = path.join(BRAIN_DIR, 'whitelist-version.txt');
const UNPLUGGED_FLAG_PATH = path.join(BRAIN_DIR, 'unplugged.flag');
const BLOCKED_LOG_PATH = path.join(BRAIN_DIR, 'blocked-requests.log');
const LOG_CURSOR_PATH = path.join(BRAIN_DIR, 'poll-log-cursor.txt');
const VISITS_PATH = path.join(BRAIN_DIR, 'recent-visits.json');
const FIRST_VISIT_PATH = path.join(BRAIN_DIR, 'first-visit.json');
const NET_STATE_PATH = path.join(BRAIN_DIR, 'net-state.txt');
// Set when the hub asks for diagnostics; the NEXT poll uploads the event-log
// tail and clears it. Two-cycle handshake keeps it dead simple and pull-only.
const DIAG_PENDING_PATH = path.join(BRAIN_DIR, 'diag-pending.flag');
const LOCATION_PATH = path.join(BRAIN_DIR, 'location.json');
const LOCATE_PENDING_PATH = path.join(BRAIN_DIR, 'locate-pending.flag');
// Plan 0003 (Capa 4 staging gate): present = the hub marked this machine staging in a previous poll
// response (is_staging, cross-repo contract). ONLY then does the poll run the acceptance self-test
// suite — its cutover check spawns a real scratch proxy, so it must never run on a banca. Same
// set-on-response / act-next-poll two-cycle idiom as diag-pending.flag.
const STAGING_FLAG_PATH = path.join(BRAIN_DIR, 'staging.flag');
const TAMPER_CURSOR_PATH = path.join(BRAIN_DIR, 'tamper-cursor.txt');
const GET_LOCATION_PS = path.join(BRAIN_DIR, 'GetLocation.ps1');
const EVENTS_LOG_PATH = path.join(BRAIN_DIR, 'events.log');
// Plan 0010: the two SYSTEM-only hardening scripts this poll re-asserts ~hourly, and the
// marker whose mtime is the "when did we last do it" clock (no content is ever read).
const HARDEN_PRINTERS_PS = path.join(BRAIN_DIR, 'HardenPrinters.ps1');
const HARDEN_POWER_PS = path.join(BRAIN_DIR, 'HardenPower.ps1');
const HARDEN_MARKER_PATH = path.join(BRAIN_DIR, 'harden-last.txt');
// Plan 0011: SEPARATE from the throttle clock above. harden-last.txt is stamped BEFORE running
// (the ~hourly "when did we last try" throttle); this confirm marker is stamped ONLY when the
// guards actually verified clean this cycle (default-veto — see reassertHardeningIfDue). Its mtime
// is the "último OK" reported as body.guards_checked_at.
const HARDEN_OK_MARKER_PATH = path.join(BRAIN_DIR, 'guards-ok.txt');

// Failed-version cooldown: self-update.js writes update-failed.json {version,failedAt}
// when a genuine update fails its post-update health check and rolls back. We honor
// it here so a bad (or too-slow-to-health-check) version can't re-trigger self-update
// on every 2-min poll — the engine of the ~44-min unfiltered loop. A strictly newer
// version bypasses it (forward-only, matches isNewerVersion). See docs/plans/0006.
const UPDATE_FAILED_PATH = path.join(BRAIN_DIR, 'update-failed.json');
const FAILED_VERSION_COOLDOWN_MS = 60 * 60 * 1000; // 60 min
const LOCATION_MAX_AGE_MS = 55 * 60 * 1000; // sample ~hourly
const HARDEN_MAX_AGE_MS = 55 * 60 * 1000; // re-assert hardening ~hourly (see reassertHardeningIfDue)

// Spread hub hits across this window (anti-thundering-herd). Sized to the ~2-min
// poll cadence: 30s decorrelates machines that fired together without stretching
// the effective interval much, and stays well under the "stale" threshold.
const POLL_JITTER_MS = 30 * 1000;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function checkTcpOpen(host, port, timeoutMs) {
    return new Promise((resolve) => {
        const socket = new net.Socket();
        let done = false;
        const finish = (result) => {
            if (done) return;
            done = true;
            socket.destroy();
            resolve(result);
        };
        socket.setTimeout(timeoutMs);
        socket.once('connect', () => finish(true));
        socket.once('timeout', () => finish(false));
        socket.once('error', () => finish(false));
        socket.connect(port, host);
    });
}

async function checkInternetReachable() {
    // Deliberately independent of the hub and of the local proxy: raw HTTPS
    // GETs via Node's https module (see hub-client.js) never go through
    // 127.0.0.1:8080, so this measures the PC's actual internet, not "can it
    // reach the filter."
    //
    // Try several well-known hosts and count internet as UP if ANY responds.
    // A single reference host can be slow/blocked for a moment and would
    // otherwise flag a perfectly-online till as "sin internet" on the
    // dashboard. Requiring only one success makes the signal far less jumpy.
    const hosts = [
        'https://www.google.com/generate_204',
        'https://raw.githubusercontent.com/',
        'https://www.cloudflare.com/',
        'https://www.microsoft.com/',
    ];
    const attempts = hosts.map((url) =>
        getText(url, 6000).then(
            () => true,
            () => false
        )
    );
    const results = await Promise.all(attempts);
    return results.some((ok) => ok);
}

function readLocalWhitelistVersion() {
    if (!fs.existsSync(WHITELIST_VERSION_PATH)) return null;
    const raw = fs.readFileSync(WHITELIST_VERSION_PATH, 'utf-8').trim();
    const n = parseInt(raw, 10);
    return Number.isFinite(n) ? n : null;
}

function readLocalAgentVersion() {
    return fs.existsSync(VERSION_PATH) ? fs.readFileSync(VERSION_PATH, 'utf-8').trim() : '0.0.0';
}

// The Windows edition/version, reported on every poll (additive — an old hub
// ignores it) so the fleet knows its Win10-vs-Win11 + feature-version mix without
// a manual "scout" link. Read from the registry, whose VALUE NAMES (CurrentBuild,
// DisplayVersion) are language-independent — unlike `Get-ComputerInfo`/`systeminfo`
// text, which is localized (the terminals run Spanish Windows). Classify Win10 vs
// Win11 by BUILD (>= 22000 = Win11): ProductName is unreliable — it still reads
// "Windows 10" on Win11 (a known Microsoft quirk). Best-effort: any failure returns
// null and the poll just omits the field (never throws — this is the poll path).
function readOsVersion() {
    try {
        const out = execSync('reg query "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion"',
            { encoding: 'utf-8', timeout: 5000, windowsHide: true });
        const build = (out.match(/\bCurrentBuild\b\s+REG_SZ\s+(\d+)/) || [])[1];
        const disp = (out.match(/\bDisplayVersion\b\s+REG_SZ\s+(\S+)/) || [])[1];
        const b = parseInt(build, 10);
        if (!Number.isFinite(b)) return null;
        const name = b >= 22000 ? 'Windows 11' : 'Windows 10';
        return disp ? `${name} ${disp}` : `${name} (build ${b})`;
    } catch (e) {
        return null;
    }
}

// Parse a dotted numeric version ("1.0.16") into comparable parts. Non-numeric
// or missing segments become 0, so a malformed string degrades to 0.0.0 rather
// than throwing (this runs on the golden-rule path — never crash the poll).
function parseVersion(v) {
    return String(v || '').split('.').map((n) => {
        const p = parseInt(n, 10);
        return Number.isFinite(p) ? p : 0;
    });
}

// Forward-only OTA: true ONLY when `candidate` is a STRICTLY NEWER version than
// `current`. Self-update must never move a machine BACKWARD. The old check
// (`agent_version !== localAgentVersion`) treated any mismatch as an update, so
// a hub still advertising an OLDER build than a freshly-installed machine would
// silently DOWNGRADE it — reverting shipped fixes (e.g. a machine on 1.0.16
// getting pulled back to a 1.0.15 that still had the EADDRINUSE crash loop).
// Rollback is done by REPUBLISHING the good code under a higher number; bad
// forward updates are already caught by self-update.js's health-check + rollback.
function isNewerVersion(candidate, current) {
    const a = parseVersion(candidate);
    const b = parseVersion(current);
    const len = Math.max(a.length, b.length);
    for (let i = 0; i < len; i++) {
        const x = a[i] || 0;
        const y = b[i] || 0;
        if (x > y) return true;
        if (x < y) return false;
    }
    return false; // equal → not newer
}

function clearFailedVersion() {
    try { fs.unlinkSync(UPDATE_FAILED_PATH); } catch (e) {}
}

// True when `candidate` is the version that just failed its post-update health check
// and the cooldown hasn't elapsed — i.e. don't re-trigger self-update for it yet. A
// STRICTLY NEWER version bypasses the cooldown and clears the stale marker, so a
// republished fix (higher number) always deploys immediately. A malformed/absent
// marker degrades to "not cooling down" — never block updates on the golden-rule path.
function isUpdateCoolingDown(candidate) {
    let marker;
    try {
        marker = JSON.parse(fs.readFileSync(UPDATE_FAILED_PATH, 'utf-8'));
    } catch (e) {
        return false; // no marker / unreadable → free to update
    }
    if (!marker || !marker.version || !marker.failedAt) return false;
    // Newer than the failed version → forward-only bypass + clear the stale marker.
    if (isNewerVersion(candidate, marker.version)) {
        clearFailedVersion();
        return false;
    }
    // Cool down ONLY the EXACT version that failed. A DIFFERENT version that isn't
    // newer than the failed one — e.g. the hub repointed from a bad 2.0 back to a
    // known-good 1.5 that's still forward of this machine's 1.0 — never failed here,
    // so it must not be blocked by 2.0's cooldown.
    if (candidate !== marker.version) return false;
    // The version that failed, still within the cooldown window → skip this trigger.
    const failedAtMs = Date.parse(marker.failedAt);
    if (Number.isFinite(failedAtMs) && (Date.now() - failedAtMs) < FAILED_VERSION_COOLDOWN_MS) {
        return true;
    }
    return false; // cooldown elapsed → allow one more attempt (the failure may have been transient)
}

function isLocallyUnplugged() {
    return fs.existsSync(UNPLUGGED_FLAG_PATH);
}

// Only NEW blocked lines since the last successful poll, so we never resend
// the whole log. Cursor is a byte offset into blocked-requests.log.
function readNewBlockedLogLines() {
    if (!fs.existsSync(BLOCKED_LOG_PATH)) return [];
    const stat = fs.statSync(BLOCKED_LOG_PATH);
    let cursor = 0;
    if (fs.existsSync(LOG_CURSOR_PATH)) {
        cursor = parseInt(fs.readFileSync(LOG_CURSOR_PATH, 'utf-8').trim(), 10) || 0;
    }
    // Log was rotated/cleared (e.g. the existing weekly clear) since our last read.
    if (cursor > stat.size) cursor = 0;

    const fd = fs.openSync(BLOCKED_LOG_PATH, 'r');
    const length = stat.size - cursor;
    let text = '';
    if (length > 0) {
        const buf = Buffer.alloc(length);
        fs.readSync(fd, buf, 0, length, cursor);
        text = buf.toString('utf-8');
    }
    fs.closeSync(fd);
    fs.writeFileSync(LOG_CURSOR_PATH, String(stat.size), 'utf-8');

    const lineRe = /^\[(.+?)\] BLOCKED: (\S+)/;
    return text
        .split(/\r?\n/)
        .map((line) => {
            const m = line.match(lineRe);
            if (!m) return null;
            return { occurred_at: m[1], blocked_url: m[2] };
        })
        .filter(Boolean);
}

// Last few allowed hosts the proxy recorded (bounded to 3 on the writer side).
function readRecentVisits() {
    try {
        if (!fs.existsSync(VISITS_PATH)) return [];
        const parsed = JSON.parse(fs.readFileSync(VISITS_PATH, 'utf-8'));
        if (!Array.isArray(parsed)) return [];
        return parsed
            .filter((v) => v && typeof v.host === 'string' && typeof v.at === 'string')
            .slice(0, 25);
    } catch (e) {
        return [];
    }
}

// Record only CHANGES in the machine's internet reachability, and interpret
// them for later auditing: internet gone while the proxy is UP means the
// machine/ISP lost connectivity — NOT the Watcher. This is the line that lets
// a reader tell the two apart.
function logInternetTransition(reachable, proxyRunning) {
    try {
        const prev = fs.existsSync(NET_STATE_PATH) ? fs.readFileSync(NET_STATE_PATH, 'utf-8').trim() : '';
        const now = reachable ? 'up' : 'down';
        if (prev !== now) {
            fs.writeFileSync(NET_STATE_PATH, now, 'utf-8');
            if (!reachable) {
                appendEvent('internet-lost', proxyRunning
                    ? 'proxy OK, sin salida a internet — ISP/maquina, no el Watcher'
                    : 'sin internet y proxy abajo');
            } else if (prev) {
                appendEvent('internet-back', 'salida a internet restablecida');
            }
        }
    } catch (e) { /* best effort */ }
}

// Refresh location.json by running GetLocation.ps1, but only when it's stale
// (~hourly) or forced (a "locate now" request). Synchronous + time-boxed; any
// failure is swallowed so a poll never hangs or breaks on location.
function refreshLocationIfDue(force) {
    try {
        let due = force;
        if (!due) {
            const stat = fs.existsSync(LOCATION_PATH) ? fs.statSync(LOCATION_PATH) : null;
            due = !stat || (Date.now() - stat.mtimeMs > LOCATION_MAX_AGE_MS);
        }
        if (!due) return;
        const out = require('child_process').execFileSync(
            'powershell',
            ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', GET_LOCATION_PS],
            { timeout: 15000, encoding: 'utf-8' }
        );
        const parsed = JSON.parse(out.trim());
        if (parsed && typeof parsed.lat === 'number' && typeof parsed.lng === 'number') {
            fs.writeFileSync(
                LOCATION_PATH,
                JSON.stringify({ lat: parsed.lat, lng: parsed.lng, acc: parsed.acc ?? null, at: new Date().toISOString() }),
                'utf-8'
            );
        }
    } catch (e) {
        /* no fix this cycle — leave the last one (if any) in place */
    }
}

// Re-assert the two SYSTEM-only hardening scripts (printer Keep=OFF, power/radio)
// ~hourly. Plan 0010.
//
// WHY THIS LIVES IN THE POLL: both were only ever re-applied at install and by the
// "WinConfig Cleanup At Logon" task. But a banca is routinely left ON for DAYS —
// hibernated, or just locked, frequently not even that — and an `onlogon` trigger does
// NOT fire on resume-from-hibernate or on unlock: Windows RESTORES the existing session
// instead of creating one. So on the machines that behave most normally, the logon task
// can go a week without running, and anything that flips Keep=ON or re-enables Wi-Fi
// power saving mid-session (a driver install, a Windows update touching print drivers,
// someone with admin) stays flipped that entire time. "WinConfig Sync" is the ONLY
// always-running task with the rights to fix it: it runs as SYSTEM /rl highest and is
// independent of any logon, while the minute-frequency watchdog tasks run as
// BUILTIN\Users (LeastPrivilege) and cannot change printer or power config at all.
//
// GOLDEN RULE: both scripts are orthogonal to filtering — neither reads or writes
// ProxyEnable/ProxyServer, neither starts or stops the proxy — so this is safe to run in
// any state (filtering, unplugged, mid-update). Best-effort and individually time-boxed:
// a missing or hung script can never fail a poll, it just leaves the hardening for the
// next hour.
//
// EXIT-CODE CONTRACT (plan 0011): each guard now signals its own outcome via its exit code, so
// we can tell "verified clean" from "reverted a tamper" from "skipped" — execFileSync could not
// (it throws on ANY nonzero, collapsing 2 and 3 together), so we use spawnSync and read .status:
//   0 = verified-clean, 2 = harden-failed (a real revert was needed), 3 = skip / N-A.
// TWO SEPARATE MARKERS: harden-last.txt (the throttle) is stamped BEFORE running exactly as
// before; guards-ok.txt (the confirm) is stamped AFTER, and ONLY when EVERY first-class guard
// actually ran and returned exactly 0. guards_checked_at is a machine-WIDE "all watched settings
// confirmed clean" timestamp (cross-review, plan 0011), so a skip (3), a harden-fail (2), a missing
// script, or a timeout/signal/spawn error (.status null) ALL veto — an unevaluated guard is not a
// confirmation. A banca always has a printer + powercfg, so a skip is near-unreachable in the field;
// when it does happen, "no confirmado" is the honest state, not a fresh green.
function reassertHardeningIfDue() {
    try {
        const stat = fs.existsSync(HARDEN_MARKER_PATH) ? fs.statSync(HARDEN_MARKER_PATH) : null;
        if (stat && Date.now() - stat.mtimeMs <= HARDEN_MAX_AGE_MS) return;
        // Stamp the THROTTLE marker BEFORE running: if a script hangs to its timeout we pay that
        // cost once an hour, not on every 2-min poll. If the stamp itself fails we skip this cycle
        // rather than risk re-running every poll forever. (This is UNCHANGED from before.)
        if (!touchHardenMarker()) return;
        // Run BOTH guards (they re-force their settings regardless of the stamp), tracking whether
        // EVERY first-class guard actually ran and returned exactly 0 (verified-clean).
        let allVerifiedClean = true;
        for (const script of [HARDEN_PRINTERS_PS, HARDEN_POWER_PS]) {
            let status = null;
            try {
                if (fs.existsSync(script)) {
                    const res = require('child_process').spawnSync(
                        'powershell',
                        ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script],
                        { timeout: 25000, encoding: 'utf-8' }
                    );
                    // spawnSync never throws on a nonzero exit — .status is the exit code, or null on
                    // timeout/signal/spawn error. A missing script leaves status null (it never ran).
                    status = res.status;
                }
            } catch (e) {
                // spawnSync itself threw (rare) — non-verifying; still let the OTHER guard run.
                status = null;
            }
            // STRICT (cross-review): only an explicit 0 counts as confirmation. A skip (3), a
            // harden-fail (2), a missing script, a timeout/signal/spawn error (null), or any other
            // code means this guard was NOT confirmed clean this cycle → vetoes the machine-wide stamp.
            if (status !== 0) allVerifiedClean = false;
        }
        // Stamp the confirm marker ONLY when every first-class guard verified clean.
        if (allVerifiedClean) {
            touchHardenMarker(HARDEN_OK_MARKER_PATH);
        }
    } catch (e) {
        /* never break a poll over hardening */
    }
}

// Hidden+System-safe stamp (see proxy-port.js's writeChosenPort for the same idiom and
// the CLAUDE.md disguise note): the install marks agent files +h +s and a plain
// writeFileSync (CREATE_ALWAYS) EPERMs against those, which would silently freeze the
// clock at the first stamp and re-run the hardening on EVERY poll. Rewrite in place when
// the file already exists. Returns whether the stamp landed. Defaults to the throttle
// marker; pass HARDEN_OK_MARKER_PATH to stamp the "último OK" confirm marker (plan 0011).
function touchHardenMarker(markerPath = HARDEN_MARKER_PATH) {
    try {
        const data = new Date().toISOString();
        if (!fs.existsSync(markerPath)) {
            fs.writeFileSync(markerPath, data, 'utf-8');
            return true;
        }
        const buf = Buffer.from(data, 'utf-8');
        const fd = fs.openSync(markerPath, 'r+');
        try {
            fs.writeSync(fd, buf, 0, buf.length, 0);
            fs.ftruncateSync(fd, buf.length);
        } finally {
            fs.closeSync(fd);
        }
        return true;
    } catch (e) {
        return false;
    }
}

function readLocation() {
    try {
        if (!fs.existsSync(LOCATION_PATH)) return null;
        const v = JSON.parse(fs.readFileSync(LOCATION_PATH, 'utf-8'));
        if (v && typeof v.lat === 'number' && typeof v.lng === 'number') return v;
        return null;
    } catch (e) {
        return null;
    }
}

// Tamper events are lines in events.log tagged `tamper` (written by
// BackToNormal / watchdog before the agent might be killed). Return the ones
// newer than the cursor timestamp; the caller advances the cursor only AFTER a
// successful upload so nothing is lost if the poll fails.
//
// SETTING DIMENSION (plan 0011, additive + back-compat): a tamper detail may now lead with a
// structured prefix `setting=<slug> | <human detail>` (slugs are lowercase kebab: printer-keep,
// power, …). When present we split it out into event.setting and keep detail as just the human
// text; when absent (every pre-0011 line) event.setting is null and detail is unchanged.
function readNewTamperEvents() {
    try {
        if (!fs.existsSync(EVENTS_LOG_PATH)) return { events: [], maxTs: null };
        const sinceIso = fs.existsSync(TAMPER_CURSOR_PATH)
            ? fs.readFileSync(TAMPER_CURSOR_PATH, 'utf-8').trim()
            : '';
        const since = sinceIso ? Date.parse(sinceIso) : 0;
        const lines = fs.readFileSync(EVENTS_LOG_PATH, 'utf-8').split(/\r?\n/);
        const re = /^\[([^\]]+)\]\s*tamper\s*(?:\|\s*(.*))?$/i;
        // Optional leading `setting=<slug> | `: group 1 = slug, group 2 = the remaining human text.
        const settingRe = /^setting=([a-z0-9-]+)\s*\|\s*(.*)$/;
        const events = [];
        let maxTs = sinceIso || null;
        for (const line of lines) {
            const m = line.match(re);
            if (!m) continue;
            const ts = Date.parse(m[1]);
            if (Number.isNaN(ts) || (since && ts <= since)) continue;
            let detail = (m[2] || '').trim();
            let setting = null;
            const sm = detail.match(settingRe);
            if (sm) {
                setting = sm[1];
                detail = sm[2].trim();
            }
            events.push({ at: new Date(ts).toISOString(), kind: 'tamper', detail, setting });
            if (!maxTs || ts > Date.parse(maxTs)) maxTs = new Date(ts).toISOString();
        }
        return { events: events.slice(-20), maxTs };
    } catch (e) {
        return { events: [], maxTs: null };
    }
}

// The first allowed page of the day (written by the proxy). Sent as {host, at}.
function readFirstVisit() {
    try {
        if (!fs.existsSync(FIRST_VISIT_PATH)) return null;
        const v = JSON.parse(fs.readFileSync(FIRST_VISIT_PATH, 'utf-8'));
        if (v && typeof v.host === 'string' && typeof v.at === 'string') {
            const out = { host: v.host, at: v.at }; // 1ª con ruido
            if (typeof v.realHost === 'string' && typeof v.realAt === 'string') {
                out.realHost = v.realHost; // 1ª sin ruido
                out.realAt = v.realAt;
            }
            return out;
        }
        return null;
    } catch (e) {
        return null;
    }
}

function setUnpluggedFlag(resumeAtIso) {
    fs.writeFileSync(UNPLUGGED_FLAG_PATH, resumeAtIso || '', 'utf-8');
}

function clearUnpluggedFlag() {
    if (fs.existsSync(UNPLUGGED_FLAG_PATH)) fs.unlinkSync(UNPLUGGED_FLAG_PATH);
}

function triggerSelfUpdate(version, url, sha256) {
    const { spawn } = require('child_process');
    const child = spawn(
        process.execPath,
        [path.join(BRAIN_DIR, 'self-update.js'), version, url, sha256 || ''],
        { detached: true, stdio: 'ignore', cwd: BRAIN_DIR }
    );
    child.unref();
}

async function main() {
    const cred = readCredential();

    // Re-assert SYSTEM-only hardening (~hourly) — printer Keep=OFF + power/radio. This runs
    // ABOVE the not-enrolled guard BY DESIGN: it is a purely LOCAL safety property (SYSTEM
    // rewriting local printer/power config) that needs no credential, no hub, no network, so
    // it must NOT be coupled to fleet enrollment. A machine that failed to enroll (bad master
    // code, 409 anti-hijack on a reinstall, 429, or offline at install) still polls every 2
    // min and is EXACTLY the machine an operator can't see on the dashboard — so leaving its
    // printers unguarded is the worst case, not an acceptable one. Also stays above
    // readNewTamperEvents() below, so for an enrolled machine a retention attempt it reverts
    // is reported in THIS poll, not the next. See plan 0010.
    // KNOWN LIMIT: an install with NO HubConfig.json never creates the "WinConfig Sync" task,
    // so it has no periodic trigger here at all — plan 0010 §Límites (the shipped bundle
    // always includes HubConfig.json, so this is an edge/manual config, not a real banca).
    reassertHardeningIfDue();

    // Not enrolled (no credential on disk). We deliberately do NOT try to
    // re-register here: enrollment needs the plaintext master code, which is
    // captured ONCE at install and never persisted (only its scrypt hash is
    // kept, for uninstall). With no code to send, a re-register is impossible,
    // so the safe thing is to do NOTHING — make no local changes, never touch
    // the proxy/registry/whitelist. The machine keeps enforcing whatever state
    // it already had; the golden rule is untouched.
    if (!cred) {
        console.log('poll-hub: not enrolled (no credential); nothing to do.');
        return;
    }
    const config = readHubConfig();

    // Jitter: wait a random slice of a window BEFORE doing anything with the
    // hub, so machines whose 5-min timers accidentally lined up (a whole shop
    // powering on at 8am, everyone rebooting after an outage) don't all hit the
    // hub in the same second. Re-randomized every poll, so any accidental
    // alignment scatters on its own. Well under the "stale" threshold, so it
    // never risks a machine looking offline. State is read AFTER the wait, so
    // the report is fresh at send time.
    await sleep(Math.floor(Math.random() * POLL_JITTER_MS));

    const [internetReachable, proxyRunning] = await Promise.all([
        checkInternetReachable(),
        checkTcpOpen('127.0.0.1', readChosenPort(), 2000),
    ]);
    const unplugged = isLocallyUnplugged();
    // Filter is only meaningfully "active" if the proxy is up AND we're not
    // intentionally unplugged (matches WatchdogLoop.ps1's own logic).
    const filterActive = proxyRunning && !unplugged;

    // Audit breadcrumbs (local): internet reachability changes + time-based
    // pruning of the shared events.log so it never grows past its window.
    logInternetTransition(internetReachable, proxyRunning);
    pruneByTime();

    // Cross-repo contract (plan 0003): the RUNNING agent version, reported on every poll (additive — an
    // old hub ignores it). Read once here; the OTA check below reuses it.
    //
    // Cross-repo contract (plan 0011): two MORE additive poll fields ride along below —
    // `tamper_events[].setting` (per-event setting dimension: printer-keep, power, uninstall, …) and
    // top-level `body.guards_checked_at` (the hourly "último OK" stamp). Additive in BOTH directions:
    // an old hub simply ignores them, and a new hub tolerates their absence from an old agent (setting
    // → null/unknown; guards_checked_at → "never confirmed"). Neither ever breaks the insert.
    const localAgentVersion = readLocalAgentVersion();

    const body = {
        machine_id: cred.machine_id,
        credential: cred.credential,
        agent_version: localAgentVersion,
        internet_reachable: internetReachable,
        proxy_running: proxyRunning,
        filter_active: filterActive,
        whitelist_version: readLocalWhitelistVersion(),
        extras: getReportableExtras(WHITELIST_PATH),
        logs: readNewBlockedLogLines(),
        recent_visits: readRecentVisits(),
    };
    const osVersion = readOsVersion();
    if (osVersion) body.os_version = osVersion;
    const firstVisit = readFirstVisit();
    if (firstVisit) body.first_visit = firstVisit;

    // Plan 0011 (cross-repo contract, additive): the "último OK" stamp — the mtime of the confirm
    // marker that reassertHardeningIfDue() wrote the last time every applicable hardening guard
    // verified clean (default-veto; ~hourly cadence, NOT the 2-min poll). Only-set-when-present,
    // mirroring os_version/first_visit: absent means "never confirmed clean" (the panel shows that
    // as such), never a faked recent timestamp.
    const guardsCheckedAt = (() => {
        try {
            if (!fs.existsSync(HARDEN_OK_MARKER_PATH)) return null;
            // Read the ISO timestamp STORED IN THE FILE, not its mtime (cross-review): an OTA
            // rollback restores this file from backup, which rewrites the mtime and would fabricate
            // a fresh "último OK" even though no guard ran clean recently. The written content is the
            // honest confirmation time; touchHardenMarker writes an ISO string, so parse that.
            const raw = fs.readFileSync(HARDEN_OK_MARKER_PATH, 'utf-8').trim();
            const t = Date.parse(raw);
            return Number.isNaN(t) ? null : new Date(t).toISOString();
        } catch (e) {
            return null;
        }
    })();
    if (guardsCheckedAt) body.guards_checked_at = guardsCheckedAt;

    // Location: refresh ~hourly (or now, if the hub asked via locate_requested
    // last cycle), then attach the latest fix if we have one.
    const locateForced = fs.existsSync(LOCATE_PENDING_PATH);
    refreshLocationIfDue(locateForced);
    if (locateForced) { try { fs.unlinkSync(LOCATE_PENDING_PATH); } catch (e) {} }
    const location = readLocation();
    if (location) body.location = location;

    // Tamper events (uninstall attempt, printer retention attempt, etc.) since the last upload.
    // reassertHardeningIfDue() ran at the TOP of main() (above the not-enrolled guard); its
    // synchronous `tamper` write is therefore already on disk for this read. See plan 0010.
    // Each event now carries a `setting` dimension (plan 0011, additive — null for pre-0011 lines).
    const tamper = readNewTamperEvents();
    if (tamper.events.length > 0) body.tamper_events = tamper.events;

    // If the hub asked for diagnostics last time, attach the event-log tail now.
    const diagPending = fs.existsSync(DIAG_PENDING_PATH);
    if (diagPending) {
        // Send the whole recent trail (bounded) so an auditor sees the full
        // picture, not just the last few lines.
        body.diagnostics = readAll(60000) || '(sin eventos registrados)';
    }

    // Plan 0003 (Capa 4): ONLY a staging machine (staging.flag, set from a previous poll's is_staging)
    // runs/reports the acceptance self-test suite. Cached once per running version; maybeRunSelfTest
    // defers itself during updates/unplug and NEVER throws, so a broken suite can't take the poll loop
    // down with it. Cheap on every later staging poll (it just re-reads the cached result).
    if (fs.existsSync(STAGING_FLAG_PATH)) {
        const selftest = await maybeRunSelfTest(localAgentVersion);
        if (selftest) body.selftest = selftest;
    }

    const response = await postJson(config.HubUrl, '/api/agent/poll', body);

    // Diagnostics handshake: clear the flag once uploaded; set it when asked.
    if (diagPending) {
        try { fs.unlinkSync(DIAG_PENDING_PATH); } catch (e) {}
    }
    if (response.diag_requested) {
        try { fs.writeFileSync(DIAG_PENDING_PATH, '', 'utf-8'); } catch (e) {}
    }

    // Locate handshake: hub asks → force a fresh fix on the next poll.
    if (response.locate_requested) {
        try { fs.writeFileSync(LOCATE_PENDING_PATH, '', 'utf-8'); } catch (e) {}
    }
    // Staging handshake (plan 0003, cross-repo contract): the hub tells us whether this machine is
    // staging. Only EXPLICIT booleans change local state — an older hub that omits the field leaves
    // whatever we already knew untouched.
    if (response.is_staging === true) {
        try { fs.writeFileSync(STAGING_FLAG_PATH, '', 'utf-8'); } catch (e) {}
    } else if (response.is_staging === false) {
        try { if (fs.existsSync(STAGING_FLAG_PATH)) fs.unlinkSync(STAGING_FLAG_PATH); } catch (e) {}
    }
    // Tamper cursor advances ONLY after a successful post, so a failed poll
    // re-sends the events next time instead of dropping them.
    if (tamper.events.length > 0 && tamper.maxTs) {
        try { fs.writeFileSync(TAMPER_CURSOR_PATH, tamper.maxTs, 'utf-8'); } catch (e) {}
    }

    if (typeof response.whitelist_version === 'number' && response.whitelist_version !== body.whitelist_version) {
        applyPushedWhitelist(WHITELIST_PATH, response.whitelist_entries || []);
        fs.writeFileSync(WHITELIST_VERSION_PATH, String(response.whitelist_version), 'utf-8');
    }

    if (response.unplugged) {
        setUnpluggedFlag(response.unplug_resume_at || '');
    } else if (unplugged) {
        // Hub says we should be resumed and we're currently unplugged locally.
        clearUnpluggedFlag();
    }

    if (
        response.agent_version &&
        isNewerVersion(response.agent_version, localAgentVersion) &&
        response.agent_download_url
    ) {
        if (isUpdateCoolingDown(response.agent_version)) {
            // A recent update to this same version failed its health check — don't
            // re-fire it every 2-min poll. A newer version would have bypassed above.
            try { appendEvent('update-cooldown', `skipping ${response.agent_version} (recent failed attempt)`); } catch (e) {}
        } else {
            triggerSelfUpdate(response.agent_version, response.agent_download_url, response.agent_sha256);
        }
    }
}

main().catch((err) => {
    // Anything above failing (hub down, network down, bad response) simply
    // means "no update this cycle" — never touch local state on failure.
    // Record it (bounded) so "the machine went quiet" is diagnosable later.
    try { appendEvent('hub-unreachable', err && err.message); } catch (e) {}
    console.error('poll-hub failed (no local changes made):', err.message);
    process.exit(1);
});
