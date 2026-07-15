param(
  [string]$Target = "windows",
  [string]$GmailClientId = $(if ($env:GMAIL_CLIENT_ID) { $env:GMAIL_CLIENT_ID } else { "YOUR_GMAIL_CLIENT_ID" }),
  [string]$GmailClientSecret = $(if ($env:GMAIL_CLIENT_SECRET) { $env:GMAIL_CLIENT_SECRET } else { "YOUR_GMAIL_CLIENT_SECRET" }),
  [string]$GoogleSearchApiKey = $env:GOOGLE_SEARCH_API_KEY,
  [string]$GoogleSearchEngineId = $env:GOOGLE_SEARCH_ENGINE_ID
)

Set-Location "$PSScriptRoot\.."

$defines = @()
if ($GmailClientId) { $defines += "--dart-define=GMAIL_CLIENT_ID=$GmailClientId" }
if ($GmailClientSecret) { $defines += "--dart-define=GMAIL_CLIENT_SECRET=$GmailClientSecret" }
if ($GoogleSearchApiKey) { $defines += "--dart-define=GOOGLE_SEARCH_API_KEY=$GoogleSearchApiKey" }
if ($GoogleSearchEngineId) { $defines += "--dart-define=GOOGLE_SEARCH_ENGINE_ID=$GoogleSearchEngineId" }

flutter pub get
flutter run -d $Target @defines
