import 'dart:convert';
import 'dart:io';

import 'package:dart_duckdb/dart_duckdb.dart' as ddb;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite_vector/sqlite_vector.dart';
import 'package:test/test.dart';

import 'package:tealkit_server/database/server_legacy_duckdb_migrator.dart';
import 'package:tealkit_server/database/server_sqlite_adapter.dart';
import 'package:tealkit_server/utils/semantic_embedding.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tealkit_srv_sqlite_test_');
  });

  tearDown(() async {
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  test(
    'ServerSqliteAdapter.full silently migrates tealkit_server.duckdb (including llm_profiles & tasks) and supports sqlite_vector + FTS5',
    () async {
      bool vectorLoaded = false;
      try {
        sqlite3.loadSqliteVectorExtension();
        vectorLoaded = true;
      } catch (_) {}
      expect(vectorLoaded, isTrue);

      final dbDir = p.join(tempDir.path, 'db');
      await Directory(dbDir).create(recursive: true);
      final duckPath = p.join(dbDir, 'tealkit_server.duckdb');

      // 1. Seed a legacy server DuckDB file
      ServerLegacyDuckDbMigrator.configureDuckDbLibrary();
      final duckDb = await ddb.duckdb.open(duckPath);
      final conn = await ddb.duckdb.connect(duckDb);

      await conn.execute('''
        CREATE TABLE llm_profiles (
          id VARCHAR PRIMARY KEY,
          name VARCHAR NOT NULL,
          is_selected BOOLEAN DEFAULT FALSE,
          data JSON NOT NULL,
          sort_order INTEGER DEFAULT 0,
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
          updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
      ''');
      final profileJson = jsonEncode({
        'id': 'prof-1',
        'name': 'DeepInfra Qwen',
        'provider': 'openai_compatible',
        'model': 'Qwen/Qwen3-32B',
        'base_url': 'https://api.deepinfra.com/v1/openai',
      }).replaceAll("'", "''");
      await conn.execute('''
        INSERT INTO llm_profiles (id, name, is_selected, data, sort_order)
        VALUES ('prof-1', 'DeepInfra Qwen', true, '$profileJson', 0);
      ''');

      await conn.execute('''
        CREATE TABLE tasks (
          id VARCHAR PRIMARY KEY,
          name VARCHAR NOT NULL,
          enabled BOOLEAN DEFAULT TRUE,
          agent_id VARCHAR,
          tags VARCHAR[],
          data JSON NOT NULL,
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
          updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
      ''');
      final taskJson = jsonEncode({
        'id': 'srv-task-1',
        'name': 'Server Digest',
        'description': 'Hourly server digest',
        'enabled': true,
        'tags': ['digest'],
        'created_at': '2026-11-18T10:00:00.000Z',
        'updated_at': '2026-11-18T10:00:00.000Z',
        'execution_plan': {'cron_expression': '0 * * * *'},
        'agents': [],
      }).replaceAll("'", "''");
      await conn.execute('''
        INSERT INTO tasks (id, name, enabled, tags, data)
        VALUES ('srv-task-1', 'Server Digest', true, ['digest'], '$taskJson');
      ''');

      await conn.execute('''
        CREATE TABLE skill_defs (
          id VARCHAR PRIMARY KEY,
          name VARCHAR NOT NULL,
          goal VARCHAR DEFAULT '',
          description VARCHAR DEFAULT '',
          skill_def TEXT NOT NULL,
          tool_names VARCHAR[],
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
          updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
      ''');
      await conn.execute('''
        INSERT INTO skill_defs (id, name, goal, description, skill_def, tool_names)
        VALUES ('srv-skill-1', 'deploy-check', 'Verify deploy', 'Checks health', '# Deploy Check', ['fetch']);
      ''');

      await conn.execute('''
        CREATE TABLE document_index (
          id VARCHAR PRIMARY KEY,
          file_path VARCHAR NOT NULL,
          content_text TEXT
        );
      ''');
      await conn.execute('''
        INSERT INTO document_index (id, file_path, content_text)
        VALUES ('old-doc-1', '/data/readme.md', 'Legacy DuckDB doc index row');
      ''');

      await conn.dispose();
      await duckDb.dispose();

      // 2. Initialize ServerSqliteAdapter.full with silent migration hook
      ServerSqliteAdapter.legacyMigratorHook =
          ServerLegacyDuckDbMigrator.migrateIfNeeded;
      final adapter = ServerSqliteAdapter.full(
        customDataDir: tempDir.path,
        vectorExtensionLoaded: vectorLoaded,
      );
      await adapter.init();

      try {
        expect(adapter.isVectorInitialized, isTrue);
        expect(await File(duckPath).exists(), isFalse);
        expect(await File('$duckPath.migrated.bak').exists(), isTrue);

        // Verify llm_profiles migrated silently
        final profiles = await adapter.getLlmProfiles();
        expect(profiles.length, 1);
        expect(profiles.first['name'], 'DeepInfra Qwen');
        expect(await adapter.getSelectedLlmProfileId(), 'prof-1');

        // Verify tasks & skills migrated silently
        final tasks = await adapter.getAllTasks();
        expect(tasks.length, 1);
        expect(tasks.first.name, 'Server Digest');

        final skills = await adapter.getAllSkillDefs();
        expect(skills.length, 1);
        expect(skills.first['name'], 'deploy-check');

        // Verify document_index was skipped during migration
        final countRows = await adapter.query('SELECT COUNT(*) FROM document_index');
        expect((countRows.first.first as num).toInt(), 0);

        // 3. Verify sqlite_vector + FTS5 on server adapter
        final nowIso = DateTime.utc(2026, 11, 18).toIso8601String();
        const docText =
            'Headless TealKit Server runs SQLite with sqlite_vector and FTS5 hybrid search.';
        await adapter.upsertDocumentIndex(
          id: 'srv-doc-1',
          rootPath: '/data/docs',
          filePath: '/data/docs/architecture.md',
          fileName: 'architecture.md',
          fileType: 'md',
          contentText: docText,
          embedding: SemanticEmbedding.buildEmbedding(docText),
          fileSize: 256,
          lastModified: nowIso,
          indexedAt: nowIso,
        );

        final vecHits = await adapter.vectorSearchDocuments(
          queryEmbedding: SemanticEmbedding.buildEmbedding(
            'sqlite_vector hybrid search on TealKit Server',
          ),
          k: 5,
        );
        expect(vecHits.length, 1);
        expect(vecHits.first['file_path'], '/data/docs/architecture.md');

        final ftsRanks = await adapter.ftsRankDocuments('FTS5 hybrid');
        expect(ftsRanks, contains('/data/docs/architecture.md'));
      } finally {
        await adapter.close();
      }
    },
  );
}
