import 'dart:async';
import 'dart:io';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../database/task_database_service_duckdb.dart';
import '../mcp/servers/document_mcp_server.dart';
import '../mcp/servers/website_search_mcp_server.dart';
import '../models/workflow_task.dart';
import '../services/app_logger.dart';
import '../services/data_sources_settings_service.dart';
import '../services/notification_service.dart';
import '../services/scheduler_log_service.dart';
import '../services/task_runner_service.dart';
import '../utils/cron_utils.dart';

// ─── WorkManager callback dispatcher (background isolate entry point) ────────

/// Top-level callback called by WorkManager in a background isolate.
/// On Android this is the iOS-style fallback heartbeat; the primary mechanism
/// is the exact AlarmManager heartbeat ([heartbeatAlarmDispatcher]).
/// On iOS this IS the only background mechanism (no AlarmManager).
/// MUST be annotated with `@pragma('vm:entry-point')`.
@pragma('vm:entry-point')
void workManagerCallbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    log.info('[WM] Heartbeat tick (task="$taskName")');
    try {
      await bootstrapTaskRunnerServices();
      if (await _isAppActive()) {
        log.info('[WM] App is active — yielding to foreground scheduler, skipping background run.');
        await SchedulerLogService().addEntry(
          taskId: '__heartbeat__',
          taskName: 'WM',
          event: SchedulerEventType.skipped,
          detail: 'app-active, fg-scheduler handles',
        );
        return true;
      }
      await _runDueTasks('[WM]');
      return true;
    } catch (e, st) {
      log.error('[WM] Heartbeat error: $e', e, st);
      return false;
    }
  });
}

// ─── Heartbeat alarm (single periodic wakeup, Android) ───────────────────────

/// Stable alarm ID for the single heartbeat.
/// Chosen outside the range produced by per-task hash IDs (historical compat).
const int _kHeartbeatAlarmId = 200000001;

/// Default heartbeat cadence in minutes when no user preference is stored.
const int _kDefaultHeartbeatIntervalMinutes = 10;

/// SharedPreferences key where the user's chosen heartbeat interval is stored.
/// Written by [AppPreferencesService] (via its own persist path) and read here
/// from background isolates where AppPreferencesService is not initialised.
const String _kHeartbeatIntervalPrefKey = 'app_pref_background_check_interval';

/// WorkManager unique task name for the iOS fallback heartbeat.
const String _kHeartbeatWMTaskName = 'scheduler_heartbeat';

// ─── App-active heartbeat ─────────────────────────────────────────────────────

/// SharedPreferences key written by the foreground timer every
/// [_kAppActiveWriteIntervalSeconds] seconds while the app is running.
/// Background dispatchers read this to decide whether to yield to the
/// foreground scheduler (avoiding duplicate / race-condition runs).
const String _kAppActiveHeartbeatKey = 'app_fg_active_ms';

/// How often (in seconds) the running app writes the active-timestamp.
const int _kAppActiveWriteIntervalSeconds = 12;

/// Tolerance (in seconds): if `now − lastActive ≤ _kAppActiveTolerance` the
/// app is considered running and the background dispatcher will skip execution.
const int _kAppActiveTolerance = 40;

/// Write the current timestamp to SharedPreferences as the app-active marker.
/// Called on a recurring timer inside [MobileSchedulerService].
Future<void> _writeAppActiveHeartbeat() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kAppActiveHeartbeatKey, DateTime.now().millisecondsSinceEpoch);
  } catch (_) {}
}

/// Returns `true` when the app was recently active (within [_kAppActiveTolerance]
/// seconds). Used by background dispatchers: when the app is active they skip
/// execution so the foreground timer (which fires at the exact cron second)
/// handles the task without a duplicate run.
Future<bool> _isAppActive() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(_kAppActiveHeartbeatKey);
    if (ms == null) return false;
    final lastActive = DateTime.fromMillisecondsSinceEpoch(ms);
    return DateTime.now().difference(lastActive).inSeconds <= _kAppActiveTolerance;
  } catch (_) {
    return false;
  }
}

/// Returns true when [error] looks like a transient network or LLM-
/// availability problem that may resolve on a retry (connection refused,
/// timeout, host unreachable, socket errors, DNS failure, or the specific
/// "LLM not configured" message that appears when the background isolate
/// hasn't yet warmed its cipher for reading LLM2 credentials).
bool _isTransientError(String? error) {
  if (error == null) return false;
  final lower = error.toLowerCase();
  return lower.contains('connection refused') ||
      lower.contains('connection reset') ||
      lower.contains('timed out') ||
      lower.contains('timeout') ||
      lower.contains('socket') ||
      lower.contains('host lookup failed') ||
      lower.contains('network is unreachable') ||
      lower.contains('failed host lookup') ||
      lower.contains('no address associated');
}

/// Returns the currently configured heartbeat interval in minutes.
/// Reads directly from SharedPreferences so it works in background isolates.
Future<int> _resolveHeartbeatInterval() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getInt(_kHeartbeatIntervalPrefKey) ?? _kDefaultHeartbeatIntervalMinutes;
    const allowed = [5, 10, 15];
    return allowed.contains(v) ? v : _kDefaultHeartbeatIntervalMinutes;
  } catch (_) {
    return _kDefaultHeartbeatIntervalMinutes;
  }
}

// ─── Shared due-task logic ────────────────────────────────────────────────────

