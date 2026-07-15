import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'app_logger.dart';

/// Thin wrapper around flutter_local_notifications.
///
/// Supports Android, iOS, and macOS.
/// On Windows and Linux the notification is currently logged only
/// (Windows toast setup requires COM/registry boilerplate outside Flutter).
class NotificationService {
  NotificationService._();
  static final instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  // ─── Android notification channels ────────────────────────────────────────

  static const _channelTaskSuccess = AndroidNotificationChannel(
    'task_success',
    'Task completed',
    description: 'Shown when a scheduled task finishes successfully.',
    importance: Importance.defaultImportance,
  );

  static const _channelTaskError = AndroidNotificationChannel(
    'task_error',
    'Task failed',
    description: 'Shown when a scheduled task fails.',
    importance: Importance.high,
  );

  static const _channelTaskPending = AndroidNotificationChannel(
    'task_pending',
    'Task waiting for app',
    description: 'Shown when a scheduled task with an embedded model needs the app open to run.',
    importance: Importance.defaultImportance,
  );

  // ─── Init ─────────────────────────────────────────────────────────────────

  Future<void> init() async {
    if (_initialized) return;
    if (!_isSupportedPlatform) return;

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    const settings = InitializationSettings(android: android, iOS: darwin, macOS: darwin);

    await _plugin.initialize(settings: settings);

    // Create Android channels
    if (Platform.isAndroid) {
      final androidPlugin = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await androidPlugin?.createNotificationChannel(_channelTaskSuccess);
      await androidPlugin?.createNotificationChannel(_channelTaskError);
      await androidPlugin?.createNotificationChannel(_channelTaskPending);
    }

    // Request permissions on iOS
    if (Platform.isIOS) {
      await _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()?.requestPermissions(
        alert: true,
        badge: true,
        sound: false,
      );
    }

    _initialized = true;
    log.info('[NotificationService] initialized');
  }

  bool get _isSupportedPlatform => !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  // ─── Show ──────────────────────────────────────────────────────────────────

  /// Show a task-completion notification.
  Future<void> showTaskResult({required String taskName, required bool success, required String body, required int id}) async {
    if (!_isSupportedPlatform) {
      log.info('[NotificationService] skipped (unsupported platform)  — $taskName: $body');
      return;
    }
    if (!_initialized) await init();

    final channel = success ? _channelTaskSuccess : _channelTaskError;
    final title = success ? '✓ $taskName' : '✗ $taskName';
    // Truncate body to 240 chars for notification
    final truncated = body.length > 240 ? '${body.substring(0, 240)}…' : body;

    final androidDetails = AndroidNotificationDetails(
      channel.id,
      channel.name,
      channelDescription: channel.description,
      importance: channel.importance,
      priority: success ? Priority.defaultPriority : Priority.high,
      icon: '@mipmap/ic_launcher',
    );

    const iosDetails = DarwinNotificationDetails(presentAlert: true, presentBadge: false, presentSound: false);

    final details = NotificationDetails(android: androidDetails, iOS: iosDetails, macOS: iosDetails);

    try {
      await _plugin.show(id: id & 0xFFFF, title: title, body: truncated, notificationDetails: details);
    } catch (e) {
      log.warning('[NotificationService] Failed to show notification: $e');
    }
  }

  /// Show a "task waiting — open app" notification for tasks that use an
  /// embedded model and cannot run in the background.
  /// Tapping the notification brings TealKit to the foreground so the
  /// foreground scheduler can execute the task on the next cron tick.
  Future<void> showEmbeddedTaskPending(String taskName, int id) async {
    if (!_isSupportedPlatform) return;
    if (!_initialized) await init();

    final androidDetails = AndroidNotificationDetails(
      _channelTaskPending.id,
      _channelTaskPending.name,
      channelDescription: _channelTaskPending.description,
      importance: _channelTaskPending.importance,
      priority: Priority.defaultPriority,
      icon: '@mipmap/ic_launcher',
    );

    const iosDetails = DarwinNotificationDetails(presentAlert: true, presentBadge: false, presentSound: false);

    final details = NotificationDetails(android: androidDetails, iOS: iosDetails, macOS: iosDetails);

    try {
      await _plugin.show(
        id: (id ^ 0x1000) & 0xFFFF,
        title: '📱 Open TealKit to run "$taskName"',
        body: 'This task uses an embedded model and needs the app open. Tap to launch.',
        notificationDetails: details,
      );
    } catch (e) {
      log.warning('[NotificationService] Failed to show pending-embedded notification: $e');
    }
  }

  /// Request Android 13+ POST_NOTIFICATIONS permission.
  Future<bool> requestAndroidPermission() async {
    if (!Platform.isAndroid) return true;
    if (!_initialized) await init();
    final result = await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    return result ?? false;
  }
}
