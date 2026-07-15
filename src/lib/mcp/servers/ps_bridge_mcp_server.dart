import 'dart:convert';
import 'dart:io';

import '../internal_mcp_server.dart';
import '../../services/app_logger.dart';
import '../../services/powershell_script_service.dart';

/// Windows-only MCP server that exposes user-saved PowerShell scripts as MCP tools.
///
/// Built-in tools:
///   • list_ps_scripts  – discover available scripts
///   • run_ps_script    – execute a script by id or name (with optional extra args)
///
/// Plus one dynamic tool per saved script: ps_<sanitised_name>
class PsBridgeMcpServer extends InternalMcpServer {
  final List<McpToolDescriptor> _dynamicTools = [];
  final Map<String, String> _toolNameToId = {}; // dynamic tool name → script id

  int _timeoutSeconds = 60;

  @override
  String get type => 'ps_bridge';

  @override
  String get displayName => 'PowerShell tools';

  @override
  String get description => 'Run user-saved PowerShell scripts on this Windows machine.';

  @override
  String get iconName => 'terminal';

  @override
  Map<String, dynamic> get initParamSchema => {
    'type': 'object',
    'properties': {
      'timeoutSeconds': {'type': 'integer', 'description': 'Execution timeout per script call in seconds (default 60).', 'default': 60},
    },
    'required': [],
  };

  @override
  Map<String, dynamic> get defaultInitParams => {'timeoutSeconds': 60};

  @override
  String get defaultSystemPrompt =>
      'You can run user-saved PowerShell scripts on this Windows machine. '
      'First call list_ps_scripts to discover available scripts. '
      'Then call run_ps_script or the dynamic ps_<name> tool directly. '
      'To create a new script: ask the user to describe it and store it '
      'via the TealKit PowerShell tool generator.';

  @override
  Future<void> initialize(Map<String, dynamic> initParams) async {
    _timeoutSeconds = (initParams['timeoutSeconds'] as int?) ?? 60;

    await PowershellScriptService.instance.load();
    _rebuildDynamicTools();
  }

  void _rebuildDynamicTools() {
    _dynamicTools.clear();
    _toolNameToId.clear();

    final usedNames = <String>{'list_ps_scripts', 'run_ps_script'};

    for (final script in PowershellScriptService.instance.scripts) {
      var dynName = 'ps_${_sanitize(script.name)}';
      if (dynName == 'ps_' || dynName == 'ps') dynName = 'ps_script';
      if (usedNames.contains(dynName)) {
        dynName = '${dynName}_${script.id.substring(0, 6)}';
      }
      usedNames.add(dynName);
      _toolNameToId[dynName] = script.id;

      // Parse the param() block so the AI sees individual typed parameters
      // instead of a raw args string.
      final parsedSchema = _parseParamSchema(script.content);
      final schema =
          parsedSchema ??
          const {
            'type': 'object',
            'properties': {
              'args': {'type': 'string', 'description': 'Command-line arguments, e.g. -Folder C:\\temp -Months 6'},
            },
            'required': [],
          };

      // Inject timeoutSeconds into every dynamic tool schema so callers
      // can override the default timeout at the individual call level.
      final schemaWithTimeout = Map<String, dynamic>.from(schema);
      final props = Map<String, dynamic>.from((schemaWithTimeout['properties'] as Map<String, dynamic>?) ?? {});
      props['timeoutSeconds'] = {'type': 'integer', 'description': 'Override execution timeout in seconds for this call.'};
      schemaWithTimeout['properties'] = props;

      _dynamicTools.add(
        McpToolDescriptor(
          name: dynName,
          description: script.description.isNotEmpty ? script.description : 'PowerShell script: ${script.name}',
          inputSchema: schemaWithTimeout,
        ),
      );
    }
  }

