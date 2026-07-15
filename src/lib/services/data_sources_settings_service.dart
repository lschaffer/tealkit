import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/logger.dart';
import '../config/oauth_defaults.dart';
import 'app_logger.dart';

// ═══════════════════════════════════════════════════════════════
// Email provider enum
// ═══════════════════════════════════════════════════════════════

enum EmailProvider {
  none,
  gmail,
  imap;

  String get label {
    switch (this) {
      case EmailProvider.none:
        return '—';
      case EmailProvider.gmail:
        return 'Gmail (OAuth2)';
      case EmailProvider.imap:
        return 'IMAP';
    }
  }

  String get configKey {
    switch (this) {
      case EmailProvider.none:
        return '';
      case EmailProvider.gmail:
        return 'gmail';
      case EmailProvider.imap:
        return 'imap';
    }
  }

  static EmailProvider fromConfigKey(String? key) {
    if (key == null || key.isEmpty) return EmailProvider.none;
    for (final p in EmailProvider.values) {
      if (p.configKey == key) return p;
    }
    return EmailProvider.none;
  }
}

// ═══════════════════════════════════════════════════════════════
// Web search provider enum
// ═══════════════════════════════════════════════════════════════

enum WebSearchProvider {
  none,
  duckduckgo,
  serper,
  serpapi,
  custom;

  String get label {
    switch (this) {
      case WebSearchProvider.none:
        return '—';
      case WebSearchProvider.duckduckgo:
        return 'DuckDuckGo';
      case WebSearchProvider.serper:
        return 'Serper.dev';
      case WebSearchProvider.serpapi:
        return 'SerpApi';
      case WebSearchProvider.custom:
        return 'Custom';
    }
  }

  String get configKey {
    switch (this) {
      case WebSearchProvider.none:
        return '';
      case WebSearchProvider.duckduckgo:
        return 'duckduckgo';
      case WebSearchProvider.serper:
        return 'serper';
      case WebSearchProvider.serpapi:
        return 'serpapi';
      case WebSearchProvider.custom:
        return 'custom';
    }
  }

  static WebSearchProvider fromConfigKey(String? key) {
    if (key == null || key.isEmpty) return WebSearchProvider.none;
    if (key == 'google') return WebSearchProvider.serper;
    for (final p in WebSearchProvider.values) {
      if (p.configKey == key) return p;
    }
    return WebSearchProvider.none;
  }
}

// ═══════════════════════════════════════════════════════════════
// Cloud storage provider enum
// ═══════════════════════════════════════════════════════════════

enum CloudStorageProvider {
  none,
  googleDrive,
  oneDrive;

  String get label {
    switch (this) {
      case CloudStorageProvider.none:
        return '—';
      case CloudStorageProvider.googleDrive:
        return 'Google Drive';
      case CloudStorageProvider.oneDrive:
        return 'Microsoft OneDrive';
    }
  }

  String get configKey {
    switch (this) {
      case CloudStorageProvider.none:
        return '';
      case CloudStorageProvider.googleDrive:
        return 'google_drive';
      case CloudStorageProvider.oneDrive:
        return 'onedrive';
    }
  }

  static CloudStorageProvider fromConfigKey(String? key) {
    if (key == null || key.isEmpty) return CloudStorageProvider.none;
    for (final p in CloudStorageProvider.values) {
      if (p.configKey == key) return p;
    }
    return CloudStorageProvider.none;
  }
}

// ═══════════════════════════════════════════════════════════════
// Service – persists global data source settings in secure storage
// ═══════════════════════════════════════════════════════════════

class DataSourcesSettingsService extends ChangeNotifier {
  static final DataSourcesSettingsService instance = DataSourcesSettingsService._();
  DataSourcesSettingsService._();

  static const List<String> gmailOAuthScopes = [
    'https://www.googleapis.com/auth/gmail.readonly',
    'https://www.googleapis.com/auth/gmail.send',
    'https://www.googleapis.com/auth/userinfo.email',
    'https://www.googleapis.com/auth/drive.file',
    'https://www.googleapis.com/auth/calendar',
  ];

  bool _googleSignInInitialized = false;

  Future<GoogleSignIn> _googleSignInClient() async {
    final signIn = GoogleSignIn.instance;
    if (!_googleSignInInitialized) {
      // iOS: pass iOS-specific client ID (or null → google_sign_in_ios reads from GoogleSignIn.xcconfig)
      // Android: pass Web application client ID as serverClientId (required by google_sign_in_android v7.2+)
      // Desktop/other: pass Desktop client ID as clientId
      final iosClientId = OAuthDefaults.googleIosClientId.trim().isNotEmpty ? OAuthDefaults.googleIosClientId.trim() : null;
      final webClientId = OAuthDefaults.googleWebClientId.trim().isNotEmpty ? OAuthDefaults.googleWebClientId.trim() : null;
      final desktopClientId = gmailClientId.trim().isNotEmpty ? gmailClientId.trim() : null;
      final isIOS = defaultTargetPlatform == TargetPlatform.iOS;
      final isAndroid = defaultTargetPlatform == TargetPlatform.android;
      await signIn.initialize(
        clientId: isAndroid ? null : (isIOS ? iosClientId : desktopClientId),
        serverClientId: isAndroid ? (webClientId ?? desktopClientId) : null,
      );
      _googleSignInInitialized = true;
    }
    return signIn;
  }

  // resetOnError: true → if a single key's Keystore entry is invalidated
  // (PIN change, OEM quirk, debug reinstall), that read returns null instead of
  // throwing PlatformException and aborting the entire load().
  static const _storage = FlutterSecureStorage(aOptions: AndroidOptions(resetOnError: true));

  // On Linux the keyring may be locked (e.g. headless / VNC). Once detected,
  // bypass secure storage entirely for the remainder of the session.
  bool _keyringUnavailable = false;

  /// True when [e] is a libsecret/keyring error on Linux (keyring locked/unavailable).
  static bool _isLinuxKeyringError(Object e) => Platform.isLinux && e.toString().contains('Libsecret');

  // Shadow key prefix in SharedPreferences — used as fallback when
  // libsecret (keyring) is locked or unavailable on Linux.
  static const _kShadowPrefix = '_ds_shadow_';

  // ── Storage key prefix ────────────────────────────
  static const _prefix = 'ds_';

  // ── Email keys ────────────────────────────────────
  static const _kEmailProvider = '${_prefix}email_provider';
  static const _kEmailEnabled = '${_prefix}email_enabled';
  // Gmail
  static const _kGmailClientId = '${_prefix}gmail_client_id';
  static const _kGmailClientSecret = '${_prefix}gmail_client_secret';
  static const _kGmailAccessToken = '${_prefix}gmail_access_token';
  static const _kGmailRefreshToken = '${_prefix}gmail_refresh_token';
  static const _kGmailTokenExpiry = '${_prefix}gmail_token_expiry';
  static const _kGmailAccountEmail = '${_prefix}gmail_account_email';
  // IMAP
  static const _kImapHost = '${_prefix}imap_host';
  static const _kImapPort = '${_prefix}imap_port';
  static const _kImapUsername = '${_prefix}imap_username';
  static const _kImapPassword = '${_prefix}imap_password';
  static const _kImapUseSsl = '${_prefix}imap_use_ssl';
  // SMTP (outgoing)
  static const _kSmtpHost = '${_prefix}smtp_host';
  static const _kSmtpPort = '${_prefix}smtp_port';
  static const _kSmtpSender = '${_prefix}smtp_sender';

  // ── Web search keys ───────────────────────────────
  static const _kWebSearchProvider = '${_prefix}websearch_provider';
  static const _kWebSearchEnabled = '${_prefix}websearch_enabled';
  static const _kWebSearchApiKey = '${_prefix}websearch_api_key';
  static const _kWebSearchEngineId = '${_prefix}websearch_engine_id';
  static const _kWebSearchMaxResults = '${_prefix}websearch_max_results';
  static const _kWebSearchCustomProviderName = '${_prefix}websearch_custom_provider_name';
  static const _kWebSearchCustomEndpoint = '${_prefix}websearch_custom_endpoint';
  static const _kDuckDbIndexSizeLimitGb = '${_prefix}duckdb_index_size_limit_gb';
  static const _kOutputRetentionDays = '${_prefix}output_retention_days';

  // ── Website index keys ───────────────────────────
  static const _kWebsiteIndexUrls = '${_prefix}website_index_urls';
  static const _kWebsiteIndexMaxPages = '${_prefix}website_index_max_pages';
  static const _kWebsiteIndexCron = '${_prefix}website_index_cron';
  static const _kWebsiteIndexLastIndexed = '${_prefix}website_index_last_indexed_at';

  // ── Document index keys ──────────────────────────
  static const _kDocumentRootPaths = '${_prefix}document_root_paths';
  static const _kDocumentFileTypes = '${_prefix}document_file_types';
  static const _kDocumentIndexLastIndexed = '${_prefix}document_index_last_indexed_at';
  static const _kDocumentIndexCron = '${_prefix}document_index_cron';

  // ── Cloud storage keys (independent switches) ────
  static const _kGoogleDriveEnabled = '${_prefix}gdrive_enabled';
  static const _kOneDriveEnabled = '${_prefix}onedrive_enabled';
  static const _kOneDriveClientId = '${_prefix}onedrive_client_id';
  static const _kOneDriveTenantId = '${_prefix}onedrive_tenant_id';

  // ── Notification keys ─────────────────────────────
  static const _kNotificationEmailEnabled = '${_prefix}notification_email_enabled';

  // ── Location keys ─────────────────────────────────
  static const _kLocationLat = '${_prefix}location_lat';
  static const _kLocationLng = '${_prefix}location_lng';

  // ── SSH keys ──────────────────────────────────────
  static const _kSshHost = '${_prefix}ssh_host';
  static const _kSshPort = '${_prefix}ssh_port';
  static const _kSshUsername = '${_prefix}ssh_username';
  static const _kSshPassword = '${_prefix}ssh_password';
  static const _kSshPrivateKey = '${_prefix}ssh_private_key';

  // ── Slack keys ────────────────────────────────────
  static const _kSlackEnabled = '${_prefix}slack_enabled';
  static const _kSlackWebhookUrl = '${_prefix}slack_webhook_url';
  static const _kSlackBotToken = '${_prefix}slack_bot_token';
  static const _kSlackDefaultChannel = '${_prefix}slack_default_channel';

  // ── Home Assistant keys ──────────────────────────
  static const _kHaBaseUrl = '${_prefix}ha_base_url';
  static const _kHaToken = '${_prefix}ha_token';

