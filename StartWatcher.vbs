Set WshShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

' Get the directory where this script is located
ScriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
BrainDir = ScriptDir & "\WatcherBrain"

' Check for bundled Node.js
NodeExe = BrainDir & "\node\node.exe"
If fso.FileExists(NodeExe) Then
    ' Use bundled Node.js - run hidden (0 = hidden window)
    WshShell.Run """" & NodeExe & """ """ & BrainDir & "\proxy-server.js""", 0, False
Else
    ' Use system Node.js - run hidden (0 = hidden window)
    WshShell.Run "node """ & BrainDir & "\proxy-server.js""", 0, False
End If

Set WshShell = Nothing
Set fso = Nothing
