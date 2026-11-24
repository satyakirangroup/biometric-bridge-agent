# Satyakiran Biometric Bridge - Manager (settings UI)
#   Set machine IP / cloud details, test the connection, see live status and logs,
#   restart the service, check for updates. Saving config applies within ~30 s (agent reloads it).
# Started from the Start Menu / Desktop shortcut in 32-bit PowerShell (SBXPC.ocx is 32-bit COM).
# Keep this file ASCII-only (PowerShell 5.1 misreads BOM-less UTF-8).

param(
    [string]$DataDir = (Join-Path $env:ProgramData "SatyakiranBridge")
)

$ErrorActionPreference = "Stop"
$AppDir  = $PSScriptRoot
$Root    = Split-Path $AppDir -Parent
$Ps32    = Join-Path $env:SystemRoot "SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
if (-not (Test-Path $Ps32)) { $Ps32 = "powershell.exe" }

# Needs admin (writes ProgramData config, controls the SYSTEM service) -> relaunch elevated, 32-bit.
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -or [Environment]::Is64BitProcess) {
    Start-Process $Ps32 -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`" -DataDir `"$DataDir`""
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$TaskName   = "SatyakiranBridge"
$ConfigFile = Join-Path $DataDir "config.json"
$Heartbeat  = Join-Path $DataDir "heartbeat.json"
$LogDir     = Join-Path $DataDir "logs"
$DefaultCloud    = "https://api.satyakiran.co.in/api/v1/hrms/attendance/biometric-push"
$DefaultManifest = "https://github.com/satyakirangroup/biometric-bridge-agent/releases/latest/download/version.json"
New-Item -ItemType Directory -Force -Path $DataDir, $LogDir | Out-Null

function Get-Version { try { (Get-Content (Join-Path $AppDir "VERSION") -Raw).Trim() } catch { "?" } }

function Read-Config {
    $d = [ordered]@{ ip = "192.168.0.124"; port = "5005"; num = "1"; pass = "0"; name = "Biometric Machine"; cloud = $DefaultCloud; token = ""; branch = ""; interval = "30"; update = $null; options = $null }
    if (Test-Path $ConfigFile) {
        try {
            $c = Get-Content $ConfigFile -Raw | ConvertFrom-Json
            if ($c.machine.ip) { $d.ip = [string]$c.machine.ip }
            if ($c.machine.port) { $d.port = [string]$c.machine.port }
            if ($c.machine.machineNumber) { $d.num = [string]$c.machine.machineNumber }
            if ($null -ne $c.machine.password) { $d.pass = [string]$c.machine.password }
            if ($c.machine.deviceName) { $d.name = [string]$c.machine.deviceName }
            if ($c.cloud.apiUrl) { $d.cloud = [string]$c.cloud.apiUrl }
            if ($c.cloud.authToken) { $d.token = [string]$c.cloud.authToken }
            if ($c.cloud.branchId) { $d.branch = [string]$c.cloud.branchId }
            if ($c.cloud.syncIntervalSeconds) { $d.interval = [string]$c.cloud.syncIntervalSeconds }
            $d.update = $c.update
            $d.options = $c.options
        } catch {}
    }
    return $d
}

function Write-Config($v) {
    $cfg = [ordered]@{
        machine = [ordered]@{ ip = $v.ip; port = [int]$v.port; machineNumber = [int]$v.num; password = [int]$v.pass; deviceName = $v.name }
        cloud   = [ordered]@{ apiUrl = $v.cloud; authToken = $v.token; branchId = $v.branch; syncIntervalSeconds = [int]$v.interval }
        options = $(if ($v.options) { $v.options } else { [ordered]@{ maxBatchSize = 100 } })
        update  = $(if ($v.update) { $v.update } else { [ordered]@{ enabled = $true; checkHours = 6 } })
    }
    $tmp = "$ConfigFile.tmp"
    [IO.File]::WriteAllText($tmp, ($cfg | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    Move-Item $tmp $ConfigFile -Force
}

function Test-TcpPort([string]$ip, [int]$port, [int]$ms = 3000) {
    $c = New-Object Net.Sockets.TcpClient
    try {
        $ar = $c.BeginConnect($ip, $port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($ms)) { return $false }
        $c.EndConnect($ar); return $true
    } catch { return $false } finally { $c.Close() }
}

function Test-Machine($v) {
    if (-not (Test-TcpPort $v.ip ([int]$v.port))) {
        return "FAILED: this PC cannot reach $($v.ip):$($v.port) at all.`nCheck the machine IP / WiFi, that the machine is on, and that this PC is on the same network."
    }
    try {
        $dllPath = Join-Path $AppDir "SBXPCDLL_Net.dll"
        if (-not (Test-Path $dllPath)) { $dllPath = Join-Path $Root "SBXPCDLL_Net.dll" }
        if (-not (Test-Path $dllPath)) { return "FAILED: SBXPCDLL_Net.dll is missing from the install folder." }
        if (-not ("sbxpc.SBXPCDLL" -as [type])) { [void][Reflection.Assembly]::LoadFrom($dllPath) }
        [sbxpc.SBXPCDLL]::DotNET()
        try { [sbxpc.SBXPCDLL]::_DisableTranseiveCallback() } catch {}
        for ($i = 0; $i -lt 2; $i++) {
            if ([sbxpc.SBXPCDLL]::ConnectTcpip([int]$v.num, $v.ip, [int]$v.port, [int]$v.pass)) {
                try { [void][sbxpc.SBXPCDLL]::Disconnect([int]$v.num) } catch {}
                return "OK: connected to the machine at $($v.ip):$($v.port)."
            }
            Start-Sleep -Seconds 2
        }
        return "Port is open but the machine did not accept the SDK connection.`nCheck Machine No. and Comm Key (password) on the machine, or close other software connected to it (it allows one connection at a time)."
    } catch {
        return "FAILED: could not load the biometric SDK (SBXPCDLL.dll must be in C:\Windows\SysWOW64).`n$($_.Exception.Message)"
    }
}

function Test-Cloud($v) {
    try {
        $base = $v.cloud -replace "/biometric-push$", ""
        $r = Invoke-RestMethod -Uri "$base/biometric-health?branchId=$($v.branch)" -TimeoutSec 15
        return "OK: cloud reachable. Server status: $($r.status) - $($r.message)"
    } catch { return "FAILED: cannot reach the cloud: $($_.Exception.Message)" }
}

function Get-ServiceState {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($t) { return [string]$t.State } else { return "NOT INSTALLED" }
}

function Restart-Service2 {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -match "agent\.ps1|supervisor\.ps1" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
    if (-not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) {
        & $Ps32 -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "register-task.ps1") -Action install -DataDir $DataDir | Out-Null
    } else { Start-ScheduledTask -TaskName $TaskName }
}

# ---------------------------------------------------------------- UI
$font  = New-Object Drawing.Font("Segoe UI", 9)
$bold  = New-Object Drawing.Font("Segoe UI", 9, [Drawing.FontStyle]::Bold)
$brand = [Drawing.Color]::FromArgb(0, 102, 77)

$form = New-Object Windows.Forms.Form
$form.Text = "Satyakiran Biometric Bridge"
$form.Size = New-Object Drawing.Size(600, 660)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false
$form.Font = $font

$hdr = New-Object Windows.Forms.Label
$hdr.Text = "  Satyakiran Biometric Bridge   v$(Get-Version)"
$hdr.Dock = "Top"; $hdr.Height = 44; $hdr.BackColor = $brand; $hdr.ForeColor = [Drawing.Color]::White
$hdr.TextAlign = "MiddleLeft"; $hdr.Font = New-Object Drawing.Font("Segoe UI", 12, [Drawing.FontStyle]::Bold)
$form.Controls.Add($hdr)

$tabs = New-Object Windows.Forms.TabControl
$tabs.Location = New-Object Drawing.Point(10, 54); $tabs.Size = New-Object Drawing.Size(566, 560)
$form.Controls.Add($tabs)
$tabSet = New-Object Windows.Forms.TabPage; $tabSet.Text = "Settings"
$tabSt  = New-Object Windows.Forms.TabPage; $tabSt.Text  = "Status && Logs"
$tabs.TabPages.AddRange(@($tabSet, $tabSt))

function Add-Field($parent, [string]$label, [int]$y, [bool]$secret = $false) {
    $l = New-Object Windows.Forms.Label; $l.Text = $label; $l.Location = New-Object Drawing.Point(16, ($y + 4)); $l.AutoSize = $true
    $t = New-Object Windows.Forms.TextBox; $t.Location = New-Object Drawing.Point(190, $y); $t.Width = 340
    if ($secret) { $t.UseSystemPasswordChar = $true }
    $parent.Controls.AddRange(@($l, $t))
    return $t
}
function Add-Group($parent, [string]$title, [int]$y, [int]$h) {
    $g = New-Object Windows.Forms.GroupBox; $g.Text = $title; $g.Font = $bold
    $g.Location = New-Object Drawing.Point(8, $y); $g.Size = New-Object Drawing.Size(540, $h)
    $parent.Controls.Add($g); return $g
}

$gM = Add-Group $tabSet "Biometric machine" 8 190
$tIp   = Add-Field $gM "Machine IP address"        26
$tPort = Add-Field $gM "Port"                      56
$tNum  = Add-Field $gM "Machine No."               86
$tPass = Add-Field $gM "Comm Key (password)"       116
$tName = Add-Field $gM "Machine name (in reports)" 146
foreach ($t in $tIp, $tPort, $tNum, $tPass, $tName) { $t.Font = $font }
$gM.Font = $bold; foreach ($c in $gM.Controls) { if ($c -isnot [Windows.Forms.GroupBox]) { $c.Font = $font } }

$gC = Add-Group $tabSet "Cloud (Satyakiran EMS)" 206 150
$tCloud  = Add-Field $gC "Cloud URL"   26
$tBranch = Add-Field $gC "Branch ID"   56
$tToken  = Add-Field $gC "Auth token"  86 $true
$tInt    = Add-Field $gC "Sync every (seconds)" 116
foreach ($c in $gC.Controls) { if ($c -isnot [Windows.Forms.GroupBox]) { $c.Font = $font } }

$out = New-Object Windows.Forms.TextBox
$out.Multiline = $true; $out.ReadOnly = $true; $out.Location = New-Object Drawing.Point(8, 364); $out.Size = New-Object Drawing.Size(540, 80)
$out.BackColor = [Drawing.Color]::White; $out.Text = "Fill in the details, press Test, then Save & Apply."
$tabSet.Controls.Add($out)

function New-Btn([string]$text, [int]$x, [int]$y, [int]$w, [bool]$primary = $false) {
    $b = New-Object Windows.Forms.Button; $b.Text = $text; $b.Location = New-Object Drawing.Point($x, $y); $b.Size = New-Object Drawing.Size($w, 32)
    $b.FlatStyle = "Flat"
    if ($primary) { $b.BackColor = $brand; $b.ForeColor = [Drawing.Color]::White; $b.Font = $bold }
    return $b
}
$bTestM = New-Btn "Test machine" 8 454 130
$bTestC = New-Btn "Test cloud" 144 454 130
$bSave  = New-Btn "Save && Apply" 380 454 168 $true
$bShow  = New-Btn "Show token" 280 454 94
$tabSet.Controls.AddRange(@($bTestM, $bTestC, $bShow, $bSave))

# --- Status tab
$lblState = New-Object Windows.Forms.Label; $lblState.Location = New-Object Drawing.Point(12, 12); $lblState.Size = New-Object Drawing.Size(530, 90); $lblState.Font = $font
$tabSt.Controls.Add($lblState)
$logBox = New-Object Windows.Forms.TextBox
$logBox.Multiline = $true; $logBox.ReadOnly = $true; $logBox.ScrollBars = "Vertical"; $logBox.WordWrap = $false
$logBox.Font = New-Object Drawing.Font("Consolas", 8.5); $logBox.Location = New-Object Drawing.Point(8, 108); $logBox.Size = New-Object Drawing.Size(540, 346)
$tabSt.Controls.Add($logBox)
$bRestart = New-Btn "Restart service" 8 464 130
$bUpdate  = New-Btn "Check for update" 144 464 140
$bRepair  = New-Btn "Repair auto-start" 290 464 140
$tabSt.Controls.AddRange(@($bRestart, $bUpdate, $bRepair))

function Load-Fields {
    $c = Read-Config
    $tIp.Text = $c.ip; $tPort.Text = $c.port; $tNum.Text = $c.num; $tPass.Text = $c.pass; $tName.Text = $c.name
    $tCloud.Text = $c.cloud; $tBranch.Text = $c.branch; $tToken.Text = $c.token; $tInt.Text = $c.interval
    $script:Loaded = $c
}
function Get-Fields {
    @{ ip = $tIp.Text.Trim(); port = $tPort.Text.Trim(); num = $tNum.Text.Trim(); pass = $tPass.Text.Trim(); name = $tName.Text.Trim()
       cloud = $tCloud.Text.Trim(); branch = $tBranch.Text.Trim(); token = $tToken.Text.Trim(); interval = $tInt.Text.Trim()
       update = $script:Loaded.update; options = $script:Loaded.options }
}
function Test-Fields($v) {
    if ($v.ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return "Machine IP must look like 192.168.0.124" }
    foreach ($n in "port", "num", "pass", "interval") { if ($v[$n] -notmatch '^\d+$') { return "$n must be a number" } }
    if ([int]$v.port -lt 1 -or [int]$v.port -gt 65535) { return "Port must be 1-65535" }
    if ([int]$v.interval -lt 5) { return "Sync interval must be at least 5 seconds" }
    if (-not $v.cloud.StartsWith("http")) { return "Cloud URL must start with https://" }
    if (-not $v.branch) { return "Branch ID is required" }
    if (-not $v.token) { return "Auth token is required" }
    return $null
}

$bShow.Add_Click({ $tToken.UseSystemPasswordChar = -not $tToken.UseSystemPasswordChar; $bShow.Text = $(if ($tToken.UseSystemPasswordChar) { "Show token" } else { "Hide token" }) })

function Run-Busy($btn, [scriptblock]$work) {
    $form.Cursor = "WaitCursor"; $btn.Enabled = $false; [Windows.Forms.Application]::DoEvents()
    try { & $work } catch { $out.Text = "Error: $($_.Exception.Message)" } finally { $form.Cursor = "Default"; $btn.Enabled = $true }
}

$bTestM.Add_Click({ Run-Busy $bTestM { $out.Text = "Testing machine..."; [Windows.Forms.Application]::DoEvents(); $out.Text = Test-Machine (Get-Fields) } })
$bTestC.Add_Click({ Run-Busy $bTestC { $out.Text = "Testing cloud..."; [Windows.Forms.Application]::DoEvents(); $out.Text = Test-Cloud (Get-Fields) } })
$bSave.Add_Click({
    Run-Busy $bSave {
        $v = Get-Fields
        $err = Test-Fields $v
        if ($err) { $out.Text = "Cannot save: $err"; return }
        Write-Config $v
        $script:Loaded = Read-Config
        if ((Get-ServiceState) -in "NOT INSTALLED", "Disabled") { Restart-Service2; $out.Text = "Saved. Background service installed and started (starts automatically with Windows)." }
        else { $out.Text = "Saved. The service picks up the new settings within $($v.interval) seconds - no restart needed." }
    }
})

$bRestart.Add_Click({ Run-Busy $bRestart { Restart-Service2; $lblState.Text = "Service restarted." } })
$bRepair.Add_Click({ Run-Busy $bRepair {
    & $Ps32 -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "register-task.ps1") -Action install -DataDir $DataDir | Out-Null
    [Windows.Forms.MessageBox]::Show("Auto-start registered. The bridge now starts with Windows, even before anyone logs in.", "Satyakiran Bridge") | Out-Null
} })
$bUpdate.Add_Click({
    Run-Busy $bUpdate {
        $u = $script:Loaded.update
        $url = $(if ($u -and $u.manifestUrl) { [string]$u.manifestUrl } else { $DefaultManifest })
        $hdrs = @{ "User-Agent" = "Satyakiran-Manager" }
        if ($u -and $u.token) { $hdrs["Authorization"] = "token $($u.token)" }
        try {
            $m = (Invoke-WebRequest -Uri $url -Headers $hdrs -UseBasicParsing -TimeoutSec 20).Content | ConvertFrom-Json
            if ([version]$m.version -gt [version](Get-Version)) {
                $r = [Windows.Forms.MessageBox]::Show("Version $($m.version) is available (installed: $(Get-Version)).`nInstall now? The service restarts for a few seconds.", "Update", "YesNo")
                if ($r -eq "Yes") { Restart-Service2; [Windows.Forms.MessageBox]::Show("Restarted. The update downloads and installs in about a minute; check Status & Logs.", "Update") | Out-Null }
            } else { [Windows.Forms.MessageBox]::Show("You are on the latest version ($(Get-Version)).", "Update") | Out-Null }
        } catch { [Windows.Forms.MessageBox]::Show("Could not check for updates:`n$($_.Exception.Message)", "Update") | Out-Null }
    }
})

function Refresh-Status {
    $lines = @("Service      : $(Get-ServiceState)   (auto-starts with Windows)", "Version      : $(Get-Version)")
    if (Test-Path $Heartbeat) {
        try {
            $hb = Get-Content $Heartbeat -Raw | ConvertFrom-Json
            $age = [int]((Get-Date) - [datetime]$hb.time).TotalSeconds
            $lines += "Agent        : $($hb.status), heartbeat $age s ago"
            $lines += "Punches sent : $($hb.totalSynced)   (last: $($hb.lastSyncAt))"
        } catch { $lines += "Agent        : heartbeat unreadable" }
    } else { $lines += "Agent        : not started yet" }
    $lblState.Text = $lines -join "`r`n"
    $f = Get-ChildItem $LogDir -Filter "agent-*.log" -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
    if ($f) {
        try {
            $fs = [IO.File]::Open($f.FullName, "Open", "Read", "ReadWrite")
            $sr = New-Object IO.StreamReader($fs); $txt = $sr.ReadToEnd(); $sr.Close()
            $logBox.Text = (($txt -split "`r?`n") | Select-Object -Last 60) -join "`r`n"
            $logBox.SelectionStart = $logBox.Text.Length; $logBox.ScrollToCaret()
        } catch {}
    }
}
$timer = New-Object Windows.Forms.Timer; $timer.Interval = 4000
$timer.Add_Tick({ if ($tabs.SelectedTab -eq $tabSt) { Refresh-Status } })
$timer.Start()
$tabs.Add_SelectedIndexChanged({ if ($tabs.SelectedTab -eq $tabSt) { Refresh-Status } })

Load-Fields
if (-not (Test-Path $ConfigFile) -or -not $script:Loaded.token -or -not $script:Loaded.branch) {
    $out.Text = "First-time setup: enter the machine IP, Branch ID and Auth token, press Test machine, then Save & Apply."
}
[void]$form.ShowDialog()
