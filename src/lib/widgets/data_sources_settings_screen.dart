// ignore_for_file: use_build_context_synchronously

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../l10n/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';
import '../config/app_theme.dart';
import '../config/oauth_defaults.dart';
import '../services/app_logger.dart';
import '../services/data_sources_settings_service.dart';
import '../services/email_delivery_service.dart';
import '../services/messaging_delivery_service.dart';
import '../services/location_service.dart';
import '../services/server_api_client.dart';
import '../mcp/servers/web_search_mcp_server.dart';
import '../mcp/servers/google_drive_mcp_server.dart';
import '../mcp/servers/website_search_mcp_server.dart';
import '../mcp/servers/document_mcp_server.dart';
import '../services/scheduler_service.dart';
import 'package:path_provider/path_provider.dart';
import 'schedule_picker_dialog.dart';
import '../utils/saf_bridge.dart';

/// Full-screen dialog for configuring global data source credentials.
///
/// All credentials are stored in encrypted secure storage.
/// When [serverClient] is provided, settings are fetched from / saved to the
/// remote server instead of local secure storage.
class DataSourcesSettingsScreen extends StatefulWidget {
  final DataSourcesSettingsService service;

  /// When non-null the screen operates in server mode: loads settings from the
  /// remote server on open and pushes them back on save.
  final ServerApiClient? serverClient;

  const DataSourcesSettingsScreen({super.key, required this.service, this.serverClient});

  /// Open the screen and return `true` when saved.
  static Future<bool?> show(BuildContext context, DataSourcesSettingsService service, {ServerApiClient? serverClient}) {
    return Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => DataSourcesSettingsScreen(service: service, serverClient: serverClient),
      ),
    );
  }

  @override
  State<DataSourcesSettingsScreen> createState() => _DataSourcesSettingsScreenState();
}

class _DataSourcesSettingsScreenState extends State<DataSourcesSettingsScreen> {
  bool _loading = true;
  bool _saving = false;

  /// True when operating in server / remote mode.
  bool get _isRemote => widget.serverClient != null;

  // ── Email ─────────────────────────────────────────
  EmailProvider _emailProvider = EmailProvider.none;
  bool _emailEnabled = false;
  bool _gmailSearchEnabled = false;
  bool _imapSendEnabled = false;
  final _gmailClientIdCtrl = TextEditingController();
  final _gmailClientSecretCtrl = TextEditingController();
  final _gmailAuthCodeCtrl = TextEditingController();
  final _imapHostCtrl = TextEditingController();
  final _imapPortCtrl = TextEditingController(text: '993');
  final _imapUsernameCtrl = TextEditingController();
  final _imapPasswordCtrl = TextEditingController();
  final _smtpHostCtrl = TextEditingController();
  final _smtpPortCtrl = TextEditingController(text: '587');
  final _smtpSenderCtrl = TextEditingController();
  bool _imapUseSsl = true;
  bool _notificationEmailEnabled = false;
  bool _obscureImapPassword = true;
  bool _gmailAuthInProgress = false;
  bool _useManualGoogleOAuthFallback = false;
  final _testEmailRecipientCtrl = TextEditingController();
  final _testEmailSubjectCtrl = TextEditingController(text: 'Test Email from Mobile AI Agent');
  bool _testSendInProgress = false;

  /// Which provider to use for the test email: 'gmail' or 'imap'
  String _testEmailVia = 'gmail';

  // ── Web Search ────────────────────────────────────
  WebSearchProvider _webSearchProvider = WebSearchProvider.duckduckgo;
  bool _webSearchEnabled = false;
  final _webSearchApiKeyCtrl = TextEditingController();
  final _webSearchMaxResultsCtrl = TextEditingController(text: '5');
  final _webSearchCustomProviderCtrl = TextEditingController();
  final _webSearchCustomEndpointCtrl = TextEditingController();
  final _duckDbSizeLimitGbCtrl = TextEditingController(text: '1.0');
  bool _obscureSearchKey = true;
  final _testSearchQueryCtrl = TextEditingController();
  bool _testSearchInProgress = false;

  // ── Website Auto-Index ─────────────────────────────
  List<String> _websiteIndexUrls = [];
  final _websiteIndexUrlCtrl = TextEditingController();
  final _websiteIndexMaxPagesCtrl = TextEditingController(text: '100');
  String _websiteIndexCron = '';

  DateTime? _websiteIndexLastIndexedAt;
  bool _websiteIndexing = false;
  int _websiteIndexed = 0;
  int _websiteIndexTotal = 0;
  WebsiteSearchMcpServer? _activeWebIndexServer;
  Timer? _websiteIndexPollTimer;
  bool _websiteIndexPollRequestInFlight = false;

  // ── Document Index ─────────────────────────────────
  Set<String> _documentRootPaths = {};
  Set<String> _documentFileTypes = {'pdf', 'md', 'docx'};

  static const _kAllDocFileTypes = [
    'pdf',
    'txt',
    'md',
    'doc',
    'docx',
    'xls',
    'xlsx',
    'csv',
    'ppt',
    'pptx',
    'rtf',
    'odt',
    'ods',
    'odp',
    'json',
    'xml',
    'html',
    'htm',
    'yaml',
    'yml',
    'log',
  ];

  /// Paths that are auto-added on Android and cannot be removed by the user.
  String _documentIndexCron = '';

  bool _documentIndexing = false;
  int _documentIndexed = 0;
  int _documentIndexTotal = 0;
  DateTime? _documentIndexLastIndexedAt;
  DocumentMcpServer? _activeDocServer;
  Timer? _documentIndexPollTimer;

  // ── Cloud Storage (independent switches) ─────
  // Set to true to show the OneDrive section in the UI
  static const bool _kShowOneDrive = false;
  bool _googleDriveEnabled = false;
  bool _testDriveInProgress = false;
  bool _oneDriveEnabled = false;
  final _oneDriveClientIdCtrl = TextEditingController();
  final _oneDriveTenantIdCtrl = TextEditingController();

  // ── Location ──────────────────────────────────
  final _latCtrl = TextEditingController();
  final _lngCtrl = TextEditingController();
  bool _locationFetching = false;

  // ── SSH ───────────────────────────────────────
  final _sshHostCtrl = TextEditingController();
  final _sshPortCtrl = TextEditingController(text: '22');
  final _sshUsernameCtrl = TextEditingController();
  final _sshPasswordCtrl = TextEditingController();
  bool _obscureSshPassword = true;
  bool _sshTestInProgress = false;
  String _sshPrivateKeyContent = '';
  String _sshPrivateKeyFileName = '';

  // ── Home Assistant ────────────────────────────
  bool _haEnabled = false;
  final _haBaseUrlCtrl = TextEditingController();
  final _haTokenCtrl = TextEditingController();
  bool _obscureHaToken = true;

  // ── Slack ─────────────────────────────────────
  bool _slackEnabled = false;
  final _slackWebhookUrlCtrl = TextEditingController();
  final _slackBotTokenCtrl = TextEditingController();
  final _slackDefaultChannelCtrl = TextEditingController();
  bool _obscureSlackBotToken = true;
  bool _slackTestInProgress = false;

  // ── WhatsApp ──────────────────────────────────
  bool _whatsAppEnabled = false;
  String _whatsAppMode = 'meta'; // 'meta' | 'callmebot'
  final _whatsAppPhoneNumberIdCtrl = TextEditingController();
  final _whatsAppAccessTokenCtrl = TextEditingController();
  final _whatsAppDefaultRecipientCtrl = TextEditingController();
  final _whatsAppCallMeBotApiKeyCtrl = TextEditingController();
  bool _obscureWaToken = true;
  bool _obscureCallMeBotKey = true;
  bool _whatsAppTestInProgress = false;

  @override
  void initState() {
    super.initState();
    _initFromService();
  }

  Future<void> _initFromService() async {
    final s = widget.service;
    if (!s.isLoaded) await s.load();

    // In server mode, fetch settings from the remote server and overlay them.
    Map<String, dynamic>? remote;
    if (_isRemote) {
      try {
        remote = await widget.serverClient!.getDataSourcesSettings();
      } catch (e) {
        log.warning('[DataSources] Failed to fetch server settings: $e — falling back to local');
      }
    }

    if (!mounted) return;
    setState(() {
      if (remote != null) {
        _loadFromRemote(remote);
      } else {
        _loadFromLocal(s);
      }
      _loading = false;
    });
  }

  void _loadFromRemote(Map<String, dynamic> r) {
    // Email
    final email = r['email'] as Map<String, dynamic>? ?? {};
    _emailProvider = EmailProvider.fromConfigKey(email['provider'] as String? ?? '');
    _emailEnabled = email['enabled'] as bool? ?? false;
    _gmailSearchEnabled = _emailProvider == EmailProvider.gmail && _emailEnabled;
    _imapSendEnabled = (email['imap_host'] as String? ?? '').isNotEmpty;
    _gmailClientIdCtrl.text = email['gmail_client_id'] as String? ?? '';
    _gmailClientSecretCtrl.text = email['gmail_client_secret'] as String? ?? '';
    _imapHostCtrl.text = email['imap_host'] as String? ?? '';
    _imapPortCtrl.text = (email['imap_port'] as int? ?? 993).toString();
    _imapUsernameCtrl.text = email['imap_username'] as String? ?? '';
    _imapPasswordCtrl.text = email['imap_password'] as String? ?? '';
    _imapUseSsl = email['imap_use_ssl'] as bool? ?? true;
    _smtpHostCtrl.text = email['smtp_host'] as String? ?? '';
    _smtpPortCtrl.text = (email['smtp_port'] as int? ?? 587).toString();
    _smtpSenderCtrl.text = email['smtp_sender'] as String? ?? '';
    _notificationEmailEnabled = email['notification_email_enabled'] as bool? ?? false;
    _testEmailRecipientCtrl.text = email['gmail_account_email'] as String? ?? '';
    _testEmailVia = _isRemote ? 'imap' : ((email['has_gmail_tokens'] as bool? ?? false) ? 'gmail' : 'imap');

    // Web search
    final ws = r['web_search'] as Map<String, dynamic>? ?? {};
    _webSearchProvider = WebSearchProvider.fromConfigKey(ws['provider'] as String? ?? '') == WebSearchProvider.none
        ? WebSearchProvider.duckduckgo
        : WebSearchProvider.fromConfigKey(ws['provider'] as String? ?? '');
    _webSearchEnabled = ws['enabled'] as bool? ?? false;
    _webSearchApiKeyCtrl.text = ws['api_key'] as String? ?? '';
    _webSearchMaxResultsCtrl.text = (ws['max_results'] as int? ?? 5).toString();
    _webSearchCustomProviderCtrl.text = ws['custom_provider_name'] as String? ?? '';
    _webSearchCustomEndpointCtrl.text = ws['custom_endpoint'] as String? ?? '';
    final sizeLimit = (ws['duckdb_index_size_limit_gb'] as num?)?.toDouble() ?? 1.0;
    _duckDbSizeLimitGbCtrl.text = sizeLimit.toStringAsFixed(sizeLimit.truncateToDouble() == sizeLimit ? 0 : 1);

    // Website index
    final wi = r['website_index'] as Map<String, dynamic>? ?? {};
    final wiUrls = wi['urls'] as String? ?? '';
    _websiteIndexUrls = wiUrls.isEmpty ? [] : wiUrls.split(',').map((u) => u.trim()).where((u) => u.isNotEmpty).toList();
    _websiteIndexMaxPagesCtrl.text = (wi['max_pages'] as int? ?? 100).toString();
    _websiteIndexCron = wi['cron'] as String? ?? '';
    final wiLast = wi['last_indexed_at'] as String?;
    _websiteIndexLastIndexedAt = wiLast != null ? DateTime.tryParse(wiLast) : null;

    // Document index
    final di = r['document_index'] as Map<String, dynamic>? ?? {};
    final diPaths = di['root_paths'] as String? ?? '';
    _documentRootPaths = diPaths.isEmpty ? {} : diPaths.split(';').map((p) => p.trim()).where((p) => p.isNotEmpty).toSet();
    final diTypes = di['file_types'] as String? ?? 'pdf,md,docx';
    _documentFileTypes = diTypes.isEmpty
        ? {'pdf', 'md', 'docx'}
        : diTypes.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toSet();
    _documentIndexCron = di['cron'] as String? ?? '';
    final diLast = di['last_indexed_at'] as String?;
    _documentIndexLastIndexedAt = diLast != null ? DateTime.tryParse(diLast) : null;

    // Cloud storage
    final cs = r['cloud_storage'] as Map<String, dynamic>? ?? {};
    _googleDriveEnabled = cs['google_drive_enabled'] as bool? ?? false;
    _oneDriveEnabled = cs['one_drive_enabled'] as bool? ?? false;
    _oneDriveClientIdCtrl.text = cs['one_drive_client_id'] as String? ?? '';
    _oneDriveTenantIdCtrl.text = cs['one_drive_tenant_id'] as String? ?? '';

    // Location
    final loc = r['location'] as Map<String, dynamic>? ?? {};
    final lat = (loc['lat'] as num?)?.toDouble();
    final lng = (loc['lng'] as num?)?.toDouble();
    if (lat != null) _latCtrl.text = lat.toStringAsFixed(6);
    if (lng != null) _lngCtrl.text = lng.toStringAsFixed(6);

    // SSH
    final ssh = r['ssh'] as Map<String, dynamic>? ?? {};
    _sshHostCtrl.text = ssh['host'] as String? ?? '';
    _sshPortCtrl.text = (ssh['port'] as int? ?? 22).toString();
    _sshUsernameCtrl.text = ssh['username'] as String? ?? '';
    _sshPasswordCtrl.text = ssh['password'] as String? ?? '';
    _sshPrivateKeyContent = ssh['private_key'] as String? ?? '';
    _sshPrivateKeyFileName = _sshPrivateKeyContent.isNotEmpty ? '(key loaded)' : '';

    // Home Assistant
    final ha = r['home_assistant'] as Map<String, dynamic>? ?? {};
    _haBaseUrlCtrl.text = ha['base_url'] as String? ?? '';
    _haTokenCtrl.text = ha['token'] as String? ?? '';
    _haEnabled = _haBaseUrlCtrl.text.isNotEmpty && _haTokenCtrl.text.isNotEmpty;

    // Slack
    final slack = r['slack'] as Map<String, dynamic>? ?? {};
    _slackEnabled = slack['enabled'] as bool? ?? false;
    _slackWebhookUrlCtrl.text = slack['webhook_url'] as String? ?? '';
    _slackBotTokenCtrl.text = slack['bot_token'] as String? ?? '';
    _slackDefaultChannelCtrl.text = slack['default_channel'] as String? ?? '';

    // WhatsApp
    final wa = r['whatsapp'] as Map<String, dynamic>? ?? {};
    _whatsAppEnabled = wa['enabled'] as bool? ?? false;
    _whatsAppMode = wa['mode'] as String? ?? 'meta';
    _whatsAppPhoneNumberIdCtrl.text = wa['phone_number_id'] as String? ?? '';
    _whatsAppAccessTokenCtrl.text = wa['access_token'] as String? ?? '';
    _whatsAppDefaultRecipientCtrl.text = wa['default_recipient'] as String? ?? '';
    _whatsAppCallMeBotApiKeyCtrl.text = wa['callmebot_api_key'] as String? ?? '';
  }

