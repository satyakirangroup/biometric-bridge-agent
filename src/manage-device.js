/**
 * ================================================================
 *  SATYAKIRAN BIOMETRIC - MANUAL DEVICE MANAGER
 *  Directly push/pull employees to/from the biometric hardware.
 *  Bypasses the cloud command queue — works offline too!
 *
 *  Usage: node src/manage-device.js
 *  Or:    manage-device.bat
 * ================================================================
 */
const readline = require("readline");
const fs = require("fs");
const path = require("path");
const SbxpcConnector = require("./sbxpc-connector");

// Load config
const configPath = path.resolve(__dirname, "../config.json");
if (!fs.existsSync(configPath)) {
  console.error("config.json not found!");
  process.exit(1);
}
const config = JSON.parse(fs.readFileSync(configPath, "utf-8"));
const connector = new SbxpcConnector(config.machine);
const rl = readline.createInterface({ input: process.stdin, output: process.stdout });

function ask(prompt) {
  return new Promise((r) => rl.question(prompt, (a) => r(a.trim())));
}
function ts() {
  return new Date().toLocaleTimeString("en-IN", { hour12: false });
}
function log(type, msg) {
  const icons = { OK: "OK  ", ERR: "ERR ", INFO: "INFO", WARN: "WARN", WAIT: "... " };
  console.log("[" + ts() + "] " + (icons[type] || "?   ") + " | " + msg);
}

function printMenu() {
  console.log("\n========================================================");
  console.log("  SATYAKIRAN BIOMETRIC - MANUAL DEVICE MANAGER");
  console.log("  Device : " + config.machine.ip + ":" + config.machine.port);
  console.log("  Name   : " + config.machine.deviceName);
  console.log("========================================================");
  console.log("  1. Add / Create Employee on Device");
  console.log("  2. Get Employee Details (by code)");
  console.log("  3. List ALL Enrolled Employees");
  console.log("  4. Update Employee Info");
  console.log("  5. Delete Employee from Device");
  console.log("  6. Enable Employee (allow punching)");
  console.log("  7. Disable Employee (block punching)");
  console.log("  8. Sync Device Clock with PC Time");
  console.log("  9. Test Device Connection");
  console.log("  0. Exit\n");
}

