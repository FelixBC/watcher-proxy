# Registers SupervisorService.ps1 as a real Windows Service, supervised by
# SCM (Service Control Manager) instead of a second hand-built Task
# Scheduler entry (the old Layer 2, confirmed unreliable). This replaces
# Layer 2 only - Layer 1 (WatchdogLoop.ps1's own logon-triggered task) and
# Layer 3 (CheckAndStartProxy.ps1's 1-min safety net task) are untouched;
# both already run as LogonType=InteractiveToken, so they were never subject
# to the SYSTEM-vs-user-registry problem this script's own process (running
# as LocalSystem) has to avoid - see SupervisorService.ps1's header.
#
# Safe to re-run: uninstalls any existing WinConfigSvc service
# first, matching the idempotent pattern RegisterWatchdogTasks.ps1 already
# uses for its own tasks.
param([Parameter(Mandatory=$true)] [string] $BrainDir)
$BrainDir = $BrainDir.TrimEnd('\')
$ErrorActionPreference = 'SilentlyContinue'

$winswExe = Join-Path $BrainDir "winsw\WatcherProxySupervisor.exe"
$winswXmlSrc = Join-Path $BrainDir "WatcherProxySupervisor.xml"
$winswXmlDest = Join-Path $BrainDir "winsw\WatcherProxySupervisor.xml"

if (-not (Test-Path $winswExe)) {
    & (Join-Path $BrainDir "DownloadWinSW.ps1") -TargetDir $BrainDir
}
if (-not (Test-Path $winswExe)) {
    Write-Error "WatcherProxySupervisor.exe still missing after download attempt - aborting service install."
    exit 1
}

$xml = Get-Content -Path $winswXmlSrc -Raw
$xml = $xml.Replace('__BRAIN_DIR__', $BrainDir)
Set-Content -Path $winswXmlDest -Value $xml -Encoding UTF8

# LEGACY cleanup: before the WinConfig rename, this service was registered
# under the literal id "WatcherProxySupervisor" (see WatcherProxySupervisor.xml's
# <id>, later changed to WinConfigSvc). A machine ever upgraded from that
# older install could still have it registered and running, duplicating (and
# fighting) the WinConfigSvc install below. Best-effort only: sc.exe returns
# non-zero when the service doesn't exist, which is the normal/expected case
# on a fresh install - ignore it, same as the idempotent stop/uninstall below.
sc.exe stop "WatcherProxySupervisor" 2>$null | Out-Null
sc.exe delete "WatcherProxySupervisor" 2>$null | Out-Null

# Stop/uninstall any previous instance first (idempotent re-run).
& $winswExe stop | Out-Null
& $winswExe uninstall | Out-Null

& $winswExe install
if ($LASTEXITCODE -ne 0) {
    Write-Error "Service install failed."
    exit 1
}

# SCM's native Recovery policy: restart immediately on first failure, then
# after 1 min for subsequent failures within the same day, reset the
# failure count after 1 failure-free day. This is what Layer 2 was trying
# (and, per real testing this session, failing) to approximate with Task
# Scheduler's RestartOnFailure.
sc.exe failure WinConfigSvc reset= 86400 actions= restart/0/restart/60000/restart/60000 | Out-Null
sc.exe failureflag WinConfigSvc 1 | Out-Null
sc.exe config WinConfigSvc start= auto | Out-Null

& $winswExe start
if ($LASTEXITCODE -ne 0) {
    Write-Error "Service start failed."
    exit 1
}

exit 0
