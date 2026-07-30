# Keep a banca REPORTING to the hub through every power state it passes through
# (AC, battery, sleep, wake). Two Windows defaults make a machine go silent even
# though internet and the filter are fine:
#   1. Wi-Fi radio power-saving naps the adapter (esp. on battery) -> polls stop.
#   2. Sleep-on-AC suspends a plugged terminal -> it disappears until someone
#      wiggles the mouse.
# So force, on the ACTIVE power scheme:
#   - Wireless Adapter Power Saving Mode = Maximum Performance, for BOTH AC and DC.
#   - Standby (sleep) timeout on AC = 0 (never). Battery sleep is left ALONE on
#     purpose (don't accelerate a dying battery; the golden rule + resume handling
#     cover the wake).
#
# Always runs ELEVATED (powercfg needs it): at install from InstallWatcher (the elevated
# installer / Administrators), re-asserted every logon AS SYSTEM by the "WinConfig
# Cleanup At Logon" task (CleanPrintSpoolOncePerDay.bat), and — since plan 0010 — ~hourly
# AS SYSTEM by the "WinConfig Sync" poll task (poll-hub.js reassertHardeningIfDue). That
# last caller is the one that covers normal banca behaviour: the PC is left ON for days,
# hibernated or merely locked, and an onlogon trigger does NOT fire on resume or unlock,
# so the logon task alone can go a week without running. NOT the watchdog: the watchdog
# loop runs as BUILTIN\Users (least-privilege, to manage the per-user proxy) so powercfg
# would fail there. Both SYSTEM callers reach already-installed bancas via OTA
# (their files are OTA-updated and both tasks already exist) and self-heal a Windows reset.
# Changing power scheme values needs elevation, which a standard "banca" user
# does NOT have (so the cashier can't undo it either). Best-effort + idempotent: it
# never throws, and only writes to the log when it actually changes something. This is
# the power sibling of HardenPrinters.ps1.
#
# -Baseline = "this is the install-time first pass, not a guard hit" — mirrors
# HardenPrinters.ps1's switch exactly. At install the active scheme may legitimately
# arrive with Wi-Fi power-saving or sleep-on-AC still on (Windows/driver defaults), so
# correcting it is expected housekeeping and gets logged as informational
# ('power-hardened'). EVERY LATER run that has to re-flip it means something reverted
# it after we'd already hardened it, which is a tamper signal and gets logged as
# `tamper` so poll-hub.js forwards it to the fleet's red alert (setting=power).
#
# Exit-code contract (poll-hub.js reads this): 0 = VERIFIED-CLEAN (read+enforced, or
# already correct — nothing to change counts as clean), 2 = HARDEN-FAILED (tried to set
# but the re-read shows it did NOT take), 3 = SKIP/N-A (powercfg absent or the active
# scheme GUID could not be resolved — the setting could not be evaluated at all).
#
# GOLDEN-RULE NOTE: this script is orthogonal to filtering. It NEVER reads or writes
# ProxyEnable/ProxyServer, never starts/stops the proxy, never touches routing. It only
# adjusts power/radio config, so it is safe to run in any state (filtering, unplugged,
# mid-update).
#
# Idempotency is read from the REGISTRY, not `powercfg /query`: query output labels are
# LOCALIZED (the terminals run Spanish Windows -> "Indice de configuracion..."), so
# parsing English text would silently never match and never harden. The scheme GUID and
# the ACSettingIndex/DCSettingIndex DWORDs are locale-independent.
param([switch]$Baseline)

$ErrorActionPreference = 'SilentlyContinue'
$BrainDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$EventsPath = Join-Path $BrainDir 'events.log'

function Write-Event([string]$tag, [string]$detail) {
    try {
        $suffix = if ($detail) { " | $detail" } else { "" }
        $line = "[{0}] {1}{2}" -f (Get-Date).ToUniversalTime().ToString('o'), $tag, $suffix
        Add-Content -Path $EventsPath -Value $line -ErrorAction SilentlyContinue
    } catch {}
}

if (-not (Get-Command powercfg -ErrorAction SilentlyContinue)) {
    Write-Event 'power-guard-skip' 'powercfg no disponible'
    exit 3
}

# Stable, locale-independent GUIDs.
$WIFI_SUB  = '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'  # Wireless Adapter Settings
$WIFI_SET  = '12bbebe6-58d6-4636-95bb-3217ef867c1a'  # Power Saving Mode (0 = Maximum Performance)
$SLEEP_SUB = '238c9fa8-0aad-41ed-83f4-97be242c8f20'  # Sleep
$SLEEP_SET = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'  # Sleep after (STANDBYIDLE), seconds; 0 = never

# Resolve the active scheme GUID. `powercfg /getactivescheme` prints a localized name
# but the GUID itself is not localized, so match it by shape.
$activeGuid = $null
try {
    $raw = (& powercfg /getactivescheme 2>&1 | Out-String)
    $m = [regex]::Match($raw, '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})')
    if ($m.Success) { $activeGuid = $m.Groups[1].Value }
} catch {}

function Get-RegIndex([string]$scheme, [string]$sub, [string]$setting, [string]$valueName) {
    # Returns the persisted per-scheme index as [int], or $null if unreadable/unset.
    if (-not $scheme) { return $null }
    try {
        $key = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$scheme\$sub\$setting"
        $item = Get-ItemProperty -Path $key -Name $valueName -ErrorAction Stop
        return [int]$item.$valueName
    } catch { return $null }
}

