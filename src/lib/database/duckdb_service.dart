import 'dart:convert';
import 'dart:io';

import 'package:dart_duckdb/dart_duckdb.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../services/app_logger.dart';
import '../models/workflow_task.dart';


/// Central DuckDB service — single database for the entire app.
///
/// Provides:
///   • Task storage (replaces Sembast)
///   • Content indexing tables (for doc-search-mcp, website-search-mcp)
///   • General-purpose SQL access for internal MCP servers
class DuckDbService {
  static const String _dbFileName = 'mobile_ai_agent.duckdb';

  Database? _db;
  Connection? _conn;
  String? _dbPath;

  // ── Singleton ──
  static final DuckDbService _instance = DuckDbService._internal();
  factory DuckDbService() => _instance;
  DuckDbService._internal();

  /// Path to the open database file, or null if not yet initialised.
  String? get dbPath => _dbPath;

  // ──────────────────────────────────────────────
  // Lifecycle
  // ──────────────────────────────────────────────

  /// Initialize and open the database.
  Future<void> init() async {
    if (_db != null) return; // already initialized

    final supportDir = await getApplicationSupportDirectory();
    final dbDir = p.join(supportDir.path, 'mobile_ai_agent');
    await Directory(dbDir).create(recursive: true);
    final dbPath = p.join(dbDir, _dbFileName);

    await _migrateLegacyDatabaseIfNeeded(dbPath);

    log.info('[DuckDB] Opening database at: $dbPath');

    try {
      await _openDatabase(dbPath);
    } catch (e) {
      if (_isWalReplayError(e)) {
        log.warning('[DuckDB] WAL replay failed. Attempting recovery by archiving WAL and reopening. Error: $e');
        await _archiveWalFile(dbPath);
        await _openDatabase(dbPath);
      } else if (_isAlreadyOpenError(e)) {
        // Hot-restart on Windows/Linux: Dart VM resets _db to null but the native
        // DuckDB library still holds the OS file lock from the previous run.
        // Deleting the lock file releases it so we can re-open cleanly.
        log.warning('[DuckDB] Database appears locked (hot-restart?). Releasing lock file and retrying. Error: $e');
        await _deleteLockFile(dbPath);
        await _openDatabase(dbPath);
      } else {
        rethrow;
      }
    }

    log.info('[DuckDB] Database opened successfully');

    await _createTables();
    await _migrateTasksToOrchestratorPattern();
  }


  Future<void> _openDatabase(String dbPath) async {
    _db = await duckdb.open(dbPath);
    _conn = await duckdb.connect(_db!);
    _dbPath = dbPath;
  }

  bool _isWalReplayError(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('failure while replaying wal') ||
        message.contains('calling databasemanager::getdefaultdatabase') ||
        message.contains('.duckdb.wal');
  }

  bool _isAlreadyOpenError(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('already opened') ||
        message.contains('database is locked') ||
        message.contains('unable to lock') ||
        message.contains('could not set lock') ||
        message.contains('access is denied') ||
        message.contains('.duckdb.lock');
  }

  Future<void> _deleteLockFile(String dbPath) async {
    final lockFile = File('$dbPath.lock');
    if (await lockFile.exists()) {
      await lockFile.delete();
      log.info('[DuckDB] Deleted stale lock file: ${lockFile.path}');
    }
  }

  Future<void> _archiveWalFile(String dbPath) async {
    final walPath = '$dbPath.wal';
    final walFile = File(walPath);
    if (!await walFile.exists()) return;

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final archived = '$walPath.corrupt.$timestamp';
    await walFile.rename(archived);
    log.warning('[DuckDB] Archived corrupted WAL to: $archived');
  }

  Future<void> _migrateLegacyDatabaseIfNeeded(String newDbPath) async {
    final newDbFile = File(newDbPath);
    if (await newDbFile.exists()) return;

    final legacyDocsDir = await getApplicationDocumentsDirectory();
    final legacyDbPath = p.join(legacyDocsDir.path, 'mobile_ai_agent', _dbFileName);
    final legacyDbFile = File(legacyDbPath);
    if (!await legacyDbFile.exists()) return;

    await legacyDbFile.copy(newDbPath);
    log.info('[DuckDB] Migrated legacy DB from: $legacyDbPath -> $newDbPath');
  }

  /// Initialize with an in-memory database (for testing).
  /// Avoids platform-channel dependencies (path_provider).
  Future<void> initInMemory() async {
    if (_db != null) return;

    log.info('[DuckDB] Opening in-memory database (test mode)');
    _db = await duckdb.open(':memory:');
    _conn = await duckdb.connect(_db!);
    log.info('[DuckDB] In-memory database opened successfully');

    await _createTables();
    await _migrateTasksToOrchestratorPattern();
  }


