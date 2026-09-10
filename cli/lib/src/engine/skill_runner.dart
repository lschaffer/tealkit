import 'dart:convert';
import 'dart:io';

import 'package:mcp_playground_dart/mcp_playground_dart.dart';
import 'package:yaml/yaml.dart';

import '../config/env_loader.dart';
import '../formatters/terminal_printer.dart';

/// Headless skill and prompt execution engine powered by `mcp_playground_dart`.
class SkillRunner {
  final String llmConfigPath;
  final String toolsConfigPath;
  final bool verbose;

  SkillRunner({
    this.llmConfigPath = 'llm.yaml',
    this.toolsConfigPath = 'extern_mcp_tools.yaml',
    this.verbose = false,
  });

  /// Loads [LlmConfig] from [llmConfigPath] (or fallback default / .env).
  LlmConfig loadLlmConfig() {
    final file = File(llmConfigPath);
    if (!file.existsSync()) {
      // Fallback: check .env for standard keys
      final dotEnv = EnvLoader.loadDotEnv();
      final apiKey = dotEnv['OPENAI_API_KEY'] ??
          dotEnv['ANTHROPIC_API_KEY'] ??
          dotEnv['GEMINI_API_KEY'] ??
          dotEnv['MISTRAL_API_KEY'] ??
          '';

      var provider = LlmProvider.openai;
      var model = 'gpt-4o-mini';

      if (dotEnv.containsKey('ANTHROPIC_API_KEY')) {
        provider = LlmProvider.claude;
        model = 'claude-3-5-sonnet-20241022';
      } else if (dotEnv.containsKey('GEMINI_API_KEY')) {
        provider = LlmProvider.gemini;
        model = 'gemini-1.5-flash';
      } else if (dotEnv.containsKey('MISTRAL_API_KEY')) {
        provider = LlmProvider.mistral;
        model = 'mistral-medium-latest';
      }

      return LlmConfig(
        provider: provider,
        model: dotEnv['LLM_MODEL'] ?? model,
        apiKey: apiKey,
        baseUrl: dotEnv['LLM_BASE_URL'] ?? '',
      );
    }

    final raw = file.readAsStringSync();
    final resolved = EnvLoader.substitute(raw);
    final yaml = loadYaml(resolved) as YamlMap?;
    if (yaml == null) {
      throw FormatException('Failed to parse LLM configuration at $llmConfigPath');
    }

    final providerStr =
        (yaml['provider'] as String?)?.toLowerCase() ?? 'openai';
    final provider = switch (providerStr) {
      'claude' || 'anthropic' => LlmProvider.claude,
      'gemini' || 'google' => LlmProvider.gemini,
      'ollama' => LlmProvider.ollama,
      'openai_compatible' || 'openaicompatible' => LlmProvider.openaiCompatible,
      'mistral' => LlmProvider.mistral,
      _ => LlmProvider.openai,
    };

    return LlmConfig(
      provider: provider,
      model: (yaml['model'] as String?) ?? 'gpt-4o-mini',
      apiKey: (yaml['api_key'] as String?) ?? '',
      baseUrl: (yaml['base_url'] as String?) ?? '',
      temperature: (yaml['temperature'] as num?)?.toDouble() ?? 0.2,
      maxTokens: (yaml['max_tokens'] as int?) ?? 0,
      topP: (yaml['top_p'] as num?)?.toDouble(),
      topK: yaml['top_k'] as int?,
      seed: yaml['seed'] as int?,
    );
  }

  /// Loads external MCP server configurations from YAML file.
  List<McpServerConfig> loadMcpServers() {
    File file = File(toolsConfigPath);
    if (!file.existsSync()) {
      // Also check fallback mcp.yaml
      file = File('mcp.yaml');
      if (!file.existsSync()) return [];
    }

    try {
      final raw = file.readAsStringSync();
      final resolved = EnvLoader.substitute(raw);
      final yaml = loadYaml(resolved) as YamlMap?;
      final serversList = yaml?['servers'] as YamlList?;
      if (serversList == null) return [];

      return serversList.whereType<YamlMap>().map((s) {
        final localEnv = s['env'] as YamlMap?;
        return McpServerConfig(
          id: (s['id'] as String?) ?? 'mcp_${serversList.indexOf(s)}',
          name: (s['name'] as String?) ?? 'Unnamed',
          url: (s['url'] as String?) ?? '',
          isLocal: s['is_local'] as bool? ?? false,
          localType: s['local_type'] as String?,
          localInstallMethod: s['local_install_method'] as String?,
          localPackage: s['local_package'] as String?,
          localCommand: s['local_command'] as String?,
          customLaunchCommand: s['custom_launch_command'] as String?,
          enabled: s['enabled'] as bool? ?? true,
          localEnvVars: localEnv?.map(
            (k, v) => MapEntry(k.toString(), v.toString()),
          ),
        );
      }).toList();
    } catch (e) {
      if (verbose) stderr.writeln('Warning: Could not parse $toolsConfigPath: $e');
      return [];
    }
  }

