import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/mcp_models.dart';
import '../utils/logger.dart';

/// Interface that defines the MCP functionality needed by ChatService
abstract class MCPClientInterface extends ChangeNotifier {
  List<MCPTool> get availableTools;
  Future<List<MCPTool>> get availableToolsWithEmbeddings;
  bool get isConnected;
  Future<MCPToolResult> callTool(String name, Map<String, dynamic> arguments);
}

/// Definition of an MCP client with its metadata
class MCPClientDef {
  final String name;
  final dynamic client;
  final String? displayName;
  final bool isPluginProvided; // Track if this client is provided by a plugin

  MCPClientDef({
    required this.name,
    required this.client,
    this.displayName,
    this.isPluginProvided = false, // Default to false for backwards compatibility
  });

  String get label => displayName ?? name;

  bool get isConnected {
    try {
      return client.isConnected == true;
    } catch (_) {
      return false;
    }
  }

  List<MCPTool> get availableTools {
    try {
      talker.debug('MCPClientDef($name): Accessing client.availableTools...');
      final tools = client.availableTools;

      // For web: serialize to JSON and back to avoid type issues
      if (tools is List) {
        talker.debug('MCPClientDef($name): Got ${tools.length} tools');

        final List<MCPTool> result = [];
        for (int i = 0; i < tools.length; i++) {
          try {
            final tool = tools[i];

            // Safely access properties with fallback
            String? name;
            String? description;
            Map<String, dynamic>? inputSchema;
            List<double>? embedding;

            try {
              name = (tool as dynamic).name as String?;
            } catch (_) {}

            try {
              description = (tool as dynamic).description as String?;
            } catch (_) {}

            try {
              inputSchema = (tool as dynamic).inputSchema as Map<String, dynamic>?;
            } catch (_) {}

            try {
              embedding = (tool as dynamic).embedding as List<double>?;
            } catch (_) {
              // embedding is optional, no warning needed
            }

            if (name != null) {
              result.add(MCPTool(name: name, description: description, inputSchema: inputSchema, embedding: embedding));
            }
          } catch (e) {
            talker.warning('MCPClientDef($name): Failed to convert tool $i: $e');
          }
        }

        return result;
      }

      talker.warning('MCPClientDef($name): availableTools is not a List, got ${tools.runtimeType}');
      return [];
    } catch (e, stack) {
      talker.error('MCPClientDef($name): Failed to get tools: $e');
      talker.debug('Stack: $stack');
      return [];
    }
  }

  Future<MCPToolResult> callTool(String toolName, Map<String, dynamic> arguments) async {
    try {
      final result = await client.callTool(toolName, arguments);

      // For web: ensure type compatibility by reconstructing the result
      if (result is MCPToolResult) {
        return result;
      }

      // If dynamic type mismatch, reconstruct from properties
      final content = (result as dynamic).content as List<dynamic>?;
      final isError = (result as dynamic).isError as bool? ?? false;

      return MCPToolResult(
        content:
            content?.map((item) {
              return MCPContent(
                type: (item as dynamic).type as String,
                text: (item as dynamic).text as String?,
                data: (item as dynamic).data as String?,
                mimeType: (item as dynamic).mimeType as String?,
              );
            }).toList() ??
            [],
        isError: isError,
      );
    } catch (e) {
      talker.error('MCPClientDef($name): callTool failed: $e');
      rethrow;
    }
  }

  Future<void> connect() async {
    try {
      await client.connect();
    } catch (_) {}
  }

  Future<void> disconnect() async {
    try {
      await client.disconnect();
    } catch (_) {}
  }
}

/// Manager for multiple MCP servers - fully dynamic and abstract
class MultiMCPManager extends ChangeNotifier implements MCPClientInterface {
  final List<MCPClientDef> _clients = [];
  bool _isInitialized = false;
  bool _disposed = false;

  // Cached tool list — rebuilt once per connection-change cycle to avoid
  // re-walking all clients (with full type-conversion) on every access.
  List<MCPTool>? _cachedTools;

  MultiMCPManager({List<MCPClientDef>? clients}) {
    if (clients != null) {
      for (final clientDef in clients) {
        registerClient(clientDef);
      }
    }
  }

  /// Register an MCP client dynamically
  void registerClient(MCPClientDef clientDef) {
    _clients.add(clientDef);
    if (clientDef.client is ChangeNotifier) {
      (clientDef.client as ChangeNotifier).addListener(_onConnectionChange);
    }
    _cachedTools = null; // invalidate cache
    notifyListeners();
  }

  /// Get client by name
  MCPClientDef? getClient(String name) {
    try {
      return _clients.firstWhere((c) => c.name == name);
    } catch (_) {
      return null;
    }
  }

