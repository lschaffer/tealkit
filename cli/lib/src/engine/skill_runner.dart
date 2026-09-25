import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp_core/dart_mcp_core.dart';
import 'package:yaml/yaml.dart';

import '../config/env_loader.dart';
import '../config/global_config.dart';
import '../config/llm_config_manager.dart';
import '../formatters/terminal_printer.dart';

/// Headless skill and prompt execution engine powered by `dart_mcp_core`.
class SkillRunner {
  final String llmConfigPath;
  final String toolsConfigPath;
  final bool verbose;

  SkillRunner({
    this.llmConfigPath = 'llm.yaml',
    this.toolsConfigPath = 'extern_mcp_tools.yaml',
    this.verbose = false,
  });

  /// Loads [LlmConfig] from [llmConfigPath] or named profile.
  LlmConfig loadLlmConfig({String? targetName}) {
    return LlmConfigManager.resolveConfig(
      nameOrPath: targetName,
      configPath: llmConfigPath,
    );
  }

  /// Loads external MCP server configurations from YAML file.
  List<McpServerConfig> loadMcpServers() {
    File file = GlobalConfigLocator.resolveConfigFile(toolsConfigPath);
    if (!file.existsSync()) {
      // Also check fallback mcp.yaml
      file = GlobalConfigLocator.resolveConfigFile('mcp.yaml');
      if (!file.existsSync()) return [];
    }

    try {
      final raw = file.readAsStringSync();
      final resolved = EnvLoader.substitute(raw, file.parent);
      final yaml = loadYaml(resolved) as YamlMap?;
      final serversList = yaml?['servers'] as YamlList?;
      if (serversList == null) return [];

      return serversList.whereType<YamlMap>().map((s) {
        final localEnv = s['env'] as YamlMap?;
        final name = (s['name'] as String?) ?? 'Unnamed';
        final id = (s['id'] as String?) ?? 'mcp_${serversList.indexOf(s)}';
        var localType = (s['local_type'] as String?)?.toLowerCase();
        var installMethod = (s['local_install_method'] as String?)?.toLowerCase();
        var pkg = (s['local_package'] as String?) ?? (s['packageName'] as String?) ?? '';
        var customCmd = (s['custom_launch_command'] as String?) ?? (s['customLaunchCommand'] as String?);

        final url = (s['url'] as String?) ?? (s['server_url'] as String?) ?? '';
        final isLocal = (s['is_local'] as bool?) ??
            !(url.trim().startsWith('http://') || url.trim().startsWith('https://'));
        final mcpEndpoint = (s['mcp_endpoint'] as String?) ?? '/mcp';
        final apiKey = (s['api_key'] as String?) ?? (s['apiKey'] as String?);
        final apiPassword = (s['api_password'] as String?) ?? (s['apiPassword'] as String?);

        // Fallback resolution if YAML has empty/missing package name for local server
        if (isLocal && pkg.trim().isEmpty) {
          if (name.contains('filesystem')) {
            pkg = '@modelcontextprotocol/server-filesystem';
            localType ??= 'nodejs';
            installMethod ??= 'npx';
          } else if (name.contains('fetch')) {
            pkg = 'mcp-server-fetch';
            localType ??= 'python';
            installMethod ??= 'uvx';
          } else if (name.contains('github')) {
            pkg = '@modelcontextprotocol/server-github';
            localType ??= 'nodejs';
            installMethod ??= 'npx';
          } else if (name.contains('puppeteer')) {
            pkg = '@modelcontextprotocol/server-puppeteer';
            localType ??= 'nodejs';
            installMethod ??= 'npx';
          } else if (name.contains('matplotlib')) {
            pkg = 'matplotlib';
            localType ??= 'python';
            installMethod ??= 'uvx';
          } else {
            pkg = name;
          }
        }

        // Infer install method if missing (for local servers)
        if (isLocal) {
          if (installMethod == null || installMethod.isEmpty) {
            if (localType == 'python') {
              installMethod = 'uvx';
            } else {
              installMethod = 'npx';
            }
          }
          if (installMethod == 'npm') installMethod = 'npx';

          // Ensure Windows uses npx.cmd for custom commands or launches
          if (customCmd != null && Platform.isWindows) {
            if (customCmd.startsWith('npx ')) {
              customCmd = 'npx.cmd ${customCmd.substring(4)}';
            }
          }

          // If customLaunchCommand is not provided, generate a sensible default
          if (customCmd == null || customCmd.trim().isEmpty) {
            if (installMethod == 'npx') {
              final npxExe = Platform.isWindows ? 'npx.cmd' : 'npx';
              final extra = pkg.contains('server-filesystem') ? ' .' : '';
              customCmd = '$npxExe -y $pkg$extra';
            } else if (installMethod == 'uvx') {
              customCmd = 'uvx $pkg';
            }
          }
        }

        return McpServerConfig(
          id: id,
          name: name,
          url: url,
          mcpEndpoint: mcpEndpoint,
          apiKey: apiKey,
          apiPassword: apiPassword,
          isLocal: isLocal,
          localType: localType,
          localInstallMethod: installMethod,
          localPackage: pkg,
          localCommand: s['local_command'] as String?,
          customLaunchCommand: customCmd,
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
    final activeServers = servers.where((s) => s.enabled).toList();

    if (activeServers.isEmpty) {
      stdout.writeln(TerminalPrinter.dim('No enabled MCP servers configured in mcp.yaml.'));
      return mcpManager;
    }

    stdout.writeln(TerminalPrinter.bold('Connecting to ${activeServers.length} configured MCP server(s)...'));

    for (int i = 0; i < activeServers.length; i++) {
      final server = activeServers[i];
      final typeLabel = server.isLocal ? 'stdio' : 'remote';
      final label = '[${i + 1}/${activeServers.length}] ${server.name} ($typeLabel)';
      stdout.write('  → $label: connecting... ');

      try {
        final MCPClient client;
        if (server.isLocal) {
          client = LocalMCPClient(
            server,
            logCallback: (msg, {bool isError = false}) {
              if (verbose) {
                stderr.writeln('\n      [LocalMCP:${server.name}] $msg');
              } else {
                final lower = msg.toLowerCase();
                if (lower.contains('download') ||
                    lower.contains('install') ||
                    lower.contains('resolv') ||
                    lower.contains('pull') ||
                    lower.contains('fetch')) {
                  stdout.write('\n      ($msg)... ');
                }
              }
            },
          );
        } else {
          client = MCPClient(
            server.url,
            mcpEndpoint: server.mcpEndpoint,
            bearerToken: server.apiKey,
            apiPassword: server.apiPassword,
            logCallback: (msg, {bool isError = false}) {
              if (verbose) {
                stderr.writeln('\n      [RemoteMCP:${server.name}] $msg');
              }
            },
          );
        }

        final clientDef = MCPClientDef(
          name: server.id,
          client: client,
          displayName: server.name,
        );
        mcpManager.registerClient(clientDef);

        await client.connect().timeout(
          const Duration(seconds: 25),
          onTimeout: () {
            throw TimeoutException('Timed out after 25s');
          },
        );

        final count = client.availableTools.length;
        if (count > 0) {
          stdout.writeln(TerminalPrinter.green('✔ connected ($count tool${count > 1 ? "s" : ""})'));
        } else {
          stdout.writeln(TerminalPrinter.yellow('✔ connected (0 tools reported)'));
        }
      } catch (e) {
        stdout.writeln(TerminalPrinter.red('✘ failed'));
        stdout.writeln(TerminalPrinter.yellow('      $e'));
        if (!verbose) {
          stdout.writeln(TerminalPrinter.dim('      (Run with --verbose to view full subprocess logs)'));
        }
      }
    }

    final totalTools = mcpManager.availableTools;
    if (totalTools.isNotEmpty) {
      stdout.writeln(TerminalPrinter.green('\n✔ Total tools available: ${totalTools.length} (${totalTools.map((t) => t.name).join(", ")})'));
    } else {
      stdout.writeln(TerminalPrinter.yellow('\nNo MCP tools currently available. Run with --verbose for detailed diagnostic logs.'));
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
          case AgentUsageEvent():
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
