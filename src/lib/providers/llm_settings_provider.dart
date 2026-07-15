import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/llm_settings_service.dart';

/// Singleton Riverpod provider for the LLM settings service.
/// The singleton is loaded in main() before runApp, so it is
/// always ready when the UI accesses it.
final llmSettingsProvider = Provider<LlmSettingsService>((ref) {
  return LlmSettingsService.instance;
});
