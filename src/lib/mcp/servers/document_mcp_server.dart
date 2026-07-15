import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../database/duckdb_service.dart';
import '../../services/app_logger.dart';
import '../../services/data_sources_settings_service.dart';
import '../../services/server_api_client.dart';
import '../../utils/saf_bridge.dart';
import '../../utils/semantic_embedding.dart';
import '../internal_mcp_server.dart';

/// Internal MCP server for document search and indexing.
///
/// Scans a local directory for documents (txt, md, docx, xlsx, pdf, csv),
/// extracts text content, indexes it in DuckDB, and provides
/// full-text search capabilities.
///
/// Init parameters:
///   • rootPath: One or more directories separated by ';'
///              (e.g. "C:\Documents" or "/sdcard/Download;/sdcard/Documents")
///   • fileTypes: Comma-separated list of extensions (default: "txt,md,docx,xlsx,pdf,csv")
///   • indexingStrategy: "now" | "before_first_run" (when to build the index)
class DocumentMcpServer extends InternalMcpServer {
  List<String> _rootPaths = [];
  List<String> _fileTypes = [];
  String _indexingStrategy = 'now';
  int _maxDocuments = 1000;
  bool _indexed = false;
  bool _pdfEngineInitialized = false;
  bool _cancelRequested = false;

  /// Callback invoked during indexing with (indexed, total, currentFileName).
  void Function(int indexed, int total, String currentFile)? onIndexProgress;

  /// Request cancellation of the current indexing operation.
  void cancelIndexing() => _cancelRequested = true;

  // ── Public accessors (for testing) ──
  List<String> get rootPaths => _rootPaths;

  /// Convenience: first root path (for backward compat).
  String? get rootPath => _rootPaths.isNotEmpty ? _rootPaths.first : null;
  List<String> get fileTypes => _fileTypes;
  String get indexingStrategy => _indexingStrategy;
  int get maxDocuments => _maxDocuments;
  bool get isIndexed => _indexed;

  @override
  String get type => 'document';

  @override
  String get displayName => 'Document Search';

  @override
  String get description =>
      'Search and index local documents (TXT, MD, DOCX, XLSX, PDF, CSV). '
      'Extracts text content and provides semantic/hybrid search via DuckDB.';

  @override
  String get iconName => 'description';

  @override
  Map<String, dynamic> get initParamSchema => {
    'type': 'object',
    'properties': {
      'rootPath': {
        'type': 'string',
        'description':
            'One or more root directories to scan, separated by ";". '
            '(e.g. "/sdcard/Download;/sdcard/Documents").',
      },
      'fileTypes': {
        'type': 'string',
        'description':
            'Comma-separated file extensions to index '
            '(e.g. "txt,md,docx,xlsx,pdf,csv").',
        'default': 'txt,md,docx,xlsx,pdf,csv',
      },
      'indexingStrategy': {
        'type': 'string',
        'description':
            'When to index: "now" (at initialization) or '
            '"before_first_run" (lazy, index before first search).',
        'default': 'before_first_run',
        'enum': ['now', 'before_first_run'],
      },
      'maxDocuments': {'type': 'integer', 'description': 'Maximum number of documents to index (1–10000).', 'default': 1000},
    },
    'required': ['rootPath'],
  };

  /// Allowed file types (hard-restricted for local document search).
  static const _allowedFileTypes = ['pdf', 'md', 'docx'];
  static const _maxFolders = 10;
  static const _maxFiles = 10000;

  @override
  Map<String, dynamic> get defaultInitParams => {
    'rootPath': '',
    'fileTypes': 'pdf,md,docx',
    'indexingStrategy': 'before_first_run',
    'maxDocuments': _maxDocuments,
  };

  @override
  String get defaultSystemPrompt =>
      'Document tools: use search_documents to find relevant files, then '
      'get_document_content to read details. Return file names and relevant '
      'excerpts. If no matches are found, suggest broader search terms.';

  // ══════════════════════════════════════════════
  // Lifecycle
  // ══════════════════════════════════════════════

