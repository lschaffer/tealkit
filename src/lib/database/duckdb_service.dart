import 'sqlite_service.dart';

/// Backwards-compatible database facade delegating all operations to [SqliteService].
///
/// Kept under the `DuckDbService` name so existing callers across `lib/` continue
/// working seamlessly without importing `dart_duckdb`.
class DuckDbService {
  static final DuckDbService _instance = DuckDbService._internal();
  factory DuckDbService() => _instance;
  DuckDbService._internal();

  final SqliteService _sqlite = SqliteService();

  String? get dbPath => _sqlite.dbPath;

  bool get isVectorExtensionLoaded => _sqlite.isVectorExtensionLoaded;

  Future<void> init({String? customPath}) => _sqlite.init(customPath: customPath);

  Future<void> initInMemory() => _sqlite.initInMemory();

  Future<void> close() => _sqlite.close();

  // ── Workflow Memory ──
  Future<void> saveWorkflowMemory({
    required String workflowId,
    required String runId,
    required String key,
    required String value,
    String scope = 'workflow',
    required String createdBy,
  }) =>
      _sqlite.saveWorkflowMemory(
        workflowId: workflowId,
        runId: runId,
        key: key,
        value: value,
        scope: scope,
        createdBy: createdBy,
      );

  Future<String?> getWorkflowMemory({
    required String workflowId,
    required String runId,
    required String key,
  }) =>
      _sqlite.getWorkflowMemory(
        workflowId: workflowId,
        runId: runId,
        key: key,
      );

  Future<Map<String, String>> getAllWorkflowMemories({
    required String workflowId,
    required String runId,
  }) =>
      _sqlite.getAllWorkflowMemories(workflowId: workflowId, runId: runId);

  Future<void> deleteWorkflowMemoriesForRun({
    required String workflowId,
    required String runId,
  }) =>
      _sqlite.deleteWorkflowMemoriesForRun(
        workflowId: workflowId,
        runId: runId,
      );

  // ── Tasks ──
  Future<void> saveTask(
    String id,
    String name,
    bool enabled,
    String? agentId,
    List<String> tags,
    Map<String, dynamic> data,
  ) =>
      _sqlite.saveTask(id, name, enabled, agentId, tags, data);

  Future<Map<String, dynamic>?> getTask(String id) => _sqlite.getTask(id);

  Future<List<Map<String, dynamic>>> getAllTasks({
    String? agentId,
    bool? enabledOnly,
  }) =>
      _sqlite.getAllTasks(agentId: agentId, enabledOnly: enabledOnly);

  Future<List<Map<String, dynamic>>> getDueTasks() => _sqlite.getDueTasks();

  Future<List<Map<String, dynamic>>> getTasksByTag(String tag) =>
      _sqlite.getTasksByTag(tag);

  Future<void> deleteTask(String id) => _sqlite.deleteTask(id);

  Future<int> deleteTasksByAgent(String agentId) =>
      _sqlite.deleteTasksByAgent(agentId);

  Future<List<Map<String, dynamic>>> searchTasks(String query) =>
      _sqlite.searchTasks(query);

  Future<int> countTasks({String? agentId}) =>
      _sqlite.countTasks(agentId: agentId);

  Future<void> updateExecution(
    String taskId,
    Map<String, dynamic> executionJson,
  ) =>
      _sqlite.updateExecution(taskId, executionJson);

  Future<void> toggleTask(String taskId, bool enabled) =>
      _sqlite.toggleTask(taskId, enabled);

  // ── Internal MCP Configs ──
  Future<void> saveInternalMcpConfig(
    String id,
    String taskId,
    String mcpType,
    Map<String, dynamic> params,
    bool enabled,
  ) =>
      _sqlite.saveInternalMcpConfig(id, taskId, mcpType, params, enabled);

  Future<List<Map<String, dynamic>>> getInternalMcpConfigs(String taskId) =>
      _sqlite.getInternalMcpConfigs(taskId);

