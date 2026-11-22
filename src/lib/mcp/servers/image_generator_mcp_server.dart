import 'package:dart_mcp_core/dart_mcp_core.dart';

import '../internal_mcp_server.dart';

/// Internal MCP server exposing `dart_mcp_core`'s [GenerateImageTool]
/// (`generate_image`) as a selectable built-in tool across TealKit Assistant
/// and Workflows.
class ImageGeneratorMcpServer extends InternalMcpServer {
  final GenerateImageTool _tool = GenerateImageTool();

  @override
  String get type => 'image_generator';

  @override
  String get displayName => 'AI Image Generator';

  @override
  String get description =>
      'Generate images from text prompts using OpenAI (gpt-image-1), '
      'Google Gemini (Nano Banana), DeepInfra FLUX, or custom OpenAI-compatible endpoints.';

  @override
  String get iconName => 'image';

  @override
  Map<String, dynamic> get initParamSchema => const {
    'type': 'object',
    'properties': {
      'model': {
        'type': 'string',
        'description':
            'Optional default image generation model override (e.g. "black-forest-labs/FLUX-1-schnell", "gemini-2.5-flash-image", "gpt-image-1").',
      },
    },
    'required': [],
  };

  @override
  Map<String, dynamic> get defaultInitParams => const {};

  @override
  String get defaultSystemPrompt =>
      'You have access to the generate_image tool to create images from detailed text descriptions '
      'and display them directly in chat. Use generate_image whenever the user asks to create, draw, '
      'paint, illustrate, or generate a picture or image.';

  String _defaultModelOverride = '';

  @override
  Future<void> initialize(Map<String, dynamic> initParams) async {
    _defaultModelOverride = (initParams['model'] as String? ?? '').trim();
  }

  @override
  List<McpToolDescriptor> get tools => [
    McpToolDescriptor(
      name: _tool.name,
      description: _tool.description,
      inputSchema: _tool.inputSchema,
    ),
  ];

  @override
  Future<Map<String, dynamic>> executeTool(
    String toolName,
    Map<String, dynamic> arguments,
  ) async {
    if (toolName != _tool.name) {
      return {'error': 'Unknown tool: $toolName'};
    }
    final args = Map<String, dynamic>.from(arguments);
    if ((args['model'] as String? ?? '').trim().isEmpty &&
        _defaultModelOverride.isNotEmpty) {
      args['model'] = _defaultModelOverride;
    }
    final res = await _tool.execute(args);
    if (res.isError) {
      return {'error': res.text};
    }
    final imageBlock = res.content.where((c) => c.type == 'image').firstOrNull;
    return {
      'success': true,
      'text': res.text,
      if (imageBlock?.data != null) 'imageBase64': imageBlock!.data,
      if (imageBlock?.mimeType != null) 'imageMimeType': imageBlock!.mimeType,
    };
  }
}
