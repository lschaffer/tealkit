import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;
import 'package:http/http.dart' as http;
import 'package:googleai_dart/googleai_dart.dart' as genai;
import 'package:openai_dart/openai_dart.dart' as openai;
import 'package:ollama_dart/ollama_dart.dart' as ollama;
import 'package:path/path.dart' as p;

import '../models/agentic_task.dart';
import '../models/mcp_models.dart';
import '../services/server_llm_settings_service.dart';
import '../utils/server_logger.dart';
import '../utils/server_paths.dart';
import '../utils/server_live_log.dart';
import 'server_embedded_llm_adapter.dart';
import 'server_tool_registry.dart';

// ═══════════════════════════════════════════════════════════════
// Data types
// ═══════════════════════════════════════════════════════════════

enum LlmChatRole { system, human, ai, tool }

class LlmChatMessage {
  final LlmChatRole role;
  final String content;

  /// For AI messages: the tool calls requested (if any).
  final List<LlmToolCall> toolCalls;

  /// For tool result messages: the tool call ID they reply to.
  final String? toolCallId;

  const LlmChatMessage({
    required this.role,
    required this.content,
    this.toolCalls = const [],
    this.toolCallId,
  });

  factory LlmChatMessage.system(String content) =>
      LlmChatMessage(role: LlmChatRole.system, content: content);

  factory LlmChatMessage.human(String content) =>
      LlmChatMessage(role: LlmChatRole.human, content: content);

  factory LlmChatMessage.ai(
    String content, {
    List<LlmToolCall> toolCalls = const [],
  }) => LlmChatMessage(
    role: LlmChatRole.ai,
    content: content,
    toolCalls: toolCalls,
  );

  factory LlmChatMessage.toolResult({
    required String toolCallId,
    required String content,
  }) => LlmChatMessage(
    role: LlmChatRole.tool,
    content: content,
    toolCallId: toolCallId,
  );
}

class LlmToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;

  LlmToolCall({String? id, required this.name, required this.arguments})
    : id = (id != null && id.isNotEmpty)
          ? id
          : 'call_${name}_${jsonEncode(arguments).hashCode.toRadixString(16)}';
}

class LlmRunResult {
  final String content;
  final bool success;
  final String? error;
  final int promptTokens;
  final int completionTokens;
  final int toolCallCount;
  final int? messageCount;
  final int? sentChars;

  /// Raw concatenated tool outputs from this run (used for $$@@$$ chain injection).
  final String? rawToolOutput;

  /// Detailed formatted execution log snippet for this step
  final String? executionLogSnippet;

  const LlmRunResult({
    required this.content,
    required this.success,
    this.error,
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.toolCallCount = 0,
    this.messageCount,
    this.sentChars,
    this.rawToolOutput,
    this.executionLogSnippet,
  });
}

// ═══════════════════════════════════════════════════════════════
// Mistral HTTP interceptor (ported from UI llm_service.dart)
// ─────────────────────────────────────────────────────────────────────────────
// Mistral's API rejects OpenAI-specific fields (e.g. parallel_tool_calls) and
// omits "type":"function" from tool_calls in responses. This interceptor:
//  1. Strips forbidden OpenAI-only fields from outgoing requests.
//  2. Fixes orphaned tool-result messages (adds a fake assistant message when
//     a tool result has no matching preceding assistant tool_call).
//  3. Injects the missing "type":"function" into tool_calls in responses.
// ─────────────────────────────────────────────────────────────────────────────
class _MistralPatchClient extends http.BaseClient {
  _MistralPatchClient(this._inner);
  final http.Client _inner;

  // Fields that are valid for OpenAI but forbidden by Mistral.
  static const _forbiddenRequestFields = {
    'parallel_tool_calls',
    'stream_options',
    'logprobs',
    'top_logprobs',
    'logit_bias',
  };

  String _toolCallId(int messageIndex, int toolIndex) =>
      'mistral_tool_${messageIndex}_$toolIndex';

  List<Map<String, dynamic>> _normalizeToolCalls(
    List toolCalls, {
    required int messageIndex,
    List<Map<String, dynamic>>? followingTools,
  }) {
    final normalized = <Map<String, dynamic>>[];
    for (int i = 0; i < toolCalls.length; i++) {
      final raw = toolCalls[i];
      if (raw is! Map) continue;
      final toolCall = Map<String, dynamic>.from(raw);
      final existingId = (toolCall['id'] ?? '').toString().trim();
      final inferredId = (followingTools != null && i < followingTools.length)
          ? (followingTools[i]['tool_call_id'] ?? '').toString().trim()
          : '';
      toolCall['id'] = existingId.isNotEmpty
          ? existingId
          : (inferredId.isNotEmpty ? inferredId : _toolCallId(messageIndex, i));
      toolCall['type'] = 'function';
      normalized.add(toolCall);
    }
    return normalized;
  }

  Map<String, dynamic> _patchRequest(Map<String, dynamic> payload) {
    // Strip OpenAI-only top-level fields.
    payload.removeWhere((k, _) => _forbiddenRequestFields.contains(k));

    // OpenAI SDK ≥1.x renames max_tokens → max_completion_tokens (o-series models).
    // Mistral forbids max_completion_tokens; remap it back to max_tokens.
    if (payload.containsKey('max_completion_tokens') &&
        !payload.containsKey('max_tokens')) {
      payload['max_tokens'] = payload.remove('max_completion_tokens');
    } else {
      payload.remove('max_completion_tokens');
    }

    // Fix orphaned tool-result messages: Mistral requires every tool message
    // to be immediately preceded by an assistant message that contains a
    // matching tool_call. If that is missing, insert a synthetic one.
    final rawMessages = payload['messages'];
    if (rawMessages is! List) return payload;

    final sanitized = <dynamic>[];
    bool changed = false;

    for (int index = 0; index < rawMessages.length; index++) {
      final item = rawMessages[index];
      if (item is! Map) {
        sanitized.add(item);
        continue;
      }
      final msg = Map<String, dynamic>.from(item);
      final role = (msg['role'] ?? '').toString();

      if (role == 'assistant') {
        final rawToolCalls = msg['tool_calls'];
        if (rawToolCalls is List && rawToolCalls.isNotEmpty) {
          final followingTools = <Map<String, dynamic>>[];
          int lookahead = index + 1;
          while (lookahead < rawMessages.length) {
            final next = rawMessages[lookahead];
            if (next is! Map) break;
            final nextMap = Map<String, dynamic>.from(next);
            if ((nextMap['role'] ?? '').toString() != 'tool') break;
            followingTools.add(nextMap);
            lookahead++;
          }

          final normalizedToolCalls = _normalizeToolCalls(
            rawToolCalls,
            messageIndex: index,
            followingTools: followingTools,
          );
          if (normalizedToolCalls.isNotEmpty) {
            msg['tool_calls'] = normalizedToolCalls;
            if (normalizedToolCalls.length != (rawToolCalls).length) {
              changed = true;
            } else {
              for (int i = 0; i < normalizedToolCalls.length; i++) {
                final before = rawToolCalls[i] is Map
                    ? Map<String, dynamic>.from(rawToolCalls[i] as Map)
                    : <String, dynamic>{};
                final after = normalizedToolCalls[i];
                if ((before['id'] ?? '').toString().trim() != after['id'] ||
                    before['type'] != after['type']) {
                  changed = true;
                  break;
                }
              }
            }
          }

          if (normalizedToolCalls.length > 1 && followingTools.isNotEmpty) {
            final emittedToolIds = <String>{};
            for (final toolCall in normalizedToolCalls) {
              final toolCallId = (toolCall['id'] ?? '').toString().trim();
              sanitized.add({
                'role': 'assistant',
                'content': null,
                'tool_calls': [toolCall],
              });
              final matchingTool = followingTools
                  .cast<Map<String, dynamic>?>()
                  .firstWhere(
                    (tool) =>
                        tool != null &&
                        (tool['tool_call_id'] ?? '').toString().trim() ==
                            toolCallId,
                    orElse: () => null,
                  );
              if (matchingTool != null) {
                sanitized.add(matchingTool);
                emittedToolIds.add(toolCallId);
              }
            }
            for (final tool in followingTools) {
              final toolCallId = (tool['tool_call_id'] ?? '').toString().trim();
              if (!emittedToolIds.contains(toolCallId)) {
                sanitized.add(tool);
              }
            }
            changed = true;
            index += followingTools.length;
            continue;
          }
        }
      }

      if (role == 'tool') {
        final toolCallId = (msg['tool_call_id'] ?? '').toString().trim();
        final prev = sanitized.isNotEmpty && sanitized.last is Map
            ? Map<String, dynamic>.from(sanitized.last as Map)
            : null;
        bool hasMatch = false;
        if (prev != null && prev['role']?.toString() == 'assistant') {
          final tcs = prev['tool_calls'];
          if (tcs is List) {
            hasMatch = tcs.any((tc) {
              if (tc is! Map) return false;
              return (Map<String, dynamic>.from(tc)['id'] ?? '')
                      .toString()
                      .trim() ==
                  toolCallId;
            });
          }
        }
        if (!hasMatch && toolCallId.isNotEmpty) {
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
    if (changed) payload['messages'] = sanitized;
    return payload;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    http.BaseRequest outgoing = request;

    if (request.method.toUpperCase() == 'POST' &&
        request.url.path.contains('chat/completions')) {
      String? rawBody;
      try {
        if (request is http.Request) {
          rawBody = request.body;
        } else {
          final rawBytes = await request.finalize().toBytes();
          rawBody = utf8.decode(rawBytes);
        }

        final decoded = jsonDecode(rawBody);
        if (decoded is Map<String, dynamic>) {
          final patched = _patchRequest(decoded);
          outgoing = http.Request(request.method, request.url)
            ..headers.addAll(request.headers)
            ..body = jsonEncode(patched);
        } else {
          outgoing = http.Request(request.method, request.url)
            ..headers.addAll(request.headers)
            ..body = rawBody;
        }
      } catch (_) {
        if (request is! http.Request && rawBody != null) {
          // For streamed requests, preserve original body if patching fails.
          outgoing = http.Request(request.method, request.url)
            ..headers.addAll(request.headers)
            ..body = rawBody;
        }
      }
    }

    final streamed = await _inner.send(outgoing);
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
      final decoded = jsonDecode(bodyStr);
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

            final tcs = msg['tool_calls'];
            if (tcs is! List) continue;
            for (final tc in tcs) {
              if (tc is Map<String, dynamic> && !tc.containsKey('type')) {
                tc['type'] = 'function';
                changed = true;
              }
            }
          }
        }
        if (changed) patched = jsonEncode(decoded);
      }
    } catch (_) {}

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

// ═══════════════════════════════════════════════════════════════
// Helper functions for text-based tool parsing & argument coercion
// ═══════════════════════════════════════════════════════════════

String _extractBalancedJson(String input, int startIndex) {
  if (startIndex < 0 ||
      startIndex >= input.length ||
      input[startIndex] != '{') {
    return '';
  }

  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var i = startIndex; i < input.length; i++) {
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
      if (depth == 0) {
        return input.substring(startIndex, i + 1);
      }
    }
  }
  return '';
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
      return jsonDecode(
        raw.replaceAllMapped(
          RegExp(r'([{,]\s*)([A-Za-z_][A-Za-z0-9_]*)(\s*:)'),
          (m) => '${m.group(1)}"${m.group(2)}"${m.group(3)}',
        ),
      );
    } catch (_) {}
  }
  return raw;
}

