import 'dart:convert';
import 'dart:io';

import 'package:dart_duckdb/dart_duckdb.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/agentic_task.dart';
import '../utils/cron_utils.dart';
import '../utils/server_logger.dart';
import '../utils/server_paths.dart';
import 'server_database_adapter.dart';

/// DuckDB implementation of [ServerDatabaseAdapter].
///
/// Wraps the original DuckDB logic (previously in the singleton
/// `ServerDatabaseAdapter`) behind the adapter interface.
///
/// This is a **singleton** — only one DuckDB database connection can
/// be open to the same file within a process.
class ServerDuckDbAdapter implements ServerDatabaseAdapter {
  static const String _dbFileName = 'tealkit_server.duckdb';

  static final ServerDuckDbAdapter _instance = ServerDuckDbAdapter._internal();
  factory ServerDuckDbAdapter() => _instance;
  ServerDuckDbAdapter._internal();

  @override
  String get engineType => 'duckdb';

  Database? _db;
  Connection? _conn;
  bool _initialized = false;

  // ── Lifecycle ──────────────────────────────────────────────

  @override
  String get dataDir => resolveServerDataDir();

  @override
  Future<void> init() async {
    if (_initialized) return;

    final dbDir = p.join(dataDir, 'db');
    await Directory(dbDir).create(recursive: true);
    final dbPath = p.join(dbDir, _dbFileName);

    log.info('[DuckDB] Opening database at: $dbPath');

    try {
      await _openDatabase(dbPath);
    } catch (e) {
      if (_isWalReplayError(e)) {
        log.warning(
          '[DuckDB] WAL replay failed — archiving WAL and retrying. Error: $e',
        );
        await _archiveWalFile(dbPath);
        await _openDatabase(dbPath);
      } else if (_isAlreadyOpenError(e)) {
        log.warning(
          '[DuckDB] Database locked — deleting lock file and retrying. Error: $e',
        );
        await _deleteLockFile(dbPath);
        await _openDatabase(dbPath);
      } else {
        rethrow;
      }
    }

    log.info('[DuckDB] Database opened successfully');
    await _createTables();
    await _migrateTasksToOrchestratorPattern();
    await _seedDefaultPyTools();
    _initialized = true;
  }

  Future<void> _openDatabase(String dbPath) async {
    _db = await duckdb.open(dbPath);
    _conn = await duckdb.connect(_db!);
  }

  @override
  Future<void> close() async {
    log.info('[DuckDB] Closing database');
    await _conn?.dispose();
    await _db?.dispose();
    _conn = null;
    _db = null;
    _initialized = false;
  }

  Future<Connection> _getConn() async {
    if (_conn == null) await init();
    return _conn!;
  }

  bool _isWalReplayError(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains('failure while replaying wal') ||
        msg.contains('calling databasemanager') ||
        msg.contains('.duckdb.wal');
  }

  bool _isAlreadyOpenError(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains('already opened') ||
        msg.contains('database is locked') ||
        msg.contains('unable to lock') ||
        msg.contains('could not set lock') ||
        msg.contains('access is denied') ||
        msg.contains('.duckdb.lock');
  }

  Future<void> _deleteLockFile(String dbPath) async {
    final lockFile = File('$dbPath.lock');
    if (await lockFile.exists()) {
      await lockFile.delete();
      log.info('[DuckDB] Deleted stale lock file: ${lockFile.path}');
    }
  }

  Future<void> _archiveWalFile(String dbPath) async {
    final walFile = File('$dbPath.wal');
    if (!await walFile.exists()) return;
    final archived =
        '${walFile.path}.corrupt.${DateTime.now().millisecondsSinceEpoch}';
    await walFile.rename(archived);
    log.warning('[DuckDB] Archived corrupted WAL to: $archived');
  }

  // ── Schema ──────────────────────────────────────────────────

  Future<void> _createTables() async {
    final conn = _conn!;

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
      await conn.execute(
        'ALTER TABLE document_index ADD COLUMN IF NOT EXISTS embedding_json TEXT',
      );
    } catch (_) {}

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

    try {
      await conn.execute(
        'ALTER TABLE py_tools ADD COLUMN IF NOT EXISTS description VARCHAR DEFAULT \'\'',
      );
      await conn.execute(
        'ALTER TABLE py_tools ADD COLUMN IF NOT EXISTS input_schema JSON',
      );
      await conn.execute(
        'ALTER TABLE py_tools ADD COLUMN IF NOT EXISTS code TEXT',
      );
      await conn.execute(
        'ALTER TABLE py_tools ADD COLUMN IF NOT EXISTS requirements TEXT DEFAULT \'\'',
      );
      await conn.execute(
        'ALTER TABLE py_tools ADD COLUMN IF NOT EXISTS venv_ready BOOLEAN DEFAULT FALSE',
      );
      await conn.execute(
        'ALTER TABLE py_tools ADD COLUMN IF NOT EXISTS is_active BOOLEAN DEFAULT TRUE',
      );
      await conn.execute(
        'ALTER TABLE py_tools ADD COLUMN IF NOT EXISTS generation_prompt TEXT DEFAULT \'\'',
      );
      await conn.execute(
        'ALTER TABLE py_tools ADD COLUMN IF NOT EXISTS created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP',
      );
      await conn.execute(
        'ALTER TABLE py_tools ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP',
      );
    } catch (_) {}

    await conn.execute('''
      CREATE TABLE IF NOT EXISTS js_tools (
        id           VARCHAR PRIMARY KEY,
        name         VARCHAR NOT NULL,
        description  VARCHAR DEFAULT '',
        input_schema JSON    NOT NULL DEFAULT '{"type":"object","properties":{}}',
        js_code      TEXT    NOT NULL,
        is_active    BOOLEAN DEFAULT TRUE,
        created_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )
    ''');

