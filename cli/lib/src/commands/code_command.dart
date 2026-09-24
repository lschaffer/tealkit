import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dart_mcp_core/dart_mcp_core.dart';
import 'package:path/path.dart' as p;

import '../config/permission_settings.dart';
import '../engine/skill_runner.dart';
import '../formatters/terminal_printer.dart';

enum CodingMode {
  architect,
  code,
  ask,
}

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
      help: 'Initial agent mode (architect: planning/tasks.md, code: implementation, ask: Q&A)',
    );
    argParser.addOption(
      'instructions',
      abbr: 'i',
      help: 'Path to custom instructions markdown file (default looks for tealkit_agent.md or AGENTS.md)',
    );
    argParser.addOption(
      'llm',
      help: 'Path to custom llm.yaml configuration',
      defaultsTo: 'llm.yaml',
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
  /mode <architect|code|ask> Switch operational mode
  /plan                     Shortcut to switch to ARCHITECT mode
  /code                     Shortcut to switch to CODE mode
  /ask                      Shortcut to switch to ASK mode
  /permissions              View or toggle tool approval requirements (write/exec)
  /auto-approve <on|off>    Toggle auto-approval for all tools in session
  /tasks                    Display current tasks.md if present
  /instructions             Show or reload tealkit_agent.md / custom instructions
  /clear                    Clear conversation turn history
  /tools                    List active native coding tools
  /bye, /exit               Exit session
  /help, /?                 Show this help menu
''';

  @override
  Future<void> run() async {
    final modeStr = argResults?['mode'] as String? ?? 'code';
    final customInstructionsPath = argResults?['instructions'] as String?;
    final llmPath = argResults?['llm'] as String? ?? 'llm.yaml';
    final verbose = argResults?['verbose'] as bool? ?? false;

    CodingMode currentMode = switch (modeStr) {
      'architect' => CodingMode.architect,
      'ask' => CodingMode.ask,
      _ => CodingMode.code,
    };

    final runner = SkillRunner(
      llmConfigPath: llmPath,
      verbose: verbose,
    );

    final llmConfig = runner.loadLlmConfig();
    final workspaceDir = Directory.current.path;
    final permissions = ToolPermissionSettings.load();

    // Load workspace custom instructions (tealkit_agent.md, AGENTS.md, or specified)
    String userInstructions = _loadWorkspaceInstructions(customInstructionsPath);

    // Initialize Native Coding Tools via shared dart_mcp_core
    final dartTools = CodingTools.createAll(workingDirectory: workspaceDir);

    final toolNames = dartTools.map((t) => t.name).toList();
    final half = (toolNames.length / 2).ceil();
    final toolsLine1 = toolNames.take(half).join(', ');
    final toolsLine2 = toolNames.skip(half).join(', ');

    TerminalPrinter.printBanner('TealKit Coding Agent (v1.1.0)', [
      'Workspace    : $workspaceDir',
      'LLM Provider : ${llmConfig.provider.displayName} (${llmConfig.model})',
      'Active Mode  : ${currentMode.displayName}',
      'Permissions  : Write=${permissions.autoApproveWrite ? "Auto" : "Ask"}, Exec=${permissions.autoApproveExecute ? "Auto" : "Ask"}',
      'Instructions : ${userInstructions.isNotEmpty ? "Loaded from workspace" : "(None found, default active)"}',
      'Tools (${toolNames.length})   : $toolsLine1,',
      '               $toolsLine2',
    ]);

    stdout.writeln(
      TerminalPrinter.dim(
        'Type your request, switch modes with /plan or /code, or type /help for commands.',
      ),
    );
    stdout.writeln('');

    final history = <ChatMessage>[];

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
        stdout.writeln(TerminalPrinter.green('Switched to ${currentMode.displayName}'));
        stdout.writeln('');
        continue;
      }

      if (input == '/code') {
        currentMode = CodingMode.code;
        stdout.writeln(TerminalPrinter.green('Switched to ${currentMode.displayName}'));
        stdout.writeln('');
        continue;
      }

      if (input == '/ask') {
        currentMode = CodingMode.ask;
        stdout.writeln(TerminalPrinter.green('Switched to ${currentMode.displayName}'));
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
          stdout.writeln(TerminalPrinter.green('Switched to ${currentMode.displayName}'));
        } else {
          stdout.writeln('Current mode: ${currentMode.displayName}');
          stdout.writeln('Usage: /mode <architect|code|ask>');
        }
        stdout.writeln('');
        continue;
      }

      if (input.startsWith('/auto-approve')) {
        final parts = input.split(RegExp(r'\s+'));
        if (parts.length > 1 && parts[1].toLowerCase() == 'on') {
          permissions.autoApproveWrite = true;
          permissions.autoApproveExecute = true;
          permissions.save();
          stdout.writeln(TerminalPrinter.green('Auto-approval ENABLED for write & exec tools.'));
        } else if (parts.length > 1 && parts[1].toLowerCase() == 'off') {
          permissions.autoApproveWrite = false;
          permissions.autoApproveExecute = false;
          permissions.save();
          stdout.writeln(TerminalPrinter.yellow('Auto-approval DISABLED (will prompt on write & exec).'));
        } else {
          stdout.writeln('Usage: /auto-approve <on|off>');
        }
        stdout.writeln('');
        continue;
      }

      if (input == '/permissions') {
        stdout.writeln(TerminalPrinter.bold('--- Tool Permissions Configuration ---'));
        stdout.writeln('  Read operations   (fs_read_file, fs_find)   : ${permissions.autoApproveRead ? "Auto-Approved" : "Requires Confirmation"}');
        stdout.writeln('  Write operations  (fs_write, fs_replace)    : ${permissions.autoApproveWrite ? "Auto-Approved" : "Requires Confirmation"}');
        stdout.writeln('  Execute commands  (terminal_exec)           : ${permissions.autoApproveExecute ? "Auto-Approved" : "Requires Confirmation"}');
        stdout.writeln('  Network actions   (remote MCP)              : ${permissions.autoApproveNetwork ? "Auto-Approved" : "Requires Confirmation"}');
        stdout.writeln(TerminalPrinter.dim('Tip: Use "/auto-approve on" or edit ~/.tealkit/permissions.yaml'));
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

      if (input == '/clear') {
        history.clear();
        stdout.writeln(TerminalPrinter.dim('Conversation history cleared.'));
        stdout.writeln('');
        continue;
      }

      if (input == '/tools') {
        stdout.writeln(TerminalPrinter.bold('Active Coding Tools:'));
        for (final t in dartTools) {
          stdout.writeln('  • ${TerminalPrinter.cyan(t.name)} — ${t.description}');
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

      final agent = Agent(
        key: 'code_agent',
        name: 'Coding Assistant',
        llmConfig: llmConfig,
        systemPrompt: systemPrompt,
        prompts: [SubPromptStep(text: input)],
        dartTools: dartTools,
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
          await engine.run(
            agent.key,
            onToolApproval: ({
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
              stdout.writeln(TerminalPrinter.yellow('⚠️  Tool Approval Requested:'));
              stdout.writeln('  • Tool   : ${TerminalPrinter.cyan(toolName)} ($riskLevel)');
              stdout.writeln('  • Args   : ${jsonEncode(parameters)}');
              stdout.write(TerminalPrinter.bold('Approve execution? [y/n/always/deny-all] > '));

              final response = stdin.readLineSync()?.trim().toLowerCase();
              if (response == 'a' || response == 'always') {
                if (riskLevel == ToolRiskLevel.write) {
                  permissions.autoApproveWrite = true;
                } else if (riskLevel == ToolRiskLevel.execute) {
                  permissions.autoApproveExecute = true;
                }
                permissions.save();
                stdout.writeln(TerminalPrinter.green('Approved and saved to preferences.'));
                return true;
              } else if (response == 'd' || response == 'deny-all') {
                permissions.autoApproveWrite = false;
                permissions.autoApproveExecute = false;
                permissions.save();
                stdout.writeln(TerminalPrinter.red('Denied and disabled auto-approval.'));
                return false;
              }

              final approved = response == 'y' || response == 'yes' || response == '';
              if (!approved) {
                stdout.writeln(TerminalPrinter.red('Tool execution rejected by user.'));
              }
              return approved;
            },
          );
          turnSuccess = true;
        } catch (e) {
          if (verbose) {
            stderr.writeln(TerminalPrinter.dim('[execution error] $e'));
          }
        } finally {
          await Future.delayed(const Duration(milliseconds: 50));
          await subscription.cancel();
        }
      } finally {
        await engine.dispose();
      }

      if (turnSuccess) {
        history.add(
          ChatMessage(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            content: input,
            role: ChatRole.user,
            timestamp: DateTime.now(),
          ),
        );
      }
    }

    stdout.writeln(TerminalPrinter.green('Exiting coding agent session. Goodbye!'));
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