List<LlmToolCall> _extractTextToolCalls(String content) {
  final out = <LlmToolCall>[];
  if (content.trim().isEmpty) return out;

  // Try to extract XML-style tool calls first: <tool_call>...</tool_call>
  final xmlToolCallPattern = RegExp(
    r'<tool_call>\s*(.*?)\s*</tool_call>',
    dotAll: true,
    caseSensitive: false,
  );
  final xmlMatches = xmlToolCallPattern.allMatches(content);
  for (final match in xmlMatches) {
    try {
      final jsonStr = match.group(1)?.trim() ?? '';
      if (jsonStr.isNotEmpty) {
        final decoded = jsonDecode(jsonStr);
        if (decoded is Map<String, dynamic>) {
          final inner = decoded['tool_call'] is Map<String, dynamic>
              ? decoded['tool_call'] as Map<String, dynamic>
              : decoded;
          final toolName = inner['name'] as String?;
          final arguments =
              (inner['arguments'] ?? inner['parameters'])
                  as Map<String, dynamic>?;
          final id = inner['id']?.toString();
          if (toolName != null && toolName.isNotEmpty && arguments != null) {
            out.add(LlmToolCall(id: id, name: toolName, arguments: arguments));
          }
        }
      }
    } catch (_) {}
  }
  if (out.isNotEmpty) return out;

  final multilineJsonPattern = RegExp(
    r'tool[_ ]?call\s*:?\s*\n\s*([a-zA-Z0-9_]+)\s*\n\s*(\{)',
    caseSensitive: false,
    multiLine: true,
  );
  for (final match in multilineJsonPattern.allMatches(content)) {
    try {
      final name = match.group(1)?.trim();
      if (name == null || name.isEmpty) continue;
      final jsonStart = match.end - 1;
      final jsonStr = _extractBalancedJson(content, jsonStart);
      if (jsonStr.isEmpty) continue;
      final parsed = jsonDecode(jsonStr);
      if (parsed is Map<String, dynamic>) {
        out.add(LlmToolCall(name: name, arguments: parsed));
        return out;
      }
    } catch (_) {}
  }

  final multilineParamsPattern = RegExp(
    r'tool[_ ]?call\s*:?\s*\n\s*([a-zA-Z0-9_]+)\s*\n\s*parameters\s*:?\s*(.*?)(?=\n\n|\Z)',
    caseSensitive: false,
    dotAll: true,
    multiLine: true,
  );
  for (final match in multilineParamsPattern.allMatches(content)) {
    final name = match.group(1)?.trim();
    final rawArgs = match.group(2);
    if (name == null || name.isEmpty || rawArgs == null) continue;
    final arguments = _parseLooseKeyValueArgs(rawArgs);
    if (arguments.isNotEmpty) {
      out.add(LlmToolCall(name: name, arguments: arguments));
      return out;
    }
  }

  final inlineParamsPattern = RegExp(
    r'tool[_ ]?call\s*:?\s*([a-zA-Z0-9_]+)\s*\n\s*parameters\s*:?\s*(.*?)(?=\n\n|\Z)',
    caseSensitive: false,
    dotAll: true,
    multiLine: true,
  );
  for (final match in inlineParamsPattern.allMatches(content)) {
    final name = match.group(1)?.trim();
    final rawArgs = match.group(2);
    if (name == null || name.isEmpty || rawArgs == null) continue;
    final arguments = _parseLooseKeyValueArgs(rawArgs);
    if (arguments.isNotEmpty) {
      out.add(LlmToolCall(name: name, arguments: arguments));
      return out;
    }
  }

  final inlineArgsPattern = RegExp(
    r'tool[_ ]?call\s*:?\s*([a-zA-Z0-9_]+)\s*\n\s*arguments\s*:?\s*(.*?)(?=\n\n|\Z)',
    caseSensitive: false,
    dotAll: true,
    multiLine: true,
  );
  for (final match in inlineArgsPattern.allMatches(content)) {
    final name = match.group(1)?.trim();
    final rawArgs = match.group(2);
    if (name == null || name.isEmpty || rawArgs == null) continue;
    final arguments = _parseLooseKeyValueArgs(rawArgs);
    if (arguments.isNotEmpty) {
      out.add(LlmToolCall(name: name, arguments: arguments));
      return out;
    }
  }

  // Search for raw JSON tool calls anywhere in the text content
  final toolCallPattern = RegExp(r'"tool_call"|"name"\s*:', multiLine: true);
  final matches = toolCallPattern.allMatches(content);
  for (final match in matches) {
    try {
      int searchStart = match.start;
      int? openBracePos;

      for (int i = searchStart - 1; i >= 0; i--) {
        if (content[i] == '{') {
          openBracePos = i;
          break;
        }
        if (content[i] == '}') {
          break;
        }
      }

      if (openBracePos == null) continue;

      final jsonStr = _extractBalancedJson(content, openBracePos);
      if (jsonStr.isNotEmpty) {
        final decoded = jsonDecode(jsonStr);
        if (decoded is Map<String, dynamic>) {
          final inner = decoded['tool_call'] is Map<String, dynamic>
              ? decoded['tool_call'] as Map<String, dynamic>
              : decoded;
          final toolName = inner['name'] as String?;
          final arguments =
              (inner['arguments'] ?? inner['parameters'])
                  as Map<String, dynamic>?;
          final id = inner['id']?.toString();
          if (toolName != null && toolName.isNotEmpty && arguments != null) {
            final isDuplicate = out.any(
              (tc) =>
                  tc.name == toolName &&
                  jsonEncode(tc.arguments) == jsonEncode(arguments),
            );
            if (!isDuplicate) {
              out.add(
                LlmToolCall(id: id, name: toolName, arguments: arguments),
              );
            }
          }
        }
      }
    } catch (_) {}
  }

  return out;
}

MCPTool? _findToolByName(List<MCPTool> tools, String name) {
  for (final tool in tools) {
    if (tool.name == name) {
      return tool;
    }
  }
  return null;
}

Map<String, dynamic> _coerceArgumentsToSchema(
  Map<String, dynamic> arguments,
  MCPTool? tool,
) {
  final inputSchema = tool?.inputSchema;
  final rawProps = inputSchema?['properties'];
  if (inputSchema == null || rawProps == null) {
    return arguments;
  }

  final properties = rawProps is Map<String, dynamic>
      ? rawProps
      : Map<String, dynamic>.from(rawProps as Map);
  Map<String, dynamic>? patched;

  for (final entry in arguments.entries) {
    final schema = properties[entry.key];
    if (schema is! Map) {
      continue;
    }

    final coerced = _coerceValueForSchema(
      entry.value,
      Map<String, dynamic>.from(schema),
    );
    if (coerced != entry.value) {
      patched ??= Map<String, dynamic>.from(arguments);
      patched[entry.key] = coerced;
    }
  }

  return patched ?? arguments;
}

