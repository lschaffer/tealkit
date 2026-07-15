<#
.SYNOPSIS
    Starts the TealKit Dart REST API server locally on Windows.
.DESCRIPTION
    Sets up the necessary environment variables (data directories, ports, hosts, etc.),
    adds the project root to PATH so that duckdb.dll is resolved,
    ensures dependencies are fetched, and launches the server.
#>

$ErrorActionPreference = 'Stop'

# Project paths
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
$serverDir = Join-Path $projectRoot "server"
$apiDir = Join-Path $projectRoot "api"

Write-Host "=== Starting TealKit Server ===" -ForegroundColor Cyan

# 1. Add project root to PATH so Windows finds duckdb.dll in current directory or PATH
Write-Host "Adding project root to PATH for duckdb.dll resolution..." -ForegroundColor Gray
$originalPath = $env:PATH
$env:PATH = "$projectRoot;$env:PATH"

# 2. Setup standard environment variables
$dataDir = Join-Path $env:USERPROFILE ".tealkit-server"
if (-not (Test-Path $dataDir)) {
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
    Write-Host "Created data directory: $dataDir" -ForegroundColor Gray
}

$env:TEALKIT_DATA_DIR = $dataDir
$env:TEALKIT_PORT = "7771"
$env:TEALKIT_HOST = "127.0.0.1"
$env:TEALKIT_FILES_DIR = Join-Path $dataDir "files"
$env:TEALKIT_MODELS_DIR = Join-Path $dataDir "models"

Write-Host "Environment configured:" -ForegroundColor Gray
Write-Host "  TEALKIT_DATA_DIR   = $env:TEALKIT_DATA_DIR" -ForegroundColor Gray
Write-Host "  TEALKIT_PORT       = $env:TEALKIT_PORT" -ForegroundColor Gray
Write-Host "  TEALKIT_HOST       = $env:TEALKIT_HOST" -ForegroundColor Gray

# 3. Ensure dependencies are resolved
Write-Host "Checking server dependencies..." -ForegroundColor Cyan
Push-Location $serverDir
try {
    # If .dart_tool does not exist, run pub get
    if (-not (Test-Path ".dart_tool")) {
        Write-Host "Running dart pub get..." -ForegroundColor Gray
        & dart pub get
    }
    
    # 4. Launch the server
    Write-Host "Launching server via Dart..." -ForegroundColor Green
    & dart run bin/tealkit_server.dart
}
finally {
    # Restore path and location
    $env:PATH = $originalPath
    Pop-Location
}
