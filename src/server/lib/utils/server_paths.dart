import 'dart:io';

import 'package:path/path.dart' as p;

String resolveServerDataDir() {
  final configured = Platform.environment['TEALKIT_DATA_DIR']?.trim();
  if (configured != null && configured.isNotEmpty) return configured;

  final home = Platform.isWindows
      ? (Platform.environment['USERPROFILE'] ??
            Platform.environment['HOMEDRIVE'] ??
            'C:\\')
      : (Platform.environment['HOME'] ?? '/root');
  return p.join(home, '.tealkit-server');
}

String resolveServerFilesDir() {
  final configured = Platform.environment['TEALKIT_FILES_DIR']?.trim();
  if (configured != null && configured.isNotEmpty) {
    return configured;
  }
  return p.join(resolveServerDataDir(), 'files');
}

String resolveServerMcpServersDir() {
  return p.join(resolveServerFilesDir(), 'mcp_servers');
}

String resolveServerModelsDir() {
  final configured = Platform.environment['TEALKIT_MODELS_DIR']?.trim();
  if (configured != null && configured.isNotEmpty) {
    return configured;
  }
  return p.join(resolveServerDataDir(), 'models');
}
