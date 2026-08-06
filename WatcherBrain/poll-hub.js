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
const { execSync, execFileSync } = require('child_process');

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
// Plan 0017: the Wi-Fi BSSID fingerprint — the automatic fallback location source
// deposited every cycle so the hub can (a) use it when Windows Location gives no
// fix and (b) accumulate it to propose the post's reference fingerprint.
const WIFI_FP_PATH = path.join(BRAIN_DIR, 'wifi-fingerprint.json');
// One line: the last location OUTCOME ('ok' or an err code). Only used to log a
// breadcrumb on TRANSITION so an hourly refresh doesn't spam events.log.
const LOCATION_HEALTH_PATH = path.join(BRAIN_DIR, 'location-health.txt');
const LOCATE_PENDING_PATH = path.join(BRAIN_DIR, 'locate-pending.flag');
// Plan 0003 (Capa 4 staging gate): present = the hub marked this machine staging in a previous poll
// response (is_staging, cross-repo contract). ONLY then does the poll run the acceptance self-test
// suite — its cutover check spawns a real scratch proxy, so it must never run on a banca. Same
// set-on-response / act-next-poll two-cycle idiom as diag-pending.flag.
const STAGING_FLAG_PATH = path.join(BRAIN_DIR, 'staging.flag');
const TAMPER_CURSOR_PATH = path.join(BRAIN_DIR, 'tamper-cursor.txt');
const GET_LOCATION_PS = path.join(BRAIN_DIR, 'GetLocation.ps1');
const GET_WIFI_FP_PS = path.join(BRAIN_DIR, 'GetWifiFingerprint.ps1'); // plan 0017
const EVENTS_LOG_PATH = path.join(BRAIN_DIR, 'events.log');
// Plan 0010: the two SYSTEM-only hardening scripts this poll re-asserts ~hourly, and the
// marker whose mtime is the "when did we last do it" clock (no content is ever read).
const HARDEN_PRINTERS_PS = path.join(BRAIN_DIR, 'HardenPrinters.ps1');
const HARDEN_POWER_PS = path.join(BRAIN_DIR, 'HardenPower.ps1');
const HARDEN_LOCATION_PS = path.join(BRAIN_DIR, 'HardenLocation.ps1');
const HARDEN_MARKER_PATH = path.join(BRAIN_DIR, 'harden-last.txt');
// Plan 0011: SEPARATE from the throttle clock above. harden-last.txt is stamped BEFORE running
// (the ~hourly "when did we last try" throttle); this confirm marker is stamped ONLY when the
// guards actually verified clean this cycle (default-veto — see reassertHardeningIfDue). Its mtime
// is the "último OK" reported as body.guards_checked_at.
const HARDEN_OK_MARKER_PATH = path.join(BRAIN_DIR, 'guards-ok.txt');
// Plan 0013: the print-signal harvest. HardenPrinters.ps1 turns the Windows print log ON;
// THIS file owns its cursor exclusively, exactly as it owns tamper-cursor.txt above.
// That ownership is not tidiness. If the guard (~55 min) wrote the anchor and the harvest
// (~2 min) read it, ~27 polls would run with the cursor absent — and "absent" taken as 0
// dumps the whole pre-existing log, days of old prints, into the hub the night this ships.
const PRINT_LOG_CHANNEL = 'Microsoft-Windows-PrintService/Operational';
const PRINT_CURSOR_PATH = path.join(BRAIN_DIR, 'print-cursor.txt');
// "We already reported the harvest as broken" — so a permanent failure costs ONE line in the
// shared events.log instead of 720 a day. Cleared as soon as a harvest works again.
const PRINT_FAIL_FLAG_PATH = path.join(BRAIN_DIR, 'print-harvest-failed.flag');
const PRINT_JOBS_MAX = 50;

// Failed-version cooldown: self-update.js writes update-failed.json {version,failedAt}
// when a genuine update fails its post-update health check and rolls back. We honor
// it here so a bad (or too-slow-to-health-check) version can't re-trigger self-update
// on every 2-min poll — the engine of the ~44-min unfiltered loop. A strictly newer
// version bypasses it (forward-only, matches isNewerVersion). See docs/plans/0006.
const UPDATE_FAILED_PATH = path.join(BRAIN_DIR, 'update-failed.json');
const FAILED_VERSION_COOLDOWN_MS = 60 * 60 * 1000; // 60 min
const LOCATION_MAX_AGE_MS = 55 * 60 * 1000; // sample ~hourly
const WIFI_FP_MAX_AGE_MS = 55 * 60 * 1000; // plan 0017: same ~hourly cadence as location
// Plan 0017: once a Windows fix is older than this it STOPS riding on the poll, so a
// stale coordinate (Location turned off → GetLocation fails → location.json keeps its
// last good fix) can't keep masking the Wi-Fi fallback forever. 2 h ≈ two refresh
// cycles: a normally-refreshing machine always attaches; one whose fixes have dried up
// for hours falls back to the fresh fingerprint. Mirrors the hub's fingerprint TTL.
const LOCATION_ATTACH_TTL_MS = 2 * 60 * 60 * 1000;
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