/// Returns true when [task] should be executed by the current heartbeat tick.
///
/// Returns the scheduled cron slot that falls inside the current heartbeat
/// window for [task], or null if the task is not due (or already ran for
/// this slot).
///
/// Window:  [now − 2×interval, now + ceil(interval/2)]
/// The 2× lookback covers alarm delivery latency up to one full interval
/// (Android Doze, OEM delay).  The ½ look-ahead lets slightly-early alarms
/// catch the next cron hit.
///
/// The deduplication guard uses [scheduledTime] as the reference point.
/// Crucially, [_runDueTasks] pre-marks [lastRun] = scheduledTime in the DB
/// *before* executing the task, so a concurrent heartbeat in another isolate
/// that fires while the task is still running will see lastRun ≥ scheduledTime
/// and correctly skip re-execution.
DateTime? _computeDueScheduledTime(WorkflowTask task, DateTime now, {int intervalMinutes = _kDefaultHeartbeatIntervalMinutes}) {
  final windowStart = now.subtract(Duration(minutes: intervalMinutes * 2));
  final windowEnd = now.add(Duration(minutes: (intervalMinutes / 2).ceil()));

  DateTime? scheduledTime = task.execution.nextRun;
  DateTime? cronWindowSlot;

  // Canonical slot from the current cron expression for this window.
  // Used to detect stale stored nextRun after schedule edits.
  try {
    cronWindowSlot = nextCronFire(task.executionPlan.cronExpression, from: windowStart.subtract(const Duration(seconds: 1)));
  } catch (_) {
    return null;
  }

  if (scheduledTime == null) {
    // No nextRun stored (first run or cron just changed).
    // Find the first cron hit inside the window.
    scheduledTime = cronWindowSlot;
  } else if (scheduledTime.isBefore(windowStart)) {
    // Stored nextRun is stale — the alarm was suppressed while the app was
    // killed, in Doze, or killed by an OEM battery optimizer for more than
    // 2 × heartbeat interval.  Re-derive the most recent cron slot that
    // falls inside the current window so we can catch up on missed runs.
    scheduledTime = cronWindowSlot;
  } else {
    // Stored nextRun is inside the window but may belong to an old cron after
    // a schedule edit. If it doesn't match the current cron-derived window slot,
    // trust the cron-derived value.
    final driftSeconds = scheduledTime.difference(cronWindowSlot).inSeconds.abs();
    if (driftSeconds > 60) {
      scheduledTime = cronWindowSlot;
    }
  }

  // Boundary check: scheduled slot must be inside the window.
  if (scheduledTime.isBefore(windowStart) || scheduledTime.isAfter(windowEnd)) return null;

  // Deduplication guard: task already ran for this scheduled slot when
  // lastRun ≥ scheduledTime.  This also catches early-alarm executions:
  // if the alarm fired at 08:59 for a 09:00 task, _runDueTasks pre-marks
  // lastRun = 09:00 in the DB before running, so the 09:03 alarm sees
  // lastRun (09:00) ≥ scheduledTime (09:00) and returns null here.
  final lastRun = task.execution.lastRun;
  if (lastRun != null && !lastRun.isBefore(scheduledTime)) return null;

  return scheduledTime;
}

DateTime? _computeExecutorDueScheduledTime(Agent exec, DateTime now, {int intervalMinutes = _kDefaultHeartbeatIntervalMinutes}) {
  final windowStart = now.subtract(Duration(minutes: intervalMinutes * 2));
  final windowEnd = now.add(Duration(minutes: (intervalMinutes / 2).ceil()));

  DateTime? scheduledTime = exec.nextRun;
  DateTime? cronWindowSlot;

  if (exec.executionPlan == null) return null;

  try {
    cronWindowSlot = nextCronFire(exec.executionPlan!.cronExpression, from: windowStart.subtract(const Duration(seconds: 1)));
  } catch (_) {
    return null;
  }

  if (scheduledTime == null) {
    scheduledTime = cronWindowSlot;
  } else if (scheduledTime.isBefore(windowStart)) {
    scheduledTime = cronWindowSlot;
  } else {
    final driftSeconds = scheduledTime.difference(cronWindowSlot).inSeconds.abs();
    if (driftSeconds > 60) {
      scheduledTime = cronWindowSlot;
    }
  }

  if (scheduledTime.isBefore(windowStart) || scheduledTime.isAfter(windowEnd)) return null;

  final lastRun = exec.lastRun;
  if (lastRun != null && !lastRun.isBefore(scheduledTime)) return null;

  return scheduledTime;
}

bool _isExecutorCalledByPrevious(WorkflowTask task, Agent exec) {
  if (task.edges.any((r) => r.targetAgentId == exec.id)) {
    return true;
  }
  final idx = task.agents.indexOf(exec);
  if (idx > 0) {
    return true;
  }
  return false;
}


