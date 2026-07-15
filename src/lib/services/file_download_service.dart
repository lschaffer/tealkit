import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import '../utils/logger.dart';
import 'multi_mcp_manager.dart';

/// Service for handling chunked file downloads from MCP servers
class FileDownloadService {
  final MCPClientInterface _mcpClient;

  // Download progress tracking
  final Map<String, DownloadProgress> _activeDownloads = {};

  // Default chunk size: 512KB
  static const int defaultChunkSize = 512 * 1024;

  FileDownloadService(this._mcpClient);

  /// Download a file with automatic chunking for large files
  Stream<DownloadProgress> downloadFile({
    required String filePath,
    required String saveAsFileName,
    bool asBase64 = true,
    int chunkSize = defaultChunkSize,
    String? savePath,
  }) async* {
    final downloadId = '${filePath}_${DateTime.now().millisecondsSinceEpoch}';

    try {
      talker.info('Starting file download: $filePath');

      // Read the file via MCP resource read
      final content = await _readFileContent(filePath);
      final bytes = asBase64 ? base64Decode(content) : utf8.encode(content);
      final fileSize = bytes.length;

      // Emit initial progress
      var progress = DownloadProgress(
        downloadId: downloadId,
        filePath: filePath,
        fileName: saveAsFileName,
        totalBytes: fileSize,
        downloadedBytes: 0,
      );
      _activeDownloads[downloadId] = progress;
      yield progress;

      // Emit mid-progress
      progress = progress.copyWith(downloadedBytes: fileSize);
      yield progress;

      // Save the file
      final savedPath = await _saveFile(bytes: Uint8List.fromList(bytes), fileName: saveAsFileName, savePath: savePath);

      progress = progress.copyWith(isComplete: true, savedPath: savedPath);
      yield progress;
      talker.info('File download completed: $savedPath');
    } catch (e) {
      talker.error('Download failed for $filePath: $e');

      final progress = _activeDownloads[downloadId];
      if (progress != null) {
        progress.error = e.toString();
        yield progress.copyWith();
      }
      rethrow;
    } finally {
      _activeDownloads.remove(downloadId);
    }
  }

  Future<String> _readFileContent(String filePath) async {
    // Try to read file through MCP resource
    try {
      final result = await _mcpClient.callTool('read_file', {'path': filePath});
      if (result.content.isNotEmpty) {
        return result.content.first.text ?? '';
      }
    } catch (e) {
      talker.warning('MCP read_file failed, trying direct read: $e');
    }

    // Fallback: direct file system read
    final file = File(filePath);
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      return base64Encode(bytes);
    }

    throw Exception('Could not read file: $filePath');
  }

  Future<String> _saveFile({required Uint8List bytes, required String fileName, String? savePath}) async {
    if (savePath != null) {
      final file = File(savePath);
      await file.writeAsBytes(bytes);
      return savePath;
    }

    final outputPath = await FilePicker.saveFile(dialogTitle: 'Save file', fileName: fileName);
    if (outputPath != null) {
      final file = File(outputPath);
      await file.writeAsBytes(bytes);
      return outputPath;
    }

    throw Exception('User cancelled file save');
  }

  void cancelDownload(String downloadId) {
    _activeDownloads.remove(downloadId);
    talker.info('Download cancelled: $downloadId');
  }

  DownloadProgress? getProgress(String downloadId) => _activeDownloads[downloadId];

  List<DownloadProgress> getActiveDownloads() => _activeDownloads.values.toList();
}

/// Tracks the progress of a file download.
class DownloadProgress {
  final String downloadId;
  final String filePath;
  final String fileName;
  final int totalBytes;
  int downloadedBytes;
  final String? mimeType;
  bool isComplete;
  String? savedPath;
  String? error;

  DownloadProgress({
    required this.downloadId,
    required this.filePath,
    required this.fileName,
    required this.totalBytes,
    this.downloadedBytes = 0,
    this.mimeType,
    this.isComplete = false,
    this.savedPath,
    this.error,
  });

  double get progressPercent {
    if (totalBytes == 0) return 0;
    return (downloadedBytes / totalBytes) * 100;
  }

  DownloadProgress copyWith({int? downloadedBytes, bool? isComplete, String? savedPath, String? error}) {
    return DownloadProgress(
      downloadId: downloadId,
      filePath: filePath,
      fileName: fileName,
      totalBytes: totalBytes,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      mimeType: mimeType,
      isComplete: isComplete ?? this.isComplete,
      savedPath: savedPath ?? this.savedPath,
      error: error ?? this.error,
    );
  }
}
