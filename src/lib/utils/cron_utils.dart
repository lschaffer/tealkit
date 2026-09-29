/// Cron expression utilities shared by [SchedulerService] and [TaskRunnerService].
///
/// Supports common 5-part cron notation:
///   `M H * * *`       – daily at H:M
///   `*/N * * * *`     – every N minutes
///   `M */N * * *`     – every N hours at minute M
///   `M H * * DOW`     – specific day-of-week
///   `M H D * *`       – specific day-of-month
library;

/// Returns the next [DateTime] strictly after [from] (default: now) that
/// matches the 5-part [cron] expression.
DateTime nextCronFire(String cron, {DateTime? from}) {
  final now = from ?? DateTime.now();
  final parts = cron.trim().split(RegExp(r'\s+'));
  if (parts.length < 5) {
    // Fallback: 24 h from now
    return now.add(const Duration(hours: 24));
  }

  final minutePart = parts[0];
  final hourPart = parts[1];
  final domPart = parts[2]; // day-of-month
  // parts[3] = month (ignored)
  final dowPart = parts[4]; // day-of-week  0=Sun … 6=Sat

  // ── Every N minutes: `*/N * * * *` ──────────────────────────────────
  if (minutePart.startsWith('*/') && hourPart == '*' && domPart == '*' && dowPart == '*') {
    final n = int.tryParse(minutePart.substring(2)) ?? 1;
    final epochMins = now.millisecondsSinceEpoch ~/ 60000;
    final nextMins = (epochMins ~/ n + 1) * n;
    return DateTime.fromMillisecondsSinceEpoch(nextMins * 60000);
  }

  // ── Fixed minute + hour (daily or DOW/DOM variants) ──────────────────
  final minute = int.tryParse(minutePart);
  final hour = hourPart == '*' ? null : int.tryParse(hourPart);

  // Hourly: `M * * * *`
  if (hourPart == '*' && domPart == '*' && dowPart == '*' && minute != null) {
    var candidate = DateTime(now.year, now.month, now.day, now.hour, minute);
    if (!candidate.isAfter(now)) candidate = candidate.add(const Duration(hours: 1));
    return candidate;
  }

  // Every N hours: `M */N * * *`
  if (hourPart.startsWith('*/') && domPart == '*' && dowPart == '*' && minute != null) {
    final n = int.tryParse(hourPart.substring(2)) ?? 1;
    for (var i = 0; i < 48; i++) {
      final c = DateTime(now.year, now.month, now.day, now.hour + i, minute);
      if (c.isAfter(now) && (now.hour + i) % n == 0) return c;
    }
  }

  if (minute == null || hour == null) {
    return now.add(const Duration(hours: 24));
  }

  // ── DOW-specific: `M H * * D` ────────────────────────────────────────
  if (domPart == '*' && dowPart != '*' && !dowPart.contains('/')) {
    final targetDows = _parseDowSet(dowPart);
    if (targetDows.isNotEmpty) {
      final baseDate = DateTime(now.year, now.month, now.day, hour, minute);
      for (var d = 0; d < 14; d++) {
        final c = baseDate.add(Duration(days: d));
        if (c.isAfter(now) && targetDows.contains(c.weekday % 7)) return c;
      }
    }
  }

  // ── DOM-specific: `M H D * *` ────────────────────────────────────────
  if (domPart != '*' && dowPart == '*') {
    final targetDom = int.tryParse(domPart);
    if (targetDom != null) {
      for (var m = 0; m < 13; m++) {
        final month = now.month + m;
        final year = now.year + (month - 1) ~/ 12;
        final c = DateTime(year, ((month - 1) % 12) + 1, targetDom, hour, minute);
        if (c.isAfter(now)) return c;
      }
    }
  }

  // ── Daily: `M H * * *` ───────────────────────────────────────────────
  var candidate = DateTime(now.year, now.month, now.day, hour, minute);
  if (!candidate.isAfter(now)) candidate = candidate.add(const Duration(days: 1));
  return candidate;
}

/// Parses day-of-week cron tokens like `1,4`, `1-5`, `0` or `7` (both Sunday).
/// Returns a set of integers 0..6 where 0=Sun, 1=Mon, ..., 6=Sat.
Set<int> _parseDowSet(String dowPart) {
  final result = <int>{};
  for (final part in dowPart.split(',')) {
    final trimmed = part.trim();
    if (trimmed.isEmpty) continue;
    if (trimmed.contains('-')) {
      final sub = trimmed.split('-');
      if (sub.length == 2) {
        final start = int.tryParse(sub[0]);
        final end = int.tryParse(sub[1]);
        if (start != null && end != null && start <= end) {
          for (var i = start; i <= end; i++) {
            result.add(i % 7);
          }
        }
      }
    } else {
      final v = int.tryParse(trimmed);
      if (v != null) {
        result.add(v % 7);
      }
    }
  }
  return result;
}