/// Loads all tasks from the DB and runs every enabled task that is due in the
/// current heartbeat window.  Used by both the alarm and WorkManager dispatchers.
///
/// The heartbeat is the only task-execution mechanism (in-process foreground
/// timers have been removed to prevent duplicate runs). It fires tasks both
/// when the app is in the foreground and in the background.
Future<void> _runDueTasks(String prefix) async {
  final prefs = await SharedPreferences.getInstance();
  if ((prefs.getString('server_mode') ?? 'local') == 'remote') {
    log.info('$prefix App is in remote server mode — skipping local task scheduler run.');
    return;
  }

  final now = DateTime.now();
  final interval = await _resolveHeartbeatInterval();
  final tasks = await TaskDatabaseService().getAllTasks();

  // Pair each due task with its computed scheduled slot time and optional startExecutorId.
  final due = <(WorkflowTask, DateTime, String?)>[];
  for (final t in tasks) {
    if (!t.enabled || t.isSubtask) continue;
    
    // Check main task schedule
    final slot = _computeDueScheduledTime(t, now, intervalMinutes: interval);
    if (slot != null) {
      due.add((t, slot, null));
    }
    
    // Check individual agents' schedules
    for (final exec in t.agents) {
      if (exec.executionPlan != null && !_isExecutorCalledByPrevious(t, exec)) {
        final slot = _computeExecutorDueScheduledTime(exec, now, intervalMinutes: interval);
        if (slot != null) {
          due.add((t, slot, exec.id));
        }
      }
    }
  }

  // In a background isolate, tasks that use an embedded (on-device) LLM
  // cannot run: loading the GGUF model in a background isolate risks a
  // LlamaBackend double-init crash or an OOM kill.  Separate them out,
  // post a "tap to open app" notification, and exclude them from the
  // pre-mark + run loop so they remain eligible for the foreground scheduler.
  List<(WorkflowTask, DateTime, String?)> runnable = due;
  if (isBackgroundRunnerContext) {
    final embedded = <(WorkflowTask, DateTime, String?)>[];
    runnable = <(WorkflowTask, DateTime, String?)>[];
    for (final item in due) {
      if (taskUsesEmbeddedLlm(item.$1)) {
        embedded.add(item);
      } else {
        runnable.add(item);
      }
    }
    for (final (task, _, _) in embedded) {
      log.info('$prefix Skipping "${task.name}" — embedded model requires app to be open; posting notification.');
      await SchedulerLogService().addEntry(
        taskId: task.id,
        taskName: task.name,
        event: SchedulerEventType.skipped,
        detail: 'embedded-model-background',
      );
      await NotificationService.instance.showEmbeddedTaskPending(task.name, task.id.hashCode);
    }
  }

  log.info(
    '$prefix ${runnable.length}/${tasks.where((t) => t.enabled && !t.isSubtask).length} enabled non-subtask(s) due (interval=${interval}m)',
  );

  // Log the alarm tick itself so the user can see when the heartbeat fired.
  final source = prefix.trim().replaceAll(RegExp(r'[\[\]]'), '');
  String hm(DateTime dt) => '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  final alarmDetail = runnable.isEmpty
      ? '0 due'
      : '${runnable.length} due: ${runnable.map((e) {
          final (t, slot, execId) = e;
          final last = execId == null
              ? (t.execution.lastRun != null ? hm(t.execution.lastRun!) : '?')
              : (() {
                  final exec = t.agents.firstWhere((ex) => ex.id == execId, orElse: () => t.agents.first);
                  return exec.lastRun != null ? hm(exec.lastRun!) : '?';
                }());
          final label = execId == null ? t.name : '${t.name}[$execId]';
          return '$label(slot=${hm(slot)},last=$last)';
        }).join(' | ')}';
  await SchedulerLogService().addEntry(taskId: '__heartbeat__', taskName: source, event: SchedulerEventType.alarm, detail: alarmDetail);

  // ── Pre-mark lastRun = max(now, scheduledSlot) BEFORE running ──────────
  // This prevents a concurrent heartbeat (e.g. WorkManager + AlarmManager
  // both firing within the same window) from reading stale DB state and
  // running the same task a second time while the first execution is still
  // in progress.  TaskRunnerService will overwrite with the real completion
  // time when it finishes.
  final db = TaskDatabaseService();
  final runnableFresh = <(WorkflowTask, DateTime, String?)>[];
  for (final (task, _, startExecutorId) in runnable) {
    try {
      final latest = await db.getTask(task.id);
      if (latest == null || !latest.enabled || latest.isSubtask) {
        log.info('$prefix Skipping "${task.name}" before pre-mark — task disabled or removed');
        await SchedulerLogService().addEntry(
          taskId: task.id,
          taskName: task.name,
          event: SchedulerEventType.skipped,
          detail: 'disabled-before-run',
        );
        continue;
      }

      // Re-check due-ness against the latest DB state to avoid stale-snapshot
      // races (e.g. cron/enable edits or a concurrent heartbeat isolate).
      DateTime? latestSlot;
      if (startExecutorId == null) {
        latestSlot = _computeDueScheduledTime(latest, now, intervalMinutes: interval);
      } else {
        final exec = latest.agents.firstWhere((e) => e.id == startExecutorId, orElse: () => latest.agents.first);
        latestSlot = _computeExecutorDueScheduledTime(exec, now, intervalMinutes: interval);
      }

      if (latestSlot == null) {
        log.info('$prefix Skipping "${task.name}" before pre-mark — no longer due in latest state');
        await SchedulerLogService().addEntry(
          taskId: task.id,
          taskName: task.name,
          event: SchedulerEventType.skipped,
          detail: 'not-due-latest-state',
        );
        continue;
      }

      // Final dedup fence: if another isolate already pre-marked or completed
      // this exact slot, skip here to prevent duplicate starts.
      DateTime? latestLastRun;
      if (startExecutorId == null) {
        latestLastRun = latest.execution.lastRun;
      } else {
        final exec = latest.agents.firstWhere((e) => e.id == startExecutorId, orElse: () => latest.agents.first);
        latestLastRun = exec.lastRun;
      }

      if (latestLastRun != null && !latestLastRun.isBefore(latestSlot)) {
        log.info('$prefix Skipping "${task.name}" before pre-mark — slot already handled (lastRun=$latestLastRun, slot=$latestSlot)');
        await SchedulerLogService().addEntry(
          taskId: task.id,
          taskName: task.name,
          event: SchedulerEventType.skipped,
          detail: 'already-handled-slot',
        );
        continue;
      }

      final preMarkTime = now.isAfter(latestSlot) ? now : latestSlot;
      if (startExecutorId == null) {
        final preExec = TaskExecution(
          lastRun: preMarkTime,
          nextRun: latest.execution.nextRun,
          lastResult: latest.execution.lastResult,
          lastError: latest.execution.lastError,
          runCount: latest.execution.runCount,
          consecutiveFailures: latest.execution.consecutiveFailures,
          history: latest.execution.history,
        );
        await db.updateExecution(task.id, preExec);
      } else {
        final updatedExecutors = latest.agents.map((e) {
          if (e.id == startExecutorId) return e.copyWith(lastRun: preMarkTime);
          return e;
        }).toList();
        await db.saveTask(latest.copyWith(agents: updatedExecutors));
      }

      log.info('$prefix Pre-marked lastRun=$preMarkTime for "${task.name}" (startExecutorId=$startExecutorId)');
      runnableFresh.add((latest, latestSlot, startExecutorId));
    } catch (e) {
      log.warning('$prefix Pre-mark failed for "${task.name}": $e');
    }
  }

  for (final (task, slot, startExecutorId) in runnableFresh) {
    try {
      final latest = await db.getTask(task.id);
      if (latest == null || !latest.enabled || latest.isSubtask) {
        log.info('$prefix Skipping "${task.name}" before execute — task disabled or removed');
        await SchedulerLogService().addEntry(
          taskId: task.id,
          taskName: task.name,
          event: SchedulerEventType.skipped,
          detail: 'disabled-before-execute',
        );
        continue;
      }

      final firstResult = await TaskRunnerService().run(latest, startExecutorId: startExecutorId);
      if (!firstResult.success && _isTransientError(firstResult.error)) {
        log.info('$prefix "${latest.name}" failed with transient error, retrying in 30 s...');
        await Future.delayed(const Duration(seconds: 30));
        final retryLatest = await db.getTask(latest.id);
        if (retryLatest != null && retryLatest.enabled && !retryLatest.isSubtask) {
          await TaskRunnerService().run(retryLatest, startExecutorId: startExecutorId);
        } else {
          log.info('$prefix Skipping retry for "${latest.name}" — task disabled before retry');
        }
      }

      // ── Post-run lastRun correction ──────────────────────────────────────
      try {
        final refreshed = await db.getTask(latest.id);
        if (refreshed != null) {
          if (startExecutorId == null) {
            final lr = refreshed.execution.lastRun;
            if (lr != null && lr.isBefore(slot)) {
              final exec = refreshed.execution;
              await db.updateExecution(
                latest.id,
                TaskExecution(
                  lastRun: slot,
                  nextRun: exec.nextRun,
                  lastResult: exec.lastResult,
                  lastError: exec.lastError,
                  runCount: exec.runCount,
                  consecutiveFailures: exec.consecutiveFailures,
                  history: exec.history,
                ),
              );
              log.info('$prefix Corrected lastRun to slot=$slot for "${latest.name}" (was $lr)');
            }
          } else {
            final exec = refreshed.agents.firstWhere((e) => e.id == startExecutorId, orElse: () => refreshed.agents.first);
            final lr = exec.lastRun;
            if (lr != null && lr.isBefore(slot)) {
              final updatedExecutors = refreshed.agents.map((e) {
                if (e.id == startExecutorId) {
                  return e.copyWith(lastRun: slot);
                }
                return e;
              }).toList();
              await db.saveTask(refreshed.copyWith(agents: updatedExecutors));
              log.info('$prefix Corrected lastRun to slot=$slot for executor "${exec.name}" of "${latest.name}" (was $lr)');
            }
          }
        }
      } catch (e) {
        log.warning('$prefix Failed to correct lastRun for "${latest.name}": $e');
      }
    } catch (e, st) {
      log.error('$prefix Error running "${task.name}": $e', e, st);
    }
  }

  // Run website/document index jobs that are due in the same window.
  await _runDueIndexJobs(now, interval);
}

