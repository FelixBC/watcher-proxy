' Runs poll-hub.js once, hidden, with no console window. Invoked every 2
' minutes by the "Watcher Fleet Poll" scheduled task.
On Error Resume Next
Set WshShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
BrainDir = fso.GetParentFolderName(WScript.ScriptFullName)

If fso.FileExists(BrainDir & "\node\node.exe") Then
    NodeExe = BrainDir & "\node\node.exe"
Else
    NodeExe = "node"
End If

WshShell.Run """" & NodeExe & """ """ & BrainDir & "\poll-hub.js""", 0, True
WScript.Quit 0