dynamic _coerceValueForSchema(dynamic value, Map<String, dynamic> schema) {
  if (value == null) {
    return null;
  }

  final type = _primarySchemaType(schema);
  if (type == null) {
    return value;
  }

  switch (type) {
    case 'object':
      if (value is Map<String, dynamic>) {
        return value;
      }
      if (value is Map) {
        return Map<String, dynamic>.from(value);
      }
      if (value is String) {
        final trimmed = value.trim();
        if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
          try {
            final decoded = jsonDecode(trimmed);
            if (decoded is Map) {
              return Map<String, dynamic>.from(decoded);
            }
          } catch (_) {}
        }
      }
      return value;
    case 'array':
      List<dynamic>? items;
      if (value is List<dynamic>) {
        items = List<dynamic>.from(value);
      } else if (value is List) {
        items = List<dynamic>.from(value);
      } else if (value is String) {
        final trimmed = value.trim();
        if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
          try {
            final decoded = jsonDecode(trimmed);
            if (decoded is List) {
              items = List<dynamic>.from(decoded);
            }
          } catch (_) {}
        }
        items ??= _splitLooseArrayString(trimmed);
      }

      if (items == null) {
        return value;
      }

      final itemSchemaRaw = schema['items'];
      if (itemSchemaRaw is Map) {
        final itemSchema = Map<String, dynamic>.from(itemSchemaRaw);
        return items
            .map((item) => _coerceValueForSchema(item, itemSchema))
            .toList();
      }
      return items;
    case 'integer':
      if (value is int) return value;
      if (value is num) return value.toInt() == value ? value.toInt() : value;
      if (value is String) return int.tryParse(value.trim()) ?? value;
      return value;
    case 'number':
      if (value is num) return value;
      if (value is String) return num.tryParse(value.trim()) ?? value;
      return value;
    case 'boolean':
      if (value is bool) return value;
      if (value is num) {
        if (value == 1) return true;
        if (value == 0) return false;
      }
      if (value is String) {
        switch (value.trim().toLowerCase()) {
          case 'true':
          case 'yes':
          case '1':
          case 'on':
            return true;
          case 'false':
          case 'no':
          case '0':
          case 'off':
            return false;
        }
      }
      return value;
    case 'string':
      return value is String ? value : value.toString();
    default:
      return value;
  }
}

String? _primarySchemaType(Map<String, dynamic> schema) {
  final rawType = schema['type'];
  if (rawType is String && rawType.isNotEmpty) {
    return rawType;
  }
  if (rawType is List) {
    for (final entry in rawType) {
      if (entry is String && entry != 'null' && entry.isNotEmpty) {
        return entry;
      }
    }
  }
  if (schema['properties'] is Map) {
    return 'object';
  }
  if (schema['items'] is Map) {
    return 'array';
  }
  return null;
}

List<dynamic> _splitLooseArrayString(String input) {
  if (input.isEmpty) {
    return <dynamic>[];
  }

  final parts = input
      .split(RegExp(r'\s*(?:,|\||;|\n)\s*'))
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList();

  if (parts.length <= 1) {
    return <dynamic>[input];
  }

  return parts;
}

// ═══════════════════════════════════════════════════════════════
// Server LLM Runner
// ═══════════════════════════════════════════════════════════════

class ServerLlmRunner {
  static const int _maxToolIterations = 15;
  static const Duration _embeddedQueueTimeout = Duration(minutes: 3);
  static const Duration _embeddedLoadTimeout = Duration(minutes: 2);
  static const Duration _embeddedGenerationTimeout = Duration(minutes: 5);
  static const Duration _embeddedToolCallTimeout = Duration(minutes: 2);
  static final RegExp _markdownBase64DataUriPattern = RegExp(
    r'\[([^\]]+)\]\(\s*data:[^;\s\)]+;base64,([A-Za-z0-9+/=\s\r\n]{80,})\s*\)',
    caseSensitive: false,
    dotAll: true,
  );
  static final RegExp _base64DataUriPattern = RegExp(
    r'data:[^;\s]+;base64,\s*[A-Za-z0-9+/=\s\r\n]{80,}',
    caseSensitive: false,
    dotAll: true,
  );

  final ServerLlmSettingsService _settings;
  final String? taskId;
  final String? stepName;

  ServerLlmRunner(this._settings, {this.taskId, this.stepName});

  void _liveLog(String message) {
    if (taskId != null) {
      final prefix = stepName != null ? '[$stepName] ' : '';
      ServerLiveLog.log(taskId!, '$prefix$message');
    }
  }

  // ── Public entry point ──────────────────────────────────────

  Future<LlmRunResult> run({
    required String systemPrompt,
    required String userPrompt,
    required ServerToolRegistry registry,
    bool usePrimary = true,
    TaskLlmConfig? taskLlmConfig,
    bool stopAfterToolCall = false,
    Directory? outputDir,
    List<MCPTool>? toolsOverride,
  }) async {
    LlmProvider provider;
    String model;
    String apiKey;
    String baseUrl;
    double temperature;
    int? maxTokens;
    int? topK;
    double? topP;
    double? repeatPenalty;
    bool thinking;

    if (taskLlmConfig != null) {
      provider = LlmProvider.values.firstWhere(
        (p) =>
            p.name == taskLlmConfig.provider ||
            p.configKey == taskLlmConfig.provider,
        orElse: () => usePrimary ? _settings.provider : _settings.provider2,
      );
      model = taskLlmConfig.model;
      final configuredApiKey = taskLlmConfig.apiKey?.trim() ?? '';
      final configuredBaseUrl = taskLlmConfig.baseUrl?.trim() ?? '';
      apiKey = configuredApiKey.isNotEmpty
          ? configuredApiKey
          : (usePrimary ? _settings.apiKey : _settings.apiKey2);
      baseUrl = configuredBaseUrl.isNotEmpty
          ? configuredBaseUrl
          : (usePrimary ? _settings.baseUrl : _settings.baseUrl2);
      temperature = taskLlmConfig.temperature;
      maxTokens = taskLlmConfig.maxTokens;
      topK =
          (taskLlmConfig.extraParams['top_k'] as num?)?.toInt() ??
          (usePrimary ? _settings.topK : _settings.topK2);
      topP =
          (taskLlmConfig.extraParams['top_p'] as num?)?.toDouble() ??
          (usePrimary ? _settings.topP : _settings.topP2);
      repeatPenalty =
          (taskLlmConfig.extraParams['repeat_penalty'] as num?)?.toDouble() ??
          (usePrimary ? _settings.repeatPenalty : _settings.repeatPenalty2);
      thinking =
          (taskLlmConfig.extraParams['thinking'] as bool?) ??
          (usePrimary ? _settings.thinking : _settings.thinking2);
    } else {
      provider = usePrimary ? _settings.provider : _settings.provider2;
      model = usePrimary ? _settings.model : _settings.model2;
      apiKey = usePrimary ? _settings.apiKey : _settings.apiKey2;
      baseUrl = usePrimary ? _settings.baseUrl : _settings.baseUrl2;
      temperature = usePrimary ? _settings.temperature : _settings.temperature2;
      maxTokens = usePrimary ? _settings.maxTokens : _settings.maxTokens2;
      topK = usePrimary ? _settings.topK : _settings.topK2;
      topP = usePrimary ? _settings.topP : _settings.topP2;
      repeatPenalty = usePrimary
          ? _settings.repeatPenalty
          : _settings.repeatPenalty2;
      thinking = usePrimary ? _settings.thinking : _settings.thinking2;
    }

    log.info(
      '[LlmRunner] TaskConfig: ${taskLlmConfig != null ? "provider=${taskLlmConfig.provider} model=${taskLlmConfig.model} baseUrl=${taskLlmConfig.baseUrl}" : "null"}',
    );
    log.info(
      '[LlmRunner] resolved: provider=${provider.configKey} model=$model baseUrl="$baseUrl" hasApiKey=${apiKey.isNotEmpty}',
    );
    log.info('[LlmRunner] Provider=${provider.label} Model=$model');
    _liveLog(
      'Starting execution flow using provider: ${provider.label}, model: $model',
    );
    _liveLog('System Prompt: $systemPrompt');
    _liveLog('User Prompt: $userPrompt');

    if (provider == LlmProvider.none || model.isEmpty) {
      return const LlmRunResult(
        content: '',
        success: false,
        error: 'No LLM configured. Set up a provider in settings.',
      );
    }

    try {
      if (provider == LlmProvider.claude) {
        return await _runWithClaude(
          apiKey: apiKey,
          model: model,
          systemPrompt: systemPrompt,
          userPrompt: userPrompt,
          temperature: temperature,
          maxTokens: maxTokens,
        );
      }

      if (provider == LlmProvider.embedded) {
        return await _runWithEmbedded(
          model: model,
          systemPrompt: systemPrompt,
          userPrompt: userPrompt,
          temperature: temperature,
          maxTokens: maxTokens,
          topK: topK,
          topP: topP,
          repeatPenalty: repeatPenalty,
          registry: registry,
          toolsOverride: toolsOverride,
          stopAfterToolCall: stopAfterToolCall,
          outputDir: outputDir,
        );
      }

      // All other providers: Native path.
      return await _runWithNative(
        provider: provider,
        model: model,
        apiKey: apiKey,
        baseUrl: baseUrl,
        temperature: temperature,
        maxTokens: maxTokens,
        systemPrompt: systemPrompt,
        userPrompt: userPrompt,
        registry: registry,
        toolsOverride: toolsOverride,
        thinking: thinking,
        stopAfterToolCall: stopAfterToolCall,
        outputDir: outputDir,
      );
    } on Exception catch (e) {
      final msg = e.toString();
      final isRateLimit =
          msg.contains('429') || msg.contains('rate') || msg.contains('quota');
      final isUnavailable =
          msg.contains('503') ||
          msg.contains('overloaded') ||
          msg.contains('unavailable');

      if (usePrimary &&
          (isRateLimit || isUnavailable) &&
          _settings.isConfigured2) {
        log.warning(
          '[LlmRunner] Primary provider error ($msg) — falling back to secondary',
        );
        return run(
          systemPrompt: systemPrompt,
          userPrompt: userPrompt,
          registry: registry,
          usePrimary: false,
          taskLlmConfig: taskLlmConfig,
          toolsOverride: toolsOverride,
          stopAfterToolCall: stopAfterToolCall,
          outputDir: outputDir,
        );
      }
      return LlmRunResult(content: '', success: false, error: msg);
    }
  }

