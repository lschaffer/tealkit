import 'dart:collection';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../database/duckdb_service.dart';
import '../../services/app_logger.dart';
import '../../services/data_sources_settings_service.dart';
import '../../services/server_api_client.dart';
import '../../utils/semantic_embedding.dart';
import '../internal_mcp_server.dart';

/// Internal MCP server for indexing and searching predefined websites.
class WebsiteSearchMcpServer extends InternalMcpServer {
  final List<Uri> _seedUrls = [];
  int _maxPages = 100;
  String _indexingStrategy = 'now';
  bool _indexed = false;
  bool _cancelRequested = false;

  /// Callback fired after each page is indexed: (indexed, total, currentUrl).
  void Function(int indexed, int total, String currentUrl)? onIndexProgress;

  /// Request cancellation of an in-progress indexing run.
  void cancelIndexing() => _cancelRequested = true;

  @override
  String get type => 'website_search';

  @override
  String get displayName => 'Website Search';

  @override
  String get description =>
      'Index predefined websites into DuckDB and search across indexed web content '
      'with hybrid semantic + keyword ranking.';

  @override
  String get iconName => 'language';

  @override
  Map<String, dynamic> get initParamSchema => {
    'type': 'object',
    'properties': {
      'websiteUrls': {
        'type': 'string',
        'description':
            'Comma-separated seed URLs to index, e.g. "https://example.com/docs, https://mysite.org". '
            'Maximum 3 websites.',
      },
      'maxPages': {
        'type': 'integer',
        'description':
            'Maximum number of pages to crawl (default 100, max 1000).',
        'default': 100,
      },
      'indexingStrategy': {
        'type': 'string',
        'enum': ['now', 'before_first_run'],
        'default': 'before_first_run',
        'description': 'Index immediately or lazily before first query.',
      },
    },
    'required': ['websiteUrls'],
  };

  @override
  Map<String, dynamic> get defaultInitParams => {
    'websiteUrls': '',
    'maxPages': 100,
    'indexingStrategy': 'before_first_run',
  };

  @override
  String get defaultSystemPrompt {
    final domains = _seedUrls.map((u) => u.host).join(', ');
    final domainList = _seedUrls.isNotEmpty
        ? 'The index contains pages from: $domains.'
        : '';
    return '$domainList\n'
        'SEARCH RULES — follow strictly:\n'
        '1. Use ONLY simple 1-3 word topic queries in the language of the indexed site. '
        '   Examples: "Politik", "Wirtschaft", "Sport", "Innenpolitik". '
        '   NEVER use boolean syntax (OR, AND, parentheses), field names, or time phrases.\n'
        '2. If totalResults is 0 but indexedDomains shows pages exist, the page content '
        '   may be navigation-only. Try an even simpler 1-word query or use list_indexed_pages '
        '   to browse titles directly.\n'
        '3. Do ONE broad search, then ONE per domain that had no results. '
        '   STOP after 3 total calls — never repeat the same query.\n'
        '4. NEVER suggest, recommend, or output any website URL that did not come from '
        '   a tool result. If no results are found, say so plainly and stop.\n'
        '5. Format every URL from results as a Markdown link: [Title](https://...)';
  }

