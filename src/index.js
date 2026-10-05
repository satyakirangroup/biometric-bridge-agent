const http = require("http");
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

async function processPendingCommands() {
  try {
    const commands = await pusher.fetchPendingCommands();
    if (!commands || commands.length === 0) return;

    log("INFO", `📩 Received ${commands.length} pending hardware command(s) from Satyakiran Cloud!`);

    for (const cmd of commands) {
      const cmdId = cmd.id || cmd.commandId;
      const action = (cmd.action || cmd.command || cmd.type || "").toUpperCase();
      const payload = cmd.data || cmd.payload || cmd;

      log("INFO", `⚙️  Executing Command [${cmdId}]: ${action}...`);

      try {
        if (action === "SET_USER" || action === "CREATE_USER") {
          const empCode = payload.enrollNumber || payload.punchId || payload.employeeCode || payload.UserId || payload.tatempcode;
          const empName = payload.employeeName || payload.fullName || payload.name || payload.UserName || "";
          const priv = Number(payload.privilege || 0);
          const enabled = payload.enabled !== false;
          if (!empCode) throw new Error("Missing employee identifier (enrollNumber/employeeCode) in command data");

          await connector.setUser(empCode, empName, priv, enabled);
          log("SUCCESS", `✅ [CRUD CREATE] Created Employee #${empCode} (${empName || "No name"}) on Biometric Machine!`);
          await pusher.acknowledgeCommand(cmdId, "SUCCESS");

        } else if (action === "UPDATE_USER") {
          const empCode = payload.enrollNumber || payload.punchId || payload.employeeCode || payload.UserId || payload.tatempcode;
          if (!empCode) throw new Error("Missing employee identifier in command data");

          await connector.updateUser(empCode, {
            name: payload.employeeName || payload.fullName || payload.name,
            privilege: payload.privilege,
            enabled: payload.enabled
          });
          log("SUCCESS", `✅ [CRUD UPDATE] Updated Employee #${empCode} on Biometric Machine!`);
          await pusher.acknowledgeCommand(cmdId, "SUCCESS");

        } else if (action === "DELETE_USER" || action === "REMOVE_USER") {
          const empCode = payload.enrollNumber || payload.punchId || payload.employeeCode || payload.UserId;
          if (!empCode) throw new Error("Missing employee identifier in command data");

          await connector.deleteUser(empCode);
          log("SUCCESS", `✅ [CRUD DELETE] Deleted Employee #${empCode} from Biometric Machine!`);
          await pusher.acknowledgeCommand(cmdId, "SUCCESS");

        } else if (action === "ENABLE_USER" || action === "DISABLE_USER") {
          const empCode = payload.enrollNumber || payload.punchId || payload.employeeCode || payload.UserId;
          if (!empCode) throw new Error("Missing employee identifier in command data");
          const flag = action === "ENABLE_USER" ? 1 : 0;

          await connector.enableUser(empCode, flag);
          log("SUCCESS", `✅ [CRUD TOGGLE] ${flag ? "Enabled" : "Disabled"} Employee #${empCode} on Biometric Machine!`);
          await pusher.acknowledgeCommand(cmdId, "SUCCESS");

        } else if (action === "SYNC_TIME") {
          await connector.syncTime();
          log("SUCCESS", `✅ Synchronized Biometric Machine clock with Server Time!`);
          await pusher.acknowledgeCommand(cmdId, "SUCCESS");

        } else if (action === "CLEAR_LOGS") {
          await connector.clearLogs();
          log("SUCCESS", `✅ Cleared device punch logs per Cloud command!`);
          await pusher.acknowledgeCommand(cmdId, "SUCCESS");

        } else {
          log("WARN", `⚠️ Unknown command action '${action}'. Skipping.`);
          await pusher.acknowledgeCommand(cmdId, "FAILED", `Unknown command action: ${action}`);
        }
      } catch (err) {
        log("ERROR", `❌ Failed executing command [${cmdId}]: ${err.message}`);
        await pusher.acknowledgeCommand(cmdId, "FAILED", err.message);
      }
    }
  } catch (err) {
    // Suppress minor polling errors
  }
}

