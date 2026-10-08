const fs = require("fs");
const path = require("path");

class StateManager {
  constructor(filePath) {
    this.filePath = path.resolve(filePath || "./sync-state.json");
    this.state = {
      lastSyncAt: null,
      lastLogTimestamp: null,
      syncedSignatures: {},
      totalSyncedCount: 0
    };
    this.load();
  }

  load() {
    try {
      if (fs.existsSync(this.filePath)) {
        const raw = fs.readFileSync(this.filePath, "utf-8").replace(/^\uFEFF/, "");
        this.state = JSON.parse(raw);
        if (!this.state.syncedSignatures) this.state.syncedSignatures = {};
      }
    } catch (err) {
      console.warn(`[StateManager] Warning loading state: ${err.message}. Starting fresh.`);
    }
  }

  save() {
    try {
      // Keep only recent 5000 signatures to prevent file bloat
      const keys = Object.keys(this.state.syncedSignatures);
      if (keys.length > 5000) {
        const trimmed = {};
        for (const k of keys.slice(-4000)) {
          trimmed[k] = this.state.syncedSignatures[k];
        }
        this.state.syncedSignatures = trimmed;
      }

      fs.writeFileSync(this.filePath, JSON.stringify(this.state, null, 2), "utf-8");
    } catch (err) {
      console.error(`[StateManager] Failed to save state file: ${err.message}`);
    }
  }

  getSignature(log) {
    const code = String(log.employeeCode || log.Empcode || "").trim();
    const time = String(log.logDateTime || log.LogDateTime || "").trim();
    return `${code}_${time}`;
  }

  isAlreadySynced(log) {
    const sig = this.getSignature(log);
    return Boolean(this.state.syncedSignatures[sig]);
  }

  markSynced(logs) {
    for (const log of logs) {
      const sig = this.getSignature(log);
      this.state.syncedSignatures[sig] = Date.now();
      this.state.totalSyncedCount = (this.state.totalSyncedCount || 0) + 1;
      this.state.lastLogTimestamp = log.logDateTime || log.LogDateTime || this.state.lastLogTimestamp;
    }
    this.state.lastSyncAt = new Date().toISOString();
    this.save();
  }
}

module.exports = StateManager;
