class OAuthDefaults {
  // Desktop/manual-OAuth client ID (used on Linux, Windows, macOS, and as fallback)
  static const String gmailClientId = String.fromEnvironment('GMAIL_CLIENT_ID', defaultValue: '');
  static const String gmailClientSecret = String.fromEnvironment('GMAIL_CLIENT_SECRET', defaultValue: '');

  // iOS native Google Sign-In client ID (reads from GoogleSignIn.xcconfig when empty)
  static const String googleIosClientId = String.fromEnvironment('GOOGLE_IOS_CLIENT_ID', defaultValue: '');

  // Web application client ID — required as serverClientId for google_sign_in_android v7.2+
  static const String googleWebClientId = String.fromEnvironment('GOOGLE_WEB_CLIENT_ID', defaultValue: '');

  static const String webSearchApiKey = String.fromEnvironment('SERPER_API_KEY', defaultValue: '');
  static const String webSearchEngineId = '';

  static bool get hasGmailClientId => gmailClientId.trim().isNotEmpty;
  static bool get hasGmailClientSecret => gmailClientSecret.trim().isNotEmpty;
}
