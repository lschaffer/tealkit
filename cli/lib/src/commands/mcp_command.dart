import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';

import '../formatters/terminal_printer.dart';
import '../mcp/mcp_config_installer.dart';

/// Top-level command for TealKit MCP server and client integrations.
class McpCommand extends Command {
  @override
  final String name = 'mcp';
  @override
  final String description =
      'Model Context Protocol (MCP) server management, installation, and client configuration.';

  McpCommand() {
    addSubcommand(McpServeCommand());
    addSubcommand(McpInstallClaudeCommand());
    addSubcommand(McpConfigCommand());
  }
}

/// Informs developers about the dedicated TealKit MCP server.
class McpServeCommand extends Command {
  @override
  final String name = 'serve';
  @override
  final String description =
      'Starts or guides the TealKit MCP stdio server for Claude Desktop, Cursor, and Roo Code.';
  @override
  final List<String> aliases = ['mcp-serve'];

  McpServeCommand() {
    argParser
      ..addOption(
        'server-url',
        help: 'TealKit Server URL (default: https://tealkit.dev/tealkitserver)',
        defaultsTo: 'https://tealkit.dev/tealkitserver',
      )
      ..addOption(
        'server-key',
        help: 'Optional TealKit Server API Key',
      );
  }

  @override
  Future<void> run() async {
    final serverUrl = (argResults?['server-url'] as String?) ?? 'https://tealkit.dev/tealkitserver';
    final serverKey = argResults?['server-key'] as String?;

    stdout.writeln(TerminalPrinter.bold('─── TealKit Model Context Protocol (MCP) ───'));
    stdout.writeln('');
    stdout.writeln('The TealKit MCP Server is now published in a dedicated lightweight package:');
    stdout.writeln(TerminalPrinter.cyan('  https://github.com/lschaffer/tealkit-mcp'));
    stdout.writeln('');
    stdout.writeln('To launch the MCP server directly:');
    stdout.writeln(
      TerminalPrinter.green(
        '  dart run https://github.com/lschaffer/tealkit-mcp.git --server-url $serverUrl ${serverKey != null ? "--server-key $serverKey" : ""}',
      ),
    );
    stdout.writeln('');
    stdout.writeln('To automatically register in Claude Desktop, run:');
    stdout.writeln(TerminalPrinter.green('  tealkit mcp install-claude'));
  }
}

/// Standalone shortcut command so `tealkit mcp-serve` works directly at the root.
class DirectMcpServeCommand extends McpServeCommand {
  @override
  String get name => 'mcp-serve';
  @override
  List<String> get aliases => [];
}

/// Command to automatically install TealKit MCP into Claude Desktop.
class McpInstallClaudeCommand extends Command {
  @override
  final String name = 'install-claude';
  @override
  final String description =
      'Automatically registers TealKit MCP server inside Claude Desktop configuration.';

  McpInstallClaudeCommand() {
    argParser.addOption(
      'config-path',
      abbr: 'c',
      help: 'Custom path to claude_desktop_config.json',
    );
  }

  @override
  void run() {
    final customPath = argResults?['config-path'] as String?;
    final result = McpConfigInstaller.installToClaudeDesktop(
      configPath: customPath,
    );

    if (result.success) {
      stdout.writeln(TerminalPrinter.green('✔ ${result.message}'));
      stdout.writeln(
        TerminalPrinter.dim('  Config file: ${result.configPath}'),
      );
      stdout.writeln('');
      stdout.writeln('Registered configuration:');
      stdout.writeln(
        const JsonEncoder.withIndent('  ').convert({
          'mcpServers': {'tealkit': result.serverDefinition},
        }),
      );
      stdout.writeln('');
      stdout.writeln(
        TerminalPrinter.bold(
          'Restart Claude Desktop to start using TealKit tools.',
        ),
      );
    } else {
      stderr.writeln(
        TerminalPrinter.red(
          '✘ Failed to install Claude Desktop configuration:',
        ),
      );
      stderr.writeln('  ${result.message}');
    }
  }
}

/// Command to output copy-pasteable MCP configs for Claude, Cursor, and Roo Code.
class McpConfigCommand extends Command {
  @override
  final String name = 'config';
  @override
  final String description =
      'Prints ready-to-copy MCP configuration snippets for Claude Desktop, Cursor, and Roo Code.';

  @override
  void run() {
    stdout.writeln(
      TerminalPrinter.bold(
        '─── 1. Local Stdio Configuration (Claude Desktop: claude_desktop_config.json) ───',
      ),
    );
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'mcpServers': {'tealkit': McpConfigInstaller.generateServerConfig()},
      }),
    );
    stdout.writeln('');

    stdout.writeln(
      TerminalPrinter.bold(
        '─── 2. Remote SSE / HTTPS Configuration (Claude, Cursor, LibreChat, OpenWebUI) ───',
      ),
    );
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'mcpServers': {
          'tealkit-remote': {
            'url': 'http://localhost:8081/sse',
            'headers': {'Authorization': 'Bearer YOUR_OPTIONAL_API_KEY'},
          },
        },
      }),
    );
    stdout.writeln('');

    stdout.writeln(
      TerminalPrinter.bold(
        '─── 3. Cursor MCP Configuration (Settings -> Features -> MCP) ───',
      ),
    );
    stdout.writeln('Name   : TealKit');
    stdout.writeln('Type   : command');
    stdout.writeln(
      'Command: ${McpConfigInstaller.resolveExecutableCommand()} mcp-serve',
    );
    stdout.writeln('');

    stdout.writeln(
      TerminalPrinter.bold(
        '─── 4. Roo Code / Cline (cline_mcp_settings.json) ───',
      ),
    );
    stdout.writeln(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(McpConfigInstaller.generateRooCodeConfig()),
    );
    stdout.writeln('');
  }
}
