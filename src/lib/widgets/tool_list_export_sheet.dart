import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A bottom sheet that generates a model-training export from a raw list of
/// MCP tools (OpenAI functions / Anthropic tools / Markdown / JSONL).
///
/// Accepts tools as plain [Map<String, dynamic>] (standard MCP format):
///   { "name": "...", "description": "...", "inputSchema": {...} }
///
/// Usage:
///   ToolListExportSheet.show(context, serverName: 'My Server', tools: rawList);
class ToolListExportSheet extends StatefulWidget {
  final String serverName;
  final List<Map<String, dynamic>> tools;

  const ToolListExportSheet({super.key, required this.serverName, required this.tools});

  static Future<void> show(BuildContext context, {required String serverName, required List<Map<String, dynamic>> tools}) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => ToolListExportSheet(serverName: serverName, tools: tools),
    );
  }

  @override
  State<ToolListExportSheet> createState() => _ToolListExportSheetState();
}

class _ToolListExportSheetState extends State<ToolListExportSheet> {
  String _format = 'openai';

  static const _formats = {
    'openai': 'OpenAI functions',
    'anthropic': 'Anthropic tools',
    'markdown': 'Markdown docs',
    'jsonl': 'JSONL (fine-tuning)',
  };

  String _generate() {
    final tools = widget.tools;
    final serverName = widget.serverName;
    switch (_format) {
      case 'anthropic':
        return _fmt(
          tools.map((t) {
            return {
              'name': t['name'] ?? '',
              if (t['description'] != null) 'description': t['description'],
              'input_schema': t['inputSchema'] ?? {'type': 'object', 'properties': {}},
              if (t['skill'] != null) 'skill': t['skill'],
            };
          }).toList(),
        );
      case 'markdown':
        final buf = StringBuffer();
        buf.writeln('# MCP Tool Reference – $serverName');
        buf.writeln();
        buf.writeln('Generated: ${DateTime.now().toIso8601String()}  |  ${tools.length} tools');
        buf.writeln();
        for (final t in tools) {
          buf.writeln('### `${t['name']}`');
          final desc = (t['description'] ?? '').toString().trim();
          if (desc.isNotEmpty) buf.writeln(desc);
          buf.writeln();
          final schema = t['inputSchema'];
          if (schema != null) {
            buf.writeln('**Input schema:**');
            buf.writeln('```json');
            buf.writeln(const JsonEncoder.withIndent('  ').convert(schema));
            buf.writeln('```');
            buf.writeln();
          }
          if (t['skill'] != null) {
            final skill = t['skill'];
            if (skill is Map) {
              final text = skill['skillText'] ?? '';
              if (text.isNotEmpty) {
                buf.writeln('**Function Hint Guide:**');
                buf.writeln(text);
                buf.writeln();
              }
            }
          }
        }
        return buf.toString();
      case 'jsonl':
        return tools
            .map((t) {
              return jsonEncode({
                'type': 'function',
                'function': {
                  'name': t['name'] ?? '',
                  if (t['description'] != null) 'description': t['description'],
                  'parameters': t['inputSchema'] ?? {'type': 'object', 'properties': {}},
                  if (t['skill'] != null) 'skill': t['skill'],
                },
              });
            })
            .join('\n');
      default: // openai
        return _fmt(
          tools.map((t) {
            return {
              'type': 'function',
              'function': {
                'name': t['name'] ?? '',
                if (t['description'] != null) 'description': t['description'],
                'parameters': t['inputSchema'] ?? {'type': 'object', 'properties': {}},
                if (t['skill'] != null) 'skill': t['skill'],
              },
            };
          }).toList(),
        );
    }
  }

  String _fmt(Object obj) => const JsonEncoder.withIndent('  ').convert(obj);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final output = _generate();

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (_, controller) => Column(
        children: [
          // ── Handle ──
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(color: colorScheme.outlineVariant, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          // ── Header ──
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 4, 8),
            child: Row(
              children: [
                const Icon(Icons.model_training, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Export: ${widget.serverName}', style: theme.textTheme.titleMedium, overflow: TextOverflow.ellipsis),
                ),
                Text('${widget.tools.length} tools', style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.outline)),
                // ── Save to file ──
                if (!kIsWeb)
                  IconButton(
                    icon: const Icon(Icons.download, size: 18),
                    tooltip: 'Save to file',
                    onPressed: () async {
                      final ext = _format == 'markdown'
                          ? 'md'
                          : _format == 'jsonl'
                          ? 'jsonl'
                          : 'json';
                      final safeName = widget.serverName.replaceAll(RegExp(r'[^\w\s\-]'), '').trim();
                      final defaultName = '${safeName.isEmpty ? 'tools' : safeName}_tools.$ext';
                      final isMobile = Platform.isAndroid || Platform.isIOS;
                      final bytes = utf8.encode(output);
                      final savePath = await FilePicker.saveFile(
                        dialogTitle: 'Save tool list',
                        fileName: defaultName,
                        type: FileType.any,
                        bytes: isMobile ? Uint8List.fromList(bytes) : null,
                      );
                      if (savePath == null || !context.mounted) return;
                      if (!isMobile) {
                        await File(savePath).writeAsString(output);
                      }
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Saved to $savePath'),
                          behavior: SnackBarBehavior.floating,
                          duration: const Duration(seconds: 4),
                        ),
                      );
                    },
                  ),
                // ── Copy to clipboard ──
                IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  tooltip: 'Copy to clipboard',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: output));
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('Copied to clipboard'), duration: Duration(seconds: 2)));
                  },
                ),
              ],
            ),
          ),
          // ── Format selector ──
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                const Text('Format:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                DropdownButton<String>(
                  value: _format,
                  underline: Container(),
                  isDense: true,
                  items: _formats.entries
                      .map(
                        (e) => DropdownMenuItem(
                          value: e.key,
                          child: Text(e.value, style: const TextStyle(fontSize: 12)),
                        ),
                      )
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setState(() => _format = v);
                  },
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // ── Output ──
          Expanded(
            child: SingleChildScrollView(
              controller: controller,
              padding: const EdgeInsets.all(12),
              child: SelectableText(output, style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', fontSize: 11)),
            ),
          ),
        ],
      ),
    );
  }
}
