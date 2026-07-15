import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../utils/server_logger.dart';
import '../utils/server_paths.dart';

enum ServerModelDownloadStatus { queued, downloading, completed, failed, cancelled }

class ServerModelDownloadJob {
  final String jobId;
  final String url;
  final String filename;
  final String? displayName;
  final int? requestedSizeBytes;
  final DateTime createdAt;

  ServerModelDownloadStatus status;
  int downloadedBytes;
  int? totalBytes;
  String? error;
  DateTime updatedAt;
  DateTime? completedAt;

  ServerModelDownloadJob({
    required this.jobId,
    required this.url,
    required this.filename,
    required this.displayName,
    required this.requestedSizeBytes,
    required this.createdAt,
    required this.status,
    required this.downloadedBytes,
    required this.totalBytes,
    required this.updatedAt,
    this.completedAt,
    this.error,
  });

  Map<String, dynamic> toJson() {
    final total = totalBytes;
    final progress = (total != null && total > 0) ? (downloadedBytes / total).clamp(0.0, 1.0) : 0.0;
    return {
      'job_id': jobId,
      'url': url,
      'filename': filename,
      'display_name': displayName,
      'requested_size_bytes': requestedSizeBytes,
      'status': status.name,
      'downloaded_bytes': downloadedBytes,
      'total_bytes': total,
      'progress': progress,
      'error': error,
      'created_at': createdAt.toUtc().toIso8601String(),
      'updated_at': updatedAt.toUtc().toIso8601String(),
      'completed_at': completedAt?.toUtc().toIso8601String(),
    };
  }
}

class ServerModelFileInfo {
  final String filename;
  final int size;
  final DateTime modifiedAt;

  const ServerModelFileInfo({required this.filename, required this.size, required this.modifiedAt});

  Map<String, dynamic> toJson() => {'filename': filename, 'size': size, 'modified_at': modifiedAt.toUtc().toIso8601String()};
}

class ServerModelDownloadService {
  static final ServerModelDownloadService instance = ServerModelDownloadService._();
  ServerModelDownloadService._();

  static const _uuid = Uuid();

  final Map<String, ServerModelDownloadJob> _jobsById = <String, ServerModelDownloadJob>{};
  final Map<String, String> _activeJobByFilename = <String, String>{};
  final Map<String, bool> _cancelFlags = <String, bool>{};

  late final Directory _modelsDir;

  Future<void> init() async {
    _modelsDir = Directory(resolveServerModelsDir());
    if (!await _modelsDir.exists()) {
      await _modelsDir.create(recursive: true);
    }
  }

  Future<ServerModelDownloadJob> startDownload({
    required String url,
    required String filename,
    String? displayName,
    int? requestedSizeBytes,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      throw ArgumentError('Invalid download URL. Only http/https are allowed.');
    }

    final safeFilename = _sanitizeFilename(filename);
    if (!_isSupportedModelFile(safeFilename)) {
      throw ArgumentError('Unsupported file type. Allowed: .gguf, .zip');
    }

    final existingJobId = _activeJobByFilename[safeFilename];
    if (existingJobId != null) {
      final existing = _jobsById[existingJobId];
      if (existing != null && existing.status == ServerModelDownloadStatus.downloading) {
        return existing;
      }
    }

    final now = DateTime.now().toUtc();
    final job = ServerModelDownloadJob(
      jobId: _uuid.v4(),
      url: url,
      filename: safeFilename,
      displayName: displayName,
      requestedSizeBytes: requestedSizeBytes,
      createdAt: now,
      status: ServerModelDownloadStatus.queued,
      downloadedBytes: 0,
      totalBytes: null,
      updatedAt: now,
    );

    _jobsById[job.jobId] = job;
    _activeJobByFilename[safeFilename] = job.jobId;
    _cancelFlags[job.jobId] = false;

    unawaited(_runDownload(job));
    return job;
  }

  ServerModelDownloadJob? getJob(String jobId) => _jobsById[jobId];

  Future<bool> cancelDownload(String jobId) async {
    final job = _jobsById[jobId];
    if (job == null) return false;
    _cancelFlags[jobId] = true;
    if (job.status == ServerModelDownloadStatus.queued) {
      job.status = ServerModelDownloadStatus.cancelled;
      job.updatedAt = DateTime.now().toUtc();
      job.completedAt = job.updatedAt;
      _activeJobByFilename.remove(job.filename);
    }
    return true;
  }

