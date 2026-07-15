import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';

import '../database/duckdb_service.dart';
import '../database/task_database_service_duckdb.dart';
import '../mcp/internal_mcp_client_adapter.dart';
import '../mcp/internal_mcp_registry.dart';
import '../models/workflow_task.dart';
import '../models/mcp_models.dart';
import '../services/app_logger.dart';
import '../services/app_preferences_service.dart';
import '../services/chat_service.dart';
import '../services/data_sources_settings_service.dart';
import '../services/external_tools_settings_service.dart';
import '../services/llm_service.dart';
import '../services/llm_settings_service.dart';
import '../services/location_service.dart';
import '../services/mcp_client.dart';
import '../services/multi_mcp_manager.dart';
import '../services/email_delivery_service.dart';
import '../services/messaging_delivery_service.dart';
import '../services/notification_service.dart';
import '../services/function_hint_database_service.dart';
import '../services/scheduler_log_service.dart';
import '../services/embedded_llm/embedded_llm_adapter.dart';
import '../services/embedded_llm/embedded_model_manager.dart';
import '../services/shell_script_service.dart';
import '../utils/credential_cipher.dart';
import '../utils/cron_utils.dart';

// --- Result ----------------------------------------------------------------

class TaskRunResult {
  final bool success;
  final String resultText;
  final String? error;

  const TaskRunResult({
    required this.success,
    required this.resultText,
    this.error,
  });
}

// --- Service ---------------------------------------------------------------

/// Headless task runner.
///
/// Does NOT require a BuildContext or Riverpod WidgetRef.
/// Suitable for:
///   - WorkManager background callbacks (Android / iOS)
///   - Windows Timer.periodic callbacks in the tray app
///   - Manual "run now" from a Riverpod provider
///
/// Usage:
/// ```
/// // Boot minimal services first (in main isolate or background isolate)
/// await DuckDbService().init();
/// await LlmSettingsService.instance.load();
/// await ExternalToolsSettingsService.instance.load();
/// await DataSourcesSettingsService.instance.load();
///
/// final result = await TaskRunnerService().run(task);
/// ```
/// Set to `true` by [bootstrapTaskRunnerServices] when the runner is
/// initialised inside a background isolate (Android AlarmManager / WorkManager).
/// Embedded model tasks are skipped in this mode to protect against:
///   1. [LlamaBackend] double-initialisation — it registers GGML backends as
///      global native state; creating it a second time in the same OS process
///      exceeds GGML_SCHED_MAX_BACKENDS and hard-crashes the process.
///   2. OOM kills — loading a ≥2 GB GGUF model inside a restricted background
///      isolate leaves no headroom for inference and triggers the Android OOM
///      killer, which kills the process without writing any log entries.
bool _isBackgroundRunnerContext = false;

/// Whether the current isolate was booted as a background runner.
/// Readable by scheduler_service.dart to pre-filter embedded-model tasks
/// before pre-marking or running them.
bool get isBackgroundRunnerContext => _isBackgroundRunnerContext;

/// Returns true when [task] will use the embedded (on-device) LLM.
/// Checks the task's explicit provider first; falls back to the global LLM1
/// setting when no per-task provider is configured.
bool taskUsesEmbeddedLlm(WorkflowTask task) {
  final taskProvider = task.llmConfig?.provider;
  if (taskProvider == 'embedded') return true;
  if (taskProvider != null && taskProvider.isNotEmpty) return false;
  // No task-level override → uses global LLM1.
  if (LlmSettingsService.instance.isLoaded) {
    return LlmSettingsService.instance.provider.configKey == 'embedded';
  }
  return false;
}

class TaskRunnerService {
  static const String _formatInstruction =
      'Output formatting: If the user requests a specific format, you can format the response accordingly. '
      'Default to concise plain text when no specific format is requested.';

  /// Expose the output delivery helper publicly for UI execution flow dialog.
  Future<List<String>> deliverExecutorOutput({
    required WorkflowTask task,
    required Agent executor,
    required TaskRunResult result,
    required List<ChatMessage> capturedMessages,
    required DateTime startTime,
    required LLMService llmService,
  }) async {
    return _deliverExecutorOutput(
      task: task,
      executor: executor,
      result: result,
      capturedMessages: capturedMessages,
      startTime: startTime,
      llmService: llmService,
    );
  }

