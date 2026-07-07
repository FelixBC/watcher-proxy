@echo off
REM Runs print spool cleanup at logon but only once per calendar day (first logon of the day).
REM Must run with administrator rights. Called by Task Scheduler at logon.
setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
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
