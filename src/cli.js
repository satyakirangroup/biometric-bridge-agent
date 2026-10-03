const fs = require("fs");
const path = require("path");
const readline = require("readline");
const SbxpcConnector = require("./sbxpc-connector");
const CloudPusher = require("./cloud-pusher");
const StateManager = require("./state-manager");

const CONFIG_PATH = path.resolve(__dirname, "../config.json");

function loadConfig() {
  if (!fs.existsSync(CONFIG_PATH)) {
    const defaultConfig = {
      machine: {
        ip: "192.168.1.14",
        port: 5005,
        machineNumber: 1,
        password: 0,
        deviceName: "Sonipat Plant Biometric Machine"
      },
      cloud: {
        apiUrl: "https://api.satyakiran.co.in/api/v1/hrms/attendance/biometric-push",
        authToken: "satyakiran_biometric_2026",
        branchId: "0fe39d99-31fb-4753-aa6c-704499bdbba9",
        syncIntervalSeconds: 30
      },
      options: {
        clearDeviceLogsAfterSync: false,
        syncStateFile: "./sync-state.json",
        maxBatchSize: 100,
        retryIntervalSeconds: 10
      }
    };
    fs.writeFileSync(CONFIG_PATH, JSON.stringify(defaultConfig, null, 2), "utf-8");
    return defaultConfig;
  }
  return JSON.parse(fs.readFileSync(CONFIG_PATH, "utf-8"));
}

function saveConfig(cfg) {
  fs.writeFileSync(CONFIG_PATH, JSON.stringify(cfg, null, 2), "utf-8");
}

function createRl() {
  return readline.createInterface({
    input: process.stdin,
    output: process.stdout
  });
}

function ask(rl, query) {
  return new Promise((resolve) => rl.question(query, resolve));
}

async function showHeader(cfg) {
  console.clear();
  console.log("=======================================================");
  console.log("🚀 SATYAKIRAN BIOMETRIC CLOUD BRIDGE — ALL-IN-ONE CLI");
  console.log("=======================================================");
  console.log(`📟 Machine IP   : ${cfg.machine.ip}:${cfg.machine.port} (ID: ${cfg.machine.machineNumber})`);
  console.log(`🏢 Device Name  : ${cfg.machine.deviceName}`);
  console.log(`☁️  Cloud URL    : ${cfg.cloud.apiUrl}`);
  console.log(`🏢 Branch ID    : ${cfg.cloud.branchId}`);
  console.log("=======================================================\n");
}

async function testConnection(cfg) {
  console.log(`\n⏳ Testing connection to ${cfg.machine.ip}:${cfg.machine.port}...`);
  const connector = new SbxpcConnector(cfg.machine);

  const tcp = await connector.testTcpConnection(3000);
  if (!tcp.connected) {
    console.log(`❌ TCP Ping Failed: ${tcp.message}`);
    console.log("   👉 Check if device is powered on and connected to LAN (192.168.1.x)");
    return;
  }
  console.log(`✅ TCP Socket OK: Reached ${cfg.machine.ip}:${cfg.machine.port}`);

  try {
    const data = await connector.inspectMachine();
    console.log("✅ Device Handshake Successful!");
    console.log(`   🕒 Device Time : ${data.deviceTime}`);
    console.log(`   👥 Total Users : ${data.userCount}`);
    console.log(`   💾 Total Logs  : ${data.totalLogs}`);
  } catch (err) {
    console.log(`❌ Device Handshake Error: ${err.message}`);
  }
}

