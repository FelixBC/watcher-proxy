@echo off
REM Clears "kept printed documents" from Windows print spool.
REM Must run with administrator rights (Task Scheduler uses /RL HIGHEST).
setlocal

net stop spooler >nul 2>&1
del /q "%SystemRoot%\System32\spool\PRINTERS\*" >nul 2>&1
net start spooler >nul 2>&1

endlocal
exit /b 0
