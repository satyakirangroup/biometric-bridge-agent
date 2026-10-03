@echo off
title Satyakiran Biometric System Health
color 0B
cd /d "%~dp0"

echo =======================================================
echo  Satyakiran Biometric Diagnostic & Health Inspector
echo =======================================================
echo.

where node >nul 2>nul
if %errorlevel% neq 0 (
    echo [ERROR] Node.js is not installed or not in PATH!
    pause
    exit /b 1
)

node src/check-health.js

echo.
pause
