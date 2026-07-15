import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:llamadart/llamadart.dart';
import '../../models/mcp_models.dart';
import '../llm_service.dart';

/// Adapter that wraps the llamadart library and exposes an interface compatible
/// with [LLMService]. This is the ONLY place where llamadart is used.
///
/// The adapter is a singleton and keeps the [LlamaEngine] alive between calls
/// to avoid the heavy cost of model reloading. It creates a fresh [ChatSession]
/// on each [generateResponse] call (stateless per-request, matching other
/// provider behaviour).
///
/// Tool calling: tool definitions are passed to llamadart. After the stream
/// finishes, any [LlamaToolCallContent] parts from the last assistant message
/// are converted to [LLMToolCall] objects and returned in [LLMResponse].
/// [ChatService] then executes the tools and recurses — exactly as with every
/// other provider. No internal tool loop lives inside this adapter.
class EmbeddedLlmAdapter {
  EmbeddedLlmAdapter._();
  static final EmbeddedLlmAdapter instance = EmbeddedLlmAdapter._();

  // LlamaBackend registers ggml backends globally. Creating it more than once
  // exceeds GGML_SCHED_MAX_BACKENDS and hard-crashes the process. Keep a single
  // instance for the entire app lifetime.
  static final LlamaBackend _backend = LlamaBackend();

  LlamaEngine? _engine;
  String? _loadedModelPath;
  Completer<void>? _loadingCompleter;

  bool get isLoaded => _engine?.isReady == true;
  String? get loadedModelPath => _loadedModelPath;

  // ── Lifecycle ────────────────────────────────────────────────────────────────

  /// Loads [modelPath] into [LlamaEngine].
  ///
  /// If the same path is already loaded the call is a no-op. Otherwise the
  /// previous model is unloaded first.
  ///
  /// IMPORTANT: We never call [LlamaEngine.dispose] / [LlamaBackend.dispose]
  /// during a model switch because [_backend] is a static singleton that
  /// registers GGML backends globally. Disposing it invalidates native state
  /// and causes the next [loadModel] call to hang. We only call [unloadModel]
  /// (which frees the native model/context handles) and reuse the same
  /// [LlamaEngine] instance.
  ///
  /// If a load is already in progress, this call waits for it to complete and
  /// then returns (instead of silently returning immediately, which would leave
  /// callers thinking the model is ready when it isn't).
  /// Maximum context size allocated on mobile (Android/iOS).
  ///
  /// Larger contexts increase KV-cache memory linearly. 4K tokens is a safe
  /// cap for mobile: a 9B Q4_0 model already consumes ~4.9 GB for weights;
  /// a 4K KV-cache adds ~600 MB, keeping total RSS below the Android OOM
  /// threshold. 8K caused process kills on Samsung S25 Ultra (12 GB RAM).
  /// Tool-result truncation (_maxToolResultChars = 2500 chars) ensures
  /// conversations fit comfortably within 4096 tokens.
  /// On desktop the caller-supplied value (or 0 = model native max) is used.
  static const int _mobileMaxContextSize = 4096;

  Future<void> initialize(String modelPath, {int gpuLayers = 0, int contextSize = 4096, void Function(double progress)? onProgress}) async {
    // On mobile, cap context size to avoid KV-cache OOM even when the model
    // advertises a larger native context (e.g. Qwen3 128K).
    final effectiveContextSize = _shouldTruncate ? contextSize.clamp(1, _mobileMaxContextSize) : contextSize;
    if (_loadedModelPath == modelPath && isLoaded) return;

    // If another load is in progress, wait for it to finish before proceeding.
    if (_loadingCompleter != null) {
      await _loadingCompleter!.future;
      // After the previous load finished, re-check if the right model is loaded.
      if (_loadedModelPath == modelPath && isLoaded) return;
    }

    final completer = Completer<void>();
    _loadingCompleter = completer;
    try {
      // Unload any currently loaded model without disposing the shared backend.
      await _unloadCurrentModel();
      onProgress?.call(0.0);

      // Reuse the single LlamaEngine instance; create it only on first use.
      _engine ??= LlamaEngine(_backend);
      await _engine!.loadModel(
        modelPath,
        modelParams: ModelParams(contextSize: effectiveContextSize, gpuLayers: gpuLayers),
      );

      _loadedModelPath = modelPath;
      onProgress?.call(1.0);
      completer.complete();
    } catch (e) {
      // On failure reset so the next attempt starts clean.
      _engine = null;
      _loadedModelPath = null;
      completer.completeError(e);
      rethrow;
    } finally {
      _loadingCompleter = null;
    }
  }

