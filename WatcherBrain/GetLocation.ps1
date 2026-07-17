# Reads the laptop's current location via the Windows Geolocation API (WiFi
# triangulation on machines with no GPS) and prints {lat,lng,acc} as JSON to
# stdout. Best-effort: on any failure it prints nothing and exits 0, so the
# caller (poll-hub.js) just skips location this cycle. Requires the Location
# service enabled + permission granted (EnableLocation.ps1 does that at install).
#
# NOTE: uses the Windows PowerShell 5.1 WinRT projection (the default shell on
# these terminals). NEEDS VERIFICATION ON A REAL WINDOWS VM before publishing —
# WinRT await from PowerShell is environment-sensitive.
$ErrorActionPreference = 'Stop'
try {
    [void][Windows.Devices.Geolocation.Geolocator, Windows.Devices.Geolocation, ContentType = WindowsRuntime]
    [void][Windows.Foundation.IAsyncOperation`1, Windows.Foundation, ContentType = WindowsRuntime]

    $locator = New-Object Windows.Devices.Geolocation.Geolocator
    $locator.DesiredAccuracyInMeters = 50

    # Await the async WinRT op via AsTask (WindowsRuntimeSystemExtensions).
    $op = $locator.GetGeopositionAsync()
    $task = [System.WindowsRuntimeSystemExtensions]::AsTask($op)
    $pos = $task.GetAwaiter().GetResult()

    $c = $pos.Coordinate
    $out = @{
        lat = [double]$c.Point.Position.Latitude
        lng = [double]$c.Point.Position.Longitude
        acc = [double]$c.Accuracy
    }
    $out | ConvertTo-Json -Compress
} catch {
    # No location this time (service off, no permission, no fix). Silent.
    exit 0
}
