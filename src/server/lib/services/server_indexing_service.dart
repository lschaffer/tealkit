import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;

import '../database/server_database_adapter.dart';
import '../services/server_data_sources_service.dart';
import '../utils/semantic_embedding.dart';
import '../utils/server_logger.dart';

// ═══════════════════════════════════════════════════════════════
// Helper classes
// ═══════════════════════════════════════════════════════════════

class _FetchedPage {
  final int statusCode;
  final String title;
  final String text;
  final List<Uri> links;
  _FetchedPage({
    required this.statusCode,
    required this.title,
    required this.text,
    required this.links,
  });
}

class _CrawlItem {
  final Uri seed;
  final Uri url;
  _CrawlItem(this.seed, this.url);
}

// ═══════════════════════════════════════════════════════════════
// ServerIndexingService
// ═══════════════════════════════════════════════════════════════

/// Server-side website and document indexing.
///
/// Exposes start / stop / status for both website and document indexing.
/// All crawling and file I/O runs directly on the server and writes into
/// [ServerDatabaseAdapter] (the server's own DuckDB).
class ServerIndexingService {
  static final ServerIndexingService instance = ServerIndexingService._();
  ServerIndexingService._();

  // ── Website index state ───────────────────────────────────────
  bool _websiteRunning = false;
  bool _websiteCancelRequested = false;
  int _websiteIndexed = 0;
  int _websiteTotal = 0;
  String _websiteCurrentUrl = '';
  Map<String, dynamic>? _websiteLastResult;
  List<Uri> _websiteRunSeeds = const [];
  int _websiteRunMaxPages = 0;

  // ── Document index state ──────────────────────────────────────
  bool _documentRunning = false;
  bool _documentCancelRequested = false;
  int _documentIndexed = 0;
  int _documentTotal = 0;
  String _documentCurrentFile = '';
  Map<String, dynamic>? _documentLastResult;
  List<String> _documentRunRootPaths = const [];
  List<String> _documentRunFileTypes = const [];

  // ═══════════════════════════════════════════════════
  // Website indexing — public API
  // ═══════════════════════════════════════════════════

  Map<String, dynamic> getWebsiteIndexStatus() => {
    'running': _websiteRunning,
    'indexed': _websiteIndexed,
    'total': _websiteTotal,
    'currentUrl': _websiteCurrentUrl,
    'lastResult': _websiteLastResult,
  };

  /// Start website indexing in the background. Returns immediately.
  Map<String, dynamic> startWebsiteIndex({
    required String urls,
    required int maxPages,
  }) {
    if (_websiteRunning) {
      return {'error': 'Website indexing is already running'};
    }
    final seeds = _parseSeedUrls(urls);
    if (seeds.isEmpty) {
      return {'error': 'No valid URLs provided'};
    }
    final clampedMax = maxPages.clamp(1, 1000);
    final normalizedSeeds = seeds.map(_normalizeUrl).toSet().toList();
    final normalizedSeedUris = normalizedSeeds.map(Uri.parse).toList();

    _websiteRunning = true;
    _websiteCancelRequested = false;
    _websiteIndexed = 0;
    _websiteTotal = normalizedSeedUris.length * clampedMax;
    _websiteCurrentUrl = '';
    _websiteLastResult = null;
    _websiteRunSeeds = normalizedSeedUris;
    _websiteRunMaxPages = clampedMax;

    // Fire off async without awaiting
    _runWebsiteIndex(normalizedSeedUris, clampedMax)
        .then((result) async {
          _websiteLastResult = result;

          if (result['status'] == 'complete') {
            final ds = ServerDataSourcesService.instance;
            await ds.load();
            await ds.saveWebsiteIndex(
              urls: _websiteRunSeeds.map(_normalizeUrl).join(','),
              maxPages: _websiteRunMaxPages,
              cron: ds.websiteIndexCron,
              lastIndexedAt: DateTime.now(),
            );
          }

          _websiteRunning = false;
          _websiteCurrentUrl = '';
        })
        .catchError((Object e) {
          _websiteLastResult = {'error': e.toString()};
          _websiteRunning = false;
          _websiteCurrentUrl = '';
        });

    return {'started': true, 'seedCount': seeds.length, 'maxPages': clampedMax};
  }

  /// Run website indexing synchronously. Awaits the execution and returns results.
  Future<Map<String, dynamic>> runWebsiteIndexSync({
    required String urls,
    required int maxPages,
  }) async {
    if (_websiteRunning) {
      return {'error': 'Website indexing is already running'};
    }
    final seeds = _parseSeedUrls(urls);
    if (seeds.isEmpty) {
      return {'error': 'No valid URLs provided'};
    }
    final clampedMax = maxPages.clamp(1, 1000);
    final normalizedSeeds = seeds.map(_normalizeUrl).toSet().toList();
    final normalizedSeedUris = normalizedSeeds.map(Uri.parse).toList();

    _websiteRunning = true;
    _websiteCancelRequested = false;
    _websiteIndexed = 0;
    _websiteTotal = normalizedSeedUris.length * clampedMax;
    _websiteCurrentUrl = '';
    _websiteLastResult = null;
    _websiteRunSeeds = normalizedSeedUris;
    _websiteRunMaxPages = clampedMax;

    try {
      final result = await _runWebsiteIndex(normalizedSeedUris, clampedMax);
      _websiteLastResult = result;

      if (result['status'] == 'complete') {
        final ds = ServerDataSourcesService.instance;
        await ds.load();
        await ds.saveWebsiteIndex(
          urls: _websiteRunSeeds.map(_normalizeUrl).join(','),
          maxPages: _websiteRunMaxPages,
          cron: ds.websiteIndexCron,
          lastIndexedAt: DateTime.now(),
        );
      }
      return result;
    } catch (e) {
      final errResult = {'error': e.toString()};
      _websiteLastResult = errResult;
      return errResult;
    } finally {
      _websiteRunning = false;
      _websiteCurrentUrl = '';
    }
  }

