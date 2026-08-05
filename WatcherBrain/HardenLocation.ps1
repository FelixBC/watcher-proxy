# Keep a banca's LOCATION reporting to the hub, and treat turning it off as tamper.
# The fleet needs each station's location; Windows lets a user (or a cleaner tool)
# silently kill it five ways, so force + re-assert all five, exactly like
# HardenPower.ps1 / HardenPrinters.ps1 do for their settings (verified on the test
# PC, Win11 build 26200 — the "on" values below are Allow / Status=1 / Automatic+
# Running / GPO absent):
#   1. Master location consent (Settings > Privacy > Location): ConsentStore\location Value = Allow
#   2. Desktop-app consent (this agent's GetLocation probe is a Win32 app): ...\NonPackaged Value = Allow
#   3. The Geolocation service (lfsvc): Configuration\Status = 1, service Automatic + Running
#   4. Group Policy "Turn off location": Policies\...\LocationAndSensors DisableLocation must be 0/absent
#      (DisableLocation=1 overrides the consent keys no matter what, so it MUST be cleared).
#   5. PER-USER consent: HKU\<user>\...\ConsentStore\location Value = Allow — the toggle a user flips
#      in Settings is the per-user one, so HKLM='Allow' alone is NOT enough if HKU\<user>='Deny'.
# Registry ground-truth over the Settings UI, same discipline as HardenPower.ps1.
#
# Always ELEVATED (HKLM writes + Set-Service need it): at install from InstallWatcher
# (-Baseline), and ~hourly AS SYSTEM by the poll task (poll-hub.js reassertHardeningIfDue) —
# the caller that covers a banca left on for days. Best-effort + idempotent: never throws,
# only logs when it changes something. This replaces the old one-shot EnableLocation.ps1.
#
# -Baseline = install-time first pass (housekeeping, not a guard hit). A per-machine
# 'location-baselined.flag' (gitignored) makes EVERY later machine — including one that
# first sees this guard via OTA — treat its first pass as housekeeping too, so the OTA
# debut is never a false tamper. After the baseline, a lever found DISABLED and flipped
# back is a `tamper` event (setting=location) forwarded to the fleet's red alert.
#
# Exit-code contract (poll-hub.js reads this): 0 = VERIFIED-CLEAN (read+enforced or already
# correct), 2 = HARDEN-FAILED (set but the re-read shows it did NOT take), 3 = SKIP/N-A
# (the lfsvc Geolocation service does not exist on this image — location can't be evaluated).
#
# GOLDEN-RULE NOTE: orthogonal to filtering. Never touches ProxyEnable/ProxyServer, the
# proxy, or routing. Safe to run in any state (filtering, unplugged, mid-update).
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

$ConsentKey     = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'
$NonPackagedKey = Join-Path $ConsentKey 'NonPackaged'
$SvcConfigKey   = 'HKLM:\SYSTEM\CurrentControlSet\Services\lfsvc\Service\Configuration'
$GpoKey         = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors'
$BaselinePath   = Join-Path $BrainDir 'location-baselined.flag'

# N/A: no Geolocation service on this image -> location can't be evaluated at all.
if (-not (Get-Service -Name lfsvc -ErrorAction SilentlyContinue)) {
    Write-Event 'location-guard-skip' 'lfsvc no existe'
    exit 3
}

# Read a registry value; $null if the key/value is unreadable or absent.
function Get-RegValue([string]$key, [string]$name) {
    try { return (Get-ItemProperty -Path $key -Name $name -ErrorAction Stop).$name } catch { return $null }
}

# First pass = install (-Baseline) OR this machine has never been through the guard
# (marker absent). Computed BEFORE enforcing, so an OTA debut is never a false tamper.
$firstPass = $Baseline -or (-not (Test-Path -LiteralPath $BaselinePath -PathType Leaf))

$changed = $false          # did we have to write anything?
$confirmedRevert = $false  # was a lever CONFIRMED-readable in a disabled state? (the tamper signal)
$details = @()

# --- 1 + 2: consent (master + desktop apps). Disabled value is the string 'Deny'. ---
foreach ($pair in @(@{ Key = $ConsentKey; Label = 'consent' }, @{ Key = $NonPackagedKey; Label = 'desktop-apps' })) {
    $cur = Get-RegValue $pair.Key 'Value'
    if ($cur -ne 'Allow') {
        if ($cur -eq 'Deny') { $confirmedRevert = $true }   # readable + explicitly denied
        New-Item -Path $pair.Key -Force | Out-Null
        Set-ItemProperty -Path $pair.Key -Name 'Value' -Value 'Allow' -Type String
        $changed = $true
        $details += $pair.Label
    }
}

# --- 3: lfsvc service config Status + start type + running. ---
$status = Get-RegValue $SvcConfigKey 'Status'
if ($status -ne 1) {
    if ($null -ne $status -and [int]$status -eq 0) { $confirmedRevert = $true }
    New-Item -Path $SvcConfigKey -Force | Out-Null
    Set-ItemProperty -Path $SvcConfigKey -Name 'Status' -Value 1 -Type DWord
    $changed = $true
    $details += 'svc-status'
}
$svc = Get-Service -Name lfsvc -ErrorAction SilentlyContinue
if ($svc) {
    if ($svc.StartType -ne 'Automatic') {
        if ($svc.StartType -eq 'Disabled') { $confirmedRevert = $true }
        Set-Service -Name lfsvc -StartupType Automatic
        $changed = $true; $details += 'svc-starttype'
    }
    if ($svc.Status -ne 'Running') {
        Start-Service -Name lfsvc
        $changed = $true; $details += 'svc-start'
    }
}

