import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:llamadart/llamadart.dart';
import '../engine/embedded/cli_embedded_model_manager.dart';
import 'rag_config.dart';

/// Handles text embedding generation and vector similarity calculations.
class RagEmbedder {
  final RagConfig config;
  final http.Client _client = http.Client();

  static LlamaBackend? _embeddedBackend;
  static LlamaEngine? _embeddedEngine;
  static String? _loadedEmbeddedModelPath;

  RagEmbedder(this.config);

  /// Whether semantic embedding generation is configured and enabled.
  bool get isEnabled =>
      config.embeddingProvider.isNotEmpty &&
      config.embeddingProvider != 'none';

  /// Ensures the embedded model file is downloaded and loaded into LlamaEngine.
  Future<void> _ensureEmbeddedEngine({
    void Function(double progress, String status)? onDownloadProgress,
  }) async {
    if (_embeddedEngine != null && _embeddedEngine!.isReady && _loadedEmbeddedModelPath != null) {
      return;
    }

    final modelFilename = config.embeddingModel;
    final repo = config.embeddingRepo.isNotEmpty ? config.embeddingRepo : null;

    final modelFile = await CliEmbeddedModelManager.instance.ensureModelDownloaded(
      modelFilename: modelFilename,
      repo: repo,
      onProgress: onDownloadProgress ??
          (progress, status) {
            final pct = (progress * 100).toStringAsFixed(1);
            stdout.write(
              '\r\x1b[36m[EmbeddingGemma] Downloading $modelFilename: $pct% ($status)\x1b[0m',
            );
          },
    );

    if (onDownloadProgress == null) {
      stdout.writeln();
    }

    _embeddedBackend ??= LlamaBackend();
    _embeddedEngine ??= LlamaEngine(_embeddedBackend!);

    if (_loadedEmbeddedModelPath != modelFile.path || !_embeddedEngine!.isReady) {
      await _embeddedEngine!.setModel(
        LlamaModel(ModelSource.path(modelFile.path)),
        params: ModelParams(
          contextSize: 2048,
          batchSize: 2048,
          microBatchSize: 2048,
          gpuLayers: 99,
          numberOfThreads: Platform.numberOfProcessors > 0 ? Platform.numberOfProcessors : 8,
          numberOfThreadsBatch: Platform.numberOfProcessors > 0 ? Platform.numberOfProcessors : 8,
        ),
      );
      _loadedEmbeddedModelPath = modelFile.path;
    }
  }

  /// Generates an embedding vector (Float32List) for [text].
  /// Returns null if embedding generation is disabled or fails.
  Future<Float32List?> embedText(String text) async {
    if (!isEnabled || text.trim().isEmpty) return null;

    final provider = config.embeddingProvider.toLowerCase();
    try {
      if (provider == 'embedded') {
        return await _embedEmbedded(text);
      } else if (provider == 'ollama') {
        return await _embedOllama(text);
      } else if (provider == 'openai' || provider == 'openai_compatible') {
        return await _embedOpenAi(text);
      }
    } catch (e) {
      stderr.writeln('[RAG Embedder] embedText failed: $e');
    }
    return null;
  }

  /// Batch embedding generation for multiple text chunks.
  Future<List<Float32List?>> embedBatch(
    List<String> texts, {
    void Function(int current, int total)? onProgress,
  }) async {
    if (!isEnabled || texts.isEmpty) {
      return List<Float32List?>.filled(texts.length, null);
    }

    final provider = config.embeddingProvider.toLowerCase();
    if (provider == 'embedded') {
      try {
        await _ensureEmbeddedEngine();
        if (_embeddedEngine != null && _embeddedEngine!.isReady) {
          final results = <Float32List?>[];
          for (int i = 0; i < texts.length; i++) {
            final t = texts[i];
            if (t.trim().isEmpty) {
              results.add(null);
            } else {
              final vec = await _embeddedEngine!.embed(t, normalize: true);
              final f32 = Float32List(vec.length);
              for (int j = 0; j < vec.length; j++) {
                f32[j] = vec[j];
              }
              results.add(f32);
            }
            onProgress?.call(i + 1, texts.length);
          }
          return results;
        }
      } catch (e) {
        stderr.writeln('[RAG Embedder] embedBatch failed: $e');
      }
    }

    final results = <Float32List?>[];
    for (int i = 0; i < texts.length; i++) {
      results.add(await embedText(texts[i]));
      onProgress?.call(i + 1, texts.length);
    }
    return results;
  }

  Future<Float32List?> _embedEmbedded(String text) async {
    await _ensureEmbeddedEngine();
    if (_embeddedEngine == null || !_embeddedEngine!.isReady) return null;

    final vec = await _embeddedEngine!.embed(text, normalize: true);
    final f32 = Float32List(vec.length);
    for (int i = 0; i < vec.length; i++) {
      f32[i] = vec[i];
    }
    return f32;
  }

  Future<Float32List?> _embedOllama(String text) async {
    final baseUrl = config.embeddingBaseUrl.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$baseUrl/api/embeddings');

    final payload = {
      'model': config.embeddingModel,
      'prompt': text,
    };

    final resp = await _client
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 20));

    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body);
      if (data is Map && data['embedding'] is List) {
        final list = (data['embedding'] as List).cast<num>();
        final f32 = Float32List(list.length);
        for (int i = 0; i < list.length; i++) {
          f32[i] = list[i].toDouble();
        }
        return f32;
      }
    }
    return null;
  }

  Future<Float32List?> _embedOpenAi(String text) async {
    final baseUrl = config.embeddingBaseUrl.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$baseUrl/v1/embeddings');

    final payload = {
      'model': config.embeddingModel,
      'input': text,
    };

    final headers = <String, String>{
      'Content-Type': 'application/json',
    };
    if (config.embeddingApiKey.isNotEmpty) {
      headers['Authorization'] = 'Bearer ${config.embeddingApiKey}';
    }

    final resp = await _client
        .post(
          uri,
          headers: headers,
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 20));

    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body);
      if (data is Map && data['data'] is List && (data['data'] as List).isNotEmpty) {
        final item = (data['data'] as List).first;
        if (item is Map && item['embedding'] is List) {
          final list = (item['embedding'] as List).cast<num>();
          final f32 = Float32List(list.length);
          for (int i = 0; i < list.length; i++) {
            f32[i] = list[i].toDouble();
          }
          return f32;
        }
      }
    }
    return null;
  }

  /// Calculates cosine similarity between vector [a] and vector [b].
  static double cosineSimilarity(Float32List a, Float32List b) {
    if (a.length != b.length || a.isEmpty) return 0.0;

    double dot = 0.0;
    double normA = 0.0;
    double normB = 0.0;

    for (int i = 0; i < a.length; i++) {
      final valA = a[i];
      final valB = b[i];
      dot += valA * valB;
      normA += valA * valA;
      normB += valB * valB;
    }

    if (normA == 0.0 || normB == 0.0) return 0.0;
    return dot / (math.sqrt(normA) * math.sqrt(normB));
  }

  /// Converts a `Float32List` into raw byte `Uint8List` for SQLite BLOB storage.
  static Uint8List vectorToBytes(Float32List vector) {
    return vector.buffer.asUint8List(vector.offsetInBytes, vector.lengthInBytes);
  }

  /// Converts SQLite BLOB `Uint8List` back to `Float32List`.
  static Float32List bytesToVector(List<int> bytes) {
    final u8 = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    return u8.buffer.asFloat32List(u8.offsetInBytes, u8.lengthInBytes ~/ 4);
  }

  void dispose() {
    _client.close();
  }
}
