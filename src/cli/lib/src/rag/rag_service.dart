import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'extractors/docx_extractor.dart';
import 'extractors/pdf_extractor.dart';
import 'extractors/text_extractor.dart';
import 'extractors/web_extractor.dart';
import 'rag_chunker.dart';
import 'rag_config.dart';
import 'rag_database.dart';
import 'rag_embedder.dart';

/// Top-level coordinator for indexing, embedding, and hybrid search.
class RagService {
  final RagConfig config;
  late final RagDatabase database;
  late final RagEmbedder embedder;

  RagService(this.config) {
    database = RagDatabase(config.databasePath);
    embedder = RagEmbedder(config);
  }

  /// Initializes the underlying SQLite database.
  void init() {
    database.open();
  }

  /// Runs an incremental or full reindex pass over all configured sources.
  ///
  /// [onProgress] receives (currentStep, totalSteps, statusMessage).
  /// [logOutput] callback writes logging lines for scheduled headless execution.
  Future<Map<String, dynamic>> reindex({
    void Function(int current, int total, String status)? onProgress,
    void Function(String message)? logOutput,
  }) async {
    init();
    final stopwatch = Stopwatch()..start();

    void log(String msg) {
      if (logOutput != null) logOutput(msg);
    }

    log('Starting RAG index pass...');
    log('Database target: ${config.databasePath}');

    // 1. Gather all local files
    final allFiles = <File>[];
    for (final sourceDir in config.folderSources) {
      final dir = Directory(sourceDir);
      if (dir.existsSync()) {
        try {
          for (final entity in dir.listSync(recursive: true, followLinks: false)) {
            if (entity is File) {
              final ext = p.extension(entity.path).toLowerCase();
              if (config.fileExtensions.contains(ext)) {
                allFiles.add(entity);
              }
            }
          }
        } catch (e) {
          log('Warning: Error listing directory $sourceDir: $e');
        }
      } else {
        log('Warning: Source directory does not exist: $sourceDir');
      }
    }

    final totalSources = allFiles.length + config.webSources.length;
    log('Found ${allFiles.length} local files and ${config.webSources.length} web sources to evaluate.');

    int processedCount = 0;
    int updatedCount = 0;
    int skippedCount = 0;
    int errorCount = 0;
    int newChunksCount = 0;

    // 2. Index local files
    for (final file in allFiles) {
      processedCount++;
      final fileName = p.basename(file.path);
      if (onProgress != null) {
        onProgress(processedCount, totalSources, 'Indexing $fileName');
      }

      try {
        final stat = file.statSync();
        final existingDoc = database.getDocumentByUri(file.path);

        // Fast mtime & size check
        if (existingDoc != null &&
            existingDoc['file_size'] == stat.size &&
            existingDoc['last_modified'] == stat.modified.millisecondsSinceEpoch) {
          skippedCount++;
          continue;
        }

        // Extract content
        final text = _extractTextFromFile(file);
        if (text == null || text.trim().isEmpty) {
          skippedCount++;
          continue;
        }

        final contentHash = md5.convert(utf8.encode(text)).toString();
        if (existingDoc != null && existingDoc['content_hash'] == contentHash) {
          skippedCount++;
          continue;
        }

        // Chunking
        final chunks = RagChunker.splitText(
          text: text,
          chunkSize: config.chunkSize,
          chunkOverlap: config.chunkOverlap,
        );

        final docId = 'doc_${md5.convert(utf8.encode(file.path))}';
        final chunkMaps = <Map<String, dynamic>>[];
        final chunkTexts = chunks.map((c) => c.text).toList();
        final vectors = embedder.isEnabled
            ? await embedder.embedBatch(
                chunkTexts,
                onProgress: (current, total) {
                  final pct = ((current / total) * 100).toStringAsFixed(0);
                  stdout.write(
                    '\r\x1b[36m  -> [$fileName] Embedding chunk $current/$total ($pct%)\x1b[0m',
                  );
                },
              )
            : <Float32List?>[];
        if (embedder.isEnabled && chunkTexts.isNotEmpty) {
          stdout.writeln();
        }

        for (int i = 0; i < chunks.length; i++) {
          final c = chunks[i];
          final vec = i < vectors.length ? vectors[i] : null;

          chunkMaps.add({
            'id': '${docId}_${c.index}',
            'index': c.index,
            'content': c.text,
            'token_count': c.tokenCount,
            'line_start': c.startLine,
            'line_end': c.endLine,
            'embedding': vec != null ? RagEmbedder.vectorToBytes(vec) : null,
          });
        }

        database.saveDocumentWithChunks(
          documentId: docId,
          sourceType: 'file',
          uri: file.path,
          title: fileName,
          contentHash: contentHash,
          fileSize: stat.size,
          lastModified: stat.modified.millisecondsSinceEpoch,
          chunks: chunkMaps,
        );

        updatedCount++;
        newChunksCount += chunkMaps.length;
        log('Indexed: $fileName (${chunkMaps.length} chunks)');
      } catch (e) {
        errorCount++;
        log('Error indexing file ${file.path}: $e');
      }
    }

    // 3. Index Web sources with pure Dart web crawler
    final crawler = WebCrawler(maxPages: config.maxPages);
    for (final rawUrl in config.webSources) {
      processedCount++;
      Uri? seedUri;
      try {
        seedUri = Uri.parse(rawUrl);
        if (!seedUri.hasScheme) {
          seedUri = Uri.parse('https://$rawUrl');
        }
      } catch (_) {
        log('Skipping invalid web URL: $rawUrl');
        errorCount++;
        continue;
      }

      if (onProgress != null) {
        onProgress(processedCount, totalSources, 'Crawling $rawUrl (up to ${config.maxPages} pages)');
      }

      try {
        final pages = await crawler.crawlSeed(
          seedUri,
          onProgress: (crawled, totalEst, currentUrl) {
            stdout.write('\r\x1b[35m  -> [Crawler] Crawled $crawled/$totalEst pages ($currentUrl)\x1b[0m');
          },
        );
        if (pages.isNotEmpty) {
          stdout.writeln();
        }

        if (pages.isEmpty) {
          log('No crawlable HTML pages returned for $rawUrl');
          skippedCount++;
          continue;
        }

        log('Crawled ${pages.length} page(s) from $rawUrl. Processing and indexing...');

        for (final page in pages) {
          final pageUrl = page.url.toString();
          final contentHash = md5.convert(utf8.encode(page.text)).toString();
          final existingDoc = database.getDocumentByUri(pageUrl);
          if (existingDoc != null && existingDoc['content_hash'] == contentHash) {
            skippedCount++;
            continue;
          }

          final chunks = RagChunker.splitText(
            text: page.text,
            chunkSize: config.chunkSize,
            chunkOverlap: config.chunkOverlap,
          );

          final docId = 'web_${md5.convert(utf8.encode(pageUrl))}';
          final chunkMaps = <Map<String, dynamic>>[];

          final chunkTexts = chunks.map((c) => c.text).toList();
          final vectors = embedder.isEnabled
              ? await embedder.embedBatch(
                  chunkTexts,
                  onProgress: (current, total) {
                    final pct = ((current / total) * 100).toStringAsFixed(0);
                    final label = page.title.isNotEmpty ? page.title : pageUrl;
                    final shortLabel = label.length > 30 ? label.substring(0, 30) : label;
                    stdout.write(
                      '\r\x1b[36m  -> [$shortLabel] Embedding chunk $current/$total ($pct%)\x1b[0m',
                    );
                  },
                )
              : <Float32List?>[];
          if (embedder.isEnabled && chunkTexts.isNotEmpty) {
            stdout.writeln();
          }

          for (int i = 0; i < chunks.length; i++) {
            final c = chunks[i];
            final vec = i < vectors.length ? vectors[i] : null;

            chunkMaps.add({
              'id': '${docId}_${c.index}',
              'index': c.index,
              'content': c.text,
              'token_count': c.tokenCount,
              'line_start': c.startLine,
              'line_end': c.endLine,
              'embedding': vec != null ? RagEmbedder.vectorToBytes(vec) : null,
            });
          }

          database.saveDocumentWithChunks(
            documentId: docId,
            sourceType: 'web',
            uri: pageUrl,
            title: page.title.isNotEmpty ? page.title : pageUrl,
            contentHash: contentHash,
            fileSize: page.text.length,
            lastModified: DateTime.now().millisecondsSinceEpoch,
            chunks: chunkMaps,
          );

          updatedCount++;
          newChunksCount += chunkMaps.length;
          log('Indexed Web: ${page.title} ($pageUrl) - ${chunkMaps.length} chunks');
        }
      } catch (e) {
        errorCount++;
        log('Error crawling/indexing website $rawUrl: $e');
      }
    }

    stopwatch.stop();
    final elapsedSec = (stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1);
    log('Index pass complete in ${elapsedSec}s. Updated: $updatedCount, Unchanged: $skippedCount, Errors: $errorCount.');

    return {
      'duration_seconds': elapsedSec,
      'evaluated': totalSources,
      'updated': updatedCount,
      'skipped': skippedCount,
      'errors': errorCount,
      'new_chunks': newChunksCount,
      'stats': database.getStats(),
    };
  }