  void _loadFromLocal(DataSourcesSettingsService s) {
    // Email
    _emailProvider = s.emailProvider;
    _emailEnabled = s.emailEnabled;
    _gmailSearchEnabled = s.emailProvider == EmailProvider.gmail || s.emailProvider == EmailProvider.none ? s.emailEnabled : false;
    _imapSendEnabled = s.imapHost.isNotEmpty;
    _gmailClientIdCtrl.text = s.gmailClientId;
    _gmailClientSecretCtrl.text = s.gmailClientSecret;
    _testEmailRecipientCtrl.text = s.gmailAccountEmail;
    _imapHostCtrl.text = s.imapHost;
    _imapPortCtrl.text = s.imapPort.toString();
    _imapUsernameCtrl.text = s.imapUsername;
    _imapPasswordCtrl.text = s.imapPassword;
    _imapUseSsl = s.imapUseSsl;
    _smtpHostCtrl.text = s.smtpHost;
    _smtpPortCtrl.text = s.smtpPort.toString();
    _smtpSenderCtrl.text = s.smtpSender;
    _notificationEmailEnabled = s.notificationEmailEnabled;
    // Default test-via based on what's configured
    _testEmailVia = s.hasGmailOAuthTokens ? 'gmail' : 'imap';

    // Web Search – dropdown has no "none" item, so fall back to duckduckgo
    _webSearchProvider = s.webSearchProvider == WebSearchProvider.none ? WebSearchProvider.duckduckgo : s.webSearchProvider;
    _webSearchEnabled = s.webSearchEnabled;
    _webSearchApiKeyCtrl.text = s.webSearchApiKey;
    _webSearchMaxResultsCtrl.text = s.webSearchMaxResults.toString();
    _webSearchCustomProviderCtrl.text = s.webSearchCustomProviderName;
    _webSearchCustomEndpointCtrl.text = s.webSearchCustomEndpoint;
    _duckDbSizeLimitGbCtrl.text = s.duckDbIndexSizeLimitGb.toStringAsFixed(
      s.duckDbIndexSizeLimitGb.truncateToDouble() == s.duckDbIndexSizeLimitGb ? 0 : 1,
    );

    // Website Auto-Index
    _websiteIndexUrls = s.websiteIndexUrls.isEmpty
        ? []
        : s.websiteIndexUrls.split(',').map((u) => u.trim()).where((u) => u.isNotEmpty).toList();
    _websiteIndexMaxPagesCtrl.text = s.websiteIndexMaxPages.toString();
    _websiteIndexCron = s.websiteIndexCron;
    _websiteIndexLastIndexedAt = s.websiteIndexLastIndexedAt;

    // Document Index
    _documentRootPaths = s.documentRootPaths.isEmpty
        ? {}
        : s.documentRootPaths.split(';').map((p) => p.trim()).where((p) => p.isNotEmpty).toSet();
    _documentFileTypes = s.documentFileTypes.isEmpty
        ? {'pdf', 'md', 'docx'}
        : s.documentFileTypes.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toSet();
    _documentIndexCron = s.documentIndexCron;
    _documentIndexLastIndexedAt = s.documentIndexLastIndexedAt;

    // Cloud Storage (independent)
    _googleDriveEnabled = s.googleDriveEnabled;
    _oneDriveEnabled = s.oneDriveEnabled;
    _oneDriveClientIdCtrl.text = s.oneDriveClientId;
    _oneDriveTenantIdCtrl.text = s.oneDriveTenantId;

    // Location
    if (s.locationLatitude != null) {
      _latCtrl.text = s.locationLatitude!.toStringAsFixed(6);
    }
    if (s.locationLongitude != null) {
      _lngCtrl.text = s.locationLongitude!.toStringAsFixed(6);
    }

    // SSH
    _sshHostCtrl.text = s.sshHost;
    _sshPortCtrl.text = s.sshPort.toString();
    _sshUsernameCtrl.text = s.sshUsername;
    _sshPasswordCtrl.text = s.sshPassword;
    _sshPrivateKeyContent = s.sshPrivateKey;
    _sshPrivateKeyFileName = s.sshPrivateKey.isNotEmpty ? '(key loaded)' : '';

    // Home Assistant
    _haEnabled = s.isHomeAssistantConfigured;
    _haBaseUrlCtrl.text = s.haBaseUrl;
    _haTokenCtrl.text = s.haToken;

    // Auto-fetch GPS on first open if no location is saved yet
    if (s.locationLatitude == null && s.locationLongitude == null) {
      _autoFetchLocation();
    }

    // Slack
    _slackEnabled = s.slackEnabled;
    _slackWebhookUrlCtrl.text = s.slackWebhookUrl;
    _slackBotTokenCtrl.text = s.slackBotToken;
    _slackDefaultChannelCtrl.text = s.slackDefaultChannel;

    // WhatsApp
    _whatsAppEnabled = s.whatsAppEnabled;
    _whatsAppMode = s.whatsAppMode;
    _whatsAppPhoneNumberIdCtrl.text = s.whatsAppPhoneNumberId;
    _whatsAppAccessTokenCtrl.text = s.whatsAppAccessToken;
    _whatsAppDefaultRecipientCtrl.text = s.whatsAppDefaultRecipient;
    _whatsAppCallMeBotApiKeyCtrl.text = s.whatsAppCallMeBotApiKey;
  }

  /// Silently fetch GPS on first open (no location saved yet).
  /// Updates the lat/lng fields and saves to service without blocking the UI.
  Future<void> _autoFetchLocation() async {
    try {
      final pos = await LocationService().fetchGpsLocation();
      if (pos != null && mounted) {
        setState(() {
          _latCtrl.text = pos.latitude.toStringAsFixed(6);
          _lngCtrl.text = pos.longitude.toStringAsFixed(6);
        });
      }
    } catch (_) {
      // Silent — user can always tap "Refetch GPS Position" manually
    }
  }

  @override
  void dispose() {
    _gmailClientIdCtrl.dispose();
    _gmailClientSecretCtrl.dispose();
    _gmailAuthCodeCtrl.dispose();
    _testEmailRecipientCtrl.dispose();
    _testEmailSubjectCtrl.dispose();
    _imapHostCtrl.dispose();
    _imapPortCtrl.dispose();
    _imapUsernameCtrl.dispose();
    _imapPasswordCtrl.dispose();
    _smtpHostCtrl.dispose();
    _smtpPortCtrl.dispose();
    _smtpSenderCtrl.dispose();
    _webSearchApiKeyCtrl.dispose();
    _webSearchMaxResultsCtrl.dispose();
    _webSearchCustomProviderCtrl.dispose();
    _webSearchCustomEndpointCtrl.dispose();
    _duckDbSizeLimitGbCtrl.dispose();
    _testSearchQueryCtrl.dispose();
    _websiteIndexUrlCtrl.dispose();
    _websiteIndexMaxPagesCtrl.dispose();
    _websiteIndexPollTimer?.cancel();
    _documentIndexPollTimer?.cancel();
    _oneDriveClientIdCtrl.dispose();
    _oneDriveTenantIdCtrl.dispose();
    _latCtrl.dispose();
    _lngCtrl.dispose();
    _sshHostCtrl.dispose();
    _sshPortCtrl.dispose();
    _sshUsernameCtrl.dispose();
    _sshPasswordCtrl.dispose();
    _slackWebhookUrlCtrl.dispose();
    _slackBotTokenCtrl.dispose();
    _slackDefaultChannelCtrl.dispose();
    _whatsAppPhoneNumberIdCtrl.dispose();
    _whatsAppAccessTokenCtrl.dispose();
    _whatsAppDefaultRecipientCtrl.dispose();
    _whatsAppCallMeBotApiKeyCtrl.dispose();
    _haBaseUrlCtrl.dispose();
    _haTokenCtrl.dispose();
    super.dispose();
  }