  @override
  Future<void> initialize(Map<String, dynamic> initParams) async {
    final rawPath = initParams['rootPath'] as String? ?? '';
    _rootPaths = rawPath.split(';').map((e) => e.trim()).where((e) => e.isNotEmpty).take(_maxFolders).toList();
    // Use caller-supplied file types; fall back to the allowed set.
    final rawTypes = initParams['fileTypes'] as String? ?? '';
    final requestedTypes = rawTypes.split(',').map((e) => e.trim().toLowerCase()).where((e) => e.isNotEmpty).toList();
    _fileTypes = requestedTypes.isNotEmpty ? requestedTypes : _allowedFileTypes;
    _indexingStrategy = initParams['indexingStrategy'] as String? ?? 'now';
    final maxDocsRaw = initParams['maxDocuments'];
    _maxDocuments = (maxDocsRaw is int ? maxDocsRaw : int.tryParse(maxDocsRaw?.toString() ?? '') ?? _maxFiles).clamp(1, _maxFiles);

    log.info(
      '[Document MCP] Initializing with rootPaths=${_rootPaths.join("; ")}, '
      'fileTypes=${_fileTypes.join(",")}, strategy=$_indexingStrategy',
    );

    if (_rootPaths.isEmpty) {
      log.warning('[Document MCP] No rootPath specified');
      return;
    }

    // In server/remote mode the index lives on the server — skip local indexing.
    final prefs = await SharedPreferences.getInstance();
    final isRemote = (prefs.getString('server_mode') ?? 'local') == 'remote';
    if (isRemote) {
      _indexed = true;
      log.info('[Document MCP] Server mode: skipping local indexing; queries will use server DuckDB.');
      return;
    }

    // Ensure the document index table exists
    await _ensureTable();

    if (_indexingStrategy == 'before_first_run') {
      _indexed = await _hasExistingIndexForConfiguredRoots();
      if (_indexed) {
        log.info('[Document MCP] Reusing existing index for configured root paths (no auto-reindex needed)');
      }
    }

    // Index immediately if strategy is "now"
    if (_indexingStrategy == 'now') {
      await _indexDocuments();
    }
  }

  @override
  String? validateInitParams(Map<String, dynamic> params) {
    final rootPath = params['rootPath'] as String?;
    if (rootPath == null || rootPath.trim().isEmpty) {
      return 'At least one root path is required';
    }
    return null;
  }

  @override
  Future<void> dispose() async {
    _indexed = false;
  }

  // ══════════════════════════════════════════════
  // Tools
  // ══════════════════════════════════════════════