  /// Get all registered clients
  List<MCPClientDef> get clients => List.unmodifiable(_clients); // Getters
  bool get isInitialized => _isInitialized;
  @override
  bool get isConnected => hasAnyConnection;

  bool get hasAnyConnection {
    return _clients.any((client) => client.isConnected);
  }

  /// Check if a specific client is connected
  bool isClientConnected(String name) {
    final client = getClient(name);
    return client?.isConnected ?? false;
  }

  /// Get all available tools from all connected servers (implements MCPClientInterface)
  @override
  List<MCPTool> get availableTools => allAvailableTools;

  /// Get all available tools from all connected servers
  List<MCPTool> get allAvailableTools {
    if (_cachedTools != null) return _cachedTools!;

    final tools = <MCPTool>[];
    final seen = <String>{};

    for (final clientDef in _clients) {
      try {
        // MCPClientDef.availableTools already handles the type conversion
        final clientTools = clientDef.availableTools;
        for (final tool in clientTools) {
          if (seen.add(tool.name)) {
            tools.add(tool);
          } else {
            talker.warning('Duplicate tool name "${tool.name}" from "${clientDef.name}" — skipped to avoid LLM API errors');
          }
        }
      } catch (e) {
        talker.error('Error getting tools from client ${clientDef.name}: $e');
      }
    }

    _cachedTools = tools;
    return tools;
  }

  /// Get all available tools with pre-computed embeddings from the embedding server
  /// Falls back to returning tools without embeddings if the embedding server is unavailable
  @override
  Future<List<MCPTool>> get availableToolsWithEmbeddings async {
    final tools = allAvailableTools;

    final embeddingClient = getClient('embedding');
    if (embeddingClient?.isConnected != true) {
      return tools;
    }

    try {
      final embeddedTools = await embeddingClient!.client.embedTools(tools);
      talker.info('Received ${embeddedTools?.length ?? 0} tools with pre-computed embeddings');
      return embeddedTools ?? tools;
    } catch (e) {
      talker.error('Failed to get embeddings from server: $e');
      return tools;
    }
  }

  /// Get all available resources from all connected servers
  List<MCPResource> get allAvailableResources {
    final resources = <MCPResource>[];

    for (final clientDef in _clients) {
      try {
        final clientResources = clientDef.client.availableResources as List<MCPResource>?;
        if (clientResources != null) {
          resources.addAll(clientResources);
        }
      } catch (_) {}
    }

    return resources;
  }

  /// Initialize all MCP connections
  Future<void> initializeAll() async {
    talker.info('Initializing ${_clients.length} MCP client(s)...');

    // Connect to embedding server first if it exists
    final embeddingClient = getClient('embedding');
    if (embeddingClient != null) {
      try {
        await embeddingClient.connect();
        talker.info(' ${embeddingClient.label} connected');
      } catch (e) {
        talker.warning('⚠️ ${embeddingClient.label} connection failed: $e');
      }
    }

    // Connect to all other clients in parallel
    final otherClients = _clients.where((c) => c.name != 'embedding').toList();
    final results = await Future.wait(
      otherClients.map((clientDef) async {
        try {
          await clientDef.connect();
          talker.info('${clientDef.label} MCP server connected successfully');
          return true;
        } catch (e) {
          talker.warning('${clientDef.label} MCP connection failed: $e');
          return false;
        }
      }),
      eagerError: false,
    );

    // Check if at least one connection succeeded
    if (results.any((success) => success)) {
      _isInitialized = true;
      final connectedNames = _clients.where((c) => c.isConnected).map((c) => c.label).join(', ');
      talker.log('Multi-MCP Manager initialized with: $connectedNames');
    } else {
      talker.warning('No MCP servers could be connected');
    }

    notifyListeners();
  }

  /// Reconnect to a specific server
  Future<void> reconnectServer(String clientName) async {
    final clientDef = getClient(clientName);
    if (clientDef == null) {
      throw ArgumentError('Client not found: $clientName');
    }

    try {
      await clientDef.connect();
      talker.info('Reconnected to ${clientDef.label}');
    } catch (e) {
      talker.error('Failed to reconnect to ${clientDef.label}: $e');
      rethrow;
    }

    notifyListeners();
  }

  /// Reconnect to all disconnected servers
  Future<void> reconnectAll() async {
    final disconnectedClients = _clients.where((c) => !c.isConnected).toList();

    if (disconnectedClients.isEmpty) {
      return;
    }

    await Future.wait(disconnectedClients.map((clientDef) => reconnectServer(clientDef.name)), eagerError: false);
  }