  // ── WhatsApp keys ─────────────────────────────────
  static const _kWhatsAppEnabled = '${_prefix}whatsapp_enabled';
  static const _kWhatsAppMode = '${_prefix}whatsapp_mode'; // 'meta' | 'callmebot'
  static const _kWhatsAppPhoneNumberId = '${_prefix}whatsapp_phone_number_id';
  static const _kWhatsAppAccessToken = '${_prefix}whatsapp_access_token';
  static const _kWhatsAppDefaultRecipient = '${_prefix}whatsapp_default_recipient';
  static const _kWhatsAppCallMeBotApiKey = '${_prefix}whatsapp_callmebot_api_key';

  // ═══════════════════════════════════════════════════
  // State
  // ═══════════════════════════════════════════════════

  bool _loaded = false;
  bool get isLoaded => _loaded;

  // ── Email ─────────────────────────────────────────
  EmailProvider _emailProvider = EmailProvider.none;
  bool _emailEnabled = false;
  String _gmailClientId = '';
  String _gmailClientSecret = '';
  String _gmailAccessToken = '';
  String _gmailRefreshToken = '';
  DateTime? _gmailTokenExpiry;
  String _gmailAccountEmail = '';
  String _imapHost = '';
  int _imapPort = 993;
  String _imapUsername = '';
  String _imapPassword = '';
  bool _imapUseSsl = true;
  String _smtpHost = '';
  int _smtpPort = 587;
  String _smtpSender = '';

  // ── Web search ────────────────────────────────────
  WebSearchProvider _webSearchProvider = WebSearchProvider.duckduckgo;
  bool _webSearchEnabled = false;
  String _webSearchApiKey = '';
  String _webSearchEngineId = '';
  int _webSearchMaxResults = 5;
  String _webSearchCustomProviderName = '';
  String _webSearchCustomEndpoint = '';
  double _duckDbIndexSizeLimitGb = 1.0;

  // ── Website index ─────────────────────────────────
  String _websiteIndexUrls = '';
  int _websiteIndexMaxPages = 100;
  String _websiteIndexCron = '';
  DateTime? _websiteIndexLastIndexedAt;

  // ── Document index ────────────────────────────────
  String _documentRootPaths = '';
  String _documentFileTypes = 'pdf,md,docx';
  String _documentIndexCron = '';
  DateTime? _documentIndexLastIndexedAt;

  // ── Cloud storage (independent) ───────────────────
  bool _googleDriveEnabled = false;
  bool _oneDriveEnabled = false;
  String _oneDriveClientId = '';
  String _oneDriveTenantId = '';

  // ── Notification ──────────────────────────────────
  bool _notificationEmailEnabled = false;
  int _outputRetentionDays = 2;

  // ── Location ──────────────────────────────────────
  double? _locationLat;
  double? _locationLng;

  // ── SSH ───────────────────────────────────────────
  String _sshHost = '';
  int _sshPort = 22;
  String _sshUsername = '';
  String _sshPassword = '';
  String _sshPrivateKey = '';

  // ── Home Assistant ────────────────────────────────
  String _haBaseUrl = '';
  String _haToken = '';

  // ── Slack ─────────────────────────────────────────
  bool _slackEnabled = false;
  String _slackWebhookUrl = '';
  String _slackBotToken = '';
  String _slackDefaultChannel = '';

  // ── WhatsApp ──────────────────────────────────────
  bool _whatsAppEnabled = false;
  String _whatsAppMode = 'meta'; // 'meta' | 'callmebot'
  String _whatsAppPhoneNumberId = '';
  String _whatsAppAccessToken = '';
  String _whatsAppDefaultRecipient = '';
  String _whatsAppCallMeBotApiKey = '';

  /// Apply server-backed settings to the in-memory model only.
  ///
  /// This keeps local secure storage untouched while the app is in remote mode.
  void applyRemoteState(Map<String, dynamic> remote) {
    final email = remote['email'] as Map<String, dynamic>? ?? const <String, dynamic>{};
    _emailProvider = EmailProvider.fromConfigKey(email['provider'] as String?);
    _emailEnabled = email['enabled'] as bool? ?? false;
    _imapHost = (email['imap_host'] as String?) ?? '';
    _imapPort = (email['imap_port'] as int?) ?? 993;
    _imapUsername = (email['imap_username'] as String?) ?? '';
    _imapPassword = (email['imap_password'] as String?) ?? '';
    _imapUseSsl = email['imap_use_ssl'] as bool? ?? true;
    _smtpHost = (email['smtp_host'] as String?) ?? '';
    _smtpPort = (email['smtp_port'] as int?) ?? 587;
    _smtpSender = (email['smtp_sender'] as String?) ?? '';
    _notificationEmailEnabled = email['notification_email_enabled'] as bool? ?? false;
    _gmailAccountEmail = (email['gmail_account_email'] as String?) ?? _gmailAccountEmail;

    final webSearch = remote['web_search'] as Map<String, dynamic>? ?? const <String, dynamic>{};
    _webSearchProvider = WebSearchProvider.fromConfigKey(webSearch['provider'] as String?);
    if (_webSearchProvider == WebSearchProvider.none) {
      _webSearchProvider = WebSearchProvider.duckduckgo;
    }
    _webSearchEnabled = webSearch['enabled'] as bool? ?? false;
    _webSearchApiKey = (webSearch['api_key'] as String?) ?? '';
    _webSearchEngineId = (webSearch['engine_id'] as String?) ?? '';
    _webSearchMaxResults = (webSearch['max_results'] as int?) ?? 5;
    _webSearchCustomProviderName = (webSearch['custom_provider_name'] as String?) ?? '';
    _webSearchCustomEndpoint = (webSearch['custom_endpoint'] as String?) ?? '';
    _duckDbIndexSizeLimitGb = (webSearch['duckdb_index_size_limit_gb'] as num?)?.toDouble() ?? 1.0;
    _outputRetentionDays = (webSearch['output_retention_days'] as int?) ?? _outputRetentionDays;

    final websiteIndex = remote['website_index'] as Map<String, dynamic>? ?? const <String, dynamic>{};
    _websiteIndexUrls = (websiteIndex['urls'] as String?) ?? '';
    _websiteIndexMaxPages = (websiteIndex['max_pages'] as int?) ?? 100;
    _websiteIndexCron = (websiteIndex['cron'] as String?) ?? '';
    final websiteLastIndexed = websiteIndex['last_indexed_at'] as String?;
    _websiteIndexLastIndexedAt = websiteLastIndexed != null ? DateTime.tryParse(websiteLastIndexed) : null;

    final documentIndex = remote['document_index'] as Map<String, dynamic>? ?? const <String, dynamic>{};
    _documentRootPaths = (documentIndex['root_paths'] as String?) ?? '';
    _documentFileTypes = (documentIndex['file_types'] as String?) ?? 'pdf,md,docx';
    _documentIndexCron = (documentIndex['cron'] as String?) ?? '';
    final documentLastIndexed = documentIndex['last_indexed_at'] as String?;
    _documentIndexLastIndexedAt = documentLastIndexed != null ? DateTime.tryParse(documentLastIndexed) : null;

    final cloudStorage = remote['cloud_storage'] as Map<String, dynamic>? ?? const <String, dynamic>{};
    _googleDriveEnabled = cloudStorage['google_drive_enabled'] as bool? ?? false;
    _oneDriveEnabled = cloudStorage['one_drive_enabled'] as bool? ?? false;
    _oneDriveClientId = (cloudStorage['one_drive_client_id'] as String?) ?? '';
    _oneDriveTenantId = (cloudStorage['one_drive_tenant_id'] as String?) ?? '';

    final location = remote['location'] as Map<String, dynamic>? ?? const <String, dynamic>{};
    _locationLat = (location['lat'] as num?)?.toDouble();
    _locationLng = (location['lng'] as num?)?.toDouble();

    final ssh = remote['ssh'] as Map<String, dynamic>? ?? const <String, dynamic>{};
    _sshHost = (ssh['host'] as String?) ?? '';
    _sshPort = (ssh['port'] as int?) ?? 22;
    _sshUsername = (ssh['username'] as String?) ?? '';
    _sshPassword = (ssh['password'] as String?) ?? '';
    _sshPrivateKey = (ssh['private_key'] as String?) ?? '';

    final slack = remote['slack'] as Map<String, dynamic>? ?? const <String, dynamic>{};
    _slackEnabled = slack['enabled'] as bool? ?? false;
    _slackWebhookUrl = (slack['webhook_url'] as String?) ?? '';
    _slackBotToken = (slack['bot_token'] as String?) ?? '';
    _slackDefaultChannel = (slack['default_channel'] as String?) ?? '';

    final homeAssistant = remote['home_assistant'] as Map<String, dynamic>? ?? const <String, dynamic>{};
    _haBaseUrl = (homeAssistant['base_url'] as String?) ?? '';
    _haToken = (homeAssistant['token'] as String?) ?? '';

    final whatsApp = remote['whatsapp'] as Map<String, dynamic>? ?? const <String, dynamic>{};
    _whatsAppEnabled = whatsApp['enabled'] as bool? ?? false;
    _whatsAppMode = (whatsApp['mode'] as String?) ?? 'meta';
    _whatsAppPhoneNumberId = (whatsApp['phone_number_id'] as String?) ?? '';
    _whatsAppAccessToken = (whatsApp['access_token'] as String?) ?? '';
    _whatsAppDefaultRecipient = (whatsApp['default_recipient'] as String?) ?? '';
    _whatsAppCallMeBotApiKey = (whatsApp['callmebot_api_key'] as String?) ?? '';

    _loaded = true;
    notifyListeners();
  }

  // ═══════════════════════════════════════════════════
  // Getters
  // ═══════════════════════════════════════════════════

  // Email
  EmailProvider get emailProvider => _emailProvider;
  bool get emailEnabled => _emailEnabled;
  String get gmailClientId {
    final buildClientId = OAuthDefaults.gmailClientId.trim();
    if (buildClientId.isNotEmpty) return buildClientId;
    return _gmailClientId;
  }

  String get gmailClientSecret => _gmailClientSecret.isNotEmpty ? _gmailClientSecret : OAuthDefaults.gmailClientSecret;
  String get gmailAccessToken => _gmailAccessToken;
  String get gmailRefreshToken => _gmailRefreshToken;
  DateTime? get gmailTokenExpiry => _gmailTokenExpiry;
  String get gmailAccountEmail => _gmailAccountEmail;
  bool get hasGmailOAuthTokens => _gmailRefreshToken.isNotEmpty || _gmailAccessToken.isNotEmpty;
  bool get isGmailAccessTokenExpired {
    final exp = _gmailTokenExpiry;
    if (exp == null) {
      return true; // No expiry known → treat as expired to force refresh
    }
    return DateTime.now().isAfter(exp.subtract(const Duration(minutes: 1)));
  }

