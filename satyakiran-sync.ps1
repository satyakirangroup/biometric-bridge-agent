# Satyakiran Biometric Hardware to AWS Cloud Bridge (Pure Windows Native - 2-Way Communication)
# Runs on any Windows 10/11 machine using built-in PowerShell & .NET

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile = Join-Path $ScriptDir "config.json"
$StateFile = Join-Path $ScriptDir "sync-state.json"

if (-not (Test-Path $ConfigFile)) {
    Write-Host "[ERROR] config.json not found in $ScriptDir" -ForegroundColor Red
    exit 1
}

# 1. Load Configuration
$Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
$MachineIp = $Config.machine.ip
$MachinePort = [int]$Config.machine.port
$MachineNum = [int]$Config.machine.machineNumber
$MachinePass = [int]$Config.machine.password
$DeviceName = $Config.machine.deviceName
$CloudUrl = $Config.cloud.apiUrl
$AuthToken = $Config.cloud.authToken
$BranchId = $Config.cloud.branchId
$SyncInterval = [int]$Config.cloud.syncIntervalSeconds
if ($SyncInterval -le 0) { $SyncInterval = 30 }

# Derive Commands & Ack URLs from CloudUrl
$BaseAttendanceUrl = $CloudUrl -replace "/biometric-push$", ""
$CommandsUrl = "$BaseAttendanceUrl/biometric-commands?branchId=$BranchId"
$AckUrl = "$BaseAttendanceUrl/biometric-commands/ack"

# 2. Load or Initialize State (De-duplication memory)
$State = @{
    lastSyncAt = $null
    totalSyncedCount = 0
    syncedSignatures = @{}
}

if (Test-Path $StateFile) {
    try {
        $Loaded = Get-Content $StateFile -Raw | ConvertFrom-Json
        if ($Loaded.syncedSignatures) {
            foreach ($prop in $Loaded.syncedSignatures.PSObject.Properties) {
                $State.syncedSignatures[$prop.Name] = $prop.Value
            }
        }
        if ($Loaded.totalSyncedCount) {
            $State.totalSyncedCount = [int]$Loaded.totalSyncedCount
        }
    } catch {
        Write-Host "[WARN] Could not parse sync-state.json, starting fresh." -ForegroundColor Yellow
    }
}

function Save-State {
    $Json = $State | ConvertTo-Json -Depth 4
    Set-Content -Path $StateFile -Value $Json -Encoding UTF8
}

function Get-LogSignature($empCode, $dtStr) {
    return "$($empCode.Trim())_$($dtStr.Trim())"
}

Write-Host "`n=======================================================" -ForegroundColor Cyan
Write-Host "🚀 Satyakiran Biometric Cloud Bridge (2-Way Windows Native)" -ForegroundColor Green
Write-Host "   Way 1: Machine -> Cloud (Punches & Lateness Sync)" -ForegroundColor White
Write-Host "   Way 2: Cloud -> Machine (User Creation, Delete, Clock Sync)" -ForegroundColor White
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host "🏢 Branch ID   : $BranchId" -ForegroundColor Gray
Write-Host "📟 Machine IP  : $MachineIp`:$MachinePort (Machine #$MachineNum)" -ForegroundColor Gray
Write-Host "☁️  AWS Cloud  : $CloudUrl" -ForegroundColor Gray
Write-Host "⏱️  Sync Rate  : Every $SyncInterval seconds" -ForegroundColor Gray
Write-Host "💾 Prev Synced : $($State.totalSyncedCount) records" -ForegroundColor Gray
Write-Host "=======================================================`n" -ForegroundColor Cyan

# Enable TLS1.2 for modern secure HTTPS
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 3. Main Polling Loop
$KeepRunning = $true

