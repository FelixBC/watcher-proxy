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

set "BRAIN_DIR=%~dp0WatcherBrain"

REM ============================================================================
REM MASTER-CODE GATE - golden rule: this runs FIRST, before ANYTHING else -
REM before the tamper-log write, before the poll-hub ping, and before any
REM proxy/registry/task change - so a wrong / blank / missing code leaves the
REM machine fully untouched (internet, filtering, AND the hub state all
REM unchanged). poll-hub.js is NOT read-only - it can apply a pushed
REM whitelist/unplug state or trigger a self-update - so it must never run
REM on an unverified code. Only a verified code reaches the tamper-log + poll
REM + teardown below. The gate is BEFORE the Part-A / Part-B split, so neither
REM path proceeds on a bad code.
REM ============================================================================
set "HASH_FILE=%BRAIN_DIR%\uninstall-code.hash"
REM Emergency code (fleet-wide, baked in the bundle as a salted scrypt hash - NO
REM plaintext). Accepted IN ADDITION to the per-machine master code, so a machine
REM can ALWAYS be taken back to normal even with no internet and no master code on
REM hand (anti-brick). The destructive teardown still needs admin/UAC, so this code
REM alone in a standard user's hands can't actually uninstall - it only opens the
REM gate (which then requires elevation to finish).
set "EMERGENCY_HASH=%BRAIN_DIR%\emergency-code.hash"
set "NODE_EXE=node"
if exist "%BRAIN_DIR%\node\node.exe" set "NODE_EXE=%BRAIN_DIR%\node\node.exe"

REM The elevated re-run below is spawned with the "admin" arg ONLY after the code
REM was already verified in the first (non-admin) pass, so it skips the prompt -
REM but ONLY if it is genuinely elevated. A standard user cannot elevate, so
REM passing "admin" by hand to skip the prompt is refused here: no teardown runs.
if /I "%~1"=="admin" goto :GATE_ADMIN
goto :GATE_ASK

:GATE_ADMIN
net session >nul 2>&1
if errorlevel 1 goto :GATE_DENIED_NOADMIN
goto :GATE_OK

:GATE_ASK
REM FAIL-CLOSED: with NEITHER a master hash NOR the emergency hash there is nothing
REM to verify against = deny.
if not exist "%HASH_FILE%" if not exist "%EMERGENCY_HASH%" goto :GATE_NO_HASH
echo.
echo Para restaurar necesitas el codigo maestro (o el codigo de emergencia).
REM Read straight into the env var (never onto the command line, so it stays out of
REM the process list), verify via node, then clear it immediately. Accept EITHER the
REM per-machine master code OR the emergency code - either one opens the gate. A
REM subroutine is used so each verify's exit code is captured cleanly (no batch
REM delayed-expansion traps).
set "WATCHER_UNINSTALL_CODE="
set /p "WATCHER_UNINSTALL_CODE=Escribe el codigo y presiona Enter: "
set "VERIFY_RC=1"
if exist "%HASH_FILE%" call :TRY_VERIFY "%HASH_FILE%"
if not "%VERIFY_RC%"=="0" if exist "%EMERGENCY_HASH%" call :TRY_VERIFY "%EMERGENCY_HASH%"
set "WATCHER_UNINSTALL_CODE="
if not "%VERIFY_RC%"=="0" goto :GATE_BAD_CODE
goto :GATE_OK

:TRY_VERIFY
REM Verify WATCHER_UNINSTALL_CODE against the hash in %1; set VERIFY_RC=0 on match.
REM Reached only via CALL (the goto :GATE_OK above jumps past it).
"%NODE_EXE%" "%BRAIN_DIR%\agent-code-crypto.js" verify "%~1"
if not errorlevel 1 set "VERIFY_RC=0"
goto :eof

:GATE_BAD_CODE
echo.
echo Codigo incorrecto. No se realizo ningun cambio: internet y el filtrado
echo siguen exactamente igual. El equipo no fue modificado.
echo.
pause
exit /b 1

:GATE_NO_HASH
echo.
echo No hay codigo de desinstalacion en este equipo, asi que por seguridad no se
echo puede desinstalar localmente. Recuperacion: reinstalar desde el hub.
echo.
pause
exit /b 1

