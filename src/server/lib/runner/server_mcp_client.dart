import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../models/mcp_models.dart';
import '../utils/server_logger.dart';

/// Headless MCP client (HTTP/SSE transport only).
///
/// No [ChangeNotifier] — uses a simple callback for state changes.
/// Drop-in replacement for the Flutter MCPClient inside the server runner.
class ServerMcpClient {
  final String serverUrl;
  final String? bearerToken;

  String? _effectiveBearerToken;
  final http.Client _httpClient = http.Client();
  bool _isConnected = false;
  String? _sessionId;
  bool _isDisposed = false;

  final Uuid _uuid = const Uuid();

  List<MCPTool> _availableTools = [];
  List<MCPResource> _availableResources = [];

  // Reconnection bookkeeping
  bool _isReconnecting = false;
  int _reconnectionAttempts = 0;
  static const int _maxReconnectionAttempts = 5;
  static const Duration _reconnectionDelay = Duration(seconds: 5);
  static const Duration _healthCheckInterval = Duration(seconds: 30);
  Timer? _healthCheckTimer;

  /// Called when the connection state changes.
  void Function(bool connected)? onConnectionChanged;

  ServerMcpClient(this.serverUrl, {this.bearerToken}) : _effectiveBearerToken = bearerToken;

  // ── URL helpers ─────────────────────────────────────────────

  String get _normalizedUrl => serverUrl.trim().replaceAll(RegExp(r'/+$'), '');

  Uri _rpcUri() {
    final uri = Uri.parse(_normalizedUrl);
    if (uri.path.toLowerCase().endsWith('/mcp')) return uri;
    return uri.replace(path: '${uri.path}/mcp');
  }

  Uri _healthUri() {
    final uri = Uri.parse(_normalizedUrl);
    if (uri.path.toLowerCase().endsWith('/mcp')) {
      return uri.replace(path: uri.path.replaceFirst(RegExp(r'/mcp$', caseSensitive: false), '/health'));
    }
    return uri.replace(path: '${uri.path}/health');
  }

  // ── Headers ─────────────────────────────────────────────────

  Map<String, String> _headers({Map<String, String>? extra}) {
    final h = <String, String>{'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream'};
    if (_effectiveBearerToken != null) {
      final token = _effectiveBearerToken!.trim();
      if (token.contains(':')) {
        final bytes = utf8.encode(token);
        final base64Str = base64.encode(bytes);
        h['Authorization'] = 'Basic $base64Str';
      } else {
        h['Authorization'] = 'Bearer $token';
      }
    }
    if (_sessionId != null) h['Mcp-Session-Id'] = _sessionId!;
    if (extra != null) h.addAll(extra);
    return h;
  }

  // ── SSE helper ───────────────────────────────────────────────

  static String _extractFirstSseData(String body) {
    for (final line in body.split('\n')) {
      final t = line.trim();
      if (t.startsWith('data: ') && t.length > 6) {
        final json = t.substring(6).trim();
        if (json.isNotEmpty && json != '[DONE]') return json;
      }
    }
    return body;
  }

  // ── Public API ───────────────────────────────────────────────

  bool get isConnected => _isConnected;
  List<MCPTool> get availableTools => List.unmodifiable(_availableTools);
  List<MCPResource> get availableResources => List.unmodifiable(_availableResources);

  /// Connect and load capabilities.
  Future<void> connect() async {
    if (_isDisposed) throw Exception('Client is already disposed');
    try {
      await _testConnection();
      if (_isDisposed) return;
      _isConnected = true;
      _reconnectionAttempts = 0;
      onConnectionChanged?.call(true);
      await _initialize();
      if (_isDisposed) return;
      await _loadCapabilities();
      if (_isDisposed) return;
      _startHealthCheck();
      log.info('[ServerMcpClient] Connected: $serverUrl');
    } catch (e) {
      if (!_isDisposed) {
        log.error('[ServerMcpClient] connect failed: $e');
      }
      _isConnected = false;
      rethrow;
    }
  }