    try {
      await conn.execute(
        'ALTER TABLE js_tools ADD COLUMN IF NOT EXISTS description VARCHAR DEFAULT \'\'',
      );
      await conn.execute(
        'ALTER TABLE js_tools ADD COLUMN IF NOT EXISTS input_schema JSON',
      );
      await conn.execute(
        'ALTER TABLE js_tools ADD COLUMN IF NOT EXISTS js_code TEXT',
      );
      await conn.execute(
        'ALTER TABLE js_tools ADD COLUMN IF NOT EXISTS is_active BOOLEAN DEFAULT TRUE',
      );
      await conn.execute(
        'ALTER TABLE js_tools ADD COLUMN IF NOT EXISTS created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP',
      );
      await conn.execute(
        'ALTER TABLE js_tools ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP',
      );
    } catch (_) {}

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
      await conn.execute(
        'ALTER TABLE github_mcp_servers ADD COLUMN IF NOT EXISTS is_manual BOOLEAN DEFAULT FALSE',
      );
    } catch (_) {}

    await conn.execute('''
      CREATE TABLE IF NOT EXISTS scheduler_log (
        id         VARCHAR PRIMARY KEY,
        task_id    VARCHAR NOT NULL,
        task_name  VARCHAR NOT NULL,
        started_at TIMESTAMP NOT NULL,
        ended_at   TIMESTAMP,
        success    BOOLEAN,
        message    TEXT
      )
    ''');

    await conn.execute('''
      CREATE TABLE IF NOT EXISTS tool_skills (
        id             VARCHAR PRIMARY KEY,
        tool_name      VARCHAR NOT NULL,
        mcp_type       VARCHAR NOT NULL,
        skill_text     TEXT DEFAULT '',
        skill_text_slm TEXT DEFAULT '',
        is_enabled     BOOLEAN DEFAULT TRUE,
        is_custom      BOOLEAN DEFAULT FALSE,
        generated_at   VARCHAR,
        updated_at     VARCHAR DEFAULT CURRENT_TIMESTAMP
      )
    ''');

    // ── Skill definitions table — persisted AgentSkills.io skills ──────
    await conn.execute('''
      CREATE TABLE IF NOT EXISTS skill_defs (
        id          VARCHAR PRIMARY KEY,
        name        VARCHAR NOT NULL,
        goal        VARCHAR DEFAULT '',
        description VARCHAR DEFAULT '',
        skill_def   TEXT NOT NULL,
        tool_names  VARCHAR[],
        created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )
    ''');

    await conn.execute('''
      CREATE TABLE IF NOT EXISTS playground_sessions (
        id          VARCHAR PRIMARY KEY,
        name        VARCHAR NOT NULL,
        mode        VARCHAR DEFAULT 'local',
        data        JSON NOT NULL,
        created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )
    ''');
  }

  // ── Tasks CRUD ─────────────────────────────────────────────

  @override
  Future<void> saveTask(AgenticTask task) async {
    final conn = await _getConn();
    final json = jsonEncode(task.toJson());
    final tagsArray = task.tags.isEmpty
        ? 'NULL'
        : '[${task.tags.map((t) => "'${_esc(t)}'").join(',')}]';
    await conn.execute('''
      INSERT INTO tasks (id, name, enabled, agent_id, tags, data, created_at, updated_at)
      VALUES (
        '${_esc(task.id)}',
        '${_esc(task.name)}',
        ${task.enabled},
        ${task.agentId != null ? "'${_esc(task.agentId!)}'" : 'NULL'},
        $tagsArray,
        '${_esc(json)}',
        '${task.createdAt.toIso8601String()}',
        '${task.updatedAt.toIso8601String()}'
      )
      ON CONFLICT (id) DO UPDATE SET
        name       = EXCLUDED.name,
        enabled    = EXCLUDED.enabled,
        agent_id   = EXCLUDED.agent_id,
        tags       = EXCLUDED.tags,
        data       = EXCLUDED.data,
        updated_at = EXCLUDED.updated_at
    ''');
  }

  @override
  Future<AgenticTask?> getTask(String id) async {
    final conn = await _getConn();
    final rows = (await conn.query(
      "SELECT data FROM tasks WHERE id = '${_esc(id)}'",
    )).fetchAll();
    if (rows.isEmpty) return null;
    return AgenticTask.fromJson(_decodeJsonMap(rows.first[0]));
  }

  @override
  Future<List<AgenticTask>> getAllTasks() async {
    final conn = await _getConn();
    final rows = (await conn.query(
      'SELECT data FROM tasks ORDER BY created_at DESC',
    )).fetchAll();
    return rows
        .map((row) {
          try {
            return AgenticTask.fromJson(_decodeJsonMap(row[0]));
          } catch (e) {
            log.warning('[DuckDB] Failed to decode task: $e');
            return null;
          }
        })
        .whereType<AgenticTask>()
        .toList();
  }

  @override
  Future<List<AgenticTask>> getDueTasks() async {
    final conn = await _getConn();
    final rows = (await conn.query(
      'SELECT data FROM tasks WHERE enabled = TRUE',
    )).fetchAll();
    final now = DateTime.now().toUtc();
    return rows
        .map((row) {
          try {
            return AgenticTask.fromJson(_decodeJsonMap(row[0]));
          } catch (e) {
            log.warning('[DuckDB] Failed to decode due task: $e');
            return null;
          }
        })
        .whereType<AgenticTask>()
        .where((task) {
          final cron = task.executionPlan.cronExpression.trim();
          if (cron.isEmpty || cron == '@manual') return false;
          final lastRun = task.execution.lastRun?.toLocal();
          final reference = lastRun ?? DateTime(1970);
          final expectedFire = nextCronFire(cron, from: reference);
          return !expectedFire.isAfter(now);
        })
        .toList();
  }

  @override
  Future<void> deleteTask(String id) async {
    final conn = await _getConn();
    await conn.execute("DELETE FROM tasks WHERE id = '${_esc(id)}'");
  }

  @override
  Future<void> updateExecution(String taskId, TaskExecution execution) async {
    final task = await getTask(taskId);
    if (task == null) return;
    final updated = task.copyWith(execution: execution);
    await saveTask(updated);
  }

  @override
  Future<void> toggleTask(String id, bool enabled) async {
    final conn = await _getConn();
    await conn.execute(
      "UPDATE tasks SET enabled = $enabled WHERE id = '${_esc(id)}'",
    );
    final task = await getTask(id);
    if (task == null) return;
    await saveTask(task.copyWith(enabled: enabled));
  }

  // ── Internal MCP Configs ───────────────────────────────────

  @override
  Future<void> saveInternalMcpConfig(
    String taskId,
    InternalMcpEntry entry,
  ) async {
    final conn = await _getConn();
    final json = jsonEncode(entry.initParams);
    await conn.execute('''
      INSERT INTO internal_mcp_configs (id, task_id, mcp_type, params, enabled, created_at, updated_at)
      VALUES (
        '${_esc(entry.id)}',
        '${_esc(taskId)}',
        '${_esc(entry.mcpType)}',
        '${_esc(json)}',
        ${entry.enabled},
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
      )
      ON CONFLICT (id) DO UPDATE SET
        mcp_type   = EXCLUDED.mcp_type,
        params     = EXCLUDED.params,
        enabled    = EXCLUDED.enabled,
        updated_at = CURRENT_TIMESTAMP
    ''');
  }

  @override
  Future<List<InternalMcpEntry>> getInternalMcpConfigs(String taskId) async {
    final conn = await _getConn();
    final rows = (await conn.query(
      "SELECT id, mcp_type, params, enabled FROM internal_mcp_configs WHERE task_id = '${_esc(taskId)}'",
    )).fetchAll();
    return rows.map((row) {
      return InternalMcpEntry(
        id: row[0] as String,
        mcpType: row[1] as String,
        initParams: _decodeJsonMap(row[2]),
        enabled: row[3] as bool? ?? true,
      );
    }).toList();
  }

  // ── Python Tools ───────────────────────────────────────────

  @override
  Future<void> savePyTool(Map<String, dynamic> tool) async {
    final conn = await _getConn();
    final schema = jsonEncode(tool['input_schema'] ?? {});
    final now = DateTime.now().toIso8601String();
    await conn.execute('''
      INSERT INTO py_tools (id, name, description, input_schema, code, requirements, venv_ready, is_active, generation_prompt, created_at, updated_at)
      VALUES (
        '${_esc(tool['id'] as String)}',
        '${_esc(tool['name'] as String)}',
        '${_esc(tool['description'] as String? ?? '')}',
        '${_esc(schema)}',
        '${_esc(tool['code'] as String? ?? '')}',
        '${_esc(tool['requirements'] as String? ?? '')}',
        ${tool['venv_ready'] as bool? ?? false},
        ${tool['is_active'] as bool? ?? true},
        '${_esc(tool['generation_prompt'] as String? ?? '')}',
        '$now',
        '$now'
      )
      ON CONFLICT (id) DO UPDATE SET
        name              = EXCLUDED.name,
        description       = EXCLUDED.description,
        input_schema      = EXCLUDED.input_schema,
        code              = EXCLUDED.code,
        requirements      = EXCLUDED.requirements,
        venv_ready        = EXCLUDED.venv_ready,
        is_active         = EXCLUDED.is_active,
        generation_prompt = EXCLUDED.generation_prompt,
        updated_at        = EXCLUDED.updated_at
    ''');
  }

  @override
  Future<List<Map<String, dynamic>>> getAllPyTools() async {
    final conn = await _getConn();
    final rows = (await conn.query(
      'SELECT id, name, description, input_schema, code, requirements, venv_ready, is_active, generation_prompt FROM py_tools ORDER BY created_at DESC',
    )).fetchAll();
    return rows.map((row) {
      return {
        'id': row[0],
        'name': row[1],
        'description': row[2],
        'input_schema': _decodeJsonMap(row[3]),
        'code': row[4],
        'requirements': row[5],
        'venv_ready': row[6],
        'is_active': row[7],
        'generation_prompt': row[8],
      };
    }).toList();
  }

  @override
  Future<void> setPyToolVenvReady(String id, bool ready) async {
    final conn = await _getConn();
    await conn.execute(
      "UPDATE py_tools SET venv_ready = $ready, updated_at = CURRENT_TIMESTAMP WHERE id = '${_esc(id)}'",
    );
  }

  @override
  Future<void> deletePyTool(String id) async {
    final conn = await _getConn();
    await conn.execute("DELETE FROM py_tools WHERE id = '${_esc(id)}'");
  }

  // ── JavaScript Tools ───────────────────────────────────────

  @override
  Future<void> saveJsTool(Map<String, dynamic> tool) async {
    final conn = await _getConn();
    final now = DateTime.now().toIso8601String();
    final schema = jsonEncode(
      tool['input_schema'] ??
          tool['inputSchema'] ??
          const <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{},
          },
    );
    await conn.execute('''
      INSERT INTO js_tools (id, name, description, input_schema, js_code, is_active, created_at, updated_at)
      VALUES (
        '${_esc(tool['id'] as String)}',
        '${_esc(tool['name'] as String)}',
        '${_esc(tool['description'] as String? ?? '')}',
        '${_esc(schema)}',
        '${_esc(tool['js_code'] as String? ?? tool['jsCode'] as String? ?? '')}',
        ${tool['is_active'] as bool? ?? tool['isActive'] as bool? ?? true},
        '$now',
        '$now'
      )
      ON CONFLICT (id) DO UPDATE SET
        name        = EXCLUDED.name,
        description = EXCLUDED.description,
        input_schema = EXCLUDED.input_schema,
        js_code     = EXCLUDED.js_code,
        is_active   = EXCLUDED.is_active,
        updated_at  = EXCLUDED.updated_at
    ''');
  }

  @override
  Future<List<Map<String, dynamic>>> getAllJsTools({
    bool activeOnly = false,
  }) async {
    final conn = await _getConn();
    final where = activeOnly ? 'WHERE is_active = TRUE' : '';
    final rows = (await conn.query(
      'SELECT id, name, description, input_schema, js_code, is_active, created_at, updated_at FROM js_tools $where ORDER BY updated_at DESC',
    )).fetchAll();
    return rows.map((row) {
      return {
        'id': row[0],
        'name': row[1],
        'description': row[2],
        'input_schema': _decodeJsonMap(row[3]),
        'js_code': row[4],
        'is_active': row[5],
        'created_at': row[6]?.toString(),
        'updated_at': row[7]?.toString(),
      };
    }).toList();
  }

  @override
  Future<void> deleteJsTool(String id) async {
    final conn = await _getConn();
    await conn.execute("DELETE FROM js_tools WHERE id = '${_esc(id)}'");
  }

  // ── GitHub MCP Servers ─────────────────────────────────────

  @override
  Future<void> saveGithubMcpServer(GithubMcpServerDefinition server) async {
    final conn = await _getConn();
    final launchArgsJson = jsonEncode(server.launchArgs);
    final requiredEnvVarsJson = jsonEncode(server.requiredEnvVars);
    final envVarsJson = jsonEncode(server.envVars);

    await conn.execute('''
      INSERT INTO github_mcp_servers (
        id, name, display_name, description, github_url, language, install_type,
        package_name, entry_point, launch_args, required_env_vars, env_vars,
        category, is_installed, is_active, is_manual, installed_at, created_at
      ) VALUES (
        '${_esc(server.id)}',
        '${_esc(server.name)}',
        '${_esc(server.displayName)}',
        '${_esc(server.description)}',
        '${_esc(server.githubUrl)}',
        '${_esc(server.language)}',
        '${_esc(server.installType)}',
        '${_esc(server.packageName)}',
        ${server.entryPoint != null ? "'${_esc(server.entryPoint!)}'" : 'NULL'},
        '${_esc(launchArgsJson)}',
        '${_esc(requiredEnvVarsJson)}',
        '${_esc(envVarsJson)}',
        '${_esc(server.category)}',
        ${server.isInstalled},
        ${server.isActive},
        ${server.isManual},
        ${server.installedAt != null ? "'${server.installedAt!.toIso8601String()}'" : 'NULL'},
        '${server.createdAt.toIso8601String()}'
      )
      ON CONFLICT (id) DO UPDATE SET
        display_name      = EXCLUDED.display_name,
        description       = EXCLUDED.description,
        launch_args       = EXCLUDED.launch_args,
        required_env_vars = EXCLUDED.required_env_vars,
        env_vars          = EXCLUDED.env_vars,
        category          = EXCLUDED.category,
        is_installed      = EXCLUDED.is_installed,
        is_active         = EXCLUDED.is_active,
        is_manual         = EXCLUDED.is_manual,
        installed_at      = EXCLUDED.installed_at
    ''');
  }

  @override
  Future<List<GithubMcpServerDefinition>> getAllGithubMcpServers() async {
    final conn = await _getConn();
    final rows = (await conn.query(
      'SELECT id, name, display_name, description, github_url, language, install_type, '
      'package_name, entry_point, launch_args, required_env_vars, env_vars, category, '
      'is_installed, is_active, is_manual, installed_at, created_at FROM github_mcp_servers ORDER BY created_at DESC',
    )).fetchAll();

    return rows.map((row) {
      return GithubMcpServerDefinition(
        id: row[0] as String,
        name: row[1] as String,
        displayName: row[2] as String,
        description: row[3] as String? ?? '',
        githubUrl: row[4] as String? ?? '',
        language: row[5] as String? ?? 'python',
        installType: row[6] as String? ?? 'uvx',
        packageName: row[7] as String,
        entryPoint: row[8] as String?,
        launchArgs: _decodeJsonList(row[9]).cast<String>(),
        requiredEnvVars: _decodeJsonList(row[10]).cast<String>(),
        envVars: Map<String, String>.from(_decodeJsonMap(row[11])),
        category: row[12] as String? ?? 'other',
        isInstalled: row[13] as bool? ?? false,
        isActive: row[14] as bool? ?? false,
        isManual: row[15] as bool? ?? false,
        installedAt: row[16] != null
            ? DateTime.tryParse(row[16].toString())
            : null,
        createdAt: DateTime.tryParse(row[17].toString()) ?? DateTime.now(),
      );
    }).toList();
  }

  @override
  Future<void> deleteGithubMcpServer(String id) async {
    final conn = await _getConn();
    await conn.execute(
      "DELETE FROM github_mcp_servers WHERE id = '${_esc(id)}'",
    );
  }

  // ── Scheduler Log ──────────────────────────────────────────

  @override
  Future<void> logSchedulerRun({
    required String id,
    required String taskId,
    required String taskName,
    required DateTime startedAt,
    DateTime? endedAt,
    bool? success,
    String? message,
  }) async {
    final conn = await _getConn();
    final endedSql = endedAt != null
        ? "'${endedAt.toIso8601String()}'"
        : 'NULL';
    final successSql = success != null ? success.toString() : 'NULL';
    final msgSql = message != null ? "'${_esc(message)}'" : 'NULL';
    await conn.execute('''
      INSERT INTO scheduler_log (id, task_id, task_name, started_at, ended_at, success, message)
      VALUES (
        '${_esc(id)}',
        '${_esc(taskId)}',
        '${_esc(taskName)}',
        '${startedAt.toIso8601String()}',
        $endedSql,
        $successSql,
        $msgSql
      )
      ON CONFLICT (id) DO UPDATE SET
        ended_at = EXCLUDED.ended_at,
        success  = EXCLUDED.success,
        message  = EXCLUDED.message
    ''');
  }

  // ── Tool Skills ────────────────────────────────────────────

  @override
  Future<void> saveToolSkill(Map<String, dynamic> skill) async {
    final conn = await _getConn();
    final id = _esc(skill['id'] as String);
    final toolName = _esc(skill['tool_name'] as String);
    final mcpType = _esc(skill['mcp_type'] as String);
    final skillText = _esc(skill['skill_text'] as String? ?? '');
    final skillTextSlm = _esc(skill['skill_text_slm'] as String? ?? '');
    final isEnabled = skill['is_enabled'] as bool? ?? true;
    final isCustom = skill['is_custom'] as bool? ?? false;
    final generatedAt = skill['generated_at'] != null
        ? "'${_esc(skill['generated_at'] as String)}'"
        : 'NULL';
    final updatedAt = skill['updated_at'] != null
        ? "'${_esc(skill['updated_at'] as String)}'"
        : 'CURRENT_TIMESTAMP';
    await conn.execute('''
      INSERT INTO tool_skills (id, tool_name, mcp_type, skill_text, skill_text_slm, is_enabled, is_custom, generated_at, updated_at)
      VALUES ('$id','$toolName','$mcpType','$skillText','$skillTextSlm',$isEnabled,$isCustom,$generatedAt,$updatedAt)
      ON CONFLICT (id) DO UPDATE SET
        tool_name      = EXCLUDED.tool_name,
        mcp_type       = EXCLUDED.mcp_type,
        skill_text     = EXCLUDED.skill_text,
        skill_text_slm = EXCLUDED.skill_text_slm,
        is_enabled     = EXCLUDED.is_enabled,
        is_custom      = EXCLUDED.is_custom,
        generated_at   = EXCLUDED.generated_at,
        updated_at     = EXCLUDED.updated_at
    ''');
  }

  @override
  Future<List<Map<String, dynamic>>> getAllToolSkills({String? mcpType}) async {
    final conn = await _getConn();
    final where = mcpType != null ? "WHERE mcp_type = '${_esc(mcpType)}'" : '';
    final rows = (await conn.query(
      'SELECT id,tool_name,mcp_type,skill_text,skill_text_slm,is_enabled,is_custom,generated_at,updated_at FROM tool_skills $where ORDER BY mcp_type,tool_name',
    )).fetchAll();
    return rows
        .map(
          (row) => <String, dynamic>{
            'id': row[0] as String,
            'tool_name': row[1] as String,
            'mcp_type': row[2] as String,
            'skill_text': row[3] as String? ?? '',
            'skill_text_slm': row[4] as String? ?? '',
            'is_enabled': row[5] as bool? ?? true,
            'is_custom': row[6] as bool? ?? false,
            'generated_at': row[7],
            'updated_at': row[8],
          },
        )
        .toList();
  }

  @override
  Future<void> deleteToolSkill(String id) async {
    final conn = await _getConn();
    await conn.execute("DELETE FROM tool_skills WHERE id = '${_esc(id)}'");
  }

  @override
  Future<void> deleteToolSkillsByToolName(String toolName) async {
    final conn = await _getConn();
    await conn.execute(
      "DELETE FROM tool_skills WHERE tool_name = '${_esc(toolName)}'",
    );
  }

  @override
  Future<List<String>> getToolNamesWithSkills({String? mcpType}) async {
    final conn = await _getConn();
    final where = mcpType != null ? "WHERE mcp_type = '${_esc(mcpType)}'" : '';
    final rows = (await conn.query(
      'SELECT DISTINCT tool_name FROM tool_skills $where',
    )).fetchAll();
    return rows.map((row) => row[0] as String).toList();
  }

  // ── Skill Definitions ──────────────────────────────────────

  @override
  Future<List<Map<String, dynamic>>> getAllSkillDefs() async {
    final conn = await _getConn();
    final rows = (await conn.query(
      'SELECT * FROM skill_defs ORDER BY updated_at DESC',
    )).fetchAll();
    return rows
        .map(
          (r) => {
            'id': r[0] as String,
            'name': r[1] as String,
            'goal': r[2] as String? ?? '',
            'description': r[3] as String? ?? '',
            'skill_def': r[4] as String,
            'tool_names': (r[5] as List?)?.cast<String>() ?? <String>[],
            'created_at': _skillTimeStr(r[6]),
            'updated_at': _skillTimeStr(r[7]),
          },
        )
        .toList();
  }

  @override
  Future<Map<String, dynamic>?> getSkillDef(String id) async {
    final conn = await _getConn();
    final rows = (await conn.query(
      "SELECT * FROM skill_defs WHERE id = '${_esc(id)}'",
    )).fetchAll();
    if (rows.isEmpty) return null;
    final r = rows.first;
    return {
      'id': r[0] as String,
      'name': r[1] as String,
      'goal': r[2] as String? ?? '',
      'description': r[3] as String? ?? '',
      'skill_def': r[4] as String,
      'tool_names': (r[5] as List?)?.cast<String>() ?? <String>[],
      'created_at': _skillTimeStr(r[6]),
      'updated_at': _skillTimeStr(r[7]),
    };
  }

  @override
  Future<void> saveSkillDef(Map<String, dynamic> skillDef) async {
    final conn = await _getConn();
    final id = skillDef['id'] as String;
    final name = skillDef['name'] as String;
    final goal = skillDef['goal'] as String? ?? '';
    final description = skillDef['description'] as String? ?? '';
    final skillDefContent = skillDef['skill_def'] as String;
    final toolNames =
        (skillDef['tool_names'] as List?)?.cast<String>() ?? <String>[];
    final now = DateTime.now().toUtc().toIso8601String();
    final tagsArray = toolNames.map((t) => "'${_esc(t)}'").join(',');
    await conn.execute('''
      INSERT OR REPLACE INTO skill_defs (id, name, goal, description, skill_def, tool_names, created_at, updated_at)
      VALUES ('${_esc(id)}', '${_esc(name)}', '${_esc(goal)}',
              '${_esc(description)}', '${_esc(skillDefContent)}',
              [$tagsArray], '${_esc(now)}', '${_esc(now)}')
    ''');
  }

  @override
  Future<void> deleteSkillDef(String id) async {
    final conn = await _getConn();
    await conn.execute("DELETE FROM skill_defs WHERE id = '${_esc(id)}'");
  }

  static String _skillTimeStr(dynamic v) {
    if (v is DateTime) return v.toUtc().toIso8601String();
    if (v is String) return v;
    return DateTime.now().toUtc().toIso8601String();
  }

  // ── Playground Sessions ────────────────────────────────────

  @override
  Future<void> savePlaygroundSession(Map<String, dynamic> session) async {
    final conn = await _getConn();
    final id = session['id'] as String? ?? '';
    final name = session['name'] as String? ?? '';
    final mode = session['mode'] as String? ?? 'local';
    final createdAt =
        session['createdAt'] as String? ?? DateTime.now().toIso8601String();
    final json = jsonEncode(session);
    await conn.execute('''
      INSERT INTO playground_sessions (id, name, mode, data, created_at)
      VALUES (
        '${_esc(id)}',
        '${_esc(name)}',
        '${_esc(mode)}',
        '${_esc(json)}',
        '$createdAt'
      )
      ON CONFLICT (id) DO UPDATE SET
        name       = EXCLUDED.name,
        mode       = EXCLUDED.mode,
        data       = EXCLUDED.data
    ''');
  }

  @override
  Future<List<Map<String, dynamic>>> getAllPlaygroundSessions() async {
    final conn = await _getConn();
    final rows = (await conn.query(
      'SELECT data FROM playground_sessions ORDER BY created_at DESC',
    )).fetchAll();
    return rows
        .map((row) {
          try {
            return _decodeJsonMap(row[0]);
          } catch (e) {
            log.warning('[DuckDB] Failed to decode playground session: $e');
            return null;
          }
        })
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  @override
  Future<void> deletePlaygroundSession(String id) async {
    final conn = await _getConn();
    await conn.execute(
      "DELETE FROM playground_sessions WHERE id = '${_esc(id)}'",
    );
  }

  // ── Raw Access ─────────────────────────────────────────────

  @override
  Future<void> execute(String sql) async {
    final conn = await _getConn();
    await conn.execute(sql);
  }

  @override
  Future<List<List<dynamic>>> query(String sql) async {
    final conn = await _getConn();
    return (await conn.query(
      sql,
    )).fetchAll().map((row) => List<dynamic>.from(row)).toList();
  }

  // ── Import / Export ────────────────────────────────────────

  @override
  Future<List<Map<String, dynamic>>> exportTasks() async {
    final tasks = await getAllTasks();
    return tasks.map((t) => t.toJson()).toList();
  }

  @override
  Future<void> importTasks(
    List<Map<String, dynamic>> rows, {
    bool overwrite = false,
  }) async {
    for (final row in rows) {
      if (!overwrite) {
        final existing = await getTask(row['id'] as String);
        if (existing != null) continue;
      }
      final task = AgenticTask.fromJson(row);
      await saveTask(task);
    }
  }

  // ── Helpers ────────────────────────────────────────────────

  static String _esc(String s) => s.replaceAll("'", "''");

  static Map<String, dynamic> _decodeJsonMap(dynamic raw) {
    if (raw == null) return {};
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) return decoded;
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return {};
  }

  static List<dynamic> _decodeJsonList(dynamic raw) {
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

  // ── Migration ──────────────────────────────────────────────

  Future<void> _migrateTasksToOrchestratorPattern() async {
    final conn = await _getConn();
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

        bool modified = false;
        if (!data.containsKey('executors') ||
            (data['executors'] as List?) == null ||
            (data['executors'] as List).isEmpty) {
          if ((data['prompt'] as String? ?? '').isNotEmpty) {
            log.info(
              '[DuckDB Migration] Migrating task $id to orchestrator-executor pattern...',
            );
            final task = AgenticTask.fromJson(data);
            allTasks[id] = task.toJson();
            modified = true;
          }
        }

        final currentData = allTasks[id]!;
        final chainConfig =
            currentData['chain_config'] as Map<String, dynamic>?;
        if (chainConfig != null &&
            (chainConfig['is_subtask'] == null ||
                chainConfig['is_subtask'] == false)) {
          if (chainConfig['on_match_task_id'] != null ||
              chainConfig['on_no_match_task_id'] != null) {
            log.info(
              '[DuckDB Migration] Migrating legacy chains for root task $id...',
            );

            final rootTask = AgenticTask.fromJson(currentData);
            List<TaskExecutor> executors = List.from(rootTask.executors);
            List<RoutingRule> routingRules = List.from(rootTask.routingRules);

            String currentSourceId = executors.isNotEmpty
                ? executors.first.id
                : id;

            String? currentNextId = chainConfig['on_match_task_id'] as String?;
            String? currentCondition =
                chainConfig['trigger_condition'] as String?;

            while (currentNextId != null &&
                allTasks.containsKey(currentNextId)) {
              final childData = allTasks[currentNextId]!;
              final childTask = AgenticTask.fromJson(childData);

              final newExecutorId = const Uuid().v4();
              executors.add(
                TaskExecutor(
                  id: newExecutorId,
                  name: childTask.name.isNotEmpty
                      ? childTask.name
                      : 'Agent ${executors.length + 1}',
                  systemPrompt: childTask.systemPrompt,
                  prompt: childTask.prompt,
                  llmConfig: childTask.llmConfig,
                  mcpTools: childTask.mcpTools,
                  internalMcps: childTask.internalMcps,
                  chatMode: childTask.chatMode,
                  stopAfterToolCall: childTask.stopAfterToolCall,
                ),
              );

              routingRules.add(
                RoutingRule(
                  id: const Uuid().v4(),
                  sourceExecutorId: currentSourceId,
                  variable: 'task_result',
                  operator: currentCondition != null ? 'contains' : 'contains',
                  value: currentCondition ?? '',
                  targetExecutorId: newExecutorId,
                ),
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
              executors: executors,
              routingRules: routingRules,
              clearChainConfig: true,
            );
            allTasks[id] = updatedRoot.toJson();
            modified = true;
          }
        }

        if (modified) {
          final escData = _esc(jsonEncode(allTasks[id]!));
          final now = DateTime.now().toIso8601String();
          await conn.execute(
            "UPDATE tasks SET data = '$escData'::JSON, updated_at = '$now' WHERE id = '$id'",
          );
          log.info('[DuckDB Migration] Saved updated task $id');
        }
      }

      for (final delId in tasksToDelete) {
        log.info('[DuckDB Migration] Deleting legacy subtask $delId');
        await conn.execute("DELETE FROM tasks WHERE id = '$delId'");
      }
    } catch (e) {
      log.warning(
        '[DuckDB Migration] Failed to run orchestrator migration: $e',
      );
    }
  }

  // ── Seed default Python tools ──────────────────────────────

  Future<void> _seedDefaultPyTools() async {
    try {
      final conn = await _getConn();
      final rows = (await conn.query('SELECT id FROM py_tools')).fetchAll();
      final existingIds = rows.map((r) => r[0] as String).toSet();
      final defaults = _defaultPyTools(DateTime.now().toIso8601String());

      if (existingIds.isEmpty) {
        log.info('[DuckDB] No tools found — seeding all defaults');
        for (final tool in defaults) {
          await savePyTool(tool);
        }
      } else {
        for (final tool in defaults) {
          final id = tool['id'] as String;
          if (!existingIds.contains(id)) {
            log.info(
              '[DuckDB] Missing default tool — seeding: $id "${tool['name']}"',
            );
            await savePyTool(tool);
          }
        }
      }
      log.info('[DuckDB] Default Python tools check complete');
    } catch (e) {
      log.warning('[DuckDB] Failed to seed default Python tools: $e');
    }
  }

  List<Map<String, dynamic>> _defaultPyTools(String now) => [
    {
      'id': '_default_csv_analyzer',
      'name': 'csv_analyzer',
      'description':
          'Parse and profile CSV data: column-level statistics, null counts, frequencies, quartiles, and type detection.',
      'input_schema': {
        'type': 'object',
        'properties': {
          'csv_data': {
            'type': 'string',
            'description': 'Raw CSV content (including header row).',
          },
          'delimiter': {
            'type': 'string',
            'description': 'Delimiter character (default: comma).',
            'default': ',',
          },
          'max_rows': {
            'type': 'integer',
            'description': 'Maximum rows to analyze (default: 10000).',
            'default': 10000,
          },
          'top_k': {
            'type': 'integer',
            'description':
                'Show top-K frequent values for categorical columns (default: 5).',
            'default': 5,
          },
        },
        'required': ['csv_data'],
      },
      'code': _csvAnalyzerCode,
      'requirements': '',
      'venv_ready': false,
      'is_active': true,
      'generation_prompt': '',
    },
    {
      'id': '_default_json_query',
      'name': 'json_query',
      'description':
          'Filter, project, sort, group-by, and aggregate JSON datasets using simple Python expressions.',
      'input_schema': {
        'type': 'object',
        'properties': {
          'data': {
            'type': 'string',
            'description': 'JSON array of objects or a single JSON object.',
          },
          'filter': {
            'type': 'string',
            'description':
                "Python expression to filter rows. Use 'item' for each element. E.g., 'item[\"age\"] > 30'.",
          },
          'project_fields': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'Field names to keep in output.',
          },
          'sort_by': {
            'type': 'string',
            'description':
                "Field name to sort by. Prefix with '-' for descending.",
          },
          'group_by': {
            'type': 'string',
            'description': 'Field name to group by.',
          },
          'aggregate': {
            'type': 'object',
            'properties': {
              'field': {'type': 'string'},
              'function': {
                'type': 'string',
                'enum': ['sum', 'avg', 'count', 'min', 'max'],
              },
            },
            'description': 'Aggregation to apply per group.',
          },
          'limit': {'type': 'integer', 'description': 'Max results.'},
        },
        'required': ['data'],
      },
      'code': _jsonQueryCode,
      'requirements': '',
      'venv_ready': false,
      'is_active': true,
      'generation_prompt': '',
    },
    {
      'id': '_default_text_classify',
      'name': 'text_classify',
      'description':
          'Classify text snippets against user-defined keyword rules. Returns best-matching labels with confidence scores.',
      'input_schema': {
        'type': 'object',
        'properties': {
          'text': {
            'type': 'string',
            'description': 'The input text to classify.',
          },
          'rules': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'label': {'type': 'string'},
                'include_keywords': {
                  'type': 'array',
                  'items': {'type': 'string'},
                },
                'exclude_keywords': {
                  'type': 'array',
                  'items': {'type': 'string'},
                },
                'min_score': {
                  'type': 'number',
                  'description':
                      'Minimum match fraction (0.0-1.0, default: 0.5).',
                },
              },
              'required': ['label', 'include_keywords'],
            },
          },
          'case_sensitive': {
            'type': 'boolean',
            'description': 'Case-sensitive matching (default: false).',
            'default': false,
          },
          'top_k': {
            'type': 'integer',
            'description': 'Return top-K matching labels (default: 3).',
            'default': 3,
          },
        },
        'required': ['text', 'rules'],
      },
      'code': _textClassifyCode,
      'requirements': '',
      'venv_ready': false,
      'is_active': true,
      'generation_prompt': '',
    },
    {
      'id': '_default_run_python',
      'name': 'run_python',
      'description':
          'Execute arbitrary Python code and return stdout output. '
          'STDLIB ONLY — no third-party packages. '
          'Use built-in modules only: os, sys, json, csv, io, re, math, pathlib, sqlite3, etc.',
      'input_schema': {
        'type': 'object',
        'properties': {
          'code': {
            'type': 'string',
            'description':
                'Python source code to execute. STDLIB ONLY — use only built-in modules. '
                'Do NOT use pip or subprocess to install packages.',
          },
          'timeoutSeconds': {
            'type': 'integer',
            'description': 'Max execution time in seconds (default: 30).',
            'default': 30,
          },
        },
        'required': ['code'],
      },
      'code': _runPythonCode,
      'requirements': '',
      'venv_ready': false,
      'is_active': true,
      'generation_prompt': '',
    },
  ];
}

