const { spawn } = require("child_process");
const net = require("net");
const os = require("os");
const fs = require("fs");
const path = require("path");

class SbxpcConnector {
  constructor(config) {
    this.ip = config.ip || "192.168.1.14";
    this.port = Number(config.port || 5005);
    this.machineNumber = Number(config.machineNumber || 1);
    this.password = Number(config.password || 0);
    this.deviceName = config.deviceName || "Sonipat Plant Biometric Machine";
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
   * On Windows, it invokes the native 32-bit SBXPCDLL bridge via SysWOW64 PowerShell.
   */
  async fetchLogs() {
    if (os.platform() === "win32") {
      return this._fetchLogsViaNativeBridge();
    } else {
      const tcp = await this.testTcpConnection(2000);
      if (!tcp.connected) {
        throw new Error(`Device unreachable at ${this.ip}:${this.port} (${tcp.message})`);
      }
      return [];
    }
  }

  /**
   * Native 32-bit SBXPCDLL Automation via SysWOW64 PowerShell.
   * Directly interfaces with vendor C# wrapper and native SBXPCDLL.dll / SBPCCOMM.dll.
   */
  async _fetchLogsViaNativeBridge() {
    return new Promise((resolve, reject) => {
      const sysRoot = process.env.SystemRoot || process.env.windir || "C:\\Windows";
      const x86Ps = path.join(sysRoot, "SysWOW64", "WindowsPowerShell", "v1.0", "powershell.exe");
      const psExe = fs.existsSync(x86Ps) ? x86Ps : "powershell.exe";
      const bridgeScript = path.resolve(__dirname, "native/sbxpc-bridge.ps1");

      const args = [
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", bridgeScript,
        "fetch-logs",
        String(this.machineNumber),
        this.ip,
        String(this.port),
        String(this.password),
        this.deviceName
      ];

      const proc = spawn(psExe, args);
      let stdout = "";
      let stderr = "";

      const timeoutTimer = setTimeout(() => {
        try { proc.kill(); } catch {}
        reject(new Error("Timeout reading biometric device (60s exceeded)"));
      }, 60000);

      proc.stdout.on("data", (d) => (stdout += d.toString()));
      proc.stderr.on("data", (d) => (stderr += d.toString()));

      proc.on("close", (code) => {
        clearTimeout(timeoutTimer);

        const out = stdout.trim();
        const err = stderr.trim();

        if (code !== 0 || out.startsWith("ERROR:") || err.includes("ERROR:")) {
          const errMsg = err || out || `Process exited with code ${code}`;
          return reject(new Error(errMsg));
        }

        if (!out || out === "" || out === "[]") {
          return resolve([]);
        }

        try {
          // Find the JSON array boundary in stdout if any prefix exists
          const jsonStart = out.indexOf("[");
          const jsonEnd = out.lastIndexOf("]");
          if (jsonStart === -1 || jsonEnd === -1) {
            return resolve([]);
          }
          const cleanJson = out.substring(jsonStart, jsonEnd + 1);
          const parsed = JSON.parse(cleanJson);
          const list = Array.isArray(parsed) ? parsed : [parsed];
          resolve(list);
        } catch (e) {
          reject(new Error(`Failed to parse device output: ${e.message}\nOutput: ${out.substring(0, 200)}...`));
        }
      });
    });
  }

  /**
   * Queries hardware device information and stored inventory.
   */
  async inspectMachine() {
    return new Promise((resolve, reject) => {
      const sysRoot = process.env.SystemRoot || process.env.windir || "C:\\Windows";
      const x86Ps = path.join(sysRoot, "SysWOW64", "WindowsPowerShell", "v1.0", "powershell.exe");
      const psExe = fs.existsSync(x86Ps) ? x86Ps : "powershell.exe";
      const bridgeScript = path.resolve(__dirname, "native/sbxpc-bridge.ps1");

      const args = [
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", bridgeScript,
        "inspect",
        String(this.machineNumber),
        this.ip,
        String(this.port),
        String(this.password),
        this.deviceName
      ];

      const proc = spawn(psExe, args);
      let stdout = "";
      let stderr = "";

      const timeoutTimer = setTimeout(() => {
        try { proc.kill(); } catch {}
        reject(new Error("Timeout inspecting biometric device (60s exceeded)"));
      }, 60000);

      proc.stdout.on("data", (d) => (stdout += d.toString()));
      proc.stderr.on("data", (d) => (stderr += d.toString()));

      proc.on("close", (code) => {
        clearTimeout(timeoutTimer);

        const out = stdout.trim();
        const err = stderr.trim();

        if (code !== 0 || out.startsWith("ERROR:") || err.includes("ERROR:")) {
          return reject(new Error(err || out || `Process exited with code ${code}`));
        }

        const startIdx = out.indexOf("JSON_START");
        const endIdx = out.indexOf("JSON_END");

        if (startIdx === -1 || endIdx === -1) {
          return reject(new Error(`Invalid inspect output format: ${out.substring(0, 200)}`));
        }

        const jsonStr = out.substring(startIdx + 10, endIdx).trim();
        try {
          const data = JSON.parse(jsonStr);
          resolve(data);
        } catch (e) {
          reject(new Error(`Failed to parse inspection JSON: ${e.message}`));
        }
      });
    });
  }

  /**
   * Helper to execute native PowerShell bridge actions.
   */
  async _runBridge(action, extraArgs = [], timeoutMs = 60000) {
    return new Promise((resolve, reject) => {
      const sysRoot = process.env.SystemRoot || process.env.windir || "C:\\Windows";
      const x86Ps = path.join(sysRoot, "SysWOW64", "WindowsPowerShell", "v1.0", "powershell.exe");
      const psExe = fs.existsSync(x86Ps) ? x86Ps : "powershell.exe";
      const bridgeScript = path.resolve(__dirname, "native/sbxpc-bridge.ps1");

      const args = [
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", bridgeScript,
        action,
        String(this.machineNumber),
        this.ip,
        String(this.port),
        String(this.password),
        this.deviceName,
        ...extraArgs.map(String)
      ];

      const proc = spawn(psExe, args);
      let stdout = "";
      let stderr = "";

      const timeoutTimer = setTimeout(() => {
        try { proc.kill(); } catch {}
        reject(new Error(`Timeout executing '${action}' on biometric device (${timeoutMs / 1000}s exceeded)`));
      }, timeoutMs);

      proc.stdout.on("data", (d) => (stdout += d.toString()));
      proc.stderr.on("data", (d) => (stderr += d.toString()));

      proc.on("close", (code) => {
        clearTimeout(timeoutTimer);

        const out = stdout.trim();
        const err = stderr.trim();

        if (code !== 0 || out.startsWith("ERROR:") || err.includes("ERROR:")) {
          return reject(new Error(err || out || `Bridge process exited with code ${code}`));
        }

        try {
          const parsed = JSON.parse(out);
          resolve(parsed);
        } catch {
          resolve({ raw: out });
        }
      });
    });
  }

  /**
   * Normalizes an enroll number or employee code (e.g. "EMP-0001", "EMP-00000043", "43", 1)
   * into a positive integer required by biometric device firmware.
   */
  _normalizeEnrollNumber(val) {
    if (val === undefined || val === null) {
      throw new Error("Enroll number is required");
    }
    if (typeof val === "number" && !isNaN(val) && val > 0) {
      return Math.floor(val);
    }
    const str = String(val).trim();
    if (/^\d+$/.test(str)) {
      const num = parseInt(str, 10);
      if (!isNaN(num) && num > 0) return num;
    }
    const digits = str.replace(/\D/g, "");
    if (digits.length > 0) {
      const num = parseInt(digits, 10);
      if (!isNaN(num) && num > 0) return num;
    }
    throw new Error(`Cannot parse valid numeric biometric EnrollNumber from '${val}'`);
  }

  /**
   * [CREATE / UPDATE] Sets user's name, privilege and enables user on device.
   */
  async setUser(enrollNumber, userName, privilege = 0, enabled = 1) {
    const num = this._normalizeEnrollNumber(enrollNumber);
    const safeName = String(userName || "").trim();
    return this._runBridge("set-user", [num, safeName, Number(privilege || 0), enabled ? 1 : 0]);
  }

  /**
   * [READ] Reads a single employee's details directly from device.
   */
  async getUser(enrollNumber) {
    const num = this._normalizeEnrollNumber(enrollNumber);
    return this._runBridge("get-user", [num]);
  }

  /**
   * [UPDATE] Updates an existing user's attributes.
   */
  async updateUser(enrollNumber, updates = {}) {
    const num = this._normalizeEnrollNumber(enrollNumber);
    const current = await this.getUser(num).catch(() => ({}));
    const name = updates.name !== undefined ? updates.name : (current.employeeName || "");
    const priv = updates.privilege !== undefined ? updates.privilege : (current.privilege || 0);
    const enabled = updates.enabled !== undefined ? (updates.enabled ? 1 : 0) : 1;
    return this.setUser(num, name, priv, enabled);
  }

  /**
   * [DELETE] Deletes a user and their biometric/card/password data from physical device.
   */
  async deleteUser(enrollNumber) {
    const num = this._normalizeEnrollNumber(enrollNumber);
    return this._runBridge("delete-user", [num]);
  }

  /**
   * [TOGGLE] Toggles enable/disable state for an employee on hardware.
   */
  async enableUser(enrollNumber, flag = 1) {
    const num = this._normalizeEnrollNumber(enrollNumber);
    const current = await this.getUser(num).catch(() => ({}));
    const name = current.employeeName || "";
    const priv = current.privilege || 0;
    return this.setUser(num, name, priv, flag ? 1 : 0);
  }

  /**
   * Synchronizes hardware clock with local PC system time.
   */
  async syncTime() {
    return this._runBridge("sync-time");
  }

  /**
   * [READ ALL] Reads all enrolled users and their names directly from hardware memory.
   */
  async getUsers() {
    const res = await this._runBridge("get-users", [], 90000);
    return Array.isArray(res) ? res : [];
  }

  /**
   * Empties attendance logs stored on the machine.
   */
  async clearLogs() {
    return this._runBridge("clear-logs");
  }
}

module.exports = SbxpcConnector;
