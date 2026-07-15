#!/usr/bin/env pwsh
# Creates a self-signed code-signing certificate for local MSIX sideloading.
# The generated .pfx is suitable for passing to launch-build-windows-msix.ps1
# with the --sideload flag.
#
# NOTE: Self-signed certs are NOT accepted by Microsoft Store.
#       They are only for local testing / Enterprise sideloading.
#
# USAGE:
#   .\scripts\create-dev-cert.ps1 -Publisher "CN=TealKit Software" `
#       -OutputPfx "certs\tealkit-dev.pfx" -Password "YourPassword"

param(
  [string]$Publisher  = "CN=TealKit Software",   # must match publisher in pubspec msix_config
  [string]$OutputPfx  = "certs\tealkit-dev.pfx",
  [string]$Password   = "TealKitDev123!"
)

$ErrorActionPreference = 'Stop'
Set-Location "$PSScriptRoot\.."

# Make sure output folder exists.
$pfxDir = Split-Path $OutputPfx -Parent
if ($pfxDir -and -not (Test-Path $pfxDir)) {
  New-Item -ItemType Directory -Path $pfxDir | Out-Null
}

Write-Host "Creating self-signed code-signing certificate…" -ForegroundColor Cyan
Write-Host "  Subject : $Publisher"
Write-Host "  Output  : $OutputPfx"

# Create the cert in the current user cert store.
$cert = New-SelfSignedCertificate `
  -Type Custom `
  -Subject $Publisher `
  -KeyUsage DigitalSignature `
  -FriendlyName "TealKit Dev Code-Signing" `
  -CertStoreLocation "Cert:\CurrentUser\My" `
  -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3", "2.5.29.19={text}") `
  -NotAfter (Get-Date).AddYears(3)

# Export to .pfx.
$securePassword = ConvertTo-SecureString -String $Password -Force -AsPlainText
Export-PfxCertificate -Cert $cert -FilePath $OutputPfx -Password $securePassword | Out-Null

Write-Host "`n✅  Certificate created: $((Resolve-Path $OutputPfx).Path)" -ForegroundColor Green
Write-Host "    Thumbprint : $($cert.Thumbprint)"
Write-Host "    Expires    : $($cert.NotAfter.ToString('yyyy-MM-dd'))"
Write-Host @"

-- Installing the cert so Windows trusts the sideloaded MSIX ------------------
  Run the following ONCE on every machine that will install the sideloaded MSIX:

    Import-Certificate -FilePath "$OutputPfx" ``
        -CertStoreLocation Cert:\LocalMachine\TrustedPeople

  OR double-click the .cer file and install it to "Trusted People".

-- Using it in the sideload build ----------------------------------------------
  .\scripts\launch-build-windows-msix.ps1 --sideload ``
      --certificate-path "$OutputPfx" ``
      --certificate-password "$Password"
--------------------------------------------------------------------------------
"@ -ForegroundColor Cyan

# Remove the cert from the personal store (the .pfx is sufficient).
Remove-Item -Path "Cert:\CurrentUser\My\$($cert.Thumbprint)"
Write-Host "Cert removed from personal store (exported to .pfx only)." -ForegroundColor Gray