  /// Run [task] headlessly.
  ///
  /// Boots LLM + MCP services, sends the task prompt, saves execution result
  /// to the database, and shows a local notification.
  ///
  /// Returns the [TaskRunResult] -- always succeeds as an object (errors are
  /// captured inside [TaskRunResult.success] / [TaskRunResult.error]).
  Future<TaskRunResult> run(WorkflowTask task, {String? startExecutorId}) async {
    log.info('[TaskRunner] Running task "${task.name}" (id=${task.id})');

    final llmService = LLMService();
    final mcpManager = MultiMCPManager();
    final locationService = LocationService();
    TaskRunResult result = const TaskRunResult(
      success: false,
      resultText: '',
      error: 'Not executed',
    );
    Map<String, dynamic>? capturedStats;
    final startTime = DateTime.now();
    final List<String> accumulatedOutputFilePaths = [];
    TaskNotification getActiveNotification() {
      if (task.notification.email != null ||
          task.notification.download != null ||
          task.notification.sftpOutput != null ||
          task.notification.slack != null ||
          task.notification.whatsApp != null ||
          task.notification.push != null) {
        return task.notification;
      }
      for (final exec in task.agents) {
        final notif = exec.notification;
        if (notif.email != null ||
            notif.download != null ||
            notif.sftpOutput != null ||
            notif.slack != null ||
            notif.whatsApp != null ||
            notif.push != null) {
          return notif;
        }
      }
      return task.notification;
    }

    // Log that this task started
    await SchedulerLogService().addEntry(
      taskId: task.id,
      taskName: task.name,
      event: SchedulerEventType.started,
    );

    try {
      final List<Agent> executorsToRun = task.agents.isNotEmpty
          ? task.agents
          : [
              Agent(
                id: 'default',
                name: task.name,
                prompt: task.prompt,
                systemPrompt: task.systemPrompt,
                llmConfig: task.llmConfig,
                mcpTools: task.mcpTools,
                internalMcps: task.internalMcps,
                chatMode: task.chatMode,
                stopAfterToolCall: task.stopAfterToolCall,
              ),
            ];

      final Map<String, Agent> executorMap = {
        for (final e in executorsToRun) e.id: e,
      };
      Agent currentExecutor = startExecutorId != null
          ? (executorMap[startExecutorId] ?? executorsToRun.first)
          : executorsToRun.first;
      String previousStepOutput = '';
      int stepsExecuted = 0;
      int accumulatedPromptTokens = 0;
      int accumulatedCompletionTokens = 0;
      int accumulatedToolCallCount = 0;
      final List<ChatMessage> allStepsMessages = [];
      final executedSteps = <Map<String, dynamic>>[];

      while (stepsExecuted < 50) {
        stepsExecuted++;
        final stepStartTime = DateTime.now();
        log.info(
          '[TaskRunner] Executing step "${currentExecutor.name}" (id=${currentExecutor.id})',
        );

        // 0. Ensure embedded model is loaded
        await _ensureEmbeddedModelLoaded(
          task,
          executor: currentExecutor,
        ).timeout(
          const Duration(minutes: 3),
          onTimeout: () => throw TimeoutException(
            'Embedded model loading timed out after 3 minutes.',
            const Duration(minutes: 3),
          ),
        );

        // 1. Configure LLM
        await _configureLlm(llmService, task, executor: currentExecutor);

        if (!llmService.isConfigured) {
          throw Exception(
            'No LLM configured. Set up an LLM provider in Settings.',
          );
        }

        final llmHost = _getLlmHostname(llmService);
        if (llmHost != null && llmHost.isNotEmpty) {
          await _warmDns(llmHost);
        }

        // 2. Build system prompt
        final systemPrompt = await _buildSystemPrompt(
          task,
          executor: currentExecutor,
          isSlm: llmService.useSimplifiedPrompts,
        );

        // 3. Build ChatService
        final chatService = ChatService(
          mcpClient: mcpManager,
          llmService: llmService,
          locationService: locationService,
          getPluginPrompts: () => ProjectPrompts(systemPrompt: systemPrompt),
          stopAfterToolCall: currentExecutor.stopAfterToolCall,
        );

        // 4. Connect external MCPs
        await _connectExternalMcps(mcpManager, task, executor: currentExecutor);

        // 5. Connect internal MCPs
        await _connectInternalMcps(mcpManager, task, executor: currentExecutor);

        log.info(
          '[TaskRunner] Step "${currentExecutor.name}": ${mcpManager.availableTools.length} tools ready, sending prompt.',
        );

        if (llmHost != null && llmHost.isNotEmpty) {
          await _warmDns(llmHost);
        }

        // 6. Replace variables in prompt
        String promptToRun = currentExecutor.prompt;
        promptToRun = promptToRun
            .replaceAll(r'${task_output}', previousStepOutput)
            .replaceAll('[task_output]', previousStepOutput)
            .replaceAll(r'$(task_output)', previousStepOutput)
            .replaceAll(r'${task_result}', previousStepOutput)
            .replaceAll('[task_result]', previousStepOutput)
            .replaceAll(r'$(task_result)', previousStepOutput);

        if (!currentExecutor.prompt.contains('++#++')) {
          promptToRun = promptToRun
              .replaceAll(r'${tool_output}', previousStepOutput)
              .replaceAll('[tool_output]', previousStepOutput)
              .replaceAll(r'$(tool_output)', previousStepOutput)
              .replaceAll(r'${tool_result}', previousStepOutput)
              .replaceAll('[tool_result]', previousStepOutput)
              .replaceAll(r'$(tool_result)', previousStepOutput);
        }

        final isEmbedded = llmService.currentProvider == LLMProvider.embedded;
        final promptTimeout = isEmbedded
            ? const Duration(minutes: 12)
            : const Duration(minutes: 6);
        await chatService
            .sendMessage(promptToRun)
            .timeout(
              promptTimeout,
              onTimeout: () =>
                  throw TimeoutException('Task step timed out.', promptTimeout),
            );

        final stepStats = chatService.getChatStats();
        final stepMessages = chatService.messages;

        accumulatedPromptTokens += stepStats['prompt_tokens'] as int? ?? 0;
        accumulatedCompletionTokens +=
            stepStats['completion_tokens'] as int? ?? 0;
        accumulatedToolCallCount += stepStats['tool_call_count'] as int? ?? 0;
        allStepsMessages.addAll(stepMessages);

        const toolCallingPlaceholder =
            'Calling tools to retrieve the requested information...';
        ChatMessage? lastAssistant;
        for (final m in stepMessages.reversed) {
          if (m.role == ChatRole.assistant) {
            final content = m.content.trim();
            if (content.isEmpty || content == toolCallingPlaceholder) continue;
            lastAssistant = m;
            break;
          }
        }

        String assistantText = lastAssistant?.content.trim() ?? '';
        if (assistantText.isEmpty) {
          final toolTexts = stepMessages
              .where((m) => m.role == ChatRole.tool)
              .expand((m) => m.toolResult?.content ?? <MCPContent>[])
              .where((c) => c.text != null && c.text!.isNotEmpty)
              .map((c) => c.text!)
              .toList();
          if (toolTexts.isNotEmpty) {
            assistantText = toolTexts.join('\n\n');
          }
        }

        if (currentExecutor.stopAfterToolCall && !currentExecutor.prompt.contains('++#++')) {
          final toolTexts = stepMessages
              .where((m) => m.role == ChatRole.tool)
              .expand((m) => m.toolResult?.content ?? <MCPContent>[])
              .where((c) => c.text != null && c.text!.isNotEmpty)
              .map((c) => c.text!)
              .toList();
          if (toolTexts.isNotEmpty) {
            assistantText = toolTexts.join('\n\n');
          }
        }

        final isJsonError =
            assistantText.trimLeft().startsWith('{') &&
            (assistantText.contains('"error"') ||
                assistantText.contains('"statusCode"') ||
                assistantText.contains('"status_code"'));
        final stepSuccess =
            assistantText.isNotEmpty &&
            !assistantText.toLowerCase().startsWith('ai error') &&
            !isJsonError;

        if (!stepSuccess) {
          result = TaskRunResult(
            success: false,
            resultText: assistantText,
            error: assistantText.isEmpty
                ? 'Empty response from LLM'
                : _extractCleanMessage(assistantText),
          );
          executedSteps.add({
            'executor': currentExecutor,
            'messages': List<ChatMessage>.from(stepMessages),
            'assistantText': assistantText,
            'startTime': stepStartTime,
            'provider': llmService.currentProvider.name,
            'model': llmService.currentModel,
          });
          break;
        }

        previousStepOutput = assistantText;
        result = TaskRunResult(success: true, resultText: assistantText);

        capturedStats = {
          'prompt_tokens': accumulatedPromptTokens,
          'completion_tokens': accumulatedCompletionTokens,
          'tool_call_count': accumulatedToolCallCount,
        };

        // Clean up connections for the step before continuing
        await mcpManager.clear();

        executedSteps.add({
          'executor': currentExecutor,
          'messages': List<ChatMessage>.from(stepMessages),
          'assistantText': assistantText,
          'startTime': stepStartTime,
          'provider': llmService.currentProvider.name,
          'model': llmService.currentModel,
        });

        // 7. Dynamic Routing
        String? nextExecutorId;
        final rules = task.edges
            .where((r) => r.sourceAgentId == currentExecutor.id)
            .toList();
        final hasStopRule = rules.any((r) => r.operator == 'stop');

        if (rules.isNotEmpty && !hasStopRule) {
          for (final rule in rules) {
            final valueToCheck = previousStepOutput;
            log.info('[TaskRunner] Evaluating routing condition for "${currentExecutor.name}": "${rule.value}"');
            final met = await evaluateCondition(
              llmService: llmService,
              locationService: locationService,
              mcpManager: mcpManager,
              source: valueToCheck,
              operator: rule.operator,
              value: rule.value,
            );
            log.info('[TaskRunner] Condition "${rule.value}" result: ${met ? "MET (True)" : "NOT MET (False)"}');
            if (met) {
              nextExecutorId = rule.targetAgentId;
              log.info(
                '[TaskRunner] Routing condition met. Routing to $nextExecutorId',
              );
              break;
            }
          }
        }

        if (nextExecutorId != null) {
          if (executorMap.containsKey(nextExecutorId)) {
            currentExecutor = executorMap[nextExecutorId]!;
          } else {
            log.warning(
              '[TaskRunner] Routed target executor $nextExecutorId not found in agents list. Terminating.',
            );
            break;
          }
        } else {
          if (hasStopRule) {
            break;
          }
          if (rules.isNotEmpty && !hasStopRule) {
            log.info(
              '[TaskRunner] No routing conditions met for conditional step. Terminating.',
            );
            break;
          }
          final currentIndex = executorsToRun.indexOf(currentExecutor);
          if (currentIndex != -1 && currentIndex + 1 < executorsToRun.length) {
            final nextExec = executorsToRun[currentIndex + 1];
            if (nextExec.executionPlan != null) {
              log.info(
                '[TaskRunner] Next executor "${nextExec.name}" is scheduled independently. Stopping sequential run.',
              );
              break;
            }
            currentExecutor = nextExec;
          } else {
            break;
          }
        }
      }

      // Deliver combined task notification
      final activeNotif = getActiveNotification();
      final hasNotificationConfigured = activeNotif.email != null ||
          activeNotif.download != null ||
          activeNotif.sftpOutput != null ||
          activeNotif.slack != null ||
          activeNotif.whatsApp != null ||
          activeNotif.push != null;

      if (hasNotificationConfigured && executedSteps.isNotEmpty) {
        final combinedPaths = await _deliverCombinedOutput(
          task: task,
          notification: activeNotif,
          result: result,
          executedSteps: executedSteps,
          startTime: startTime,
          llmService: llmService,
        );
        accumulatedOutputFilePaths.addAll(combinedPaths);
      }

      log.info(
        '[TaskRunner] Task "${task.name}" finished -- success=${result.success}',
      );
    } catch (e, st) {
      log.error('[TaskRunner] Task "${task.name}" threw: $e', e, st);
      result = TaskRunResult(
        success: false,
        resultText: '',
        error: e.toString(),
      );
    } finally {
      // Dispose resources
      try {
        await mcpManager.clear();
        mcpManager.dispose();
      } catch (_) {}
      try {
        llmService.dispose();
      } catch (_) {}
    }

    final durationMs = DateTime.now().difference(startTime).inMilliseconds;

    // 8. Persist execution record
    try {
      final nextRun = nextCronFire(task.executionPlan.cronExpression);
      final execution = task.execution.recordRun(
        success: result.success,
        result: result.success
            ? (result.resultText.isNotEmpty ? result.resultText : null)
            : null,
        error: result.error,
        maxHistory: 10,
        outputFilePaths: accumulatedOutputFilePaths,
        rawOutput: result.success ? result.resultText : null,
        durationMs: durationMs,
        nextRun: nextRun,
        tokensUsed: capturedStats?['cumulativeTokens'] as int?,
        toolCallCount: capturedStats?['toolCalls'] as int?,
        messageCount: capturedStats?['totalMessages'] as int?,
        sentChars: capturedStats?['totalSentChars'] as int?,
        lastRequestCostUsd: (capturedStats?['lastRequestCostUsd'] as num?)
            ?.toDouble(),
        sessionCostUsd: (capturedStats?['sessionCostUsd'] as num?)?.toDouble(),
      );
      await TaskDatabaseService().updateExecution(task.id, execution);
      log.info(
        '[TaskRunner] Execution saved for task "${task.name}" (nextRun=$nextRun)',
      );
      if (startExecutorId != null) {
        final freshTask = await TaskDatabaseService().getTask(task.id);
        if (freshTask != null) {
          final updatedTask = freshTask.copyWith(
            agents: freshTask.agents.map((e) {
              if (e.id == startExecutorId) {
                final execNextRun = e.executionPlan != null
                    ? nextCronFire(e.executionPlan!.cronExpression).toUtc()
                    : null;
                return e.copyWith(
                  lastRun: DateTime.now().toUtc(),
                  nextRun: execNextRun,
                );
              }
              return e;
            }).toList(),
          );
          await TaskDatabaseService().saveTask(updatedTask);
          log.info(
            '[TaskRunner] Execution saved for executor "$startExecutorId" of "${task.name}"',
          );
        }
      }
    } catch (e) {
      log.warning('[TaskRunner] Failed to save execution: $e');
    }

    // 8b. Log task completion
    await SchedulerLogService().addEntry(
      taskId: task.id,
      taskName: task.name,
      event: result.success
          ? SchedulerEventType.completed
          : SchedulerEventType.failed,
      detail: result.success
          ? '${durationMs}ms'
          : (result.error ?? 'unknown error'),
    );

    // 9. Show notification (clean body -- no raw JSON)
    try {
      String body;
      if (result.success) {
        final text = result.resultText.trim();
        if (text.isEmpty) {
          body = 'Task completed successfully.';
        } else {
          final isJson =
              text.trimLeft().startsWith('{') ||
              text.trimLeft().startsWith('[');
          body = isJson
              ? 'Task completed successfully.'
              : (text.length > 200 ? '${text.substring(0, 200)}...' : text);
        }
      } else {
        final raw = (result.error ?? 'Task failed.').trim();
        final err = _extractCleanMessage(raw);
        body = err.length > 200 ? '${err.substring(0, 200)}...' : err;
      }
      await NotificationService.instance.showTaskResult(
        taskName: task.name,
        success: result.success,
        body: body,
        id: task.id.hashCode,
      );
    } catch (e) {
      log.warning('[TaskRunner] Notification failed: $e');
    }

    // 11. Task chaining -- evaluate condition and trigger follow-up task if configured
    if (result.success) {
      await runChainIfConfigured(task, result);
    }

    // 12. Unload embedded model to free device memory.
    final adapter = EmbeddedLlmAdapter.instance;
    if (adapter.isLoaded) {
      try {
        await adapter.dispose();
        log.info(
          '[TaskRunner] Embedded model unloaded after task "${task.name}".',
        );
      } catch (e) {
        log.warning('[TaskRunner] Failed to unload embedded model: $e');
      }
    }

    return result;
  }

  // --- LLM ----------------------------------------------------------------

  // --- Task Chaining ------------------------------------------------------

  /// Evaluate [task.chainConfig] after a successful run.
  ///
  /// 1. If [triggerCondition] is set, ask the LLM whether it holds given
  ///    [result.resultText]. The answer selects [onMatchTaskId] (true) or
  ///    [onNoMatchTaskId] (false).
  /// 2. If there is no condition, [onMatchTaskId] is always triggered.
  /// 3. Load the target task from DB, inject `\${task_result}` into its prompt,
  ///    then call [run] recursively (guarded by depth limited scheduler log).
  Future<void> runChainIfConfigured(
    WorkflowTask task,
    TaskRunResult result,
  ) async {
    final chain = task.chainConfig;
    if (chain == null || !chain.hasChaining) return;

    String? targetTaskId;
    try {
      if (chain.triggerCondition != null &&
          chain.triggerCondition!.trim().isNotEmpty) {
        log.info(
          '[TaskRunner] Evaluating chain condition: "${chain.triggerCondition}"',
        );
        final conditionMet = await _evaluateChainCondition(
          condition: chain.triggerCondition!,
          taskResult: result.resultText,
          parentTask: task,
        );
        log.info('[TaskRunner] Chain condition result: $conditionMet');
        targetTaskId = conditionMet
            ? chain.onMatchTaskId
            : chain.onNoMatchTaskId;
        await SchedulerLogService().addEntry(
          taskId: task.id,
          taskName: task.name,
          event: SchedulerEventType.completed,
          detail:
              'chain-condition: ${conditionMet ? "matched" : "no-match"} -> ${targetTaskId ?? "none"}',
        );
      } else {
        // No condition -> always run onMatchTaskId
        targetTaskId = chain.onMatchTaskId;
      }

      if (targetTaskId == null || targetTaskId.trim().isEmpty) {
        log.info(
          '[TaskRunner] No chain target task configured for this branch.',
        );
        return;
      }

      final db = TaskDatabaseService();
      final chainedTask = await db.getTask(targetTaskId);
      if (chainedTask == null) {
        log.warning('[TaskRunner] Chain target task not found: $targetTaskId');
        await SchedulerLogService().addEntry(
          taskId: task.id,
          taskName: task.name,
          event: SchedulerEventType.failed,
          detail: 'chain-error: target task $targetTaskId not found',
        );
        return;
      }

      // Inject parent result into the chained task's prompt
      final injectedPrompt = chainedTask.prompt
          .replaceAll(r'${task_result}', result.resultText.trim())
          .replaceAll('[task_result]', result.resultText.trim())
          .replaceAll(r'$(task_result)', result.resultText.trim())
          .replaceAll(r'${task_output}', result.resultText.trim())
          .replaceAll('[task_output]', result.resultText.trim())
          .replaceAll(r'$(task_output)', result.resultText.trim())
          .replaceAll(r'${tool_result}', result.resultText.trim())
          .replaceAll('[tool_result]', result.resultText.trim())
          .replaceAll(r'$(tool_result)', result.resultText.trim())
          .replaceAll(r'${tool_output}', result.resultText.trim())
          .replaceAll('[tool_output]', result.resultText.trim())
          .replaceAll(r'$(tool_output)', result.resultText.trim());
      final taskToRun = chainedTask.copyWith(prompt: injectedPrompt);

      log.info(
        '[TaskRunner] Running chained task "${chainedTask.name}" (id=$targetTaskId)',
      );
      await SchedulerLogService().addEntry(
        taskId: task.id,
        taskName: task.name,
        event: SchedulerEventType.started,
        detail: 'chain-start: ${chainedTask.name}',
      );

      // Run the chained task (recursive, but depth is naturally bounded by task design)
      await TaskRunnerService().run(taskToRun);
    } catch (e, st) {
      log.error('[TaskRunner] Chain execution failed: $e', e, st);
      await SchedulerLogService().addEntry(
        taskId: task.id,
        taskName: task.name,
        event: SchedulerEventType.failed,
        detail: 'chain-exception: $e',
      );
    }
  }

