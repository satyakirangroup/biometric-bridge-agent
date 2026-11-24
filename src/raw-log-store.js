const fs = require("fs");
const path = require("path");

/**
 * Permanent, date-wise archive of every punch the agent has ever read from the
 * machine: logs/raw_machine_punches.json (+ a matching .csv).
 *
 * Unlike the machine's own memory (which can be cleared or overflow), this file
 * only ever grows: each cycle merges the machine's current records into it,
 * de-duplicated by employeeCode + logDateTime. Day buckets use the machine's own
 * wall-clock date (the first 10 chars of logDateTime), so no timezone shift.
 *
 * File shape:
 * {
 *   "updatedAt": "...", "totalPunches": 1234, "totalDays": 30,
 *   "dates": { "2026-10-10": { "totalPunches": 14, "employees": 14, "punches": [ {...}, ... ] }, ... }  // newest day first
 * }
 */
class RawLogStore {
  constructor(logsDir) {
    this.logsDir = logsDir;
    this.jsonPath = path.join(logsDir, "raw_machine_punches.json");
    this.csvPath = path.join(logsDir, "raw_machine_punches.csv");
    this.byKey = new Map();
    this._load();
  }

  _key(p) {
    return `${String(p.employeeCode ?? "").trim()}_${String(p.logDateTime ?? "").trim()}`;
  }

  _load() {
    try {
      if (!fs.existsSync(this.jsonPath)) return;
      const parsed = JSON.parse(fs.readFileSync(this.jsonPath, "utf-8"));
      // Older agent versions wrote a flat array of punches — keep those too.
      const flat = Array.isArray(parsed)
        ? parsed
        : Object.values(parsed.dates || {}).flatMap((d) => d.punches || []);
      for (const p of flat) this.byKey.set(this._key(p), p);
    } catch (err) {
      // A corrupt file must not stop syncing: keep a copy and start a fresh archive.
      try {
        fs.copyFileSync(this.jsonPath, `${this.jsonPath}.corrupt-${Date.now()}`);
      } catch {}
    }
  }

  /** Merge punches into the archive and rewrite the files. Returns how many were new. */
  add(punches) {
    let added = 0;
    for (const p of punches || []) {
      if (!p || !p.logDateTime) continue;
      const k = this._key(p);
      if (!this.byKey.has(k)) {
        this.byKey.set(k, {
          employeeCode: p.employeeCode,
          employeeName: p.employeeName || "",
          logDateTime: p.logDateTime,
          direction: p.direction,
          verificationMode: p.verificationMode,
          deviceSerial: p.deviceSerial,
          deviceName: p.deviceName
        });
        added++;
      }
    }
    if (added > 0 || !fs.existsSync(this.jsonPath)) this._write();
    return added;
  }

  _write() {
    fs.mkdirSync(this.logsDir, { recursive: true });
    const all = [...this.byKey.values()].sort((a, b) => String(a.logDateTime).localeCompare(String(b.logDateTime)));

    const days = new Map();
    for (const p of all) {
      const day = String(p.logDateTime).slice(0, 10);
      if (!days.has(day)) days.set(day, []);
      days.get(day).push(p);
    }
    const dates = {};
    for (const day of [...days.keys()].sort().reverse()) {
      const punches = days.get(day);
      dates[day] = {
        totalPunches: punches.length,
        employees: new Set(punches.map((p) => p.employeeCode)).size,
        punches
      };
    }

    const out = { updatedAt: new Date().toISOString(), totalPunches: all.length, totalDays: days.size, dates };
    this._atomicWrite(this.jsonPath, JSON.stringify(out, null, 2));

    const csv = ["Date,EmployeeCode,EmployeeName,LogDateTime,Direction,VerificationMode,DeviceSerial,DeviceName"];
    for (const day of Object.keys(dates)) {
      for (const p of dates[day].punches) {
        csv.push(`${day},${p.employeeCode},"${p.employeeName || ""}",${p.logDateTime},${p.direction ?? ""},${p.verificationMode ?? ""},${p.deviceSerial ?? ""},"${p.deviceName || ""}"`);
      }
    }
    this._atomicWrite(this.csvPath, csv.join("\n"));
  }

  // Write to a temp file then rename, so a crash mid-write can't corrupt the archive.
  _atomicWrite(file, content) {
    const tmp = `${file}.tmp`;
    fs.writeFileSync(tmp, content, "utf-8");
    fs.renameSync(tmp, file);
  }
}

module.exports = RawLogStore;
