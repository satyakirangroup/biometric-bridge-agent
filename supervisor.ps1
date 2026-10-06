# Satyakiran Bridge Supervisor - runs as a SYSTEM scheduled task at boot.
#  - starts app\agent.ps1 and restarts it if it exits or hangs (watchdog)
#  - checks for updates, verifies them, swaps app\ and restarts the agent
#  - rolls back automatically if the new version dies right after an update
# This file is deliberately small and stable: it is only changed by re-running the installer.
# Keep it ASCII-only (PowerShell 5.1 misreads BOM-less UTF-8).

param(
    [string]$DataDir = (Join-Path $env:ProgramData "SatyakiranBridge")
)

$ErrorActionPreference = "Stop"
$Root       = $PSScriptRoot
$AppDir     = Join-Path $Root "app"
$BakDir     = Join-Path $Root "app.bak"
$Staging    = Join-Path $DataDir "staging"
$LogDir     = Join-Path $DataDir "logs"
$ConfigFile = Join-Path $DataDir "config.json"
$Heartbeat  = Join-Path $DataDir "heartbeat.json"
$VerifyFlag = Join-Path $DataDir "verify-update.json"   # exists while a fresh update is on probation
$BadFile    = Join-Path $DataDir "bad-version.txt"
$PubKeyFile = Join-Path $Root "update-pubkey.xml"
$Ps32       = Join-Path $env:SystemRoot "SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
if (-not (Test-Path $Ps32)) { $Ps32 = "powershell.exe" }

$DefaultManifest = "https://github.com/satyakirangroup/biometric-bridge-agent/releases/latest/download/version.json"
$ProbationSeconds = 90
$WatchdogMinutes  = 10

New-Item -ItemType Directory -Force -Path $LogDir, $Staging | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Log([string]$Level, [string]$Msg) {
    $line = "{0} [{1}] [supervisor] {2}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"), $Level, $Msg
    try { Add-Content -Path (Join-Path $LogDir ("agent-{0}.log" -f (Get-Date).ToString("yyyyMMdd"))) -Value $line -Encoding UTF8 } catch {}
    Write-Host $line
}

# Only one supervisor at a time.
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, "Global\SatyakiranBridgeSupervisor", [ref]$createdNew)
if (-not $createdNew) { Write-Log "WARN" "Another supervisor is already running. Exiting."; exit 0 }

function Get-AppVersion([string]$dir) {
    try { return [version]((Get-Content (Join-Path $dir "VERSION") -Raw).Trim()) } catch { return [version]"0.0.0" }
}

function Get-UpdateConfig {
    $u = @{ enabled = $true; manifestUrl = $DefaultManifest; checkHours = 6; token = $null }
    try {
        $c = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        if ($c.update) {
            if ($null -ne $c.update.enabled)  { $u.enabled = [bool]$c.update.enabled }
            if ($c.update.manifestUrl)        { $u.manifestUrl = [string]$c.update.manifestUrl }
            if ($c.update.checkHours)         { $u.checkHours = [double]$c.update.checkHours }
            if ($c.update.token)              { $u.token = [string]$c.update.token }
        }
    } catch {}
    return $u
}

function Start-Agent {
    $argLine = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $AppDir 'agent.ps1')`" -DataDir `"$DataDir`""
    return Start-Process -FilePath $Ps32 -ArgumentList $argLine -WindowStyle Hidden -PassThru
}

function Stop-Agent($proc) {
    if ($proc -and -not $proc.HasExited) {
        try { & taskkill.exe /PID $proc.Id /T /F | Out-Null } catch { try { $proc.Kill() } catch {} }
    }
}

# Returns the new version string if an update was downloaded, verified and staged; otherwise $null.
function Prepare-Update($cfg) {
    $headers = @{ "User-Agent" = "Satyakiran-Supervisor" }
    if ($cfg.token) { $headers["Authorization"] = "token $($cfg.token)"; $headers["Accept"] = "application/octet-stream" }

    try {
        $manifestTxt = (Invoke-WebRequest -Uri $cfg.manifestUrl -Headers $headers -UseBasicParsing -TimeoutSec 30).Content
        if ($manifestTxt -is [byte[]]) { $manifestTxt = [Text.Encoding]::UTF8.GetString($manifestTxt) }
        $m = $manifestTxt | ConvertFrom-Json
    } catch {
        Write-Log "WARN" "Update check failed (will retry later): $($_.Exception.Message)"
        return $null
    }

    $current = Get-AppVersion $AppDir
    $remote = [version]$m.version
    if ($remote -le $current) { return $null }
    if ((Test-Path $BadFile) -and ((Get-Content $BadFile -Raw).Trim() -eq [string]$m.version)) {
        Write-Log "WARN" "Version $($m.version) previously failed on this PC; skipping."
        return $null
    }

    Write-Log "INFO" "Update available: $current -> $remote. Downloading..."
    $zip = Join-Path $Staging "update.zip"
    $new = Join-Path $Staging "app-new"
    try {
        Remove-Item $zip, $new -Recurse -Force -ErrorAction SilentlyContinue
        Invoke-WebRequest -Uri $m.url -Headers $headers -OutFile $zip -UseBasicParsing -TimeoutSec 300

        $hashBytes = [Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes($zip))
        $hashHex = ([BitConverter]::ToString($hashBytes) -replace '-', '').ToLowerInvariant()
        if ($hashHex -ne ([string]$m.sha256).ToLowerInvariant()) { throw "SHA256 mismatch (expected $($m.sha256), got $hashHex)" }

        if (Test-Path $PubKeyFile) {
            if (-not $m.signature) { throw "Manifest is not signed" }
            $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
            $rsa.FromXmlString((Get-Content $PubKeyFile -Raw))
            $ok = $rsa.VerifyHash($hashBytes, "SHA256", [Convert]::FromBase64String([string]$m.signature))
            if (-not $ok) { throw "Signature verification FAILED" }
        } else {
            Write-Log "WARN" "No update-pubkey.xml installed; update is verified by SHA256 only."
        }

        Expand-Archive -Path $zip -DestinationPath $new -Force
        if (-not (Test-Path (Join-Path $new "agent.ps1"))) { throw "Update package has no agent.ps1" }
        if ((Get-AppVersion $new) -ne $remote) { throw "Package VERSION does not match manifest" }
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        return [string]$m.version
    } catch {
        Write-Log "ERROR" "Update rejected: $($_.Exception.Message)"
        Remove-Item $zip, $new -Recurse -Force -ErrorAction SilentlyContinue
        return $null
    }
}

