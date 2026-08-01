import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../models/agentic_task.dart';
import '../utils/cron_utils.dart';
import '../utils/server_logger.dart';
import '../utils/server_paths.dart';
import 'server_database_adapter.dart';

/// SQLite implementation of [ServerDatabaseAdapter] for low-resource environments
/// (≤1GB RAM — no DuckDB dependency).
///
/// Creates an identical schema to DuckDB but using SQLite-compatible types:
///   - VARCHAR → TEXT
///   - BOOLEAN → INTEGER (0/1)
///   - VARCHAR[] → TEXT (JSON array)
///   - JSON → TEXT (JSON string)
///   - TIMESTAMP → TEXT (ISO 8601)
class ServerSqliteAdapter implements ServerDatabaseAdapter {
  final String _dbPath;
  Database? _db;

  ServerSqliteAdapter({String? dbPath}) : _dbPath = dbPath ?? _defaultDbPath();

  @override
  String get engineType => 'sqlite';

  static String _defaultDbPath() {
    final dataDir = resolveServerDataDir();
    return p.join(dataDir, 'db', 'tealkit_light.db');
  }

  // ── Lifecycle ──────────────────────────────────────────────

  @override
  String get dataDir => resolveServerDataDir();

  @override
  Future<void> init() async {
    if (_db != null) return;

    final dbDir = p.dirname(_dbPath);
    await Directory(dbDir).create(recursive: true);

    log.info('[SQLite] Opening database at: $_dbPath');
    _db = sqlite3.open(_dbPath);
    _db!.execute('PRAGMA journal_mode = WAL;');
    _db!.execute('PRAGMA foreign_keys = ON;');

    await _createTables();
    await _seedDefaultPyTools();
    log.info('[SQLite] Database opened successfully');
  }

  @override
  Future<void> close() async {
    log.info('[SQLite] Closing database');
    _db?.dispose();
    _db = null;
  }

  Database get _requireDb {
    if (_db == null) {
      throw StateError('SQLite not initialized. Call init() first.');
    }
    return _db!;
  }

  // ── Schema ──────────────────────────────────────────────────

  Future<void> _createTables() async {
    final db = _requireDb;

    db.execute('''
      CREATE TABLE IF NOT EXISTS tasks (
        id        TEXT PRIMARY KEY,
        name      TEXT NOT NULL,
        enabled   INTEGER DEFAULT 1,
        agent_id  TEXT,
        tags      TEXT,
        data      TEXT NOT NULL,
        created_at TEXT DEFAULT (datetime('now')),
        updated_at TEXT DEFAULT (datetime('now'))
      )
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS internal_mcp_configs (
        id        TEXT PRIMARY KEY,
        task_id   TEXT NOT NULL,
        mcp_type  TEXT NOT NULL,
        params    TEXT NOT NULL,
        enabled   INTEGER DEFAULT 1,
        created_at TEXT DEFAULT (datetime('now')),
        updated_at TEXT DEFAULT (datetime('now'))
      )
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS py_tools (
        id                TEXT PRIMARY KEY,
        name              TEXT NOT NULL,
        description       TEXT DEFAULT '',
        input_schema      TEXT NOT NULL,
        code              TEXT NOT NULL,
        requirements      TEXT DEFAULT '',
        venv_ready        INTEGER DEFAULT 0,
        is_active         INTEGER DEFAULT 1,
        generation_prompt TEXT DEFAULT '',
        created_at        TEXT DEFAULT (datetime('now')),
        updated_at        TEXT DEFAULT (datetime('now'))
      )
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS js_tools (
        id           TEXT PRIMARY KEY,
        name         TEXT NOT NULL,
        description  TEXT DEFAULT '',
        input_schema TEXT NOT NULL DEFAULT '{"type":"object","properties":{}}',
        js_code      TEXT NOT NULL,
        is_active    INTEGER DEFAULT 1,
        created_at   TEXT DEFAULT (datetime('now')),
        updated_at   TEXT DEFAULT (datetime('now'))
      )
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS github_mcp_servers (
        id                TEXT PRIMARY KEY,
        name              TEXT NOT NULL,
        display_name      TEXT NOT NULL,
        description       TEXT DEFAULT '',
        github_url        TEXT DEFAULT '',
        language          TEXT DEFAULT 'python',
        install_type      TEXT DEFAULT 'uvx',
        package_name      TEXT NOT NULL,
        entry_point       TEXT,
        launch_args       TEXT DEFAULT '[]',
        required_env_vars TEXT DEFAULT '[]',
        env_vars          TEXT DEFAULT '{}',
        category          TEXT DEFAULT 'other',
        is_installed      INTEGER DEFAULT 0,
        is_active         INTEGER DEFAULT 0,
        is_manual         INTEGER DEFAULT 0,
        installed_at      TEXT,
        created_at        TEXT DEFAULT (datetime('now'))
      )
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS scheduler_log (
        id         TEXT PRIMARY KEY,
        task_id    TEXT NOT NULL,
        task_name  TEXT NOT NULL,
        started_at TEXT NOT NULL,
        ended_at   TEXT,
        success    INTEGER,
        message    TEXT
      )
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS tool_skills (
        id             TEXT PRIMARY KEY,
        tool_name      TEXT NOT NULL,
        mcp_type       TEXT NOT NULL,
        skill_text     TEXT DEFAULT '',
        skill_text_slm TEXT DEFAULT '',
        is_enabled     INTEGER DEFAULT 1,
        is_custom      INTEGER DEFAULT 0,
        generated_at   TEXT,
        updated_at     TEXT DEFAULT (datetime('now'))
      )
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS playground_sessions (
        id          TEXT PRIMARY KEY,
        name        TEXT NOT NULL,
        mode        TEXT DEFAULT 'local',
        data        TEXT NOT NULL,
        created_at  TEXT DEFAULT (datetime('now'))
      )
    ''');
  }

