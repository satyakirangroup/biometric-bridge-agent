# Builds dist\app-<ver>.zip, dist\version.json (signed) and dist\SatyakiranBridge-Setup.exe
# Usage:  scripts\build-release.ps1 -Version 1.0.1 -Repo satyakirangroup/biometric-bridge-agent
# Signing key comes from env UPDATE_SIGNING_KEY_XML (private key XML). Without it the manifest is unsigned.
param(
    [Parameter(Mandatory)] [string]$Version,
    [string]$Repo = "satyakirangroup/biometric-bridge-agent",
    # Host the update files on your own server instead of GitHub, e.g. https://api.satyakiran.co.in/downloads/bridge
    # (the PCs then fetch <BaseUrl>/version.json and <BaseUrl>/app-<ver>.zip; nobody needs a GitHub account/token).
    [string]$BaseUrl = ""
)
$ErrorActionPreference = "Stop"
$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$dist = Join-Path $root "dist"
New-Item -ItemType Directory -Force -Path $dist | Out-Null

Set-Content -Path (Join-Path $root "app\VERSION") -Value $Version -Encoding ASCII -NoNewline
$zip = Join-Path $dist "app-$Version.zip"
Remove-Item $zip -Force -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $root "app\*") -DestinationPath $zip

$hashBytes = [Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes($zip))
$manifest = [ordered]@{
    version = $Version
    url     = $(if ($BaseUrl) { "$($BaseUrl.TrimEnd('/'))/app-$Version.zip" } else { "https://github.com/$Repo/releases/download/v$Version/app-$Version.zip" })
    sha256  = ([BitConverter]::ToString($hashBytes) -replace '-', '').ToLowerInvariant()
}
if ($env:UPDATE_SIGNING_KEY_XML) {
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    $rsa.FromXmlString($env:UPDATE_SIGNING_KEY_XML)
    $manifest.signature = [Convert]::ToBase64String($rsa.SignHash($hashBytes, "SHA256"))
} else { Write-Warning "UPDATE_SIGNING_KEY_XML not set - manifest is NOT signed." }
$manifest | ConvertTo-Json | Set-Content (Join-Path $dist "version.json") -Encoding UTF8

$iscc = Get-Command iscc -ErrorAction SilentlyContinue
if (-not $iscc) { $iscc = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" }
if (-not (Test-Path (Join-Path $root "sdk\SBXPC.ocx"))) { throw "sdk\SBXPC.ocx missing - copy the Realtime SDK files (SBXPC.ocx, *.dll) into the sdk folder first." }
# Optional pre-fill so the installer arrives configured: env DEFAULT_TOKEN / DEFAULT_BRANCH / DEFAULT_IP
$defs = @("/DAppVersion=$Version")
if ($env:DEFAULT_TOKEN)  { $defs += "/DDefaultToken=$($env:DEFAULT_TOKEN)" }
if ($env:DEFAULT_BRANCH) { $defs += "/DDefaultBranch=$($env:DEFAULT_BRANCH)" }
if ($env:DEFAULT_IP)     { $defs += "/DDefaultIp=$($env:DEFAULT_IP)" }
if ($BaseUrl)            { $defs += "/DManifestUrl=$($BaseUrl.TrimEnd('/'))/version.json" }
& $iscc @defs (Join-Path $root "installer\SatyakiranBridge.iss")
Write-Host "Done. Give clients dist\SatyakiranBridge-Setup.exe. To roll out an update, upload dist\app-$Version.zip and dist\version.json to the update location (GitHub release v$Version, or your BaseUrl folder)."
