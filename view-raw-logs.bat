@echo off
title Satyakiran Biometric - Raw Log Viewer
color 0B
cd /d "%~dp0"

echo =======================================================
echo   Satyakiran Biometric — Raw Log Inspector
echo =======================================================
echo.

where node >nul 2>nul
if %errorlevel% equ 0 (
    node src/view-raw-logs.js
) else (
    echo [INFO] Node.js not detected in PATH, using native Windows PowerShell...
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0view-raw-logs.ps1"
)

echo.
pause