async function pullLogs(cfg) {
  console.log(`\n⏳ Reading all punch records from machine memory (${cfg.machine.ip})...`);
  const connector = new SbxpcConnector(cfg.machine);

  try {
    const logs = await connector.fetchLogs();
    if (!logs || logs.length === 0) {
      console.log("⚠️  0 punch records found in device memory.");
      return;
    }

    console.log(`✅ Successfully extracted ${logs.length} punch records from device memory!\n`);

    // Save CSV and JSON
    const logsDir = path.resolve(__dirname, "../logs");
    if (!fs.existsSync(logsDir)) fs.mkdirSync(logsDir, { recursive: true });
    
    fs.writeFileSync(path.join(logsDir, "raw_machine_punches.json"), JSON.stringify(logs, null, 2), "utf-8");

    const csvRows = ["EmployeeCode,EmployeeName,LogDateTime,Direction,VerificationMode,DeviceSerial,DeviceName"];
    for (const l of logs) {
      csvRows.push(`${l.employeeCode},"${l.employeeName || ""}",${l.logDateTime},${l.direction},${l.verificationMode},${l.deviceSerial},"${l.deviceName}"`);
    }
    fs.writeFileSync(path.join(logsDir, "raw_machine_punches.csv"), csvRows.join("\n"), "utf-8");

    console.log(`💾 Saved full records to logs/raw_machine_punches.csv and .json`);

    console.log("\n📋 Showing Last 15 Punches (Most Recent):");
    console.table(logs.slice(-15).map((l) => ({
      EmpCode: l.employeeCode,
      Name: l.employeeName,
      PunchTime: l.logDateTime,
      Mode: l.verificationMode
    })));
  } catch (err) {
    console.error(`❌ Failed to read logs: ${err.message}`);
  }
}

async function viewEnrolledEmployees(cfg) {
  console.log(`\n⏳ Querying enrolled users from biometric hardware (${cfg.machine.ip})...`);
  const connector = new SbxpcConnector(cfg.machine);

  try {
    const users = await connector.getUsers();
    if (users && users.length > 0) {
      console.log(`\n📋 Enrolled Employees on Machine (Total: ${users.length}):`);
      console.table(users.map((u) => ({
        EmpID: u.employeeCode,
        EmployeeName: u.employeeName || "(Registered on machine)"
      })));
    } else {
      console.log("⚠️ No users found registered on this machine.");
    }
  } catch (err) {
    console.error(`❌ Failed to query employees: ${err.message}`);
  }
}

async function pushToCloud(cfg) {
  console.log(`\n⏳ Fetching pending punches and pushing to Satyakiran AWS Cloud...`);
  const connector = new SbxpcConnector(cfg.machine);
  const pusher = new CloudPusher(cfg.cloud);
  const stateManager = new StateManager(cfg.options?.syncStateFile || "./sync-state.json");

  try {
    const rawLogs = await connector.fetchLogs();
    if (!rawLogs || rawLogs.length === 0) {
      console.log("⚠️  0 records found in biometric machine.");
      return;
    }

    const pendingLogs = rawLogs.filter((l) => !stateManager.isAlreadySynced(l));

    if (pendingLogs.length === 0) {
      console.log(`✅ All ${rawLogs.length} punch records are ALREADY synced with cloud DB!`);
      console.log("   (No new un-pushed punches detected in device memory).");
      return;
    }

    console.log(`🚀 Found ${pendingLogs.length} new punch(es) to push to cloud DB...`);

    const batchSize = cfg.options?.maxBatchSize || 100;
    let success = 0;
    let failed = 0;

    for (let i = 0; i < pendingLogs.length; i += batchSize) {
      const batch = pendingLogs.slice(i, i + batchSize);
      process.stdout.write(`   📤 Batch ${Math.floor(i / batchSize) + 1}/${Math.ceil(pendingLogs.length / batchSize)}... `);

      const res = await pusher.pushPunches(batch);
      if (res.success) {
        stateManager.markSynced(batch);
        success += batch.length;
        console.log("✅ OK");
      } else {
        failed += batch.length;
        console.log(`❌ Failed: ${res.error}`);
      }
    }

    console.log(`\n🎉 Push Complete! Synced: ${success} | Failed: ${failed} | Total Cloud Count: ${stateManager.state.totalSyncedCount}`);
  } catch (err) {
    console.error(`❌ Push Error: ${err.message}`);
  }
}

