import 'dart:io';
import 'package:path/path.dart' as p;
import 'global_config.dart';

/// Utility to load `.env` files and interpolate `${VAR}` syntax in configs.
class EnvLoader {
  static Map<String, String>? _cache;

  /// Parse a `.env` file into key-value map.
  static Map<String, String> parseEnvFile(File envFile) {
    final env = <String, String>{};
    if (!envFile.existsSync()) return env;

    try {
      for (final line in envFile.readAsLinesSync()) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
        final eq = trimmed.indexOf('=');
        if (eq == -1) continue;
        final key = trimmed.substring(0, eq).trim();
        var val = trimmed.substring(eq + 1).trim();
        // Strip outer quotes if present
        if ((val.startsWith('"') && val.endsWith('"')) ||
            (val.startsWith("'") && val.endsWith("'"))) {
          val = val.substring(1, val.length - 1);
        }
        env[key] = val;
      }
    } catch (_) {}
    return env;
  }

  /// Load key-value pairs from `.env` files:
  /// 1. Global ~/.tealkit/.env (base defaults)
  /// 2. Config file directory if [startDir] provided
  /// 3. Workspace directory tree walking up from current directory (overrides global)
  static Map<String, String> loadDotEnv([Directory? startDir]) {
    if (_cache != null && startDir == null) return _cache!;

    final combinedEnv = <String, String>{};

    // 1. Load global ~/.tealkit/.env if present
    try {
      final globalEnvFile = File(p.join(GlobalConfigLocator.globalDir, '.env'));
      combinedEnv.addAll(parseEnvFile(globalEnvFile));
    } catch (_) {}

    // 2. Load startDir .env if specified (e.g. parent of resolved config file)
    if (startDir != null) {
      try {
        var dir = startDir;
        for (int i = 0; i < 3; i++) {
          final envFile = File(p.join(dir.path, '.env'));
          if (envFile.existsSync()) {
            combinedEnv.addAll(parseEnvFile(envFile));
            break;
          }
          final parent = dir.parent;
          if (parent.path == dir.path) break;
          dir = parent;
        }
      } catch (_) {}
    }

    // 3. Load workspace .env (highest priority)
    try {
      var dir = Directory.current;
      for (int i = 0; i < 5; i++) {
        final envFile = File(p.join(dir.path, '.env'));
        if (envFile.existsSync()) {
          combinedEnv.addAll(parseEnvFile(envFile));
          break;
        }
        final parent = dir.parent;
        if (parent.path == dir.path) break;
        dir = parent;
      }
    } catch (_) {}

    if (startDir == null) {
      _cache = combinedEnv;
    }
    return combinedEnv;
  }

  /// Replaces `${VAR_NAME}` in [input] with values from `.env` or system environment.
  static String substitute(String input, [Directory? startDir]) {
    final dotEnv = loadDotEnv(startDir);
    final envPattern = RegExp(r'\$\{([^}]+)\}');
    return input.replaceAllMapped(envPattern, (m) {
      final varName = m.group(1)!;
      return dotEnv[varName] ?? Platform.environment[varName] ?? '';
    });
  }

  /// Clears cached .env values (useful in testing).
  static void clearCache() {
    _cache = null;
  }
}
