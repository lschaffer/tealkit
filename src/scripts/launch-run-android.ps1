param(
  [string]$Target = "android",
  [string]$GmailClientId = "YOUR_GMAIL_CLIENT_ID",
  [string]$GoogleWebClientId = $(if ($env:GOOGLE_WEB_CLIENT_ID) { $env:GOOGLE_WEB_CLIENT_ID } else { "YOUR_GOOGLE_WEB_CLIENT_ID" }),
  [string]$GoogleSearchApiKey = $env:GOOGLE_SEARCH_API_KEY,
  [string]$GoogleSearchEngineId = $env:GOOGLE_SEARCH_ENGINE_ID
)

Set-Location "$PSScriptRoot\.."

$defines = @()
if ($GmailClientId) { $defines += "--dart-define=GMAIL_CLIENT_ID=$GmailClientId" }
if ($GoogleWebClientId) { $defines += "--dart-define=GOOGLE_WEB_CLIENT_ID=$GoogleWebClientId" }
if ($GoogleSearchApiKey) { $defines += "--dart-define=GOOGLE_SEARCH_API_KEY=$GoogleSearchApiKey" }
if ($GoogleSearchEngineId) { $defines += "--dart-define=GOOGLE_SEARCH_ENGINE_ID=$GoogleSearchEngineId" }

$packageConfig = Join-Path ".dart_tool" "package_config.json"
$shouldRunPubGet = -not (Test-Path $packageConfig)

if (-not $shouldRunPubGet) {
  $packageConfigTime = (Get-Item $packageConfig).LastWriteTimeUtc
  foreach ($dependencyFile in @("pubspec.yaml", "pubspec.lock")) {
    if ((Get-Item $dependencyFile).LastWriteTimeUtc -gt $packageConfigTime) {
      $shouldRunPubGet = $true
      break
    }
  }
}

if ($shouldRunPubGet) {
  Write-Host "Running flutter pub get (dependency metadata changed)..."
  flutter pub get
} else {
  Write-Host "Skipping flutter pub get (dependencies unchanged)."
}

flutter run -d $Target @defines