  /// Signal the running website indexer to cancel.
  Map<String, dynamic> stopWebsiteIndex() {
    if (!_websiteRunning) return {'message': 'No website indexing in progress'};
    _websiteCancelRequested = true;
    return {'message': 'Cancel requested'};
  }

  // ═══════════════════════════════════════════════════
  // Document indexing — public API
  // ═══════════════════════════════════════════════════

  Map<String, dynamic> getDocumentIndexStatus() => {
    'running': _documentRunning,
    'indexed': _documentIndexed,
    'total': _documentTotal,
    'currentFile': _documentCurrentFile,
    'lastResult': _documentLastResult,
  };

  /// Start document indexing in the background. Returns immediately.
  Map<String, dynamic> startDocumentIndex({
    required String rootPaths,
    required String fileTypes,
  }) {
    if (_documentRunning) {
      return {'error': 'Document indexing is already running'};
    }
    final paths = rootPaths
        .split(';')
        .map((e) => _normalizeRootPath(e.trim()))
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    if (paths.isEmpty) {
      return {'error': 'No root paths provided'};
    }
    final types = fileTypes
        .split(',')
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toList();
    final effectiveTypes = types.isNotEmpty ? types : ['pdf', 'md', 'docx'];

    _documentRunning = true;
    _documentCancelRequested = false;
    _documentIndexed = 0;
    _documentTotal = 0;
    _documentCurrentFile = '';
    _documentLastResult = null;
    _documentRunRootPaths = paths;
    _documentRunFileTypes = effectiveTypes;

    _runDocumentIndex(paths, effectiveTypes)
        .then((result) async {
          _documentLastResult = result;

          if (result['status'] == 'complete') {
            final ds = ServerDataSourcesService.instance;
            await ds.load();
            await ds.saveDocumentIndex(
              rootPaths: _documentRunRootPaths.join(';'),
              fileTypes: _documentRunFileTypes.join(','),
              cron: ds.documentIndexCron,
              lastIndexedAt: DateTime.now(),
            );
          }

          _documentRunning = false;
          _documentCurrentFile = '';
        })
        .catchError((Object e) {
          _documentLastResult = {'error': e.toString()};
          _documentRunning = false;
          _documentCurrentFile = '';
        });

    return {'started': true, 'rootPaths': paths, 'fileTypes': effectiveTypes};
  }

  /// Signal the running document indexer to cancel.
  Map<String, dynamic> stopDocumentIndex() {
    if (!_documentRunning) {
      return {'message': 'No document indexing in progress'};
    }
    _documentCancelRequested = true;
    return {'message': 'Cancel requested'};
  }

  /// Purge website rows that are not part of currently configured seed URLs.
  Future<Map<String, dynamic>> purgeStaleWebsiteIndex() async {
    final db = serverDb;
    final ds = ServerDataSourcesService.instance;
    await ds.load();

    final seeds = _parseSeedUrls(
      ds.websiteIndexUrls,
    ).map(_normalizeUrl).toSet().toList();
    final beforeRows = await db.query('SELECT COUNT(*) FROM website_index');
    final beforeCount = beforeRows.isNotEmpty
        ? int.tryParse(beforeRows.first.first.toString()) ?? 0
        : 0;

    if (seeds.isEmpty) {
      await db.execute('DELETE FROM website_index');
    } else {
      final seedIn = seeds.map((s) => "'${_esc(s)}'").join(',');
      await db.execute(
        'DELETE FROM website_index WHERE seed_url NOT IN ($seedIn)',
      );
    }

    final afterRows = await db.query('SELECT COUNT(*) FROM website_index');
    final afterCount = afterRows.isNotEmpty
        ? int.tryParse(afterRows.first.first.toString()) ?? 0
        : 0;
    return {
      'ok': true,
      'scope': 'website',
      'configuredSeeds': seeds.length,
      'beforeRows': beforeCount,
      'afterRows': afterCount,
      'purgedRows': (beforeCount - afterCount).clamp(0, beforeCount),
    };
  }

  /// Purge document rows that are not part of currently configured root paths.
  Future<Map<String, dynamic>> purgeStaleDocumentIndex() async {
    final db = serverDb;
    final roots = await _getConfiguredDocumentRoots();

    final beforeRows = await db.query('SELECT COUNT(*) FROM document_index');
    final beforeCount = beforeRows.isNotEmpty
        ? int.tryParse(beforeRows.first.first.toString()) ?? 0
        : 0;

    if (roots.isEmpty) {
      await db.execute('DELETE FROM document_index');
    } else {
      final rootIn = roots.map((rp) => "'${_esc(rp)}'").join(',');
      await db.execute(
        'DELETE FROM document_index WHERE root_path NOT IN ($rootIn)',
      );
    }

    final afterRows = await db.query('SELECT COUNT(*) FROM document_index');
    final afterCount = afterRows.isNotEmpty
        ? int.tryParse(afterRows.first.first.toString()) ?? 0
        : 0;
    return {
      'ok': true,
      'scope': 'document',
      'configuredRoots': roots.length,
      'beforeRows': beforeCount,
      'afterRows': afterCount,
      'purgedRows': (beforeCount - afterCount).clamp(0, beforeCount),
    };
  }

