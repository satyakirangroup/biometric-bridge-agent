@echo off
title Satyakiran Biometric Cloud Bridge
color 0A
cd /d "%~dp0"

echo =======================================================
echo   Satyakiran Biometric Hardware to AWS Cloud Bridge
echo =======================================================
echo.

:: 1. Check Node.js installation
where node >nul 2>nul
if %errorlevel% equ 0 (
    echo [OK] Node.js runtime detected. Starting Bridge Agent...
    echo Press Ctrl+C to stop.
    echo.
    node src/index.js
    goto :end
)

:: 2. Fallback to Native Windows PowerShell / C# Engine
echo [INFO] Node.js not found in PATH. Using Native Windows Engine...
set "PS32=%SystemRoot%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
if exist "%PS32%" (
    "%PS32%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0satyakiran-sync.ps1"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0satyakiran-sync.ps1"
)

:end
if %errorlevel% neq 0 (
    echo.
    echo [Agent process exited with code %errorlevel%]
    pause
)

