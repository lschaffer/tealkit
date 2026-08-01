// Pure Dart types for embedded LLM chat — no llamadart dependency.
// Used by server_runner.dart and server_embedded_llm_adapter.dart.
// Split from server_embedded_llm_adapter.dart so server_light can import
// these types without pulling in llamadart transitively.

class ServerEmbeddedToolCall {
  final String? id;
  final String name;
  final Map<String, dynamic> arguments;

  const ServerEmbeddedToolCall({
    this.id,
    required this.name,
    required this.arguments,
  });
}

enum ServerEmbeddedChatRole { system, human, ai, tool }

class ServerEmbeddedChatMessage {
  final ServerEmbeddedChatRole role;
  final String content;
  final List<ServerEmbeddedToolCall> toolCalls;
  final String? toolCallId;
  final String? toolName;

  const ServerEmbeddedChatMessage({
    required this.role,
    required this.content,
    this.toolCalls = const [],
    this.toolCallId,
    this.toolName,
  });

  factory ServerEmbeddedChatMessage.system(String content) =>
      ServerEmbeddedChatMessage(
        role: ServerEmbeddedChatRole.system,
        content: content,
      );

  factory ServerEmbeddedChatMessage.human(String content) =>
      ServerEmbeddedChatMessage(
        role: ServerEmbeddedChatRole.human,
        content: content,
      );

  factory ServerEmbeddedChatMessage.ai(
    String content, {
    List<ServerEmbeddedToolCall> toolCalls = const [],
  }) => ServerEmbeddedChatMessage(
    role: ServerEmbeddedChatRole.ai,
    content: content,
    toolCalls: toolCalls,
  );

  factory ServerEmbeddedChatMessage.toolResult({
    required String toolCallId,
    required String toolName,
    required String content,
  }) => ServerEmbeddedChatMessage(
    role: ServerEmbeddedChatRole.tool,
    content: content,
    toolCallId: toolCallId,
    toolName: toolName,
  );
}

class ServerEmbeddedGenerationResult {
  final String content;
  final List<ServerEmbeddedToolCall> toolCalls;

  const ServerEmbeddedGenerationResult({
    required this.content,
    required this.toolCalls,
  });
}
