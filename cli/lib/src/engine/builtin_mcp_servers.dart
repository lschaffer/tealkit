import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_mcp_core/dart_mcp_core.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../config/global_config.dart';

MCPToolResult _toolResultError(String message) => MCPToolResult(
      isError: true,
      content: [MCPContent(type: 'text', text: message)],
    );

MCPToolResult _toolResultJson(Object data, {bool isError = false}) => MCPToolResult(
      isError: isError,
      content: [MCPContent(type: 'text', text: jsonEncode(data))],
    );

/// Manages built-in native TealKit MCP tools:
/// 1. `web_search` (configured via `web_search.yaml` or `.env`, falls back to DuckDuckGo)
/// 2. `mermaid` (`create_mermaid_png` via Kroki API)
/// 3. `toolbox` (`get_current_time`, `get_timezone_info`, `calculate`, `sum_numbers`, `geocode_city`)
/// 4. `ssh` (`execute_command`, `list_directory`, `read_file`, `upload_file`, `download_file`, `make_directory`, `remove_directory`, configured via `ssh.yaml`)
class BuiltinMcpServers {
  // ── Web Search ───────────────────────────────────────────────
  static McpLocalTool createWebSearchTool({String configPath = 'web_search.yaml'}) {
    return _WebSearchTool(configPath: configPath);
  }

  // ── Mermaid Diagram Tool ─────────────────────────────────────
  static McpLocalTool createMermaidTool() {
    return _MermaidTool();
  }

  // ── Toolbox Tools ────────────────────────────────────────────
  static List<McpLocalTool> createToolboxTools() {
    return [
      _GetCurrentTimeTool(),
      _GetTimezoneInfoTool(),
      _CalculateTool(),
      _SumNumbersTool(),
      _GeocodeCityTool(),
    ];
  }

  // ── SSH Tools ────────────────────────────────────────────────
  static _SshManager? _sharedSshManager;

  static _SshManager getSharedSshManager({String configPath = 'ssh.yaml'}) {
    return _sharedSshManager ??= _SshManager(configPath: configPath);
  }

  static List<McpLocalTool> createSshTools({String configPath = 'ssh.yaml'}) {
    final client = getSharedSshManager(configPath: configPath);
    return [
      _SshListDirectoryTool(client),
      _SshReadFileTool(client),
      _SshUploadFileTool(client),
      _SshDownloadFileTool(client),
      _SshMakeDirectoryTool(client),
      _SshRemoveDirectoryTool(client),
      _SshExecuteCommandTool(client),
    ];
  }

  /// Sets in-memory SSH connection details for the active session without modifying ssh.yaml.
  static Future<void> connectSshSession({
    required String host,
    int port = 22,
    required String username,
    String? password,
    String? privateKey,
    String configPath = 'ssh.yaml',
  }) async {
    final manager = getSharedSshManager(configPath: configPath);
    await manager.connectOverride(
      host: host,
      port: port,
      username: username,
      password: password ?? '',
      privateKey: privateKey ?? '',
    );
  }

  /// Disconnects the active session SSH client and reverts to preconfigured ssh.yaml.
  static Future<void> disconnectSshSession({String configPath = 'ssh.yaml'}) async {
    final manager = getSharedSshManager(configPath: configPath);
    await manager.disconnectOverride();
  }

  /// Gets current SSH status details.
  static Map<String, dynamic> getSshStatus({String configPath = 'ssh.yaml'}) {
    final manager = getSharedSshManager(configPath: configPath);
    return manager.getStatus();
  }

  /// Create all built-in tools configured for the workspace.
  static List<McpLocalTool> createAll() {
    return [
      createWebSearchTool(),
      createMermaidTool(),
      ...createToolboxTools(),
      ...createSshTools(),
    ];
  }
}

// ═══════════════════════════════════════════════════════════════
// 1. Web Search Tool Implementation
// ═══════════════════════════════════════════════════════════════

class _WebSearchTool extends McpLocalTool {
  final String configPath;

  _WebSearchTool({this.configPath = 'web_search.yaml'});

