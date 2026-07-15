import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../../services/app_logger.dart';
import '../../services/data_sources_settings_service.dart';
import '../../services/shell_script_service.dart';
import '../internal_mcp_server.dart';

/// Internal MCP server that provides SSH + SFTP tools for a remote Linux/Unix host.
///
/// Init params (task-level override – all optional; falls back to global settings):
///   host     – SSH hostname or IP
///   port     – SSH port (default 22)
///   username – SSH username
///   password – SSH password
///   privateKey – PEM-encoded private key (RSA/Ed25519/ECDSA). Overrides password auth when provided.
class SshMcpServer extends InternalMcpServer {
  // ── Connection params (overridable per task) ─────────────────
  String _host = '';
  int _port = 22;
  String _username = '';
  String _password = '';
  String _privateKey = '';

  // ── Lazy SSH client ──────────────────────────────────────────
  SSHClient? _client;

  // ─────────────────────────────────────────────────────────────
  // InternalMcpServer identity
  // ─────────────────────────────────────────────────────────────

  @override
  String get type => 'ssh';

  @override
  String get displayName => 'SSH / SFTP';

  @override
  String get description =>
      'Connect to a remote Linux/Unix server via SSH. '
      'Browse directories, read and upload files, execute commands, '
      'and manage reusable shell scripts.';

  @override
  String get iconName => 'terminal';

  // ─────────────────────────────────────────────────────────────
  // Init param schema
  // ─────────────────────────────────────────────────────────────

  @override
  Map<String, dynamic> get initParamSchema => {
    'host': {'type': 'string', 'description': 'SSH hostname or IP address. Leave empty to use global SSH settings.'},
    'port': {'type': 'integer', 'description': 'SSH port (default 22). Leave 0 to use global SSH settings.'},
    'username': {'type': 'string', 'description': 'SSH username. Leave empty to use global SSH settings.'},
    'password': {'type': 'string', 'description': 'SSH password. Leave empty to use global SSH settings.', 'sensitive': true},
    'privateKey': {
      'type': 'string',
      'description': 'PEM-encoded private key (RSA/Ed25519/ECDSA). Leave empty to use global SSH settings or password auth.',
      'sensitive': true,
    },
  };

  @override
  Map<String, dynamic> get defaultInitParams => {'host': '', 'port': 0, 'username': '', 'password': '', 'privateKey': ''};

  // ─────────────────────────────────────────────────────────────
  // Default system prompt
  // ─────────────────────────────────────────────────────────────

  @override
  String get defaultSystemPrompt =>
      '''You have SSH access to a remote Linux/Unix server. Use the available tools to assist the user with server management, file operations, and automation.

## Available Tools

- **list_directory** – List files and directories at a given path.
- **read_file** – Read the text content of a remote file.
- **download_file** – Download a binary or text file as base-64 content.
- **upload_file** – Upload a text file to the remote server.
- **execute_command** – Run an ad-hoc shell command on the remote server and return stdout/stderr.
- **list_scripts** – List saved shell scripts in the local script library.
- **run_script** – Run a saved shell script (by name or id) with optional arguments.

## Guidelines

- Always confirm destructive operations (file deletion, service restarts) with the user before executing.
- When showing directory listings, format them clearly (name, size, permissions).
- When executing commands, show the full stdout and stderr to the user.
- If `root` login is used on a production server, remind the user to use a dedicated user account instead.
- For multi-step automation, prefer combining commands with `&&` in a single `execute_command` call.
- **IMPORTANT**: When the user asks to "call script NAME", "run script NAME", or run a named script with arguments, ALWAYS use `run_script` with `scriptName` and `args` — never `execute_command`. The number after the script name is a script argument (put it in `args`), not a timeout.''';

  // ─────────────────────────────────────────────────────────────
  // Tools
  // ─────────────────────────────────────────────────────────────