  Future<LlmRunResult> _runWithEmbedded({
    required String model,
    required String systemPrompt,
    required String userPrompt,
    required double temperature,
    required int? maxTokens,
    required int? topK,
    required double? topP,
    required double? repeatPenalty,
    required ServerToolRegistry registry,
    List<MCPTool>? toolsOverride,
    bool stopAfterToolCall = false,
    Directory? outputDir,
  }) async {
    final modelPath = p.join(resolveServerModelsDir(), model);
    final modelFile = File(modelPath);
    if (!await modelFile.exists()) {
      return LlmRunResult(
        content: '',
        success: false,
        error:
            'Embedded model file not found on server: $model. Expected at $modelPath',
      );
    }

    final adapter = ServerEmbeddedLlmAdapter.instance;
    try {
      return await adapter.runExclusive(() async {
        try {
          log.info('[LlmRunner] Loading embedded model from $modelPath');
          await adapter
              .initialize(modelPath)
              .timeout(
                _embeddedLoadTimeout,
                onTimeout: () => throw TimeoutException(
                  'Timed out while loading embedded model "$model" after ${_embeddedLoadTimeout.inMinutes} minutes.',
                ),
              );

          final history = <ServerEmbeddedChatMessage>[
            ServerEmbeddedChatMessage.system(systemPrompt),
            ServerEmbeddedChatMessage.human(userPrompt),
          ];

          var effectiveTools = toolsOverride ?? registry.mcpTools;
          final defaultMaxTokens = effectiveTools.isNotEmpty ? 256 : 1024;
          final effectiveMaxTokens = (maxTokens != null && maxTokens > 0)
              ? maxTokens
              : defaultMaxTokens;
          final effectiveTopK = (topK != null && topK > 0) ? topK : 40;
          final effectiveTopP = (topP != null && topP > 0) ? topP : 0.9;
          final effectiveRepeatPenalty =
              (repeatPenalty != null && repeatPenalty > 0)
              ? repeatPenalty
              : 1.15;
          log.info(
            '[LlmRunner] Embedded params: maxTokens=$effectiveMaxTokens topK=$effectiveTopK topP=$effectiveTopP repeatPenalty=$effectiveRepeatPenalty tools=${effectiveTools.length}',
          );

          var toolCallCount = 0;
          var sentChars = 0;
          var finalContent = '';
          var sawFinalResponse = false;
          String? lastWebSearchQuery;
          final List<String> allToolOutputs = [];
          final executedIds = <String>{};
          final executedSignatures = <String>{};

          for (var iteration = 0; iteration < _maxToolIterations; iteration++) {
            _liveLog('Iteration ${iteration + 1}...');
            sentChars += history.fold<int>(
              0,
              (sum, message) => sum + message.content.length,
            );
            final response = await adapter
                .generateResponse(
                  messages: history,
                  availableTools: effectiveTools,
                  temperature: temperature,
                  maxTokens: effectiveMaxTokens,
                  topK: effectiveTopK,
                  topP: effectiveTopP,
                  penalty: effectiveRepeatPenalty,
                )
                .timeout(
                  _embeddedGenerationTimeout,
                  onTimeout: () => throw TimeoutException(
                    'Timed out waiting for embedded model response after ${_embeddedGenerationTimeout.inMinutes} minutes (iteration ${iteration + 1}).',
                  ),
                );

            var embeddedToolCalls = response.toolCalls;
            if (embeddedToolCalls.isEmpty && effectiveTools.isNotEmpty) {
              final textToolCalls = _extractTextToolCalls(response.content);
              if (textToolCalls.isNotEmpty) {
                log.info(
                  '[LlmRunner] iter=$iteration extracted_text_tool_calls=${textToolCalls.length}',
                );
                embeddedToolCalls = textToolCalls
                    .map(
                      (tc) => ServerEmbeddedToolCall(
                        id: tc.id,
                        name: tc.name,
                        arguments: tc.arguments,
                      ),
                    )
                    .toList();
              }
            }

            if (response.content.isNotEmpty) {
              _liveLog('Assistant: ${response.content}');
            }

            if (embeddedToolCalls.isEmpty) {
              finalContent = response.content.trim();
              sawFinalResponse = true;
              break;
            }

            history.add(
              ServerEmbeddedChatMessage.ai(
                response.content,
                toolCalls: embeddedToolCalls,
              ),
            );

            toolCallCount += embeddedToolCalls.length;
            log.info(
              '[LlmRunner] iter=$iteration embedded_tool_calls=${embeddedToolCalls.length}',
            );
            _liveLog(
              'Model requested tool calls: ${embeddedToolCalls.map((tc) => tc.name).join(", ")}',
            );

            for (final toolCall in embeddedToolCalls) {
              final cleanToolName = toolCall.name;
              final toolCallId =
                  toolCall.id ?? 'call_${cleanToolName}_$iteration';

              final toolSchema = _findToolByName(effectiveTools, cleanToolName);
              if (toolSchema == null) {
                log.warning(
                  '[LlmRunner] Model attempted to call tool "$cleanToolName" which is not available/enabled.',
                );
                final errorText =
                    'Error: The tool "$cleanToolName" is not available/enabled for this step.';
                final structuredText = jsonEncode({
                  'tool': cleanToolName,
                  'id': toolCallId,
                  'tool_executed': false,
                  'error': errorText,
                });
                history.add(
                  ServerEmbeddedChatMessage.toolResult(
                    toolCallId: toolCallId,
                    toolName: cleanToolName,
                    content: structuredText,
                  ),
                );
                continue;
              }
              final schemaArgs = _coerceArgumentsToSchema(
                toolCall.arguments,
                toolSchema,
              );
              final repairedArgs = _repairMissingRequiredToolArgs(
                toolName: cleanToolName,
                arguments: schemaArgs,
                userPrompt: userPrompt,
                fallbackWebSearchQuery: lastWebSearchQuery,
              );

              final toolSignature =
                  '$cleanToolName|${jsonEncode(repairedArgs)}';
              final isDuplicateId =
                  toolCall.id != null && executedIds.contains(toolCall.id);
              final isDuplicateSignature = executedSignatures.contains(
                toolSignature,
              );

              if (isDuplicateId || isDuplicateSignature) {
                log.warning(
                  '[LlmRunner] Repeated tool call detected for "$cleanToolName" in embedded loop. Intercepting.',
                );

                String previousResult = 'Executed successfully.';
                try {
                  final prevMsg = history.lastWhere(
                    (m) =>
                        m.role == ServerEmbeddedChatRole.tool &&
                        m.toolName == cleanToolName,
                  );
                  final parsed = jsonDecode(prevMsg.content);
                  if (parsed is Map && parsed.containsKey('tool_result')) {
                    previousResult = parsed['tool_result'].toString();
                  } else {
                    previousResult = prevMsg.content;
                  }
                } catch (_) {}

                final loopCorrectionText =
                    'The tool "$cleanToolName" was already successfully executed. '
                    'Previous result: $previousResult\n\n'
                    'Do NOT call this tool again. Generate the final response using this result.';

                final structuredText = jsonEncode({
                  'tool': cleanToolName,
                  'id': toolCallId,
                  'tool_executed': true,
                  'tool_result': loopCorrectionText,
                });

                history.add(
                  ServerEmbeddedChatMessage.toolResult(
                    toolCallId: toolCallId,
                    toolName: cleanToolName,
                    content: structuredText,
                  ),
                );

                effectiveTools = [];
                _liveLog(
                  'Repeated tool call detected. Clearing available tools to force model finalization.',
                );
                continue;
              }

              if (toolCall.id != null) {
                executedIds.add(toolCall.id!);
              }
              executedSignatures.add(toolSignature);

              if (cleanToolName == 'web_search') {
                final q = (repairedArgs['query'] as String?)?.trim();
                if (q != null && q.isNotEmpty) {
                  lastWebSearchQuery = q;
                }
              }
              log.info('[LlmRunner] Calling embedded tool "$cleanToolName"');
              _liveLog(
                'Calling tool "$cleanToolName" with arguments: $repairedArgs',
              );
              final result = await registry
                  .callTool(cleanToolName, repairedArgs)
                  .timeout(
                    _embeddedToolCallTimeout,
                    onTimeout: () => throw TimeoutException(
                      'Tool "$cleanToolName" timed out after ${_embeddedToolCallTimeout.inMinutes} minutes during embedded run.',
                    ),
                  );
              if (outputDir != null) {
                _extractAndSaveBinaryFiles(result, outputDir);
              }
              final resultText = _toolResultForLlm(result);
              final truncated = resultText.length > _settings.maxToolOutputSize
                  ? resultText.substring(0, _settings.maxToolOutputSize)
                  : resultText;
              _liveLog('Tool "$cleanToolName" returned: $truncated');
              allToolOutputs.add(truncated);
              final structuredText = jsonEncode({
                'tool': cleanToolName,
                'id': toolCallId,
                'tool_executed': true,
                'tool_result': truncated,
              });
              history.add(
                ServerEmbeddedChatMessage.toolResult(
                  toolCallId: toolCallId,
                  toolName: cleanToolName,
                  content: structuredText,
                ),
              );
            }

            if (stopAfterToolCall) {
              finalContent = allToolOutputs.isNotEmpty
                  ? allToolOutputs.join('\n\n')
                  : '';
              sawFinalResponse = true;
              log.info(
                '[LlmRunner] stopAfterToolCall enabled — halting after first embedded tool round-trip',
              );
              break;
            }
          }

          if (finalContent.isNotEmpty) {
            _liveLog('Task execution finished. Final response:\n$finalContent');
          }

          final execLogSnippet = _buildExecutionLogSnippetFromEmbedded(
            history,
            sawFinalResponse,
            finalContent,
          );

          return LlmRunResult(
            content: finalContent,
            success:
                finalContent.isNotEmpty ||
                (stopAfterToolCall && toolCallCount > 0),
            error:
                (finalContent.isEmpty &&
                    (!stopAfterToolCall || toolCallCount == 0))
                ? 'LLM returned empty response'
                : null,
            promptTokens: 0,
            completionTokens: 0,
            toolCallCount: toolCallCount,
            messageCount: history.length + (sawFinalResponse ? 1 : 0),
            sentChars: sentChars,
            executionLogSnippet: execLogSnippet,
          );
        } catch (e) {
          return LlmRunResult(content: '', success: false, error: e.toString());
        }
      }, waitTimeout: _embeddedQueueTimeout);
    } catch (e) {
      return LlmRunResult(content: '', success: false, error: e.toString());
    }
  }

