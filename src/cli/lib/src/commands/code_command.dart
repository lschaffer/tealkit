import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dart_mcp_core/dart_mcp_core.dart';
import 'package:path/path.dart' as p;

import '../config/llm_config_manager.dart';
import '../config/permission_settings.dart';
import '../engine/mcp_manager_helper.dart';
import '../engine/session_manager.dart';
import '../engine/skill_runner.dart';
import '../engine/token_usage_tracker.dart';
import '../formatters/terminal_printer.dart';

enum CodingMode { architect, code, ask }

extension CodingModeExt on CodingMode {
  String get name => switch (this) {
    CodingMode.architect => 'architect',
    CodingMode.code => 'code',
    CodingMode.ask => 'ask',
  };

  String get displayName => switch (this) {
    CodingMode.architect => '📐 ARCHITECT (Planning & Analysis)',
    CodingMode.code => '💻 CODE (Implementation & Execution)',
    CodingMode.ask => '💬 ASK (General Q&A)',
  };
}

/// `tealkit code [--mode <architect|code|ask>]`
class CodeCommand extends Command {
  @override
  final String name = 'code';
  @override
  final String description =
      'Launch interactive coding agent REPL (Claude Code / Roo Code style) with native file and terminal tools.';

  CodeCommand() {
    argParser.addOption(
      'mode',
      abbr: 'm',
      allowed: ['architect', 'code', 'ask'],
      defaultsTo: 'code',
      help:
          'Initial agent mode (architect: planning/tasks.md, code: implementation, ask: Q&A)',
    );
    argParser.addOption(
      'instructions',
      abbr: 'i',
      help:
          'Path to custom instructions markdown file (default looks for tealkit_agent.md or AGENTS.md)',
    );
    argParser.addOption(
      'llm',
      help: 'Path to custom llm.yaml configuration or model name',
      defaultsTo: 'llm.yaml',
    );
    argParser.addOption(
      'llm-name',
      help: 'Select named LLM model profile from llm.yaml (e.g. ollama, deepseek, mistral)',
    );
    argParser.addOption(
      'tools',
      help: 'Path to custom extern_mcp_tools.yaml / mcp.yaml',
      defaultsTo: 'extern_mcp_tools.yaml',
    );
    argParser.addOption(
      'save-session',
      help: 'File path (.json or .md) to auto-save session transcript',
    );
    argParser.addOption(
      'load-session',
      help: 'File path (.json or .md) to load and continue a previous session',
    );
    argParser.addOption(
      'max-tool-iterations',
      abbr: 't',
      help: 'Maximum tool calls per step before synthesizing final response (defaults to 100)',
    );
    argParser.addFlag(
      'verbose',
      abbr: 'v',
      negatable: false,
      help: 'Print verbose logs and raw tool payloads',
    );
  }

  static const _helpText = '''
Commands:
  /mode <architect|code|ask>  Switch operational mode
  /plan                      Shortcut to switch to ARCHITECT mode
  /code                      Shortcut to switch to CODE mode
  /ask                       Shortcut to switch to ASK mode
  /llm                       List all configured LLM profiles and show active
  /llm <name> or /llm:<name> Switch active LLM profile (e.g. /llm:ollama, /llm mistral)
  /uninstall <name|all_mcp>  Uninstall/disconnect MCP server & clean package cache
  /save-session [path]       Save session transcript to .json or .md file
  /load-session <path>       Load and continue a saved session from .json or .md
  /clear-session, /clear     Clear conversation history and token statistics
  /estimated_costs, /costs   Display accumulated token usage and estimated API cost
  /session                   Display current session statistics and configuration
  /permissions               View or toggle tool approval requirements (write/exec)
  /auto-approve <on|off>     Toggle auto-approval for all tools in session
  /tasks                     Display current tasks.md if present
  /instructions              Show or reload tealkit_agent.md / custom instructions
  /tools                     List active native coding and external MCP tools
  /bye, /exit                Exit session
  /help, /?                  Show this help menu
''';

