import 'package:dart_mcp_core/dart_mcp_core.dart';
import '../config/cli_config.dart';
import '../config/llm_config_manager.dart';

/// Prepares and registers sub-agents for multi-model delegation via [DelegateTaskTool].
class SubAgentHelper {
  /// Builds a list of [Agent] instances that can be delegated to by the primary orchestrator.
  static List<Agent> buildSubAgents({
    required List<NamedLlmProfile> allProfiles,
    required String activeProfileName,
    required List<SubAgentDefinition> configuredSubagents,
    required List<McpLocalTool> availableTools,
    required List<McpServerConfig> localServers,
    required List<McpServerConfig> remoteServers,
  }) {
    final subAgents = <Agent>[];
    final addedKeys = <String>{};

    final toolsByName = {for (final t in availableTools) t.name: t};

    // Combine configured subagents with predefined subagents (user config takes precedence)
    final effectiveSubagents = <SubAgentDefinition>[...configuredSubagents];
    final configuredKeys = {for (final s in configuredSubagents) s.key.toLowerCase()};
    for (final sample in SubAgentDefinition.predefined) {
      if (!configuredKeys.contains(sample.key.toLowerCase())) {
        effectiveSubagents.add(sample);
      }
    }

    // 1. Register specialized roles (e.g. unit_tester, git_auditor, web_researcher, code_scout, c_analyzer)
    for (final def in effectiveSubagents) {
      if (addedKeys.contains(def.key)) continue;

      // Resolve model profile (defaults to active profile if "default" or empty)
      final targetProfile = (def.model.toLowerCase() == 'default' || def.model.isEmpty)
          ? allProfiles.firstWhere(
              (p) => p.name.toLowerCase() == activeProfileName.toLowerCase(),
              orElse: () => allProfiles.first,
            )
          : allProfiles.firstWhere(
              (p) => p.name.toLowerCase() == def.model.toLowerCase(),
              orElse: () => allProfiles.firstWhere(
                (p) => p.name.toLowerCase() == activeProfileName.toLowerCase(),
                orElse: () => allProfiles.first,
              ),
            );

      // Filter tools if restricted (with web_search / fetch_web alias fallback)
      final filteredTools = def.tools != null && def.tools!.isNotEmpty
          ? def.tools!.map((name) {
              if (toolsByName.containsKey(name)) return toolsByName[name];
              if (name == 'web_search' && toolsByName.containsKey('fetch_web')) return toolsByName['fetch_web'];
              if (name == 'fetch_web' && toolsByName.containsKey('web_search')) return toolsByName['web_search'];
              return null;
            }).whereType<McpLocalTool>().toList()
          : availableTools;

      final prompt = def.systemPrompt.trim().isNotEmpty
          ? def.systemPrompt
          : 'You are a specialized sub-agent for ${def.description.isNotEmpty ? def.description : def.key}. Execute the assigned task and return your final distilled findings.';

      subAgents.add(Agent(
        key: def.key,
        name: '${def.key} (${targetProfile.name})',
        llmConfig: targetProfile.config,
        systemPrompt: prompt,
        dartTools: filteredTools,
        localServers: localServers,
        remoteServers: remoteServers,
        isSubAgent: true,
        enableDelegation: false,
        maxToolIterations: def.maxTurns,
      ));
      addedKeys.add(def.key);
    }

    // 2. Register all other configured LLM profiles as direct assignees
    for (final profile in allProfiles) {
      if (addedKeys.contains(profile.name)) continue;

      subAgents.add(Agent(
        key: profile.name,
        name: 'Model Sub-Agent (${profile.name})',
        llmConfig: profile.config,
        systemPrompt:
            'You are an autonomous sub-agent powered by the ${profile.name} model (${profile.config.model}). '
            'Perform the delegated task thoroughly using the available tools and return your final response.',
        dartTools: availableTools,
        localServers: localServers,
        remoteServers: remoteServers,
        isSubAgent: true,
        enableDelegation: false,
        maxToolIterations: 10,
      ));
      addedKeys.add(profile.name);
    }

    return subAgents;
  }
}
