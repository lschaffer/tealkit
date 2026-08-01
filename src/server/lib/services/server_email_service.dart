import 'dart:io';

import 'package:mailer/mailer.dart';
import 'package:mailer/smtp_server.dart';

import 'package:tealkit_server/database/server_duckdb_adapter.dart';
import '../models/agentic_task.dart';
import '../runner/server_llm_runner.dart';
import '../runner/server_tool_registry.dart';
import '../utils/server_logger.dart';
import 'server_data_sources_service.dart';
import 'server_llm_settings_service.dart';

/// Server-side email notification service for task completion notifications.
///
/// Sends emails via SMTP when tasks complete (if notification is configured).
class ServerEmailService {
  static final ServerEmailService _instance = ServerEmailService._();
  factory ServerEmailService() => _instance;
  ServerEmailService._();

  static final RegExp _markdownDataUriPattern = RegExp(
    r'\[([^\]]+)\]\((data:[^\s\)]+;base64,([A-Za-z0-9+/=\s]+))\)',
    caseSensitive: false,
    dotAll: true,
  );

  /// Send a task completion email notification.
  /// Returns true if sent successfully, false otherwise.
  Future<bool> sendTaskNotification({
    required AgenticTask task,
    required bool success,
    required String resultText,
    required String? errorText,
    List<File> attachments = const [],
    String? previousResult,
  }) async {
    final notification = task.notification.email;
    if (notification == null || notification.recipients.isEmpty) {
      log.debug(
        '[EmailService] No email notification configured for task "${task.name}"',
      );
      return false;
    }

    // Check send condition
    final shouldSend = await _shouldSend(
      notification.sendCondition,
      success: success,
      resultText: resultText,
      previousResult: previousResult,
      conditionExpression: notification.conditionExpression,
    );
    if (!shouldSend) {
      log.debug(
        '[EmailService] Send condition not met for task "${task.name}" (condition: ${notification.sendCondition})',
      );
      return false;
    }

    final ds = ServerDataSourcesService.instance;

    // Check if notifications are globally enabled
    if (!ds.notificationEmailEnabled) {
      log.warning('[EmailService] Task notifications disabled globally');
      return false;
    }

    // Check if SMTP is configured
    if (ds.smtpHost.trim().isEmpty) {
      log.warning(
        '[EmailService] SMTP not configured - cannot send email for task "${task.name}"',
      );
      return false;
    }

    try {
      final extraction = await _extractEmbeddedDataUriAttachments(
        resultText: resultText,
        taskName: task.name,
        includeAttachments: notification.withAttachment,
      );

      final effectiveResultText = _sanitizeHtmlForEmailBody(
        extraction.sanitizedText,
      );
      final effectiveAttachments = <File>[
        ...attachments,
        ...extraction.extractedFiles,
      ];

      final subject = _buildSubject(notification, task);
      final body = _buildBody(task, success, effectiveResultText, errorText);

      final message = Message()
        ..from = Address(
          ds.smtpSender.isNotEmpty ? ds.smtpSender : ds.imapUsername,
        )
        ..recipients.addAll(notification.recipients)
        ..subject = subject
        ..text = body
        ..html = _markdownToHtml(body);

      if (notification.withAttachment && effectiveAttachments.isNotEmpty) {
        message.attachments.addAll(
          effectiveAttachments.map(FileAttachment.new),
        );
      }

      final smtpServer = gmail(
        ds.smtpSender.isNotEmpty ? ds.smtpSender : ds.imapUsername,
        ds.imapPassword,
      );

      // Override SMTP settings if custom values provided
      if (ds.smtpHost.isNotEmpty && ds.smtpPort > 0) {
        // For custom SMTP, create server connection manually
        final customSmtp = SmtpServer(
          ds.smtpHost,
          port: ds.smtpPort,
          ssl: ds.imapUseSsl,
          allowInsecure: !ds.imapUseSsl,
          username: ds.imapUsername,
          password: ds.imapPassword,
        );

        await send(message, customSmtp);
      } else {
        // Use Gmail
        await send(message, smtpServer);
      }

      log.info(
        '[EmailService] Email sent for task "${task.name}" to ${notification.recipients.join(", ")}',
      );
      return true;
    } catch (e, st) {
      log.error(
        '[EmailService] Failed to send email for task "${task.name}": $e',
        e,
        st,
      );
      return false;
    }
  }

