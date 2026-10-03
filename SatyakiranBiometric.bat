@echo off
title Satyakiran Biometric Control Panel v2.0
color 0B
cd /d "%~dp0"

:: Check Node.js installation
where node >nul 2>nul
if %errorlevel% neq 0 (
    echo.
    echo =======================================================
    echo  ERROR: Node.js is not found on your system!
    echo =======================================================
    echo  Please install Node.js (LTS version) from:
    echo  https://nodejs.org
    echo.
    pause
    exit /b 1
)

:: Run All-in-One CLI
node src/cli.js

if %errorlevel% neq 0 (
    echo.
    echo [Process exited with code %errorlevel%]
    pause
)
