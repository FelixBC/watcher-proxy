# Safety: if proxy (port 8080) is not running, switch Windows to NORMAL internet (proxy off, auto-detect).
# This script runs in a SCHEDULED TASK (PowerShell). It does NOT run inside Node. When Node is off,
# the user gets internet as soon as this task runs—no waiting for Node to come back. Run every 1 min.
$ErrorActionPreference = 'SilentlyContinue'

$BrainDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$UpdatingFlag = Join-Path $BrainDir 'updating.flag'

# Stale-flag guard (see docs/plans/0006). An orphaned updating.flag — self-update
# killed before it could clear the flag (Defender, power loss, reboot) — would
# otherwise freeze this layer forever: it never restores PE=1, leaving the machine
# unfiltered + proxy-down indefinitely. Treat a flag older than STALE_FLAG_MINUTES as
# ABSENT so an orphan self-heals; mirrors self-update.js's LOCK_STALE_MS. BOTH sides
# UTC: the flag is written as new Date().toISOString() (UTC) and the fleet runs
# Eastern (UTC-4/5) — a local-vs-UTC subtraction would read ~240min for a 1-second-old
# flag and defeat the guard on EVERY update, invisible to any UTC test. Same
# .ToUniversalTime()-both-sides idiom used for unplugged.flag resume times.
function Test-UpdatingActive([string]$flagPath) {
    if (-not (Test-Path $flagPath)) { return $false }
    $STALE_FLAG_MINUTES = 15  # > max legit update (~8min: patient 300s + rollback + overhead);
                              # coupled to self-update.js's health window — if that grows, re-derive.
    try {
        $ageMin = ((Get-Date).ToUniversalTime() - (Get-Item $flagPath).LastWriteTimeUtc).TotalMinutes
        if ($ageMin -gt $STALE_FLAG_MINUTES) { return $false }
    } catch { }
    return $true
}

# The proxy's local port — the obscure one chosen at install (proxy-port.txt), NOT
# 8080. Used both to probe the proxy and to point Windows at it. See proxy-port.js.
$ProxyPort = 49732
$pf = Join-Path $BrainDir 'proxy-port.txt'
if (Test-Path $pf) { $v = (Get-Content $pf -Raw -ErrorAction SilentlyContinue).Trim(); if ($v -match '^\d+$') { $ProxyPort = [int]$v } }

# Use 2s timeout; TcpClient.Connect() with no timeout blocks ~21s when nothing is listening (Windows TCP retransmits).
# Param'd (plan 0007): the reactive updating-flag branch below probes the port
# Windows is CURRENTLY pointed at, which during a cutover may be the scaffold port,
# not the persisted home port. Defaults to the home port for the normal path.
function Test-PortListening([int]$port = $ProxyPort) {
    $timeoutMs = 2000
    try {
        $tcp = New-Object Net.Sockets.TcpClient
        $ar = $tcp.BeginConnect('127.0.0.1', $port, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne($timeoutMs, $false) -and $tcp.Connected) {
            $tcp.EndConnect($ar)
            $tcp.Close()
            return $true
        }
        try { $tcp.Close() } catch { }
    } catch { }
    return $false
}
function Test-ProxyListening { return (Test-PortListening $ProxyPort) }

$RegKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'

# The port Windows is CURRENTLY pointed at (ProxyServer = "127.0.0.1:NNNNN"), or
# $null if unset / not our loopback proxy. Plan 0007: this registry value — NOT
# proxy-port.txt — is the source of truth for "which proxy is live" during a cutover
# (it's atomic and survives a reboot, unlike a port file we'd have to keep in sync).
function Get-RegistryProxyPort {
    try {
        $ps = (Get-ItemProperty -Path $RegKey -Name ProxyServer -ErrorAction SilentlyContinue).ProxyServer
        if ($ps -and $ps -match '^127\.0\.0\.1:(\d+)$') { return [int]$matches[1] }
    } catch { }
    return $null
}

# PLAN 0007 — reactive golden rule during a blue-green update cutover.
# While updating.flag is up, self-update.js OWNS the registry: it points Windows at
# the scaffold port, then back at the home port, and ALWAYS only after that port is
# listening. So we must NOT rewrite ProxyServer from proxy-port.txt here — that would
# fight the flip (e.g. re-point at the home port while the live proxy is on the
# scaffold). Instead enforce the golden rule REACTIVELY against the port Windows is
# actually pointed at: if a live proxy is there, hands off entirely; if it's DEAD (a
# crash or power-loss/reboot froze ProxyEnable=1 on a port that's now gone), force
# NORMAL internet (fail-open) in this one tick. This is what lets zero-gap (live
# pointer left alone) and fail-open (dead pointer corrected) coexist. See ADR 0001.
if (Test-UpdatingActive $UpdatingFlag) {
    $regPort = Get-RegistryProxyPort
    if ($null -ne $regPort -and (Test-PortListening $regPort)) {
        exit 0   # live pointer — leave the registry exactly as self-update set it
    }
    # Dead/unset pointer mid-update → force normal internet (fail-open).
    Set-ItemProperty -Path $RegKey -Name ProxyEnable -Value 0 -Type DWord -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $RegKey -Name ProxyServer -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $RegKey -Name ProxyOverride -ErrorAction SilentlyContinue
    try {
        $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Connections'
        $d = (Get-ItemProperty -Path $k -Name DefaultConnectionSettings -ErrorAction SilentlyContinue).DefaultConnectionSettings
        if ($d -and $d.Length -gt 8) { $d[8] = 9; Set-ItemProperty -Path $k -Name DefaultConnectionSettings -Value $d }
    } catch {}
    exit 0
}

$proxyUp = Test-ProxyListening

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
