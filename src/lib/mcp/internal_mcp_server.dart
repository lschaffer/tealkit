/// Base class for all internal ("mini") MCP servers built into the app.
///
/// Each internal MCP server provides built-in tools that can be used by
/// agentic tasks without requiring an external server. They follow the
/// MCP tool/prompt/resource pattern but execute locally in-process.
///
/// Subclasses must implement:
///   • [type]        — unique identifier (e.g. 'weather', 'gmail', 'doc-search')
///   • [displayName] — human-readable name shown in UI
///   • [description] — what this MCP server does
///   • [tools]       — list of available tools with their schemas
///   • [executeTool] — run a specific tool with parameters
///   • [initParamSchema] — JSON Schema for the init parameters this MCP needs
abstract class InternalMcpServer {
  /// Unique type identifier, e.g. 'weather', 'gmail', 'doc-search', 'website-search'.
  String get type;

  /// Human-readable display name.
  String get displayName;

  /// Short description of what this MCP server does.
  String get description;

  /// Icon name (Material Icons) for UI display.
  String get iconName;

  /// JSON Schema describing the init parameters this MCP server requires.
  /// Example for weather: { "location": { "type": "string", "description": "City name or lat,lng" } }
  Map<String, dynamic> get initParamSchema;

  /// Default init parameter values.
  Map<String, dynamic> get defaultInitParams;

  /// Default system prompt tailored for this MCP server.
  ///
  /// This prompt instructs the LLM how to effectively use the tools
  /// provided by this MCP. Shown in the task editor and injected into
  /// the conversation when this MCP is active.
  String get defaultSystemPrompt;

  /// Initialize the server with task-specific parameters.
  /// Called before executeTool() when a task uses this MCP.
  Future<void> initialize(Map<String, dynamic> initParams);

  /// List of available tools provided by this MCP server.
  /// Returns a list of tool descriptors compatible with the MCP tools/list format.
  List<McpToolDescriptor> get tools;

  /// Execute a specific tool by name with the given arguments.
  /// Returns the tool result as a JSON-encodable map.
  Future<Map<String, dynamic>> executeTool(String toolName, Map<String, dynamic> arguments);

  /// Validate init parameters before saving.
  /// Returns null if valid, or an error message string if invalid.
  String? validateInitParams(Map<String, dynamic> params) => null;

  /// Clean up resources when the server is no longer needed.
  Future<void> dispose() async {}

  /// Convert tool list to the MCP-compatible format (for discovery dialog).
  List<Map<String, dynamic>> toolsToJson() {
    return tools.map((t) => t.toJson()).toList();
  }
}

/// Describes a single tool provided by an internal MCP server.
class McpToolDescriptor {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
  final Map<String, dynamic>? returnType;

  const McpToolDescriptor({required this.name, required this.description, required this.inputSchema, this.returnType});

  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'inputSchema': inputSchema,
    if (returnType != null) 'returnType': returnType,
  };
}

/// Configuration for an internal MCP server attached to a task.
class InternalMcpConfig {
  final String id;
  final String taskId;
  final String mcpType;
  final Map<String, dynamic> params;
  final bool enabled;

  const InternalMcpConfig({required this.id, required this.taskId, required this.mcpType, this.params = const {}, this.enabled = true});

  InternalMcpConfig copyWith({String? taskId, String? mcpType, Map<String, dynamic>? params, bool? enabled}) {
    return InternalMcpConfig(
      id: id,
      taskId: taskId ?? this.taskId,
      mcpType: mcpType ?? this.mcpType,
      params: params ?? this.params,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toJson() => {'id': id, 'task_id': taskId, 'mcp_type': mcpType, 'params': params, 'enabled': enabled};

  factory InternalMcpConfig.fromJson(Map<String, dynamic> json) => InternalMcpConfig(
    id: json['id'] as String,
    taskId: json['task_id'] as String,
    mcpType: json['mcp_type'] as String,
    params: (json['params'] as Map<String, dynamic>?) ?? {},
    enabled: json['enabled'] as bool? ?? true,
  );

  @override
  String toString() => 'InternalMcpConfig($mcpType, task=$taskId, enabled=$enabled)';
}
