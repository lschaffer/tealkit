import 'package:uuid/uuid.dart';

import '../models/workflow_task.dart';
import '../services/app_logger.dart';
import 'task_database_service.dart';

/// Seeds the database with pre-configured test tasks.
///
/// Call [seedIfEmpty] to insert test tasks only when the DB is empty,
/// or [seedTestWeatherTask] to always insert a weather test task.
class TestTaskSeeder {
  final _db = TaskDatabaseService();

  /// Insert test tasks only if the database is empty.
  Future<bool> seedIfEmpty() async {
    final count = await _db.countTasks();
    if (count > 0) {
      log.info('[Seeder] DB already has $count tasks — skipping seed');
      return false;
    }
    return seedTestWeatherTask();
  }

  /// Create a "Get Weather in Current Location" test task with:
  ///   - Internal Weather MCP (location: current)
  ///   - Gemini LLM (gemini-2.5-flash)
  ///   - File output notification
  Future<bool> seedTestWeatherTask() async {
    try {
      final task = WorkflowTask(
        id: const Uuid().v4(),
        name: 'Get Current Weather — Current Location',
        description:
            'Test task: Fetches current weather for the current location using the '
            'built-in Weather MCP'
            'Results are saved to a local file.',
        systemPrompt:
            'You are a weather assistant. Use the weather tools to fetch '
            'current conditions and a short forecast for the current location. '
            'Present the results clearly with temperature (°C), wind speed '
            '(km/h), humidity (%), and precipitation probability. '
            'Include a brief natural-language summary.',
        prompt:
            'Get the current weather and today\'s forecast for the current location. '
            'Include temperature, wind, humidity, precipitation, and a short '
            'summary of conditions.',
        enabled: true,
        tags: ['test', 'weather', 'current_location'],

        // ── Schedule: every 6 hours ──
        executionPlan: const ExecutionPlan(
          cronExpression: '0 */6 * * *',
          timezone: 'Europe/Vienna',
          scheduleHint: 'Every 6 hours',
          retryOnFailure: true,
          maxRetries: 2,
          retryDelayMinutes: 5,
          executeImmediately: true,
        ),

        // ── LLM: Gemini 2.5 Flash ──
        llmConfig: const TaskLlmConfig(
          provider: 'gemini',
          model: 'gemini-2.5-flash',
          apiKey: '',
          temperature: 0.2,
          maxTokens: 8192,
          extraParams: {'n_ctx': 8192, 'timeout_seconds': 300},
        ),

        // ── Internal MCP: Weather with city=Graz ──
        internalMcps: [
          InternalMcpEntry(
            id: const Uuid().v4(),
            mcpType: 'weather',
            label: 'Weather — Current Location',
            initParams: {'location': 'current', 'timezone': 'Europe/Vienna'},
            enabled: true,
          ),
        ],

        // ── Output: save results to local file ──
        notification: const TaskNotification(download: DownloadNotification(fileNamePattern: 'weather_current_location_{date}.txt')),
      );

      await _db.saveTask(task);
      log.info('[Seeder] Test task created: "${task.name}" (id=${task.id})');
      return true;
    } catch (e, st) {
      log.error('[Seeder] Failed to seed test task: $e', st);
      return false;
    }
  }
}
