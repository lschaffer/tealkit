import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:pdfrx/pdfrx.dart';
import 'package:flutter/foundation.dart';
import 'package:googleai_dart/googleai_dart.dart' as genai;
import 'package:http/http.dart' as http;
import 'package:ollama_dart/ollama_dart.dart' as ollama;
import 'package:openai_dart/openai_dart.dart' as openai;
import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/mcp_models.dart';
import 'app_preferences_service.dart';
import '../utils/logger.dart';
import '../utils/grammar_generator.dart';
import '../config/tool_usage_rules.dart';
import 'embedded_llm/embedded_llm_adapter.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Mistral response-patch HTTP client
// Mistral omits "type": "function" from tool_calls objects, which causes
// openai_dart's $enumDecode to throw "A value must be provided. Supported
// values: function". This interceptor injects the missing field before the
// response body is deserialized.
// ─────────────────────────────────────────────────────────────────────────────
class _MistralPatchClient extends http.BaseClient {
  _MistralPatchClient(
    this._inner, {
    this.targetProvider,
    this.targetBaseUrl,
    this.targetApiKey,
  });
  final http.Client _inner;
  final String? targetProvider;
  final String? targetBaseUrl;
  final String? targetApiKey;

  Map<String, dynamic> _sanitizeMistralChatRequest(
    Map<String, dynamic> payload,
  ) {
    final rawMessages = payload['messages'];
    if (rawMessages is! List) return payload;

    final sanitized = <dynamic>[];
    bool changed = false;

    for (final item in rawMessages) {
      if (item is! Map) {
        sanitized.add(item);
        continue;
      }

      final msg = Map<String, dynamic>.from(item);
      final role = (msg['role'] ?? '').toString();

      // Mistral V1 API expects image_url as a plain string, not a nested {url: ...} object.
      // LangChain serializes ChatMessageContent.image() as OpenAI format: {"image_url": {"url": "data:..."}}
      // Patch: convert {"image_url": {"url": "..."}} → {"image_url": "..."}
      if (role == 'user') {
        final content = msg['content'];
        if (content is List) {
          final patchedContent = content.map((part) {
            if (part is! Map) return part;
            final partMap = Map<String, dynamic>.from(part);
            if (partMap['type'] == 'image_url') {
              final imageUrl = partMap['image_url'];
              if (imageUrl is Map) {
                final url = imageUrl['url'];
                if (url is String) {
                  partMap['image_url'] = url;
                  changed = true;
                }
              }
            }
            return partMap;
          }).toList();
          msg['content'] = patchedContent;
        }
      }

      if (role == 'tool') {
        final toolCallId = (msg['tool_call_id'] ?? '').toString().trim();
        final prev = sanitized.isNotEmpty && sanitized.last is Map
            ? Map<String, dynamic>.from(sanitized.last as Map)
            : null;

        bool hasMatchingAssistantToolCall = false;
        if (prev != null && (prev['role']?.toString() == 'assistant')) {
          final toolCalls = prev['tool_calls'];
          if (toolCalls is List) {
            hasMatchingAssistantToolCall = toolCalls.any((tc) {
              if (tc is! Map) return false;
              final tcMap = Map<String, dynamic>.from(tc);
              return (tcMap['id'] ?? '').toString().trim() == toolCallId;
            });
          }
        }

        if (!hasMatchingAssistantToolCall && toolCallId.isNotEmpty) {
          sanitized.add({
            'role': 'assistant',
            'content': null,
            'tool_calls': [
              {
                'id': toolCallId,
                'type': 'function',
                'function': {'name': 'unknown_tool', 'arguments': '{}'},
              },
            ],
          });
          changed = true;
        }
      }

      sanitized.add(msg);
    }

    if (changed) {
      payload['messages'] = sanitized;
    }
    return payload;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    http.BaseRequest requestToSend = request;

    if (targetProvider != null && targetProvider!.isNotEmpty) {
      request.headers['X-Llm-Provider'] = targetProvider!;
    }
    if (targetBaseUrl != null && targetBaseUrl!.isNotEmpty) {
      request.headers['X-Llm-Base-Url'] = targetBaseUrl!;
    }
    if (targetApiKey != null && targetApiKey!.isNotEmpty) {
      request.headers['X-Llm-Api-Key'] = targetApiKey!;
    }

    // Patch outgoing chat/completions requests for strict Mistral ordering.
    if (request.method.toUpperCase() == 'POST' &&
        request.url.path.contains('chat/completions') &&
        request is http.Request) {
      try {
        final decoded = jsonDecode(request.body);
        if (decoded is Map<String, dynamic>) {
          final patchedPayload = _sanitizeMistralChatRequest(decoded);
          requestToSend = http.Request(request.method, request.url)
            ..headers.addAll(request.headers)
            ..body = jsonEncode(patchedPayload);
        }
      } catch (_) {
        // If request JSON parse fails, send original request unchanged.
      }
    }

    final streamed = await _inner.send(requestToSend);

    // Only patch chat/completions responses
    if (!request.url.path.contains('chat/completions')) return streamed;

    // Check if it is a streaming response (text/event-stream)
    final contentType = (streamed.headers['content-type'] ?? '').toLowerCase();
    if (contentType.contains('text/event-stream') ||
        contentType.contains('event-stream')) {
      final transformer = StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (bytes, sink) {
          final text = utf8.decode(bytes);
          final lines = text.split('\n');
          final patchedLines = <String>[];
          for (final line in lines) {
            final trimmed = line.trim();
            if (trimmed.startsWith('data: ') && trimmed.length > 6) {
              final jsonStr = trimmed.substring(6).trim();
              if (jsonStr == '[DONE]') {
                patchedLines.add(line);
                continue;
              }
              try {
                final decoded = jsonDecode(jsonStr);
                if (decoded is Map<String, dynamic>) {
                  bool changed = false;
                  final choices = decoded['choices'];
                  if (choices is List) {
                    for (final choice in choices) {
                      if (choice is! Map<String, dynamic>) continue;

                      // Handle streaming delta
                      final delta = choice['delta'];
                      if (delta is Map<String, dynamic>) {
                        if (delta['content'] is List) {
                          delta['content'] = null;
                          changed = true;
                        }
                        final toolCalls = delta['tool_calls'];
                        if (toolCalls is List) {
                          for (final tc in toolCalls) {
                            if (tc is Map<String, dynamic> &&
                                !tc.containsKey('type')) {
                              tc['type'] = 'function';
                              changed = true;
                            }
                          }
                        }
                      }

                      // Handle non-streaming message (fallback)
                      final msg = choice['message'];
                      if (msg is Map<String, dynamic>) {
                        if (msg['content'] is List) {
                          msg['content'] = null;
                          changed = true;
                        }
                        final toolCalls = msg['tool_calls'];
                        if (toolCalls is List) {
                          for (final tc in toolCalls) {
                            if (tc is Map<String, dynamic> &&
                                !tc.containsKey('type')) {
                              tc['type'] = 'function';
                              changed = true;
                            }
                          }
                        }
                      }
                    }
                  }
                  if (changed) {
                    patchedLines.add('data: ${jsonEncode(decoded)}');
                    continue;
                  }
                }
              } catch (_) {}
            }
            patchedLines.add(line);
          }
          sink.add(utf8.encode(patchedLines.join('\n')));
        },
      );

      return http.StreamedResponse(
        streamed.stream.transform(transformer),
        streamed.statusCode,
        headers: streamed.headers,
        isRedirect: streamed.isRedirect,
        persistentConnection: streamed.persistentConnection,
        reasonPhrase: streamed.reasonPhrase,
      );
    }

    // Buffer the full body for non-streaming responses
    final bodyBytes = await streamed.stream.toBytes();
    final bodyStr = utf8.decode(bodyBytes);

    String patched = bodyStr;
    try {
      final dynamic decoded = jsonDecode(bodyStr);
      if (decoded is Map<String, dynamic>) {
        bool changed = false;
        final choices = decoded['choices'];
        if (choices is List) {
          for (final choice in choices) {
            if (choice is! Map<String, dynamic>) continue;
            final msg = choice['message'];
            if (msg is! Map<String, dynamic>) continue;

            if (msg['content'] is List) {
              msg['content'] = null;
              changed = true;
            }

            final toolCalls = msg['tool_calls'];
            if (toolCalls is! List) continue;
            for (final tc in toolCalls) {
              if (tc is Map<String, dynamic> && !tc.containsKey('type')) {
                tc['type'] = 'function';
                changed = true;
              }
            }
          }
        }
        if (changed) {
          patched = jsonEncode(decoded);
        }
      }
    } catch (_) {
      // If JSON parsing fails leave the body untouched
    }

    final patchedBytes = utf8.encode(patched);
    return http.StreamedResponse(
      http.ByteStream.fromBytes(patchedBytes),
      streamed.statusCode,
      contentLength: patchedBytes.length,
      headers: streamed.headers,
      isRedirect: streamed.isRedirect,
      persistentConnection: streamed.persistentConnection,
      reasonPhrase: streamed.reasonPhrase,
    );
  }

  @override
  void close() => _inner.close();
}

/// Safely converts a raw schema 'properties' value to `Map<String, dynamic>`.
/// Handles `_ConstMap<dynamic, dynamic>` (from `const {}` literals with no explicit types)
/// which cannot be directly cast to `Map<String, dynamic>`.
Map<String, dynamic> _safePropsMap(dynamic raw) {
  if (raw == null) return <String, dynamic>{};
  if (raw is Map<String, dynamic>) return raw;
  return Map<String, dynamic>.from(raw as Map);
}

Map<String, dynamic> _sanitizeToolSchema(Map<String, dynamic>? schema) {
  if (schema == null) return {'type': 'string'};
  final sanitized = Map<String, dynamic>.from(schema)
    ..removeWhere((_, value) => value == null);

  const unsupportedKeys = {
    'default',
    'examples',
    'additionalProperties',
    'minItems',
    'maxItems',
    'minimum',
    'maximum',
    'pattern',
  };
  sanitized.removeWhere((key, _) => unsupportedKeys.contains(key));

  if (sanitized['enum'] is List) sanitized.remove('enum');
  if (sanitized['anyOf'] != null) sanitized.remove('anyOf');

  if (sanitized['type'] is List) {
    final typeList = sanitized['type'] as List;
    sanitized['type'] = typeList.isNotEmpty
        ? typeList.first.toString()
        : 'string';
  }
  sanitized['type'] ??= 'string';

  if (sanitized['type'] == 'object') {
    final properties = sanitized['properties'];
    if (properties == null || (properties is Map && properties.isEmpty)) {
      sanitized['type'] = 'string';
      sanitized.remove('properties');
      sanitized.remove('required');
    }
  }

  if (sanitized['properties'] is Map) {
    final cleanedProperties = <String, dynamic>{};
    for (final entry in (sanitized['properties'] as Map).entries) {
      if (entry.value is Map) {
        cleanedProperties[entry.key.toString()] = _sanitizeToolSchema(
          Map<String, dynamic>.from(entry.value as Map),
        );
      } else if (entry.value != null) {
        cleanedProperties[entry.key.toString()] = entry.value;
      }
    }
    sanitized['properties'] = cleanedProperties;
  }

  if (sanitized['items'] is Map) {
    sanitized['items'] = _sanitizeToolSchema(
      Map<String, dynamic>.from(sanitized['items'] as Map),
    );
  }

  return sanitized.isEmpty ? {'type': 'string'} : sanitized;
}

/// LLM Service for integrating with various language models
class LLMService extends ChangeNotifier with ServiceLogging {
  // Storage key base names (will be prefixed with plugin ID)
  static const String _apiKeyKey = 'gemini_api_key';
  static const String _ollamaUrlKey = 'ollama_url';
  static const String _ollamaApiKeyKey = 'ollama_api_key';
  static const String _providerKey = 'llm_provider';
  static const String _modelKey = 'llm_model';
  static const String _ollamaModelKey = 'ollama_model';
  static const String _openaiApiKeyKey = 'openai_api_key';
  static const String _claudeApiKeyKey = 'claude_api_key';
  static const String _openaiCompatibleUrlKey = 'openai_compatible_url';
  static const String _openaiCompatibleApiKeyKey = 'openai_compatible_api_key';
  static const String _openaiCompatibleModelKey = 'openai_compatible_model';
  static const String _temperatureKey = 'llm_temperature';
  static const String _maxTokensKey = 'llm_max_tokens';
  static const String _maxToolOutputCharsKey = 'llm_max_tool_output_chars';
  static const String _hideThinkBlocksKey = 'llm_hide_think_blocks';
  static const String _useSimplifiedPromptsKey = 'llm_use_simplified_prompts';
  static const String _tokenWarningThresholdKey = 'llm_token_warning_threshold';
  static const String _serviceTierKey = 'llm_service_tier';
  static const String _reasoningEffortKey = 'llm_reasoning_effort';

  // Current plugin ID (used to namespace settings)
  String? _pluginId;

  genai.GoogleAIClient? _googleaiClient;
  ollama.OllamaClient? _ollamaClient;
  openai.OpenAIClient? _openaiClient;
  anthropic.AnthropicClient? _claudeClient;
  openai.OpenAIClient? _openaiCompatibleClient;
  LLMProvider _currentProvider = LLMProvider.none;

  // Default models by provider
  static const List<String> _defaultOllamaModels = [
    'deepseek-r1:14b',
    'qwen3-vl:2b',
    'llama3.1:latest',
    'gemma3:270m',
  ];

  static const List<String> _defaultGeminiModels = [
    'gemini-2.5-flash',
    'gemini-2.5-flash-lite',
    'gemini-2.5-pro',
    'gemini-3-flash',
    'gemini-3-pro',
    'gemini-3-pro-image',
    'gemini-3.0-pro',
  ];

  static const List<String> _defaultOpenAIModels = [
    'gpt-4o',
    'gpt-4o-mini',
    'gpt-4-turbo',
    'gpt-4',
    'gpt-3.5-turbo',
    'o1-preview',
    'o1-mini',
  ];

  static const List<String> _defaultClaudeModels = [
    'claude-3-5-sonnet-20241022',
    'claude-3-5-haiku-20241022',
    'claude-3-opus-20240229',
    'claude-3-sonnet-20240229',
    'claude-3-haiku-20240307',
  ];

  static const List<String> _defaultOpenAICompatibleModels = [
    'meta-llama/Meta-Llama-3.1-70B-Instruct',
    'meta-llama/Meta-Llama-3.1-405B-Instruct',
    'Qwen/Qwen3-Next-80B-A3B-Instruct',
    'Qwen/QwQ-32B-Preview',
    'deepseek-ai/DeepSeek-V3',
    'nvidia/Llama-3.1-Nemotron-70B-Instruct',
    'mistralai/Mixtral-8x7B-Instruct-v0.1',
    'local-model',
  ];

  // Configuration
  String? _geminiApiKey;
  String? _ollamaUrl;
  String? _ollamaApiKey;
  String? _ollamaModel;
  // ignore: unused_field
  String? _openaiApiKey;
  // ignore: unused_field
  String? _claudeApiKey;
  String? _openaiCompatibleUrl;
  String? _openaiCompatibleApiKey;
  String? _openaiCompatibleModel;
  String _currentModel = '';
  bool _useNativeToolCall = true;
  bool _useSafeToolCall = false;
  double _temperature = 0.2; // Initial default
  int _maxTokens = 0; // 0 = provider/model default
  int _maxToolOutputChars =
      2560000; // 2.56M default, aligned with current LLM settings dialog
  bool _hideThinkBlocks =
      true; // Default true - hide <think> blocks in LLM responses
  bool _useSimplifiedPrompts = false; // Default false - use full warmup prompts
  bool _thinking = false; // Default false - thinking/reasoning output disabled
  int _tokenWarningThreshold =
      150000; // Default 150K tokens - suggest cleanup when reached
  String? _serviceTier; // null = auto/default, 'fast' = fast service tier
  String? _reasoningEffort; // null = model default, 'low'|'medium'|'high' etc.

  LLMService();

  bool _isLocalOpenAICompatibleEndpoint() {
    final raw = _openaiCompatibleUrl?.trim();
    if (raw == null || raw.isEmpty) return false;

    final parsed = Uri.tryParse(raw);
    final host = (parsed?.host.isNotEmpty == true ? parsed!.host : raw)
        .toLowerCase();

    return host == 'localhost' || host == '127.0.0.1' || host == '::1';
  }

  bool _isServerLlmProxyBaseUrl() {
    final raw = _openaiCompatibleUrl?.trim().toLowerCase();
    if (raw == null || raw.isEmpty) return false;
    return raw.contains('/api/v1/llm');
  }

  bool _isEmbeddedModelSelection() {
    final model = _currentModel.trim().toLowerCase();
    return model.endsWith('.gguf');
  }

  bool _shouldAvoidOpenAICompatibleStreaming() {
    // Remote server mode uses OpenAI-compatible transport, but when the selected
    // model is a GGUF file the server auto-routes to embedded provider, which
    // currently rejects stream=true on this endpoint.
    return _currentProvider == LLMProvider.openaiCompatible &&
        _isServerLlmProxyBaseUrl() &&
        _isEmbeddedModelSelection();
  }

  int? _normalizeMaxTokens(int? value) {
    final candidate = value ?? _maxTokens;
    return candidate > 0 ? candidate : null;
  }

  bool _requiresAiDataSharingConsent() {
    switch (_currentProvider) {
      case LLMProvider.none:
        return false;
      case LLMProvider.ollama:
        return false;
      case LLMProvider.openaiCompatible:
        return !_isLocalOpenAICompatibleEndpoint();
      case LLMProvider.embedded:
        return false; // On-device inference — no data shared externally.
      case LLMProvider.gemini:
      case LLMProvider.openai:
      case LLMProvider.claude:
        return true;
    }
  }

  void _ensureAiDataSharingConsent() {
    if (!_requiresAiDataSharingConsent()) return;

    final prefs = AppPreferencesService.instance;
    if (!prefs.aiDataSharingConsent) {
      throw Exception(
        'AI data-sharing consent is required before sending prompts to remote AI providers. '
        'Open LLM Settings and enable "Allow sending my prompts/data to AI providers".',
      );
    }
  }

  bool _isMultiModal = true;
  bool get isMultiModal => _isMultiModal;
  void setIsMultiModal(bool value) {
    _isMultiModal = value;
    talker.info('Set isMultiModal to $value');
  }

  bool _pdfEngineInitialized = false;

  Future<void> _ensurePdfEngine() async {
    if (_pdfEngineInitialized) return;
    try {
      pdfrxFlutterInitialize();
      _pdfEngineInitialized = true;
      talker.info('[LLM Service] PDF engine (PDFium) initialized');
    } catch (e) {
      talker.warning('[LLM Service] PDF engine init failed: $e');
    }
  }

  Future<String> _extractTextFromAttachment(
    MessageAttachment attachment,
  ) async {
    if (attachment.bytes == null || attachment.bytes!.isEmpty) {
      return '';
    }

    final mimeType = attachment.mimeType ?? '';
    final name = attachment.name;

    if (mimeType == 'application/pdf' || name.toLowerCase().endsWith('.pdf')) {
      await _ensurePdfEngine();
      if (!_pdfEngineInitialized) {
        return '[PDF content omitted: PDF engine not initialized]';
      }
      PdfDocument? document;
      try {
        document = await PdfDocument.openData(attachment.bytes!);
        final pages = document.pages;
        if (pages.isEmpty) return '[PDF content empty]';
        final buffer = StringBuffer();
        for (final page in pages) {
          final rawText = await page.loadText();
          if (rawText != null && rawText.fullText.isNotEmpty) {
            buffer.writeln(rawText.fullText);
          }
        }
        final txt = buffer.toString().trim();
        return txt.isNotEmpty
            ? txt
            : '[PDF text content is empty or scanned image]';
      } catch (e) {
        talker.warning('[LLM Service] PDF extraction failed: $e');
        return '[Error extracting text from PDF: $e]';
      } finally {
        document?.dispose();
      }
    } else if (mimeType.startsWith('text/') ||
        name.toLowerCase().endsWith('.txt') ||
        name.toLowerCase().endsWith('.md') ||
        name.toLowerCase().endsWith('.csv') ||
        name.toLowerCase().endsWith('.json') ||
        name.toLowerCase().endsWith('.yaml') ||
        name.toLowerCase().endsWith('.yml') ||
        name.toLowerCase().endsWith('.xml') ||
        name.toLowerCase().endsWith('.html') ||
        name.toLowerCase().endsWith('.js') ||
        name.toLowerCase().endsWith('.py') ||
        name.toLowerCase().endsWith('.dart') ||
        name.toLowerCase().endsWith('.sh') ||
        name.toLowerCase().endsWith('.bat') ||
        name.toLowerCase().endsWith('.ps1')) {
      try {
        return utf8.decode(attachment.bytes!);
      } catch (_) {
        try {
          return latin1.decode(attachment.bytes!);
        } catch (e) {
          return '[Error decoding text attachment: $e]';
        }
      }
    }

    return '';
  }