  // ── Tasks CRUD ─────────────────────────────────────────────

  @override
  Future<void> saveTask(AgenticTask task) async {
    final db = _requireDb;
    final json = jsonEncode(task.toJson());
    final tagsJson = jsonEncode(task.tags);
    final now = DateTime.now().toIso8601String();
    db.execute(
      '''INSERT INTO tasks (id, name, enabled, agent_id, tags, data, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT (id) DO UPDATE SET
           name = excluded.name,
           enabled = excluded.enabled,
           agent_id = excluded.agent_id,
           tags = excluded.tags,
           data = excluded.data,
           updated_at = excluded.updated_at''',
      [
        task.id,
        task.name,
        task.enabled ? 1 : 0,
        task.agentId,
        tagsJson,
        json,
        task.createdAt.toIso8601String(),
        now,
      ],
    );
  }

  @override
  Future<AgenticTask?> getTask(String id) async {
    final db = _requireDb;
    final result = db.select('SELECT data FROM tasks WHERE id = ?', [id]);
    if (result.isEmpty) return null;
    final raw = result.first['data'] as String?;
    if (raw == null || raw.isEmpty) return null;
    return AgenticTask.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  @override
  Future<List<AgenticTask>> getAllTasks() async {
    final db = _requireDb;
    final result = db.select('SELECT data FROM tasks ORDER BY created_at DESC');
    return result
        .map((row) {
          try {
            final raw = row['data'] as String?;
            if (raw == null || raw.isEmpty) return null;
            return AgenticTask.fromJson(
              jsonDecode(raw) as Map<String, dynamic>,
            );
          } catch (e) {
            log.warning('[SQLite] Failed to decode task: $e');
            return null;
          }
        })
        .whereType<AgenticTask>()
        .toList();
  }

  @override
  Future<List<AgenticTask>> getDueTasks() async {
    final db = _requireDb;
    final result = db.select('SELECT data FROM tasks WHERE enabled = 1');
    final now = DateTime.now().toUtc();
    return result
        .map((row) {
          try {
            final raw = row['data'] as String?;
            if (raw == null || raw.isEmpty) return null;
            return AgenticTask.fromJson(
              jsonDecode(raw) as Map<String, dynamic>,
            );
          } catch (e) {
            log.warning('[SQLite] Failed to decode due task: $e');
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
    _requireDb.execute('DELETE FROM tasks WHERE id = ?', [id]);
  }

  @override
  Future<void> updateExecution(String taskId, TaskExecution execution) async {
    final task = await getTask(taskId);
    if (task == null) return;
    await saveTask(task.copyWith(execution: execution));
  }

  @override
  Future<void> toggleTask(String id, bool enabled) async {
    _requireDb.execute('UPDATE tasks SET enabled = ? WHERE id = ?', [
      enabled ? 1 : 0,
      id,
    ]);
    final task = await getTask(id);
    if (task != null) {
      await saveTask(task.copyWith(enabled: enabled));
    }
  }

  // ── Internal MCP Configs ───────────────────────────────────

  @override
  Future<void> saveInternalMcpConfig(
    String taskId,
    InternalMcpEntry entry,
  ) async {
    final db = _requireDb;
    final paramsJson = jsonEncode(entry.initParams);
    db.execute(
      '''INSERT INTO internal_mcp_configs (id, task_id, mcp_type, params, enabled, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, datetime('now'), datetime('now'))
         ON CONFLICT (id) DO UPDATE SET
           mcp_type = excluded.mcp_type,
           params = excluded.params,
           enabled = excluded.enabled,
           updated_at = datetime('now')''',
      [entry.id, taskId, entry.mcpType, paramsJson, entry.enabled ? 1 : 0],
    );
  }

  @override
  Future<List<InternalMcpEntry>> getInternalMcpConfigs(String taskId) async {
    final db = _requireDb;
    final result = db.select(
      'SELECT id, mcp_type, params, enabled FROM internal_mcp_configs WHERE task_id = ?',
      [taskId],
    );
    return result.map((row) {
      return InternalMcpEntry(
        id: row['id'] as String,
        mcpType: row['mcp_type'] as String,
        initParams: jsonDecode(row['params'] as String) as Map<String, dynamic>,
        enabled: (row['enabled'] as int) == 1,
      );
    }).toList();
  }

  // ── Python Tools ───────────────────────────────────────────

  @override
  Future<void> savePyTool(Map<String, dynamic> tool) async {
    final db = _requireDb;
    final schema = jsonEncode(tool['input_schema'] ?? {});
    final now = DateTime.now().toIso8601String();
    db.execute(
      '''INSERT INTO py_tools (id, name, description, input_schema, code, requirements, venv_ready, is_active, generation_prompt, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT (id) DO UPDATE SET
           name = excluded.name,
           description = excluded.description,
           input_schema = excluded.input_schema,
           code = excluded.code,
           requirements = excluded.requirements,
           venv_ready = excluded.venv_ready,
           is_active = excluded.is_active,
           generation_prompt = excluded.generation_prompt,
           updated_at = excluded.updated_at''',
      [
        tool['id'] as String,
        tool['name'] as String,
        tool['description'] as String? ?? '',
        schema,
        tool['code'] as String? ?? '',
        tool['requirements'] as String? ?? '',
        (tool['venv_ready'] as bool? ?? false) ? 1 : 0,
        (tool['is_active'] as bool? ?? true) ? 1 : 0,
        tool['generation_prompt'] as String? ?? '',
        now,
        now,
      ],
    );
  }

  @override
  Future<List<Map<String, dynamic>>> getAllPyTools() async {
    final db = _requireDb;
    final result = db.select(
      'SELECT id, name, description, input_schema, code, requirements, venv_ready, is_active, generation_prompt FROM py_tools ORDER BY created_at DESC',
    );
    return result.map((row) {
      return {
        'id': row['id'],
        'name': row['name'],
        'description': row['description'],
        'input_schema': _decodeJson(row['input_schema']),
        'code': row['code'],
        'requirements': row['requirements'],
        'venv_ready': (row['venv_ready'] as int) == 1,
        'is_active': (row['is_active'] as int) == 1,
        'generation_prompt': row['generation_prompt'],
      };
    }).toList();
  }

  @override
  Future<void> setPyToolVenvReady(String id, bool ready) async {
    _requireDb.execute(
      "UPDATE py_tools SET venv_ready = ?, updated_at = datetime('now') WHERE id = ?",
      [ready ? 1 : 0, id],
    );
  }

  @override
  Future<void> deletePyTool(String id) async {
    _requireDb.execute('DELETE FROM py_tools WHERE id = ?', [id]);
  }

  // ── JavaScript Tools ───────────────────────────────────────

  @override
  Future<void> saveJsTool(Map<String, dynamic> tool) async {
    final db = _requireDb;
    final schema = jsonEncode(
      tool['input_schema'] ??
          tool['inputSchema'] ??
          const <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{},
          },
    );
    final now = DateTime.now().toIso8601String();
    db.execute(
      '''INSERT INTO js_tools (id, name, description, input_schema, js_code, is_active, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT (id) DO UPDATE SET
           name = excluded.name,
           description = excluded.description,
           input_schema = excluded.input_schema,
           js_code = excluded.js_code,
           is_active = excluded.is_active,
           updated_at = excluded.updated_at''',
      [
        tool['id'] as String,
        tool['name'] as String,
        tool['description'] as String? ?? '',
        schema,
        tool['js_code'] as String? ?? tool['jsCode'] as String? ?? '',
        (tool['is_active'] as bool? ?? tool['isActive'] as bool? ?? true)
            ? 1
            : 0,
        now,
        now,
      ],
    );
  }

  @override
  Future<List<Map<String, dynamic>>> getAllJsTools({
    bool activeOnly = false,
  }) async {
    final db = _requireDb;
    final where = activeOnly ? 'WHERE is_active = 1' : '';
    final result = db.select(
      'SELECT id, name, description, input_schema, js_code, is_active, created_at, updated_at FROM js_tools $where ORDER BY updated_at DESC',
    );
    return result.map((row) {
      return {
        'id': row['id'],
        'name': row['name'],
        'description': row['description'],
        'input_schema': _decodeJson(row['input_schema']),
        'js_code': row['js_code'],
        'is_active': (row['is_active'] as int) == 1,
        'created_at': row['created_at']?.toString(),
        'updated_at': row['updated_at']?.toString(),
      };
    }).toList();
  }

  @override
  Future<void> deleteJsTool(String id) async {
    _requireDb.execute('DELETE FROM js_tools WHERE id = ?', [id]);
  }

  // ── GitHub MCP Servers ─────────────────────────────────────

  @override
  Future<void> saveGithubMcpServer(GithubMcpServerDefinition server) async {
    final db = _requireDb;
    final launchArgsJson = jsonEncode(server.launchArgs);
    final requiredEnvVarsJson = jsonEncode(server.requiredEnvVars);
    final envVarsJson = jsonEncode(server.envVars);

    db.execute(
      '''INSERT INTO github_mcp_servers (
           id, name, display_name, description, github_url, language, install_type,
           package_name, entry_point, launch_args, required_env_vars, env_vars,
           category, is_installed, is_active, is_manual, installed_at, created_at
         ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT (id) DO UPDATE SET
           display_name = excluded.display_name,
           description = excluded.description,
           launch_args = excluded.launch_args,
           required_env_vars = excluded.required_env_vars,
           env_vars = excluded.env_vars,
           category = excluded.category,
           is_installed = excluded.is_installed,
           is_active = excluded.is_active,
           is_manual = excluded.is_manual,
           installed_at = excluded.installed_at''',
      [
        server.id,
        server.name,
        server.displayName,
        server.description,
        server.githubUrl,
        server.language,
        server.installType,
        server.packageName,
        server.entryPoint,
        launchArgsJson,
        requiredEnvVarsJson,
        envVarsJson,
        server.category,
        server.isInstalled ? 1 : 0,
        server.isActive ? 1 : 0,
        server.isManual ? 1 : 0,
        server.installedAt?.toIso8601String(),
        server.createdAt.toIso8601String(),
      ],
    );
  }

  @override
  Future<List<GithubMcpServerDefinition>> getAllGithubMcpServers() async {
    final db = _requireDb;
    final result = db.select(
      'SELECT id, name, display_name, description, github_url, language, install_type, '
      'package_name, entry_point, launch_args, required_env_vars, env_vars, category, '
      'is_installed, is_active, is_manual, installed_at, created_at FROM github_mcp_servers ORDER BY created_at DESC',
    );

    return result.map((row) {
      return GithubMcpServerDefinition(
        id: row['id'] as String,
        name: row['name'] as String,
        displayName: row['display_name'] as String,
        description: row['description'] as String? ?? '',
        githubUrl: row['github_url'] as String? ?? '',
        language: row['language'] as String? ?? 'python',
        installType: row['install_type'] as String? ?? 'uvx',
        packageName: row['package_name'] as String,
        entryPoint: row['entry_point'] as String?,
        launchArgs: _decodeJsonList(row['launch_args']).cast<String>(),
        requiredEnvVars: _decodeJsonList(
          row['required_env_vars'],
        ).cast<String>(),
        envVars: Map<String, String>.from(_decodeJsonMap(row['env_vars'])),
        category: row['category'] as String? ?? 'other',
        isInstalled: (row['is_installed'] as int) == 1,
        isActive: (row['is_active'] as int) == 1,
        isManual: (row['is_manual'] as int) == 1,
        installedAt: row['installed_at'] != null
            ? DateTime.tryParse(row['installed_at'] as String)
            : null,
        createdAt:
            DateTime.tryParse(row['created_at'] as String) ?? DateTime.now(),
      );
    }).toList();
  }

  @override
  Future<void> deleteGithubMcpServer(String id) async {
    _requireDb.execute('DELETE FROM github_mcp_servers WHERE id = ?', [id]);
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
    _requireDb.execute(
      '''INSERT INTO scheduler_log (id, task_id, task_name, started_at, ended_at, success, message)
         VALUES (?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT (id) DO UPDATE SET
           ended_at = excluded.ended_at,
           success = excluded.success,
           message = excluded.message''',
      [
        id,
        taskId,
        taskName,
        startedAt.toIso8601String(),
        endedAt?.toIso8601String(),
        success != null ? (success ? 1 : 0) : null,
        message,
      ],
    );
  }

  // ── Tool Skills ────────────────────────────────────────────

  @override
  Future<void> saveToolSkill(Map<String, dynamic> skill) async {
    final db = _requireDb;
    db.execute(
      '''INSERT INTO tool_skills (id, tool_name, mcp_type, skill_text, skill_text_slm, is_enabled, is_custom, generated_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
         ON CONFLICT (id) DO UPDATE SET
           tool_name = excluded.tool_name,
           mcp_type = excluded.mcp_type,
           skill_text = excluded.skill_text,
           skill_text_slm = excluded.skill_text_slm,
           is_enabled = excluded.is_enabled,
           is_custom = excluded.is_custom,
           generated_at = excluded.generated_at,
           updated_at = excluded.updated_at''',
      [
        skill['id'] as String,
        skill['tool_name'] as String,
        skill['mcp_type'] as String,
        skill['skill_text'] as String? ?? '',
        skill['skill_text_slm'] as String? ?? '',
        (skill['is_enabled'] as bool? ?? true) ? 1 : 0,
        (skill['is_custom'] as bool? ?? false) ? 1 : 0,
        skill['generated_at'],
      ],
    );
  }

  @override
  Future<List<Map<String, dynamic>>> getAllToolSkills({String? mcpType}) async {
    final db = _requireDb;
    final where = mcpType != null ? 'WHERE mcp_type = ?' : '';
    final params = mcpType != null ? [mcpType] : <String>[];
    final result = db.select(
      'SELECT id, tool_name, mcp_type, skill_text, skill_text_slm, is_enabled, is_custom, generated_at, updated_at FROM tool_skills $where ORDER BY mcp_type, tool_name',
      params,
    );
    return result
        .map(
          (row) => <String, dynamic>{
            'id': row['id'] as String,
            'tool_name': row['tool_name'] as String,
            'mcp_type': row['mcp_type'] as String,
            'skill_text': row['skill_text'] as String? ?? '',
            'skill_text_slm': row['skill_text_slm'] as String? ?? '',
            'is_enabled': (row['is_enabled'] as int) == 1,
            'is_custom': (row['is_custom'] as int) == 1,
            'generated_at': row['generated_at'],
            'updated_at': row['updated_at'],
          },
        )
        .toList();
  }

  @override
  Future<void> deleteToolSkill(String id) async {
    _requireDb.execute('DELETE FROM tool_skills WHERE id = ?', [id]);
  }

  @override
  Future<void> deleteToolSkillsByToolName(String toolName) async {
    _requireDb.execute('DELETE FROM tool_skills WHERE tool_name = ?', [
      toolName,
    ]);
  }

  @override
  Future<List<String>> getToolNamesWithSkills({String? mcpType}) async {
    final db = _requireDb;
    final where = mcpType != null ? 'WHERE mcp_type = ?' : '';
    final params = mcpType != null ? [mcpType] : <String>[];
    final result = db.select(
      'SELECT DISTINCT tool_name FROM tool_skills $where',
      params,
    );
    return result.map((row) => row['tool_name'] as String).toList();
  }

  // ── Playground Sessions ────────────────────────────────────

  @override
  Future<void> savePlaygroundSession(Map<String, dynamic> session) async {
    final db = _requireDb;
    final id = session['id'] as String? ?? '';
    final name = session['name'] as String? ?? '';
    final mode = session['mode'] as String? ?? 'local';
    final createdAt =
        session['createdAt'] as String? ?? DateTime.now().toIso8601String();
    final json = jsonEncode(session);
    db.execute(
      '''INSERT INTO playground_sessions (id, name, mode, data, created_at)
         VALUES (?, ?, ?, ?, ?)
         ON CONFLICT (id) DO UPDATE SET
           name = excluded.name,
           mode = excluded.mode,
           data = excluded.data''',
      [id, name, mode, json, createdAt],
    );
  }

  @override
  Future<List<Map<String, dynamic>>> getAllPlaygroundSessions() async {
    final db = _requireDb;
    final result = db.select(
      'SELECT data FROM playground_sessions ORDER BY created_at DESC',
    );
    return result
        .map((row) {
          try {
            final raw = row['data'] as String?;
            if (raw == null || raw.isEmpty) return null;
            return jsonDecode(raw) as Map<String, dynamic>;
          } catch (e) {
            log.warning('[SQLite] Failed to decode playground session: $e');
            return null;
          }
        })
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  @override
  Future<void> deletePlaygroundSession(String id) async {
    _requireDb.execute('DELETE FROM playground_sessions WHERE id = ?', [id]);
  }

  // ── Raw Access ─────────────────────────────────────────────

  @override
  Future<void> execute(String sql) async {
    _requireDb.execute(sql);
  }

  @override
  Future<List<List<dynamic>>> query(String sql) async {
    final result = _requireDb.select(sql);
    return result.map((row) => row.values.toList()).toList();
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

  // ── Seed default Python tools ──────────────────────────────

  Future<void> _seedDefaultPyTools() async {
    try {
      final db = _requireDb;
      final countResult = db.select('SELECT COUNT(*) AS cnt FROM py_tools');
      final count = countResult.first['cnt'] as int? ?? 0;
      if (count > 0) return;

      log.info('[SQLite] Seeding default Python tools');
      final now = DateTime.now().toIso8601String();
      for (final tool in _defaultPyTools(now)) {
        await savePyTool(tool);
      }
      log.info(
        '[SQLite] Seeded ${_defaultPyTools(now).length} default Python tools',
      );
    } catch (e) {
      log.warning('[SQLite] Failed to seed default Python tools: $e');
    }
  }

  List<Map<String, dynamic>> _defaultPyTools(String now) => [
    {
      'id': '_default_csv_analyzer',
      'name': 'csv_analyzer',
      'description':
          'Parse and profile CSV data: column-level statistics, null counts, frequencies, quartiles, and type detection.',
      'input_schema': const {
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
      'input_schema': const {
        'type': 'object',
        'properties': {
          'data': {
            'type': 'string',
            'description': 'JSON array of objects or a single JSON object.',
          },
          'filter': {
            'type': 'string',
            'description':
                "Python expression to filter rows. Use 'item' for each element.",
          },
          'project_fields': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'Field names to keep.',
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
          'Classify text snippets against user-defined keyword rules.',
      'input_schema': const {
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
                  'description': 'Minimum match fraction (0.0-1.0).',
                },
              },
              'required': ['label', 'include_keywords'],
            },
          },
          'case_sensitive': {'type': 'boolean', 'default': false},
          'top_k': {'type': 'integer', 'default': 3},
        },
        'required': ['text', 'rules'],
      },
      'code': _textClassifyCode,
      'requirements': '',
      'venv_ready': false,
      'is_active': true,
      'generation_prompt': '',
    },
  ];

  // ── Helpers ────────────────────────────────────────────────

  static Map<String, dynamic> _decodeJson(dynamic raw) {
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
}

// ═════════════════════════════════════════════════════════════════════════════
// Default Python tool code constants (same as DuckDB adapter)
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
            "top_k_frequencies": [{"value": val, "count": cnt} for val, cnt in freq],
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

    return {"rows_analyzed": len(rows), "columns_found": len(columns), "column_names": columns, "profile": profile}
''';

const _jsonQueryCode = '''import json
from collections import defaultdict

def execute(args):
    raw = args.get("data", "")
    if isinstance(raw, str):
        data = json.loads(raw)
    else:
        data = raw
    items = [data] if isinstance(data, dict) else data if isinstance(data, list) else []
    if not isinstance(items, list):
        return {"error": "data must be a JSON object or array"}
    original_count = len(items)

    filter_expr = args.get("filter", "").strip()
    if filter_expr:
        items = [item for item in items if eval(filter_expr, {"__builtins__": {}}, {"item": item})]

    project_fields = args.get("project_fields")
    if project_fields and isinstance(project_fields, list):
        items = [{k: item[k] for k in project_fields if k in item} for item in items]

    sort_by = args.get("sort_by", "").strip()
    if sort_by:
        desc = sort_by.startswith("-")
        field = sort_by.lstrip("-")
        items.sort(key=lambda x: x.get(field, ""), reverse=desc)

    group_by = args.get("group_by", "").strip()
    aggregate = args.get("aggregate")
    result = items
    if group_by and aggregate:
        groups = defaultdict(list)
        for item in items:
            groups[str(item.get(group_by, "null"))].append(item)
        agg_field = aggregate.get("field", "")
        agg_func = aggregate.get("function", "count").lower()
        result = {}
        for key, group in groups.items():
            vals = [g.get(agg_field, 0) for g in group if agg_field in g]
            numeric = [v for v in vals if isinstance(v, (int, float))]
            if agg_func == "count": result[key] = len(group)
            elif agg_func == "sum": result[key] = sum(numeric)
            elif agg_func == "avg": result[key] = round(sum(numeric)/len(numeric), 4) if numeric else None
            elif agg_func == "min": result[key] = min(numeric) if numeric else None
            elif agg_func == "max": result[key] = max(numeric) if numeric else None
    elif group_by:
        groups = defaultdict(list)
        for item in items:
            groups[str(item.get(group_by, "null"))].append(item)
        result = dict(groups)

    limit = args.get("limit")
    if limit and isinstance(result, list):
        result = result[:int(limit)]
    return {"original_count": original_count, "filtered_count": len(items) if isinstance(items, list) else None, "result": result}
''';

const _textClassifyCode = '''import re

def execute(args):
    text = args.get("text", "")
    rules = args.get("rules", [])
    case_sensitive = args.get("case_sensitive", False)
    top_k = args.get("top_k", 3)
    if not text.strip(): return {"error": "text is empty"}
    if not rules: return {"error": "no rules provided", "classifications": []}
    text_lower = text if case_sensitive else text.lower()

    def _matches(t, kws, cs):
        m, tot = 0, 0
        for kw in kws:
            if not kw.strip(): continue
            tot += 1
            target = kw if cs else kw.lower()
            if re.search(r'\\b' + re.escape(target) + r'\\b', t, 0 if cs else re.IGNORECASE):
                m += 1
        return m, tot

    scores = []
    for rule in rules:
        label = rule.get("label", "unknown")
        include_kw = rule.get("include_keywords", [])
        exclude_kw = rule.get("exclude_keywords", [])
        min_score = float(rule.get("min_score", 0.5))
        if not include_kw: continue
        if exclude_kw:
            excl_m, _ = _matches(text_lower, exclude_kw, case_sensitive)
            if excl_m > 0: continue
        inc_m, inc_tot = _matches(text_lower, include_kw, case_sensitive)
        if inc_tot == 0: continue
        score = round(inc_m / inc_tot, 4)
        if score >= min_score:
            scores.append({"label": label, "score": score, "matched_keywords": inc_m, "total_keywords": inc_tot})

    scores.sort(key=lambda s: s["score"], reverse=True)
    return {"text_length": len(text), "rules_evaluated": len(rules), "classifications": scores[:top_k], "best_label": scores[0]["label"] if scores else None, "best_score": scores[0]["score"] if scores else 0.0}
''';
