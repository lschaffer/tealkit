import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dart_mcp_core/dart_mcp_core.dart';

import '../engine/skill_runner.dart';
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
      help: 'Path to custom llm.yaml configuration',
      defaultsTo: 'llm.yaml',
    );
    argParser.addOption(
      'tools',
      help: 'Path to custom extern_mcp_tools.yaml',
      defaultsTo: 'extern_mcp_tools.yaml',
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
  /bye, /exit   Quit interactive chat
  /tools        List available MCP tools
  /clear        Clear conversation history
  /system       Display current system prompt
  /help, /?     Show this help
''';

  @override
  Future<void> run() async {
    final skillPath = argResults?['skill'] as String?;
    final llmPath = argResults?['llm'] as String? ?? 'llm.yaml';
    final toolsPath =
        argResults?['tools'] as String? ?? 'extern_mcp_tools.yaml';
    final verbose = argResults?['verbose'] as bool? ?? false;

    final runner = SkillRunner(
      llmConfigPath: llmPath,
      toolsConfigPath: toolsPath,
      verbose: verbose,
    );

    final llmConfig = runner.loadLlmConfig();
    final localServers = runner.loadMcpServers();

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

    TerminalPrinter.printBanner(sessionTitle, [
      'LLM Model   : ${llmConfig.provider.displayName} / ${llmConfig.model}',
      'MCP Servers : ${localServers.length} configured',
      'Commands    : Type /help for slash commands, /exit to quit',
    ]);

    final mcpManager = await runner.connectMcpServers(localServers);

    stdout.writeln('');
    stdout.writeln('Enter your message (type /exit to quit):');
    stdout.writeln('');

    final conversation = <ChatMessage>[];

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
        if (input == '/clear') {
          conversation.clear();
          stdout.writeln(TerminalPrinter.dim('Conversation history cleared.'));
          stdout.writeln('');
          continue;
        }
        if (input == '/system') {
          stdout.writeln(TerminalPrinter.bold('System prompt:'));
          stdout.writeln(systemPrompt);
          stdout.writeln('');
          continue;
        }

        final agent = Agent(
          key: 'chat_agent',
          name: 'Chat Agent',
          llmConfig: llmConfig,
          systemPrompt: systemPrompt,
          prompts: [SubPromptStep(text: input)],
          localServers: [],
        );

        final engine = McpAgentEngine();
        engine.setAgents([agent]);

        bool turnSuccess = false;
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
                stdout.writeln('');
                stdout.writeln(response.trim());
                stdout.writeln('');
              case AgentErrorEvent(:final error):
                stderr.writeln(TerminalPrinter.red('ERROR: $error'));
              case AgentFinalResultEvent():
              case AgentTextChunkEvent():
                break;
            }
          });

          try {
            await engine.run(agent.key, mcpManager: mcpManager);
            turnSuccess = true;
          } catch (e) {
            // Error was already printed via AgentErrorEvent or uncaught
            if (verbose) {
              stderr.writeln(TerminalPrinter.dim('[turn error] $e'));
            }
          } finally {
            await Future.delayed(const Duration(milliseconds: 50));
            await subscription.cancel();
          }
        } finally {
          await engine.dispose();
        }

        if (turnSuccess) {
          conversation.add(
            ChatMessage(
              id: DateTime.now().millisecondsSinceEpoch.toString(),
              content: input,
              role: ChatRole.user,
              timestamp: DateTime.now(),
            ),
          );
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
