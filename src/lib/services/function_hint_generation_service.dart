import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../mcp/internal_mcp_registry.dart';
import '../mcp/internal_mcp_server.dart';
import 'mcp_client.dart';
import '../models/workflow_task.dart';
import '../models/mcp_models.dart';
import '../models/function_hint.dart';
import 'app_logger.dart';
import 'external_tools_settings_service.dart';
import 'llm_service.dart';
import 'llm_settings_service.dart';
import 'function_hint_database_service.dart';
import 'task_runner_service.dart';

/// Immutable progress snapshot for skill generation.
class FunctionHintProgress {
  final int total;
  final int processed;
  final String currentTool;

  const FunctionHintProgress({this.total = 0, this.processed = 0, this.currentTool = ''});

  FunctionHintProgress copyWith({int? total, int? processed, String? currentTool}) =>
      FunctionHintProgress(total: total ?? this.total, processed: processed ?? this.processed, currentTool: currentTool ?? this.currentTool);
}

/// Generates, stores and refreshes [FunctionHint] records for MCP tools.
///
/// Generation runs fire-and-forget in the background — callers should never
/// `await` the public `ensure*` methods from hot paths such as startup or
/// the active-task provider.
class FunctionHintGenerationService {
  // ── Singleton ──────────────────────────────────────────────────────────
  static final FunctionHintGenerationService _instance = FunctionHintGenerationService._();
  factory FunctionHintGenerationService() => _instance;
  FunctionHintGenerationService._();

  static FunctionHintGenerationService get instance => _instance;

  // ── Token-budget settings ──────────────────────────────────────────────
  static const String _prefKeyLlm = 'skill_max_tokens_llm';
  static const String _prefKeySlm = 'skill_max_tokens_slm';
  static const int defaultMaxTokensLlm = 200;
  static const int defaultMaxTokensSlm = 60;

  int _maxTokensLlm = defaultMaxTokensLlm;
  int _maxTokensSlm = defaultMaxTokensSlm;

  int get maxTokensLlm => _maxTokensLlm;
  int get maxTokensSlm => _maxTokensSlm;

