import 'package:dart_mcp_core/dart_mcp_core.dart';
import 'package:yaml/yaml.dart';
import '../rag/rag_config.dart';
import 'global_config.dart';

/// Represents a specialized sub-agent role definition in `config.yaml`.
class SubAgentDefinition {
  final String key;
  final String model;
  final String description;
  final String systemPrompt;
  final List<String>? tools;
  final int maxTurns;

  const SubAgentDefinition({
    required this.key,
    required this.model,
    this.description = '',
    this.systemPrompt = '',
    this.tools,
    this.maxTurns = 10,
  });

  /// Inbuilt predefined sub-agents from ThiesCoder / TealKit.
  static const List<SubAgentDefinition> predefined = [
    SubAgentDefinition(
      key: 'unit_tester',
      model: 'default',
      description: 'Automated unit test specialist: generates, updates, and executes test suites',
      systemPrompt: '''You are an expert test engineer and QA specialist.
Your task is to analyze code, write robust and comprehensive unit tests (covering happy paths, edge cases, and failure modes), and execute them to verify test suite health.
Follow standard test frameworks for the target project (e.g. xUnit for .NET, pytest for Python, test/flutter_test for Dart).
Always execute the test runner via terminal to verify all tests pass before completing.''',
      tools: ['fs_read_file', 'fs_replace_text', 'fs_write_file', 'terminal_exec', 'fs_list_dir'],
      maxTurns: 10,
    ),
    SubAgentDefinition(
      key: 'git_auditor',
      model: 'default',
      description: 'Git repository auditor: inspects status, diffs, branch health, and formats commits',
      systemPrompt: '''You are an expert Git and version control auditor.
Your job is to inspect git status, review branch diffs, detect untracked or dangling files, ensure working tree hygiene, and prepare clean, conventional commit messages.
Never force-push or destroy uncommitted work.
Report a clean breakdown of modified, added, and deleted files with recommendations.''',
      tools: ['terminal_exec', 'fs_read_file', 'fs_list_dir'],
      maxTurns: 6,
    ),
    SubAgentDefinition(
      key: 'web_researcher',
      model: 'default',
      description: 'Technical web researcher: queries online documentation, APIs, and release notes',
      systemPrompt: '''You are a specialized technical documentation and web researcher.
Your task is to search the web for API documentation, libraries, release notes, and solutions to technical errors or deprecations.
Synthesize your findings concisely with direct links, code snippets, and citations.''',
      tools: ['web_search', 'fs_read_file'],
      maxTurns: 8,
    ),
    SubAgentDefinition(
      key: 'code_scout',
      model: 'default',
      description: 'Fast codebase explorer and caller hierarchy / symbol scout',
      systemPrompt: '''You are a specialized codebase exploration and symbol search agent.
Your objective is to quickly locate symbols, caller hierarchies, interface implementations, and architectural structure without modifying any code.
Return concise, structured findings with exact file paths and line numbers.''',
      tools: ['fs_find', 'fs_read_file', 'fs_list_dir'],
      maxTurns: 8,
    ),
    SubAgentDefinition(
      key: 'c_analyzer',
      model: 'default',
      description: 'C/C++ firmware static analyzer and compiler warning expert',
      systemPrompt: '''You are an expert embedded C/C++ systems engineer.
Analyze source files and header files for compiler warnings, buffer overflows,
pointer safety, signed/unsigned mismatches, and missing NULL checks.
Be concise: return only file paths, line numbers, and actionable fixes.''',
      tools: ['fs_read_file', 'fs_find', 'fs_list_dir'],
      maxTurns: 8,
    ),
  ];
}

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

  /// Maximum tool iterations per user prompt turn.
  int maxToolIterations;

  /// Whether compact tool output format is enabled.
  bool compactTools;

  /// Progressive MCP Tool Discovery mode ('auto', 'on', 'off').
  /// In 'auto' mode, it is automatically enabled if total tools > 25 or using embedded/SLM models.
  String progressiveTools;

  /// Session persistence settings.
  int maxTurns;
  int maxSizeMb;
  bool autoSaveSession;

  /// Local RAG (document & web hybrid search) configuration.
  RagConfig rag;

  /// Configured specialized sub-agents.
  List<SubAgentDefinition> subagents;

  CliConfig({
    this.multilinePrompt = true,
    this.submitKey = 'ctrl-enter',
    this.autoPasteImages = true,
    this.enablePlanning = true,
    this.contextCompressionThreshold = 4000,
    this.maxToolIterations = 100,
    this.compactTools = false,
    this.progressiveTools = 'auto',
    this.maxTurns = 500,
    this.maxSizeMb = 10,
    this.autoSaveSession = true,
    RagConfig? rag,
    List<SubAgentDefinition>? subagents,
  })  : rag = rag ?? RagConfig(),
        subagents = subagents ?? [];

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

  /// Loads configuration from `config.yaml` (workspace `./config.yaml` or global `~/.tealkitcoder/config.yaml`).
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

      final maxToolIter = agentSection != null && agentSection.containsKey('max_tool_iterations')
          ? int.tryParse(agentSection['max_tool_iterations'].toString()) ?? 100
          : int.tryParse(doc['max_tool_iterations']?.toString() ?? '100') ?? 100;

      final progressive = agentSection != null && agentSection.containsKey('progressive_tools')
          ? (agentSection['progressive_tools'] as String? ?? 'auto').trim().toLowerCase()
          : (doc['progressive_tools'] as String? ?? 'auto').trim().toLowerCase();

      final compact = doc['compact_tools'] == true;
      final sessionSection = doc['session'] is Map ? doc['session'] as Map : null;
      final maxSessionTurns = sessionSection != null && sessionSection['max_turns'] != null
          ? int.tryParse(sessionSection['max_turns'].toString()) ?? 500
          : int.tryParse(doc['max_turns']?.toString() ?? '500') ?? 500;
      final maxSessionSizeMb = sessionSection != null && sessionSection['max_size_mb'] != null
          ? int.tryParse(sessionSection['max_size_mb'].toString()) ?? 10
          : 10;
      final sessionAutoSave = sessionSection != null && sessionSection.containsKey('auto_save')
          ? sessionSection['auto_save'] == true
          : true;

      final ragSection = doc['rag'] is Map ? doc['rag'] as Map : null;
      final ragConfig = RagConfig.fromYaml(ragSection);

      final subagentsList = <SubAgentDefinition>[];
      final subagentsSection = doc['subagents'] is Map ? doc['subagents'] as Map : null;
      if (subagentsSection != null) {
        for (final entry in subagentsSection.entries) {
          final key = entry.key.toString().trim();
          final val = entry.value;
          if (val is Map) {
            final model = val['model']?.toString().trim() ?? '';
            final desc = val['description']?.toString().trim() ?? '';
            final prompt = val['system_prompt']?.toString().trim() ?? '';
            final tools = val['tools'] is List
                ? (val['tools'] as List).map((t) => t.toString().trim()).toList()
                : null;
            final maxTurns = int.tryParse(val['max_turns']?.toString() ?? '10') ?? 10;
            if (key.isNotEmpty && model.isNotEmpty) {
              subagentsList.add(SubAgentDefinition(
                key: key,
                model: model,
                description: desc,
                systemPrompt: prompt,
                tools: tools,
                maxTurns: maxTurns,
              ));
            }
          }
        }
      }

      return CliConfig(
        multilinePrompt: multiline,
        submitKey: submit,
        autoPasteImages: autoPaste,
        enablePlanning: planning,
        contextCompressionThreshold: compThreshold,
        maxToolIterations: maxToolIter,
        compactTools: compact,
        progressiveTools: progressive,
        maxTurns: maxSessionTurns,
        maxSizeMb: maxSessionSizeMb,
        autoSaveSession: sessionAutoSave,
        rag: ragConfig,
        subagents: subagentsList,
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
    yamlBuffer.writeln('  max_tool_iterations: $maxToolIterations');
    yamlBuffer.writeln('  progressive_tools: "$progressiveTools"');
    yamlBuffer.writeln('');
    yamlBuffer.writeln('compact_tools: $compactTools');
    yamlBuffer.writeln('');
    yamlBuffer.writeln('session:');
    yamlBuffer.writeln('  max_size_mb: $maxSizeMb');
    yamlBuffer.writeln('  max_turns: $maxTurns');
    yamlBuffer.writeln('  auto_save: $autoSaveSession');
    yamlBuffer.writeln('  file_pattern: "tealkitcoder_session_{timestamp}.json"');
    yamlBuffer.writeln('');
    yamlBuffer.writeln('rag:');
    yamlBuffer.writeln('  enabled: ${rag.enabled}');
    yamlBuffer.writeln('  database_path: "${rag.databasePath}"');
    yamlBuffer.writeln('  sources:');
    if (rag.folderSources.isEmpty) {
      yamlBuffer.writeln('    folders: []');
    } else {
      yamlBuffer.writeln('    folders:');
      for (final f in rag.folderSources) {
        yamlBuffer.writeln('      - "$f"');
      }
    }
    if (rag.webSources.isEmpty) {
      yamlBuffer.writeln('    web: []');
    } else {
      yamlBuffer.writeln('    web:');
      for (final w in rag.webSources) {
        yamlBuffer.writeln('      - "$w"');
      }
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
    yamlBuffer.writeln('    gpu_layers: ${rag.embeddingGpuLayers}');
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
