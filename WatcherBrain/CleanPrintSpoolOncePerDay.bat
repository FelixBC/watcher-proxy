@echo off
REM Runs print spool cleanup at logon but only once per calendar day (first logon of the day).
REM Must run with administrator rights. Called by Task Scheduler at logon (as SYSTEM).
setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"

REM EVERY logon (NOT gated by the once-per-day marker): enforce Keep-printed-documents
REM = OFF on all printers, so no receipt/ticket is ever retained for reprint even if a
REM driver/update flipped it on. Cheap + non-disruptive (no spooler restart), and this
REM task runs as SYSTEM, which has the rights to change printer config that a standard
REM "banca" user does not. The disruptive spool CLEAR below stays once per day.
REM NOTE (plan 0010): this logon path is no longer the primary guard for either script
REM below -- an onlogon trigger does not fire on resume-from-hibernate or on unlock, and a
REM banca commonly runs for DAYS without a real logon. The ~hourly SYSTEM re-assert in
REM poll-hub.js (reassertHardeningIfDue) is what actually keeps these enforced; this stays
REM as the at-logon fast path.
powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%SCRIPT_DIR%HardenPrinters.ps1" >nul 2>&1

REM EVERY logon (same SYSTEM context + reasoning as HardenPrinters above): re-assert power
REM resilience so this machine keeps REPORTING through sleep/battery -- Wi-Fi = maximum
REM performance (AC+DC) + never sleep on AC. Must run as SYSTEM (powercfg needs elevation
REM a standard "banca" user lacks); this task provides it, the least-privilege watchdog
REM does NOT. Reaches already-installed bancas via OTA (this .bat is OTA-updated and the
REM logon task already exists) -- no new task to register. See HardenPower.ps1 + plan 0009.
powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%SCRIPT_DIR%HardenPower.ps1" >nul 2>&1

set "MARKER_FILE=%SCRIPT_DIR%last_spool_cleanup_day.txt"

for /f "delims=" %%D in ('powershell -NoProfile -WindowStyle Hidden -Command "(Get-Date).ToString('yyyyMMdd')" 2^>nul') do set TODAY=%%D
if not defined TODAY exit /b 0

if exist "%MARKER_FILE%" (
  set /p LAST=<"%MARKER_FILE%" 2>nul
  if "!LAST!"=="%TODAY%" exit /b 0
)

call "%SCRIPT_DIR%CleanPrintSpool.bat"
echo %TODAY%> "%MARKER_FILE%"

endlocal
exit /b 0
