@echo off
REM If proxy died and you have no internet: double-click this to switch to normal traffic immediately (no restart needed).
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0SetProxyByAvailability.ps1"
exit /b 0
