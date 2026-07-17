/// In-process implementations of internal MCP tool handlers for the server.
///
/// These mirror the Flutter-app's InternalMcpServer implementations but depend
/// only on server-side services (no Flutter packages).
///
/// Supported types: 'ssh', 'weather', 'web_search'
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:enough_mail/enough_mail.dart';
import 'package:http/http.dart' as http;

import '../database/server_duckdb_service.dart';
import '../models/mcp_models.dart';
import '../services/server_data_sources_service.dart';
import '../services/server_indexing_service.dart';
import '../utils/semantic_embedding.dart';
import '../utils/server_logger.dart';

// ═══════════════════════════════════════════════════════════════
// Abstract base
// ═══════════════════════════════════════════════════════════════

/// Base for all server-side in-process MCP tool handlers.
abstract class ServerInternalMcp {
  List<MCPTool> get tools;
  Future<Map<String, dynamic>> callTool(String name, Map<String, dynamic> args);
  Future<void> dispose() async {}
  Future<void> refresh() async {}
}

// ═══════════════════════════════════════════════════════════════
// Factory
// ═══════════════════════════════════════════════════════════════

/// Create and initialise an in-process MCP handler for [mcpType].
/// Returns `null` when [mcpType] is not supported.
Future<ServerInternalMcp?> createServerInternalMcp(
  String mcpType,
  Map<String, dynamic> initParams,
) async {
  switch (mcpType) {
    case 'ssh':
      final impl = ServerSshMcp();
      await impl.initialize(initParams);
      return impl;
    case 'weather':
      final impl = ServerWeatherMcp();
      await impl.initialize(initParams);
      return impl;
    case 'web_search':
      final impl = ServerWebSearchMcp();
      await impl.initialize(initParams);
      return impl;
    case 'imap':
      final impl = ServerImapMcp();
      await impl.initialize(initParams);
      return impl;
    case 'chart':
      return ServerChartMcp();
    case 'mermaid':
      return ServerMermaidMcp();
    case 'file':
      return ServerFileMcp();
    case 'excel':
      return ServerExcelMcp();
    case 'home_assistant':
      final haImpl = ServerHomeAssistantMcp();
      await haImpl.initialize(initParams);
      return haImpl;
    case 'gmail':
      final gmailImpl = ServerGmailMcp();
      await gmailImpl.initialize(initParams);
      return gmailImpl;
    case 'google_calendar':
      final calImpl = ServerGoogleCalendarMcp();
      await calImpl.initialize(initParams);
      return calImpl;
    case 'google_drive':
      final driveImpl = ServerGoogleDriveMcp();
      await driveImpl.initialize(initParams);
      return driveImpl;
    case 'document':
      final docImpl = ServerDocumentMcp();
      await docImpl.initialize(initParams);
      return docImpl;
    case 'pdf':
      return ServerPdfStub();
    case 'js_bridge':
      final jsImpl = ServerJsBridgeMcp();
      await jsImpl.initialize(initParams);
      return jsImpl;
    case 'ps_bridge':
      return ServerPsBridgeStub();
    case 'py_bridge':
      final pyImpl = ServerPyBridgeMcp();
      await pyImpl.initialize(initParams);
      return pyImpl;
    case 'website_search':
      final wsImpl = ServerWebsiteSearchMcp();
      await wsImpl.initialize(initParams);
      return wsImpl;
    case 'toolbox':
      return ServerToolboxMcp();
    default:
      return null;
  }
}

// ═══════════════════════════════════════════════════════════════
// SSH
// ═══════════════════════════════════════════════════════════════

class ServerSshMcp extends ServerInternalMcp {
  String _host = '';
  int _port = 22;
  String _username = '';
  String _password = '';
  String _privateKey = '';

  SSHClient? _client;
  SftpClient? _sftpClient;

  static const _tools = <MCPTool>[
    MCPTool(
      name: 'list_directory',
      description: 'List files and subdirectories at a remote path.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'Remote directory path (e.g. /home/user or ~).',
          },
        },
        'required': ['path'],
      },
    ),
    MCPTool(
      name: 'read_file',
      description: 'Read the text content of a remote file.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'Full remote path of the file to read.',
          },
          'maxBytes': {
            'type': 'integer',
            'description':
                'Maximum bytes to read (default 65536). Use 0 for unlimited.',
          },
        },
        'required': ['path'],
      },
    ),
    MCPTool(
      name: 'download_file',
      description:
          'Download a remote file. Returns base-64 encoded content and MIME type.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'Full remote path of the file to download.',
          },
        },
        'required': ['path'],
      },
    ),
    MCPTool(
      name: 'upload_file',
      description: 'Upload a text file to the remote server.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'Full remote path where the file should be written.',
          },
          'content': {
            'type': 'string',
            'description': 'UTF-8 text content to write.',
          },
          'permissions': {
            'type': 'string',
            'description':
                'Optional octal permission string e.g. "755" or "644".',
          },
        },
        'required': ['path', 'content'],
      },
    ),
    MCPTool(
      name: 'execute_command',
      description:
          'Execute a shell command on the remote server. Returns stdout, stderr and exit code.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'command': {
            'type': 'string',
            'description': 'Shell command to execute.',
          },
          'timeoutSeconds': {
            'type': 'integer',
            'description': 'Timeout in seconds (default 30, max 300).',
          },
        },
        'required': ['command'],
      },
    ),
    MCPTool(
      name: 'make_directory',
      description:
          'Create a directory (and all missing parent directories) on the remote server.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'Full remote path of the directory to create.',
          },
        },
        'required': ['path'],
      },
    ),
    MCPTool(
      name: 'remove_directory',
      description:
          'Remove an EMPTY directory on the remote server. Fails if the directory is not empty.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'Full remote path of the empty directory to remove.',
          },
        },
        'required': ['path'],
      },
    ),
    MCPTool(
      name: 'list_scripts',
      description:
          'List all saved shell scripts in the server script library (scripts.json in the data directory).',
      inputSchema: {'type': 'object', 'properties': {}, 'required': []},
    ),
    MCPTool(
      name: 'run_script',
      description:
          'Run a saved shell script from the server script library on the configured SSH host.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'scriptName': {
            'type': 'string',
            'description': 'Name of the saved script to run.',
          },
          'scriptId': {
            'type': 'string',
            'description': 'Optional script id (overrides scriptName).',
          },
          'args': {
            'type': 'string',
            'description': 'Optional additional arguments to append.',
          },
          'timeoutSeconds': {
            'type': 'integer',
            'description': 'Timeout in seconds (default 180, max 600).',
          },
        },
        'required': ['scriptName'],
      },
    ),
  ];

  @override
  List<MCPTool> get tools => _tools;

  Future<void> initialize(Map<String, dynamic> initParams) async {
    final ds = ServerDataSourcesService.instance;
    final paramHost = (initParams['host'] as String? ?? '').trim();
    final paramPort = (initParams['port'] as int?) ?? 0;
    final paramUser = (initParams['username'] as String? ?? '').trim();
    final paramPass = (initParams['password'] as String? ?? '').trim();
    final paramKey = (initParams['privateKey'] as String? ?? '').trim();

    _host = paramHost.isNotEmpty ? paramHost : ds.sshHost;
    _port = (paramPort > 0) ? paramPort : ds.sshPort;
    _username = paramUser.isNotEmpty ? paramUser : ds.sshUsername;
    _password = paramPass.isNotEmpty ? paramPass : ds.sshPassword;
    _privateKey = paramKey.isNotEmpty ? paramKey : ds.sshPrivateKey;

    log.info(
      '[SSH MCP] Initialized – host=$_host, port=$_port, user=$_username',
    );
  }

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> args,
  ) async {
    switch (name) {
      case 'list_directory':
        return _listDirectory(args['path'] as String? ?? '.');
      case 'read_file':
        return _readFile(
          args['path'] as String? ?? '',
          maxBytes: (args['maxBytes'] as int?) ?? 65536,
        );
      case 'download_file':
        return _downloadFile(args['path'] as String? ?? '');
      case 'upload_file':
        return _uploadFile(
          path: args['path'] as String? ?? '',
          content: args['content'] as String? ?? '',
          permissions: args['permissions'] as String?,
        );
      case 'make_directory':
        return _makeDirectory(args['path'] as String? ?? '');
      case 'remove_directory':
        return _removeDirectory(args['path'] as String? ?? '');
      case 'execute_command':
        final timeout = ((args['timeoutSeconds'] as int?) ?? 30).clamp(1, 300);
        return _executeCommand(
          args['command'] as String? ?? '',
          timeoutSeconds: timeout,
        );
      case 'list_scripts':
        return _listScripts();
      case 'run_script':
        final scriptTimeout = ((args['timeoutSeconds'] as int?) ?? 180).clamp(
          1,
          600,
        );
        return _runScript(
          scriptId: args['scriptId'] as String?,
          scriptName: args['scriptName'] as String? ?? '',
          args: args['args'] as String? ?? '',
          timeoutSeconds: scriptTimeout,
        );
      default:
        return {'error': 'Unknown SSH tool: $name'};
    }
  }

  Future<SSHClient> _connect() async {
    if (_client != null) return _client!;
    if (_host.isEmpty) {
      throw StateError(
        'SSH host is not configured. Set global SSH settings in Data Sources or provide task-level SSH params.',
      );
    }
    _client = SSHClient(
      await SSHSocket.connect(
        _host,
        _port,
      ).timeout(const Duration(seconds: 15)),
      username: _username,
      identities: _privateKey.isNotEmpty
          ? SSHKeyPair.fromPem(_privateKey)
          : null,
      onPasswordRequest: () => _password,
    );
    await _client!.authenticated.timeout(const Duration(seconds: 15));
    log.info('[SSH MCP] Connected to $_host:$_port as $_username');
    return _client!;
  }

  Future<SftpClient> _sftp() async {
    if (_sftpClient != null) return _sftpClient!;
    final client = await _connect();
    _sftpClient = await client.sftp();
    return _sftpClient!;
  }

  Future<Map<String, dynamic>> _listDirectory(String path) async {
    try {
      final sftp = await _sftp();
      final entries = await sftp.listdir(path);
      final items = entries
          .where((e) => e.filename != '.' && e.filename != '..')
          .map((e) {
            final attr = e.attr;
            final fileType = attr.mode?.type;
            return {
              'name': e.filename,
              'isDirectory': fileType == SftpFileType.directory,
              'isFile': fileType == SftpFileType.regularFile,
              'isSymlink': fileType == SftpFileType.symbolicLink,
              'size': attr.size ?? 0,
              'permissions': _formatPermissions(attr.mode?.value ?? 0),
              'modified': attr.modifyTime != null
                  ? DateTime.fromMillisecondsSinceEpoch(
                      attr.modifyTime! * 1000,
                    ).toIso8601String()
                  : null,
            };
          })
          .toList();
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

  Future<Map<String, dynamic>> _readFile(
    String path, {
    int maxBytes = 65536,
  }) async {
    try {
      final sftp = await _sftp();
      final file = await sftp.open(path, mode: SftpFileOpenMode.read);
      final bytes = maxBytes > 0
          ? await file.readBytes(length: maxBytes)
          : await file.readBytes();
      await file.close();
      return {
        'path': path,
        'content': utf8.decode(bytes, allowMalformed: true),
        'bytes': bytes.length,
        'truncated': maxBytes > 0 && bytes.length >= maxBytes,
      };
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
      return {
        'path': path,
        'bytes': bytes.length,
        'fileName': fileName,
        'mimeType': _mimeTypeFromExtension(fileName),
        'encoding': 'base64',
        'content': base64Encode(bytes),
      };
    } catch (e) {
      return {'error': 'download_file failed: $e'};
    }
  }

  Future<Map<String, dynamic>> _uploadFile({
    required String path,
    required String content,
    String? permissions,
  }) async {
    try {
      final sftp = await _sftp();
      final bytes = Uint8List.fromList(utf8.encode(content));
      final file = await sftp.open(
        path,
        mode:
            SftpFileOpenMode.create |
            SftpFileOpenMode.write |
            SftpFileOpenMode.truncate,
      );
      await file.writeBytes(bytes);
      await file.close();
      if (permissions != null && permissions.isNotEmpty) {
        final client = await _connect();
        final session = await client.execute(
          'chmod $permissions ${_shellEscape(path)}',
        );
        await session.stdout.drain<void>();
        await session.stderr.drain<void>();
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
        return {
          'error': (result['stderr'] as String?)?.isNotEmpty == true
              ? result['stderr']
              : 'Directory not empty or does not exist',
        };
      }
      return {'success': true, 'path': path};
    } catch (e) {
      return {'error': 'remove_directory failed: $e'};
    }
  }

  Future<Map<String, dynamic>> _executeCommand(
    String command, {
    int timeoutSeconds = 30,
  }) async {
    if (command.trim().isEmpty) return {'error': 'command is empty'};
    try {
      final client = await _connect();
      final session = await client.execute(command);
      final stdoutBytes = BytesBuilder();
      final stderrBytes = BytesBuilder();
      await Future.wait([
        session.stdout.forEach(stdoutBytes.add),
        session.stderr.forEach(stderrBytes.add),
      ]).timeout(
        Duration(seconds: timeoutSeconds),
        onTimeout: () => throw TimeoutException(
          'Command timed out after ${timeoutSeconds}s',
        ),
      );

      final exitCode = session.exitCode ?? -1;
      final stdoutText = utf8.decode(
        stdoutBytes.takeBytes(),
        allowMalformed: true,
      );
      final stderrText = utf8.decode(
        stderrBytes.takeBytes(),
        allowMalformed: true,
      );
      final success = _isSuccessfulExit(exitCode, stdoutText, stderrText);

      return {
        'command': command,
        'exitCode': exitCode,
        'stdout': stdoutText,
        'stderr': stderrText,
        'success': success,
      };
    } catch (e) {
      return {'error': 'execute_command failed: $e', 'command': command};
    }
  }

  String _formatPermissions(int mode) {
    final perms = mode & 0x1FF;
    final chars = ['r', 'w', 'x'];
    final result = StringBuffer();
    for (var i = 8; i >= 0; i--) {
      result.write((perms >> i) & 1 == 1 ? chars[2 - (i % 3)] : '-');
    }
    return result.toString();
  }

  String _mimeTypeFromExtension(String fileName) {
    final ext = fileName.contains('.')
        ? fileName.split('.').last.toLowerCase()
        : '';
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
    };
    return map[ext] ?? 'application/octet-stream';
  }

  static String _shellEscape(String path) =>
      "'${path.replaceAll("'", "'\\''")}'";

  bool _isSuccessfulExit(int exitCode, String stdoutText, String stderrText) {
    if (exitCode == 0) return true;
    // dartssh2 can occasionally report -1 even when command output is valid.
    // Treat that as success when stderr is empty and stdout has useful content.
    if (exitCode == -1 &&
        stderrText.trim().isEmpty &&
        stdoutText.trim().isNotEmpty) {
      return true;
    }
    return false;
  }

  // ── Script library (reads scripts.json from TEALKIT_DATA_DIR) ────────────

  static List<Map<String, dynamic>>? _cachedScripts;

  static void clearScriptCache() {
    _cachedScripts = null;
  }

  static List<Map<String, dynamic>> _loadScriptsFromDisk() {
    if (_cachedScripts != null) return _cachedScripts!;
    final dataDir =
        Platform.environment['TEALKIT_DATA_DIR'] ??
        '${Platform.environment['HOME'] ?? '/root'}/.tealkit-server';
    final file = File('$dataDir/scripts.json');
    if (!file.existsSync()) {
      _cachedScripts = [];
      return _cachedScripts!;
    }
    try {
      _cachedScripts = (jsonDecode(file.readAsStringSync()) as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .toList();
    } catch (_) {
      _cachedScripts = [];
    }
    return _cachedScripts!;
  }

  Map<String, dynamic> _listScripts() {
    final scripts = _loadScriptsFromDisk();
    return {
      'count': scripts.length,
      'scripts': scripts
          .map(
            (s) => {
              'id': s['id'],
              'name': s['name'],
              'description': s['description'],
              'updatedAt': s['updatedAt'],
              'lines':
                  '\n'.allMatches((s['content'] as String? ?? '')).length + 1,
            },
          )
          .toList(),
      'note': scripts.isEmpty
          ? 'No scripts found. Export scripts from the TealKit app to \$TEALKIT_DATA_DIR/scripts.json'
          : null,
    };
  }

  Future<Map<String, dynamic>> _runScript({
    String? scriptId,
    required String scriptName,
    String args = '',
    int timeoutSeconds = 60,
  }) async {
    final scripts = _loadScriptsFromDisk();
    Map<String, dynamic>? script;
    if (scriptId != null && scriptId.trim().isNotEmpty) {
      script = scripts.where((s) => s['id'] == scriptId.trim()).firstOrNull;
    }
    script ??= scripts
        .where((s) => (s['name'] as String?) == scriptName)
        .firstOrNull;
    script ??= scripts
        .where(
          (s) =>
              (s['name'] as String?)?.toLowerCase() == scriptName.toLowerCase(),
        )
        .firstOrNull;
    if (script == null) {
      return {
        'error': 'Script not found: ${scriptId ?? scriptName}',
        'hint': 'Use list_scripts to see available scripts.',
      };
    }

    final content = script['content'] as String? ?? '';
    try {
      final client = await _connect();
      final tmpPath =
          '/tmp/.tealkit_script_${(script['id'] as String? ?? 'x').replaceAll('-', '')}.sh';
      final sftp = await client.sftp();
      final scriptBytes = Uint8List.fromList(utf8.encode(content));
      final remoteFile = await sftp.open(
        tmpPath,
        mode:
            SftpFileOpenMode.create |
            SftpFileOpenMode.write |
            SftpFileOpenMode.truncate,
      );
      await remoteFile.writeBytes(scriptBytes);
      await remoteFile.close();

      final cmd =
          'chmod +x ${_shellEscape(tmpPath)} && ${_shellEscape(tmpPath)}${args.isNotEmpty ? ' $args' : ''} ; rm -f ${_shellEscape(tmpPath)}';
      final session = await client.execute(cmd);
      final outBytes = BytesBuilder();
      final errBytes = BytesBuilder();
      await Future.wait([
        session.stdout.forEach(outBytes.add),
        session.stderr.forEach(errBytes.add),
      ]).timeout(
        Duration(seconds: timeoutSeconds),
        onTimeout: () =>
            throw TimeoutException('Script timed out after ${timeoutSeconds}s'),
      );

      final exitCode = session.exitCode ?? -1;
      final stdoutText = utf8.decode(
        outBytes.takeBytes(),
        allowMalformed: true,
      );
      final stderrText = utf8.decode(
        errBytes.takeBytes(),
        allowMalformed: true,
      );
      final success = _isSuccessfulExit(exitCode, stdoutText, stderrText);

      return {
        'scriptId': script['id'],
        'scriptName': script['name'],
        'exitCode': exitCode,
        'stdout': stdoutText,
        'stderr': stderrText,
        'success': success,
      };
    } catch (e) {
      return {'error': 'run_script failed: $e', 'scriptName': scriptName};
    }
  }

  @override
  Future<void> dispose() async {
    _sftpClient?.close();
    _sftpClient = null;
    _client?.close();
    _client = null;
  }
}

// ═══════════════════════════════════════════════════════════════
// Weather (Open-Meteo — free, no API key)
// ═══════════════════════════════════════════════════════════════

class ServerWeatherMcp extends ServerInternalMcp {
  static const _baseUrl = 'https://api.open-meteo.com/v1';
  static const _geocodeUrl = 'https://geocoding-api.open-meteo.com/v1';

  double? _latitude;
  double? _longitude;
  String? _locationName;
  String _timezone = 'auto';

  static const _tools = <MCPTool>[
    MCPTool(
      name: 'get_current_weather',
      description:
          'Get current weather conditions including temperature, wind, humidity, and weather description.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'latitude': {
            'type': 'number',
            'description':
                'Latitude (optional, uses configured location if omitted)',
          },
          'longitude': {
            'type': 'number',
            'description':
                'Longitude (optional, uses configured location if omitted)',
          },
        },
        'required': <String>[],
      },
    ),
    MCPTool(
      name: 'get_hourly_forecast',
      description:
          'Get hourly weather forecast for the next 24-168 hours. '
          'Includes temperature, precipitation, wind speed, and weather code.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'hours': {
            'type': 'integer',
            'description':
                'Number of hours to forecast (default: 24, max: 168)',
            'default': 24,
          },
          'latitude': {'type': 'number', 'description': 'Latitude (optional)'},
          'longitude': {
            'type': 'number',
            'description': 'Longitude (optional)',
          },
        },
        'required': <String>[],
      },
    ),
    MCPTool(
      name: 'get_daily_forecast',
      description:
          'Get daily weather forecast for the next 1-16 days. '
          'Includes high/low temperatures, precipitation sum, sunrise/sunset.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'days': {
            'type': 'integer',
            'description': 'Number of days to forecast (default: 7, max: 16)',
            'default': 7,
          },
          'latitude': {'type': 'number', 'description': 'Latitude (optional)'},
          'longitude': {
            'type': 'number',
            'description': 'Longitude (optional)',
          },
        },
        'required': <String>[],
      },
    ),
    MCPTool(
      name: 'geocode_weather_city',
      description:
          'Look up the coordinates (latitude, longitude) for a city name.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'city': {
            'type': 'string',
            'description': 'City name to look up (e.g. "Vienna", "New York")',
          },
        },
        'required': ['city'],
      },
    ),
  ];

  @override
  List<MCPTool> get tools => _tools;

  Future<void> initialize(Map<String, dynamic> initParams) async {
    final location = (initParams['location'] as String? ?? 'current').trim();
    _timezone = (initParams['timezone'] as String? ?? 'auto').trim();
    log.info(
      '[Weather MCP] Initializing with location="$location", timezone="$_timezone"',
    );

    if (location == 'current' || location.isEmpty) {
      final ds = ServerDataSourcesService.instance;
      if (ds.hasLocation) {
        _latitude = ds.locationLatitude;
        _longitude = ds.locationLongitude;
        _locationName = 'your location';
        log.info(
          '[Weather MCP] Using stored location: $_latitude, $_longitude',
        );
      } else {
        log.warning(
          '[Weather MCP] No stored location. Provide coordinates or city in initParams.',
        );
      }
      return;
    }

    final coordMatch = RegExp(
      r'^(-?\d+\.?\d*)\s*,\s*(-?\d+\.?\d*)$',
    ).firstMatch(location);
    if (coordMatch != null) {
      _latitude = double.parse(coordMatch.group(1)!);
      _longitude = double.parse(coordMatch.group(2)!);
      _locationName = 'Lat $_latitude, Lng $_longitude';
      return;
    }

    await _geocodeCity(location);
  }

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> args,
  ) async {
    switch (name) {
      case 'get_current_weather':
        return _getCurrentWeather(args);
      case 'get_hourly_forecast':
        return _getHourlyForecast(args);
      case 'get_daily_forecast':
        return _getDailyForecast(args);
      case 'geocode_weather_city':
      case 'geocode_city':
        return _geocodeCityTool(args);
      default:
        return {'error': 'Unknown weather tool: $name'};
    }
  }

  double _getLat(Map<String, dynamic> args) {
    if (args['latitude'] != null) return (args['latitude'] as num).toDouble();
    if (_latitude != null) return _latitude!;
    return ServerDataSourcesService.instance.locationLatitude ?? 0;
  }

  double _getLng(Map<String, dynamic> args) {
    if (args['longitude'] != null) return (args['longitude'] as num).toDouble();
    if (_longitude != null) return _longitude!;
    return ServerDataSourcesService.instance.locationLongitude ?? 0;
  }

  Future<void> _geocodeCity(String cityName) async {
    final url =
        '$_geocodeUrl/search?name=${Uri.encodeComponent(cityName)}&count=1&language=en&format=json';
    try {
      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final results = body['results'] as List<dynamic>?;
        if (results != null && results.isNotEmpty) {
          final first = results[0] as Map<String, dynamic>;
          _latitude = (first['latitude'] as num).toDouble();
          _longitude = (first['longitude'] as num).toDouble();
          _locationName = '${first['name']}, ${first['country'] ?? ''}';
          log.info('[Weather MCP] Geocoded "$cityName" → $_locationName');
        } else {
          log.warning('[Weather MCP] No geocoding results for "$cityName"');
        }
      }
    } catch (e) {
      log.warning('[Weather MCP] Geocoding error: $e');
    }
  }

  Future<Map<String, dynamic>> _getCurrentWeather(
    Map<String, dynamic> args,
  ) async {
    final lat = _getLat(args);
    final lng = _getLng(args);
    if (lat == 0 && lng == 0) return {'error': 'No location configured.'};
    final url =
        '$_baseUrl/forecast?latitude=$lat&longitude=$lng'
        '&current=temperature_2m,relative_humidity_2m,apparent_temperature,'
        'is_day,precipitation,rain,showers,snowfall,weather_code,'
        'cloud_cover,pressure_msl,surface_pressure,wind_speed_10m,'
        'wind_direction_10m,wind_gusts_10m&timezone=$_timezone';
    return _fetchWeatherData(url, 'current_weather');
  }

  Future<Map<String, dynamic>> _getHourlyForecast(
    Map<String, dynamic> args,
  ) async {
    final lat = _getLat(args);
    final lng = _getLng(args);
    final hours = ((args['hours'] as int?) ?? 24).clamp(1, 168);
    if (lat == 0 && lng == 0) return {'error': 'No location configured.'};
    final url =
        '$_baseUrl/forecast?latitude=$lat&longitude=$lng'
        '&hourly=temperature_2m,relative_humidity_2m,apparent_temperature,'
        'precipitation_probability,precipitation,rain,showers,snowfall,'
        'weather_code,cloud_cover,wind_speed_10m,wind_direction_10m,wind_gusts_10m'
        '&forecast_hours=$hours&timezone=$_timezone';
    return _fetchWeatherData(url, 'hourly_forecast');
  }

  Future<Map<String, dynamic>> _getDailyForecast(
    Map<String, dynamic> args,
  ) async {
    final lat = _getLat(args);
    final lng = _getLng(args);
    final days = ((args['days'] as int?) ?? 7).clamp(1, 16);
    if (lat == 0 && lng == 0) return {'error': 'No location configured.'};
    final url =
        '$_baseUrl/forecast?latitude=$lat&longitude=$lng'
        '&daily=weather_code,temperature_2m_max,temperature_2m_min,'
        'apparent_temperature_max,apparent_temperature_min,sunrise,sunset,'
        'uv_index_max,precipitation_sum,rain_sum,showers_sum,snowfall_sum,'
        'precipitation_hours,precipitation_probability_max,'
        'wind_speed_10m_max,wind_gusts_10m_max,wind_direction_10m_dominant'
        '&forecast_days=$days&timezone=$_timezone';
    return _fetchWeatherData(url, 'daily_forecast');
  }

  Future<Map<String, dynamic>> _geocodeCityTool(
    Map<String, dynamic> args,
  ) async {
    final city = args['city'] as String?;
    if (city == null || city.isEmpty) return {'error': 'City name is required'};
    final url =
        '$_geocodeUrl/search?name=${Uri.encodeComponent(city)}&count=5&language=en&format=json';
    try {
      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final results = (body['results'] as List<dynamic>?) ?? [];
        return {
          'query': city,
          'results': results.map((r) {
            final m = r as Map<String, dynamic>;
            return {
              'name': m['name'],
              'country': m['country'],
              'admin1': m['admin1'],
              'latitude': m['latitude'],
              'longitude': m['longitude'],
              'timezone': m['timezone'],
              'population': m['population'],
            };
          }).toList(),
        };
      }
      return {'error': 'Geocoding API returned status ${response.statusCode}'};
    } catch (e) {
      return {'error': 'Geocoding failed: $e'};
    }
  }

  Future<Map<String, dynamic>> _fetchWeatherData(
    String url,
    String label,
  ) async {
    try {
      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        _addWeatherDescriptions(data);
        data['_location'] =
            _locationName ??
            'Lat ${data['latitude']}, Lng ${data['longitude']}';
        return data;
      }
      return {'error': 'API returned status ${response.statusCode}'};
    } catch (e) {
      return {'error': '$label failed: $e'};
    }
  }

  void _addWeatherDescriptions(Map<String, dynamic> data) {
    if (data['current'] is Map) {
      final current = data['current'] as Map<String, dynamic>;
      if (current['weather_code'] != null) {
        current['weather_description'] = _wmoCodeToDescription(
          current['weather_code'] as int,
        );
      }
    }
    if (data['hourly'] is Map) {
      final hourly = data['hourly'] as Map<String, dynamic>;
      if (hourly['weather_code'] is List) {
        hourly['weather_description'] = (hourly['weather_code'] as List)
            .map((code) => _wmoCodeToDescription(code as int))
            .toList();
      }
    }
    if (data['daily'] is Map) {
      final daily = data['daily'] as Map<String, dynamic>;
      if (daily['weather_code'] is List) {
        daily['weather_description'] = (daily['weather_code'] as List)
            .map((code) => _wmoCodeToDescription(code as int))
            .toList();
      }
    }
  }

  static String _wmoCodeToDescription(int code) => switch (code) {
    0 => 'Clear sky',
    1 => 'Mainly clear',
    2 => 'Partly cloudy',
    3 => 'Overcast',
    45 => 'Fog',
    48 => 'Depositing rime fog',
    51 => 'Light drizzle',
    53 => 'Moderate drizzle',
    55 => 'Dense drizzle',
    56 => 'Light freezing drizzle',
    57 => 'Dense freezing drizzle',
    61 => 'Slight rain',
    63 => 'Moderate rain',
    65 => 'Heavy rain',
    66 => 'Light freezing rain',
    67 => 'Heavy freezing rain',
    71 => 'Slight snowfall',
    73 => 'Moderate snowfall',
    75 => 'Heavy snowfall',
    77 => 'Snow grains',
    80 => 'Slight rain showers',
    81 => 'Moderate rain showers',
    82 => 'Violent rain showers',
    85 => 'Slight snow showers',
    86 => 'Heavy snow showers',
    95 => 'Thunderstorm',
    96 => 'Thunderstorm with slight hail',
    99 => 'Thunderstorm with heavy hail',
    _ => 'Unknown ($code)',
  };
}