  // ── Claude path (anthropic_sdk_dart) ───────────────────────

  Future<LlmRunResult> _runWithClaude({
    required String apiKey,
    required String model,
    required String systemPrompt,
    required String userPrompt,
    required double temperature,
    required int? maxTokens,
  }) async {
    final client = anthropic.AnthropicClient(
      config: anthropic.AnthropicConfig(
        authProvider: anthropic.ApiKeyProvider(apiKey),
      ),
    );
    try {
      final effectiveMaxTokens = (maxTokens != null && maxTokens > 0)
          ? maxTokens
          : 4096;
      final request = anthropic.MessageCreateRequest(
        model: model,
        messages: [anthropic.InputMessage.user(userPrompt)],
        system: systemPrompt.trim().isNotEmpty
            ? anthropic.SystemPrompt.text(systemPrompt)
            : null,
        maxTokens: effectiveMaxTokens,
        temperature: temperature,
      );
      final response = await client.messages.create(request);
      final textBuffer = StringBuffer();
      for (final block in response.content) {
        if (block is anthropic.TextBlock) {
          textBuffer.write(block.text);
        }
      }
      final content = textBuffer.toString();
      return LlmRunResult(
        content: content,
        success: content.isNotEmpty,
        error: content.isEmpty ? 'Claude returned empty response' : null,
        promptTokens: response.usage.inputTokens,
        completionTokens: response.usage.outputTokens,
        messageCount: content.isNotEmpty ? 3 : 2,
        sentChars: systemPrompt.length + userPrompt.length,
      );
    } finally {
      client.close();
    }
  }

  // ── Native path ─────────────────────────────────────────────

  Future<LlmRunResult> _runWithNative({
    required LlmProvider provider,
    required String model,
    required String apiKey,
    required String baseUrl,
    required double temperature,
    required int? maxTokens,
    required String systemPrompt,
    required String userPrompt,
    required ServerToolRegistry registry,
    List<MCPTool>? toolsOverride,
    bool thinking = false,
    bool stopAfterToolCall = false,
    Directory? outputDir,
  }) async {
    final mcpTools = toolsOverride ?? registry.mcpTools;
    log.info('[LlmRunner] ${mcpTools.length} tools available');

    String effectiveSystemPrompt = systemPrompt;
    if (provider == LlmProvider.ollama) {
      effectiveSystemPrompt +=
          '\n\n'
          'Tool execution rules:\n'
          '- Each tool execution result is returned in a JSON structure: {"tool": "name", "id": "unique_id", "tool_executed": true, "tool_result": ...}.\n'
          '- Once a tool has been successfully executed (tool_executed is true), you must NEVER call that tool with the same "id" or parameters again.\n'
          '- Instead, formulate your final response to the user using the result provided in tool_result.';
    }

    // Build initial message history.
    final List<LlmChatMessage> history = [
      LlmChatMessage.system(effectiveSystemPrompt),
      LlmChatMessage.human(userPrompt),
    ];

    int promptTokens = 0;
    int completionTokens = 0;
    int toolCallCount = 0;
    int sentChars = systemPrompt.length + userPrompt.length;
    String finalContent = '';
    bool sawFinalResponse = false;
    String? lastWebSearchQuery;
    final List<String> allToolOutputs = [];
    final executedIds = <String>{};
    final executedSignatures = <String>{};

    for (int i = 0; i < _maxToolIterations; i++) {
      _liveLog('Iteration ${i + 1}...');
      _NativeResponse response;
      try {
        response = await _generateNative(
          provider: provider,
          model: model,
          apiKey: apiKey,
          baseUrl: baseUrl,
          temperature: temperature,
          maxTokens: maxTokens,
          history: history,
          mcpTools: mcpTools,
          thinking: thinking,
        );
      } catch (e) {
        log.error('[LlmRunner] native call failed: $e');
        return LlmRunResult(
          content: '',
          success: false,
          error: e.toString(),
          promptTokens: promptTokens,
          completionTokens: completionTokens,
          toolCallCount: toolCallCount,
          sentChars: sentChars,
        );
      }

      promptTokens += response.promptTokens;
      completionTokens += response.completionTokens;

      final content = response.content;
      var toolCalls = response.toolCalls;

      if (toolCalls.isEmpty && content.isNotEmpty) {
        final textToolCalls = _extractTextToolCalls(content);
        if (textToolCalls.isNotEmpty) {
          toolCalls = textToolCalls;
        }
      }

      if (content.isNotEmpty) {
        _liveLog('Assistant: $content');
      }

      if (toolCalls.isEmpty) {
        finalContent = content;
        sawFinalResponse = true;
        break;
      }

      history.add(LlmChatMessage.ai(content, toolCalls: toolCalls));
      toolCallCount += toolCalls.length;
      sentChars += content.length;
      log.info('[LlmRunner] iter=$i tool_calls=${toolCalls.length}');
      _liveLog(
        'Model requested tool calls: ${toolCalls.map((tc) => tc.name).join(", ")}',
      );

      for (final tc in toolCalls) {
        final cleanToolName = tc.name;
        final toolCallId = tc.id;

        final toolSchema = _findToolByName(mcpTools, cleanToolName);
        if (toolSchema == null) {
          log.warning(
            '[LlmRunner] Model attempted to call tool "$cleanToolName" which is not available/enabled.',
          );
          final errorText =
              'Error: The tool "$cleanToolName" is not available/enabled. Available tools: ${mcpTools.map((t) => t.name).join(", ")}';
          final structuredText = jsonEncode({
            'tool': cleanToolName,
            'id': toolCallId,
            'tool_executed': false,
            'error': errorText,
          });
          history.add(
            LlmChatMessage.toolResult(
              toolCallId: toolCallId,
              content: structuredText,
            ),
          );
          sentChars += structuredText.length;
          continue;
        }
        final schemaArgs = _coerceArgumentsToSchema(tc.arguments, toolSchema);
        final repairedArgs = _repairMissingRequiredToolArgs(
          toolName: cleanToolName,
          arguments: schemaArgs,
          userPrompt: userPrompt,
          fallbackWebSearchQuery: lastWebSearchQuery,
        );

        final toolSignature = '$cleanToolName|${jsonEncode(repairedArgs)}';
        final isDuplicateId = executedIds.contains(tc.id);
        final isDuplicateSignature = executedSignatures.contains(toolSignature);

        if (isDuplicateId || isDuplicateSignature) {
          log.warning(
            '[LlmRunner] Repeated tool call detected for "$cleanToolName" in native loop. Intercepting.',
          );

          String previousResult = 'Executed successfully.';
          try {
            final prevMsg = history.lastWhere((m) {
              if (m.role != LlmChatRole.tool) return false;
              try {
                final parsed = jsonDecode(m.content);
                return parsed is Map && parsed['tool'] == cleanToolName;
              } catch (_) {
                return false;
              }
            });
            final parsed = jsonDecode(prevMsg.content);
            if (parsed is Map && parsed.containsKey('tool_result')) {
              previousResult = parsed['tool_result'].toString();
            } else {
              previousResult = prevMsg.content;
            }
          } catch (_) {}

          final loopCorrectionText =
              'The tool "$cleanToolName" was already successfully executed. '
              'Previous result: $previousResult\n\n'
              'Do NOT call this tool again. Generate the final response using this result.';

          final structuredText = jsonEncode({
            'tool': cleanToolName,
            'id': toolCallId,
            'tool_executed': true,
            'tool_result': loopCorrectionText,
          });

          history.add(
            LlmChatMessage.toolResult(
              toolCallId: toolCallId,
              content: structuredText,
            ),
          );
          sentChars += structuredText.length;
          break;
        }

        executedIds.add(tc.id);
        executedSignatures.add(toolSignature);

        if (cleanToolName == 'web_search') {
          final q = (repairedArgs['query'] as String?)?.trim();
          if (q != null && q.isNotEmpty) {
            lastWebSearchQuery = q;
          }
        }
        log.info('[LlmRunner] Calling tool "$cleanToolName"');
        _liveLog('Calling tool "$cleanToolName" with arguments: $repairedArgs');
        final result = await registry.callTool(cleanToolName, repairedArgs);
        if (outputDir != null) {
          _extractAndSaveBinaryFiles(result, outputDir);
        }
        final resultText = _toolResultForLlm(result);
        final truncated = resultText.length > _settings.maxToolOutputSize
            ? resultText.substring(0, _settings.maxToolOutputSize)
            : resultText;
        _liveLog('Tool "$cleanToolName" returned: $truncated');
        final structuredText = jsonEncode({
          'tool': cleanToolName,
          'id': toolCallId,
          'tool_executed': true,
          'tool_result': truncated,
        });
        history.add(
          LlmChatMessage.toolResult(
            toolCallId: toolCallId,
            content: structuredText,
          ),
        );
        sentChars += structuredText.length;
        allToolOutputs.add(truncated);
      }

      if (stopAfterToolCall) {
        finalContent = allToolOutputs.isNotEmpty
            ? allToolOutputs.join('\n\n')
            : '';
        sawFinalResponse = true;
        log.info(
          '[LlmRunner] stopAfterToolCall enabled — halting after first tool round-trip',
        );
        break;
      }
    }

    if (finalContent.isNotEmpty) {
      _liveLog('Task execution finished. Final response:\n$finalContent');
    }

    final execLogSnippet = _buildExecutionLogSnippetFromNative(
      history,
      sawFinalResponse,
      finalContent,
    );

    return LlmRunResult(
      content: finalContent,
      success:
          finalContent.isNotEmpty || (stopAfterToolCall && toolCallCount > 0),
      error:
          (finalContent.isEmpty && (!stopAfterToolCall || toolCallCount == 0))
          ? 'LLM returned empty response'
          : null,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      toolCallCount: toolCallCount,
      rawToolOutput: allToolOutputs.isNotEmpty
          ? allToolOutputs.join('\n\n')
          : null,
      messageCount: history.length + (sawFinalResponse ? 1 : 0),
      sentChars: sentChars,
      executionLogSnippet: execLogSnippet,
    );
  }