  Future<List<ChatMessage>> _preprocessAttachments(
    List<ChatMessage> messages,
  ) async {
    if (_currentProvider == LLMProvider.gemini) {
      return messages;
    }

    final List<ChatMessage> processed = [];
    for (final m in messages) {
      if (m.role == ChatRole.user &&
          m.attachments != null &&
          m.attachments!.isNotEmpty) {
        final buffer = StringBuffer(m.content);
        final imagesOnly = <MessageAttachment>[];
        for (final att in m.attachments!) {
          final extText = await _extractTextFromAttachment(att);
          if (extText.isNotEmpty) {
            buffer.writeln('\n\n[Attached File: ${att.name}]');
            buffer.writeln('--- CONTENT START ---');
            buffer.writeln(extText);
            buffer.writeln('--- CONTENT END ---');
          } else if (att.bytes != null &&
              (att.mimeType?.startsWith('image/') ?? false)) {
            imagesOnly.add(att);
          }
        }
        processed.add(
          ChatMessage(
            id: m.id,
            role: m.role,
            content: buffer.toString(),
            timestamp: m.timestamp,
            attachments: _isMultiModal ? imagesOnly : null,
            toolResult: m.toolResult,
          ),
        );
      } else {
        processed.add(m);
      }
    }
    return processed;
  }

  // Getters
  LLMProvider get currentProvider => _currentProvider;
  String get currentModel => _currentModel;
  bool get isConfigured => _currentProvider != LLMProvider.none;

  /// Returns true if the current model is a Small Language Model (SLM).
  /// SLMs have limited context windows and need ultra-short system prompts.
  bool get isSlm {
    // Embedded (on-device) models are always treated as SLM regardless of size.
    if (_currentProvider == LLMProvider.embedded) return true;

    final model = _currentModel.toLowerCase();
    // Match explicit param counts ≤ 14B: e.g. `:3.5b`, `-7b`, `_1b`, `3b`, `14b`, `0.5b`
    final paramMatch = RegExp(
      r'(?:^|[:\-_.])([0-9]+\.?[0-9]*)b(?:\b|-)',
    ).firstMatch(model);
    if (paramMatch != null) {
      final params = double.tryParse(paramMatch.group(1)!);
      talker.debug(
        '🔍 SLM size detection: model=$model, matched="${paramMatch.group(0)}", params=$params',
      );
      if (params != null && params <= 14) return true;
    } else {
      talker.debug(
        '🔍 SLM size detection: model=$model, NO MATCH for size pattern',
      );
    }
    // Keyword-based: phi models are always small; mini/tiny/nano signal small variants
    final keywordMatch =
        model.contains('phi') ||
        model.contains('tiny') ||
        model.contains('nano') ||
        model.contains(':mini') ||
        model.contains('-mini') ||
        model.contains('tinyllama');
    if (keywordMatch) {
      talker.debug('🔍 SLM keyword match: model=$model');
    }
    return keywordMatch;
  }

  String? get savedApiKey => _geminiApiKey;
  String? get savedOpenAIApiKey => _openaiApiKey;
  int get maxToolOutputChars => _maxToolOutputChars;
  String? get savedOllamaUrl => _ollamaUrl;
  String? get savedOllamaApiKey => _ollamaApiKey;
  String? get savedOllamaModel => _ollamaModel;
  String? get savedOpenAICompatibleUrl => _openaiCompatibleUrl;
  String? get savedOpenAICompatibleApiKey => _openaiCompatibleApiKey;
  String? get savedOpenAICompatibleModel => _openaiCompatibleModel;
  double get temperature => _temperature;
  bool get useNativeToolCall => _useNativeToolCall;
  bool get useSafeToolCall => _useSafeToolCall;
  int get maxTokens => _maxTokens;
  bool get hideThinkBlocks => _hideThinkBlocks;
  bool get useSimplifiedPrompts => _useSimplifiedPrompts;
  bool get thinking => _thinking;
  int get tokenWarningThreshold => _tokenWarningThreshold;
  String? get serviceTier => _serviceTier;
  String? get reasoningEffort => _reasoningEffort;

  /// Update hide think blocks setting
  void setHideThinkBlocks(bool value) {
    _hideThinkBlocks = value;
    notifyListeners();
  }

  /// Update use simplified prompts setting
  void setUseSimplifiedPrompts(bool value) {
    _useSimplifiedPrompts = value;
    notifyListeners();
  }

  /// Set whether the model is allowed to produce thinking/reasoning output.
  void setThinking(bool value) {
    _thinking = value;
    notifyListeners();
  }