  Future<_EmbeddedAttachmentExtractionResult>
  _extractEmbeddedDataUriAttachments({
    required String resultText,
    required String taskName,
    required bool includeAttachments,
  }) async {
    if (resultText.isEmpty) {
      return const _EmbeddedAttachmentExtractionResult(
        sanitizedText: '',
        extractedFiles: [],
      );
    }

    final extractedFiles = <File>[];
    var index = 0;

    final sanitizedText = resultText.replaceAllMapped(_markdownDataUriPattern, (
      match,
    ) {
      final rawName = (match.group(1) ?? '').trim();
      final dataUri = (match.group(2) ?? '').trim();

      final fallbackName = 'attachment_${index + 1}';
      final fileName = _sanitizeFileName(
        rawName.isNotEmpty ? rawName : fallbackName,
        fallbackName: fallbackName,
      );

      if (includeAttachments) {
        final extracted = _tryDecodeDataUriToTempFile(
          dataUri: dataUri,
          fileName: fileName,
          taskName: taskName,
          index: index,
        );
        if (extracted != null) {
          extractedFiles.add(extracted);
        }
      }

      index++;
      return includeAttachments
          ? '$fileName (attached)'
          : '$fileName (file content omitted)';
    });

    return _EmbeddedAttachmentExtractionResult(
      sanitizedText: sanitizedText,
      extractedFiles: extractedFiles,
    );
  }

  File? _tryDecodeDataUriToTempFile({
    required String dataUri,
    required String fileName,
    required String taskName,
    required int index,
  }) {
    try {
      final uri = Uri.parse(dataUri);
      final uriData = uri.data;
      if (uriData == null) {
        return null;
      }

      final bytes = uriData.contentAsBytes();
      if (bytes.isEmpty) {
        return null;
      }

      final safeTaskName = taskName.replaceAll(
        RegExp(r'[^a-zA-Z0-9_\-]+'),
        '_',
      );
      final tempName =
          '${safeTaskName}_${DateTime.now().millisecondsSinceEpoch}_${index + 1}_$fileName';
      final path =
          '${Directory.systemTemp.path}${Platform.pathSeparator}$tempName';
      final file = File(path);
      file.writeAsBytesSync(bytes, flush: true);
      return file;
    } catch (e) {
      log.warning(
        '[EmailService] Failed to decode embedded data URI attachment "$fileName": $e',
      );
      return null;
    }
  }

  String _sanitizeFileName(String name, {required String fallbackName}) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return fallbackName;

