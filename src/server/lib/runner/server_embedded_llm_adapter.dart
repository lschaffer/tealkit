import 'dart:async';
import 'dart:convert';

import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as p;

import '../config/server_config_service.dart';
import '../models/mcp_models.dart';
import 'server_embedded_types.dart';

export 'server_embedded_types.dart'; // Re-export for backward compatibility

class ServerEmbeddedLlmAdapter {
  ServerEmbeddedLlmAdapter._();
  static final ServerEmbeddedLlmAdapter instance = ServerEmbeddedLlmAdapter._();

  static const int _defaultContextSize = 4096;

  LlamaEngine? _engine;
  String? _loadedModelPath;
  Completer<void>? _loadingCompleter;

  bool _exclusiveRunActive = false;
  final List<Completer<void>> _runWaiters = <Completer<void>>[];

  bool get isLoaded => _engine?.isReady == true;
  String? get loadedModelPath => _loadedModelPath;

  static LlamaBackend? _backend;

  static LlamaBackend _getBackend() {
    _backend ??= LlamaBackend();
    return _backend!;
  }

  Future<T> runExclusive<T>(
    Future<T> Function() action, {
    Duration? waitTimeout,
  }) async {
    if (_exclusiveRunActive) {
      final waiter = Completer<void>();
      _runWaiters.add(waiter);
      if (waitTimeout != null) {
        await waiter.future.timeout(
          waitTimeout,
          onTimeout: () => throw TimeoutException(
            'Timed out waiting for embedded model execution slot after ${waitTimeout.inMinutes} minutes. Another run may be stuck; retry or restart the server.',
          ),
        );
      } else {
        await waiter.future;
      }
    }

    _exclusiveRunActive = true;
    try {
      return await action();
    } finally {
      _exclusiveRunActive = false;
      if (_runWaiters.isNotEmpty) {
        _runWaiters.removeAt(0).complete();
      }
    }
  }

