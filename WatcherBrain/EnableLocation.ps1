# Enables the Windows Location service and allows desktop apps to use it, so
# GetLocation.ps1 can read a fix without a per-user consent prompt. Run once at
# install as admin (best-effort — if it can't, location just stays unavailable
# and the fleet falls back to no-location; nothing else breaks).
#
# NOTE: NEEDS VERIFICATION ON A REAL WINDOWS VM before publishing. Exact keys
# can vary by Windows build.
$ErrorActionPreference = 'SilentlyContinue'
try {
    # Master consent for the "location" capability (all apps).
    $consent = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'
    New-Item -Path $consent -Force | Out-Null
    Set-ItemProperty -Path $consent -Name 'Value' -Value 'Allow' -Type String

    # Let classic desktop (Win32) apps use location.
    $consentNonPackaged = Join-Path $consent 'NonPackaged'
    New-Item -Path $consentNonPackaged -Force | Out-Null
    Set-ItemProperty -Path $consentNonPackaged -Name 'Value' -Value 'Allow' -Type String

    # Turn the Location service on and make it start automatically.
    $cfg = 'HKLM:\SYSTEM\CurrentControlSet\Services\lfsvc\Service\Configuration'
    New-Item -Path $cfg -Force | Out-Null
    Set-ItemProperty -Path $cfg -Name 'Status' -Value 1 -Type DWord
    Set-Service -Name lfsvc -StartupType Automatic
    Start-Service -Name lfsvc

    Write-Host "Location enabled."
} catch {
    Write-Host "EnableLocation: skipped ($($_.Exception.Message))"
}
