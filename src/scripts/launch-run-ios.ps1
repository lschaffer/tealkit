param(
  [string]$Target = "ios",
  [string]$GmailClientId = $(if ($env:GMAIL_CLIENT_ID) { $env:GMAIL_CLIENT_ID } else { "YOUR_GMAIL_CLIENT_ID" }),
  [string]$GoogleIosClientId = $(if ($env:GOOGLE_IOS_CLIENT_ID) { $env:GOOGLE_IOS_CLIENT_ID } else { "YOUR_GOOGLE_IOS_CLIENT_ID" }),
  [string]$GmailClientSecret = $env:GMAIL_CLIENT_SECRET,
  [string]$GoogleSearchApiKey = $env:GOOGLE_SEARCH_API_KEY,
  [string]$GoogleSearchEngineId = $env:GOOGLE_SEARCH_ENGINE_ID
)

if (-not $IsMacOS) {
  Write-Error "iOS run is only supported on macOS with Xcode installed."
  exit 1
}

Set-Location "$PSScriptRoot\.."

$defines = @()
if ($GmailClientId) { $defines += "--dart-define=GMAIL_CLIENT_ID=$GmailClientId" }
if ($GoogleIosClientId) { $defines += "--dart-define=GOOGLE_IOS_CLIENT_ID=$GoogleIosClientId" }
if ($GmailClientSecret) { $defines += "--dart-define=GMAIL_CLIENT_SECRET=$GmailClientSecret" }
if ($GoogleSearchApiKey) { $defines += "--dart-define=GOOGLE_SEARCH_API_KEY=$GoogleSearchApiKey" }
if ($GoogleSearchEngineId) { $defines += "--dart-define=GOOGLE_SEARCH_ENGINE_ID=$GoogleSearchEngineId" }

flutter pub get
flutter run -d $Target @defines
