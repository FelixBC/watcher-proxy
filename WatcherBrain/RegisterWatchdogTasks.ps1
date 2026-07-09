# Registers the two independent recovery layers on top of the fast 5-second
# WatchdogLoop.ps1 (layer 1). See docs/plans/0001-fleet-dashboard.md for the
# full reasoning; summary:
#
#   Layer 1 (existing, unchanged): WatchdogLoop.ps1, a persistent process,
#     checks every 5 sec. Fast, but it IS a process - it can be killed.
#
#   Layer 2 (this script): the "Watcher Proxy Loop" task itself gets a
#     native Task Scheduler restart-on-failure policy. If the layer-1
#     PROCESS dies for any reason (crash, antivirus, someone killing it in
#     Task Manager), the Scheduler SERVICE - not our code - relaunches it.
#     Also removes the default 72-hour execution time limit, which would
#     otherwise silently kill a long-running watchdog on a machine that
#     just stays logged in for days (no crash involved at all).
#
#     IMPORTANT, confirmed by hand on a real VM: this ONLY works if the
#     task's Action IS the long-running process itself (powershell.exe
#     running WatchdogLoop.ps1 directly). An earlier version launched it
#     via a detached "wscript.exe RunWatchdogLoopHidden.vbs" wrapper -
#     Task Scheduler considered the task "successfully completed" the
#     instant that launcher script returned, and had no ongoing
#     relationship to the background process it spawned. Killing that
#     process was invisible to Task Scheduler; RestartOnFailure never
#     fired. Layer 3 alone (below) caught it in that version - which is
#     exactly why layer 3 exists independently of layer 2, not merely as
#     a backup to it.
#
#   Layer 3 (this script): a second, separate task with NO persistent
#     process - Windows fires it directly every 1 minute. It doesn't
#     exist except for the instant it runs, so it can't be "killed" the
#     way a running program can. It both restores normal internet AND
#     tries to restart the proxy, so it's a real second attempt at
#     recovery, not just a safety check.
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

$loopOk = Install-TaskFromTemplate -TaskName "Watcher Proxy Loop" -TemplateFile "WatcherProxyLoop.task.xml"
$safetyOk = Install-TaskFromTemplate -TaskName "Watcher Proxy Safety Net" -TemplateFile "WatcherProxySafetyNet.task.xml"

# Arm both immediately (their triggers alone wouldn't fire until next logon /
# 1 min from creation respectively - same reasoning as the InstallWatcher.bat
# fix for the original single-watchdog gap).
if ($loopOk) { schtasks.exe /run /tn "Watcher Proxy Loop" | Out-Null }
if ($safetyOk) { schtasks.exe /run /tn "Watcher Proxy Safety Net" | Out-Null }

if (-not ($loopOk -and $safetyOk)) { exit 1 }
exit 0
