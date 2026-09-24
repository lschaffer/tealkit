import 'dart:io';

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

  /// Print a formatted tool call card (matches mcp_cli_example).
  static void printToolCall({
    required String toolName,
    required String argumentsJson,
    required String result,
  }) {
    stdout.writeln(yellow('┌─ TOOL CALL ──────────────────────────────────────────────'));
    stdout.writeln('${yellow("│")} ${bold("Tool   :")} ${cyan(toolName)}');
    stdout.writeln('${yellow("│")} ${bold("Args   :")} $argumentsJson');
    stdout.writeln(yellow('├─ RESULT ─────────────────────────────────────────────────'));
    final lines = result.split('\n');
    for (final line in lines.take(20)) {
      stdout.writeln('${yellow("│")} $line');
    }
    if (lines.length > 20) {
      stdout.writeln('${yellow("│")} ${dim("... (${lines.length} lines total)")}');
    }
    stdout.writeln(yellow('└──────────────────────────────────────────────────────────'));
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