  @override
  Future<void> initialize(Map<String, dynamic> initParams) async {
    _seedUrls
      ..clear()
      ..addAll(
        _parseSeedUrls((initParams['websiteUrls'] as String? ?? '').trim()),
      );

    final rawMaxPages = initParams['maxPages'];
    final parsedMaxPages = switch (rawMaxPages) {
      int value => value,
      num value => value.toInt(),
      String value => int.tryParse(value.trim()) ?? 100,
      _ => 100,
    };
    _maxPages = parsedMaxPages.clamp(1, 1000);
    _indexingStrategy = (initParams['indexingStrategy'] as String? ?? 'now')
        .trim();
    if (_indexingStrategy != 'before_first_run' &&
        _indexingStrategy != 'none') {
      _indexingStrategy = 'now';
    }

    // In server/remote mode the index lives on the server — skip local crawling.
    final prefs = await SharedPreferences.getInstance();
    final isRemote = (prefs.getString('server_mode') ?? 'local') == 'remote';
    if (isRemote) {
      _indexed = true;
      log.info(
        '[Website Search MCP] Server mode: skipping local indexing; queries will use server DuckDB.',
      );
      return;
    }

    await _ensureTable();

    if (_indexingStrategy == 'now' && _seedUrls.isNotEmpty) {
      await _indexWebsites();
    } else if (_indexingStrategy == 'before_first_run' &&
        _seedUrls.isNotEmpty) {
      try {
        final seedIn = _seedUrls
            .map((s) => "'${_esc(_normalizeUrl(s))}'")
            .join(',');
        final rows = await DuckDbService().query(
          'SELECT COUNT(*) FROM website_index WHERE seed_url IN ($seedIn)',
        );
        final count = rows.isNotEmpty
            ? int.tryParse(rows.first.first.toString()) ?? 0
            : 0;
        if (count > 0) {
          _indexed = true;
          log.info(
            '[Website Search MCP] Already indexed $count pages for configured seeds; skipping lazy re-indexing.',
          );
        }
      } catch (e) {
        log.warning(
          '[Website Search MCP] Failed to check existing index count: $e',
        );
      }
    } else if (_indexingStrategy == 'none') {
      // Background mode: use whatever is already in the DB, don't re-index.
      _indexed = true;
    }

    log.info(
      '[Website Search MCP] Initialized with ${_seedUrls.length} seed(s), maxPages=$_maxPages, strategy=$_indexingStrategy',
    );
  }

  @override
  String? validateInitParams(Map<String, dynamic> params) {
    final raw = (params['websiteUrls'] as String? ?? '').trim();
    final seeds = _parseSeedUrls(raw);

    if (seeds.isEmpty) {
      return 'websiteUrls is required (comma-separated list of URLs).';
    }
    if (seeds.length > 3) {
      return 'Maximum 3 website URLs are allowed per task.';
    }
    return null;
  }

