import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../services/app_logger.dart';
import '../../services/data_sources_settings_service.dart';
import '../internal_mcp_server.dart';

/// Internal MCP server for web search outside indexed websites.
///
/// Provider selection:
/// 1) SerpApi (https://serpapi.com) if configured
/// 2) Serper.dev (if configured)
/// 3) DuckDuckGo fallback
class WebSearchMcpServer extends InternalMcpServer {
  String _providerPreference = 'auto'; // auto | serpapi | serper | duckduckgo | custom
  int _defaultMaxResults = 5;

  @override
  String get type => 'web_search';

  @override
  String get displayName => 'Web Search';

  @override
  String get description =>
      'Search the public web. Uses SerpApi (Google Search) if configured, '
      'then Serper.dev, otherwise falls back to DuckDuckGo.';

  @override
  String get iconName => 'search';

  @override
  Map<String, dynamic> get initParamSchema => {
    'type': 'object',
    'properties': {
      'provider': {
        'type': 'string',
        'enum': ['auto', 'serpapi', 'serper', 'duckduckgo', 'custom'],
        'default': 'auto',
        'description': 'Preferred search provider. auto = use global settings/fallback.',
      },
      'maxResults': {'type': 'integer', 'default': 5, 'description': 'Default max result count (1-20).'},
    },
    'required': [],
  };

  @override
  Map<String, dynamic> get defaultInitParams => {'provider': 'auto', 'maxResults': 5};

  @override
  String get defaultSystemPrompt =>
      'You have access to the web_search tool. Use it proactively whenever the user asks '
      'about current events, prices, flights, weather, news, travel, products, or any topic '
      'that benefits from up-to-date information. Do NOT refuse to search — just call web_search. '
      'CRITICAL: ONLY output URLs that were returned verbatim by the web_search tool. '
      'NEVER generate, guess, recall, or construct URLs from your training knowledge — '
      'doing so produces broken links. If a search returns 0 results, say so honestly '
      'instead of inventing sources. '
      'SEARCH STRATEGY: Use broad, natural-language queries. '
      'NEVER use site: operators unless the user explicitly names a specific website. '
      'If a query returns 0 results, try ONE simplified query without modifiers, '
      'then summarize what was found — do NOT keep retrying with minor variations.';

  @override
  Future<void> initialize(Map<String, dynamic> initParams) async {
    _providerPreference = (initParams['provider'] as String? ?? 'auto').trim().toLowerCase();
    if (_providerPreference == 'google') {
      _providerPreference = 'serpapi';
    }
    if (!{'auto', 'serpapi', 'serper', 'duckduckgo', 'custom'}.contains(_providerPreference)) {
      _providerPreference = 'auto';
    }

    _defaultMaxResults = ((initParams['maxResults'] as int?) ?? 5).clamp(1, 20);
    log.info('[Web Search MCP] Initialized provider=$_providerPreference, maxResults=$_defaultMaxResults');
  }