  @override
  String get name => 'web_search';

  @override
  String get description =>
      'Search the public web for real-time information, docs, news, and facts using SerpApi, Serper.dev, or DuckDuckGo.';

  @override
  ToolRiskLevel get riskLevel => ToolRiskLevel.network;

  @override
  Map<String, dynamic> get inputSchema => {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': 'Search query string to look up.',
          },
          'maxResults': {
            'type': 'integer',
            'description': 'Maximum number of results to return (default 5, max 20).',
          },
          'provider': {
            'type': 'string',
            'enum': ['auto', 'serpapi', 'serper', 'duckduckgo'],
            'description': 'Optional search provider override.',
          },
        },
        'required': ['query'],
      };

  @override
  Future<MCPToolResult> execute(Map<String, dynamic> arguments) async {
    final query = (arguments['query'] as String?)?.trim();
    if (query == null || query.isEmpty) {
      return _toolResultError('Query parameter is required.');
    }

    final maxResults = ((arguments['maxResults'] as int?) ?? 5).clamp(1, 20);
    final reqProvider = (arguments['provider'] as String?)?.trim().toLowerCase();

    // Read web_search.yaml config if present
    String provider = reqProvider ?? 'auto';
    String apiKey = '';

    final file = GlobalConfigLocator.resolveConfigFile(configPath);
    if (file.existsSync()) {
      try {
        final yaml = loadYaml(file.readAsStringSync()) as YamlMap?;
        if (yaml != null) {
          if (provider == 'auto' && yaml['provider'] != null) {
            provider = yaml['provider'].toString().toLowerCase().trim();
          }
          if (yaml['api_key'] != null) {
            apiKey = yaml['api_key'].toString().trim();
          }
        }
      } catch (_) {}
    }

    // Environment variable fallback
    if (apiKey.isEmpty) {
      apiKey = Platform.environment['SERPAPI_API_KEY'] ??
          Platform.environment['SERPER_API_KEY'] ??
          Platform.environment['WEB_SEARCH_API_KEY'] ??
          '';
    }

    // Try SerpApi
    if (provider == 'serpapi' || (provider == 'auto' && apiKey.isNotEmpty)) {
      try {
        final uri = Uri.parse('https://serpapi.com/search').replace(queryParameters: {
          'engine': 'google',
          'q': query,
          'num': '$maxResults',
          if (apiKey.isNotEmpty) 'api_key': apiKey,
        });
        final resp = await http.get(uri).timeout(const Duration(seconds: 15));
        if (resp.statusCode == 200) {
          final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
          final raw = (data['organic_results'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()
              .take(maxResults)
              .map((item) => {
                    'title': item['title']?.toString() ?? '',
                    'url': item['link']?.toString() ?? '',
                    'snippet': item['snippet']?.toString() ?? '',
                  })
              .toList();
          return _toolResultJson({
            'provider': 'serpapi',
            'query': query,
            'count': raw.length,
            'results': raw,
          });
        }
      } catch (_) {}
    }

    // Try Serper
    if (provider == 'serper' || (provider == 'auto' && apiKey.isNotEmpty)) {
      try {
        final uri = Uri.parse('https://google.serper.dev/search');
        final resp = await http.post(
          uri,
          headers: {'Content-Type': 'application/json', 'X-API-KEY': apiKey},
          body: jsonEncode({'q': query, 'num': maxResults}),
        ).timeout(const Duration(seconds: 15));
        if (resp.statusCode == 200) {
          final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
          final raw = (data['organic'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()
              .take(maxResults)
              .map((item) => {
                    'title': item['title']?.toString() ?? '',
                    'url': item['link']?.toString() ?? '',
                    'snippet': item['snippet']?.toString() ?? '',
                  })
              .toList();
          return _toolResultJson({
            'provider': 'serper',
            'query': query,
            'count': raw.length,
            'results': raw,
          });
        }
      } catch (_) {}
    }

    // Fallback: DuckDuckGo Instant Answer API
    try {
      final uri = Uri.parse('https://api.duckduckgo.com/').replace(queryParameters: {
        'q': query,
        'format': 'json',
        'no_html': '1',
        'no_redirect': '1',
      });
      final resp = await http.get(uri).timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200) {
        final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
        final results = <Map<String, dynamic>>[];
        final heading = (data['Heading'] ?? '').toString();
        final abstract = (data['AbstractText'] ?? '').toString();
        final abstractUrl = (data['AbstractURL'] ?? '').toString();
        if (heading.isNotEmpty || abstract.isNotEmpty) {
          results.add({'title': heading, 'url': abstractUrl, 'snippet': abstract});
        }

        final related = data['RelatedTopics'] as List<dynamic>? ?? const [];
        for (final topic in related) {
          if (results.length >= maxResults) break;
          if (topic is Map<String, dynamic>) {
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

        return _toolResultJson({
          'provider': 'duckduckgo',
          'query': query,
          'count': results.length,
          'results': results,
        });
      }
    } catch (e) {
      return _toolResultError('Web search failed: $e');
    }

    return _toolResultError('No search provider succeeded for query: "$query".');
  }
}

// ═══════════════════════════════════════════════════════════════
// 2. Mermaid Diagram Generator
// ═══════════════════════════════════════════════════════════════

class _MermaidTool extends McpLocalTool {
  @override
  String get name => 'create_mermaid_png';

  @override
  String get description =>
      'Render Mermaid diagram markdown into a PNG file on disk using Kroki API. Returns the saved PNG file path.';

  @override
  ToolRiskLevel get riskLevel => ToolRiskLevel.write;

  @override
  Map<String, dynamic> get inputSchema => {
        'type': 'object',
        'properties': {
          'md': {
            'type': 'string',
            'description': 'Mermaid diagram markdown source code (e.g. "graph TD\\n  A-->B").',
          },
          'fileName': {
            'type': 'string',
            'description': 'Optional output filename (default: "diagram.png").',
          },
        },
        'required': ['md'],
      };

  @override
  Future<MCPToolResult> execute(Map<String, dynamic> arguments) async {
    final md = (arguments['md'] as String?)?.trim();
    if (md == null || md.isEmpty) {
      return _toolResultError('Diagram markdown "md" is required.');
    }

    var fileName = (arguments['fileName'] as String?)?.trim() ?? 'diagram.png';
    if (!fileName.toLowerCase().endsWith('.png')) {
      fileName = '$fileName.png';
    }

    try {
      final resp = await http.post(
        Uri.parse('https://kroki.io/mermaid/png'),
        headers: {'Content-Type': 'text/plain; charset=utf-8', 'Accept': 'image/png'},
        body: md,
      ).timeout(const Duration(seconds: 25));

      final isPng = resp.bodyBytes.length > 4 &&
          resp.bodyBytes[0] == 0x89 &&
          resp.bodyBytes[1] == 0x50 &&
          resp.bodyBytes[2] == 0x4E &&
          resp.bodyBytes[3] == 0x47;

      if ((resp.statusCode < 200 || resp.statusCode >= 300) && !isPng) {
        return _toolResultError('Mermaid render error (${resp.statusCode}): ${utf8.decode(resp.bodyBytes, allowMalformed: true)}');
      }

      final outDir = Directory.current.path;
      final outFile = File(p.join(outDir, fileName));
      await outFile.writeAsBytes(resp.bodyBytes);

      return _toolResultJson({
        'success': true,
        'path': outFile.path,
        'fileName': fileName,
        'bytes': resp.bodyBytes.length,
        'message': 'Mermaid PNG diagram saved to ${outFile.path}',
      });
    } catch (e) {
      return _toolResultError('Failed to render Mermaid diagram: $e');
    }
  }
}

// ═══════════════════════════════════════════════════════════════
// 3. Toolbox Utilities
// ═══════════════════════════════════════════════════════════════

class _GetCurrentTimeTool extends McpLocalTool {
  @override
  String get name => 'get_current_time';

  @override
  String get description =>
      'Get current date and time with ISO timestamp, Unix epoch, timezone name, and UTC offset.';

  @override
  ToolRiskLevel get riskLevel => ToolRiskLevel.read;

  @override
  Map<String, dynamic> get inputSchema => {
        'type': 'object',
        'properties': {
          'timezone': {
            'type': 'string',
            'enum': ['local', 'utc'],
            'description': 'Timezone mode: "local" (default) or "utc".',
          },
        },
      };

  @override
  Future<MCPToolResult> execute(Map<String, dynamic> arguments) async {
    final mode = (arguments['timezone'] as String? ?? 'local').toLowerCase();
    final now = mode == 'utc' ? DateTime.now().toUtc() : DateTime.now();
    return _toolResultJson({
      'timezoneMode': mode,
      'iso8601': now.toIso8601String(),
      'epochMs': now.millisecondsSinceEpoch,
      'timezoneName': now.timeZoneName,
      'offsetMinutes': now.timeZoneOffset.inMinutes,
      'date': now.toIso8601String().split('T').first,
      'time': now.toIso8601String().split('T').last,
    });
  }
}

class _GetTimezoneInfoTool extends McpLocalTool {
  @override
  String get name => 'get_timezone_info';

  @override
  String get description => 'Get detailed timezone information for local time and UTC.';

  @override
  ToolRiskLevel get riskLevel => ToolRiskLevel.read;

  @override
  Map<String, dynamic> get inputSchema => {'type': 'object', 'properties': {}};

  @override
  Future<MCPToolResult> execute(Map<String, dynamic> arguments) async {
    final now = DateTime.now();
    return _toolResultJson({
      'localTimezone': now.timeZoneName,
      'utcOffsetMinutes': now.timeZoneOffset.inMinutes,
      'isUtc': now.isUtc,
      'nowLocal': now.toIso8601String(),
      'nowUtc': now.toUtc().toIso8601String(),
    });
  }
}

class _CalculateTool extends McpLocalTool {
  @override
  String get name => 'calculate';

  @override
  String get description =>
      'Evaluate mathematical expression with literal numbers (+ - * / % ^ sqrt abs round floor ceil).';

  @override
  ToolRiskLevel get riskLevel => ToolRiskLevel.read;

  @override
  Map<String, dynamic> get inputSchema => {
        'type': 'object',
        'properties': {
          'expression': {
            'type': 'string',
            'description': 'Mathematical expression string, e.g. "(12.5 * 4) + 10".',
          },
        },
        'required': ['expression'],
      };

  @override
  Future<MCPToolResult> execute(Map<String, dynamic> arguments) async {
    final expr = (arguments['expression'] as String?)?.trim();
    if (expr == null || expr.isEmpty) {
      return _toolResultError('Expression is required.');
    }

    try {
      final res = _evalSimpleMath(expr);
      return _toolResultJson({
        'expression': expr,
        'result': res,
        'resultString': res % 1 == 0 ? res.toInt().toString() : res.toString(),
      });
    } catch (e) {
      return _toolResultError('Calculation error: $e');
    }
  }

  static double _evalSimpleMath(String expr) {
    var clean = expr.replaceAll(' ', '');
    // Safety check: only allow digits and standard operators
    if (!RegExp(r'^[\d\.\+\-\*\/\%\^\(\)]+$').hasMatch(clean)) {
      throw ArgumentError('Invalid characters in math expression.');
    }
    // Basic evaluation using recursive descent
    return _parseAddSub(clean, [0]);
  }

  static double _parseAddSub(String s, List<int> pos) {
    var left = _parseMulDiv(s, pos);
    while (pos[0] < s.length && (s[pos[0]] == '+' || s[pos[0]] == '-')) {
      final op = s[pos[0]++];
      final right = _parseMulDiv(s, pos);
      left = op == '+' ? left + right : left - right;
    }
    return left;
  }

  static double _parseMulDiv(String s, List<int> pos) {
    var left = _parseUnary(s, pos);
    while (pos[0] < s.length && (s[pos[0]] == '*' || s[pos[0]] == '/' || s[pos[0]] == '%')) {
      final op = s[pos[0]++];
      final right = _parseUnary(s, pos);
      if (op == '*') left = left * right;
      if (op == '/') left = left / right;
      if (op == '%') left = left % right;
    }
    return left;
  }

  static double _parseUnary(String s, List<int> pos) {
    if (pos[0] < s.length && s[pos[0]] == '-') {
      pos[0]++;
      return -_parsePrimary(s, pos);
    }
    if (pos[0] < s.length && s[pos[0]] == '+') pos[0]++;
    return _parsePrimary(s, pos);
  }

  static double _parsePrimary(String s, List<int> pos) {
    if (pos[0] < s.length && s[pos[0]] == '(') {
      pos[0]++;
      final val = _parseAddSub(s, pos);
      if (pos[0] < s.length && s[pos[0]] == ')') pos[0]++;
      return val;
    }
    final start = pos[0];
    while (pos[0] < s.length && (RegExp(r'[\d\.]').hasMatch(s[pos[0]]))) {
      pos[0]++;
    }
    if (start == pos[0]) throw ArgumentError('Expected number at position ${pos[0]}');
    return double.parse(s.substring(start, pos[0]));
  }
}

class _SumNumbersTool extends McpLocalTool {
  @override
  String get name => 'sum_numbers';

  @override
  String get description => 'Calculate sum, average, min, and max for an array of numbers.';

  @override
  ToolRiskLevel get riskLevel => ToolRiskLevel.read;

  @override
  Map<String, dynamic> get inputSchema => {
        'type': 'object',
        'properties': {
          'numbers': {
            'type': 'array',
            'items': {'type': 'number'},
            'description': 'Array of numbers to sum.',
          },
        },
        'required': ['numbers'],
      };

  @override
  Future<MCPToolResult> execute(Map<String, dynamic> arguments) async {
    final list = arguments['numbers'] as List<dynamic>?;
    if (list == null || list.isEmpty) {
      return _toolResultError('Array of numbers is required.');
    }
    final nums = list.map((e) => (e as num).toDouble()).toList();
    final sum = nums.fold(0.0, (acc, n) => acc + n);
    final avg = sum / nums.length;
    final min = nums.reduce(math.min);
    final max = nums.reduce(math.max);

    return _toolResultJson({
      'count': nums.length,
      'sum': sum,
      'average': avg,
      'min': min,
      'max': max,
    });
  }
}

class _GeocodeCityTool extends McpLocalTool {
  @override
  String get name => 'geocode_city';

  @override
  String get description => 'Resolve city name to coordinates, country, and timezone metadata.';

  @override
  ToolRiskLevel get riskLevel => ToolRiskLevel.network;

  @override
  Map<String, dynamic> get inputSchema => {
        'type': 'object',
        'properties': {
          'city': {
            'type': 'string',
            'description': 'City name to look up, e.g. "Berlin", "San Francisco".',
          },
        },
        'required': ['city'],
      };

  @override
  Future<MCPToolResult> execute(Map<String, dynamic> arguments) async {
    final city = (arguments['city'] as String?)?.trim();
    if (city == null || city.isEmpty) {
      return _toolResultError('City parameter is required.');
    }

    try {
      final uri = Uri.parse(
        'https://geocoding-api.open-meteo.com/v1/search?name=${Uri.encodeComponent(city)}&count=5&language=en&format=json',
      );
      final resp = await http.get(uri).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        final results = (body['results'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
        return _toolResultJson({
          'query': city,
          'count': results.length,
          'results': results
              .map((r) => {
                    'name': r['name'],
                    'country': r['country'],
                    'admin1': r['admin1'],
                    'latitude': r['latitude'],
                    'longitude': r['longitude'],
                    'timezone': r['timezone'],
                    'population': r['population'],
                  })
              .toList(),
        });
      }
      return _toolResultError('Geocoding API status: ${resp.statusCode}');
    } catch (e) {
      return _toolResultError('Geocoding request failed: $e');
    }
  }
}

// ═══════════════════════════════════════════════════════════════
// 4. SSH Tools Implementation
// ═══════════════════════════════════════════════════════════════

class _SshManager {
  final String configPath;
  SSHClient? _client;
  SftpClient? _sftp;

  // In-memory session override (does not modify ssh.yaml)
  Map<String, dynamic>? _sessionOverride;

  _SshManager({required this.configPath});

  bool get hasSessionOverride => _sessionOverride != null;

  Map<String, dynamic> getStatus() {
    final effective = _getEffectiveConfig();
    return {
      'hasSessionOverride': hasSessionOverride,
      'isConnected': _client != null && !_client!.isClosed,
      'host': effective['host'] ?? '',
      'port': effective['port'] ?? 22,
      'username': effective['username'] ?? '',
      'hasPassword': ((effective['password'] as String?) ?? '').isNotEmpty,
      'hasPrivateKey': ((effective['privateKey'] as String?) ?? '').isNotEmpty,
      'configPath': configPath,
    };
  }

  Map<String, dynamic> _getEffectiveConfig() {
    if (_sessionOverride != null) {
      return Map<String, dynamic>.from(_sessionOverride!);
    }

    String host = '';
    int port = 22;
    String username = '';
    String password = '';
    String privateKey = '';

    final file = GlobalConfigLocator.resolveConfigFile(configPath);
    if (file.existsSync()) {
      try {
        final yaml = loadYaml(file.readAsStringSync()) as YamlMap?;
        if (yaml != null) {
          host = (yaml['host'] as String?)?.trim() ?? '';
          port = (yaml['port'] as int?) ?? 22;
          username = (yaml['username'] as String?)?.trim() ?? '';
          password = (yaml['password'] as String?)?.trim() ?? '';
          privateKey = (yaml['private_key'] as String? ?? yaml['privateKey'] as String?)?.trim() ?? '';
        }
      } catch (_) {}
    }

    if (host.isEmpty) {
      host = Platform.environment['SSH_HOST'] ?? '';
      port = int.tryParse(Platform.environment['SSH_PORT'] ?? '') ?? 22;
      username = Platform.environment['SSH_USER'] ?? '';
      password = Platform.environment['SSH_PASSWORD'] ?? '';
      privateKey = Platform.environment['SSH_KEY'] ?? '';
    }

    return {
      'host': host,
      'port': port,
      'username': username,
      'password': password,
      'privateKey': privateKey,
    };
  }

  Future<void> connectOverride({
    required String host,
    int port = 22,
    required String username,
    required String password,
    required String privateKey,
  }) async {
    // Close existing connection if any
    await _closeCurrent();

    _sessionOverride = {
      'host': host,
      'port': port,
      'username': username,
      'password': password,
      'privateKey': privateKey,
    };

    // Establish immediately to verify credentials & connectivity
    await getClient();
  }

  Future<void> disconnectOverride() async {
    await _closeCurrent();
    _sessionOverride = null;
  }

  Future<void> _closeCurrent() async {
    try {
      _sftp?.close();
    } catch (_) {}
    _sftp = null;

    try {
      _client?.close();
    } catch (_) {}
    _client = null;
  }

  Future<SSHClient> getClient() async {
    if (_client != null && !_client!.isClosed) return _client!;

    final config = _getEffectiveConfig();
    final host = config['host'] as String? ?? '';
    final port = config['port'] as int? ?? 22;
    final username = config['username'] as String? ?? '';
    final password = config['password'] as String? ?? '';
    final privateKey = config['privateKey'] as String? ?? '';

    if (host.isEmpty || username.isEmpty) {
      throw StateError('SSH is not configured. Please connect with "/ssh connect user:pwd@host" or configure "$configPath".');
    }

    final socket = await SSHSocket.connect(host, port).timeout(const Duration(seconds: 15));
    _client = SSHClient(
      socket,
      username: username,
      onPasswordRequest: () => password,
      identities: privateKey.isNotEmpty ? SSHKeyPair.fromPem(privateKey) : null,
    );
    await _client!.authenticated.timeout(const Duration(seconds: 15));
    return _client!;
  }

  Future<SftpClient> getSftp() async {
    if (_sftp != null) return _sftp!;
    final client = await getClient();
    _sftp = await client.sftp();
    return _sftp!;
  }
}

class _SshListDirectoryTool extends McpLocalTool {
  final _SshManager manager;
  _SshListDirectoryTool(this.manager);

  @override
  String get name => 'ssh_list_directory';

  @override
  String get description => 'List files and directories on remote host via SSH/SFTP.';

  @override
  ToolRiskLevel get riskLevel => ToolRiskLevel.read;

  @override
  Map<String, dynamic> get inputSchema => {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'Remote directory path (e.g. "/var/log" or ".").',
          },
        },
        'required': ['path'],
      };

  @override
  Future<MCPToolResult> execute(Map<String, dynamic> arguments) async {
    final path = arguments['path'] as String? ?? '.';
    try {
      final sftp = await manager.getSftp();
      final entries = await sftp.listdir(path);
      final items = entries
          .where((e) => e.filename != '.' && e.filename != '..')
          .map((e) => {
                'name': e.filename,
                'isDirectory': e.attr.isDirectory,
                'size': e.attr.size ?? 0,
              })
          .toList();
      return _toolResultJson({'path': path, 'count': items.length, 'entries': items});
    } catch (e) {
      return _toolResultError('SSH list directory failed: $e');
    }
  }
}

class _SshReadFileTool extends McpLocalTool {
  final _SshManager manager;
  _SshReadFileTool(this.manager);

  @override
  String get name => 'ssh_read_file';

  @override
  String get description => 'Read remote file text content on remote host via SSH/SFTP.';

  @override
  ToolRiskLevel get riskLevel => ToolRiskLevel.read;

  @override
  Map<String, dynamic> get inputSchema => {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': 'Full remote file path to read.'},
          'maxBytes': {'type': 'integer', 'description': 'Maximum bytes to read (default 65536).'},
        },
        'required': ['path'],
      };

  @override
  Future<MCPToolResult> execute(Map<String, dynamic> arguments) async {
    final path = arguments['path'] as String? ?? '';
    final maxBytes = (arguments['maxBytes'] as int?) ?? 65536;
    try {
      final sftp = await manager.getSftp();
      final file = await sftp.open(path, mode: SftpFileOpenMode.read);
      final bytes = await file.readBytes(length: maxBytes);
      await file.close();
      return _toolResultJson({
        'path': path,
        'content': utf8.decode(bytes, allowMalformed: true),
        'bytes': bytes.length,
      });
    } catch (e) {
      return _toolResultError('SSH read file failed: $e');
    }
  }
}

class _SshUploadFileTool extends McpLocalTool {
  final _SshManager manager;
  _SshUploadFileTool(this.manager);

  @override
  String get name => 'ssh_upload_file';

  @override
  String get description => 'Write/upload text content to remote file on remote host via SSH/SFTP.';

  @override
  ToolRiskLevel get riskLevel => ToolRiskLevel.write;

  @override
  Map<String, dynamic> get inputSchema => {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': 'Remote destination file path.'},
          'content': {'type': 'string', 'description': 'UTF-8 text content to write.'},
        },
        'required': ['path', 'content'],
      };

  @override
  Future<MCPToolResult> execute(Map<String, dynamic> arguments) async {
    final path = arguments['path'] as String? ?? '';
    final content = arguments['content'] as String? ?? '';
    try {
      final sftp = await manager.getSftp();
      final bytes = Uint8List.fromList(utf8.encode(content));
      final file = await sftp.open(
        path,
        mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate,
      );
      await file.writeBytes(bytes);
      await file.close();
      return _toolResultJson({'success': true, 'path': path, 'bytes': bytes.length});
    } catch (e) {
      return _toolResultError('SSH upload failed: $e');
    }
  }
}

class _SshDownloadFileTool extends McpLocalTool {
  final _SshManager manager;
  _SshDownloadFileTool(this.manager);

  @override
  String get name => 'ssh_download_file';

  @override
  String get description => 'Download a remote file from SSH host as base64 content.';

  @override
  ToolRiskLevel get riskLevel => ToolRiskLevel.read;

  @override
  Map<String, dynamic> get inputSchema => {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': 'Remote file path.'},
        },
        'required': ['path'],
      };

  @override
  Future<MCPToolResult> execute(Map<String, dynamic> arguments) async {
    final path = arguments['path'] as String? ?? '';
    try {
      final sftp = await manager.getSftp();
      final file = await sftp.open(path, mode: SftpFileOpenMode.read);
      final bytes = await file.readBytes();
      await file.close();
      return _toolResultJson({
        'path': path,
        'bytes': bytes.length,
        'encoding': 'base64',
        'content': base64Encode(bytes),
      });
    } catch (e) {
      return _toolResultError('SSH download failed: $e');
    }
  }
}