  Future<void> disconnect() async {
    _isConnected = false;
    _stopHealthCheck();
    onConnectionChanged?.call(false);
  }

  void dispose() {
    _isDisposed = true;
    disconnect();
    _httpClient.close();
  }

  /// Call a tool by name.
  Future<MCPToolResult> callTool(String name, Map<String, dynamic> arguments) async {
    final request = MCPRequest(id: _uuid.v4(), method: 'tools/call', params: {'name': name, 'arguments': arguments});
    final response = await _sendRequest(request);

    // Preserve structured MCP tool results (content list with typed items)
    // so downstream UI can render images/files directly.
    if (response is Map<String, dynamic> && response['content'] is List) {
      return MCPToolResult.fromJson(response);
    }

    if (response != null) {
      final content = <Map<String, dynamic>>[];
      if (response is String) {
        content.add({'type': 'text', 'text': response});
      } else {
        content.add({'type': 'text', 'text': jsonEncode(response)});
      }
      return MCPToolResult(content: content.map(MCPContent.fromJson).toList(), isError: false);
    }
    return const MCPToolResult(
      content: [MCPContent(type: 'text', text: '{"success":false,"error":"No response from server"}')],
      isError: true,
    );
  }

  /// Read an MCP resource.
  Future<String> readResource(String uri) async {
    final request = MCPRequest(id: _uuid.v4(), method: 'resources/read', params: {'uri': uri});
    final response = await _sendRequest(request);
    final contents = response?['contents'] as List?;
    if (contents != null && contents.isNotEmpty) {
      return (contents.first as Map<String, dynamic>?)?['text'] as String? ?? '';
    }
    return '';
  }

  // ── Internal ─────────────────────────────────────────────────

