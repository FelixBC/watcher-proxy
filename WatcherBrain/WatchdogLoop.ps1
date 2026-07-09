# Runs every 5 seconds: if proxy (port 8080) is down, switch to normal internet then start Node.
# Launched at logon by a scheduled task; runs until logoff. No Node required for the "normal internet" switch.
#
# Also owns the "unplugged" (free internet) state pushed from the fleet dashboard
# (plan 0001, AC3/AC4): unplugged.flag existing means Nelson intentionally wants
# this machine unfiltered. This loop is the ONLY thing that starts/stops the
# proxy, so unplug/resume has to be handled here too, or this loop would just
# undo it within 5 seconds. Resume time is read from the flag file itself and
# compared to the LOCAL clock, so a scheduled resume fires even if the hub is
# completely unreachable at that moment (poll-hub.js only ever writes/clears
# this file — it never touches the proxy process directly).
$ErrorActionPreference = 'SilentlyContinue'
$BrainDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$StartWatcherPath = Join-Path $BrainDir 'StartWatcher.vbs'
$SafetyScript = Join-Path $BrainDir 'SetProxyByAvailability.ps1'
$PidFile = Join-Path $BrainDir 'watchdog_loop.pid'
$UnpluggedFlagPath = Join-Path $BrainDir 'unplugged.flag'

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

function Stop-ProxyProcessOnly {
    # Scoped to the proxy process only — this loop itself must keep running.
    try {
        $bundledNode = Join-Path $BrainDir 'node\node.exe'
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like "*proxy-server.js*" } |
            ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }
    } catch {}
}

function Test-ShouldStayUnplugged {
    # Returns $true if the flag says to stay unplugged, $false if it's time
    # to resume (flag deleted as a side effect of returning $false).
    if (-not (Test-Path $UnpluggedFlagPath)) { return $false }

    $resumeAtRaw = (Get-Content -Path $UnpluggedFlagPath -Raw -ErrorAction SilentlyContinue)
    if ([string]::IsNullOrWhiteSpace($resumeAtRaw)) {
        return $true  # indefinite unplug
    }

    $resumeAt = $null
    if ([DateTime]::TryParse($resumeAtRaw.Trim(), [ref]$resumeAt)) {
        if ((Get-Date).ToUniversalTime() -ge $resumeAt.ToUniversalTime()) {
            Remove-Item -Path $UnpluggedFlagPath -Force -ErrorAction SilentlyContinue
            return $false  # resume time has passed
        }
        return $true
    }
    # Unparseable content — fail toward "still unplugged" rather than
    # guessing, since unplugged always means normal internet anyway (fail-open
    # holds either way); Nelson can always hit "resume now" from the dashboard.
    return $true
}

while ($true) {
    Start-Sleep -Seconds 5

    if (Test-ShouldStayUnplugged) {
        # GOLDEN RULE ORDER: flip Windows to normal internet FIRST, then stop
        # the proxy — never the other way round, so there is no window where
        # the proxy is dead but Windows still points at 127.0.0.1:8080.
        if (Test-Path $SafetyScript) {
            # Force "off" regardless of whether the proxy happens to still be
            # listening — unplugged means unfiltered, full stop.
            Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyEnable -Value 0 -Type DWord -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyServer -ErrorAction SilentlyContinue
        }
        Stop-ProxyProcessOnly
        continue  # do NOT restart the proxy while unplugged
    }

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