  /// Get a connection (auto-initializes if needed).
  Future<Connection> get connection async {
    if (_conn == null) await init();
    return _conn!;
  }

  /// Close the database.
  Future<void> close() async {
    log.info('[DuckDB] Closing database');
    await _conn?.dispose();
    await _db?.dispose();
    _conn = null;
    _db = null;
  }

  // ──────────────────────────────────────────────
  // Schema
  // ──────────────────────────────────────────────

  Future<void> _createTables() async {
    final conn = _conn!;

    // ── Tasks table: stores the full WorkflowTask as JSON ──
    await conn.execute('''
      CREATE TABLE IF NOT EXISTS tasks (
        id        VARCHAR PRIMARY KEY,
        name      VARCHAR NOT NULL,
        enabled   BOOLEAN DEFAULT TRUE,
        agent_id  VARCHAR,
        tags      VARCHAR[],
        data      JSON NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )
    ''');

    // ── Internal MCP configs: per-task init parameters for built-in MCPs ──
    await conn.execute('''
      CREATE TABLE IF NOT EXISTS internal_mcp_configs (
        id        VARCHAR PRIMARY KEY,
        task_id   VARCHAR NOT NULL,
        mcp_type  VARCHAR NOT NULL,
        params    JSON NOT NULL,
        enabled   BOOLEAN DEFAULT TRUE,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )
    ''');

    // ── Document index table for document-search MCP ──
    await conn.execute('''
      CREATE TABLE IF NOT EXISTS document_index (
        id            VARCHAR PRIMARY KEY,
        root_path     VARCHAR NOT NULL,
        file_path     VARCHAR NOT NULL,
        file_name     VARCHAR NOT NULL,
        file_type     VARCHAR NOT NULL,
        content_text  TEXT,
        embedding_json TEXT,
        file_size     BIGINT,
        last_modified VARCHAR,
        indexed_at    VARCHAR DEFAULT CURRENT_TIMESTAMP
      )
    ''');

    try {
      await conn.execute('ALTER TABLE document_index ADD COLUMN IF NOT EXISTS embedding_json TEXT');
    } catch (_) {
      // no-op for engines without ADD COLUMN IF NOT EXISTS support
    }

    // ── Website index table for website-search MCP ──
    await conn.execute('''
      CREATE TABLE IF NOT EXISTS website_index (
        id              VARCHAR PRIMARY KEY,
        seed_url        VARCHAR NOT NULL,
        url             VARCHAR NOT NULL,
        domain          VARCHAR NOT NULL,
        title           VARCHAR,
        content_text    TEXT,
        embedding_json  TEXT,
        http_status     INTEGER,
        indexed_at      VARCHAR DEFAULT CURRENT_TIMESTAMP
      )
    ''');

    // ── Python tools table ────────────────────────────────────────────────
    await conn.execute('''
      CREATE TABLE IF NOT EXISTS py_tools (
        id                VARCHAR PRIMARY KEY,
        name              VARCHAR NOT NULL,
        description       VARCHAR DEFAULT '',
        input_schema      JSON NOT NULL,
        code              TEXT NOT NULL,
        requirements      TEXT DEFAULT '',
        venv_ready        BOOLEAN DEFAULT FALSE,
        is_active         BOOLEAN DEFAULT TRUE,
        generation_prompt TEXT DEFAULT '',
        created_at        TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at        TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )
    ''');

    // ── GitHub MCP servers registry ───────────────────────────────────────
    await conn.execute('''
      CREATE TABLE IF NOT EXISTS github_mcp_servers (
        id                VARCHAR PRIMARY KEY,
        name              VARCHAR NOT NULL,
        display_name      VARCHAR NOT NULL,
        description       TEXT DEFAULT '',
        github_url        VARCHAR DEFAULT '',
        language          VARCHAR DEFAULT 'python',
        install_type      VARCHAR DEFAULT 'uvx',
        package_name      VARCHAR NOT NULL,
        entry_point       VARCHAR,
        launch_args       JSON DEFAULT '[]',
        required_env_vars JSON DEFAULT '[]',
        env_vars          JSON DEFAULT '{}',
        category          VARCHAR DEFAULT 'other',
        is_installed      BOOLEAN DEFAULT FALSE,
        is_active         BOOLEAN DEFAULT FALSE,
        is_manual         BOOLEAN DEFAULT FALSE,
        installed_at      TIMESTAMP,
        created_at        TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )
    ''');

    try {
      await conn.execute('ALTER TABLE github_mcp_servers ADD COLUMN IF NOT EXISTS is_manual BOOLEAN DEFAULT FALSE');
    } catch (_) {
      // no-op — column already exists or engine variant doesn't support IF NOT EXISTS
    }

    // ── System metadata table — used by TrialService for trial management ──
    // Stores key/value pairs such as install_ts, last_run_ts, and hw_hash.
    // Intentionally schema-less so values can be added without migrations.
    await conn.execute('''
      CREATE TABLE IF NOT EXISTS _sys_meta (
        key   VARCHAR PRIMARY KEY,
        value VARCHAR NOT NULL
      )
    ''');

    // ── Tool Hints table — LLM-generated usage guides per MCP tool ──────
    await conn.execute('''
      CREATE TABLE IF NOT EXISTS tool_skills (
        id              VARCHAR PRIMARY KEY,
        tool_name       VARCHAR NOT NULL,
        mcp_type        VARCHAR NOT NULL,
        skill_text      TEXT NOT NULL,
        skill_text_slm  TEXT NOT NULL,
        is_enabled      BOOLEAN DEFAULT TRUE,
        is_custom       BOOLEAN DEFAULT FALSE,
        generated_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )
    ''');

    log.info('[DuckDB] Tables created / verified');
  }

