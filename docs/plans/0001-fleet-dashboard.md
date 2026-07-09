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
