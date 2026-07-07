@echo off
REM Runs when PC resumes from sleep. Sync proxy state and restart proxy if needed. No delay - instant.
REM Called by Task Scheduler on Power-Troubleshooter Event 1 (resume from sleep).
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0CheckAndStartProxy.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0SetProxyByAvailability.ps1"