// ═══════════════════════════════════════════════════════════════
// Web Search
// ═══════════════════════════════════════════════════════════════

class ServerWebSearchMcp extends ServerInternalMcp {
  String _providerPreference = 'auto';
  int _defaultMaxResults = 5;

  static const _tools = <MCPTool>[
    MCPTool(
      name: 'web_search',
      description:
          'Search the public web for any information: news, prices, flights, travel, products, etc. '
          'Uses SerpApi (Google Search) if configured, then Serper.dev, otherwise DuckDuckGo.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'description': 'Search query string.'},
          'maxResults': {
            'type': 'integer',
            'description': 'Maximum results (default from MCP config, max 20).',
          },
          'provider': {
            'type': 'string',
            'enum': ['auto', 'serpapi', 'serper', 'duckduckgo', 'custom'],
            'description': 'Optional per-call provider override.',
          },
        },
        'required': ['query'],
      },
    ),
  ];

  @override
  List<MCPTool> get tools => _tools;

  Future<void> initialize(Map<String, dynamic> initParams) async {
    _providerPreference = (initParams['provider'] as String? ?? 'auto')
        .trim()
        .toLowerCase();
    if (_providerPreference == 'google') _providerPreference = 'serper';
    if (!{
      'auto',
      'serpapi',
      'serper',
      'duckduckgo',
      'custom',
    }.contains(_providerPreference)) {
      _providerPreference = 'auto';
    }
    _defaultMaxResults = ((initParams['maxResults'] as int?) ?? 5).clamp(1, 20);
    log.info(
      '[Web Search MCP] Initialized provider=$_providerPreference, maxResults=$_defaultMaxResults',
    );
  }

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> args,
  ) async {
    if (name == 'web_search') return _webSearch(args);
    return {'error': 'Unknown web search tool: $name'};
  }

  Future<Map<String, dynamic>> _webSearch(Map<String, dynamic> args) async {
    final query = (args['query'] as String?)?.trim();
    if (query == null || query.isEmpty) {
      return {'error': 'Parameter "query" is required.'};
    }
    final maxResults = ((args['maxResults'] as int?) ?? _defaultMaxResults)
        .clamp(1, 20);
    final providerOverride = (args['provider'] as String?)
        ?.trim()
        .toLowerCase();
    final effectiveOverride = providerOverride == 'google'
        ? 'serper'
        : providerOverride;
    final provider = (effectiveOverride != null && effectiveOverride.isNotEmpty)
        ? effectiveOverride
        : _providerPreference;

    final ds = ServerDataSourcesService.instance;
    final serpapiConfigured =
        ds.webSearchProvider == WebSearchProvider.serpapi &&
        ds.isWebSearchConfigured;
    final serperConfigured =
        ds.webSearchProvider == WebSearchProvider.serper &&
        ds.isWebSearchConfigured;
    final customConfigured =
        ds.webSearchProvider == WebSearchProvider.custom &&
        ds.isWebSearchConfigured;

    if (provider == 'custom' || (provider == 'auto' && customConfigured)) {
      final result = await _searchCustomProvider(query, maxResults, ds);
      if (!result.containsKey('error')) return result;
      if (provider == 'custom') return result;
      log.warning(
        '[Web Search MCP] Custom provider failed, falling back: ${result['error']}',
      );
    }

    if (provider == 'serpapi' || (provider == 'auto' && serpapiConfigured)) {
      final result = await _searchSerpApi(query, maxResults, ds);
      if (!result.containsKey('error')) return result;
      if (provider == 'serpapi') return result;
      log.warning(
        '[Web Search MCP] SerpApi failed, falling back: ${result['error']}',
      );
    }

    if (provider == 'serper' || (provider == 'auto' && serperConfigured)) {
      final result = await _searchSerper(query, maxResults, ds);
      if (!result.containsKey('error')) return result;
      if (provider == 'serper') return result;
      log.warning(
        '[Web Search MCP] Serper failed, falling back to DDG: ${result['error']}',
      );
    }

    return _searchDuckDuckGo(query, maxResults);
  }

  Future<Map<String, dynamic>> _searchSerpApi(
    String query,
    int maxResults,
    ServerDataSourcesService ds,
  ) async {
    final apiKey = ds.webSearchApiKey.trim();
    if (apiKey.isEmpty) {
      return {'error': 'SerpApi is not configured (missing API key).'};
    }
    final uri = Uri.parse('https://serpapi.com/search').replace(
      queryParameters: {
        'engine': 'google',
        'q': query,
        'num': '$maxResults',
        'api_key': apiKey,
      },
    );
    try {
      final response = await http
          .get(uri, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 20));
      final data =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      if (response.statusCode >= 300) {
        return {
          'error':
              'SerpApi error ${response.statusCode}: ${data['error'] ?? response.reasonPhrase}',
        };
      }
      final items = (data['organic_results'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .take(maxResults)
          .map(
            (item) => {
              'title': item['title']?.toString() ?? '',
              'url': item['link']?.toString() ?? '',
              'snippet': item['snippet']?.toString() ?? '',
            },
          )
          .toList();
      return {
        'providerUsed': 'serpapi',
        'query': query,
        'returned': items.length,
        'results': items,
      };
    } catch (e) {
      return {'error': 'SerpApi search failed: $e'};
    }
  }

  Future<Map<String, dynamic>> _searchSerper(
    String query,
    int maxResults,
    ServerDataSourcesService ds,
  ) async {
    final apiKey = ds.webSearchApiKey.trim();
    if (apiKey.isEmpty) {
      return {'error': 'Serper.dev is not configured (missing API key).'};
    }
    try {
      final response = await http
          .post(
            Uri.parse('https://google.serper.dev/search'),
            headers: {
              'Accept': 'application/json',
              'Content-Type': 'application/json',
              'X-API-KEY': apiKey,
            },
            body: jsonEncode({'q': query, 'num': maxResults}),
          )
          .timeout(const Duration(seconds: 20));
      final data =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      if (response.statusCode >= 300) {
        return {
          'error':
              'Serper error ${response.statusCode}: ${data['message'] ?? response.reasonPhrase}',
        };
      }
      final items = (data['organic'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(
            (item) => {
              'title': item['title']?.toString() ?? '',
              'url': item['link']?.toString() ?? '',
              'snippet': item['snippet']?.toString() ?? '',
            },
          )
          .toList();
      return {
        'providerUsed': 'serper',
        'query': query,
        'returned': items.length,
        'results': items,
      };
    } catch (e) {
      return {'error': 'Serper search failed: $e'};
    }
  }

  Future<Map<String, dynamic>> _searchCustomProvider(
    String query,
    int maxResults,
    ServerDataSourcesService ds,
  ) async {
    final endpointRaw = ds.webSearchCustomEndpoint.trim();
    if (endpointRaw.isEmpty) {
      return {'error': 'Custom provider endpoint is not configured.'};
    }
    late final Uri endpoint;
    try {
      endpoint = Uri.parse(endpointRaw);
    } catch (_) {
      return {'error': 'Custom provider endpoint is invalid.'};
    }
    if (!endpoint.hasScheme ||
        (endpoint.scheme != 'http' && endpoint.scheme != 'https')) {
      return {'error': 'Custom provider endpoint must use http or https.'};
    }
    final apiKey = ds.webSearchApiKey.trim();
    final requestUri = endpoint.replace(
      queryParameters: {
        ...endpoint.queryParameters,
        'q': query,
        'maxResults': '$maxResults',
      },
    );
    try {
      final response = await http
          .get(
            requestUri,
            headers: {
              'Accept': 'application/json',
              if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
              if (apiKey.isNotEmpty) 'X-API-Key': apiKey,
            },
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode >= 300) {
        return {
          'error':
              'Custom provider error ${response.statusCode}: ${response.reasonPhrase}',
        };
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      List<dynamic> rows;
      if (decoded is List) {
        rows = decoded;
      } else if (decoded is Map<String, dynamic>) {
        rows =
            (decoded['results'] as List?) ??
            (decoded['items'] as List?) ??
            (decoded['data'] as List?) ??
            const <dynamic>[];
      } else {
        rows = const <dynamic>[];
      }
      final results = rows
          .whereType<Map>()
          .map((item) {
            final m = Map<String, dynamic>.from(item);
            return {
              'title': (m['title'] ?? m['name'] ?? '').toString(),
              'url': (m['url'] ?? m['link'] ?? '').toString(),
              'snippet': (m['snippet'] ?? m['description'] ?? m['text'] ?? '')
                  .toString(),
            };
          })
          .where(
            (row) =>
                (row['title']?.isNotEmpty ?? false) ||
                (row['url']?.isNotEmpty ?? false),
          )
          .take(maxResults)
          .toList();
      return {
        'providerUsed': ds.webSearchCustomProviderName.isNotEmpty
            ? ds.webSearchCustomProviderName
            : 'custom',
        'query': query,
        'returned': results.length,
        'results': results,
      };
    } catch (e) {
      return {'error': 'Custom provider search failed: $e'};
    }
  }

  Future<Map<String, dynamic>> _searchDuckDuckGo(
    String query,
    int maxResults,
  ) async {
    final uri = Uri.parse('https://api.duckduckgo.com/').replace(
      queryParameters: {
        'q': query,
        'format': 'json',
        'no_html': '1',
        'no_redirect': '1',
      },
    );
    try {
      final response = await http
          .get(uri, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 15));
      if (response.statusCode >= 300) {
        return {
          'error':
              'DuckDuckGo search error ${response.statusCode}: ${response.reasonPhrase}',
        };
      }
      final data =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final results = <Map<String, dynamic>>[];

      final heading = (data['Heading'] ?? '').toString();
      final abstract = (data['AbstractText'] ?? '').toString();
      final abstractUrl = (data['AbstractURL'] ?? '').toString();
      if (heading.isNotEmpty || abstract.isNotEmpty) {
        results.add({
          'title': heading,
          'url': abstractUrl,
          'snippet': abstract,
        });
      }

      for (final topic
          in (data['RelatedTopics'] as List<dynamic>? ?? const [])) {
        if (results.length >= maxResults) break;
        if (topic is! Map<String, dynamic>) continue;
        if (topic.containsKey('Topics')) {
          for (final nested
              in (topic['Topics'] as List<dynamic>? ?? const [])
                  .whereType<Map<String, dynamic>>()) {
            if (results.length >= maxResults) break;
            final text = (nested['Text'] ?? '').toString();
            final url = (nested['FirstURL'] ?? '').toString();
            if (text.isNotEmpty || url.isNotEmpty) {
              results.add({
                'title': text.split('-').first.trim(),
                'url': url,
                'snippet': text,
              });
            }
          }
        } else {
          final text = (topic['Text'] ?? '').toString();
          final url = (topic['FirstURL'] ?? '').toString();
          if (text.isNotEmpty || url.isNotEmpty) {
            results.add({
              'title': text.split('-').first.trim(),
              'url': url,
              'snippet': text,
            });
          }
        }
      }

      return {
        'providerUsed': 'duckduckgo',
        'query': query,
        'returned': results.take(maxResults).length,
        'results': results.take(maxResults).toList(),
      };
    } catch (e) {
      log.warning('[Web Search MCP] DuckDuckGo failed: $e');
      return {'error': 'DuckDuckGo search failed: $e'};
    }
  }
}

// ═══════════════════════════════════════════════════════════════
// IMAP
// ═══════════════════════════════════════════════════════════════

/// Server-side IMAP handler.  Uses [enough_mail] (pure Dart — no Flutter).
class ServerImapMcp extends ServerInternalMcp {
  static const _tools = <MCPTool>[
    MCPTool(
      name: 'list_folders',
      description: 'List all available IMAP folders / mailboxes on the server.',
      inputSchema: {'type': 'object', 'properties': {}, 'required': []},
    ),
    MCPTool(
      name: 'search_emails',
      description:
          'Search emails in an IMAP mailbox. '
          'Returns uid, from, to, subject, date and seen-status. '
          'Pass uid to read_email for the full body.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'folder': {
            'type': 'string',
            'description': 'Mailbox folder (default: INBOX).',
            'default': 'INBOX',
          },
          'from': {
            'type': 'string',
            'description': 'Filter by sender (partial match).',
          },
          'to': {
            'type': 'string',
            'description': 'Filter by recipient (partial match).',
          },
          'subject': {
            'type': 'string',
            'description': 'Filter by subject keyword.',
          },
          'body': {
            'type': 'string',
            'description': 'Full-text search in message body.',
          },
          'since': {
            'type': 'string',
            'description':
                'Return emails on or after this date. Format: YYYY-MM-DD.',
          },
          'before': {
            'type': 'string',
            'description':
                'Return emails before this date. Format: YYYY-MM-DD.',
          },
          'unseen': {
            'type': 'boolean',
            'description': 'If true, return only unread emails.',
          },
          'maxResults': {
            'type': 'integer',
            'description': 'Maximum results (default 20, max 50).',
            'default': 20,
          },
        },
        'required': [],
      },
    ),
    MCPTool(
      name: 'read_email',
      description:
          'Read the full content of a specific email by uid and folder.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'uid': {
            'type': 'integer',
            'description': 'UID of the email (from search_emails).',
          },
          'folder': {
            'type': 'string',
            'description': 'Mailbox folder (default: INBOX).',
            'default': 'INBOX',
          },
        },
        'required': ['uid'],
      },
    ),
  ];

  @override
  List<MCPTool> get tools => _tools;

  Future<void> initialize(Map<String, dynamic> initParams) async {
    log.info('[IMAP MCP] Initialized (server mode)');
  }

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> args,
  ) async {
    final ds = ServerDataSourcesService.instance;
    final host = ds.imapHost.trim();
    final port = ds.imapPort;
    final username = ds.imapUsername.trim();
    final password = ds.imapPassword.trim();
    final useSsl = ds.imapUseSsl;

    if (host.isEmpty || username.isEmpty || password.isEmpty) {
      return _error(
        'IMAP credentials not configured. '
        'Please set IMAP host, username and password in Settings → Data Sources.',
      );
    }

    switch (name) {
      case 'list_folders':
        return _listFolders(host, port, username, password, useSsl);
      case 'search_emails':
        return _searchEmails(host, port, username, password, useSsl, args);
      case 'read_email':
        return _readEmail(host, port, username, password, useSsl, args);
      default:
        return _error('Unknown IMAP tool: $name');
    }
  }

  // ── list_folders ─────────────────────────────────────────────

  Future<Map<String, dynamic>> _listFolders(
    String host,
    int port,
    String username,
    String password,
    bool useSsl,
  ) async {
    final client = ImapClient(isLogEnabled: false);
    try {
      await client.connectToServer(host, port, isSecure: useSsl);
      await client.login(username, password);
      final listResult = await client.listMailboxes();
      await client.logout();
      final folders = listResult.map((m) => m.path).toList();
      log.info('[IMAP MCP] list_folders → ${folders.length} folders');
      return _ok({'folders': folders});
    } catch (e, st) {
      log.error('[IMAP MCP] list_folders error: $e', e, st);
      await _safeLogout(client);
      return _error('IMAP error listing folders: $e');
    }
  }

  // ── search_emails ─────────────────────────────────────────────

  Future<Map<String, dynamic>> _searchEmails(
    String host,
    int port,
    String username,
    String password,
    bool useSsl,
    Map<String, dynamic> args,
  ) async {
    final folder = _argStr(args, 'folder', 'INBOX');
    final from = _argStr(args, 'from', '');
    final to = _argStr(args, 'to', '');
    final subject = _argStr(args, 'subject', '');
    final body = _argStr(args, 'body', '');
    final since = _argStr(args, 'since', '');
    final before = _argStr(args, 'before', '');
    final unseen = args['unseen'] as bool? ?? false;
    final maxResults = (args['maxResults'] as int? ?? 20).clamp(1, 50);

    final parts = <String>[];
    if (from.isNotEmpty) parts.add('FROM "${_toAscii(from)}"');
    if (to.isNotEmpty) parts.add('TO "${_toAscii(to)}"');
    if (subject.isNotEmpty) parts.add('SUBJECT "${_toAscii(subject)}"');
    if (body.isNotEmpty) parts.add('BODY "${_toAscii(body)}"');
    if (since.isNotEmpty) {
      final d = _parseYmd(since);
      if (d != null) parts.add('SINCE ${_imapDate(d)}');
    }
    if (before.isNotEmpty) {
      final d = _parseYmd(before);
      if (d != null) parts.add('BEFORE ${_imapDate(d)}');
    }
    if (unseen) parts.add('UNSEEN');
    final criteria = parts.isEmpty ? 'ALL' : parts.join(' ');

    log.info(
      '[IMAP MCP] search_emails folder=$folder criteria="$criteria" max=$maxResults',
    );

    final client = ImapClient(isLogEnabled: false);
    try {
      await client.connectToServer(host, port, isSecure: useSsl);
      await client.login(username, password);
      await client.selectMailboxByPath(folder);

      final searchResult = await client.uidSearchMessages(
        searchCriteria: criteria,
      );
      final allUids = searchResult.matchingSequence?.toList() ?? [];

      if (allUids.isEmpty) {
        await client.logout();
        return _ok({'messages': <dynamic>[], 'total': 0, 'folder': folder});
      }

      final sliced = allUids.length > maxResults
          ? allUids.sublist(allUids.length - maxResults)
          : allUids;
      final seq = MessageSequence.fromIds(sliced, isUid: true);
      final fetchResult = await client.uidFetchMessages(
        seq,
        '(UID ENVELOPE FLAGS)',
      );
      await client.logout();

      final messages = fetchResult.messages.reversed.map((msg) {
        return {
          'uid': msg.uid,
          'id': msg.uid.toString(),
          'folder': folder,
          'from': _fmtAddresses(msg.from),
          'to': _fmtAddresses(msg.to),
          'subject': msg.decodeSubject() ?? '',
          'date': msg.decodeDate()?.toIso8601String() ?? '',
          'seen': msg.isSeen,
        };
      }).toList();

      log.info(
        '[IMAP MCP] search_emails → ${messages.length} of ${allUids.length} results',
      );
      return _ok({
        'messages': messages,
        'total': allUids.length,
        'returned': messages.length,
        'folder': folder,
      });
    } catch (e, st) {
      log.error('[IMAP MCP] search_emails error: $e', e, st);
      await _safeLogout(client);
      return _error('IMAP search error: $e');
    }
  }

  // ── read_email ────────────────────────────────────────────────

  Future<Map<String, dynamic>> _readEmail(
    String host,
    int port,
    String username,
    String password,
    bool useSsl,
    Map<String, dynamic> args,
  ) async {
    final uid = args['uid'] as int?;
    if (uid == null) return _error('Parameter "uid" is required.');
    final requestedFolder = _argStr(args, 'folder', 'INBOX');

    log.info('[IMAP MCP] read_email uid=$uid folder=$requestedFolder');

    final foldersToTry = <String>{
      requestedFolder,
      '[Gmail]/All Mail',
      'All Mail',
      'INBOX',
    };

    final client = ImapClient(isLogEnabled: false);
    try {
      await client.connectToServer(host, port, isSecure: useSsl);
      await client.login(username, password);

      MimeMessage? msg;
      String foundFolder = requestedFolder;

      for (final folder in foldersToTry) {
        try {
          await client.selectMailboxByPath(folder);
          final fetchResult = await client.uidFetchMessages(
            MessageSequence.fromId(uid, isUid: true),
            '(UID ENVELOPE FLAGS BODY[])',
          );
          if (fetchResult.messages.isNotEmpty) {
            msg = fetchResult.messages.first;
            foundFolder = folder;
            break;
          }
        } catch (_) {
          // Folder may not exist on this server — try next.
        }
      }

      await client.logout();

      if (msg == null) {
        return _error('Email uid=$uid not found in folder "$requestedFolder".');
      }

      String body = msg.decodeTextPlainPart() ?? '';
      String htmlBody = msg.decodeTextHtmlPart() ?? '';
      if (body.isEmpty && htmlBody.isNotEmpty) {
        body = htmlBody
            .replaceAll(RegExp(r'<[^>]*>'), ' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
      }
      const maxBodyLen = 6000;
      if (body.length > maxBodyLen) {
        body = '${body.substring(0, maxBodyLen)}\n[truncated]';
      }
      if (htmlBody.length > maxBodyLen * 2) {
        htmlBody =
            '${htmlBody.substring(0, maxBodyLen * 2)}\n<!-- truncated -->';
      }

      final attachments = <String>[];
      _collectAttachments(msg, attachments);

      return _ok({
        'uid': msg.uid != 0 ? msg.uid : uid,
        'folder': foundFolder,
        'from': _fmtAddresses(msg.from),
        'to': _fmtAddresses(msg.to),
        'cc': _fmtAddresses(msg.cc),
        'subject': msg.decodeSubject() ?? '',
        'date': msg.decodeDate()?.toIso8601String() ?? '',
        'seen': msg.isSeen,
        'body': body,
        'htmlBody': htmlBody,
        'attachments': attachments,
      });
    } catch (e, st) {
      log.error('[IMAP MCP] read_email error: $e', e, st);
      await _safeLogout(client);
      return _error('IMAP read error: $e');
    }
  }

  // ── helpers ───────────────────────────────────────────────────

  Map<String, dynamic> _ok(Map<String, dynamic> data) => {
    'content': [
      {
        'type': 'text',
        'text': const JsonEncoder.withIndent('  ').convert(data),
      },
    ],
  };

  Map<String, dynamic> _error(String message) => {
    'isError': true,
    'content': [
      {'type': 'text', 'text': message},
    ],
  };

  String _argStr(Map<String, dynamic> args, String key, String fallback) {
    final raw = args[key];
    if (raw == null) return fallback;
    if (raw is List) {
      final parts = raw
          .map((e) {
            if (e is Map) {
              final name = (e['name'] ?? e['displayName'] ?? '')
                  .toString()
                  .trim();
              final email = (e['email'] ?? e['address'] ?? '')
                  .toString()
                  .trim();
              return name.isNotEmpty ? name : email;
            }
            return e.toString();
          })
          .where((s) => s.isNotEmpty)
          .join(', ');
      return parts.isNotEmpty ? parts : fallback;
    }
    final v = raw.toString().trim();
    return v.isNotEmpty ? v : fallback;
  }

  static const _diacriticMap = <int, String>{
    0xe0: 'a',
    0xe1: 'a',
    0xe2: 'a',
    0xe3: 'a',
    0xe4: 'a',
    0xe5: 'a',
    0xe6: 'ae',
    0xe7: 'c',
    0xe8: 'e',
    0xe9: 'e',
    0xea: 'e',
    0xeb: 'e',
    0xec: 'i',
    0xed: 'i',
    0xee: 'i',
    0xef: 'i',
    0xf0: 'd',
    0xf1: 'n',
    0xf2: 'o',
    0xf3: 'o',
    0xf4: 'o',
    0xf5: 'o',
    0xf6: 'o',
    0xf8: 'o',
    0xf9: 'u',
    0xfa: 'u',
    0xfb: 'u',
    0xfc: 'u',
    0xfd: 'y',
    0xff: 'y',
    0xdf: 'ss',
    0xc0: 'A',
    0xc1: 'A',
    0xc2: 'A',
    0xc3: 'A',
    0xc4: 'A',
    0xc5: 'A',
    0xc6: 'AE',
    0xc7: 'C',
    0xc8: 'E',
    0xc9: 'E',
    0xca: 'E',
    0xcb: 'E',
    0xcc: 'I',
    0xcd: 'I',
    0xce: 'I',
    0xcf: 'I',
    0xd0: 'D',
    0xd1: 'N',
    0xd2: 'O',
    0xd3: 'O',
    0xd4: 'O',
    0xd5: 'O',
    0xd6: 'O',
    0xd8: 'O',
    0xd9: 'U',
    0xda: 'U',
    0xdb: 'U',
    0xdc: 'U',
    0xdd: 'Y',
  };

  String _toAscii(String s) {
    final buf = StringBuffer();
    for (final r in s.runes) {
      if (r < 128) {
        buf.writeCharCode(r);
      } else {
        buf.write(_diacriticMap[r] ?? '');
      }
    }
    return buf.toString();
  }

  String _fmtAddresses(List<MailAddress>? addresses) {
    if (addresses == null || addresses.isEmpty) return '';
    return addresses
        .map((a) {
          final name = (a.personalName ?? '').trim();
          final email = a.email.trim();
          if (name.isNotEmpty && email.isNotEmpty) return '$name <$email>';
          return email.isNotEmpty ? email : name;
        })
        .join(', ');
  }

  void _collectAttachments(MimePart part, List<String> result) {
    final filename = part.decodeFileName();
    final cd = part.getHeaderValue('content-disposition') ?? '';
    if (filename != null && filename.isNotEmpty) {
      result.add(filename);
    } else if (cd.toLowerCase().startsWith('attachment')) {
      result.add(part.mediaType.text);
    }
    for (final child in part.parts ?? const <MimePart>[]) {
      _collectAttachments(child, result);
    }
  }

  DateTime? _parseYmd(String s) {
    try {
      return DateTime.parse(s);
    } catch (_) {
      return null;
    }
  }

  String _imapDate(DateTime d) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${d.day.toString().padLeft(2, '0')}-${months[d.month - 1]}-${d.year}';
  }

  Future<void> _safeLogout(ImapClient client) async {
    try {
      await client.logout();
    } catch (_) {}
  }
}

