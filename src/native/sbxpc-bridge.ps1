param (
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Action,

    [Parameter(Position=1)]
    [int]$MachineNumber = 1,

    [Parameter(Position=2)]
    [string]$Ip = "192.168.1.14",

    [Parameter(Position=3)]
    [int]$Port = 5005,

    [Parameter(Position=4)]
    [int]$Password = 0,

    [Parameter(Position=5)]
    [string]$DeviceName = "Biometric Device",

    [Parameter(Position=6)]
    [string]$TargetEnrollNumber = "0",

    [Parameter(Position=7)]
    [string]$TargetUserName = "",

    [Parameter(Position=8)]
    [int]$TargetPrivilege = 0,

    [Parameter(Position=9)]
    [int]$TargetEnable = 1
)

$ErrorActionPreference = "Stop"

# Sanitize TargetEnrollNumber so values like "EMP-0001", "EMP-00000043", "NaN" never crash parameter binding
$rawEnrollStr = [string]$TargetEnrollNumber
$cleanEnroll = ($rawEnrollStr -replace '\D', '')
$targetEnrollInt = 0
if (-not [int]::TryParse($cleanEnroll, [ref]$targetEnrollInt) -or $targetEnrollInt -le 0) {
    if (-not [int]::TryParse($rawEnrollStr, [ref]$targetEnrollInt)) {
        $targetEnrollInt = 0
    }
}
$TargetEnrollNumber = $targetEnrollInt

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BaseDir = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$DllPath = Join-Path $BaseDir "SBXPCDLL_Net.dll"
$CsPath = Join-Path $ScriptDir "SBXPCDLL.cs"

# 1. Load Assembly
try {
    if (Test-Path $DllPath) {
        [System.Reflection.Assembly]::LoadFrom($DllPath) | Out-Null
    } elseif (Test-Path $CsPath) {
        Add-Type -Path $CsPath
    } else {
        Write-Error "ERROR: Neither SBXPCDLL_Net.dll nor SBXPCDLL.cs found!"
        exit 1
    }
} catch {
    Write-Error "ERROR: Failed to load SBXPC assembly: $_"
    exit 1
}

# 2. Initialize Hardware Communication
[sbxpc.SBXPCDLL]::DotNET()
[sbxpc.SBXPCDLL]::_DisableTranseiveCallback()

$conn = [sbxpc.SBXPCDLL]::ConnectTcpip($MachineNumber, $Ip, $Port, $Password)
if (-not $conn) {
    [Console]::Error.WriteLine("ERROR: Cannot connect to biometric device at $Ip`:$Port (Device offline or busy)")
    exit 2
}

