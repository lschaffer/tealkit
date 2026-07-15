import '../database/task_database_service.dart';
import '../models/workflow_task.dart';
import 'i_task_repository.dart';

/// [ITaskRepository] backed by the local DuckDB database.
class LocalTaskRepository implements ITaskRepository {
  final TaskDatabaseService _db;

  LocalTaskRepository(this._db);

  @override
  Future<List<WorkflowTask>> getAllTasks({String? agentId, bool? enabledOnly}) =>
      _db.getAllTasks(agentId: agentId, enabledOnly: enabledOnly);

  @override
  Future<WorkflowTask?> getTask(String id) => _db.getTask(id);

  @override
  Future<void> saveTask(WorkflowTask task) => _db.saveTask(task);

  @override
  Future<void> deleteTask(String id) => _db.deleteTask(id);

  @override
  Future<void> toggleTask(String taskId, bool enabled) => _db.toggleTask(taskId, enabled);
}