// ═════════════════════════════════════════════════════════════════════════════
// Default Python tool code constants
// ═════════════════════════════════════════════════════════════════════════════

const _csvAnalyzerCode = '''import csv, io, statistics
from collections import Counter

def execute(args):
    csv_text = args.get("csv_data", "")
    delimiter = args.get("delimiter", ",")
    max_rows = args.get("max_rows", 10000)
    top_k = args.get("top_k", 5)

    if not csv_text.strip():
        return {"error": "csv_data is empty"}

    reader = csv.DictReader(io.StringIO(csv_text), delimiter=delimiter)
    rows = []
    for i, row in enumerate(reader):
        if i >= max_rows:
            break
        rows.append(row)

    if not rows:
        return {"error": "No data rows found", "columns": reader.fieldnames or []}

    columns = reader.fieldnames or list(rows[0].keys())
    profile = {}

    for col in columns:
        values = [r.get(col, "") for r in rows]
        numeric_vals = []
        for v in values:
            try:
                numeric_vals.append(float(v.replace(",", "").strip()))
            except (ValueError, AttributeError):
                pass

        null_count = sum(1 for v in values if not v or v.strip() == "")
        unique_values = len(set(v.strip() for v in values if v.strip()))
        freq = Counter(v.strip() for v in values if v.strip()).most_common(top_k)

        col_profile = {
            "type": "numeric" if len(numeric_vals) > len(values) * 0.5 else "categorical",
            "count": len(values),
            "null_count": null_count,
            "null_pct": round(null_count / len(values) * 100, 2),
            "unique_count": unique_values,
            "top_k_frequencies": [
                {"value": val, "count": cnt} for val, cnt in freq
            ],
        }

        if col_profile["type"] == "numeric":
            sorted_nums = sorted(numeric_vals)
            col_profile.update({
                "min": round(float(min(numeric_vals)), 4),
                "max": round(float(max(numeric_vals)), 4),
                "mean": round(statistics.mean(numeric_vals), 4),
                "median": round(statistics.median(numeric_vals), 4),
                "stdev": round(statistics.stdev(numeric_vals), 4) if len(numeric_vals) > 1 else 0,
                "q1": round(float(sorted_nums[len(sorted_nums)//4]), 4),
                "q3": round(float(sorted_nums[3*len(sorted_nums)//4]), 4),
            })

        profile[col] = col_profile

    return {
        "rows_analyzed": len(rows),
        "columns_found": len(columns),
        "column_names": columns,
        "profile": profile,
    }
''';