  /// Ask the LLM whether [condition] is satisfied given [taskResult].
  ///
  /// Returns `true` if the LLM answers "true" (case-insensitive), `false` otherwise.
  Future<bool> _evaluateChainCondition({
    required String condition,
    required String taskResult,
    required WorkflowTask parentTask,
  }) async {
    final llmService = LLMService();
    try {
      await _configureLlm(llmService, parentTask);
      if (!llmService.isConfigured) {
        log.warning(
          '[TaskRunner] LLM not configured -- chain condition defaults to false',
        );
        return false;
      }

      final chatService = ChatService(
        mcpClient: MultiMCPManager(),
        llmService: llmService,
        locationService: LocationService(),
        getPluginPrompts: () => ProjectPrompts(
          systemPrompt:
              'You are a condition evaluator. Reply with ONLY the single word "true" or "false". Never explain.',
        ),
      );

      final taskResultSnippet = taskResult.length > 2000
          ? '${taskResult.substring(0, 2000)}...'
          : taskResult;

      final prompt =
          'Evaluate this condition based on the task result below.\n'
          'Condition: $condition\n'
          '\n'
          'Task result:\n'
          '```\n'
          '$taskResultSnippet\n'
          '```\n'
          '\n'
          'Reply with ONLY the single word "true" if the condition is met, or "false" if not.';

      await chatService.sendMessage(prompt);

      final messages = chatService.messages;
      String reply = '';
      for (final m in messages.reversed) {
        if (m.role == ChatRole.assistant) {
          reply = m.content.trim().toLowerCase();
          break;
        }
      }
      chatService.dispose();
      return reply.contains('true');
    } catch (e) {
      log.warning('[TaskRunner] Condition evaluation error: $e');
      return false;
    } finally {
      try {
        llmService.dispose();
      } catch (_) {}
    }
  }

  /// Resolves the embedded GGUF model path for [task] and ensures it is
  /// loaded into [EmbeddedLlmAdapter] before task execution begins.
  ///
  /// - If the task (or global settings) does NOT use the embedded provider,
  ///   returns immediately without doing anything.
  /// - If a different embedded model is currently loaded it is unloaded first
  ///   to free device memory before the required model is loaded.
  /// - Throws a descriptive [StateError] if loading fails, so the task result
  ///   surfaces a clear error instead of the misleading "model not loaded"
  ///   message that would otherwise come from [_generateWithEmbedded].
  Future<void> _ensureEmbeddedModelLoaded(
    WorkflowTask task, {
    Agent? executor,
  }) async {
    // Determine the effective provider + model, mirroring _configureLlm logic.
    final effectiveLlmConfig = executor?.llmConfig ?? task.llmConfig;
    String? provider = effectiveLlmConfig?.provider;
    String? model = effectiveLlmConfig?.model;

    if (provider == null || provider.isEmpty) {
      final settings = LlmSettingsService.instance;
      if (!settings.isLoaded) await settings.load();
      provider = settings.provider.configKey;
      model = settings.model;
    } else if (provider == 'llm2') {
      final settings = LlmSettingsService.instance;
      if (!settings.isLoaded) await settings.load();
      provider = settings.provider2.configKey;
      model = (effectiveLlmConfig?.model.isNotEmpty == true)
          ? effectiveLlmConfig!.model
          : settings.model2;
    } else if (provider == 'embedded' && (model == null || model.isEmpty)) {
      // Task explicitly selects embedded but left the model blank —
      // fall back to the globally selected embedded model.
      final settings = LlmSettingsService.instance;
      if (!settings.isLoaded) await settings.load();
      model = settings.model;
    }

    if (provider != 'embedded') return; // nothing to do for cloud providers

    // Background isolates must not load the embedded model: LlamaBackend
    // registers GGML backends as global native state and crashes if created
    // twice in the same OS process. Loading ≥2 GB into a background isolate
    // also triggers the Android OOM killer before inference can even start.
    if (_isBackgroundRunnerContext) {
      throw StateError(
        'Embedded model tasks require the app to be open. '
        'Background alarm isolates cannot load the GGUF model (risk of '
        'LlamaBackend double-init crash or OOM kill). '
        'Open the app, or switch this task to a cloud LLM for background scheduling.',
      );
    }

    if (model == null || model.isEmpty) {
      throw StateError(
        'Embedded LLM is selected for task "${task.name}" but no GGUF model '
        'file is configured. Open Settings → LLM and select a downloaded model.',
      );
    }

    final fullPath = await EmbeddedModelManager.instance.fullPathForFilename(
      model,
    );
    final adapter = EmbeddedLlmAdapter.instance;

    // Fast path: correct model already loaded.
    if (adapter.isLoaded && adapter.loadedModelPath == fullPath) return;

    if (adapter.isLoaded) {
      log.info(
        '[TaskRunner] Unloading embedded model "${adapter.loadedModelPath}" '
        'to free memory before loading "$model".',
      );
      // dispose() frees native model/context handles without touching the
      // shared LlamaBackend (which must stay alive for the app's lifetime).
      await adapter.dispose();
    }

    log.info('[TaskRunner] Loading embedded model "$model" (path=$fullPath).');
    try {
      await adapter.initialize(fullPath);
    } catch (e, st) {
      log.error(
        '[TaskRunner] Failed to load embedded model "$model": $e',
        e,
        st,
      );
      throw StateError(
        'Failed to load embedded model "$model": $e. '
        'Ensure the GGUF file exists in app storage and the device has '
        'enough free memory.',
      );
    }

    if (!adapter.isLoaded) {
      throw StateError(
        'Embedded model "$model" reported as not ready after loading. '
        'Try restarting the app or re-downloading the model.',
      );
    }
    log.info('[TaskRunner] Embedded model "$model" ready.');
  }

  Future<void> _configureLlm(
    LLMService llmService,
    WorkflowTask task, {
    Agent? executor,
  }) async {
    final effectiveLlmConfig = executor?.llmConfig ?? task.llmConfig;
    String? provider = effectiveLlmConfig?.provider;
    String? model = effectiveLlmConfig?.model;
    String? apiKey = effectiveLlmConfig?.apiKey;
    String? baseUrl = effectiveLlmConfig?.baseUrl;

    final settings = LlmSettingsService.instance;
    if (!settings.isLoaded) await settings.load();

    bool useNativeToolCall = settings.useNativeToolCall;

    if (provider == null || provider.isEmpty) {
      provider = settings.provider.configKey;
      model = settings.model;
      apiKey = settings.apiKey;
      baseUrl = settings.baseUrl;
      useNativeToolCall = settings.useNativeToolCall;
    } else if (provider == 'llm2') {
      // Task-level "use LLM 2 from global settings", but respect any per-task overrides
      provider = settings.provider2.configKey;
      // Use task's explicit model override if set, otherwise fall back to global LLM2 model
      model = (effectiveLlmConfig?.model.isNotEmpty == true)
          ? effectiveLlmConfig!.model
          : settings.model2;
      apiKey = settings.apiKey2;
      baseUrl =
          effectiveLlmConfig?.baseUrl ??
          (settings.baseUrl2.isNotEmpty ? settings.baseUrl2 : null);
      useNativeToolCall = settings.useNativeToolCall2;
    }

    if (provider.isEmpty || provider == 'none') return;

    try {
      await configureLlmFromParams(
        llmService: llmService,
        providerKey: provider,
        model: model ?? '',
        apiKey: apiKey,
        baseUrl: baseUrl,
        useNativeToolCall: useNativeToolCall,
      );
    } catch (e) {
      log.warning('[TaskRunner] LLM config failed: $e');
    }

    // Sync SLM flag → useSimplifiedPrompts so the chat service uses the right system prompt.
    // Also honour per-task model overrides: a small model name takes priority over global isSlm flags.
    final useLlm2 = task.llmConfig?.provider == 'llm2';
    bool isSlm;
    if (task.llmConfig != null && task.llmConfig!.provider != 'llm2') {
      isSlm = (task.llmConfig!.extraParams['is_slm'] as bool?) ?? false;
    } else {
      isSlm = useLlm2 ? settings.isSlm2 : settings.isSlm;
    }
    // If the task overrides the model, re-derive isSlm from that model name
    final effectiveModel = model ?? '';
    if (effectiveModel.isNotEmpty) {
      isSlm = isSlm || _isSmallModelByName(effectiveModel);
    }
    llmService.setUseSimplifiedPrompts(isSlm);
    llmService.setThinking(useLlm2 ? settings.thinking2 : settings.thinking);
  }

  /// Returns true when [modelName] identifies a small (≤14B) model based on its
  /// parameter-count tag (e.g. `:8b`, `-14b`, `_7B`) or well-known small-model
  /// keywords (`phi`, `tiny`, `nano`, `mini`, `tinyllama`).
  static bool _isSmallModelByName(String modelName) {
    final lower = modelName.toLowerCase();
    // Keyword shortcuts
    if (RegExp(r'\b(phi|tiny|nano|tinyllama)\b').hasMatch(lower)) return true;
    if (lower.contains(':mini') || lower.contains('-mini')) return true;
    // Numeric param-count tag: :NNb / -NNb / _NNb where NN ≤ 14
    final match = RegExp(r'[:\-_](\d+(?:\.\d+)?)b\b').firstMatch(lower);
    if (match != null) {
      final params = double.tryParse(match.group(1)!);
      if (params != null && params <= 7) return true;
    }
    return false;
  }

  /// Shared utility: configure an [LLMService] from raw provider params.
  /// Used both by [_configureLlm] and by code-generation dialogs.
  static Future<void> configureLlmFromParams({
    required LLMService llmService,
    required String providerKey,
    required String model,
    String? apiKey,
    String? baseUrl,
    bool useNativeToolCall = true,
  }) async {
    switch (providerKey.toLowerCase()) {
      case 'gemini':
      case 'google':
        await llmService.initializeGemini(
          apiKey: apiKey ?? '',
          model: model.isNotEmpty ? model : 'gemini-2.5-flash',
        );
      case 'openai':
        await llmService.initializeOpenAI(
          apiKey: apiKey ?? '',
          model: model.isNotEmpty ? model : 'gpt-4o-mini',
        );
      case 'claude':
      case 'anthropic':
        await llmService.initializeClaude(
          apiKey: apiKey ?? '',
          model: model.isNotEmpty ? model : 'claude-3-5-sonnet-20241022',
        );
      case 'ollama':
        await llmService.initializeOllama(
          baseUrl: (baseUrl != null && baseUrl.isNotEmpty)
              ? baseUrl
              : 'http://localhost:11434/api',
          model: model.isNotEmpty ? model : 'llama3.1:latest',
          apiKey: (apiKey != null && apiKey.isNotEmpty) ? apiKey : null,
          useNativeToolCall: useNativeToolCall,
        );
      case 'mistral':
        await llmService.initializeOpenAICompatible(
          baseUrl: (baseUrl != null && baseUrl.isNotEmpty)
              ? baseUrl
              : 'https://api.mistral.ai/v1',
          apiKey: apiKey,
          model: model.isNotEmpty ? model : 'mistral-medium-latest',
        );
      case 'openai_compatible':
      case 'openaicompatible':
        await llmService.initializeOpenAICompatible(
          baseUrl: baseUrl ?? '',
          apiKey: apiKey,
          model: model.isNotEmpty ? model : 'local-model',
        );
      case 'embedded':
        // model = GGUF filename stored in app documents/models/
        final fullPath = await EmbeddedModelManager.instance
            .fullPathForFilename(model);
        await llmService.initializeEmbedded(modelPath: fullPath);
    }
  }

  // --- System prompt ------------------------------------------------------