  Future<void> deleteInternalMcpConfig(String id) =>
      _sqlite.deleteInternalMcpConfig(id);

  // ── Python Tools ──
  Future<void> savePyTool(dynamic def) => _sqlite.savePyTool(def);

  Future<List<Map<String, dynamic>>> getAllPyTools() => _sqlite.getAllPyTools();

  Future<void> deletePyTool(String id) => _sqlite.deletePyTool(id);

  // ── GitHub MCP Servers ──
  Future<void> saveGithubMcpServer(Map<String, dynamic> def) =>
      _sqlite.saveGithubMcpServer(def);

  Future<List<Map<String, dynamic>>> getAllGithubMcpServers() =>
      _sqlite.getAllGithubMcpServers();

  Future<void> deleteGithubMcpServer(String id) =>
      _sqlite.deleteGithubMcpServer(id);

  // ── Bulk / Export ──
  Future<List<Map<String, dynamic>>> exportTasks() => _sqlite.exportTasks();

  Future<int> importTasks(List<Map<String, dynamic>> tasksJson) =>
      _sqlite.importTasks(tasksJson);

  // ── Raw SQL ──
  Future<void> execute(String sql, [List<Object?> parameters = const []]) =>
      _sqlite.execute(sql, parameters);

  Future<List<List<dynamic>>> query(
    String sql, [
    List<Object?> parameters = const [],
  ]) =>
      _sqlite.query(sql, parameters);

  // ── Skill Definitions ──
  Future<List<Map<String, dynamic>>> getAllSkillDefMaps() =>
      _sqlite.getAllSkillDefMaps();

  Future<Map<String, dynamic>?> getSkillDefMap(String id) =>
      _sqlite.getSkillDefMap(id);

  Future<void> saveSkillDefMap({
    required String id,
    required String name,
    required String goal,
    required String description,
    required String skillDef,
    required List<String> toolNames,
    String? createdAt,
    String? updatedAt,
  }) =>
      _sqlite.saveSkillDefMap(
        id: id,
        name: name,
        goal: goal,
        description: description,
        skillDef: skillDef,
        toolNames: toolNames,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );

  Future<void> deleteSkillDef(String id) => _sqlite.deleteSkillDef(id);

  // ── Tool Hints ──
  Future<void> saveToolSkill({
    required String id,
    required String toolName,
    required String mcpType,
    required String skillText,
    required String skillTextSlm,
    required bool isEnabled,
    required bool isCustom,
  }) =>
      _sqlite.saveToolSkill(
        id: id,
        toolName: toolName,
        mcpType: mcpType,
        skillText: skillText,
        skillTextSlm: skillTextSlm,
        isEnabled: isEnabled,
        isCustom: isCustom,
      );

  Future<List<Map<String, dynamic>>> getAllToolSkills({String? mcpType}) =>
      _sqlite.getAllToolSkills(mcpType: mcpType);

  Future<List<Map<String, dynamic>>> getEnabledSkillsForTools(
    List<String> toolNames,
  ) =>
      _sqlite.getEnabledSkillsForTools(toolNames);

  Future<Set<String>> getToolNamesWithSkills() =>
      _sqlite.getToolNamesWithSkills();

  Future<void> deleteToolSkill(String id) => _sqlite.deleteToolSkill(id);

  Future<void> deleteToolSkillsByToolName(String toolName) =>
      _sqlite.deleteToolSkillsByToolName(toolName);

  // ── Subagent Definitions ──
  Future<List<Map<String, dynamic>>> getSubagentDefinitions() =>
      _sqlite.getSubagentDefinitions();

  Future<void> saveSubagentDefinition(Map<String, dynamic> data) =>
      _sqlite.saveSubagentDefinition(data);

  Future<void> deleteSubagentDefinition(String key) =>
      _sqlite.deleteSubagentDefinition(key);
}
