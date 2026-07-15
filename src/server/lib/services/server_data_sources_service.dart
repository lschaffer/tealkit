import '../config/server_config_service.dart';
import '../utils/server_logger.dart';

// ═══════════════════════════════════════════════════════════════
// Enums
// ═══════════════════════════════════════════════════════════════

enum EmailProvider {
  none,
  gmail,
  imap;

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

enum WebSearchProvider {
  none,
  duckduckgo,
  serper,
  serpapi,
  custom;

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

enum CloudStorageProvider {
  none,
  googleDrive,
  oneDrive;

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
// Server Data Sources Settings Service — plain class, no Flutter
// ═══════════════════════════════════════════════════════════════

class ServerDataSourcesService {
  static final ServerDataSourcesService instance = ServerDataSourcesService._();
  ServerDataSourcesService._();

  String? _lastLoadedSummary;

  // ── Storage key prefix ────────────────────────────
  static const _p = 'ds_';

  // ── Email keys ────────────────────────────
  static const _kEmailProvider = '${_p}email_provider';
  static const _kEmailEnabled = '${_p}email_enabled';
  static const _kGmailClientId = '${_p}gmail_client_id';
  static const _kGmailClientSecret = '${_p}gmail_client_secret';
  static const _kGmailAccessToken = '${_p}gmail_access_token';
  static const _kGmailRefreshToken = '${_p}gmail_refresh_token';
  static const _kGmailTokenExpiry = '${_p}gmail_token_expiry';
  static const _kGmailAccountEmail = '${_p}gmail_account_email';
  static const _kImapHost = '${_p}imap_host';
  static const _kImapPort = '${_p}imap_port';
  static const _kImapUsername = '${_p}imap_username';
  static const _kImapPassword = '${_p}imap_password';
  static const _kImapUseSsl = '${_p}imap_use_ssl';
  static const _kSmtpHost = '${_p}smtp_host';
  static const _kSmtpPort = '${_p}smtp_port';
  static const _kSmtpSender = '${_p}smtp_sender';

  // ── Web search keys ───────────────────────────────
  static const _kWebSearchProvider = '${_p}websearch_provider';
  static const _kWebSearchEnabled = '${_p}websearch_enabled';
  static const _kWebSearchApiKey = '${_p}websearch_api_key';
  static const _kWebSearchEngineId = '${_p}websearch_engine_id';
  static const _kWebSearchMaxResults = '${_p}websearch_max_results';
  static const _kWebSearchCustomProviderName = '${_p}websearch_custom_provider_name';
  static const _kWebSearchCustomEndpoint = '${_p}websearch_custom_endpoint';
  static const _kDuckDbIndexSizeLimitGb = '${_p}duckdb_index_size_limit_gb';
  static const _kOutputRetentionDays = '${_p}output_retention_days';

  // ── Website index keys ───────────────────────────
  static const _kWebsiteIndexUrls = '${_p}website_index_urls';
  static const _kWebsiteIndexMaxPages = '${_p}website_index_max_pages';
  static const _kWebsiteIndexCron = '${_p}website_index_cron';
  static const _kWebsiteIndexLastIndexed = '${_p}website_index_last_indexed_at';

  // ── Document index keys ──────────────────────────
  static const _kDocumentRootPaths = '${_p}document_root_paths';
  static const _kDocumentFileTypes = '${_p}document_file_types';
  static const _kDocumentIndexLastIndexed = '${_p}document_index_last_indexed_at';
  static const _kDocumentIndexCron = '${_p}document_index_cron';

  // ── Cloud storage keys ────────────────────────────
  static const _kGoogleDriveEnabled = '${_p}gdrive_enabled';
  static const _kOneDriveEnabled = '${_p}onedrive_enabled';
  static const _kOneDriveClientId = '${_p}onedrive_client_id';
  static const _kOneDriveTenantId = '${_p}onedrive_tenant_id';

  // ── Notification / misc ───────────────────────────
  static const _kNotificationEmailEnabled = '${_p}notification_email_enabled';

  // ── Location ──────────────────────────────────────
  static const _kLocationLat = '${_p}location_lat';
  static const _kLocationLng = '${_p}location_lng';

  // ── SSH ───────────────────────────────────────────
  static const _kSshHost = '${_p}ssh_host';
  static const _kSshPort = '${_p}ssh_port';
  static const _kSshUsername = '${_p}ssh_username';
  static const _kSshPassword = '${_p}ssh_password';
  static const _kSshPrivateKey = '${_p}ssh_private_key';