  Future<String> _buildSystemPrompt(
    WorkflowTask task, {
    Agent? executor,
    bool isSlm = false,
  }) async {
    var prompt = (executor?.systemPrompt ?? task.systemPrompt ?? '').trim();

    final internalMcps = executor?.internalMcps ?? task.internalMcps;
    // Append toolbox default system prompt (unless explicitly disabled for this task)
    final toolboxDisabledForPrompt = internalMcps.any(
      (m) => m.mcpType == 'toolbox' && !m.enabled,
    );
    final toolboxPrompt = toolboxDisabledForPrompt
        ? null
        : InternalMcpRegistry().create('toolbox')?.defaultSystemPrompt.trim();
    if (toolboxPrompt != null && toolboxPrompt.isNotEmpty) {
      prompt = prompt.isEmpty ? toolboxPrompt : '$prompt\n\n$toolboxPrompt';
    }

    // Append per-MCP capability hints so the LLM knows which tools are available
    final capabilityHints = <String>[];
    var hasWebSearch = false;
    for (final entry in internalMcps) {
      if (!entry.enabled) continue;
      switch (entry.mcpType) {
        case 'gmail':
          capabilityHints.add(
            'Email: use search_gmail (q: Gmail query syntax, includeBody: true to get full text) '
            'and get_gmail_message for a single message. '
            'Supports: from:, to:, subject:, after:YYYY/MM/DD, newer_than:Nd, has:attachment.',
          );
        case 'google_calendar':
          capabilityHints.add(
            'Google Calendar: use list_calendars to see calendars, '
            'list_events (calendarId, timeMin, timeMax, q) to fetch events, '
            'create_event (summary, start, end) to add events, '
            'update_event to modify, delete_event to remove. '
            'Times must be ISO 8601 with timezone (e.g. 2026-02-24T10:00:00+01:00).',
          );
        case 'document':
          capabilityHints.add(
            'Local documents: use search_documents and get_document_content.',
          );
        case 'file':
          capabilityHints.add(
            'File output: use create_text_file to create .txt/.md/.html files.',
          );
        case 'google_drive':
          capabilityHints.add(
            'Google Drive: use search_drive and read_drive_file.',
          );
        case 'onedrive':
          capabilityHints.add(
            'OneDrive: use search_onedrive and read_onedrive_file.',
          );
        case 'website_search':
          hasWebSearch = true;
          capabilityHints.add(
            'Indexed websites: use search_indexed_websites and get_indexed_page. '
            'Always format every result URL as a Markdown link [Page Title](https://...) '
            'so the user can tap it directly -- never output a bare URL string.',
          );
        case 'web_search':
          hasWebSearch = true;
          capabilityHints.add(
            'Public web: use web_search for current/public information. '
            'ONLY include URLs returned verbatim by the web_search tool — '
            'NEVER invent or recall URLs from training knowledge. '
            'Use broad queries without site: operators unless the user names a specific site. '
            'If a search returns 0 results, try once with a simpler query, then move on.',
          );
        case 'weather':
          capabilityHints.add(
            'Weather: use weather tools for forecasts and current conditions.',
          );
        case 'imap':
          capabilityHints.add(
            'IMAP email: use search_emails (params: from, to, subject, body, since/before YYYY-MM-DD, unseen bool, folder default INBOX, maxResults) '
            'to find emails, then read_email (uid, folder) to get the full body. '
            'Use list_folders to see available mailboxes. '
            'If you need the current date/time to compute since/before values, call get_current_time first.',
          );
        case 'pdf':
          capabilityHints.add(
            'PDF: use pdf tools to generate or read PDF documents.',
          );
        case 'chart':
          capabilityHints.add(
            'Charts: use create_chart_png to build PNG charts. '
            'Supported chartTypes: line, bar, area, pie, scatter, histogram, statistics_summary. '
            'Provide xAxis labels, series data, optional title, xAxisTitle, yAxisTitle. '
            'Use statistics_summary for a 4-panel dashboard.',
          );
      }
    }
    if (capabilityHints.isNotEmpty) {
      final String hintsBlock;
      if (isSlm) {
        // Short tool list for small models: first sentence of each hint + explicit call-first instruction
        final shortHints = capabilityHints
            .map((h) => h.split('.').first.trim())
            .join('\n- ');
        hintsBlock =
            'Available tools:\n- $shortHints\nAlways call a tool immediately to get data — never answer from memory.';
      } else {
        if (hasWebSearch) {
          capabilityHints.add(
            'Never output generic placeholders like "Link". Show readable title plus absolute URL.',
          );
        }
        hintsBlock = 'Enabled capabilities:\n- ${capabilityHints.join('\n- ')}';
      }
      prompt = prompt.isEmpty ? hintsBlock : '$prompt\n\n$hintsBlock';
    }

    // Inject stored user location coordinates into every task if toolbox is enabled
    final ds = DataSourcesSettingsService.instance;
    final hasToolbox = !toolboxDisabledForPrompt;
    if (hasToolbox && ds.locationLatitude != null && ds.locationLongitude != null) {
      final locCtx =
          'USER LOCATION: The user is currently at coordinates '
          '${ds.locationLatitude!.toStringAsFixed(5)}, ${ds.locationLongitude!.toStringAsFixed(5)}. '
          'When the user says "my location", "here", "near me" or "current position", use these coordinates. '
          'IMPORTANT: For travel searches (flights, trains, hotels, restaurants, weather, etc.) that require '
          'a city name, region, or airport code, first determine the nearest city and airport from these '
          'coordinates — do NOT use a default or example city like Los Angeles. Always derive the departure '
          'location from the user\'s actual coordinates.';
      prompt = prompt.isEmpty ? locCtx : '$prompt\n\n$locCtx';
    }

    if (!prompt.contains(_formatInstruction)) {
      prompt = prompt.isEmpty
          ? _formatInstruction
          : '$prompt\n\n$_formatInstruction';
    }

    // Always strip any pre-baked "Tool Skills:" block and rebuild it fresh.
    // The editor may have generated an incomplete block (e.g. external servers were
    // not yet connected at the time the prompt was authored), so we always discard
    // the stale preview and inject the authoritative runtime version here.
    final skillsMarker = '\n\nTool Skills:';
    final skillsIdx = prompt.lastIndexOf(skillsMarker);
    if (skillsIdx >= 0) {
      prompt = prompt.substring(0, skillsIdx);
    } else if (prompt.trimLeft().startsWith('Tool Skills:')) {
      prompt = '';
    }

    // Inject tool skills — skipped for SLMs (4K context budget must be reserved for conversation).
    if (!isSlm) {
      try {
        final toolNames = <String>[
          ...task.internalMcps.where((e) => e.enabled).expand((e) {
            final server = InternalMcpRegistry().create(e.mcpType);
            return server?.tools.map((t) => t.name) ?? <String>[];
          }),
          ...task.mcpTools.expand((s) => s.discoveredTools),
        ];
        if (toolNames.isNotEmpty) {
          final skills = await FunctionHintDatabaseService().getEnabledForTools(
            toolNames,
          );
          if (skills.isNotEmpty) {
            final skillLines = skills
                .where((s) => s.skillText.trim().isNotEmpty)
                .map((s) => '• ${s.toolName}: ${s.skillText.trim()}')
                .join('\n');
            if (skillLines.isNotEmpty) {
              prompt = prompt.isEmpty
                  ? 'Tool Skills:\n$skillLines'
                  : '$prompt\n\nTool Skills:\n$skillLines';
            }
          }
        }
      } catch (_) {}
    }

    return prompt;
  }

  // --- Raw output log -----------------------------------------------------

  /// Build a structured markdown "Output Raw" log from the captured messages,
  /// matching the format shown in the app's task detail view.
  String _buildRawOutput({
    required WorkflowTask task,
    required List<ChatMessage> messages,
    required DateTime startTime,
    required LLMService llmService,
  }) {
    try {
      final buf = StringBuffer();
      final ts =
          '${startTime.year}-${_pad(startTime.month)}-${_pad(startTime.day)} '
          '${_pad(startTime.hour)}:${_pad(startTime.minute)}:${_pad(startTime.second)}';

      final provider =
          task.llmConfig?.provider ?? llmService.currentProvider.name;
      final model = task.llmConfig?.model ?? llmService.currentModel;

      buf.writeln('## Step 1 of 1');
      buf.writeln();
      buf.writeln('**Timestamp:** $ts');
      buf.writeln('**Provider:** $provider');
      buf.writeln('**Model:** $model');
      buf.writeln();
      buf.writeln('### Prompt');
      buf.writeln();
      buf.writeln('```');
      buf.writeln(task.prompt.trim());
      buf.writeln('```');
      buf.writeln();
      buf.writeln('### LLM Interactions');

      int toolIteration = 0;
      String? pendingToolName;

      for (final msg in messages) {
        switch (msg.role) {
          case ChatRole.assistant:
            final content = msg.content.trim();
            if (content.isEmpty) break;
            // Check if it contains tool call references (assistant calling tools)
            if (msg.availableTools != null ||
                content.toLowerCase().contains('calling tools')) {
              buf.writeln();
              buf.writeln('**Initial LLM Response:**');
              if (content.isNotEmpty &&
                  content !=
                      'Calling tools to retrieve the requested information...') {
                buf.writeln();
                buf.writeln(content);
              }
              // List the tool calls hinted by lastCalledToolName or availableTools
              if (msg.lastCalledToolName != null) {
                pendingToolName = msg.lastCalledToolName;
                buf.writeln('Function Calls:');
                buf.writeln('- `${msg.lastCalledToolName}`');
              }
            } else {
              buf.writeln();
              buf.writeln('**Final Response:**');
              buf.writeln();
              buf.writeln(content);
            }
          case ChatRole.tool:
            final toolResult = msg.toolResult;
            final name = pendingToolName ?? msg.lastCalledToolName ?? 'tool';
            pendingToolName = null;
            buf.writeln();
            buf.writeln(
              '**Function Result (Iteration $toolIteration):** `$name`',
            );
            buf.writeln();
            buf.writeln('```');
            final resultText =
                toolResult?.content.map((c) => c.text ?? '').join('\n') ??
                msg.content;
            // Pretty-print JSON so it is readable in the execution log.
            final prettyResult = _prettyPrintIfJson(resultText.trim());
            // Show up to 8 non-empty lines, max 500 chars, then truncate.
            final nonEmptyLines = prettyResult
                .split('\n')
                .where((l) => l.trim().isNotEmpty)
                .take(8)
                .join('\n');
            const maxToolChars = 128;
            final trimmed = nonEmptyLines.isEmpty
                ? '(empty)'
                : nonEmptyLines.length > maxToolChars
                ? '${nonEmptyLines.substring(0, maxToolChars)}...'
                : nonEmptyLines;
            buf.writeln(trimmed);
            buf.writeln('```');
            toolIteration++;
          default:
            break;
        }
      }

      return buf.toString().trim();
    } catch (e) {
      return '';
    }
  }

  String _pad(int n) => n.toString().padLeft(2, '0');

  /// If [text] is a JSON object or array (starts with `{` or `[`), parse and
  /// re-encode with indentation so the output is human-readable.
  /// Returns [text] unchanged if it is not valid JSON or is already multi-line.
  String _prettyPrintIfJson(String text) {
    final trimmed = text.trim();
    if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return text;
    // Already multi-line -> probably already formatted
    if (trimmed.contains('\n')) return text;
    try {
      final decoded = jsonDecode(trimmed);
      const encoder = JsonEncoder.withIndent('  ');
      return encoder.convert(decoded);
    } catch (_) {
      return text;
    }
  }

  String? _extractHtmlFromOutput(String text) {
    // 1. Markdown code fence: ```html\n...\n```
    final fenceMatch = RegExp(
      r'```html\s*\n([\s\S]*?)\n?```',
      caseSensitive: false,
    ).firstMatch(text);
    if (fenceMatch != null) {
      final extracted = fenceMatch.group(1)?.trim() ?? '';
      if (extracted.isNotEmpty) return extracted;
    }
    // 2. Raw HTML (starts with <!DOCTYPE html> or <html)
    final trimmed = text.trim();
    final lower = trimmed.toLowerCase();
    if (lower.contains('<!doctype html') || lower.contains('<html')) {
      final htmlMatch = RegExp(
        r'(?:<!doctype\s+html[^>]*>\s*)?<html[\s\S]*?</html>',
        caseSensitive: false,
      ).firstMatch(trimmed);
      if (htmlMatch != null) return htmlMatch.group(0)!.trim();
      return trimmed;
    }
    // 3. Fallback: contains common HTML tags (div, table, p, h1, etc.)
    if (RegExp(
      r'<(div|span|table|p|h1|h2|h3|ul|ol|li|body)[\s>]',
      caseSensitive: false,
    ).hasMatch(lower)) {
      return trimmed;
    }
    return null;
  }

