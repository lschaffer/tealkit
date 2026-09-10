import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:tealkit_api/tealkit_api.dart';

import '../config/server_config.dart';
import '../formatters/terminal_printer.dart';

/// Top-level command for server management.
class ServerCommand extends Command {
  @override
  final String name = 'server';
  @override
  final String description = 'Manage TealKit server connection profiles.';

  ServerCommand() {
    addSubcommand(ServerListCommand());
    addSubcommand(ServerActivateCommand());
  }
}

/// `tealkit server list`
class ServerListCommand extends Command {
  @override
  final String name = 'list';
  @override
  final String description = 'List all configured server profiles.';

  @override
  void run() {
    final manager = ServerConfigManager();
    final profiles = manager.loadProfiles();

    if (profiles.isEmpty) {
      stdout.writeln('No servers configured in server.yaml.');
      return;
    }

    stdout.writeln(TerminalPrinter.bold('TealKit Server Profiles:'));
    stdout.writeln('');

    final headers = ['#', 'Status', 'Name', 'URL', 'API Key'];
    final rows = <List<String>>[];

    for (int i = 0; i < profiles.length; i++) {
      final p = profiles[i];
      final status = p.isActive ? TerminalPrinter.green('* ACTIVE') : '  ';
      final apiKeyDisplay = p.apiKey.isEmpty
          ? TerminalPrinter.dim('(none)')
          : '${p.apiKey.substring(0, p.apiKey.length > 8 ? 8 : p.apiKey.length)}...';

      rows.add([
        (i + 1).toString(),
        status,
        p.name,
        p.url,
        apiKeyDisplay,
      ]);
    }

    TerminalPrinter.printTable(headers: headers, rows: rows);
  }
}

/// `tealkit server activate <name|index>`
class ServerActivateCommand extends Command {
  @override
  final String name = 'activate';
  @override
  final String description = 'Activate a server profile by 1-based index or profile name.';

  @override
  void run() {
    if (argResults?.rest.isEmpty ?? true) {
      stderr.writeln('Error: Please provide profile name or index.');
      stderr.writeln('Usage: tealkit server activate <index|name>');
      return;
    }

    final identifier = argResults!.rest.first;
    final manager = ServerConfigManager();
    final success = manager.activateProfile(identifier);

    if (success) {
      final active = manager.getActiveProfile();
      stdout.writeln(
        TerminalPrinter.green('✔ Activated server profile: "${active?.name}" (${active?.url})'),
      );
    } else {
      stderr.writeln(
        TerminalPrinter.red('Error: Server profile "$identifier" not found.'),
      );
    }
  }
}

/// Standalone `tealkit ping` command
class PingCommand extends Command {
  @override
  final String name = 'ping';
  @override
  final String description = 'Verify connectivity and health with the active TealKit server.';

  @override
  Future<void> run() async {
    final manager = ServerConfigManager();
    final profile = manager.getActiveProfile();

    if (profile == null) {
      stderr.writeln(TerminalPrinter.red('Error: No active server profile in server.yaml.'));
      return;
    }

    stdout.writeln('Pinging ${TerminalPrinter.cyan(profile.name)} at ${profile.url}...');
    final stopwatch = Stopwatch()..start();

    final client = ServerApiClient(
      serverUrl: profile.url,
      apiKey: profile.apiKey.isNotEmpty ? profile.apiKey : null,
    );

    try {
      final isHealthy = await client.ping();
      stopwatch.stop();

      if (isHealthy) {
        stdout.writeln(
          TerminalPrinter.green(
            '✔ Server responded OK (200) in ${stopwatch.elapsedMilliseconds} ms',
          ),
        );

        final health = await client.getHealthStatus();
        if (health.isNotEmpty) {
          stdout.writeln(TerminalPrinter.dim('Server Health details: $health'));
        }
      } else {
        stderr.writeln(
          TerminalPrinter.red('✖ Server ping failed (not reachable or error status).'),
        );
      }
    } catch (e) {
      stopwatch.stop();
      stderr.writeln(TerminalPrinter.red('✖ Connection failed after ${stopwatch.elapsedMilliseconds} ms: $e'));
    }
  }
}
