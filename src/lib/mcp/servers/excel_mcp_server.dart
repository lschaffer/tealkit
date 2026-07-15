import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../internal_mcp_server.dart';

/// Internal MCP server that converts text/CSV/JSON tabular data to Excel .xlsx files.
/// XLSX format is built manually as a ZIP of XML files -- no extra package required.
class ExcelMcpServer extends InternalMcpServer {
  @override
  String get type => 'excel';

  @override
  String get displayName => 'Excel Export';

  @override
  String get description => 'Convert text, CSV or JSON data to a downloadable Excel (.xlsx) file.';

  @override
  String get iconName => 'table_chart';

  @override
  Map<String, dynamic> get initParamSchema => {'type': 'object', 'properties': {}, 'required': []};

  @override
  Map<String, dynamic> get defaultInitParams => const {};

  @override
  String get defaultSystemPrompt =>
      'Use convert_to_excel to turn tabular data (CSV, JSON arrays, or plain text) into a downloadable Excel .xlsx file. '
      'Optionally specify a sheet name. Bold headers are applied automatically when the first row is a header.';

  @override
  Future<void> initialize(Map<String, dynamic> initParams) async {}

  @override
  List<McpToolDescriptor> get tools => [
    const McpToolDescriptor(
      name: 'convert_to_excel',
      description:
          'Convert tabular data (CSV, JSON array of objects, or tab-separated text) to an Excel .xlsx file. '
          'Returns the file as a base64-encoded attachment ready to download.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'data': {
            'type': 'string',
            'description':
                'Tabular data to convert. Accepted formats:\n'
                '- CSV: comma-separated rows, optional header row\n'
                '- TSV: tab-separated rows\n'
                '- JSON: array of objects (each object = one row) or array of arrays\n'
                '- Plain text: rows separated by newlines, cells separated by commas or tabs',
          },
          'fileName': {'type': 'string', 'description': 'Output filename without extension. Defaults to "export".'},
          'sheetName': {'type': 'string', 'description': 'Excel sheet name. Defaults to "Sheet1".'},
          'hasHeader': {
            'type': 'boolean',
            'description': 'Whether the first row is a header (will be rendered bold). Defaults to true.',
            'default': true,
          },
        },
        'required': ['data'],
      },
    ),
  ];

  @override
  Future<Map<String, dynamic>> executeTool(String toolName, Map<String, dynamic> arguments) async {
    switch (toolName) {
      case 'convert_to_excel':
        return _convertToExcel(arguments);
      default:
        return {'error': 'Unknown tool: $toolName'};
    }
  }

  Future<Map<String, dynamic>> _convertToExcel(Map<String, dynamic> args) async {
    final dataStr = args['data'] as String?;
    if (dataStr == null || dataStr.trim().isEmpty) {
      return {'error': 'Parameter "data" is required and must not be empty.'};
    }

    final rawName = ((args['fileName'] as String?) ?? 'export').trim();
    final safeName = rawName.isEmpty ? 'export' : rawName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final sheetName = ((args['sheetName'] as String?) ?? 'Sheet1').trim().isNotEmpty
        ? ((args['sheetName'] as String?) ?? 'Sheet1').trim()
        : 'Sheet1';
    final hasHeader = args['hasHeader'] as bool? ?? true;

    try {
      final rows = _parseData(dataStr.trim());
      if (rows.isEmpty) {
        return {'error': 'Could not parse any data rows from the input.'};
      }

      final bytes = _buildXlsx(rows: rows, sheetName: sheetName, hasHeader: hasHeader);
      final fileName = '$safeName.xlsx';

      return {
        'success': true,
        'message': 'Excel file created: $fileName (${rows.length} row(s), sheet "$sheetName")',
        'fileName': fileName,
        'mimeType': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        'encoding': 'base64',
        'size': bytes.length,
        'data': base64.encode(bytes),
      };
    } catch (e) {
      return {'error': 'Failed to create Excel file: $e'};
    }
  }

  // --- XLSX builder ---

  Uint8List _buildXlsx({required List<List<String>> rows, required String sheetName, required bool hasHeader}) {
    // Build shared strings list (deduplicated)
    final shared = <String>[];
    final sharedIndex = <String, int>{};
    int strIdx(String s) {
      return sharedIndex.putIfAbsent(s, () {
        final idx = shared.length;
        shared.add(s);
        return idx;
      });
    }

    for (final row in rows) {
      for (final cell in row) {
        if (double.tryParse(cell) == null) strIdx(cell);
      }
    }

    // Sheet XML
    final sheetXml = StringBuffer();
    sheetXml.write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>');
    sheetXml.write('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">');
    sheetXml.write('<sheetData>');
    for (int r = 0; r < rows.length; r++) {
      final isBold = hasHeader && r == 0;
      sheetXml.write('<row r="${r + 1}">');
      for (int c = 0; c < rows[r].length; c++) {
        final ref = '${_colLetter(c)}${r + 1}';
        final val = rows[r][c];
        final numVal = double.tryParse(val);
        final s = isBold ? ' s="1"' : '';
        if (numVal != null && val.trim().isNotEmpty) {
          sheetXml.write('<c r="$ref"$s><v>$numVal</v></c>');
        } else {
          sheetXml.write('<c r="$ref" t="s"$s><v>${strIdx(val)}</v></c>');
        }
      }
      sheetXml.write('</row>');
    }
    sheetXml.write('</sheetData></worksheet>');

    // Shared strings XML
    final ssXml = StringBuffer();
    ssXml.write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>');
    ssXml.write(
      '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
      ' count="${shared.length}" uniqueCount="${shared.length}">',
    );
    for (final s in shared) {
      ssXml.write('<si><t>${_xmlEscape(s)}</t></si>');
    }
    ssXml.write('</sst>');

    // Styles XML (index 0 = normal, index 1 = bold)
    const stylesXml =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<fonts count="2">'
        '<font><sz val="11"/><name val="Calibri"/></font>'
        '<font><b/><sz val="11"/><name val="Calibri"/></font>'
        '</fonts>'
        '<fills count="2"><fill><patternFill patternType="none"/></fill>'
        '<fill><patternFill patternType="gray125"/></fill></fills>'
        '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
        '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
        '<cellXfs count="2">'
        '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
        '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>'
        '</cellXfs>'
        '</styleSheet>';

    const workbookXml =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
        ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        '<sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets>'
        '</workbook>';

    const workbookRels =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"'
        ' Target="worksheets/sheet1.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings"'
        ' Target="sharedStrings.xml"/>'
        '<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles"'
        ' Target="styles.xml"/>'
        '</Relationships>';

    const rootRels =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"'
        ' Target="xl/workbook.xml"/>'
        '</Relationships>';

    const contentTypes =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml"'
        ' ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/worksheets/sheet1.xml"'
        ' ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        '<Override PartName="/xl/sharedStrings.xml"'
        ' ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>'
        '<Override PartName="/xl/styles.xml"'
        ' ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
        '</Types>';

    final archive = Archive();
    void addFile(String name, String content) {
      final b = utf8.encode(content);
      archive.addFile(ArchiveFile(name, b.length, b));
    }

    addFile('[Content_Types].xml', contentTypes);
    addFile('_rels/.rels', rootRels);
    addFile('xl/workbook.xml', workbookXml);
    addFile('xl/_rels/workbook.xml.rels', workbookRels);
    addFile('xl/worksheets/sheet1.xml', sheetXml.toString());
    addFile('xl/sharedStrings.xml', ssXml.toString());
    addFile('xl/styles.xml', stylesXml);

    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  String _colLetter(int index) {
    var result = '';
    var n = index;
    do {
      result = String.fromCharCode(65 + (n % 26)) + result;
      n = (n ~/ 26) - 1;
    } while (n >= 0);
    return result;
  }

  String _xmlEscape(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&apos;');

  // --- Data parsing ---

  List<List<String>> _parseData(String data) {
    // 1. Try JSON
    if (data.startsWith('[')) {
      try {
        final parsed = jsonDecode(data) as List;
        if (parsed.isNotEmpty) {
          if (parsed.first is Map) {
            // Array of objects -> derive headers from first object's keys
            final maps = parsed.cast<Map<String, dynamic>>();
            final headers = maps.first.keys.toList();
            final result = <List<String>>[headers.map((h) => h.toString()).toList()];
            for (final rowMap in maps) {
              result.add(headers.map((h) => rowMap[h]?.toString() ?? '').toList());
            }
            return result;
          } else if (parsed.first is List) {
            // Array of arrays
            return parsed.map((r) => (r as List).map((c) => c?.toString() ?? '').toList()).toList();
          }
        }
      } catch (_) {}
    }

    // 2. CSV / TSV: detect delimiter from the first non-empty line
    final lines = data.split(RegExp(r'\r?\n')).where((l) => l.isNotEmpty).toList();
    if (lines.isEmpty) return const [];

    final firstLine = lines.first;
    final tabCount = '\t'.allMatches(firstLine).length;
    final commaCount = ','.allMatches(firstLine).length;
    final delimiter = tabCount > commaCount ? '\t' : ',';

    return lines.map((line) => _splitLine(line, delimiter)).toList();
  }

  /// Split a single CSV/TSV line, respecting double-quoted fields for CSV.
  List<String> _splitLine(String line, String delimiter) {
    if (delimiter == '\t') return line.split('\t').map((c) => c.trim()).toList();

    final cells = <String>[];
    var current = StringBuffer();
    var inQuotes = false;

    for (int i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        // Handle escaped double-quote ("") inside a quoted field
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          current.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
      } else if (ch == ',' && !inQuotes) {
        cells.add(current.toString().trim());
        current = StringBuffer();
      } else {
        current.write(ch);
      }
    }
    cells.add(current.toString().trim());
    return cells;
  }
}