  Future<void> initialize(
    String modelPath, {
    int? gpuLayers,
    int contextSize = _defaultContextSize,
  }) async {
    if (_loadedModelPath == modelPath && isLoaded) return;

    if (_loadingCompleter != null) {
      await _loadingCompleter!.future;
      if (_loadedModelPath == modelPath && isLoaded) return;
    }

    final filename = p.basename(modelPath);
    final configKey = 'embedded_gpu_layers_$filename';

    // Determine target gpuLayers:
    // If not null, save and use it.
    // If null, try loading from config service, fallback to 0.
    final int targetGpuLayers;
    if (gpuLayers != null) {
      targetGpuLayers = gpuLayers;
      try {
        await ServerConfigService().setInt(configKey, gpuLayers);
      } catch (_) {}
    } else {
      int? cached;
      try {
        cached = ServerConfigService().getInt(configKey);
      } catch (_) {}
      targetGpuLayers = cached ?? 0;
    }

    final completer = Completer<void>();
    _loadingCompleter = completer;
    try {
      await _unloadCurrentModel();
      _engine ??= LlamaEngine(_getBackend());
      await _engine!.loadModel(
        modelPath,
        modelParams: ModelParams(
          contextSize: contextSize,
          gpuLayers: targetGpuLayers,
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

  Future<void> _unloadCurrentModel() async {
    if (_engine != null && isLoaded) {
      await _engine!.unloadModel();
    }
    _loadedModelPath = null;
  }

  Future<void> dispose() async {
    await _unloadCurrentModel();
    _engine = null;
  }

  Future<bool> isGpuSupported() async {
    try {
      return await _getBackend().isGpuSupported();
    } catch (_) {
      return false;
    }
  }

  Future<({int total, int free})> getVramInfo() async {
    try {
      return await _getBackend().getVramInfo();
    } catch (_) {
      return (total: 0, free: 0);
    }
  }

  Future<ServerEmbeddedGenerationResult> generateResponse({
    required List<ServerEmbeddedChatMessage> messages,
    List<MCPTool>? availableTools,
    double temperature = 0.3,
    int maxTokens = 1024,
    int topK = 40,
    double topP = 0.9,
    double penalty = 1.15,
  }) async {
    final engine = _engine;
    if (engine == null || !engine.isReady) {
      throw StateError('Embedded model not loaded. Call initialize() first.');
    }

    final session = ChatSession(engine);
    final systemMsg = messages.lastWhereOrNull(
      (m) => m.role == ServerEmbeddedChatRole.system,
    );
    if (systemMsg != null) {
      session.systemPrompt = systemMsg.content;
    }

    final nonSystem = messages
        .where((m) => m.role != ServerEmbeddedChatRole.system)
        .toList();
    if (nonSystem.isEmpty) {
      throw ArgumentError('No user messages in conversation.');
    }

    final lastIsToolResult = nonSystem.last.role == ServerEmbeddedChatRole.tool;
    final historySlice = lastIsToolResult
        ? nonSystem
        : nonSystem.take(nonSystem.length - 1).toList();
    _populateHistory(session, historySlice);

    final inputParts = <LlamaContentPart>[];
    if (!lastIsToolResult) {
      inputParts.add(LlamaTextContent(nonSystem.last.content));
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

    var fullText = '';
    await for (final chunk in session.create(
      inputParts,
      tools: toolDefs,
      params: params,
    )) {
      if (chunk.choices.isNotEmpty) {
        final content = chunk.choices.first.delta.content;
        if (content != null && content.isNotEmpty) {
          fullText += content;
        }
      }
    }

    final lastHistoryMsg = session.history.lastOrNull;
    final toolCalls =
        lastHistoryMsg?.parts
            .whereType<LlamaToolCallContent>()
            .map(
              (tc) => ServerEmbeddedToolCall(
                id: tc.id,
                name: tc.name,
                arguments: tc.arguments,
              ),
            )
            .toList() ??
        const <ServerEmbeddedToolCall>[];

    return ServerEmbeddedGenerationResult(
      content: fullText,
      toolCalls: toolCalls,
    );
  }

  void _populateHistory(
    ChatSession session,
    List<ServerEmbeddedChatMessage> messages,
  ) {
    var index = 0;
    while (index < messages.length) {
      final msg = messages[index];

      if (msg.role == ServerEmbeddedChatRole.human) {
        session.addMessage(
          LlamaChatMessage.fromText(
            role: LlamaChatRole.user,
            text: msg.content,
          ),
        );
        index++;
        continue;
      }

      if (msg.role == ServerEmbeddedChatRole.ai) {
        final toolResults = <ServerEmbeddedChatMessage>[];
        var lookahead = index + 1;
        while (lookahead < messages.length &&
            messages[lookahead].role == ServerEmbeddedChatRole.tool) {
          toolResults.add(messages[lookahead]);
          lookahead++;
        }

        if (toolResults.isNotEmpty) {
          final parts = toolResults
              .map<LlamaContentPart>(
                (toolResult) => LlamaToolCallContent(
                  id: toolResult.toolCallId,
                  name: toolResult.toolName ?? 'tool',
                  arguments: const <String, dynamic>{},
                  rawJson: jsonEncode({
                    'name': toolResult.toolName ?? 'tool',
                    'arguments': const <String, dynamic>{},
                  }),
                ),
              )
              .toList(growable: false);
          session.addMessage(
            LlamaChatMessage.withContent(
              role: LlamaChatRole.assistant,
              content: parts,
            ),
          );

          for (final toolResult in toolResults) {
            session.addMessage(
              LlamaChatMessage.withContent(
                role: LlamaChatRole.tool,
                content: [
                  LlamaToolResultContent(
                    id: toolResult.toolCallId,
                    name: toolResult.toolName ?? 'tool',
                    result: toolResult.content,
                  ),
                ],
              ),
            );
          }

          index = lookahead;
          continue;
        }

        session.addMessage(
          LlamaChatMessage.fromText(
            role: LlamaChatRole.assistant,
            text: msg.content,
          ),
        );
        index++;
        continue;
      }

      if (msg.role == ServerEmbeddedChatRole.tool) {
        session.addMessage(
          LlamaChatMessage.withContent(
            role: LlamaChatRole.tool,
            content: [
              LlamaToolResultContent(
                id: msg.toolCallId,
                name: msg.toolName ?? 'tool',
                result: msg.content,
              ),
            ],
          ),
        );
        index++;
        continue;
      }

      index++;
    }
  }

  List<ToolDefinition> _convertTools(List<MCPTool> tools) {
    return tools
        .map((tool) {
          final params = _schemaToParams(tool.inputSchema);
          return ToolDefinition(
            name: tool.name,
            description: tool.description ?? '',
            parameters: params,
            handler: (_) async => null,
          );
        })
        .toList(growable: false);
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

    return props.entries
        .map((entry) {
          final def = (entry.value as Map).cast<String, dynamic>();
          final isRequired = required.contains(entry.key);
          final desc = def['description'] as String?;
          final type = def['type'] as String? ?? 'string';

          switch (type) {
            case 'integer':
              return ToolParam.integer(
                entry.key,
                description: desc,
                required: isRequired,
              );
            case 'number':
              return ToolParam.number(
                entry.key,
                description: desc,
                required: isRequired,
              );
            case 'boolean':
              return ToolParam.boolean(
                entry.key,
                description: desc,
                required: isRequired,
              );
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
              return ToolParam.string(
                entry.key,
                description: desc,
                required: isRequired,
              );
          }
        })
        .toList(growable: false);
  }
}

extension<T> on List<T> {
  T? get lastOrNull => isEmpty ? null : last;

  T? lastWhereOrNull(bool Function(T value) test) {
    for (var index = length - 1; index >= 0; index--) {
      if (test(this[index])) return this[index];
    }
    return null;
  }
}
