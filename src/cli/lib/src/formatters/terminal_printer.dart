import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp_core/dart_mcp_core.dart';

/// Terminal styling, box drawing, and formatted tables for CLI output.
class TerminalPrinter {
  static final bool supportsAnsi = stdout.hasTerminal && stdout.supportsAnsiEscapes;

  // Colors
  static String reset(String text) => supportsAnsi ? '\x1B[0m$text\x1B[0m' : text;
  static String bold(String text) => supportsAnsi ? '\x1B[1m$text\x1B[0m' : text;
  static String dim(String text) => supportsAnsi ? '\x1B[2m$text\x1B[0m' : text;
  static String cyan(String text) => supportsAnsi ? '\x1B[36m$text\x1B[0m' : text;
  static String green(String text) => supportsAnsi ? '\x1B[32m$text\x1B[0m' : text;
  static String yellow(String text) => supportsAnsi ? '\x1B[33m$text\x1B[0m' : text;
  static String red(String text) => supportsAnsi ? '\x1B[31m$text\x1B[0m' : text;
  static String magenta(String text) => supportsAnsi ? '\x1B[35m$text\x1B[0m' : text;
  static String blue(String text) => supportsAnsi ? '\x1B[34m$text\x1B[0m' : text;

  /// Print a decorative box banner with dynamic width and clean line wrapping.
  static void printBanner(String title, [List<String> subLines = const []]) {
    // 1. Calculate optimal width (clamped between 74 and 96)
    int maxLineLen = title.length;
    for (final line in subLines) {
      if (line.length > maxLineLen) {
        maxLineLen = line.length;
      }
    }

    final width = (maxLineLen + 6).clamp(74, 94);
    final contentWidth = width - 4;

    final top = '╔${'═' * (width - 2)}╗';
    final mid = '╠${'═' * (width - 2)}╣';
    final bot = '╚${'═' * (width - 2)}╝';

    stdout.writeln('');
    stdout.writeln(cyan(top));

    void printRow(String text, {bool isTitle = false}) {
      // Calculate padding
      final visibleLen = _stripAnsi(text).length;
      final pad = contentWidth - visibleLen;
      final rightPad = pad > 0 ? ' ' * pad : '';
      if (isTitle) {
        final leftPadLen = (pad > 0 ? pad ~/ 2 : 0);
        final titleRightPad = ' ' * (pad - leftPadLen);
        stdout.writeln('${cyan("║")} ${' ' * leftPadLen}${bold(text)}$titleRightPad ${cyan("║")}');
      } else {
        stdout.writeln('${cyan("║")} $text$rightPad ${cyan("║")}');
      }
    }

    printRow(title, isTitle: true);

    if (subLines.isNotEmpty) {
      stdout.writeln(cyan(mid));
      for (final line in subLines) {
        final wrapped = _wrapBannerLine(line, contentWidth);
        for (final row in wrapped) {
          printRow(row);
        }
      }
    }

    stdout.writeln(cyan(bot));
    stdout.writeln('');
  }