  String get imapHost => _imapHost;
  int get imapPort => _imapPort;
  String get imapUsername => _imapUsername;
  String get imapPassword => _imapPassword;
  bool get imapUseSsl => _imapUseSsl;
  String get smtpHost => _smtpHost.isNotEmpty ? _smtpHost : _imapHost.replaceFirst('imap.', 'smtp.');
  int get smtpPort => _smtpPort;
  String get smtpSender => _smtpSender.isNotEmpty ? _smtpSender : _imapUsername;

  bool get isEmailConfigured {
    if (!_emailEnabled) return false;
    if (_emailProvider == EmailProvider.gmail) {
      return gmailClientId.isNotEmpty && hasGmailOAuthTokens;
    }
    if (_emailProvider == EmailProvider.imap) {
      return _imapHost.isNotEmpty && _imapUsername.isNotEmpty && _imapPassword.isNotEmpty;
    }
    return false;
  }

  // Web search
  WebSearchProvider get webSearchProvider => _webSearchProvider;
  bool get webSearchEnabled => _webSearchEnabled;
  String get webSearchApiKey => _webSearchApiKey.isNotEmpty ? _webSearchApiKey : OAuthDefaults.webSearchApiKey;
  String get webSearchEngineId => _webSearchEngineId;
  int get webSearchMaxResults => _webSearchMaxResults;
  String get webSearchCustomProviderName => _webSearchCustomProviderName;
  String get webSearchCustomEndpoint => _webSearchCustomEndpoint;
  double get duckDbIndexSizeLimitGb => _duckDbIndexSizeLimitGb;

  // Website index
  String get websiteIndexUrls => _websiteIndexUrls;
  int get websiteIndexMaxPages => _websiteIndexMaxPages;
  String get websiteIndexCron => _websiteIndexCron;
  DateTime? get websiteIndexLastIndexedAt => _websiteIndexLastIndexedAt;
  bool get isWebsiteIndexConfigured => _websiteIndexUrls.trim().isNotEmpty;

  // Document index
  String get documentRootPaths => _documentRootPaths;
  String get documentFileTypes => _documentFileTypes.isNotEmpty ? _documentFileTypes : 'pdf,md,docx';
  String get documentIndexCron => _documentIndexCron;
  DateTime? get documentIndexLastIndexedAt => _documentIndexLastIndexedAt;
  bool get isDocumentIndexConfigured => _documentRootPaths.trim().isNotEmpty;

  bool get isWebSearchConfigured {
    if (!_webSearchEnabled) return false;
    if (_webSearchProvider == WebSearchProvider.duckduckgo) {
      return true; // no keys needed
    }
    if (_webSearchProvider == WebSearchProvider.serper) {
      final apiKey = _webSearchApiKey.isNotEmpty ? _webSearchApiKey : OAuthDefaults.webSearchApiKey;
      return apiKey.isNotEmpty;
    }
    if (_webSearchProvider == WebSearchProvider.serpapi) {
      final apiKey = _webSearchApiKey.isNotEmpty ? _webSearchApiKey : OAuthDefaults.webSearchApiKey;
      return apiKey.isNotEmpty;
    }
    if (_webSearchProvider == WebSearchProvider.custom) {
      return _webSearchCustomEndpoint.trim().isNotEmpty;
    }
    return false;
  }

  // Cloud storage – Google Drive
  bool get googleDriveEnabled => _googleDriveEnabled;
  String get googleDriveClientId => gmailClientId;

  bool get isGoogleDriveConfigured => _googleDriveEnabled && googleDriveClientId.isNotEmpty;

  // Cloud storage – OneDrive
  bool get oneDriveEnabled => _oneDriveEnabled;
  String get oneDriveClientId => _oneDriveClientId;
  String get oneDriveTenantId => _oneDriveTenantId;

  bool get isOneDriveConfigured => _oneDriveEnabled && _oneDriveClientId.isNotEmpty;

  bool get isCloudStorageConfigured => isGoogleDriveConfigured || isOneDriveConfigured;

  // Notification
  bool get notificationEmailEnabled => _notificationEmailEnabled;
  int get outputRetentionDays => _outputRetentionDays;

  double? get locationLatitude => _locationLat;
  double? get locationLongitude => _locationLng;
  bool get hasLocation => _locationLat != null && _locationLng != null;

  // SSH
  String get sshHost => _sshHost;
  int get sshPort => _sshPort;
  String get sshUsername => _sshUsername;
  String get sshPassword => _sshPassword;
  String get sshPrivateKey => _sshPrivateKey;
  bool get isSshConfigured => _sshHost.isNotEmpty && _sshUsername.isNotEmpty;

  // Home Assistant
  String get haBaseUrl => _haBaseUrl;
  String get haToken => _haToken;
  bool get isHomeAssistantConfigured => _haBaseUrl.isNotEmpty && _haToken.isNotEmpty;

  // Slack
  bool get slackEnabled => _slackEnabled;
  String get slackWebhookUrl => _slackWebhookUrl;
  String get slackBotToken => _slackBotToken;
  String get slackDefaultChannel => _slackDefaultChannel;
  bool get isSlackConfigured => _slackEnabled && (_slackWebhookUrl.isNotEmpty || _slackBotToken.isNotEmpty);

  // WhatsApp
  bool get whatsAppEnabled => _whatsAppEnabled;
  String get whatsAppMode => _whatsAppMode;
  String get whatsAppPhoneNumberId => _whatsAppPhoneNumberId;
  String get whatsAppAccessToken => _whatsAppAccessToken;
  String get whatsAppDefaultRecipient => _whatsAppDefaultRecipient;
  String get whatsAppCallMeBotApiKey => _whatsAppCallMeBotApiKey;
  bool get isWhatsAppConfigured {
    if (!_whatsAppEnabled) return false;
    if (_whatsAppMode == 'callmebot') {
      return _whatsAppCallMeBotApiKey.isNotEmpty && _whatsAppDefaultRecipient.isNotEmpty;
    }
    return _whatsAppPhoneNumberId.isNotEmpty && _whatsAppAccessToken.isNotEmpty;
  }

  /// Summary of how many data sources are configured.
  int get configuredCount {
    int count = 0;
    if (isEmailConfigured) count++;
    if (isWebSearchConfigured) count++;
    if (isGoogleDriveConfigured) count++;
    if (isOneDriveConfigured) count++;
    if (isSshConfigured) count++;
    if (isHomeAssistantConfigured) count++;
    if (isSlackConfigured) count++;
    if (isWhatsAppConfigured) count++;
    return count;
  }

  // ═══════════════════════════════════════════════════
  // Load from secure storage
  // ═══════════════════════════════════════════════════

