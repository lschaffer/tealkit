#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Download and register a model from HuggingFace to Ollama.

.DESCRIPTION
    Downloads GGUF and Modelfile from a HuggingFace repository and registers
    the model with Ollama. The Modelfile contains the required TEMPLATE for
    tool support.

.PARAMETER Repo
    HuggingFace repository (e.g., "username/qwen25-3b-weathersensorsmcp")

.PARAMETER ModelName
    Optional: Override the local Ollama model name. If not specified, uses
    the repo name without the username prefix.

.PARAMETER OutputDir
    Optional: Directory to download files to. Defaults to "./hf_models/<repo-name>"

.PARAMETER GgufPattern
    Optional: Pattern to match GGUF filename (e.g., "*q5_k_m.gguf", "*f16.gguf")
    Defaults to "*q5_k_m.gguf" (recommended quantization)

.EXAMPLE
    .\download-hf-model.ps1 -Repo "username/qwen25-3b-weathersensorsmcp"

.EXAMPLE
    .\download-hf-model.ps1 -Repo "username/ministral-3b-weathersensorsmcp" -ModelName "ministral-weather"

.EXAMPLE
    .\download-hf-model.ps1 -Repo "username/qwen25-3b-weathersensorsmcp" -GgufPattern "*f16.gguf"
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Repo,

    [Parameter(Mandatory=$false)]
    [string]$ModelName = "",

    [Parameter(Mandatory=$false)]
    [string]$OutputDir = "",

    [Parameter(Mandatory=$false)]
    [string]$GgufPattern = "*q5_k_m.gguf"
)

$ErrorActionPreference = "Stop"

# ══════════════════════════════════════════════════════════
# CONFIGURATION
# ══════════════════════════════════════════════════════════

$BaseUrl = "https://huggingface.co/$Repo/resolve/main"

# Derive model name from repo if not specified
if ([string]::IsNullOrWhiteSpace($ModelName)) {
    $ModelName = ($Repo -split '/')[-1]
}

# Set output directory
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $repoBasename = ($Repo -split '/')[-1]
    $OutputDir = Join-Path "." "hf_models" $repoBasename
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Download & Register HuggingFace Model to Ollama" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "Repository    : $Repo" -ForegroundColor White
Write-Host "Model name    : $ModelName" -ForegroundColor White
Write-Host "Output dir    : $OutputDir" -ForegroundColor White
Write-Host "GGUF pattern  : $GgufPattern" -ForegroundColor White
Write-Host ""

# ══════════════════════════════════════════════════════════
# STEP 1: Fetch available files from HF repo
# ══════════════════════════════════════════════════════════

Write-Host "[1/5] Fetching file list from HuggingFace..." -ForegroundColor Yellow

$apiUrl = "https://huggingface.co/api/models/$Repo/tree/main"
try {
    $response = Invoke-RestMethod -Uri $apiUrl -Method Get -ErrorAction Stop
    $files = $response | Where-Object { $_.type -eq "file" } | Select-Object -ExpandProperty path
} catch {
    Write-Host "✗ Failed to fetch file list from $Repo" -ForegroundColor Red
    Write-Host "  Make sure the repository exists and is public." -ForegroundColor Red
    exit 1
}

# Find GGUF file matching pattern
$ggufFile = $files | Where-Object { $_ -like $GgufPattern } | Select-Object -First 1

if (-not $ggufFile) {
    Write-Host "✗ No GGUF file matching pattern '$GgufPattern' found in repository." -ForegroundColor Red
    Write-Host "  Available files:" -ForegroundColor Yellow
    $files | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
    exit 1
}

# Check for Modelfile
$hasModelfile = $files -contains "Modelfile"
if (-not $hasModelfile) {
    Write-Host "✗ Modelfile not found in repository." -ForegroundColor Red
    Write-Host "  The Modelfile is required for tool support." -ForegroundColor Red
    exit 1
}

Write-Host "✓ Found GGUF: $ggufFile" -ForegroundColor Green
Write-Host "✓ Found Modelfile" -ForegroundColor Green

# ══════════════════════════════════════════════════════════
# STEP 2: Create output directory
# ══════════════════════════════════════════════════════════

