const fs = require("fs");
const path = require("path");
const SbxpcConnector = require("./sbxpc-connector");

async function viewRawLogs() {
  console.log("\n=======================================================");
  console.log("📟 Satyakiran Biometric — Live Raw Log Inspector");
  console.log("=======================================================\n");

  const configPath = path.resolve(__dirname, "../config.json");
  if (!fs.existsSync(configPath)) {
    console.error("❌ config.json not found!");
    process.exit(1);
  }

  const config = JSON.parse(fs.readFileSync(configPath, "utf-8"));
  const connector = new SbxpcConnector(config.machine);

  console.log(`🔍 Connecting to Machine: ${config.machine.ip}:${config.machine.port}...`);
  console.log("⏳ Reading raw log memory...\n");

  const rawLogs = await connector.fetchLogs();

  if (!rawLogs || rawLogs.length === 0) {
    console.log("⚠️  No logs currently in machine memory, or device returned 0 records.");
    return;
  }

  // Save to local files for easy viewing
  const logsDir = path.resolve(__dirname, "../logs");
  if (!fs.existsSync(logsDir)) fs.mkdirSync(logsDir, { recursive: true });

  const jsonPath = path.join(logsDir, "raw_machine_punches.json");
  const csvPath = path.join(logsDir, "raw_machine_punches.csv");

  fs.writeFileSync(jsonPath, JSON.stringify(rawLogs, null, 2), "utf-8");

  const csvRows = ["EmployeeCode,LogDateTime,Direction,VerificationMode,DeviceSerial,DeviceName"];
  for (const log of rawLogs) {
    csvRows.push(`${log.employeeCode},"${log.logDateTime}",${log.direction},${log.verificationMode},${log.deviceSerial},"${log.deviceName}"`);
  }
  fs.writeFileSync(csvPath, csvRows.join("\n"), "utf-8");

  console.log(`✅ Extracted ${rawLogs.length} Raw Punch Records!`);
  console.log(`💾 Raw JSON saved to : ${jsonPath}`);
  console.log(`📄 Raw CSV/Excel to  : ${csvPath}\n`);

  console.log("--- 📋 Preview of Recent 25 Records ---");
  console.table(
    rawLogs.slice(-25).map((l) => ({
      "Emp Code": l.employeeCode,
      "Punch Time": l.logDateTime,
      "Direction": l.direction,
      "Mode": l.verificationMode
    }))
  );
  console.log("=======================================================\n");

  if (process.platform === "win32") {
    try {
      const { exec } = require("child_process");
      exec(`start "" "${csvPath}"`);
      console.log("📊 Opening raw punches file in Excel / Default Viewer...");
    } catch {}
  }
}

viewRawLogs().catch((err) => {
  console.error("❌ Error reading raw logs:", err.message);
  process.exit(1);
});
