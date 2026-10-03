const http = require("http");
const fs = require("fs");
const path = require("path");
const SbxpcConnector = require("./sbxpc-connector");
const CloudPusher = require("./cloud-pusher");
const StateManager = require("./state-manager");

// 1. Load Configuration
const configPath = path.resolve(__dirname, "../config.json");
if (!fs.existsSync(configPath)) {
  console.error("❌ Fatal Error: config.json not found!");
  process.exit(1);
}

const config = JSON.parse(fs.readFileSync(configPath, "utf-8"));
const stateManager = new StateManager(config.options?.syncStateFile || "./sync-state.json");
const pusher = new CloudPusher(config.cloud);
const connector = new SbxpcConnector(config.machine);

const SYNC_INTERVAL_MS = (config.cloud.syncIntervalSeconds || 30) * 1000;
const LOCAL_API_PORT = 5006;

let isSyncing = false;
let totalPushes = 0;
let totalCommandsExecuted = 0;
let machineStatusCache = {
  ip: config.machine.ip,
  port: config.machine.port,
  online: false,
  totalUsers: 0,
  totalPunches: 0,
  lastSyncTime: null
};

function ts() {
  return new Date().toLocaleTimeString("en-IN", { hour12: false });
}

function log(channel, message) {
  const badge =
    channel === "CLOUD_PUSH" ? "📤 [CLOUD PUSH]" :
    channel === "CLOUD_CMD"  ? "📥 [CLOUD CMD ]" :
    channel === "LOCAL_API"  ? "🌐 [LOCAL API ]" :
    channel === "DEVICE"     ? "📟 [DEVICE    ]" :
    channel === "SUCCESS"    ? "✅ [SUCCESS   ]" :
    channel === "ERROR"      ? "❌ [ERROR     ]" :
                               "🔹 [SYSTEM    ]";
  console.log(`[${ts()}] ${badge} ${message}`);
}

// -------------------------------------------------------------
// Direction 2: Process Cloud Commands (AWS -> Biometric Device)
// -------------------------------------------------------------
async function processCloudCommands() {
  try {
    const commands = await pusher.fetchPendingCommands();
    if (!commands || !Array.isArray(commands) || commands.length === 0) {
      return 0;
    }

    log("CLOUD_CMD", `Found ${commands.length} pending command(s) in Satyakiran Cloud Queue!`);

    for (const cmd of commands) {
      const cmdId = cmd.id || cmd.commandId;
      const action = (cmd.action || cmd.command || cmd.type || "").toUpperCase();
      const payload = cmd.data || cmd.payload || cmd;

      log("CLOUD_CMD", `Executing [${cmdId}]: ${action}...`);

      try {
        if (action === "SET_USER" || action === "CREATE_USER") {
          const empCode = payload.employeeCode || payload.enrollNumber || payload.UserId || payload.tatempcode;
          const empName = payload.employeeName || payload.name || payload.UserName || "";
          const priv = Number(payload.privilege || 0);
          const enabled = payload.enabled !== false;
          if (!empCode) throw new Error("Missing employeeCode in command data");

          await connector.setUser(empCode, empName, priv, enabled);
          log("SUCCESS", `[CRUD CREATE] Employee #${empCode} (${empName || "No name"}) created on biometric hardware!`);
          await pusher.acknowledgeCommand(cmdId, "SUCCESS");
          totalCommandsExecuted++;

        } else if (action === "UPDATE_USER") {
          const empCode = payload.employeeCode || payload.enrollNumber || payload.UserId || payload.tatempcode;
          if (!empCode) throw new Error("Missing employeeCode in command data");

          await connector.updateUser(empCode, {
            name: payload.employeeName || payload.name,
            privilege: payload.privilege,
            enabled: payload.enabled
          });
          log("SUCCESS", `[CRUD UPDATE] Employee #${empCode} updated on biometric hardware!`);
          await pusher.acknowledgeCommand(cmdId, "SUCCESS");
          totalCommandsExecuted++;

        } else if (action === "DELETE_USER" || action === "REMOVE_USER") {
          const empCode = payload.employeeCode || payload.enrollNumber || payload.UserId;
          if (!empCode) throw new Error("Missing employeeCode in command data");

          await connector.deleteUser(empCode);
          log("SUCCESS", `[CRUD DELETE] Employee #${empCode} deleted from biometric hardware!`);
          await pusher.acknowledgeCommand(cmdId, "SUCCESS");
          totalCommandsExecuted++;

        } else if (action === "ENABLE_USER" || action === "DISABLE_USER") {
          const empCode = payload.employeeCode || payload.enrollNumber || payload.UserId;
          if (!empCode) throw new Error("Missing employeeCode in command data");
          const flag = action === "ENABLE_USER" ? 1 : 0;

          await connector.enableUser(empCode, flag);
          log("SUCCESS", `[CRUD TOGGLE] Employee #${empCode} ${flag ? "enabled" : "disabled"} on hardware!`);
          await pusher.acknowledgeCommand(cmdId, "SUCCESS");
          totalCommandsExecuted++;

        } else if (action === "SYNC_TIME") {
          await connector.syncTime();
          log("SUCCESS", `Synchronized biometric hardware clock with server time!`);
          await pusher.acknowledgeCommand(cmdId, "SUCCESS");
          totalCommandsExecuted++;

        } else if (action === "CLEAR_LOGS") {
          await connector.clearLogs();
          log("SUCCESS", `Cleared attendance logs on biometric device!`);
          await pusher.acknowledgeCommand(cmdId, "SUCCESS");
          totalCommandsExecuted++;

        } else {
          log("CLOUD_CMD", `⚠️ Unknown command action: '${action}'. Skipping.`);
          await pusher.acknowledgeCommand(cmdId, "FAILED", `Unknown action: ${action}`);
        }
      } catch (cmdErr) {
        log("ERROR", `Failed executing command [${cmdId}]: ${cmdErr.message}`);
        await pusher.acknowledgeCommand(cmdId, "FAILED", cmdErr.message);
      }
    }

    return commands.length;
  } catch (err) {
    return 0;
  }
}

