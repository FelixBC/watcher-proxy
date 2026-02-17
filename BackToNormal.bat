@echo off
title Back to Normal - Remove Proxy
color 0C
cls

echo.
echo ╔══════════════════════════════════════════════════════════════╗
echo ║                                                              ║
echo ║         BACK TO NORMAL - Removing proxy settings             ║
echo ║                                                              ║
echo ╚══════════════════════════════════════════════════════════════╝
echo.

REM 1. Stop proxy if running (node.exe)
echo [1/5] Stopping proxy...
taskkill /F /IM node.exe >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    echo        [OK] Proxy stopped
) else (
    echo        [OK] Proxy was not running
)
timeout /t 1 /nobreak >nul

REM 2. Turn OFF manual proxy, turn ON automatically detect settings
echo [2/5] Restoring proxy settings...
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable /t REG_DWORD /d 0 /f >nul 2>&1
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer /f >nul 2>&1
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyOverride /f >nul 2>&1
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v AutoConfigURL /t REG_SZ /d "" /f >nul 2>&1
powershell -NoProfile -Command "try { $k='HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Connections'; $d=(Get-ItemProperty -Path $k -Name DefaultConnectionSettings -ErrorAction SilentlyContinue).DefaultConnectionSettings; if ($d -and $d.Length -gt 8) { $d[8]=9; Set-ItemProperty -Path $k -Name DefaultConnectionSettings -Value $d } } catch {}" >nul 2>&1
echo        [OK] Manual proxy off, automatic detect on
timeout /t 1 /nobreak >nul

REM 3. Remove proxy scheduled task
echo [3/5] Removing proxy startup task...
schtasks /delete /tn "URL Whitelist Proxy" /f >nul 2>&1
echo        [OK] Proxy startup task removed
timeout /t 1 /nobreak >nul

REM 4. Remove print spool cleanup tasks (so cleanup stops running)
echo [4/5] Removing print spool cleanup tasks...
schtasks /delete /tn "Watcher Print Spool Cleanup At Logon" /f >nul 2>&1
schtasks /delete /tn "Watcher Print Spool Cleanup Daily" /f >nul 2>&1
echo        [OK] Print spool cleanup tasks removed
timeout /t 1 /nobreak >nul

REM 5. Remove Startup shortcut from current user and All Users
echo [5/5] Removing startup shortcut...
set "USER_STARTUP=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
set "ALL_STARTUP=%ProgramData%\Microsoft\Windows\Start Menu\Programs\Startup"
set "SHORTCUT=URL Whitelist Proxy.lnk"
if exist "%USER_STARTUP%\%SHORTCUT%" del "%USER_STARTUP%\%SHORTCUT%" >nul 2>&1
if exist "%ALL_STARTUP%\%SHORTCUT%" del "%ALL_STARTUP%\%SHORTCUT%" >nul 2>&1
echo        [OK] Startup shortcut removed ^(user and All Users^)

echo.
echo ╔══════════════════════════════════════════════════════════════╗
echo ║                                                              ║
echo ║              DONE - Browsing back to normal                  ║
echo ║                                                              ║
echo ╚══════════════════════════════════════════════════════════════╝
echo.
echo Proxy stopped. Manual proxy disabled. Print spool cleanup stopped.
echo You can close this window.
echo.
pause
