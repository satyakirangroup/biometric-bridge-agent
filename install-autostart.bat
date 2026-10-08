@echo off
title Install Satyakiran Biometric Auto-Start
color 0B
cd /d "%~dp0"

echo =======================================================
echo   Satyakiran Biometric Bridge - Windows Auto-Start Setup
echo =======================================================
echo.

if exist "%~dp0SatyakiranBiometricAgent.exe" (
    echo Registering Native Windows Executable Auto-Start...
    "%~dp0SatyakiranBiometricAgent.exe" install
) else (
    echo [WARN] SatyakiranBiometricAgent.exe not found, using legacy shortcut...
    set SCRIPT_DIR=%~dp0
    set TARGET_BAT=%SCRIPT_DIR%start-agent.bat
    set STARTUP_FOLDER=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup
    set VBS_SCRIPT=%TEMP%\create_shortcut.vbs

    echo Creating startup shortcut in: %STARTUP_FOLDER%
    echo.
    echo Set oWS = WScript.CreateObject("WScript.Shell") > "%VBS_SCRIPT%"
    echo sLinkFile = "%STARTUP_FOLDER%\SatyakiranBiometricBridge.lnk" >> "%VBS_SCRIPT%"
    echo Set oLink = oWS.CreateShortcut(sLinkFile) >> "%VBS_SCRIPT%"
    echo oLink.TargetPath = "%TARGET_BAT%" >> "%VBS_SCRIPT%"
    echo oLink.WorkingDirectory = "%SCRIPT_DIR%" >> "%VBS_SCRIPT%"
    echo oLink.Description = "Satyakiran Biometric to AWS Cloud Bridge Agent" >> "%VBS_SCRIPT%"
    echo oLink.WindowStyle = 7 >> "%VBS_SCRIPT%"
    echo oLink.Save >> "%VBS_SCRIPT%"

    cscript //nologo "%VBS_SCRIPT%"
    del "%VBS_SCRIPT%"
)

echo.
pause

