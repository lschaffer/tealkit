import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/mcp_models.dart';
import 'internal_mcp_server.dart';

/// Adapter that wraps an [InternalMcpServer] so it can be registered as a
/// client in [MultiMCPManager] via [MCPClientDef].
///
/// This bridges the gap between internal (built-in) MCP servers and the
/// external MCP client system that the [ChatService] uses for tool discovery
/// and execution.
class InternalMcpClientAdapter extends ChangeNotifier {
  final InternalMcpServer _server;
  bool _isConnected = false;
  List<MCPTool> _tools = [];

  InternalMcpClientAdapter(this._server);

  bool get isConnected => _isConnected;

  List<MCPTool> get availableTools => _tools;

  List<MCPTool> _getFilteredTools() {
    var rawTools = _server.tools;
    if (_server.type == 'website_search') {
      rawTools = rawTools
          .where((t) =>
              t.name != 'index_websites' &&
              t.name != 'reindex_websites' &&
              t.name != 'purge_stale_index')
          .toList();
    }
    return rawTools
        .map((t) => MCPTool(
            name: t.name,
            description: t.description,
            inputSchema: t.inputSchema))
        .toList();
  }

  /// "Connecting" means initializing the server with its parameters.
  Future<void> connect() async {
    // Server tools are available immediately — no network needed.
    _tools = _getFilteredTools();
    _isConnected = true;
    notifyListeners();
  }

  /// Re-reads the underlying server's tool list and notifies listeners.
  ///
  /// Call this after a slow-starting server (e.g. [GithubMcpBridgeServer])
  /// finishes its background initialization so that the UI and the LLM API
  /// call see the correct tool list.
  void refreshTools() {
    final updated = _getFilteredTools();
    if (updated.length != _tools.length) {
      _tools = updated;
      notifyListeners();
    }
  }

  /// Initialize the underlying server with task-specific parameters.
  Future<void> initialize(Map<String, dynamic> initParams) async {
    await _server.initialize(initParams);
  }

  Future<void> disconnect() async {
    _isConnected = false;
    notifyListeners();
  }

  /// Execute a tool call — delegates to the internal server and wraps the
  /// result into an [MCPToolResult].
  Future<MCPToolResult> callTool(String name, Map<String, dynamic> arguments) async {
    final result = await _server.executeTool(name, arguments);

    // The internal server returns a Map; wrap it as MCPToolResult.
    // result['content'] may be:
    //   • a List  — MCP-protocol style: [{'type':'text','text':'...'}, ...]
    //   • a String — legacy plain-text or base64 style
    //   • null     — fall through to JSON-encode the whole result
    final isError = result['isError'] == true || result['error'] != null;
    final rawContent = result['content'];

    // ── MCP-protocol style (used by IMAP, etc.) ──
    if (rawContent is List) {
      final items = rawContent
          .whereType<Map>()
          .map(
            (item) => MCPContent(
              type: (item['type'] as String?) ?? 'text',
              text: item['text'] as String?,
              data: item['data'] as String?,
              mimeType: item['mimeType'] as String?,
            ),
          )
          .toList();
      if (items.isNotEmpty) {
        return MCPToolResult(content: items, isError: isError);
      }
    }

    // ── Legacy base64 style ──
    // Servers may return base64 data under 'content' (old) or 'data' (new, e.g. Excel/File MCP).
    final mimeType = (result['mimeType'] as String?)?.trim();
    final encoding = (result['encoding'] as String?)?.trim().toLowerCase();
    // Check both 'content' (legacy) and 'data' (Excel/File MCP servers)
    final base64Content = (rawContent is String && rawContent.trim().isNotEmpty)
        ? rawContent.trim()
        : (result['data'] is String && (result['data'] as String).trim().isNotEmpty)
        ? (result['data'] as String).trim()
        : null;

    if (!isError && mimeType != null && mimeType.isNotEmpty && encoding == 'base64' && base64Content != null && base64Content.isNotEmpty) {
      final fileName = (result['fileName'] as String?)?.trim();
      final message = (result['message'] as String?)?.trim();
      final content = <MCPContent>[];
      // Put metadata JSON FIRST so _extractEmailAttachments can track fileName
      // before it processes the binary data item that follows.
      if (fileName != null && fileName.isNotEmpty) {
        content.add(MCPContent(type: 'text', text: jsonEncode({'fileName': fileName, 'message': message ?? ''})));
      }
      // Binary payload
      content.add(MCPContent(type: 'file', data: base64Content, mimeType: mimeType));
      return MCPToolResult(content: content, isError: false);
    }

    // ── Fallback: JSON-encode the whole result map ──
    final text = (rawContent is String && rawContent.trim().isNotEmpty) ? rawContent : jsonEncode(result);
    return MCPToolResult(
      content: [MCPContent(type: 'text', text: text)],
      isError: isError,
    );
  }

  @override
  void dispose() {
    _server.dispose();
    super.dispose();
  }
}