// -------------------------------------------------------------
// Direction 1: Push Attendance Punches (Biometric Device -> AWS)
// -------------------------------------------------------------
async function processAttendancePushes() {
  const rawLogs = await connector.fetchLogs();
  
  if (!rawLogs || rawLogs.length === 0) {
    machineStatusCache.online = true;
    machineStatusCache.totalPunches = 0;
    machineStatusCache.lastSyncTime = new Date().toISOString();
    return 0;
  }

  machineStatusCache.online = true;
  machineStatusCache.totalPunches = rawLogs.length;
  machineStatusCache.lastSyncTime = new Date().toISOString();

  // Save local copy
  try {
    const logsDir = path.resolve(__dirname, "../logs");
    if (!fs.existsSync(logsDir)) fs.mkdirSync(logsDir, { recursive: true });
    fs.writeFileSync(path.join(logsDir, "raw_machine_punches.json"), JSON.stringify(rawLogs, null, 2), "utf-8");
  } catch {}

  const newLogs = rawLogs.filter((l) => !stateManager.isAlreadySynced(l));
  if (newLogs.length === 0) {
    return 0;
  }

  log("CLOUD_PUSH", `🔥 Detected ${newLogs.length} new punch(es) on device! Pushing to AWS...`);

  const maxBatch = config.options?.maxBatchSize || 100;
  let pushedCount = 0;

  for (let i = 0; i < newLogs.length; i += maxBatch) {
    const batch = newLogs.slice(i, i + maxBatch);
    const res = await pusher.pushPunches(batch);

    if (res.success) {
      stateManager.markSynced(batch);
      pushedCount += batch.length;
      totalPushes += batch.length;
      log("SUCCESS", `Pushed batch of ${batch.length} punch(es) to AWS Cloud Webhook! (Total Synced: ${stateManager.state.totalSyncedCount})`);
    } else {
      log("ERROR", `Push failed: ${res.error}`);
      break;
    }
  }

  return pushedCount;
}

// -------------------------------------------------------------
// Unified 2-Way Sync Cycle
// -------------------------------------------------------------
async function runTwoWayCycle() {
  if (isSyncing) return;
  isSyncing = true;

  try {
    // 1. Direction 2: Listen for & execute cloud commands
    await processCloudCommands();

    // 2. Direction 1: Read & push attendance punches
    const pushed = await processAttendancePushes();

    if (pushed === 0) {
      log("DEVICE", `Device Online (${connector.ip}:${connector.port}) | Punches in memory: ${machineStatusCache.totalPunches} | Total Synced: ${stateManager.state.totalSyncedCount} | Listening for punches & commands...`);
    }
  } catch (err) {
    machineStatusCache.online = false;
    log("DEVICE", `⚠️ Polling cycle notice: ${err.message}`);
  } finally {
    isSyncing = false;
  }
}

