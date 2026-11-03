import 'dart:convert';
import 'package:http/http.dart' as http;

import '../../services/app_logger.dart';
import '../internal_mcp_server.dart';

/// Pure Dart implementation of the Model Context Protocol (MCP) Fetch Server.
///
/// Compatible with the official `@modelcontextprotocol/server-fetch`:
/// Fetches a URL from the internet and extracts its contents as clean Markdown
/// or raw text, with pagination via [start_index] and [max_length].
class FetchMcpServer extends InternalMcpServer {
  int _defaultMaxLength = 5000;
  String _customUserAgent = '';

  @override
  String get type => 'fetch';

  @override
  String get displayName => 'Web Page Fetcher';

  @override
  String get description =>
      'Fetches web pages from the internet and converts HTML content into '
      'clean Markdown with pagination support.';

  @override
  String get iconName => 'language';

  @override
  Map<String, dynamic> get initParamSchema => {
        'type': 'object',
        'properties': {
          'defaultMaxLength': {
            'type': 'integer',
            'default': 5000,
            'description':
                'Default maximum characters to return per fetch request.',
          },
          'userAgent': {
            'type': 'string',
            'description': 'Optional custom User-Agent header.',
          },
        },
        'required': [],
      };

  @override
  Map<String, dynamic> get defaultInitParams => {
        'defaultMaxLength': 5000,
      };

  @override
  String get defaultSystemPrompt =>
      'You have access to the fetch tool to retrieve web page content directly from URLs as Markdown. '
      'Use fetch when you need to read documentation, articles, release notes, or web pages discovered '
      'via web_search or specified by the user. If content is truncated, pass start_index to continue reading.';

  @override
  Future<void> initialize(Map<String, dynamic> initParams) async {
    _defaultMaxLength =
        ((initParams['defaultMaxLength'] as int?) ?? 5000).clamp(100, 100000);
    _customUserAgent = (initParams['userAgent'] as String? ?? '').trim();
    log.info(
        '[Fetch MCP] Initialized with defaultMaxLength=$_defaultMaxLength');
  }

  @override
  List<McpToolDescriptor> get tools => [
        const McpToolDescriptor(
          name: 'fetch',
          description:
              'Fetches a URL from the internet and extracts its contents as markdown (or raw text). '
              'Supports pagination via start_index and max_length.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'url': {
                'type': 'string',
                'description': 'The URL to fetch (must be HTTP or HTTPS).',
              },
              'max_length': {
                'type': 'integer',
                'default': 5000,
                'description':
                    'Maximum number of characters to return (default: 5000).',
              },
              'start_index': {
                'type': 'integer',
                'default': 0,
                'description':
                    'On return, start at this character index (default: 0).',
              },
              'raw': {
                'type': 'boolean',
                'default': false,
                'description':
                    'If true, returns raw response body without markdown conversion.',
              },
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
    switch (toolName) {
      case 'fetch':
        return _fetchUrl(arguments);
      default:
        return {'error': 'Unknown tool: $toolName'};
    }
  }

