import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/duckdb_service.dart';
import '../models/subagent_definition.dart';
import '../providers/server_mode_provider.dart';
import 'app_logger.dart';
import 'server_api_client.dart';

/// Database and remote sync service for Specialized Sub-Agents.
class SubAgentDatabaseService {
  SubAgentDatabaseService._();
  static final instance = SubAgentDatabaseService._();

  static Object? _appContext;

  /// Call once during app startup to enable server-mode routing.
  static void init(dynamic context) {
    _appContext = context;
  }

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

  /// Get all configured subagents from local DuckDB or remote server.
  Future<List<SubAgentDefinition>> getAllSubagents({bool autoSeedPredefined = true}) async {
    final client = _getServerClient();
    if (client != null) {
      try {
        final list = await client.getAllSubagents();
        return list.map((j) => SubAgentDefinition.fromJson(j)).toList();
      } catch (e) {
        log.warning('[SubAgentDB] Remote getAllSubagents failed: $e');
        return [];
      }
    }

    try {
      final db = DuckDbService();
      final rows = await db.getSubagentDefinitions();
      if (rows.isEmpty && autoSeedPredefined) {
        await seedSampleSubagents();
        final seededRows = await db.getSubagentDefinitions();
        return seededRows.map((m) => SubAgentDefinition.fromJson(m)).toList();
      }
      return rows.map((m) => SubAgentDefinition.fromJson(m)).toList();
    } catch (e) {
      log.warning('[SubAgentDB] getAllSubagents failed: $e');
      return [];
    }
  }

  /// Save or update a subagent definition.
  Future<void> saveSubagent(SubAgentDefinition def) async {
    final client = _getServerClient();
    if (client != null) {
      try {
        await client.saveSubagent(def.toJson());
        return;
      } catch (e) {
        log.warning('[SubAgentDB] Remote saveSubagent failed: $e');
      }
    }

    final db = DuckDbService();
    await db.saveSubagentDefinition(def.toJson());
  }

  /// Delete a subagent by key.
  Future<void> deleteSubagent(String key) async {
    final client = _getServerClient();
    if (client != null) {
      try {
        await client.deleteSubagent(key);
        return;
      } catch (e) {
        log.warning('[SubAgentDB] Remote deleteSubagent failed: $e');
      }
    }

    final db = DuckDbService();
    await db.deleteSubagentDefinition(key);
  }

  /// Seeds all predefined sample sub-agents into the database.
  Future<int> seedSampleSubagents() async {
    final client = _getServerClient();
    if (client != null) {
      try {
        return await client.seedSampleSubagents();
      } catch (e) {
        log.warning('[SubAgentDB] Remote seedSampleSubagents failed: $e');
      }
    }

    final db = DuckDbService();
    final existing = await db.getSubagentDefinitions();
    final existingKeys = existing.map((e) => e['key'].toString().toLowerCase()).toSet();
    int added = 0;

    for (final sample in SubAgentDefinition.predefined) {
      if (!existingKeys.contains(sample.key.toLowerCase())) {
        await db.saveSubagentDefinition(sample.toJson());
        added++;
      }
    }
    return added;
  }
}

/// Riverpod provider for reactive subagent listing.
final subagentsListProvider =
    AsyncNotifierProvider<SubAgentsListNotifier, List<SubAgentDefinition>>(
  SubAgentsListNotifier.new,
);

class SubAgentsListNotifier extends AsyncNotifier<List<SubAgentDefinition>> {
  @override
  Future<List<SubAgentDefinition>> build() async {
    return SubAgentDatabaseService.instance.getAllSubagents();
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(
      () => SubAgentDatabaseService.instance.getAllSubagents(),
    );
  }

  Future<void> save(SubAgentDefinition def) async {
    await SubAgentDatabaseService.instance.saveSubagent(def);
    await refresh();
  }

  Future<void> remove(String key) async {
    await SubAgentDatabaseService.instance.deleteSubagent(key);
    await refresh();
  }

  Future<int> generateSamples() async {
    final count = await SubAgentDatabaseService.instance.seedSampleSubagents();
    await refresh();
    return count;
  }
}

