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
echo [1/4] Checking Node.js installation...
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

REM Step 2: Install to startup
echo [2/4] Installing to Windows Startup...
if exist "%STARTUP_FOLDER%\%SHORTCUT_NAME%" (
    del "%STARTUP_FOLDER%\%SHORTCUT_NAME%" >nul 2>&1
)

powershell -Command "$WshShell = New-Object -ComObject WScript.Shell; $Shortcut = $WshShell.CreateShortcut('%STARTUP_FOLDER%\%SHORTCUT_NAME%'); $Shortcut.TargetPath = '%SCRIPT_DIR%StartWatcher.vbs'; $Shortcut.WorkingDirectory = '%SCRIPT_DIR%'; $Shortcut.Description = 'URL Whitelist Proxy Server'; $Shortcut.Save()" >nul 2>&1

if %ERRORLEVEL% EQU 0 (
    echo        [OK] Startup shortcut created
) else (
    echo        [WARNING] Could not create startup shortcut
    echo        Proxy will still work, but won't start automatically
)
timeout /t 1 /nobreak >nul

REM Step 3: Start the proxy
echo [3/4] Starting proxy server...
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

REM Step 4: Finalize
echo [4/4] Finalizing installation...
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
echo 1. Configure your browser proxy settings:
echo    → Windows Settings → Network ^& Internet → Proxy
echo    → Turn ON "Manual proxy setup"
echo    → Address: 127.0.0.1  Port: 8080
echo    → Click Save
echo.
echo 2. Edit "whitelist.txt" to add allowed websites
echo    → One website per line (e.g., google.com)
echo    → Save the file - changes apply automatically
echo.
echo 3. The proxy will start automatically on every boot.
echo    No need to run anything manually!
echo.
echo ───────────────────────────────────────────────────────────────
echo.
echo The proxy is running silently in the background.
echo You can close this window now.
echo.
pause
