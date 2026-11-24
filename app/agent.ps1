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

# Hardware access goes through the managed SBXPCDLL_Net.dll wrapper (P/Invoke into SBXPCDLL.dll in SysWOW64),
# not the SBXPC.ocx ActiveX control, which cannot be created from PowerShell on some PCs (E_UNEXPECTED).
$WrapperDll = Join-Path $AppDir "SBXPCDLL_Net.dll"
if (-not (Test-Path $WrapperDll)) { $WrapperDll = Join-Path (Split-Path $AppDir -Parent) "SBXPCDLL_Net.dll" }
if (-not (Test-Path $WrapperDll)) { Write-Log "ERROR" "SBXPCDLL_Net.dll not found next to the agent"; exit 1 }
[void][Reflection.Assembly]::LoadFrom($WrapperDll)

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
    if ($m -eq 3) { return "Password" }
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
function Read-MachinePunches {
    $records = New-Object System.Collections.ArrayList
    [void][sbxpc.SBXPCDLL]::EnableDevice($MachineNum, 0)
    try {
        $hasLogs = [sbxpc.SBXPCDLL]::ReadAllGLogData($MachineNum)
        if (-not $hasLogs) { $hasLogs = [sbxpc.SBXPCDLL]::ReadGeneralLogData($MachineNum, 0) }
        if (-not $hasLogs) { return @() }

        $tmno = 0; $seno = 0; $smno = 0; $vmode = 0
        $yr = 0; $mon = 0; $day = 0; $hr = 0; $min = 0; $sec = 0
        while ([sbxpc.SBXPCDLL]::GetAllGLogData($MachineNum, [ref]$tmno, [ref]$seno, [ref]$smno, [ref]$vmode, [ref]$yr, [ref]$mon, [ref]$day, [ref]$hr, [ref]$min, [ref]$sec)) {
            $dt = "{0:D4}-{1:D2}-{2:D2} {3:D2}:{4:D2}:{5:D2}" -f $yr, $mon, $day, $hr, $min, $sec
            [void]$records.Add(@{ code = $seno.ToString(); dt = $dt; mode = $vmode })
        }
    } finally {
        try { [void][sbxpc.SBXPCDLL]::EnableDevice($MachineNum, 1) } catch {}
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
function Invoke-MachineCommand($sbxUnused, $cmd) {
    $action = [string]$cmd.action
    $payload = $cmd.payload
    $dll = [sbxpc.SBXPCDLL]
    [void]$dll::EnableDevice($MachineNum, 0)
    try {
        if ($action -eq "SET_USER" -or $action -eq "CREATE_USER" -or $action -eq "UPDATE_USER") {
            $code = ConvertTo-EnrollInt $payload
            if ($code -le 0) { throw "$action without a valid enroll number" }
            $name = [string]$(if ($payload.employeeName) { $payload.employeeName } elseif ($payload.fullName) { $payload.fullName } else { "" })
            Write-Log "INFO" "$action -> machine enroll #$code ($name)"
            if ($name) { [void]$dll::SetUserName1($MachineNum, $code, $name) }
            if ($action -ne "UPDATE_USER") { [void]$dll::EnableUser($MachineNum, $code, 0, 0, [byte]1) }
            return $true
        }
        if ($action -eq "DELETE_USER" -or $action -eq "REMOVE_USER") {
            $code = ConvertTo-EnrollInt $payload
            if ($code -le 0) { throw "$action without a valid enroll number" }
            Write-Log "INFO" "$action -> machine enroll #$code"
            $r = $dll::DeleteEnrollData($MachineNum, $code, 0, 12)
            if (-not $r) { [void]$dll::DeleteEnrollData($MachineNum, $code, 0, 11) }
            [void]$dll::SetUserName1($MachineNum, $code, "")
            [void]$dll::EnableUser($MachineNum, $code, 0, 0, [byte]0)
            return $true
        }
        if ($action -eq "ENABLE_USER" -or $action -eq "DISABLE_USER") {
            $code = ConvertTo-EnrollInt $payload
            if ($code -le 0) { throw "$action without a valid enroll number" }
            [void]$dll::EnableUser($MachineNum, $code, 0, 0, [byte]$(if ($action -eq "ENABLE_USER") { 1 } else { 0 }))
            return $true
        }
        if ($action -eq "SYNC_TIME") {
            Write-Log "INFO" "SYNC_TIME -> setting machine clock"
            return [bool]$dll::SetDeviceTime($MachineNum)
        }
        if ($action -eq "CLEAR_LOGS") {
            return [bool]$dll::EmptyGeneralLogData($MachineNum)
        }
        if ($action -eq "GET_USERS") {
            # Enrolled users (code + name) so EMS can create / map the codes it does not know yet.
            $wanted = @{}
            if ($payload -and $payload.codes) { foreach ($c in @($payload.codes)) { $wanted[([string]$c).Trim()] = $true } }
            $seen = New-Object System.Collections.Generic.List[int]
            $total = 0
            if ($dll::ReadAllUserID($MachineNum)) {
                $e = 0; $em = 0; $bk = 0; $pr = 0; $en = 0
                while ($dll::GetAllUserID($MachineNum, [ref]$e, [ref]$em, [ref]$bk, [ref]$pr, [ref]$en)) {
                    $total++
                    if (-not $seen.Contains($e)) { $seen.Add($e) }
                }
            }
            $users = New-Object System.Collections.ArrayList
            foreach ($u in $seen) {
                if ($wanted.Count -gt 0 -and -not $wanted.ContainsKey([string]$u)) { continue }
                $nm = ""
                try { [void]$dll::GetUserName1($MachineNum, $u, [ref]$nm) } catch {}
                [void]$users.Add(@{ employeeCode = [string]$u; employeeName = ([string]$nm).Trim() })
            }
            Write-Log "INFO" "GET_USERS -> $total record(s) on machine, $($seen.Count) distinct user(s), returning $($users.Count)"
            $script:LastResult = @{ users = $users.ToArray(); totalOnMachine = $seen.Count; wanted = @($wanted.Keys) }
            return $true
        }
        throw "Unknown command action: $action"
    } finally {
        try { [void]$dll::EnableDevice($MachineNum, 1) } catch {}
    }
}

function Process-Commands($sbx, $commands, $headers) {
    Write-Log "INFO" "Processing $($commands.Count) cloud command(s)"
    foreach ($cmd in $commands) {
        $ok = $false; $err = $null; $script:LastResult = $null
        try { $ok = Invoke-MachineCommand $sbx $cmd } catch { $err = $_.Exception.Message; Write-Log "ERROR" "Command $($cmd.action) failed: $err" }
        $status = if ($ok) { "COMPLETED" } else { "FAILED" }
        $ack = ConvertTo-Json -Compress -Depth 6 -InputObject @{ commandId = $cmd.id; status = $status; error = $err; result = $script:LastResult }
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
    $connected = $false
    try {
        Load-Config   # picks up config.json edits without restart
        Write-Heartbeat "polling"
        $headers = @{ "Content-Type" = "application/json"; "User-Agent" = "Satyakiran-Bridge/$Version" }
        if ($AuthToken) { $headers["Authorization"] = "Bearer $AuthToken" }

        [sbxpc.SBXPCDLL]::DotNET()
        try { [sbxpc.SBXPCDLL]::_DisableTranseiveCallback() } catch {}
        $connected = [sbxpc.SBXPCDLL]::ConnectTcpip($MachineNum, $MachineIp, $MachinePort, $MachinePass)

        if ($connected) {
            $commands = @()
            $records = Read-MachinePunches
            $commands += @(Push-Punches $records $headers)

            if ($commands.Count -eq 0) {
                try { $res = Invoke-RestMethod -Uri $CommandsUrl -Method Get -Headers $headers -TimeoutSec 15; if ($res) { $commands = @($res) } } catch {}
            }
            if ($commands.Count -gt 0) { Process-Commands $null $commands $headers }
        } else {
            Write-Log "WARN" "Cannot reach biometric device at $MachineIp`:$MachinePort (offline or busy)"
        }
    } catch {
        Write-Log "WARN" "Bridge error: $($_.Exception.Message)"
    } finally {
        if ($connected) { try { [void][sbxpc.SBXPCDLL]::Disconnect($MachineNum) } catch {} }
    }

    if (((Get-Date) - $lastLogClean).TotalHours -ge 24) { Remove-OldLogs; $lastLogClean = Get-Date }
    Write-Heartbeat "idle"
    Start-Sleep -Seconds $SyncInterval
}
