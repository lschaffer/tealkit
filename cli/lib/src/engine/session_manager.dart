import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp_core/dart_mcp_core.dart';
import 'package:path/path.dart' as p;

/// Represents a serialized conversation session.
class SessionData {
  final String version;
  final String id;
  final String title;
  final String mode;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? llmName;
  final String? llmProvider;
  final String? llmModel;
  final List<ChatMessage> messages;

  SessionData({
    this.version = '1.0',
    required this.id,
    required this.title,
    this.mode = 'code',
    required this.createdAt,
    required this.updatedAt,
    this.llmName,
    this.llmProvider,
    this.llmModel,
    required this.messages,
  });

  Map<String, dynamic> toJson() => {
        'version': version,
        'id': id,
        'title': title,
        'mode': mode,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        if (llmName != null) 'llmName': llmName,
        if (llmProvider != null) 'llmProvider': llmProvider,
        if (llmModel != null) 'llmModel': llmModel,
        'messages': messages.map((m) => m.toJson()).toList(),
      };

  factory SessionData.fromJson(Map<String, dynamic> json) {
    final rawMsgs = (json['messages'] as List?) ?? [];
    return SessionData(
      version: json['version'] as String? ?? '1.0',
      id: json['id'] as String? ?? DateTime.now().millisecondsSinceEpoch.toString(),
      title: json['title'] as String? ?? 'TealKit Session',
      mode: json['mode'] as String? ?? 'code',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? DateTime.now(),
      llmName: json['llmName'] as String?,
      llmProvider: json['llmProvider'] as String?,
      llmModel: json['llmModel'] as String?,
      messages: rawMsgs.map((e) => ChatMessage.fromJson(e as Map<String, dynamic>)).toList(),
    );
  }
}

/// Helper for exporting, saving, loading, and continuing interactive sessions.
class SessionManager {
  /// Saves a session to a JSON or Markdown file depending on extension.
  static Future<File> saveSession(SessionData session, String targetPath) async {
    final file = File(p.normalize(targetPath));
    if (!file.parent.existsSync()) {
      file.parent.createSync(recursive: true);
    }

    if (targetPath.endsWith('.md')) {
      final mdContent = exportMarkdown(session);
      await file.writeAsString(mdContent);
    } else {
      final jsonStr = const JsonEncoder.withIndent('  ').convert(session.toJson());
      await file.writeAsString(jsonStr);
    }
    return file;
  }

  /// Loads a session from a JSON or Markdown file.
  static Future<SessionData> loadSession(String filePath) async {
    final file = File(p.normalize(filePath));
    if (!file.existsSync()) {
      throw FileSystemException('Session file not found', filePath);
    }

    final content = await file.readAsString();
    if (filePath.endsWith('.md') || content.trim().startsWith('---')) {
      return importMarkdown(content, filePath: filePath);
    }

    try {
      final json = jsonDecode(content) as Map<String, dynamic>;
      return SessionData.fromJson(json);
    } catch (_) {
      // Fallback: try markdown parsing if JSON decoding fails
      return importMarkdown(content, filePath: filePath);
    }
  }

  /// Exports a [SessionData] object to GitHub-flavored Markdown.
  static String exportMarkdown(SessionData session) {
    final buffer = StringBuffer();
    buffer.writeln('---');
    buffer.writeln('title: "${session.title}"');
    buffer.writeln('id: "${session.id}"');
    buffer.writeln('mode: "${session.mode}"');
    if (session.llmName != null) buffer.writeln('llm: "${session.llmName}"');
    if (session.llmModel != null) buffer.writeln('model: "${session.llmModel}"');
    buffer.writeln('created: "${session.createdAt.toIso8601String()}"');
    buffer.writeln('updated: "${session.updatedAt.toIso8601String()}"');
    buffer.writeln('turns: ${session.messages.length}');
    buffer.writeln('---');
    buffer.writeln('');
    buffer.writeln('# ${session.title}');
    buffer.writeln('');

    for (final msg in session.messages) {
      final roleHeader = switch (msg.role) {
        ChatRole.user => '### 👤 User',
        ChatRole.assistant => '### 🤖 Assistant',
        ChatRole.tool => '### ⚙️ Tool Result (${msg.toolName ?? "tool"})',
        ChatRole.system => '### ℹ️ System',
      };

      buffer.writeln('$roleHeader (${_formatTime(msg.timestamp)})');
      buffer.writeln('');
      buffer.writeln(msg.content.trim());
      buffer.writeln('');
    }

    return buffer.toString();
  }

