using System;
using System.Collections.Generic;
using System.Text;
using sbxpc;

namespace SbxpcBridge
{
    class Program
    {
        static int Main(string[] args)
        {
            if (args.Length < 5)
            {
                Console.Error.WriteLine("Usage: sbxpc-bridge <action> <machNo> <ip> <port> <password> [deviceName]");
                Console.Error.WriteLine("Actions: fetch-logs, inspect, clear-logs, test-conn");
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

        static int DoFetchLogs(int machNo, string ip, string deviceName)
        {
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

                    if (!first) sb.Append(",");
                    first = false;

                    sb.Append("{");
                    sb.Append("\"employeeCode\":\"").Append(seno).Append("\",");
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

            // Read enrolled users
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

            // Read punches sample / count
            SBXPCDLL.EnableDevice(machNo, 0);
            StringBuilder punchJson = new StringBuilder();
            punchJson.Append("[");
            int pCount = 0;
            try
            {
                if (SBXPCDLL.ReadAllGLogData(machNo))
                {
                    int tmno, seno, smno, vmode, yr, mon, day, hr, min, sec;
                    bool first = true;
                    while (SBXPCDLL.GetAllGLogData(machNo, out tmno, out seno, out smno, out vmode, out yr, out mon, out day, out hr, out min, out sec))
                    {
                        pCount++;
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

        static string EscapeJson(string s)
        {
            if (string.IsNullOrEmpty(s)) return "";
            return s.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\n", "\\n").Replace("\r", "\\r");
        }
    }
}
