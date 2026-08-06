import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../database/duckdb_service.dart';
import '../models/skill_def.dart';
import '../providers/server_mode_provider.dart';
import 'app_logger.dart';
import 'server_api_client.dart';
import 'workflow_export_service.dart';

/// Handles CRUD operations for AgentSkills.io skill definitions.
///
/// In local mode: uses the local DuckDB `skill_defs` table.
/// In server/remote mode: routes through [ServerApiClient] to the remote server.
class SkillDefDatabaseService {
  SkillDefDatabaseService._();
  static final instance = SkillDefDatabaseService._();

  static final _log = log;

  /// Returns the current [ServerApiClient] if in server/remote mode, or null.
  static ServerApiClient? _getServerClient() {
    try {
      final container = ProviderScope.containerOf(_appContext as dynamic);
      final modeAsync = container.read(serverModeProvider);
      if (modeAsync.value?.isRemote == true) {
        return container.read(serverApiClientProvider);
      }
    } catch (_) {}
    return null;
  }

  static Object? _appContext;

  /// Call once during app startup to enable server-mode routing.
  static void init(dynamic context) {
    _appContext = context;
  }

  Future<List<SkillDef>> getAllSkills() async {
    final client = _getServerClient();
    if (client != null) {
      try {
        final raw = await client.getAllSkillDefs();
        return raw.map((j) => SkillDef.fromJson(j)).toList();
      } catch (e) {
        _log.warning('[SkillDef] Remote getAllSkills failed: $e');
        return [];
      }
    }

    try {
      final db = DuckDbService();
      final conn = await db.connection;
      final rows = (await conn.query(
        'SELECT * FROM skill_defs ORDER BY updated_at DESC',
      )).fetchAll();
      return rows
          .map(
            (r) => SkillDef.fromJson({
              'id': r[0] as String,
              'name': r[1] as String,
              'goal': r[2] as String? ?? '',
              'description': r[3] as String? ?? '',
              'skill_def': r[4] as String,
              'tool_names': (r[5] as List?)?.cast<String>() ?? [],
              'created_at': _toDateTimeStr(r[6]),
              'updated_at': _toDateTimeStr(r[7]),
            }),
          )
          .toList();
    } catch (e) {
      _log.warning('[SkillDef] getAllSkills failed: $e');
      return [];
    }
  }

  Future<SkillDef?> getSkill(String id) async {
    final client = _getServerClient();
    if (client != null) {
      try {
        final raw = await client.getSkillDef(id);
        if (raw == null) return null;
        return SkillDef.fromJson(raw);
      } catch (e) {
        _log.warning('[SkillDef] Remote getSkill failed: $e');
        return null;
      }
    }

    try {
      final db = DuckDbService();
      final conn = await db.connection;
      final rows = (await conn.query(
        "SELECT * FROM skill_defs WHERE id = '${_esc(id)}'",
      )).fetchAll();
      if (rows.isEmpty) return null;
      final r = rows.first;
      return SkillDef.fromJson({
        'id': r[0] as String,
        'name': r[1] as String,
        'goal': r[2] as String? ?? '',
        'description': r[3] as String? ?? '',
        'skill_def': r[4] as String,
        'tool_names': (r[5] as List?)?.cast<String>() ?? [],
        'created_at': _toDateTimeStr(r[6]),
        'updated_at': _toDateTimeStr(r[7]),
      });
    } catch (e) {
      _log.warning('[SkillDef] getSkill failed: $e');
      return null;
    }
  }

  Future<void> saveSkill(SkillDef skill) async {
    final client = _getServerClient();
    if (client != null) {
      try {
        await client.saveSkillDef(skill.toJson());
        _log.info('[SkillDef] Remote saved skill: ${skill.name}');
        return;
      } catch (e) {
        _log.warning('[SkillDef] Remote saveSkill failed: $e');
        rethrow;
      }
    }

    try {
      final db = DuckDbService();
      final conn = await db.connection;
      final now = DateTime.now().toUtc().toIso8601String();
      final toolNamesStr = skill.toolNames
          .map((t) => "'${_esc(t)}'")
          .join(', ');

      await conn.execute('''
        INSERT OR REPLACE INTO skill_defs (id, name, goal, description, skill_def, tool_names, created_at, updated_at)
        VALUES ('${_esc(skill.id)}', '${_esc(skill.name)}', '${_esc(skill.goal)}',
                '${_esc(skill.description)}', '${_esc(skill.skillDef)}',
                [$toolNamesStr], '${_esc(now)}', '${_esc(now)}')
      ''');
      _log.info('[SkillDef] Saved skill: ${skill.name} (${skill.id})');
    } catch (e) {
      _log.warning('[SkillDef] saveSkill failed: $e');
      rethrow;
    }
  }

  Future<void> deleteSkill(String id) async {
    final client = _getServerClient();
    if (client != null) {
      try {
        await client.deleteSkillDef(id);
        _log.info('[SkillDef] Remote deleted skill: $id');
        return;
      } catch (e) {
        _log.warning('[SkillDef] Remote deleteSkill failed: $e');
        rethrow;
      }
    }

    try {
      final db = DuckDbService();
      final conn = await db.connection;
      await conn.execute("DELETE FROM skill_defs WHERE id = '${_esc(id)}'");
      _log.info('[SkillDef] Deleted skill: $id');
    } catch (e) {
      _log.warning('[SkillDef] deleteSkill failed: $e');
      rethrow;
    }
  }

  /// Imports a skill from a `.md` or `.zip` file bytes.
  Future<SkillDef> importFromFile({
    required List<int> bytes,
    required String filename,
  }) async {
    final task = await WorkflowExportService.parseWorkflowFile(
      bytes: bytes,
      filename: filename,
    );

    final String fullContent;
    final nameLower = filename.toLowerCase();
    if (nameLower.endsWith('.md')) {
      fullContent = utf8.decode(bytes);
    } else {
      fullContent = task.systemPrompt ?? task.prompt;
    }

    final validationError = SkillDef.validateAgentskillsFormat(fullContent);
    if (validationError != null) {
      throw Exception(validationError);
    }

    final name = task.name.isNotEmpty ? task.name : _nameFromFilename(filename);

    // Prevent duplicate imports — check if a skill with this name already exists.
    final existing = await getAllSkills();
    final duplicate = existing.where(
      (s) => s.name.toLowerCase() == name.toLowerCase(),
    );
    if (duplicate.isNotEmpty) {
      throw Exception(
        'A skill named "$name" already exists (id: ${duplicate.first.id}). '
        'Delete the existing skill first to re-import.',
      );
    }

    final now = DateTime.now();
    final skill = SkillDef(
      id: const Uuid().v4(),
      name: name,
      goal: '',
      description: task.description ?? '',
      skillDef: fullContent,
      toolNames: task.internalMcps
          .where((m) => m.enabled)
          .map((m) => SkillDef.resolveToolAlias(m.mcpType))
          .toList(),
      createdAt: now,
      updatedAt: now,
    );

    await saveSkill(skill);
    return skill;
  }

  static String _nameFromFilename(String filename) {
    final base = filename.replaceAll(RegExp(r'\.[^.]+$'), '');
    return base.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '-').toLowerCase();
  }

  static String _toDateTimeStr(dynamic v) {
    if (v is DateTime) return v.toUtc().toIso8601String();
    if (v is String) return v;
    return DateTime.now().toUtc().toIso8601String();
  }

  static String _esc(String s) => s.replaceAll("'", "''");
}
