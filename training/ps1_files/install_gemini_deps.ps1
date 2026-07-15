$ErrorActionPreference = "Stop"

$python = Join-Path $PSScriptRoot ".venv\Scripts\python.exe"
if (-not (Test-Path $python)) {
    Write-Error "Python venv not found at $python"
}

& $python -m pip install --upgrade pip
& $python -m pip install google-genai
& $python -m pip uninstall -y google-generativeai

Write-Host "Gemini dependency installed with: $python"