  /// Set token warning threshold
  Future<void> setTokenWarningThreshold(int threshold) async {
    _tokenWarningThreshold = threshold;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_getKey(_tokenWarningThresholdKey), threshold);
    notifyListeners();
  }

  /// Apply per-session runtime limits without persisting them.
  /// Used by task/playground custom LLM overrides.
  void applySessionLimits({
    int? maxTokens,
    int? maxToolOutputChars,
    int? tokenWarningThreshold,
  }) {
    if (maxTokens != null) {
      _maxTokens = maxTokens.clamp(0, 2000000);
    }
    if (maxToolOutputChars != null) {
      _maxToolOutputChars = maxToolOutputChars.clamp(0, 100000000);
    }
    if (tokenWarningThreshold != null) {
      _tokenWarningThreshold = tokenWarningThreshold.clamp(1000, 100000000);
    }
    notifyListeners();
  }

  /// Set the active plugin ID to namespace all settings
  void setPluginId(String? pluginId) {
    if (_pluginId != pluginId) {
      talker.info(
        '🔌 LLMService: Switching plugin context from "$_pluginId" to "$pluginId"',
      );
      _pluginId = pluginId;
      // Reset current provider when switching plugins
      _currentProvider = LLMProvider.none;
      _currentModel = '';
      _googleaiClient = null;

      // Schedule loading saved provider/model for this plugin after build completes
      Future.microtask(() async {
        await loadSavedProviderAndModel();
        notifyListeners(); // Notify after loading completes
      });
    }
  }

  /// Get storage key with plugin prefix
  String _getKey(String baseKey) {
    return _pluginId != null ? '${_pluginId}_$baseKey' : baseKey;
  }

  /// Load saved API key from SharedPreferences
  Future<String?> loadSavedApiKey() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedKey = prefs.getString(_getKey(_apiKeyKey));
      if (savedKey != null) {
        _geminiApiKey = savedKey;
        notifyListeners();
      }
      return savedKey;
    } catch (e) {
      debugPrint('Failed to load saved API key: $e');
      return null;
    }
  }

  /// Load saved OpenAI API key from SharedPreferences
  Future<String?> loadSavedOpenAIApiKey() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedKey = prefs.getString(_getKey(_openaiApiKeyKey));
      if (savedKey != null) {
        _openaiApiKey = savedKey;
        notifyListeners();
      }
      return savedKey;
    } catch (e) {
      debugPrint('Failed to load saved OpenAI API key: $e');
      return null;
    }
  }

  /// Save API key to SharedPreferences
  Future<void> _saveApiKey(String apiKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_getKey(_apiKeyKey), apiKey);
      _geminiApiKey = apiKey;
      notifyListeners();
    } catch (e) {
      debugPrint('Failed to save API key: $e');
    }
  }

  /// Load saved Ollama URL from SharedPreferences
  Future<String?> loadSavedOllamaUrl() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedUrl = prefs.getString(_getKey(_ollamaUrlKey));
      if (savedUrl != null) {
        _ollamaUrl = savedUrl;
        notifyListeners();
      }
      return savedUrl;
    } catch (e) {
      debugPrint('Failed to load saved Ollama URL: $e');
      return null;
    }
  }

  /// Load saved Ollama API key from SharedPreferences
  Future<String?> loadSavedOllamaApiKey() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedKey = prefs.getString(_getKey(_ollamaApiKeyKey));
      if (savedKey != null) {
        _ollamaApiKey = savedKey;
        notifyListeners();
      }
      return savedKey;
    } catch (e) {
      debugPrint('Failed to load saved Ollama API key: $e');
      return null;
    }
  }

  /// Load saved Ollama model from SharedPreferences
  Future<String?> loadSavedOllamaModel() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedModel = prefs.getString(_getKey(_ollamaModelKey));
      if (savedModel != null) {
        _ollamaModel = savedModel;
        notifyListeners();
      }
      return savedModel;
    } catch (e) {
      debugPrint('Failed to load saved Ollama model: $e');
      return null;
    }
  }

  /// Load saved OpenAI-compatible URL from SharedPreferences
  Future<String?> loadSavedOpenAICompatibleUrl() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedUrl = prefs.getString(_getKey(_openaiCompatibleUrlKey));
      if (savedUrl != null) {
        _openaiCompatibleUrl = savedUrl;
        notifyListeners();
      }
      return savedUrl;
    } catch (e) {
      debugPrint('Failed to load saved OpenAI Compatible URL: $e');
      return null;
    }
  }

  /// Load saved OpenAI Compatible API key from SharedPreferences
  Future<String?> loadSavedOpenAICompatibleApiKey() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedKey = prefs.getString(_getKey(_openaiCompatibleApiKeyKey));
      if (savedKey != null) {
        _openaiCompatibleApiKey = savedKey;
        notifyListeners();
      }
      return savedKey;
    } catch (e) {
      debugPrint('Failed to load saved OpenAI Compatible API key: $e');
      return null;
    }
  }

  /// Load saved OpenAI-compatible model from SharedPreferences
  Future<String?> loadSavedOpenAICompatibleModel() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedModel = prefs.getString(_getKey(_openaiCompatibleModelKey));
      if (savedModel != null) {
        _openaiCompatibleModel = savedModel;
        notifyListeners();
      }
      return savedModel;
    } catch (e) {
      debugPrint('Failed to load saved OpenAI-compatible model: $e');
      return null;
    }
  }

  /// Save Ollama URL to SharedPreferences
  Future<void> _saveOllamaUrl(String url) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_getKey(_ollamaUrlKey), url);
      _ollamaUrl = url;
      notifyListeners();
    } catch (e) {
      debugPrint('Failed to save Ollama URL: $e');
    }
  }

  /// Save Ollama API key to SharedPreferences
  Future<void> _saveOllamaApiKey(String? apiKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (apiKey != null && apiKey.isNotEmpty) {
        await prefs.setString(_getKey(_ollamaApiKeyKey), apiKey);
        _ollamaApiKey = apiKey;
      } else {
        await prefs.remove(_getKey(_ollamaApiKeyKey));
        _ollamaApiKey = null;
      }
      notifyListeners();
    } catch (e) {
      debugPrint('Failed to save Ollama API key: $e');
    }
  }

  /// Save OpenAI Compatible API key to SharedPreferences
  Future<void> _saveOpenAICompatibleApiKey(String? apiKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (apiKey != null && apiKey.isNotEmpty) {
        await prefs.setString(_getKey(_openaiCompatibleApiKeyKey), apiKey);
        _openaiCompatibleApiKey = apiKey;
      } else {
        await prefs.remove(_getKey(_openaiCompatibleApiKeyKey));
        _openaiCompatibleApiKey = null;
      }
      notifyListeners();
    } catch (e) {
      debugPrint('Failed to save OpenAI Compatible API key: $e');
    }
  }

  /// Save Ollama model to SharedPreferences
  Future<void> _saveOllamaModel(String model) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_getKey(_ollamaModelKey), model);
      _ollamaModel = model;
      notifyListeners();
    } catch (e) {
      debugPrint('Failed to save Ollama model: $e');
    }
  }

  /// Save provider and model to SharedPreferences
  Future<void> _saveProviderAndModel(LLMProvider provider, String model) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_getKey(_providerKey), provider.name);
      await prefs.setString(_getKey(_modelKey), model);
      notifyListeners();
    } catch (e) {
      debugPrint('Failed to save provider and model: $e');
    }
  }

  /// Load saved provider and model from SharedPreferences
  Future<void> loadSavedProviderAndModel() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Load temperature and maxTokens first
      final savedTemperature = prefs.getDouble(_getKey(_temperatureKey));
      final savedMaxTokens = prefs.getInt(_getKey(_maxTokensKey));
      final savedTokenWarningThreshold = prefs.getInt(
        _getKey(_tokenWarningThresholdKey),
      );

      // Always preserve user-saved values
      if (savedTemperature != null) _temperature = savedTemperature;
      if (savedMaxTokens != null) _maxTokens = savedMaxTokens;
      if (savedTokenWarningThreshold != null) {
        _tokenWarningThreshold = savedTokenWarningThreshold;
      }

      // Load service tier and reasoning effort preferences
      final savedServiceTier = prefs.getString(_getKey(_serviceTierKey));
      final savedReasoningEffort = prefs.getString(
        _getKey(_reasoningEffortKey),
      );
      if (savedServiceTier != null && savedServiceTier.isNotEmpty) {
        _serviceTier = savedServiceTier;
      }
      if (savedReasoningEffort != null && savedReasoningEffort.isNotEmpty) {
        _reasoningEffort = savedReasoningEffort;
      }

      final savedProvider = prefs.getString(_getKey(_providerKey));
      final savedModel = prefs.getString(_getKey(_modelKey));

      if (savedProvider != null && savedModel != null) {
        // Convert string to enum
        final provider = LLMProvider.values.firstWhere(
          (e) => e.name == savedProvider,
          orElse: () => LLMProvider.none,
        );

        if (provider != LLMProvider.none) {
          // Re-initialize with saved settings
          if (provider == LLMProvider.gemini) {
            final apiKey = await loadSavedApiKey();
            if (apiKey != null) {
              await initializeGemini(apiKey: apiKey, model: savedModel);
            }
          } else if (provider == LLMProvider.ollama) {
            final ollamaUrl = await loadSavedOllamaUrl();
            final ollamaModel = await loadSavedOllamaModel();
            final ollamaApiKey = await loadSavedOllamaApiKey();
            await initializeOllama(
              baseUrl: ollamaUrl ?? 'http://localhost:11434/api',
              model: ollamaModel ?? savedModel,
              apiKey: ollamaApiKey,
            );
          } else if (provider == LLMProvider.openai) {
            final apiKey = prefs.getString(_getKey(_openaiApiKeyKey));
            if (apiKey != null) {
              await initializeOpenAI(apiKey: apiKey, model: savedModel);
            }
          } else if (provider == LLMProvider.openaiCompatible) {
            final url = await loadSavedOpenAICompatibleUrl();
            final apiKey = await loadSavedOpenAICompatibleApiKey();
            final openaiCompatibleModel =
                await loadSavedOpenAICompatibleModel();
            if (url != null) {
              await initializeOpenAICompatible(
                baseUrl: url,
                apiKey: apiKey,
                model:
                    openaiCompatibleModel ??
                    savedModel, // Use specific saved model, fallback to generic
              );
            }
          } else if (provider == LLMProvider.claude) {
            final apiKey = prefs.getString(_getKey(_claudeApiKeyKey));
            if (apiKey != null) {
              await initializeClaude(apiKey: apiKey, model: savedModel);
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Failed to load saved provider and model: $e');
    }
  }

  /// Initialize Google Gemini
  Future<void> initializeGemini({
    required String apiKey,
    String model = 'gemini-2.5-flash',
    bool skipModelValidation = false,
  }) async {
    try {
      _geminiApiKey = apiKey;

      // Reload temperature, maxTokens, maxToolOutputChars, and hideThinkBlocks from SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      final savedTemperature = prefs.getDouble(_getKey(_temperatureKey));
      final savedMaxTokens = prefs.getInt(_getKey(_maxTokensKey));
      final savedMaxToolOutputChars = prefs.getInt(
        _getKey(_maxToolOutputCharsKey),
      );
      final savedHideThinkBlocks = prefs.getBool(_getKey(_hideThinkBlocksKey));
      final savedUseSimplifiedPrompts = prefs.getBool(
        _getKey(_useSimplifiedPromptsKey),
      );
      if (savedTemperature != null) _temperature = savedTemperature;
      if (savedMaxTokens != null) _maxTokens = savedMaxTokens;
      if (savedMaxToolOutputChars != null) {
        _maxToolOutputChars = savedMaxToolOutputChars;
      }
      if (savedHideThinkBlocks != null) _hideThinkBlocks = savedHideThinkBlocks;
      if (savedUseSimplifiedPrompts != null) {
        _useSimplifiedPrompts = savedUseSimplifiedPrompts;
      }

      // First check if API key format is valid
      if (apiKey.trim().isEmpty) {
        throw Exception(
          'API key is empty. Please provide a valid Gemini API key from Google AI Studio.',
        );
      }

      if (!apiKey.startsWith('AIza')) {
        throw Exception(
          'Invalid API key format. Gemini API keys should start with "AIza".',
        );
      }

      talker.info(
        'API key format looks valid, starting model initialization...',
      );
      talker.info('Testing with Gemini API key: ${apiKey.substring(0, 8)}...');

      // If user wants to skip validation (for custom/unreleased models), use their model directly
      if (skipModelValidation) {
        talker.info('Skipping model validation, using custom model: $model');
        final customModel = genai.GoogleAIClient(
          config: genai.GoogleAIConfig.googleAI(
            authProvider: genai.ApiKeyProvider(apiKey),
          ),
        );

        _googleaiClient = customModel;

        _currentProvider = LLMProvider.gemini;
        _currentModel = model;

        _saveApiKey(apiKey);
        _saveProviderAndModel(LLMProvider.gemini, model);

        talker.log(
          'Gemini initialized with custom model: $model (validation skipped)',
        );
        notifyListeners();
        return;
      }

      // Try to use the user's requested model first - just test API key validity
      try {
        talker.info('Testing API key with requested model: $model');
        final testModel = genai.GoogleAIClient(
          config: genai.GoogleAIConfig.googleAI(
            authProvider: genai.ApiKeyProvider(apiKey),
          ),
        );

        // Test with a very simple prompt and shorter timeout
        final response = await testModel.models
            .generateContent(
              model: model,
              request: genai.GenerateContentRequest(
                contents: [genai.Content.text('Hi')],
              ),
            )
            .timeout(const Duration(seconds: 10));

        // If successful, use this exact model
        if (response.text != null && response.text!.isNotEmpty) {
          talker.log('✓ Model $model is working!');

          _googleaiClient = genai.GoogleAIClient(
            config: genai.GoogleAIConfig.googleAI(
              authProvider: genai.ApiKeyProvider(apiKey),
            ),
          );

          _currentProvider = LLMProvider.gemini;
          _currentModel = model;

          _saveApiKey(apiKey);
          _saveProviderAndModel(LLMProvider.gemini, model);

          talker.log('Gemini initialized successfully with model: $model');
          notifyListeners();
          return;
        }
      } catch (e) {
        talker.error('✗ Requested model $model failed: ${e.toString()}');

        // Check for specific error types that should stop immediately
        if (e.toString().contains('API_KEY_INVALID') ||
            e.toString().contains('PERMISSION_DENIED')) {
          throw Exception(
            'Invalid API key. Please check your Gemini API key and try again.',
          );
        }

        // Check for quota/rate limit errors
        if (e.toString().contains('Quota exceeded') ||
            e.toString().contains('rate limit')) {
          throw Exception(
            'Rate limit exceeded. Free tier has 250 requests/minute.\n'
            'If you have Google One AI Premium, make sure you\'re using the premium API key.\n'
            'Monitor usage at: https://ai.dev/usage?tab=rate-limit',
          );
        }

        // Show error for model validation failure
        throw Exception(
          'Model "$model" validation failed.\n'
          'The model may not exist yet or is not available with your API key.\n'
          'Error: ${e.toString()}\n\n'
          'Please try one of these models:\n'
          '• gemini-2.5-flash\n'
          '• gemini-2.5-pro\n'
          '• gemini-1.5-flash',
        );
      }

      // Fallback: Try other known working models (this code won't be reached now)
      final fallbackModels = [
        'gemini-2.5-flash', // Gemini 2.5 flash model (default fallback)
        'gemini-2.5-flash-lite', // Lightweight flash model (free tier)
        'gemini-1.5-flash', // Stable flash model
      ];

      genai.GoogleAIClient? workingModel;
      String? workingModelName;

      for (final modelName in fallbackModels) {
        try {
          talker.info('Trying fallback model: $modelName');
          final testModel = genai.GoogleAIClient(
            config: genai.GoogleAIConfig.googleAI(
              authProvider: genai.ApiKeyProvider(apiKey),
            ),
          );

          // Test with a very simple prompt and shorter timeout
          final response = await testModel.models
              .generateContent(
                model: modelName,
                request: genai.GenerateContentRequest(
                  contents: [genai.Content.text('Hi')],
                ),
              )
              .timeout(const Duration(seconds: 10));

          // Check if we got a valid response
          if (response.text != null && response.text!.isNotEmpty) {
            workingModel = testModel;
            workingModelName = modelName;
            talker.log('✓ Fallback model $modelName is working!');
            break;
          } else {
            talker.warning('Fallback model $modelName returned empty response');
            continue;
          }
        } catch (e) {
          talker.error('✗ Fallback model $modelName failed: ${e.toString()}');
          continue;
        }
      }

      if (workingModel == null) {
        throw Exception(
          'No working Gemini model found. Please check your API key and try again.',
        );
      }

      // Create the full model configuration with the working model
      _googleaiClient = genai.GoogleAIClient(
        config: genai.GoogleAIConfig.googleAI(
          authProvider: genai.ApiKeyProvider(apiKey),
        ),
      );

      _currentProvider = LLMProvider.gemini;
      _currentModel = workingModelName ?? model;

      // Save the API key and provider/model for future use (don't await to avoid blocking UI)
      _saveApiKey(apiKey);
      _saveProviderAndModel(LLMProvider.gemini, workingModelName ?? model);

      talker.log(
        'Gemini initialized successfully with model: $workingModelName',
      );
      notifyListeners();
    } catch (e) {
      talker.error('Failed to initialize Gemini: $e');
      rethrow;
    }
  }

  /// Initialize Ollama
  Future<void> initializeOllama({
    String baseUrl = 'http://localhost:11434/api',
    String model = 'llama3.1:latest',
    String? apiKey,
    bool useNativeToolCall = true,
    bool useSafeToolCall = false,
  }) async {
    try {
      _useNativeToolCall = useNativeToolCall;
      _useSafeToolCall = useSafeToolCall;
      _ollamaUrl = baseUrl;
      _ollamaApiKey = apiKey;

      // Create headers with API key if provided
      final headers = <String, String>{};
      if (apiKey != null && apiKey.isNotEmpty) {
        headers['Authorization'] = 'Bearer $apiKey';
      }

      talker.info(
        '[OllamaService] initializeOllama - input baseUrl: "$baseUrl"',
      );
      var cleanedBaseUrl = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
      talker.info(
        '[OllamaService] cleanedBaseUrl after strip trailing: "$cleanedBaseUrl"',
      );
      if (cleanedBaseUrl.endsWith('/api')) {
        cleanedBaseUrl = cleanedBaseUrl
            .substring(0, cleanedBaseUrl.length - 4)
            .replaceAll(RegExp(r'/+$'), '');
        talker.info(
          '[OllamaService] cleanedBaseUrl after endsWith("/api") check: "$cleanedBaseUrl"',
        );
      }
      final finalBaseUrl = cleanedBaseUrl.isNotEmpty
          ? cleanedBaseUrl
          : 'http://localhost:11434';
      talker.info(
        '[OllamaService] final target baseUrl config for OllamaClient: "$finalBaseUrl"',
      );

      _ollamaClient = ollama.OllamaClient(
        config: ollama.OllamaConfig(
          baseUrl: finalBaseUrl,
          defaultHeaders: headers,
        ),
      );

      // Reload temperature, maxTokens, and maxToolOutputChars from SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      final savedTemperature = prefs.getDouble(_getKey(_temperatureKey));
      final savedMaxTokens = prefs.getInt(_getKey(_maxTokensKey));
      final savedMaxToolOutputChars = prefs.getInt(
        _getKey(_maxToolOutputCharsKey),
      );
      final savedHideThinkBlocks = prefs.getBool(_getKey(_hideThinkBlocksKey));
      final savedUseSimplifiedPrompts = prefs.getBool(
        _getKey(_useSimplifiedPromptsKey),
      );

      // Always preserve user-saved values
      if (savedTemperature != null) _temperature = savedTemperature;
      if (savedMaxTokens != null) _maxTokens = savedMaxTokens;
      if (savedMaxToolOutputChars != null) {
        _maxToolOutputChars = savedMaxToolOutputChars;
      }
      if (savedHideThinkBlocks != null) _hideThinkBlocks = savedHideThinkBlocks;
      if (savedUseSimplifiedPrompts != null) {
        _useSimplifiedPrompts = savedUseSimplifiedPrompts;
      }

      // Test connection by listing models
      final models = await _ollamaClient!.models.list();
      talker.info(
        'Available Ollama models: ${models.models?.map((m) => m.model).join(', ')}',
      );

      _currentProvider = LLMProvider.ollama;
      _currentModel = model;

      // Save the Ollama URL, API key, model, and provider for future use (don't await to avoid blocking UI)
      _saveOllamaUrl(baseUrl);
      _saveOllamaApiKey(apiKey);
      _saveOllamaModel(model);
      _saveProviderAndModel(LLMProvider.ollama, model);

      talker.log('Ollama initialized with model: $model');
      notifyListeners();
    } catch (e) {
      talker.error('Failed to initialize Ollama: $e');
      rethrow;
    }
  }

  /// Initialize the embedded (on-device, llama.cpp) provider.
  ///
  /// [modelPath] is the absolute filesystem path to the GGUF file.
  Future<void> initializeEmbedded({
    required String modelPath,
    int gpuLayers = 0,
    void Function(double progress)? onProgress,
  }) async {
    _currentProvider = LLMProvider.embedded;
    _currentModel = modelPath;
    talker.info('Embedded LLM provider set – model path: $modelPath');
    notifyListeners();

    // Actually load the model into the engine if not already loaded.
    final adapter = EmbeddedLlmAdapter.instance;
    if (!adapter.isLoaded || adapter.loadedModelPath != modelPath) {
      talker.info('Loading embedded model: $modelPath (gpuLayers: $gpuLayers)');
      await adapter.initialize(
        modelPath,
        gpuLayers: gpuLayers,
        onProgress: onProgress,
      );
      talker.info('Embedded model loaded: $modelPath');
    }
    if (!adapter.isLoaded) {
      throw StateError('Embedded model failed to load: $modelPath');
    }
  }

  /// Initialize OpenAI-compatible provider (LM Studio, LocalAI, etc.)
  Future<void> initializeOpenAICompatible({
    required String baseUrl,
    String? apiKey,
    String model = 'local-model',
    bool forceMistralCompat = false,
    String? targetProvider,
    String? targetBaseUrl,
    String? targetApiKey,
  }) async {
    try {
      _openaiCompatibleUrl = baseUrl;
      _openaiCompatibleModel = model;
      _openaiCompatibleApiKey = apiKey;

      // Reload temperature, maxTokens, and maxToolOutputChars from SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      final savedTemperature = prefs.getDouble(_getKey(_temperatureKey));
      final savedMaxTokens = prefs.getInt(_getKey(_maxTokensKey));
      final savedMaxToolOutputChars = prefs.getInt(
        _getKey(_maxToolOutputCharsKey),
      );
      final savedHideThinkBlocks = prefs.getBool(_getKey(_hideThinkBlocksKey));
      final savedUseSimplifiedPrompts = prefs.getBool(
        _getKey(_useSimplifiedPromptsKey),
      );

      // Always preserve user-saved values
      if (savedTemperature != null) _temperature = savedTemperature;
      if (savedMaxTokens != null) _maxTokens = savedMaxTokens;
      if (savedMaxToolOutputChars != null) {
        _maxToolOutputChars = savedMaxToolOutputChars;
      }
      if (savedHideThinkBlocks != null) _hideThinkBlocks = savedHideThinkBlocks;
      if (savedUseSimplifiedPrompts != null) {
        _useSimplifiedPrompts = savedUseSimplifiedPrompts;
      }

      talker.info(
        '🌡️ Loaded temperature: $_temperature, maxTokens: $_maxTokens from SharedPreferences',
      );

      // Detect Mistral early so we can log compatibility notes
      final urlIsMistral = baseUrl.toLowerCase().contains('mistral.ai');
      final modelIsMistral = model.toLowerCase().contains('mistral');
      if (urlIsMistral || modelIsMistral) {
        talker.warning('🟡 Mistral AI detected as OpenAI-compatible provider.');
        talker.warning('   Compatibility notes:');
        talker.warning(
          '   • max_tokens is used (not max_completion_tokens) — correct for Mistral',
        );
        talker.warning(
          '   • Strict JSON schema mode is NOT supported; use json_object response_format',
        );
        talker.warning(
          '   • Threads / files / images / audio endpoints are not available at this URL',
        );
        talker.warning(
          '   • "Calling tools..." placeholder messages are filtered from history automatically',
        );
      }

      // Create OpenAI client with custom base URL.
      // For Mistral we wrap the HTTP client to inject missing "type":"function"
      // fields into tool_call objects before openai_dart deserializes the response.
      final http.Client patchClient = _MistralPatchClient(
        http.Client(),
        targetProvider: targetProvider,
        targetBaseUrl: targetBaseUrl,
        targetApiKey: targetApiKey,
      );
      _openaiCompatibleClient = openai.OpenAIClient(
        config: openai.OpenAIConfig(
          authProvider: openai.ApiKeyProvider(
            apiKey?.isNotEmpty == true ? apiKey! : 'not-needed',
          ),
          baseUrl: baseUrl,
        ),
        httpClient: patchClient,
      );

      _currentProvider = LLMProvider.openaiCompatible;
      _currentModel = model;

      // Save the base URL, API key, model, and provider for future use
      await prefs.setString(_getKey(_openaiCompatibleUrlKey), baseUrl);
      await prefs.setString(_getKey(_openaiCompatibleModelKey), model);
      _saveOpenAICompatibleApiKey(apiKey);
      _saveProviderAndModel(LLMProvider.openaiCompatible, model);

      talker.log(
        'OpenAI-compatible provider initialized with model: $model at $baseUrl',
      );
      notifyListeners();
    } catch (e) {
      talker.error('Failed to initialize OpenAI-compatible provider: $e');
      rethrow;
    }
  }

  /// Initialize OpenAI
  Future<void> initializeOpenAI({
    required String apiKey,
    String model = 'gpt-4o-mini',
  }) async {
    try {
      _openaiApiKey = apiKey;

      // Reload temperature, maxTokens, and maxToolOutputChars from SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      final savedTemperature = prefs.getDouble(_getKey(_temperatureKey));
      final savedMaxTokens = prefs.getInt(_getKey(_maxTokensKey));
      final savedMaxToolOutputChars = prefs.getInt(
        _getKey(_maxToolOutputCharsKey),
      );

      // Always preserve user-saved values
      if (savedTemperature != null) _temperature = savedTemperature;
      if (savedMaxTokens != null) _maxTokens = savedMaxTokens;
      if (savedMaxToolOutputChars != null) {
        _maxToolOutputChars = savedMaxToolOutputChars;
      }

      talker.info(
        '🌡️ Loaded temperature: $_temperature, maxTokens: $_maxTokens from SharedPreferences',
      );

      _openaiClient = openai.OpenAIClient(
        config: openai.OpenAIConfig(
          authProvider: openai.ApiKeyProvider(apiKey),
        ),
      );

      _currentProvider = LLMProvider.openai;
      _currentModel = model;

      // Save the API key and provider/model for future use (reuse prefs from above)
      await prefs.setString(_getKey(_openaiApiKeyKey), apiKey);
      _saveProviderAndModel(LLMProvider.openai, model);

      talker.log('OpenAI initialized successfully with model: $model');
      notifyListeners();
    } catch (e) {
      talker.error('Failed to initialize OpenAI: $e');
      rethrow;
    }
  }

  /// Initialize Claude (Anthropic)
  Future<void> initializeClaude({
    required String apiKey,
    String model = 'claude-3-5-sonnet-20241022',
  }) async {
    try {
      _claudeApiKey = apiKey;

      // Reload temperature, maxTokens, and maxToolOutputChars from SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      final savedTemperature = prefs.getDouble(_getKey(_temperatureKey));
      final savedMaxTokens = prefs.getInt(_getKey(_maxTokensKey));
      final savedMaxToolOutputChars = prefs.getInt(
        _getKey(_maxToolOutputCharsKey),
      );
      if (savedTemperature != null) _temperature = savedTemperature;
      if (savedMaxTokens != null) _maxTokens = savedMaxTokens;
      if (savedMaxToolOutputChars != null) {
        _maxToolOutputChars = savedMaxToolOutputChars;
      }

      _claudeClient = anthropic.AnthropicClient(
        config: anthropic.AnthropicConfig(
          authProvider: anthropic.ApiKeyProvider(apiKey),
        ),
      );

      _currentProvider = LLMProvider.claude;
      _currentModel = model;

      // Save the API key and provider/model for future use
      await prefs.setString(_getKey(_claudeApiKeyKey), apiKey);
      _saveProviderAndModel(LLMProvider.claude, model);

      talker.log('Claude initialized successfully with model: $model');
      notifyListeners();
    } catch (e) {
      talker.error('Failed to initialize Claude: $e');
      rethrow;
    }
  }

  /// Returns true if [text] looks like a raw base64-encoded blob.
  ///
  /// Heuristic: ≥ 256 characters of base64 alphabet with no whitespace.
  static bool _looksLikeBase64Blob(String text) {
    if (text.length < 256) return false;
    final hasWhitespace =
        text.contains(' ') || text.contains('\n') || text.contains('\t');
    if (hasWhitespace) return false;
    return RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(text);
  }

  /// Extracts the system message content from a list of chat messages.
  static String? _extractSystemMessage(List<ChatMessage> messages) {
    for (final m in messages) {
      if (m.role == ChatRole.system) return m.content;
    }
    return null;
  }

  /// Produces a short hex hash of [input] for use as a prompt cache key suffix.
  static String _hashString(String input) {
    return input.hashCode.toRadixString(16);
  }

  /// Generate chat completion with tool support
  Future<LLMResponse> generateChatCompletion({
    required List<ChatMessage> messages,
    List<MCPTool>? availableTools,
    double? temperature,
    int? maxTokens,
    bool forceNoToolCalls =
        false, // Force LLM to NOT call tools (for final responses after tool execution)
    void Function(String chunk)?
    onStreamChunk, // Optional streaming callback for token-by-token display
  }) async {
    final response = await _generateChatCompletionInternal(
      messages: messages,
      availableTools: availableTools,
      temperature: temperature,
      maxTokens: maxTokens,
      forceNoToolCalls: forceNoToolCalls,
      onStreamChunk: onStreamChunk,
    );

    // Post-process response to filter out "no_tool" calls
    final hasNoTool = response.toolCalls.any((tc) => tc.name == 'no_tool');
    if (hasNoTool) {
      talker.info(
        '🧹 Found "no_tool" call in response, converting to a clean text response',
      );
      final noToolCall = response.toolCalls.firstWhere(
        (tc) => tc.name == 'no_tool',
      );
      final reason =
          noToolCall.arguments['reason'] as String? ??
          'No matching tool found.';

      final filteredToolCalls = response.toolCalls
          .where((tc) => tc.name != 'no_tool')
          .toList();

      return LLMResponse(
        content: reason,
        toolCalls: filteredToolCalls,
        images: response.images,
        usage: response.usage,
        finishReason: response.finishReason,
      );
    }

    return response;
  }

  /// Internal implementation of chat completion generation
  Future<LLMResponse> _generateChatCompletionInternal({
    required List<ChatMessage> messages,
    List<MCPTool>? availableTools,
    double? temperature,
    int? maxTokens,
    bool forceNoToolCalls = false,
    void Function(String chunk)? onStreamChunk,
  }) async {
    if (!isConfigured) {
      throw Exception('LLM service not configured');
    }

    _ensureAiDataSharingConsent();

    final processedMessages = await _preprocessAttachments(messages);

    // Use provided values or fall back to stored settings
    var effectiveTemperature = temperature ?? _temperature;
    final effectiveMaxTokens = _normalizeMaxTokens(maxTokens);

    // Mistral models work better with lower temperature for tool calling.
    // Detect Mistral by model name OR by the openaiCompatible base URL (api.mistral.ai).
    final isMistralCall =
        _currentModel.toLowerCase().contains('mistral') ||
        (_currentProvider == LLMProvider.openaiCompatible &&
            (_openaiCompatibleUrl?.toLowerCase().contains('mistral.ai') ??
                false));
    if (isMistralCall &&
        (availableTools != null && availableTools.isNotEmpty)) {
      if (effectiveTemperature > 0.3) {
        talker.info(
          '🎯 Reducing temperature from $effectiveTemperature to 0.2 for Mistral tool calling',
        );
        effectiveTemperature = 0.2;
      }
    }

    try {
      // Use native tool calling if supported
      // Note: We use native tool calling even with empty tools array (for follow-up responses)
      // For Ollama: always route through _generateWithOllama to enable streaming.

      // Embedded (on-device) provider — completely separate path, no LangChain.
      if (_currentProvider == LLMProvider.embedded) {
        talker.info('💻 Routing request through embedded (on-device) LLM');
        return await _generateWithEmbedded(
          messages: processedMessages,
          availableTools: forceNoToolCalls ? null : availableTools,
          temperature: effectiveTemperature,
          maxTokens: effectiveMaxTokens ?? 1024,
          onStreamChunk: onStreamChunk,
        );
      }

      if (_currentProvider == LLMProvider.ollama) {
        talker.info('🦙 Routing Ollama request through direct streaming API');
        return await _generateWithOllama(
          messages: processedMessages,
          availableTools: availableTools,
          temperature: effectiveTemperature,
          maxTokens: effectiveMaxTokens,
          onStreamChunk: onStreamChunk,
        );
      }

      // Route openaiCompatible early when streaming is requested, similar to Ollama.
      if (_currentProvider == LLMProvider.openaiCompatible &&
          onStreamChunk != null) {
        if (_shouldAvoidOpenAICompatibleStreaming()) {
          talker.info(
            '🧭 OpenAI-compatible endpoint is server embedded proxy for model "$_currentModel"; using non-stream request to avoid embedded stream=unsupported errors',
          );
          return await _generateWithOpenAICompatible(
            messages: processedMessages,
            availableTools: availableTools,
            temperature: effectiveTemperature,
            maxTokens: effectiveMaxTokens,
            forceNoToolCalls: forceNoToolCalls,
            onStreamChunk: null,
          );
        }

        talker.info(
          '🌊 Routing OpenAI-compatible request through streaming API',
        );
        return await _generateWithOpenAICompatible(
          messages: processedMessages,
          availableTools: availableTools,
          temperature: effectiveTemperature,
          maxTokens: effectiveMaxTokens,
          forceNoToolCalls: forceNoToolCalls,
          onStreamChunk: onStreamChunk,
        );
      }

      // Route OpenAI direct early when streaming is requested (avoids blocking LangChain).
      if (_currentProvider == LLMProvider.openai && onStreamChunk != null) {
        talker.info('🌊 Routing OpenAI request through streaming API');
        return await _generateWithOpenAI(
          messages: processedMessages,
          availableTools: availableTools,
          temperature: effectiveTemperature,
          maxTokens: effectiveMaxTokens,
          forceNoToolCalls: forceNoToolCalls,
          onStreamChunk: onStreamChunk,
        );
      }

      // Route Gemini early when streaming is requested (avoids blocking LangChain).
      if (_currentProvider == LLMProvider.gemini && onStreamChunk != null) {
        talker.info('🌊 Routing Gemini request through streaming API');
        return await _generateWithGemini(
          messages: processedMessages,
          availableTools: availableTools,
          temperature: effectiveTemperature,
          maxTokens: effectiveMaxTokens,
          forceNoToolCalls: forceNoToolCalls,
          onStreamChunk: onStreamChunk,
        );
      }

      // Route request to the appropriate direct provider method

      // Otherwise fall back to existing provider-specific methods
      talker.info(
        '📝 Using legacy text-based tool calling for ${_currentProvider.name}',
      );
      switch (_currentProvider) {
        case LLMProvider.gemini:
          return await _generateWithGemini(
            messages: processedMessages,
            availableTools: availableTools,
            temperature: effectiveTemperature,
            maxTokens: effectiveMaxTokens,
            onStreamChunk: onStreamChunk,
          );
        case LLMProvider.openai:
          return await _generateWithOpenAI(
            messages: processedMessages,
            availableTools: availableTools,
            temperature: effectiveTemperature,
            maxTokens: effectiveMaxTokens,
            onStreamChunk: onStreamChunk,
          );
        case LLMProvider.claude:
          return await _generateWithClaude(
            messages: processedMessages,
            availableTools: availableTools,
            temperature: effectiveTemperature,
            maxTokens: effectiveMaxTokens,
            onStreamChunk: onStreamChunk,
          );
        case LLMProvider.ollama:
          // This path is now only reached for providers that are NOT Ollama
          // (Ollama is handled above via the direct streaming route).
          return await _generateWithOllama(
            messages: processedMessages,
            availableTools: availableTools,
            temperature: effectiveTemperature,
            maxTokens: effectiveMaxTokens,
            onStreamChunk: onStreamChunk,
          );
        case LLMProvider.openaiCompatible:
          return await _generateWithOpenAICompatible(
            messages: processedMessages,
            availableTools: availableTools,
            temperature: effectiveTemperature,
            maxTokens: effectiveMaxTokens,
            forceNoToolCalls: forceNoToolCalls,
            onStreamChunk: onStreamChunk,
          );
        case LLMProvider.embedded:
          return await _generateWithEmbedded(
            messages: processedMessages,
            availableTools: availableTools,
            onStreamChunk: onStreamChunk,
          );
        case LLMProvider.none:
          throw Exception('No LLM provider configured');
      }
    } catch (e) {
      talker.error('Error generating chat completion: $e');
      rethrow;
    }
  }

  /// Generate with the on-device embedded (llama.cpp) provider.
  ///
  /// Delegates entirely to [EmbeddedLlmAdapter]. All tool calling is handled
  /// by [ChatService] — this method never enters a tool loop itself.
  Future<LLMResponse> _generateWithEmbedded({
    required List<ChatMessage> messages,
    List<MCPTool>? availableTools,
    double temperature = 0.3,
    int maxTokens = 1024,
    void Function(String chunk)? onStreamChunk,
  }) async {
    final adapter = EmbeddedLlmAdapter.instance;
    if (!adapter.isLoaded) {
      throw StateError(
        'Embedded model is not loaded. '
        'Please select and download a model in LLM Settings → Embedded.',
      );
    }
    return adapter.generateResponse(
      messages: messages,
      availableTools: availableTools,
      temperature: temperature,
      maxTokens: maxTokens,
      onStreamChunk: onStreamChunk,
    );
  }

  List<genai.Content> _convertToGeminiMessages(List<ChatMessage> messages) {
    final List<genai.Content> contentList = [];

    // Extractor helper function matching the one from compatible
    String extractToolArgumentsJson(String rawContent) {
      final argsMatch = RegExp(
        r'Arguments:\s*(\{[\s\S]*\})',
        caseSensitive: false,
      ).firstMatch(rawContent);
      final argsRaw = argsMatch?.group(1)?.trim();
      if (argsRaw == null || argsRaw.isEmpty) {
        return '{}';
      }
      try {
        final decoded = jsonDecode(argsRaw);
        if (decoded is Map<String, dynamic>) {
          return jsonEncode(decoded);
        }
      } catch (_) {}
      return '{}';
    }

    for (final msg in messages) {
      if (msg.role == ChatRole.system) continue;

      if (msg.role == ChatRole.user) {
        final parts = <genai.Part>[genai.TextPart(msg.content)];
        if (msg.attachments != null && msg.attachments!.isNotEmpty) {
          for (final attachment in msg.attachments!) {
            if (attachment.bytes != null) {
              final mimeType =
                  attachment.mimeType ?? 'application/octet-stream';
              final isSupported =
                  mimeType.startsWith('image/') ||
                  mimeType.startsWith('audio/') ||
                  mimeType.startsWith('video/') ||
                  mimeType.startsWith('text/') ||
                  mimeType == 'application/pdf';
              if (isSupported) {
                parts.add(
                  genai.InlineDataPart(
                    genai.Blob.fromBytes(mimeType, attachment.bytes!),
                  ),
                );
              } else {
                parts.add(
                  genai.TextPart(
                    '\n[Note: Attached file "${attachment.name}" ($mimeType) cannot be processed directly.]',
                  ),
                );
              }
            }
          }
        }
        contentList.add(genai.Content(role: 'user', parts: parts));
      } else if (msg.role == ChatRole.assistant) {
        if (msg.content.contains('Calling tools') ||
            msg.content.contains('Calling additional tools')) {
          continue;
        }
        contentList.add(
          genai.Content(role: 'model', parts: [genai.TextPart(msg.content)]),
        );
      } else if (msg.role == ChatRole.tool) {
        final toolContent = _truncateLargeToolResults(msg).trim();
        final toolCallId = msg.id.trim();
        if (toolCallId.isNotEmpty) {
          final toolName =
              (msg.lastCalledToolName ??
                      _extractCalledToolName(msg.content) ??
                      'unknown_tool')
                  .trim();
          final toolArgsJson = extractToolArgumentsJson(msg.content);

          contentList.add(
            genai.Content(
              role: 'model',
              parts: [
                genai.Part.functionCall(
                  toolName,
                  args: jsonDecode(toolArgsJson) as Map<String, dynamic>,
                ),
              ],
            ),
          );

          contentList.add(
            genai.Content(
              role: 'function',
              parts: [
                genai.Part.functionResponse(toolName, {'content': toolContent}),
              ],
            ),
          );
        } else {
          contentList.add(
            genai.Content(
              role: 'user',
              parts: [genai.TextPart('Tool result:\n$toolContent')],
            ),
          );
        }
      }
    }
    return contentList;
  }

  /// Generate with Google Gemini
  Future<LLMResponse> _generateWithGemini({
    required List<ChatMessage> messages,
    List<MCPTool>? availableTools,
    double? temperature,
    int? maxTokens,
    bool forceNoToolCalls = false,
    void Function(String chunk)? onStreamChunk,
  }) async {
    if (_googleaiClient == null) {
      throw Exception('Gemini not initialized');
    }

    final content = _convertToGeminiMessages(messages);

    // Build native Gemini genai.Tool list from availableTools
    List<genai.Tool>? geminiTools;
    genai.ToolConfig? geminiToolConfig;
    if (!forceNoToolCalls &&
        availableTools != null &&
        availableTools.isNotEmpty) {
      final declarations = availableTools.map((t) {
        return genai.FunctionDeclaration(
          name: t.name,
          description: t.description ?? 'No description',
          parameters: _mcpSchemaToGemini(t.inputSchema),
        );
      }).toList();
      geminiTools = [genai.Tool(functionDeclarations: declarations)];
      talker.info(
        '🔧 Sending ${declarations.length} native function declarations to Gemini',
      );
    } else if (forceNoToolCalls) {
      geminiToolConfig = genai.ToolConfig(
        functionCallingConfig: genai.FunctionCallingConfig(
          mode: genai.FunctionCallingMode.none,
        ),
      );
      talker.info(
        '🔒 forceNoToolCalls=true: using genai.FunctionCallingMode.none for Gemini',
      );
    }

    // Log message count and system message presence
    talker.info(
      '📨 Sending ${messages.length} messages to Gemini (${content.length} after conversion)',
    );
    final systemMsgCount = messages
        .where((m) => m.role == ChatRole.system)
        .length;
    talker.info('📋 System messages in original: $systemMsgCount');
    if (systemMsgCount > 0) {
      final totalSystemChars = messages
          .where((m) => m.role == ChatRole.system)
          .fold(0, (sum, m) => sum + m.content.length);
      talker.info(
        '📏 Total system message chars in original messages: $totalSystemChars',
      );
    }

    // Log ACTUAL content being sent to Gemini (after merging)
    int totalCharsInMergedContent = 0;
    for (final contentItem in content) {
      for (final part in contentItem.parts) {
        if (part is genai.TextPart) {
          totalCharsInMergedContent += part.text.length;
        }
      }
    }
    talker.info(
      '📏 ACTUAL chars being sent to Gemini API (after merge): $totalCharsInMergedContent',
    );

    // Log role sequence for debugging
    final roleSequence = content.map((c) => c.role).join(' → ');
    talker.info('🔄 Role sequence: $roleSequence');

    // Log tools being sent
    talker.info('🔧 Tools being sent: ${availableTools?.length ?? 0}');
    if (availableTools != null && availableTools.isNotEmpty) {
      talker.debug(
        'genai.Tool names: ${availableTools.map((t) => t.name).join(", ")}',
      );
    }

    final request = genai.GenerateContentRequest(
      contents: content,
      tools: geminiTools,
      toolConfig: geminiToolConfig,
      generationConfig: genai.GenerationConfig(
        temperature: _temperature,
        topK: 40,
        topP: 0.95,
        maxOutputTokens: _normalizeMaxTokens(_maxTokens),
      ),
      safetySettings: [
        genai.SafetySetting(
          category: genai.HarmCategory.harassment,
          threshold: genai.HarmBlockThreshold.blockMediumAndAbove,
        ),
        genai.SafetySetting(
          category: genai.HarmCategory.hateSpeech,
          threshold: genai.HarmBlockThreshold.blockMediumAndAbove,
        ),
        genai.SafetySetting(
          category: genai.HarmCategory.sexuallyExplicit,
          threshold: genai.HarmBlockThreshold.blockMediumAndAbove,
        ),
        genai.SafetySetting(
          category: genai.HarmCategory.dangerousContent,
          threshold: genai.HarmBlockThreshold.blockMediumAndAbove,
        ),
      ],
    );

    try {
      if (onStreamChunk != null) {
        talker.info('🌊 Using streaming API for Gemini provider');
        String fullContent = '';
        final List<LLMToolCall> streamedFunctionCalls = [];

        await for (final chunk in _googleaiClient!.models.streamGenerateContent(
          model: _currentModel,
          request: request,
        )) {
          final chunkText = chunk.text ?? '';
          if (chunkText.isNotEmpty) {
            fullContent += chunkText;
            onStreamChunk(chunkText);
          }
          // Collect native function call parts from every chunk
          for (final fc in chunk.functionCalls) {
            talker.info('🔧 Gemini stream native function call: ${fc.name}');
            streamedFunctionCalls.add(
              LLMToolCall(
                id: 'gemini-${fc.name}-${DateTime.now().millisecondsSinceEpoch}',
                name: fc.name,
                arguments: Map<String, dynamic>.from(fc.args ?? {}),
              ),
            );
          }
        }

        talker.info(
          '📥 Gemini stream complete - content length: ${fullContent.length}, '
          'native function calls: ${streamedFunctionCalls.length}',
        );
        return LLMResponse(
          content: fullContent,
          toolCalls: streamedFunctionCalls.isNotEmpty
              ? streamedFunctionCalls
              : _extractToolCalls(fullContent),
          usage: const LLMUsage(
            promptTokens: 0,
            completionTokens: 0,
            totalTokens: 0,
          ),
          finishReason: 'stop',
        );
      }

      final response = await _generateWithRetry(
        () => _googleaiClient!.models.generateContent(
          model: _currentModel,
          request: request,
        ),
      );

      // Extract native function calls, fall back to text-based extraction
      List<LLMToolCall> toolCalls;
      final nativeCalls = response.functionCalls.toList();
      if (nativeCalls.isNotEmpty) {
        talker.info(
          '✅ Received ${nativeCalls.length} native function calls from Gemini',
        );
        toolCalls = nativeCalls
            .map(
              (fc) => LLMToolCall(
                id: 'gemini-${fc.name}-${DateTime.now().millisecondsSinceEpoch}',
                name: fc.name,
                arguments: Map<String, dynamic>.from(fc.args ?? {}),
              ),
            )
            .toList();
      } else {
        toolCalls = _extractToolCalls(response.text ?? '');
      }

      // Log usage metadata for debugging (check if it's null or just 0)
      if (response.usageMetadata == null) {
        talker.warning(
          '⚠️ Gemini usageMetadata is NULL - this is a Gemini API bug',
        );
      } else {
        talker.info(
          '📊 Gemini tokens: ${response.usageMetadata!.promptTokenCount} prompt + ${response.usageMetadata!.candidatesTokenCount} completion = ${response.usageMetadata!.totalTokenCount} total',
        );
      }

      return LLMResponse(
        content: response.text ?? '',
        toolCalls: toolCalls,
        usage: LLMUsage(
          promptTokens: response.usageMetadata?.promptTokenCount ?? 0,
          completionTokens: response.usageMetadata?.candidatesTokenCount ?? 0,
          totalTokens: response.usageMetadata?.totalTokenCount ?? 0,
        ),
        finishReason: _mapGeminiFinishReason(
          response.candidates?.firstOrNull?.finishReason,
        ),
      );
    } catch (e) {
      // Handle the specific UNEXPECTED_TOOL_CALL error from newer Gemini API
      if (e.toString().contains('UNEXPECTED_TOOL_CALL')) {
        logLLMResponse('UNEXPECTED_TOOL_CALL error occurred');
        talker.error(
          'Gemini SDK error: UNEXPECTED_TOOL_CALL - this is a known issue with tool calls in the current SDK version',
        );

        // Log additional context for debugging
        talker.info(
          'Available tools: ${availableTools?.map((t) => t.name).toList() ?? 'none'}',
        );
        talker.info(
          'Last message content preview: ${messages.isNotEmpty ? messages.last.content.substring(0, math.min(100, messages.last.content.length)) : 'no messages'}...',
        );

        // Try a fallback approach without tools first time
        try {
          logWorkflowStep(
            'UNEXPECTED_TOOL_CALL Recovery',
            'Attempting fallback generation without tools',
          );
          final fallbackResponse = await _googleaiClient!.models
              .generateContent(
                model: _currentModel,
                request: genai.GenerateContentRequest(
                  contents: [
                    genai.Content.text(
                      _buildSimplifiedPrompt(messages, availableTools),
                    ),
                  ],
                ),
              );

          if (fallbackResponse.text != null &&
              fallbackResponse.text!.isNotEmpty) {
            logLLMResponse(
              'Fallback response generated successfully',
              toolCallCount: 0,
            );
            return LLMResponse(
              content: fallbackResponse.text!,
              toolCalls: _extractToolCalls(
                fallbackResponse.text!,
              ), // Still try to extract tool calls
              usage: LLMUsage(
                promptTokens:
                    fallbackResponse.usageMetadata?.promptTokenCount ?? 0,
                completionTokens:
                    fallbackResponse.usageMetadata?.candidatesTokenCount ?? 0,
                totalTokens:
                    fallbackResponse.usageMetadata?.totalTokenCount ?? 0,
              ),
              finishReason: _mapGeminiFinishReason(
                fallbackResponse.candidates?.firstOrNull?.finishReason,
              ),
            );
          }
        } catch (fallbackError) {
          talker.error('Fallback generation also failed: $fallbackError');
        }

        // Return a recovery response that asks the user to try again
        return const LLMResponse(
          content:
              'I encountered a compatibility issue with the tool call system. This is a known problem with the current Google AI SDK version. Please try your request again - it may work on the second attempt.',
          toolCalls: [],
          usage: LLMUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0),
          finishReason: 'stop',
        );
      }

      throw Exception('Gemini generation failed: $e');
    }
  }

  List<ollama.ChatMessage> _convertToOllamaMessages(
    List<ChatMessage> messages,
  ) {
    final List<ollama.ChatMessage> ollamaMsgs = [];

    // Helper to extract tool arguments JSON, same as for OpenAI
    String extractToolArgumentsJson(String rawContent) {
      final argsMatch = RegExp(
        r'Arguments:\s*(\{[\s\S]*\})',
        caseSensitive: false,
      ).firstMatch(rawContent);
      final argsRaw = argsMatch?.group(1)?.trim();
      if (argsRaw == null || argsRaw.isEmpty) {
        return '{}';
      }
      try {
        final decoded = jsonDecode(argsRaw);
        if (decoded is Map<String, dynamic>) {
          return jsonEncode(decoded);
        }
      } catch (_) {}
      return '{}';
    }

    for (int i = 0; i < messages.length; i++) {
      final message = messages[i];
      if (message.role == ChatRole.tool) {
        final toolContent = _truncateLargeToolResults(message).trim();
        final toolName =
            (message.lastCalledToolName ??
                    _extractCalledToolName(message.content) ??
                    'unknown_tool')
                .trim();
        final toolCallId = message.id.trim();

        // Wrap tool execution result in structured JSON to prevent loops
        final structuredContent = jsonEncode({
          'tool': toolName,
          'id': toolCallId,
          'tool_executed': true,
          'tool_result': toolContent,
        });

        ollamaMsgs.add(
          ollama.ChatMessage(
            role: ollama.MessageRole.tool,
            content: structuredContent,
          ),
        );
      } else if (message.role == ChatRole.assistant) {
        final toolCallNames = <String>[];
        final toolCallArgs = <String>[];
        int j = i + 1;
        while (j < messages.length && messages[j].role == ChatRole.tool) {
          final toolMsg = messages[j];
          final name =
              (toolMsg.lastCalledToolName ??
                      _extractCalledToolName(toolMsg.content) ??
                      'tool')
                  .trim();
          toolCallNames.add(name);
          toolCallArgs.add(extractToolArgumentsJson(toolMsg.content));
          j++;
        }

        if (toolCallNames.isNotEmpty) {
          final List<ollama.ToolCall> tCalls = [];
          for (int k = 0; k < toolCallNames.length; k++) {
            tCalls.add(
              ollama.ToolCall(
                function: ollama.ToolCallFunction(
                  name: toolCallNames[k],
                  arguments:
                      jsonDecode(toolCallArgs[k]) as Map<String, dynamic>,
                ),
              ),
            );
          }
          ollamaMsgs.add(
            ollama.ChatMessage(
              role: ollama.MessageRole.assistant,
              content: '',
              toolCalls: tCalls,
            ),
          );
        } else {
          if (message.content.contains('Calling tools') ||
              message.content.contains('Calling additional tools')) {
            continue;
          }
          final processedContent = _truncateLargeToolResults(message);
          ollamaMsgs.add(
            ollama.ChatMessage(
              role: ollama.MessageRole.assistant,
              content: processedContent,
            ),
          );
        }
      } else {
        final role = _mapToOllamaRole(message.role);
        final processedContent = _truncateLargeToolResults(message);
        ollamaMsgs.add(
          ollama.ChatMessage(role: role, content: processedContent),
        );
      }
    }
    return ollamaMsgs;
  }

  /// Generate with Ollama
  Future<LLMResponse> _generateWithOllama({
    required List<ChatMessage> messages,
    List<MCPTool>? availableTools,
    double temperature = 0.7,
    int? maxTokens,
    void Function(String chunk)? onStreamChunk,
  }) async {
    if (_ollamaClient == null) {
      throw Exception('Ollama not initialized');
    }

    final ollamaMessages = _convertToOllamaMessages(messages);

    // Convert MCP tools to Ollama format
    List<ollama.ToolDefinition>? ollamaTools;
    if (availableTools != null && availableTools.isNotEmpty) {
      ollamaTools = availableTools.map((mcpTool) {
        final inputSchema = _sanitizeToolSchema(mcpTool.inputSchema);
        return ollama.ToolDefinition(
          type: ollama.ToolType.function,
          function: ollama.ToolFunction(
            name: mcpTool.name,
            description: mcpTool.description ?? 'No description provided',
            parameters: {
              'type': inputSchema['type'] ?? 'object',
              if (inputSchema['properties'] != null)
                'properties': _safePropsMap(inputSchema['properties']),
              if (inputSchema['required'] is List)
                'required': (inputSchema['required'] as List).cast<String>(),
              if (inputSchema['items'] != null) 'items': inputSchema['items'],
            },
          ),
        );
      }).toList();
      talker.info(
        '🔧 Converted ${ollamaTools.length} tools for Ollama: ${ollamaTools.map((t) => t.function.name).toList()}',
      );
    } else {
      talker.warning(
        '⚠️ No tools provided to Ollama - availableTools is ${availableTools == null ? "null" : "empty"}',
      );
    }

    Future<LLMResponse> runOllamaRequest(
      List<ollama.ToolDefinition>? toolsForRequest,
    ) async {
      String? grammarString;
      if (_useSafeToolCall &&
          availableTools != null &&
          availableTools.isNotEmpty) {
        grammarString = GrammarGenerator.buildToolCallGrammar(availableTools);
        talker.info(
          '🔒 Safe tool call mode ON — using GBNF grammar to constrain output',
        );
      }

      talker.info(
        '📤 Sending request to Ollama with ${ollamaMessages.length} messages, '
        '${toolsForRequest?.length ?? 0} tools, grammar=${grammarString != null}',
      );

      final request = ollama.ChatRequest(
        model: _currentModel,
        messages: ollamaMessages,
        tools: _useSafeToolCall ? null : toolsForRequest,
        options: ollama.ModelOptions(
          temperature: temperature,
          numPredict: maxTokens,
        ),
      );

      String fullContent = '';
      List<LLMToolCall> toolCalls = [];
      final List<ollama.ToolCall> nativeToolCallsAccumulated = [];
      int promptTokens = 0;
      int completionTokens = 0;
      String finishReason = 'stop';

      await for (final chunk in _ollamaClient!.chat.createStream(
        request: request,
      )) {
        final chunkContent = chunk.message?.content ?? '';
        if (chunkContent.isNotEmpty) {
          fullContent += chunkContent;
          onStreamChunk?.call(chunkContent);
        }
        final chunkToolCalls = chunk.message?.toolCalls;
        if (chunkToolCalls != null && chunkToolCalls.isNotEmpty) {
          talker.info(
            '🔧 Ollama chunk has ${chunkToolCalls.length} tool call(s) (done=${chunk.done})',
          );
          nativeToolCallsAccumulated.addAll(chunkToolCalls);
        }
        if (chunk.done == true) {
          promptTokens = chunk.promptEvalCount ?? 0;
          completionTokens = chunk.evalCount ?? 0;
          finishReason = chunk.doneReason?.toString() ?? 'stop';
        }
      }

      talker.info(
        '📥 Ollama stream complete - content length: ${fullContent.length}, accumulated tool calls: ${nativeToolCallsAccumulated.length}',
      );

      if (_useSafeToolCall) {
        final parsed = GrammarGenerator.parseSafeToolCallResponse(fullContent);
        if (parsed != null) {
          talker.info(
            '🔒 Safe mode: parsed tool call "${parsed.name}" with ${parsed.arguments.length} args',
          );
          toolCalls = [parsed];
        } else {
          talker.warning(
            '🔒 Safe mode parse failed (should not happen), falling back to text extraction',
          );
          toolCalls = _extractToolCalls(fullContent);
        }
      } else {
        if (nativeToolCallsAccumulated.isNotEmpty) {
          talker.info(
            '🔧 Found ${nativeToolCallsAccumulated.length} native Ollama tool calls',
          );
          for (final toolCall in nativeToolCallsAccumulated) {
            if (toolCall.function?.name != null &&
                toolCall.function?.arguments != null) {
              final name = toolCall.function!.name;
              final arguments =
                  toolCall.function!.arguments ?? const <String, dynamic>{};
              final argString = jsonEncode(arguments);
              final id = 'call_${name}_${argString.hashCode.toRadixString(16)}';
              toolCalls.add(
                LLMToolCall(id: id, name: name, arguments: arguments),
              );
            }
          }
        } else {
          talker.info(
            '🔍 No native tool calls found, attempting text extraction...',
          );
          toolCalls = _extractToolCalls(fullContent);
          if (toolCalls.isNotEmpty) {
            talker.info(' Extracted ${toolCalls.length} tool calls from text');
          } else {
            talker.warning(
              '⚠️ No tool calls found in response (neither native nor text format)',
            );
          }
        }
      }

      return LLMResponse(
        content: fullContent,
        toolCalls: toolCalls,
        usage: LLMUsage(
          promptTokens: promptTokens,
          completionTokens: completionTokens,
          totalTokens: promptTokens + completionTokens,
        ),
        finishReason: finishReason,
      );
    }

    try {
      return await runOllamaRequest(_useNativeToolCall ? ollamaTools : null);
    } catch (e) {
      if (_useSafeToolCall) {
        talker.warning(
          '⚠️ Safe tool call mode failed: $e; falling back to standard mode',
        );
        _useSafeToolCall = false;
        return await runOllamaRequest(_useNativeToolCall ? ollamaTools : null);
      }
      throw Exception('Ollama generation failed: $e');
    }
  }

  List<openai.ChatMessage> _convertToOpenAIMessages(
    List<ChatMessage> messages,
  ) {
    final List<openai.ChatMessage> openaiMessages = [];

    // Extractor helper function matching the one from compatible
    String extractToolArgumentsJson(String rawContent) {
      final argsMatch = RegExp(
        r'Arguments:\s*(\{[\s\S]*\})',
        caseSensitive: false,
      ).firstMatch(rawContent);
      final argsRaw = argsMatch?.group(1)?.trim();
      if (argsRaw == null || argsRaw.isEmpty) {
        return '{}';
      }
      try {
        final decoded = jsonDecode(argsRaw);
        if (decoded is Map<String, dynamic>) {
          return jsonEncode(decoded);
        }
      } catch (_) {}
      return '{}';
    }

    for (final message in messages) {
      if (message.role == ChatRole.tool) {
        final toolContent = _truncateLargeToolResults(message).trim();
        final toolCallId = message.id.trim();

        if (toolCallId.isNotEmpty) {
          final toolName =
              (message.lastCalledToolName ??
                      _extractCalledToolName(message.content) ??
                      'unknown_tool')
                  .trim();
          final toolArgsJson = extractToolArgumentsJson(message.content);

          openaiMessages.add(
            openai.ChatMessage.assistant(
              toolCalls: [
                openai.ToolCall.functionCall(
                  id: toolCallId,
                  call: openai.FunctionCall.fromMap(
                    name: toolName,
                    arguments: jsonDecode(toolArgsJson) as Map<String, dynamic>,
                  ),
                ),
              ],
            ),
          );

          openaiMessages.add(
            openai.ChatMessage.tool(
              toolCallId: toolCallId,
              content: toolContent,
            ),
          );
        } else {
          openaiMessages.add(
            openai.ChatMessage.user('Tool result:\n$toolContent'),
          );
        }
        continue;
      }

      if (message.role == ChatRole.system) {
        openaiMessages.add(openai.ChatMessage.system(message.content));
      } else if (message.role == ChatRole.user) {
        if (message.attachments != null && message.attachments!.isNotEmpty) {
          final imageParts = message.attachments!
              .where(
                (a) =>
                    a.bytes != null &&
                    (a.mimeType?.startsWith('image/') ?? false),
              )
              .toList();
          if (imageParts.isNotEmpty) {
            final parts = <openai.ContentPart>[
              openai.ContentPart.text(message.content),
            ];
            for (final att in imageParts) {
              final b64 = base64Encode(att.bytes!);
              final mime = att.mimeType ?? 'image/jpeg';
              parts.add(
                openai.ContentPart.imageBase64(data: b64, mediaType: mime),
              );
            }
            openaiMessages.add(openai.ChatMessage.user(parts));
            continue;
          }
        }
        openaiMessages.add(openai.ChatMessage.user(message.content));
      } else if (message.role == ChatRole.assistant) {
        if (message.content.contains('Calling tools') ||
            message.content.contains('Calling additional tools')) {
          continue;
        }
        openaiMessages.add(
          openai.ChatMessage.assistant(content: message.content),
        );
      }
    }
    return openaiMessages;
  }

  /// Generate with OpenAI
  Future<LLMResponse> _generateWithOpenAI({
    required List<ChatMessage> messages,
    List<MCPTool>? availableTools,
    double? temperature,
    int? maxTokens,
    bool forceNoToolCalls = false,
    void Function(String chunk)? onStreamChunk,
  }) async {
    // Use instance variables if not provided
    final effectiveTemperature = temperature ?? _temperature;
    final effectiveMaxTokens = _normalizeMaxTokens(maxTokens);
    if (_openaiClient == null) {
      throw Exception('OpenAI not initialized');
    }

    final openaiMessages = _convertToOpenAIMessages(messages);
    talker.info('Converted to ${openaiMessages.length} OpenAI messages');

    try {
      final useMaxCompletionTokens =
          _currentModel.contains('gpt-4o') ||
          _currentModel.contains('gpt-5') ||
          _currentModel.contains('o1') ||
          _currentModel.contains('o3');

      // Convert MCP tools to OpenAI native format if available (skip when forceNoToolCalls)
      List<openai.Tool>? tools;
      if (!forceNoToolCalls &&
          availableTools != null &&
          availableTools.isNotEmpty) {
        tools = availableTools.map((mcpTool) {
          return openai.Tool.function(
            name: mcpTool.name,
            description: mcpTool.description ?? 'No description provided',
            parameters:
                mcpTool.inputSchema ?? {'type': 'object', 'properties': {}},
          );
        }).toList();
        talker.info('🔧 Sending ${tools.length} tools to OpenAI API');
      }

      // Generate a stable prompt cache key from the system prompt content
      // so that repeated requests with the same system prompt benefit from
      // OpenAI prompt caching (50%+ token savings on cached prefixes).
      String? promptCacheKey;
      if (tools != null && tools.isNotEmpty) {
        final sysMsg = _extractSystemMessage(messages);
        if (sysMsg != null && sysMsg.isNotEmpty) {
          promptCacheKey = 'tealkit-openai-${_hashString(sysMsg)}';
        }
      }

      // Auto-enable fast service tier for OpenAI direct provider
      // (up to 2.5x faster, ignored by non-OpenAI endpoints)
      final effectiveServiceTier = _serviceTier ?? 'auto';

      final request = openai.ChatCompletionCreateRequest(
        model: _currentModel,
        messages: openaiMessages,
        temperature: effectiveTemperature,
        maxTokens: useMaxCompletionTokens ? null : effectiveMaxTokens,
        maxCompletionTokens: useMaxCompletionTokens ? effectiveMaxTokens : null,
        tools: tools,
        promptCacheKey: promptCacheKey,
        promptCacheRetention: promptCacheKey != null
            ? openai.PromptCacheRetention.inMemory
            : null,
        serviceTier: effectiveServiceTier == 'auto'
            ? null
            : effectiveServiceTier,
        reasoningEffort: _reasoningEffort != null
            ? openai.ReasoningEffort.fromJson(_reasoningEffort!)
            : null,
      );

      if (onStreamChunk != null) {
        talker.info('🌊 Using streaming API for OpenAI provider');
        String fullContent = '';
        String finishReason = 'stop';
        final Map<int, Map<String, dynamic>> toolCallAccumulator = {};

        await for (final chunk in _openaiClient!.chat.completions.createStream(
          request,
        )) {
          if (chunk.choices != null && chunk.choices!.isNotEmpty) {
            final delta = chunk.choices!.first.delta;
            final chunkContent = delta.content ?? '';
            if (chunkContent.isNotEmpty) {
              fullContent += chunkContent;
              onStreamChunk(chunkContent);
            }
            if (delta.toolCalls != null) {
              for (final tc in delta.toolCalls!) {
                final idx = tc.index;
                if (!toolCallAccumulator.containsKey(idx)) {
                  toolCallAccumulator[idx] = {
                    'id': '',
                    'name': '',
                    'args': StringBuffer(),
                  };
                }
                final entry = toolCallAccumulator[idx]!;
                if (tc.id != null && tc.id!.isNotEmpty) entry['id'] = tc.id!;
                if (tc.function?.name != null &&
                    tc.function!.name!.isNotEmpty) {
                  entry['name'] = tc.function!.name!;
                }
                if (tc.function?.arguments != null) {
                  (entry['args'] as StringBuffer).write(
                    tc.function!.arguments!,
                  );
                }
              }
            }
            if (chunk.choices!.first.finishReason != null) {
              finishReason = chunk.choices!.first.finishReason!.name;
            }
          }
        }

        talker.info(
          '📥 OpenAI stream complete - content length: ${fullContent.length}, accumulated tool calls: ${toolCallAccumulator.length}',
        );

        List<LLMToolCall> toolCalls = [];
        if (toolCallAccumulator.isNotEmpty) {
          talker.info(
            '🔧 Converting ${toolCallAccumulator.length} accumulated native tool calls',
          );
          for (final entry in toolCallAccumulator.entries) {
            final name = entry.value['name'] as String;
            final argsStr = (entry.value['args'] as StringBuffer).toString();
            final id = entry.value['id'] as String;
            if (name.isNotEmpty) {
              try {
                final args = argsStr.isNotEmpty
                    ? jsonDecode(argsStr) as Map<String, dynamic>
                    : <String, dynamic>{};
                toolCalls.add(LLMToolCall(id: id, name: name, arguments: args));
              } catch (e) {
                talker.warning(
                  'Failed to parse streamed tool call arguments for "$name": $e',
                );
              }
            }
          }
        } else {
          toolCalls = _extractToolCalls(fullContent);
        }

        return LLMResponse(
          content: fullContent,
          toolCalls: toolCalls,
          usage: const LLMUsage(
            promptTokens: 0,
            completionTokens: 0,
            totalTokens: 0,
          ),
          finishReason: finishReason,
        );
      }

      final response = await _openaiClient!.chat.completions.create(request);
      final choice = response.choices.first;
      final messageContent = choice.message.content ?? '';

      List<LLMToolCall> toolCalls = [];
      if (choice.message.toolCalls != null &&
          choice.message.toolCalls!.isNotEmpty) {
        talker.info(
          '✅ Received ${choice.message.toolCalls!.length} native tool calls from OpenAI API',
        );
        for (final toolCall in choice.message.toolCalls!) {
          try {
            toolCalls.add(
              LLMToolCall(
                id: toolCall.id,
                name: toolCall.function.name,
                arguments: jsonDecode(toolCall.function.arguments.toString()),
              ),
            );
          } catch (e) {
            talker.error('Failed to parse tool call: $e');
          }
        }
      } else {
        toolCalls = _extractToolCalls(messageContent);
      }

      return LLMResponse(
        content: messageContent,
        toolCalls: toolCalls,
        usage: LLMUsage(
          promptTokens: response.usage?.promptTokens ?? 0,
          completionTokens: response.usage?.completionTokens ?? 0,
          totalTokens: response.usage?.totalTokens ?? 0,
        ),
        finishReason: choice.finishReason?.name ?? 'stop',
      );
    } catch (e) {
      throw Exception('OpenAI generation failed: $e');
    }
  }

  /// Generate with OpenAI-compatible provider (LM Studio, LocalAI, etc.)
  Future<LLMResponse> _generateWithOpenAICompatible({
    required List<ChatMessage> messages,
    List<MCPTool>? availableTools,
    double? temperature,
    int? maxTokens,
    bool forceNoToolCalls = false,
    void Function(String chunk)? onStreamChunk,
  }) async {
    // Use instance variables if not provided
    final effectiveTemperature = temperature ?? _temperature;
    final effectiveMaxTokens = _normalizeMaxTokens(maxTokens);
    if (_openaiCompatibleClient == null) {
      throw Exception('OpenAI-compatible provider not initialized');
    }

    final openaiMessages = _convertToOpenAIMessages(messages);
    talker.info(
      'Converted to ${openaiMessages.length} OpenAI-compatible messages',
    );

    try {
      // Convert MCP tools to OpenAI format if available
      List<openai.Tool>? tools;
      if (!forceNoToolCalls &&
          availableTools != null &&
          availableTools.isNotEmpty) {
        tools = availableTools.map((mcpTool) {
          return openai.Tool.function(
            name: mcpTool.name,
            description: mcpTool.description ?? 'No description provided',
            parameters:
                mcpTool.inputSchema ?? {'type': 'object', 'properties': {}},
          );
        }).toList();
        talker.info(
          '🔧 Sending ${tools.length} tools to OpenAI-compatible API',
        );
      }

      final request = openai.ChatCompletionCreateRequest(
        model: _openaiCompatibleModel ?? 'local-model',
        messages: openaiMessages,
        temperature: effectiveTemperature,
        maxTokens: effectiveMaxTokens,
        tools: tools,
        reasoningEffort: _reasoningEffort != null
            ? openai.ReasoningEffort.fromJson(_reasoningEffort!)
            : null,
      );

      // Use streaming when a callback is provided, non-streaming otherwise.
      if (onStreamChunk != null) {
        talker.info('🌊 Using streaming API for OpenAI-compatible provider');
        String fullContent = '';
        List<LLMToolCall> toolCalls = [];
        String finishReason = 'stop';
        final Map<int, Map<String, dynamic>> toolCallAccumulator = {};

        try {
          await for (final chunk
              in _openaiCompatibleClient!.chat.completions.createStream(
                request,
              )) {
            if (chunk.choices != null && chunk.choices!.isNotEmpty) {
              final delta = chunk.choices!.first.delta;
              final chunkContent = delta.content ?? '';
              if (chunkContent.isNotEmpty) {
                fullContent += chunkContent;
                onStreamChunk(chunkContent);
              }
              if (delta.toolCalls != null) {
                for (final tc in delta.toolCalls!) {
                  final idx = tc.index;
                  if (!toolCallAccumulator.containsKey(idx)) {
                    toolCallAccumulator[idx] = {
                      'id': '',
                      'name': '',
                      'args': StringBuffer(),
                    };
                  }
                  final entry = toolCallAccumulator[idx]!;
                  if (tc.id != null && tc.id!.isNotEmpty) entry['id'] = tc.id!;
                  if (tc.function?.name != null &&
                      tc.function!.name!.isNotEmpty) {
                    entry['name'] = tc.function!.name!;
                  }
                  if (tc.function?.arguments != null) {
                    (entry['args'] as StringBuffer).write(
                      tc.function!.arguments!,
                    );
                  }
                }
              }
              if (chunk.choices!.first.finishReason != null) {
                finishReason = chunk.choices!.first.finishReason!.name;
              }
            }
          }

          talker.info(
            '📥 OpenAI-compatible stream complete - content length: ${fullContent.length}, accumulated tool calls: ${toolCallAccumulator.length}',
          );

          if (!forceNoToolCalls) {
            if (toolCallAccumulator.isNotEmpty) {
              talker.info(
                '🔧 Converting ${toolCallAccumulator.length} accumulated native tool calls',
              );
              for (final entry in toolCallAccumulator.entries) {
                final name = entry.value['name'] as String;
                final argsStr = (entry.value['args'] as StringBuffer)
                    .toString();
                final id = entry.value['id'] as String;
                if (name.isNotEmpty) {
                  try {
                    final args = argsStr.isNotEmpty
                        ? jsonDecode(argsStr) as Map<String, dynamic>
                        : <String, dynamic>{};
                    toolCalls.add(
                      LLMToolCall(id: id, name: name, arguments: args),
                    );
                  } catch (e) {
                    talker.warning(
                      'Failed to parse streamed tool call arguments for "$name": $e',
                    );
                  }
                }
              }
            } else {
              toolCalls = _extractToolCalls(fullContent);
            }
          }

          return LLMResponse(
            content: fullContent,
            toolCalls: toolCalls,
            usage: const LLMUsage(
              promptTokens: 0,
              completionTokens: 0,
              totalTokens: 0,
            ),
            finishReason: finishReason,
          );
        } catch (e) {
          final errorText = e.toString();
          final embeddedStreamUnsupported =
              errorText.contains(
                'Embedded provider does not support streaming',
              ) ||
              errorText.contains('Use non-stream requests');

          if (!embeddedStreamUnsupported) {
            rethrow;
          }

          talker.warning(
            '⚠️ Streaming not supported by embedded server endpoint, retrying as non-stream request',
          );

          final fallbackResponse = await _openaiCompatibleClient!
              .chat
              .completions
              .create(request);
          final fallbackChoice = fallbackResponse.choices.first;
          final fallbackContent = fallbackChoice.message.content ?? '';

          if (fallbackContent.isNotEmpty) {
            onStreamChunk(fallbackContent);
          }

          final fallbackToolCalls = <LLMToolCall>[];
          if (!forceNoToolCalls &&
              fallbackChoice.message.toolCalls != null &&
              fallbackChoice.message.toolCalls!.isNotEmpty) {
            talker.info(
              '✅ Received ${fallbackChoice.message.toolCalls!.length} native tool calls from fallback non-stream response',
            );
            for (final toolCall in fallbackChoice.message.toolCalls!) {
              try {
                fallbackToolCalls.add(
                  LLMToolCall(
                    id: toolCall.id,
                    name: toolCall.function.name,
                    arguments:
                        jsonDecode(toolCall.function.arguments.toString())
                            as Map<String, dynamic>,
                  ),
                );
              } catch (parseError) {
                talker.error('Failed to parse fallback tool call: $parseError');
              }
            }
          } else if (!forceNoToolCalls) {
            fallbackToolCalls.addAll(_extractToolCalls(fallbackContent));
          }

          return LLMResponse(
            content: fallbackContent,
            toolCalls: fallbackToolCalls,
            usage: LLMUsage(
              promptTokens: fallbackResponse.usage?.promptTokens ?? 0,
              completionTokens: fallbackResponse.usage?.completionTokens ?? 0,
              totalTokens: fallbackResponse.usage?.totalTokens ?? 0,
            ),
            finishReason: fallbackChoice.finishReason?.name ?? 'stop',
          );
        }
      }

      final response = await _openaiCompatibleClient!.chat.completions.create(
        request,
      );
      final choice = response.choices.first;
      final messageContent = choice.message.content ?? '';

      List<LLMToolCall> toolCalls = [];
      if (choice.message.toolCalls != null &&
          choice.message.toolCalls!.isNotEmpty) {
        talker.info(
          '✅ Received ${choice.message.toolCalls!.length} native tool calls from OpenAI-compatible API',
        );
        for (final toolCall in choice.message.toolCalls!) {
          try {
            toolCalls.add(
              LLMToolCall(
                id: toolCall.id,
                name: toolCall.function.name,
                arguments: jsonDecode(toolCall.function.arguments.toString()),
              ),
            );
          } catch (e) {
            talker.error('Failed to parse tool call: $e');
          }
        }
      } else {
        if (!forceNoToolCalls) {
          talker.debug(
            'No native tool calls, attempting text-based extraction',
          );
          toolCalls = _extractToolCalls(messageContent);
        } else {
          talker.debug(
            'forceNoToolCalls=true: skipping text-based tool-call extraction',
          );
        }
      }

      return LLMResponse(
        content: messageContent,
        toolCalls: toolCalls,
        usage: LLMUsage(
          promptTokens: response.usage?.promptTokens ?? 0,
          completionTokens: response.usage?.completionTokens ?? 0,
          totalTokens: response.usage?.totalTokens ?? 0,
        ),
        finishReason: choice.finishReason?.name ?? 'stop',
      );
    } catch (e) {
      throw Exception('OpenAI-compatible provider generation failed: $e');
    }
  }

  List<anthropic.InputMessage> _convertToAnthropicMessages(
    List<ChatMessage> messages,
  ) {
    final List<anthropic.InputMessage> anthropicMsgs = [];

    // Helper to extract tool arguments JSON, same as for OpenAI
    String extractToolArgumentsJson(String rawContent) {
      final argsMatch = RegExp(
        r'Arguments:\s*(\{[\s\S]*\})',
        caseSensitive: false,
      ).firstMatch(rawContent);
      final argsRaw = argsMatch?.group(1)?.trim();
      if (argsRaw == null || argsRaw.isEmpty) {
        return '{}';
      }
      try {
        final decoded = jsonDecode(argsRaw);
        if (decoded is Map<String, dynamic>) {
          return jsonEncode(decoded);
        }
      } catch (_) {}
      return '{}';
    }

    for (final msg in messages) {
      if (msg.role == ChatRole.system) continue;

      if (msg.role == ChatRole.user) {
        if (msg.attachments != null && msg.attachments!.isNotEmpty) {
          final imageParts = msg.attachments!
              .where(
                (a) =>
                    a.bytes != null &&
                    (a.mimeType?.startsWith('image/') ?? false),
              )
              .toList();
          if (imageParts.isNotEmpty) {
            final blocks = <anthropic.InputContentBlock>[];
            blocks.add(anthropic.InputContentBlock.text(msg.content));
            for (final att in imageParts) {
              final b64 = base64Encode(att.bytes!);
              final mime = att.mimeType ?? 'image/jpeg';
              blocks.add(
                anthropic.InputContentBlock.image(
                  anthropic.ImageSource.base64(
                    data: b64,
                    mediaType: anthropic.ImageMediaType.fromMimeType(mime),
                  ),
                ),
              );
            }
            anthropicMsgs.add(anthropic.InputMessage.userBlocks(blocks));
            continue;
          }
        }
        anthropicMsgs.add(anthropic.InputMessage.user(msg.content));
      } else if (msg.role == ChatRole.assistant) {
        if (msg.content.contains('Calling tools') ||
            msg.content.contains('Calling additional tools')) {
          continue;
        }
        anthropicMsgs.add(anthropic.InputMessage.assistant(msg.content));
      } else if (msg.role == ChatRole.tool) {
        final toolContent = _truncateLargeToolResults(msg).trim();
        final toolCallId = msg.id.trim();
        if (toolCallId.isNotEmpty) {
          final toolName =
              (msg.lastCalledToolName ??
                      _extractCalledToolName(msg.content) ??
                      'unknown_tool')
                  .trim();
          final toolArgsJson = extractToolArgumentsJson(msg.content);

          anthropicMsgs.add(
            anthropic.InputMessage.assistantBlocks([
              anthropic.InputContentBlock.toolUse(
                id: toolCallId,
                name: toolName,
                input: jsonDecode(toolArgsJson) as Map<String, dynamic>,
              ),
            ]),
          );

          anthropicMsgs.add(
            anthropic.InputMessage.userBlocks([
              anthropic.InputContentBlock.toolResultText(
                toolUseId: toolCallId,
                text: toolContent,
              ),
            ]),
          );
        } else {
          anthropicMsgs.add(
            anthropic.InputMessage.user('Tool result:\n$toolContent'),
          );
        }
      }
    }
    return anthropicMsgs;
  }

  /// Generate with Claude (Anthropic)
  Future<LLMResponse> _generateWithClaude({
    required List<ChatMessage> messages,
    List<MCPTool>? availableTools,
    double temperature = 0.7,
    int? maxTokens,
    bool forceNoToolCalls = false,
    void Function(String chunk)? onStreamChunk,
  }) async {
    if (_claudeClient == null) {
      throw Exception('Claude not initialized');
    }

    // Extract system prompt from messages (Claude uses separate system parameter)
    String systemPrompt = 'You are a helpful AI assistant.';
    final systemMessage = messages.firstWhere(
      (m) => m.role == ChatRole.system,
      orElse: () => ChatMessage(
        id: '',
        role: ChatRole.system,
        content: systemPrompt,
        timestamp: DateTime.now(),
      ),
    );
    systemPrompt = systemMessage.content;

    final claudeMessages = _convertToAnthropicMessages(messages);

    try {
      final effectiveMaxTokens = (maxTokens != null && maxTokens > 0)
          ? maxTokens
          : 4096;

      final List<anthropic.ToolDefinition> anthropicTools = [];
      if (!forceNoToolCalls &&
          availableTools != null &&
          availableTools.isNotEmpty) {
        for (final t in availableTools) {
          anthropicTools.add(
            anthropic.ToolDefinition.custom(
              anthropic.Tool(
                name: t.name,
                description: t.description ?? '',
                inputSchema: anthropic.InputSchema.fromJson(
                  t.inputSchema ?? {'type': 'object', 'properties': {}},
                ),
              ),
            ),
          );
        }
      }

      final request = anthropic.MessageCreateRequest(
        model: _currentModel,
        messages: claudeMessages,
        system: systemPrompt.trim().isNotEmpty
            ? anthropic.SystemPrompt.text(systemPrompt)
            : null,
        tools: anthropicTools.isNotEmpty ? anthropicTools : null,
        maxTokens: effectiveMaxTokens,
        temperature: temperature,
      );

      if (onStreamChunk != null) {
        talker.info('🌊 Using streaming API for Claude provider');
        String fullContent = '';
        final toolCalls = <LLMToolCall>[];
        final Map<int, Map<String, dynamic>> toolCallAccumulator = {};

        await for (final event in _claudeClient!.messages.createStream(
          request,
        )) {
          if (event is anthropic.ContentBlockDeltaEvent) {
            final delta = event.delta;
            if (delta is anthropic.TextDelta) {
              final text = delta.text;
              fullContent += text;
              onStreamChunk(text);
            } else if (delta is anthropic.InputJsonDelta) {
              final idx = event.index;
              if (!toolCallAccumulator.containsKey(idx)) {
                toolCallAccumulator[idx] = {
                  'id': '',
                  'name': '',
                  'args': StringBuffer(),
                };
              }
              final entry = toolCallAccumulator[idx]!;
              entry['args'].write(delta.partialJson);
            }
          } else if (event is anthropic.ContentBlockStartEvent) {
            final block = event.contentBlock;
            if (block is anthropic.ToolUseBlock) {
              final idx = event.index;
              if (!toolCallAccumulator.containsKey(idx)) {
                toolCallAccumulator[idx] = {
                  'id': block.id,
                  'name': block.name,
                  'args': StringBuffer(),
                };
              } else {
                toolCallAccumulator[idx]!['id'] = block.id;
                toolCallAccumulator[idx]!['name'] = block.name;
              }
            }
          }
        }

        // Convert accumulated tool calls
        if (toolCallAccumulator.isNotEmpty) {
          for (final entry in toolCallAccumulator.entries) {
            final name = entry.value['name'] as String;
            final argsStr = entry.value['args'].toString();
            final id = entry.value['id'] as String;
            if (name.isNotEmpty) {
              try {
                final args = argsStr.isNotEmpty
                    ? jsonDecode(argsStr) as Map<String, dynamic>
                    : <String, dynamic>{};
                toolCalls.add(LLMToolCall(id: id, name: name, arguments: args));
              } catch (_) {}
            }
          }
        } else {
          toolCalls.addAll(_extractToolCalls(fullContent));
        }

        return LLMResponse(
          content: fullContent,
          toolCalls: toolCalls,
          usage: const LLMUsage(
            promptTokens: 0,
            completionTokens: 0,
            totalTokens: 0,
          ),
          finishReason: 'stop',
        );
      }

      final response = await _claudeClient!.messages.create(request);

      final textBuffer = StringBuffer();
      final toolCalls = <LLMToolCall>[];

      for (final block in response.content) {
        if (block is anthropic.TextBlock) {
          textBuffer.write(block.text);
        } else if (block is anthropic.ToolUseBlock) {
          toolCalls.add(
            LLMToolCall(id: block.id, name: block.name, arguments: block.input),
          );
        }
      }

      final messageContent = textBuffer.toString();
      if (toolCalls.isEmpty && !forceNoToolCalls) {
        toolCalls.addAll(_extractToolCalls(messageContent));
      }

      return LLMResponse(
        content: messageContent,
        toolCalls: toolCalls,
        usage: LLMUsage(
          promptTokens: response.usage.inputTokens,
          completionTokens: response.usage.outputTokens,
          totalTokens: response.usage.inputTokens + response.usage.outputTokens,
        ),
        finishReason: response.stopReason?.name ?? 'stop',
      );
    } catch (e) {
      throw Exception('Claude generation failed: $e');
    }
  }

  /// Convert a JSON genai.Schema map (from MCPTool.inputSchema) to a Gemini [genai.Schema] object.
  genai.Schema? _mcpSchemaToGemini(Map<String, dynamic>? jsonSchema) {
    if (jsonSchema == null) return null;
    final type = (jsonSchema['type'] as String?)?.toLowerCase();
    final description = jsonSchema['description'] as String?;

    switch (type) {
      case 'object':
        final rawProps = jsonSchema['properties'];
        final required = (jsonSchema['required'] as List<dynamic>?)
            ?.cast<String>();
        Map<String, genai.Schema>? schemaProps;
        if (rawProps is Map) {
          schemaProps = {};
          for (final entry in rawProps.entries) {
            final propSchema = _mcpSchemaToGemini(
              entry.value is Map<dynamic, dynamic>
                  ? Map<String, dynamic>.from(
                      entry.value as Map<dynamic, dynamic>,
                    )
                  : null,
            );
            if (propSchema != null) {
              schemaProps[entry.key as String] = propSchema;
            }
          }
        }
        return genai.Schema(
          type: genai.SchemaType.object,
          description: description,
          properties: (schemaProps == null || schemaProps.isEmpty)
              ? null
              : schemaProps,
          required: required,
        );
      case 'array':
        final items = jsonSchema['items'];
        return genai.Schema(
          type: genai.SchemaType.array,
          description: description,
          items: items is Map<dynamic, dynamic>
              ? _mcpSchemaToGemini(Map<String, dynamic>.from(items))
              : null,
        );
      case 'integer':
        return genai.Schema(
          type: genai.SchemaType.integer,
          description: description,
        );
      case 'number':
        return genai.Schema(
          type: genai.SchemaType.number,
          description: description,
        );
      case 'boolean':
        return genai.Schema(
          type: genai.SchemaType.boolean,
          description: description,
        );
      case 'string':
      default:
        final enumValues = (jsonSchema['enum'] as List<dynamic>?)
            ?.cast<String>();
        return genai.Schema(
          type: genai.SchemaType.string,
          description: description,
          enumValues: enumValues,
        );
    }
  }

  /// Build tools prompt for LLM (used for text-based providers; kept for diagnostics)
  // ignore: unused_element
  Future<String> _buildToolsPrompt(List<MCPTool> tools) async {
    final buffer = StringBuffer();
    buffer.writeln(
      'You are a helpful AI assistant with access to tools for specific tasks.',
    );
    buffer.writeln();
    buffer.writeln('Available tools:');

    for (final tool in tools) {
      buffer.writeln('## ${tool.name}');
      buffer.writeln('Description: ${tool.description ?? "No description"}');

      // Add parameter details if available
      if (tool.inputSchema != null && tool.inputSchema!['properties'] != null) {
        buffer.writeln('Parameters:');
        final properties = _safePropsMap(tool.inputSchema!['properties']);
        final required =
            (tool.inputSchema!['required'] as List<dynamic>?) ?? [];

        for (final entry in properties.entries) {
          final paramName = entry.key;
          final paramInfo = entry.value is Map
              ? Map<String, dynamic>.from(entry.value as Map)
              : <String, dynamic>{};
          final paramType = paramInfo['type'] ?? 'string';
          final paramDesc = paramInfo['description'] ?? 'No description';
          final isRequired = required.contains(paramName);

          buffer.writeln(
            '  - $paramName ($paramType)${isRequired ? ' [REQUIRED]' : ' [OPTIONAL]'}: $paramDesc',
          );

          // Add enum values if available
          if (paramInfo['enum'] != null) {
            final enumValues = paramInfo['enum'] as List<dynamic>;
            buffer.writeln('    Valid values: ${enumValues.join(', ')}');
          }
        }
        buffer.writeln();
      }
    }

    // Add all tool usage instructions from external configuration files
    buffer.writeln(await ToolUsageRules.getAllInstructions());

    return buffer.toString();
  }

  /// Generate with retry logic for handling API overload
  Future<T> _generateWithRetry<T>(Future<T> Function() generateFunction) async {
    const maxRetries = 5; // Increased from 3 to 5 for better reliability
    const baseDelay = Duration(seconds: 3); // Increased from 2 to 3 seconds

    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        return await generateFunction();
      } catch (e) {
        final errorMessage = e.toString().toLowerCase();

        // Check if it's a rate limit or overload error
        if (errorMessage.contains('overloaded') ||
            errorMessage.contains('rate limit') ||
            errorMessage.contains('quota') ||
            errorMessage.contains('resource exhausted') ||
            errorMessage.contains('429') ||
            errorMessage.contains('503') ||
            errorMessage.contains('too many requests')) {
          if (attempt < maxRetries) {
            // Exponential backoff: 3s, 6s, 12s, 15s, 18s
            final delay = Duration(seconds: baseDelay.inSeconds * attempt);
            talker.warning(
              '🔄 API overloaded, auto-retry $attempt/$maxRetries in ${delay.inSeconds}s...',
            );
            await Future.delayed(delay);
            continue;
          } else {
            talker.error(
              ' API still overloaded after $maxRetries automatic retries (waited ${baseDelay.inSeconds * maxRetries}s total)',
            );
            throw Exception(
              'Gemini API is overloaded. Already retried $maxRetries times automatically. Please wait a few minutes and try again.',
            );
          }
        } else {
          // For non-rate-limit errors, throw immediately
          rethrow;
        }
      }
    }

    throw Exception('Unexpected error in retry logic');
  }

  /// Extract tool calls from LLM response
  List<LLMToolCall> _extractToolCalls(String content) {
    final toolCalls = <LLMToolCall>[];

    // Check for and warn about invalid tool_code format
    if (content.contains('"tool_code"')) {
      talker.error(
        '⚠️ WARNING: Found INVALID "tool_code" format in LLM response',
      );
      talker.error(
        ' "tool_code" is NOT SUPPORTED - only "tool_call" format is valid',
      );
      talker.error(
        'This will prevent tool execution. Please fix LLM instructions.',
      );
      talker.error(
        'Response preview: ${content.substring(0, math.min(300, content.length))}...',
      );
    }

    talker.info(
      'Parsing LLM response for tool calls. genai.Content length: ${content.length}',
    );
    talker.info('FULL LLM CONTENT: $content');

    // Pre-process content to fix common JSON syntax errors
    String processedContent = content;

    // Fix the specific error: {"tool_call": ["name": ...]} should be {"tool_call": {"name": ...}}
    // Look for pattern: "tool_call": ["name": and replace with "tool_call": {"name":
    processedContent = processedContent.replaceAllMapped(
      RegExp(r'"tool_call":\s*\[\s*"name":', multiLine: true),
      (match) {
        talker.warning(
          'Found invalid tool_call syntax with square brackets, fixing to curly braces',
        );
        return '"tool_call": {"name":';
      },
    );

    // Also fix the closing bracket issue: if we find ]}` at the end after arguments, replace with }}
    processedContent = processedContent.replaceAllMapped(
      RegExp(
        r'("arguments":\s*\{[^}]*\})\s*\]\s*\}',
        multiLine: true,
        dotAll: true,
      ),
      (match) {
        talker.warning(
          'Found closing square bracket after arguments, fixing to curly brace',
        );
        return '${match.group(1)!}}}';
      },
    );

    // Try to extract XML-style tool calls: <tool_call>...</tool_call>
    final xmlToolCallPattern = RegExp(
      r'<tool_call>\s*(.*?)\s*</tool_call>',
      dotAll: true,
      caseSensitive: false,
    );
    final xmlMatches = xmlToolCallPattern.allMatches(processedContent);
    talker.info('Found ${xmlMatches.length} XML tool call tags');
    for (final match in xmlMatches) {
      try {
        final jsonStr = match.group(1)?.trim() ?? '';
        if (jsonStr.isNotEmpty) {
          talker.info('Parsing XML tool call content: $jsonStr');
          final decoded = jsonDecode(jsonStr);
          if (decoded is Map<String, dynamic>) {
            final inner = decoded['tool_call'] is Map<String, dynamic>
                ? decoded['tool_call'] as Map<String, dynamic>
                : decoded;
            final toolName = inner['name'] as String?;
            final arguments =
                (inner['arguments'] ?? inner['parameters'])
                    as Map<String, dynamic>?;
            if (toolName != null && toolName.isNotEmpty && arguments != null) {
              final extractedCall = LLMToolCall(
                name: toolName,
                arguments: arguments,
              );
              talker.info(
                'Successfully extracted XML tool call: ${extractedCall.name} with args: ${extractedCall.arguments}',
              );
              toolCalls.add(extractedCall);
            }
          }
        }
      } catch (e) {
        talker.warning('Failed to parse XML tool call tag content: $e');
      }
    }

    // First handle the exact training-target format used by the weather models:
    // tool_call: {"name":"...","arguments":{...}}
    if (toolCalls.isEmpty) {
      final markerMatch = RegExp(
        r'tool[_ ]call\s*:',
        caseSensitive: false,
      ).firstMatch(processedContent);
      if (markerMatch != null) {
        final firstBrace = processedContent.indexOf('{', markerMatch.end);
        if (firstBrace >= 0) {
          try {
            final jsonStr = _extractBalancedJson(
              processedContent.substring(firstBrace),
            );
            if (jsonStr.isNotEmpty) {
              final decoded = jsonDecode(jsonStr);
              if (decoded is Map<String, dynamic>) {
                final inner = decoded['tool_call'] is Map<String, dynamic>
                    ? decoded['tool_call'] as Map<String, dynamic>
                    : decoded;
                final toolName = inner['name'] as String?;
                final arguments = inner['arguments'] as Map<String, dynamic>?;
                if (toolName != null &&
                    toolName.isNotEmpty &&
                    arguments != null) {
                  final extractedCall = LLMToolCall(
                    name: toolName,
                    arguments: arguments,
                  );
                  talker.info(
                    'Successfully extracted tool call from training-target format: ${extractedCall.name} with args: ${extractedCall.arguments}',
                  );
                  toolCalls.add(extractedCall);
                }
              }
            }
          } catch (e) {
            talker.warning(
              'Failed to parse training-target tool_call format: $e',
            );
          }
        }
      }
    }

    // Look for JSON code blocks with tool_call structure - more flexible matching
    final jsonRegex = RegExp(
      r'```(?:json)?\s*(\{.*?"tool_call".*?\})\s*```',
      dotAll: true,
      multiLine: true,
    );
    final matches = jsonRegex.allMatches(processedContent);
    talker.info(
      'Found ${matches.length} potential tool call matches in code blocks',
    );

    // Process code block matches first
    for (final match in matches) {
      try {
        final jsonStr = match.group(1) ?? '';
        if (jsonStr.isEmpty) continue;

        talker.info('Parsing JSON from code block: $jsonStr');
        final json = jsonDecode(jsonStr) as Map<String, dynamic>;

        // More flexible validation - check if tool_call exists regardless of other fields
        if (json.containsKey('tool_call')) {
          final toolCall = json['tool_call'] as Map<String, dynamic>;
          if (toolCall.containsKey('name') &&
              toolCall.containsKey('arguments') &&
              toolCall['name'] is String &&
              toolCall['arguments'] is Map<String, dynamic>) {
            final extractedCall = LLMToolCall(
              id: toolCall['id']?.toString(),
              name: toolCall['name'] as String,
              arguments: toolCall['arguments'] as Map<String, dynamic>,
            );
            talker.info(
              'Successfully extracted tool call from code block: ${extractedCall.name} with args: ${extractedCall.arguments}',
            );
            toolCalls.add(extractedCall);
          } else {
            talker.warning(
              'genai.Tool call structure invalid in code block: missing name or arguments',
            );
            talker.warning('genai.Tool call content: $toolCall');
          }
        } else {
          talker.warning(
            'JSON in code block does not contain valid tool_call structure. Keys: ${json.keys.toList()}',
          );
        }
      } catch (e) {
        talker.debug(
          'Ignored potential tool call parsing error in code block: $e',
        );
        continue;
      }
    }

    // If no code block tool calls found, look for raw JSON anywhere in content
    if (toolCalls.isEmpty) {
      talker.info('No code block tool calls found, checking for raw JSON...');

      // Use a more sophisticated approach to find complete JSON objects with tool_call or name/arguments structure
      // We'll find the opening brace before the pattern and then match braces to find the complete object
      final toolCallPattern = RegExp(
        r'"tool_call"|"name"\s*:',
        multiLine: true,
      );
      final matches = toolCallPattern.allMatches(processedContent);
      talker.info('Found ${matches.length} tool call references in content');

      for (final match in matches) {
        try {
          // Find the opening brace before this reference
          int searchStart = match.start;
          int? openBracePos;

          // Search backwards for opening brace
          for (int i = searchStart - 1; i >= 0; i--) {
            if (processedContent[i] == '{') {
              openBracePos = i;
              break;
            }
            // Stop if we hit a closing brace (means we're in another JSON object)
            if (processedContent[i] == '}') {
              break;
            }
          }

          if (openBracePos == null) continue;

          // Now find the matching closing brace
          int braceCount = 1;
          int? closeBracePos;

          for (int i = openBracePos + 1; i < processedContent.length; i++) {
            if (processedContent[i] == '{') {
              braceCount++;
            } else if (processedContent[i] == '}') {
              braceCount--;
              if (braceCount == 0) {
                closeBracePos = i;
                break;
              }
            }
          }

          if (closeBracePos == null) continue;

          // Extract the complete JSON object
          final jsonStr = processedContent.substring(
            openBracePos,
            closeBracePos + 1,
          );
          talker.info('Found potential complete JSON object: $jsonStr');

          final json = jsonDecode(jsonStr) as Map<String, dynamic>;

          final inner = json.containsKey('tool_call')
              ? json['tool_call'] as Map<String, dynamic>
              : json;
          final toolName = inner['name'] as String?;
          final arguments =
              (inner['arguments'] ?? inner['parameters'])
                  as Map<String, dynamic>?;

          if (toolName != null && toolName.isNotEmpty && arguments != null) {
            final extractedCall = LLMToolCall(
              id: inner['id']?.toString(),
              name: toolName,
              arguments: arguments,
            );
            final isDuplicate = toolCalls.any(
              (tc) =>
                  tc.name == toolName &&
                  jsonEncode(tc.arguments) == jsonEncode(arguments),
            );
            if (!isDuplicate) {
              talker.info(
                'Successfully extracted tool call from raw JSON: ${extractedCall.name} with args: ${extractedCall.arguments}',
              );
              toolCalls.add(extractedCall);
            }
          } else {
            talker.warning(
              'Raw JSON does not contain valid name and arguments/parameters structure.',
            );
          }
        } catch (e) {
          talker.debug(
            'Ignored potential tool call parsing error in raw JSON: $e',
          );
          continue;
        }
      }
    }

    // If still no JSON tool calls found, try parsing plain text format
    if (toolCalls.isEmpty) {
      talker.info('No JSON tool calls found, trying plain text parsing...');
      final plainTextToolCalls = _extractPlainTextToolCalls(processedContent);
      toolCalls.addAll(plainTextToolCalls);
    }

    // If still no tool calls, try parsing toolname[ARGS]{...} syntax (Mistral/Ministral fallback)
    if (toolCalls.isEmpty) {
      talker.info(
        'No plain text tool calls found, trying toolName[ARGS]{...} syntax parsing...',
      );
      final argsBracketCalls = _extractArgsBracketToolCalls(processedContent);
      toolCalls.addAll(argsBracketCalls);
    }

    // If still no tool calls, try parsing <function=...> syntax (Llama fallback)
    if (toolCalls.isEmpty) {
      talker.info(
        'No [ARGS] tool calls found, trying <function=...> syntax parsing...',
      );
      final functionSyntaxCalls = _extractFunctionSyntaxToolCalls(
        processedContent,
      );
      toolCalls.addAll(functionSyntaxCalls);
    }

    talker.info('Final extracted tool calls: ${toolCalls.length}');

    return toolCalls;
  }

  /// Parses responses in the format:  toolName[ARGS]{"key": "value"}
  /// Emitted by Mistral/Ministral models when native tool calling is not triggered.
  List<LLMToolCall> _extractArgsBracketToolCalls(String content) {
    final toolCalls = <LLMToolCall>[];
    final pattern = RegExp(r'([a-zA-Z0-9_]+)\[ARGS\]\s*(\{)', multiLine: true);
    final matches = pattern.allMatches(content);
    talker.info('Found ${matches.length} [ARGS] patterns');

    for (final match in matches) {
      try {
        final toolName = match.group(1);
        if (toolName == null) continue;
        final jsonStartPos = match.end - 1;
        final balancedJson = _extractBalancedJson(
          content.substring(jsonStartPos),
        );
        if (balancedJson.isEmpty) {
          talker.warning(
            'Could not extract balanced JSON from $toolName[ARGS]',
          );
          continue;
        }
        final arguments = jsonDecode(balancedJson) as Map<String, dynamic>;
        toolCalls.add(LLMToolCall(name: toolName, arguments: arguments));
        talker.info(
          '✅ Extracted [ARGS] tool call: $toolName with ${arguments.keys.length} arguments',
        );
      } catch (e) {
        talker.error('Failed to parse [ARGS] tool call: $e');
      }
    }
    return toolCalls;
  }

  List<LLMToolCall> _extractFunctionSyntaxToolCalls(String content) {
    final toolCalls = <LLMToolCall>[];

    // Pattern: <function=tool_name> followed by JSON
    final pattern = RegExp(
      r'<function=([a-zA-Z0-9_]+)>\s*(\{)',
      multiLine: true,
    );
    final matches = pattern.allMatches(content);

    talker.info('Found ${matches.length} <function=...> patterns');

    for (final match in matches) {
      try {
        final toolName = match.group(1);
        if (toolName == null) continue;

        // Start position of the JSON (the opening brace)
        final jsonStartPos = match.end - 1; // Position of '{'

        talker.info(
          'Parsing <function=$toolName> starting at position $jsonStartPos',
        );

        // Extract balanced JSON starting from the opening brace
        final jsonSubstring = content.substring(jsonStartPos);
        final balancedJson = _extractBalancedJson(jsonSubstring);

        if (balancedJson.isEmpty) {
          talker.warning(
            'Could not extract balanced JSON from <function=$toolName>',
          );
          continue;
        }

        talker.info(
          'Extracted JSON length: ${balancedJson.length}, preview: ${balancedJson.substring(0, math.min(200, balancedJson.length))}...',
        );

        Map<String, dynamic> arguments;
        try {
          arguments = jsonDecode(balancedJson) as Map<String, dynamic>;
        } catch (e) {
          talker.warning('Failed to parse JSON for <function=$toolName>: $e');
          talker.warning('JSON was: $balancedJson');
          continue;
        }

        final toolCall = LLMToolCall(name: toolName, arguments: arguments);

        talker.info(
          '✅ Successfully extracted <function=$toolName> tool call with ${arguments.keys.length} arguments',
        );
        toolCalls.add(toolCall);
      } catch (e) {
        talker.error('Failed to parse <function=...> tool call: $e');
      }
    }

    return toolCalls;
  }

  /// Extract tool calls from plain text formats like
  /// "Called tool: name\nArguments: {...}" or
  /// "tool call:\nname\n{...}" or
  /// "tool call:\nname\nparameters: key=value".
  List<LLMToolCall> _extractPlainTextToolCalls(String content) {
    final toolCalls = <LLMToolCall>[];

    final multilinePattern = RegExp(
      r'tool[_ ]?call\s*:?\s*\n\s*([a-zA-Z0-9_]+)\s*\n\s*(\{)',
      caseSensitive: false,
      multiLine: true,
    );
    final multilineMatches = multilinePattern.allMatches(content);
    talker.info(
      'Found ${multilineMatches.length} Qwen multiline JSON tool call patterns',
    );

    for (final match in multilineMatches) {
      try {
        final toolName = match.group(1);
        if (toolName == null) continue;

        final jsonStartPos = match.end - 1;
        final argumentsStr = _extractBalancedJson(
          content.substring(jsonStartPos),
        );
        if (argumentsStr.isEmpty) continue;

        final arguments = jsonDecode(argumentsStr) as Map<String, dynamic>;
        final toolCall = LLMToolCall(name: toolName, arguments: arguments);
        talker.info(
          'Successfully extracted Qwen multiline JSON tool call: ${toolCall.name}',
        );
        toolCalls.add(toolCall);
      } catch (e) {
        talker.error('Failed to parse Qwen multiline JSON tool call: $e');
      }
    }

    if (toolCalls.isNotEmpty) {
      return toolCalls;
    }

    final multilineParamsPattern = RegExp(
      r'tool[_ ]?call\s*:?\s*\n\s*([a-zA-Z0-9_]+)\s*\n\s*parameters\s*:?\s*(.*?)(?=\n\n|\Z)',
      caseSensitive: false,
      dotAll: true,
      multiLine: true,
    );
    final multilineParamsMatches = multilineParamsPattern.allMatches(content);
    talker.info(
      'Found ${multilineParamsMatches.length} Qwen multiline parameters tool call patterns',
    );

    for (final match in multilineParamsMatches) {
      try {
        final toolName = match.group(1);
        final paramsRaw = match.group(2);
        if (toolName == null || paramsRaw == null) continue;

        final arguments = _parseLooseKeyValueArgs(paramsRaw);
        final toolCall = LLMToolCall(name: toolName, arguments: arguments);
        talker.info(
          'Successfully extracted Qwen multiline parameters tool call: ${toolCall.name}',
        );
        toolCalls.add(toolCall);
      } catch (e) {
        talker.error('Failed to parse Qwen multiline parameters tool call: $e');
      }
    }

    if (toolCalls.isNotEmpty) {
      return toolCalls;
    }

    final inlineParamsPattern = RegExp(
      r'tool[_ ]?call\s*:?\s*([a-zA-Z0-9_]+)\s*\n\s*parameters\s*:?\s*(.*?)(?=\n\n|\Z)',
      caseSensitive: false,
      dotAll: true,
      multiLine: true,
    );
    final inlineParamsMatches = inlineParamsPattern.allMatches(content);
    talker.info(
      'Found ${inlineParamsMatches.length} Qwen inline parameters tool call patterns',
    );

    for (final match in inlineParamsMatches) {
      try {
        final toolName = match.group(1);
        final paramsRaw = match.group(2);
        if (toolName == null || paramsRaw == null) continue;

        final arguments = _parseLooseKeyValueArgs(paramsRaw);
        final toolCall = LLMToolCall(name: toolName, arguments: arguments);
        talker.info(
          'Successfully extracted Qwen inline parameters tool call: ${toolCall.name}',
        );
        toolCalls.add(toolCall);
      } catch (e) {
        talker.error('Failed to parse Qwen inline parameters tool call: $e');
      }
    }

    if (toolCalls.isNotEmpty) {
      return toolCalls;
    }

    // Find all "Called tool:" occurrences
    final toolCallStarts = <int>[];
    const pattern = 'Called tool:';
    int index = 0;
    while ((index = content.indexOf(pattern, index)) != -1) {
      toolCallStarts.add(index);
      index += pattern.length;
    }

    talker.info('Found ${toolCallStarts.length} plain text tool call patterns');

    for (int i = 0; i < toolCallStarts.length; i++) {
      try {
        final startIndex = toolCallStarts[i];
        final endIndex = i < toolCallStarts.length - 1
            ? toolCallStarts[i + 1]
            : content.length;
        final section = content.substring(startIndex, endIndex);

        // Extract tool name
        final toolNameMatch = RegExp(
          r'Called tool:\s*([\w_]+)',
        ).firstMatch(section);
        if (toolNameMatch == null) continue;

        final toolName = toolNameMatch.group(1);
        if (toolName == null) continue;

        // Extract arguments JSON - find the opening brace and match it properly
        final argsMatch = RegExp(r'Arguments:\s*(\{)').firstMatch(section);
        if (argsMatch == null) continue;

        final jsonStartIndex = argsMatch.end - 1; // Position of opening '{'
        final argumentsStr = _extractBalancedJson(
          section.substring(jsonStartIndex),
        );

        if (argumentsStr.isEmpty) continue;

        talker.info(
          'Parsing plain text tool call: $toolName with args length: ${argumentsStr.length}',
        );

        Map<String, dynamic> arguments;
        try {
          // Try parsing as valid JSON first
          arguments = jsonDecode(argumentsStr) as Map<String, dynamic>;
        } catch (e) {
          // If that fails, try to fix JavaScript object notation to JSON
          talker.info(
            'JSON parsing failed, trying to fix JavaScript object notation...',
          );
          String fixedJson = _convertJsObjectToJson(argumentsStr);
          talker.info('Fixed JSON length: ${fixedJson.length}');
          arguments = jsonDecode(fixedJson) as Map<String, dynamic>;
        }

        final toolCall = LLMToolCall(name: toolName, arguments: arguments);

        talker.info(
          'Successfully extracted plain text tool call: ${toolCall.name}',
        );
        toolCalls.add(toolCall);
      } catch (e) {
        talker.error('Failed to parse plain text tool call: $e');
      }
    }

    return toolCalls;
  }

  Map<String, dynamic> _parseLooseKeyValueArgs(String input) {
    final result = <String, dynamic>{};
    final normalized = input.replaceAll('\r', '');
    for (final rawLine in normalized.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final lineMatch = RegExp(
        r'^(\w+)\s*=\s*(.+)$',
        dotAll: true,
      ).firstMatch(line);
      if (lineMatch != null) {
        result[lineMatch.group(1)!] = _parseLooseArgValue(
          lineMatch.group(2)!.trim(),
        );
      }
    }

    if (result.isNotEmpty) {
      return result;
    }

    final pattern = RegExp(
      r'''(\w+)\s*=\s*("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\[[^\]]*\]|\{[^}]*\}|-?(?:\d+\.?\d*|\.\d+)|\w+)''',
    );
    for (final match in pattern.allMatches(normalized)) {
      final key = match.group(1);
      final rawValue = match.group(2);
      if (key == null || rawValue == null) continue;
      result[key] = _parseLooseArgValue(rawValue);
    }
    return result;
  }

  dynamic _parseLooseArgValue(String raw) {
    if ((raw.startsWith('"') && raw.endsWith('"')) ||
        (raw.startsWith("'") && raw.endsWith("'"))) {
      return raw
          .substring(1, raw.length - 1)
          .replaceAll(r'\"', '"')
          .replaceAll(r"\'", "'");
    }
    if (raw == 'True' || raw == 'true') return true;
    if (raw == 'False' || raw == 'false') return false;
    if (raw == 'None' || raw == 'null') return null;
    final asInt = int.tryParse(raw);
    if (asInt != null) return asInt;
    final asDouble = double.tryParse(raw);
    if (asDouble != null) return asDouble;
    if (raw.startsWith('[') && raw.endsWith(']')) {
      try {
        return jsonDecode(raw.replaceAll("'", '"'));
      } catch (_) {}
    }
    if (raw.startsWith('{') && raw.endsWith('}')) {
      try {
        return jsonDecode(_convertJsObjectToJson(raw));
      } catch (_) {}
    }
    return raw;
  }

  /// Extract balanced JSON from a string starting with '{'
  /// Handles nested braces, arrays, and strings properly
  String _extractBalancedJson(String text) {
    if (text.isEmpty || !text.startsWith('{')) return '';

    int braceCount = 0;
    bool inString = false;
    bool escaped = false;

    for (int i = 0; i < text.length; i++) {
      final char = text[i];

      if (escaped) {
        escaped = false;
        continue;
      }

      if (char == '\\') {
        escaped = true;
        continue;
      }

      if (char == '"') {
        inString = !inString;
        continue;
      }

      if (!inString) {
        if (char == '{') {
          braceCount++;
        } else if (char == '}') {
          braceCount--;
          if (braceCount == 0) {
            return text.substring(0, i + 1);
          }
        }
      }
    }

    return ''; // No balanced JSON found
  }

  /// Convert JavaScript object notation to valid JSON
  String _convertJsObjectToJson(String jsObject) {
    // Step 1: Replace unquoted property names with quoted ones
    // This regex finds property names (word characters) followed by a colon
    String result = jsObject.replaceAllMapped(
      RegExp(r'(\w+):'),
      (match) => '"${match.group(1)}":',
    );

    // Step 2: Quote unquoted string values
    // Match values that:
    // - Come after a colon and optional whitespace
    // - Are not already quoted
    // - Are not numbers, booleans, null, or start of array/object
    // - End at comma, closing bracket, or closing brace
    result = result.replaceAllMapped(
      RegExp(r':\s*([^"\[\]{},\s][^,\[\]{}]*?)(?=\s*[,\]\}])'),
      (match) {
        final value = match.group(1)!.trim();
        // Don't quote if it's a number, boolean, null, or already starts with quote
        if (value == 'true' ||
            value == 'false' ||
            value == 'null' ||
            double.tryParse(value) != null ||
            value.startsWith('"')) {
          return ': $value';
        }
        // Quote the string value
        return ': "$value"';
      },
    );

    // Step 3: Handle array elements that aren't quoted
    // Match array elements that are not numbers, booleans, null, or already quoted
    result = result.replaceAllMapped(
      RegExp(r'\[\s*([^"\[\]{},\s][^,\]\[{}]*?)(?=\s*[,\]])'),
      (match) {
        final value = match.group(1)!.trim();
        // Don't quote if it's a number, boolean, null, or already starts with quote
        if (value == 'true' ||
            value == 'false' ||
            value == 'null' ||
            double.tryParse(value) != null ||
            value.startsWith('"')) {
          return '[${match.group(0)!.substring(1)}';
        }
        // Quote the string value
        return '["$value"';
      },
    );

    // Step 4: Handle subsequent array elements
    result = result.replaceAllMapped(
      RegExp(r',\s*([^"\[\]{},\s][^,\]\[{}]*?)(?=\s*[,\]])'),
      (match) {
        final value = match.group(1)!.trim();
        // Don't quote if it's a number, boolean, null, or already starts with quote
        if (value == 'true' ||
            value == 'false' ||
            value == 'null' ||
            double.tryParse(value) != null ||
            value.startsWith('"')) {
          return ', $value';
        }
        // Quote the string value
        return ', "$value"';
      },
    );

    return result;
  }

  /// Map Gemini finish reason
  String _mapGeminiFinishReason(genai.FinishReason? reason) {
    try {
      switch (reason) {
        case genai.FinishReason.stop:
          return 'stop';
        case genai.FinishReason.maxTokens:
          return 'length';
        case genai.FinishReason.safety:
        case genai.FinishReason.recitation:
        case genai.FinishReason.blocklist:
        case genai.FinishReason.prohibitedContent:
        case genai.FinishReason.spii:
          return 'content_filter';
        case genai.FinishReason.malformedFunctionCall:
          return 'malformed_function_call';
        case genai.FinishReason.unspecified:
        case genai.FinishReason.other:
        case null:
        default:
          return 'stop';
      }
    } catch (e) {
      // Handle new/unrecognized finish reasons gracefully
      talker.warning(
        'Unrecognized finish reason: $reason, defaulting to "stop"',
      );
      return 'stop';
    }
  }

  /// Map ChatRole to Ollama MessageRole
  ollama.MessageRole _mapToOllamaRole(ChatRole role) {
    switch (role) {
      case ChatRole.user:
        return ollama.MessageRole.user;
      case ChatRole.assistant:
        return ollama.MessageRole.assistant;
      case ChatRole.system:
        return ollama.MessageRole.system;
      case ChatRole.tool:
        return ollama
            .MessageRole
            .tool; // Ollama v0.3+ supports the tool role natively
    }
  }

  /// Test connection to current LLM provider
  Future<bool> testConnection() async {
    try {
      final testMessages = [
        ChatMessage(
          id: 'test',
          content: 'Hello',
          role: ChatRole.user,
          timestamp: DateTime.now(),
        ),
      ];

      final response = await generateChatCompletion(
        messages: testMessages,
        maxTokens: 10,
      );

      return response.content.isNotEmpty;
    } catch (e) {
      talker.error('LLM connection test failed: $e');
      return false;
    }
  }

  /// Switch model for current provider
  Future<void> switchModel(String modelName) async {
    switch (_currentProvider) {
      case LLMProvider.gemini:
        if (_geminiApiKey != null) {
          await initializeGemini(apiKey: _geminiApiKey!, model: modelName);
        }
        break;
      case LLMProvider.openai:
        if (_openaiApiKey != null) {
          await initializeOpenAI(apiKey: _openaiApiKey!, model: modelName);
        }
        break;
      case LLMProvider.claude:
        if (_claudeApiKey != null) {
          await initializeClaude(apiKey: _claudeApiKey!, model: modelName);
        }
        break;
      case LLMProvider.ollama:
        if (_ollamaUrl != null) {
          await initializeOllama(
            baseUrl: _ollamaUrl!,
            model: modelName,
            apiKey: _ollamaApiKey,
            useNativeToolCall: _useNativeToolCall,
          );
        }
        break;
      case LLMProvider.openaiCompatible:
        if (_openaiCompatibleUrl != null) {
          await initializeOpenAICompatible(
            baseUrl: _openaiCompatibleUrl!,
            model: modelName,
          );
        }
        break;
      case LLMProvider.embedded:
        // Model selection for embedded is handled via EmbeddedLlmAdapter directly
        break;
      case LLMProvider.none:
        throw Exception('No LLM provider configured');
    }
  }

  /// Discover available Gemini models using the API
  Future<List<String>> discoverGeminiModels(String apiKey) async {
    try {
      // Gemini models with Flash as default
      return [
        'gemini-3-flash', // Gemini 3 flash model
        'gemini-3-pro', // Gemini 3 pro model
        'gemini-flash', // Primary flash model
        'gemini-2.5-pro', // Gemini 2.5 pro model
        'gemini-2.5-flash', // Gemini 2.5 flash model
        'gemini-2.5-flash-lite', // Lightweight flash model
      ];
    } catch (e) {
      talker.error('Model discovery failed: $e');
      return ['gemini-2.5-flash', 'gemini-2.5-flash-lite', 'gemini-1.5-flash'];
    }
  }

  /// Test Gemini API key validity with detailed feedback
  Future<Map<String, dynamic>> testGeminiApiKey(String apiKey) async {
    try {
      final testModel = genai.GoogleAIClient(
        config: genai.GoogleAIConfig.googleAI(
          authProvider: genai.ApiKeyProvider(apiKey),
        ),
      );

      final response = await testModel.models
          .generateContent(
            model: 'gemini-2.5-flash',
            request: genai.GenerateContentRequest(
              contents: [genai.Content.text('Hello')],
            ),
          )
          .timeout(const Duration(seconds: 8));

      if (response.text != null && response.text!.isNotEmpty) {
        return {
          'success': true,
          'message': 'API key is valid and working!',
          'model': 'gemini-2.5-flash',
        };
      } else {
        return {
          'success': false,
          'message': 'API key test returned empty response',
          'error': 'Empty response',
        };
      }
    } catch (e) {
      talker.error('API key test failed: $e');

      String errorMessage;
      if (e.toString().contains('API_KEY_INVALID') ||
          e.toString().contains('PERMISSION_DENIED') ||
          e.toString().contains('403') ||
          e.toString().contains('401')) {
        errorMessage =
            'Invalid API key. Check your Gemini API key from Google AI Studio.';
      } else if (e.toString().contains('quota') ||
          e.toString().contains('limit')) {
        errorMessage = 'API quota exceeded. Check your usage limits.';
      } else if (e.toString().contains('timeout')) {
        errorMessage = 'Request timed out. Check your internet connection.';
      } else {
        errorMessage = 'API test failed: ${e.toString()}';
      }

      return {'success': false, 'message': errorMessage, 'error': e.toString()};
    }
  }

  /// Get available models for current provider
  Future<List<String>> getAvailableModels() async {
    switch (_currentProvider) {
      case LLMProvider.gemini:
        return [
          'gemini-2.5-flash',
          'gemini-2.5-flash-lite',
          'gemini-2.5-pro',
          'gemini-3.0-pro',
        ];
      case LLMProvider.openai:
        return _defaultOpenAIModels;
      case LLMProvider.claude:
        return _defaultClaudeModels;
      case LLMProvider.ollama:
        if (_ollamaClient != null) {
          try {
            final response = await _ollamaClient!.models.list();
            final availableModels =
                response.models
                    ?.map((m) => m.model ?? '')
                    .where((name) => name.isNotEmpty)
                    .toList() ??
                [];
            // If we got models from the server, return them, otherwise return defaults
            return availableModels.isNotEmpty
                ? availableModels
                : _defaultOllamaModels;
          } catch (e) {
            talker.error('Failed to get Ollama models: $e');
            // Return default models on error
            return _defaultOllamaModels;
          }
        }
        // Return default models if client not initialized
        return _defaultOllamaModels;
      case LLMProvider.openaiCompatible:
        // Return OpenAI-compatible models (user can add custom models via Autocomplete)
        return _defaultOpenAICompatibleModels;
      case LLMProvider.embedded:
        return [];
      case LLMProvider.none:
        return [];
    }
  }

  /// Get available models for a specific provider (without needing to be configured)
  Future<List<String>> getAvailableModelsForProvider(
    LLMProvider provider,
  ) async {
    switch (provider) {
      case LLMProvider.gemini:
        return _defaultGeminiModels;
      case LLMProvider.openai:
        return _defaultOpenAIModels;
      case LLMProvider.claude:
        return _defaultClaudeModels;
      case LLMProvider.ollama:
        // Try to get models from server if we have a URL saved
        if (_ollamaUrl != null) {
          try {
            // Create headers with API key if available
            final headers = <String, String>{};
            if (_ollamaApiKey != null && _ollamaApiKey!.isNotEmpty) {
              headers['Authorization'] = 'Bearer $_ollamaApiKey';
            }

            var cleanedBaseUrl = _ollamaUrl!.trim().replaceAll(
              RegExp(r'/+$'),
              '',
            );
            if (cleanedBaseUrl.endsWith('/api')) {
              cleanedBaseUrl = cleanedBaseUrl
                  .substring(0, cleanedBaseUrl.length - 4)
                  .replaceAll(RegExp(r'/+$'), '');
            }
            final finalBaseUrl = cleanedBaseUrl.isNotEmpty
                ? cleanedBaseUrl
                : 'http://localhost:11434';

            final client = ollama.OllamaClient(
              config: ollama.OllamaConfig(
                baseUrl: finalBaseUrl,
                defaultHeaders: headers,
              ),
            );
            final response = await client.models.list();
            final availableModels =
                response.models
                    ?.map((m) => m.model ?? '')
                    .where((name) => name.isNotEmpty)
                    .toList() ??
                [];
            return availableModels.isNotEmpty
                ? availableModels
                : _defaultOllamaModels;
          } catch (e) {
            talker.error('Failed to get Ollama models: $e');
            return _defaultOllamaModels;
          }
        }
        return _defaultOllamaModels;
      case LLMProvider.openaiCompatible:
        // Return OpenAI-compatible default models (user can add custom models via Autocomplete)
        return _defaultOpenAICompatibleModels;
      case LLMProvider.embedded:
        return [];
      case LLMProvider.none:
        return [];
    }
  }

  /// Generate image using available AI services
  Future<LLMResponse> generateImage({
    required String prompt,
    String? style,
    String? size,
  }) async {
    try {
      // For now, we'll generate a response that suggests using MCP tools for image generation
      // In the future, this could integrate with image generation APIs like DALL-E, Midjourney, etc.

      final content =
          """I understand you want to generate an image with the prompt: "$prompt"
      
Currently, I don't have direct image generation capabilities, but I can help you in a few ways:

1. **Chart Generation**: If you want to create charts from data, I can use the measurement tools to get WSAgrar data and then help you create charts using web-based chart libraries.

2. **Image Generation Services**: You could integrate with services like:
   - OpenAI DALL-E API
   - Stability AI (Stable Diffusion)
   - Midjourney API
   - Google Imagen (when available)

3. **Data Visualization**: For WSAgrar data, I can help create charts using libraries like Chart.js, D3.js, or similar.

Would you like me to help you get some measurement data and create a chart instead?""";

      return LLMResponse(
        content: content,
        usage: const LLMUsage(
          promptTokens: 0,
          completionTokens: 0,
          totalTokens: 0,
        ),
        finishReason: 'stop',
      );
    } catch (e) {
      throw Exception('Image generation failed: $e');
    }
  }

  /// Generate chart from data (helper method)
  Future<String> generateChartHtml({
    required Map<String, dynamic> data,
    String chartType = 'line',
    String title = 'Data Chart',
  }) async {
    // Generate HTML with Chart.js for data visualization
    return '''
<!DOCTYPE html>
<html>
<head>
    <title>$title</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <style>
        body { font-family: Arial, sans-serif; padding: 20px; }
        #chartContainer { width: 800px; height: 400px; margin: 0 auto; }
    </style>
</head>
<body>
    <h2>$title</h2>
    <div id="chartContainer">
        <canvas id="dataChart"></canvas>
    </div>
    
    <script>
        const ctx = document.getElementById('dataChart').getContext('2d');
        const chart = new Chart(ctx, {
            type: '$chartType',
            data: ${jsonEncode(data)},
            options: {
                responsive: true,
                maintainAspectRatio: false,
                plugins: {
                    title: {
                        display: true,
                        text: '$title'
                    }
                },
                scales: {
                    y: {
                        beginAtZero: true
                    }
                }
            }
        });
    </script>
</body>
</html>''';
  }

  /// Build a simplified prompt without tool declarations for fallback scenarios
  String _buildSimplifiedPrompt(
    List<ChatMessage> messages,
    List<MCPTool>? availableTools,
  ) {
    final buffer = StringBuffer();

    // Add a simplified system context
    buffer.writeln(
      'You are a helpful AI assistant for WSAgrar agricultural data platform.',
    );

    if (availableTools != null && availableTools.isNotEmpty) {
      buffer.writeln('\nAvailable tools with their required parameters:');

      // Include parameter information for each tool
      for (final tool in availableTools) {
        buffer.writeln('\n## ${tool.name}');
        buffer.writeln('Description: ${tool.description ?? "No description"}');

        if (tool.inputSchema != null &&
            tool.inputSchema!['properties'] != null) {
          buffer.writeln('Parameters:');
          final properties = _safePropsMap(tool.inputSchema!['properties']);
          final required =
              (tool.inputSchema!['required'] as List<dynamic>?) ?? [];

          for (final entry in properties.entries) {
            final paramName = entry.key;
            final paramInfo = entry.value is Map
                ? Map<String, dynamic>.from(entry.value as Map)
                : <String, dynamic>{};
            final paramType = paramInfo['type'] ?? 'string';
            final isRequired = required.contains(paramName);

            buffer.writeln(
              '  - $paramName ($paramType)${isRequired ? ' [REQUIRED]' : ' [OPTIONAL]'}',
            );
          }
        }
      }

      buffer.writeln(
        '\nIMPORTANT: Use EXACT parameter names from the schema above!',
      );
      buffer.writeln('genai.Tool call format:');
      buffer.writeln('```json');
      buffer.writeln(
        '{"tool_call": {"name": "tool_name", "arguments": {"exact_param_name": "value"}}}',
      );
      buffer.writeln('```');
    }

    buffer.writeln();

    // Add the conversation context
    for (final message in messages) {
      if (message.role == ChatRole.user) {
        buffer.writeln('User: ${message.content}');
      } else if (message.role == ChatRole.assistant) {
        buffer.writeln('Assistant: ${message.content}');
      }
    }

    return buffer.toString();
  }

  /// Dispose of the service
  @override
  void dispose() {
    // Clean up resources if needed
    super.dispose();
  }
}

