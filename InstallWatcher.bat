@echo off
title Installing URL Whitelist Proxy
color 0B
cls

echo.
echo ╔══════════════════════════════════════════════════════════════╗
echo ║                                                              ║
echo ║         INSTALLING URL WHITELIST PROXY                      ║
echo ║                                                              ║
echo ╚══════════════════════════════════════════════════════════════╝
echo.
echo Please wait while we set up the proxy...
echo.

REM Get the directory where this batch file is located
set "SCRIPT_DIR=%~dp0"
set "BRAIN_DIR=%SCRIPT_DIR%WatcherBrain"
set "STARTUP_FOLDER=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
set "SHORTCUT_NAME=URL Whitelist Proxy.lnk"

REM Step 1: Check Node.js
echo [1/6] Checking Node.js installation...
if exist "%BRAIN_DIR%\node\node.exe" (
    echo        [OK] Bundled Node.js found
) else (
    where node >nul 2>nul
    if %ERRORLEVEL% EQU 0 (
        echo        [OK] System Node.js found
    ) else (
        echo        [ERROR] Node.js not found!
        echo.
        echo        This package should include Node.js.
        echo        Please re-extract the complete package.
        echo.
        pause
        exit /b 1
    )
)
timeout /t 1 /nobreak >nul

REM Step 2: Install to run at Windows logon (Startup folder + Task Scheduler backup)
echo [2/6] Installing to run at Windows logon...

REM Always add shortcut to Startup folder (VBS handles paths so # and special chars work)
if exist "%STARTUP_FOLDER%\%SHORTCUT_NAME%" del "%STARTUP_FOLDER%\%SHORTCUT_NAME%" >nul 2>&1
wscript.exe "%SCRIPT_DIR%CreateStartupShortcut.vbs" >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    echo        [OK] Startup shortcut added - look for "URL Whitelist Proxy" in Settings ^> Apps ^> Startup
) else (
    echo        [WARNING] Could not add Startup shortcut
)

REM Scheduled task runs FIRST at logon (0 delay) so proxy starts before Discord etc.; uses same VBS launcher
schtasks /delete /tn "URL Whitelist Proxy" /f >nul 2>&1
schtasks /create /tn "URL Whitelist Proxy" /tr "wscript.exe \"%SCRIPT_DIR%RunProxyAtStartup.vbs\"" /sc onlogon /delay 0000:00 /f >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    echo        [OK] Task runs at logon ^(proxy ready in ~7 sec, no window^)
)
timeout /t 1 /nobreak >nul

REM Step 3: Schedule print spool cleanup (at logon + every 24 hours) - requires admin to create
echo [3/6] Scheduling print spool cleanup ^(at logon + every 24h^)...
set "CLEANUP_SCRIPT=%SCRIPT_DIR%WatcherBrain\CleanPrintSpool.bat"
schtasks /delete /tn "Watcher Print Spool Cleanup At Logon" /f >nul 2>&1
schtasks /delete /tn "Watcher Print Spool Cleanup Daily" /f >nul 2>&1
schtasks /create /tn "Watcher Print Spool Cleanup At Logon" /tr "\"%CLEANUP_SCRIPT%\"" /sc onlogon /delay 0001:00 /ru SYSTEM /rl highest /f >nul 2>&1
schtasks /create /tn "Watcher Print Spool Cleanup Daily" /tr "\"%CLEANUP_SCRIPT%\"" /sc daily /st 03:00 /ru SYSTEM /rl highest /f >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    echo        [OK] Cleanup runs for any user ^(1 min after logon + daily 03:00^)
) else (
    echo        [WARNING] Run InstallWatcher.bat as Administrator to enable print spool cleanup
)
timeout /t 1 /nobreak >nul

REM Step 4: Start the proxy
echo [4/6] Starting proxy server...
start "" wscript.exe "%SCRIPT_DIR%StartWatcher.vbs"
timeout /t 2 /nobreak >nul

REM Check if proxy started
tasklist /FI "IMAGENAME eq node.exe" 2>nul | find /I /N "node.exe">nul
if %ERRORLEVEL% EQU 0 (
    echo        [OK] Proxy server is running
) else (
    echo        [WARNING] Proxy may not have started
    echo        Try running "StartWatcher.vbs" manually
)
timeout /t 1 /nobreak >nul

REM Step 5: Configure Windows proxy (manual 127.0.0.1:8080, auto-detect OFF)
echo [5/6] Configuring proxy settings...
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable /t REG_DWORD /d 1 /f >nul 2>&1
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer /t REG_SZ /d "127.0.0.1:8080" /f >nul 2>&1
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyOverride /t REG_SZ /d "<local>" /f >nul 2>&1
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v AutoConfigURL /f >nul 2>&1
REM Turn OFF "Automatically detect settings" (byte 8 of DefaultConnectionSettings = 1)
powershell -NoProfile -Command "try { $k='HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Connections'; $d=(Get-ItemProperty -Path $k -Name DefaultConnectionSettings -ErrorAction SilentlyContinue).DefaultConnectionSettings; if ($d -and $d.Length -gt 8) { $d[8]=1; Set-ItemProperty -Path $k -Name DefaultConnectionSettings -Value $d } } catch {}" >nul 2>&1
echo        [OK] Manual proxy 127.0.0.1:8080, auto-detect off
timeout /t 1 /nobreak >nul

REM Step 6: Finalize
echo [6/6] Finalizing installation...
timeout /t 1 /nobreak >nul

echo.
echo ╔══════════════════════════════════════════════════════════════╗
echo ║                                                              ║
echo ║              INSTALLATION COMPLETE!                         ║
echo ║                                                              ║
echo ╚══════════════════════════════════════════════════════════════╝
echo.
echo The proxy is now running in the background.
echo.
echo NEXT STEPS:
echo ───────────────────────────────────────────────────────────────
echo.
echo 1. Proxy is set to 127.0.0.1:8080 ^(browser uses it automatically^)
echo.
echo 2. Edit "whitelist.txt" to add allowed websites
echo    → One website per line (e.g., google.com)
echo    → Save the file - changes apply automatically
echo.
echo 3. Proxy starts automatically on every boot.
echo    No need to run anything manually!
echo.
echo ───────────────────────────────────────────────────────────────
echo.
echo The proxy is running silently in the background.
echo You can close this window now.
echo.
pause