try {
    switch ($Action.ToLowerInvariant()) {
        "fetch-logs" {
            $empMapFile = Join-Path $BaseDir "logs\enrolled_employees.json"
            $empMap = @{}
            if (Test-Path $empMapFile) {
                try {
                    $loadedMap = Get-Content $empMapFile -Raw | ConvertFrom-Json
                    foreach ($prop in $loadedMap.PSObject.Properties) {
                        $empMap[$prop.Name] = $prop.Value
                    }
                } catch {}
            }

            [sbxpc.SBXPCDLL]::EnableDevice($MachineNumber, 0) | Out-Null
            try {
                $hasLogs = [sbxpc.SBXPCDLL]::ReadAllGLogData($MachineNumber)
                if (-not $hasLogs) {
                    $hasLogs = [sbxpc.SBXPCDLL]::ReadGeneralLogData($MachineNumber, 0)
                }

                $sb = New-Object System.Text.StringBuilder
                [void]$sb.Append("[")
                $first = $true

                $tmno = 0; $seno = 0; $smno = 0; $vmode = 0
                $yr = 0; $mon = 0; $day = 0; $hr = 0; $min = 0; $sec = 0

                while ($true) {
                    $gotRec = [sbxpc.SBXPCDLL]::GetAllGLogData($MachineNumber, [ref]$tmno, [ref]$seno, [ref]$smno, [ref]$vmode, [ref]$yr, [ref]$mon, [ref]$day, [ref]$hr, [ref]$min, [ref]$sec)
                    if (-not $gotRec) { break }

                    $dtStr = "{0:D4}-{1:D2}-{2:D2} {3:D2}:{4:D2}:{5:D2}" -f $yr, $mon, $day, $hr, $min, $sec
                    $vModeStr = "Face"
                    if ($vmode -eq 1) { $vModeStr = "Fingerprint" }
                    elseif ($vmode -eq 2) { $vModeStr = "Card" }
                    elseif ($vmode -eq 3) { $vModeStr = "Password" }
                    elseif ($vmode -eq 15 -or $vmode -eq 407 -or $vmode -eq 20) { $vModeStr = "Face" }

                    if (-not $first) { [void]$sb.Append(",") }
                    $first = $false

                    $senoStr = [string]$seno
                    $empName = if ($empMap.ContainsKey($senoStr)) { [string]$empMap[$senoStr] } else { "" }
                    $escapedEmpName = $empName.Replace("\", "\\").Replace('"', '\"')
                    $escapedName = $DeviceName.Replace("\", "\\").Replace('"', '\"')
                    $item = '{"employeeCode":"' + $seno + '","employeeName":"' + $escapedEmpName + '","logDateTime":"' + $dtStr + '","direction":"AUTO","verificationMode":"' + $vModeStr + '","deviceSerial":"' + $Ip + '","deviceName":"' + $escapedName + '"}'
                    [void]$sb.Append($item)
                }

                [void]$sb.Append("]")
                [Console]::WriteLine($sb.ToString())
            } finally {
                [sbxpc.SBXPCDLL]::EnableDevice($MachineNumber, 1) | Out-Null
            }
        }

        "inspect" {
            # Clock
            $dY = 0; $dM = 0; $dD = 0; $dH = 0; $dMi = 0; $dS = 0; $dDow = 0
            [sbxpc.SBXPCDLL]::GetDeviceTime($MachineNumber, [ref]$dY, [ref]$dM, [ref]$dD, [ref]$dH, [ref]$dMi, [ref]$dS, [ref]$dDow) | Out-Null
            $devTime = "{0:D4}-{1:D2}-{2:D2} {3:D2}:{4:D2}:{5:D2}" -f $dY, $dM, $dD, $dH, $dMi, $dS

            # Registers
            [uint32]$userCount = 0; [uint32]$totalLogs = 0; [uint32]$unreadLogs = 0
            [uint32]$fpCount = 0; [uint32]$faceCount = 0; [uint32]$pwdCount = 0

            [sbxpc.SBXPCDLL]::GetDeviceStatus($MachineNumber, 2, [ref]$userCount) | Out-Null
            [sbxpc.SBXPCDLL]::GetDeviceStatus($MachineNumber, 6, [ref]$totalLogs) | Out-Null
            [sbxpc.SBXPCDLL]::GetDeviceStatus($MachineNumber, 11, [ref]$unreadLogs) | Out-Null
            [sbxpc.SBXPCDLL]::GetDeviceStatus($MachineNumber, 3, [ref]$fpCount) | Out-Null
            [sbxpc.SBXPCDLL]::GetDeviceStatus($MachineNumber, 9, [ref]$faceCount) | Out-Null
            [sbxpc.SBXPCDLL]::GetDeviceStatus($MachineNumber, 4, [ref]$pwdCount) | Out-Null

            # Enrolled Users
            [sbxpc.SBXPCDLL]::EnableDevice($MachineNumber, 0) | Out-Null
            $users = New-Object System.Collections.Generic.List[int]
            try {
                if ([sbxpc.SBXPCDLL]::ReadAllUserID($MachineNumber)) {
                    $uEnroll = 0; $uEmach = 0; $uBackup = 0; $uPriv = 0; $uEnable = 0
                    while ([sbxpc.SBXPCDLL]::GetAllUserID($MachineNumber, [ref]$uEnroll, [ref]$uEmach, [ref]$uBackup, [ref]$uPriv, [ref]$uEnable)) {
                        if (-not $users.Contains($uEnroll)) { $users.Add($uEnroll) }
                    }
                }
            } finally {
                [sbxpc.SBXPCDLL]::EnableDevice($MachineNumber, 1) | Out-Null
            }

            # Punches
            [sbxpc.SBXPCDLL]::EnableDevice($MachineNumber, 0) | Out-Null
            $punchSb = New-Object System.Text.StringBuilder
            [void]$punchSb.Append("[")
            try {
                if ([sbxpc.SBXPCDLL]::ReadAllGLogData($MachineNumber)) {
                    $tmno = 0; $seno = 0; $smno = 0; $vmode = 0
                    $yr = 0; $mon = 0; $day = 0; $hr = 0; $min = 0; $sec = 0
                    $first = $true
                    while ([sbxpc.SBXPCDLL]::GetAllGLogData($MachineNumber, [ref]$tmno, [ref]$seno, [ref]$smno, [ref]$vmode, [ref]$yr, [ref]$mon, [ref]$day, [ref]$hr, [ref]$min, [ref]$sec)) {
                        if (-not $first) { [void]$punchSb.Append(",") }
                        $first = $false
                        $dtStr = "{0:D4}-{1:D2}-{2:D2} {3:D2}:{4:D2}:{5:D2}" -f $yr, $mon, $day, $hr, $min, $sec
                        $vModeStr = "Face"
                        if ($vmode -eq 1) { $vModeStr = "Fingerprint" }
                        elseif ($vmode -eq 2) { $vModeStr = "Card" }
                        elseif ($vmode -eq 3) { $vModeStr = "Password" }
                        elseif ($vmode -eq 15 -or $vmode -eq 407 -or $vmode -eq 20) { $vModeStr = "Face" }

                        $pItem = '{"emp":"' + $seno + '","time":"' + $dtStr + '","mode":"' + $vModeStr + '"}'
                        [void]$punchSb.Append($pItem)
                    }
                }
            } finally {
                [sbxpc.SBXPCDLL]::EnableDevice($MachineNumber, 1) | Out-Null
            }
            [void]$punchSb.Append("]")

            $userListStr = $users -join ","

            [Console]::WriteLine("JSON_START")
            [Console]::WriteLine("{" + @"
  "deviceTime": "$devTime",
  "userCount": $userCount,
  "fpCount": $fpCount,
  "faceCount": $faceCount,
  "pwdCount": $pwdCount,
  "totalLogs": $totalLogs,
  "unreadLogs": $unreadLogs,
  "enrolledUsers": [$userListStr],
  "punches": $($punchSb.ToString())
}
"@)
            [Console]::WriteLine("JSON_END")
        }

        "clear-logs" {
            [sbxpc.SBXPCDLL]::EnableDevice($MachineNumber, 0) | Out-Null
            try {
                $ok = [sbxpc.SBXPCDLL]::EmptyGeneralLogData($MachineNumber)
                if ($ok) {
                    [Console]::WriteLine('{"cleared":true}')
                } else {
                    [Console]::Error.WriteLine("ERROR: Failed to empty log data on device.")
                    exit 4
                }
            } finally {
                [sbxpc.SBXPCDLL]::EnableDevice($MachineNumber, 1) | Out-Null
            }
        }

        "test-conn" {
            [Console]::WriteLine('{"connected":true,"ip":"' + $Ip + '","port":' + $Port + '}')
        }

        "get-users" {
            [sbxpc.SBXPCDLL]::EnableDevice($MachineNumber, 0) | Out-Null
            try {
                $users = New-Object System.Collections.Generic.List[int]
                $empMap = @{}
                $logsDir = Join-Path $BaseDir "logs"
                if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
                $empMapFile = Join-Path $logsDir "enrolled_employees.json"
                if (Test-Path $empMapFile) {
                    try {
                        $loadedMap = Get-Content $empMapFile -Raw | ConvertFrom-Json
                        foreach ($prop in $loadedMap.PSObject.Properties) {
                            $empMap[$prop.Name] = $prop.Value
                        }
                    } catch {}
                }

                if ([sbxpc.SBXPCDLL]::ReadAllUserID($MachineNumber)) {
                    $uEnroll = 0; $uEmach = 0; $uBackup = 0; $uPriv = 0; $uEnable = 0
                    while ([sbxpc.SBXPCDLL]::GetAllUserID($MachineNumber, [ref]$uEnroll, [ref]$uEmach, [ref]$uBackup, [ref]$uPriv, [ref]$uEnable)) {
                        if (-not $users.Contains($uEnroll)) {
                            $users.Add($uEnroll)
                            $uStr = [string]$uEnroll
                            if (-not $empMap.ContainsKey($uStr) -or [string]::IsNullOrWhiteSpace($empMap[$uStr])) {
                                $uName = ""
                                [sbxpc.SBXPCDLL]::GetUserName1($MachineNumber, $uEnroll, [ref]$uName) | Out-Null
                                if (-not [string]::IsNullOrWhiteSpace($uName)) {
                                    $empMap[$uStr] = $uName
                                }
                            }
                        }
                    }
                    try {
                        [System.IO.File]::WriteAllText($empMapFile, ($empMap | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
                    } catch {}
                }

                $sb = New-Object System.Text.StringBuilder
                [void]$sb.Append("[")
                $first = $true
                foreach ($u in $users) {
                    if (-not $first) { [void]$sb.Append(",") }
                    $first = $false
                    $uStr = [string]$u
                    $name = if ($empMap.ContainsKey($uStr)) { [string]$empMap[$uStr] } else { "" }
                    $escName = $name.Replace("\", "\\").Replace('"', '\"')
                    [void]$sb.Append('{"employeeCode":"' + $uStr + '","employeeName":"' + $escName + '"}')
                }
                [void]$sb.Append("]")
                [Console]::WriteLine($sb.ToString())
            } finally {
                [sbxpc.SBXPCDLL]::EnableDevice($MachineNumber, 1) | Out-Null
            }
        }

        "get-user" {
            [sbxpc.SBXPCDLL]::EnableDevice($MachineNumber, 0) | Out-Null
            try {
                $name = ""
                [sbxpc.SBXPCDLL]::GetUserName1($MachineNumber, $TargetEnrollNumber, [ref]$name) | Out-Null
                $priv = 0; $pwd = 0
                [sbxpc.SBXPCDLL]::GetEnrollData1($MachineNumber, $TargetEnrollNumber, 10, [ref]$priv, [IntPtr]::Zero, [ref]$pwd) | Out-Null

                $escName = $name.Replace("\", "\\").Replace('"', '\"')
                [Console]::WriteLine('{"success":true,"employeeCode":"' + $TargetEnrollNumber + '","employeeName":"' + $escName + '","privilege":' + $priv + '}')
            } finally {
                [sbxpc.SBXPCDLL]::EnableDevice($MachineNumber, 1) | Out-Null
            }
        }

        "set-user" {
            [sbxpc.SBXPCDLL]::EnableDevice($MachineNumber, 0) | Out-Null
            try {
                $resName = [sbxpc.SBXPCDLL]::SetUserName1($MachineNumber, $TargetEnrollNumber, $TargetUserName)
                $resEn = [sbxpc.SBXPCDLL]::EnableUser($MachineNumber, $TargetEnrollNumber, 0, 0, [byte]$TargetEnable)
                if ($TargetPrivilege -ge 0) {
                    [sbxpc.SBXPCDLL]::ModifyPrivilege($MachineNumber, $TargetEnrollNumber, 0, 0, $TargetPrivilege) | Out-Null
                }

                # Update local cache enrolled_employees.json
                $logsDir = Join-Path $BaseDir "logs"
                if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
                $empMapFile = Join-Path $logsDir "enrolled_employees.json"
                $empMap = @{}
                if (Test-Path $empMapFile) {
                    try {
                        $loadedMap = Get-Content $empMapFile -Raw | ConvertFrom-Json
                        foreach ($prop in $loadedMap.PSObject.Properties) {
                            $empMap[$prop.Name] = $prop.Value
                        }
                    } catch {}
                }
                $empMap["$TargetEnrollNumber"] = $TargetUserName
                [System.IO.File]::WriteAllText($empMapFile, ($empMap | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))

                [Console]::WriteLine('{"success":true,"action":"SET_USER","employeeCode":"' + $TargetEnrollNumber + '","employeeName":"' + $TargetUserName + '","privilege":' + $TargetPrivilege + ',"enabled":' + ($TargetEnable -eq 1).ToString().ToLower() + '}')
            } finally {
                [sbxpc.SBXPCDLL]::EnableDevice($MachineNumber, 1) | Out-Null
            }
        }

        "delete-user" {
            [sbxpc.SBXPCDLL]::EnableDevice($MachineNumber, 0) | Out-Null
            try {
                # Attempt to delete all enrolled biometric/card/password data
                $res = [sbxpc.SBXPCDLL]::DeleteEnrollData($MachineNumber, $TargetEnrollNumber, 0, 12)
                if (-not $res) {
                    $res = [sbxpc.SBXPCDLL]::DeleteEnrollData($MachineNumber, $TargetEnrollNumber, 0, 11)
                }
                # Clear name and disable user
                [sbxpc.SBXPCDLL]::SetUserName1($MachineNumber, $TargetEnrollNumber, "") | Out-Null
                [sbxpc.SBXPCDLL]::EnableUser($MachineNumber, $TargetEnrollNumber, 0, 0, 0) | Out-Null

                # Remove from local cache
                $logsDir = Join-Path $BaseDir "logs"
                $empMapFile = Join-Path $logsDir "enrolled_employees.json"
                if (Test-Path $empMapFile) {
                    try {
                        $loadedMap = Get-Content $empMapFile -Raw | ConvertFrom-Json
                        $empMap = @{}
                        foreach ($prop in $loadedMap.PSObject.Properties) {
                            if ($prop.Name -ne "$TargetEnrollNumber") {
                                $empMap[$prop.Name] = $prop.Value
                            }
                        }
                        [System.IO.File]::WriteAllText($empMapFile, ($empMap | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
                    } catch {}
                }

                [Console]::WriteLine('{"success":true,"action":"DELETE_USER","employeeCode":"' + $TargetEnrollNumber + '"}')
            } finally {
                [sbxpc.SBXPCDLL]::EnableDevice($MachineNumber, 1) | Out-Null
            }
        }

        "sync-time" {
            $res = [sbxpc.SBXPCDLL]::SetDeviceTime($MachineNumber)
            [Console]::WriteLine('{"success":' + ($res).ToString().ToLower() + ',"action":"SYNC_TIME"}')
        }

        default {
            [Console]::Error.WriteLine("ERROR: Unknown action '$Action'")
            exit 1
        }
    }
} finally {
    try { [sbxpc.SBXPCDLL]::Disconnect($MachineNumber) } catch {}
}
