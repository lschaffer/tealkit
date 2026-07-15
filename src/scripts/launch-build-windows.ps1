param(
  [string]$GmailClientId = $env:GMAIL_CLIENT_ID,
  [string]$GmailClientSecret = $env:GMAIL_CLIENT_SECRET,
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
flutter build windows @defines