// ═══════════════════════════════════════════════════════════════
// Chart (server stub)
// ═══════════════════════════════════════════════════════════════

/// Server-mode stub for the chart tool.
///
/// Chart PNG generation uses Flutter's Canvas / dart:ui which is not
/// available in the headless server binary.  This stub registers the
/// same [create_chart_png] tool schema so the LLM knows the capability,
/// but returns a clear error when called.  Users who need PNG charts
/// should run the task inside the Flutter app instead.
class ServerChartMcp extends ServerInternalMcp {
  static const _tools = <MCPTool>[
    MCPTool(
      name: 'create_chart_png',
      description:
          'Generate a PNG chart from x-axis labels and numeric data series. '
          'Supported chart types: line, bar, area, pie, scatter, histogram, statistics_summary.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'chartType': {
            'type': 'string',
            'enum': [
              'line',
              'bar',
              'area',
              'pie',
              'scatter',
              'histogram',
              'statistics_summary',
            ],
            'default': 'line',
          },
          'xAxis': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'series': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'name': {'type': 'string'},
                'data': {
                  'type': 'array',
                  'items': {'type': 'number'},
                },
                'colorHex': {'type': 'string'},
              },
              'required': ['name', 'data'],
            },
          },
          'chartTitle': {'type': 'string'},
          'xAxisTitle': {'type': 'string'},
          'yAxisTitle': {'type': 'string'},
          'width': {'type': 'integer', 'default': 1000},
          'height': {'type': 'integer', 'default': 640},
        },
        'required': [],
      },
    ),
  ];

  @override
  List<MCPTool> get tools => _tools;

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> args,
  ) async {
    return {
      'isError': true,
      'content': [
        {
          'type': 'text',
          'text':
              'Chart PNG generation is not available in server mode. '
              'Flutter\'s rendering engine (dart:ui) is required to draw charts. '
              'Run this task inside the TealKit app to generate chart images.',
        },
      ],
    };
  }
}

// ═══════════════════════════════════════════════════════════════
// Google OAuth helper (shared by Gmail, Calendar, Drive)
// ═══════════════════════════════════════════════════════════════

/// Resolves a valid Google access token. Refreshes automatically when expired.
/// Returns `{'accessToken': token}` on success or `{'error': message}` on failure.
Future<Map<String, dynamic>> _resolveGoogleToken() async {
  final ds = ServerDataSourcesService.instance;
  if (ds.isGmailAccessTokenExpired) {
    final r = await _refreshGoogleToken(ds);
    if (r['error'] != null) return r;
  }
  final token = ds.gmailAccessToken.trim();
  if (token.isEmpty) {
    return {
      'error':
          'No Google OAuth access token. Configure Gmail/Google credentials in server settings.',
    };
  }
  return {'accessToken': token};
}

Future<Map<String, dynamic>> _refreshGoogleToken(
  ServerDataSourcesService ds,
) async {
  final clientId = ds.gmailClientId.trim();
  final clientSecret = ds.gmailClientSecret.trim();
  final refreshToken = ds.gmailRefreshToken.trim();
  if (clientId.isEmpty || clientSecret.isEmpty || refreshToken.isEmpty) {
    return {
      'error':
          'Google OAuth credentials (clientId, clientSecret, refreshToken) not configured.',
    };
  }
  try {
    final resp = await http.post(
      Uri.parse('https://oauth2.googleapis.com/token'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'grant_type': 'refresh_token',
        'client_id': clientId,
        'client_secret': clientSecret,
        'refresh_token': refreshToken,
      },
    );
    if (resp.statusCode != 200) {
      final snippet = resp.body.length > 300
          ? resp.body.substring(0, 300)
          : resp.body;
      return {
        'error': 'Google token refresh failed (${resp.statusCode}): $snippet',
      };
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final newToken = (data['access_token'] as String? ?? '').trim();
    if (newToken.isEmpty) {
      return {'error': 'Token refresh returned empty access_token.'};
    }
    final expiresIn = (data['expires_in'] as int?) ?? 3600;
    final expiry = DateTime.now().add(Duration(seconds: expiresIn));
    await ds.saveGmailTokens(
      accessToken: newToken,
      refreshToken: refreshToken,
      expiry: expiry,
      accountEmail: ds.gmailAccountEmail,
    );
    log.info('[Google OAuth] Token refreshed, expires $expiry');
    return {'accessToken': newToken};
  } catch (e) {
    return {'error': 'Google token refresh error: $e'};
  }
}

// ═══════════════════════════════════════════════════════════════
// Mermaid
// ═══════════════════════════════════════════════════════════════

class ServerMermaidMcp extends ServerInternalMcp {
  static const _renderUrl = 'https://kroki.io/mermaid/png';

  static const _tools = <MCPTool>[
    MCPTool(
      name: 'create_mermaid_png',
      description: 'Render Mermaid markdown (md) to a PNG image via kroki.io.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'md': {
            'type': 'string',
            'description':
                'Mermaid diagram markdown source. Example: graph TD; A-->B;',
          },
          'fileName': {
            'type': 'string',
            'description':
                'Optional target file name (.png appended if missing).',
          },
        },
        'required': ['md'],
      },
    ),
  ];

  @override
  List<MCPTool> get tools => _tools;

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> args,
  ) async {
    if (name != 'create_mermaid_png') return {'error': 'Unknown tool: $name'};

    final md = (args['md'] as String?)?.trim();
    if (md == null || md.isEmpty) {
      return {'error': 'Parameter "md" is required.'};
    }

    final fileName = _normalizeMermaidName(
      (args['fileName'] as String?)?.trim(),
    );

    try {
      final response = await http.post(
        Uri.parse(_renderUrl),
        headers: const {
          'Accept': 'image/png',
          'Content-Type': 'text/plain; charset=utf-8',
        },
        body: md,
      );

      final isPng =
          response.bodyBytes.length > 4 &&
          response.bodyBytes[0] == 0x89 &&
          response.bodyBytes[1] == 0x50 &&
          response.bodyBytes[2] == 0x4E &&
          response.bodyBytes[3] == 0x47;

      if ((response.statusCode < 200 || response.statusCode >= 300) && !isPng) {
        final body = utf8.decode(response.bodyBytes, allowMalformed: true);
        return {
          'error':
              'Mermaid rendering failed (${response.statusCode}): '
              '${body.isEmpty ? response.reasonPhrase ?? "unknown" : body}',
        };
      }

      final pngBytes = response.bodyBytes;
      if (pngBytes.isEmpty) {
        return {'error': 'Mermaid renderer returned an empty response.'};
      }

      return {
        'success': true,
        'message': 'Mermaid PNG generated successfully.',
        'fileName': fileName,
        'mimeType': 'image/png',
        'encoding': 'base64',
        'size': pngBytes.length,
        'content': base64Encode(pngBytes),
      };
    } catch (e) {
      return {'error': 'Mermaid rendering failed: $e'};
    }
  }

  String _normalizeMermaidName(String? requested) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final raw = (requested == null || requested.isEmpty)
        ? 'mermaid-$now'
        : requested;
    final safe = raw.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return safe.toLowerCase().endsWith('.png') ? safe : '$safe.png';
  }
}

// ═══════════════════════════════════════════════════════════════
// File output
// ═══════════════════════════════════════════════════════════════

class ServerFileMcp extends ServerInternalMcp {
  static const _tools = <MCPTool>[
    MCPTool(
      name: 'create_text_file',
      description:
          'Create HTML, Markdown, or plain text file from source content. Returns base64-encoded content.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'source': {
            'type': 'string',
            'description': 'Text content to store in the file.',
          },
          'fileName': {
            'type': 'string',
            'description':
                'Optional file name. Extension is normalized to detected type.',
          },
          'typeHint': {
            'type': 'string',
            'description': 'Force detection mode.',
            'enum': ['auto', 'html', 'markdown', 'text'],
            'default': 'auto',
          },
        },
        'required': ['source'],
      },
    ),
  ];

  @override
  List<MCPTool> get tools => _tools;

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> args,
  ) async {
    if (name != 'create_text_file') return {'error': 'Unknown tool: $name'};

    final source = args['source'] as String?;
    if (source == null || source.trim().isEmpty) {
      return {'error': 'Parameter "source" is required.'};
    }

    var hint = (args['typeHint'] as String? ?? 'auto').trim().toLowerCase();
    final requestedName = (args['fileName'] as String?)?.trim();

    if (hint == 'auto' && requestedName != null) {
      final lower = requestedName.toLowerCase();
      if (lower.endsWith('.md') || lower.endsWith('.markdown')) {
        hint = 'markdown';
      } else if (lower.endsWith('.html') || lower.endsWith('.htm')) {
        hint = 'html';
      } else if (lower.endsWith('.txt')) {
        hint = 'text';
      }
    }

    final detectedType = _detectFileType(source, hint: hint);
    final extension = _extFor(detectedType);
    final mimeType = _mimeFor(detectedType);
    final fileOut = _normalizeFileName(requestedName, extension);
    final bytes = utf8.encode(source);

    return {
      'success': true,
      'message': 'File created successfully.',
      'detectedType': detectedType,
      'fileName': fileOut,
      'mimeType': mimeType,
      'encoding': 'base64',
      'size': bytes.length,
      'content': base64Encode(bytes),
    };
  }

  String _detectFileType(String source, {required String hint}) {
    switch (hint) {
      case 'html':
        return _isHtmlContent(source)
            ? 'html'
            : (_isMarkdownContent(source) ? 'markdown' : 'text');
      case 'markdown':
        return 'markdown';
      case 'text':
        return 'text';
      default:
        if (_isHtmlContent(source)) return 'html';
        if (_isMarkdownContent(source)) return 'markdown';
        return 'text';
    }
  }

  bool _isHtmlContent(String s) {
    final t = s.trim();
    if (t.isEmpty) return false;
    final hasEnvelope = RegExp(
      r'^\s*(<!doctype\s+html[^>]*>\s*)?<html\b[^>]*>.*</html>\s*$',
      caseSensitive: false,
      dotAll: true,
    ).hasMatch(t);
    final hasTag = RegExp(
      r'<(head|body|div|p|h[1-6]|span|ul|ol|li|table|section|article)\b',
      caseSensitive: false,
    ).hasMatch(t);
    return hasEnvelope || hasTag;
  }

  bool _isMarkdownContent(String s) {
    final t = s.trim();
    if (t.isEmpty) return false;
    return [
      RegExp(r'^#{1,6}\s+.+$', multiLine: true),
      RegExp(r'^\s*[-*+]\s+.+$', multiLine: true),
      RegExp(r'^\s*\d+\.\s+.+$', multiLine: true),
      RegExp(r'```.+```', dotAll: true),
      RegExp(r'\[[^\]]+\]\([^\)]+\)'),
    ].any((r) => r.hasMatch(t));
  }

  String _extFor(String type) {
    switch (type) {
      case 'html':
        return 'html';
      case 'markdown':
        return 'md';
      default:
        return 'txt';
    }
  }

  String _mimeFor(String type) {
    switch (type) {
      case 'html':
        return 'text/html';
      case 'markdown':
        return 'text/markdown';
      default:
        return 'text/plain';
    }
  }

  String _normalizeFileName(String? requested, String extension) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (requested == null || requested.isEmpty) {
      return 'document-$now.$extension';
    }
    final safe = requested.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return safe.contains('.') ? safe : '$safe.$extension';
  }
}

// ═══════════════════════════════════════════════════════════════
// Excel Export
// ═══════════════════════════════════════════════════════════════

class ServerExcelMcp extends ServerInternalMcp {
  static const _tools = <MCPTool>[
    MCPTool(
      name: 'convert_to_excel',
      description:
          'Convert tabular data (CSV, JSON array of objects, or tab-separated text) to an Excel .xlsx file. '
          'Returns the file as a base64-encoded attachment.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'data': {
            'type': 'string',
            'description':
                'Tabular data: CSV, TSV, JSON array of objects or arrays, or plain newline-separated rows.',
          },
          'fileName': {
            'type': 'string',
            'description':
                'Output filename without extension. Defaults to "export".',
          },
          'sheetName': {
            'type': 'string',
            'description': 'Excel sheet name. Defaults to "Sheet1".',
          },
          'hasHeader': {
            'type': 'boolean',
            'description':
                'Whether the first row is a header (rendered bold). Defaults to true.',
            'default': true,
          },
        },
        'required': ['data'],
      },
    ),
  ];

  @override
  List<MCPTool> get tools => _tools;

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> args,
  ) async {
    if (name != 'convert_to_excel') return {'error': 'Unknown tool: $name'};

    final dataStr = args['data'] as String?;
    if (dataStr == null || dataStr.trim().isEmpty) {
      return {'error': 'Parameter "data" is required.'};
    }

    final rawName = ((args['fileName'] as String?) ?? 'export').trim();
    final safeName = rawName.isEmpty
        ? 'export'
        : rawName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    String sheetName = ((args['sheetName'] as String?) ?? 'Sheet1').trim();
    if (sheetName.isEmpty) sheetName = 'Sheet1';
    final hasHeader = args['hasHeader'] as bool? ?? true;

    try {
      final rows = _xlsxParseData(dataStr.trim());
      if (rows.isEmpty) {
        return {'error': 'Could not parse any data rows from the input.'};
      }

      final bytes = _buildXlsx(
        rows: rows,
        sheetName: sheetName,
        hasHeader: hasHeader,
      );
      final fileName = '$safeName.xlsx';

      return {
        'success': true,
        'message':
            'Excel file created: $fileName (${rows.length} row(s), sheet "$sheetName")',
        'fileName': fileName,
        'mimeType':
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        'encoding': 'base64',
        'size': bytes.length,
        'data': base64.encode(bytes),
      };
    } catch (e) {
      return {'error': 'Failed to create Excel file: $e'};
    }
  }

  Uint8List _buildXlsx({
    required List<List<String>> rows,
    required String sheetName,
    required bool hasHeader,
  }) {
    final shared = <String>[];
    final sharedIndex = <String, int>{};
    int strIdx(String s) => sharedIndex.putIfAbsent(s, () {
      final idx = shared.length;
      shared.add(s);
      return idx;
    });

    for (final row in rows) {
      for (final cell in row) {
        if (double.tryParse(cell) == null) strIdx(cell);
      }
    }

    final sheetXml = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
      ..write(
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>',
      );
    for (int r = 0; r < rows.length; r++) {
      final isBold = hasHeader && r == 0;
      sheetXml.write('<row r="${r + 1}">');
      for (int c = 0; c < rows[r].length; c++) {
        final ref = '${_xlsxColLetter(c)}${r + 1}';
        final val = rows[r][c];
        final numVal = double.tryParse(val);
        final s = isBold ? ' s="1"' : '';
        if (numVal != null && val.trim().isNotEmpty) {
          sheetXml.write('<c r="$ref"$s><v>$numVal</v></c>');
        } else {
          sheetXml.write('<c r="$ref" t="s"$s><v>${strIdx(val)}</v></c>');
        }
      }
      sheetXml.write('</row>');
    }
    sheetXml.write('</sheetData></worksheet>');

    final ssXml = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
      ..write(
        '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
        ' count="${shared.length}" uniqueCount="${shared.length}">',
      );
    for (final s in shared) {
      ssXml.write('<si><t>${_xlsxEscape(s)}</t></si>');
    }
    ssXml.write('</sst>');

    const styles =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font>'
        '<font><b/><sz val="11"/><name val="Calibri"/></font></fonts>'
        '<fills count="2"><fill><patternFill patternType="none"/></fill>'
        '<fill><patternFill patternType="gray125"/></fill></fills>'
        '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
        '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
        '<cellXfs count="2">'
        '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
        '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>'
        '</cellXfs></styleSheet>';
    const workbook =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
        ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        '<sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>';
    const wbRels =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1"'
        ' Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"'
        ' Target="worksheets/sheet1.xml"/>'
        '<Relationship Id="rId2"'
        ' Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings"'
        ' Target="sharedStrings.xml"/>'
        '<Relationship Id="rId3"'
        ' Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles"'
        ' Target="styles.xml"/>'
        '</Relationships>';
    const rootRels =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1"'
        ' Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"'
        ' Target="xl/workbook.xml"/>'
        '</Relationships>';
    const ct =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml"'
        ' ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/worksheets/sheet1.xml"'
        ' ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        '<Override PartName="/xl/sharedStrings.xml"'
        ' ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>'
        '<Override PartName="/xl/styles.xml"'
        ' ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
        '</Types>';

    final archive = Archive();
    void addEntry(String n, String content) {
      final b = utf8.encode(content);
      archive.addFile(ArchiveFile(n, b.length, b));
    }

    addEntry('[Content_Types].xml', ct);
    addEntry('_rels/.rels', rootRels);
    addEntry('xl/workbook.xml', workbook);
    addEntry('xl/_rels/workbook.xml.rels', wbRels);
    addEntry('xl/worksheets/sheet1.xml', sheetXml.toString());
    addEntry('xl/sharedStrings.xml', ssXml.toString());
    addEntry('xl/styles.xml', styles);

    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  String _xlsxColLetter(int index) {
    var result = '';
    var n = index;
    do {
      result = String.fromCharCode(65 + (n % 26)) + result;
      n = (n ~/ 26) - 1;
    } while (n >= 0);
    return result;
  }

  String _xlsxEscape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  List<List<String>> _xlsxParseData(String data) {
    if (data.startsWith('[')) {
      try {
        final parsed = jsonDecode(data) as List;
        if (parsed.isNotEmpty) {
          if (parsed.first is Map) {
            final maps = parsed.cast<Map<String, dynamic>>();
            final headers = maps.first.keys.toList();
            return [
              headers.map((h) => h.toString()).toList(),
              ...maps.map(
                (row) => headers.map((h) => row[h]?.toString() ?? '').toList(),
              ),
            ];
          } else if (parsed.first is List) {
            return parsed
                .map(
                  (r) => (r as List).map((c) => c?.toString() ?? '').toList(),
                )
                .toList();
          }
        }
      } catch (_) {}
    }

    final lines = data
        .split(RegExp(r'\r?\n'))
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty) return const [];
    final first = lines.first;
    final delimiter =
        '\t'.allMatches(first).length > ','.allMatches(first).length
        ? '\t'
        : ',';
    return lines.map((l) => _xlsxSplitLine(l, delimiter)).toList();
  }

  List<String> _xlsxSplitLine(String line, String delimiter) {
    if (delimiter == '\t') {
      return line.split('\t').map((c) => c.trim()).toList();
    }
    final cells = <String>[];
    var current = StringBuffer();
    var inQuotes = false;
    for (int i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          current.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
      } else if (ch == ',' && !inQuotes) {
        cells.add(current.toString().trim());
        current = StringBuffer();
      } else {
        current.write(ch);
      }
    }
    cells.add(current.toString().trim());
    return cells;
  }
}

