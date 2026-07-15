import 'dart:io';
import 'package:flutter/services.dart';

/// A file entry returned by the SAF (Storage Access Framework) method channel.
class SafFile {
  final String uri;
  final String name;
  final int size;
  final int lastModified;
  final String mimeType;

  const SafFile({required this.uri, required this.name, required this.size, required this.lastModified, required this.mimeType});

  factory SafFile.fromMap(Map<String, dynamic> m) => SafFile(
    uri: m['uri'] as String? ?? '',
    name: m['name'] as String? ?? '',
    size: (m['size'] as num?)?.toInt() ?? 0,
    lastModified: (m['lastModified'] as num?)?.toInt() ?? 0,
    mimeType: m['mimeType'] as String? ?? '',
  );

  String get extension => name.contains('.') ? name.substring(name.lastIndexOf('.') + 1).toLowerCase() : '';
}

/// Dart bridge to the Android SAF (Storage Access Framework) Kotlin method channel.
///
/// All methods are no-ops / return null on non-Android platforms.
class SafBridge {
  SafBridge._();

  static const _channel = MethodChannel('at.ls.gr.tealkit/saf');

  /// Returns true if [path] is an Android SAF content URI.
  static bool isSafUri(String path) => path.startsWith('content://');

  /// Recursively lists files under a SAF tree URI.
  ///
  /// [extensions] — list of lowercase file extensions to include (e.g. ['pdf', 'md']).
  ///               Pass an empty list to include all files.
  /// [maxFiles]   — hard limit on the number of files returned.
  static Future<List<SafFile>> listFiles(String contentUri, {List<String> extensions = const [], int maxFiles = 100}) async {
    if (!Platform.isAndroid) return [];
    try {
      final raw = await _channel.invokeListMethod<Object?>('listFiles', {
        'uri': contentUri,
        'extensions': extensions,
        'maxFiles': maxFiles,
      });
      if (raw == null) return [];
      return raw.whereType<Map>().map((m) => SafFile.fromMap(Map<String, dynamic>.from(m))).toList();
    } on PlatformException catch (e) {
      // Rethrow with a clear message so the caller can surface it to the user.
      throw Exception('SAF listFiles failed for $contentUri: ${e.message}');
    }
  }

  /// Reads the raw bytes of a single file identified by its SAF document URI.
  static Future<Uint8List?> readFile(String contentUri) async {
    if (!Platform.isAndroid) return null;
    try {
      final result = await _channel.invokeMethod<Uint8List>('readFile', {'uri': contentUri});
      return result;
    } on PlatformException catch (e) {
      throw Exception('SAF readFile failed for $contentUri: ${e.message}');
    }
  }

  /// Returns the display name of a SAF tree URI (e.g. "Documents", "Download").
  /// Returns null if the name cannot be determined.
  static Future<String?> displayName(String contentUri) async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('displayName', {'uri': contentUri});
    } catch (_) {
      return null;
    }
  }

  /// Extracts a human-readable folder label from a SAF content URI without
  /// a native call. Useful for display in the UI when the channel is not yet
  /// initialized or for a quick inline label.
  ///
  /// Examples:
  ///   content://.../tree/primary:Documents  →  "Documents"
  ///   content://.../tree/primary:Download   →  "Download"
  ///   content://.../tree/primary:           →  "Internal Storage"
  static String labelFromUri(String uri) {
    if (!isSafUri(uri)) {
      // Real path — return the last segment
      return uri.split('/').where((s) => s.isNotEmpty).lastOrNull ?? uri;
    }
    try {
      final decoded = Uri.decodeFull(uri);
      final treeMatch = RegExp(r'/tree/[^:]+:(.*)$').firstMatch(decoded);
      if (treeMatch != null) {
        final rel = treeMatch.group(1) ?? '';
        if (rel.isEmpty) return 'Internal Storage';
        return rel.split('/').where((s) => s.isNotEmpty).lastOrNull ?? rel;
      }
    } catch (_) {}
    return uri;
  }

  /// Requests a persistable URI permission for a SAF tree URI so the app can
  /// access the folder across restarts without the picker being re-opened.
  ///
  /// Must be called immediately after [FilePicker.getDirectoryPath] returns a
  /// `content://` URI on Android.  No-op on other platforms.
  static Future<void> takePersistablePermission(String contentUri) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('takePersistablePermission', {'uri': contentUri});
    } on PlatformException catch (e) {
      // Not fatal — log and continue.
      throw Exception('SAF takePersistablePermission failed for $contentUri: ${e.message}');
    }
  }

  /// Opens the Android system folder picker (ACTION_OPEN_DOCUMENT_TREE) and
  /// returns a persistable `content://` tree URI, or `null` if cancelled.
  ///
  /// [initialUri] — optional SAF document URI to pre-navigate the picker
  /// (e.g. `content://com.android.externalstorage.documents/document/primary%3ADocuments`).
  /// The user still confirms the selection; this only sets the starting folder.
  ///
  /// Also takes the persistable permission automatically so the app can access
  /// the folder across restarts.  Returns `null` on non-Android platforms.
  static Future<String?> openDocumentTree({String? initialUri}) async {
    if (!Platform.isAndroid) return null;
    try {
      final args = <String, dynamic>{};
      if (initialUri != null) args['initialUri'] = initialUri;
      final uri = await _channel.invokeMethod<String>('openDocumentTree', args.isEmpty ? null : args);
      return uri;
    } on PlatformException catch (e) {
      throw Exception('SAF openDocumentTree failed: ${e.message}');
    }
  }

  /// Opens a SAF document URI with the system's default viewer (ACTION_VIEW).
  /// Returns `null` on non-Android platforms.
  static Future<void> openFile(String contentUri) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('openFile', {'uri': contentUri});
    } on PlatformException catch (e) {
      throw Exception('SAF openFile failed for $contentUri: ${e.message}');
    }
  }

  /// Extracts a human-readable filename from a SAF document URI or a regular path.
  ///
  /// Examples:
  ///   content://.../document/primary:Documents/report.pdf  →  "report.pdf"
  ///   /storage/emulated/0/Documents/report.pdf             →  "report.pdf"
  static String fileNameFromUri(String uri) {
    if (isSafUri(uri)) {
      try {
        final decoded = Uri.decodeFull(uri);
        final last = decoded.split('/').where((s) => s.isNotEmpty).last;
        return last;
      } catch (_) {}
    }
    return uri.split('/').last.split('\\').last;
  }
}
