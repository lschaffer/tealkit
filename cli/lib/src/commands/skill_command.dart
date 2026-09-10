import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:tealkit_api/tealkit_api.dart';

import '../config/server_config.dart';
import '../engine/skill_runner.dart';
import '../formatters/terminal_printer.dart';

/// Top-level command for AgentSkills management and execution.
class SkillCommand extends Command {
  @override
  final String name = 'skill';
  @override
  final String description = 'Inspect and directly execute AgentSkills (SKILL.md) workflows.';

  SkillCommand() {
    addSubcommand(SkillListCommand());
    addSubcommand(SkillInfoCommand());
    addSubcommand(SkillRunCommand());
  }
}

/// `tealkit skill list [--remote]`
class SkillListCommand extends Command {
  @override
  final String name = 'list';
  @override
  final String description = 'List skills in local ./skills directory or on remote server.';

  SkillListCommand() {
    argParser.addFlag('remote', abbr: 'r', negatable: false, help: 'Fetch skills from active server');
  }

  @override
  Future<void> run() async {
    final isRemote = argResults?['remote'] as bool? ?? false;

    if (isRemote) {
      final manager = ServerConfigManager();
      final profile = manager.getActiveProfile();
      if (profile == null) {
        stderr.writeln(TerminalPrinter.red('Error: No active server profile found in server.yaml.'));
        return;
      }
      final client = ServerApiClient(
        serverUrl: profile.url,
        apiKey: profile.apiKey.isNotEmpty ? profile.apiKey : null,
      );

      stdout.writeln('Fetching skills from server ${profile.name}...');
      final skills = await client.getAllSkillDefs();

      if (skills.isEmpty) {
        stdout.writeln('No skills found on remote server.');
        return;
      }

      stdout.writeln(TerminalPrinter.bold('Remote Server Skills (${skills.length}):'));
      stdout.writeln('');

      final headers = ['ID', 'Name', 'Description', 'Tools'];
      final rows = <List<String>>[];
      for (final s in skills) {
        final tools = (s['tool_names'] as List?)?.join(', ') ?? '';
        rows.add([
          s['id'] ?? '',
          s['name'] ?? '',
          s['description'] ?? '',
          tools,
        ]);
      }
      TerminalPrinter.printTable(headers: headers, rows: rows);
      return;
    }

    // Local skills in ./skills or current dir
    final searchDirs = [Directory('skills'), Directory('example_skills'), Directory('.')];
    final skillFiles = <File>[];

    for (final d in searchDirs) {
      if (d.existsSync()) {
        final entities = d.listSync(recursive: false);
        for (final e in entities) {
          if (e is File && (e.path.endsWith('.md') || e.path.endsWith('skill.md'))) {
            if (e.path.toLowerCase().contains('skill') || d.path == 'skills' || d.path == 'example_skills') {
              skillFiles.add(e);
            }
          }
        }
      }
    }

    if (skillFiles.isEmpty) {
      stdout.writeln('No local skill (.md) files found in ./skills/ or current directory.');
      stdout.writeln('Tip: Use `tealkit auto-discover skills` to download skills from your server.');
      return;
    }

    stdout.writeln(TerminalPrinter.bold('Local AgentSkills (${skillFiles.length}):'));
    stdout.writeln('');

    final headers = ['File Path', 'Skill Name', 'Version', 'Steps', 'Tools'];
    final rows = <List<String>>[];
    final runner = SkillRunner();

    for (final file in skillFiles) {
      try {
        final manifest = runner.parseSkillFile(file.path);
        rows.add([
          file.path,
          manifest.name,
          manifest.version,
          manifest.promptSteps.length.toString(),
          manifest.tools.map((t) => t.name).join(', '),
        ]);
      } catch (_) {
        rows.add([file.path, '(invalid frontmatter)', '-', '-', '-']);
      }
    }

    TerminalPrinter.printTable(headers: headers, rows: rows);
  }
}

/// `tealkit skill info <path-to-skill.md>`
class SkillInfoCommand extends Command {
  @override
  final String name = 'info';
  @override
  final String description = 'Inspect an AgentSkill manifest, prompt steps, and tool requirements.';

