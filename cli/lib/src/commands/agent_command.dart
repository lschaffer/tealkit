import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:tealkit_api/tealkit_api.dart';

import '../config/server_config.dart';
import '../formatters/terminal_printer.dart';

/// Top-level command for remote task/agent management.
class AgentCommand extends Command {
  @override
  final String name = 'agent';
  @override
  final String description = 'Manage and execute remote tasks and agents on the server.';
  @override
  final List<String> aliases = ['task'];

  AgentCommand() {
    addSubcommand(AgentListCommand());
    addSubcommand(AgentRunCommand());
    addSubcommand(AgentStatusCommand());
    addSubcommand(AgentCancelCommand());
    addSubcommand(AgentLogsCommand());
    addSubcommand(AgentDownloadCommand());
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

/// `tealkit agent list`
class AgentListCommand extends Command {
  @override
  final String name = 'list';
  @override
  final String description = 'List tasks on the server.';

  @override
  Future<void> run() async {
    final client = _getClient();
    final tasks = await client.getAllTasks();

    if (tasks.isEmpty) {
      stdout.writeln('No tasks found on server.');
      return;
    }

    stdout.writeln(TerminalPrinter.bold('Remote Tasks & Agents (${tasks.length}):'));
    stdout.writeln('');

    final headers = ['Task ID', 'Name', 'Status', 'Agents', 'Internal MCPs'];
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

/// `tealkit agent run <task-id>`
class AgentRunCommand extends Command {
  @override
  final String name = 'run';
  @override
  final String description = 'Trigger remote task execution on the server.';

  @override
  Future<void> run() async {
    if (argResults?.rest.isEmpty ?? true) {
      stderr.writeln('Error: Please provide a task ID.');
      stderr.writeln('Usage: tealkit agent run <task-id>');
      return;
    }

    final taskId = argResults!.rest.first;
    final client = _getClient();

    stdout.writeln('Triggering execution for task $taskId...');
    final runId = await client.runTask(taskId);
    stdout.writeln(TerminalPrinter.green('✔ Task triggered! Run ID: $runId'));
    stdout.writeln('Check status with: tealkit agent status $taskId');
  }
}

/// `tealkit agent status <task-id>`
class AgentStatusCommand extends Command {
  @override
  final String name = 'status';
  @override
  final String description = 'Check running status and latest output for a task.';

  @override
  Future<void> run() async {
    if (argResults?.rest.isEmpty ?? true) {
      stderr.writeln('Error: Please provide a task ID.');
      stderr.writeln('Usage: tealkit agent status <task-id>');
      return;
    }

    final taskId = argResults!.rest.first;
    final client = _getClient();

    final isRunning = await client.getTaskRunStatus(taskId);
    stdout.writeln('Task $taskId status: ${isRunning ? TerminalPrinter.yellow("RUNNING") : TerminalPrinter.green("IDLE / COMPLETED")}');

    final output = await client.getTaskOutput(taskId);
    if (output != null && output.isNotEmpty) {
      stdout.writeln('');
      stdout.writeln(TerminalPrinter.bold('Latest Output:'));
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(output));
    }
  }
}

/// `tealkit agent cancel <task-id>`
class AgentCancelCommand extends Command {
  @override
  final String name = 'cancel';
  @override
  final String description = 'Cancel a running task on the server.';

  @override
  Future<void> run() async {
    if (argResults?.rest.isEmpty ?? true) {
      stderr.writeln('Error: Please provide a task ID.');
      stderr.writeln('Usage: tealkit agent cancel <task-id>');
      return;
    }

    final taskId = argResults!.rest.first;
    final client = _getClient();

    stdout.writeln('Cancelling task $taskId...');
    await client.cancelTask(taskId);
    stdout.writeln(TerminalPrinter.green('✔ Cancel request sent for task $taskId.'));
  }
}

/// `tealkit agent logs <task-id>`
class AgentLogsCommand extends Command {
  @override
  final String name = 'logs';
  @override
  final String description = 'Fetch execution history and logs for a task.';

  @override
  Future<void> run() async {
    if (argResults?.rest.isEmpty ?? true) {
      stderr.writeln('Error: Please provide a task ID.');
      stderr.writeln('Usage: tealkit agent logs <task-id>');
      return;
    }

    final taskId = argResults!.rest.first;
    final client = _getClient();

    final logs = await client.getTaskExecutionLogs(taskId);
    if (logs == null || logs.isEmpty) {
      stdout.writeln('No execution logs available for task $taskId.');
      return;
    }

    stdout.writeln(TerminalPrinter.bold('Execution Logs for $taskId:'));
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(logs));
  }
}

/// `tealkit agent download <task-id> <filename> [--run-id <id>]`
class AgentDownloadCommand extends Command {
  @override
  final String name = 'download';
  @override
  final String description = 'Download an output file for a task run.';

  AgentDownloadCommand() {
    argParser.addOption('run-id', abbr: 'r', help: 'Specific run ID (defaults to latest)');
  }

  @override
  Future<void> run() async {
    final rest = argResults?.rest ?? [];
    if (rest.length < 2) {
      stderr.writeln('Error: Missing task-id or filename.');
      stderr.writeln('Usage: tealkit agent download <task-id> <filename> [--run-id <run-id>]');
      return;
    }

    final taskId = rest[0];
    final fileName = rest[1];
    final runId = argResults?['run-id'] as String? ?? 'latest';

    final client = _getClient();
    stdout.writeln('Downloading $fileName for task $taskId (run: $runId)...');

    final bytes = await client.downloadTaskOutputFile(taskId, runId, fileName);
    final outFile = File(fileName);
    outFile.writeAsBytesSync(bytes);

    stdout.writeln(
      TerminalPrinter.green('✔ Successfully downloaded ${bytes.length} bytes to ${outFile.path}'),
    );
  }
}
