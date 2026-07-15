import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';

/// Utility to request storage permissions on Android, iOS, and macOS.
///
/// - **Android 11+** (API 30+): No special permission is required. File access
///   is handled through the Storage Access Framework (SAF) via `file_picker`.
///   Users select folders/files via the system picker; no broad storage grant needed.
/// - **Android 9–10** (API 28–29): `READ_EXTERNAL_STORAGE` is requested for
///   direct path access on older devices.
/// - **iOS**: No runtime permission needed; sandboxed file access via Files app.
/// - **macOS/Windows/Linux**: No permission needed.
class StoragePermission {
  StoragePermission._();

  /// Returns `true` if the app has sufficient storage read access.
  ///
  /// On Android 11+, always returns `true` — SAF-based access via the system
  /// file picker does not require a runtime permission grant.
  static Future<bool> hasAccess() async {
    if (!Platform.isAndroid) return true;

    final info = await DeviceInfoPlugin().androidInfo;
    if (info.version.sdkInt >= 30) {
      // Android 11+: SAF (file_picker) handles access — no broad permission needed.
      return true;
    } else {
      return await Permission.storage.isGranted;
    }
  }

  /// Request storage permission. Returns `true` if granted.
  ///
  /// On Android 11+, returns `true` immediately — no permission dialog is shown
  /// because file access uses SAF (system file picker). On older Android versions,
  /// requests READ_EXTERNAL_STORAGE.
  static Future<bool> request(BuildContext context) async {
    if (!Platform.isAndroid) return true;

    final info = await DeviceInfoPlugin().androidInfo;
    if (info.version.sdkInt >= 30) {
      // Android 11+: SAF-based access requires no runtime permission.
      return true;
    } else {
      // Android 9–10: request READ_EXTERNAL_STORAGE
      final result = await Permission.storage.request();
      return result.isGranted;
    }
  }

  /// Common external storage directories.
  /// Returns a list of (label, path) pairs that exist on the device.
  ///
  /// - **Android**: well-known folders under `/storage/emulated/0`.
  /// - **iOS/macOS**: app Documents directory + Downloads (if available).
  /// - **Windows/Linux**: returns empty (use file picker instead).
  static Future<List<(String, String)>> getCommonDirectories() async {
    if (Platform.isAndroid) {
      return _getAndroidDirectories();
    } else if (Platform.isIOS || Platform.isMacOS) {
      return _getAppleDirectories();
    }
    return [];
  }

  static Future<List<(String, String)>> _getAndroidDirectories() async {
    // On Android 11+ we use SAF — no direct path access needed.
    // Return well-known path labels for display purposes only;
    // actual indexing uses content:// URIs from file_picker.
    const base = '/storage/emulated/0';
    final dirs = <(String, String)>[];
    final candidates = [('Documents', '$base/Documents'), ('Downloads', '$base/Download')];
    for (final (label, path) in candidates) {
      dirs.add((label, path));
    }
    return dirs;
  }

  static Future<List<(String, String)>> _getAppleDirectories() async {
    final dirs = <(String, String)>[];

    try {
      // App's own Documents directory (always accessible)
      final appDocDir = await getApplicationDocumentsDirectory();
      if (await appDocDir.exists()) {
        dirs.add(('App Documents', appDocDir.path));
      }
    } catch (_) {}

    if (Platform.isMacOS) {
      try {
        // On macOS, user home directories are accessible
        final home = Platform.environment['HOME'] ?? '';
        if (home.isNotEmpty) {
          final candidates = [('Documents', '$home/Documents'), ('Downloads', '$home/Downloads'), ('Desktop', '$home/Desktop')];
          for (final (label, path) in candidates) {
            if (await Directory(path).exists()) {
              dirs.add((label, path));
            }
          }
        }
      } catch (_) {}
    }

    if (Platform.isIOS) {
      try {
        // On iOS, check for iCloud/On My iPhone directories accessible to the app
        final appDocDir = await getApplicationDocumentsDirectory();
        // The parent of the app documents dir can sometimes contain shared containers
        final parentPath = appDocDir.parent.path;
        final onMyIphone = Directory('$parentPath/Documents');
        if (await onMyIphone.exists() && onMyIphone.path != appDocDir.path) {
          dirs.add(('On My iPhone', onMyIphone.path));
        }
      } catch (_) {}
    }

    return dirs;
  }
}