const _jsonQueryCode = '''import json
from collections import defaultdict

def execute(args):
    raw = args.get("data", "")
    if isinstance(raw, str):
        data = json.loads(raw)
    else:
        data = raw

    if isinstance(data, dict):
        items = [data]
    elif isinstance(data, list):
        items = data
    else:
        return {"error": "data must be a JSON object or array"}

    original_count = len(items)

    # Filter
    filter_expr = args.get("filter", "").strip()
    if filter_expr:
        filtered = []
        for item in items:
            try:
                if eval(filter_expr, {"__builtins__": {}}, {"item": item}):
                    filtered.append(item)
            except Exception:
                pass
        items = filtered

    # Project fields
    project_fields = args.get("project_fields")
    if project_fields and isinstance(project_fields, list):
        items = [
            {k: item[k] for k in project_fields if k in item}
            for item in items
        ]

    # Sort
    sort_by = args.get("sort_by", "").strip()
    if sort_by:
        desc = sort_by.startswith("-")
        field = sort_by.lstrip("-")
        items.sort(key=lambda x: x.get(field, ""), reverse=desc)

    # Group + Aggregate
    group_by = args.get("group_by", "").strip()
    aggregate = args.get("aggregate")
    result = items

    if group_by and aggregate:
        groups = defaultdict(list)
        for item in items:
            key = str(item.get(group_by, "null"))
            groups[key].append(item)

        agg_field = aggregate.get("field", "")
        agg_func = aggregate.get("function", "count").lower()
        grouped_result = {}
        for key, group in groups.items():
            vals = [g.get(agg_field, 0) for g in group if agg_field in g]
            numeric = [v for v in vals if isinstance(v, (int, float))]
            if agg_func == "count":
                grouped_result[key] = len(group)
            elif agg_func == "sum":
                grouped_result[key] = sum(numeric)
            elif agg_func == "avg":
                grouped_result[key] = round(sum(numeric) / len(numeric), 4) if numeric else None
            elif agg_func == "min":
                grouped_result[key] = min(numeric) if numeric else None
            elif agg_func == "max":
                grouped_result[key] = max(numeric) if numeric else None
        result = grouped_result
    elif group_by:
        groups = defaultdict(list)
        for item in items:
            key = str(item.get(group_by, "null"))
            groups[key].append(item)
        result = dict(groups)

    # Limit
    limit = args.get("limit")
    if limit and isinstance(result, list):
        result = result[:int(limit)]

    return {
        "original_count": original_count,
        "filtered_count": len(items) if isinstance(items, list) else None,
        "result": result,
    }
''';