  /// Scans [text] for a filename hint like "saved as `report.html`" or
  /// "find the file at `disk_usage.html`" and returns it sanitised.
  String? _extractHtmlFileName(String text) {
    final match = RegExp(
      r'(?:file\s+at|saved\s+as|file\s+is|named?|called?|output\s+(?:file|is)|the\s+file)[^\n`"]*[`"]?([\w][\w.\-]*\.html)[`"\s]?',
      caseSensitive: false,
    ).firstMatch(text);
    if (match != null) {
      final raw = match.group(1)!.trim();
      final safe = raw.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      if (safe.isNotEmpty && safe != 'output.html') return safe;
    }
    // Fallback: any backtick-quoted .html token in the first 400 chars
    final quickMatch = RegExp(
      r'`([\w][\w.\-]*\.html)`',
      caseSensitive: false,
    ).firstMatch(text.length > 400 ? text.substring(0, 400) : text);
    if (quickMatch != null) {
      final raw = quickMatch.group(1)!.trim();
      final safe = raw.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      if (safe.isNotEmpty && safe != 'output.html') return safe;
    }
    return null;
  }

  /// Extracts a human-readable message from a potentially JSON-formatted error string.
  /// Handles nested malformed JSON like `{code: 401, message: Request had invalid...}`.
  String _extractCleanMessage(String text) {
    final t = text.trim();
    if (t.startsWith('{') || t.startsWith('[')) {
      try {
        final decoded = jsonDecode(t) as Map<String, dynamic>;
        final msg = decoded['error'] ?? decoded['message'] ?? decoded['detail'];
        if (msg != null) {
          final msgStr = msg.toString();
          // Inner value may be malformed JSON like {code: 401, message: Request had invalid...}
          final re = RegExp(r'message:\s*([^,}]+)');
          final m = re.firstMatch(msgStr);
          if (m != null) return m.group(1)?.trim() ?? msgStr;
          return msgStr;
        }
      } catch (_) {
        // Malformed outer JSON -- try regex to find "error":"..." value
        final re = RegExp(r'"error"\s*:\s*"([^"]+)"');
        final m = re.firstMatch(t);
        if (m != null) return m.group(1) ?? 'Task failed.';
      }
      return 'Task failed.';
    }
    return t;
  }

  Future<void> _connectExternalMcps(
    MultiMCPManager manager,
    WorkflowTask task, {
    Agent? executor,
  }) async {
    final extSvc = ExternalToolsSettingsService.instance;
    if (!extSvc.isLoaded) await extSvc.load();

    final mcpTools = executor?.mcpTools ?? task.mcpTools;
    for (final serverConfig in mcpTools) {
      try {
        final baseUrl = serverConfig.serverUrl.trim().replaceAll(
          RegExp(r'/+$'),
          '',
        );
        var endpoint = (serverConfig.mcpEndpoint ?? '/mcp').trim();
        if (endpoint.isEmpty) endpoint = '/mcp';
        if (!endpoint.startsWith('/')) endpoint = '/$endpoint';

        final (resolvedBase, resolvedKey) = await extSvc
            .resolveSmitheryEndpoint(baseUrl, serverConfig.apiKey);
        // Don't append endpoint if the URL path already includes /mcp.
        // Use URI path inspection so embedded ?api_key= query params don't break the check.
        final parsedResolved = Uri.parse(resolvedBase);
        final url = parsedResolved.path.toLowerCase().endsWith('/mcp')
            ? resolvedBase
            : parsedResolved
                  .replace(path: parsedResolved.path + endpoint)
                  .toString();

        final client = MCPClient(url, bearerToken: resolvedKey);
        await client.connect().timeout(
          const Duration(seconds: 15),
          onTimeout: () {
            log.warning(
              '[TaskRunner] Timeout MCP: ${serverConfig.name ?? url}',
            );
          },
        );

        manager.registerClient(
          MCPClientDef(
            name: serverConfig.name ?? Uri.parse(url).host,
            client: client,
            displayName: serverConfig.name,
          ),
        );
      } catch (e) {
        log.warning(
          '[TaskRunner] MCP connect failed ${serverConfig.serverUrl}: $e',
        );
      }
    }
  }

  // --- Internal MCPs ------------------------------------------------------

  Future<void> _connectInternalMcps(
    MultiMCPManager manager,
    WorkflowTask task, {
    Agent? executor,
  }) async {
    final registry = InternalMcpRegistry();
    final ds = DataSourcesSettingsService.instance;
    if (!ds.isLoaded) await ds.load();

    final internalMcps = executor?.internalMcps ?? task.internalMcps;
    // Toolbox — on by default, but can be disabled per-task
    final toolboxDisabled = internalMcps.any(
      (m) => m.mcpType == 'toolbox' && !m.enabled,
    );
    if (!toolboxDisabled) {
      try {
        final toolbox = registry.create('toolbox');
        if (toolbox != null) {
          await toolbox
              .initialize(const {'timezone': 'local'})
              .timeout(const Duration(seconds: 10));
          final adapter = InternalMcpClientAdapter(toolbox);
          await adapter.connect().timeout(const Duration(seconds: 5));
          manager.registerClient(
            MCPClientDef(
              name: 'internal_toolbox',
              client: adapter,
              displayName: toolbox.displayName,
            ),
          );
        }
      } catch (e) {
        log.warning('[TaskRunner] Toolbox MCP failed: $e');
      }
    }

    for (final entry in internalMcps) {
      if (!entry.enabled) continue;
      if (entry.mcpType == 'toolbox') continue;
      try {
        final server = registry.create(entry.mcpType);
        if (server == null) continue;

        final initParams = Map<String, dynamic>.from(entry.initParams);

        if (entry.mcpType == 'gmail' || entry.mcpType == 'google_calendar') {
          if (ds.isGmailAccessTokenExpired) {
            final refreshResult = await ds.refreshGmailAccessToken();
            if (refreshResult['success'] != true) {
              log.warning(
                '[TaskRunner] Google token pre-refresh failed: ${refreshResult['error']}',
              );
            }
          }
          final token = ds.gmailAccessToken.trim();
          if (token.isNotEmpty) initParams['accessToken'] = token;
          if (entry.mcpType == 'gmail') initParams['userId'] ??= 'me';
        }

        final initTimeout =
            (entry.mcpType == 'document' || entry.mcpType == 'website_search')
            ? const Duration(minutes: 10)
            : const Duration(seconds: 10);
        await server.initialize(initParams).timeout(initTimeout);
        final adapter = InternalMcpClientAdapter(server);
        await adapter.connect().timeout(const Duration(seconds: 5));
        manager.registerClient(
          MCPClientDef(
            name: 'internal_${entry.mcpType}',
            client: adapter,
            displayName: entry.label ?? server.displayName,
          ),
        );
      } catch (e) {
        log.warning('[TaskRunner] Internal MCP ${entry.mcpType} failed: $e');
      }
    }
  }

  // --- Attachment extraction -----------------------------------------------

  /// Scans tool-result messages for binary files (PDFs, images, etc.) and
  /// returns them as [EmailAttachmentPayload] objects ready for delivery.
  /// Zipping (if enabled) is handled at the [run] level after combining with
  /// log files so that a single archive contains everything.
  List<EmailAttachmentPayload> _extractEmailAttachments(
    List<ChatMessage> messages,
  ) {
    final attachments = <EmailAttachmentPayload>[];

    void tryAdd(String? fileName, String? mimeType, String? base64Data) {
      if (fileName == null || fileName.trim().isEmpty) return;
      if (mimeType == null || mimeType.trim().isEmpty) return;
      if (base64Data == null || base64Data.trim().isEmpty) return;
      try {
        final bytes = base64Decode(base64Data.trim());
        attachments.add(
          EmailAttachmentPayload(
            fileName: fileName.trim(),
            mimeType: mimeType.trim(),
            bytes: Uint8List.fromList(bytes),
          ),
        );
      } catch (_) {}
    }

    for (final message in messages.reversed) {
      final toolResult = message.toolResult;
      if (message.role != ChatRole.tool || toolResult == null) continue;

      // Track the pending fileName from metadata JSON items that precede binary data items.
      String? pendingFileName;

      for (final content in toolResult.content) {
        // JSON wrapper: { fileName, mimeType, encoding:"base64", content/data }
        // Also used as metadata (fileName + message) that precedes a binary MCPContent.data item.
        final text = content.text;
        if (text != null && text.trim().isNotEmpty) {
          try {
            final decoded = jsonDecode(text);
            if (decoded is Map<String, dynamic>) {
              // Pure metadata item preceding a binary content (from adapter binary path)
              if (decoded.containsKey('fileName') &&
                  !decoded.containsKey('encoding')) {
                pendingFileName = decoded['fileName']?.toString();
              }
              // Full payload with encoding: 'base64' -- save directly
              _tryAddFromJsonMap(decoded, tryAdd);
              if (decoded['data'] is Map<String, dynamic>) {
                _tryAddFromJsonMap(
                  decoded['data'] as Map<String, dynamic>,
                  tryAdd,
                );
              }
            }
          } catch (_) {}
          continue;
        }

        // Direct base64 binary (MCPContent.data field)
        if (content.data != null && content.data!.isNotEmpty) {
          final mime = content.mimeType ?? 'application/octet-stream';
          final ext = _extensionForMime(mime);
          // Use tracked fileName from preceding metadata item, or generate a timestamped name.
          final fname = (pendingFileName != null && pendingFileName.isNotEmpty)
              ? pendingFileName
              : 'output_${DateTime.now().millisecondsSinceEpoch}.$ext';
          tryAdd(fname, mime, content.data);
          pendingFileName = null; // consumed
        }
      }

      // Stop after the first tool message that yielded binary output
      if (attachments.isNotEmpty) break;
    }

    if (attachments.isEmpty) return const [];

    return attachments;
  }

  void _tryAddFromJsonMap(
    Map<String, dynamic> m,
    void Function(String?, String?, String?) tryAdd,
  ) {
    if (m['fileName'] != null &&
        m['mimeType'] != null &&
        m['encoding'] == 'base64') {
      // Accept both 'content' (legacy) and 'data' (used by Excel/File MCP servers)
      final payload = m['content'] ?? m['data'];
      if (payload != null) {
        tryAdd(
          m['fileName'].toString(),
          m['mimeType'].toString(),
          payload.toString(),
        );
      }
    }
  }

  String _extensionForMime(String mime) {
    final lower = mime.toLowerCase();
    if (lower.contains('pdf')) return 'pdf';
    if (lower.contains('png')) return 'png';
    if (lower.contains('jpeg') || lower.contains('jpg')) return 'jpg';
    if (lower.contains('gif')) return 'gif';
    if (lower.contains('svg')) return 'svg';
    if (lower.contains('html')) return 'html';
    if (lower.contains('csv')) return 'csv';
    if (lower.contains('json')) return 'json';
    if (lower.contains('zip')) return 'zip';
    if (lower.contains('excel') || lower.contains('spreadsheet')) return 'xlsx';
    return 'bin';
  }

  /// Saves [attachments] to the user-configured [folderPath].
  /// Creates a timestamped sub-folder per run (same convention as TaskOutputFileService).
  Future<List<String>> _saveToDiskOutputFolder({
    required List<EmailAttachmentPayload> attachments,
    required WorkflowTask task,
    required String folderPath,
  }) async {
    if (attachments.isEmpty) return const [];
    final dir = Directory(folderPath);
    if (!await dir.exists()) await dir.create(recursive: true);

    final now = DateTime.now();
    final stamp =
        '${now.year.toString().padLeft(4, '0')}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}'
        '_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
    final slug = task.name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final runDir = Directory(
      '${dir.path}${Platform.pathSeparator}${slug}_$stamp',
    );
    await runDir.create(recursive: true);

    final savedPaths = <String>[];
    for (final att in attachments) {
      final file = File(
        '${runDir.path}${Platform.pathSeparator}${att.fileName}',
      );
      await file.writeAsBytes(att.bytes);
      savedPaths.add(file.path);
      log.info(
        '[TaskRunner] Disk output folder: saved "${att.fileName}" -> ${file.path}',
      );
    }
    return savedPaths;
  }

