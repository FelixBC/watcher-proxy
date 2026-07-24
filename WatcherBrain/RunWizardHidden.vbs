' Launch WinConfigWizard.ps1 with no console window. Arg 1 = Install | Uninstall.
' wscript has no console, and WshShell.Run with intWindowStyle = 0 starts PowerShell
' hidden, so the only window the user sees is the wizard itself (which self-elevates).
Set WshShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
BrainDir = fso.GetParentFolderName(WScript.ScriptFullName)
Mode = "Install"
If WScript.Arguments.Count >= 1 Then
  If LCase(WScript.Arguments(0)) = "uninstall" Then Mode = "Uninstall"
End If
WshShell.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & BrainDir & "\WinConfigWizard.ps1"" -Mode " & Mode, 0, False
WScript.Quit 0
