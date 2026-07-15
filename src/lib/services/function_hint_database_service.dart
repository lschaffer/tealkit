import '../database/duckdb_service.dart';
import '../models/function_hint.dart';
import 'app_logger.dart';

/// Thin service layer over [DuckDbService] for [FunctionHint] CRUD.
///
/// Usage:
/// ```dart
/// final svc = FunctionHintDatabaseService();
/// await svc.save(skill);
/// final list = await svc.getAll();
/// ```
class FunctionHintDatabaseService {
  // ── Singleton ──────────────────────────────────────────────────────────
  static final FunctionHintDatabaseService _instance = FunctionHintDatabaseService._();
  factory FunctionHintDatabaseService() => _instance;
  FunctionHintDatabaseService._();

  final DuckDbService _db = DuckDbService();

  // ──────────────────────────────────────────────────────────────────────

  Future<void> save(FunctionHint skill) async {
    try {
      await _db.saveToolSkill(
        id: skill.id,
        toolName: skill.toolName,
        mcpType: skill.mcpType,
        skillText: skill.skillText,
        skillTextSlm: skill.skillTextSlm,
        isEnabled: skill.isEnabled,
        isCustom: skill.isCustom,
      );
    } catch (e, st) {
      log.warning('[SkillDB] save failed for ${skill.toolName}: $e $st');
      rethrow;
    }
  }

  Future<List<FunctionHint>> getAll({String? mcpType}) async {
    final rows = await _db.getAllToolSkills(mcpType: mcpType);
    return rows.map(_fromRow).toList();
  }

  /// Returns only enabled skills whose tool name appears in [toolNames].
  Future<List<FunctionHint>> getEnabledForTools(List<String> toolNames) async {
    if (toolNames.isEmpty) return [];
    final rows = await _db.getEnabledSkillsForTools(toolNames);
    final list = rows.map(_fromRow).toList();
    final seen = <String>{};
    return list.where((s) => seen.add(s.toolName)).toList();
  }

  /// Returns the set of tool names that already have a DB record.
  Future<Set<String>> getExistingToolNames() => _db.getToolNamesWithSkills();

  Future<void> delete(String id) => _db.deleteToolSkill(id);

  Future<void> deleteByToolName(String toolName) => _db.deleteToolSkillsByToolName(toolName);

  /// Exports all skills as a list of JSON maps (for vault backup).
  Future<List<Map<String, dynamic>>> exportToJson() async {
    final all = await getAll();
    return all.map((s) => s.toJson()).toList();
  }

  /// Imports skills from a list of JSON maps (from vault restore).
  /// Upserts each record so existing skills are overwritten.
  Future<void> importFromJson(List<Map<String, dynamic>> records) async {
    for (final r in records) {
      try {
        final skill = FunctionHint.fromJson(r);
        await save(skill);
      } catch (e) {
        log.warning('[SkillDB] importFromJson: skipping record due to error: $e');
      }
    }
  }

  // ──────────────────────────────────────────────────────────────────────
  FunctionHint _fromRow(Map<String, dynamic> r) => FunctionHint.fromJson(r);
}
