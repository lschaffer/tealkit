#!/usr/bin/env pwsh
# Build a production-ready MSIX package for Windows.
#
# EDITION FLAVOR:
#   Default (Store) : LIGHT edition (no llamadart / embedded LLM native DLLs;
#                     passes --dart-define=TEALKIT_LIGHT=true and overrides
#                     llamadart with third_party/llamadart_stub).
#   -Full           : FULL edition (includes llamadart on-device GGUF engine).
#
# MODES:
#   Store (default) : Creates an unsigned Store-ready MSIX.
#                     Upload directly to Microsoft Partner Center -- Microsoft signs it.
#   -Sideload       : Creates a signed MSIX for sideloading / Enterprise deployment.
#                     Requires -CertificatePath and -CertificatePassword.
#
# USAGE:
#   # Microsoft Store Light submission (default, unsigned):
#   .\scripts\launch-build-windows-msix.ps1
#
#   # Full MSIX build (optional):
#   .\scripts\launch-build-windows-msix.ps1 -Full

param(
  [switch]$Sideload,
  [switch]$Full,
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
$RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path
Set-Location $RepoRoot

$IsLight = -not $Full

# ── 1. Validate sideload params ──────────────────────────────────────────────
if ($Sideload) {
  if (-not $CertificatePath) {
    Write-Error "Sideload mode requires -CertificatePath (or env MSIX_CERT_PATH)."
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
if ($IsLight)              { $defines += "--dart-define=TEALKIT_LIGHT=true" }
if ($GmailClientId)        { $defines += "--dart-define=GMAIL_CLIENT_ID=$GmailClientId" }
if ($GmailClientSecret)    { $defines += "--dart-define=GMAIL_CLIENT_SECRET=$GmailClientSecret" }
if ($GoogleSearchApiKey)   { $defines += "--dart-define=GOOGLE_SEARCH_API_KEY=$GoogleSearchApiKey" }
if ($GoogleSearchEngineId) { $defines += "--dart-define=GOOGLE_SEARCH_ENGINE_ID=$GoogleSearchEngineId" }
if ($env:GOOGLE_WEB_CLIENT_ID) { $defines += "--dart-define=GOOGLE_WEB_CLIENT_ID=$($env:GOOGLE_WEB_CLIENT_ID)" }
if ($env:SERPER_API_KEY) { $defines += "--dart-define=SERPER_API_KEY=$($env:SERPER_API_KEY)" }
if ($env:GOOGLE_IOS_CLIENT_ID) { $defines += "--dart-define=GOOGLE_IOS_CLIENT_ID=$($env:GOOGLE_IOS_CLIENT_ID)" }

# ── 2b. Version management ────────────────────────────────────────────────────
$pubspecPath      = Join-Path $RepoRoot 'pubspec.yaml'
$overridesPath    = Join-Path $RepoRoot 'pubspec_overrides.yaml'
$utf8NoBom        = New-Object System.Text.UTF8Encoding($false)
$pubspecContent   = [System.IO.File]::ReadAllText($pubspecPath, [System.Text.Encoding]::UTF8)

if ($BuildVersion) {
  if ($BuildVersion -match '^(\d+\.\d+\.\d+)(?:\+(\d+))?$') {
    $semVer   = $Matches[1]
    $buildNum = if ($Matches[2]) { [int]$Matches[2] } else { 0 }
  } else {
    Write-Error "Invalid -BuildVersion '$BuildVersion'. Expected major.minor.patch or major.minor.patch+build."
    exit 1
  }
  Write-Host "Version (manual): $semVer+$buildNum" -ForegroundColor Yellow
} else {
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
    [System.IO.File]::WriteAllText($pubspecPath, $pubspecContent, $utf8NoBom)
    Write-Host "Auto-incremented -> $newVersionLine  (pubspec.yaml updated)" -ForegroundColor Green
  } else {
    Write-Host "No-increment mode: using current version $semVer+$buildNum" -ForegroundColor Yellow
  }
}

$editionLabel = if ($IsLight) { "LIGHT (Store default -- no llamadart native libs)" } else { "FULL (with llamadart)" }
Write-Host "Edition: $editionLabel" -ForegroundColor Cyan

# Flutter flags derived from the resolved version
$buildNameFlag   = @("--build-name=$semVer", "--build-number=$buildNum")
# MSIX version must be 4-part with revision = 0 (Store rejects non-zero revision).
$semParts        = $semVer -split '\.'
$msixVersionFull = "$($semParts[0]).$($semParts[1]).$buildNum.0"

$pubspecBackup   = [System.IO.File]::ReadAllText($pubspecPath, [System.Text.Encoding]::UTF8)
$hasOverrides    = Test-Path -LiteralPath $overridesPath
$overridesBackup = if ($hasOverrides) { [System.IO.File]::ReadAllText($overridesPath, [System.Text.Encoding]::UTF8) } else { $null }

function Set-LlamaDartStub([string]$content) {
  return ($content -replace '(?m)^(\s*)llamadart:\s*\^?[0-9][^\r\n]*\r?$', ('$1llamadart:' + "`r`n" + '$1  path: third_party/llamadart_stub'))
}

try {
  if ($IsLight) {
    Write-Host "`n-- Applying temporary Light edition llamadart_stub override --" -ForegroundColor Cyan
    [System.IO.File]::WriteAllText($pubspecPath, (Set-LlamaDartStub $pubspecBackup), $utf8NoBom)
    if ($hasOverrides) {
      [System.IO.File]::WriteAllText($overridesPath, (Set-LlamaDartStub $overridesBackup), $utf8NoBom)
    }
    foreach ($staleDir in @(
      (Join-Path $RepoRoot 'build\windows\x64\runner\Release'),
      (Join-Path $RepoRoot 'build\native_assets\windows')
    )) {
      if (Test-Path -LiteralPath $staleDir) {
        Write-Host "-- Cleaning stale build output: $staleDir --" -ForegroundColor Cyan
        Remove-Item -LiteralPath $staleDir -Recurse -Force
      }
    }
  }

  # ── 3. Install dependencies ─────────────────────────────────────────────────
  Write-Host "`n-- flutter pub get --" -ForegroundColor Cyan
  & flutter pub get
  if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed." }

  # ── 4. Flutter build windows (release) ─────────────────────────────────────
  Write-Host "`n-- flutter build windows --release --" -ForegroundColor Cyan
  $buildArgs = @('build', 'windows', '--release') + $buildNameFlag + $defines
  & flutter @buildArgs
  if ($LASTEXITCODE -ne 0) { throw "flutter build windows failed." }

  # ── 5. Create MSIX ─────────────────────────────────────────────────────────
  Write-Host "`n-- dart run msix:create --" -ForegroundColor Cyan

  $msixArgs = @('--build-windows=false')

  if ($Sideload) {
    Write-Host "Mode: SIDELOAD (signed with $CertificatePath)" -ForegroundColor Yellow
    $msixArgs += '--store=false'
    $msixArgs += "--certificate-path=$CertificatePath"
    if ($CertificatePassword) {
      $msixArgs += "--certificate-password=$CertificatePassword"
    }
  } else {
    Write-Host "Mode: STORE (unsigned -- ready for Partner Center upload)" -ForegroundColor Green
  }

  $msixArgs += "--version=$msixVersionFull"

  & dart run msix:create @msixArgs
  if ($LASTEXITCODE -ne 0) { throw "msix:create failed." }
} finally {
  if ($IsLight) {
    [System.IO.File]::WriteAllText($pubspecPath, $pubspecBackup, $utf8NoBom)
    if ($hasOverrides -and $null -ne $overridesBackup) {
      [System.IO.File]::WriteAllText($overridesPath, $overridesBackup, $utf8NoBom)
    }
  }
}

# ── 6. Report output location ────────────────────────────────────────────────
$msixFile = Get-ChildItem -Path "build\windows\x64\runner\Release" -Filter "*.msix" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1

if ($msixFile) {
  Write-Host "`n[OK] MSIX ready ($editionLabel): $($msixFile.FullName)" -ForegroundColor Green
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
