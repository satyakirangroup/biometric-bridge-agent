const fs = require("fs");
const path = require("path");
const StateManager = require("./state-manager");
const CloudPusher = require("./cloud-pusher");
const SbxpcConnector = require("./sbxpc-connector");

// Load Configuration
const configPath = path.resolve(__dirname, "../config.json");
if (!fs.existsSync(configPath)) {
  console.error("❌ Fatal: config.json file not found!");
  process.exit(1);
}

const config = JSON.parse(fs.readFileSync(configPath, "utf-8"));
const stateManager = new StateManager(config.options?.syncStateFile || "./sync-state.json");
const pusher = new CloudPusher(config.cloud);
const connector = new SbxpcConnector(config.machine);

const SYNC_INTERVAL_MS = (config.cloud.syncIntervalSeconds || 30) * 1000;
let isSyncing = false;

function log(level, message) {
  const ts = new Date().toLocaleTimeString("en-IN", { hour12: false });
  const icon = level === "INFO" ? "🔹" : level === "SUCCESS" ? "✅" : level === "WARN" ? "⚠️" : "❌";
  console.log(`[${ts}] ${icon} ${message}`);
}

async function syncCycle() {
  if (isSyncing) return;
  isSyncing = true;

  try {
    // 1. Fetch raw logs from machine via SDK
    const rawLogs = await connector.fetchLogs();
    
    if (!rawLogs || rawLogs.length === 0) {
      log("INFO", `📡 Machine polled (${connector.ip}:${connector.port}) — 0 punch records in memory. Waiting for punches...`);
      isSyncing = false;
      return;
    }

    // Auto-save raw logs snapshot to local files for offline verification & Excel viewing
    try {
      const logsDir = path.resolve(__dirname, "../logs");
      if (!fs.existsSync(logsDir)) fs.mkdirSync(logsDir, { recursive: true });
      fs.writeFileSync(path.join(logsDir, "raw_machine_punches.json"), JSON.stringify(rawLogs, null, 2), "utf-8");

      const csvRows = ["EmployeeCode,LogDateTime,Direction,VerificationMode,DeviceSerial,DeviceName"];
      for (const log of rawLogs) {
        csvRows.push(`${log.employeeCode},"${log.logDateTime}",${log.direction},${log.verificationMode},${log.deviceSerial},"${log.deviceName}"`);
      }
      fs.writeFileSync(path.join(logsDir, "raw_machine_punches.csv"), csvRows.join("\n"), "utf-8");
    } catch {}

    // 2. Filter out logs that were already synced
    const newLogs = rawLogs.filter((log) => !stateManager.isAlreadySynced(log));

    if (newLogs.length === 0) {
      log("INFO", `📡 Machine online (${connector.ip}:${connector.port}) | Total device records: ${rawLogs.length} | Synced: ${stateManager.state.totalSyncedCount} | Listening for new punches...`);
      isSyncing = false;
      return;
    }

    log("INFO", `🔥 Detected ${newLogs.length} new punch record(s) on biometric device! Preparing push...`);

    // 3. Batch push to Satyakiran AWS Cloud
    const maxBatch = config.options?.maxBatchSize || 100;
    for (let i = 0; i < newLogs.length; i += maxBatch) {
      const batch = newLogs.slice(i, i + maxBatch);
      const pushResult = await pusher.pushPunches(batch);

      if (pushResult.success) {
        stateManager.markSynced(batch);
        log("SUCCESS", `Successfully pushed ${batch.length} punch(es) to Satyakiran Cloud! (Total Synced: ${stateManager.state.totalSyncedCount})`);
        
        // Print preview of first 3 punches
        for (const p of batch.slice(0, 3)) {
          console.log(`      👤 EmpCode: ${p.employeeCode} | Time: ${p.logDateTime} | Mode: ${p.verificationMode}`);
        }
        if (batch.length > 3) {
          console.log(`      ... and ${batch.length - 3} more records`);
        }
      } else {
        log("ERROR", `Failed to push batch to cloud: ${pushResult.error}. Will retry next cycle.`);
        break;
      }
    }
  } catch (err) {
    log("WARN", `Sync cycle skipped: ${err.message}`);
  } finally {
    isSyncing = false;
  }
}

async function start() {
  console.log("\n=======================================================");
  console.log("🚀 Satyakiran Biometric Cloud Bridge Agent v1.0");
  console.log("   100% Native Biometric to AWS Integration");
  console.log("=======================================================");
  console.log(`🏢 Branch: ${config.cloud.branchId}`);
  console.log(`📟 Machine: ${config.machine.ip}:${config.machine.port} (No: ${config.machine.machineNumber})`);
  console.log(`☁️  Cloud URL: ${config.cloud.apiUrl}`);
  console.log(`⏱️  Polling Interval: ${config.cloud.syncIntervalSeconds} seconds`);
  console.log(`💾 Previously Synced Records: ${stateManager.state.totalSyncedCount}`);
  console.log("=======================================================\n");

  log("INFO", "Starting initial sync cycle (catching up offline punches)...");
  await syncCycle();

  // Start continuous background polling
  log("INFO", `Continuous sync active. Polling device every ${config.cloud.syncIntervalSeconds}s...\n`);
  setInterval(syncCycle, SYNC_INTERVAL_MS);
}

// Handle graceful termination
process.on("SIGINT", () => {
  log("INFO", "Shutting down Satyakiran Biometric Bridge Agent cleanly...");
  stateManager.save();
  process.exit(0);
});

process.on("SIGTERM", () => {
  stateManager.save();
  process.exit(0);
});

start().catch((err) => {
  console.error("Fatal error starting agent:", err);
  process.exit(1);
});
