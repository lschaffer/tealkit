import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dart_mcp_core/dart_mcp_core.dart';

import '../config/llm_config_manager.dart';
import '../engine/mcp_manager_helper.dart';
import '../engine/session_manager.dart';
import '../engine/skill_runner.dart';
import '../engine/token_usage_tracker.dart';
import '../formatters/terminal_printer.dart';

/// `tealkit chat [--skill <path>]`
class ChatCommand extends Command {
  @override
  final String name = 'chat';
  @override
  final String description =
      'Start an interactive multi-turn terminal agent session.';

  ChatCommand() {
    argParser.addOption(
      'skill',
      abbr: 's',
      help: 'Preload system prompt and tools from a SKILL.md file',
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
      help: 'Print verbose logs',
    );
  }

  static const _helpText = '''
Commands:
  /llm                       List all configured LLM profiles and show active
  /llm <name> or /llm:<name> Switch active LLM profile (e.g. /llm:ollama, /llm mistral)
  /uninstall <name|all_mcp>  Uninstall/disconnect MCP server & clean package cache
  /save-session [path]       Save session transcript to .json or .md file
  /load-session <path>       Load and continue a saved session from .json or .md
  /clear-session, /clear     Clear conversation history and token statistics
  /estimated_costs, /costs   Display accumulated token usage and estimated API cost
  /session                   Display current session statistics and configuration
  /tools                     List available MCP tools
  /system                    Display current system prompt
  /bye, /exit                Quit interactive chat
  /help, /?                  Show this help
''';