// ═══════════════════════════════════════════════════════════════
// Home Assistant
// ═══════════════════════════════════════════════════════════════

class ServerHomeAssistantMcp extends ServerInternalMcp {
  String _baseUrl = '';
  String _token = '';
  List<Map<String, dynamic>> _entityCache = [];
  DateTime? _entityCacheTime;
  static const _cacheTtl = Duration(minutes: 5);

  static const _tools = <MCPTool>[
    MCPTool(
      name: 'list_ha_entities',
      description:
          'List Home Assistant entities. Optionally filter by domain (light, switch, sensor, climate, cover, '
          'automation, script, media_player, fan, lock, alarm_control_panel).',
      inputSchema: {
        'type': 'object',
        'properties': {
          'domain': {
            'type': 'string',
            'description': 'Optional domain filter, e.g. "light" or "switch".',
          },
          'area': {
            'type': 'string',
            'description': 'Optional area/room name filter (case-insensitive).',
          },
          'search': {
            'type': 'string',
            'description':
                'Optional free-text search in entity id or friendly name.',
          },
          'limit': {
            'type': 'integer',
            'default': 50,
            'description': 'Max number of results (default 50).',
          },
        },
        'required': [],
      },
    ),
    MCPTool(
      name: 'get_ha_entity_state',
      description:
          'Get the current state and attributes of a single Home Assistant entity.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'entity_id': {
            'type': 'string',
            'description': 'Full entity id, e.g. "light.living_room".',
          },
        },
        'required': ['entity_id'],
      },
    ),
    MCPTool(
      name: 'control_ha_entity',
      description:
          'Call a Home Assistant service to control a device. '
          'Common services: turn_on, turn_off, toggle. '
          'For lights pass brightness (0-255) or rgb_color in serviceData. '
          'The service domain is derived automatically from entity_id.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'entity_id': {
            'type': 'string',
            'description': 'Entity id, e.g. "light.bedroom".',
          },
          'service': {
            'type': 'string',
            'description':
                'Service name without domain, e.g. "turn_on", "turn_off", "toggle".',
          },
          'serviceData': {
            'type': 'object',
            'description':
                'Optional extra service data, e.g. {"brightness": 200}.',
          },
        },
        'required': ['entity_id', 'service'],
      },
    ),
    MCPTool(
      name: 'trigger_ha_automation',
      description: 'Trigger a Home Assistant automation by entity_id.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'entity_id': {
            'type': 'string',
            'description':
                'Automation entity id, e.g. "automation.morning_routine".',
          },
        },
        'required': ['entity_id'],
      },
    ),
    MCPTool(
      name: 'get_ha_history',
      description: 'Get state history for an entity over the past N hours.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'entity_id': {'type': 'string'},
          'hours': {
            'type': 'integer',
            'default': 6,
            'description': 'How many hours of history (default 6, max 72).',
          },
        },
        'required': ['entity_id'],
      },
    ),
  ];

  @override
  List<MCPTool> get tools => _tools;

  Future<void> initialize(Map<String, dynamic> initParams) async {
    _baseUrl = (initParams['haBaseUrl'] as String? ?? '').trim().replaceAll(
      RegExp(r'/+$'),
      '',
    );
    _token = (initParams['haToken'] as String? ?? '').trim();

    if (_baseUrl.isEmpty || _token.isEmpty) {
      final ds = ServerDataSourcesService.instance;
      if (_baseUrl.isEmpty) {
        _baseUrl = ds.haBaseUrl.replaceAll(RegExp(r'/+$'), '');
      }
      if (_token.isEmpty) _token = ds.haToken;
    }

    _entityCache = [];
    _entityCacheTime = null;
    log.info(
      '[HA MCP] Initialized baseUrl=$_baseUrl hasToken=${_token.isNotEmpty}',
    );
  }

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> args,
  ) async {
    if (_baseUrl.isEmpty || _token.isEmpty) {
      return {
        'error':
            'Home Assistant not configured. Set haBaseUrl and haToken in server settings or task init params.',
      };
    }
    switch (name) {
      case 'list_ha_entities':
        return _listEntities(args);
      case 'get_ha_entity_state':
        return _getEntityState(args);
      case 'control_ha_entity':
        return _controlEntity(args);
      case 'trigger_ha_automation':
        return _triggerAutomation(args);
      case 'get_ha_history':
        return _getHistory(args);
      default:
        return {'error': 'Unknown tool: $name'};
    }
  }

  Map<String, String> get _haHeaders => {
    'Authorization': 'Bearer $_token',
    'Content-Type': 'application/json',
  };

  Future<http.Response> _haGet(String path) => http
      .get(Uri.parse('$_baseUrl$path'), headers: _haHeaders)
      .timeout(const Duration(seconds: 15));

  Future<http.Response> _haPost(String path, Map<String, dynamic> body) => http
      .post(
        Uri.parse('$_baseUrl$path'),
        headers: _haHeaders,
        body: jsonEncode(body),
      )
      .timeout(const Duration(seconds: 15));

  Map<String, dynamic> _haErr(http.Response res, String ctx) {
    log.warning('[HA MCP] $ctx → HTTP ${res.statusCode}');
    return {
      'error': 'HA API error ($ctx): HTTP ${res.statusCode}',
      'detail': res.body.length > 400
          ? '${res.body.substring(0, 400)}…'
          : res.body,
    };
  }

  Future<List<Map<String, dynamic>>> _fetchAllEntities() async {
    final now = DateTime.now();
    if (_entityCacheTime != null &&
        now.difference(_entityCacheTime!) < _cacheTtl &&
        _entityCache.isNotEmpty) {
      return _entityCache;
    }
    final res = await _haGet('/api/states');
    if (res.statusCode != 200) {
      throw Exception('HA /api/states → HTTP ${res.statusCode}');
    }
    _entityCache = (jsonDecode(res.body) as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    _entityCacheTime = now;
    return _entityCache;
  }

  Future<Map<String, dynamic>> _listEntities(Map<String, dynamic> args) async {
    try {
      final domainFilter = (args['domain'] as String?)?.trim().toLowerCase();
      final areaFilter = (args['area'] as String?)?.trim().toLowerCase();
      final searchFilter = (args['search'] as String?)?.trim().toLowerCase();
      final limit = ((args['limit'] as int?) ?? 50).clamp(1, 500);

      final all = await _fetchAllEntities();
      final filtered = all
          .where((e) {
            final id = (e['entity_id'] as String? ?? '').toLowerCase();
            final name =
                ((e['attributes'] as Map?)?['friendly_name'] as String? ?? '')
                    .toLowerCase();
            final area = ((e['attributes'] as Map?)?['area'] as String? ?? '')
                .toLowerCase();
            if (domainFilter != null && !id.startsWith('$domainFilter.')) {
              return false;
            }
            if (areaFilter != null &&
                !area.contains(areaFilter) &&
                !name.contains(areaFilter)) {
              return false;
            }
            if (searchFilter != null &&
                !id.contains(searchFilter) &&
                !name.contains(searchFilter)) {
              return false;
            }
            return true;
          })
          .take(limit)
          .map((e) {
            final attrs = e['attributes'] as Map? ?? {};
            return {
              'entity_id': e['entity_id'],
              'state': e['state'],
              'friendly_name': attrs['friendly_name'],
              'domain': (e['entity_id'] as String).split('.').first,
            };
          })
          .toList();

      return {'count': filtered.length, 'entities': filtered};
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> _getEntityState(
    Map<String, dynamic> args,
  ) async {
    final entityId = (args['entity_id'] as String?)?.trim();
    if (entityId == null || entityId.isEmpty) {
      return {'error': 'entity_id is required.'};
    }
    try {
      final res = await _haGet('/api/states/$entityId');
      if (res.statusCode != 200) return _haErr(res, 'get_state($entityId)');
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      return {
        'entity_id': data['entity_id'],
        'state': data['state'],
        'attributes': data['attributes'],
        'last_changed': data['last_changed'],
        'last_updated': data['last_updated'],
      };
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> _controlEntity(Map<String, dynamic> args) async {
    final entityId = (args['entity_id'] as String?)?.trim();
    final service = (args['service'] as String?)?.trim();
    if (entityId == null || entityId.isEmpty) {
      return {'error': 'entity_id is required.'};
    }
    if (service == null || service.isEmpty) {
      return {'error': 'service is required.'};
    }
    final parts = entityId.split('.');
    if (parts.length < 2) return {'error': 'entity_id must be "domain.name".'};
    final domain = parts.first;
    final body = <String, dynamic>{'entity_id': entityId};
    final extra = args['serviceData'];
    if (extra is Map) body.addAll(Map<String, dynamic>.from(extra));
    try {
      _entityCacheTime = null;
      final res = await _haPost('/api/services/$domain/$service', body);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        return _haErr(res, 'control($entityId, $service)');
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final stateRes = await _haGet('/api/states/$entityId');
      final newState = stateRes.statusCode == 200
          ? (jsonDecode(stateRes.body) as Map)['state']
          : 'unknown';
      log.info('[HA MCP] $entityId → $service → $newState');
      return {
        'success': true,
        'entity_id': entityId,
        'service': service,
        'newState': newState,
      };
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> _triggerAutomation(
    Map<String, dynamic> args,
  ) async {
    final entityId = (args['entity_id'] as String?)?.trim();
    if (entityId == null || entityId.isEmpty) {
      return {'error': 'entity_id is required.'};
    }
    try {
      final res = await _haPost('/api/services/automation/trigger', {
        'entity_id': entityId,
      });
      if (res.statusCode < 200 || res.statusCode >= 300) {
        return _haErr(res, 'trigger($entityId)');
      }
      return {'success': true, 'entity_id': entityId};
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> _getHistory(Map<String, dynamic> args) async {
    final entityId = (args['entity_id'] as String?)?.trim();
    if (entityId == null || entityId.isEmpty) {
      return {'error': 'entity_id is required.'};
    }
    final hours = ((args['hours'] as int?) ?? 6).clamp(1, 72);
    final since = DateTime.now()
        .toUtc()
        .subtract(Duration(hours: hours))
        .toIso8601String();
    try {
      final res = await _haGet(
        '/api/history/period/$since?filter_entity_id=$entityId&minimal_response=true',
      );
      if (res.statusCode != 200) return _haErr(res, 'history($entityId)');
      final raw = jsonDecode(res.body) as List;
      final entries = raw.isEmpty ? <dynamic>[] : raw.first as List;
      return {
        'entity_id': entityId,
        'hours': hours,
        'count': entries.length,
        'history': entries
            .map(
              (e) => {'state': e['state'], 'last_changed': e['last_changed']},
            )
            .toList(),
      };
    } catch (e) {
      return {'error': e.toString()};
    }
  }
}

// ═══════════════════════════════════════════════════════════════
// Gmail
// ═══════════════════════════════════════════════════════════════

class ServerGmailMcp extends ServerInternalMcp {
  static const _gmailBase = 'https://gmail.googleapis.com/gmail/v1/users';

  String _userId = 'me';
  String? _gmailToken;

  static const _tools = <MCPTool>[
    MCPTool(
      name: 'search_gmail',
      description:
          'Search Gmail messages using Gmail API q parameter. '
          'Examples: "from:john@example.com", "has:attachment", "is:unread subject:invoice".',
      inputSchema: {
        'type': 'object',
        'properties': {
          'q': {
            'type': 'string',
            'description': 'Gmail query string (standard Gmail search syntax).',
          },
          'maxResults': {
            'type': 'integer',
            'description': 'Maximum results (default: 20, max: 100).',
            'default': 20,
          },
          'labelIds': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'Optional label filters (e.g. INBOX, UNREAD).',
          },
          'includeBody': {
            'type': 'boolean',
            'description': 'Include plain text body (default: false).',
            'default': false,
          },
          'accessToken': {
            'type': 'string',
            'description': 'Optional token override.',
          },
        },
        'required': ['q'],
      },
    ),
    MCPTool(
      name: 'get_gmail_message',
      description: 'Fetch one Gmail message by id.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'id': {'type': 'string', 'description': 'Gmail message id.'},
          'format': {
            'type': 'string',
            'enum': ['metadata', 'full', 'minimal'],
            'default': 'full',
          },
          'accessToken': {
            'type': 'string',
            'description': 'Optional token override.',
          },
        },
        'required': ['id'],
      },
    ),
  ];

  @override
  List<MCPTool> get tools => _tools;

  Future<void> initialize(Map<String, dynamic> initParams) async {
    _userId = ((initParams['userId'] as String?) ?? 'me').trim();
    if (_userId.isEmpty) _userId = 'me';
    final t = (initParams['accessToken'] as String?)?.trim();
    if (t != null && t.isNotEmpty) {
      _gmailToken = t;
    } else {
      final ds = ServerDataSourcesService.instance;
      if (!ds.isGmailAccessTokenExpired &&
          ds.gmailAccessToken.trim().isNotEmpty) {
        _gmailToken = ds.gmailAccessToken.trim();
      }
    }
    log.info('[Gmail MCP] Initialized userId=$_userId');
  }

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> args,
  ) async {
    switch (name) {
      case 'search_gmail':
        return _searchGmail(args);
      case 'get_gmail_message':
        return _getMessage(args);
      default:
        return {'error': 'Unknown tool: $name'};
    }
  }

  Future<Map<String, dynamic>> _searchGmail(Map<String, dynamic> args) async {
    final rawQuery = (args['q'] as String?)?.trim();
    if (rawQuery == null || rawQuery.isEmpty) {
      return {'error': 'Parameter "q" is required.'};
    }

    final token = await _resolveGmailToken(args);
    if (token == null) {
      return {
        'error':
            'No OAuth access token. Configure Gmail credentials in server settings.',
      };
    }

    final maxResults = ((args['maxResults'] as int?) ?? 20).clamp(1, 100);
    final includeBody = args['includeBody'] == true;
    final labelIds =
        (args['labelIds'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        const <String>[];

    final qp = <String, String>{'q': rawQuery, 'maxResults': '$maxResults'};
    if (labelIds.isNotEmpty) qp['labelIds'] = labelIds.join(',');

    final listUri = Uri.parse(
      '$_gmailBase/$_userId/messages',
    ).replace(queryParameters: qp);
    final listResp = await _gmailGet(listUri, token);
    if (listResp['error'] != null) return listResp;

    final messagesRaw =
        (listResp['data'] as Map<String, dynamic>)['messages']
            as List<dynamic>? ??
        const [];
    if (messagesRaw.isEmpty) {
      return {
        'q': rawQuery,
        'maxResults': maxResults,
        'totalEstimated': 0,
        'messages': <Map<String, dynamic>>[],
      };
    }

    final messages = <Map<String, dynamic>>[];
    for (final entry in messagesRaw) {
      final id = (entry as Map<String, dynamic>)['id']?.toString();
      if (id == null || id.isEmpty) continue;
      final detail = await _fetchGmailSummary(
        id,
        token,
        includeBody: includeBody,
      );
      if (detail['error'] == null) messages.add(detail);
    }

    return {
      'q': rawQuery,
      'maxResults': maxResults,
      'totalEstimated':
          (listResp['data'] as Map<String, dynamic>)['resultSizeEstimate'] ??
          messages.length,
      'returned': messages.length,
      'messages': messages,
    };
  }

  Future<Map<String, dynamic>> _getMessage(Map<String, dynamic> args) async {
    final id = (args['id'] as String?)?.trim();
    if (id == null || id.isEmpty) {
      return {'error': 'Parameter "id" is required.'};
    }
    final format = (args['format'] as String? ?? 'full').trim();
    final token = await _resolveGmailToken(args);
    if (token == null) return {'error': 'No OAuth access token.'};

    final uri = Uri.parse(
      '$_gmailBase/$_userId/messages/$id',
    ).replace(queryParameters: {'format': format});
    final resp = await _gmailGet(uri, token);
    if (resp['error'] != null) return resp;

    final data = resp['data'] as Map<String, dynamic>;
    return {
      'id': data['id'],
      'threadId': data['threadId'],
      'labelIds': data['labelIds'],
      'snippet': data['snippet'],
      'payload': data['payload'],
      if (format == 'full')
        'plainTextBody': _gmailPlainText(
          data['payload'] as Map<String, dynamic>?,
        ),
    };
  }

  Future<Map<String, dynamic>> _fetchGmailSummary(
    String messageId,
    String token, {
    required bool includeBody,
  }) async {
    final uri = Uri.parse(
      '$_gmailBase/$_userId/messages/$messageId',
    ).replace(queryParameters: {'format': 'metadata'});
    final resp = await _gmailGet(uri, token);
    if (resp['error'] != null) return resp;

    final data = resp['data'] as Map<String, dynamic>;
    final payload = data['payload'] as Map<String, dynamic>? ?? const {};
    final headers = ((payload['headers'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .fold<Map<String, String>>({}, (acc, h) {
          acc[(h['name'] ?? '').toString().toLowerCase()] = (h['value'] ?? '')
              .toString();
          return acc;
        });

    String? body;
    if (includeBody) {
      final fullR = await _gmailGet(
        Uri.parse(
          '$_gmailBase/$_userId/messages/$messageId',
        ).replace(queryParameters: {'format': 'full'}),
        token,
      );
      if (fullR['error'] == null) {
        body = _gmailPlainText(
          (fullR['data'] as Map<String, dynamic>)['payload']
              as Map<String, dynamic>?,
        );
      }
    }

    return {
      'id': data['id'],
      'threadId': data['threadId'],
      'subject': headers['subject'] ?? '',
      'from': headers['from'] ?? '',
      'to': headers['to'] ?? '',
      'date': headers['date'] ?? '',
      'snippet': data['snippet'] ?? '',
      'internalDate': data['internalDate'],
      if (includeBody) 'body': body ?? '',
    };
  }

  String _gmailPlainText(Map<String, dynamic>? payload) {
    if (payload == null) return '';
    final body = payload['body'] as Map<String, dynamic>?;
    final bodyData = body?['data']?.toString();
    final mime = payload['mimeType']?.toString() ?? '';
    if (bodyData != null &&
        bodyData.isNotEmpty &&
        (mime == 'text/plain' || mime.isEmpty)) {
      return _gmailDecodeB64(bodyData);
    }
    for (final part
        in (payload['parts'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()) {
      final mt = part['mimeType']?.toString() ?? '';
      if (mt == 'text/plain') {
        final d = (part['body'] as Map<String, dynamic>?)?['data']?.toString();
        if (d != null && d.isNotEmpty) return _gmailDecodeB64(d);
      }
      final nested = _gmailPlainText(part);
      if (nested.trim().isNotEmpty) return nested;
    }
    return '';
  }

  String _gmailDecodeB64(String value) {
    try {
      final normalized = base64.normalize(
        value.replaceAll('-', '+').replaceAll('_', '/'),
      );
      return utf8.decode(base64Decode(normalized), allowMalformed: true);
    } catch (_) {
      return '';
    }
  }

  Future<String?> _resolveGmailToken(Map<String, dynamic> args) async {
    final fromArgs = (args['accessToken'] as String?)?.trim();
    if (fromArgs != null && fromArgs.isNotEmpty) return fromArgs;
    if (_gmailToken != null && _gmailToken!.isNotEmpty) return _gmailToken;
    final result = await _resolveGoogleToken();
    if (result['error'] != null) return null;
    _gmailToken = result['accessToken'] as String;
    return _gmailToken;
  }

  Future<Map<String, dynamic>> _gmailGet(Uri uri, String token) async {
    try {
      var resp = await http.get(
        uri,
        headers: {
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
        },
      );
      if (resp.statusCode == 401) {
        final ds = ServerDataSourcesService.instance;
        final r = await _refreshGoogleToken(ds);
        if (r['error'] != null) {
          return {'error': 'Gmail 401 and token refresh failed: ${r['error']}'};
        }
        final newToken = r['accessToken'] as String;
        _gmailToken = newToken;
        resp = await http.get(
          uri,
          headers: {
            'Authorization': 'Bearer $newToken',
            'Accept': 'application/json',
          },
        );
      }
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        return {
          'data': resp.body.isNotEmpty
              ? jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>
              : <String, dynamic>{},
        };
      }
      return {
        'error': 'Gmail API error ${resp.statusCode}: ${resp.reasonPhrase}',
      };
    } catch (e) {
      return {'error': 'Gmail request failed: $e'};
    }
  }
}

// ═══════════════════════════════════════════════════════════════
// Google Calendar
// ═══════════════════════════════════════════════════════════════

class ServerGoogleCalendarMcp extends ServerInternalMcp {
  static const _calBase = 'https://www.googleapis.com/calendar/v3';
  String? _calToken;

  static const _tools = <MCPTool>[
    MCPTool(
      name: 'list_calendars',
      description: 'List all Google calendars accessible to the user.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'accessToken': {'type': 'string'},
        },
        'required': [],
      },
    ),
    MCPTool(
      name: 'list_events',
      description:
          'List or search events on a calendar. Use timeMin/timeMax (ISO 8601 with Z suffix) to filter by date.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'calendarId': {'type': 'string', 'default': 'primary'},
          'q': {'type': 'string', 'description': 'Free-text search query.'},
          'timeMin': {
            'type': 'string',
            'description': 'ISO 8601 UTC, e.g. 2026-02-24T00:00:00Z',
          },
          'timeMax': {
            'type': 'string',
            'description': 'ISO 8601 UTC, e.g. 2026-02-25T00:00:00Z',
          },
          'maxResults': {'type': 'integer', 'default': 25},
          'orderBy': {
            'type': 'string',
            'enum': ['startTime', 'updated'],
            'default': 'startTime',
          },
          'accessToken': {'type': 'string'},
        },
      },
    ),
    MCPTool(
      name: 'get_event',
      description: 'Get a single calendar event by ID.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'calendarId': {'type': 'string', 'default': 'primary'},
          'eventId': {'type': 'string'},
          'accessToken': {'type': 'string'},
        },
        'required': ['eventId'],
      },
    ),
    MCPTool(
      name: 'create_event',
      description: 'Create a new Google Calendar event.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'calendarId': {'type': 'string', 'default': 'primary'},
          'summary': {'type': 'string'},
          'description': {'type': 'string'},
          'location': {'type': 'string'},
          'start': {
            'type': 'string',
            'description': 'ISO 8601 datetime or YYYY-MM-DD for all-day.',
          },
          'end': {'type': 'string'},
          'allDay': {'type': 'boolean'},
          'attendees': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'accessToken': {'type': 'string'},
        },
        'required': ['summary', 'start', 'end'],
      },
    ),
    MCPTool(
      name: 'update_event',
      description: 'Update (patch) an existing Google Calendar event.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'calendarId': {'type': 'string', 'default': 'primary'},
          'eventId': {'type': 'string'},
          'summary': {'type': 'string'},
          'description': {'type': 'string'},
          'location': {'type': 'string'},
          'start': {'type': 'string'},
          'end': {'type': 'string'},
          'allDay': {'type': 'boolean'},
          'accessToken': {'type': 'string'},
        },
        'required': ['eventId'],
      },
    ),
    MCPTool(
      name: 'delete_event',
      description: 'Delete a Google Calendar event permanently.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'calendarId': {'type': 'string', 'default': 'primary'},
          'eventId': {'type': 'string'},
          'accessToken': {'type': 'string'},
        },
        'required': ['eventId'],
      },
    ),
  ];

  @override
  List<MCPTool> get tools => _tools;

  Future<void> initialize(Map<String, dynamic> initParams) async {
    final t = (initParams['accessToken'] as String?)?.trim();
    if (t != null && t.isNotEmpty) {
      _calToken = t;
    } else {
      final ds = ServerDataSourcesService.instance;
      if (!ds.isGmailAccessTokenExpired &&
          ds.gmailAccessToken.trim().isNotEmpty) {
        _calToken = ds.gmailAccessToken.trim();
      }
    }
    log.info(
      '[Calendar MCP] Initialized token=${_calToken != null ? "present" : "missing"}',
    );
  }

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> args,
  ) async {
    switch (name) {
      case 'list_calendars':
        return _listCalendars(args);
      case 'list_events':
        return _listEvents(args);
      case 'get_event':
        return _getEvent(args);
      case 'create_event':
        return _createEvent(args);
      case 'update_event':
        return _updateEvent(args);
      case 'delete_event':
        return _deleteEvent(args);
      default:
        return {'error': 'Unknown tool: $name'};
    }
  }

  Future<Map<String, dynamic>> _listCalendars(Map<String, dynamic> args) async {
    final token = await _getCalToken(args);
    if (token == null) return _calNoToken();
    final r = await _calGet(
      Uri.parse('$_calBase/users/me/calendarList'),
      token,
    );
    if (r['error'] != null) return r;
    final items = ((r['data'] as Map)['items'] as List? ?? [])
        .map(
          (c) => {
            'id': c['id'],
            'summary': c['summary'],
            'primary': c['primary'] ?? false,
          },
        )
        .toList();
    return {'calendars': items, 'count': items.length};
  }

  Future<Map<String, dynamic>> _listEvents(Map<String, dynamic> args) async {
    final token = await _getCalToken(args);
    if (token == null) return _calNoToken();
    final calId = Uri.encodeComponent(_calId(args));
    final params = <String, String>{
      'singleEvents': 'true',
      'maxResults': '${(args['maxResults'] as int?) ?? 25}',
      'orderBy': ((args['orderBy'] as String?)?.isNotEmpty == true)
          ? args['orderBy']!
          : 'startTime',
    };
    if ((args['q'] as String?)?.isNotEmpty == true) params['q'] = args['q']!;
    if ((args['timeMin'] as String?)?.isNotEmpty == true) {
      params['timeMin'] = args['timeMin']!;
    }
    if ((args['timeMax'] as String?)?.isNotEmpty == true) {
      params['timeMax'] = args['timeMax']!;
    }
    final r = await _calGet(
      Uri.parse(
        '$_calBase/calendars/$calId/events',
      ).replace(queryParameters: params),
      token,
    );
    if (r['error'] != null) return r;
    final items = ((r['data'] as Map)['items'] as List? ?? [])
        .map((e) => _calSummary(e as Map<String, dynamic>))
        .toList();
    return {'events': items, 'count': items.length};
  }

  Future<Map<String, dynamic>> _getEvent(Map<String, dynamic> args) async {
    final token = await _getCalToken(args);
    if (token == null) return _calNoToken();
    final calId = Uri.encodeComponent(_calId(args));
    final eventId = Uri.encodeComponent(args['eventId'] as String? ?? '');
    final r = await _calGet(
      Uri.parse('$_calBase/calendars/$calId/events/$eventId'),
      token,
    );
    if (r['error'] != null) return r;
    return _calSummary(r['data'] as Map<String, dynamic>);
  }

  Future<Map<String, dynamic>> _createEvent(Map<String, dynamic> args) async {
    final token = await _getCalToken(args);
    if (token == null) return _calNoToken();
    final calId = Uri.encodeComponent(_calId(args));
    final allDay = args['allDay'] == true;
    final body = <String, dynamic>{
      'summary': args['summary'] ?? '',
      if ((args['description'] as String?)?.isNotEmpty == true)
        'description': args['description'],
      if ((args['location'] as String?)?.isNotEmpty == true)
        'location': args['location'],
      'start': allDay
          ? {'date': args['start']}
          : {'dateTime': _toRfc3339(args['start'] as String? ?? '')},
      'end': allDay
          ? {'date': args['end']}
          : {'dateTime': _toRfc3339(args['end'] as String? ?? '')},
    };
    if (args['attendees'] is List) {
      body['attendees'] = (args['attendees'] as List)
          .map((e) => {'email': e})
          .toList();
    }
    final r = await _calPost(
      Uri.parse('$_calBase/calendars/$calId/events'),
      token,
      body,
    );
    if (r['error'] != null) return r;
    return {
      'success': true,
      'event': _calSummary(r['data'] as Map<String, dynamic>),
    };
  }

  Future<Map<String, dynamic>> _updateEvent(Map<String, dynamic> args) async {
    final token = await _getCalToken(args);
    if (token == null) return _calNoToken();
    final calId = Uri.encodeComponent(_calId(args));
    final eventId = Uri.encodeComponent(args['eventId'] as String? ?? '');
    final allDay = args['allDay'] == true;
    final body = <String, dynamic>{
      if (args['summary'] != null) 'summary': args['summary'],
      if (args['description'] != null) 'description': args['description'],
      if (args['location'] != null) 'location': args['location'],
      if (args['start'] != null)
        'start': allDay
            ? {'date': args['start']}
            : {'dateTime': _toRfc3339(args['start'] as String)},
      if (args['end'] != null)
        'end': allDay
            ? {'date': args['end']}
            : {'dateTime': _toRfc3339(args['end'] as String)},
    };
    final r = await _calPatch(
      Uri.parse('$_calBase/calendars/$calId/events/$eventId'),
      token,
      body,
    );
    if (r['error'] != null) return r;
    return {
      'success': true,
      'event': _calSummary(r['data'] as Map<String, dynamic>),
    };
  }

  Future<Map<String, dynamic>> _deleteEvent(Map<String, dynamic> args) async {
    final token = await _getCalToken(args);
    if (token == null) return _calNoToken();
    final calId = Uri.encodeComponent(_calId(args));
    final eventId = Uri.encodeComponent(args['eventId'] as String? ?? '');
    final r = await _calDelete(
      Uri.parse('$_calBase/calendars/$calId/events/$eventId'),
      token,
    );
    if (r['error'] != null) return r;
    return {'success': true, 'message': 'Event deleted.'};
  }

  String _calId(Map<String, dynamic> args) {
    final s = (args['calendarId'] as String?)?.trim() ?? '';
    return s.isEmpty ? 'primary' : s;
  }

  Map<String, dynamic> _calSummary(Map<String, dynamic> e) {
    final start = e['start'] as Map? ?? {};
    final end = e['end'] as Map? ?? {};
    return {
      'id': e['id'],
      'summary': e['summary'],
      if (e['description'] != null) 'description': e['description'],
      if (e['location'] != null) 'location': e['location'],
      'start': start['dateTime'] ?? start['date'],
      'end': end['dateTime'] ?? end['date'],
      'status': e['status'],
      'htmlLink': e['htmlLink'],
    };
  }

  Map<String, dynamic> _calNoToken() => {
    'error':
        'No Google OAuth access token. '
        'Authorize Google in server settings (gmailClientId, gmailClientSecret, gmailRefreshToken).',
  };

  Future<String?> _getCalToken(Map<String, dynamic> args) async {
    final fromArgs = (args['accessToken'] as String?)?.trim();
    if (fromArgs != null && fromArgs.isNotEmpty) return fromArgs;
    if (_calToken != null && _calToken!.isNotEmpty) return _calToken;
    final r = await _resolveGoogleToken();
    if (r['error'] != null) return null;
    _calToken = r['accessToken'] as String;
    return _calToken;
  }

  String _toRfc3339(String dt) {
    if (dt.isEmpty) return dt;
    try {
      return DateTime.parse(dt).toUtc().toIso8601String();
    } catch (_) {
      final after = dt.length > 10 ? dt.substring(10) : '';
      final hasTz =
          after.contains('Z') ||
          after.contains('+') ||
          (after.contains('-') && after.length > 3);
      return hasTz ? dt : '${dt}Z';
    }
  }

  Future<Map<String, dynamic>> _calGet(
    Uri uri,
    String token, {
    bool retried = false,
  }) async {
    try {
      final resp = await http.get(
        uri,
        headers: {
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
        },
      );
      if (resp.statusCode == 401 && !retried) {
        return await _calRefreshRetry(uri, 'GET', null);
      }
      return _calParse(resp);
    } catch (e) {
      return {'error': 'Calendar request failed: $e'};
    }
  }

  Future<Map<String, dynamic>> _calPost(
    Uri uri,
    String token,
    Map<String, dynamic> body, {
    bool retried = false,
  }) async {
    try {
      final resp = await http.post(
        uri,
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      );
      if (resp.statusCode == 401 && !retried) {
        return await _calRefreshRetry(uri, 'POST', body);
      }
      return _calParse(resp);
    } catch (e) {
      return {'error': 'Calendar request failed: $e'};
    }
  }

  Future<Map<String, dynamic>> _calPatch(
    Uri uri,
    String token,
    Map<String, dynamic> body, {
    bool retried = false,
  }) async {
    try {
      final resp = await http.patch(
        uri,
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      );
      if (resp.statusCode == 401 && !retried) {
        return await _calRefreshRetry(uri, 'PATCH', body);
      }
      return _calParse(resp);
    } catch (e) {
      return {'error': 'Calendar request failed: $e'};
    }
  }

  Future<Map<String, dynamic>> _calDelete(
    Uri uri,
    String token, {
    bool retried = false,
  }) async {
    try {
      final resp = await http.delete(
        uri,
        headers: {'Authorization': 'Bearer $token'},
      );
      if (resp.statusCode == 401 && !retried) {
        return await _calRefreshRetry(uri, 'DELETE', null);
      }
      if (resp.statusCode == 204) return {'data': <String, dynamic>{}};
      return _calParse(resp);
    } catch (e) {
      return {'error': 'Calendar request failed: $e'};
    }
  }

  Map<String, dynamic> _calParse(http.Response resp) {
    final parsed = resp.body.isNotEmpty
        ? jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>
        : <String, dynamic>{};
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      return {'data': parsed};
    }
    final msg = (parsed['error'] as Map?)?.containsKey('message') == true
        ? parsed['error']['message']
        : resp.reasonPhrase;
    return {'error': 'Calendar API ${resp.statusCode}: $msg'};
  }

  Future<Map<String, dynamic>> _calRefreshRetry(
    Uri uri,
    String method,
    Map<String, dynamic>? body,
  ) async {
    final ds = ServerDataSourcesService.instance;
    final r = await _refreshGoogleToken(ds);
    if (r['error'] != null) {
      return {
        'error': 'Calendar token expired and refresh failed: ${r['error']}',
      };
    }
    final newToken = r['accessToken'] as String;
    _calToken = newToken;
    switch (method) {
      case 'GET':
        return _calGet(uri, newToken, retried: true);
      case 'POST':
        return _calPost(uri, newToken, body!, retried: true);
      case 'PATCH':
        return _calPatch(uri, newToken, body!, retried: true);
      case 'DELETE':
        return _calDelete(uri, newToken, retried: true);
      default:
        return {'error': 'Unknown method $method'};
    }
  }
}

