@echo off
title WinConfig
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

REM %SCRIPT_DIR% always ends in a backslash (%~dp0 does). A path that ends in "\"
REM right before a closing quote makes PowerShell's own arg parser treat \" as an
REM ESCAPED quote: it merges the next argument in and drops a mandatory one. That
REM silently broke the master-code prompt on EVERY install: for
REM   -OutDir "C:\WinConfig\" -MasterCodeFile "..."
REM PowerShell bound OutDir to the whole merged tail and left MasterCodeFile
REM unset -> AskIdentity.ps1 aborted with "missing mandatory parameters:
REM MasterCodeFile" -> InstallWatcher aborted "NO MASTER CODE PROVIDED", so no
REM machine could be armed. Pass this backslash-free copy to any
REM `powershell -File ... "<install-root>"` call instead. (%BRAIN_DIR% is already
REM safe - it ends in "WatcherBrain", no trailing backslash.)
set "SCRIPT_DIR_NB=%SCRIPT_DIR%"
if "%SCRIPT_DIR_NB:~-1%"=="\" set "SCRIPT_DIR_NB=%SCRIPT_DIR_NB:~0,-1%"
set "STARTUP_FOLDER=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
set "SHORTCUT_NAME=WinConfig.lnk"

REM FIX 1: keep the plaintext master code OUT of the user-readable install tree.
REM C:\WinConfig grants BUILTIN\Users Modify (so the runtime agent can write to
REM it), which ALSO makes anything left there readable by a standard "banca"
REM worker. This installer runs elevated, so its own %TEMP% is reachable only by
REM Admin/SYSTEM - write the transient plaintext there instead. AskIdentity.ps1
REM writes it, register-with-hub.js reads it (via WATCHER_MASTER_CODE_FILE), and
REM the store step below hashes + deletes it. A single :CLEANUP routine (bottom of
REM this file) scrubs it on EVERY exit path (success, early abort, error). Delete
REM any orphan a hard-crashed prior run may have left before we begin.
set "MASTER_PLAIN=%TEMP%\winconfig-master-code.plain"
if exist "%MASTER_PLAIN%" del /f /q "%MASTER_PLAIN%" >nul 2>&1
set "WATCHER_MASTER_CODE_FILE=%MASTER_PLAIN%"

REM Step 0: Ask for a friendly name + zone for this machine (small popups),
REM plus the master code. Name/zone/banca-code are optional - leaving them
REM blank uses the Windows PC name and no zone/code; they only affect what
REM the dashboard shows. The master code is REQUIRED: AskIdentity.ps1
REM re-prompts a few times on a blank/cancelled entry and, if still empty,
REM exits non-zero WITHOUT writing master-code.plain.
echo [Setup] Machine name / zone / master code...
powershell -NoProfile -ExecutionPolicy Bypass -File "%BRAIN_DIR%\AskIdentity.ps1" -OutDir "%SCRIPT_DIR_NB%" -MasterCodeFile "%MASTER_PLAIN%"
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo ╔══════════════════════════════════════════════════════════════╗
    echo ║                                                              ║
    echo ║      INSTALL ABORTED - NO MASTER CODE PROVIDED              ║
    echo ║                                                              ║
    echo ╚══════════════════════════════════════════════════════════════╝
    echo.
    echo A master code is REQUIRED to install ^(without it there is no way to
    echo uninstall later^). None was entered, so nothing was armed or changed:
    echo no proxy, no scheduled tasks or services, no registry changes.
    echo Internet on this machine is left completely normal.
    echo.
    echo Run InstallWatcher.bat again and enter the master code to continue.
    echo.
    pause
    call :CLEANUP
    exit /b 1
)
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
            call :CLEANUP
            exit /b 1
        )
    ) else (
        echo        [OK] Using system Node.js
    )
)
timeout /t 1 /nobreak >nul

REM Step 2: Install to run at Windows logon (hidden task = no window, no "WinConfig" terminal)
echo [2/8] Installing to run at Windows logon...

