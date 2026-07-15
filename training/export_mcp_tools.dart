import 'dart:convert';
import 'dart:io';

import 'package:tealkit/mcp/internal_mcp_registry.dart';

Future<void> main(List<String> args) async {
  final outputPath = args.isNotEmpty ? args.first : 'scripts_training/mcp_data/mcp_tools.json';

  final registry = InternalMcpRegistry();
  final servers = registry.availableServers..sort((a, b) => a.type.compareTo(b.type));

  final exportedServers = <Map<String, dynamic>>[];
  final allTools = <Map<String, dynamic>>[];

  for (final server in servers) {
    final instance = registry.create(server.type);
    if (instance == null) {
      continue;
    }

    final tools =
        instance.tools
            .map((tool) => {'name': tool.name, 'description': tool.description, 'inputSchema': tool.inputSchema})
            .toList(growable: false)
          ..sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));

    exportedServers.add({
      'type': server.type,
      'displayName': server.displayName,
      'description': server.description,
      'toolCount': tools.length,
      'tools': tools,
    });

    for (final tool in tools) {
      allTools.add({'serverType': server.type, 'serverDisplayName': server.displayName, ...tool});
    }
  }

  allTools.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));

  final output = {
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'platform': Platform.operatingSystem,
    'serverCount': exportedServers.length,
    'toolCount': allTools.length,
    'servers': exportedServers,
    'allTools': allTools,
  };

  final outFile = File(outputPath);
  await outFile.parent.create(recursive: true);
  await outFile.writeAsString(const JsonEncoder.withIndent('  ').convert(output));

  stdout.writeln('Exported ${allTools.length} tools from ${exportedServers.length} internal MCP servers.');
  stdout.writeln('Wrote: ${outFile.path}');
}