  /// Call a tool on the appropriate server (implements MCPClientInterface)
  @override
  Future<MCPToolResult> callTool(String toolName, Map<String, dynamic> arguments) async {
    talker.info('MultiMCPManager: Calling tool $toolName');

    final resolvedName = _resolveToolName(toolName);
    if (resolvedName != toolName) {
      talker.info('MultiMCPManager: Fuzzy-resolved tool "$toolName" → "$resolvedName"');
    }

    // Find which client has this tool
    for (final clientDef in _clients) {
      if (clientDef.availableTools.any((tool) => tool.name == resolvedName)) {
        // Found the client with this tool
        if (!clientDef.isConnected) {
          talker.warning('${clientDef.label} not connected, attempting to reconnect...');
          await reconnectServer(clientDef.name);
        }

        talker.info('Routing to ${clientDef.label}: $resolvedName');
        return await clientDef.callTool(resolvedName, arguments);
      }
    }

    throw Exception('Tool not found: $toolName');
  }

  /// Resolves a (possibly hallucinated) tool name to an actual registered name.
  /// Returns the original name unchanged if an exact match exists or no fuzzy match is found.
  String _resolveToolName(String name) {
    final all = allAvailableTools;

    // Exact match — no work needed.
    if (all.any((t) => t.name == name)) return name;

    final names = all.map((t) => t.name).toList();

    // 1. Prefix match: e.g. "create_chart" → "create_chart_png"
    final prefixMatches = names.where((n) => n.startsWith(name) || name.startsWith(n)).toList();
    if (prefixMatches.length == 1) return prefixMatches.first;

    // 2. Substring match
    final substringMatches = names.where((n) => n.contains(name) || name.contains(n)).toList();
    if (substringMatches.length == 1) return substringMatches.first;

    // 3. Snake-case token overlap (≥2 shared tokens required to avoid false positives)
    final calledTokens = name.split('_').toSet();
    String? bestName;
    int bestOverlap = 0;
    for (final n in names) {
      final overlap = n.split('_').where(calledTokens.contains).length;
      if (overlap > bestOverlap) {
        bestOverlap = overlap;
        bestName = n;
      }
    }
    if (bestName != null && bestOverlap >= 2) return bestName;

    return name;
  }

  /// Get tool by name
  MCPTool? getTool(String toolName) {
    for (final tool in allAvailableTools) {
      if (tool.name == toolName) {
        return tool;
      }
    }
    return null;
  }

  /// Get server connection status summary
  Map<String, dynamic> getConnectionStatus() {
    final status = <String, dynamic>{};

    for (final clientDef in _clients) {
      status[clientDef.name] = {
        'connected': clientDef.isConnected,
        'tools': clientDef.availableTools.length,
        'displayName': clientDef.label,
      };
    }

    return status;
  }

  /// Listen to connection changes
  void _onConnectionChange() {
    _cachedTools = null; // invalidate tool cache on any connection state change
    notifyListeners();
  }

  /// Disconnect all servers
  Future<void> disconnectAll() async {
    await Future.wait(_clients.map((clientDef) => clientDef.disconnect()), eagerError: false);
    _isInitialized = false;
    // Defer notification to avoid calling during build phase
    Future.microtask(() {
      if (!_disposed) {
        notifyListeners();
      }
    });
  }

  /// Reconnect all servers (useful after conversation reset to refresh sessions)
  Future<void> reconnectAllServers() async {
    talker.info('🔄 Reconnecting all MCP servers...');

    for (final clientDef in _clients) {
      // Skip plugin-provided clients - they manage their own reconnection via auth listeners
      if (clientDef.isPluginProvided) {
        talker.debug('⏭️ Skipping ${clientDef.name} - managed by plugin');
        continue;
      }

      try {
        talker.debug('Reconnecting ${clientDef.name}...');
        await clientDef.disconnect();
        await Future.delayed(const Duration(milliseconds: 100));
        await clientDef.connect();
        talker.info(' ${clientDef.displayName} reconnected');
      } catch (e) {
        talker.warning('⚠️ Failed to reconnect ${clientDef.displayName}: $e');
      }
    }

    talker.info(' MCP servers reconnected after conversation reset');
    notifyListeners();
  }

