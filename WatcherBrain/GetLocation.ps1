# Reads the PC's current location via the Windows Geolocation API (WiFi
# triangulation on machines with no GPS) and prints ONE line of JSON to stdout:
# either {"lat":..,"lng":..,"acc":..} on a fix, or {"err":"<code>","detail":".."}
# when it could not get one. It NEVER prints nothing and it always exits 0 — the
# caller (poll-hub.js) turns that `err` into the machine's location health, which
# the hub shows. Silence was the previous contract and it cost two weeks of a
# feature that looked built and had never once worked (see the AsTask note below).
#
# Requires the Location service enabled + permission granted; EnableLocation.ps1
# does that at install (lfsvc Automatic, ConsentStore\location = Allow, and the
# NonPackaged subkey so classic Win32 apps are allowed too).
#
# VERIFIED on the staging PC (Windows 11 25H2, Windows PowerShell 5.1) in BOTH
# contexts that matter: as the interactive user AND as SYSTEM via a scheduled
# task, which is how the poll actually runs it. Both returned a real fix at ~100 m.
$ErrorActionPreference = 'Stop'

# One-line JSON on the way out, whatever happened. `detail` is trimmed and
# quote-stripped because it ends up inside a JSON string built by hand (the
# failure paths must not depend on ConvertTo-Json being reachable).
function Write-Err($code, $detail) {
    $d = ''
    if ($detail) { $d = ([string]$detail -replace '["\r\n\\]', ' ').Trim() }
    if ($d.Length -gt 160) { $d = $d.Substring(0, 160) }
    Write-Output ('{"err":"' + $code + '","detail":"' + $d + '"}')
    exit 0
}

# WinRT `IAsyncOperation` is awaited through AsTask, an EXTENSION method living in
# System.Runtime.WindowsRuntime — an assembly Windows PowerShell 5.1 does not load
# on its own. Without this line the next block dies with "Unable to find type
# [System.WindowsRuntimeSystemExtensions]", which is exactly the bug that kept
# every machine's location empty from 1.0.14 to 1.0.35.
try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
} catch {
    Write-Err 'winrt-assembly' $_.Exception.Message
}

try {
    [void][Windows.Devices.Geolocation.Geolocator, Windows.Devices.Geolocation, ContentType = WindowsRuntime]
    [void][Windows.Foundation.IAsyncOperation`1, Windows.Foundation, ContentType = WindowsRuntime]
} catch {
    Write-Err 'geolocator-type' $_.Exception.Message
}

$locator = $null
try {
    $locator = New-Object Windows.Devices.Geolocation.Geolocator
    $locator.DesiredAccuracyInMeters = 50
} catch {
    Write-Err 'geolocator-new' $_.Exception.Message
}

# Resolve AsTask by reflection and close it over Geoposition ourselves: PowerShell
# 5.1 cannot bind a generic extension method as a static call, so the obvious
# [System.WindowsRuntimeSystemExtensions]::AsTask($op) throws even once the
# assembly above is loaded. Pick the single-argument IAsyncOperation`1 overload —
# the others take progress/cancellation and would not bind.
$asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
} | Select-Object -First 1
if (-not $asTask) { Write-Err 'astask-missing' 'AsTask(IAsyncOperation<T>) not found' }

$task = $null
try {
    $op = $locator.GetGeopositionAsync()
    $task = $asTask.MakeGenericMethod([Windows.Devices.Geolocation.Geoposition]).Invoke($null, @($op))
} catch {
    Write-Err 'request-failed' ("$($_.Exception.Message) [status=$($locator.LocationStatus)]")
}

try {
    # Bounded on purpose: poll-hub gives this whole script 15 s, and a request that
    # hangs would be killed with no output at all — the silent failure again. 12 s
    # leaves room to report WHY instead.
    if (-not $task.Wait(12000)) {
        Write-Err 'timeout' ("no fix in 12s [status=$($locator.LocationStatus)]")
    }
    $pos = $task.Result
} catch {
    # Denied / service off surface here as an AggregateException; LocationStatus
    # tells the two apart, so it rides along in the detail.
    $inner = $_.Exception
    while ($inner.InnerException) { $inner = $inner.InnerException }
    $status = "$($locator.LocationStatus)"
    $code = 'no-fix'
    if ($status -eq 'Denied') { $code = 'denied' }
    elseif ($status -eq 'Disabled') { $code = 'disabled' }
    elseif ($status -eq 'NotAvailable') { $code = 'no-hardware' }
    Write-Err $code ("$($inner.Message) [status=$status]")
}

if (-not $pos -or -not $pos.Coordinate) {
    Write-Err 'no-position' ("empty result [status=$($locator.LocationStatus)]")
}

$c = $pos.Coordinate
$out = @{
    lat = [double]$c.Point.Position.Latitude
    lng = [double]$c.Point.Position.Longitude
    acc = [double]$c.Accuracy
}
$out | ConvertTo-Json -Compress
