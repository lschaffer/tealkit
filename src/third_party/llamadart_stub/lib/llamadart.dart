// Stub llamadart for Desktop Light builds and server_light.
// Exports the public API used by embedded_llm_adapter.dart,
// flutter_ui_mcp_embedded, and server_embedded_llm_adapter.dart
// with no-op implementations and zero native build hooks.
library llamadart;

import 'dart:async';
import 'dart:typed_data';

// ═══════════════════════════════════════════════════════════════
// Logging & Enums
// ═══════════════════════════════════════════════════════════════

enum LlamaLogLevel { debug, info, warn, warning, error, none }

class LlamaLogging {
  const LlamaLogging._();
  static void configure({LlamaLogLevel level = LlamaLogLevel.info}) {}
}

enum LlamaChatRole { user, assistant, tool, system }

enum ComputeDevice { auto, cpu, gpu }

enum ModelSplitMode { none, layer, row }

// ═══════════════════════════════════════════════════════════════
// Model source & metadata
// ═══════════════════════════════════════════════════════════════

class ModelSource {
  final String value;
  const ModelSource._(this.value);

  factory ModelSource.path(String path) => ModelSource._(path);
  factory ModelSource.parse(String raw) => ModelSource._(raw);
}

class LlamaModel {
  final ModelSource source;
  const LlamaModel(this.source);
}

class ModelDownloadProgress {
  final double? fraction;
  final int downloadedBytes;
  final int? totalBytes;

  const ModelDownloadProgress({
    this.fraction,
    this.downloadedBytes = 0,
    this.totalBytes,
  });
}

// ═══════════════════════════════════════════════════════════════
// Content parts (used in chat messages)
// ═══════════════════════════════════════════════════════════════

abstract class LlamaContentPart {}

class LlamaTextContent extends LlamaContentPart {
  final String text;
  LlamaTextContent(this.text);
}

class LlamaImageContent extends LlamaContentPart {
  final Uint8List? bytes;
  final String? path;
  LlamaImageContent({this.bytes, this.path});
}

class LlamaToolCallContent extends LlamaContentPart {
  final String? id;
  final String name;
  final Map<String, dynamic> arguments;
  final String? rawJson;
  LlamaToolCallContent({
    this.id,
    required this.name,
    this.arguments = const {},
    this.rawJson,
  });
}

class LlamaToolResultContent extends LlamaContentPart {
  final String? id;
  final String name;
  final String result;
  LlamaToolResultContent({this.id, required this.name, required this.result});
}

// ═══════════════════════════════════════════════════════════════
// Chat messages
// ═══════════════════════════════════════════════════════════════

class LlamaChatMessage {
  final LlamaChatRole role;
  final List<LlamaContentPart> content;
  List<LlamaContentPart> get parts => content;

  LlamaChatMessage._({required this.role, required this.content});

  factory LlamaChatMessage.fromText({
    required LlamaChatRole role,
    required String text,
  }) {
    return LlamaChatMessage._(role: role, content: [LlamaTextContent(text)]);
  }

  factory LlamaChatMessage.withContent({
    required LlamaChatRole role,
    required List<LlamaContentPart> content,
  }) {
    return LlamaChatMessage._(role: role, content: content);
  }
}

// ═══════════════════════════════════════════════════════════════
// Generation parameters
// ═══════════════════════════════════════════════════════════════

class ModelParams {
  static const int maxGpuLayers = 99;

  final int contextSize;
  final int gpuLayers;
  final ComputeDevice device;
  final ModelSplitMode splitMode;
  final int? batchSize;
  final int? microBatchSize;
  final int? numberOfThreads;
  final int? numberOfThreadsBatch;

  const ModelParams({
    this.contextSize = 4096,
    this.gpuLayers = 0,
    this.device = ComputeDevice.auto,
    this.splitMode = ModelSplitMode.none,
    this.batchSize,
    this.microBatchSize,
    this.numberOfThreads,
    this.numberOfThreadsBatch,
  });
}

class GenerationParams {
  final int maxTokens;
  final double temp;
  final int topK;
  final double topP;
  final double penalty;
  const GenerationParams({
    this.maxTokens = 1024,
    this.temp = 0.3,
    this.topK = 40,
    this.topP = 0.9,
    this.penalty = 1.15,
  });
}

// ═══════════════════════════════════════════════════════════════
// Tool definitions
// ═══════════════════════════════════════════════════════════════

