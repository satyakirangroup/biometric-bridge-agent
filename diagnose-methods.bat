@echo off
title Satyakiran Biometric SDK COM Inspector
color 0B
cd /d "%~dp0"

echo =======================================================
echo   Satyakiran Biometric SDK - COM Methods Inspector
echo =======================================================
echo.

set "PS32=%SystemRoot%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS32%" set "PS32=powershell.exe"

"%PS32%" -NoProfile -ExecutionPolicy Bypass -Command ^
    "try {" ^
    "  $sbx = New-Object -ComObject 'SBXPC.SBXPCCtrl.1' -ErrorAction Stop;" ^
    "  Write-Host '✅ Successfully created COM Object: SBXPC.SBXPCCtrl.1' -ForegroundColor Green;" ^
    "  Write-Host '--- Available Methods on SBXPC Object ---' -ForegroundColor Cyan;" ^
    "  $methods = $sbx | Get-Member -MemberType Method, Property;" ^
    "  if ($methods) { $methods | Format-Table -AutoSize } else { Write-Host 'No direct CLR members, using IDispatch' -ForegroundColor Yellow };" ^
    "} catch {" ^
    "  Write-Host '❌ COM Error: ' $_.Exception.Message -ForegroundColor Red;" ^
    "}"

echo.
pause