  // ──────────────────────────────────────────────
  // Task CRUD
  // ──────────────────────────────────────────────

  /// Upsert a task (insert or replace).
  Future<void> saveTask(String id, String name, bool enabled, String? agentId, List<String> tags, Map<String, dynamic> data) async {
    final conn = await connection;
    final jsonStr = _esc(jsonEncode(data));
    final tagsStr = tags.map((t) => "'$t'").join(', ');
    final now = DateTime.now().toIso8601String();

    log.info('[DuckDB] saveTask: id=$id name="$name"');

    // Use INSERT OR REPLACE
    await conn.execute('''
      INSERT OR REPLACE INTO tasks (id, name, enabled, agent_id, tags, data, created_at, updated_at)
      VALUES ('${_esc(id)}', '${_esc(name)}', $enabled, ${agentId != null ? "'${_esc(agentId)}'" : 'NULL'},
              [$tagsStr], '$jsonStr'::JSON, '$now', '$now')
    ''');
    log.info('[DuckDB] saveTask: OK');
  }

  /// Get a single task by ID. Returns the JSON data map or null.
  Future<Map<String, dynamic>?> getTask(String id) async {
    final conn = await connection;
    log.verbose('[DuckDB] getTask: id=$id');

    final result = await conn.query("SELECT data FROM tasks WHERE id = '$id'");
    final rows = result.fetchAll();
    if (rows.isEmpty) {
      log.verbose('[DuckDB] getTask: not found');
      return null;
    }
    try {
      return _decodeJsonMap(rows.first[0]);
    } catch (e) {
      log.warning('[DuckDB] getTask: invalid JSON payload for id=$id: $e');
      return null;
    }
  }

  /// Get all tasks, optionally filtered.
  Future<List<Map<String, dynamic>>> getAllTasks({String? agentId, bool? enabledOnly}) async {
    final conn = await connection;

    final conditions = <String>[];
    if (agentId != null) conditions.add("agent_id = '${_esc(agentId)}'");
    if (enabledOnly == true) conditions.add('enabled = TRUE');

    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';
    final result = await conn.query('SELECT data FROM tasks $where ORDER BY updated_at DESC');
    final rows = result.fetchAll();
    log.info('[DuckDB] getAllTasks: found ${rows.length} tasks (agentId=$agentId, enabledOnly=$enabledOnly)');
    final tasks = <Map<String, dynamic>>[];
    for (final row in rows) {
      try {
        tasks.add(_decodeJsonMap(row[0]));
      } catch (e) {
        log.warning('[DuckDB] getAllTasks: skipped invalid task JSON row: $e');
      }
    }
    return tasks;
  }

  /// Get tasks that are due to run.
  Future<List<Map<String, dynamic>>> getDueTasks() async {
    final conn = await connection;
    final now = DateTime.now().toIso8601String();

    final result = await conn.query('''
      SELECT data FROM tasks
      WHERE enabled = TRUE
        AND (json_extract_string(data, '\$.execution.next_run') IS NULL
             OR json_extract_string(data, '\$.execution.next_run') <= '$now')
      ORDER BY updated_at DESC
    ''');
    final rows = result.fetchAll();
    final tasks = <Map<String, dynamic>>[];
    for (final row in rows) {
      try {
        tasks.add(_decodeJsonMap(row[0]));
      } catch (e) {
        log.warning('[DuckDB] getDueTasks: skipped invalid task JSON row: $e');
      }
    }
    return tasks;
  }

