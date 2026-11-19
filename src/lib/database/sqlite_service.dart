import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite_vector/sqlite_vector.dart';
import 'package:uuid/uuid.dart';

import '../models/workflow_task.dart';
import '../services/app_logger.dart';
import '../utils/semantic_embedding.dart';

/// Central SQLite + `sqlite_vector` + FTS5 service for TealKit.
///
/// Replaces DuckDB as the single embedded database across all platforms:
///   • Tasks / Workflows, Internal MCP configs, Skills, Sub-agents, Python tools,
///     GitHub MCP registry, Tool hints, Workflow memory store, and `_sys_meta`
///   • Hybrid vector (`sqlite_vector` KNN) + lexical (SQLite FTS5 BM25) search
///     for `document_index` and `website_index`
class SqliteService {
  static const String dbFileName = 'mobile_ai_agent.sqlite';

  Database? _db;
  String? _dbPath;
  bool _vectorLoaded = false;
  bool _vectorInitialized = false;

  static bool _extensionAttempted = false;
  static bool _extensionAvailable = false;

  // ── Singleton ──
  static final SqliteService _instance = SqliteService._internal();
  factory SqliteService() => _instance;
  SqliteService._internal();

  /// Path to the open SQLite database file, or null if not yet initialized / in-memory.
  String? get dbPath => _dbPath;

  /// True when the native `sqlite_vector` extension loaded successfully.
  bool get isVectorExtensionLoaded => _vectorLoaded;

  bool get isInitialized => _db != null;

  static bool _ensureVectorExtension() {
    if (_extensionAttempted) return _extensionAvailable;
    _extensionAttempted = true;
    try {
      sqlite3.loadSqliteVectorExtension();
      _extensionAvailable = true;
      log.info('[SQLite] sqlite_vector extension loaded successfully');
    } catch (e) {
      _extensionAvailable = false;
      log.warning(
        '[SQLite] sqlite_vector extension unavailable (falling back to pure-Dart isolate vector scoring): $e',
      );
    }
    return _extensionAvailable;
  }

  // ──────────────────────────────────────────────
  // Lifecycle
  // ──────────────────────────────────────────────

  Future<void> init({String? customPath}) async {
    if (_db != null) return;

    _vectorLoaded = _ensureVectorExtension();

    final String targetPath;
    if (customPath != null && customPath.isNotEmpty) {
      targetPath = customPath;
      await Directory(p.dirname(targetPath)).create(recursive: true);
    } else {
      final supportDir = await getApplicationSupportDirectory();
      final dbDir = p.join(supportDir.path, 'mobile_ai_agent');
      await Directory(dbDir).create(recursive: true);
      targetPath = p.join(dbDir, dbFileName);
    }

    log.info('[SQLite] Opening database at: $targetPath');
    _db = sqlite3.open(targetPath);
    _dbPath = targetPath;

    _configurePragmas();
    _createTables();
    await _migrateTasksToOrchestratorPattern();
    log.info('[SQLite] Database opened and verified');
  }

  /// Initialize with an in-memory database (for unit/integration tests).
  Future<void> initInMemory() async {
    if (_db != null) return;

    _vectorLoaded = _ensureVectorExtension();
    log.info('[SQLite] Opening in-memory database (test mode)');
    _db = sqlite3.openInMemory();
    _dbPath = ':memory:';

    _configurePragmas();
    _createTables();
    await _migrateTasksToOrchestratorPattern();
  }

  Database get _requireDb {
    if (_db == null) {
      throw StateError('SqliteService not initialized. Call init() first.');
    }
    return _db!;
  }

  Future<Database> _ensureOpen() async {
    if (_db == null) {
      await init();
    }
    return _db!;
  }

  void _configurePragmas() {
    final db = _requireDb;
    try {
      db.execute('PRAGMA journal_mode = WAL;');
      db.execute('PRAGMA synchronous = NORMAL;');
      db.execute('PRAGMA foreign_keys = ON;');
      db.execute('PRAGMA busy_timeout = 5000;');
    } catch (e) {
      log.warning('[SQLite] PRAGMA setup warning: $e');
    }
  }

  Future<void> close() async {
    if (_db == null) return;
    log.info('[SQLite] Closing database');
    try {
      _db!.close();
    } catch (_) {}
    _db = null;
    _dbPath = null;
    _vectorInitialized = false;
  }

  /// Runs [action] inside an atomic SQLite transaction.
  void runInTransaction(void Function(Database db) action) {
    final db = _requireDb;
    db.execute('BEGIN IMMEDIATE');
    try {
      action(db);
      db.execute('COMMIT');
    } catch (_) {
      try {
        db.execute('ROLLBACK');
      } catch (_) {}
      rethrow;
    }
  }

  // ──────────────────────────────────────────────
  // Schema + Vector + FTS5 Setup
  // ──────────────────────────────────────────────

  void _createTables() {
    final db = _requireDb;

    db.execute('''
      CREATE TABLE IF NOT EXISTS tasks (
        id         TEXT PRIMARY KEY,
        name       TEXT NOT NULL,
        enabled    INTEGER DEFAULT 1,
        agent_id   TEXT,
        tags       TEXT DEFAULT '[]',
        data       TEXT NOT NULL,
        created_at TEXT DEFAULT (datetime('now')),
        updated_at TEXT DEFAULT (datetime('now'))
      )
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS internal_mcp_configs (
        id         TEXT PRIMARY KEY,
        task_id    TEXT NOT NULL,
        mcp_type   TEXT NOT NULL,
        params     TEXT NOT NULL,
        enabled    INTEGER DEFAULT 1,
        created_at TEXT DEFAULT (datetime('now')),
        updated_at TEXT DEFAULT (datetime('now'))
      )
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS document_index (
        id             TEXT PRIMARY KEY,
        root_path      TEXT NOT NULL,
        file_path      TEXT NOT NULL,
        file_name      TEXT NOT NULL,
        file_type      TEXT NOT NULL,
        content_text   TEXT,
        embedding_json TEXT,
        embedding      BLOB,
        file_size      INTEGER,
        last_modified  TEXT,
        indexed_at     TEXT DEFAULT (datetime('now'))
      )
    ''');
    _tryAlter(db, 'ALTER TABLE document_index ADD COLUMN embedding_json TEXT');
    _tryAlter(db, 'ALTER TABLE document_index ADD COLUMN embedding BLOB');
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_doc_root ON document_index(root_path)',
    );

