#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Build TealKit Server Light from the unified server/ package (no llamadart).
  Keeps full SQLite + FTS5 + RAG + Scheduler + PDF/Excel/File tools; disables only embedded GGUF.
.EXAMPLE
  .\server\scripts\build-server-light.ps1
  .\server\scripts\build-server-light.ps1 -OutputPath server\dist\tealkit_server_light.exe
#>

param(
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
$ServerDir = (Resolve-Path "$PSScriptRoot\..").Path
if (-not $OutputPath) {
    $OutputPath = Join-Path $ServerDir 'dist\tealkit_server_light.exe'
}

$overridesPath = Join-Path $ServerDir 'pubspec_overrides.yaml'
$hadOverrides = Test-Path $overridesPath
$prevOverrides = if ($hadOverrides) { [System.IO.File]::ReadAllText($overridesPath, [System.Text.Encoding]::UTF8) } else { $null }
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

try {
    $stubOverrides = @"
dependency_overrides:
  llamadart:
    path: ../third_party/llamadart_stub
  dart_duckdb:
    path: ../third_party/dart_duckdb_light
  sqlite_vector:
    path: ../third_party/sqlite_vector_stub
"@
    [System.IO.File]::WriteAllText($overridesPath, $stubOverrides, $utf8NoBom)

    $outDir = Split-Path -Parent $OutputPath
    if ($outDir -and -not (Test-Path $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    Push-Location $ServerDir
    Write-Host "==> Resolving Light server dependencies (llamadart stubbed)..." -ForegroundColor Cyan
    dart pub get
    if ($LASTEXITCODE -ne 0) { throw "dart pub get failed with exit code $LASTEXITCODE" }

    Write-Host "==> Compiling TealKit Server Light (-DTEALKIT_LIGHT=true)..." -ForegroundColor Cyan
    dart compile exe bin/tealkit_server.dart -DTEALKIT_LIGHT=true -o $OutputPath
    if ($LASTEXITCODE -ne 0) { throw "dart compile exe failed with exit code $LASTEXITCODE" }

    Write-Host "[OK] Built TealKit Server Light: $OutputPath" -ForegroundColor Green
}
finally {
    Pop-Location -ErrorAction SilentlyContinue
    if ($hadOverrides -and $null -ne $prevOverrides) {
        [System.IO.File]::WriteAllText($overridesPath, $prevOverrides, $utf8NoBom)
    } elseif (Test-Path $overridesPath) {
        Remove-Item $overridesPath -Force
    }
    Push-Location $ServerDir
    dart pub get | Out-Null
    Pop-Location
}