  /// Delete a task by ID.
  Future<void> deleteTask(String id) async {
    final conn = await connection;
    log.info('[DuckDB] deleteTask: id=$id');
    await conn.execute("DELETE FROM tasks WHERE id = '$id'");
    // Also clean up internal MCP configs for this task
    await conn.execute("DELETE FROM internal_mcp_configs WHERE task_id = '$id'");
    log.info('[DuckDB] deleteTask: OK');
  }

  /// Delete all tasks for an agent.
  Future<int> deleteTasksByAgent(String agentId) async {
    final conn = await connection;
    final res = await conn.query("SELECT id FROM tasks WHERE agent_id = '${_esc(agentId)}'");
    final ids = res.fetchAll().map((r) => r[0].toString()).toList();
    if (ids.isEmpty) return 0;

    await conn.execute("DELETE FROM tasks WHERE agent_id = '${_esc(agentId)}'");
    // Clean up internal MCP configs
    for (final id in ids) {
      await conn.execute("DELETE FROM internal_mcp_configs WHERE task_id = '$id'");
    }
    return ids.length;
  }

  /// Search tasks by name, description, or prompt (SQL LIKE).
  Future<List<Map<String, dynamic>>> searchTasks(String query) async {
    final conn = await connection;
    final q = _esc(query.toLowerCase());

    final result = await conn.query('''
      SELECT data FROM tasks
      WHERE LOWER(name) LIKE '%$q%'
         OR LOWER(COALESCE(json_extract_string(data, '\$.description'), '')) LIKE '%$q%'
         OR LOWER(COALESCE(json_extract_string(data, '\$.prompt'), '')) LIKE '%$q%'
      ORDER BY updated_at DESC
    ''');
    final rows = result.fetchAll();
    final tasks = <Map<String, dynamic>>[];
    for (final row in rows) {
      try {
        tasks.add(_decodeJsonMap(row[0]));
      } catch (e) {
        log.warning('[DuckDB] searchTasks: skipped invalid task JSON row: $e');
      }
    }
    return tasks;
  }

  /// Count tasks.
  Future<int> countTasks({String? agentId}) async {
    final conn = await connection;
    final where = agentId != null ? "WHERE agent_id = '${_esc(agentId)}'" : '';
    final result = await conn.query('SELECT COUNT(*) FROM tasks $where');
    final rows = result.fetchAll();
    return (rows.first[0] as int?) ?? 0;
  }

  /// Update only the execution state (partial update via JSON merge).
  Future<void> updateExecution(String taskId, Map<String, dynamic> executionJson) async {
    final conn = await connection;
    final existing = await getTask(taskId);
    if (existing == null) return;

    existing['execution'] = executionJson;
    existing['updated_at'] = DateTime.now().toIso8601String();
    final jsonStr = _esc(jsonEncode(existing));
    final now = DateTime.now().toIso8601String();

    await conn.execute('''
      UPDATE tasks SET data = '$jsonStr'::JSON, updated_at = '$now'
      WHERE id = '${_esc(taskId)}'
    ''');
  }

  /// Toggle task enabled/disabled.
  Future<void> toggleTask(String taskId, bool enabled) async {
    final conn = await connection;
    final existing = await getTask(taskId);
    if (existing == null) return;

    existing['enabled'] = enabled;
    existing['updated_at'] = DateTime.now().toIso8601String();
    final jsonStr = _esc(jsonEncode(existing));
    final now = DateTime.now().toIso8601String();

    await conn.execute('''
      UPDATE tasks SET enabled = $enabled, data = '$jsonStr'::JSON, updated_at = '$now'
      WHERE id = '${_esc(taskId)}'
    ''');
  }

  // ──────────────────────────────────────────────
  // Internal MCP Config CRUD
  // ──────────────────────────────────────────────

  /// Save an internal MCP configuration for a task.
  Future<void> saveInternalMcpConfig(String id, String taskId, String mcpType, Map<String, dynamic> params, bool enabled) async {
    final conn = await connection;
    final jsonStr = _esc(jsonEncode(params));
    final now = DateTime.now().toIso8601String();

    await conn.execute('''
      INSERT OR REPLACE INTO internal_mcp_configs
        (id, task_id, mcp_type, params, enabled, created_at, updated_at)
      VALUES ('${_esc(id)}', '${_esc(taskId)}', '${_esc(mcpType)}', '$jsonStr'::JSON,
              $enabled, '$now', '$now')
    ''');
  }

  /// Get all internal MCP configs for a task.
  Future<List<Map<String, dynamic>>> getInternalMcpConfigs(String taskId) async {
    final conn = await connection;
    final result = await conn.query('''
      SELECT id, mcp_type, params, enabled FROM internal_mcp_configs
      WHERE task_id = '$taskId'
      ORDER BY mcp_type ASC
    ''');
    final rows = result.fetchAll();
    return rows
        .map(
          (r) => {
            'id': r[0].toString(),
            'mcp_type': r[1].toString(),
            'params': jsonDecode(r[2].toString()) as Map<String, dynamic>,
            'enabled': r[3] as bool,
          },
        )
        .toList();
  }