// Log a location OUTCOME to events.log, but only when it CHANGES — otherwise an
// hourly refresh would write ~24 identical lines a day. The last outcome is kept
// in a one-line marker so a transition (fix→denied, denied→fix, error code
// change) leaves exactly one breadcrumb. This is the trace that was missing: from
// 1.0.14 to 1.0.35 GetLocation.ps1 threw on EVERY machine and three nested
// swallows (the .ps1 `exit 0`, this catch, and "send no field") hid it, so a
// feature that never once worked looked healthy for two weeks.
function noteLocationOutcome(outcome) {
    try {
        let prev = null;
        if (fs.existsSync(LOCATION_HEALTH_PATH)) {
            prev = fs.readFileSync(LOCATION_HEALTH_PATH, 'utf-8').trim();
        }
        if (prev === outcome) return;
        // Rewrite-in-place if it already exists (may be +h +s): CREATE_ALWAYS would
        // EPERM on a Hidden+System file — same rule as the whitelist/self-update files.
        if (fs.existsSync(LOCATION_HEALTH_PATH)) {
            const fd = fs.openSync(LOCATION_HEALTH_PATH, 'r+');
            try { fs.ftruncateSync(fd); fs.writeSync(fd, outcome, 0, 'utf-8'); }
            finally { fs.closeSync(fd); }
        } else {
            fs.writeFileSync(LOCATION_HEALTH_PATH, outcome, 'utf-8');
        }
        appendEvent('location', outcome === 'ok' ? 'ubicacion obtenida' : ('ubicacion no disponible: ' + outcome));
    } catch (e) {
        /* best effort — a breadcrumb must never break a poll */
    }
}

// Refresh location.json by running GetLocation.ps1, but only when it's stale
// (~hourly) or forced (a "locate now" request). Synchronous + time-boxed. A fix
// overwrites location.json; a failure LEAVES the last good fix in place (so the
// map doesn't blink out on one bad cycle) and records WHY via noteLocationOutcome.
// GetLocation.ps1 now always prints one JSON line and exits 0 — either
// {lat,lng,acc} or {err,detail} — so a swallowed throw here means the process
// itself could not run (killed at the 15s timeout, powershell missing), which is
// its own distinct outcome, not a location denial.
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
        let parsed = null;
        try { parsed = JSON.parse(out.trim()); } catch (e) { /* handled as unparseable below */ }
        if (parsed && typeof parsed.lat === 'number' && typeof parsed.lng === 'number') {
            fs.writeFileSync(
                LOCATION_PATH,
                JSON.stringify({ lat: parsed.lat, lng: parsed.lng, acc: parsed.acc ?? null, at: new Date().toISOString() }),
                'utf-8'
            );
            noteLocationOutcome('ok');
        } else {
            noteLocationOutcome(parsed && parsed.err ? String(parsed.err) : 'unparseable');
        }
    } catch (e) {
        // The .ps1 could not run at all (timeout kill / powershell missing) — distinct
        // from a location denial, and the ONLY path that reaches this catch now.
        noteLocationOutcome('probe-failed');
    }
}