/// Checks if the website and/or document index jobs are due in the current
/// heartbeat window and runs them.  Uses identical window logic to normal
/// agentic tasks so they benefit from the same missed-alarm recovery.
Future<void> _runDueIndexJobs(DateTime now, int intervalMinutes) async {
  final ds = DataSourcesSettingsService.instance;
  final windowStart = now.subtract(Duration(minutes: intervalMinutes * 2));
  final windowEnd = now.add(Duration(minutes: (intervalMinutes / 2).ceil()));

  // ── Website index ──────────────────────────────────────────────────────────
  final websiteCron = ds.websiteIndexCron.trim();
  final websiteUrls = ds.websiteIndexUrls.trim();
  if (websiteCron.isNotEmpty && websiteUrls.isNotEmpty) {
    try {
      final scheduled = nextCronFire(websiteCron, from: windowStart.subtract(const Duration(seconds: 1)));
      final inWindow = !scheduled.isBefore(windowStart) && !scheduled.isAfter(windowEnd);
      final lastIndexed = ds.websiteIndexLastIndexedAt;
      final notYetRun = lastIndexed == null || lastIndexed.isBefore(scheduled);
      if (inWindow && notYetRun) {
        log.info('[Heartbeat] Website index due (scheduled=$scheduled) — indexing.');
        try {
          final server = WebsiteSearchMcpServer();
          await server.initialize({'websiteUrls': websiteUrls, 'maxPages': ds.websiteIndexMaxPages, 'indexingStrategy': 'now'});
          await ds.saveWebsiteIndex(urls: websiteUrls, maxPages: ds.websiteIndexMaxPages, cron: websiteCron, lastIndexedAt: DateTime.now());
          log.info('[Heartbeat] Website index complete.');
        } catch (e, st) {
          log.error('[Heartbeat] Website index failed: $e', e, st);
        }
      }
    } catch (e) {
      log.error('[Heartbeat] Website index cron parse error: $e');
    }
  }

  // ── Document index ─────────────────────────────────────────────────────────
  final documentCron = ds.documentIndexCron.trim();
  final documentPaths = ds.documentRootPaths.trim();
  if (documentCron.isNotEmpty && documentPaths.isNotEmpty) {
    try {
      final scheduled = nextCronFire(documentCron, from: windowStart.subtract(const Duration(seconds: 1)));
      final inWindow = !scheduled.isBefore(windowStart) && !scheduled.isAfter(windowEnd);
      final lastIndexed = ds.documentIndexLastIndexedAt;
      final notYetRun = lastIndexed == null || lastIndexed.isBefore(scheduled);
      if (inWindow && notYetRun) {
        log.info('[Heartbeat] Document index due (scheduled=$scheduled) — indexing.');
        try {
          final server = DocumentMcpServer();
          await server.initialize({'rootPath': documentPaths, 'fileTypes': ds.documentFileTypes, 'indexingStrategy': 'now'});
          await server.executeTool('reindex', {});
          await server.dispose();
          await ds.saveDocumentIndex(rootPaths: documentPaths, cron: documentCron, lastIndexedAt: DateTime.now());
          log.info('[Heartbeat] Document index complete.');
        } catch (e, st) {
          log.error('[Heartbeat] Document index failed: $e', e, st);
        }
      }
    } catch (e) {
      log.error('[Heartbeat] Document index cron parse error: $e');
    }
  }
}

