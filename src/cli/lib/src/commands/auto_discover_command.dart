import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:tealkit_api/tealkit_api.dart';

import '../config/server_config.dart';
import '../formatters/terminal_printer.dart';

/// Top-level command for auto-discovering configurations from TealKit server.
class AutoDiscoverCommand extends Command {
  @override
  final String name = 'auto-discover';
  @override
  final String description = 'Auto-discover configurations, tasks, and skills from active server.';

  AutoDiscoverCommand() {
    addSubcommand(AutoDiscoverLlmCommand());
    addSubcommand(AutoDiscoverAgentsCommand());
    addSubcommand(AutoDiscoverMcpCommand());
    addSubcommand(AutoDiscoverSkillsCommand());
    addSubcommand(AutoDiscoverAllCommand());
  }
}

ServerApiClient _getClient() {
  final manager = ServerConfigManager();
  final profile = manager.getActiveProfile();
  if (profile == null) {
    throw StateError('No active server profile found in server.yaml.');
  }
  return ServerApiClient(
    serverUrl: profile.url,
    apiKey: profile.apiKey.isNotEmpty ? profile.apiKey : null,
  );
}

/// `tealkit auto-discover llm`
class AutoDiscoverLlmCommand extends Command {
  @override
  final String name = 'llm';
  @override
  final String description = 'Download server LLM settings and save to llm.yaml.';

  @override
  Future<void> run() async {
    stdout.writeln('Discovering LLM settings from active server...');
    final client = _getClient();
    final settings = await client.getLlmSettings();

    final buffer = StringBuffer();
    buffer.writeln('# TealKit LLM Configuration (Auto-discovered)');
    buffer.writeln('provider: "${settings['provider'] ?? 'openai'}"');
    buffer.writeln('model: "${settings['model'] ?? 'gpt-4o-mini'}"');
    buffer.writeln('api_key: "\${${(settings['provider'] ?? 'OPENAI').toString().toUpperCase()}_API_KEY}"');
    buffer.writeln('base_url: "${settings['base_url'] ?? ''}"');
    buffer.writeln('temperature: ${settings['temperature'] ?? 0.2}');
    buffer.writeln('max_tokens: ${settings['max_tokens'] ?? 4096}');

    const outputFile = 'llm.yaml';
    File(outputFile).writeAsStringSync(buffer.toString());
    stdout.writeln(TerminalPrinter.green('✔ Saved LLM settings to $outputFile'));
  }
}

/// `tealkit auto-discover agents`
class AutoDiscoverAgentsCommand extends Command {
  @override
  final String name = 'agents';
  @override
  final String description = 'Download remote tasks/agents and save to agents.yaml.';

  @override
  Future<void> run() async {
    stdout.writeln('Discovering agents and tasks from active server...');
    final client = _getClient();
    final tasks = await client.getAllTasks();

    final buffer = StringBuffer();
    buffer.writeln('# TealKit Tasks & Agents Configuration (Auto-discovered)');
    buffer.writeln('tasks:');

    for (final task in tasks) {
      buffer.writeln('  - id: "${task.id}"');
      buffer.writeln('    name: "${task.name}"');
      buffer.writeln('    description: "${task.description ?? ''}"');
      buffer.writeln('    enabled: ${task.enabled}');
      buffer.writeln('    agents_count: ${task.agents.length}');
      buffer.writeln('    internal_mcps: [${task.internalMcps.map((m) => '"${m.mcpType}"').join(', ')}]');
    }

    const outputFile = 'agents.yaml';
    File(outputFile).writeAsStringSync(buffer.toString());
    stdout.writeln(TerminalPrinter.green('✔ Saved ${tasks.length} task(s) to $outputFile'));
  }
}

/// `tealkit auto-discover mcp`
class AutoDiscoverMcpCommand extends Command {
  @override
  final String name = 'mcp';
  @override
  final String description = 'Download MCP server registry and save to mcp.yaml.';

  @override
  Future<void> run() async {
    stdout.writeln('Discovering MCP servers from active server...');
    final client = _getClient();
    final servers = await client.listRegistryServers();

    final buffer = StringBuffer();
    buffer.writeln('# TealKit MCP Servers Configuration (Auto-discovered)');
    buffer.writeln('servers:');

    for (final s in servers) {
      final id = s['id'] ?? 'mcp_server';
      final name = s['name'] ?? id;
      final isLocal = s['is_local'] ?? true;
      final localType = s['local_type'] ?? 'nodejs';
      final localPackage = s['local_package'] ?? '';
      final enabled = s['enabled'] ?? true;

      buffer.writeln('  - id: "$id"');
      buffer.writeln('    name: "$name"');
      buffer.writeln('    is_local: $isLocal');
      buffer.writeln('    local_type: "$localType"');
      buffer.writeln('    local_package: "$localPackage"');
      buffer.writeln('    enabled: $enabled');
    }

    const outputFile = 'mcp.yaml';
    File(outputFile).writeAsStringSync(buffer.toString());
    stdout.writeln(TerminalPrinter.green('✔ Saved ${servers.length} MCP server(s) to $outputFile'));
  }
}

/// `tealkit auto-discover skills`
class AutoDiscoverSkillsCommand extends Command {
  @override
  final String name = 'skills';
  @override
  final String description = 'Download AgentSkills from server into ./skills directory.';

  @override
  Future<void> run() async {
    stdout.writeln('Discovering skills from active server...');
    final client = _getClient();
    final skills = await client.getAllSkillDefs();

    final skillsDir = Directory('skills');
    if (!skillsDir.existsSync()) {
      skillsDir.createSync(recursive: true);
    }

    int savedCount = 0;
    for (final skill in skills) {
      final name = (skill['name'] as String?)?.trim() ?? 'unnamed';
      final rawContent = skill['skill_def'] as String? ?? '';
      if (rawContent.isEmpty) continue;

      final safeName = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_\-]'), '_');
      final fileName = 'skills/$safeName.md';
      File(fileName).writeAsStringSync(rawContent);
      savedCount++;
    }

    stdout.writeln(TerminalPrinter.green('✔ Saved $savedCount skill(s) into ./skills/'));
  }
}

/// `tealkit auto-discover all`
class AutoDiscoverAllCommand extends Command {
  @override
  final String name = 'all';
  @override
  final String description = 'Auto-discover LLM, agents, MCP tools, and skills in sequence.';

  @override
  Future<void> run() async {
    stdout.writeln(TerminalPrinter.bold('Running full configuration auto-discovery...'));
    stdout.writeln('');

    try {
      await AutoDiscoverLlmCommand().run();
      await AutoDiscoverAgentsCommand().run();
      await AutoDiscoverMcpCommand().run();
      await AutoDiscoverSkillsCommand().run();
      stdout.writeln('');
      stdout.writeln(TerminalPrinter.green('✔ Full auto-discovery completed successfully!'));
    } catch (e) {
      stderr.writeln(TerminalPrinter.red('Error during auto-discovery: $e'));
    }
  }
}