  @override
  Future<void> run() async {
    final skillPath = argResults?['skill'] as String?;
    final llmPath = argResults?['llm'] as String? ?? 'llm.yaml';
    final explicitLlmName = argResults?['llm-name'] as String?;
    final toolsPath =
        argResults?['tools'] as String? ?? 'extern_mcp_tools.yaml';
    String? autoSavePath = argResults?['save-session'] as String?;
    final loadSessionPath = argResults?['load-session'] as String?;
    final verbose = argResults?['verbose'] as bool? ?? false;

    final runner = SkillRunner(
      llmConfigPath: llmPath,
      toolsConfigPath: toolsPath,
      verbose: verbose,
    );

    // Resolve initial LLM config
    final targetLlm = explicitLlmName ?? (llmPath != 'llm.yaml' && !llmPath.endsWith('.yaml') && !llmPath.endsWith('.yml') && !File(llmPath).existsSync() ? llmPath : null);
    LlmConfig activeLlmConfig = runner.loadLlmConfig(targetName: targetLlm);
    String activeLlmName = targetLlm ?? 'default';

    final allProfiles = LlmConfigManager.loadAllProfiles(configPath: llmPath);
    for (final p in allProfiles) {
      if (p.config.model == activeLlmConfig.model && p.config.provider == activeLlmConfig.provider) {
        activeLlmName = p.name;
        break;
      }
    }

    var localServers = runner.loadMcpServers();

    String systemPrompt =
        'You are a helpful AI assistant. Use available tools when needed.';
    String sessionTitle = 'TealKit Interactive Agent Chat';

    if (skillPath != null) {
      try {
        final manifest = runner.parseSkillFile(skillPath);
        if (manifest.systemPrompt.trim().isNotEmpty) {
          systemPrompt = manifest.systemPrompt;
        }
        sessionTitle = 'Chat: ${manifest.name}';
      } catch (e) {
        stderr.writeln(
          TerminalPrinter.yellow(
            'Warning: Could not load skill "$skillPath": $e',
          ),
        );
      }
    }

    final conversation = <ChatMessage>[];
    final usageTracker = TokenUsageTracker();

    if (loadSessionPath != null) {
      try {
        final session = await SessionManager.loadSession(loadSessionPath);
        conversation.addAll(session.messages);
        stdout.writeln(
          TerminalPrinter.green(
            '✔ Loaded session from "$loadSessionPath" (${conversation.length} messages restored).',
          ),
        );
        autoSavePath ??= loadSessionPath;
      } catch (e) {
        stderr.writeln(
          TerminalPrinter.yellow('Warning: Could not load session from "$loadSessionPath": $e'),
        );
      }
    }

    TerminalPrinter.printBanner(sessionTitle, [
      'LLM Profile : $activeLlmName (${activeLlmConfig.provider.displayName} / ${activeLlmConfig.model})',
      'MCP Servers : ${localServers.length} configured',
      if (autoSavePath != null) 'Session File: $autoSavePath',
      'Commands    : Type /help for slash commands, /exit to quit',
    ]);

    var mcpManager = await runner.connectMcpServers(localServers);

    stdout.writeln('');
    stdout.writeln('Enter your message (type /exit to quit):');
    stdout.writeln('');

    try {
      while (true) {
        stdout.write(TerminalPrinter.cyan('> '));
        final rawInput = stdin.readLineSync();
        if (rawInput == null) break;

        final input = rawInput.trim();
        if (input.isEmpty) continue;

        if (input == '/bye' || input == '/exit') break;
        if (input == '/help' || input == '/?') {
          stdout.writeln(_helpText);
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
            final tools = mcpManager.availableTools;
            stdout.writeln(
              TerminalPrinter.green(
                '✔ MCP server uninstalled. Remaining MCP tools: ${tools.length} (${tools.map((t) => t.name).join(", ")})',
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
            targetPath = 'chat-session-$timestamp.json';
          }

          try {
            final session = SessionData(
              id: DateTime.now().millisecondsSinceEpoch.toString(),
              title: 'TealKit Chat Session',
              mode: 'chat',
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
              llmName: activeLlmName,
              llmProvider: activeLlmConfig.provider.displayName,
              llmModel: activeLlmConfig.model,
              messages: conversation,
            );
            final savedFile = await SessionManager.saveSession(session, targetPath);
            autoSavePath = savedFile.path;
            stdout.writeln(
              TerminalPrinter.green(
                '✔ Session saved successfully to "${savedFile.path}" (${conversation.length} messages recorded).',
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
            conversation.clear();
            conversation.addAll(session.messages);
            autoSavePath = targetPath;
            stdout.writeln(
              TerminalPrinter.green(
                '✔ Restored session from "$targetPath" (${conversation.length} messages loaded).',
              ),
            );
          } catch (e) {
            stderr.writeln(TerminalPrinter.red('Error loading session: $e'));
          }
          stdout.writeln('');
          continue;
        }

        if (input == '/clear-session' || input == '/clear') {
          conversation.clear();
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
          stdout.writeln('  Active LLM       : $activeLlmName (${activeLlmConfig.provider.displayName} / ${activeLlmConfig.model})');
          stdout.writeln('  History Messages : ${conversation.length}');
          stdout.writeln('  Tokens Tracked   : ${usageTracker.totalTokens} (est. \$${usageTracker.calculateEstimatedCost(activeLlmConfig).toStringAsFixed(6)})');
          stdout.writeln('  Auto-Save File   : ${autoSavePath ?? "(not set, use /save-session <path>)"}');
          stdout.writeln('---------------------------');
          stdout.writeln('');
          continue;
        }

        if (input == '/tools') {
          final tools = mcpManager.availableTools;
          if (tools.isEmpty) {
            stdout.writeln('No MCP tools connected.');
            stdout.writeln(
              TerminalPrinter.dim(
                'Tip: Check mcp.yaml or run with "tealkit chat --verbose" for diagnostics.',
              ),
            );
          } else {
            stdout.writeln(
              TerminalPrinter.bold('Available tools (${tools.length}):'),
            );
            for (final t in tools) {
              stdout.writeln(
                '  • ${TerminalPrinter.cyan(t.name)} — ${t.description ?? "(no description)"}',
              );
            }
          }
          stdout.writeln('');
          continue;
        }

        if (input == '/system') {
          stdout.writeln(TerminalPrinter.bold('System prompt:'));
          stdout.writeln(systemPrompt);
          stdout.writeln('');
          continue;
        }

        final cliMaxToolIterations =
            int.tryParse(argResults?['max-tool-iterations'] as String? ?? '');

        final agent = Agent(
          key: 'chat_agent',
          name: 'Chat Agent',
          llmConfig: activeLlmConfig,
          systemPrompt: systemPrompt,
          prompts: [SubPromptStep(text: input)],
          localServers: [],
          initialMessages: conversation,
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
                  conversation.clear();
                  conversation.addAll(messages);
                }
              case AgentUsageEvent(:final promptTokens, :final completionTokens):
                usageTracker.recordUsage(prompt: promptTokens, completion: completionTokens);
              case AgentTextChunkEvent():
                break;
            }
          });

          try {
            await engine.run(agent.key, mcpManager: mcpManager);
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
          if (conversation.isEmpty) {
            conversation.add(
              ChatMessage(
                id: DateTime.now().millisecondsSinceEpoch.toString(),
                content: input,
                role: ChatRole.user,
                timestamp: DateTime.now(),
              ),
            );
            if (lastAssistantResponse.isNotEmpty) {
              conversation.add(
                ChatMessage(
                  id: (DateTime.now().millisecondsSinceEpoch + 1).toString(),
                  content: lastAssistantResponse,
                  role: ChatRole.assistant,
                  timestamp: DateTime.now(),
                ),
              );
            }
          }

          if (autoSavePath != null) {
            try {
              final session = SessionData(
                id: DateTime.now().millisecondsSinceEpoch.toString(),
                title: 'TealKit Chat Session',
                mode: 'chat',
                createdAt: DateTime.now(),
                updatedAt: DateTime.now(),
                llmName: activeLlmName,
                llmProvider: activeLlmConfig.provider.displayName,
                llmModel: activeLlmConfig.model,
                messages: conversation,
              );
              await SessionManager.saveSession(session, autoSavePath);
            } catch (_) {}
          }
        }
      }
    } finally {
      stdout.writeln('');
      stdout.writeln('Disconnecting MCP servers...');
      await mcpManager.disconnectAll();
      mcpManager.dispose();
      stdout.writeln(TerminalPrinter.green('Goodbye!'));
    }
  }
}
