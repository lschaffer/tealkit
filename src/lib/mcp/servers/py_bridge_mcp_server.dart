import '../internal_mcp_server.dart';
import '../../models/py_tool_definition.dart';
import '../../services/app_logger.dart';
import '../../services/py_tool_library_service.dart';
import '../../services/py_tool_runtime_service.dart';

/// Desktop-only MCP server that exposes user-generated Python tools as MCP tools.
///
/// Three built-in meta-tools:
///   • list_py_tools    – discover available tools
///   • init_py_tool     – (re)create venv & install deps for a tool
///   • run_py_tool      – run by id/name
///
/// Plus one dynamic tool per active PyToolDefinition: py_sanitised_name
class PyBridgeMcpServer extends InternalMcpServer {
  final List<McpToolDescriptor> _dynamicTools = [];
  final Map<String, String> _toolNameToId = {}; // dynamic tool name → tool id

  @override
  String get type => 'py_bridge';

  @override
  String get displayName => 'Python tools';

  @override
  String get description =>
      'Run user-generated Python tools on this desktop machine.';

  @override
  String get iconName => 'terminal';

  @override
  Map<String, dynamic> get initParamSchema => {
    'type': 'object',
    'properties': {
      'allowInactive': {
        'type': 'boolean',
        'description': 'Include inactive tools in list_py_tools output.',
        'default': false,
      },
      'timeoutSeconds': {
        'type': 'integer',
        'description':
            'Execution timeout per tool call in seconds (default 60).',
        'default': 60,
      },
    },
    'required': [],
  };

  @override
  Map<String, dynamic> get defaultInitParams => {
    'allowInactive': false,
    'timeoutSeconds': 60,
  };

  @override
  String get defaultSystemPrompt =>
      'You can run Python code on this machine. '
      'Use run_py_tool with toolName: "run_python" to execute ANY ad-hoc Python '
      'script — great for one-off data processing, file generation (PDF, CSV, '
      'JSON), calculations, or scripts from skill instructions. '
      'First call list_py_tools to see all available tools. '
      'Use init_py_tool before first run of a tool to create its virtualenv. '
      'To create a reusable named tool: ask the user to describe it, '
      'generate the code, and store it via the TealKit Python tool generator. '
      'IMPORTANT: When a skill or instruction provides Python code examples, '
      'DO NOT just output them as text — EXECUTE them via run_py_tool!';

  bool _allowInactive = false;
  int _timeoutSeconds = 60;

  @override
  Future<void> initialize(Map<String, dynamic> initParams) async {
    _allowInactive = initParams['allowInactive'] as bool? ?? false;
    _timeoutSeconds = (initParams['timeoutSeconds'] as int?) ?? 60;

    await PyToolLibraryService.instance.load();
    _rebuildDynamicTools();
  }

  void _rebuildDynamicTools() {
    _dynamicTools.clear();
    _toolNameToId.clear();

    final usedNames = <String>{'list_py_tools', 'init_py_tool', 'run_py_tool'};
    final source = _allowInactive
        ? PyToolLibraryService.instance.tools
        : PyToolLibraryService.instance.activeTools;

    for (final tool in source) {
      var dynName = 'py_${_sanitize(tool.name)}';
      if (dynName == 'py_' || dynName == 'py') dynName = 'py_tool';
      if (usedNames.contains(dynName)) {
        dynName = '${dynName}_${tool.id.substring(0, 6)}';
      }
      usedNames.add(dynName);
      _toolNameToId[dynName] = tool.id;

      // Inject timeoutSeconds into every dynamic tool schema so callers
      // can override the default timeout at the individual call level.
      final baseSchema = tool.inputSchema.isNotEmpty
          ? tool.inputSchema
          : const <String, dynamic>{
              'type': 'object',
              'properties': <String, dynamic>{},
            };
      final schemaWithTimeout = Map<String, dynamic>.from(baseSchema);
      final props = Map<String, dynamic>.from(
        (schemaWithTimeout['properties'] as Map<String, dynamic>?) ?? {},
      );
      props['timeoutSeconds'] = {
        'type': 'integer',
        'description': 'Override execution timeout in seconds for this call.',
      };
      schemaWithTimeout['properties'] = props;

      _dynamicTools.add(
        McpToolDescriptor(
          name: dynName,
          description: tool.description.isNotEmpty
              ? tool.description
              : 'Python tool: ${tool.name}',
          inputSchema: schemaWithTimeout,
        ),
      );
    }
  }