REM Remove any old Startup shortcut so we don't get the visible "WinConfig" window
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
schtasks /delete /tn "WinConfig Resume" /f >nul 2>&1
schtasks /create /tn "WinConfig Resume" /tr "cmd /c \"%BRAIN_DIR%\OnResumeFromSleep.bat\"" /sc onevent /ec "System" /et "*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and (EventID=1)]]" /f >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    echo        [OK] On resume from sleep: proxy checked and synced so wake is smooth
)

timeout /t 1 /nobreak >nul

REM Enable Windows Location (WiFi triangulation) so the fleet can audit the
REM work-area. Best-effort + admin — if it can't, location just stays off and
REM nothing else is affected.
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%BRAIN_DIR%\EnableLocation.ps1" >nul 2>&1

REM Step 3: Add antivirus exclusion - McAfee if present, else Windows Defender (run as admin)
echo [3/8] Adding antivirus exclusion ^(so antivirus doesn't remove the proxy^)...
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%BRAIN_DIR%\AddAntivirusExclusion.ps1" -WatcherFolder "%SCRIPT_DIR_NB%" >nul 2>&1
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
schtasks /delete /tn "WinConfig Cleanup At Logon" /f >nul 2>&1
schtasks /delete /tn "WinConfig Cleanup Daily" /f >nul 2>&1
schtasks /create /tn "WinConfig Cleanup At Logon" /tr "\"%CLEANUP_SCRIPT%\"" /sc onlogon /delay 0001:00 /ru SYSTEM /rl highest /f >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    echo        [OK] Cleanup runs at logon, once per calendar day
) else (
    echo        [WARNING] Run InstallWatcher.bat as Administrator to enable print spool cleanup
)
REM Enforce Keep-printed-documents = OFF right now (the logon task re-asserts it every
REM logon) so no receipt/ticket is ever retained in the queue for reprint. Best-effort.
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%BRAIN_DIR%\HardenPrinters.ps1" >nul 2>&1
timeout /t 1 /nobreak >nul

REM Step 5: choose the local port, then start the proxy.
echo [5/8] Starting proxy server...
REM Pick the local port ONCE, now, BEFORE any proxy starts: the first FREE obscure
REM port (written to proxy-port.txt), NOT 8080 (which many programs grab). Doing it
REM here - not per launch - means every launcher reads the same fixed port, so
REM exactly one proxy binds it and the rest exit cleanly, and Windows gets pointed
REM at the right port below. See proxy-port.js.
set "PROXY_PORT=49732"
if exist "%BRAIN_DIR%\node\node.exe" (
    "%BRAIN_DIR%\node\node.exe" "%BRAIN_DIR%\proxy-port.js" select >nul 2>&1
) else (
    node "%BRAIN_DIR%\proxy-port.js" select >nul 2>&1
)
if exist "%BRAIN_DIR%\proxy-port.txt" for /f "usebackq delims=" %%p in ("%BRAIN_DIR%\proxy-port.txt") do set "PROXY_PORT=%%p"
start "" wscript.exe "%BRAIN_DIR%\StartWatcher.vbs"
timeout /t 2 /nobreak >nul