  Future<_NativeResponse> _generateNative({
    required LlmProvider provider,
    required String model,
    required String apiKey,
    required String baseUrl,
    required double temperature,
    required int? maxTokens,
    required List<LlmChatMessage> history,
    required List<MCPTool> mcpTools,
    bool thinking = false,
  }) async {
    switch (provider) {
      case LlmProvider.openai:
        return _generateOpenAi(
          model: model,
          apiKey: apiKey,
          baseUrl: baseUrl,
          temperature: temperature,
          maxTokens: maxTokens,
          history: history,
          mcpTools: mcpTools,
          isRealOpenAi: baseUrl.isEmpty || baseUrl.contains('api.openai.com'),
        );
      case LlmProvider.gemini:
        return _generateGemini(
          model: model,
          apiKey: apiKey,
          temperature: temperature,
          maxTokens: maxTokens,
          history: history,
          mcpTools: mcpTools,
        );
      case LlmProvider.ollama:
        return _generateOllama(
          model: model,
          apiKey: apiKey,
          baseUrl: baseUrl,
          temperature: temperature,
          maxTokens: maxTokens,
          history: history,
          mcpTools: mcpTools,
        );
      case LlmProvider.openaiCompatible:
        return _generateOpenAi(
          model: model,
          apiKey: apiKey,
          baseUrl: baseUrl.isNotEmpty ? baseUrl : 'http://localhost:11434/v1',
          temperature: temperature,
          maxTokens: maxTokens,
          history: history,
          mcpTools: mcpTools,
          httpClient: _MistralPatchClient(http.Client()),
          isRealOpenAi: false,
        );
      case LlmProvider.mistral:
        return _generateOpenAi(
          model: model,
          apiKey: apiKey,
          baseUrl: baseUrl.isNotEmpty ? baseUrl : 'https://api.mistral.ai/v1',
          temperature: temperature,
          maxTokens: maxTokens,
          history: history,
          mcpTools: mcpTools,
          httpClient: _MistralPatchClient(http.Client()),
          isRealOpenAi: false,
        );
      default:
        throw Exception('Unsupported provider for native runner: $provider');
    }
  }

  Future<_NativeResponse> _generateOpenAi({
    required String model,
    required String apiKey,
    required String baseUrl,
    required double temperature,
    required int? maxTokens,
    required List<LlmChatMessage> history,
    required List<MCPTool> mcpTools,
    http.Client? httpClient,
    bool isRealOpenAi = true,
  }) async {
    final client = openai.OpenAIClient(
      config: openai.OpenAIConfig(
        authProvider: openai.ApiKeyProvider(apiKey),
        baseUrl: baseUrl.isNotEmpty ? baseUrl : 'https://api.openai.com/v1',
      ),
      httpClient: httpClient,
    );
    try {
      final List<openai.ChatMessage> openAiMsgs = [];
      for (final msg in history) {
        switch (msg.role) {
          case LlmChatRole.system:
            openAiMsgs.add(openai.ChatMessage.system(msg.content));
          case LlmChatRole.human:
            openAiMsgs.add(openai.ChatMessage.user(msg.content));
          case LlmChatRole.ai:
            if (msg.toolCalls.isNotEmpty) {
              openAiMsgs.add(
                openai.ChatMessage.assistant(
                  toolCalls: msg.toolCalls.map((tc) {
                    return openai.ToolCall.functionCall(
                      id: tc.id,
                      call: openai.FunctionCall.fromMap(
                        name: tc.name,
                        arguments: tc.arguments,
                      ),
                    );
                  }).toList(),
                ),
              );
            } else {
              openAiMsgs.add(
                openai.ChatMessage.assistant(content: msg.content),
              );
            }
          case LlmChatRole.tool:
            openAiMsgs.add(
              openai.ChatMessage.tool(
                toolCallId: msg.toolCallId ?? '',
                content: msg.content,
              ),
            );
        }
      }

      final List<openai.Tool> tools = [];
      for (final t in mcpTools) {
        tools.add(
          openai.Tool.function(
            name: t.name,
            description: t.description ?? '',
            parameters: t.inputSchema ?? {'type': 'object', 'properties': {}},
          ),
        );
      }

      // Generate a stable prompt cache key from the system prompt so repeated
      // agent task runs with the same system prompt benefit from OpenAI prompt
      // caching, reducing token costs by 50%+ on cached prefix tokens.
      String? promptCacheKey;
      if (isRealOpenAi && tools.isNotEmpty) {
        final sysMsg = history
            .firstWhere(
              (m) => m.role == LlmChatRole.system,
              orElse: () =>
                  const LlmChatMessage(role: LlmChatRole.system, content: ''),
            )
            .content;
        if (sysMsg.isNotEmpty) {
          promptCacheKey =
              'tealkit-server-${sysMsg.hashCode.toRadixString(16)}';
        }
      }

      final response = await client.chat.completions.create(
        openai.ChatCompletionCreateRequest(
          model: model,
          messages: openAiMsgs,
          tools: tools.isNotEmpty ? tools : null,
          temperature: temperature >= 0 ? temperature : 0.7,
          maxTokens: (maxTokens != null && maxTokens > 0) ? maxTokens : null,
          promptCacheKey: isRealOpenAi ? promptCacheKey : null,
          promptCacheRetention: isRealOpenAi && promptCacheKey != null
              ? openai.PromptCacheRetention.h24
              : null,
        ),
      );

      final choice = response.choices.first;
      final content = choice.message.content ?? '';
      final toolCalls = <LlmToolCall>[];

      if (choice.message.toolCalls != null) {
        for (final tc in choice.message.toolCalls!) {
          if (tc.type == 'function') {
            Map<String, dynamic> args = {};
            try {
              args = jsonDecode(tc.function.arguments) as Map<String, dynamic>;
            } catch (_) {}
            toolCalls.add(
              LlmToolCall(id: tc.id, name: tc.function.name, arguments: args),
            );
          }
        }
      }

      return _NativeResponse(
        content: content,
        toolCalls: toolCalls,
        promptTokens: response.usage?.promptTokens ?? 0,
        completionTokens: response.usage?.completionTokens ?? 0,
      );
    } finally {
      client.close();
    }
  }

