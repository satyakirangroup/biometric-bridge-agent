@echo off
title Satyakiran Biometric - Raw Log Viewer
color 0B
cd /d "%~dp0"

echo =======================================================
echo   Satyakiran Biometric — Raw Log Inspector
echo =======================================================
echo.

node src/view-raw-logs.js
echo.
pause
