@echo off
REM Runs at logon via hidden task. Sets proxy ON and starts Node directly (no port check = faster).
cd /d "%~dp0"

REM Set proxy ON in registry
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable /t REG_DWORD /d 1 /f >nul 2>&1
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer /t REG_SZ /d "127.0.0.1:8080" /f >nul 2>&1
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyOverride /t REG_SZ /d "<local>" /f >nul 2>&1
wscript //B "%~dp0SetConnectionByte.vbs" >nul 2>&1

REM Start proxy (Priority High removed - can make Start-Process fail without admin). Task + StartWatcher run as backup.
set "BRAIN=%~dp0"
if exist "%BRAIN%node\node.exe" (
    start "" /B "%BRAIN%node\node.exe" proxy-server.js
) else (
    start "" /B node proxy-server.js
)
