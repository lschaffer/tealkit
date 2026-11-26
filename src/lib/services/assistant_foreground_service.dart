import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'app_logger.dart';
import 'app_preferences_service.dart';

/// Keeps the device awake (`wakelock_plus` on Android, iOS, Windows, macOS,
/// Linux) and runs the native Android Foreground Service (`dataSync` + partial
/// wake lock) while a long-running Assistant or Coding Agent turn is active.
///
/// Only active when [AppPreferencesService.keepAssistantAliveInBackground] is
/// enabled and an Assistant turn is actively running.
class AssistantForegroundService {
  AssistantForegroundService._();

  static const _channel = MethodChannel('at.ls.gr.tealkit/assistant_foreground');
  static bool _isRunning = false;

  static bool get isSupported => !kIsWeb;
  static bool get isRunning => _isRunning;

  static Future<void> startIfEnabled({
    String title = 'TealKit Assistant',
    String text = 'AI agent is running in the background…',
  }) async {
    if (!isSupported) return;
    if (!AppPreferencesService.instance.keepAssistantAliveInBackground) return;
    if (_isRunning) return;
    _isRunning = true;

    // 1. Cross-platform screen/sleep wakelock (Android, iOS, Windows, macOS, Linux)
    try {
      await WakelockPlus.enable();
      log.info('[AssistantFG] WakelockPlus enabled');
    } catch (e) {
      log.warning('[AssistantFG] WakelockPlus.enable failed: $e');
    }

    // 2. Android native Foreground Service (keeps network alive if user switches apps)
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod('start', {'title': title, 'text': text});
        log.info('[AssistantFG] Android foreground service started');
      } catch (e) {
        log.warning('[AssistantFG] Failed to start Android foreground service: $e');
      }
    }
  }

  static Future<void> stop() async {
    if (!isSupported || !_isRunning) return;
    _isRunning = false;

    try {
      await WakelockPlus.disable();
      log.info('[AssistantFG] WakelockPlus disabled');
    } catch (e) {
      log.warning('[AssistantFG] WakelockPlus.disable failed: $e');
    }

    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod('stop');
        log.info('[AssistantFG] Android foreground service stopped');
      } catch (e) {
        log.warning('[AssistantFG] Failed to stop Android foreground service: $e');
      }
    }
  }
}
