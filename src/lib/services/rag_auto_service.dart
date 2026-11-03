import 'package:flutter_ui_mcp_core/flutter_ui_mcp_core.dart';
import '../database/duckdb_service.dart';
import '../services/app_logger.dart';
import '../services/llm_settings_service.dart';

/// Result of a RAG health/readiness check.
class RagAvailabilityResult {
  final bool isAvailable;
  final String? warningMessage;
  final int indexedDocumentCount;
  final int indexedWebsiteCount;

  const RagAvailabilityResult({
    required this.isAvailable,
    this.warningMessage,
    this.indexedDocumentCount = 0,
    this.indexedWebsiteCount = 0,
  });

  bool get hasIndexedData => indexedDocumentCount > 0 || indexedWebsiteCount > 0;
}

/// Service that automates local RAG operations:
/// 1. Health checks and availability detection (DuckDB document & web-crawl indices).
/// 2. Auto-enabling `document` and `web_crawl` tools when RAG is toggled.
/// 3. Detecting user query intent ("search ... in documents", "search ... in websites")
///    and enforcing localized internal RAG rather than external search engines.
class RagAutoService {
  RagAutoService._();
  static final RagAutoService instance = RagAutoService._();

  /// Tool names that belong to internal document search.
  static const List<String> documentToolNames = [
    'search_documents',
    'list_documents',
    'get_document_content',
    'reindex',
  ];

  /// Tool names that belong to internal web-crawl search.
  static const List<String> webCrawlToolNames = [
    'search_indexed_websites',
    'list_indexed_pages',
    'get_indexed_page',
    'reindex_websites',
  ];

  /// All RAG-relevant tool names.
  static List<String> get allRagToolNames => [
        ...documentToolNames,
        ...webCrawlToolNames,
      ];

  /// Checks whether local RAG is available and whether indexed data exists.
  Future<RagAvailabilityResult> checkRagAvailability() async {
    int docCount = 0;
    int webCount = 0;

    try {
      final db = DuckDbService();
      if (db.dbPath != null) {
        try {
          final docRows = await db.query('SELECT COUNT(*) FROM document_index');
          if (docRows.isNotEmpty) {
            docCount = int.tryParse(docRows.first.first.toString()) ?? 0;
          }
        } catch (_) {
          // document_index table might not yet exist if uninitialized
        }

        try {
          final webRows = await db.query('SELECT COUNT(*) FROM website_index');
          if (webRows.isNotEmpty) {
            webCount = int.tryParse(webRows.first.first.toString()) ?? 0;
          }
        } catch (_) {
          // website_index table might not yet exist if uninitialized
        }
      }
    } catch (e) {
      log.warning('[RagAutoService] Error checking DuckDB indices: $e');
    }

    final llmConfigured = LlmSettingsService.instance.isConfigured;
    if (!llmConfigured) {
      return RagAvailabilityResult(
        isAvailable: false,
        warningMessage: 'LLM model endpoint is not configured.',
        indexedDocumentCount: docCount,
        indexedWebsiteCount: webCount,
      );
    }

    if (docCount == 0 && webCount == 0) {
      return RagAvailabilityResult(
        isAvailable: true,
        warningMessage:
            'Knowledge database is empty (0 documents, 0 crawled websites). '
            'Please configure seed URLs or folders in Settings > Data Sources.',
        indexedDocumentCount: docCount,
        indexedWebsiteCount: webCount,
      );
    }

    return RagAvailabilityResult(
      isAvailable: true,
      indexedDocumentCount: docCount,
      indexedWebsiteCount: webCount,
    );
  }

  /// Automatically enables document and web-crawl tools on the [PlaygroundController].
  void autoEnableRagTools(PlaygroundController controller) {
    for (final toolName in allRagToolNames) {
      if (!controller.enabledToolNames.contains(toolName)) {
        controller.toggleToolEnabled(toolName, true);
      }
    }
  }

  /// Inspects user text to check if the prompt expresses an intent to search in documents or websites.
  bool matchesLocalSearchIntent(String text) {
    final lower = text.toLowerCase();
    final hasSearchVerb = lower.contains('search') ||
        lower.contains('find') ||
        lower.contains('query') ||
        lower.contains('suche') ||
        lower.contains('finde');

    final hasTarget = lower.contains('document') ||
        lower.contains('dokument') ||
        lower.contains('file') ||
        lower.contains('website') ||
        lower.contains('webseite') ||
        lower.contains('web-crawl') ||
        lower.contains('crawl');

    return hasSearchVerb && hasTarget;
  }

  /// Returns tailored system prompt routing guidance based on the user's intent.
  String? getRoutingGuidance(String userPrompt) {
    final lower = userPrompt.toLowerCase();
    final inDocuments = lower.contains('document') ||
        lower.contains('dokument') ||
        lower.contains('in files');
    final inWebsites = lower.contains('website') ||
        lower.contains('webseite') ||
        lower.contains('web-crawl');

    if (inDocuments && !inWebsites) {
      return 'ROUTING GUIDANCE: The user explicitly requested searching local documents. '
          'You MUST use the internal "search_documents" tool to query local indexed files. '
          'NEVER invoke external search engines or fabricate remote links.';
    }

    if (inWebsites && !inDocuments) {
      return 'ROUTING GUIDANCE: The user explicitly requested searching indexed websites. '
          'You MUST use the internal "search_indexed_websites" tool to search pre-crawled content. '
          'NEVER invoke external web search APIs or fabricate URLs not found in index results.';
    }

    if (inDocuments && inWebsites) {
      return 'ROUTING GUIDANCE: The user requested searching both local documents and crawled websites. '
          'Use "search_documents" and "search_indexed_websites" to synthesize your findings from local DuckDB storage.';
    }

    return null;
  }
}