  Future<void> uploadToSftp({
    required WorkflowTask task,
    required SftpOutputConfig sftpCfg,
    required List<EmailAttachmentPayload> attachments,
  }) async {
    final ds = DataSourcesSettingsService.instance;
    if (!ds.isLoaded) await ds.load();

    final host = sftpCfg.useConfiguredSshServer ? ds.sshHost : sftpCfg.host;
    final port = sftpCfg.useConfiguredSshServer ? ds.sshPort : sftpCfg.port;
    final username = sftpCfg.useConfiguredSshServer
        ? ds.sshUsername
        : sftpCfg.username;
    final password = sftpCfg.useConfiguredSshServer
        ? ds.sshPassword
        : (sftpCfg.password ?? '');
    final privateKey = sftpCfg.useConfiguredSshServer
        ? ds.sshPrivateKey
        : (sftpCfg.privateKey ?? '');

    if (host.isEmpty) throw StateError('SFTP host is not configured.');

    final client = SSHClient(
      await SSHSocket.connect(host, port),
      username: username,
      identities: privateKey.isNotEmpty ? SSHKeyPair.fromPem(privateKey) : null,
      onPasswordRequest: () => password,
    );
    await client.authenticated;
    log.info('[TaskRunner] SFTP connected to $host:$port as $username');

    try {
      final sftp = await client.sftp();
      final remotePath = sftpCfg.remotePath.trim().isNotEmpty
          ? sftpCfg.remotePath.trim()
          : '/';

      final now = DateTime.now();
      final stamp =
          '${now.year.toString().padLeft(4, '0')}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}'
          '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';
      final taskSlug = task.name
          .toLowerCase()
          .replaceAll('ä', 'a')
          .replaceAll('ö', 'o')
          .replaceAll('ü', 'u')
          .replaceAll('ß', 'ss')
          .replaceAll('à', 'a')
          .replaceAll('á', 'a')
          .replaceAll('â', 'a')
          .replaceAll('è', 'e')
          .replaceAll('é', 'e')
          .replaceAll('ê', 'e')
          .replaceAll('ì', 'i')
          .replaceAll('í', 'i')
          .replaceAll('î', 'i')
          .replaceAll('ò', 'o')
          .replaceAll('ó', 'o')
          .replaceAll('ô', 'o')
          .replaceAll('ù', 'u')
          .replaceAll('ú', 'u')
          .replaceAll('û', 'u')
          .replaceAll(' ', '_')
          .replaceAll(RegExp(r'[^a-z0-9_\-]'), '')
          .replaceAll(RegExp(r'_+'), '_')
          .replaceAll(RegExp(r'^_|_$'), '');
      final remoteDir =
          '$remotePath/${taskSlug.isNotEmpty ? taskSlug : 'task'}/$stamp';

      // Create remote directory tree
      await _sftpMkdirRecursive(sftp, remoteDir);

      final uploadedNames = <String>[];
      for (final att in attachments) {
        final remoteFile = '$remoteDir/${att.fileName}';
        final sftpFile = await sftp.open(
          remoteFile,
          mode:
              SftpFileOpenMode.create |
              SftpFileOpenMode.write |
              SftpFileOpenMode.truncate,
        );
        await sftpFile.writeBytes(att.bytes);
        await sftpFile.close();
        uploadedNames.add(att.fileName);
        log.info('[TaskRunner] SFTP uploaded "${att.fileName}" -> $remoteFile');
      }

      sftp.close();
      log.info(
        '[TaskRunner] SFTP upload complete: ${uploadedNames.length} file(s) to $remoteDir',
      );

      await SchedulerLogService().addEntry(
        taskId: task.id,
        taskName: task.name,
        event: SchedulerEventType.completed,
        detail:
            'sftp-uploaded: ${uploadedNames.length} file(s) to $host:$remoteDir',
      );

      // Send notification email if requested
      if (sftpCfg.notifyByEmail && sftpCfg.notifyEmailAddress.isNotEmpty) {
        final subject = sftpCfg.notifyEmailSubject.isNotEmpty
            ? sftpCfg.notifyEmailSubject
            : '${task.name}: SFTP upload complete';
        final body = sftpCfg.notifyEmailBody.isNotEmpty
            ? sftpCfg.notifyEmailBody
            : '${uploadedNames.length} file(s) uploaded to $host:$remoteDir\n\nFiles: ${uploadedNames.join(', ')}';
        final via = ds.smtpHost.trim().isNotEmpty ? 'imap' : 'gmail';
        try {
          await EmailDeliveryService().sendTestEmail(
            recipient: sftpCfg.notifyEmailAddress,
            subject: subject,
            body: body,
            via: via,
          );
          log.info(
            '[TaskRunner] SFTP notification email sent to ${sftpCfg.notifyEmailAddress}',
          );
        } catch (e) {
          log.warning('[TaskRunner] SFTP notification email failed: $e');
        }
      }
    } finally {
      client.close();
    }
  }

  Future<List<String>> _deliverCombinedOutput({
    required WorkflowTask task,
    required TaskNotification notification,
    required TaskRunResult result,
    required List<Map<String, dynamic>> executedSteps,
    required DateTime startTime,
    required LLMService llmService,
  }) async {
    final binaryAttachments = <EmailAttachmentPayload>[];
    for (final step in executedSteps) {
      final msgs = step['messages'] as List<ChatMessage>;
      binaryAttachments.addAll(_extractEmailAttachments(msgs));
    }

    final combinedExecLog = _buildCombinedExecutionLog(task, executedSteps);
    final combinedOutputLog = _buildCombinedOutputLog(task, executedSteps);

    // Check if any step had HTML output
    final htmlAttachments = <EmailAttachmentPayload>[];
    for (final step in executedSteps) {
      final exec = step['executor'] as Agent;
      final assistantText = step['assistantText'] as String;
      final htmlContent = _extractHtmlFromOutput(assistantText);
      if (htmlContent != null) {
        final cleanExecName = exec.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
        final htmlFileName = '${cleanExecName}_output.html';
        htmlAttachments.add(
          EmailAttachmentPayload(
            fileName: htmlFileName,
            mimeType: 'text/html',
            bytes: Uint8List.fromList(utf8.encode(htmlContent)),
          ),
        );
      }
    }

    final emailAttachmentsRaw = <EmailAttachmentPayload>[];
    if (notification.addExecutionLog && combinedExecLog.isNotEmpty) {
      emailAttachmentsRaw.add(
        EmailAttachmentPayload(
          fileName: 'execution_log.md',
          mimeType: 'text/markdown',
          bytes: Uint8List.fromList(utf8.encode(combinedExecLog)),
        ),
      );
    }
    emailAttachmentsRaw.addAll(htmlAttachments);
    emailAttachmentsRaw.addAll(binaryAttachments);

    final diskSftpAttachmentsRaw = <EmailAttachmentPayload>[];
    if (notification.addExecutionLog && combinedExecLog.isNotEmpty) {
      diskSftpAttachmentsRaw.add(
        EmailAttachmentPayload(
          fileName: 'execution_log.md',
          mimeType: 'text/markdown',
          bytes: Uint8List.fromList(utf8.encode(combinedExecLog)),
        ),
      );
    }
    if (combinedOutputLog.isNotEmpty) {
      diskSftpAttachmentsRaw.add(
        EmailAttachmentPayload(
          fileName: 'output.md',
          mimeType: 'text/markdown',
          bytes: Uint8List.fromList(utf8.encode(combinedOutputLog)),
        ),
      );
    }
    diskSftpAttachmentsRaw.addAll(htmlAttachments);
    diskSftpAttachmentsRaw.addAll(binaryAttachments);

    List<EmailAttachmentPayload> emailAttachments;
    if (notification.zipOutputFiles && emailAttachmentsRaw.isNotEmpty) {
      try {
        final archive = Archive();
        for (final a in emailAttachmentsRaw) {
          archive.addFile(ArchiveFile(a.fileName, a.bytes.length, a.bytes));
        }
        final zipBytes = ZipEncoder().encode(archive);
        emailAttachments = [
          EmailAttachmentPayload(
            fileName: 'task_output_${DateTime.now().millisecondsSinceEpoch}.zip',
            mimeType: 'application/zip',
            bytes: Uint8List.fromList(zipBytes),
          ),
        ];
      } catch (e) {
        log.warning('[TaskRunner] Zip compression failed for email: $e');
        emailAttachments = emailAttachmentsRaw;
      }
    } else {
      emailAttachments = emailAttachmentsRaw;
    }

    List<EmailAttachmentPayload> diskSftpAttachments;
    if (notification.zipOutputFiles && diskSftpAttachmentsRaw.isNotEmpty) {
      try {
        final archive = Archive();
        for (final a in diskSftpAttachmentsRaw) {
          archive.addFile(ArchiveFile(a.fileName, a.bytes.length, a.bytes));
        }
        final zipBytes = ZipEncoder().encode(archive);
        diskSftpAttachments = [
          EmailAttachmentPayload(
            fileName: 'task_output_${DateTime.now().millisecondsSinceEpoch}.zip',
            mimeType: 'application/zip',
            bytes: Uint8List.fromList(zipBytes),
          ),
        ];
      } catch (e) {
        log.warning('[TaskRunner] Zip compression failed for disk/sftp: $e');
        diskSftpAttachments = diskSftpAttachmentsRaw;
      }
    } else {
      diskSftpAttachments = diskSftpAttachmentsRaw;
    }

    final savedPaths = <String>[];

    // File/Disk Output
    if (notification.download != null) {
      try {
        final dl = notification.download!;
        final paths = await _saveToDiskOutputFolder(
          task: task,
          folderPath: dl.downloadPath ?? '',
          attachments: diskSftpAttachments,
        );
        savedPaths.addAll(paths);
      } catch (e) {
        log.warning('[TaskRunner] File output failed: $e');
      }
    }

    // SFTP Output
    if (notification.sftpOutput != null) {
      try {
        await uploadToSftp(
          task: task,
          sftpCfg: notification.sftpOutput!,
          attachments: diskSftpAttachments,
        );
      } catch (e) {
        log.warning('[TaskRunner] SFTP upload failed: $e');
      }
    }

    // Dummy executor for global notification delivery
    final globalDummyExecutor = Agent(
      id: 'global',
      name: task.name,
      prompt: task.prompt,
      notification: notification,
    );

    // Email Delivery
    try {
      if (notification.email != null) {
        final emailOutcome = await EmailDeliveryService().sendExecutorResult(
          task: task,
          executor: globalDummyExecutor,
          taskSuccess: result.success,
          resultText: result.success ? combinedOutputLog : result.resultText,
          errorText: result.success ? null : result.error,
          attachments: emailAttachments,
        );
        final emailDetail = emailOutcome.attempted
            ? (emailOutcome.sent
                  ? 'email-sent'
                  : 'email-failed: ${emailOutcome.message ?? "unknown"}')
            : 'email-skipped: ${emailOutcome.message ?? "no config"}';
        await SchedulerLogService().addEntry(
          taskId: task.id,
          taskName: task.name,
          event: emailOutcome.sent
              ? SchedulerEventType.completed
              : SchedulerEventType.skipped,
          detail: emailDetail,
        );
      }
    } catch (e) {
      log.warning('[TaskRunner] Email delivery failed: $e');
    }

    // Slack Delivery
    try {
      if (notification.slack != null) {
        final slackOutcome = await MessagingDeliveryService()
            .sendSlackExecutorResult(
              task: task,
              executor: globalDummyExecutor,
              taskSuccess: result.success,
              resultText: result.success ? combinedOutputLog : result.resultText,
              errorText: result.success ? null : result.error,
              attachments: emailAttachments,
            );
        final slackDetail = slackOutcome.attempted
            ? (slackOutcome.sent
                  ? 'slack-sent'
                  : 'slack-failed: ${slackOutcome.message ?? "unknown"}')
            : 'slack-skipped';
        await SchedulerLogService().addEntry(
          taskId: task.id,
          taskName: task.name,
          event: slackOutcome.sent
              ? SchedulerEventType.completed
              : SchedulerEventType.skipped,
          detail: slackDetail,
        );
      }
    } catch (e) {
      log.warning('[TaskRunner] Slack delivery failed: $e');
    }

    // WhatsApp Delivery
    try {
      if (notification.whatsApp != null) {
        final waOutcome = await MessagingDeliveryService()
            .sendWhatsAppExecutorResult(
              task: task,
              executor: globalDummyExecutor,
              taskSuccess: result.success,
              resultText: result.success ? combinedOutputLog : result.resultText,
              errorText: result.success ? null : result.error,
              attachments: emailAttachments,
            );
        final waDetail = waOutcome.attempted
            ? (waOutcome.sent
                  ? 'whatsapp-sent'
                  : 'whatsapp-failed: ${waOutcome.message ?? "unknown"}')
            : 'whatsapp-skipped';
        await SchedulerLogService().addEntry(
          taskId: task.id,
          taskName: task.name,
          event: waOutcome.sent
              ? SchedulerEventType.completed
              : SchedulerEventType.skipped,
          detail: waDetail,
        );
      }
    } catch (e) {
      log.warning('[TaskRunner] WhatsApp delivery failed: $e');
    }

    // Push Notification
    try {
      if (notification.push != null) {
        final push = notification.push!;
        final shouldSend = _shouldSendPush(push.condition, result.success);
        if (shouldSend) {
          final title = push.title?.trim().isNotEmpty == true
              ? push.title!.trim()
              : 'Task [${task.name}] completed';
          final bodyText = result.success ? combinedOutputLog : (result.error ?? 'Task failed');
          final body = bodyText.length > 240 ? '${bodyText.substring(0, 240)}…' : bodyText;
          await NotificationService.instance.showTaskResult(
            taskName: title,
            success: result.success,
            body: body,
            id: task.id.hashCode,
          );
          await SchedulerLogService().addEntry(
            taskId: task.id,
            taskName: task.name,
            event: result.success
                ? SchedulerEventType.completed
                : SchedulerEventType.failed,
            detail: 'push-sent',
          );
        } else {
          await SchedulerLogService().addEntry(
            taskId: task.id,
            taskName: task.name,
            event: SchedulerEventType.skipped,
            detail: 'push-skipped: condition not met',
          );
        }
      }
    } catch (e) {
      log.warning('[TaskRunner] Push delivery failed: $e');
    }

    return savedPaths;
  }

