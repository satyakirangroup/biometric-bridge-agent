@echo off
title Satyakiran Biometric — 2-Way Hardware Communication
color 0A
cd /d "%~dp0"

echo =======================================================
echo  Satyakiran Biometric 2-Way Communication Daemon
echo  Direction 1: Device Punches -^> AWS Cloud
echo  Direction 2: Cloud Commands -^> Device Hardware
echo  Local API:   http://localhost:5006
echo =======================================================
echo.

where node >nul 2>nul
if %errorlevel% neq 0 (
    echo [ERROR] Node.js is not installed or not in PATH!
    echo Please install Node.js from https://nodejs.org
    pause
    exit /b 1
)

node src/two-way-sync.js

if %errorlevel% neq 0 (
    echo.
    echo [Process exited with code %errorlevel%]
    pause
)