Write-Host ""
Write-Host "[2/5] Creating output directory..." -ForegroundColor Yellow

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    Write-Host "✓ Created: $OutputDir" -ForegroundColor Green
} else {
    Write-Host "✓ Directory exists: $OutputDir" -ForegroundColor Green
}

# ══════════════════════════════════════════════════════════
# STEP 3: Download GGUF
# ══════════════════════════════════════════════════════════

Write-Host ""
Write-Host "[3/5] Downloading GGUF (this may take several minutes)..." -ForegroundColor Yellow

$ggufUrl = "$BaseUrl/$ggufFile"
$ggufPath = Join-Path $OutputDir $ggufFile

if (Test-Path $ggufPath) {
    Write-Host "✓ GGUF already exists, skipping download: $ggufPath" -ForegroundColor Green
} else {
    try {
        # Use curl for better progress indication
        & curl -L -o $ggufPath $ggufUrl --progress-bar
        if ($LASTEXITCODE -ne 0) { throw "curl failed with exit code $LASTEXITCODE" }
        Write-Host "✓ Downloaded: $ggufPath" -ForegroundColor Green
    } catch {
        Write-Host "✗ Failed to download GGUF: $_" -ForegroundColor Red
        exit 1
    }
}

# ══════════════════════════════════════════════════════════
# STEP 4: Download Modelfile
# ══════════════════════════════════════════════════════════

Write-Host ""
Write-Host "[4/5] Downloading Modelfile..." -ForegroundColor Yellow

$modelfileUrl = "$BaseUrl/Modelfile"
$modelfilePath = Join-Path $OutputDir "Modelfile"

try {
    Invoke-WebRequest -Uri $modelfileUrl -OutFile $modelfilePath -ErrorAction Stop
    Write-Host "✓ Downloaded: $modelfilePath" -ForegroundColor Green
} catch {
    Write-Host "✗ Failed to download Modelfile: $_" -ForegroundColor Red
    exit 1
}

# ══════════════════════════════════════════════════════════
# STEP 5: Register with Ollama
# ══════════════════════════════════════════════════════════

Write-Host ""
Write-Host "[5/5] Registering model with Ollama..." -ForegroundColor Yellow

# Check if Ollama is available
try {
    $null = & ollama list 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ollama command failed" }
} catch {
    Write-Host "✗ Ollama is not available. Please install Ollama first:" -ForegroundColor Red
    Write-Host "  https://ollama.com/download" -ForegroundColor Yellow
    exit 1
}

# Check if model already exists
$existingModels = & ollama list 2>&1 | Out-String
if ($existingModels -match [regex]::Escape($ModelName)) {
    Write-Host "⚠ Model '$ModelName' already exists in Ollama." -ForegroundColor Yellow
    $response = Read-Host "  Overwrite? (y/N)"
    if ($response -ne 'y' -and $response -ne 'Y') {
        Write-Host "✓ Keeping existing model." -ForegroundColor Green
        Write-Host ""
        Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host "  To use the model:" -ForegroundColor Cyan
        Write-Host "    ollama run $ModelName" -ForegroundColor White
        Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
        exit 0
    }
    & ollama rm $ModelName 2>&1 | Out-Null
}

# Register the model
Push-Location $OutputDir
try {
    Write-Host "  Running: ollama create $ModelName -f Modelfile" -ForegroundColor Gray
    & ollama create $ModelName -f Modelfile
    if ($LASTEXITCODE -ne 0) { throw "ollama create failed with exit code $LASTEXITCODE" }
    Write-Host "✓ Model registered: $ModelName" -ForegroundColor Green
} catch {
    Write-Host "✗ Failed to register model: $_" -ForegroundColor Red
    Pop-Location
    exit 1
} finally {
    Pop-Location
}

# ══════════════════════════════════════════════════════════
# DONE
# ══════════════════════════════════════════════════════════

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  ✓ SUCCESS" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
Write-Host "Model downloaded to: $OutputDir" -ForegroundColor White
Write-Host "Model registered as: $ModelName" -ForegroundColor White
Write-Host ""
Write-Host "To use the model:" -ForegroundColor Cyan
Write-Host "  ollama run $ModelName" -ForegroundColor White
Write-Host ""
Write-Host "To test tool support:" -ForegroundColor Cyan
Write-Host "  ollama run $ModelName 'What tools do you have?'" -ForegroundColor White
Write-Host ""
