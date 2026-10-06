# Satyakiran Biometric Bridge Agent - 2-way (Machine <-> Cloud)
#   Way 1: Machine -> Cloud  (punches)
#   Way 2: Cloud -> Machine  (SET_USER, DELETE_USER, SYNC_TIME commands)
# Runs under supervisor.ps1 (32-bit PowerShell, because SBXPC.ocx is 32-bit COM).
# Keep this file ASCII-only (PowerShell 5.1 misreads BOM-less UTF-8).

param(
    [string]$DataDir = (Join-Path $env:ProgramData "SatyakiranBridge")
)

$ErrorActionPreference = "Stop"
$AppDir     = $PSScriptRoot
$Version    = (Get-Content (Join-Path $AppDir "VERSION") -Raw).Trim()
$ConfigFile = Join-Path $DataDir "config.json"
$StateFile  = Join-Path $DataDir "sync-state.json"
$LogDir     = Join-Path $DataDir "logs"
$Heartbeat  = Join-Path $DataDir "heartbeat.json"

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Log([string]$Level, [string]$Msg) {
    $line = "{0} [{1}] {2}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"), $Level, $Msg
    $file = Join-Path $LogDir ("agent-{0}.log" -f (Get-Date).ToString("yyyyMMdd"))
    try { Add-Content -Path $file -Value $line -Encoding UTF8 } catch {}
    Write-Host $line
}

