import 'dart:collection';
import 'dart:convert';
import 'package:http/http.dart' as http;

/// Represents a single crawled web page with content and metadata.
class CrawledWebPage {
  final Uri url;
  final String title;
  final String text;
  final int statusCode;
  final List<Uri> links;

  CrawledWebPage({
    required this.url,
    required this.title,
    required this.text,
    required this.statusCode,
    this.links = const [],
  });
}

class _CrawlItem {
  final Uri seed;
  final Uri url;
  _CrawlItem({required this.seed, required this.url});
}

/// Pure Dart asynchronous web crawler designed for local RAG indexing.
///
/// Features breadth-first crawl traversal, domain and path prefix boundaries,
/// non-HTML resource exclusion, boilerplate/noise segment filtering,
/// title extraction, and clean readable text conversion.
class WebCrawler {
  final int maxPages;
  final Duration timeout;
  final String userAgent;

  WebCrawler({
    this.maxPages = 50,
    this.timeout = const Duration(seconds: 15),
    this.userAgent =
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) TealKit-CLI/1.3',
  });

  static const _kSkipExtensions = {
    'css', 'js', 'mjs', 'ts', 'jpg', 'jpeg', 'png', 'gif', 'webp',
    'svg', 'ico', 'bmp', 'avif', 'woff', 'woff2', 'ttf', 'eot', 'otf',
    'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'zip', 'gz',
    'tar', 'rar', '7z', 'mp3', 'mp4', 'wav', 'ogg', 'avi', 'mov',
    'webm', 'xml', 'rss', 'atom', 'json', 'jsonld', 'map', 'wasm',
  };

  static const _kSkipPathSegments = {
    'autor', 'author', 'autoren', 'redaktion', 'redakteur',
    'tag', 'tags', 'thema', 'themen', 'kategorie', 'kategorien',
    'suche', 'search', 'impressum', 'datenschutz', 'agb', 'kontakt',
    'ueber-uns', 'about', 'dsi', 'privacy', 'legal', 'cookie', 'cookies',
    'newsletter', 'abo', 'abonnement', 'subscription', 'login', 'signin',
    'register', 'konto', 'account', 'sitemap', 'feed',
  };

  /// Crawls pages starting from [seedUrl] up to [maxPages].
  Future<List<CrawledWebPage>> crawlSeed(
    Uri seedUrl, {
    int? maxPages,
    void Function(int crawled, int totalEstimated, String currentUrl)? onProgress,
  }) async {
    final limit = (maxPages ?? this.maxPages).clamp(1, 1000);
    final client = http.Client();
    final results = <CrawledWebPage>[];
    final queue = Queue<_CrawlItem>();
    final visited = <String>{};

    final seedHost = seedUrl.host.toLowerCase();
    final allowedDomains = <String>{seedHost};

    queue.add(_CrawlItem(seed: seedUrl, url: seedUrl));

    try {
      while (queue.isNotEmpty && results.length < limit) {
        final item = queue.removeFirst();
        final normalizedUrl = normalizeUrl(item.url);

        if (visited.contains(normalizedUrl)) continue;
        visited.add(normalizedUrl);

        if (!isAllowed(item.url, allowedDomains, seed: item.seed)) continue;

        final page = await fetchPage(client, item.url);
        if (page == null || page.text.trim().isEmpty) continue;

        results.add(page);
        onProgress?.call(results.length, limit, normalizedUrl);

        // Add discovered outgoing links to queue if budget allows
        if (results.length + queue.length < limit * 3) {
          for (final link in page.links) {
            final norm = normalizeUrl(link);
            if (!visited.contains(norm) && isAllowed(link, allowedDomains, seed: item.seed)) {
              queue.add(_CrawlItem(seed: item.seed, url: link));
            }
          }
        }
      }
    } finally {
      client.close();
    }

    return results;
  }

  /// Fetches a single page and parses its title, text, and outgoing links.
  Future<CrawledWebPage?> fetchPage(http.Client client, Uri url) async {
    try {
      final response = await client
          .get(
            url,
            headers: {
              'User-Agent': userAgent,
              'Accept':
                  'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
              'Accept-Language': 'en-US,en;q=0.9,de;q=0.8',
            },
          )
          .timeout(timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }

      final contentType =
          (response.headers['content-type'] ?? '').toLowerCase();
      if (!contentType.contains('text/html') &&
          !contentType.contains('application/xhtml') &&
          !contentType.contains('text/plain')) {
        return null;
      }

      final body = utf8.decode(response.bodyBytes, allowMalformed: true);
      final title = extractTitle(body);
      final text = extractReadableText(body);
      if (text.trim().isEmpty) return null;

      final links = extractLinks(url, body);

      return CrawledWebPage(
        url: url,
        title: title.isNotEmpty ? title : url.toString(),
        text: text,
        statusCode: response.statusCode,
        links: links,
      );
    } catch (_) {
      return null;
    }
  }

  /// Checks if [url] is eligible for crawling given domain and seed path restrictions.
  bool isAllowed(Uri url, Set<String> allowedDomains, {Uri? seed}) {
    if (url.scheme != 'http' && url.scheme != 'https') return false;
    final host = url.host.toLowerCase();
    var domainAllowed = allowedDomains.contains(host);
    if (!domainAllowed) {
      for (final d in allowedDomains) {
        if (host.endsWith('.$d')) {
          domainAllowed = true;
          break;
        }
      }
    }
    if (!domainAllowed) return false;

    // Subpath constraint from seed URL (e.g. /docs)
    if (seed != null) {
      var seedPath = seed.path.trim();
      if (seedPath.endsWith('/')) {
        seedPath = seedPath.substring(0, seedPath.length - 1);
      }
      if (seedPath.isNotEmpty && seedPath != '/') {
        final urlPath = url.path.trim();
        if (!urlPath.startsWith(seedPath)) {
          return false;
        }
      }
    }

    return true;
  }

  /// Strips URL fragments (#...) and trailing slashes for canonical comparison.
  static String normalizeUrl(Uri uri) {
    final cleaned = uri.removeFragment();
    var asString = cleaned.toString();
    if (asString.endsWith('/')) {
      asString = asString.substring(0, asString.length - 1);
    }
    return asString;
  }

  /// Extracts HTML title.
  static String extractTitle(String html) {
    final match = RegExp(
      r'<title[^>]*>(.*?)</title>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(html);
    if (match == null) return '';
    return match.group(1)?.replaceAll(RegExp(r'<[^>]+>'), ' ').trim() ?? '';
  }

  /// Extracts clean, readable text from HTML body.
  static String extractReadableText(String html) {
    var text = html;

    // Remove script, style, and noscript tags and their contents
    text = text.replaceAll(
      RegExp(r'<script\b[^<]*(?:(?!<\/script>)<[^<]*)*<\/script>', caseSensitive: false, dotAll: true),
      ' ',
    );
    text = text.replaceAll(
      RegExp(r'<style\b[^<]*(?:(?!<\/style>)<[^<]*)*<\/style>', caseSensitive: false, dotAll: true),
      ' ',
    );
    text = text.replaceAll(
      RegExp(r'<noscript\b[^<]*(?:(?!<\/noscript>)<[^<]*)*<\/noscript>', caseSensitive: false, dotAll: true),
      ' ',
    );

    // Convert block-level elements into line breaks
    text = text.replaceAll(
      RegExp(r'<\/?(p|div|br|h[1-6]|li|blockquote|tr|table|section|article)[^>]*>', caseSensitive: false),
      '\n',
    );

    // Strip all remaining HTML tags
    text = text.replaceAll(RegExp(r'<[^>]+>'), ' ');

    // Decode common HTML entities
    text = text
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&copy;', '©')
        .replaceAll('&reg;', '®')
        .replaceAll('&trade;', '™');

    // Clean whitespace and blank lines
    final lines = text.split('\n');
    final cleaned = <String>[];
    for (final line in lines) {
      final t = line.replaceAll(RegExp(r'[ \t]+'), ' ').trim();
      if (t.isNotEmpty) cleaned.add(t);
    }

    return cleaned.join('\n');
  }

  /// Extracts outgoing links from HTML document.
  List<Uri> extractLinks(Uri baseUrl, String html) {
    final links = <Uri>[];
    final regex = RegExp(
      r'''href\s*=\s*["']([^"'#]+)["']''',
      caseSensitive: false,
    );

    for (final match in regex.allMatches(html)) {
      final href = (match.group(1) ?? '').trim();
      if (href.isEmpty) continue;
      if (href.startsWith('javascript:') || href.startsWith('mailto:') || href.startsWith('tel:')) {
        continue;
      }
      if (href.contains('{{') || href.contains('}}') || href.contains('%7B%7B')) {
        continue;
      }

      try {
        final candidate = Uri.parse(href);
        final resolved = candidate.hasScheme
            ? candidate
            : baseUrl.resolveUri(candidate);

        if (resolved.scheme != 'http' && resolved.scheme != 'https') continue;

        // Skip non-HTML resource extensions
        final pathSegment = resolved.path.split('/').last.toLowerCase();
        final extIndex = pathSegment.lastIndexOf('.');
        if (extIndex >= 0) {
          final ext = pathSegment.substring(extIndex + 1).split('?').first;
          if (_kSkipExtensions.contains(ext)) continue;
        }

        // Skip non-content noise path segments
        final pathParts = resolved.path.toLowerCase().split('/').where((s) => s.isNotEmpty);
        if (pathParts.any((seg) => _kSkipPathSegments.contains(seg.split('?').first))) {
          continue;
        }

        links.add(resolved);
      } catch (_) {
        continue;
      }
    }

    return links;
  }
}
