import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../config/cli_config.dart';
import '../config/global_config.dart';
import '../formatters/terminal_printer.dart';
import 'cli_attachment_helper.dart';
import 'cli_clipboard_helper.dart';

/// Reads multi-line and single-line user input from the terminal with support for
/// command history (Up/Down arrows), Ctrl-Enter submission, inline `/paste` clipboard expansion.
class CliPromptReader {
  static final List<String> _history = [];
  static bool _historyLoaded = false;

  /// Loads persistent command history from ~/.thiescoder/command_history.txt
  static void _ensureHistoryLoaded() {
    if (_historyLoaded) return;
    _historyLoaded = true;
    try {
      final file = File(p.join(GlobalConfigLocator.globalDir, 'command_history.txt'));
      if (file.existsSync()) {
        final lines = file.readAsLinesSync();
        for (final line in lines) {
          final t = line.trim();
          if (t.isNotEmpty && (_history.isEmpty || _history.last != t)) {
            _history.add(t);
          }
        }
      }
    } catch (_) {}
  }

  /// Appends command to memory and persists to ~/.thiescoder/command_history.txt
  static void _saveToHistory(String entry) {
    final t = entry.trim();
    if (t.isEmpty) return;
    _ensureHistoryLoaded();
    if (_history.isEmpty || _history.last != t) {
      _history.add(t);
      try {
        final file = File(p.join(GlobalConfigLocator.globalDir, 'command_history.txt'));
        if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
        final toSave = _history.length > 500
            ? _history.sublist(_history.length - 500)
            : _history;
        file.writeAsStringSync('${toSave.join('\n')}\n');
      } catch (_) {}
    }
  }

  /// Reads a prompt from the user.
  ///
  /// In multi-line mode (`config.multilinePrompt`):
  /// - Pressing `Enter` adds a newline and displays the continuation prefix `... `
  /// - Pressing `Ctrl-Enter` (or `Ctrl-D`, `Ctrl-J`) submits the multi-line prompt.
  /// - Pressing `Ctrl-C` cancels the current prompt.
  ///
  /// In single-line mode:
  /// - Pressing `Enter` submits immediately (or line ending with `\` continues).
  ///
  /// Automatically resolves inline `/paste` and `/paste image` directives from the clipboard.
  static Future<String?> readPrompt({
    required String promptPrefix,
    required CliConfig config,
    required List<CliAttachment> stagedAttachments,
    String? workspaceDir,
  }) async {
    // Ensure clean terminal state before prompting
    if (stdin.hasTerminal) {
      try {
        if (!stdin.lineMode) stdin.lineMode = true;
        if (!stdin.echoMode) stdin.echoMode = true;
      } catch (_) {}
    }

    stdout.write(TerminalPrinter.cyan(promptPrefix));

    final fullText = _readLineModeInput(config);
    if (fullText == null) return null;

    final trimmed = fullText.trim();
    if (trimmed.isEmpty) return '';

    _saveToHistory(trimmed);

    // Check for inline /paste and /paste image in prompt
    return await resolveInlineClipboard(
      trimmed,
      stagedAttachments: stagedAttachments,
      workspaceDir: workspaceDir,
    );
  }