async function fullHistoricalSync(cfg) {
  console.log("\n=======================================================");
  console.log("🔄 FULL HISTORICAL DATA SYNC (Force Sync All)");
  console.log("=======================================================");
  const connector = new SbxpcConnector(cfg.machine);
  const pusher = new CloudPusher(cfg.cloud);
  const stateManager = new StateManager(cfg.options?.syncStateFile || "./sync-state.json");

  try {
    const rawLogs = await connector.fetchLogs();
    if (!rawLogs || rawLogs.length === 0) {
      console.log("⚠️  0 punch records found in biometric machine memory.");
      return;
    }

    console.log(`✅ Successfully extracted ${rawLogs.length} records from machine memory!`);
    console.log(`☁️  Target: ${cfg.cloud.apiUrl}`);

    rawLogs.sort((a, b) => new Date(a.logDateTime).getTime() - new Date(b.logDateTime).getTime());
    console.log(`📅 Date Range: ${rawLogs[0]?.logDateTime} ---> ${rawLogs[rawLogs.length - 1]?.logDateTime}\n`);

    const batchSize = cfg.options?.maxBatchSize || 100;
    let success = 0;

    for (let i = 0; i < rawLogs.length; i += batchSize) {
      const batch = rawLogs.slice(i, i + batchSize);
      process.stdout.write(`   📤 Uploading batch ${Math.floor(i / batchSize) + 1}/${Math.ceil(rawLogs.length / batchSize)} (${Math.round(((i + batch.length) / rawLogs.length) * 100)}%)... `);

      const res = await pusher.pushPunches(batch);
      if (res.success) {
        stateManager.markSynced(batch);
        success += batch.length;
        console.log("✅ OK");
      } else {
        console.log(`❌ Failed: ${res.error}`);
      }
    }

    console.log("\n=======================================================");
    console.log(`🎉 FULL SYNC COMPLETE! Uploaded ${success}/${rawLogs.length} records!`);
    console.log("=======================================================\n");
  } catch (err) {
    console.error(`❌ Sync Error: ${err.message}`);
  }
}

async function configureSettings(cfg, rl) {
  console.log("\n=======================================================");
  console.log("⚙️  UPDATE SETTINGS (Press ENTER to keep current value)");
  console.log("=======================================================");

  const ip = await ask(rl, `Machine IP [${cfg.machine.ip}]: `);
  if (ip.trim()) cfg.machine.ip = ip.trim();

  const port = await ask(rl, `Machine Port [${cfg.machine.port}]: `);
  if (port.trim()) cfg.machine.port = parseInt(port.trim(), 10);

  const machNo = await ask(rl, `Machine Number [${cfg.machine.machineNumber}]: `);
  if (machNo.trim()) cfg.machine.machineNumber = parseInt(machNo.trim(), 10);

  const devName = await ask(rl, `Device Name [${cfg.machine.deviceName}]: `);
  if (devName.trim()) cfg.machine.deviceName = devName.trim();

  const apiUrl = await ask(rl, `Cloud API URL [${cfg.cloud.apiUrl}]: `);
  if (apiUrl.trim()) cfg.cloud.apiUrl = apiUrl.trim();

  const branchId = await ask(rl, `Branch ID [${cfg.cloud.branchId}]: `);
  if (branchId.trim()) cfg.cloud.branchId = branchId.trim();

  saveConfig(cfg);
  console.log("\n✅ Configuration updated successfully in config.json!");
}

async function enrollUser(cfg, rl) {
  console.log("\n=======================================================");
  console.log("👤 ENROL / CREATE EMPLOYEE ON BIOMETRIC MACHINE");
  console.log("=======================================================");

  const empCodeStr = await ask(rl, "👉 Enter Employee Code / ID (e.g. 101): ");
  const empCode = parseInt(empCodeStr.trim(), 10);
  if (isNaN(empCode) || empCode <= 0) {
    console.log("❌ Invalid employee code. Must be a positive integer.");
    return;
  }

  const empName = (await ask(rl, "👉 Enter Employee Name (e.g. Rahul Sharma): ")).trim();
  if (!empName) {
    console.log("❌ Employee name cannot be empty.");
    return;
  }

  console.log(`\n⏳ Setting User #${empCode} [${empName}] on biometric device (${cfg.machine.ip})...`);
  const connector = new SbxpcConnector(cfg.machine);

  try {
    const res = await connector.setUser(empCode, empName);
    if (res.success) {
      console.log(`\n✅ SUCCESS: Employee #${empCode} [${empName}] created & enabled on physical machine!`);
      console.log("   (Machine flash memory updated and cached in logs/enrolled_employees.json)");
    } else {
      console.log(`❌ Hardware returned failure:`, res);
    }
  } catch (err) {
    console.error(`❌ Failed to create employee on machine: ${err.message}`);
  }
}

