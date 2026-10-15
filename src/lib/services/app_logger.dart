import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:talker_flutter/talker_flutter.dart';

/// Raw [Talker] instance – used by [TalkerScreen] for the in-app log viewer.
/// In production / release mode, Talker history and logging are completely disabled.
final Talker talkerInstance = TalkerFlutter.init(
  settings: TalkerSettings(
    enabled: !kReleaseMode,
    useConsoleLogs: !kReleaseMode,
    useHistory: !kReleaseMode,
    maxHistoryItems: kReleaseMode ? 0 : 500,
  ),
  logger: TalkerLogger(
    output: kReleaseMode ? (String _) {} : debugPrint,
    settings: TalkerLoggerSettings(maxLineWidth: 120),
  ),
);

/// Opens the interactive Talker log monitor screen (dev mode only).
void openTalkerScreen(BuildContext context) {
  if (kReleaseMode) return;

  final theme = Theme.of(context);
  final isDark = theme.brightness == Brightness.dark;
  final textColor = isDark ? Colors.white : const Color(0xFF1E293B);
  final cardColor = isDark ? theme.cardColor : const Color(0xFFF8FAFC);

  // High-contrast colors in light mode so monitor icons, pills, and text are crisp
  final logColors = isDark
      ? null
      : {
          TalkerLogType.info.key: const Color(0xFF1D4ED8),
          TalkerLogType.debug.key: const Color(0xFF475569),
          TalkerLogType.verbose.key: const Color(0xFF64748B),
          TalkerLogType.warning.key: const Color(0xFFD97706),
          TalkerLogType.error.key: const Color(0xFFDC2626),
          TalkerLogType.critical.key: const Color(0xFF991B1B),
          TalkerLogType.exception.key: const Color(0xFFDC2626),
          TalkerLogType.httpError.key: const Color(0xFFDC2626),
          TalkerLogType.httpRequest.key: const Color(0xFF9333EA),
          TalkerLogType.httpResponse.key: const Color(0xFF16A34A),
        };

  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => Theme(
        data: theme.copyWith(
          appBarTheme: theme.appBarTheme.copyWith(
            backgroundColor: theme.scaffoldBackgroundColor,
            foregroundColor: textColor,
            iconTheme: IconThemeData(color: textColor),
          ),
        ),
        child: TalkerScreen(
          talker: talkerInstance,
          theme: TalkerScreenTheme(
            backgroundColor: theme.scaffoldBackgroundColor,
            textColor: textColor,
            cardColor: cardColor,
            logColors: logColors,
          ),
        ),
      ),
    ),
  );
}

/// Filtered log proxy.
///
/// • In **debug/dev** mode: all levels are forwarded.
/// • In **release/prod** mode: completely disabled (no-op).
final FilteredLog log = FilteredLog(talkerInstance);

class FilteredLog {
  const FilteredLog(this._t);
  final Talker _t;

  void info(String msg) {
    if (!kReleaseMode) _t.info(_clean(msg));
  }

  void verbose(String msg) {
    if (!kReleaseMode) _t.verbose(_clean(msg));
  }

  void debug(String msg) {
    if (!kReleaseMode) _t.debug(_clean(msg));
  }

  void warning(String msg) {
    if (!kReleaseMode) _t.warning(_clean(msg));
  }

  void error(String msg, [Object? err, StackTrace? st]) {
    if (!kReleaseMode) _t.error(_clean(msg), err, st);
  }

  /// Remove non-printable and non-ASCII bytes (e.g. stray emoji / mojibake).
  static String _clean(String s) => s.replaceAll(RegExp(r'[^\x09\x0A\x0D\x20-\x7E]'), '');
}

/// Truncate a string to [maxLen] chars for compact log output.
String truncate(String s, [int maxLen = 100]) {
  if (s.length <= maxLen) return s;
  return '${s.substring(0, maxLen)}...';
}
