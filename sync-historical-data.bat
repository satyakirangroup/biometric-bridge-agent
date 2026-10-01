@echo off
title Satyakiran Biometric - Full Historical Data Sync
color 0E
cd /d "%~dp0"

echo =======================================================
echo   Satyakiran Biometric - Full Historical Data Sync
echo =======================================================
echo.
echo This will read ALL stored offline logs from the biometric
echo machine memory and sync them to Satyakiran AWS Cloud DB.
echo.

:: Check Node.js installation
where node >nul 2>nul
if %errorlevel% neq 0 (
    echo [ERROR] Node.js is not installed or not in PATH!
    echo Please install Node.js from https://nodejs.org
    echo.
    pause
    exit /b 1
)

node src/sync-history.js
echo.
pause