  String _buildCombinedExecutionLog(WorkflowTask task, List<Map<String, dynamic>> executedSteps) {
    final buf = StringBuffer();
    buf.writeln('# Combined Task Execution Log: ${task.name}');
    buf.writeln();
    for (final step in executedSteps) {
      final exec = step['executor'] as Agent;
      final msgs = step['messages'] as List<ChatMessage>;
      final startTime = step['startTime'] as DateTime;
      final provider = step['provider'] as String;
      final model = step['model'] as String;

      final ts = '${startTime.year}-${_pad(startTime.month)}-${_pad(startTime.day)} '
                 '${_pad(startTime.hour)}:${_pad(startTime.minute)}:${_pad(startTime.second)}';

      buf.writeln('================================================================');
      buf.writeln('## Agent: ${exec.name}');
      buf.writeln('================================================================');
      buf.writeln('**Timestamp:** $ts');
      buf.writeln('**Provider:** $provider | **Model:** $model');
      buf.writeln();
      buf.writeln('### Prompt');
      buf.writeln('```');
      buf.writeln(exec.prompt.trim());
      buf.writeln('```');
      buf.writeln();
      buf.writeln('### LLM Interactions');

      String? pendingToolName;
      for (final msg in msgs) {
        switch (msg.role) {
          case ChatRole.assistant:
            final content = msg.content.trim();
            if (content.isEmpty) break;
            if (msg.availableTools != null || content.toLowerCase().contains('calling tools')) {
              buf.writeln();
              buf.writeln('**Initial LLM Response:**');
              if (content.isNotEmpty && content != 'Calling tools to retrieve the requested information...') {
                buf.writeln();
                buf.writeln(content);
              }
              if (msg.lastCalledToolName != null) {
                pendingToolName = msg.lastCalledToolName;
                buf.writeln('Function Calls:');
                buf.writeln('- `${msg.lastCalledToolName}`');
              }
            } else {
              buf.writeln();
              buf.writeln('**Final Response:**');
              buf.writeln();
              buf.writeln(content);
            }
          case ChatRole.tool:
            buf.writeln();
            final toolName = msg.lastCalledToolName ?? pendingToolName ?? 'tool';
            buf.writeln('**Tool Response (`$toolName`):**');
            buf.writeln();
            String toolText = msg.content.trim();
            if (toolText.isEmpty && msg.toolResult != null) {
              toolText = msg.toolResult!.content
                  .where((c) => c.text != null && c.text!.isNotEmpty)
                  .map((c) => c.text!.trim())
                  .join('\n');
            }
            if (toolText.length > 128) {
              toolText = '${toolText.substring(0, 128)}...';
            }
            buf.writeln('```');
            buf.writeln(toolText);
            buf.writeln('```');
            buf.writeln();
          case ChatRole.user:
            final content = msg.content.trim();
            if (content.isNotEmpty) {
              buf.writeln();
              buf.writeln('**User/System Message:**');
              buf.writeln(content);
              buf.writeln();
            }
          case ChatRole.system:
            break;
        }
      }
      buf.writeln();
    }
    return buf.toString();
  }

  String _buildCombinedOutputLog(WorkflowTask task, List<Map<String, dynamic>> executedSteps) {
    final buf = StringBuffer();
    buf.writeln('# Combined Task Output: ${task.name}');
    buf.writeln();
    for (final step in executedSteps) {
      final exec = step['executor'] as Agent;
      final assistantText = step['assistantText'] as String;
      buf.writeln('================================================================');
      buf.writeln('## Agent: ${exec.name}');
      buf.writeln('================================================================');
      buf.writeln();
      buf.writeln(assistantText.trim());
      buf.writeln();
    }
    return buf.toString();
  }

  Future<List<String>> _deliverExecutorOutput({
    required WorkflowTask task,
    required Agent executor,
    required TaskRunResult result,
    required List<ChatMessage> capturedMessages,
    required DateTime startTime,
    required LLMService llmService,
  }) async {
    final binaryAttachments = _extractEmailAttachments(capturedMessages);
    final String rawOutput = _buildRawOutput(
      task: task.copyWith(prompt: executor.prompt),
      messages: capturedMessages,
      startTime: startTime,
      llmService: llmService,
    );
    final prefix = (executor.id == 'global' || executor.id == 'default')
        ? ''
        : '${executor.id.length > 8 ? executor.id.substring(0, 8) : executor.id}_';

    final logPayloads = <EmailAttachmentPayload>[];
    if (rawOutput.isNotEmpty) {
      logPayloads.add(
        EmailAttachmentPayload(
          fileName: '${prefix}execution_log.md',
          mimeType: 'text/markdown',
          bytes: Uint8List.fromList(utf8.encode(rawOutput)),
        ),
      );
    }
    final userOutput = result.success && result.resultText.isNotEmpty
        ? result.resultText
        : (result.error ?? '');
    final prettyUserOutput = _prettyPrintIfJson(userOutput);
    if (userOutput.isNotEmpty) {
      final htmlContent = _extractHtmlFromOutput(userOutput);
      if (htmlContent != null) {
        final htmlFileName = _extractHtmlFileName(userOutput) ?? 'output.html';
        logPayloads.add(
          EmailAttachmentPayload(
            fileName: '$prefix$htmlFileName',
            mimeType: 'text/html',
            bytes: Uint8List.fromList(utf8.encode(htmlContent)),
          ),
        );
      } else {
        logPayloads.add(
          EmailAttachmentPayload(
            fileName: '${prefix}output.md',
            mimeType: 'text/markdown',
            bytes: Uint8List.fromList(utf8.encode(prettyUserOutput)),
          ),
        );
      }
    }

    final allSaveAttachments = [...logPayloads, ...binaryAttachments];
    List<EmailAttachmentPayload> emailAttachments;
    if (executor.notification.zipOutputFiles &&
        (logPayloads.isNotEmpty || binaryAttachments.isNotEmpty)) {
      try {
        final allForZip = [...logPayloads, ...binaryAttachments];
        final archive = Archive();
        for (final a in allForZip) {
          archive.addFile(ArchiveFile(a.fileName, a.bytes.length, a.bytes));
        }
        final zipBytes = ZipEncoder().encode(archive);
        emailAttachments = [
          EmailAttachmentPayload(
            fileName: 'output_${DateTime.now().millisecondsSinceEpoch}.zip',
            mimeType: 'application/zip',
            bytes: Uint8List.fromList(zipBytes),
          ),
        ];
      } catch (e) {
        log.warning('[TaskRunner] Zip compression failed: $e');
        emailAttachments = allSaveAttachments;
      }
    } else {
      emailAttachments = allSaveAttachments;
    }

    final savedPaths = <String>[];

    // File/Disk Output
    if (executor.notification.download != null) {
      try {
        final dl = executor.notification.download!;
        final paths = await _saveToDiskOutputFolder(
          task: task,
          folderPath: dl.downloadPath ?? '',
          attachments: allSaveAttachments,
        );
        savedPaths.addAll(paths);
      } catch (e) {
        log.warning('[TaskRunner] File output failed: $e');
      }
    }

    // SFTP Output
    if (executor.notification.sftpOutput != null) {
      try {
        await uploadToSftp(
          task: task,
          sftpCfg: executor.notification.sftpOutput!,
          attachments: allSaveAttachments,
        );
      } catch (e) {
        log.warning('[TaskRunner] SFTP upload failed: $e');
      }
    }

    // Email Delivery
    try {
      if (executor.notification.email != null) {
        final emailOutcome = await EmailDeliveryService().sendExecutorResult(
          task: task,
          executor: executor,
          taskSuccess: result.success,
          resultText: result.success ? prettyUserOutput : result.resultText,
          errorText: result.success ? null : result.error,
          attachments: emailAttachments,
        );
        final emailDetail = emailOutcome.attempted
            ? (emailOutcome.sent
                  ? 'email-sent'
                  : 'email-failed: ${emailOutcome.message ?? "unknown"}')
            : 'email-skipped: ${emailOutcome.message ?? "no config"}';
        await SchedulerLogService().addEntry(
          taskId: task.id,
          taskName: task.name,
          event: emailOutcome.sent
              ? SchedulerEventType.completed
              : SchedulerEventType.skipped,
          detail: emailDetail,
        );
      }
    } catch (e) {
      log.warning('[TaskRunner] Email delivery failed: $e');
    }

    // Slack Delivery
    try {
      if (executor.notification.slack != null) {
        final slackOutcome = await MessagingDeliveryService()
            .sendSlackExecutorResult(
              task: task,
              executor: executor,
              taskSuccess: result.success,
              resultText: result.success ? prettyUserOutput : result.resultText,
              errorText: result.success ? null : result.error,
              attachments: emailAttachments,
            );
        final slackDetail = slackOutcome.attempted
            ? (slackOutcome.sent
                  ? 'slack-sent'
                  : 'slack-failed: ${slackOutcome.message ?? "unknown"}')
            : 'slack-skipped: ${slackOutcome.message ?? "no config"}';
        await SchedulerLogService().addEntry(
          taskId: task.id,
          taskName: task.name,
          event: slackOutcome.sent
              ? SchedulerEventType.completed
              : SchedulerEventType.skipped,
          detail: slackDetail,
        );
      }
    } catch (e) {
      log.warning('[TaskRunner] Slack delivery failed: $e');
    }

    // WhatsApp Delivery
    try {
      if (executor.notification.whatsApp != null) {
        final waOutcome = await MessagingDeliveryService()
            .sendWhatsAppExecutorResult(
              task: task,
              executor: executor,
              taskSuccess: result.success,
              resultText: result.success ? prettyUserOutput : result.resultText,
              errorText: result.success ? null : result.error,
              attachments: emailAttachments,
            );
        final waDetail = waOutcome.attempted
            ? (waOutcome.sent
                  ? 'whatsapp-sent'
                  : 'whatsapp-failed: ${waOutcome.message ?? "unknown"}')
            : 'whatsapp-skipped: ${waOutcome.message ?? "no config"}';
        await SchedulerLogService().addEntry(
          taskId: task.id,
          taskName: task.name,
          event: waOutcome.sent
              ? SchedulerEventType.completed
              : SchedulerEventType.skipped,
          detail: waDetail,
        );
      }
    } catch (e) {
      log.warning('[TaskRunner] WhatsApp delivery failed: $e');
    }

    // Push Delivery
    try {
      if (executor.notification.push != null) {
        final push = executor.notification.push!;
        final shouldSend = _shouldSendPush(push.condition, result.success);
        if (shouldSend) {
          final title = push.title?.trim().isNotEmpty == true
              ? push.title!.trim()
              : 'Agent [${executor.name}] completed';
          final body = result.success
              ? (prettyUserOutput.length > 240 ? '${prettyUserOutput.substring(0, 240)}…' : prettyUserOutput)
              : (result.error ?? 'Step failed');
          await NotificationService.instance.showTaskResult(
            taskName: title,
            success: result.success,
            body: body,
            id: executor.id.hashCode,
          );
        }
      }
    } catch (e) {
      log.warning('[TaskRunner] Push notification delivery failed: $e');
    }

    return savedPaths;
  }

