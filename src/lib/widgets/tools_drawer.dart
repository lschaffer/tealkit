import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:convert';
import '../providers/active_task_provider.dart';
import '../services/multi_mcp_manager.dart';
import '../models/mcp_models.dart';

class ToolsDrawer extends ConsumerStatefulWidget {
  final ValueNotifier<String?>? promptNotifier;

  const ToolsDrawer({super.key, this.promptNotifier});

  @override
  ConsumerState<ToolsDrawer> createState() => _ToolsDrawerState();
}

class _ToolsDrawerState extends ConsumerState<ToolsDrawer> {
  String _selectedServer = 'All';

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width > 800;
    final drawerWidth = isDesktop ? 480.0 : 360.0;

    // Read MCP manager from the active task provider
    final taskState = ref.watch(activeTaskProvider);
    final mcpManager = taskState?.mcpManager;

    // If no active task or no MCP manager, show empty state
    if (mcpManager == null) {
      return Drawer(
        width: drawerWidth,
        child: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.build_outlined, size: 64, color: Colors.grey),
              SizedBox(height: 16),
              Text('No active task', style: TextStyle(fontSize: 16, color: Colors.grey)),
              SizedBox(height: 8),
              Text(
                'Select a task to see\navailable tools',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    }

    return Drawer(
      width: drawerWidth,
      child: Column(
        children: [
          DrawerHeader(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: Theme.of(context).brightness == Brightness.dark
                    ? [const Color(0xFF1a2332), const Color(0xFF1e2d3d)]
                    : [const Color(0xFFb8c9cf), const Color(0xFFa8bdc5)],
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.build, size: 24, color: Theme.of(context).colorScheme.onPrimaryContainer),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'MCP Tools & Resources',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => _showTrainingExportDialog(context, mcpManager),
                      icon: Icon(Icons.model_training, color: Theme.of(context).colorScheme.onPrimaryContainer),
                      tooltip: 'Export tool list for model training',
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Available tools and resources from MCP servers',
                  style: TextStyle(fontSize: 14, color: Theme.of(context).colorScheme.onPrimaryContainer),
                ),
              ],
            ),
          ),
          Expanded(
            child: DefaultTabController(
              length: 2,
              child: Column(
                children: [
                  const TabBar(
                    tabs: [
                      Tab(icon: Icon(Icons.build), text: 'Tools'),
                      Tab(icon: Icon(Icons.folder), text: 'Resources'),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      physics: const NeverScrollableScrollPhysics(),
                      children: [_buildToolsTab(context, mcpManager), _buildResourcesTab(context, mcpManager)],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolsTab(BuildContext context, MultiMCPManager multiMcpManager) {
    final allTools = multiMcpManager.allAvailableTools;

    final servers = <String, int>{'All': allTools.length};
    for (final client in multiMcpManager.clients) {
      servers[client.label] = client.availableTools.length;
    }

    if (!servers.containsKey(_selectedServer)) {
      _selectedServer = 'All';
    }

    List<MCPTool> filteredTools;
    if (_selectedServer == 'All') {
      filteredTools = allTools;
    } else {
      final selectedClient = multiMcpManager.clients.firstWhere(
        (c) => c.label == _selectedServer,
        orElse: () => multiMcpManager.clients.first,
      );
      filteredTools = selectedClient.availableTools;
    }

    if (allTools.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.build_outlined, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text('No tools available', style: TextStyle(fontSize: 16, color: Colors.grey)),
            const SizedBox(height: 8),
            Text(
              multiMcpManager.isConnected ? 'Loading tools...' : 'Connect to MCP servers\nto see available tools',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            border: Border(bottom: BorderSide(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2))),
          ),
          child: Row(
            children: [
              Icon(Icons.dns, size: 18, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              const Text('MCP Server:', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButton<String>(
                  value: _selectedServer,
                  isExpanded: true,
                  underline: Container(),
                  items: servers.entries.map((entry) {
                    bool isConnected = entry.key == 'All';
                    if (!isConnected) {
                      final client = multiMcpManager.clients.firstWhere(
                        (c) => c.label == entry.key,
                        orElse: () => multiMcpManager.clients.first,
                      );
                      isConnected = client.isConnected;
                    }
                    return DropdownMenuItem(
                      value: entry.key,
                      child: Row(
                        children: [
                          Icon(isConnected ? Icons.check_circle : Icons.cancel, size: 14, color: isConnected ? Colors.green : Colors.red),
                          const SizedBox(width: 8),
                          Text('${entry.key} (${entry.value})'),
                        ],
                      ),
                    );
                  }).toList(),
                  onChanged: (value) {
                    if (value != null) setState(() => _selectedServer = value);
                  },
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: filteredTools.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.search_off, size: 48, color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
                      const SizedBox(height: 12),
                      Text(
                        'No tools available for $_selectedServer',
                        style: TextStyle(fontSize: 14, color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7)),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: filteredTools.length,
                  itemBuilder: (context, index) => _buildToolCard(context, filteredTools[index]),
                ),
        ),
      ],
    );
  }

  Widget _buildToolCard(BuildContext context, MCPTool tool) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ExpansionTile(
        title: Text(
          tool.name,
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Theme.of(context).colorScheme.onSurface),
        ),
        subtitle: tool.description != null
            ? Text(
                tool.description!,
                style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              )
            : null,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (tool.description != null) ...[
                  Text(
                    'Description:',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Theme.of(context).colorScheme.onSurface),
                  ),
                  const SizedBox(height: 4),
                  Text(tool.description!, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 12),
                ],
                if (tool.inputSchema != null) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Input Schema:',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Theme.of(context).colorScheme.onSurface),
                      ),
                      IconButton(
                        onPressed: () => _copyToClipboard(context, jsonEncode(tool.inputSchema)),
                        icon: const Icon(Icons.copy, size: 16),
                        tooltip: 'Copy schema',
                        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
                    ),
                    child: SelectableText(
                      _formatJson(tool.inputSchema!),
                      style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: Theme.of(context).colorScheme.onSurface),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () => _showToolTestDialog(context, tool),
                    icon: const Icon(Icons.play_arrow, size: 16),
                    label: const Text('Test Tool', style: TextStyle(fontSize: 12)),
                    style: ElevatedButton.styleFrom(minimumSize: const Size(0, 32)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResourcesTab(BuildContext context, MultiMCPManager multiMcpManager) {
    final resources = multiMcpManager.allAvailableResources;

    if (resources.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.folder_outlined, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text('No resources available', style: TextStyle(fontSize: 16, color: Colors.grey)),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: resources.length,
      itemBuilder: (context, index) => _buildResourceCard(context, resources[index]),
    );
  }

  Widget _buildResourceCard(BuildContext context, MCPResource resource) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        title: Text(
          resource.name,
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Theme.of(context).colorScheme.onSurface),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (resource.description != null)
              Text(resource.description!, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 4),
            Text(
              'URI: ${resource.uri}',
              style: TextStyle(fontSize: 10, fontFamily: 'monospace', color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            if (resource.mimeType != null)
              Text('Type: ${resource.mimeType}', style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ),
        trailing: IconButton(
          onPressed: () => _readResource(context, resource),
          icon: const Icon(Icons.visibility, size: 16),
          tooltip: 'Read resource',
        ),
      ),
    );
  }

  String _formatJson(Map<String, dynamic> json) {
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(json);
  }

  void _copyToClipboard(BuildContext context, String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied to clipboard'), duration: Duration(seconds: 1)));
  }

  void _showToolTestDialog(BuildContext context, MCPTool tool) {
    final taskState = ref.read(activeTaskProvider);
    final mcpManager = taskState?.mcpManager;
    if (mcpManager == null) return;
    showDialog(
      context: context,
      builder: (context) => _ToolTestDialog(tool: tool, mcpManager: mcpManager),
    );
  }

  Future<void> _readResource(BuildContext context, MCPResource resource) async {
    try {
      final taskState = ref.read(activeTaskProvider);
      final mcpManager = taskState?.mcpManager;
      if (mcpManager == null) throw Exception('No active task');
      final clients = mcpManager.clients.where((c) => c.isConnected);
      if (clients.isEmpty) throw Exception('No connected MCP servers');
      final content = await clients.first.client.readResource(resource.uri);

      if (context.mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(resource.name),
            content: SizedBox(
              width: 400,
              height: 300,
              child: SingleChildScrollView(
                child: SelectableText(content, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              ),
            ),
            actions: [
              TextButton(onPressed: () => _copyToClipboard(context, content), child: const Text('Copy')),
              TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
            ],
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error reading resource: $e'), backgroundColor: Colors.red));
      }
    }
  }

  void _showTrainingExportDialog(BuildContext context, MultiMCPManager mcpManager) {
    showDialog(
      context: context,
      builder: (context) => TrainingExportDialog(mcpManager: mcpManager),
    );
  }
}

class TrainingExportDialog extends StatefulWidget {
  final MultiMCPManager mcpManager;

  const TrainingExportDialog({super.key, required this.mcpManager});

  @override
  State<TrainingExportDialog> createState() => _TrainingExportDialogState();
}

class _TrainingExportDialogState extends State<TrainingExportDialog> {
  String _format = 'openai';
  String? _serverFilter;
  bool _includeServerTag = true;
  late String _output;

  static const _formats = {
    'openai': 'OpenAI functions',
    'anthropic': 'Anthropic tools',
    'markdown': 'Markdown docs',
    'jsonl': 'JSONL (fine-tuning)',
  };

  @override
  void initState() {
    super.initState();
    _regenerate();
  }

  void _regenerate() {
    _output = widget.mcpManager.generateTrainingToolList(format: _format, serverFilter: _serverFilter, includeServerTag: _includeServerTag);
  }

  Future<void> _copyOutput(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: _output));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied to clipboard'), duration: Duration(seconds: 2)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final servers = <String?>[null, ...widget.mcpManager.clients.map((c) => c.label)];
    final isWide = MediaQuery.of(context).size.width > 700;

    return AlertDialog(
      title: const Row(children: [Icon(Icons.model_training, size: 20), SizedBox(width: 8), Text('Export Tool List for Model Training')]),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      content: SizedBox(
        width: isWide ? 680 : double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.65,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Controls row ──
            Wrap(
              spacing: 16,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                // Format selector
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Format:', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(width: 8),
                    DropdownButton<String>(
                      value: _format,
                      underline: Container(),
                      items: _formats.entries
                          .map(
                            (e) => DropdownMenuItem(
                              value: e.key,
                              child: Text(e.value, style: const TextStyle(fontSize: 13)),
                            ),
                          )
                          .toList(),
                      onChanged: (v) {
                        if (v != null) {
                          setState(() {
                            _format = v;
                            _regenerate();
                          });
                        }
                      },
                    ),
                  ],
                ),
                // Server filter
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Server:', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(width: 8),
                    DropdownButton<String?>(
                      value: _serverFilter,
                      underline: Container(),
                      items: servers
                          .map(
                            (s) => DropdownMenuItem(
                              value: s,
                              child: Text(s ?? 'All servers', style: const TextStyle(fontSize: 13)),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => setState(() {
                        _serverFilter = v;
                        _regenerate();
                      }),
                    ),
                  ],
                ),
                // Server tag checkbox
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      value: _includeServerTag,
                      onChanged: (v) => setState(() {
                        _includeServerTag = v ?? true;
                        _regenerate();
                      }),
                    ),
                    const Text('Include server tag', style: TextStyle(fontSize: 13)),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            // ── Stats row ──
            Text(
              '${widget.mcpManager.allAvailableTools.length} tools across ${widget.mcpManager.clients.length} server(s)',
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            // ── Output preview ──
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(10),
                  child: SelectableText(_output, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                ),
              ),
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
      actions: [
        TextButton.icon(onPressed: () => _copyOutput(context), icon: const Icon(Icons.copy, size: 16), label: const Text('Copy')),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
      ],
    );
  }
}

class _ToolTestDialog extends StatefulWidget {
  final MCPTool tool;
  final MultiMCPManager mcpManager;

  const _ToolTestDialog({required this.tool, required this.mcpManager});

  @override
  State<_ToolTestDialog> createState() => _ToolTestDialogState();
}

class _ToolTestDialogState extends State<_ToolTestDialog> {
  final TextEditingController _argumentsController = TextEditingController();
  bool _isLoading = false;
  MCPToolResult? _result;

  @override
  void initState() {
    super.initState();
    if (widget.tool.inputSchema != null) {
      _argumentsController.text = _generateExampleArguments(widget.tool.inputSchema!);
    }
  }

  String _generateExampleArguments(Map<String, dynamic> schema) {
    try {
      final properties = schema['properties'] as Map<String, dynamic>?;
      if (properties != null) {
        final example = <String, dynamic>{};
        properties.forEach((key, value) {
          if (value is Map<String, dynamic>) {
            switch (value['type'] as String?) {
              case 'string':
                example[key] = 'example_$key';
              case 'number':
              case 'integer':
                example[key] = 123;
              case 'boolean':
                example[key] = true;
              case 'array':
                example[key] = ['item1', 'item2'];
              case 'object':
                example[key] = {};
            }
          }
        });
        return const JsonEncoder.withIndent('  ').convert(example);
      }
    } catch (_) {}
    return '{}';
  }

  Future<void> _testTool() async {
    setState(() => _isLoading = true);
    try {
      final argumentsText = _argumentsController.text.trim();
      final arguments = argumentsText.isEmpty ? <String, dynamic>{} : jsonDecode(argumentsText) as Map<String, dynamic>;
      final result = await widget.mcpManager.callTool(widget.tool.name, arguments);
      setState(() => _result = result);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error testing tool: $e'), backgroundColor: Colors.red));
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Test ${widget.tool.name}'),
      content: SizedBox(
        width: 500,
        height: 400,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Arguments (JSON):', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Expanded(
              flex: 1,
              child: TextField(
                controller: _argumentsController,
                decoration: const InputDecoration(border: OutlineInputBorder(), hintText: '{}'),
                maxLines: null,
                expands: true,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _isLoading ? null : _testTool,
                  icon: _isLoading
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).colorScheme.primary),
                          ),
                        )
                      : const Icon(Icons.play_arrow),
                  label: const Text('Test Tool'),
                ),
                const Spacer(),
                const Text('Result:', style: TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              flex: 1,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.grey.withValues(alpha: 0.3)),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    _result != null ? _result!.content.map((c) => c.text ?? '').join('\n') : 'No result yet',
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (_result != null)
          TextButton(
            onPressed: () {
              final resultText = _result!.content.map((c) => c.text ?? '').join('\n');
              Clipboard.setData(ClipboardData(text: resultText));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Result copied to clipboard')));
            },
            child: const Text('Copy Result'),
          ),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
      ],
    );
  }
}
