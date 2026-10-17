import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:pdfium_dart/pdfium_dart.dart';

/// PDF text extractor supporting PDFium FFI (using bundled pdfium.dll) with
/// pure Dart stream decompression fallback.
class PdfExtractor {
  static PDFium? _pdfium;
  static bool _pdfiumInitialized = false;

  /// Tries to initialize PDFium from the executable directory, current directory, or PATH.
  static PDFium? _getOrInitPdfium() {
    if (_pdfiumInitialized) return _pdfium;

    // Search candidate locations for pdfium.dll
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = [
      p.join(exeDir, 'pdfium.dll'),
      p.join(Directory.current.path, 'pdfium.dll'),
      p.join(Directory.current.path, 'cli', 'pdfium.dll'),
      'pdfium.dll',
    ];

    for (final candidate in candidates) {
      if (File(candidate).existsSync()) {
        try {
          final inst = getPdfium(modulePath: candidate);
          inst.FPDF_InitLibrary();
          _pdfium = inst;
          _pdfiumInitialized = true;
          return _pdfium;
        } catch (_) {}
      }
    }

    try {
      final inst = getPdfium();
      inst.FPDF_InitLibrary();
      _pdfium = inst;
      _pdfiumInitialized = true;
      return _pdfium;
    } catch (_) {
      _pdfiumInitialized = true;
      return null;
    }
  }

  /// Extracts text from a PDF file using PDFium (with fallback to pure Dart stream parsing).
  static String? extractFromFile(File file) {
    if (!file.existsSync()) return null;

    final pdfium = _getOrInitPdfium();
    if (pdfium != null) {
      final text = _extractWithPdfium(pdfium, file.path);
      if (text != null && text.trim().isNotEmpty) {
        return text;
      }
    }

    // Fallback: pure Dart stream extractor
    return _extractWithPureDart(file);
  }

  /// Extracts text using the PDFium C API.
  static String? _extractWithPdfium(PDFium pdfium, String filePath) {
    Pointer<Utf8>? pathPtr;
    FPDF_DOCUMENT? doc;

    try {
      pathPtr = filePath.toNativeUtf8();
      doc = pdfium.FPDF_LoadDocument(pathPtr.cast(), nullptr);
      if (doc == nullptr) return null;

      final pageCount = pdfium.FPDF_GetPageCount(doc);
      if (pageCount <= 0) return null;

      final buffer = StringBuffer();

      for (int i = 0; i < pageCount; i++) {
        final page = pdfium.FPDF_LoadPage(doc, i);
        if (page == nullptr) continue;

        try {
          final textPage = pdfium.FPDFText_LoadPage(page);
          if (textPage == nullptr) continue;

          try {
            final charCount = pdfium.FPDFText_CountChars(textPage);
            if (charCount > 0) {
              // Allocate UTF-16 buffer (charCount + 1 shorts)
              final textBuffer = calloc<UnsignedShort>(charCount + 1);
              try {
                final extracted = pdfium.FPDFText_GetText(
                  textPage,
                  0,
                  charCount,
                  textBuffer,
                );
                if (extracted > 0) {
                  final codeUnits = textBuffer.cast<Uint16>().asTypedList(extracted);
                  // Remove null terminator if present
                  final len = (codeUnits.isNotEmpty && codeUnits.last == 0)
                      ? codeUnits.length - 1
                      : codeUnits.length;
                  final pageStr = String.fromCharCodes(codeUnits.sublist(0, len));
                  if (pageStr.trim().isNotEmpty) {
                    buffer.writeln(pageStr.trim());
                  }
                }
              } finally {
                calloc.free(textBuffer);
              }
            }
          } finally {
            pdfium.FPDFText_ClosePage(textPage);
          }
        } finally {
          pdfium.FPDF_ClosePage(page);
        }
      }

      final res = buffer.toString().trim();
      return res.isNotEmpty ? res : null;
    } catch (_) {
      return null;
    } finally {
      if (doc != null && doc != nullptr) {
        pdfium.FPDF_CloseDocument(doc);
      }
      if (pathPtr != null) {
        calloc.free(pathPtr);
      }
    }
  }

  /// Pure Dart fallback parser extracting text from uncompressed or FlateDecode streams.
  static String? _extractWithPureDart(File file) {
    try {
      final bytes = file.readAsBytesSync();
      final content = String.fromCharCodes(bytes);
      final buffer = StringBuffer();

      // Look for stream ... endstream blocks
      final streamRegex = RegExp(r'stream[\r\n]+(.*?)[\r\n]+endstream', dotAll: true);
      for (final match in streamRegex.allMatches(content)) {
        final rawStream = match.group(1);
        if (rawStream == null) continue;

        String streamText = rawStream;
        // Try decompressing if flate encoded
        try {
          final rawBytes = rawStream.codeUnits;
          final decompressed = zlib.decode(rawBytes);
          streamText = String.fromCharCodes(decompressed);
        } catch (_) {}

        // Extract strings between ( ... ) Tj or [( ... )] TJ
        final textRegex = RegExp(r'\((.*?)\)\s*Tj', dotAll: true);
        for (final tm in textRegex.allMatches(streamText)) {
          final t = tm.group(1);
          if (t != null && t.trim().isNotEmpty) {
            buffer.write('${t.trim()} ');
          }
        }
      }

      final res = buffer.toString().trim();
      return res.isNotEmpty ? res : null;
    } catch (_) {
      return null;
    }
  }
}
