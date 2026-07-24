' Start proxy (node). When this script is in WatcherBrain, BrainDir = this folder.
' If the proxy is already listening on 8080, exit without starting a second node.
'
' We ALWAYS check the port first now. The old "watchdog"/"nocheck" fast-path that
' SKIPPED this check assumed "only one launcher runs at logon" - that is FALSE on
' real hardware, where the logon task, the 5s watchdog and the 1-min safety net
' all fire at once. Skipping the check spawned 2+ node processes that fought over
' 8080 (EADDRINUSE) and took internet down. proxy-server.js now also exits cleanly
' on EADDRINUSE (the port is the real single-instance lock); checking here first
' just avoids spawning a doomed node every time. Any arg (e.g. "watchdog") is
' accepted and ignored, so existing callers keep working.
Set WshShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

BrainDir = fso.GetParentFolderName(WScript.ScriptFullName)

' Port check: Node (CheckPort.js) is much faster than PowerShell on cold boot
' (~2-5s vs ~12s). Use local node.exe or system node; fall back to CheckPort.ps1.
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
  ' Proxy already listening - nothing to do.
  WScript.Quit 0
End If

' Start node with no console window. wscript itself has no console, and
' WshShell.Run with intWindowStyle = 0 creates node hidden from the start. We do
' NOT wrap it in "powershell -WindowStyle Hidden -Command Start-Process ...": that
' wrapper powershell.exe flashes its own console window in a real interactive
' logon (one of the visible black windows reported on real hardware). Set the
' working directory so node resolves proxy-server.js relative to WatcherBrain.
WshShell.CurrentDirectory = BrainDir
If fso.FileExists(BrainDir & "\node\node.exe") Then
    WshShell.Run """" & BrainDir & "\node\node.exe"" proxy-server.js", 0, False
Else
    WshShell.Run "node proxy-server.js", 0, False
End If

Set WshShell = Nothing
Set fso = Nothing
