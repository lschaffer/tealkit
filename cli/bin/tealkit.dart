import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:tealkit_cli/tealkit_cli.dart';

List<String> _preprocessArgs(List<String> rawArgs) {
  final processed = <String>[];
  for (final arg in rawArgs) {
    if (arg.startsWith('--llm:')) {
      final name = arg.substring('--llm:'.length).trim();
      processed.add('--llm-name');
      processed.add(name);
    } else if (arg.startsWith('-llm:')) {
      final name = arg.substring('-llm:'.length).trim();
      processed.add('--llm-name');
      processed.add(name);
    } else {
      processed.add(arg);
    }
  }
  return processed;
}

Future<void> main(List<String> args) async {
  final runner = buildTealKitCommandRunner();
  final effectiveArgs = _preprocessArgs(args);

  try {
    if (effectiveArgs.isEmpty) {
      runner.printUsage();
      return;
    }
    await runner.run(effectiveArgs);
  } on UsageException catch (e) {
    stderr.writeln(TerminalPrinter.red(e.message));
    stderr.writeln('');
    stderr.writeln(e.usage);
    exit(64);
  } catch (e, stack) {
    stderr.writeln(TerminalPrinter.red('Error: $e'));
    if (effectiveArgs.contains('--verbose') || effectiveArgs.contains('-v')) {
      stderr.writeln(stack);
    }
    exit(1);
  }
}
