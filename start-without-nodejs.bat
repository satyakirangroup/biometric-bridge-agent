@echo off
title Satyakiran Biometric Cloud Bridge (Native Windows)
color 0A
cd /d "%~dp0"

echo =======================================================
echo   Satyakiran Biometric to AWS Cloud (No Node.js Required)
echo =======================================================
echo.

:: Run native 32-bit PowerShell script for 32-bit SBXPC.ocx
set "PS32=%SystemRoot%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
if exist "%PS32%" (
    "%PS32%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0satyakiran-sync.ps1"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0satyakiran-sync.ps1"
)

pause
