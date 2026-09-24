import 'dart:io';
import 'package:path/path.dart' as p;

/// Resolves configuration files and directories with fallback to user home directory (`~/.tealkit/`).
class GlobalConfigLocator {
  /// User's global TealKit directory (~/.tealkit or %USERPROFILE%\.tealkit).
  static String get globalDir {
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        Directory.current.path;
    return p.normalize(p.join(home, '.tealkit'));
  }

  /// Global skills directory (~/.tealkit/skills/).
  static String get globalSkillsDir => p.join(globalDir, 'skills');

  /// Resolves a configuration file by checking:
  /// 1. Explicit path (if passed and differs from default filename)
  /// 2. Current working directory (./filename)
  /// 3. Global user directory (~/.tealkit/filename)
  ///
  /// Returns the resolved [File] (existing or preferred location).
  static File resolveConfigFile(String filename, [String? explicitPath]) {
    if (explicitPath != null &&
        explicitPath.trim().isNotEmpty &&
        explicitPath != filename) {
      return File(explicitPath);
    }

    // 1. Check local workspace
    final local = File(p.join(Directory.current.path, filename));
    if (local.existsSync()) return local;

    // 2. Check global ~/.tealkit/
    final global = File(p.join(globalDir, filename));
    if (global.existsSync()) return global;

    // Fallback: return local path if neither exists
    return local;
  }

  /// Returns all skill directories to scan (both local `./skills/` and global `~/.tealkit/skills/`).
  static List<Directory> resolveSkillDirectories() {
    final dirs = <Directory>[];

    final localSkills = Directory(p.join(Directory.current.path, 'skills'));
    if (localSkills.existsSync()) {
      dirs.add(localSkills);
    }

    final globalSkills = Directory(globalSkillsDir);
    if (globalSkills.existsSync()) {
      dirs.add(globalSkills);
    }

    return dirs;
  }

  /// Resolves a skill file path (supports explicit path, skill name, or checking ~/.tealkit/skills/).
  static File resolveSkillFile(String pathOrName) {
    final direct = File(pathOrName);
    if (direct.existsSync()) return direct;

    final candidates = [
      p.join(Directory.current.path, 'skills', pathOrName),
      p.join(Directory.current.path, 'skills', '$pathOrName.md'),
      p.join(Directory.current.path, 'example_skills', pathOrName),
      p.join(Directory.current.path, 'example_skills', '$pathOrName.md'),
      p.join(globalSkillsDir, pathOrName),
      p.join(globalSkillsDir, '$pathOrName.md'),
    ];

    for (final c in candidates) {
      final f = File(c);
      if (f.existsSync()) return f;
    }

    return direct;
  }
}
