import 'dart:convert';
import 'dart:io';

import '../../services/app_logger.dart';
import '../../services/local_shell_script_service.dart';
import '../internal_mcp_server.dart';

/// Internal MCP server that runs shell scripts and commands directly on the
/// local Linux / macOS machine.
///
/// Platform guard: all tool calls return an error on non-Linux/macOS platforms.
class LocalShellMcpServer extends InternalMcpServer {
  // ─────────────────────────────────────────────────────────────
  // Identity
  // ─────────────────────────────────────────────────────────────

  @override
  String get type => 'local_shell';

  @override
  String get displayName => 'Local Shell';

  @override
  String get description =>
      'Execute shell scripts and commands directly on this Linux/macOS desktop. '
      'Run saved scripts from the local shell library, execute ad-hoc bash commands, '
      'browse the local filesystem, and read local files.';

  @override
  String get iconName => 'terminal';

  // ─────────────────────────────────────────────────────────────
  // Init param schema — no task-level config needed
  // ─────────────────────────────────────────────────────────────

  @override
  Map<String, dynamic> get initParamSchema => {};

  @override
  Map<String, dynamic> get defaultInitParams => {};

  // ─────────────────────────────────────────────────────────────
  // Default system prompt
  // ─────────────────────────────────────────────────────────────

  @override
  String get defaultSystemPrompt =>
      '''You have direct shell access to the local Linux/macOS machine. Use the available tools to help the user with local automation, file management, and script execution.

## Available Tools
- **list_local_scripts** – List all saved shell scripts in the local script library.
- **run_local_script** – Run a saved script from the local script library by name.
- **execute_local_command** – Run an ad-hoc bash command on the local machine.
- **list_local_directory** – List files and directories at a local path.
- **read_local_file** – Read the text content of a local file.

## Guidelines

- Always confirm destructive operations (file deletion, data wipes) with the user before executing.
- When showing directory listings, format them clearly.
- When executing commands, show the full stdout and stderr to the user.
- **IMPORTANT**: When the user asks to "call script NAME", "run script NAME", or run a named script with arguments, ALWAYS use `run_local_script` with `scriptName` — never `execute_local_command`.''';

  // ─────────────────────────────────────────────────────────────
  // Tools
  // ─────────────────────────────────────────────────────────────

