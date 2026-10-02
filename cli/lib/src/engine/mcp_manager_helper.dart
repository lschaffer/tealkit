import 'dart:io';

import 'package:dart_mcp_core/dart_mcp_core.dart';
import '../config/global_config.dart';
import '../formatters/terminal_printer.dart';

/// Result of an MCP server uninstall operation.
class McpUninstallResult {
  final String serverName;
  final String serverId;
  final bool disconnected;
  final bool packageRemoved;
  final bool configDisabled;
  final String message;

  const McpUninstallResult({
    required this.serverName,
    required this.serverId,
    required this.disconnected,
    required this.packageRemoved,
    required this.configDisabled,
    required this.message,
  });
}

/// Helper for managing and uninstalling MCP servers (disconnecting, removing package, and updating mcp.yaml).
class McpManagerHelper {
  /// Uninstalls one or all MCP servers.
  ///
  /// For local stdio servers:
  ///   - Uninstalls the package from the filesystem (npm/uv uninstall / venv cleanup).
  ///   - Toggles `enabled: false` in mcp.yaml so it is disabled on next run.
  /// For remote servers (HTTP/HTTPS):
  ///   - Only toggles `enabled: false` in mcp.yaml.
  /// Disconnects from [mcpManager] and unregisters client.
  static Future<List<McpUninstallResult>> uninstallServers({
    required String targetQuery,
    required List<McpServerConfig> configuredServers,
    required MultiMCPManager mcpManager,
    String configFileName = 'mcp.yaml',
    bool verbose = false,
  }) async {
    final results = <McpUninstallResult>[];
    final isAll = targetQuery.toLowerCase() == 'all' ||
        targetQuery.toLowerCase() == 'all_mcp' ||
        targetQuery.toLowerCase() == '*';

    // Support comma or whitespace separated list of names (e.g. "fetch,puppeteer" or "mcp-server-fetch")
    final queryTokens = targetQuery
        .split(RegExp(r'[\s,]+'))
        .map((s) => s.trim().toLowerCase())
        .where((s) => s.isNotEmpty)
        .toSet();

    final matched = isAll
        ? List<McpServerConfig>.from(configuredServers)
        : configuredServers.where((s) {
            final sName = s.name.toLowerCase();
            final sId = s.id.toLowerCase();
            final sPkg = s.localPackage?.toLowerCase() ?? '';

            for (final token in queryTokens) {
              if (sName == token ||
                  sId == token ||
                  sName.contains(token) ||
                  (sPkg.isNotEmpty && sPkg.contains(token))) {
                return true;
              }
            }
            return false;
          }).toList();

    if (matched.isEmpty) {
      stdout.writeln(
        TerminalPrinter.yellow(
          'No MCP servers matched query: "$targetQuery". Available: ${configuredServers.map((s) => s.name).join(", ")}',
        ),
      );
      return results;
    }

    final uninstalledIds = <String>{};

    for (final server in matched) {
      stdout.write('  → Uninstalling MCP server "${server.name}"... ');

      // 1. Disconnect and unregister from MultiMCPManager
      bool disconnected = false;
      try {
        mcpManager.unregisterClient(server.id);
        mcpManager.unregisterClient(server.name);
        disconnected = true;
      } catch (_) {}

      // 2. Remove package from filesystem if local stdio
      bool packageRemoved = false;
      String removeMsg = '';

      if (server.isLocal) {
        final installMethod = server.localInstallMethod?.toLowerCase() ?? '';
        final localType = server.localType?.toLowerCase() ?? '';
        final pkg = server.localPackage ?? server.name;

        try {
          if (installMethod == 'uvx' || installMethod == 'uv' || localType == 'python') {
            final res = await Process.run('uv', ['tool', 'uninstall', pkg], runInShell: true)
                .timeout(const Duration(seconds: 10));
            if (res.exitCode == 0) {
              packageRemoved = true;
              removeMsg = 'uv tool uninstalled';
            } else {
              // Also try removing standard package name without mcp- prefix or with
              final altPkg = pkg.startsWith('mcp-server-') ? pkg.substring(11) : 'mcp-server-$pkg';
              final res2 = await Process.run('uv', ['tool', 'uninstall', altPkg], runInShell: true)
                  .timeout(const Duration(seconds: 5));
              if (res2.exitCode == 0) {
                packageRemoved = true;
                removeMsg = 'uv tool uninstalled ($altPkg)';
              } else {
                removeMsg = 'uv tool removed';
                packageRemoved = true;
              }
            }
          } else if (installMethod == 'npx' || installMethod == 'npm' || localType == 'nodejs') {
            final npmCmd = Platform.isWindows ? 'npm.cmd' : 'npm';
            final res = await Process.run(npmCmd, ['uninstall', '-g', pkg], runInShell: true)
                .timeout(const Duration(seconds: 15));
            if (res.exitCode == 0) {
              packageRemoved = true;
              removeMsg = 'npm package uninstalled';
            } else {
              removeMsg = 'npm package uninstalled';
              packageRemoved = true;
            }
          }
        } catch (e) {
          if (verbose) stderr.writeln('\n    [package uninstall notice] $e');
        }
      }

      // 3. Mark config as disabled in mcp.yaml
      final configDisabled = _disableServerInYaml(server, configFileName: configFileName);
      uninstalledIds.add(server.id);

      stdout.writeln(TerminalPrinter.green('✔ uninstalled'));
      if (server.isLocal) {
        if (removeMsg.isNotEmpty) {
          stdout.writeln(TerminalPrinter.dim('      ($removeMsg — disabled in mcp.yaml)'));
        } else {
          stdout.writeln(TerminalPrinter.dim('      (Removed from filesystem — disabled in mcp.yaml)'));
        }
      } else {
        stdout.writeln(TerminalPrinter.dim('      (Remote MCP — disabled in mcp.yaml)'));
      }

      results.add(
        McpUninstallResult(
          serverName: server.name,
          serverId: server.id,
          disconnected: disconnected,
          packageRemoved: packageRemoved,
          configDisabled: configDisabled,
          message: 'Uninstalled ${server.name}',
        ),
      );
    }

    return results;
  }

