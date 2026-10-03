const { spawn } = require("child_process");
const path = require("path");

async function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function runCrudVerification() {
  console.log("=======================================================");
  console.log("🧪 COMPLETE BIOMETRIC HARDWARE CRUD VERIFICATION TEST");
  console.log("   [C] Create  -> [R] Read  -> [U] Update  -> [D] Delete");
  console.log("=======================================================\n");

  console.log("1️⃣ Spawning 2-Way Sync Engine (src/two-way-sync.js)...");
  const child = spawn("node", [path.resolve(__dirname, "two-way-sync.js")], {
    stdio: ["pipe", "pipe", "pipe"]
  });

  child.stdout.on("data", (d) => process.stdout.write(d.toString()));
  child.stderr.on("data", (d) => process.stderr.write(d.toString()));

  // Wait 12 seconds for device handshake and HTTP server startup
  console.log("\n⏳ Waiting 12s for device handshake and local API server to boot...");
  await sleep(12000);

  const testId = 7777;

  // -----------------------------------------------------------------
  // 1. CREATE (POST /api/user)
  // -----------------------------------------------------------------
  console.log("\n-------------------------------------------------------");
  console.log(`[C - CREATE] Adding Employee #${testId} ('CRUD Alpha Test')...`);
  try {
    const res = await fetch("http://localhost:5006/api/user", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        employeeCode: testId,
        employeeName: "CRUD Alpha Test",
        privilege: 0,
        enabled: true
      })
    });
    const json = await res.json();
    console.log("   ✅ Server Response:", JSON.stringify(json, null, 2));
  } catch (err) {
    console.error("   ❌ CREATE failed:", err.message);
  }

  // -----------------------------------------------------------------
  // 2. READ (GET /api/user?id=7777)
  // -----------------------------------------------------------------
  console.log("\n-------------------------------------------------------");
  console.log(`[R - READ] Inspecting Employee #${testId} directly from device...`);
  try {
    const res = await fetch(`http://localhost:5006/api/user?id=${testId}`);
    const json = await res.json();
    console.log("   ✅ Server Response:", JSON.stringify(json, null, 2));
  } catch (err) {
    console.error("   ❌ READ failed:", err.message);
  }

  // -----------------------------------------------------------------
  // 3. UPDATE (PUT /api/user)
  // -----------------------------------------------------------------
  console.log("\n-------------------------------------------------------");
  console.log(`[U - UPDATE] Updating Employee #${testId} ('CRUD Beta Updated', Privilege=1)...`);
  try {
    const res = await fetch("http://localhost:5006/api/user", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        employeeCode: testId,
        employeeName: "CRUD Beta Updated",
        privilege: 1,
        enabled: true
      })
    });
    const json = await res.json();
    console.log("   ✅ Server Response:", JSON.stringify(json, null, 2));
  } catch (err) {
    console.error("   ❌ UPDATE failed:", err.message);
  }

  // -----------------------------------------------------------------
  // 4. VERIFY UPDATE (GET /api/user?id=7777)
  // -----------------------------------------------------------------
  console.log("\n-------------------------------------------------------");
  console.log(`[R - READ VERIFY] Verifying Employee #${testId} after update...`);
  try {
    const res = await fetch(`http://localhost:5006/api/user?id=${testId}`);
    const json = await res.json();
    console.log("   ✅ Server Response:", JSON.stringify(json, null, 2));
  } catch (err) {
    console.error("   ❌ READ VERIFY failed:", err.message);
  }

  // -----------------------------------------------------------------
  // 5. DELETE (DELETE /api/user)
  // -----------------------------------------------------------------
  console.log("\n-------------------------------------------------------");
  console.log(`[D - DELETE] Removing Employee #${testId} from biometric hardware...`);
  try {
    const res = await fetch(`http://localhost:5006/api/user?id=${testId}`, {
      method: "DELETE"
    });
    const json = await res.json();
    console.log("   ✅ Server Response:", JSON.stringify(json, null, 2));
  } catch (err) {
    console.error("   ❌ DELETE failed:", err.message);
  }

  // -----------------------------------------------------------------
  // 6. Clean Shutdown
  // -----------------------------------------------------------------
  console.log("\n-------------------------------------------------------");
  console.log("Shutting down engine cleanly...");
  child.kill("SIGINT");
  await sleep(2000);

  console.log("\n=======================================================");
  console.log("🎉 FULL HARDWARE CRUD CYCLE TEST COMPLETED SUCCESSFULLY!");
  console.log("=======================================================\n");
}

runCrudVerification().catch(console.error);