/// Registers (or replaces) the self-rescheduling periodic heartbeat alarm.
/// Using [AndroidAlarmManager.periodic] means the OS handles rescheduling
/// automatically — no manual re-trigger is needed after each callback.
/// Safe to call from any isolate; no-op on non-Android platforms.
Future<void> _scheduleNextHeartbeat() async {
  if (!Platform.isAndroid) return;
  try {
    final interval = await _resolveHeartbeatInterval();
    await AndroidAlarmManager.periodic(
      Duration(minutes: interval),
      _kHeartbeatAlarmId,
      heartbeatAlarmDispatcher,
      exact: true,
      wakeup: true,
      rescheduleOnReboot: true,
    );
    log.info('[Heartbeat] Periodic alarm registered (interval=${interval}m)');
  } catch (e) {
    log.error('[Heartbeat] Failed to register periodic alarm: $e');
  }
}

/// Legacy compatibility shim — kept so that any one-shot alarms registered
/// by a previous version of the app (which stored this function's handle in
/// native AlarmManager storage) can still resolve without crashing.
/// These old alarms will fire once, do nothing harmful, and are then gone.
/// The new periodic heartbeat ([heartbeatAlarmDispatcher]) takes over from
/// the first time [_ensureHeartbeatRunning] is called.
@pragma('vm:entry-point')
void alarmCallbackDispatcher(int alarmId) async {
  log.info('[Heartbeat/compat] Legacy alarm fired (id=$alarmId) — ignoring, new periodic alarm is active.');
}

/// Top-level callback invoked by AndroidAlarmManager at the configured interval.
/// Runs in a background isolate even when the app is completely closed.
/// The periodic alarm is self-rescheduling — no manual re-trigger is needed.
@pragma('vm:entry-point')
void heartbeatAlarmDispatcher(int alarmId) async {
  log.info('[Heartbeat] Alarm fired (id=$alarmId)');
  try {
    await bootstrapTaskRunnerServices();
    if (await _isAppActive()) {
      log.info('[Heartbeat] App is active — yielding to foreground scheduler, skipping background run.');
      await SchedulerLogService().addEntry(
        taskId: '__heartbeat__',
        taskName: 'Heartbeat',
        event: SchedulerEventType.skipped,
        detail: 'app-active, fg-scheduler handles',
      );
      return;
    }
    await _runDueTasks('[Heartbeat]');
  } catch (e, st) {
    log.error('[Heartbeat] Unhandled error: $e', e, st);
  }
}

// ─── Website Auto-Index (legacy alarm stubs) ─────────────────────────────────
//
// Website and document indexing is now triggered by the heartbeat scheduler
// via [_runDueIndexJobs], using identical window + lastIndexedAt guard logic
// as normal agentic tasks.  The separate one-shot alarms have been removed.
// The constants and stub functions below are kept for backwards compatibility
// so that any alarms already registered in the device's AlarmManager can
// still resolve their callback without crashing.

/// No-op stub — website indexing is now handled by [_runDueIndexJobs].
/// Kept so callers in the settings UI do not need to be updated.
Future<void> scheduleWebsiteIndexAlarm(String cron) async {
  log.info('[WebsiteIndex] scheduleWebsiteIndexAlarm — now handled by heartbeat (no-op).');
}