    final cleaned = trimmed
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), '_');
    if (cleaned.isEmpty || cleaned == '.') {
      return fallbackName;
    }
    return cleaned;
  }

  Future<bool> _shouldSend(
    String sendCondition, {
    required bool success,
    required String resultText,
    String? previousResult,
    String? conditionExpression,
  }) async {
    switch (sendCondition.toLowerCase().trim()) {
      case 'always':
        return true;
      case 'on_success':
        return success;
      case 'on_failure':
      case 'on_error':
        return !success;
      case 'on_change':
        return (previousResult ?? '').trim() != resultText.trim();
      case 'conditional':
        final expr = (conditionExpression ?? '').trim();
        if (expr.isEmpty) return false;
        return _evaluateCustomCondition(expr, resultText);
      default:
        return false;
    }
  }

  Future<bool> _evaluateCustomCondition(
    String expression,
    String resultText,
  ) async {
    try {
      final llmRunner = ServerLlmRunner(ServerLlmSettingsService.instance);
      final emptyRegistry = ServerToolRegistry(ServerDuckDbAdapter());
      final prompt =
          'Check this condition against the task output.\n'
          'Return ONLY TRUE if it matches, otherwise ONLY FALSE.\n\n'
          'Condition: $expression\n\n'
          'Task output:\n$resultText';
      final res = await llmRunner.run(
        systemPrompt:
            'You are a strict condition evaluator. Reply with ONLY TRUE or ONLY FALSE.',
        userPrompt: prompt,
        registry: emptyRegistry,
      );
      if (!res.success) return false;
      final ans = res.content.trim().toLowerCase();
      final firstToken = RegExp(
        r'\b(true|false)\b',
        caseSensitive: false,
      ).firstMatch(ans)?.group(1)?.toLowerCase();
      if (firstToken == null) {
        log.warning(
          '[EmailService] Conditional evaluation returned non-boolean response: ${res.content}',
        );
        return false;
      }
      final matched = firstToken == 'true';
      log.info(
        '[EmailService] Conditional evaluation: "$expression" => $firstToken (send=$matched)',
      );
      return matched;
    } catch (e) {
      log.warning('[EmailService] Conditional evaluation failed: $e');
      return false;
    }
  }

  String _buildSubject(EmailNotification notification, AgenticTask task) {
    final template = notification.subject?.trim() ?? 'Task Result: [task_name]';
    return template.replaceAll('[task_name]', task.name);
  }

  String _buildBody(
    AgenticTask task,
    bool success,
    String resultText,
    String? errorText,
  ) {
    final buf = StringBuffer()
      ..writeln('Task: ${task.name}')
      ..writeln('Status: ${success ? "SUCCESS" : "FAILED"}')
      ..writeln('Time: ${DateTime.now().toIso8601String()}')
      ..writeln('---\n');

    if (success && resultText.isNotEmpty) {
      buf.writeln('Result:');
      buf.writeln(resultText);
    } else if (!success && errorText != null && errorText.isNotEmpty) {
      buf.writeln('Error:');
      buf.writeln(errorText);
    } else if (resultText.isNotEmpty) {
      buf.writeln(resultText);
    }

    return buf.toString();
  }
}

class _EmbeddedAttachmentExtractionResult {
  final String sanitizedText;
  final List<File> extractedFiles;

  const _EmbeddedAttachmentExtractionResult({
    required this.sanitizedText,
    required this.extractedFiles,
  });
}

String _sanitizeHtmlForEmailBody(String text) {
  var sanitized = text;

  // 1. Replace ```html\n...\n``` code fences
  final fenceRegex = RegExp(
    r'```html\s*\n[\s\S]*?\n?```',
    caseSensitive: false,
  );
  if (fenceRegex.hasMatch(sanitized)) {
    sanitized = sanitized.replaceAll(
      fenceRegex,
      '[HTML Content Omitted - See Attachment]',
    );
  }

  // 2. Replace raw HTML blocks starting with <!DOCTYPE html> or <html... to </html>
  final rawHtmlRegex = RegExp(
    r'(?:<!doctype\s+html[^>]*>\s*)?<html[\s\S]*?</html>',
    caseSensitive: false,
  );
  if (rawHtmlRegex.hasMatch(sanitized)) {
    sanitized = sanitized.replaceAll(
      rawHtmlRegex,
      '[HTML Content Omitted - See Attachment]',
    );
  }

  // 3. Replace typical tag blocks like <table...</table>, <div...</div>, <ol...</ol>, <ul...</ul>
  final tagBlocksRegex = RegExp(
    r'<(table|div|ol|ul|body|html)[^>]*>[\s\S]*?</\1>',
    caseSensitive: false,
  );
  if (tagBlocksRegex.hasMatch(sanitized)) {
    sanitized = sanitized.replaceAll(
      tagBlocksRegex,
      '[HTML Content Omitted - See Attachment]',
    );
  }

  return sanitized;
}

