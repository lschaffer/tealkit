import 'dart:ffi';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart' as sqlite_open;
import 'package:sqlite3/sqlite3.dart';

/// Represents a scored chunk retrieved from search.
class ScoredChunk {
  final String chunkId;
  final String documentId;
  final String documentUri;
  final String? documentTitle;
  final int? chunkIndex;
  final int? lineStart;
  final int? lineEnd;
  final String content;
  final double score;
  final String matchType; // 'bm25', 'vector', 'hybrid'

  ScoredChunk({
    required this.chunkId,
    required this.documentId,
    required this.documentUri,
    this.documentTitle,
    this.chunkIndex,
    this.lineStart,
    this.lineEnd,
    required this.content,
    required this.score,
    required this.matchType,
  });

  /// Formatted clickable link or file URI with line anchor (e.g. file:///C:/path/file.txt#L42)
  String get clickableLink {
    if (documentUri.startsWith('http://') || documentUri.startsWith('https://')) {
      return documentUri;
    }
    final fileUri = Uri.file(documentUri).toString();
    if (lineStart != null && lineStart! > 0) {
      return '$fileUri#L$lineStart';
    }
    return fileUri;
  }

  /// Terminal-friendly clickable location format recognized by VS Code / Windows Terminal (e.g. C:\path\file.txt:42)
  String get terminalLocation {
    if (documentUri.startsWith('http://') || documentUri.startsWith('https://')) {
      return documentUri;
    }
    final norm = p.normalize(documentUri);
    if (lineStart != null && lineStart! > 0) {
      return '$norm:$lineStart';
    }
    return norm;
  }

  /// Human-friendly line or chunk label
  String get locationLabel {
    if (lineStart != null && lineEnd != null) {
      if (lineStart == lineEnd) return 'Line $lineStart';
      return 'Lines $lineStart-$lineEnd';
    }
    return 'Chunk #${(chunkIndex ?? 0) + 1}';
  }
}

/// Local SQLite database management for RAG documents, chunks, and FTS5 index.
class RagDatabase {
  final String databasePath;
  Database? _db;
  static bool _sqliteOverrideRegistered = false;

  RagDatabase(this.databasePath);

  /// Initializes the SQLite library bindings and opens the database connection.
  void open() {
    if (_db != null) return;

    _ensureSqliteDynamicLibrary();

    // Ensure parent directory exists (even on network UNC paths like \\server\share\dir)
    final dbFile = File(databasePath);
    if (!dbFile.parent.existsSync()) {
      try {
        dbFile.parent.createSync(recursive: true);
      } catch (_) {}
    }

    _db = sqlite3.open(databasePath);
    _initSchema();
  }

  static void _ensureSqliteDynamicLibrary() {
    if (_sqliteOverrideRegistered) return;
    _sqliteOverrideRegistered = true;

    if (Platform.isWindows) {
      sqlite_open.open.overrideFor(sqlite_open.OperatingSystem.windows, () {
        // 1. Check beside executable
        final exeDir = File(Platform.resolvedExecutable).parent.path;
        final localSqlite = p.join(exeDir, 'sqlite3.dll');
        if (File(localSqlite).existsSync()) {
          try {
            return DynamicLibrary.open(localSqlite);
          } catch (_) {}
        }

        // 2. Check current working directory
        final cwdSqlite = p.join(Directory.current.path, 'sqlite3.dll');
        if (File(cwdSqlite).existsSync()) {
          try {
            return DynamicLibrary.open(cwdSqlite);
          } catch (_) {}
        }

        // 3. System winsqlite3.dll (available on all Windows 10/11)
        try {
          return DynamicLibrary.open('winsqlite3.dll');
        } catch (_) {}

        // 4. Default sqlite3.dll in PATH
        return DynamicLibrary.open('sqlite3.dll');
      });
    }
  }