  @override
  List<McpToolDescriptor> get tools => [
    const McpToolDescriptor(
      name: 'web_search',
      description:
          'Search the public web for any information: news, prices, flights, travel, products, etc. '
          'Uses SerpApi (Google Search) if configured, then Serper.dev, otherwise DuckDuckGo.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'description': 'Search query string.'},
          'maxResults': {'type': 'integer', 'description': 'Maximum results (default from MCP config, max 20).'},
          'provider': {
            'type': 'string',
            'enum': ['auto', 'serpapi', 'serper', 'duckduckgo', 'custom'],
            'description': 'Optional per-call provider override.',
          },
        },
        'required': ['query'],
      },
    ),
  ];

  @override
  Future<Map<String, dynamic>> executeTool(String toolName, Map<String, dynamic> arguments) async {
    switch (toolName) {
      case 'web_search':
        return _webSearch(arguments);
      default:
        return {'error': 'Unknown tool: $toolName'};
    }
  }

  Future<Map<String, dynamic>> _webSearch(Map<String, dynamic> args) async {
    final query = (args['query'] as String?)?.trim();
    if (query == null || query.isEmpty) {
      return {'error': 'Parameter "query" is required.'};
    }

    final maxResults = ((args['maxResults'] as int?) ?? _defaultMaxResults).clamp(1, 20);
    final providerOverride = (args['provider'] as String?)?.trim().toLowerCase();
    final normalizedOverride = providerOverride == 'google' ? 'serper' : providerOverride;
    final provider = normalizedOverride != null && normalizedOverride.isNotEmpty ? normalizedOverride : _providerPreference;

    final ds = DataSourcesSettingsService.instance;
    if (!ds.isLoaded) {
      await ds.load();
    }
    final serpapiConfigured = ds.webSearchProvider == WebSearchProvider.serpapi && ds.isWebSearchConfigured;
    final serperConfigured = ds.webSearchProvider == WebSearchProvider.serper && ds.isWebSearchConfigured;
    final customConfigured = ds.webSearchProvider == WebSearchProvider.custom && ds.isWebSearchConfigured;

    if (provider == 'custom' || (provider == 'auto' && customConfigured)) {
      final result = await _searchCustomProvider(query, maxResults, ds);
      if (result['error'] == null) return result;

      if (provider == 'custom') return result;
      log.warning('[Web Search MCP] Custom provider failed, using DuckDuckGo fallback: ${result['error']}');
    }

    if (provider == 'serpapi' || (provider == 'auto' && serpapiConfigured)) {
      final result = await _searchSerpApi(query, maxResults, ds);
      if (result['error'] == null) return result;

      if (provider == 'serpapi') return result;
      log.warning('[Web Search MCP] SerpApi failed, trying Serper fallback: ${result['error']}');
    }

    if (provider == 'serper' || (provider == 'auto' && serperConfigured)) {
      final result = await _searchSerper(query, maxResults, ds);
      if (result['error'] == null) return result;

      if (provider == 'serper') return result; // explicit serper request should not silently switch
      log.warning('[Web Search MCP] Serper failed, using DuckDuckGo fallback: ${result['error']}');
    }

    return _searchDuckDuckGo(query, maxResults);
  }

  Future<Map<String, dynamic>> _searchSerpApi(String query, int maxResults, DataSourcesSettingsService ds) async {
    final apiKey = ds.webSearchApiKey.trim();
    if (apiKey.isEmpty) {
      return {'error': 'SerpApi is not configured (missing API key).'};
    }

    final clampedMax = maxResults.clamp(1, 20);
    final uri = Uri.parse(
      'https://serpapi.com/search',
    ).replace(queryParameters: {'engine': 'google', 'q': query, 'num': '$clampedMax', 'api_key': apiKey});

    log.info('[Web Search MCP] SerpApi request: q=$query, num=$clampedMax');

    try {
      final response = await http.get(uri, headers: {'Accept': 'application/json'});
      final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final errorMsg = (data['error'] ?? data['message'] ?? response.reasonPhrase ?? 'unknown').toString();
        log.error('[Web Search MCP] SerpApi error ${response.statusCode}: $errorMsg');
        return {'error': 'SerpApi error ${response.statusCode}: $errorMsg'};
      }

      final raw = (data['organic_results'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .take(clampedMax)
          .map(
            (item) => {
              'title': item['title']?.toString() ?? '',
              'url': item['link']?.toString() ?? '',
              'snippet': item['snippet']?.toString() ?? '',
              'displayLink': item['displayed_link']?.toString() ?? '',
            },
          )
          .toList();

      final items = await _filterValidUrls(raw);
      return {'providerUsed': 'serpapi', 'query': query, 'returned': items.length, 'results': items};
    } catch (e) {
      return {'error': 'SerpApi web search failed: $e'};
    }
  }

  Future<Map<String, dynamic>> _searchSerper(String query, int maxResults, DataSourcesSettingsService ds) async {
    final apiKey = ds.webSearchApiKey.trim();

    if (apiKey.isEmpty) {
      return {'error': 'Serper.dev is not configured (missing API key).'};
    }

    final clampedMax = maxResults.clamp(1, 20);
    final uri = Uri.parse('https://google.serper.dev/search');

    log.info('[Web Search MCP] Serper request: q=$query, num=$clampedMax');

    try {
      final response = await http.post(
        uri,
        headers: {'Accept': 'application/json', 'Content-Type': 'application/json', 'X-API-KEY': apiKey},
        body: jsonEncode({'q': query, 'num': clampedMax}),
      );
      final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final errorMsg = (data['message'] ?? data['error'] ?? response.reasonPhrase ?? 'unknown').toString();
        log.error('[Web Search MCP] Serper error ${response.statusCode}: $errorMsg');
        return {'error': 'Serper search error ${response.statusCode}: $errorMsg'};
      }

      final raw = (data['organic'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(
            (item) => {
              'title': item['title']?.toString() ?? '',
              'url': item['link']?.toString() ?? '',
              'snippet': item['snippet'] ?? '',
              'displayLink': item['link']?.toString() ?? '',
            },
          )
          .toList();

      final items = await _filterValidUrls(raw);
      return {'providerUsed': 'serper', 'query': query, 'returned': items.length, 'results': items};
    } catch (e) {
      return {'error': 'Serper web search failed: $e'};
    }
  }

  Future<Map<String, dynamic>> _searchDuckDuckGo(String query, int maxResults) async {
    final uri = Uri.parse(
      'https://api.duckduckgo.com/',
    ).replace(queryParameters: {'q': query, 'format': 'json', 'no_html': '1', 'no_redirect': '1'});

    try {
      final response = await http.get(uri, headers: {'Accept': 'application/json'});
      final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return {'error': 'DuckDuckGo search error ${response.statusCode}: ${response.reasonPhrase}'};
      }

      final results = <Map<String, dynamic>>[];

      final heading = (data['Heading'] ?? '').toString();
      final abstract = (data['AbstractText'] ?? '').toString();
      final abstractUrl = (data['AbstractURL'] ?? '').toString();
      if (heading.isNotEmpty || abstract.isNotEmpty) {
        results.add({'title': heading, 'url': abstractUrl, 'snippet': abstract});
      }

      final relatedTopics = data['RelatedTopics'] as List<dynamic>? ?? const [];
      for (final topic in relatedTopics) {
        if (results.length >= maxResults) break;

        if (topic is Map<String, dynamic>) {
          if (topic.containsKey('Topics')) {
            final nested = topic['Topics'] as List<dynamic>? ?? const [];
            for (final nestedTopic in nested.whereType<Map<String, dynamic>>()) {
              if (results.length >= maxResults) break;
              final text = (nestedTopic['Text'] ?? '').toString();
              final url = (nestedTopic['FirstURL'] ?? '').toString();
              if (text.isNotEmpty || url.isNotEmpty) {
                results.add({'title': text.split('-').first.trim(), 'url': url, 'snippet': text});
              }
            }
          } else {
            final text = (topic['Text'] ?? '').toString();
            final url = (topic['FirstURL'] ?? '').toString();
            if (text.isNotEmpty || url.isNotEmpty) {
              results.add({'title': text.split('-').first.trim(), 'url': url, 'snippet': text});
            }
          }
        }
      }

      return {
        'providerUsed': 'duckduckgo',
        'query': query,
        'returned': results.take(maxResults).length,
        'results': await _filterValidUrls(results.take(maxResults).toList()),
      };
    } catch (e) {
      log.error('[Web Search MCP] DuckDuckGo failed: $e');
      return {'error': 'DuckDuckGo web search failed: $e'};
    }
  }

  Future<Map<String, dynamic>> _searchCustomProvider(String query, int maxResults, DataSourcesSettingsService ds) async {
    final endpointRaw = ds.webSearchCustomEndpoint.trim();
    if (endpointRaw.isEmpty) {
      return {'error': 'Custom provider endpoint is not configured.'};
    }

    Uri endpoint;
    try {
      endpoint = Uri.parse(endpointRaw);
    } catch (_) {
      return {'error': 'Custom provider endpoint is invalid.'};
    }

    if (!endpoint.hasScheme || (endpoint.scheme != 'http' && endpoint.scheme != 'https')) {
      return {'error': 'Custom provider endpoint must use http or https.'};
    }

    final apiKey = ds.webSearchApiKey.trim();
    final requestUri = endpoint.replace(queryParameters: {...endpoint.queryParameters, 'q': query, 'maxResults': '$maxResults'});

    try {
      final response = await http.get(
        requestUri,
        headers: {
          'Accept': 'application/json',
          if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
          if (apiKey.isNotEmpty) 'X-API-Key': apiKey,
        },
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return {'error': 'Custom provider error ${response.statusCode}: ${response.reasonPhrase}'};
      }

      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      List<dynamic> rows;
      if (decoded is List) {
        rows = decoded;
      } else if (decoded is Map<String, dynamic>) {
        rows = (decoded['results'] as List?) ?? (decoded['items'] as List?) ?? (decoded['data'] as List?) ?? const <dynamic>[];
      } else {
        rows = const <dynamic>[];
      }

      final results = rows
          .whereType<Map>()
          .map((item) {
            final map = Map<String, dynamic>.from(item);
            return {
              'title': (map['title'] ?? map['name'] ?? '').toString(),
              'url': (map['url'] ?? map['link'] ?? '').toString(),
              'snippet': (map['snippet'] ?? map['description'] ?? map['text'] ?? '').toString(),
            };
          })
          .where((row) => (row['title']?.toString().isNotEmpty ?? false) || (row['url']?.toString().isNotEmpty ?? false))
          .toList();

      return {
        'providerUsed': ds.webSearchCustomProviderName.trim().isNotEmpty ? ds.webSearchCustomProviderName.trim() : 'custom',
        'query': query,
        'returned': results.take(maxResults).length,
        'results': await _filterValidUrls(results.take(maxResults).toList()),
      };
    } catch (e) {
      return {'error': 'Custom provider search failed: $e'};
    }
  }

  // ── URL validation ────────────────────────────────────────────────────────

  /// Checks each result URL with a HEAD request (GET fallback) in parallel.
  /// Results whose URLs return 4xx/5xx or time out are removed so they are
  /// never shown to the user or the LLM.
  Future<List<Map<String, dynamic>>> _filterValidUrls(
    List<Map<String, dynamic>> results, {
    Duration timeout = const Duration(seconds: 6),
  }) async {
    if (results.isEmpty) return results;

    final futures = results.map((item) async {
      final rawUrl = (item['url'] as String? ?? '').trim();
      if (rawUrl.isEmpty) return null; // drop empty URLs

      Uri uri;
      try {
        uri = Uri.parse(rawUrl);
      } catch (_) {
        return null;
      }
      if (uri.scheme != 'http' && uri.scheme != 'https') return item; // keep non-http (shouldn't happen)

      try {
        // Try HEAD first (cheap), fall back to GET if HEAD is not allowed.
        http.Response response;
        try {
          response = await http
              .head(uri, headers: {'User-Agent': 'Mozilla/5.0 (compatible; TealKit/1.0)', 'Accept': 'text/html,application/xhtml+xml,*/*'})
              .timeout(timeout);
        } catch (_) {
          // HEAD failed (network / timeout) — try GET with byte limit.
          response = await http
              .get(
                uri,
                headers: {
                  'User-Agent': 'Mozilla/5.0 (compatible; TealKit/1.0)',
                  'Accept': 'text/html,application/xhtml+xml,*/*',
                  'Range': 'bytes=0-0', // request only the first byte
                },
              )
              .timeout(timeout);
        }

        // 4xx (client error) = page not found / forbidden → drop.
        // 5xx (server error) → drop.
        // 3xx redirects are followed automatically by the http package.
        if (response.statusCode >= 400) {
          log.info('[Web Search MCP] Dropping URL with status ${response.statusCode}: $rawUrl');
          return null;
        }
        return item;
      } catch (e) {
        // Network error / timeout — keep the result to avoid over-filtering
        // on slow connections. The LLM may still be able to use the snippet.
        log.info('[Web Search MCP] URL check timed out / failed for $rawUrl: $e — keeping');
        return item;
      }
    });

    final checked = await Future.wait(futures);
    return checked.whereType<Map<String, dynamic>>().toList();
  }
}
