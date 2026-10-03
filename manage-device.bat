@echo off
title Satyakiran Biometric - Manual Device Manager
color 0A
echo.
echo  ========================================================
echo   SATYAKIRAN BIOMETRIC - MANUAL DEVICE MANAGER
echo   Directly add/update/delete employees on biometric hardware
echo  ========================================================
echo.
cd /d %~dp0
node src\manage-device.js
echo.
pause