  // ═══════════════════════════════════════════════════
  // Website crawl engine
  // ═══════════════════════════════════════════════════

  Future<Map<String, dynamic>> _runWebsiteIndex(
    List<Uri> seedUrls,
    int maxPages,
  ) async {
    final db = serverDb;
    final stopwatch = Stopwatch()..start();

    log.info(
      '[ServerIndexing] Website index start — seeds=${seedUrls.map((u) => u.toString()).join(", ")}, maxPages=$maxPages',
    );

    // Remove stale rows for removed seeds and fully refresh current seeds.
    final normalizedSeeds = seedUrls.map(_normalizeUrl).toSet().toList();
    try {
      if (normalizedSeeds.isNotEmpty) {
        final seedIn = normalizedSeeds.map((s) => "'${_esc(s)}'").join(',');
        await db.execute(
          'DELETE FROM website_index WHERE seed_url NOT IN ($seedIn)',
        );
        await db.execute(
          'DELETE FROM website_index WHERE seed_url IN ($seedIn)',
        );
      }
    } catch (e) {
      log.warning('[ServerIndexing] Failed to clear old website rows: $e');
    }

    final queue = Queue<_CrawlItem>();
    final visited = <String>{};
    final allowedDomains = seedUrls.map((u) => u.host.toLowerCase()).toSet();

    for (final seed in seedUrls) {
      queue.add(_CrawlItem(seed, seed));
    }

    int indexed = 0;
    int failed = 0;
    final perSeedIndexed = <String, int>{
      for (final s in seedUrls) _normalizeUrl(s): 0,
    };
    _websiteTotal = seedUrls.length * maxPages;

    while (queue.isNotEmpty) {
      if (_websiteCancelRequested) break;
      if (perSeedIndexed.values.every((n) => n >= maxPages)) break;

      final item = queue.removeFirst();
      final seedKey = _normalizeUrl(item.seed);

      if ((perSeedIndexed[seedKey] ?? 0) >= maxPages) continue;

      final normalizedUrl = _normalizeUrl(item.url);
      if (visited.contains(normalizedUrl)) continue;
      visited.add(normalizedUrl);

      if (!_isAllowed(item.url, allowedDomains)) continue;

      _websiteCurrentUrl = normalizedUrl;

      final page = await _fetchPage(item.url);
      if (page == null) {
        failed++;
        continue;
      }

      final embedding = SemanticEmbedding.buildEmbedding(page.text);
      final id = '${seedKey}_$normalizedUrl'.hashCode.toRadixString(16);

      try {
        await db.execute('''
          INSERT OR REPLACE INTO website_index
            (id, seed_url, url, domain, title, content_text, embedding_json, http_status, indexed_at)
          VALUES (
            '${_esc(id)}',
            '${_esc(seedKey)}',
            '${_esc(normalizedUrl)}',
            '${_esc(item.url.host.toLowerCase())}',
            '${_esc(page.title)}',
            '${_esc(page.text)}',
            '${_esc(SemanticEmbedding.toJson(embedding))}',
            ${page.statusCode},
            '${DateTime.now().toIso8601String()}'
          )
        ''');

        perSeedIndexed[seedKey] = (perSeedIndexed[seedKey] ?? 0) + 1;
        indexed++;
        _websiteIndexed = indexed;
      } catch (e) {
        failed++;
        log.warning('[ServerIndexing] Failed to persist $normalizedUrl: $e');
        continue;
      }

      final remaining = maxPages - (perSeedIndexed[seedKey] ?? 0);
      if (remaining > 0) {
        for (final link in page.links) {
          queue.add(_CrawlItem(item.seed, link));
        }
      }

      await Future<void>.delayed(Duration.zero);
    }

    stopwatch.stop();
    final wasCancelled = _websiteCancelRequested;
    _websiteCancelRequested = false;

    log.info(
      '[ServerIndexing] Website index ${wasCancelled ? "CANCELLED" : "COMPLETE"} — '
      'indexed=$indexed, failed=$failed, duration=${stopwatch.elapsedMilliseconds}ms',
    );

    return {
      'status': wasCancelled ? 'cancelled' : 'complete',
      'cancelled': wasCancelled,
      'indexedPages': indexed,
      'failedPages': failed,
      'durationMs': stopwatch.elapsedMilliseconds,
    };
  }

  // ═══════════════════════════════════════════════════
  // Document indexing engine
  // ═══════════════════════════════════════════════════

