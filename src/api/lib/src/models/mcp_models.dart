import 'dart:typed_data';

/// Base class for all MCP messages
abstract class MCPMessage {
  final String jsonrpc;

  const MCPMessage({this.jsonrpc = '2.0'});

  factory MCPMessage.fromJson(Map<String, dynamic> json) {
    if (json.containsKey('id')) {
      if (json.containsKey('method')) {
        return MCPRequest.fromJson(json);
      } else {
        return MCPResponse.fromJson(json);
      }
    } else if (json.containsKey('method')) {
      return MCPNotification.fromJson(json);
    } else {
      throw ArgumentError('Invalid MCP message format');
    }
  }

  Map<String, dynamic> toJson();
}

/// MCP Request message
class MCPRequest extends MCPMessage {
  final String id;
  final String method;
  final Map<String, dynamic>? params;

  const MCPRequest({
    required this.id,
    required this.method,
    this.params,
    super.jsonrpc,
  });

  factory MCPRequest.fromJson(Map<String, dynamic> json) {
    return MCPRequest(
      id: json['id'] as String,
      method: json['method'] as String,
      params: json['params'] as Map<String, dynamic>?,
      jsonrpc: json['jsonrpc'] as String? ?? '2.0',
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      'jsonrpc': jsonrpc,
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    };
  }
}

/// MCP Response message
class MCPResponse extends MCPMessage {
  final String id;
  final dynamic result;
  final MCPError? error;

  const MCPResponse({
    required this.id,
    this.result,
    this.error,
    super.jsonrpc,
  });

  factory MCPResponse.fromJson(Map<String, dynamic> json) {
    return MCPResponse(
      id: json['id'] as String,
      result: json['result'],
      error: json['error'] != null ? MCPError.fromJson(json['error']) : null,
      jsonrpc: json['jsonrpc'] as String? ?? '2.0',
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      'jsonrpc': jsonrpc,
      'id': id,
      if (result != null) 'result': result,
      if (error != null) 'error': error!.toJson(),
    };
  }
}

/// MCP Notification message
class MCPNotification extends MCPMessage {
  final String method;
  final Map<String, dynamic>? params;

  const MCPNotification({
    required this.method,
    this.params,
    super.jsonrpc,
  });

  factory MCPNotification.fromJson(Map<String, dynamic> json) {
    return MCPNotification(
      method: json['method'] as String,
      params: json['params'] as Map<String, dynamic>?,
      jsonrpc: json['jsonrpc'] as String? ?? '2.0',
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      'jsonrpc': jsonrpc,
      'method': method,
      if (params != null) 'params': params,
    };
  }
}

/// MCP Error object
class MCPError {
  final int code;
  final String message;
  final dynamic data;

  const MCPError({
    required this.code,
    required this.message,
    this.data,
  });

  factory MCPError.fromJson(Map<String, dynamic> json) {
    return MCPError(
      code: json['code'] as int,
      message: json['message'] as String,
      data: json['data'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'code': code,
      'message': message,
      if (data != null) 'data': data,
    };
  }
}

/// MCP Tool definition
class MCPTool {
  final String name;
  final String? description;
  final Map<String, dynamic>? inputSchema;
  final List<double>? embedding; // Pre-computed embedding from embedding server

  const MCPTool({
    required this.name,
    this.description,
    this.inputSchema,
    this.embedding,
  });

  factory MCPTool.fromJson(Map<String, dynamic> json) {
    return MCPTool(
      name: json['name'] as String,
      description: json['description'] as String?,
      inputSchema: json['inputSchema'] as Map<String, dynamic>?,
      embedding: (json['embedding'] as List<dynamic>?)?.map((e) => (e as num).toDouble()).toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      if (description != null) 'description': description,
      if (inputSchema != null) 'inputSchema': inputSchema,
      if (embedding != null) 'embedding': embedding,
    };
  }
}

/// MCP Tool result
class MCPToolResult {
  final List<MCPContent> content;
  final bool isError;

  const MCPToolResult({
    required this.content,
    this.isError = false,
  });

