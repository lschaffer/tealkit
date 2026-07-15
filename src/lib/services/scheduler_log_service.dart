import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';

enum SchedulerEventType { scheduled, fired, started, completed, failed, skipped, alarm }

class SchedulerLogEntry {
  final DateTime timestamp;
  final String taskId;
  final String taskName;
  final SchedulerEventType event;
  final String? detail;

  const SchedulerLogEntry({required this.timestamp, required this.taskId, required this.taskName, required this.event, this.detail});

  String get eventLabel {
    switch (event) {
      case SchedulerEventType.scheduled:
        return 'Scheduled';
      case SchedulerEventType.fired:
        return 'Fired';
      case SchedulerEventType.started:
        return 'Started';
      case SchedulerEventType.completed:
        return 'Completed';
      case SchedulerEventType.failed:
        return 'Failed';
      case SchedulerEventType.skipped:
        return 'Skipped';
      case SchedulerEventType.alarm:
        return 'Alarm';
    }
  }

  Map<String, dynamic> toJson() => {
    'ts': timestamp.toIso8601String(),
    'taskId': taskId,
    'taskName': taskName,
    'event': event.name,
    if (detail != null) 'detail': detail,
  };

  factory SchedulerLogEntry.fromJson(Map<String, dynamic> j) => SchedulerLogEntry(
    timestamp: DateTime.parse(j['ts'] as String),
    taskId: j['taskId'] as String,
    taskName: j['taskName'] as String,
    event: SchedulerEventType.values.firstWhere((e) => e.name == j['event'], orElse: () => SchedulerEventType.fired),
    detail: j['detail'] as String?,
  );
}

/// Persistent append-only scheduler log stored in SharedPreferences.
/// Safe to call from background isolates.
class SchedulerLogService {
  static const String _prefKey = 'scheduler_log_v1';
  static const Duration _retentionWindow = Duration(hours: 48);

  static final SchedulerLogService _instance = SchedulerLogService._();
  factory SchedulerLogService() => _instance;
  SchedulerLogService._();

  Future<void> addEntry({required String taskId, required String taskName, required SchedulerEventType event, String? detail}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cutoff = DateTime.now().subtract(_retentionWindow);
      final existing = _load(prefs).where((e) => e.timestamp.isAfter(cutoff)).toList();
      final entry = SchedulerLogEntry(timestamp: DateTime.now(), taskId: taskId, taskName: taskName, event: event, detail: detail);
      final updated = [entry, ...existing];
      await prefs.setString(_prefKey, jsonEncode(updated.map((e) => e.toJson()).toList()));
    } catch (e) {
      log.warning('[SchedulerLog] write failed: $e');
    }
  }

  Future<List<SchedulerLogEntry>> readAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Reload from native storage to pick up writes from background isolates
      // (Android AlarmManager callback, WorkManager). Without this the Dart
      // SharedPreferences instance returns its in-memory cache, which may not
      // include entries written in a separate Dart isolate.
      await prefs.reload();
      return _load(prefs);
    } catch (e) {
      log.warning('[SchedulerLog] read failed: $e');
      return const [];
    }
  }

  /// Returns only entries from the last 48 hours, newest first.
  Future<List<SchedulerLogEntry>> readRecent48h() async {
    final all = await readAll();
    final cutoff = DateTime.now().subtract(_retentionWindow);
    return all.where((e) => e.timestamp.isAfter(cutoff)).toList();
  }

  Future<List<SchedulerLogEntry>> readForTask(String taskId) async {
    final all = await readAll();
    return all.where((e) => e.taskId == taskId && e.event != SchedulerEventType.scheduled).toList();
  }

  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefKey);
    } catch (_) {}
  }

  List<SchedulerLogEntry> _load(SharedPreferences prefs) {
    final raw = prefs.getString(_prefKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list.whereType<Map<String, dynamic>>().map(SchedulerLogEntry.fromJson).toList();
    } catch (_) {
      return const [];
    }
  }
}
