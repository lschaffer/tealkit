import 'dart:convert';
import 'dart:io';

import 'package:dart_duckdb/dart_duckdb.dart' as ddb;
import 'package:dart_duckdb/open.dart' as ddb_open;
import 'package:path/path.dart' as p;

import '../utils/server_logger.dart';
import 'server_sqlite_adapter.dart';

/// Silent one-time Release-1 bridge migrator for headless TealKit Server:
/// migrates `tealkit_server.duckdb` -> `tealkit_server.sqlite` on startup,
/// skips `document_index` & `website_index`, immediately frees DuckDB, and
/// archives `tealkit_server.duckdb` -> `tealkit_server.duckdb.migrated.bak`.
class ServerLegacyDuckDbMigrator {
  ServerLegacyDuckDbMigrator._();

  static const String legacyDbFileName = 'tealkit_server.duckdb';

  static void configureDuckDbLibrary() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final cwd = Directory.current.path;
    if (Platform.isWindows) {
      final candidates = <String>[
        p.join(exeDir, 'duckdb.dll'),
        p.join(cwd, 'duckdb.dll'),
        p.join(cwd, '..', 'third_party', 'dart_duckdb', 'windows', 'Libraries', 'release', 'duckdb.dll'),
        p.join(cwd, 'third_party', 'dart_duckdb', 'windows', 'Libraries', 'release', 'duckdb.dll'),
      ];
      for (final c in candidates) {
        if (File(c).existsSync()) {
          ddb_open.open.overrideFor(ddb.OperatingSystem.windows, p.normalize(c));
          break;
        }
      }
    } else if (Platform.isLinux) {
      final candidates = <String>[
        '/app/libduckdb.so',
        p.join(exeDir, 'libduckdb.so'),
        p.join(exeDir, '..', 'libduckdb.so'),
        p.join(cwd, '..', 'third_party', 'dart_duckdb', 'linux', 'Libraries', 'release', 'libduckdb.so'),
        p.join(cwd, 'third_party', 'dart_duckdb', 'linux', 'Libraries', 'release', 'libduckdb.so'),
      ];
      for (final c in candidates) {
        if (File(c).existsSync()) {
          ddb_open.open.overrideFor(ddb.OperatingSystem.linux, p.normalize(c));
          break;
        }
      }
    }
  }

  static Future<void> migrateIfNeeded(
    ServerSqliteAdapter sqlite, {
    String? customDuckDbPath,
  }) async {
    configureDuckDbLibrary();
    final duckPath =
        customDuckDbPath ?? p.join(sqlite.dataDir, 'db', legacyDbFileName);
    final bakPath = '$duckPath.migrated.bak';

    if (await File(bakPath).exists()) {
      log.info('[Server-DB-Migrate] Legacy DuckDB already migrated ($bakPath)');
      return;
    }
    if (!await File(duckPath).exists()) {
      log.info(
        '[Server-DB-Migrate] No legacy DuckDB at $duckPath (using SQLite directly)',
      );
      return;
    }

    log.info(
      '[Server-DB-Migrate] Found legacy DuckDB at $duckPath — starting silent migration to SQLite...',
    );

    ddb.Database? duckDb;
    ddb.Connection? duckConn;

    int tasksCount = 0;
    int mcpCount = 0;
    int pyToolsCount = 0;
    int jsToolsCount = 0;
    int githubMcpsCount = 0;
    int schedLogCount = 0;
    int toolSkillsCount = 0;
    int skillsCount = 0;
    int sessionsCount = 0;
    int subagentsCount = 0;
    int llmProfilesCount = 0;

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
          log.warning(
            '[Server-DB-Migrate] Archiving corrupt DuckDB WAL and retrying: $e',
          );
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
      final pyToolRows = await _safeQuery(
        conn,
        'SELECT id, name, description, CAST(input_schema AS VARCHAR), code, '
        'requirements, venv_ready, is_active, generation_prompt, '
        'CAST(created_at AS VARCHAR), CAST(updated_at AS VARCHAR) FROM py_tools',
      );
      final jsToolRows = await _safeQuery(
        conn,
        'SELECT id, name, description, CAST(input_schema AS VARCHAR), js_code, '
        'is_active, CAST(created_at AS VARCHAR), CAST(updated_at AS VARCHAR) FROM js_tools',
      );
      final githubMcpRows = await _safeQuery(
        conn,
        'SELECT id, name, display_name, description, github_url, language, '
        'install_type, package_name, entry_point, CAST(launch_args AS VARCHAR), '
        'CAST(required_env_vars AS VARCHAR), CAST(env_vars AS VARCHAR), category, '
        'is_installed, is_active, is_manual, CAST(installed_at AS VARCHAR), '
        'CAST(created_at AS VARCHAR) FROM github_mcp_servers',
      );
      final schedLogRows = await _safeQuery(
        conn,
        'SELECT id, task_id, task_name, CAST(started_at AS VARCHAR), '
        'CAST(ended_at AS VARCHAR), success, message FROM scheduler_log ORDER BY started_at DESC LIMIT 500',
      );
      final toolSkillRows = await _safeQuery(
        conn,
        'SELECT id, tool_name, mcp_type, skill_text, skill_text_slm, '
        'is_enabled, is_custom, CAST(generated_at AS VARCHAR), '
        'CAST(updated_at AS VARCHAR) FROM tool_skills',
      );
      final skillRows = await _safeQuery(
        conn,
        'SELECT id, name, goal, description, skill_def, to_json(tool_names), '
        'CAST(created_at AS VARCHAR), CAST(updated_at AS VARCHAR) FROM skill_defs',
      );
      final sessionRows = await _safeQuery(
        conn,
        'SELECT id, name, mode, CAST(data AS VARCHAR), CAST(created_at AS VARCHAR) '
        'FROM playground_sessions',
      );
      final subagentRows = await _safeQuery(
        conn,
        'SELECT key, name, description, model, system_prompt, tools_json, '
        'max_turns, CAST(created_at AS VARCHAR), CAST(updated_at AS VARCHAR) '
        'FROM subagent_definitions',
      );
      final llmProfileRows = await _safeQuery(
        conn,
        'SELECT id, name, is_selected, CAST(data AS VARCHAR), sort_order, '
        'CAST(created_at AS VARCHAR), CAST(updated_at AS VARCHAR) FROM llm_profiles',
      );

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

        for (final r in jsToolRows) {
          if (r.isEmpty || r[0] == null) continue;
          sq.execute(
            '''
            INSERT OR REPLACE INTO js_tools
              (id, name, description, input_schema, js_code, is_active, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ''',
            [
              r[0].toString(),
              r[1]?.toString() ?? '',
              r[2]?.toString() ?? '',
              _normalizeJsonMapStr(r[3]),
              r[4]?.toString() ?? '',
              _boolToInt(r[5], defaultValue: 1),
              r[6]?.toString() ?? nowIso,
              r[7]?.toString() ?? nowIso,
            ],
          );
          jsToolsCount++;
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

        for (final r in schedLogRows) {
          if (r.isEmpty || r[0] == null) continue;
          sq.execute(
            '''
            INSERT OR REPLACE INTO scheduler_log
              (id, task_id, task_name, started_at, ended_at, success, message)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ''',
            [
              r[0].toString(),
              r[1]?.toString() ?? '',
              r[2]?.toString() ?? '',
              r[3]?.toString() ?? nowIso,
              r[4]?.toString(),
              r[5] == null ? null : _boolToInt(r[5]),
              r[6]?.toString(),
            ],
          );
          schedLogCount++;
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

        for (final r in sessionRows) {
          if (r.isEmpty || r[0] == null) continue;
          sq.execute(
            '''
            INSERT OR REPLACE INTO playground_sessions
              (id, name, mode, data, created_at)
            VALUES (?, ?, ?, ?, ?)
            ''',
            [
              r[0].toString(),
              r[1]?.toString() ?? '',
              r[2]?.toString() ?? 'local',
              _normalizeJsonMapStr(r[3]),
              r[4]?.toString() ?? nowIso,
            ],
          );
          sessionsCount++;
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

        for (final r in llmProfileRows) {
          if (r.isEmpty || r[0] == null) continue;
          sq.execute(
            '''
            INSERT OR REPLACE INTO llm_profiles
              (id, name, is_selected, data, sort_order, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ''',
            [
              r[0].toString(),
              r[1]?.toString() ?? '',
              _boolToInt(r[2]),
              _normalizeJsonMapStr(r[3]),
              (r[4] as num?)?.toInt() ?? 0,
              r[5]?.toString() ?? nowIso,
              r[6]?.toString() ?? nowIso,
            ],
          );
          llmProfilesCount++;
        }
      });
    } finally {
      try {
        await duckConn?.dispose();
      } catch (_) {}
      try {
        await duckDb?.dispose();
      } catch (_) {}
      duckConn = null;
      duckDb = null;
    }

    try {
      await File(duckPath).rename(bakPath);
    } catch (_) {
      await File(duckPath).copy(bakPath);
      try {
        await File(duckPath).delete();
      } catch (_) {}
    }

    final walFile = File('$duckPath.wal');
    if (await walFile.exists()) {
      try {
        await walFile.rename('$duckPath.wal.migrated.bak');
      } catch (_) {}
    }
    final lockFile = File('$duckPath.lock');
    if (await lockFile.exists()) {
      try {
        await lockFile.delete();
      } catch (_) {}
    }

    log.info(
      '[Server-DB-Migrate] Completed silent DuckDB -> SQLite migration: '
      'tasks=$tasksCount llmProfiles=$llmProfilesCount skills=$skillsCount '
      'subagents=$subagentsCount mcpConfigs=$mcpCount pyTools=$pyToolsCount '
      'jsTools=$jsToolsCount githubMcps=$githubMcpsCount sessions=$sessionsCount '
      'toolSkills=$toolSkillsCount schedLogs=$schedLogCount',
    );
  }

  static Future<List<List<dynamic>>> _safeQuery(
    ddb.Connection conn,
    String sql,
  ) async {
    try {
      final res = await conn.query(sql);
      try {
        return res.fetchAll();
      } finally {
        await res.dispose();
      }
    } catch (e) {
      final msg = e.toString().toLowerCase();
      if (msg.contains('does not exist') || msg.contains('catalog error')) {
        return const [];
      }
      log.warning('[Server-DB-Migrate] Query skipped ($sql): $e');
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

  static String _normalizeJsonListStr(dynamic v) {
    if (v == null) return '[]';
    if (v is List) return jsonEncode(v);
    final s = v.toString().trim();
    if (s.isEmpty || s.toLowerCase() == 'null') return '[]';
    try {
      final dec = jsonDecode(s);
      if (dec is List) return jsonEncode(dec);
    } catch (_) {}
    return '[]';
  }

  static String _normalizeJsonMapStr(dynamic v) {
    if (v == null) return '{}';
    if (v is Map) return jsonEncode(v);
    final s = v.toString().trim();
    if (s.isEmpty || s.toLowerCase() == 'null') return '{}';
    try {
      final dec = jsonDecode(s);
      if (dec is Map) return jsonEncode(dec);
    } catch (_) {}
    return s;
  }
}
