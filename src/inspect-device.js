const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");
const os = require("os");

async function inspectMachine() {
  console.log("\n=======================================================");
  console.log("📟 Satyakiran Biometric — Machine Data & Inventory");
  console.log("=======================================================\n");

  const configPath = path.resolve(__dirname, "../config.json");
  if (!fs.existsSync(configPath)) {
    console.error("❌ config.json not found!");
    process.exit(1);
  }

  const config = JSON.parse(fs.readFileSync(configPath, "utf-8"));
  const machine = config.machine;

  console.log(`Connecting to Machine: ${machine.ip}:${machine.port} (ID: ${machine.machineNumber})...\n`);

  const vbsCode = `
On Error Resume Next
Set sbx = CreateObject("SBXPC.SBXPCCtrl.1")
If Err.Number <> 0 Then
    WScript.Echo "ERROR: Cannot create COM object SBXPC.SBXPCCtrl.1 (" & Err.Description & ")"
    WScript.Quit 1
End If
On Error Goto 0

connected = sbx.ConnectTcpip(${machine.machineNumber}, "${machine.ip}", ${machine.port}, ${machine.password})
If Not connected Then
    WScript.Echo "ERROR: Cannot connect to biometric device at ${machine.ip}:${machine.port} (Device offline or busy)"
    WScript.Quit 1
End If

' 1. Device Clock
Dim dY, dM, dD, dH, dMi, dS, dDow
dY = CLng(0): dM = CLng(0): dD = CLng(0): dH = CLng(0): dMi = CLng(0): dS = CLng(0): dDow = CLng(0)
hasTime = sbx.GetDeviceTime(${machine.machineNumber}, dY, dM, dD, dH, dMi, dS, dDow)
devTimeStr = dY & "-" & Right("0" & dM, 2) & "-" & Right("0" & dD, 2) & " " & Right("0" & dH, 2) & ":" & Right("0" & dMi, 2) & ":" & Right("0" & dS, 2)

' 2. Device Hardware Registers
Dim userCount, totalLogs, unreadLogs, fpCount, faceCount, pwdCount
userCount = CLng(0): totalLogs = CLng(0): unreadLogs = CLng(0): fpCount = CLng(0): faceCount = CLng(0): pwdCount = CLng(0)
sbx.GetDeviceStatus ${machine.machineNumber}, 2, userCount
sbx.GetDeviceStatus ${machine.machineNumber}, 6, totalLogs
sbx.GetDeviceStatus ${machine.machineNumber}, 11, unreadLogs
sbx.GetDeviceStatus ${machine.machineNumber}, 3, fpCount
sbx.GetDeviceStatus ${machine.machineNumber}, 9, faceCount
sbx.GetDeviceStatus ${machine.machineNumber}, 4, pwdCount

' 3. Enrolled User IDs
Dim userList
userList = ""
sbx.EnableDevice ${machine.machineNumber}, False

hasUsers = sbx.ReadAllUserID(${machine.machineNumber})
If hasUsers Then
    Dim uEnroll, uEmach, uBackup, uPriv, uEnable, uCnt
    uEnroll = CLng(0): uEmach = CLng(0): uBackup = CLng(0): uPriv = CLng(0): uEnable = CLng(0)
    uCnt = 0
    gotUser = sbx.GetAllUserID(${machine.machineNumber}, uEnroll, uEmach, uBackup, uPriv, uEnable)
    Do While gotUser
        uCnt = uCnt + 1
        If userList = "" Then
            userList = "" & uEnroll
        Else
            userList = userList & "," & uEnroll
        End If
        gotUser = sbx.GetAllUserID(${machine.machineNumber}, uEnroll, uEmach, uBackup, uPriv, uEnable)
    Loop
End If

' 4. Read Punches
Dim punchesJson
punchesJson = ""
hasLogs = sbx.ReadAllGLogData(${machine.machineNumber})
If Not hasLogs Then
    hasLogs = sbx.ReadGeneralLogData(${machine.machineNumber})
End If

If hasLogs Then
    Dim tMach, enrollNo, eMach, verifyMode, y, m, d, h, mi, s
    tMach = CLng(0): enrollNo = CLng(0): eMach = CLng(0): verifyMode = CLng(0)
    y = CLng(0): m = CLng(0): d = CLng(0): h = CLng(0): mi = CLng(0): s = CLng(0)
    
    gotRec = sbx.GetAllGLogData(${machine.machineNumber}, tMach, enrollNo, eMach, verifyMode, y, m, d, h, mi, s)
    If Not gotRec Then
        gotRec = sbx.GetGeneralLogData(${machine.machineNumber}, tMach, enrollNo, eMach, verifyMode, y, m, d, h, mi, s)
    End If

    Do While gotRec
        dt = Right("0000" & y, 4) & "-" & Right("00" & m, 2) & "-" & Right("00" & d, 2) & " " & Right("00" & h, 2) & ":" & Right("00" & mi, 2) & ":" & Right("00" & s, 2)
        vMode = "Face"
        If verifyMode = 1 Then vMode = "Fingerprint"
        If verifyMode = 2 Then vMode = "Card"
        
        item = "{" & Chr(34) & "emp" & Chr(34) & ":" & Chr(34) & enrollNo & Chr(34) & "," & Chr(34) & "time" & Chr(34) & ":" & Chr(34) & dt & Chr(34) & "," & Chr(34) & "mode" & Chr(34) & ":" & Chr(34) & vMode & Chr(34) & "}"
        If punchesJson = "" Then
            punchesJson = item
        Else
            punchesJson = punchesJson & "," & item
        End If
        gotRec = sbx.GetAllGLogData(${machine.machineNumber}, tMach, enrollNo, eMach, verifyMode, y, m, d, h, mi, s)
    Loop
End If

sbx.EnableDevice ${machine.machineNumber}, True
sbx.Disconnect
sbx.CloseCommPort

WScript.Echo "JSON_START"
WScript.Echo "{"
WScript.Echo "  ""deviceTime"": """ & devTimeStr & ""","
WScript.Echo "  ""userCount"": " & userCount & ","
WScript.Echo "  ""fpCount"": " & fpCount & ","
WScript.Echo "  ""faceCount"": " & faceCount & ","
WScript.Echo "  ""totalLogs"": " & totalLogs & ","
WScript.Echo "  ""unreadLogs"": " & unreadLogs & ","
WScript.Echo "  ""enrolledUsers"": [" & userList & "],"
WScript.Echo "  ""punches"": [" & punchesJson & "]"
WScript.Echo "}"
WScript.Echo "JSON_END"
`;

  const tmpVbs = path.join(os.tmpdir(), `inspect_machine_${Date.now()}.vbs`);
  fs.writeFileSync(tmpVbs, vbsCode, "utf-8");

  const sysRoot = process.env.SystemRoot || process.env.windir || "C:\\Windows";
  const x86Cscript = path.join(sysRoot, "SysWOW64", "cscript.exe");
  const cscriptExe = fs.existsSync(x86Cscript) ? x86Cscript : "cscript.exe";

  const proc = spawn(cscriptExe, ["//Nologo", tmpVbs]);
  let stdout = "";
  let stderr = "";

  proc.stdout.on("data", (d) => (stdout += d.toString()));
  proc.stderr.on("data", (d) => (stderr += d.toString()));

  proc.on("close", (code) => {
    try { fs.unlinkSync(tmpVbs); } catch {}

    const out = stdout.trim();
    if (code !== 0 || out.startsWith("ERROR:")) {
      console.error("❌ Inspection Error:", out || stderr);
      console.log("\n💡 Note: Make sure 'npm start' is stopped in your other window so the port is free.");
      process.exit(1);
    }

    const startIdx = out.indexOf("JSON_START");
    const endIdx = out.indexOf("JSON_END");

    if (startIdx === -1 || endIdx === -1) {
      console.log("Raw Output:", out);
      return;
    }

    const jsonStr = out.substring(startIdx + 10, endIdx).trim();
    try {
      const data = JSON.parse(jsonStr);

      console.log("-------------------------------------------------------");
      console.log("🕒 DEVICE CLOCK");
      console.log("-------------------------------------------------------");
      console.log(`   Device Date & Time : ${data.deviceTime}`);
      console.log(`   Computer Date & Time: ${new Date().toLocaleString("en-IN")}`);
      console.log("-------------------------------------------------------");
      console.log("📊 STORED HARDWARE TOTALS");
      console.log("-------------------------------------------------------");
      console.log(`   👥 Total Registered Users : ${data.userCount}`);
      console.log(`   🖐️  Enrolled Fingerprints   : ${data.fpCount}`);
      console.log(`   👤 Enrolled Faces          : ${data.faceCount}`);
      console.log(`   💾 TOTAL PUNCHES IN MEMORY : ${data.totalLogs}`);
      console.log(`   ⏳ Unread Punches Pending  : ${data.unreadLogs}`);
      console.log("-------------------------------------------------------");
      console.log("📋 ENROLLED EMPLOYEE IDS ON MACHINE");
      console.log("-------------------------------------------------------");
      if (data.enrolledUsers && data.enrolledUsers.length > 0) {
        console.log(`   Total Found: ${data.enrolledUsers.length} employee(s)`);
        console.log(`   IDs: ${data.enrolledUsers.slice(0, 50).join(", ")}${data.enrolledUsers.length > 50 ? "..." : ""}`);
      } else {
        console.log("   (No users enrolled on this machine)");
      }

      console.log("-------------------------------------------------------");
      console.log("🔍 ATTENDANCE PUNCHES");
      console.log("-------------------------------------------------------");
      if (data.punches && data.punches.length > 0) {
        console.log(`   ✅ Extracted ${data.punches.length} punch record(s)!`);
        console.table(data.punches.slice(-20));
      } else {
        console.log(`   ⚠️ Total Punches in memory is currently: ${data.totalLogs}`);
        if (data.totalLogs === 0) {
          console.log("      Machine memory has 0 attendance records stored.");
          console.log("      👉 Reason: Realsoft might have cleared memory or nobody has punched yet.");
        }
      }

      // Save summary
      const logsDir = path.resolve(__dirname, "../logs");
      if (!fs.existsSync(logsDir)) fs.mkdirSync(logsDir, { recursive: true });
      fs.writeFileSync(path.join(logsDir, "machine_inventory.json"), JSON.stringify(data, null, 2), "utf-8");
      console.log(`\n💾 Saved detailed report to: logs/machine_inventory.json`);
      console.log("=======================================================\n");
    } catch (e) {
      console.error("Failed to parse inventory:", e.message);
      console.log("Raw output:", jsonStr);
    }
  });
}

inspectMachine().catch(console.error);
