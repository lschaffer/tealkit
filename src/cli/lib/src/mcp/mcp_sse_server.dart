import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

import 'mcp_stdio_server.dart';
import 'workflow_schema_generator.dart';

/// Server-Sent Events (SSE) and HTTP transport for TealKit Model Context Protocol (MCP) Server.
///
/// Complies with the MCP HTTP with SSE specification:
/// - `GET /sse`: Establishes the SSE stream and returns the POST endpoint URL for the session.
/// - `POST /message?sessionId=<id>`: Receives JSON-RPC requests from the client and dispatches responses over the SSE stream.
class McpSseServer {
  final McpStdioServer mcpServer;
  final String host;
  final int port;
  final String? apiKey;
  final String? certificatePath;
  final String? privateKeyPath;
  final bool verbose;

  HttpServer? _server;
  final Map<String, HttpResponse> _sessions = {};
  final _uuid = const Uuid();

  McpSseServer({
    required this.mcpServer,
    this.host = '0.0.0.0',
    this.port = 8081,
    this.apiKey,
    this.certificatePath,
    this.privateKeyPath,
    this.verbose = false,
  });

  /// Factory creating an [McpSseServer] with workflows and options.
  factory McpSseServer.create({
    List<TealKitWorkflow> workflows = const [],
    String host = '0.0.0.0',
    int port = 8081,
    String? apiKey,
    String? certificatePath,
    String? privateKeyPath,
    bool verbose = false,
  }) {
    final mcp = McpStdioServer(
      workflows: workflows,
      verbose: verbose,
    );
    return McpSseServer(
      mcpServer: mcp,
      host: host,
      port: port,
      apiKey: apiKey,
      certificatePath: certificatePath,
      privateKeyPath: privateKeyPath,
      verbose: verbose,
    );
  }

  /// Starts the HTTP / HTTPS SSE server.
  Future<HttpServer> start() async {
    SecurityContext? securityContext;
    if (certificatePath != null && privateKeyPath != null) {
      securityContext = SecurityContext()
        ..useCertificateChain(certificatePath!)
        ..usePrivateKey(privateKeyPath!);
    }

    if (securityContext != null) {
      _server = await HttpServer.bindSecure(host, port, securityContext);
    } else {
      _server = await HttpServer.bind(host, port);
    }

    final scheme = securityContext != null ? 'https' : 'http';
    stderr.writeln('[TealKit MCP SSE] Listening on $scheme://$host:$port/sse');
    if (apiKey != null && apiKey!.isNotEmpty) {
      stderr.writeln('[TealKit MCP SSE] Authentication enabled (Bearer token required).');
    }

    _server!.listen(_handleHttpRequest);
    return _server!;
  }

  /// Stops the running server and closes all active SSE sessions.
  Future<void> stop() async {
    for (final session in _sessions.values) {
      try {
        session.close();
      } catch (_) {}
    }
    _sessions.clear();
    await _server?.close(force: true);
    _server = null;
    stderr.writeln('[TealKit MCP SSE] Server stopped.');
  }

  void _applyCors(HttpResponse response) {
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    response.headers.set(
      'Access-Control-Allow-Headers',
      'Content-Type, Authorization, X-Requested-With',
    );
  }

  bool _isAuthorized(HttpRequest request) {
    if (apiKey == null || apiKey!.isEmpty) return true;

    final authHeader = request.headers.value('Authorization');
    if (authHeader != null) {
      final token = authHeader.replaceFirst(RegExp(r'^Bearer\s+', caseSensitive: false), '').trim();
      if (token == apiKey) return true;
    }

    final queryToken = request.uri.queryParameters['apiKey'] ??
        request.uri.queryParameters['api_key'] ??
        request.uri.queryParameters['token'];
    return queryToken == apiKey;
  }

  Future<void> _handleHttpRequest(HttpRequest request) async {
    _applyCors(request.response);

    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      return;
    }

    final path = request.uri.path;

    // Health check endpoint
    if (path == '/health' || path == '/') {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'status': 'healthy',
        'service': 'tealkit-mcp-server',
        'protocol': 'mcp-sse',
        'version': '1.3.0',
        'active_sse_sessions': _sessions.length,
      }));
      await request.response.close();
      return;
    }

    // Check API Key authentication
    if (!_isAuthorized(request)) {
      request.response.statusCode = HttpStatus.unauthorized;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'error': 'Unauthorized',
        'message': 'Valid Bearer token or apiKey query param required.'
      }));
      await request.response.close();
      return;
    }

    if (request.method == 'GET' && (path == '/sse' || path == '/mcp/sse')) {
      await _handleSseConnect(request);
    } else if (request.method == 'POST' && (path == '/message' || path == '/mcp/message')) {
      await _handlePostMessage(request);
    } else {
      request.response.statusCode = HttpStatus.notFound;
      request.response.write('Not Found');
      await request.response.close();
    }
  }

  Future<void> _handleSseConnect(HttpRequest request) async {
    final sessionId = _uuid.v4();
    final response = request.response;

    response.headers.set('Content-Type', 'text/event-stream; charset=utf-8');
    response.headers.set('Cache-Control', 'no-cache, no-transform');
    response.headers.set('Connection', 'keep-alive');
    response.bufferOutput = false;

    _sessions[sessionId] = response;
    stderr.writeln('[TealKit MCP SSE] Client connected: session $sessionId');

    // Send the endpoint event informing the client where to POST messages
    final messageEndpoint = '/message?sessionId=$sessionId';
    response.write('event: endpoint\ndata: $messageEndpoint\n\n');

    // Handle client disconnect
    request.response.done.then((_) {
      stderr.writeln('[TealKit MCP SSE] Client disconnected: session $sessionId');
      _sessions.remove(sessionId);
    }).catchError((_) {
      _sessions.remove(sessionId);
    });
  }

  Future<void> _handlePostMessage(HttpRequest request) async {
    final sessionId = request.uri.queryParameters['sessionId'];
    if (sessionId == null || !_sessions.containsKey(sessionId)) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write(jsonEncode({
        'error': 'Invalid sessionId',
        'message': 'No active SSE connection found for sessionId: $sessionId'
      }));
      await request.response.close();
      return;
    }

    final sseResponse = _sessions[sessionId]!;
    final body = await utf8.decoder.bind(request).join();

    // Acknowledge the HTTP POST
    request.response.statusCode = HttpStatus.accepted;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'status': 'accepted', 'sessionId': sessionId}));
    await request.response.close();

    // Route message through MCP engine and send response back over the SSE channel
    await mcpServer.handleRawMessage(
      body,
      writer: (responseJson) {
        if (_sessions.containsKey(sessionId)) {
          sseResponse.write('event: message\ndata: $responseJson\n\n');
        }
      },
    );
  }
}
