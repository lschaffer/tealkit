import 'dart:convert';
import 'package:dart_mcp_core/dart_mcp_core.dart';
import 'package:flutter_ui_mcp_core/flutter_ui_mcp_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/app_logger.dart';
import '../services/llm_settings_service.dart' as tk_llm;
import '../services/skill_def_database_service.dart';
import '../models/skill_def.dart' as tk_skill;

/// Custom storage delegate for TealKit that ensures all settings, tools,
/// and configurations persist directly into TealKit's database and preferences,
/// rather than loose YAML files.
class TealKitDatabaseStorageDelegate implements McpPlaygroundStorageDelegate {
  static const _kServers = 'mcp_playground_servers';
  static const _kSetups = 'mcp_playground_saved_setups';
  static const _kWorkflows = 'mcp_playground_workflows_list';
  static const _kEnabledTools = 'mcp_playground_enabled_tools';
  static const _kDisabledTools = 'mcp_playground_disabled_tools';
  static const _kInitializedClients = 'mcp_playground_initialized_clients';
  static const _kServerCatalog = 'mcp_playground_server_catalog';
  static const _kServerCatalogTimestamp = 'mcp_playground_server_catalog_timestamp';
  static const _kSkillsRoot = 'mcp_playground_skills_root_path';

  static final Set<String> _explicitlyDisabledTools = <String>{};
  static bool _disabledToolsLoaded = false;

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  static Future<void> _ensureDisabledToolsLoaded() async {
    if (_disabledToolsLoaded) return;
    final p = await SharedPreferences.getInstance();
    final list = p.getStringList(_kDisabledTools);
    if (list != null) {
      _explicitlyDisabledTools.addAll(list);
    }
    _disabledToolsLoaded = true;
  }

  /// Explicitly enables or disables [toolNames] on [controller] and persists
  /// user intent so background MCP server syncs never re-enable disabled tools.
  static Future<void> setToolsEnabled(
    PlaygroundController controller,
    Iterable<String> toolNames,
    bool enabled,
  ) async {
    await _ensureDisabledToolsLoaded();
    final p = await SharedPreferences.getInstance();
    if (enabled) {
      _explicitlyDisabledTools.removeAll(toolNames);
      await p.setStringList(_kDisabledTools, _explicitlyDisabledTools.toList());
      controller.toggleToolsEnabled(toolNames, true);
    } else {
      _explicitlyDisabledTools.addAll(toolNames);
      controller.enabledToolNames.removeAll(toolNames);
      await p.setStringList(_kDisabledTools, _explicitlyDisabledTools.toList());
      await p.setStringList(_kEnabledTools, controller.enabledToolNames.toList());
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      controller.notifyListeners();
    }
  }

  /// Replaces the full set of enabled tools on [controller] and records all
  /// other tools in [allAvailableNames] as explicitly disabled.
  static Future<void> replaceEnabledTools(
    PlaygroundController controller,
    Set<String> enabledNames,
    Set<String> allAvailableNames,
  ) async {
    await _ensureDisabledToolsLoaded();
    final p = await SharedPreferences.getInstance();
    _explicitlyDisabledTools
      ..removeAll(enabledNames)
      ..addAll(allAvailableNames.difference(enabledNames));
    await p.setStringList(_kDisabledTools, _explicitlyDisabledTools.toList());
    if (enabledNames.isEmpty) {
      controller.enabledToolNames.clear();
      await p.setStringList(_kEnabledTools, const <String>[]);
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      controller.notifyListeners();
    } else {
      controller.updateEnabledTools(enabledNames);
    }
  }

  // ─────────────────────────────────────────────────────────────
  // LLM Config (Bridges directly to TealKit LlmSettingsService)
  // ─────────────────────────────────────────────────────────────

