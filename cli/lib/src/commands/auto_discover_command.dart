import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:tealkit_api/tealkit_api.dart';

import '../config/env_loader.dart';
import '../config/server_config.dart';
import '../formatters/terminal_printer.dart';

/// Top-level command for auto-discovering configurations from TealKit server.
class AutoDiscoverCommand extends Command {
  @override
  final String name = 'auto-discover';
  @override
  final String description =
      'Auto-discover configurations, tasks, and skills from active server.';

  AutoDiscoverCommand() {
    addSubcommand(AutoDiscoverLlmCommand());
    addSubcommand(AutoDiscoverWorkflowsCommand());
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
  final String description =
      'Download server LLM settings and save to llm.yaml.';

  @override
  Future<void> run() async {
    stdout.writeln('Discovering LLM settings from active server...');
    final client = _getClient();
    final settings = await client.getLlmSettings();

    final rawKey = (settings['api_key'] as String?)?.trim() ?? '';
    final providerName = (settings['provider'] ?? 'openai').toString().toLowerCase();
    final envVarName = '${providerName.toUpperCase()}_API_KEY';

    // If server provides an actual API key, persist it into .env so the user has it ready
    if (rawKey.isNotEmpty) {
      final envFile = File('.env');
      final lines = envFile.existsSync() ? envFile.readAsLinesSync() : <String>[];
      final newLines = <String>[];
      bool keyFound = false;

      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.startsWith('$envVarName=')) {
          newLines.add('$envVarName=$rawKey');
          keyFound = true;
        } else {
          newLines.add(line);
        }
      }
      if (!keyFound) {
        newLines.add('$envVarName=$rawKey');
      }
      envFile.writeAsStringSync('${newLines.join('\n')}\n');
      EnvLoader.clearCache();
    }

    final buffer = StringBuffer();
    buffer.writeln('# TealKit LLM Configuration (Auto-discovered)');
    buffer.writeln('provider: "$providerName"');
    buffer.writeln('model: "${settings['model'] ?? 'gpt-4o-mini'}"');
    buffer.writeln('api_key: "\${$envVarName}"');
    buffer.writeln('base_url: "${settings['base_url'] ?? ''}"');
    buffer.writeln('temperature: ${settings['temperature'] ?? 0.2}');
    buffer.writeln('max_tokens: ${settings['max_tokens'] ?? 4096}');

    const outputFile = 'llm.yaml';
    File(outputFile).writeAsStringSync(buffer.toString());
    stdout.writeln(
      TerminalPrinter.green('✔ Saved LLM settings to $outputFile'),
    );
    if (rawKey.isNotEmpty) {
      stdout.writeln(
        TerminalPrinter.green('✔ Synchronized $envVarName in .env'),
      );
    }
  }
}

/// `tealkit auto-discover workflows` (aliases: `agents`, `tasks`)
class AutoDiscoverWorkflowsCommand extends Command {
  @override
  final String name = 'workflows';
  @override
  final List<String> aliases = ['agents', 'tasks'];
  @override
  final String description =
      'Download remote workflows/agents and save to workflows.yaml.';

  @override
  Future<void> run() async {
    stdout.writeln('Discovering workflows and agents from active server...');
    final client = _getClient();
    final tasks = await client.getAllTasks();

    final buffer = StringBuffer();
    buffer.writeln(
      '# TealKit Workflows & Agents Configuration (Auto-discovered)',
    );
    buffer.writeln('workflows:');

    for (final task in tasks) {
      buffer.writeln('  - id: "${task.id}"');
      buffer.writeln('    name: "${task.name}"');
      buffer.writeln('    description: "${task.description ?? ''}"');
      buffer.writeln('    enabled: ${task.enabled}');
      buffer.writeln('    agents_count: ${task.agents.length}');
      buffer.writeln(
        '    internal_mcps: [${task.internalMcps.map((m) => '"${m.mcpType}"').join(', ')}]',
      );
    }

    const outputFile = 'workflows.yaml';
    File(outputFile).writeAsStringSync(buffer.toString());
    // Also save agents.yaml for backwards compatibility
    File('agents.yaml').writeAsStringSync(buffer.toString());
    stdout.writeln(
      TerminalPrinter.green(
        '✔ Saved ${tasks.length} workflow(s) to $outputFile',
      ),
    );
  }
}