  /// Line-mode reader using standard native terminal input.
  /// Preserves native Windows/PowerShell history (Up/Down arrows), backspace, and cursor editing.
  ///
  /// Multi-line behaviors:
  /// 1. Line ending with `\` continues directly to the next line (`... `).
  /// 2. Line starting with `"""` continues until closing `"""`.
  /// 3. If `config.multilinePrompt` is true, pressing Enter on a non-slash command
  ///    prompts `  ↳ [Enter/e: execute | c: continue] > `:
  ///    - Pressing Enter or `e` executes the prompt immediately.
  ///    - Typing `c` allows adding more lines with `... `.
  ///    - Typing additional text directly appends it to the prompt.
  static String? _readLineModeInput(CliConfig config) {
    final firstLine = stdin.readLineSync(encoding: utf8);
    if (firstLine == null) return null;

    final trimmedFirst = firstLine.trim();
    if (trimmedFirst.isEmpty) return '';

    // Slash commands always execute immediately without confirmation
    if (_isSlashCommand(firstLine)) {
      return trimmedFirst;
    }

    // Trailing backslash '\' indicates explicit line continuation
    if (firstLine.endsWith('\\')) {
      return _readBackslashContinuation(firstLine);
    }

    // Triple-quote multi-line block
    if (trimmedFirst.startsWith('"""')) {
      return _readTripleQuoteBlock(trimmedFirst);
    }

    // If multilinePrompt is enabled, prompt user to continue or execute
    if (config.multilinePrompt) {
      stdout.write(TerminalPrinter.dim('  ↳ [Enter/e: execute | c: continue] > '));
      final choice = stdin.readLineSync(encoding: utf8);
      if (choice == null) return trimmedFirst;

      final trimmedChoice = choice.trim().toLowerCase();

      // Enter (empty) or 'e'/'execute' -> execute firstLine
      if (trimmedChoice.isEmpty ||
          trimmedChoice == 'e' ||
          trimmedChoice == 'exec' ||
          trimmedChoice == 'execute') {
        return trimmedFirst;
      }

      // 'c' or 'continue' -> enter multi-line continuation mode
      if (trimmedChoice == 'c' || trimmedChoice == 'continue') {
        final buffer = StringBuffer();
        buffer.writeln(firstLine);

        while (true) {
          stdout.write(TerminalPrinter.dim('... '));
          final nextLine = stdin.readLineSync(encoding: utf8);
          if (nextLine == null) break;

          if (nextLine.endsWith('\\')) {
            buffer.writeln(nextLine.substring(0, nextLine.length - 1));
            continue;
          }

          if (nextLine.trim().isEmpty) {
            // Empty line submits
            break;
          }

          buffer.writeln(nextLine);

          stdout.write(TerminalPrinter.dim('  ↳ [Enter/e: execute | c: continue] > '));
          final nextChoice = stdin.readLineSync(encoding: utf8);
          if (nextChoice == null) break;

          final nc = nextChoice.trim().toLowerCase();
          if (nc == 'c' || nc == 'continue') {
            continue;
          } else if (nc.isEmpty || nc == 'e' || nc == 'exec' || nc == 'execute') {
            break;
          } else {
            // User typed text directly at the continuation prompt
            buffer.writeln(nextChoice);
            break;
          }
        }
        return buffer.toString().trimRight();
      }

      // User typed additional text directly at the [Enter/e: execute | c: continue] prompt
      final buffer = StringBuffer();
      buffer.writeln(firstLine);
      buffer.writeln(choice);
      return buffer.toString().trimRight();
    }

    return firstLine;
  }

  static String _readBackslashContinuation(String firstLine) {
    final buffer = StringBuffer();
    buffer.writeln(firstLine.substring(0, firstLine.length - 1));

    while (true) {
      stdout.write(TerminalPrinter.dim('... '));
      final nextLine = stdin.readLineSync(encoding: utf8);
      if (nextLine == null) break;

      if (nextLine.endsWith('\\')) {
        buffer.writeln(nextLine.substring(0, nextLine.length - 1));
      } else {
        buffer.writeln(nextLine);
        break;
      }
    }
    return buffer.toString().trimRight();
  }

  static String _readTripleQuoteBlock(String trimmedFirst) {
    final buffer = StringBuffer();
    var remainder = trimmedFirst.substring(3);
    if (remainder.endsWith('"""') && remainder.length > 3) {
      return remainder.substring(0, remainder.length - 3);
    }
    if (remainder.isNotEmpty) buffer.writeln(remainder);

    while (true) {
      stdout.write(TerminalPrinter.dim('... '));
      final line = stdin.readLineSync(encoding: utf8);
      if (line == null) break;
      if (line.trim().endsWith('"""')) {
        final content = line.trim().substring(0, line.trim().length - 3);
        if (content.isNotEmpty) buffer.writeln(content);
        break;
      }
      buffer.writeln(line);
    }
    return buffer.toString().trimRight();
  }