  bool _shouldSendPush(String condition, bool success) {
    final norm = condition.trim().toLowerCase();
    if (norm == 'always') return true;
    if (norm == 'on_success') return success;
    if (norm == 'on_failure' || norm == 'on_error') return !success;
    return false;
  }

  Future<void> _sftpMkdirRecursive(SftpClient sftp, String path) async {
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    var current = '';
    for (final part in parts) {
      current += '/$part';
      try {
        await sftp.mkdir(current);
      } catch (_) {
        // Directory may already exist — ignore errors
      }
    }
  }
}

// --- Bootstrap helper (call in each isolate before running tasks) -----------

/// Bootstrap all services needed for headless task execution.
/// Call this in `main()` and in WorkManager's `callbackDispatcher`.
Future<void> bootstrapTaskRunnerServices() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Mark this isolate as a background boot so embedded model tasks are skipped
  // (prevents LlamaBackend double-init crash and OOM kills).
  _isBackgroundRunnerContext = true;

  try {
    await DuckDbService().init();
  } catch (e) {
    log.error('[Bootstrap] DuckDB init failed: $e');
  }

  // Load the cached Pro status from SharedPreferences so that Pro-gated tool
  // calls (e.g. SFTP upload_file) are not spuriously blocked by the entitlement
  // check.  RevenueCat itself is not initialised in background isolates to avoid
  // MethodChannel / Platform-plugin instability.
  try {
    await CredentialCipher.instance.init();
  } catch (e) {
    log.error('[Bootstrap] CredentialCipher init failed: $e');
  }

  try {
    await AppPreferencesService.instance.load();
  } catch (e) {
    log.error('[Bootstrap] App preferences load failed: $e');
  }

  try {
    await LlmSettingsService.instance.load();
  } catch (e) {
    log.error('[Bootstrap] LLM settings load failed: $e');
  }

  try {
    await ExternalToolsSettingsService.instance.load();
  } catch (e) {
    log.error('[Bootstrap] External tools settings load failed: $e');
  }

  try {
    await DataSourcesSettingsService.instance.load();
  } catch (e) {
    log.error('[Bootstrap] Data sources settings load failed: $e');
  }

  // Load the script library so background SSH/SFTP tasks can resolve scripts.
  try {
    await ScriptLibraryService.instance.load();
  } catch (e) {
    log.error('[Bootstrap] Script library load failed: $e');
  }

  try {
    await NotificationService.instance.init();
  } catch (e) {
    log.error('[Bootstrap] Notification service init failed: $e');
  }

  // On Android, the network radio may not be immediately ready after the alarm
  // wakes the device from sleep (especially on Samsung with battery optimization).
  // Wait up to 15 seconds for network connectivity before proceeding.
  await _waitForNetwork();

  // Pre-warm DNS for common email/delivery hosts so SMTP and Gmail API calls
  // don't fail with errno=7 (no address) immediately after wake-from-sleep.
  final ds = DataSourcesSettingsService.instance;
  final emailHosts = <String>[
    'smtp.gmail.com',
    'gmail.googleapis.com',
    if (ds.smtpHost.trim().isNotEmpty) ds.smtpHost.trim(),
  ];
  for (final host in emailHosts) {
    InternetAddress.lookup(host).catchError((_) => <InternetAddress>[]);
  }

  // Pre-warm DNS for the configured LLM API host (e.g. api.mistral.ai).
  // This runs fire-and-forget in parallel with email pre-warm so that by the
  // time TaskRunnerService.run() calls _warmDns() the resolver has already
  // cached the entry and the await there returns immediately.
  try {
    final llmService = LLMService();
    final llmHost = _getLlmHostname(llmService);
    if (llmHost != null && llmHost.isNotEmpty) {
      InternetAddress.lookup(llmHost).catchError((_) => <InternetAddress>[]);
    }
  } catch (_) {}
}

/// Waits until internet is reachable.
///
/// Two-stage check to handle the Android wake-from-sleep race:
///   Stage 1 — TCP connect to 1.1.1.1:443 by raw IP (no DNS required).
///              This confirms the network radio / WiFi is up.
///   Stage 2 — DNS lookup to confirm the resolver is also ready.
///              (DNS can lag a few extra seconds behind TCP.)
///
/// Retries up to [maxAttempts] times with [delaySeconds] between tries.
/// Returns silently if network never comes up -- the task will fail with its
/// own network error, which is logged as normal.
Future<void> _waitForNetwork({
  int maxAttempts = 10,
  int delaySeconds = 4,
}) async {
  for (var i = 0; i < maxAttempts; i++) {
    try {
      // Stage 1: raw TCP — does not need DNS, tests the network radio only.
      final socket = await Socket.connect(
        '1.1.1.1',
        443,
        timeout: const Duration(seconds: 3),
      );
      await socket.close();

      // Stage 2: DNS lookup — confirms the resolver is functional.
      final result = await InternetAddress.lookup(
        'cloudflare.com',
      ).timeout(const Duration(seconds: 4));
      if (result.isNotEmpty && result.first.rawAddress.isNotEmpty) {
        if (i > 0) {
          log.info(
            '[Bootstrap] Network ready after ${i * delaySeconds}s wait.',
          );
        }
        return;
      }
    } catch (_) {
      // not reachable yet
    }
    if (i < maxAttempts - 1) {
      log.info(
        '[Bootstrap] Network not ready, waiting ${delaySeconds}s (attempt ${i + 1}/$maxAttempts)…',
      );
      await Future.delayed(Duration(seconds: delaySeconds));
    }
  }
  log.warning(
    '[Bootstrap] Network not reachable after ${maxAttempts * delaySeconds}s -- proceeding anyway.',
  );
}

/// Extracts the DNS hostname from the configured LLM provider so it can be
/// pre-warmed before the first real API call.
String? _getLlmHostname(LLMService llmService) {
  try {
    // OpenAI-compatible covers Mistral, DeepInfra, local Ollama-compat routers, etc.
    final compatUrl = llmService.savedOpenAICompatibleUrl;
    if (compatUrl != null && compatUrl.isNotEmpty) {
      final host = Uri.tryParse(compatUrl)?.host ?? '';
      // Skip localhost / raw IP addresses — DNS pre-warm is pointless for those.
      if (host.isNotEmpty && !_isLocalhostOrIp(host)) return host;
    }
    // For native SDK providers, return their known API hostnames.
    switch (llmService.currentProvider) {
      case LLMProvider.openai:
        return 'api.openai.com';
      case LLMProvider.gemini:
        return 'generativelanguage.googleapis.com';
      case LLMProvider.claude:
        return 'api.anthropic.com';
      default:
        return null;
    }
  } catch (_) {
    return null;
  }
}

bool _isLocalhostOrIp(String host) =>
    host == 'localhost' ||
    host.startsWith('127.') ||
    host.startsWith('192.168.') ||
    host.startsWith('10.') ||
    RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(host);

/// Waits until [host] resolves via DNS, up to ~24 s (8 × 3 s).
/// Returns silently once resolved, or after the budget is exhausted.
Future<void> _warmDns(String host) async {
  const maxAttempts = 8;
  const delaySeconds = 3;
  for (var i = 0; i < maxAttempts; i++) {
    try {
      final result = await InternetAddress.lookup(
        host,
      ).timeout(const Duration(seconds: 3));
      if (result.isNotEmpty && result.first.rawAddress.isNotEmpty) {
        if (i > 0) {
          log.info(
            '[TaskRunner] DNS for $host ready after ${i * delaySeconds}s.',
          );
        }
        return;
      }
    } catch (_) {}
    if (i < maxAttempts - 1) {
      log.info(
        '[TaskRunner] DNS for $host not ready yet, waiting ${delaySeconds}s (attempt ${i + 1}/$maxAttempts)…',
      );
      await Future.delayed(const Duration(seconds: delaySeconds));
    }
  }
  log.warning(
    '[TaskRunner] DNS for $host not resolved after ${maxAttempts * delaySeconds}s — proceeding anyway.',
  );
}

Future<bool> evaluateCondition({
  required LLMService llmService,
  required LocationService locationService,
  required MultiMCPManager mcpManager,
  required String source,
  required String operator,
  required String value,
}) async {
  final src = source.trim();
  final val = value.trim();

  if (operator == 'always' || operator == 'sequential') {
    return true;
  }

  if (operator == 'llm_eval' || operator == 'evaluated_by_llm') {
    try {
      final evalChatService = ChatService(
        mcpClient: mcpManager,
        llmService: llmService,
        locationService: locationService,
        chatMode: true,
      );
      final evaluationPrompt =
          'Analyze the following Task Result and check if the given Condition is met.\n'
          'Provide a brief one-line reasoning (perform any math/checks step-by-step), and then conclude with exactly "RESULT: TRUE" or "RESULT: FALSE".\n\n'
          'Condition: $val\n\n'
          'Task Result:\n$src\n\n'
          'Format:\n'
          'Reasoning: <brief reasoning>\n'
          'RESULT: <TRUE or FALSE>';

      await evalChatService
          .sendMessage(evaluationPrompt)
          .timeout(
            const Duration(minutes: 2),
            onTimeout: () =>
                throw TimeoutException('LLM Condition evaluation timed out.'),
          );

      final messages = evalChatService.messages;
      ChatMessage? lastAssistant;
      for (final m in messages.reversed) {
        if (m.role == ChatRole.assistant) {
          final content = m.content.trim();
          if (content.isNotEmpty) {
            lastAssistant = m;
            break;
          }
        }
      }
      final responseText = lastAssistant?.content.trim() ?? '';

      // 1. Look for explicit RESULT: TRUE/FALSE (from CoT prompt format)
      final explicitMatch = RegExp(
        r'RESULT:\s*(TRUE|FALSE)',
        caseSensitive: false,
      ).firstMatch(responseText);

      if (explicitMatch != null) {
        return explicitMatch.group(1)!.toUpperCase() == 'TRUE';
      }

      // 2. Look for JSON output if model outputted JSON
      if (responseText.contains('"result"')) {
        final jsonMatch = RegExp(
          r'"result"\s*:\s*(true|false)',
          caseSensitive: false,
        ).firstMatch(responseText);
        if (jsonMatch != null) {
          return jsonMatch.group(1)!.toLowerCase() == 'true';
        }
      }

      // 3. Fallback: check the last non-empty line
      final lines = responseText
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .toList();
      if (lines.isNotEmpty) {
        final lastLine = lines.last.toLowerCase();
        if (lastLine.contains('true') && !lastLine.contains('false')) {
          return true;
        }
        if (lastLine.contains('false') && !lastLine.contains('true')) {
          return false;
        }
      }

      // 4. Default legacy fallback: match first true/false word token
      final firstToken = RegExp(
        r'\b(true|false)\b',
        caseSensitive: false,
      ).firstMatch(responseText.toLowerCase())?.group(1)?.toLowerCase();
      if (firstToken != null) {
        return firstToken == 'true';
      }
    } catch (e) {
      log.warning('[TaskRunner] LLM condition evaluation failed: $e');
    }
    return false;
  }

  final sNum = double.tryParse(src);
  final vNum = double.tryParse(val);

  switch (operator) {
    case 'contains':
      return src.toLowerCase().contains(val.toLowerCase());
    case 'not_contains':
      return !src.toLowerCase().contains(val.toLowerCase());
    case 'equals':
    case '==':
      if (sNum != null && vNum != null) return sNum == vNum;
      return src.toLowerCase() == val.toLowerCase();
    case 'not_equals':
    case 'not_equal':
    case '!=':
      if (sNum != null && vNum != null) return sNum != vNum;
      return src.toLowerCase() != val.toLowerCase();
    case 'greater_than':
    case 'more':
    case '>':
      return sNum != null && vNum != null && sNum > vNum;
    case 'greater_or_equals':
    case 'more_or_equals':
    case '>=':
      return sNum != null && vNum != null && sNum >= vNum;
    case 'less_than':
    case 'less':
    case '<':
      return sNum != null && vNum != null && sNum < vNum;
    case 'less_or_equals':
    case '<=':
      return sNum != null && vNum != null && sNum <= vNum;
    default:
      return false;
  }
}
