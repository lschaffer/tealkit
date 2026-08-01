import 'dart:io';

/// Configuration settings for TealKit Server Light (Low-RAM / ARM Microcontroller Edition).
class TealKitServerLightConfig {
  /// Whether to use lightweight SQLite storage instead of DuckDB / relational engines.
  final bool useSQLite;

  /// Path to the SQLite database file on disk.
  final String dbPath;

  /// Whether heavy semantic search and local vector DB features are enabled.
  /// Set to false on low-resource devices (e.g. 1GB RAM) to minimize RAM usage.
  final bool enableSemanticSearch;

  /// Whether to enable local embedded LLM inference (requires 4GB+ RAM for 1.5B models).
  final bool enableLocalModel;

  /// Path to local model file (e.g. GGUF / llamafile) if local model is enabled.
  final String? localModelPath;

  /// Default HTTP port for REST & WebSocket TealKit API server.
  final int port;

  /// Default API key for external providers (e.g. OpenAI / Groq / Anthropic).
  final String? defaultExternalApiKey;

  /// Target base URL for external AI API provider.
  final String externalApiBaseUrl;

  const TealKitServerLightConfig({
    this.useSQLite = true,
    this.dbPath = 'tealkit_light.db',
    this.enableSemanticSearch = false,
    this.enableLocalModel = false,
    this.localModelPath,
    this.port = 8080,
    this.defaultExternalApiKey,
    this.externalApiBaseUrl = 'https://api.openai.com/v1',
  });

  /// Factory constructor to load configuration from environment variables or defaults.
  factory TealKitServerLightConfig.fromEnv() {
    final env = Platform.environment;
    return TealKitServerLightConfig(
      useSQLite: env['TEALKIT_USE_SQLITE'] != 'false',
      dbPath: env['TEALKIT_DB_PATH'] ?? 'tealkit_light.db',
      enableSemanticSearch: env['TEALKIT_ENABLE_SEMANTIC_SEARCH'] == 'true',
      enableLocalModel: env['TEALKIT_ENABLE_LOCAL_MODEL'] == 'true',
      localModelPath: env['TEALKIT_LOCAL_MODEL_PATH'],
      port: int.tryParse(env['PORT'] ?? '8080') ?? 8080,
      defaultExternalApiKey: env['OPENAI_API_KEY'] ?? env['TEALKIT_EXTERNAL_API_KEY'],
      externalApiBaseUrl: env['TEALKIT_EXTERNAL_API_BASE_URL'] ?? 'https://api.openai.com/v1',
    );
  }

  Map<String, dynamic> toJson() => {
    'useSQLite': useSQLite,
    'dbPath': dbPath,
    'enableSemanticSearch': enableSemanticSearch,
    'enableLocalModel': enableLocalModel,
    'localModelPath': localModelPath,
    'port': port,
    'externalApiBaseUrl': externalApiBaseUrl,
  };
}
