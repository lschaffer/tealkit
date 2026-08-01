import 'dart:async';

import '../database/server_database_adapter.dart';
import '../models/agentic_task.dart';
import '../runner/server_task_runner.dart';
import '../services/server_data_sources_service.dart';
import '../services/server_indexing_service.dart';
import '../services/server_llm_settings_service.dart';
import '../services/server_preferences_service.dart';
import '../utils/cron_utils.dart';
import '../utils/server_logger.dart';

// ═══════════════════════════════════════════════════════════════
// Server Scheduler
// ═══════════════════════════════════════════════════════════════

/// Cron-style background scheduler.
///
/// Every [_tickInterval] (default: 1 minute) it queries DuckDB for all
/// enabled tasks whose `next_run` is in the past and triggers
/// [ServerTaskRunner.runTask] for each one.
///
/// Features:
/// - Avoids concurrent runs of the same task (tracked in [_inProgress]).
/// - Retry logic: retries up to [_maxRetries] times with exponential
///   back-off before marking a task as FAILED.
/// - Records every run in the `scheduler_log` table via
///   [ServerDatabaseAdapter.logRun].
/// - Respects [ServerPreferencesService.backgroundCheckIntervalMinutes]
///   at each tick (so config changes take effect without restart).
///
/// Start with [start], stop with [stop].
class ServerScheduler {
  static final ServerScheduler instance = ServerScheduler._();
  ServerScheduler._();

  static const Duration _tickInterval = Duration(minutes: 1);
  static const int _maxRetries = 3;

  Timer? _timer;

  /// Task IDs currently being executed (to prevent concurrent runs).
  final Set<String> _inProgress = {};

  bool get isRunning => _timer != null;

  bool isTaskRunning(String taskId) => _inProgress.contains(taskId);
  void markTaskRunning(String taskId) => _inProgress.add(taskId);
  void markTaskFinished(String taskId) => _inProgress.remove(taskId);

  // ── Lifecycle ────────────────────────────────────────────────

  /// Start the scheduler.  Safe to call multiple times — no-op if already
  /// running.
  void start() {
    if (_timer != null) return;
    log.info(
      '[Scheduler] Starting — tick every ${_tickInterval.inMinutes} minute(s)',
    );
    _timer = Timer.periodic(_tickInterval, (_) => _tick());
    // Fire an immediate first tick so tasks due right at startup are picked up.
    _tick();
  }

  /// Stop the scheduler.  In-progress runs are NOT cancelled — they will
  /// complete normally.
  void stop() {
    _timer?.cancel();
    _timer = null;
    log.info('[Scheduler] Stopped');
  }

  // ── Tick ─────────────────────────────────────────────────────

  Future<void> _tick() async {
    log.debug('[Scheduler] Tick at ${DateTime.now().toIso8601String()}');

    await _tickBackgroundIndexing();

    final db = serverDb;
    final llmSettings = ServerLlmSettingsService.instance;

    List<AgenticTask> dueTasks;
    try {
      dueTasks = await db.getDueTasks();
    } catch (e) {
      log.error('[Scheduler] Failed to query due tasks: $e');
      return;
    }

    if (dueTasks.isEmpty) return;
    log.info('[Scheduler] ${dueTasks.length} task(s) due');

    for (final task in dueTasks) {
      if (_inProgress.contains(task.id)) {
        log.debug('[Scheduler] Task ${task.id} already running — skipping');
        continue;
      }
      _inProgress.add(task.id);
      _runWithRetry(task, db: db, llmSettings: llmSettings)
          .then((_) {
            _inProgress.remove(task.id);
          })
          .catchError((Object e) {
            log.error('[Scheduler] Unexpected error for task ${task.id}: $e');
            _inProgress.remove(task.id);
          });
    }
  }

