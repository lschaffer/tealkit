import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/external_tools_settings_service.dart';

final externalToolsSettingsProvider = Provider<ExternalToolsSettingsService>((ref) {
  return ExternalToolsSettingsService.instance;
});