  @override
  List<McpToolDescriptor> get tools => [
    const McpToolDescriptor(
      name: 'index_websites',
      description:
          'Crawl and index websites into DuckDB. Use the "sites" parameter to specify which websites to index.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'sites': {
            'type': 'string',
            'description':
                'Comma-separated list of website URLs to index (e.g. "https://example.com, https://other.org"). If omitted, uses configured website URLs.',
          },
        },
        'required': [],
      },
    ),
    const McpToolDescriptor(
      name: 'reindex_websites',
      description:
          'Rebuild the website index. Use the "sites" parameter to specify which websites to reindex.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'sites': {
            'type': 'string',
            'description':
                'Comma-separated list of website URLs to reindex (e.g. "https://example.com, https://other.org"). If omitted, uses configured website URLs.',
          },
        },
        'required': [],
      },
    ),
    const McpToolDescriptor(
      name: 'purge_stale_index',
      description:
          'Delete indexed website rows that no longer belong to currently configured seed URLs.',
      inputSchema: {'type': 'object', 'properties': {}, 'required': []},
    ),
    const McpToolDescriptor(
      name: 'list_indexed_pages',
      description: 'List pages currently indexed.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'domain': {
            'type': 'string',
            'description': 'Optional domain filter (e.g. example.com).',
          },
          'limit': {'type': 'integer', 'default': 50},
        },
        'required': [],
      },
    ),
    const McpToolDescriptor(
      name: 'search_indexed_websites',
      description:
          'Search indexed website content with hybrid semantic ranking.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'query': {'type': 'string'},
          'domain': {'type': 'string'},
          'limit': {'type': 'integer', 'default': 20},
          'searchMode': {
            'type': 'string',
            'enum': ['keyword', 'semantic', 'hybrid'],
            'default': 'hybrid',
          },
        },
        'required': ['query'],
      },
    ),
    const McpToolDescriptor(
      name: 'get_indexed_page',
      description: 'Get full stored content for one indexed URL.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'url': {'type': 'string'},
        },
        'required': ['url'],
      },
    ),
  ];

  @override
  Future<Map<String, dynamic>> executeTool(
    String toolName,
    Map<String, dynamic> arguments,
  ) async {
    if (!_indexed &&
        _indexingStrategy == 'before_first_run' &&
        toolName != 'index_websites' &&
        toolName != 'reindex_websites') {
      await _indexWebsites(arguments);
    }

    switch (toolName) {
      case 'index_websites':
      case 'reindex_websites':
        return _indexWebsites(arguments);
      case 'purge_stale_index':
        return _purgeStaleIndex();
      case 'list_indexed_pages':
        return _listIndexedPages(arguments);
      case 'search_indexed_websites':
        return _searchIndexedWebsites(arguments);
      case 'get_indexed_page':
        return _getIndexedPage(arguments);
      default:
        return {'error': 'Unknown tool: $toolName'};
    }
  }

  /// Build a [ServerApiClient] from stored SharedPreferences. Returns null if server URL is empty.
  ServerApiClient? _buildServerClient(SharedPreferences prefs) {
    final url = (prefs.getString('server_url') ?? '').trim();
    if (url.isEmpty) return null;
    final key = prefs.getString('server_api_key');
    return ServerApiClient(
      serverUrl: url,
      apiKey: key?.isNotEmpty == true ? key : null,
    );
  }

  Future<void> _ensureTable() async {
    final db = DuckDbService();
    await db.execute('''
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
  }

  Future<Map<String, dynamic>> _indexWebsites([
    Map<String, dynamic> arguments = const {},
  ]) async {
    _cancelRequested = false;

    // Handle optional sites parameter — overrides configured _seedUrls.
    final sitesParam = (arguments['sites'] as String?)?.trim();
    List<Uri> effectiveSeeds;
    final isSitesOverride = sitesParam != null && sitesParam.isNotEmpty;
    if (isSitesOverride) {
      effectiveSeeds = _parseSeedUrls(sitesParam);
      if (effectiveSeeds.isEmpty) {
        return {'error': 'No valid website URLs found in sites parameter.'};
      }
    } else {
      effectiveSeeds = _seedUrls;
    }

    if (effectiveSeeds.isEmpty) {
      return {'error': 'No valid website URLs configured.'};
    }

    final db = DuckDbService();
    final prefs = await SharedPreferences.getInstance();
    final isRemote = (prefs.getString('server_mode') ?? 'local') == 'remote';
    // Use warning level so this appears in Talker even in release builds.
    log.warning(
      '[WebsiteIndex] Starting indexing. '
      'Server mode: ${isRemote ? "REMOTE (server)" : "LOCAL"}. '
      'Local DuckDB path: ${db.dbPath ?? "(not yet opened)"}. '
      'Seeds: ${effectiveSeeds.map((u) => u.toString()).join(", ")}. '
      'Max pages per seed: $_maxPages.',
    );
    if (isRemote) {
      log.warning(
        '[WebsiteIndex] IMPORTANT: Running in REMOTE/server mode but website indexing '
        'always uses the LOCAL app DuckDB, NOT the remote server DuckDB. '
        'Indexed pages will NOT be available to server-side task runs.',
      );
    }
    final ds = DataSourcesSettingsService.instance;
    if (!ds.isLoaded) {
      await ds.load();
    }
    final maxIndexBytes = (ds.duckDbIndexSizeLimitGb * 1024 * 1024 * 1024)
        .round();
    final stopwatch = Stopwatch()..start();

    final normalizedSeeds = effectiveSeeds.map(_normalizeUrl).toSet().toList();

    // Remove stale rows for removed seeds and fully refresh current seeds.
    if (normalizedSeeds.isNotEmpty) {
      try {
        final seedIn = normalizedSeeds.map((s) => "'${_esc(s)}'").join(',');
        await db.execute(
          'DELETE FROM website_index WHERE seed_url NOT IN ($seedIn)',
        );
        await db.execute(
          'DELETE FROM website_index WHERE seed_url IN ($seedIn)',
        );
      } catch (e) {
        log.warning(
          '[Website Search MCP] Failed to clear old website rows: $e',
        );
      }
    }

    final queue = Queue<_CrawlItem>();
    final visited = <String>{};
    final allowedDomains = effectiveSeeds
        .map((u) => u.host.toLowerCase())
        .toSet();

    for (final seed in effectiveSeeds) {
      queue.add(_CrawlItem(seed: seed, url: seed));
    }

    int indexed = 0;
    int failed = 0;
    int indexedBytes = 0;
    bool sizeLimitReached = false;
    // _maxPages is per-seed; track per-seed counts separately.
    final perSeedIndexed = <String, int>{
      for (final s in effectiveSeeds) _normalizeUrl(s): 0,
    };
    final estimatedTotal = effectiveSeeds.length * _maxPages;
    onIndexProgress?.call(0, estimatedTotal, '');

    while (queue.isNotEmpty) {
      if (_cancelRequested) break;

      // Stop when every seed has reached its per-seed limit.
      if (perSeedIndexed.values.every((n) => n >= _maxPages)) break;

      final item = queue.removeFirst();
      final seedKey = _normalizeUrl(item.seed);

      // Skip if this seed already hit its page limit.
      if ((perSeedIndexed[seedKey] ?? 0) >= _maxPages) continue;

      final normalizedUrl = _normalizeUrl(item.url);

      if (visited.contains(normalizedUrl)) continue;
      visited.add(normalizedUrl);

      if (!_isAllowed(item.url, allowedDomains)) continue;

      final page = await _fetchPage(item.url);
      if (page == null) {
        failed++;
        continue;
      }

      final pageBytes = utf8.encode(page.text).length;
      if (indexedBytes + pageBytes > maxIndexBytes) {
        sizeLimitReached = true;
        break;
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
        indexedBytes += pageBytes;
        onIndexProgress?.call(indexed, estimatedTotal, normalizedUrl);
      } catch (e) {
        failed++;
        log.warning(
          '[Website Search MCP] Failed to persist indexed page $normalizedUrl: $e',
        );
        continue;
      }

      // Add outgoing links only if this seed still has budget remaining.
      final remaining = _maxPages - (perSeedIndexed[seedKey] ?? 0);
      if (remaining > 0) {
        for (final link in page.links) {
          queue.add(_CrawlItem(seed: item.seed, url: link));
        }
      }

      await Future<void>.delayed(Duration.zero);
    }

    stopwatch.stop();
    final wasCancelled = _cancelRequested;
    _cancelRequested = false;
    if (!wasCancelled) _indexed = true;

    log.warning(
      '[WebsiteIndex] Indexing ${wasCancelled ? "CANCELLED" : "COMPLETE"}. '
      'Indexed: $indexed pages, Failed: $failed, '
      'Size: ${(indexedBytes / 1024 / 1024).toStringAsFixed(1)} MB, '
      'Duration: ${stopwatch.elapsedMilliseconds} ms. '
      'Stored in LOCAL DuckDB: ${db.dbPath ?? "(unknown)"}.',
    );

    return {
      'status': wasCancelled ? 'cancelled' : 'complete',
      'cancelled': wasCancelled,
      'seedUrls': _seedUrls.map((u) => u.toString()).toList(),
      'indexedPages': indexed,
      'failedPages': failed,
      'sizeLimitReached': sizeLimitReached,
      'maxIndexBytes': maxIndexBytes,
      'indexedBytes': indexedBytes,
      'maxPages': _maxPages,
      'durationMs': stopwatch.elapsedMilliseconds,
      'duckDbPath': db.dbPath,
      'serverMode': isRemote,
    };
  }

  Future<Map<String, dynamic>> _purgeStaleIndex() async {
    final prefs = await SharedPreferences.getInstance();
    final isRemote = (prefs.getString('server_mode') ?? 'local') == 'remote';
    if (isRemote) {
      final client = _buildServerClient(prefs);
      if (client == null) return {'error': 'Server not configured.'};
      return client.purgeStaleWebsiteIndex();
    }

    final db = DuckDbService();
    final seeds = _seedUrls.map(_normalizeUrl).toSet().toList();
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

  Future<Map<String, dynamic>> _listIndexedPages(
    Map<String, dynamic> args,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final isRemote = (prefs.getString('server_mode') ?? 'local') == 'remote';
    if (isRemote) {
      final client = _buildServerClient(prefs);
      if (client == null) return {'error': 'Server not configured.'};
      final domain = (args['domain'] as String?)?.trim().toLowerCase();
      final limit = ((args['limit'] as int?) ?? 50).clamp(1, 500);
      return client.listWebsiteIndexPages(
        domain: domain?.isEmpty == true ? null : domain,
        limit: limit,
      );
    }

    final domain = (args['domain'] as String?)?.trim().toLowerCase();
    final limit = ((args['limit'] as int?) ?? 50).clamp(1, 500);

    final db = DuckDbService();
    final where = StringBuffer('WHERE ${_websiteSeedScopeClause()}');
    if (domain != null && domain.isNotEmpty) {
      where.write(" AND domain = '${_esc(domain)}'");
    }

    final rows = await db.query('''
      SELECT url, domain, title, http_status, indexed_at
      FROM website_index
      $where
      ORDER BY indexed_at DESC
      LIMIT $limit
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

  Future<Map<String, dynamic>> _searchIndexedWebsites(
    Map<String, dynamic> args,
  ) async {
    final rawQuery = (args['query'] as String?)?.trim();
    if (rawQuery == null || rawQuery.isEmpty) {
      return {'error': 'Parameter "query" is required.'};
    }

    final prefs = await SharedPreferences.getInstance();
    final isRemote = (prefs.getString('server_mode') ?? 'local') == 'remote';
    if (isRemote) {
      final client = _buildServerClient(prefs);
      if (client == null) return {'error': 'Server not configured.'};
      final domain = (args['domain'] as String?)?.trim().toLowerCase();
      final limit = ((args['limit'] as int?) ?? 20).clamp(1, 200);
      final mode = (args['searchMode'] as String? ?? 'hybrid').toLowerCase();
      return client.searchWebsiteIndex(
        query: rawQuery,
        domain: domain?.isEmpty == true ? null : domain,
        limit: limit,
        searchMode: mode,
      );
    }

    // Strip boolean operators / parentheses / field names the LLM sometimes injects.
    final query = rawQuery
        .replaceAll(RegExp(r'\b(OR|AND|NOT)\b'), ' ')
        .replaceAll(RegExp(r'[()\[\]]'), ' ')
        .replaceAll(
          RegExp(
            r'\b(Titel|Überschrift|Lead|Teaser|Vorspann|Schlagzeile)\b',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();

    final domain = (args['domain'] as String?)?.trim().toLowerCase();
    final limit = ((args['limit'] as int?) ?? 20).clamp(1, 200);
    final mode = (args['searchMode'] as String? ?? 'hybrid').toLowerCase();

    final db = DuckDbService();
    final where = StringBuffer(
      "WHERE ${_websiteSeedScopeClause()} AND content_text IS NOT NULL AND content_text != ''",
    );
    if (domain != null && domain.isNotEmpty) {
      where.write(" AND domain = '${_esc(domain)}'");
    }

    final rows = await db.query('''
      SELECT url, domain, title, content_text, embedding_json, indexed_at
      FROM website_index
      $where
    ''');

    final queryEmbedding = SemanticEmbedding.buildEmbedding(query);
    final matches = <Map<String, dynamic>>[];

    for (final row in rows) {
      final content = (row[3] ?? '').toString();
      if (content.isEmpty) continue;

      // Skip pages whose URL path indicates a non-article page (author profiles,
      // tag pages, cookie notices, etc.) that slipped through the crawl filter.
      final rowUrl = (row[0] ?? '').toString();
      final rowPathParts = (Uri.tryParse(rowUrl)?.path.toLowerCase() ?? '')
          .split('/')
          .where((s) => s.isNotEmpty);
      if (rowPathParts.any(
        (seg) => _kSkipPathSegments.contains(seg.split('?').first),
      )) {
        continue;
      }

      final docEmbedding = SemanticEmbedding.fromJson(row[4]?.toString());
      final semanticScore = SemanticEmbedding.cosineSimilarity(
        queryEmbedding,
        docEmbedding,
      );
      final keywordScore = SemanticEmbedding.keywordOverlapScore(
        query,
        content,
      );
      final lexicalMatches = _countMatches(content, query);

      final relevance = switch (mode) {
        'keyword' => keywordScore + (lexicalMatches * 0.02),
        'semantic' => semanticScore,
        _ =>
          (0.65 * semanticScore) +
              (0.30 * keywordScore) +
              (0.05 * lexicalMatches),
      };

      // Filter obviously irrelevant results; keep anything with at least one keyword hit.
      if (lexicalMatches == 0 && relevance < 0.12) continue;

      matches.add({
        'url': row[0],
        'domain': row[1],
        'title': row[2],
        'excerpt': _buildExcerpt(content, query),
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

    // Always include per-domain index stats so the AI can self-diagnose 0-result responses.
    final db2 = DuckDbService();
    final domainRows = await db2.query(
      'SELECT domain, COUNT(*) as cnt FROM website_index WHERE ${_websiteSeedScopeClause()} GROUP BY domain ORDER BY cnt DESC',
    );
    final indexedDomains = {for (final r in domainRows) r[0].toString(): r[1]};

    // If strict filtering produced 0 results but the index has pages, fall back to
    // returning the top results by pure semantic score so the AI always has something.
    List<Map<String, dynamic>> finalResults = matches;
    bool usedFallback = false;
    if (matches.isEmpty && rows.isNotEmpty) {
      usedFallback = true;
      final fallback = <Map<String, dynamic>>[];
      for (final row in rows) {
        final rowUrl = (row[0] ?? '').toString();
        final rowPathParts = (Uri.tryParse(rowUrl)?.path.toLowerCase() ?? '')
            .split('/')
            .where((s) => s.isNotEmpty);
        if (rowPathParts.any(
          (seg) => _kSkipPathSegments.contains(seg.split('?').first),
        )) {
          continue;
        }
        final content = (row[3] ?? '').toString();
        if (content.isEmpty) continue;
        final docEmbedding = SemanticEmbedding.fromJson(row[4]?.toString());
        final queryEmbedding2 = SemanticEmbedding.buildEmbedding(query);
        final score = SemanticEmbedding.cosineSimilarity(
          queryEmbedding2,
          docEmbedding,
        );
        fallback.add({
          'url': row[0],
          'domain': row[1],
          'title': row[2],
          'excerpt': _buildExcerpt(content, query),
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

    // Include sample titles so the AI can see what IS in the index.
    final sampleRows = await db2.query(
      'SELECT title, domain FROM website_index WHERE ${_websiteSeedScopeClause()} AND title IS NOT NULL AND title != \'\' LIMIT 5',
    );
    final sampleTitles = sampleRows.map((r) => '${r[1]}: ${r[0]}').toList();

    return {
      'query': query,
      'originalQuery': rawQuery != query ? rawQuery : null,
      'searchMode': mode,
      'totalResults': finalResults.length,
      'usedFallback': usedFallback,
      'results': finalResults,
      'indexedDomains': indexedDomains,
      if (finalResults.isEmpty) 'sampleIndexedTitles': sampleTitles,
    };
  }

  Future<Map<String, dynamic>> _getIndexedPage(
    Map<String, dynamic> args,
  ) async {
    final url = (args['url'] as String?)?.trim();
    if (url == null || url.isEmpty) {
      return {'error': 'Parameter "url" is required.'};
    }

    final prefs = await SharedPreferences.getInstance();
    final isRemote = (prefs.getString('server_mode') ?? 'local') == 'remote';
    if (isRemote) {
      final client = _buildServerClient(prefs);
      if (client == null) return {'error': 'Server not configured.'};
      return client.getWebsiteIndexPage(url);
    }

    final normalized = _normalizeUrl(Uri.parse(url));

    final db = DuckDbService();
    final rows = await db.query('''
      SELECT url, domain, title, content_text, indexed_at
      FROM website_index
      WHERE ${_websiteSeedScopeClause()} AND url = '${_esc(normalized)}'
      LIMIT 1
    ''');

    if (rows.isEmpty) {
      return {'error': 'Indexed page not found: $url'};
    }

    final row = rows.first;
    return {
      'url': row[0],
      'domain': row[1],
      'title': row[2],
      'content': row[3],
      'indexedAt': row[4],
    };
  }

  List<Uri> _parseSeedUrls(String raw) {
    final parts = raw
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .take(10)
        .toList();

    final urls = <Uri>[];
    for (final part in parts) {
      Uri? uri;
      try {
        uri = Uri.parse(part);
      } catch (_) {
        continue;
      }
      if (!uri.hasScheme) {
        uri = Uri.parse('https://$part');
      }
      if (uri.scheme != 'http' && uri.scheme != 'https') continue;
      urls.add(uri);
    }
    return urls;
  }

  bool _isAllowed(Uri url, Set<String> allowedDomains) {
    if (url.scheme != 'http' && url.scheme != 'https') return false;
    final host = url.host.toLowerCase();
    if (allowedDomains.contains(host)) return true;

    for (final domain in allowedDomains) {
      if (host.endsWith('.$domain')) return true;
    }
    return false;
  }

  String _normalizeUrl(Uri uri) {
    final cleaned = uri.removeFragment();
    var asString = cleaned.toString();
    if (asString.endsWith('/')) {
      asString = asString.substring(0, asString.length - 1);
    }
    return asString;
  }

  String _websiteSeedScopeClause() {
    final seeds = _seedUrls.map(_normalizeUrl).toSet().toList();
    if (seeds.isEmpty) return '1=0';
    final seedIn = seeds.map((s) => "'${_esc(s)}'").join(',');
    return 'seed_url IN ($seedIn)';
  }

  Future<_FetchedPage?> _fetchPage(Uri url) async {
    try {
      final response = await http
          .get(url, headers: {'Accept': 'text/html,application/xhtml+xml'})
          .timeout(const Duration(seconds: 20));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }

      // Skip non-HTML content (CSS, JS, images, fonts, etc.)
      final contentType = (response.headers['content-type'] ?? '')
          .toLowerCase();
      if (!contentType.contains('text/html') &&
          !contentType.contains('application/xhtml') &&
          !contentType.contains('text/plain')) {
        return null;
      }

      final body = utf8.decode(response.bodyBytes, allowMalformed: true);
      final title = _extractTitle(body);
      final text = _extractText(body);
      if (text.trim().isEmpty) return null;

      final links = _extractLinks(url, body);

      return _FetchedPage(
        statusCode: response.statusCode,
        title: title,
        text: text,
        links: links,
      );
    } catch (e) {
      log.warning('[Website Search MCP] Failed to fetch $url: $e');
      return null;
    }
  }

  String _extractTitle(String html) {
    final match = RegExp(
      r'<title[^>]*>(.*?)</title>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(html);
    if (match == null) return '';
    return _stripTags(match.group(1) ?? '').trim();
  }

  String _extractText(String html) {
    var text = html;
    text = text.replaceAll(
      RegExp(r'<script[^>]*>.*?</script>', caseSensitive: false, dotAll: true),
      ' ',
    );
    text = text.replaceAll(
      RegExp(r'<style[^>]*>.*?</style>', caseSensitive: false, dotAll: true),
      ' ',
    );
    text = text.replaceAll(
      RegExp(
        r'<noscript[^>]*>.*?</noscript>',
        caseSensitive: false,
        dotAll: true,
      ),
      ' ',
    );
    text = _stripTags(text);
    text = text
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>');
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text;
  }

  String _stripTags(String value) => value.replaceAll(RegExp(r'<[^>]+>'), ' ');

  // URL path segments that indicate non-article pages on news/content sites.
  // These are skipped during both crawling and search result filtering.
  static const _kSkipPathSegments = {
    'autor', 'author', 'autoren', 'redaktion', 'redakteur', // author profiles
    'tag', 'tags', 'thema', 'themen', 'kategorie', 'kategorien', // tag/category
    'suche', 'search', // search pages
    'impressum',
    'datenschutz',
    'agb',
    'kontakt',
    'ueber-uns',
    'about', // legal/contact
    'dsi', 'privacy', 'legal', 'cookie', 'cookies', // privacy pages
    'newsletter', 'abo', 'abonnement', 'subscription', // subscription
    'login', 'signin', 'register', 'konto', 'account', // auth
    'sitemap', 'feed', // sitemaps/feeds
  };

  // Extensions that are never HTML pages — filter them out before crawling.
  static const _kSkipExtensions = {
    'css',
    'js',
    'mjs',
    'ts',
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

  List<Uri> _extractLinks(Uri baseUrl, String html) {
    final links = <Uri>[];
    final regex = RegExp(
      'href\\s*=\\s*["\\\']([^"\\\'#]+)["\\\']',
      caseSensitive: false,
    );

    for (final match in regex.allMatches(html)) {
      final href = (match.group(1) ?? '').trim();
      if (href.isEmpty) continue;
      if (href.startsWith('javascript:') || href.startsWith('mailto:')) {
        continue;
      }
      // Skip unresolved template placeholders (Handlebars/Mustache/Angular/etc.)
      // e.g. {{{post.link.url.full}}} or %7B%7B which is URL-encoded {{
      if (href.contains('{{') ||
          href.contains('}}') ||
          href.contains('%7B%7B') ||
          href.contains('%7D%7D') ||
          href.contains('<%') ||
          href.contains('%>') ||
          href.contains('\${')) {
        continue;
      }

      try {
        final candidate = Uri.parse(href);
        final resolved = candidate.hasScheme
            ? candidate
            : baseUrl.resolveUri(candidate);
        if (resolved.scheme != 'http' && resolved.scheme != 'https') continue;

        // Skip known non-HTML resource extensions.
        final pathSegment = resolved.path.split('/').last.toLowerCase();
        final extIndex = pathSegment.lastIndexOf('.');
        if (extIndex >= 0) {
          final ext = pathSegment.substring(extIndex + 1).split('?').first;
          if (_kSkipExtensions.contains(ext)) continue;
        }

        // Skip non-article path segments (author profiles, tag pages, etc.).
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
      } catch (_) {
        continue;
      }
    }

    return links;
  }

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

  String _esc(String s) => s.replaceAll('\u0000', ' ').replaceAll("'", "''");
}

class _CrawlItem {
  final Uri seed;
  final Uri url;

  _CrawlItem({required this.seed, required this.url});
}

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