String _markdownToHtml(String md) {
  // Escape HTML characters first to avoid injecting raw tags
  var escaped = md
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  // Headers: # Header
  escaped = escaped.replaceAllMapped(
    RegExp(r'^(#{1,6})\s+(.+)$', multiLine: true),
    (m) {
      final level = m.group(1)!.length;
      return '<h$level>${m.group(2)}</h$level>';
    },
  );

  // Code blocks: ```content```
  escaped = escaped.replaceAllMapped(
    RegExp(r'```(?:[a-zA-Z0-9]+)?\n([\s\S]*?)\n```'),
    (m) {
      return '<pre><code>${m.group(1)}</code></pre>';
    },
  );

  // Inline code: `code`
  escaped = escaped.replaceAllMapped(RegExp(r'`([^`\n]+)`'), (m) {
    return '<code>${m.group(1)}</code>';
  });

  // Bold: **text**
  escaped = escaped.replaceAllMapped(RegExp(r'\*\*([^*]+)\*\*'), (m) {
    return '<strong>${m.group(1)}</strong>';
  });

  // Italic: *text* or _text_
  escaped = escaped.replaceAllMapped(RegExp(r'\*([^*]+)\*'), (m) {
    return '<em>${m.group(1)}</em>';
  });
  escaped = escaped.replaceAllMapped(RegExp(r'\b_([^_]+)_\b'), (m) {
    return '<em>${m.group(1)}</em>';
  });

  // Links: [text](url)
  escaped = escaped.replaceAllMapped(RegExp(r'\[([^\]]+)\]\(([^)]+)\)'), (m) {
    final text = m.group(1);
    var url = m.group(2)!.trim();
    url = url.replaceAll('&amp;', '&');
    return '<a href="$url">$text</a>';
  });

  // Horizontal rules: ---
  escaped = escaped.replaceAll(RegExp(r'^---\s*$', multiLine: true), '<hr/>');

  // Process line by line for bullet lists and paragraphs
  final lines = escaped.split('\n');
  var inList = false;
  final processedLines = <String>[];

  for (var line in lines) {
    final trimmed = line.trim();
    if (trimmed.startsWith('- ') ||
        trimmed.startsWith('* ') ||
        trimmed.startsWith('• ')) {
      if (!inList) {
        processedLines.add('<ul>');
        inList = true;
      }
      processedLines.add('<li>${trimmed.substring(2)}</li>');
    } else {
      if (inList) {
        processedLines.add('</ul>');
        inList = false;
      }

      if (trimmed.isEmpty) {
        processedLines.add('<br/>');
      } else if (trimmed.startsWith('<h') ||
          trimmed.startsWith('<pre') ||
          trimmed.startsWith('<hr')) {
        processedLines.add(line);
      } else {
        processedLines.add('$line<br/>');
      }
    }
  }
  if (inList) {
    processedLines.add('</ul>');
  }

  final htmlBody = processedLines.join('\n');

  return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <style>
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      font-size: 14px;
      line-height: 1.6;
      color: #333333;
      background-color: #ffffff;
      margin: 0;
      padding: 20px;
    }
    h1, h2, h3, h4, h5, h6 {
      color: #111111;
      margin-top: 20px;
      margin-bottom: 10px;
      font-weight: 600;
    }
    h1 { font-size: 20px; border-bottom: 1px solid #eeeeee; padding-bottom: 8px; }
    h2 { font-size: 18px; }
    h3 { font-size: 16px; }
    a {
      color: #0066cc;
      text-decoration: none;
    }
    a:hover {
      text-decoration: underline;
    }
    code {
      font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, Courier, monospace;
      font-size: 12px;
      background-color: #f5f5f5;
      padding: 2px 4px;
      border-radius: 3px;
    }
    pre {
      background-color: #f5f5f5;
      padding: 12px;
      border-radius: 4px;
      overflow-x: auto;
    }
    pre code {
      background-color: transparent;
      padding: 0;
    }
    ul {
      margin-top: 5px;
      margin-bottom: 5px;
      padding-left: 20px;
    }
    li {
      margin-bottom: 4px;
    }
    hr {
      border: 0;
      border-top: 1px solid #dddddd;
      margin: 20px 0;
    }
  </style>
</head>
<body>
  $htmlBody
</body>
</html>
''';
}