/// Legacy compat stub — fires if an old one-shot alarm stored this handle.
@pragma('vm:entry-point')
void websiteIndexAlarmDispatcher(int alarmId) async {
  log.info(
    '[WebsiteIndex/compat] Legacy alarm fired (id=$alarmId) — ignoring, '
    'indexing is now driven by the heartbeat scheduler.',
  );
}

// ─── Document Index (legacy alarm stubs) ─────────────────────────────────────

/// No-op stub — document indexing is now handled by [_runDueIndexJobs].
/// Kept so callers in the settings UI do not need to be updated.
Future<void> scheduleDocumentIndexAlarm(String cron) async {
  log.info('[DocumentIndex] scheduleDocumentIndexAlarm — now handled by heartbeat (no-op).');
}

/// Legacy compat stub — fires if an old one-shot alarm stored this handle.
@pragma('vm:entry-point')
void documentIndexAlarmDispatcher(int alarmId) async {
  log.info(
    '[DocumentIndex/compat] Legacy alarm fired (id=$alarmId) — ignoring, '
    'indexing is now driven by the heartbeat scheduler.',
  );
}

// ─── Abstract interface ───────────────────────────────────────────────────────

abstract class SchedulerService {
  /// Schedule or update a periodic background task.
  Future<void> scheduleTask(WorkflowTask task);

  /// Cancel scheduling for one task.
  Future<void> cancelTask(String taskId);

  /// Cancel all scheduled tasks.
  Future<void> cancelAll();

  /// Re-sync all tasks: cancel old ones, schedule all currently-enabled tasks.
  Future<void> syncAllTasks(List<WorkflowTask> tasks);
}

// ─── Global singleton ─────────────────────────────────────────────────────────

SchedulerService? _schedulerInstance;

/// Access the app-wide [SchedulerService].
/// Created on first access; correct impl chosen by platform.
SchedulerService get appScheduler {
  return _schedulerInstance ??= createSchedulerService();
}

/// Replace the global instance (used in tests or for manual override).
set appScheduler(SchedulerService svc) => _schedulerInstance = svc;

// ─── Factory ─────────────────────────────────────────────────────────────────

SchedulerService createSchedulerService() {
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) return WindowsSchedulerService();
  return MobileSchedulerService();
}

// ─── Cron next-fire calculator ────────────────────────────────────────────────

/// Returns the next [DateTime] at or after [from] that matches [cron].
/// Delegates to the shared [nextCronFire] utility in `cron_utils.dart`.
/// Kept as a private alias so all in-file call sites remain unchanged.
DateTime _nextCronFire(String cron, {DateTime? from}) => nextCronFire(cron, from: from);

// ─── Shared runner mixin ───────────────────────────────────────────────────────

Future<void> _runScheduledTask(
  WorkflowTask task,
  Map<String, DateTime> lastRun, {
  String prefix = 'Scheduler',
  Set<String>? inFlight,
}) async {
  final now = DateTime.now();
  // In-flight guard: skip if the same task is already executing.
  // This prevents overlapping runs when a task takes longer than its cron
  // interval (e.g. a slow LLM call outlasts a 5-minute schedule).
  if (inFlight != null && inFlight.contains(task.id)) {
    log.info('[$prefix] Skipping "${task.name}" — already running');
    return;
  }
  final last = lastRun[task.id];
  // In-memory guard: ignore if we ran within 90% of the interval
  final minGap = Duration(minutes: (task.executionPlan.intervalMinutes * 0.9).round().clamp(1, 999999));
  if (last != null && now.difference(last) < minGap) {
    log.info('[$prefix] Skipping "${task.name}" — ran too recently (${now.difference(last).inMinutes}m ago)');
    return;
  }
  lastRun[task.id] = now;
  inFlight?.add(task.id);
  log.info('[$prefix] Firing "${task.name}"');
  try {
    final db = TaskDatabaseService();
    final tasks = await db.getAllTasks();
    final fresh = tasks.where((t) => t.id == task.id).firstOrNull ?? task;
    if (!fresh.enabled) return;

    await SchedulerLogService().addEntry(
      taskId: fresh.id,
      taskName: fresh.name,
      event: SchedulerEventType.fired,
      detail: 'foreground-timer',
    );
    // Note: TaskRunnerService also logs completed/failed. The 'fired' entry here
    // is intentionally kept for foreground tasks so the user can see them in the
    // task-detail screen scheduler log, but it is filtered out by the Activity
    // dialog which shows only completed/failed from background runs.
    await TaskRunnerService().run(fresh);
  } catch (e, st) {
    log.error('[$prefix] Error running "${task.name}": $e', e, st);
  } finally {
    inFlight?.remove(task.id);
  }
}

// ─── Mobile (Android / iOS) ───────────────────────────────────────────────────

class MobileSchedulerService implements SchedulerService {
  // Foreground cron timers: fire at exact cron time while app is open.
  final Map<String, Timer> _foregroundTimers = {};
  final Map<String, DateTime> _lastRun = {};
  // In-flight guard: task IDs currently executing (prevents overlapping runs).
  final Set<String> _inFlight = {};
  // Generation counter per task: incremented on each new scheduling so stale
  // timer callbacks can detect they have been superseded and skip rescheduling.
  final Map<String, int> _generation = {};

  /// Whether the single background heartbeat has been started this app session.
  bool _heartbeatStarted = false;

