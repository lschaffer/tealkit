import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_code_editor/flutter_code_editor.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/atom-one-light.dart';
import 'package:highlight/languages/bash.dart' as hl_bash;
import 'package:highlight/languages/css.dart' as hl_css;
import 'package:highlight/languages/dart.dart' as hl_dart;
import 'package:highlight/languages/javascript.dart' as hl_js;
import 'package:highlight/languages/json.dart' as hl_json;
import 'package:highlight/languages/markdown.dart' as hl_md;
import 'package:highlight/languages/python.dart' as hl_py;
import 'package:highlight/languages/typescript.dart' as hl_ts;
import 'package:highlight/languages/xml.dart' as hl_xml;
import 'package:highlight/languages/yaml.dart' as hl_yaml;

// ─── Language resolver ─────────────────────────────────────────────────────

/// Maps a language id or file extension string to a highlight grammar object.
/// Returns null for unknown ids (falls back to plain text in CodeField).
dynamic _languageForId(String? id) {
  switch (id?.toLowerCase()) {
    case 'js':
    case 'javascript':
      return hl_js.javascript;
    case 'ts':
    case 'typescript':
      return hl_ts.typescript;
    case 'py':
    case 'python':
      return hl_py.python;
    case 'sh':
    case 'bash':
    case 'shell':
      return hl_bash.bash;
    case 'json':
      return hl_json.json;
    case 'yaml':
    case 'yml':
      return hl_yaml.yaml;
    case 'dart':
      return hl_dart.dart;
    case 'html':
    case 'htm':
    case 'xml':
      return hl_xml.xml;
    case 'css':
      return hl_css.css;
    case 'md':
    case 'markdown':
      return hl_md.markdown;
    default:
      return null; // plain text
  }
}

// ─── CodeEditorField ──────────────────────────────────────────────────────

/// A compact syntax-highlighted code editor that mirrors a [TextEditingController].
///
/// Shows syntax highlighting via `flutter_code_editor`.  A small expand
/// (magnify) button in the top-right corner opens a full-screen dialog with
/// Save / Cancel buttons — ideal for mobile use.
///
/// Two-way sync: edits in the compact view update [controller] immediately;
/// external writes to [controller] (e.g. LLM-generated code) are reflected
/// in the visible code field on the next build.
///
/// ```dart
/// CodeEditorField(
///   controller: _codeCtrl,
///   language: 'js',
///   title: 'JavaScript Code',
/// )
/// ```
class CodeEditorField extends StatefulWidget {
  /// The [TextEditingController] whose text is displayed and edited.
  final TextEditingController controller;

  /// Language id for syntax highlighting: 'js', 'python', 'bash', 'sh',
  /// 'yaml', 'json', 'dart', 'ts', 'html', 'css', 'md'.
  /// Pass null for plain-text (no highlighting).
  final String? language;

  /// Title shown in the fullscreen dialog AppBar.  Defaults to 'Code Editor'.
  final String? title;

  /// Approximate number of visible lines in compact (inline) mode.
  final int previewLines;

  const CodeEditorField({super.key, required this.controller, this.language, this.title, this.previewLines = 12});

  @override
  State<CodeEditorField> createState() => _CodeEditorFieldState();
}

class _CodeEditorFieldState extends State<CodeEditorField> {
  late CodeController _codeCtrl;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _codeCtrl = CodeController(text: widget.controller.text, language: _languageForId(widget.language));
    _codeCtrl.addListener(_onCodeChanged);
    widget.controller.addListener(_onExternalChanged);
  }

  // Internal code controller changed → push to external controller.
  void _onCodeChanged() {
    if (_syncing) return;
    if (widget.controller.text != _codeCtrl.text) {
      _syncing = true;
      widget.controller.text = _codeCtrl.text;
      _syncing = false;
    }
  }

  // External controller changed (e.g. LLM generate) → update code field.
  void _onExternalChanged() {
    if (_syncing) return;
    if (_codeCtrl.text != widget.controller.text) {
      _syncing = true;
      _codeCtrl.text = widget.controller.text;
      _syncing = false;
    }
  }

  @override
  void dispose() {
    _codeCtrl.removeListener(_onCodeChanged);
    widget.controller.removeListener(_onExternalChanged);
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _openFullScreen() async {
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _FullScreenCodeEditorDialog(initialText: _codeCtrl.text, language: widget.language, title: widget.title),
    );
    if (result != null && mounted) {
      // Update both to stay in sync.
      _syncing = true;
      _codeCtrl.text = result;
      widget.controller.text = result;
      _syncing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final codeStyles = isDark ? atomOneDarkTheme : atomOneLightTheme;
    const lineHeight = 20.0;
    final compactHeight = lineHeight * widget.previewLines + 24;

    return Stack(
      children: [
        // ── Code field container ──
        Container(
          height: compactHeight,
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E1E2E) : const Color(0xFFF5F5F5),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: theme.dividerColor),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(7),
            child: CodeTheme(
              data: CodeThemeData(styles: codeStyles),
              child: SingleChildScrollView(
                child: CodeField(
                  controller: _codeCtrl,
                  textStyle: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                  minLines: widget.previewLines,
                ),
              ),
            ),
          ),
        ),

        // ── Expand / magnify button ──
        Positioned(
          top: 4,
          right: 4,
          child: Tooltip(
            message: 'Open fullscreen editor',
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: _openFullScreen,
                child: Container(
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    color: (isDark ? const Color(0xFF2A2A3E) : Colors.white).withValues(alpha: 0.90),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: theme.dividerColor.withValues(alpha: 0.5)),
                  ),
                  child: Icon(Icons.open_in_full, size: 15, color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Full-screen code editor dialog ───────────────────────────────────────────

class _FullScreenCodeEditorDialog extends StatefulWidget {
  final String initialText;
  final String? language;
  final String? title;

  const _FullScreenCodeEditorDialog({required this.initialText, this.language, this.title});

  @override
  State<_FullScreenCodeEditorDialog> createState() => _FullScreenCodeEditorDialogState();
}

class _FullScreenCodeEditorDialogState extends State<_FullScreenCodeEditorDialog> {
  late final CodeController _controller;

  @override
  void initState() {
    super.initState();
    _controller = CodeController(text: widget.initialText, language: _languageForId(widget.language));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final codeStyles = isDark ? atomOneDarkTheme : atomOneLightTheme;

    return Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: Text(widget.title ?? 'Code Editor', style: const TextStyle(fontSize: 15)),
          actions: [
            IconButton(
              icon: const Icon(Icons.copy_all),
              tooltip: 'Copy all',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _controller.text));
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('Copied to clipboard'), duration: Duration(seconds: 1)));
              },
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(null), // Cancel — no changes
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(_controller.text), // Save
              child: Text(
                'Save',
                style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: CodeTheme(
          data: CodeThemeData(styles: codeStyles),
          child: SingleChildScrollView(
            child: CodeField(
              controller: _controller,
              textStyle: const TextStyle(fontFamily: 'monospace', fontSize: 14),
            ),
          ),
        ),
      ),
    );
  }
}