// Plan 0017: refresh wifi-fingerprint.json by running GetWifiFingerprint.ps1, on the
// SAME ~hourly cadence as location. Deposited EVERY cycle (not only when location is
// off) so the hub always has the current AP set — both to fall back on when there's
// no coordinate AND to accumulate into the post's reference fingerprint. A failed
// scan LEAVES the last-good fingerprint in place (one bad scan must not blank the
// fallback), exactly like refreshLocationIfDue. Best-effort: never affects the poll.
// GetWifiFingerprint.ps1 needs NO location permission, so this works headless even
// on a machine where Windows Location is denied.
function refreshWifiFingerprintIfDue(force) {
    try {
        let due = force;
        const exists = fs.existsSync(WIFI_FP_PATH);
        if (!due) {
            const stat = exists ? fs.statSync(WIFI_FP_PATH) : null;
            due = !stat || (Date.now() - stat.mtimeMs > WIFI_FP_MAX_AGE_MS);
        }
        if (!due) return;
        // Throttle BEFORE scanning (same discipline as reassertHardeningIfDue) so a FAILED
        // scan does NOT re-run the 15 s probe on every 2-min poll. If a cache exists we just
        // move its mtime (its last-good CONTENT + scan `at` are preserved; the hub's TTL
        // reads the content's `at`, not the mtime, so a stale fingerprint still ages out).
        // If NONE exists yet — the very first scan, which could keep failing — we write an
        // EMPTY placeholder: readWifiFingerprint returns null for it (never sent), but its
        // mtime now throttles the retry to ~hourly instead of every poll.
        try {
          if (exists) { const t = new Date(); fs.utimesSync(WIFI_FP_PATH, t, t); }
          else { fs.writeFileSync(WIFI_FP_PATH, JSON.stringify({ bssids: [], at: new Date().toISOString() }), 'utf-8'); }
        } catch (e) {}
        const out = require('child_process').execFileSync(
            'powershell',
            ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', GET_WIFI_FP_PS],
            { timeout: 15000, encoding: 'utf-8' }
        );
        let parsed = null;
        try { parsed = JSON.parse(out.trim()); } catch (e) { /* unparseable → keep last good */ }
        if (parsed && Array.isArray(parsed.bssids) && parsed.bssids.length > 0) {
            // Cap the set: a fingerprint needs the visible APs, not an unbounded list.
            const bssids = parsed.bssids.filter((b) => typeof b === 'string').slice(0, 40);
            fs.writeFileSync(
                WIFI_FP_PATH,
                JSON.stringify({ bssids, at: new Date().toISOString() }),
                'utf-8'
            );
        }
        // A no-wifi / no-aps / probe error result carries no bssids → leave the last
        // good fingerprint untouched.
    } catch (e) {
        /* best-effort — a scan failure must never affect the poll */
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
        for (const script of [HARDEN_PRINTERS_PS, HARDEN_POWER_PS, HARDEN_LOCATION_PS]) {
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

// Plan 0017: the latest Wi-Fi fingerprint, or null. Same shape discipline as
// readLocation — only return a well-formed non-empty set.
function readWifiFingerprint() {
    try {
        if (!fs.existsSync(WIFI_FP_PATH)) return null;
        const v = JSON.parse(fs.readFileSync(WIFI_FP_PATH, 'utf-8'));
        if (v && Array.isArray(v.bssids) && v.bssids.length > 0) return v;
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

// ---------------------------------------------------------------------------
// PRINT SIGNAL (plan 0013, cross-repo contract). Windows records every printed document as
// event 307 of Microsoft-Windows-PrintService/Operational — printer, document, pages, time.
// The channel ships DISABLED (the Windows default), which is why it held nothing;
// HardenPrinters.ps1 turns it on and re-asserts it, and this harvests what the hub hasn't seen.
//
// The three facts below were MEASURED on the test PC (2026-07-31), not assumed — the whole plan
// exists because the previous "print signal" was written from a comment nobody ever checked:
//   · `Get-WinEvent -FilterHashtable` does NOT accept EventRecordID, so a cursor filter has to be
//     XPath. wevtutil is also a native binary (~10-30ms) rather than a PowerShell start-up
//     (~300-700ms), and this runs every ~2 min on every banca.
//   · `/rd:false` returns OLDEST-first, and that matters more than it looks: newest-first with a
//     cap would hand us the 200 newest of a backlog, and moving the cursor past them would bury
//     the older ones FOREVER, with no error anywhere.
//   · `Pages printed` is 0 on the EPSON thermal for a ticket that physically came out. The unit
//     is therefore the EVENT — one 307 is one printed document — never the page count.
//
// What deliberately does NOT travel: the document name (Param2) and the user (Param3). A ticket
// name can carry a customer's data and this repo is public; printer + time + count already answer
// both questions that matter — was a human there, and did a copy go to another printer.
function wevtutilRun(args) {
    try {
        // spawnSync, not execFileSync: a nonzero exit here is information, not an exception.
        // 3s, not 10: the measured read is 10-30 ms, and on the STAGING machine up to four of these
        // stack on top of the poll jitter and the self-test's own cutover cycle, inside the task's
        // 5-minute ExecutionTimeLimit. A generous-looking ceiling was quietly eating that budget.
        const res = require('child_process').spawnSync('wevtutil.exe', args, {
            encoding: 'utf-8', windowsHide: true, timeout: 3000,
        });
        if (!res || res.status !== 0) return null;   // null = the command really failed
        return res.stdout || '';                     // '' = it ran and matched nothing
    } catch (e) {
        return null;
    }
}

// The health probe deliberately uses `gl`/`gli` and NOT the harvest query. An invalid XPath exits
// 0 with EMPTY output (measured), so a probe built on the same query would report "log fine, zero
// prints" while broken — certifying itself with its own output. These are different commands with
// a different failure mode, so they can contradict the harvest instead of echoing it.
function readPrintLogState() {
    const gl = wevtutilRun(['gl', PRINT_LOG_CHANNEL]);
    const gli = wevtutilRun(['gli', PRINT_LOG_CHANNEL]);
    if (gl === null || gli === null) return null;
    // Case-insensitive on purpose: the PowerShell side of this same read (HardenPrinters.ps1's
    // Get-PrintLogEnabled) is insensitive by default, and two readers of one wevtutil field
    // disagreeing on case would mean the guard keeps working while the harvest reports broken
    // forever. wevtutil emits lowercase today; this costs nothing and removes the divergence.
    const enabled = /^\s*enabled:\s*(true|false)\s*$/im.exec(gl);
    const records = /^\s*numberOfLogRecords:\s*(\d+)\s*$/im.exec(gli);
    if (!enabled || !records) return null;
    return { enabled: enabled[1].toLowerCase() === 'true', records: Number(records[1]) };
}

// The tip = the highest EventRecordID currently in the channel. It MUST come from querying the
// newest event: `gli`'s oldestRecordNumber reported 1 while the live records were 11-15 (measured
// right after a `wevtutil cl`), so deriving the cursor from that field would silently re-send.
function readPrintLogTip() {
    const xml = wevtutilRun(['qe', PRINT_LOG_CHANNEL, '/c:1', '/rd:true', '/f:xml']);
    if (xml === null) return null;
    const m = /<EventRecordID>(\d+)<\/EventRecordID>/.exec(xml);
    return m ? Number(m[1]) : null;   // null here = ran fine but returned nothing
}

// Unreadable is ABSENT, never 0. The reflex idiom `parseInt(raw) || 0` is a trap in this one
// spot: an empty file, a NaN or a stray BOM would all collapse to 0, and cursor 0 means "send
// the entire log". Note Number('') === 0, so the empty case has to be caught before the coercion.
function readPrintCursor() {
    try {
        if (!fs.existsSync(PRINT_CURSOR_PATH)) return null;
        const raw = fs.readFileSync(PRINT_CURSOR_PATH, 'utf-8').trim();
        if (!raw) return null;
        const n = Number(raw);
        if (Number.isFinite(n) && n >= 0) return Math.floor(n);
        // Garbage in the file (half-written, hand-edited) is treated as absent, which re-anchors to
        // the tip and DISCARDS whatever had not been posted. That is the safe direction, but it is
        // indistinguishable from a legitimate debut unless it leaves a crumb. The crumb is written
        // by the caller and ONLY once the re-anchor actually landed — otherwise a file that is both
        // unreadable AND unwritable would log this every ~2 min forever. Content never logged.
        cursorWasInvalid = true;
        return null;
    } catch (e) {
        return null;
    }
}

function writePrintCursor(record) {
    try { fs.writeFileSync(PRINT_CURSOR_PATH, String(record), 'utf-8'); return true; }
    catch (e) { return false; }
}

function decodeXmlText(s) {
    return String(s)
        .replace(/&lt;/g, '<').replace(/&gt;/g, '>')
        .replace(/&quot;/g, '"').replace(/&apos;/g, "'")
        .replace(/&amp;/g, '&');
}

// A permanent harvest failure must be reported ONCE, not every ~2 min. events.log is shared,
// capped at 128 KB / 600 lines by event-log.js, AND it is what body.diagnostics uploads — 720
// identical lines a day would evict the internet/update/tamper history inside two days and leave
// diagnostics saying nothing but this. So: log the TRANSITION, mirroring logInternetTransition.
let harvestFailedThisPass = false;
let cursorWasInvalid = false;

function reportHarvestFailure(detail, tag) {
    harvestFailedThisPass = true;
    try {
        if (fs.existsSync(PRINT_FAIL_FLAG_PATH)) return;
        fs.writeFileSync(PRINT_FAIL_FLAG_PATH, new Date().toISOString(), 'utf-8');
    } catch (e) {
        // If the marker can NEVER be written the throttle is gone and this costs a line per pass.
        // Self-limiting in practice: a BRAIN_DIR that rejects this write also rejects the
        // appendFileSync into events.log, so the flood silences itself.
    }
    appendEvent(tag || 'print-harvest-failed', detail);
}

// Guarded by the pass flag on purpose. Clearing it while this same pass has already reported a
// failure would re-arm the once-only rule and put us straight back to a line every ~2 min — which
// is how the FIRST version of this fix broke itself: it cleared on "the probe answered", then a
// later step (an unwritable cursor) failed and logged again, forever.
function clearHarvestFailure() {
    if (harvestFailedThisPass) return;
    try { if (fs.existsSync(PRINT_FAIL_FLAG_PATH)) fs.unlinkSync(PRINT_FAIL_FLAG_PATH); } catch (e) {}
}

function harvestPrintJobs() {
    // Health is reported even when the probe fails — with nulls, so the hub sees a HOLE instead of
    // nothing at all. Sending no field on the loudest failure would be the exact opposite of the
    // point: "this channel holds 500 records and we have reported 0 prints" has to stay visible.
    const blind = { jobs: [], maxRecord: null, health: { enabled: null, tip: null, cursor: null } };
    harvestFailedThisPass = false;
    cursorWasInvalid = false;
    try {
        const state = readPrintLogState();
        if (!state) {
            reportHarvestFailure('no se pudo leer el estado del canal de impresion');
            return blind;
        }

        const tip = readPrintLogTip();
        if (state.records > 0 && tip === null) {
            // Non-empty log, yet the tip query returned nothing => the query mechanism is broken,
            // not the day. This is the ONLY way to tell those two apart, because a malformed XPath
            // exits 0 with empty output. Anchor nothing, harvest nothing, and report it.
            reportHarvestFailure('el canal tiene registros pero la consulta no devuelve ninguno');
            return blind;
        }
        // NOT cleared here. Clearing on "the probe answered" would re-arm the one-line rule on every
        // pass, so a failure further down (an unwritable cursor, a dead 307 query) would log again
        // every ~2 min — exactly the flood this marker exists to prevent. Cleared only where the
        // harvest actually got through.

        const health = { enabled: state.enabled, tip, cursor: null };
        const cursor = readPrintCursor();

        // DEBUT / re-anchor. Absent (or unreadable) cursor => anchor to the TIP and post ZERO
        // events, so a machine that receives this by OTA never ships days of pre-existing prints
        // (the plan's non-goal "no recompactar historia" — green starts existing forwards).
        // A cursor ABOVE the tip means the log was cleared or its ids reset; re-anchoring costs
        // that window's prints, which under-counts — the safe direction — and never invents any.
        if (cursor === null || (tip !== null && cursor > tip)) {
            // ANCHOR TO THE OBSERVED TIP, never to a record COUNT. On the test PC a disabled channel
            // still reported its 5 records and its tip stayed queryable, so the two probes agree
            // there — but `gli` was already caught lying on this very channel (`oldestRecordNumber`
            // said 1 while the live records were 11-15), so its numbers are not something to gate
            // the anchor on. If the two ever disagree, the resolution has to be under-counting,
            // which costs a few prints; resolving toward 0 means "send the whole log", which paints
            // the fleet green on debut night.
            const anchor = tip === null ? 0 : tip;
            // This write is an ANCHOR, not a delivery receipt, so it is NOT gated on a successful
            // post: there is nothing being posted. The "advance only after the hub took it" rule
            // applies to the harvest below.
            if (writePrintCursor(anchor)) {
                health.cursor = anchor;
                if (cursorWasInvalid) {
                    appendEvent('print-cursor-invalid', 'cursor de impresion ilegible; re-anclado a la punta');
                }
                clearHarvestFailure();
            } else {
                // An unwritable cursor re-anchors every single pass and therefore posts nothing,
                // FOREVER, while looking exactly like a banca that does not print. Leave cursor
                // null so the hub can see the hole. (EPERM here is not hypothetical: installed
                // files carry +h +s and writeFileSync CREATE_ALWAYS throws on them.)
                reportHarvestFailure('no se pudo escribir el cursor de impresion');
            }
            return { jobs: [], maxRecord: null, health };
        }
        health.cursor = cursor;

        if (tip === null || tip <= cursor) {
            clearHarvestFailure();   // nothing new to fetch is a healthy harvest, not a broken one
            return { jobs: [], maxRecord: null, health };
        }

        // Constant template; only a validated finite integer is interpolated.
        const xml = wevtutilRun([
            'qe', PRINT_LOG_CHANNEL,
            `/q:*[System[(EventID=307) and (EventRecordID>${cursor})]]`,
            '/f:xml', `/c:${PRINT_JOBS_MAX}`, '/rd:false',
        ]);
        if (xml === null) {
            reportHarvestFailure('la consulta de eventos 307 fallo');
            return { jobs: [], maxRecord: null, health };
        }

        const jobs = [];
        let maxRecord = null;
        let maxSeen = null;    // highest record id we LOOKED at, parsed or not — see below
        let unreadable = 0;    // 307s we saw and could NOT turn into a job
        for (const chunk of xml.split('</Event>')) {
            const rec = /<EventRecordID>(\d+)<\/EventRecordID>/.exec(chunk);
            if (rec) {
                const seen = Number(rec[1]);
                if (Number.isFinite(seen) && (maxSeen === null || seen > maxSeen)) maxSeen = seen;
            }
            const when = /<TimeCreated\s+SystemTime='([^']+)'/.exec(chunk);
            const body = /<DocumentPrinted[^>]*>([\s\S]*?)<\/DocumentPrinted>/.exec(chunk);
            if (!rec) continue;                    // trailing fragment of the split, not an event
            if (!when || !body) { unreadable++; continue; }
            const param = (n) => {
                const m = new RegExp(`<Param${n}>([\\s\\S]*?)</Param${n}>`).exec(body[1]);
                return m ? decodeXmlText(m[1]) : null;
            };
            const at = Date.parse(when[1]);
            const printer = param(5);
            if (Number.isNaN(at) || !printer) { unreadable++; continue; }
            // Number(null) is 0, not NaN — so reading a missing Param through Number() straight
            // would report a confident 0 bytes instead of "unknown". Same coercion trap the cursor
            // reader guards against, in a field where it merely lies quietly.
            const rawBytes = param(7);
            const rawJob = param(1);
            const bytes = rawBytes === null ? null : Number(rawBytes);
            const job = rawJob === null ? null : Number(rawJob);
            const record = Number(rec[1]);
            jobs.push({
                at: new Date(at).toISOString(),
                printer: printer.slice(0, 120),
                bytes: Number.isFinite(bytes) ? bytes : null,
                job: Number.isFinite(job) ? job : null,
                record,
            });
            if (maxRecord === null || record > maxRecord) maxRecord = record;
        }

        // GUARANTEE OF PROGRESS. If every event in this window failed to parse, `jobs` is empty, so
        // nothing is posted, so the cursor never advances — and because /rd:false hands back the
        // OLDEST first, those same unparseable events block everything behind them forever. Step
        // over what we have already judged unreportable; that costs those events and nothing else.
        if (jobs.length === 0 && maxSeen !== null && maxSeen > cursor) {
            if (writePrintCursor(maxSeen)) {
                health.cursor = maxSeen;
                // Counted, not subtracted: `maxSeen - cursor` is a span of record ids, and this
                // channel writes FIVE events per job (800/801/842/805/307), so that arithmetic
                // would report ~5x what was actually dropped — on the one line a human uses to
                // judge how bad a broken harvest is. Routed through the throttle because a broken
                // parser makes this fire on every print, forever.
                reportHarvestFailure(`${unreadable} evento(s) 307 ilegibles omitidos`, 'print-harvest-skipped');
            } else {
                reportHarvestFailure('no se pudo escribir el cursor de impresion');
            }
            return { jobs, maxRecord, health };
        }
        // NOT cleared when we are handing jobs upward: this pass does not end here, it ends in
        // main() once the post returned 2xx AND the cursor write landed. Clearing here would wipe
        // the marker before a post-cursor failure could repeat — putting the every-2-min flood
        // back through the exact door it already came through once.
        if (jobs.length === 0) clearHarvestFailure();
        return { jobs, maxRecord, health };
    } catch (e) {
        // Never let this take the poll down with it: everything else in the body still has to ship.
        // But do NOT go quiet: this is the one module whose whole thesis is that silence is the bug,
        // and a deterministic throw here would blind a machine forever without a single line.
        // e.message can carry an agent path at worst, never ticket data.
        reportHarvestFailure('excepcion en la cosecha: ' + (e && e.message));
        return { jobs: [], maxRecord: null, health: { enabled: null, tip: null, cursor: null } };
    }
}
// ---------------------------------------------------------------------------

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

// --- Launcher reconciliation (Install/Uninstall rename, v1.0.38) ---------------
// The double-click launchers were renamed to Install.exe / Uninstall.exe (from the
// old Instalar.exe / Restaurar.bat). This migration CANNOT live in self-update.js:
// during the OTA that ships 1.0.38 the running process is still the OLD self-update.js
// (Node loaded it at startup), and afterwards VERSION already equals the new version
// so self-update returns early and never runs again. The poll task, by contrast, is a
// FRESH SYSTEM process every ~2 min, so the first poll AFTER the update runs THIS (new)
// code — the only reliable place for a post-update file migration.
//   1. Delete the obsolete launchers OTA leaves behind — copyTree only adds/overwrites,
//      it never removes a file absent from the new bundle, so the old names would linger
//      next to the new ones ("two files, which do I use?").
//   2. Re-hide the current launchers with +h +s — OTA's copyFileSync CREATES the new
//      Install.exe/Uninstall.exe WITHOUT the disguise attributes a fresh install applies
//      (InstallWatcher.bat hides every file but abracadabra.bat), so an OTA-added launcher
//      would otherwise sit VISIBLE at the install root.
// Idempotent + marker-gated (one-time cost). SYSTEM-only, no credential, no network —
// exactly like reassertHardeningIfDue — so it runs ABOVE the not-enrolled guard: a
// machine that failed to enroll still polls and still needs its launchers reconciled.
// Fully wrapped so launcher cleanup can never break a poll. NOT a golden-rule concern:
// it touches no proxy process, registry, or internet setting.
//
// KNOWN LIMIT (accepted, self-healing — deferred fix, see docs/plans/0005): if the 1.0.38 OTA
// copies the new exes and then FAILS validation, self-update's rollback (restoreBackup) is an
// additive overlay — it restores the old Instalar.exe but does NOT remove the just-added
// Install.exe/Uninstall.exe, which self-update created WITHOUT +h +s. The rolled-back machine
// then runs the OLD poll-hub (no reconcile), so the new exes sit VISIBLE until 1.0.38 (or a later
// version carrying this code) SUCCESSFULLY lands — at which point the first post-commit poll runs
// reconcile and converges (deletes Instalar.exe, hides both). So the leak is bounded to a
// rolled-back-and-not-yet-resucceeded machine and heals itself on the next successful update; a
// launcher-rename release doesn't touch the proxy, so a rollback is unlikely to begin with. The
// COMPLETE fix (rollback removes root *.exe absent from the backup) lives in self-update.js's
// golden-rule-critical rollback path and is filed as its own change — deliberately NOT folded in
// here to keep this migration out of the OTA rollback engine.
const LAUNCHER_MIGRATION_MARKER = path.join(BRAIN_DIR, 'launchers-1.0.38.done');
const UPDATING_FLAG_PATH = path.join(BRAIN_DIR, 'updating.flag');
// Coupled to the .ps1 watchdog layers' STALE_FLAG_MINUTES (CheckAndStartProxy.ps1 /
// SetProxyByAvailability.ps1) and self-update.js's health window — keep the three in step.
const STALE_UPDATING_FLAG_MS = 15 * 60 * 1000;
// updating.flag is "active" only while FRESH. self-update writes it (mtime = now) from before it
// copies the new tree until it commits/rolls-back (cleared in its finally). But if self-update is
// KILLED or the machine loses power after writing the new VERSION and before that finally runs, the
// flag is orphaned — and since VERSION already matches, no same-version update ever runs to clear
// it. An existence-only gate would then skip reconcile FOREVER. So mirror the watchdog: a flag older
// than STALE_UPDATING_FLAG_MS is treated as ABSENT, letting an orphaned update self-heal on the next
// poll. mtimeMs and Date.now() are both absolute epoch ms, so the subtraction is timezone-safe.
function isUpdatingActive() {
    try {
        const ageMs = Date.now() - fs.statSync(UPDATING_FLAG_PATH).mtimeMs;
        return ageMs <= STALE_UPDATING_FLAG_MS;
    } catch (e) {
        return false; // absent or unreadable → not updating
    }
}
function reconcileLaunchers() {
    try {
        if (fs.existsSync(LAUNCHER_MIGRATION_MARKER)) return; // already reconciled here
        // Never reconcile mid-cutover. A poll firing during self-update's ~minutes-long validation
        // window (polls every ~2 min, update up to ~5) would load the new code, see both exes
        // already copied, hide them and write the marker BEFORE cutover; if validation then rolled
        // back to the old launchers, the marker would survive and permanently skip the real
        // reconcile after a later retry. Gate on a FRESH updating.flag (stale = crashed update,
        // treated as absent so it self-heals). Reconcile runs on the first poll after a clean commit.
        if (isUpdatingActive()) return;
        const rootDir = path.join(BRAIN_DIR, '..');

        for (const name of ['Instalar.exe', 'Instalar.bat', 'Restaurar.bat']) {
            try {
                const p = path.join(rootDir, name);
                if (fs.existsSync(p)) fs.unlinkSync(p); // +h+s never blocks unlink
            } catch (e) { /* best-effort; a stale shim is harmless */ }
        }

        // Full path to attrib.exe — a bare 'attrib' can fail to resolve under SYSTEM's
        // PATH; System32 is always present.
        const attribExe = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'attrib.exe');
        let bothPresent = true;
        let hideFailed = false;
        for (const name of ['Install.exe', 'Uninstall.exe']) {
            const p = path.join(rootDir, name);
            if (fs.existsSync(p)) {
                try { execFileSync(attribExe, ['+h', '+s', p], { windowsHide: true, timeout: 8000 }); }
                catch (e) { hideFailed = true; }
            } else {
                bothPresent = false; // one launcher not copied yet — don't latch on a partial swap
            }
        }

        // Latch ONLY once BOTH new launchers are present AND hidden cleanly. copyTree is an
        // additive, non-atomic overlay: an interrupted OTA can land ONE launcher before a poll
        // fires. Latching on "any present" would hide that one, mark done, and then never
        // re-hide the second launcher a later retry adds — leaving it VISIBLE forever. Requiring
        // both (fail-closed: whole set or nothing) makes such a machine re-check next poll, so
        // it converges only when the swap is actually complete. A machine that polled before the
        // swap (both names absent) or hit a transient attrib failure re-checks the same way.
        if (bothPresent && !hideFailed) {
            try { fs.writeFileSync(LAUNCHER_MIGRATION_MARKER, new Date().toISOString(), 'utf-8'); } catch (e) {}
        }
    } catch (e) { /* never let launcher cleanup break the poll */ }
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

    // One-time launcher rename cleanup (Install/Uninstall, v1.0.38). Same rationale as
    // the hardening re-assert above: a purely LOCAL, SYSTEM-only, no-credential/no-network
    // property, so it must run ABOVE the not-enrolled guard — a machine that failed to
    // enroll still polls and still needs its old launchers removed + new ones hidden.
    reconcileLaunchers();

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
    refreshWifiFingerprintIfDue(locateForced); // plan 0017: automatic fallback source
    if (locateForced) { try { fs.unlinkSync(LOCATE_PENDING_PATH); } catch (e) {} }
    const location = readLocation();
    // Plan 0017: only attach a FRESH Windows fix. When Location is off, GetLocation
    // fails and location.json keeps its last good fix — attaching it forever would keep
    // the hub on (stale) Windows and the Wi-Fi fallback would never fire, so a moved
    // laptop could never read as "out". Once the fix ages past the TTL we drop it,
    // body.location goes absent, and the hub falls back to the fresh fingerprint.
    if (location && location.at && Date.now() - new Date(location.at).getTime() < LOCATION_ATTACH_TTL_MS) {
      body.location = location;
    }
    // Plan 0017: the Wi-Fi fingerprint rides along on EVERY poll (additive to the
    // cross-repo contract). The hub uses it only when there's no `location` fix, and
    // to build the post's reference set. An old hub simply ignores the field.
    const wifiFingerprint = readWifiFingerprint();
    if (wifiFingerprint) body.wifi_fingerprint = wifiFingerprint;

    // Tamper events (uninstall attempt, printer retention attempt, etc.) since the last upload.
    // reassertHardeningIfDue() ran at the TOP of main() (above the not-enrolled guard); its
    // synchronous `tamper` write is therefore already on disk for this read. See plan 0010.
    // Each event now carries a `setting` dimension (plan 0011, additive — null for pre-0011 lines).
    const tamper = readNewTamperEvents();
    if (tamper.events.length > 0) body.tamper_events = tamper.events;

    // Printed documents since the last upload (plan 0013, cross-repo contract — ADDITIVE in both
    // directions: an old hub ignores both fields, and a new hub tolerates an old agent that sends
    // neither, treating their absence as "no proof", never as "it printed"). `print_log` is the
    // health probe: it makes "this channel holds 500 records and we have reported 0 prints"
    // visible from the hub instead of silent, which a column that only ever shows what we wrote
    // could never do.
    // `print_log` is ALWAYS sent (every path returns a health object) — its own fields carry the
    // "we could not tell" case. `tip: null` means two different things and the hub tells them apart
    // by `enabled`: enabled null => the probe itself failed; enabled boolean with tip null => the
    // channel is genuinely empty. That rule is consumed in the other repo, so it also lives in
    // this repo's CLAUDE.md next to the field description.
    const print = harvestPrintJobs();
    if (print.jobs.length > 0) body.print_jobs = print.jobs;
    body.print_log = print.health;

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
    // Same rule for the print cursor, and it reaches here only on a 2xx: postJson rejects on
    // anything else, so a hub error re-sends these prints next poll instead of losing them.
    // It advances to the highest record we ACTUALLY posted — never to the tip of the log, which
    // would skip whatever the cap left behind.
    if (print.jobs.length > 0 && print.maxRecord !== null) {
        // The pass ENDS here, not in harvestPrintJobs(): this is the only cursor write on the
        // normal path, and an unchecked failure here is the worst of the three — the harvest keeps
        // working, the hub keeps deduping, and the same events are re-posted every ~2 min forever
        // while every surface looks healthy. Clearing the marker is deliberately the LAST thing.
        if (writePrintCursor(print.maxRecord)) {
            clearHarvestFailure();
        } else {
            reportHarvestFailure('no se pudo escribir el cursor tras subirlo al hub');
        }
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