  Future<Map<String, dynamic>> _fetchUrl(Map<String, dynamic> args) async {
    final rawUrl = (args['url'] as String?)?.trim();
    if (rawUrl == null || rawUrl.isEmpty) {
      return {'error': 'Parameter "url" is required.'};
    }

    final parsedUri = Uri.tryParse(rawUrl);
    if (parsedUri == null ||
        (parsedUri.scheme != 'http' && parsedUri.scheme != 'https')) {
      return {
        'error':
            'Invalid URL: "$rawUrl". URL must start with http:// or https://.'
      };
    }

    // Check for known binary extensions
    final path = parsedUri.path.toLowerCase();
    final dotIdx = path.lastIndexOf('.');
    if (dotIdx != -1 && dotIdx < path.length - 1) {
      final ext = path.substring(dotIdx + 1).split('?').first;
      if (_kBinaryExtensions.contains(ext)) {
        return {
          'error':
              'URL points to a binary or non-document file extension (.$ext). '
              'The fetch tool is intended for HTML, Markdown, and text documents.'
        };
      }
    }

    final rawMode = args['raw'] == true;
    final startIndex = (args['start_index'] as int? ?? 0);
    final maxLength = (args['max_length'] as int? ?? _defaultMaxLength)
        .clamp(100, 100000);

    try {
      final userAgent = _customUserAgent.isNotEmpty
          ? _customUserAgent
          : 'Mozilla/5.0 (compatible; TealKit-Fetch/1.0; ModelContextProtocol/1.0)';

      final response = await http
          .get(
            parsedUri,
            headers: {
              'Accept':
                  'text/html,application/xhtml+xml,application/xml;q=0.9,text/plain;q=0.8,text/markdown;q=0.7,*/*;q=0.5',
              'Accept-Language': 'en-US,en;q=0.9,de;q=0.8',
              'User-Agent': userAgent,
            },
          )
          .timeout(const Duration(seconds: 25));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return {
          'error':
              'HTTP request failed with status code ${response.statusCode}: ${response.reasonPhrase ?? 'Unknown'}',
          'status': response.statusCode,
          'url': rawUrl,
        };
      }

      final contentType =
          (response.headers['content-type'] ?? '').toLowerCase();

      // Check for binary content types
      if (_isBinaryContentType(contentType)) {
        return {
          'error':
              'Unsupported content-type: "$contentType". The fetch tool is intended for text, HTML, and Markdown.',
          'content_type': contentType,
          'url': rawUrl,
        };
      }

      final body = utf8.decode(response.bodyBytes, allowMalformed: true);

      String content;
      final isHtml = contentType.contains('text/html') ||
          contentType.contains('application/xhtml+xml') ||
          body.trimLeft().startsWith('<!DOCTYPE') ||
          body.trimLeft().startsWith('<html');

      if (rawMode || (!isHtml && !contentType.contains('xml'))) {
        content = body;
      } else {
        content = _htmlToMarkdown(body, parsedUri);
      }

      final totalLength = content.length;
      final clampedStart = startIndex.clamp(0, totalLength);
      final clampedEnd =
          (clampedStart + maxLength).clamp(clampedStart, totalLength);
      final slice = content.substring(clampedStart, clampedEnd);
      final hasMore = clampedEnd < totalLength;

      final formattedText = StringBuffer();
      formattedText.writeln('Contents of $rawUrl:');
      formattedText.writeln();
      formattedText.write(slice);
      if (hasMore) {
        formattedText.writeln();
        formattedText.writeln();
        formattedText.write(
          '[Content truncated. Showing characters $clampedStart to $clampedEnd of $totalLength. '
          'Call fetch with start_index: $clampedEnd to continue reading.]',
        );
      }

      return {
        'url': rawUrl,
        'status': response.statusCode,
        'contents': slice,
        'text': formattedText.toString(),
        'start_index': clampedStart,
        'end_index': clampedEnd,
        'total_length': totalLength,
        'has_more': hasMore,
        if (hasMore) 'next_start_index': clampedEnd,
      };
    } catch (e) {
      log.warning('[Fetch MCP] Failed to fetch $rawUrl: $e');
      return {'error': 'Failed to fetch $rawUrl: $e', 'url': rawUrl};
    }
  }

  bool _isBinaryContentType(String contentType) {
    if (contentType.isEmpty) return false;
    final ct = contentType.toLowerCase();
    if (ct.startsWith('image/') ||
        ct.startsWith('audio/') ||
        ct.startsWith('video/') ||
        ct.contains('application/octet-stream') ||
        ct.contains('application/pdf') ||
        ct.contains('application/zip') ||
        ct.contains('application/gzip') ||
        ct.contains('application/x-tar') ||
        ct.contains('application/x-executable') ||
        ct.contains('application/x-msdownload') ||
        ct.contains('application/vnd.android.package-archive')) {
      return true;
    }
    return false;
  }

  /// Converts HTML to clean, readable Markdown.
  String _htmlToMarkdown(String html, Uri baseUrl) {
    var text = html;

    // Extract title
    String title = '';
    final titleMatch = RegExp(r'<title[^>]*>(.*?)</title>',
            caseSensitive: false, dotAll: true)
        .firstMatch(text);
    if (titleMatch != null) {
      title = _stripTags(titleMatch.group(1) ?? '').trim();
    }

    // Strip scripts, styles, noscript, svg, canvas, head
    text = text.replaceAll(
      RegExp(r'<script[^>]*>.*?</script>', caseSensitive: false, dotAll: true),
      ' ',
    );
    text = text.replaceAll(
      RegExp(r'<style[^>]*>.*?</style>', caseSensitive: false, dotAll: true),
      ' ',
    );
    text = text.replaceAll(
      RegExp(r'<noscript[^>]*>.*?</noscript>',
          caseSensitive: false, dotAll: true),
      ' ',
    );
    text = text.replaceAll(
      RegExp(r'<svg[^>]*>.*?</svg>', caseSensitive: false, dotAll: true),
      ' ',
    );
    text = text.replaceAll(
      RegExp(r'<canvas[^>]*>.*?</canvas>',
          caseSensitive: false, dotAll: true),
      ' ',
    );
    text = text.replaceAll(
      RegExp(r'<!--.*?-->', caseSensitive: false, dotAll: true),
      ' ',
    );

    // Code blocks <pre><code>...</code></pre> and <pre>...</pre>
    text = text.replaceAllMapped(
      RegExp(r'<pre[^>]*><code[^>]*>(.*?)</code></pre>',
          caseSensitive: false, dotAll: true),
      (m) => '\n\n```\n${_stripTags(m.group(1) ?? '').trim()}\n```\n\n',
    );
    text = text.replaceAllMapped(
      RegExp(r'<pre[^>]*>(.*?)</pre>', caseSensitive: false, dotAll: true),
      (m) => '\n\n```\n${_stripTags(m.group(1) ?? '').trim()}\n```\n\n',
    );
    text = text.replaceAllMapped(
      RegExp(r'<code[^>]*>(.*?)</code>', caseSensitive: false, dotAll: true),
      (m) => '`${_stripTags(m.group(1) ?? '').trim()}`',
    );

    // Headings
    text = text.replaceAllMapped(
      RegExp(r'<h1[^>]*>(.*?)</h1>', caseSensitive: false, dotAll: true),
      (m) => '\n\n# ${_stripTags(m.group(1) ?? '').trim()}\n\n',
    );
    text = text.replaceAllMapped(
      RegExp(r'<h2[^>]*>(.*?)</h2>', caseSensitive: false, dotAll: true),
      (m) => '\n\n## ${_stripTags(m.group(1) ?? '').trim()}\n\n',
    );
    text = text.replaceAllMapped(
      RegExp(r'<h3[^>]*>(.*?)</h3>', caseSensitive: false, dotAll: true),
      (m) => '\n\n### ${_stripTags(m.group(1) ?? '').trim()}\n\n',
    );
    text = text.replaceAllMapped(
      RegExp(r'<h[4-6][^>]*>(.*?)</h[4-6]>',
          caseSensitive: false, dotAll: true),
      (m) => '\n\n#### ${_stripTags(m.group(1) ?? '').trim()}\n\n',
    );

    // Links: convert <a href="...">text</a> to [text](url)
    text = text.replaceAllMapped(
      RegExp(r'<a\s+[^>]*href="([^"]+)"[^>]*>(.*?)</a>',
          caseSensitive: false, dotAll: true),
      (m) {
        final href = (m.group(1) ?? '').trim();
        final linkText = _stripTags(m.group(2) ?? '').trim();
        if (href.isEmpty || href.startsWith('javascript:')) {
          return linkText;
        }
        if (linkText.isEmpty) return '';

        try {
          final uri = Uri.parse(href);
          final resolved = uri.hasScheme ? uri : baseUrl.resolveUri(uri);
          return '[$linkText]($resolved)';
        } catch (_) {
          return '[$linkText]($href)';
        }
      },
    );
    text = text.replaceAllMapped(
      RegExp(r"<a\s+[^>]*href='([^']+)'[^>]*>(.*?)</a>",
          caseSensitive: false, dotAll: true),
      (m) {
        final href = (m.group(1) ?? '').trim();
        final linkText = _stripTags(m.group(2) ?? '').trim();
        if (href.isEmpty || href.startsWith('javascript:')) {
          return linkText;
        }
        if (linkText.isEmpty) return '';

        try {
          final uri = Uri.parse(href);
          final resolved = uri.hasScheme ? uri : baseUrl.resolveUri(uri);
          return '[$linkText]($resolved)';
        } catch (_) {
          return '[$linkText]($href)';
        }
      },
    );

    // Bold & Italics
    text = text.replaceAllMapped(
      RegExp(r'<(?:strong|b)[^>]*>(.*?)</(?:strong|b)>',
          caseSensitive: false, dotAll: true),
      (m) => '**${_stripTags(m.group(1) ?? '').trim()}**',
    );
    text = text.replaceAllMapped(
      RegExp(r'<(?:em|i)[^>]*>(.*?)</(?:em|i)>',
          caseSensitive: false, dotAll: true),
      (m) => '*${_stripTags(m.group(1) ?? '').trim()}*',
    );

    // Blockquotes
    text = text.replaceAllMapped(
      RegExp(r'<blockquote[^>]*>(.*?)</blockquote>',
          caseSensitive: false, dotAll: true),
      (m) => '\n> ${_stripTags(m.group(1) ?? '').trim()}\n',
    );

    // List items
    text = text.replaceAllMapped(
      RegExp(r'<li[^>]*>(.*?)</li>', caseSensitive: false, dotAll: true),
      (m) => '\n- ${_stripTags(m.group(1) ?? '').trim()}',
    );

    // Paragraphs, divs, breaks
    text = text.replaceAll(
      RegExp(r'<br\s*/?>', caseSensitive: false),
      '\n',
    );
    text = text.replaceAll(
      RegExp(r'</?(?:p|div|section|article|main|footer|header|tr)[^>]*>',
          caseSensitive: false),
      '\n\n',
    );
    text = text.replaceAll(
      RegExp(r'<hr\s*/?>', caseSensitive: false),
      '\n\n---\n\n',
    );

    // Strip all remaining tags
    text = _stripTags(text);

    // Decode HTML entities
    text = _decodeHtmlEntities(text);

    // Normalize spacing: replace multiple spaces with single space, multiple newlines with at most 2
    text = text.replaceAll(RegExp(r'[ \t]+'), ' ');
    text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();

    if (title.isNotEmpty && !text.startsWith('# ')) {
      text = '# $title\n\n$text';
    }

    return text;
  }

  String _stripTags(String s) => s.replaceAll(RegExp(r'<[^>]+>'), ' ');

  String _decodeHtmlEntities(String s) {
    var out = s
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'");

    // Hex entities: &#x...;
    out = out.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
      final code = int.tryParse(m.group(1)!, radix: 16);
      return code != null ? String.fromCharCode(code) : m.group(0)!;
    });

    // Decimal entities: &#...;
    out = out.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
      final code = int.tryParse(m.group(1)!);
      return code != null ? String.fromCharCode(code) : m.group(0)!;
    });

    return out;
  }

  static const _kBinaryExtensions = {
    'exe',
    'msi',
    'zip',
    'tar',
    'gz',
    'tgz',
    'bz2',
    'tbz2',
    'xz',
    'txz',
    '7z',
    'rar',
    'bin',
    'iso',
    'dmg',
    'pkg',
    'deb',
    'rpm',
    'apk',
    'aab',
    'pdf',
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'bmp',
    'ico',
    'svg',
    'mp3',
    'mp4',
    'wav',
    'ogg',
    'avi',
    'mov',
    'webm',
    'wasm',
  };
}