  factory MCPToolResult.fromJson(Map<String, dynamic> json) {
    final contentList = json['content'] as List? ?? [];
    return MCPToolResult(
      content: contentList.map((item) => MCPContent.fromJson(item)).toList(),
      isError: json['isError'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'content': content.map((item) => item.toJson()).toList(),
      'isError': isError,
    };
  }
}

/// MCP Content object
class MCPContent {
  final String type;
  final String? text;
  final String? data; // For base64 encoded content like images
  final String? mimeType;

  const MCPContent({
    required this.type,
    this.text,
    this.data,
    this.mimeType,
  });

  factory MCPContent.fromJson(Map<String, dynamic> json) {
    return MCPContent(
      type: json['type'] as String,
      text: json['text'] as String?,
      data: json['data'] as String?,
      mimeType: json['mimeType'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'type': type,
      if (text != null) 'text': text,
      if (data != null) 'data': data,
      if (mimeType != null) 'mimeType': mimeType,
    };
  }
}

/// MCP Resource definition
class MCPResource {
  final String uri;
  final String name;
  final String? description;
  final String? mimeType;

  const MCPResource({
    required this.uri,
    required this.name,
    this.description,
    this.mimeType,
  });

  factory MCPResource.fromJson(Map<String, dynamic> json) {
    return MCPResource(
      uri: json['uri'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      mimeType: json['mimeType'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'uri': uri,
      'name': name,
      if (description != null) 'description': description,
      if (mimeType != null) 'mimeType': mimeType,
    };
  }
}

/// MCP Sampling result for LLM completion
class MCPSamplingResult {
  final String model;
  final List<MCPMessage> messages;
  final String? stopReason;
  final Map<String, dynamic>? usage;

  const MCPSamplingResult({
    required this.model,
    required this.messages,
    this.stopReason,
    this.usage,
  });

  factory MCPSamplingResult.fromJson(Map<String, dynamic> json) {
    final messagesList = json['messages'] as List? ?? [];
    return MCPSamplingResult(
      model: json['model'] as String,
      messages: messagesList.map((msg) => MCPMessage.fromJson(msg)).toList(),
      stopReason: json['stopReason'] as String?,
      usage: json['usage'] as Map<String, dynamic>?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'model': model,
      'messages': messages.map((msg) => msg.toJson()).toList(),
      if (stopReason != null) 'stopReason': stopReason,
      if (usage != null) 'usage': usage,
    };
  }
}

/// Chat message for the UI
class ChatMessage {
  final String id;
  final String content;
  final ChatRole role;
  final DateTime timestamp;
  final List<MCPTool>? availableTools;
  final MCPToolResult? toolResult;
  final List<MessageAttachment>? attachments;
  final MessageType type;
  final String? lastCalledToolName; // Store the last called tool name for context
  final bool processAsMultiStep; // Whether to process message with \n as multi-step task
  final String? actionType; // Optional action type for interactive system messages (e.g., 'reset')

  const ChatMessage({
    required this.id,
    required this.content,
    required this.role,
    required this.timestamp,
    this.availableTools,
    this.toolResult,
    this.attachments,
    this.type = MessageType.text,
    this.lastCalledToolName,
    this.processAsMultiStep = false,
    this.actionType,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'content': content,
      'role': role.toString().split('.').last,
      'timestamp': timestamp.toIso8601String(),
      'type': type.toString().split('.').last,
      if (availableTools != null) 'availableTools': availableTools!.map((t) => t.toJson()).toList(),
      if (toolResult != null) 'toolResult': toolResult!.toJson(),
      if (attachments != null) 'attachments': attachments!.map((a) => a.toJson()).toList(),
      if (lastCalledToolName != null) 'lastCalledToolName': lastCalledToolName,
      'processAsMultiStep': processAsMultiStep,
      if (actionType != null) 'actionType': actionType,
    };
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String,
      content: json['content'] as String,
      role: ChatRole.values.firstWhere((r) => r.toString().split('.').last == json['role']),
      timestamp: DateTime.parse(json['timestamp']),
      type: json['type'] != null ? MessageType.values.firstWhere((t) => t.toString().split('.').last == json['type']) : MessageType.text,
      availableTools: json['availableTools'] != null ? (json['availableTools'] as List).map((t) => MCPTool.fromJson(t)).toList() : null,
      toolResult: json['toolResult'] != null ? MCPToolResult.fromJson(json['toolResult']) : null,
      attachments: json['attachments'] != null ? (json['attachments'] as List).map((a) => MessageAttachment.fromJson(a)).toList() : null,
      lastCalledToolName: json['lastCalledToolName'] as String?,
      processAsMultiStep: json['processAsMultiStep'] as bool? ?? false,
      actionType: json['actionType'] as String?,
    );
  }

  /// Create a text message
  factory ChatMessage.text({
    required String id,
    required String content,
    required ChatRole role,
    DateTime? timestamp,
    List<MCPTool>? availableTools,
    MCPToolResult? toolResult,
    String? lastCalledToolName,
    bool processAsMultiStep = false,
  }) {
    return ChatMessage(
      id: id,
      content: content,
      role: role,
      timestamp: timestamp ?? DateTime.now(),
      type: MessageType.text,
      availableTools: availableTools,
      toolResult: toolResult,
      lastCalledToolName: lastCalledToolName,
      processAsMultiStep: processAsMultiStep,
    );
  }

  /// Create an image message
  factory ChatMessage.image({
    required String id,
    required String imagePath,
    required ChatRole role,
    String content = '',
    DateTime? timestamp,
  }) {
    return ChatMessage(
      id: id,
      content: content,
      role: role,
      timestamp: timestamp ?? DateTime.now(),
      type: MessageType.image,
      attachments: [
        MessageAttachment(
          id: '$id-image',
          type: AttachmentType.image,
          path: imagePath,
          name: imagePath.split('/').last,
        ),
      ],
    );
  }

  /// Create a file message
  factory ChatMessage.file({
    required String id,
    required String filePath,
    required ChatRole role,
    String content = '',
    DateTime? timestamp,
  }) {
    return ChatMessage(
      id: id,
      content: content,
      role: role,
      timestamp: timestamp ?? DateTime.now(),
      type: MessageType.file,
      attachments: [
        MessageAttachment(
          id: '$id-file',
          type: AttachmentType.file,
          path: filePath,
          name: filePath.split('/').last,
        ),
      ],
    );
  }
}

/// Message attachment model
class MessageAttachment {
  final String id;
  final AttachmentType type;
  final String path;
  final String name;
  final int? size;
  final String? mimeType;
  final String? thumbnail;
  final Uint8List? bytes; // For web platform where path is unavailable

