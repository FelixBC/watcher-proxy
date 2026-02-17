Set WshShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

ScriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
BrainDir = ScriptDir & "\WatcherBrain"

' Brief wait for stability when run at logon
WScript.Sleep 1500

' Start node with no console window (PowerShell -WindowStyle Hidden)
If fso.FileExists(BrainDir & "\node\node.exe") Then
    NodeExe = BrainDir & "\node\node.exe"
    WshShell.Run "powershell -WindowStyle Hidden -NoProfile -Command ""Start-Process -FilePath '" & Replace(NodeExe, "'", "''") & "' -ArgumentList 'proxy-server.js' -WorkingDirectory '" & Replace(BrainDir, "'", "''") & "' -WindowStyle Hidden""", 0, False
Else
    WshShell.Run "powershell -WindowStyle Hidden -NoProfile -Command ""Start-Process -FilePath 'node' -ArgumentList 'proxy-server.js' -WorkingDirectory '" & Replace(BrainDir, "'", "''") & "' -WindowStyle Hidden""", 0, False
End If

Set WshShell = Nothing
Set fso = Nothing
