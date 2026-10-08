using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using sbxpc;

namespace SatyakiranAgent
{
    class Program
    {
        const string Version = "1.0.0";
        const string TaskName = "SatyakiranBridge";
        const string MutexName = "Global\\SatyakiranBiometricAgentMutex";

        static string BaseDir = AppDomain.CurrentDomain.BaseDirectory;
        static string ExePath = Process.GetCurrentProcess().MainModule.FileName;
        static string ConfigFile = Path.Combine(BaseDir, "config.json");
        static string LogDir = Path.Combine(BaseDir, "logs");

        static Config RootConfig;
        static StateManager State;
        static HttpListener HealthListener;
        static Thread HealthThread;
        static bool IsRunning = true;

        static int Main(string[] args)
        {
            ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072; // TLS 1.2
            EnsureDirectories();

            string cmd = args.Length > 0 ? args[0].ToLowerInvariant().TrimStart('-', '/') : "run";

            switch (cmd)
            {
                case "install":
                case "setup":
                    return DoInstall();

                case "uninstall":
                case "remove":
                    return DoUninstall();

                case "status":
                    return DoStatus();

                case "test":
                case "check":
                    return DoTest();

                case "sync-once":
                    return DoSyncOnce();

                case "bg":
                case "background":
                    return DoRun(true);

                case "run":
                default:
                    return DoRun(false);
            }
        }

        static void EnsureDirectories()
        {
            try
            {
                if (!Directory.Exists(LogDir)) Directory.CreateDirectory(LogDir);
            }
            catch { }
        }

        #region Logging
        static void Log(string level, string message)
        {
            string ts = DateTime.Now.ToString("HH:mm:ss");
            string icon = "🔹";
            ConsoleColor col = ConsoleColor.White;

            if (level == "SUCCESS") { icon = "✅"; col = ConsoleColor.Green; }
            else if (level == "WARN") { icon = "⚠️"; col = ConsoleColor.Yellow; }
            else if (level == "ERROR") { icon = "❌"; col = ConsoleColor.Red; }
            else if (level == "INFO") { icon = "🔹"; col = ConsoleColor.Cyan; }

            string line = string.Format("[{0}] {1} {2}", ts, icon, message);

            try
            {
                var prev = Console.ForegroundColor;
                Console.ForegroundColor = col;
                Console.WriteLine(line);
                Console.ForegroundColor = prev;
            }
            catch
            {
                Console.WriteLine(line);
            }

            try
            {
                string logFile = Path.Combine(LogDir, string.Format("agent-{0:yyyyMMdd}.log", DateTime.Now));
                File.AppendAllText(logFile, string.Format("{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}\r\n", DateTime.Now, level, message), Encoding.UTF8);
            }
            catch { }
        }
        #endregion

        #region Configuration & State
        static bool LoadConfiguration()
        {
            if (!File.Exists(ConfigFile))
            {
                Log("ERROR", "config.json not found in " + BaseDir);
                return false;
            }

            try
            {
                string json = File.ReadAllText(ConfigFile, Encoding.UTF8);
                var jss = new JavaScriptSerializer();
                RootConfig = jss.Deserialize<Config>(json);
                if (RootConfig.machine == null) RootConfig.machine = new MachineConfig();
                if (RootConfig.cloud == null) RootConfig.cloud = new CloudConfig();
                if (RootConfig.options == null) RootConfig.options = new OptionsConfig();

                if (string.IsNullOrEmpty(RootConfig.options.syncStateFile))
                {
                    RootConfig.options.syncStateFile = Path.Combine(BaseDir, "sync-state.json");
                }
                else if (!Path.IsPathRooted(RootConfig.options.syncStateFile))
                {
                    RootConfig.options.syncStateFile = Path.Combine(BaseDir, RootConfig.options.syncStateFile);
                }

                State = new StateManager(RootConfig.options.syncStateFile);
                return true;
            }
            catch (Exception ex)
            {
                Log("ERROR", "Failed to parse config.json: " + ex.Message);
                return false;
            }
        }
        #endregion

        #region Core Runner
        static int DoRun(bool background)
        {
            bool createdNew;
            Mutex appMutex = new Mutex(true, MutexName, out createdNew);
            if (!createdNew)
            {
                if (!background)
                {
                    Console.WriteLine("\n[WARN] Satyakiran Biometric Agent is already running in background!");
                    Console.WriteLine("       Run 'SatyakiranBiometricAgent.exe status' to view live status.\n");
                }
                return 0;
            }

            if (!LoadConfiguration()) return 1;

            if (!background)
            {
                Console.Clear();
                Console.WriteLine("=======================================================");
                Console.WriteLine("🚀 Satyakiran Biometric Cloud Bridge Agent v" + Version);
                Console.WriteLine("   100% Native Windows Biometric to AWS Integration");
                Console.WriteLine("=======================================================");
                Console.WriteLine("🏢 Branch       : " + RootConfig.cloud.branchId);
                Console.WriteLine("📟 Machine      : " + RootConfig.machine.ip + ":" + RootConfig.machine.port + " (No: " + RootConfig.machine.machineNumber + ")");
                Console.WriteLine("☁️  AWS Cloud    : " + RootConfig.cloud.apiUrl);
                Console.WriteLine("⏱️  Poll Interval: " + RootConfig.cloud.syncIntervalSeconds + " seconds");
                Console.WriteLine("💾 Total Synced : " + State.TotalSyncedCount + " records");
                Console.WriteLine("⚡ 2-Way Sync   : ACTIVE (Cloud <-> Hardware)");
                Console.WriteLine("=======================================================\n");
            }

            StartHealthServer(5006);

            Console.CancelKeyPress += delegate(object sender, ConsoleCancelEventArgs e)
            {
                e.Cancel = true;
                IsRunning = false;
                Log("INFO", "Shutting down Satyakiran Biometric Agent cleanly...");
            };

            Log("INFO", "Starting initial sync cycle...");
            PerformSyncCycle();

            int intervalMs = Math.Max(5, RootConfig.cloud.syncIntervalSeconds) * 1000;
            Log("INFO", "Continuous sync active. Polling device every " + RootConfig.cloud.syncIntervalSeconds + "s...\n");

            while (IsRunning)
            {
                Thread.Sleep(intervalMs);
                if (!IsRunning) break;
                PerformSyncCycle();
            }

            StopHealthServer();
            appMutex.ReleaseMutex();
            return 0;
        }