/// LLM Provider enumeration
enum LLMProvider {
  none,
  gemini,
  openai,
  claude,
  ollama,
  openaiCompatible,
  embedded,
}

/// LLM Response model
class LLMResponse {
  final String content;
  final List<LLMToolCall> toolCalls;
  final List<LLMImage>? images;
  final LLMUsage usage;
  final String finishReason;

  const LLMResponse({
    required this.content,
    this.toolCalls = const [],
    this.images,
    required this.usage,
    required this.finishReason,
  });
}

/// LLM Image model for generated images
class LLMImage {
  final String? url;
  final String? base64Data;
  final String? mimeType;
  final String? description;

  const LLMImage({this.url, this.base64Data, this.mimeType, this.description});
}

/// LLM genai.Tool Call model
class LLMToolCall {
  final String? id; // Optional ID for native API tool calls
  final String name;
  final Map<String, dynamic> arguments;

  const LLMToolCall({this.id, required this.name, required this.arguments});
}

/// LLM Usage statistics
class LLMUsage {
  final int promptTokens;
  final int completionTokens;
  final int totalTokens;

  const LLMUsage({
    required this.promptTokens,
    required this.completionTokens,
    required this.totalTokens,
  });
}

extension on LLMService {
  String? _extractCalledToolName(String content) {
    final match = RegExp(
      r'Called tool:\s*([^\n]+)',
      caseSensitive: false,
    ).firstMatch(content);
    return match?.group(1)?.trim();
  }

