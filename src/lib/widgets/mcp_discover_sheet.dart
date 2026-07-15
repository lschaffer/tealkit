import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../mcp/internal_mcp_server.dart';
import '../models/github_mcp_server_definition.dart';
import '../services/github_mcp_runtime_service.dart';
import 'tool_list_export_sheet.dart';

/// Shows the tool-discovery bottom sheet for a [GithubMcpServerDefinition].
/// Launches a temp process, does the MCP handshake, reads tools/list, disposes.
Future<void> showMcpDiscoverSheet(BuildContext context, GithubMcpServerDefinition def) async {
  // Show a loading indicator while we discover
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (_) => const _LoadingSheet(),
  );

  List<McpToolDescriptor> tools = [];
  String? error;
  StdioMcpClient? client;

  try {
    final process = await GithubMcpRuntimeService.instance.launch(def);
    client = StdioMcpClient(process);

    final initResp = await client.request('initialize', {
      'protocolVersion': '2024-11-05',
      'capabilities': {},
      'clientInfo': {'name': 'TealKit', 'version': '1.0'},
    }, timeout: const Duration(seconds: 30));

    if (initResp.containsKey('error')) {
      error = 'Handshake error: ${initResp['error']}';
    } else {
      await client.notify('notifications/initialized', null);

      final resp = await client.request('tools/list', null, timeout: const Duration(seconds: 30));
      final rawList = resp['result']?['tools'] as List<dynamic>? ?? resp['result'] as List<dynamic>? ?? [];
      tools = rawList.whereType<Map<String, dynamic>>().map((t) {
        return McpToolDescriptor(
          name: t['name'] as String,
          description: t['description'] as String? ?? '',
          inputSchema: (t['inputSchema'] as Map<String, dynamic>?) ?? {'type': 'object', 'properties': {}},
        );
      }).toList();
      if (tools.isEmpty && resp.containsKey('error')) {
        error = 'tools/list error: ${resp['error']}';
      }
    }
  } on TimeoutException catch (e) {
    error =
        'Server did not respond in time (${e.duration?.inSeconds ?? 30}s).\nMake sure the server is installed and its dependencies are available.';
  } catch (e) {
    error = e.toString();
  } finally {
    await client?.dispose();
  }

  if (!context.mounted) return;

  // Close loading sheet and show results
  Navigator.of(context).pop();
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (_) => McpDiscoverSheet(serverName: def.displayName, tools: tools, error: error),
  );
}

// ─── Loading placeholder ──────────────────────────────────────────────────────

class _LoadingSheet extends StatelessWidget {
  const _LoadingSheet();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 160,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text('Discovering tools…', style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}

// ─── Results sheet ────────────────────────────────────────────────────────────

class McpDiscoverSheet extends StatelessWidget {
  final String serverName;
  final List<McpToolDescriptor> tools;
  final String? error;

  const McpDiscoverSheet({super.key, required this.serverName, required this.tools, this.error});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (_, controller) => Column(
        children: [
          // Handle
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(color: colorScheme.outlineVariant, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                const Icon(Icons.search, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Tools: $serverName', style: theme.textTheme.titleMedium, overflow: TextOverflow.ellipsis),
                ),
                Text('${tools.length} tools', style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.outline)),
                if (tools.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.model_training, size: 18),
                    tooltip: 'Export for training',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    onPressed: () => ToolListExportSheet.show(
                      context,
                      serverName: serverName,
                      tools: tools.map((t) => {'name': t.name, 'description': t.description, 'inputSchema': t.inputSchema}).toList(),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Error: $error', style: TextStyle(color: colorScheme.error)),
            )
          else if (tools.isEmpty)
            const Padding(padding: EdgeInsets.all(24), child: Text('No tools found.'))
          else
            Expanded(
              child: ListView.separated(
                controller: controller,
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: tools.length,
                separatorBuilder: (_, _) => const Divider(height: 1, indent: 16),
                itemBuilder: (_, i) {
                  final t = tools[i];
                  final props = (t.inputSchema['properties'] as Map?)?.keys.toList() ?? <String>[];
                  final required = (t.inputSchema['required'] as List?)?.cast<String>() ?? <String>[];
                  final example = _buildExamplePrompt(t.name, props, required);
                  return ListTile(
                    dense: true,
                    title: Text(
                      t.name,
                      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, fontFamily: 'monospace'),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (t.description.isNotEmpty) ...[const SizedBox(height: 2), Text(t.description, style: theme.textTheme.bodySmall)],
                        if (props.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 4,
                            runSpacing: 4,
                            children: props.map((p) {
                              final isReq = required.contains(p);
                              return Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                decoration: BoxDecoration(
                                  color: isReq ? colorScheme.primaryContainer : colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  p,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: isReq ? colorScheme.onPrimaryContainer : colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ],
                        if (example != null) ...[
                          const SizedBox(height: 6),
                          GestureDetector(
                            onTap: () {
                              Clipboard.setData(ClipboardData(text: example));
                              ScaffoldMessenger.of(
                                context,
                              ).showSnackBar(const SnackBar(content: Text('Copied to clipboard'), duration: Duration(seconds: 1)));
                            },
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(color: colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(6)),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(example, style: theme.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic)),
                                  ),
                                  const SizedBox(width: 4),
                                  Icon(Icons.copy, size: 12, color: colorScheme.outline),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    isThreeLine: false,
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  static String? _buildExamplePrompt(String toolName, List props, List<String> required) {
    if (props.isEmpty) return 'Call $toolName';
    final paramHints = required.isNotEmpty ? required : props.take(2).toList();
    final paramStr = paramHints.map((p) => '$p="<value>"').join(', ');
    return 'Call $toolName with $paramStr';
  }
}
