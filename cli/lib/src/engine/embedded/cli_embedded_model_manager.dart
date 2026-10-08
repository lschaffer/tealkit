import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;

/// Token to cancel an active file download.
class DownloadCancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

/// Manages local storage and downloading of GGUF models for TealKit CLI.
class CliEmbeddedModelManager {
  CliEmbeddedModelManager._();
  static final CliEmbeddedModelManager instance = CliEmbeddedModelManager._();

  /// Directory where models are kept: ~/.tealkit/models/
  Future<Directory> getModelsDirectory() async {
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        Directory.current.path;
    final dir = Directory('$home/.tealkit/models');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Resolves the local file path for a model filename.
  Future<File> getModelFile(String filename) async {
    final dir = await getModelsDirectory();
    return File('${dir.path}/$filename');
  }

  /// Checks if a model exists locally.
  Future<bool> isModelDownloaded(String filename) async {
    final file = await getModelFile(filename);
    return file.existsSync();
  }

  /// Ensures the model is downloaded. If missing, it downloads it from HuggingFace
  /// or a direct URL with a terminal progress bar.
  Future<File> ensureModelDownloaded({
    required String modelFilename,
    String? repo,
    String? directUrl,
    void Function(double progress, String status)? onProgress,
    DownloadCancelToken? cancelToken,
  }) async {
    final file = await getModelFile(modelFilename);
    if (file.existsSync()) {
      return file;
    }

    String url;
    if (directUrl != null && directUrl.trim().isNotEmpty) {
      url = directUrl.trim();
    } else if (repo != null && repo.trim().isNotEmpty) {
      // Standard HuggingFace resolve URL
      url = 'https://huggingface.co/${repo.trim()}/resolve/main/${modelFilename.trim()}';
    } else {
      throw ArgumentError(
        'Cannot download model "$modelFilename" without a HuggingFace "repo" or direct "url" specified in llm.yaml.',
      );
    }

    final dir = await getModelsDirectory();
    final destFile = File('${dir.path}/$modelFilename');
    final partFile = File('${dir.path}/$modelFilename.part');

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

      // Handle redirect if needed (HuggingFace returns 302 to CDN)
      http.StreamedResponse finalResponse = response;
      if (response.isRedirect ||
          response.statusCode == 301 ||
          response.statusCode == 302 ||
          response.statusCode == 307 ||
          response.statusCode == 308) {
        final redirectUrl = response.headers['location'];
        if (redirectUrl != null) {
          final redirReq = http.Request('GET', Uri.parse(redirectUrl));
          if (existingBytes > 0) {
            redirReq.headers['Range'] = 'bytes=$existingBytes-';
          }
          finalResponse = await client.send(redirReq);
        }
      }

      if (finalResponse.statusCode != 200 && finalResponse.statusCode != 206) {
        throw Exception(
          'HTTP ${finalResponse.statusCode} downloading model from $url',
        );
      }

      final totalBytes = (finalResponse.contentLength ?? 0) + existingBytes;
      int receivedBytes = existingBytes;

      final sink = partFile.openWrite(mode: FileMode.append);
      try {
        await for (final chunk in finalResponse.stream) {
          if (cancelToken?.isCancelled == true) {
            await sink.close();
            throw Exception('Model download was cancelled.');
          }
          sink.add(chunk);
          receivedBytes += chunk.length;

          if (totalBytes > 0) {
            final progress = receivedBytes / totalBytes;
            final mbReceived = (receivedBytes / (1024 * 1024)).toStringAsFixed(1);
            final mbTotal = (totalBytes / (1024 * 1024)).toStringAsFixed(1);
            onProgress?.call(
              progress,
              '$mbReceived / $mbTotal MB (${(progress * 100).toStringAsFixed(1)}%)',
            );
          }
        }
      } finally {
        await sink.close();
      }

      if (cancelToken?.isCancelled == true) {
        throw Exception('Model download was cancelled.');
      }

      await partFile.rename(destFile.path);
      onProgress?.call(1.0, 'Download complete');
      return destFile;
    } finally {
      client.close();
    }
  }
}
