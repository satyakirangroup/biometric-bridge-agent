; Satyakiran Biometric Bridge - Windows installer (Inno Setup 6)
; Build:  iscc /DAppVersion=1.0.0 installer\SatyakiranBridge.iss   (see scripts\build-release.ps1)
; Needs sdk\ folder next to the repo root containing the Realtime SDK files
; (SBXPC.ocx, SBPCCOMM.dll, SBXPCDLL.dll, GEN_FONT.dll, ...). They are NOT stored in git.

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
; Optional pre-fill, passed by build-release.ps1:  /DDefaultToken=... /DDefaultBranch=... /DDefaultIp=... /DManifestUrl=...
#ifndef DefaultToken
  #define DefaultToken ""
#endif
#ifndef DefaultBranch
  #define DefaultBranch ""
#endif
#ifndef DefaultIp
  #define DefaultIp "192.168.0.124"
#endif
#ifndef ManifestUrl
  #define ManifestUrl ""
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
; The settings UI (32-bit PowerShell: the machine SDK is 32-bit COM). It elevates itself.
Name: "{commonprograms}\Satyakiran Bridge"; Filename: "{syswow64}\WindowsPowerShell\v1.0\powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File ""{app}\app\manager.ps1"""; WorkingDir: "{app}"
Name: "{commondesktop}\Satyakiran Bridge"; Filename: "{syswow64}\WindowsPowerShell\v1.0\powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File ""{app}\app\manager.ps1"""; WorkingDir: "{app}"

[Run]
Filename: "{syswow64}\WindowsPowerShell\v1.0\powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File ""{app}\app\manager.ps1"""; \
  Description: "Open Satyakiran Bridge settings now"; Flags: postinstall nowait skipifsilent

[Code]
function PsExe(): String;
begin
  Result := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
end;

function ConfigPath(): String;
begin
  Result := ExpandConstant('{commonappdata}\SatyakiranBridge\config.json');
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Json, Upd: String;
  RC: Integer;
begin
  if CurStep = ssInstall then
    Exec(PsExe(), '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}') + '\register-task.ps1" -Action stop',
      '', SW_HIDE, ewWaitUntilTerminated, RC);

  { First install only: write a starter config. Upgrades keep the existing one. IP / token / branch are then edited in the UI. }
  if (CurStep = ssPostInstall) and (not FileExists(ConfigPath())) then
  begin
    Upd := '"update": { "enabled": true, "checkHours": 6';
    if '{#ManifestUrl}' <> '' then Upd := Upd + ', "manifestUrl": "{#ManifestUrl}"';
    Upd := Upd + ' }';
    Json :=
      '{' + #13#10 +
      '  "machine": { "ip": "{#DefaultIp}", "port": 5005, "machineNumber": 1, "password": 0, "deviceName": "Biometric Machine" },' + #13#10 +
      '  "cloud": { "apiUrl": "https://api.satyakiran.co.in/api/v1/hrms/attendance/biometric-push", "authToken": "{#DefaultToken}", "branchId": "{#DefaultBranch}", "syncIntervalSeconds": 30 },' + #13#10 +
      '  "options": { "maxBatchSize": 100 },' + #13#10 +
      '  ' + Upd + #13#10 +
      '}';
    SaveStringToFile(ConfigPath(), Json, False);
  end;

  if CurStep = ssPostInstall then
    Exec(PsExe(), '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}') + '\register-task.ps1" -Action install -DataDir "' +
      ExpandConstant('{commonappdata}') + '\SatyakiranBridge"', '', SW_HIDE, ewWaitUntilTerminated, RC);
end;