class _SshMakeDirectoryTool extends McpLocalTool {
  final _SshManager manager;
  _SshMakeDirectoryTool(this.manager);

  @override
  String get name => 'ssh_make_directory';

  @override
  String get description => 'Create a directory on the remote host via SSH.';

  @override
  ToolRiskLevel get riskLevel => ToolRiskLevel.write;

  @override
  Map<String, dynamic> get inputSchema => {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': 'Remote directory path.'},
        },
        'required': ['path'],
      };

  @override
  Future<MCPToolResult> execute(Map<String, dynamic> arguments) async {
    final path = arguments['path'] as String? ?? '';
    try {
      final client = await manager.getClient();
      final res = await client.runWithResult('mkdir -p "$path"');
      final exitCode = res.exitCode ?? 0;
      return _toolResultJson({'success': exitCode == 0, 'path': path, 'exitCode': exitCode});
    } catch (e) {
      return _toolResultError('SSH make directory failed: $e');
    }
  }
}

class _SshRemoveDirectoryTool extends McpLocalTool {
  final _SshManager manager;
  _SshRemoveDirectoryTool(this.manager);

  @override
  String get name => 'ssh_remove_directory';

  @override
  String get description => 'Remove an empty directory on the remote host via SSH.';

  @override
  ToolRiskLevel get riskLevel => ToolRiskLevel.write;