  /// Delete an internal MCP config.
  Future<void> deleteInternalMcpConfig(String id) async {
    final conn = await connection;
    await conn.execute("DELETE FROM internal_mcp_configs WHERE id = '$id'");
  }

  // ──────────────────────────────────────────────
  // Python Tool CRUD
  // ──────────────────────────────────────────────

  /// Upsert a Python tool definition.
  Future<void> savePyTool(dynamic def) async {
    final conn = await connection;
    final id = _esc(def.id as String);
    final name = _esc(def.name as String);
    final desc = _esc(def.description as String? ?? '');
    final schema = _esc(jsonEncode(def.inputSchema));
    final code = _esc(def.code as String? ?? '');
    final reqs = _esc(def.requirements as String? ?? '');
    final venvReady = (def.venvReady as bool? ?? false) ? 'TRUE' : 'FALSE';
    final isActive = (def.isActive as bool? ?? true) ? 'TRUE' : 'FALSE';
    final genPrompt = _esc(def.generationPrompt as String? ?? '');
    final now = DateTime.now().toIso8601String();

    await conn.execute('''
      INSERT OR REPLACE INTO py_tools
        (id, name, description, input_schema, code, requirements,
         venv_ready, is_active, generation_prompt, created_at, updated_at)
      VALUES
        ('$id', '$name', '$desc', '$schema'::JSON, '$code', '$reqs',
         $venvReady, $isActive, '$genPrompt', '$now', '$now')
    ''');
    log.info('[DuckDB] savePyTool: $id "$name"');
  }

  /// Return all Python tools as raw JSON maps.
  Future<List<Map<String, dynamic>>> getAllPyTools() async {
    final conn = await connection;
    final result = await conn.query('''
      SELECT id, name, description, input_schema, code, requirements,
             venv_ready, is_active, generation_prompt, created_at, updated_at
      FROM py_tools
      ORDER BY updated_at DESC
    ''');
    return result.fetchAll().map((r) {
      Map<String, dynamic> schema;
      try {
        final raw = r[3];
        schema = raw is Map<String, dynamic>
            ? raw
            : (raw is Map ? Map<String, dynamic>.from(raw) : jsonDecode(raw.toString()) as Map<String, dynamic>);
      } catch (_) {
        schema = {};
      }
      return {
        'id': r[0].toString(),
        'name': r[1].toString(),
        'description': r[2]?.toString() ?? '',
        'inputSchema': schema,
        'code': r[4]?.toString() ?? '',
        'requirements': r[5]?.toString() ?? '',
        'venvReady': r[6] as bool? ?? false,
        'isActive': r[7] as bool? ?? true,
        'generationPrompt': r[8]?.toString() ?? '',
        'createdAt': r[9]?.toString() ?? '',
        'updatedAt': r[10]?.toString() ?? '',
      };
    }).toList();
  }

  /// Delete a Python tool by ID.
  Future<void> deletePyTool(String id) async {
    final conn = await connection;
    await conn.execute("DELETE FROM py_tools WHERE id = '${_esc(id)}'");
    log.info('[DuckDB] deletePyTool: $id');
  }

  // ──────────────────────────────────────────────
  // GitHub MCP Server CRUD
  // ──────────────────────────────────────────────

  /// Upsert a GitHub MCP server definition.
  Future<void> saveGithubMcpServer(Map<String, dynamic> def) async {
    final conn = await connection;
    final id = _esc(def['id'] as String);
    final name = _esc(def['name'] as String);
    final displayName = _esc(def['displayName'] as String? ?? def['name'] as String);
    final description = _esc(def['description'] as String? ?? '');
    final githubUrl = _esc(def['githubUrl'] as String? ?? '');
    final language = _esc(def['language'] as String? ?? 'python');
    final installType = _esc(def['installType'] as String? ?? 'uvx');
    final packageName = _esc(def['packageName'] as String);
    final entryPoint = def['entryPoint'] != null ? "'${_esc(def['entryPoint'] as String)}'" : 'NULL';
    final launchArgs = _esc(jsonEncode(def['launchArgs'] ?? []));
    final requiredEnvVars = _esc(jsonEncode(def['requiredEnvVars'] ?? []));
    final envVars = _esc(jsonEncode(def['envVars'] ?? {}));
    final category = _esc(def['category'] as String? ?? 'other');
    final isInstalled = (def['isInstalled'] as bool? ?? false) ? 'TRUE' : 'FALSE';
    final isActive = (def['isActive'] as bool? ?? false) ? 'TRUE' : 'FALSE';
    final isManual = (def['isManual'] as bool? ?? false) ? 'TRUE' : 'FALSE';
    final installedAt = def['installedAt'] != null ? "'${def['installedAt']}'" : 'NULL';
    final createdAt = def['createdAt'] as String? ?? DateTime.now().toIso8601String();

    await conn.execute('''
      INSERT OR REPLACE INTO github_mcp_servers
        (id, name, display_name, description, github_url, language, install_type,
         package_name, entry_point, launch_args, required_env_vars, env_vars,
         category, is_installed, is_active, is_manual, installed_at, created_at)
      VALUES
        ('$id', '$name', '$displayName', '$description', '$githubUrl', '$language', '$installType',
         '$packageName', $entryPoint, '$launchArgs'::JSON, '$requiredEnvVars'::JSON, '$envVars'::JSON,
         '$category', $isInstalled, $isActive, $isManual, $installedAt, '$createdAt')
    ''');
    log.info('[DuckDB] saveGithubMcpServer: $id "$name"');
    // Force WAL checkpoint so data is in the main DB file even if the process
    // is killed before the connection is closed normally.
    try {
      await conn.execute('CHECKPOINT');
    } catch (e) {
      log.warning('[DuckDB] CHECKPOINT after saveGithubMcpServer failed: $e');
    }
  }