  // ── Slack ─────────────────────────────────────────
  static const _kSlackEnabled = '${_p}slack_enabled';
  static const _kSlackWebhookUrl = '${_p}slack_webhook_url';
  static const _kSlackBotToken = '${_p}slack_bot_token';
  static const _kSlackDefaultChannel = '${_p}slack_default_channel';

  // ── Home Assistant ────────────────────────────────
  static const _kHaBaseUrl = '${_p}ha_base_url';
  static const _kHaToken = '${_p}ha_token';

  // ── WhatsApp ──────────────────────────────────────
  static const _kWhatsAppEnabled = '${_p}whatsapp_enabled';
  static const _kWhatsAppMode = '${_p}whatsapp_mode';
  static const _kWhatsAppPhoneNumberId = '${_p}whatsapp_phone_number_id';
  static const _kWhatsAppAccessToken = '${_p}whatsapp_access_token';
  static const _kWhatsAppDefaultRecipient = '${_p}whatsapp_default_recipient';
  static const _kWhatsAppCallMeBotApiKey = '${_p}whatsapp_callmebot_api_key';

  // ═══════════════════════════════════════════════════
  // State
  // ═══════════════════════════════════════════════════

  // Email
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

  // Web search
  WebSearchProvider _webSearchProvider = WebSearchProvider.duckduckgo;
  bool _webSearchEnabled = false;
  String _webSearchApiKey = '';
  String _webSearchEngineId = '';
  int _webSearchMaxResults = 5;
  String _webSearchCustomProviderName = '';
  String _webSearchCustomEndpoint = '';
  double _duckDbIndexSizeLimitGb = 1.0;
  int _outputRetentionDays = 2;

  // Website index
  String _websiteIndexUrls = '';
  int _websiteIndexMaxPages = 100;
  String _websiteIndexCron = '';
  DateTime? _websiteIndexLastIndexedAt;

  // Document index
  String _documentRootPaths = '';
  String _documentFileTypes = 'pdf,md,docx';
  String _documentIndexCron = '';
  DateTime? _documentIndexLastIndexedAt;

  // Cloud storage
  bool _googleDriveEnabled = false;
  bool _oneDriveEnabled = false;
  String _oneDriveClientId = '';
  String _oneDriveTenantId = '';

  // Notifications / misc
  bool _notificationEmailEnabled = false;

  // Location
  double? _locationLat;
  double? _locationLng;

  // SSH
  String _sshHost = '';
  int _sshPort = 22;
  String _sshUsername = '';
  String _sshPassword = '';
  String _sshPrivateKey = '';

  // Slack
  bool _slackEnabled = false;
  String _slackWebhookUrl = '';
  String _slackBotToken = '';
  String _slackDefaultChannel = '';

  // Home Assistant
  String _haBaseUrl = '';
  String _haToken = '';

  // WhatsApp
  bool _whatsAppEnabled = false;
  String _whatsAppMode = 'meta';
  String _whatsAppPhoneNumberId = '';
  String _whatsAppAccessToken = '';
  String _whatsAppDefaultRecipient = '';
  String _whatsAppCallMeBotApiKey = '';

  // ═══════════════════════════════════════════════════
  // Getters
  // ═══════════════════════════════════════════════════

  // Email
  EmailProvider get emailProvider => _emailProvider;
  bool get emailEnabled => _emailEnabled;
  String get gmailClientId => _gmailClientId;
  String get gmailClientSecret => _gmailClientSecret;
  String get gmailAccessToken => _gmailAccessToken;
  String get gmailRefreshToken => _gmailRefreshToken;
  DateTime? get gmailTokenExpiry => _gmailTokenExpiry;
  String get gmailAccountEmail => _gmailAccountEmail;
  bool get hasGmailOAuthTokens => _gmailRefreshToken.isNotEmpty || _gmailAccessToken.isNotEmpty;
  bool get isGmailAccessTokenExpired {
    final exp = _gmailTokenExpiry;
    if (exp == null) return true;
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
    if (_emailProvider == EmailProvider.gmail) return _gmailClientId.isNotEmpty && hasGmailOAuthTokens;
    if (_emailProvider == EmailProvider.imap) {
      return _imapHost.isNotEmpty && _imapUsername.isNotEmpty && _imapPassword.isNotEmpty;
    }
    return false;
  }

