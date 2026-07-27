# Plan 0007 — one-shot check used by StartProxyAtLogon.bat (and any cmd/bat caller)
# to avoid spawning a proxy during a blue-green update cutover. Exits 0 if a NON-stale
# updating.flag is present (an update is actively in progress), 1 otherwise.
#
# Stale guard = 15 min, mirroring the .ps1 watchdog layers: self-update may be killed
# (Defender / power loss / reboot) before it clears the flag, and an orphaned flag
# must self-heal rather than freeze the logon path forever. BOTH sides UTC — the flag
# is written as new Date().toISOString() (UTC) and the fleet runs Eastern (UTC-4/5),
# so a local-vs-UTC subtraction would read ~240 min for a 1-second-old flag and defeat
# the guard on EVERY update (see the identical note in WatchdogLoop.ps1 /
# SetProxyByAvailability.ps1 / CheckAndStartProxy.ps1). If self-update's health window
# grows past 15 min, re-derive this alongside those.
$ErrorActionPreference = 'SilentlyContinue'
$BrainDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$flag = Join-Path $BrainDir 'updating.flag'
if (-not (Test-Path $flag)) { exit 1 }
try {
    $ageMin = ((Get-Date).ToUniversalTime() - (Get-Item $flag).LastWriteTimeUtc).TotalMinutes
    if ($ageMin -le 15) { exit 0 }
} catch { }
exit 1
