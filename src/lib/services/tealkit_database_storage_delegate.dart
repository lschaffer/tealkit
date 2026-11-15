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
  // LLM Config (Read-only bridge from TealKit LlmSettingsService;
  // Assistant LLM changes are strictly session-scoped)
  // ─────────────────────────────────────────────────────────────

  @override
  Future<void> saveLlmConfig(LlmConfig config) async {
    // Intentionally session-only: selecting or overriding an LLM inside
    // Assistant must NOT mutate global LlmSettingsService profiles/defaults
    // nor persist a sticky Assistant-specific LLM override across sessions.
    final p = await _prefs;
    if (p.containsKey('mcp_playground_llm_config')) {
      await p.remove('mcp_playground_llm_config');
    }
    log.verbose(
      '[TealKitStorage] Applied session-only LLM config (${config.provider.name} / ${config.model})',
    );
  }

  /// Converts a TealKit [tk_llm.NamedLlmProfile] to a Playground [LlmConfig]
  /// while preserving its profile [id] and [name].
  static LlmConfig fromNamedProfile(tk_llm.NamedLlmProfile profile) {
    return LlmConfig(
      id: profile.id,
      name: profile.name,
      provider: fromTealKitProvider(profile.provider),
      model: profile.model,
      apiKey: profile.apiKey,
      baseUrl: profile.baseUrl,
      temperature: profile.temperature,
      maxTokens: profile.maxTokens,
      isSlm: profile.isSlm,
      isMultiModal: profile.isMultiModal,
      topK: profile.topK,
      topP: profile.topP,
      repeatPenalty: profile.repeatPenalty,
      seed: profile.seed,
      thinking: profile.thinking,
      useNativeToolCall: profile.useNativeToolCall,
      useSafeToolCall: profile.useSafeToolCall,
      maxToolOutputSize: profile.maxToolOutputSize,
      tokenWarningThreshold: profile.tokenWarningThreshold,
    );
  }

  /// Returns the default LlmConfig derived directly from TealKit's LlmSettingsService.
  LlmConfig? getTealKitLlmConfig() {
    final service = tk_llm.LlmSettingsService.instance;
    final selected = service.selectedProfile;
    if (selected != null && selected.isConfigured) {
      return fromNamedProfile(selected);
    }
    if (!service.isConfigured) return null;
    return LlmConfig(
      id: selected?.id,
      name: selected?.name,
      provider: fromTealKitProvider(service.provider),
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

  @override
  Future<LlmConfig?> loadLlmConfig() async {
    final p = await _prefs;
    if (p.containsKey('mcp_playground_llm_config')) {
      await p.remove('mcp_playground_llm_config');
    }
    return getTealKitLlmConfig();
  }

  @override
  Future<void> saveLlmConfigs(
    List<LlmConfig> configs, {
    String? selectedId,
  }) async {
    // Session-scoped only: never persist Assistant session LLM switches back
    // to SharedPreferences or LlmSettingsService.
    final p = await _prefs;
    if (p.containsKey('mcp_playground_llm_profiles')) {
      await p.remove('mcp_playground_llm_profiles');
    }
    if (p.containsKey('mcp_playground_selected_llm_id')) {
      await p.remove('mcp_playground_selected_llm_id');
    }
  }

  @override
  Future<({List<LlmConfig> configs, String? selectedId})?> loadLlmConfigs() async {
    final p = await _prefs;
    if (p.containsKey('mcp_playground_llm_profiles')) {
      await p.remove('mcp_playground_llm_profiles');
    }
    if (p.containsKey('mcp_playground_selected_llm_id')) {
      await p.remove('mcp_playground_selected_llm_id');
    }

    final service = tk_llm.LlmSettingsService.instance;
    if (service.profiles.isEmpty) return null;
    final configs = service.profiles.map(fromNamedProfile).toList();
    final selectedProfile = service.selectedProfile;
    final selectedId = selectedProfile != null
        ? fromNamedProfile(selectedProfile).profileId
        : (configs.isNotEmpty ? configs.first.profileId : null);
    return (configs: configs, selectedId: selectedId);
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

  static tk_llm.LlmProvider toTealKitProvider(LlmProvider p) {
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

  static LlmProvider fromTealKitProvider(tk_llm.LlmProvider p) {
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
