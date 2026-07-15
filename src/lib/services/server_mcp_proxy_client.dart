import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/mcp_models.dart';
import 'server_api_client.dart';

/// MCP client adapter that proxies tool discovery/calls to the TealKit server
/// MCP proxy API in Server Mode.
class ServerMcpProxyClient extends ChangeNotifier {
  final ServerApiClient _api;
  final String serverId;
  final Map<String, dynamic> initParams;

  bool _isConnected = false;
  List<MCPTool> _availableTools = const [];

  ServerMcpProxyClient({required ServerApiClient api, required this.serverId, Map<String, dynamic>? initParams})
    : _api = api,
      initParams = Map<String, dynamic>.unmodifiable(Map<String, dynamic>.from(initParams ?? const <String, dynamic>{}));

  bool get isConnected => _isConnected;
  List<MCPTool> get availableTools => List.unmodifiable(_availableTools);

  Future<void> connect() async {
    // Start (or ensure started) on server.
    try {
      await _api.startMcpServer(serverId, initParams: initParams);
    } on ApiException catch (e) {
      // 409 means already running, which is fine.
      if (e.statusCode != 409) rethrow;
    }

    final rawTools = await _api.getMcpServerTools(serverId);
    _availableTools = rawTools.map(MCPTool.fromJson).toList();
    _isConnected = true;
    notifyListeners();
  }

  Future<void> disconnect() async {
    if (!_isConnected) return;
    try {
      await _api.stopMcpServer(serverId);
    } catch (_) {
      // Best effort: server process cleanup is not fatal for client lifecycle.
    }
    _isConnected = false;
    notifyListeners();
  }

  Future<MCPToolResult> callTool(String name, Map<String, dynamic> arguments) async {
    if (!_isConnected) {
      throw StateError('Server MCP proxy client is not connected: $serverId');
    }
    final result = await _api.callMcpServerTool(serverId, name, arguments);
    return MCPToolResult.fromJson(result);
  }

  @override
  void dispose() {
    unawaited(disconnect());
    super.dispose();
  }
}
