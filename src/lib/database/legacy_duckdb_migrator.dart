import 'dart:convert';
import 'dart:io';

import 'package:dart_duckdb/dart_duckdb.dart' as ddb;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../services/app_logger.dart';
import 'sqlite_service.dart';

/// Result report returned after migrating a legacy `mobile_ai_agent.duckdb` database.
class DatabaseMigrationReport {
  final int tasksMigrated;
  final int mcpConfigsMigrated;
  final int skillsMigrated;
  final int subagentsMigrated;
  final int pyToolsMigrated;
  final int githubMcpsMigrated;
  final int toolSkillsMigrated;
  final int sysMetaMigrated;
  final String sourcePath;
  final String backupPath;

  const DatabaseMigrationReport({
    required this.tasksMigrated,
    required this.mcpConfigsMigrated,
    required this.skillsMigrated,
    required this.subagentsMigrated,
    required this.pyToolsMigrated,
    required this.githubMcpsMigrated,
    required this.toolSkillsMigrated,
    required this.sysMetaMigrated,
    required this.sourcePath,
    required this.backupPath,
  });

  int get totalRecords =>
      tasksMigrated +
      mcpConfigsMigrated +
      skillsMigrated +
      subagentsMigrated +
      pyToolsMigrated +
      githubMcpsMigrated +
      toolSkillsMigrated +
      sysMetaMigrated;
}

/// One-time Release-1 bridge migrator reading legacy `mobile_ai_agent.duckdb`
/// (including `.duckdb.wal` replay) into [SqliteService] (`mobile_ai_agent.sqlite`),
/// skipping `document_index`, `website_index`, and `workflow_memory_store`,
/// then immediately closing DuckDB (`0 MB` runtime RAM) and archiving `.duckdb`
/// to `.duckdb.migrated.bak`.
///
/// NOTE FOR RELEASE 2: Delete this file and remove `dart_duckdb` from `pubspec.yaml`.
class LegacyDuckDbBridgeMigrator {
  static const String legacyDbFileName = 'mobile_ai_agent.duckdb';

  const LegacyDuckDbBridgeMigrator._();

  /// Resolves the unmigrated legacy `.duckdb` path if one exists on disk, or null.
  static Future<String?> findPendingLegacyDuckDbPath({
    String? customDuckDbPath,
  }) async {
    if (customDuckDbPath != null && customDuckDbPath.isNotEmpty) {
      final f = File(customDuckDbPath);
      final bak = File('$customDuckDbPath.migrated.bak');
      if (await f.exists() && !await bak.exists()) {
        return customDuckDbPath;
      }
      return null;
    }

    final supportDir = await getApplicationSupportDirectory();
    final primaryPath = p.join(
      supportDir.path,
      'mobile_ai_agent',
      legacyDbFileName,
    );
    final primaryBak = '$primaryPath.migrated.bak';
    if (await File(primaryBak).exists()) {
      log.info(
        '[DB-Migrate] Legacy DuckDB already migrated ($primaryBak exists)',
      );
      return null;
    }
    if (await File(primaryPath).exists()) {
      log.info('[DB-Migrate] Pending legacy DuckDB detected at: $primaryPath');
      return primaryPath;
    }

    // Check sibling desktop app-support directories (e.g. "TealKit" vs "TealKit AI")
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      try {
        final parentDir = supportDir.parent;
        for (final siblingName in const ['TealKit AI', 'TealKit', 'mobile_ai_agent']) {
          final candidate = p.join(
            parentDir.path,
            siblingName,
            'mobile_ai_agent',
            legacyDbFileName,
          );
          if (candidate == primaryPath) continue;
          if (await File(candidate).exists() &&
              !await File('$candidate.migrated.bak').exists()) {
            log.info(
              '[DB-Migrate] Pending legacy DuckDB detected in sibling support dir: $candidate',
            );
            await Directory(p.dirname(primaryPath)).create(recursive: true);
            await File(candidate).copy(primaryPath);
            final sibWal = File('$candidate.wal');
            if (await sibWal.exists()) {
              await sibWal.copy('$primaryPath.wal');
            }
            return primaryPath;
          }
        }
      } catch (_) {}
    }

