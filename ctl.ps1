# Satyakiran Bridge control tool (replaces all the old .bat helpers).
#   ctl.ps1 status | logs [-Lines 50] | restart | test | synctime
param(
    [Parameter(Position = 0)] [ValidateSet("status", "logs", "restart", "test", "synctime")] [string]$Command = "status",
    [int]$Lines = 50,
    [string]$DataDir = (Join-Path $env:ProgramData "SatyakiranBridge")
)
$Root = $PSScriptRoot
$Task = "SatyakiranBridge"
$Ps32 = Join-Path $env:SystemRoot "SysWOW64\WindowsPowerShell\v1.0\powershell.exe"

# COM needs 32-bit PowerShell: relaunch ourselves if needed.
if (($Command -in "test", "synctime") -and [Environment]::Is64BitProcess -and (Test-Path $Ps32)) {
    & $Ps32 -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath $Command -DataDir $DataDir
    exit $LASTEXITCODE
}

function Connect-Machine {
    $c = (Get-Content (Join-Path $DataDir "config.json") -Raw | ConvertFrom-Json).machine
    $sbx = New-Object -ComObject "SBXPC.SBXPCCtrl.1"
    try { $sbx.DotNET() } catch {}
    $ok = $sbx.ConnectTcpip([int]$c.machineNumber, $c.ip, [int]$c.port, [int]$c.password)
    return @{ sbx = $sbx; ok = $ok; num = [int]$c.machineNumber; ip = $c.ip; port = $c.port }
}

switch ($Command) {
    "status" {
        $t = Get-ScheduledTask -TaskName $Task -ErrorAction SilentlyContinue
        Write-Host "Task      : $(if ($t) { $t.State } else { 'NOT INSTALLED' })"
        Write-Host "Version   : $((Get-Content (Join-Path $Root 'app\VERSION') -Raw).Trim())"
        $hbFile = Join-Path $DataDir "heartbeat.json"
        if (Test-Path $hbFile) {
            $hb = Get-Content $hbFile -Raw | ConvertFrom-Json
            $age = [int]((Get-Date) - [datetime]$hb.time).TotalSeconds
            Write-Host "Heartbeat : $age s ago ($($hb.status))"
            Write-Host "Synced    : $($hb.totalSynced) punches, last at $($hb.lastSyncAt)"
        } else { Write-Host "Heartbeat : none yet" }
    }
    "logs" {
        $f = Get-ChildItem (Join-Path $DataDir "logs") -Filter "agent-*.log" | Sort-Object Name | Select-Object -Last 1
        if ($f) { Get-Content $f.FullName -Tail $Lines } else { Write-Host "No logs yet." }
    }
    "restart" {
        Stop-ScheduledTask -TaskName $Task -ErrorAction SilentlyContinue
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
            Where-Object { $_.CommandLine -match "agent\.ps1|supervisor\.ps1" } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 2
        Start-ScheduledTask -TaskName $Task
        Write-Host "Restarted."
    }
    "test" {
        $m = Connect-Machine
        if ($m.ok) { Write-Host "OK: connected to machine $($m.ip):$($m.port)"; try { $m.sbx.Disconnect() } catch {} } else { Write-Host "FAILED: cannot reach $($m.ip):$($m.port)"; exit 2 }
    }
    "synctime" {
        $m = Connect-Machine
        if (-not $m.ok) { Write-Host "FAILED: cannot reach machine"; exit 2 }
        Write-Host "Clock set: $([bool]$m.sbx.SetDeviceTime($m.num))"; try { $m.sbx.Disconnect() } catch {}
    }
}
