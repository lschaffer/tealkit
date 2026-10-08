import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dart_mcp_core/dart_mcp_core.dart';
import 'package:path/path.dart' as p;

/// Represents an attachment staged in the CLI session.
class CliAttachment {
  final String id;
  final String name;
  final String path;
  final String mimeType;
  final int sizeBytes;
  final bool isImage;
  final Uint8List? bytes;
  final String? extractedText;

  const CliAttachment({
    required this.id,
    required this.name,
    required this.path,
    required this.mimeType,
    required this.sizeBytes,
    required this.isImage,
    this.bytes,
    this.extractedText,
  });

  String get sizeLabel {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  MessageAttachment toMessageAttachment() {
    return MessageAttachment(
      id: id,
      name: name,
      path: path,
      bytes: bytes,
      mimeType: mimeType,
      size: sizeBytes,
    );
  }
}

/// Helper for loading and preparing file attachments.
class CliAttachmentHelper {
  /// Loads a file from disk and parses text/image attributes.
  static Future<CliAttachment> fromFile(
    String inputPath, {
    required String workspaceDir,
  }) async {
    var cleanPath = inputPath.trim();
    if ((cleanPath.startsWith('"') && cleanPath.endsWith('"')) ||
        (cleanPath.startsWith("'") && cleanPath.endsWith("'"))) {
      cleanPath = cleanPath.substring(1, cleanPath.length - 1);
    }

    final resolvedPath = p.isAbsolute(cleanPath)
        ? cleanPath
        : p.normalize(p.join(workspaceDir, cleanPath));

    final file = File(resolvedPath);
    if (!file.existsSync()) {
      throw FileNotFoundException('File not found: "$cleanPath"');
    }

    final bytes = await file.readAsBytes();
    final name = p.basename(resolvedPath);
    final ext = p.extension(resolvedPath).toLowerCase();
    final mimeType = _detectMimeType(name, ext);
    final isImage = mimeType.startsWith('image/');

    String? extractedText;
    if (!isImage) {
      extractedText = _tryExtractText(bytes, ext);
    }

    return CliAttachment(
      id: 'att_${DateTime.now().millisecondsSinceEpoch}_${bytes.length}',
      name: name,
      path: resolvedPath,
      mimeType: mimeType,
      sizeBytes: bytes.length,
      isImage: isImage,
      bytes: bytes,
      extractedText: extractedText,
    );
  }

  /// Creates an attachment directly from bytes (e.g. from clipboard).
  static CliAttachment fromBytes({
    required Uint8List bytes,
    required String name,
    required String path,
    required String mimeType,
    String? textContent,
  }) {
    final isImage = mimeType.startsWith('image/');
    return CliAttachment(
      id: 'att_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      path: path,
      mimeType: mimeType,
      sizeBytes: bytes.length,
      isImage: isImage,
      bytes: bytes,
      extractedText: textContent ?? (!isImage ? _tryExtractText(bytes, p.extension(name)) : null),
    );
  }

  static String _detectMimeType(String name, String ext) {
    return switch (ext) {
      '.png' => 'image/png',
      '.jpg' || '.jpeg' => 'image/jpeg',
      '.webp' => 'image/webp',
      '.gif' => 'image/gif',
      '.pdf' => 'application/pdf',
      '.json' => 'application/json',
      '.yaml' || '.yml' => 'text/yaml',
      '.dart' => 'text/x-dart',
      '.md' => 'text/markdown',
      '.txt' => 'text/plain',
      '.html' || '.htm' => 'text/html',
      '.csv' => 'text/csv',
      '.xml' => 'application/xml',
      '.js' || '.ts' => 'text/javascript',
      '.py' => 'text/x-python',
      _ => 'application/octet-stream',
    };
  }

  static String? _tryExtractText(Uint8List bytes, String ext) {
    if (ext == '.pdf') {
      // Basic text extraction or notice if raw PDF
      try {
        final raw = latin1.decode(bytes);
        final matches = RegExp(r'\(([^)]+)\)\s*Tj').allMatches(raw);
        if (matches.isNotEmpty) {
          final buf = StringBuffer();
          for (final m in matches) {
            buf.write(m.group(1));
            buf.write(' ');
          }
          final extracted = buf.toString().trim();
          if (extracted.isNotEmpty) return extracted;
        }
      } catch (_) {}
      return '[Binary PDF document: ${bytes.length} bytes]';
    }

    try {
      return utf8.decode(bytes);
    } catch (_) {
      try {
        return latin1.decode(bytes);
      } catch (_) {
        return null;
      }
    }
  }
}

class FileNotFoundException implements Exception {
  final String message;
  FileNotFoundException(this.message);
  @override
  String toString() => message;
}
