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

## Update — 2026-07-09, Windows Service migration for Layer 2

Replaced Layer 2 (Task Scheduler's `RestartOnFailure` on the "Watcher Proxy
Loop" task — confirmed unreliable in the original handoff above) with a real
Windows Service (`WatcherProxySupervisor`, wrapped via WinSW) supervised by
SCM's own Recovery policy. Layer 1 and Layer 3 are untouched.

**A real, load-bearing discovery made by testing on the VM, not by
reasoning about it:** a Windows Service running as LocalSystem writes to
its OWN profile's `HKCU`, not the logged-in user's — confirmed by hand by
setting `ProxyEnable` from inside a LocalSystem service and observing the
interactive Administrator session's actual value never changed. This
would have silently broken the whole migration had it shipped as
originally scoped ("just wrap WatchdogLoop.ps1 in a service"). Also
confirmed a service CAN reach a specific logged-in user's hive correctly
via `HKEY_USERS\<their SID>` — same underlying hive `HKCU` aliases to for
whichever user a process runs as — but rather than build SID-resolution
logic into the service, the simpler fix was to keep the service
completely registry-free: its only job is `schtasks /run` on Layer 1's
existing task, which Task Scheduler already knows how to launch correctly
in the right user session (`LogonType=InteractiveToken`, unchanged).

**Verified end-to-end on the test VM, by running it:**
- `RegisterWatchdogTasks.ps1` (real script, not a mock) downloaded WinSW,
  registered the `WatcherProxySupervisor` service, and started it — exit
  code 0.
- `sc.exe qfailure` confirmed the Recovery policy applied exactly as
  designed: restart immediately, then 60s, then 60s, reset count after 1
  day (86400s).
- Killed the running `WatchdogLoop.ps1` process directly (`Stop-Process
  -Force`, simulating a crash). Within the supervisor's 5-second poll
  cycle it called `schtasks /run` and a **new** `WatchdogLoop.ps1` process
  came up (confirmed by PID changing: 3840 → 936) — the actual proof this
  design works, not just that the scripts ran without error.
- Confirmed the interactive Administrator's real `HKCU` `ProxyEnable`
  value continued being managed correctly by the relaunched process,
  unaffected by the new service.

**Not yet tested:**
- Interaction with `self-update.js` — an update replacing files while the
  supervisor service is active hasn't been exercised together this
  session.
- Behavior across an actual reboot (only a live-kill was tested, not a
  cold start with no one logged in yet — worth checking `StartWhenAvailable`
  interacts correctly with the service's own `start= auto` setting).
- Longer soak time (only tested immediately after install, not over hours).

## Handoff — 2026-07-10, Windows 11 VM built, two QA questions still open

Built a second test VM (`~/vm/win11-test-vm/`) specifically to settle two
open QA items that the Windows Server VM structurally can't answer: (1)
does the multi-user fix cause the watchdog to run twice when two people are
genuinely logged in at once, and (2) is the self-update silent-crash bug
Server/eval-build-specific or a real cross-version bug. **Neither question
got answered this session** — real progress was made, but the session ran
very long fighting VM/tooling issues, not the actual product logic.

**State to resume from:**
- The VM is a real, genuine Windows 11 Pro 25H2 install (via Fido, no MS
  account needed), built with QEMU on `~/vm/win11-test-vm/boot.sh`
  (disk-only, safe to reboot — do NOT use `install-boot.sh` again, that has
  the install ISOs attached and will re-trigger the Windows Setup boot menu).
  VNC console at `127.0.0.1:5902`, SSH intended for port 2223 (currently
  broken — see below). Administrator password: `W4tcherTest!2026`.
- **Confirmed root cause of no SSH access**: `Get-WindowsCapability -Online
  -Name OpenSSH.Server*` shows `State: NotPresent` — the OpenSSH Server
  capability never actually installed, despite `Add-WindowsCapability`
  reporting a false "success" (`RestartNeeded: False`) with no error. This
  is a real, reproducible Windows/DISM quirk worth knowing about
  independent of Watcher.
- **A real, separate, time-costly discovery**: this VNC session (via
  `vncdotool`) has a **keyboard input bug** — special/shifted characters
  (`$`, `:`, `!`, etc.) are unreliably transmitted through `type` (which is
  only documented to support alphanumeric anyway) AND through explicit `key
  shift-X` / named keysym calls (`colon`, `dollar` — tested directly,
  confirmed broken). Plain alphanumeric `type` and `key super`/`key
  ctrl-alt-del`/`key ctrl-shift-esc`/`key tab`/`key enter` all work
  reliably. **Do not re-attempt typing URLs or PowerShell `$variables`
  through this VNC connection** — it will not converge; this cost most of
  this session's time. Mouse clicks also don't work reliably on this VNC
  connection (coordinates don't land correctly, cursor doesn't render in
  captures) — keyboard-only navigation (Tab/Shift-Tab/Enter, Task Manager's
  Ctrl+Shift+Esc → "Run new task") is the only thing confirmed reliable.
- **Recommended next step, in order of promise**: (1) try RDP instead of
  VNC for console access — a real RDP client may not share this specific
  keyboard-encoding bug; (2) if RDP also fails, fix OpenSSH via a file
  written directly to the VM's disk offline (`qemu-nbd`/mount the qcow2
  while the VM is shut down) rather than through any live keyboard-driven
  session; (3) worst case, rebuild the VM with OpenSSH baked into the
  unattend answer file's `FirstLogonCommands` more robustly (retry loop
  already exists in `setup-ssh.ps1` but the underlying
  `Add-WindowsCapability` call needs the same investigation done here).
