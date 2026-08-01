param(
  [ValidateSet("apk", "appbundle")]
  [string]$Artifact = "appbundle",
  [string]$GmailClientId = "YOUR_GMAIL_CLIENT_ID",
  [string]$GoogleWebClientId = $(if ($env:GOOGLE_WEB_CLIENT_ID) { $env:GOOGLE_WEB_CLIENT_ID } else { "YOUR_GOOGLE_WEB_CLIENT_ID" }),
  [string]$GoogleSearchApiKey = $env:GOOGLE_SEARCH_API_KEY,
  [string]$GoogleSearchEngineId = $env:GOOGLE_SEARCH_ENGINE_ID
)

Set-Location "$PSScriptRoot\.."

# Load .env file if exists
if (Test-Path "$PSScriptRoot\.env") {
    Get-Content "$PSScriptRoot\.env" | Where-Object { $_ -and $_ -notlike "#*" } | ForEach-Object {
        $name, $val = $_ -split '=', 2
        if ($name -and $val) {
            $envKey = $name.Trim()
            $envVal = $val.Trim()
            [System.Environment]::SetEnvironmentVariable($envKey, $envVal)
            if ($envKey -eq "GMAIL_CLIENT_ID" -and ($GmailClientId -eq "YOUR_GMAIL_CLIENT_ID" -or -not $GmailClientId)) { $GmailClientId = $envVal }
            if ($envKey -eq "GOOGLE_WEB_CLIENT_ID" -and ($GoogleWebClientId -eq "YOUR_GOOGLE_WEB_CLIENT_ID" -or -not $GoogleWebClientId)) { $GoogleWebClientId = $envVal }
            if ($envKey -eq "GOOGLE_SEARCH_API_KEY" -and -not $GoogleSearchApiKey) { $GoogleSearchApiKey = $envVal }
            if ($envKey -eq "GOOGLE_SEARCH_ENGINE_ID" -and -not $GoogleSearchEngineId) { $GoogleSearchEngineId = $envVal }
        }
    }
}

$defines = @()
if ($GmailClientId -and $GmailClientId -ne "YOUR_GMAIL_CLIENT_ID") { $defines += "--dart-define=GMAIL_CLIENT_ID=$GmailClientId" }
if ($GoogleWebClientId -and $GoogleWebClientId -ne "YOUR_GOOGLE_WEB_CLIENT_ID") { $defines += "--dart-define=GOOGLE_WEB_CLIENT_ID=$GoogleWebClientId" }
if ($GoogleSearchApiKey) { $defines += "--dart-define=GOOGLE_SEARCH_API_KEY=$GoogleSearchApiKey" }
if ($GoogleSearchEngineId) { $defines += "--dart-define=GOOGLE_SEARCH_ENGINE_ID=$GoogleSearchEngineId" }
if ($env:GMAIL_CLIENT_SECRET) { $defines += "--dart-define=GMAIL_CLIENT_SECRET=$($env:GMAIL_CLIENT_SECRET)" }
if ($env:SERPER_API_KEY) { $defines += "--dart-define=SERPER_API_KEY=$($env:SERPER_API_KEY)" }
if ($env:GOOGLE_IOS_CLIENT_ID) { $defines += "--dart-define=GOOGLE_IOS_CLIENT_ID=$($env:GOOGLE_IOS_CLIENT_ID)" }

flutter pub get
if ($Artifact -eq "appbundle") {
  flutter build appbundle @defines
} else {
  flutter build apk @defines
}