  /// Load persisted token-budget settings.  Call once before showing the
  /// skills screen so UI fields reflect the stored values.
  Future<void> loadTokenSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _maxTokensLlm = prefs.getInt(_prefKeyLlm) ?? defaultMaxTokensLlm;
    _maxTokensSlm = prefs.getInt(_prefKeySlm) ?? defaultMaxTokensSlm;
  }

  /// Persist new token-budget values and apply them immediately.
  Future<void> saveTokenSettings(int maxTokensLlm, int maxTokensSlm) async {
    _maxTokensLlm = maxTokensLlm.clamp(10, 2000);
    _maxTokensSlm = maxTokensSlm.clamp(10, 500);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefKeyLlm, _maxTokensLlm);
    await prefs.setInt(_prefKeySlm, _maxTokensSlm);
  }

  final FunctionHintDatabaseService _db = FunctionHintDatabaseService();
  final InternalMcpRegistry _registry = InternalMcpRegistry();

  /// Normalise a server URL into a stable mcpType key for external servers.
  /// Matches the convention used in skills_screen.dart.
  static String _extMcpTypeKey(String serverUrl) {
    final raw = serverUrl.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    return 'ext_${raw.length > 40 ? raw.substring(0, 40) : raw}';
  }

  // Prevent concurrent full-scan runs
  bool _busyBuiltIn = false;
  bool _cancelRequested = false;

  /// Notifier updated while a generation pass is in progress.
  final progressNotifier = ValueNotifier<FunctionHintProgress>(const FunctionHintProgress());

  /// Bumped by 1 every time a generation pass finishes (success, error, or
  /// cancel).  Listeners can use this to detect completion without polling.
  final completionNotifier = ValueNotifier<int>(0);

  /// True while `ensureSkillsForBuiltInTools` or `generateSkillsForTools` is running.
  bool get isBusy => _busyBuiltIn;

  /// Request cancellation of the in-progress generation pass.
  /// The running loop will stop after the current tool finishes.
  void cancelGeneration() {
    if (_busyBuiltIn) _cancelRequested = true;
  }

  // ──────────────────────────────────────────────────────────────────────

  /// Scan all registered built-in MCP tools and generate skills for any that
  /// do not yet have a DB record.  Safe to call multiple times (no-ops for
  /// existing entries).
  ///
  /// Throws if the LLM returns an API-level error (4xx/5xx) so callers can
  /// surface the failure to the user and abort.  Per-tool serialisation /
  /// content errors are still caught internally and logged.
  Future<void> ensureSkillsForBuiltInTools() async {
    if (await _db.isServerMode()) return;
    if (_busyBuiltIn) return;
    _busyBuiltIn = true;
    _cancelRequested = false;
    try {
      final llm = await _configureLlmFromSettings();
      if (llm == null) return;

      final existing = await _db.getExistingToolNames();

      // Collect all tools that need generation first so we can show accurate
      // total counts in the progress dialog.
      final pending = <(McpToolDescriptor, String)>[];
      for (final info in _registry.availableServers) {
        final server = _registry.create(info.type);
        if (server == null) continue;
        for (final tool in server.tools) {
          if (!existing.contains(tool.name)) pending.add((tool, info.type));
        }
      }

      // Also include external MCP servers: prefer full schemas when cached,
      // fall back to name-only for servers configured before schemas were stored.
      for (final server in ExternalToolsSettingsService.instance.selectedServers) {
        final mcpType = _extMcpTypeKey(server.serverUrl);
        if (server.discoveredToolSchemas.isNotEmpty) {
          for (final schema in server.discoveredToolSchemas) {
            final name = schema['name'] as String? ?? '';
            if (name.isEmpty || existing.contains(name)) continue;
            pending.add((
              McpToolDescriptor(
                name: name,
                description: schema['description'] as String? ?? '',
                inputSchema: (schema['inputSchema'] as Map<String, dynamic>?) ?? {},
              ),
              mcpType,
            ));
          }
        } else {
          // Schemas not cached yet — attempt a live HTTP discovery so we can
          // generate skills with the correct parameter info.
          final freshSchemas = await _tryDiscoverExternalServerSchemas(server);
          if (freshSchemas.isNotEmpty) {
            // Persist the freshly discovered schemas for future use.
            final freshToolNames = freshSchemas.map((s) => s['name'] as String? ?? '').where((n) => n.isNotEmpty).toList();
            unawaited(
              ExternalToolsSettingsService.instance.upsertSelectedServer(
                server.copyWith(discoveredTools: freshToolNames, discoveredToolSchemas: freshSchemas),
              ),
            );
            for (final schema in freshSchemas) {
              final name = schema['name'] as String? ?? '';
              if (name.isEmpty || existing.contains(name)) continue;
              pending.add((
                McpToolDescriptor(
                  name: name,
                  description: schema['description'] as String? ?? '',
                  inputSchema: (schema['inputSchema'] as Map<String, dynamic>?) ?? {},
                ),
                mcpType,
              ));
            }
          } else {
            // Live discovery unavailable — fall back to name-only so skills
            // can still be (re-)generated once schemas are populated by a task run.
            for (final name in server.discoveredTools) {
              if (name.isEmpty || existing.contains(name)) continue;
              pending.add((McpToolDescriptor(name: name, description: '', inputSchema: {}), mcpType));
            }
          }
        }
      }

      progressNotifier.value = FunctionHintProgress(total: pending.length, processed: 0);
      int processed = 0;

      for (final (tool, mcpType) in pending) {
        if (_cancelRequested) {
          log.info('[Skills] Generation cancelled by user.');
          break;
        }
        progressNotifier.value = progressNotifier.value.copyWith(currentTool: tool.name);
        await _generateAndSave(tool, mcpType, llm);
        processed++;
        progressNotifier.value = progressNotifier.value.copyWith(processed: processed, currentTool: '');
        existing.add(tool.name);
      }

      if (!_cancelRequested) log.info('[Skills] Built-in skill generation pass complete');
    } catch (e, st) {
      log.warning('[Skills] ensureSkillsForBuiltInTools error: $e $st');
      rethrow;
    } finally {
      _busyBuiltIn = false;
      _cancelRequested = false;
      completionNotifier.value++;
    }
  }

  /// Generate (or re-generate) skills for an explicit list of [tools] and
  /// persist them under [mcpType].
  ///
  /// [mcpType] is used as the grouping key in the DB — pass a stable string
  /// that identifies the tool set (e.g. a sanitised server URL for remote MCP
  /// servers, or `'js_bridge'` for user-defined JS tools).
  ///
  /// If [addMissingOnly] is true, tools that already have a DB record are
  /// skipped.  Otherwise every tool is regenerated.
  Future<List<FunctionHint>> generateSkillsForTools(List<McpToolDescriptor> tools, String mcpType, {bool addMissingOnly = false}) async {
    if (_busyBuiltIn) return const [];
    _busyBuiltIn = true;
    _cancelRequested = false;
    try {
      final llm = await _configureLlmFromSettings();
      if (llm == null) return const [];
      final existing = addMissingOnly ? await _db.getExistingToolNames() : <String>{};
      final pending = tools.where((t) => !addMissingOnly || !existing.contains(t.name)).toList();
      progressNotifier.value = FunctionHintProgress(total: pending.length, processed: 0);
      final results = <FunctionHint>[];
      int processed = 0;
      for (final tool in pending) {
        if (_cancelRequested) break;
        progressNotifier.value = progressNotifier.value.copyWith(currentTool: tool.name);
        try {
          final skill = await _generateAndSave(tool, mcpType, llm, forceReplace: !addMissingOnly);
          results.add(skill);
        } catch (e) {
          log.warning('[Skills] generateSkillsForTools: failed for ${tool.name}: $e');
        }
        processed++;
        progressNotifier.value = progressNotifier.value.copyWith(processed: processed, currentTool: '');
      }
      log.info('[Skills] generateSkillsForTools: ${results.length}/${tools.length} skills for $mcpType');
      return results;
    } finally {
      _busyBuiltIn = false;
      _cancelRequested = false;
      completionNotifier.value++;
    }
  }

  /// Generate (or re-generate) a skill for a single tool and persist it.
  /// Marks [isCustom] = false so it can be regenerated again freely.
  Future<FunctionHint?> regenerateSkillForTool(McpToolDescriptor tool, String mcpType) async {
    final llm = await _configureLlmFromSettings();
    if (llm == null) return null;
    try {
      return await _generateAndSave(tool, mcpType, llm, forceReplace: true);
    } catch (e) {
      log.warning('[Skills] regenerateSkillForTool ${tool.name}: $e');
      return null;
    }
  }

  // ──────────────────────────────────────────────────────────────────────
  // Internal helpers
  // ──────────────────────────────────────────────────────────────────────

  /// Load LLM1 settings and configure [LLMService]. Returns null (and logs)
  /// if the user has not yet set up an LLM provider.
  Future<LLMService?> _configureLlmFromSettings() async {
    final settings = LlmSettingsService.instance;
    if (!settings.isLoaded) await settings.load();
    if (!settings.isConfigured) {
      log.info('[Skills] LLM not configured — skipping auto-generation');
      return null;
    }
    final llm = LLMService();
    try {
      await TaskRunnerService.configureLlmFromParams(
        llmService: llm,
        providerKey: settings.provider.configKey,
        model: settings.model,
        apiKey: settings.apiKey,
        baseUrl: settings.baseUrl,
        useNativeToolCall: settings.useNativeToolCall,
      );
    } catch (e) {
      log.warning('[Skills] Failed to configure LLM from settings: $e');
      return null;
    }
    if (!llm.isConfigured) {
      log.warning('[Skills] LLM configuration did not succeed');
      return null;
    }
    llm.setUseSimplifiedPrompts(settings.isSlm);
    return llm;
  }

  Future<FunctionHint> _generateAndSave(McpToolDescriptor tool, String mcpType, LLMService llm, {bool forceReplace = false}) async {
    final isSlm = llm.useSimplifiedPrompts;

    // Build a rich parameter summary from JSON-schema for more useful prompts.
    final paramSummary = _buildParamSummary(tool.inputSchema);

    // ── Full-model skill ─────────────────────────────────────────────────
    final fullPrompt =
        'Write a concise MCP tool skill guide (max ${_maxTokensLlm ~/ 4} words) for the tool `${tool.name}`.\n'
        'Tool description: ${tool.description}\n'
        '${paramSummary.isNotEmpty ? 'Parameters: $paramSummary\n' : ''}'
        'Include: when to use this tool, key parameters, example usage pattern.\n'
        'Plain text only. No code blocks, no markdown headers.';

    // ── SLM skill ────────────────────────────────────────────────────────
    final slmPrompt =
        'Write a 1-sentence MCP skill for `${tool.name}`: ${tool.description}.'
        '${paramSummary.isNotEmpty ? ' Params: $paramSummary.' : ''}'
        ' Max ${_maxTokensSlm ~/ 3} words. Plain text only.';

    String fullText;
    String slmText;

    if (isSlm) {
      // When running SLM, generate the compact variant first and use a
      // shortened version of it for the full variant to avoid overloading
      // the small model with a complex instruction.
      slmText = await _callLlm(llm, slmPrompt, maxTokens: _maxTokensSlm);
      fullText = await _callLlm(llm, fullPrompt, maxTokens: _maxTokensLlm);
    } else {
      // For larger models: generate both independently.
      fullText = await _callLlm(llm, fullPrompt, maxTokens: _maxTokensLlm);
      slmText = await _callLlm(llm, slmPrompt, maxTokens: _maxTokensSlm);
    }

    final skill = FunctionHint.create(toolName: tool.name, mcpType: mcpType, skillText: fullText, skillTextSlm: slmText);

    await _db.save(skill);
    log.info('[Skills] Saved skill for ${tool.name}');
    return skill;
  }

  Future<String> _callLlm(LLMService llm, String userPrompt, {int maxTokens = 200}) async {
    final response = await llm.generateChatCompletion(
      messages: [
        ChatMessage(
          id: const Uuid().v4(),
          role: ChatRole.system,
          content: 'You write concise, practical MCP tool skill guides. Output plain text only — no markdown, no quotes.',
          timestamp: DateTime.now(),
        ),
        ChatMessage(id: const Uuid().v4(), role: ChatRole.user, content: userPrompt, timestamp: DateTime.now()),
      ],
      maxTokens: maxTokens,
      forceNoToolCalls: true,
    );
    return response.content.trim();
  }

  /// Builds a formatted string describing all parameters from a JSON Schema
  /// object, e.g.: "dluName (string, required): device name; detail (boolean,
  /// optional): include full details".
  String _buildParamSummary(Map<String, dynamic> schema) {
    try {
      final required = (schema['required'] as List?)?.cast<String>() ?? <String>[];
      final props = schema['properties'];
      if (props is! Map || props.isEmpty) {
        // No properties defined — fall back to listing required names only.
        return required.isEmpty ? '' : 'required: ${required.join(', ')}';
      }
      final parts = <String>[];
      for (final entry in (props).entries) {
        final name = entry.key as String;
        final prop = (entry.value as Map<dynamic, dynamic>?)?.cast<String, dynamic>() ?? <String, dynamic>{};
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

  /// Attempts a live HTTP discovery of the tools exposed by [server] by
  /// creating a short-lived [MCPClient] and calling [connect].  Returns the
  /// list of tool schema maps suitable for use in [ensureSkillsForBuiltInTools]
  /// on success, or an empty list if the server is unreachable or returns no
  /// tools within [_discoveryTimeout].
  static const Duration _discoveryTimeout = Duration(seconds: 10);

  Future<List<Map<String, dynamic>>> _tryDiscoverExternalServerSchemas(McpToolConfig server) async {
    MCPClient? client;
    try {
      client = MCPClient(server.serverUrl, bearerToken: server.apiKey);
      await client.connect().timeout(_discoveryTimeout);
      final tools = client.availableTools;
      if (tools.isEmpty) return const [];
      return tools
          .map(
            (t) => <String, dynamic>{
              'name': t.name,
              'description': t.description ?? '',
              'inputSchema': t.inputSchema ?? <String, dynamic>{},
            },
          )
          .toList();
    } catch (e) {
      log.debug('[Skills] Live discovery for ${server.serverUrl} failed: $e');
      return const [];
    } finally {
      client?.dispose();
    }
  }
}
