import '../models/agentic_task.dart';

/// Global reference to the active database adapter.
/// Set by [serverBootstrap] at startup.
ServerDatabaseAdapter serverDb = _UninitializedAdapter();

/// Factory for the default database adapter. Set by the entry point before
/// calling [serverBootstrap].  This indirection allows server_light to avoid
/// importing server_duckdb_adapter.dart (and transitively dart_duckdb).
ServerDatabaseAdapter Function() defaultDbFactory = () =>
    throw UnimplementedError('No default DB adapter factory set');

/// Abstract interface for the server database backend.
///
/// Two implementations exist:
///   - [ServerDuckDbAdapter] — DuckDB (full server)
///   - [ServerSqliteAdapter] — SQLite (server_light, ≤1GB RAM)
///
/// All REST API handlers and internal services use this interface so that
/// the database engine can be swapped at bootstrap time without changing
/// any route or service code.
abstract class ServerDatabaseAdapter {
  // ── Lifecycle ──────────────────────────────────────────────

  Future<void> init();
  Future<void> close();
  String get dataDir;

  /// Returns the engine identifier: 'duckdb' or 'sqlite'.
  String get engineType;

  // ── Tasks CRUD ─────────────────────────────────────────────

  Future<void> saveTask(AgenticTask task);
  Future<AgenticTask?> getTask(String id);
  Future<List<AgenticTask>> getAllTasks();
  Future<List<AgenticTask>> getDueTasks();
  Future<void> deleteTask(String id);
  Future<void> updateExecution(String taskId, TaskExecution execution);
  Future<void> toggleTask(String id, bool enabled);

  // ── Internal MCP Configs ───────────────────────────────────

  Future<void> saveInternalMcpConfig(String taskId, InternalMcpEntry entry);
  Future<List<InternalMcpEntry>> getInternalMcpConfigs(String taskId);

  // ── Python Tools ───────────────────────────────────────────

  Future<void> savePyTool(Map<String, dynamic> tool);
  Future<List<Map<String, dynamic>>> getAllPyTools();
  Future<void> setPyToolVenvReady(String id, bool ready);
  Future<void> deletePyTool(String id);

  // ── JavaScript Tools ───────────────────────────────────────

  Future<void> saveJsTool(Map<String, dynamic> tool);
  Future<List<Map<String, dynamic>>> getAllJsTools({bool activeOnly = false});
  Future<void> deleteJsTool(String id);

  // ── GitHub MCP Servers ─────────────────────────────────────

  Future<void> saveGithubMcpServer(GithubMcpServerDefinition server);
  Future<List<GithubMcpServerDefinition>> getAllGithubMcpServers();
  Future<void> deleteGithubMcpServer(String id);

  // ── Scheduler Log ──────────────────────────────────────────

  Future<void> logSchedulerRun({
    required String id,
    required String taskId,
    required String taskName,
    required DateTime startedAt,
    DateTime? endedAt,
    bool? success,
    String? message,
  });

  // ── Tool Skills ────────────────────────────────────────────

  Future<void> saveToolSkill(Map<String, dynamic> skill);
  Future<List<Map<String, dynamic>>> getAllToolSkills({String? mcpType});
  Future<void> deleteToolSkill(String id);
  Future<void> deleteToolSkillsByToolName(String toolName);
  Future<List<String>> getToolNamesWithSkills({String? mcpType});

  // ── Playground Sessions ────────────────────────────────────

  Future<void> savePlaygroundSession(Map<String, dynamic> session);
  Future<List<Map<String, dynamic>>> getAllPlaygroundSessions();
  Future<void> deletePlaygroundSession(String id);

  // ── Raw Access ─────────────────────────────────────────────

  Future<void> execute(String sql);
  Future<List<List<dynamic>>> query(String sql);

  // ── Import / Export ────────────────────────────────────────

  Future<List<Map<String, dynamic>>> exportTasks();
  Future<void> importTasks(
    List<Map<String, dynamic>> rows, {
    bool overwrite = false,
  });
}

/// Stub adapter used before [serverBootstrap] sets the real [serverDb].
class _UninitializedAdapter implements ServerDatabaseAdapter {
  @override
  String get dataDir => '';
  @override
  String get engineType => 'uninitialized';
  @override
  Future<void> init() async {}
  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}