class ToolParam {
  final String name;
  final String? description;
  final bool required;
  final String type;
  final List<String>? enumValues;
  final ToolParam? itemType;

  const ToolParam._({
    required this.name,
    this.description,
    this.required = false,
    required this.type,
    this.enumValues,
    this.itemType,
  });

  factory ToolParam.string(
    String name, {
    String? description,
    bool required = false,
  }) => ToolParam._(
    name: name,
    description: description,
    required: required,
    type: 'string',
  );

  factory ToolParam.integer(
    String name, {
    String? description,
    bool required = false,
  }) => ToolParam._(
    name: name,
    description: description,
    required: required,
    type: 'integer',
  );

  factory ToolParam.number(
    String name, {
    String? description,
    bool required = false,
  }) => ToolParam._(
    name: name,
    description: description,
    required: required,
    type: 'number',
  );

  factory ToolParam.boolean(
    String name, {
    String? description,
    bool required = false,
  }) => ToolParam._(
    name: name,
    description: description,
    required: required,
    type: 'boolean',
  );

  factory ToolParam.array(
    String name, {
    required ToolParam itemType,
    String? description,
    bool required = false,
  }) => ToolParam._(
    name: name,
    description: description,
    required: required,
    type: 'array',
    itemType: itemType,
  );

  factory ToolParam.enumType(
    String name, {
    required List<String> values,
    String? description,
    bool required = false,
  }) => ToolParam._(
    name: name,
    description: description,
    required: required,
    type: 'string',
    enumValues: values,
  );
}

typedef ToolHandler = Future<dynamic> Function(Map<String, dynamic> args);

class ToolDefinition {
  final String name;
  final String description;
  final List<ToolParam> parameters;
  final ToolHandler? handler;
  const ToolDefinition({
    required this.name,
    this.description = '',
    this.parameters = const [],
    this.handler,
  });
}

// ═══════════════════════════════════════════════════════════════
// Chat generation result (chunk)
// ═══════════════════════════════════════════════════════════════

class LlamaChoice {
  final LlamaChoiceDelta delta;
  const LlamaChoice({required this.delta});
}

class LlamaChoiceDelta {
  final String? content;
  const LlamaChoiceDelta({this.content});
}

class LlamaChatChunk {
  final List<LlamaChoice> choices;
  const LlamaChatChunk({required this.choices});
}

// ═══════════════════════════════════════════════════════════════
// Chat session
// ═══════════════════════════════════════════════════════════════

class ChatSession {
  String? systemPrompt;
  final List<LlamaChatMessage> _messages = [];

  ChatSession(dynamic engine);

  List<LlamaChatMessage> get history => List.unmodifiable(_messages);

  void addMessage(LlamaChatMessage message) {
    _messages.add(message);
  }

  Stream<LlamaChatChunk> create(
    List<LlamaContentPart> parts, {
    List<ToolDefinition>? tools,
    GenerationParams? params,
  }) async* {
    throw UnsupportedError(
      'Embedded LLM (llamadart) is not included in TealKit Light builds. '
      'Use an external local server (llama.cpp, Ollama, LM Studio) or the Full sideload edition.',
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Backend and engine stubs
// ═══════════════════════════════════════════════════════════════

class LlamaBackend {
  LlamaBackend();

  bool get supportsUrlLoading => false;

  Future<bool> isGpuSupported() async => false;

  Future<({int total, int free})> getVramInfo() async => (total: 0, free: 0);

  Future<void> dispose() async {}
}

class LlamaEngine {
  // ignore: unused_field
  final LlamaBackend _backend;

  LlamaEngine(this._backend);

  bool get isReady => false;

  Future<void> setModel(
    LlamaModel model, {
    ModelParams? params,
    void Function(ModelDownloadProgress progress)? onProgress,
  }) async {
    throw UnsupportedError(
      'Embedded LLM (llamadart) is not included in TealKit Light builds. '
      'Use an external local server (llama.cpp, Ollama, LM Studio) or the Full sideload edition.',
    );
  }

  Future<void> loadModel(String modelPath, {ModelParams? modelParams}) async {
    throw UnsupportedError(
      'Embedded LLM (llamadart) is not included in TealKit Light builds.',
    );
  }

  Future<List<double>> embed(String text, {bool normalize = true}) async {
    throw UnsupportedError(
      'Embedded embeddings (llamadart) are not included in this build. '
      'Configure an external Ollama or OpenAI-compatible embedding endpoint.',
    );
  }

  Future<void> unloadModel() async {}

  Future<void> dispose() async {}
}
