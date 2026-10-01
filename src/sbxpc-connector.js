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
          if (-not ([System.Management.Automation.PSTypeName]'SbxBridge').Type) {
            Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;

public class SbxBridge {
    public static string FetchLogsJson(int machineNum, string ip, int port, int password, string deviceName) {
        Type comType = Type.GetTypeFromProgID("SBXPC.SBXPCCtrl.1");
        if (comType == null) throw new Exception("COM class SBXPC.SBXPCCtrl.1 is not registered in Windows.");
        
        dynamic sbx = Activator.CreateInstance(comType);
        try { sbx.DotNET(); } catch {}

        bool ok = false;
        try {
            ok = (bool)sbx.ConnectTcpip(machineNum, ip, port, password);
        } catch (Exception ex) {
            throw new Exception("ConnectTcpip failed: " + ex.Message);
        }

        if (!ok) {
            throw new Exception("Cannot connect to biometric machine at " + ip + ":" + port + " (Device offline or busy)");
        }

        List<string> items = new List<string>();
        try {
            bool hasLogs = (bool)sbx.ReadGeneralLogData(machineNum);
            if (hasLogs) {
                int enrollNo = 0;
                int verifyMode = 0;
                int inOutMode = 0;
                int y = 0, m = 0, d = 0, h = 0, min = 0, s = 0;

                while ((bool)sbx.GetGeneralLogData(machineNum, ref enrollNo, ref verifyMode, ref inOutMode, ref y, ref m, ref d, ref h, ref min, ref s)) {
                    string dt = string.Format("{0:D4}-{1:D2}-{2:D2} {3:D2}:{4:D2}:{5:D2}", y, m, d, h, min, s);
                    string dir = inOutMode == 1 ? "IN" : (inOutMode == 2 ? "OUT" : "AUTO");
                    string vm = verifyMode == 1 ? "Fingerprint" : (verifyMode == 2 ? "Card" : "Face");
                    
                    items.Add("{\\"employeeCode\\":\\"" + enrollNo + "\\",\\"logDateTime\\":\\"" + dt + "\\",\\"direction\\":\\"" + dir + "\\",\\"verificationMode\\":\\"" + vm + "\\",\\"deviceSerial\\":\\"" + ip + "\\",\\"deviceName\\":\\"" + deviceName + "\\"}");
                }
            }
        } finally {
            try { sbx.Disconnect(); } catch { try { sbx.CloseCommPort(); } catch {} }
        }

        return "[" + string.Join(",", items.ToArray()) + "]";
    }
}
"@ -Language CSharp
          }

          $json = [SbxBridge]::FetchLogsJson(${this.machineNumber}, "${this.ip}", ${this.port}, ${this.password}, "${this.deviceName}")
          Write-Output $json
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