  @override
  List<McpToolDescriptor> get tools => const [
    McpToolDescriptor(
      name: 'list_local_scripts',
      description: 'List all saved shell scripts in the local script library.',
      inputSchema: {'type': 'object', 'properties': {}},
    ),
    McpToolDescriptor(
      name: 'run_local_script',
      description:
          'Run a saved script from the local script library by name. '
          'ALWAYS use this (never execute_local_command) when the user says "call script NAME", "run script NAME", or provides a script name with arguments.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'scriptName': {'type': 'string', 'description': 'The name of the saved script to run.'},
          'scriptId': {'type': 'string', 'description': 'Optional id of the saved script (overrides scriptName).'},
          'args': {'type': 'string', 'description': 'Arguments passed to the script as a space-separated string (e.g. "15" or "/tmp 6").'},
          'timeoutSeconds': {'type': 'integer', 'description': 'Execution timeout in seconds (default 120).'},
        },
        'required': ['scriptName'],
      },
    ),
    McpToolDescriptor(
      name: 'execute_local_command',
      description:
          'Execute a raw ad-hoc bash command on the local machine. '
          'Use ONLY for one-off commands like "df -h" or "ls /tmp". '
          'Do NOT use this to run a script from the library — use run_local_script for that.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'command': {'type': 'string', 'description': 'Bash command to execute.'},
          'timeoutSeconds': {'type': 'integer', 'description': 'Execution timeout in seconds (default 30).'},
        },
        'required': ['command'],
      },
    ),
    McpToolDescriptor(
      name: 'list_local_directory',
      description: 'List files and subdirectories at a local path.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': 'Local directory path (e.g. /home/user or ~).'},
        },
        'required': ['path'],
      },
    ),
    McpToolDescriptor(
      name: 'read_local_file',
      description: 'Read the text content of a local file.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': 'Full local path of the file to read.'},
          'maxBytes': {'type': 'integer', 'description': 'Maximum bytes to read (default 65536). Use 0 for unlimited.'},
        },
        'required': ['path'],
      },
    ),
  ];

  // ─────────────────────────────────────────────────────────────
  // initialize()
  // ─────────────────────────────────────────────────────────────

  @override
  Future<void> initialize(Map<String, dynamic> initParams) async {
    if (!Platform.isLinux && !Platform.isMacOS) {
      log.warning('[LocalShell] Initialized on non-Linux/macOS platform — tools will return errors.');
      return;
    }
    await LocalShellScriptService.instance.load();
    log.info('[LocalShell] Initialized – ${LocalShellScriptService.instance.scripts.length} scripts loaded');
  }

  // ─────────────────────────────────────────────────────────────
  // executeTool()
  // ─────────────────────────────────────────────────────────────

  @override
  Future<Map<String, dynamic>> executeTool(String toolName, Map<String, dynamic> arguments) async {
    if (!Platform.isLinux && !Platform.isMacOS) {
      return {'error': 'Local shell tools are only available on Linux and macOS.'};
    }
    switch (toolName) {
      case 'list_local_scripts':
        return _listScripts();
      case 'run_local_script':
        return _runScript(
          scriptId: arguments['scriptId'] as String?,
          scriptName: arguments['scriptName'] as String? ?? '',
          args: _coerceArgs(arguments['args']),
          timeoutSeconds: (arguments['timeoutSeconds'] as int?) ?? 120,
        );
      case 'execute_local_command':
        // Auto-redirect: if the command matches a known script name, use run_local_script.
        final cmd = (arguments['command'] as String? ?? '').trim();
        final redirect = _matchLibraryScript(cmd);
        if (redirect != null) {
          return _runScript(scriptName: redirect.$1, args: redirect.$2);
        }
        final timeout = ((arguments['timeoutSeconds'] as int?) ?? 30).clamp(1, 300);
        return _executeCommand(cmd, timeoutSeconds: timeout);
      case 'list_local_directory':
        return _listDirectory(arguments['path'] as String? ?? '.');
      case 'read_local_file':
        return _readFile(arguments['path'] as String? ?? '', maxBytes: (arguments['maxBytes'] as int?) ?? 65536);
      default:
        return {'error': 'Unknown tool: $toolName'};
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Tool implementations
  // ─────────────────────────────────────────────────────────────

  Map<String, dynamic> _listScripts() {
    final scripts = LocalShellScriptService.instance.scripts;
    return {
      'count': scripts.length,
      'scripts': scripts
          .map(
            (s) => {
              'id': s.id,
              'name': s.name,
              'description': s.description,
              'updatedAt': s.updatedAt.toIso8601String(),
              'lines': '\n'.allMatches(s.content).length + 1,
            },
          )
          .toList(),
    };
  }

  Future<Map<String, dynamic>> _runScript({
    String? scriptId,
    required String scriptName,
    String args = '',
    int timeoutSeconds = 120,
  }) async {
    final svc = LocalShellScriptService.instance;
    LocalShellScript? script;

    if (scriptId != null && scriptId.isNotEmpty) {
      script = svc.findById(scriptId);
    }
    script ??= svc.scripts.where((s) => s.name.toLowerCase() == scriptName.toLowerCase()).firstOrNull;

    if (script == null) {
      return {'error': 'Script not found: "$scriptName"', 'availableScripts': svc.scripts.map((s) => s.name).toList()};
    }

    log.info('[LocalShell] Running script "${script.name}" args="$args"');
    return svc.runScript(script, args: args, timeoutSeconds: timeoutSeconds);
  }

  Future<Map<String, dynamic>> _executeCommand(String command, {int timeoutSeconds = 30}) async {
    if (command.trim().isEmpty) return {'error': 'command is empty'};
    try {
      final result = await Process.run(
        '/bin/bash',
        ['-c', command],
        runInShell: false,
      ).timeout(Duration(seconds: timeoutSeconds), onTimeout: () => throw Exception('Command timed out after ${timeoutSeconds}s'));
      return {
        'command': command,
        'exitCode': result.exitCode,
        'stdout': result.stdout.toString(),
        'stderr': result.stderr.toString(),
        'success': result.exitCode == 0,
      };
    } catch (e) {
      return {'error': 'execute_local_command failed: $e', 'command': command};
    }
  }

  Future<Map<String, dynamic>> _listDirectory(String path) async {
    try {
      // Expand ~ to the home directory.
      final expandedPath = path.startsWith('~/') || path == '~' ? path.replaceFirst('~', Platform.environment['HOME'] ?? '~') : path;

      final dir = Directory(expandedPath);
      if (!dir.existsSync()) {
        return {'error': 'Directory not found: $path'};
      }

      final entries = dir.listSync(followLinks: false);
      final items = entries.map((e) {
        final stat = e.statSync();
        return {
          'name': e.path.split(Platform.pathSeparator).last,
          'isDirectory': e is Directory,
          'isFile': e is File,
          'isLink': e is Link,
          'size': stat.size,
          'modified': stat.modified.toIso8601String(),
          'permissions': _formatPermissions(stat.mode),
        };
      }).toList();

      // Sort: directories first, then files, both alphabetically.
      items.sort((a, b) {
        final aDir = a['isDirectory'] as bool? ?? false;
        final bDir = b['isDirectory'] as bool? ?? false;
        if (aDir != bDir) return aDir ? -1 : 1;
        return (a['name'] as String).compareTo(b['name'] as String);
      });

      return {'path': expandedPath, 'count': items.length, 'entries': items};
    } catch (e) {
      return {'error': 'list_local_directory failed: $e'};
    }
  }

  Future<Map<String, dynamic>> _readFile(String path, {int maxBytes = 65536}) async {
    try {
      final expandedPath = path.startsWith('~/') || path == '~' ? path.replaceFirst('~', Platform.environment['HOME'] ?? '~') : path;

      final file = File(expandedPath);
      if (!file.existsSync()) return {'error': 'File not found: $path'};

      final bytes = maxBytes > 0 ? (await file.openRead(0, maxBytes).toList()).expand((b) => b).toList() : await file.readAsBytes();

      final content = utf8.decode(bytes, allowMalformed: true);
      return {'path': expandedPath, 'content': content, 'bytes': bytes.length, 'truncated': maxBytes > 0 && bytes.length >= maxBytes};
    } catch (e) {
      return {'error': 'read_local_file failed: $e'};
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Helpers
  // ─────────────────────────────────────────────────────────────

  /// Auto-redirect: if [command] is just a known local script name (with optional args),
  /// returns (scriptName, args). Otherwise returns null.
  (String, String)? _matchLibraryScript(String command) {
    final cmd = command.trim();
    if (cmd.isEmpty) return null;

    final scripts = LocalShellScriptService.instance.scripts;
    if (scripts.isEmpty) return null;

    final parts = cmd.split(RegExp(r'\s+'));
    final exe = parts.first;

    String stem(String s) {
      var name = s.split('/').last.split('\\').last;
      if (name.endsWith('.sh')) name = name.substring(0, name.length - 3);
      if (name.startsWith('./')) name = name.substring(2);
      return name.toLowerCase();
    }

    final candidates = [exe, if (parts.length >= 2 && (exe == 'bash' || exe == 'sh')) parts[1]];

    for (final candidate in candidates) {
      final s = stem(candidate);
      if (s.startsWith('tealkit_local_')) continue;
      final match = scripts.where((sc) => sc.name.toLowerCase() == s).firstOrNull;
      if (match != null) {
        final tokenIndex = parts.indexOf(candidate);
        final args = parts.skip(tokenIndex + 1).join(' ');
        log.info('[LocalShell] execute_local_command intercepted → run_local_script("${match.name}", args="$args")');
        return (match.name, args);
      }
    }
    return null;
  }

  static String _coerceArgs(dynamic value) {
    if (value == null) return '';
    if (value is String) return value;
    if (value is num) return value.toString();
    return value.toString();
  }

  static String _formatPermissions(int mode) {
    final types = ['---', '--x', '-w-', '-wx', 'r--', 'r-x', 'rw-', 'rwx'];
    final owner = types[(mode >> 6) & 7];
    final group = types[(mode >> 3) & 7];
    final other = types[mode & 7];
    return '$owner$group$other';
  }
}
