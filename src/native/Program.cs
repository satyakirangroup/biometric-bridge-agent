using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;
using sbxpc;

namespace SbxpcBridge
{
    class Program
    {
        static string BaseDir = AppDomain.CurrentDomain.BaseDirectory;

        static int Main(string[] args)
        {
            if (args.Length < 5)
            {
                Console.Error.WriteLine("Usage: sbxpc-bridge <action> <machNo> <ip> <port> <password> [deviceName] [extraArgs...]");
                Console.Error.WriteLine("Actions: fetch-logs, inspect, clear-logs, test-conn, get-users, get-user, set-user, delete-user, sync-time");
                return 1;
            }

            string action = args[0].ToLowerInvariant();
            int machNo;
            if (!int.TryParse(args[1], out machNo)) machNo = 1;
            string ip = args[2];
            int port;
            if (!int.TryParse(args[3], out port)) port = 5005;
            int password;
            if (!int.TryParse(args[4], out password)) password = 0;
            string deviceName = args.Length > 5 ? args[5] : "Biometric Device";

            try
            {
                SBXPCDLL.DotNET();
                SBXPCDLL._DisableTranseiveCallback();

                bool connected = SBXPCDLL.ConnectTcpip(machNo, ip, port, password);
                if (!connected)
                {
                    Console.Error.WriteLine("ERROR: Cannot connect to biometric device at " + ip + ":" + port + " (Device offline or busy)");
                    return 2;
                }

                try
                {
                    switch (action)
                    {
                        case "fetch-logs":
                            return DoFetchLogs(machNo, ip, deviceName);

                        case "inspect":
                            return DoInspect(machNo, ip);

                        case "clear-logs":
                            return DoClearLogs(machNo);

                        case "test-conn":
                            Console.WriteLine("{\"connected\":true,\"ip\":\"" + ip + "\",\"port\":" + port + "}");
                            return 0;

                        case "get-users":
                            return DoGetUsers(machNo);

                        case "get-user":
                            int targetEnroll = args.Length > 6 ? ParseInt(args[6], 0) : 0;
                            return DoGetUser(machNo, targetEnroll);

                        case "set-user":
                            int setEnroll = args.Length > 6 ? ParseInt(args[6], 0) : 0;
                            string setName = args.Length > 7 ? args[7] : "";
                            int setPriv = args.Length > 8 ? ParseInt(args[8], 0) : 0;
                            int setEnable = args.Length > 9 ? ParseInt(args[9], 1) : 1;
                            return DoSetUser(machNo, setEnroll, setName, setPriv, setEnable);

                        case "delete-user":
                            int delEnroll = args.Length > 6 ? ParseInt(args[6], 0) : 0;
                            return DoDeleteUser(machNo, delEnroll);

                        case "sync-time":
                            return DoSyncTime(machNo);

                        default:
                            Console.Error.WriteLine("ERROR: Unknown action: " + action);
                            return 1;
                    }
                }
                finally
                {
                    try { SBXPCDLL.Disconnect(machNo); } catch { }
                }
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("ERROR: Native exception: " + ex.Message);
                return 3;
            }
        }

        static Dictionary<string, string> LoadEmployeeMap()
        {
            var map = new Dictionary<string, string>();
            try
            {
                string path = Path.Combine(BaseDir, "logs", "enrolled_employees.json");
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
                string dir = Path.Combine(BaseDir, "logs");
                if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
                string path = Path.Combine(dir, "enrolled_employees.json");
                var jss = new JavaScriptSerializer();
                File.WriteAllText(path, jss.Serialize(map), Encoding.UTF8);
            }
            catch { }
        }

        static int DoFetchLogs(int machNo, string ip, string deviceName)
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

                StringBuilder sb = new StringBuilder();
                sb.Append("[");
                bool first = true;

