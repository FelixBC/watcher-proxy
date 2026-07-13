# Downloads WinSW (Windows Service Wrapper) into WatcherBrain\winsw\ so the
# folder is self-contained, same pattern as DownloadNode.ps1. WinSW just
# wraps SupervisorService.ps1 as a real Windows Service so SCM (Service
# Control Manager) supervises it, instead of another hand-built Task
# Scheduler entry.
param([string]$TargetDir = $PSScriptRoot)

$winswDir = Join-Path $TargetDir "winsw"
$winswExe = Join-Path $winswDir "WatcherProxySupervisor.exe"

if (Test-Path $winswExe) {
    Write-Host "WatcherProxySupervisor.exe already exists in $winswDir"
    exit 0
}

$url = "https://github.com/winsw/winsw/releases/download/v3.0.0-alpha.11/WinSW-x64.exe"

Write-Host "Downloading WinSW..."
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    New-Item -ItemType Directory -Path $winswDir -Force | Out-Null
    Invoke-WebRequest -Uri $url -OutFile $winswExe -UseBasicParsing
} catch {
    Write-Error "Download failed: $_"
    exit 1
}

Write-Host "Done. WatcherProxySupervisor.exe saved to $winswExe"
exit 0