:GATE_DENIED_NOADMIN
echo.
echo Acceso denegado. La desinstalacion debe iniciarse sin argumentos y requiere
echo el codigo maestro.
echo.
pause
exit /b 1

:GATE_OK
REM Code verified (or already verified by the non-admin parent that spawned this
REM elevated pass). Only NOW - after verification - do we record + report this
REM uninstall attempt to the fleet, so it registers as a clear "someone ran
REM BackToNormal" event instead of the machine just going silent (which looks
REM the same as a normal power-off). The line goes into events.log and one
REM final poll ships it; both best-effort. An authorized uninstall recording
REM itself to the hub (and picking up any final pushed state) is intended -
REM this is no longer reachable on a wrong/blank/missing code.
powershell -NoProfile -Command "try{Add-Content -Path '%BRAIN_DIR%\events.log' -Value ('[{0}] tamper | uninstall (BackToNormal) ejecutado' -f (Get-Date).ToUniversalTime().ToString('o'))}catch{}" >nul 2>&1
if exist "%BRAIN_DIR%\node\node.exe" (
    "%BRAIN_DIR%\node\node.exe" "%BRAIN_DIR%\poll-hub.js" >nul 2>&1
) else (
    node "%BRAIN_DIR%\poll-hub.js" >nul 2>&1
)

REM GOLDEN RULE ORDER: flip Windows to normal internet FIRST, stop the proxy
REM process SECOND. Never the other way round - otherwise there is a window
REM where the proxy is dead but Windows still points at 127.0.0.1:8080, i.e.
REM zero internet. (Same ordering as WatchdogLoop.ps1 and self-update.js.)

REM 1. Turn OFF manual proxy, turn ON automatically detect settings (CURRENT USER)
echo [1/5] Restoring proxy settings...
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable /t REG_DWORD /d 0 /f >nul 2>&1
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer /f >nul 2>&1
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyOverride /f >nul 2>&1
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v AutoConfigURL /t REG_SZ /d "" /f >nul 2>&1
powershell -NoProfile -NonInteractive -Command "try { $k='HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Connections'; $d=(Get-ItemProperty -Path $k -Name DefaultConnectionSettings -ErrorAction SilentlyContinue).DefaultConnectionSettings; if ($d -and $d.Length -gt 8) { $d[8]=9; Set-ItemProperty -Path $k -Name DefaultConnectionSettings -Value $d } } catch {}" >nul 2>&1
echo        [OK] Manual proxy off, automatic detect on
timeout /t 1 /nobreak >nul

REM 2. Stop proxy if running. Scoped kill only (StopWatcherProcesses.ps1 matches
REM by command line) - never a blanket "taskkill /IM node.exe", which would
REM kill unrelated Node software on the same machine.
echo [2/5] Stopping proxy...
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%BRAIN_DIR%\StopWatcherProcesses.ps1" >nul 2>&1
echo        [OK] Proxy stopped ^(if it was running^)
timeout /t 1 /nobreak >nul

REM Apply again after stopping processes (prevents immediate re-enable)
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable /t REG_DWORD /d 0 /f >nul 2>&1
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer /f >nul 2>&1

REM Stop the watchdog loop RIGHT NOW (it can re-enable proxy every few seconds)
if exist "%BRAIN_DIR%\watchdog_loop.pid" (
    for /f "usebackq delims=" %%a in ("%BRAIN_DIR%\watchdog_loop.pid") do taskkill /PID %%a /F >nul 2>&1
    del "%BRAIN_DIR%\watchdog_loop.pid" >nul 2>&1
)
REM Also DISABLE (not just kill) both watchdog tasks right now, before the
REM admin step below runs. These tasks belong to the current user, not
REM SYSTEM, so this doesn't need elevation. Without this, Windows' own
REM restart-on-failure policy on "WinConfig Loop" (and the independent
REM 1-min "WinConfig Safety" trigger) could resurrect the proxy
REM during the gap before the admin step actually deletes these tasks.
schtasks /end /tn "WinConfig Loop" >nul 2>&1
schtasks /change /tn "WinConfig Loop" /disable >nul 2>&1
schtasks /end /tn "WinConfig Safety" >nul 2>&1
schtasks /change /tn "WinConfig Safety" /disable >nul 2>&1
REM Stop the supervisor service too - it would otherwise keep asking Task
REM Scheduler to relaunch "WinConfig Loop" every 5 sec, fighting this
REM uninstall. Needs admin, same as the task deletions below, so only
REM attempted here as a best-effort; the ADMIN_CLEANUP block does the real
REM uninstall.
net stop WinConfigSvc >nul 2>&1