// -------------------------------------------------------------
// Local 2-Way HTTP Webhook API Server (Localhost:5006)
// -------------------------------------------------------------
function startLocalApiServer() {
  const server = http.createServer(async (req, res) => {
    // Enable CORS
    res.setHeader("Access-Control-Allow-Origin", "*");
    res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
    res.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");

    if (req.method === "OPTIONS") {
      res.writeHead(204);
      return res.end();
    }

    const parsedUrl = new URL(req.url, `http://${req.headers.host || "localhost"}`);
    const pathname = parsedUrl.pathname;

    function sendJson(status, data) {
      res.writeHead(status, { "Content-Type": "application/json" });
      res.end(JSON.stringify(data, null, 2));
    }

    async function parseBody() {
      return new Promise((resolve, reject) => {
        let body = "";
        req.on("data", (chunk) => (body += chunk.toString()));
        req.on("end", () => {
          try {
            resolve(body ? JSON.parse(body) : {});
          } catch (e) {
            reject(new Error("Invalid JSON body"));
          }
        });
        req.on("error", reject);
      });
    }

    try {
      // 1. Status Check
      if (req.method === "GET" && (pathname === "/" || pathname === "/api/status")) {
        return sendJson(200, {
          bridge: "Satyakiran Biometric Two-Way Bridge Agent",
          version: "2.0.0",
          status: "RUNNING",
          cloudEndpoint: config.cloud.apiUrl,
          branchId: config.cloud.branchId,
          device: machineStatusCache,
          stats: {
            totalPunchesUploaded: totalPushes,
            totalCommandsExecuted,
            currentlySyncedRecords: stateManager.state.totalSyncedCount
          },
          availableEndpoints: {
            "GET /api/status": "Get bridge and machine status",
            "GET /api/users": "List all enrolled users on machine",
            "GET /api/user?id=101": "Inspect a single employee's details",
            "POST /api/user": "Create employee on machine: { employeeCode, employeeName, privilege, enabled }",
            "PUT /api/user": "Update employee on machine: { employeeCode, employeeName, privilege, enabled }",
            "DELETE /api/user": "Delete employee from machine: { employeeCode }",
            "POST /api/toggle-user": "Enable/Disable employee: { employeeCode, enabled: true/false }",
            "POST /api/sync-time": "Sync machine clock with PC time",
            "POST /api/sync-now": "Trigger immediate punch sync to AWS"
          }
        });
      }

      // 2. Read All Users
      if (req.method === "GET" && pathname === "/api/users") {
        log("LOCAL_API", "GET /api/users requested");
        const users = await connector.getUsers();
        return sendJson(200, { success: true, count: users.length, users });
      }

      // 3. Read Single User (Inspect)
      if (req.method === "GET" && (pathname === "/api/user" || pathname.startsWith("/api/user/"))) {
        const queryId = parsedUrl.searchParams.get("id") || pathname.split("/").pop();
        if (!queryId || queryId === "user") {
          return sendJson(400, { success: false, error: "Missing 'id' parameter (e.g. /api/user?id=101)" });
        }
        log("LOCAL_API", `GET /api/user: ID=${queryId}`);
        const user = await connector.getUser(queryId);
        return sendJson(200, { success: true, user });
      }

      // 4. Create User (POST /api/user or POST /api/set-user)
      if (req.method === "POST" && (pathname === "/api/user" || pathname === "/api/set-user")) {
        const body = await parseBody();
        const code = body.employeeCode || body.empCode || body.id;
        const name = body.employeeName || body.name || "";
        const priv = Number(body.privilege || 0);
        const enabled = body.enabled !== false;

        if (!code) {
          return sendJson(400, { success: false, error: "Missing 'employeeCode' in body" });
        }

        log("LOCAL_API", `POST /api/user [CREATE]: Code=${code}, Name='${name}', Priv=${priv}, Enabled=${enabled}`);
        const result = await connector.setUser(code, name, priv, enabled);
        totalCommandsExecuted++;
        return sendJson(201, { success: true, action: "CREATED", result });
      }

      // 5. Update User (PUT /api/user or POST /api/update-user)
      if ((req.method === "PUT" && pathname === "/api/user") || (req.method === "POST" && pathname === "/api/update-user")) {
        const body = await parseBody();
        const code = body.employeeCode || body.empCode || body.id;

        if (!code) {
          return sendJson(400, { success: false, error: "Missing 'employeeCode' in body" });
        }

        log("LOCAL_API", `PUT /api/user [UPDATE]: Code=${code}`);
        const result = await connector.updateUser(code, {
          name: body.employeeName || body.name,
          privilege: body.privilege,
          enabled: body.enabled
        });
        totalCommandsExecuted++;
        return sendJson(200, { success: true, action: "UPDATED", result });
      }

      // 6. Delete User (DELETE /api/user or POST /api/delete-user)
      if ((req.method === "DELETE" && pathname === "/api/user") || (req.method === "POST" && pathname === "/api/delete-user")) {
        const body = await parseBody();
        const queryId = parsedUrl.searchParams.get("id");
        const code = body.employeeCode || body.empCode || body.id || queryId;

        if (!code) {
          return sendJson(400, { success: false, error: "Missing 'employeeCode' in body or query" });
        }

        log("LOCAL_API", `DELETE /api/user [DELETE]: Code=${code}`);
        const result = await connector.deleteUser(code);
        totalCommandsExecuted++;
        return sendJson(200, { success: true, action: "DELETED", result });
      }

      // 7. Toggle User Enable / Disable
      if (req.method === "POST" && pathname === "/api/toggle-user") {
        const body = await parseBody();
        const code = body.employeeCode || body.empCode || body.id;
        const enabled = body.enabled !== false ? 1 : 0;

        if (!code) {
          return sendJson(400, { success: false, error: "Missing 'employeeCode' in body" });
        }

        log("LOCAL_API", `POST /api/toggle-user: Code=${code}, Enabled=${enabled}`);
        const result = await connector.enableUser(code, enabled);
        totalCommandsExecuted++;
        return sendJson(200, { success: true, action: "TOGGLE", result });
      }

      // 8. Sync Time
      if (req.method === "POST" && pathname === "/api/sync-time") {
        log("LOCAL_API", "POST /api/sync-time requested");
        const result = await connector.syncTime();
        totalCommandsExecuted++;
        return sendJson(200, { success: true, result });
      }

      // 9. Trigger Immediate Cloud Sync
      if (req.method === "POST" && pathname === "/api/sync-now") {
        log("LOCAL_API", "POST /api/sync-now triggered");
        runTwoWayCycle();
        return sendJson(200, { success: true, message: "Sync cycle triggered immediately" });
      }

      // 404 Route
      return sendJson(404, { success: false, error: `Route not found: ${req.method} ${pathname}` });

    } catch (err) {
      log("LOCAL_API", `Error: ${err.message}`);
      return sendJson(500, { success: false, error: err.message });
    }
  });

  server.listen(LOCAL_API_PORT, "0.0.0.0", () => {
    log("LOCAL_API", `Local 2-Way REST API Server listening on http://localhost:${LOCAL_API_PORT}`);
  });

  server.on("error", (err) => {
    if (err.code === "EADDRINUSE") {
      log("LOCAL_API", `⚠️ Port ${LOCAL_API_PORT} in use; local HTTP API skipped, cloud 2-way sync continues.`);
    } else {
      log("LOCAL_API", `⚠️ Server error: ${err.message}`);
    }
  });
}

