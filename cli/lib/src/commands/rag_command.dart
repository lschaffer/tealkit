import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;
import '../config/cli_config.dart';
import '../formatters/terminal_printer.dart';
import '../formatters/terminal_spinner.dart';
import '../rag/rag_service.dart';

/// Top-level command for local RAG management in TealKit CLI.
class RagCommand extends Command {
  @override
  final String name = 'rag';
  @override
  final String description =
      'Manage local RAG indexing (PDF, DOCX, text, web) and execute semantic/FTS queries.';

  RagCommand() {
    addSubcommand(RagReindexCommand());
    addSubcommand(RagStatusCommand());
    addSubcommand(RagSearchCommand());
  }
}

/// `tealkit rag reindex`
class RagReindexCommand extends Command {
  @override
  final String name = 'reindex';
  @override
  final String description =
      'Rebuild or incrementally update the local RAG SQLite index.';

  RagReindexCommand() {
    argParser.addOption(
      'max-pages',
      abbr: 'p',
      help: 'Maximum web pages to crawl per website source (default from config)',
    );
  }

  @override
  Future<void> run() async {
    final config = CliConfig.load();
    final maxPagesArg = argResults?['max-pages'] as String?;
    if (maxPagesArg != null) {
      final parsed = int.tryParse(maxPagesArg);
      if (parsed != null && parsed > 0) {
        config.rag.maxPages = parsed;
      }
    }
    final service = RagService(config.rag);

    stdout.writeln(TerminalPrinter.bold('─── TealKit Local RAG Indexer ───'));
    stdout.writeln('Database: ${config.rag.databasePath}');
    stdout.writeln('Folders:  ${config.rag.folderSources.join(", ")}');
    if (config.rag.webSources.isNotEmpty) {
      stdout.writeln('Web URLs: ${config.rag.webSources.join(", ")} (max_pages: ${config.rag.maxPages})');
    }
    stdout.writeln('');

    final spinner = TerminalProgress('Scanning and indexing sources...');
    spinner.start();

    try {
      final res = await service.reindex(
        onProgress: (current, total, status) {
          spinner.start('[$current/$total] $status');
        },
      );
      spinner.stop();

      stdout.writeln(TerminalPrinter.green('✔ Indexing completed successfully!'));
      stdout.writeln('  Time elapsed: ${res['duration_seconds']}s');
      stdout.writeln('  Evaluated:    ${res['evaluated']} sources');
      stdout.writeln('  Updated:      ${res['updated']} files/pages');
      stdout.writeln('  Unchanged:    ${res['skipped']} files/pages');
      stdout.writeln('  New chunks:   ${res['new_chunks']}');
      final stats = res['stats'] as Map<String, dynamic>;
      stdout.writeln('  Total docs:   ${stats['document_count']}');
      stdout.writeln('  Total chunks: ${stats['chunk_count']}');
      stdout.writeln('  DB file size: ${stats['file_size_mb']} MB');
    } catch (e) {
      spinner.stop();
      stderr.writeln(TerminalPrinter.red('❌ Indexing failed: $e'));
      exitCode = 1;
    } finally {
      service.dispose();
    }
  }
}

/// `tealkit rag status`
class RagStatusCommand extends Command {
  @override
  final String name = 'status';
  @override
  final String description = 'Show RAG database stats and storage location.';

  @override
  Future<void> run() async {
    final config = CliConfig.load();
    final service = RagService(config.rag);

    try {
      service.init();
      final stats = service.database.getStats();

      stdout.writeln(TerminalPrinter.bold('─── RAG Database Status ───'));
      stdout.writeln('Status:       ${config.rag.enabled ? TerminalPrinter.green("Enabled") : TerminalPrinter.yellow("Disabled")}');
      stdout.writeln('Database:     ${stats['database_path']}');
      stdout.writeln('Size:         ${stats['file_size_mb']} MB (${stats['file_size_bytes']} bytes)');
      stdout.writeln('Documents:    ${stats['document_count']}');
      stdout.writeln('Total chunks: ${stats['chunk_count']}');
      stdout.writeln('Vector chunks:${stats['vector_count']}');
      stdout.writeln('Search mode:  ${config.rag.searchMode}');
      stdout.writeln('Embedding:    ${config.rag.embeddingProvider} (${config.rag.embeddingModel})');
      stdout.writeln('Sources:      ${config.rag.folderSources.join(", ")}');
      if (config.rag.webSources.isNotEmpty) {
        stdout.writeln('Web Sources:  ${config.rag.webSources.join(", ")} (max_pages: ${config.rag.maxPages})');
      }
    } catch (e) {
      stderr.writeln(TerminalPrinter.red('Error reading RAG status: $e'));
    } finally {
      service.dispose();
    }
  }
}

/// `tealkit rag search <query>`
class RagSearchCommand extends Command {
  @override
  final String name = 'search';
  @override
  final String description = 'Perform a test search across indexed documents and web pages.';

  RagSearchCommand() {
    argParser.addOption(
      'limit',
      abbr: 'l',
      defaultsTo: '5',
      help: 'Maximum number of chunks to return',
    );
  }

  @override
  Future<void> run() async {
    if (argResults?.rest.isEmpty ?? true) {
      stderr.writeln('Usage: tealkit rag search <query>');
      exitCode = 1;
      return;
    }

    final query = argResults!.rest.join(' ');
    final limit = int.tryParse(argResults?['limit'] as String? ?? '5') ?? 5;

    final config = CliConfig.load();
    final service = RagService(config.rag);

    final spinner = TerminalProgress('Searching local RAG...');
    spinner.start();

    try {
      final results = await service.search(query, limit: limit);
      spinner.stop();

      if (results.isEmpty) {
        stdout.writeln(TerminalPrinter.yellow('No matching documents found.'));
        return;
      }

      stdout.writeln(TerminalPrinter.bold('─── RAG Search Results (${results.length}) ───'));
      for (int i = 0; i < results.length; i++) {
        final c = results[i];
        final scorePercent = (c.score * 100).toStringAsFixed(1);
        final title = c.documentTitle ?? p.basename(c.documentUri);

        stdout.writeln(TerminalPrinter.cyan('[${i + 1}] $title ($scorePercent%, ${c.matchType}, ${c.locationLabel})'));
        stdout.writeln('    File: ${TerminalPrinter.bold(c.terminalLocation)}');
        stdout.writeln('    Link: ${TerminalPrinter.underline(c.clickableLink)}');
        final preview = c.content.length > 250
            ? '${c.content.substring(0, 250)}...'
            : c.content;
        stdout.writeln(TerminalPrinter.dim('    ${preview.replaceAll('\n', ' ')}'));
        stdout.writeln('');
      }
    } catch (e) {
      spinner.stop();
      stderr.writeln(TerminalPrinter.red('Search error: $e'));
    } finally {
      service.dispose();
    }
  }
}
