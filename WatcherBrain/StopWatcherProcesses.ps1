# Stops Watcher-related background processes by inspecting command lines.
# Safe to run multiple times.

$ErrorActionPreference = 'SilentlyContinue'

$brainDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $brainDir

function Stop-ByCommandLineMatch([string]$match) {
    Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine -like "*$match*" } |
        ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }
}

# Stop Watcher-launched node (runs proxy-server.js)
Stop-ByCommandLineMatch (Join-Path $brainDir 'proxy-server.js')

# Stop watchdog loop and helper scripts if running
Stop-ByCommandLineMatch (Join-Path $brainDir 'WatchdogLoop.ps1')
Stop-ByCommandLineMatch (Join-Path $brainDir 'SetProxyByAvailability.ps1')
Stop-ByCommandLineMatch (Join-Path $brainDir 'CheckAndStartProxy.ps1')
Stop-ByCommandLineMatch (Join-Path $brainDir 'CheckPort.ps1')
Stop-ByCommandLineMatch (Join-Path $brainDir 'SupervisorService.ps1')

# Stop VBS launchers if running
Stop-ByCommandLineMatch (Join-Path $brainDir 'RunWatchdogLoopHidden.vbs')
Stop-ByCommandLineMatch (Join-Path $brainDir 'RunStartupHidden.vbs')
Stop-ByCommandLineMatch (Join-Path $rootDir 'StartWatcher.vbs')
Stop-ByCommandLineMatch (Join-Path $rootDir 'RunProxyAtStartup.vbs')

# Also stop any node.exe launched from our bundled node folder — but NEVER the
# self-update process itself. self-update.js runs on this same bundled node and
# calls this script to stop the proxy; the old broad "kill all bundled node"
# killed self-update mid-run, which was the long-standing SILENT CRASH (the
# process died right after downloading, with no error and no rollback). Excluding
# it here is the fix.
try {
    $bundledNode = Join-Path $brainDir 'node\node.exe'
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
        Where-Object {
            $_.CommandLine -and
            $_.ExecutablePath -and ($_.ExecutablePath -ieq $bundledNode) -and
            ($_.CommandLine -notlike '*self-update.js*')
        } |
        ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }
} catch {}

exit 0

