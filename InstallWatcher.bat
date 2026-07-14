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

REM Recommended: run as Administrator so antivirus exclusion and print cleanup can be configured.
REM If not elevated, proxy will still work, but AV exclusion and some cleanup tasks may not.
net session >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo NOTE: You are NOT running as Administrator.
    echo       Proxy will install and work, but Windows Defender exclusion
    echo       and automatic print spool cleanup may not be set up.
    echo       For best results use: Right-click ^> Run as administrator.
    echo.
)

REM Get the directory where this batch file is located
set "SCRIPT_DIR=%~dp0"
set "BRAIN_DIR=%SCRIPT_DIR%WatcherBrain"
set "STARTUP_FOLDER=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
set "SHORTCUT_NAME=URL Whitelist Proxy.lnk"

REM Step 0: Ask for a friendly name + zone for this machine (small popups).
REM Optional - leaving them blank uses the Windows PC name and no zone. This
REM only sets what the dashboard shows; it never affects filtering.
echo [Setup] Machine name / zone...
powershell -NoProfile -ExecutionPolicy Bypass -File "%BRAIN_DIR%\AskIdentity.ps1" -OutDir "%SCRIPT_DIR%"
echo.

REM Step 1: Check Node.js (use folder first, then system; if neither, download into folder)
echo [1/8] Checking Node.js...
if exist "%BRAIN_DIR%\node\node.exe" (
    echo        [OK] Using Node.js in folder
) else (
    where node >nul 2>nul
    if errorlevel 1 (
        echo        Node not in folder or system. Downloading into folder ^(one-time, needs internet^)...
        powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%BRAIN_DIR%\DownloadNode.ps1" -TargetDir "%BRAIN_DIR%"
        if exist "%BRAIN_DIR%\node\node.exe" (
            echo        [OK] Node.js downloaded and ready
        ) else (
            echo        [ERROR] Download failed. Check internet or add node.exe to WatcherBrain\node\
            echo.
            pause
            exit /b 1
        )
    ) else (
        echo        [OK] Using system Node.js
    )
)
timeout /t 1 /nobreak >nul

REM Step 2: Install to run at Windows logon (hidden task = no window, no "URL Whitelist" terminal)
echo [2/8] Installing to run at Windows logon...

REM Remove any old Startup shortcut so we don't get the visible "URL Whitelist" window
if exist "%STARTUP_FOLDER%\%SHORTCUT_NAME%" del "%STARTUP_FOLDER%\%SHORTCUT_NAME%" >nul 2>&1
if exist "%ProgramData%\Microsoft\Windows\Start Menu\Programs\Startup\%SHORTCUT_NAME%" del "%ProgramData%\Microsoft\Windows\Start Menu\Programs\Startup\%SHORTCUT_NAME%" >nul 2>&1

REM Create hidden scheduled task at logon (no window at all). Watchdog backs up if proxy didn't start.
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%BRAIN_DIR%\RegisterProxyLogonTask.ps1" -BrainDir "%BRAIN_DIR%" >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    echo        [OK] Proxy runs at logon with no window ^(hidden task^)
) else (
    echo        [WARNING] Could not create logon task
)

REM 5-sec loop: at logon start a background loop that every 5 sec checks proxy; if down, sets normal internet + restarts Node.
schtasks /delete /tn "Watcher Proxy Watchdog" /f >nul 2>&1
schtasks /delete /tn "Watcher Proxy Safety" /f >nul 2>&1
schtasks /delete /tn "Watcher Proxy Quick Check" /f >nul 2>&1
REM Three independent recovery layers, not one: the fast 5-sec loop (as
REM before), Windows' own restart-on-failure policy on that same task (so
REM if the loop's PROCESS itself dies, the OS relaunches it - not our
REM code), and a separate, process-less "Safety Net" task Windows fires
REM directly every minute regardless of whether the loop is alive at all.
REM Both tasks are armed immediately (not just "at next logon") for the
REM same reason as before - see RegisterWatchdogTasks.ps1 for the full
REM reasoning. Only BackToNormal.bat removes these.
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%BRAIN_DIR%\RegisterWatchdogTasks.ps1" -BrainDir "%BRAIN_DIR%" >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    echo        [OK] If proxy dies: normal internet within 5 sec, proxy auto-restarts
    echo        [OK] If the watchdog itself dies: a Windows Service relaunches it within 5 sec ^(or run WatcherBrain\RestoreInternetNow.bat^)
) else (
    echo        [WARNING] Watchdog tasks/service may not have been created correctly
)