  String? _tryBuildCompactFileListSummary(MCPToolResult toolResult) {
    for (final content in toolResult.content) {
      final raw = content.text?.trim();
      if (raw == null || raw.isEmpty) continue;

      try {
        final decoded = jsonDecode(raw);
        List<dynamic>? items;
        String listKind = 'items';

        if (decoded is Map<String, dynamic>) {
          if (decoded['files'] is List) {
            items = decoded['files'] as List<dynamic>;
            listKind = 'Google Drive files';
          } else if (decoded['documents'] is List) {
            items = decoded['documents'] as List<dynamic>;
            listKind = 'documents';
          } else if (decoded['results'] is List) {
            items = decoded['results'] as List<dynamic>;
            listKind = 'files';
          }
        } else if (decoded is List) {
          items = decoded;
          listKind = 'files';
        }

        if (items == null || items.isEmpty) continue;

        final names = <String>[];
        for (final item in items.take(8)) {
          if (item is Map<String, dynamic>) {
            final name =
                (item['name'] ??
                        item['fileName'] ??
                        item['filePath'] ??
                        item['path'] ??
                        '')
                    .toString()
                    .trim();
            if (name.isNotEmpty) {
              names.add(name.split(RegExp(r'[\\/]')).last);
            }
          } else {
            final rawName = item.toString().trim();
            if (rawName.isNotEmpty) {
              names.add(rawName.split(RegExp(r'[\\/]')).last);
            }
          }
        }

        if (names.isEmpty) continue;

        final count = items.length;
        final preview = names.join(', ');
        final more = count > names.length
            ? ' (+${count - names.length} more)'
            : '';
        return 'genai.Tool returned a $listKind list with $count entries. Filenames: $preview$more';
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  String _truncateLargeToolResults(ChatMessage message) {
    // Only process tool messages with results
    if (message.role != ChatRole.tool || message.toolResult == null) {
      return message.content;
    }

    final calledToolName = _extractCalledToolName(
      message.content,
    )?.toLowerCase();

    // For file-list style tools, always pass only compact summary to the LLM
    final compactListSummary = _tryBuildCompactFileListSummary(
      message.toolResult!,
    );
    if (compactListSummary != null) {
      talker.info('📦 Using compact file-list summary for LLM context');
      return compactListSummary;
    }

    // For file generation/download tools, never forward binary payload details
    if (calledToolName == 'download_file' ||
        calledToolName == 'read_drive_file') {
      return 'genai.Tool executed successfully. A downloadable file is available in the tool result UI. Do not re-list full content.';
    }

    // Do not return message.content here.
    // message.content is often only metadata like "Called tool: ... Arguments: ..."
    // and may omit the actual tool output text (e.g. command stdout).
    // Always build context from toolResult.content text items below so the model
    // can detect that the tool already completed and use its result.

    // Build filtered content: include text, exclude images and binary data
    final buffer = StringBuffer();
    bool hasTextContent = false;

    for (final content in message.toolResult!.content) {
      final mimeType = content.mimeType?.toLowerCase() ?? '';

      // Skip explicit image content items
      final isImage =
          content.type == 'image' ||
          (content.data != null && mimeType.startsWith('image/'));
      if (isImage) continue;

      // Skip any content that carries a binary data field (covers Excel, PDF, etc.)
      if (content.data != null && content.data!.isNotEmpty) continue;

      // Skip content whose mimeType indicates binary/office formats
      final isBinaryMime =
          mimeType.isNotEmpty &&
          (mimeType.startsWith('application/vnd.') ||
              mimeType.startsWith('application/octet-stream') ||
              mimeType.startsWith('application/zip') ||
              mimeType.startsWith('application/x-') ||
              mimeType.contains('spreadsheet') ||
              mimeType.contains('officedocument') ||
              mimeType.contains('pdf'));
      if (isBinaryMime) continue;

      // Include text content (with filtering and CSV truncation for LLM)
      if (content.text != null && content.text!.trim().isNotEmpty) {
        String textToAdd = content.text!.trim();

        // Skip text that contains embedded image data URIs (data:image/...)
        if (textToAdd.startsWith('data:image/') ||
            textToAdd.contains('\ndata:image/')) {
          talker.info('🖼️ Skipping text content with embedded data URI image');
          continue;
        }

        // Skip text that is a raw base64 blob (long, no whitespace, base64 alphabet)
        if (LLMService._looksLikeBase64Blob(textToAdd)) {
          talker.info(
            '🖼️ Skipping text content that looks like a base64 blob (${textToAdd.length} chars)',
          );
          continue;
        }

        // Skip markdown image syntax wrapping a data URI: ![...](data:image/...)
        if (RegExp(
          r'!\[.*?\]\(data:image/',
          dotAll: true,
        ).hasMatch(textToAdd)) {
          talker.info('🖼️ Skipping markdown image with embedded data URI');
          continue;
        }

        // Strip embedded base64 from JSON wrappers, e.g.:
        // {"success": true, "data": {"content": "<base64>", "fileName": "report.xlsx"}}
        if (textToAdd.startsWith('{')) {
          try {
            final json = jsonDecode(textToAdd);
            if (json is Map) {
              final data = json['data'];
              if (data is Map) {
                final content = data['content'];
                if (content is String &&
                    LLMService._looksLikeBase64Blob(content)) {
                  // Replace binary content with a human-readable summary
                  final summary = <String, dynamic>{
                    if (json['success'] != null) 'success': json['success'],
                    'message': 'File generated and available in the UI.',
                    if (data['fileName'] != null) 'fileName': data['fileName'],
                    if (data['mimeType'] != null) 'mimeType': data['mimeType'],
                    if (data['size'] != null) 'size': data['size'],
                  };
                  textToAdd = jsonEncode(summary);
                  talker.info(
                    '📊 Stripped base64 from JSON file response, replaced with summary',
                  );
                }
              }
            }
          } catch (_) {
            // Not JSON — keep as-is
          }
        }

        if (hasTextContent) {
          buffer.writeln();
        }

        // Check if this looks like CSV data (contains "date" or multiple commas in first line)
        final firstLine = textToAdd.split('\n').first.toLowerCase();
        final looksLikeCSV =
            firstLine.contains('date') || firstLine.split(',').length > 3;

        // Truncate CSV data to first 10 lines for LLM (full data still visible in UI)
        if (looksLikeCSV && textToAdd.split('\n').length > 12) {
          final lines = textToAdd.split('\n');
          final truncatedLines = lines.take(12).toList();
          truncatedLines.add(
            '... [${lines.length - 12} more rows omitted from LLM context - full data visible in UI]',
          );
          textToAdd = truncatedLines.join('\n');
          talker.info(
            '📊 Truncated CSV data for LLM: ${lines.length} rows → 12 rows preview',
          );
        }

        buffer.write(textToAdd);
        hasTextContent = true;
      }
    }

    // If we have text content after filtering, return it
    if (hasTextContent) {
      return buffer.toString();
    }

    // If only images/binary data (no text), return a placeholder
    return '[genai.Tool produced image/binary output. The result is visible in the UI. '
        'Do not describe, reproduce, or reference any binary/base64 data — '
        'just confirm the output was created.]';
  }
}