        static void PerformSyncCycle()
        {
            try
            {
                // 1. Process 2-way cloud remote commands (create/delete users, sync time, etc.)
                ProcessPendingCommands();

                // 2. Fetch raw logs from machine
                List<PunchRecord> rawLogs = FetchHardwareLogs();
                if (rawLogs == null)
                {
                    // Device unreachable or busy
                    return;
                }

                if (rawLogs.Count == 0)
                {
                    Log("INFO", string.Format("📡 Machine polled ({0}:{1}) — 0 punch records in memory.", RootConfig.machine.ip, RootConfig.machine.port));
                    return;
                }

                // Auto-save local snapshot
                SaveRawSnapshot(rawLogs);

                // 3. Filter out already-synced punches
                List<PunchRecord> newLogs = new List<PunchRecord>();
                foreach (var log in rawLogs)
                {
                    if (!State.IsAlreadySynced(log.employeeCode, log.logDateTime))
                    {
                        newLogs.Add(log);
                    }
                }

                if (newLogs.Count == 0)
                {
                    Log("INFO", string.Format("📡 Machine online ({0}:{1}) | Total records: {2} | Synced: {3} | ⚡ 2-Way Active",
                        RootConfig.machine.ip, RootConfig.machine.port, rawLogs.Count, State.TotalSyncedCount));
                    return;
                }

                Log("INFO", string.Format("🔥 Detected {0} new punch record(s) on biometric device! Preparing push...", newLogs.Count));

                // 4. Batch push to Satyakiran AWS Cloud
                int batchSize = RootConfig.options.maxBatchSize > 0 ? RootConfig.options.maxBatchSize : 100;
                for (int i = 0; i < newLogs.Count; i += batchSize)
                {
                    int count = Math.Min(batchSize, newLogs.Count - i);
                    var batch = newLogs.GetRange(i, count);

                    bool pushed = PushPunchesToCloud(batch);
                    if (pushed)
                    {
                        State.MarkSynced(batch);
                        Log("SUCCESS", string.Format("Successfully pushed {0} punch(es) to Satyakiran Cloud! (Total Synced: {1})", batch.Count, State.TotalSyncedCount));

                        // Preview first 2 punches
                        int previewCount = Math.Min(2, batch.Count);
                        for (int p = 0; p < previewCount; p++)
                        {
                            var r = batch[p];
                            string display = !string.IsNullOrEmpty(r.employeeName) ? string.Format("{0} (#{1})", r.employeeName, r.employeeCode) : "#" + r.employeeCode;
                            Console.WriteLine(string.Format("      👤 Emp: {0} | Time: {1} | Mode: {2}", display, r.logDateTime, r.verificationMode));
                        }
                    }
                    else
                    {
                        Log("ERROR", "Failed to push batch to cloud. Will retry next cycle.");
                        break;
                    }
                }
            }
            catch (Exception ex)
            {
                Log("WARN", "Sync cycle warning: " + ex.Message);
            }
        }

        static List<PunchRecord> FetchHardwareLogs()
        {
            int machNo = RootConfig.machine.machineNumber;
            string ip = RootConfig.machine.ip;
            int port = RootConfig.machine.port;
            int password = RootConfig.machine.password;
            string devName = RootConfig.machine.deviceName;

            try
            {
                SBXPCDLL.DotNET();
                SBXPCDLL._DisableTranseiveCallback();

                bool conn = SBXPCDLL.ConnectTcpip(machNo, ip, port, password);
                if (!conn)
                {
                    Log("WARN", string.Format("Cannot connect to biometric device at {0}:{1} (offline or busy)", ip, port));
                    return null;
                }

                try
                {
                    var empMap = LoadEmployeeMap();

                    SBXPCDLL.EnableDevice(machNo, 0);
                    try
                    {
                        bool hasLogs = SBXPCDLL.ReadAllGLogData(machNo);
                        if (!hasLogs)
                        {
                            hasLogs = SBXPCDLL.ReadGeneralLogData(machNo, 0);
                        }

                        List<PunchRecord> list = new List<PunchRecord>();
                        int tmno, seno, smno, vmode, yr, mon, day, hr, min, sec;

                        while (true)
                        {
                            bool got = SBXPCDLL.GetAllGLogData(machNo, out tmno, out seno, out smno, out vmode, out yr, out mon, out day, out hr, out min, out sec);
                            if (!got) break;

                            string dtStr = string.Format("{0:D4}-{1:D2}-{2:D2} {3:D2}:{4:D2}:{5:D2}", yr, mon, day, hr, min, sec);
                            string vModeStr = "Face";
                            if (vmode == 1) vModeStr = "Fingerprint";
                            else if (vmode == 2) vModeStr = "Card";
                            else if (vmode == 3) vModeStr = "Password";
                            else if (vmode == 15 || vmode == 407 || vmode == 20) vModeStr = "Face";

                            string senoStr = seno.ToString();
                            string empName = empMap.ContainsKey(senoStr) ? empMap[senoStr] : "";

                            var rec = new PunchRecord();
                            rec.employeeCode = senoStr;
                            rec.employeeName = empName;
                            rec.logDateTime = dtStr;
                            rec.direction = "AUTO";
                            rec.verificationMode = vModeStr;
                            rec.deviceSerial = ip;
                            rec.deviceName = devName;
                            rec.branchId = RootConfig.cloud.branchId;

                            list.Add(rec);
                        }

                        return list;
                    }
                    finally
                    {
                        SBXPCDLL.EnableDevice(machNo, 1);
                    }
                }
                finally
                {
                    try { SBXPCDLL.Disconnect(machNo); } catch { }
                }
            }
            catch (Exception ex)
            {
                Log("ERROR", "Native hardware exception: " + ex.Message);
                return null;
            }
        }

