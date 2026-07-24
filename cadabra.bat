@echo off
REM cadabra — vuelve a OCULTAR todo en esta carpeta (WatcherBrain, InstallWatcher,
REM BackToNormal, Restaurar, este mismo archivo, etc.), dejando visible solo
REM "abracadabra.bat" como la puerta de entrada. Es el par de abracadabra.
REM Hide everything (attrib wildcard, not a FOR loop — see abracadabra.bat), then
REM re-reveal only abracadabra.bat as the visible door back in.
attrib +h +s "%~dp0*" /d >nul 2>&1
attrib -h -s "%~dp0abracadabra.bat" >nul 2>&1