  /// Return all GitHub MCP server definitions as raw JSON maps.
  Future<List<Map<String, dynamic>>> getAllGithubMcpServers() async {
    final conn = await connection;
    final result = await conn.query('''
      SELECT id, name, display_name, description, github_url, language, install_type,
             package_name, entry_point, launch_args, required_env_vars, env_vars,
             category, is_installed, is_active, is_manual, installed_at, created_at
      FROM github_mcp_servers
      ORDER BY display_name ASC
    ''');
    return result.fetchAll().map((r) {
      return {
        'id': r[0].toString(),
        'name': r[1].toString(),
        'displayName': r[2].toString(),
        'description': r[3]?.toString() ?? '',
        'githubUrl': r[4]?.toString() ?? '',
        'language': r[5]?.toString() ?? 'python',
        'installType': r[6]?.toString() ?? 'uvx',
        'packageName': r[7].toString(),
        'entryPoint': r[8]?.toString(),
        'launchArgs': _decodeJsonList(r[9]),
        'requiredEnvVars': _decodeJsonList(r[10]),
        'envVars': _decodeJsonMapSafe(r[11]),
        'category': r[12]?.toString() ?? 'other',
        'isInstalled': r[13] as bool? ?? false,
        'isActive': r[14] as bool? ?? false,
        'isManual': r[15] as bool? ?? false,
        'installedAt': r[16]?.toString(),
        'createdAt': r[17]?.toString() ?? DateTime.now().toIso8601String(),
      };
    }).toList();
  }

  /// Delete a GitHub MCP server by ID.
  Future<void> deleteGithubMcpServer(String id) async {
    final conn = await connection;
    await conn.execute("DELETE FROM github_mcp_servers WHERE id = '${_esc(id)}'");
    log.info('[DuckDB] deleteGithubMcpServer: $id');
    try {
      await conn.execute('CHECKPOINT');
    } catch (e) {
      log.warning('[DuckDB] CHECKPOINT after deleteGithubMcpServer failed: $e');
    }
  }

