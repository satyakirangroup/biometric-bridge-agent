@echo off
title Satyakiran Biometric - Machine Data Inspector
color 0B
cd /d "%~dp0"

echo =======================================================
echo   Satyakiran Biometric Machine — Data Inspector
echo =======================================================
echo.

node src/inspect-device.js

echo.
pause
