import 'dart:convert';

import '../models/workflow_task.dart';
import '../services/app_logger.dart';
import 'duckdb_service.dart';

/// Task database service backed by DuckDB.
///
/// Replaces the previous Sembast-based implementation.
/// Tasks are stored as JSON documents in the DuckDB `tasks` table,
/// with indexed columns for common query patterns (id, name, enabled, agent_id, tags).
class TaskDatabaseService {
  final _duckDb = DuckDbService();

  // ── Singleton ──
  static final TaskDatabaseService _instance = TaskDatabaseService._internal();
  factory TaskDatabaseService() => _instance;
  TaskDatabaseService._internal();

  // ──────────────────────────────────────────────
  // Initialization
  // ──────────────────────────────────────────────

  /// Ensure the database is initialized.
  Future<void> init() async => _duckDb.init();

  Future<void> close() async => _duckDb.close();

  // ──────────────────────────────────────────────
  // CRUD Operations
  // ──────────────────────────────────────────────

  /// Create or update a task.
  Future<void> saveTask(WorkflowTask task) async {
    log.info('[DB] saveTask: id=${task.id} name="${task.name}"');
    final json = task.toJson();
    log.verbose('[DB] saveTask payload: ${truncate(json.toString())}');
    await _duckDb.saveTask(task.id, task.name, task.enabled, task.agentId, task.tags, json);
    log.info('[DB] saveTask: OK');
  }

  /// Get a single task by ID.
  Future<WorkflowTask?> getTask(String id) async {
    log.verbose('[DB] getTask: id=$id');
    final data = await _duckDb.getTask(id);
    if (data == null) {
      log.verbose('[DB] getTask: not found');
      return null;
    }
    log.verbose('[DB] getTask: found');
    return WorkflowTask.fromJson(data);
  }

  /// Get all tasks, optionally filtered.
  Future<List<WorkflowTask>> getAllTasks({String? agentId, bool? enabledOnly}) async {
    final rows = await _duckDb.getAllTasks(agentId: agentId, enabledOnly: enabledOnly);
    log.info('[DB] getAllTasks: found ${rows.length} tasks (agentId=$agentId, enabledOnly=$enabledOnly)');
    return rows.map((data) => WorkflowTask.fromJson(data)).toList();
  }

  /// Get tasks that are due to run (next_run <= now).
  Future<List<WorkflowTask>> getDueTasks() async {
    final rows = await _duckDb.getDueTasks();
    return rows.map((data) => WorkflowTask.fromJson(data)).toList();
  }

  /// Delete a task.
  Future<void> deleteTask(String id) async {
    log.info('[DB] deleteTask: id=$id');
    await _duckDb.deleteTask(id);
    log.info('[DB] deleteTask: OK');
  }

  /// Delete all tasks for an agent.
  Future<int> deleteTasksByAgent(String agentId) async {
    return _duckDb.deleteTasksByAgent(agentId);
  }

  /// Update only the execution state (after a run).
  Future<void> updateExecution(String taskId, TaskExecution execution) async {
    await _duckDb.updateExecution(taskId, execution.toJson());
  }

  /// Toggle task enabled/disabled.
  Future<void> toggleTask(String taskId, bool enabled) async {
    await _duckDb.toggleTask(taskId, enabled);
  }

  // ──────────────────────────────────────────────
  // Search & Queries
  // ──────────────────────────────────────────────

  /// Search tasks by name, description, or prompt.
  Future<List<WorkflowTask>> searchTasks(String query) async {
    final rows = await _duckDb.searchTasks(query);
    return rows.map((data) => WorkflowTask.fromJson(data)).toList();
  }