  // Web search
  WebSearchProvider get webSearchProvider => _webSearchProvider;
  bool get webSearchEnabled => _webSearchEnabled;
  String get webSearchApiKey => _webSearchApiKey;
  String get webSearchEngineId => _webSearchEngineId;
  int get webSearchMaxResults => _webSearchMaxResults;
  String get webSearchCustomProviderName => _webSearchCustomProviderName;
  String get webSearchCustomEndpoint => _webSearchCustomEndpoint;
  double get duckDbIndexSizeLimitGb => _duckDbIndexSizeLimitGb;
  int get outputRetentionDays => _outputRetentionDays;

  bool get isWebSearchConfigured {
    if (!_webSearchEnabled) return false;
    if (_webSearchProvider == WebSearchProvider.duckduckgo) return true;
    if (_webSearchProvider == WebSearchProvider.custom) return _webSearchCustomEndpoint.trim().isNotEmpty;
    return _webSearchApiKey.isNotEmpty;
  }

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

  // Cloud storage
  bool get googleDriveEnabled => _googleDriveEnabled;
  bool get isGoogleDriveConfigured => _googleDriveEnabled && _gmailClientId.isNotEmpty;
  bool get oneDriveEnabled => _oneDriveEnabled;
  String get oneDriveClientId => _oneDriveClientId;
  String get oneDriveTenantId => _oneDriveTenantId;
  bool get isOneDriveConfigured => _oneDriveEnabled && _oneDriveClientId.isNotEmpty;
  bool get isCloudStorageConfigured => isGoogleDriveConfigured || isOneDriveConfigured;

  // Notification
  bool get notificationEmailEnabled => _notificationEmailEnabled;

  // Location
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

  // ═══════════════════════════════════════════════════
  // Load
  // ═══════════════════════════════════════════════════

