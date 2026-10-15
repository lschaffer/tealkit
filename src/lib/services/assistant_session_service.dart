import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/mcp_models.dart';

/// Represents a serialized conversation session.
/// Fully compatible with CLI SessionData format.
class AssistantSessionData {
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

  AssistantSessionData({
    this.version = '1.0',
    required this.id,
    required this.title,
    this.mode = 'assistant',
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

  factory AssistantSessionData.fromJson(Map<String, dynamic> json) {
    final rawMsgs = (json['messages'] as List?) ?? [];
    return AssistantSessionData(
      version: json['version'] as String? ?? '1.0',
      id:
          json['id'] as String? ??
          DateTime.now().millisecondsSinceEpoch.toString(),
      title: json['title'] as String? ?? 'TealKit Session',
      mode: json['mode'] as String? ?? 'assistant',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
      llmName: json['llmName'] as String?,
      llmProvider: json['llmProvider'] as String?,
      llmModel: json['llmModel'] as String?,
      messages: rawMsgs
          .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// Service to save, export, load, and record assistant chat sessions.
class AssistantSessionService {
  AssistantSessionService._();

  /// Saves a session to a JSON or Markdown file.
  /// If [targetPath] is null, opens a native file-save dialog.
  static Future<String?> saveSession(
    AssistantSessionData session, {
    String? targetPath,
  }) async {
    String? filePath = targetPath;

    final isMarkdown = filePath != null && filePath.endsWith('.md');
    final String content;
    if (isMarkdown) {
      content = exportMarkdown(session);
    } else {
      content = const JsonEncoder.withIndent('  ').convert(session.toJson());
    }

    final bytes = utf8.encode(content);

    if (filePath == null) {
      final safeTitle = session.title
          .trim()
          .replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
      final ts = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
      final defaultName = safeTitle.isNotEmpty
          ? 'session_${safeTitle}_$ts.json'
          : 'session_$ts.json';

      if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
        filePath = await FilePicker.saveFile(
          dialogTitle: 'Save Assistant Session',
          fileName: defaultName,
          type: FileType.custom,
          allowedExtensions: ['json', 'md'],
          bytes: Uint8List.fromList(bytes),
        );
      } else {
        // Mobile fallback
        final docs = await getApplicationDocumentsDirectory();
        final sessionDir = Directory(p.join(docs.path, 'sessions'));
        if (!sessionDir.existsSync()) {
          sessionDir.createSync(recursive: true);
        }
        filePath = p.join(sessionDir.path, defaultName);
      }
    }

    if (filePath == null) return null;

    final file = File(p.normalize(filePath));
    if (!file.parent.existsSync()) {
      file.parent.createSync(recursive: true);
    }
    await file.writeAsBytes(bytes);
    return file.path;
  }

  /// Loads a session from a JSON or Markdown file.
  /// If [filePath] is null, opens a file picker dialog.
  static Future<AssistantSessionData?> loadSession({String? filePath}) async {
    String? path = filePath;

    if (path == null) {
      final res = await FilePicker.pickFiles(
        dialogTitle: 'Load Assistant Session',
        type: FileType.custom,
        allowedExtensions: ['json', 'md'],
        allowMultiple: false,
      );
      if (res == null || res.files.isEmpty) return null;
      path = res.files.first.path;
      if (path == null && res.files.first.bytes != null) {
        final content = utf8.decode(res.files.first.bytes!);
        return _parseContent(content, fileName: res.files.first.name);
      }
    }

    if (path == null) return null;
    final file = File(p.normalize(path));
    if (!file.existsSync()) {
      throw FileSystemException('Session file not found', path);
    }

    final content = await file.readAsString();
    return _parseContent(content, fileName: p.basename(path));
  }

  static AssistantSessionData _parseContent(String content, {String? fileName}) {
    if ((fileName != null && fileName.endsWith('.md')) || content.trim().startsWith('---')) {
      return importMarkdown(content, fileName: fileName);
    }

    try {
      final json = jsonDecode(content) as Map<String, dynamic>;
      return AssistantSessionData.fromJson(json);
    } catch (_) {
      return importMarkdown(content, fileName: fileName);
    }
  }

  /// Exports a [AssistantSessionData] object to GitHub-flavored Markdown.
  static String exportMarkdown(AssistantSessionData session) {
    final buffer = StringBuffer();
    buffer.writeln('---');
    buffer.writeln('title: "${session.title}"');
    buffer.writeln('id: "${session.id}"');
    buffer.writeln('mode: "${session.mode}"');
    if (session.llmName != null) buffer.writeln('llm: "${session.llmName}"');
    if (session.llmProvider != null) buffer.writeln('provider: "${session.llmProvider}"');
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
        ChatRole.tool => '### ⚙️ Tool Result (${msg.lastCalledToolName ?? "tool"})',
        ChatRole.system => '### ℹ️ System',
      };

      buffer.writeln('$roleHeader (${_formatTime(msg.timestamp)})');
      buffer.writeln('');
      buffer.writeln(msg.content.trim());
      buffer.writeln('');
    }

    return buffer.toString();
  }

  /// Imports a [AssistantSessionData] object from Markdown transcript.
  static AssistantSessionData importMarkdown(String content, {String? fileName}) {
    final lines = content.split('\n');
    final messages = <ChatMessage>[];

    String mode = 'assistant';
    String? llmName;
    String? llmProvider;
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
          if (key == 'provider') llmProvider = val;
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
            id: '${DateTime.now().millisecondsSinceEpoch}_${messages.length}',
            content: text,
            role: currentRole,
            lastCalledToolName: currentToolName,
            type: MessageType.text,
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

      if (trimmed.startsWith('### 👤 User') ||
          trimmed.startsWith('## User') ||
          trimmed == 'User:') {
        flushMessage();
        currentRole = ChatRole.user;
        currentTs = _extractTimestamp(line) ?? DateTime.now();
      } else if (trimmed.startsWith('### 🤖 Assistant') ||
          trimmed.startsWith('## Assistant') ||
          trimmed == 'Assistant:') {
        flushMessage();
        currentRole = ChatRole.assistant;
        currentTs = _extractTimestamp(line) ?? DateTime.now();
      } else if (trimmed.startsWith('### ⚙️ Tool Result') ||
          trimmed.startsWith('## Tool Result') ||
          trimmed.startsWith('### Tool')) {
        flushMessage();
        currentRole = ChatRole.tool;
        currentTs = _extractTimestamp(line) ?? DateTime.now();
        final match = RegExp(r'\((.*?)\)').firstMatch(line);
        currentToolName = match?.group(1);
      } else if (trimmed.startsWith('# ') && !trimmed.startsWith('### ')) {
        continue;
      } else {
        msgBuffer.writeln(line);
      }
    }
    flushMessage();

    final title = fileName != null
        ? p.basenameWithoutExtension(fileName)
        : 'TealKit Session';
    return AssistantSessionData(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: title,
      mode: mode,
      createdAt: createdAt,
      updatedAt: updatedAt,
      llmName: llmName,
      llmProvider: llmProvider,
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