        static bool PushPunchesToCloud(List<PunchRecord> batch)
        {
            try
            {
                var jss = new JavaScriptSerializer();
                string jsonPayload = jss.Serialize(batch);

                var req = (HttpWebRequest)WebRequest.Create(RootConfig.cloud.apiUrl);
                req.Method = "POST";
                req.ContentType = "application/json";
                req.UserAgent = "Satyakiran-Biometric-Agent-v" + Version;
                req.Timeout = 30000;

                if (!string.IsNullOrEmpty(RootConfig.cloud.authToken))
                {
                    req.Headers.Add("Authorization", "Bearer " + RootConfig.cloud.authToken);
                }

                byte[] bytes = Encoding.UTF8.GetBytes(jsonPayload);
                req.ContentLength = bytes.Length;

                using (var stream = req.GetRequestStream())
                {
                    stream.Write(bytes, 0, bytes.Length);
                }

                using (var resp = (HttpWebResponse)req.GetResponse())
                {
                    int status = (int)resp.StatusCode;
                    return (status >= 200 && status < 300);
                }
            }
            catch (WebException wex)
            {
                if (wex.Response != null)
                {
                    var r = (HttpWebResponse)wex.Response;
                    Log("ERROR", string.Format("Cloud API responded HTTP {0} ({1})", (int)r.StatusCode, r.StatusDescription));
                }
                else
                {
                    Log("ERROR", "Cloud API network error: " + wex.Message);
                }
                return false;
            }
            catch (Exception ex)
            {
                Log("ERROR", "Push error: " + ex.Message);
                return false;
            }
        }

        static void SaveRawSnapshot(List<PunchRecord> logs)
        {
            try
            {
                string jsonFile = Path.Combine(LogDir, "raw_machine_punches.json");
                var jss = new JavaScriptSerializer();
                jss.MaxJsonLength = int.MaxValue;
                File.WriteAllText(jsonFile, jss.Serialize(logs), new UTF8Encoding(false));

                string csvFile = Path.Combine(LogDir, "raw_machine_punches.csv");
                StringBuilder csv = new StringBuilder();
                csv.AppendLine("EmployeeCode,EmployeeName,LogDateTime,Direction,VerificationMode,DeviceSerial,DeviceName");
                foreach (var p in logs)
                {
                    csv.AppendLine(string.Format("{0},\"{1}\",{2},{3},{4},{5},\"{6}\"",
                        p.employeeCode, (p.employeeName ?? "").Replace("\"", "\"\""), p.logDateTime, p.direction, p.verificationMode, p.deviceSerial, (p.deviceName ?? "").Replace("\"", "\"\"")));
                }
                File.WriteAllText(csvFile, csv.ToString(), new UTF8Encoding(false));
            }
            catch { }
        }
        #endregion

        #region 2-Way Commands
        static void ProcessPendingCommands()
        {
            try
            {
                string baseAttendanceUrl = RootConfig.cloud.apiUrl;
                if (baseAttendanceUrl.EndsWith("/biometric-push"))
                {
                    baseAttendanceUrl = baseAttendanceUrl.Substring(0, baseAttendanceUrl.Length - "/biometric-push".Length);
                }
                string cmdUrl = baseAttendanceUrl + "/biometric-commands?branchId=" + Uri.EscapeDataString(RootConfig.cloud.branchId);

                var req = (HttpWebRequest)WebRequest.Create(cmdUrl);
                req.Method = "GET";
                req.Timeout = 10000;
                req.UserAgent = "Satyakiran-Biometric-Agent-v" + Version;
                if (!string.IsNullOrEmpty(RootConfig.cloud.authToken))
                {
                    req.Headers.Add("Authorization", "Bearer " + RootConfig.cloud.authToken);
                }

                string json = "";
                using (var resp = (HttpWebResponse)req.GetResponse())
                using (var reader = new StreamReader(resp.GetResponseStream(), Encoding.UTF8))
                {
                    json = reader.ReadToEnd();
                }

                if (string.IsNullOrEmpty(json) || json.Trim() == "[]") return;

                var jss = new JavaScriptSerializer();
                var cmds = jss.Deserialize<List<Dictionary<string, object>>>(json);
                if (cmds == null || cmds.Count == 0) return;

                Log("INFO", string.Format("📩 Received {0} pending hardware command(s) from Satyakiran Cloud!", cmds.Count));

                foreach (var cmd in cmds)
                {
                    string cmdId = cmd.ContainsKey("id") ? cmd["id"].ToString() : (cmd.ContainsKey("commandId") ? cmd["commandId"].ToString() : "");
                    string action = cmd.ContainsKey("action") ? cmd["action"].ToString().ToUpper() : (cmd.ContainsKey("command") ? cmd["command"].ToString().ToUpper() : "");

                    Dictionary<string, object> payload = cmd;
                    if (cmd.ContainsKey("data") && cmd["data"] is Dictionary<string, object>)
                    {
                        payload = (Dictionary<string, object>)cmd["data"];
                    }
                    else if (cmd.ContainsKey("payload") && cmd["payload"] is Dictionary<string, object>)
                    {
                        payload = (Dictionary<string, object>)cmd["payload"];
                    }

                    Log("INFO", string.Format("⚙️ Executing Command [{0}]: {1}...", cmdId, action));

                    try
                    {
                        ExecuteHardwareCommand(action, payload);
                        Log("SUCCESS", string.Format("✅ Command [{0}] executed successfully!", cmdId));
                        AckCommand(baseAttendanceUrl, cmdId, "COMPLETED", null);
                    }
                    catch (Exception ex)
                    {
                        Log("ERROR", string.Format("❌ Failed executing command [{0}]: {1}", cmdId, ex.Message));
                        AckCommand(baseAttendanceUrl, cmdId, "FAILED", ex.Message);
                    }
                }
            }
            catch { }
        }

