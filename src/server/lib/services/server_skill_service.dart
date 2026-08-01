import 'dart:async';

import '../database/server_database_adapter.dart';
import '../models/mcp_models.dart';
import '../models/github_mcp_server_definition.dart';
import '../models/agentic_task.dart';
import '../runner/server_internal_mcp.dart';
import '../runner/server_llm_runner.dart';
import '../runner/server_tool_registry.dart';
import '../runner/server_mcp_client.dart';
import '../services/server_external_tools_service.dart';
import '../services/server_llm_settings_service.dart';
import '../utils/server_logger.dart';

/// All known built-in MCP types that can have Tool Hints generated.
const _kBuiltInMcpTypes = [
  'ssh',
  'weather',
  'web_search',
  'imap',
  'chart',
  'mermaid',
  'file',
  'excel',
  'home_assistant',
  'gmail',
  'google_calendar',
  'google_drive',
  'document',
  'pdf',
  'js_bridge',
  'ps_bridge',
  'py_bridge',
  'website_search',
  'toolbox',
];

const int _kMaxTokensFull = 512;
const int _kMaxTokensSlm = 80;

/// Server-side counterpart of the Flutter [SkillGenerationService].
/// Generates [ToolSkill] records for built-in MCP tools and stores them in
/// the server DuckDB [tool_skills] table.
class ServerSkillService {
  ServerSkillService._();
  static final ServerSkillService instance = ServerSkillService._();

  bool _running = false;
  int _processed = 0;
  int _total = 0;
  String _currentTool = '';
  bool _cancelRequested = false;

  bool get isBusy => _running;

  Map<String, dynamic> getStatus() => {
    'running': _running,
    'processed': _processed,
    'total': _total,
    'current_tool': _currentTool,
  };

  void cancel() {
    if (_running) _cancelRequested = true;
  }

