#!/usr/bin/env pwsh
# Build a production-ready signed MSIX package for Windows.
#
# MODES:
#   --store       (default) Creates an unsigned Store-ready MSIX.
#                 Upload directly to Microsoft Partner Center -- Microsoft signs it.
#
#   --sideload    Creates a signed MSIX for sideloading / Enterprise deployment.
#                 Requires --certificate-path and --certificate-password.
#
# USAGE:
#   # Store submission (unsigned, ready for Partner Center upload):
#   .\scripts\launch-build-windows-msix.ps1
#
#   # Sideload build (signed with your PFX):
#   .\scripts\launch-build-windows-msix.ps1 --sideload `
#       --certificate-path "certs\tealkit-dev.pfx" `
#       --certificate-password "YourPfxPassword"
#
#   # Override dart-define secrets (e.g. CI):
#   .\scripts\launch-build-windows-msix.ps1 `
#       --gmail-client-id $env:GMAIL_CLIENT_ID `
#       --gmail-client-secret $env:GMAIL_CLIENT_SECRET

param(
  [switch]$Sideload,
  [string]$CertificatePath      = $env:MSIX_CERT_PATH,
  [string]$CertificatePassword  = $env:MSIX_CERT_PASSWORD,
  [string]$GmailClientId        = $env:GMAIL_CLIENT_ID,
  [string]$GmailClientSecret    = $env:GMAIL_CLIENT_SECRET,
  [string]$GoogleSearchApiKey   = $env:GOOGLE_SEARCH_API_KEY,
  [string]$GoogleSearchEngineId = $env:GOOGLE_SEARCH_ENGINE_ID,
  [string]$BuildVersion         = '',  # e.g. "1.2.3" or "1.2.3+42" -- skips auto-increment
  [switch]$NoIncrement               # use current pubspec version without bumping build number
)

$ErrorActionPreference = 'Stop'
Set-Location "$PSScriptRoot\.."

# ── 1. Validate sideload params ──────────────────────────────────────────────
if ($Sideload) {
  if (-not $CertificatePath) {
    Write-Error "Sideload mode requires --certificate-path (or env MSIX_CERT_PATH)."
    exit 1
  }
  if (-not (Test-Path $CertificatePath)) {
    Write-Error "Certificate not found: $CertificatePath"
    exit 1
  }
  if (-not $CertificatePassword) {
    Write-Warning "No certificate password provided -- assuming the PFX has no password."
  }
}

# Load .env file if exists
if (Test-Path "$PSScriptRoot\.env") {
    Get-Content "$PSScriptRoot\.env" | Where-Object { $_ -and $_ -notlike "#*" } | ForEach-Object {
        $name, $val = $_ -split '=', 2
        if ($name -and $val) {
            $envKey = $name.Trim()
            $envVal = $val.Trim()
            [System.Environment]::SetEnvironmentVariable($envKey, $envVal)
            if ($envKey -eq "GMAIL_CLIENT_ID" -and -not $GmailClientId) { $GmailClientId = $envVal }
            if ($envKey -eq "GMAIL_CLIENT_SECRET" -and -not $GmailClientSecret) { $GmailClientSecret = $envVal }
            if ($envKey -eq "GOOGLE_WEB_CLIENT_ID" -and -not $GoogleWebClientId) { $GoogleWebClientId = $envVal }
            if ($envKey -eq "GOOGLE_SEARCH_API_KEY" -and -not $GoogleSearchApiKey) { $GoogleSearchApiKey = $envVal }
            if ($envKey -eq "GOOGLE_SEARCH_ENGINE_ID" -and -not $GoogleSearchEngineId) { $GoogleSearchEngineId = $envVal }
        }
    }
}

# ── 2. Prepare dart-define flags ─────────────────────────────────────────────
$defines = @()
if ($GmailClientId)        { $defines += "--dart-define=GMAIL_CLIENT_ID=$GmailClientId" }
if ($GmailClientSecret)    { $defines += "--dart-define=GMAIL_CLIENT_SECRET=$GmailClientSecret" }
if ($GoogleSearchApiKey)   { $defines += "--dart-define=GOOGLE_SEARCH_API_KEY=$GoogleSearchApiKey" }
if ($GoogleSearchEngineId) { $defines += "--dart-define=GOOGLE_SEARCH_ENGINE_ID=$GoogleSearchEngineId" }
if ($env:GOOGLE_WEB_CLIENT_ID) { $defines += "--dart-define=GOOGLE_WEB_CLIENT_ID=$($env:GOOGLE_WEB_CLIENT_ID)" }
if ($env:SERPER_API_KEY) { $defines += "--dart-define=SERPER_API_KEY=$($env:SERPER_API_KEY)" }
if ($env:GOOGLE_IOS_CLIENT_ID) { $defines += "--dart-define=GOOGLE_IOS_CLIENT_ID=$($env:GOOGLE_IOS_CLIENT_ID)" }