  Future<void> _testConnection() async {
    try {
      final r = await _httpClient.get(_healthUri(), headers: _headers()).timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) throw Exception('Health returned ${r.statusCode}');
    } catch (_) {
      await _probeRpc();
    }
  }

  Future<void> _probeRpc() async {
    final body = jsonEncode({
      'jsonrpc': '2.0',
      'method': 'initialize',
      'id': 'probe',
      'params': {
        'protocolVersion': '2024-11-05',
        'capabilities': {},
        'clientInfo': {'name': 'TealKit Server MCP Client', 'version': '1.0.0'},
      },
    });
    var r = await _httpClient.post(_rpcUri(), headers: _headers(), body: body).timeout(const Duration(seconds: 30));
    if (r.statusCode == 401 && _effectiveBearerToken != null) {
      log.info('[ServerMcpClient] 401 probe, retrying without auth');
      _effectiveBearerToken = null;
      r = await _httpClient.post(_rpcUri(), headers: _headers(), body: body).timeout(const Duration(seconds: 30));
    }
    if (r.statusCode != 200) throw Exception('MCP probe failed: HTTP ${r.statusCode}');
  }

  Future<void> _initialize() async {
    final body = jsonEncode({
      'jsonrpc': '2.0',
      'id': _uuid.v4(),
      'method': 'initialize',
      'params': {
        'protocolVersion': '2024-11-05',
        'capabilities': {
          'roots': {'listChanged': true},
          'sampling': {},
          'tools': {'listChanged': true},
          'resources': {'listChanged': true},
        },
        'clientInfo': {'name': 'TealKit Server MCP Client', 'version': '1.0.0'},
      },
    });
    final r = await _httpClient.post(_rpcUri(), headers: _headers(), body: body).timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) throw Exception('Initialize failed: HTTP ${r.statusCode}');
    final sessionId = r.headers['mcp-session-id'];
    if (sessionId != null && sessionId.isNotEmpty) {
      _sessionId = sessionId;
      log.info('[ServerMcpClient] Session: $sessionId');
    }
    await _sendNotification('notifications/initialized');
  }

  Future<void> _loadCapabilities() async {
    final toolsResp = await _sendRequest(MCPRequest(id: _uuid.v4(), method: 'tools/list'));
    if (toolsResp?['tools'] != null) {
      _availableTools = (toolsResp!['tools'] as List).map((t) => MCPTool.fromJson(t as Map<String, dynamic>)).toList();
    }
    try {
      final resResp = await _sendRequest(MCPRequest(id: _uuid.v4(), method: 'resources/list'));
      if (resResp?['resources'] != null) {
        _availableResources = (resResp!['resources'] as List).map((r) => MCPResource.fromJson(r as Map<String, dynamic>)).toList();
      }
    } catch (e) {
      log.warning('[ServerMcpClient] resources/list not supported: $e');
    }
    log.info('[ServerMcpClient] ${_availableTools.length} tools, ${_availableResources.length} resources loaded');
  }

  Future<dynamic> _sendRequest(MCPRequest request) async {
    if (_isDisposed) throw Exception('Client is already disposed');
    if (!_isConnected) throw Exception('Not connected to MCP server @ $serverUrl');
    try {
      final r = await _httpClient
          .post(_rpcUri(), headers: _headers(), body: jsonEncode(request.toJson()))
          .timeout(const Duration(seconds: 30));
      if (_isDisposed) throw Exception('Client is already disposed');
      if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}: ${r.reasonPhrase}');
      final ct = r.headers['content-type'] ?? '';
      final raw = ct.contains('text/event-stream') ? _extractFirstSseData(r.body) : r.body;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      if (data.containsKey('error')) {
        final err = data['error'];
        throw Exception('MCP error: ${err is Map ? err['message'] ?? err : err}');
      }
      return data['result'];
    } catch (e) {
      if (_isDisposed) throw Exception('Client is already disposed');
      final msg = e.toString();
      if (msg.contains('Connection') || msg.contains('Socket') || msg.contains('Timeout') || msg.contains('Failed host lookup')) {
        if (_isConnected) {
          _isConnected = false;
          onConnectionChanged?.call(false);
          _attemptReconnection();
        }
      }
      rethrow;
    }
  }

  Future<void> _sendNotification(String method, [Map<String, dynamic>? params]) async {
    if (!_isConnected) return;
    try {
      final body = <String, dynamic>{'jsonrpc': '2.0', 'method': method};
      if (params != null) body['params'] = params;
      await _httpClient.post(_rpcUri(), headers: _headers(), body: jsonEncode(body)).timeout(const Duration(seconds: 10));
    } catch (e) {
      log.warning('[ServerMcpClient] notification failed: $e');
    }
  }

  void _startHealthCheck() {
    _stopHealthCheck();
    _healthCheckTimer = Timer.periodic(_healthCheckInterval, (_) => _performHealthCheck());
  }

  void _stopHealthCheck() {
    _healthCheckTimer?.cancel();
    _healthCheckTimer = null;
  }

  Future<void> _performHealthCheck() async {
    if (_isDisposed || !_isConnected) return;
    try {
      await _testConnection();
    } catch (e) {
      if (_isDisposed) return;
      log.warning('[ServerMcpClient] health check failed: $e');
      _isConnected = false;
      onConnectionChanged?.call(false);
      _attemptReconnection();
    }
  }

  Future<void> _attemptReconnection() async {
    if (_isDisposed) return;
    if (_isReconnecting || _reconnectionAttempts >= _maxReconnectionAttempts) return;
    _isReconnecting = true;
    _reconnectionAttempts++;
    final delay = Duration(seconds: (_reconnectionDelay.inSeconds * _reconnectionAttempts).clamp(5, 60));
    log.info('[ServerMcpClient] Reconnect attempt $_reconnectionAttempts in ${delay.inSeconds}s');
    await Future.delayed(delay);
    if (_isDisposed) {
      _isReconnecting = false;
      return;
    }
    try {
      await connect();
    } catch (e) {
      if (!_isDisposed) {
        log.error('[ServerMcpClient] Reconnect attempt $_reconnectionAttempts failed: $e');
      }
    } finally {
      _isReconnecting = false;
    }
  }
}