  Future<void> load() async {
    // On Linux, probe keyring availability once and bypass secure storage if locked.
    if (Platform.isLinux && !_keyringUnavailable) {
      try {
        await _storage.read(key: 'ping');
      } catch (_) {
        _keyringUnavailable = true;
        log.warning('[DataSources] Keyring unavailable on Linux — using shadow prefs exclusively');
      }
    }
    if (_keyringUnavailable) {
      await _loadFromShadowPrefs();
      _loaded = true;
      notifyListeners();
      return;
    }
    try {
      _emailProvider = EmailProvider.fromConfigKey(await _storage.read(key: _kEmailProvider));
      _emailEnabled = (await _storage.read(key: _kEmailEnabled)) == 'true';
      _gmailClientId = await _storage.read(key: _kGmailClientId) ?? '';
      _gmailClientSecret = await _storage.read(key: _kGmailClientSecret) ?? '';
      _gmailAccessToken = await _storage.read(key: _kGmailAccessToken) ?? '';
      _gmailRefreshToken = await _storage.read(key: _kGmailRefreshToken) ?? '';
      _gmailAccountEmail = await _storage.read(key: _kGmailAccountEmail) ?? '';
      final expiryRaw = await _storage.read(key: _kGmailTokenExpiry);
      _gmailTokenExpiry = expiryRaw != null && expiryRaw.isNotEmpty ? DateTime.tryParse(expiryRaw) : null;
      _imapHost = await _storage.read(key: _kImapHost) ?? '';
      _imapPort = int.tryParse(await _storage.read(key: _kImapPort) ?? '') ?? 993;
      _imapUsername = await _storage.read(key: _kImapUsername) ?? '';
      _imapPassword = await _storage.read(key: _kImapPassword) ?? '';
      _imapUseSsl = (await _storage.read(key: _kImapUseSsl) ?? 'true') == 'true';
      _smtpHost = await _storage.read(key: _kSmtpHost) ?? '';
      _smtpPort = int.tryParse(await _storage.read(key: _kSmtpPort) ?? '') ?? 587;
      _smtpSender = await _storage.read(key: _kSmtpSender) ?? '';

      _webSearchProvider = WebSearchProvider.fromConfigKey(await _storage.read(key: _kWebSearchProvider));
      _webSearchEnabled = (await _storage.read(key: _kWebSearchEnabled)) == 'true';
      _webSearchApiKey = await _storage.read(key: _kWebSearchApiKey) ?? '';
      _webSearchEngineId = await _storage.read(key: _kWebSearchEngineId) ?? '';
      _webSearchMaxResults = int.tryParse(await _storage.read(key: _kWebSearchMaxResults) ?? '') ?? 5;
      _webSearchCustomProviderName = await _storage.read(key: _kWebSearchCustomProviderName) ?? '';
      _webSearchCustomEndpoint = await _storage.read(key: _kWebSearchCustomEndpoint) ?? '';
      _duckDbIndexSizeLimitGb = (double.tryParse(await _storage.read(key: _kDuckDbIndexSizeLimitGb) ?? '') ?? 1.0).clamp(0.1, 50.0);

      _websiteIndexUrls = await _storage.read(key: _kWebsiteIndexUrls) ?? '';
      _websiteIndexMaxPages = (int.tryParse(await _storage.read(key: _kWebsiteIndexMaxPages) ?? '') ?? 100).clamp(1, 1000);
      _websiteIndexCron = await _storage.read(key: _kWebsiteIndexCron) ?? '';
      final wiLastRaw = await _storage.read(key: _kWebsiteIndexLastIndexed);
      _websiteIndexLastIndexedAt = wiLastRaw != null && wiLastRaw.isNotEmpty ? DateTime.tryParse(wiLastRaw) : null;

      _documentRootPaths = await _storage.read(key: _kDocumentRootPaths) ?? '';
      // On Android, default to Downloads folder when no folder has been configured yet.
      if (_documentRootPaths.isEmpty && Platform.isAndroid) {
        _documentRootPaths = '/storage/emulated/0/Download';
      }
      _documentFileTypes = await _storage.read(key: _kDocumentFileTypes) ?? 'pdf,md,docx';
      _documentIndexCron = await _storage.read(key: _kDocumentIndexCron) ?? '';
      final diLastRaw = await _storage.read(key: _kDocumentIndexLastIndexed);
      _documentIndexLastIndexedAt = diLastRaw != null && diLastRaw.isNotEmpty ? DateTime.tryParse(diLastRaw) : null;

      _googleDriveEnabled = (await _storage.read(key: _kGoogleDriveEnabled)) == 'true';
      _oneDriveEnabled = (await _storage.read(key: _kOneDriveEnabled)) == 'true';
      _oneDriveClientId = await _storage.read(key: _kOneDriveClientId) ?? '';
      _oneDriveTenantId = await _storage.read(key: _kOneDriveTenantId) ?? '';

      _notificationEmailEnabled = (await _storage.read(key: _kNotificationEmailEnabled)) == 'true';
      _outputRetentionDays = (int.tryParse(await _storage.read(key: _kOutputRetentionDays) ?? '') ?? 2).clamp(1, 30);

      final latRaw = await _storage.read(key: _kLocationLat);
      final lngRaw = await _storage.read(key: _kLocationLng);
      _locationLat = latRaw != null ? double.tryParse(latRaw) : null;
      _locationLng = lngRaw != null ? double.tryParse(lngRaw) : null;

      _sshHost = await _storage.read(key: _kSshHost) ?? '';
      _sshPort = int.tryParse(await _storage.read(key: _kSshPort) ?? '') ?? 22;
      _sshUsername = await _storage.read(key: _kSshUsername) ?? '';
      _sshPassword = await _storage.read(key: _kSshPassword) ?? '';
      _sshPrivateKey = await _storage.read(key: _kSshPrivateKey) ?? '';

      _haBaseUrl = await _storage.read(key: _kHaBaseUrl) ?? '';
      _haToken = await _storage.read(key: _kHaToken) ?? '';

      _slackEnabled = (await _storage.read(key: _kSlackEnabled)) == 'true';
      _slackWebhookUrl = await _storage.read(key: _kSlackWebhookUrl) ?? '';
      _slackBotToken = await _storage.read(key: _kSlackBotToken) ?? '';
      _slackDefaultChannel = await _storage.read(key: _kSlackDefaultChannel) ?? '';

      _whatsAppEnabled = (await _storage.read(key: _kWhatsAppEnabled)) == 'true';
      _whatsAppMode = await _storage.read(key: _kWhatsAppMode) ?? 'meta';
      _whatsAppPhoneNumberId = await _storage.read(key: _kWhatsAppPhoneNumberId) ?? '';
      _whatsAppAccessToken = await _storage.read(key: _kWhatsAppAccessToken) ?? '';
      _whatsAppDefaultRecipient = await _storage.read(key: _kWhatsAppDefaultRecipient) ?? '';
      _whatsAppCallMeBotApiKey = await _storage.read(key: _kWhatsAppCallMeBotApiKey) ?? '';

      _loaded = true;
      log.info(
        '[DataSources] Loaded – email=${_emailProvider.configKey}, search=${_webSearchProvider.configKey}, gdrive=$_googleDriveEnabled, onedrive=$_oneDriveEnabled',
      );
      // Keep the SharedPreferences shadow current so Linux/Android can fall back when keyring is locked.
      await _writeShadowPrefs();
      // On Android/iOS, background isolates (WorkManager, AlarmManager) run in a separate
      // FlutterEngine context where flutter_secure_storage silently returns null for all
      // keys — no exception is thrown, credentials just come back as empty strings.
      // Supplement any empty values from the shadow copy kept in SharedPreferences
      // (always accessible from background), which is written on every foreground load / save.
      if (Platform.isAndroid || Platform.isIOS) {
        await _supplementFromShadowPrefs();
      }
      notifyListeners();
    } catch (e) {
      log.error('[DataSources] Failed to load: $e');
      // On Linux the keyring may be locked — storage.read() throws instead of
      // returning null. Fall back to the SharedPreferences shadow copy so the
      // app still shows the configured state.
      // On Android/iOS the same can happen in background isolates.
      if (Platform.isLinux || Platform.isAndroid || Platform.isIOS) {
        try {
          await _loadFromShadowPrefs();
          log.info('[DataSources] Recovered from storage error via shadow prefs – email=${_emailProvider.configKey}');
        } catch (e2) {
          log.warning('[DataSources] Shadow fallback also failed: $e2');
        }
      }
      _loaded = true;
      notifyListeners();
    }
  }

  // ═══════════════════════════════════════════════════
  // Shadow prefs helpers (Linux keyring fallback)
  // ═══════════════════════════════════════════════════

