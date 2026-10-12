import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

/// Utilities to generate and install MCP client configurations for Claude Desktop, Cursor, and Roo Code.
class McpConfigInstaller {
  /// Resolves the default Claude Desktop configuration file path across platforms.
  static String? resolveClaudeDesktopConfigPath() {
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      if (appData != null && appData.isNotEmpty) {
        return p.join(appData, 'Claude', 'claude_desktop_config.json');
      }
    } else if (Platform.isMacOS) {
      final home = Platform.environment['HOME'];
      if (home != null && home.isNotEmpty) {
        return p.join(home, 'Library', 'Application Support', 'Claude',
            'claude_desktop_config.json');
      }
    } else if (Platform.isLinux) {
      final home = Platform.environment['HOME'];
      if (home != null && home.isNotEmpty) {
        return p.join(home, '.config', 'Claude', 'claude_desktop_config.json');
      }
    }
    return null;
  }

  /// Resolves the executable path to launch `tealkit`.
  static String resolveExecutableCommand() {
    final exec = Platform.resolvedExecutable;
    // If running compiled standalone binary
    if (exec.endsWith('tealkit.exe') || exec.endsWith('tealkit')) {
      return exec;
    }
    // If running via `dart run` or developmental build
    return 'tealkit';
  }

  /// Returns the MCP server config block for TealKit.
  static Map<String, dynamic> generateServerConfig({
    String? customCommand,
    List<String>? customArgs,
  }) {
    final cmd = customCommand ?? resolveExecutableCommand();
    final args = customArgs ?? ['mcp-serve'];

    return {
      'command': cmd,
      'args': args,
    };
  }

  /// Installs or updates TealKit in Claude Desktop's `claude_desktop_config.json`.
  static InstallResult installToClaudeDesktop({
    String? configPath,
    String? customCommand,
  }) {
    final targetPath = configPath ?? resolveClaudeDesktopConfigPath();
    if (targetPath == null) {
      return InstallResult(
        success: false,
        message: 'Could not determine Claude Desktop config location on this OS.',
      );
    }

    final file = File(targetPath);
    Map<String, dynamic> rootJson = {};

    if (file.existsSync()) {
      try {
        final content = file.readAsStringSync().trim();
        if (content.isNotEmpty) {
          final decoded = jsonDecode(content);
          if (decoded is Map<String, dynamic>) {
            rootJson = decoded;
          }
        }
      } catch (e) {
        return InstallResult(
          success: false,
          configPath: targetPath,
          message: 'Failed to parse existing config: $e',
        );
      }
    } else {
      file.parent.createSync(recursive: true);
    }

    final mcpServers = (rootJson['mcpServers'] as Map<String, dynamic>?) ?? {};
    final serverDef = generateServerConfig(customCommand: customCommand);

    mcpServers['tealkit'] = serverDef;
    rootJson['mcpServers'] = mcpServers;

    final formatted = const JsonEncoder.withIndent('  ').convert(rootJson);
    file.writeAsStringSync('$formatted\n');

    return InstallResult(
      success: true,
      configPath: targetPath,
      message: 'TealKit MCP server registered in Claude Desktop config.',
      serverDefinition: serverDef,
    );
  }

  /// Generates the Cursor settings snippet.
  static Map<String, dynamic> generateCursorConfig() {
    return {
      'mcpServers': {
        'tealkit': generateServerConfig(),
      }
    };
  }

  /// Generates the Roo Code / Cline settings snippet.
  static Map<String, dynamic> generateRooCodeConfig() {
    return {
      'mcpServers': {
        'tealkit': {
          ...generateServerConfig(),
          'autoApprove': [],
          'disabled': false,
        }
      }
    };
  }
}

class InstallResult {
  final bool success;
  final String? configPath;
  final String message;
  final Map<String, dynamic>? serverDefinition;

  InstallResult({
    required this.success,
    this.configPath,
    required this.message,
    this.serverDefinition,
  });
}