  Future<void> load() async {
    final cfg = ServerConfigService();

    // Email
    _emailProvider = EmailProvider.fromConfigKey(cfg.getString(_kEmailProvider));
    _emailEnabled = cfg.getBool(_kEmailEnabled) ?? false;
    _gmailClientId = cfg.getSecret(_kGmailClientId) ?? '';
    _gmailClientSecret = cfg.getSecret(_kGmailClientSecret) ?? '';
    _gmailAccessToken = cfg.getSecret(_kGmailAccessToken) ?? '';
    _gmailRefreshToken = cfg.getSecret(_kGmailRefreshToken) ?? '';
    final expiryStr = cfg.getSecret(_kGmailTokenExpiry) ?? cfg.getString(_kGmailTokenExpiry);
    _gmailTokenExpiry = expiryStr != null ? DateTime.tryParse(expiryStr) : null;
    _gmailAccountEmail = cfg.getSecret(_kGmailAccountEmail) ?? cfg.getString(_kGmailAccountEmail) ?? '';
    _imapHost = cfg.getString(_kImapHost) ?? '';
    _imapPort = cfg.getInt(_kImapPort) ?? 993;
    _imapUsername = cfg.getSecret(_kImapUsername) ?? cfg.getString(_kImapUsername) ?? '';
    _imapPassword = cfg.getSecret(_kImapPassword) ?? '';
    _imapUseSsl = cfg.getBool(_kImapUseSsl) ?? true;
    _smtpHost = cfg.getString(_kSmtpHost) ?? '';
    _smtpPort = cfg.getInt(_kSmtpPort) ?? 587;
    _smtpSender = cfg.getString(_kSmtpSender) ?? '';

    // Web search
    _webSearchProvider = WebSearchProvider.fromConfigKey(cfg.getString(_kWebSearchProvider));
    _webSearchEnabled = cfg.getBool(_kWebSearchEnabled) ?? false;
    _webSearchApiKey = cfg.getSecret(_kWebSearchApiKey) ?? '';
    _webSearchEngineId = cfg.getString(_kWebSearchEngineId) ?? '';
    _webSearchMaxResults = cfg.getInt(_kWebSearchMaxResults) ?? 5;
    _webSearchCustomProviderName = cfg.getString(_kWebSearchCustomProviderName) ?? '';
    _webSearchCustomEndpoint = cfg.getString(_kWebSearchCustomEndpoint) ?? '';
    _duckDbIndexSizeLimitGb = cfg.getDouble(_kDuckDbIndexSizeLimitGb) ?? 1.0;
    _outputRetentionDays = cfg.getInt(_kOutputRetentionDays) ?? 2;

    // Website index
    _websiteIndexUrls = cfg.getString(_kWebsiteIndexUrls) ?? '';
    _websiteIndexMaxPages = cfg.getInt(_kWebsiteIndexMaxPages) ?? 100;
    _websiteIndexCron = cfg.getString(_kWebsiteIndexCron) ?? '';
    final wiLastStr = cfg.getString(_kWebsiteIndexLastIndexed);
    _websiteIndexLastIndexedAt = wiLastStr != null ? DateTime.tryParse(wiLastStr) : null;

    // Document index
    _documentRootPaths = cfg.getString(_kDocumentRootPaths) ?? '';
    _documentFileTypes = cfg.getString(_kDocumentFileTypes) ?? 'pdf,md,docx';
    _documentIndexCron = cfg.getString(_kDocumentIndexCron) ?? '';
    final diLastStr = cfg.getString(_kDocumentIndexLastIndexed);
    _documentIndexLastIndexedAt = diLastStr != null ? DateTime.tryParse(diLastStr) : null;

    // Cloud storage
    _googleDriveEnabled = cfg.getBool(_kGoogleDriveEnabled) ?? false;
    _oneDriveEnabled = cfg.getBool(_kOneDriveEnabled) ?? false;
    _oneDriveClientId = cfg.getSecret(_kOneDriveClientId) ?? cfg.getString(_kOneDriveClientId) ?? '';
    _oneDriveTenantId = cfg.getString(_kOneDriveTenantId) ?? '';

    // Notification / misc
    _notificationEmailEnabled = cfg.getBool(_kNotificationEmailEnabled) ?? false;

    // Location
    _locationLat = cfg.getDouble(_kLocationLat);
    _locationLng = cfg.getDouble(_kLocationLng);

    // SSH
    _sshHost = cfg.getString(_kSshHost) ?? '';
    _sshPort = cfg.getInt(_kSshPort) ?? 22;
    _sshUsername = cfg.getSecret(_kSshUsername) ?? cfg.getString(_kSshUsername) ?? '';
    _sshPassword = cfg.getSecret(_kSshPassword) ?? '';
    _sshPrivateKey = cfg.getSecret(_kSshPrivateKey) ?? '';

    // Slack
    _slackEnabled = cfg.getBool(_kSlackEnabled) ?? false;
    _slackWebhookUrl = cfg.getSecret(_kSlackWebhookUrl) ?? cfg.getString(_kSlackWebhookUrl) ?? '';
    _slackBotToken = cfg.getSecret(_kSlackBotToken) ?? '';
    _slackDefaultChannel = cfg.getString(_kSlackDefaultChannel) ?? '';

    // Home Assistant
    _haBaseUrl = cfg.getString(_kHaBaseUrl) ?? '';
    _haToken = cfg.getSecret(_kHaToken) ?? '';

    // WhatsApp
    _whatsAppEnabled = cfg.getBool(_kWhatsAppEnabled) ?? false;
    _whatsAppMode = cfg.getString(_kWhatsAppMode) ?? 'meta';
    _whatsAppPhoneNumberId = cfg.getSecret(_kWhatsAppPhoneNumberId) ?? cfg.getString(_kWhatsAppPhoneNumberId) ?? '';
    _whatsAppAccessToken = cfg.getSecret(_kWhatsAppAccessToken) ?? '';
    _whatsAppDefaultRecipient = cfg.getString(_kWhatsAppDefaultRecipient) ?? '';
    _whatsAppCallMeBotApiKey = cfg.getSecret(_kWhatsAppCallMeBotApiKey) ?? '';

    final summary = 'email=${_emailProvider.configKey}, webSearch=${_webSearchProvider.configKey}';
    if (_lastLoadedSummary != summary) {
      _lastLoadedSummary = summary;
      log.debug('[DataSources] Loaded - $summary');
    }
  }

  // ═══════════════════════════════════════════════════
  // Save helpers
  // ═══════════════════════════════════════════════════

