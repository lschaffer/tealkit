import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'embedded_model.dart';

/// Result from the HuggingFace model-discovery search.
class HfDiscoveryResult {
  final String repoId;
  final String displayName;
  final int downloads;
  final int likes;
  final int? sizeBytes;
  final String? description;
  final List<HfGgufFile> ggufFiles;

  const HfDiscoveryResult({
    required this.repoId,
    required this.displayName,
    required this.downloads,
    required this.likes,
    this.sizeBytes,
    this.description,
    this.ggufFiles = const [],
  });
}

class HfGgufFile {
  final String filename;
  final int sizeBytes;
  final String downloadUrl;

  const HfGgufFile({required this.filename, required this.sizeBytes, required this.downloadUrl});

  /// Returns `sizeBytes` if known, otherwise estimates from the filename.
  /// GGUF filenames often encode parameter count (e.g. "7B", "27B") and
  /// quantization level (Q4_K_M, Q8_0, F16, etc.) which allows a rough estimate.
  int get effectiveSizeBytes {
    if (sizeBytes > 0) return sizeBytes;
    return _estimateSizeFromFilename(filename);
  }

  static int _estimateSizeFromFilename(String filename) {
    final lower = filename.toLowerCase();

    // Extract parameter count (e.g. 0.5b, 1b, 3b, 7b, 14b, 27b, 72b).
    double? params;
    final paramMatch = RegExp(r'[_\-.](\d+(?:\.\d+)?)b[_\-.]').firstMatch(lower);
    if (paramMatch != null) {
      params = double.tryParse(paramMatch.group(1)!);
    }
    if (params == null) return 0;

    // Bytes-per-parameter by quantization type.
    double bpp = 0.55; // default Q4_K_M
    if (lower.contains('f32')) {
      bpp = 4.0;
    } else if (lower.contains('f16') || lower.contains('fp16')) {
      bpp = 2.0;
    } else if (lower.contains('q8_0') || lower.contains('q8')) {
      bpp = 1.0;
    } else if (lower.contains('q6_k')) {
      bpp = 0.75;
    } else if (lower.contains('q5_k_m') || lower.contains('q5_1')) {
      bpp = 0.68;
    } else if (lower.contains('q5_k_s') || lower.contains('q5_0')) {
      bpp = 0.62;
    } else if (lower.contains('q4_k_m') || lower.contains('q4_1')) {
      bpp = 0.57;
    } else if (lower.contains('q4_k_s') || lower.contains('q4_0')) {
      bpp = 0.51;
    } else if (lower.contains('q3_k_m') || lower.contains('q3_k_l')) {
      bpp = 0.44;
    } else if (lower.contains('q3_k_s') || lower.contains('q3_k')) {
      bpp = 0.41;
    } else if (lower.contains('q2_k')) {
      bpp = 0.31;
    } else if (lower.contains('iq4')) {
      bpp = 0.53;
    } else if (lower.contains('iq3')) {
      bpp = 0.40;
    } else if (lower.contains('iq2')) {
      bpp = 0.30;
    }

    // Add ~5% overhead for model metadata/tensors.
    return (params * 1e9 * bpp * 1.05).round();
  }

  String get sizeLabel {
    final bytes = effectiveSizeBytes;
    if (bytes <= 0) return 'Unknown size';
    final estimated = sizeBytes <= 0; // estimated, not from API
    String label;
    if (bytes >= 1024 * 1024 * 1024) {
      label = '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    } else {
      label = '${(bytes / (1024 * 1024)).round()} MB';
    }
    return estimated ? '~$label' : label;
  }
}

/// Manages on-device GGUF model files: downloads, listing, deletion and custom model persistence.
class EmbeddedModelManager {
  EmbeddedModelManager._();
  static final EmbeddedModelManager instance = EmbeddedModelManager._();

  static const String _customModelsKey = 'embedded_llm_custom_models';

  // ── Directory ────────────────────────────────────────────────────────────────

  Future<Directory> getModelsDirectory() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/models');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  // ── File listing ─────────────────────────────────────────────────────────────

  Future<Set<String>> listDownloadedFilenames() async {
    final dir = await getModelsDirectory();
    if (!await dir.exists()) return {};
    final files = dir.listSync().whereType<File>();
    return files.map((f) => f.uri.pathSegments.last).toSet();
  }

  Future<String> fullPathForFilename(String filename) async {
    final dir = await getModelsDirectory();
    return '${dir.path}/$filename';
  }

  // ── Download ─────────────────────────────────────────────────────────────────

  /// Downloads a GGUF file from [url] to the models directory.
  ///
  /// Supports resume via HTTP Range header if the partial file exists.
  /// [onProgress] receives values 0.0–1.0. Call [cancelToken.cancel] to stop.
  Future<void> downloadModel({
    required String url,
    required String filename,
    void Function(double progress)? onProgress,
    DownloadCancelToken? cancelToken,
  }) async {
    final dir = await getModelsDirectory();
    final destFile = File('${dir.path}/$filename');
    final partFile = File('${dir.path}/$filename.part');

    int existingBytes = 0;
    if (await partFile.exists()) {
      existingBytes = await partFile.length();
    }

    final request = http.Request('GET', Uri.parse(url));
    if (existingBytes > 0) {
      request.headers['Range'] = 'bytes=$existingBytes-';
    }

    final client = http.Client();
    try {
      final response = await client.send(request);

      if (response.statusCode != 200 && response.statusCode != 206) {
        throw Exception('HTTP ${response.statusCode} downloading $url');
      }

      final totalBytes = (response.contentLength ?? 0) + existingBytes;
      int receivedBytes = existingBytes;

      final sink = partFile.openWrite(mode: FileMode.append);
      try {
        await for (final chunk in response.stream) {
          if (cancelToken?.isCancelled == true) {
            await sink.close();
            return;
          }
          sink.add(chunk);
          receivedBytes += chunk.length;
          if (totalBytes > 0) {
            onProgress?.call(receivedBytes / totalBytes);
          }
        }
      } finally {
        await sink.close();
      }

      if (cancelToken?.isCancelled == true) return;
      await partFile.rename(destFile.path);
      onProgress?.call(1.0);
    } finally {
      client.close();
    }
  }