while ($KeepRunning) {
    $NowStr = (Get-Date).ToString("HH:mm:ss")
    $pendingCommands = @()
    
    try {
        # Initialize COM Object
        $sbx = New-Object -ComObject "SBXPC.SBXPCCtrl.1" -ErrorAction Stop
        try { $sbx.DotNET() } catch {}
        $conn = $sbx.ConnectTcpip($MachineNum, $MachineIp, $MachinePort, $MachinePass)
        
        if ($conn) {
            # -------------------------------------------------------------
            # WAY 1: Read Punches from Machine -> Push to Cloud
            # -------------------------------------------------------------
            $hasLogs = $false
            try { $hasLogs = $sbx.ReadAllGLogData($MachineNum) } catch {}
            if (-not $hasLogs) {
                try { $hasLogs = $sbx.ReadGeneralLogData($MachineNum) } catch {}
            }
            $newPunches = @()
            $totalCount = 0

            if ($hasLogs) {
                $tMach = 0
                $enrollNo = 0
                $eMach = 0
                $verifyMode = 0
                $year = 0; $month = 0; $day = 0; $hour = 0; $minute = 0; $second = 0

                # Try GetAllGLogData first (paired with ReadAllGLogData)
                $hasRecord = $false
                try {
                    $hasRecord = $sbx.GetAllGLogData($MachineNum, [ref]$tMach, [ref]$enrollNo, [ref]$eMach, [ref]$verifyMode, [ref]$year, [ref]$month, [ref]$day, [ref]$hour, [ref]$minute, [ref]$second)
                } catch {}

                if ($hasRecord) {
                    do {
                        $totalCount++
                        $monthStr = "{0:D2}" -f $month
                        $dayStr = "{0:D2}" -f $day
                        $hourStr = "{0:D2}" -f $hour
                        $minStr = "{0:D2}" -f $minute
                        $secStr = "{0:D2}" -f $second
                        $dtStr = "$year-$monthStr-$dayStr $hourStr`:$minStr`:$secStr"
                        $empCodeStr = $enrollNo.ToString()

                        $sig = Get-LogSignature $empCodeStr $dtStr

                        if (-not $State.syncedSignatures.ContainsKey($sig)) {
                            $dir = "AUTO"
                            $vMode = "Face"
                            if ($verifyMode -eq 1) { $vMode = "Fingerprint" }
                            elseif ($verifyMode -eq 2) { $vMode = "Card" }
                            elseif ($verifyMode -eq 15) { $vMode = "Face" }

                            $newPunches += @{
                                employeeCode = $empCodeStr
                                logDateTime = $dtStr
                                direction = $dir
                                verificationMode = $vMode
                                deviceSerial = $MachineIp
                                deviceName = $DeviceName
                                branchId = $BranchId
                            }
                        }
                    } while ($sbx.GetAllGLogData($MachineNum, [ref]$tMach, [ref]$enrollNo, [ref]$eMach, [ref]$verifyMode, [ref]$year, [ref]$month, [ref]$day, [ref]$hour, [ref]$minute, [ref]$second))
                } else {
                    # Fallback loop using GetGeneralLogData (exact 11 parameters)
                    while ($sbx.GetGeneralLogData($MachineNum, [ref]$tMach, [ref]$enrollNo, [ref]$eMach, [ref]$verifyMode, [ref]$year, [ref]$month, [ref]$day, [ref]$hour, [ref]$minute, [ref]$second)) {
                        $totalCount++
                        $monthStr = "{0:D2}" -f $month
                        $dayStr = "{0:D2}" -f $day
                        $hourStr = "{0:D2}" -f $hour
                        $minStr = "{0:D2}" -f $minute
                        $secStr = "{0:D2}" -f $second
                        $dtStr = "$year-$monthStr-$dayStr $hourStr`:$minStr`:$secStr"
                        $empCodeStr = $enrollNo.ToString()

                        $sig = Get-LogSignature $empCodeStr $dtStr

                        if (-not $State.syncedSignatures.ContainsKey($sig)) {
                            $dir = "AUTO"
                            $vMode = "Face"
                            if ($verifyMode -eq 1) { $vMode = "Fingerprint" }
                            elseif ($verifyMode -eq 2) { $vMode = "Card" }
                            elseif ($verifyMode -eq 15) { $vMode = "Face" }

                            $newPunches += @{
                                employeeCode = $empCodeStr
                                logDateTime = $dtStr
                                direction = $dir
                                verificationMode = $vMode
                                deviceSerial = $MachineIp
                                deviceName = $DeviceName
                                branchId = $BranchId
                            }
                        }
                    }
                }
            }

            # Headers for Cloud API
            $Headers = @{
                "Content-Type" = "application/json"
                "User-Agent" = "Satyakiran-2WayBridge-v1.0"
            }
            if ($AuthToken) {
                $Headers["Authorization"] = "Bearer $AuthToken"
            }

            # If there are new punches, send to AWS Cloud
            if ($newPunches.Count -gt 0) {
                Write-Host "[$NowStr] 🔹 Uploading $($newPunches.Count) new punch(es) to cloud..." -ForegroundColor Cyan
                $BodyJson = $newPunches | ConvertTo-Json -Compress
                
                try {
                    $response = Invoke-RestMethod -Uri $CloudUrl -Method Post -Headers $Headers -Body $BodyJson -TimeoutSec 15
                    
                    # Mark signatures as synced
                    foreach ($p in $newPunches) {
                        $sig = Get-LogSignature $p.employeeCode $p.logDateTime
                        $State.syncedSignatures[$sig] = (Get-Date).ToString("o")
                        $State.totalSyncedCount++
                        Write-Host "      👤 EmpCode: $($p.employeeCode) | Time: $($p.logDateTime) | Mode: $($p.verificationMode)" -ForegroundColor Green
                    }

                    $State.lastSyncAt = (Get-Date).ToString("o")
                    Save-State
                    Write-Host "[$NowStr] ✅ Synced $($newPunches.Count) punch(es)! Total: $($State.totalSyncedCount)" -ForegroundColor Green

                    if ($response.pendingCommands) {
                        $pendingCommands = $response.pendingCommands
                    }
                } catch {
                    Write-Host "[$NowStr] ❌ Cloud Push Error: $($_.Exception.Message)" -ForegroundColor Red
                }
            }

            # -------------------------------------------------------------
            # WAY 2: Cloud -> Machine Commands (User Sync, Delete, Clock)
            # -------------------------------------------------------------
            if ($pendingCommands.Count -eq 0) {
                try {
                    $cmdRes = Invoke-RestMethod -Uri $CommandsUrl -Method Get -Headers $Headers -TimeoutSec 10
                    if ($cmdRes) { $pendingCommands = $cmdRes }
                } catch {}
            }

            if ($pendingCommands.Count -gt 0) {
                Write-Host "[$NowStr] ⚡ Processing $($pendingCommands.Count) 2-Way Hardware Command(s)..." -ForegroundColor Yellow

                foreach ($cmd in $pendingCommands) {
                    $cmdId = $cmd.id
                    $action = $cmd.action
                    $payload = $cmd.payload
                    $cmdSuccess = $false
                    $errMsg = $null

                    try {
                        if ($action -eq "SET_USER") {
                            $codeInt = 0
                            [int]::TryParse($payload.employeeCode, [ref]$codeInt) | Out-Null
                            if ($codeInt -le 0) { $codeInt = [Math]::Abs($payload.employeeId.GetHashCode() % 99999) }
                            
                            $uName = $payload.fullName
                            Write-Host "   📥 Writing Employee to Machine: [$codeInt] $uName" -ForegroundColor Cyan
                            
                            # Enable User on Machine
                            $sbx.EnableUser($MachineNum, $codeInt, 0, $true) | Out-Null
                            $cmdSuccess = $true
                        }
                        elseif ($action -eq "DELETE_USER") {
                            $codeInt = 0
                            [int]::TryParse($payload.employeeCode, [ref]$codeInt) | Out-Null
                            if ($codeInt -gt 0) {
                                Write-Host "   🗑️ Deleting Employee from Machine: [$codeInt]" -ForegroundColor Yellow
                                $sbx.DeleteEnrollData($MachineNum, $codeInt, 0, 11) | Out-Null
                                $cmdSuccess = $true
                            }
                        }
                        elseif ($action -eq "SYNC_TIME") {
                            Write-Host "   🕒 Synchronizing Machine Clock to exact IST Server Time..." -ForegroundColor Cyan
                            $tRes = $sbx.SetDeviceTime($MachineNum)
                            $cmdSuccess = [bool]$tRes
                        }
                    } catch {
                        $errMsg = $_.Exception.Message
                        $cmdSuccess = $false
                    }

                    # Acknowledge Command back to Cloud
                    $ackBody = @{
                        commandId = $cmdId
                        status = if ($cmdSuccess) { "COMPLETED" } else { "FAILED" }
                        error = $errMsg
                    } | ConvertTo-Json -Compress

                    try {
                        Invoke-RestMethod -Uri $AckUrl -Method Post -Headers $Headers -Body $ackBody -TimeoutSec 10 | Out-Null
                        Write-Host "   ✅ Command $action ($cmdId) marked $($ackBody.status)" -ForegroundColor Green
                    } catch {
                        Write-Host "   ⚠️ Could not acknowledge command $cmdId to cloud: $($_.Exception.Message)" -ForegroundColor Red
                    }
                }
            }

            try { $sbx.Disconnect() } catch { $sbx.CloseCommPort() }
        } else {
            Write-Host "[$NowStr] ⚠️  Cannot reach biometric device at $MachineIp`:$MachinePort (Device offline or busy)" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "[$NowStr] ⚠️  SDK Bridge Error: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Start-Sleep -Seconds $SyncInterval
}
