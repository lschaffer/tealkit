import 'dart:async';
import 'dart:convert';
import 'package:dart_mcp_core/dart_mcp_core.dart';
import 'package:llamadart/llamadart.dart';

/// CLI adapter that wraps `llamadart` and registers delegates on `LLMService` in `dart_mcp_core`.
class CliEmbeddedLlmAdapter {
  CliEmbeddedLlmAdapter._();
  static final CliEmbeddedLlmAdapter instance = CliEmbeddedLlmAdapter._();

  static final LlamaBackend _backend = LlamaBackend();
  LlamaEngine? _engine;
  String? _loadedModelPath;
  Completer<void>? _loadingCompleter;

  bool get isLoaded => _engine?.isReady == true;
  String? get loadedModelPath => _loadedModelPath;

  /// Loads [modelPath] into [LlamaEngine].
  Future<void> initialize(
    String modelPath, {
    int gpuLayers = 0,
    int contextSize = 4096,
  }) async {
    if (_loadedModelPath == modelPath && isLoaded) return;

    if (_loadingCompleter != null) {
      await _loadingCompleter!.future;
      if (_loadedModelPath == modelPath && isLoaded) return;
    }

    final completer = Completer<void>();
    _loadingCompleter = completer;
    try {
      if (_engine != null && isLoaded) {
        await _engine!.unloadModel();
      }
      _engine ??= LlamaEngine(_backend);
      await _engine!.loadModel(
        modelPath,
        modelParams: ModelParams(
          contextSize: contextSize,
          gpuLayers: gpuLayers,
        ),
      );
      _loadedModelPath = modelPath;
      completer.complete();
    } catch (e) {
      _engine = null;
      _loadedModelPath = null;
      completer.completeError(e);
      rethrow;
    } finally {
      _loadingCompleter = null;
    }
  }

  /// Hook this adapter into `dart_mcp_core.LLMService`.
  void registerWithMcpCore() {
    LLMService.embeddedHandler = ({
      required LlmConfig config,
      required List<ChatMessage> messages,
      required List<MCPTool> tools,
      String? systemPrompt,
    }) async {
      return await generateResponse(
        messages: messages,
        availableTools: tools,
        systemPrompt: systemPrompt,
        temperature: config.temperature,
        maxTokens: config.maxTokens > 0 ? config.maxTokens : 1024,
        topK: config.topK ?? 40,
        topP: config.topP ?? 0.9,
      );
    };

    LLMService.embeddedStreamHandler = ({
      required LlmConfig config,
      required List<ChatMessage> messages,
      required List<MCPTool> tools,
      String? systemPrompt,
    }) {
      return generateStream(
        messages: messages,
        availableTools: tools,
        systemPrompt: systemPrompt,
        temperature: config.temperature,
        maxTokens: config.maxTokens > 0 ? config.maxTokens : 1024,
        topK: config.topK ?? 40,
        topP: config.topP ?? 0.9,
      );
    };
  }

