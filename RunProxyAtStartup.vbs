' Runs at logon for whichever user is logging in. Sets proxy for current user (so non-admin users get it too), then starts proxy.
Set fso = CreateObject("Scripting.FileSystemObject")
Set WshShell = CreateObject("WScript.Shell")

ScriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
StartWatcherPath = ScriptDir & "\StartWatcher.vbs"

' Ensure proxy is set for THIS user (no admin needed; when Admin installed, shortcut runs for each user)
WshShell.RegWrite "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ProxyEnable", 1, "REG_DWORD"
WshShell.RegWrite "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ProxyServer", "127.0.0.1:8080", "REG_SZ"
WshShell.RegWrite "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ProxyOverride", "<local>", "REG_SZ"
WshShell.Run "powershell -NoProfile -Command ""try { $k='HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Connections'; $d=(Get-ItemProperty -Path $k -Name DefaultConnectionSettings -ErrorAction SilentlyContinue).DefaultConnectionSettings; if ($d -and $d.Length -gt 8) { $d[8]=1; Set-ItemProperty -Path $k -Name DefaultConnectionSettings -Value $d } } catch {}""", 0, True

' Short wait so PATH is available at logon
WScript.Sleep 3000

' Start proxy via StartWatcher.vbs, hidden (0), don't wait (False)
WshShell.Run "wscript.exe """ & StartWatcherPath & """", 0, False

Set WshShell = Nothing
Set fso = Nothing
