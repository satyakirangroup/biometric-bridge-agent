# Builds and signs SbxpcBridge.exe and SatyakiranBiometricAgent.exe natively using Windows built-in .NET compiler.
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot

$csc = "C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) {
    Write-Error "Microsoft .NET Framework 4.0/4.8 compiler not found at $csc"
    exit 1
}

Write-Host ""
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host "BUILDING SATYAKIRAN NATIVE WINDOWS EXECUTABLES (.EXE)" -ForegroundColor Green
Write-Host "=======================================================" -ForegroundColor Cyan

# 1. Compile SbxpcBridge.exe
Write-Host ""
Write-Host "1. Compiling SbxpcBridge.exe..." -ForegroundColor Yellow
$bridgeCs = Join-Path $Root "src\native\Program.cs"
$bridgeOut = Join-Path $Root "SbxpcBridge.exe"
$bridgeDll = Join-Path $Root "SBXPCDLL_Net.dll"

& $csc /target:exe /out:$bridgeOut /platform:x86 "/r:$bridgeDll,System.Web.Extensions.dll" $bridgeCs
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to compile SbxpcBridge.exe"
    exit 1
}
Write-Host "   [OK] SbxpcBridge.exe compiled successfully." -ForegroundColor Green

# Also copy to src/native/
Copy-Item $bridgeOut (Join-Path $Root "src\native\sbxpc-bridge.exe") -Force

# 2. Compile SatyakiranBiometricAgent.exe
Write-Host ""
Write-Host "2. Compiling SatyakiranBiometricAgent.exe..." -ForegroundColor Yellow
$agentCs = Join-Path $Root "src\native\SatyakiranBiometricAgent.cs"
$agentOut = Join-Path $Root "SatyakiranBiometricAgent.exe"

& $csc /target:exe /out:$agentOut /platform:x86 "/r:$bridgeDll,System.Web.Extensions.dll" $agentCs
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to compile SatyakiranBiometricAgent.exe"
    exit 1
}
Write-Host "   [OK] SatyakiranBiometricAgent.exe compiled successfully." -ForegroundColor Green

# 3. Code Sign EXEs
Write-Host ""
Write-Host "3. Signing executables with Code Signing Certificate..." -ForegroundColor Yellow
$cert = (Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -match "Satyakiran" } | Select-Object -First 1)
if (-not $cert) {
    $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject "CN=Satyakiran Biometric Bridge" -CertStoreLocation "Cert:\CurrentUser\My"
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store "TrustedPublisher", "CurrentUser"
    $store.Open("ReadWrite")
    $store.Add($cert)
    $store.Close()
}

Set-AuthenticodeSignature -Certificate $cert -FilePath $bridgeOut | Out-Null
Set-AuthenticodeSignature -Certificate $cert -FilePath (Join-Path $Root "src\native\sbxpc-bridge.exe") | Out-Null
Set-AuthenticodeSignature -Certificate $cert -FilePath $agentOut | Out-Null

Write-Host "   [OK] SbxpcBridge.exe signed." -ForegroundColor Green
Write-Host "   [OK] SatyakiranBiometricAgent.exe signed." -ForegroundColor Green

Write-Host ""
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host "SUCCESS! All native Windows EXEs are ready to run!" -ForegroundColor Green
Write-Host "   - SbxpcBridge.exe              (Fast hardware bridge CLI)" -ForegroundColor Gray
Write-Host "   - SatyakiranBiometricAgent.exe  (Standalone 2-Way Sync Engine)" -ForegroundColor Gray
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host ""
