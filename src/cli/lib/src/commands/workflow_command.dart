import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:tealkit_api/tealkit_api.dart';

import '../config/server_config.dart';
import '../formatters/terminal_printer.dart';

/// Top-level command for remote workflow (agent/task) management.
class WorkflowCommand extends Command {
  @override
  final String name = 'workflow';
  @override
  final String description = 'Manage and execute remote workflows, tasks, and agents on the server.';
  @override
  final List<String> aliases = ['agent', 'task', 'wf'];

  WorkflowCommand() {
    addSubcommand(WorkflowListCommand());
    addSubcommand(WorkflowRunCommand());
    addSubcommand(WorkflowStatusCommand());
    addSubcommand(WorkflowCancelCommand());
    addSubcommand(WorkflowLogsCommand());
    addSubcommand(WorkflowDownloadCommand());
  }
}

/// Backwards compatibility alias
typedef AgentCommand = WorkflowCommand;

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

class ResolvedWorkflow {
  final String id;
  final String name;

  ResolvedWorkflow({required this.id, required this.name});
}

/// Matches a workflow identifier (UUID, exact name, normalized name with spaces/underscores, or unique prefix) against a list of tasks.
ResolvedWorkflow? matchWorkflow(List<WorkflowTask> tasks, String identifier) {
  final trimmed = identifier.trim();
  if (trimmed.isEmpty) return null;

  final isUuid = RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(trimmed);

  // 1. Direct ID match (case-insensitive)
  for (final t in tasks) {
    if (t.id.toLowerCase() == trimmed.toLowerCase()) {
      return ResolvedWorkflow(id: t.id, name: t.name);
    }
  }

  // 2. Exact name match (case-insensitive)
  for (final t in tasks) {
    if (t.name.trim().toLowerCase() == trimmed.toLowerCase()) {
      return ResolvedWorkflow(id: t.id, name: t.name);
    }
  }

  // Helper to normalize strings (collapse multiple spaces, hyphens, and underscores)
  String normalize(String s) =>
      s.trim().replaceAll(RegExp(r'[_\-\s]+'), ' ').toLowerCase();

  final normalizedQuery = normalize(trimmed);

  // 3. Normalized name match (underscores <-> spaces)
  for (final t in tasks) {
    if (normalize(t.name) == normalizedQuery) {
      return ResolvedWorkflow(id: t.id, name: t.name);
    }
  }

  // 4. Prefix or substring matches
  final matches = tasks.where((t) {
    final normName = normalize(t.name);
    return normName.contains(normalizedQuery) ||
        t.id.toLowerCase().startsWith(trimmed.toLowerCase());
  }).toList();

  if (matches.length == 1) {
    final t = matches.first;
    return ResolvedWorkflow(id: t.id, name: t.name);
  }

  if (matches.length > 1) {
    stderr.writeln(TerminalPrinter.yellow('Multiple workflows matched "$identifier":'));
    for (final m in matches) {
      stderr.writeln('  - ${m.name} (${m.id})');
    }
    stderr.writeln('Please specify the full workflow name or UUID.');
    return null;
  }

  // If no match found in task list, but input is a valid UUID, allow direct attempt
  if (isUuid) {
    return ResolvedWorkflow(id: trimmed, name: trimmed);
  }

  return null;
}

/// Helper to resolve a workflow ID by either UUID or name (supports spaces, underscores, case-insensitivity).
Future<ResolvedWorkflow?> _resolveWorkflow(ServerApiClient client, String identifier) async {
  final trimmed = identifier.trim();
  if (trimmed.isEmpty) return null;

  final isUuid = RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(trimmed);

  List<WorkflowTask> tasks = [];
  try {
    tasks = await client.getAllTasks();
  } catch (e) {
    if (isUuid) {
      return ResolvedWorkflow(id: trimmed, name: trimmed);
    }
    rethrow;
  }

  final resolved = matchWorkflow(tasks, identifier);
  if (resolved != null) return resolved;

  stderr.writeln(TerminalPrinter.red('Error: Workflow "$identifier" not found on server.'));
  stderr.writeln('Run "tealkit workflow list" to view available workflows.');
  return null;
}

/// `tealkit workflow list`
class WorkflowListCommand extends Command {
  @override
  final String name = 'list';
  @override
  final String description = 'List remote workflows and tasks on the server.';

  @override
  Future<void> run() async {
    final client = _getClient();
    final tasks = await client.getAllTasks();

    if (tasks.isEmpty) {
      stdout.writeln('No workflows found on server.');
      return;
    }

    stdout.writeln(TerminalPrinter.bold('Remote Workflows (${tasks.length}):'));
    stdout.writeln('');

    final headers = ['Workflow ID', 'Name', 'Status', 'Agents', 'Internal MCPs'];
    final rows = <List<String>>[];

    for (final t in tasks) {
      rows.add([
        t.id,
        t.name,
        t.enabled ? TerminalPrinter.green('ENABLED') : TerminalPrinter.dim('DISABLED'),
        t.agents.length.toString(),
        t.internalMcps.map((m) => m.mcpType).join(', '),
      ]);
    }

    TerminalPrinter.printTable(headers: headers, rows: rows);
  }
}

/// `tealkit workflow run <workflow-name-or-id>`
class WorkflowRunCommand extends Command {
  @override
  final String name = 'run';
  @override
  final String description = 'Trigger remote workflow execution on the server.';

