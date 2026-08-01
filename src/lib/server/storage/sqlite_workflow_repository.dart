import 'dart:convert';
import 'package:sqlite3/sqlite3.dart';

/// Lightweight SQLite Repository for storing and retrieving TealKit Workflows and execution logs.
class SqliteWorkflowRepository {
  final Database db;

  SqliteWorkflowRepository(this.db) {
    _initTables();
  }

  /// Open or create an SQLite database file.
  factory SqliteWorkflowRepository.open(String path) {
    final database = sqlite3.open(path);
    // Enable Write-Ahead Logging (WAL) mode for better concurrency and fast non-blocking writes
    database.execute('PRAGMA journal_mode = WAL;');
    return SqliteWorkflowRepository(database);
  }

  void _initTables() {
    db.execute('''
      CREATE TABLE IF NOT EXISTS workflows (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        definition TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS workflow_runs (
        id TEXT PRIMARY KEY,
        workflow_id TEXT NOT NULL,
        status TEXT NOT NULL,
        input_data TEXT,
        output_data TEXT,
        started_at INTEGER NOT NULL,
        finished_at INTEGER,
        FOREIGN KEY(workflow_id) REFERENCES workflows(id) ON DELETE CASCADE
      );
    ''');
  }

  /// Save or update a workflow.
  void saveWorkflow(String id, String name, Map<String, dynamic> definition) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final stmt = db.prepare('''
      INSERT INTO workflows (id, name, definition, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        name = excluded.name,
        definition = excluded.definition,
        updated_at = excluded.updated_at;
    ''');
    stmt.execute([id, name, jsonEncode(definition), now, now]);
    stmt.dispose();
  }

  /// Retrieve a workflow definition by ID.
  Map<String, dynamic>? getWorkflow(String id) {
    final ResultSet results = db.select('SELECT id, name, definition FROM workflows WHERE id = ?;', [id]);
    if (results.isEmpty) return null;
    final row = results.first;
    return {
      'id': row['id'],
      'name': row['name'],
      'definition': jsonDecode(row['definition'] as String),
    };
  }

  /// List all saved workflows.
  List<Map<String, dynamic>> listWorkflows() {
    final ResultSet results = db.select('SELECT id, name, updated_at FROM workflows ORDER BY updated_at DESC;');
    return results.map((row) => {
      'id': row['id'],
      'name': row['name'],
      'updated_at': row['updated_at'],
    }).toList();
  }

  /// Record initial workflow run.
  void recordRunStart(String runId, String workflowId, Map<String, dynamic>? input) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final stmt = db.prepare('''
      INSERT INTO workflow_runs (id, workflow_id, status, input_data, started_at)
      VALUES (?, ?, 'running', ?, ?);
    ''');
    stmt.execute([runId, workflowId, input != null ? jsonEncode(input) : null, now]);
    stmt.dispose();
  }

  /// Record workflow run completion.
  void recordRunFinish(String runId, String status, Map<String, dynamic>? output) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final stmt = db.prepare('''
      UPDATE workflow_runs
      SET status = ?, output_data = ?, finished_at = ?
      WHERE id = ?;
    ''');
    stmt.execute([status, output != null ? jsonEncode(output) : null, now, runId]);
    stmt.dispose();
  }

  /// Close SQLite database connection.
  void dispose() {
    db.dispose();
  }
}