  @override
  Future<void> saveLlmConfig(LlmConfig config) async {
    final service = tk_llm.LlmSettingsService.instance;
    final tkProvider = _toTealKitProvider(config.provider);

    final targetModel = config.model.isNotEmpty ? config.model : service.model;
    final targetApiKey = config.apiKey.isNotEmpty ? config.apiKey : service.apiKey;
    final targetBaseUrl = config.baseUrl.isNotEmpty ? config.baseUrl : service.baseUrl;

    final isSame = service.provider == tkProvider &&
        service.model == targetModel &&
        service.apiKey == targetApiKey &&
        service.baseUrl == targetBaseUrl &&
        (service.temperature - config.temperature).abs() < 0.001 &&
        service.maxTokens == config.maxTokens;

    if (!isSame) {
      await service.save(
        provider: tkProvider,
        model: targetModel,
        apiKey: targetApiKey,
        baseUrl: targetBaseUrl,
        temperature: config.temperature,
        maxTokens: config.maxTokens,
        maxToolOutputSize: service.maxToolOutputSize,
        tokenWarningThreshold: service.tokenWarningThreshold,
        isSlm: service.isSlm,
        isMultiModal: service.isMultiModal,
        topK: service.topK,
        topP: service.topP,
        repeatPenalty: service.repeatPenalty,
        seed: service.seed,
        thinking: service.thinking,
        useNativeToolCall: service.useNativeToolCall,
        useSafeToolCall: service.useSafeToolCall,
        enableToolParameterAutoRecovery: service.enableToolParameterAutoRecovery,
        injectToolCallingRules: service.injectToolCallingRules,
      );
      log.info('[TealKitStorage] Persisted active LLM config to TealKit DB/Prefs (${config.provider.name} / ${config.model})');
    }

    // Also persist as JSON in SharedPreferences for seamless McpPlayground reloads
    final p = await _prefs;
    await p.setString('mcp_playground_llm_config', jsonEncode(config.toJson()));
  }

  /// Returns the active LlmConfig derived directly from TealKit's LlmSettingsService.
  LlmConfig? getTealKitLlmConfig() {
    final service = tk_llm.LlmSettingsService.instance;
    final activeProfile = service.selectedProfile;
    if (activeProfile != null && activeProfile.isConfigured) {
      return _profileToPlaygroundConfig(activeProfile);
    }
    if (!service.isConfigured) return null;
    return LlmConfig(
      id: activeProfile?.id,
      name: activeProfile?.name,
      provider: _fromTealKitProvider(service.provider),
      model: service.model,
      apiKey: service.apiKey,
      baseUrl: service.baseUrl,
      temperature: service.temperature,
      maxTokens: service.maxTokens,
      isSlm: service.isSlm,
      isMultiModal: service.isMultiModal,
      topK: service.topK,
      topP: service.topP,
      repeatPenalty: service.repeatPenalty,
      seed: service.seed,
      thinking: service.thinking,
      useNativeToolCall: service.useNativeToolCall,
      useSafeToolCall: service.useSafeToolCall,
      maxToolOutputSize: service.maxToolOutputSize,
      tokenWarningThreshold: service.tokenWarningThreshold,
    );
  }

  static LlmConfig _profileToPlaygroundConfig(tk_llm.NamedLlmProfile p) {
    return LlmConfig(
      id: p.id,
      name: p.name,
      provider: _fromTealKitProvider(p.provider),
      model: p.model,
      apiKey: p.apiKey,
      baseUrl: p.baseUrl,
      temperature: p.temperature,
      maxTokens: p.maxTokens,
      isSlm: p.isSlm,
      isMultiModal: p.isMultiModal,
      topK: p.topK,
      topP: p.topP,
      repeatPenalty: p.repeatPenalty,
      seed: p.seed,
      thinking: p.thinking,
      useNativeToolCall: p.useNativeToolCall,
      useSafeToolCall: p.useSafeToolCall,
      maxToolOutputSize: p.maxToolOutputSize,
      tokenWarningThreshold: p.tokenWarningThreshold,
    );
  }

  @override
  Future<LlmConfig?> loadLlmConfig() async {
    // 1. Always prioritize TealKit's native LlmSettingsService if configured!
    final tkConfig = getTealKitLlmConfig();
    if (tkConfig != null) {
      return tkConfig;
    }

    // 2. Fall back to cached JSON if any
    final p = await _prefs;
    final raw = p.getString('mcp_playground_llm_config');
    if (raw != null) {
      try {
        final cfg = LlmConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        if (cfg.isConfigured) return cfg;
      } catch (e) {
        log.warning('[TealKitStorage] Error decoding cached LLM config: $e');
      }
    }

    return null;
  }

  @override
  Future<void> saveLlmConfigs(
    List<LlmConfig> configs, {
    String? selectedId,
  }) async {
    final p = await _prefs;
    final list = configs.map((c) => c.toJson()).toList();
    await p.setString('mcp_playground_llm_profiles', jsonEncode(list));
    if (selectedId != null) {
      await p.setString('mcp_playground_selected_llm_id', selectedId);
    }
  }

