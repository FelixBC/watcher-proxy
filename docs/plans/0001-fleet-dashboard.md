# 0001 — Fleet dashboard for watcher-proxy

Status: **APPROVED — proceeding to build**

## Problem

Nelson (and Felix) currently have no way to see the health of, update the
whitelist on, or remotely disable/re-enable the ~40 deployed watcher-proxy
Windows PCs after the field install trip. Today, any fix or config change
requires physical or UltraViewer access to each machine individually, and
there is no way to distinguish "this PC has no internet" from "watcher-proxy
itself is broken" without a phone call to the site.

## Acceptance criteria

1. Login is required for all dashboard access. Two roles exist — admin
   (Felix) and operator (Nelson). Unauthenticated requests are rejected.
2. Editing the shared whitelist and pushing it updates the shared list
   centrally; each PC applies the new shared list within one poll cycle
   while preserving its own per-machine "extra" whitelist entries (extras
   are additive-only — a bulk push never removes or overwrites them).
3. Toggling "unplug" on a machine fully stops that machine's proxy AND its
   watchdog within one poll cycle; Windows reverts to normal, unfiltered
   internet. The watchdog checks a persisted "disabled" flag and does not
   attempt to restart anything while it's set.
4. An unplug can be set to auto-resume at a specific date/time, or left
   indefinite. The resume timestamp is stored **locally on the machine**
   at the time it's set, so resume fires on the machine's own clock and
   does not depend on the hub being reachable at the moment resume is due.
   Nelson can also manually resume at any time, overriding any scheduled
   resume.
5. The dashboard shows, per machine, four independent signals — internet
   reachable, proxy running, filter active, last-check-in age — refreshed
   at least once per poll cycle, such that a "no internet" machine is
   visually distinct from a "stale check-in, otherwise fine" machine.
6. If the hub is completely unreachable, every PC continues enforcing its
   last-known whitelist/unplug state with zero change to local behavior.
   Verified by blocking the hub's domain and confirming no local effect.
7. A PC can pull and apply a code update with no manual intervention.
   Before stopping the running proxy to apply the update, the machine
   first flips Windows to normal unfiltered internet (same mechanism the
   watchdog already uses) — so a crash or power loss mid-update cannot
   leave the machine pointed at a dead local proxy. If a post-update
   health check fails, the previous working version is restored
   automatically.
8. A freshly installed PC self-registers using a shared enrollment secret
   embedded in the installer package, and receives a unique per-machine
   credential back from the hub on first successful registration. It
   appears on the dashboard within one poll cycle. No manual
   pre-provisioning step is required. All subsequent polls from that
   machine use its own issued credential, not the shared enrollment
   secret.
9. Under all of the above (bulk push, unplug/resume, update, hub downtime),
   no machine ever loses internet connectivity entirely — the fail-open
   invariant holds in every case, independent of the dashboard/hub.

## Non-goals (explicit v1 scope fence)

- Full allowed-traffic logging / browsing history. v1 ships blocked-request
  logs only, as already decided earlier in this project.
- Recurring/repeating unplug schedules (e.g. "every Sunday 8–11pm"). v1 is
  single resume-time-or-indefinite only.
- Real-time push (WebSocket, instant-apply). v1 is poll-based (~1–2 min
  cycle); Nelson's changes take effect on the next poll, not instantly.
- Code-signing or checksum verification of pulled updates. The update
  mechanism trusts the hub over TLS; this is a named residual risk, not
  solved in v1.
- Hardening the enrollment secret against extraction from the installer
  package itself (it is not obfuscated). Named residual risk, not solved
  in v1 — acceptable for this threat model but should be revisited if
  the deployment scales past this fleet.
- Editing a specific machine's per-machine "extra" whitelist entries
  *through the dashboard UI*. v1 only guarantees a bulk push doesn't
  destroy them; editing extras remains a manual/local (UltraViewer)
  process for now. **Inferred from "bulk is default and more polished" —
  flagged for Felix's confirmation, not a hard decision yet.**
- More than two roles or granular per-user permissions.
- Managing antivirus exclusions or print-spool config from the dashboard.
- A native mobile app — web dashboard only.

## Contracts & ADR-locked areas touched

None exist yet. `watcher-proxy` has no `CLAUDE.md`, no `docs/adr/`, and no
prior plan tracker — this is the first plan doc in the repo. The dashboard
itself is a different stack (Vercel/Next.js + Supabase) from the existing
PowerShell/Node.js proxy tooling, so it is proposed as a **new repository**
("watcher-fleet") rather than folded into `watcher-proxy` — pending Felix's
confirmation below. No locked contract is being changed by this feature;
there is simply nothing established yet to conflict with.

## Recommended gear

