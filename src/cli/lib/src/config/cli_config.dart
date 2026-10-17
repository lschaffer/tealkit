import 'package:dart_mcp_core/dart_mcp_core.dart';
import 'package:yaml/yaml.dart';
import '../rag/rag_config.dart';
import 'global_config.dart';

/// Configuration options for the TealKit CLI, loaded from `config.yaml`.
class CliConfig {
  /// Whether multi-line prompt entry is enabled (Enter = newline, Ctrl-Enter = submit).
  bool multilinePrompt;

  /// The shortcut to submit multi-line prompts ('ctrl-enter' or 'double-enter').
  String submitKey;

  /// Whether `/paste` automatically inspects and attaches clipboard images.
  bool autoPasteImages;

  /// Whether Structured Agent Planning (`write_todos`) is enabled by default.
  bool enablePlanning;

  /// Token threshold for automatic context window compression (ContextCompressor).
  int contextCompressionThreshold;

  /// Whether compact tool output format is enabled.
  bool compactTools;

  /// Progressive MCP Tool Discovery mode ('auto', 'on', 'off').
  /// In 'auto' mode, it is automatically enabled if total tools > 25 or using embedded/SLM models.
  String progressiveTools;

  /// Local RAG (document & web hybrid search) configuration.
  RagConfig rag;

  CliConfig({
    this.multilinePrompt = true,
    this.submitKey = 'ctrl-enter',
    this.autoPasteImages = true,
    this.enablePlanning = true,
    this.contextCompressionThreshold = 4000,
    this.compactTools = false,
    this.progressiveTools = 'auto',
    RagConfig? rag,
  }) : rag = rag ?? RagConfig();

  /// Returns whether progressive tool discovery should be active given the available tool count and model provider.
  bool isProgressiveToolsActive({required int totalTools, LlmProvider? provider}) {
    final mode = progressiveTools.toLowerCase().trim();
    if (mode == 'on' || mode == 'true' || mode == '1') return true;
    if (mode == 'off' || mode == 'false' || mode == '0') return false;
    // 'auto' mode:
    if (provider == LlmProvider.embedded || provider == LlmProvider.ollama) {
      return true;
    }
    return totalTools > 25;
  }

  /// Loads configuration from `config.yaml` (workspace `./config.yaml` or global `~/.tealkit/config.yaml`).
  static CliConfig load({String configPath = 'config.yaml'}) {
    final file = GlobalConfigLocator.resolveConfigFile(configPath);
    if (!file.existsSync()) {
      return CliConfig();
    }

    try {
      final content = file.readAsStringSync();
      final doc = loadYaml(content);
      if (doc is! Map) return CliConfig();

      final promptSection = doc['prompt'] is Map ? doc['prompt'] as Map : null;
      final agentSection = doc['agent'] is Map ? doc['agent'] as Map : null;

      final multiline = promptSection != null && promptSection.containsKey('multiline')
          ? promptSection['multiline'] == true
          : (doc['multiline_prompt'] == true || doc['multiline'] == true || true);

      final submit = promptSection != null && promptSection.containsKey('submit_key')
          ? (promptSection['submit_key'] as String? ?? 'ctrl-enter').trim().toLowerCase()
          : (doc['submit_key'] as String? ?? 'ctrl-enter').trim().toLowerCase();

      final autoPaste = promptSection != null && promptSection.containsKey('auto_paste_images')
          ? promptSection['auto_paste_images'] == true
          : (doc['auto_paste_images'] != false);

      final planning = agentSection != null && agentSection.containsKey('planning')
          ? agentSection['planning'] == true
          : (doc['enable_planning'] != false);

      final compThreshold = agentSection != null && agentSection.containsKey('compression_threshold')
          ? int.tryParse(agentSection['compression_threshold'].toString()) ?? 4000
          : int.tryParse(doc['compression_threshold']?.toString() ?? '4000') ?? 4000;

      final progressive = agentSection != null && agentSection.containsKey('progressive_tools')
          ? (agentSection['progressive_tools'] as String? ?? 'auto').trim().toLowerCase()
          : (doc['progressive_tools'] as String? ?? 'auto').trim().toLowerCase();

      final compact = doc['compact_tools'] == true;
      final ragSection = doc['rag'] is Map ? doc['rag'] as Map : null;
      final ragConfig = RagConfig.fromYaml(ragSection);

      return CliConfig(
        multilinePrompt: multiline,
        submitKey: submit,
        autoPasteImages: autoPaste,
        enablePlanning: planning,
        contextCompressionThreshold: compThreshold,
        compactTools: compact,
        progressiveTools: progressive,
        rag: ragConfig,
      );
    } catch (_) {
      return CliConfig();
    }
  }

  /// Saves the current configuration to `config.yaml`.
  void save({String configPath = 'config.yaml'}) {
    final file = GlobalConfigLocator.resolveConfigFile(configPath);
    final yamlBuffer = StringBuffer();
    yamlBuffer.writeln('# TealKit CLI Configuration');
    yamlBuffer.writeln('prompt:');
    yamlBuffer.writeln('  multiline: $multilinePrompt');
    yamlBuffer.writeln('  submit_key: "$submitKey"');
    yamlBuffer.writeln('  auto_paste_images: $autoPasteImages');
    yamlBuffer.writeln('');
    yamlBuffer.writeln('agent:');
    yamlBuffer.writeln('  planning: $enablePlanning');
    yamlBuffer.writeln('  compression_threshold: $contextCompressionThreshold');
    yamlBuffer.writeln('  progressive_tools: "$progressiveTools"');
    yamlBuffer.writeln('');
    yamlBuffer.writeln('compact_tools: $compactTools');
    yamlBuffer.writeln('');
    yamlBuffer.writeln('rag:');
    yamlBuffer.writeln('  enabled: ${rag.enabled}');
    yamlBuffer.writeln('  database_path: "${rag.databasePath}"');
    yamlBuffer.writeln('  sources:');
    yamlBuffer.writeln('    folders:');
    for (final f in rag.folderSources) {
      yamlBuffer.writeln('      - "$f"');
    }
    yamlBuffer.writeln('    web:');
    for (final w in rag.webSources) {
      yamlBuffer.writeln('      - "$w"');
    }
    yamlBuffer.writeln('    max_pages: ${rag.maxPages}');
    yamlBuffer.writeln('  file_extensions:');
    for (final ext in rag.fileExtensions) {
      yamlBuffer.writeln('    - "$ext"');
    }
    yamlBuffer.writeln('  chunking:');
    yamlBuffer.writeln('    chunk_size: ${rag.chunkSize}');
    yamlBuffer.writeln('    chunk_overlap: ${rag.chunkOverlap}');
    yamlBuffer.writeln('  embedding:');
    yamlBuffer.writeln('    provider: "${rag.embeddingProvider}"');
    yamlBuffer.writeln('    model: "${rag.embeddingModel}"');
    yamlBuffer.writeln('    base_url: "${rag.embeddingBaseUrl}"');
    yamlBuffer.writeln('    api_key: "${rag.embeddingApiKey}"');
    yamlBuffer.writeln('  search:');
    yamlBuffer.writeln('    mode: "${rag.searchMode}"');
    yamlBuffer.writeln('    max_chunks: ${rag.maxChunks}');
    yamlBuffer.writeln('    min_score: ${rag.minScore}');

    try {
      file.writeAsStringSync(yamlBuffer.toString());
    } catch (_) {}
  }
}
