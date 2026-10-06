; Satyakiran Biometric Bridge - Windows installer (Inno Setup 6)
; Build:  iscc /DAppVersion=1.0.0 installer\SatyakiranBridge.iss   (see scripts\build-release.ps1)
; Needs sdk\ folder next to the repo root containing the Realtime SDK files
; (SBXPC.ocx, SBPCCOMM.dll, SBXPCDLL.dll, GEN_FONT.dll, ...). They are NOT stored in git.

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

[Setup]
AppId={{6F1B7A52-3C0E-4E8B-9D4B-5A7A2C0B1E01}
AppName=Satyakiran Biometric Bridge
AppVersion={#AppVersion}
AppPublisher=Satyakiran
DefaultDirName={autopf32}\SatyakiranBridge
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=SatyakiranBridge-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=Satyakiran Biometric Bridge

[Files]
Source: "..\supervisor.ps1";      DestDir: "{app}"; Flags: ignoreversion
Source: "..\register-task.ps1";   DestDir: "{app}"; Flags: ignoreversion
Source: "..\ctl.ps1";             DestDir: "{app}"; Flags: ignoreversion
Source: "..\update-pubkey.xml";   DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "..\app\*";               DestDir: "{app}\app"; Flags: ignoreversion recursesubdirs
; 32-bit SDK -> SysWOW64, SBXPC.ocx registered as 32-bit COM
Source: "..\sdk\SBXPC.ocx";       DestDir: "{syswow64}"; Flags: ignoreversion 32bit regserver
Source: "..\sdk\*.dll";           DestDir: "{syswow64}"; Flags: ignoreversion 32bit skipifsourcedoesntexist
Source: "..\sdk\*.ocx";           DestDir: "{syswow64}"; Excludes: "SBXPC.ocx"; Flags: ignoreversion 32bit skipifsourcedoesntexist

[Dirs]
Name: "{commonappdata}\SatyakiranBridge"; Permissions: users-modify

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\register-task.ps1"" -Action remove"; \
  Flags: runhidden; RunOnceId: "RemoveTask"

[Icons]
Name: "{commonprograms}\Satyakiran Bridge Status"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -NoExit -File ""{app}\ctl.ps1"" status"

[Code]
var
  CfgPage: TInputQueryWizardPage;

function PsExe(): String;
begin
  Result := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
end;

function ConfigPath(): String;
begin
  Result := ExpandConstant('{commonappdata}\SatyakiranBridge\config.json');
end;

function JsonEscape(S: String): String;
begin
  StringChangeEx(S, '\', '\\', True);
  StringChangeEx(S, '"', '\"', True);
  Result := S;
end;

procedure InitializeWizard();
begin
  CfgPage := CreateInputQueryPage(wpSelectDir, 'Biometric machine & cloud',
    'Enter the details for this site', 'You can change these later in config.json (no reinstall needed).');
  CfgPage.Add('Biometric machine IP:', False);
  CfgPage.Add('Machine port:', False);
  CfgPage.Add('Machine name (shown in reports):', False);
  CfgPage.Add('Branch ID:', False);
  CfgPage.Add('Cloud auth token:', True);
  CfgPage.Values[0] := '192.168.1.224';
  CfgPage.Values[1] := '5005';
  CfgPage.Values[2] := 'Biometric Machine';
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  { Upgrade / re-install: keep the existing config.json untouched }
  Result := (PageID = CfgPage.ID) and FileExists(ConfigPath());
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if CurPageID = CfgPage.ID then
    if (Trim(CfgPage.Values[0]) = '') or (Trim(CfgPage.Values[3]) = '') or (Trim(CfgPage.Values[4]) = '') then
    begin
      MsgBox('Machine IP, Branch ID and Auth token are required.', mbError, MB_OK);
      Result := False;
    end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Json: String;
  RC: Integer;
begin
  if CurStep = ssInstall then
    Exec(PsExe(), '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}') + '\register-task.ps1" -Action stop',
      '', SW_HIDE, ewWaitUntilTerminated, RC);

  if (CurStep = ssPostInstall) and (not FileExists(ConfigPath())) then
  begin
    Json :=
      '{' + #13#10 +
      '  "machine": { "ip": "' + JsonEscape(Trim(CfgPage.Values[0])) + '", "port": ' + Trim(CfgPage.Values[1]) +
        ', "machineNumber": 1, "password": 0, "deviceName": "' + JsonEscape(Trim(CfgPage.Values[2])) + '" },' + #13#10 +
      '  "cloud": { "apiUrl": "https://api.satyakiran.co.in/api/v1/hrms/attendance/biometric-push", "authToken": "' +
        JsonEscape(Trim(CfgPage.Values[4])) + '", "branchId": "' + JsonEscape(Trim(CfgPage.Values[3])) +
        '", "syncIntervalSeconds": 30 },' + #13#10 +
      '  "options": { "maxBatchSize": 100 },' + #13#10 +
      '  "update": { "enabled": true, "checkHours": 6 }' + #13#10 +
      '}';
    SaveStringToFile(ConfigPath(), Json, False);
  end;

  if CurStep = ssPostInstall then
    Exec(PsExe(), '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}') + '\register-task.ps1" -Action install -DataDir "' +
      ExpandConstant('{commonappdata}') + '\SatyakiranBridge"', '', SW_HIDE, ewWaitUntilTerminated, RC);
end;