  /// Scans [prompt] for inline clipboard paste directives like `/paste`, `/paste image`,
  /// or `/paste text`, resolves them from the system clipboard, and stages attachments.
  static Future<String> resolveInlineClipboard(
    String prompt, {
    required List<CliAttachment> stagedAttachments,
    String? workspaceDir,
  }) async {
    var result = prompt;

    // 1. Explicit /paste image or /paste-image
    if (result.contains('/paste image') || result.contains('/paste-image')) {
      final clip = await CliClipboardHelper.getClipboardContent();
      if (clip != null && clip.isImage && clip.imageBytes != null) {
        final att = CliAttachmentHelper.fromBytes(
          bytes: clip.imageBytes!,
          name: 'clipboard_${DateTime.now().millisecondsSinceEpoch}.png',
          path: clip.imagePath ?? 'clipboard.png',
          mimeType: clip.mimeType,
        );
        stagedAttachments.add(att);
        stdout.writeln(
          TerminalPrinter.green('✔ Staged image from clipboard: ${att.name} (${att.sizeLabel})'),
        );
        result = result
            .replaceAll('/paste image', '')
            .replaceAll('/paste-image', '')
            .trim();
      } else {
        stdout.writeln(
          TerminalPrinter.yellow('No image found on system clipboard.'),
        );
        result = result
            .replaceAll('/paste image', '')
            .replaceAll('/paste-image', '')
            .trim();
      }
    }

    // 2. Generic /paste or /paste text
    if (result.contains('/paste') && !result.startsWith('/paste-file')) {
      final clip = await CliClipboardHelper.getClipboardContent();
      if (clip != null) {
        if (clip.isImage && clip.imageBytes != null) {
          final att = CliAttachmentHelper.fromBytes(
            bytes: clip.imageBytes!,
            name: 'clipboard_${DateTime.now().millisecondsSinceEpoch}.png',
            path: clip.imagePath ?? 'clipboard.png',
            mimeType: clip.mimeType,
          );
          stagedAttachments.add(att);
          stdout.writeln(
            TerminalPrinter.green('✔ Staged image from clipboard: ${att.name} (${att.sizeLabel})'),
          );
          result = result.replaceAll('/paste', '').trim();
        } else if (clip.text != null && clip.text!.isNotEmpty) {
          result = result.replaceAll('/paste', clip.text!);
          stdout.writeln(
            TerminalPrinter.green('✔ Inserted ${clip.text!.length} characters from clipboard into prompt.'),
          );
        }
      } else {
        stdout.writeln(TerminalPrinter.yellow('Clipboard is empty.'));
        result = result.replaceAll('/paste', '').trim();
      }
    }

    return result;
  }

  /// Checks whether [text] begins with a known slash command.
  static bool _isSlashCommand(String text) {
    final t = text.trim();
    if (!t.startsWith('/')) return false;
    final cmd = t.split(' ').first.toLowerCase();
    return const {
      '/bye', '/exit', '/quit', '/q',
      '/help', '/?',
      '/about',
      '/multiline',
      '/progressive',
      '/clear', '/cls',
      '/mode',
      '/model', '/llm',
      '/workspace',
      '/ssh',
      '/install', '/uninstall',
      '/mcp', '/mcp_inspect', '/mcp_enable', '/mcp_enable_fnc', '/mcp_reset', '/mcp_reset_fnc',
      '/save', '/save-session', '/load', '/load-session',
      '/compact',
      '/reindex', '/rag',
      '/attach', '/attach-file', '/attach-clipboard', '/attachments',
      '/paste', '/paste-image', '/paste-file',
      '/undo', '/reset', '/stash', '/history',
      '/todos', '/planning',
    }.contains(cmd);
  }
}
