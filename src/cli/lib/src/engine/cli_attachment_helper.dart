import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dart_mcp_core/dart_mcp_core.dart';
import 'package:image/image.dart' as img;
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
  /// Recommended max dimension for visual LLM input (1280px).
  static const int maxImageDimension = 1280;

  /// Always enabled image shrinking for CLI chat and coding modes.
  /// Downscales images exceeding [maxDimension] keeping aspect ratio.
  static ({Uint8List bytes, String mimeType}) shrinkImage(
    Uint8List originalBytes,
    String mimeType, {
    int maxDimension = maxImageDimension,
  }) {
    if (originalBytes.isEmpty) {
      return (bytes: originalBytes, mimeType: mimeType);
    }
    try {
      final decoded = img.decodeImage(originalBytes);
      if (decoded == null) {
        return (bytes: originalBytes, mimeType: mimeType);
      }
      final width = decoded.width;
      final height = decoded.height;
      if (width <= maxDimension && height <= maxDimension) {
        return (bytes: originalBytes, mimeType: mimeType);
      }

      img.Image resized;
      if (width >= height) {
        resized = img.copyResize(decoded, width: maxDimension);
      } else {
        resized = img.copyResize(decoded, height: maxDimension);
      }

      if (mimeType == 'image/png' && decoded.hasAlpha) {
        final encoded = img.encodePng(resized);
        return (bytes: Uint8List.fromList(encoded), mimeType: 'image/png');
      } else {
        final encoded = img.encodeJpg(resized, quality: 85);
        return (bytes: Uint8List.fromList(encoded), mimeType: 'image/jpeg');
      }
    } catch (_) {
      return (bytes: originalBytes, mimeType: mimeType);
    }
  }

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
    final rawMime = _detectMimeType(name, ext);
    final isImage = rawMime.startsWith('image/');

    String? extractedText;
    Uint8List finalBytes = bytes;
    String finalMimeType = rawMime;

    if (isImage) {
      final shrunk = shrinkImage(bytes, rawMime);
      finalBytes = shrunk.bytes;
      finalMimeType = shrunk.mimeType;
    } else {
      extractedText = _tryExtractText(bytes, ext);
    }

    return CliAttachment(
      id: 'att_${DateTime.now().millisecondsSinceEpoch}_${finalBytes.length}',
      name: name,
      path: resolvedPath,
      mimeType: finalMimeType,
      sizeBytes: finalBytes.length,
      isImage: isImage,
      bytes: finalBytes,
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
    Uint8List finalBytes = bytes;
    String finalMimeType = mimeType;

    if (isImage) {
      final shrunk = shrinkImage(bytes, mimeType);
      finalBytes = shrunk.bytes;
      finalMimeType = shrunk.mimeType;
    }

    return CliAttachment(
      id: 'att_${DateTime.now().millisecondsSinceEpoch}_${finalBytes.length}',
      name: name,
      path: path,
      mimeType: finalMimeType,
      sizeBytes: finalBytes.length,
      isImage: isImage,
      bytes: finalBytes,
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