- Once a working shell into this VM exists (SSH or otherwise), the actual
  test plan is unchanged from what's described in the multi-user section
  below: deploy `WatcherBrain` to `C:\Watcher`, run
  `RegisterWatchdogTasks.ps1`, create a `banca` user, log Administrator in,
  confirm her watchdog fires, then Ctrl+Alt+Del → **Switch User** (not
  Sign out) to banca and check via `qwinsta` whether both sessions stay
  genuinely concurrent (unlike the Server VM, which logs the first user off
  entirely) — that's the actual unresolved question. Also re-run
  `self-update.js` here to compare against the Server VM's silent-crash
  signature.

**A second real bug found the same session, from Felix's own context about
real terminals**: some PCs have a separate admin (installer) account and a
"banca" worker account that actually logs in day-to-day. The watchdog
tasks' `<Principal>` had no explicit user, but Task Scheduler silently
bakes in whoever ran the installer as that task's specific run-as identity
(confirmed: `schtasks /query .../xml` showed Administrator's exact SID).
Since `InteractiveToken` requires that specific user to have an active
session, this could mean the watchdog fails to run at all during the
banca worker's own session on a two-account PC - the exact opposite of
protected. Fixed by binding both task templates and
`RegisterProxyLogonTask.ps1` to `GroupId = S-1-5-32-545` (`BUILTIN\Users`)
instead of an implicit specific user, and verified the fix took effect in
the real re-registered task's XML.

**Also re-tested self-update today, same VM, current code.** Still fails
the exact same way described in the original handoff above — but with a
sharper diagnosis this time. Ran `node self-update.js` directly (not via
poll-hub) and watched it live: logs "Update available" then "Backed up
current install," then nothing — no error line, no rollback attempt logged,
the node process itself simply gone afterward (confirmed via
`Get-CimInstance Win32_Process` — zero node processes running). This is
meaningfully different from earlier failed attempts logged from a prior
session, which DID get caught by the script's own try/catch and logged
"Update failed with an error, attempting rollback." This time nothing was
caught at all - strongly suggesting the process is dying at the native
level (a crash in or around the `execFileSync('reg.exe', ...)` call)
rather than throwing a normal, catchable JS error. Confirmed the fail-open
guarantee held regardless: `ProxyEnable` was `0` (unrestricted, the safe
direction) afterward, matching the golden rule even through an
uncontrolled crash. Still recommend re-testing on real hardware or a
non-TCG-emulated VM before trusting this for rollout - if it fails there
too with the exact same "dies silently right after backup, no JS error"
signature, that's the point to suspect a real Node/native bug rather than
this VM's emulation.

**Then fully verified live, not just at the config level.** Neither SSH
(creates no real WTS session at all) nor RDP `+auth-only` (authenticates
then disconnects before a session forms) were sufficient to test this -
both confirmed insufficient by trying them. What worked: booted the VM with
a VNC console (`-vnc 127.0.0.1:1`) and drove a real interactive logon as a
second "banca" user via `vncdotool`, at the actual LogonUI screen. Confirmed
a genuine, separate console session (ID 2 vs Administrator's ID 1), then
confirmed `WatchdogLoop.ps1`'s process owner was `WATCHER-TEST\banca` (via
`Win32_Process.GetOwner()`) and that banca's own `HKEY_USERS\<SID>` hive was
being actively managed. The fix works end-to-end for a genuinely different,
non-installer account, exactly the multi-user real-terminal scenario Felix
described. QA plan section F updated to ✅.

## Handoff — 2026-07-10 (later same day): self-update crash confirmed NOT TCG-specific

Built a third test VM specifically to settle the one remaining open
question from above: is the self-update silent-crash a TCG-emulation
artifact, or a real bug? This VM (`~/vm/win11-arm-vm/` via UTM, ARM64 host
+ ARM64 guest) uses **HVF hardware acceleration, not TCG software
emulation** — the opposite of every VM used in earlier retests.

**Result: the crash reproduces identically under HVF.** Forced an update
by setting the local `VERSION` file to `1.0.0` (repo's real `VERSION` and
GitHub's `main` branch `VERSION` both legitimately read `1.0.1`, so without
this the script silently no-ops by design — that's not a bug, see
`main()`'s `remoteVersion === localVersion` early return). Ran
`node self-update.js` directly:

```
Update available: 1.0.0 -> 1.0.1
Backed up current install to C:\Watcher\WatcherBrain\_backup_1.0.0_...
```

then nothing — no "New files copied in," no error, no rollback log line,
process gone. `update.log` matches the console exactly (just those two
lines), confirming it's not a display artifact. **`%errorlevel%` came back
`-1`** — notably not `1` (Node's normal uncaught-exception exit code),
which further supports the earlier hypothesis that this is a native-level
crash (something in or around the `downloadFile()` call right after the
backup step, since that's the next line in `main()`) rather than a
catchable JS exception. The script's own try/catch never fired.

**This settles the open question: the bug is real, not TCG-specific.**
Same signature, same missing log lines, same abrupt process death,
reproduced now across TCG emulation (x86-on-ARM), a genuine Windows Server
VM, and now HVF-accelerated ARM64-on-ARM64 — three different
virtualization backends and two different Windows editions. The next step
is instrumenting `downloadFile()` in `hub-client.js` (the call immediately
after the last successful log line) directly, since that's the prime
suspect, rather than continuing to re-test on different VMs.
