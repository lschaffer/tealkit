import 'dart:io';

/// Lightweight stdout/stderr logger for the headless server.
/// Mirrors the [FilteredLog] interface used in the Flutter app so all
/// ported service files can keep the same `log.info(...)` call-site style.
final ServerLog log = ServerLog._();

class ServerLog {
  ServerLog._();

  void verbose(String msg) => _write('VERBOSE', msg);
  void debug(String msg) => _write('DEBUG', msg);
  void info(String msg) => _write('INFO', msg);
  void warning(String msg, [Object? error, StackTrace? st]) => _write('WARN', msg, error: error, st: st);
  void error(String msg, [Object? error, StackTrace? st]) => _write('ERROR', msg, error: error, st: st);

  void _write(String level, String msg, {Object? error, StackTrace? st}) {
    final now = DateTime.now().toIso8601String();
    final out = '[$now] [$level] $msg';
    if (level == 'ERROR' || level == 'WARN') {
      stderr.writeln(out);
      if (error != null) stderr.writeln('  $error');
      if (st != null) stderr.writeln('  $st');
    } else {
      stdout.writeln(out);
    }
  }
}

/// Truncate a [value] to [maxLen] characters for log output.
String truncate(String value, {int maxLen = 200}) {
  if (value.length <= maxLen) return value;
  return '${value.substring(0, maxLen)}…';
}
