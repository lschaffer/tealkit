import 'dart:io';

import 'package:args/command_runner.dart';

import '../engine/rpc_engine.dart';
import 'code_command.dart';

/// `tealkit rpc [--workspace <dir>] [--mode <mode>] [--llm <llm>]`
class RpcCommand extends Command {
  @override
  final String name = 'rpc';
  @override
  final String description =
      'Launch headless JSON-RPC engine over stdio for IDE extensions (VS Code / Antigravity).';

  RpcCommand() {
    argParser.addOption(
      'workspace',
      abbr: 'w',
      help: 'Target workspace root directory (defaults to current directory)',
    );
    argParser.addOption(
      'mode',
      abbr: 'm',
      allowed: ['architect', 'code', 'ask', 'rag'],
      defaultsTo: 'code',
      help: 'Initial agent mode (architect, code, ask, rag)',
    );
    argParser.addOption(
      'llm',
      help: 'Path to custom llm.yaml configuration or model profile name',
      defaultsTo: 'llm.yaml',
    );
    argParser.addOption(
      'llm-name',
      help: 'Select named LLM model profile from llm.yaml',
    );
    argParser.addOption(
      'tools',
      help: 'Path to custom extern_mcp_tools.yaml / mcp.yaml',
      defaultsTo: 'extern_mcp_tools.yaml',
    );
    argParser.addOption(
      'instructions',
      abbr: 'i',
      help: 'Path to custom instructions markdown file',
    );
    argParser.addOption(
      'save-session',
      help: 'File path (.json or .md) to auto-save session transcript',
    );
    argParser.addOption(
      'load-session',
      help: 'File path (.json or .md) to load and continue a previous session',
    );
    argParser.addFlag(
      'continue',
      abbr: 'c',
      negatable: false,
      help: 'Continue the most recent saved session from .tealkit/sessions/',
    );
    argParser.addFlag(
      'auto-save-session',
      defaultsTo: true,
      help: 'Automatically save conversation session after each turn',
    );
  }

  @override
  Future<void> run() async {
    final workspaceDir =
        argResults?['workspace'] as String? ?? Directory.current.path;
    final modeStr = argResults?['mode'] as String? ?? 'code';
    final llmPath = argResults?['llm'] as String? ?? 'llm.yaml';
    final explicitLlmName = argResults?['llm-name'] as String?;
    final toolsPath =
        argResults?['tools'] as String? ?? 'extern_mcp_tools.yaml';
    final customInstructionsPath = argResults?['instructions'] as String?;
    final saveSessionPath = argResults?['save-session'] as String?;
    final loadSessionPath = argResults?['load-session'] as String?;
    final continueSession = argResults?['continue'] as bool? ?? false;
    final autoSaveSession = argResults?['auto-save-session'] as bool? ?? true;

    final currentMode = switch (modeStr) {
      'architect' => CodingMode.architect,
      'ask' => CodingMode.ask,
      'rag' => CodingMode.rag,
      _ => CodingMode.code,
    };

    final engine = TealKitRpcEngine(
      workspaceDir: workspaceDir,
      customInstructionsPath: customInstructionsPath,
      llmPath: llmPath,
      initialLlmName: explicitLlmName,
      toolsPath: toolsPath,
      currentMode: currentMode,
      saveSessionPath: saveSessionPath,
      loadSessionPath: loadSessionPath,
      continueSession: continueSession,
      autoSaveSession: autoSaveSession,
    );

    await engine.run();
  }
}