  /// Dispatches file text extraction by extension.
  String? _extractTextFromFile(File file) {
    final ext = p.extension(file.path).toLowerCase();
    switch (ext) {
      case '.docx':
        return DocxExtractor.extractFromFile(file);
      case '.pdf':
        return PdfExtractor.extractFromFile(file);
      default:
        return TextExtractor.extractFromFile(file);
    }
  }

  /// Searches indexed documents and web sources using hybrid RRF scoring.
  Future<List<ScoredChunk>> search(
    String query, {
    int? limit,
    double? minScore,
  }) async {
    if (!config.enabled) return [];
    init();

    final maxResults = limit ?? config.maxChunks;
    final threshold = minScore ?? config.minScore;
    final mode = config.searchMode.toLowerCase();

    // 1. Keyword FTS5 search
    List<ScoredChunk> ftsResults = [];
    if (mode == 'fts' || mode == 'hybrid') {
      ftsResults = database.searchFts(query, limit: maxResults * 2);
    }

    // 2. Semantic vector search
    List<ScoredChunk> vectorResults = [];
    if ((mode == 'semantic' || mode == 'hybrid') && embedder.isEnabled) {
      final queryVec = await embedder.embedText(query);
      if (queryVec != null) {
        final candidateChunks = database.getAllChunksWithVectors();
        final scoredList = <ScoredChunk>[];

        for (final row in candidateChunks) {
          final blob = row['embedding'] as List<int>?;
          if (blob == null) continue;
          final chunkVec = RagEmbedder.bytesToVector(blob);
          final sim = RagEmbedder.cosineSimilarity(queryVec, chunkVec);

          if (sim >= threshold) {
            scoredList.add(
              ScoredChunk(
                chunkId: row['chunk_id'] as String,
                documentId: row['document_id'] as String,
                documentUri: row['uri'] as String,
                documentTitle: row['title'] as String?,
                chunkIndex: row['chunk_index'] as int?,
                lineStart: row['line_start'] as int?,
                lineEnd: row['line_end'] as int?,
                content: row['content'] as String,
                score: sim,
                matchType: 'vector',
              ),
            );
          }
        }

        scoredList.sort((a, b) => b.score.compareTo(a.score));
        vectorResults = scoredList.take(maxResults * 2).toList();
      }
    }

    if (mode == 'fts') {
      return ftsResults.where((c) => c.score >= threshold).take(maxResults).toList();
    }
    if (mode == 'semantic') {
      return vectorResults.take(maxResults).toList();
    }

    // 3. Hybrid Reciprocal Rank Fusion (RRF)
    final rrfScores = <String, double>{};
    final chunkMap = <String, ScoredChunk>{};

    for (int i = 0; i < ftsResults.length; i++) {
      final c = ftsResults[i];
      chunkMap[c.chunkId] = c;
      rrfScores[c.chunkId] = (rrfScores[c.chunkId] ?? 0.0) + (1.0 / (60.0 + (i + 1)));
    }

    for (int i = 0; i < vectorResults.length; i++) {
      final c = vectorResults[i];
      chunkMap[c.chunkId] = c;
      rrfScores[c.chunkId] = (rrfScores[c.chunkId] ?? 0.0) + (1.0 / (60.0 + (i + 1)));
    }

    final fusedList = rrfScores.entries.map((entry) {
      final chunk = chunkMap[entry.key]!;
      return ScoredChunk(
        chunkId: chunk.chunkId,
        documentId: chunk.documentId,
        documentUri: chunk.documentUri,
        documentTitle: chunk.documentTitle,
        chunkIndex: chunk.chunkIndex,
        lineStart: chunk.lineStart,
        lineEnd: chunk.lineEnd,
        content: chunk.content,
        score: entry.value,
        matchType: 'hybrid',
      );
    }).toList();

    fusedList.sort((a, b) => b.score.compareTo(a.score));
    return fusedList.take(maxResults).toList();
  }

  /// Builds a Markdown context snippet to inject into agent prompts.
  Future<String?> buildPromptContext(String userQuery) async {
    if (!config.enabled) return null;

    final hits = await search(userQuery);
    if (hits.isEmpty) return null;

    final buffer = StringBuffer();
    buffer.writeln('\n[Relevant Knowledge Base Documents]:');
    buffer.writeln('Instructions for LLM: When using facts from these documents in your answer, reference the source using its clickable link (e.g. `[filename](file:///path#Lline)`) or terminal location (`path:line`).');
    buffer.writeln('');
    for (int i = 0; i < hits.length; i++) {
      final h = hits[i];
      final title = h.documentTitle ?? p.basename(h.documentUri);
      buffer.writeln('--- Source [${i + 1}]: $title (${h.locationLabel}) ---');
      buffer.writeln('Location: ${h.terminalLocation}');
      buffer.writeln('URI: ${h.clickableLink}');
      buffer.writeln(h.content.trim());
      buffer.writeln('');
    }

    return buffer.toString().trim();
  }

  void dispose() {
    database.close();
    embedder.dispose();
  }
}
