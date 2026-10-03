' Satyakiran Biometric Machine Deep Diagnostics
Option Explicit

Dim sbx, connected, errDesc
On Error Resume Next
Set sbx = CreateObject("SBXPC.SBXPCCtrl.1")
If Err.Number <> 0 Then
    WScript.Echo "❌ COM ERROR: Cannot create SBXPC.SBXPCCtrl.1 (" & Err.Description & ")"
    WScript.Echo "💡 Tip: Make sure you ran _install_sbxpc.bat as Administrator."
    WScript.Quit 1
End If
On Error Goto 0

WScript.Echo "======================================================="
WScript.Echo "📟 Satyakiran Biometric Machine — Deep Diagnostics"
WScript.Echo "======================================================="

Dim machineNum, ip, port, pass
machineNum = 1
ip = "192.168.1.14"
port = 5005
pass = 0

WScript.Echo "Target Machine : " & ip & ":" & port & " (Machine #" & machineNum & ")"
WScript.Echo "Connecting via TCP/IP..."

connected = sbx.ConnectTcpip(machineNum, ip, port, pass)
If Not connected Then
    WScript.Echo "❌ CONNECTION FAILED: Cannot reach biometric machine at " & ip & ":" & port
    WScript.Echo "   Check: Is the machine powered ON and on the same WiFi/router?"
    WScript.Quit 1
End If

WScript.Echo "✅ CONNECTED successfully to biometric machine!"
WScript.Echo ""

' 1. Query Hardware Status (Status 2=Users, 6=Total Logs, 11=Unread Logs)
Dim userCount, totalLogs, unreadLogs, fpCount, faceCount
userCount = CLng(0)
totalLogs = CLng(0)
unreadLogs = CLng(0)
fpCount = CLng(0)
faceCount = CLng(0)

Dim rUsers, rLogs, rUnread, rFp, rFace
rUsers = sbx.GetDeviceStatus(machineNum, 2, userCount)
rLogs = sbx.GetDeviceStatus(machineNum, 6, totalLogs)
rUnread = sbx.GetDeviceStatus(machineNum, 11, unreadLogs)
rFp = sbx.GetDeviceStatus(machineNum, 3, fpCount)
rFace = sbx.GetDeviceStatus(machineNum, 9, faceCount)

WScript.Echo "--- 📊 HARDWARE STATUS IN MACHINE MEMORY ---"
WScript.Echo "Enrolled Users on Device : " & userCount
WScript.Echo "Enrolled Fingerprints    : " & fpCount
WScript.Echo "Enrolled Faces           : " & faceCount
WScript.Echo "TOTAL PUNCHES STORED     : " & totalLogs
WScript.Echo "UNREAD PUNCHES PENDING   : " & unreadLogs
WScript.Echo ""

' 2. Test Transactional Memory Read with EnableDevice(..., False)
WScript.Echo "--- 🔍 TESTING LOG RETRIEVAL ---"
sbx.EnableDevice machineNum, False

Dim hasAll, hasGen
WScript.Echo "1. Calling ReadAllGLogData(" & machineNum & ")..."
hasAll = sbx.ReadAllGLogData(machineNum)
WScript.Echo "   Result: " & hasAll

If hasAll Then
    Dim tMach, enrollNo, eMach, verifyMode, y, m, d, h, mi, s
    tMach = CLng(0)
    enrollNo = CLng(0)
    eMach = CLng(0)
    verifyMode = CLng(0)
    y = CLng(0)
    m = CLng(0)
    d = CLng(0)
    h = CLng(0)
    mi = CLng(0)
    s = CLng(0)

    Dim gotRec, recCount
    recCount = 0
    gotRec = sbx.GetAllGLogData(machineNum, tMach, enrollNo, eMach, verifyMode, y, m, d, h, mi, s)
    WScript.Echo "   GetAllGLogData first record call returned: " & gotRec

    Do While gotRec
        recCount = recCount + 1
        If recCount <= 5 Then
            WScript.Echo "      [" & recCount & "] EmpCode: " & enrollNo & " | Time: " & y & "-" & Right("0" & m, 2) & "-" & Right("0" & d, 2) & " " & Right("0" & h, 2) & ":" & Right("0" & mi, 2) & ":" & Right("0" & s, 2) & " | Mode: " & verifyMode
        End If
        gotRec = sbx.GetAllGLogData(machineNum, tMach, enrollNo, eMach, verifyMode, y, m, d, h, mi, s)
    Loop
    WScript.Echo "   ✅ Total records parsed via GetAllGLogData: " & recCount
End If

WScript.Echo ""
WScript.Echo "2. Calling ReadGeneralLogData(" & machineNum & ")..."
hasGen = sbx.ReadGeneralLogData(machineNum)
WScript.Echo "   Result: " & hasGen

If hasGen Then
    Dim tMach2, enrollNo2, eMach2, verifyMode2, y2, m2, d2, h2, mi2, s2
    tMach2 = CLng(0)
    enrollNo2 = CLng(0)
    eMach2 = CLng(0)
    verifyMode2 = CLng(0)
    y2 = CLng(0)
    m2 = CLng(0)
    d2 = CLng(0)
    h2 = CLng(0)
    mi2 = CLng(0)
    s2 = CLng(0)

    Dim gotRec2, recCount2
    recCount2 = 0
    gotRec2 = sbx.GetGeneralLogData(machineNum, tMach2, enrollNo2, eMach2, verifyMode2, y2, m2, d2, h2, mi2, s2)
    WScript.Echo "   GetGeneralLogData first record call returned: " & gotRec2

    Do While gotRec2
        recCount2 = recCount2 + 1
        If recCount2 <= 5 Then
            WScript.Echo "      [" & recCount2 & "] EmpCode: " & enrollNo2 & " | Time: " & y2 & "-" & Right("0" & m2, 2) & "-" & Right("0" & d2, 2) & " " & Right("0" & h2, 2) & ":" & Right("0" & mi2, 2) & ":" & Right("0" & s2, 2) & " | Mode: " & verifyMode2
        End If
        gotRec2 = sbx.GetGeneralLogData(machineNum, tMach2, enrollNo2, eMach2, verifyMode2, y2, m2, d2, h2, mi2, s2)
    Loop
    WScript.Echo "   ✅ Total records parsed via GetGeneralLogData: " & recCount2
End If

sbx.EnableDevice machineNum, True
sbx.Disconnect
sbx.CloseCommPort

WScript.Echo ""
WScript.Echo "======================================================="
WScript.Echo "🏁 Diagnostics Finished Successfully!"
WScript.Echo "======================================================="
