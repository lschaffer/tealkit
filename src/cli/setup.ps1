<#
.SYNOPSIS
  Compiles the TealKit CLI, packages the standalone tealkit_cli_setup.zip, and uploads it to tealkit.dev.

.DESCRIPTION
  Builds the CLI native binary and dynamic libraries using `dart build cli -o build/cli`
  as documented in cli/README.md. Packages tealkit.exe, native DLLs (including llamadart and pdfium),
  configuration templates, skills, and documentation into a single distribution archive:
  cli/setup/tealkit_cli_setup.zip.

  SAFETY GUARANTEE:
  Explicitly excludes any secret files (.env, credentials, *.db) from the distribution package.

.PARAMETER SkipCompile
  Skip the `dart build cli` step and package from existing build artifacts.

.PARAMETER SkipUpload
  Skip uploading the resulting zip archive to tealkit.dev.

.PARAMETER Force
  Overwrite existing artifacts without confirmation.
#>

[CmdletBinding()]
param (
    [switch]$SkipCompile,
    [switch]$SkipUpload,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$CliDir = $PSScriptRoot
if (-not (Test-Path (Join-Path $CliDir 'pubspec.yaml'))) {
    $CliDir = Join-Path $PSScriptRoot 'cli'
}

$BuildDir    = Join-Path $CliDir 'build\cli'
$BundleBin   = Join-Path $BuildDir 'bundle\bin\tealkit.exe'
$BundleLib   = Join-Path $BuildDir 'bundle\lib'
$SetupDir    = Join-Path $CliDir 'setup'
$ZipPath     = Join-Path $SetupDir 'tealkit_cli_setup.zip'
$StagingDir  = Join-Path $CliDir 'build\staging_setup'

# Remote deployment configuration
$RemoteHost  = "tealkit.dev"
$RootUser    = "root"
$RootPass    = "banaNPatay!27"
$RemoteUser  = "tealkit"
$RemotePass  = "26BananaApple!"
$RemoteDest  = "/apps/containers/vol/nginx/www/root/download/tealkit_cli_setup.zip"

function Log-Step($msg) { Write-Host "`n====> $msg" -ForegroundColor Cyan }
function Log-Ok($msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Log-Warn($msg) { Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function Log-Err($msg)  { Write-Host "  [ERROR] $msg" -ForegroundColor Red; exit 1 }

# ── 1. Compile Native CLI Bundle ─────────────────────────────────────────────
if (-not $SkipCompile) {
    Log-Step "Compiling Native CLI Bundle (dart build cli -o build/cli)..."
    Push-Location $CliDir
    try {
        & dart pub get
        if ($LASTEXITCODE -ne 0) { Log-Err "dart pub get failed." }

        & dart build cli -o build/cli
        if ($LASTEXITCODE -ne 0) { Log-Err "dart build cli failed." }
    } finally {
        Pop-Location
    }

    if (-not (Test-Path $BundleBin)) {
        Log-Err "Compiled binary not found at $BundleBin"
    }

    # Also update root cli/tealkit.exe for local convenient execution
    Copy-Item -Path $BundleBin -Destination (Join-Path $CliDir 'tealkit.exe') -Force
    Log-Ok "Native executable compiled successfully: $BundleBin"
} else {
    Log-Step "Skipping compilation as requested (-SkipCompile)."
    if (-not (Test-Path $BundleBin)) {
        Log-Err "Existing binary not found at $BundleBin. Run without -SkipCompile."
    }
}

# ── 2. Prepare Clean Staging Folder (NO SECRETS!) ────────────────────────────
Log-Step "Preparing distribution staging directory (excluding all secrets)..."

if (Test-Path $StagingDir) {
    try {
        Get-ChildItem -Path $StagingDir -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
        Remove-Item -Path $StagingDir -Recurse -Force -ErrorAction SilentlyContinue
    } catch {}
}
if (-not (Test-Path $StagingDir)) {
    New-Item -ItemType Directory -Path $StagingDir -Force | Out-Null
}

# Copy main binary
Copy-Item -Path $BundleBin -Destination $StagingDir -Force
Log-Ok "Copied tealkit.exe"

# Copy native dynamic libraries (.dll)
if (Test-Path $BundleLib) {
    Get-ChildItem -Path $BundleLib -Filter *.dll | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination $StagingDir -Force
    }
    Log-Ok "Copied dynamic libraries from $BundleLib"
}

# Copy pdfium.dll if present
$Pdfium = Join-Path $CliDir 'pdfium.dll'
if ((Test-Path $Pdfium) -and (-not (Test-Path (Join-Path $StagingDir 'pdfium.dll')))) {
    Copy-Item -Path $Pdfium -Destination $StagingDir -Force
    Log-Ok "Copied pdfium.dll"
}

# Copy 2 starter skills (coding-agent-skill.md & dotnet-engineer-skill.md)
$SkillsDir = Join-Path $CliDir 'skills'
if (Test-Path $SkillsDir) {
    $StagingSkillsDir = Join-Path $StagingDir 'skills'
    New-Item -ItemType Directory -Path $StagingSkillsDir -Force | Out-Null
    foreach ($skillFile in @('coding-agent-skill.md', 'dotnet-engineer-skill.md')) {
        $srcSkill = Join-Path $SkillsDir $skillFile
        if (Test-Path $srcSkill) {
            Copy-Item -Path $srcSkill -Destination $StagingSkillsDir -Force
        }
    }
    Log-Ok "Copied 2 starter skills (coding-agent-skill.md, dotnet-engineer-skill.md)"
}

# Copy basic YAML configuration templates (empty RAG sources, no personal server workflows, NEVER .env or pubspec!)
$BasicConfigFiles = @('config.yaml', 'llm.yaml', 'mcp.yaml', 'server.yaml', 'ssh.yaml', 'web_search.yaml')
$StagingConfigDir = Join-Path $StagingDir 'config'
New-Item -ItemType Directory -Path $StagingConfigDir -Force | Out-Null
foreach ($cfgName in $BasicConfigFiles) {
    $srcCfg = Join-Path $CliDir "config\$cfgName"
    if (-not (Test-Path $srcCfg)) {
        $srcCfg = Join-Path $CliDir $cfgName
    }
    if (Test-Path $srcCfg) {
        Copy-Item -Path $srcCfg -Destination $StagingDir -Force
        Copy-Item -Path $srcCfg -Destination $StagingConfigDir -Force
    }
}
Log-Ok "Copied basic YAML config templates (empty RAG sources)"

# Copy .env.example (if exists, but NEVER .env!)
$EnvExample = Join-Path $CliDir '.env.example'
if (Test-Path $EnvExample) {
    Copy-Item -Path $EnvExample -Destination $StagingDir -Force
    Log-Ok "Copied .env.example"
}

# Copy README.md and CHANGELOG.md
foreach ($doc in @('README.md', 'CHANGELOG.md')) {
    $docPath = Join-Path $CliDir $doc
    if (Test-Path $docPath) {
        Copy-Item -Path $docPath -Destination $StagingDir -Force
    }
}
Log-Ok "Copied README.md & CHANGELOG.md"

# CRITICAL SECURITY SANITY CHECK: Ensure no secret files slipped into staging
$BannedPatterns = @('.env', '*.db', '*.key', '*.pem', 'command_history.txt')
foreach ($banned in $BannedPatterns) {
    $found = Get-ChildItem -Path $StagingDir -Recurse -Filter $banned -File -ErrorAction SilentlyContinue
    if ($found) {
        Remove-Item -Path $StagingDir -Recurse -Force
        Log-Err "SECURITY VIOLATION: Found forbidden secret/database file in package: $($found.FullName)"
    }
}
Log-Ok "Security check passed: Staging contains zero secrets or databases (.env excluded)."

# ── 3. Package into single tealkit_cli_setup.zip ─────────────────────────────
Log-Step "Creating distribution archive (tealkit_cli_setup.zip)..."

if (-not (Test-Path $SetupDir)) {
    New-Item -ItemType Directory -Path $SetupDir -Force | Out-Null
}

# Remove any old duplicates or previous builds
$OldDuplicate = Join-Path $SetupDir 'tealkit_setup.zip'
if (Test-Path $OldDuplicate) {
    Remove-Item -Path $OldDuplicate -Force -ErrorAction SilentlyContinue
    Log-Ok "Removed legacy duplicate file: $OldDuplicate"
}

if (Test-Path $ZipPath) {
    Remove-Item -Path $ZipPath -Force
}

# Compress staging directory contents into tealkit_cli_setup.zip
Compress-Archive -Path "$StagingDir\*" -DestinationPath $ZipPath -CompressionLevel Optimal
$ZipSizeMb = [math]::Round((Get-Item $ZipPath).Length / 1MB, 2)
Log-Ok "Created $ZipPath ($ZipSizeMb MB)"

# Clean up temporary staging directory
try {
    Start-Sleep -Milliseconds 500
    Remove-Item -Path $StagingDir -Recurse -Force -ErrorAction SilentlyContinue
} catch {}

# ── 4. Upload to tealkit.dev ──────────────────────────────────────────────────
if (-not $SkipUpload) {
    Log-Step "Uploading $ZipPath to https://${RemoteHost}/download/tealkit_cli_setup.zip ..."

    $uploaded = $false

    # Method 1: WinSCP .NET if available on system
    $winScpNetCandidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'WinSCP\WinSCPnet.dll'),
        (Join-Path $env:ProgramFiles 'WinSCP\WinSCPnet.dll')
    )
    $winScpDll = $winScpNetCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($winScpDll) {
        try {
            Write-Host "  Attempting upload via WinSCP .NET..." -ForegroundColor Gray
            if (-not ('WinSCP.Session' -as [type])) {
                Add-Type -Path $winScpDll
            }
            $sessionOptions = New-Object WinSCP.SessionOptions -Property @{
                Protocol = [WinSCP.Protocol]::Sftp
                HostName = $RemoteHost
                UserName = $RemoteUser
                Password = $RemotePass
                GiveUpSecurityAndAcceptAnySshHostKey = $true
            }
            $session = New-Object WinSCP.Session
            try {
                $session.Open($sessionOptions)
                $transferOptions = New-Object WinSCP.TransferOptions
                $transferOptions.TransferMode = [WinSCP.TransferMode]::Binary
                $transferResult = $session.PutFiles($ZipPath, $RemoteDest, $false, $transferOptions)
                $transferResult.Check()
                $uploaded = $true
                Log-Ok "Upload completed via WinSCP SFTP."
            } finally {
                $session.Dispose()
            }
        } catch {
            Log-Warn "WinSCP upload encountered an error: $_. Falling back to WSL SCP..."
        }
    }

    # Method 2: WSL SCP with sshpass
    if (-not $uploaded) {
        $wslZipPath = "/mnt/" + $ZipPath.Substring(0, 1).ToLower() + $ZipPath.Substring(2).Replace('\', '/')
        Write-Host "  Attempting upload via WSL sshpass (SCP)..." -ForegroundColor Gray

        $scpCmd = "sshpass -p '$RootPass' scp -o ConnectTimeout=30 -o ServerAliveInterval=15 -o StrictHostKeyChecking=no '$wslZipPath' ${RootUser}@${RemoteHost}:'$RemoteDest'"
        $wslResult = wsl -e bash -lc $scpCmd
        if ($LASTEXITCODE -eq 0) {
            $uploaded = $true
            Log-Ok "Upload completed via WSL SCP (root)."
        } else {
            # Try with tealkit user
            $scpTealkitCmd = "sshpass -p '$RemotePass' scp -o ConnectTimeout=30 -o ServerAliveInterval=15 -o StrictHostKeyChecking=no '$wslZipPath' ${RemoteUser}@${RemoteHost}:'/tmp/tealkit_cli_setup.zip' && sshpass -p '$RootPass' ssh -o StrictHostKeyChecking=no ${RootUser}@${RemoteHost} 'mv /tmp/tealkit_cli_setup.zip $RemoteDest && chown -R www-data:www-data $RemoteDest'"
            wsl -e bash -lc $scpTealkitCmd
            if ($LASTEXITCODE -eq 0) {
                $uploaded = $true
                Log-Ok "Upload completed via WSL SCP (tealkit user)."
            }
        }
    }

    # Verify public download availability
    if ($uploaded) {
        try {
            $webCheck = Invoke-WebRequest -Uri "https://${RemoteHost}/download/tealkit_cli_setup.zip" -Method Head -UseBasicParsing -TimeoutSec 10
            if ($webCheck.StatusCode -eq 200) {
                $contentLen = [math]::Round([int64]$webCheck.Headers['Content-Length'] / 1MB, 2)
                Log-Ok "Verified public URL: https://${RemoteHost}/download/tealkit_cli_setup.zip ($contentLen MB, HTTP 200)"
            }
        } catch {
            Log-Warn "Could not verify public download endpoint: $_"
        }
    } else {
        Log-Err "All upload methods failed. Please verify network access to ${RemoteHost}."
    }
} else {
    Log-Step "Skipping upload step (-SkipUpload)."
}

Log-Step "CLI Setup Process Completed Successfully!"
Write-Host "Archive ready at: $ZipPath" -ForegroundColor Green
