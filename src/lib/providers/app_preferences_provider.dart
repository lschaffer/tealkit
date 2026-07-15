import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/app_preferences_service.dart';

/// Riverpod provider that exposes the [AppPreferencesService] singleton.
///
/// Uses a plain [Provider] to match the pattern of all other singleton
/// settings providers in this project (Riverpod 3.x removed
/// ChangeNotifierProvider).  Consumers that need reactive rebuilds should
/// wrap their widget subtree in a [ListenableBuilder] on the service.
final appPreferencesProvider = Provider<AppPreferencesService>((ref) {
  return AppPreferencesService.instance;
});