        static void ExecuteHardwareCommand(string action, Dictionary<string, object> payload)
        {
            int machNo = RootConfig.machine.machineNumber;
            string ip = RootConfig.machine.ip;
            int port = RootConfig.machine.port;
            int password = RootConfig.machine.password;

            SBXPCDLL.DotNET();
            SBXPCDLL._DisableTranseiveCallback();

            bool conn = SBXPCDLL.ConnectTcpip(machNo, ip, port, password);
            if (!conn) throw new ErrorException("Biometric machine offline or unreachable at " + ip + ":" + port);

            try
            {
                SBXPCDLL.EnableDevice(machNo, 0);
                try
                {
                    if (action == "SET_USER" || action == "CREATE_USER")
                    {
                        int empCode = GetIntFromDict(payload, "employeeCode", "enrollNumber", "UserId");
                        string name = GetStringFromDict(payload, "employeeName", "name", "UserName");
                        int priv = GetIntFromDict(payload, "privilege");
                        int enable = 1;

                        SBXPCDLL.SetUserName1(machNo, empCode, name);
                        SBXPCDLL.EnableUser(machNo, empCode, 0, 0, (byte)enable);
                        if (priv >= 0) SBXPCDLL.ModifyPrivilege(machNo, empCode, 0, 0, priv);

                        var map = LoadEmployeeMap();
                        map[empCode.ToString()] = name;
                        SaveEmployeeMap(map);
                    }
                    else if (action == "UPDATE_USER")
                    {
                        int empCode = GetIntFromDict(payload, "employeeCode", "enrollNumber", "UserId");
                        string name = GetStringFromDict(payload, "employeeName", "name", "UserName");
                        int priv = GetIntFromDict(payload, "privilege");

                        SBXPCDLL.SetUserName1(machNo, empCode, name);
                        if (priv >= 0) SBXPCDLL.ModifyPrivilege(machNo, empCode, 0, 0, priv);

                        var map = LoadEmployeeMap();
                        map[empCode.ToString()] = name;
                        SaveEmployeeMap(map);
                    }
                    else if (action == "DELETE_USER" || action == "REMOVE_USER")
                    {
                        int empCode = GetIntFromDict(payload, "employeeCode", "enrollNumber", "UserId");
                        bool res = SBXPCDLL.DeleteEnrollData(machNo, empCode, 0, 12);
                        if (!res) SBXPCDLL.DeleteEnrollData(machNo, empCode, 0, 11);
                        SBXPCDLL.SetUserName1(machNo, empCode, "");
                        SBXPCDLL.EnableUser(machNo, empCode, 0, 0, 0);

                        var map = LoadEmployeeMap();
                        if (map.ContainsKey(empCode.ToString()))
                        {
                            map.Remove(empCode.ToString());
                            SaveEmployeeMap(map);
                        }
                    }
                    else if (action == "ENABLE_USER" || action == "DISABLE_USER")
                    {
                        int empCode = GetIntFromDict(payload, "employeeCode", "enrollNumber", "UserId");
                        byte flag = (byte)(action == "ENABLE_USER" ? 1 : 0);
                        SBXPCDLL.EnableUser(machNo, empCode, 0, 0, flag);
                    }
                    else if (action == "SYNC_TIME")
                    {
                        SBXPCDLL.SetDeviceTime(machNo);
                    }
                    else if (action == "CLEAR_LOGS")
                    {
                        SBXPCDLL.EmptyGeneralLogData(machNo);
                    }
                    else
                    {
                        throw new ErrorException("Unknown action: " + action);
                    }
                }
                finally
                {
                    SBXPCDLL.EnableDevice(machNo, 1);
                }
            }
            finally
            {
                try { SBXPCDLL.Disconnect(machNo); } catch { }
            }
        }