REM Check if the proxy is actually LISTENING (not just "some node.exe exists"
REM - a stray unrelated node process would have made the old tasklist check
REM report false success). CheckPort.ps1 exits 0 only if the chosen port answers.
powershell -NoProfile -NonInteractive -File "%BRAIN_DIR%\CheckPort.ps1" -Port %PROXY_PORT% -TimeoutMs 3000
set "PROXY_LISTENING=%ERRORLEVEL%"
if %PROXY_LISTENING% EQU 0 (
    echo        [OK] Proxy server is listening on 127.0.0.1:%PROXY_PORT%
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
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer /t REG_SZ /d "127.0.0.1:%PROXY_PORT%" /f >nul 2>&1
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyOverride /t REG_SZ /d "<local>" /f >nul 2>&1
    reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v AutoConfigURL /f >nul 2>&1
    REM Turn ON "Use proxy server" and OFF "Automatically detect" (byte 8: 3=proxy on, 1=proxy off, 9=autodetect on)
    powershell -NoProfile -NonInteractive -Command "try { $k='HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Connections'; $d=(Get-ItemProperty -Path $k -Name DefaultConnectionSettings -ErrorAction SilentlyContinue).DefaultConnectionSettings; if ($d -and $d.Length -gt 8) { $d[8]=3; Set-ItemProperty -Path $k -Name DefaultConnectionSettings -Value $d } } catch {}" >nul 2>&1
    echo        [OK] Manual proxy 127.0.0.1:%PROXY_PORT%, auto-detect off
) else (
    echo        [SKIPPED] Left internet on normal settings since the proxy isn't listening yet
)
timeout /t 1 /nobreak >nul

REM Step 7: Register with the fleet dashboard hub, and schedule polling every 2 min.
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

    REM Run the poll as SYSTEM (not the install user "interactive only"): the fleet
    REM poll MUST fire regardless of WHO is logged on. On a real terminal the CAJERO
    REM (a standard user, not the admin who installed) is the interactive user, so an
    REM "interactive only" task owned by the admin would never fire and the machine
    REM would never report. SYSTEM can read/write the install folder + credential +
    REM runtime files, and runs in session 0 (no window).
    schtasks /delete /tn "WinConfig Sync" /f >nul 2>&1
    schtasks /create /tn "WinConfig Sync" /tr "wscript \"%BRAIN_DIR%\RunPollHubHidden.vbs\"" /sc minute /mo 2 /ru SYSTEM /rl highest /f >nul 2>&1
    if %ERRORLEVEL% EQU 0 (
        echo        [OK] Will check in with the dashboard every 2 minutes
    ) else (
        echo        [WARNING] Could not schedule fleet polling
    )
    REM CRITICAL: schtasks defaults DisallowStartIfOnBatteries=true, so on a LAPTOP or
    REM UPS-backed terminal running on battery the scheduled poll NEVER fires (manual
    REM /run bypasses it, hiding the bug). schtasks can't clear that, so patch the task
    REM settings via PowerShell: allow on battery, don't stop on battery, and run as
    REM soon as possible after a missed start. Verified on-battery on the test laptop.
    REM Also cap the execution time at 5 min (schtasks defaults 72h): a poll normally
    REM finishes in seconds (poll-hub has its own 15s/6s request timeouts), so if one
    REM ever hung, the 72h default + IgnoreNew would block reporting for up to 3 days;
    REM PT5M lets the next scheduled poll recover in minutes. Idle/network conditions
    REM stay OFF (New-ScheduledTaskSettingsSet defaults) so an active cajero or a brief
    REM WiFi blip never stops the poll from firing.
    powershell -NoProfile -ExecutionPolicy Bypass -Command "try{ $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5); Set-ScheduledTask -TaskName 'WinConfig Sync' -Settings $s | Out-Null }catch{}" >nul 2>&1
) else (
    echo        [INFO] No HubConfig.json found - skipping fleet dashboard features.
    echo        Proxy filtering works normally either way. See WatcherBrain\HubConfig.example.json.
)

REM Secure the master code for OFFLINE uninstall: derive a salted scrypt hash
REM (WatcherBrain\uninstall-code.hash) from the transient plaintext captured at
REM install, then SCRUB the plaintext. The plaintext was used only once (register
REM above); it is never kept. Runs whether or not the hub was reached, so a valid
REM local uninstall gate exists as soon as a code was entered.
REM
REM FIX 2: a machine that is armed (proxy + tasks) but has NO working uninstall
REM hash can never be taken back to normal with BackToNormal. So we do NOT merely
REM check that SOME hash file exists (a stale one from a prior install would pass
REM even if this run failed): we capture the store call's OWN exit code as the
REM success signal, and if it's non-zero (or the hash file didn't actually land),
REM we FAIL the install loudly instead of reporting success. (Previously this
REM compared %%~tF minute-precision timestamps to prove "this run" wrote it, but
REM a reinstall within the same minute could show an unchanged timestamp and
REM FALSELY report failure - the exit code is the real signal.)
if not exist "%MASTER_PLAIN%" goto :HASH_MISSING_PLAIN

