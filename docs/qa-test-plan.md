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

## E — Self-update

- ✅ **Silent-crash FIXED — verified end-to-end 2026-07-21.** Real hub→poll→
  self-update run on the VM (agent on 1.0.13 fixed code, hub serving 1.0.14):
  full clean sequence in `update.log` — `Backed up` → download 200 (93174 B)
  → `Checksum OK` → `New files copied in` → `Update to 1.0.14 successful and
  healthy` → `Process exiting with code 0`. Reproduced 2/2 runs, ended at
  VERSION=1.0.14, port 8080 healthy, lock released. The old silent-death
  signature (process gone after "Backed up"/"Checksum OK", no exit line) is
  GONE. NOTE: an apparent "death after Checksum OK" seen mid-session was a
  TEST-HARNESS artifact — triggering `poll-hub` over SSH let the SSH session
  teardown orphan-kill the detached self-update child; keeping the session
  alive (or the real scheduled-task path) completes cleanly.
- ⚠️ Version-check/backup/download/extract — verified working in isolation
- ❌ Self-update when the "new" version has a bug that fails its own health
  check (does rollback actually restore full function, not just files?)
- ⚠️ GitHub/hub unreachable mid-download — fails safely (verified once, worth
  re-confirming after the reg.exe fix)
- ✅ **GOLDEN-RULE VIOLATION FOUND & FIXED — self-update racing the watchdog/
  Safety Net. Bug confirmed 2/2, fix verified 2/2 on the VM 2026-07-21.** Second-by-second registry+
  port timeline during the update:
  `PE=1/PS=127.0.0.1:8080/up` → self-update `flipToNormalInternet` → `PE=0/
  PS=<none>/up` (correct, ~1s) → watchdog/SafetyNet re-asserts → `PE=1/PS=
  127.0.0.1:8080/up` (flip UNDONE while proxy briefly still up) → proxy dies
  for the file-copy → **`PE=1/PS=127.0.0.1:8080/DOWN` for ~13–22s = all
  browser traffic routed to a dead proxy = internet FULLY DOWN** → recovers
  when self-update restarts the proxy. Root cause: self-update's single
  upfront flip-to-normal is transient (the still-running watchdog re-enables
  filtering because the proxy is momentarily still up), and self-update then
  STOPS the watchdog — removing the normal fail-open safety net exactly when
  it kills the proxy for the copy. So nothing forces PE=0 while the proxy is
  dead. FIX (implemented + verified, shipped as v1.0.15): an `updating.flag`
  mirroring `unplugged.flag`. self-update.js raises it right before the flip
  and clears it in `finally`; **SetProxyByAvailability.ps1** (the only place
  PE=1 is ever set) treats the flag as "proxy down" → always forces NORMAL
  internet, so the watchdog can no longer re-enable the proxy mid-update; and
  **WatchdogLoop.ps1** + **CheckAndStartProxy.ps1** honor it like the unplug
  path (force normal internet, do NOT restart the proxy). VERIFIED 2/2 on the
  VM (1.0.14→1.0.15): second-by-second timeline shows the whole ~20s
  proxy-down copy window at `PE=0 / ProxyServer=<none>` = direct internet UP,
  **0 danger samples** (vs ~13–22s of internet-down before the fix); update
  still completes healthy, flag cleared, filtering restored after. Caveat:
  this VM is the 1.0.0-era install + synced current code; the racing
  interaction is code-level (not install-specific), but a FRESH 1.0.15
  install is still worth a confirming run before rollout.

## F — Multi-user PCs (admin installer account ≠ worker "banca" account)

Felix flagged this: real terminals often have TWO Windows accounts — an
admin account (used to install) and a separate limited "banca" account the
actual worker logs into to sell. Since Watcher's proxy toggling is all
per-user (`HKCU`), this interacts directly with the Windows Service /
registry-hive findings from this session.

- ✅ **Found and fixed a real bug this session**: the watchdog tasks'
  `<Principal>` had no explicit user, and Windows Task Scheduler silently
  bakes in the SID of whoever ran the installer as the task's specific
  run-as identity — confirmed by hand (`schtasks /query .../xml` showed
  Administrator's exact SID). On a two-account PC, this would bind the
  watchdog to the admin account; `InteractiveToken` requires that *specific*
  user to have an active session, so the task could fail to start entirely
  during the banca worker's own session — meaning no filtering/protection
  while the terminal is actually in use. Fixed by binding `<Principal>` to
  `GroupId = S-1-5-32-545` (`BUILTIN\Users`) instead, both in the task XML
  templates and `RegisterProxyLogonTask.ps1`. Re-verified the fix actually
  took effect in the real registered task's XML (shows `GroupId`, not a
  baked-in SID) after re-running `RegisterWatchdogTasks.ps1`.
