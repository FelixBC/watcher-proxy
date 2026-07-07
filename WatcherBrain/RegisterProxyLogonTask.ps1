# Creates "URL Whitelist Proxy" task to run at logon with -Hidden so no window appears (no "URL Whitelist" terminal).
param([Parameter(Mandatory=$true)] [string] $BrainDir)
$BrainDir = $BrainDir.TrimEnd('\')
$vbsPath = Join-Path $BrainDir "RunStartupHidden.vbs"
$action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$vbsPath`"" -WorkingDirectory $BrainDir
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Unregister-ScheduledTask -TaskName "URL Whitelist Proxy" -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName "URL Whitelist Proxy" -Action $action -Trigger $trigger -Settings $settings -Description "Starts proxy at logon (no window)" -Force | Out-Null
