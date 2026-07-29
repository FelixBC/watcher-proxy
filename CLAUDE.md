# watcher-proxy

Windows whitelist HTTP(S) proxy agent (Node.js), disguised as **"WinConfig"**, installed on
lottery-terminal ("banca") PCs. Filters browsing to a whitelist; everything else is blocked.
This repo is the **agent**. Its dashboard/hub sibling is `../watcher-fleet` (Next.js on Vercel +
Supabase) — the two are one system split across two repos. This repo is **public on GitHub**:
never commit plaintext secrets (see `.gitignore` for the actual list of excluded per-machine
state/credentials).

Full component map: `ARCHITECTURE.md`. Feature history/specs: `docs/plans/000N-*.md`. Live QA
checklist: `docs/qa-test-plan.md`. Read those for depth — this file is the map + the rules.

## Golden rule (the one invariant everything else defers to)

**Fail OPEN, never fail CLOSED.** On any proxy restart/update/error path: set Windows to normal
internet FIRST, then (re)start the proxy — never leave `ProxyEnable=1` pointing at a dead proxy,
because that means no internet at all. The filter is allowed to fail open (normal internet); the
connection itself must never fail closed. Full statement: `ARCHITECTURE.md` §Watchdog. Any change
touching `self-update.js`, `proxy-server.js`, the watchdog `.ps1` scripts, or `BackToNormal.bat`
must be checked against this before anything else.

## Cross-repo contract with watcher-fleet

Small HTTP contract, credential-authenticated after enroll. Both repos comment "cross-repo
contract" at the code sites below — grep that phrase if the shape ever needs re-checking.

