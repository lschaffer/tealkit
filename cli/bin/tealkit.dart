import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:tealkit_cli/tealkit_cli.dart';

Future<void> main(List<String> args) async {
  final runner = buildTealKitCommandRunner();

  try {
    if (args.isEmpty) {
      runner.printUsage();
      return;
    }
    await runner.run(args);
  } on UsageException catch (e) {
    stderr.writeln(TerminalPrinter.red(e.message));
    stderr.writeln('');
    stderr.writeln(e.usage);
    exit(64);
  } catch (e, stack) {
    stderr.writeln(TerminalPrinter.red('Error: $e'));
    if (args.contains('--verbose') || args.contains('-v')) {
      stderr.writeln(stack);
    }
    exit(1);
  }
}