  void _initSchema() {
    final db = _db!;

    db.execute('PRAGMA journal_mode = WAL;');
    db.execute('PRAGMA synchronous = NORMAL;');

    db.execute('''
      CREATE TABLE IF NOT EXISTS rag_documents (
        id TEXT PRIMARY KEY,
        source_type TEXT NOT NULL,
        uri TEXT NOT NULL UNIQUE,
        title TEXT,
        content_hash TEXT NOT NULL,
        file_size INTEGER,
        last_modified INTEGER,
        chunk_count INTEGER DEFAULT 0,
        indexed_at INTEGER NOT NULL
      );
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS rag_chunks (
        id TEXT PRIMARY KEY,
        document_id TEXT NOT NULL REFERENCES rag_documents(id) ON DELETE CASCADE,
        chunk_index INTEGER NOT NULL,
        content TEXT NOT NULL,
        token_count INTEGER DEFAULT 0,
        line_start INTEGER,
        line_end INTEGER,
        embedding BLOB,
        FOREIGN KEY(document_id) REFERENCES rag_documents(id)
      );
    ''');

    // Schema migrations for backward compatibility
    try {
      db.execute('ALTER TABLE rag_chunks ADD COLUMN line_start INTEGER;');
    } catch (_) {}
    try {
      db.execute('ALTER TABLE rag_chunks ADD COLUMN line_end INTEGER;');
    } catch (_) {}

    db.execute('CREATE INDEX IF NOT EXISTS idx_chunks_doc ON rag_chunks(document_id);');

    // FTS5 Virtual Table for BM25 keyword search
    try {
      db.execute('''
        CREATE VIRTUAL TABLE IF NOT EXISTS rag_chunks_fts USING fts5(
          chunk_id UNINDEXED,
          document_id UNINDEXED,
          content,
          tokenize = 'porter unicode61'
        );
      ''');
    } catch (_) {}
  }

  /// Retrieves an existing indexed document by URI.
  Map<String, dynamic>? getDocumentByUri(String uri) {
    final res = _db!.select(
      'SELECT id, source_type, uri, title, content_hash, file_size, last_modified, chunk_count, indexed_at FROM rag_documents WHERE uri = ?',
      [uri],
    );
    if (res.isEmpty) return null;
    final row = res.first;
    return {
      'id': row['id'],
      'source_type': row['source_type'],
      'uri': row['uri'],
      'title': row['title'],
      'content_hash': row['content_hash'],
      'file_size': row['file_size'],
      'last_modified': row['last_modified'],
      'chunk_count': row['chunk_count'],
      'indexed_at': row['indexed_at'],
    };
  }

  /// Deletes a document and its associated chunks from both tables.
  void deleteDocument(String documentId) {
    _db!.execute('BEGIN TRANSACTION;');
    try {
      try {
        _db!.execute('DELETE FROM rag_chunks_fts WHERE document_id = ?', [documentId]);
      } catch (_) {}
      _db!.execute('DELETE FROM rag_chunks WHERE document_id = ?', [documentId]);
      _db!.execute('DELETE FROM rag_documents WHERE id = ?', [documentId]);
      _db!.execute('COMMIT;');
    } catch (e) {
      _db!.execute('ROLLBACK;');
      rethrow;
    }
  }

  /// Inserts a new document record and its chunks inside a transaction.
  void saveDocumentWithChunks({
    required String documentId,
    required String sourceType,
    required String uri,
    required String? title,
    required String contentHash,
    required int fileSize,
    required int lastModified,
    required List<Map<String, dynamic>> chunks,
  }) {
    deleteDocument(documentId);

    _db!.execute('BEGIN TRANSACTION;');
    try {
      _db!.execute('''
        INSERT INTO rag_documents (
          id, source_type, uri, title, content_hash, file_size, last_modified, chunk_count, indexed_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''', [
        documentId,
        sourceType,
        uri,
        title,
        contentHash,
        fileSize,
        lastModified,
        chunks.length,
        DateTime.now().millisecondsSinceEpoch,
      ]);

      final chunkStmt = _db!.prepare('''
        INSERT INTO rag_chunks (
          id, document_id, chunk_index, content, token_count, line_start, line_end, embedding
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ''');

      PreparedStatement? ftsStmt;
      try {
        ftsStmt = _db!.prepare('''
          INSERT INTO rag_chunks_fts (chunk_id, document_id, content) VALUES (?, ?, ?)
        ''');
      } catch (_) {}

      for (final c in chunks) {
        chunkStmt.execute([
          c['id'],
          documentId,
          c['index'],
          c['content'],
          c['token_count'] ?? 0,
          c['line_start'],
          c['line_end'],
          c['embedding'], // BLOB (Uint8List)
        ]);

        if (ftsStmt != null) {
          try {
            ftsStmt.execute([c['id'], documentId, c['content']]);
          } catch (_) {}
        }
      }

      chunkStmt.dispose();
      ftsStmt?.dispose();

      _db!.execute('COMMIT;');
    } catch (e) {
      _db!.execute('ROLLBACK;');
      rethrow;
    }
  }