async function deleteUser(cfg, rl) {
  console.log("\n=======================================================");
  console.log("🗑️  DELETE EMPLOYEE FROM BIOMETRIC MACHINE");
  console.log("=======================================================");

  const empCodeStr = await ask(rl, "👉 Enter Employee Code / ID to delete: ");
  const empCode = parseInt(empCodeStr.trim(), 10);
  if (isNaN(empCode) || empCode <= 0) {
    console.log("❌ Invalid employee code. Must be a positive integer.");
    return;
  }

  const confirm = (await ask(rl, `⚠️  Are you sure you want to delete Employee #${empCode} from hardware? (y/N): `)).trim().toLowerCase();
  if (confirm !== "y") {
    console.log("Operation cancelled.");
    return;
  }

  console.log(`\n⏳ Deleting Employee #${empCode} from biometric device (${cfg.machine.ip})...`);
  const connector = new SbxpcConnector(cfg.machine);

  try {
    const res = await connector.deleteUser(empCode);
    if (res.success) {
      console.log(`\n✅ SUCCESS: Employee #${empCode} deleted from physical biometric hardware!`);
    } else {
      console.log(`❌ Hardware returned failure:`, res);
    }
  } catch (err) {
    console.error(`❌ Failed to delete employee: ${err.message}`);
  }
}

async function inspectUser(cfg, rl) {
  console.log("\n=======================================================");
  console.log("🔍 INSPECT SINGLE EMPLOYEE DETAILS");
  console.log("=======================================================");

  const empCodeStr = await ask(rl, "👉 Enter Employee Code / ID to inspect: ");
  const empCode = parseInt(empCodeStr.trim(), 10);
  if (isNaN(empCode) || empCode <= 0) {
    console.log("❌ Invalid employee code.");
    return;
  }

  console.log(`\n⏳ Querying Employee #${empCode} from biometric device (${cfg.machine.ip})...`);
  const connector = new SbxpcConnector(cfg.machine);
  try {
    const user = await connector.getUser(empCode);
    const privMap = { 0: "Normal User (Punch Only)", 1: "Enroller", 2: "Manager", 3: "Administrator" };
    console.log("\n📋 Employee Hardware Profile:");
    console.log(`   🆔 Employee Code : ${user.employeeCode}`);
    console.log(`   👤 Full Name     : ${user.employeeName || "(No Name set)"}`);
    console.log(`   🛡️  Privilege     : ${privMap[user.privilege] || user.privilege}`);
    console.log(`   ⚡ Status        : Active & Enrolled on Hardware`);
  } catch (err) {
    console.error(`❌ Failed to query employee: ${err.message}`);
  }
}

async function updateUser(cfg, rl) {
  console.log("\n=======================================================");
  console.log("✏️  UPDATE EMPLOYEE ON BIOMETRIC MACHINE");
  console.log("=======================================================");

  const empCodeStr = await ask(rl, "👉 Enter Employee Code / ID to update: ");
  const empCode = parseInt(empCodeStr.trim(), 10);
  if (isNaN(empCode) || empCode <= 0) {
    console.log("❌ Invalid employee code.");
    return;
  }

  const connector = new SbxpcConnector(cfg.machine);
  const current = await connector.getUser(empCode).catch(() => ({}));
  console.log(`   Current Name: '${current.employeeName || ""}'`);

  const newName = (await ask(rl, `👉 New Name [${current.employeeName || "Keep Current"}]: `)).trim();
  const finalName = newName || current.employeeName || "";

  console.log("   Privilege Levels: [0] User, [1] Enroller, [2] Manager, [3] Administrator");
  const privStr = await ask(rl, `👉 New Privilege [${current.privilege || 0}]: `);
  const finalPriv = privStr.trim() !== "" ? parseInt(privStr.trim(), 10) : (current.privilege || 0);

  const enableStr = (await ask(rl, "👉 Status: [1] Enabled, [0] Disabled [1]: ")).trim();
  const finalEnable = enableStr === "0" ? 0 : 1;

  console.log(`\n⏳ Updating Employee #${empCode} on device...`);
  try {
    const res = await connector.setUser(empCode, finalName, finalPriv, finalEnable);
    if (res.success) {
      console.log(`\n✅ SUCCESS: Employee #${empCode} updated successfully on hardware!`);
    } else {
      console.log(`❌ Failed:`, res);
    }
  } catch (err) {
    console.error(`❌ Update Error: ${err.message}`);
  }
}

