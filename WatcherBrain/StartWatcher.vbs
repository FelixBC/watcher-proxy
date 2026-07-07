' Start proxy (node). When this script is in WatcherBrain, BrainDir = this folder.
' If proxy is already running (port 8080 in use), exit so we don't start a second instance.
Set WshShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

BrainDir = fso.GetParentFolderName(WScript.ScriptFullName)

' When launched with "nocheck" (at logon) or "watchdog" we skip the slow port check; only one launcher runs at logon so no double start.
SkipPortCheck = False
If WScript.Arguments.Count >= 1 Then
  Dim arg1
  arg1 = LCase(Trim(WScript.Arguments(0)))
  SkipPortCheck = (arg1 = "watchdog" Or arg1 = "nocheck")
End If
If Not SkipPortCheck Then
  ' Port check: Node (CheckPort.js) is much faster than PowerShell on cold boot (~2-5s vs ~12s). Use local node.exe or system node; fall back to CheckPort.ps1.
  Dim checkCmd, exitCode
  If fso.FileExists(BrainDir & "\node\node.exe") Then
    checkCmd = """" & BrainDir & "\node\node.exe"" """ & BrainDir & "\CheckPort.js"""
  Else
    checkCmd = "node """ & BrainDir & "\CheckPort.js"""
  End If
  exitCode = WshShell.Run(checkCmd, 0, True)
  If exitCode <> 0 And exitCode <> 1 Then
    ' Node not found or script error; fall back to PowerShell (slower but works)
    checkCmd = "powershell -NoProfile -ExecutionPolicy Bypass -File """ & BrainDir & "\CheckPort.ps1"""
    exitCode = WshShell.Run(checkCmd, 0, True)
  End If
  If exitCode = 0 Then
    WScript.Quit 0
  End If
End If

' Start node with no console window (Priority High removed - it can make Start-Process fail without admin, so proxy never started)
If fso.FileExists(BrainDir & "\node\node.exe") Then
    NodeExe = BrainDir & "\node\node.exe"
    WshShell.Run "powershell -WindowStyle Hidden -NoProfile -Command ""Start-Process -FilePath '" & Replace(NodeExe, "'", "''") & "' -ArgumentList 'proxy-server.js' -WorkingDirectory '" & Replace(BrainDir, "'", "''") & "' -WindowStyle Hidden""", 0, False
Else
    WshShell.Run "powershell -WindowStyle Hidden -NoProfile -Command ""Start-Process -FilePath 'node' -ArgumentList 'proxy-server.js' -WorkingDirectory '" & Replace(BrainDir, "'", "''") & "' -WindowStyle Hidden""", 0, False
End If

Set WshShell = Nothing
Set fso = Nothing