  /// Executes FTS5 BM25 search.
  List<ScoredChunk> searchFts(String query, {int limit = 10}) {
    final cleanQuery = _sanitizeFtsQuery(query);
    if (cleanQuery.isEmpty) return [];

    try {
      final results = _db!.select('''
        SELECT 
          f.chunk_id,
          f.document_id,
          f.content,
          d.uri,
          d.title,
          c.chunk_index,
          c.line_start,
          c.line_end,
          bm25(rag_chunks_fts) as rank_score
        FROM rag_chunks_fts f
        JOIN rag_documents d ON f.document_id = d.id
        LEFT JOIN rag_chunks c ON f.chunk_id = c.id
        WHERE rag_chunks_fts MATCH ?
        ORDER BY rank_score ASC
        LIMIT ?
      ''', [cleanQuery, limit]);

      final chunks = <ScoredChunk>[];
      for (final row in results) {
        final rawScore = (row['rank_score'] as num).toDouble();
        // Normalize BM25 score (smaller negative is better match)
        final normalizedScore = (1.0 / (1.0 + rawScore.abs())).clamp(0.0, 1.0);

        chunks.add(
          ScoredChunk(
            chunkId: row['chunk_id'] as String,
            documentId: row['document_id'] as String,
            documentUri: row['uri'] as String,
            documentTitle: row['title'] as String?,
            chunkIndex: row['chunk_index'] as int?,
            lineStart: row['line_start'] as int?,
            lineEnd: row['line_end'] as int?,
            content: row['content'] as String,
            score: normalizedScore,
            matchType: 'bm25',
          ),
        );
      }
      return chunks;
    } catch (_) {
      // Fallback: LIKE query if FTS5 syntax error occurs
      return _searchLikeFallback(query, limit: limit);
    }
  }

  /// Retrieves chunks that possess vector embeddings for similarity calculation.
  List<Map<String, dynamic>> getAllChunksWithVectors() {
    final rows = _db!.select('''
      SELECT c.id, c.document_id, c.chunk_index, c.line_start, c.line_end, c.content, c.embedding, d.uri, d.title
      FROM rag_chunks c
      JOIN rag_documents d ON c.document_id = d.id
      WHERE c.embedding IS NOT NULL
    ''');

    return rows.map((r) => {
      'chunk_id': r['id'],
      'document_id': r['document_id'],
      'chunk_index': r['chunk_index'],
      'line_start': r['line_start'],
      'line_end': r['line_end'],
      'content': r['content'],
      'embedding': r['embedding'],
      'uri': r['uri'],
      'title': r['title'],
    }).toList();
  }

  List<ScoredChunk> _searchLikeFallback(String query, {int limit = 10}) {
    final words = query.trim().split(RegExp(r'\s+')).where((w) => w.length > 2);
    if (words.isEmpty) return [];

    final likeClause = words.map((_) => 'c.content LIKE ?').join(' OR ');
    final params = words.map((w) => '%$w%').toList();
    params.add(limit.toString());

    try {
      final rows = _db!.select('''
        SELECT c.id as chunk_id, c.document_id, c.chunk_index, c.line_start, c.line_end, c.content, d.uri, d.title
        FROM rag_chunks c
        JOIN rag_documents d ON c.document_id = d.id
        WHERE $likeClause
        LIMIT ?
      ''', params);

      return rows.map((r) => ScoredChunk(
        chunkId: r['chunk_id'] as String,
        documentId: r['document_id'] as String,
        documentUri: r['uri'] as String,
        documentTitle: r['title'] as String?,
        chunkIndex: r['chunk_index'] as int?,
        lineStart: r['line_start'] as int?,
        lineEnd: r['line_end'] as int?,
        content: r['content'] as String,
        score: 0.5,
        matchType: 'bm25',
      )).toList();
    } catch (_) {
      return [];
    }
  }

  String _sanitizeFtsQuery(String query) {
    // Keep alphanumeric and spaces, strip FTS syntax characters
    final words = query
        .replaceAll(RegExp(r'[^\w\s\u00C0-\u024F]'), ' ')
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.length > 1)
        .take(8);
    if (words.isEmpty) return '';
    return words.map((w) => '"$w"*').join(' OR ');
  }

  /// Returns statistical summary of the indexed database.
  Map<String, dynamic> getStats() {
    if (_db == null) open();

    final docCount = _db!.select('SELECT COUNT(*) as c FROM rag_documents').first['c'] as int;
    final chunkCount = _db!.select('SELECT COUNT(*) as c FROM rag_chunks').first['c'] as int;
    final vecCount = _db!.select('SELECT COUNT(*) as c FROM rag_chunks WHERE embedding IS NOT NULL').first['c'] as int;

    final dbFile = File(databasePath);
    final sizeBytes = dbFile.existsSync() ? dbFile.lengthSync() : 0;

    return {
      'database_path': databasePath,
      'document_count': docCount,
      'chunk_count': chunkCount,
      'vector_count': vecCount,
      'file_size_bytes': sizeBytes,
      'file_size_mb': (sizeBytes / (1024 * 1024)).toStringAsFixed(2),
    };
  }

  void close() {
    _db?.dispose();
    _db = null;
  }
}
