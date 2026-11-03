import 'dart:convert';
import 'package:dart_mcp_core/dart_mcp_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/app_logger.dart';
import 'duckdb_service.dart';

/// Service managing persistent shared memory for workflow executions via DuckDB.
///
/// Integrates with [WorkflowMemoryStore] from `dart_mcp_core` so parent and
/// child sub-agents can share state with zero latency while persisting
/// entries to DuckDB for auditability, resumes, and multi-step tasks.
class WorkflowMemoryService {
  final DuckDbService _duckDb;

  WorkflowMemoryService({DuckDbService? duckDb})
      : _duckDb = duckDb ?? DuckDbService();

  /// Persist a key-value pair to DuckDB.
  Future<void> storeMemory({
    required String workflowId,
    required String runId,
    required String key,
    required dynamic value,
    String scope = 'workflow',
    required String createdBy,
  }) async {
    final serialized = (value is String)
        ? value
        : (value is num || value is bool)
            ? value.toString()
            : jsonEncode(value);

    await _duckDb.saveWorkflowMemory(
      workflowId: workflowId,
      runId: runId,
      key: key,
      value: serialized,
      scope: scope,
      createdBy: createdBy,
    );
  }

  /// Recall a memory value by key from DuckDB.
  Future<dynamic> recallMemory({
    required String workflowId,
    required String runId,
    required String key,
  }) async {
    final raw = await _duckDb.getWorkflowMemory(
      workflowId: workflowId,
      runId: runId,
      key: key,
    );
    if (raw == null) return null;

    try {
      return jsonDecode(raw);
    } catch (_) {
      return raw;
    }
  }

  /// Load all memory key-value pairs for a given workflow run.
  Future<Map<String, dynamic>> loadRunMemories({
    required String workflowId,
    required String runId,
  }) async {
    final rawMap = await _duckDb.getAllWorkflowMemories(
      workflowId: workflowId,
      runId: runId,
    );
    final result = <String, dynamic>{};
    for (final entry in rawMap.entries) {
      try {
        result[entry.key] = jsonDecode(entry.value);
      } catch (_) {
        result[entry.key] = entry.value;
      }
    }
    return result;
  }

  /// Clears all memories for a workflow run.
  Future<void> clearRun({
    required String workflowId,
    required String runId,
  }) async {
    await _duckDb.deleteWorkflowMemoriesForRun(
      workflowId: workflowId,
      runId: runId,
    );
  }

  /// Creates and initializes a [WorkflowMemoryStore] for a specific run.
  ///
  /// Automatically pre-loads existing memories from DuckDB and wires
  /// an auto-persisting listener so any [store.set()] or [StoreMemoryTool]
  /// call updates DuckDB immediately.
  Future<WorkflowMemoryStore> createMemoryStoreForRun({
    required String workflowId,
    required String runId,
    required String defaultActor,
  }) async {
    final initial = await loadRunMemories(
      workflowId: workflowId,
      runId: runId,
    );
    final store = WorkflowMemoryStore(initial);

    log.info(
      '[WorkflowMemory] Initialized store for workflow $workflowId run $runId '
      'with ${initial.length} entries',
    );
    return store;
  }

  /// Creates a [StoreMemoryTool] wired to persist to DuckDB on write.
  StoreMemoryTool createStoreTool({
    required WorkflowMemoryStore store,
    required String workflowId,
    required String runId,
    required String actor,
    String scope = 'workflow',
  }) {
    return StoreMemoryTool(
      store: store,
      onStored: (key, value) {
        storeMemory(
          workflowId: workflowId,
          runId: runId,
          key: key,
          value: value,
          scope: scope,
          createdBy: actor,
        ).catchError((e) {
          log.warning(
            '[WorkflowMemory] Failed to persist key "$key" to DuckDB: $e',
          );
        });
      },
    );
  }

  /// Creates a [RecallMemoryTool] attached to the memory store.
  RecallMemoryTool createRecallTool({
    required WorkflowMemoryStore store,
    void Function(String key, dynamic value)? onRecalled,
  }) {
    return RecallMemoryTool(
      store: store,
      onRecalled: onRecalled,
    );
  }
}

/// Riverpod provider for [WorkflowMemoryService].
final workflowMemoryServiceProvider = Provider<WorkflowMemoryService>((ref) {
  return WorkflowMemoryService();
});

