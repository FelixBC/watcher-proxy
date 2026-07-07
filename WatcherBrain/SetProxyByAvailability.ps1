# Safety: if proxy (port 8080) is not running, switch Windows to NORMAL internet (proxy off, auto-detect).
# This script runs in a SCHEDULED TASK (PowerShell). It does NOT run inside Node. When Node is off,
# the user gets internet as soon as this task runs—no waiting for Node to come back. Run every 1 min.
$ErrorActionPreference = 'SilentlyContinue'

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

$proxyUp = Test-ProxyListening

if ($proxyUp) {
    # Proxy is running: ensure proxy is ON (restriction active)
    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyEnable -Value 1 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyServer -Value '127.0.0.1:8080' -Type String -ErrorAction SilentlyContinue
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