// ═══════════════════════════════════════════════════════════════
// Google Drive
// ═══════════════════════════════════════════════════════════════

class ServerGoogleDriveMcp extends ServerInternalMcp {
  static const _driveBase = 'https://www.googleapis.com/drive/v3';
  String _folderPath = '';

  static const _tools = <MCPTool>[
    MCPTool(
      name: 'search_drive',
      description: 'Search for files in Google Drive by name or content.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description':
                'Search query (file name contains, or fullText contains).',
          },
          'folderPath': {
            'type': 'string',
            'description':
                'Optional folder path to restrict search (e.g. "Reports/2026").',
          },
          'maxResults': {
            'type': 'integer',
            'default': 20,
            'description': 'Max results (default 20, max 100).',
          },
        },
        'required': ['query'],
      },
    ),
    MCPTool(
      name: 'list_drive_folder',
      description: 'List files in a specific Google Drive folder.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'folderPath': {
            'type': 'string',
            'description': 'Folder path or empty for root.',
          },
          'maxResults': {'type': 'integer', 'default': 50},
        },
        'required': [],
      },
    ),
    MCPTool(
      name: 'read_drive_file',
      description:
          'Read the text content of a file from Google Drive. Supports Google Docs, Sheets, plain text, CSV.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'fileId': {
            'type': 'string',
            'description': 'The Google Drive file ID.',
          },
        },
        'required': ['fileId'],
      },
    ),
    MCPTool(
      name: 'delete_drive_file',
      description:
          'Move a file to the Google Drive trash (or permanently delete when permanently=true).',
      inputSchema: {
        'type': 'object',
        'properties': {
          'fileId': {'type': 'string'},
          'permanently': {'type': 'boolean', 'default': false},
        },
        'required': ['fileId'],
      },
    ),
    MCPTool(
      name: 'upload_to_drive',
      description:
          'Create or overwrite a plain-text or Markdown file in Google Drive.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'fileName': {
            'type': 'string',
            'description': 'Name of the file to create or overwrite.',
          },
          'content': {
            'type': 'string',
            'description': 'Text content to write.',
          },
          'folderPath': {
            'type': 'string',
            'description': 'Optional Drive folder path. Empty = root.',
          },
          'mimeType': {'type': 'string', 'default': 'text/plain'},
        },
        'required': ['fileName', 'content'],
      },
    ),
  ];

  @override
  List<MCPTool> get tools => _tools;

  Future<void> initialize(Map<String, dynamic> initParams) async {
    _folderPath = (initParams['folderPath'] as String? ?? '').trim();
    log.info('[Drive MCP] Initialized folderPath="$_folderPath"');
  }

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> args,
  ) async {
    switch (name) {
      case 'search_drive':
        return _searchDrive(args);
      case 'list_drive_folder':
        return _listFolder(args);
      case 'read_drive_file':
        return _readFile(args);
      case 'delete_drive_file':
        return _deleteFile(args);
      case 'upload_to_drive':
        return _uploadFile(args);
      default:
        return {'error': 'Unknown tool: $name'};
    }
  }

  Future<Map<String, dynamic>> _searchDrive(Map<String, dynamic> args) async {
    final query = (args['query'] as String?)?.trim();
    if (query == null || query.isEmpty) {
      return {'error': 'Parameter "query" is required.'};
    }
    final maxResults = ((args['maxResults'] as int?) ?? 20).clamp(1, 100);
    final folderOverride =
        (args['folderPath'] as String?)?.trim() ?? _folderPath;

    final tr = await _resolveGoogleToken();
    if (tr['error'] != null) return tr;
    final token = tr['accessToken'] as String;

    final folderId = await _driveResolveFolderId(token, folderOverride);
    if (folderId is Map<String, dynamic>) return folderId;

    final qEsc = query.replaceAll("'", r"\'");
    final clauses = <String>[
      'trashed=false',
      "(name contains '$qEsc' or fullText contains '$qEsc')",
    ];
    if (folderId != null) clauses.add("'$folderId' in parents");

    final r = await _driveGet('/files', token, {
      'q': clauses.join(' and '),
      'pageSize': '$maxResults',
      'orderBy': 'modifiedTime desc',
      'fields': 'files(id,name,mimeType,size,modifiedTime,webViewLink)',
    });
    if (r['error'] != null) return r;
    final files = ((r['data'] as Map)['files'] as List? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(_driveMeta)
        .toList();
    return {'query': query, 'returned': files.length, 'files': files};
  }

  Future<Map<String, dynamic>> _listFolder(Map<String, dynamic> args) async {
    final folderOverride =
        (args['folderPath'] as String?)?.trim() ?? _folderPath;
    final maxResults = ((args['maxResults'] as int?) ?? 50).clamp(1, 500);

    final tr = await _resolveGoogleToken();
    if (tr['error'] != null) return tr;
    final token = tr['accessToken'] as String;

    final folderId = await _driveResolveFolderId(token, folderOverride);
    if (folderId is Map<String, dynamic>) return folderId;
    final parentId = (folderId as String?) ?? 'root';

    final r = await _driveGet('/files', token, {
      'q': "'$parentId' in parents and trashed=false",
      'pageSize': '$maxResults',
      'orderBy': 'folder,name',
      'fields': 'files(id,name,mimeType,size,modifiedTime,webViewLink)',
    });
    if (r['error'] != null) return r;
    final files = ((r['data'] as Map)['files'] as List? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(_driveMeta)
        .toList();
    return {
      'folderPath': folderOverride.isEmpty ? '/' : folderOverride,
      'returned': files.length,
      'files': files,
    };
  }

  Future<Map<String, dynamic>> _readFile(Map<String, dynamic> args) async {
    final fileId = (args['fileId'] as String?)?.trim();
    if (fileId == null || fileId.isEmpty) {
      return {'error': 'Parameter "fileId" is required.'};
    }

    final tr = await _resolveGoogleToken();
    if (tr['error'] != null) return tr;
    final token = tr['accessToken'] as String;

    final metaR = await _driveGet('/files/$fileId', token, {
      'fields': 'id,name,mimeType,size,modifiedTime,webViewLink',
    });
    if (metaR['error'] != null) return metaR;
    final meta = metaR['data'] as Map<String, dynamic>;
    final mimeType = (meta['mimeType'] ?? '').toString();

    String content = '';
    if (mimeType.startsWith('application/vnd.google-apps')) {
      final exportMime = mimeType == 'application/vnd.google-apps.spreadsheet'
          ? 'text/csv'
          : 'text/plain';
      content = await _driveExport(token, fileId, exportMime);
    } else {
      content = await _driveDownloadText(token, fileId);
    }

    if (content.trim().isEmpty) {
      return {
        ..._driveMeta(meta),
        'error': 'Could not extract readable text from this file type.',
      };
    }

    final normalized = content.replaceAll('\r\n', '\n').trim();
    return {
      ..._driveMeta(meta),
      'content': normalized,
      'snippet': normalized.length > 800
          ? '${normalized.substring(0, 800)}…'
          : normalized,
    };
  }

  Future<Map<String, dynamic>> _deleteFile(Map<String, dynamic> args) async {
    final fileId = (args['fileId'] as String?)?.trim();
    if (fileId == null || fileId.isEmpty) {
      return {'error': 'Parameter "fileId" is required.'};
    }
    final permanently = args['permanently'] as bool? ?? false;

    final tr = await _resolveGoogleToken();
    if (tr['error'] != null) return tr;
    final token = tr['accessToken'] as String;

    http.Response resp;
    if (permanently) {
      resp = await http.delete(
        Uri.parse('$_driveBase/files/$fileId?supportsAllDrives=true'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (resp.statusCode == 204) {
        return {
          'success': true,
          'action': 'deleted_permanently',
          'fileId': fileId,
        };
      }
    } else {
      resp = await http.patch(
        Uri.parse('$_driveBase/files/$fileId?supportsAllDrives=true'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'trashed': true}),
      );
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        return {'success': true, 'action': 'trashed', 'fileId': fileId};
      }
    }
    return {
      'error':
          'Drive delete failed (${resp.statusCode}): ${resp.body.length > 200 ? resp.body.substring(0, 200) : resp.body}',
    };
  }

  Future<Map<String, dynamic>> _uploadFile(Map<String, dynamic> args) async {
    final fileName = (args['fileName'] as String?)?.trim();
    if (fileName == null || fileName.isEmpty) {
      return {'error': 'Parameter "fileName" is required.'};
    }
    final content = (args['content'] as String?) ?? '';
    final mimeType =
        ((args['mimeType'] as String?)?.trim().isNotEmpty == true
            ? args['mimeType'] as String
            : null) ??
        'text/plain';
    final folderOverride =
        (args['folderPath'] as String?)?.trim() ?? _folderPath;

    final tr = await _resolveGoogleToken();
    if (tr['error'] != null) return tr;
    final token = tr['accessToken'] as String;

    String? folderId;
    if (folderOverride.isNotEmpty) {
      folderId = await _driveResolveOrCreateFolder(token, folderOverride);
    }

    final existingId = await _driveFindFileByName(
      token,
      fileName,
      parentId: folderId,
    );
    if (existingId != null) {
      final patchUri = Uri.parse(
        'https://www.googleapis.com/upload/drive/v3/files/$existingId?uploadType=media',
      );
      final r = await http.patch(
        patchUri,
        headers: {'Authorization': 'Bearer $token', 'Content-Type': mimeType},
        body: utf8.encode(content),
      );
      if (r.statusCode < 200 || r.statusCode >= 300) {
        return {'error': 'Upload failed (${r.statusCode}): ${r.body}'};
      }
      final meta = jsonDecode(r.body) as Map<String, dynamic>;
      return {
        'success': true,
        'action': 'updated',
        'fileId': meta['id'],
        'fileName': fileName,
      };
    } else {
      final driveMetadata = <String, dynamic>{
        'name': fileName,
        'mimeType': mimeType,
        if (folderId != null) 'parents': [folderId],
      };
      const boundary = '-------tealkit_multipart';
      final bodyBuf = StringBuffer()
        ..write('--$boundary\r\n')
        ..write('Content-Type: application/json; charset=UTF-8\r\n\r\n')
        ..write(jsonEncode(driveMetadata))
        ..write('\r\n--$boundary\r\n')
        ..write('Content-Type: $mimeType\r\n\r\n')
        ..write(content)
        ..write('\r\n--$boundary--');
      final uploadUri = Uri.parse(
        'https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart',
      );
      final r = await http.post(
        uploadUri,
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'multipart/related; boundary=$boundary',
        },
        body: utf8.encode(bodyBuf.toString()),
      );
      if (r.statusCode < 200 || r.statusCode >= 300) {
        return {'error': 'Upload failed (${r.statusCode}): ${r.body}'};
      }
      final meta = jsonDecode(r.body) as Map<String, dynamic>;
      return {
        'success': true,
        'action': 'created',
        'fileId': meta['id'],
        'fileName': fileName,
      };
    }
  }

  // ─── Drive helpers ────────────────────────────────────────────

  Map<String, dynamic> _driveMeta(Map<String, dynamic> f) => {
    'id': f['id'],
    'name': f['name'],
    'mimeType': f['mimeType'],
    'size': f['size'],
    'modifiedTime': f['modifiedTime'],
    'webViewLink': f['webViewLink'],
    'isFolder':
        (f['mimeType']?.toString() ?? '') ==
        'application/vnd.google-apps.folder',
  };

  Future<Map<String, dynamic>> _driveGet(
    String path,
    String token, [
    Map<String, String>? qp,
  ]) async {
    try {
      final uri = Uri.parse('$_driveBase$path').replace(queryParameters: qp);
      var resp = await http.get(
        uri,
        headers: {
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
        },
      );
      if (resp.statusCode == 401) {
        final ds = ServerDataSourcesService.instance;
        final r = await _refreshGoogleToken(ds);
        if (r['error'] == null) {
          resp = await http.get(
            uri,
            headers: {
              'Authorization': 'Bearer ${r["accessToken"]}',
              'Accept': 'application/json',
            },
          );
        }
      }
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final parsed = resp.body.isNotEmpty
            ? jsonDecode(utf8.decode(resp.bodyBytes))
            : <String, dynamic>{};
        return {
          'data': parsed is Map<String, dynamic> ? parsed : <String, dynamic>{},
        };
      }
      return {'error': 'Drive API ${resp.statusCode}: ${resp.reasonPhrase}'};
    } catch (e) {
      return {'error': 'Drive request failed: $e'};
    }
  }

  Future<dynamic> _driveResolveFolderId(
    String token,
    String? folderPath,
  ) async {
    final raw = (folderPath ?? '').trim();
    if (raw.isEmpty || raw == '/' || raw.toLowerCase() == 'root') return null;
    final parts = raw
        .split(RegExp(r'[\\/]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    String current = 'root';
    for (final seg in parts) {
      final esc = seg.replaceAll("'", r"\'");
      final r = await _driveGet('/files', token, {
        'q':
            "name='$esc' and mimeType='application/vnd.google-apps.folder' and '$current' in parents and trashed=false",
        'pageSize': '5',
        'fields': 'files(id,name)',
      });
      if (r['error'] != null) return r;
      final files = (r['data'] as Map)['files'] as List? ?? [];
      if (files.isEmpty) {
        return {'error': 'Folder not found: "$seg" in path "$raw".'};
      }
      current = (files.first as Map)['id']?.toString() ?? '';
    }
    return current;
  }

  Future<String?> _driveResolveOrCreateFolder(String token, String path) async {
    final parts = path
        .split('/')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    String? parentId;
    for (final part in parts) {
      parentId = await _driveFindOrCreateFolder(
        token,
        part,
        parentId: parentId,
      );
      if (parentId == null) return null;
    }
    return parentId;
  }

  Future<String?> _driveFindOrCreateFolder(
    String token,
    String name, {
    String? parentId,
  }) async {
    final esc = name.replaceAll("'", r"\'");
    var q =
        "name='$esc' and mimeType='application/vnd.google-apps.folder' and trashed=false";
    if (parentId != null) q += " and '$parentId' in parents";
    final r = await _driveGet('/files', token, {
      'q': q,
      'pageSize': '1',
      'fields': 'files(id)',
    });
    if (r['error'] == null) {
      final files = (r['data'] as Map)['files'] as List? ?? [];
      if (files.isNotEmpty) return (files.first as Map)['id']?.toString();
    }
    final createUri = Uri.parse('$_driveBase/files');
    final body = <String, dynamic>{
      'name': name,
      'mimeType': 'application/vnd.google-apps.folder',
      if (parentId != null) 'parents': [parentId],
    };
    final resp = await http.post(
      createUri,
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(body),
    );
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      return (jsonDecode(resp.body) as Map)['id']?.toString();
    }
    return null;
  }

  Future<String?> _driveFindFileByName(
    String token,
    String name, {
    String? parentId,
  }) async {
    final esc = name.replaceAll("'", r"\'");
    var q = "name='$esc' and trashed=false";
    if (parentId != null) q += " and '$parentId' in parents";
    final r = await _driveGet('/files', token, {
      'q': q,
      'pageSize': '1',
      'fields': 'files(id)',
    });
    if (r['error'] != null) return null;
    final files = (r['data'] as Map)['files'] as List? ?? [];
    return files.isNotEmpty ? (files.first as Map)['id']?.toString() : null;
  }

  Future<String> _driveExport(
    String token,
    String fileId,
    String exportMime,
  ) async {
    try {
      final uri = Uri.parse(
        '$_driveBase/files/$fileId/export',
      ).replace(queryParameters: {'mimeType': exportMime});
      final resp = await http.get(
        uri,
        headers: {'Authorization': 'Bearer $token'},
      );
      if (resp.statusCode < 200 || resp.statusCode >= 300) return '';
      return utf8.decode(resp.bodyBytes, allowMalformed: true);
    } catch (_) {
      return '';
    }
  }

  Future<String> _driveDownloadText(String token, String fileId) async {
    try {
      final uri = Uri.parse(
        '$_driveBase/files/$fileId',
      ).replace(queryParameters: {'alt': 'media'});
      final resp = await http.get(
        uri,
        headers: {'Authorization': 'Bearer $token'},
      );
      if (resp.statusCode < 200 || resp.statusCode >= 300) return '';
      final text = utf8.decode(resp.bodyBytes, allowMalformed: true);
      return _looksLikeBinary(text) ? '' : text;
    } catch (_) {
      return '';
    }
  }

  bool _looksLikeBinary(String text) {
    if (text.isEmpty) return false;
    final sample = text.length > 1000 ? text.substring(0, 1000) : text;
    var ctrl = 0;
    for (final u in sample.codeUnits) {
      if (u == 9 || u == 10 || u == 13) continue;
      if (u < 32) ctrl++;
    }
    return ctrl > sample.length * 0.05;
  }
}

