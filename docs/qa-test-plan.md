# QA stress-test plan — watcher-proxy / watcher-fleet

Living checklist. Every item gets tested for real on `~/vm/watcher-test-vm/`
(or real hardware once available), never just reasoned about. Mark ✅ verified
/ ⚠️ partially verified / ❌ not yet tested / 🔺 priority for next session.
Update this file as items get tested — don't re-derive status from memory.

See `docs/plans/0001-fleet-dashboard.md` → "Handoff" section for full context
on what's already been proven and the one open bug thread (self-update's
registry-flip step).

## A — Install-time edge cases

- ✅ No internet + no bundled Node → fails safely, touches nothing (verified)
- ✅ Internet + bundled Node → full clean install (verified)
- ❌ Re-running the installer on an already-installed machine (idempotency —
  does it duplicate scheduled tasks, corrupt whitelist.txt, double-register
  with the hub?)
- ❌ Running without admin rights at all, deliberately isolated (AV exclusion
  and print-spool steps should degrade gracefully, core proxy+watchdog should
  still work — confirm explicitly, not just inferred from partial runs)
- ❌ McAfee-present path (`AddAntivirusExclusion.ps1`'s exit-code-2/3 branches)
  — only Defender has been tested since the VM only has Defender
- ❌ Disk nearly full during Node download/extraction or during install
- ❌ Node download interrupted mid-transfer, then retried (partial zip
  cleanup — a lock-file collision was hit once by accident, not deliberately
  engineered as a test)
- ❌ Two `InstallWatcher.bat` runs launched at nearly the same time (double
  click twice) — duplicate scheduled tasks? duplicate proxy processes?

## B — Runtime resilience

- ✅ Kill the proxy process → watchdog self-heals (verified, ~6s to safe state)
- ✅ Kill the watchdog process → Layer 3 (Safety Net) rebuilds it (verified)
- ✅ Kill both simultaneously → full rebuild from a dead stop (verified)
- ❌ Hard power-loss simulation (force-kill the VM process, not a graceful
  shutdown) mid-install, mid-update, and mid-whitelist-write — does the
  machine come back up in a safe state on next boot?
- ❌ System clock changed backward/forward while an unplug `resume_at` is
  pending — does the local-clock comparison in `WatchdogLoop.ps1` do
  something sane, or does a clock jump cause a stuck or premature resume?
- ❌ `whitelist.txt` manually corrupted/malformed (binary garbage, no
  managed-block markers at all, markers present but mismatched) — does
  `whitelist-merge.js` degrade safely or corrupt further?
- ❌ Disk full while `poll-hub.js` tries to write logs or update
  `whitelist-version.txt`
- ❌ Rapid unplug/resume toggling (flapping every few seconds) — does
  anything race or leave a stuck intermediate state?
- ❌ Long-run stability — specifically confirm the layer-1 task's
  `ExecutionTimeLimit: Disabled` actually holds past the old 72h default
  (can't wait 72h in a session; at minimum confirm the task XML setting is
  still applied correctly after a reboot, not just at creation time)
- ❌ Network flapping (repeated connect/disconnect) during a hub poll or
  self-update download

## C — Uninstall / reinstall cycles

- ✅ `BackToNormal.bat` ordering (registry-before-process-stop) — verified
- ✅ Admin cleanup removes all scheduled tasks including the new Layer 2/3
  ones — verified
- ❌ Repeated uninstall→reinstall cycles (3-5x back to back) — anything
  accumulate or leak (stale backup folders, orphaned tasks, growing logs)?
- ❌ Uninstalling while the machine is mid-unplugged (does BackToNormal
  correctly override an active unplug, or fight it?)
- ❌ Uninstalling while a self-update is in progress

## D — Fleet/hub interaction (blocked until watcher-fleet is actually deployed)

- ❌ Hub unreachable during a real poll cycle (only reasoned about /
  code-reviewed, never executed against a real deployed hub)
- ❌ Hub returns a malformed/unexpected JSON response
- ❌ Duplicate/replayed registration attempts with the same enrollment secret
- ❌ Concurrent whitelist edits by two dashboard sessions at once

## E — Self-update (the open bug thread — see handoff section for detail)

- 🔺 **Priority**: re-run the full self-update flow on a different VM config
  or real hardware to determine if the registry-flip failure is this VM's
  TCG emulation specifically, or a real remaining bug
- ⚠️ Version-check/backup/download/extract — verified working in isolation
- ❌ Self-update when the "new" version has a bug that fails its own health
  check (does rollback actually restore full function, not just files?)
- ⚠️ GitHub unreachable mid-download — fails safely (verified once, worth
  re-confirming after the reg.exe fix)
- ❌ Self-update racing with the watchdog or Safety Net simultaneously trying
  to restart the proxy — possible double-start or state confusion?

---
*Update this file directly as items move from ❌/⚠️ to ✅. If a new edge case
occurs to you (or Felix) mid-session, add it here immediately rather than
letting it live only in conversation.*
