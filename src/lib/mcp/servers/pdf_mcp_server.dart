import 'dart:convert';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../internal_mcp_server.dart';

class PdfMcpServer extends InternalMcpServer {
  @override
  String get type => 'pdf';

  @override
  String get displayName => 'Pdf generator';

  @override
  String get description => 'Create PDF files from text, HTML-like text, or PNG image (base64).';

  @override
  String get iconName => 'picture_as_pdf';

  @override
  Map<String, dynamic> get initParamSchema => {'type': 'object', 'properties': {}, 'required': []};

  @override
  Map<String, dynamic> get defaultInitParams => const {};

  @override
  String get defaultSystemPrompt =>
      'Use create_pdf to generate a PDF from text, HTML text, or base64 PNG image. '
      'Set orientation (portrait/landscape), page size (A4/A3/A2), scaling (25-100), and optional file name.';

  @override
  Future<void> initialize(Map<String, dynamic> initParams) async {}

  @override
  List<McpToolDescriptor> get tools => [
    const McpToolDescriptor(
      name: 'create_pdf',
      description: 'Create a PDF from plain text, HTML text, or base64 PNG image source.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'source': {'type': 'string', 'description': 'Source content. For image sourceType, pass base64 PNG or data URI.'},
          'sourceType': {
            'type': 'string',
            'enum': ['text', 'html', 'image_base64'],
            'default': 'text',
            'description': 'Input source type.',
          },
          'orientation': {
            'type': 'string',
            'enum': ['portrait', 'landscape'],
            'default': 'portrait',
            'description': 'Page orientation.',
          },
          'page': {
            'type': 'string',
            'enum': ['A4', 'A3', 'A2'],
            'default': 'A4',
            'description': 'Page format.',
          },
          'scaling': {'type': 'integer', 'default': 100, 'description': 'Scale percentage for rendered content (25-100).'},
          'fileName': {'type': 'string', 'description': 'Optional output file name (without or with .pdf).'},
          'title': {'type': 'string', 'description': 'Optional title rendered on top for text/html source.'},
        },
        'required': ['source'],
      },
    ),
    const McpToolDescriptor(
      name: 'generate_pdf',
      description:
          'Convert an HTML document to a PDF file. Preserves tables, headings, lists and paragraphs. '
          'Works on all platforms (Android, iOS, Windows, Linux, macOS).',
      inputSchema: {
        'type': 'object',
        'properties': {
          'content': {'type': 'string', 'description': 'Full HTML content to render as PDF.'},
          'format': {
            'type': 'string',
            'enum': ['A2', 'A3', 'A4', 'A5', 'Letter', 'Legal', 'Tabloid'],
            'default': 'A4',
            'description': 'Page format.',
          },
          'landscape': {'type': 'boolean', 'default': false, 'description': 'Use landscape orientation.'},
          'printBackground': {'type': 'boolean', 'default': true, 'description': 'Hint to print backgrounds (visual only).'},
          'scale': {'type': 'number', 'default': 1.0, 'description': 'Content scale factor (0.5–2.0).'},
        },
        'required': ['content'],
      },
    ),
  ];

  @override
  Future<Map<String, dynamic>> executeTool(String toolName, Map<String, dynamic> arguments) async {
    switch (toolName) {
      case 'create_pdf':
        return _createPdf(arguments);
      case 'generate_pdf':
        return _generatePdf(arguments);
      default:
        return {'error': 'Unknown tool: $toolName'};
    }
  }

  Future<Map<String, dynamic>> _createPdf(Map<String, dynamic> args) async {
    final source = (args['source'] as String?)?.trim();
    if (source == null || source.isEmpty) {
      return {'error': 'Parameter "source" is required.'};
    }

    final sourceType = (args['sourceType'] as String? ?? 'text').trim().toLowerCase();
    final orientation = (args['orientation'] as String? ?? 'portrait').trim().toLowerCase();
    final page = (args['page'] as String? ?? 'A4').trim().toUpperCase();
    final scaling = ((args['scaling'] as num?)?.toInt() ?? 100).clamp(25, 100);
    final title = (args['title'] as String?)?.trim();

    final fileName = _normalizePdfFileName((args['fileName'] as String?)?.trim());

    final doc = pw.Document();
    final pageFormat = _resolvePageFormat(page, orientation);

    try {
      if (sourceType == 'image_base64') {
        final bytes = _decodeBase64(source);
        if (bytes == null || bytes.isEmpty) {
          return {'error': 'Invalid base64 image source.'};
        }

        final memoryImage = pw.MemoryImage(bytes);
        final widthFactor = scaling / 100.0;

        doc.addPage(
          pw.Page(
            pageFormat: pageFormat,
            margin: const pw.EdgeInsets.all(24),
            build: (context) {
              final maxWidth = context.page.pageFormat.availableWidth * widthFactor;
              return pw.Center(
                child: pw.Image(memoryImage, fit: pw.BoxFit.contain, width: maxWidth),
              );
            },
          ),
        );
      } else {
        final rawText = sourceType == 'html' ? _htmlToPlainText(source) : source;
        final fontScale = scaling / 100.0;

        // Split into paragraphs so MultiPage can paginate between them.
        // A single pw.Text taller than one page throws a "won't fit" error.
        final paragraphs = rawText.split(RegExp(r'\n{2,}')).map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
        // If there are no double-newlines, split by single newline instead to
        // still get line-level pagination for dense content.
        final blocks = paragraphs.isNotEmpty ? paragraphs : rawText.split('\n').map((l) => l.trim()).toList();

        doc.addPage(
          pw.MultiPage(
            pageFormat: pageFormat,
            margin: const pw.EdgeInsets.all(24),
            build: (context) => [
              if (title != null && title.isNotEmpty) ...[
                pw.Text(
                  title,
                  style: pw.TextStyle(fontSize: 18 * fontScale, fontWeight: pw.FontWeight.bold),
                ),
                pw.SizedBox(height: 10),
              ],
              for (final block in blocks) ...[
                pw.Text(block, style: pw.TextStyle(fontSize: 12 * fontScale)),
                pw.SizedBox(height: 6 * fontScale),
              ],
            ],
          ),
        );
      }

      final pdfBytes = await doc.save();
      return {
        'success': true,
        'message': 'PDF created successfully.',
        'fileName': fileName,
        'mimeType': 'application/pdf',
        'encoding': 'base64',
        'size': pdfBytes.length,
        'content': base64Encode(pdfBytes),
      };
    } catch (e) {
      return {'error': 'Failed to create PDF: $e'};
    }
  }

  // ─── generate_pdf ─────────────────────────────────────────────────────────

  /// HTML → PDF using the Dart pdf package (all platforms, no Puppeteer needed).
  /// Handles headings, tables, ordered/unordered lists, paragraphs and plain text.
  Future<Map<String, dynamic>> _generatePdf(Map<String, dynamic> args) async {
    final content = (args['content'] as String?)?.trim();
    if (content == null || content.isEmpty) {
      return {'error': 'Parameter "content" is required.'};
    }

    final format = (args['format'] as String? ?? 'A4').trim();
    final landscape = (args['landscape'] as bool?) ?? false;
    final scale = ((args['scale'] as num?)?.toDouble() ?? 1.0).clamp(0.5, 2.0);
    final orientation = landscape ? 'landscape' : 'portrait';
    final pageFormat = _resolvePageFormat(format, orientation);

    try {
      final doc = pw.Document();
      final widgets = _htmlToPdfWidgets(content, scale);

      doc.addPage(pw.MultiPage(pageFormat: pageFormat, margin: const pw.EdgeInsets.all(20), build: (context) => widgets));

      final pdfBytes = await doc.save();
      // Do NOT include 'fileName' here so the adapter returns a single blob
      // content item (no text-metadata prefix), keeping result.content.first.data valid.
      return {
        'success': true,
        'message': 'PDF generated successfully.',
        'mimeType': 'application/pdf',
        'encoding': 'base64',
        'size': pdfBytes.length,
        'content': base64Encode(pdfBytes),
      };
    } catch (e) {
      return {'error': 'Failed to generate PDF: $e'};
    }
  }

  // ─── HTML → pdf widgets parser ─────────────────────────────────────────────

  List<pw.Widget> _htmlToPdfWidgets(String html, double scale) {
    // Strip head, scripts, styles — they have no meaning in a print PDF.
    var cleaned = html
        .replaceAll(RegExp(r'<head\b[^>]*>[\s\S]*?</head>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<script\b[^>]*>[\s\S]*?</script>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<style\b[^>]*>[\s\S]*?</style>', caseSensitive: false), '');

    // Extract body content when the document includes a <body> tag.
    final bodyMatch = RegExp(r'<body\b[^>]*>([\s\S]*?)</body>', caseSensitive: false).firstMatch(cleaned);
    var remaining = (bodyMatch?.group(1) ?? cleaned).trim();

    final result = <pw.Widget>[];

    while (remaining.isNotEmpty) {
      remaining = remaining.trim();
      if (remaining.isEmpty) break;

      // ── <table> ────────────────────────────────────────────────────────────
      // Each row is added as a separate widget so MultiPage can distribute
      // rows across pages without hitting the SpanningWidget constraint.
      if (RegExp(r'^<table\b', caseSensitive: false).hasMatch(remaining)) {
        final end = _findClosingTagEnd(remaining, 'table');
        if (end > 0) {
          final tableHtml = remaining.substring(0, end);
          final rowWidgets = _renderHtmlTableRows(tableHtml, scale);
          result.addAll(rowWidgets);
          if (rowWidgets.isNotEmpty) result.add(pw.SizedBox(height: 8));
          remaining = remaining.substring(end);
          continue;
        }
      }

      // ── <h1>…<h6> ─────────────────────────────────────────────────────────
      final headingMatch = RegExp(r'^<(h[1-6])\b[^>]*>([\s\S]*?)</\1>', caseSensitive: false).firstMatch(remaining);
      if (headingMatch != null && headingMatch.start == 0) {
        final level = headingMatch.group(1)!;
        final text = _stripInlineTags(headingMatch.group(2)!);
        if (text.isNotEmpty) {
          result.add(
            pw.Text(
              text,
              style: pw.TextStyle(fontSize: _headingFontPt(level, scale), fontWeight: pw.FontWeight.bold, color: PdfColors.blueGrey800),
            ),
          );
          result.add(pw.SizedBox(height: 6));
        }
        remaining = remaining.substring(headingMatch.end);
        continue;
      }

      // ── <ul> / <ol> ────────────────────────────────────────────────────────
      final listMatch = RegExp(r'^<(ul|ol)\b[^>]*>([\s\S]*?)</\1>', caseSensitive: false).firstMatch(remaining);
      if (listMatch != null && listMatch.start == 0) {
        final isOrdered = listMatch.group(1)!.toLowerCase() == 'ol';
        final itemMatches = RegExp(r'<li\b[^>]*>([\s\S]*?)</li>', caseSensitive: false).allMatches(listMatch.group(2)!).toList();
        var idx = 0;
        for (final item in itemMatches) {
          idx++;
          final text = _stripInlineTags(item.group(1)!);
          result.add(
            pw.Padding(
              padding: const pw.EdgeInsets.only(left: 16),
              child: pw.Text('${isOrdered ? '$idx.' : '•'} $text', style: pw.TextStyle(fontSize: 10 * scale)),
            ),
          );
          result.add(pw.SizedBox(height: 2));
        }
        result.add(pw.SizedBox(height: 6));
        remaining = remaining.substring(listMatch.end);
        continue;
      }

      // ── <p> / <div> ────────────────────────────────────────────────────────
      final blockMatch = RegExp(r'^<(p|div)\b[^>]*>([\s\S]*?)</\1>', caseSensitive: false).firstMatch(remaining);
      if (blockMatch != null && blockMatch.start == 0) {
        final text = _stripInlineTags(blockMatch.group(2)!).trim();
        if (text.isNotEmpty) {
          result.add(pw.Text(text, style: pw.TextStyle(fontSize: 10 * scale)));
          result.add(pw.SizedBox(height: 4));
        }
        remaining = remaining.substring(blockMatch.end);
        continue;
      }

      // ── <br> ──────────────────────────────────────────────────────────────
      if (RegExp(r'^<br\s*/?>', caseSensitive: false).hasMatch(remaining)) {
        result.add(pw.SizedBox(height: 4));
        remaining = remaining.replaceFirst(RegExp(r'^<br\s*/?>', caseSensitive: false), '');
        continue;
      }

      // ── Unknown/unparseable opening tag — skip past "> " ──────────────────
      if (remaining.startsWith('<')) {
        final tagEnd = remaining.indexOf('>');
        if (tagEnd >= 0) {
          remaining = remaining.substring(tagEnd + 1);
          continue;
        }
        break; // Malformed tag, give up on remainder.
      }

      // ── Plain text up to next tag ──────────────────────────────────────────
      final nextTag = remaining.indexOf('<');
      final text = (nextTag > 0 ? remaining.substring(0, nextTag) : remaining)
          .replaceAll('&nbsp;', ' ')
          .replaceAll('&amp;', '&')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&quot;', '"')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (text.isNotEmpty) {
        result.add(pw.Text(text, style: pw.TextStyle(fontSize: 10 * scale)));
        result.add(pw.SizedBox(height: 4));
      }
      remaining = nextTag > 0 ? remaining.substring(nextTag) : '';
    }

    return result.isEmpty ? [pw.Text('')] : result;
  }

  /// Returns the index in [html] one character past the closing tag that
  /// balances the first opening `<tagName>` in [html].
  /// Returns -1 if the matching closing tag is not found.
  int _findClosingTagEnd(String html, String tagName) {
    final pattern = RegExp('<(/?${RegExp.escape(tagName)})\\b[^>]*>', caseSensitive: false);
    int depth = 0;
    for (final m in pattern.allMatches(html)) {
      if (m.group(1)!.startsWith('/')) {
        if (--depth == 0) return m.end;
      } else {
        depth++;
      }
    }
    return -1;
  }

  /// Renders a `<table>` HTML block as a list of individual row widgets.
  /// Returning one widget per row lets [pw.MultiPage] place rows on different
  /// pages without hitting the "widget won't fit" constraint.
  List<pw.Widget> _renderHtmlTableRows(String tableHtml, double scale) {
    final fontSize = 9.0 * scale;
    final rowMatches = RegExp(r'<tr\b[^>]*>([\s\S]*?)</tr>', caseSensitive: false).allMatches(tableHtml).toList();
    if (rowMatches.isEmpty) return [];

    // Determine max column count.
    int maxCols = 0;
    for (final row in rowMatches) {
      final count = RegExp(r'<t[hd]\b', caseSensitive: false).allMatches(row.group(1)!).length;
      if (count > maxCols) maxCols = count;
    }
    if (maxCols == 0) return [];

    final result = <pw.Widget>[];
    int rowIndex = 0;

    for (final rowMatch in rowMatches) {
      final rowHtml = rowMatch.group(1)!;
      final isHeader = RegExp(r'<th\b', caseSensitive: false).hasMatch(rowHtml);
      final isOdd = rowIndex.isOdd;

      final cellMatches = RegExp(r'<t[hd]\b[^>]*>([\s\S]*?)</t[hd]>', caseSensitive: false).allMatches(rowHtml).toList();
      final cells = cellMatches.map((m) => _stripInlineTags(m.group(1)!).trim()).toList();
      while (cells.length < maxCols) {
        cells.add('');
      }

      result.add(
        pw.Container(
          decoration: pw.BoxDecoration(
            color: isHeader ? PdfColors.blueGrey700 : (isOdd ? PdfColors.grey200 : null),
            border: pw.Border.all(color: PdfColors.grey400, width: 0.5),
          ),
          child: pw.Row(
            children: List.generate(maxCols, (i) {
              return pw.Expanded(
                child: pw.Container(
                  padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                  decoration: i > 0
                      ? const pw.BoxDecoration(
                          border: pw.Border(left: pw.BorderSide(color: PdfColors.grey400, width: 0.5)),
                        )
                      : null,
                  child: pw.Text(
                    i < cells.length ? cells[i] : '',
                    style: pw.TextStyle(
                      fontSize: fontSize,
                      fontWeight: isHeader ? pw.FontWeight.bold : pw.FontWeight.normal,
                      color: isHeader ? PdfColors.white : PdfColors.black,
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      );
      rowIndex++;
    }

    return result;
  }

  double _headingFontPt(String tag, double scale) {
    switch (tag.toLowerCase()) {
      case 'h1':
        return 18 * scale;
      case 'h2':
        return 15 * scale;
      case 'h3':
        return 13 * scale;
      case 'h4':
        return 12 * scale;
      case 'h5':
        return 11 * scale;
      case 'h6':
        return 10 * scale;
      default:
        return 12 * scale;
    }
  }

  String _stripInlineTags(String html) {
    return html
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .trim();
  }

  // ─── resolve page format ──────────────────────────────────────────────────

  PdfPageFormat _resolvePageFormat(String page, String orientation) {
    PdfPageFormat base;
    switch (page) {
      case 'A2':
        base = PdfPageFormat(420 * PdfPageFormat.mm, 594 * PdfPageFormat.mm);
        break;
      case 'A3':
        base = PdfPageFormat.a3;
        break;
      case 'A5':
        base = PdfPageFormat.a5;
        break;
      case 'Letter':
        base = PdfPageFormat.letter;
        break;
      case 'Legal':
        base = PdfPageFormat.legal;
        break;
      case 'Tabloid':
        // 11 × 17 inches
        base = PdfPageFormat(11 * PdfPageFormat.inch, 17 * PdfPageFormat.inch);
        break;
      case 'A4':
      default:
        base = PdfPageFormat.a4;
        break;
    }

    return orientation == 'landscape' ? base.landscape : base;
  }

  Uint8List? _decodeBase64(String value) {
    final payload = value.contains(',') ? value.split(',').last : value;
    try {
      return base64Decode(payload);
    } catch (_) {
      return null;
    }
  }

  String _htmlToPlainText(String html) {
    var text = html;
    text = text.replaceAll(RegExp(r'<script.*?>.*?</script>', caseSensitive: false, dotAll: true), ' ');
    text = text.replaceAll(RegExp(r'<style.*?>.*?</style>', caseSensitive: false, dotAll: true), ' ');
    text = text.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</p>|</div>|</li>|</h[1-6]>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'<[^>]+>', dotAll: true), ' ');
    text = text.replaceAll('&nbsp;', ' ');
    text = text.replaceAll('&amp;', '&');
    text = text.replaceAll('&lt;', '<');
    text = text.replaceAll('&gt;', '>');
    text = text.replaceAll(RegExp(r'[ \t]+'), ' ');
    text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return text.trim();
  }

  String _normalizePdfFileName(String? value) {
    final base = (value == null || value.isEmpty) ? 'generated_document' : value;
    return base.toLowerCase().endsWith('.pdf') ? base : '$base.pdf';
  }
}
