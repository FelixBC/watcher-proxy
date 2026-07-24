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
powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%SCRIPT_DIR%HardenPrinters.ps1" >nul 2>&1

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