# ── 2b. Version management ────────────────────────────────────────────────────
$pubspecPath    = 'pubspec.yaml'
$pubspecContent = Get-Content $pubspecPath -Raw

if ($BuildVersion) {
  # Manual override: accept "major.minor.patch" or "major.minor.patch+build"
  if ($BuildVersion -match '^(\d+\.\d+\.\d+)(?:\+(\d+))?$') {
    $semVer   = $Matches[1]
    $buildNum = if ($Matches[2]) { [int]$Matches[2] } else { 0 }
  } else {
    Write-Error "Invalid --BuildVersion '$BuildVersion'. Expected major.minor.patch or major.minor.patch+build."
    exit 1
  }
  Write-Host "Version (manual): $semVer+$buildNum" -ForegroundColor Yellow
} else {
  # Auto: read current version from pubspec.yaml
  if ($pubspecContent -match 'version:\s+(\d+)\.(\d+)\.(\d+)\+(\d+)') {
    $semVer   = "$($Matches[1]).$($Matches[2]).$($Matches[3])"
    $buildNum = [int]$Matches[4]
  } else {
    Write-Error 'Could not parse version from pubspec.yaml. Expected format: major.minor.patch+build'
    exit 1
  }

  if (-not $NoIncrement) {
    $buildNum++
    $newVersionLine = "version: $semVer+$buildNum"
    $pubspecContent = $pubspecContent -replace 'version:\s+\d+\.\d+\.\d+\+\d+', $newVersionLine
    Set-Content $pubspecPath $pubspecContent -NoNewline
    Write-Host "Auto-incremented -> $newVersionLine  (pubspec.yaml updated)" -ForegroundColor Green
  } else {
    Write-Host "No-increment mode: using current version $semVer+$buildNum" -ForegroundColor Yellow
  }
}

# Flutter flags derived from the resolved version
$buildNameFlag   = @("--build-name=$semVer", "--build-number=$buildNum")
# MSIX version must be 4-part with revision = 0 (Store rejects non-zero revision).
# Encode the build number as the 3rd (patch) component: major.minor.build.0
$semParts        = $semVer -split '\.'
$msixVersionFull = "$($semParts[0]).$($semParts[1]).$buildNum.0"

# ── 3. Install dependencies ───────────────────────────────────────────────────
Write-Host "`n-- flutter pub get --" -ForegroundColor Cyan
flutter pub get

# ── 4. Flutter build windows (release) ───────────────────────────────────────
Write-Host "`n-- flutter build windows --release --" -ForegroundColor Cyan
$buildArgs = @('build', 'windows', '--release') + $buildNameFlag + $defines
& flutter @buildArgs
if ($LASTEXITCODE -ne 0) { Write-Error "flutter build windows failed."; exit 1 }

# ── 5. Create MSIX ───────────────────────────────────────────────────────────
Write-Host "`n-- dart run msix:create --" -ForegroundColor Cyan

$msixArgs = @()

if ($Sideload) {
  Write-Host "Mode: SIDELOAD (signed with $CertificatePath)" -ForegroundColor Yellow
  # Override pubspec store:true for sideload signing.
  $msixArgs += '--store=false'
  $msixArgs += "--certificate-path=$CertificatePath"
  if ($CertificatePassword) {
    $msixArgs += "--certificate-password=$CertificatePassword"
  }
} else {
  Write-Host "Mode: STORE (unsigned -- ready for Partner Center upload)" -ForegroundColor Green
  # pubspec.yaml already has store: true -- no overrides needed.
}

# Always pass the explicit 4-part version so Partner Center sees the bump
$msixArgs += "--version=$msixVersionFull"

& dart run msix:create @msixArgs
if ($LASTEXITCODE -ne 0) { Write-Error "msix:create failed."; exit 1 }

# ── 6. Report output location ────────────────────────────────────────────────
$msixFile = Get-ChildItem -Path "build\windows\x64\runner\Release" -Filter "*.msix" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1

if ($msixFile) {
  Write-Host "`n✅  MSIX ready: $($msixFile.FullName)" -ForegroundColor Green
  Write-Host "    Size: $([Math]::Round($msixFile.Length / 1MB, 2)) MB"
} else {
  Write-Warning "MSIX file not found in expected output folder -- check the msix:create output above."
}

if (-not $Sideload) {
  Write-Host @"

-- Next steps for Microsoft Store submission ------------------------------------------
  1. Sign in to Partner Center:  https://partner.microsoft.com/dashboard
  2. Create / open your app submission.
  3. Upload the .msix file above as the package.
  4. Make sure pubspec.yaml identity_name and publisher match Partner Center
     EXACTLY (Settings -> App identity in Partner Center).
  5. Fill in store listing, pricing, availability and submit.
--------------------------------------------------------------------------------
"@ -ForegroundColor Cyan
}