  /// Imports a [SessionData] object from Markdown transcript.
  static SessionData importMarkdown(String content, {String? filePath}) {
    final lines = content.split('\n');
    final messages = <ChatMessage>[];

    String mode = 'code';
    String? llmName;
    String? llmModel;
    DateTime createdAt = DateTime.now();
    DateTime updatedAt = DateTime.now();

    int contentStartIdx = 0;

    // Check for frontmatter
    if (lines.isNotEmpty && lines.first.trim() == '---') {
      int endFm = -1;
      for (int i = 1; i < lines.length; i++) {
        if (lines[i].trim() == '---') {
          endFm = i;
          break;
        }
        final line = lines[i];
        final parts = line.split(':');
        if (parts.length >= 2) {
          final key = parts[0].trim().toLowerCase();
          final val = parts.sublist(1).join(':').trim().replaceAll('"', '');
          if (key == 'mode') mode = val;
          if (key == 'llm') llmName = val;
          if (key == 'model') llmModel = val;
          if (key == 'created') createdAt = DateTime.tryParse(val) ?? createdAt;
          if (key == 'updated') updatedAt = DateTime.tryParse(val) ?? updatedAt;
        }
      }
      if (endFm != -1) {
        contentStartIdx = endFm + 1;
      }
    }

    ChatRole currentRole = ChatRole.user;
    String? currentToolName;
    final msgBuffer = StringBuffer();
    DateTime currentTs = DateTime.now();

    void flushMessage() {
      final text = msgBuffer.toString().trim();
      if (text.isNotEmpty) {
        messages.add(
          ChatMessage(
            id: DateTime.now().millisecondsSinceEpoch.toString() + '_' + messages.length.toString(),
            content: text,
            role: currentRole,
            toolName: currentToolName,
            type: currentRole == ChatRole.tool ? MessageType.toolResponse : MessageType.text,
            timestamp: currentTs,
          ),
        );
      }
      msgBuffer.clear();
      currentToolName = null;
    }

    for (int i = contentStartIdx; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trim();

      if (trimmed.startsWith('### 👤 User') || trimmed.startsWith('## User') || trimmed == 'User:') {
        flushMessage();
        currentRole = ChatRole.user;
        currentTs = _extractTimestamp(line) ?? DateTime.now();
      } else if (trimmed.startsWith('### 🤖 Assistant') || trimmed.startsWith('## Assistant') || trimmed == 'Assistant:') {
        flushMessage();
        currentRole = ChatRole.assistant;
        currentTs = _extractTimestamp(line) ?? DateTime.now();
      } else if (trimmed.startsWith('### ⚙️ Tool Result') || trimmed.startsWith('## Tool Result') || trimmed.startsWith('### Tool')) {
        flushMessage();
        currentRole = ChatRole.tool;
        currentTs = _extractTimestamp(line) ?? DateTime.now();
        final match = RegExp(r'\((.*?)\)').firstMatch(line);
        currentToolName = match?.group(1);
      } else if (trimmed.startsWith('# ') && !trimmed.startsWith('### ')) {
        // Skip main title
        continue;
      } else {
        msgBuffer.writeln(line);
      }
    }
    flushMessage();

    final title = filePath != null ? p.basenameWithoutExtension(filePath) : 'TealKit Session';
    return SessionData(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: title,
      mode: mode,
      createdAt: createdAt,
      updatedAt: updatedAt,
      llmName: llmName,
      llmModel: llmModel,
      messages: messages,
    );
  }

  static String _formatTime(DateTime dt) {
    return '${dt.year}-${_twoDigits(dt.month)}-${_twoDigits(dt.day)} ${_twoDigits(dt.hour)}:${_twoDigits(dt.minute)}:${_twoDigits(dt.second)}';
  }

  static String _twoDigits(int n) => n >= 10 ? '$n' : '0$n';

  static DateTime? _extractTimestamp(String line) {
    final reg = RegExp(r'\((\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2})\)');
    final match = reg.firstMatch(line);
    if (match != null) {
      return DateTime.tryParse(match.group(1)!.replaceAll(' ', 'T'));
    }
    return null;
  }
}
