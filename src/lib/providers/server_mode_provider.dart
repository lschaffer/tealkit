import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../database/task_database_service_duckdb.dart';
import '../models/workflow_task.dart';
import '../services/data_sources_settings_service.dart';
import '../services/app_logger.dart';
import '../services/external_tools_settings_service.dart';
import '../services/llm_settings_service.dart';
import '../services/scheduler_service.dart';
import '../services/server_api_client.dart';

// ═══════════════════════════════════════════════════════════════
// Models
// ═══════════════════════════════════════════════════════════════

enum ServerMode { local, remote }

enum ServerConnectPhase { connecting, loadingSettings, done }

class ServerConnectionConfig {
  final String name;
  final String url;
  final String apiKey;

  const ServerConnectionConfig({
    required this.name,
    required this.url,
    required this.apiKey,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'url': url,
        'apiKey': apiKey,
      };

  factory ServerConnectionConfig.fromJson(Map<String, dynamic> json) {
    return ServerConnectionConfig(
      name: json['name'] as String? ?? '',
      url: json['url'] as String? ?? '',
      apiKey: json['apiKey'] as String? ?? '',
    );
  }
}

class ServerModeState {
  final ServerMode mode;
  final String serverUrl;
  final String apiKey;
  final bool isConnected;
  final List<ServerConnectionConfig> connections;
  final String? activeConnectionName;

  const ServerModeState({
    this.mode = ServerMode.local,
    this.serverUrl = '',
    this.apiKey = '',
    this.isConnected = false,
    this.connections = const [],
    this.activeConnectionName,
  });

  bool get isRemote => mode == ServerMode.remote;

