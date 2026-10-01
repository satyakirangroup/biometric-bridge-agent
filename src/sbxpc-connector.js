const { spawn } = require("child_process");
const net = require("net");
const os = require("os");

class SbxpcConnector {
  constructor(config) {
    this.ip = config.ip || "192.168.1.224";
    this.port = Number(config.port || 5005);
    this.machineNumber = Number(config.machineNumber || 1);
    this.password = Number(config.password || 0);
    this.deviceName = config.deviceName || "Biometric Device";
  }

  /**
   * Tests raw TCP reachability of the device.
   */
  async testTcpConnection(timeoutMs = 4000) {
    return new Promise((resolve) => {
      const socket = new net.Socket();
      let isResolved = false;

      socket.setTimeout(timeoutMs);

      socket.connect(this.port, this.ip, () => {
        if (!isResolved) {
          isResolved = true;
          socket.destroy();
          resolve({ connected: true, message: `Successfully reached ${this.ip}:${this.port}` });
        }
      });

      socket.on("error", (err) => {
        if (!isResolved) {
          isResolved = true;
          socket.destroy();
          resolve({ connected: false, message: `TCP Error: ${err.message}` });
        }
      });

      socket.on("timeout", () => {
        if (!isResolved) {
          isResolved = true;
          socket.destroy();
          resolve({ connected: false, message: `TCP Timeout after ${timeoutMs}ms` });
        }
      });
    });
  }

  /**
   * Reads attendance logs from the machine.
   * On Windows with SBXPC registered, it invokes the native COM bridge via PowerShell.
   * On non-Windows/dev, it checks TCP socket status.
   */
  async fetchLogs() {
    if (os.platform() === "win32") {
      return this._fetchLogsViaWindowsCOM();
    } else {
      // Diagnostic/TCP check for non-windows environments
      const tcp = await this.testTcpConnection(2000);
      if (!tcp.connected) {
        throw new Error(`Device unreachable at ${this.ip}:${this.port} (${tcp.message})`);
      }
      return [];
    }
  }

  /**
   * Windows COM Automation via SBXPC.ocx / SBPCOMM.dll
   */
  async _fetchLogsViaWindowsCOM() {
    return new Promise((resolve, reject) => {
      const psScript = `
        $ErrorActionPreference = 'Stop'
        try {
          $sbx = New-Object -ComObject "SBXPC.SBXPCCtrl.1"
          $conn = $sbx.OpenNetwork(${this.machineNumber}, "${this.ip}", ${this.port}, ${this.password})
          if (-not $conn) {
            Write-Output "ERROR: Failed to open network connection to ${this.ip}:${this.port}"
            exit 1
          }

          $hasLogs = $sbx.ReadGeneralLogData(${this.machineNumber})
          $logs = @()

          if ($hasLogs) {
            $enrollNo = 0
            $verifyMode = 0
            $inOutMode = 0
            $year = 0
            $month = 0
            $day = 0
            $hour = 0
            $minute = 0
            $second = 0

            while ($sbx.GetGeneralLogData(${this.machineNumber}, [ref]$enrollNo, [ref]$verifyMode, [ref]$inOutMode, [ref]$year, [ref]$month, [ref]$day, [ref]$hour, [ref]$minute, [ref]$second)) {
              $monthStr = "{0:D2}" -f $month
              $dayStr = "{0:D2}" -f $day
              $hourStr = "{0:D2}" -f $hour
              $minStr = "{0:D2}" -f $minute
              $secStr = "{0:D2}" -f $second
              $dtStr = "$year-$monthStr-$dayStr " + $hourStr + ":" + $minStr + ":" + $secStr
              
              $dir = "AUTO"
              if ($inOutMode -eq 1) { $dir = "IN" }
              elseif ($inOutMode -eq 2) { $dir = "OUT" }

              $vMode = "Face"
              if ($verifyMode -eq 1) { $vMode = "Fingerprint" }
              elseif ($verifyMode -eq 2) { $vMode = "Card" }

              $logs += [PSCustomObject]@{
                employeeCode = $enrollNo.ToString()
                logDateTime = $dtStr
                direction = $dir
                verificationMode = $vMode
                deviceSerial = "${this.ip}"
                deviceName = "${this.deviceName}"
              }
            }
          }

          $sbx.CloseCommPort()
          Write-Output ($logs | ConvertTo-Json -Compress)
        } catch {
          Write-Output "ERROR: $($_.Exception.Message)"
          exit 1
        }
      `;

      const fs = require("fs");
      const path = require("path");
      const sysRoot = process.env.SystemRoot || process.env.windir || "C:\\Windows";
      const x86Ps = path.join(sysRoot, "SysWOW64", "WindowsPowerShell", "v1.0", "powershell.exe");
      const psExecutable = fs.existsSync(x86Ps) ? x86Ps : "powershell.exe";

      const ps = spawn(psExecutable, ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", psScript]);
      let stdout = "";
      let stderr = "";

      ps.stdout.on("data", (d) => (stdout += d.toString()));
      ps.stderr.on("data", (d) => (stderr += d.toString()));

      ps.on("close", (code) => {
        const out = stdout.trim();
        if (code !== 0 || out.startsWith("ERROR:")) {
          return reject(new Error(out || stderr || `PowerShell exited with code ${code}`));
        }

        if (!out || out === "") {
          return resolve([]);
        }

        try {
          const parsed = JSON.parse(out);
          const list = Array.isArray(parsed) ? parsed : [parsed];
          resolve(list);
        } catch (e) {
          resolve([]);
        }
      });
    });
  }
}

module.exports = SbxpcConnector;
