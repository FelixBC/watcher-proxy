' Start the 30-second watchdog loop with no window. Task runs this at logon.
On Error Resume Next
Set WshShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
BrainDir = fso.GetParentFolderName(WScript.ScriptFullName)
WshShell.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & BrainDir & "\WatchdogLoop.ps1""", 0, False
WScript.Quit 0