  Future<LLMResponse> generateResponse({
    required List<ChatMessage> messages,
    List<MCPTool>? availableTools,
    String? systemPrompt,
    double temperature = 0.3,
    int maxTokens = 1024,
    int topK = 40,
    double topP = 0.9,
    double penalty = 1.15,
  }) async {
    final engine = _engine;
    if (engine == null || !engine.isReady) {
      throw StateError('Embedded model is not loaded. Call initialize() first.');
    }

    final session = ChatSession(engine);
    if (systemPrompt != null && systemPrompt.trim().isNotEmpty) {
      session.systemPrompt = systemPrompt;
    } else {
      final sysMsg = messages.lastWhereOrNull((m) => m.role == ChatRole.system);
      if (sysMsg != null) {
        session.systemPrompt = sysMsg.content;
      }
    }

    final nonSystem = messages.where((m) => m.role != ChatRole.system).toList();
    if (nonSystem.isEmpty) {
      throw ArgumentError('No user messages in conversation.');
    }

    final lastIsToolResult = nonSystem.last.role == ChatRole.tool;
    final historySlice = lastIsToolResult
        ? nonSystem
        : nonSystem.take(nonSystem.length - 1).toList();
    _populateHistory(session, historySlice);

    final inputParts = <LlamaContentPart>[];
    if (!lastIsToolResult) {
      final lastMsg = nonSystem.last;
      inputParts.add(LlamaTextContent(lastMsg.content));
      if (lastMsg.attachments != null) {
        for (final att in lastMsg.attachments!) {
          final mime = att.mimeType.toLowerCase();
          if (mime.startsWith('image/') && att.bytes != null) {
            inputParts.add(LlamaImageContent(bytes: att.bytes!));
          }
        }
      }
    }

    final toolDefs = availableTools != null && availableTools.isNotEmpty
        ? _convertTools(availableTools)
        : null;

    final params = GenerationParams(
      maxTokens: maxTokens,
      temp: temperature,
      topK: topK,
      topP: topP,
      penalty: penalty,
    );

    String fullText = '';
    await for (final chunk in session.create(inputParts, tools: toolDefs, params: params)) {
      if (chunk.choices.isNotEmpty) {
        final content = chunk.choices.first.delta.content;
        if (content != null && content.isNotEmpty) {
          fullText += content;
        }
      }
    }

    final lastHistoryMsg = session.history.lastOrNull;
    var toolCalls = lastHistoryMsg?.parts
            .whereType<LlamaToolCallContent>()
            .map(
              (tc) => LLMToolCall(
                id: tc.id ?? '',
                name: tc.name,
                arguments: tc.arguments,
              ),
            )
            .toList() ??
        [];

    if (toolCalls.isEmpty && fullText.isNotEmpty) {
      final parsed = _extractTextToolCall(fullText);
      if (parsed != null) {
        toolCalls = [parsed];
        fullText = '';
      }
    }

    return LLMResponse(
      text: fullText,
      toolCalls: toolCalls,
      usage: const LLMUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0),
    );
  }

  Stream<LLMStreamChunk> generateStream({
    required List<ChatMessage> messages,
    List<MCPTool>? availableTools,
    String? systemPrompt,
    double temperature = 0.3,
    int maxTokens = 1024,
    int topK = 40,
    double topP = 0.9,
    double penalty = 1.15,
  }) async* {
    final engine = _engine;
    if (engine == null || !engine.isReady) {
      throw StateError('Embedded model is not loaded. Call initialize() first.');
    }

    final session = ChatSession(engine);
    if (systemPrompt != null && systemPrompt.trim().isNotEmpty) {
      session.systemPrompt = systemPrompt;
    } else {
      final sysMsg = messages.lastWhereOrNull((m) => m.role == ChatRole.system);
      if (sysMsg != null) {
        session.systemPrompt = sysMsg.content;
      }
    }

    final nonSystem = messages.where((m) => m.role != ChatRole.system).toList();
    if (nonSystem.isEmpty) {
      throw ArgumentError('No user messages in conversation.');
    }

    final lastIsToolResult = nonSystem.last.role == ChatRole.tool;
    final historySlice = lastIsToolResult
        ? nonSystem
        : nonSystem.take(nonSystem.length - 1).toList();
    _populateHistory(session, historySlice);

    final inputParts = <LlamaContentPart>[];
    if (!lastIsToolResult) {
      final lastMsg = nonSystem.last;
      inputParts.add(LlamaTextContent(lastMsg.content));
      if (lastMsg.attachments != null) {
        for (final att in lastMsg.attachments!) {
          final mime = att.mimeType.toLowerCase();
          if (mime.startsWith('image/') && att.bytes != null) {
            inputParts.add(LlamaImageContent(bytes: att.bytes!));
          }
        }
      }
    }

    final toolDefs = availableTools != null && availableTools.isNotEmpty
        ? _convertTools(availableTools)
        : null;

    final params = GenerationParams(
      maxTokens: maxTokens,
      temp: temperature,
      topK: topK,
      topP: topP,
      penalty: penalty,
    );

    String fullText = '';
    await for (final chunk in session.create(inputParts, tools: toolDefs, params: params)) {
      if (chunk.choices.isNotEmpty) {
        final content = chunk.choices.first.delta.content;
        if (content != null && content.isNotEmpty) {
          fullText += content;
          yield LLMStreamChunk(textDelta: content);
        }
      }
    }

    final lastHistoryMsg = session.history.lastOrNull;
    var toolCalls = lastHistoryMsg?.parts
            .whereType<LlamaToolCallContent>()
            .map(
              (tc) => LLMToolCall(
                id: tc.id ?? '',
                name: tc.name,
                arguments: tc.arguments,
              ),
            )
            .toList() ??
        [];

    if (toolCalls.isEmpty && fullText.isNotEmpty) {
      final parsed = _extractTextToolCall(fullText);
      if (parsed != null) {
        toolCalls = [parsed];
        fullText = '';
      }
    }

    yield LLMStreamChunk(
      textDelta: '',
      isDone: true,
      finalResponse: LLMResponse(
        text: fullText,
        toolCalls: toolCalls,
        usage: const LLMUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0),
      ),
    );
  }

  void _populateHistory(ChatSession session, List<ChatMessage> messages) {
    int i = 0;
    while (i < messages.length) {
      final msg = messages[i];
      if (msg.role == ChatRole.user) {
        session.addMessage(
          LlamaChatMessage.fromText(role: LlamaChatRole.user, text: msg.content),
        );
        i++;
      } else if (msg.role == ChatRole.assistant) {
        int j = i + 1;
        final toolResults = <ChatMessage>[];
        while (j < messages.length && messages[j].role == ChatRole.tool) {
          toolResults.add(messages[j]);
          j++;
        }

        if (toolResults.isNotEmpty) {
          final parts = toolResults
              .map<LlamaContentPart>(
                (tr) => LlamaToolCallContent(
                  id: tr.id,
                  name: tr.toolName ?? 'tool',
                  arguments: const {},
                  rawJson: '{"name":"${tr.toolName ?? "tool"}","arguments":{}}',
                ),
              )
              .toList();
          session.addMessage(
            LlamaChatMessage.withContent(
              role: LlamaChatRole.assistant,
              content: parts,
            ),
          );

          for (final tr in toolResults) {
            final resultText = tr.content;
            session.addMessage(
              LlamaChatMessage.withContent(
                role: LlamaChatRole.tool,
                content: [
                  LlamaToolResultContent(
                    id: tr.id,
                    name: tr.toolName ?? 'tool',
                    result: resultText,
                  ),
                ],
              ),
            );
          }
          i = j;
        } else {
          session.addMessage(
            LlamaChatMessage.fromText(
              role: LlamaChatRole.assistant,
              text: msg.content,
            ),
          );
          i++;
        }
      } else if (msg.role == ChatRole.tool) {
        session.addMessage(
          LlamaChatMessage.withContent(
            role: LlamaChatRole.tool,
            content: [
              LlamaToolResultContent(
                id: msg.id,
                name: msg.toolName ?? 'tool',
                result: msg.content,
              ),
            ],
          ),
        );
        i++;
      } else {
        i++;
      }
    }
  }

  LLMToolCall? _extractTextToolCall(String text) {
    final match = RegExp(
      r'tool_call:\s*(\w+)\s*(\{[\s\S]*\})',
      caseSensitive: false,
    ).firstMatch(text);
    if (match != null) {
      final name = match.group(1)!;
      final rawArgs = match.group(2)!;
      try {
        final args = jsonDecode(rawArgs) as Map<String, dynamic>;
        return LLMToolCall(
          id: 'call_${DateTime.now().millisecondsSinceEpoch}',
          name: name,
          arguments: args,
        );
      } catch (_) {}
    }
    return null;
  }

  List<ToolDefinition> _convertTools(List<MCPTool> tools) {
    return tools.map((tool) {
      final params = _schemaToParams(tool.inputSchema);
      return ToolDefinition(
        name: tool.name,
        description: tool.description ?? '',
        parameters: params,
        handler: (_) async => null,
      );
    }).toList();
  }

  List<ToolParam> _schemaToParams(Map<String, dynamic>? schema) {
    final rawProps = schema?['properties'];
    final props = rawProps == null
        ? <String, dynamic>{}
        : (rawProps as Map).cast<String, dynamic>();
    final rawRequired = schema?['required'];
    final required = rawRequired == null
        ? <String>[]
        : (rawRequired as List).cast<String>();

    return props.entries.map((entry) {
      final def = (entry.value as Map).cast<String, dynamic>();
      final isRequired = required.contains(entry.key);
      final desc = def['description'] as String?;
      final type = def['type'] as String? ?? 'string';

      switch (type) {
        case 'integer':
          return ToolParam.integer(entry.key, description: desc, required: isRequired);
        case 'number':
          return ToolParam.number(entry.key, description: desc, required: isRequired);
        case 'boolean':
          return ToolParam.boolean(entry.key, description: desc, required: isRequired);
        case 'array':
          return ToolParam.array(
            entry.key,
            itemType: ToolParam.string('item'),
            description: desc,
            required: isRequired,
          );
        default:
          final enumVals = (def['enum'] as List?)?.cast<String>();
          if (enumVals != null && enumVals.isNotEmpty) {
            return ToolParam.enumType(
              entry.key,
              values: enumVals,
              description: desc,
              required: isRequired,
            );
          }
          return ToolParam.string(entry.key, description: desc, required: isRequired);
      }
    }).toList();
  }
}

extension<T> on List<T> {
  T? lastWhereOrNull(bool Function(T) test) {
    for (int i = length - 1; i >= 0; i--) {
      if (test(this[i])) return this[i];
    }
    return null;
  }
}
