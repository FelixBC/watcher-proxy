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

Write-Host "Downloading Node.js $nodeVersion..."
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip -UseBasicParsing
} catch {
    Write-Error "Download failed: $_"
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