**FULL-ORCHESTRATOR.** This is unambiguously multi-area — auth, an API, a
database, changes to the Windows device-agent scripts, and a dashboard UI —
and it touches a real risk surface: access control over the
internet-filtering state of ~40 unattended production business machines.
Escalating per the bias-to-escalate rule even though some individual pieces
(e.g. the status dashboard) would look small in isolation.

## Open questions — resolved on "go build" (recommended defaults adopted)

1. **Trip date** — still unknown. Not blocking build; revisit before final
   canary/rollout scheduling.
2. **Repo location** — **new repo `watcher-fleet`**, separate from
   `watcher-proxy`.
3. **Poll interval** — **2 minutes**.
4. **Log retention window** — **30 days rolling**.
5. **Per-machine extras editing in the dashboard** — **confirmed out of
   v1**; bulk push + preservation only, per non-goals.

---
*Written by the `/define` skill. Nothing built yet — this statement is the
contract every later phase (research, solve, decompose, implement, verify)
will be checked against. Any drift from it during those phases is a
stop-and-report, not a silent expansion.*

## Handoff — 2026-07-09, context ran low mid-session

Everything below is real state, not aspirational. Both repos exist and are
pushed. **watcher-proxy is up to date on GitHub** (`main` @ `d20f366`).
**watcher-fleet exists locally only** (`~/work/watcher-fleet`) — never
pushed anywhere, no remote configured, Supabase/Vercel never provisioned.

### What's actually verified, by AC number (see Acceptance criteria above)

Verified by *running it* on a real Windows Server 2022 VM (not just review):

- **AC2** (bulk whitelist push preserves extras) — ✅ fully verified.
  Simulated two successive hub pushes against a real `whitelist.txt`;
  extras survived byte-identical across both. `WatcherBrain/whitelist-merge.js`.
- **AC3/AC4** (unplug/resume) — ✅ fully verified. Simulated flag
  create/remove, watchdog correctly stopped/restarted the proxy and
  flipped filtering each time, confirmed stable (not flapping) over 15s+.
- **AC7 golden-rule ordering** (flip-before-stop) — ✅ verified in
  `BackToNormal.bat`, `WatchdogLoop.ps1`, and (eventually) `self-update.js`.
  Found and fixed a real bug where `BackToNormal.bat` had this order
  backwards.
- **AC9 fail-open under crash** — ✅ verified. Killed the proxy process
  directly; registry reverted to normal internet in ~6s, self-healed
  without intervention.
- **AC9 fail-open under total watchdog death** — ✅ verified, but only
  after a real design change (see "3-layer redundancy" below).
- **AC7 self-update mechanics minus the final apply step** — ✅ version
  check against live GitHub, backup, download, extraction, protected-path
  exclusions, rollback structure. ❌ **the actual "flip to normal internet
  then swap files" step remains unreliable** — see the dedicated section
  below, this is the one open thread.
- **AC1/AC5/AC6/AC8** (login, dashboard status signals, hub-unreachable
  behavior, self-registration) — built (`watcher-fleet`), reviewed by a
  separate agent, **never run** — no Supabase project exists yet to run
  it against. This is next-step work, not verified work.

### Two real, confirmed-fixed bugs (found by running, not reading)

1. `InstallWatcher.bat`'s Node.js detection always reported success
   regardless of whether Node was actually found — classic batch
   `%ERRORLEVEL%`-inside-parentheses bug (value substituted at parse
   time, before the command it's checking even ran). Fixed with
   `if errorlevel 1 (...)`, which evaluates live.
2. The watchdog task's only trigger was "at logon" — since running the
   installer means you're already logged in, it stayed unarmed for the
   entire session it was installed in. Fixed by running it once
   immediately after creation.

### The 3-layer watchdog redundancy (Felix asked for "unkillable, only
BackToNormal stops it")

- **Layer 1** — existing 5-sec `WatchdogLoop.ps1` loop. Works when alive.
- **Layer 2** — Windows' native Task Scheduler `RestartOnFailure`, wired
  onto the "Watcher Proxy Loop" task. **Built, and confirmed by hand NOT
  to reliably fire** even after fixing the task's action to be the
  long-running process directly (rather than a detached `wscript.exe`
  launcher, which was the first reason it didn't work). Kept in the code
  for whatever marginal benefit it has; do not rely on it.
- **Layer 3** — a second, independent, process-less scheduled task
  ("Watcher Proxy Safety Net") firing every 1 min via
  `CheckAndStartProxy.ps1`, which was extended to ALSO relaunch
  `WatchdogLoop.ps1` itself if it's not running (not just restart the
  proxy). **This is the layer that's actually proven to work** — verified
  twice, independently rebuilding the watchdog and the proxy from a
  totally dead stop.
- `RegisterWatchdogTasks.ps1` deliberately uses `schtasks.exe` (via raw
  Task Scheduler XML templates, `WatcherProxyLoop.task.xml` /
  `WatcherProxySafetyNet.task.xml`), NOT the PowerShell `ScheduledTasks`
  module (`Register-ScheduledTask`) — that module hung indefinitely
  re-registering a task with a running instance on this VM; `schtasks.exe`
  never did.
- `BackToNormal.bat`'s non-admin step now explicitly disables (not just
  kills the process for) both tasks before the admin-elevation gap, so
  Layer 2/3 can't resurrect anything mid-uninstall. Confirmed working.

