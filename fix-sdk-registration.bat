@echo off
title Satyakiran Biometric - Register SDK Components
color 0A
cd /d "%~dp0"

echo =======================================================
echo   Satyakiran Biometric SDK — Complete Registration Fix
echo =======================================================
echo.

:: Check for Administrator permissions
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [REQUESTING ADMINISTRATOR RIGHTS...]
    powershell -Command "Start-Process cmd -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)

set "BIN_DIR=C:\SatyakiranBiometric\bin"
if not exist "%BIN_DIR%" (
    if exist "C:\SatyakiranBiometric" set "BIN_DIR=C:\SatyakiranBiometric"
)

echo [1/3] Copying ALL 32-bit SDK DLLs & Dependencies to Windows SysWOW64...
if exist "%BIN_DIR%" (
    copy /y "%BIN_DIR%\*.dll" "%SystemRoot%\SysWOW64\" >nul 2>&1
    copy /y "%BIN_DIR%\*.ocx" "%SystemRoot%\SysWOW64\" >nul 2>&1
    echo       Successfully copied dependencies from %BIN_DIR% to SysWOW64.
) else (
    echo       Warning: %BIN_DIR% not found.
)

echo.
echo [2/3] Registering SBXPC.ocx in 32-bit Windows Subsystem...
cd /d "%BIN_DIR%"
"%SystemRoot%\SysWOW64\regsvr32.exe" /s "%BIN_DIR%\SBXPC.ocx"
"%SystemRoot%\SysWOW64\regsvr32.exe" /s "%SystemRoot%\SysWOW64\SBXPC.ocx"

echo.
echo [3/3] Verifying with 32-bit Windows Subsystem (SysWOW64)...
set "PS32=%SystemRoot%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS32%" set "PS32=powershell.exe"

"%PS32%" -NoProfile -ExecutionPolicy Bypass -Command ^
    "try { $sbx = New-Object -ComObject 'SBXPC.SBXPCCtrl.1' -ErrorAction Stop; Write-Host '✅ SUCCESS! SBXPC COM Object is 100% REGISTERED and ACTIVE!' -ForegroundColor Green } catch { Write-Host '❌ 32-bit COM Registration Error: ' $_.Exception.Message -ForegroundColor Red; Write-Host '   Make sure Microsoft Visual C++ 2010 Redistributable (x86) is installed.' -ForegroundColor Yellow }"

echo.
echo =======================================================
echo   Done!
echo =======================================================
echo.
pause