  List<dynamic> _decodeJsonList(dynamic raw) {
    if (raw == null) return [];
    if (raw is List) return raw;
    if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) return decoded;
      } catch (_) {}
    }
    return [];
  }

  Map<String, dynamic> _decodeJsonMapSafe(dynamic raw) {
    if (raw == null) return {};
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return {};
  }

  // ──────────────────────────────────────────────
  // Bulk / Export
  // ──────────────────────────────────────────────

  /// Export all tasks as JSON list.
  Future<List<Map<String, dynamic>>> exportTasks() async {
    final conn = await connection;
    final result = await conn.query('SELECT data FROM tasks ORDER BY name');
    final rows = result.fetchAll();
    final tasks = <Map<String, dynamic>>[];
    for (final row in rows) {
      try {
        tasks.add(_decodeJsonMap(row[0]));
      } catch (e) {
        log.warning('[DuckDB] exportTasks: skipped invalid task JSON row: $e');
      }
    }
    return tasks;
  }

  /// Import tasks from JSON list.
  Future<int> importTasks(List<Map<String, dynamic>> tasksJson) async {
    int count = 0;
    for (final json in tasksJson) {
      final id = json['id'] as String;
      final name = json['name'] as String;
      final enabled = json['enabled'] as bool? ?? true;
      final agentId = json['agent_id'] as String?;
      final tags = (json['tags'] as List<dynamic>?)?.cast<String>() ?? [];
      await saveTask(id, name, enabled, agentId, tags, json);
      count++;
    }
    return count;
  }

  // ──────────────────────────────────────────────
  // Raw query access (for internal MCP servers)
  // ──────────────────────────────────────────────

  /// Execute a raw SQL statement (DDL, DML).
  Future<void> execute(String sql) async {
    final conn = await connection;
    await conn.execute(sql);
  }

  /// Run a raw SQL query and return results as list of rows.
  Future<List<List<dynamic>>> query(String sql) async {
    final conn = await connection;
    final result = await conn.query(sql);
    return result.fetchAll();
  }

  // ──────────────────────────────────────────────
  // Tool Hints CRUD
  // ──────────────────────────────────────────────

  /// Upsert a tool skill record.
  Future<void> saveToolSkill({
    required String id,
    required String toolName,
    required String mcpType,
    required String skillText,
    required String skillTextSlm,
    required bool isEnabled,
    required bool isCustom,
  }) async {
    final conn = await connection;
    final now = DateTime.now().toIso8601String();
    await conn.execute('''
      INSERT OR REPLACE INTO tool_skills
        (id, tool_name, mcp_type, skill_text, skill_text_slm, is_enabled, is_custom, generated_at, updated_at)
      VALUES (
        '${_esc(id)}',
        '${_esc(toolName)}',
        '${_esc(mcpType)}',
        '${_esc(skillText)}',
        '${_esc(skillTextSlm)}',
        $isEnabled,
        $isCustom,
        '$now',
        '$now'
      )
    ''');
  }

  /// Return all Tool Hints, optionally filtered by mcpType.
  Future<List<Map<String, dynamic>>> getAllToolSkills({String? mcpType}) async {
    final conn = await connection;
    final where = mcpType != null ? "WHERE mcp_type = '${_esc(mcpType)}'" : '';
    final result = await conn.query(
      'SELECT id, tool_name, mcp_type, skill_text, skill_text_slm, is_enabled, is_custom, generated_at, updated_at '
      'FROM tool_skills $where ORDER BY mcp_type, tool_name',
    );
    return result.fetchAll().map((r) => _rowToSkillMap(r)).toList();
  }

  /// Return skills only for a specific set of tool names (used during prompt injection).
  Future<List<Map<String, dynamic>>> getEnabledSkillsForTools(List<String> toolNames) async {
    if (toolNames.isEmpty) return [];
    final conn = await connection;
    final inList = toolNames.map((t) => "'${_esc(t)}'").join(', ');
    final result = await conn.query(
      'SELECT id, tool_name, mcp_type, skill_text, skill_text_slm, is_enabled, is_custom, generated_at, updated_at '
      'FROM tool_skills WHERE is_enabled = true AND tool_name IN ($inList)',
    );
    return result.fetchAll().map((r) => _rowToSkillMap(r)).toList();
  }

  /// Return the set of tool names that already have a skill record.
  Future<Set<String>> getToolNamesWithSkills() async {
    final conn = await connection;
    final result = await conn.query('SELECT tool_name FROM tool_skills');
    return result.fetchAll().map((r) => r[0].toString()).toSet();
  }

  Map<String, dynamic> _rowToSkillMap(List<dynamic> r) => {
    'id': r[0].toString(),
    'tool_name': r[1].toString(),
    'mcp_type': r[2].toString(),
    'skill_text': r[3].toString(),
    'skill_text_slm': r[4].toString(),
    'is_enabled': r[5] as bool? ?? true,
    'is_custom': r[6] as bool? ?? false,
    'generated_at': r[7].toString(),
    'updated_at': r[8].toString(),
  };

  /// Delete a skill by its id.
  Future<void> deleteToolSkill(String id) async {
    final conn = await connection;
    await conn.execute("DELETE FROM tool_skills WHERE id = '${_esc(id)}'");
  }

  /// Delete all skills for a specific tool_name (e.g. when a JS tool is removed).
  Future<void> deleteToolSkillsByToolName(String toolName) async {
    final conn = await connection;
    await conn.execute("DELETE FROM tool_skills WHERE tool_name = '${_esc(toolName)}'");
  }

  // ──────────────────────────────────────────────
  // Helpers
  // ──────────────────────────────────────────────

  /// Escape single quotes for SQL strings.
  String _esc(String s) => s.replaceAll("'", "''");

  /// Decode JSON payloads returned by DuckDB across platforms.
  ///
  /// Depending on driver/platform, JSON columns may come back as:
  /// - `Map` (already decoded)
  /// - `String` (JSON text)
  Map<String, dynamic> _decodeJsonMap(dynamic raw) {
    if (raw is Map<String, dynamic>) {
      return raw;
    }

    if (raw is Map) {
      return Map<String, dynamic>.from(raw);
    }

    if (raw is String) {
      final trimmed = raw.trim();
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
      throw const FormatException('JSON value is not an object');
    }

    throw FormatException('Unsupported JSON payload type: ${raw.runtimeType}');
  }

  Future<void> _migrateTasksToOrchestratorPattern() async {
    final conn = await connection;
    try {
      final result = await conn.query("SELECT id, data FROM tasks");
      final rows = result.fetchAll();
      
      final Map<String, Map<String, dynamic>> allTasks = {};
      for (final row in rows) {
        final id = row[0] as String;
        allTasks[id] = _decodeJsonMap(row[1]);
      }

      final Set<String> tasksToDelete = {};

      for (final id in allTasks.keys) {
        final data = allTasks[id]!;
        
        // Phase 1 migration: ensure it has agents
        bool modified = false;
        if ((!data.containsKey('agents') && !data.containsKey('executors')) || 
            ((data['agents'] ?? data['executors']) as List?) == null || 
            ((data['agents'] ?? data['executors']) as List).isEmpty) {
          if ((data['prompt'] as String? ?? '').isNotEmpty) {
            log.info('[DuckDB Migration] Migrating task $id to orchestrator-executor pattern...');
            final task = WorkflowTask.fromJson(data);
            allTasks[id] = task.toJson(); // This will auto-migrate via fromJson
            modified = true;
          }
        }
        
        // Phase 1.5 migration: legacy chaining
        final currentData = allTasks[id]!;
        final chainConfig = currentData['chain_config'] as Map<String, dynamic>?;
        if (chainConfig != null && (chainConfig['is_subtask'] == null || chainConfig['is_subtask'] == false)) {
          // This is a root task with chaining!
          if (chainConfig['on_match_task_id'] != null || chainConfig['on_no_match_task_id'] != null) {
             log.info('[DuckDB Migration] Migrating legacy chains for root task $id...');
             
             final rootTask = WorkflowTask.fromJson(currentData);
             List<Agent> agents = List.from(rootTask.agents);
             List<Edge> edges = List.from(rootTask.edges);
             
             String currentSourceId = agents.isNotEmpty ? agents.first.id : id;
             
             String? currentNextId = chainConfig['on_match_task_id'] as String?;
             String? currentCondition = chainConfig['trigger_condition'] as String?;
             
             while (currentNextId != null && allTasks.containsKey(currentNextId)) {
                final childData = allTasks[currentNextId]!;
                final childTask = WorkflowTask.fromJson(childData);
                
                // Add as executor
                final newExecutorId = const Uuid().v4();
                agents.add(
                  Agent(
                    id: newExecutorId,
                    name: childTask.name.isNotEmpty ? childTask.name : 'Agent ${agents.length + 1}',
                    systemPrompt: childTask.systemPrompt,
                    prompt: childTask.prompt,
                    llmConfig: childTask.llmConfig,
                    mcpTools: childTask.mcpTools,
                    internalMcps: childTask.internalMcps,
                    chatMode: childTask.chatMode,
                    stopAfterToolCall: childTask.stopAfterToolCall,
                  )
                );
                
                // Add routing rule
                edges.add(
                   Edge(
                     id: const Uuid().v4(),
                     sourceAgentId: currentSourceId,
                     variable: 'task_result',
                     operator: currentCondition != null ? 'contains' : 'contains',
                     value: currentCondition ?? '',
                     targetAgentId: newExecutorId,
                   )
                );
                
                tasksToDelete.add(currentNextId);
                
                currentSourceId = newExecutorId;
                final childChain = childTask.chainConfig;
                if (childChain != null) {
                   currentNextId = childChain.onMatchTaskId;
                   currentCondition = childChain.triggerCondition;
                } else {
                   currentNextId = null;
                   currentCondition = null;
                }
             }
             
             final updatedRoot = rootTask.copyWith(
               agents: agents,
               edges: edges,
               clearChainConfig: true,
             );
             allTasks[id] = updatedRoot.toJson();
             modified = true;
          }
        }
        
        if (modified) {
          final escData = _esc(jsonEncode(allTasks[id]!));
          final now = DateTime.now().toIso8601String();
          await conn.execute("UPDATE tasks SET data = '$escData'::JSON, updated_at = '$now' WHERE id = '$id'");
          log.info('[DuckDB Migration] Saved updated task $id');
        }
      }
      
      for (final delId in tasksToDelete) {
         log.info('[DuckDB Migration] Deleting legacy subtask $delId');
         await conn.execute("DELETE FROM tasks WHERE id = '$delId'");
      }

    } catch (e) {
      log.warning('[DuckDB Migration] Failed to run orchestrator migration: $e');
    }
  }
}

