# Registers the recovery layers on top of the fast 5-second WatchdogLoop.ps1
# (layer 1). See docs/plans/0001-fleet-dashboard.md for the full reasoning
# and the real VM testing behind this; summary:
#
#   Layer 1 (existing, unchanged): WatchdogLoop.ps1, a persistent process,
#     checks every 5 sec. Fast, but it IS a process - it can be killed. Its
#     scheduled task runs as LogonType=InteractiveToken (the actual logged-in
#     user), which matters: it's what lets it correctly read/write that
#     user's own HKCU proxy settings.
#
#   Layer 2 - RETIRED. Used to be a native Task Scheduler
#     RestartOnFailure policy on the "WinConfig Loop" task itself.
#     Confirmed by hand on a real VM this session that it does NOT reliably
#     fire in practice. Replaced by the WinConfigSvc Windows
#     Service (see InstallWatcherService.ps1) - SCM's own Recovery policy is
#     purpose-built for exactly this and, unlike Task Scheduler here, is
#     core Windows infrastructure every service on the machine depends on.
#     That service deliberately does NOT run WatchdogLoop.ps1 or touch the
#     registry itself - also confirmed by hand this session that a
#     LocalSystem-run service writes to ITS OWN profile's HKCU, not the
#     logged-in user's, so it can't correctly flip that user's actual proxy
#     setting. Its only job is `schtasks /run` on Layer 1's task, which Task
#     Scheduler already knows how to launch in the right user session.
#
#   Layer 3 (this script): a second, separate task with NO persistent
#     process - Windows fires it directly every 1 minute. It doesn't
#     exist except for the instant it runs, so it can't be "killed" the
#     way a running program can. It both restores normal internet AND
#     tries to restart the proxy, so it's a real second attempt at
#     recovery, not just a safety check. Also now checks that the
#     WinConfigSvc service itself is running, as a secondary
#     check on top of what SCM's own Recovery policy already does.
#
# IMPORTANT: this deliberately uses schtasks.exe (via raw Task Scheduler XML)
# instead of the PowerShell ScheduledTasks module (Register-ScheduledTask /
# Unregister-ScheduledTask). Confirmed by hand on a real machine: those
# cmdlets can hang indefinitely re-registering a task that has a currently
# running instance, while schtasks.exe handles the identical operation
# instantly. schtasks.exe /create /xml still gives full access to settings
# (RestartOnFailure, ExecutionTimeLimit) that the simple schtasks.exe flags
# don't expose - this gets both the reliability AND the full settings.
#
# Only BackToNormal.bat removes these tasks (see its admin cleanup step).
param([Parameter(Mandatory=$true)] [string] $BrainDir)
$BrainDir = $BrainDir.TrimEnd('\')

function Install-TaskFromTemplate {
    param([string]$TaskName, [string]$TemplateFile)

    $templatePath = Join-Path $BrainDir $TemplateFile
    $xml = Get-Content -Path $templatePath -Raw
    $xml = $xml.Replace('__BRAIN_DIR__', $BrainDir)
    $xml = $xml.Replace('__START_TIME__', (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss'))

    $tempXmlPath = Join-Path $env:TEMP "$TaskName-$(Get-Random).xml"
    # Task Scheduler XML import expects UTF-16LE, matching the <?xml ... encoding="UTF-16"?> declaration.
    Set-Content -Path $tempXmlPath -Value $xml -Encoding Unicode

    schtasks.exe /delete /tn $TaskName /f 2>$null | Out-Null
    schtasks.exe /create /tn $TaskName /xml $tempXmlPath /f | Out-Null
    $created = $LASTEXITCODE -eq 0

    Remove-Item -Path $tempXmlPath -Force -ErrorAction SilentlyContinue
    return $created
}

$loopOk = Install-TaskFromTemplate -TaskName "WinConfig Loop" -TemplateFile "WatcherProxyLoop.task.xml"
$safetyOk = Install-TaskFromTemplate -TaskName "WinConfig Safety" -TemplateFile "WatcherProxySafetyNet.task.xml"

# Arm both immediately (their triggers alone wouldn't fire until next logon /
# 1 min from creation respectively - same reasoning as the InstallWatcher.bat
# fix for the original single-watchdog gap).
if ($loopOk) { schtasks.exe /run /tn "WinConfig Loop" | Out-Null }
if ($safetyOk) { schtasks.exe /run /tn "WinConfig Safety" | Out-Null }

# Layer 2's replacement - see header comment above for why this is a
# separate service rather than a policy on the Layer 1 task.
$serviceScript = Join-Path $BrainDir "InstallWatcherService.ps1"
$serviceOk = $true
if (Test-Path $serviceScript) {
    & $serviceScript -BrainDir $BrainDir
    $serviceOk = ($LASTEXITCODE -eq 0)
}

if (-not ($loopOk -and $safetyOk -and $serviceOk)) { exit 1 }
exit 0
