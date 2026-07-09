# Watchdog: if proxy (port 8080) is down, FIRST switch to normal internet (no Node needed), THEN start Node.
# Runs in a scheduled task (PowerShell). User gets internet as soon as this runs—we do NOT wait for Node.
# We call SetProxyByAvailability.ps1 to set proxy OFF, then start Node in the background.
#
# Called from: OnResumeFromSleep.bat, and (as of the 3-layer redundancy
# design) the independent "Watcher Proxy Safety Net" scheduled task, every
# 1 minute. Must honor unplugged.flag the same way WatchdogLoop.ps1 does -
# otherwise this would fight Nelson's own "give free internet" button by
# trying to restart the proxy during an intentional unplug.
#
# ALSO restarts WatchdogLoop.ps1 itself if it isn't running. This was
# supposed to be Task Scheduler's own job (RestartOnFailure on the "Watcher
# Proxy Loop" task) - confirmed by hand on a real VM that this does NOT
# reliably fire in practice, even with the task's action set to the
# long-running process directly. Rather than depend on an OS feature that
# didn't behave as documented here, this script - already proven to run
# reliably every minute - takes over that job directly.
$ErrorActionPreference = 'SilentlyContinue'
$BrainDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$StartWatcherPath = Join-Path $BrainDir 'StartWatcher.vbs'
$UnpluggedFlagPath = Join-Path $BrainDir 'unplugged.flag'

function Test-ShouldStayUnplugged {
    if (-not (Test-Path $UnpluggedFlagPath)) { return $false }
    $resumeAtRaw = (Get-Content -Path $UnpluggedFlagPath -Raw -ErrorAction SilentlyContinue)
    if ([string]::IsNullOrWhiteSpace($resumeAtRaw)) { return $true }
    $resumeAt = $null
    if ([DateTime]::TryParse($resumeAtRaw.Trim(), [ref]$resumeAt)) {
        if ((Get-Date).ToUniversalTime() -ge $resumeAt.ToUniversalTime()) {
            Remove-Item -Path $UnpluggedFlagPath -Force -ErrorAction SilentlyContinue
            return $false
        }
        return $true
    }
    return $true
}

if (Test-ShouldStayUnplugged) {
    exit 0
}

function Test-WatchdogLoopRunning {
    try {
        $proc = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -and $_.CommandLine -like '*WatchdogLoop.ps1*' }
        return [bool]$proc
    } catch {
        # Query itself failed - assume it's running rather than risk a
        # second instance; the next 1-min cycle will check again.
        return $true
    }
}

if (-not (Test-WatchdogLoopRunning)) {
    $watchdogScript = Join-Path $BrainDir 'WatchdogLoop.ps1'
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$watchdogScript`"" `
        -WindowStyle Hidden
}

# Use 2s timeout; TcpClient.Connect() with no timeout blocks ~21s when nothing is listening (Windows TCP retransmits).
function Test-ProxyListening {
    $timeoutMs = 2000
    try {
        $tcp = New-Object Net.Sockets.TcpClient
        $ar = $tcp.BeginConnect('127.0.0.1', 8080, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne($timeoutMs, $false) -and $tcp.Connected) {
            $tcp.EndConnect($ar)
            $tcp.Close()
            return $true
        }
        try { $tcp.Close() } catch { }
    } catch { }
    return $false
}

if (Test-ProxyListening) {
  exit 0
}
# First switch to normal traffic so user has internet immediately (don't wait for Safety task).
$SafetyScript = Join-Path $BrainDir 'SetProxyByAvailability.ps1'
if (Test-Path $SafetyScript) { & $SafetyScript | Out-Null }
# Then start the proxy again.
Start-Process -FilePath 'wscript.exe' -ArgumentList "`"$StartWatcherPath`" watchdog" -WindowStyle Hidden
exit 0
