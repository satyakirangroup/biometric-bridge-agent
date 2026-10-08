const net = require("net");
const fs = require("fs");
const path = require("path");

const configPath = path.resolve(__dirname, "../config.json");
if (!fs.existsSync(configPath)) {
  console.error("❌ config.json not found!");
  process.exit(1);
}

const config = JSON.parse(fs.readFileSync(configPath, "utf-8"));
const statePath = path.resolve(__dirname, `../${config.options?.syncStateFile || "sync-state.json"}`);

function checkTcpSocket(ip, port, timeoutMs = 3000) {
  return new Promise((resolve) => {
    const socket = new net.Socket();
    let isConnected = false;

    socket.setTimeout(timeoutMs);

    socket.on("connect", () => {
      isConnected = true;
      socket.destroy();
      resolve({ ok: true });
    });

    socket.on("timeout", () => {
      socket.destroy();
      resolve({ ok: false, error: "Connection timed out" });
    });

    socket.on("error", (err) => {
      socket.destroy();
      resolve({ ok: false, error: err.message });
    });

    socket.connect(port, ip);
  });
}

async function checkCloudHealth(apiUrl, branchId) {
  try {
    const baseUrl = apiUrl.replace(/\/biometric-push$/, "");
    const healthUrl = `${baseUrl}/biometric-health?branchId=${branchId || ""}`;
    const res = await fetch(healthUrl, { headers: { "User-Agent": "Satyakiran-HealthCheck/1.0" } });
    if (!res.ok) {
      return { ok: false, status: res.status, error: `HTTP ${res.status} ${res.statusText}` };
    }
    const data = await res.json();
    return { ok: true, data };
  } catch (err) {
    return { ok: false, error: err.message };
  }
}

async function checkLocalDaemon(port = 5006) {
  try {
    const res = await fetch(`http://localhost:${port}/health`, { signal: AbortSignal.timeout(1500) });
    if (!res.ok) return { running: false };
    const data = await res.json();
    return { running: true, data };
  } catch {
    return { running: false };
  }
}

async function main() {
  console.log("\n=======================================================");
  console.log("🩺 Satyakiran Biometric System Health Diagnostic");
  console.log("=======================================================");
  console.log(`⏱️  Timestamp: ${new Date().toLocaleString("en-IN", { timeZone: "Asia/Kolkata" })}`);
  console.log(`🏢 Branch ID: ${config.cloud.branchId}`);
  console.log(`📟 Target Machine: ${config.machine.deviceName} (${config.machine.ip}:${config.machine.port})`);
  console.log("-------------------------------------------------------");

  // 1. Check Local Biometric Machine Connectivity
  process.stdout.write("1️⃣  Checking Biometric Machine Socket... ");
  const machineCheck = await checkTcpSocket(config.machine.ip, config.machine.port, 3000);
  if (machineCheck.ok) {
    console.log("✅ ONLINE (Port reachable)");
  } else {
    console.log(`❌ OFFLINE (${machineCheck.error})`);
  }

  // 2. Check Local Bridge Agent Status
  process.stdout.write("2️⃣  Checking Local Agent Daemon (Port 5006)... ");
  const daemonCheck = await checkLocalDaemon(5006);
  if (daemonCheck.running) {
    console.log("✅ RUNNING");
  } else {
    console.log("⚠️  NOT RUNNING ON PORT 5006 (Background daemon idle or port free)");
  }

  // 3. Check Local Sync Memory State
  process.stdout.write("3️⃣  Checking Local Sync History Memory... ");
  let state = { totalSyncedCount: 0, lastSyncAt: "Never" };
  if (fs.existsSync(statePath)) {
    try {
      const raw = fs.readFileSync(statePath, "utf-8").replace(/^\uFEFF/, "");
      state = JSON.parse(raw);
      console.log(`✅ OK (${state.totalSyncedCount || 0} punches in memory)`);
    } catch {
      console.log("⚠️ Corrupted sync-state file");
    }
  } else {
    console.log("⚠️ No sync-state.json file yet");
  }

  // 4. Check Cloud Biometric Service Health
  process.stdout.write("4️⃣  Checking Satyakiran AWS Cloud Service... ");
  const cloudHealth = await checkCloudHealth(config.cloud.apiUrl, config.cloud.branchId);

  if (cloudHealth.ok && cloudHealth.data) {
    console.log(`✅ ${cloudHealth.data.status || "CONNECTED"}`);
    console.log("-------------------------------------------------------");
    console.log("☁️  CLOUD ATTENDANCE & 2-WAY STATUS:");
    console.log(`   • System State:        ${cloudHealth.data.status}`);
    console.log(`   • Message:             ${cloudHealth.data.message}`);
    console.log(`   • Punches Today:       ${cloudHealth.data.stats?.punchesToday ?? "N/A"}`);
    console.log(`   • Total Records:       ${cloudHealth.data.stats?.totalBiometricRecords ?? "N/A"}`);
    if (cloudHealth.data.latestPunch) {
      const p = cloudHealth.data.latestPunch;
      console.log(`   • Latest Punch:        Emp #${p.employeeCode} (${p.employeeName}) at ${new Date(p.punchTime).toLocaleTimeString("en-IN")}`);
      console.log(`   • Latest Punch Seen:   ~${p.minutesAgo} min ago from ${p.device}`);
    }
    console.log(`   • 2-Way Queue:         ${cloudHealth.data.twoWayCommands?.pending ?? 0} Pending | ${cloudHealth.data.twoWayCommands?.completed ?? 0} Completed`);
  } else {
    console.log(`❌ FAILED (${cloudHealth.error || "No response"})`);
  }

  console.log("=======================================================\n");
}

main().catch(console.error);
