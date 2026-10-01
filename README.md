# 🏢 Satyakiran Biometric Cloud Bridge Agent (Node.js)

Standalone, Zero-Third-Party-Cost Windows Bridge Agent to connect **Realtime Biometric Hardware (T501, RS9W, T304f, RS910)** directly to **Satyakiran AWS Cloud Database (`api.satyakiran.co.in`)**.

---

## 🌟 Key Features
- **100% Free & Independent**: No monthly/yearly paid third-party cloud subscription required.
- **Zero Data Loss on Laptop Shutdown**: When the office laptop is closed or turned off at night, punches stay stored in the biometric machine's 100,000-log flash memory. When the laptop boots in the morning, the agent automatically catches up and pushes all pending punches to the cloud.
- **Automatic De-duplication**: Tracks `sync-state.json` so duplicate punches are never sent twice.
- **Instant Live Attendance**: Syncs new punches every 30 seconds to [app.satyakiran.co.in/ems/attendance](https://app.satyakiran.co.in/ems/attendance).
- **1-Click Auto-Start**: Starts silently in the background when Windows boots.

---

## 🚀 Quick Setup on Client's Windows Laptop

### 1. Prerequisites
1. **Node.js**: Install Node.js LTS from [nodejs.org](https://nodejs.org) (version 18 or higher).
2. **SDK DLL Registration**:
   - Extract the SDK folder (`T501MiNi,T304fMini,RS9W,T304f+,RS910`).
   - Right-click `_install_sbxpc.bat` and choose **"Run as Administrator"**.

### 2. Configure `config.json`
Open `config.json` in Notepad and verify the machine IP:
```json
{
  "machine": {
    "ip": "192.168.1.224",
    "port": 5005,
    "machineNumber": 1,
    "password": 0
  },
  "cloud": {
    "apiUrl": "https://api.satyakiran.co.in/api/v1/hrms/attendance/biometric-push",
    "authToken": "satyakiran_biometric_2026",
    "branchId": "0fe39d99-31fb-4753-aa6c-704499bdbba9",
    "syncIntervalSeconds": 30
  }
}
```

### 3. Run Connection Test
Double click or run:
```cmd
npm run test-connection
```
This tests both the biometric device IP reachability and the AWS cloud webhook.

### 4. Start the Agent
Double click **`start-agent.bat`**.

### 5. Enable Auto-Start on Windows Boot
Double click **`install-autostart.bat`**.
That's it! The agent will now run automatically whenever the laptop is turned on.
