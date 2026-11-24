import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:path/path.dart' as p;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'app_logger.dart';
import 'app_preferences_service.dart';

/// Windows-only: manages the system tray icon, minimize-to-tray behaviour,
/// and the "start at login" registry entry.
///
/// On non-Windows platforms this is a no-op stub.
class WindowsTrayService with WindowListener {
  WindowsTrayService._();
  static final instance = WindowsTrayService._();

  bool _initialized = false;
  String _appName = 'TealKit';
  String _lastLocale = '';

  TrayIcon? _trayIcon;
  Image? _icon;
  Menu? _menu;
  ListenerId? _trayListenerId;
  final List<(MenuItem, ListenerId?)> _menuItems = [];

  /// Called once from [main] on Windows only.
  Future<void> init({required String appName}) async {
    if (kIsWeb || !Platform.isWindows) return;
    if (_initialized) return;
    _initialized = true;
    _appName = appName;
    _lastLocale = AppPreferencesService.instance.locale;

    // ── Window manager ──────────────────────────────────────────────────────
    await windowManager.ensureInitialized();
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);

    // ── Tray icon (tray_manager 0.7+ native API) ────────────────────────────
    final trayIcon = TrayIcon.create();
    if (trayIcon != null) {
      _trayIcon = trayIcon;
      final iconPath = _resolveIconPath();
      final icon = ImageAsset.fromAsset(iconPath) ?? Image.fromFile(iconPath);
      if (icon != null) {
        trayIcon.icon = icon;
        _icon = icon;
      } else {
        log.warning('[TrayService] Could not load tray icon from $iconPath');
      }
      trayIcon.setTooltip(appName);
      trayIcon.setContextMenuTrigger(ContextMenuTrigger.rightClicked);
      _trayListenerId = trayIcon.addListener((event) {
        if (event is TrayIconClickedEvent) {
          _showWindow();
        }
      });
      await _updateMenu();
      trayIcon.setVisible(true);
    } else {
      log.warning('[TrayService] Unable to create native TrayIcon');
    }

    // Rebuild tray menu when the user switches app language.
    AppPreferencesService.instance.addListener(_onPreferencesChanged);

    // ── Copy app path for startup registration ──────────────────────────────
    LaunchAtStartup.instance.setup(
      appName: appName,
      appPath: Platform.resolvedExecutable,
    );

    log.info('[TrayService] Initialized');
  }

  void _onPreferencesChanged() {
    final currentLocale = AppPreferencesService.instance.locale;
    if (currentLocale != _lastLocale) {
      _lastLocale = currentLocale;
      unawaited(_updateMenu());
    }
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
    final releasePath = p.join(
      exeDir,
      'data',
      'flutter_assets',
      'assets',
      'icons',
      'app_icon.ico',
    );
    if (File(releasePath).existsSync()) return releasePath;

    // Fallback: profile mode or unexpected layout — try the bare relative path.
    return 'assets/icons/app_icon.ico';
  }

  // ─── Menu ──────────────────────────────────────────────────────────────────

  Future<void> _updateMenu() async {
    final trayIcon = _trayIcon;
    if (trayIcon == null) return;

    final isStartup = await LaunchAtStartup.instance
        .isEnabled()
        .catchError((_) => false);
    final isDe = AppPreferencesService.instance.locale == 'de';

    final menu = Menu.create();
    if (menu == null) return;

    final newItems = <(MenuItem, ListenerId?)>[];

    void addActionItem(
      String label, {
      bool enabled = true,
      void Function()? onClick,
    }) {
      final item = MenuItem.createWithLabelAndType(label, MenuItemType.normal);
      if (item == null) return;
      item.isEnabled = enabled;
      ListenerId? listenerId;
      if (onClick != null) {
        listenerId = item.addListener((event) {
          if (event is MenuItemClickedEvent) {
            onClick();
          }
        });
      }
      newItems.add((item, listenerId));
      menu.addItem(item);
    }

    addActionItem(_appName, enabled: false);
    menu.addSeparator();
    addActionItem(isDe ? 'Öffnen' : 'Open', onClick: _showWindow);
    addActionItem(isDe ? 'Tasks anzeigen' : 'Show Tasks', onClick: _showWindow);
    menu.addSeparator();

    final startupItem = MenuItem.createWithLabelAndType(
      isDe ? 'Autostart beim Login' : 'Start at Login',
      MenuItemType.checkbox,
    );
    if (startupItem != null) {
      startupItem.state = isStartup
          ? MenuItemState.checked
          : MenuItemState.unchecked;
      final listenerId = startupItem.addListener((event) {
        if (event is MenuItemClickedEvent) {
          unawaited(_toggleStartup());
        }
      });
      newItems.add((startupItem, listenerId));
      menu.addItem(startupItem);
    }

    menu.addSeparator();
    addActionItem(
      isDe ? 'Beenden' : 'Quit',
      onClick: () async {
        await windowManager.setPreventClose(false);
        await windowManager.close();
      },
    );

    trayIcon.setContextMenu(menu);

    // Dispose the previous menu/items after the current callback unwinds.
    final oldMenu = _menu;
    final oldItems = List<(MenuItem, ListenerId?)>.of(_menuItems);
    _menu = menu;
    _menuItems
      ..clear()
      ..addAll(newItems);

    if (oldMenu != null || oldItems.isNotEmpty) {
      Timer.run(() {
        for (final (item, listenerId) in oldItems) {
          if (listenerId != null) {
            item.removeListener(listenerId);
          }
          item.dispose();
        }
        oldMenu?.dispose();
      });
    }
  }

  /// Dispose native tray resources if needed.
  void dispose() {
    AppPreferencesService.instance.removeListener(_onPreferencesChanged);
    final listenerId = _trayListenerId;
    if (listenerId != null) {
      _trayIcon?.removeListener(listenerId);
      _trayListenerId = null;
    }
    for (final (item, id) in _menuItems) {
      if (id != null) item.removeListener(id);
      item.dispose();
    }
    _menuItems.clear();
    _menu?.dispose();
    _menu = null;
    _icon?.dispose();
    _icon = null;
    _trayIcon?.dispose();
    _trayIcon = null;
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
      await _updateMenu(); // Refresh checkbox state.
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
      await _updateMenu();
    } catch (e) {
      log.warning('[TrayService] setStartup failed: $e');
    }
  }
}
