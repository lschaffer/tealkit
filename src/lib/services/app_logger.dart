import 'package:flutter/foundation.dart';
import 'package:talker_flutter/talker_flutter.dart';

/// Raw [Talker] instance – used by [TalkerScreen] for the in-app log viewer.
/// For all other logging use the [log] wrapper below.
final Talker talkerInstance = TalkerFlutter.init(
  settings: TalkerSettings(useConsoleLogs: !kReleaseMode, useHistory: true, maxHistoryItems: kReleaseMode ? 150 : 500),
  logger: TalkerLogger(output: debugPrint, settings: TalkerLoggerSettings(maxLineWidth: 120)),
);

/// Filtered log proxy.
///
/// • In **debug** mode: all levels are forwarded.
/// • In **release** mode: only `warning` and `error` are forwarded; `info`,
///   `verbose`, and `debug` are silently dropped.
/// • All messages are sanitised: non-printable / non-ASCII characters are
///   stripped before they reach the underlying logger.
///
/// Usage:
/// ```dart
/// import '../services/app_logger.dart';
/// log.info('something happened');
/// log.warning('watch out');
/// log.error('oops', exception);
/// ```
final FilteredLog log = FilteredLog(talkerInstance);

class FilteredLog {
  const FilteredLog(this._t);
  final Talker _t;

  void info(String msg) {
    _t.info(_clean(msg));
  }

  void verbose(String msg) {
    if (!kReleaseMode) _t.verbose(_clean(msg));
  }

  void debug(String msg) {
    if (!kReleaseMode) _t.debug(_clean(msg));
  }

  void warning(String msg) => _t.warning(_clean(msg));
  void error(String msg, [Object? err, StackTrace? st]) => _t.error(_clean(msg), err, st);

  /// Remove non-printable and non-ASCII bytes (e.g. stray emoji / mojibake).
  static String _clean(String s) => s.replaceAll(RegExp(r'[^\x09\x0A\x0D\x20-\x7E]'), '');
}

/// Truncate a string to [maxLen] chars for compact log output.
String truncate(String s, [int maxLen = 100]) {
  if (s.length <= maxLen) return s;
  return '${s.substring(0, maxLen)}...';
}