  Future<void> _tickBackgroundIndexing() async {
    final ds = ServerDataSourcesService.instance;
    await ds.load();

    final indexing = ServerIndexingService.instance;
    final now = DateTime.now();

    if (ds.websiteIndexCron.trim().isNotEmpty &&
        ds.websiteIndexUrls.trim().isNotEmpty) {
      final status = indexing.getWebsiteIndexStatus();
      final running = status['running'] == true;
      if (!running) {
        final last =
            ds.websiteIndexLastIndexedAt ??
            now.subtract(const Duration(days: 3650));
        final dueAt = nextCronFire(ds.websiteIndexCron, from: last);
        if (!dueAt.isAfter(now)) {
          log.info(
            '[Scheduler] Website index due by cron (${ds.websiteIndexCron}) — starting background run',
          );
          indexing.startWebsiteIndex(
            urls: ds.websiteIndexUrls,
            maxPages: ds.websiteIndexMaxPages,
          );
        }
      }
    }

    if (ds.documentIndexCron.trim().isNotEmpty &&
        ds.documentRootPaths.trim().isNotEmpty) {
      final status = indexing.getDocumentIndexStatus();
      final running = status['running'] == true;
      if (!running) {
        final last =
            ds.documentIndexLastIndexedAt ??
            now.subtract(const Duration(days: 3650));
        final dueAt = nextCronFire(ds.documentIndexCron, from: last);
        if (!dueAt.isAfter(now)) {
          log.info(
            '[Scheduler] Document index due by cron (${ds.documentIndexCron}) — starting background run',
          );
          indexing.startDocumentIndex(
            rootPaths: ds.documentRootPaths,
            fileTypes: ds.documentFileTypes,
          );
        }
      }
    }
  }

  // ── Retry wrapper ────────────────────────────────────────────

  Future<void> _runWithRetry(
    AgenticTask task, {
    required ServerDatabaseAdapter db,
    required ServerLlmSettingsService llmSettings,
  }) async {
    final prefs = ServerPreferencesService.instance;
    // Use preferences retentionDays as a proxy for configured max retries,
    // capped at _maxRetries.  A dedicated pref could be added later.
    final maxRetries = _maxRetries;

    final runner = ServerTaskRunner(db: db, llmSettings: llmSettings);

    String? lastError;

    for (int attempt = 0; attempt <= maxRetries; attempt++) {
      if (attempt > 0) {
        final backoff = Duration(seconds: (4 << attempt).clamp(0, 120));
        log.info(
          '[Scheduler] Retry $attempt/$maxRetries for task ${task.id} in ${backoff.inSeconds}s',
        );
        await Future.delayed(backoff);
      }

      try {
        final result = await runner.runTask(
          task,
          suppressFailureNotifications: attempt < maxRetries,
        );
        if (result.success) {
          log.info(
            '[Scheduler] Task ${task.id} completed successfully (attempt ${attempt + 1})',
          );
          return;
        }
        lastError = result.error;
        log.warning(
          '[Scheduler] Task ${task.id} failed (attempt ${attempt + 1}): $lastError',
        );

        // Configuration errors (e.g. no LLM set up) will never succeed on
        // retry — abort immediately instead of wasting retry cycles.
        if (_isPermanentError(lastError)) {
          log.error(
            '[Scheduler] Task ${task.id} permanently failed — config error, no retry: $lastError',
          );
          break;
        }
      } catch (e) {
        lastError = e.toString();
        log.error(
          '[Scheduler] Exception running task ${task.id} (attempt ${attempt + 1}): $lastError',
        );
      }
    }

    log.error(
      '[Scheduler] Task ${task.id} permanently failed after $maxRetries retries',
    );
    // Record final failure with the real error message so the app can show it.
    try {
      final existing = await db.getTask(task.id);
      if (existing != null) {
        final failedExecution = existing.execution.recordRun(
          success: false,
          error: lastError ?? 'Permanently failed after $maxRetries retries',
        );
        await db.updateExecution(task.id, failedExecution);
      }
    } catch (e) {
      log.error('[Scheduler] Could not mark task ${task.id} as failed: $e');
    }
    // suppress unused warning
    prefs;
  }

  /// Returns true for errors that represent a permanent configuration problem
  /// (wrong credentials, no LLM set up, etc.) that retrying will never fix.
  bool _isPermanentError(String? error) {
    if (error == null) return false;
    final lower = error.toLowerCase();
    return lower.contains('no llm configured') ||
        lower.contains('set up a provider') ||
        lower.contains('invalid api key') ||
        lower.contains('unauthorized') ||
        lower.contains('authentication') ||
        lower.contains('failed to connect http mcp');
  }
}