  @override
  void run() {
    if (argResults?.rest.isEmpty ?? true) {
      stderr.writeln('Error: Please provide path to a skill file (e.g. skills/my_skill.md).');
      stderr.writeln('Usage: tealkit skill info <path-to-skill.md>');
      return;
    }

    final path = argResults!.rest.first;
    final runner = SkillRunner();

    try {
      final manifest = runner.parseSkillFile(path);
      TerminalPrinter.printBanner(
        'Skill: ${manifest.name}',
        [
          'Version     : ${manifest.version}',
          'Author      : ${manifest.author ?? "N/A"}',
          'Description : ${manifest.description}',
          'Multi-turn  : ${manifest.isMultiTurn}',
        ],
      );

      stdout.writeln(TerminalPrinter.bold('── System Prompt ──'));
      stdout.writeln(manifest.systemPrompt.trim().isEmpty ? '(none)' : manifest.systemPrompt.trim());
      stdout.writeln('');

      stdout.writeln(TerminalPrinter.bold('── Prompt Sequence (${manifest.promptSteps.length} steps) ──'));
      for (int i = 0; i < manifest.promptSteps.length; i++) {
        final step = manifest.promptSteps[i];
        stdout.writeln(' [Step ${i + 1}] ${step.text}');
        if (step.enabledToolNames != null) {
          stdout.writeln(TerminalPrinter.dim('   Enabled tools: ${step.enabledToolNames!.join(", ")}'));
        }
      }
      stdout.writeln('');

      if (manifest.tools.isNotEmpty) {
        stdout.writeln(TerminalPrinter.bold('── Required Tools (${manifest.tools.length}) ──'));
        for (final t in manifest.tools) {
          stdout.writeln(' • ${t.name} (Tier: ${t.tier}) — ${t.description ?? ""}');
        }
        stdout.writeln('');
      }
    } catch (e) {
      stderr.writeln(TerminalPrinter.red('Error reading skill: $e'));
    }
  }
}

/// `tealkit skill run <path-to-skill.md>`
class SkillRunCommand extends Command {
  @override
  final String name = 'run';
  @override
  final String description = 'Directly execute prompt steps from an AgentSkill file with MCP tools.';

  SkillRunCommand() {
    argParser.addOption('step', abbr: 's', help: 'Run only a specific 1-based prompt step index');
    argParser.addMultiOption('param', abbr: 'p', help: 'Interpolate variable in prompt (e.g. -p city=Berlin)');
    argParser.addFlag('dry-run', negatable: false, help: 'Inspect resolved steps and tools without calling LLM');
    argParser.addOption('llm', help: 'Path to custom llm.yaml configuration', defaultsTo: 'llm.yaml');
    argParser.addOption('tools', help: 'Path to custom extern_mcp_tools.yaml / mcp.yaml', defaultsTo: 'extern_mcp_tools.yaml');
    argParser.addFlag('verbose', abbr: 'v', negatable: false, help: 'Print verbose logs and debug information');
  }

  @override
  Future<void> run() async {
    if (argResults?.rest.isEmpty ?? true) {
      stderr.writeln('Error: Please provide path to a skill file (e.g. skills/weather_audit.md).');
      stderr.writeln('Usage: tealkit skill run <path-to-skill.md> [--step 1] [--param key=val] [--dry-run]');
      return;
    }

    final skillPath = argResults!.rest.first;
    final stepStr = argResults?['step'] as String?;
    final stepIndex = stepStr != null ? int.tryParse(stepStr) : null;
    final dryRun = argResults?['dry-run'] as bool? ?? false;
    final verbose = argResults?['verbose'] as bool? ?? false;
    final llmPath = argResults?['llm'] as String? ?? 'llm.yaml';
    final toolsPath = argResults?['tools'] as String? ?? 'extern_mcp_tools.yaml';

    // Parse parameters
    final rawParams = argResults?['param'] as List<String>? ?? [];
    final paramMap = <String, String>{};
    for (final p in rawParams) {
      final eq = p.indexOf('=');
      if (eq != -1) {
        paramMap[p.substring(0, eq).trim()] = p.substring(eq + 1).trim();
      }
    }

    final runner = SkillRunner(
      llmConfigPath: llmPath,
      toolsConfigPath: toolsPath,
      verbose: verbose,
    );

    try {
      await runner.runSkill(
        skillPath: skillPath,
        stepIndex: stepIndex,
        parameters: paramMap,
        dryRun: dryRun,
      );
    } catch (e) {
      stderr.writeln(TerminalPrinter.red('Error executing skill: $e'));
    }
  }
}