  // ── Deletion ─────────────────────────────────────────────────────────────────

  Future<void> deleteModel(String filename) async {
    final dir = await getModelsDirectory();
    final file = File('${dir.path}/$filename');
    if (await file.exists()) await file.delete();
    final part = File('${dir.path}/$filename.part');
    if (await part.exists()) await part.delete();
  }

  Future<void> deleteAllModels() async {
    final dir = await getModelsDirectory();
    if (!await dir.exists()) return;
    for (final f in dir.listSync().whereType<File>()) {
      await f.delete();
    }
  }

  // ── Custom model persistence ─────────────────────────────────────────────────

  Future<List<EmbeddedGgufModel>> loadCustomModels() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_customModelsKey);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list.map((e) => EmbeddedGgufModel.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveCustomModels(List<EmbeddedGgufModel> models) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_customModelsKey, jsonEncode(models.map((m) => m.toJson()).toList()));
  }

  Future<void> addCustomModel(EmbeddedGgufModel model) async {
    final current = await loadCustomModels();
    current.removeWhere((m) => m.id == model.id);
    current.add(model);
    await saveCustomModels(current);
  }

  Future<void> removeCustomModel(String id) async {
    final current = await loadCustomModels();
    current.removeWhere((m) => m.id == id);
    await saveCustomModels(current);
  }

  // ── Per-model GPU layers ──────────────────────────────────────────────────

  static const String _gpuLayersPrefix = 'embedded_gpu_layers_';

  /// Returns the saved GPU-layers value for [filename], or [defaultValue] if
  /// none has been saved yet.
  Future<int> getGpuLayers(String filename, {int defaultValue = 0}) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('$_gpuLayersPrefix$filename') ?? defaultValue;
  }

  /// Persists the GPU-layers value for [filename].
  Future<void> saveGpuLayers(String filename, int gpuLayers) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('$_gpuLayersPrefix$filename', gpuLayers);
  }

  // ── HuggingFace discovery ─────────────────────────────────────────────────

  /// Searches HuggingFace for popular GGUF models.
  ///
  /// [query] filters by model name. [maxRamGb] skips models that need more RAM.
  Future<List<HfDiscoveryResult>> discoverPopularModels({String? query, int? maxRamGb, String sort = 'downloads', int limit = 20}) async {
    final queryParams = {
      'filter': 'gguf',
      'sort': sort,
      'limit': '$limit',
      'full': 'true',
      if (query != null && query.isNotEmpty) 'search': query,
    };

    final uri = Uri.https('huggingface.co', '/api/models', queryParams);
    final response = await http.get(uri, headers: {'Accept': 'application/json'});

    if (response.statusCode != 200) {
      throw Exception('HuggingFace API error: ${response.statusCode}');
    }

    final List<dynamic> data = jsonDecode(response.body) as List<dynamic>;
    final results = <HfDiscoveryResult>[];

    for (final item in data) {
      final map = item as Map<String, dynamic>;
      final repoId = map['id'] as String? ?? '';
      if (repoId.isEmpty) continue;

      final siblings = (map['siblings'] as List<dynamic>? ?? []);
      final ggufFiles = siblings
          .where((s) {
            final name = (s as Map<String, dynamic>)['rfilename'] as String? ?? '';
            return name.toLowerCase().endsWith('.gguf') && !name.toLowerCase().contains('mmproj');
          })
          .map((s) {
            final sMap = s as Map<String, dynamic>;
            final filename = sMap['rfilename'] as String;
            // HuggingFace stores LFS file sizes inside the 'lfs' sub-object.
            // The top-level 'size' field is the pointer file size (~130 B) —
            // always near zero for GGUF files. Use lfs.size first.
            final lfs = sMap['lfs'] as Map<String, dynamic>?;
            final sizeBytes = (lfs?['size'] as num?)?.toInt() ?? (sMap['size'] as num?)?.toInt() ?? 0;
            return HfGgufFile(
              filename: filename,
              sizeBytes: sizeBytes,
              downloadUrl: 'https://huggingface.co/$repoId/resolve/main/$filename',
            );
          })
          .toList();

      if (ggufFiles.isEmpty) continue;

      results.add(
        HfDiscoveryResult(
          repoId: repoId,
          displayName: repoId.split('/').last,
          downloads: (map['downloads'] as num?)?.toInt() ?? 0,
          likes: (map['likes'] as num?)?.toInt() ?? 0,
          description: map['description'] as String?,
          ggufFiles: ggufFiles,
        ),
      );
    }

    return results;
  }
}

/// Token used to cancel an in-progress download.
class DownloadCancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}
