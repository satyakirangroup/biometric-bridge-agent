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

echo [1/3] Copying ALL 32-bit SDK DLLs and Dependencies to Windows SysWOW64...
if exist "%BIN_DIR%" (
    copy /y "%BIN_DIR%\*.dll" "%SystemRoot%\SysWOW64\" >nul 2>&1
    copy /y "%BIN_DIR%\*.ocx" "%SystemRoot%\SysWOW64\" >nul 2>&1
    echo       Copied SBPCCOMM.dll, SBXPCDLL.dll, GEN_FONT.dll and OCX to SysWOW64.
) else (
    echo       Warning: %BIN_DIR% not found.
)

echo.
echo [2/3] Registering SBXPC.ocx in 32-bit Windows Subsystem...
cd /d "%SystemRoot%\SysWOW64"
"%SystemRoot%\SysWOW64\regsvr32.exe" /s "%SystemRoot%\SysWOW64\SBXPC.ocx"

echo.
echo [3/3] Verifying registration with 32-bit CSCRIPT...
set "CS32=%SystemRoot%\SysWOW64\cscript.exe"
if not exist "%CS32%" set "CS32=cscript.exe"

"%CS32%" //Nologo -e:vbs -E "On Error Resume Next: Set s = CreateObject(\"SBXPC.SBXPCCtrl.1\"): If Err.Number = 0 Then WScript.Echo \"SUCCESS: SBXPC.SBXPCCtrl.1 COM Object is 100%% Registered and Active!\" Else WScript.Echo \"Error: \" & Err.Description"

echo.
echo =======================================================
echo   Done!
echo =======================================================
echo.
pause