  @override
  List<McpToolDescriptor> get tools => [
    const McpToolDescriptor(
      name: 'list_documents',
      description: 'List all indexed documents. Optionally filter by file type.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'fileType': {'type': 'string', 'description': 'Filter by file extension (e.g. "docx", "pdf"). Omit for all types.'},
          'limit': {'type': 'integer', 'description': 'Maximum number of documents to return (default: 100).', 'default': 100},
        },
        'required': [],
      },
    ),
    const McpToolDescriptor(
      name: 'search_documents',
      description:
          'Search across indexed documents. Supports keyword, semantic, and '
          'hybrid ranking with relevance scoring and excerpts.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'description': 'Search query text. Supports multiple words (all must match).'},
          'fileType': {'type': 'string', 'description': 'Filter by file extension (e.g. "docx"). Omit for all.'},
          'limit': {'type': 'integer', 'description': 'Maximum number of results (default: 20).', 'default': 20},
          'searchMode': {
            'type': 'string',
            'enum': ['keyword', 'semantic', 'hybrid'],
            'description': 'Search mode (default: hybrid).',
            'default': 'hybrid',
          },
        },
        'required': ['query'],
      },
    ),
    const McpToolDescriptor(
      name: 'get_document_content',
      description: 'Get the full text content of a specific indexed document.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'filePath': {'type': 'string', 'description': 'Full path to the document, or just the file name to search for.'},
        },
        'required': ['filePath'],
      },
    ),
    const McpToolDescriptor(
      name: 'reindex',
      description:
          'Re-scan the root directory and rebuild the document index. '
          'Use this after adding, modifying, or deleting documents.',
      inputSchema: {'type': 'object', 'properties': {}, 'required': []},
    ),
    const McpToolDescriptor(
      name: 'purge_stale_index',
      description: 'Delete indexed document rows that no longer belong to currently configured root paths.',
      inputSchema: {'type': 'object', 'properties': {}, 'required': []},
    ),
  ];

  @override
  Future<Map<String, dynamic>> executeTool(String toolName, Map<String, dynamic> arguments) async {
    log.info('[Document MCP] executeTool: $toolName');

    final prefs = await SharedPreferences.getInstance();
    final isRemote = (prefs.getString('server_mode') ?? 'local') == 'remote';

    // Lazy indexing only applies in local mode.
    if (!isRemote && !_indexed && _indexingStrategy == 'before_first_run' && toolName != 'reindex') {
      await _indexDocuments();
    }

    switch (toolName) {
      case 'list_documents':
        return _listDocuments(arguments);
      case 'search_documents':
        return _searchDocuments(arguments);
      case 'get_document_content':
        return _getDocumentContent(arguments);
      case 'reindex':
        return _reindex();
      case 'purge_stale_index':
        return _purgeStaleIndex();
      default:
        return {'error': 'Unknown tool: $toolName'};
    }
  }

  // ══════════════════════════════════════════════
  // DuckDB Table
  // ══════════════════════════════════════════════

  Future<void> _ensureTable() async {
    final db = DuckDbService();
    await db.execute('''
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
      await db.execute('ALTER TABLE document_index ADD COLUMN IF NOT EXISTS embedding_json TEXT');
    } catch (_) {
      // ignore migration errors on older engines
    }
    log.info('[Document MCP] document_index table ensured');
  }

  Future<bool> _hasExistingIndexForConfiguredRoots() async {
    if (_rootPaths.isEmpty) return false;
    final db = DuckDbService();
    try {
      final rows = await db.query('''
        SELECT COUNT(*) FROM document_index
        WHERE ${_rootPathInClause()}
      ''');
      final count = rows.isNotEmpty ? int.tryParse(rows.first.first.toString()) ?? 0 : 0;
      return count > 0;
    } catch (e) {
      log.warning('[Document MCP] Failed checking existing index state: $e');
      return false;
    }
  }

  // ══════════════════════════════════════════════
  // Indexing Engine
  // ══════════════════════════════════════════════

  /// Build a SQL IN clause for all root paths.
  String _rootPathInClause() {
    if (_rootPaths.isEmpty) return "root_path = '__none__'";
    final escaped = _rootPaths.map((p) => "'${_esc(p)}'").join(', ');
    return 'root_path IN ($escaped)';
  }

  Future<Map<String, dynamic>> _indexDocuments() async {
    if (_rootPaths.isEmpty) {
      log.warning('[Document MCP] Cannot index: no rootPath');
      return {'error': 'No root path configured'};
    }

    log.info('[Document MCP] Starting indexing of: ${_rootPaths.join("; ")}');
    final db = DuckDbService();
    final ds = DataSourcesSettingsService.instance;
    if (!ds.isLoaded) {
      await ds.load();
    }
    final maxIndexBytes = (ds.duckDbIndexSizeLimitGb * 1024 * 1024 * 1024).round();
    final stopwatch = Stopwatch()..start();

    // Remove stale rows for removed roots, then fully refresh current roots.
    final escapedRoots = _rootPaths.map((rp) => "'${_esc(rp)}'").join(', ');
    await db.execute('DELETE FROM document_index WHERE root_path NOT IN ($escapedRoots)');

    // Clear existing index for all active root paths.
    for (final rp in _rootPaths) {
      await db.execute("DELETE FROM document_index WHERE root_path = '${_esc(rp)}'");
    }

    int indexed = 0;
    int skipped = 0;
    int errors = 0;
    int totalContentChars = 0;
    int totalFileBytes = 0;
    bool sizeLimitReached = false;
    _cancelRequested = false;

    // Enumerate all eligible files. Each entry is either:
    //   (rootPath, filePath, null) — real filesystem path
    //   (rootPath, null, SafFile)  — Android SAF content URI
    final allFiles = <({String rp, String? path, SafFile? safFile})>[];

    for (final rp in _rootPaths) {
      if (SafBridge.isSafUri(rp)) {
        // Android SAF folder — list via method channel
        try {
          final safFiles = await SafBridge.listFiles(rp, extensions: _fileTypes, maxFiles: _maxDocuments);
          for (final sf in safFiles) {
            if (allFiles.length >= _maxDocuments) break;
            allFiles.add((rp: rp, path: null, safFile: sf));
          }
        } catch (e) {
          log.warning('[Document MCP] SAF listing failed for $rp: $e');
          return {'error': 'Cannot list folder $rp: $e'};
        }
      } else {
        // Real filesystem path
        final dir = Directory(rp);
        if (!dir.existsSync()) {
          log.warning('[Document MCP] Root path does not exist: $rp');
          return {'error': 'Root path does not exist: $rp'};
        }
        try {
          await for (final entity in dir.list(recursive: true, followLinks: false)) {
            if (allFiles.length >= _maxDocuments) break;
            if (entity is File) {
              final ext = _getExtension(entity.path);
              if (_fileTypes.contains(ext)) {
                allFiles.add((rp: rp, path: entity.path, safFile: null));
              }
            }
          }
        } catch (e) {
          log.warning('[Document MCP] Error scanning $rp: $e');
          return {'error': 'Failed to scan directory: $rp — $e'};
        }
      }
    }

    final totalEligible = allFiles.length.clamp(0, _maxDocuments);
    log.info('[Document MCP] Found $totalEligible eligible files (types: ${_fileTypes.join(",")})');
    onIndexProgress?.call(0, totalEligible, '');

    for (final entry in allFiles.take(_maxDocuments)) {
      if (_cancelRequested) {
        log.info('[Document MCP] Indexing cancelled after $indexed documents');
        break;
      }

      try {
        final String filePath;
        final String fileName;
        final int fileSize;
        final String lastModified;
        String? content;

        if (entry.safFile != null) {
          final sf = entry.safFile!;
          filePath = sf.uri;
          fileName = sf.name;
          fileSize = sf.size;
          lastModified = DateTime.fromMillisecondsSinceEpoch(sf.lastModified).toIso8601String();
          if (totalFileBytes + fileSize > maxIndexBytes) {
            sizeLimitReached = true;
            skipped++;
            continue;
          }
          content = await _extractTextSaf(sf);
        } else {
          final f = File(entry.path!);
          final stat = f.statSync();
          filePath = entry.path!;
          fileName = _fileName(filePath);
          fileSize = stat.size;
          lastModified = stat.modified.toIso8601String();
          if (totalFileBytes + fileSize > maxIndexBytes) {
            sizeLimitReached = true;
            skipped++;
            continue;
          }
          content = await _extractText(filePath, _getExtension(filePath));
        }

        final id = '${entry.rp}_$filePath'.hashCode.toRadixString(16);
        final escapedContent = _esc(content ?? '');
        final embedding = SemanticEmbedding.buildEmbedding(content ?? '');
        final escapedEmbedding = _esc(SemanticEmbedding.toJson(embedding));

        await db.execute('''
          INSERT OR REPLACE INTO document_index
            (id, root_path, file_path, file_name, file_type,
             content_text, embedding_json, file_size, last_modified, indexed_at)
          VALUES (
            '${_esc(id)}',
            '${_esc(entry.rp)}',
            '${_esc(filePath)}',
            '${_esc(fileName)}',
            '${_esc(_getExtension(fileName.isEmpty ? filePath : fileName))}',
            '$escapedContent',
            '$escapedEmbedding',
            $fileSize,
            '$lastModified',
            '${DateTime.now().toIso8601String()}'
          )
        ''');
        indexed++;
        final contentLen = content?.length ?? 0;
        totalContentChars += contentLen;
        totalFileBytes += fileSize;
        onIndexProgress?.call(indexed, totalEligible, fileName);
        log.info('[Document MCP] [$indexed/$_maxDocuments] Indexed: $fileName (${_formatFileSize(fileSize)})');
        await Future<void>.delayed(Duration.zero);
      } catch (e) {
        log.warning('[Document MCP] Failed to index entry: $e');
        errors++;
      }
    }

    stopwatch.stop();
    _indexed = !_cancelRequested;
    final wasCancelled = _cancelRequested;
    _cancelRequested = false;
    log.info(
      '[Document MCP] Indexing ${wasCancelled ? "cancelled" : "complete"}: $indexed documents indexed, '
      '$skipped skipped, $errors errors, '
      '${sizeLimitReached ? "size limit reached, " : ""}'
      'total file size: ${_formatFileSize(totalFileBytes)}, '
      'total extracted text: ${_formatFileSize(totalContentChars)} chars, '
      '${stopwatch.elapsedMilliseconds}ms',
    );

    return {
      'indexed': indexed,
      'skipped': skipped,
      'errors': errors,
      'cancelled': wasCancelled,
      'sizeLimitReached': sizeLimitReached,
      'maxIndexBytes': maxIndexBytes,
      'totalFileBytes': totalFileBytes,
      'totalFileSizeFormatted': _formatFileSize(totalFileBytes),
      'totalContentChars': totalContentChars,
      'durationMs': stopwatch.elapsedMilliseconds,
    };
  }

  // ══════════════════════════════════════════════
  // Text Extraction
  // ══════════════════════════════════════════════

  /// Extract text from a SAF file (content:// URI) by reading bytes via the
  /// method channel and then dispatching to the same per-extension extractors.
  Future<String?> _extractTextSaf(SafFile sf) async {
    final ext = sf.extension;
    try {
      final bytes = await SafBridge.readFile(sf.uri);
      if (bytes == null) return null;
      switch (ext) {
        case 'txt':
        case 'md':
        case 'csv':
        case 'log':
        case 'json':
        case 'yaml':
        case 'yml':
          try {
            return utf8.decode(bytes);
          } catch (_) {
            return latin1.decode(bytes);
          }
        case 'docx':
          return _extractDocxBytes(bytes);
        case 'pdf':
          return await _extractPdfBytes(bytes, sf.name);
        default:
          return null;
      }
    } catch (e) {
      log.warning('[Document MCP] SAF text extraction failed for ${sf.name}: $e');
      return null;
    }
  }

  Future<String?> _extractText(String filePath, String ext) async {
    try {
      switch (ext) {
        case 'txt':
        case 'md':
        case 'csv':
        case 'log':
        case 'json':
        case 'yaml':
        case 'yml':
          return await _readTextFile(filePath);
        case 'docx':
          return _extractDocxText(filePath);
        case 'xlsx':
          return _extractXlsxText(filePath);
        case 'pdf':
          return await _extractPdfText(filePath);
        default:
          return null;
      }
    } catch (e) {
      log.warning('[Document MCP] Text extraction failed for $filePath: $e');
      return null;
    }
  }

  /// Read a plain text file, with UTF-8 → Latin-1 fallback.
  Future<String> _readTextFile(String filePath) async {
    try {
      return await File(filePath).readAsString(encoding: utf8);
    } catch (_) {
      final bytes = await File(filePath).readAsBytes();
      return latin1.decode(bytes);
    }
  }

  /// Extract text content from a .docx file (Office Open XML).
  /// DOCX is a ZIP containing `word/document.xml` where text lives in `<w:t>` tags.
  String? _extractDocxText(String filePath) {
    final bytes = File(filePath).readAsBytesSync();
    return _extractDocxBytes(bytes);
  }

  String? _extractDocxBytes(List<int> bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final file in archive) {
      if (file.name == 'word/document.xml' && file.isFile) {
        final data = file.content as List<int>;
        final content = utf8.decode(data);

        // Extract paragraphs: each <w:p> block → one line
        final paraRegex = RegExp(r'<w:p[^>]*>(.*?)</w:p>', dotAll: true);
        final paragraphs = <String>[];

        for (final para in paraRegex.allMatches(content)) {
          final paraContent = para.group(1) ?? '';
          final textRegex = RegExp(r'<w:t[^>]*>(.*?)</w:t>', dotAll: true);
          final texts = textRegex.allMatches(paraContent).map((m) => m.group(1) ?? '').join('');
          if (texts.isNotEmpty) {
            paragraphs.add(texts);
          }
        }
        return paragraphs.join('\n');
      }
    }
    return null;
  }

  /// Extract text content from an .xlsx file (Office Open XML Spreadsheet).
  /// XLSX is a ZIP containing xl/sharedStrings.xml with text values.
  String? _extractXlsxText(String filePath) {
    final bytes = File(filePath).readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);

    // Step 1: Read shared strings (where most text values are stored)
    final sharedStrings = <String>[];
    for (final file in archive) {
      if (file.name == 'xl/sharedStrings.xml' && file.isFile) {
        final data = file.content as List<int>;
        final content = utf8.decode(data);
        final regex = RegExp(r'<t[^>]*>(.*?)</t>', dotAll: true);
        for (final match in regex.allMatches(content)) {
          final text = match.group(1) ?? '';
          if (text.isNotEmpty) sharedStrings.add(text);
        }
      }
    }

    // Step 2: Read inline strings from worksheets
    final allText = <String>[...sharedStrings];
    for (final file in archive) {
      if (file.name.startsWith('xl/worksheets/sheet') && file.isFile) {
        final data = file.content as List<int>;
        final content = utf8.decode(data);
        // Inline string values (<is><t>text</t></is>)
        final inlineRegex = RegExp(r'<is>\s*<t[^>]*>(.*?)</t>\s*</is>', dotAll: true);
        for (final match in inlineRegex.allMatches(content)) {
          final text = match.group(1) ?? '';
          if (text.isNotEmpty) allText.add(text);
        }
      }
    }

    return allText.isEmpty ? null : allText.join(' ');
  }

  /// Ensure pdfrx_engine is initialized (one-time).
  Future<void> _ensurePdfEngine() async {
    if (_pdfEngineInitialized) return;
    try {
      pdfrxFlutterInitialize();
      _pdfEngineInitialized = true;
      log.info('[Document MCP] PDF engine (PDFium) initialized');
    } catch (e) {
      log.warning('[Document MCP] PDF engine init failed: $e');
    }
  }

  /// Extract text content from a PDF file using pdfrx_engine (PDFium).
  Future<String?> _extractPdfText(String filePath) async {
    await _ensurePdfEngine();
    if (!_pdfEngineInitialized) {
      // Fallback to metadata if engine failed to init
      final stat = File(filePath).statSync();
      return '[PDF document: ${_fileName(filePath)}, '
          'size: ${_formatFileSize(stat.size)}, '
          'modified: ${stat.modified.toIso8601String()}]';
    }

    PdfDocument? document;
    try {
      document = await PdfDocument.openFile(filePath);
      final pages = document.pages;
      if (pages.isEmpty) return null;

      final buffer = StringBuffer();
      for (final page in pages) {
        final rawText = await page.loadText();
        if (rawText != null && rawText.fullText.isNotEmpty) {
          buffer.writeln(rawText.fullText);
        }
      }

      final text = buffer.toString().trim();
      return text.isEmpty ? null : text;
    } catch (e) {
      log.warning('[Document MCP] PDF text extraction failed for $filePath: $e');
      return null;
    } finally {
      document?.dispose();
    }
  }

  /// Extract PDF text from raw bytes (used for SAF-sourced files).
  Future<String?> _extractPdfBytes(List<int> bytes, String fileName) async {
    await _ensurePdfEngine();
    if (!_pdfEngineInitialized) {
      return '[PDF document: $fileName, size: ${_formatFileSize(bytes.length)}]';
    }
    PdfDocument? document;
    try {
      document = await PdfDocument.openData(Uint8List.fromList(bytes));
      final pages = document.pages;
      if (pages.isEmpty) return null;
      final buffer = StringBuffer();
      for (final page in pages) {
        final rawText = await page.loadText();
        if (rawText != null && rawText.fullText.isNotEmpty) {
          buffer.writeln(rawText.fullText);
        }
      }
      final text = buffer.toString().trim();
      return text.isEmpty ? null : text;
    } catch (e) {
      log.warning('[Document MCP] PDF bytes extraction failed for $fileName: $e');
      return null;
    } finally {
      document?.dispose();
    }
  }

  // ══════════════════════════════════════════════
  // Tool Implementations
  // ══════════════════════════════════════════════

  Future<Map<String, dynamic>> _listDocuments(Map<String, dynamic> args) async {
    final prefs = await SharedPreferences.getInstance();
    if ((prefs.getString('server_mode') ?? 'local') == 'remote') {
      final client = _buildServerClient(prefs);
      if (client == null) return {'error': 'Server not configured.'};
      final fileType = (args['fileType'] as String?)?.trim();
      final limit = (args['limit'] as int?) ?? 100;
      return client.listDocumentIndexEntries(fileType: fileType?.isEmpty == true ? null : fileType, limit: limit);
    }

    if (_rootPaths.isEmpty) {
      return {'error': 'No root path configured. Initialize with a rootPath first.'};
    }

    final fileType = args['fileType'] as String?;
    final limit = (args['limit'] as int?) ?? 100;

    final db = DuckDbService();
    final where = StringBuffer('WHERE ${_rootPathInClause()}');
    if (fileType != null && fileType.isNotEmpty) {
      where.write(" AND file_type = '${_esc(fileType.toLowerCase())}'");
    }

    final rows = await db.query('''
      SELECT file_path, file_name, file_type, file_size, last_modified,
             LENGTH(COALESCE(content_text, '')) as content_length
      FROM document_index
      $where
      ORDER BY file_name ASC
      LIMIT $limit
    ''');

    final countRows = await db.query('SELECT COUNT(*) FROM document_index $where');
    final totalCount = _toInt(countRows.first[0]);

    return {
      'rootPaths': _rootPaths,
      'totalDocuments': totalCount,
      'returned': rows.length,
      'documents': rows
          .map((r) => {'filePath': r[0], 'fileName': r[1], 'fileType': r[2], 'fileSize': r[3], 'lastModified': r[4], 'contentLength': r[5]})
          .toList(),
    };
  }

  Future<Map<String, dynamic>> _searchDocuments(Map<String, dynamic> args) async {
    final query = args['query'] as String?;
    if (query == null || query.trim().isEmpty) {
      return {'error': 'Search query is required'};
    }

    final prefs = await SharedPreferences.getInstance();
    if ((prefs.getString('server_mode') ?? 'local') == 'remote') {
      final client = _buildServerClient(prefs);
      if (client == null) return {'error': 'Server not configured.'};
      final fileType = (args['fileType'] as String?)?.trim();
      final limit = (args['limit'] as int?) ?? 20;
      final searchMode = (args['searchMode'] as String? ?? 'hybrid').toLowerCase();
      return client.searchDocumentIndex(
        query: query,
        fileType: fileType?.isEmpty == true ? null : fileType,
        limit: limit,
        searchMode: searchMode,
      );
    }

    if (_rootPaths.isEmpty) {
      return {'error': 'No root path configured.'};
    }

    final fileType = args['fileType'] as String?;
    final limit = (args['limit'] as int?) ?? 20;
    final searchMode = (args['searchMode'] as String? ?? 'hybrid').toLowerCase();
    final db = DuckDbService();

    final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

    final conditions = StringBuffer('WHERE ${_rootPathInClause()}');
    conditions.write(" AND content_text IS NOT NULL AND content_text != ''");

    if (fileType != null && fileType.isNotEmpty) {
      conditions.write(" AND file_type = '${_esc(fileType.toLowerCase())}'");
    }

    // ── SQL pre-filter: only load rows that contain at least one search keyword.
    // Applied for all search modes — semantic scoring still runs in the isolate,
    // but we avoid loading irrelevant rows that can never match.
    if (words.isNotEmpty) {
      final likeConditions = words.take(3).map((w) => "LOWER(content_text) LIKE '%${_esc(w)}%'").join(' OR ');
      conditions.write(' AND ($likeConditions)');
    }

    // Cap content_text at 80 KB per row to avoid loading huge files into memory.
    final rows = await db.query('''
      SELECT file_path, file_name, file_type, file_size,
             SUBSTRING(content_text, 1, 81920) AS content_text,
             embedding_json, last_modified
      FROM document_index
      $conditions
      LIMIT 200
    ''');

    if (rows.isEmpty) {
      return {
        'summary':
            'No documents found matching "$query". The index may be empty or the files have not been indexed yet. Try calling reindex first.',
        'query': query,
        'searchMode': searchMode,
        'totalResults': 0,
        'results': [],
      };
    }

    // ── Offload CPU-heavy scoring (cosine similarity, keyword scan) to a
    // separate isolate so the UI thread is never blocked.
    final queryEmbedding = SemanticEmbedding.buildEmbedding(query);
    final scored = await Isolate.run(() => _scoreRows(rows, words, query, queryEmbedding, searchMode));

    scored.sort((a, b) => (b['relevanceScore'] as num).compareTo(a['relevanceScore'] as num));

    final limited = scored.take(limit).toList();
    final fileLines = limited.asMap().entries.map((e) => '${e.key + 1}. ${e.value['fileName']}  →  ${e.value['filePath']}').join('\n');
    return {
      'summary':
          'Found ${limited.length} file(s) matching "$query":\n$fileLines\n\nUse get_document_content with the filePath to read the full content.',
      'totalResults': limited.length,
      'results': limited.map((r) => {'fileName': r['fileName'], 'filePath': r['filePath'], 'fileType': r['fileType']}).toList(),
    };
  }

  /// Pure scoring function — runs in a separate isolate to avoid blocking the UI.
  static List<Map<String, dynamic>> _scoreRows(
    List<List<dynamic>> rows,
    List<String> words,
    String query,
    List<double> queryEmbedding,
    String searchMode,
  ) {
    final results = <Map<String, dynamic>>[];
    for (final row in rows) {
      final content = row[4]?.toString() ?? '';
      if (content.isEmpty) continue;

      final matchCount = _countMatches(content, words);
      final keywordScore = SemanticEmbedding.keywordOverlapScore(query, content);
      final docEmbedding = SemanticEmbedding.fromJson(row[5]?.toString());
      final semanticScore = SemanticEmbedding.cosineSimilarity(queryEmbedding, docEmbedding);

      final relevanceScore = switch (searchMode) {
        'keyword' => keywordScore + (matchCount * 0.02),
        'semantic' => semanticScore,
        _ => (0.65 * semanticScore) + (0.30 * keywordScore) + (0.05 * matchCount),
      };

      if (searchMode == 'keyword' && matchCount == 0) continue;
      if (matchCount == 0 && relevanceScore < 0.35) continue;

      results.add({
        'filePath': row[0],
        'fileName': row[1],
        'fileType': row[2],
        'fileSize': row[3],
        'lastModified': row[6],
        'matchCount': matchCount,
        'keywordScore': keywordScore,
        'semanticScore': semanticScore,
        'relevanceScore': relevanceScore,
        'excerpt': _buildExcerpt(content, words, 220),
      });
    }
    return results;
  }

  Future<Map<String, dynamic>> _getDocumentContent(Map<String, dynamic> args) async {
    final filePath = args['filePath'] as String?;
    if (filePath == null || filePath.trim().isEmpty) {
      return {'error': 'File path is required'};
    }

    final prefs = await SharedPreferences.getInstance();
    if ((prefs.getString('server_mode') ?? 'local') == 'remote') {
      final client = _buildServerClient(prefs);
      if (client == null) return {'error': 'Server not configured.'};
      return client.getDocumentIndexEntry(filePath.trim());
    }

    if (_rootPaths.isEmpty) {
      return {'error': 'No root path configured.'};
    }

    final db = DuckDbService();
    final rpClause = _rootPathInClause();

    // Try exact path match first
    var rows = await db.query('''
      SELECT file_path, file_name, file_type, content_text,
             file_size, last_modified
      FROM document_index
      WHERE $rpClause
        AND file_path = '${_esc(filePath)}'
    ''');

    // Fall back to file name match
    if (rows.isEmpty) {
      rows = await db.query('''
        SELECT file_path, file_name, file_type, content_text,
               file_size, last_modified
        FROM document_index
        WHERE $rpClause
          AND LOWER(file_name) = '${_esc(filePath.toLowerCase())}'
        LIMIT 1
      ''');
    }

    // Fall back to partial path match
    if (rows.isEmpty) {
      rows = await db.query('''
        SELECT file_path, file_name, file_type, content_text,
               file_size, last_modified
        FROM document_index
        WHERE $rpClause
          AND LOWER(file_path) LIKE '%${_esc(filePath.toLowerCase())}%'
        LIMIT 1
      ''');
    }

    if (rows.isEmpty) {
      return {'error': 'Document not found: $filePath'};
    }

    final row = rows.first;
    return {'filePath': row[0], 'fileName': row[1], 'fileType': row[2], 'content': row[3], 'fileSize': row[4], 'lastModified': row[5]};
  }

  Future<Map<String, dynamic>> _reindex() async {
    if (_rootPaths.isEmpty) {
      return {'error': 'No root path configured.'};
    }

    final stopwatch = Stopwatch()..start();
    final result = await _indexDocuments();
    stopwatch.stop();

    if (result.containsKey('error')) return result;

    final db = DuckDbService();
    final rpClause = _rootPathInClause();
    final countRows = await db.query('SELECT COUNT(*) FROM document_index WHERE $rpClause');
    final count = _toInt(countRows.first[0]);

    // Calculate DB storage size for these root paths
    final sizeRows = await db.query(
      "SELECT COALESCE(SUM(file_size), 0), "
      "COALESCE(SUM(LENGTH(COALESCE(content_text, ''))), 0) "
      'FROM document_index WHERE $rpClause',
    );
    final totalFileSize = _toInt(sizeRows.first[0]);
    final totalIndexSize = _toInt(sizeRows.first[1]);

    return {
      'status': 'complete',
      'rootPaths': _rootPaths,
      'documentsIndexed': count,
      'maxDocuments': _maxDocuments,
      'durationMs': stopwatch.elapsedMilliseconds,
      'fileTypes': _fileTypes,
      'totalFileSizeBytes': totalFileSize,
      'indexSizeBytes': totalIndexSize,
      ...result,
    };
  }

  Future<Map<String, dynamic>> _purgeStaleIndex() async {
    final prefs = await SharedPreferences.getInstance();
    if ((prefs.getString('server_mode') ?? 'local') == 'remote') {
      final client = _buildServerClient(prefs);
      if (client == null) return {'error': 'Server not configured.'};
      return client.purgeStaleDocumentIndex();
    }

    if (_rootPaths.isEmpty) {
      return {'error': 'No root path configured.'};
    }

    final db = DuckDbService();
    final escapedRoots = _rootPaths.map((rp) => "'${_esc(rp)}'").join(', ');

    final beforeRows = await db.query('SELECT COUNT(*) FROM document_index');
    final beforeCount = beforeRows.isNotEmpty ? int.tryParse(beforeRows.first.first.toString()) ?? 0 : 0;

    await db.execute('DELETE FROM document_index WHERE root_path NOT IN ($escapedRoots)');

    final afterRows = await db.query('SELECT COUNT(*) FROM document_index');
    final afterCount = afterRows.isNotEmpty ? int.tryParse(afterRows.first.first.toString()) ?? 0 : 0;
    return {
      'ok': true,
      'scope': 'document',
      'configuredRoots': _rootPaths.length,
      'beforeRows': beforeCount,
      'afterRows': afterCount,
      'purgedRows': (beforeCount - afterCount).clamp(0, beforeCount),
    };
  }

  // ══════════════════════════════════════════════
  // Helpers
  // ══════════════════════════════════════════════

  /// Build a [ServerApiClient] from stored SharedPreferences. Returns null if server URL missing.
  ServerApiClient? _buildServerClient(SharedPreferences prefs) {
    final url = (prefs.getString('server_url') ?? '').trim();
    if (url.isEmpty) return null;
    final key = prefs.getString('server_api_key');
    return ServerApiClient(serverUrl: url, apiKey: key?.isNotEmpty == true ? key : null);
  }

  String _getExtension(String path) {
    final lastDot = path.lastIndexOf('.');
    if (lastDot < 0 || lastDot == path.length - 1) return '';
    return path.substring(lastDot + 1).toLowerCase();
  }

  String _fileName(String path) {
    final sep = path.contains('\\') ? '\\' : '/';
    return path.split(sep).last;
  }

  /// Escape single quotes for DuckDB SQL strings.
  String _esc(String s) => s.replaceAll("'", "''");

  /// Build a text excerpt around the first occurrence of search terms.
  static String _buildExcerpt(String content, List<String> words, int maxLength) {
    if (content.isEmpty) return '';

    final lower = content.toLowerCase();
    int bestPos = 0;

    // Find the first position where a search word appears
    for (final word in words) {
      final pos = lower.indexOf(word);
      if (pos >= 0) {
        bestPos = pos;
        break;
      }
    }

    // Extract context around that position
    final start = (bestPos - maxLength ~/ 2).clamp(0, content.length);
    final end = (start + maxLength).clamp(0, content.length);

    var excerpt = content.substring(start, end).trim();
    if (start > 0) excerpt = '...$excerpt';
    if (end < content.length) excerpt = '$excerpt...';

    return excerpt;
  }

  /// Count total matches of search terms in content.
  static int _countMatches(String content, List<String> words) {
    final lower = content.toLowerCase();
    int count = 0;
    for (final word in words) {
      int pos = 0;
      while (true) {
        pos = lower.indexOf(word, pos);
        if (pos < 0) break;
        count++;
        pos += word.length;
      }
    }
    return count;
  }

  /// Format file size in human-readable form.
  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  int _toInt(dynamic value) {
    if (value == null) return 0;
    if (value is int) return value;
    if (value is BigInt) return value.toInt();
    if (value is num) return value.toInt();
    return int.tryParse(value.toString()) ?? 0;
  }
}
