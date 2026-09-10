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

  /// Print a decorative box banner.
  static void printBanner(String title, [List<String> subLines = const []]) {
    const width = 60;
    final top = '╔${'═' * (width - 2)}╗';
    final mid = '╠${'═' * (width - 2)}╣';
    final bot = '╚${'═' * (width - 2)}╝';

    stdout.writeln('');
    stdout.writeln(cyan(top));

    void printLine(String text) {
      final pad = width - 4 - text.length;
      final rightPad = pad > 0 ? ' ' * pad : '';
      stdout.writeln('${cyan("║")} ${bold(text)}$rightPad ${cyan("║")}');
    }

    printLine(title.padLeft((width - 4 + title.length) ~/ 2));

    if (subLines.isNotEmpty) {
      stdout.writeln(cyan(mid));
      for (final line in subLines) {
        final pad = width - 4 - line.length;
        final rightPad = pad > 0 ? ' ' * pad : '';
        stdout.writeln('${cyan("║")} $line$rightPad ${cyan("║")}');
      }
    }

    stdout.writeln(cyan(bot));
    stdout.writeln('');
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
