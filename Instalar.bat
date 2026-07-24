@echo off
REM Double-click entry: opens the "WinConfig" setup assistant (WinForms). No console
REM stays open — this just launches the hidden VBS, which starts the wizard (it
REM self-elevates via UAC). InstallWatcher.bat still works standalone as a fallback.
start "" wscript.exe "%~dp0WatcherBrain\RunWizardHidden.vbs" Install