### The one open thread — self-update's registry-flip step

`self-update.js`'s `flipToNormalInternet()` needs to set
`ProxyEnable=0`/remove `ProxyServer` before touching the proxy process
(the golden rule). Chased this through several real, fixed bugs:

1. `execSync` with a concatenated string went through `cmd.exe`'s shell
   parsing and mangled the nested quotes → switched to `execFileSync`
   with an argv array. Confirmed fixed in isolation.
2. Even fixed, it failed again in the full flow. Ruled out (each with a
   real test, not a guess): VM resource contention (reproduced on a
   *fresh* snapshot), missing Defender exclusion (added it, still
   failed), and suspected AMSI flagging PowerShell script content that
   modifies proxy settings → switched the whole call to `reg.exe`
   (a plain Win32 tool, no AMSI). **Confirmed working in isolation** with
   the array-args + reg.exe combination.
3. **Still fails inside the actual `self-update.js` run**, in a way that
   bypasses even its own try/catch (the update log shows the process
   dying silently right after "Backed up current install," no further
   line). Could not reproduce this specific failure mode in a minimal
   standalone script no matter how closely I mirrored the real call.

**Where this leaves things:** every fail-safe property that actually
matters held in every single attempt, successful or not — no run ever
left the machine internet-less or in a corrupted state. But I cannot
respons­ibly claim the self-update mechanism itself works end-to-end.
**Recommendation for the next session:** don't chase this further on
this specific VM — the TCG software emulation (x86-on-ARM, since this
Mac is Apple Silicon) is the one variable that couldn't be controlled
for across ~2 dozen attempts, and may be introducing genuine child-process
timing flakiness that isn't representative of real hardware. Re-verify on
either real hardware or a differently-configured VM before trusting this
for the 40-machine rollout. If it fails there too in the same specific
way, that's the point to suspect a real, still-undiscovered bug rather
than the environment.

### The test VM itself (for continuing without rebuilding it)

- `~/vm/watcher-test-vm/` — QEMU-based (Homebrew `qemu`, TCG-emulated
  x86_64 since this Mac is Apple Silicon), Windows Server 2022 Standard
  Evaluation, fully unattended-installed from Microsoft's official eval
  ISO. SSH key at `ssh/watcher_vm_key`, reachable at `localhost:2222`,
  user `Administrator`.
- `boot.sh` (normal boot) / `install-boot.sh` (attaches install ISOs,
  only needed to rebuild from scratch) / `ssh_connect.sh "<command>"` /
  `screendump.sh` (visual check when headless SSH isn't enough).
- `windows-server-test-clean.qcow2.bak` is a snapshot of the VM
  immediately after Windows install + SSH setup, before anything
  watcher-related ever touched it. Restore with a plain `cp` over
  `windows-server-test.qcow2` before booting, for a genuinely clean run.
- **Known VM quirks, all confirmed real, not guessed:** PowerShell cold-starts
  routinely take 20-60s+ under this emulation (don't read a timeout under
  ~90s as a real hang without checking actual state first); Windows SSH does
  **not** kill remote processes when the local SSH client
  disconnects/times out — background downloads/installs that appear to
  "time out" are usually still running, check before retrying/killing;
  the `ScheduledTasks` PowerShell module can hang indefinitely on this VM,
  use `schtasks.exe` instead; one `AccessViolationException` crash in
  PowerShell's AMSI init was observed once under heavy resource pressure
  (17 stacked processes after a hung registration retry loop) — if that
  recurs, restore the clean snapshot rather than debug the degraded state.
- Node.js (bundled, not committed to git) has to be re-downloaded after
  every snapshot restore — `DownloadNode.ps1` works but is slow; the
  fastest path is to let it run, then shortcut-copy from
  `%TEMP%\node-watcher-extract\node-v20.18.0-win-x64\node.exe` to
  `WatcherBrain\node\node.exe` the moment it appears there, rather than
  waiting for the whole npm-bundled `node_modules` extraction to finish.

### Not started at all

- `watcher-fleet`'s actual acceptance criteria (AC1, AC5, AC6, AC8) —
  built and code-reviewed, never run. No Supabase project, no Vercel
  deploy, no real users created.
- `HubConfig.json` / real enrollment secret — never generated (the
  `.example.json` template exists; the real file is gitignored and
  doesn't exist anywhere yet).
- Print-spool cleanup script — never actually executed against a real
  Windows print spooler this session, only reasoned about.
- Trip date — still unknown, still not blocking, still needs Felix.