function Apply-Update([string]$newVersion) {
    $new = Join-Path $Staging "app-new"
    $old = Get-AppVersion $AppDir
    Remove-Item $BakDir -Recurse -Force -ErrorAction SilentlyContinue
    Move-Item -Path $AppDir -Destination $BakDir -Force
    Move-Item -Path $new -Destination $AppDir -Force
    @{ from = [string]$old; to = $newVersion; at = (Get-Date).ToString("o") } | ConvertTo-Json | Set-Content $VerifyFlag -Encoding UTF8
    Write-Log "INFO" "Updated $old -> $newVersion. Restarting agent (on probation for ${ProbationSeconds}s)."
}

function Rollback-Update {
    $info = Get-Content $VerifyFlag -Raw | ConvertFrom-Json
    Write-Log "ERROR" "New version $($info.to) failed within ${ProbationSeconds}s. Rolling back to $($info.from)."
    Set-Content -Path $BadFile -Value ([string]$info.to) -Encoding ASCII
    if (Test-Path $BakDir) {
        Remove-Item $AppDir -Recurse -Force -ErrorAction SilentlyContinue
        Move-Item -Path $BakDir -Destination $AppDir -Force
    }
    Remove-Item $VerifyFlag -Force -ErrorAction SilentlyContinue
}

function Test-HeartbeatStale([datetime]$since) {
    try {
        $hb = Get-Content $Heartbeat -Raw | ConvertFrom-Json
        $t = [datetime]$hb.time
        if ($t -lt $since) { $t = $since }
        return ((Get-Date) - $t).TotalMinutes -gt $WatchdogMinutes
    } catch { return ((Get-Date) - $since).TotalMinutes -gt $WatchdogMinutes }
}

# --- Main ------------------------------------------------------------------
Write-Log "INFO" "Supervisor started. Agent version $(Get-AppVersion $AppDir)"
Remove-Item (Join-Path $Staging "*") -Recurse -Force -ErrorAction SilentlyContinue
$lastCheck = [datetime]::MinValue

while ($true) {
    $proc = Start-Agent
    $startedAt = Get-Date
    $updateVersion = $null
    Write-Log "INFO" "Agent started (pid $($proc.Id))"

    while (-not $proc.HasExited) {
        Start-Sleep -Seconds 15

        if ((Test-Path $VerifyFlag) -and (((Get-Date) - $startedAt).TotalSeconds -ge $ProbationSeconds)) {
            Remove-Item $VerifyFlag -Force -ErrorAction SilentlyContinue
            Remove-Item $BadFile -Force -ErrorAction SilentlyContinue
            Write-Log "INFO" "Update confirmed healthy."
        }

        if (Test-HeartbeatStale $startedAt) {
            Write-Log "WARN" "Agent heartbeat stale for over $WatchdogMinutes min (hung?). Restarting it."
            break
        }

        $cfg = Get-UpdateConfig
        if ($cfg.enabled -and (((Get-Date) - $lastCheck).TotalHours -ge $cfg.checkHours)) {
            $lastCheck = Get-Date
            $updateVersion = Prepare-Update $cfg
            if ($updateVersion) { break }
        }
    }

    $uptime = ((Get-Date) - $startedAt).TotalSeconds
    Stop-Agent $proc

    try {
        if ($updateVersion) {
            Apply-Update $updateVersion
        } elseif ((Test-Path $VerifyFlag) -and $uptime -lt $ProbationSeconds) {
            Rollback-Update
        } elseif ($proc.HasExited) {
            Write-Log "WARN" "Agent exited (code $($proc.ExitCode)) after $([int]$uptime)s. Restarting in 10s."
        }
    } catch {
        Write-Log "ERROR" "Update/rollback step failed: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds 10
}
