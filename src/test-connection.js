const fs = require("fs");
const path = require("path");
const SbxpcConnector = require("./sbxpc-connector");
const CloudPusher = require("./cloud-pusher");

async function runDiagnostics() {
  console.log("\n=======================================================");
  console.log("🔍 Satyakiran Biometric Bridge — Connection Diagnostics");
  console.log("=======================================================\n");

  const configPath = path.resolve(__dirname, "../config.json");
  if (!fs.existsSync(configPath)) {
    console.error("❌ config.json not found!");
    process.exit(1);
  }

  const config = JSON.parse(fs.readFileSync(configPath, "utf-8"));
  console.log(`📋 Machine Target: ${config.machine.ip}:${config.machine.port}`);
  console.log(`☁️  Cloud Endpoint: ${config.cloud.apiUrl}\n`);

  // 1. Test Hardware TCP Port
  console.log("⏳ Step 1: Testing Biometric Device TCP connection...");
  const connector = new SbxpcConnector(config.machine);
  const tcpResult = await connector.testTcpConnection(5000);

  if (tcpResult.connected) {
    console.log(`   ✅ Biometric Machine is REACHABLE at ${config.machine.ip}:${config.machine.port}`);
  } else {
    console.log(`   ❌ Cannot connect to machine: ${tcpResult.message}`);
    console.log(`      💡 Tip: Check if the device is ON and connected to the same WiFi/LAN router.`);
  }

  // 2. Test AWS Cloud API
  console.log("\n⏳ Step 2: Testing Satyakiran AWS Cloud Webhook...");
  const pusher = new CloudPusher(config.cloud);
  const cloudHealthy = await pusher.checkCloudHealth();

  if (cloudHealthy) {
    console.log(`   ✅ Satyakiran AWS Cloud API is ONLINE and responding`);
  } else {
    console.log(`   ⚠️  Cloud API responded with unexpected status. Check internet connection.`);
  }

  console.log("\n=======================================================");
  if (tcpResult.connected && cloudHealthy) {
    console.log("🎉 ALL SYSTEMS OPERATIONAL! Ready to start bridge service.");
  } else {
    console.log("⚠️  Please resolve the network warnings above before running.");
  }
  console.log("=======================================================\n");
}

runDiagnostics().catch(console.error);
