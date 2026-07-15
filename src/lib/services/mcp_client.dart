import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import '../models/mcp_models.dart';
import '../utils/logger.dart';

/// MCP Client for connecting to Model Context Protocol servers via HTTP
class MCPClient extends ChangeNotifier {
  final String serverUrl;
  final String? bearerToken;

  /// Effective token used for requests — may be cleared to null if the server
  /// returns 401, which indicates it is a free server that rejects auth headers.
  String? _effectiveBearerToken;
  final http.Client _httpClient = http.Client();
  final StreamController<MCPMessage> _messageController = StreamController<MCPMessage>.broadcast();
  bool _isConnected = false;
  final Uuid _uuid = const Uuid();

  List<MCPTool> _availableTools = [];
  List<MCPResource> _availableResources = [];

  // Reconnection management
  Timer? _healthCheckTimer;
  bool _isReconnecting = false;
  int _reconnectionAttempts = 0;
  static const int _maxReconnectionAttempts = 5;
  static const Duration _healthCheckInterval = Duration(seconds: 30);
  static const Duration _reconnectionDelay = Duration(seconds: 5);

  /// Session ID for stateful Streamable HTTP transport (MCP 2025).
  String? _sessionId;

  MCPClient(this.serverUrl, {this.bearerToken}) : _effectiveBearerToken = bearerToken;

  String get _normalizedServerUrl {
    final trimmed = serverUrl.trim();
    return trimmed.replaceAll(RegExp(r'/+$'), '');
  }

  Uri _rpcUri() {
    final uri = Uri.parse(_normalizedServerUrl);
    if (uri.path.toLowerCase().endsWith('/mcp')) return uri;
    return uri.replace(path: '${uri.path}/mcp');
  }

  Uri _healthUri() {
    final uri = Uri.parse(_normalizedServerUrl);
    if (uri.path.toLowerCase().endsWith('/mcp')) {
      return uri.replace(path: uri.path.replaceFirst(RegExp(r'/mcp$', caseSensitive: false), '/health'));
    }
    return uri.replace(path: '${uri.path}/health');
  }

  /// Get headers with optional authorization
  Map<String, String> _getHeaders({Map<String, String>? additionalHeaders}) {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      // Include text/event-stream so servers using Streamable HTTP transport
      // (MCP 2025) can respond with SSE instead of rejecting with 406.
      'Accept': 'application/json, text/event-stream',
    };

    if (_effectiveBearerToken != null) {
      headers['Authorization'] = 'Bearer $_effectiveBearerToken';
    }

    // Forward session ID for Streamable HTTP transport (MCP 2025).
    if (_sessionId != null) {
      headers['Mcp-Session-Id'] = _sessionId!;
    }

    if (additionalHeaders != null) {
      headers.addAll(additionalHeaders);
    }

