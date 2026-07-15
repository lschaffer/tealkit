param(
    [double]$ValidRatio = 0.05,
    [int]$Seed = 42,
    [switch]$RepairTrain
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$pythonExe = Join-Path $scriptDir ".venv\Scripts\python.exe"
$trainJsonl = Join-Path $scriptDir "mcp_data\train.jsonl"
$trainSplitJsonl = Join-Path $scriptDir "mcp_data\train_split.jsonl"
$validJsonl = Join-Path $scriptDir "mcp_data\valid.jsonl"
$toolsJson = Join-Path $scriptDir "mcp_data\mcp_tools.json"
$promptMd = Join-Path $scriptDir "mcp_data\generated_train_prompt.md"

if (-not (Test-Path $pythonExe)) {
    throw "Python venv not found: $pythonExe"
}

if (-not (Test-Path $trainJsonl)) {
    throw "Train JSONL not found: $trainJsonl"
}

if (-not (Test-Path $toolsJson)) {
    throw "Tools schema not found: $toolsJson"
}

function Invoke-Python {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Args
    )

    & $pythonExe @Args
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $pythonExe $($Args -join ' ')"
    }
}

if ($RepairTrain) {
    Write-Host "[1/4] Repairing train.jsonl..." -ForegroundColor Cyan
    Invoke-Python -Args @(
        (Join-Path $scriptDir "generate_train_jsonl_gemini_incremental.py"),
        "--repair-only",
        "--out", $trainJsonl,
        "--tools", $toolsJson,
        "--prompt", $promptMd
    )
}

Write-Host "[2/4] Validating train.jsonl..." -ForegroundColor Cyan
Invoke-Python -Args @(
    (Join-Path $scriptDir "validate_jsonl.py"),
    "--jsonl", $trainJsonl,
    "--tools", $toolsJson
)

Write-Host "[3/4] Splitting train/valid..." -ForegroundColor Cyan
Invoke-Python -Args @(
    (Join-Path $scriptDir "train.py"),
    "--split",
    "--jsonl", $trainJsonl,
    "--train-out", $trainSplitJsonl,
    "--valid-out", $validJsonl,
    "--valid-ratio", $ValidRatio,
    "--seed", $Seed
)

Write-Host "[4/4] Validating valid.jsonl..." -ForegroundColor Cyan
Invoke-Python -Args @(
    (Join-Path $scriptDir "validate_jsonl.py"),
    "--jsonl", $validJsonl,
    "--tools", $toolsJson
)

Write-Host "Done. train_split.jsonl and valid.jsonl are refreshed and validated." -ForegroundColor Green