  @override
  List<McpToolDescriptor> get tools => const [
    McpToolDescriptor(
      name: 'list_directory',
      description: 'List files and subdirectories at a remote path.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': 'Remote directory path (e.g. /home/user or ~).'},
        },
        'required': ['path'],
      },
    ),
    McpToolDescriptor(
      name: 'read_file',
      description: 'Read the text content of a remote file.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': 'Full remote path of the file to read.'},
          'maxBytes': {'type': 'integer', 'description': 'Maximum bytes to read (default 65536). Use 0 for unlimited.'},
        },
        'required': ['path'],
      },
    ),
    McpToolDescriptor(
      name: 'download_file',
      description: 'Download a remote file. Returns base-64 encoded content and MIME type.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': 'Full remote path of the file to download.'},
        },
        'required': ['path'],
      },
    ),
    McpToolDescriptor(
      name: 'upload_file',
      description:
          'Upload a file to the remote server. Provide either source (local filesystem path) or content (inline UTF-8 text or base64).',
      inputSchema: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': 'Full remote path where the file should be written.'},
          'source': {
            'type': 'string',
            'description':
                'Local filesystem path to read and upload (e.g. /Downloads/report.csv). Takes precedence over content when supplied.',
          },
          'content': {'type': 'string', 'description': 'Inline file content – UTF-8 text or base64-encoded bytes.'},
          'encoding': {'type': 'string', 'description': 'Set to "base64" when content is base64-encoded (default: utf8).'},
          'permissions': {'type': 'string', 'description': 'Optional octal permission string e.g. "755" or "644".'},
        },
        'required': ['path'],
      },
    ),
    McpToolDescriptor(
      name: 'make_directory',
      description: 'Create a directory (and all missing parent directories) on the remote server.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': 'Full remote path of the directory to create.'},
        },
        'required': ['path'],
      },
    ),
    McpToolDescriptor(
      name: 'remove_directory',
      description: 'Remove an EMPTY directory on the remote server. Fails if the directory is not empty.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': 'Full remote path of the empty directory to remove.'},
        },
        'required': ['path'],
      },
    ),
    McpToolDescriptor(
      name: 'list_scripts',
      description: 'List all saved shell scripts in the local script library.',
      inputSchema: {'type': 'object', 'properties': {}},
    ),
    McpToolDescriptor(
      name: 'run_script',
      description:
          'Run a saved script from the local script library by name. '
          'ALWAYS use this (never execute_command) when the user says "call script NAME", "run script NAME", or provides a script name with arguments. '
          'Numbers after the script name are script arguments — put them in args.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'scriptName': {'type': 'string', 'description': 'The name of the saved script to run.'},
          'scriptId': {'type': 'string', 'description': 'Optional id of the saved script (overrides scriptName).'},
          'args': {
            'type': 'string',
            'description':
                'Arguments passed to the script as a space-separated string (e.g. "15" or "/tmp 6"). '
                'These are the script\'s own parameters, not a timeout.',
          },
        },
        'required': ['scriptName'],
      },
    ),
    McpToolDescriptor(
      name: 'execute_command',
      description:
          'Execute a raw ad-hoc shell command. Use ONLY for one-off commands like "df -h" or "systemctl status nginx". '
          'Do NOT use this to run a script from the script library — use run_script for that.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'command': {'type': 'string', 'description': 'Shell command to execute.'},
        },
        'required': ['command'],
      },
    ),
  ];

  // ─────────────────────────────────────────────────────────────
  // initialize()
  // ─────────────────────────────────────────────────────────────

  @override
  Future<void> initialize(Map<String, dynamic> initParams) async {
    final svc = DataSourcesSettingsService.instance;
    if (!svc.isLoaded) await svc.load();

    // Task-level params override globals when non-empty/non-zero.
    final paramHost = (initParams['host'] as String? ?? '').trim();
    final paramPort = (initParams['port'] as int?) ?? 0;
    final paramUser = (initParams['username'] as String? ?? '').trim();
    final paramPass = (initParams['password'] as String? ?? '').trim();
    final paramKey = (initParams['privateKey'] as String? ?? '').trim();

    _host = paramHost.isNotEmpty ? paramHost : svc.sshHost;
    _port = (paramPort > 0) ? paramPort : svc.sshPort;
    _username = paramUser.isNotEmpty ? paramUser : svc.sshUsername;
    _password = paramPass.isNotEmpty ? paramPass : svc.sshPassword;
    _privateKey = paramKey.isNotEmpty ? paramKey : svc.sshPrivateKey;

    // Warn about root login on non-local hosts.
    if (_username == 'root' && _host.isNotEmpty && !_isLocalAddress(_host)) {
      log.warning(
        '[SSH] WARNING: Connecting as root to a remote host ($_host). '
        'Consider using a dedicated unprivileged user account.',
      );
    }
    log.info('[SSH] Initialized – host=$_host, port=$_port, user=$_username');
  }

  // ─────────────────────────────────────────────────────────────
  // executeTool()
  // ─────────────────────────────────────────────────────────────

  @override
  Future<Map<String, dynamic>> executeTool(String toolName, Map<String, dynamic> arguments) async {
    switch (toolName) {
      case 'list_directory':
        return _listDirectory(arguments['path'] as String? ?? '.');
      case 'read_file':
        final maxBytes = (arguments['maxBytes'] as int?) ?? 65536;
        return _readFile(arguments['path'] as String? ?? '', maxBytes: maxBytes);
      case 'download_file':
        return _downloadFile(arguments['path'] as String? ?? '');
      case 'upload_file':
        return _uploadFile(
          path: arguments['path'] as String? ?? '',
          source: arguments['source'] as String?,
          content: arguments['content'] as String?,
          encoding: arguments['encoding'] as String?,
          permissions: arguments['permissions'] as String?,
        );
      case 'make_directory':
        return _makeDirectory(arguments['path'] as String? ?? '');
      case 'remove_directory':
        return _removeDirectory(arguments['path'] as String? ?? '');
      case 'execute_command':
        final rawCmd = arguments['command'] as String? ?? '';
        // Auto-redirect: if the command is just a known script name/path, use run_script.
        final scriptRedirect = _matchLibraryScript(rawCmd);
        if (scriptRedirect != null) {
          return _runScript(scriptName: scriptRedirect.$1, args: scriptRedirect.$2);
        }
        final timeout = ((arguments['timeoutSeconds'] as int?) ?? 30).clamp(1, 300);
        return _executeCommand(rawCmd, timeoutSeconds: timeout);
      case 'list_scripts':
        return _listScripts();
      case 'run_script':
        return _runScript(
          scriptId: arguments['scriptId'] as String?,
          scriptName: arguments['scriptName'] as String? ?? '',
          args: _coerceArgs(arguments['args']),
        );
      default:
        return {'error': 'Unknown tool: $toolName'};
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Tool implementations
  // ─────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _listDirectory(String path) async {
    try {
      final sftp = await _sftp();
      final entries = await sftp.listdir(path);
      final items = entries.where((e) => e.filename != '.' && e.filename != '..').map((e) {
        final attr = e.attr;
        final fileType = attr.mode?.type;
        return {
          'name': e.filename,
          'isDirectory': fileType == SftpFileType.directory,
          'isFile': fileType == SftpFileType.regularFile,
          'isSymlink': fileType == SftpFileType.symbolicLink,
          'size': attr.size ?? 0,
          'permissions': _formatPermissions(attr.mode?.value ?? 0),
          'modified': attr.modifyTime != null ? DateTime.fromMillisecondsSinceEpoch(attr.modifyTime! * 1000).toIso8601String() : null,
        };
      }).toList();

      // Sort: directories first, then files, both alphabetically.
      items.sort((a, b) {
        final aDir = a['isDirectory'] as bool? ?? false;
        final bDir = b['isDirectory'] as bool? ?? false;
        if (aDir != bDir) return aDir ? -1 : 1;
        return (a['name'] as String).compareTo(b['name'] as String);
      });

      return {'path': path, 'count': items.length, 'entries': items};
    } catch (e) {
      return {'error': 'list_directory failed: $e'};
    }
  }

  Future<Map<String, dynamic>> _readFile(String path, {int maxBytes = 65536}) async {
    try {
      final sftp = await _sftp();
      final file = await sftp.open(path, mode: SftpFileOpenMode.read);
      final bytes = maxBytes > 0 ? await file.readBytes(length: maxBytes) : await file.readBytes();
      await file.close();
      final content = utf8.decode(bytes, allowMalformed: true);
      return {'path': path, 'content': content, 'bytes': bytes.length, 'truncated': maxBytes > 0 && bytes.length >= maxBytes};
    } catch (e) {
      return {'error': 'read_file failed: $e'};
    }
  }

  Future<Map<String, dynamic>> _downloadFile(String path) async {
    try {
      final sftp = await _sftp();
      final file = await sftp.open(path, mode: SftpFileOpenMode.read);
      final bytes = await file.readBytes();
      await file.close();
      final fileName = path.split('/').last;
      final mimeType = _mimeTypeFromExtension(fileName);
      final b64 = base64Encode(bytes);
      return {'path': path, 'bytes': bytes.length, 'fileName': fileName, 'mimeType': mimeType, 'encoding': 'base64', 'content': b64};
    } catch (e) {
      return {'error': 'download_file failed: $e'};
    }
  }

  /// Returns a MIME type string based on the file extension.
  String _mimeTypeFromExtension(String fileName) {
    final ext = fileName.contains('.') ? fileName.split('.').last.toLowerCase() : '';
    const map = {
      'txt': 'text/plain',
      'csv': 'text/csv',
      'json': 'application/json',
      'xml': 'application/xml',
      'html': 'text/html',
      'htm': 'text/html',
      'md': 'text/markdown',
      'pdf': 'application/pdf',
      'zip': 'application/zip',
      'gz': 'application/gzip',
      'tar': 'application/x-tar',
      'sh': 'text/x-shellscript',
      'log': 'text/plain',
      'conf': 'text/plain',
      'yaml': 'text/yaml',
      'yml': 'text/yaml',
      'toml': 'text/plain',
      'ini': 'text/plain',
      'py': 'text/x-python',
      'dart': 'text/x-dart',
      'js': 'text/javascript',
      'ts': 'text/typescript',
      'png': 'image/png',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'gif': 'image/gif',
      'svg': 'image/svg+xml',
      'xls': 'application/vnd.ms-excel',
      'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'doc': 'application/msword',
      'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    };
    return map[ext] ?? 'application/octet-stream';
  }

  Future<Map<String, dynamic>> _uploadFile({
    required String path,
    String? source,
    String? content,
    String? encoding,
    String? permissions,
  }) async {
    if (path.isEmpty) return {'error': 'upload_file: path is required'};
    try {
      Uint8List bytes;
      if (source != null && source.isNotEmpty) {
        // Read from local filesystem path.
        final localFile = File(source);
        if (!localFile.existsSync()) return {'error': 'upload_file: source file not found: $source'};
        bytes = await localFile.readAsBytes();
      } else if (content != null) {
        if (encoding == 'base64') {
          bytes = base64Decode(content);
        } else {
          bytes = Uint8List.fromList(utf8.encode(content));
        }
      } else {
        return {'error': 'upload_file: provide either source (local path) or content'};
      }

      final sftp = await _sftp();
      final file = await sftp.open(path, mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate);
      await file.writeBytes(bytes);
      await file.close();

      if (permissions != null && permissions.isNotEmpty) {
        await _runRawCommand('chmod $permissions ${_shellEscape(path)}');
      }

      return {'success': true, 'path': path, 'bytes': bytes.length};
    } catch (e) {
      return {'error': 'upload_file failed: $e'};
    }
  }

  Future<Map<String, dynamic>> _makeDirectory(String path) async {
    if (path.isEmpty) return {'error': 'make_directory: path is required'};
    try {
      final result = await _executeCommand('mkdir -p ${_shellEscape(path)}');
      if ((result['exitCode'] as int? ?? -1) != 0) {
        return {'error': result['stderr'] ?? 'mkdir failed'};
      }
      return {'success': true, 'path': path};
    } catch (e) {
      return {'error': 'make_directory failed: $e'};
    }
  }

  Future<Map<String, dynamic>> _removeDirectory(String path) async {
    if (path.isEmpty) return {'error': 'remove_directory: path is required'};
    try {
      final result = await _executeCommand('rmdir ${_shellEscape(path)}');
      if ((result['exitCode'] as int? ?? -1) != 0) {
        return {'error': (result['stderr'] as String?)?.isNotEmpty == true ? result['stderr'] : 'Directory not empty or does not exist'};
      }
      return {'success': true, 'path': path};
    } catch (e) {
      return {'error': 'remove_directory failed: $e'};
    }
  }

  Future<Map<String, dynamic>> _executeCommand(String command, {int timeoutSeconds = 30}) async {
    if (command.trim().isEmpty) return {'error': 'command is empty'};
    try {
      final client = await _connect();
      final session = await client.execute(command);

      // Drain streams with timeout.
      final stdoutBytes = BytesBuilder();
      final stderrBytes = BytesBuilder();
      await Future.wait([
        session.stdout.forEach(stdoutBytes.add),
        session.stderr.forEach(stderrBytes.add),
      ]).timeout(Duration(seconds: timeoutSeconds), onTimeout: () => throw TimeoutException('Command timed out after ${timeoutSeconds}s'));

      final exitCode = session.exitCode;
      return {
        'command': command,
        'exitCode': exitCode ?? -1,
        'stdout': utf8.decode(stdoutBytes.takeBytes(), allowMalformed: true),
        'stderr': utf8.decode(stderrBytes.takeBytes(), allowMalformed: true),
        'success': (exitCode ?? -1) == 0,
      };
    } catch (e) {
      return {'error': 'execute_command failed: $e', 'command': command};
    }
  }

  Future<Map<String, dynamic>> _listScripts() async {
    final scripts = ScriptLibraryService.instance.scripts;
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

  Future<Map<String, dynamic>> _runScript({String? scriptId, required String scriptName, String args = ''}) async {
    ShellScript? script;
    if (scriptId != null && scriptId.trim().isNotEmpty) {
      script = ScriptLibraryService.instance.findById(scriptId.trim());
    }
    script ??= _findScriptByName(scriptName.trim());
    if (script == null) {
      return {'error': 'Script not found: ${scriptId ?? scriptName}', 'scriptName': scriptName};
    }
    final timeoutSeconds = script.timeoutSeconds.clamp(5, 600);
    // Normalize named-param style args (e.g. -duration=15 or --folder=/tmp)
    // into positional values so simple scripts that use $1 $2 work correctly.
    final normalizedArgs = _normalizeScriptArgs(args);

    if (script.runLocally && (Platform.isLinux || Platform.isMacOS)) {
      return _runLocalScript(script: script, args: normalizedArgs, timeoutSeconds: timeoutSeconds);
    }

    try {
      final client = await _connect();

      // Upload script to a temp file on the remote host, execute, then clean up.
      final tmpPath = '/tmp/.tealkit_script_${script.id.replaceAll('-', '')}.sh';
      final sftp = await client.sftp();
      final scriptBytes = Uint8List.fromList(utf8.encode(script.content));
      final remoteFile = await sftp.open(tmpPath, mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate);
      await remoteFile.writeBytes(scriptBytes);
      await remoteFile.close();

      final command =
          'chmod +x ${_shellEscape(tmpPath)} && ${_shellEscape(tmpPath)}${normalizedArgs.isNotEmpty ? ' $normalizedArgs' : ''} ; rm -f ${_shellEscape(tmpPath)}';
      final session = await client.execute(command);

      final stdoutBytes2 = BytesBuilder();
      final stderrBytes2 = BytesBuilder();
      await Future.wait([
        session.stdout.forEach(stdoutBytes2.add),
        session.stderr.forEach(stderrBytes2.add),
      ]).timeout(Duration(seconds: timeoutSeconds), onTimeout: () => throw TimeoutException('Script timed out after ${timeoutSeconds}s'));

      final exitCode = session.exitCode;
      return {
        'scriptId': script.id,
        'scriptName': script.name,
        'exitCode': exitCode ?? -1,
        'stdout': utf8.decode(stdoutBytes2.takeBytes(), allowMalformed: true),
        'stderr': utf8.decode(stderrBytes2.takeBytes(), allowMalformed: true),
        'success': (exitCode ?? -1) == 0,
        'argsUsed': normalizedArgs,
      };
    } catch (e) {
      return {'error': 'run_script failed: $e', 'scriptId': scriptId, 'scriptName': scriptName};
    }
  }

  Future<Map<String, dynamic>> _runLocalScript({required ShellScript script, required String args, required int timeoutSeconds}) async {
    File? tempFile;
    try {
      final dir = await Directory.systemTemp.createTemp('tealkit_script_');
      tempFile = File('${dir.path}${Platform.pathSeparator}${script.id}.sh');
      await tempFile.writeAsString(script.content);

      final chmod = await Process.run('chmod', ['+x', tempFile.path]);
      if (chmod.exitCode != 0) {
        return {
          'error': 'run_script failed: chmod returned ${chmod.exitCode}',
          'stderr': (chmod.stderr ?? '').toString(),
          'scriptId': script.id,
          'scriptName': script.name,
        };
      }

      final argList = _splitArgs(args);
      final proc = await Process.run('/bin/bash', [tempFile.path, ...argList], runInShell: false).timeout(
        Duration(seconds: timeoutSeconds),
        onTimeout: () {
          throw TimeoutException('Script timed out after ${timeoutSeconds}s');
        },
      );

      return {
        'scriptId': script.id,
        'scriptName': script.name,
        'exitCode': proc.exitCode,
        'stdout': (proc.stdout ?? '').toString(),
        'stderr': (proc.stderr ?? '').toString(),
        'success': proc.exitCode == 0,
        'argsUsed': args,
        'executionMode': 'local',
      };
    } catch (e) {
      return {'error': 'run_script failed: $e', 'scriptId': script.id, 'scriptName': script.name};
    } finally {
      try {
        if (tempFile != null && await tempFile.exists()) {
          final parent = tempFile.parent;
          await tempFile.delete();
          if (await parent.exists()) await parent.delete();
        }
      } catch (_) {}
    }
  }

  ShellScript? _findScriptByName(String name) {
    if (name.isEmpty) return null;
    final scripts = ScriptLibraryService.instance.scripts;
    final exact = scripts.where((s) => s.name == name).toList();
    if (exact.isNotEmpty) return exact.first;
    final lower = name.toLowerCase();
    final ci = scripts.where((s) => s.name.toLowerCase() == lower).toList();
    return ci.isNotEmpty ? ci.first : null;
  }

  /// Coerces any JSON type the model might send for `args` into a String.
  /// - String → returned as-is
  /// - List   → elements joined with spaces  (e.g. [3] → "3", ["a","b"] → "a b")
  /// - other  → toString()
  String _coerceArgs(dynamic raw) {
    if (raw == null) return '';
    if (raw is List) return raw.map((e) => e.toString()).join(' ');
    if (raw is Map) return raw.values.map((e) => e.toString()).join(' ');
    if (raw is String) {
      final s = raw.trim();
      // Framework may deliver [3] or {"duration":3} as a pre-serialised string.
      if ((s.startsWith('[') && s.endsWith(']')) || (s.startsWith('{') && s.endsWith('}'))) {
        try {
          final parsed = jsonDecode(s);
          return _coerceArgs(parsed); // recurse with real type
        } catch (_) {}
      }
      return raw;
    }
    return raw.toString();
  }

  /// Normalises LLM-generated named-param style args into positional values
  /// so shell scripts that use $1 $2 receive plain values.
  ///
  /// Handles both forms a small model commonly produces:
  ///   "-duration=15"       → "15"    (equals-separated)
  ///   "--folder=/tmp"      → "/tmp"
  ///   "-duration 15"       → "15"    (space-separated pair: flag name stripped)
  ///   "-folder /tmp -m 6"  → "/tmp 6"
  ///   "15"                 → "15"    (already positional — unchanged)
  String _normalizeScriptArgs(String args) {
    if (args.isEmpty) return args;
    final tokens = args.trim().split(RegExp(r'\s+'));

    // Pass 1: convert -name=value / --name=value → value
    final pass1 = tokens.map((token) {
      final match = RegExp(r'^-{1,2}[a-zA-Z_][a-zA-Z0-9_]*=(.+)$').firstMatch(token);
      return match != null ? match.group(1)! : token;
    }).toList();

    // Pass 2: drop -name tokens that precede a plain (non-flag) value.
    // This handles "-duration 15" → "15", "-folder /tmp -m 6" → "/tmp 6".
    final isFlagName = RegExp(r'^-{1,2}[a-zA-Z]');
    final result = <String>[];
    for (int i = 0; i < pass1.length; i++) {
      final t = pass1[i];
      if (isFlagName.hasMatch(t)) {
        // Skip this flag name token; if next token is a plain value, it will be
        // collected on the next iteration. If next is also a flag (or none),
        // the flag is boolean/unknown — drop it too (can't map positionally).
        continue;
      }
      result.add(t);
    }

    final normalized = result.join(' ');
    if (normalized != args.trim()) {
      log.info('[SSH] args normalize: "$args" → "$normalized"');
    }
    return normalized;
  }

  /// args), returns (scriptName, args).  Otherwise returns null.
  ///
  /// Handles patterns a small model commonly produces:
  ///   cpu_usage 15
  ///   ./cpu_usage.sh 15
  ///   /usr/local/bin/cpu_usage.sh 15
  ///   bash cpu_usage.sh 15
  ///   sh /tmp/.tealkit_script_xxx.sh 15
  (String, String)? _matchLibraryScript(String command) {
    final cmd = command.trim();
    if (cmd.isEmpty) return null;

    final scripts = ScriptLibraryService.instance.scripts;
    if (scripts.isEmpty) return null;

    // Split into [executable, ...args]
    final parts = cmd.split(RegExp(r'\s+'));
    final exe = parts.first;

    // Strip path components, leading ./ and common extensions
    String stem(String s) {
      var name = s.split('/').last.split('\\').last;
      if (name.endsWith('.sh')) name = name.substring(0, name.length - 3);
      if (name.startsWith('./')) name = name.substring(2);
      return name.toLowerCase();
    }

    // Candidates: the executable itself, and (for "bash script.sh") the second token
    final candidates = [exe, if (parts.length >= 2 && (exe == 'bash' || exe == 'sh')) parts[1]];

    for (final candidate in candidates) {
      final s = stem(candidate);
      // Skip temp script paths generated by _runScript itself
      if (s.startsWith('.tealkit_script_')) continue;
      final match = scripts.where((sc) => sc.name.toLowerCase() == s).firstOrNull;
      if (match != null) {
        // Everything after the matched token is args
        final tokenIndex = parts.indexOf(candidate);
        final args = parts.skip(tokenIndex + 1).join(' ');
        log.info('[SSH] execute_command intercepted → run_script("${match.name}", args="$args")');
        return (match.name, args);
      }
    }
    return null;
  }

  // ─────────────────────────────────────────────────────────────
  // Connection helpers
  // ─────────────────────────────────────────────────────────────

  Future<SSHClient> _connect() async {
    if (_client != null) return _client!;
    if (_host.isEmpty) {
      throw StateError('SSH host is not configured. Set global SSH settings or task-level SSH params.');
    }
    _client = SSHClient(
      await SSHSocket.connect(_host, _port),
      username: _username,
      identities: _privateKey.isNotEmpty ? SSHKeyPair.fromPem(_privateKey) : null,
      onPasswordRequest: () => _password,
    );
    await _client!.authenticated;
    log.info('[SSH] Connected to $_host:$_port as $_username');
    return _client!;
  }

  SftpClient? _sftpClient;

  Future<SftpClient> _sftp() async {
    if (_sftpClient != null) return _sftpClient!;
    final client = await _connect();
    _sftpClient = await client.sftp();
    return _sftpClient!;
  }

  Future<void> _runRawCommand(String cmd) async {
    final client = await _connect();
    final session = await client.execute(cmd);
    await session.stdout.drain<void>();
    await session.stderr.drain<void>();
    // exitCode is synchronous after streams are drained.
    // ignore: unnecessary_statements
    session.exitCode;
  }

  @override
  Future<void> dispose() async {
    _sftpClient?.close();
    _sftpClient = null;
    _client?.close();
    _client = null;
  }

  /// Run [content] as a temporary shell script on the configured SSH host.
  /// Used by the script editor's Test Run button — no need to save the script first.
  /// Optional SSH override params take precedence over global SSH settings.
  static Future<Map<String, dynamic>> runContentForTest(
    String content, {
    String args = '',
    int timeoutSeconds = 60,
    bool runLocally = false,
    String sshHost = '',
    int sshPort = 0,
    String sshUsername = '',
    String sshPassword = '',
  }) async {
    if (runLocally) {
      if (!(Platform.isLinux || Platform.isMacOS)) {
        return {'error': 'Local shell mode is only supported on Linux and macOS.'};
      }
      return _runContentForTestLocally(content, args: args, timeoutSeconds: timeoutSeconds);
    }

    final server = SshMcpServer();
    await server.initialize({
      if (sshHost.isNotEmpty) 'host': sshHost,
      if (sshPort > 0) 'port': sshPort,
      if (sshUsername.isNotEmpty) 'username': sshUsername,
      if (sshPassword.isNotEmpty) 'password': sshPassword,
    });
    try {
      return await server._executeContentAsTempScript(content, args: args, timeoutSeconds: timeoutSeconds);
    } finally {
      await server.dispose();
    }
  }

  static Future<Map<String, dynamic>> _runContentForTestLocally(String content, {String args = '', int timeoutSeconds = 60}) async {
    File? tempFile;
    try {
      final dir = await Directory.systemTemp.createTemp('tealkit_test_');
      tempFile = File('${dir.path}${Platform.pathSeparator}script.sh');
      await tempFile.writeAsString(content);

      final chmod = await Process.run('chmod', ['+x', tempFile.path]);
      if (chmod.exitCode != 0) {
        return {'error': 'Test run failed: chmod returned ${chmod.exitCode}', 'stderr': (chmod.stderr ?? '').toString()};
      }

      final argList = _splitArgs(args);
      final result = await Process.run('/bin/bash', [tempFile.path, ...argList], runInShell: false).timeout(
        Duration(seconds: timeoutSeconds),
        onTimeout: () {
          throw TimeoutException('Script timed out after ${timeoutSeconds}s');
        },
      );

      return {
        'exitCode': result.exitCode,
        'stdout': (result.stdout ?? '').toString(),
        'stderr': (result.stderr ?? '').toString(),
        'success': result.exitCode == 0,
        'executionMode': 'local',
      };
    } catch (e) {
      return {'error': 'Test run failed: $e'};
    } finally {
      try {
        if (tempFile != null && await tempFile.exists()) {
          final parent = tempFile.parent;
          await tempFile.delete();
          if (await parent.exists()) await parent.delete();
        }
      } catch (_) {}
    }
  }

  /// Test SSH connectivity with explicit credentials.
  /// Returns a map with 'success' (bool) and 'message' (String).
  static Future<Map<String, dynamic>> testConnection({
    required String host,
    required int port,
    required String username,
    required String password,
  }) async {
    if (host.isEmpty || username.isEmpty) {
      return {'success': false, 'message': 'Host and username are required.'};
    }
    try {
      final socket = await SSHSocket.connect(host, port).timeout(const Duration(seconds: 10));
      final client = SSHClient(socket, username: username, onPasswordRequest: () => password);
      await client.authenticated.timeout(const Duration(seconds: 15));
      client.close();
      return {'success': true, 'message': 'Connected to $host:$port as $username.'};
    } catch (e) {
      return {'success': false, 'message': e.toString()};
    }
  }

  Future<Map<String, dynamic>> _executeContentAsTempScript(String content, {String args = '', int timeoutSeconds = 60}) async {
    try {
      final client = await _connect();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final tmpPath = '/tmp/.tealkit_test_$timestamp.sh';
      final sftp = await client.sftp();
      final scriptBytes = Uint8List.fromList(utf8.encode(content));
      final remoteFile = await sftp.open(tmpPath, mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate);
      await remoteFile.writeBytes(scriptBytes);
      await remoteFile.close();

      final command =
          'chmod +x ${_shellEscape(tmpPath)} && ${_shellEscape(tmpPath)}${args.isNotEmpty ? ' $args' : ''} ; rm -f ${_shellEscape(tmpPath)}';
      final session = await client.execute(command);

      final stdoutBytes = BytesBuilder();
      final stderrBytes = BytesBuilder();
      await Future.wait([
        session.stdout.forEach(stdoutBytes.add),
        session.stderr.forEach(stderrBytes.add),
      ]).timeout(Duration(seconds: timeoutSeconds), onTimeout: () => throw TimeoutException('Script timed out after ${timeoutSeconds}s'));

      final exitCode = session.exitCode;
      return {
        'exitCode': exitCode ?? -1,
        'stdout': utf8.decode(stdoutBytes.takeBytes(), allowMalformed: true),
        'stderr': utf8.decode(stderrBytes.takeBytes(), allowMalformed: true),
        'success': (exitCode ?? -1) == 0,
      };
    } catch (e) {
      return {'error': 'Test run failed: $e'};
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Util helpers
  // ─────────────────────────────────────────────────────────────

  /// True if [host] looks like a loopback / LAN address, not a public server.
  static bool _isLocalAddress(String host) {
    if (host == 'localhost' || host == '127.0.0.1' || host == '::1') return true;
    if (host.startsWith('192.168.') || host.startsWith('10.') || host.startsWith('172.')) return true;
    return false;
  }

  /// Minimal shell-escaping: wraps in single quotes, escaping any embedded single quotes.
  static String _shellEscape(String s) => "'${s.replaceAll("'", "'\\''")}'";

  static List<String> _splitArgs(String args) {
    final trimmed = args.trim();
    if (trimmed.isEmpty) return const [];
    final matches = RegExp(r'''[^\s"']+|"[^"]*"|'[^']*' ''').allMatches(trimmed);
    final out = <String>[];
    for (final m in matches) {
      var token = m.group(0) ?? '';
      if ((token.startsWith('"') && token.endsWith('"')) || (token.startsWith("'") && token.endsWith("'"))) {
        token = token.substring(1, token.length - 1);
      }
      if (token.isNotEmpty) out.add(token);
    }
    return out;
  }

  /// Convert a unix mode integer to a readable permissions string (e.g. "rwxr-xr--").
  static String _formatPermissions(int mode) {
    const chars = 'rwxrwxrwx';
    final buf = StringBuffer();
    for (var i = 8; i >= 0; i--) {
      buf.write((mode >> i) & 1 == 1 ? chars[8 - i] : '-');
    }
    return buf.toString();
  }
}
