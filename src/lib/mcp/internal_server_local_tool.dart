import 'dart:convert';
import 'package:dart_mcp_core/dart_mcp_core.dart';
import 'internal_mcp_server.dart';

/// Wraps an [InternalMcpServer] tool descriptor into a native [McpLocalTool]
/// compatible with the Flutter MCP Suite (`dart_mcp_core` & `flutter_ui_mcp`).
class InternalServerLocalTool extends McpLocalTool {
  final InternalMcpServer server;
  final McpToolDescriptor descriptor;

  InternalServerLocalTool({
    required this.server,
    required this.descriptor,
  });

  @override
  String get name => descriptor.name;

  @override
  String get description => descriptor.description;

  @override
  Map<String, dynamic> get inputSchema => descriptor.inputSchema;

  @override
  Future<MCPToolResult> execute(Map<String, dynamic> arguments) async {
    try {
      final res = await server.executeTool(descriptor.name, arguments);
      final isErr = res.containsKey('error') && res['error'] != null;
      return MCPToolResult(
        isError: isErr,
        content: [
          MCPContent(
            type: 'text',
            text: isErr ? res['error'].toString() : jsonEncode(res),
          ),
        ],
      );
    } catch (e) {
      return MCPToolResult(
        isError: true,
        content: [MCPContent(type: 'text', text: 'Error executing $name: $e')],
      );
    }
  }

  /// Factory helper that converts all tools of an [InternalMcpServer] into a list of [McpLocalTool].
  static List<McpLocalTool> adaptServer(InternalMcpServer server) {
    return server.tools
        .map((desc) => InternalServerLocalTool(server: server, descriptor: desc))
        .toList();
  }
}