  ServerModeState copyWith({
    ServerMode? mode,
    String? serverUrl,
    String? apiKey,
    bool? isConnected,
    List<ServerConnectionConfig>? connections,
    String? activeConnectionName,
  }) {
    return ServerModeState(
      mode: mode ?? this.mode,
      serverUrl: serverUrl ?? this.serverUrl,
      apiKey: apiKey ?? this.apiKey,
      isConnected: isConnected ?? this.isConnected,
      connections: connections ?? this.connections,
      activeConnectionName: activeConnectionName ?? this.activeConnectionName,
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Notifier
// ═══════════════════════════════════════════════════════════════

class ServerModeNotifier extends AsyncNotifier<ServerModeState> {
  static const _kMode = 'server_mode';
  static const _kUrl = 'server_url';
  static const _kKey = 'server_api_key';
  static const _kConnections = 'server_connections';
  static const _kActiveName = 'active_server_connection_name';

  @override
  Future<ServerModeState> build() async {
    final prefs = await SharedPreferences.getInstance();
    final modeStr = prefs.getString(_kMode) ?? 'local';
    
    // Load connections
    final connJson = prefs.getString(_kConnections);
    List<ServerConnectionConfig> connections = [];
    if (connJson != null && connJson.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(connJson) as List;
        connections = decoded
            .map((item) => ServerConnectionConfig.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList();
      } catch (e) {
        log.warning('[ServerMode] Failed to decode server connections: $e');
      }
    }

    String url = prefs.getString(_kUrl) ?? '';
    String key = prefs.getString(_kKey) ?? '';
    String? activeName = prefs.getString(_kActiveName);

    // Migration: If we have a legacy server connection but no connections list, convert it.
    if (connections.isEmpty && url.isNotEmpty) {
      final defaultConn = ServerConnectionConfig(
        name: 'Default Server',
        url: url,
        apiKey: key,
      );
      connections.add(defaultConn);
      activeName = 'Default Server';
      await prefs.setString(_kConnections, jsonEncode(connections.map((c) => c.toJson()).toList()));
      await prefs.setString(_kActiveName, activeName);
    }

    // Ensure activeName matches something in the list, or default to first
    if (activeName == null && connections.isNotEmpty) {
      activeName = connections.first.name;
      url = connections.first.url;
      key = connections.first.apiKey;
      await prefs.setString(_kUrl, url);
      await prefs.setString(_kKey, key);
      await prefs.setString(_kActiveName, activeName);
    } else if (activeName != null) {
      final activeConn = connections.firstWhere((c) => c.name == activeName, orElse: () => connections.first);
      url = activeConn.url;
      key = activeConn.apiKey;
      if (activeConn.name != activeName) {
        activeName = activeConn.name;
        await prefs.setString(_kUrl, url);
        await prefs.setString(_kKey, key);
        await prefs.setString(_kActiveName, activeName);
      }
    }

    final initial = ServerModeState(
      mode: modeStr == 'remote' ? ServerMode.remote : ServerMode.local,
      serverUrl: url,
      apiKey: key,
      isConnected: false,
      connections: connections,
      activeConnectionName: activeName,
    );

    if (initial.isRemote && initial.serverUrl.isNotEmpty) {
      unawaited(_hydrateRemoteRuntimeState(initial));
      return initial;
    }
    await _loadLocalRuntimeState();
    return initial;
  }

  Future<void> _hydrateRemoteRuntimeState(ServerModeState baseline) async {
    final client = ServerApiClient(serverUrl: baseline.serverUrl, apiKey: baseline.apiKey.isNotEmpty ? baseline.apiKey : null);
    final ok = await _loadRemoteRuntimeState(client, requestTimeout: const Duration(seconds: 12));

    final current = state.value;
    if (current == null) return;
    if (!current.isRemote) return;
    if (current.serverUrl != baseline.serverUrl || current.apiKey != baseline.apiKey) return;
    state = AsyncData(current.copyWith(isConnected: ok));
  }

  Future<void> _loadLocalRuntimeState() async {
    await LlmSettingsService.instance.load();
    await DataSourcesSettingsService.instance.load();
    await ExternalToolsSettingsService.instance.load();
  }

  Future<bool> _loadRemoteRuntimeState(ServerApiClient client, {Duration? requestTimeout}) async {
    var isConnected = false;
    try {
      isConnected = await client.validateAuthorization(timeout: requestTimeout);
    } catch (e) {
      log.warning('[ServerMode] Authorization check failed: $e');
    }

    try {
      final llm = await client.getLlmSettings(timeout: requestTimeout);
      LlmSettingsService.instance.applyRemoteState(llm);
    } catch (e) {
      log.warning('[ServerMode] Failed to load remote LLM settings: $e');
    }

    try {
      final dataSources = await client.getDataSourcesSettings(timeout: requestTimeout);
      DataSourcesSettingsService.instance.applyRemoteState(dataSources);
    } catch (e) {
      log.warning('[ServerMode] Failed to load remote data sources: $e');
    }

    try {
      final external = await client.getExternalToolsSettings(timeout: requestTimeout);
      final servers = (external['selected_servers'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<Map>()
          .map((entry) => McpToolConfig.fromJson(Map<String, dynamic>.from(entry)))
          .toList();
      ExternalToolsSettingsService.instance.applyInMemory(
        catalogBaseUrl: external['catalog_base_url'] as String?,
        catalogSource: external['catalog_source'] as String?,
        selectedServers: servers,
        smitheryApiKey: external['smithery_api_key'] as String?,
      );
    } catch (e) {
      log.warning('[ServerMode] Failed to load remote external tools: $e');
    }

    return isConnected;
  }

  /// Test the connection and update [isConnected].
  Future<bool> ping() async {
    final current = state.value;
    if (current == null || !current.isRemote || current.serverUrl.isEmpty) {
      return false;
    }
    final client = ServerApiClient(serverUrl: current.serverUrl, apiKey: current.apiKey.isNotEmpty ? current.apiKey : null);
    final ok = await client.validateAuthorization();
    state = AsyncData(current.copyWith(isConnected: ok));
    return ok;
  }

  /// Connect using a specific connection configuration.
  Future<bool> connect(ServerConnectionConfig conn, {void Function(ServerConnectPhase phase)? onPhase}) async {
    onPhase?.call(ServerConnectPhase.connecting);
    final prefs = await SharedPreferences.getInstance();

    final client = ServerApiClient(serverUrl: conn.url, apiKey: conn.apiKey.isNotEmpty ? conn.apiKey : null);

    log.info('[ServerMode] Connecting to ${conn.name} (${conn.url})...');

    final serverReachable = await client.ping();
    if (!serverReachable) {
      log.warning('[ServerMode] Server not reachable after health check');
      return false;
    }

    final ok = await client.validateAuthorization(timeout: const Duration(seconds: 15));
    log.info('[ServerMode] Connection ${ok ? "OK" : "FAILED"}');
    if (!ok) {
      return false;
    }

    await prefs.setString(_kMode, 'remote');
    await prefs.setString(_kUrl, conn.url);
    await prefs.setString(_kKey, conn.apiKey);
    await prefs.setString(_kActiveName, conn.name);

    final current = state.value;
    state = AsyncData(
      (current ?? const ServerModeState()).copyWith(
        mode: ServerMode.remote,
        serverUrl: conn.url,
        apiKey: conn.apiKey,
        activeConnectionName: conn.name,
        isConnected: true,
      ),
    );

    onPhase?.call(ServerConnectPhase.loadingSettings);
    await _loadRemoteRuntimeState(client);
    await appScheduler.cancelAll();
    log.info('[ServerMode] Local scheduler cancelled in remote mode');
    onPhase?.call(ServerConnectPhase.done);
    return ok;
  }

  /// Switch back to local mode.
  Future<void> disconnect() async {
    final current = state.value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kMode, 'local');
    state = AsyncData(
      (current ?? const ServerModeState()).copyWith(
        mode: ServerMode.local,
        isConnected: false,
      ),
    );
    await _loadLocalRuntimeState();
    final tasks = await TaskDatabaseService().getAllTasks();
    await appScheduler.syncAllTasks(tasks);
    log.info('[ServerMode] Switched to local mode');
  }

  // ── Connection Management ────────────────────────────────────

  Future<void> addConnection(ServerConnectionConfig conn) async {
    final current = state.value;
    if (current == null) return;

    final updated = List<ServerConnectionConfig>.from(current.connections)..add(conn);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kConnections, jsonEncode(updated.map((c) => c.toJson()).toList()));

    state = AsyncData(current.copyWith(connections: updated));
    log.info('[ServerMode] Added connection: ${conn.name}');
  }

  Future<void> editConnection(String oldName, ServerConnectionConfig conn) async {
    final current = state.value;
    if (current == null) return;

    final updated = current.connections.map((c) {
      if (c.name == oldName) return conn;
      return c;
    }).toList();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kConnections, jsonEncode(updated.map((c) => c.toJson()).toList()));

    String? activeName = current.activeConnectionName;
    String activeUrl = current.serverUrl;
    String activeKey = current.apiKey;

    if (activeName == oldName) {
      activeName = conn.name;
      activeUrl = conn.url;
      activeKey = conn.apiKey;
      await prefs.setString(_kUrl, activeUrl);
      await prefs.setString(_kKey, activeKey);
      await prefs.setString(_kActiveName, activeName);
    }

    state = AsyncData(
      current.copyWith(
        connections: updated,
        activeConnectionName: activeName,
        serverUrl: activeUrl,
        apiKey: activeKey,
      ),
    );
    log.info('[ServerMode] Edited connection from $oldName to ${conn.name}');
  }

  Future<void> removeConnection(String name) async {
    final current = state.value;
    if (current == null) return;

    final updated = current.connections.where((c) => c.name != name).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kConnections, jsonEncode(updated.map((c) => c.toJson()).toList()));

    String? activeName = current.activeConnectionName;
    String activeUrl = current.serverUrl;
    String activeKey = current.apiKey;
    ServerMode mode = current.mode;

    if (activeName == name) {
      if (updated.isNotEmpty) {
        activeName = updated.first.name;
        activeUrl = updated.first.url;
        activeKey = updated.first.apiKey;
        await prefs.setString(_kUrl, activeUrl);
        await prefs.setString(_kKey, activeKey);
        await prefs.setString(_kActiveName, activeName);
      } else {
        activeName = null;
        activeUrl = '';
        activeKey = '';
        mode = ServerMode.local;
        await prefs.setString(_kMode, 'local');
        await prefs.remove(_kUrl);
        await prefs.remove(_kKey);
        await prefs.remove(_kActiveName);
      }
    }

    state = AsyncData(
      current.copyWith(
        mode: mode,
        connections: updated,
        activeConnectionName: activeName,
        serverUrl: activeUrl,
        apiKey: activeKey,
        isConnected: activeName == null ? false : current.isConnected,
      ),
    );
    log.info('[ServerMode] Removed connection: $name');
  }
}

// ═══════════════════════════════════════════════════════════════
// Providers
// ═══════════════════════════════════════════════════════════════

final serverModeProvider = AsyncNotifierProvider<ServerModeNotifier, ServerModeState>(ServerModeNotifier.new);

/// Convenience provider: the ServerApiClient for the current remote server.
/// Returns `null` when in local mode.
final serverApiClientProvider = Provider<ServerApiClient?>((ref) {
  final modeAsync = ref.watch(serverModeProvider);
  return modeAsync.whenOrNull(
    data: (state) {
      if (!state.isRemote || state.serverUrl.isEmpty) return null;
      return ServerApiClient(serverUrl: state.serverUrl, apiKey: state.apiKey.isNotEmpty ? state.apiKey : null);
    },
  );
});