// ═══════════════════════════════════════════════════════════════
// Not-available stubs (Flutter-only tools)
// ═══════════════════════════════════════════════════════════════

String _stubNotAvailable(String toolType, String reason) =>
    '$toolType is not available in server mode. $reason '
    'Run this task inside the TealKit app to use this capability.';

class ServerDocumentMcp extends ServerInternalMcp {
  List<String> _rootPaths = [];
  List<String> _fileTypes = [];

  static const _tools = <MCPTool>[
    MCPTool(
      name: 'list_documents',
      description:
          'List all indexed documents. Optionally filter by file type.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'fileType': {
            'type': 'string',
            'description':
                'Filter by file extension (e.g. "docx", "pdf"). Omit for all types.',
          },
          'limit': {
            'type': 'integer',
            'description':
                'Maximum number of documents to return (default: 100).',
            'default': 100,
          },
        },
        'required': <String>[],
      },
    ),
    MCPTool(
      name: 'search_documents',
      description:
          'Search across indexed documents with keyword, semantic, or hybrid ranking.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'description': 'Search query text.'},
          'fileType': {
            'type': 'string',
            'description': 'Filter by file extension. Omit for all.',
          },
          'limit': {
            'type': 'integer',
            'description': 'Maximum results (default: 20).',
            'default': 20,
          },
          'searchMode': {
            'type': 'string',
            'enum': ['keyword', 'semantic', 'hybrid'],
            'description': 'Search mode (default: hybrid).',
            'default': 'hybrid',
          },
        },
        'required': ['query'],
      },
    ),
    MCPTool(
      name: 'get_document_content',
      description: 'Get the full text content of a specific indexed document.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'filePath': {
            'type': 'string',
            'description': 'Full path to the document, or just the file name.',
          },
        },
        'required': ['filePath'],
      },
    ),
    MCPTool(
      name: 'reindex',
      description:
          'Re-scan configured root directories and rebuild the document index.',
      inputSchema: {
        'type': 'object',
        'properties': <String, Object>{},
        'required': <String>[],
      },
    ),
    MCPTool(
      name: 'purge_stale_index',
      description:
          'Delete indexed document rows that no longer belong to currently configured root paths.',
      inputSchema: {
        'type': 'object',
        'properties': <String, Object>{},
        'required': <String>[],
      },
    ),
  ];

  @override
  List<MCPTool> get tools => _tools;

  Future<void> initialize(Map<String, dynamic> initParams) async {
    final rawPath = initParams['rootPath'] as String? ?? '';
    _rootPaths = rawPath
        .split(';')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final rawTypes = initParams['fileTypes'] as String? ?? '';
    final requestedTypes = rawTypes
        .split(',')
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toList();
    _fileTypes = requestedTypes.isNotEmpty
        ? requestedTypes
        : ['pdf', 'md', 'docx'];
    log.info(
      '[ServerDocumentMcp] Initialized rootPaths=${_rootPaths.join(";")} fileTypes=${_fileTypes.join(",")}',
    );
  }

  String _esc(String s) => s.replaceAll("'", "''");

  String _rootPathInClause() {
    if (_rootPaths.isEmpty) return '1=1';
    final escaped = _rootPaths.map((p) => "'${_esc(p)}'").join(', ');
    return 'root_path IN ($escaped)';
  }

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> args,
  ) async {
    switch (name) {
      case 'list_documents':
        return _listDocuments(args);
      case 'search_documents':
        return _searchDocuments(args);
      case 'get_document_content':
        return _getDocumentContent(args);
      case 'reindex':
        return _reindex();
      case 'purge_stale_index':
        return _purgeStaleIndex();
      default:
        return {'error': 'Unknown tool: $name'};
    }
  }

  Future<Map<String, dynamic>> _listDocuments(Map<String, dynamic> args) async {
    final fileType = (args['fileType'] as String?)?.trim();
    final limit = ((args['limit'] as int?) ?? 100).clamp(1, 1000);
    final db = ServerDuckDbService();
    final where = StringBuffer('WHERE ${_rootPathInClause()}');
    if (fileType != null && fileType.isNotEmpty) {
      where.write(" AND file_type = '${_esc(fileType.toLowerCase())}'");
    }
    try {
      final rows = await db.query('''
        SELECT file_path, file_name, file_type, file_size, last_modified,
               LENGTH(COALESCE(content_text, '')) AS content_length
        FROM document_index
        $where
        ORDER BY file_name ASC
        LIMIT $limit
      ''');
      final countRows = await db.query(
        'SELECT COUNT(*) FROM document_index WHERE ${_rootPathInClause()}',
      );
      final totalCount = countRows.isNotEmpty
          ? int.tryParse(countRows.first.first.toString()) ?? 0
          : 0;
      return {
        'rootPaths': _rootPaths,
        'totalDocuments': totalCount,
        'returned': rows.length,
        'documents': rows
            .map(
              (r) => {
                'filePath': r[0],
                'fileName': r[1],
                'fileType': r[2],
                'fileSize': r[3],
                'lastModified': r[4],
                'contentLength': r[5],
              },
            )
            .toList(),
      };
    } catch (e) {
      log.warning('[ServerDocumentMcp] list_documents error: $e');
      return {'error': 'Failed to list documents: $e'};
    }
  }

  Future<Map<String, dynamic>> _searchDocuments(
    Map<String, dynamic> args,
  ) async {
    final query = (args['query'] as String?)?.trim();
    if (query == null || query.isEmpty) {
      return {'error': 'Parameter "query" is required.'};
    }
    final fileType = (args['fileType'] as String?)?.trim();
    final limit = ((args['limit'] as int?) ?? 20).clamp(1, 200);
    final searchMode = (args['searchMode'] as String? ?? 'hybrid')
        .toLowerCase();
    final db = ServerDuckDbService();
    final words = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    final conditions = StringBuffer('WHERE ${_rootPathInClause()}');
    conditions.write(" AND content_text IS NOT NULL AND content_text != ''");
    if (fileType != null && fileType.isNotEmpty) {
      conditions.write(" AND file_type = '${_esc(fileType.toLowerCase())}'");
    }
    if (words.isNotEmpty) {
      final likeConditions = words
          .take(3)
          .map((w) => "LOWER(content_text) LIKE '%${_esc(w)}%'")
          .join(' OR ');
      conditions.write(' AND ($likeConditions)');
    }
    try {
      final rows = await db.query('''
        SELECT file_path, file_name, file_type, file_size,
               SUBSTRING(content_text, 1, 81920) AS content_text,
               embedding_json, last_modified
        FROM document_index
        $conditions
        LIMIT 200
      ''');
      if (rows.isEmpty) {
        return {
          'summary':
              'No documents found matching "$query". The index may be empty or files have not been indexed yet. Try calling reindex first.',
          'query': query,
          'searchMode': searchMode,
          'totalResults': 0,
          'results': <dynamic>[],
        };
      }
      final queryEmbedding = SemanticEmbedding.buildEmbedding(query);
      final scored = <Map<String, dynamic>>[];
      for (final row in rows) {
        final content = row[4]?.toString() ?? '';
        if (content.isEmpty) continue;
        final matchCount = _docCountMatches(content, words);
        final keywordScore = SemanticEmbedding.keywordOverlapScore(
          query,
          content,
        );
        final docEmbedding = SemanticEmbedding.fromJson(row[5]?.toString());
        final semanticScore = SemanticEmbedding.cosineSimilarity(
          queryEmbedding,
          docEmbedding,
        );
        final relevanceScore = switch (searchMode) {
          'keyword' => keywordScore + (matchCount * 0.02),
          'semantic' => semanticScore,
          _ =>
            (0.65 * semanticScore) +
                (0.30 * keywordScore) +
                (0.05 * matchCount),
        };
        if (searchMode == 'keyword' && matchCount == 0) continue;
        if (matchCount == 0 && relevanceScore < 0.35) continue;
        scored.add({
          'filePath': row[0],
          'fileName': row[1],
          'fileType': row[2],
          'fileSize': row[3],
          'lastModified': row[6],
          'matchCount': matchCount,
          'keywordScore': keywordScore,
          'semanticScore': semanticScore,
          'relevanceScore': relevanceScore,
          'excerpt': _docBuildExcerpt(content, words),
        });
      }
      scored.sort(
        (a, b) =>
            (b['relevanceScore'] as num).compareTo(a['relevanceScore'] as num),
      );
      final limited = scored.take(limit).toList();
      final fileLines = limited
          .asMap()
          .entries
          .map(
            (e) =>
                '${e.key + 1}. ${e.value['fileName']}  →  ${e.value['filePath']}',
          )
          .join('\n');
      return {
        'summary':
            'Found ${limited.length} file(s) matching "$query":\n$fileLines\n\nUse get_document_content with the filePath to read the full content.',
        'totalResults': limited.length,
        'results': limited
            .map(
              (r) => {
                'fileName': r['fileName'],
                'filePath': r['filePath'],
                'fileType': r['fileType'],
              },
            )
            .toList(),
      };
    } catch (e) {
      log.warning('[ServerDocumentMcp] search_documents error: $e');
      return {'error': 'Search failed: $e'};
    }
  }

  Future<Map<String, dynamic>> _getDocumentContent(
    Map<String, dynamic> args,
  ) async {
    final filePath = (args['filePath'] as String?)?.trim();
    if (filePath == null || filePath.isEmpty) {
      return {'error': 'Parameter "filePath" is required.'};
    }
    final db = ServerDuckDbService();
    try {
      final rows = await db.query('''
        SELECT file_path, file_name, file_type, file_size, content_text, last_modified
        FROM document_index
        WHERE file_path = '${_esc(filePath)}'
           OR file_name = '${_esc(filePath)}'
        LIMIT 1
      ''');
      if (rows.isEmpty) {
        return {'error': 'Document not found in index: $filePath'};
      }
      final row = rows.first;
      return {
        'filePath': row[0],
        'fileName': row[1],
        'fileType': row[2],
        'fileSize': row[3],
        'content': row[4],
        'lastModified': row[5],
      };
    } catch (e) {
      log.warning('[ServerDocumentMcp] get_document_content error: $e');
      return {'error': 'Failed to get document content: $e'};
    }
  }

  Future<Map<String, dynamic>> _reindex() async {
    if (_rootPaths.isEmpty) {
      return {
        'error':
            "No rootPath configured for this task. Configure rootPath in the task's document tool settings.",
      };
    }
    final result = ServerIndexingService.instance.startDocumentIndex(
      rootPaths: _rootPaths.join(';'),
      fileTypes: _fileTypes.join(','),
    );
    log.info('[ServerDocumentMcp] reindex triggered: $result');
    return result;
  }

  Future<Map<String, dynamic>> _purgeStaleIndex() async {
    final result = await ServerIndexingService.instance
        .purgeStaleDocumentIndex();
    log.info('[ServerDocumentMcp] purge_stale_index result: $result');
    return result;
  }

  int _docCountMatches(String content, List<String> words) {
    final lower = content.toLowerCase();
    var count = 0;
    for (final word in words) {
      int pos = 0;
      while (true) {
        pos = lower.indexOf(word, pos);
        if (pos < 0) break;
        count++;
        pos += word.length;
      }
    }
    return count;
  }

  String _docBuildExcerpt(
    String content,
    List<String> words, [
    int maxLen = 220,
  ]) {
    if (words.isEmpty) {
      return content.substring(0, content.length.clamp(0, maxLen));
    }
    final lower = content.toLowerCase();
    int bestPos = -1;
    for (final word in words) {
      final pos = lower.indexOf(word);
      if (pos >= 0 && (bestPos < 0 || pos < bestPos)) bestPos = pos;
    }
    if (bestPos < 0) {
      return content.substring(0, content.length.clamp(0, maxLen));
    }
    final start = (bestPos - 60).clamp(0, content.length);
    final end = (start + maxLen).clamp(0, content.length);
    final excerpt = content.substring(start, end).replaceAll('\n', ' ').trim();
    return start > 0 ? '…$excerpt' : excerpt;
  }
}

class ServerPdfStub extends ServerInternalMcp {
  static const _tools = <MCPTool>[
    MCPTool(
      name: 'create_pdf',
      description: 'Create a PDF document from markdown or HTML content.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'content': {'type': 'string'},
        },
        'required': ['content'],
      },
    ),
  ];

  @override
  List<MCPTool> get tools => _tools;

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> args,
  ) async => {
    'isError': true,
    'content': [
      {
        'type': 'text',
        'text': _stubNotAvailable(
          'PDF creation',
          'It requires Flutter widget rendering (dart:ui).',
        ),
      },
    ],
  };
}

class ServerJsBridgeMcp extends ServerInternalMcp {
  final List<MCPTool> _dynamicTools = <MCPTool>[];
  final Map<String, String> _toolNameToId = <String, String>{};
  bool _allowInactive = false;
  int _defaultTimeoutMs = 8000;

  @override
  List<MCPTool> get tools => <MCPTool>[
    const MCPTool(
      name: 'list_js_tools',
      description:
          'List saved JavaScript bridge tools currently available for execution.',
      inputSchema: {
        'type': 'object',
        'properties': <String, dynamic>{},
        'required': <String>[],
      },
    ),
    const MCPTool(
      name: 'run_js_tool',
      description: 'Run a JavaScript bridge tool by toolId or toolName.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'toolId': {'type': 'string', 'description': 'Saved JS tool id.'},
          'toolName': {'type': 'string', 'description': 'Saved JS tool name.'},
          'args': {
            'type': 'object',
            'description':
                'Arguments forwarded to generatedTool.execute(args).',
          },
          'timeoutMs': {
            'type': 'integer',
            'description':
                'Execution timeout in milliseconds (default 8000, max 15000).',
          },
        },
        'required': <String>[],
      },
    ),
    ..._dynamicTools,
  ];

  Future<void> initialize(Map<String, dynamic> initParams) async {
    _allowInactive = initParams['allowInactive'] as bool? ?? false;
    _defaultTimeoutMs = ((initParams['timeoutMs'] as int?) ?? 8000).clamp(
      250,
      15000,
    );
    await _rebuildDynamicTools();
  }

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> args,
  ) async {
    switch (name) {
      case 'list_js_tools':
        return _listTools();
      case 'run_js_tool':
        return _runByExplicitCall(args);
      default:
        final toolId = _toolNameToId[name];
        if (toolId == null) {
          return {'error': 'Unknown tool: $name'};
        }
        final timeoutMs = (args['timeoutMs'] as int? ?? _defaultTimeoutMs)
            .clamp(250, 15000);
        final runArgs = Map<String, dynamic>.from(args)..remove('timeoutMs');
        return _runById(toolId, runArgs, timeoutMs);
    }
  }

  Future<Map<String, dynamic>> _listTools() async {
    final rows = await ServerDuckDbService().getAllJsTools(
      activeOnly: !_allowInactive,
    );
    await _rebuildDynamicTools();
    return {
      'count': rows.length,
      'tools': rows
          .map(
            (t) => {
              'id': t['id'],
              'name': t['name'],
              'description': t['description'],
              'isActive': t['is_active'] as bool? ?? true,
              'inputSchema': t['input_schema'] ?? <String, dynamic>{},
              'updatedAt': t['updated_at'],
            },
          )
          .toList(),
    };
  }

  Future<void> _rebuildDynamicTools() async {
    _dynamicTools.clear();
    _toolNameToId.clear();
    final usedNames = <String>{'list_js_tools', 'run_js_tool'};
    final rows = await ServerDuckDbService().getAllJsTools(
      activeOnly: !_allowInactive,
    );
    for (final row in rows) {
      final id = row['id']?.toString() ?? '';
      final displayName = row['name']?.toString() ?? '';
      if (id.isEmpty || displayName.isEmpty) continue;
      var dynamicName = 'js_${_sanitizeName(displayName)}';
      if (dynamicName == 'js_' || dynamicName == 'js') {
        dynamicName = 'js_tool';
      }
      if (usedNames.contains(dynamicName)) {
        dynamicName =
            '${dynamicName}_${id.substring(0, math.min(6, id.length))}';
      }
      usedNames.add(dynamicName);
      _toolNameToId[dynamicName] = id;
      _dynamicTools.add(
        MCPTool(
          name: dynamicName,
          description:
              (row['description']?.toString().trim().isNotEmpty ?? false)
              ? row['description'].toString()
              : 'User-defined JS tool: $displayName',
          inputSchema:
              (row['input_schema'] as Map<String, dynamic>?) ??
              const <String, dynamic>{
                'type': 'object',
                'properties': <String, dynamic>{},
              },
        ),
      );
    }
  }

  String _sanitizeName(String input) {
    final lower = input.trim().toLowerCase();
    return lower
        .replaceAll(RegExp(r'[^a-z0-9_]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
  }

  Future<Map<String, dynamic>> _runByExplicitCall(
    Map<String, dynamic> arguments,
  ) async {
    final toolId = (arguments['toolId'] as String?)?.trim();
    final toolName = (arguments['toolName'] as String?)?.trim();
    final timeoutMs = ((arguments['timeoutMs'] as int?) ?? _defaultTimeoutMs)
        .clamp(250, 15000);
    final args = (arguments['args'] is Map)
        ? (arguments['args'] as Map).cast<String, dynamic>()
        : (Map<String, dynamic>.from(arguments)..removeWhere(
            (k, _) => k == 'toolId' || k == 'toolName' || k == 'timeoutMs',
          ));

    if (toolId != null && toolId.isNotEmpty) {
      return _runById(toolId, args, timeoutMs);
    }

    if (toolName != null && toolName.isNotEmpty) {
      final rows = await ServerDuckDbService().getAllJsTools(
        activeOnly: !_allowInactive,
      );
      final lower = toolName.toLowerCase();
      final row = rows.firstWhere(
        (t) =>
            (t['name']?.toString().toLowerCase() ?? '') == lower ||
            (_toolNameToId[toolName] != null &&
                _toolNameToId[toolName] == t['id']),
        orElse: () => <String, dynamic>{},
      );
      final foundId = row['id']?.toString() ?? _toolNameToId[toolName] ?? '';
      if (foundId.isNotEmpty) {
        return _runById(foundId, args, timeoutMs);
      }
    }

    return {
      'error': 'Tool not found. Provide toolId or toolName from list_js_tools.',
    };
  }

  Future<Map<String, dynamic>> _runById(
    String toolId,
    Map<String, dynamic> args,
    int timeoutMs,
  ) async {
    final rows = await ServerDuckDbService().getAllJsTools(activeOnly: false);
    final row = rows.where((t) => t['id']?.toString() == toolId).firstOrNull;
    if (row == null) {
      return {'error': 'Tool not found: $toolId'};
    }
    final isActive = row['is_active'] as bool? ?? true;
    if (!isActive) {
      return {'error': 'Tool is disabled: ${row['name'] ?? toolId}'};
    }

    final dataDir = ServerDuckDbService().dataDir;
    final scriptsDir = Directory('$dataDir/js_scripts');
    await scriptsDir.create(recursive: true);

    final codePath = '${scriptsDir.path}/$toolId.js';
    final shimPath = '${scriptsDir.path}/.shim_$toolId.js';
    final code = row['js_code']?.toString() ?? '';
    await File(codePath).writeAsString(code, flush: true);

    final shim = '''
const fs = require('fs');
const vm = require('vm');

const args = JSON.parse(process.env.TOOL_ARGS_JSON || '{}');
const codePath = process.env.TOOL_CODE_PATH;
const code = fs.readFileSync(codePath, 'utf8');
const sandbox = { generatedTool: undefined, console };
vm.createContext(sandbox);
vm.runInContext(code, sandbox);

const tool = sandbox.generatedTool;
if (!tool || typeof tool.execute !== 'function') {
  process.stderr.write(JSON.stringify({error: 'generatedTool.execute is not defined'}));
  process.exit(1);
}

Promise.resolve(tool.execute(args))
  .then((result) => {
    process.stdout.write(JSON.stringify({result}));
    process.exit(0);
  })
  .catch((error) => {
    process.stderr.write(JSON.stringify({error: error && error.message ? error.message : String(error)}));
    process.exit(1);
  });
''';

    await File(shimPath).writeAsString(shim, flush: true);
    try {
      final proc = await Process.start(
        'node',
        <String>[shimPath],
        environment: <String, String>{
          ...Platform.environment,
          'TOOL_ARGS_JSON': jsonEncode(args),
          'TOOL_CODE_PATH': codePath,
        },
        runInShell: false,
      );

      final stdoutFuture = proc.stdout.transform(utf8.decoder).join();
      final stderrFuture = proc.stderr.transform(utf8.decoder).join();
      final exitCode = await proc.exitCode.timeout(
        Duration(milliseconds: timeoutMs),
        onTimeout: () {
          proc.kill(ProcessSignal.sigkill);
          throw TimeoutException('JS tool timed out after ${timeoutMs}ms');
        },
      );
      final stdoutText = (await stdoutFuture).trim();
      final stderrText = (await stderrFuture).trim();

      if (exitCode != 0) {
        return {
          'success': false,
          'error': stderrText.isNotEmpty
              ? stderrText
              : 'JavaScript tool failed with exit code $exitCode',
          'toolId': toolId,
          'toolName': row['name'],
        };
      }

      final decoded = _decodeTrailingJson(stdoutText);
      if (decoded is! Map<String, dynamic>) {
        return {
          'success': false,
          'error': 'Failed to parse JS result JSON.',
          'stdout': stdoutText,
          'toolId': toolId,
          'toolName': row['name'],
        };
      }

      if (decoded['error'] != null) {
        return {
          'success': false,
          'error': decoded['error'],
          'toolId': toolId,
          'toolName': row['name'],
        };
      }

      return {
        'success': true,
        'toolId': toolId,
        'toolName': row['name'],
        'result': decoded['result'],
      };
    } on TimeoutException catch (e) {
      return {
        'success': false,
        'error': e.message ?? e.toString(),
        'toolId': toolId,
        'toolName': row['name'],
      };
    } catch (e) {
      return {
        'success': false,
        'error': e.toString(),
        'toolId': toolId,
        'toolName': row['name'],
      };
    } finally {
      final shimFile = File(shimPath);
      if (await shimFile.exists()) {
        await shimFile.delete();
      }
    }
  }
}

class ServerPsBridgeStub extends ServerInternalMcp {
  static const _tools = <MCPTool>[
    MCPTool(
      name: 'run_powershell',
      description: 'Execute PowerShell commands on the local Windows machine.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'script': {'type': 'string'},
        },
        'required': ['script'],
      },
    ),
  ];

  @override
  List<MCPTool> get tools => _tools;

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> args,
  ) async => {
    'isError': true,
    'content': [
      {
        'type': 'text',
        'text': _stubNotAvailable(
          'PowerShell bridge',
          'The server runs on Linux — use the SSH tool to run commands on a Windows host instead.',
        ),
      },
    ],
  };
}