  const MessageAttachment({
    required this.id,
    required this.type,
    required this.path,
    required this.name,
    this.size,
    this.mimeType,
    this.thumbnail,
    this.bytes,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type.toString().split('.').last,
      'path': path,
      'name': name,
      if (size != null) 'size': size,
      if (mimeType != null) 'mimeType': mimeType,
      if (thumbnail != null) 'thumbnail': thumbnail,
    };
  }

  factory MessageAttachment.fromJson(Map<String, dynamic> json) {
    return MessageAttachment(
      id: json['id'] as String,
      type: AttachmentType.values.firstWhere((t) => t.toString().split('.').last == json['type']),
      path: json['path'] as String,
      name: json['name'] as String,
      size: json['size'] as int?,
      mimeType: json['mimeType'] as String?,
      thumbnail: json['thumbnail'] as String?,
    );
  }
}

/// Message type enumeration
enum MessageType {
  text,
  image,
  file,
  audio,
  video,
  download, // For live download progress widget
}

/// Attachment type enumeration
enum AttachmentType {
  image,
  file,
  audio,
  video,
  html,
}

/// Chat role enumeration
enum ChatRole {
  user,
  assistant,
  system,
  tool,
}

/// Connection status for the MCP client
enum MCPConnectionStatus {
  disconnected,
  connecting,
  connected,
  error,
}