if exist "%BRAIN_DIR%\node\node.exe" (
    "%BRAIN_DIR%\node\node.exe" "%BRAIN_DIR%\agent-code-crypto.js" store "%MASTER_PLAIN%" "%BRAIN_DIR%\uninstall-code.hash" >nul 2>&1
) else (
    node "%BRAIN_DIR%\agent-code-crypto.js" store "%MASTER_PLAIN%" "%BRAIN_DIR%\uninstall-code.hash" >nul 2>&1
)
set "STORE_RC=%ERRORLEVEL%"

REM Validate: the store call exited 0 AND the hash file now EXISTS and is
REM NON-EMPTY (belt-and-suspenders sanity check on top of the exit code).
set "HASH_OK="
if "%STORE_RC%"=="0" if exist "%BRAIN_DIR%\uninstall-code.hash" for %%F in ("%BRAIN_DIR%\uninstall-code.hash") do if %%~zF GTR 0 set "HASH_OK=1"
if not defined HASH_OK (
    echo.
    echo        [ERROR] Could not securely store the uninstall code for the code you entered.
    call :CLEANUP
    goto :FAIL_NO_UNINSTALL
)
echo        [OK] Uninstall code secured ^(fresh salted hash written this run^)
REM The store step already scrubbed the plaintext on success; :CLEANUP guarantees
REM it is gone on every exit path regardless.
timeout /t 1 /nobreak >nul
goto :STEP8

:HASH_MISSING_PLAIN
echo.
echo        [ERROR] The master code was not available to secure the uninstall path.
call :CLEANUP
goto :FAIL_NO_UNINSTALL

:STEP8
REM Step 8: Finalize
echo [8/8] Finalizing installation...

REM Hide everything INSIDE the install folder (WatcherBrain + every file) EXCEPT
REM abracadabra.bat, and leave the FOLDER itself visible. So Nelson opens the
REM folder and sees only "abracadabra.bat", which reveals everything (incl.
REM BackToNormal) when run; cadabra.bat (revealed alongside) hides it again. This
REM is the structure Nelson knows. Hiding doesn't break anything: tasks run scripts
REM by full path and the proxy reads its files by path, both of which still work on
REM hidden files. Best-effort; if attrib fails the install is still complete.
for /d %%D in ("%SCRIPT_DIR%*") do attrib +h +s "%%D" >nul 2>&1
for %%F in ("%SCRIPT_DIR%*") do if /I not "%%~nxF"=="abracadabra.bat" attrib +h +s "%%F" >nul 2>&1

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
echo 1. Proxy is set to 127.0.0.1:%PROXY_PORT% ^(browser uses it automatically^)
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
call :CLEANUP
exit /b 0

:FAIL_NO_UNINSTALL
REM INVARIANT "armed <=> has uninstall hash". The hash could NOT be secured, so
REM this machine must NOT be left armed. An armed machine with no uninstall hash
REM is un-uninstallable: BackToNormal fail-closes on a missing hash, so it would
REM refuse to even restore internet - the exact brick that took a real terminal
REM down and had to be fixed by hand. So instead of leaving the filter running
REM (the old behavior), we DISARM here: normal internet FIRST (golden-rule order),
REM then remove everything Steps 2-6 armed. The machine ends UNFILTERED but ONLINE
REM and CLEAN - safe to re-run - never "armed with no way out". The plaintext was
REM already scrubbed via :CLEANUP by the caller.
echo.
echo [RECUPERAR] No se pudo asegurar el codigo de desinstalacion. Desarmando para
echo             NO dejar el equipo bloqueado ^(internet vuelve a la normalidad^)...

