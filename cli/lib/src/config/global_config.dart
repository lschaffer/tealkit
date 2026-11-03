import 'dart:io';
import 'package:path/path.dart' as p;

/// Resolves configuration files and directories with fallback to user home directory (`~/.tealkitcoder/`).
class GlobalConfigLocator {
  /// Optional user-specified configuration directory override (via --configuration-path / -c).
  static String? customConfigDir;

  /// User's global TealKitCoder directory (~/.tealkitcoder or %USERPROFILE%\.tealkitcoder).
  static String get globalDir {
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        Directory.current.path;
    return p.normalize(p.join(home, '.tealkitcoder'));
  }

  /// Effective configuration directory: uses [customConfigDir] if provided, otherwise [globalDir] (~/.tealkitcoder).
  static String get effectiveConfigDir =>
      customConfigDir != null && customConfigDir!.trim().isNotEmpty
          ? p.normalize(customConfigDir!)
          : globalDir;

  /// Global skills directory (~/.tealkitcoder/skills/).
  static String get globalSkillsDir => p.join(globalDir, 'skills');

  /// Effective skills directory: inside [effectiveConfigDir]/skills.
  static String get effectiveSkillsDir => p.join(effectiveConfigDir, 'skills');

  /// Returns true if the configuration directory does not exist or is missing essential config files.
  static bool get isMissingConfiguration {
    final dir = Directory(effectiveConfigDir);
    if (!dir.existsSync()) return true;
    final hasLlm = File(p.join(effectiveConfigDir, 'llm.yaml')).existsSync();
    final hasConfig = File(p.join(effectiveConfigDir, 'config.yaml')).existsSync();
    return !hasLlm || !hasConfig;
  }

  /// Resolves a configuration file by checking:
  /// 1. Explicit path (if passed and differs from default filename)
  /// 2. Custom configuration directory (if --configuration-path was provided)
  /// 3. Global user directory (~/.tealkitcoder/filename)
  /// 4. Legacy ~/.tealkit/ directory fallback
  /// 5. Local config/ folder in workspace
  /// 6. Parent config/ folder (when running in subdirectories like cli/)
  /// 7. Local workspace
  /// 8. Executable directory
  ///
  /// Returns the resolved [File] (existing or preferred location).
  static File resolveConfigFile(String filename, [String? explicitPath]) {
    if (explicitPath != null &&
        explicitPath.trim().isNotEmpty &&
        explicitPath != filename) {
      return File(explicitPath);
    }

    // 1. Check custom configuration directory if provided
    if (customConfigDir != null && customConfigDir!.trim().isNotEmpty) {
      final custom = File(p.join(customConfigDir!, filename));
      if (custom.existsSync()) return custom;
    }

    // 2. Check global ~/.tealkitcoder/ (default)
    final global = File(p.join(globalDir, filename));
    if (global.existsSync()) return global;

    // Check legacy ~/.tealkit/ fallback
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        Directory.current.path;
    final legacyFile = File(p.join(home, '.tealkit', filename));
    if (legacyFile.existsSync()) return legacyFile;

    // 3. Check local config/ folder in workspace
    final localConfig = File(p.join(Directory.current.path, 'config', filename));
    if (localConfig.existsSync()) return localConfig;

    // 4. Check parent config/ folder (when running in subdirectories like cli/)
    final parentConfig = File(p.join(Directory.current.path, '..', 'config', filename));
    if (parentConfig.existsSync()) return parentConfig;

    // 5. Check local workspace
    final local = File(p.join(Directory.current.path, filename));
    if (local.existsSync()) return local;

    // 6. Check executable directory (useful when run from elsewhere or via Task Scheduler)
    try {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      final exeConfig = File(p.join(exeDir, 'config', filename));
      if (exeConfig.existsSync()) return exeConfig;
      final exeLocal = File(p.join(exeDir, filename));
      if (exeLocal.existsSync()) return exeLocal;
    } catch (_) {}

    // Fallback: return preferred path in effectiveConfigDir
    return File(p.join(effectiveConfigDir, filename));
  }

  /// Returns all skill directories to scan (effective skills dir, local ./skills/, and legacy fallbacks).
  static List<Directory> resolveSkillDirectories() {
    final dirs = <Directory>[];

    final effSkills = Directory(effectiveSkillsDir);
    if (effSkills.existsSync()) {
      dirs.add(effSkills);
      return dirs;
    }

    final localSkills = Directory(p.join(Directory.current.path, 'skills'));
    if (localSkills.existsSync()) {
      dirs.add(localSkills);
    }

    final parentSkills = Directory(p.join(Directory.current.path, '..', 'skills'));
    if (parentSkills.existsSync()) {
      dirs.add(parentSkills);
    }

    final legacySkills = Directory(p.join(
      Platform.environment['USERPROFILE'] ??
          Platform.environment['HOME'] ??
          Directory.current.path,
      '.tealkit',
      'skills',
    ));
    if (legacySkills.existsSync()) {
      dirs.add(legacySkills);
    }

    return dirs;
  }