- ✅ **Full live test completed and PASSED.** SSH alone was confirmed
  insufficient (a banca SSH login created no WTS session at all — didn't
  even show in `query user`). RDP `+auth-only` mode authenticates but
  disconnects before a session forms — also confirmed insufficient. What
  actually worked: booted the VM with a VNC console attached
  (`-vnc 127.0.0.1:1`) and used `vncdotool` to drive a genuine interactive
  logon as a second local user ("banca") at the actual console — logged off
  Administrator, switched users at the LogonUI screen, typed banca's
  credentials. Confirmed via `query user`: banca got a real, distinct
  console session (ID 2, separate from Administrator's ID 1). Then, the
  real proof: `WatchdogLoop.ps1`'s process owner was checked via
  `Win32_Process.GetOwner()` and came back as `WATCHER-TEST\banca` — the
  `GroupId=BUILTIN\Users` fix correctly fired the task for a completely
  different, non-installer account. Also confirmed banca's OWN registry
  hive (`HKEY_USERS\<banca's SID>`) had its `ProxyEnable` value actively
  managed, not Administrator's — the whole mechanism operates correctly
  end-to-end for the actual worker account, not just the admin who installs
  it. Test user and profile removed afterward.
- ❌ What happens on a PC where the banca user has no admin rights at all —
  confirm `LeastPrivilege`/`RunLevel` on the fixed tasks doesn't require
  elevation the worker account wouldn't have.
- ⚠️ **Fast user switching / two users at once — attempted, inconclusive on
  this VM, real structural finding.** Logged Administrator in at the console,
  confirmed her `WatchdogLoop.ps1` was already running (PID 596), then used
  Ctrl-Alt-Del → "Switch User" (deliberately not "Sign out") to bring banca
  in without logging Administrator off first. Real finding: **Windows
  Server without the Remote Desktop Session Host role does not support true
  concurrent local sessions at all** — "Switch User" silently logged
  Administrator off completely (her session vanished from `qwinsta`
  entirely, not left running in the background as a "Disc" state the way it
  would on Windows 10/11). Confirmed the hand-off itself is clean — no
  orphaned/duplicate `WatchdogLoop.ps1` left behind from Administrator's
  session, only banca's new one (PID 3588). But **the actual question this
  test exists to answer — does the watchdog run twice and fight over port
  8080 when two people are genuinely logged in simultaneously — was never
  actually exercised**, because this VM's OS structurally can't produce that
  condition. Real terminals almost certainly run Windows 10/11, which
  supports genuine concurrent Fast User Switching out of the box, no RDS
  license needed. 🔺 **Priority for next session**: re-run this exact test
  on a Windows 10/11 VM or real hardware, where concurrent sessions are
  actually possible. Still a completely open question, not a confirmed
  pass.

---
*Update this file directly as items move from ❌/⚠️ to ✅. If a new edge case
occurs to you (or Felix) mid-session, add it here immediately rather than
letting it live only in conversation.*

## G — Audit/identity features (v1.0.12–1.0.14), verified 2026-07-17

Verified live on `~/vm/watcher-test-vm/` (Windows Server 2022, PS 5.1) against
the real prod hub, then the test machine row was deleted from prod.

- ✅ **Tamper detection (Phase 5)** — injected a `tamper` line into events.log,
  ran poll-hub; the event landed in prod `machine_tamper` and `last_tamper_at`
  was set. Full agent→hub→DB pipeline confirmed.
- ✅ **Location degrades gracefully (Phase 4)** — `GetLocation.ps1` runs, returns
  empty (no WiFi/fix on a Server VM) and exits clean (no crash/hang);
  `EnableLocation.ps1` runs and sets ConsentStore location = Allow; the poll
  still completes and `last_location` is null. Real coordinate ACCURACY is NOT
  verifiable in a VM (no WiFi) — 🔺 needs a real laptop.
- ✅ **Ponche (Phase 3)** — `machine_day` row created with first_seen on poll.
- ✅ **Register + poll pipeline** to prod hub — exit 0, machine row updated.
- ⚠️ Banca code / first-page-of-day: pipeline exercised indirectly (poll path);
  not separately asserted this run.
