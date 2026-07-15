import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/server_config_service.dart';
import '../models/agentic_task.dart';
import '../utils/server_logger.dart';

class ServerExternalToolsService {
  static final ServerExternalToolsService instance = ServerExternalToolsService._();
  ServerExternalToolsService._();

  static const _prefix = 'ext_tools_';
  static const _kCatalogBaseUrl = '${_prefix}catalog_base_url';
  static const _kCatalogSource = '${_prefix}catalog_source';
  static const _kSelectedServers = '${_prefix}selected_servers';
  static const _kSmitheryApiKey = '${_prefix}smithery_api_key';
  static const _kSmitheryConnections = '${_prefix}smithery_connections';

  String _catalogBaseUrl = 'https://registry.smithery.ai';
  String _catalogSource = 'pulsemcp';
  List<McpToolConfig> _selectedServers = const [];
  String _smitheryApiKey = '';
  // ignore: unused_field
  Map<String, String> _smitheryConnections = {};

  String get catalogBaseUrl => _catalogBaseUrl;
  String get catalogSource => _catalogSource;
  List<McpToolConfig> get selectedServers => List.unmodifiable(_selectedServers);
  int get selectedCount => _selectedServers.length;
  bool get isConfigured => _selectedServers.isNotEmpty;
  String get smitheryApiKey => _smitheryApiKey;

  String? resolveApiKey(String serverUrl, String? perServerKey) {
    if (perServerKey != null && perServerKey.trim().isNotEmpty) return perServerKey.trim();
    if (serverUrl.toLowerCase().contains('smithery.ai') && _smitheryApiKey.trim().isNotEmpty) {
      return _smitheryApiKey.trim();
    }
    return null;
  }

  // ── Load ─────────────────────────────────────────
  Future<void> load() async {
    final cfg = ServerConfigService();

    final catalogUrlRaw = cfg.getSecret(_kCatalogBaseUrl) ?? cfg.getString(_kCatalogBaseUrl);
    _catalogBaseUrl = (catalogUrlRaw?.trim().isNotEmpty == true)
        ? _normalizeBaseUrl(catalogUrlRaw!.trim())
        : 'https://registry.smithery.ai';

    final rawServers = cfg.getSecret(_kSelectedServers) ?? cfg.getString(_kSelectedServers);
    if (rawServers != null && rawServers.trim().isNotEmpty) {
      try {
        final data = jsonDecode(rawServers) as List<dynamic>;
        _selectedServers = data.whereType<Map<String, dynamic>>().map((e) => McpToolConfig.fromJson(e)).toList();
      } catch (e) {
        log.warning('[ExternalTools] Failed to decode selected servers: $e');
        _selectedServers = const [];
      }
    }

    _smitheryApiKey = (cfg.getSecret(_kSmitheryApiKey) ?? '').trim();

    final rawConn = cfg.getSecret(_kSmitheryConnections) ?? cfg.getString(_kSmitheryConnections);
    if (rawConn != null && rawConn.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(rawConn);
        if (decoded is Map) _smitheryConnections = Map<String, String>.from(decoded);
      } catch (_) {}
    }

    final rawSource = cfg.getString(_kCatalogSource);
    if (rawSource != null && const ['pulsemcp', 'smithery', 'custom'].contains(rawSource)) {
      _catalogSource = rawSource;
    }

    log.info('[ExternalTools] Loaded – ${_selectedServers.length} servers, source=$_catalogSource');
  }

  // ── Save helpers ─────────────────────────────────
  Future<void> saveCatalogBaseUrl(String url) async {
    _catalogBaseUrl = _normalizeBaseUrl(url);
    await ServerConfigService().setString(_kCatalogBaseUrl, _catalogBaseUrl);
  }

  Future<void> saveCatalogSource(String source) async {
    _catalogSource = source;
    await ServerConfigService().setString(_kCatalogSource, source);
  }

  Future<void> saveSmitheryApiKey(String key) async {
    _smitheryApiKey = key.trim();
    await ServerConfigService().setSecret(_kSmitheryApiKey, _smitheryApiKey);
    _smitheryConnections = {};
  }

  Future<void> saveSelectedServers(List<McpToolConfig> servers) async {
    _selectedServers = servers;
    final json = jsonEncode(servers.map((s) => s.toJson()).toList());
    await ServerConfigService().setSecret(_kSelectedServers, json);
  }

  // ── Smithery endpoint resolution ──────────────────
  Future<(String url, String? key)> resolveSmitheryEndpoint(String serverUrl, String? perServerKey) async {
    final key = perServerKey?.trim().isNotEmpty == true ? perServerKey!.trim() : _smitheryApiKey.trim();
    if (key.isEmpty) return (serverUrl, null);

    if (serverUrl.toLowerCase().contains('server.smithery.ai')) {
      final uri = Uri.parse(serverUrl);
      final params = Map<String, String>.from(uri.queryParameters)..['api_key'] = key;
      return (uri.replace(queryParameters: params).toString(), null);
    }

    return (serverUrl, key);
  }

  Future<String?> fetchSmitheryConnectionUrl(String qualifiedName) async {
    try {
      final uri = Uri.parse('https://registry.smithery.ai/servers/${Uri.encodeComponent(qualifiedName)}');
      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;
      final data = jsonDecode(response.body) as Map<String, dynamic>?;
      if (data == null) return null;
      final connections = data['connections'] as List<dynamic>?;
      if (connections == null) return null;
      for (final c in connections) {
        if (c is Map<String, dynamic>) {
          final type = c['type']?.toString() ?? '';
          final url = c['url']?.toString() ?? '';
          if ((type == 'http' || type == 'sse') && url.startsWith('https://')) {
            return url;
          }
        }
      }
    } catch (e) {
      log.warning('[ExternalTools] fetchSmitheryConnectionUrl failed: $e');
    }
    return null;
  }

  // ── Helpers ──────────────────────────────────────
  static String _normalizeBaseUrl(String url) {
    var u = url.trim();
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      u = 'https://$u';
    }
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }
}
