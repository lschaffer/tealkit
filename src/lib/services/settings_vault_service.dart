import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:pointycastle/export.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../database/task_database_service_duckdb.dart';
import '../models/workflow_task.dart';
import '../utils/credential_cipher.dart';

import 'app_logger.dart';
import 'server_api_client.dart';
import 'app_preferences_service.dart';
import 'data_sources_settings_service.dart';
import 'embedded_llm/embedded_model.dart';
import 'embedded_llm/embedded_model_manager.dart';
import 'external_tools_settings_service.dart';
import 'js_tool_library_service.dart';
import 'llm_settings_service.dart';
import 'local_shell_script_service.dart';
import 'playground_sessions_service.dart';
import 'powershell_script_service.dart';
import 'shell_script_service.dart';
import 'function_hint_database_service.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// TealKit Settings Vault
// ═══════════════════════════════════════════════════════════════════════════════
//
// Vault binary format:
//   [0–7]    8-byte ASCII magic  "TKVLT2\n\n"
//   [8–23]   16-byte random salt  (PBKDF2 input)
//   [24–39]  16-byte random IV    (AES-CBC input)
//   [40+]    AES-256-CBC ciphertext of UTF-8 JSON payload
//
// Key derivation: PBKDF2-HMAC-SHA256, 200 000 iterations, 32-byte output.
//
// Payload JSON always contains "_magic": "tealkit_settings_v1" as a
// wrong-password detector (checked after decryption; decryption never throws
// if you pass the wrong key to AES-CBC — it just produces garbage).
// ═══════════════════════════════════════════════════════════════════════════════

const _kFileMagic = 'TKVLT2\n\n';
const _kPayloadMagic = 'tealkit_settings_v1';
const _kFileExtension = 'tkv';
const _kPbkdf2Iterations = 200000;
const _kKeyLength = 32; // AES-256
const _kSaltLength = 16;
const _kIvLength = 16;

// ─── Exceptions ───────────────────────────────────────────────────────────────

class VaultException implements Exception {
  final String message;
  const VaultException(this.message);
  @override
  String toString() => message;
}

/// Controls which sections are included in a vault export / restored on import.
class VaultOptions {
  final bool includeConfiguration;
  final bool includeScripts;
  final bool includeTasks;
  final bool includePlaygroundSessions;
  final bool includeSkills;
  const VaultOptions({
    this.includeConfiguration = true,
    this.includeScripts = true,
    this.includeTasks = true,
    this.includePlaygroundSessions = true,
    this.includeSkills = true,
  });
  const VaultOptions.configurationOnly()
    : includeConfiguration = true,
      includeScripts = false,
      includeTasks = false,
      includePlaygroundSessions = false,
      includeSkills = false;
}

// ─── Service ──────────────────────────────────────────────────────────────────

class SettingsVaultService {
  SettingsVaultService._();
  static final instance = SettingsVaultService._();

  // ─── PBKDF2-HMAC-SHA256 ───────────────────────────────────────────────────