  /// Unloads the current model (frees native handles) without touching the
  /// shared [_backend]. The [LlamaEngine] instance is kept alive for reuse.
  Future<void> _unloadCurrentModel() async {
    if (_engine != null && isLoaded) {
      await _engine!.unloadModel();
    }
    _loadedModelPath = null;
  }

  /// Unloads the model and releases the engine. Safe to call from the UI
  /// "Unload" button. Does NOT dispose [_backend] — the GGML backend must
  /// remain registered for the entire app lifetime.
  Future<void> dispose() async {
    await _unloadCurrentModel();
    _engine = null;
  }

  // ── GPU capabilities ───────────────────────────────────────────────────────

  /// Returns `true` when the device's hardware and the active GGML backend
  /// (Vulkan on Android, Metal on iOS/macOS) support GPU-accelerated inference.
  ///
  /// This calls into the native backend isolate and is cheap to invoke — it
  /// does NOT require a model to be loaded.
  Future<bool> isGpuSupported() async {
    try {
      return await _backend.isGpuSupported();
    } catch (_) {
      return false;
    }
  }

  /// Returns total and free VRAM reported by the active GPU backend, in bytes.
  /// Both values are 0 when the device has no GPU or GPU is not supported.
  Future<({int total, int free})> getVramInfo() async {
    try {
      return await _backend.getVramInfo();
    } catch (_) {
      return (total: 0, free: 0);
    }
  }

  // ── Inference ────────────────────────────────────────────────────────────────

