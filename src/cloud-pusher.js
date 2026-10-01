class CloudPusher {
  constructor(config) {
    this.apiUrl = config.apiUrl;
    this.authToken = config.authToken || "satyakiran_biometric_2026";
    this.branchId = config.branchId;
  }

  /**
   * Pushes an array of punch records to the Satyakiran AWS Cloud Webhook.
   * @param {Array<Object>} punches
   * @returns {Promise<{success: boolean, responseData?: any, error?: string}>}
   */
  async pushPunches(punches) {
    if (!punches || punches.length === 0) {
      return { success: true, count: 0 };
    }

    try {
      const payload = punches.map((p) => ({
        employeeCode: String(p.employeeCode || p.Empcode || p.tatempcode || p.UserId || "").trim(),
        employeeName: p.employeeName || p.EmployeeName || undefined,
        logDateTime: p.logDateTime || p.LogDateTime || p.punchTime,
        direction: p.direction || p.Direction || "AUTO",
        verificationMode: p.verificationMode || p.VerificationMode || "Face",
        deviceSerial: p.deviceSerial || p.DeviceSerialNo || "Realtime-Hardware",
        deviceName: p.deviceName || p.DeviceName || "Office Biometric",
        branchId: this.branchId
      }));

      const headers = {
        "Content-Type": "application/json",
        "User-Agent": "Satyakiran-Biometric-Bridge-v1.0"
      };

      if (this.authToken) {
        headers["Authorization"] = `Bearer ${this.authToken}`;
      }

      const res = await fetch(this.apiUrl, {
        method: "POST",
        headers,
        body: JSON.stringify(payload)
      });

      if (!res.ok) {
        const errText = await res.text().catch(() => "");
        throw new Error(`HTTP ${res.status} ${res.statusText}: ${errText}`);
      }

      const responseData = await res.json().catch(() => ({}));
      return { success: true, count: payload.length, responseData };
    } catch (err) {
      return { success: false, count: 0, error: err.message };
    }
  }

  /**
   * Ping check to verify cloud API availability.
   */
  async checkCloudHealth() {
    try {
      const healthUrl = this.apiUrl.replace(/\/hrms\/attendance\/.*$/, "/health");
      const res = await fetch(healthUrl, { method: "GET" }).catch(() => null);
      if (res && (res.status === 200 || res.status === 304)) return true;

      const fallbackRes = await fetch(this.apiUrl, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify([])
      }).catch(() => null);
      return Boolean(fallbackRes);
    } catch (err) {
      return false;
    }
  }

  /**
   * 2-Way: Fetches pending hardware commands from cloud.
   */
  async fetchPendingCommands() {
    try {
      const baseUrl = this.apiUrl.replace(/\/biometric-push$/, "");
      const url = `${baseUrl}/biometric-commands?branchId=${this.branchId || ""}`;
      const headers = {
        "Content-Type": "application/json",
        "User-Agent": "Satyakiran-Biometric-Bridge-v1.0"
      };
      if (this.authToken) headers["Authorization"] = `Bearer ${this.authToken}`;

      const res = await fetch(url, { headers });
      if (!res.ok) return [];
      return await res.json().catch(() => []);
    } catch (err) {
      return [];
    }
  }

  /**
   * 2-Way: Acknowledges command execution status back to the cloud.
   */
  async acknowledgeCommand(commandId, status, error) {
    try {
      const baseUrl = this.apiUrl.replace(/\/biometric-push$/, "");
      const url = `${baseUrl}/biometric-commands/ack`;
      const headers = {
        "Content-Type": "application/json",
        "User-Agent": "Satyakiran-Biometric-Bridge-v1.0"
      };
      if (this.authToken) headers["Authorization"] = `Bearer ${this.authToken}`;

      await fetch(url, {
        method: "POST",
        headers,
        body: JSON.stringify({ commandId, status, error: error || null })
      });
      return true;
    } catch (err) {
      return false;
    }
  }
}

module.exports = CloudPusher;