class ServerPyBridgeMcp extends ServerInternalMcp {
  final List<MCPTool> _dynamicTools = <MCPTool>[];
  final Map<String, String> _toolNameToId = <String, String>{};
  bool _allowInactive = false;
  int _defaultTimeoutSeconds = 60;
  int _initTimeoutSeconds = 300;

  @override
  Future<void> refresh() async {
    await _rebuildDynamicTools();
  }

  @override
  List<MCPTool> get tools => <MCPTool>[
    const MCPTool(
      name: 'list_py_tools',
      description: 'List all saved Python tools available on this server.',
      inputSchema: {
        'type': 'object',
        'properties': <String, dynamic>{},
        'required': <String>[],
      },
    ),
    const MCPTool(
      name: 'init_py_tool',
      description:
          'Initialize (or re-initialize) the virtual environment for a Python tool.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'toolId': {
            'type': 'string',
            'description': 'Tool ID (from list_py_tools).',
          },
          'toolName': {
            'type': 'string',
            'description': 'Tool name (alternative to toolId).',
          },
          'timeoutSeconds': {
            'type': 'integer',
            'description': 'Initialization timeout in seconds (default 300).',
          },
        },
        'required': <String>[],
      },
    ),
    const MCPTool(
      name: 'run_py_tool',
      description:
          'Execute a Python tool by id or name, passing args as a JSON object.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'toolId': {'type': 'string', 'description': 'Tool ID.'},
          'toolName': {
            'type': 'string',
            'description': 'Tool name (alternative to toolId).',
          },
          'args': {
            'type': 'object',
            'description': 'Arguments forwarded to execute(args).',
          },
          'timeoutSeconds': {
            'type': 'integer',
            'description': 'Override timeout for this call.',
          },
        },
        'required': <String>[],
      },
    ),
    ..._dynamicTools,
  ];

  Future<void> initialize(Map<String, dynamic> initParams) async {
    _allowInactive = initParams['allowInactive'] as bool? ?? false;
    _defaultTimeoutSeconds = ((initParams['timeoutSeconds'] as int?) ?? 60)
        .clamp(5, 1800);
    _initTimeoutSeconds = ((initParams['initTimeoutSeconds'] as int?) ?? 300)
        .clamp(30, 1800);
    await _rebuildDynamicTools();
  }

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> args,
  ) async {
    switch (name) {
      case 'list_py_tools':
        return _listTools();
      case 'init_py_tool':
        return _initTool(args);
      case 'run_py_tool':
        return _runTool(args);
      default:
        final id = _toolNameToId[name];
        if (id == null) return {'error': 'Unknown tool: $name'};
        final overrideTimeout = args['timeoutSeconds'] as int?;
        final runArgs = Map<String, dynamic>.from(args)
          ..remove('timeoutSeconds');
        return _runById(id, runArgs, overrideTimeout);
    }
  }

  Future<Map<String, dynamic>> _listTools() async {
    final rows = await ServerDuckDbService().getAllPyTools();
    await _rebuildDynamicTools();
    final filtered = _allowInactive
        ? rows
        : rows.where((t) => t['is_active'] as bool? ?? true).toList();
    return {
      'count': filtered.length,
      'tools': filtered
          .map(
            (t) => {
              'id': t['id'],
              'name': t['name'],
              'description': t['description'],
              'venvReady': t['venv_ready'],
              'isActive': t['is_active'],
              'inputSchema': t['input_schema'],
            },
          )
          .toList(),
    };
  }

  Future<void> _rebuildDynamicTools() async {
    _dynamicTools.clear();
    _toolNameToId.clear();
    final usedNames = <String>{'list_py_tools', 'init_py_tool', 'run_py_tool'};
    final rows = await ServerDuckDbService().getAllPyTools();
    final source = _allowInactive
        ? rows
        : rows.where((t) => t['is_active'] as bool? ?? true).toList();

    for (final row in source) {
      final id = row['id']?.toString() ?? '';
      final displayName = row['name']?.toString() ?? '';
      if (id.isEmpty || displayName.isEmpty) continue;
      var dynName = 'py_${_sanitize(displayName)}';
      if (dynName == 'py_' || dynName == 'py') dynName = 'py_tool';
      if (usedNames.contains(dynName)) {
        dynName = '${dynName}_${id.substring(0, math.min(6, id.length))}';
      }
      usedNames.add(dynName);
      _toolNameToId[dynName] = id;

      final schema =
          (row['input_schema'] as Map<String, dynamic>?) ??
          const <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{},
          };
      final schemaWithTimeout = Map<String, dynamic>.from(schema);
      final props = Map<String, dynamic>.from(
        (schemaWithTimeout['properties'] as Map<String, dynamic>?) ??
            <String, dynamic>{},
      );
      props['timeoutSeconds'] = {
        'type': 'integer',
        'description': 'Override execution timeout in seconds for this call.',
      };
      schemaWithTimeout['properties'] = props;

      _dynamicTools.add(
        MCPTool(
          name: dynName,
          description:
              (row['description']?.toString().trim().isNotEmpty ?? false)
              ? row['description'].toString()
              : 'Python tool: $displayName',
          inputSchema: schemaWithTimeout,
        ),
      );
    }
  }

  String _sanitize(String s) {
    return s
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
  }

  Future<Map<String, dynamic>> _initTool(Map<String, dynamic> args) async {
    final tool = await _resolveTool(args);
    if (tool == null) {
      return {'error': 'Tool not found. Provide toolId or toolName.'};
    }

    final timeoutSeconds =
        ((args['timeoutSeconds'] as int?) ?? _initTimeoutSeconds).clamp(
          30,
          1800,
        );
    final toolId = tool['id'].toString();
    final toolName = tool['name']?.toString() ?? toolId;
    final logLines = <String>[];

    try {
      final dir = await _ensureToolFiles(tool);
      final venvPath = '${dir.path}/.venv';
      // On Windows venv uses Scripts\python.exe, on Linux/macOS bin/python
      final pythonPath = Platform.isWindows
          ? '$venvPath/Scripts/python.exe'
          : '$venvPath/bin/python';

      logLines.add('Creating venv with uv...');
      final venvResult = await _runSubprocess('uv', <String>[
        'venv',
        '--clear',
        venvPath,
      ], timeout: Duration(seconds: timeoutSeconds));
      logLines.addAll(_collectLogLines(venvResult));
      if (venvResult['exitCode'] != 0) {
        return {
          'success': false,
          'error': 'uv venv failed',
          'log': logLines,
          'toolId': toolId,
          'toolName': toolName,
        };
      }

      final reqFile = File('${dir.path}/requirements.txt');
      final requirements = (await reqFile.readAsString()).trim();
      if (requirements.isNotEmpty) {
        logLines.add('Installing Python requirements...');
        final pipResult = await _runSubprocess('uv', <String>[
          'pip',
          'install',
          '--python',
          pythonPath,
          '-r',
          reqFile.path,
        ], timeout: Duration(seconds: timeoutSeconds));
        logLines.addAll(_collectLogLines(pipResult));
        if (pipResult['exitCode'] != 0) {
          return {
            'success': false,
            'error': 'uv pip install failed',
            'log': logLines,
            'toolId': toolId,
            'toolName': toolName,
          };
        }
      }

      await ServerDuckDbService().setPyToolVenvReady(toolId, true);
      return {
        'success': true,
        'message': 'Venv ready for "$toolName"',
        'log': logLines,
        'toolId': toolId,
        'toolName': toolName,
      };
    } on TimeoutException catch (e) {
      return {
        'success': false,
        'error': e.message ?? e.toString(),
        'log': logLines,
        'toolId': toolId,
        'toolName': toolName,
      };
    } catch (e) {
      return {
        'success': false,
        'error': e.toString(),
        'log': logLines,
        'toolId': toolId,
        'toolName': toolName,
      };
    }
  }

  Future<Map<String, dynamic>> _runTool(Map<String, dynamic> args) async {
    final tool = await _resolveTool(args);
    if (tool == null) {
      return {'error': 'Tool not found. Provide toolId or toolName.'};
    }
    final callArgs =
        args['args'] as Map<String, dynamic>? ?? <String, dynamic>{};
    final overrideTimeout = args['timeoutSeconds'] as int?;
    return _runById(tool['id'].toString(), callArgs, overrideTimeout);
  }

  Future<Map<String, dynamic>> _runById(
    String id,
    Map<String, dynamic> args,
    int? overrideTimeoutSeconds,
  ) async {
    final rows = await ServerDuckDbService().getAllPyTools();
    final tool = rows.where((t) => t['id']?.toString() == id).firstOrNull;
    if (tool == null) return {'error': 'Tool not found: $id'};

    final isActive = tool['is_active'] as bool? ?? true;
    if (!isActive && !_allowInactive) {
      return {
        'success': false,
        'error': 'Tool is disabled: ${tool['name'] ?? id}',
      };
    }

    final venvReady = tool['venv_ready'] as bool? ?? false;
    if (!venvReady) {
      // Auto-initialize the venv on first use instead of failing
      log.info('[PyBridge] venv not ready for "${tool['name']}" — auto-initializing…');
      final initResult = await _initTool({'toolId': id, 'timeoutSeconds': 300});
      if (initResult['success'] != true) {
        return {
          'success': false,
          'error': 'Auto-init failed: ${initResult['error'] ?? 'unknown error'}',
          'toolId': id,
          'toolName': tool['name'],
        };
      }
      log.info('[PyBridge] Auto-init succeeded for "${tool['name']}"');
    }

    final timeout = Duration(
      seconds: (overrideTimeoutSeconds ?? _defaultTimeoutSeconds).clamp(
        5,
        1800,
      ),
    );
    final dir = await _ensureToolFiles(tool);
    final codePath = '${dir.path}/code.py';
    // On Windows venv uses Scripts\python.exe, on Linux/macOS bin/python
    final pythonPath = Platform.isWindows
        ? '${dir.path}/.venv/Scripts/python.exe'
        : '${dir.path}/.venv/bin/python';
    final shimPath = '${dir.path}/.shim_run.py';

    const shim = '''import json, os, sys, importlib.util, traceback

args = json.loads(os.environ.get('TOOL_ARGS_JSON', '{}'))

spec = importlib.util.spec_from_file_location('_tool', os.environ['TOOL_CODE_PATH'])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

try:
    result = mod.execute(args)
    print(json.dumps({"result": result}))
except Exception as e:
    print(json.dumps({"error": str(e), "trace": traceback.format_exc()}), file=sys.stderr)
    sys.exit(1)
''';

    await File(shimPath).writeAsString(shim, flush: true);
    try {
      final result = await _runSubprocess(
        pythonPath,
        <String>[shimPath],
        timeout: timeout,
        environment: <String, String>{
          'TOOL_ARGS_JSON': jsonEncode(args),
          'TOOL_CODE_PATH': codePath,
        },
      );

      final stdoutText = (result['stdout'] as String? ?? '').trim();
      final stderrText = (result['stderr'] as String? ?? '').trim();
      final exitCode = result['exitCode'] as int? ?? -1;

      if (exitCode != 0) {
        final decodedErr = _decodeTrailingJson(stderrText);
        final errorText = decodedErr is Map<String, dynamic>
            ? (decodedErr['error']?.toString() ?? stderrText)
            : (stderrText.isNotEmpty
                  ? stderrText
                  : 'Python tool failed with exit code $exitCode');
        return {
          'success': false,
          'error': errorText,
          if (decodedErr is Map<String, dynamic> && decodedErr['trace'] != null)
            'trace': decodedErr['trace'],
          'toolId': id,
          'toolName': tool['name'],
        };
      }

      final decoded = _decodeTrailingJson(stdoutText);
      if (decoded is! Map<String, dynamic>) {
        return {
          'success': false,
          'error': 'Failed to parse Python result JSON.',
          'stdout': stdoutText,
          'toolId': id,
          'toolName': tool['name'],
        };
      }
      if (decoded['error'] != null) {
        return {
          'success': false,
          'error': decoded['error'],
          'toolId': id,
          'toolName': tool['name'],
        };
      }
      return {
        'success': true,
        'result': decoded['result'],
        'toolId': id,
        'toolName': tool['name'],
      };
    } finally {
      final shimFile = File(shimPath);
      if (await shimFile.exists()) {
        await shimFile.delete();
      }
    }
  }

  Future<Map<String, dynamic>?> _resolveTool(Map<String, dynamic> args) async {
    final rows = await ServerDuckDbService().getAllPyTools();
    final source = _allowInactive
        ? rows
        : rows.where((t) => t['is_active'] as bool? ?? true).toList();
    final id = (args['toolId'] as String?)?.trim();
    final name = (args['toolName'] as String?)?.trim().toLowerCase();
    if (id != null && id.isNotEmpty) {
      return source.where((t) => t['id']?.toString() == id).firstOrNull;
    }
    if (name != null && name.isNotEmpty) {
      return source
          .where((t) => (t['name']?.toString().toLowerCase() ?? '') == name)
          .firstOrNull;
    }
    return null;
  }

  Future<Directory> _ensureToolFiles(Map<String, dynamic> tool) async {
    final dataDir = ServerDuckDbService().dataDir;
    final toolId = tool['id'].toString();
    final dir = Directory('$dataDir/py_scripts/$toolId');
    await dir.create(recursive: true);
    await File(
      '${dir.path}/code.py',
    ).writeAsString(tool['code']?.toString() ?? '', flush: true);
    await File(
      '${dir.path}/requirements.txt',
    ).writeAsString(tool['requirements']?.toString() ?? '', flush: true);
    return dir;
  }

  Future<Map<String, dynamic>> _runSubprocess(
    String executable,
    List<String> args, {
    required Duration timeout,
    Map<String, String>? environment,
  }) async {
    final proc = await Process.start(
      executable,
      args,
      environment: <String, String>{...Platform.environment, ...?environment},
      runInShell: false,
    );

    final stdoutFuture = proc.stdout.transform(utf8.decoder).join();
    final stderrFuture = proc.stderr.transform(utf8.decoder).join();
    final exitCode = await proc.exitCode.timeout(
      timeout,
      onTimeout: () {
        proc.kill(ProcessSignal.sigkill);
        throw TimeoutException(
          'Command timed out: $executable ${args.join(' ')}',
        );
      },
    );
    return {
      'exitCode': exitCode,
      'stdout': await stdoutFuture,
      'stderr': await stderrFuture,
    };
  }

  List<String> _collectLogLines(Map<String, dynamic> procResult) {
    final lines = <String>[];
    final stdoutText = (procResult['stdout'] as String? ?? '').trim();
    final stderrText = (procResult['stderr'] as String? ?? '').trim();
    if (stdoutText.isNotEmpty) lines.add(stdoutText);
    if (stderrText.isNotEmpty) lines.add(stderrText);
    return lines;
  }
}

dynamic _decodeTrailingJson(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  try {
    return jsonDecode(text);
  } catch (_) {}

  final lines = text
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
  for (var i = lines.length - 1; i >= 0; i--) {
    try {
      return jsonDecode(lines[i]);
    } catch (_) {}
  }
  return null;
}

class ServerWebsiteSearchMcp extends ServerInternalMcp {
  List<Uri> _seedUrls = [];
  int _maxPages = 100;
  String _indexingStrategy = 'now';
  bool _indexed = false;