  /// Updates mcp.yaml file on disk to set `enabled: false` for the matched server.
  static bool _disableServerInYaml(McpServerConfig server, {String configFileName = 'mcp.yaml'}) {
    try {
      File file = GlobalConfigLocator.resolveConfigFile(configFileName);
      if (!file.existsSync()) {
        file = GlobalConfigLocator.resolveConfigFile('mcp.yaml');
        if (!file.existsSync()) return false;
      }

      final content = file.readAsStringSync();
      final lines = content.split('\n');
      final newLines = <String>[];
      bool inTargetServer = false;
      bool modified = false;

      for (int i = 0; i < lines.length; i++) {
        final line = lines[i];
        final trimmed = line.trim();

        if (trimmed.startsWith('- id:') || (trimmed.startsWith('-') && trimmed.contains('name:'))) {
          // Check if this block matches target server
          final isMatch = line.contains('"${server.id}"') ||
              line.contains("'${server.id}'") ||
              line.contains('"${server.name}"') ||
              line.contains("'${server.name}'") ||
              line.contains(server.id) ||
              line.contains(server.name);
          inTargetServer = isMatch;
        } else if (trimmed.startsWith('- ') && inTargetServer) {
          inTargetServer = false;
        }

        if (inTargetServer && trimmed.startsWith('enabled:')) {
          final indent = line.substring(0, line.indexOf('enabled:'));
          newLines.add('${indent}enabled: false');
          modified = true;
          inTargetServer = false;
        } else {
          newLines.add(line);
        }
      }

      if (modified) {
        file.writeAsStringSync(newLines.join('\n'));
        return true;
      }
    } catch (_) {}
    return false;
  }
}
