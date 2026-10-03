const fs = require("fs");
const path = require("path");
const SbxpcConnector = require("./sbxpc-connector");

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
  const connector = new SbxpcConnector(machine);

  console.log(`Connecting to Machine: ${machine.ip}:${machine.port} (ID: ${machine.machineNumber})...\n`);

  try {
    const data = await connector.inspectMachine();

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
    }

    // Save summary
    const logsDir = path.resolve(__dirname, "../logs");
    if (!fs.existsSync(logsDir)) fs.mkdirSync(logsDir, { recursive: true });
    fs.writeFileSync(path.join(logsDir, "machine_inventory.json"), JSON.stringify(data, null, 2), "utf-8");
    console.log(`\n💾 Saved detailed report to: logs/machine_inventory.json`);
    console.log("=======================================================\n");
  } catch (err) {
    console.error("❌ Inspection Error:", err.message);
    console.log("\n💡 Note: Make sure other sync windows are not currently holding port 5005.");
    process.exit(1);
  }
}

inspectMachine().catch(console.error);