  Future<List<ServerModelFileInfo>> listFiles() async {
    final result = <ServerModelFileInfo>[];
    if (!await _modelsDir.exists()) return result;

    await for (final entity in _modelsDir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name.startsWith('.')) continue;
      if (name.endsWith('.part')) continue;
      final stat = await entity.stat();
      result.add(ServerModelFileInfo(filename: name, size: stat.size, modifiedAt: stat.modified));
    }

    result.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return result;
  }

  Future<bool> deleteFile(String filename) async {
    final safeFilename = _sanitizeFilename(filename);
    final file = File(p.join(_modelsDir.path, safeFilename));
    final part = File('${file.path}.part');

    var deletedAny = false;
    if (await file.exists()) {
      await file.delete();
      deletedAny = true;
    }
    if (await part.exists()) {
      await part.delete();
      deletedAny = true;
    }

    return deletedAny;
  }

  Future<void> _runDownload(ServerModelDownloadJob job) async {
    final destination = File(p.join(_modelsDir.path, job.filename));
    final partial = File('${destination.path}.part');

    final client = HttpClient();
    IOSink? sink;

    try {
      job.status = ServerModelDownloadStatus.downloading;
      job.updatedAt = DateTime.now().toUtc();

      var existingBytes = 0;
      if (await partial.exists()) {
        existingBytes = await partial.length();
      }

      final req = await client.getUrl(Uri.parse(job.url));
      if (existingBytes > 0) {
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=$existingBytes-');
      }
      final response = await req.close();

      if (response.statusCode != HttpStatus.ok && response.statusCode != HttpStatus.partialContent) {
        throw Exception('HTTP ${response.statusCode} downloading ${job.url}');
      }

      if (existingBytes > 0 && response.statusCode == HttpStatus.ok) {
        existingBytes = 0;
        if (await partial.exists()) {
          await partial.delete();
        }
      }

      final contentLength = response.contentLength;
      if (contentLength > 0) {
        job.totalBytes = existingBytes + contentLength;
      } else if (job.requestedSizeBytes != null && job.requestedSizeBytes! > 0) {
        job.totalBytes = job.requestedSizeBytes;
      }

      sink = partial.openWrite(mode: FileMode.append);
      job.downloadedBytes = existingBytes;
      job.updatedAt = DateTime.now().toUtc();

      await for (final chunk in response) {
        if (_cancelFlags[job.jobId] == true) {
          job.status = ServerModelDownloadStatus.cancelled;
          job.updatedAt = DateTime.now().toUtc();
          job.completedAt = job.updatedAt;
          return;
        }
        sink.add(chunk);
        job.downloadedBytes += chunk.length;
        job.updatedAt = DateTime.now().toUtc();
      }

      await sink.flush();
      await sink.close();
      sink = null;

      if (_cancelFlags[job.jobId] == true) {
        job.status = ServerModelDownloadStatus.cancelled;
        job.updatedAt = DateTime.now().toUtc();
        job.completedAt = job.updatedAt;
        return;
      }

      if (await destination.exists()) {
        await destination.delete();
      }
      await partial.rename(destination.path);

      job.status = ServerModelDownloadStatus.completed;
      job.completedAt = DateTime.now().toUtc();
      job.updatedAt = job.completedAt!;
      if (job.totalBytes == null || job.totalBytes == 0) {
        job.totalBytes = job.downloadedBytes;
      }
      log.info('[Models] Download completed: ${job.filename}');
    } catch (e, st) {
      if (job.status != ServerModelDownloadStatus.cancelled) {
        job.status = ServerModelDownloadStatus.failed;
        job.error = e.toString();
        job.updatedAt = DateTime.now().toUtc();
        job.completedAt = job.updatedAt;
        log.error('[Models] Download failed for ${job.filename}: $e', e, st);
      }
    } finally {
      _activeJobByFilename.remove(job.filename);
      _cancelFlags.remove(job.jobId);
      try {
        await sink?.flush();
      } catch (_) {}
      try {
        await sink?.close();
      } catch (_) {}
      client.close(force: true);
    }
  }

  String _sanitizeFilename(String filename) {
    final trimmed = filename.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Filename is required.');
    }
    final base = p.basename(trimmed);
    if (base == '.' || base == '..') {
      throw ArgumentError('Invalid filename.');
    }
    if (base.length > 255) {
      throw ArgumentError('Filename is too long.');
    }
    if (base.contains('/') || base.contains('\\')) {
      throw ArgumentError('Filename must not contain path separators.');
    }
    return base;
  }

  bool _isSupportedModelFile(String filename) {
    final lower = filename.toLowerCase();
    return lower.endsWith('.gguf') || lower.endsWith('.zip');
  }
}
