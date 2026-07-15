import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';

/// Persistent app-level preferences: theme mode and locale.
///
/// Stored via [SharedPreferences] so they survive app restarts.
/// Call [load()] at startup before [runApp].
class AppPreferencesService extends ChangeNotifier {
  static final AppPreferencesService instance = AppPreferencesService._();
  AppPreferencesService._();

  static const _kThemeMode =
      'app_pref_theme_mode'; // 'dark' | 'system' | 'light'
  static const _kLocale = 'app_pref_locale'; // 'de' | 'en'
  static const _kDefaultOutputPath = 'app_pref_default_output_path';
  static const _kOutputRetentionDays = 'app_pref_output_retention_days';
  static const _kBackgroundCheckInterval = 'app_pref_background_check_interval';
  static const _kAiDataSharingConsent = 'app_pref_ai_data_sharing_consent';
  static const _kUiStyle = 'app_pref_ui_style'; // 'modern' | 'classic'

  /// Allowed values for the background check interval setting.
  static const List<int> backgroundCheckIntervalOptions = [5, 10, 15];

  ThemeMode _themeMode = ThemeMode.system;
  String _locale = 'de';
  String _defaultOutputPath = '';
  int _outputRetentionDays = 3;
  int _backgroundCheckIntervalMinutes = 10;
  bool _aiDataSharingConsent = false;
  String _uiStyle = 'modern';

  ThemeMode get themeMode => _themeMode;
  String get locale => _locale;
  String get defaultOutputPath => _defaultOutputPath;
  int get outputRetentionDays => _outputRetentionDays;
  bool get aiDataSharingConsent => _aiDataSharingConsent;
  String get uiStyle => _uiStyle;

  /// How often (in minutes) the background heartbeat wakes up to check for due tasks.
  /// Allowed values: 5, 10, 15. Default: 10.
  int get backgroundCheckIntervalMinutes => _backgroundCheckIntervalMinutes;

  /// Human-readable label for the current theme mode.
  String get themeModeLabel {
    switch (_themeMode) {
      case ThemeMode.dark:
        return 'Dark';
      case ThemeMode.light:
        return 'Light';
      case ThemeMode.system:
        return 'System';
    }
  }

  IconData get themeModeIcon {
    switch (_themeMode) {
      case ThemeMode.dark:
        return Icons.dark_mode;
      case ThemeMode.light:
        return Icons.light_mode;
      case ThemeMode.system:
        return Icons.brightness_auto;
    }
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final t = prefs.getString(_kThemeMode) ?? 'system';
      _themeMode = _parseThemeMode(t);
      _locale = prefs.getString(_kLocale) ?? 'de';
      _defaultOutputPath = prefs.getString(_kDefaultOutputPath) ?? '';
      _outputRetentionDays = (prefs.getInt(_kOutputRetentionDays) ?? 3).clamp(
        1,
        60,
      );
      _backgroundCheckIntervalMinutes = _parseInterval(
        prefs.getInt(_kBackgroundCheckInterval) ?? 10,
      );
      _aiDataSharingConsent = prefs.getBool(_kAiDataSharingConsent) ?? false;
      _uiStyle = prefs.getString(_kUiStyle) ?? 'modern';
      log.info(
        '[AppPrefs] Loaded themeMode=$t locale=$_locale outputPath=$_defaultOutputPath retentionDays=$_outputRetentionDays bgInterval=$_backgroundCheckIntervalMinutes aiConsent=$_aiDataSharingConsent uiStyle=$_uiStyle',
      );
    } catch (e) {
      log.warning('[AppPrefs] load failed: $e');
    }
    notifyListeners();
  }

  /// Cycles: dark → system → light → dark
  Future<void> cycleTheme() async {
    switch (_themeMode) {
      case ThemeMode.dark:
        _themeMode = ThemeMode.system;
        break;
      case ThemeMode.system:
        _themeMode = ThemeMode.light;
        break;
      case ThemeMode.light:
        _themeMode = ThemeMode.dark;
        break;
    }
    await _persist();
    notifyListeners();
  }

  /// Sets the UI style style ('modern' | 'classic')
  Future<void> setUiStyle(String style) async {
    if (style != 'modern' && style != 'classic') return;
    _uiStyle = style;
    await _persist();
    notifyListeners();
  }

  /// Toggles between the two available locales: de ↔ en.
  Future<void> toggleLocale() async {
    _locale = _locale == 'de' ? 'en' : 'de';
    await _persist();
    notifyListeners();
  }

  /// Sets and persists the global default output directory.
  Future<void> setDefaultOutputPath(String path) async {
    _defaultOutputPath = path.trim();
    await _persist();
    notifyListeners();
  }

  /// Sets and persists the output file retention period (1-60 days).
  Future<void> setOutputRetentionDays(int days) async {
    _outputRetentionDays = days.clamp(1, 60);
    await _persist();
    notifyListeners();
  }

  /// Sets and persists the background heartbeat check interval.
  /// [minutes] must be one of [backgroundCheckIntervalOptions]; invalid values are ignored.
  Future<void> setBackgroundCheckInterval(int minutes) async {
    if (!backgroundCheckIntervalOptions.contains(minutes)) return;
    _backgroundCheckIntervalMinutes = minutes;
    await _persist();
    notifyListeners();
  }

  /// Enables/disables consent for sending user-provided content to remote AI services.
  Future<void> setAiDataSharingConsent(bool value) async {
    _aiDataSharingConsent = value;
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kThemeMode, _themeModeKey(_themeMode));
      await prefs.setString(_kLocale, _locale);
      await prefs.setString(_kDefaultOutputPath, _defaultOutputPath);
      await prefs.setInt(_kOutputRetentionDays, _outputRetentionDays);
      await prefs.setInt(
        _kBackgroundCheckInterval,
        _backgroundCheckIntervalMinutes,
      );
      await prefs.setBool(_kAiDataSharingConsent, _aiDataSharingConsent);
      await prefs.setString(_kUiStyle, _uiStyle);
    } catch (e) {
      log.warning('[AppPrefs] persist failed: $e');
    }
  }

  // ── helpers ──────────────────────────────────────────────────

  ThemeMode _parseThemeMode(String s) {
    switch (s) {
      case 'dark':
        return ThemeMode.dark;
      case 'light':
        return ThemeMode.light;
      default:
        return ThemeMode.system;
    }
  }

  String _themeModeKey(ThemeMode m) {
    switch (m) {
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.light:
        return 'light';
      default:
        return 'system';
    }
  }

  /// Returns [v] if it is a valid interval option, otherwise defaults to 10.
  int _parseInterval(int v) =>
      backgroundCheckIntervalOptions.contains(v) ? v : 10;
}