  /// Connects active MCP servers and registers them with a [MultiMCPManager].
  Future<MultiMCPManager> connectMcpServers(List<McpServerConfig> servers) async {
    final mcpManager = MultiMCPManager();

    for (final server in servers) {
      if (!server.enabled) continue;
      try {
        final client = LocalMCPClient(
          server,
          logCallback: (msg, {bool isError = false}) {
            if (verbose && isError) {
              stderr.writeln('[MCP:${server.name}] $msg');
            }
          },
        );
        final clientDef = MCPClientDef(
          name: server.id,
          client: client,
          displayName: server.name,
        );
        mcpManager.registerClient(clientDef);
        await client.connect();
        if (verbose) {
          stdout.writeln(TerminalPrinter.dim('Connected to MCP server: ${server.name}'));
        }
      } catch (e) {
        if (verbose) {
          stderr.writeln(TerminalPrinter.yellow('Warning: Failed to connect to "${server.name}": $e'));
        }
      }
    }

    return mcpManager;
  }

  /// Parses a `SKILL.md` file from path into a [SkillManifest].
  SkillManifest parseSkillFile(String filePath) {
    final file = File(filePath);
    if (!file.existsSync()) {
      throw FileSystemException('Skill file not found', filePath);
    }
    final content = file.readAsStringSync();
    final importer = SkillImporter();
    return importer.parseSkillMd(content);
  }

  /// Executes prompts directly from a `SKILL.md` file.
  Future<void> runSkill({
    required String skillPath,
    int? stepIndex,
    Map<String, String> parameters = const {},
    bool dryRun = false,
  }) async {
    final manifest = parseSkillFile(skillPath);
    final llmConfig = loadLlmConfig();
    final localServers = loadMcpServers();

    TerminalPrinter.printBanner(
      'TealKit Skill Runner: ${manifest.name}',
      [
        'Version     : ${manifest.version}',
        'Description : ${manifest.description.isEmpty ? "N/A" : manifest.description}',
        'Steps       : ${manifest.promptSteps.length}',
        'LLM Model   : ${llmConfig.provider.displayName} / ${llmConfig.model}',
      ],
    );

    if (dryRun) {
      stdout.writeln(TerminalPrinter.bold('─── Dry Run Mode ───'));
      stdout.writeln('System Prompt:');
      stdout.writeln(manifest.systemPrompt.trim());
      stdout.writeln('');
      stdout.writeln('Prompt Steps (${manifest.promptSteps.length}):');
      for (int i = 0; i < manifest.promptSteps.length; i++) {
        final step = manifest.promptSteps[i];
        final interpolated = _applyParams(step.text, parameters);
        stdout.writeln(' [Step ${i + 1}] $interpolated');
        if (step.enabledToolNames != null) {
          stdout.writeln('   Enabled tools: ${step.enabledToolNames!.join(", ")}');
        }
      }
      stdout.writeln('');
      stdout.writeln('Configured MCP Servers (${localServers.length}):');
      for (final s in localServers) {
        stdout.writeln(' • ${s.name} (${s.isLocal ? "Local" : "Remote"})');
      }
      stdout.writeln('');
      return;
    }

    final mcpManager = await connectMcpServers(localServers);

    try {
      final availableTools = mcpManager.availableTools;
      if (availableTools.isNotEmpty && verbose) {
        stdout.writeln(
          TerminalPrinter.dim(
            'Available MCP Tools: ${availableTools.map((t) => t.name).join(", ")}',
          ),
        );
        stdout.writeln('');
      }

      // Determine steps to execute
      final stepsToRun = <({int index, SkillPromptStep step})>[];
      if (stepIndex != null) {
        if (stepIndex < 1 || stepIndex > manifest.promptSteps.length) {
          throw ArgumentError('Step index $stepIndex out of range (1..${manifest.promptSteps.length})');
        }
        stepsToRun.add((index: stepIndex, step: manifest.promptSteps[stepIndex - 1]));
      } else {
        for (int i = 0; i < manifest.promptSteps.length; i++) {
          stepsToRun.add((index: i + 1, step: manifest.promptSteps[i]));
        }
      }

      if (stepsToRun.isEmpty) {
        stdout.writeln(TerminalPrinter.yellow('No prompt steps defined in skill. Nothing to execute.'));
        return;
      }

      for (final item in stepsToRun) {
        final currentStep = item.step;
        final stepPrompt = _applyParams(currentStep.text, parameters);

        stdout.writeln(
          TerminalPrinter.bold(
            TerminalPrinter.cyan('▶ Executing Step ${item.index}/${manifest.promptSteps.length}:'),
          ),
        );
        stdout.writeln(TerminalPrinter.dim('  "$stepPrompt"'));
        stdout.writeln('');

        await _executeTurn(
          llmConfig: llmConfig,
          systemPrompt: manifest.systemPrompt,
          promptText: stepPrompt,
          mcpManager: mcpManager,
          enabledToolNames: currentStep.enabledToolNames,
        );
      }
    } finally {
      await mcpManager.disconnectAll();
      mcpManager.dispose();
    }
  }

