@echo off
REM Runs at logon via the hidden "WinConfig" task (RunStartupHidden.vbs -> this).
REM
REM GOLDEN RULE: we only turn Windows' proxy ON once the proxy is actually
REM LISTENING - never before. The old version wrote ProxyEnable=1 immediately and
REM THEN started node, leaving a window at every logon where Windows pointed at a
REM dead 127.0.0.1:8080 = internet FULLY DOWN until the watchdog noticed. Now
REM SetProxyByAvailability.ps1 owns that decision (PE=1 only if 8080 answers, else
REM normal internet / fail-open), exactly like the installer's Step 5/6.
cd /d "%~dp0"
set "BRAIN=%~dp0"
set "NODE_EXE=node"
if exist "%BRAIN%node\node.exe" set "NODE_EXE=%BRAIN%node\node.exe"

REM PLAN 0007: if a blue-green update cutover is in progress, do NOT start a proxy.
REM self-update owns the proxy lifecycle AND the registry during that window; a logon
REM race here could spawn a rogue third proxy (ADR 0001, condition 1) or fight the
REM cutover. Just let SetProxyByAvailability apply the reactive golden rule (leave a
REM live pointer alone, fail-open a dead one) and leave. IsUpdating.ps1 is stale-guarded
REM (15 min) so an orphaned flag from a killed self-update self-heals.
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%BRAIN%IsUpdating.ps1"
if %ERRORLEVEL% EQU 0 (
    powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%BRAIN%SetProxyByAvailability.ps1" >nul 2>&1
    goto :eof
)

REM If the proxy is already listening (another logon layer won the race), don't
REM start a second node - just make sure Windows is pointed at it, then leave.
"%NODE_EXE%" "%BRAIN%CheckPort.js" >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%BRAIN%SetProxyByAvailability.ps1" >nul 2>&1
    goto :eof
)

REM Proxy not up yet: start it hidden (/B = no new window; this console is already
REM hidden via RunStartupHidden.vbs), give it a moment to bind, then let
REM SetProxyByAvailability decide PE based on whether it is actually listening.
start "" /B "%NODE_EXE%" proxy-server.js
timeout /t 2 /nobreak >nul
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%BRAIN%SetProxyByAvailability.ps1" >nul 2>&1
