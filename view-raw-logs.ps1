# Satyakiran Biometric - Raw Machine Punch Inspector (PowerShell Native)
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile = Join-Path $ScriptDir "config.json"
$LogsDir = Join-Path $ScriptDir "logs"
$BridgeScript = Join-Path $ScriptDir "src\native\sbxpc-bridge.ps1"

if (-not (Test-Path $ConfigFile)) {
    Write-Host "[ERROR] config.json not found in $ScriptDir" -ForegroundColor Red
    exit 1
}

$Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
$MachineIp = $Config.machine.ip
$MachinePort = [int]$Config.machine.port
$MachineNum = [int]$Config.machine.machineNumber
$MachinePass = [int]$Config.machine.password
$DeviceName = $Config.machine.deviceName

Write-Host "`n=======================================================" -ForegroundColor Cyan
Write-Host "Satyakiran Biometric - Live Raw Log Inspector" -ForegroundColor Green
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host "Connecting to Machine: $MachineIp`:$MachinePort (Machine #$MachineNum)..." -ForegroundColor Yellow

$sysRoot = if ($env:SystemRoot) { $env:SystemRoot } else { "C:\Windows" }
$x86Ps = Join-Path $sysRoot "SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
$psExe = if (Test-Path $x86Ps) { $x86Ps } else { "powershell.exe" }

$rawJson = & $psExe -NoProfile -ExecutionPolicy Bypass -File $BridgeScript "fetch-logs" $MachineNum $MachineIp $MachinePort $MachinePass $DeviceName

if (-not $rawJson -or $LASTEXITCODE -ne 0) {
    Write-Host "❌ Failed to read biometric device (Device busy or offline)" -ForegroundColor Red
    exit 1
}

try {
    $records = $rawJson | ConvertFrom-Json
    if (-not $records -or $records.Count -eq 0) {
        Write-Host "⚠️  0 punch records found in device memory." -ForegroundColor Yellow
        exit 0
    }

    Write-Host "[OK] Successfully read $($records.Count) punch records from device memory!`n" -ForegroundColor Green

    # Show recent 25 punches
    Write-Host "Showing Last 25 Punches (Most Recent):" -ForegroundColor Cyan
    $recent = $records | Select-Object -Last 25
    $recent | Format-Table -Property @{Name="EmpCode";Expression={$_.employeeCode}}, @{Name="EmployeeName";Expression={$_.employeeName}}, @{Name="PunchTime";Expression={$_.logDateTime}}, @{Name="Mode";Expression={$_.verificationMode}} -AutoSize

    # Save to CSV
    if (-not (Test-Path $LogsDir)) { New-Item -ItemType Directory -Path $LogsDir | Out-Null }
    $csvFile = Join-Path $LogsDir "raw_machine_punches.csv"
    $records | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8
    Write-Host "`n[OK] Exported full records to: $csvFile" -ForegroundColor Green
    Write-Host "=======================================================`n" -ForegroundColor Cyan
} catch {
    Write-Host "❌ Error parsing records: $_" -ForegroundColor Red
}
