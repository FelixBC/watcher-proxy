# Fast port check with timeout. Exit 0 = port open (proxy up), exit 1 = closed or timeout.
# TcpClient.Connect() with no timeout blocks ~21s when nothing is listening (Windows TCP retransmits).
# Using BeginConnect + WaitOne(TimeoutMs) so we give up after 2s instead of 20+ seconds.
param(
    [int] $Port = 8080,
    [int] $TimeoutMs = 2000
)
$ok = $false
try {
    $tcp = New-Object Net.Sockets.TcpClient
    $ar = $tcp.BeginConnect('127.0.0.1', $Port, $null, $null)
    if ($ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false) -and $tcp.Connected) {
        $tcp.EndConnect($ar)
        $tcp.Close()
        $ok = $true
    } else {
        try { $tcp.Close() } catch { }
    }
} catch { }
exit $(if ($ok) { 0 } else { 1 })
