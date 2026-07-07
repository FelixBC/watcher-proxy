# Watchdog: if proxy (port 8080) is down, FIRST switch to normal internet (no Node needed), THEN start Node.
# Runs in a scheduled task (PowerShell). User gets internet as soon as this runs—we do NOT wait for Node.
# We call SetProxyByAvailability.ps1 to set proxy OFF, then start Node in the background.
$ErrorActionPreference = 'SilentlyContinue'
$BrainDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$StartWatcherPath = Join-Path $BrainDir 'StartWatcher.vbs'

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