function Remove-OldLogs {
    try {
        Get-ChildItem $LogDir -Filter "*.log" |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {}
}

if (-not (Test-Path $ConfigFile)) {
    Write-Log "ERROR" "config.json not found in $DataDir"
    exit 1
}

function Load-Config {
    $c = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    $script:MachineIp   = $c.machine.ip
    $script:MachinePort = [int]$c.machine.port
    $script:MachineNum  = [int]$c.machine.machineNumber
    $script:MachinePass = [int]$c.machine.password
    $script:DeviceName  = $c.machine.deviceName
    $script:CloudUrl    = $c.cloud.apiUrl
    $script:AuthToken   = $c.cloud.authToken
    $script:BranchId    = $c.cloud.branchId
    $script:SyncInterval = [int]$c.cloud.syncIntervalSeconds
    if ($script:SyncInterval -le 0) { $script:SyncInterval = 30 }
    $script:BatchSize = 100
    if ($c.options -and $c.options.maxBatchSize) { $script:BatchSize = [int]$c.options.maxBatchSize }
    $base = $script:CloudUrl -replace "/biometric-push$", ""
    $script:CommandsUrl = "$base/biometric-commands?branchId=$($script:BranchId)"
    $script:AckUrl      = "$base/biometric-commands/ack"
}
Load-Config

# --- State (de-duplication memory) ---------------------------------------
$State = @{ lastSyncAt = $null; totalSyncedCount = 0; syncedSignatures = @{} }
if (Test-Path $StateFile) {
    try {
        $loaded = Get-Content $StateFile -Raw | ConvertFrom-Json
        if ($loaded.syncedSignatures) {
            foreach ($p in $loaded.syncedSignatures.PSObject.Properties) { $State.syncedSignatures[$p.Name] = $p.Value }
        }
        if ($loaded.totalSyncedCount) { $State.totalSyncedCount = [int]$loaded.totalSyncedCount }
        if ($loaded.lastSyncAt) { $State.lastSyncAt = $loaded.lastSyncAt }
    } catch { Write-Log "WARN" "Could not parse sync-state.json, starting fresh." }
}

function Save-State {
    $tmp = "$StateFile.tmp"
    ($State | ConvertTo-Json -Depth 4) | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $StateFile -Force
}

function Write-Heartbeat([string]$Status) {
    try {
        @{ time = (Get-Date).ToString("o"); version = $Version; status = $Status; pid = $PID;
           totalSynced = $State.totalSyncedCount; lastSyncAt = $State.lastSyncAt } |
            ConvertTo-Json | Set-Content -Path $Heartbeat -Encoding UTF8
    } catch {}
}

function Get-VerifyModeName($m) {
    if ($m -eq 1) { return "Fingerprint" }
    if ($m -eq 2) { return "Card" }
    return "Face"
}

function ConvertTo-EnrollInt($payload) {
    $raw = if ($payload.enrollNumber) { [string]$payload.enrollNumber }
           elseif ($payload.punchId) { [string]$payload.punchId }
           else { [string]$payload.employeeCode }
    $n = 0
    [int]::TryParse(($raw -replace '\D', ''), [ref]$n) | Out-Null
    return $n
}

# --- Way 1: read punches from machine ------------------------------------
function Read-MachinePunches($sbx) {
    $records = New-Object System.Collections.ArrayList
    $hasLogs = $false
    try { $hasLogs = $sbx.ReadAllGLogData($MachineNum) } catch {}
    if (-not $hasLogs) { try { $hasLogs = $sbx.ReadGeneralLogData($MachineNum) } catch {} }
    if (-not $hasLogs) { return @() }

    $tMach = 0; $enrollNo = 0; $eMach = 0; $verifyMode = 0
    $year = 0; $month = 0; $day = 0; $hour = 0; $minute = 0; $second = 0

    $add = {
        $dt = "{0}-{1:D2}-{2:D2} {3:D2}:{4:D2}:{5:D2}" -f $year, $month, $day, $hour, $minute, $second
        [void]$records.Add(@{ code = $enrollNo.ToString(); dt = $dt; mode = $verifyMode })
    }

    $hasRecord = $false
    try {
        $hasRecord = $sbx.GetAllGLogData($MachineNum, [ref]$tMach, [ref]$enrollNo, [ref]$eMach, [ref]$verifyMode, [ref]$year, [ref]$month, [ref]$day, [ref]$hour, [ref]$minute, [ref]$second)
    } catch {}

    if ($hasRecord) {
        do { & $add } while ($sbx.GetAllGLogData($MachineNum, [ref]$tMach, [ref]$enrollNo, [ref]$eMach, [ref]$verifyMode, [ref]$year, [ref]$month, [ref]$day, [ref]$hour, [ref]$minute, [ref]$second))
    } else {
        while ($sbx.GetGeneralLogData($MachineNum, [ref]$tMach, [ref]$enrollNo, [ref]$eMach, [ref]$verifyMode, [ref]$year, [ref]$month, [ref]$day, [ref]$hour, [ref]$minute, [ref]$second)) { & $add }
    }
    return $records.ToArray()
}

function Push-Punches($records, $headers) {
    $new = @()
    foreach ($r in $records) {
        $sig = "$($r.code)_$($r.dt)"
        if (-not $State.syncedSignatures.ContainsKey($sig)) {
            $new += @{
                employeeCode = $r.code; logDateTime = $r.dt; direction = "AUTO"
                verificationMode = (Get-VerifyModeName $r.mode)
                deviceSerial = $MachineIp; deviceName = $DeviceName; branchId = $BranchId
            }
        }
    }
    if ($new.Count -eq 0) { return @() }

    Write-Log "INFO" "Uploading $($new.Count) new punch(es) to cloud..."
    $pending = @()
    for ($i = 0; $i -lt $new.Count; $i += $BatchSize) {
        $chunk = @($new[$i..([Math]::Min($i + $BatchSize, $new.Count) - 1)])
        $body = ConvertTo-Json -InputObject $chunk -Compress
        try {
            $resp = Invoke-RestMethod -Uri $CloudUrl -Method Post -Headers $headers -Body $body -TimeoutSec 30
            foreach ($p in $chunk) {
                $State.syncedSignatures["$($p.employeeCode)_$($p.logDateTime)"] = (Get-Date).ToString("o")
                $State.totalSyncedCount++
            }
            $State.lastSyncAt = (Get-Date).ToString("o")
            Save-State
            Write-Log "INFO" "Synced $($chunk.Count) punch(es). Total: $($State.totalSyncedCount)"
            if ($resp.pendingCommands) { $pending += @($resp.pendingCommands) }
        } catch {
            Write-Log "ERROR" "Cloud push failed (will retry next cycle): $($_.Exception.Message)"
            break
        }
    }
    return $pending
}

# --- Way 2: cloud -> machine commands ------------------------------------
function Invoke-MachineCommand($sbx, $cmd) {
    $action = $cmd.action
    $payload = $cmd.payload
    if ($action -eq "SET_USER") {
        $code = ConvertTo-EnrollInt $payload
        if ($code -le 0 -and $payload.employeeId) { $code = [Math]::Abs($payload.employeeId.GetHashCode() % 99999) }
        Write-Log "INFO" "SET_USER -> machine enroll #$code"
        $sbx.EnableUser($MachineNum, $code, 0, $true) | Out-Null
        return $true
    }
    if ($action -eq "DELETE_USER") {
        $code = ConvertTo-EnrollInt $payload
        if ($code -le 0) { throw "DELETE_USER without a valid enroll number" }
        Write-Log "INFO" "DELETE_USER -> machine enroll #$code"
        $sbx.DeleteEnrollData($MachineNum, $code, 0, 11) | Out-Null
        return $true
    }
    if ($action -eq "SYNC_TIME") {
        Write-Log "INFO" "SYNC_TIME -> setting machine clock"
        return [bool]$sbx.SetDeviceTime($MachineNum)
    }
    throw "Unknown command action: $action"
}

function Process-Commands($sbx, $commands, $headers) {
    Write-Log "INFO" "Processing $($commands.Count) cloud command(s)"
    foreach ($cmd in $commands) {
        $ok = $false; $err = $null
        try { $ok = Invoke-MachineCommand $sbx $cmd } catch { $err = $_.Exception.Message; Write-Log "ERROR" "Command $($cmd.action) failed: $err" }
        $status = if ($ok) { "COMPLETED" } else { "FAILED" }
        $ack = ConvertTo-Json -Compress -InputObject @{ commandId = $cmd.id; status = $status; error = $err }
        try {
            Invoke-RestMethod -Uri $AckUrl -Method Post -Headers $headers -Body $ack -TimeoutSec 15 | Out-Null
            Write-Log "INFO" "Command $($cmd.action) ($($cmd.id)) acknowledged as $status"
        } catch { Write-Log "WARN" "Could not acknowledge command $($cmd.id): $($_.Exception.Message)" }
    }
}

# --- Main loop -----------------------------------------------------------
Write-Log "INFO" "Agent v$Version started | machine $MachineIp`:$MachinePort #$MachineNum | branch $BranchId | every ${SyncInterval}s | previously synced $($State.totalSyncedCount)"
Remove-OldLogs
$lastLogClean = Get-Date

while ($true) {
    $sbx = $null
    try {
        Load-Config   # picks up config.json edits without restart
        Write-Heartbeat "polling"
        $headers = @{ "Content-Type" = "application/json"; "User-Agent" = "Satyakiran-Bridge/$Version" }
        if ($AuthToken) { $headers["Authorization"] = "Bearer $AuthToken" }

        $sbx = New-Object -ComObject "SBXPC.SBXPCCtrl.1"
        try { $sbx.DotNET() } catch {}
        $connected = $sbx.ConnectTcpip($MachineNum, $MachineIp, $MachinePort, $MachinePass)

        if ($connected) {
            $commands = @()
            $records = Read-MachinePunches $sbx
            $commands += @(Push-Punches $records $headers)

            if ($commands.Count -eq 0) {
                try { $res = Invoke-RestMethod -Uri $CommandsUrl -Method Get -Headers $headers -TimeoutSec 15; if ($res) { $commands = @($res) } } catch {}
            }
            if ($commands.Count -gt 0) { Process-Commands $sbx $commands $headers }

            try { $sbx.Disconnect() } catch { try { $sbx.CloseCommPort() } catch {} }
        } else {
            Write-Log "WARN" "Cannot reach biometric device at $MachineIp`:$MachinePort (offline or busy)"
        }
    } catch {
        Write-Log "WARN" "Bridge error: $($_.Exception.Message)"
    } finally {
        if ($sbx) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($sbx) } catch {} }
    }

    if (((Get-Date) - $lastLogClean).TotalHours -ge 24) { Remove-OldLogs; $lastLogClean = Get-Date }
    Write-Heartbeat "idle"
    Start-Sleep -Seconds $SyncInterval
}
