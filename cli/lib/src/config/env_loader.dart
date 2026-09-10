import 'dart:io';

/// Utility to load `.env` files and interpolate `${VAR}` syntax in configs.
class EnvLoader {
  static Map<String, String>? _cache;

  /// Load key-value pairs from `.env` (walks up directory tree from [startDir]).
  static Map<String, String> loadDotEnv([Directory? startDir]) {
    if (_cache != null) return _cache!;

    final env = <String, String>{};
    try {
      var dir = startDir ?? Directory.current;
      for (int i = 0; i < 5; i++) {
        final envFile = File('${dir.path}/.env');
        if (envFile.existsSync()) {
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
          break;
        }
        dir = dir.parent;
      }
    } catch (_) {}
    _cache = env;
    return env;
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