  /// Write a shadow copy of all state to SharedPreferences so Linux can
  /// recover when libsecret (keyring) is locked on the next boot.
  Future<void> _writeShadowPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Email
      await prefs.setString('${_kShadowPrefix}emailProvider', _emailProvider.configKey);
      await prefs.setBool('${_kShadowPrefix}emailEnabled', _emailEnabled);
      await prefs.setString('${_kShadowPrefix}gmailClientId', _gmailClientId);
      await prefs.setString('${_kShadowPrefix}gmailClientSecret', _gmailClientSecret);
      await prefs.setString('${_kShadowPrefix}gmailRefreshToken', _gmailRefreshToken);
      await prefs.setString('${_kShadowPrefix}gmailAccessToken', _gmailAccessToken);
      await prefs.setString('${_kShadowPrefix}gmailAccountEmail', _gmailAccountEmail);
      await prefs.setString('${_kShadowPrefix}gmailTokenExpiry', _gmailTokenExpiry?.toIso8601String() ?? '');
      await prefs.setString('${_kShadowPrefix}imapHost', _imapHost);
      await prefs.setInt('${_kShadowPrefix}imapPort', _imapPort);
      await prefs.setString('${_kShadowPrefix}imapUsername', _imapUsername);
      await prefs.setString('${_kShadowPrefix}imapPassword', _imapPassword);
      await prefs.setBool('${_kShadowPrefix}imapUseSsl', _imapUseSsl);
      await prefs.setString('${_kShadowPrefix}smtpHost', _smtpHost);
      await prefs.setInt('${_kShadowPrefix}smtpPort', _smtpPort);
      await prefs.setString('${_kShadowPrefix}smtpSender', _smtpSender);
      await prefs.setBool('${_kShadowPrefix}notificationEmailEnabled', _notificationEmailEnabled);
      // Web search
      await prefs.setString('${_kShadowPrefix}webSearchProvider', _webSearchProvider.configKey);
      await prefs.setBool('${_kShadowPrefix}webSearchEnabled', _webSearchEnabled);
      await prefs.setString('${_kShadowPrefix}webSearchApiKey', _webSearchApiKey);
      await prefs.setString('${_kShadowPrefix}webSearchEngineId', _webSearchEngineId);
      await prefs.setInt('${_kShadowPrefix}webSearchMaxResults', _webSearchMaxResults);
      await prefs.setString('${_kShadowPrefix}webSearchCustomProviderName', _webSearchCustomProviderName);
      await prefs.setString('${_kShadowPrefix}webSearchCustomEndpoint', _webSearchCustomEndpoint);
      await prefs.setDouble('${_kShadowPrefix}duckDbIndexSizeLimitGb', _duckDbIndexSizeLimitGb);
      // Website index
      await prefs.setString('${_kShadowPrefix}websiteIndexUrls', _websiteIndexUrls);
      await prefs.setInt('${_kShadowPrefix}websiteIndexMaxPages', _websiteIndexMaxPages);
      await prefs.setString('${_kShadowPrefix}websiteIndexCron', _websiteIndexCron);
      await prefs.setString('${_kShadowPrefix}websiteIndexLastIndexedAt', _websiteIndexLastIndexedAt?.toIso8601String() ?? '');
      // Document index
      await prefs.setString('${_kShadowPrefix}documentRootPaths', _documentRootPaths);
      await prefs.setString('${_kShadowPrefix}documentIndexCron', _documentIndexCron);
      await prefs.setString('${_kShadowPrefix}documentIndexLastIndexedAt', _documentIndexLastIndexedAt?.toIso8601String() ?? '');
      // Cloud storage
      await prefs.setBool('${_kShadowPrefix}googleDriveEnabled', _googleDriveEnabled);
      await prefs.setBool('${_kShadowPrefix}oneDriveEnabled', _oneDriveEnabled);
      await prefs.setString('${_kShadowPrefix}oneDriveClientId', _oneDriveClientId);
      await prefs.setString('${_kShadowPrefix}oneDriveTenantId', _oneDriveTenantId);
      // Misc
      await prefs.setInt('${_kShadowPrefix}outputRetentionDays', _outputRetentionDays);
      if (_locationLat != null) {
        await prefs.setDouble('${_kShadowPrefix}locationLat', _locationLat!);
      }
      if (_locationLng != null) {
        await prefs.setDouble('${_kShadowPrefix}locationLng', _locationLng!);
      }
      // SSH
      await prefs.setString('${_kShadowPrefix}sshHost', _sshHost);
      await prefs.setInt('${_kShadowPrefix}sshPort', _sshPort);
      await prefs.setString('${_kShadowPrefix}sshUsername', _sshUsername);
      await prefs.setString('${_kShadowPrefix}sshPassword', _sshPassword);
      await prefs.setString('${_kShadowPrefix}sshPrivateKey', _sshPrivateKey);
      // Home Assistant
      await prefs.setString('${_kShadowPrefix}haBaseUrl', _haBaseUrl);
      await prefs.setString('${_kShadowPrefix}haToken', _haToken);
      // Slack
      await prefs.setBool('${_kShadowPrefix}slackEnabled', _slackEnabled);
      await prefs.setString('${_kShadowPrefix}slackWebhookUrl', _slackWebhookUrl);
      await prefs.setString('${_kShadowPrefix}slackBotToken', _slackBotToken);
      await prefs.setString('${_kShadowPrefix}slackDefaultChannel', _slackDefaultChannel);
      // WhatsApp
      await prefs.setBool('${_kShadowPrefix}whatsAppEnabled', _whatsAppEnabled);
      await prefs.setString('${_kShadowPrefix}whatsAppMode', _whatsAppMode);
      await prefs.setString('${_kShadowPrefix}whatsAppPhoneNumberId', _whatsAppPhoneNumberId);
      await prefs.setString('${_kShadowPrefix}whatsAppAccessToken', _whatsAppAccessToken);
      await prefs.setString('${_kShadowPrefix}whatsAppDefaultRecipient', _whatsAppDefaultRecipient);
      await prefs.setString('${_kShadowPrefix}whatsAppCallMeBotApiKey', _whatsAppCallMeBotApiKey);
    } catch (e) {
      log.warning('[DataSources] Shadow write failed (non-fatal): $e');
    }
  }

  /// Supplement empty credential values with the SharedPreferences shadow copy.
  ///
  /// Unlike [_loadFromShadowPrefs] which overwrites everything, this method only
  /// fills in values that are currently empty. Used on Android/iOS after the main
  /// secure-storage load to handle background-isolate contexts where
  /// flutter_secure_storage silently returns null for every key.
  Future<void> _supplementFromShadowPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // If the shadow has never been written, nothing to supplement.
      if (!prefs.containsKey('${_kShadowPrefix}emailProvider')) return;
      // SSH
      if (_sshHost.isEmpty) {
        _sshHost = prefs.getString('${_kShadowPrefix}sshHost') ?? _sshHost;
      }
      if (_sshPort == 22) {
        final p = prefs.getInt('${_kShadowPrefix}sshPort');
        if (p != null && p > 0) _sshPort = p;
      }
      if (_sshUsername.isEmpty) {
        _sshUsername = prefs.getString('${_kShadowPrefix}sshUsername') ?? _sshUsername;
      }
      if (_sshPassword.isEmpty) {
        _sshPassword = prefs.getString('${_kShadowPrefix}sshPassword') ?? _sshPassword;
      }
      if (_sshPrivateKey.isEmpty) {
        _sshPrivateKey = prefs.getString('${_kShadowPrefix}sshPrivateKey') ?? _sshPrivateKey;
      }
      // Email / IMAP
      if (_imapHost.isEmpty) {
        _imapHost = prefs.getString('${_kShadowPrefix}imapHost') ?? _imapHost;
      }
      if (_imapUsername.isEmpty) {
        _imapUsername = prefs.getString('${_kShadowPrefix}imapUsername') ?? _imapUsername;
      }
      if (_imapPassword.isEmpty) {
        _imapPassword = prefs.getString('${_kShadowPrefix}imapPassword') ?? _imapPassword;
      }
      if (_gmailRefreshToken.isEmpty) {
        _gmailRefreshToken = prefs.getString('${_kShadowPrefix}gmailRefreshToken') ?? _gmailRefreshToken;
      }
      if (_gmailAccessToken.isEmpty) {
        _gmailAccessToken = prefs.getString('${_kShadowPrefix}gmailAccessToken') ?? _gmailAccessToken;
      }
      // Home Assistant
      if (_haBaseUrl.isEmpty) {
        _haBaseUrl = prefs.getString('${_kShadowPrefix}haBaseUrl') ?? _haBaseUrl;
      }
      if (_haToken.isEmpty) {
        _haToken = prefs.getString('${_kShadowPrefix}haToken') ?? _haToken;
      }
      // Slack
      if (_slackWebhookUrl.isEmpty) {
        _slackWebhookUrl = prefs.getString('${_kShadowPrefix}slackWebhookUrl') ?? _slackWebhookUrl;
      }
      if (_slackBotToken.isEmpty) {
        _slackBotToken = prefs.getString('${_kShadowPrefix}slackBotToken') ?? _slackBotToken;
      }
      // WhatsApp
      if (_whatsAppAccessToken.isEmpty) {
        _whatsAppAccessToken = prefs.getString('${_kShadowPrefix}whatsAppAccessToken') ?? _whatsAppAccessToken;
      }
      if (_whatsAppCallMeBotApiKey.isEmpty) {
        _whatsAppCallMeBotApiKey = prefs.getString('${_kShadowPrefix}whatsAppCallMeBotApiKey') ?? _whatsAppCallMeBotApiKey;
      }
      // Web search
      if (_webSearchApiKey.isEmpty) {
        _webSearchApiKey = prefs.getString('${_kShadowPrefix}webSearchApiKey') ?? _webSearchApiKey;
      }
      log.info('[DataSources] Supplemented empty credentials from shadow prefs (background isolate).');
    } catch (e) {
      log.warning('[DataSources] Shadow supplement failed (non-fatal): $e');
    }
  }

  /// Read state back from the SharedPreferences shadow (Linux keyring / background fallback).
  Future<void> _loadFromShadowPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Guard: if the shadow has never been written, bail out gracefully.
      if (!prefs.containsKey('${_kShadowPrefix}emailProvider')) return;
      // Email
      _emailProvider = EmailProvider.fromConfigKey(prefs.getString('${_kShadowPrefix}emailProvider'));
      _emailEnabled = prefs.getBool('${_kShadowPrefix}emailEnabled') ?? _emailEnabled;
      _gmailClientId = prefs.getString('${_kShadowPrefix}gmailClientId') ?? _gmailClientId;
      _gmailClientSecret = prefs.getString('${_kShadowPrefix}gmailClientSecret') ?? _gmailClientSecret;
      _gmailRefreshToken = prefs.getString('${_kShadowPrefix}gmailRefreshToken') ?? _gmailRefreshToken;
      _gmailAccessToken = prefs.getString('${_kShadowPrefix}gmailAccessToken') ?? _gmailAccessToken;
      _gmailAccountEmail = prefs.getString('${_kShadowPrefix}gmailAccountEmail') ?? _gmailAccountEmail;
      final expiryRaw = prefs.getString('${_kShadowPrefix}gmailTokenExpiry') ?? '';
      if (expiryRaw.isNotEmpty) {
        _gmailTokenExpiry = DateTime.tryParse(expiryRaw);
      }
      _imapHost = prefs.getString('${_kShadowPrefix}imapHost') ?? _imapHost;
      _imapPort = prefs.getInt('${_kShadowPrefix}imapPort') ?? _imapPort;
      _imapUsername = prefs.getString('${_kShadowPrefix}imapUsername') ?? _imapUsername;
      _imapPassword = prefs.getString('${_kShadowPrefix}imapPassword') ?? _imapPassword;
      _imapUseSsl = prefs.getBool('${_kShadowPrefix}imapUseSsl') ?? _imapUseSsl;
      _smtpHost = prefs.getString('${_kShadowPrefix}smtpHost') ?? _smtpHost;
      _smtpPort = prefs.getInt('${_kShadowPrefix}smtpPort') ?? _smtpPort;
      _smtpSender = prefs.getString('${_kShadowPrefix}smtpSender') ?? _smtpSender;
      _notificationEmailEnabled = prefs.getBool('${_kShadowPrefix}notificationEmailEnabled') ?? _notificationEmailEnabled;
      // Web search
      _webSearchProvider = WebSearchProvider.fromConfigKey(prefs.getString('${_kShadowPrefix}webSearchProvider'));
      _webSearchEnabled = prefs.getBool('${_kShadowPrefix}webSearchEnabled') ?? _webSearchEnabled;
      _webSearchApiKey = prefs.getString('${_kShadowPrefix}webSearchApiKey') ?? _webSearchApiKey;
      _webSearchEngineId = prefs.getString('${_kShadowPrefix}webSearchEngineId') ?? _webSearchEngineId;
      _webSearchMaxResults = prefs.getInt('${_kShadowPrefix}webSearchMaxResults') ?? _webSearchMaxResults;
      _webSearchCustomProviderName = prefs.getString('${_kShadowPrefix}webSearchCustomProviderName') ?? _webSearchCustomProviderName;
      _webSearchCustomEndpoint = prefs.getString('${_kShadowPrefix}webSearchCustomEndpoint') ?? _webSearchCustomEndpoint;
      _duckDbIndexSizeLimitGb = prefs.getDouble('${_kShadowPrefix}duckDbIndexSizeLimitGb') ?? _duckDbIndexSizeLimitGb;
      // Website index
      _websiteIndexUrls = prefs.getString('${_kShadowPrefix}websiteIndexUrls') ?? _websiteIndexUrls;
      _websiteIndexMaxPages = prefs.getInt('${_kShadowPrefix}websiteIndexMaxPages') ?? _websiteIndexMaxPages;
      _websiteIndexCron = prefs.getString('${_kShadowPrefix}websiteIndexCron') ?? _websiteIndexCron;
      final wiLastRaw = prefs.getString('${_kShadowPrefix}websiteIndexLastIndexedAt') ?? '';
      if (wiLastRaw.isNotEmpty) {
        _websiteIndexLastIndexedAt = DateTime.tryParse(wiLastRaw);
      }
      // Document index
      _documentRootPaths = prefs.getString('${_kShadowPrefix}documentRootPaths') ?? _documentRootPaths;
      _documentIndexCron = prefs.getString('${_kShadowPrefix}documentIndexCron') ?? _documentIndexCron;
      final diLastRaw = prefs.getString('${_kShadowPrefix}documentIndexLastIndexedAt') ?? '';
      if (diLastRaw.isNotEmpty) {
        _documentIndexLastIndexedAt = DateTime.tryParse(diLastRaw);
      }
      // Cloud storage
      _googleDriveEnabled = prefs.getBool('${_kShadowPrefix}googleDriveEnabled') ?? _googleDriveEnabled;
      _oneDriveEnabled = prefs.getBool('${_kShadowPrefix}oneDriveEnabled') ?? _oneDriveEnabled;
      _oneDriveClientId = prefs.getString('${_kShadowPrefix}oneDriveClientId') ?? _oneDriveClientId;
      _oneDriveTenantId = prefs.getString('${_kShadowPrefix}oneDriveTenantId') ?? _oneDriveTenantId;
      // Misc
      _outputRetentionDays = prefs.getInt('${_kShadowPrefix}outputRetentionDays') ?? _outputRetentionDays;
      _locationLat = prefs.getDouble('${_kShadowPrefix}locationLat');
      _locationLng = prefs.getDouble('${_kShadowPrefix}locationLng');
      // SSH
      _sshHost = prefs.getString('${_kShadowPrefix}sshHost') ?? _sshHost;
      _sshPort = prefs.getInt('${_kShadowPrefix}sshPort') ?? _sshPort;
      _sshUsername = prefs.getString('${_kShadowPrefix}sshUsername') ?? _sshUsername;
      _sshPassword = prefs.getString('${_kShadowPrefix}sshPassword') ?? _sshPassword;
      _sshPrivateKey = prefs.getString('${_kShadowPrefix}sshPrivateKey') ?? _sshPrivateKey;
      // Home Assistant
      _haBaseUrl = prefs.getString('${_kShadowPrefix}haBaseUrl') ?? _haBaseUrl;
      _haToken = prefs.getString('${_kShadowPrefix}haToken') ?? _haToken;
      // Slack
      _slackEnabled = prefs.getBool('${_kShadowPrefix}slackEnabled') ?? _slackEnabled;
      _slackWebhookUrl = prefs.getString('${_kShadowPrefix}slackWebhookUrl') ?? _slackWebhookUrl;
      _slackBotToken = prefs.getString('${_kShadowPrefix}slackBotToken') ?? _slackBotToken;
      _slackDefaultChannel = prefs.getString('${_kShadowPrefix}slackDefaultChannel') ?? _slackDefaultChannel;
      // WhatsApp
      _whatsAppEnabled = prefs.getBool('${_kShadowPrefix}whatsAppEnabled') ?? _whatsAppEnabled;
      _whatsAppMode = prefs.getString('${_kShadowPrefix}whatsAppMode') ?? _whatsAppMode;
      _whatsAppPhoneNumberId = prefs.getString('${_kShadowPrefix}whatsAppPhoneNumberId') ?? _whatsAppPhoneNumberId;
      _whatsAppAccessToken = prefs.getString('${_kShadowPrefix}whatsAppAccessToken') ?? _whatsAppAccessToken;
      _whatsAppDefaultRecipient = prefs.getString('${_kShadowPrefix}whatsAppDefaultRecipient') ?? _whatsAppDefaultRecipient;
      _whatsAppCallMeBotApiKey = prefs.getString('${_kShadowPrefix}whatsAppCallMeBotApiKey') ?? _whatsAppCallMeBotApiKey;
      log.info('[DataSources] Loaded from SharedPreferences shadow – email=${_emailProvider.configKey}, gdrive=$_googleDriveEnabled');
    } catch (e) {
      log.warning('[DataSources] Shadow read failed (non-fatal): $e');
    }
  }

  // ═══════════════════════════════════════════════════
  // Save all settings
  // ═══════════════════════════════════════════════════

  Future<void> saveEmail({
    required EmailProvider provider,
    required bool enabled,
    String gmailClientId = '',
    String gmailClientSecret = '',
    String imapHost = '',
    int imapPort = 993,
    String imapUsername = '',
    String imapPassword = '',
    bool imapUseSsl = true,
    String smtpHost = '',
    int smtpPort = 587,
    String smtpSender = '',
    bool notificationEmailEnabled = false,
  }) async {
    _emailProvider = provider;
    _emailEnabled = enabled;
    _gmailClientId = gmailClientId.trim();
    _gmailClientSecret = gmailClientSecret.trim();
    _imapHost = imapHost.trim();
    _imapPort = imapPort;
    _imapUsername = imapUsername.trim();
    _imapPassword = imapPassword.trim();
    _imapUseSsl = imapUseSsl;
    _smtpHost = smtpHost.trim();
    _smtpPort = smtpPort;
    _smtpSender = smtpSender.trim();
    _notificationEmailEnabled = notificationEmailEnabled;

    try {
      await _storage.write(key: _kEmailProvider, value: provider.configKey);
      await _storage.write(key: _kEmailEnabled, value: enabled.toString());
      await _storage.write(key: _kGmailClientId, value: _gmailClientId);
      await _storage.write(key: _kGmailClientSecret, value: _gmailClientSecret);
      await _storage.write(key: _kImapHost, value: _imapHost);
      await _storage.write(key: _kImapPort, value: _imapPort.toString());
      await _storage.write(key: _kImapUsername, value: _imapUsername);
      await _storage.write(key: _kImapPassword, value: _imapPassword);
      await _storage.write(key: _kImapUseSsl, value: _imapUseSsl.toString());
      await _storage.write(key: _kSmtpHost, value: _smtpHost);
      await _storage.write(key: _kSmtpPort, value: _smtpPort.toString());
      await _storage.write(key: _kSmtpSender, value: _smtpSender);
      await _storage.write(key: _kNotificationEmailEnabled, value: _notificationEmailEnabled.toString());

      await _writeShadowPrefs();
      log.info('[DataSources] Email saved – provider=${provider.configKey}, enabled=$enabled');
      notifyListeners();
    } catch (e) {
      if (_isLinuxKeyringError(e)) {
        _keyringUnavailable = true;
        log.warning('[DataSources] Keyring unavailable, email saved to shadow prefs: $e');
        await _writeShadowPrefs();
        notifyListeners();
        return;
      }
      log.error('[DataSources] Failed to save email: $e');
      rethrow;
    }
  }

  Future<void> saveGmailOAuthTokens({required String accessToken, String? refreshToken, DateTime? expiresAt, String? accountEmail}) async {
    _gmailAccessToken = accessToken.trim();
    if (refreshToken != null && refreshToken.trim().isNotEmpty) {
      _gmailRefreshToken = refreshToken.trim();
    }
    _gmailTokenExpiry = expiresAt;
    if (accountEmail != null && accountEmail.trim().isNotEmpty) {
      _gmailAccountEmail = accountEmail.trim();
    }

    try {
      await _storage.write(key: _kGmailAccessToken, value: _gmailAccessToken);
      await _storage.write(key: _kGmailRefreshToken, value: _gmailRefreshToken);
      await _storage.write(key: _kGmailAccountEmail, value: _gmailAccountEmail);
      await _storage.write(key: _kGmailTokenExpiry, value: _gmailTokenExpiry?.toIso8601String() ?? '');
      await _writeShadowPrefs();
    } catch (e) {
      if (!_isLinuxKeyringError(e)) rethrow;
      log.warning('[DataSources] Keyring unavailable, Gmail tokens in memory only: $e');
    }
    notifyListeners();
  }

  Future<void> clearGmailOAuthTokens() async {
    _gmailAccessToken = '';
    _gmailRefreshToken = '';
    _gmailTokenExpiry = null;
    _gmailAccountEmail = '';

    await _storage.delete(key: _kGmailAccessToken);
    await _storage.delete(key: _kGmailRefreshToken);
    await _storage.delete(key: _kGmailTokenExpiry);
    await _storage.delete(key: _kGmailAccountEmail);
    notifyListeners();
  }

  Future<Map<String, dynamic>> exchangeGmailAuthorizationCode({
    required String authorizationCode,
    String redirectUri = 'http://localhost/',
    String? codeVerifier,
  }) async {
    if (gmailClientId.trim().isEmpty) {
      return {'success': false, 'error': 'Gmail OAuth client ID not configured.'};
    }
    final rawInput = authorizationCode.trim();
    final parsedInput = Uri.tryParse(rawInput);
    final oauthError = parsedInput?.queryParameters['error']?.trim();
    if (oauthError != null && oauthError.isNotEmpty) {
      final oauthErrorDescription = parsedInput?.queryParameters['error_description']?.trim();
      return {'success': false, 'error': oauthErrorDescription?.isNotEmpty == true ? oauthErrorDescription : oauthError};
    }

    final code = _extractAuthCode(rawInput);
    if (code.isEmpty) {
      return {
        'success': false,
        'error': 'No authorization code found. Paste the full callback URL containing code=... or only the code value.',
      };
    }

    try {
      final tokenClientSecret = _clientSecretForTokenRequest();
      final baseBody = <String, String>{
        'code': code,
        'client_id': gmailClientId,
        'redirect_uri': redirectUri,
        'grant_type': 'authorization_code',
        if (codeVerifier != null && codeVerifier.trim().isNotEmpty) 'code_verifier': codeVerifier.trim(),
      };

      final withSecretBody = <String, String>{...baseBody, if (tokenClientSecret.isNotEmpty) 'client_secret': tokenClientSecret};

      var response = await http.post(
        Uri.parse('https://oauth2.googleapis.com/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: withSecretBody,
      );

      var payload = response.body.isNotEmpty ? jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic> : <String, dynamic>{};
      final firstStatusCode = response.statusCode;
      final firstPayload = payload;

      if (_shouldRetryTokenRequestWithoutSecret(response.statusCode, payload) && tokenClientSecret.isNotEmpty) {
        response = await http.post(
          Uri.parse('https://oauth2.googleapis.com/token'),
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          body: baseBody,
        );
        payload = response.body.isNotEmpty ? jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic> : <String, dynamic>{};
      }

      if (response.statusCode < 200 || response.statusCode >= 300 || payload['access_token'] == null) {
        final currentErrorDescription = (payload['error_description'] ?? payload['error'] ?? '').toString();
        final firstErrorDescription = (firstPayload['error_description'] ?? firstPayload['error'] ?? '').toString();
        final errorMessage =
            currentErrorDescription.toLowerCase().contains('client_secret is missing') &&
                (firstStatusCode < 200 || firstStatusCode >= 300) &&
                firstErrorDescription.isNotEmpty
            ? firstErrorDescription
            : currentErrorDescription;

        var finalError = errorMessage.isNotEmpty ? errorMessage : 'Google token exchange failed (${response.statusCode}).';
        if (finalError.toLowerCase() == 'unauthorized') {
          finalError =
              'Unauthorized. Check Google OAuth client type (Desktop App), ensure Gmail API is enabled, and use redirect URI http://localhost/ exactly.';
        }

        return {'success': false, 'error': finalError};
      }

      final accessToken = payload['access_token'] as String;
      final refreshToken = payload['refresh_token'] as String?;
      final expiresIn = (payload['expires_in'] as num?)?.toInt() ?? 3600;
      final expiresAt = DateTime.now().add(Duration(seconds: expiresIn));

      String? accountEmail;
      try {
        final userInfoResp = await http.get(
          Uri.parse('https://www.googleapis.com/oauth2/v2/userinfo'),
          headers: {'Authorization': 'Bearer $accessToken', 'Accept': 'application/json'},
        );
        if (userInfoResp.statusCode >= 200 && userInfoResp.statusCode < 300 && userInfoResp.body.isNotEmpty) {
          final userInfo = jsonDecode(utf8.decode(userInfoResp.bodyBytes)) as Map<String, dynamic>;
          accountEmail = userInfo['email'] as String?;
        }
      } catch (_) {}

      await saveGmailOAuthTokens(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, accountEmail: accountEmail);

      return {
        'success': true,
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'expires_at': expiresAt.toIso8601String(),
        'email': accountEmail,
      };
    } catch (e) {
      return {'success': false, 'error': 'Google token exchange failed: $e'};
    }
  }

  String _extractAuthCode(String rawInput) {
    final input = rawInput.trim();
    if (input.isEmpty) return '';

    final parsed = Uri.tryParse(input);
    final queryCode = parsed?.queryParameters['code'];
    if (queryCode != null && queryCode.trim().isNotEmpty) {
      return queryCode.trim();
    }

    final codeMatch = RegExp(r'(?:^|[?&#])code=([^&#\s]+)').firstMatch(input);
    if (codeMatch != null && codeMatch.groupCount >= 1) {
      final encoded = codeMatch.group(1)?.trim() ?? '';
      if (encoded.isNotEmpty) return Uri.decodeQueryComponent(encoded);
    }

    final firstParam = input.split('&').first.trim();
    if (firstParam.startsWith('code=')) {
      final encoded = firstParam.substring('code='.length).trim();
      if (encoded.isNotEmpty) return Uri.decodeQueryComponent(encoded);
    }

    // Looks like query parameters were pasted without a code key.
    if (input.contains('scope=') || input.contains('authuser=') || input.contains('&')) {
      return '';
    }

    return input;
  }

  String _clientSecretForTokenRequest() {
    final storedSecret = gmailClientSecret.trim();
    if (storedSecret.isNotEmpty) return storedSecret;
    final buildSecret = OAuthDefaults.gmailClientSecret.trim();
    if (buildSecret.isNotEmpty) return buildSecret;
    return '';
  }

  bool _shouldRetryTokenRequestWithoutSecret(int statusCode, Map<String, dynamic> payload) {
    final error = (payload['error']?.toString() ?? '').toLowerCase();
    return statusCode == 401 || error == 'invalid_client' || error == 'unauthorized_client';
  }

  Future<Map<String, dynamic>> refreshGmailAccessToken() async {
    if (gmailClientId.trim().isEmpty) {
      return {'success': false, 'error': 'Gmail OAuth client ID not configured.'};
    }

    // On Android/iOS the google_sign_in plugin owns token refresh — no OAuth
    // refresh token is ever stored. Attempt lightweight authentication and
    // refresh client authorization token for Gmail scopes.
    if (_gmailRefreshToken.trim().isEmpty) {
      if (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS) {
        try {
          final googleSignIn = await _googleSignInClient();
          final account = await googleSignIn.attemptLightweightAuthentication(reportAllExceptions: false);
          if (account != null) {
            final authz = await account.authorizationClient.authorizationForScopes(gmailOAuthScopes);
            final freshToken = authz?.accessToken.trim() ?? '';
            if (freshToken.isNotEmpty) {
              talker.info('[DataSources] Silent Google re-auth succeeded, storing fresh token.');
              final expiresAt = DateTime.now().add(const Duration(minutes: 50));
              await saveGmailOAuthTokens(accessToken: freshToken, refreshToken: '', expiresAt: expiresAt, accountEmail: account.email);
              return {'success': true, 'access_token': freshToken, 'expires_at': expiresAt.toIso8601String()};
            }
          }
          talker.warning('[DataSources] Silent Google sign-in returned no account/token.');
        } catch (e) {
          talker.error('[DataSources] Silent Google sign-in failed: $e');
        }
      }
      return {'success': false, 'error': 'No Gmail refresh token available.'};
    }

    try {
      final tokenClientSecret = _clientSecretForTokenRequest();
      final baseBody = <String, String>{'client_id': gmailClientId, 'refresh_token': _gmailRefreshToken, 'grant_type': 'refresh_token'};

      final withSecretBody = <String, String>{...baseBody, if (tokenClientSecret.isNotEmpty) 'client_secret': tokenClientSecret};

      var response = await http.post(
        Uri.parse('https://oauth2.googleapis.com/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: withSecretBody,
      );

      var payload = response.body.isNotEmpty ? jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic> : <String, dynamic>{};
      final firstStatusCode = response.statusCode;
      final firstPayload = payload;

      if (_shouldRetryTokenRequestWithoutSecret(response.statusCode, payload) && tokenClientSecret.isNotEmpty) {
        response = await http.post(
          Uri.parse('https://oauth2.googleapis.com/token'),
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          body: baseBody,
        );
        payload = response.body.isNotEmpty ? jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic> : <String, dynamic>{};
      }

      if (response.statusCode < 200 || response.statusCode >= 300 || payload['access_token'] == null) {
        final currentErrorDescription = (payload['error_description'] ?? payload['error'] ?? '').toString();
        final firstErrorDescription = (firstPayload['error_description'] ?? firstPayload['error'] ?? '').toString();
        final errorMessage =
            currentErrorDescription.toLowerCase().contains('client_secret is missing') &&
                (firstStatusCode < 200 || firstStatusCode >= 300) &&
                firstErrorDescription.isNotEmpty
            ? firstErrorDescription
            : currentErrorDescription;

        return {
          'success': false,
          'error': errorMessage.isNotEmpty ? errorMessage : 'Google token refresh failed (${response.statusCode}).',
        };
      }

      final accessToken = payload['access_token'] as String;
      final expiresIn = (payload['expires_in'] as num?)?.toInt() ?? 3600;
      final expiresAt = DateTime.now().add(Duration(seconds: expiresIn));

      await saveGmailOAuthTokens(accessToken: accessToken, expiresAt: expiresAt);
      return {'success': true, 'access_token': accessToken, 'expires_at': expiresAt.toIso8601String()};
    } catch (e) {
      return {'success': false, 'error': 'Google token refresh failed: $e'};
    }
  }

  Future<void> saveWebSearch({
    required WebSearchProvider provider,
    required bool enabled,
    String apiKey = '',
    String engineId = '',
    int maxResults = 5,
    String customProviderName = '',
    String customEndpoint = '',
  }) async {
    _webSearchProvider = provider;
    _webSearchEnabled = enabled;
    _webSearchApiKey = apiKey.trim();
    _webSearchEngineId = engineId.trim();
    _webSearchMaxResults = maxResults.clamp(1, 50);
    _webSearchCustomProviderName = customProviderName.trim();
    _webSearchCustomEndpoint = customEndpoint.trim();

    try {
      await _storage.write(key: _kWebSearchProvider, value: provider.configKey);
      await _storage.write(key: _kWebSearchEnabled, value: enabled.toString());
      await _storage.write(key: _kWebSearchApiKey, value: _webSearchApiKey);
      await _storage.write(key: _kWebSearchEngineId, value: _webSearchEngineId);
      await _storage.write(key: _kWebSearchMaxResults, value: _webSearchMaxResults.toString());
      await _storage.write(key: _kWebSearchCustomProviderName, value: _webSearchCustomProviderName);
      await _storage.write(key: _kWebSearchCustomEndpoint, value: _webSearchCustomEndpoint);

      await _writeShadowPrefs();
      log.info('[DataSources] WebSearch saved – provider=${provider.configKey}, enabled=$enabled');
      notifyListeners();
    } catch (e) {
      if (_isLinuxKeyringError(e)) {
        _keyringUnavailable = true;
        log.warning('[DataSources] Keyring unavailable, web search saved to shadow prefs: $e');
        await _writeShadowPrefs();
        notifyListeners();
        return;
      }
      log.error('[DataSources] Failed to save web search: $e');
      rethrow;
    }
  }

  Future<void> saveCloudStorage({
    required bool googleDriveEnabled,
    required bool oneDriveEnabled,
    required String oneDriveClientId,
    required String oneDriveTenantId,
  }) async {
    _googleDriveEnabled = googleDriveEnabled;
    _oneDriveEnabled = oneDriveEnabled;
    _oneDriveClientId = oneDriveClientId.trim();
    _oneDriveTenantId = oneDriveTenantId.trim();

    try {
      await _storage.write(key: _kGoogleDriveEnabled, value: googleDriveEnabled.toString());
      await _storage.write(key: _kOneDriveEnabled, value: oneDriveEnabled.toString());
      await _storage.write(key: _kOneDriveClientId, value: _oneDriveClientId);
      await _storage.write(key: _kOneDriveTenantId, value: _oneDriveTenantId);

      await _writeShadowPrefs();
      log.info('[DataSources] CloudStorage saved – gdrive=$googleDriveEnabled, onedrive=$oneDriveEnabled');
      notifyListeners();
    } catch (e) {
      if (_isLinuxKeyringError(e)) {
        _keyringUnavailable = true;
        log.warning('[DataSources] Keyring unavailable, cloud storage saved to shadow prefs: $e');
        await _writeShadowPrefs();
        notifyListeners();
        return;
      }
      log.error('[DataSources] Failed to save cloud storage: $e');
      rethrow;
    }
  }

  Future<void> saveOutputRetentionDays({required int days}) async {
    _outputRetentionDays = days.clamp(1, 30);
    try {
      await _storage.write(key: _kOutputRetentionDays, value: _outputRetentionDays.toString());
      log.info('[DataSources] Output retention days saved – days=$_outputRetentionDays');
      notifyListeners();
    } catch (e) {
      if (_isLinuxKeyringError(e)) {
        log.warning('[DataSources] Keyring unavailable, output retention in memory only: $e');
        notifyListeners();
        return;
      }
      log.error('[DataSources] Failed to save output retention days: $e');
      rethrow;
    }
  }

  Future<void> saveDuckDbSettings({required double indexSizeLimitGb}) async {
    _duckDbIndexSizeLimitGb = indexSizeLimitGb.clamp(0.1, 50.0);
    try {
      await _storage.write(key: _kDuckDbIndexSizeLimitGb, value: _duckDbIndexSizeLimitGb.toString());
      log.info('[DataSources] DuckDB settings saved – sizeLimitGb=$_duckDbIndexSizeLimitGb');
      notifyListeners();
    } catch (e) {
      if (_isLinuxKeyringError(e)) {
        log.warning('[DataSources] Keyring unavailable, DuckDB settings in memory only: $e');
        notifyListeners();
        return;
      }
      log.error('[DataSources] Failed to save DuckDB settings: $e');
      rethrow;
    }
  }

  Future<void> saveDocumentIndex({required String rootPaths, String fileTypes = '', String cron = '', DateTime? lastIndexedAt}) async {
    _documentRootPaths = rootPaths.trim();
    if (fileTypes.trim().isNotEmpty) _documentFileTypes = fileTypes.trim();
    _documentIndexCron = cron.trim();
    if (lastIndexedAt != null) _documentIndexLastIndexedAt = lastIndexedAt;
    try {
      await _storage.write(key: _kDocumentRootPaths, value: _documentRootPaths);
      await _storage.write(key: _kDocumentFileTypes, value: _documentFileTypes);
      await _storage.write(key: _kDocumentIndexCron, value: _documentIndexCron);
      if (_documentIndexLastIndexedAt != null) {
        await _storage.write(key: _kDocumentIndexLastIndexed, value: _documentIndexLastIndexedAt!.toIso8601String());
      }
      log.info(
        '[DataSources] DocumentIndex saved – rootPaths=$_documentRootPaths, fileTypes=$_documentFileTypes, cron=$_documentIndexCron',
      );
      notifyListeners();
    } catch (e) {
      if (_isLinuxKeyringError(e)) {
        log.warning('[DataSources] Keyring unavailable, document index in memory only: $e');
        notifyListeners();
        return;
      }
      log.error('[DataSources] Failed to save document index settings: $e');
      rethrow;
    }
  }

  Future<void> saveWebsiteIndex({required String urls, required int maxPages, required String cron, DateTime? lastIndexedAt}) async {
    _websiteIndexUrls = urls.trim();
    _websiteIndexMaxPages = maxPages.clamp(1, 1000);
    _websiteIndexCron = cron.trim();
    if (lastIndexedAt != null) _websiteIndexLastIndexedAt = lastIndexedAt;
    try {
      await _storage.write(key: _kWebsiteIndexUrls, value: _websiteIndexUrls);
      await _storage.write(key: _kWebsiteIndexMaxPages, value: _websiteIndexMaxPages.toString());
      await _storage.write(key: _kWebsiteIndexCron, value: _websiteIndexCron);
      if (_websiteIndexLastIndexedAt != null) {
        await _storage.write(key: _kWebsiteIndexLastIndexed, value: _websiteIndexLastIndexedAt!.toIso8601String());
      }
      log.info('[DataSources] WebsiteIndex saved – urls=$_websiteIndexUrls, maxPages=$_websiteIndexMaxPages, cron=$_websiteIndexCron');
      notifyListeners();
    } catch (e) {
      if (_isLinuxKeyringError(e)) {
        log.warning('[DataSources] Keyring unavailable, website index in memory only: $e');
        notifyListeners();
        return;
      }
      log.error('[DataSources] Failed to save website index settings: $e');
      rethrow;
    }
  }

  /// Save the device GPS / manual location.
  Future<void> saveLocation(double latitude, double longitude) async {
    _locationLat = latitude;
    _locationLng = longitude;
    try {
      await _storage.write(key: _kLocationLat, value: latitude.toString());
      await _storage.write(key: _kLocationLng, value: longitude.toString());
      log.info('[DataSources] Location saved – lat=$latitude, lng=$longitude');
      notifyListeners();
    } catch (e) {
      if (_isLinuxKeyringError(e)) {
        log.warning('[DataSources] Keyring unavailable, location in memory only: $e');
        notifyListeners();
        return;
      }
      log.error('[DataSources] Failed to save location: $e');
      rethrow;
    }
  }

  /// Clear stored location.
  Future<void> clearLocation() async {
    _locationLat = null;
    _locationLng = null;
    await _storage.delete(key: _kLocationLat);
    await _storage.delete(key: _kLocationLng);
    notifyListeners();
  }

  // ── SSH ───────────────────────────────────────────

  Future<void> saveSlack({required bool enabled, String webhookUrl = '', String botToken = '', String defaultChannel = ''}) async {
    _slackEnabled = enabled;
    _slackWebhookUrl = webhookUrl.trim();
    _slackBotToken = botToken.trim();
    _slackDefaultChannel = defaultChannel.trim();
    try {
      await _storage.write(key: _kSlackEnabled, value: enabled.toString());
      await _storage.write(key: _kSlackWebhookUrl, value: _slackWebhookUrl);
      await _storage.write(key: _kSlackBotToken, value: _slackBotToken);
      await _storage.write(key: _kSlackDefaultChannel, value: _slackDefaultChannel);
      await _writeShadowPrefs();
      log.info('[DataSources] Slack saved – enabled=$enabled');
      notifyListeners();
    } catch (e) {
      if (_isLinuxKeyringError(e)) {
        _keyringUnavailable = true;
        log.warning('[DataSources] Keyring unavailable, Slack saved to shadow prefs: $e');
        await _writeShadowPrefs();
        notifyListeners();
        return;
      }
      log.error('[DataSources] Failed to save Slack: $e');
      rethrow;
    }
  }

  Future<void> saveWhatsApp({
    required bool enabled,
    String mode = 'meta',
    String phoneNumberId = '',
    String accessToken = '',
    String defaultRecipient = '',
    String callMeBotApiKey = '',
  }) async {
    _whatsAppEnabled = enabled;
    _whatsAppMode = mode;
    _whatsAppPhoneNumberId = phoneNumberId.trim();
    _whatsAppAccessToken = accessToken.trim();
    _whatsAppDefaultRecipient = defaultRecipient.trim();
    _whatsAppCallMeBotApiKey = callMeBotApiKey.trim();
    try {
      await _storage.write(key: _kWhatsAppEnabled, value: enabled.toString());
      await _storage.write(key: _kWhatsAppMode, value: _whatsAppMode);
      await _storage.write(key: _kWhatsAppPhoneNumberId, value: _whatsAppPhoneNumberId);
      await _storage.write(key: _kWhatsAppAccessToken, value: _whatsAppAccessToken);
      await _storage.write(key: _kWhatsAppDefaultRecipient, value: _whatsAppDefaultRecipient);
      await _storage.write(key: _kWhatsAppCallMeBotApiKey, value: _whatsAppCallMeBotApiKey);
      await _writeShadowPrefs();
      log.info('[DataSources] WhatsApp saved – enabled=$enabled, mode=$mode');
      notifyListeners();
    } catch (e) {
      if (_isLinuxKeyringError(e)) {
        _keyringUnavailable = true;
        log.warning('[DataSources] Keyring unavailable, WhatsApp saved to shadow prefs: $e');
        await _writeShadowPrefs();
        notifyListeners();
        return;
      }
      log.error('[DataSources] Failed to save WhatsApp: $e');
      rethrow;
    }
  }

  Future<void> saveHomeAssistant({required String baseUrl, required String token}) async {
    _haBaseUrl = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    _haToken = token.trim();
    try {
      await _storage.write(key: _kHaBaseUrl, value: _haBaseUrl);
      await _storage.write(key: _kHaToken, value: _haToken);
      await _writeShadowPrefs();
      log.info('[DataSources] Home Assistant saved – url=$_haBaseUrl, hasToken=${_haToken.isNotEmpty}');
      notifyListeners();
    } catch (e) {
      if (_isLinuxKeyringError(e)) {
        _keyringUnavailable = true;
        log.warning('[DataSources] Keyring unavailable, Home Assistant saved to shadow prefs: $e');
        await _writeShadowPrefs();
        notifyListeners();
        return;
      }
      log.error('[DataSources] Failed to save Home Assistant: $e');
      rethrow;
    }
  }

  Future<void> saveSsh({
    required String host,
    int port = 22,
    required String username,
    required String password,
    String privateKey = '',
  }) async {
    _sshHost = host.trim();
    _sshPort = port;
    _sshUsername = username.trim();
    _sshPassword = password.trim();
    _sshPrivateKey = privateKey.trim();
    try {
      await _storage.write(key: _kSshHost, value: _sshHost);
      await _storage.write(key: _kSshPort, value: _sshPort.toString());
      await _storage.write(key: _kSshUsername, value: _sshUsername);
      await _storage.write(key: _kSshPassword, value: _sshPassword);
      await _storage.write(key: _kSshPrivateKey, value: _sshPrivateKey);
      await _writeShadowPrefs();
      log.info('[DataSources] SSH saved – host=$_sshHost, port=$_sshPort, username=$_sshUsername, hasKey=${_sshPrivateKey.isNotEmpty}');
      notifyListeners();
    } catch (e) {
      if (_isLinuxKeyringError(e)) {
        log.warning('[DataSources] Keyring unavailable, SSH in memory only: $e');
        notifyListeners();
        return;
      }
      log.error('[DataSources] Failed to save SSH: $e');
      rethrow;
    }
  }

  /// Clear all data source settings.
  Future<void> clearAll() async {
    _emailProvider = EmailProvider.none;
    _emailEnabled = false;
    _gmailClientId = '';
    _gmailClientSecret = '';
    _gmailAccessToken = '';
    _gmailRefreshToken = '';
    _gmailTokenExpiry = null;
    _gmailAccountEmail = '';
    _imapHost = '';
    _imapPort = 993;
    _imapUsername = '';
    _imapPassword = '';
    _imapUseSsl = true;

    _webSearchProvider = WebSearchProvider.duckduckgo;
    _webSearchEnabled = false;
    _webSearchApiKey = '';
    _webSearchEngineId = '';
    _webSearchMaxResults = 5;
    _webSearchCustomProviderName = '';
    _webSearchCustomEndpoint = '';
    _duckDbIndexSizeLimitGb = 1.0;

    _googleDriveEnabled = false;
    _oneDriveEnabled = false;
    _oneDriveClientId = '';
    _oneDriveTenantId = '';

    _notificationEmailEnabled = false;
    _outputRetentionDays = 2;
    _locationLat = null;
    _locationLng = null;
    _sshHost = '';
    _sshPort = 22;
    _sshUsername = '';
    _sshPassword = '';
    _slackEnabled = false;
    _slackWebhookUrl = '';
    _slackBotToken = '';
    _slackDefaultChannel = '';
    _whatsAppEnabled = false;
    _whatsAppMode = 'meta';
    _whatsAppPhoneNumberId = '';
    _whatsAppAccessToken = '';
    _whatsAppDefaultRecipient = '';
    _whatsAppCallMeBotApiKey = '';
    _haBaseUrl = '';
    _haToken = '';

    try {
      // Delete all keys with our prefix
      final all = await _storage.readAll();
      for (final key in all.keys) {
        if (key.startsWith(_prefix)) {
          await _storage.delete(key: key);
        }
      }
      log.info('[DataSources] All settings cleared');
      notifyListeners();
    } catch (e) {
      if (_isLinuxKeyringError(e)) {
        log.warning('[DataSources] Keyring unavailable, clear may be incomplete: $e');
        notifyListeners();
        return;
      }
      log.error('[DataSources] Failed to clear: $e');
      rethrow;
    }
  }
}