typedef AutoDiscoverAgentsCommand = AutoDiscoverWorkflowsCommand;

/// `tealkit auto-discover mcp`
class AutoDiscoverMcpCommand extends Command {
  @override
  final String name = 'mcp';
  @override
  final String description =
      'Download MCP server registry and save to mcp.yaml.';

  @override
  Future<void> run() async {
    stdout.writeln('Discovering MCP servers from active server...');
    final client = _getClient();

    List<Map<String, dynamic>> localServers = [];
    try {
      localServers = await client.listRegistryServers();
    } catch (e) {
      stdout.writeln(
        TerminalPrinter.dim(
          '  (Notice: Could not fetch local registry servers: $e)',
        ),
      );
    }

    List<dynamic> remoteServers = [];
    try {
      final ext = await client.getExternalToolsSettings();
      remoteServers = (ext['selected_servers'] as List? ?? []);
    } catch (e) {
      stdout.writeln(
        TerminalPrinter.dim(
          '  (Notice: Could not fetch external/remote tools: $e)',
        ),
      );
    }

    final buffer = StringBuffer();
    buffer.writeln('# TealKit MCP Servers Configuration (Auto-discovered)');
    buffer.writeln('servers:');

    if (localServers.isNotEmpty) {
      buffer.writeln('  # ── Local / Community Stdio MCP Servers ──');
    }

    for (final s in localServers) {
      final id = (s['id'] as String?) ?? 'mcp_server';
      final name = (s['name'] as String?) ?? id;
      final language =
          (s['language'] as String?)?.toLowerCase() ??
          (s['local_type'] as String?)?.toLowerCase() ??
          'nodejs';
      final installType =
          (s['installType'] as String?)?.toLowerCase() ??
          (s['install_type'] as String?)?.toLowerCase() ??
          (language == 'python' ? 'uvx' : 'npx');

      var packageName =
          (s['packageName'] as String?) ??
          (s['package_name'] as String?) ??
          (s['local_package'] as String?) ??
          '';

      // Fallback for known community MCP servers if packageName is empty
      if (packageName.trim().isEmpty) {
        if (name.contains('filesystem')) {
          packageName = '@modelcontextprotocol/server-filesystem';
        } else if (name.contains('github')) {
          packageName = '@modelcontextprotocol/server-github';
        } else if (name.contains('fetch')) {
          packageName = 'mcp-server-fetch';
        } else if (name.contains('puppeteer')) {
          packageName = '@modelcontextprotocol/server-puppeteer';
        } else if (name.contains('memory')) {
          packageName = '@modelcontextprotocol/server-memory';
        } else {
          packageName = name;
        }
      }

      final enabled =
          (s['isActive'] as bool?) ??
          (s['is_active'] as bool?) ??
          (s['enabled'] as bool?) ??
          true;

      final rawArgs = (s['launchArgs'] as List?) ?? (s['launch_args'] as List?);
      final launchArgs = rawArgs?.map((a) => a.toString()).toList() ?? [];

      final rawEnv =
          (s['envVars'] as Map?) ??
          (s['env_vars'] as Map?) ??
          (s['env'] as Map?);
      final envVars =
          rawEnv?.map((k, v) => MapEntry(k.toString(), v.toString())) ?? {};

      String localInstallMethod = installType;
      if (localInstallMethod == 'npm') localInstallMethod = 'npx';
      if (localInstallMethod == 'python') localInstallMethod = 'uvx';

      String? customLaunchCommand;
      String effectiveArgs = '';
      if (launchArgs.isNotEmpty) {
        effectiveArgs =
            ' ${launchArgs.map((a) {
              if (a.contains('{{allowed_dirs}}')) {
                return a.replaceAll('{{allowed_dirs}}', '.');
              }
              return a;
            }).join(' ')}';
      } else if (packageName.contains('server-filesystem')) {
        effectiveArgs = ' .';
      }

      if (localInstallMethod == 'npx') {
        final npxCmd = Platform.isWindows ? 'npx.cmd' : 'npx';
        customLaunchCommand = '$npxCmd -y $packageName$effectiveArgs';
      } else if (localInstallMethod == 'uvx') {
        customLaunchCommand = 'uvx $packageName$effectiveArgs';
      }

      buffer.writeln('  - id: "$id"');
      buffer.writeln('    name: "$name"');
      buffer.writeln('    is_local: true');
      buffer.writeln('    local_type: "$language"');
      buffer.writeln('    local_install_method: "$localInstallMethod"');
      buffer.writeln('    local_package: "$packageName"');
      if (customLaunchCommand != null) {
        buffer.writeln('    custom_launch_command: "$customLaunchCommand"');
      }
      if (launchArgs.isNotEmpty) {
        buffer.writeln(
          '    launch_args: [${launchArgs.map((a) => '"$a"').join(', ')}]',
        );
      }
      if (envVars.isNotEmpty) {
        buffer.writeln('    env:');
        for (final entry in envVars.entries) {
          buffer.writeln('      ${entry.key}: "${entry.value}"');
        }
      }
      buffer.writeln('    enabled: $enabled');
      buffer.writeln('');
    }

    if (remoteServers.isNotEmpty) {
      buffer.writeln('  # ── Remote HTTP / SSE MCP Servers ──');
      for (final s in remoteServers) {
        final map = s is Map<String, dynamic>
            ? s
            : (s is Map ? Map<String, dynamic>.from(s) : null);
        if (map == null) continue;
        final serverUrl =
            (map['server_url'] as String?) ??
            (map['serverUrl'] as String?) ??
            '';
        if (serverUrl.trim().isEmpty) continue;

        final name =
            (map['name'] as String?) ??
            (map['displayName'] as String?) ??
            'Remote MCP';
        final safeId =
            'remote_${name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '_')}';
        final mcpEndpoint =
            (map['mcp_endpoint'] as String?) ??
            (map['mcpEndpoint'] as String?) ??
            '/mcp';
        final apiKey =
            (map['api_key'] as String?) ?? (map['apiKey'] as String?) ?? '';
        final desc = (map['description'] as String?) ?? '';

        buffer.writeln('  - id: "$safeId"');
        buffer.writeln('    name: "$name"');
        if (desc.isNotEmpty) {
          buffer.writeln('    description: "$desc"');
        }
        buffer.writeln('    url: "$serverUrl"');
        buffer.writeln('    mcp_endpoint: "$mcpEndpoint"');
        buffer.writeln('    is_local: false');
        if (apiKey.isNotEmpty) {
          buffer.writeln('    api_key: "$apiKey"');
        }
        buffer.writeln('    enabled: true');
        buffer.writeln('');
      }
    }

    const outputFile = 'mcp.yaml';
    File(outputFile).writeAsStringSync(buffer.toString());
    final total = localServers.length + remoteServers.length;
    stdout.writeln(
      TerminalPrinter.green(
        '✔ Saved $total MCP server(s) (${localServers.length} local stdio, ${remoteServers.length} remote HTTP) to $outputFile',
      ),
    );
  }
}