    return headers;
  }

  /// Extracts the JSON payload from the first `data:` line of an SSE body.
  /// Used when the server responds with Content-Type: text/event-stream
  /// (Streamable HTTP transport, MCP 2025).
  static String _extractFirstSseData(String sseBody) {
    for (final line in sseBody.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith('data: ') && trimmed.length > 6) {
        final json = trimmed.substring(6).trim();
        if (json.isNotEmpty && json != '[DONE]') return json;
      }
    }
    return sseBody;
  }

  // Getters
  Stream<MCPMessage> get messageStream => _messageController.stream;
  bool get isConnected => _isConnected;
  List<MCPTool> get availableTools => List.unmodifiable(_availableTools);
  List<MCPResource> get availableResources => List.unmodifiable(_availableResources);

  /// Connect to the MCP server
  Future<void> connect() async {
    try {
      // Test HTTP connection
      await _testConnection();

      _isConnected = true;
      _reconnectionAttempts = 0;
      notifyListeners();

      // Initialize MCP session
      await _initialize();

      // Load available tools and resources
      await _loadCapabilities();

      // Start periodic health checks
      _startHealthCheck();

      talker.log('MCP Client connected successfully via HTTP');
    } catch (e) {
      talker.error('Failed to connect to MCP server: $e');
      _isConnected = false;
      rethrow;
    }
  }

  /// Test HTTP connection to MCP server.
  ///
  /// For URLs that already end with `/mcp` (e.g. Smithery managed-connection
  /// proxy URLs like `https://api.smithery.ai/connect/{ns}/{id}/mcp`) there is
  /// no separate `/health` endpoint — skip straight to the RPC reachability
  /// check so we don't waste 10 s on a guaranteed timeout.
  Future<void> _testConnection() async {
    final isMcpEndpoint = Uri.parse(_normalizedServerUrl).path.toLowerCase().endsWith('/mcp');

    if (isMcpEndpoint) {
      // No /health for MCP-endpoint URLs — probe the MCP endpoint directly.
      final probeBody = jsonEncode({
        'jsonrpc': '2.0',
        'method': 'initialize',
        'id': 'probe',
        'params': {
          'protocolVersion': '2024-11-05',
          'capabilities': {},
          'clientInfo': {'name': 'Flutter MCP Client', 'version': '1.0.0'},
        },
      });
      try {
        var response = await _httpClient.post(_rpcUri(), headers: _getHeaders(), body: probeBody).timeout(const Duration(seconds: 30));
        // Free servers (e.g. Smithery free tier) reject auth headers with 401.
        // Clear the token and retry without auth so these servers connect.
        if (response.statusCode == 401 && _effectiveBearerToken != null) {
          talker.info('[MCPClient] Got 401 on probe, retrying without auth — $serverUrl');
          _effectiveBearerToken = null;
          response = await _httpClient.post(_rpcUri(), headers: _getHeaders(), body: probeBody).timeout(const Duration(seconds: 30));
        }
        if (response.statusCode != 200) {
          throw Exception('MCP probe failed: HTTP ${response.statusCode}');
        }
      } catch (e) {
        throw Exception('Connection test failed: $e');
      }
      return;
    }

    // For regular servers try /health first, fall back to RPC probe.
    try {
      final response = await _httpClient.get(_healthUri(), headers: _getHeaders()).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        throw Exception('Server returned status ${response.statusCode}');
      }
    } catch (e) {
      try {
        final response = await _httpClient
            .post(
              _rpcUri(),
              headers: _getHeaders(),
              body: jsonEncode({
                'jsonrpc': '2.0',
                'method': 'initialize',
                'id': 'probe',
                'params': {
                  'protocolVersion': '2024-11-05',
                  'capabilities': {},
                  'clientInfo': {'name': 'Flutter MCP Client', 'version': '1.0.0'},
                },
              }),
            )
            .timeout(const Duration(seconds: 10));
        if (response.statusCode != 200) {
          throw Exception('MCP endpoint test failed: ${response.statusCode}');
        }
      } catch (testError) {
        throw Exception('Connection test failed: $testError');
      }
    }
  }

  /// Initialize MCP session with handshake
  Future<void> _initialize() async {
    final initBody = jsonEncode({
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
        'clientInfo': {'name': 'Flutter MCP Client', 'version': '1.0.0'},
      },
    });

    // Use raw HTTP POST so we can capture the Mcp-Session-Id response header
    // (required by Streamable HTTP transport, MCP 2025).  _sendRequest does
    // not expose response headers, so we replicate its logic here.
    final response = await _httpClient.post(_rpcUri(), headers: _getHeaders(), body: initBody).timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      throw Exception('Initialize failed: HTTP ${response.statusCode}');
    }

    // Capture session ID if the server returned one.
    final sessionId = response.headers['mcp-session-id'];
    if (sessionId != null && sessionId.isNotEmpty) {
      _sessionId = sessionId;
      talker.info('[MCPClient] Session established: $sessionId');
    }

    // Send initialized notification
    await _sendNotification('notifications/initialized');
  }

  /// Load available tools and resources from server
  Future<void> _loadCapabilities() async {
    // tools/list is mandatory — propagate errors so connect() can detect the
    // failure and the caller does NOT register a broken (0-tool) client.
    final toolsResponse = await _sendRequest(MCPRequest(id: _uuid.v4(), method: 'tools/list'));
    if (toolsResponse['tools'] != null) {
      _availableTools = (toolsResponse['tools'] as List).map((tool) => MCPTool.fromJson(tool)).toList();
    }

    // resources/list is optional — swallow errors per MCP spec.
    try {
      final resourcesResponse = await _sendRequest(MCPRequest(id: _uuid.v4(), method: 'resources/list'));

      if (resourcesResponse['resources'] != null) {
        _availableResources = (resourcesResponse['resources'] as List).map((resource) => MCPResource.fromJson(resource)).toList();
      }
    } catch (e) {
      talker.warning('Resources not supported by server: $e');
    }

    talker.info('Loaded ${_availableTools.length} tools and ${_availableResources.length} resources');
    notifyListeners();
  }

  /// Send a request via HTTP and wait for response
  Future<dynamic> _sendRequest(MCPRequest request) async {
    if (!_isConnected) {
      throw Exception('Not connected to MCP server');
    }

    try {
      final response = await _httpClient
          .post(_rpcUri(), headers: _getHeaders(), body: jsonEncode(request.toJson()))
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}: ${response.reasonPhrase}');
      }

      // Handle Streamable HTTP (SSE) responses transparently.
      final contentType = response.headers['content-type'] ?? '';
      final rawBody = contentType.contains('text/event-stream') ? _extractFirstSseData(response.body) : response.body;
      final responseData = jsonDecode(rawBody) as Map<String, dynamic>;
      // Log only first 200 chars of response to avoid flooding logs
      final responseStr = responseData.toString();
      final responsePreview = responseStr.length > 200 ? '${responseStr.substring(0, 200)}...' : responseStr;
      talker.debug('MCP Server Response: $responsePreview');

      if (responseData.containsKey('error')) {
        final error = responseData['error'];
        talker.error('MCP Server Error: $error');
        throw Exception('Server error: ${error['message'] ?? error.toString()}');
      }

      final result = responseData['result'];
      // Log only first 100 chars of result to avoid flooding logs
      final resultStr = result.toString();
      final resultPreview = resultStr.length > 100 ? '${resultStr.substring(0, 100)}...' : resultStr;
      talker.debug('MCP Result: $resultPreview');
      return result;
    } catch (e) {
      // Check if this is a connection-related error
      if (e.toString().contains('Connection') ||
          e.toString().contains('SocketException') ||
          e.toString().contains('TimeoutException') ||
          e.toString().contains('Failed host lookup')) {
        // Mark as disconnected and trigger reconnection
        if (_isConnected) {
          _isConnected = false;
          notifyListeners();
          _attemptReconnection();
        }
      }

      throw Exception('MCP request failed: $e');
    }
  }

  /// Send a notification via HTTP (fire and forget)
  Future<void> _sendNotification(String method, [Map<String, dynamic>? params]) async {
    if (!_isConnected) return;

    try {
      final notification = <String, dynamic>{'jsonrpc': '2.0', 'method': method, 'params': params}
        ..removeWhere((key, value) => value == null);

      await _httpClient.post(_rpcUri(), headers: _getHeaders(), body: jsonEncode(notification)).timeout(const Duration(seconds: 10));
    } catch (e) {
      talker.error('Failed to send notification: $e');
    }
  }

  /// Call a specific MCP tool
  Future<MCPToolResult> callTool(String name, Map<String, dynamic> arguments) async {
    final request = MCPRequest(id: _uuid.v4(), method: 'tools/call', params: {'name': name, 'arguments': arguments});

    final response = await _sendRequest(request);

    // Preserve structured MCP tool responses when available.
    // This is required for binary/image outputs where content items carry
    // type/data/mimeType fields used by the UI renderer.
    if (response is Map<String, dynamic> && response['content'] is List) {
      return MCPToolResult.fromJson(response);
    }

    // Fallback: non-MCP payloads are wrapped as plain text.
    if (response != null) {
      final content = <Map<String, dynamic>>[];

      // Convert response to text content
      if (response is String) {
        content.add({'type': 'text', 'text': response});
      } else {
        content.add({'type': 'text', 'text': jsonEncode(response)});
      }

      return MCPToolResult(content: content.map((item) => MCPContent.fromJson(item)).toList(), isError: false);
    }

    // Handle null response
    return const MCPToolResult(
      content: [MCPContent(type: 'text', text: '{"success": false, "error": "No response from server"}')],
      isError: true,
    );
  }

  /// Read a specific MCP resource
  Future<String> readResource(String uri) async {
    final request = MCPRequest(id: _uuid.v4(), method: 'resources/read', params: {'uri': uri});

    final response = await _sendRequest(request);
    final contents = response['contents'] as List?;
    if (contents != null && contents.isNotEmpty) {
      return contents.first['text'] ?? '';
    }
    return '';
  }

  /// Request completion/sampling from MCP server
  Future<MCPSamplingResult> completeSampling(List<Map<String, dynamic>> messages, {int maxTokens = 1000, double temperature = 0.7}) async {
    final request = MCPRequest(
      id: _uuid.v4(),
      method: 'sampling/createMessage',
      params: {'messages': messages, 'maxTokens': maxTokens, 'temperature': temperature},
    );

    final response = await _sendRequest(request);
    return MCPSamplingResult.fromJson(response);
  }

  /// Start periodic health checks
  void _startHealthCheck() {
    _stopHealthCheck(); // Ensure no duplicate timers
    _healthCheckTimer = Timer.periodic(_healthCheckInterval, (_) {
      _performHealthCheck();
    });
  }

  /// Stop health checks
  void _stopHealthCheck() {
    _healthCheckTimer?.cancel();
    _healthCheckTimer = null;
  }

  /// Perform a health check
  Future<void> _performHealthCheck() async {
    if (!_isConnected) return;

    try {
      await _testConnection();
    } catch (e) {
      talker.warning('Health check failed, attempting reconnection: $e');
      _isConnected = false;
      notifyListeners();
      _attemptReconnection();
    }
  }

  /// Attempt to reconnect with exponential backoff
  Future<void> _attemptReconnection() async {
    if (_isReconnecting || _reconnectionAttempts >= _maxReconnectionAttempts) {
      return;
    }

    _isReconnecting = true;
    _reconnectionAttempts++;

    // Calculate backoff delay
    final backoffDelay = Duration(seconds: (_reconnectionDelay.inSeconds * _reconnectionAttempts).clamp(5, 60));

    talker.info('Attempting reconnection $_reconnectionAttempts/$_maxReconnectionAttempts in ${backoffDelay.inSeconds}s...');

    await Future.delayed(backoffDelay);

    try {
      await connect();
      talker.info('Reconnection successful after $_reconnectionAttempts attempts');
    } catch (e) {
      talker.error('Reconnection attempt $_reconnectionAttempts failed: $e');

      if (_reconnectionAttempts >= _maxReconnectionAttempts) {
        talker.error('Max reconnection attempts reached. Manual reconnection required.');
      }
    } finally {
      _isReconnecting = false;
    }
  }

  /// Manual reconnection method
  Future<void> reconnect() async {
    _reconnectionAttempts = 0;
    _isReconnecting = false;
    await connect();
  }

  /// Disconnect from the MCP server
  Future<void> disconnect() async {
    _isConnected = false;
    _stopHealthCheck();
    notifyListeners();
  }

  /// Dispose of the client
  @override
  void dispose() {
    disconnect();
    _messageController.close();
    _httpClient.close();
    super.dispose();
  }
}
