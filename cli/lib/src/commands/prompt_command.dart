import 'dart:io';

import 'package:args/command_runner.dart';

import '../engine/skill_runner.dart';
import '../formatters/terminal_printer.dart';

/// Top-level command for ad-hoc prompt execution.
class PromptCommand extends Command {
  @override
  final String name = 'prompt';
  @override
  final String description = 'Execute an ad-hoc prompt with local LLM and MCP tool access.';

  PromptCommand() {
    addSubcommand(PromptRunCommand());
  }
}

/// `tealkit prompt run "<prompt>"`
class PromptRunCommand extends Command {
  @override
  final String name = 'run';
  @override
  final String description = 'Run a prompt through the LLM and connected MCP tools.';

  PromptRunCommand() {
    argParser.addOption('system', abbr: 's', help: 'Custom system prompt instructions');
    argParser.addOption('llm', help: 'Path to custom llm.yaml configuration', defaultsTo: 'llm.yaml');
    argParser.addOption('tools', help: 'Path to custom extern_mcp_tools.yaml', defaultsTo: 'extern_mcp_tools.yaml');
    argParser.addFlag('verbose', abbr: 'v', negatable: false, help: 'Print verbose logs and debug information');
  }

  @override
  Future<void> run() async {
    String promptText = '';

    if (argResults?.rest.isNotEmpty ?? false) {
      promptText = argResults!.rest.join(' ').trim();
    } else if (!stdin.hasTerminal) {
      // Read piped stdin if terminal is redirected
      promptText = await stdin.transform(systemEncoding.decoder).join();
      promptText = promptText.trim();
    }

    if (promptText.isEmpty) {
      stderr.writeln('Error: Please provide prompt text or pipe via stdin.');
      stderr.writeln('Usage: tealkit prompt run "Your query here"');
      stderr.writeln('   or: cat data.txt | tealkit prompt run');
      return;
    }

    final system = argResults?['system'] as String?;
    final llmPath = argResults?['llm'] as String? ?? 'llm.yaml';
    final toolsPath = argResults?['tools'] as String? ?? 'extern_mcp_tools.yaml';
    final verbose = argResults?['verbose'] as bool? ?? false;

    final runner = SkillRunner(
      llmConfigPath: llmPath,
      toolsConfigPath: toolsPath,
      verbose: verbose,
    );

    stdout.writeln(TerminalPrinter.cyan('▶ Executing Prompt: "$promptText"'));
    stdout.writeln('');

    try {
      await runner.runPrompt(
        promptText: promptText,
        customSystemPrompt: system,
      );
    } catch (e) {
      stderr.writeln(TerminalPrinter.red('Error running prompt: $e'));
    }
  }
}
