# 0009 — Power resilience, persistent + all-machines (`HardenPower`)

**Status:** LOCKED, in build (2026-07-29). Gear: SINGLE-CONCERN (one area — the
agent's environment-hardening + its install/watchdog wiring; no money/auth/
tenancy/ADR surface). Reviewer-separate + a live HW check across power states is
the gate before shipping.

Ships as **v1.0.31** through the normal release + OTA pipeline. The staging gate
(plan 0003) validates it on the staging PC before it opens to any banca.

## Problem (one sentence)

A banca must keep **reporting to the hub through every power state** it passes
through (AC, battery, low battery, sleep, wake) — but Windows' Wi-Fi radio
power-saving naps the adapter and sleep-on-AC suspends the machine, so a banca
can go silent ("sin conexión") even though internet and the filter are fine; and
until now the only fix was a manual `powercfg` on one machine, which does not
travel to the product, does not reach existing bancas, and is lost on a reset.

## Background (why now)

On the staging laptop (2026-07-28) a ~6.5h gap in reporting was traced to: sleep
+ a proxy crash on wake (golden rule recovered filtering in 13s) + the Wi-Fi
radio power-saving napping the adapter on battery + battery-saver throttling the
scheduler. A manual `powercfg` set Wi-Fi = Max Performance and fixed that one
machine — but that violated the standing rule *"nunca resuelvas algo solo para
una máquina manualmente."* An environment setting must live in the agent,
idempotent, and be re-asserted, so it is identical on every machine and persists.
Canonical precedent in this repo: `HardenPrinters.ps1` ("Keep printed documents
= OFF") — enforced at install + re-asserted continuously, best-effort +
idempotent.

## Locked decisions (Felix, "como recomiendas", 2026-07-29)

- **A — Scope:** Wi-Fi power-saving = **Máximo rendimiento** (AC **and** DC) **+
  no dormir en AC** (`standby-timeout-ac 0`). On **battery**, sleep is left
  enabled (do not accelerate a dying battery; the golden rule + resume handling
  already cover the wake).
- **B — Re-assert vehicle:** the existing **SYSTEM logon task** ("WinConfig
  Cleanup At Logon" → `CleanPrintSpoolOncePerDay.bat`), which already re-asserts
  `HardenPrinters.ps1` every logon — HardenPower is called right next to it.
  **Correction (codex 0009 review):** decision B originally named the *watchdog*,
  on the assumption it runs as SYSTEM. It does NOT — the watchdog task runs as
  `BUILTIN\Users` / `LeastPrivilege` (by design, so it can manage the user's HKCU
  proxy), so a child `powercfg` would fail for a standard banca user. The
  logon-cleanup task runs `/ru SYSTEM /rl highest`, which is exactly why the
  "keep printing history" precedent uses IT, not the watchdog. It still satisfies
  the OTA-reach concern that drove decision B: the task already exists on
  installed bancas and its `.bat` is OTA-updated, so HardenPower reaches them with
  **no new task to register**. Plus an enforce at install (elevated) for new
  machines.
- **C — Battery-saver scheduler throttle at critically-low battery:** **accepted
  as inherent** (the machine is about to die anyway; the golden rule protects the
  filter; reporting resumes on AC/wake). Not fought.

## Acceptance criteria

1. `WatcherBrain/HardenPower.ps1` exists, runs as SYSTEM, and when run:
   - sets the **active power scheme's** Wi-Fi power-saving (subgroup
     `19cbb8fa-5279-450e-9fac-8a3d5fedd0c1`, setting
     `12bbebe6-58d6-4636-95bb-3217ef867c1a`) to **0 (Máximo rendimiento)** for
     **both** AC and DC, and activates the scheme;
   - sets **standby-timeout-ac** to **0** (never sleep on AC), leaving DC
     (battery) sleep untouched;
   - is **idempotent** — a second run makes no change and writes **nothing** to
     `events.log` (only logs when it actually changes something);
   - is **best-effort** — never throws, always `exit 0`, skips quietly if a
     command/subgroup is unavailable (mirrors `HardenPrinters.ps1`);
   - **never** touches the proxy, `ProxyEnable`, `ProxyServer`, routing, or any
     filter state (golden-rule-orthogonal).
2. It is **enforced at install** (`InstallWatcher.bat`, next to the
   `HardenPrinters.ps1` call) so a fresh install is hardened immediately.
3. It is **re-asserted every logon by the SYSTEM logon-cleanup task**
   (`CleanPrintSpoolOncePerDay.bat`, run `/ru SYSTEM /rl highest`), so it has the
   elevation `powercfg` requires and a Windows reset self-heals at the next logon.
   Each write is **verified by re-reading the registry**: a confirmed flip logs
   `power-hardened`; a write that did not take (e.g. no elevation) logs a
   falsifiable `power-harden-failed` instead of a silent false success.
4. It **reaches already-installed bancas via OTA**: `HardenPower.ps1` is
   git-tracked (not gitignored, not bundle-excluded); `self-update.js`'s
   `copyTree` creates new files, so the script and the updated watchdog land
   together on the next update. (Verified: `copyTree(tempExtract, ROOT_DIR)`
   copies new entries, not only overwrites.)
5. `VERSION` bumped `1.0.30` → `1.0.31`.
6. Verified on real hardware: after a run, `powercfg /query` shows the Wi-Fi
   power-saving AC+DC index = `0` and `standby-timeout-ac` = `0`; a second run is
   a no-op (nothing new in `events.log`).

## Non-goals (explicit)

- **Not** fighting battery-saver throttling at critically-low battery (decision
  C — accepted as inherent).
- **Not** disabling sleep on **battery** (decision A — battery sleep stays).
- **Not** touching the proxy/self-update/golden-rule paths at all. This change
  adds an orthogonal environment enforcer + two call-sites; it does not alter
  filtering, cutover, or the fail-open floor.
- **Not** a new scheduled task, and **not** the watchdog (decision B — the
  existing SYSTEM logon-cleanup task is the vehicle).
- **Not** collecting OS version — that is a separate, parked item (report
  `os_version` in the poll, not a scout link).

## Contracts & ADR-locked areas touched

- **Golden rule** (`CLAUDE.md`, `ARCHITECTURE.md` §Watchdog): the final change
  does **not touch** `WatchdogLoop.ps1` at all (an earlier draft did; removed
  after the codex review — see decision B). It touches only `HardenPower.ps1`
  (new, orthogonal to filtering — never reads/writes `ProxyEnable`/`ProxyServer`,
  never starts/stops the proxy), `CleanPrintSpoolOncePerDay.bat` (one line next to
  the existing `HardenPrinters.ps1` call), and `InstallWatcher.bat` (one line). No
  golden-rule path is modified.
- No cross-repo contract (`watcher-fleet`) change. No DB. No secrets.

## Open questions

None. A/B/C locked; reachability verified; placement identified.

## Verification plan

- Static: PowerShell parse (`[ScriptBlock]::Create`) of both scripts; confirm
  `HardenPower.ps1` never throws (every external call wrapped / `SilentlyContinue`).
- Separate reviewer: an Opus subagent + `codex exec` (repo doctrine for
  golden-rule-adjacent changes), findings applied.
- HW: SSH the test PC, run `HardenPower.ps1`, assert the two `powercfg` values,
  assert idempotency (2nd run logs nothing). Then Felix owns git/release/OTA;
  staging validates before ring 0.
