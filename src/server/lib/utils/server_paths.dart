import 'dart:io';

import 'package:path/path.dart' as p;

String resolveServerDataDir() {
  return Platform.environment['TEALKIT_DATA_DIR'] ?? p.join(Platform.environment['HOME'] ?? '/root', '.tealkit-server');
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
