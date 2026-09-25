import 'dart:io';

import 'package:dart_mcp_core/dart_mcp_core.dart';
import '../formatters/terminal_printer.dart';

/// Result of an MCP server uninstall operation.
class McpUninstallResult {
  final String serverName;
  final String serverId;
  final bool disconnected;
  final bool cacheCleaned;
  final String message;

  const McpUninstallResult({
    required this.serverName,
    required this.serverId,
    required this.disconnected,
    required this.cacheCleaned,
    required this.message,
  });
}

/// Helper for managing and uninstalling MCP servers (disconnecting + clearing cache).
class McpManagerHelper {
  /// Uninstalls one or all MCP servers.
  /// Disconnects from [mcpManager] and cleans uvx/npx tool cache so it will be freshly reinstalled next time.
  static Future<List<McpUninstallResult>> uninstallServers({
    required String targetQuery,
    required List<McpServerConfig> configuredServers,
    required MultiMCPManager mcpManager,
    bool verbose = false,
  }) async {
    final results = <McpUninstallResult>[];
    final isAll = targetQuery.toLowerCase() == 'all' ||
        targetQuery.toLowerCase() == 'all_mcp' ||
        targetQuery.toLowerCase() == '*';

    final matched = isAll
        ? List<McpServerConfig>.from(configuredServers)
        : configuredServers.where((s) {
            final q = targetQuery.toLowerCase().trim();
            return s.name.toLowerCase() == q ||
                s.id.toLowerCase() == q ||
                s.name.toLowerCase().contains(q) ||
                (s.localPackage != null && s.localPackage!.toLowerCase().contains(q));
          }).toList();

    if (matched.isEmpty) {
      stdout.writeln(
        TerminalPrinter.yellow(
          'No MCP servers matched query: "$targetQuery". Available: ${configuredServers.map((s) => s.name).join(", ")}',
        ),
      );
      return results;
    }

    for (final server in matched) {
      stdout.write('  → Uninstalling MCP server "${server.name}"... ');

      // 1. Disconnect and unregister from MultiMCPManager
      bool disconnected = false;
      try {
        mcpManager.unregisterClient(server.id);
        mcpManager.unregisterClient(server.name);
        disconnected = true;
      } catch (_) {}

      // 2. Clear local cache if it's a local stdio package
      bool cacheCleaned = false;
      String cleanMsg = '';

      if (server.isLocal) {
        final installMethod = server.localInstallMethod?.toLowerCase() ?? '';
        final localType = server.localType?.toLowerCase() ?? '';

        try {
          if (installMethod == 'uvx' || localType == 'python') {
            // Clean uv cache with short timeout
            final res = await Process.run('uv', ['cache', 'clean'], runInShell: true)
                .timeout(const Duration(seconds: 2));
            if (res.exitCode == 0) {
              cacheCleaned = true;
              cleanMsg = 'uv cache cleared';
            }
          } else if (installMethod == 'npx' || installMethod == 'npm' || localType == 'nodejs') {
            // Clean npm cache with short timeout
            final npmCmd = Platform.isWindows ? 'npm.cmd' : 'npm';
            final res = await Process.run(npmCmd, ['cache', 'clean', '--force'], runInShell: true)
                .timeout(const Duration(seconds: 2));
            if (res.exitCode == 0) {
              cacheCleaned = true;
              cleanMsg = 'npm cache cleaned';
            }
          }
        } catch (e) {
          if (verbose) stderr.writeln('\n    [cache clean notice] $e');
        }
      }

      stdout.writeln(TerminalPrinter.green('✔ uninstalled'));
      if (cleanMsg.isNotEmpty) {
        stdout.writeln(TerminalPrinter.dim('      ($cleanMsg — will be downloaded & re-installed on next run)'));
      } else {
        stdout.writeln(TerminalPrinter.dim('      (Disconnected — will be re-initialized on next run)'));
      }

      results.add(
        McpUninstallResult(
          serverName: server.name,
          serverId: server.id,
          disconnected: disconnected,
          cacheCleaned: cacheCleaned,
          message: 'Uninstalled ${server.name}',
        ),
      );
    }

    return results;
  }
}