# If the active scheme GUID couldn't be resolved we can't read the registry to know
# whether we're already hardened -- and a machine that yields no GUID from
# `powercfg /getactivescheme` wouldn't honor the writes either. Skip silently (no
# enforce, no log) so the per-logon re-assert can't churn the log with a blind
# 'power-hardened' every run — the setting could not be evaluated at all. Effectively
# unreachable on healthy Windows (the GUID is locale-independent, so the regex matches
# in any language).
if (-not $activeGuid) { exit 3 }

$changed   = @()   # CONFIRMED reverts: prior value was READABLE and non-zero, re-read now 0 -> tamper (non-baseline)
$corrected = @()   # enforced from an UNKNOWN/unreadable prior value -> informational only, NEVER tamper (cross-review:
                   # a transient/missing registry read must not fabricate a 'setting=power' tamper / false frequency alert)
$failed    = @()   # TRIED to set but re-read did NOT confirm 0 -> log 'power-harden-failed' (availability, not tamper)

# Every write below is VERIFIED by re-reading the registry, never trusted. powercfg needs
# elevation; if this ever runs without it (or a set silently fails) the value stays put.
# We only record success when the re-read confirms 0, and surface a falsifiable
# 'power-harden-failed' otherwise -- so a broken/under-privileged deploy is VISIBLE in the
# log instead of a silent false 'power-hardened'. (codex 0009 review.)

# --- Wi-Fi power saving = Maximum Performance (AC + DC) ---
# Enforce unless BOTH are already 0. Unknown (null) counts as "needs enforcing"
# (the Windows default is a power-saving mode, not max performance).
$acWifi = Get-RegIndex $activeGuid $WIFI_SUB $WIFI_SET 'ACSettingIndex'
$dcWifi = Get-RegIndex $activeGuid $WIFI_SUB $WIFI_SET 'DCSettingIndex'
# Could we actually READ the prior value? If not, enforcing is still right, but we must NOT call it a
# "revert" (tamper) — the original state was unknown, not confirmed flipped-back-on.
$wifiReadable = ($acWifi -ne $null) -and ($dcWifi -ne $null)
if (-not ($acWifi -eq 0 -and $dcWifi -eq 0)) {
    try {
        & powercfg /setacvalueindex SCHEME_CURRENT $WIFI_SUB $WIFI_SET 0 2>&1 | Out-Null
        & powercfg /setdcvalueindex SCHEME_CURRENT $WIFI_SUB $WIFI_SET 0 2>&1 | Out-Null
        & powercfg /setactive SCHEME_CURRENT 2>&1 | Out-Null
    } catch {}
    $acNow = Get-RegIndex $activeGuid $WIFI_SUB $WIFI_SET 'ACSettingIndex'
    $dcNow = Get-RegIndex $activeGuid $WIFI_SUB $WIFI_SET 'DCSettingIndex'
    if ($acNow -eq 0 -and $dcNow -eq 0) {
        if ($wifiReadable) { $changed += 'wifi=max-perf(AC+DC)' }   # prior known non-zero -> real revert
        else { $corrected += 'wifi=max-perf(AC+DC)' }              # prior unknown -> enforce, no tamper
    }
    else { $failed += 'wifi' }
}

# --- Never sleep on AC (battery sleep left untouched by design) ---
# `/change standby-timeout-ac` targets ONLY the AC index of the active scheme.
$acSleep = Get-RegIndex $activeGuid $SLEEP_SUB $SLEEP_SET 'ACSettingIndex'
$sleepReadable = ($acSleep -ne $null)
if ($acSleep -ne 0) {   # null (unknown) or non-zero -> enforce; exactly 0 -> already never, skip
    try {
        & powercfg /change standby-timeout-ac 0 2>&1 | Out-Null
    } catch {}
    if ((Get-RegIndex $activeGuid $SLEEP_SUB $SLEEP_SET 'ACSettingIndex') -eq 0) {
        if ($sleepReadable) { $changed += 'no-sleep-ac' }   # prior known non-zero -> real revert
        else { $corrected += 'no-sleep-ac' }                # prior unknown -> enforce, no tamper
    }
    else { $failed += 'no-sleep-ac' }
}

if ($changed.Count -gt 0) {
    if ($Baseline) {
        Write-Event 'power-hardened' ($changed -join ', ')
    } else {
        # `tamper` is the tag poll-hub.js lifts into tamper_events (cross-repo contract) → fleet.
        # `setting=power` is the dimension the fleet groups on. ONLY confirmed reverts (prior value
        # readable AND non-zero) reach here — enforced-from-unknown goes to $corrected below.
        Write-Event 'tamper' ("setting=power | revert de energia/Wi-Fi re-forzado: " + ($changed -join ', '))
    }
}
# Enforced from an unknown/unreadable prior state: informational, NEVER a tamper — a transient
# registry-read miss must not fabricate a false 'setting=power' frequency alert (cross-review).
if ($corrected.Count -gt 0) {
    Write-Event 'power-hardened' ('estado previo desconocido, forzado: ' + ($corrected -join ', '))
}
# A power set that did NOT take is an AVAILABILITY issue (the machine may sleep / stop reporting) —
# surfaced by the fleet's existing stale / "sin reportar" signal, NOT a ticket-retention theft. So it
# stays a local log line and does NOT emit a tamper (unlike the printer guard), keeping power off the
# red frequency ladder — consistent with M4 (power = resilience, caps at amber, not theft).
if ($failed.Count -gt 0) {
    Write-Event 'power-harden-failed' ('no aplico (elevacion?): ' + ($failed -join ', '))
    exit 2
}
exit 0
