# ==============================================================================
# install.ps1 — hosted-link BOOTSTRAPPER
#
# This is the tiny script Nelson pastes/runs on each Windows terminal. It does
# ONLY four things: self-elevate, download the install bundle, extract it to
# a fixed admin-only path, then hand off to InstallWatcher.bat (which prompts
# for the master code + machine identity, enrolls with the hub, and owns the
# golden-rule ordering). This script never touches the registry, the proxy,
# or Windows internet settings itself.
#
# Usage (either works):
#   irm <hosted-url-of-this-file> | iex
#   iwr <hosted-url-of-this-file> -OutFile install.ps1 ; powershell -ExecutionPolicy Bypass -File .\install.ps1
#
# Built by scripts/build-winconfig-bundle.sh (produces the zip this downloads).
# ==============================================================================

# ------------------------------------------------------------------------------
# PLACEHOLDERS — Felix fills these in before hosting this file / publishing it.
# ------------------------------------------------------------------------------
# Public URL of the install bundle zip produced by
# scripts/build-winconfig-bundle.sh (its "stable name" output, e.g. uploaded to
# the Supabase "agent-releases" public bucket next to the OTA agent releases).
$BundleUrl = "https://<project>.supabase.co/storage/v1/object/public/agent-releases/winconfig-install.zip"

# Public URL of THIS install.ps1 file itself. Only used to re-fetch/re-run the
# script in the elevated relaunch below, and only when it's needed (see the
# "no file on disk" branch) — i.e. when Nelson ran it as `irm ... | iex`
# instead of saving it first. If you always distribute it as a saved .ps1
# file, this value is never used, but fill it in anyway so the piped flow
# also self-elevates correctly.
$InstallScriptUrl = "https://<project>.supabase.co/storage/v1/object/public/agent-releases/install.ps1"

# Fixed extraction target. The zip's top-level folder is "WinConfig" (enforced
# by build-winconfig-bundle.sh), so this always ends up as C:\WinConfig\InstallWatcher.bat.
$InstallDir = "C:\WinConfig"

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------------------------
# Step 0: self-elevate (UAC). Everything below this needs admin: creating
# C:\WinConfig and setting its ACL (Administrators/SYSTEM Full Control, plus
# Modify for BUILTIN\Users so the runtime agent can write there — see Step 2).
# ------------------------------------------------------------------------------
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Host "Administrator rights are needed. Requesting elevation (a Windows prompt will appear)..."
    try {
        if ($PSCommandPath) {
            # Saved to disk (e.g. iwr -OutFile then run) — relaunch the same file elevated.
            Start-Process -FilePath "powershell.exe" `
                -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"") `
                -Verb RunAs | Out-Null
        } else {
            # Ran as `irm <url> | iex` — there is no file on disk to relaunch, so the
            # elevated process re-fetches and re-runs the same script from the hub.
            $reentry = "irm '$InstallScriptUrl' | iex"
            Start-Process -FilePath "powershell.exe" `
                -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $reentry) `
                -Verb RunAs | Out-Null
        }
    } catch {
        # Covers both "user clicked No" (UAC declined) and any other failure to
        # elevate. Either way: change NOTHING and exit cleanly.
        Write-Host ""
        Write-Host "Elevation was declined or failed — nothing was installed or changed."
        Write-Host "Run this again and click Yes on the Windows prompt to continue."
        exit 1
    }
    # The elevated instance now owns the install; this one is done.
    Write-Host "Continuing in the elevated window that just opened. You can close this one."
    exit 0
}

Write-Host "Running elevated. Installing WinConfig..."
Write-Host ""

# ------------------------------------------------------------------------------
# Step 1: download the bundle. Fail cleanly on any network error — nothing on
# disk is touched yet at this point, so there is no half-state to clean up.
# ------------------------------------------------------------------------------
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
    # Older PowerShell/.NET without Tls12 in the enum — ignore, most modern
    # Windows already defaults to TLS 1.2+ system-wide.
}