const _textClassifyCode = '''import re

def execute(args):
    text = args.get("text", "")
    rules = args.get("rules", [])
    case_sensitive = args.get("case_sensitive", False)
    top_k = args.get("top_k", 3)

    if not text.strip():
        return {"error": "text is empty"}
    if not rules:
        return {"error": "no rules provided", "classifications": []}

    if not case_sensitive:
        text_lower = text.lower()
    else:
        text_lower = text

    def _matches(text, keywords, case_sensitive):
        matched = 0
        total = 0
        for kw in keywords:
            if not kw.strip():
                continue
            total += 1
            target = kw if case_sensitive else kw.lower()
            pattern = re.compile(r'\\b' + re.escape(target) + r'\\b',
                                 re.IGNORECASE if not case_sensitive else 0)
            if pattern.search(text):
                matched += 1
        return matched, total

    scores = []
    for rule in rules:
        label = rule.get("label", "unknown")
        include_kw = rule.get("include_keywords", [])
        exclude_kw = rule.get("exclude_keywords", [])
        min_score = float(rule.get("min_score", 0.5))

        if not include_kw:
            continue

        # Check exclusions first
        if exclude_kw:
            excl_matched, _ = _matches(text_lower, exclude_kw, case_sensitive)
            if excl_matched > 0:
                continue

        inc_matched, inc_total = _matches(text_lower, include_kw, case_sensitive)
        if inc_total == 0:
            continue

        score = round(inc_matched / inc_total, 4)
        if score >= min_score:
            scores.append({
                "label": label,
                "score": score,
                "matched_keywords": inc_matched,
                "total_keywords": inc_total,
            })

    scores.sort(key=lambda s: s["score"], reverse=True)
    best = scores[:top_k]

    highlights = []
    if best:
        for rule in rules:
            if rule.get("label") == best[0]["label"]:
                for kw in rule.get("include_keywords", []):
                    target = kw if case_sensitive else kw.lower()
                    pattern = re.compile(re.escape(target),
                                         re.IGNORECASE if not case_sensitive else 0)
                    if pattern.search(text if case_sensitive else text_lower):
                        highlights.append(kw)
                break

    return {
        "text_length": len(text),
        "rules_evaluated": len(rules),
        "classifications": best,
        "best_label": best[0]["label"] if best else None,
        "best_score": best[0]["score"] if best else 0.0,
        "matched_highlights": highlights[:10],
    }
''';