  /// Strip ANSI codes to measure printable length accurately.
  static String _stripAnsi(String text) {
    return text.replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '');
  }

  /// Word-wraps a single banner line with smart indentation for key-value rows.
  static List<String> _wrapBannerLine(String line, int maxWidth) {
    if (_stripAnsi(line).length <= maxWidth) return [line];

    final lines = <String>[];
    final colonIdx = line.indexOf(' : ');
    final indent = colonIdx != -1 ? ' ' * (colonIdx + 3) : '   ';

    var current = line;

    while (_stripAnsi(current).length > maxWidth) {
      final searchArea = current.substring(0, maxWidth);
      int breakPoint = -1;

      final lastComma = searchArea.lastIndexOf(', ');
      if (lastComma != -1 && lastComma > 25) {
        breakPoint = lastComma + 1; // Break after comma
      } else {
        final lastSpace = searchArea.lastIndexOf(' ');
        if (lastSpace != -1 && lastSpace > 25) {
          breakPoint = lastSpace;
        } else {
          breakPoint = maxWidth;
        }
      }

      final segment = current.substring(0, breakPoint).trimRight();
      lines.add(segment);

      final remainder = current.substring(breakPoint).trimLeft();
      current = '$indent$remainder';
    }

    if (current.isNotEmpty) {
      lines.add(current);
    }

    return lines;
  }

  /// Detects whether [toolName] represents a file-reading tool.
  static bool isReadFileTool(String toolName) {
    final lower = toolName.toLowerCase();
    return lower == 'fs_read_file' ||
        lower == 'read_file' ||
        lower == 'ssh_read_file' ||
        lower.endsWith('_read_file') ||
        lower.endsWith(':read_file') ||
        lower == 'readfile';
  }

  /// Extracts a target file path from JSON-encoded tool call arguments if present.
  static String? extractFilePath(String argumentsJson) {
    try {
      final decoded = jsonDecode(argumentsJson);
      if (decoded is Map) {
        return (decoded['path'] ??
                decoded['file'] ??
                decoded['filePath'] ??
                decoded['targetPath'] ??
                decoded['filename'] ??
                decoded['uri'])
            ?.toString();
      }
    } catch (_) {}
    return null;
  }

  /// Print a formatted tool call card (matches mcp_cli_example).
  /// When [compact] is true and tool is a file-reading tool, file content is hidden,
  /// displaying only the target file path and line count.
  static void printToolCall({
    required String toolName,
    required String argumentsJson,
    required String result,
    bool compact = false,
  }) {
    final isRead = isReadFileTool(toolName);
    var filePath = isRead ? extractFilePath(argumentsJson) : null;

    stdout.writeln(yellow('┌─ TOOL CALL ──────────────────────────────────────────────'));
    stdout.writeln('${yellow("│")} ${bold("Tool   :")} ${cyan(toolName)}');
    if (compact && isRead && filePath != null) {
      stdout.writeln('${yellow("│")} ${bold("File   :")} $filePath');
    } else {
      stdout.writeln('${yellow("│")} ${bold("Args   :")} $argumentsJson');
    }
    stdout.writeln(yellow('├─ RESULT ─────────────────────────────────────────────────'));

    if (compact && isRead) {
      final trimmedResult = result.trim();
      final isError = trimmedResult.toLowerCase().startsWith('error') ||
          trimmedResult.toLowerCase().startsWith('failed') ||
          trimmedResult.toLowerCase().startsWith('exception') ||
          trimmedResult.contains('not found');

      if (isError) {
        stdout.writeln('${yellow("│")} ${red(trimmedResult)}');
      } else {
        int? lineCount;
        int? byteCount;
        try {
          final resJson = jsonDecode(result);
          if (resJson is Map) {
            filePath ??= resJson['path']?.toString();
            if (resJson.containsKey('bytes')) {
              byteCount = resJson['bytes'] as int?;
            }
            if (resJson.containsKey('content') && resJson['content'] is String) {
              lineCount = (resJson['content'] as String).split('\n').length;
            }
          }
        } catch (_) {}

        lineCount ??= result.split('\n').length;
        final fileDisplay = filePath != null ? cyan(filePath) : 'file';
        final countInfo = byteCount != null
            ? '$lineCount lines, $byteCount bytes'
            : '$lineCount lines';
        stdout.writeln('${yellow("│")} Read $fileDisplay ($countInfo)');
      }
    } else {
      final lines = result.split('\n');
      for (final line in lines.take(20)) {
        stdout.writeln('${yellow("│")} $line');
      }
      if (lines.length > 20) {
        stdout.writeln('${yellow("│")} ${dim("... (${lines.length} lines total)")}');
      }
    }
    stdout.writeln(yellow('└──────────────────────────────────────────────────────────'));
  }

  /// Render a list of [ChatMessage] as if they were entered in the live REPL.
  /// Replays conversation without making any LLM or external calls.
  static void renderSessionHistory(
    List<ChatMessage> messages, {
    String mode = 'code',
    bool compact = true,
  }) {
    if (messages.isEmpty) return;

    int i = 0;
    while (i < messages.length) {
      final msg = messages[i];

      if (msg.role == ChatRole.user) {
        final prefix = '[$mode] > ';
        stdout.write(cyan(prefix));
        stdout.writeln(msg.content);
        i++;
      } else if (msg.role == ChatRole.assistant &&
          msg.type == MessageType.toolCall) {
        // Paired tool call + tool response
        String resultText = '';
        if (i + 1 < messages.length && messages[i + 1].role == ChatRole.tool) {
          final next = messages[i + 1];
          resultText = next.toolResult != null
              ? next.toolResult!.content.map((c) => c.text ?? '').join('\n')
              : next.content;
          i++; // Consume tool response
        }
        printToolCall(
          toolName: msg.toolName ?? 'tool',
          argumentsJson: jsonEncode(msg.toolArguments ?? {}),
          result: resultText,
          compact: compact,
        );
        i++;
      } else if (msg.role == ChatRole.tool) {
        // Standalone tool result (e.g. from markdown session import)
        final resultText = msg.toolResult != null
            ? msg.toolResult!.content.map((c) => c.text ?? '').join('\n')
            : msg.content;
        printToolCall(
          toolName: msg.toolName ?? 'tool',
          argumentsJson: msg.toolArguments != null
              ? jsonEncode(msg.toolArguments)
              : '{}',
          result: resultText,
          compact: compact,
        );
        i++;
      } else if (msg.role == ChatRole.assistant) {
        final content = msg.content.trim();
        if (content.isNotEmpty) {
          stdout.writeln('');
          stdout.writeln(content);
          stdout.writeln('');
        }
        i++;
      } else {
        // Skip system or unrecognized message types
        i++;
      }
    }
  }

  /// Print a table of data with headers.
  static void printTable({
    required List<String> headers,
    required List<List<String>> rows,
  }) {
    if (headers.isEmpty) return;

    final colWidths = List<int>.generate(headers.length, (i) => headers[i].length);
    for (final row in rows) {
      for (int i = 0; i < row.length && i < colWidths.length; i++) {
        if (row[i].length > colWidths[i]) {
          colWidths[i] = row[i].length;
        }
      }
    }

    String formatRow(List<String> cols, {bool isHeader = false}) {
      final cells = <String>[];
      for (int i = 0; i < headers.length; i++) {
        final val = i < cols.length ? cols[i] : '';
        final pad = ' ' * (colWidths[i] - val.length);
        cells.add(isHeader ? bold(val) + pad : val + pad);
      }
      return cells.join('   ');
    }

    stdout.writeln(formatRow(headers, isHeader: true));
    stdout.writeln(colWidths.map((w) => '─' * w).join('   '));
    for (final row in rows) {
      stdout.writeln(formatRow(row));
    }
    stdout.writeln('');
  }
}
