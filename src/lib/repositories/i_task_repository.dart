import '../models/workflow_task.dart';

/// Abstract interface for task persistence.
///
/// Both [LocalTaskRepository] (DuckDB) and [RemoteTaskRepository] (HTTP API)
/// implement this contract so that Riverpod providers can switch between them
/// transparently.
abstract class ITaskRepository {
  Future<List<WorkflowTask>> getAllTasks({String? agentId, bool? enabledOnly});
  Future<WorkflowTask?> getTask(String id);
  Future<void> saveTask(WorkflowTask task);
  Future<void> deleteTask(String id);
  Future<void> toggleTask(String taskId, bool enabled);
}
