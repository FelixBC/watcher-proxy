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
# never throws, always exits 0, and only writes to the log when it actually changes
# something. This is the power sibling of HardenPrinters.ps1.
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
    exit 0
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
# 'power-hardened' every run. Effectively unreachable on healthy Windows (the GUID is
# locale-independent, so the regex matches in any language).
if (-not $activeGuid) { exit 0 }

$changed = @()   # settings this run actually FLIPPED (verified by re-read) -> log 'power-hardened'
$failed  = @()   # settings we TRIED to set but that did NOT take -> log 'power-harden-failed'

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
if (-not ($acWifi -eq 0 -and $dcWifi -eq 0)) {
    try {
        & powercfg /setacvalueindex SCHEME_CURRENT $WIFI_SUB $WIFI_SET 0 2>&1 | Out-Null
        & powercfg /setdcvalueindex SCHEME_CURRENT $WIFI_SUB $WIFI_SET 0 2>&1 | Out-Null
        & powercfg /setactive SCHEME_CURRENT 2>&1 | Out-Null
    } catch {}
    $acNow = Get-RegIndex $activeGuid $WIFI_SUB $WIFI_SET 'ACSettingIndex'
    $dcNow = Get-RegIndex $activeGuid $WIFI_SUB $WIFI_SET 'DCSettingIndex'
    if ($acNow -eq 0 -and $dcNow -eq 0) { $changed += 'wifi=max-perf(AC+DC)' }
    else { $failed += 'wifi' }
}

# --- Never sleep on AC (battery sleep left untouched by design) ---
# `/change standby-timeout-ac` targets ONLY the AC index of the active scheme.
$acSleep = Get-RegIndex $activeGuid $SLEEP_SUB $SLEEP_SET 'ACSettingIndex'
if ($acSleep -ne 0) {   # null (unknown) or non-zero -> enforce; exactly 0 -> already never, skip
    try {
        & powercfg /change standby-timeout-ac 0 2>&1 | Out-Null
    } catch {}
    if ((Get-RegIndex $activeGuid $SLEEP_SUB $SLEEP_SET 'ACSettingIndex') -eq 0) { $changed += 'no-sleep-ac' }
    else { $failed += 'no-sleep-ac' }
}

if ($changed.Count -gt 0) {
    Write-Event 'power-hardened' ($changed -join ', ')
}
if ($failed.Count -gt 0) {
    Write-Event 'power-harden-failed' ('no aplico (elevacion?): ' + ($failed -join ', '))
}
exit 0
