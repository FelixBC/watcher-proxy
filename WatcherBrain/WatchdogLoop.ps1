# Runs every 5 seconds: if proxy (port 8080) is down, switch to normal internet then start Node.
# Launched at logon by a scheduled task; runs until logoff. No Node required for the "normal internet" switch.
$ErrorActionPreference = 'SilentlyContinue'
$BrainDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$StartWatcherPath = Join-Path $BrainDir 'StartWatcher.vbs'
$SafetyScript = Join-Path $BrainDir 'SetProxyByAvailability.ps1'
$PidFile = Join-Path $BrainDir 'watchdog_loop.pid'

# Write PID so BackToNormal can stop this loop
$PID | Out-File -FilePath $PidFile -Force -ErrorAction SilentlyContinue

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

while ($true) {
    Start-Sleep -Seconds 5
    $proxyUp = Test-ProxyListening
    if ($proxyUp) {
        # Proxy is UP: ensure Windows is using the proxy (restriction ON).
        if (Test-Path $SafetyScript) { & $SafetyScript | Out-Null }
    } else {
        # Proxy is DOWN: first switch to normal internet (no Node needed), then restart Node.
        if (Test-Path $SafetyScript) { & $SafetyScript | Out-Null }
        Start-Process -FilePath 'wscript.exe' -ArgumentList "`"$StartWatcherPath`" watchdog" -WindowStyle Hidden
    }
}
