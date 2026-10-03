# Satyakiran Biometric - Raw Machine Punch Inspector (PowerShell Native)
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile = Join-Path $ScriptDir "config.json"
$LogsDir = Join-Path $ScriptDir "logs"

if (-not (Test-Path $ConfigFile)) {
    Write-Host "[ERROR] config.json not found in $ScriptDir" -ForegroundColor Red
    exit 1
}

$Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
$MachineIp = $Config.machine.ip
$MachinePort = [int]$Config.machine.port
$MachineNum = [int]$Config.machine.machineNumber
$MachinePass = [int]$Config.machine.password

Write-Host "`n=======================================================" -ForegroundColor Cyan
Write-Host "📟 Satyakiran Biometric — Live Raw Log Inspector" -ForegroundColor Green
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host "Connecting to Machine: $MachineIp`:$MachinePort (Machine #$MachineNum)..." -ForegroundColor Yellow

try {
    $sbx = New-Object -ComObject "SBXPC.SBXPCCtrl.1" -ErrorAction Stop
    try { $sbx.DotNET() } catch {}
    $conn = $sbx.ConnectTcpip($MachineNum, $MachineIp, $MachinePort, $MachinePass)

    if (-not $conn) {
        Write-Host "❌ Failed to connect to $MachineIp`:$MachinePort (Device offline or busy)" -ForegroundColor Red
        exit 1
    }

    Write-Host "Connected! Reading internal flash memory..." -ForegroundColor Green

    $hasLogs = $false
    try { $hasLogs = $sbx.ReadAllGLogData($MachineNum) } catch {}
    if (-not $hasLogs) {
        try { $hasLogs = $sbx.ReadGeneralLogData($MachineNum) } catch {}
    }

    $records = @()
    if ($hasLogs) {
        $tMach = 0
        $enrollNo = 0
        $eMach = 0
        $verifyMode = 0
        $year = 0; $month = 0; $day = 0; $hour = 0; $minute = 0; $second = 0

        $hasRecord = $false
        try {
            $hasRecord = $sbx.GetAllGLogData($MachineNum, [ref]$tMach, [ref]$enrollNo, [ref]$eMach, [ref]$verifyMode, [ref]$year, [ref]$month, [ref]$day, [ref]$hour, [ref]$minute, [ref]$second)
        } catch {}

        if ($hasRecord) {
            do {
                $monthStr = "{0:D2}" -f $month
                $dayStr = "{0:D2}" -f $day
                $hourStr = "{0:D2}" -f $hour
                $minStr = "{0:D2}" -f $minute
                $secStr = "{0:D2}" -f $second
                $dtStr = "$year-$monthStr-$dayStr $hourStr`:$minStr`:$secStr"

                $vMode = "Face"
                if ($verifyMode -eq 1) { $vMode = "Fingerprint" }
                elseif ($verifyMode -eq 2) { $vMode = "Card" }
                elseif ($verifyMode -eq 15) { $vMode = "Face" }

                $records += [PSCustomObject]@{
                    EmployeeCode = $enrollNo.ToString()
                    PunchTime    = $dtStr
                    VerifyMode   = $vMode
                    Terminal     = $tMach
                }
            } while ($sbx.GetAllGLogData($MachineNum, [ref]$tMach, [ref]$enrollNo, [ref]$eMach, [ref]$verifyMode, [ref]$year, [ref]$month, [ref]$day, [ref]$hour, [ref]$minute, [ref]$second))
        } else {
            while ($sbx.GetGeneralLogData($MachineNum, [ref]$tMach, [ref]$enrollNo, [ref]$eMach, [ref]$verifyMode, [ref]$year, [ref]$month, [ref]$day, [ref]$hour, [ref]$minute, [ref]$second)) {
                $monthStr = "{0:D2}" -f $month
                $dayStr = "{0:D2}" -f $day
                $hourStr = "{0:D2}" -f $hour
                $minStr = "{0:D2}" -f $minute
                $secStr = "{0:D2}" -f $second
                $dtStr = "$year-$monthStr-$dayStr $hourStr`:$minStr`:$secStr"

                $vMode = "Face"
                if ($verifyMode -eq 1) { $vMode = "Fingerprint" }
                elseif ($verifyMode -eq 2) { $vMode = "Card" }
                elseif ($verifyMode -eq 15) { $vMode = "Face" }

                $records += [PSCustomObject]@{
                    EmployeeCode = $enrollNo.ToString()
                    PunchTime    = $dtStr
                    VerifyMode   = $vMode
                    Terminal     = $tMach
                }
            }
        }
    }

    try { $sbx.Disconnect() } catch { $sbx.CloseCommPort() }

    if (-not (Test-Path $LogsDir)) { New-Item -ItemType Directory -Path $LogsDir | Out-Null }
    $csvFile = Join-Path $LogsDir "raw_machine_punches.csv"
    $records | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8

    Write-Host "`n✅ Total Records Found: $($records.Count)" -ForegroundColor Green
    Write-Host "💾 Saved CSV to: $csvFile" -ForegroundColor Cyan
    Write-Host "`n--- Recent 25 Punches ---" -ForegroundColor Yellow
    $records | Select-Object -Last 25 | Format-Table -AutoSize

    Write-Host "Opening CSV in Excel / Default Viewer..." -ForegroundColor Green
    Invoke-Item $csvFile
} catch {
    Write-Host "❌ Error: $($_.Exception.Message)" -ForegroundColor Red
}