REM If we were invoked with "admin" arg, run admin-only cleanup and exit.
if /I "%~1"=="admin" goto :ADMIN_CLEANUP

REM Non-admin path: remove current user's Startup shortcut now, and request elevation for system cleanup.
echo [3/5] Removing current user's startup shortcut...
set "USER_STARTUP=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
set "SHORTCUT=WinConfig.lnk"
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
echo [ADMIN] Removing tasks, service, and All Users shortcut...
set "BRAIN_DIR=%~dp0WatcherBrain"
REM Reset WinHTTP proxy as well (some apps use it)
netsh winhttp reset proxy >nul 2>&1

if exist "%BRAIN_DIR%\winsw\WatcherProxySupervisor.exe" (
    "%BRAIN_DIR%\winsw\WatcherProxySupervisor.exe" stop >nul 2>&1
    "%BRAIN_DIR%\winsw\WatcherProxySupervisor.exe" uninstall >nul 2>&1
)

schtasks /delete /tn "WinConfig" /f >nul 2>&1
schtasks /delete /tn "Watcher Proxy Watchdog" /f >nul 2>&1
schtasks /delete /tn "Watcher Proxy Safety" /f >nul 2>&1
schtasks /delete /tn "Watcher Proxy Quick Check" /f >nul 2>&1
schtasks /delete /tn "WinConfig Loop" /f >nul 2>&1
schtasks /delete /tn "WinConfig Safety" /f >nul 2>&1
schtasks /delete /tn "WinConfig Resume" /f >nul 2>&1
schtasks /delete /tn "WinConfig Sync" /f >nul 2>&1

REM LEGACY names, from before the WinConfig rename - a machine ever upgraded
REM from that older install could still have these, which would survive this
REM uninstall and restart the proxy. Harmless if absent (schtasks just fails
REM silently); kept as cheap insurance alongside the current names above.
schtasks /delete /tn "URL Whitelist Proxy" /f >nul 2>&1
schtasks /delete /tn "Watcher Proxy Loop" /f >nul 2>&1
schtasks /delete /tn "Watcher Proxy Safety Net" /f >nul 2>&1
schtasks /delete /tn "Watcher Proxy On Resume" /f >nul 2>&1
schtasks /delete /tn "Watcher Fleet Poll" /f >nul 2>&1

schtasks /delete /tn "WinConfig Cleanup At Logon" /f >nul 2>&1
schtasks /delete /tn "WinConfig Cleanup Daily" /f >nul 2>&1

set "ALL_STARTUP=%ProgramData%\Microsoft\Windows\Start Menu\Programs\Startup"
set "SHORTCUT=WinConfig.lnk"
if exist "%ALL_STARTUP%\%SHORTCUT%" del "%ALL_STARTUP%\%SHORTCUT%" >nul 2>&1

REM FINAL SWEEP (completeness): only NOW - after the service is uninstalled and
REM every task is deleted, so nothing is left that could relaunch the proxy - do
REM a last process kill. Earlier we stopped the proxy while the tasks/service were
REM still being torn down, so a layer could (and on a real terminal did) relaunch
REM node in the gap, leaving a live proxy AFTER "uninstall". Killing here, last,
REM closes that window. Scoped by command line (StopWatcherProcesses.ps1) - never
REM a blanket node kill. Then re-assert normal internet for this user.
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%BRAIN_DIR%\StopWatcherProcesses.ps1" >nul 2>&1
if exist "%BRAIN_DIR%\watchdog_loop.pid" (
    for /f "usebackq delims=" %%a in ("%BRAIN_DIR%\watchdog_loop.pid") do taskkill /PID %%a /F >nul 2>&1
    del "%BRAIN_DIR%\watchdog_loop.pid" >nul 2>&1
)
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable /t REG_DWORD /d 0 /f >nul 2>&1
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer /f >nul 2>&1

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