  Future<void> saveGmailTokens({
    required String accessToken,
    required String refreshToken,
    required DateTime expiry,
    required String accountEmail,
  }) async {
    _gmailAccessToken = accessToken;
    _gmailRefreshToken = refreshToken;
    _gmailTokenExpiry = expiry;
    _gmailAccountEmail = accountEmail;
    final cfg = ServerConfigService();
    await cfg.setSecret(_kGmailAccessToken, accessToken);
    await cfg.setSecret(_kGmailRefreshToken, refreshToken);
    await cfg.setString(_kGmailTokenExpiry, expiry.toIso8601String());
    await cfg.setString(_kGmailAccountEmail, accountEmail);
  }

  Future<void> setWebSearchApiKey(String key) async {
    _webSearchApiKey = key;
    await ServerConfigService().setSecret(_kWebSearchApiKey, key);
  }

  Future<void> setSshCredentials({
    required String host,
    required int port,
    required String username,
    String password = '',
    String privateKey = '',
  }) async {
    _sshHost = host;
    _sshPort = port;
    _sshUsername = username;
    _sshPassword = password;
    _sshPrivateKey = privateKey;
    final cfg = ServerConfigService();
    await cfg.setString(_kSshHost, host);
    await cfg.setInt(_kSshPort, port);
    await cfg.setSecret(_kSshUsername, username);
    await cfg.setSecret(_kSshPassword, password);
    await cfg.setSecret(_kSshPrivateKey, privateKey);
  }

  Future<void> setSlack({required bool enabled, String webhookUrl = '', String botToken = '', String defaultChannel = ''}) async {
    _slackEnabled = enabled;
    _slackWebhookUrl = webhookUrl;
    _slackBotToken = botToken;
    _slackDefaultChannel = defaultChannel;
    final cfg = ServerConfigService();
    await cfg.setBool(_kSlackEnabled, enabled);
    await cfg.setSecret(_kSlackWebhookUrl, webhookUrl);
    await cfg.setSecret(_kSlackBotToken, botToken);
    await cfg.setString(_kSlackDefaultChannel, defaultChannel);
  }

  Future<void> setHomeAssistant({required String baseUrl, required String token}) async {
    _haBaseUrl = baseUrl;
    _haToken = token;
    final cfg = ServerConfigService();
    await cfg.setString(_kHaBaseUrl, baseUrl);
    await cfg.setSecret(_kHaToken, token);
  }