  /// Executes a single ad-hoc prompt directly with MCP tools.
  Future<void> runPrompt({
    required String promptText,
    String? customSystemPrompt,
  }) async {
    final llmConfig = loadLlmConfig();
    final localServers = loadMcpServers();
    final mcpManager = await connectMcpServers(localServers);

    try {
      await _executeTurn(
        llmConfig: llmConfig,
        systemPrompt: customSystemPrompt ?? 'You are a helpful AI assistant with tool access.',
        promptText: promptText,
        mcpManager: mcpManager,
      );
    } finally {
      await mcpManager.disconnectAll();
      mcpManager.dispose();
    }
  }

  /// Single execution turn through McpAgentEngine.
  Future<void> _executeTurn({
    required LlmConfig llmConfig,
    required String systemPrompt,
    required String promptText,
    required MultiMCPManager mcpManager,
    List<String>? enabledToolNames,
  }) async {
    final agent = Agent(
      key: 'cli_runner_agent',
      name: 'CLI Runner Agent',
      llmConfig: llmConfig,
      systemPrompt: systemPrompt,
      prompts: [
        SubPromptStep(
          text: promptText,
          enabledToolNames: enabledToolNames,
        ),
      ],
      localServers: [],
    );

    final engine = McpAgentEngine();
    engine.setAgents([agent]);

    try {
      final subscription = engine.agentEvents.listen((event) {
        switch (event) {
          case AgentLogEvent(:final message):
            if (verbose) {
              stdout.writeln(TerminalPrinter.dim('[engine] $message'));
            }
          case AgentToolResultEvent(
            :final toolName,
            :final parameters,
            :final result,
          ):
            TerminalPrinter.printToolCall(
              toolName: toolName,
              argumentsJson: _truncate(jsonEncode(parameters), 200),
              result: result,
            );
          case AgentAssistantResultEvent(:final response):
            stdout.writeln('');
            stdout.writeln(TerminalPrinter.bold('─── Assistant ───'));
            stdout.writeln(response.trim());
            stdout.writeln('');
          case AgentErrorEvent(:final error):
            stderr.writeln(TerminalPrinter.red('ERROR: $error'));
          case AgentFinalResultEvent():
            break;
          case AgentTextChunkEvent():
            break;
        }
      });

      await engine.run(agent.key, mcpManager: mcpManager);
      await Future.delayed(const Duration(milliseconds: 50));
      await subscription.cancel();
    } finally {
      await engine.dispose();
    }
  }

  String _applyParams(String template, Map<String, String> parameters) {
    var result = template;
    for (final entry in parameters.entries) {
      result = result.replaceAll('\${${entry.key}}', entry.value);
      result = result.replaceAll('{{${entry.key}}}', entry.value);
    }
    return result;
  }

  String _truncate(String s, int maxLen) {
    if (s.length <= maxLen) return s;
    return '${s.substring(0, maxLen)}...';
  }
}