const _runPythonCode = '''import io, sys, traceback

def execute(args):
    code = args.get("code", "")
    if not code.strip():
        return {"error": "code is empty"}

    old_stdout = sys.stdout
    old_stderr = sys.stderr
    captured_out = io.StringIO()
    captured_err = io.StringIO()
    sys.stdout = captured_out
    sys.stderr = captured_err

    try:
        exec(code, {"__builtins__": __builtins__})
        stdout_text = captured_out.getvalue()
        stderr_text = captured_err.getvalue()
        result = {"output": stdout_text}
        if stderr_text.strip():
            result["stderr"] = stderr_text.strip()
        return result
    except ModuleNotFoundError as e:
        stdout_sofar = captured_out.getvalue()
        return {
            "error": f"Missing Python library: {e.name}. "
                     f"This tool is stdlib-only — no third-party packages. "
                     f"Use only built-in modules (os, sys, json, csv, io, re, "
                     f"math, pathlib, sqlite3, etc.) or create a named Python "
                     f"tool with the required pip packages.",
            "partial_output": stdout_sofar if stdout_sofar.strip() else None,
        }
    except Exception:
        exc_text = traceback.format_exc()
        stdout_sofar = captured_out.getvalue()
        return {
            "error": exc_text.strip(),
            "partial_output": stdout_sofar if stdout_sofar.strip() else None,
        }
    finally:
        sys.stdout = old_stdout
        sys.stderr = old_stderr
''';
