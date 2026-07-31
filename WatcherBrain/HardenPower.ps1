# Keep a banca REPORTING to the hub through every power state it passes through
# (AC, battery, sleep, wake). THREE Windows defaults make a machine go silent even
# though internet and the filter are fine:
#   1. Wi-Fi radio power-saving naps the adapter (esp. on battery) -> polls stop.
#   2. Sleep-on-AC suspends a plugged terminal -> it disappears until someone
#      wiggles the mouse.
#   3. Hibernate-on-AC (default 3h idle) drops a plugged terminal to S4 -> same
#      disappearance, and this one survives everything short of a keypress.
# So force, on the ACTIVE power scheme:
#   - Wireless Adapter Power Saving Mode = Maximum Performance, for BOTH AC and DC.
#   - Standby (sleep) timeout on AC = 0 (never). Battery sleep is left ALONE on
#     purpose (don't accelerate a dying battery; the golden rule + resume handling
#     cover the wake).
#   - Hibernate timeout on AC = 0 (never), battery likewise left ALONE (plan 0012).
#
# Why BOTH sleep and hibernate (plan 0012 — do not "simplify" this back to one):
# STANDBYIDLE and HIBERNATEIDLE are SEPARATE settings. On a Modern Standby (S0)
# machine the classic "Sleep after" is inert, and what actually drops the box to S4
# is HIBERNATEIDLE — the "Doze to Hibernate" transition. Plan 0009 set only the
# standby knob, so from v1.0.31 to v1.0.33 every plugged banca still went dark after
# 3h idle; measured on the test PC 2026-07-31 (last activity 19:12 -> hibernate 22:13,
# exactly the 10800s default, 13h without a poll). Setting one without the other
# looks correct and fixes nothing on S0 hardware.
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
$HIBER_SET = '9d7815a6-7ee4-497e-8888-515a05f02364'  # Hibernate after (HIBERNATEIDLE), seconds; 0 = never

# Per-machine "we have already forced hibernate on this box at least once" marker (plan 0012).
# Gitignored runtime state: it must never travel in the /descargar bundle, or a fresh install
# would arrive pre-baselined and swallow the FIRST real revert as housekeeping.
$HiberBaselinePath = Join-Path $BrainDir 'hibernate-baselined.flag'

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

function Set-HiberBaseline {
    # Stamp "this machine has had hibernate forced at least once" (plan 0012). Returns $true if
    # the marker is present afterwards, $false if the write failed.
    #
    # A failure here is NOT cosmetic and must not pass silently (codex 0012 review, P2-1): with no
    # marker, the NEXT genuine revert is re-classified as a first touch and never reaches the fleet
    # as tamper — the guard would keep reporting "clean" while having quietly lost its ability to
    # detect the thing it exists to detect. So the caller routes a failure into the exit-2 path,
    # exactly like a powercfg write that did not take. Same doctrine as the rest of this script:
    # a broken deploy must be VISIBLE in the log, never a silent false success.
    try {
        if (-not (Test-Path $HiberBaselinePath -PathType Leaf)) {
            Set-Content -Path $HiberBaselinePath -Value ((Get-Date).ToUniversalTime().ToString('o')) -ErrorAction Stop
        }
        # Verified by RE-READING, never trusted. -PathType Leaf on purpose: a bare Test-Path also
        # answers $true for a DIRECTORY of that name, which would let a non-file masquerade as a
        # valid marker and silently re-arm the first-touch rule forever.
        return (Test-Path $HiberBaselinePath -PathType Leaf)
    } catch { return $false }
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
$markerFailed = $false   # plan 0012: the baseline marker could not be written -> future revert detection is
                         # degraded, so this must NOT report clean (codex 0012 review, P2-1)

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

# --- Never hibernate on AC (battery hibernation left untouched by design) ---
# `/change hibernate-timeout-ac` targets ONLY the AC index of the active scheme, exactly like
# its standby sibling above. This is the knob plan 0009 missed; see the Modern Standby note in
# the header for why setting standby alone fixed nothing on S0 hardware.
#
# FIRST-TOUCH RULE (plan 0012). On a machine whose HIBERNATEIDLE is PERSISTED in the registry
# (an OEM image, or an admin who opened the power options), the first run of this block sees a
# READABLE NON-ZERO prior and the classification below would read it as "someone reverted it"
# and emit a `tamper`. poll-hub.js invokes this script WITHOUT -Baseline (only InstallWatcher.bat
# passes it), so shipping that naively would raise a red MANIPULADA on those machines the same
# night the fix lands — the exact false positive this change exists to remove. So: the first time
# we ever force this knob on a given box is housekeeping; only a revert AFTER that is tamper. The
# marker, not -Baseline, is what separates them, because the OTA'd machines that need the
# distinction are precisely the ones that never see -Baseline.
#
# MEASURED, so nobody re-derives it (test PC, 2026-07-31): the active scheme's Sleep subgroup had
# only ONE child, 29f6c1db (STANDBYIDLE=0, written by plan 0009). HIBERNATEIDLE had NO registry
# entry at all — the 3h that `powercfg /q` reports there is the scheme's INHERITED DEFAULT, not a
# persisted value. On such a box Get-RegIndex returns $null, $hiberReadable is $false, and the
# pre-existing $corrected path would already have prevented the false tamper on its own. The
# marker therefore protects the persisted-value subset, not the whole fleet.
$hiberBaselined = Test-Path $HiberBaselinePath -PathType Leaf
$acHiber = Get-RegIndex $activeGuid $SLEEP_SUB $HIBER_SET 'ACSettingIndex'
$hiberReadable = ($acHiber -ne $null)
if ($acHiber -ne 0) {   # null (unknown) or non-zero -> enforce; exactly 0 -> already never, skip
    try {
        & powercfg /change hibernate-timeout-ac 0 2>&1 | Out-Null
    } catch {}
    if ((Get-RegIndex $activeGuid $SLEEP_SUB $HIBER_SET 'ACSettingIndex') -eq 0) {
        # Real revert only if the prior value was READABLE, non-zero AND this box was already
        # baselined. First touch (or an unreadable prior) is informational, never tamper.
        if ($hiberReadable -and $hiberBaselined) { $changed += 'no-hibernate-ac' }
        else { $corrected += 'no-hibernate-ac' }
        if (-not (Set-HiberBaseline)) { $markerFailed = $true }
    }
    else { $failed += 'no-hibernate-ac' }
}
elseif (-not $hiberBaselined) {
    # Already 0 before we ever touched it (an admin or the OEM image got there first). Stamp the
    # marker anyway, or the NEXT revert would be swallowed as a first touch and never reach the
    # fleet. Writes no log line on success, so idempotency (AC3) holds.
    if (-not (Set-HiberBaseline)) { $markerFailed = $true }
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
# The power VALUES may all be correct and still leave this guard half-built: without its baseline
# marker, the next genuine hibernate revert would be misread as a first touch and never reported
# (plan 0012 / codex P2-1). That is a degraded guard, not a clean one, so it takes the same exit-2
# path — poll-hub.js then refuses to stamp guards-ok.txt and the machine stops claiming "verified".
if ($markerFailed) {
    Write-Event 'power-harden-failed' 'marcador hibernate-baselined no se pudo escribir: la deteccion de un revert futuro queda degradada'
    exit 2
}
exit 0