  Future<_NativeResponse> _generateGemini({
    required String model,
    required String apiKey,
    required double temperature,
    required int? maxTokens,
    required List<LlmChatMessage> history,
    required List<MCPTool> mcpTools,
  }) async {
    final client = genai.GoogleAIClient(
      config: genai.GoogleAIConfig(authProvider: genai.ApiKeyProvider(apiKey)),
    );
    try {
      final List<genai.Content> geminiContent = [];

      for (final msg in history) {
        if (msg.role == LlmChatRole.system) continue;

        if (msg.role == LlmChatRole.human) {
          geminiContent.add(
            genai.Content(role: 'user', parts: [genai.TextPart(msg.content)]),
          );
        } else if (msg.role == LlmChatRole.ai) {
          if (msg.toolCalls.isNotEmpty) {
            geminiContent.add(
              genai.Content(
                role: 'model',
                parts: msg.toolCalls.map((tc) {
                  return genai.Part.functionCall(tc.name, args: tc.arguments);
                }).toList(),
              ),
            );
          } else {
            geminiContent.add(
              genai.Content(
                role: 'model',
                parts: [genai.TextPart(msg.content)],
              ),
            );
          }
        } else if (msg.role == LlmChatRole.tool) {
          final toolCallName = msg.toolCallId != null
              ? _findToolNameById(history, msg.toolCallId!)
              : 'unknown_tool';
          geminiContent.add(
            genai.Content(
              role: 'function',
              parts: [
                genai.Part.functionResponse(toolCallName, {
                  'content': msg.content,
                }),
              ],
            ),
          );
        }
      }

      final systemMsg = history.firstWhere(
        (m) => m.role == LlmChatRole.system,
        orElse: () =>
            const LlmChatMessage(role: LlmChatRole.system, content: ''),
      );

      final List<genai.Tool>? tools;
      if (mcpTools.isNotEmpty) {
        tools = [
          genai.Tool(
            functionDeclarations: mcpTools.map((t) {
              return genai.FunctionDeclaration(
                name: t.name,
                description: t.description ?? 'No description',
                parameters: _mcpSchemaToGemini(t.inputSchema),
              );
            }).toList(),
          ),
        ];
      } else {
        tools = null;
      }

      final response = await client.models.generateContent(
        model: model,
        request: genai.GenerateContentRequest(
          contents: geminiContent,
          systemInstruction: systemMsg.content.trim().isNotEmpty
              ? genai.Content(parts: [genai.TextPart(systemMsg.content)])
              : null,
          tools: tools,
          generationConfig: genai.GenerationConfig(
            temperature: temperature,
            maxOutputTokens: maxTokens,
          ),
        ),
      );

      final content = response.text ?? '';
      final toolCalls = <LlmToolCall>[];
      final parts = response.candidates?.firstOrNull?.content?.parts;
      if (parts != null) {
        for (final p in parts) {
          if (p is genai.FunctionCallPart) {
            final name = p.functionCall.name;
            final arguments = p.functionCall.args ?? {};
            final argHash = jsonEncode(arguments).hashCode.toRadixString(16);
            toolCalls.add(
              LlmToolCall(
                id: 'call_${name}_$argHash',
                name: name,
                arguments: arguments,
              ),
            );
          }
        }
      }

      return _NativeResponse(
        content: content,
        toolCalls: toolCalls,
        promptTokens: response.usageMetadata?.promptTokenCount ?? 0,
        completionTokens: response.usageMetadata?.candidatesTokenCount ?? 0,
      );
    } finally {
      client.close();
    }
  }

  Future<_NativeResponse> _generateOllama({
    required String model,
    required String apiKey,
    required String baseUrl,
    required double temperature,
    required int? maxTokens,
    required List<LlmChatMessage> history,
    required List<MCPTool> mcpTools,
  }) async {
    log.info('[OllamaRunner] Input baseUrl: "$baseUrl"');
    var cleanedBaseUrl = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (cleanedBaseUrl.endsWith('/api')) {
      cleanedBaseUrl = cleanedBaseUrl
          .substring(0, cleanedBaseUrl.length - 4)
          .replaceAll(RegExp(r'/+$'), '');
      log.info(
        '[OllamaRunner] baseUrl after strip endsWith("/api"): "$cleanedBaseUrl"',
      );
    }
    final finalUrl = cleanedBaseUrl.isNotEmpty
        ? cleanedBaseUrl
        : 'http://localhost:11434';
    log.info(
      '[OllamaRunner] final target baseUrl config for OllamaClient: "$finalUrl"',
    );
    final client = ollama.OllamaClient(
      config: ollama.OllamaConfig(
        baseUrl: finalUrl,
        defaultHeaders: apiKey.isNotEmpty
            ? {'Authorization': 'Bearer $apiKey'}
            : const {},
      ),
    );
    try {
      final List<ollama.ChatMessage> ollamaMsgs = [];
      for (final msg in history) {
        switch (msg.role) {
          case LlmChatRole.system:
            ollamaMsgs.add(
              ollama.ChatMessage(
                role: ollama.MessageRole.system,
                content: msg.content,
              ),
            );
          case LlmChatRole.human:
            ollamaMsgs.add(
              ollama.ChatMessage(
                role: ollama.MessageRole.user,
                content: msg.content,
              ),
            );
          case LlmChatRole.ai:
            if (msg.toolCalls.isNotEmpty) {
              ollamaMsgs.add(
                ollama.ChatMessage(
                  role: ollama.MessageRole.assistant,
                  content: msg.content,
                  toolCalls: msg.toolCalls.map((tc) {
                    return ollama.ToolCall(
                      function: ollama.ToolCallFunction(
                        name: tc.name,
                        arguments: tc.arguments,
                      ),
                    );
                  }).toList(),
                ),
              );
            } else {
              ollamaMsgs.add(
                ollama.ChatMessage(
                  role: ollama.MessageRole.assistant,
                  content: msg.content,
                ),
              );
            }
          case LlmChatRole.tool:
            ollamaMsgs.add(
              ollama.ChatMessage(
                role: ollama.MessageRole.tool,
                content: msg.content,
              ),
            );
        }
      }

      final List<ollama.ToolDefinition>? tools;
      if (mcpTools.isNotEmpty) {
        tools = mcpTools.map((mcpTool) {
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
      } else {
        tools = null;
      }

      final response = await client.chat.create(
        request: ollama.ChatRequest(
          model: model,
          messages: ollamaMsgs,
          tools: tools,
          options: ollama.ModelOptions(
            temperature: temperature,
            numPredict: maxTokens,
          ),
        ),
      );

      final content = response.message?.content ?? '';
      final toolCalls = <LlmToolCall>[];
      if (response.message?.toolCalls != null) {
        for (final tc in response.message!.toolCalls!) {
          if (tc.function?.name != null) {
            final name = tc.function!.name;
            final arguments = tc.function!.arguments ?? {};
            final argHash = jsonEncode(arguments).hashCode.toRadixString(16);
            toolCalls.add(
              LlmToolCall(
                id: 'call_${name}_$argHash',
                name: name,
                arguments: arguments,
              ),
            );
          }
        }
      }

      return _NativeResponse(
        content: content,
        toolCalls: toolCalls,
        promptTokens: response.promptEvalCount ?? 0,
        completionTokens: response.evalCount ?? 0,
      );
    } finally {
      client.close();
    }
  }

  String _findToolNameById(List<LlmChatMessage> history, String toolCallId) {
    for (final msg in history) {
      if (msg.role == LlmChatRole.ai) {
        for (final tc in msg.toolCalls) {
          if (tc.id == toolCallId) return tc.name;
        }
      }
    }
    return 'unknown_tool';
  }

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

  String _toolResultForLlm(MCPToolResult result) {
    final parts = <String>[];
    for (final c in result.content) {
      if (c.data != null && c.data!.isNotEmpty) {
        final mime = c.mimeType?.trim();
        parts.add(
          'File created${mime != null && mime.isNotEmpty ? ' ($mime)' : ''}. Binary payload omitted.',
        );
        continue;
      }
      final raw = (c.text ?? '').trim();
      if (raw.isEmpty) continue;
      parts.add(_sanitizeToolTextForLlm(raw));
    }
    return parts.where((p) => p.trim().isNotEmpty).join('\n');
  }

  String _sanitizeToolTextForLlm(String text) {
    var out = text;
    final compact = out.replaceAll(RegExp(r'\s+'), '');
    if (compact.length > 4096 && _looksLikeEncodedPayload(compact)) {
      return '[large encoded/binary payload omitted]';
    }
    out = out.replaceAllMapped(_markdownBase64DataUriPattern, (match) {
      final name = (match.group(1) ?? 'file').trim();
      return '$name (binary file omitted)';
    });
    out = out.replaceAll(_base64DataUriPattern, '[binary data omitted]');
    out = out.replaceAllMapped(
      RegExp(r'([A-Za-z0-9+/=_\-\r\n]{160,}?(?=[^A-Za-z0-9+/=_\-\r\n]|$))'),
      (match) {
        final matched = match.group(1) ?? '';
        if (_looksLikeEncodedPayload(matched.replaceAll(RegExp(r'\s'), ''))) {
          return '[base64-encoded data omitted]';
        }
        return matched;
      },
    );
    out = out.replaceAllMapped(
      RegExp(r'\b[0-9a-fA-F]{256,}\b'),
      (_) => '[hex payload omitted]',
    );
    final trimmed = out.trimLeft();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        final decoded = jsonDecode(out);
        final scrubbed = _scrubBinaryJson(decoded);
        return jsonEncode(scrubbed);
      } catch (_) {}
    }
    return out;
  }

  Map<String, dynamic> _repairMissingRequiredToolArgs({
    required String toolName,
    required Map<String, dynamic> arguments,
    required String userPrompt,
    String? fallbackWebSearchQuery,
  }) {
    if (toolName != 'web_search') return arguments;

    final existingQuery = (arguments['query'] as String?)?.trim();
    if (existingQuery != null && existingQuery.isNotEmpty) {
      return arguments;
    }

    final repairedQuery = _buildWebSearchQueryFromPrompt(
      userPrompt,
      fallbackQuery: fallbackWebSearchQuery,
    );
    if (repairedQuery.isEmpty) {
      return arguments;
    }

    final patched = Map<String, dynamic>.from(arguments);
    patched['query'] = repairedQuery;
    log.warning(
      '[LlmRunner] Repaired missing web_search.query from prompt context: "$repairedQuery"',
    );
    return patched;
  }

  String _buildWebSearchQueryFromPrompt(
    String prompt, {
    String? fallbackQuery,
  }) {
    final cleaned = prompt.trim();
    if (cleaned.isNotEmpty) return cleaned;
    final fallback = fallbackQuery?.trim() ?? '';
    if (fallback.isNotEmpty) return fallback;
    return '';
  }

