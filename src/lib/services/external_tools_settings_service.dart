import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../models/workflow_task.dart';
import 'app_logger.dart';

class ExternalToolsSettingsService extends ChangeNotifier {
  static final ExternalToolsSettingsService instance = ExternalToolsSettingsService._();
  ExternalToolsSettingsService._();

  @override
  void notifyListeners() {
    final binding = SchedulerBinding.instance;
    if (binding.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      binding.addPostFrameCallback((_) => super.notifyListeners());
    } else {
      super.notifyListeners();
    }
  }

  static const _storage = FlutterSecureStorage();
  static const _prefix = 'ext_tools_';
  static const _kCatalogBaseUrl = '${_prefix}catalog_base_url';
  static const _kCatalogSource = '${_prefix}catalog_source';
  static const _kSelectedServers = '${_prefix}selected_servers';
  static const _kSmitheryApiKey = '${_prefix}smithery_api_key';
  static const _kSmitheryNamespace = '${_prefix}smithery_namespace';
  static const _kSmitheryConnections = '${_prefix}smithery_connections';

  bool _loaded = false;
  String _catalogBaseUrl = 'https://registry.smithery.ai';

  /// 'pulsemcp' | 'smithery' | 'custom'
  String _catalogSource = 'pulsemcp';
  List<McpToolConfig> _selectedServers = const [];
  String _smitheryApiKey = '';
  Map<String, String> _smitheryConnections = {}; // serverUrl -> connectionId

  bool get isLoaded => _loaded;
  String get catalogBaseUrl => _catalogBaseUrl;

  /// Persisted catalog source preference: 'pulsemcp' | 'smithery' | 'custom'
  String get catalogSource => _catalogSource;
  List<McpToolConfig> get selectedServers => List.unmodifiable(_selectedServers);
  int get selectedCount => _selectedServers.length;
  bool get isConfigured => _selectedServers.isNotEmpty;
  String get smitheryApiKey => _smitheryApiKey;

  /// Returns [perServerKey] if set, otherwise falls back to the global
  /// Smithery API key when the [serverUrl] belongs to smithery.ai.
  String? resolveApiKey(String serverUrl, String? perServerKey) {
    if (perServerKey != null && perServerKey.trim().isNotEmpty) return perServerKey.trim();
    if (serverUrl.toLowerCase().contains('smithery.ai') && _smitheryApiKey.trim().isNotEmpty) {
      return _smitheryApiKey.trim();
    }
    return null;
  }

  Future<void> load() async {
    try {
      _catalogBaseUrl = (await _storage.read(key: _kCatalogBaseUrl))?.trim().isNotEmpty == true
          ? (await _storage.read(key: _kCatalogBaseUrl))!.trim()
          : 'https://registry.smithery.ai';

      final raw = await _storage.read(key: _kSelectedServers);
      if (raw != null && raw.trim().isNotEmpty) {
        final data = jsonDecode(raw) as List<dynamic>;
        _selectedServers = data.whereType<Map<String, dynamic>>().map((e) => McpToolConfig.fromJson(e)).toList();
      }
      _smitheryApiKey = (await _storage.read(key: _kSmitheryApiKey))?.trim() ?? '';
      final rawConn = await _storage.read(key: _kSmitheryConnections);
      if (rawConn != null && rawConn.trim().isNotEmpty) {
        final decoded = jsonDecode(rawConn);
        if (decoded is Map) _smitheryConnections = Map<String, String>.from(decoded);
      }
      final rawSource = await _storage.read(key: _kCatalogSource);
      if (rawSource != null && const ['pulsemcp', 'smithery', 'custom'].contains(rawSource)) {
        _catalogSource = rawSource;
      }
    } catch (e) {
      log.warning('[ExternalTools] load failed: $e');
      _catalogBaseUrl = 'https://registry.smithery.ai';
      _selectedServers = const [];
    } finally {
      _loaded = true;
      notifyListeners();
    }
  }

  Future<void> saveCatalogBaseUrl(String url) async {
    final normalized = _normalizeBaseUrl(url);
    _catalogBaseUrl = normalized;
    try {
      await _storage.write(key: _kCatalogBaseUrl, value: _catalogBaseUrl);
    } catch (e) {
      if (!Platform.isLinux || !e.toString().contains('Libsecret')) rethrow;
      log.warning('[ExtTools] Keyring unavailable, catalog URL in memory only: $e');
    }
    notifyListeners();
  }