                int tmno, seno, smno, vmode, yr, mon, day, hr, min, sec;
                while (true)
                {
                    bool gotRec = SBXPCDLL.GetAllGLogData(machNo, out tmno, out seno, out smno, out vmode, out yr, out mon, out day, out hr, out min, out sec);
                    if (!gotRec) break;

                    string dtStr = string.Format("{0:D4}-{1:D2}-{2:D2} {3:D2}:{4:D2}:{5:D2}", yr, mon, day, hr, min, sec);
                    string vModeStr = "Face";
                    if (vmode == 1) vModeStr = "Fingerprint";
                    else if (vmode == 2) vModeStr = "Card";
                    else if (vmode == 3) vModeStr = "Password";
                    else if (vmode == 15 || vmode == 407 || vmode == 20) vModeStr = "Face";

                    string senoStr = seno.ToString();
                    string empName = empMap.ContainsKey(senoStr) ? empMap[senoStr] : "";

                    if (!first) sb.Append(",");
                    first = false;

                    sb.Append("{");
                    sb.Append("\"employeeCode\":\"").Append(seno).Append("\",");
                    sb.Append("\"employeeName\":\"").Append(EscapeJson(empName)).Append("\",");
                    sb.Append("\"logDateTime\":\"").Append(dtStr).Append("\",");
                    sb.Append("\"direction\":\"AUTO\",");
                    sb.Append("\"verificationMode\":\"").Append(vModeStr).Append("\",");
                    sb.Append("\"deviceSerial\":\"").Append(ip).Append("\",");
                    sb.Append("\"deviceName\":\"").Append(EscapeJson(deviceName)).Append("\"");
                    sb.Append("}");
                }

