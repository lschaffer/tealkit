import 'dart:io';
import 'package:dart_mcp_core/dart_mcp_core.dart';
import '../internal_mcp_server.dart';

/// Internal MCP Server that exposes desktop coding tools from `dart_mcp_core`
/// (filesystem operations, terminal command execution, web fetch) bound to a workspace.
class CodingToolsMcpServer extends InternalMcpServer {
  String _workspaceDirectory = Directory.current.path;
  List<McpLocalTool> _tools = [];

  CodingToolsMcpServer() {
    _refreshTools();
  }

  void _refreshTools() {
    _tools = CodingTools.createAll(workingDirectory: _workspaceDirectory);
  }

  @override
  String get type => 'coding_tools';

  @override
  String get displayName => 'Coding Agent Tools';

  @override
  String get description =>
      'Workspace file search, read/write/edit files, directory management, and command execution.';

  @override
  String get iconName => 'terminal';

  @override
  Map<String, dynamic> get initParamSchema => {
        'workspace': {
          'type': 'string',
          'description': 'Root working directory for the coding tools',
        },
      };

  @override
  Map<String, dynamic> get defaultInitParams => {
        'workspace': Directory.current.path,
      };

  @override
  String get defaultSystemPrompt =>
      'You are a desktop Coding Agent. You have full access to workspace file management '
      '(find, read, write, edit, replace) and terminal execution tools. '
      'Always verify file paths and inspect existing code before making changes.';

  @override
  Future<void> initialize(Map<String, dynamic> initParams) async {
    final ws = (initParams['workspace'] as String? ?? '').trim();
    if (ws.isNotEmpty) {
      _workspaceDirectory = ws;
    } else {
      _workspaceDirectory = Directory.current.path;
    }
    _refreshTools();
  }

  @override
  List<McpToolDescriptor> get tools {
    return _tools.map((t) {
      return McpToolDescriptor(
        name: t.name,
        description: t.description,
        inputSchema: t.inputSchema,
      );
    }).toList();
  }

  /// Direct tool list bridge for callers accessing `availableTools`.
  List<dynamic> get availableTools => _tools;

  /// Connection status for MCPClientDef.
  bool get isConnected => true;

  Future<void> connect() async {}

  Future<void> disconnect() async {}

  /// Direct tool execution bridge for MCPClientDef.
  Future<dynamic> callTool(String name, Map<String, dynamic> arguments) async {
    final tool = _tools.where((t) => t.name == name).firstOrNull;
    if (tool == null) {
      return {
        'isError': true,
        'content': [
          {'type': 'text', 'text': 'Unknown coding tool: $name'},
        ],
      };
    }
    return await tool.execute(arguments);
  }

  @override
  Future<Map<String, dynamic>> executeTool(
    String toolName,
    Map<String, dynamic> arguments,
  ) async {
    final tool = _tools.where((t) => t.name == toolName).firstOrNull;
    if (tool == null) {
      return {
        'isError': true,
        'content': [
          {'type': 'text', 'text': 'Unknown coding tool: $toolName'},
        ],
      };
    }

    try {
      final MCPToolResult res = await tool.execute(arguments);
      return {
        'isError': res.isError,
        'content': res.content
            .map((c) => {
                  'type': c.type,
                  'text': c.text,
                })
            .toList(),
      };
    } catch (e) {
      return {
        'isError': true,
        'content': [
          {'type': 'text', 'text': 'Tool execution failed: $e'},
        ],
      };
    }
  }

  @override
  String? validateInitParams(Map<String, dynamic> params) {
    final ws = params['workspace'] as String?;
    if (ws != null && ws.isNotEmpty && !Directory(ws).existsSync()) {
      return 'Workspace directory does not exist: $ws';
    }
    return null;
  }
}