async function main() {
  printMenu();
  while (true) {
    const choice = await ask("  Enter choice (0-9): ");
    try {
      if (choice === "1") {
        // --- CREATE ---
        const code = await ask("  Employee Code (number, e.g. 101): ");
        if (!code || isNaN(+code)) { log("ERR", "Invalid code. Must be a number."); continue; }
        const name = await ask("  Employee Name: ");
        const priv = await ask("  Privilege [0=Normal, 6=Admin] (default 0): ");
        log("WAIT", "Creating employee #" + code + " on device...");
        const r = await connector.setUser(code, name, isNaN(+priv) ? 0 : +priv, 1);
        log("OK", "Employee #" + code + " CREATED successfully! Result: " + JSON.stringify(r));

      } else if (choice === "2") {
        // --- READ SINGLE ---
        const code = await ask("  Employee Code: ");
        log("WAIT", "Fetching details for #" + code + "...");
        const u = await connector.getUser(code);
        console.log("  Code    : " + (u.employeeCode || code));
        console.log("  Name    : " + (u.employeeName || "(no name)"));
        console.log("  Priv    : " + (u.privilege || 0));
        console.log("  Enabled : " + (u.enabled !== false ? "Yes" : "No"));

      } else if (choice === "3") {
        // --- LIST ALL ---
        log("WAIT", "Reading all employees from device (takes 10-30s)...");
        const users = await connector.getUsers();
        log("OK", "Total enrolled: " + users.length);
        console.log("");
        console.log("  No. | Code      | Name                    | Enabled");
        console.log("  ----|-----------|-------------------------|--------");
        users.forEach(function(u, i) {
          var n  = String(i + 1).padEnd(3);
          var c  = String(u.employeeCode || u.EnrollNumber || "?").padEnd(10);
          var nm = String(u.employeeName || "(no name)").padEnd(24);
          var en = u.enabled !== false ? "Yes" : "No";
          console.log("  " + n + " | " + c + "| " + nm + "| " + en);
        });
        var logsDir = path.resolve(__dirname, "../logs");
        if (!fs.existsSync(logsDir)) fs.mkdirSync(logsDir, { recursive: true });
        fs.writeFileSync(path.join(logsDir, "enrolled_employees.json"), JSON.stringify(users, null, 2), "utf-8");
        log("INFO", "Saved to logs/enrolled_employees.json");

      } else if (choice === "4") {
        // --- UPDATE ---
        const code = await ask("  Employee Code to update: ");
        var cur = {};
        try { cur = await connector.getUser(code); log("INFO", "Current: Name=" + (cur.employeeName || "") + " Priv=" + (cur.privilege || 0)); } catch (e) { log("WARN", "Could not read current data, proceeding fresh."); }
        const name = await ask("  New Name [leave blank to keep current]: ");
        const priv = await ask("  New Privilege [leave blank to keep current]: ");
        var fn = name || cur.employeeName || "";
        var fp = (priv !== "" && !isNaN(+priv)) ? +priv : (cur.privilege || 0);
        log("WAIT", "Updating #" + code + " to Name=\"" + fn + "\" Priv=" + fp + "...");
        await connector.setUser(code, fn, fp, 1);
        log("OK", "Employee #" + code + " UPDATED!");

      } else if (choice === "5") {
        // --- DELETE ---
        const code = await ask("  Employee Code to DELETE: ");
        const cf = await ask("  Type YES to confirm deletion of #" + code + ": ");
        if (cf.toUpperCase() === "YES") {
          log("WAIT", "Deleting #" + code + " from device...");
          await connector.deleteUser(code);
          log("OK", "Employee #" + code + " DELETED from device!");
        } else {
          log("INFO", "Deletion cancelled.");
        }

      } else if (choice === "6") {
        // --- ENABLE ---
        const code = await ask("  Employee Code to ENABLE: ");
        await connector.enableUser(code, 1);
        log("OK", "Employee #" + code + " ENABLED (can punch in/out)!");

      } else if (choice === "7") {
        // --- DISABLE ---
        const code = await ask("  Employee Code to DISABLE: ");
        await connector.enableUser(code, 0);
        log("OK", "Employee #" + code + " DISABLED (blocked from punching)!");

      } else if (choice === "8") {
        // --- SYNC TIME ---
        log("WAIT", "Syncing device clock with PC system time...");
        const r = await connector.syncTime();
        log("OK", "Device clock synced! Result: " + JSON.stringify(r));

      } else if (choice === "9") {
        // --- TEST CONNECTION ---
        log("WAIT", "Testing TCP connection to " + config.machine.ip + ":" + config.machine.port + "...");
        const t = await connector.testTcpConnection(5000);
        if (t.connected) {
          log("OK", "Device ONLINE - " + t.message);
          try {
            const u = await connector.getUsers();
            log("OK", "Device responsive. Enrolled employees: " + u.length);
          } catch (e) {
            log("WARN", "TCP OK but SDK error: " + e.message);
          }
        } else {
          log("ERR", "Device OFFLINE - " + t.message);
        }

      } else if (choice === "0") {
        console.log("\n  Goodbye!\n");
        rl.close();
        process.exit(0);

      } else {
        log("WARN", "Invalid choice '" + choice + "'. Enter 0-9.");
      }
    } catch (err) {
      log("ERR", err.message);
    }

    console.log("");
    const again = await ask("  Press Enter to return to menu (or type 'exit' to quit): ");
    if (again.toLowerCase() === "exit") {
      console.log("\n  Goodbye!\n");
      rl.close();
      process.exit(0);
    }
    printMenu();
  }
}

main().catch(function(e) {
  console.error("Fatal error:", e);
  rl.close();
  process.exit(1);
});