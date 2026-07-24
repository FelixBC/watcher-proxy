# Downloads Node.js LTS (Windows x64) into WatcherBrain\node\ so the folder is self-contained.
# Run from WatcherBrain folder or pass target path. Requires internet.

param([string]$TargetDir = $PSScriptRoot)

$nodeDir = Join-Path $TargetDir "node"
$nodeExe = Join-Path $nodeDir "node.exe"

if (Test-Path $nodeExe) {
    Write-Host "node.exe already exists in $nodeDir"
    exit 0
}

$nodeVersion = "v20.18.0"
$zipUrl = "https://nodejs.org/dist/$nodeVersion/node-$nodeVersion-win-x64.zip"
$tempZip = Join-Path $env:TEMP "node-watcher.zip"
$tempExtract = Join-Path $env:TEMP "node-watcher-extract"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Retry the download. A SINGLE transient failure (slow network, a TLS hiccup, a
# momentary nodejs.org blip) previously aborted the WHOLE install at [1/8] — the
# install has no bundled node, so this download is a hard dependency. Try several
# times with a growing pause and a real timeout, and sanity-check the size, before
# giving up.
$maxAttempts = 5
$downloaded = $false
for ($i = 1; $i -le $maxAttempts; $i++) {
    try {
        Write-Host "Downloading Node.js $nodeVersion (attempt $i/$maxAttempts)..."
        Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
        Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip -UseBasicParsing -TimeoutSec 120
        if ((Test-Path $tempZip) -and ((Get-Item $tempZip).Length -gt 1MB)) { $downloaded = $true; break }
        throw "downloaded file missing or too small"
    } catch {
        Write-Warning "Node.js download attempt $i/$maxAttempts failed: $_"
        if ($i -lt $maxAttempts) { Start-Sleep -Seconds ([math]::Min(5 * $i, 20)) }
    }
}
if (-not $downloaded) {
    Write-Error "Node.js download failed after $maxAttempts attempts (check internet / nodejs.org reachability)."
    exit 1
}

Write-Host "Extracting..."
if (Test-Path $tempExtract) { Remove-Item $tempExtract -Recurse -Force }
Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force

$innerFolder = Get-ChildItem $tempExtract -Directory | Select-Object -First 1
$srcExe = Join-Path $innerFolder.FullName "node.exe"
if (-not (Test-Path $srcExe)) {
    Write-Error "node.exe not found in archive"
    Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
    Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

New-Item -ItemType Directory -Path $nodeDir -Force | Out-Null
Copy-Item -Path $srcExe -Destination $nodeExe -Force

Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "Done. node.exe saved to $nodeExe"
exit 0
