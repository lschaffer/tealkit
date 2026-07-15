// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:logging/logging.dart';

import 'app_preferences_service.dart';
import 'email_delivery_service.dart';

/// Saves generated task output files to a local directory and
/// handles automatic cleanup of files older than [outputRetentionDays].
class TaskOutputFileService {
  static final log = Logger('TaskOutputFileService');
  static const _subDir = 'task_outputs';

  // ─────────────────────────────────────────────────────────────
  // Directory
  // ─────────────────────────────────────────────────────────────

  /// Returns (and creates if needed) the output directory
  /// `<app-documents>/task_outputs/`.
  static Future<Directory> getOutputDirectory() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}$_subDir');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  // ─────────────────────────────────────────────────────────────
  // Save files
  // ─────────────────────────────────────────────────────────────

  /// Saves [attachments] to a `{taskSlug}_{timestamp}` sub-folder under the
  /// global default output path (if configured) or the internal
  /// `<app-documents>/task_outputs/` fallback directory.
  static Future<List<String>> saveFiles(List<EmailAttachmentPayload> attachments, String taskName) async {
    if (attachments.isEmpty) return const [];

    // Base dir: global default → app documents/task_outputs
    final Directory base;
    final globalDefault = AppPreferencesService.instance.defaultOutputPath.trim();
    if (globalDefault.isNotEmpty) {
      base = Directory(globalDefault);
    } else {
      base = await getOutputDirectory();
    }
    if (!await base.exists()) await base.create(recursive: true);

    // Sub-folder: {slug}_{YYYYMMDD_HHmmss}
    final now = DateTime.now();
    final stamp =
        '${now.year.toString().padLeft(4, '0')}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}'
        '_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
    final slug = _slugify(taskName);
    final folderName = slug.isNotEmpty ? '${slug}_$stamp' : stamp;
    final runDir = Directory('${base.path}${Platform.pathSeparator}$folderName');
    await runDir.create(recursive: true);

    final paths = <String>[];
    for (final att in attachments) {
      final file = File('${runDir.path}${Platform.pathSeparator}${att.fileName}');
      await file.writeAsBytes(att.bytes);
      paths.add(file.path);
      log.info('[TaskOutputFiles] Saved "${att.fileName}" (${att.bytes.length} bytes) → ${file.path}');
    }
    return paths;
  }

  static String _slugify(String name) => name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');

  // ─────────────────────────────────────────────────────────────
  // Cleanup
  // ─────────────────────────────────────────────────────────────

  /// Deletes all output files (the entire run sub-folder) whose
  /// creation time is older than [outputRetentionDays] days.
  /// Called at app startup and after task runs.
  static Future<void> cleanupOldFiles({String? additionalDirectoryPath}) async {
    try {
      final prefs = AppPreferencesService.instance;
      final retentionDays = prefs.outputRetentionDays;

      final cutoff = DateTime.now().subtract(Duration(days: retentionDays));

      final dirsToClean = <Directory>{await getOutputDirectory()};

      final globalDefault = prefs.defaultOutputPath.trim();
      if (globalDefault.isNotEmpty) {
        dirsToClean.add(Directory(globalDefault));
      }

      final additional = additionalDirectoryPath?.trim() ?? '';
      if (additional.isNotEmpty) {
        dirsToClean.add(Directory(additional));
      }

      int deleted = 0;
      for (final dir in dirsToClean) {
        deleted += await _cleanupDirectory(dir, cutoff);
      }

      if (deleted > 0) {
        log.info('[TaskOutputFiles] Cleanup: removed $deleted old item(s) (retention=$retentionDays days)');
      }
    } catch (e) {
      log.warning('[TaskOutputFiles] Cleanup error: $e');
    }
  }

  static Future<int> _cleanupDirectory(Directory dir, DateTime cutoff) async {
    if (!await dir.exists()) return 0;

    var deleted = 0;
    await for (final entry in dir.list()) {
      if (entry is Directory) {
        final stat = await entry.stat();
        if (stat.modified.isBefore(cutoff)) {
          await entry.delete(recursive: true);
          deleted++;
        }
      } else if (entry is File) {
        final stat = await entry.stat();
        if (stat.modified.isBefore(cutoff)) {
          await entry.delete();
          deleted++;
        }
      }
    }
    return deleted;
  }
}
