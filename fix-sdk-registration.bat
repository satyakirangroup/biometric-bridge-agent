@echo off
title Satyakiran Biometric - Register SDK Components
color 0A
cd /d "%~dp0"

echo =======================================================
echo   Satyakiran Biometric SDK — 1-Click Registration Fix
echo =======================================================
echo.

:: Check for Administrator permissions
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [REQUESTING ADMIN RIGHTS...]
    powershell -Command "Start-Process cmd -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)

set "SOURCE_DIR=C:\SatyakiranBiometric\bin"
if not exist "%SOURCE_DIR%" (
    if exist "%~dp0..\attenance" set "SOURCE_DIR=%~dp0..\attenance"
)

echo [1/3] Copying 32-bit SDK DLLs to Windows SysWOW64 folder...
if exist "%SOURCE_DIR%" (
    copy /y "%SOURCE_DIR%\SBPCOMM.dll" "%SystemRoot%\SysWOW64\" >nul 2>&1
    copy /y "%SOURCE_DIR%\SBXPCDLL.dll" "%SystemRoot%\SysWOW64\" >nul 2>&1
    copy /y "%SOURCE_DIR%\SBXPC.ocx" "%SystemRoot%\SysWOW64\" >nul 2>&1
    echo       Copied from %SOURCE_DIR%
) else (
    echo       Warning: %SOURCE_DIR% not found. Searching current directory...
    copy /y "%~dp0SBPCOMM.dll" "%SystemRoot%\SysWOW64\" >nul 2>&1
    copy /y "%~dp0SBXPCDLL.dll" "%SystemRoot%\SysWOW64\" >nul 2>&1
    copy /y "%~dp0SBXPC.ocx" "%SystemRoot%\SysWOW64\" >nul 2>&1
)

echo.
echo [2/3] Registering 32-bit SBXPC.ocx with 32-bit RegSvr32...
"%SystemRoot%\SysWOW64\regsvr32.exe" /s "%SystemRoot%\SysWOW64\SBXPC.ocx"

if exist "%SOURCE_DIR%\SBXPC.ocx" (
    "%SystemRoot%\SysWOW64\regsvr32.exe" /s "%SOURCE_DIR%\SBXPC.ocx"
)

echo.
echo [3/3] Verifying COM registration in Windows Registry...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "try { $sbx = New-Object -ComObject 'SBXPC.SBXPCCtrl.1' -ErrorAction Stop; Write-Host '✅ SUCCESS! SBXPC.SBXPCCtrl.1 COM object is registered and fully operational!' -ForegroundColor Green } catch { Write-Host '❌ Failed: ' $_.Exception.Message -ForegroundColor Red }"

echo.
echo =======================================================
echo   Done! Now run view-raw-logs.bat or npm start
echo =======================================================
echo.
pause
