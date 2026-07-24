' Run the 1-minute safety-net check (CheckAndStartProxy.ps1) with no window.
' The "WinConfig Safety" task runs this every minute. Launching PowerShell via
' WshShell.Run with intWindowStyle = 0 creates it hidden from the start - unlike
' a task action of "powershell.exe -WindowStyle Hidden", which flashes a console
' in a real interactive logon before it hides itself.
On Error Resume Next
Set WshShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
BrainDir = fso.GetParentFolderName(WScript.ScriptFullName)
WshShell.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & BrainDir & "\CheckAndStartProxy.ps1""", 0, False
WScript.Quit 0
