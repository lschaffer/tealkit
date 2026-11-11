<#
.SYNOPSIS
  Builds and deploys the TealKit CLI bundle to tealkit.dev.

.DESCRIPTION
  Delegates to setup.ps1 to run `dart build cli -o build/cli`, verify distribution staging
  (zero secrets guarantee), package tealkit_cli_setup.zip, and upload via WinSCP SFTP/WSL SCP.
#>

[CmdletBinding()]
param (
    [switch]$SkipCompile,
    [switch]$SkipUpload,
    [switch]$Force
)

$PSScript = Join-Path $PSScriptRoot 'setup.ps1'
if (-not (Test-Path $PSScript)) {
    Write-Error "setup.ps1 not found in $PSScriptRoot"
    exit 1
}

& $PSScript @PSBoundParameters