  /// Generate a structured tool list for model training / fine-tuning.
  ///
  /// [format] controls the output shape:
  ///   • `'openai'`     — OpenAI function-calling format (list of tool objects)
  ///   • `'anthropic'`  — Anthropic Claude tool-use format
  ///   • `'markdown'`   — Human-readable markdown documentation
  ///   • `'jsonl'`      — One JSON object per line (OpenAI format, for fine-tuning JSONL)
  ///
  /// [serverFilter] — if non-null, only include tools from the named client.
  /// [includeServerTag] — when true, adds a `_server` metadata field per tool entry.
  String generateTrainingToolList({String format = 'openai', String? serverFilter, bool includeServerTag = true}) {
    // Collect tools per server so we can tag them.
    final perServer = <String, List<MCPTool>>{};
    for (final clientDef in _clients) {
      if (serverFilter != null && clientDef.label != serverFilter) continue;
      final tools = clientDef.availableTools;
      if (tools.isNotEmpty) {
        perServer[clientDef.label] = tools;
      }
    }

    // Flatten to a list while recording server origin.
    final toolEntries = <({MCPTool tool, String server})>[];
    final seen = <String>{};
    for (final entry in perServer.entries) {
      for (final tool in entry.value) {
        if (seen.add(tool.name)) {
          toolEntries.add((tool: tool, server: entry.key));
        }
      }
    }

    switch (format) {
      case 'anthropic':
        return _formatAnthropic(toolEntries, includeServerTag);
      case 'markdown':
        return _formatMarkdown(toolEntries, perServer);
      case 'jsonl':
        return _formatJsonl(toolEntries, includeServerTag);
      default: // 'openai'
        return _formatOpenAI(toolEntries, includeServerTag);
    }
  }

  String _formatOpenAI(List<({MCPTool tool, String server})> entries, bool tagServer) {
    final list = entries.map((e) {
      final fn = <String, dynamic>{
        'name': e.tool.name,
        if (e.tool.description != null) 'description': e.tool.description,
        'parameters': e.tool.inputSchema ?? {'type': 'object', 'properties': {}},
      };
      final obj = <String, dynamic>{'type': 'function', 'function': fn};
      if (tagServer) obj['_server'] = e.server;
      return obj;
    }).toList();
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(list);
  }

  String _formatAnthropic(List<({MCPTool tool, String server})> entries, bool tagServer) {
    final list = entries.map((e) {
      final obj = <String, dynamic>{
        'name': e.tool.name,
        if (e.tool.description != null) 'description': e.tool.description,
        'input_schema': e.tool.inputSchema ?? {'type': 'object', 'properties': {}},
      };
      if (tagServer) obj['_server'] = e.server;
      return obj;
    }).toList();
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(list);
  }

  String _formatMarkdown(List<({MCPTool tool, String server})> entries, Map<String, List<MCPTool>> perServer) {
    final buf = StringBuffer();
    buf.writeln('# MCP Tool Reference — Model Training Data');
    buf.writeln();
    buf.writeln('Generated: ${DateTime.now().toIso8601String()}');
    buf.writeln('Total tools: ${entries.length}  |  Servers: ${perServer.length}');
    buf.writeln();

    for (final serverEntry in perServer.entries) {
      buf.writeln('---');
      buf.writeln('## ${serverEntry.key}  (${serverEntry.value.length} tools)');
      buf.writeln();
      for (final tool in serverEntry.value) {
        buf.writeln('### `${tool.name}`');
        if (tool.description != null) buf.writeln('${tool.description}');
        buf.writeln();
        if (tool.inputSchema != null) {
          buf.writeln('**Input schema:**');
          buf.writeln('```json');
          const enc = JsonEncoder.withIndent('  ');
          buf.writeln(enc.convert(tool.inputSchema));
          buf.writeln('```');
          buf.writeln();
        }
      }
    }
    return buf.toString();
  }

  String _formatJsonl(List<({MCPTool tool, String server})> entries, bool tagServer) {
    final lines = entries.map((e) {
      final fn = <String, dynamic>{
        'name': e.tool.name,
        if (e.tool.description != null) 'description': e.tool.description,
        'parameters': e.tool.inputSchema ?? {'type': 'object', 'properties': {}},
      };
      final obj = <String, dynamic>{'type': 'function', 'function': fn};
      if (tagServer) obj['_server'] = e.server;
      return jsonEncode(obj);
    });
    return lines.join('\n');
  }

  /// Clear all registered clients after disconnecting them.
  Future<void> clear() async {
    await disconnectAll();
    for (final clientDef in _clients) {
      if (clientDef.client is ChangeNotifier) {
        (clientDef.client as ChangeNotifier).removeListener(_onConnectionChange);
      }
    }
    _clients.clear();
    _cachedTools = null;
    _isInitialized = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final clientDef in _clients) {
      if (clientDef.client is ChangeNotifier) {
        (clientDef.client as ChangeNotifier).removeListener(_onConnectionChange);
      }
    }
    disconnectAll();
    super.dispose();
  }
}
