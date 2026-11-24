import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite_vector/sqlite_vector.dart';
import 'package:test/test.dart';

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
    'ServerSqliteAdapter.full supports sqlite_vector + FTS5 hybrid search',
    () async {
      bool vectorLoaded = false;
      try {
        sqlite3.loadSqliteVectorExtension();
        vectorLoaded = true;
      } catch (_) {}
      expect(vectorLoaded, isTrue);

      final adapter = ServerSqliteAdapter.full(
        customDataDir: tempDir.path,
        vectorExtensionLoaded: vectorLoaded,
      );
      await adapter.init();

      try {
        expect(adapter.isVectorInitialized, isTrue);

        // Verify sqlite_vector + FTS5 on server adapter
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
