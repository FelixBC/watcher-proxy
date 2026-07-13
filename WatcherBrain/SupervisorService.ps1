# The process a Windows Service (see InstallWatcherService.ps1) runs under
# SCM supervision. Deliberately does NOT touch the registry or the proxy
# process directly - a LocalSystem service writes to its OWN profile's HKCU,
# not the logged-in user's (confirmed by hand on a real VM: a LocalSystem
# service setting HKCU:...ProxyEnable had zero effect on the interactive
# user's actual value). Layer 1's scheduled task avoids this because it runs
# as LogonType=InteractiveToken - the actual logged-in user - so it's left
# completely alone here. This script's only job is to ask Task Scheduler to
# relaunch that task, which Task Scheduler already knows how to do correctly
# in the right user session.
#
# Runs every 5 sec, same cadence as Layer 1 itself, so a dead Layer 1 doesn't
# sit dead for up to a minute waiting on Layer 3's slower cycle.
$ErrorActionPreference = 'SilentlyContinue'

function Test-WatchdogLoopRunning {
    try {
        $proc = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -and $_.CommandLine -like '*WatchdogLoop.ps1*' }
        return [bool]$proc
    } catch {
        return $true
    }
}

while ($true) {
    Start-Sleep -Seconds 5
    if (-not (Test-WatchdogLoopRunning)) {
        schtasks.exe /run /tn "Watcher Proxy Loop" | Out-Null
    }
}