  bool _looksLikeEncodedPayload(String text) {
    if (text.length < 160) return false;
    final b64 = RegExp(r'^[A-Za-z0-9+/=_\-]+$').hasMatch(text);
    if (b64) {
      final nonPadLen = text.replaceAll('=', '').length;
      if (nonPadLen >= 160) return true;
    }
    final hex = RegExp(r'^[0-9a-fA-F]+$').hasMatch(text);
    if (hex && text.length >= 256) return true;
    return false;
  }

  dynamic _scrubBinaryJson(dynamic value) {
    if (value is List) {
      return value.map(_scrubBinaryJson).toList(growable: false);
    }
    if (value is! Map) return value;
    final m = <String, dynamic>{};
    for (final e in value.entries) {
      m[e.key.toString()] = _scrubBinaryJson(e.value);
    }
    final encoding = (m['encoding'] ?? '').toString().toLowerCase();
    final mime = (m['mimeType'] ?? m['mimetype'] ?? '')
        .toString()
        .toLowerCase();
    final hasBinaryEncoding = encoding == 'base64';
    final hasBinaryMime = _isBinaryMime(mime);

    if (hasBinaryEncoding || hasBinaryMime) {
      final fileName = (m['fileName'] ?? m['filename'] ?? '').toString().trim();
      final message = (m['message'] ?? '').toString().trim();
      return <String, dynamic>{
        'fileName': fileName.isNotEmpty ? fileName : null,
        'mimeType': mime.isNotEmpty ? mime : null,
        'message': message.isNotEmpty
            ? message
            : 'File created. Binary payload omitted.',
      }..removeWhere((k, v) => v == null);
    }

    for (final key in const ['content', 'data']) {
      final v = m[key];
      if (v is String &&
          v.length > 256 &&
          RegExp(r'^[A-Za-z0-9+/=_\-\r\n]{100,}$').hasMatch(v)) {
        final fileName = (m['fileName'] ?? m['filename'] ?? 'file')
            .toString()
            .trim();
        m[key] =
            '[base64 file content omitted - use filename "$fileName" instead]';
      }
      if (v is String && _base64DataUriPattern.hasMatch(v)) {
        final fileName = (m['fileName'] ?? m['filename'] ?? 'file')
            .toString()
            .trim();
        m[key] =
            '[data URI file content omitted - use filename "$fileName" instead]';
      }
    }
    return m;
  }

  bool _isBinaryMime(String mime) {
    if (mime.isEmpty) return false;
    if (mime.startsWith('image/')) return true;
    if (mime.startsWith('audio/')) return true;
    if (mime.startsWith('video/')) return true;
    if (mime.startsWith('application/octet-stream')) return true;
    if (mime.startsWith('application/zip')) return true;
    if (mime.startsWith('application/vnd.')) return true;
    return mime.contains('spreadsheet') ||
        mime.contains('officedocument') ||
        mime.contains('excel') ||
        mime.contains('pdf');
  }

  void _extractAndSaveBinaryFiles(MCPToolResult result, Directory outputDir) {
    try {
      void trySave(String? fileName, String? mimeType, String? base64Data) {
        if (fileName == null || fileName.trim().isEmpty) return;
        if (mimeType == null || mimeType.trim().isEmpty) return;
        if (base64Data == null || base64Data.trim().isEmpty) return;
        try {
          final bytes = base64.decode(base64Data.trim());
          final file = File(p.join(outputDir.path, fileName.trim()));
          file.writeAsBytesSync(bytes, flush: true);
          log.info(
            '[LlmRunner] Saved binary tool result file: ${file.path} (${bytes.length} bytes)',
          );
        } catch (e) {
          log.warning(
            '[LlmRunner] Failed to decode/write binary file $fileName: $e',
          );
        }
      }

      void tryAddFromJsonMap(Map<String, dynamic> m) {
        if (m['fileName'] != null &&
            m['mimeType'] != null &&
            m['encoding'] == 'base64') {
          final payload = m['content'] ?? m['data'];
          if (payload != null) {
            trySave(
              m['fileName'].toString(),
              m['mimeType'].toString(),
              payload.toString(),
            );
          }
        }
      }

      String? pendingFileName;

      for (final content in result.content) {
        final text = content.text;
        if (text != null && text.trim().isNotEmpty) {
          try {
            final decoded = jsonDecode(text);
            if (decoded is Map<String, dynamic>) {
              if (decoded.containsKey('fileName') &&
                  !decoded.containsKey('encoding')) {
                pendingFileName = decoded['fileName']?.toString();
              }
              tryAddFromJsonMap(decoded);
              if (decoded['data'] is Map<String, dynamic>) {
                tryAddFromJsonMap(decoded['data'] as Map<String, dynamic>);
              }
            }
          } catch (_) {}
          continue;
        }

        if (content.data != null && content.data!.isNotEmpty) {
          final mime = content.mimeType ?? 'application/octet-stream';
          final ext = _extensionForMime(mime);
          final fname = (pendingFileName != null && pendingFileName.isNotEmpty)
              ? pendingFileName
              : 'output_${DateTime.now().millisecondsSinceEpoch}.$ext';
          trySave(fname, mime, content.data);
          pendingFileName = null;
        }
      }
    } catch (e) {
      log.warning(
        '[LlmRunner] Error extracting generated files from tool result: $e',
      );
    }
  }

  String _extensionForMime(String mime) {
    final lower = mime.toLowerCase();
    if (lower.contains('pdf')) return 'pdf';
    if (lower.contains('png')) return 'png';
    if (lower.contains('jpeg') || lower.contains('jpg')) return 'jpg';
    if (lower.contains('gif')) return 'gif';
    if (lower.contains('svg')) return 'svg';
    if (lower.contains('html')) return 'html';
    if (lower.contains('csv')) return 'csv';
    if (lower.contains('json')) return 'json';
    if (lower.contains('zip')) return 'zip';
    if (lower.contains('excel') || lower.contains('spreadsheet')) return 'xlsx';
    return 'bin';
  }

  String _buildExecutionLogSnippetFromEmbedded(
    List<ServerEmbeddedChatMessage> history,
    bool sawFinalResponse,
    String finalContent,
  ) {
    final execLogBuf = StringBuffer();
    for (final msg in history) {
      if (msg.role == ServerEmbeddedChatRole.system) {
        execLogBuf.writeln('System Prompt:\n${msg.content}\n');
      } else if (msg.role == ServerEmbeddedChatRole.human) {
        execLogBuf.writeln('User Message:\n${msg.content}\n');
      } else if (msg.role == ServerEmbeddedChatRole.ai) {
        if (msg.content.isNotEmpty) {
          execLogBuf.writeln('Assistant Message:\n${msg.content}\n');
        }
        if (msg.toolCalls.isNotEmpty) {
          for (final tc in msg.toolCalls) {
            execLogBuf.writeln(
              'Tool Call: ${tc.name} arguments: ${jsonEncode(tc.arguments)}',
            );
          }
        }
      } else if (msg.role == ServerEmbeddedChatRole.tool) {
        String toolResult = msg.content;
        try {
          final parsed = jsonDecode(msg.content);
          if (parsed is Map && parsed.containsKey('tool_result')) {
            toolResult = parsed['tool_result'].toString();
          }
        } catch (_) {}
        final displayResult = toolResult.length > 128
            ? '${toolResult.substring(0, 128)}...'
            : toolResult;
        execLogBuf.writeln('Tool Response: $displayResult\n');
      }
    }
    if (sawFinalResponse && finalContent.isNotEmpty) {
      execLogBuf.writeln('Assistant Message:\n$finalContent\n');
    }
    return execLogBuf.toString().trim();
  }

  String _buildExecutionLogSnippetFromNative(
    List<LlmChatMessage> history,
    bool sawFinalResponse,
    String finalContent,
  ) {
    final execLogBuf = StringBuffer();
    for (final msg in history) {
      if (msg.role == LlmChatRole.system) {
        execLogBuf.writeln('System Prompt:\n${msg.content}\n');
      } else if (msg.role == LlmChatRole.human) {
        execLogBuf.writeln('User Message:\n${msg.content}\n');
      } else if (msg.role == LlmChatRole.ai) {
        if (msg.content.isNotEmpty) {
          execLogBuf.writeln('Assistant Message:\n${msg.content}\n');
        }
        if (msg.toolCalls.isNotEmpty) {
          for (final tc in msg.toolCalls) {
            execLogBuf.writeln(
              'Tool Call: ${tc.name} arguments: ${jsonEncode(tc.arguments)}',
            );
          }
        }
      } else if (msg.role == LlmChatRole.tool) {
        String toolResult = msg.content;
        try {
          final parsed = jsonDecode(msg.content);
          if (parsed is Map && parsed.containsKey('tool_result')) {
            toolResult = parsed['tool_result'].toString();
          }
        } catch (_) {}
        final displayResult = toolResult.length > 128
            ? '${toolResult.substring(0, 128)}...'
            : toolResult;
        execLogBuf.writeln('Tool Response: $displayResult\n');
      }
    }
    if (sawFinalResponse && finalContent.isNotEmpty) {
      execLogBuf.writeln('Assistant Message:\n$finalContent\n');
    }
    return execLogBuf.toString().trim();
  }
}

class _NativeResponse {
  final String content;
  final List<LlmToolCall> toolCalls;
  final int promptTokens;
  final int completionTokens;

  const _NativeResponse({
    required this.content,
    required this.toolCalls,
    this.promptTokens = 0,
    this.completionTokens = 0,
  });
}
