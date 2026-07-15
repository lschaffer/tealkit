param(
  [ValidateSet("apk", "appbundle")]
  [string]$Artifact = "appbundle",
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

flutter pub get
if ($Artifact -eq "appbundle") {
  flutter build appbundle @defines
} else {
  flutter build apk @defines
}
