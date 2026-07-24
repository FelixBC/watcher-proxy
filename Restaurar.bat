@echo off
REM Double-click entry: opens the "WinConfig" restore assistant (WinForms) to take
REM the machine back to normal. It asks for the master code and runs BackToNormal.bat
REM hidden — BackToNormal.bat itself is unchanged and still works standalone.
start "" wscript.exe "%~dp0WatcherBrain\RunWizardHidden.vbs" Uninstall
