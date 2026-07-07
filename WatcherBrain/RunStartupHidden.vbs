' Launcher for StartProxyAtLogon.bat: runs it with no visible window so users don't see or close it.
' Used by the Startup shortcut so no PowerShell or CMD window appears at logon.
Set WshShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
ScriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
BatPath = fso.GetAbsolutePathName(ScriptDir & "\StartProxyAtLogon.bat")
' Run batch hidden (0 = hide window). Don't wait (False) so shortcut returns immediately.
WshShell.Run "cmd /c """ & BatPath & """", 0, False
WScript.Quit 0