REM On resume from sleep: check proxy and sync settings so wake is smooth (no 2-min wait).
schtasks /delete /tn "Watcher Proxy On Resume" /f >nul 2>&1
schtasks /create /tn "Watcher Proxy On Resume" /tr "cmd /c \"%BRAIN_DIR%\OnResumeFromSleep.bat\"" /sc onevent /ec "System" /et "*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and (EventID=1)]]" /f >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    echo        [OK] On resume from sleep: proxy checked and synced so wake is smooth
)

timeout /t 1 /nobreak >nul

REM Step 3: Add antivirus exclusion - McAfee if present, else Windows Defender (run as admin)
echo [3/8] Adding antivirus exclusion ^(so antivirus doesn't remove the proxy^)...
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%BRAIN_DIR%\AddAntivirusExclusion.ps1" -WatcherFolder "%SCRIPT_DIR%" >nul 2>&1
set "AV_EXIT=%ERRORLEVEL%"
if %AV_EXIT% EQU 0 (
    echo        [OK] Watcher folder added to Windows Defender exclusions
) else if %AV_EXIT% EQU 2 (
    echo        [OK] Defender exclusion added. McAfee detected - add Watcher folder in McAfee too:
    echo        My Protection -^> Real-Time Scanning -^> Excluded Files -^> Add folder
) else if %AV_EXIT% EQU 3 (
    echo        [INFO] McAfee detected. Run as Administrator to add Defender; add Watcher folder in McAfee:
    echo        My Protection -^> Real-Time Scanning -^> Excluded Files
) else (
    echo        [INFO] Run InstallWatcher.bat as Administrator to add exclusion
    echo        For McAfee/Norton etc., add the Watcher folder to that antivirus exclusions.
)
timeout /t 1 /nobreak >nul

REM Step 4: Schedule print spool cleanup at logon, but only once per day (first logon of the day)
echo [4/8] Scheduling print spool cleanup ^(at logon, once per day^)...
set "CLEANUP_SCRIPT=%BRAIN_DIR%\CleanPrintSpoolOncePerDay.bat"
schtasks /delete /tn "Watcher Print Spool Cleanup At Logon" /f >nul 2>&1
schtasks /delete /tn "Watcher Print Spool Cleanup Daily" /f >nul 2>&1
schtasks /create /tn "Watcher Print Spool Cleanup At Logon" /tr "\"%CLEANUP_SCRIPT%\"" /sc onlogon /delay 0001:00 /ru SYSTEM /rl highest /f >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    echo        [OK] Cleanup runs at logon, once per calendar day
) else (
    echo        [WARNING] Run InstallWatcher.bat as Administrator to enable print spool cleanup
)
timeout /t 1 /nobreak >nul

REM Step 5: Start the proxy
echo [5/8] Starting proxy server...
start "" wscript.exe "%BRAIN_DIR%\StartWatcher.vbs"
timeout /t 2 /nobreak >nul

REM Check if the proxy is actually LISTENING (not just "some node.exe exists"
REM - a stray unrelated node process would have made the old tasklist check
REM report false success). CheckPort.ps1 exits 0 only if port 8080 answers.
powershell -NoProfile -NonInteractive -File "%BRAIN_DIR%\CheckPort.ps1" -Port 8080 -TimeoutMs 3000
set "PROXY_LISTENING=%ERRORLEVEL%"
if %PROXY_LISTENING% EQU 0 (
    echo        [OK] Proxy server is listening on 127.0.0.1:8080
) else (
    echo        [WARNING] Proxy did not come up - NOT switching Windows to the
    echo        manual proxy, so internet stays normal. Run InstallWatcher.bat
    echo        again, or WatcherBrain\StartWatcher.vbs manually, then re-run.
)
timeout /t 1 /nobreak >nul

