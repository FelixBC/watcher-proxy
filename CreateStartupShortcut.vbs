' Creates "URL Whitelist Proxy" shortcut. When run as Admin, uses All Users startup; else current user only.
Set WshShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

ScriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
VbsPath = ScriptDir & "\RunProxyAtStartup.vbs"
ShortcutName = "\URL Whitelist Proxy.lnk"

Sub SaveShortcut(folder)
    Dim sc
    Set sc = WshShell.CreateShortcut(folder & ShortcutName)
    sc.TargetPath = "wscript.exe"
    sc.Arguments = """" & VbsPath & """"
    sc.WorkingDirectory = ScriptDir
    sc.WindowStyle = 7
    sc.Description = "URL Whitelist Proxy"
    sc.Save
End Sub

' Try All Users startup first (requires Admin); on Access Denied, use current user
On Error Resume Next
SaveShortcut WshShell.SpecialFolders("AllUsersStartup")
If Err.Number <> 0 Then
    Err.Clear
    SaveShortcut WshShell.SpecialFolders("Startup")
End If
On Error Goto 0

WScript.Quit 0