  /// Resolves a skill file path (supports explicit path, skill name, or checking effective skills dir).
  static File resolveSkillFile(String pathOrName) {
    final direct = File(pathOrName);
    if (direct.existsSync()) return direct;

    final candidates = [
      p.join(effectiveSkillsDir, pathOrName),
      p.join(effectiveSkillsDir, '$pathOrName.md'),
      p.join(Directory.current.path, 'skills', pathOrName),
      p.join(Directory.current.path, 'skills', '$pathOrName.md'),
      p.join(Directory.current.path, '..', 'skills', pathOrName),
      p.join(Directory.current.path, '..', 'skills', '$pathOrName.md'),
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

  /// Finds available source directories containing template configuration files.
  static List<Directory> getTemplateSourceDirectories() {
    final candidates = <Directory>[];

    void addIfDir(String dirPath) {
      final d = Directory(dirPath);
      if (d.existsSync() &&
          !candidates.any((existing) => p.normalize(existing.path) == p.normalize(d.path))) {
        candidates.add(d);
      }
    }

    // 1. Root config/ directory
    addIfDir(p.join(Directory.current.path, 'config'));
    addIfDir(p.join(Directory.current.path, '..', 'config'));

    // 2. Executable config/ directory
    try {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      addIfDir(p.join(exeDir, 'config'));
      addIfDir(exeDir);
    } catch (_) {}

    // 3. Workspace root fallback
    addIfDir(Directory.current.path);

    return candidates;
  }

  /// Ensures the global `~/.tealkitcoder` directory exists and has initial configurations.
  /// If it doesn't exist or is missing required config files, copies template files
  /// from `config/` or installation directory.
  ///
  /// CRITICAL: Never overwrites existing user files.
  /// Returns `true` if initial setup/copying occurred, `false` if already fully configured.
  static Future<bool> ensureInitialized({
    bool forceReinit = false,
    bool interactive = false,
  }) async {
    final targetDir = Directory(effectiveConfigDir);
    final missing = isMissingConfiguration;

    if (!missing && !forceReinit) {
      return false;
    }

    if (interactive && stdin.hasTerminal) {
      final isDefault = targetDir.path == Directory(globalDir).path;
      final actionLabel = forceReinit
          ? 'Reinitialize settings directory'
          : (isDefault
              ? 'Global settings directory not found'
              : 'Configuration directory not found');

      stdout.writeln('');
      stdout.writeln('[$actionLabel]');
      stdout.write('Create settings directory at "${targetDir.path}"? [Y/n]: ');
      final input = stdin.readLineSync()?.trim().toLowerCase() ?? '';
      if (input == 'n' || input == 'no') {
        stdout.writeln('Skipped global directory initialization.');
        stdout.writeln('');
        return false;
      }
    }

    try {
      if (!targetDir.existsSync()) {
        targetDir.createSync(recursive: true);
      }

      int copiedFiles = 0;
      int copiedSkills = 0;

      final sourceDirs = getTemplateSourceDirectories();

      // 1. Copy config files (never overwrite existing files)
      for (final srcDir in sourceDirs) {
        try {
          for (final entity in srcDir.listSync()) {
            if (entity is File) {
              final filename = p.basename(entity.path);
              final lower = filename.toLowerCase();
              if (lower == '.env' ||
                  lower == '.env.example' ||
                  lower.endsWith('.yaml') ||
                  lower.endsWith('.yml')) {
                final destFile = File(p.join(targetDir.path, filename));
                if (!destFile.existsSync()) {
                  entity.copySync(destFile.path);
                  copiedFiles++;
                }

                // If .env doesn't exist and we found .env.example, also seed initial .env
                if (lower == '.env.example') {
                  final targetEnv = File(p.join(targetDir.path, '.env'));
                  if (!targetEnv.existsSync()) {
                    entity.copySync(targetEnv.path);
                    copiedFiles++;
                  }
                }
              }
            }
          }
        } catch (_) {}
      }

      // 2. Copy skills folder (recursively, never overwrite)
      final skillsCandidates = [
        Directory(p.join(Directory.current.path, 'skills')),
        Directory(p.join(Directory.current.path, '..', 'skills')),
        Directory(p.join(Directory.current.path, 'example_skills')),
      ];
      try {
        final exeDir = p.dirname(Platform.resolvedExecutable);
        skillsCandidates.add(Directory(p.join(exeDir, 'skills')));
      } catch (_) {}

      final targetSkillsDir = Directory(effectiveSkillsDir);
      if (!targetSkillsDir.existsSync()) {
        targetSkillsDir.createSync(recursive: true);
      }

      for (final srcSkills in skillsCandidates) {
        if (srcSkills.existsSync()) {
          copiedSkills += _copyDirectoryRecursiveNoOverwrite(srcSkills, targetSkillsDir);
        }
      }

      if (stdin.hasTerminal) {
        stdout.writeln('✓ Successfully initialized TealKitCoder directory:');
        stdout.writeln('  Directory: $effectiveConfigDir');
        if (copiedFiles > 0) stdout.writeln('  Configurations seeded: $copiedFiles');
        if (copiedSkills > 0) stdout.writeln('  Skills seeded: $copiedSkills');
        stdout.writeln('');
      }

      return true;
    } catch (e) {
      if (stdin.hasTerminal) {
        stderr.writeln('Failed to initialize settings directory: $e');
      }
      return false;
    }
  }

  static int _copyDirectoryRecursiveNoOverwrite(Directory source, Directory destination) {
    int count = 0;
    if (!source.existsSync()) return count;
    if (!destination.existsSync()) {
      destination.createSync(recursive: true);
    }

    for (final entity in source.listSync(recursive: false)) {
      final name = p.basename(entity.path);
      if (entity is Directory) {
        final nextDest = Directory(p.join(destination.path, name));
        count += _copyDirectoryRecursiveNoOverwrite(entity, nextDest);
      } else if (entity is File) {
        final destFile = File(p.join(destination.path, name));
        if (!destFile.existsSync()) {
          entity.copySync(destFile.path);
          count++;
        }
      }
    }
    return count;
  }
}
