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
      allowed: ['architect', 'code', 'ask'],
      defaultsTo: 'code',
      help: 'Initial agent mode (architect, code, ask)',
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

    final currentMode = switch (modeStr) {
      'architect' => CodingMode.architect,
      'ask' => CodingMode.ask,
      _ => CodingMode.code,
    };

    final engine = TealKitRpcEngine(
      workspaceDir: workspaceDir,
      customInstructionsPath: customInstructionsPath,
      llmPath: llmPath,
      initialLlmName: explicitLlmName,
      toolsPath: toolsPath,
      currentMode: currentMode,
    );

    await engine.run();
  }
}