    // Also check very old legacy Documents directory location
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final legacyDocsPath = p.join(
        docsDir.path,
        'mobile_ai_agent',
        legacyDbFileName,
      );
      if (await File(legacyDocsPath).exists() &&
          !await File('$legacyDocsPath.migrated.bak').exists()) {
        log.info(
          '[DB-Migrate] Pending legacy DuckDB detected in Documents: $legacyDocsPath',
        );
        await Directory(p.dirname(primaryPath)).create(recursive: true);
        await File(legacyDocsPath).copy(primaryPath);
        final legacyWal = File('$legacyDocsPath.wal');
        if (await legacyWal.exists()) {
          await legacyWal.copy('$primaryPath.wal');
        }
        return primaryPath;
      }
    } catch (_) {}

    log.info(
      '[DB-Migrate] No legacy DuckDB found at $primaryPath (fresh install or clean storage)',
    );
    return null;
  }

  static Future<bool> hasPendingMigration({String? customDuckDbPath}) async {
    final path = await findPendingLegacyDuckDbPath(
      customDuckDbPath: customDuckDbPath,
    );
    return path != null;
  }

  /// Runs the offline DuckDB -> SQLite metadata migration and frees DuckDB immediately.
  static Future<DatabaseMigrationReport> migrate({
    String? customDuckDbPath,
    SqliteService? targetSqlite,
    void Function(String step)? onProgress,
  }) async {
    final duckPath = await findPendingLegacyDuckDbPath(
      customDuckDbPath: customDuckDbPath,
    );
    if (duckPath == null) {
      throw StateError('No unmigrated legacy DuckDB database found.');
    }

    final sqlite = targetSqlite ?? SqliteService();
    if (!sqlite.isInitialized) {
      await sqlite.init();
    }

    onProgress?.call('Opening legacy DuckDB database...');
    log.info('[DB-Migrate] Opening legacy DuckDB at: $duckPath');

    ddb.Database? duckDb;
    ddb.Connection? duckConn;

    int tasksCount = 0;
    int mcpCount = 0;
    int skillsCount = 0;
    int subagentsCount = 0;
    int pyToolsCount = 0;
    int githubMcpsCount = 0;
    int toolSkillsCount = 0;
    int sysMetaCount = 0;

    try {
      Future<void> openDuck() async {
        duckDb = await ddb.duckdb.open(duckPath);
        duckConn = await ddb.duckdb.connect(duckDb!);
      }

      try {
        await openDuck();
      } catch (e) {
        final msg = e.toString().toLowerCase();
        if (msg.contains('failure while replaying wal') ||
            msg.contains('databasemanager::getdefaultdatabase') ||
            msg.contains('.duckdb.wal')) {
          log.warning('[DB-Migrate] WAL replay error; archiving corrupt WAL: $e');
          final wal = File('$duckPath.wal');
          if (await wal.exists()) {
            await wal.rename(
              '$duckPath.wal.corrupt.${DateTime.now().millisecondsSinceEpoch}',
            );
          }
          await openDuck();
        } else if (msg.contains('lock') || msg.contains('already opened')) {
          final lockFile = File('$duckPath.lock');
          if (await lockFile.exists()) {
            await lockFile.delete();
          }
          await openDuck();
        } else {
          rethrow;
        }
      }

      final conn = duckConn!;

      onProgress?.call('Reading workflows & MCP configurations...');
      final taskRows = await _safeQuery(
        conn,
        'SELECT id, name, enabled, agent_id, to_json(tags), CAST(data AS VARCHAR), '
        'CAST(created_at AS VARCHAR), CAST(updated_at AS VARCHAR) FROM tasks',
      );

      final mcpRows = await _safeQuery(
        conn,
        'SELECT id, task_id, mcp_type, CAST(params AS VARCHAR), enabled, '
        'CAST(created_at AS VARCHAR), CAST(updated_at AS VARCHAR) FROM internal_mcp_configs',
      );

      onProgress?.call('Reading skills & specialized sub-agents...');
      final skillRows = await _safeQuery(
        conn,
        'SELECT id, name, goal, description, skill_def, to_json(tool_names), '
        'CAST(created_at AS VARCHAR), CAST(updated_at AS VARCHAR) FROM skill_defs',
      );

      final subagentRows = await _safeQuery(
        conn,
        'SELECT key, name, description, model, system_prompt, tools_json, '
        'max_turns, CAST(created_at AS VARCHAR), CAST(updated_at AS VARCHAR) '
        'FROM subagent_definitions',
      );

      onProgress?.call('Reading Python tools, MCP servers & tool hints...');
      final pyToolRows = await _safeQuery(
        conn,
        'SELECT id, name, description, CAST(input_schema AS VARCHAR), code, '
        'requirements, venv_ready, is_active, generation_prompt, '
        'CAST(created_at AS VARCHAR), CAST(updated_at AS VARCHAR) FROM py_tools',
      );

      final githubMcpRows = await _safeQuery(
        conn,
        'SELECT id, name, display_name, description, github_url, language, '
        'install_type, package_name, entry_point, CAST(launch_args AS VARCHAR), '
        'CAST(required_env_vars AS VARCHAR), CAST(env_vars AS VARCHAR), category, '
        'is_installed, is_active, is_manual, CAST(installed_at AS VARCHAR), '
        'CAST(created_at AS VARCHAR) FROM github_mcp_servers',
      );

      final toolSkillRows = await _safeQuery(
        conn,
        'SELECT id, tool_name, mcp_type, skill_text, skill_text_slm, '
        'is_enabled, is_custom, CAST(generated_at AS VARCHAR), '
        'CAST(updated_at AS VARCHAR) FROM tool_skills',
      );

      final sysMetaRows = await _safeQuery(
        conn,
        'SELECT key, value FROM _sys_meta',
      );

      onProgress?.call('Writing migrated records to SQLite...');
      final nowIso = DateTime.now().toIso8601String();

      sqlite.runInTransaction((sq) {
        for (final r in taskRows) {
          if (r.isEmpty || r[0] == null) continue;
          sq.execute(
            '''
            INSERT OR REPLACE INTO tasks
              (id, name, enabled, agent_id, tags, data, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ''',
            [
              r[0].toString(),
              r[1]?.toString() ?? '',
              _boolToInt(r[2], defaultValue: 1),
              r[3]?.toString(),
              _normalizeJsonListStr(r[4]),
              _normalizeJsonMapStr(r[5]),
              r[6]?.toString() ?? nowIso,
              r[7]?.toString() ?? nowIso,
            ],
          );
          tasksCount++;
        }

        for (final r in mcpRows) {
          if (r.isEmpty || r[0] == null) continue;
          sq.execute(
            '''
            INSERT OR REPLACE INTO internal_mcp_configs
              (id, task_id, mcp_type, params, enabled, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ''',
            [
              r[0].toString(),
              r[1]?.toString() ?? '',
              r[2]?.toString() ?? '',
              _normalizeJsonMapStr(r[3]),
              _boolToInt(r[4], defaultValue: 1),
              r[5]?.toString() ?? nowIso,
              r[6]?.toString() ?? nowIso,
            ],
          );
          mcpCount++;
        }

        for (final r in skillRows) {
          if (r.isEmpty || r[0] == null) continue;
          sq.execute(
            '''
            INSERT OR REPLACE INTO skill_defs
              (id, name, goal, description, skill_def, tool_names, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ''',
            [
              r[0].toString(),
              r[1]?.toString() ?? '',
              r[2]?.toString() ?? '',
              r[3]?.toString() ?? '',
              r[4]?.toString() ?? '',
              _normalizeJsonListStr(r[5]),
              r[6]?.toString() ?? nowIso,
              r[7]?.toString() ?? nowIso,
            ],
          );
          skillsCount++;
        }

        for (final r in subagentRows) {
          if (r.isEmpty || r[0] == null) continue;
          sq.execute(
            '''
            INSERT OR REPLACE INTO subagent_definitions
              (key, name, description, model, system_prompt, tools_json,
               max_turns, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ''',
            [
              r[0].toString(),
              r[1]?.toString() ?? '',
              r[2]?.toString() ?? '',
              r[3]?.toString() ?? 'default',
              r[4]?.toString() ?? '',
              _normalizeJsonListStr(r[5]),
              (r[6] as num?)?.toInt() ?? 8,
              r[7]?.toString() ?? nowIso,
              r[8]?.toString() ?? nowIso,
            ],
          );
          subagentsCount++;
        }

        for (final r in pyToolRows) {
          if (r.isEmpty || r[0] == null) continue;
          sq.execute(
            '''
            INSERT OR REPLACE INTO py_tools
              (id, name, description, input_schema, code, requirements,
               venv_ready, is_active, generation_prompt, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ''',
            [
              r[0].toString(),
              r[1]?.toString() ?? '',
              r[2]?.toString() ?? '',
              _normalizeJsonMapStr(r[3]),
              r[4]?.toString() ?? '',
              r[5]?.toString() ?? '',
              _boolToInt(r[6]),
              _boolToInt(r[7], defaultValue: 1),
              r[8]?.toString() ?? '',
              r[9]?.toString() ?? nowIso,
              r[10]?.toString() ?? nowIso,
            ],
          );
          pyToolsCount++;
        }

        for (final r in githubMcpRows) {
          if (r.isEmpty || r[0] == null) continue;
          sq.execute(
            '''
            INSERT OR REPLACE INTO github_mcp_servers
              (id, name, display_name, description, github_url, language,
               install_type, package_name, entry_point, launch_args,
               required_env_vars, env_vars, category, is_installed, is_active,
               is_manual, installed_at, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ''',
            [
              r[0].toString(),
              r[1]?.toString() ?? '',
              r[2]?.toString() ?? r[1]?.toString() ?? '',
              r[3]?.toString() ?? '',
              r[4]?.toString() ?? '',
              r[5]?.toString() ?? 'python',
              r[6]?.toString() ?? 'uvx',
              r[7]?.toString() ?? '',
              r[8]?.toString(),
              _normalizeJsonListStr(r[9]),
              _normalizeJsonListStr(r[10]),
              _normalizeJsonMapStr(r[11]),
              r[12]?.toString() ?? 'other',
              _boolToInt(r[13]),
              _boolToInt(r[14]),
              _boolToInt(r[15]),
              r[16]?.toString(),
              r[17]?.toString() ?? nowIso,
            ],
          );
          githubMcpsCount++;
        }

        for (final r in toolSkillRows) {
          if (r.isEmpty || r[0] == null) continue;
          sq.execute(
            '''
            INSERT OR REPLACE INTO tool_skills
              (id, tool_name, mcp_type, skill_text, skill_text_slm,
               is_enabled, is_custom, generated_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ''',
            [
              r[0].toString(),
              r[1]?.toString() ?? '',
              r[2]?.toString() ?? '',
              r[3]?.toString() ?? '',
              r[4]?.toString() ?? '',
              _boolToInt(r[5], defaultValue: 1),
              _boolToInt(r[6]),
              r[7]?.toString() ?? nowIso,
              r[8]?.toString() ?? nowIso,
            ],
          );
          toolSkillsCount++;
        }

        for (final r in sysMetaRows) {
          if (r.isEmpty || r[0] == null) continue;
          sq.execute(
            'INSERT OR REPLACE INTO _sys_meta (key, value) VALUES (?, ?)',
            [r[0].toString(), r[1]?.toString() ?? ''],
          );
          sysMetaCount++;
        }
      });
    } finally {
      onProgress?.call('Releasing DuckDB engine memory...');
      try {
        await duckConn?.dispose();
      } catch (_) {}
      try {
        await duckDb?.dispose();
      } catch (_) {}
    }

    onProgress?.call('Archiving legacy DuckDB file...');
    final backupPath = '$duckPath.migrated.bak';
    try {
      await File(duckPath).rename(backupPath);
    } catch (_) {
      await File(duckPath).copy(backupPath);
      try {
        await File(duckPath).delete();
      } catch (_) {}
    }

    for (final suffix in ['.wal', '.lock']) {
      final aux = File('$duckPath$suffix');
      if (await aux.exists()) {
        try {
          await aux.rename('$duckPath$suffix.migrated.bak');
        } catch (_) {}
      }
    }

    log.info(
      '[DB-Migrate] Completed DuckDB -> SQLite migration: '
      'tasks=$tasksCount skills=$skillsCount subagents=$subagentsCount '
      'mcpConfigs=$mcpCount pyTools=$pyToolsCount githubMcps=$githubMcpsCount',
    );

    return DatabaseMigrationReport(
      tasksMigrated: tasksCount,
      mcpConfigsMigrated: mcpCount,
      skillsMigrated: skillsCount,
      subagentsMigrated: subagentsCount,
      pyToolsMigrated: pyToolsCount,
      githubMcpsMigrated: githubMcpsCount,
      toolSkillsMigrated: toolSkillsCount,
      sysMetaMigrated: sysMetaCount,
      sourcePath: duckPath,
      backupPath: backupPath,
    );
  }

  static Future<List<List<dynamic>>> _safeQuery(
    ddb.Connection conn,
    String sql,
  ) async {
    try {
      final res = await conn.query(sql);
      return res.fetchAll();
    } catch (e) {
      log.verbose('[DB-Migrate] Skipping missing/empty table query: $e');
      return const [];
    }
  }

  static int _boolToInt(dynamic v, {int defaultValue = 0}) {
    if (v == null) return defaultValue;
    if (v is bool) return v ? 1 : 0;
    if (v is num) return v != 0 ? 1 : 0;
    final s = v.toString().toLowerCase();
    if (s == 'true' || s == '1') return 1;
    if (s == 'false' || s == '0') return 0;
    return defaultValue;
  }

  static String _normalizeJsonListStr(dynamic raw) {
    if (raw == null) return '[]';
    if (raw is List) {
      return jsonEncode(raw.map((e) => e.toString()).toList());
    }
    final str = raw.toString().trim();
    if (str.isEmpty || str == 'null') return '[]';
    try {
      final decoded = jsonDecode(str);
      if (decoded is List) return jsonEncode(decoded);
    } catch (_) {}
    return '[]';
  }

  static String _normalizeJsonMapStr(dynamic raw) {
    if (raw == null) return '{}';
    if (raw is Map) return jsonEncode(raw);
    final str = raw.toString().trim();
    if (str.isEmpty || str == 'null') return '{}';
    try {
      final decoded = jsonDecode(str);
      if (decoded is Map) return jsonEncode(decoded);
    } catch (_) {}
    return str;
  }
}
