import 'dart:io';

import 'package:dart_mcp_core/dart_mcp_core.dart';
import 'package:path/path.dart' as p;
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

/// Result of an MCP server install operation.
class McpInstallResult {
  final String serverName;
  final String serverId;
  final bool success;
  final bool packageInstalled;
  final bool configEnabled;
  final String message;

  const McpInstallResult({
    required this.serverName,
    required this.serverId,
    required this.success,
    required this.packageInstalled,
    required this.configEnabled,
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
            final uvExe = await _detectUvExecutable();
            final res = await Process.run(uvExe, ['tool', 'uninstall', pkg], runInShell: false)
                .timeout(const Duration(seconds: 10));
            if (res.exitCode == 0) {
              packageRemoved = true;
              removeMsg = 'uv tool uninstalled';
            } else {
              // Also try removing standard package name without mcp- prefix or with
              final altPkg = pkg.startsWith('mcp-server-') ? pkg.substring(11) : 'mcp-server-$pkg';
              final res2 = await Process.run(uvExe, ['tool', 'uninstall', altPkg], runInShell: false)
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

  /// Updates mcp.yaml file on disk to set `enabled: true` for the matched server.
  static bool _enableServerInYaml(McpServerConfig server, {String configFileName = 'mcp.yaml'}) {
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
          newLines.add('${indent}enabled: true');
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

  /// Detects the uv executable path, resolving Windows paths (.local/bin, .cargo/bin, etc.).
  static Future<String> _detectUvExecutable() async {
    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'] ?? '';
      final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
      final candidates = [
        p.join(userProfile, '.local', 'bin', 'uv.exe'),
        p.join(userProfile, '.cargo', 'bin', 'uv.exe'),
        p.join(localAppData, 'Programs', 'uv', 'uv.exe'),
      ];
      for (final c in candidates) {
        if (File(c).existsSync()) return c;
      }
      try {
        final res = await Process.run('where.exe', ['uv.exe']);
        if (res.exitCode == 0) {
          final first = (res.stdout as String)
              .split(RegExp(r'\r?\n'))
              .firstWhere((s) => s.trim().isNotEmpty, orElse: () => '');
          if (first.isNotEmpty) return first.trim();
        }
      } catch (_) {}
    }
    return 'uv';
  }

  /// Fetches the set of installed tools via `uv tool list`.
  static Future<Set<String>> getInstalledUvTools() async {
    try {
      final uvExe = await _detectUvExecutable();
      final res = await Process.run(uvExe, ['tool', 'list'], runInShell: false)
          .timeout(const Duration(seconds: 5));
      if (res.exitCode != 0) return {};
      final lines = (res.stdout as String).split(RegExp(r'\r?\n'));
      final tools = <String>{};
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        if (trimmed.startsWith('- ')) {
          tools.add(trimmed.substring(2).trim().toLowerCase());
        } else {
          final spaceIdx = trimmed.indexOf(' ');
          if (spaceIdx > 0) {
            tools.add(trimmed.substring(0, spaceIdx).trim().toLowerCase());
          } else {
            tools.add(trimmed.toLowerCase());
          }
        }
      }
      return tools;
    } catch (_) {
      return {};
    }
  }

  /// Checks whether a local MCP server package is installed and ready.
  static Future<bool> isServerInstalled(
    McpServerConfig server, {
    Set<String>? cachedUvTools,
  }) async {
    if (!server.isLocal) return true;

    final installMethod = server.localInstallMethod?.toLowerCase() ?? '';
    final localType = server.localType?.toLowerCase() ?? '';
    final pkg = (server.localPackage ?? server.name).toLowerCase();

    if (installMethod == 'uvx' || installMethod == 'uv' || localType == 'python') {
      final uvTools = cachedUvTools ?? await getInstalledUvTools();
      if (uvTools.isEmpty) return false;
      if (uvTools.contains(pkg)) return true;
      if (uvTools.contains(server.name.toLowerCase())) return true;
      final stripped = pkg.startsWith('mcp-server-') ? pkg.substring(11) : pkg;
      if (uvTools.contains(stripped)) return true;
      for (final t in uvTools) {
        if (t.contains(pkg) || pkg.contains(t) || t.contains(stripped)) {
          return true;
        }
      }
      return false;
    }

    return true;
  }

  /// Installs or verifies the package for a single local MCP server.
  static Future<McpInstallResult> installServer(
    McpServerConfig server, {
    void Function(String msg)? onProgress,
    String configFileName = 'mcp.yaml',
    bool verbose = false,
  }) async {
    final pkg = server.localPackage ?? server.name;
    final installMethod = server.localInstallMethod?.toLowerCase() ?? '';
    final localType = server.localType?.toLowerCase() ?? '';

    _enableServerInYaml(server, configFileName: configFileName);

    if (!server.isLocal) {
      return McpInstallResult(
        serverName: server.name,
        serverId: server.id,
        success: true,
        packageInstalled: false,
        configEnabled: true,
        message: 'Remote MCP enabled in $configFileName',
      );
    }

    try {
      if (installMethod == 'uvx' || installMethod == 'uv' || localType == 'python') {
        onProgress?.call('Running uv tool install --force $pkg...');
        final uvExe = await _detectUvExecutable();
        final isFetch = pkg == 'mcp-server-fetch' || pkg.contains('fetch');
        final args = [
          'tool',
          'install',
          '--force',
          pkg,
          if (isFetch) ...['--with', 'pydantic<2.10', '--with', 'mcp<1.3.0'],
        ];

        final res = await Process.run(uvExe, args, runInShell: false)
            .timeout(const Duration(minutes: 3));

        if (res.exitCode == 0) {
          return McpInstallResult(
            serverName: server.name,
            serverId: server.id,
            success: true,
            packageInstalled: true,
            configEnabled: true,
            message: 'Installed $pkg via uv tool',
          );
        } else {
          final err = (res.stderr as String).trim();
          return McpInstallResult(
            serverName: server.name,
            serverId: server.id,
            success: false,
            packageInstalled: false,
            configEnabled: true,
            message: 'uv tool install failed (exit ${res.exitCode}): $err',
          );
        }
      } else if (installMethod == 'npm' || installMethod == 'npx' || localType == 'nodejs') {
        onProgress?.call('Running npm install -g $pkg...');
        final npmCmd = Platform.isWindows ? 'npm.cmd' : 'npm';
        final res = await Process.run(npmCmd, ['install', '-g', pkg], runInShell: true)
            .timeout(const Duration(minutes: 3));

        if (res.exitCode == 0) {
          return McpInstallResult(
            serverName: server.name,
            serverId: server.id,
            success: true,
            packageInstalled: true,
            configEnabled: true,
            message: 'Installed $pkg via npm',
          );
        } else {
          final err = (res.stderr as String).trim();
          return McpInstallResult(
            serverName: server.name,
            serverId: server.id,
            success: false,
            packageInstalled: false,
            configEnabled: true,
            message: 'npm install failed: $err',
          );
        }
      }
    } catch (e) {
      return McpInstallResult(
        serverName: server.name,
        serverId: server.id,
        success: false,
        packageInstalled: false,
        configEnabled: true,
        message: 'Install exception: $e',
      );
    }

    return McpInstallResult(
      serverName: server.name,
      serverId: server.id,
      success: true,
      packageInstalled: false,
      configEnabled: true,
      message: 'Server enabled in $configFileName',
    );
  }

  /// Installs and connects one or all MCP servers matching [targetQuery].
  static Future<List<McpInstallResult>> installServers({
    required String targetQuery,
    required List<McpServerConfig> configuredServers,
    required MultiMCPManager mcpManager,
    String configFileName = 'mcp.yaml',
    bool verbose = false,
  }) async {
    final results = <McpInstallResult>[];
    final isAll = targetQuery.toLowerCase() == 'all' ||
        targetQuery.toLowerCase() == 'all_mcp' ||
        targetQuery.toLowerCase() == '*';

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

    for (final server in matched) {
      stdout.write('  → Installing MCP server "${server.name}"... ');
      final res = await installServer(
        server,
        configFileName: configFileName,
        verbose: verbose,
      );

      if (res.success) {
        stdout.writeln(TerminalPrinter.green('✔ installed'));
        stdout.writeln(TerminalPrinter.dim('      (${res.message})'));

        // Connect and register with MultiMCPManager if enabled
        try {
          final MCPClient client;
          if (server.isLocal) {
            client = LocalMCPClient(
              server,
              logCallback: (msg, {bool isError = false}) {
                if (verbose) stderr.writeln('      [LocalMCP:${server.name}] $msg');
              },
            );
          } else {
            client = MCPClient(
              server.url,
              mcpEndpoint: server.mcpEndpoint,
              bearerToken: server.apiKey,
              apiPassword: server.apiPassword,
              logCallback: (msg, {bool isError = false}) {
                if (verbose) stderr.writeln('      [RemoteMCP:${server.name}] $msg');
              },
            );
          }

          final clientDef = MCPClientDef(
            name: server.id,
            client: client,
            displayName: server.name,
          );
          mcpManager.registerClient(clientDef);
          await client.connect().timeout(const Duration(seconds: 25));
          final count = client.availableTools.length;
          stdout.writeln(
            TerminalPrinter.green('      ✔ connected ($count tool${count > 1 ? "s" : ""} registered)'),
          );
        } catch (e) {
          stdout.writeln(
            TerminalPrinter.yellow('      warning: connection attempt after install reported: $e'),
          );
        }
      } else {
        stdout.writeln(TerminalPrinter.red('✘ failed'));
        stdout.writeln(TerminalPrinter.yellow('      ${res.message}'));
      }

      results.add(res);
    }

    return results;
  }
}
