@echo off
title Satyakiran Biometric Cloud Bridge
color 0A
cd /d "%~dp0"

echo =======================================================
echo   Satyakiran Biometric Hardware to AWS Cloud Bridge
echo =======================================================
echo.

:: Check Node.js installation
where node >nul 2>nul
if %errorlevel% neq 0 (
    echo [ERROR] Node.js is not installed or not in PATH!
    echo Please install Node.js from https://nodejs.org (LTS Version)
    echo.
    pause
    exit /b 1
)

echo Starting Biometric Bridge Agent...
echo Press Ctrl+C to stop.
echo.
node src/index.js
pause