  Future<void> saveEmail({
    required EmailProvider provider,
    required bool enabled,
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
    _imapHost = imapHost;
    _imapPort = imapPort;
    _imapUsername = imapUsername;
    _imapPassword = imapPassword;
    _imapUseSsl = imapUseSsl;
    _smtpHost = smtpHost;
    _smtpPort = smtpPort;
    _smtpSender = smtpSender;
    _notificationEmailEnabled = notificationEmailEnabled;
    final cfg = ServerConfigService();
    await cfg.setString(_kEmailProvider, provider.configKey);
    await cfg.setBool(_kEmailEnabled, enabled);
    await cfg.setString(_kImapHost, imapHost);
    await cfg.setInt(_kImapPort, imapPort);
    await cfg.setSecret(_kImapUsername, imapUsername);
    await cfg.setSecret(_kImapPassword, imapPassword);
    await cfg.setBool(_kImapUseSsl, imapUseSsl);
    await cfg.setString(_kSmtpHost, smtpHost);
    await cfg.setInt(_kSmtpPort, smtpPort);
    await cfg.setString(_kSmtpSender, smtpSender);
    await cfg.setBool(_kNotificationEmailEnabled, notificationEmailEnabled);
  }

  Future<void> saveWebSearch({
    required WebSearchProvider provider,
    required bool enabled,
    String apiKey = '',
    String engineId = '',
    int maxResults = 5,
    String customProviderName = '',
    String customEndpoint = '',
    double duckDbIndexSizeLimitGb = 1.0,
    int outputRetentionDays = 2,
  }) async {
    _webSearchProvider = provider;
    _webSearchEnabled = enabled;
    _webSearchApiKey = apiKey;
    _webSearchEngineId = engineId;
    _webSearchMaxResults = maxResults;
    _webSearchCustomProviderName = customProviderName;
    _webSearchCustomEndpoint = customEndpoint;
    _duckDbIndexSizeLimitGb = duckDbIndexSizeLimitGb;
    _outputRetentionDays = outputRetentionDays;
    final cfg = ServerConfigService();
    await cfg.setString(_kWebSearchProvider, provider.configKey);
    await cfg.setBool(_kWebSearchEnabled, enabled);
    await cfg.setSecret(_kWebSearchApiKey, apiKey);
    await cfg.setString(_kWebSearchEngineId, engineId);
    await cfg.setInt(_kWebSearchMaxResults, maxResults);
    await cfg.setString(_kWebSearchCustomProviderName, customProviderName);
    await cfg.setString(_kWebSearchCustomEndpoint, customEndpoint);
    await cfg.setDouble(_kDuckDbIndexSizeLimitGb, duckDbIndexSizeLimitGb);
    await cfg.setInt(_kOutputRetentionDays, outputRetentionDays);
  }

  Future<void> saveWebsiteIndex({required String urls, int maxPages = 100, String cron = '', DateTime? lastIndexedAt}) async {
    _websiteIndexUrls = urls;
    _websiteIndexMaxPages = maxPages;
    _websiteIndexCron = cron;
    if (lastIndexedAt != null) _websiteIndexLastIndexedAt = lastIndexedAt;
    final cfg = ServerConfigService();
    await cfg.setString(_kWebsiteIndexUrls, urls);
    await cfg.setInt(_kWebsiteIndexMaxPages, maxPages);
    await cfg.setString(_kWebsiteIndexCron, cron);
    if (lastIndexedAt != null) {
      await cfg.setString(_kWebsiteIndexLastIndexed, lastIndexedAt.toIso8601String());
    }
  }

  Future<void> saveDocumentIndex({
    required String rootPaths,
    String fileTypes = 'pdf,md,docx',
    String cron = '',
    DateTime? lastIndexedAt,
  }) async {
    _documentRootPaths = rootPaths;
    _documentFileTypes = fileTypes;
    _documentIndexCron = cron;
    if (lastIndexedAt != null) _documentIndexLastIndexedAt = lastIndexedAt;
    final cfg = ServerConfigService();
    await cfg.setString(_kDocumentRootPaths, rootPaths);
    await cfg.setString(_kDocumentFileTypes, fileTypes);
    await cfg.setString(_kDocumentIndexCron, cron);
    if (lastIndexedAt != null) {
      await cfg.setString(_kDocumentIndexLastIndexed, lastIndexedAt.toIso8601String());
    }
  }

  Future<void> saveLocation(double? lat, double? lng) async {
    _locationLat = lat;
    _locationLng = lng;
    final cfg = ServerConfigService();
    if (lat != null) {
      await cfg.setDouble(_kLocationLat, lat);
    } else {
      await cfg.setString(_kLocationLat, '');
    }
    if (lng != null) {
      await cfg.setDouble(_kLocationLng, lng);
    } else {
      await cfg.setString(_kLocationLng, '');
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
    _whatsAppPhoneNumberId = phoneNumberId;
    _whatsAppAccessToken = accessToken;
    _whatsAppDefaultRecipient = defaultRecipient;
    _whatsAppCallMeBotApiKey = callMeBotApiKey;
    final cfg = ServerConfigService();
    await cfg.setBool(_kWhatsAppEnabled, enabled);
    await cfg.setString(_kWhatsAppMode, mode);
    await cfg.setSecret(_kWhatsAppPhoneNumberId, phoneNumberId);
    await cfg.setSecret(_kWhatsAppAccessToken, accessToken);
    await cfg.setString(_kWhatsAppDefaultRecipient, defaultRecipient);
    await cfg.setSecret(_kWhatsAppCallMeBotApiKey, callMeBotApiKey);
  }

  Future<void> saveCloudStorage({
    bool googleDriveEnabled = false,
    bool oneDriveEnabled = false,
    String oneDriveClientId = '',
    String oneDriveTenantId = '',
  }) async {
    _googleDriveEnabled = googleDriveEnabled;
    _oneDriveEnabled = oneDriveEnabled;
    _oneDriveClientId = oneDriveClientId;
    _oneDriveTenantId = oneDriveTenantId;
    final cfg = ServerConfigService();
    await cfg.setBool(_kGoogleDriveEnabled, googleDriveEnabled);
    await cfg.setBool(_kOneDriveEnabled, oneDriveEnabled);
    await cfg.setSecret(_kOneDriveClientId, oneDriveClientId);
    await cfg.setString(_kOneDriveTenantId, oneDriveTenantId);
  }
}
