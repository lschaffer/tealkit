import 'dart:io';
import 'package:dart_mcp_core/dart_mcp_core.dart';
import 'package:yaml/yaml.dart';

/// Configuration managing human-in-the-loop tool approvals.
class ToolPermissionSettings {
  bool autoApproveRead;
  bool autoApproveWrite;
  bool autoApproveExecute;
  bool autoApproveNetwork;

  ToolPermissionSettings({
    this.autoApproveRead = true,
    this.autoApproveWrite = false,
    this.autoApproveExecute = false,
    this.autoApproveNetwork = false,
  });

  /// Checks if a tool risk level is auto-approved under current settings.
  bool isAutoApproved(ToolRiskLevel risk) {
    return switch (risk) {
      ToolRiskLevel.read => autoApproveRead,
      ToolRiskLevel.write => autoApproveWrite,
      ToolRiskLevel.execute => autoApproveExecute,
      ToolRiskLevel.network => autoApproveNetwork,
    };
  }

  /// Path to persistent permissions configuration in user home or workspace.
  static String get defaultStoragePath {
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        Directory.current.path;
    return '$home/.tealkit/permissions.yaml';
  }

  /// Load permissions from YAML storage file (or return safe defaults).
  static ToolPermissionSettings load([String? customPath]) {
    final path = customPath ?? defaultStoragePath;
    final file = File(path);
    if (!file.existsSync()) {
      return ToolPermissionSettings();
    }

    try {
      final raw = file.readAsStringSync();
      final yaml = loadYaml(raw) as YamlMap?;
      if (yaml == null) return ToolPermissionSettings();

      return ToolPermissionSettings(
        autoApproveRead: (yaml['auto_approve_read'] as bool?) ?? true,
        autoApproveWrite: (yaml['auto_approve_write'] as bool?) ?? false,
        autoApproveExecute: (yaml['auto_approve_execute'] as bool?) ?? false,
        autoApproveNetwork: (yaml['auto_approve_network'] as bool?) ?? false,
      );
    } catch (_) {
      return ToolPermissionSettings();
    }
  }

  /// Save permissions to YAML storage file.
  void save([String? customPath]) {
    final path = customPath ?? defaultStoragePath;
    final file = File(path);
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('''# TealKit Human-in-the-loop Tool Approval Settings
auto_approve_read: $autoApproveRead
auto_approve_write: $autoApproveWrite
auto_approve_execute: $autoApproveExecute
auto_approve_network: $autoApproveNetwork
''');
    } catch (_) {}
  }
}
