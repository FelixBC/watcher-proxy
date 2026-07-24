# Safety: if proxy (port 8080) is not running, switch Windows to NORMAL internet (proxy off, auto-detect).
# This script runs in a SCHEDULED TASK (PowerShell). It does NOT run inside Node. When Node is off,
# the user gets internet as soon as this task runs—no waiting for Node to come back. Run every 1 min.
$ErrorActionPreference = 'SilentlyContinue'

$BrainDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$UpdatingFlag = Join-Path $BrainDir 'updating.flag'

# The proxy's local port — the obscure one chosen at install (proxy-port.txt), NOT
# 8080. Used both to probe the proxy and to point Windows at it. See proxy-port.js.
$ProxyPort = 49732
$pf = Join-Path $BrainDir 'proxy-port.txt'
if (Test-Path $pf) { $v = (Get-Content $pf -Raw -ErrorAction SilentlyContinue).Trim(); if ($v -match '^\d+$') { $ProxyPort = [int]$v } }

# Use 2s timeout; TcpClient.Connect() with no timeout blocks ~21s when nothing is listening (Windows TCP retransmits).
function Test-ProxyListening {
    $timeoutMs = 2000
    try {
        $tcp = New-Object Net.Sockets.TcpClient
        $ar = $tcp.BeginConnect('127.0.0.1', $ProxyPort, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne($timeoutMs, $false) -and $tcp.Connected) {
            $tcp.EndConnect($ar)
            $tcp.Close()
            return $true
        }
        try { $tcp.Close() } catch { }
    } catch { }
    return $false
}

$proxyUp = Test-ProxyListening

# GOLDEN RULE: during a self-update the proxy is deliberately torn down and
# rebuilt. If it happens to still be listening at this instant we must NOT
# re-point Windows at it (PE=1) — self-update is about to kill it for the file
# swap, which would leave traffic routed at a dead 127.0.0.1:8080 = internet
# FULLY DOWN. Treat "updating" as proxy-down so this always forces NORMAL
# internet (fail-open); self-update.js clears the flag once the proxy is
# healthy again, and the next cycle restores filtering.
if (Test-Path $UpdatingFlag) { $proxyUp = $false }

if ($proxyUp) {
    # Proxy is running: ensure proxy is ON (restriction active)
    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyEnable -Value 1 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyServer -Value "127.0.0.1:$ProxyPort" -Type String -ErrorAction SilentlyContinue
    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyOverride -Value '<local>' -Type String -ErrorAction SilentlyContinue
    try {
        $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Connections'
        $d = (Get-ItemProperty -Path $k -Name DefaultConnectionSettings -ErrorAction SilentlyContinue).DefaultConnectionSettings
        if ($d -and $d.Length -gt 8) { $d[8] = 3; Set-ItemProperty -Path $k -Name DefaultConnectionSettings -Value $d }
    } catch {}
} else {
    # Proxy is NOT running: switch to normal traffic (proxy off + automatically detect settings) so user has internet
    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyEnable -Value 0 -Type DWord -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyServer -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyOverride -ErrorAction SilentlyContinue
    try {
        $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Connections'
        $d = (Get-ItemProperty -Path $k -Name DefaultConnectionSettings -ErrorAction SilentlyContinue).DefaultConnectionSettings
        if ($d -and $d.Length -gt 8) { $d[8] = 9; Set-ItemProperty -Path $k -Name DefaultConnectionSettings -Value $d }
    } catch {}
}
exit 0