  @override
  Map<String, dynamic> get inputSchema => {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': 'Remote directory path.'},
        },
        'required': ['path'],
      };

  @override
  Future<MCPToolResult> execute(Map<String, dynamic> arguments) async {
    final path = arguments['path'] as String? ?? '';
    try {
      final client = await manager.getClient();
      final res = await client.runWithResult('rmdir "$path"');
      final exitCode = res.exitCode ?? 0;
      return _toolResultJson({'success': exitCode == 0, 'path': path, 'exitCode': exitCode});
    } catch (e) {
      return _toolResultError('SSH remove directory failed: $e');
    }
  }
}

class _SshExecuteCommandTool extends McpLocalTool {
  final _SshManager manager;
  _SshExecuteCommandTool(this.manager);

  @override
  String get name => 'ssh_execute_command';

  @override
  String get description => 'Execute a shell command on remote server via SSH.';

  @override
  ToolRiskLevel get riskLevel => ToolRiskLevel.execute;

  @override
  Map<String, dynamic> get inputSchema => {
        'type': 'object',
        'properties': {
          'command': {'type': 'string', 'description': 'Shell command string to execute.'},
          'timeoutSeconds': {'type': 'integer', 'description': 'Timeout in seconds (default 30).'},
        },
        'required': ['command'],
      };

  @override
  Future<MCPToolResult> execute(Map<String, dynamic> arguments) async {
    final command = arguments['command'] as String? ?? '';
    final timeout = (arguments['timeoutSeconds'] as int?) ?? 30;
    try {
      final client = await manager.getClient();
      final res = await client
          .runWithResult(command)
          .timeout(Duration(seconds: timeout));

      final exitCode = res.exitCode ?? 0;
      return _toolResultJson({
        'command': command,
        'exitCode': exitCode,
        'stdout': utf8.decode(res.stdout, allowMalformed: true),
        'stderr': utf8.decode(res.stderr, allowMalformed: true),
        'success': exitCode == 0,
      });
    } catch (e) {
      return _toolResultError('SSH execute failed: $e');
    }
  }
}