// -------------------------------------------------------------
// Main Entrypoint
// -------------------------------------------------------------
async function main() {
  console.log("=======================================================");
  console.log("🚀 SATYAKIRAN 2-WAY BIOMETRIC HARDWARE COMMUNICATION");
  console.log("   Direction 1: Hardware Punches ➡️  Satyakiran AWS Cloud");
  console.log("   Direction 2: Cloud Commands  ➡️  Biometric Hardware");
  console.log("=======================================================");
  console.log(`📟 Machine Target : ${config.machine.ip}:${config.machine.port}`);
  console.log(`🏢 Device Name    : ${config.machine.deviceName}`);
  console.log(`☁️  AWS Webhook   : ${config.cloud.apiUrl}`);
  console.log(`🏢 Branch ID      : ${config.cloud.branchId}`);
  console.log(`⏱️  Polling Rate   : Every ${config.cloud.syncIntervalSeconds} seconds`);
  console.log(`🌐 Local REST API : http://localhost:${LOCAL_API_PORT}`);
  console.log("=======================================================\n");

  // 1. Start Local REST API Server
  startLocalApiServer();

  // 2. Initial handshake
  log("DEVICE", "Verifying biometric device reachability...");
  const tcp = await connector.testTcpConnection(3000);
  if (tcp.connected) {
    log("DEVICE", `✅ TCP connected to ${config.machine.ip}:${config.machine.port}`);
    try {
      const users = await connector.getUsers();
      machineStatusCache.online = true;
      machineStatusCache.totalUsers = users.length;
      log("DEVICE", `✅ Machine verified: ${users.length} enrolled employees active.`);
    } catch {}
  } else {
    log("DEVICE", `⚠️ Warning: ${tcp.message}. Bridge will keep retrying...`);
  }

  // 3. Initial 2-Way Cycle
  log("SYSTEM", "Starting initial 2-way communication cycle...");
  await runTwoWayCycle();

  // 4. Set interval for ongoing polling
  log("SYSTEM", `2-Way daemon running. Polling cloud commands and device punches every ${config.cloud.syncIntervalSeconds}s.\n`);
  setInterval(runTwoWayCycle, SYNC_INTERVAL_MS);
}

// Graceful exit
process.on("SIGINT", () => {
  console.log("\n");
  log("SYSTEM", "Shutting down 2-way communication agent cleanly...");
  stateManager.save();
  process.exit(0);
});

process.on("SIGTERM", () => {
  stateManager.save();
  process.exit(0);
});

main().catch((err) => {
  console.error("Fatal startup error:", err);
  process.exit(1);
});