  String _sanitize(String s) => s
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9_]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');

  // ─── Tools list ──────────────────────────────────────────────────────────

  @override
  List<McpToolDescriptor> get tools => [
    const McpToolDescriptor(
      name: 'list_py_tools',
      description: 'List all saved Python tools available on this machine.',
      inputSchema: {'type': 'object', 'properties': {}},
    ),
    const McpToolDescriptor(
      name: 'init_py_tool',
      description:
          'Initialise (or re-initialise) the virtual environment for a Python tool. '
          'Must be called at least once before the first run_py_tool call.',
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
        },
        'required': [],
      },
    ),
    const McpToolDescriptor(
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
            'description':
                'Arguments forwarded to the Python execute(args) function.',
          },
          'timeoutSeconds': {
            'type': 'integer',
            'description': 'Override timeout for this call.',
          },
        },
        'required': [],
      },
    ),
    ..._dynamicTools,
  ];

  // ─── Dispatch ────────────────────────────────────────────────────────────

  @override
  Future<Map<String, dynamic>> executeTool(
    String toolName,
    Map<String, dynamic> arguments,
  ) async {
    switch (toolName) {
      case 'list_py_tools':
        return _listTools(arguments);
      case 'init_py_tool':
        return _initTool(arguments);
      case 'run_py_tool':
        return _runTool(arguments);
      default:
        // Dynamic py_<name> tools
        final id = _toolNameToId[toolName];
        if (id != null) {
          // Extract timeoutSeconds before forwarding args to the Python tool.
          final overrideTimeout = arguments['timeoutSeconds'] as int?;
          final toolArgs = Map<String, dynamic>.from(arguments)
            ..remove('timeoutSeconds');
          return _runById(id, toolArgs, overrideTimeout);
        }
        return {'error': 'Unknown tool: $toolName'};
    }
  }

  // ─── list_py_tools ────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _listTools(Map<String, dynamic> _) async {
    final lib = PyToolLibraryService.instance;
    await lib.load();
    _rebuildDynamicTools();
    final source = _allowInactive ? lib.tools : lib.activeTools;
    return {
      'tools': source
          .map(
            (t) => {
              'id': t.id,
              'name': t.name,
              'description': t.description,
              'venvReady': t.venvReady,
              'isActive': t.isActive,
              'inputSchema': t.inputSchema,
            },
          )
          .toList(),
      'count': source.length,
    };
  }

  // ─── init_py_tool ─────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _initTool(Map<String, dynamic> args) async {
    final def = _resolve(args);
    if (def == null) {
      return {'error': 'Tool not found. Provide toolId or toolName.'};
    }

    final messages = <String>[];
    final err = await PyToolRuntimeService.instance.initTool(
      def,
      onProgress: (p) => messages.add(p.message),
    );

    if (err != null) {
      return {'success': false, 'error': err, 'log': messages};
    }
    return {
      'success': true,
      'message': 'Venv ready for "${def.name}"',
      'log': messages,
    };
  }

  // ─── run_py_tool ──────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _runTool(Map<String, dynamic> args) async {
    final def = _resolve(args);
    if (def == null) {
      return {'error': 'Tool not found. Provide toolId or toolName.'};
    }
    final callArgs = args['args'] as Map<String, dynamic>? ?? {};
    final overrideTimeout = args['timeoutSeconds'] as int?;
    return _runById(def.id, callArgs, overrideTimeout);
  }

  Future<Map<String, dynamic>> _runById(
    String id,
    Map<String, dynamic> args,
    int? overrideTimeoutSeconds,
  ) async {
    final def = PyToolLibraryService.instance.getById(id);
    if (def == null) return {'error': 'Tool not found: $id'};

    final timeout = Duration(
      seconds: overrideTimeoutSeconds ?? _timeoutSeconds,
    );
    try {
      final result = await PyToolRuntimeService.instance.execute(
        def,
        args,
        timeout: timeout,
      );
      return {'success': true, 'result': result};
    } on PyToolError catch (e) {
      log.warning('[PyBridge] executeTool error: $e');
      return {'success': false, 'error': e.message};
    } catch (e) {
      log.error('[PyBridge] executeTool unexpected: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  // ─── Helper ───────────────────────────────────────────────────────────────

  PyToolDefinition? _resolve(Map<String, dynamic> args) {
    final lib = PyToolLibraryService.instance;
    final id = args['toolId'] as String?;
    final name = args['toolName'] as String?;
    if (id != null && id.isNotEmpty) return lib.getById(id);
    if (name != null && name.isNotEmpty) return lib.getByName(name);
    return null;
  }
}
