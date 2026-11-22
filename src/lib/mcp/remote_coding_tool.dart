import 'package:dart_mcp_core/dart_mcp_core.dart';
import 'package:tealkit_api/tealkit_api.dart' show ServerApiClient;

/// Wraps a Coding Agent tool (`fs_*`, `terminal_exec`, `fetch_web`) so that
/// mobile clients connected in Server Mode execute workspace file and terminal
/// operations safely on the remote TealKit Server inside its configured root
/// directory (`TEALKIT_FILES_DIR`).
class RemoteCodingTool extends McpLocalTool {
  final ServerApiClient serverClient;
  final String workspaceDirectory;
  final McpLocalTool _descriptor;

  RemoteCodingTool({
    required this.serverClient,
    required this.workspaceDirectory,
    required McpLocalTool descriptor,
  }) : _descriptor = descriptor;

  @override
  String get name => _descriptor.name;

  @override
  String get description => _descriptor.description;

  @override
  Map<String, dynamic> get inputSchema => _descriptor.inputSchema;

  @override
  ToolRiskLevel get riskLevel => _descriptor.riskLevel;

  @override
  Future<MCPToolResult> execute(Map<String, dynamic> arguments) async {
    try {
      final resp = await serverClient.executeServerCodingTool(
        name,
        workspace: workspaceDirectory,
        arguments: arguments,
      );
      final isError = resp['isError'] == true;
      final content = resp['content'] as String? ?? '';
      if (isError) {
        return MCPToolResult.error(content.isNotEmpty ? content : 'Remote coding tool failed');
      }
      return MCPToolResult.text(content);
    } catch (e) {
      return MCPToolResult.error('Remote coding tool "$name" failed: $e');
    }
  }

  /// Creates the full Coding Tools suite backed by the remote TealKit Server.
  static List<McpLocalTool> createAll({
    required ServerApiClient serverClient,
    required String workspaceDirectory,
  }) {
    final templates = CodingTools.createAll(workingDirectory: workspaceDirectory);
    return templates
        .map(
          (t) => RemoteCodingTool(
            serverClient: serverClient,
            workspaceDirectory: workspaceDirectory,
            descriptor: t,
          ),
        )
        .toList();
  }
}
