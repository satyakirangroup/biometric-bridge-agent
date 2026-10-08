@echo off
title Install Satyakiran Biometric Auto-Start
color 0B
cd /d "%~dp0"

echo =======================================================
echo   Satyakiran Biometric Bridge - Windows Auto-Start Setup
echo =======================================================
echo.

set "SCRIPT_DIR=%~dp0"
set "TARGET_BAT=%SCRIPT_DIR%start-agent.bat"
set "STARTUP_FOLDER=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
set "VBS_SCRIPT=%TEMP%\create_shortcut_%RANDOM%.vbs"

:: 1. Register Windows User Startup Folder Shortcut
echo 1. Creating Startup Folder shortcut...
echo Set oWS = WScript.CreateObject("WScript.Shell") > "%VBS_SCRIPT%"
echo sLinkFile = "%STARTUP_FOLDER%\SatyakiranBiometricBridge.lnk" >> "%VBS_SCRIPT%"
echo Set oLink = oWS.CreateShortcut(sLinkFile) >> "%VBS_SCRIPT%"
echo oLink.TargetPath = "%TARGET_BAT%" >> "%VBS_SCRIPT%"
echo oLink.WorkingDirectory = "%SCRIPT_DIR%" >> "%VBS_SCRIPT%"
echo oLink.Description = "Satyakiran Biometric to AWS Cloud Bridge Agent" >> "%VBS_SCRIPT%"
echo oLink.WindowStyle = 7 >> "%VBS_SCRIPT%"
echo oLink.Save >> "%VBS_SCRIPT%"

cscript //nologo "%VBS_SCRIPT%" >nul 2>&1
if exist "%VBS_SCRIPT%" del "%VBS_SCRIPT%"
echo    [OK] User Startup shortcut created.

:: 2. Register Windows Registry Auto-Run
echo.
echo 2. Configuring Windows User Registry Auto-Run...
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v "SatyakiranBiometricBridge" /t REG_SZ /d "\"%TARGET_BAT%\"" /f >nul 2>&1
echo    [OK] Registry auto-run configured.

:: 3. Register Task Scheduler (SYSTEM Boot Service - requires Admin)
echo.
echo 3. Configuring Windows Task Scheduler (Boot Service)...
powershell -NoProfile -ExecutionPolicy Bypass -Command "& { try { $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%~dp0supervisor.ps1\"'; $trigger = New-ScheduledTaskTrigger -AtStartup; Register-ScheduledTask -TaskName 'SatyakiranBridge' -Action $action -Trigger $trigger -Principal (New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest) -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)) -Force -ErrorAction Stop | Out-Null; Write-Host '   [OK] Task Scheduler Boot Service registered (24/7 AtStartup).' } catch { Write-Host '   [INFO] User Registry and Startup shortcut are active.' -ForegroundColor Yellow; Write-Host '          (Tip: Run as Administrator to enable 24/7 boot service without user login).' -ForegroundColor Gray } }"

echo.
echo =======================================================
echo  SUCCESS! Satyakiran Biometric Bridge Auto-Start is FIXED!
echo  The agent will now automatically start on system boot.
echo =======================================================
echo.
pause


