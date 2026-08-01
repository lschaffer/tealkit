/// Feature flags controlling which REST API route groups and services are
/// enabled at server bootstrap time.
///
/// Used so that [server_light] can reuse the full server router but disable
/// routes that require heavy dependencies (embedded models, indexing, PDF tools).
class ServerFeatureFlags {
  /// llama.cpp / GGUF model loading, downloading, GPU queries.
  final bool enableEmbeddedModels;

  /// Website + document indexing (semantic search / vector embeddings).
  final bool enableIndexing;

  /// [ServerPdfMcp] — PDF manipulation tools.
  final bool enablePdfTools;

  /// [ServerChartMcp] + [ServerMermaidMcp] — chart generation.
  final bool enableChartTools;

  /// [ServerDocumentMcp] — document parsing beyond indexing.
  final bool enableDocumentTools;

  /// [ServerExcelMcp] — Excel file operations.
  final bool enableExcelTools;

  /// [ServerFileMcp] — generic file I/O tools.
  final bool enableFileTools;

  /// Semantic / vector embedding module.
  final bool enableSemanticSearch;

  /// Cron-based task scheduler.
  final bool enableScheduler;

  const ServerFeatureFlags({
    this.enableEmbeddedModels = true,
    this.enableIndexing = true,
    this.enablePdfTools = true,
    this.enableChartTools = true,
    this.enableDocumentTools = true,
    this.enableExcelTools = true,
    this.enableFileTools = true,
    this.enableSemanticSearch = true,
    this.enableScheduler = true,
  });

  /// Preset for server_light: disables everything that requires heavy
  /// dependencies or >1GB RAM.
  static const light = ServerFeatureFlags(
    enableEmbeddedModels: false,
    enableIndexing: false,
    enablePdfTools: false,
    enableChartTools: false,
    enableDocumentTools: false,
    enableExcelTools: false,
    enableFileTools: false,
    enableSemanticSearch: false,
    enableScheduler: false,
  );
}