  String _sanitize(String s) =>
      s.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]+'), '_').replaceAll(RegExp(r'_+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');

  // ─── Tools list ──────────────────────────────────────────────────────────

  @override
  List<McpToolDescriptor> get tools => [
    const McpToolDescriptor(
      name: 'list_ps_scripts',
      description: 'List all saved PowerShell scripts available on this Windows machine.',
      inputSchema: {'type': 'object', 'properties': {}},
    ),
    const McpToolDescriptor(
      name: 'run_ps_script',
      description: 'Execute a saved PowerShell script by id or name with optional command-line arguments.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'scriptId': {'type': 'string', 'description': 'Script ID (from list_ps_scripts).'},
          'scriptName': {'type': 'string', 'description': 'Script name (alternative to scriptId).'},
          'args': {'type': 'string', 'description': 'Optional space-separated command-line arguments.'},
          'timeoutSeconds': {'type': 'integer', 'description': 'Override timeout for this call.'},
        },
        'required': [],
      },
    ),
    ..._dynamicTools,
  ];

  // ─── Dispatch ────────────────────────────────────────────────────────────

  @override
  Future<Map<String, dynamic>> executeTool(String toolName, Map<String, dynamic> arguments) async {
    switch (toolName) {
      case 'list_ps_scripts':
        return _listScripts(arguments);
      case 'run_ps_script':
        return _runScript(arguments);
      default:
        final id = _toolNameToId[toolName];
        if (id != null) {
          // Extract timeoutSeconds before building the PS arg string so it
          // is not forwarded as a -timeoutSeconds parameter to PowerShell.
          final overrideTimeout = arguments['timeoutSeconds'] as int?;
          final scriptArgs = Map<String, dynamic>.from(arguments)..remove('timeoutSeconds');

          // If the schema has individual typed params, build the PS arg string
          // from the map. If schema only has 'args', pass it through directly.
          final String? argsStr;
          if (scriptArgs.isEmpty) {
            argsStr = null;
          } else if (scriptArgs.length == 1 && scriptArgs.containsKey('args')) {
            argsStr = scriptArgs['args'] as String?;
          } else {
            argsStr = _buildArgsString(scriptArgs);
          }
          return _runById(id, argsStr, overrideTimeout);
        }
        return {'error': 'Unknown tool: $toolName'};
    }
  }

  // ─── list_ps_scripts ─────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _listScripts(Map<String, dynamic> _) async {
    await PowershellScriptService.instance.load();
    _rebuildDynamicTools();
    final scripts = PowershellScriptService.instance.scripts;
    return {
      'scripts': scripts.map((s) => {'id': s.id, 'name': s.name, 'description': s.description}).toList(),
      'count': scripts.length,
    };
  }

  // ─── run_ps_script ────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _runScript(Map<String, dynamic> args) async {
    final script = _resolve(args);
    if (script == null) {
      return {'error': 'Script not found. Provide scriptId or scriptName.'};
    }
    final argsStr = args['args'] as String?;
    final overrideTimeout = args['timeoutSeconds'] as int?;
    return _runById(script.id, argsStr, overrideTimeout);
  }

  Future<Map<String, dynamic>> _runById(String id, String? argsStr, int? overrideTimeoutSeconds) async {
    final script = PowershellScriptService.instance.findById(id);
    if (script == null) return {'error': 'Script not found: $id'};

    final timeout = Duration(seconds: overrideTimeoutSeconds ?? _timeoutSeconds);

    Directory? tempDir;
    try {
      tempDir = await Directory.systemTemp.createTemp('ps_bridge_');
      final tempFile = File('${tempDir.path}\\script.ps1');

      // Write script as-is — param()/[CmdletBinding()] must be the first
      // statement in the file for parameter binding to work.
      await tempFile.writeAsString(script.content, encoding: utf8);

      // Use -Command wrapper so the UTF-8 encoding is set BEFORE the script
      // starts (fixing encoding for [CmdletBinding()] scripts) and args are
      // passed inline without naive whitespace-splitting.
      final safePath = tempFile.path.replaceAll("'", "''");
      final argsPart = argsStr != null && argsStr.isNotEmpty ? ' $argsStr' : '';
      final fullCmd =
          '[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; '
          '\$OutputEncoding=[System.Text.Encoding]::UTF8; '
          "& '$safePath'$argsPart";

      final psArgs = <String>['-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', fullCmd];

      final ps = await Process.run(
        'powershell.exe',
        psArgs,
        runInShell: false,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(timeout);

      return {'success': ps.exitCode == 0, 'stdout': ps.stdout as String, 'stderr': ps.stderr as String, 'exitCode': ps.exitCode};
    } catch (e) {
      log.error('[PsBridge] executeTool error for script $id: $e');
      return {'success': false, 'error': e.toString()};
    } finally {
      tempDir?.delete(recursive: true).catchError((_) => Directory(''));
    }
  }

  // ─── Helper ───────────────────────────────────────────────────────────────

  /// Parses the `param()` block of a PowerShell script and returns a JSON
  /// Schema object with one typed property per parameter.
  Map<String, dynamic>? _parseParamSchema(String content) {
    final lc = content.toLowerCase();
    final paramIdx = lc.indexOf('param');
    if (paramIdx < 0) return null;
    final openParen = content.indexOf('(', paramIdx);
    if (openParen < 0) return null;

    // Extract balanced content of param(...)
    int depth = 0;
    int i = openParen;
    while (i < content.length) {
      if (content[i] == '(') {
        depth++;
      } else if (content[i] == ')') {
        depth--;
        if (depth == 0) break;
      }
      i++;
    }
    final paramBlock = content.substring(openParen + 1, i);

    // Split on top-level commas (skip commas inside brackets/parens)
    final rawParams = <String>[];
    int parenDepth = 0;
    int start = 0;
    for (int j = 0; j < paramBlock.length; j++) {
      final c = paramBlock[j];
      if (c == '(' || c == '[') {
        parenDepth++;
      } else if (c == ')' || c == ']') {
        parenDepth--;
      } else if (c == ',' && parenDepth == 0) {
        rawParams.add(paramBlock.substring(start, j));
        start = j + 1;
      }
    }
    rawParams.add(paramBlock.substring(start));

    final properties = <String, dynamic>{};
    for (final raw in rawParams) {
      final p = raw.trim();
      if (p.isEmpty) continue;

      // Param name
      final nameMatch = RegExp(r'\$([A-Za-z][A-Za-z0-9_]*)').firstMatch(p);
      if (nameMatch == null) continue;
      final name = nameMatch.group(1)!;

      // Type annotation — last [type] directly before $Name
      final typeMatches = RegExp(r'\[([A-Za-z][A-Za-z0-9.]*)\]\s*\$', caseSensitive: false).allMatches(p).toList();
      final psType = typeMatches.isNotEmpty ? typeMatches.last.group(1)!.toLowerCase() : null;

      // ValidateSet → enum values
      final vsMatch = RegExp(r'\[ValidateSet\(([^)]+)\)\]', caseSensitive: false).firstMatch(p);
      List<dynamic>? enumValues;
      if (vsMatch != null) {
        enumValues = vsMatch.group(1)!.split(',').map((v) {
          final t = v.trim().replaceAll(RegExp(r"""^["']|["']$"""), '');
          return num.tryParse(t) ?? t;
        }).toList();
      }

      // Map to JSON schema type
      final Map<String, dynamic> prop = {};
      switch (psType) {
        case 'int':
        case 'int32':
        case 'int64':
        case 'long':
        case 'uint32':
          prop['type'] = 'integer';
        case 'double':
        case 'float':
        case 'decimal':
        case 'single':
          prop['type'] = 'number';
        case 'bool':
        case 'boolean':
          prop['type'] = 'boolean';
        case 'switch':
        case 'switchparameter':
          prop['type'] = 'boolean';
          prop['description'] = 'Switch — pass true to enable';
        default:
          prop['type'] = 'string';
      }
      if (enumValues != null) prop['enum'] = enumValues;

      // Default value
      final defMatch = RegExp(r'\$[A-Za-z][A-Za-z0-9_]*\s*=\s*(.+)$').firstMatch(p);
      if (defMatch != null) {
        var defStr = defMatch.group(1)!.trim().replaceAll(RegExp(r',\s*$'), '').trim();
        defStr = defStr.replaceAll(RegExp(r'''^["'`]|["'`]$'''), '');
        if (defStr == r'$true') {
          prop['default'] = true;
        } else if (defStr == r'$false') {
          prop['default'] = false;
        } else {
          prop['default'] = num.tryParse(defStr) ?? defStr;
        }
      }

      properties[name] = prop;
    }

    if (properties.isEmpty) return null;
    return {'type': 'object', 'properties': properties, 'required': []};
  }

  /// Converts a named-param map to a PowerShell argument string.
  /// e.g. {Folder: 'c:\\temp', Months: 12} → "-Folder 'c:\\temp' -Months 12"
  String _buildArgsString(Map<String, dynamic> params) {
    final parts = <String>[];
    for (final entry in params.entries) {
      final key = entry.key;
      final value = entry.value;
      if (value == null) continue;
      if (value is bool) {
        if (value) parts.add('-$key'); // false → omit switch
      } else if (value is num) {
        parts.add('-$key $value');
      } else {
        final escaped = value.toString().replaceAll("'", "''");
        parts.add("-$key '$escaped'");
      }
    }
    return parts.join(' ');
  }

  PowershellScript? _resolve(Map<String, dynamic> args) {
    final svc = PowershellScriptService.instance;
    final id = args['scriptId'] as String?;
    final name = args['scriptName'] as String?;
    if (id != null && id.isNotEmpty) return svc.findById(id);
    if (name != null && name.isNotEmpty) {
      try {
        return svc.scripts.firstWhere((s) => s.name.toLowerCase() == name.toLowerCase());
      } catch (_) {
        return null;
      }
    }
    return null;
  }
}
