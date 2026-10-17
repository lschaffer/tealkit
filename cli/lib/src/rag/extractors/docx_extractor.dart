import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';

/// Pure Dart DOCX text extractor (Office Open XML).
class DocxExtractor {
  /// Extracts text content from a `.docx` file.
  static String? extractFromFile(File file) {
    try {
      final bytes = file.readAsBytesSync();
      return extractFromBytes(bytes);
    } catch (_) {
      return null;
    }
  }

  /// Extracts text content from raw `.docx` bytes.
  static String? extractFromBytes(List<int> bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      for (final file in archive) {
        if (file.name == 'word/document.xml' && file.isFile) {
          final data = file.content as List<int>;
          final content = utf8.decode(data, allowMalformed: true);

          final paraRegex = RegExp(r'<w:p[^>]*>(.*?)</w:p>', dotAll: true);
          final textRegex = RegExp(r'<w:t[^>]*>(.*?)</w:t>', dotAll: true);
          final paragraphs = <String>[];

          for (final para in paraRegex.allMatches(content)) {
            final paraContent = para.group(1) ?? '';
            final texts = textRegex
                .allMatches(paraContent)
                .map((m) => m.group(1) ?? '')
                .join('');
            if (texts.trim().isNotEmpty) {
              paragraphs.add(texts.trim());
            }
          }
          return paragraphs.join('\n');
        }
      }
    } catch (_) {}
    return null;
  }
}