async function syncDeviceTime(cfg) {
  console.log(`\n⏳ Synchronizing biometric hardware clock with PC time (${cfg.machine.ip})...`);
  const connector = new SbxpcConnector(cfg.machine);

  try {
    const res = await connector.syncTime();
    if (res.success) {
      console.log(`✅ SUCCESS: Biometric machine clock synchronized with current PC time!`);
    } else {
      console.log(`❌ Clock sync returned failure:`, res);
    }
  } catch (err) {
    console.error(`❌ Time sync failed: ${err.message}`);
  }
}

async function startContinuousSync(cfg) {
  console.log("\n=======================================================");
  console.log("🚀 STARTING 24/7 CONTINUOUS 2-WAY HARDWARE SYNC");
  console.log(`   Polling punches & cloud commands every ${cfg.cloud.syncIntervalSeconds || 30} seconds...`);
  console.log("   Press Ctrl+C to stop.");
  console.log("=======================================================\n");

  require("./two-way-sync");
}

async function main() {
  const cfg = loadConfig();

  while (true) {
    await showHeader(cfg);

    console.log("Select an Action:");
    console.log(" [1]  📡 Test Connection (Check IP & Reachability)");
    console.log(" [2]  📥 Pull / Read Punches from Machine Memory");
    console.log(" [3]  🕒 Synchronize Machine Clock with PC Time\n");

    console.log(" --- EMPLOYEE CRUD MANAGEMENT (2-WAY HARDWARE) ---");
    console.log(" [4]  👥 View All Enrolled Employees (List All)");
    console.log(" [5]  🔍 Inspect Single Employee Details");
    console.log(" [6]  👤 Create / Enrol New Employee");
    console.log(" [7]  ✏️  Update Existing Employee (Name, Privilege, Status)");
    console.log(" [8]  🗑️  Delete Employee from Machine (Full Removal)\n");

    console.log(" --- CLOUD SYNC & AUTOMATION ---");
    console.log(" [9]  ☁️  Push / Upload Pending Punches to AWS Cloud");
    console.log(" [10] 🔄 Full Historical Sync (Force Upload All to Cloud)");
    console.log(" [11] 🚀 Start 2-Way Realtime Daemon (Punches + Cloud Commands)");
    console.log(" [12] ⚙️  Update Machine IP / Cloud Settings");
    console.log(" [0]  ❌ Exit\n");

    const rl = createRl();
    const choice = (await ask(rl, "👉 Enter choice (0-12): ")).trim();
    rl.close();

    switch (choice) {
      case "1":
        await testConnection(cfg);
        break;
      case "2":
        await pullLogs(cfg);
        break;
      case "3":
        await syncDeviceTime(cfg);
        break;
      case "4":
        await viewEnrolledEmployees(cfg);
        break;
      case "5": {
        const rlInspect = createRl();
        await inspectUser(cfg, rlInspect);
        rlInspect.close();
        break;
      }
      case "6": {
        const rlEnroll = createRl();
        await enrollUser(cfg, rlEnroll);
        rlEnroll.close();
        break;
      }
      case "7": {
        const rlUpdate = createRl();
        await updateUser(cfg, rlUpdate);
        rlUpdate.close();
        break;
      }
      case "8": {
        const rlDelete = createRl();
        await deleteUser(cfg, rlDelete);
        rlDelete.close();
        break;
      }
      case "9":
        await pushToCloud(cfg);
        break;
      case "10":
        await fullHistoricalSync(cfg);
        break;
      case "11":
        await startContinuousSync(cfg);
        return;
      case "12": {
        const rlConfig = createRl();
        await configureSettings(cfg, rlConfig);
        rlConfig.close();
        break;
      }
      case "0":
        console.log("\n👋 Exiting Satyakiran Biometric Control Panel. Goodbye!\n");
        process.exit(0);
      default:
        console.log("\n⚠️ Invalid choice. Please enter 0-12.");
    }

    const rlPause = createRl();
    await ask(rlPause, "\nPress Enter to continue...");
    rlPause.close();
  }
}

main().catch(console.error);
