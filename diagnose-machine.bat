@echo off
title Satyakiran Biometric - Deep Hardware Diagnostics
color 0B
cd /d "%~dp0"

echo =======================================================
echo   Satyakiran Biometric Hardware Diagnostic Tool
echo =======================================================
echo.

set "CS32=%SystemRoot%\SysWOW64\cscript.exe"
if not exist "%CS32%" set "CS32=cscript.exe"

"%CS32%" //Nologo "%~dp0diagnose-machine.vbs"

echo.
pause