  @override
  Future<void> run() async {
    if (argResults?.rest.isEmpty ?? true) {
      stderr.writeln('Error: Please provide a workflow name or UUID.');
      stderr.writeln('Usage: tealkit workflow run <workflow-name-or-id>');
      return;
    }

    final identifier = argResults!.rest.join(' ').trim();
    final client = _getClient();

    final workflow = await _resolveWorkflow(client, identifier);
    if (workflow == null) return;

    stdout.writeln('Triggering execution for workflow "${workflow.name}" (${workflow.id})...');
    final runId = await client.runTask(workflow.id);
    stdout.writeln(TerminalPrinter.green('✔ Workflow triggered! Run ID: $runId'));
    stdout.writeln('Check status with: tealkit workflow status "${workflow.name}"');
  }
}

/// `tealkit workflow status <workflow-name-or-id>`
class WorkflowStatusCommand extends Command {
  @override
  final String name = 'status';
  @override
  final String description = 'Check running status and latest output for a workflow.';

  @override
  Future<void> run() async {
    if (argResults?.rest.isEmpty ?? true) {
      stderr.writeln('Error: Please provide a workflow name or UUID.');
      stderr.writeln('Usage: tealkit workflow status <workflow-name-or-id>');
      return;
    }

    final identifier = argResults!.rest.join(' ').trim();
    final client = _getClient();

    final workflow = await _resolveWorkflow(client, identifier);
    if (workflow == null) return;

    final isRunning = await client.getTaskRunStatus(workflow.id);
    stdout.writeln('Workflow "${workflow.name}" (${workflow.id}) status: ${isRunning ? TerminalPrinter.yellow("RUNNING") : TerminalPrinter.green("IDLE / COMPLETED")}');

    final output = await client.getTaskOutput(workflow.id);
    if (output != null && output.isNotEmpty) {
      stdout.writeln('');
      stdout.writeln(TerminalPrinter.bold('Latest Output:'));
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(output));
    }
  }
}

/// `tealkit workflow cancel <workflow-name-or-id>`
class WorkflowCancelCommand extends Command {
  @override
  final String name = 'cancel';
  @override
  final String description = 'Cancel a running workflow on the server.';

  @override
  Future<void> run() async {
    if (argResults?.rest.isEmpty ?? true) {
      stderr.writeln('Error: Please provide a workflow name or UUID.');
      stderr.writeln('Usage: tealkit workflow cancel <workflow-name-or-id>');
      return;
    }

    final identifier = argResults!.rest.join(' ').trim();
    final client = _getClient();

    final workflow = await _resolveWorkflow(client, identifier);
    if (workflow == null) return;

    stdout.writeln('Cancelling workflow "${workflow.name}" (${workflow.id})...');
    await client.cancelTask(workflow.id);
    stdout.writeln(TerminalPrinter.green('✔ Cancel request sent for workflow "${workflow.name}".'));
  }
}

/// `tealkit workflow logs <workflow-name-or-id>`
class WorkflowLogsCommand extends Command {
  @override
  final String name = 'logs';
  @override
  final String description = 'Fetch execution history and logs for a workflow.';

  @override
  Future<void> run() async {
    if (argResults?.rest.isEmpty ?? true) {
      stderr.writeln('Error: Please provide a workflow name or UUID.');
      stderr.writeln('Usage: tealkit workflow logs <workflow-name-or-id>');
      return;
    }

    final identifier = argResults!.rest.join(' ').trim();
    final client = _getClient();

    final workflow = await _resolveWorkflow(client, identifier);
    if (workflow == null) return;

    final logs = await client.getTaskExecutionLogs(workflow.id);
    if (logs == null || logs.isEmpty) {
      stdout.writeln('No execution logs available for workflow "${workflow.name}".');
      return;
    }

    stdout.writeln(TerminalPrinter.bold('Execution Logs for "${workflow.name}" (${workflow.id}):'));
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(logs));
  }
}

/// `tealkit workflow download <workflow-name-or-id> <filename> [--run-id <id>]`
class WorkflowDownloadCommand extends Command {
  @override
  final String name = 'download';
  @override
  final String description = 'Download an output file for a workflow run.';

  WorkflowDownloadCommand() {
    argParser.addOption('run-id', abbr: 'r', help: 'Specific run ID (defaults to latest)');
  }

  @override
  Future<void> run() async {
    final rest = argResults?.rest ?? [];
    if (rest.length < 2) {
      stderr.writeln('Error: Missing workflow name or filename.');
      stderr.writeln('Usage: tealkit workflow download <workflow-name-or-id> <filename> [--run-id <run-id>]');
      return;
    }

    final fileName = rest.last;
    final identifier = rest.sublist(0, rest.length - 1).join(' ').trim();
    final runId = argResults?['run-id'] as String? ?? 'latest';

    final client = _getClient();
    final workflow = await _resolveWorkflow(client, identifier);
    if (workflow == null) return;

    stdout.writeln('Downloading $fileName for workflow "${workflow.name}" (run: $runId)...');

    final bytes = await client.downloadTaskOutputFile(workflow.id, runId, fileName);
    final outFile = File(fileName);
    outFile.writeAsBytesSync(bytes);

    stdout.writeln(
      TerminalPrinter.green('✔ Successfully downloaded ${bytes.length} bytes to ${outFile.path}'),
    );
  }
}