        static void AckCommand(string baseAttendanceUrl, string cmdId, string status, string error)
        {
            try
            {
                string ackUrl = baseAttendanceUrl + "/biometric-commands/ack";
                var req = (HttpWebRequest)WebRequest.Create(ackUrl);
                req.Method = "POST";
                req.ContentType = "application/json";
                req.Timeout = 10000;
                req.UserAgent = "Satyakiran-Biometric-Agent-v" + Version;
                if (!string.IsNullOrEmpty(RootConfig.cloud.authToken))
                {
                    req.Headers.Add("Authorization", "Bearer " + RootConfig.cloud.authToken);
                }

                var ackBody = new Dictionary<string, object>();
                ackBody["commandId"] = cmdId;
                ackBody["status"] = status;
                ackBody["error"] = error;

                var jss = new JavaScriptSerializer();
                byte[] bytes = Encoding.UTF8.GetBytes(jss.Serialize(ackBody));
                req.ContentLength = bytes.Length;

                using (var s = req.GetRequestStream())
                {
                    s.Write(bytes, 0, bytes.Length);
                }
                using (var resp = (HttpWebResponse)req.GetResponse()) { }
            }
            catch { }
        }
        #endregion

        #region Local Health Server
        static void StartHealthServer(int port)
        {
            try
            {
                HealthListener = new HttpListener();
                HealthListener.Prefixes.Add(string.Format("http://+:{0}/", port));
                HealthListener.Start();

                HealthThread = new Thread(HealthLoop);
                HealthThread.IsBackground = true;
                HealthThread.Start();
                Log("INFO", "🌐 Local Health API running on http://localhost:" + port + "/health");
            }
            catch (Exception)
            {
                // Port might be in use or require admin urlacl
                try
                {
                    HealthListener = new HttpListener();
                    HealthListener.Prefixes.Add(string.Format("http://localhost:{0}/", port));
                    HealthListener.Start();
                    HealthThread = new Thread(HealthLoop);
                    HealthThread.IsBackground = true;
                    HealthThread.Start();
                    Log("INFO", "🌐 Local Health API running on http://localhost:" + port + "/health");
                }
                catch { }
            }
        }

        static void HealthLoop()
        {
            while (IsRunning && HealthListener != null && HealthListener.IsListening)
            {
                try
                {
                    var ctx = HealthListener.GetContext();
                    ThreadPool.QueueUserWorkItem(delegate
                    {
                        try
                        {
                            var req = ctx.Request;
                            var res = ctx.Response;
                            res.ContentType = "application/json";
                            res.AddHeader("Access-Control-Allow-Origin", "*");

                            var statusData = new Dictionary<string, object>();
                            statusData["status"] = "RUNNING";
                            statusData["agent"] = "Satyakiran Biometric Bridge Agent";
                            statusData["version"] = Version;
                            statusData["twoWayActive"] = true;

                            var machineData = new Dictionary<string, object>();
                            machineData["ip"] = RootConfig.machine.ip;
                            machineData["port"] = RootConfig.machine.port;
                            machineData["deviceName"] = RootConfig.machine.deviceName;
                            statusData["machine"] = machineData;

                            var stats = new Dictionary<string, object>();
                            stats["totalSynced"] = State.TotalSyncedCount;
                            stats["lastSyncAt"] = State.LastSyncAt;
                            statusData["stats"] = stats;
                            statusData["timestamp"] = DateTime.Now.ToString("o");

                            var jss = new JavaScriptSerializer();
                            byte[] buf = Encoding.UTF8.GetBytes(jss.Serialize(statusData));
                            res.ContentLength64 = buf.Length;
                            res.OutputStream.Write(buf, 0, buf.Length);
                            res.Close();
                        }
                        catch { }
                    });
                }
                catch
                {
                    if (!IsRunning) break;
                }
            }
        }

        static void StopHealthServer()
        {
            try
            {
                if (HealthListener != null)
                {
                    HealthListener.Stop();
                    HealthListener.Close();
                }
            }
            catch { }
        }
        #endregion

        #region CLI Actions (Install, Uninstall, Status, Test, Sync-Once)
        static int DoInstall()
        {
            Console.WriteLine("=======================================================");
            Console.WriteLine("📦 Satyakiran Biometric Bridge - Windows Auto-Start Setup");
            Console.WriteLine("=======================================================\n");

            string exeTarget = ExePath;
            string workingDir = BaseDir;

            // 1. Register in HKCU Registry Run Key (Always works, runs every time Windows starts / user logs in)
            Console.WriteLine("1. Configuring Windows User Auto-Run Registry...");
            try
            {
                using (var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true))
                {
                    if (key != null)
                    {
                        key.SetValue("SatyakiranBiometricAgent", string.Format("\"{0}\" --background", exeTarget));
                        Console.WriteLine("   ✅ Registry auto-start enabled (HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run).");
                    }
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine("   ⚠️ Registry registration warning: " + ex.Message);
            }

            // 2. Register Scheduled Task to run AtStartup as SYSTEM (for 24/7 background boot without login)
            Console.WriteLine("2. Registering Windows Scheduled Task (" + TaskName + ")...");
            string schArgs = string.Format("/create /tn \"{0}\" /tr \"\\\"{1}\\\" --background\" /sc ONSTART /ru \"SYSTEM\" /rl HIGHEST /f", TaskName, exeTarget);

            int exitCode = RunProcess("schtasks.exe", schArgs);
            if (exitCode == 0)
            {
                Console.WriteLine("   ✅ Task registered to start at Windows boot (SYSTEM privileges).");
                RunProcess("schtasks.exe", string.Format("/run /tn \"{0}\"", TaskName));
                Console.WriteLine("   ✅ Scheduled task triggered.");
            }
            else
            {
                Console.WriteLine("   ℹ️ SYSTEM boot task requires Administrator rights (Registry autostart is already active).");
                Console.WriteLine("      Tip: Run install-autostart.bat as Administrator to enable 24/7 boot service without login.");
            }

            // 3. Create Startup Folder shortcut as second safety net
            Console.WriteLine("3. Creating Startup Folder shortcut...");
            try
            {
                string appDataStartup = Environment.GetFolderPath(Environment.SpecialFolder.Startup);
                string lnkPath = Path.Combine(appDataStartup, "SatyakiranBiometricAgent.lnk");
                CreateShortcut(lnkPath, exeTarget, "--background", workingDir, "Satyakiran Biometric Bridge Agent");
                Console.WriteLine("   ✅ User Startup shortcut created: " + lnkPath);
            }
            catch (Exception ex)
            {
                Console.WriteLine("   ⚠️ Startup shortcut: " + ex.Message);
            }

            // 4. Create Desktop shortcut for easy manual status / launch
            try
            {
                string desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
                string lnkDesktop = Path.Combine(desktop, "Satyakiran Biometric Bridge.lnk");
                CreateShortcut(lnkDesktop, exeTarget, "run", workingDir, "Satyakiran Biometric Bridge Control Panel");
                Console.WriteLine("4. Desktop shortcut created: " + lnkDesktop);
            }
            catch { }

            Console.WriteLine("\n=======================================================");
            Console.WriteLine("🎉 SUCCESS! Satyakiran Biometric Bridge is now configured");
            Console.WriteLine("   to start automatically on Windows startup!");
            Console.WriteLine("=======================================================\n");
            return 0;
        }