                sb.Append("]");
                Console.WriteLine(sb.ToString());
                return 0;
            }
            finally
            {
                SBXPCDLL.EnableDevice(machNo, 1);
            }
        }

        static int DoInspect(int machNo, string ip)
        {
            int dY = 0, dM = 0, dD = 0, dH = 0, dMi = 0, dS = 0, dDow = 0;
            SBXPCDLL.GetDeviceTime(machNo, out dY, out dM, out dD, out dH, out dMi, out dS, out dDow);
            string devTime = string.Format("{0:D4}-{1:D2}-{2:D2} {3:D2}:{4:D2}:{5:D2}", dY, dM, dD, dH, dMi, dS);

            uint userCount = 0, totalLogs = 0, unreadLogs = 0, fpCount = 0, faceCount = 0, pwdCount = 0;
            SBXPCDLL.GetDeviceStatus(machNo, 2, out userCount);
            SBXPCDLL.GetDeviceStatus(machNo, 6, out totalLogs);
            SBXPCDLL.GetDeviceStatus(machNo, 11, out unreadLogs);
            SBXPCDLL.GetDeviceStatus(machNo, 3, out fpCount);
            SBXPCDLL.GetDeviceStatus(machNo, 9, out faceCount);
            SBXPCDLL.GetDeviceStatus(machNo, 4, out pwdCount);

            SBXPCDLL.EnableDevice(machNo, 0);
            List<int> users = new List<int>();
            try
            {
                if (SBXPCDLL.ReadAllUserID(machNo))
                {
                    int uEnroll = 0, uEmach = 0, uBackup = 0, uPriv = 0, uEnable = 0;
                    while (SBXPCDLL.GetAllUserID(machNo, out uEnroll, out uEmach, out uBackup, out uPriv, out uEnable))
                    {
                        if (!users.Contains(uEnroll)) users.Add(uEnroll);
                    }
                }
            }
            finally
            {
                SBXPCDLL.EnableDevice(machNo, 1);
            }

            SBXPCDLL.EnableDevice(machNo, 0);
            StringBuilder punchJson = new StringBuilder();
            punchJson.Append("[");
            try
            {
                if (SBXPCDLL.ReadAllGLogData(machNo))
                {
                    int tmno, seno, smno, vmode, yr, mon, day, hr, min, sec;
                    bool first = true;
                    while (SBXPCDLL.GetAllGLogData(machNo, out tmno, out seno, out smno, out vmode, out yr, out mon, out day, out hr, out min, out sec))
                    {
                        if (!first) punchJson.Append(",");
                        first = false;
                        string dtStr = string.Format("{0:D4}-{1:D2}-{2:D2} {3:D2}:{4:D2}:{5:D2}", yr, mon, day, hr, min, sec);
                        string vModeStr = "Face";
                        if (vmode == 1) vModeStr = "Fingerprint";
                        else if (vmode == 2) vModeStr = "Card";
                        else if (vmode == 3) vModeStr = "Password";
                        else if (vmode == 15 || vmode == 407 || vmode == 20) vModeStr = "Face";

                        punchJson.Append("{\"emp\":\"").Append(seno).Append("\",\"time\":\"").Append(dtStr).Append("\",\"mode\":\"").Append(vModeStr).Append("\"}");
                    }
                }
            }
            finally
            {
                SBXPCDLL.EnableDevice(machNo, 1);
            }
            punchJson.Append("]");

            StringBuilder sb = new StringBuilder();
            sb.Append("JSON_START\n");
            sb.Append("{\n");
            sb.Append("  \"deviceTime\": \"").Append(devTime).Append("\",\n");
            sb.Append("  \"userCount\": ").Append(userCount).Append(",\n");
            sb.Append("  \"fpCount\": ").Append(fpCount).Append(",\n");
            sb.Append("  \"faceCount\": ").Append(faceCount).Append(",\n");
            sb.Append("  \"pwdCount\": ").Append(pwdCount).Append(",\n");
            sb.Append("  \"totalLogs\": ").Append(totalLogs).Append(",\n");
            sb.Append("  \"unreadLogs\": ").Append(unreadLogs).Append(",\n");
            sb.Append("  \"enrolledUsers\": [");
            for (int i = 0; i < users.Count; i++)
            {
                if (i > 0) sb.Append(",");
                sb.Append(users[i]);
            }
            sb.Append("],\n");
            sb.Append("  \"punches\": ").Append(punchJson.ToString()).Append("\n");
            sb.Append("}\n");
            sb.Append("JSON_END");

            Console.WriteLine(sb.ToString());
            return 0;
        }

        static int DoClearLogs(int machNo)
        {
            SBXPCDLL.EnableDevice(machNo, 0);
            try
            {
                bool ok = SBXPCDLL.EmptyGeneralLogData(machNo);
                if (ok)
                {
                    Console.WriteLine("{\"cleared\":true}");
                    return 0;
                }
                else
                {
                    Console.Error.WriteLine("ERROR: Failed to empty log data on device.");
                    return 4;
                }
            }
            finally
            {
                SBXPCDLL.EnableDevice(machNo, 1);
            }
        }

        static int DoGetUsers(int machNo)
        {
            var empMap = LoadEmployeeMap();
            var users = new List<int>();

            SBXPCDLL.EnableDevice(machNo, 0);
            try
            {
                if (SBXPCDLL.ReadAllUserID(machNo))
                {
                    int uEnroll = 0, uEmach = 0, uBackup = 0, uPriv = 0, uEnable = 0;
                    while (SBXPCDLL.GetAllUserID(machNo, out uEnroll, out uEmach, out uBackup, out uPriv, out uEnable))
                    {
                        if (!users.Contains(uEnroll))
                        {
                            users.Add(uEnroll);
                            string uStr = uEnroll.ToString();
                            if (!empMap.ContainsKey(uStr) || string.IsNullOrEmpty(empMap[uStr]))
                            {
                                string uName = "";
                                SBXPCDLL.GetUserName1(machNo, uEnroll, out uName);
                                if (!string.IsNullOrEmpty(uName))
                                {
                                    empMap[uStr] = uName;
                                }
                            }
                        }
                    }
                    SaveEmployeeMap(empMap);
                }

                StringBuilder sb = new StringBuilder();
                sb.Append("[");
                bool first = true;
                foreach (int u in users)
                {
                    if (!first) sb.Append(",");
                    first = false;
                    string uStr = u.ToString();
                    string name = empMap.ContainsKey(uStr) ? empMap[uStr] : "";
                    sb.Append("{\"employeeCode\":\"").Append(uStr).Append("\",\"employeeName\":\"").Append(EscapeJson(name)).Append("\"}");
                }
                sb.Append("]");
                Console.WriteLine(sb.ToString());
                return 0;
            }
            finally
            {
                SBXPCDLL.EnableDevice(machNo, 1);
            }
        }

        static int DoGetUser(int machNo, int enrollNo)
        {
            SBXPCDLL.EnableDevice(machNo, 0);
            try
            {
                string name = "";
                SBXPCDLL.GetUserName1(machNo, enrollNo, out name);
                int priv = 0, pwd = 0;
                SBXPCDLL.GetEnrollData1(machNo, enrollNo, 10, out priv, IntPtr.Zero, out pwd);

                Console.WriteLine("{\"success\":true,\"employeeCode\":\"" + enrollNo + "\",\"employeeName\":\"" + EscapeJson(name) + "\",\"privilege\":" + priv + "}");
                return 0;
            }
            finally
            {
                SBXPCDLL.EnableDevice(machNo, 1);
            }
        }

        static int DoSetUser(int machNo, int enrollNo, string userName, int privilege, int enable)
        {
            SBXPCDLL.EnableDevice(machNo, 0);
            try
            {
                bool resName = SBXPCDLL.SetUserName1(machNo, enrollNo, userName);
                bool resEn = SBXPCDLL.EnableUser(machNo, enrollNo, 0, 0, (byte)enable);
                if (privilege >= 0)
                {
                    SBXPCDLL.ModifyPrivilege(machNo, enrollNo, 0, 0, privilege);
                }

                var empMap = LoadEmployeeMap();
                empMap[enrollNo.ToString()] = userName;
                SaveEmployeeMap(empMap);

                Console.WriteLine("{\"success\":true,\"action\":\"SET_USER\",\"employeeCode\":\"" + enrollNo + "\",\"employeeName\":\"" + EscapeJson(userName) + "\",\"privilege\":" + privilege + ",\"enabled\":" + (enable == 1 ? "true" : "false") + "}");
                return 0;
            }
            finally
            {
                SBXPCDLL.EnableDevice(machNo, 1);
            }
        }

        static int DoDeleteUser(int machNo, int enrollNo)
        {
            SBXPCDLL.EnableDevice(machNo, 0);
            try
            {
                bool res = SBXPCDLL.DeleteEnrollData(machNo, enrollNo, 0, 12);
                if (!res) res = SBXPCDLL.DeleteEnrollData(machNo, enrollNo, 0, 11);
                SBXPCDLL.SetUserName1(machNo, enrollNo, "");
                SBXPCDLL.EnableUser(machNo, enrollNo, 0, 0, 0);

                var empMap = LoadEmployeeMap();
                if (empMap.ContainsKey(enrollNo.ToString()))
                {
                    empMap.Remove(enrollNo.ToString());
                    SaveEmployeeMap(empMap);
                }

                Console.WriteLine("{\"success\":true,\"action\":\"DELETE_USER\",\"employeeCode\":\"" + enrollNo + "\"}");
                return 0;
            }
            finally
            {
                SBXPCDLL.EnableDevice(machNo, 1);
            }
        }

        static int DoSyncTime(int machNo)
        {
            bool res = SBXPCDLL.SetDeviceTime(machNo);
            Console.WriteLine("{\"success\":" + (res ? "true" : "false") + ",\"action\":\"SYNC_TIME\"}");
            return res ? 0 : 1;
        }

        static int ParseInt(string s, int defaultVal)
        {
            int v;
            return int.TryParse(s, out v) ? v : defaultVal;
        }

        static string EscapeJson(string s)
        {
            if (string.IsNullOrEmpty(s)) return "";
            return s.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\n", "\\n").Replace("\r", "\\r");
        }
    }
}
