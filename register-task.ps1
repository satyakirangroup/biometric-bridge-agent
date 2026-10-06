# Registers / removes the "SatyakiranBridge" scheduled task (called by the installer).
param(
    [ValidateSet("install", "remove", "stop")] [string]$Action = "install",
    [string]$DataDir = (Join-Path $env:ProgramData "SatyakiranBridge")
)
$TaskName = "SatyakiranBridge"
$Root = $PSScriptRoot
$Ps32 = Join-Path $env:SystemRoot "SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
if (-not (Test-Path $Ps32)) { $Ps32 = "powershell.exe" }

if ($Action -in "stop", "remove") {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -match "agent\.ps1|supervisor\.ps1" -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    if ($Action -eq "remove") { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue }
    exit 0
}

$arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Root\supervisor.ps1`" -DataDir `"$DataDir`""
$action = New-ScheduledTaskAction -Execute $Ps32 -Argument $arg -WorkingDirectory $Root
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