# --- 4: GPO override. DisableLocation=1 force-disables regardless of consent -> must be 0/absent. ---
$gpo = Get-RegValue $GpoKey 'DisableLocation'
if ($null -ne $gpo -and [int]$gpo -ne 0) {
    $confirmedRevert = $true
    Set-ItemProperty -Path $GpoKey -Name 'DisableLocation' -Value 0 -Type DWord
    $changed = $true; $details += 'gpo-disablelocation'
}

# --- 5: PER-USER consent. The "Location services" toggle a user actually flips in Settings is the
# PER-USER ConsentStore key, NOT the machine-wide one in step 1 — a machine can read HKLM='Allow'
# while HKU\<user>='Deny', which turns location OFF for that user and gives GetLocation no fix.
# Enforce it for every LOADED user hive (the banca user + SYSTEM). Only touch hives that ALREADY
# have the key and only flip a confirmed 'Deny' — never create one where Windows didn't. SYSTEM
# (this process) can write any loaded hive; a banca stays logged on for days so its hive is loaded.
$UserConsentRel = 'SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'
foreach ($hive in (Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue)) {
    $sid = $hive.PSChildName
    if ($sid -match '_Classes$') { continue }
    if ($sid -ne 'S-1-5-18' -and $sid -notmatch '^S-1-5-21-') { continue }
    $ukey = "Registry::HKEY_USERS\$sid\$UserConsentRel"
    if (-not (Test-Path -LiteralPath $ukey)) { continue }
    $ucur = (Get-ItemProperty -LiteralPath $ukey -Name 'Value' -ErrorAction SilentlyContinue).Value
    # Only fix an explicit 'Deny' — a user hive is theirs; don't overwrite 'Prompt' or an unknown/
    # corrupt value (Codex P1). 'Deny' is the clear "location off" state and the only tamper here.
    if ($ucur -eq 'Deny') {
        $confirmedRevert = $true
        Set-ItemProperty -LiteralPath $ukey -Name 'Value' -Value 'Allow' -Type String
        $changed = $true; $details += 'user-consent'
    }
}

# --- Verify the enforcement actually took (re-read), only if we wrote something. ---
if ($changed) {
    $okConsent = (Get-RegValue $ConsentKey 'Value') -eq 'Allow'
    $okDesktop = (Get-RegValue $NonPackagedKey 'Value') -eq 'Allow'
    $okStatus  = ([int](Get-RegValue $SvcConfigKey 'Status')) -eq 1
    $gpoNow    = Get-RegValue $GpoKey 'DisableLocation'
    $okGpo     = ($null -eq $gpoNow -or [int]$gpoNow -eq 0)
    # Also verify the SERVICE ended up runnable — a swallowed Set-Service/Start-Service would
    # otherwise let the guard report clean while lfsvc is disabled/stopped (Codex P1). Allow
    # StartPending (an async start still in progress); only Stopped/Disabled are failures.
    $svcNow    = Get-Service -Name lfsvc -ErrorAction SilentlyContinue
    $okSvc     = $svcNow -and $svcNow.StartType -ne 'Disabled' -and $svcNow.Status -ne 'Stopped'
    # Per-user consent (step 5): no loaded hive should still read 'Deny' after enforcement.
    $okUsers = $true
    foreach ($hive in (Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue)) {
        $sid = $hive.PSChildName
        if ($sid -match '_Classes$') { continue }
        if ($sid -ne 'S-1-5-18' -and $sid -notmatch '^S-1-5-21-') { continue }
        $ukey = "Registry::HKEY_USERS\$sid\$UserConsentRel"
        if ((Test-Path -LiteralPath $ukey) -and (Get-ItemProperty -LiteralPath $ukey -Name 'Value' -ErrorAction SilentlyContinue).Value -eq 'Deny') { $okUsers = $false }
    }
    if (-not ($okConsent -and $okDesktop -and $okStatus -and $okGpo -and $okSvc -and $okUsers)) {
        Write-Event 'location-guard-fail' ('no tomo: ' + ($details -join ','))
        exit 2
    }
}

# --- Stamp the baseline marker on any successful pass (even a clean one), so this
# machine is "under the guard" and future reverts count as tamper. ---
if (-not (Test-Path -LiteralPath $BaselinePath -PathType Leaf)) {
    New-Item -ItemType File -Path $BaselinePath -Force | Out-Null
    # Verify the marker landed. Without it this machine would stay stuck in "first pass"
    # forever — swallowing every future real revert as housekeeping — while still reporting
    # clean. Fail closed (exit 2) instead, mirroring HardenPower/HardenPrinters' marker-write
    # discipline: a clean-but-blind guard is the exact silent failure to avoid.
    if (-not (Test-Path -LiteralPath $BaselinePath -PathType Leaf)) {
        Write-Event 'location-guard-fail' 'no se pudo escribir location-baselined.flag'
        exit 2
    }
}

# --- Log: housekeeping on the first pass; tamper only when a confirmed-disabled lever
# was flipped back on a LATER pass. Either way the state is now verified-clean (exit 0). ---
if ($changed) {
    if ((-not $firstPass) -and $confirmedRevert) {
        Write-Event 'tamper' ('setting=location | Ubicacion apagada; reactivada (' + ($details -join ',') + ')')
    } else {
        Write-Event 'location-hardened' ($details -join ',')
    }
}
exit 0