/// `tealkit auto-discover skills`
class AutoDiscoverSkillsCommand extends Command {
  @override
  final String name = 'skills';
  @override
  final String description =
      'Download AgentSkills from server into ./skills directory.';

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

      final safeName = name.toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9_\-]'),
        '_',
      );
      final fileName = 'skills/$safeName.md';
      File(fileName).writeAsStringSync(rawContent);
      savedCount++;
    }

    stdout.writeln(
      TerminalPrinter.green('✔ Saved $savedCount skill(s) into ./skills/'),
    );
  }
}

/// `tealkit auto-discover all`
class AutoDiscoverAllCommand extends Command {
  @override
  final String name = 'all';
  @override
  final String description =
      'Auto-discover LLM, agents, MCP tools, and skills in sequence.';

  @override
  Future<void> run() async {
    stdout.writeln(
      TerminalPrinter.bold('Running full configuration auto-discovery...'),
    );
    stdout.writeln('');

    try {
      await AutoDiscoverLlmCommand().run();
      await AutoDiscoverAgentsCommand().run();
      await AutoDiscoverMcpCommand().run();
      await AutoDiscoverSkillsCommand().run();
      stdout.writeln('');
      stdout.writeln(
        TerminalPrinter.green('✔ Full auto-discovery completed successfully!'),
      );
    } catch (e) {
      stderr.writeln(TerminalPrinter.red('Error during auto-discovery: $e'));
    }
  }
}