  Future<Map<String, dynamic>> _runDocumentIndex(
    List<String> rootPaths,
    List<String> fileTypes,
  ) async {
    final db = serverDb;
    final stopwatch = Stopwatch()..start();

    log.info(
      '[ServerIndexing] Document index start — paths=${rootPaths.join(";")} types=${fileTypes.join(",")}',
    );

    // Remove stale rows for removed roots, then fully refresh current roots.
    final normalizedRoots = rootPaths
        .map(_normalizeRootPath)
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    if (normalizedRoots.isNotEmpty) {
      final rootIn = normalizedRoots.map((rp) => "'${_esc(rp)}'").join(',');
      await db.execute(
        'DELETE FROM document_index WHERE root_path NOT IN ($rootIn)',
      );
    }

    // Clear existing index for these root paths (also remove common legacy variants).
    for (final rp in normalizedRoots) {
      await db.execute(
        "DELETE FROM document_index WHERE root_path = '${_esc(rp)}'",
      );
      await db.execute(
        "DELETE FROM document_index WHERE root_path = '${_esc('$rp/')}'",
      );
      await db.execute(
        "DELETE FROM document_index WHERE root_path = '${_esc('$rp\\')}'",
      );
    }

    // Enumerate files
    final allFiles = <({String rp, String path})>[];
    for (final rp in rootPaths.map(_normalizeRootPath)) {
      final dir = Directory(rp);
      if (!dir.existsSync()) {
        log.warning('[ServerIndexing] Root path does not exist: $rp');
        continue;
      }
      try {
        await for (final entity in dir.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is File) {
            final ext = _getExtension(entity.path);
            if (fileTypes.contains(ext)) {
              allFiles.add((rp: rp, path: entity.path));
            }
          }
        }
      } catch (e) {
        log.warning('[ServerIndexing] Error scanning $rp: $e');
      }
    }

    _documentTotal = allFiles.length;
    log.info('[ServerIndexing] Found ${allFiles.length} eligible files');

    int indexed = 0;
    int errors = 0;

    for (final entry in allFiles) {
      if (_documentCancelRequested) break;

      final fileName = _fileName(entry.path);
      _documentCurrentFile = fileName;

      try {
        final f = File(entry.path);
        final stat = f.statSync();
        final content = await _extractText(
          entry.path,
          _getExtension(entry.path),
        );

        final id = '${entry.rp}_${entry.path}'.hashCode.toRadixString(16);
        final embedding = SemanticEmbedding.buildEmbedding(content ?? '');

        await db.execute('''
          INSERT OR REPLACE INTO document_index
            (id, root_path, file_path, file_name, file_type,
             content_text, embedding_json, file_size, last_modified, indexed_at)
          VALUES (
            '${_esc(id)}',
            '${_esc(entry.rp)}',
            '${_esc(entry.path)}',
            '${_esc(fileName)}',
            '${_esc(_getExtension(entry.path))}',
            '${_esc(content ?? '')}',
            '${_esc(SemanticEmbedding.toJson(embedding))}',
            ${stat.size},
            '${stat.modified.toIso8601String()}',
            '${DateTime.now().toIso8601String()}'
          )
        ''');

        indexed++;
        _documentIndexed = indexed;
      } catch (e) {
        log.warning('[ServerIndexing] Failed to index ${entry.path}: $e');
        errors++;
      }

      await Future<void>.delayed(Duration.zero);
    }

    stopwatch.stop();
    final wasCancelled = _documentCancelRequested;
    _documentCancelRequested = false;

    log.info(
      '[ServerIndexing] Document index ${wasCancelled ? "CANCELLED" : "COMPLETE"} — '
      'indexed=$indexed, errors=$errors, duration=${stopwatch.elapsedMilliseconds}ms',
    );

