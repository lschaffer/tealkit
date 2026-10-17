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
  // Check for headless RAG reindexing (e.g. for Windows Task Scheduler)
  if (args.contains('--rag-reindex') || args.contains('-rag-reindex')) {
    await _handleRagReindex(args);
    return;
  }

  final hasReinit = args.contains('--reinit');
  final cleanedArgs = args.where((a) => a != '--reinit').toList();

  // Check if first-time run or --reinit requested
  await GlobalConfigLocator.ensureInitialized(forceReinit: hasReinit);

  if (hasReinit && cleanedArgs.isEmpty) {
    return;
  }

  final runner = buildTealKitCommandRunner();
  final effectiveArgs = _preprocessArgs(cleanedArgs);

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

Future<void> _handleRagReindex(List<String> args) async {
  String timestamp() =>
      DateTime.now().toIso8601String().substring(0, 19).replaceAll('T', ' ');

  stdout.writeln('[${timestamp()}] [INFO] Starting TealKit scheduled RAG reindexing...');

  String? explicitConfig;
  for (int i = 0; i < args.length; i++) {
    if (args[i] == '--config' && i + 1 < args.length) {
      explicitConfig = args[i + 1];
    } else if (args[i].startsWith('--config=')) {
      explicitConfig = args[i].substring('--config='.length);
    }
  }

  final configFile = GlobalConfigLocator.resolveConfigFile('config.yaml', explicitConfig);
  final config = CliConfig.load(configPath: configFile.path);
  stdout.writeln('[${timestamp()}] [INFO] Loaded config from: ${configFile.path}');
  stdout.writeln('[${timestamp()}] [INFO] Target database: ${config.rag.databasePath}');
  stdout.writeln(
      '[${timestamp()}] [INFO] Search mode: ${config.rag.searchMode} | Embedder: ${config.rag.embeddingProvider} (${config.rag.embeddingModel})');
  stdout.writeln(
      '[${timestamp()}] [INFO] Folder sources (${config.rag.folderSources.length}): ${config.rag.folderSources.join(", ")}');
  if (config.rag.webSources.isNotEmpty) {
    stdout.writeln(
        '[${timestamp()}] [INFO] Web sources (${config.rag.webSources.length}): ${config.rag.webSources.join(", ")}');
  }

  final service = RagService(config.rag);
  try {
    final res = await service.reindex(
      logOutput: (msg) {
        stdout.writeln('[${timestamp()}] [LOG] $msg');
      },
      onProgress: (current, total, status) {
        stdout.writeln('[${timestamp()}] [PROGRESS $current/$total] $status');
      },
    );

    final stats = res['stats'] as Map<String, dynamic>;
    stdout.writeln(
        '[${timestamp()}] [SUCCESS] RAG reindexing completed in ${res['duration_seconds']}s');
    stdout.writeln(
        '[${timestamp()}] [SUMMARY] Evaluated: ${res['evaluated']} | Updated: ${res['updated']} | Unchanged: ${res['skipped']} | Chunks created: ${res['new_chunks']}');
    stdout.writeln(
        '[${timestamp()}] [DATABASE] Total documents: ${stats['document_count']} | Total chunks: ${stats['chunk_count']} | DB size: ${stats['file_size_mb']} MB');
    exit(0);
  } catch (e, stack) {
    stderr.writeln('[${timestamp()}] [ERROR] RAG reindexing failed: $e');
    if (args.contains('--verbose') || args.contains('-v')) {
      stderr.writeln(stack);
    }
    exit(1);
  } finally {
    service.dispose();
  }
}