  @override
  Future<void> run() async {
    final modeStr = argResults?['mode'] as String? ?? 'code';
    final customInstructionsPath = argResults?['instructions'] as String?;
    final llmPath = argResults?['llm'] as String? ?? 'llm.yaml';
    final explicitLlmName = argResults?['llm-name'] as String?;
    final toolsPath =
        argResults?['tools'] as String? ?? 'extern_mcp_tools.yaml';
    String? autoSavePath = argResults?['save-session'] as String?;
    final loadSessionPath = argResults?['load-session'] as String?;
    final verbose = argResults?['verbose'] as bool? ?? false;

    CodingMode currentMode = switch (modeStr) {
      'architect' => CodingMode.architect,
      'ask' => CodingMode.ask,
      _ => CodingMode.code,
    };

    final runner = SkillRunner(
      llmConfigPath: llmPath,
      toolsConfigPath: toolsPath,
      verbose: verbose,
    );

    // Resolve initial LLM config (supporting named profile or path)
    final targetLlm = explicitLlmName ?? (llmPath != 'llm.yaml' && !llmPath.endsWith('.yaml') && !llmPath.endsWith('.yml') && !File(llmPath).existsSync() ? llmPath : null);
    LlmConfig activeLlmConfig = runner.loadLlmConfig(targetName: targetLlm);
    String activeLlmName = targetLlm ?? 'default';

    // Find friendly active LLM name if possible
    final allProfiles = LlmConfigManager.loadAllProfiles(configPath: llmPath);
    for (final p in allProfiles) {
      if (p.config.model == activeLlmConfig.model && p.config.provider == activeLlmConfig.provider) {
        activeLlmName = p.name;
        break;
      }
    }

    final workspaceDir = Directory.current.path;
    final permissions = ToolPermissionSettings.load();

    // Load workspace custom instructions (tealkit_agent.md, AGENTS.md, or specified)
    String userInstructions = _loadWorkspaceInstructions(
      customInstructionsPath,
    );

    // 1. Initialize Native Coding Tools via shared dart_mcp_core
    final dartTools = CodingTools.createAll(workingDirectory: workspaceDir);

    // 2. Connect External MCP Servers from mcp.yaml / extern_mcp_tools.yaml if present
    var localServers = runner.loadMcpServers();
    var mcpManager = await runner.connectMcpServers(localServers);
    var mcpTools = mcpManager.availableTools;

    final toolNames = dartTools.map((t) => t.name).toList();
    final half = (toolNames.length / 2).ceil();
    final toolsLine1 = toolNames.take(half).join(', ');
    final toolsLine2 = toolNames.skip(half).join(', ');

    final activeMcpNames = localServers
        .where((s) => s.enabled)
        .map((s) => s.name)
        .toList();
    final mcpSummary = activeMcpNames.isNotEmpty
        ? '${activeMcpNames.length} active (${activeMcpNames.join(", ")})'
        : '(none in mcp.yaml)';

    final history = <ChatMessage>[];
    final usageTracker = TokenUsageTracker();

    // Load initial session if requested
    if (loadSessionPath != null) {
      try {
        final session = await SessionManager.loadSession(loadSessionPath);
        history.addAll(session.messages);
        if (session.mode == 'architect') currentMode = CodingMode.architect;
        if (session.mode == 'ask') currentMode = CodingMode.ask;
        if (session.mode == 'code') currentMode = CodingMode.code;
        stdout.writeln(
          TerminalPrinter.green(
            '✔ Loaded session from "$loadSessionPath" (${history.length} messages restored).',
          ),
        );
        autoSavePath ??= loadSessionPath;
      } catch (e) {
        stderr.writeln(
          TerminalPrinter.yellow('Warning: Could not load session from "$loadSessionPath": $e'),
        );
      }
    }

    TerminalPrinter.printBanner('TealKit Coding Agent (v1.1.0)', [
      'Workspace    : $workspaceDir',
      'LLM Profile  : $activeLlmName (${activeLlmConfig.provider.displayName} / ${activeLlmConfig.model})',
      'Active Mode  : ${currentMode.displayName}',
      'MCP Servers  : $mcpSummary',
      'Permissions  : Write=${permissions.autoApproveWrite ? "Auto" : "Ask"}, Exec=${permissions.autoApproveExecute ? "Auto" : "Ask"}',
      'Instructions : ${userInstructions.isNotEmpty ? "Loaded from workspace" : "(None found, default active)"}',
      if (autoSavePath != null) 'Session File : $autoSavePath',
      'Native Tools (${toolNames.length}): $toolsLine1,',
      '               $toolsLine2',
    ]);

    stdout.writeln(
      TerminalPrinter.dim(
        'Type your request, switch modes with /plan or /code, or type /help for commands.',
      ),
    );
    stdout.writeln('');

    while (true) {
      final promptPrefix = switch (currentMode) {
        CodingMode.architect => '[architect] > ',
        CodingMode.code => '[code] > ',
        CodingMode.ask => '[ask] > ',
      };

      stdout.write(TerminalPrinter.cyan(promptPrefix));
      final rawInput = stdin.readLineSync();
      if (rawInput == null) break;

      final input = rawInput.trim();
      if (input.isEmpty) continue;

      if (input == '/bye' || input == '/exit') break;

      if (input == '/help' || input == '/?') {
        stdout.writeln(_helpText);
        continue;
      }

      if (input == '/plan' || input == '/architect') {
        currentMode = CodingMode.architect;
        stdout.writeln(
          TerminalPrinter.green('Switched to ${currentMode.displayName}'),
        );
        stdout.writeln('');
        continue;
      }

      if (input == '/code') {
        currentMode = CodingMode.code;
        stdout.writeln(
          TerminalPrinter.green('Switched to ${currentMode.displayName}'),
        );
        stdout.writeln('');
        continue;
      }

      if (input == '/ask') {
        currentMode = CodingMode.ask;
        stdout.writeln(
          TerminalPrinter.green('Switched to ${currentMode.displayName}'),
        );
        stdout.writeln('');
        continue;
      }

      if (input.startsWith('/mode')) {
        final parts = input.split(RegExp(r'\s+'));
        if (parts.length > 1) {
          final target = parts[1].toLowerCase();
          currentMode = switch (target) {
            'architect' || 'plan' => CodingMode.architect,
            'ask' => CodingMode.ask,
            _ => CodingMode.code,
          };
          stdout.writeln(
            TerminalPrinter.green('Switched to ${currentMode.displayName}'),
          );
        } else {
          stdout.writeln('Current mode: ${currentMode.displayName}');
          stdout.writeln('Usage: /mode <architect|code|ask>');
        }
        stdout.writeln('');
        continue;
      }

      // ── LLM Model Listing & Switching (/llm, /llm:<name>, /llm <name>) ──
      if (input.startsWith('/llm')) {
        String? target;
        if (input.startsWith('/llm:')) {
          target = input.substring(5).trim();
        } else {
          final parts = input.split(RegExp(r'\s+'));
          if (parts.length > 1) {
            target = parts.sublist(1).join(' ').trim();
          }
        }

        final profiles = LlmConfigManager.loadAllProfiles(configPath: llmPath);

        if (target == null || target.isEmpty) {
          stdout.writeln(TerminalPrinter.bold('--- Configured LLM Profiles ---'));
          for (final p in profiles) {
            final isCurrent = (p.name == activeLlmName) ||
                (p.config.model == activeLlmConfig.model && p.config.provider == activeLlmConfig.provider);
            final marker = isCurrent ? TerminalPrinter.green('* [ACTIVE]') : ' ';
            stdout.writeln(
              '  $marker ${TerminalPrinter.bold(p.name.padRight(12))} : ${p.config.provider.displayName} / ${p.config.model} (temp: ${p.config.temperature}, max_tokens: ${p.config.maxTokens})',
            );
          }
          stdout.writeln('--------------------------------');
          stdout.writeln(TerminalPrinter.dim('Usage: /llm <name> or /llm:<name> (e.g. /llm:ollama, /llm deepseek)'));
          stdout.writeln('');
          continue;
        }

        try {
          final newConfig = LlmConfigManager.resolveConfig(nameOrPath: target, configPath: llmPath);
          activeLlmConfig = newConfig;
          activeLlmName = target;
          for (final p in profiles) {
            if (p.name.toLowerCase() == target.toLowerCase()) {
              activeLlmName = p.name;
              break;
            }
          }
          stdout.writeln(
            TerminalPrinter.green(
              '✔ Switched LLM to: $activeLlmName (${activeLlmConfig.provider.displayName} / ${activeLlmConfig.model})',
            ),
          );
        } catch (e) {
          stderr.writeln(TerminalPrinter.red('Error switching LLM: $e'));
        }
        stdout.writeln('');
        continue;
      }

      // ── MCP Uninstall / Remove (/uninstall <name|all_mcp>) ──
      if (input.startsWith('/uninstall')) {
        final parts = input.split(RegExp(r'\s+'));
        if (parts.length < 2) {
          stdout.writeln('Usage: /uninstall <server_name|server_id|all_mcp>');
          stdout.writeln(TerminalPrinter.dim('Available MCP servers: ${localServers.map((s) => s.name).join(", ")}'));
          stdout.writeln('');
          continue;
        }

        final target = parts.sublist(1).join(' ').trim();
        stdout.writeln(TerminalPrinter.bold('Uninstalling MCP server(s) matching "$target"...'));
        final results = await McpManagerHelper.uninstallServers(
          targetQuery: target,
          configuredServers: localServers,
          mcpManager: mcpManager,
          verbose: verbose,
        );

        if (results.isNotEmpty) {
          mcpTools = mcpManager.availableTools;
          stdout.writeln(
            TerminalPrinter.green(
              '✔ MCP server uninstalled. Remaining MCP tools: ${mcpTools.length} (${mcpTools.map((t) => t.name).join(", ")})',
            ),
          );
        }
        stdout.writeln('');
        continue;
      }

      // ── Session Management: /save-session, /load-session, /clear-session, /session ──
      if (input.startsWith('/save-session') || input.startsWith('/save')) {
        final parts = input.split(RegExp(r'\s+'));
        String targetPath;
        if (parts.length > 1) {
          targetPath = parts.sublist(1).join(' ').trim();
        } else if (autoSavePath != null) {
          targetPath = autoSavePath;
        } else {
          final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
          targetPath = 'coding-session-$timestamp.json';
        }

        try {
          final session = SessionData(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            title: 'TealKit Coding Session',
            mode: currentMode.name,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
            llmName: activeLlmName,
            llmProvider: activeLlmConfig.provider.displayName,
            llmModel: activeLlmConfig.model,
            messages: history,
          );
          final savedFile = await SessionManager.saveSession(session, targetPath);
          autoSavePath = savedFile.path;
          stdout.writeln(
            TerminalPrinter.green(
              '✔ Session saved successfully to "${savedFile.path}" (${history.length} messages recorded).',
            ),
          );
        } catch (e) {
          stderr.writeln(TerminalPrinter.red('Error saving session: $e'));
        }
        stdout.writeln('');
        continue;
      }

      if (input.startsWith('/load-session') || input.startsWith('/load')) {
        final parts = input.split(RegExp(r'\s+'));
        if (parts.length < 2) {
          stdout.writeln('Usage: /load-session <path-to-session.json-or-md>');
          stdout.writeln('');
          continue;
        }

        final targetPath = parts.sublist(1).join(' ').trim();
        try {
          final session = await SessionManager.loadSession(targetPath);
          history.clear();
          history.addAll(session.messages);
          if (session.mode == 'architect') currentMode = CodingMode.architect;
          if (session.mode == 'ask') currentMode = CodingMode.ask;
          if (session.mode == 'code') currentMode = CodingMode.code;
          autoSavePath = targetPath;
          stdout.writeln(
            TerminalPrinter.green(
              '✔ Restored session from "$targetPath" (${history.length} messages loaded, mode: ${currentMode.displayName}).',
            ),
          );
        } catch (e) {
          stderr.writeln(TerminalPrinter.red('Error loading session: $e'));
        }
        stdout.writeln('');
        continue;
      }

      if (input == '/clear-session' || input == '/clear') {
        history.clear();
        usageTracker.reset();
        stdout.writeln(TerminalPrinter.dim('Conversation history and token/cost statistics cleared.'));
        stdout.writeln('');
        continue;
      }

      if (input == '/estimated_costs' || input == '/costs' || input == '/cost' || input == '/tokens' || input == '/usage') {
        stdout.writeln(usageTracker.formatReport(activeLlmConfig, modelDisplayName: activeLlmName));
        stdout.writeln('');
        continue;
      }

      if (input == '/session') {
        stdout.writeln(TerminalPrinter.bold('--- Session Information ---'));
        stdout.writeln('  Mode             : ${currentMode.displayName}');
        stdout.writeln('  Active LLM       : $activeLlmName (${activeLlmConfig.provider.displayName} / ${activeLlmConfig.model})');
        stdout.writeln('  History Messages : ${history.length}');
        stdout.writeln('  Tokens Tracked   : ${usageTracker.totalTokens} (est. \$${usageTracker.calculateEstimatedCost(activeLlmConfig).toStringAsFixed(6)})');
        stdout.writeln('  Auto-Save File   : ${autoSavePath ?? "(not set, use /save-session <path>)"}');
        stdout.writeln('  Workspace        : $workspaceDir');
        stdout.writeln('---------------------------');
        stdout.writeln('');
        continue;
      }

      if (input == '/auto-approve') {
        final parts = input.split(RegExp(r'\s+'));
        if (parts.length > 1 && parts[1].toLowerCase() == 'on') {
          permissions.autoApproveWrite = true;
          permissions.autoApproveExecute = true;
          permissions.save();
          stdout.writeln(
            TerminalPrinter.green(
              'Auto-approval ENABLED for write & exec tools.',
            ),
          );
        } else if (parts.length > 1 && parts[1].toLowerCase() == 'off') {
          permissions.autoApproveWrite = false;
          permissions.autoApproveExecute = false;
          permissions.save();
          stdout.writeln(
            TerminalPrinter.yellow(
              'Auto-approval DISABLED (will prompt on write & exec).',
            ),
          );
        } else {
          stdout.writeln('Usage: /auto-approve <on|off>');
        }
        stdout.writeln('');
        continue;
      }

      if (input == '/permissions') {
        stdout.writeln(
          TerminalPrinter.bold('--- Tool Permissions Configuration ---'),
        );
        stdout.writeln(
          '  Read operations   (fs_read_file, fs_find)   : ${permissions.autoApproveRead ? "Auto-Approved" : "Requires Confirmation"}',
        );
        stdout.writeln(
          '  Write operations  (fs_write, fs_replace)    : ${permissions.autoApproveWrite ? "Auto-Approved" : "Requires Confirmation"}',
        );
        stdout.writeln(
          '  Execute commands  (terminal_exec)           : ${permissions.autoApproveExecute ? "Auto-Approved" : "Requires Confirmation"}',
        );
        stdout.writeln(
          '  Network actions   (remote MCP)              : ${permissions.autoApproveNetwork ? "Auto-Approved" : "Requires Confirmation"}',
        );
        stdout.writeln(
          TerminalPrinter.dim(
            'Tip: Use "/auto-approve on" or edit ~/.tealkit/permissions.yaml',
          ),
        );
        stdout.writeln('--------------------------------------');
        stdout.writeln('');
        continue;
      }

      if (input == '/tasks') {
        final tasksFile = File(p.join(workspaceDir, 'tasks.md'));
        if (tasksFile.existsSync()) {
          stdout.writeln(TerminalPrinter.bold('--- tasks.md ---'));
          stdout.writeln(tasksFile.readAsStringSync().trim());
          stdout.writeln(TerminalPrinter.bold('----------------'));
        } else {
          stdout.writeln('No tasks.md found in workspace.');
        }
        stdout.writeln('');
        continue;
      }

      if (input == '/instructions') {
        userInstructions = _loadWorkspaceInstructions(customInstructionsPath);
        if (userInstructions.isNotEmpty) {
          stdout.writeln(TerminalPrinter.bold('Workspace Instructions:'));
          stdout.writeln(userInstructions);
        } else {
          stdout.writeln(
            'No custom instructions found. You can create a "tealkit_agent.md" file in the workspace root.',
          );
        }
        stdout.writeln('');
        continue;
      }

      if (input == '/tools') {
        stdout.writeln(
          TerminalPrinter.bold('Native Coding Tools (${dartTools.length}):'),
        );
        for (final t in dartTools) {
          stdout.writeln(
            '  • ${TerminalPrinter.cyan(t.name)} (${t.riskLevel.name}) — ${t.description}',
          );
        }
        if (mcpTools.isNotEmpty) {
          stdout.writeln('');
          stdout.writeln(
            TerminalPrinter.bold('External MCP Tools (${mcpTools.length}):'),
          );
          for (final t in mcpTools) {
            stdout.writeln(
              '  • ${TerminalPrinter.green(t.name)} — ${t.description ?? "(no description)"}',
            );
          }
        }
        stdout.writeln('');
        continue;
      }

      // Build effective system prompt tailored for mode and instructions
      final systemPrompt = _buildSystemPrompt(
        mode: currentMode,
        workspaceDir: workspaceDir,
        userInstructions: userInstructions,
      );

      final cliMaxToolIterations =
          int.tryParse(argResults?['max-tool-iterations'] as String? ?? '');

      final agent = Agent(
        key: 'code_agent',
        name: 'Coding Assistant',
        llmConfig: activeLlmConfig,
        systemPrompt: systemPrompt,
        prompts: [SubPromptStep(text: input)],
        dartTools: dartTools,
        localServers: localServers.where((s) => s.isLocal).toList(),
        remoteServers: localServers.where((s) => !s.isLocal).toList(),
        initialMessages: history,
        maxToolIterations: cliMaxToolIterations,
      );

      final engine = McpAgentEngine();
      engine.setAgents([agent]);

      bool turnSuccess = false;
      String lastAssistantResponse = '';

      try {
        final subscription = engine.agentEvents.listen((event) {
          switch (event) {
            case AgentLogEvent(:final message):
              if (verbose) {
                stdout.writeln(TerminalPrinter.dim('[log] $message'));
              }
            case AgentToolResultEvent(
              :final toolName,
              :final parameters,
              :final result,
            ):
              TerminalPrinter.printToolCall(
                toolName: toolName,
                argumentsJson: jsonEncode(parameters),
                result: result,
              );
            case AgentAssistantResultEvent(:final response):
              lastAssistantResponse = response;
              stdout.writeln('');
              stdout.writeln(response.trim());
              stdout.writeln('');
            case AgentErrorEvent(:final error):
              stderr.writeln(TerminalPrinter.red('❌ ERROR: $error'));
            case AgentFinalResultEvent(:final response, :final messages):
              if (response.isNotEmpty) {
                lastAssistantResponse = response;
              }
              if (messages.isNotEmpty) {
                history.clear();
                history.addAll(messages);
              }
            case AgentUsageEvent(:final promptTokens, :final completionTokens):
              usageTracker.recordUsage(prompt: promptTokens, completion: completionTokens);
            case AgentTextChunkEvent():
              break;
          }
        });

        try {
          await engine.run(
            agent.key,
            onToolApproval:
                ({
                  required String toolName,
                  required Map<String, dynamic> parameters,
                  required ToolRiskLevel riskLevel,
                }) async {
                  final autoApproved = switch (riskLevel) {
                    ToolRiskLevel.read => permissions.autoApproveRead,
                    ToolRiskLevel.write => permissions.autoApproveWrite,
                    ToolRiskLevel.execute => permissions.autoApproveExecute,
                    ToolRiskLevel.network => permissions.autoApproveNetwork,
                  };

                  if (autoApproved) return true;

                  // Interactive prompt for user approval
                  stdout.writeln('');
                  stdout.writeln(
                    TerminalPrinter.yellow('⚠️  Tool Approval Requested:'),
                  );
                  stdout.writeln(
                    '  • Tool   : ${TerminalPrinter.cyan(toolName)} ($riskLevel)',
                  );
                  stdout.writeln('  • Args   : ${jsonEncode(parameters)}');
                  stdout.write(
                    TerminalPrinter.bold(
                      'Approve execution? [y/n/always/deny-all] > ',
                    ),
                  );

                  final response = stdin.readLineSync()?.trim().toLowerCase();
                  if (response == 'a' || response == 'always') {
                    if (riskLevel == ToolRiskLevel.write) {
                      permissions.autoApproveWrite = true;
                    } else if (riskLevel == ToolRiskLevel.execute) {
                      permissions.autoApproveExecute = true;
                    }
                    permissions.save();
                    stdout.writeln(
                      TerminalPrinter.green(
                        'Approved and saved to preferences.',
                      ),
                    );
                    return true;
                  } else if (response == 'd' || response == 'deny-all') {
                    permissions.autoApproveWrite = false;
                    permissions.autoApproveExecute = false;
                    permissions.save();
                    stdout.writeln(
                      TerminalPrinter.red('Denied and disabled auto-approval.'),
                    );
                    return false;
                  }

                  final approved =
                      response == 'y' || response == 'yes' || response == '';
                  if (!approved) {
                    stdout.writeln(
                      TerminalPrinter.red('Tool execution rejected by user.'),
                    );
                  }
                  return approved;
                },
          );
          turnSuccess = true;
        } catch (e, stack) {
          stderr.writeln('');
          stderr.writeln(TerminalPrinter.red('❌ Execution Error during turn:'));
          stderr.writeln(TerminalPrinter.yellow('   $e'));
          if (e.toString().contains('400') ||
              e.toString().contains('context_length') ||
              e.toString().contains('max_tokens')) {
            stderr.writeln(
              TerminalPrinter.dim(
                '   Tip: The model returned a request error. Check max_tokens or use /clear-session to reset history.',
              ),
            );
          }
          if (verbose) {
            stderr.writeln(TerminalPrinter.dim('\nStacktrace:\n$stack'));
          } else {
            stderr.writeln(
              TerminalPrinter.dim('   (Run with --verbose for complete debug logs)'),
            );
          }
        } finally {
          await Future.delayed(const Duration(milliseconds: 50));
          await subscription.cancel();
        }
      } finally {
        await engine.dispose();
      }

      if (turnSuccess) {
        if (history.isEmpty) {
          history.add(
            ChatMessage(
              id: DateTime.now().millisecondsSinceEpoch.toString(),
              content: input,
              role: ChatRole.user,
              timestamp: DateTime.now(),
            ),
          );
          if (lastAssistantResponse.isNotEmpty) {
            history.add(
              ChatMessage(
                id: (DateTime.now().millisecondsSinceEpoch + 1).toString(),
                content: lastAssistantResponse,
                role: ChatRole.assistant,
                timestamp: DateTime.now(),
              ),
            );
          }
        }

        // Auto-save session if path is configured
        if (autoSavePath != null) {
          try {
            final session = SessionData(
              id: DateTime.now().millisecondsSinceEpoch.toString(),
              title: 'TealKit Coding Session',
              mode: currentMode.name,
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
              llmName: activeLlmName,
              llmProvider: activeLlmConfig.provider.displayName,
              llmModel: activeLlmConfig.model,
              messages: history,
            );
            await SessionManager.saveSession(session, autoSavePath);
          } catch (_) {}
        }
      }
    }

    try {
      await mcpManager.disconnectAll();
    } catch (_) {}

    stdout.writeln(
      TerminalPrinter.green('Exiting coding agent session. Goodbye!'),
    );
  }