    return {
      'status': wasCancelled ? 'cancelled' : 'complete',
      'cancelled': wasCancelled,
      'documentsIndexed': indexed,
      'errors': errors,
      'durationMs': stopwatch.elapsedMilliseconds,
    };
  }

  // ═══════════════════════════════════════════════════
  // Text extraction helpers
  // ═══════════════════════════════════════════════════

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
      log.warning('[ServerIndexing] Text extraction failed for $filePath: $e');
      return null;
    }
  }

  Future<String> _readTextFile(String filePath) async {
    try {
      return await File(filePath).readAsString(encoding: utf8);
    } catch (_) {
      final bytes = await File(filePath).readAsBytes();
      return latin1.decode(bytes);
    }
  }

  String? _extractDocxText(String filePath) {
    final bytes = File(filePath).readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final file in archive) {
      if (file.name == 'word/document.xml' && file.isFile) {
        final content = utf8.decode(file.content as List<int>);
        final paraRegex = RegExp(r'<w:p[^>]*>(.*?)</w:p>', dotAll: true);
        final paragraphs = <String>[];
        for (final para in paraRegex.allMatches(content)) {
          final texts = RegExp(r'<w:t[^>]*>(.*?)</w:t>', dotAll: true)
              .allMatches(para.group(1) ?? '')
              .map((m) => m.group(1) ?? '')
              .join('');
          if (texts.isNotEmpty) paragraphs.add(texts);
        }
        return paragraphs.join('\n');
      }
    }
    return null;
  }

  String? _extractXlsxText(String filePath) {
    final bytes = File(filePath).readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);
    final shared = <String>[];
    for (final file in archive) {
      if (file.name == 'xl/sharedStrings.xml' && file.isFile) {
        final content = utf8.decode(file.content as List<int>);
        for (final m in RegExp(
          r'<t[^>]*>(.*?)</t>',
          dotAll: true,
        ).allMatches(content)) {
          final t = m.group(1) ?? '';
          if (t.isNotEmpty) shared.add(t);
        }
      }
    }
    return shared.isEmpty ? null : shared.join(' ');
  }

  Future<String?> _extractPdfText(String filePath) async {
    // Try pdftotext (poppler) if available on the system
    try {
      final result = await Process.run('pdftotext', [
        filePath,
        '-',
      ], stdoutEncoding: utf8);
      if (result.exitCode == 0) {
        final text = (result.stdout as String).trim();
        if (text.isNotEmpty) return text;
      }
    } catch (_) {
      // pdftotext not available — return metadata stub
    }
    final stat = File(filePath).statSync();
    return '[PDF: ${_fileName(filePath)}, ${_formatSize(stat.size)}]';
  }

  // ═══════════════════════════════════════════════════
  // Web crawler helpers
  // ═══════════════════════════════════════════════════

  static const _kSkipExtensions = {
    'css',
    'js',
    'mjs',
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
    'svg',
    'ico',
    'bmp',
    'avif',
    'woff',
    'woff2',
    'ttf',
    'eot',
    'otf',
    'pdf',
    'doc',
    'docx',
    'xls',
    'xlsx',
    'ppt',
    'pptx',
    'zip',
    'gz',
    'tar',
    'rar',
    '7z',
    'mp3',
    'mp4',
    'wav',
    'ogg',
    'avi',
    'mov',
    'webm',
    'xml',
    'rss',
    'atom',
    'json',
    'jsonld',
    'map',
    'wasm',
  };

  static const _kSkipPathSegments = {
    'autor',
    'author',
    'autoren',
    'redaktion',
    'redakteur',
    'tag',
    'tags',
    'thema',
    'themen',
    'kategorie',
    'kategorien',
    'suche',
    'search',
    'impressum',
    'datenschutz',
    'agb',
    'kontakt',
    'ueber-uns',
    'about',
    'dsi',
    'privacy',
    'legal',
    'cookie',
    'cookies',
    'newsletter',
    'abo',
    'abonnement',
    'subscription',
    'login',
    'signin',
    'register',
    'konto',
    'account',
    'sitemap',
    'feed',
  };

  List<Uri> _parseSeedUrls(String raw) {
    final urls = <Uri>[];
    for (final part
        in raw
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .take(10)) {
      try {
        var uri = Uri.parse(part);
        if (!uri.hasScheme) uri = Uri.parse('https://$part');
        if (uri.scheme != 'http' && uri.scheme != 'https') continue;
        urls.add(uri);
      } catch (_) {}
    }
    return urls;
  }

  bool _isAllowed(Uri url, Set<String> allowedDomains) {
    if (url.scheme != 'http' && url.scheme != 'https') return false;
    final host = url.host.toLowerCase();
    if (allowedDomains.contains(host)) return true;
    return allowedDomains.any((d) => host.endsWith('.$d'));
  }

  String _normalizeUrl(Uri uri) {
    var s = uri.removeFragment().toString();
    if (s.endsWith('/')) s = s.substring(0, s.length - 1);
    return s;
  }

  Future<_FetchedPage?> _fetchPage(Uri url) async {
    try {
      final response = await http
          .get(
            url,
            headers: {
              'Accept': 'text/html,application/xhtml+xml',
              'User-Agent': 'TealKit-Indexer/1.0',
            },
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode < 200 || response.statusCode >= 300) return null;

      final contentType = (response.headers['content-type'] ?? '')
          .toLowerCase();
      if (!contentType.contains('text/html') &&
          !contentType.contains('application/xhtml') &&
          !contentType.contains('text/plain')) {
        return null;
      }

      final body = utf8.decode(response.bodyBytes, allowMalformed: true);
      final title = _extractTitle(body);
      final text = _extractHtmlText(body);
      if (text.trim().isEmpty) return null;

      return _FetchedPage(
        statusCode: response.statusCode,
        title: title,
        text: text,
        links: _extractLinks(url, body),
      );
    } catch (e) {
      log.warning('[ServerIndexing] Failed to fetch $url: $e');
      return null;
    }
  }

  String _extractTitle(String html) {
    final m = RegExp(
      r'<title[^>]*>(.*?)</title>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(html);
    return m == null ? '' : _stripTags(m.group(1) ?? '').trim();
  }

  String _extractHtmlText(String html) {
    var text = html
        .replaceAll(
          RegExp(
            r'<script[^>]*>.*?</script>',
            caseSensitive: false,
            dotAll: true,
          ),
          ' ',
        )
        .replaceAll(
          RegExp(
            r'<style[^>]*>.*?</style>',
            caseSensitive: false,
            dotAll: true,
          ),
          ' ',
        )
        .replaceAll(
          RegExp(
            r'<noscript[^>]*>.*?</noscript>',
            caseSensitive: false,
            dotAll: true,
          ),
          ' ',
        );
    text = _stripTags(text)
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return text;
  }

  String _stripTags(String v) => v.replaceAll(RegExp(r'<[^>]+>'), ' ');

  List<Uri> _extractLinks(Uri baseUrl, String html) {
    final links = <Uri>[];
    final regex = RegExp(
      'href\\s*=\\s*["\']([^"\'#]+)["\']',
      caseSensitive: false,
    );
    for (final match in regex.allMatches(html)) {
      final href = (match.group(1) ?? '').trim();
      if (href.isEmpty) continue;
      if (href.startsWith('javascript:') || href.startsWith('mailto:')) {
        continue;
      }
      if (href.contains('{{') || href.contains('}}')) continue;
      try {
        final candidate = Uri.parse(href);
        final resolved = candidate.hasScheme
            ? candidate
            : baseUrl.resolveUri(candidate);
        if (resolved.scheme != 'http' && resolved.scheme != 'https') continue;

        final pathSegment = resolved.path.split('/').last.toLowerCase();
        final extIdx = pathSegment.lastIndexOf('.');
        if (extIdx >= 0) {
          final ext = pathSegment.substring(extIdx + 1).split('?').first;
          if (_kSkipExtensions.contains(ext)) continue;
        }

        final pathParts = resolved.path
            .toLowerCase()
            .split('/')
            .where((s) => s.isNotEmpty);
        if (pathParts.any(
          (seg) => _kSkipPathSegments.contains(seg.split('?').first),
        )) {
          continue;
        }

        links.add(resolved);
      } catch (_) {}
    }
    return links;
  }

  // ═══════════════════════════════════════════════════
  // Website index query API
  // ═══════════════════════════════════════════════════

  /// Search the server's website_index table with hybrid semantic + keyword ranking.
  Future<Map<String, dynamic>> searchWebsiteIndex({
    required String query,
    String? domain,
    int limit = 20,
    String searchMode = 'hybrid',
  }) async {
    final cleanQuery = query
        .replaceAll(RegExp(r'\b(OR|AND|NOT)\b'), ' ')
        .replaceAll(RegExp(r'[()\[\]]'), ' ')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();

    final db = serverDb;
    final where = StringBuffer(
      "WHERE content_text IS NOT NULL AND content_text != ''",
    );
    final websiteScope = await _getWebsiteScope();
    if (websiteScope != null) {
      where.write(' AND ($websiteScope)');
    }
    if (domain != null && domain.isNotEmpty) {
      where.write(" AND domain = '${_esc(domain.toLowerCase())}'");
    }

    final rows = await db.query('''
      SELECT url, domain, title, content_text, embedding_json, indexed_at
      FROM website_index
      $where
    ''');

    final queryEmbedding = SemanticEmbedding.buildEmbedding(cleanQuery);
    final matches = <Map<String, dynamic>>[];

    for (final row in rows) {
      final content = (row[3] ?? '').toString();
      if (content.isEmpty) continue;

      final docEmbedding = SemanticEmbedding.fromJson(row[4]?.toString());
      final semanticScore = SemanticEmbedding.cosineSimilarity(
        queryEmbedding,
        docEmbedding,
      );
      final keywordScore = SemanticEmbedding.keywordOverlapScore(
        cleanQuery,
        content,
      );
      final lexicalMatches = _countMatches(content, cleanQuery);

      final relevance = switch (searchMode) {
        'keyword' => keywordScore + (lexicalMatches * 0.02),
        'semantic' => semanticScore,
        _ =>
          (0.65 * semanticScore) +
              (0.30 * keywordScore) +
              (0.05 * lexicalMatches),
      };

      if (lexicalMatches == 0 && relevance < 0.12) continue;

      matches.add({
        'url': row[0],
        'domain': row[1],
        'title': row[2],
        'excerpt': _buildExcerpt(content, cleanQuery),
        'keywordMatches': lexicalMatches,
        'keywordScore': keywordScore,
        'semanticScore': semanticScore,
        'relevanceScore': relevance,
        'indexedAt': row[5],
      });
    }

    matches.sort(
      (a, b) =>
          (b['relevanceScore'] as num).compareTo(a['relevanceScore'] as num),
    );

    final domainRows = await db.query(
      'SELECT domain, COUNT(*) FROM website_index $where GROUP BY domain ORDER BY COUNT(*) DESC',
    );
    final indexedDomains = {for (final r in domainRows) r[0].toString(): r[1]};

    List<Map<String, dynamic>> finalResults = matches.take(limit).toList();
    bool usedFallback = false;
    if (matches.isEmpty && rows.isNotEmpty) {
      usedFallback = true;
      final fallback = <Map<String, dynamic>>[];
      for (final row in rows) {
        final content = (row[3] ?? '').toString();
        if (content.isEmpty) continue;
        final docEmb = SemanticEmbedding.fromJson(row[4]?.toString());
        final score = SemanticEmbedding.cosineSimilarity(
          queryEmbedding,
          docEmb,
        );
        fallback.add({
          'url': row[0],
          'domain': row[1],
          'title': row[2],
          'excerpt': _buildExcerpt(content, cleanQuery),
          'keywordMatches': 0,
          'semanticScore': score,
          'relevanceScore': score,
          'indexedAt': row[5],
        });
      }
      fallback.sort(
        (a, b) =>
            (b['relevanceScore'] as num).compareTo(a['relevanceScore'] as num),
      );
      finalResults = fallback.take(limit).toList();
    }

    final sampleRows = await db.query(
      "SELECT title, domain FROM website_index $where AND title IS NOT NULL AND title != '' LIMIT 5",
    );
    final sampleTitles = sampleRows.map((r) => '${r[1]}: ${r[0]}').toList();

    return {
      'query': cleanQuery,
      'originalQuery': cleanQuery != query ? query : null,
      'searchMode': searchMode,
      'totalResults': finalResults.length,
      'usedFallback': usedFallback,
      'results': finalResults,
      'indexedDomains': indexedDomains,
      if (finalResults.isEmpty) 'sampleIndexedTitles': sampleTitles,
    };
  }

  /// List pages in the server's website_index.
  Future<Map<String, dynamic>> listWebsitePages({
    String? domain,
    int limit = 50,
  }) async {
    final db = serverDb;
    final where = StringBuffer('WHERE 1=1');
    final websiteScope = await _getWebsiteScope();
    if (websiteScope != null) {
      where.write(' AND ($websiteScope)');
    }
    if (domain != null && domain.isNotEmpty) {
      where.write(" AND domain = '${_esc(domain.toLowerCase())}'");
    }
    final rows = await db.query('''
      SELECT url, domain, title, http_status, indexed_at
      FROM website_index
      $where
      ORDER BY indexed_at DESC
      LIMIT ${limit.clamp(1, 500)}
    ''');
    return {
      'returned': rows.length,
      'pages': rows
          .map(
            (r) => {
              'url': r[0],
              'domain': r[1],
              'title': r[2],
              'httpStatus': r[3],
              'indexedAt': r[4],
            },
          )
          .toList(),
    };
  }

  /// Retrieve the full stored content for a single indexed URL.
  Future<Map<String, dynamic>> getWebsitePage(String url) async {
    final normalized = _normalizeUrl(Uri.parse(url));
    final db = serverDb;
    final websiteScope = await _getWebsiteScope();
    final scopeClause = websiteScope == null ? '' : ' AND ($websiteScope)';
    final rows = await db.query('''
      SELECT url, domain, title, content_text, indexed_at
      FROM website_index
      WHERE url = '${_esc(normalized)}'$scopeClause
      LIMIT 1
    ''');
    if (rows.isEmpty) return {'error': 'Indexed page not found: $url'};
    final r = rows.first;
    return {
      'url': r[0],
      'domain': r[1],
      'title': r[2],
      'content': r[3],
      'indexedAt': r[4],
    };
  }

  // ── search helpers ───────────────────────────────────────────

  int _countMatches(String content, String query) {
    final words = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    final lower = content.toLowerCase();
    var count = 0;
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

  String _buildExcerpt(String content, String query, {int maxLength = 260}) {
    final words = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    final lower = content.toLowerCase();
    int pos = 0;
    for (final word in words) {
      final p = lower.indexOf(word);
      if (p >= 0) {
        pos = p;
        break;
      }
    }
    final start = (pos - (maxLength ~/ 2)).clamp(0, content.length);
    final end = (start + maxLength).clamp(0, content.length);
    var excerpt = content.substring(start, end).trim();
    if (start > 0) excerpt = '...$excerpt';
    if (end < content.length) excerpt = '$excerpt...';
    return excerpt;
  }

  // ═══════════════════════════════════════════════════
  // Document index query API
  // ═══════════════════════════════════════════════════

  /// Search the server's document_index with hybrid semantic + keyword ranking.
  Future<Map<String, dynamic>> searchDocumentIndex({
    required String query,
    String? fileType,
    int limit = 20,
    String searchMode = 'hybrid',
  }) async {
    final cleanQuery = query.trim();
    if (cleanQuery.isEmpty) return {'error': 'query is required'};

    final db = serverDb;
    final words = cleanQuery
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();

    final where = StringBuffer(
      "WHERE content_text IS NOT NULL AND content_text != ''",
    );
    final roots = await _getConfiguredDocumentRoots();
    if (roots.isNotEmpty) {
      final rootClause = roots
          .map((rp) => "root_path = '${_esc(rp)}'")
          .join(' OR ');
      where.write(' AND ($rootClause)');
    }
    if (fileType != null && fileType.isNotEmpty) {
      where.write(" AND file_type = '${_esc(fileType.toLowerCase())}'");
    }
    if (words.isNotEmpty) {
      final likes = words
          .take(3)
          .map((w) => "LOWER(content_text) LIKE '%${_esc(w)}%'")
          .join(' OR ');
      where.write(' AND ($likes)');
    }

    final rows = await db.query('''
      SELECT file_path, file_name, file_type, file_size,
             SUBSTRING(content_text, 1, 81920) AS content_text,
             embedding_json, last_modified
      FROM document_index
      $where
      LIMIT 200
    ''');

    if (rows.isEmpty) {
      return {
        'summary': 'No documents found matching "$cleanQuery".',
        'query': cleanQuery,
        'searchMode': searchMode,
        'totalResults': 0,
        'results': [],
      };
    }

    final queryEmbedding = SemanticEmbedding.buildEmbedding(cleanQuery);
    final scored = <Map<String, dynamic>>[];
    for (final row in rows) {
      final content = row[4]?.toString() ?? '';
      if (content.isEmpty) continue;
      final matchCount = _countMatches(content, cleanQuery);
      final keywordScore = SemanticEmbedding.keywordOverlapScore(
        cleanQuery,
        content,
      );
      final docEmbedding = SemanticEmbedding.fromJson(row[5]?.toString());
      final semanticScore = SemanticEmbedding.cosineSimilarity(
        queryEmbedding,
        docEmbedding,
      );
      final relevanceScore = switch (searchMode) {
        'keyword' => keywordScore + (matchCount * 0.02),
        'semantic' => semanticScore,
        _ =>
          (0.65 * semanticScore) + (0.30 * keywordScore) + (0.05 * matchCount),
      };
      if (searchMode == 'keyword' && matchCount == 0) continue;
      if (matchCount == 0 && relevanceScore < 0.35) continue;
      scored.add({
        'filePath': row[0],
        'fileName': row[1],
        'fileType': row[2],
        'fileSize': row[3],
        'lastModified': row[6],
        'matchCount': matchCount,
        'keywordScore': keywordScore,
        'semanticScore': semanticScore,
        'relevanceScore': relevanceScore,
        'excerpt': _buildExcerpt(content, cleanQuery),
      });
    }

    scored.sort(
      (a, b) =>
          (b['relevanceScore'] as num).compareTo(a['relevanceScore'] as num),
    );
    final limited = scored.take(limit).toList();
    final fileLines = limited
        .asMap()
        .entries
        .map(
          (e) =>
              '${e.key + 1}. ${e.value['fileName']}  →  ${e.value['filePath']}',
        )
        .join('\n');
    return {
      'summary':
          'Found ${limited.length} file(s) matching "$cleanQuery":\n$fileLines',
      'totalResults': limited.length,
      'query': cleanQuery,
      'searchMode': searchMode,
      'results': limited
          .map(
            (r) => {
              'fileName': r['fileName'],
              'filePath': r['filePath'],
              'fileType': r['fileType'],
            },
          )
          .toList(),
    };
  }

  /// List documents in the server's document_index.
  Future<Map<String, dynamic>> listDocumentIndex({
    String? fileType,
    int limit = 100,
  }) async {
    final db = serverDb;
    final where = StringBuffer('WHERE 1=1');
    final roots = await _getConfiguredDocumentRoots();
    if (roots.isNotEmpty) {
      final rootClause = roots
          .map((rp) => "root_path = '${_esc(rp)}'")
          .join(' OR ');
      where.write(' AND ($rootClause)');
    }
    if (fileType != null && fileType.isNotEmpty) {
      where.write(" AND file_type = '${_esc(fileType.toLowerCase())}'");
    }
    final rows = await db.query('''
      SELECT file_path, file_name, file_type, file_size, last_modified,
             LENGTH(COALESCE(content_text, '')) AS content_length
      FROM document_index
      $where
      ORDER BY file_name ASC
      LIMIT ${limit.clamp(1, 1000)}
    ''');
    final countRows = await db.query(
      'SELECT COUNT(*) FROM document_index $where',
    );
    final totalCount = int.tryParse(countRows.first.first.toString()) ?? 0;
    return {
      'totalDocuments': totalCount,
      'returned': rows.length,
      'documents': rows
          .map(
            (r) => {
              'filePath': r[0],
              'fileName': r[1],
              'fileType': r[2],
              'fileSize': r[3],
              'lastModified': r[4],
              'contentLength': r[5],
            },
          )
          .toList(),
    };
  }

  /// Retrieve the full stored content for a single indexed document.
  Future<Map<String, dynamic>> getDocumentIndexEntry(String filePath) async {
    final db = serverDb;
    final roots = await _getConfiguredDocumentRoots();
    final rootScope = roots.isEmpty
        ? ''
        : ' AND (${roots.map((rp) => "root_path = '${_esc(rp)}'").join(' OR ')})';
    // Try exact path first, then filename, then partial path
    for (final sql in [
      "SELECT file_path, file_name, file_type, content_text, file_size, last_modified FROM document_index WHERE file_path = '${_esc(filePath)}'$rootScope LIMIT 1",
      "SELECT file_path, file_name, file_type, content_text, file_size, last_modified FROM document_index WHERE LOWER(file_name) = '${_esc(filePath.toLowerCase())}'$rootScope LIMIT 1",
      "SELECT file_path, file_name, file_type, content_text, file_size, last_modified FROM document_index WHERE LOWER(file_path) LIKE '%${_esc(filePath.toLowerCase())}%'$rootScope LIMIT 1",
    ]) {
      final rows = await db.query(sql);
      if (rows.isNotEmpty) {
        final r = rows.first;
        return {
          'filePath': r[0],
          'fileName': r[1],
          'fileType': r[2],
          'content': r[3],
          'fileSize': r[4],
          'lastModified': r[5],
        };
      }
    }
    return {'error': 'Document not found: $filePath'};
  }

  // ═══════════════════════════════════════════════════
  // General helpers
  // ═══════════════════════════════════════════════════

  Future<List<String>> _getConfiguredDocumentRoots() async {
    final ds = ServerDataSourcesService.instance;
    await ds.load();
    return ds.documentRootPaths
        .split(';')
        .map((e) => _normalizeRootPath(e.trim()))
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
  }

  Future<String?> _getWebsiteScope() async {
    final ds = ServerDataSourcesService.instance;
    await ds.load();

    final seeds = _parseSeedUrls(
      ds.websiteIndexUrls,
    ).map(_normalizeUrl).toSet().toList();
    if (seeds.isEmpty) {
      // No configured seeds means no rows should be visible.
      return '1=0';
    }

    final seedIn = seeds.map((s) => "'${_esc(s)}'").join(',');
    return 'seed_url IN ($seedIn)';
  }

  String _normalizeRootPath(String path) {
    var p = path.trim();
    while (p.length > 1 && (p.endsWith('/') || p.endsWith('\\'))) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  String _getExtension(String path) {
    final name = path.split('/').last.split('\\').last;
    final dot = name.lastIndexOf('.');
    return dot >= 0 ? name.substring(dot + 1).toLowerCase() : '';
  }

  String _fileName(String path) => path.split('/').last.split('\\').last;

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  String _esc(String s) => s.replaceAll("'", "''");
}