  Future<void> _openGoogleAuthorization() async {
    final l = L.of(context);
    final clientId = _gmailClientIdCtrl.text.trim();
    if ((!_usesNativeGoogleSignInPlatform || _useManualGoogleOAuthFallback) && clientId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.oauthClientId), backgroundColor: AppTheme.error));
      return;
    }

    if (_usesNativeGoogleSignInPlatform && !_useManualGoogleOAuthFallback) {
      setState(() => _gmailAuthInProgress = true);
      try {
        await widget.service.saveEmail(
          provider: _emailProvider,
          enabled: _emailEnabled,
          gmailClientId: _gmailClientIdCtrl.text,
          gmailClientSecret: _gmailClientSecretCtrl.text,
          imapHost: _imapHostCtrl.text,
          imapPort: int.tryParse(_imapPortCtrl.text) ?? 993,
          imapUsername: _imapUsernameCtrl.text,
          imapPassword: _imapPasswordCtrl.text,
          imapUseSsl: _imapUseSsl,
          smtpHost: _smtpHostCtrl.text,
          smtpPort: int.tryParse(_smtpPortCtrl.text) ?? 587,
          smtpSender: _smtpSenderCtrl.text,
          notificationEmailEnabled: _notificationEmailEnabled,
        );

        final googleSignIn = GoogleSignIn.instance;
        final manualClientId = _gmailClientIdCtrl.text.trim().isNotEmpty ? _gmailClientIdCtrl.text.trim() : null;
        final iosClientId = OAuthDefaults.googleIosClientId.trim().isNotEmpty ? OAuthDefaults.googleIosClientId.trim() : null;
        final webClientId = OAuthDefaults.googleWebClientId.trim().isNotEmpty ? OAuthDefaults.googleWebClientId.trim() : null;
        final isIOS = defaultTargetPlatform == TargetPlatform.iOS;
        final isAndroid = defaultTargetPlatform == TargetPlatform.android;
        await googleSignIn.initialize(
          clientId: isAndroid ? null : (isIOS ? iosClientId : manualClientId),
          serverClientId: isAndroid ? (webClientId ?? manualClientId) : null,
        );

        await googleSignIn.signOut();
        final account = await googleSignIn.authenticate(scopeHint: DataSourcesSettingsService.gmailOAuthScopes);

        final authz = await account.authorizationClient.authorizeScopes(DataSourcesSettingsService.gmailOAuthScopes);
        final accessToken = authz.accessToken.trim();
        if (accessToken.isEmpty) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l.oauthExchangeFailed('Google sign-in returned no access token.')), backgroundColor: AppTheme.error),
          );
          return;
        }

        await widget.service.saveGmailOAuthTokens(
          accessToken: accessToken,
          refreshToken: '',
          expiresAt: DateTime.now().add(const Duration(minutes: 50)),
          accountEmail: account.email,
        );

        if (!mounted) return;
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.oauthExchangeSuccess)));
      } catch (e) {
        if (!mounted) return;
        final lower = e.toString().toLowerCase();
        final shouldFallbackToManual = defaultTargetPlatform == TargetPlatform.iOS && lower.contains('client_secret is missing');

        if (shouldFallbackToManual) {
          setState(() => _useManualGoogleOAuthFallback = true);
          await _openManualGoogleAuthorization(clientId: clientId);
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('iOS native Google auth failed for this client. Switched to manual OAuth fallback.'),
              behavior: SnackBarBehavior.floating,
              duration: Duration(seconds: 8),
            ),
          );
          return;
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l.oauthExchangeFailed(e.toString())),
            backgroundColor: AppTheme.error,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 10),
          ),
        );
      } finally {
        if (mounted) setState(() => _gmailAuthInProgress = false);
      }
      return;
    }

    await _openManualGoogleAuthorization(clientId: clientId);
  }

  Future<void> _openManualGoogleAuthorization({required String clientId}) async {
    final l = L.of(context);
    final uri = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
      'client_id': clientId,
      'redirect_uri': 'http://localhost/',
      'response_type': 'code',
      'scope':
          'https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/gmail.send https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/drive.file https://www.googleapis.com/auth/calendar',
      'access_type': 'offline',
      'prompt': 'consent',
    });

    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!mounted) return;
    if (!opened) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.oauthOpenFailed), backgroundColor: AppTheme.error));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.oauthOpenSuccess)));
    }
  }

  bool get _usesNativeGoogleSignInPlatform =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  /// Sync the legacy _emailProvider field based on the new switches.
  /// Gmail takes priority for backwards compatibility with the service layer.
  void _updateEmailProvider() {
    if (_gmailSearchEnabled) {
      _emailProvider = EmailProvider.gmail;
    } else if (_imapSendEnabled) {
      _emailProvider = EmailProvider.imap;
    } else {
      _emailProvider = EmailProvider.none;
    }
  }

  Future<void> _exchangeAuthorizationCode() async {
    final l = L.of(context);
    final code = _gmailAuthCodeCtrl.text.trim();
    if (code.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.oauthCodeRequired), backgroundColor: AppTheme.error));
      return;
    }

    setState(() => _gmailAuthInProgress = true);
    try {
      await widget.service.saveEmail(
        provider: _emailProvider,
        enabled: _emailEnabled,
        gmailClientId: _gmailClientIdCtrl.text,
        gmailClientSecret: _gmailClientSecretCtrl.text,
        imapHost: _imapHostCtrl.text,
        imapPort: int.tryParse(_imapPortCtrl.text) ?? 993,
        imapUsername: _imapUsernameCtrl.text,
        imapPassword: _imapPasswordCtrl.text,
        imapUseSsl: _imapUseSsl,
        smtpHost: _smtpHostCtrl.text,
        smtpPort: int.tryParse(_smtpPortCtrl.text) ?? 587,
        smtpSender: _smtpSenderCtrl.text,
        notificationEmailEnabled: _notificationEmailEnabled,
      );

      final result = await widget.service.exchangeGmailAuthorizationCode(authorizationCode: code);
      if (!mounted) return;
      if (result['success'] == true) {
        _gmailAuthCodeCtrl.clear();
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.oauthExchangeSuccess)));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l.oauthExchangeFailed(result['error']?.toString() ?? 'unknown')),
            backgroundColor: AppTheme.error,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 10),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _gmailAuthInProgress = false);
    }
  }

  Future<void> _clearGmailTokens() async {
    await widget.service.clearGmailOAuthTokens();
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _sendTestEmail() async {
    final l = L.of(context);
    final recipient = _testEmailRecipientCtrl.text.trim();
    if (recipient.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.testEmailRecipientRequired), backgroundColor: AppTheme.error));
      return;
    }

    setState(() => _testSendInProgress = true);
    try {
      await widget.service.saveEmail(
        provider: _emailProvider,
        enabled: _emailEnabled,
        gmailClientId: _gmailClientIdCtrl.text,
        gmailClientSecret: _gmailClientSecretCtrl.text,
        imapHost: _imapHostCtrl.text,
        imapPort: int.tryParse(_imapPortCtrl.text) ?? 993,
        imapUsername: _imapUsernameCtrl.text,
        imapPassword: _imapPasswordCtrl.text,
        imapUseSsl: _imapUseSsl,
        smtpHost: _smtpHostCtrl.text,
        smtpPort: int.tryParse(_smtpPortCtrl.text) ?? 587,
        smtpSender: _smtpSenderCtrl.text,
        notificationEmailEnabled: _notificationEmailEnabled,
      );

      final result = await EmailDeliveryService().sendTestEmail(
        recipient: recipient,
        subject: _testEmailSubjectCtrl.text.trim(),
        via: _testEmailVia,
      );

      if (!mounted) return;
      final ok = result.sent;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ok ? l.testEmailSent : l.testEmailFailed(result.message ?? 'unknown')),
          backgroundColor: ok ? AppTheme.success : AppTheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _testSendInProgress = false);
    }
  }

  // ═══════════════════════════════════════════════════
  // Test Web Search
  // ═══════════════════════════════════════════════════

  Future<void> _testWebSearch() async {
    final l = L.of(context);
    final query = _testSearchQueryCtrl.text.trim();
    if (query.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.testSearchQueryHint), backgroundColor: AppTheme.warning));
      return;
    }

    setState(() => _testSearchInProgress = true);

    try {
      // Save current settings first
      await widget.service.saveWebSearch(
        provider: _webSearchProvider,
        enabled: _webSearchEnabled,
        apiKey: _webSearchApiKeyCtrl.text,
        engineId: '',
        maxResults: int.tryParse(_webSearchMaxResultsCtrl.text) ?? 5,
        customProviderName: _webSearchCustomProviderCtrl.text,
        customEndpoint: _webSearchCustomEndpointCtrl.text,
      );

      final providerKey = switch (_webSearchProvider) {
        WebSearchProvider.serpapi => 'serpapi',
        WebSearchProvider.serper => 'serper',
        WebSearchProvider.custom => 'custom',
        _ => 'duckduckgo',
      };
      final server = WebSearchMcpServer();
      await server.initialize({'provider': providerKey, 'maxResults': int.tryParse(_webSearchMaxResultsCtrl.text) ?? 5});

      final result = await server.executeTool('web_search', {'query': query, 'maxResults': 3});

      if (!mounted) return;
      final error = result['error'] as String?;
      if (error != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.testSearchFailed(error)), backgroundColor: AppTheme.error));
      } else {
        final count = result['returned'] as int? ?? 0;
        final provider = result['providerUsed'] as String? ?? '?';
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.testSearchSuccess(count, provider)), backgroundColor: AppTheme.success));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.testSearchFailed(e.toString())), backgroundColor: AppTheme.error));
      }
    } finally {
      if (mounted) setState(() => _testSearchInProgress = false);
    }
  }

  // ═══════════════════════════════════════════════════
  // Test Google Drive Connection
  // ═══════════════════════════════════════════════════

  Future<void> _testGoogleDrive() async {
    final l = L.of(context);
    setState(() => _testDriveInProgress = true);

    // Auto-save current settings so the service reflects the latest UI state
    // before running the test (avoids "not configured" error on first test).
    await _save(pop: false);

    try {
      final server = GoogleDriveMcpServer();
      await server.initialize({'folderPath': '', 'fileTypes': 'txt,md,docx,xlsx,pdf,csv'});

      final result = await server.executeTool('list_drive_folder', {'folderPath': '', 'maxResults': 10});

      if (!mounted) return;
      final error = result['error'] as String?;
      if (error != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.testDriveFailed(error)), backgroundColor: AppTheme.error));
      } else {
        final files = result['files'] as List<dynamic>? ?? [];
        // Show a dialog listing the files/folders
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(l.testDriveSuccess(files.length)), backgroundColor: AppTheme.success));
          if (files.isNotEmpty) {
            _showDriveFilesDialog(files);
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.testDriveFailed(e.toString())), backgroundColor: AppTheme.error));
      }
    } finally {
      if (mounted) setState(() => _testDriveInProgress = false);
    }
  }

  void _showDriveFilesDialog(List<dynamic> files) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Google Drive – Root'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: files.length,
            itemBuilder: (_, i) {
              final f = files[i] as Map<String, dynamic>;
              final isFolder = f['isFolder'] == true;
              return ListTile(
                leading: Icon(isFolder ? Icons.folder : Icons.insert_drive_file, color: isFolder ? AppTheme.warning : AppTheme.primaryBlue),
                title: Text(f['name']?.toString() ?? '?', maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(f['mimeType']?.toString() ?? '', style: const TextStyle(fontSize: 11)),
                dense: true,
              );
            },
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  // Save
  // ═══════════════════════════════════════════════════

  Future<void> _save({bool pop = true}) async {
    setState(() => _saving = true);
    // Derive email enabled/provider from sub-toggles
    _emailEnabled = _gmailSearchEnabled || _imapSendEnabled;
    _updateEmailProvider();
    final l = L.of(context);
    try {
      final lat = double.tryParse(_latCtrl.text.trim());
      final lng = double.tryParse(_lngCtrl.text.trim());
      final duckDbLimit = (double.tryParse(_duckDbSizeLimitGbCtrl.text.trim()) ?? 1.0).clamp(0.1, 50.0);

      if (_isRemote) {
        // ── Server mode: push all settings via REST ───────────────────────────
        await widget.serverClient!.putDataSourcesSettings({
          'email': {
            'provider': _emailProvider.configKey,
            'enabled': _emailEnabled,
            'gmail_client_id': _gmailClientIdCtrl.text,
            'gmail_client_secret': _gmailClientSecretCtrl.text,
            'imap_host': _imapHostCtrl.text,
            'imap_port': int.tryParse(_imapPortCtrl.text) ?? 993,
            'imap_username': _imapUsernameCtrl.text,
            'imap_password': _imapPasswordCtrl.text,
            'imap_use_ssl': _imapUseSsl,
            'smtp_host': _smtpHostCtrl.text,
            'smtp_port': int.tryParse(_smtpPortCtrl.text) ?? 587,
            'smtp_sender': _smtpSenderCtrl.text,
            'notification_email_enabled': _notificationEmailEnabled,
          },
          'web_search': {
            'provider': _webSearchProvider.configKey,
            'enabled': _webSearchEnabled,
            'api_key': _webSearchApiKeyCtrl.text,
            'engine_id': '',
            'max_results': int.tryParse(_webSearchMaxResultsCtrl.text) ?? 5,
            'custom_provider_name': _webSearchCustomProviderCtrl.text,
            'custom_endpoint': _webSearchCustomEndpointCtrl.text,
            'duckdb_index_size_limit_gb': duckDbLimit,
            'output_retention_days': widget.service.outputRetentionDays,
          },
          'website_index': {
            'urls': _websiteIndexUrls.join(', '),
            'max_pages': (int.tryParse(_websiteIndexMaxPagesCtrl.text.trim()) ?? 100).clamp(1, 1000),
            'cron': _websiteIndexCron,
          },
          'document_index': {
            'root_paths': _documentRootPaths.join(';'),
            'file_types': _documentFileTypes.join(','),
            'cron': _documentIndexCron,
          },
          'cloud_storage': {
            'google_drive_enabled': _googleDriveEnabled,
            'one_drive_enabled': _oneDriveEnabled,
            'one_drive_client_id': _oneDriveClientIdCtrl.text,
            'one_drive_tenant_id': _oneDriveTenantIdCtrl.text,
          },
          'location': {'lat': (lat != null && lng != null) ? lat : null, 'lng': (lat != null && lng != null) ? lng : null},
          'ssh': {
            'host': _sshHostCtrl.text,
            'port': int.tryParse(_sshPortCtrl.text) ?? 22,
            'username': _sshUsernameCtrl.text,
            'password': _sshPasswordCtrl.text,
            'private_key': _sshPrivateKeyContent,
          },
          'slack': {
            'enabled': _slackEnabled,
            'webhook_url': _slackWebhookUrlCtrl.text,
            'bot_token': _slackBotTokenCtrl.text,
            'default_channel': _slackDefaultChannelCtrl.text,
          },
          'home_assistant': {'base_url': _haBaseUrlCtrl.text, 'token': _haTokenCtrl.text},
          'whatsapp': {
            'enabled': _whatsAppEnabled,
            'mode': _whatsAppMode,
            'phone_number_id': _whatsAppPhoneNumberIdCtrl.text,
            'access_token': _whatsAppAccessTokenCtrl.text,
            'default_recipient': _whatsAppDefaultRecipientCtrl.text,
            'callmebot_api_key': _whatsAppCallMeBotApiKeyCtrl.text,
          },
        });
      } else {
        // ── Local mode: save to secure storage ────────────────────────────────
        await widget.service.saveEmail(
          provider: _emailProvider,
          enabled: _emailEnabled,
          gmailClientId: _gmailClientIdCtrl.text,
          gmailClientSecret: _gmailClientSecretCtrl.text,
          imapHost: _imapHostCtrl.text,
          imapPort: int.tryParse(_imapPortCtrl.text) ?? 993,
          imapUsername: _imapUsernameCtrl.text,
          imapPassword: _imapPasswordCtrl.text,
          imapUseSsl: _imapUseSsl,
          smtpHost: _smtpHostCtrl.text,
          smtpPort: int.tryParse(_smtpPortCtrl.text) ?? 587,
          smtpSender: _smtpSenderCtrl.text,
          notificationEmailEnabled: _notificationEmailEnabled,
        );
        await widget.service.saveWebSearch(
          provider: _webSearchProvider,
          enabled: _webSearchEnabled,
          apiKey: _webSearchApiKeyCtrl.text,
          engineId: '',
          maxResults: int.tryParse(_webSearchMaxResultsCtrl.text) ?? 5,
          customProviderName: _webSearchCustomProviderCtrl.text,
          customEndpoint: _webSearchCustomEndpointCtrl.text,
        );

        await widget.service.saveCloudStorage(
          googleDriveEnabled: _googleDriveEnabled,
          oneDriveEnabled: _oneDriveEnabled,
          oneDriveClientId: _oneDriveClientIdCtrl.text,
          oneDriveTenantId: _oneDriveTenantIdCtrl.text,
        );
        await widget.service.saveDuckDbSettings(indexSizeLimitGb: duckDbLimit);

        await widget.service.saveWebsiteIndex(
          urls: _websiteIndexUrls.join(', '),
          maxPages: (int.tryParse(_websiteIndexMaxPagesCtrl.text.trim()) ?? 100).clamp(1, 1000),
          cron: _websiteIndexCron,
        );
        scheduleWebsiteIndexAlarm(_websiteIndexCron);

        // Save manual lat/lng if both are filled
        if (lat != null && lng != null) {
          await widget.service.saveLocation(lat, lng);
        } else if (_latCtrl.text.trim().isEmpty && _lngCtrl.text.trim().isEmpty) {
          await widget.service.clearLocation();
        }

        await widget.service.saveSsh(
          host: _sshHostCtrl.text,
          port: int.tryParse(_sshPortCtrl.text) ?? 22,
          username: _sshUsernameCtrl.text,
          password: _sshPasswordCtrl.text,
          privateKey: _sshPrivateKeyContent,
        );

        await widget.service.saveSlack(
          enabled: _slackEnabled,
          webhookUrl: _slackWebhookUrlCtrl.text,
          botToken: _slackBotTokenCtrl.text,
          defaultChannel: _slackDefaultChannelCtrl.text,
        );

        await widget.service.saveWhatsApp(
          enabled: _whatsAppEnabled,
          phoneNumberId: _whatsAppPhoneNumberIdCtrl.text,
          accessToken: _whatsAppAccessTokenCtrl.text,
          defaultRecipient: _whatsAppDefaultRecipientCtrl.text,
        );

        await widget.service.saveHomeAssistant(baseUrl: _haBaseUrlCtrl.text, token: _haTokenCtrl.text);
      }

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.dataSourcesSettingsSaved), behavior: SnackBarBehavior.floating));
        if (pop) Navigator.of(context).pop(true);
      }
    } catch (e) {
      log.error('[DataSources] save error: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.dataSourcesSettingsSaveFailed(e.toString())), backgroundColor: AppTheme.error));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ═══════════════════════════════════════════════════
  // Document Index
  // ═══════════════════════════════════════════════════

  Future<void> _openDocumentIndexSchedulePicker() async {
    String? determinedCategory;
    final cron = _documentIndexCron.trim();
    if (cron.isNotEmpty) {
      final parts = cron.split(RegExp(r'\s+'));
      if (parts.length == 5) {
        final hour = parts[1];
        final day = parts[2];
        final month = parts[3];
        final weekday = parts[4];
        if (month != '*' || day != '*' || weekday != '*') {
          determinedCategory = day != '*' && month == '*' && weekday == '*'
              ? 'monthly'
              : weekday != '*'
              ? 'weekly'
              : 'daily';
        } else if (hour == '*' || hour.contains('/')) {
          determinedCategory = 'hourly';
        } else {
          determinedCategory = 'daily';
        }
      }
    }
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => SchedulePickerDialog(initialCron: _documentIndexCron, initialCategory: determinedCategory, allowSubHourly: false),
    );
    if (result != null && mounted) {
      setState(() {
        _documentIndexCron = result['cron'] ?? '';

      });
      await widget.service.saveDocumentIndex(rootPaths: _documentRootPaths.join(';'), cron: _documentIndexCron);
      scheduleDocumentIndexAlarm(_documentIndexCron);
    }
  }

  Future<void> _docBrowseFolder() async {
    if (_isRemote) {
      await _docAddServerPath();
      return;
    }
    String? picked;
    if (Platform.isAndroid) {
      // Use the native ACTION_OPEN_DOCUMENT_TREE picker which returns a real
      // content:// URI and takes the persistable permission automatically.
      try {
        picked = await SafBridge.openDocumentTree();
      } catch (e) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not open folder picker: $e'), behavior: SnackBarBehavior.floating));
        return;
      }
    } else {
      picked = await FilePicker.getDirectoryPath();
    }
    if (picked == null || !mounted) return;
    final updated = {..._documentRootPaths, picked};
    setState(() => _documentRootPaths = updated);
    await widget.service.saveDocumentIndex(rootPaths: updated.join(';'), fileTypes: _documentFileTypes.join(','), cron: _documentIndexCron);
  }

  Future<void> _docAddServerPath() async {
    final controller = TextEditingController();
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Folder or File'),
        content: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (_) {
            final v = controller.text.trim();
            FocusScope.of(ctx).unfocus();
            if (Navigator.of(ctx).canPop()) {
              Navigator.of(ctx).pop(v.isNotEmpty ? v : null);
            }
          },
          decoration: const InputDecoration(
            hintText: '/home/user/documents',
            labelText: 'Absolute path on server',
            helperText: 'Shown as folder name only',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              final v = controller.text.trim();
              FocusScope.of(ctx).unfocus();
              if (Navigator.of(ctx).canPop()) {
                Navigator.of(ctx).pop(v.isNotEmpty ? v : null);
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    final normalized = picked.trim().replaceAll(RegExp(r'/+\$'), '');
    if (!normalized.startsWith('/')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Server mode requires an absolute path, e.g. /home/tealkit/upload/doc'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    final updated = {..._documentRootPaths, normalized};
    setState(() => _documentRootPaths = updated);
    await widget.service.saveDocumentIndex(rootPaths: updated.join(';'), fileTypes: _documentFileTypes.join(','), cron: _documentIndexCron);
  }

  /// Opens the folder picker pre-navigated to a well-known Android folder.
  /// [safRelPath] — SAF-relative path like 'primary:Documents'.
  Future<void> _docBrowseKnownFolder(String safRelPath) async {
    const authority = 'com.android.externalstorage.documents';
    final initialUri = 'content://$authority/document/${Uri.encodeComponent(safRelPath)}';
    String? picked;
    try {
      picked = await SafBridge.openDocumentTree(initialUri: initialUri);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not open folder picker: $e'), behavior: SnackBarBehavior.floating));
      return;
    }
    if (picked == null || !mounted) {
      // Android blocks the Downloads root — suggest using Pick Files instead.
      if (safRelPath.startsWith('primary:Download') && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Android blocks selecting the Downloads root folder directly. '
              'Use "Pick Files" to choose individual files from Downloads.',
            ),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 5),
          ),
        );
      }
      return;
    }
    final updated = {..._documentRootPaths, picked};
    setState(() => _documentRootPaths = updated);
    await widget.service.saveDocumentIndex(rootPaths: updated.join(';'), fileTypes: _documentFileTypes.join(','), cron: _documentIndexCron);
  }

  /// Returns a human-readable label for a folder path or SAF URI.
  static String _folderLabel(String path) {
    if (SafBridge.isSafUri(path)) return SafBridge.labelFromUri(path);
    return path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).lastOrNull ?? path;
  }

  Future<void> _docPickFiles() async {
    // Use the user's selected file types; fall back to a broad default.
    final extensions = _documentFileTypes.isNotEmpty ? _documentFileTypes.toList() : ['pdf', 'md', 'docx'];
    final result = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: extensions,
      withData: false, // load via path to avoid OOM with large/many files
    );
    if (result == null || result.files.isEmpty || !mounted) return;
    final appDir = await getApplicationSupportDirectory();
    final destDir = Directory('${appDir.path}/tealkit_indexed_files');
    await destDir.create(recursive: true);
    final int allowedPicks = 100;
    final filesToCopy = result.files.take(allowedPicks).toList();

    for (final f in filesToCopy) {
      final name = f.name;
      if (f.path != null) {
        await File(f.path!).copy('${destDir.path}/$name');
      }
    }
    if (!mounted) return;
    final updated = {..._documentRootPaths, destDir.path};
    setState(() => _documentRootPaths = updated);
    await widget.service.saveDocumentIndex(rootPaths: updated.join(';'), fileTypes: _documentFileTypes.join(','), cron: _documentIndexCron);
  }

  Future<void> _doDocumentIndex() async {
    if (_documentRootPaths.isEmpty) return;
    final rootPaths = _isRemote ? _documentRootPaths.map((p) => p.trim()).where((p) => p.startsWith('/')).toSet() : _documentRootPaths;
    if (_isRemote && rootPaths.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No valid absolute server paths configured. Use /home/...'), behavior: SnackBarBehavior.floating),
      );
      return;
    }
    final rootPath = rootPaths.join(';');
    final fileTypesStr = _documentFileTypes.isNotEmpty ? _documentFileTypes.join(',') : 'pdf,md,docx';

    // ── Server mode: delegate indexing to the remote server ──────────────────
    if (_isRemote) {
      setState(() {
        _documentIndexing = true;
        _documentIndexed = 0;
        _documentIndexTotal = 0;
      });
      try {
        await widget.serverClient!.startDocumentIndex(rootPaths: rootPath, fileTypes: fileTypesStr);
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to start server indexing: $e'),
            backgroundColor: AppTheme.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
        setState(() => _documentIndexing = false);
        return;
      }

      // Poll the server every 2 s until done.
      _documentIndexPollTimer?.cancel();
      _documentIndexPollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
        try {
          final status = await widget.serverClient!.getDocumentIndexStatus();
          final running = status['running'] as bool? ?? false;
          final indexed = status['indexed'] as int? ?? 0;
          final total = status['total'] as int? ?? 0;
          if (mounted) {
            setState(() {
              _documentIndexed = indexed;
              _documentIndexTotal = total;
            });
          }
          if (!running) {
            _documentIndexPollTimer?.cancel();
            _documentIndexPollTimer = null;
            final result = status['lastResult'] as Map<String, dynamic>? ?? {};
            if (!mounted) return;
            setState(() {
              _documentIndexing = false;
              _documentIndexed = 0;
              _documentIndexTotal = 0;
            });
            if (result.containsKey('error')) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Server indexing failed: ${result['error']}'),
                  backgroundColor: AppTheme.error,
                  behavior: SnackBarBehavior.floating,
                ),
              );
            } else {
              final count = result['documentsIndexed'] as int? ?? indexed;
              final cancelled = result['cancelled'] as bool? ?? false;
              final now = DateTime.now();
              await widget.service.saveDocumentIndex(
                rootPaths: rootPath,
                fileTypes: fileTypesStr,
                cron: _documentIndexCron,
                lastIndexedAt: now,
              );
              setState(() => _documentIndexLastIndexedAt = now);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    cancelled
                        ? 'Server indexing cancelled ($count documents indexed)'
                        : 'Server indexed $count document${count == 1 ? '' : 's'} into server DuckDB',
                  ),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            }
          }
        } catch (e) {
          _documentIndexPollTimer?.cancel();
          _documentIndexPollTimer = null;
          if (mounted) {
            setState(() {
              _documentIndexing = false;
              _documentIndexed = 0;
              _documentIndexTotal = 0;
            });
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Polling error: $e'), backgroundColor: AppTheme.error, behavior: SnackBarBehavior.floating),
            );
          }
        }
      });
      return;
    }

    // ── Local mode: run indexing in-process ───────────────────────────────────
    final server = DocumentMcpServer();
    server.onIndexProgress = (indexed, total, currentFile) {
      if (mounted) {
        setState(() {
          _documentIndexed = indexed;
          _documentIndexTotal = total;
        });
      }
    };
    _activeDocServer = server;
    setState(() {
      _documentIndexing = true;
      _documentIndexed = 0;
      _documentIndexTotal = 0;
    });
    try {
      await server.initialize({'rootPath': rootPath, 'fileTypes': fileTypesStr, 'indexingStrategy': 'before_first_run'});
      final result = await server.executeTool('reindex', {});
      await server.dispose();
      _activeDocServer = null;
      if (!mounted) return;
      if (result.containsKey('error')) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Indexing failed: ${result['error']}'),
            backgroundColor: AppTheme.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else {
        final count = result['documentsIndexed'] as int? ?? 0;
        final now = DateTime.now();
        await widget.service.saveDocumentIndex(rootPaths: rootPath, fileTypes: fileTypesStr, cron: _documentIndexCron, lastIndexedAt: now);
        setState(() => _documentIndexLastIndexedAt = now);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Indexed $count document${count == 1 ? '' : 's'} successfully.'), behavior: SnackBarBehavior.floating),
        );
      }
    } catch (e) {
      _activeDocServer = null;
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Indexing error: $e'), backgroundColor: AppTheme.error, behavior: SnackBarBehavior.floating));
    } finally {
      if (mounted) {
        setState(() {
          _documentIndexing = false;
          _documentIndexed = 0;
          _documentIndexTotal = 0;
        });
      }
    }
  }

  // ═══════════════════════════════════════════════════
  // Website Auto-Index
  // ═══════════════════════════════════════════════════

  static const int _kMaxWebsiteIndexUrlsPro = 10;

  int get _maxWebsiteIndexUrls => _kMaxWebsiteIndexUrlsPro;

  Future<void> _addWebsiteIndexUrl() async {
    final raw = _websiteIndexUrlCtrl.text.trim();
    if (raw.isEmpty) return;
    final url = raw.contains('://') ? raw : 'https://$raw';
    try {
      final uri = Uri.parse(url);
      if (!uri.hasAuthority) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Invalid URL'), behavior: SnackBarBehavior.floating));
        return;
      }
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Invalid URL'), behavior: SnackBarBehavior.floating));
      return;
    }
    if (_websiteIndexUrls.contains(url)) return;
    if (_websiteIndexUrls.length >= _maxWebsiteIndexUrls) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Maximum $_kMaxWebsiteIndexUrlsPro URLs allowed'), behavior: SnackBarBehavior.floating));
      return;
    }
    setState(() {
      _websiteIndexUrls.add(url);
      _websiteIndexUrlCtrl.clear();
    });
  }

  String _formatLastIndexed(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  Future<void> _doWebsiteIndex() async {
    if (_websiteIndexUrls.isEmpty) return;
    final urlStr = _websiteIndexUrls.join(', ');
    final maxPages = (int.tryParse(_websiteIndexMaxPagesCtrl.text.trim()) ?? 100).clamp(1, 1000);

    // ── Server mode: delegate indexing to the remote server ──────────────────
    if (_isRemote) {
      setState(() {
        _websiteIndexing = true;
        _websiteIndexed = 0;
        _websiteIndexTotal = 0;
      });
      try {
        await widget.serverClient!.startWebsiteIndex(urls: urlStr, maxPages: maxPages);
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to start server indexing: $e'),
            backgroundColor: AppTheme.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
        setState(() => _websiteIndexing = false);
        return;
      }

      // Poll the server every 2 s until done.
      _websiteIndexPollTimer?.cancel();
      _websiteIndexPollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
        if (_websiteIndexPollRequestInFlight) return;
        _websiteIndexPollRequestInFlight = true;
        try {
          final status = await widget.serverClient!.getWebsiteIndexStatus(timeout: const Duration(minutes: 5));
          final running = status['running'] as bool? ?? false;
          final indexed = status['indexed'] as int? ?? 0;
          final total = status['total'] as int? ?? 0;
          if (mounted) {
            setState(() {
              _websiteIndexed = indexed;
              _websiteIndexTotal = total;
            });
          }
          if (!running) {
            _websiteIndexPollTimer?.cancel();
            _websiteIndexPollTimer = null;
            final result = status['lastResult'] as Map<String, dynamic>? ?? {};
            if (!mounted) return;
            setState(() {
              _websiteIndexing = false;
              _websiteIndexed = 0;
              _websiteIndexTotal = 0;
            });
            if (result.containsKey('error')) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Server indexing failed: ${result['error']}'),
                  backgroundColor: AppTheme.error,
                  behavior: SnackBarBehavior.floating,
                ),
              );
            } else {
              final count = result['indexedPages'] as int? ?? indexed;
              final cancelled = result['cancelled'] as bool? ?? false;
              final now = DateTime.now();
              await widget.service.saveWebsiteIndex(urls: urlStr, maxPages: maxPages, cron: _websiteIndexCron, lastIndexedAt: now);
              scheduleWebsiteIndexAlarm(_websiteIndexCron);
              setState(() => _websiteIndexLastIndexedAt = now);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    cancelled
                        ? 'Server indexing cancelled ($count pages indexed)'
                        : 'Server indexed $count page${count == 1 ? '' : 's'} into server DuckDB',
                  ),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            }
          }
        } on TimeoutException {
          // Keep polling. The server continues indexing in the background and a
          // slow status response should not surface as a hard failure.
          log.warning('[DataSources] Website index status poll timed out; continuing to wait for server-side indexing');
        } catch (e) {
          _websiteIndexPollTimer?.cancel();
          _websiteIndexPollTimer = null;
          if (mounted) {
            setState(() {
              _websiteIndexing = false;
              _websiteIndexed = 0;
              _websiteIndexTotal = 0;
            });
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Polling error: $e'), backgroundColor: AppTheme.error, behavior: SnackBarBehavior.floating),
            );
          }
        } finally {
          _websiteIndexPollRequestInFlight = false;
        }
      });
      return;
    }

    // ── Local mode: run indexing in-process ───────────────────────────────────
    final server = WebsiteSearchMcpServer();
    server.onIndexProgress = (indexed, total, currentUrl) {
      if (mounted) {
        setState(() {
          _websiteIndexed = indexed;
          _websiteIndexTotal = total;
        });
      }
    };
    _activeWebIndexServer = server;
    setState(() {
      _websiteIndexing = true;
      _websiteIndexed = 0;
      _websiteIndexTotal = 0;
    });
    try {
      await server.initialize({'websiteUrls': urlStr, 'maxPages': maxPages, 'indexingStrategy': 'before_first_run'});
      final result = await server.executeTool('reindex_websites', {});
      await server.dispose();
      _activeWebIndexServer = null;

      if (!mounted) return;
      if (result['cancelled'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Indexing cancelled (${result['indexedPages'] ?? 0} pages).'), behavior: SnackBarBehavior.floating),
        );
      } else if (result.containsKey('error')) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Indexing failed: ${result['error']}'),
            backgroundColor: AppTheme.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else {
        final count = result['indexedPages'] as int? ?? 0;
        final dbPath = result['duckDbPath'] as String?;
        final now = DateTime.now();
        await widget.service.saveWebsiteIndex(urls: urlStr, maxPages: maxPages, cron: _websiteIndexCron, lastIndexedAt: now);
        scheduleWebsiteIndexAlarm(_websiteIndexCron);
        setState(() => _websiteIndexLastIndexedAt = now);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Indexed $count page${count == 1 ? '' : 's'} — DB: ${dbPath ?? "local"}'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      _activeWebIndexServer = null;
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Indexing error: $e'), backgroundColor: AppTheme.error, behavior: SnackBarBehavior.floating));
    } finally {
      if (mounted) {
        setState(() {
          _websiteIndexing = false;
          _websiteIndexed = 0;
          _websiteIndexTotal = 0;
        });
      }
    }
  }

  Future<void> _openWebsiteIndexSchedulePicker() async {
    String? determinedCategory;
    final cron = _websiteIndexCron.trim();
    if (cron.isNotEmpty) {
      final parts = cron.split(RegExp(r'\s+'));
      if (parts.length == 5) {
        final hour = parts[1];
        final day = parts[2];
        final month = parts[3];
        final weekday = parts[4];
        if (month != '*' || day != '*' || weekday != '*') {
          determinedCategory = day != '*' && month == '*' && weekday == '*'
              ? 'monthly'
              : weekday != '*'
              ? 'weekly'
              : 'daily';
        } else if (hour == '*' || hour.contains('/')) {
          // "45 * * * *" or "0 */2 * * *" — runs every hour (or every N hours)
          determinedCategory = 'hourly';
        } else {
          // "35 19 * * *" — specific hour → daily
          determinedCategory = 'daily';
        }
      }
    }
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => SchedulePickerDialog(initialCron: _websiteIndexCron, initialCategory: determinedCategory, allowSubHourly: false),
    );
    if (result != null && mounted) {
      setState(() {
        _websiteIndexCron = result['cron'] ?? '';

      });
    }
  }

  // ═══════════════════════════════════════════════════
  // Clear
  // ═══════════════════════════════════════════════════

  Future<void> _clear() async {
    final l = L.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.dataSourcesClearTitle),
        content: Text(l.dataSourcesClearMessage),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.cancel)),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.delete, style: TextStyle(color: AppTheme.error)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await widget.service.clearAll();
    if (mounted) {
      _initFromService();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.dataSourcesSettingsCleared), behavior: SnackBarBehavior.floating));
    }
  }

  // ═══════════════════════════════════════════════════
  // Build
  // ═══════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l.dataSources),
        actions: [
          if (!_loading && widget.service.configuredCount > 0)
            IconButton(
              icon: Icon(Icons.delete_outline, color: AppTheme.error),
              tooltip: l.dataSourcesClearTitle,
              onPressed: _clear,
            ),
          const SizedBox(width: 8),
        ],
      ),
      bottomNavigationBar: _loading
          ? null
          : SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.save),
                  label: Text(l.save),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48), backgroundColor: AppTheme.primaryBlue),
                ),
              ),
            ),
      body: SafeArea(
        top: false,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).viewPadding.bottom + 84),
                children: [
                  // ── Info card ──
                  Card(
                    color: AppTheme.primaryBlue.withValues(alpha: 0.08),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Icon(Icons.security, color: AppTheme.primaryBlue, size: 20),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              l.dataSourcesGlobalSubtitle,
                              style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.primaryBlue),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // ═══════════════════════════════════════
                  // 1. GOOGLE SERVICES (Gmail + Drive)
                  // ═══════════════════════════════════════
                  _buildSectionCard(
                    icon: Icons.account_circle,
                    title: l.googleServices,
                    subtitle: l.googleServicesSubtitle,
                    enabled: _gmailSearchEnabled || _googleDriveEnabled,
                    onToggle: (v) => setState(() {
                      if (_isRemote) return;
                      _gmailSearchEnabled = v;
                      _googleDriveEnabled = v;
                      _updateEmailProvider();
                    }),
                    configured: widget.service.hasGmailOAuthTokens,
                    children: [
                      // ── Server mode notice ──
                      if (_isRemote) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppTheme.warning.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppTheme.warning.withValues(alpha: 0.4)),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(Icons.info_outline, color: AppTheme.warning, size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Google OAuth authentication must be done in local mode. '
                                  'In server mode, use IMAP/SMTP for email instead.',
                                  style: TextStyle(fontSize: 12, color: AppTheme.warning),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      // ── Google OAuth (shared) ──
                      if ((!_usesNativeGoogleSignInPlatform || _useManualGoogleOAuthFallback) && !_isRemote) ...[
                        Text(l.gmailSetup, style: TextStyle(fontSize: 12, color: Colors.grey[500])),
                        const SizedBox(height: 12),
                        if (OAuthDefaults.hasGmailClientId && OAuthDefaults.hasGmailClientSecret)
                          Text(
                            'Using bundled Google OAuth credentials from app build.',
                            style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                          ),
                        if (!OAuthDefaults.hasGmailClientId) ...[
                          TextFormField(
                            controller: _gmailClientIdCtrl,
                            decoration: InputDecoration(
                              labelText: l.oauthClientId,
                              hintText: l.oauthClientIdHint,
                              border: const OutlineInputBorder(),
                              prefixIcon: const Icon(Icons.badge_outlined),
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        if (!OAuthDefaults.hasGmailClientSecret) ...[
                          TextFormField(
                            controller: _gmailClientSecretCtrl,
                            obscureText: true,
                            decoration: InputDecoration(
                              labelText: l.oauthClientSecret,
                              hintText: l.oauthClientSecretHint,
                              border: const OutlineInputBorder(),
                              prefixIcon: const Icon(Icons.key_outlined),
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                      ],
                      if (!_isRemote)
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final isWide = constraints.maxWidth > 600;

                            final authCodeField = TextFormField(
                              controller: _gmailAuthCodeCtrl,
                              decoration: InputDecoration(
                                labelText: l.oauthAuthorizationCode,
                                hintText: l.oauthAuthorizationCodeHint,
                                border: const OutlineInputBorder(),
                                prefixIcon: const Icon(Icons.lock_open),
                              ),
                            );

                            final buttonRow = Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: _gmailAuthInProgress ? null : _openGoogleAuthorization,
                                    icon: const Icon(Icons.open_in_new),
                                    label: Text(l.authorizeGoogle),
                                  ),
                                ),
                                if (!_usesNativeGoogleSignInPlatform || _useManualGoogleOAuthFallback) ...[
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: FilledButton.icon(
                                      onPressed: _gmailAuthInProgress ? null : _exchangeAuthorizationCode,
                                      icon: _gmailAuthInProgress
                                          ? const SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                            )
                                          : const Icon(Icons.verified_user),
                                      label: Text(l.exchangeAuthorizationCode),
                                    ),
                                  ),
                                ],
                                if (widget.service.hasGmailOAuthTokens) ...[
                                  const SizedBox(width: 8),
                                  IconButton(
                                    onPressed: _gmailAuthInProgress ? null : _clearGmailTokens,
                                    tooltip: l.delete,
                                    icon: const Icon(Icons.delete_outline),
                                  ),
                                ],
                              ],
                            );

                            if (_usesNativeGoogleSignInPlatform && !_useManualGoogleOAuthFallback) {
                              return buttonRow;
                            }

                            if (isWide) {
                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(flex: 3, child: authCodeField),
                                  const SizedBox(width: 12),
                                  Expanded(flex: 4, child: buttonRow),
                                ],
                              );
                            }

                            return Column(children: [authCodeField, const SizedBox(height: 12), buttonRow]);
                          },
                        ),
                      if (!_isRemote) ...[
                        const SizedBox(height: 8),
                        Text(
                          widget.service.hasGmailOAuthTokens
                              ? l.oauthTokenStatusReady(
                                  widget.service.gmailAccountEmail.isNotEmpty ? widget.service.gmailAccountEmail : l.configured,
                                  widget.service.gmailTokenExpiry?.toIso8601String() ?? l.na,
                                )
                              : l.oauthTokenStatusMissing,
                          style: TextStyle(fontSize: 12, color: widget.service.hasGmailOAuthTokens ? AppTheme.success : Colors.orange),
                        ),
                      ],

                      if (!_isRemote) ...[
                        const Divider(height: 24),

                        // ── Gmail Search sub-toggle ──
                        SwitchListTile(
                          secondary: Icon(Icons.mail, color: _gmailSearchEnabled ? AppTheme.primaryBlue : Colors.grey),
                          title: Text(l.gmailSearch, style: const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text(l.emailSearchGmail, style: TextStyle(fontSize: 12, color: Colors.grey[500])),
                          value: _gmailSearchEnabled,
                          onChanged: (v) => setState(() {
                            _gmailSearchEnabled = v;
                            _updateEmailProvider();
                          }),
                          contentPadding: EdgeInsets.zero,
                        ),

                        const SizedBox(height: 8),

                        // ── Google Drive sub-toggle ──
                        SwitchListTile(
                          secondary: Icon(Icons.add_to_drive, color: _googleDriveEnabled ? AppTheme.primaryBlue : Colors.grey),
                          title: Text(l.googleDrive, style: const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text(l.cloudStorageSubtitle, style: TextStyle(fontSize: 12, color: Colors.grey[500])),
                          value: _googleDriveEnabled,
                          onChanged: (v) => setState(() => _googleDriveEnabled = v),
                          contentPadding: EdgeInsets.zero,
                        ),

                        if (_googleDriveEnabled) ...[
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: _testDriveInProgress ? null : _testGoogleDrive,
                              icon: _testDriveInProgress
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                    )
                                  : const Icon(Icons.folder_open),
                              label: Text(l.testDriveConnection),
                            ),
                          ),
                        ],
                      ],
                    ],
                  ),
                  const SizedBox(height: 16),

                  // ═══════════════════════════════════════
                  // 2. EMAIL SEND (IMAP / SMTP)
                  // ═══════════════════════════════════════
                  _buildSectionCard(
                    icon: Icons.outgoing_mail,
                    title: l.imapSmtpEmail,
                    subtitle: l.imapSmtpEmailSubtitle,
                    enabled: _imapSendEnabled,
                    onToggle: (v) => setState(() {
                      _imapSendEnabled = v;
                      _updateEmailProvider();
                    }),
                    configured: _imapSendEnabled && widget.service.imapHost.isNotEmpty && widget.service.imapUsername.isNotEmpty,
                    children: [
                      TextFormField(
                        controller: _imapHostCtrl,
                        decoration: InputDecoration(
                          labelText: l.imapHost,
                          hintText: l.imapHostHint,
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.dns),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          SizedBox(
                            width: 120,
                            child: TextFormField(
                              controller: _imapPortCtrl,
                              keyboardType: TextInputType.number,
                              decoration: InputDecoration(labelText: l.imapPort, border: const OutlineInputBorder()),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: SwitchListTile(
                              title: Text(l.imapUseSsl, style: const TextStyle(fontSize: 14)),
                              value: _imapUseSsl,
                              onChanged: (v) => setState(() {
                                _imapUseSsl = v;
                                if (v && _imapPortCtrl.text == '143') {
                                  _imapPortCtrl.text = '993';
                                } else if (!v && _imapPortCtrl.text == '993') {
                                  _imapPortCtrl.text = '143';
                                }
                              }),
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _imapUsernameCtrl,
                        decoration: InputDecoration(
                          labelText: l.imapUsername,
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.person),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _imapPasswordCtrl,
                        obscureText: _obscureImapPassword,
                        decoration: InputDecoration(
                          labelText: l.imapPassword,
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.lock),
                          suffixIcon: IconButton(
                            icon: Icon(_obscureImapPassword ? Icons.visibility : Icons.visibility_off),
                            onPressed: () => setState(() => _obscureImapPassword = !_obscureImapPassword),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      // SMTP outgoing settings
                      TextFormField(
                        controller: _smtpHostCtrl,
                        decoration: InputDecoration(
                          labelText: l.smtpHost,
                          hintText: l.smtpHostHint,
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.outgoing_mail),
                        ),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: 120,
                        child: TextFormField(
                          controller: _smtpPortCtrl,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(labelText: l.smtpPort, border: const OutlineInputBorder()),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _smtpSenderCtrl,
                        decoration: InputDecoration(
                          labelText: l.smtpSender,
                          hintText: l.smtpSenderHint,
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.alternate_email),
                        ),
                        keyboardType: TextInputType.emailAddress,
                      ),

                      // ── Notification / Test Email ──
                      const Divider(height: 24),
                      SwitchListTile(
                        title: Text(l.notificationEmail, style: const TextStyle(fontSize: 14)),
                        subtitle: Text(l.notificationEmailHint, style: TextStyle(fontSize: 12, color: Colors.grey[500])),
                        value: _notificationEmailEnabled,
                        onChanged: (v) => setState(() => _notificationEmailEnabled = v),
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _testEmailRecipientCtrl,
                        decoration: InputDecoration(
                          labelText: l.testEmailRecipient,
                          hintText: l.toEmailHint,
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.alternate_email),
                        ),
                        keyboardType: TextInputType.emailAddress,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _testEmailSubjectCtrl,
                        decoration: InputDecoration(
                          labelText: l.subject,
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.subject),
                        ),
                      ),
                      const SizedBox(height: 12),
                      // Test-via chooser
                      Row(
                        children: [
                          Text('${l.testVia}:', style: const TextStyle(fontWeight: FontWeight.w500)),
                          const SizedBox(width: 12),
                          if (!_isRemote) ...[
                            ChoiceChip(
                              label: const Text('Gmail'),
                              selected: _testEmailVia == 'gmail',
                              onSelected: _gmailSearchEnabled ? (v) => setState(() => _testEmailVia = 'gmail') : null,
                            ),
                            const SizedBox(width: 8),
                          ],
                          ChoiceChip(
                            label: const Text('IMAP'),
                            selected: _testEmailVia == 'imap',
                            onSelected: _imapSendEnabled ? (v) => setState(() => _testEmailVia = 'imap') : null,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _testSendInProgress ? null : _sendTestEmail,
                          icon: _testSendInProgress
                              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : const Icon(Icons.send),
                          label: Text(l.sendTestEmail),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // ═══════════════════════════════════════
                  // 2. WEB SEARCH
                  // ═══════════════════════════════════════
                  _buildSectionCard(
                    icon: Icons.search,
                    title: l.webSearch,
                    subtitle: l.webSearchSubtitle,
                    enabled: _webSearchEnabled,
                    onToggle: (v) => setState(() => _webSearchEnabled = v),
                    configured: widget.service.isWebSearchConfigured,
                    children: [
                      DropdownButtonFormField<WebSearchProvider>(
                        initialValue: _webSearchProvider,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: l.searchProvider,
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.travel_explore),
                        ),
                        items: [
                          DropdownMenuItem(
                            value: WebSearchProvider.duckduckgo,
                            child: Text(l.duckDuckGo, maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                          DropdownMenuItem(
                            value: WebSearchProvider.serper,
                            child: Text(l.serperProvider, maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                          DropdownMenuItem(
                            value: WebSearchProvider.serpapi,
                            child: Text(l.serpApiProvider, maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                          DropdownMenuItem(
                            value: WebSearchProvider.custom,
                            child: Text(l.customProvider, maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                        ],
                        onChanged: (v) => setState(() => _webSearchProvider = v ?? WebSearchProvider.duckduckgo),
                      ),

                      // ── Official website link for selected provider ──
                      Builder(
                        builder: (context) {
                          final providerUrl = switch (_webSearchProvider) {
                            WebSearchProvider.duckduckgo => 'https://duckduckgo.com',
                            WebSearchProvider.serper => 'https://serper.dev',
                            WebSearchProvider.serpapi => 'https://serpapi.com',
                            _ => '',
                          };
                          if (providerUrl.isEmpty) {
                            return const SizedBox.shrink();
                          }
                          return Padding(
                            padding: const EdgeInsets.only(top: 6, left: 4),
                            child: InkWell(
                              onTap: () => launchUrl(Uri.parse(providerUrl), mode: LaunchMode.externalApplication),
                              child: Text(
                                providerUrl,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(context).colorScheme.primary,
                                  decoration: TextDecoration.underline,
                                ),
                              ),
                            ),
                          );
                        },
                      ),

                      if (_webSearchProvider == WebSearchProvider.serper) ...[
                        const SizedBox(height: 16),
                        Text(l.serperSetup, style: TextStyle(fontSize: 12, color: Colors.grey[500])),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _webSearchApiKeyCtrl,
                          obscureText: _obscureSearchKey,
                          decoration: InputDecoration(
                            labelText: l.apiKey,
                            hintText: l.serperApiKeyHint,
                            border: const OutlineInputBorder(),
                            prefixIcon: const Icon(Icons.key),
                            suffixIcon: IconButton(
                              icon: Icon(_obscureSearchKey ? Icons.visibility : Icons.visibility_off),
                              onPressed: () => setState(() => _obscureSearchKey = !_obscureSearchKey),
                            ),
                          ),
                        ),
                      ],

                      if (_webSearchProvider == WebSearchProvider.serpapi) ...[
                        const SizedBox(height: 16),
                        Text(l.serpApiSetup, style: TextStyle(fontSize: 12, color: Colors.grey[500])),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _webSearchApiKeyCtrl,
                          obscureText: _obscureSearchKey,
                          decoration: InputDecoration(
                            labelText: l.apiKey,
                            hintText: l.serpApiKeyHint,
                            border: const OutlineInputBorder(),
                            prefixIcon: const Icon(Icons.key),
                            suffixIcon: IconButton(
                              icon: Icon(_obscureSearchKey ? Icons.visibility : Icons.visibility_off),
                              onPressed: () => setState(() => _obscureSearchKey = !_obscureSearchKey),
                            ),
                          ),
                        ),
                      ],

                      if (_webSearchProvider == WebSearchProvider.custom) ...[
                        const SizedBox(height: 16),
                        Text(l.customProviderSetup, style: TextStyle(fontSize: 12, color: Colors.grey[500])),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _webSearchCustomProviderCtrl,
                          decoration: InputDecoration(
                            labelText: l.customProviderName,
                            hintText: l.customProviderNameHint,
                            border: const OutlineInputBorder(),
                            prefixIcon: const Icon(Icons.label_outline),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _webSearchCustomEndpointCtrl,
                          decoration: InputDecoration(
                            labelText: l.customProviderEndpoint,
                            hintText: l.customProviderEndpointHint,
                            border: const OutlineInputBorder(),
                            prefixIcon: const Icon(Icons.link),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _webSearchApiKeyCtrl,
                          obscureText: _obscureSearchKey,
                          decoration: InputDecoration(
                            labelText: l.apiKey,
                            hintText: l.apiKeyHint,
                            border: const OutlineInputBorder(),
                            prefixIcon: const Icon(Icons.key),
                            suffixIcon: IconButton(
                              icon: Icon(_obscureSearchKey ? Icons.visibility : Icons.visibility_off),
                              onPressed: () => setState(() => _obscureSearchKey = !_obscureSearchKey),
                            ),
                          ),
                        ),
                      ],

                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _webSearchMaxResultsCtrl,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: l.maxResults,
                          hintText: '5',
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.format_list_numbered),
                        ),
                      ),
                      const Divider(height: 24),
                      TextFormField(
                        controller: _testSearchQueryCtrl,
                        decoration: InputDecoration(
                          labelText: l.testSearchQuery,
                          hintText: l.testSearchQueryHint,
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.search),
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _testSearchInProgress ? null : _testWebSearch,
                          icon: _testSearchInProgress
                              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : const Icon(Icons.travel_explore),
                          label: Text(l.testSearch),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.storage, color: AppTheme.primaryBlue),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(l.localSearchIndexDuckdb, style: const TextStyle(fontWeight: FontWeight.w600)),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(l.duckdbSizeLimitDescription, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _duckDbSizeLimitGbCtrl,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: InputDecoration(
                              labelText: l.duckdbSizeLimitGb,
                              hintText: l.duckdbSizeLimitHint,
                              border: OutlineInputBorder(),
                              prefixIcon: const Icon(Icons.data_object),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // ═══════════════════════════════════════
                  // 3. WEBSITE AUTO-INDEX
                  // ═══════════════════════════════════════
                  Card(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(
                        color: _websiteIndexUrls.isNotEmpty
                            ? AppTheme.primaryBlue.withValues(alpha: 0.5)
                            : Theme.of(context).dividerColor.withValues(alpha: 0.3),
                        width: _websiteIndexUrls.isNotEmpty ? 2 : 1,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ListTile(
                          leading: Icon(Icons.language, color: AppTheme.primaryBlue),
                          title: const Text('Website Auto-Index', style: TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: const Text(
                            'Crawl and index websites for AI search. Up to 10 URLs indexed into DuckDB.',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                        const Divider(height: 1),
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // ── URL chip list ──
                              if (_websiteIndexUrls.isNotEmpty) ...[
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 4,
                                  children: _websiteIndexUrls.map((url) {
                                    Uri? parsed;
                                    try {
                                      parsed = Uri.parse(url.contains('://') ? url : 'https://$url');
                                    } catch (_) {}
                                    final host = parsed?.host.isNotEmpty == true ? parsed!.host : url;
                                    return InputChip(
                                      label: Text(host, style: const TextStyle(fontSize: 12)),
                                      avatar: const Icon(Icons.public, size: 16),
                                      tooltip: url,
                                      deleteIcon: const Icon(Icons.close, size: 16),
                                      onDeleted: _websiteIndexing ? null : () => setState(() => _websiteIndexUrls.remove(url)),
                                    );
                                  }).toList(),
                                ),
                                const SizedBox(height: 8),
                              ],

                              // ── URL input ──
                              Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: _websiteIndexUrlCtrl,
                                      enabled: !_websiteIndexing,
                                      decoration: const InputDecoration(
                                        border: OutlineInputBorder(),
                                        isDense: true,
                                        labelText: 'Add website URL',
                                        hintText: 'https://example.com/docs',
                                        prefixIcon: Icon(Icons.add_link),
                                      ),
                                      onSubmitted: (_) => _addWebsiteIndexUrl(),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  OutlinedButton(onPressed: _websiteIndexing ? null : _addWebsiteIndexUrl, child: const Text('Add')),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Add up to 10 URLs. Pages are indexed into DuckDB for AI-powered search.',
                                style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                              ),
                              const SizedBox(height: 12),

                              // ── Max pages ──
                              TextFormField(
                                controller: _websiteIndexMaxPagesCtrl,
                                enabled: !_websiteIndexing,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                  labelText: 'Max pages per site',
                                  hintText: '100',
                                  prefixIcon: Icon(Icons.format_list_numbered),
                                ),
                              ),
                              const SizedBox(height: 12),

                              // ── Schedule row ──
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: _websiteIndexing ? null : _openWebsiteIndexSchedulePicker,
                                      icon: const Icon(Icons.schedule, size: 18),
                                      label: Text(
                                        _websiteIndexCron.isNotEmpty
                                            ? _websiteIndexCron
                                            : 'Set auto-index schedule',
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 13),
                                      ),
                                    ),
                                  ),
                                  if (_websiteIndexCron.isNotEmpty) ...[
                                    const SizedBox(width: 8),
                                    IconButton(
                                      icon: const Icon(Icons.clear, size: 18),
                                      tooltip: 'Remove schedule',
                                      onPressed: _websiteIndexing
                                          ? null
                                          : () => setState(() {
                                              _websiteIndexCron = '';
                                        
                                            }),
                                    ),
                                  ],
                                ],
                              ),

                              // ── Last indexed ──
                              if (_websiteIndexLastIndexedAt != null) ...[
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Icon(Icons.history, size: 14, color: Colors.grey[500]),
                                    const SizedBox(width: 4),
                                    Text(
                                      'Last indexed: ${_formatLastIndexed(_websiteIndexLastIndexedAt!)}',
                                      style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                                    ),
                                  ],
                                ),
                              ],

                              // ── Progress ──
                              if (_websiteIndexing) ...[
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        value: _websiteIndexTotal > 0 ? (_websiteIndexed / _websiteIndexTotal).clamp(0.0, 1.0) : null,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        _websiteIndexTotal > 0
                                            ? 'Indexing $_websiteIndexed / $_websiteIndexTotal pages\u2026'
                                            : 'Indexing\u2026',
                                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                                      ),
                                    ),
                                    TextButton(
                                      onPressed: () {
                                        if (_isRemote) {
                                          widget.serverClient!.stopWebsiteIndex().catchError((_) {});
                                        } else {
                                          _activeWebIndexServer?.cancelIndexing();
                                        }
                                      },
                                      child: const Text('Cancel'),
                                    ),
                                  ],
                                ),
                              ],

                              const SizedBox(height: 12),
                              // ── Index Now button ──
                              SizedBox(
                                width: double.infinity,
                                child: FilledButton.icon(
                                  onPressed: (_websiteIndexUrls.isEmpty || _websiteIndexing) ? null : _doWebsiteIndex,
                                  icon: _websiteIndexing
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                        )
                                      : const Icon(Icons.play_arrow),
                                  label: Text(_websiteIndexing ? 'Indexing\u2026' : 'Index Now'),
                                  style: FilledButton.styleFrom(backgroundColor: Colors.green),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  // ═══════════════════════════════════════
                  // 4. DOCUMENT INDEX
                  // ═══════════════════════════════════════
                  const SizedBox(height: 16),
                  Card(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(
                        color: _documentRootPaths.isNotEmpty
                            ? AppTheme.primaryBlue.withValues(alpha: 0.5)
                            : Theme.of(context).dividerColor.withValues(alpha: 0.3),
                        width: _documentRootPaths.isNotEmpty ? 2 : 1,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ListTile(
                          leading: Icon(Icons.folder_open, color: AppTheme.primaryBlue),
                          title: const Text('Document Index', style: TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: const Text(
                            'Index local PDF, Word, and Markdown files for AI document search.',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                        const Divider(height: 1),
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // ── Selected folders as removable chips ──
                              if (_documentRootPaths.isNotEmpty) ...[
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: _documentRootPaths.map((p) {
                                    final label = _folderLabel(p);
                                    return Container(
                                      decoration: BoxDecoration(
                                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                        borderRadius: BorderRadius.circular(20),
                                        border: Border.all(color: Theme.of(context).dividerColor),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          // ── Info button (left) ──
                                          InkWell(
                                            borderRadius: const BorderRadius.horizontal(left: Radius.circular(20)),
                                            onTap: () {
                                              showDialog<void>(
                                                context: context,
                                                builder: (dialogCtx) => AlertDialog(
                                                  title: const Text('Full path'),
                                                  content: SelectableText(p),
                                                  actions: [TextButton(onPressed: () => Navigator.pop(dialogCtx), child: const Text('OK'))],
                                                ),
                                              );
                                            },
                                            child: const Padding(
                                              padding: EdgeInsets.fromLTRB(10, 6, 4, 6),
                                              child: Icon(Icons.info_outline, size: 14),
                                            ),
                                          ),
                                          // ── Folder icon + label ──
                                          const Icon(Icons.folder, size: 16),
                                          const SizedBox(width: 4),
                                          Text(label, style: const TextStyle(fontSize: 12)),
                                          // ── Remove button (right) ──
                                          if (!_documentIndexing)
                                            InkWell(
                                              borderRadius: const BorderRadius.horizontal(right: Radius.circular(20)),
                                              onTap: () async {
                                                final updated = {..._documentRootPaths}..remove(p);
                                                setState(() => _documentRootPaths = updated);
                                                await widget.service.saveDocumentIndex(
                                                  rootPaths: updated.join(';'),
                                                  cron: _documentIndexCron,
                                                );
                                              },
                                              child: const Padding(
                                                padding: EdgeInsets.fromLTRB(4, 6, 10, 6),
                                                child: Icon(Icons.close, size: 14),
                                              ),
                                            )
                                          else
                                            const SizedBox(width: 10),
                                        ],
                                      ),
                                    );
                                  }).toList(),
                                ),
                                const SizedBox(height: 8),
                              ],

                              // ── File types to index ──
                              Row(
                                children: [
                                  Text(
                                    L.of(context).docFileTypesLabel,
                                    style: Theme.of(context).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
                                  ),
                                  const Spacer(),
                                  TextButton(
                                    style: TextButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      minimumSize: Size.zero,
                                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    ),
                                    onPressed: () async {
                                      const defaults = {'pdf', 'md', 'docx'};
                                      setState(() => _documentFileTypes = defaults);
                                      await widget.service.saveDocumentIndex(
                                        rootPaths: _documentRootPaths.join(';'),
                                        fileTypes: defaults.join(','),
                                        cron: _documentIndexCron,
                                      );
                                    },
                                    child: Text(
                                      L.of(context).docFileTypesReset,
                                      style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.primary),
                                    ),
                                  ),
                                  TextButton(
                                    style: TextButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      minimumSize: Size.zero,
                                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    ),
                                    onPressed: () async {
                                      final all = Set<String>.from(_kAllDocFileTypes);
                                      setState(() => _documentFileTypes = all);
                                      await widget.service.saveDocumentIndex(
                                        rootPaths: _documentRootPaths.join(';'),
                                        fileTypes: all.join(','),
                                        cron: _documentIndexCron,
                                      );
                                    },
                                    child: Text(
                                      L.of(context).docFileTypesAll,
                                      style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.primary),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Wrap(
                                spacing: 6,
                                runSpacing: 4,
                                children: _kAllDocFileTypes.map((ext) {
                                  final isSelected = _documentFileTypes.contains(ext);
                                  return FilterChip(
                                    label: Text(
                                      '.$ext',
                                      style: TextStyle(fontSize: 11, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal),
                                    ),
                                    selected: isSelected,
                                    showCheckmark: false,
                                    visualDensity: VisualDensity.compact,
                                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    selectedColor: Theme.of(context).colorScheme.primaryContainer,
                                    onSelected: (on) async {
                                      final updated = Set<String>.from(_documentFileTypes);
                                      if (on) {
                                        updated.add(ext);
                                      } else {
                                        updated.remove(ext);
                                      }
                                      setState(() => _documentFileTypes = updated);
                                      await widget.service.saveDocumentIndex(
                                        rootPaths: _documentRootPaths.join(';'),
                                        fileTypes: updated.join(','),
                                        cron: _documentIndexCron,
                                      );
                                    },
                                  );
                                }).toList(),
                              ),
                              const SizedBox(height: 8),

                              // ── Status container ──
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                decoration: BoxDecoration(
                                  border: Border.all(color: Theme.of(context).colorScheme.outline.withAlpha(120)),
                                  borderRadius: BorderRadius.circular(8),
                                  color: Theme.of(context).colorScheme.surfaceContainerHighest.withAlpha(80),
                                ),
                                child: Text(
                                  _documentRootPaths.isEmpty
                                      ? 'No folders selected'
                                      : '${_documentRootPaths.length} folder${_documentRootPaths.length > 1 ? 's' : ''} selected',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: _documentRootPaths.isEmpty ? Theme.of(context).colorScheme.onSurfaceVariant : null,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),

                              // ── Add path (server) or Browse / Pick (local) ──
                              if (_isRemote) ...[
                                SizedBox(
                                  width: double.infinity,
                                  child: OutlinedButton.icon(
                                    icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                                    label: const Text('Add Folder or File'),
                                    onPressed: _documentIndexing ? null : _docAddServerPath,
                                  ),
                                ),
                              ] else ...[
                                Row(
                                  children: [
                                    Expanded(
                                      child: OutlinedButton.icon(
                                        icon: const Icon(Icons.folder_open, size: 18),
                                        label: const Text('Browse Folder'),
                                        onPressed: _documentIndexing ? null : _docBrowseFolder,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: OutlinedButton.icon(
                                        icon: const Icon(Icons.file_copy_outlined, size: 18),
                                        label: const Text('Pick Files'),
                                        onPressed: _documentIndexing ? null : _docPickFiles,
                                      ),
                                    ),
                                  ],
                                ),
                                // ── Common-folder shortcuts (Android only) ──
                                if (Platform.isAndroid) ...[
                                  const SizedBox(height: 6),
                                  Wrap(
                                    spacing: 6,
                                    runSpacing: 4,
                                    children: [
                                      for (final entry in const [('Documents', 'primary:Documents'), ('Downloads', 'primary:Download')])
                                        Builder(
                                          builder: (context) {
                                            final alreadyAdded = _documentRootPaths.any((p) => Uri.decodeFull(p).contains(entry.$2));
                                            return ActionChip(
                                              avatar: Icon(alreadyAdded ? Icons.check : Icons.folder_special, size: 14),
                                              label: Text(alreadyAdded ? entry.$1 : '+ ${entry.$1}', style: const TextStyle(fontSize: 11)),
                                              tooltip: alreadyAdded ? '${entry.$1} already added' : 'Open picker at ${entry.$1}',
                                              onPressed: (_documentIndexing || alreadyAdded) ? null : () => _docBrowseKnownFolder(entry.$2),
                                              visualDensity: VisualDensity.compact,
                                              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                            );
                                          },
                                        ),
                                    ],
                                  ),
                                ],
                              ],
                              const SizedBox(height: 8),
                              // ── Run schedule ──
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: _openDocumentIndexSchedulePicker,
                                      icon: const Icon(Icons.schedule, size: 18),
                                      label: Text(
                                        _documentIndexCron.isNotEmpty
                                            ? _documentIndexCron
                                            : 'Set auto-index schedule (optional)',
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 13),
                                      ),
                                    ),
                                  ),
                                  if (_documentIndexCron.isNotEmpty) ...[
                                    const SizedBox(width: 8),
                                    IconButton(
                                      icon: const Icon(Icons.clear, size: 18),
                                      tooltip: 'Remove schedule',
                                      onPressed: () async {
                                        setState(() {
                                          _documentIndexCron = '';
                                    
                                        });
                                        await widget.service.saveDocumentIndex(rootPaths: _documentRootPaths.join(';'), cron: '');
                                        scheduleDocumentIndexAlarm('');
                                      },
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 4),
                              if (_isRemote)
                                Text(
                                  'Enter the absolute path on the server (e.g. /home/user/documents). The folder name is shown as the chip label.',
                                  style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                                )
                              else
                                Text(
                                  Platform.isAndroid
                                      ? 'Android blocks the root and Downloads folder. Use shortcuts above for Documents (works). For Downloads: use "Pick Files" to copy individual files.'
                                      : 'Pick Files copies files into app storage for indexing.',
                                  style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                                ),

                              // ── Last indexed ──
                              if (_documentIndexLastIndexedAt != null) ...[
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Icon(Icons.history, size: 14, color: Colors.grey[500]),
                                    const SizedBox(width: 4),
                                    Text(
                                      'Last indexed: ${_formatLastIndexed(_documentIndexLastIndexedAt!)}',
                                      style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                                    ),
                                  ],
                                ),
                              ],

                              // ── Progress ──
                              if (_documentIndexing) ...[
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        value: _documentIndexTotal > 0 ? (_documentIndexed / _documentIndexTotal).clamp(0.0, 1.0) : null,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        _documentIndexTotal > 0 ? 'Indexing $_documentIndexed / $_documentIndexTotal…' : 'Indexing…',
                                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                                      ),
                                    ),
                                    TextButton(
                                      onPressed: () {
                                        if (_isRemote) {
                                          widget.serverClient!.stopDocumentIndex().catchError((_) {});
                                        } else {
                                          _activeDocServer?.cancelIndexing();
                                        }
                                      },
                                      child: const Text('Cancel'),
                                    ),
                                  ],
                                ),
                              ],

                              const SizedBox(height: 12),
                              // ── Index Now button ──
                              SizedBox(
                                width: double.infinity,
                                child: FilledButton.icon(
                                  onPressed: (_documentRootPaths.isEmpty || _documentIndexing) ? null : _doDocumentIndex,
                                  icon: _documentIndexing
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                        )
                                      : const Icon(Icons.play_arrow),
                                  label: Text(_documentIndexing ? 'Indexing…' : 'Index Now'),
                                  style: FilledButton.styleFrom(backgroundColor: Colors.green),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  // ═══════════════════════════════════════
                  // 5. CLOUD STORAGE – OneDrive (hidden – set _kShowOneDrive=true to re-enable)
                  // ═══════════════════════════════════════
                  if (_kShowOneDrive) ...[
                    const SizedBox(height: 16),
                    _buildSectionCard(
                      icon: Icons.cloud,
                      title: l.oneDrive,
                      subtitle: l.oneDriveSubtitle,
                      enabled: _oneDriveEnabled,
                      onToggle: (v) => setState(() => _oneDriveEnabled = v),
                      configured: widget.service.isOneDriveConfigured,
                      children: [
                        TextFormField(
                          controller: _oneDriveClientIdCtrl,
                          decoration: InputDecoration(
                            labelText: l.oneDriveClientId,
                            hintText: l.oneDriveClientIdHint,
                            border: const OutlineInputBorder(),
                            prefixIcon: const Icon(Icons.apps),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _oneDriveTenantIdCtrl,
                          decoration: InputDecoration(
                            labelText: l.oneDriveTenantId,
                            hintText: l.oneDriveTenantIdHint,
                            border: const OutlineInputBorder(),
                            prefixIcon: const Icon(Icons.business),
                          ),
                        ),
                      ],
                    ),
                  ],

                  const SizedBox(height: 16),

                  // ═══════════════════════════════════════
                  // 5. LOCATION
                  // ═══════════════════════════════════════
                  Card(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(
                        color: widget.service.hasLocation
                            ? AppTheme.success.withValues(alpha: 0.5)
                            : Theme.of(context).dividerColor.withValues(alpha: 0.3),
                        width: widget.service.hasLocation ? 2 : 1,
                      ),
                    ),
                    child: Column(
                      children: [
                        ListTile(
                          leading: Stack(
                            children: [
                              Icon(Icons.location_on, color: AppTheme.primaryBlue),
                              if (widget.service.hasLocation)
                                Positioned(right: -2, bottom: -2, child: Icon(Icons.check_circle, size: 14, color: AppTheme.success)),
                            ],
                          ),
                          title: const Text('Location', style: TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text(
                            'Stored coordinates are injected into every AI task so queries like '
                            '"weather at my location" resolve automatically.',
                            style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                          ),
                        ),
                        const Divider(height: 1),
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: TextFormField(
                                      controller: _latCtrl,
                                      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                                      decoration: const InputDecoration(
                                        labelText: 'Latitude',
                                        hintText: '48.137154',
                                        border: OutlineInputBorder(),
                                        prefixIcon: Icon(Icons.north),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: TextFormField(
                                      controller: _lngCtrl,
                                      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                                      decoration: const InputDecoration(
                                        labelText: 'Longitude',
                                        hintText: '11.575382',
                                        border: OutlineInputBorder(),
                                        prefixIcon: Icon(Icons.east),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              SizedBox(
                                width: double.infinity,
                                child: FilledButton.icon(
                                  onPressed: _locationFetching
                                      ? null
                                      : () async {
                                          setState(() => _locationFetching = true);
                                          final messenger = ScaffoldMessenger.of(context);
                                          try {
                                            final pos = await LocationService().fetchGpsLocation();
                                            if (pos != null && mounted) {
                                              setState(() {
                                                _latCtrl.text = pos.latitude.toStringAsFixed(6);
                                                _lngCtrl.text = pos.longitude.toStringAsFixed(6);
                                              });
                                              messenger.showSnackBar(
                                                SnackBar(
                                                  content: Text(
                                                    'Location updated: ${pos.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)}',
                                                  ),
                                                  behavior: SnackBarBehavior.floating,
                                                ),
                                              );
                                            } else if (mounted) {
                                              messenger.showSnackBar(
                                                const SnackBar(
                                                  content: Text('Could not get GPS position. Check location permissions.'),
                                                  backgroundColor: Colors.orange,
                                                  behavior: SnackBarBehavior.floating,
                                                ),
                                              );
                                            }
                                          } finally {
                                            if (mounted) {
                                              setState(() => _locationFetching = false);
                                            }
                                          }
                                        },
                                  icon: _locationFetching
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                        )
                                      : const Icon(Icons.my_location),
                                  label: const Text('Refetch GPS Position'),
                                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                                ),
                              ),
                              if (widget.service.hasLocation) ...[
                                const SizedBox(height: 8),
                                Text(
                                  'Stored: ${widget.service.locationLatitude?.toStringAsFixed(5)}, '
                                  '${widget.service.locationLongitude?.toStringAsFixed(5)}',
                                  style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // ═══════════════════════════════════════
                  // 6. SSH / SFTP
                  // ═══════════════════════════════════════
                  Card(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(
                        color: widget.service.isSshConfigured
                            ? AppTheme.success.withValues(alpha: 0.5)
                            : Theme.of(context).dividerColor.withValues(alpha: 0.3),
                        width: widget.service.isSshConfigured ? 2 : 1,
                      ),
                    ),
                    child: Column(
                      children: [
                        ListTile(
                          leading: Stack(
                            children: [
                              const Icon(Icons.terminal, color: AppTheme.primaryBlue),
                              if (widget.service.isSshConfigured)
                                const Positioned(right: -2, bottom: -2, child: Icon(Icons.check_circle, size: 14, color: AppTheme.success)),
                            ],
                          ),
                          title: const Text('SSH / SFTP', style: TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text(
                            'Global SSH connection settings. Tasks using the SSH/SFTP MCP will fall back to these credentials.',
                            style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                          ),
                        ),
                        const Divider(height: 1),
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    flex: 3,
                                    child: TextFormField(
                                      controller: _sshHostCtrl,
                                      decoration: const InputDecoration(
                                        labelText: 'Hostname / IP',
                                        hintText: '192.168.1.10',
                                        border: OutlineInputBorder(),
                                        prefixIcon: Icon(Icons.dns),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  SizedBox(
                                    width: 90,
                                    child: TextFormField(
                                      controller: _sshPortCtrl,
                                      keyboardType: TextInputType.number,
                                      decoration: const InputDecoration(labelText: 'Port', hintText: '22', border: OutlineInputBorder()),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              TextFormField(
                                controller: _sshUsernameCtrl,
                                decoration: const InputDecoration(
                                  labelText: 'Username',
                                  hintText: 'admin',
                                  border: OutlineInputBorder(),
                                  prefixIcon: Icon(Icons.person),
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextFormField(
                                controller: _sshPasswordCtrl,
                                obscureText: _obscureSshPassword,
                                decoration: InputDecoration(
                                  labelText: 'Password',
                                  border: const OutlineInputBorder(),
                                  prefixIcon: const Icon(Icons.lock),
                                  suffixIcon: IconButton(
                                    icon: Icon(_obscureSshPassword ? Icons.visibility_off : Icons.visibility),
                                    onPressed: () => setState(() => _obscureSshPassword = !_obscureSshPassword),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              // Private key picker
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: () async {
                                        final result = await FilePicker.pickFiles(
                                          type: FileType.any,
                                          allowMultiple: false,
                                          withData: true,
                                        );
                                        if (result != null && result.files.single.bytes != null) {
                                          final content = utf8.decode(result.files.single.bytes!, allowMalformed: false);
                                          setState(() {
                                            _sshPrivateKeyContent = content;
                                            _sshPrivateKeyFileName = result.files.single.name;
                                          });
                                        }
                                      },
                                      icon: const Icon(Icons.key, size: 18),
                                      label: Text(
                                        _sshPrivateKeyFileName.isNotEmpty ? _sshPrivateKeyFileName : 'Load Private Key (PEM)…',
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                                  if (_sshPrivateKeyContent.isNotEmpty) ...[
                                    const SizedBox(width: 8),
                                    IconButton(
                                      tooltip: 'Clear private key',
                                      icon: const Icon(Icons.clear, size: 18),
                                      onPressed: () => setState(() {
                                        _sshPrivateKeyContent = '';
                                        _sshPrivateKeyFileName = '';
                                      }),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 12),
                              SizedBox(
                                width: double.infinity,
                                child: OutlinedButton.icon(
                                  onPressed: _sshTestInProgress ? null : _testSshConnection,
                                  icon: _sshTestInProgress
                                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                                      : const Icon(Icons.network_check),
                                  label: const Text('Test SSH Connection'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // ═══════════════════════════════════════
                  // 7. HOME ASSISTANT
                  // ═══════════════════════════════════════
                  _buildSectionCard(
                    icon: Icons.home,
                    title: 'Home Assistant',
                    subtitle: 'Control smart home devices via the Home Assistant REST API.',
                    enabled: _haEnabled,
                    onToggle: (v) => setState(() => _haEnabled = v),
                    configured: widget.service.isHomeAssistantConfigured,
                    children: [
                      TextFormField(
                        controller: _haBaseUrlCtrl,
                        keyboardType: TextInputType.url,
                        decoration: const InputDecoration(
                          labelText: 'Base URL',
                          hintText: 'http://homeassistant.local:8123',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.link),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _haTokenCtrl,
                        obscureText: _obscureHaToken,
                        decoration: InputDecoration(
                          labelText: 'Long-Lived Access Token',
                          hintText: 'Create one in HA \u2192 Profile \u2192 Long-Lived Access Tokens',
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.vpn_key),
                          suffixIcon: IconButton(
                            icon: Icon(_obscureHaToken ? Icons.visibility_off : Icons.visibility),
                            onPressed: () => setState(() => _obscureHaToken = !_obscureHaToken),
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 16),

                  // ═══════════════════════════════════════
                  // 8. SLACK
                  // ═══════════════════════════════════════
                  // ═══════════════════════════════════════
                  _buildSectionCard(
                    icon: Icons.chat_bubble_outline,
                    title: 'Slack',
                    subtitle: 'Send task results to a Slack channel via webhook or bot token.',
                    enabled: _slackEnabled,
                    onToggle: (v) => setState(() => _slackEnabled = v),
                    configured: widget.service.isSlackConfigured,
                    children: [
                      Text(
                        'Webhook URL — how to get it:\n'
                        '1. Go to api.slack.com/apps and create a free app ("From scratch").\n'
                        '2. Under "Add features", enable Incoming Webhooks.\n'
                        '3. Click "Add New Webhook to Workspace" and choose a channel.\n'
                        '4. Copy the Webhook URL shown (starts with https://hooks.slack.com/…).',
                        style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                          icon: const Icon(Icons.open_in_new, size: 14),
                          label: const Text('Open api.slack.com/apps (free)', style: TextStyle(fontSize: 12)),
                          onPressed: () =>
                              launchUrl(Uri.parse('https://api.slack.com/apps?new_app=1'), mode: LaunchMode.externalApplication),
                        ),
                      ),
                      const SizedBox(height: 4),
                      TextFormField(
                        controller: _slackWebhookUrlCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Webhook URL',
                          hintText: 'https://hooks.slack.com/services/T…/B…/…',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.link),
                        ),
                        keyboardType: TextInputType.url,
                      ),
                      const Divider(height: 24),
                      Text(
                        'Bot token (advanced) — required for file uploads.\n'
                        'In your Slack App: left sidebar → OAuth & Permissions → scroll to '
                        'Scopes → Bot Token Scopes → Add an OAuth Scope.\n'
                        'Add: chat:write  ·  files:write  ·  files:read\n'
                        'Then: scroll up → Install to Workspace → copy the Bot User OAuth Token (xoxb-…).',
                        style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                      ),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _slackBotTokenCtrl,
                        obscureText: _obscureSlackBotToken,
                        decoration: InputDecoration(
                          labelText: 'Bot Token',
                          hintText: 'xoxb-…',
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.token),
                          suffixIcon: IconButton(
                            icon: Icon(_obscureSlackBotToken ? Icons.visibility_off : Icons.visibility),
                            onPressed: () => setState(() => _obscureSlackBotToken = !_obscureSlackBotToken),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _slackDefaultChannelCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Default Channel',
                          hintText: '#channel-name  ·  C0XXXXXXX  ·  U0XXXXXXX (your Member ID)',
                          helperText: 'To message yourself: open Slack → your profile → ⋮ → Copy Member ID (U…)',
                          helperMaxLines: 2,
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.tag),
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _slackTestInProgress ? null : _testSlack,
                          icon: _slackTestInProgress
                              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.send),
                          label: const Text('Send Test Message'),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 16),

                  // ═══════════════════════════════════════
                  // 8. WHATSAPP
                  // ═══════════════════════════════════════
                  _buildSectionCard(
                    icon: Icons.phone_android,
                    title: 'WhatsApp',
                    subtitle: 'Send task results via WhatsApp.',
                    enabled: _whatsAppEnabled,
                    onToggle: (v) => setState(() => _whatsAppEnabled = v),
                    configured: widget.service.isWhatsAppConfigured,
                    children: [
                      // ── Mode selector ─────────────────────────────────
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(value: 'callmebot', label: Text('CallMeBot'), icon: Icon(Icons.person)),
                          ButtonSegment(value: 'meta', label: Text('Meta Business API'), icon: Icon(Icons.business)),
                        ],
                        selected: {_whatsAppMode},
                        onSelectionChanged: (s) => setState(() => _whatsAppMode = s.first),
                        style: ButtonStyle(
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          padding: WidgetStateProperty.all(const EdgeInsets.symmetric(vertical: 14)),
                        ),
                      ),
                      const SizedBox(height: 16),

                      if (_whatsAppMode == 'callmebot') ...[
                        // ── CallMeBot mode ───────────────────────────────
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.green.withAlpha(20),
                            border: Border.all(color: Colors.green.withAlpha(80)),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '✅ Works with your personal WhatsApp number — no Facebook/Meta account needed.',
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 6),
                              const Text(
                                'One-time setup: send the message below to +34 644 59 77 60 on WhatsApp. '
                                'CallMeBot replies with your personal API key.',
                                style: TextStyle(fontSize: 12),
                              ),
                              const SizedBox(height: 6),
                              SelectableText(
                                'I allow callmebot to send me messages',
                                style: TextStyle(fontSize: 12, fontFamily: 'monospace', color: Colors.green[300]),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _whatsAppDefaultRecipientCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Your WhatsApp Number',
                            hintText: '+43660…',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.call),
                          ),
                          keyboardType: TextInputType.phone,
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _whatsAppCallMeBotApiKeyCtrl,
                          obscureText: _obscureCallMeBotKey,
                          decoration: InputDecoration(
                            labelText: 'CallMeBot API Key',
                            hintText: '1234567',
                            border: const OutlineInputBorder(),
                            prefixIcon: const Icon(Icons.vpn_key),
                            suffixIcon: IconButton(
                              icon: Icon(_obscureCallMeBotKey ? Icons.visibility_off : Icons.visibility),
                              onPressed: () => setState(() => _obscureCallMeBotKey = !_obscureCallMeBotKey),
                            ),
                          ),
                        ),
                      ] else ...[
                        // ── Meta Business Cloud API mode ────────────────
                        Text(
                          'Requires a Meta Developer account with a WhatsApp Business App. '
                          'Free tier: 1,000 conversations / month.',
                          style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                            icon: const Icon(Icons.open_in_new, size: 14),
                            label: const Text('Get started (free) on Meta Developers', style: TextStyle(fontSize: 12)),
                            onPressed: () => launchUrl(
                              Uri.parse('https://developers.facebook.com/docs/whatsapp/cloud-api/get-started'),
                              mode: LaunchMode.externalApplication,
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        TextFormField(
                          controller: _whatsAppPhoneNumberIdCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Phone Number ID',
                            hintText: '1234567890',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.dialpad),
                          ),
                          keyboardType: TextInputType.number,
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _whatsAppAccessTokenCtrl,
                          obscureText: _obscureWaToken,
                          decoration: InputDecoration(
                            labelText: 'Access Token',
                            hintText: 'EAAxxxxxxxx…',
                            border: const OutlineInputBorder(),
                            prefixIcon: const Icon(Icons.token),
                            suffixIcon: IconButton(
                              icon: Icon(_obscureWaToken ? Icons.visibility_off : Icons.visibility),
                              onPressed: () => setState(() => _obscureWaToken = !_obscureWaToken),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _whatsAppDefaultRecipientCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Default Recipient Number',
                            hintText: '+43123456789',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.call),
                          ),
                          keyboardType: TextInputType.phone,
                        ),
                      ],

                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _whatsAppTestInProgress ? null : _testWhatsApp,
                          icon: _whatsAppTestInProgress
                              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.send),
                          label: const Text('Send Test Message'),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 24),
                ],
              ),
      ),
    );
  }

  // ═════════════════════
  // Test Slack
  // ═════════════════════

  Future<void> _testSlack() async {
    setState(() => _slackTestInProgress = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.service.saveSlack(
        enabled: _slackEnabled,
        webhookUrl: _slackWebhookUrlCtrl.text,
        botToken: _slackBotTokenCtrl.text,
        defaultChannel: _slackDefaultChannelCtrl.text,
      );
      final result = await MessagingDeliveryService().sendSlackTest(
        overrideChannel: _slackDefaultChannelCtrl.text.isNotEmpty ? _slackDefaultChannelCtrl.text : null,
      );
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(result.sent ? 'Slack test message sent!' : 'Slack test failed: ${result.message ?? "unknown"}'),
          backgroundColor: result.sent ? AppTheme.success : AppTheme.error,
        ),
      );
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('Slack test error: $e'), backgroundColor: AppTheme.error));
      }
    } finally {
      if (mounted) setState(() => _slackTestInProgress = false);
    }
  }

  // ═════════════════════════
  // Test WhatsApp
  // ═════════════════════════

  Future<void> _testWhatsApp() async {
    setState(() => _whatsAppTestInProgress = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.service.saveWhatsApp(
        enabled: _whatsAppEnabled,
        mode: _whatsAppMode,
        phoneNumberId: _whatsAppPhoneNumberIdCtrl.text,
        accessToken: _whatsAppAccessTokenCtrl.text,
        defaultRecipient: _whatsAppDefaultRecipientCtrl.text,
        callMeBotApiKey: _whatsAppCallMeBotApiKeyCtrl.text,
      );
      final result = await MessagingDeliveryService().sendWhatsAppTest(
        overrideRecipient: _whatsAppDefaultRecipientCtrl.text.isNotEmpty ? _whatsAppDefaultRecipientCtrl.text : null,
      );
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(result.sent ? 'WhatsApp test message sent!' : 'WhatsApp test failed: ${result.message ?? "unknown"}'),
          backgroundColor: result.sent ? AppTheme.success : AppTheme.error,
        ),
      );
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('WhatsApp test error: $e'), backgroundColor: AppTheme.error));
      }
    } finally {
      if (mounted) setState(() => _whatsAppTestInProgress = false);
    }
  }

  // ═══════════════════════════════════════
  // Test SSH Connection
  // ═══════════════════════════════════════

  Future<void> _testSshConnection() async {
    final host = _sshHostCtrl.text.trim();
    final username = _sshUsernameCtrl.text.trim();
    final password = _sshPasswordCtrl.text.trim();
    final port = int.tryParse(_sshPortCtrl.text.trim()) ?? 22;
    final privateKey = _sshPrivateKeyContent;

    if (host.isEmpty || username.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Enter host and username first.'), backgroundColor: Colors.orange));
      return;
    }
    setState(() => _sshTestInProgress = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      // Save first so the server can pick up the latest values.
      await widget.service.saveSsh(host: host, port: port, username: username, password: password, privateKey: privateKey);

      // Import SshMcpServer inline via the registry.
      // Using a direct import here would create a circular dep with the screen;
      // instead we drive it through a quick manual import from the server file.
      final server = await _tryConnectSsh(host: host, port: port, username: username, password: password, privateKey: privateKey);
      if (!mounted) return;
      if (server == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('SSH connection failed. Check host, port, username and password.'), backgroundColor: Colors.red),
        );
      } else {
        messenger.showSnackBar(SnackBar(content: Text('SSH connection to $host:$port succeeded!'), backgroundColor: Colors.green));
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('SSH error: $e'), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _sshTestInProgress = false);
    }
  }

  Future<bool?> _tryConnectSsh({
    required String host,
    required int port,
    required String username,
    required String password,
    String privateKey = '',
  }) async {
    try {
      final socket = await SSHSocket.connect(host, port).timeout(const Duration(seconds: 10));
      final client = SSHClient(
        socket,
        username: username,
        identities: privateKey.isNotEmpty ? SSHKeyPair.fromPem(privateKey) : null,
        onPasswordRequest: () => password,
      );
      await client.authenticated.timeout(const Duration(seconds: 15));
      client.close();
      return true;
    } catch (_) {
      return null;
    }
  }

  // ═══════════════════════════════════════════════════
  // Reusable section card with toggle + status
  // ═══════════════════════════════════════════════════

  Widget _buildSectionCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool enabled,
    required ValueChanged<bool> onToggle,
    required bool configured,
    required List<Widget> children,
  }) {
    final theme = Theme.of(context);
    return Card(
      elevation: enabled ? 2 : 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: configured
              ? AppTheme.success.withValues(alpha: 0.5)
              : enabled
              ? AppTheme.primaryBlue.withValues(alpha: 0.3)
              : theme.dividerColor.withValues(alpha: 0.3),
          width: configured ? 2 : 1,
        ),
      ),
      child: Column(
        children: [
          SwitchListTile(
            secondary: Stack(
              children: [
                Icon(icon, color: enabled ? AppTheme.primaryBlue : Colors.grey),
                if (configured) Positioned(right: -2, bottom: -2, child: Icon(Icons.check_circle, size: 14, color: AppTheme.success)),
              ],
            ),
            title: Text(
              title,
              style: TextStyle(fontWeight: FontWeight.w600, color: enabled ? null : Colors.grey),
            ),
            subtitle: Text(subtitle, style: TextStyle(fontSize: 12, color: Colors.grey[500])),
            value: enabled,
            onChanged: onToggle,
          ),
          if (enabled) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
            ),
          ],
        ],
      ),
    );
  }
}