        static int DoUninstall()
        {
            Console.WriteLine("Removing Satyakiran Biometric Bridge Auto-Start...");

            try
            {
                using (var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true))
                {
                    if (key != null) key.DeleteValue("SatyakiranBiometricAgent", false);
                }
            }
            catch { }

            RunProcess("schtasks.exe", string.Format("/end /tn \"{0}\"", TaskName));
            RunProcess("schtasks.exe", string.Format("/delete /tn \"{0}\" /f", TaskName));

            try
            {
                string appDataStartup = Environment.GetFolderPath(Environment.SpecialFolder.Startup);
                string lnk1 = Path.Combine(appDataStartup, "SatyakiranBiometricAgent.lnk");
                string lnk2 = Path.Combine(appDataStartup, "SatyakiranBiometricBridge.lnk");
                if (File.Exists(lnk1)) File.Delete(lnk1);
                if (File.Exists(lnk2)) File.Delete(lnk2);
            }
            catch { }

            Console.WriteLine("✅ Removed registry auto-start, scheduled task, and startup shortcuts.");
            return 0;
        }

        static int DoStatus()
        {
            LoadConfiguration();

            Console.WriteLine("=======================================================");
            Console.WriteLine("📊 Satyakiran Biometric Bridge - Status Check");
            Console.WriteLine("=======================================================");

            // Check Registry Auto-Run
            bool regConfigured = false;
            try
            {
                using (var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", false))
                {
                    regConfigured = key != null && key.GetValue("SatyakiranBiometricAgent") != null;
                }
            }
            catch { }
            Console.WriteLine("Registry Boot Auto-Run : " + (regConfigured ? "ACTIVE ✅ (Runs automatically on login)" : "NOT CONFIGURED ⚠️"));

            // Check Scheduled Task
            Console.Write("Task Scheduler Boot    : ");
            string queryOut = RunProcessWithOutput("schtasks.exe", string.Format("/query /tn \"{0}\" /fo LIST", TaskName));
            if (queryOut.Contains("Status:") || queryOut.Contains("Ready") || queryOut.Contains("Running"))
            {
                Console.WriteLine("ACTIVE ✅ (SYSTEM Boot Service)");
            }
            else
            {
                Console.WriteLine("Not Registered ℹ️ (Run install-autostart.bat as Admin for boot service)");
            }

            // Check Process
            var procs = Process.GetProcessesByName("SatyakiranBiometricAgent");
            int currPid = Process.GetCurrentProcess().Id;
            int bgCount = 0;
            foreach (var p in procs) { if (p.Id != currPid) bgCount++; }

            Console.WriteLine("Background Agent Runs  : " + (bgCount > 0 ? "YES (Active) ✅" : "NO (Inactive) ⚠️"));
            Console.WriteLine("Biometric Machine IP   : " + RootConfig.machine.ip + ":" + RootConfig.machine.port);
            Console.WriteLine("Cloud Push Endpoint    : " + RootConfig.cloud.apiUrl);
            Console.WriteLine("Total Synced Punches   : " + State.TotalSyncedCount);
            Console.WriteLine("Last Cloud Sync Time   : " + (State.LastSyncAt ?? "Never"));
            Console.WriteLine("=======================================================\n");
            return 0;
        }

        static void CreateShortcut(string lnkPath, string targetPath, string arguments, string workingDir, string description)
        {
            string vbs = Path.Combine(Path.GetTempPath(), "mklnk_" + Guid.NewGuid().ToString("N") + ".vbs");
            string script = string.Format(
                "Set ws = CreateObject(\"WScript.Shell\")\r\n" +
                "Set link = ws.CreateShortcut(\"{0}\")\r\n" +
                "link.TargetPath = \"{1}\"\r\n" +
                "link.Arguments = \"{2}\"\r\n" +
                "link.WorkingDirectory = \"{3}\"\r\n" +
                "link.Description = \"{4}\"\r\n" +
                "link.Save\r\n",
                lnkPath.Replace("\"", "\"\""),
                targetPath.Replace("\"", "\"\""),
                arguments.Replace("\"", "\"\""),
                workingDir.Replace("\"", "\"\""),
                description.Replace("\"", "\"\"")
            );
            File.WriteAllText(vbs, script, Encoding.ASCII);
            RunProcess("cscript.exe", "//nologo \"" + vbs + "\"");
            try { File.Delete(vbs); } catch { }
        }

        static int DoTest()
        {
            if (!LoadConfiguration()) return 1;

            Console.WriteLine("Testing Biometric Bridge connections...\n");

            // 1. Hardware test
            Console.Write("1. Hardware Connect to " + RootConfig.machine.ip + ":" + RootConfig.machine.port + " ... ");
            try
            {
                SBXPCDLL.DotNET();
                SBXPCDLL._DisableTranseiveCallback();
                bool conn = SBXPCDLL.ConnectTcpip(RootConfig.machine.machineNumber, RootConfig.machine.ip, RootConfig.machine.port, RootConfig.machine.password);
                if (conn)
                {
                    Console.WriteLine("SUCCESS ✅ (Hardware Online!)");
                    SBXPCDLL.Disconnect(RootConfig.machine.machineNumber);
                }
                else
                {
                    Console.WriteLine("FAILED ❌ (Device unreachable or busy)");
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine("FAILED ❌ (" + ex.Message + ")");
            }

            // 2. Cloud test
            Console.Write("2. AWS Cloud Webhook at " + RootConfig.cloud.apiUrl + " ... ");
            try
            {
                var req = (HttpWebRequest)WebRequest.Create(RootConfig.cloud.apiUrl);
                req.Method = "POST";
                req.ContentType = "application/json";
                req.Timeout = 10000;
                if (!string.IsNullOrEmpty(RootConfig.cloud.authToken))
                {
                    req.Headers.Add("Authorization", "Bearer " + RootConfig.cloud.authToken);
                }
                byte[] b = Encoding.UTF8.GetBytes("[]");
                req.ContentLength = b.Length;
                using (var s = req.GetRequestStream()) s.Write(b, 0, b.Length);
                using (var resp = (HttpWebResponse)req.GetResponse())
                {
                    Console.WriteLine("SUCCESS ✅ (HTTP " + (int)resp.StatusCode + ")");
                }
            }
            catch (WebException wex)
            {
                if (wex.Response != null)
                {
                    var r = (HttpWebResponse)wex.Response;
                    Console.WriteLine("SUCCESS ✅ (HTTP " + (int)r.StatusCode + ")");
                }
                else
                {
                    Console.WriteLine("FAILED ❌ (" + wex.Message + ")");
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine("FAILED ❌ (" + ex.Message + ")");
            }

            return 0;
        }

        static int DoSyncOnce()
        {
            if (!LoadConfiguration()) return 1;
            Console.WriteLine("Running single sync cycle...\n");
            PerformSyncCycle();
            Console.WriteLine("Single sync completed.");
            return 0;
        }


        static int RunProcess(string exe, string args)
        {
            try
            {
                var psi = new ProcessStartInfo(exe, args);
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                using (var p = Process.Start(psi))
                {
                    p.WaitForExit();
                    return p.ExitCode;
                }
            }
            catch
            {
                return -1;
            }
        }

        static string RunProcessWithOutput(string exe, string args)
        {
            try
            {
                var psi = new ProcessStartInfo(exe, args);
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;
                using (var p = Process.Start(psi))
                {
                    string outStr = p.StandardOutput.ReadToEnd();
                    p.WaitForExit();
                    return outStr;
                }
            }
            catch
            {
                return "";
            }
        }
        #endregion

        #region Helpers & Models
        static Dictionary<string, string> LoadEmployeeMap()
        {
            var map = new Dictionary<string, string>();
            try
            {
                string path = Path.Combine(LogDir, "enrolled_employees.json");
                if (File.Exists(path))
                {
                    string json = File.ReadAllText(path, Encoding.UTF8);
                    var jss = new JavaScriptSerializer();
                    var dict = jss.Deserialize<Dictionary<string, object>>(json);
                    if (dict != null)
                    {
                        foreach (var kvp in dict)
                        {
                            map[kvp.Key] = kvp.Value != null ? kvp.Value.ToString() : "";
                        }
                    }
                }
            }
            catch { }
            return map;
        }

        static void SaveEmployeeMap(Dictionary<string, string> map)
        {
            try
            {
                string path = Path.Combine(LogDir, "enrolled_employees.json");
                var jss = new JavaScriptSerializer();
                File.WriteAllText(path, jss.Serialize(map), new UTF8Encoding(false));
            }
            catch { }
        }

        static int GetIntFromDict(Dictionary<string, object> dict, params string[] keys)
        {
            foreach (var k in keys)
            {
                if (dict.ContainsKey(k) && dict[k] != null)
                {
                    string s = dict[k].ToString().Trim();
                    int num;
                    if (int.TryParse(s, out num)) return num;
                    // strip non-digits
                    StringBuilder sb = new StringBuilder();
                    foreach (char c in s) { if (char.IsDigit(c)) sb.Append(c); }
                    if (sb.Length > 0 && int.TryParse(sb.ToString(), out num)) return num;
                }
            }
            return 0;
        }

        static string GetStringFromDict(Dictionary<string, object> dict, params string[] keys)
        {
            foreach (var k in keys)
            {
                if (dict.ContainsKey(k) && dict[k] != null)
                {
                    return dict[k].ToString().Trim();
                }
            }
            return "";
        }
        #endregion
    }

    public class StateManager
    {
        string filePath;
        Dictionary<string, long> syncedSignatures = new Dictionary<string, long>();
        int totalSyncedCount = 0;
        string lastSyncAt = null;
        string lastLogTimestamp = null;
        object lockObj = new object();

        public int TotalSyncedCount { get { return totalSyncedCount; } }
        public string LastSyncAt { get { return lastSyncAt; } }

        public StateManager(string path)
        {
            this.filePath = path;
            Load();
        }

        public void Load()
        {
            lock (lockObj)
            {
                try
                {
                    if (File.Exists(filePath))
                    {
                        string json = File.ReadAllText(filePath, Encoding.UTF8);
                        var jss = new JavaScriptSerializer();
                        jss.MaxJsonLength = int.MaxValue;
                        var dict = jss.Deserialize<Dictionary<string, object>>(json);
                        if (dict != null)
                        {
                            if (dict.ContainsKey("totalSyncedCount"))
                            {
                                int.TryParse(dict["totalSyncedCount"].ToString(), out totalSyncedCount);
                            }
                            if (dict.ContainsKey("lastSyncAt") && dict["lastSyncAt"] != null)
                            {
                                lastSyncAt = dict["lastSyncAt"].ToString();
                            }
                            if (dict.ContainsKey("lastLogTimestamp") && dict["lastLogTimestamp"] != null)
                            {
                                lastLogTimestamp = dict["lastLogTimestamp"].ToString();
                            }
                            if (dict.ContainsKey("syncedSignatures") && dict["syncedSignatures"] is Dictionary<string, object>)
                            {
                                var sigs = (Dictionary<string, object>)dict["syncedSignatures"];
                                foreach (var kvp in sigs)
                                {
                                    long val = 0;
                                    if (kvp.Value != null) long.TryParse(kvp.Value.ToString(), out val);
                                    syncedSignatures[kvp.Key] = val;
                                }
                            }
                        }
                    }
                }
                catch { }
            }
        }

        public void Save()
        {
            lock (lockObj)
            {
                try
                {
                    // Keep maximum 5000 recent signatures to prevent state bloat
                    if (syncedSignatures.Count > 5000)
                    {
                        var trimmed = new Dictionary<string, long>();
                        int skip = syncedSignatures.Count - 4000;
                        int i = 0;
                        foreach (var kvp in syncedSignatures)
                        {
                            if (i >= skip) trimmed[kvp.Key] = kvp.Value;
                            i++;
                        }
                        syncedSignatures = trimmed;
                    }

                    var dict = new Dictionary<string, object>();
                    dict["lastSyncAt"] = lastSyncAt;
                    dict["lastLogTimestamp"] = lastLogTimestamp;
                    dict["syncedSignatures"] = syncedSignatures;
                    dict["totalSyncedCount"] = totalSyncedCount;

                    var jss = new JavaScriptSerializer();
                    jss.MaxJsonLength = int.MaxValue;
                    string json = jss.Serialize(dict);

                    string tmp = filePath + ".tmp";
                    File.WriteAllText(tmp, json, new UTF8Encoding(false));
                    if (File.Exists(filePath)) File.Delete(filePath);
                    File.Move(tmp, filePath);
                }
                catch { }
            }
        }

        public bool IsAlreadySynced(string employeeCode, string logDateTime)
        {
            string sig = (employeeCode ?? "").Trim() + "_" + (logDateTime ?? "").Trim();
            lock (lockObj)
            {
                return syncedSignatures.ContainsKey(sig);
            }
        }

        public void MarkSynced(List<PunchRecord> records)
        {
            lock (lockObj)
            {
                long now = DateTime.UtcNow.Ticks;
                foreach (var r in records)
                {
                    string sig = (r.employeeCode ?? "").Trim() + "_" + (r.logDateTime ?? "").Trim();
                    syncedSignatures[sig] = now;
                    totalSyncedCount++;
                    lastLogTimestamp = r.logDateTime;
                }
                lastSyncAt = DateTime.UtcNow.ToString("o");
                Save();
            }
        }
    }

    public class PunchRecord
    {
        public string employeeCode { get; set; }
        public string employeeName { get; set; }
        public string logDateTime { get; set; }
        public string direction { get; set; }
        public string verificationMode { get; set; }
        public string deviceSerial { get; set; }
        public string deviceName { get; set; }
        public string branchId { get; set; }
    }

    public class Config
    {
        public MachineConfig machine { get; set; }
        public CloudConfig cloud { get; set; }
        public OptionsConfig options { get; set; }
    }

    public class MachineConfig
    {
        public string ip { get; set; }
        public int port { get; set; }
        public int machineNumber { get; set; }
        public int password { get; set; }
        public string deviceName { get; set; }

        public MachineConfig()
        {
            ip = "192.168.1.14";
            port = 5005;
            machineNumber = 1;
            password = 0;
            deviceName = "Biometric Machine";
        }
    }

    public class CloudConfig
    {
        public string apiUrl { get; set; }
        public string authToken { get; set; }
        public string branchId { get; set; }
        public int syncIntervalSeconds { get; set; }

        public CloudConfig()
        {
            apiUrl = "https://api.satyakiran.co.in/api/v1/hrms/attendance/biometric-push";
            authToken = "satyakiran_biometric_2026";
            syncIntervalSeconds = 30;
        }
    }

    public class OptionsConfig
    {
        public bool clearDeviceLogsAfterSync { get; set; }
        public string syncStateFile { get; set; }
        public int maxBatchSize { get; set; }
        public int retryIntervalSeconds { get; set; }

        public OptionsConfig()
        {
            maxBatchSize = 100;
            retryIntervalSeconds = 10;
        }
    }

    public class ErrorException : Exception
    {
        public ErrorException(string msg) : base(msg) { }
    }
}
