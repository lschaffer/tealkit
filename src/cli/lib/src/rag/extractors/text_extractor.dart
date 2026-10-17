import 'dart:convert';
import 'dart:io';

/// Text extractor for plain text, markdown, CSV, JSON, YAML, and source code.
class TextExtractor {
  /// Reads a text file safely handling multi-encoding fallbacks.
  static String? extractFromFile(File file) {
    if (!file.existsSync()) return null;
    try {
      final bytes = file.readAsBytesSync();
      try {
        return utf8.decode(bytes);
      } on FormatException {
        try {
          return latin1.decode(bytes);
        } catch (_) {
          return utf8.decode(bytes, allowMalformed: true);
        }
      }
    } catch (_) {
      return null;
    }
  }
}
