# Creates "WinConfig" task to run at logon with -Hidden so no window appears (no "WinConfig" terminal).
#
# Principal is explicitly the BUILTIN\Users group, NOT left to default -
# confirmed by hand this session that Register-ScheduledTask otherwise bakes
# in the SID of whoever ran the installer as the task's specific run-as user.
# On a PC with a separate admin (install) account and a worker ("banca")
# account that actually logs in day-to-day, that would bind this task to the
# admin and it could fail to start during the worker's own session -
# defeating the whole point on exactly the machines that need it most.
param([Parameter(Mandatory=$true)] [string] $BrainDir)
$BrainDir = $BrainDir.TrimEnd('\')
$vbsPath = Join-Path $BrainDir "RunStartupHidden.vbs"
$action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$vbsPath`"" -WorkingDirectory $BrainDir
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$principal = New-ScheduledTaskPrincipal -GroupId "BUILTIN\Users" -RunLevel Limited
Unregister-ScheduledTask -TaskName "WinConfig" -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName "WinConfig" -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "Starts proxy at logon (no window)" -Force | Out-Null
