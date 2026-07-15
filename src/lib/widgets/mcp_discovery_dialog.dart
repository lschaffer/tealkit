import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../config/app_theme.dart';
import '../models/workflow_task.dart';
import '../services/app_logger.dart';

/// Holds full detail for a discovered MCP item (tool, prompt, or resource).
class McpItemDetail {
  final String name;
  final String? description;
  final Map<String, dynamic>? inputSchema; // JSON Schema for parameters
  final Map<String, dynamic>? returnType; // return value schema (if any)
  final Map<String, dynamic> raw; // full raw JSON from server

  const McpItemDetail({required this.name, this.description, this.inputSchema, this.returnType, required this.raw});

  factory McpItemDetail.fromJson(Map<String, dynamic> json) {
    return McpItemDetail(
      name: json['name']?.toString() ?? 'unnamed',
      description: json['description']?.toString(),
      inputSchema: json['inputSchema'] is Map<String, dynamic> ? json['inputSchema'] as Map<String, dynamic> : null,
      returnType: json['returnType'] is Map<String, dynamic> ? json['returnType'] as Map<String, dynamic> : null,
      raw: json,
    );
  }
}

/// Dialog that connects to an MCP server and discovers available
/// tools, prompts, and resources via the MCP protocol.
///
/// Returns an updated [McpToolConfig] with discovered items on success,
/// or `null` if cancelled.
class McpDiscoveryDialog extends ConsumerStatefulWidget {
  final McpToolConfig server;

  const McpDiscoveryDialog({super.key, required this.server});

  @override
  ConsumerState<McpDiscoveryDialog> createState() => _McpDiscoveryDialogState();
}

class _McpDiscoveryDialogState extends ConsumerState<McpDiscoveryDialog> {
  bool _loading = true;
  String? _error;

  List<McpItemDetail> _tools = [];
  List<McpItemDetail> _prompts = [];
  List<McpItemDetail> _resources = [];

  @override
  void initState() {
    super.initState();
    _discover();
  }

  // ─── Discovery logic ──────────────────────────────────

  Future<void> _discover() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final baseUrl = widget.server.serverUrl.replaceAll(RegExp(r'/+$'), '');
      log.info('[MCP Discovery] Starting discovery for: $baseUrl');
      log.verbose('[MCP Discovery] Server name: ${widget.server.name}');
      log.verbose('[MCP Discovery] Spec URL: ${widget.server.specificationUrl}');
      log.verbose('[MCP Discovery] API Key set: ${widget.server.apiKey != null && widget.server.apiKey!.isNotEmpty}');

      final headers = <String, String>{'Content-Type': 'application/json', 'Accept': 'application/json'};

      if (widget.server.apiKey != null && widget.server.apiKey!.isNotEmpty) {
        headers['Authorization'] = 'Bearer ${widget.server.apiKey}';
      }

      // MCP JSON-RPC: POST to a single endpoint with method in the body.
      final endpoint = widget.server.mcpEndpoint ?? '/mcp';
      log.verbose('[MCP Discovery] Endpoint path: $endpoint');
      try {
        _tools = await _fetchItems(baseUrl, endpoint, 'tools/list', 'tools', headers);
      } catch (e) {
        log.warning('[MCP Discovery] tools/list failed: $e');
      }
      try {
        _prompts = await _fetchItems(baseUrl, endpoint, 'prompts/list', 'prompts', headers);
      } catch (e) {
        log.warning('[MCP Discovery] prompts/list failed: $e');
      }
      try {
        _resources = await _fetchItems(baseUrl, endpoint, 'resources/list', 'resources', headers);
      } catch (e) {
        log.warning('[MCP Discovery] resources/list failed: $e');
      }

      if (_tools.isEmpty && _prompts.isEmpty && _resources.isEmpty) {
        // Also try the MCP spec URL if provided
        if (widget.server.specificationUrl != null && widget.server.specificationUrl!.isNotEmpty) {
          await _trySpecificationUrl(widget.server.specificationUrl!, headers);
        }
      }

      log.info('[MCP Discovery] Result: ${_tools.length} tools, ${_prompts.length} prompts, ${_resources.length} resources');
      if (_tools.isNotEmpty) log.verbose('[MCP Discovery] Tools: ${_tools.map((t) => t.name).join(', ')}');
      if (_prompts.isNotEmpty) log.verbose('[MCP Discovery] Prompts: ${_prompts.map((p) => p.name).join(', ')}');
      if (_resources.isNotEmpty) log.verbose('[MCP Discovery] Resources: ${_resources.map((r) => r.name).join(', ')}');

