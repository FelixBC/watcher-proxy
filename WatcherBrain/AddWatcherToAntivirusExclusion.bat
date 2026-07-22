@echo off
title WinConfig
color 0B
cls

echo.
echo Add Watcher folder to antivirus exclusion
echo ^(so antivirus stops removing the proxy files^)
echo.

set "BRAIN_DIR=%~dp0"
pushd "%BRAIN_DIR%.." 2>nul
if errorlevel 1 (
    echo Could not find Watcher folder.
    pause
    exit /b 1
)
set "WATCHER_DIR=%CD%"
popd

powershell -NoProfile -ExecutionPolicy Bypass -File "%BRAIN_DIR%AddAntivirusExclusion.ps1" -WatcherFolder "%WATCHER_DIR%" 2>nul
set "AV_EXIT=%ERRORLEVEL%"

if %AV_EXIT% EQU 0 (
    echo [OK] Watcher folder added to Windows Defender exclusions.
    echo      The proxy should no longer be removed by Defender.
    goto :done
)
if %AV_EXIT% EQU 2 (
    echo [OK] Defender exclusion added. McAfee is installed - please also add
    echo      the Watcher folder in McAfee: My Protection -^> Real-Time Scanning
    echo      -^> Excluded Files -^> Add folder -^> select: %WATCHER_DIR%
    goto :done
)
if %AV_EXIT% EQU 3 (
    echo McAfee detected. Run this file as Administrator to add Defender exclusion.
    echo Also add the Watcher folder in McAfee: My Protection -^> Real-Time Scanning
    echo -^> Excluded Files -^> Add folder.
    echo.
    echo Watcher folder: %WATCHER_DIR%
    pause
    exit /b 1
)

echo This script must run as Administrator to add the exclusion.
echo.
echo Do this:
echo   1. Right-click this file ^(AddWatcherToAntivirusExclusion.bat^)
echo   2. Click "Run as administrator"
echo   3. If Windows asks, click Yes
echo.
echo If this PC uses another antivirus ^(Norton, Kaspersky, etc.^),
echo add this folder to that program's exclusion list:
echo. 
echo   %WATCHER_DIR%
echo.
echo See FIX_ANTIVIRUS_REMOVING_PROXY.txt in this folder for details.
echo.
pause
exit /b 1

:done
echo.
echo Run this on every PC where the proxy was installed, once per PC.
echo.
pause