  /// Derives a 32-byte key from [password] and [salt] using PBKDF2-HMAC-SHA256
  /// with [_kPbkdf2Iterations] iterations.
  Uint8List _deriveKey(String password, Uint8List salt) {
    final dk = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64));
    dk.init(Pbkdf2Parameters(salt, _kPbkdf2Iterations, _kKeyLength));
    return dk.process(Uint8List.fromList(utf8.encode(password)));
  }

  // ─── Encryption helpers ───────────────────────────────────────────────────

  PaddedBlockCipherImpl _makeCipher(Uint8List keyBytes, Uint8List ivBytes, bool forEncryption) {
    final cipher = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()));
    cipher.init(forEncryption, PaddedBlockCipherParameters(ParametersWithIV(KeyParameter(keyBytes), ivBytes), null));
    return cipher;
  }

  Uint8List _encrypt(String plaintext, Uint8List keyBytes, Uint8List ivBytes) {
    return _makeCipher(keyBytes, ivBytes, true).process(Uint8List.fromList(utf8.encode(plaintext)));
  }

  String _decrypt(Uint8List ciphertext, Uint8List keyBytes, Uint8List ivBytes) {
    return utf8.decode(_makeCipher(keyBytes, ivBytes, false).process(ciphertext));
  }

  // ─── Payload collection ───────────────────────────────────────────────────

  Future<Map<String, dynamic>> _collectSettings() async {
    final llm = LlmSettingsService.instance;
    final ds = DataSourcesSettingsService.instance;
    final ext = ExternalToolsSettingsService.instance;
    final prefs = AppPreferencesService.instance;

    return {
      '_magic': _kPayloadMagic,
      '_exportedAt': DateTime.now().toIso8601String(),
      'llm': {
        'provider': llm.provider.configKey,
        'model': llm.model,
        'apiKey': llm.apiKey,
        'baseUrl': llm.baseUrl,
        'temperature': llm.temperature,
        'maxTokens': llm.maxTokens,
        'maxToolOutputSize': llm.maxToolOutputSize,
        'tokenWarningThreshold': llm.tokenWarningThreshold,
        // Per-provider keys/URLs/models
        'perProvider': {
          for (final p in LlmProvider.values)
            if (p != LlmProvider.none) p.configKey: {'apiKey': llm.getApiKeyForProvider(p), 'baseUrl': llm.getBaseUrlForProvider(p)},
        },
        // LLM 2 (secondary model for code generation)
        'llm2': {
          'provider': llm.provider2.configKey,
          'model': llm.model2,
          'apiKey': llm.apiKey2,
          'baseUrl': llm.baseUrl2,
          'temperature': llm.temperature2,
          'maxTokens': llm.maxTokens2,
        },
      },
      'dataSources': {
        'emailProvider': ds.emailProvider.configKey,
        'emailEnabled': ds.emailEnabled,
        'gmailClientId': ds.gmailClientId,
        'gmailClientSecret': ds.gmailClientSecret,
        'gmailAccessToken': ds.gmailAccessToken,
        'gmailRefreshToken': ds.gmailRefreshToken,
        'gmailAccountEmail': ds.gmailAccountEmail,
        'imapHost': ds.imapHost,
        'imapPort': ds.imapPort,
        'imapUsername': ds.imapUsername,
        'imapPassword': ds.imapPassword,
        'imapUseSsl': ds.imapUseSsl,
        'smtpHost': ds.smtpHost,
        'smtpPort': ds.smtpPort,
        'smtpSender': ds.smtpSender,
        'notificationEmailEnabled': ds.notificationEmailEnabled,
        'webSearchProvider': ds.webSearchProvider.configKey,
        'webSearchEnabled': ds.webSearchEnabled,
        'webSearchApiKey': ds.webSearchApiKey,
        'webSearchMaxResults': ds.webSearchMaxResults,
        'webSearchCustomProviderName': ds.webSearchCustomProviderName,
        'webSearchCustomEndpoint': ds.webSearchCustomEndpoint,
        'googleDriveEnabled': ds.googleDriveEnabled,
        'oneDriveEnabled': ds.oneDriveEnabled,
        'oneDriveClientId': ds.oneDriveClientId,
        'oneDriveTenantId': ds.oneDriveTenantId,
        'locationLat': ds.locationLatitude,
        'locationLng': ds.locationLongitude,
        'sshHost': ds.sshHost,
        'sshPort': ds.sshPort,
        'sshUsername': ds.sshUsername,
        'sshPassword': ds.sshPassword,
        'sshPrivateKey': ds.sshPrivateKey,
        'slackEnabled': ds.slackEnabled,
        'slackWebhookUrl': ds.slackWebhookUrl,
        'slackBotToken': ds.slackBotToken,
        'slackDefaultChannel': ds.slackDefaultChannel,
        'whatsAppEnabled': ds.whatsAppEnabled,
        'whatsAppMode': ds.whatsAppMode,
        'whatsAppPhoneNumberId': ds.whatsAppPhoneNumberId,
        'whatsAppAccessToken': ds.whatsAppAccessToken,
        'whatsAppDefaultRecipient': ds.whatsAppDefaultRecipient,
        'whatsAppCallMeBotApiKey': ds.whatsAppCallMeBotApiKey,
        'homeAssistantBaseUrl': ds.haBaseUrl,
        'homeAssistantToken': ds.haToken,
        'websiteIndexUrls': ds.websiteIndexUrls,
        'websiteIndexMaxPages': ds.websiteIndexMaxPages,
        'websiteIndexCron': ds.websiteIndexCron,
        'documentRootPaths': ds.documentRootPaths,
        'documentFileTypes': ds.documentFileTypes,
        'documentIndexCron': ds.documentIndexCron,
        'duckDbIndexSizeLimitGb': ds.duckDbIndexSizeLimitGb,
      },
      'externalTools': {
        'smitheryApiKey': ext.smitheryApiKey,
        'catalogBaseUrl': ext.catalogBaseUrl,
        'selectedServers': ext.selectedServers.map((s) => s.toJson()).toList(),
      },
      'appPreferences': {
        'themeMode': prefs.themeMode.name,
        'locale': prefs.locale,
        'defaultOutputPath': prefs.defaultOutputPath,
        'outputRetentionDays': prefs.outputRetentionDays,
      },
    };
  }

  // ─── Payload restoration ──────────────────────────────────────────────────

  Future<void> _restoreSettings(Map<String, dynamic> data) async {
    final llm = LlmSettingsService.instance;
    final ds = DataSourcesSettingsService.instance;
    final ext = ExternalToolsSettingsService.instance;

    // LLM
    final llmData = data['llm'] as Map<String, dynamic>?;
    if (llmData != null) {
      await llm.save(
        provider: LlmProvider.fromConfigKey(llmData['provider'] as String?),
        model: (llmData['model'] as String?) ?? '',
        apiKey: (llmData['apiKey'] as String?) ?? '',
        baseUrl: (llmData['baseUrl'] as String?) ?? '',
        temperature: (llmData['temperature'] as num?)?.toDouble() ?? 0.2,
        maxTokens: (llmData['maxTokens'] as int?) ?? 16384,
        maxToolOutputSize: (llmData['maxToolOutputSize'] as int?) ?? 2560000,
        tokenWarningThreshold: (llmData['tokenWarningThreshold'] as int?) ?? 1500000,
      );

      // Restore per-provider API keys / base URLs stored in the vault.
      // save() only writes the active provider; this fills in the rest so
      // background isolates can pick up any provider stored in the vault.
      final perProvider = llmData['perProvider'];
      if (perProvider is Map<String, dynamic>) {
        final typed = <String, Map<String, dynamic>>{};
        for (final kv in perProvider.entries) {
          final v = kv.value;
          if (v is Map<String, dynamic>) typed[kv.key] = v;
        }
        if (typed.isNotEmpty) {
          await llm.savePerProviderSecrets(typed);
        }
      }

      // LLM 2
      final llm2Data = llmData['llm2'] as Map<String, dynamic>?;
      if (llm2Data != null) {
        await llm.save2(
          provider: LlmProvider.fromConfigKey(llm2Data['provider'] as String?),
          model: (llm2Data['model'] as String?) ?? '',
          apiKey: (llm2Data['apiKey'] as String?) ?? '',
          baseUrl: (llm2Data['baseUrl'] as String?) ?? '',
          temperature: (llm2Data['temperature'] as num?)?.toDouble() ?? 0.2,
          maxTokens: (llm2Data['maxTokens'] as int?) ?? 16384,
        );
      }
    }

    // Data Sources
    final dsData = data['dataSources'] as Map<String, dynamic>?;
    if (dsData != null) {
      final s = dsData;
      await ds.saveEmail(
        provider: EmailProvider.fromConfigKey(s['emailProvider'] as String?),
        enabled: (s['emailEnabled'] as bool?) ?? false,
        gmailClientId: (s['gmailClientId'] as String?) ?? '',
        gmailClientSecret: (s['gmailClientSecret'] as String?) ?? '',
        imapHost: (s['imapHost'] as String?) ?? '',
        imapPort: (s['imapPort'] as int?) ?? 993,
        imapUsername: (s['imapUsername'] as String?) ?? '',
        imapPassword: (s['imapPassword'] as String?) ?? '',
        imapUseSsl: (s['imapUseSsl'] as bool?) ?? true,
        smtpHost: (s['smtpHost'] as String?) ?? '',
        smtpPort: (s['smtpPort'] as int?) ?? 587,
        smtpSender: (s['smtpSender'] as String?) ?? '',
        notificationEmailEnabled: (s['notificationEmailEnabled'] as bool?) ?? false,
      );
      if ((s['gmailAccessToken'] as String?)?.isNotEmpty == true) {
        await ds.saveGmailOAuthTokens(
          accessToken: (s['gmailAccessToken'] as String?) ?? '',
          refreshToken: (s['gmailRefreshToken'] as String?) ?? '',
          accountEmail: (s['gmailAccountEmail'] as String?) ?? '',
        );
      }
      await ds.saveWebSearch(
        provider: WebSearchProvider.fromConfigKey(s['webSearchProvider'] as String?),
        enabled: (s['webSearchEnabled'] as bool?) ?? false,
        apiKey: (s['webSearchApiKey'] as String?) ?? '',
        engineId: '',
        maxResults: (s['webSearchMaxResults'] as int?) ?? 5,
        customProviderName: (s['webSearchCustomProviderName'] as String?) ?? '',
        customEndpoint: (s['webSearchCustomEndpoint'] as String?) ?? '',
      );
      await ds.saveCloudStorage(
        googleDriveEnabled: (s['googleDriveEnabled'] as bool?) ?? false,
        oneDriveEnabled: (s['oneDriveEnabled'] as bool?) ?? false,
        oneDriveClientId: (s['oneDriveClientId'] as String?) ?? '',
        oneDriveTenantId: (s['oneDriveTenantId'] as String?) ?? '',
      );
      final lat = (s['locationLat'] as num?)?.toDouble();
      final lng = (s['locationLng'] as num?)?.toDouble();
      if (lat != null && lng != null) {
        await ds.saveLocation(lat, lng);
      }
      await ds.saveSsh(
        host: (s['sshHost'] as String?) ?? '',
        port: (s['sshPort'] as int?) ?? 22,
        username: (s['sshUsername'] as String?) ?? '',
        password: (s['sshPassword'] as String?) ?? '',
        privateKey: (s['sshPrivateKey'] as String?) ?? '',
      );
      await ds.saveSlack(
        enabled: (s['slackEnabled'] as bool?) ?? false,
        webhookUrl: (s['slackWebhookUrl'] as String?) ?? '',
        botToken: (s['slackBotToken'] as String?) ?? '',
        defaultChannel: (s['slackDefaultChannel'] as String?) ?? '',
      );
      await ds.saveWhatsApp(
        enabled: (s['whatsAppEnabled'] as bool?) ?? false,
        mode: (s['whatsAppMode'] as String?) ?? 'meta',
        phoneNumberId: (s['whatsAppPhoneNumberId'] as String?) ?? '',
        accessToken: (s['whatsAppAccessToken'] as String?) ?? '',
        defaultRecipient: (s['whatsAppDefaultRecipient'] as String?) ?? '',
        callMeBotApiKey: (s['whatsAppCallMeBotApiKey'] as String?) ?? '',
      );
      await ds.saveHomeAssistant(baseUrl: (s['homeAssistantBaseUrl'] as String?) ?? '', token: (s['homeAssistantToken'] as String?) ?? '');
      await ds.saveWebsiteIndex(
        urls: (s['websiteIndexUrls'] as String?) ?? '',
        maxPages: (s['websiteIndexMaxPages'] as int?) ?? 100,
        cron: (s['websiteIndexCron'] as String?) ?? '',
      );
      await ds.saveDocumentIndex(
        rootPaths: (s['documentRootPaths'] as String?) ?? '',
        fileTypes: (s['documentFileTypes'] as String?) ?? 'pdf,md,docx',
        cron: (s['documentIndexCron'] as String?) ?? '',
      );
      final duckDbSize = (s['duckDbIndexSizeLimitGb'] as num?)?.toDouble();
      if (duckDbSize != null) {
        await ds.saveDuckDbSettings(indexSizeLimitGb: duckDbSize.clamp(0.1, 50.0));
      }
    }

    // External tools
    final extData = data['externalTools'] as Map<String, dynamic>?;
    if (extData != null) {
      final apiKey = (extData['smitheryApiKey'] as String?) ?? '';
      if (apiKey.isNotEmpty) await ext.saveSmitheryApiKey(apiKey);
      final baseUrl = (extData['catalogBaseUrl'] as String?) ?? '';
      if (baseUrl.isNotEmpty) await ext.saveCatalogBaseUrl(baseUrl);
      final rawServers = extData['selectedServers'] as List<dynamic>?;
      if (rawServers != null) {
        final servers = rawServers.whereType<Map<String, dynamic>>().map(McpToolConfig.fromJson).toList();
        await ext.saveSelectedServers(servers);
      }
    }

    log.info('[SettingsVault] Restore complete.');
  }

  // ─── Extended payload collection / restore with options ──────────────────

  Future<Map<String, dynamic>> _collectPayload(VaultOptions options, {ServerApiClient? serverClient}) async {
    final payload = <String, dynamic>{
      '_magic': _kPayloadMagic,
      '_exportedAt': DateTime.now().toIso8601String(),
      '_sections': [
        if (options.includeConfiguration) 'configuration',
        if (options.includeScripts) 'scripts',
        if (options.includeTasks) 'tasks',
        if (options.includePlaygroundSessions) 'playground_sessions',
        if (options.includeSkills) 'skills',
      ],
    };

    if (options.includeConfiguration) {
      final sharedPrefs = await SharedPreferences.getInstance();
      final serverApiKey = sharedPrefs.getString('server_api_key') ?? '';
      payload['serverApiKey'] = serverApiKey;

      if (serverClient != null) {
        try {
          final remoteDs = await serverClient.getDataSourcesSettings();
          final remoteLlm = await serverClient.getLlmSettings();
          final remoteExt = await serverClient.getExternalToolsSettings();
          payload['llm'] = _buildVaultLlmFromRemote(remoteLlm);
          payload['dataSources'] = _buildVaultDataSourcesFromRemote(remoteDs);
          payload['externalTools'] = _buildVaultExternalToolsFromRemote(remoteExt);
          payload['appPreferences'] = {
            'themeMode': AppPreferencesService.instance.themeMode.name,
            'locale': AppPreferencesService.instance.locale,
            'defaultOutputPath': AppPreferencesService.instance.defaultOutputPath,
            'outputRetentionDays': AppPreferencesService.instance.outputRetentionDays,
          };
          log.info('[SettingsVault] Fetched settings from server for export.');
        } catch (e) {
          log.warning('[SettingsVault] Could not fetch server settings for export, using local: $e');
          final config = await _collectSettings();
          for (final key in ['llm', 'dataSources', 'externalTools', 'appPreferences']) {
            if (config.containsKey(key)) payload[key] = config[key];
          }
        }
      } else {
        final config = await _collectSettings();
        for (final key in ['llm', 'dataSources', 'externalTools', 'appPreferences']) {
          if (config.containsKey(key)) payload[key] = config[key];
        }
      }
    }

    if (options.includeScripts) {
      await ScriptLibraryService.instance.load();
      await PowershellScriptService.instance.load();
      await LocalShellScriptService.instance.load();
      await JsToolLibraryService.instance.load();
      payload['scripts'] = {
        'ssh': ScriptLibraryService.instance.exportToJson(),
        'powershell': PowershellScriptService.instance.exportToJson(),
        'local_shell': LocalShellScriptService.instance.exportToJson(),
        'js': JsToolLibraryService.instance.exportToJson(),
      };
    }

    if (options.includeTasks) {
      if (serverClient != null) {
        // Server mode: export tasks from the server's DuckDB, not the local one.
        try {
          final serverTasks = await serverClient.getAllTasks();
          payload['tasks'] = serverTasks.map((t) => _decryptTaskInitParams(t.toJson())).toList();
          log.info('[SettingsVault] Exported ${serverTasks.length} tasks from server for vault.');
        } catch (e) {
          log.warning('[SettingsVault] Could not fetch server tasks for export, using local: $e');
          final db = TaskDatabaseService();
          final tasks = await db.exportTasks(stripSecrets: false);
          payload['tasks'] = tasks.map(_decryptTaskInitParams).toList();
        }
      } else {
        final db = TaskDatabaseService();
        final tasks = await db.exportTasks(stripSecrets: false);
        // Decrypt field-level encryption so the vault is self-contained and can
        // be restored on a different device (new device gets a different
        // CredentialCipher key). The vault payload is separately encrypted with
        // the user's vault password, so plain-text initParams are still secure.
        payload['tasks'] = tasks.map(_decryptTaskInitParams).toList();
      }
    }

    if (options.includePlaygroundSessions) {
      await PlaygroundSessionsService.instance.load();
      payload['playground_sessions'] = PlaygroundSessionsService.instance.exportToJson();
    }

    if (options.includeSkills) {
      payload['skills'] = await FunctionHintDatabaseService().exportToJson();
    }

    // Always include embedded model metadata (not files) when configuration is exported.
    if (options.includeConfiguration) {
      final customModels = await EmbeddedModelManager.instance.loadCustomModels();
      payload['embedded_models'] = customModels.map((m) => m.toJson()).toList();
    }

    return payload;
  }

  Map<String, dynamic> _buildVaultLlmFromRemote(Map<String, dynamic> remote) {
    return {
      'provider': remote['provider'] ?? '',
      'model': remote['model'] ?? '',
      'apiKey': remote['api_key'] ?? '',
      'baseUrl': remote['base_url'] ?? '',
      'temperature': remote['temperature'] ?? 0.2,
      'maxTokens': remote['max_tokens'] ?? 0,
      'maxToolOutputSize': remote['max_tool_output_size'] ?? 2560000,
      'tokenWarningThreshold': remote['token_warning_threshold'] ?? 1500000,
      'llm2': {
        'provider': remote['provider2'] ?? '',
        'model': remote['model2'] ?? '',
        'apiKey': remote['api_key2'] ?? '',
        'baseUrl': remote['base_url2'] ?? '',
        'temperature': remote['temperature2'] ?? 0.2,
        'maxTokens': remote['max_tokens2'] ?? 0,
      },
    };
  }

  Map<String, dynamic> _buildVaultDataSourcesFromRemote(Map<String, dynamic> remote) {
    final email = remote['email'] as Map<String, dynamic>? ?? const <String, dynamic>{};
    final webSearch = remote['web_search'] as Map<String, dynamic>? ?? const <String, dynamic>{};
    final cloudStorage = remote['cloud_storage'] as Map<String, dynamic>? ?? const <String, dynamic>{};
    final location = remote['location'] as Map<String, dynamic>? ?? const <String, dynamic>{};
    final ssh = remote['ssh'] as Map<String, dynamic>? ?? const <String, dynamic>{};
    final slack = remote['slack'] as Map<String, dynamic>? ?? const <String, dynamic>{};
    final homeAssistant = remote['home_assistant'] as Map<String, dynamic>? ?? const <String, dynamic>{};
    final whatsApp = remote['whatsapp'] as Map<String, dynamic>? ?? const <String, dynamic>{};
    final websiteIndex = remote['website_index'] as Map<String, dynamic>? ?? const <String, dynamic>{};
    final documentIndex = remote['document_index'] as Map<String, dynamic>? ?? const <String, dynamic>{};

    return {
      'emailProvider': email['provider'] ?? '',
      'emailEnabled': email['enabled'] ?? false,
      'gmailClientId': '',
      'gmailClientSecret': '',
      'gmailAccessToken': '',
      'gmailRefreshToken': '',
      'gmailAccountEmail': email['gmail_account_email'] ?? '',
      'imapHost': email['imap_host'] ?? '',
      'imapPort': email['imap_port'] ?? 993,
      'imapUsername': email['imap_username'] ?? '',
      'imapPassword': email['imap_password'] ?? '',
      'imapUseSsl': email['imap_use_ssl'] ?? true,
      'smtpHost': email['smtp_host'] ?? '',
      'smtpPort': email['smtp_port'] ?? 587,
      'smtpSender': email['smtp_sender'] ?? '',
      'notificationEmailEnabled': email['notification_email_enabled'] ?? false,
      'webSearchProvider': webSearch['provider'] ?? '',
      'webSearchEnabled': webSearch['enabled'] ?? false,
      'webSearchApiKey': webSearch['api_key'] ?? '',
      'webSearchMaxResults': webSearch['max_results'] ?? 5,
      'webSearchCustomProviderName': webSearch['custom_provider_name'] ?? '',
      'webSearchCustomEndpoint': webSearch['custom_endpoint'] ?? '',
      'googleDriveEnabled': cloudStorage['google_drive_enabled'] ?? false,
      'oneDriveEnabled': cloudStorage['one_drive_enabled'] ?? false,
      'oneDriveClientId': cloudStorage['one_drive_client_id'] ?? '',
      'oneDriveTenantId': cloudStorage['one_drive_tenant_id'] ?? '',
      'locationLat': location['lat'],
      'locationLng': location['lng'],
      'sshHost': ssh['host'] ?? '',
      'sshPort': ssh['port'] ?? 22,
      'sshUsername': ssh['username'] ?? '',
      'sshPassword': ssh['password'] ?? '',
      'sshPrivateKey': ssh['private_key'] ?? '',
      'slackEnabled': slack['enabled'] ?? false,
      'slackWebhookUrl': slack['webhook_url'] ?? '',
      'slackBotToken': slack['bot_token'] ?? '',
      'slackDefaultChannel': slack['default_channel'] ?? '',
      'whatsAppEnabled': whatsApp['enabled'] ?? false,
      'whatsAppMode': whatsApp['mode'] ?? 'meta',
      'whatsAppPhoneNumberId': whatsApp['phone_number_id'] ?? '',
      'whatsAppAccessToken': whatsApp['access_token'] ?? '',
      'whatsAppDefaultRecipient': whatsApp['default_recipient'] ?? '',
      'whatsAppCallMeBotApiKey': whatsApp['callmebot_api_key'] ?? '',
      'homeAssistantBaseUrl': homeAssistant['base_url'] ?? '',
      'homeAssistantToken': homeAssistant['token'] ?? '',
      'websiteIndexUrls': websiteIndex['urls'] ?? '',
      'websiteIndexMaxPages': websiteIndex['max_pages'] ?? 100,
      'websiteIndexCron': websiteIndex['cron'] ?? '',
      'documentRootPaths': documentIndex['root_paths'] ?? '',
      'documentFileTypes': documentIndex['file_types'] ?? 'pdf,md,docx',
      'documentIndexCron': documentIndex['cron'] ?? '',
      'duckDbIndexSizeLimitGb': webSearch['duckdb_index_size_limit_gb'] ?? 1.0,
    };
  }

  Map<String, dynamic> _buildVaultExternalToolsFromRemote(Map<String, dynamic> remote) {
    return {
      'smitheryApiKey': remote['smithery_api_key'] ?? '',
      'catalogBaseUrl': remote['catalog_base_url'] ?? 'https://registry.smithery.ai',
      'selectedServers': remote['selected_servers'] ?? const <dynamic>[],
    };
  }

  /// Decrypts [CredentialCipher]-encrypted values inside each
  /// `internal_mcps[].init_params` map so the vault payload is not tied to
  /// the source device's keychain key.
  Map<String, dynamic> _decryptTaskInitParams(Map<String, dynamic> task) {
    final t = Map<String, dynamic>.from(task);
    if (t['internal_mcps'] is List) {
      t['internal_mcps'] = (t['internal_mcps'] as List).map((e) {
        if (e is! Map) return e;
        final entry = Map<String, dynamic>.from(e as Map<String, dynamic>);
        if (entry['init_params'] is Map) {
          entry['init_params'] = CredentialCipher.instance.decryptParams(Map<String, dynamic>.from(entry['init_params'] as Map));
        }
        return entry;
      }).toList();
    }
    return t;
  }

  Future<void> _pushVaultConfigurationToServer(Map<String, dynamic> data, ServerApiClient serverClient) async {
    final llmData = data['llm'] as Map<String, dynamic>?;
    if (llmData != null) {
      final llmPayload = <String, dynamic>{};
      final provider = llmData['provider'] as String?;
      final model = llmData['model'] as String?;
      final apiKey = llmData['apiKey'] as String?;
      final baseUrl = llmData['baseUrl'] as String?;

      if (provider != null && provider.isNotEmpty && provider != 'none') llmPayload['provider'] = provider;
      if (model != null && model.isNotEmpty) llmPayload['model'] = model;
      if (apiKey != null && apiKey.isNotEmpty) llmPayload['api_key'] = apiKey;
      if (baseUrl != null && baseUrl.isNotEmpty) llmPayload['base_url'] = baseUrl;
      if (llmData['temperature'] != null) llmPayload['temperature'] = llmData['temperature'];
      if (llmData['maxTokens'] != null) llmPayload['max_tokens'] = llmData['maxTokens'];

      final llm2Data = llmData['llm2'] as Map<String, dynamic>?;
      if (llm2Data != null) {
        final p2 = llm2Data['provider'] as String?;
        final m2 = llm2Data['model'] as String?;
        final k2 = llm2Data['apiKey'] as String?;
        final b2 = llm2Data['baseUrl'] as String?;
        if (p2 != null && p2.isNotEmpty && p2 != 'none') llmPayload['provider2'] = p2;
        if (m2 != null && m2.isNotEmpty) llmPayload['model2'] = m2;
        if (k2 != null && k2.isNotEmpty) llmPayload['api_key2'] = k2;
        if (b2 != null && b2.isNotEmpty) llmPayload['base_url2'] = b2;
        if (llm2Data['temperature'] != null) llmPayload['temperature2'] = llm2Data['temperature'];
        if (llm2Data['maxTokens'] != null) llmPayload['max_tokens2'] = llm2Data['maxTokens'];
      }

      if (llmPayload.isNotEmpty) {
        await serverClient.putLlmSettings(llmPayload);
        log.info('[SettingsVault] LLM settings pushed to server from vault payload.');
      }
    }

    final s = data['dataSources'] as Map<String, dynamic>?;
    if (s != null) {
      await serverClient.putDataSourcesSettings({
        'email': {
          'provider': s['emailProvider'],
          'enabled': s['emailEnabled'],
          'imap_host': s['imapHost'],
          'imap_port': s['imapPort'],
          'imap_username': s['imapUsername'],
          'imap_password': s['imapPassword'],
          'imap_use_ssl': s['imapUseSsl'],
          'smtp_host': s['smtpHost'],
          'smtp_port': s['smtpPort'],
          'smtp_sender': s['smtpSender'],
          'notification_email_enabled': s['notificationEmailEnabled'],
        },
        'web_search': {
          'provider': s['webSearchProvider'],
          'enabled': s['webSearchEnabled'],
          'api_key': s['webSearchApiKey'],
          'max_results': s['webSearchMaxResults'],
          'custom_provider_name': s['webSearchCustomProviderName'],
          'custom_endpoint': s['webSearchCustomEndpoint'],
        },
        'location': {'lat': s['locationLat'], 'lng': s['locationLng']},
        'ssh': {
          'host': s['sshHost'],
          'port': s['sshPort'],
          'username': s['sshUsername'],
          'password': s['sshPassword'],
          'private_key': s['sshPrivateKey'],
        },
        'slack': {
          'enabled': s['slackEnabled'],
          'webhook_url': s['slackWebhookUrl'],
          'bot_token': s['slackBotToken'],
          'default_channel': s['slackDefaultChannel'],
        },
        'whatsapp': {
          'enabled': s['whatsAppEnabled'],
          'mode': s['whatsAppMode'],
          'phone_number_id': s['whatsAppPhoneNumberId'],
          'access_token': s['whatsAppAccessToken'],
          'default_recipient': s['whatsAppDefaultRecipient'],
          'callmebot_api_key': s['whatsAppCallMeBotApiKey'],
        },
        'home_assistant': {'base_url': s['homeAssistantBaseUrl'], 'token': s['homeAssistantToken']},
        'website_index': {'urls': s['websiteIndexUrls'], 'max_pages': s['websiteIndexMaxPages'], 'cron': s['websiteIndexCron']},
        'document_index': {'root_paths': s['documentRootPaths'], 'file_types': s['documentFileTypes'], 'cron': s['documentIndexCron']},
        'cloud_storage': {
          'google_drive_enabled': s['googleDriveEnabled'],
          'one_drive_enabled': s['oneDriveEnabled'],
          'one_drive_client_id': s['oneDriveClientId'],
          'one_drive_tenant_id': s['oneDriveTenantId'],
        },
      });
      log.info('[SettingsVault] Data sources pushed to server from vault payload.');
    }
  }

  Future<void> _restorePayload(Map<String, dynamic> data, VaultOptions options, {ServerApiClient? serverClient}) async {
    if (options.includeConfiguration) {
      final serverApiKey = data['serverApiKey'] as String?;
      if (serverApiKey != null && serverApiKey.isNotEmpty) {
        final sharedPrefs = await SharedPreferences.getInstance();
        await sharedPrefs.setString('server_api_key', serverApiKey);
        log.info('[SettingsVault] Restored server API key: $serverApiKey');
      }

      if (serverClient != null) {
        // Connected server mode: import writes to server only.
        // Keep local task/config storage untouched.
        await _pushVaultConfigurationToServer(data, serverClient);
      } else {
        await _restoreSettings(data);
      }
    }

    if (options.includeScripts) {
      final scriptsData = data['scripts'] as Map<String, dynamic>?;
      if (scriptsData != null) {
        final sshList = scriptsData['ssh'] as List?;
        final jsList = scriptsData['js'] as List?;
        if (serverClient != null) {
          if (sshList != null) {
            await serverClient.syncShellScripts(sshList.whereType<Map<String, dynamic>>().toList());
          }
          if (jsList != null) {
            await serverClient.syncJsTools(jsList.whereType<Map<String, dynamic>>().toList());
          }
          log.info('[SettingsVault] Script import in server mode: pushed SSH/JS scripts to server only.');
        } else {
          if (sshList != null) {
            await ScriptLibraryService.instance.load();
            await ScriptLibraryService.instance.importFromJson(sshList.whereType<Map<String, dynamic>>().toList());
          }
          if (jsList != null) {
            await JsToolLibraryService.instance.load();
            await JsToolLibraryService.instance.importFromJson(jsList.whereType<Map<String, dynamic>>().toList());
          }
          // PowerShell and Python scripts only on non-mobile platforms
          if (!Platform.isAndroid && !Platform.isIOS) {
            final psList = scriptsData['powershell'] as List?;
            if (psList != null) {
              await PowershellScriptService.instance.load();
              await PowershellScriptService.instance.importFromJson(psList.whereType<Map<String, dynamic>>().toList());
            }
            final pyList = (scriptsData['local_shell'] ?? scriptsData['python']) as List?;
            if (pyList != null) {
              await LocalShellScriptService.instance.load();
              await LocalShellScriptService.instance.importFromJson(pyList.whereType<Map<String, dynamic>>().toList());
            }
          }
        }
      }
    }

    if (options.includeTasks) {
      final rawTasks = data['tasks'] as List<dynamic>?;
      if (rawTasks != null) {
        final taskMaps = rawTasks.whereType<Map<String, dynamic>>().toList();
        if (serverClient != null) {
          // Server mode: push tasks directly to the remote server.
          // The local DuckDB must NOT be touched when the server owns the data.
          log.info('[SettingsVault] Server mode — syncing ${taskMaps.length} tasks to remote server.');
          await serverClient.syncTasks(taskMaps);
        } else {
          final db = TaskDatabaseService();
          await db.importTasks(taskMaps);
        }
      }
    }

    if (options.includePlaygroundSessions) {
      final rawSessions = data['playground_sessions'] as List<dynamic>?;
      if (rawSessions != null) {
        if (serverClient != null) {
          log.info('[SettingsVault] Playground sessions import skipped in server mode (server-only import policy).');
        } else {
          await PlaygroundSessionsService.instance.importFromJson(rawSessions.whereType<Map<String, dynamic>>().toList());
        }
      }
    }

    // Restore embedded model metadata (configuration section).
    if (options.includeConfiguration) {
      final rawModels = data['embedded_models'] as List<dynamic>?;
      if (rawModels != null) {
        final models = rawModels.whereType<Map<String, dynamic>>().map((e) => EmbeddedGgufModel.fromJson(e)).toList();
        if (models.isNotEmpty) {
          await EmbeddedModelManager.instance.saveCustomModels(models);
          log.info('[SettingsVault] Restored ${models.length} embedded model entries.');
        }
      }
    }

    if (options.includeSkills) {
      final rawSkills = data['skills'] as List<dynamic>?;
      if (rawSkills != null) {
        final records = rawSkills.whereType<Map<String, dynamic>>().toList();
        await FunctionHintDatabaseService().importFromJson(records);
        log.info('[SettingsVault] Restored ${records.length} tool skills.');
      }
    }

    log.info(
      '[SettingsVault] Restore complete '
      '(config=${options.includeConfiguration}, scripts=${options.includeScripts}, '
      'tasks=${options.includeTasks}, sessions=${options.includePlaygroundSessions}, '
      'skills=${options.includeSkills}).',
    );
  }

  // ─── Public API: encrypt → bytes ─────────────────────────────────────────

  /// Collect all settings, serialize to JSON, and encrypt with [password].
  /// When [serverClient] is not null (server mode), tasks and settings are
  /// fetched from the server before building the payload.
  /// Returns the raw vault bytes ready to be written to a `.tkv` file.
  Future<Uint8List> buildVaultBytes(String password, VaultOptions options, {ServerApiClient? serverClient}) async {
    final payload = await _collectPayload(options, serverClient: serverClient);
    final jsonStr = jsonEncode(payload);

    final rng = Random.secure();
    final salt = Uint8List.fromList(List.generate(_kSaltLength, (_) => rng.nextInt(256)));
    final ivBytes = Uint8List.fromList(List.generate(_kIvLength, (_) => rng.nextInt(256)));

    final keyBytes = await _deriveKeyAsync(password, salt);
    final ciphertext = _encrypt(jsonStr, keyBytes, ivBytes);

    final magic = utf8.encode(_kFileMagic);
    final out = BytesBuilder();
    out.add(magic);
    out.add(salt);
    out.add(ivBytes);
    out.add(ciphertext);
    return out.toBytes();
  }

  // ─── Public API: decrypt + restore ───────────────────────────────────────

  /// Read vault bytes, decrypt with [password], and restore all settings.
  /// Throws [VaultException] on wrong password, bad magic, or corrupt data.
  Future<void> restoreFromBytes(Uint8List bytes, String password) async {
    final magic = utf8.encode(_kFileMagic);
    if (bytes.length < magic.length + _kSaltLength + _kIvLength + 16) {
      throw const VaultException('Invalid vault file (too short).');
    }
    for (int i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) throw const VaultException('Not a TealKit vault file.');
    }

    final salt = bytes.sublist(magic.length, magic.length + _kSaltLength);
    final ivBytes = bytes.sublist(magic.length + _kSaltLength, magic.length + _kSaltLength + _kIvLength);
    final ciphertext = bytes.sublist(magic.length + _kSaltLength + _kIvLength);

    late Map<String, dynamic> payload;
    try {
      final keyBytes = await _deriveKeyAsync(password, salt);
      final decrypted = _decrypt(ciphertext, keyBytes, ivBytes);
      payload = jsonDecode(decrypted) as Map<String, dynamic>;
    } catch (_) {
      throw const VaultException('Wrong password or corrupted vault file.');
    }

    if (payload['_magic'] != _kPayloadMagic) {
      throw const VaultException('Wrong password (integrity check failed).');
    }

    await _restorePayload(payload, const VaultOptions());
  }

  // ─── Public API: decrypt only ─────────────────────────────────────────────

  /// Decrypt vault bytes and return the raw payload map without restoring anything.
  /// Throws [VaultException] on wrong password, bad magic, or corrupt data.
  Future<Map<String, dynamic>> decryptPayload(Uint8List bytes, String password) async {
    final magic = utf8.encode(_kFileMagic);
    if (bytes.length < magic.length + _kSaltLength + _kIvLength + 16) {
      throw const VaultException('Invalid vault file (too short).');
    }
    for (int i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) throw const VaultException('Not a TealKit vault file.');
    }
    final salt = bytes.sublist(magic.length, magic.length + _kSaltLength);
    final ivBytes = bytes.sublist(magic.length + _kSaltLength, magic.length + _kSaltLength + _kIvLength);
    final ciphertext = bytes.sublist(magic.length + _kSaltLength + _kIvLength);
    late Map<String, dynamic> payload;
    try {
      final keyBytes = await _deriveKeyAsync(password, salt);
      final decrypted = _decrypt(ciphertext, keyBytes, ivBytes);
      payload = jsonDecode(decrypted) as Map<String, dynamic>;
    } catch (_) {
      throw const VaultException('Wrong password or corrupted vault file.');
    }
    if (payload['_magic'] != _kPayloadMagic) {
      throw const VaultException('Wrong password (integrity check failed).');
    }
    return payload;
  }

  /// Restore settings from a previously decrypted [payload] map.
  /// When [serverClient] is not null and [options.includeTasks] is true, tasks
  /// are pushed to the remote server instead of the local DuckDB.
  Future<void> restoreFromPayload(Map<String, dynamic> payload, VaultOptions options, {ServerApiClient? serverClient}) async {
    await _restorePayload(payload, options, serverClient: serverClient);
  }

  // ─── Public API: file picking ──────────────────────────────────────────────

  /// Opens a directory picker on desktop; returns the Downloads path on mobile.
  /// Returns null if the user cancels.
  Future<String?> pickExportDirectory() async {
    try {
      final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Choose Export Directory');
      if (dir != null) return dir;
    } catch (e) {
      if (e.toString().contains('zenity') || e.toString().contains('kdialog') || e.toString().contains('executable')) {
        throw Exception('File dialog not available. Please install zenity:\n  sudo apt install zenity');
      }
      rethrow;
    }
    // User cancelled on desktop → return null; on mobile fall back to Downloads
    if (Platform.isAndroid || Platform.isIOS) return _mobileExportDir();
    return null;
  }

  /// Opens a file picker and returns the chosen File, or null if cancelled.
  /// Uses FileType.any on mobile to avoid the unsupported-extension error on Android.
  Future<File?> pickImportFile() async {
    final useCustom = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    final FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(
        dialogTitle: 'Open TealKit Settings Vault',
        type: useCustom ? FileType.custom : FileType.any,
        allowedExtensions: useCustom ? [_kFileExtension] : null,
      );
    } catch (e) {
      if (e.toString().contains('zenity') || e.toString().contains('kdialog') || e.toString().contains('executable')) {
        throw Exception('File dialog not available. Please install zenity:\n  sudo apt install zenity');
      }
      rethrow;
    }
    if (result == null || result.files.isEmpty) return null;
    final path = result.files.single.path;
    if (path == null) return null;
    return File(path);
  }

  // ─── Public API: encrypt → file ───────────────────────────────────────────

  /// Build vault and save to [dirPath] with [fileName] (no extension). Returns the saved file path.
  /// Pass [serverClient] in server mode so tasks and settings are fetched from the server.
  Future<String> exportToDirectory(
    String dirPath,
    String fileName,
    String password,
    VaultOptions options, {
    ServerApiClient? serverClient,
  }) async {
    final bytes = await buildVaultBytes(password, options, serverClient: serverClient);
    final file = File(p.join(dirPath, '$fileName.$_kFileExtension'));
    await file.writeAsBytes(bytes);
    log.info('[SettingsVault] Exported to ${file.path}');
    return file.path;
  }

  /// Restore settings from [file] using [password] and [options].
  Future<void> importFile(File file, String password, VaultOptions options) async {
    final bytes = await file.readAsBytes();
    final payload = await decryptPayload(bytes, password);
    await _restorePayload(payload, options);
    log.info('[SettingsVault] Imported from ${file.path}');
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  /// Run key derivation in an isolate-friendly way (compute wrapper keeps UI
  /// responsive during the 200k PBKDF2 iterations).
  Future<Uint8List> _deriveKeyAsync(String password, Uint8List salt) async {
    // Running in the main isolate is fine for now; can wrap with compute() if needed.
    return _deriveKey(password, salt);
  }

  Future<String> _mobileExportDir() async {
    if (Platform.isAndroid) {
      // Write to /storage/emulated/0/Download when accessible, fallback to app docs.
      final downloads = Directory('/storage/emulated/0/Download');
      if (await downloads.exists()) return downloads.path;
    }
    final docs = await getApplicationDocumentsDirectory();
    return docs.path;
  }
}