  /// Get tasks by tag.
  Future<List<WorkflowTask>> getTasksByTag(String tag) async {
    // DuckDB supports array operations
    final rows = await _duckDb.query(
      "SELECT data FROM tasks WHERE list_contains(tags, '${tag.replaceAll("'", "''")}') ORDER BY updated_at DESC",
    );
    return rows.map((r) {
      final jsonStr = r[0] as String;
      return WorkflowTask.fromJson(Map<String, dynamic>.from((r[0] is Map) ? r[0] as Map : _parseJson(jsonStr)));
    }).toList();
  }

  /// Count tasks.
  Future<int> countTasks({String? agentId}) async {
    return _duckDb.countTasks(agentId: agentId);
  }

  // ──────────────────────────────────────────────
  // Bulk Operations
  // ──────────────────────────────────────────────

  /// Import tasks from JSON list (e.g. backup restore).
  ///
  /// Parses each task through [WorkflowTask.fromJson] / [saveTask] so that
  /// any plain-text credentials arriving from a cross-device vault restore are
  /// re-encrypted with this device's [CredentialCipher] key before hitting the DB.
  Future<int> importTasks(List<Map<String, dynamic>> tasksJson) async {
    int count = 0;
    for (final json in tasksJson) {
      try {
        final task = WorkflowTask.fromJson(json);
        await saveTask(task);
        count++;
      } catch (e) {
        log.warning('[DB] importTasks: skipped invalid task: $e');
      }
    }
    return count;
  }

  /// Export all tasks as JSON list.
  Future<List<Map<String, dynamic>>> exportTasks({bool stripSecrets = true}) async {
    final tasks = await _duckDb.exportTasks();
    if (stripSecrets) {
      return tasks.map(_stripSecrets).toList();
    }
    return tasks;
  }

  // ──────────────────────────────────────────────
  // Helpers
  // ──────────────────────────────────────────────

  Map<String, dynamic> _parseJson(String jsonStr) {
    return Map<String, dynamic>.from(json.decode(jsonStr) as Map<String, dynamic>);
  }

  /// Remove API keys, passwords, tokens from export.
  Map<String, dynamic> _stripSecrets(Map<String, dynamic> json) {
    final copy = Map<String, dynamic>.from(json);

    // Strip LLM config secrets
    if (copy['llm_config'] is Map) {
      final llm = Map<String, dynamic>.from(copy['llm_config'] as Map);
      llm.remove('api_key');
      copy['llm_config'] = llm;
    }

    // Strip MCP tool secrets
    if (copy['mcp_tools'] is List) {
      copy['mcp_tools'] = (copy['mcp_tools'] as List).map((t) {
        final tool = Map<String, dynamic>.from(t as Map);
        tool.remove('api_key');
        tool.remove('api_password');
        return tool;
      }).toList();
    }

    // Strip provider auth
    if (copy['providers'] is Map) {
      final providers = Map<String, dynamic>.from(copy['providers'] as Map);
      if (providers['email'] is Map) {
        final email = Map<String, dynamic>.from(providers['email'] as Map);
        email.remove('auth_data');
        providers['email'] = email;
      }
      if (providers['web_search'] is Map) {
        final ws = Map<String, dynamic>.from(providers['web_search'] as Map);
        ws.remove('api_key');
        providers['web_search'] = ws;
      }
      copy['providers'] = providers;
    }

    // Strip notification secrets
    if (copy['notification'] is Map) {
      final notif = Map<String, dynamic>.from(copy['notification'] as Map);
      _stripUploadSecrets(notif);
      copy['notification'] = notif;
    }

    return copy;
  }

  void _stripUploadSecrets(Map<String, dynamic> notif) {
    if (notif['upload'] is Map) {
      final upload = Map<String, dynamic>.from(notif['upload'] as Map);
      for (final key in ['google_drive', 'one_drive']) {
        if (upload[key] is Map) {
          final target = Map<String, dynamic>.from(upload[key] as Map);
          target.remove('api_key');
          upload[key] = target;
        }
      }
      if (upload['sftp'] is Map) {
        final sftp = Map<String, dynamic>.from(upload['sftp'] as Map);
        sftp.remove('password');
        sftp.remove('private_key');
        upload['sftp'] = sftp;
      }
      notif['upload'] = upload;
    }
  }
}
