import '../database/task_database_service_duckdb.dart';
import '../models/workflow_task.dart';
import '../services/app_logger.dart';
import '../services/llm_settings_service.dart';

/// Utility that re-syncs the LLM 2 snapshot stored inside each task with the
/// current global LLM 2 settings.
///
/// Tasks that use `provider == 'llm2'` store a point-in-time snapshot of the
/// LLM 2 config (model, API key, base URL, temperature, …) at the moment they
/// were last edited.  When the user later changes LLM 2 or restores a vault,
/// those snapshots go stale and tasks run with the wrong model.
///
/// Call [resyncLlm2Tasks] after any operation that modifies the global LLM 2
/// settings (LLM settings dialog save, vault restore).  The method updates
/// every affected task silently — no user confirmation required — and logs
/// which tasks were changed.
class LlmTaskResyncService {
  LlmTaskResyncService._();

  /// Scans all local tasks and updates those configured with LLM 2 to reflect
  /// the current global LLM 2 settings.
  ///
  /// Returns the number of tasks that were updated.
  static Future<int> resyncLlm2Tasks() async {
    final llm = LlmSettingsService.instance;

    if (!llm.isConfigured2) {
      log.info('[LlmResync] LLM 2 not configured — skipping resync');
      return 0;
    }

    final db = TaskDatabaseService();
    final List<WorkflowTask> tasks;
    try {
      tasks = await db.getAllTasks();
    } catch (e) {
      log.warning('[LlmResync] Failed to load tasks: $e');
      return 0;
    }

    int count = 0;
    for (final task in tasks) {
      if (task.llmConfig?.provider != 'llm2') continue;

      final updatedConfig = TaskLlmConfig(
        provider: 'llm2',
        model: llm.model2,
        apiKey: llm.apiKey2.isNotEmpty ? llm.apiKey2 : null,
        baseUrl: llm.baseUrl2.isNotEmpty ? llm.baseUrl2 : null,
        temperature: llm.temperature2,
        maxTokens: llm.maxTokens2,
        extraParams: task.llmConfig!.extraParams,
      );

      final updated = task.copyWith(llmConfig: updatedConfig);
      try {
        await db.saveTask(updated);
        log.info('[LlmResync] Updated LLM 2 config for task "${task.name}" (${task.id})');
        count++;
      } catch (e) {
        log.warning('[LlmResync] Failed to save task "${task.name}" (${task.id}): $e');
      }
    }

    if (count > 0) {
      log.info(
        '[LlmResync] Done — $count task(s) updated with current LLM 2 settings '
        '(${llm.provider2.configKey} / ${llm.model2})',
      );
    } else {
      log.info('[LlmResync] No tasks using LLM 2 found');
    }

    return count;
  }
}
