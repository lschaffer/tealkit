import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/duckdb_service.dart';
import '../database/task_database_service.dart';
import '../models/workflow_task.dart';
import '../repositories/i_task_repository.dart';
import '../repositories/local_task_repository.dart';
import '../repositories/remote_task_repository.dart';
import 'server_mode_provider.dart';

// ──────────────────────────────────────────────
// Service providers (singletons via Riverpod)
// ──────────────────────────────────────────────

/// Provides the DuckDB service singleton.
/// Keeps the singleton pattern but makes it injectable/testable.
final duckDbServiceProvider = Provider<DuckDbService>((ref) {
  return DuckDbService();
});

/// Provides the task database service singleton.
final taskDatabaseServiceProvider = Provider<TaskDatabaseService>((ref) {
  return TaskDatabaseService();
});

/// Provides the active [ITaskRepository] — local or remote depending on
/// [serverModeProvider].
final taskRepositoryProvider = Provider<ITaskRepository>((ref) {
  final modeAsync = ref.watch(serverModeProvider);
  return modeAsync.when(
    data: (state) {
      if (state.isRemote) {
        final client = ref.watch(serverApiClientProvider);
        if (client != null) return RemoteTaskRepository(client);
      }
      return LocalTaskRepository(ref.read(taskDatabaseServiceProvider));
    },
    loading: () => LocalTaskRepository(ref.read(taskDatabaseServiceProvider)),
    error: (e, st) => LocalTaskRepository(ref.read(taskDatabaseServiceProvider)),
  );
});

// ──────────────────────────────────────────────
// Task list provider (reactive async state)
// ──────────────────────────────────────────────

/// Async provider for the task list.
/// Automatically handles loading, error, and data states.
/// Call `ref.invalidate(taskListProvider)` to trigger a reload.
final taskListProvider = AsyncNotifierProvider<TaskListNotifier, List<WorkflowTask>>(TaskListNotifier.new);

class TaskListNotifier extends AsyncNotifier<List<WorkflowTask>> {
  @override
  Future<List<WorkflowTask>> build() async {
    final repo = ref.watch(taskRepositoryProvider);
    return repo.getAllTasks();
  }

  /// Save (create or update) a task, then refresh the list.
  Future<void> saveTask(WorkflowTask task) async {
    final repo = ref.read(taskRepositoryProvider);
    await repo.saveTask(task);
    ref.invalidateSelf();
  }

  /// Delete a task, then refresh the list.
  Future<void> deleteTask(String id) async {
    final repo = ref.read(taskRepositoryProvider);
    await repo.deleteTask(id);
    ref.invalidateSelf();
  }

  /// Toggle enabled/disabled, then refresh the list.
  Future<void> toggleTask(String taskId, bool enabled) async {
    final repo = ref.read(taskRepositoryProvider);
    await repo.toggleTask(taskId, enabled);
    ref.invalidateSelf();
  }

  /// Force-refresh the task list.
  Future<void> refresh() async {
    ref.invalidateSelf();
  }
}
