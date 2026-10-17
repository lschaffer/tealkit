export 'web_crawler.dart';

import 'package:http/http.dart' as http;
import 'web_crawler.dart';

/// Web content extractor that fetches URLs and extracts readable article text.
class WebExtractor {
  /// Fetches [url] over HTTP and extracts readable text content.
  static Future<String?> extractFromUrl(
    String url, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    try {
      final uri = Uri.parse(url);
      final crawler = WebCrawler(timeout: timeout);
      final client = http.Client();
      try {
        final page = await crawler.fetchPage(client, uri);
        return page?.text;
      } finally {
        client.close();
      }
    } catch (_) {
      return null;
    }
  }

  /// Strips `<script>`, `<style>`, HTML tags, and decodes HTML entities.
  static String extractReadableText(String html) =>
      WebCrawler.extractReadableText(html);
}
