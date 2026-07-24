@echo off
REM cadabra — vuelve a OCULTAR todo en esta carpeta (WatcherBrain, InstallWatcher,
REM BackToNormal, Restaurar, este mismo archivo, etc.), dejando visible solo
REM "abracadabra.bat" como la puerta de entrada. Es el par de abracadabra.
for /d %%D in ("%~dp0*") do attrib +h +s "%%D" >nul 2>&1
for %%F in ("%~dp0*") do if /I not "%%~nxF"=="abracadabra.bat" attrib +h +s "%%F" >nul 2>&1
