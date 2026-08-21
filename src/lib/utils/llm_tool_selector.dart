import 'dart:async';
import 'dart:convert';
import '../models/mcp_models.dart';
import '../services/llm_service.dart';
import '../utils/logger.dart';

/// Intelligent 2nd-stage tool selector that uses an LLM to pick the minimal set
/// of relevant tools from a candidate list (e.g. 10-20 tools from MCP servers).
class LLMToolSelector {
  /// Filter candidate tools down to the exact tools needed for the user's prompt.
  /// Returns a subset of [candidateTools], or an empty list if no tools are needed.
  /// If an error or timeout occurs, it falls back to returning all [candidateTools].
  static Future<List<MCPTool>> filterTools({
    required String query,
    required List<MCPTool> candidateTools,
    required LLMService llmService,
    String? source,
    Duration timeout = const Duration(milliseconds: 3500),
  }) async {
    if (candidateTools.isEmpty) return [];

    final targetSource = source ?? llmService.toolFilteringLlmSource;

    try {
      final startTime = DateTime.now();
      talker.info('🧠 [Stage 2 Tool Selector] Starting LLM tool filtering for ${candidateTools.length} candidate tools using $targetSource...');

      // 1. Build compact tool summary manifest
      final toolManifest = StringBuffer();
      for (final tool in candidateTools) {
        String desc = tool.description?.trim() ?? '';
        if (desc.length > 120) {
          desc = '${desc.substring(0, 117)}...';
        }
        toolManifest.writeln('- ${tool.name}: $desc');
      }

      // 2. Build selector prompt with domain-agnostic tool routing guidelines
      final prompt = '''You are an expert AI tool selector.
Given the user prompt and available tools, select the MINIMAL set of tool names necessary to fulfill the request.
Guidelines:
1. Select only from the Available Tools listed below.
2. If the prompt requires searching/retrieving data, select the specific lookup/fetch tool.
3. If no tools are needed (e.g. general conversation, greetings, calculations, direct questions), return an empty array [].
4. Respond ONLY with a valid JSON array of tool names, e.g. ["tool_name_1", "tool_name_2"]. Do not add explanation or markdown formatting.

Available Tools:
$toolManifest
User Prompt:
${query.length > 600 ? '${query.substring(0, 597)}...' : query}''';

      // 3. Call LLM with fast timeout
      final rawResponse = await llmService
          .generateFastCompletion(
            prompt,
            source: targetSource,
            maxTokens: 120,
            temperature: 0.0,
          )
          .timeout(timeout);

      final elapsedMs = DateTime.now().difference(startTime).inMilliseconds;

      if (rawResponse == null || rawResponse.trim().isEmpty) {
        talker.warning('⚠️ [Stage 2 Tool Selector] Empty response from $targetSource after ${elapsedMs}ms, falling back to all candidate tools');
        return candidateTools;
      }

      // 4. Parse JSON list of tool names from model response
      final selectedNames = _extractToolNames(rawResponse);
      talker.info('🧠 [Stage 2 Tool Selector] Model returned names: $selectedNames (${elapsedMs}ms)');

      // If model returned empty array explicitly, user prompt requires NO tools!
      if (selectedNames.isEmpty) {
        talker.info('📭 [Stage 2 Tool Selector] 0 tools selected - query requires no tools');
        return [];
      }

      // Map selected names back to actual candidate MCPTool instances
      final candidateMap = {for (final t in candidateTools) t.name.toLowerCase(): t};
      final filteredTools = <MCPTool>[];

      for (final name in selectedNames) {
        final matched = candidateMap[name.toLowerCase().trim()];
        if (matched != null && !filteredTools.contains(matched)) {
          filteredTools.add(matched);
        }
      }

      if (filteredTools.isEmpty) {
        talker.warning('⚠️ [Stage 2 Tool Selector] None of the returned tool names matched candidate tools. Falling back to candidate tools.');
        return candidateTools;
      }

      talker.info('✅ [Stage 2 Tool Selector] Successfully filtered from ${candidateTools.length} to ${filteredTools.length} tool(s): ${filteredTools.map((t) => t.name).join(", ")}');
      return filteredTools;
    } catch (e) {
      talker.warning('⚠️ [Stage 2 Tool Selector] Error or timeout during LLM tool selection ($e), falling back to ${candidateTools.length} candidate tools');
      return candidateTools;
    }
  }

  /// Extracts tool names from raw response text, handling JSON arrays and regex fallbacks.
  static List<String> _extractToolNames(String text) {
    final cleaned = text.trim();

    // 1. Try direct JSON parsing
    try {
      final decoded = jsonDecode(cleaned);
      if (decoded is List) {
        return decoded.map((e) => e.toString().trim()).where((s) => s.isNotEmpty).toList();
      }
    } catch (_) {
      // Continue to regex
    }

    // 2. Extract content within JSON array brackets [ ... ]
    final match = RegExp(r'\[(.*?)\]', dotAll: true).firstMatch(cleaned);
    if (match != null) {
      final inner = match.group(1)?.trim() ?? '';
      if (inner.isEmpty) return [];

      try {
        final arrayJson = jsonDecode('[$inner]');
        if (arrayJson is List) {
          return arrayJson.map((e) => e.toString().trim()).where((s) => s.isNotEmpty).toList();
        }
      } catch (_) {
        // Fallback to item splitting
        final items = inner.split(',').map((s) => s.replaceAll(RegExp(r'["\x27\s]'), '')).where((s) => s.isNotEmpty).toList();
        return items;
      }
    }

    return [];
  }
}
