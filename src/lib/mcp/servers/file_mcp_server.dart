import 'dart:convert';

import '../internal_mcp_server.dart';

class FileMcpServer extends InternalMcpServer {
  @override
  String get type => 'file';

  @override
  String get displayName => 'File output';

  @override
  String get description => 'Create text-based files from source content. Valid HTML becomes .html, markdown becomes .md, otherwise .txt.';

  @override
  String get iconName => 'description';

  @override
  Map<String, dynamic> get initParamSchema => {'type': 'object', 'properties': {}, 'required': []};

  @override
  Map<String, dynamic> get defaultInitParams => const {};

  @override
  String get defaultSystemPrompt =>
      'Use create_text_file to build .html/.md/.txt files from source text. '
      'If HTML is valid create .html, otherwise detect markdown and use .md, else .txt.';

  @override
  Future<void> initialize(Map<String, dynamic> initParams) async {}

  @override
  List<McpToolDescriptor> get tools => [
    const McpToolDescriptor(
      name: 'create_text_file',
      description: 'Create HTML, Markdown, or plain text file from source content.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'source': {'type': 'string', 'description': 'Text content to store in the file.'},
          'fileName': {'type': 'string', 'description': 'Optional file name. Extension is normalized to detected type.'},
          'typeHint': {
            'type': 'string',
            'description': 'Optional type hint to force detection mode.',
            'enum': ['auto', 'html', 'markdown', 'text'],
            'default': 'auto',
          },
        },
        'required': ['source'],
      },
    ),
  ];

  @override
  Future<Map<String, dynamic>> executeTool(String toolName, Map<String, dynamic> arguments) async {
    switch (toolName) {
      case 'create_text_file':
        return _createTextFile(arguments);
      default:
        return {'error': 'Unknown tool: $toolName'};
    }
  }

  Map<String, dynamic> _createTextFile(Map<String, dynamic> args) {
    final source = args['source'] as String?;
    if (source == null || source.trim().isEmpty) {
      return {'error': 'Parameter "source" is required.'};
    }

    var hint = (args['typeHint'] as String? ?? 'auto').trim().toLowerCase();
    final requestedName = (args['fileName'] as String?)?.trim();

    // When typeHint is 'auto', infer from the requested file extension so that
    // e.g. fileName="report.markdown" or "notes.md" forces markdown detection
    // rather than the heuristic falling back to .txt for simple prose.
    if (hint == 'auto' && requestedName != null) {
      final lower = requestedName.toLowerCase();
      if (lower.endsWith('.md') || lower.endsWith('.markdown')) {
        hint = 'markdown';
      } else if (lower.endsWith('.html') || lower.endsWith('.htm')) {
        hint = 'html';
      } else if (lower.endsWith('.txt')) {
        hint = 'text';
      }
    }

    final detectedType = _detectType(source, hint: hint);
    final extension = _extensionForType(detectedType);
    final mimeType = _mimeForType(detectedType);
    final fileName = _normalizeFileName(requestedName, extension);

    final bytes = utf8.encode(source);
    return {
      'success': true,
      'message': 'File created successfully.',
      'detectedType': detectedType,
      'fileName': fileName,
      'mimeType': mimeType,
      'encoding': 'base64',
      'size': bytes.length,
      'content': base64Encode(bytes),
    };
  }

  String _detectType(String source, {required String hint}) {
    switch (hint) {
      case 'html':
        return _isValidHtml(source) ? 'html' : (_looksLikeMarkdown(source) ? 'markdown' : 'text');
      case 'markdown':
        return 'markdown';
      case 'text':
        return 'text';
      case 'auto':
      default:
        if (_isValidHtml(source)) return 'html';
        if (_looksLikeMarkdown(source)) return 'markdown';
        return 'text';
    }
  }

  bool _isValidHtml(String source) {
    final text = source.trim();
    if (text.isEmpty) return false;

    final hasHtmlEnvelope = RegExp(
      r'^\s*(<!doctype\s+html[^>]*>\s*)?<html\b[^>]*>.*</html>\s*$',
      caseSensitive: false,
      dotAll: true,
    ).hasMatch(text);
    final hasMeaningfulTag = RegExp(
      r'<(head|body|div|p|h[1-6]|span|ul|ol|li|table|section|article)\b',
      caseSensitive: false,
      dotAll: true,
    ).hasMatch(text);
    if (!hasHtmlEnvelope && !hasMeaningfulTag) return false;

    return _hasBalancedTags(text);
  }

  bool _hasBalancedTags(String html) {
    final tagRegex = RegExp(r'<\s*(/)?\s*([a-zA-Z][a-zA-Z0-9]*)\b[^>]*?(\/?)\s*>', caseSensitive: false, dotAll: true);
    final ignored = <String>{'br', 'hr', 'img', 'meta', 'input', 'link', 'source', 'track', 'wbr', 'area', 'base', 'col', 'embed', 'param'};

    final stack = <String>[];

    for (final match in tagRegex.allMatches(html)) {
      final closing = (match.group(1) ?? '').isNotEmpty;
      final name = (match.group(2) ?? '').toLowerCase();
      final selfClosing = (match.group(3) ?? '').isNotEmpty || ignored.contains(name);

      if (name == '!' || name.startsWith('?')) continue;
      if (selfClosing) continue;

      if (!closing) {
        stack.add(name);
      } else {
        if (stack.isEmpty) return false;
        final last = stack.removeLast();
        if (last != name) return false;
      }
    }

    return stack.isEmpty;
  }

  bool _looksLikeMarkdown(String source) {
    final text = source.trim();
    if (text.isEmpty) return false;

    final checks = <RegExp>[
      RegExp(r'^#{1,6}\s+.+$', multiLine: true),
      RegExp(r'^\s*[-*+]\s+.+$', multiLine: true),
      RegExp(r'^\s*\d+\.\s+.+$', multiLine: true),
      RegExp(r'^\s*>\s+.+$', multiLine: true),
      RegExp(r'```.+```', dotAll: true),
      RegExp(r'\[[^\]]+\]\([^\)]+\)'),
      RegExp(r'^\|.+\|$', multiLine: true),
    ];

    return checks.any((regex) => regex.hasMatch(text));
  }

  String _extensionForType(String type) {
    switch (type) {
      case 'html':
        return 'html';
      case 'markdown':
        return 'md';
      case 'text':
      default:
        return 'txt';
    }
  }

  String _mimeForType(String type) {
    switch (type) {
      case 'html':
        return 'text/html';
      case 'markdown':
        return 'text/markdown';
      case 'text':
      default:
        return 'text/plain';
    }
  }

  String _normalizeFileName(String? requested, String extension) {
    final fallback = 'generated_file';
    final raw = (requested == null || requested.isEmpty) ? fallback : requested;
    final sanitized = raw.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final base = sanitized.replaceAll(RegExp(r'\.[a-zA-Z0-9]+$'), '');
    return '$base.$extension';
  }
}
