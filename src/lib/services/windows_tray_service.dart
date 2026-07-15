import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'app_logger.dart';

/// Windows-only: manages the system tray icon, minimize-to-tray behaviour,
/// and the "start at login" registry entry.
///
/// On non-Windows platforms this is a no-op stub.
class WindowsTrayService with TrayListener, WindowListener {
  WindowsTrayService._();
  static final instance = WindowsTrayService._();

  bool _initialized = false;

  /// Called once from [main] on Windows only.
  Future<void> init({required String appName}) async {
    if (kIsWeb || !Platform.isWindows) return;
    if (_initialized) return;
    _initialized = true;

    // ── Window manager ──────────────────────────────────────────────────────
    await windowManager.ensureInitialized();
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);

    // ── Tray icon ────────────────────────────────────────────────────────────
    // Windows system tray requires .ico format; other platforms use .png.
    await trayManager.setIcon(_resolveIconPath());
    await trayManager.setToolTip(appName);
    await _updateMenu(appName);
    trayManager.addListener(this);

    // ── Copy app path for startup registration ──────────────────────────────
    LaunchAtStartup.instance.setup(appName: appName, appPath: Platform.resolvedExecutable);

    log.info('[TrayService] Initialized');
  }

  // ─── Icon path ────────────────────────────────────────────────────────────

  /// Returns the correct icon path for the current platform and build mode.
  ///
  /// - Debug / `flutter run`: assets are served from the project root, so the
  ///   relative path `assets/icons/app_icon.ico` works directly.
  /// - Release build: Flutter copies assets into
  ///   `<exe-dir>/data/flutter_assets/`, so we resolve the absolute path from
  ///   the running executable's directory.
  String _resolveIconPath() {
    if (!Platform.isWindows) return 'assets/icons/app_icon.png';

    if (kDebugMode) return 'assets/icons/app_icon.ico';

    // Release / profile: exe sits at <install>/TealKit.exe and assets are at
    // <install>/data/flutter_assets/assets/icons/app_icon.ico
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final releasePath = p.join(exeDir, 'data', 'flutter_assets', 'assets', 'icons', 'app_icon.ico');
    if (File(releasePath).existsSync()) return releasePath;

    // Fallback: profile mode or unexpected layout — try the bare relative path.
    return 'assets/icons/app_icon.ico';
  }

  // ─── Menu ──────────────────────────────────────────────────────────────────

  Future<void> _updateMenu(String appName) async {
    final isStartup = await LaunchAtStartup.instance.isEnabled().catchError((_) => false);

    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(label: appName, disabled: true),
          MenuItem.separator(),
          MenuItem(key: 'show', label: 'Öffnen'),
          MenuItem(key: 'tasks', label: 'Tasks anzeigen'),
          MenuItem.separator(),
          MenuItem.checkbox(key: 'startup', label: 'Autostart beim Login', checked: isStartup),
          MenuItem.separator(),
          MenuItem(key: 'quit', label: 'Beenden'),
        ],
      ),
    );
  }

  // ─── TrayListener ─────────────────────────────────────────────────────────

  @override
  void onTrayIconMouseDown() {
    _showWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'show':
      case 'tasks':
        _showWindow();
      case 'startup':
        await _toggleStartup();
      case 'quit':
        await windowManager.setPreventClose(false);
        await windowManager.close();
    }
  }

  // ─── WindowListener ───────────────────────────────────────────────────────

  @override
  void onWindowClose() async {
    // Minimize to tray instead of closing.
    await windowManager.hide();
    log.info('[TrayService] Window hidden to tray');
  }

  // ─── Public API ───────────────────────────────────────────────────────────

  Future<void> showWindow() async {
    await _showWindow();
  }

  Future<void> _showWindow() async {
    if (!await windowManager.isVisible()) {
      await windowManager.show();
    }
    await windowManager.focus();
  }

  /// Toggle launch-at-startup.
  Future<bool> _toggleStartup() async {
    try {
      final enabled = await LaunchAtStartup.instance.isEnabled();
      if (enabled) {
        await LaunchAtStartup.instance.disable();
        log.info('[TrayService] Autostart disabled');
      } else {
        await LaunchAtStartup.instance.enable();
        log.info('[TrayService] Autostart enabled');
      }
      await _updateMenu('TealKit'); // Refresh checkbox state.
      return !enabled;
    } catch (e) {
      log.warning('[TrayService] Startup toggle failed: $e');
      return false;
    }
  }

  /// Expose startup state for the Settings screen.
  Future<bool> isStartupEnabled() async {
    if (kIsWeb || !Platform.isWindows) return false;
    return LaunchAtStartup.instance.isEnabled().catchError((_) => false);
  }

  Future<void> setStartup({required bool enabled}) async {
    if (kIsWeb || !Platform.isWindows) return;
    try {
      if (enabled) {
        await LaunchAtStartup.instance.enable();
      } else {
        await LaunchAtStartup.instance.disable();
      }
      await _updateMenu('TealKit');
    } catch (e) {
      log.warning('[TrayService] setStartup failed: $e');
    }
  }
}