  String _loadWorkspaceInstructions(String? explicitPath) {
    if (explicitPath != null && File(explicitPath).existsSync()) {
      return File(explicitPath).readAsStringSync().trim();
    }
    // Check standard files: tealkit_agent.md, AGENTS.md, CLAUDE.md
    for (final filename in ['tealkit_agent.md', 'AGENTS.md', 'CLAUDE.md']) {
      final file = File(p.join(Directory.current.path, filename));
      if (file.existsSync()) {
        return file.readAsStringSync().trim();
      }
    }
    return '';
  }

  String _buildSystemPrompt({
    required CodingMode mode,
    required String workspaceDir,
    required String userInstructions,
  }) {
    final buffer = StringBuffer();

    buffer.writeln('''
You are an expert autonomous software engineer and coding assistant inside the TealKit CLI environment.
Working Directory: $workspaceDir

Operating Principles:
1. EXPLORE FIRST: Discover project files, frameworks, build systems, and versions using `fs_find` and `fs_read_file`.
2. SURGICAL EDITS: When modifying existing files, use `fs_replace_text` with unique context blocks instead of rewriting full files whenever possible. Use `fs_write_file` to create new files.
3. VERIFY WITH TERMINAL: After code changes, execute build and test commands (e.g. `dotnet build`, `dart test`, `npm test`) using `terminal_exec`.
4. FORMATTING: Use clean markdown, diff blocks, and concise technical explanations.
''');

    switch (mode) {
      case CodingMode.architect:
        buffer.writeln('''
CURRENT MODE: 📐 ARCHITECT (Planning & Analysis Mode)
- Your goal is to inspect the codebase, perform architectural review, design systems, and draft implementation plans.
- DO NOT modify production source code in this mode.
- ALWAYS create or update `tasks.md` in the workspace root with a Markdown checkbox checklist (`- [ ] task description`).
- When asked for an implementation plan, create or update `implementation_plan.md` or a requested document with clear rationale, affected files, and verification steps.
- Conclude by asking the user if they approve the plan and want to switch to `/code` mode to begin execution.
''');
        break;
      case CodingMode.code:
        buffer.writeln('''
CURRENT MODE: 💻 CODE (Implementation Mode)
- Your goal is to implement, refactor, and fix code according to specifications.
- If `tasks.md` exists in the workspace, check it for pending tasks `- [ ]`.
- As you complete and verify each task with `terminal_exec`, update `tasks.md` using `fs_replace_text` to check off the completed item (`- [x]`).
- Always run the relevant build or test command after editing code to ensure you did not introduce syntax errors or broken imports.
''');
        break;
      case CodingMode.ask:
        buffer.writeln('''
CURRENT MODE: 💬 ASK (Q&A & Exploration Mode)
- Your goal is to answer questions, explain concepts, and explore code without making changes.
- Read-only tools (`fs_find`, `fs_read_file`) and informative commands (`terminal_exec` for git log / status) are preferred.
''');
        break;
    }

    if (userInstructions.isNotEmpty) {
      buffer.writeln('''
==============================
WORKSPACE CUSTOM INSTRUCTIONS (from tealkit_agent.md):
$userInstructions
==============================
''');
    }

    return buffer.toString();
  }
}