      if (_tools.isEmpty && _prompts.isEmpty && _resources.isEmpty) {
        _error =
            'No tools, prompts, or resources discovered.\n'
            'The server may require authentication or use a different protocol.';
        log.warning('[MCP Discovery] Nothing discovered from $baseUrl');
      }
    } catch (e) {
      log.error('[MCP Discovery] Exception during discovery', e);
      _error = 'Discovery failed: $e';
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  /// Fetch full item details via JSON-RPC POST to the MCP endpoint.
  Future<List<McpItemDetail>> _fetchItems(
    String baseUrl,
    String endpoint,
    String method,
    String arrayKey,
    Map<String, String> headers,
  ) async {
    final uri = Uri.parse('$baseUrl$endpoint');
    try {
      // JSON-RPC POST to the MCP endpoint
      final rpcBody = jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': {}});
      log.verbose('[MCP HTTP] POST $uri  method=$method');
      log.verbose('[MCP HTTP] Body: ${truncate(rpcBody)}');
      final postResp = await http.post(uri, headers: headers, body: rpcBody).timeout(const Duration(seconds: 10));
      log.verbose('[MCP HTTP] POST response: ${postResp.statusCode} body: ${truncate(postResp.body)}');

      if (postResp.statusCode == 200) {
        final parsed = _parseItems(postResp.body, arrayKey);
        if (parsed.isNotEmpty) return parsed;
      }

      // Fallback: plain GET with method as path
      final getUri = Uri.parse('$baseUrl/$method');
      log.verbose('[MCP HTTP] GET fallback $getUri');
      final getResp = await http.get(getUri, headers: headers).timeout(const Duration(seconds: 10));
      log.verbose('[MCP HTTP] GET response: ${getResp.statusCode} body: ${truncate(getResp.body)}');
      if (getResp.statusCode == 200) {
        final parsed = _parseItems(getResp.body, arrayKey);
        if (parsed.isNotEmpty) return parsed;
      }
    } catch (e) {
      log.verbose('[MCP HTTP] $uri method=$method failed: $e');
    }
    return [];
  }

  /// Parse a JSON response body into a list of [McpItemDetail].
  List<McpItemDetail> _parseItems(String body, String arrayKey) {
    final json = jsonDecode(body);
    // JSON-RPC result wrapper
    final result = (json is Map && json.containsKey('result')) ? json['result'] : json;
    List? items;
    if (result is Map && result.containsKey(arrayKey)) {
      items = result[arrayKey] as List;
    } else if (result is List) {
      items = result;
    }
    if (items == null) return [];
    return items.whereType<Map<String, dynamic>>().map((m) => McpItemDetail.fromJson(m)).toList();
  }

  /// Try to retrieve tool/prompt/resource info from a spec URL (e.g. OpenAPI).
  Future<void> _trySpecificationUrl(String specUrl, Map<String, String> headers) async {
    try {
      log.verbose('[MCP HTTP] GET spec URL: $specUrl');
      final resp = await http.get(Uri.parse(specUrl), headers: headers).timeout(const Duration(seconds: 10));
      log.verbose('[MCP HTTP] Spec response: ${resp.statusCode} body: ${truncate(resp.body)}');
      if (resp.statusCode == 200) {
        final json = jsonDecode(resp.body);
        if (json is Map) {
          if (json.containsKey('tools') && json['tools'] is List) {
            _tools = (json['tools'] as List).whereType<Map<String, dynamic>>().map((m) => McpItemDetail.fromJson(m)).toList();
          }
          if (json.containsKey('prompts') && json['prompts'] is List) {
            _prompts = (json['prompts'] as List).whereType<Map<String, dynamic>>().map((m) => McpItemDetail.fromJson(m)).toList();
          }
          if (json.containsKey('resources') && json['resources'] is List) {
            _resources = (json['resources'] as List).whereType<Map<String, dynamic>>().map((m) => McpItemDetail.fromJson(m)).toList();
          }
          // OpenAPI-style: extract paths as tool names
          if (json.containsKey('paths') && _tools.isEmpty) {
            final paths = json['paths'] as Map;
            _tools = paths.entries
                .map(
                  (e) => McpItemDetail(
                    name: e.key.toString(),
                    description: null,
                    raw: e.value is Map<String, dynamic> ? e.value as Map<String, dynamic> : {},
                  ),
                )
                .toList();
          }
        }
      }
    } catch (e) {
      log.verbose('[MCP HTTP] Spec URL failed: $e');
    }
  }

  // ─── UI ───────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.travel_explore, color: AppTheme.primaryBlue),
          const SizedBox(width: 8),
          Expanded(child: Text('Discover: ${widget.server.name ?? widget.server.serverUrl}', maxLines: 1, overflow: TextOverflow.ellipsis)),
        ],
      ),
      content: SizedBox(width: 480, height: 400, child: _loading ? _buildLoading() : _buildResults()),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        if (!_loading && _error == null)
          FilledButton(
            onPressed: () {
              final updated = widget.server.copyWith(
                discoveredTools: _tools.map((t) => t.name).toList(),
                discoveredToolSchemas: _tools
                    .map(
                      (t) => {
                        'name': t.name,
                        if (t.description != null) 'description': t.description,
                        if (t.inputSchema != null) 'inputSchema': t.inputSchema,
                      },
                    )
                    .toList(),
                discoveredPrompts: _prompts.map((p) => p.name).toList(),
                discoveredResources: _resources.map((r) => r.name).toList(),
              );
              Navigator.pop(context, updated);
            },
            child: const Text('Apply'),
          ),
        if (!_loading && _error != null)
          TextButton.icon(onPressed: _discover, icon: const Icon(Icons.refresh, size: 18), label: const Text('Retry')),
      ],
    );
  }

  Widget _buildLoading() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text('Connecting to ${widget.server.serverUrl}...', textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text('Discovering tools, prompts & resources', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
        ],
      ),
    );
  }

  Widget _buildResults() {
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: AppTheme.error),
            const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSection(Icons.build, 'Tools', _tools, AppTheme.primaryBlue),
          _buildSection(Icons.chat, 'Prompts', _prompts, Colors.orange),
          _buildSection(Icons.folder, 'Resources', _resources, Colors.teal),
        ],
      ),
    );
  }

  Widget _buildSection(IconData icon, String title, List<McpItemDetail> items, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 6),
            Text(
              '$title (${items.length})',
              style: TextStyle(fontWeight: FontWeight.bold, color: color),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 24, bottom: 16),
            child: Text('None found', style: TextStyle(fontSize: 12, color: Colors.grey[500])),
          )
        else
          Padding(
            padding: const EdgeInsets.only(left: 24, bottom: 16),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: items
                  .map(
                    (item) => ActionChip(
                      label: Text(item.name, style: const TextStyle(fontSize: 12)),
                      backgroundColor: color.withAlpha(25),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onPressed: () => _showItemDetail(item, color),
                    ),
                  )
                  .toList(),
            ),
          ),
      ],
    );
  }

  /// Show a centered dialog with full details for a tool/prompt/resource.
  void _showItemDetail(McpItemDetail item, Color color) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 600),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── Header bar ──
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
                child: Row(
                  children: [
                    Icon(Icons.build, color: color, size: 22),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        item.name,
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color),
                      ),
                    ),
                    IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(ctx).pop()),
                  ],
                ),
              ),
              const Divider(),

              // ── Scrollable content ──
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── Description ──
                      if (item.description != null && item.description!.isNotEmpty) ...[
                        const Text('Description', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                        const SizedBox(height: 4),
                        Text(item.description!, style: const TextStyle(fontSize: 13)),
                        const SizedBox(height: 16),
                      ],

                      // ── Parameters (inputSchema) ──
                      if (item.inputSchema != null) ...[
                        const Text('Parameters', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                        const SizedBox(height: 6),
                        _buildSchemaTable(item.inputSchema!),
                        const SizedBox(height: 16),
                      ],

                      // ── Return type ──
                      if (item.returnType != null) ...[
                        const Text('Return Type', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                        const SizedBox(height: 4),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.grey.withAlpha(25),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: Colors.grey.withAlpha(60)),
                          ),
                          child: Text(
                            const JsonEncoder.withIndent('  ').convert(item.returnType),
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],

                      // ── Raw JSON ──
                      ExpansionTile(
                        title: const Text('Raw JSON', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                        tilePadding: EdgeInsets.zero,
                        children: [
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Colors.grey.withAlpha(25),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: Colors.grey.withAlpha(60)),
                            ),
                            child: SelectableText(
                              const JsonEncoder.withIndent('  ').convert(item.raw),
                              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Build a table of parameters from a JSON Schema `inputSchema`.
  Widget _buildSchemaTable(Map<String, dynamic> schema) {
    final properties = schema['properties'] as Map<String, dynamic>?;
    final required_ = (schema['required'] as List<dynamic>?)?.cast<String>() ?? [];

    if (properties == null || properties.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.grey.withAlpha(25),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.grey.withAlpha(60)),
        ),
        child: Text(const JsonEncoder.withIndent('  ').convert(schema), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
      );
    }

    return Table(
      columnWidths: const {0: FlexColumnWidth(2), 1: FlexColumnWidth(1.2), 2: FlexColumnWidth(3)},
      border: TableBorder.all(color: Colors.grey.withAlpha(60), borderRadius: BorderRadius.circular(4)),
      children: [
        TableRow(
          decoration: BoxDecoration(color: Colors.grey.withAlpha(30)),
          children: const [
            Padding(
              padding: EdgeInsets.all(6),
              child: Text('Name', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            ),
            Padding(
              padding: EdgeInsets.all(6),
              child: Text('Type', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            ),
            Padding(
              padding: EdgeInsets.all(6),
              child: Text('Description', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            ),
          ],
        ),
        ...properties.entries.map((e) {
          final prop = e.value is Map<String, dynamic> ? e.value as Map<String, dynamic> : <String, dynamic>{};
          final isRequired = required_.contains(e.key);
          final type = prop['type']?.toString() ?? '';
          final desc = prop['description']?.toString() ?? '';
          return TableRow(
            children: [
              Padding(
                padding: const EdgeInsets.all(6),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: e.key,
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                      ),
                      if (isRequired)
                        TextSpan(
                          text: ' *',
                          style: TextStyle(color: AppTheme.error, fontWeight: FontWeight.bold, fontSize: 12),
                        ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(6),
                child: Text(
                  type,
                  style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.grey[600]),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(6),
                child: Text(desc, style: const TextStyle(fontSize: 12)),
              ),
            ],
          );
        }),
      ],
    );
  }
}
