@echo off
REM Unhide Watcher folder and all contents
title Unhiding Files
color 0B
cls

echo.
echo Unhiding files and folders...
echo.

REM Get the directory where this batch file is located
set "SCRIPT_DIR=%~dp0"
set "WATCHER_DIR=%SCRIPT_DIR%Watcher"

REM Unhide Watcher folder and all its contents
if exist "%WATCHER_DIR%" (
    attrib -h -s "%WATCHER_DIR%" >nul 2>&1
    attrib -h "%WATCHER_DIR%\*.*" /s /d >nul 2>&1
    echo [OK] Watcher folder unhidden
) else (
    echo [WARNING] Watcher folder not found
)

echo.
echo [OK] All files and folders are now visible.
echo.
timeout /t 2 /nobreak >nul
exit