- **Enroll** (`WatcherBrain/register-with-hub.js`, once at install) → fleet
  `POST /api/agent/register` (`src/app/api/agent/register/route.ts`). Body:
  `{master_code, hardware_id (Windows MachineGuid), label, custom_name, zone, banca_code}`.
  The hub scrypt-hash-compares `master_code` against `master_code_settings` — **the master code
  is set/rotated by Nelson in the fleet Settings page, not a hardcoded value**; treat any specific
  digit sequence you've seen as a point-in-time operational fact, not a contract constant. Returns
  `{machine_id, credential}`, or 401 (bad code) / 409 (this `hardware_id` already holds a
  credential — anti-hijack, see route.ts's H2 comment) / 429 (rate-limited) / 400 (bad body).
  **Gotcha:** identity is the `hardware_id`, so reinstalling on the same PC without first deleting
  its row in the dashboard → 409 → the new install never gets a credential → it's invisible.
- **Poll** (`WatcherBrain/poll-hub.js`, every ~2 min, SYSTEM task) → `POST /api/agent/poll`.
  Reports internet/proxy/filter state, `whitelist_version`, blocked logs, `recent_visits` (≤25),
  `first_visit` (con-ruido/sin-ruido), location (~hourly), tamper events, on-request diagnostics.
  Receives back the shared whitelist (only when the version differs — egress optimization), unplug
  state, diag/locate requests, and the latest `agent_version` + download URL + sha256 for OTA.
- **OTA self-update** (`WatcherBrain/self-update.js`): downloads the release the poll response
  pointed at (Supabase `agent-releases` bucket, published by `watcher-fleet/scripts/publish-agent.mjs`,
  keyed on this repo's `VERSION` file), verifies sha256, backs up, swaps files, restarts, health-checks,
  rolls back on failure. Single-flight lock + 3 retries. Never touches identity/secrets.
  **There is an active P0 here — see "Active work" below before touching this path.**
- **Shared whitelist**: fleet `whitelist_shared` table (versioned), pushed on poll when the version
  differs, additive-only on top of each machine's local `whitelist.txt` (never overwrites it) —
  merge logic in `WatcherBrain/whitelist-merge.js`.
- **The `/descargar` bundle**: `scripts/build-winconfig-bundle.sh` packages this repo (git-tracked
  + untracked-but-not-gitignored files, minus delivery tooling/dev docs — see the script's own
  EXCLUDE list) into `dist/winconfig-install.zip`, copied to `watcher-fleet/public/winconfig-install.zip`
  and served at `/descargar` (public, no login) for fresh installs.

## Standing rules

- **On every agent change:** bump `VERSION` → `scripts/build-winconfig-bundle.sh` → copy
  `dist/winconfig-install.zip` to `../watcher-fleet/public/` → from `watcher-fleet`:
  `vercel --prod --yes` → `node --env-file=.env.local scripts/publish-agent.mjs`. This keeps
  `/descargar` fresh for new installs; OTA is the safety net for already-installed machines.
- **No CI in either repo.** Nothing runs on push — the sequence above IS the release.
- **Secrets:** Felix runs all DB/secret commands himself (`publish-agent.mjs` needs
  `SUPABASE_SERVICE_ROLE_KEY`, `.env.local`). Never read/print `HubConfig.json`,
  `hub-credential.json`, `master-code.plain`, or any `.env*` — see `.gitignore` for the full list.

## Conventions worth knowing

- **The listen port IS the single-instance lock.** `proxy-server.js` binds a **per-machine OBSCURE
  port chosen at install** (e.g. `49732` on the test PC) — `8080` is only the in-code default; the
  actually-bound port is persisted via `writeChosenPort`/`readChosenPort` so every checker/setter
  (`CheckPort.*`, the watchdog, `SetProxyByAvailability.ps1`) agrees on it. A sibling already
  listening → `EADDRINUSE` → clean `exit(0)` (intentional — handles the logon-herd case where
  multiple triggers race to start the proxy). See `docs/plans/0006` for why this same handler is
  mid-fix.
- **Disguise + Hidden+System EPERM:** installed files carry `+h +s`. Node's `writeFileSync`/
  `copyFileSync` (CREATE_ALWAYS) throw EPERM against them — rewrite in place instead with
  `openSync('r+')` + `ftruncateSync` + `writeSync`.
- **Poll runs as SYSTEM + battery-safe** (scheduled task) — a laptop on battery otherwise never
  polls.
- **`BackToNormal.bat`** = the uninstall/reset. Gated by a code check that runs FIRST, before
  anything else (tamper log, poll ping, registry/task changes) — a wrong/blank code leaves the
  machine fully untouched. Accepts the per-machine master-code-derived hash (`uninstall-code.hash`,
  gitignored, per-machine) OR a fleet-wide emergency-code hash committed at
  `WatcherBrain/emergency-code.hash` (salted scrypt, no plaintext ever in the repo — this is the
  anti-brick path: works with no internet and no master code on hand). Fails open; finishes in one
  window if already elevated.
- **Install locations:** the hosted bootstrapper (`install.ps1`) always extracts to
  `C:\WinConfig` (enforced by the zip's fixed `WinConfig/` top folder). A manual `/descargar`
  install runs **in place**, wherever the zip was extracted (`InstallWatcher.bat` uses `%~dp0`).

## Active work — read before touching self-update/proxy-server/watchdog

`docs/plans/0006-selfupdate-loop-fix.md` — **LOCKED, in build** (2026-07-24). A real OTA loop was
observed on the test PC: killing the old proxy leaves the port held by the OS for minutes, the new
proxy's `EADDRINUSE` handler exits instead of retrying, the 15s health check fails, and rollback +
un-cooled re-poll loops with the filter fail-open (~44 min live) — with two fail-closed edges that
can also cut internet entirely. Fix touches `proxy-server.js`, `CheckPort.ps1`, `self-update.js`.
Gate: reviewer-separate + a live repro on the test PC as the E2E gate before re-publishing OTA.
Ships as v1.0.29, must supersede/retire the v1.0.28 `agent_release` row. Check this plan's status
before assuming the current `VERSION`/OTA state.

## QA & debugging workflow

- **Loop:** agent-dev deploys watcher-fleet + publishes the agent → Felix installs on the physical
  test PC and QAs → verify via the fleet dashboard + SSH into the test PC
  (`ssh -i ~/.ssh/watcher_testpc_key fcmag@10.0.30.222`, PowerShell 5.1, install at
  `C:\Users\fcmag\Downloads\winconfig-install\WinConfig`).
- **The test PC IS the fleet's `staging` machine** (it carries `WatcherBrain/staging.flag`), and it is
  a DEDICATED box for trying things, sitting next to Felix — not a banca serving customers. Two
  consequences worth knowing before asking him for anything:
    - Publishing a release is already the whole staging test. A staging machine is served the new
      version on its next poll **regardless of its hash ring**, runs the acceptance self-test, and
      opens ring 0 by itself once it bakes healthy (`STAGING_BAKE_MS`, ~45 min). Nothing needs
      forcing — `forceOpenRing0` only skips that gate, it doesn't make anything else happen.
    - It is also the ONLY machine, and it is excluded from the ring health judgment (`is_staging`),
      so the cron's auto-advance can never fire (it needs ≥3 awake on-target non-staging machines).
      Ring advance past 0 is manual in `/rollout`, and "no machines to test rings 1-2" is expected,
      not a fault. More VMs would not fix it: ring 0 is 5% of the fleet by `fnv1a32(hardware_id)`.
- **SSH to it is a STANDING capability, not a favour to request.** The box is always powered and
  beside Felix, always on the same LAN as the Mac, with SSH always enabled and the session holding a
  full admin token (so remote elevated installs work). Never ask him to read something off it that
  SSH can read — **connect and look**. Readable with no hub credential at all: `VERSION`,
  `staging.flag`, `selftest-state.json` (per-invariant pass/fail), `update-failed.json`,
  `update.log` (the blue-green cutover narrates itself there), and the live port from
  `proxy-port.txt` (never assume 8080). **Reachability moves:** `10.0.30.222` is current; some plan
  docs say `10.0.0.72` from a stint on another network — try both before concluding it is down.
- **Three verification lanes, blind in different ways — pick the right one, not the convenient one.**
  SSH sees internal state but never a pixel. Felix's eyes on the physical screen see what a banca
  worker sees — flashing black windows, popups, the wizard — and nothing internal; he has the machine
  right there, so a 5-second eyeball is cheap, and it is the ONLY way to check those. The hub
  dashboard shows what the fleet *believes* (rings, stable, `os_version`) and needs HIS session,
  since every `/rollout` action goes through `requireAdmin()`. Ask him only for what SSH structurally
  cannot see.
- **Running PowerShell over SSH:** pass `powershell -NoProfile -NonInteractive -EncodedCommand
  <base64-UTF16LE>` instead of an inline script. Anything non-trivial gets mangled by the
  zsh → ssh → PowerShell quoting chain (a bare `-Tail` was read as a command named `tail`); write
  the script to a file, `iconv -f UTF-8 -t UTF-16LE | base64`, and send that. Output carries a
  `#< CLIXML` progress wrapper — grep your own `KEY=value` markers rather than parsing positionally.
- **Deep-bug method:** cross-review between this agent (Fable) and Codex (`codex exec`) before
  shipping a fix in a risk-surface area (self-update, watchdog, uninstall gate).
