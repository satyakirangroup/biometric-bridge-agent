' Satyakiran Biometric Machine Deep Hardware & Memory Diagnostics
Option Explicit

Dim sbx, connected
On Error Resume Next
Set sbx = CreateObject("SBXPC.SBXPCCtrl.1")
If Err.Number <> 0 Then
    WScript.Echo "❌ COM ERROR: Cannot create SBXPC.SBXPCCtrl.1 (" & Err.Description & ")"
    WScript.Echo "💡 Tip: Right-click _install_sbxpc.bat and select 'Run as Administrator'."
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

' 1. Check Device Clock vs PC Clock
Dim dY, dM, dD, dH, dMi, dS, dDow, rTime
dY = CLng(0)
dM = CLng(0)
dD = CLng(0)
dH = CLng(0)
dMi = CLng(0)
dS = CLng(0)
dDow = CLng(0)

rTime = sbx.GetDeviceTime(machineNum, dY, dM, dD, dH, dMi, dS, dDow)
If rTime Then
    Dim devTimeStr
    devTimeStr = dY & "-" & Right("0" & dM, 2) & "-" & Right("0" & dD, 2) & " " & Right("0" & dH, 2) & ":" & Right("0" & dMi, 2) & ":" & Right("0" & dS, 2)
    WScript.Echo "--- 🕒 CLOCK SYNCHRONIZATION ---"
    WScript.Echo "Biometric Device Time : " & devTimeStr
    WScript.Echo "Windows PC Time       : " & Now
    If Abs(DateDiff("d", Now, DateSerial(dY, dM, dD))) > 1 Then
        WScript.Echo "⚠️  WARNING: Device date differs from PC date! Machine may be recording punches under wrong date!"
    End If
    WScript.Echo ""
End If

' 2. Query Hardware Status from Internal Register
Dim userCount, totalLogs, unreadLogs, fpCount, faceCount
userCount = CLng(0)
totalLogs = CLng(0)
unreadLogs = CLng(0)
fpCount = CLng(0)
faceCount = CLng(0)

sbx.GetDeviceStatus machineNum, 2, userCount
sbx.GetDeviceStatus machineNum, 6, totalLogs
sbx.GetDeviceStatus machineNum, 11, unreadLogs
sbx.GetDeviceStatus machineNum, 3, fpCount
sbx.GetDeviceStatus machineNum, 9, faceCount

WScript.Echo "--- 📊 HARDWARE STATUS IN MACHINE MEMORY ---"
WScript.Echo "Enrolled Users on Device : " & userCount
WScript.Echo "Enrolled Fingerprints    : " & fpCount
WScript.Echo "Enrolled Faces           : " & faceCount
WScript.Echo "TOTAL PUNCHES IN FLASH   : " & totalLogs
WScript.Echo "UNREAD PUNCHES PENDING   : " & unreadLogs
WScript.Echo ""

' 3. List First 10 Enrolled User IDs from Device
WScript.Echo "--- 👥 ENROLLED USER IDS ON DEVICE ---"
Dim hasUsers
hasUsers = sbx.ReadAllUserID(machineNum)
If hasUsers Then
    Dim uEnroll, uEmach, uBackup, uPriv, uEnable, uCount
    uEnroll = CLng(0)
    uEmach = CLng(0)
    uBackup = CLng(0)
    uPriv = CLng(0)
    uEnable = CLng(0)
    uCount = 0

    Dim gotUser
    gotUser = sbx.GetAllUserID(machineNum, uEnroll, uEmach, uBackup, uPriv, uEnable)
    Dim userList
    userList = ""

    Do While gotUser And uCount < 10
        uCount = uCount + 1
        userList = userList & uEnroll & " "
        gotUser = sbx.GetAllUserID(machineNum, uEnroll, uEmach, uBackup, uPriv, uEnable)
    Loop

    If userList <> "" Then
        WScript.Echo "Sample Enrolled IDs: " & userList
    Else
        WScript.Echo "No users returned from GetAllUserID."
    End If
Else
    WScript.Echo "ReadAllUserID returned false."
End If
WScript.Echo ""

' 4. Read Punch Logs with Transactional Lock
WScript.Echo "--- 🔍 READING LOG MEMORY ---"
sbx.EnableDevice machineNum, False

Dim hasAll, hasGen, totalRead
totalRead = 0

WScript.Echo "1. Trying ReadAllGLogData (reads all records, ignores read-mark)..."
hasAll = sbx.ReadAllGLogData(machineNum)
WScript.Echo "   ReadAllGLogData returned: " & hasAll

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

    Dim gotRec
    gotRec = sbx.GetAllGLogData(machineNum, tMach, enrollNo, eMach, verifyMode, y, m, d, h, mi, s)
    WScript.Echo "   GetAllGLogData first record: " & gotRec

    Do While gotRec
        totalRead = totalRead + 1
        If totalRead <= 10 Then
            WScript.Echo "      [" & totalRead & "] Emp: " & enrollNo & " | " & y & "-" & Right("0" & m, 2) & "-" & Right("0" & d, 2) & " " & Right("0" & h, 2) & ":" & Right("0" & mi, 2) & ":" & Right("0" & s, 2) & " | Mode: " & verifyMode
        End If
        gotRec = sbx.GetAllGLogData(machineNum, tMach, enrollNo, eMach, verifyMode, y, m, d, h, mi, s)
    Loop
    WScript.Echo "   ✅ Total records parsed: " & totalRead
End If

If totalRead = 0 Then
    WScript.Echo "2. Trying ReadGeneralLogData (standard log read)..."
    hasGen = sbx.ReadGeneralLogData(machineNum)
    WScript.Echo "   ReadGeneralLogData returned: " & hasGen

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

        Dim gotRec2
        gotRec2 = sbx.GetGeneralLogData(machineNum, tMach2, enrollNo2, eMach2, verifyMode2, y2, m2, d2, h2, mi2, s2)
        Do While gotRec2
            totalRead = totalRead + 1
            If totalRead <= 10 Then
                WScript.Echo "      [" & totalRead & "] Emp: " & enrollNo2 & " | " & y2 & "-" & Right("0" & m2, 2) & "-" & Right("0" & d2, 2) & " " & Right("0" & h2, 2) & ":" & Right("0" & mi2, 2) & ":" & Right("0" & s2, 2) & " | Mode: " & verifyMode2
            End If
            gotRec2 = sbx.GetGeneralLogData(machineNum, tMach2, enrollNo2, eMach2, verifyMode2, y2, m2, d2, h2, mi2, s2)
        Loop
        WScript.Echo "   ✅ Total records parsed via GetGeneralLogData: " & totalRead
    End If
End If

sbx.EnableDevice machineNum, True
sbx.Disconnect
sbx.CloseCommPort

WScript.Echo ""
WScript.Echo "======================================================="
If totalRead > 0 Then
    WScript.Echo "🎉 SUCCESS: Successfully read " & totalRead & " punch records from biometric machine!"
Else
    WScript.Echo "⚠️  ATTENTION: The machine's internal memory reported 0 punch records."
    WScript.Echo "   Common causes:"
    WScript.Echo "   1. Realsoft software is running in Task Manager and downloading/clearing logs."
    WScript.Echo "   2. Punch the machine with your finger/face right now and re-run this script."
    WScript.Echo "   3. Check the machine clock above matches today's date."
End If
WScript.Echo "======================================================="