async function syncCycle() {
  if (isSyncing) return;
  isSyncing = true;

  try {
    // 1. Process 2-way remote commands from cloud (Create user, delete user, clock sync, etc.)
    await processPendingCommands();

    // 2. Fetch raw logs from machine via SDK
    const rawLogs = await connector.fetchLogs();
    
    if (!rawLogs || rawLogs.length === 0) {
      log("INFO", `📡 Machine polled (${connector.ip}:${connector.port}) — 0 punch records in memory. Waiting for punches...`);
      return;
    }

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

    // 3. Filter out logs that were already synced
    const newLogs = rawLogs.filter((log) => !stateManager.isAlreadySynced(log));

    if (newLogs.length === 0) {
      log("INFO", `📡 Machine online (${connector.ip}:${connector.port}) | Total device records: ${rawLogs.length} | Synced: ${stateManager.state.totalSyncedCount} | ⚡ 2-Way Active | Listening for punches & commands...`);
      return;
    }

    log("INFO", `🔥 Detected ${newLogs.length} new punch record(s) on biometric device! Preparing push...`);

    // 4. Batch push to Satyakiran AWS Cloud
    const maxBatch = config.options?.maxBatchSize || 100;
    for (let i = 0; i < newLogs.length; i += maxBatch) {
      const batch = newLogs.slice(i, i + maxBatch);
      const pushResult = await pusher.pushPunches(batch);

      if (pushResult.success) {
        stateManager.markSynced(batch);
        log("SUCCESS", `Successfully pushed ${batch.length} punch(es) to Satyakiran Cloud! (Total Synced: ${stateManager.state.totalSyncedCount})`);
        
        // Print preview of first 3 punches
        for (const p of batch.slice(0, 3)) {
          const empDisplay = p.employeeName ? `${p.employeeName} (#${p.employeeCode})` : `#${p.employeeCode}`;
          console.log(`      👤 Emp: ${empDisplay} | Time: ${p.logDateTime} | Mode: ${p.verificationMode}`);
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

function startLocalHealthServer(port = 5006) {
  const server = http.createServer((req, res) => {
    res.setHeader("Access-Control-Allow-Origin", "*");
    res.setHeader("Content-Type", "application/json");

    const parsedUrl = new URL(req.url, `http://${req.headers.host || "localhost"}`);
    if (parsedUrl.pathname === "/" || parsedUrl.pathname === "/health" || parsedUrl.pathname === "/api/status") {
      res.writeHead(200);
      return res.end(JSON.stringify({
        status: "RUNNING",
        agent: "Satyakiran Biometric Bridge Agent",
        version: "1.0.0",
        twoWayActive: true,
        machine: {
          name: config.machine.deviceName,
          ip: config.machine.ip,
          port: config.machine.port,
          number: config.machine.machineNumber
        },
        cloud: {
          apiUrl: config.cloud.apiUrl,
          branchId: config.cloud.branchId,
          syncIntervalSeconds: config.cloud.syncIntervalSeconds
        },
        stats: {
          totalSynced: stateManager.state.totalSyncedCount,
          lastSyncAt: stateManager.state.lastSyncAt
        },
        timestamp: new Date().toISOString()
      }, null, 2));
    }

    res.writeHead(404);
    res.end(JSON.stringify({ error: "Not Found" }));
  });

  server.on("error", (err) => {
    if (err.code !== "EADDRINUSE") {
      log("WARN", `Local health API warning: ${err.message}`);
    }
  });

  server.listen(port, "0.0.0.0", () => {
    log("INFO", `🌐 Local Health API running on http://localhost:${port}/health`);
  });
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
  console.log(`⚡ 2-Way Remote Commands: ACTIVE (Polling Cloud -> Hardware)`);
  console.log("=======================================================\n");

  startLocalHealthServer(5006);

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