  static const _tools = <MCPTool>[
    MCPTool(
      name: 'index_websites',
      description:
          'Crawl and index websites into DuckDB. Use the "sites" parameter to specify which websites to index.',
      inputSchema: {
        'type': 'object',
        'properties': <String, Object>{
          'sites': {
            'type': 'string',
            'description':
                'Comma-separated list of website URLs to index (e.g. "https://example.com, https://other.org"). If omitted, uses configured website URLs.',
          },
        },
        'required': <String>[],
      },
    ),
    MCPTool(
      name: 'reindex_websites',
      description:
          'Rebuild the website index. Use the "sites" parameter to specify which websites to reindex.',
      inputSchema: {
        'type': 'object',
        'properties': <String, Object>{
          'sites': {
            'type': 'string',
            'description':
                'Comma-separated list of website URLs to reindex (e.g. "https://example.com, https://other.org"). If omitted, uses configured website URLs.',
          },
        },
        'required': <String>[],
      },
    ),
    MCPTool(
      name: 'purge_stale_index',
      description:
          'Delete indexed website rows that no longer belong to currently configured seed URLs.',
      inputSchema: {
        'type': 'object',
        'properties': <String, Object>{},
        'required': <String>[],
      },
    ),
    MCPTool(
      name: 'list_indexed_pages',
      description: 'List pages currently in the website index.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'domain': {
            'type': 'string',
            'description': 'Optional domain filter (e.g. example.com).',
          },
          'limit': {'type': 'integer', 'default': 50},
        },
        'required': <String>[],
      },
    ),
    MCPTool(
      name: 'search_indexed_websites',
      description:
          'Search indexed website content with hybrid semantic + keyword ranking.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'query': {'type': 'string'},
          'domain': {'type': 'string'},
          'limit': {'type': 'integer', 'default': 20},
          'searchMode': {
            'type': 'string',
            'enum': ['keyword', 'semantic', 'hybrid'],
            'default': 'hybrid',
          },
        },
        'required': ['query'],
      },
    ),
    MCPTool(
      name: 'get_indexed_page',
      description: 'Get full stored content for one indexed URL.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'url': {'type': 'string'},
        },
        'required': ['url'],
      },
    ),
  ];

  @override
  List<MCPTool> get tools => _tools;

  Future<void> initialize(Map<String, dynamic> initParams) async {
    final rawUrls = initParams['websiteUrls'] as String? ?? '';
    _seedUrls = _wsParseSeedUrls(rawUrls);
    final rawMaxPages = initParams['maxPages'];
    final parsedMaxPages = switch (rawMaxPages) {
      int v => v,
      num v => v.toInt(),
      String v => int.tryParse(v.trim()) ?? 100,
      _ => 100,
    };
    _maxPages = parsedMaxPages.clamp(1, 1000);
    _indexingStrategy = (initParams['indexingStrategy'] as String? ?? 'now')
        .trim();
    if (_indexingStrategy != 'before_first_run' &&
        _indexingStrategy != 'none') {
      _indexingStrategy = 'now';
    }

    if (_indexingStrategy == 'now' && _seedUrls.isNotEmpty) {
      log.info(
        '[ServerWebsiteSearchMcp] Starting synchronous indexing on initialize...',
      );
      await ServerIndexingService.instance.runWebsiteIndexSync(
        urls: _seedUrls.map((u) => u.toString()).join(','),
        maxPages: _maxPages,
      );
    } else if (_indexingStrategy == 'before_first_run' &&
        _seedUrls.isNotEmpty) {
      final db = ServerDuckDbService();
      try {
        final seedIn = _seedUrls
            .map((s) => "'${_esc(_wsNormalizeUrl(s))}'")
            .join(',');
        final rows = await db.query(
          'SELECT COUNT(*) FROM website_index WHERE seed_url IN ($seedIn)',
        );
        final count = rows.isNotEmpty
            ? int.tryParse(rows.first.first.toString()) ?? 0
            : 0;
        if (count > 0) {
          _indexed = true;
          log.info(
            '[ServerWebsiteSearchMcp] Already indexed $count pages for configured seeds; skipping lazy re-indexing.',
          );
        }
      } catch (e) {
        log.warning(
          '[ServerWebsiteSearchMcp] Failed to check existing index count: $e',
        );
      }
    } else if (_indexingStrategy == 'none') {
      _indexed = true;
    }

    log.info(
      '[ServerWebsiteSearchMcp] Initialized seeds=${_seedUrls.map((u) => u.toString()).join(",")} maxPages=$_maxPages strategy=$_indexingStrategy',
    );
  }

  String _esc(String s) => s.replaceAll("'", "''");

  static const _kSkipPathSegments = {
    'autor',
    'author',
    'autoren',
    'redaktion',
    'redakteur',
    'tag',
    'tags',
    'thema',
    'themen',
    'kategorie',
    'kategorien',
    'suche',
    'search',
    'impressum',
    'datenschutz',
    'agb',
    'kontakt',
    'ueber-uns',
    'about',
    'dsi',
    'privacy',
    'legal',
    'cookie',
    'cookies',
    'newsletter',
    'abo',
    'abonnement',
    'subscription',
    'login',
    'signin',
    'register',
    'konto',
    'account',
    'sitemap',
    'feed',
  };

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> args,
  ) async {
    if (!_indexed &&
        _indexingStrategy == 'before_first_run' &&
        name != 'index_websites' &&
        name != 'reindex_websites') {
      _indexed = true; // prevent re-entry
      if (_seedUrls.isNotEmpty) {
        log.info('[ServerWebsiteSearchMcp] Lazy indexing before first run...');
        await ServerIndexingService.instance.runWebsiteIndexSync(
          urls: _seedUrls.map((u) => u.toString()).join(','),
          maxPages: _maxPages,
        );
      }
    }

    switch (name) {
      case 'index_websites':
      case 'reindex_websites':
        return _indexWebsites(args);
      case 'purge_stale_index':
        return _purgeStaleIndex();
      case 'list_indexed_pages':
        return _listIndexedPages(args);
      case 'search_indexed_websites':
        return _searchIndexedWebsites(args);
      case 'get_indexed_page':
        return _getIndexedPage(args);
      default:
        return {'error': 'Unknown tool: $name'};
    }
  }

  Future<Map<String, dynamic>> _indexWebsites(Map<String, dynamic> args) async {
    final sitesParam = (args['sites'] as String?)?.trim();
    if (sitesParam != null && sitesParam.isNotEmpty) {
      final parsedSites = _wsParseSeedUrls(sitesParam);
      if (parsedSites.isEmpty) {
        return {'error': 'No valid website URLs found in sites parameter.'};
      }
      final result = await ServerIndexingService.instance.runWebsiteIndexSync(
        urls: parsedSites.map((u) => u.toString()).join(','),
        maxPages: _maxPages,
      );
      log.info(
        '[ServerWebsiteSearchMcp] indexing triggered with sites param: $result',
      );
      return result;
    }
    if (_seedUrls.isEmpty) {
      return {
        'error':
            'No websiteUrls configured for this task and no sites parameter provided.',
      };
    }
    final result = await ServerIndexingService.instance.runWebsiteIndexSync(
      urls: _seedUrls.map((u) => u.toString()).join(','),
      maxPages: _maxPages,
    );
    log.info('[ServerWebsiteSearchMcp] indexing triggered: $result');
    return result;
  }

  Future<Map<String, dynamic>> _purgeStaleIndex() async {
    final result = await ServerIndexingService.instance
        .purgeStaleWebsiteIndex();
    log.info('[ServerWebsiteSearchMcp] purge_stale_index result: $result');
    return result;
  }

  Future<Map<String, dynamic>> _listIndexedPages(
    Map<String, dynamic> args,
  ) async {
    final domain = (args['domain'] as String?)?.trim().toLowerCase();
    final limit = ((args['limit'] as int?) ?? 50).clamp(1, 500);
    final db = ServerDuckDbService();
    final where = StringBuffer('WHERE ${_wsSeedScopeClause()}');
    if (domain != null && domain.isNotEmpty) {
      where.write(" AND domain = '${_esc(domain)}'");
    }
    try {
      final rows = await db.query('''
        SELECT url, domain, title, http_status, indexed_at
        FROM website_index
        $where
        ORDER BY indexed_at DESC
        LIMIT $limit
      ''');
      return {
        'returned': rows.length,
        'pages': rows
            .map(
              (r) => {
                'url': r[0],
                'domain': r[1],
                'title': r[2],
                'httpStatus': r[3],
                'indexedAt': r[4],
              },
            )
            .toList(),
      };
    } catch (e) {
      log.warning('[ServerWebsiteSearchMcp] list_indexed_pages error: $e');
      return {'error': 'Failed to list indexed pages: $e'};
    }
  }

  Future<Map<String, dynamic>> _searchIndexedWebsites(
    Map<String, dynamic> args,
  ) async {
    final rawQuery = (args['query'] as String?)?.trim();
    if (rawQuery == null || rawQuery.isEmpty) {
      return {'error': 'Parameter "query" is required.'};
    }
    // Strip boolean operators / field names the LLM sometimes injects.
    final query = rawQuery
        .replaceAll(RegExp(r'\b(OR|AND|NOT)\b'), ' ')
        .replaceAll(RegExp(r'[()\[\]]'), ' ')
        .replaceAll(
          RegExp(
            r'\b(Titel|Überschrift|Lead|Teaser|Vorspann|Schlagzeile)\b',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();
    final domain = (args['domain'] as String?)?.trim().toLowerCase();
    final limit = ((args['limit'] as int?) ?? 20).clamp(1, 200);
    final mode = (args['searchMode'] as String? ?? 'hybrid').toLowerCase();
    final db = ServerDuckDbService();
    final where = StringBuffer(
      "WHERE ${_wsSeedScopeClause()} AND content_text IS NOT NULL AND content_text != ''",
    );
    if (domain != null && domain.isNotEmpty) {
      where.write(" AND domain = '${_esc(domain)}'");
    }
    try {
      final rows = await db.query('''
        SELECT url, domain, title, content_text, embedding_json, indexed_at
        FROM website_index
        $where
      ''');
      final queryEmbedding = SemanticEmbedding.buildEmbedding(query);
      final matches = <Map<String, dynamic>>[];
      for (final row in rows) {
        final content = (row[3] ?? '').toString();
        if (content.isEmpty) continue;
        final rowUrl = (row[0] ?? '').toString();
        final rowPathParts = (Uri.tryParse(rowUrl)?.path.toLowerCase() ?? '')
            .split('/')
            .where((s) => s.isNotEmpty);
        if (rowPathParts.any(
          (seg) => _kSkipPathSegments.contains(seg.split('?').first),
        )) {
          continue;
        }
        final docEmbedding = SemanticEmbedding.fromJson(row[4]?.toString());
        final semanticScore = SemanticEmbedding.cosineSimilarity(
          queryEmbedding,
          docEmbedding,
        );
        final keywordScore = SemanticEmbedding.keywordOverlapScore(
          query,
          content,
        );
        final lexicalMatches = _wsCountMatches(content, query);
        final relevance = switch (mode) {
          'keyword' => keywordScore + (lexicalMatches * 0.02),
          'semantic' => semanticScore,
          _ =>
            (0.65 * semanticScore) +
                (0.30 * keywordScore) +
                (0.05 * lexicalMatches),
        };
        if (lexicalMatches == 0 && relevance < 0.12) continue;
        matches.add({
          'url': row[0],
          'domain': row[1],
          'title': row[2],
          'excerpt': _wsBuildExcerpt(content, query),
          'keywordMatches': lexicalMatches,
          'keywordScore': keywordScore,
          'semanticScore': semanticScore,
          'relevanceScore': relevance,
          'indexedAt': row[5],
        });
      }
      matches.sort(
        (a, b) =>
            (b['relevanceScore'] as num).compareTo(a['relevanceScore'] as num),
      );
      final domainRows = await db.query(
        'SELECT domain, COUNT(*) as cnt FROM website_index WHERE ${_wsSeedScopeClause()} GROUP BY domain ORDER BY cnt DESC',
      );
      final indexedDomains = {
        for (final r in domainRows) r[0].toString(): r[1],
      };
      List<Map<String, dynamic>> finalResults = matches;
      bool usedFallback = false;
      if (matches.isEmpty && rows.isNotEmpty) {
        usedFallback = true;
        final fallback = <Map<String, dynamic>>[];
        for (final row in rows) {
          final rowUrl = (row[0] ?? '').toString();
          final rowPathParts = (Uri.tryParse(rowUrl)?.path.toLowerCase() ?? '')
              .split('/')
              .where((s) => s.isNotEmpty);
          if (rowPathParts.any(
            (seg) => _kSkipPathSegments.contains(seg.split('?').first),
          )) {
            continue;
          }
          final content = (row[3] ?? '').toString();
          if (content.isEmpty) continue;
          final docEmbedding = SemanticEmbedding.fromJson(row[4]?.toString());
          final score = SemanticEmbedding.cosineSimilarity(
            queryEmbedding,
            docEmbedding,
          );
          fallback.add({
            'url': row[0],
            'domain': row[1],
            'title': row[2],
            'excerpt': _wsBuildExcerpt(content, query),
            'keywordMatches': 0,
            'semanticScore': score,
            'relevanceScore': score,
            'indexedAt': row[5],
          });
        }
        fallback.sort(
          (a, b) => (b['relevanceScore'] as num).compareTo(
            a['relevanceScore'] as num,
          ),
        );
        finalResults = fallback.take(limit).toList();
      }
      final sampleRows = await db.query(
        "SELECT title, domain FROM website_index WHERE ${_wsSeedScopeClause()} AND title IS NOT NULL AND title != '' LIMIT 5",
      );
      final sampleTitles = sampleRows.map((r) => '${r[1]}: ${r[0]}').toList();
      return {
        'query': query,
        if (rawQuery != query) 'originalQuery': rawQuery,
        'searchMode': mode,
        'totalResults': finalResults.length,
        'usedFallback': usedFallback,
        'results': finalResults,
        'indexedDomains': indexedDomains,
        if (finalResults.isEmpty) 'sampleIndexedTitles': sampleTitles,
      };
    } catch (e) {
      log.warning('[ServerWebsiteSearchMcp] search_indexed_websites error: $e');
      return {'error': 'Search failed: $e'};
    }
  }

  Future<Map<String, dynamic>> _getIndexedPage(
    Map<String, dynamic> args,
  ) async {
    final url = (args['url'] as String?)?.trim();
    if (url == null || url.isEmpty) {
      return {'error': 'Parameter "url" is required.'};
    }
    final normalized = _wsNormalizeUrl(Uri.parse(url));
    final db = ServerDuckDbService();
    try {
      final rows = await db.query('''
        SELECT url, domain, title, content_text, indexed_at
        FROM website_index
        WHERE ${_wsSeedScopeClause()} AND url = '${_esc(normalized)}'
        LIMIT 1
      ''');
      if (rows.isEmpty) return {'error': 'Indexed page not found: $url'};
      final row = rows.first;
      return {
        'url': row[0],
        'domain': row[1],
        'title': row[2],
        'content': row[3],
        'indexedAt': row[4],
      };
    } catch (e) {
      log.warning('[ServerWebsiteSearchMcp] get_indexed_page error: $e');
      return {'error': 'Failed to get indexed page: $e'};
    }
  }

  List<Uri> _wsParseSeedUrls(String raw) {
    final urls = <Uri>[];
    for (final part
        in raw
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .take(10)) {
      try {
        var uri = Uri.parse(part);
        if (!uri.hasScheme) uri = Uri.parse('https://$part');
        if (uri.scheme == 'http' || uri.scheme == 'https') urls.add(uri);
      } catch (_) {}
    }
    return urls;
  }

  String _wsNormalizeUrl(Uri uri) {
    var s = uri.removeFragment().toString();
    if (s.endsWith('/')) s = s.substring(0, s.length - 1);
    return s;
  }

  String _wsSeedScopeClause() {
    final seeds = _seedUrls.map(_wsNormalizeUrl).toSet().toList();
    if (seeds.isEmpty) return '1=0';
    final seedIn = seeds.map((s) => "'${_esc(s)}'").join(',');
    return 'seed_url IN ($seedIn)';
  }

  int _wsCountMatches(String content, String query) {
    final words = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    final lower = content.toLowerCase();
    var count = 0;
    for (final word in words) {
      int pos = 0;
      while (true) {
        pos = lower.indexOf(word, pos);
        if (pos < 0) break;
        count++;
        pos += word.length;
      }
    }
    return count;
  }

  String _wsBuildExcerpt(String content, String query, [int maxLen = 220]) {
    final words = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) {
      return content.substring(0, content.length.clamp(0, maxLen));
    }
    final lower = content.toLowerCase();
    int bestPos = -1;
    for (final word in words) {
      final pos = lower.indexOf(word);
      if (pos >= 0 && (bestPos < 0 || pos < bestPos)) bestPos = pos;
    }
    if (bestPos < 0) {
      return content.substring(0, content.length.clamp(0, maxLen));
    }
    final start = (bestPos - 60).clamp(0, content.length);
    final end = (start + maxLen).clamp(0, content.length);
    final excerpt = content.substring(start, end).replaceAll('\n', ' ').trim();
    return start > 0 ? '…$excerpt' : excerpt;
  }
}

// ═══════════════════════════════════════════════════════════════
// Toolbox (time, timezone, geocode, calculate, sum)
// ═══════════════════════════════════════════════════════════════

class ServerToolboxMcp extends ServerInternalMcp {
  static const _geocodeUrl = 'https://geocoding-api.open-meteo.com/v1';

  String _timezoneMode = 'local';

  static const _tools = <MCPTool>[
    MCPTool(
      name: 'get_current_time',
      description:
          'Get current date/time with ISO timestamp, unix epoch, timezone name, and UTC offset.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'timezone': {
            'type': 'string',
            'description': 'Optional override: "local" or "utc".',
            'enum': ['local', 'utc'],
          },
        },
        'required': [],
      },
    ),
    MCPTool(
      name: 'get_timezone_info',
      description: 'Get timezone details for local time or UTC.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'timezone': {
            'type': 'string',
            'enum': ['local', 'utc'],
          },
        },
        'required': [],
      },
    ),
    MCPTool(
      name: 'get_current_location',
      description:
          'Returns a "not available" message — the server has no GPS or manually set location.',
      inputSchema: {'type': 'object', 'properties': {}, 'required': []},
    ),
    MCPTool(
      name: 'geocode_city',
      description: 'Resolve a city name to coordinates and timezone metadata.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'city': {
            'type': 'string',
            'description': 'City name (e.g. "Berlin", "New York").',
          },
          'count': {
            'type': 'integer',
            'description': 'Max results (1-10, default 5).',
            'default': 5,
          },
        },
        'required': ['city'],
      },
    ),
    MCPTool(
      name: 'calculate',
      description:
          'Evaluate a mathematical expression containing LITERAL NUMBERS and return the exact result. '
          'IMPORTANT: Only pass expressions with actual numeric values (e.g. "1234 + 5678"). '
          'Do NOT use this tool if any part of the expression is a variable name, identifier, '
          'script name, or word (e.g. "cpu_usage", "total", "value") — those are NOT math expressions. '
          'Supported: +  -  *  /  %  ^  sqrt()  abs()  round()  floor()  ceil()  log()  sin()  cos()  tan()  pi  e. '
          'Example: "(1234 + 5678) * 0.001" or "sqrt(144)".',
      inputSchema: {
        'type': 'object',
        'properties': {
          'expression': {
            'type': 'string',
            'description': 'Mathematical expression to evaluate.',
          },
        },
        'required': ['expression'],
      },
    ),
    MCPTool(
      name: 'sum_numbers',
      description: 'Sum a list of numbers and optionally compute the average.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'numbers': {
            'type': 'array',
            'items': {'type': 'number'},
            'description': 'List of numeric values to sum.',
          },
          'labels': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'Optional labels for each number.',
          },
          'round_decimals': {
            'type': 'integer',
            'description': 'Decimal places in result (default 4).',
            'default': 4,
          },
        },
        'required': ['numbers'],
      },
    ),
  ];

  @override
  List<MCPTool> get tools => _tools;

  void initialize(Map<String, dynamic> initParams) {
    final mode = (initParams['timezone'] as String? ?? 'local')
        .trim()
        .toLowerCase();
    _timezoneMode = mode == 'utc' ? 'utc' : 'local';
  }

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> args,
  ) async {
    switch (name) {
      case 'get_current_time':
        return _getCurrentTime(args);
      case 'get_timezone_info':
        return _getTimezoneInfo(args);
      case 'get_current_location':
        return {
          'available': false,
          'message':
              'Location is not available in server mode. Use geocode_city to look up coordinates by city name.',
        };
      case 'geocode_city':
        return _geocodeCity(args);
      case 'calculate':
        return _calculate(args);
      case 'sum_numbers':
        return _sumNumbers(args);
      default:
        return {'error': 'Unknown toolbox tool: $name'};
    }
  }

  Map<String, dynamic> _getCurrentTime(Map<String, dynamic> args) {
    final mode = _resolveMode(args['timezone'] as String?);
    final now = mode == 'utc' ? DateTime.now().toUtc() : DateTime.now();
    final offset = now.timeZoneOffset;
    return {
      'timezoneMode': mode,
      'iso8601': now.toIso8601String(),
      'epochMs': now.millisecondsSinceEpoch,
      'timezoneName': now.timeZoneName,
      'offsetMinutes': offset.inMinutes,
      'offsetText': _formatOffset(offset),
      'date': now.toIso8601String().split('T').first,
      'time': now.toIso8601String().split('T').last,
    };
  }

  Map<String, dynamic> _getTimezoneInfo(Map<String, dynamic> args) {
    final mode = _resolveMode(args['timezone'] as String?);
    final now = mode == 'utc' ? DateTime.now().toUtc() : DateTime.now();
    final offset = now.timeZoneOffset;
    return {
      'timezoneMode': mode,
      'timezoneName': now.timeZoneName,
      'offsetMinutes': offset.inMinutes,
      'offsetText': _formatOffset(offset),
      'nowIso8601': now.toIso8601String(),
      'supportedModes': ['local', 'utc'],
    };
  }

  Future<Map<String, dynamic>> _geocodeCity(Map<String, dynamic> args) async {
    final city = (args['city'] as String?)?.trim();
    if (city == null || city.isEmpty) {
      return {'error': 'Parameter "city" is required.'};
    }
    final count = ((args['count'] as int?) ?? 5).clamp(1, 10);
    final url =
        '$_geocodeUrl/search?name=${Uri.encodeComponent(city)}&count=$count&language=en&format=json';
    try {
      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        return {'error': 'Geocoding API returned ${response.statusCode}'};
      }
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final results = (body['results'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      return {
        'query': city,
        'count': results.length,
        'results': results
            .map(
              (item) => {
                'name': item['name'],
                'country': item['country'],
                'admin1': item['admin1'],
                'latitude': item['latitude'],
                'longitude': item['longitude'],
                'timezone': item['timezone'],
                'population': item['population'],
              },
            )
            .toList(),
      };
    } catch (e) {
      return {'error': 'Geocoding failed: $e'};
    }
  }

  String _resolveMode(String? override) {
    final v = (override ?? _timezoneMode).trim().toLowerCase();
    return v == 'utc' ? 'utc' : 'local';
  }

  String _formatOffset(Duration offset) {
    final sign = offset.isNegative ? '-' : '+';
    final total = offset.inMinutes.abs();
    return '$sign${(total ~/ 60).toString().padLeft(2, '0')}:${(total % 60).toString().padLeft(2, '0')}';
  }

  // ── calculate ──────────────────────────────────────────────────────────────

  Map<String, dynamic> _calculate(Map<String, dynamic> args) {
    final expr = (args['expression'] as String? ?? '').trim();
    if (expr.isEmpty) return {'error': 'expression is required'};
    try {
      final result = _evalExpr(expr);
      return {
        'expression': expr,
        'result': result,
        'resultText': result % 1 == 0
            ? result.toStringAsFixed(0)
            : result.toString(),
      };
    } catch (e) {
      return {'error': 'Cannot evaluate "$expr": $e'};
    }
  }

  Map<String, dynamic> _sumNumbers(Map<String, dynamic> args) {
    final rawList = args['numbers'];
    if (rawList == null) return {'error': '"numbers" is required'};
    final numbers = (rawList as List<dynamic>)
        .map((v) => (v as num).toDouble())
        .toList();
    if (numbers.isEmpty) {
      return {'sum': 0.0, 'count': 0, 'average': null, 'breakdown': []};
    }
    final labels = (args['labels'] as List<dynamic>?)
        ?.map((v) => v.toString())
        .toList();
    final decimals = ((args['round_decimals'] as int?) ?? 4).clamp(0, 10);
    final sum = numbers.fold(0.0, (acc, n) => acc + n);
    final avg = sum / numbers.length;
    double r(double v) => double.parse(v.toStringAsFixed(decimals));
    final breakdown = <Map<String, dynamic>>[
      for (var i = 0; i < numbers.length; i++)
        {
          if (labels != null && i < labels.length) 'label': labels[i],
          'value': numbers[i],
        },
    ];
    return {
      'sum': r(sum),
      'count': numbers.length,
      'average': r(avg),
      'min': numbers.reduce(math.min),
      'max': numbers.reduce(math.max),
      'breakdown': breakdown,
    };
  }

  // ── Minimal safe expression evaluator ─────────────────────────────────────

  static final RegExp _safeChars = RegExp(
    r'^[\d\s\+\-\*\/\%\^\(\)\.\,\[\]a-zA-Z_]+$',
  );
  static final RegExp _badIdent = RegExp(
    r'\b(?!sqrt|abs|round|floor|ceil|log|sin|cos|tan|sum|pi|e\b)[a-zA-Z_][a-zA-Z_0-9]*',
  );

  double _evalExpr(String expr) {
    if (!_safeChars.hasMatch(expr)) {
      throw ArgumentError('Unsupported characters in expression');
    }
    if (_badIdent.hasMatch(expr)) {
      throw ArgumentError('Unsupported identifier in expression');
    }
    var e2 = expr
        .replaceAll('pi', math.pi.toString())
        .replaceAll(RegExp(r'\be\b'), math.e.toString());
    e2 = e2.replaceAllMapped(RegExp(r'sum\(\[([^\]]+)\]\)'), (m) {
      final nums = m.group(1)!.split(',').map((s) => s.trim()).join('+');
      return '($nums)';
    });
    return _parseExpr(e2.replaceAll(' ', ''), _ToolboxCursor());
  }

  double _parseExpr(String s, _ToolboxCursor c) => _parseAddSub(s, c);

  double _parseAddSub(String s, _ToolboxCursor c) {
    var left = _parseMulDiv(s, c);
    while (c.pos < s.length && (s[c.pos] == '+' || s[c.pos] == '-')) {
      final op = s[c.pos++];
      final right = _parseMulDiv(s, c);
      left = op == '+' ? left + right : left - right;
    }
    return left;
  }

  double _parseMulDiv(String s, _ToolboxCursor c) {
    var left = _parsePow(s, c);
    while (c.pos < s.length &&
        (s[c.pos] == '*' || s[c.pos] == '/' || s[c.pos] == '%')) {
      final op = s[c.pos++];
      final right = _parsePow(s, c);
      left = op == '*'
          ? left * right
          : op == '/'
          ? left / right
          : left % right;
    }
    return left;
  }

  double _parsePow(String s, _ToolboxCursor c) {
    final base = _parseUnary(s, c);
    if (c.pos < s.length && s[c.pos] == '^') {
      c.pos++;
      return math.pow(base, _parseUnary(s, c)).toDouble();
    }
    return base;
  }

  double _parseUnary(String s, _ToolboxCursor c) {
    if (c.pos < s.length && s[c.pos] == '-') {
      c.pos++;
      return -_parsePrimary(s, c);
    }
    if (c.pos < s.length && s[c.pos] == '+') c.pos++;
    return _parsePrimary(s, c);
  }

  double _parsePrimary(String s, _ToolboxCursor c) {
    if (c.pos < s.length && s[c.pos] == '(') {
      c.pos++;
      final val = _parseExpr(s, c);
      if (c.pos < s.length && s[c.pos] == ')') c.pos++;
      return val;
    }
    final fnMatch = RegExp(
      r'^(sqrt|abs|round|floor|ceil|log|sin|cos|tan)\(',
    ).firstMatch(s.substring(c.pos));
    if (fnMatch != null) {
      c.pos += fnMatch.group(0)!.length;
      final arg = _parseExpr(s, c);
      if (c.pos < s.length && s[c.pos] == ')') c.pos++;
      return switch (fnMatch.group(1)!) {
        'sqrt' => math.sqrt(arg),
        'abs' => arg.abs(),
        'round' => arg.roundToDouble(),
        'floor' => arg.floorToDouble(),
        'ceil' => arg.ceilToDouble(),
        'log' => math.log(arg),
        'sin' => math.sin(arg),
        'cos' => math.cos(arg),
        'tan' => math.tan(arg),
        _ => throw ArgumentError('Unknown function'),
      };
    }
    final numMatch = RegExp(r'^\d+(\.\d+)?').firstMatch(s.substring(c.pos));
    if (numMatch != null) {
      c.pos += numMatch.group(0)!.length;
      return double.parse(numMatch.group(0)!);
    }
    throw ArgumentError('Unexpected token at position ${c.pos}');
  }
}

/// Mutable position cursor used by ServerToolboxMcp expression parser.
class _ToolboxCursor {
  int pos = 0;
}