  String _extMcpTypeKey(String serverUrl) {
    final raw = serverUrl.trim().toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9]+'),
      '_',
    );
    return 'ext_${raw.length > 40 ? raw.substring(0, 40) : raw}';
  }

  Future<void> buildSkills({
    bool addMissingOnly = true,
    String? toolName,
    String? mcpType,
    bool clearBeforeBuild = false,
    bool clearCustom = false,
  }) async {
    if (_running) return; // already in progress
    _running = true;
    _cancelRequested = false;
    _processed = 0;
    _total = 0;
    _currentTool = '';

    try {
      final db = serverDb;
      final llmSettings = ServerLlmSettingsService.instance;

      if (clearBeforeBuild) {
        log.info(
          '[SkillService] Clearing skills table (clearCustom: $clearCustom)',
        );
        if (clearCustom) {
          await db.execute('DELETE FROM tool_skills');
        } else {
          await db.execute('DELETE FROM tool_skills WHERE is_custom = FALSE');
        }
      }

      if (!llmSettings.isConfigured) {
        log.warning('[SkillService] No LLM configured — cannot build skills.');
        _running = false;
        return;
      }

      List<GithubMcpServerDefinition> githubServers = const [];
      try {
        githubServers = (await db.getAllGithubMcpServers())
            .where((s) => s.isActive)
            .toList(growable: false);
      } catch (e) {
        log.warning('[SkillService] Could not load GitHub MCP servers: $e');
      }

      // Collect tools to process ────────────────────────────────────────────
      final List<_ToolEntry> pending = [];

      // 1. Scan internal built-in types
      final List<String> internalTypes = [];
      if (mcpType == null) {
        internalTypes.addAll(_kBuiltInMcpTypes);
      } else if (_kBuiltInMcpTypes.contains(mcpType)) {
        internalTypes.add(mcpType);
      }

      for (final type in internalTypes) {
        if (_cancelRequested) break;
        final mcp = await createServerInternalMcp(type, {});
        if (mcp == null) continue;
        final tools = mcp.tools;
        List<String> existingNames = const [];
        if (addMissingOnly) {
          existingNames = await db.getToolNamesWithSkills(mcpType: type);
        }
        for (final tool in tools) {
          if (toolName != null && tool.name != toolName) continue;
          if (addMissingOnly && existingNames.contains(tool.name)) continue;
          pending.add(_ToolEntry(mcpType: type, tool: tool));
        }
      }

      // 2. Scan custom GitHub MCP servers
      final List<GithubMcpServerDefinition> githubToScan = [];
      if (mcpType == null) {
        githubToScan.addAll(githubServers);
      } else if (mcpType.startsWith('gh_mcp_')) {
        final serverId = mcpType.substring('gh_mcp_'.length).trim();
        final match = githubServers.where((s) => s.id == serverId).firstOrNull;
        if (match != null) {
          githubToScan.add(match);
        }
      }

      if (githubToScan.isNotEmpty) {
        final tmpRegistry = ServerToolRegistry(db);
        try {
          for (final server in githubToScan) {
            if (_cancelRequested) break;
            final type = 'gh_mcp_${server.id}';
            await tmpRegistry.connectGithubMcpServer(server);
            final tools = tmpRegistry.mcpTools;
            List<String> existingNames = const [];
            if (addMissingOnly) {
              existingNames = await db.getToolNamesWithSkills(mcpType: type);
            }
            for (final tool in tools) {
              if (toolName != null && tool.name != toolName) continue;
              if (addMissingOnly && existingNames.contains(tool.name)) continue;
              pending.add(_ToolEntry(mcpType: type, tool: tool));
            }
          }
        } catch (e) {
          log.error(
            '[SkillService] Failed scanning custom GitHub MCP servers: $e',
          );
        } finally {
          await tmpRegistry.dispose();
        }
      }

      // 3. Scan external custom remote MCP servers (HTTP/SSE)
      final List<McpToolConfig> externalToScan = [];
      final selectedServers =
          ServerExternalToolsService.instance.selectedServers;
      if (mcpType == null) {
        externalToScan.addAll(selectedServers);
      } else if (mcpType.startsWith('ext_')) {
        final match = selectedServers
            .where((s) => _extMcpTypeKey(s.serverUrl) == mcpType)
            .firstOrNull;
        if (match != null) {
          externalToScan.add(match);
        }
      }

      if (externalToScan.isNotEmpty) {
        for (final server in externalToScan) {
          if (_cancelRequested) break;
          final type = _extMcpTypeKey(server.serverUrl);

          // Try to discover tools live by connecting to the server
          List<MCPTool> tools = [];
          final apiKey = ServerExternalToolsService.instance.resolveApiKey(
            server.serverUrl,
            server.apiKey,
          );
          final resolvedTuple = await ServerExternalToolsService.instance
              .resolveSmitheryEndpoint(server.serverUrl, apiKey);
          final endpointUrl = resolvedTuple.$1;
          final effectiveToken = resolvedTuple.$2;

          log.info(
            '[SkillService] Connecting to external MCP server: ${server.serverUrl} @ $endpointUrl',
          );
          final client = ServerMcpClient(
            endpointUrl,
            bearerToken: effectiveToken,
          );
          try {
            await client.connect();
            tools = client.availableTools;
          } catch (e) {
            log.warning(
              '[SkillService] Failed live connection to external MCP server ${server.serverUrl}: $e. Falling back to cached discoveredToolSchemas.',
            );
            // Fallback to cached discoveredToolSchemas if server is offline
            if (server.discoveredToolSchemas.isNotEmpty) {
              tools = server.discoveredToolSchemas.map((schema) {
                final name = schema['name'] as String? ?? '';
                final desc = schema['description'] as String? ?? '';
                final inputSchema =
                    (schema['inputSchema'] as Map<String, dynamic>?) ?? {};
                return MCPTool(
                  name: name,
                  description: desc,
                  inputSchema: inputSchema,
                );
              }).toList();
            }
          } finally {
            client.dispose();
          }

          if (tools.isNotEmpty) {
            List<String> existingNames = const [];
            if (addMissingOnly) {
              existingNames = await db.getToolNamesWithSkills(mcpType: type);
            }
            for (final tool in tools) {
              if (toolName != null && tool.name != toolName) continue;
              if (addMissingOnly && existingNames.contains(tool.name)) continue;
              pending.add(_ToolEntry(mcpType: type, tool: tool));
            }
          }
        }
      }

      _total = pending.length;
      log.info('[SkillService] Building ${pending.length} skill(s)');

      final runner = ServerLlmRunner(llmSettings);
      final emptyRegistry = ServerToolRegistry(db);

      for (final entry in pending) {
        if (_cancelRequested) break;
        _currentTool = entry.tool.name;
        try {
          await _generateAndSave(
            db: db,
            runner: runner,
            registry: emptyRegistry,
            tool: entry.tool,
            mcpType: entry.mcpType,
          );
        } catch (e) {
          log.warning('[SkillService] Failed for ${entry.tool.name}: $e');
        }
        _processed++;
        _currentTool = '';
      }
      log.info(
        '[SkillService] Done — $_processed/${pending.length} skills saved.',
      );
    } finally {
      _running = false;
      _cancelRequested = false;
      _currentTool = '';
    }
  }

  Future<void> _generateAndSave({
    required ServerDatabaseAdapter db,
    required ServerLlmRunner runner,
    required ServerToolRegistry registry,
    required MCPTool tool,
    required String mcpType,
  }) async {
    final paramSummary = _buildParamSummary(tool.inputSchema);

    final fullPrompt =
        'Write a concise MCP tool skill guide (max ${_kMaxTokensFull ~/ 4} words) for the tool `${tool.name}`.\n'
        'Tool description: ${tool.description ?? tool.name}\n'
        '${paramSummary.isNotEmpty ? 'Parameters: $paramSummary\n' : ''}'
        'Include: when to use this tool, key parameters, example usage pattern.\n'
        'Plain text only. No code blocks, no markdown headers.';

    final slmPrompt =
        'Write a 1-sentence MCP skill for `${tool.name}`: ${tool.description ?? tool.name}.'
        '${paramSummary.isNotEmpty ? ' Params: $paramSummary.' : ''}'
        ' Max ${_kMaxTokensSlm ~/ 3} words. Plain text only.';

    const systemPrompt =
        'You write concise, practical MCP tool skill guides. Output plain text only — no markdown, no quotes.';

    final fullResult = await runner.run(
      systemPrompt: systemPrompt,
      userPrompt: fullPrompt,
      registry: registry,
    );
    final slmResult = await runner.run(
      systemPrompt: systemPrompt,
      userPrompt: slmPrompt,
      registry: registry,
    );

    final fullText = fullResult.content.trim();
    final slmText = slmResult.content.trim();

    final now = DateTime.now().toIso8601String();
    // Build a deterministic ID from tool name + mcpType.
    final id = '${mcpType}_${tool.name}'.replaceAll(
      RegExp(r'[^a-zA-Z0-9_]'),
      '_',
    );

    await db.saveToolSkill({
      'id': id,
      'tool_name': tool.name,
      'mcp_type': mcpType,
      'skill_text': fullText,
      'skill_text_slm': slmText,
      'is_enabled': true,
      'is_custom': false,
      'generated_at': now,
      'updated_at': now,
    });

    log.info('[SkillService] Saved skill for ${tool.name} ($mcpType)');
  }

  /// Builds a formatted string describing all parameters from a JSON Schema
  /// object, e.g.: "dluName (string, required): device name; detail (boolean,
  /// optional): include full details".
  String _buildParamSummary(Map<String, dynamic>? schema) {
    if (schema == null) return '';
    try {
      final required =
          (schema['required'] as List?)?.cast<String>() ?? <String>[];
      final props = schema['properties'];
      if (props is! Map || props.isEmpty) {
        return required.isEmpty ? '' : 'required: ${required.join(', ')}';
      }
      final parts = <String>[];
      for (final entry in (props).entries) {
        final name = entry.key as String;
        final prop =
            (entry.value as Map<dynamic, dynamic>?)?.cast<String, dynamic>() ??
            <String, dynamic>{};
        final type = prop['type'] as String? ?? 'any';
        final desc = prop['description'] as String? ?? '';
        final isRequired = required.contains(name);
        final tag = isRequired ? 'required' : 'optional';
        final descPart = desc.isNotEmpty ? ': $desc' : '';
        parts.add('$name ($type, $tag)$descPart');
      }
      return parts.join('; ');
    } catch (_) {
      return '';
    }
  }
}

class _ToolEntry {
  final String mcpType;
  final MCPTool tool;
  const _ToolEntry({required this.mcpType, required this.tool});
}
