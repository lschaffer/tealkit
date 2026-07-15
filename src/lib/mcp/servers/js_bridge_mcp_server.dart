import '../../services/js_tool_library_service.dart';
import '../../services/js_tool_runtime_service.dart';
import '../internal_mcp_server.dart';

class JsBridgeMcpServer extends InternalMcpServer {
  final List<McpToolDescriptor> _dynamicTools = [];
  final Map<String, String> _toolNameToId = {};

  @override
  String get type => 'js_bridge';

  @override
  String get displayName => 'JavaScript bridge';

  @override
  String get description => 'Run user-defined JavaScript MCP tools from the local JS tool library.';

  @override
  String get iconName => 'javascript';

  @override
  Map<String, dynamic> get initParamSchema => {
    'type': 'object',
    'properties': {
      'allowInactive': {
        'type': 'boolean',
        'description': 'Include inactive tools in list_js_tools output. Execution still requires active status.',
        'default': false,
      },
    },
    'required': [],
  };

  @override
  Map<String, dynamic> get defaultInitParams => {'allowInactive': false};

  @override
  String get defaultSystemPrompt =>
      'You can call user-created JavaScript tools. First use list_js_tools to discover available tool names and schemas. '
      'Then call either run_js_tool (by name/id) or the dynamic tool directly. Always pass arguments as a JSON object.';

  @override
  List<McpToolDescriptor> get tools => [
    const McpToolDescriptor(
      name: 'list_js_tools',
      description: 'List saved JavaScript bridge tools currently available for execution.',
      inputSchema: {'type': 'object', 'properties': {}},
    ),
    const McpToolDescriptor(
      name: 'run_js_tool',
      description: 'Run a JavaScript bridge tool by toolId or toolName.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'toolId': {'type': 'string', 'description': 'Saved JS tool id.'},
          'toolName': {'type': 'string', 'description': 'Saved JS tool name.'},
          'args': {'type': 'object', 'description': 'Arguments passed to generatedTool.execute(args).'},
          'timeoutMs': {'type': 'integer', 'description': 'Execution timeout in milliseconds (default 8000, max 15000).'},
        },
        'required': [],
      },
    ),
    ..._dynamicTools,
  ];

  @override
  Future<void> initialize(Map<String, dynamic> initParams) async {
    await JsToolLibraryService.instance.load();
    _rebuildDynamicTools();
  }

  void _rebuildDynamicTools() {
    _dynamicTools.clear();
    _toolNameToId.clear();

    final usedNames = <String>{'list_js_tools', 'run_js_tool'};
    for (final tool in JsToolLibraryService.instance.activeTools) {
      var dynamicName = 'js_${_sanitizeName(tool.name)}';
      if (dynamicName == 'js_' || dynamicName == 'js') {
        dynamicName = 'js_tool';
      }
      if (usedNames.contains(dynamicName)) {
        dynamicName = '${dynamicName}_${tool.id.substring(0, 6)}';
      }
      usedNames.add(dynamicName);

      _toolNameToId[dynamicName] = tool.id;
      _dynamicTools.add(
        McpToolDescriptor(
          name: dynamicName,
          description: tool.description.isNotEmpty ? tool.description : 'User-defined JS tool: ${tool.name}',
          inputSchema: tool.inputSchema.isNotEmpty ? tool.inputSchema : const {'type': 'object', 'properties': {}},
        ),
      );
    }
  }

  String _sanitizeName(String input) {
    final lower = input.trim().toLowerCase();
    return lower.replaceAll(RegExp(r'[^a-z0-9_]+'), '_').replaceAll(RegExp(r'_+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
  }

  @override
  Future<Map<String, dynamic>> executeTool(String toolName, Map<String, dynamic> arguments) async {
    if (toolName == 'list_js_tools') {
      return _listTools();
    }
    if (toolName == 'run_js_tool') {
      return _runByExplicitCall(arguments);
    }

    final dynamicToolId = _toolNameToId[toolName];
    if (dynamicToolId != null) {
      return _runById(dynamicToolId, arguments);
    }

    return {'error': 'Unknown tool: $toolName'};
  }

  Map<String, dynamic> _listTools() {
    final tools = JsToolLibraryService.instance.tools;
    return {
      'count': tools.length,
      'activeCount': tools.where((t) => t.isActive).length,
      'tools': tools
          .map(
            (t) => {
              'id': t.id,
              'name': t.name,
              'description': t.description,
              'isActive': t.isActive,
              'inputSchema': t.inputSchema,
              'updatedAt': t.updatedAt.toIso8601String(),
            },
          )
          .toList(),
    };
  }

  Future<Map<String, dynamic>> _runByExplicitCall(Map<String, dynamic> arguments) async {
    final toolId = (arguments['toolId'] as String?)?.trim();
    final toolName = (arguments['toolName'] as String?)?.trim();
    final args = (arguments['args'] is Map) ? (arguments['args'] as Map).cast<String, dynamic>() : Map<String, dynamic>.from(arguments)
      ..removeWhere((k, _) => k == 'toolId' || k == 'toolName' || k == 'timeoutMs');
    final timeoutMs = ((arguments['timeoutMs'] as int?) ?? 8000).clamp(250, 15000);

    JsToolDefinition? tool;
    if (toolId != null && toolId.isNotEmpty) {
      tool = JsToolLibraryService.instance.findById(toolId);
    } else if (toolName != null && toolName.isNotEmpty) {
      tool = JsToolLibraryService.instance.findByName(toolName);

      tool ??= () {
        final dynamicToolId = _toolNameToId[toolName];
        if (dynamicToolId == null) return null;
        return JsToolLibraryService.instance.findById(dynamicToolId);
      }();

      tool ??= () {
        final lower = toolName.toLowerCase();
        final all = JsToolLibraryService.instance.tools;
        for (final candidate in all) {
          if (candidate.name.toLowerCase() == lower) return candidate;
        }
        return null;
      }();
    }

    if (tool == null) {
      return {'error': 'Tool not found. Provide toolId or toolName from list_js_tools.'};
    }
    return _runTool(tool, args: args, timeoutMs: timeoutMs);
  }

  Future<Map<String, dynamic>> _runById(String toolId, Map<String, dynamic> args) async {
    final tool = JsToolLibraryService.instance.findById(toolId);
    if (tool == null) {
      return {'error': 'Tool not found: $toolId'};
    }
    return _runTool(tool, args: args, timeoutMs: 8000);
  }

  Future<Map<String, dynamic>> _runTool(JsToolDefinition tool, {required Map<String, dynamic> args, required int timeoutMs}) async {
    if (!tool.isActive) {
      return {'error': 'Tool is disabled: ${tool.name}'};
    }

    final result = await JsToolRuntimeService.instance.testExecute(jsCode: tool.jsCode, args: args, timeoutMs: timeoutMs);
    if (!result.success) {
      return {
        'error': result.error ?? 'Execution failed',
        'toolId': tool.id,
        'toolName': tool.name,
        'logs': result.logs,
        'durationMs': result.durationMs,
      };
    }

    return {
      'success': true,
      'toolId': tool.id,
      'toolName': tool.name,
      'result': result.result,
      'logs': result.logs,
      'durationMs': result.durationMs,
    };
  }
}
