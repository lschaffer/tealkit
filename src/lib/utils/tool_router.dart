import '../models/mcp_models.dart';
import 'logger.dart';

/// Lightweight wrapper around an MCPTool for routing purposes.
class ToolDef {
  final MCPTool tool;

  ToolDef(this.tool);

  factory ToolDef.fromMCPTool(MCPTool tool) => ToolDef(tool);

  String get name => tool.name;
  String get description => tool.description ?? '';
}

/// Simplified tool router – selects the most relevant tools for a query
/// using keyword matching (no embedding model required).
class ToolRouter {
  final List<ToolDef> _allTools;

  ToolRouter(this._allTools);

  /// Initialize the router with a list of MCP tools.
  static Future<ToolRouter> create(List<MCPTool> tools) async {
    final defs = tools.map((t) => ToolDef.fromMCPTool(t)).toList();
    talker.info('ToolRouter initialized with ${defs.length} tools');
    return ToolRouter(defs);
  }

  /// Select the top-K most relevant tools for a query.
  /// Uses simple keyword matching on tool name + description.
  Future<List<ToolDef>> selectTools(String query, {int topK = 15}) async {
    if (_allTools.length <= topK) return _allTools;

    final queryWords = query.toLowerCase().split(RegExp(r'\s+')).toSet();

    final scored = <MapEntry<int, double>>[];
    for (int i = 0; i < _allTools.length; i++) {
      final t = _allTools[i];
      final text = '${t.name} ${t.description}'.toLowerCase();
      final words = text.split(RegExp(r'\s+'));
      double score = 0;
      for (final qw in queryWords) {
        if (qw.length < 3) continue;
        for (final tw in words) {
          if (tw.contains(qw) || qw.contains(tw)) {
            score += 1;
          }
        }
      }
      scored.add(MapEntry(i, score));
    }

    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.take(topK).map((e) => _allTools[e.key]).toList();
  }

  /// Convert MCPTools to ToolDefs.
  static List<ToolDef> fromMCPTools(List<MCPTool> tools) {
    return tools.map((tool) => ToolDef.fromMCPTool(tool)).toList();
  }
}