  /// Generates a response for the given [messages] history.
  ///
  /// Returns an [LLMResponse] with [toolCalls] populated when the model wants
  /// to invoke tools. [ChatService] handles execution and recursion.
  Future<LLMResponse> generateResponse({
    required List<ChatMessage> messages,
    List<MCPTool>? availableTools,
    double temperature = 0.3,
    int maxTokens = 1024,
    int topK = 40,
    double topP = 0.9,
    double penalty = 1.15,
    void Function(String chunk)? onStreamChunk,
  }) async {
    final engine = _engine;
    if (engine == null || !engine.isReady) {
      throw StateError('Embedded model not loaded. Call initialize() first.');
    }

    // ── Build session from message history ──────────────────────────────────
    final session = ChatSession(engine);

    // Use the last system message as the session system prompt.
    final systemMsg = messages.lastWhereOrNull((m) => m.role == ChatRole.system);
    if (systemMsg != null) {
      session.systemPrompt = systemMsg.content;
    }

    // Non-system messages (all except the last user message we'll pass to create()).
    final nonSystem = messages.where((m) => m.role != ChatRole.system).toList();
    if (nonSystem.isEmpty) {
      throw ArgumentError('No user messages in conversation.');
    }

    // When the last message is a tool result, all messages (including the
    // tool result) belong in history and we generate with empty parts —
    // exactly the pattern recommended by llamadart's chat_session API:
    //   session.addMessage(toolResultMsg);
    //   session.create([])  →  model responds to the tool result.
    //
    // When the last message is a user turn (normal chat), all prior messages
    // are history and the last message is the current user input.
    final lastIsToolResult = nonSystem.last.role == ChatRole.tool;
    final historySlice = lastIsToolResult ? nonSystem : nonSystem.take(nonSystem.length - 1).toList();
    _populateHistory(session, historySlice);

    // ── Current user turn (empty when responding to a tool result) ───────────
    final inputParts = <LlamaContentPart>[];
    if (!lastIsToolResult) {
      final lastMsg = nonSystem.last;
      inputParts.add(LlamaTextContent(lastMsg.content));
      // Inject any attachments (images only for now) if present.
      if (lastMsg.attachments != null) {
        for (final att in lastMsg.attachments!) {
          final mime = att.mimeType?.toLowerCase() ?? '';
          if (mime.startsWith('image/') && att.bytes != null) {
            inputParts.add(LlamaImageContent(bytes: att.bytes!));
          }
        }
      }
    }

    // ── Tool definitions ─────────────────────────────────────────────────────
    final toolDefs = availableTools != null && availableTools.isNotEmpty ? _convertTools(availableTools) : null;

    // ── Stream generation ────────────────────────────────────────────────────
    final params = GenerationParams(maxTokens: maxTokens, temp: temperature, topK: topK, topP: topP, penalty: penalty);

    String fullText = '';
    await for (final chunk in session.create(inputParts, tools: toolDefs, params: params)) {
      if (chunk.choices.isNotEmpty) {
        final content = chunk.choices.first.delta.content;
        if (content != null && content.isNotEmpty) {
          fullText += content;
          onStreamChunk?.call(content);
        }
      }
    }

    // ── Extract tool calls ───────────────────────────────────────────────────
    // Primary: native llamadart tool-call parts (models that output [TOOL_CALLS] format).
    final lastHistoryMsg = session.history.lastOrNull;
    var toolCalls =
        lastHistoryMsg?.parts
            .whereType<LlamaToolCallContent>()
            .map((tc) => LLMToolCall(id: tc.id, name: tc.name, arguments: tc.arguments))
            .toList() ??
        [];

    // Fallback: models trained with the plain-text "tool_call: {...}" format
    // (e.g. ministral3b-tealkit) output the call in the text stream rather than
    // as a native tool-call part.  Parse it here so ChatService can execute it.
    if (toolCalls.isEmpty && fullText.isNotEmpty) {
      final parsed = _extractTextToolCall(fullText);
      if (parsed != null) {
        toolCalls = [parsed];
        fullText = ''; // suppress the raw text; caller sees only the tool call
      }
    }

    return LLMResponse(
      content: fullText,
      toolCalls: toolCalls,
      usage: const LLMUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0),
      finishReason: toolCalls.isNotEmpty ? 'tool_calls' : 'stop',
    );
  }

  // ── History builder ──────────────────────────────────────────────────────────

  /// Adds [messages] (all non-system history except the current prompt) to [session].
  ///
  /// Handles the assistant → tool-result pattern by reconstructing tool-call
  /// content from the tool-result message metadata so that llamadart's template
  /// engine sees proper assistant⟶tool pairs.
  void _populateHistory(ChatSession session, List<ChatMessage> messages) {
    int i = 0;
    while (i < messages.length) {
      final msg = messages[i];

      if (msg.role == ChatRole.user) {
        session.addMessage(LlamaChatMessage.fromText(role: LlamaChatRole.user, text: msg.content));
        i++;
      } else if (msg.role == ChatRole.assistant) {
        // Peek ahead: if the next message(s) are tool results, this assistant
        // message was a tool-calling turn. Reconstruct it with tool-call parts.
        int j = i + 1;
        final toolResults = <ChatMessage>[];
        while (j < messages.length && messages[j].role == ChatRole.tool) {
          toolResults.add(messages[j]);
          j++;
        }

        if (toolResults.isNotEmpty) {
          // Synthesise tool-call content parts for the assistant message.
          final parts = toolResults
              .map<LlamaContentPart>(
                (tr) => LlamaToolCallContent(
                  id: tr.id,
                  name: tr.lastCalledToolName ?? 'tool',
                  arguments: const {},
                  rawJson: '{"name":"${tr.lastCalledToolName ?? "tool"}","arguments":{}}',
                ),
              )
              .toList();
          session.addMessage(LlamaChatMessage.withContent(role: LlamaChatRole.assistant, content: parts));

          // Now add each tool result.
          for (final tr in toolResults) {
            final resultText = _truncateToolResult(_extractToolResultText(tr.toolResult?.content, tr.content));
            session.addMessage(
              LlamaChatMessage.withContent(
                role: LlamaChatRole.tool,
                content: [LlamaToolResultContent(id: tr.id, name: tr.lastCalledToolName ?? 'tool', result: resultText)],
              ),
            );
          }

          i = j; // Skip the tool messages we already processed.
        } else {
          // Plain assistant message (no following tool results).
          session.addMessage(LlamaChatMessage.fromText(role: LlamaChatRole.assistant, text: msg.content));
          i++;
        }
      } else if (msg.role == ChatRole.tool) {
        // Orphan tool message (shouldn't normally happen but handle gracefully).
        final resultText = _truncateToolResult(_extractToolResultText(msg.toolResult?.content, msg.content));
        session.addMessage(
          LlamaChatMessage.withContent(
            role: LlamaChatRole.tool,
            content: [LlamaToolResultContent(id: msg.id, name: msg.lastCalledToolName ?? 'tool', result: resultText)],
          ),
        );
        i++;
      } else {
        i++;
      }
    }
  }

  // ── Tool result truncation ───────────────────────────────────────────────────

  /// Whether tool result truncation should be applied.
  ///
  /// On mobile (Android / iOS) the native inference engine shares RAM with the
  /// OS and all other apps, so large tool outputs can push prefill compute
  /// buffers past the OOM threshold.  On desktop platforms (macOS, Windows,
  /// Linux) available memory is typically abundant and truncation is skipped
  /// entirely so the model sees full output.
  static bool get _shouldTruncate => Platform.isAndroid || Platform.isIOS;

  /// Extracts plain text from a list of [MCPContent] items, skipping images
  /// and binary data.  Image/binary items are replaced with a one-line notice
  /// so the model knows an output was produced without seeing the raw data.
  ///
  /// Falls back to [fallback] when [contents] is null or empty.
  String _extractToolResultText(List<MCPContent>? contents, String fallback) {
    if (contents == null || contents.isEmpty) return fallback;

    final parts = <String>[];
    int skippedImages = 0;

    for (final c in contents) {
      final mime = c.mimeType?.toLowerCase() ?? '';
      final isImage = c.type == 'image' || mime.startsWith('image/') || mime == 'application/octet-stream';

      // Content item has an explicit data/binary field → skip
      if (isImage || (c.data != null && c.data!.isNotEmpty)) {
        skippedImages++;
        continue;
      }

      final text = c.text;
      if (text == null || text.trim().isEmpty) continue;

      // Detect base64-encoded blobs in text fields: long run of base64 chars
      // with no spaces/newlines is almost certainly binary, not readable text.
      if (_looksLikeBase64Blob(text)) {
        skippedImages++;
        continue;
      }

      // Strip embedded base64 from JSON wrappers, e.g.:
      // {"success": true, "data": {"content": "<base64>", "fileName": "report.xlsx"}}
      String trimmed = text.trim();
      if (trimmed.startsWith('{')) {
        try {
          final json = jsonDecode(trimmed) as Map<String, dynamic>?;
          if (json != null) {
            final data = json['data'];
            if (data is Map) {
              final inner = data['content'];
              if (inner is String && _looksLikeBase64Blob(inner)) {
                final summary = <String, dynamic>{
                  if (json['success'] != null) 'success': json['success'],
                  'message': 'File generated and available in the UI.',
                  if (data['fileName'] != null) 'fileName': data['fileName'],
                  if (data['mimeType'] != null) 'mimeType': data['mimeType'],
                  if (data['size'] != null) 'size': data['size'],
                };
                trimmed = jsonEncode(summary);
              }
            }
          }
        } catch (_) {}
      }

      parts.add(trimmed);
    }

    if (parts.isEmpty) {
      if (skippedImages > 0) {
        return '[Tool produced $skippedImages image/binary output(s). '
            'The file has been saved and is visible in the UI. '
            'Do not describe or reproduce the binary data.]';
      }
      return fallback;
    }

    final joined = parts.join('\n');
    if (skippedImages > 0) {
      return '$joined\n[$skippedImages image/binary output(s) omitted — visible in UI]';
    }
    return joined;
  }

  /// Returns true if [text] looks like a raw base64-encoded blob.
  ///
  /// Heuristic: ≥ 256 characters of base64 alphabet with no whitespace.
  /// Real textual content always contains spaces or newlines.
  static bool _looksLikeBase64Blob(String text) {
    if (text.length < 256) return false;
    // If the text has no whitespace at all and consists only of base64 chars it
    // is almost certainly a binary payload.
    final hasWhitespace = text.contains(' ') || text.contains('\n') || text.contains('\t');
    if (hasWhitespace) return false;
    return RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(text);
  }

  /// Maximum characters of tool result text passed to the native inference
  /// engine per tool call. Limits prefill memory (compute buffers scale with
  /// sequence length) and prevents OOM on memory-constrained devices when
  /// running multi-turn conversations with large tool outputs.
  static const int _maxToolResultChars = 2500;

  /// Prepares tool result text for the native inference engine.
  ///
  /// 1. If the text is a JSON script/command result, the textual payload
  ///    (`stdout`, `output`, etc.) is extracted so the JSON envelope does
  ///    not burn context tokens.
  /// 2. On mobile, if the result exceeds [_maxToolResultChars] the entire
  ///    payload is replaced with an error notice — no partial content is
  ///    sent, which prevents the model from hallucinating the missing data.
  ///    Tell the user to use a desktop agent or a smaller/filtered command.
  String _truncateToolResult(String text) {
    final payload = _extractTextualPayload(text);
    if (!_shouldTruncate || payload.length <= _maxToolResultChars) return payload;
    return '[TOOL OUTPUT BLOCKED — the output was ${payload.length} characters, '
        'which exceeds the on-device limit of $_maxToolResultChars characters. '
        'The result has NOT been sent to the model to prevent memory issues and hallucinations. '
        'Please retry with a more specific or filtered command that produces less output, '
        'or use a cloud/desktop agent for commands with large outputs.]';
  }

  /// If [text] is a JSON object that contains a recognisable textual payload
  /// field (stdout, stderr, output, text, result), returns that field value.
  /// Otherwise returns [text] unchanged.
  String _extractTextualPayload(String text) {
    if (!text.startsWith('{')) return text;
    try {
      final json = jsonDecode(text) as Map<String, dynamic>?;
      if (json == null) return text;
      // Prefer stdout for run_script / execute_command results.
      final stdout = json['stdout'] as String?;
      if (stdout != null && stdout.trim().isNotEmpty) return stdout.trim();
      // Fallback: other common textual payload keys.
      for (final key in const ['output', 'text', 'result', 'content']) {
        final v = json[key];
        if (v is String && v.trim().isNotEmpty) return v.trim();
      }
    } catch (_) {}
    return text;
  }

  // ── Plain-text tool-call parser ────────────────────────────────────────────

  /// Parses a plain-text tool call in the form produced by models trained on
  /// the `tool_call: {"name": "...", "arguments": {...}}` format.
  ///
  /// Returns null when no valid tool call is found.
  static LLMToolCall? _extractTextToolCall(String content) {
    try {
      Map<String, dynamic>? payload;

      // Try "tool_call: {…}" prefix first.
      final marker = content.indexOf('tool_call:');
      if (marker >= 0) {
        final firstBrace = content.indexOf('{', marker);
        if (firstBrace >= 0) {
          final jsonStr = _extractBalancedJson(content, firstBrace);
          if (jsonStr.isNotEmpty) {
            final decoded = jsonDecode(jsonStr);
            if (decoded is Map<String, dynamic>) payload = decoded;
          }
        }
      }

      // Fallback: bare JSON object anywhere in the text.
      if (payload == null) {
        final firstBrace = content.indexOf('{');
        if (firstBrace >= 0) {
          final jsonStr = _extractBalancedJson(content, firstBrace);
          if (jsonStr.isNotEmpty) {
            final decoded = jsonDecode(jsonStr);
            if (decoded is Map<String, dynamic>) payload = decoded;
          }
        }
      }

      if (payload == null) return null;

      // Unwrap optional outer {"tool_call": {...}} envelope.
      final inner = payload.containsKey('tool_call') ? payload['tool_call'] : payload;
      if (inner is! Map) return null;
      final toolCall = Map<String, dynamic>.from(inner);

      final name = (toolCall['name'] ?? '').toString().trim();
      if (name.isEmpty) return null;

      final args = toolCall['arguments'];
      final params = toolCall['parameters'];
      Map<String, dynamic> arguments = const {};
      if (args is Map) {
        arguments = Map<String, dynamic>.from(args);
      } else if (params is Map) {
        arguments = Map<String, dynamic>.from(params);
      }

      return LLMToolCall(id: name, name: name, arguments: arguments);
    } catch (_) {
      return null;
    }
  }

  /// Extracts the smallest balanced `{…}` JSON object starting at [startIndex].
  static String _extractBalancedJson(String input, int startIndex) {
    int depth = 0;
    bool inString = false;
    bool escaped = false;
    for (int i = startIndex; i < input.length; i++) {
      final ch = input[i];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (ch == '\\') {
        escaped = true;
        continue;
      }
      if (ch == '"') {
        inString = !inString;
        continue;
      }
      if (inString) continue;
      if (ch == '{') depth++;
      if (ch == '}') {
        depth--;
        if (depth == 0) return input.substring(startIndex, i + 1);
      }
    }
    return '';
  }

  // ── Tool conversion ──────────────────────────────────────────────────────────

  /// Converts [MCPTool] definitions to [ToolDefinition] objects for llamadart.
  ///
  /// The [ToolDefinition.handler] is a no-op because tool execution happens
  /// in [ChatService], not inside this adapter.
  List<ToolDefinition> _convertTools(List<MCPTool> tools) {
    return tools.map((tool) {
      final params = _schemaToParams(tool.inputSchema);
      return ToolDefinition(
        name: tool.name,
        description: tool.description ?? '',
        parameters: params,
        handler: (_) async => null, // ChatService executes the actual tool.
      );
    }).toList();
  }

  List<ToolParam> _schemaToParams(Map<String, dynamic>? schema) {
    final rawProps = schema?['properties'];
    final props = rawProps == null ? <String, dynamic>{} : (rawProps as Map).cast<String, dynamic>();
    final rawRequired = schema?['required'];
    final required = rawRequired == null ? <String>[] : (rawRequired as List).cast<String>();

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
          return ToolParam.array(entry.key, itemType: ToolParam.string('item'), description: desc, required: isRequired);
        default:
          final enumVals = (def['enum'] as List?)?.cast<String>();
          if (enumVals != null && enumVals.isNotEmpty) {
            return ToolParam.enumType(entry.key, values: enumVals, description: desc, required: isRequired);
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
