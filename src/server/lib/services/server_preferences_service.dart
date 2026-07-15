import '../config/server_config_service.dart';
import '../utils/server_logger.dart';

class ServerPreferencesService {
  static final ServerPreferencesService instance = ServerPreferencesService._();
  ServerPreferencesService._();

  static const _kDefaultOutputPath = 'pref_default_output_path';
  static const _kOutputRetentionDays = 'pref_output_retention_days';
  static const _kBackgroundCheckInterval = 'pref_background_check_interval';
  static const _kAiDataSharingConsent = 'pref_ai_data_sharing_consent';
  static const _kLocale = 'pref_locale';

  String _defaultOutputPath = '';
  int _outputRetentionDays = 2;
  int _backgroundCheckIntervalMinutes = 60;
  bool _aiDataSharingConsent = false;
  String _locale = 'en';

  String get defaultOutputPath => _defaultOutputPath;
  int get outputRetentionDays => _outputRetentionDays;
  int get backgroundCheckIntervalMinutes => _backgroundCheckIntervalMinutes;
  bool get aiDataSharingConsent => _aiDataSharingConsent;
  String get locale => _locale;

  Future<void> load() async {
    final cfg = ServerConfigService();
    _defaultOutputPath = cfg.getString(_kDefaultOutputPath) ?? '';
    _outputRetentionDays = cfg.getInt(_kOutputRetentionDays) ?? 2;
    _backgroundCheckIntervalMinutes = cfg.getInt(_kBackgroundCheckInterval) ?? 60;
    _aiDataSharingConsent = cfg.getBool(_kAiDataSharingConsent) ?? false;
    _locale = cfg.getString(_kLocale) ?? 'en';
    log.info('[Preferences] Loaded');
  }

  Future<void> setDefaultOutputPath(String path) async {
    _defaultOutputPath = path;
    await ServerConfigService().setString(_kDefaultOutputPath, path);
  }

  Future<void> setOutputRetentionDays(int days) async {
    _outputRetentionDays = days;
    await ServerConfigService().setInt(_kOutputRetentionDays, days);
  }

  Future<void> setBackgroundCheckIntervalMinutes(int minutes) async {
    _backgroundCheckIntervalMinutes = minutes;
    await ServerConfigService().setInt(_kBackgroundCheckInterval, minutes);
  }

  Future<void> setAiDataSharingConsent(bool value) async {
    _aiDataSharingConsent = value;
    await ServerConfigService().setBool(_kAiDataSharingConsent, value);
  }

  Future<void> setLocale(String locale) async {
    _locale = locale;
    await ServerConfigService().setString(_kLocale, locale);
  }
}
