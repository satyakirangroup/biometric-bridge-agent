const { spawn } = require("child_process");
const net = require("net");
const os = require("os");
const fs = require("fs");
const path = require("path");

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

sbx.DotNET

connected = sbx.ConnectTcpip(${this.machineNumber}, "${this.ip}", ${this.port}, ${this.password})
If Not connected Then
    WScript.Echo "ERROR: Cannot connect to biometric device at ${this.ip}:${this.port} (Device offline or busy)"
    WScript.Quit 1
End If

' Disable device input during transactional log reading (Mandatory per SDK manual)
sbx.EnableDevice ${this.machineNumber}, False

' Read logs from device memory into PC buffer (ReadAllGLogData ignores read marks)
Dim hasLogs
hasLogs = sbx.ReadAllGLogData(${this.machineNumber})
If Not hasLogs Then
    ' Fallback to ReadGeneralLogData if ReadAllGLogData returned false
    hasLogs = sbx.ReadGeneralLogData(${this.machineNumber})
End If

Dim results
results = ""

If hasLogs Then
    Dim tMach, enrollNo, eMach, verifyMode, y, m, d, h, mi, s
    tMach = CLng(0)
    enrollNo = CLng(0)
    eMach = CLng(0)
    verifyMode = CLng(0)
    y = CLng(0)
    m = CLng(0)
    d = CLng(0)
    h = CLng(0)
    mi = CLng(0)
    s = CLng(0)

    ' Try GetAllGLogData first (paired with ReadAllGLogData)
    Dim hasRecord
    hasRecord = sbx.GetAllGLogData(${this.machineNumber}, tMach, enrollNo, eMach, verifyMode, y, m, d, h, mi, s)
    
    If hasRecord Then
        Do
            Dim dtStr, dir, vMode
            dtStr = Right("0000" & y, 4) & "-" & Right("00" & m, 2) & "-" & Right("00" & d, 2) & " " & Right("00" & h, 2) & ":" & Right("00" & mi, 2) & ":" & Right("00" & s, 2)
            
            dir = "AUTO"
            vMode = "Face"
            If verifyMode = 1 Then vMode = "Fingerprint"
            If verifyMode = 2 Then vMode = "Card"
            If verifyMode = 15 Then vMode = "Face"

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
        Loop While sbx.GetAllGLogData(${this.machineNumber}, tMach, enrollNo, eMach, verifyMode, y, m, d, h, mi, s)
    Else
        ' Fallback loop using GetGeneralLogData (exact 11 parameters)
        While sbx.GetGeneralLogData(${this.machineNumber}, tMach, enrollNo, eMach, verifyMode, y, m, d, h, mi, s)
            Dim dtStr2, dir2, vMode2
            dtStr2 = Right("0000" & y, 4) & "-" & Right("00" & m, 2) & "-" & Right("00" & d, 2) & " " & Right("00" & h, 2) & ":" & Right("00" & mi, 2) & ":" & Right("00" & s, 2)
            
            dir2 = "AUTO"
            vMode2 = "Face"
            If verifyMode = 1 Then vMode2 = "Fingerprint"
            If verifyMode = 2 Then vMode2 = "Card"
            If verifyMode = 15 Then vMode2 = "Face"

            Dim item2
            item2 = "{" & Chr(34) & "employeeCode" & Chr(34) & ":" & Chr(34) & enrollNo & Chr(34) & "," & _
                    Chr(34) & "logDateTime" & Chr(34) & ":" & Chr(34) & dtStr2 & Chr(34) & "," & _
                    Chr(34) & "direction" & Chr(34) & ":" & Chr(34) & dir2 & Chr(34) & "," & _
                    Chr(34) & "verificationMode" & Chr(34) & ":" & Chr(34) & vMode2 & Chr(34) & "," & _
                    Chr(34) & "deviceSerial" & Chr(34) & ":" & Chr(34) & "${this.ip}" & Chr(34) & "," & _
                    Chr(34) & "deviceName" & Chr(34) & ":" & Chr(34) & "${this.deviceName}" & Chr(34) & "}"

            If results = "" Then
                results = item2
            Else
                results = results & "," & item2
            End If
        Wend
    End If
End If

' Re-enable device input
On Error Resume Next
sbx.EnableDevice ${this.machineNumber}, True
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

      const timeoutTimer = setTimeout(() => {
        try { proc.kill(); } catch {}
        try { fs.unlinkSync(tmpVbsPath); } catch {}
        reject(new Error("Timeout reading biometric device (20s exceeded)"));
      }, 20000);

      proc.stdout.on("data", (d) => (stdout += d.toString()));
      proc.stderr.on("data", (d) => (stderr += d.toString()));

      proc.on("close", (code) => {
        clearTimeout(timeoutTimer);
        try { fs.unlinkSync(tmpVbsPath); } catch {}

        const out = stdout.trim();
        if (code !== 0 || out.startsWith("ERROR:")) {
          return reject(new Error(out || stderr || `cscript exited with code ${code}`));
        }

        if (!out || out === "" || out === "[]") {
          return resolve([]);
        }

        try {
          const parsed = JSON.parse(out);
          const list = Array.isArray(parsed) ? parsed : [parsed];
          resolve(list);
        } catch (e) {
          reject(new Error(`Failed to parse device output: ${out}`));
        }
      });
    });
  }
}

module.exports = SbxpcConnector;