  @override
  Future<({List<LlmConfig> configs, String? selectedId})?> loadLlmConfigs() async {
    final service = tk_llm.LlmSettingsService.instance;
    if (service.profiles.isNotEmpty) {
      final tkConfigs = service.profiles
          .map(_profileToPlaygroundConfig)
          .toList();
      final selectedProfile = service.selectedProfile;
      final selectedId = selectedProfile != null
          ? _profileToPlaygroundConfig(selectedProfile).profileId
          : (tkConfigs.isNotEmpty ? tkConfigs.first.profileId : null);
      return (configs: tkConfigs, selectedId: selectedId);
    }

    final p = await _prefs;
    final raw = p.getString('mcp_playground_llm_profiles');
    final sel = p.getString('mcp_playground_selected_llm_id');
    if (raw == null || raw.isEmpty) return null;
    try {
      final list = jsonDecode(raw) as List;
      final configs = list
          .map((item) => LlmConfig.fromJson(item as Map<String, dynamic>))
          .toList();
      return (configs: configs, selectedId: sel);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> saveToolStrategy({
    required String strategy,
    required bool injectRules,
    required String filterSource,
  }) async {
    final p = await _prefs;
    await p.setString('mcp_playground_tool_delivery_strategy', strategy);
    await p.setBool('mcp_playground_inject_tool_calling_rules', injectRules);
    await p.setString('mcp_playground_tool_filtering_llm_source', filterSource);
  }

  @override
  Future<({String strategy, bool injectRules, String filterSource})?>
  loadToolStrategy() async {
    final p = await _prefs;
    final strategy = p.getString('mcp_playground_tool_delivery_strategy');
    final inject = p.getBool('mcp_playground_inject_tool_calling_rules');
    final filter = p.getString('mcp_playground_tool_filtering_llm_source');
    if (strategy == null && inject == null && filter == null) return null;
    return (
      strategy: strategy ?? 'auto',
      injectRules: inject ?? true,
      filterSource: filter ?? 'llm1',
    );
  }

  // ─────────────────────────────────────────────────────────────
  // MCP Servers
  // ─────────────────────────────────────────────────────────────

  @override
  Future<void> saveServers(List<McpServerConfig> servers) async {
    final p = await _prefs;
    final list = servers.map((s) => s.toJson()).toList();
    await p.setString(_kServers, jsonEncode(list));
  }

  @override
  Future<List<McpServerConfig>> loadServers() async {
    final p = await _prefs;
    final raw = p.getString(_kServers);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => McpServerConfig.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Saved Playground Setups
  // ─────────────────────────────────────────────────────────────

  @override
  Future<void> saveSetups(List<SavedPlaygroundSetup> setups) async {
    final p = await _prefs;
    final list = setups.map((s) => s.toJson()).toList();
    await p.setString(_kSetups, jsonEncode(list));
  }

  @override
  Future<List<SavedPlaygroundSetup>> loadSetups() async {
    final p = await _prefs;
    final raw = p.getString(_kSetups);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => SavedPlaygroundSetup.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Skills (Bridges to TealKit SkillDefDatabaseService)
  // ─────────────────────────────────────────────────────────────

  @override
  Future<void> saveSkills(List<SkillDef> skills) async {
    for (final s in skills) {
      final tkSkillDef = tk_skill.SkillDef(
        id: s.id,
        name: s.name,
        goal: s.goal,
        description: s.description,
        skillDef: s.skillDef,
        toolNames: s.toolNames,
        createdAt: s.createdAt,
        updatedAt: s.updatedAt,
      );
      await SkillDefDatabaseService.instance.saveSkill(tkSkillDef);
    }
  }

  @override
  Future<List<SkillDef>> loadSkills() async {
    try {
      final dbSkills = await SkillDefDatabaseService.instance.getAllSkills();
      return dbSkills
          .map(
            (s) => SkillDef(
              id: s.id,
              name: s.name,
              goal: s.goal,
              description: s.description,
              skillDef: s.skillDef,
              toolNames: s.toolNames,
              createdAt: s.createdAt,
              updatedAt: s.updatedAt,
            ),
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Workflows
  // ─────────────────────────────────────────────────────────────

  @override
  Future<void> saveWorkflows(List<PlaygroundWorkflow> workflows) async {
    final p = await _prefs;
    final list = workflows.map((w) => w.toJson()).toList();
    await p.setString(_kWorkflows, jsonEncode(list));
  }

  @override
  Future<List<PlaygroundWorkflow>> loadWorkflows() async {
    final p = await _prefs;
    final raw = p.getString(_kWorkflows);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => PlaygroundWorkflow.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Tools & Client States
  // ─────────────────────────────────────────────────────────────

  @override
  Future<void> saveEnabledTools(Set<String> tools) async {
    await _ensureDisabledToolsLoaded();
    if (_explicitlyDisabledTools.isNotEmpty) {
      tools.removeAll(_explicitlyDisabledTools);
    }
    final p = await _prefs;
    await p.setStringList(_kEnabledTools, tools.toList());
  }

  @override
  Future<Set<String>> loadEnabledTools() async {
    await _ensureDisabledToolsLoaded();
    final p = await _prefs;
    final list = p.getStringList(_kEnabledTools);
    final result = list?.toSet() ?? <String>{};
    if (_explicitlyDisabledTools.isNotEmpty) {
      result.removeAll(_explicitlyDisabledTools);
    }
    return result;
  }

  @override
  Future<void> saveInitializedClients(Set<String> clients) async {
    final p = await _prefs;
    await p.setStringList(_kInitializedClients, clients.toList());
  }

  @override
  Future<Set<String>> loadInitializedClients() async {
    final p = await _prefs;
    final list = p.getStringList(_kInitializedClients);
    return list?.toSet() ?? {};
  }

  @override
  Future<void> saveCachedServerTools(String serverId, List<MCPTool> tools) async {
    final p = await _prefs;
    final list = tools.map((t) => t.toJson()).toList();
    await p.setString('mcp_cached_tools_$serverId', jsonEncode(list));
  }

  @override
  Future<List<MCPTool>> loadCachedServerTools(String serverId) async {
    final p = await _prefs;
    final raw = p.getString('mcp_cached_tools_$serverId');
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => MCPTool.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  @override
  Future<void> saveServerCatalog(String catalogJson) async {
    final p = await _prefs;
    await p.setString(_kServerCatalog, catalogJson);
  }

  @override
  Future<String?> loadServerCatalog() async {
    final p = await _prefs;
    return p.getString(_kServerCatalog);
  }

  @override
  Future<void> saveServerCatalogTimestamp(int timestamp) async {
    final p = await _prefs;
    await p.setInt(_kServerCatalogTimestamp, timestamp);
  }

  @override
  Future<int?> loadServerCatalogTimestamp() async {
    final p = await _prefs;
    return p.getInt(_kServerCatalogTimestamp);
  }

  @override
  Future<void> saveSkillsRootPath(String path) async {
    final p = await _prefs;
    await p.setString(_kSkillsRoot, path);
  }

  @override
  Future<String?> loadSkillsRootPath() async {
    final p = await _prefs;
    return p.getString(_kSkillsRoot);
  }

  // ─────────────────────────────────────────────────────────────
  // Helper Provider Converters
  // ─────────────────────────────────────────────────────────────

  static tk_llm.LlmProvider _toTealKitProvider(LlmProvider p) {
    switch (p) {
      case LlmProvider.gemini:
        return tk_llm.LlmProvider.gemini;
      case LlmProvider.openai:
        return tk_llm.LlmProvider.openai;
      case LlmProvider.claude:
        return tk_llm.LlmProvider.claude;
      case LlmProvider.mistral:
        return tk_llm.LlmProvider.mistral;
      case LlmProvider.ollama:
        return tk_llm.LlmProvider.ollama;
      case LlmProvider.openaiCompatible:
        return tk_llm.LlmProvider.openaiCompatible;
      case LlmProvider.embedded:
        return tk_llm.LlmProvider.embedded;
      default:
        return tk_llm.LlmProvider.none;
    }
  }

  static LlmProvider _fromTealKitProvider(tk_llm.LlmProvider p) {
    switch (p) {
      case tk_llm.LlmProvider.gemini:
        return LlmProvider.gemini;
      case tk_llm.LlmProvider.openai:
        return LlmProvider.openai;
      case tk_llm.LlmProvider.claude:
        return LlmProvider.claude;
      case tk_llm.LlmProvider.mistral:
        return LlmProvider.mistral;
      case tk_llm.LlmProvider.ollama:
        return LlmProvider.ollama;
      case tk_llm.LlmProvider.openaiCompatible:
        return LlmProvider.openaiCompatible;
      case tk_llm.LlmProvider.embedded:
        return LlmProvider.embedded;
      default:
        return LlmProvider.none;
    }
  }
}