  /// Interval (minutes) used when registering the current periodic alarm.
  /// 0 means no alarm is registered. Used to detect user-changed intervals
  /// so the alarm can be re-registered with the new cadence.
  int _heartbeatInterval = 0;

  /// Timer that writes the app-active timestamp every [_kAppActiveWriteIntervalSeconds]s
  /// while the app is running. The background alarm checks this to avoid
  /// duplicate runs when the foreground scheduler is already active.
  Timer? _appActiveTimer;

  /// Periodic timer that fires [_runDueTasks] at the configured interval while
  /// the app is in the foreground (or background-but-alive). This mirrors the
  /// exact-alarm accuracy of [WindowsSchedulerService] for mobile users, while
  /// the background alarm covers the app-closed / Doze case.
  Timer? _foregroundCronTimer;

  /// Start the app-active heartbeat writer (idempotent).
  void _startAppActiveHeartbeat() {
    if (_appActiveTimer?.isActive == true) return;
    _appActiveTimer?.cancel();
    _writeAppActiveHeartbeat(); // write immediately
    _appActiveTimer = Timer.periodic(const Duration(seconds: _kAppActiveWriteIntervalSeconds), (_) => _writeAppActiveHeartbeat());
    log.info('[Scheduler/Mobile] App-active heartbeat writer started (every ${_kAppActiveWriteIntervalSeconds}s)');
  }

  /// Start the foreground cron timer that calls [_runDueTasks] on the heartbeat
  /// interval (idempotent — restarts only if the interval changed).
  void _startForegroundCronTimer(int intervalMinutes) {
    if (_foregroundCronTimer?.isActive == true && _heartbeatInterval == intervalMinutes) return;
    _foregroundCronTimer?.cancel();
    _foregroundCronTimer = Timer.periodic(Duration(minutes: intervalMinutes), (_) async {
      log.info('[Scheduler/Mobile/FG] Foreground cron tick');
      try {
        // Refresh the active-heartbeat timestamp immediately before running so
        // a concurrent background alarm sees a fresh timestamp and correctly
        // yields to this foreground run instead of duplicating it.
        await _writeAppActiveHeartbeat();
        await _runDueTasks('[FG]');
      } catch (e, st) {
        log.error('[Scheduler/Mobile/FG] Error: $e', e, st);
      }
    });
    log.info('[Scheduler/Mobile] Foreground cron timer started (every ${intervalMinutes}m)');
  }

  /// Starts (or re-registers) the background heartbeat.
  ///
  /// Android: registers a self-rescheduling periodic exact-wakeup alarm.
  ///   Re-registers automatically when the user changes the interval.
  /// iOS/other: registers a single WorkManager periodic task as best-effort.
  Future<void> _ensureHeartbeatRunning() async {
    if (!kIsWeb && Platform.isAndroid) {
      // Android uses AlarmManager heartbeat. Cancel any legacy WorkManager
      // heartbeat (from older app versions) to avoid dual dispatchers.
      try {
        await Workmanager().cancelByUniqueName(_kHeartbeatWMTaskName);
      } catch (_) {}

      final interval = await _resolveHeartbeatInterval();
      // Re-register if the alarm hasn't started yet or the interval changed.
      if (_heartbeatStarted && _heartbeatInterval == interval) return;
      _heartbeatStarted = true;
      _heartbeatInterval = interval;
      await _scheduleNextHeartbeat();
      _startAppActiveHeartbeat();
      _startForegroundCronTimer(interval);
    } else if (!kIsWeb) {
      if (_heartbeatStarted) return;
      _heartbeatStarted = true;
      // iOS: one WorkManager periodic task covers all tasks via scan logic.
      try {
        final interval = await _resolveHeartbeatInterval();
        _heartbeatInterval = interval;
        await Workmanager().registerPeriodicTask(
          _kHeartbeatWMTaskName,
          _kHeartbeatWMTaskName,
          frequency: Duration(minutes: interval),
          constraints: Constraints(
            networkType: NetworkType.connected,
            requiresBatteryNotLow: false,
            requiresCharging: false,
            requiresDeviceIdle: false,
            requiresStorageNotLow: false,
          ),
          existingWorkPolicy: ExistingPeriodicWorkPolicy.replace,
        );
        log.info('[Scheduler/Mobile] WorkManager heartbeat registered (iOS, interval=${interval}m)');
        _startAppActiveHeartbeat();
        _startForegroundCronTimer(interval);
      } catch (e) {
        log.error('[Scheduler/Mobile] WorkManager heartbeat failed: $e');
      }
    }
  }

  @override
  Future<void> scheduleTask(WorkflowTask task) async {
    _foregroundTimers.remove(task.id)?.cancel();
    // Do NOT clear _lastRun here — wiping the duplicate-run guard while a task
    // is still executing would allow a freshly-created timer to bypass the
    // in-memory dedup check and fire an unintended extra run.

    if (!task.enabled) {
      await cancelTask(task.id);
      return;
    }

    log.info('[Scheduler/Mobile] Scheduling "${task.name}" (cron: ${task.executionPlan.cronExpression})');

    // Ensure the single background heartbeat is running.
    // The heartbeat is the sole execution mechanism (no in-process foreground timer).
    await _ensureHeartbeatRunning();
  }

