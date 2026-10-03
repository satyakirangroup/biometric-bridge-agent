const fs = require("fs");
const path = require("path");
const SbxpcConnector = require("./sbxpc-connector");
const CloudPusher = require("./cloud-pusher");
const StateManager = require("./state-manager");

async function syncAllHistoricalData() {
  console.log("\n=======================================================");
  console.log("🔄 Satyakiran Biometric — Full Historical Data Sync");
  console.log("   Reading 100% of stored offline punches from device memory");
  console.log("=======================================================\n");

  const configPath = path.resolve(__dirname, "../config.json");
  if (!fs.existsSync(configPath)) {
    console.error("❌ config.json not found!");
    process.exit(1);
  }

  const config = JSON.parse(fs.readFileSync(configPath, "utf-8"));
  const connector = new SbxpcConnector(config.machine);
  const pusher = new CloudPusher(config.cloud);
  const stateManager = new StateManager(config.options?.syncStateFile || "./sync-state.json");

  console.log(`📟 Machine Target: ${config.machine.ip}:${config.machine.port}`);
  console.log(`☁️  Cloud Endpoint: ${config.cloud.apiUrl}`);
  console.log("⏳ Fetching all historical logs from biometric device memory...\n");

  const startTime = Date.now();
  const rawLogs = await connector.fetchLogs();

  if (!rawLogs || rawLogs.length === 0) {
    console.log("⚠️  No logs found in biometric machine memory or device is idle.");
    return;
  }

  console.log(`✅ Successfully extracted ${rawLogs.length} punch record(s) from device!`);

  // Auto-save raw logs snapshot to local files for offline verification & Excel viewing
  try {
    const logsDir = path.resolve(__dirname, "../logs");
    if (!fs.existsSync(logsDir)) fs.mkdirSync(logsDir, { recursive: true });
    fs.writeFileSync(path.join(logsDir, "raw_machine_punches.json"), JSON.stringify(rawLogs, null, 2), "utf-8");

    const csvRows = ["EmployeeCode,EmployeeName,LogDateTime,Direction,VerificationMode,DeviceSerial,DeviceName"];
    for (const log of rawLogs) {
      csvRows.push(`${log.employeeCode},"${log.employeeName || ""}",${log.logDateTime},${log.direction},${log.verificationMode},${log.deviceSerial},"${log.deviceName}"`);
    }
    fs.writeFileSync(path.join(logsDir, "raw_machine_punches.csv"), csvRows.join("\n"), "utf-8");
  } catch {}

  // Sort logs chronologically (oldest first to newest)
  rawLogs.sort((a, b) => new Date(a.logDateTime).getTime() - new Date(b.logDateTime).getTime());

  const firstDate = rawLogs[0]?.logDateTime;
  const lastDate = rawLogs[rawLogs.length - 1]?.logDateTime;
  console.log(`📅 Date Range: ${firstDate}  --->  ${lastDate}\n`);

  console.log("🚀 Starting bulk upload to Satyakiran Cloud DB...");

  const batchSize = config.options?.maxBatchSize || 100;
  let successCount = 0;
  let failCount = 0;

  for (let i = 0; i < rawLogs.length; i += batchSize) {
    const batch = rawLogs.slice(i, i + batchSize);
    const progress = Math.min(100, Math.round(((i + batch.length) / rawLogs.length) * 100));

    process.stdout.write(`   📤 Uploading batch ${Math.floor(i / batchSize) + 1}/${Math.ceil(rawLogs.length / batchSize)} (${progress}%)... `);

    const res = await pusher.pushPunches(batch);
    if (res.success) {
      stateManager.markSynced(batch);
      successCount += batch.length;
      console.log("✅ OK");
    } else {
      failCount += batch.length;
      console.log(`❌ Failed: ${res.error}`);
    }
  }

  const durationSec = ((Date.now() - startTime) / 1000).toFixed(1);

  console.log("\n=======================================================");
  console.log("🎉 HISTORICAL SYNC COMPLETE!");
  console.log(`📊 Total Records Read    : ${rawLogs.length}`);
  console.log(`✅ Successfully Synced   : ${successCount}`);
  if (failCount > 0) {
    console.log(`❌ Failed Records        : ${failCount}`);
  }
  console.log(`⏱️  Time Elapsed          : ${durationSec}s`);
  console.log("🌐 View results at: https://app.satyakiran.co.in/ems/attendance");
  console.log("=======================================================\n");
}

syncAllHistoricalData().catch((err) => {
  console.error("❌ Fatal error during historical sync:", err);
  process.exit(1);
});
