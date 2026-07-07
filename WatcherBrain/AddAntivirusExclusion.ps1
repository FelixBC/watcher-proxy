# Add Watcher folder to antivirus exclusions.
# If McAfee is installed: try Defender anyway, then exit 2 so caller can prompt for manual McAfee exclusion.
# If only Defender: add exclusion and exit 0.
# Must run as Administrator for Defender. Called from InstallWatcher.bat when run as admin.
param(
    [Parameter(Mandatory=$true)]
    [string]$WatcherFolder
)

$WatcherFolder = $WatcherFolder.TrimEnd('\')
if (-not (Test-Path -LiteralPath $WatcherFolder -PathType Container)) {
    Write-Warning "AddAntivirusExclusion: Folder not found: $WatcherFolder"
    exit 1
}

$mcAfeeDetected = $false
# Detect McAfee (common registry key; consumer and some enterprise)
try {
    if (Test-Path "HKLM:\SOFTWARE\McAfee") { $mcAfeeDetected = $true }
    if (Test-Path "HKLM:\SOFTWARE\WOW6432Node\McAfee") { $mcAfeeDetected = $true }
} catch { }

# Always try Windows Defender (works when Defender is primary; when McAfee is primary, Defender is passive but exclusion still useful)
$defenderOk = $false
try {
    $exclusions = Get-MpPreference -ErrorAction Stop | Select-Object -ExpandProperty ExclusionPath
    if ($exclusions -and $exclusions -contains $WatcherFolder) {
        $defenderOk = $true
    } else {
        Add-MpPreference -ExclusionPath $WatcherFolder -ErrorAction Stop
        $defenderOk = $true
    }
} catch {
    # Defender not available or not admin
}

if ($mcAfeeDetected) {
    # McAfee is present; user must add folder in McAfee GUI (consumer McAfee has no reliable scriptable exclusion API)
    if ($defenderOk) { exit 2 }  # Defender done; tell user to add McAfee manually
    exit 3                        # Defender failed (e.g. not admin); still tell user about McAfee
}
if ($defenderOk) { exit 0 }
exit 1