  @override
  Future<void> cancelTask(String taskId) async {
    _foregroundTimers.remove(taskId)?.cancel();
    _lastRun.remove(taskId);
    _inFlight.remove(taskId);
    _generation.remove(taskId);
    log.info('[Scheduler/Mobile] Cancelled foreground timer for $taskId');
  }

  @override
  Future<void> cancelAll() async {
    for (final t in _foregroundTimers.values) {
      t.cancel();
    }
    _foregroundTimers.clear();
    _lastRun.clear();
    _inFlight.clear();
    _generation.clear();
    _heartbeatStarted = false;

    _appActiveTimer?.cancel();
    _appActiveTimer = null;
    _foregroundCronTimer?.cancel();
    _foregroundCronTimer = null;

    // Cancel the background heartbeat.
    if (!kIsWeb && Platform.isAndroid) {
      try {
        await AndroidAlarmManager.cancel(_kHeartbeatAlarmId);
        log.info('[Scheduler/Mobile] Heartbeat alarm cancelled');
      } catch (e) {
        log.warning('[Scheduler/Mobile] Heartbeat cancel failed: $e');
      }
    } else if (!kIsWeb) {
      try {
        await Workmanager().cancelByUniqueName(_kHeartbeatWMTaskName);
        log.info('[Scheduler/Mobile] WorkManager heartbeat cancelled');
      } catch (e) {
        log.warning('[Scheduler/Mobile] WorkManager cancel failed: $e');
      }
    }
    _heartbeatStarted = false;
    _heartbeatInterval = 0;
    log.info('[Scheduler/Mobile] All tasks cancelled');
  }

  @override
  Future<void> syncAllTasks(List<WorkflowTask> tasks) async {
    final currentIds = tasks.map((t) => t.id).toSet();
    for (final id in _foregroundTimers.keys.toList()) {
      if (!currentIds.contains(id)) {
        _foregroundTimers.remove(id)?.cancel();
        _lastRun.remove(id);
        _inFlight.remove(id);
        _generation.remove(id);
      }
    }
    final enabledCount = tasks.where((t) => t.enabled).length;
    log.info('[Scheduler/Mobile] Synced $enabledCount enabled tasks (heartbeat-only mode)');

    if (enabledCount > 0) await _ensureHeartbeatRunning();
  }
}

// ─── Windows (in-process cron timer) ─────────────────────────────────────────

class WindowsSchedulerService implements SchedulerService {
  final Map<String, Timer> _timers = {};
  final Map<String, DateTime> _lastRun = {};
  // In-flight guard: task IDs currently executing (prevents overlapping runs).
  final Set<String> _inFlight = {};
  // Generation counter: stale callbacks detect they have been superseded.
  final Map<String, int> _generation = {};

  void _scheduleTimer(WorkflowTask task) {
    _timers.remove(task.id)?.cancel();
    if (!task.enabled) return;

    final myGeneration = (_generation[task.id] ?? 0) + 1;
    _generation[task.id] = myGeneration;

    final next = _nextCronFire(task.executionPlan.cronExpression);
    final delay = next.difference(DateTime.now());
    log.info('[Scheduler/Win] Next fire for "${task.name}": $next (in ${delay.inMinutes}m ${delay.inSeconds % 60}s)');

    _timers[task.id] = Timer(delay.isNegative ? Duration.zero : delay, () async {
      if (_generation[task.id] != myGeneration) {
        log.info('[Scheduler/Win] Stale callback for "${task.name}" — skipping');
        return;
      }
      await _runScheduledTask(task, _lastRun, prefix: 'Scheduler/Win', inFlight: _inFlight);
      if (_generation[task.id] != myGeneration) return;
      // Reschedule for the next cron occurrence
      try {
        final tasks = await TaskDatabaseService().getAllTasks();
        final fresh = tasks.where((t) => t.id == task.id).firstOrNull;
        if (fresh != null && fresh.enabled) _scheduleTimer(fresh);
      } catch (_) {
        _scheduleTimer(task);
      }
    });
  }

  @override
  Future<void> scheduleTask(WorkflowTask task) async {
    _timers.remove(task.id)?.cancel();
    if (!task.enabled) return;
    log.info('[Scheduler/Win] Scheduling "${task.name}" (cron: ${task.executionPlan.cronExpression})');
    _scheduleTimer(task);
  }

  @override
  Future<void> cancelTask(String taskId) async {
    _timers.remove(taskId)?.cancel();
    _lastRun.remove(taskId);
    _inFlight.remove(taskId);
    _generation.remove(taskId);
    log.info('[Scheduler/Win] Cancelled task $taskId');
  }

  @override
  Future<void> cancelAll() async {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    _lastRun.clear();
    _inFlight.clear();
    _generation.clear();
    log.info('[Scheduler/Win] All timers cancelled');
  }

  @override
  Future<void> syncAllTasks(List<WorkflowTask> tasks) async {
    final currentIds = tasks.map((t) => t.id).toSet();
    for (final id in _timers.keys.toList()) {
      if (!currentIds.contains(id)) {
        _timers.remove(id)?.cancel();
        _lastRun.remove(id);
        _inFlight.remove(id);
        _generation.remove(id);
      }
    }
    // Schedule synchronously (no await in the loop) so timers cannot fire
    // between iterations and observe a half-updated state.
    for (final task in tasks) {
      if (task.enabled) {
        _scheduleTimer(task);
      } else {
        _timers.remove(task.id)?.cancel();
      }
    }
    log.info('[Scheduler/Win] Synced ${tasks.where((t) => t.enabled).length} enabled tasks');
  }
}
