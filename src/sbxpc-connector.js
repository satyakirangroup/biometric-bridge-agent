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
      return this._fetchLogsViaVbs();
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
   * Native 32-bit VBScript Automation for SBXPC.ocx / SBPCOMM.dll
   * VBScript natively passes COM ByRef Variant pointers without RCW/marshaling exceptions.
   */
  async _fetchLogsViaVbs() {
    return new Promise((resolve, reject) => {
      const vbsCode = `
On Error Resume Next
Set sbx = CreateObject("SBXPC.SBXPCCtrl.1")
If Err.Number <> 0 Then
    WScript.Echo "ERROR: Cannot create COM object SBXPC.SBXPCCtrl.1 (" & Err.Description & ")"
    WScript.Quit 1
End If

On Error Goto 0
sbx.DotNET

connected = sbx.ConnectTcpip(${this.machineNumber}, "${this.ip}", ${this.port}, ${this.password})
If Not connected Then
    WScript.Echo "ERROR: Cannot connect to biometric device at ${this.ip}:${this.port} (Device offline or busy)"
    WScript.Quit 1
End If

hasLogs = sbx.ReadGeneralLogData(${this.machineNumber})
Dim results
results = ""

If hasLogs Then
    Dim enrollNo, verifyMode, inOutMode, y, m, d, h, mi, s
    enrollNo = 0
    verifyMode = 0
    inOutMode = 0
    y = 0
    m = 0
    d = 0
    h = 0
    mi = 0
    s = 0

    Do While sbx.GetGeneralLogData(${this.machineNumber}, enrollNo, verifyMode, inOutMode, y, m, d, h, mi, s)
        Dim dtStr, dir, vMode
        dtStr = Right("0000" & y, 4) & "-" & Right("00" & m, 2) & "-" & Right("00" & d, 2) & " " & Right("00" & h, 2) & ":" & Right("00" & mi, 2) & ":" & Right("00" & s, 2)
        
        dir = "AUTO"
        If inOutMode = 1 Then dir = "IN"
        If inOutMode = 2 Then dir = "OUT"

        vMode = "Face"
        If verifyMode = 1 Then vMode = "Fingerprint"
        If verifyMode = 2 Then vMode = "Card"

        Dim item
        item = "{" & Chr(34) & "employeeCode" & Chr(34) & ":" & Chr(34) & enrollNo & Chr(34) & "," & _
               Chr(34) & "logDateTime" & Chr(34) & ":" & Chr(34) & dtStr & Chr(34) & "," & _
               Chr(34) & "direction" & Chr(34) & ":" & Chr(34) & dir & Chr(34) & "," & _
               Chr(34) & "verificationMode" & Chr(34) & ":" & Chr(34) & vMode & Chr(34) & "," & _
               Chr(34) & "deviceSerial" & Chr(34) & ":" & Chr(34) & "${this.ip}" & Chr(34) & "," & _
               Chr(34) & "deviceName" & Chr(34) & ":" & Chr(34) & "${this.deviceName}" & Chr(34) & "}"

        If results = "" Then
            results = item
        Else
            results = results & "," & item
        End If
    Loop
End If

On Error Resume Next
sbx.Disconnect
sbx.CloseCommPort
On Error Goto 0

WScript.Echo "[" & results & "]"
`;

      const tmpDir = os.tmpdir();
      const tmpVbsPath = path.join(tmpDir, `sbxpc_fetch_${Date.now()}.vbs`);
      fs.writeFileSync(tmpVbsPath, vbsCode, "utf-8");

      const sysRoot = process.env.SystemRoot || process.env.windir || "C:\\Windows";
      const x86Cscript = path.join(sysRoot, "SysWOW64", "cscript.exe");
      const cscriptExe = fs.existsSync(x86Cscript) ? x86Cscript : "cscript.exe";

      const proc = spawn(cscriptExe, ["//Nologo", tmpVbsPath]);
      let stdout = "";
      let stderr = "";

      proc.stdout.on("data", (d) => (stdout += d.toString()));
      proc.stderr.on("data", (d) => (stderr += d.toString()));

      proc.on("close", (code) => {
        try { fs.unlinkSync(tmpVbsPath); } catch {}

        const out = stdout.trim();
        if (code !== 0 || out.startsWith("ERROR:")) {
          return reject(new Error(out || stderr || `cscript exited with code ${code}`));
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
