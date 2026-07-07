' Sets the proxy "connection" byte (DefaultConnectionSettings index 8 = 3) so Windows Settings UI shows proxy ON.
' No PowerShell = no console window flash. Uses WMI StdRegProv for REG_BINARY read/write.
On Error Resume Next
Const HKCU = &H80000001
Dim reg, keyPath, valName, arr
keyPath = "Software\Microsoft\Windows\CurrentVersion\Internet Settings\Connections"
valName = "DefaultConnectionSettings"
Set reg = GetObject("winmgmts:\\.\root\default:StdRegProv")
If reg.GetBinaryValue(HKCU, keyPath, valName, arr) <> 0 Then WScript.Quit 0
If Not IsArray(arr) Or UBound(arr) < 8 Then WScript.Quit 0
arr(8) = 3
reg.SetBinaryValue HKCU, keyPath, valName, arr
WScript.Quit 0