REM Step 6: Configure Windows proxy (manual 127.0.0.1:8080, auto-detect OFF) -
REM ONLY if the proxy is confirmed listening. Pointing Windows at a proxy
REM that isn't there would mean no internet until the watchdog notices and
REM reverts it on its next 5-second tick - avoid that window entirely here.
echo [6/8] Configuring proxy settings...
if %PROXY_LISTENING% EQU 0 (
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable /t REG_DWORD /d 1 /f >nul 2>&1
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer /t REG_SZ /d "127.0.0.1:8080" /f >nul 2>&1
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyOverride /t REG_SZ /d "<local>" /f >nul 2>&1
    reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v AutoConfigURL /f >nul 2>&1
    REM Turn ON "Use proxy server" and OFF "Automatically detect" (byte 8: 3=proxy on, 1=proxy off, 9=autodetect on)
    powershell -NoProfile -NonInteractive -Command "try { $k='HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Connections'; $d=(Get-ItemProperty -Path $k -Name DefaultConnectionSettings -ErrorAction SilentlyContinue).DefaultConnectionSettings; if ($d -and $d.Length -gt 8) { $d[8]=3; Set-ItemProperty -Path $k -Name DefaultConnectionSettings -Value $d } } catch {}" >nul 2>&1
    echo        [OK] Manual proxy 127.0.0.1:8080, auto-detect off
) else (
    echo        [SKIPPED] Left internet on normal settings since the proxy isn't listening yet
)
timeout /t 1 /nobreak >nul

REM Step 7: Register with the fleet dashboard hub, and schedule polling every 5 min.
REM Requires WatcherBrain\HubConfig.json (not in git - copy from HubConfig.example.json
REM and fill in the real enrollment secret before packaging this install). If it's
REM missing, fleet features (bulk whitelist push, unplug/resume, dashboard visibility,
REM remote updates) are simply unavailable on this machine - the proxy itself is
REM completely unaffected either way.
echo [7/8] Registering with fleet dashboard...
if exist "%BRAIN_DIR%\HubConfig.json" (
    if exist "%BRAIN_DIR%\node\node.exe" (
        "%BRAIN_DIR%\node\node.exe" "%BRAIN_DIR%\register-with-hub.js" >nul 2>&1
    ) else (
        node "%BRAIN_DIR%\register-with-hub.js" >nul 2>&1
    )
    if exist "%BRAIN_DIR%\hub-credential.json" (
        echo        [OK] Registered with fleet dashboard
    ) else (
        echo        [WARNING] Registration failed - will retry automatically on next poll
    )

    schtasks /delete /tn "Watcher Fleet Poll" /f >nul 2>&1
    schtasks /create /tn "Watcher Fleet Poll" /tr "wscript \"%BRAIN_DIR%\RunPollHubHidden.vbs\"" /sc minute /mo 5 /f >nul 2>&1
    if %ERRORLEVEL% EQU 0 (
        echo        [OK] Will check in with the dashboard every 5 minutes
    ) else (
        echo        [WARNING] Could not schedule fleet polling
    )
) else (
    echo        [INFO] No HubConfig.json found - skipping fleet dashboard features.
    echo        Proxy filtering works normally either way. See WatcherBrain\HubConfig.example.json.
)
timeout /t 1 /nobreak >nul

REM Step 8: Finalize
echo [8/8] Finalizing installation...
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
echo 4. ANTIVIRUS: If the proxy stops, run InstallWatcher.bat as Administrator
echo    ^(adds Defender/McAfee exclusion^). Or run WatcherBrain\AddWatcherToAntivirusExclusion.bat as admin.
echo    See README.txt and WatcherBrain\FIX_ANTIVIRUS_REMOVING_PROXY.txt.
echo.
echo ───────────────────────────────────────────────────────────────
echo.
echo The proxy is running silently in the background.
echo You can close this window now.
echo.
pause
