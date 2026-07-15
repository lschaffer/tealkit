import '../../models/github_mcp_server_definition.dart';
import '../../services/app_logger.dart';
import '../../services/github_mcp_runtime_service.dart';
import '../internal_mcp_server.dart';

/// [InternalMcpServer] wrapper for a GitHub-sourced Python MCP server.
///
/// On [initialize] the server binary is launched as a child process.
/// Communicates via MCP stdio (JSON-RPC 2.0 newline-delimited).
///
/// One instance → one live process for the lifetime of the agent session.
class GithubMcpBridgeServer extends InternalMcpServer {
  final GithubMcpServerDefinition def;

  StdioMcpClient? _client;
  List<McpToolDescriptor> _tools = [];
  bool _initialized = false;

  GithubMcpBridgeServer(this.def);

  // ─── InternalMcpServer identity ───────────────────────────────────────────

  @override
  String get type => 'gh_mcp_${def.id}';

  @override
  String get displayName => def.displayName;

  @override
  String get description => def.description;

  @override
  String get iconName => _iconForCategory(def.category);

  @override
  Map<String, dynamic> get initParamSchema => {
    'type': 'object',
    'properties': {
      'timeoutSeconds': {'type': 'integer', 'description': 'Per-call timeout in seconds.', 'default': 60},
    },
    'required': [],
  };

  @override
  Map<String, dynamic> get defaultInitParams => {'timeoutSeconds': 60};

  @override
  String get defaultSystemPrompt =>
      'You have access to the "${def.displayName}" MCP server. '
      'Call tools/list first if you are unsure which tools are available. '
      'Follow each tool\'s input schema precisely.';

  int _timeoutSeconds = 60;

  // ─── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  Future<void> initialize(Map<String, dynamic> initParams) async {
    _timeoutSeconds = (initParams['timeoutSeconds'] as int?) ?? 60;

    log.info('[GhMcpBridge:${def.name}] Launching process…');
    final process = await GithubMcpRuntimeService.instance.launch(def);
    _client = StdioMcpClient(process);

    // MCP handshake: initialize
    try {
      final initResp = await _client!.request('initialize', {
        'protocolVersion': '2024-11-05',
        'capabilities': {},
        'clientInfo': {'name': 'TealKit', 'version': '1.0'},
      }, timeout: Duration(seconds: _timeoutSeconds));
      if (initResp.containsKey('error')) {
        log.warning('[GhMcpBridge:${def.name}] initialize error: ${initResp['error']}');
      }

      // ACK
      await _client!.notify('notifications/initialized', null);
    } catch (e) {
      log.warning('[GhMcpBridge:${def.name}] initialize handshake failed: $e');
    }

    // Discover tools
    await _refreshTools();
    _initialized = true;
    log.info('[GhMcpBridge:${def.name}] Ready with ${_tools.length} tools');
  }

  Future<void> _refreshTools() async {
    try {
      final resp = await _client!.request('tools/list', null, timeout: Duration(seconds: _timeoutSeconds));
      final list = (resp['result']?['tools'] as List<dynamic>?) ?? [];
      _tools = list.whereType<Map<String, dynamic>>().map((t) {
        return McpToolDescriptor(
          name: t['name'] as String,
          description: t['description'] as String? ?? '',
          inputSchema: (t['inputSchema'] as Map<String, dynamic>?) ?? {'type': 'object', 'properties': {}},
        );
      }).toList();
    } catch (e) {
      log.warning('[GhMcpBridge:${def.name}] tools/list failed: $e');
      _tools = [];
    }
  }

  @override
  List<McpToolDescriptor> get tools => List.unmodifiable(_tools);

  // ─── Tool execution ────────────────────────────────────────────────────────

  @override
  Future<Map<String, dynamic>> executeTool(String toolName, Map<String, dynamic> arguments) async {
    if (!_initialized || _client == null) {
      throw StateError('GithubMcpBridgeServer not initialized: ${def.name}');
    }

    log.info('[GhMcpBridge:${def.name}] tools/call $toolName');

    final resp = await _client!.request('tools/call', {
      'name': toolName,
      'arguments': arguments,
    }, timeout: Duration(seconds: _timeoutSeconds));

    if (resp.containsKey('error')) {
      final err = resp['error'];
      throw GhMcpRuntimeError('Tool "$toolName" error (${err['code']}): ${err['message']}');
    }

    final result = resp['result'] as Map<String, dynamic>? ?? {};

    // MCP spec: result.content is a list of content items.
    // Return the full list under the 'content' key so InternalMcpClientAdapter
    // creates proper MCPContent objects for ALL item types (text, image, file).
    // Collapsing to only the first text item here would discard image payloads
    // and cause base64 data to leak into the LLM context as raw text.
    final content = result['content'];
    if (content is List && content.isNotEmpty) {
      return {'content': content, if (result['isError'] == true) 'isError': true};
    }

    return result.isNotEmpty ? result : {'result': 'done'};
  }

  // ─── Dispose ───────────────────────────────────────────────────────────────

  @override
  Future<void> dispose() async {
    await _client?.dispose();
    _client = null;
    _initialized = false;
    log.info('[GhMcpBridge:${def.name}] Disposed');
  }

  // ─── Helpers ───────────────────────────────────────────────────────────────

  static String _iconForCategory(String category) {
    switch (category) {
      case 'files':
        return 'folder_open';
      case 'databases':
        return 'storage';
      case 'web':
        return 'language';
      case 'productivity':
        return 'work';
      default:
        return 'extension';
    }
  }
}
