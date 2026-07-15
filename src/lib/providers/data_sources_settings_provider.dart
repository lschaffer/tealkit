import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/data_sources_settings_service.dart';

/// Singleton Riverpod provider for the global Data Sources settings service.
/// The singleton is loaded in main() before runApp, so it is
/// always ready when the UI accesses it.
final dataSourcesSettingsProvider = Provider<DataSourcesSettingsService>((ref) {
  return DataSourcesSettingsService.instance;
});
