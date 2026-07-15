import '../models/workflow_task.dart';
import '../services/server_api_client.dart';
import 'i_task_repository.dart';

/// [ITaskRepository] backed by the TealKit server REST API.
class RemoteTaskRepository implements ITaskRepository {
  final ServerApiClient _client;

  RemoteTaskRepository(this._client);

  @override
  Future<List<WorkflowTask>> getAllTasks({String? agentId, bool? enabledOnly}) async {
    final all = await _client.getAllTasks();
    var result = all;
    if (agentId != null) result = result.where((t) => t.agentId == agentId).toList();
    if (enabledOnly == true) result = result.where((t) => t.enabled).toList();
    return result;
  }

  @override
  Future<WorkflowTask?> getTask(String id) => _client.getTask(id);

  @override
  Future<void> saveTask(WorkflowTask task) => _client.saveTask(task);

  @override
  Future<void> deleteTask(String id) => _client.deleteTask(id);

  @override
  Future<void> toggleTask(String taskId, bool enabled) => _client.toggleTask(taskId, enabled);
}
