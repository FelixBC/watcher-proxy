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

REM This script has TWO parts:
REM - Part A (always): revert proxy settings for the CURRENT logged-in user (HKCU)
REM - Part B (admin only): remove scheduled tasks (SYSTEM) and All Users startup shortcut
REM
REM If you're not admin, it will run Part A and then ask once for admin to run Part B.

REM 1. Stop proxy if running (node.exe)
echo [1/5] Stopping proxy...
set "BRAIN_DIR=%~dp0WatcherBrain"
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%BRAIN_DIR%\StopWatcherProcesses.ps1" >nul 2>&1
taskkill /F /IM node.exe >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    echo        [OK] Proxy stopped
) else (
    echo        [OK] Proxy was not running
)
timeout /t 1 /nobreak >nul

REM 2. Turn OFF manual proxy, turn ON automatically detect settings (CURRENT USER)
echo [2/5] Restoring proxy settings...
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable /t REG_DWORD /d 0 /f >nul 2>&1
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer /f >nul 2>&1
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyOverride /f >nul 2>&1
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v AutoConfigURL /t REG_SZ /d "" /f >nul 2>&1
powershell -NoProfile -NonInteractive -Command "try { $k='HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Connections'; $d=(Get-ItemProperty -Path $k -Name DefaultConnectionSettings -ErrorAction SilentlyContinue).DefaultConnectionSettings; if ($d -and $d.Length -gt 8) { $d[8]=9; Set-ItemProperty -Path $k -Name DefaultConnectionSettings -Value $d } } catch {}" >nul 2>&1
echo        [OK] Manual proxy off, automatic detect on
timeout /t 1 /nobreak >nul

REM Apply again after stopping processes (prevents immediate re-enable)
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable /t REG_DWORD /d 0 /f >nul 2>&1
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer /f >nul 2>&1

REM Stop the watchdog loop RIGHT NOW (it can re-enable proxy every few seconds)
if exist "%BRAIN_DIR%\watchdog_loop.pid" (
    for /f "usebackq delims=" %%a in ("%BRAIN_DIR%\watchdog_loop.pid") do taskkill /PID %%a /F >nul 2>&1
    del "%BRAIN_DIR%\watchdog_loop.pid" >nul 2>&1
)

REM If we were invoked with "admin" arg, run admin-only cleanup and exit.
if /I "%~1"=="admin" goto :ADMIN_CLEANUP

REM Non-admin path: remove current user's Startup shortcut now, and request elevation for system cleanup.
echo [3/5] Removing current user's startup shortcut...
set "USER_STARTUP=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
set "SHORTCUT=URL Whitelist Proxy.lnk"
if exist "%USER_STARTUP%\%SHORTCUT%" del "%USER_STARTUP%\%SHORTCUT%" >nul 2>&1
echo        [OK] User startup shortcut removed
timeout /t 1 /nobreak >nul

REM Request admin to remove scheduled tasks + All Users shortcut (SYSTEM tasks require admin)
echo [4/5] Removing scheduled tasks and All Users startup shortcut...
powershell -NoProfile -NonInteractive -Command "Start-Process -FilePath '%~f0' -ArgumentList 'admin' -Verb RunAs" >nul 2>&1
echo        [OK] If prompted, click Yes to finish removal
timeout /t 1 /nobreak >nul

echo [5/5] Done for this user.
goto :DONE

:ADMIN_CLEANUP
REM Admin-only removal (does NOT touch HKCU of the admin account beyond what already happened)
echo [ADMIN] Removing tasks and All Users shortcut...
set "BRAIN_DIR=%~dp0WatcherBrain"
REM Reset WinHTTP proxy as well (some apps use it)
netsh winhttp reset proxy >nul 2>&1

schtasks /delete /tn "URL Whitelist Proxy" /f >nul 2>&1
schtasks /delete /tn "Watcher Proxy Watchdog" /f >nul 2>&1
schtasks /delete /tn "Watcher Proxy Safety" /f >nul 2>&1
schtasks /delete /tn "Watcher Proxy Quick Check" /f >nul 2>&1
schtasks /delete /tn "Watcher Proxy Loop" /f >nul 2>&1
schtasks /delete /tn "Watcher Proxy On Resume" /f >nul 2>&1

schtasks /delete /tn "Watcher Print Spool Cleanup At Logon" /f >nul 2>&1
schtasks /delete /tn "Watcher Print Spool Cleanup Daily" /f >nul 2>&1

set "ALL_STARTUP=%ProgramData%\Microsoft\Windows\Start Menu\Programs\Startup"
set "SHORTCUT=URL Whitelist Proxy.lnk"
if exist "%ALL_STARTUP%\%SHORTCUT%" del "%ALL_STARTUP%\%SHORTCUT%" >nul 2>&1

echo [ADMIN] Tasks and All Users shortcut removed.
goto :DONE

:DONE
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