  Future<void> saveCatalogSource(String source) async {
    _catalogSource = source;
    await _storage.write(key: _kCatalogSource, value: source);
    notifyListeners();
  }

  Future<void> saveSmitheryApiKey(String key) async {
    _smitheryApiKey = key.trim();
    try {
      await _storage.write(key: _kSmitheryApiKey, value: _smitheryApiKey);
      // Clear cached connections so they are re-created with the new key
      _smitheryConnections = {};
      await _storage.delete(key: _kSmitheryNamespace);
      await _storage.delete(key: _kSmitheryConnections);
    } catch (e) {
      if (!Platform.isLinux || !e.toString().contains('Libsecret')) rethrow;
      log.warning('[ExtTools] Keyring unavailable, Smithery key in memory only: $e');
      _smitheryConnections = {};
    }
    notifyListeners();
  }

  /// For a smithery.ai [serverUrl], resolves the final URL and optional Bearer
  /// key for the caller to use.
  ///
  /// `server.smithery.ai` endpoints authenticate via `?api_key=` query
  /// parameter (the Streamable HTTP transport does NOT accept an
  /// `Authorization: Bearer` header).  The resolved URL has the key embedded
  /// and null is returned as the header key so callers don't add a header.
  ///
  /// Non-Smithery or non-server URLs are returned with the key as a header
  /// value (existing behaviour).
  Future<(String url, String? key)> resolveSmitheryEndpoint(String serverUrl, String? perServerKey) async {
    final key = perServerKey?.trim().isNotEmpty == true ? perServerKey!.trim() : _smitheryApiKey.trim();
    if (key.isEmpty) return (serverUrl, null);

    if (serverUrl.toLowerCase().contains('server.smithery.ai')) {
      // Embed the API key as a query parameter; no Authorization header.
      final uri = Uri.parse(serverUrl);
      final params = Map<String, String>.from(uri.queryParameters)..['api_key'] = key;
      return (uri.replace(queryParameters: params).toString(), null);
    }

    return (serverUrl, key);
  }