    db.execute('''
      CREATE TABLE IF NOT EXISTS website_index (
        id             TEXT PRIMARY KEY,
        seed_url       TEXT NOT NULL,
        url            TEXT NOT NULL,
        domain         TEXT NOT NULL,
        title          TEXT,
        content_text   TEXT,
        embedding_json TEXT,
        embedding      BLOB,
        http_status    INTEGER,
        indexed_at     TEXT DEFAULT (datetime('now'))
      )
    ''');
    _tryAlter(db, 'ALTER TABLE website_index ADD COLUMN embedding_json TEXT');
    _tryAlter(db, 'ALTER TABLE website_index ADD COLUMN embedding BLOB');
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_web_seed ON website_index(seed_url)',
    );

    // FTS5 full-text indexes synced via triggers for fast BM25 lexical search
    _setupFts5Tables(db);

    // Initialize sqlite_vector metadata on embedding BLOB columns
    _initVectorColumns(db);

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
    _tryAlter(
      db,
      'ALTER TABLE github_mcp_servers ADD COLUMN is_manual INTEGER DEFAULT 0',
    );

    db.execute('''
      CREATE TABLE IF NOT EXISTS _sys_meta (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS tool_skills (
        id             TEXT PRIMARY KEY,
        tool_name      TEXT NOT NULL,
        mcp_type       TEXT NOT NULL,
        skill_text     TEXT NOT NULL DEFAULT '',
        skill_text_slm TEXT NOT NULL DEFAULT '',
        is_enabled     INTEGER DEFAULT 1,
        is_custom      INTEGER DEFAULT 0,
        generated_at   TEXT DEFAULT (datetime('now')),
        updated_at     TEXT DEFAULT (datetime('now'))
      )
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS skill_defs (
        id          TEXT PRIMARY KEY,
        name        TEXT NOT NULL,
        goal        TEXT DEFAULT '',
        description TEXT DEFAULT '',
        skill_def   TEXT NOT NULL,
        tool_names  TEXT DEFAULT '[]',
        created_at  TEXT DEFAULT (datetime('now')),
        updated_at  TEXT DEFAULT (datetime('now'))
      )
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS workflow_memory_store (
        workflow_id  TEXT NOT NULL,
        run_id       TEXT NOT NULL,
        memory_key   TEXT NOT NULL,
        memory_value TEXT NOT NULL,
        scope        TEXT DEFAULT 'workflow',
        created_by   TEXT NOT NULL,
        updated_at   TEXT DEFAULT (datetime('now')),
        PRIMARY KEY (workflow_id, run_id, memory_key)
      )
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS subagent_definitions (
        key           TEXT PRIMARY KEY,
        name          TEXT NOT NULL,
        description   TEXT DEFAULT '',
        model         TEXT DEFAULT 'default',
        system_prompt TEXT DEFAULT '',
        tools_json    TEXT DEFAULT '[]',
        max_turns     INTEGER DEFAULT 8,
        created_at    TEXT DEFAULT (datetime('now')),
        updated_at    TEXT DEFAULT (datetime('now'))
      )
    ''');
  }

  void _tryAlter(Database db, String sql) {
    try {
      db.execute(sql);
    } catch (_) {}
  }

  void _setupFts5Tables(Database db) {
    try {
      db.execute('''
        CREATE VIRTUAL TABLE IF NOT EXISTS document_index_fts USING fts5(
          file_name,
          content_text,
          content='document_index',
          content_rowid='rowid'
        )
      ''');
      db.execute('''
        CREATE TRIGGER IF NOT EXISTS document_index_ai AFTER INSERT ON document_index BEGIN
          INSERT INTO document_index_fts(rowid, file_name, content_text)
          VALUES (new.rowid, COALESCE(new.file_name, ''), COALESCE(new.content_text, ''));
        END
      ''');
      db.execute('''
        CREATE TRIGGER IF NOT EXISTS document_index_ad AFTER DELETE ON document_index BEGIN
          INSERT INTO document_index_fts(document_index_fts, rowid, file_name, content_text)
          VALUES ('delete', old.rowid, COALESCE(old.file_name, ''), COALESCE(old.content_text, ''));
        END
      ''');
      db.execute('''
        CREATE TRIGGER IF NOT EXISTS document_index_au AFTER UPDATE ON document_index BEGIN
          INSERT INTO document_index_fts(document_index_fts, rowid, file_name, content_text)
          VALUES ('delete', old.rowid, COALESCE(old.file_name, ''), COALESCE(old.content_text, ''));
          INSERT INTO document_index_fts(rowid, file_name, content_text)
          VALUES (new.rowid, COALESCE(new.file_name, ''), COALESCE(new.content_text, ''));
        END
      ''');

      db.execute('''
        CREATE VIRTUAL TABLE IF NOT EXISTS website_index_fts USING fts5(
          title,
          content_text,
          content='website_index',
          content_rowid='rowid'
        )
      ''');
      db.execute('''
        CREATE TRIGGER IF NOT EXISTS website_index_ai AFTER INSERT ON website_index BEGIN
          INSERT INTO website_index_fts(rowid, title, content_text)
          VALUES (new.rowid, COALESCE(new.title, ''), COALESCE(new.content_text, ''));
        END
      ''');
      db.execute('''
        CREATE TRIGGER IF NOT EXISTS website_index_ad AFTER DELETE ON website_index BEGIN
          INSERT INTO website_index_fts(website_index_fts, rowid, title, content_text)
          VALUES ('delete', old.rowid, COALESCE(old.title, ''), COALESCE(old.content_text, ''));
        END
      ''');
      db.execute('''
        CREATE TRIGGER IF NOT EXISTS website_index_au AFTER UPDATE ON website_index BEGIN
          INSERT INTO website_index_fts(website_index_fts, rowid, title, content_text)
          VALUES ('delete', old.rowid, COALESCE(old.title, ''), COALESCE(old.content_text, ''));
          INSERT INTO website_index_fts(rowid, title, content_text)
          VALUES (new.rowid, COALESCE(new.title, ''), COALESCE(new.content_text, ''));
        END
      ''');
    } catch (e) {
      log.warning('[SQLite] FTS5 table setup skipped/failed: $e');
    }
  }

  void _initVectorColumns(Database db) {
    if (!_vectorLoaded || _vectorInitialized) return;
    const dim = SemanticEmbedding.defaultDimensions;
    for (final table in ['document_index', 'website_index']) {
      try {
        db.select(
          "SELECT vector_init('$table', 'embedding', 'type=FLOAT32,dimension=$dim,distance=COSINE')",
        );
      } catch (_) {
        try {
          db.select(
            "SELECT vector_init('$table', 'embedding', 'type=FLOAT32,dimension=$dim')",
          );
        } catch (e) {
          log.warning('[SQLite] vector_init failed for $table: $e');
          return;
        }
      }
    }
    _vectorInitialized = true;
  }

  // ──────────────────────────────────────────────
  // Vector + Hybrid Index Helpers (`document_index` & `website_index`)
  // ──────────────────────────────────────────────

  Future<void> upsertDocumentIndex({
    required String id,
    required String rootPath,
    required String filePath,
    required String fileName,
    required String fileType,
    required String contentText,
    required List<double> embedding,
    required int fileSize,
    required String lastModified,
    required String indexedAt,
  }) async {
    final db = await _ensureOpen();
    final embJson = SemanticEmbedding.toJson(embedding);
    if (_vectorLoaded && _vectorInitialized) {
      db.execute(
        '''
        INSERT OR REPLACE INTO document_index
          (id, root_path, file_path, file_name, file_type,
           content_text, embedding_json, embedding, file_size, last_modified, indexed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, vector_as_f32(?), ?, ?, ?)
        ''',
        [
          id,
          rootPath,
          filePath,
          fileName,
          fileType,
          contentText,
          embJson,
          embJson,
          fileSize,
          lastModified,
          indexedAt,
        ],
      );
    } else {
      db.execute(
        '''
        INSERT OR REPLACE INTO document_index
          (id, root_path, file_path, file_name, file_type,
           content_text, embedding_json, file_size, last_modified, indexed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          id,
          rootPath,
          filePath,
          fileName,
          fileType,
          contentText,
          embJson,
          fileSize,
          lastModified,
          indexedAt,
        ],
      );
    }
  }

  /// Queries `sqlite_vector` KNN candidates (`rowid` -> distance) on `document_index`.
  Future<List<Map<String, dynamic>>> vectorSearchDocuments({
    required List<double> queryEmbedding,
    required String whereScopeSql,
    int k = 100,
  }) async {
    final db = await _ensureOpen();
    if (!_vectorLoaded || !_vectorInitialized) return const [];
    final embJson = SemanticEmbedding.toJson(queryEmbedding);
    try {
      final rs = db.select(
        '''
        SELECT d.file_path, d.file_name, d.file_type, d.file_size,
               SUBSTR(d.content_text, 1, 81920) AS content_text,
               d.embedding_json, d.last_modified, v.distance
        FROM vector_full_scan('document_index', 'embedding', vector_as_f32(?), ?) AS v
        JOIN document_index AS d ON d.rowid = v.rowid
        $whereScopeSql
        ''',
        [embJson, k],
      );
      return rs.map((r) => Map<String, dynamic>.from(r)).toList();
    } catch (e) {
      log.warning('[SQLite] vectorSearchDocuments fallback triggered: $e');
      return const [];
    }
  }

  /// Queries FTS5 BM25 ranked candidates on `document_index_fts`.
  Future<Map<String, double>> ftsRankDocuments(
    String rawQuery, {
    int limit = 100,
  }) async {
    final db = await _ensureOpen();
    final ftsQuery = _buildSafeFtsQuery(rawQuery);
    if (ftsQuery.isEmpty) return const {};
    try {
      final rs = db.select(
        '''
        SELECT d.file_path, bm25(document_index_fts) AS rank_score
        FROM document_index_fts
        JOIN document_index AS d ON d.rowid = document_index_fts.rowid
        WHERE document_index_fts MATCH ?
        ORDER BY rank_score ASC
        LIMIT ?
        ''',
        [ftsQuery, limit],
      );
      final ranks = <String, double>{};
      var idx = 0;
      for (final r in rs) {
        final fp = r['file_path']?.toString();
        if (fp != null && fp.isNotEmpty) {
          // Reciprocal Rank score 1 / (60 + rank)
          ranks[fp] = 1.0 / (60.0 + idx);
          idx++;
        }
      }
      return ranks;
    } catch (_) {
      return const {};
    }
  }

  Future<void> upsertWebsiteIndex({
    required String id,
    required String seedUrl,
    required String url,
    required String domain,
    required String title,
    required String contentText,
    required List<double> embedding,
    required int httpStatus,
    required String indexedAt,
  }) async {
    final db = await _ensureOpen();
    final embJson = SemanticEmbedding.toJson(embedding);
    if (_vectorLoaded && _vectorInitialized) {
      db.execute(
        '''
        INSERT OR REPLACE INTO website_index
          (id, seed_url, url, domain, title, content_text,
           embedding_json, embedding, http_status, indexed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, vector_as_f32(?), ?, ?)
        ''',
        [
          id,
          seedUrl,
          url,
          domain,
          title,
          contentText,
          embJson,
          embJson,
          httpStatus,
          indexedAt,
        ],
      );
    } else {
      db.execute(
        '''
        INSERT OR REPLACE INTO website_index
          (id, seed_url, url, domain, title, content_text,
           embedding_json, http_status, indexed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          id,
          seedUrl,
          url,
          domain,
          title,
          contentText,
          embJson,
          httpStatus,
          indexedAt,
        ],
      );
    }
  }

  Future<List<Map<String, dynamic>>> vectorSearchWebsites({
    required List<double> queryEmbedding,
    required String whereScopeSql,
    int k = 150,
  }) async {
    final db = await _ensureOpen();
    if (!_vectorLoaded || !_vectorInitialized) return const [];
    final embJson = SemanticEmbedding.toJson(queryEmbedding);
    try {
      final rs = db.select(
        '''
        SELECT w.url, w.domain, w.title, w.content_text,
               w.embedding_json, w.indexed_at, v.distance
        FROM vector_full_scan('website_index', 'embedding', vector_as_f32(?), ?) AS v
        JOIN website_index AS w ON w.rowid = v.rowid
        $whereScopeSql
        ''',
        [embJson, k],
      );
      return rs.map((r) => Map<String, dynamic>.from(r)).toList();
    } catch (e) {
      log.warning('[SQLite] vectorSearchWebsites fallback triggered: $e');
      return const [];
    }
  }

  Future<Map<String, double>> ftsRankWebsites(
    String rawQuery, {
    int limit = 150,
  }) async {
    final db = await _ensureOpen();
    final ftsQuery = _buildSafeFtsQuery(rawQuery);
    if (ftsQuery.isEmpty) return const {};
    try {
      final rs = db.select(
        '''
        SELECT w.url, bm25(website_index_fts) AS rank_score
        FROM website_index_fts
        JOIN website_index AS w ON w.rowid = website_index_fts.rowid
        WHERE website_index_fts MATCH ?
        ORDER BY rank_score ASC
        LIMIT ?
        ''',
        [ftsQuery, limit],
      );
      final ranks = <String, double>{};
      var idx = 0;
      for (final r in rs) {
        final url = r['url']?.toString();
        if (url != null && url.isNotEmpty) {
          ranks[url] = 1.0 / (60.0 + idx);
          idx++;
        }
      }
      return ranks;
    } catch (_) {
      return const {};
    }
  }

  String _buildSafeFtsQuery(String query) {
    final tokens = query
        .replaceAll(RegExp(r'[^\p{L}\p{N}_]+', unicode: true), ' ')
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.length >= 2)
        .take(8)
        .map((w) => '"${w.replaceAll('"', '')}"*')
        .toList();
    return tokens.join(' OR ');
  }

  // ──────────────────────────────────────────────
  // Shared Workflow Memory CRUD
  // ──────────────────────────────────────────────

  Future<void> saveWorkflowMemory({
    required String workflowId,
    required String runId,
    required String key,
    required String value,
    String scope = 'workflow',
    required String createdBy,
  }) async {
    final db = await _ensureOpen();
    final now = DateTime.now().toIso8601String();
    db.execute(
      '''
      INSERT OR REPLACE INTO workflow_memory_store
        (workflow_id, run_id, memory_key, memory_value, scope, created_by, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ''',
      [workflowId, runId, key, value, scope, createdBy, now],
    );
  }

  Future<String?> getWorkflowMemory({
    required String workflowId,
    required String runId,
    required String key,
  }) async {
    final db = await _ensureOpen();
    final rs = db.select(
      '''
      SELECT memory_value FROM workflow_memory_store
      WHERE workflow_id = ? AND run_id = ? AND memory_key = ?
      ''',
      [workflowId, runId, key],
    );
    if (rs.isEmpty) return null;
    return rs.first['memory_value']?.toString();
  }

  Future<Map<String, String>> getAllWorkflowMemories({
    required String workflowId,
    required String runId,
  }) async {
    final db = await _ensureOpen();
    final rs = db.select(
      '''
      SELECT memory_key, memory_value FROM workflow_memory_store
      WHERE workflow_id = ? AND run_id = ?
      ORDER BY updated_at ASC
      ''',
      [workflowId, runId],
    );
    final map = <String, String>{};
    for (final row in rs) {
      final k = row['memory_key']?.toString();
      final v = row['memory_value']?.toString();
      if (k != null && v != null) map[k] = v;
    }
    return map;
  }

  Future<void> deleteWorkflowMemoriesForRun({
    required String workflowId,
    required String runId,
  }) async {
    final db = await _ensureOpen();
    db.execute(
      'DELETE FROM workflow_memory_store WHERE workflow_id = ? AND run_id = ?',
      [workflowId, runId],
    );
  }

  // ──────────────────────────────────────────────
  // Task CRUD
  // ──────────────────────────────────────────────

  Future<void> saveTask(
    String id,
    String name,
    bool enabled,
    String? agentId,
    List<String> tags,
    Map<String, dynamic> data,
  ) async {
    final db = await _ensureOpen();
    final now = DateTime.now().toIso8601String();
    final existing = db.select(
      'SELECT created_at FROM tasks WHERE id = ?',
      [id],
    );
    final createdAt = existing.isNotEmpty
        ? (existing.first['created_at']?.toString() ?? now)
        : now;

    db.execute(
      '''
      INSERT OR REPLACE INTO tasks
        (id, name, enabled, agent_id, tags, data, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        id,
        name,
        enabled ? 1 : 0,
        agentId,
        jsonEncode(tags),
        jsonEncode(data),
        createdAt,
        now,
      ],
    );
  }

  Future<Map<String, dynamic>?> getTask(String id) async {
    final db = await _ensureOpen();
    final rs = db.select('SELECT data FROM tasks WHERE id = ?', [id]);
    if (rs.isEmpty) return null;
    try {
      return _decodeJsonMap(rs.first['data']);
    } catch (e) {
      log.warning('[SQLite] getTask: invalid JSON payload for id=$id: $e');
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> getAllTasks({
    String? agentId,
    bool? enabledOnly,
  }) async {
    final db = await _ensureOpen();
    final conditions = <String>[];
    final args = <Object?>[];

    if (agentId != null) {
      conditions.add('agent_id = ?');
      args.add(agentId);
    }
    if (enabledOnly == true) {
      conditions.add('enabled = 1');
    }

    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';
    final rs = db.select(
      'SELECT data FROM tasks $where ORDER BY updated_at DESC',
      args,
    );
    final tasks = <Map<String, dynamic>>[];
    for (final row in rs) {
      try {
        tasks.add(_decodeJsonMap(row['data']));
      } catch (e) {
        log.warning('[SQLite] getAllTasks: skipped invalid task JSON row: $e');
      }
    }
    return tasks;
  }

  Future<List<Map<String, dynamic>>> getDueTasks() async {
    final db = await _ensureOpen();
    final now = DateTime.now().toIso8601String();
    final rs = db.select(
      '''
      SELECT data FROM tasks
      WHERE enabled = 1
        AND (json_extract(data, '\$.execution.next_run') IS NULL
             OR json_extract(data, '\$.execution.next_run') <= ?)
      ORDER BY updated_at DESC
      ''',
      [now],
    );
    final tasks = <Map<String, dynamic>>[];
    for (final row in rs) {
      try {
        tasks.add(_decodeJsonMap(row['data']));
      } catch (e) {
        log.warning('[SQLite] getDueTasks: skipped invalid task JSON row: $e');
      }
    }
    return tasks;
  }

  Future<List<Map<String, dynamic>>> getTasksByTag(String tag) async {
    final db = await _ensureOpen();
    final rs = db.select(
      '''
      SELECT data FROM tasks
      WHERE EXISTS (SELECT 1 FROM json_each(COALESCE(tags, '[]')) WHERE value = ?)
      ORDER BY updated_at DESC
      ''',
      [tag],
    );
    final tasks = <Map<String, dynamic>>[];
    for (final row in rs) {
      try {
        tasks.add(_decodeJsonMap(row['data']));
      } catch (_) {}
    }
    return tasks;
  }

  Future<void> deleteTask(String id) async {
    final db = await _ensureOpen();
    db.execute('DELETE FROM tasks WHERE id = ?', [id]);
    db.execute('DELETE FROM internal_mcp_configs WHERE task_id = ?', [id]);
  }

  Future<int> deleteTasksByAgent(String agentId) async {
    final db = await _ensureOpen();
    final rs = db.select('SELECT id FROM tasks WHERE agent_id = ?', [agentId]);
    final ids = rs.map((r) => r['id'].toString()).toList();
    if (ids.isEmpty) return 0;

    db.execute('DELETE FROM tasks WHERE agent_id = ?', [agentId]);
    for (final id in ids) {
      db.execute('DELETE FROM internal_mcp_configs WHERE task_id = ?', [id]);
    }
    return ids.length;
  }

  Future<List<Map<String, dynamic>>> searchTasks(String query) async {
    final db = await _ensureOpen();
    final pattern = '%${query.toLowerCase()}%';
    final rs = db.select(
      '''
      SELECT data FROM tasks
      WHERE LOWER(name) LIKE ?
         OR LOWER(COALESCE(json_extract(data, '\$.description'), '')) LIKE ?
         OR LOWER(COALESCE(json_extract(data, '\$.prompt'), '')) LIKE ?
      ORDER BY updated_at DESC
      ''',
      [pattern, pattern, pattern],
    );
    final tasks = <Map<String, dynamic>>[];
    for (final row in rs) {
      try {
        tasks.add(_decodeJsonMap(row['data']));
      } catch (_) {}
    }
    return tasks;
  }

  Future<int> countTasks({String? agentId}) async {
    final db = await _ensureOpen();
    final rs = agentId != null
        ? db.select(
            'SELECT COUNT(*) AS cnt FROM tasks WHERE agent_id = ?',
            [agentId],
          )
        : db.select('SELECT COUNT(*) AS cnt FROM tasks');
    return (rs.first['cnt'] as num?)?.toInt() ?? 0;
  }

  Future<void> updateExecution(
    String taskId,
    Map<String, dynamic> executionJson,
  ) async {
    final db = await _ensureOpen();
    final existing = await getTask(taskId);
    if (existing == null) return;

    final now = DateTime.now().toIso8601String();
    existing['execution'] = executionJson;
    existing['updated_at'] = now;

    db.execute(
      'UPDATE tasks SET data = ?, updated_at = ? WHERE id = ?',
      [jsonEncode(existing), now, taskId],
    );
  }

  Future<void> toggleTask(String taskId, bool enabled) async {
    final db = await _ensureOpen();
    final existing = await getTask(taskId);
    if (existing == null) return;

    final now = DateTime.now().toIso8601String();
    existing['enabled'] = enabled;
    existing['updated_at'] = now;

    db.execute(
      'UPDATE tasks SET enabled = ?, data = ?, updated_at = ? WHERE id = ?',
      [enabled ? 1 : 0, jsonEncode(existing), now, taskId],
    );
  }

  // ──────────────────────────────────────────────
  // Internal MCP Config CRUD
  // ──────────────────────────────────────────────

  Future<void> saveInternalMcpConfig(
    String id,
    String taskId,
    String mcpType,
    Map<String, dynamic> params,
    bool enabled,
  ) async {
    final db = await _ensureOpen();
    final now = DateTime.now().toIso8601String();
    db.execute(
      '''
      INSERT OR REPLACE INTO internal_mcp_configs
        (id, task_id, mcp_type, params, enabled, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ''',
      [id, taskId, mcpType, jsonEncode(params), enabled ? 1 : 0, now, now],
    );
  }

  Future<List<Map<String, dynamic>>> getInternalMcpConfigs(
    String taskId,
  ) async {
    final db = await _ensureOpen();
    final rs = db.select(
      '''
      SELECT id, mcp_type, params, enabled FROM internal_mcp_configs
      WHERE task_id = ?
      ORDER BY mcp_type ASC
      ''',
      [taskId],
    );
    return rs.map((r) {
      return {
        'id': r['id'].toString(),
        'mcp_type': r['mcp_type'].toString(),
        'params': _decodeJsonMapSafe(r['params']),
        'enabled': _toBool(r['enabled'], defaultValue: true),
      };
    }).toList();
  }

  Future<void> deleteInternalMcpConfig(String id) async {
    final db = await _ensureOpen();
    db.execute('DELETE FROM internal_mcp_configs WHERE id = ?', [id]);
  }

  // ──────────────────────────────────────────────
  // Python Tool CRUD
  // ──────────────────────────────────────────────

  Future<void> savePyTool(dynamic def) async {
    final db = await _ensureOpen();
    final now = DateTime.now().toIso8601String();
    db.execute(
      '''
      INSERT OR REPLACE INTO py_tools
        (id, name, description, input_schema, code, requirements,
         venv_ready, is_active, generation_prompt, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        def.id as String,
        def.name as String,
        def.description as String? ?? '',
        jsonEncode(def.inputSchema),
        def.code as String? ?? '',
        def.requirements as String? ?? '',
        _toBool(def.venvReady) ? 1 : 0,
        _toBool(def.isActive, defaultValue: true) ? 1 : 0,
        def.generationPrompt as String? ?? '',
        now,
        now,
      ],
    );
  }

  Future<List<Map<String, dynamic>>> getAllPyTools() async {
    final db = await _ensureOpen();
    final rs = db.select('''
      SELECT id, name, description, input_schema, code, requirements,
             venv_ready, is_active, generation_prompt, created_at, updated_at
      FROM py_tools
      ORDER BY updated_at DESC
    ''');
    return rs.map((r) {
      return {
        'id': r['id'].toString(),
        'name': r['name'].toString(),
        'description': r['description']?.toString() ?? '',
        'inputSchema': _decodeJsonMapSafe(r['input_schema']),
        'code': r['code']?.toString() ?? '',
        'requirements': r['requirements']?.toString() ?? '',
        'venvReady': _toBool(r['venv_ready']),
        'isActive': _toBool(r['is_active'], defaultValue: true),
        'generationPrompt': r['generation_prompt']?.toString() ?? '',
        'createdAt': r['created_at']?.toString() ?? '',
        'updatedAt': r['updated_at']?.toString() ?? '',
      };
    }).toList();
  }

  Future<void> deletePyTool(String id) async {
    final db = await _ensureOpen();
    db.execute('DELETE FROM py_tools WHERE id = ?', [id]);
  }

  // ──────────────────────────────────────────────
  // GitHub MCP Server CRUD
  // ──────────────────────────────────────────────

  Future<void> saveGithubMcpServer(Map<String, dynamic> def) async {
    final db = await _ensureOpen();
    final id = def['id'] as String;
    final name = def['name'] as String;
    final displayName = def['displayName'] as String? ?? name;
    final description = def['description'] as String? ?? '';
    final githubUrl = def['githubUrl'] as String? ?? '';
    final language = def['language'] as String? ?? 'python';
    final installType = def['installType'] as String? ?? 'uvx';
    final packageName = def['packageName'] as String;
    final entryPoint = def['entryPoint'] as String?;
    final launchArgs = jsonEncode(def['launchArgs'] ?? const []);
    final requiredEnvVars = jsonEncode(def['requiredEnvVars'] ?? const []);
    final envVars = jsonEncode(def['envVars'] ?? const <String, dynamic>{});
    final category = def['category'] as String? ?? 'other';
    final isInstalled = _toBool(def['isInstalled']) ? 1 : 0;
    final isActive = _toBool(def['isActive']) ? 1 : 0;
    final isManual = _toBool(def['isManual']) ? 1 : 0;
    final installedAt = def['installedAt']?.toString();
    final createdAt =
        def['createdAt'] as String? ?? DateTime.now().toIso8601String();

    db.execute(
      '''
      INSERT OR REPLACE INTO github_mcp_servers
        (id, name, display_name, description, github_url, language, install_type,
         package_name, entry_point, launch_args, required_env_vars, env_vars,
         category, is_installed, is_active, is_manual, installed_at, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        id,
        name,
        displayName,
        description,
        githubUrl,
        language,
        installType,
        packageName,
        entryPoint,
        launchArgs,
        requiredEnvVars,
        envVars,
        category,
        isInstalled,
        isActive,
        isManual,
        installedAt,
        createdAt,
      ],
    );
  }

  Future<List<Map<String, dynamic>>> getAllGithubMcpServers() async {
    final db = await _ensureOpen();
    final rs = db.select('''
      SELECT id, name, display_name, description, github_url, language, install_type,
             package_name, entry_point, launch_args, required_env_vars, env_vars,
             category, is_installed, is_active, is_manual, installed_at, created_at
      FROM github_mcp_servers
      ORDER BY display_name ASC
    ''');
    return rs.map((r) {
      return {
        'id': r['id'].toString(),
        'name': r['name'].toString(),
        'displayName': r['display_name'].toString(),
        'description': r['description']?.toString() ?? '',
        'githubUrl': r['github_url']?.toString() ?? '',
        'language': r['language']?.toString() ?? 'python',
        'installType': r['install_type']?.toString() ?? 'uvx',
        'packageName': r['package_name'].toString(),
        'entryPoint': r['entry_point']?.toString(),
        'launchArgs': _decodeJsonList(r['launch_args']),
        'requiredEnvVars': _decodeJsonList(r['required_env_vars']),
        'envVars': _decodeJsonMapSafe(r['env_vars']),
        'category': r['category']?.toString() ?? 'other',
        'isInstalled': _toBool(r['is_installed']),
        'isActive': _toBool(r['is_active']),
        'isManual': _toBool(r['is_manual']),
        'installedAt': r['installed_at']?.toString(),
        'createdAt':
            r['created_at']?.toString() ?? DateTime.now().toIso8601String(),
      };
    }).toList();
  }

  Future<void> deleteGithubMcpServer(String id) async {
    final db = await _ensureOpen();
    db.execute('DELETE FROM github_mcp_servers WHERE id = ?', [id]);
  }

  // ──────────────────────────────────────────────
  // Bulk / Export
  // ──────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> exportTasks() async {
    final db = await _ensureOpen();
    final rs = db.select('SELECT data FROM tasks ORDER BY name');
    final tasks = <Map<String, dynamic>>[];
    for (final row in rs) {
      try {
        tasks.add(_decodeJsonMap(row['data']));
      } catch (_) {}
    }
    return tasks;
  }

  Future<int> importTasks(List<Map<String, dynamic>> tasksJson) async {
    int count = 0;
    for (final json in tasksJson) {
      final id = json['id'] as String;
      final name = json['name'] as String;
      final enabled = _toBool(json['enabled'], defaultValue: true);
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

  Future<void> execute(String sql, [List<Object?> parameters = const []]) async {
    final db = await _ensureOpen();
    db.execute(sql, parameters);
  }

  Future<List<List<dynamic>>> query(
    String sql, [
    List<Object?> parameters = const [],
  ]) async {
    final db = await _ensureOpen();
    final rs = db.select(sql, parameters);
    return rs.rows;
  }

  // ──────────────────────────────────────────────
  // Skill Definitions CRUD (`skill_defs`)
  // ──────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getAllSkillDefMaps() async {
    final db = await _ensureOpen();
    final rs = db.select(
      'SELECT id, name, goal, description, skill_def, tool_names, created_at, updated_at '
      'FROM skill_defs ORDER BY updated_at DESC',
    );
    return rs.map(_rowToSkillDefMap).toList();
  }

  Future<Map<String, dynamic>?> getSkillDefMap(String id) async {
    final db = await _ensureOpen();
    final rs = db.select(
      'SELECT id, name, goal, description, skill_def, tool_names, created_at, updated_at '
      'FROM skill_defs WHERE id = ?',
      [id],
    );
    if (rs.isEmpty) return null;
    return _rowToSkillDefMap(rs.first);
  }

  Future<void> saveSkillDefMap({
    required String id,
    required String name,
    required String goal,
    required String description,
    required String skillDef,
    required List<String> toolNames,
    String? createdAt,
    String? updatedAt,
  }) async {
    final db = await _ensureOpen();
    final now = DateTime.now().toUtc().toIso8601String();
    final existing = db.select(
      'SELECT created_at FROM skill_defs WHERE id = ?',
      [id],
    );
    final effectiveCreated = createdAt ??
        (existing.isNotEmpty
            ? existing.first['created_at']?.toString()
            : null) ??
        now;
    db.execute(
      '''
      INSERT OR REPLACE INTO skill_defs
        (id, name, goal, description, skill_def, tool_names, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        id,
        name,
        goal,
        description,
        skillDef,
        jsonEncode(toolNames),
        effectiveCreated,
        updatedAt ?? now,
      ],
    );
  }

  Future<void> deleteSkillDef(String id) async {
    final db = await _ensureOpen();
    db.execute('DELETE FROM skill_defs WHERE id = ?', [id]);
  }

  Map<String, dynamic> _rowToSkillDefMap(Row r) => {
    'id': r['id'].toString(),
    'name': r['name']?.toString() ?? '',
    'goal': r['goal']?.toString() ?? '',
    'description': r['description']?.toString() ?? '',
    'skill_def': r['skill_def']?.toString() ?? '',
    'tool_names': _decodeJsonList(r['tool_names'])
        .map((e) => e.toString())
        .toList(),
    'created_at':
        r['created_at']?.toString() ?? DateTime.now().toUtc().toIso8601String(),
    'updated_at':
        r['updated_at']?.toString() ?? DateTime.now().toUtc().toIso8601String(),
  };

  // ──────────────────────────────────────────────
  // Tool Hints CRUD (`tool_skills`)
  // ──────────────────────────────────────────────

  Future<void> saveToolSkill({
    required String id,
    required String toolName,
    required String mcpType,
    required String skillText,
    required String skillTextSlm,
    required bool isEnabled,
    required bool isCustom,
  }) async {
    final db = await _ensureOpen();
    final now = DateTime.now().toIso8601String();
    db.execute(
      '''
      INSERT OR REPLACE INTO tool_skills
        (id, tool_name, mcp_type, skill_text, skill_text_slm,
         is_enabled, is_custom, generated_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        id,
        toolName,
        mcpType,
        skillText,
        skillTextSlm,
        isEnabled ? 1 : 0,
        isCustom ? 1 : 0,
        now,
        now,
      ],
    );
  }

  Future<List<Map<String, dynamic>>> getAllToolSkills({String? mcpType}) async {
    final db = await _ensureOpen();
    final rs = mcpType != null
        ? db.select(
            'SELECT id, tool_name, mcp_type, skill_text, skill_text_slm, '
            'is_enabled, is_custom, generated_at, updated_at '
            'FROM tool_skills WHERE mcp_type = ? ORDER BY mcp_type, tool_name',
            [mcpType],
          )
        : db.select(
            'SELECT id, tool_name, mcp_type, skill_text, skill_text_slm, '
            'is_enabled, is_custom, generated_at, updated_at '
            'FROM tool_skills ORDER BY mcp_type, tool_name',
          );
    return rs.map(_rowToToolSkillMap).toList();
  }

  Future<List<Map<String, dynamic>>> getEnabledSkillsForTools(
    List<String> toolNames,
  ) async {
    if (toolNames.isEmpty) return [];
    final db = await _ensureOpen();
    final placeholders = List.filled(toolNames.length, '?').join(', ');
    final rs = db.select(
      'SELECT id, tool_name, mcp_type, skill_text, skill_text_slm, '
      'is_enabled, is_custom, generated_at, updated_at '
      'FROM tool_skills WHERE is_enabled = 1 AND tool_name IN ($placeholders)',
      toolNames,
    );
    return rs.map(_rowToToolSkillMap).toList();
  }

  Future<Set<String>> getToolNamesWithSkills() async {
    final db = await _ensureOpen();
    final rs = db.select('SELECT tool_name FROM tool_skills');
    return rs.map((r) => r['tool_name'].toString()).toSet();
  }

  Map<String, dynamic> _rowToToolSkillMap(Row r) => {
    'id': r['id'].toString(),
    'tool_name': r['tool_name'].toString(),
    'mcp_type': r['mcp_type'].toString(),
    'skill_text': r['skill_text']?.toString() ?? '',
    'skill_text_slm': r['skill_text_slm']?.toString() ?? '',
    'is_enabled': _toBool(r['is_enabled'], defaultValue: true),
    'is_custom': _toBool(r['is_custom']),
    'generated_at': r['generated_at']?.toString() ?? '',
    'updated_at': r['updated_at']?.toString() ?? '',
  };

  Future<void> deleteToolSkill(String id) async {
    final db = await _ensureOpen();
    db.execute('DELETE FROM tool_skills WHERE id = ?', [id]);
  }

  Future<void> deleteToolSkillsByToolName(String toolName) async {
    final db = await _ensureOpen();
    db.execute('DELETE FROM tool_skills WHERE tool_name = ?', [toolName]);
  }

  // ──────────────────────────────────────────────
  // Subagent Definitions CRUD
  // ──────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getSubagentDefinitions() async {
    final db = await _ensureOpen();
    final rs = db.select(
      'SELECT key, name, description, model, system_prompt, tools_json, '
      'max_turns, created_at, updated_at FROM subagent_definitions ORDER BY key',
    );
    return rs.map((r) {
      final tools = _decodeJsonList(r['tools_json'])
          .map((e) => e.toString())
          .toList();
      return {
        'key': r['key'].toString(),
        'name': r['name']?.toString() ?? '',
        'description': r['description']?.toString() ?? '',
        'model': r['model']?.toString() ?? 'default',
        'system_prompt': r['system_prompt']?.toString() ?? '',
        'tools': tools,
        'max_turns': (r['max_turns'] as num?)?.toInt() ?? 8,
        'created_at': r['created_at']?.toString(),
        'updated_at': r['updated_at']?.toString(),
      };
    }).toList();
  }

  Future<void> saveSubagentDefinition(Map<String, dynamic> data) async {
    final db = await _ensureOpen();
    final key = data['key']?.toString().trim() ?? '';
    final name = data['name']?.toString().trim() ?? '';
    final desc = data['description']?.toString().trim() ?? '';
    final model = data['model']?.toString().trim() ?? 'default';
    final prompt = data['system_prompt']?.toString() ?? '';
    final toolsList = (data['tools'] as List?)
            ?.map((t) => t.toString().trim())
            .where((s) => s.isNotEmpty)
            .toList() ??
        [];
    final maxTurns = (data['max_turns'] as num?)?.toInt() ?? 8;
    final now = DateTime.now().toIso8601String();

    db.execute(
      '''
      INSERT OR REPLACE INTO subagent_definitions
        (key, name, description, model, system_prompt, tools_json,
         max_turns, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [key, name, desc, model, prompt, jsonEncode(toolsList), maxTurns, now, now],
    );
  }

  Future<void> deleteSubagentDefinition(String key) async {
    final db = await _ensureOpen();
    db.execute('DELETE FROM subagent_definitions WHERE key = ?', [key]);
  }

  // ──────────────────────────────────────────────
  // Helpers & Legacy Task Structure Migration
  // ──────────────────────────────────────────────

  bool _toBool(Object? v, {bool defaultValue = false}) {
    if (v == null) return defaultValue;
    if (v is bool) return v;
    if (v is int) return v != 0;
    if (v is String) {
      final lower = v.toLowerCase();
      if (lower == 'true' || lower == '1') return true;
      if (lower == 'false' || lower == '0') return false;
    }
    return defaultValue;
  }

  List<dynamic> _decodeJsonList(dynamic raw) {
    if (raw == null) return [];
    if (raw is List) return raw;
    if (raw is String && raw.isNotEmpty) {
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
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return {};
  }

  Map<String, dynamic> _decodeJsonMap(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is String) {
      final decoded = jsonDecode(raw.trim());
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      throw const FormatException('JSON value is not an object');
    }
    throw FormatException('Unsupported JSON payload type: ${raw.runtimeType}');
  }

  Future<void> _migrateTasksToOrchestratorPattern() async {
    final db = _requireDb;
    try {
      final rows = db.select('SELECT id, data FROM tasks');
      final Map<String, Map<String, dynamic>> allTasks = {};
      for (final row in rows) {
        final id = row['id'] as String;
        allTasks[id] = _decodeJsonMap(row['data']);
      }

      final Set<String> tasksToDelete = {};

      for (final id in allTasks.keys) {
        final data = allTasks[id]!;
        bool modified = false;

        if ((!data.containsKey('agents') && !data.containsKey('executors')) ||
            ((data['agents'] ?? data['executors']) as List?) == null ||
            ((data['agents'] ?? data['executors']) as List).isEmpty) {
          if ((data['prompt'] as String? ?? '').isNotEmpty) {
            final task = WorkflowTask.fromJson(data);
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
            final rootTask = WorkflowTask.fromJson(currentData);
            final List<Agent> agents = List.from(rootTask.agents);
            final List<Edge> edges = List.from(rootTask.edges);
            String currentSourceId = agents.isNotEmpty ? agents.first.id : id;
            String? currentNextId = chainConfig['on_match_task_id'] as String?;
            String? currentCondition =
                chainConfig['trigger_condition'] as String?;

            while (currentNextId != null &&
                allTasks.containsKey(currentNextId)) {
              final childTask = WorkflowTask.fromJson(allTasks[currentNextId]!);
              final newExecutorId = const Uuid().v4();
              agents.add(
                Agent(
                  id: newExecutorId,
                  name: childTask.name.isNotEmpty
                      ? childTask.name
                      : 'Agent ${agents.length + 1}',
                  systemPrompt: childTask.systemPrompt,
                  prompt: childTask.prompt,
                  llmConfig: childTask.llmConfig,
                  mcpTools: childTask.mcpTools,
                  internalMcps: childTask.internalMcps,
                  chatMode: childTask.chatMode,
                  stopAfterToolCall: childTask.stopAfterToolCall,
                ),
              );
              edges.add(
                Edge(
                  id: const Uuid().v4(),
                  sourceAgentId: currentSourceId,
                  variable: 'task_result',
                  operator: 'contains',
                  value: currentCondition ?? '',
                  targetAgentId: newExecutorId,
                ),
              );
              tasksToDelete.add(currentNextId);
              currentSourceId = newExecutorId;
              final childChain = childTask.chainConfig;
              currentNextId = childChain?.onMatchTaskId;
              currentCondition = childChain?.triggerCondition;
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
          final now = DateTime.now().toIso8601String();
          db.execute(
            'UPDATE tasks SET data = ?, updated_at = ? WHERE id = ?',
            [jsonEncode(allTasks[id]!), now, id],
          );
        }
      }

      for (final delId in tasksToDelete) {
        db.execute('DELETE FROM tasks WHERE id = ?', [delId]);
      }
    } catch (e) {
      log.warning('[SQLite] Failed to run orchestrator task migration: $e');
    }
  }
}
