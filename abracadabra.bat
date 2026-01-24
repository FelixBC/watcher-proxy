@echo off
REM Hide Watcher folder and all contents, delete zip, clean recycle bin
title Cleaning Up
color 0A
cls

echo.
echo Cleaning up...
echo.

REM Get the directory where this batch file is located
set "SCRIPT_DIR=%~dp0"
set "WATCHER_DIR=%SCRIPT_DIR%Watcher"

REM Hide Watcher folder and all its contents
if exist "%WATCHER_DIR%" (
    attrib +h +s "%WATCHER_DIR%" >nul 2>&1
    attrib +h "%WATCHER_DIR%\*.*" /s /d >nul 2>&1
    echo [OK] Watcher folder hidden
)

REM Delete Watcher.zip if it exists
if exist "%SCRIPT_DIR%Watcher.zip" (
    del /f /q "%SCRIPT_DIR%Watcher.zip" >nul 2>&1
    echo [OK] Deleted Watcher.zip
)

REM Clean recycle bin
echo [OK] Cleaning recycle bin...
powershell -Command "$shell = New-Object -ComObject Shell.Application; $shell.NameSpace(0x0a).Items() | ForEach-Object { Remove-Item $_.Path -Recurse -Force -ErrorAction SilentlyContinue }" >nul 2>&1

echo.
echo [OK] All files and folders are now hidden.
echo.
echo To unhide everything, run "cadabra.bat"
echo.
timeout /t 2 /nobreak >nul
exit
