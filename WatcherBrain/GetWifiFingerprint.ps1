# Scan the Wi-Fi access points (BSSIDs) currently visible, as a location
# FINGERPRINT — the AUTOMATIC FALLBACK source for the "worked from their post?"
# audit (plan 0017) when Windows Location is off. This runs as SYSTEM with NO
# location permission at all: netsh wlan returns BSSIDs even when the Geolocation
# broker denies location to a headless service (verified on the test PC — 21 APs
# as SYSTEM, no denial). That is exactly why it can locate a banca that a human
# never enabled Location services on.
#
# Prints ONE JSON line and exits 0, the SAME contract as GetLocation.ps1:
#   {"bssids":["aa:bb:cc:dd:ee:ff",...],"at":"<iso>"}   on a scan, or
#   {"err":"<code>","detail":"..."}                     when it could not.
# The hub compares this SET against the machine's reference fingerprint: a
# wholesale change of visible APs = the laptop moved off its post. We send only
# the AP HARDWARE ids (BSSID/MAC), never the network name (SSID) — the fingerprint
# is a location signal, not a record of what Wi-Fi they joined.
#
# MAC-address regex over the raw netsh output on purpose (NOT the localized "BSSID"
# label): the label text changes with the Windows display language, a MAC does not.
$ErrorActionPreference = 'Stop'

function Write-Err($code, $detail) {
    $d = ''
    if ($detail) { $d = ([string]$detail -replace '["\r\n\\]', ' ').Trim() }
    if ($d.Length -gt 160) { $d = $d.Substring(0, 160) }
    Write-Output ('{"err":"' + $code + '","detail":"' + $d + '"}')
    exit 0
}

$nets = ''
try {
    $iface = netsh wlan show interfaces 2>&1 | Out-String
    # No wireless adapter at all → distinct code (the fleet is 100% laptops, so this
    # is near-unreachable in the field, but a desktop image would land here).
    if ($iface -match 'There is no wireless interface|no wireless interface|no hay ninguna interfaz|El servicio.*no se est') {
        Write-Err 'no-wifi' 'sin interfaz inalambrica'
    }
    $nets = netsh wlan show networks mode=bssid 2>&1 | Out-String
} catch {
    Write-Err 'scan-failed' $_.Exception.Message
}

# Collect every distinct AP MAC. Lowercased + sorted so the SAME environment yields
# a byte-identical set the hub can compare cheaply.
$macs = [System.Collections.Generic.HashSet[string]]::new()
foreach ($m in [regex]::Matches($nets, '(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}')) {
    [void]$macs.Add($m.Value.ToLowerInvariant())
}
if ($macs.Count -eq 0) { Write-Err 'no-aps' 'cero antenas visibles' }

$sorted = @($macs) | Sort-Object
$json = ($sorted | ForEach-Object { '"' + $_ + '"' }) -join ','
Write-Output ('{"bssids":[' + $json + '],"at":"' + (Get-Date).ToUniversalTime().ToString('o') + '"}')
exit 0
