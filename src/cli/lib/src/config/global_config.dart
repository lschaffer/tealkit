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

  /// Ensures the global `~/.tealkit` directory exists.
  /// If it doesn't exist (first run) or [forceReinit] is true:
  /// Prompts the user to create the global directory and copies `.env`, `llm.yaml`,
  /// `mcp.yaml`, all other `*.yaml` configs, and the `skills/` directory from the
  /// executable/working installation directory.
  static Future<void> ensureInitialized({bool forceReinit = false}) async {
    final targetDir = Directory(globalDir);
    final exists = targetDir.existsSync();

    if (exists && !forceReinit) {
      return;
    }

    // Determine the source directory where TealKit is installed / running from.
    // Check executable directory first (e.g. where tealkit.exe lives), fallback to current directory.
    var sourceDir = Directory.current;
    try {
      final exeFile = File(Platform.resolvedExecutable);
      if (exeFile.existsSync()) {
        final exeParent = exeFile.parent;
        // Verify if exeParent contains configuration files or skills
        final hasConfig = exeParent.listSync().any((entity) =>
            entity is File &&
            (entity.path.endsWith('.yaml') || entity.path.endsWith('.env')));
        if (hasConfig) {
          sourceDir = exeParent;
        }
      }
    } catch (_) {}

    final actionLabel = forceReinit
        ? 'Reinitialize global settings directory'
        : 'Global settings directory not found';

    stdout.writeln('');
    stdout.writeln('[$actionLabel]');
    stdout.write('Create global directory for settings at "$globalDir"? [y/N]: ');
    final input = stdin.readLineSync()?.trim().toLowerCase() ?? '';

    if (input != 'y' && input != 'yes') {
      stdout.writeln('Skipped global directory initialization.');
      stdout.writeln('');
      return;
    }

    try {
      if (!targetDir.existsSync()) {
        targetDir.createSync(recursive: true);
      }

      int copiedFiles = 0;
      int copiedSkills = 0;

      // 1. Copy .env and any *.yaml configuration files
      try {
        final sourceEntities = sourceDir.listSync();
        for (final entity in sourceEntities) {
          if (entity is File) {
            final filename = p.basename(entity.path);
            final lower = filename.toLowerCase();
            if (lower == '.env' ||
                lower.endsWith('.yaml') ||
                lower.endsWith('.yml')) {
              final destFile = File(p.join(targetDir.path, filename));
              entity.copySync(destFile.path);
              copiedFiles++;
            }
          }
        }
      } catch (e) {
        stderr.writeln('Warning: Failed copying configuration files: $e');
      }

      // Also check Directory.current if sourceDir was exeParent and .env was in current dir
      if (sourceDir.path != Directory.current.path) {
        try {
          final curEntities = Directory.current.listSync();
          for (final entity in curEntities) {
            if (entity is File) {
              final filename = p.basename(entity.path);
              final lower = filename.toLowerCase();
              if (lower == '.env' ||
                  lower.endsWith('.yaml') ||
                  lower.endsWith('.yml')) {
                final destFile = File(p.join(targetDir.path, filename));
                if (!destFile.existsSync()) {
                  entity.copySync(destFile.path);
                  copiedFiles++;
                }
              }
            }
          }
        } catch (_) {}
      }

      // 2. Copy skills folder (recursively) if it exists
      final skillsCandidates = [
        Directory(p.join(sourceDir.path, 'skills')),
        Directory(p.join(Directory.current.path, 'skills')),
        Directory(p.join(sourceDir.path, 'example_skills')),
        Directory(p.join(Directory.current.path, 'example_skills')),
      ];

      final targetSkillsDir = Directory(globalSkillsDir);
      if (!targetSkillsDir.existsSync()) {
        targetSkillsDir.createSync(recursive: true);
      }

      for (final srcSkills in skillsCandidates) {
        if (srcSkills.existsSync()) {
          copiedSkills += _copyDirectoryRecursive(srcSkills, targetSkillsDir);
        }
      }

      stdout.writeln('✓ Successfully initialized global TealKit directory:');
      stdout.writeln('  Directory: $globalDir');
      stdout.writeln('  Configurations copied: $copiedFiles');
      stdout.writeln('  Skills copied: $copiedSkills');
      stdout.writeln('');
    } catch (e) {
      stderr.writeln('Failed to initialize global directory: $e');
      stdout.writeln('');
    }
  }

  static int _copyDirectoryRecursive(Directory source, Directory destination) {
    int count = 0;
    if (!source.existsSync()) return count;
    if (!destination.existsSync()) {
      destination.createSync(recursive: true);
    }

    for (final entity in source.listSync(recursive: false)) {
      final name = p.basename(entity.path);
      if (entity is Directory) {
        final nextDest = Directory(p.join(destination.path, name));
        count += _copyDirectoryRecursive(entity, nextDest);
      } else if (entity is File) {
        final destFile = File(p.join(destination.path, name));
        entity.copySync(destFile.path);
        count++;
      }
    }
    return count;
  }
}