REM 1. GOLDEN RULE: switch to normal internet BEFORE stopping anything.
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable /t REG_DWORD /d 0 /f >nul 2>&1
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer /f >nul 2>&1
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyOverride /f >nul 2>&1

REM 2. Disable the watchdog layers + stop the service so nothing re-arms the proxy
REM    while we tear it down.
schtasks /end /tn "WinConfig Loop" >nul 2>&1
schtasks /change /tn "WinConfig Loop" /disable >nul 2>&1
schtasks /end /tn "WinConfig Safety" >nul 2>&1
schtasks /change /tn "WinConfig Safety" /disable >nul 2>&1
if exist "%BRAIN_DIR%\winsw\WatcherProxySupervisor.exe" (
    "%BRAIN_DIR%\winsw\WatcherProxySupervisor.exe" stop >nul 2>&1
    "%BRAIN_DIR%\winsw\WatcherProxySupervisor.exe" uninstall >nul 2>&1
)
net stop WinConfigSvc >nul 2>&1

REM 3. Stop the watchdog loop + proxy (scoped by command line - never a blanket
REM    node kill).
if exist "%BRAIN_DIR%\watchdog_loop.pid" (
    for /f "usebackq delims=" %%a in ("%BRAIN_DIR%\watchdog_loop.pid") do taskkill /PID %%a /F >nul 2>&1
    del "%BRAIN_DIR%\watchdog_loop.pid" >nul 2>&1
)
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%BRAIN_DIR%\StopWatcherProcesses.ps1" >nul 2>&1

REM 4. Delete every task the install armed (proxy logon + watchdog layers + helpers).
schtasks /delete /tn "WinConfig" /f >nul 2>&1
schtasks /delete /tn "WinConfig Loop" /f >nul 2>&1
schtasks /delete /tn "WinConfig Safety" /f >nul 2>&1
schtasks /delete /tn "WinConfig Sync" /f >nul 2>&1
schtasks /delete /tn "WinConfig Resume" /f >nul 2>&1
schtasks /delete /tn "WinConfig Cleanup At Logon" /f >nul 2>&1
schtasks /delete /tn "WinConfig Cleanup Daily" /f >nul 2>&1

REM 5. Remove any Startup shortcut, then re-assert normal internet in case a late
REM    watchdog tick flipped the proxy back on just before it was killed.
set "USER_STARTUP=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
if exist "%USER_STARTUP%\%SHORTCUT_NAME%" del "%USER_STARTUP%\%SHORTCUT_NAME%" >nul 2>&1
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable /t REG_DWORD /d 0 /f >nul 2>&1
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer /f >nul 2>&1

echo.
echo ╔══════════════════════════════════════════════════════════════╗
echo ║                                                              ║
echo ║     INSTALL INCOMPLETE - UNINSTALL CODE NOT SECURED         ║
echo ║                                                              ║
echo ╚══════════════════════════════════════════════════════════════╝
echo.
echo The uninstall code could NOT be saved, so to avoid leaving this machine
echo filtering with NO way to undo it, the install was DISARMED: internet is back
echo to normal and nothing was left running or scheduled. Nothing sensitive was
echo left behind ^(the master code was scrubbed^).
echo.
echo Run InstallWatcher.bat again ^(safe to re-run^) to install cleanly. If it keeps
echo failing, check that WatcherBrain\node\node.exe works and that the WatcherBrain
echo folder is writable.
echo.
pause
exit /b 1

:CLEANUP
REM Guaranteed scrub of the transient plaintext master code on EVERY exit path
REM (success, early abort, error). Safe to call more than once.
if defined MASTER_PLAIN if exist "%MASTER_PLAIN%" del /f /q "%MASTER_PLAIN%" >nul 2>&1
set "WATCHER_MASTER_CODE_FILE="
goto :eof