  /// Removes the cached Smithery connection ID for [serverUrl] so that the
  /// next call to [resolveSmitheryEndpoint] will create a fresh connection.
  /// Fetches the real connection URL for a Smithery server via the registry
  /// detail API (`registry.smithery.ai/servers/{qualifiedName}`).
  /// Returns the first HTTPS HTTP/SSE connection URL found, or null on any
  /// error or if the server has no public connection URL.
  Future<String?> fetchSmitheryConnectionUrl(String qualifiedName) async {
    try {
      final uri = Uri.parse('https://registry.smithery.ai/servers/${Uri.encodeComponent(qualifiedName)}');
      final response = await http
          .get(uri, headers: const {'Accept': 'application/json', 'User-Agent': 'mobile-ai-agent/1.0'})
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      if (data is! Map<String, dynamic>) return null;
      final connections = data['connections'];
      if (connections is List) {
        for (final conn in connections.whereType<Map<String, dynamic>>()) {
          final t = (conn['type'] ?? '').toString().toLowerCase();
          // The Smithery detail API uses 'deploymentUrl' inside connections, not 'url'.
          final u = (conn['url']?.toString().trim().isNotEmpty == true ? conn['url'] : conn['deploymentUrl'])?.toString().trim() ?? '';
          if (u.startsWith('https://') && (t == 'http' || t == 'sse' || t == 'streamable_http' || t == 'streamable-http' || t.isEmpty)) {
            return u;
          }
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Fetches the Smithery detail API for [qualifiedName] and returns a
  /// human-readable authentication note (e.g. "Requires Microsoft 365 OAuth").
  /// Returns an empty string if no special auth is detected, null on error.
  Future<String?> fetchSmitheryAuthNote(String qualifiedName, String serverName) async {
    try {
      final uri = Uri.parse('https://registry.smithery.ai/servers/${Uri.encodeComponent(qualifiedName)}');
      final response = await http
          .get(uri, headers: const {'Accept': 'application/json', 'User-Agent': 'mobile-ai-agent/1.0'})
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return '';
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      if (data is! Map<String, dynamic>) return '';

      String note = '';
      String? realUrl;
      final connections = data['connections'];
      if (connections is List) {
        for (final conn in connections.whereType<Map<String, dynamic>>()) {
          final du = (conn['deploymentUrl'] ?? conn['url'] ?? '').toString().trim();
          if (du.startsWith('https://')) realUrl ??= du;

          final schema = conn['configSchema'];
          if (schema is! Map<String, dynamic>) continue;
          final props = schema['properties'] as Map<String, dynamic>?;
          if (props == null || props.isEmpty) continue;

          final oauthKeys = ['oauth', 'scope', 'client_id', 'client_secret', 'access_token', 'authorization_url'];
          for (final entry in props.entries) {
            final keyLower = entry.key.toLowerCase();
            final desc = (entry.value is Map ? (entry.value as Map)['description'] ?? '' : '').toString().toLowerCase();
            if (oauthKeys.any((k) => keyLower.contains(k) || desc.contains(k))) {
              if (desc.contains('microsoft') || (realUrl ?? '').contains('microsoft') || serverName.toLowerCase().contains('excel')) {
                note = 'Requires Microsoft 365 OAuth authentication';
              } else if (desc.contains('google')) {
                note = 'Requires Google OAuth authentication';
              } else {
                note = 'Requires OAuth authentication';
              }
              break;
            }
            if (note.isEmpty && entry.value is Map) {
              final d = (entry.value as Map)['description']?.toString() ?? '';
              if (d.isNotEmpty) note = 'Requires API key — $d';
            }
          }
          if (note.isNotEmpty) break;
        }
      }

      // Probe real deployment URL for 401/403 if schema gave no hint.
      if (note.isEmpty && realUrl != null) {
        try {
          final probe = await http
              .get(Uri.parse(realUrl), headers: const {'Accept': 'application/json'})
              .timeout(const Duration(seconds: 5));
          if (probe.statusCode == 401 || probe.statusCode == 403) {
            final body = probe.body.toLowerCase();
            if (body.contains('microsoft') ||
                body.contains('azure') ||
                body.contains('msal') ||
                realUrl.contains('microsoft') ||
                serverName.toLowerCase().contains('excel')) {
              note = 'Requires Microsoft 365 OAuth authentication';
            } else {
              note = 'Requires authentication — visit the server page for credentials';
            }
          }
        } catch (_) {}
      }

      return note;
    } catch (_) {
      return null;
    }
  }

  Future<void> invalidateSmitheryConnection(String serverUrl) async {
    if (_smitheryConnections.containsKey(serverUrl)) {
      _smitheryConnections.remove(serverUrl);
      await _storage.write(key: _kSmitheryConnections, value: jsonEncode(_smitheryConnections));
      log.info('[SmitheryConn] Invalidated cached connection for $serverUrl');
    }
  }

  Future<void> saveSelectedServers(List<McpToolConfig> servers) async {
    _selectedServers = List<McpToolConfig>.from(servers);
    try {
      await _storage.write(key: _kSelectedServers, value: jsonEncode(_selectedServers.map((e) => e.toJson()).toList()));
    } catch (e) {
      if (!Platform.isLinux || !e.toString().contains('Libsecret')) rethrow;
      log.warning('[ExtTools] Keyring unavailable, selected servers in memory only: $e');
    }
    notifyListeners();
  }

  /// Apply settings to the in-memory model only. This is used in server mode
  /// so the app can reflect remote state without persisting it locally.
  void applyInMemory({
    String? catalogBaseUrl,
    String? catalogSource,
    List<McpToolConfig>? selectedServers,
    String? smitheryApiKey,
    Map<String, String>? smitheryConnections,
  }) {
    if (catalogBaseUrl != null) {
      _catalogBaseUrl = _normalizeBaseUrl(catalogBaseUrl);
    }
    if (catalogSource != null && const ['pulsemcp', 'smithery', 'custom'].contains(catalogSource)) {
      _catalogSource = catalogSource;
    }
    if (selectedServers != null) {
      _selectedServers = List<McpToolConfig>.from(selectedServers);
    }
    if (smitheryApiKey != null) {
      _smitheryApiKey = smitheryApiKey.trim();
    }
    if (smitheryConnections != null) {
      _smitheryConnections = Map<String, String>.from(smitheryConnections);
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> upsertSelectedServer(McpToolConfig server, {String? oldServerUrl}) async {
    final normalizedUrl = _normalizeServerUrl(server.serverUrl);
    final normalizedEndpoint = _normalizeMcpEndpoint(server.mcpEndpoint);
    final normalizedServer = server.copyWith(serverUrl: normalizedUrl, mcpEndpoint: normalizedEndpoint);

    final current = List<McpToolConfig>.from(_selectedServers);
    // When the URL was changed by the user, search by the OLD URL to find the
    // existing entry; fall back to the new URL for normal (non-URL-change) saves.
    final lookupUrl = oldServerUrl != null ? _normalizeServerUrl(oldServerUrl) : normalizedUrl;
    final index = current.indexWhere((e) => _normalizeServerUrl(e.serverUrl) == lookupUrl);
    if (index >= 0) {
      current[index] = normalizedServer;
    } else {
      current.add(normalizedServer);
    }
    current.sort(
      (a, b) => (a.name?.trim().isNotEmpty == true ? a.name!.trim() : a.serverUrl).compareTo(
        b.name?.trim().isNotEmpty == true ? b.name!.trim() : b.serverUrl,
      ),
    );
    await saveSelectedServers(current);
  }

  Future<Map<String, dynamic>> testMcpServer({required String serverUrl, String? mcpEndpoint, String? apiKey, String? apiPassword}) async {
    final normalizedUrl = _normalizeServerUrl(serverUrl);
    final endpoint = _normalizeMcpEndpoint(mcpEndpoint);

    // Resolve Smithery API key (URL is returned unchanged; relay proxy is not used).
    final (_, resolvedKey) = await resolveSmitheryEndpoint(normalizedUrl, apiKey);

    final candidates = <Uri>[Uri.parse(normalizedUrl), Uri.parse('$normalizedUrl$endpoint'), Uri.parse('$normalizedUrl/.well-known/mcp')];
    final rpcCandidates = <Uri>{
      if (normalizedUrl.toLowerCase().endsWith('/mcp')) Uri.parse(normalizedUrl) else Uri.parse('$normalizedUrl$endpoint'),
      Uri.parse('$normalizedUrl$endpoint'),
    }.toList();

    final headers = <String, String>{'Accept': 'application/json, text/event-stream'};
    final key = resolvedKey ?? '';
    final pwd = apiPassword?.trim() ?? '';
    if (key.isNotEmpty) {
      headers['Authorization'] = 'Bearer $key';
    } else if (pwd.isNotEmpty) {
      headers['Authorization'] = 'Basic $pwd';
    }

    final diagnostics = <String>[];
    Object? lastError;

    for (final uri in candidates) {
      try {
        final response = await http.get(uri, headers: headers).timeout(const Duration(seconds: 8));

        final status = response.statusCode;
        if (status >= 200 && status < 500) {
          return {
            'success': true,
            'statusCode': status,
            'url': uri.toString(),
            'message': status >= 200 && status < 300
                ? 'Server reachable.'
                : 'Server reachable (HTTP $status). Authentication may be required.',
          };
        }

        diagnostics.add('GET ${uri.toString()} -> HTTP $status');
      } catch (e) {
        lastError = e;
        diagnostics.add('GET ${uri.toString()} -> ${_friendlyTestError(e)}');
      }
    }

    final rpcHeaders = <String, String>{'Content-Type': 'application/json', ...headers};
    const initBody = {
      'jsonrpc': '2.0',
      'id': 'health-check',
      'method': 'initialize',
      'params': {
        'protocolVersion': '2024-11-05',
        'capabilities': {},
        'clientInfo': {'name': 'mobile-ai-agent', 'version': '1.0.0'},
      },
    };

    for (final uri in rpcCandidates) {
      try {
        final response = await http.post(uri, headers: rpcHeaders, body: jsonEncode(initBody)).timeout(const Duration(seconds: 10));

        final status = response.statusCode;
        if (status >= 200 && status < 500) {
          return {
            'success': true,
            'statusCode': status,
            'url': uri.toString(),
            'message': status >= 200 && status < 300
                ? 'MCP endpoint reachable via JSON-RPC.'
                : 'MCP endpoint responded (HTTP $status). Authentication may be required.',
          };
        }

        diagnostics.add('POST ${uri.toString()} -> HTTP $status');
      } catch (e) {
        lastError = e;
        diagnostics.add('POST ${uri.toString()} -> ${_friendlyTestError(e)}');
      }
    }

    final diag = diagnostics.take(3).join(' | ');
    final base = _friendlyTestError(lastError);
    return {'success': false, 'message': diag.isNotEmpty ? '$base Diagnostic: $diag' : base};
  }

  /// Fetches servers from the Official MCP Registry (https://registry.modelcontextprotocol.io).
  ///
  /// PulseMCP is a key contributor to this registry and recommends it as the
  /// standard REST API for building custom applications.
  /// Set [remoteOnly] to `true` to return only servers that expose a remote
  /// HTTP MCP endpoint (have a non-empty `remotes` array).
  /// Falls back to Smithery when the registry is unreachable.
  Future<List<McpToolConfig>> searchPulseMcp({String query = '', bool remoteOnly = false}) async {
    const headers = {'Accept': 'application/json', 'User-Agent': 'mobile-ai-agent/1.0'};
    const registryBase = 'https://registry.modelcontextprotocol.io/v0';
    final q = query.trim();

    final params = <String, String>{'limit': '100'};
    if (q.isNotEmpty) params['q'] = q;

    final uri = Uri.parse('$registryBase/servers').replace(queryParameters: params);
    final response = await http.get(uri, headers: headers).timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('MCP Registry returned HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    // Do NOT fall back to Smithery — caller explicitly chose the MCP Registry.
    return _parsePulseMcpResponse(decoded, remoteOnly: remoteOnly);
  }

  Future<List<McpToolConfig>> searchCatalog({String query = '', String source = 'auto'}) async {
    final base = _normalizeBaseUrl(_catalogBaseUrl);
    final q = query.trim();
    final attempts = <String>[];
    final headers = const {'Accept': 'application/json', 'User-Agent': 'mobile-ai-agent/1.0'};

    // ── PulseMCP (explicit source) ─────────────────────────────────────────
    if (source == 'pulsemcp') {
      return searchPulseMcp(query: q);
    }

    // ── Smithery registry (explicit source) ───────────────────────────────
    if (source == 'smithery' || base.contains('smithery.ai')) {
      final registryBase = base.contains('registry.') ? base : 'https://registry.smithery.ai';
      final candidates = <Uri>[
        if (q.isNotEmpty) Uri.parse('$registryBase/servers').replace(queryParameters: {'q': q, 'pageSize': '50'}),
        Uri.parse('$registryBase/servers').replace(queryParameters: {'pageSize': '50', 'q': 'remote'}),
        Uri.parse('$registryBase/servers').replace(queryParameters: {'pageSize': '50'}),
      ];
      for (final uri in candidates) {
        try {
          final response = await http.get(uri, headers: headers).timeout(const Duration(seconds: 12));
          if (response.statusCode < 200 || response.statusCode >= 300) {
            attempts.add('HTTP \${response.statusCode} at $uri');
            continue;
          }
          final decoded = jsonDecode(utf8.decode(response.bodyBytes));
          final parsed = _parseSmitheryResponse(decoded);
          if (parsed.isNotEmpty) return parsed;
          attempts.add('No remote servers in response at $uri');
        } catch (e) {
          attempts.add('\${_friendlyTestError(e)} (at $uri)');
        }
      }
      final hint = attempts.isNotEmpty ? attempts.take(3).join(' | ') : 'No reachable endpoint.';
      throw Exception('Could not fetch server list from Smithery. $hint');
    }

    // ── Glama.ai fallback ───────────────────────────────────────────────────
    final queryParamsQ = {if (q.isNotEmpty) 'q': q};
    final queryParamsQuery = {if (q.isNotEmpty) 'query': q};
    final candidates = <Uri>[
      if (q.isNotEmpty) Uri.parse('$base/api/mcp/v1/servers').replace(queryParameters: {'first': '50', ...queryParamsQuery}),
      Uri.parse('$base/api/mcp/v1/servers').replace(queryParameters: {'first': '50'}),
      Uri.parse('$base/api/mcp/v1/servers').replace(queryParameters: {'first': '20'}),
      Uri.parse('$base/api/mcp/v1/servers').replace(queryParameters: queryParamsQuery),
      Uri.parse('$base/api/mcp/servers').replace(queryParameters: queryParamsQ),
      Uri.parse('$base/api/mcp-servers').replace(queryParameters: queryParamsQ),
      Uri.parse('$base/api/servers').replace(queryParameters: queryParamsQ),
      Uri.parse('$base/mcp/servers.json'),
    ];

    for (final uri in candidates) {
      try {
        final response = await http.get(uri, headers: headers).timeout(const Duration(seconds: 12));
        if (response.statusCode < 200 || response.statusCode >= 300) {
          attempts.add('HTTP \${response.statusCode} at $uri');
          continue;
        }
        if (response.body.trim().isEmpty) {
          attempts.add('Empty response at $uri');
          continue;
        }
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        final parsed = _parseCatalogResponse(decoded);
        if (parsed.isNotEmpty) return parsed;
        attempts.add('No MCP server URLs in response at $uri');
      } catch (e) {
        attempts.add('\${_friendlyTestError(e)} (at $uri)');
      }
    }

    final hint = attempts.isNotEmpty ? attempts.take(3).join(' | ') : 'No reachable endpoint.';
    throw Exception('Could not fetch MCP server list from $base. Public catalog may be temporarily unavailable. $hint');
  }

  /// Parse Smithery registry response — only keeps remote+deployed servers.
  /// Live endpoint = https://server.smithery.ai/{qualifiedName}/mcp
  List<McpToolConfig> _parseSmitheryResponse(dynamic decoded) {
    final serversList = decoded is Map<String, dynamic> ? (decoded['servers'] as List<dynamic>?) ?? [] : <dynamic>[];
    final seen = <String>{};
    final result = <McpToolConfig>[];

    for (final item in serversList.whereType<Map<String, dynamic>>()) {
      final remote = item['remote'] as bool? ?? false;
      final isDeployed = item['isDeployed'] as bool? ?? false;
      if (!remote || !isDeployed) continue;

      final qualifiedName = (item['qualifiedName'] as String? ?? '').trim();
      if (qualifiedName.isEmpty) continue;

      final name = (item['displayName'] as String? ?? qualifiedName).trim();
      final description = (item['description'] as String? ?? '').trim();
      final homepage = (item['homepage'] as String? ?? '').trim();

      // Resolve actual connection URL from API response first.
      // Smithery returns self-hosted servers with their own domain (e.g.
      // https://excel.run.tools) via the connections[] array.  Only fall back
      // to the server.smithery.ai proxy URL when no real URL is provided.
      // NOTE: the search endpoint returns connections:null for every server;
      // the real URL is resolved from the detail endpoint in fetchSmitheryConnectionUrl.
      String resolvedUrl = '';

      // 1. connections[].url or connections[].deploymentUrl — preferred.
      final connections = item['connections'];
      if (connections is List) {
        for (final conn in connections.whereType<Map<String, dynamic>>()) {
          final t = (conn['type'] ?? '').toString().toLowerCase();
          final u = (conn['url']?.toString().trim().isNotEmpty == true ? conn['url'] : conn['deploymentUrl'])?.toString().trim() ?? '';
          if (u.startsWith('https://') && (t == 'http' || t == 'sse' || t == 'streamable_http' || t == 'streamable-http' || t.isEmpty)) {
            resolvedUrl = u;
            break;
          }
        }
      }

      // 2. Flat URL fields (deploymentUrl, url, endpoint).
      if (resolvedUrl.isEmpty) {
        resolvedUrl = (item['deploymentUrl'] ?? item['url'] ?? item['endpoint'] ?? '').toString().trim();
      }

      // 3. Fall back to the Smithery-managed proxy URL.
      if (resolvedUrl.isEmpty || !resolvedUrl.startsWith('https://')) {
        resolvedUrl = 'https://server.smithery.ai/$qualifiedName/mcp';
      }

      // Split full endpoint URL into base + mcpEndpoint so the rest of the
      // app doesn't double-append the path (…/mcp/mcp → 404).
      String baseUrl = resolvedUrl;
      String endpoint = '/mcp';
      for (final suffix in ['/mcp', '/sse', '/v1/mcp']) {
        if (resolvedUrl.toLowerCase().endsWith(suffix)) {
          baseUrl = resolvedUrl.substring(0, resolvedUrl.length - suffix.length);
          endpoint = suffix;
          break;
        }
      }

      if (!seen.add(baseUrl)) continue;

      result.add(
        McpToolConfig(
          serverUrl: baseUrl,
          name: name,
          description: description.isNotEmpty ? description : null,
          isOnline: true, // remote+deployed — assumed reachable
          mcpEndpoint: endpoint,
          catalogPageUrl: homepage.isNotEmpty ? homepage : null,
        ),
      );
    }
    return result;
  }

  /// Parse PulseMCP API response.
  ///
  /// Handles various response shapes:
  ///   - `{ servers: [...] }` or `{ items: [...] }` or bare array
  ///
  /// Each entry may expose the MCP endpoint URL through several fields:
  ///   - `connections[].url` (preferred — typed connection list)
  ///   - `server_url`, `serverUrl`, `mcp_url`, `endpoint`, `url`
  ///
  /// When [remoteOnly] is true, entries without a parseable HTTPS remote URL
  /// are dropped. Text filtering is intentionally left to the caller
  /// (_filterCatalogResults) so this parser never returns an empty list due
  /// to an overly strict client-side query match.
  List<McpToolConfig> _parsePulseMcpResponse(dynamic decoded, {bool remoteOnly = false}) {
    final List<dynamic> serversList;
    if (decoded is Map<String, dynamic>) {
      final raw = decoded['servers'] ?? decoded['items'] ?? decoded['results'] ?? decoded['data'];
      serversList = raw is List ? raw : <dynamic>[];
    } else if (decoded is List) {
      serversList = decoded;
    } else {
      return const [];
    }

    final seen = <String>{};
    final result = <McpToolConfig>[];

    for (final entry in serversList.whereType<Map<String, dynamic>>()) {
      // Official MCP Registry wraps server data under a "server" key.
      final item = (entry['server'] is Map<String, dynamic>) ? entry['server'] as Map<String, dynamic> : entry;

      // ── Resolve remote URL ─────────────────────────────────────────────
      String serverUrl = '';

      // 1. Official MCP Registry format: remotes[].url
      final remotes = item['remotes'];
      if (remotes is List) {
        for (final r in remotes.whereType<Map<String, dynamic>>()) {
          final u = (r['url'] ?? '').toString().trim();
          if (u.startsWith('https://')) {
            serverUrl = u;
            break;
          }
        }
      }

      // 2. Legacy PulseMCP format: connections[].url
      if (serverUrl.isEmpty) {
        final connections = item['connections'];
        if (connections is List) {
          for (final conn in connections.whereType<Map<String, dynamic>>()) {
            final t = (conn['type'] ?? '').toString().toLowerCase();
            final u = (conn['url'] ?? '').toString().trim();
            if (u.startsWith('https://') && (t == 'http' || t == 'sse' || t == 'streamable_http' || t == 'streamable-http' || t.isEmpty)) {
              serverUrl = u;
              break;
            }
          }
        }
      }

      // 3. Flat URL fields as fallback.
      if (serverUrl.isEmpty) {
        serverUrl = (item['server_url'] ?? item['serverUrl'] ?? item['mcp_url'] ?? item['endpoint'] ?? '').toString().trim();
      }

      // 4. Attributes sub-object.
      if (serverUrl.isEmpty) {
        final attrs = item['attributes'];
        if (attrs is Map<String, dynamic>) {
          serverUrl = (attrs['server_url'] ?? attrs['serverUrl'] ?? attrs['url'] ?? '').toString().trim();
        }
      }

      // Remote-only: skip entries that have no remote URL.
      if (remoteOnly && serverUrl.isEmpty) continue;
      if (serverUrl.isEmpty) continue;
      if (!serverUrl.startsWith('https://') && !serverUrl.startsWith('http://')) continue;
      if (remoteOnly && !serverUrl.startsWith('https://')) continue;
      if (!seen.add(serverUrl)) continue;

      final name = (item['title'] ?? item['name'] ?? item['display_name'] ?? item['displayName'] ?? '').toString().trim();
      final description = (item['description'] ?? item['tagline'] ?? item['summary'] ?? item['short_description'] ?? '').toString().trim();

      // Homepage: prefer websiteUrl, then repository.url.
      String homepage = '';
      final repo = item['repository'];
      if (repo is Map<String, dynamic>) {
        homepage = (repo['url'] ?? '').toString().trim();
      }
      if (homepage.isEmpty) {
        homepage = (item['websiteUrl'] ?? item['source_code_url'] ?? item['homepage'] ?? item['repo_url'] ?? '').toString().trim();
      }

      // The registry's remote URL is the full MCP endpoint (e.g. https://host/mcp).
      // Split it into base URL + mcpEndpoint so the rest of the app doesn't
      // double-append the path (which produces …/mcp/mcp → 404).
      String baseUrl = serverUrl;
      String endpoint = '/mcp';
      for (final suffix in ['/mcp', '/sse', '/v1/mcp']) {
        if (serverUrl.toLowerCase().endsWith(suffix)) {
          baseUrl = serverUrl.substring(0, serverUrl.length - suffix.length);
          endpoint = suffix;
          break;
        }
      }

      result.add(
        McpToolConfig(
          serverUrl: baseUrl,
          name: name.isNotEmpty ? name : baseUrl,
          description: description.isNotEmpty ? description : null,
          isOnline: true,
          mcpEndpoint: endpoint,
          catalogPageUrl: homepage.isNotEmpty ? homepage : null,
        ),
      );
    }
    return result;
  }

  List<McpToolConfig> _parseCatalogResponse(dynamic decoded) {
    final maps = <Map<String, dynamic>>[];

    if (decoded is List) {
      maps.addAll(decoded.whereType<Map<String, dynamic>>());
    } else if (decoded is Map<String, dynamic>) {
      for (final key in const ['servers', 'items', 'results', 'data']) {
        final value = decoded[key];
        if (value is List) {
          maps.addAll(value.whereType<Map<String, dynamic>>());
        }
      }
      if (maps.isEmpty) {
        maps.add(decoded);
      }
    }

    final seen = <String>{};
    final result = <McpToolConfig>[];

    for (final m in maps) {
      final name = (m['name'] ?? m['title'] ?? m['id'] ?? 'MCP Server').toString().trim();
      final description = (m['description'] ?? m['shortDescription'] ?? m['summary'] ?? m['tagline'] ?? '').toString().trim();
      final isOnline = _parseOnlineStatus(m);
      var serverUrl = (m['server_url'] ?? m['serverUrl'] ?? m['mcp_url'] ?? m['endpoint'] ?? m['url'] ?? '').toString().trim();
      if (serverUrl.isEmpty) continue;
      if (!serverUrl.startsWith('http://') && !serverUrl.startsWith('https://')) {
        serverUrl = 'https://$serverUrl';
      }
      if (seen.add(serverUrl)) {
        result.add(
          McpToolConfig(
            serverUrl: serverUrl,
            name: name,
            description: description.isNotEmpty ? description : null,
            isOnline: isOnline,
            mcpEndpoint: '/mcp',
          ),
        );
      }
    }

    return result;
  }

  String _normalizeBaseUrl(String url) {
    var v = url.trim();
    if (v.isEmpty) return 'https://glama.ai';
    if (!v.startsWith('http://') && !v.startsWith('https://')) {
      v = 'https://$v';
    }
    if (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    return v;
  }

  bool? _parseOnlineStatus(Map<String, dynamic> source) {
    final direct = source['is_online'] ?? source['isOnline'] ?? source['online'] ?? source['reachable'];
    final parsedDirect = _coerceBool(direct);
    if (parsedDirect != null) return parsedDirect;

    final status = source['status'];
    if (status is bool || status is num || status is String) {
      return _coerceBool(status);
    }
    if (status is Map<String, dynamic>) {
      for (final key in const ['online', 'is_online', 'isOnline', 'reachable', 'healthy']) {
        final parsed = _coerceBool(status[key]);
        if (parsed != null) return parsed;
      }
      final state = status['state']?.toString().toLowerCase().trim();
      if (state == 'online' || state == 'healthy' || state == 'ok' || state == 'up') return true;
      if (state == 'offline' || state == 'down' || state == 'unhealthy') return false;
    }

    return null;
  }

  bool? _coerceBool(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final v = value.toLowerCase().trim();
      if (v == 'true' || v == '1' || v == 'online' || v == 'up' || v == 'healthy' || v == 'ok') return true;
      if (v == 'false' || v == '0' || v == 'offline' || v == 'down' || v == 'unhealthy') return false;
    }
    return null;
  }

  String _normalizeServerUrl(String url) {
    var v = url.trim();
    if (v.isEmpty) return v;
    if (!v.startsWith('http://') && !v.startsWith('https://')) {
      v = 'https://$v';
    }
    if (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    return v;
  }

  String _normalizeMcpEndpoint(String? endpoint) {
    var e = endpoint?.trim() ?? '/mcp';
    if (e.isEmpty) e = '/mcp';
    if (!e.startsWith('/')) e = '/$e';
    return e;
  }

  String _friendlyTestError(Object? error) {
    final raw = (error ?? '').toString();
    final lower = raw.toLowerCase();

    if (lower.contains('certificate_verify_failed') ||
        lower.contains('unable to get local issuer certificate') ||
        lower.contains('handshakeexception') ||
        lower.contains('handshake error')) {
      return 'TLS certificate verification failed. The server certificate chain is not trusted by Android. Fix server SSL (install full chain/intermediate certs) or use a certificate from a public CA.';
    }

    if (lower.contains('name not resolved') || lower.contains('failed host lookup') || lower.contains('nodename nor servname provided')) {
      return 'Host could not be resolved. Check the server URL and DNS.';
    }

    if (lower.contains('connection refused')) {
      return 'Connection refused. Server is reachable but not accepting connections on this URL/port.';
    }

    if (lower.contains('timed out') || lower.contains('timeout')) {
      return 'Connection timed out. Check network reachability, firewall, and server availability.';
    }

    if (lower.contains('400') || lower.contains('401') || lower.contains('403')) {
      return 'Server responded but denied/invalid request. Check MCP endpoint path and authentication.';
    }

    return raw.isNotEmpty ? 'Could not reach MCP server: $raw' : 'Could not reach MCP server.';
  }
}
