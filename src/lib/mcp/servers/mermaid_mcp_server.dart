import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../services/app_logger.dart';
import '../internal_mcp_server.dart';

class MermaidMcpServer extends InternalMcpServer {
  static const String _defaultRenderUrl = 'https://kroki.io/mermaid/png';

  String _renderUrl = _defaultRenderUrl;
  String _defaultFilePrefix = 'generated_mermaid';

  @override
  String get type => 'mermaid';

  @override
  String get displayName => 'Mermaid diagram';

  @override
  String get description => 'Render Mermaid markdown into PNG diagrams via a free hosted renderer.';

  @override
  String get iconName => 'schema';

  @override
  Map<String, dynamic> get initParamSchema => {
    'type': 'object',
    'properties': {
      'renderUrl': {
        'type': 'string',
        'description': 'Optional Mermaid renderer endpoint. Default: https://kroki.io/mermaid/png',
        'default': _defaultRenderUrl,
      },
      'filePrefix': {
        'type': 'string',
        'description': 'Optional default file name prefix used when no fileName is provided.',
        'default': 'generated_mermaid',
      },
    },
    'required': [],
  };

  @override
  Map<String, dynamic> get defaultInitParams => {'renderUrl': _defaultRenderUrl, 'filePrefix': 'generated_mermaid'};

  @override
  String get defaultSystemPrompt =>
      'Use create_mermaid_png whenever the user requests a diagram (flowchart, sequence, class, gantt, state, ER, journey). '
      'Pass valid Mermaid markdown in the "md" field and optionally set fileName.';

  @override
  Future<void> initialize(Map<String, dynamic> initParams) async {
    final renderUrl = (initParams['renderUrl'] as String?)?.trim();
    final filePrefix = (initParams['filePrefix'] as String?)?.trim();

    if (renderUrl != null && renderUrl.isNotEmpty) {
      _renderUrl = renderUrl;
    }
    if (filePrefix != null && filePrefix.isNotEmpty) {
      _defaultFilePrefix = filePrefix;
    }

    log.info('[Mermaid MCP] Initialized renderUrl=$_renderUrl, filePrefix=$_defaultFilePrefix');
  }

  @override
  List<McpToolDescriptor> get tools => [
    const McpToolDescriptor(
      name: 'create_mermaid_png',
      description: 'Render Mermaid markdown (md) to a PNG image.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'md': {'type': 'string', 'description': 'Mermaid diagram markdown source. Example: graph TD; A-->B;'},
          'fileName': {'type': 'string', 'description': 'Optional target file name. .png is auto-appended when missing.'},
        },
        'required': ['md'],
      },
    ),
  ];

  @override
  Future<Map<String, dynamic>> executeTool(String toolName, Map<String, dynamic> arguments) async {
    switch (toolName) {
      case 'create_mermaid_png':
        return _createMermaidPng(arguments);
      default:
        return {'error': 'Unknown tool: $toolName'};
    }
  }

  Future<Map<String, dynamic>> _createMermaidPng(Map<String, dynamic> args) async {
    final md = (args['md'] as String?)?.trim();
    if (md == null || md.isEmpty) {
      return {'error': 'Parameter "md" is required.'};
    }

    final fileName = _normalizeFileName((args['fileName'] as String?)?.trim());

    try {
      final response = await http.post(
        Uri.parse(_renderUrl),
        headers: const {'Accept': 'image/png', 'Content-Type': 'text/plain; charset=utf-8'},
        body: md,
      );

      // Check if the body is a valid PNG regardless of HTTP status code.
      // Some renderers (e.g. kroki.io) return 400 but still include a PNG body.
      final isPng =
          response.bodyBytes.length > 4 &&
          response.bodyBytes[0] == 0x89 &&
          response.bodyBytes[1] == 0x50 && // P
          response.bodyBytes[2] == 0x4E && // N
          response.bodyBytes[3] == 0x47; // G

      if ((response.statusCode < 200 || response.statusCode >= 300) && !isPng) {
        final body = utf8.decode(response.bodyBytes, allowMalformed: true);
        return {'error': 'Mermaid rendering failed (${response.statusCode}): ${body.isEmpty ? response.reasonPhrase ?? 'unknown' : body}'};
      }

      final pngBytes = response.bodyBytes;
      if (pngBytes.isEmpty) {
        return {'error': 'Mermaid renderer returned an empty PNG response.'};
      }

      final outputPath = await _saveToTemp(fileName, pngBytes);

      return {
        'success': true,
        'message': 'Mermaid PNG generated successfully.',
        'fileName': fileName,
        'mimeType': 'image/png',
        'encoding': 'base64',
        'size': pngBytes.length,
        'content': base64Encode(pngBytes),
        'path': outputPath,
      };
    } catch (e) {
      return {'error': 'Mermaid rendering failed: $e'};
    }
  }

  Future<String> _saveToTemp(String fileName, Uint8List bytes) async {
    final outputDir = Directory('${Directory.systemTemp.path}${Platform.pathSeparator}tealkit_mcp_mermaid');
    if (!await outputDir.exists()) {
      await outputDir.create(recursive: true);
    }
    final outputPath = '${outputDir.path}${Platform.pathSeparator}$fileName';
    await File(outputPath).writeAsBytes(bytes, flush: true);
    return outputPath;
  }

  String _normalizeFileName(String? requested) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final fallback = '$_defaultFilePrefix-$now';
    final raw = (requested == null || requested.isEmpty) ? fallback : requested;
    final sanitized = raw.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return sanitized.toLowerCase().endsWith('.png') ? sanitized : '$sanitized.png';
  }
}