$zipPath = Join-Path $env:TEMP ("winconfig-install-{0}.zip" -f ([guid]::NewGuid().ToString("N")))
Write-Host "[1/3] Downloading install bundle..."
try {
    Invoke-WebRequest -Uri $BundleUrl -OutFile $zipPath -UseBasicParsing
} catch {
    Write-Host ""
    Write-Host "ERROR: could not download the install bundle."
    Write-Host "       $($_.Exception.Message)"
    Write-Host "Check the internet connection and try again. Nothing was changed."
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    exit 1
}
Write-Host "       [OK] downloaded"

# ------------------------------------------------------------------------------
# Step 2: create (or reuse) C:\WinConfig and grant the runtime user Modify.
# The agent's own processes (proxy, poll/self-update, watchdog) run AS
# BUILTIN\Users at logon — see WatcherBrain/RegisterProxyLogonTask.ps1 — and
# must WRITE into this tree at runtime: events.log, blocked-request logs,
# whitelist state, unplugged.flag/updating.flag, update.lock,
# hub-credential.json, uninstall-code.hash, and the self-update file swap.
# Read+Execute-only would access-denied every one of those and break
# dashboard sync, whitelist push, unplug/resume, and OTA. Administrators and
# SYSTEM keep Full Control. This intentionally means a standard "banca" user
# CAN still delete the folder — ACL-based tamper-resistance is deferred to a
# v2 that needs an elevated OTA path; do not try to half-restrict this in a
# way that blocks writes.
# ------------------------------------------------------------------------------
Write-Host "[2/3] Preparing $InstallDir ..."
try {
    if (-not (Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }
    # Well-known SIDs (locale-independent): Administrators=S-1-5-32-544,
    # SYSTEM=S-1-5-18, Users=S-1-5-32-545.
    icacls $InstallDir /inheritance:r | Out-Null
    icacls $InstallDir /grant:r "*S-1-5-32-544:(OI)(CI)F" | Out-Null
    icacls $InstallDir /grant:r "*S-1-5-18:(OI)(CI)F" | Out-Null
    icacls $InstallDir /grant:r "*S-1-5-32-545:(OI)(CI)M" | Out-Null
} catch {
    Write-Host ""
    Write-Host "ERROR: could not create/secure $InstallDir."
    Write-Host "       $($_.Exception.Message)"
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    exit 1
}
Write-Host "       [OK] folder ready (Users: Modify; Admin/SYSTEM: Full Control)"

# ------------------------------------------------------------------------------
# Step 3: extract. The zip's single top folder is "WinConfig" (enforced by
# build-winconfig-bundle.sh's self-check), so extracting into C:\'s parent
# lands it exactly at C:\WinConfig, merging into the folder just created/
# hardened above — safe to re-run on a machine that already has one.
# ------------------------------------------------------------------------------
Write-Host "[3/3] Extracting and launching the installer..."
try {
    $parent = Split-Path $InstallDir -Parent
    Expand-Archive -Path $zipPath -DestinationPath $parent -Force
} catch {
    Write-Host ""
    Write-Host "ERROR: could not extract the install bundle (it may be corrupt or the"
    Write-Host "       download was interrupted)."
    Write-Host "       $($_.Exception.Message)"
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    exit 1
}
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

$installerBat = Join-Path $InstallDir "InstallWatcher.bat"
if (-not (Test-Path $installerBat)) {
    Write-Host ""
    Write-Host "ERROR: $installerBat not found after extraction — the bundle may be malformed."
    Write-Host "       Nothing was started. Re-download and try again."
    exit 1
}

# Hand off to the WinForms wizard (asistente "WinConfig"): it collects the fields
# in one window, runs InstallWatcher.bat HIDDEN, and shows progress + a result
# screen. If the wizard file is missing (older bundle), fall back to running the
# .bat directly (its own console + AskIdentity popups). Either way InstallWatcher.bat
# owns the golden-rule ordering — the wizard only wraps it, never changes it.
$wizard = Join-Path $InstallDir "WatcherBrain\WinConfigWizard.ps1"
if (Test-Path $wizard) {
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Mode Install' -f $wizard) `
        -WorkingDirectory $InstallDir -Wait
} else {
    Start-Process -FilePath $installerBat -WorkingDirectory $InstallDir -Wait
}
