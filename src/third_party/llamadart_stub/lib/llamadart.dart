// Stub llamadart for server_light.
// Exports the same public API used by server_embedded_llm_adapter.dart
// but with no-op implementations. server_light never uses embedded LLMs.
library llamadart;

import 'dart:async';

// ═══════════════════════════════════════════════════════════════
// Enums
// ═══════════════════════════════════════════════════════════════

enum LlamaChatRole { user, assistant, tool, system }

// ═══════════════════════════════════════════════════════════════
// Content parts (used in chat messages)
// ═══════════════════════════════════════════════════════════════

abstract class LlamaContentPart {}

class LlamaTextContent extends LlamaContentPart {
  final String text;
  LlamaTextContent(this.text);
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
  final int contextSize;
  final int gpuLayers;
  const ModelParams({this.contextSize = 4096, this.gpuLayers = 0});
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
    throw UnimplementedError(
      'llamadart_stub: ChatSession.create() not available',
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Backend and engine stubs
// ═══════════════════════════════════════════════════════════════

class LlamaBackend {
  LlamaBackend();

  Future<bool> isGpuSupported() async => false;

  Future<({int total, int free})> getVramInfo() async => (total: 0, free: 0);
}

class LlamaEngine {
  final LlamaBackend _backend;

  LlamaEngine(this._backend);

  bool get isReady => false;

  Future<void> loadModel(String modelPath, {ModelParams? modelParams}) async {
    throw UnimplementedError(
      'llamadart_stub: LlamaEngine.loadModel() not available',
    );
  }

  Future<void> unloadModel() async {}

  Future<void> dispose() async {}
}
