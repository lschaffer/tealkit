import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../database/server_database_adapter.dart';
import '../models/agentic_task.dart';
import '../services/server_data_sources_service.dart';
import '../services/server_notification_service.dart';
import '../services/server_llm_settings_service.dart';
import '../utils/cron_utils.dart';
import '../utils/server_logger.dart';
import '../utils/server_live_log.dart';
import 'server_llm_runner.dart';
import 'server_tool_registry.dart';

// ═══════════════════════════════════════════════════════════════
// Task run result
// ═══════════════════════════════════════════════════════════════

class TaskRunResult {
  final bool success;
  final String resultText;
  final String? error;
  final int promptTokens;
  final int completionTokens;
  final int toolCallCount;
  final int durationMs;
  final int? messageCount;
  final int? sentChars;

  const TaskRunResult({
    required this.success,
    required this.resultText,
    this.error,
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.toolCallCount = 0,
    this.durationMs = 0,
    this.messageCount,
    this.sentChars,
  });
}

// ═══════════════════════════════════════════════════════════════
// Cancellation token
// ═══════════════════════════════════════════════════════════════

/// Simple cancellable token. Pass to [ServerTaskRunner.runTask] and call
/// [cancel] to signal the runner to abort after the current LLM step.
class CancellationToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

// ═══════════════════════════════════════════════════════════════
// Server task runner
// ═══════════════════════════════════════════════════════════════

/// Headless task runner for the server.
///
/// For each [AgenticTask]:
///  1. Builds the system prompt from the task definition.
///  2. Connects MCP tools via [ServerToolRegistry].
///  3. Runs the agentic loop via [ServerLlmRunner].
///  4. Writes output artifacts to `$TEALKIT_DATA_DIR/output/<task_id>/`.
///  5. Updates the task execution record in DuckDB.
///  6. Logs the run in the `scheduler_log` table.
///
/// No Flutter / ChangeNotifier dependency.
class ServerTaskRunner {
  static const String _formatInstruction = '''

═══════════════════════════════════════════════
🔧 TOOL CALL FORMAT (MANDATORY - use this exact format):
tool_call: {"name": "tool_name", "arguments": {"param1": "value1", "param2": 123}}
⚠️  Always use this JSON format. Do NOT use key=value format.
═══════════════════════════════════════════════

Output formatting: default to concise plain text unless the task specifies a specific format. When including hyperlinks, use plain Markdown link syntax [Title](url) — do NOT wrap links in bold markers like **[Title](url)** because the trailing )** causes email clients to capture the closing ) as part of the URL, making the link invalid.''';
  static final RegExp _markdownDataUriPattern = RegExp(
    r'\[([^\]]+)\]\((data:[^\s\)]+;base64,([A-Za-z0-9+/=\s]+))\)',
    caseSensitive: false,
    dotAll: true,
  );
  static final RegExp _boldWrappedMarkdownLinkPattern = RegExp(
    r'\*\*\s*\[([^\]]+)\]\((https?:\/\/[^\s\)]+)\)\s*\*\*',
    caseSensitive: false,
  );

  final ServerDatabaseAdapter _db;
  final ServerLlmSettingsService _llmSettings;
  final _uuid = const Uuid();

  ServerTaskRunner({
    required ServerDatabaseAdapter db,
    required ServerLlmSettingsService llmSettings,
  }) : _db = db,
       _llmSettings = llmSettings;

  // ── Public API ───────────────────────────────────────────────

  /// Run [task] headlessly.
  ///
  /// If [cancellationToken] is provided and cancelled before the LLM call
  /// completes, the run is aborted and recorded as cancelled.
  Future<TaskRunResult> runTask(
    AgenticTask task, {
    CancellationToken? cancellationToken,
    bool suppressFailureNotifications = false,
  }) async {
    log.info('[TaskRunner] Starting task "${task.name}" (id=${task.id})');
    final startTime = DateTime.now();
    final logId = _uuid.v4();

    // Log start
    await _logRun(
      id: logId,
      taskId: task.id,
      taskName: task.name,
      startedAt: startTime,
    );

    final registry = ServerToolRegistry(_db);
    TaskRunResult result = const TaskRunResult(
      success: false,
      resultText: '',
      error: 'Not executed',
    );
    String? effectiveProviderKey;
    String? effectiveModel;
    Directory? outputDir;
    final List<String> subagentOutputs = [];
    final List<String> subagentExecutionLogs = [];

    try {
      // Check cancellation before starting.
      if (cancellationToken?.isCancelled ?? false) {
        return await _finish(
          task: task,
          result: const TaskRunResult(
            success: false,
            resultText: '',
            error: 'Cancelled',
          ),
          startTime: startTime,
          logId: logId,
          registry: registry,
          outputDir: outputDir,
        );
      }

      // Create output directory early so we can write binary outputs directly to it during execution
      final taskOutputDir = Directory(p.join(_db.dataDir, 'output', task.id));
      await taskOutputDir.create(recursive: true);
      final runDirName =
          '${startTime.year.toString().padLeft(4, '0')}'
          '${startTime.month.toString().padLeft(2, '0')}'
          '${startTime.day.toString().padLeft(2, '0')}'
          '${startTime.hour.toString().padLeft(2, '0')}'
          '${startTime.minute.toString().padLeft(2, '0')}'
          '${startTime.second.toString().padLeft(2, '0')}';
      outputDir = Directory(p.join(taskOutputDir.path, runDirName));
      await outputDir.create(recursive: true);

      final List<TaskExecutor> executorsToRun = task.executors.isNotEmpty
          ? task.executors
          : [
              TaskExecutor(
                id: 'default',
                name: 'Executor',
                prompt: task.prompt,
                systemPrompt: task.systemPrompt,
                llmConfig: task.llmConfig,
                mcpTools: task.mcpTools,
                internalMcps: task.internalMcps,
                chatMode: task.chatMode,
                stopAfterToolCall: task.stopAfterToolCall,
              ),
            ];

      final Map<String, TaskExecutor> executorMap = {
        for (final e in executorsToRun) e.id: e,
      };
      TaskExecutor currentExecutor = executorsToRun.first;
      String previousStepOutput = '';
      int stepsExecuted = 0;
      int accumulatedPromptTokens = 0;
      int accumulatedCompletionTokens = 0;
      int accumulatedToolCallCount = 0;
      int accumulatedSentChars = 0;
      int accumulatedMessageCount = 0;

      while (stepsExecuted < 50) {
        stepsExecuted++;
        log.info(
          '[TaskRunner] Executing step "${currentExecutor.name}" (id=${currentExecutor.id})',
        );
        ServerLiveLog.log(
          task.id,
          '\n================================================================\n'
          '▶ AGENT RUNNING: "${currentExecutor.name}"\n'
          '================================================================',
        );

        if (cancellationToken?.isCancelled ?? false) {
          result = const TaskRunResult(
            success: false,
            resultText: '',
            error: 'Cancelled',
          );
          break;
        }

        // Connect MCP tools.
        await registry.initForTask(task, executor: currentExecutor);
        log.info(
          '[TaskRunner] ${registry.tools.length} tools ready for step "${currentExecutor.name}"',
        );

        if (cancellationToken?.isCancelled ?? false) {
          result = const TaskRunResult(
            success: false,
            resultText: '',
            error: 'Cancelled',
          );
          break;
        }

        final executorLlmConfig = currentExecutor.llmConfig ?? task.llmConfig;
        final bool usePrimary =
            executorLlmConfig == null || executorLlmConfig.provider != 'llm2';

        if (executorLlmConfig != null) {
          effectiveProviderKey = executorLlmConfig.provider
              .trim()
              .toLowerCase();
          effectiveModel = executorLlmConfig.model.trim();
        } else {
          effectiveProviderKey = usePrimary
              ? _llmSettings.provider.configKey
              : _llmSettings.provider2.configKey;
          effectiveModel = usePrimary
              ? _llmSettings.model
              : _llmSettings.model2;
        }

        final systemPrompt = await _buildSystemPrompt(
          task,
          executor: currentExecutor,
        );
        final runner = ServerLlmRunner(
          _llmSettings,
          taskId: task.id,
          stepName: currentExecutor.name,
        );

        String promptToRun = currentExecutor.prompt
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

        final bool hasPlaceholder =
            currentExecutor.prompt.contains('tool_result') ||
            currentExecutor.prompt.contains('tool_output') ||
            currentExecutor.prompt.contains('task_result') ||
            currentExecutor.prompt.contains('task_output');

        if (!hasPlaceholder && previousStepOutput.isNotEmpty) {
          promptToRun =
              '$promptToRun\n\n[Context from previous step]:\n$previousStepOutput';
        }

        final llmResult = await _runPrompt(
          runner: runner,
          systemPrompt: systemPrompt,
          prompt: promptToRun,
          registry: registry,
          usePrimary: usePrimary,
          taskLlmConfig: executorLlmConfig,
          stopAfterToolCall: currentExecutor.stopAfterToolCall,
          outputDir: outputDir,
        );

        accumulatedPromptTokens += llmResult.promptTokens;
        accumulatedCompletionTokens += llmResult.completionTokens;
        accumulatedToolCallCount += llmResult.toolCallCount;
        accumulatedSentChars += llmResult.sentChars ?? 0;
        accumulatedMessageCount += llmResult.messageCount ?? 0;

        subagentOutputs.add(llmResult.content);
        if (llmResult.executionLogSnippet != null &&
            llmResult.executionLogSnippet!.isNotEmpty) {
          subagentExecutionLogs.add(
            'Step: ${currentExecutor.name}\n${llmResult.executionLogSnippet}',
          );
        }

        await _writeExecutorStepOutputFiles(
          taskId: task.id,
          executor: currentExecutor,
          content: llmResult.content,
          success: llmResult.success,
          outputDir: outputDir,
        );

        try {
          final shouldDeliver =
              llmResult.success || !suppressFailureNotifications;
          final isDuplicate =
              jsonEncode(currentExecutor.notification.toJson()) ==
              jsonEncode(task.notification.toJson());
          if (shouldDeliver && !isDuplicate) {
            await ServerNotificationService().deliverExecutorNotification(
              taskId: task.id,
              executorName: currentExecutor.name,
              notification: currentExecutor.notification,
              success: llmResult.success,
              resultText: llmResult.content,
              errorText: llmResult.success ? null : llmResult.error,
            );
          }
        } catch (e) {
          log.warning('[TaskRunner] Failed to deliver step notification: $e');
        }

        if (!llmResult.success) {
          result = TaskRunResult(
            success: false,
            resultText: llmResult.content,
            error: llmResult.error,
            promptTokens: accumulatedPromptTokens,
            completionTokens: accumulatedCompletionTokens,
            toolCallCount: accumulatedToolCallCount,
            durationMs: DateTime.now().difference(startTime).inMilliseconds,
            messageCount: accumulatedMessageCount,
            sentChars: accumulatedSentChars,
          );
          break;
        }

        previousStepOutput = llmResult.content;
        result = TaskRunResult(
          success: true,
          resultText: llmResult.content,
          promptTokens: accumulatedPromptTokens,
          completionTokens: accumulatedCompletionTokens,
          toolCallCount: accumulatedToolCallCount,
          durationMs: DateTime.now().difference(startTime).inMilliseconds,
          messageCount: accumulatedMessageCount,
          sentChars: accumulatedSentChars,
        );

        // Clean registry connections between steps
        await registry.dispose();

        // 7. Dynamic Routing
        String? nextExecutorId;
        final rules = task.routingRules
            .where((r) => r.sourceExecutorId == currentExecutor.id)
            .toList();
        for (final rule in rules) {
          final valueToCheck = previousStepOutput;
          final stepName = currentExecutor.name;
          ServerLiveLog.log(
            task.id,
            '[$stepName] Evaluating routing condition: "${rule.value}"',
          );
          final met = await _evaluateCondition(
            valueToCheck,
            rule.operator,
            rule.value,
            llmSettings: _llmSettings,
            db: _db,
          );
          ServerLiveLog.log(
            task.id,
            '[$stepName] Condition "${rule.value}" result: ${met ? "MET (True)" : "NOT MET (False)"}',
          );
          if (met) {
            nextExecutorId = rule.targetExecutorId;
            log.info(
              '[TaskRunner] Routing condition met: ${rule.variable} ${rule.operator} ${rule.value}. Routing to $nextExecutorId',
            );
            ServerLiveLog.log(
              task.id,
              '[$stepName] Routing condition met. Routing to $nextExecutorId',
            );
            break;
          }
        }

        if (nextExecutorId != null) {
          if (executorMap.containsKey(nextExecutorId)) {
            currentExecutor = executorMap[nextExecutorId]!;
          } else {
            log.warning(
              '[TaskRunner] Routed target executor $nextExecutorId not found. Terminating.',
            );
            break;
          }
        } else {
          if (rules.isNotEmpty) {
            log.info(
              '[TaskRunner] No routing conditions met for conditional step. Terminating.',
            );
            break;
          }
          final currentIndex = executorsToRun.indexOf(currentExecutor);
          if (currentIndex != -1 && currentIndex + 1 < executorsToRun.length) {
            currentExecutor = executorsToRun[currentIndex + 1];
          } else {
            break;
          }
        }
      }
    } catch (e, st) {
      log.error('[TaskRunner] Task "${task.name}" threw: $e', e, st);
      result = TaskRunResult(
        success: false,
        resultText: '',
        error: e.toString(),
        durationMs: DateTime.now().difference(startTime).inMilliseconds,
      );
    }

    final combinedOutput = subagentOutputs
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .join('\n----\n');
    final combinedExecLog = subagentExecutionLogs.join(
      '\n========================================\n',
    );

    return _finish(
      task: task,
      result: result,
      startTime: startTime,
      logId: logId,
      registry: registry,
      effectiveProviderKey: effectiveProviderKey,
      effectiveModel: effectiveModel,
      outputDir: outputDir,
      combinedOutput: combinedOutput.isNotEmpty ? combinedOutput : null,
      combinedExecutionLog: combinedExecLog.isNotEmpty ? combinedExecLog : null,
    );
  }

  // ── Helpers ─────────────────────────────────────────────────

  // Supports legacy [Nd], named tools [NT:...], and per-step [SATC] flag.
  static final RegExp _subPromptSepRegex = RegExp(
    r'^\+\+#\+\+(?:\[N(\d)\]|\[NT:([^\]]*)\])?(\[SATC\])?\r?$',
    multiLine: true,
  );

  /// Parse a separator match into `List<String>? toolNames`:
  ///   null = all tools, [] = no tools, [...] = specific named tools.
  static List<String>? _stepToolNames(RegExpMatch? match) {
    if (match == null) {
      return null; // bare separator or no separator → all tools
    }
    final legacyDigit = match.group(1);
    final ntContent = match.group(2);
    if (legacyDigit != null) {
      if (legacyDigit == '0') return const []; // N0 → no tools
      return null; // N1/N2 → all tools
    }
    if (ntContent != null) {
      if (ntContent.isEmpty) return const []; // [NT:] → no tools
      return ntContent.split('|'); // [NT:t1|t2] → ['t1','t2']
    }
    return null;
  }

  /// Parse a prompt into `(text, toolNames, stopAfterToolCall)` tuples.
  static List<({String text, List<String>? toolNames, bool stopAfterToolCall})>
  _parseSteps(String prompt) {
    final matches = _subPromptSepRegex.allMatches(prompt).toList();
    if (matches.isEmpty) {
      return [(text: prompt.trim(), toolNames: null, stopAfterToolCall: false)];
    }
    final steps =
        <({String text, List<String>? toolNames, bool stopAfterToolCall})>[];
    final beforeFirst = prompt.substring(0, matches[0].start).trim();
    if (beforeFirst.isNotEmpty) {
      steps.add((text: beforeFirst, toolNames: null, stopAfterToolCall: false));
    }
    for (int i = 0; i < matches.length; i++) {
      final m = matches[i];
      final names = _stepToolNames(m);
      final satc = m.group(3) != null;
      final segEnd = i + 1 < matches.length
          ? matches[i + 1].start
          : prompt.length;
      final segText = prompt.substring(m.end, segEnd).trim();
      steps.add((text: segText, toolNames: names, stopAfterToolCall: satc));
    }
    if (steps.isEmpty) {
      steps.add((text: '', toolNames: null, stopAfterToolCall: false));
    }
    return steps;
  }

  /// Runs a prompt, handling `++#++[Nn]?` (standalone line) sub-prompt chaining.
  /// Each sub-prompt is executed sequentially; `${tool_result}` in a later
  /// step is replaced with the raw tool output (or LLM content) of the
  /// previous step.  The optional `[N0]`/`[N1]`/`[N2]` tag on the separator
  /// controls which tools are available for that step:
  ///   N0 = no tools, N1 = basic tools (calc/math/convert), N2/bare = all tools.
  Future<LlmRunResult> _runPrompt({
    required ServerLlmRunner runner,
    required String systemPrompt,
    required String prompt,
    required ServerToolRegistry registry,
    required bool usePrimary,
    TaskLlmConfig? taskLlmConfig,
    required bool stopAfterToolCall,
    Directory? outputDir,
  }) async {
    if (!_subPromptSepRegex.hasMatch(prompt)) {
      return runner.run(
        systemPrompt: systemPrompt,
        userPrompt: prompt,
        registry: registry,
        usePrimary: usePrimary,
        taskLlmConfig: taskLlmConfig,
        stopAfterToolCall: stopAfterToolCall,
        outputDir: outputDir,
      );
    }

    final subSteps = _parseSteps(prompt);

    // Split the system prompt on the same separator for per-step system instructions.
    final List<String> sysPromptParts = () {
      final raw = systemPrompt.trim();
      if (raw.isEmpty) return <String>[];
      return _parseSteps(
        raw,
      ).where((s) => s.text.isNotEmpty).map((s) => s.text).toList();
    }();

    int totalPromptTokens = 0;
    int totalCompletionTokens = 0;
    int totalToolCalls = 0;
    int totalSentChars = 0;
    int totalMessages = 0;
    LlmRunResult? lastResult;
    String? pendingInjection; // raw tool output or content from previous step

    for (int i = 0; i < subSteps.length; i++) {
      if (subSteps.length > 1 && runner.taskId != null) {
        ServerLiveLog.log(
          runner.taskId!,
          '\n----------------------------------------------------------------\n'
          '👉 Subprompt ${i + 1}/${subSteps.length}\n'
          '----------------------------------------------------------------',
        );
      }
      var stepPrompt = subSteps[i].text;
      final stepToolNames = subSteps[i].toolNames;
      final nextNeedsToolResult =
          (i + 1 < subSteps.length) &&
          (subSteps[i + 1].text.contains('tool_result') ||
              subSteps[i + 1].text.contains('tool_output') ||
              subSteps[i + 1].text.contains('task_result') ||
              subSteps[i + 1].text.contains('task_output'));
      final stepStopAfterToolCall =
          nextNeedsToolResult || subSteps[i].stopAfterToolCall;
      if (pendingInjection != null) {
        stepPrompt = stepPrompt
            .replaceAll(r'${tool_result}', pendingInjection)
            .replaceAll('[tool_result]', pendingInjection)
            .replaceAll(r'$(tool_result)', pendingInjection)
            .replaceAll(r'${tool_output}', pendingInjection)
            .replaceAll('[tool_output]', pendingInjection)
            .replaceAll(r'$(tool_output)', pendingInjection)
            .replaceAll(r'${task_result}', pendingInjection)
            .replaceAll('[task_result]', pendingInjection)
            .replaceAll(r'$(task_result)', pendingInjection)
            .replaceAll(r'${task_output}', pendingInjection)
            .replaceAll('[task_output]', pendingInjection)
            .replaceAll(r'$(task_output)', pendingInjection);
        pendingInjection = null;
      }

      // Use step-specific system prompt section if available.
      var stepSystemPrompt = sysPromptParts.length > 1
          ? sysPromptParts[i < sysPromptParts.length
                ? i
                : sysPromptParts.length - 1]
          : systemPrompt;

      // Compute per-step tool list based on tool names tag.
      List<MCPTool>? stepToolsOverride;
      if (stepToolNames != null) {
        stepSystemPrompt = _filterSkillsForStep(
          stepSystemPrompt,
          stepToolNames,
        );
        if (stepToolNames.isEmpty) {
          stepToolsOverride = const []; // no tools
        } else {
          stepToolsOverride = registry.mcpTools
              .where((t) => stepToolNames.contains(t.name))
              .toList();
        }
      }
      // stepToolNames == null → toolsOverride null → all tools

      lastResult = await runner.run(
        systemPrompt: stepSystemPrompt,
        userPrompt: stepPrompt,
        registry: registry,
        usePrimary: usePrimary,
        taskLlmConfig: taskLlmConfig,
        toolsOverride: stepToolsOverride,
        stopAfterToolCall: stepStopAfterToolCall,
        outputDir: outputDir,
      );

      totalPromptTokens += lastResult.promptTokens;
      totalCompletionTokens += lastResult.completionTokens;
      totalToolCalls += lastResult.toolCallCount;
      totalSentChars += lastResult.sentChars ?? 0;
      totalMessages += lastResult.messageCount ?? 0;

      if (!lastResult.success) break;

      // Prepare injection for the next step if it uses ${tool_result}.
      if (nextNeedsToolResult) {
        // Prefer raw tool output; fall back to LLM synthesis.
        pendingInjection = lastResult.rawToolOutput ?? lastResult.content;
      }

      // Task-level global stopAfterToolCall: after a step produced tool output,
      // stop the chain unless the next step explicitly consumes it.
      if (stopAfterToolCall && !nextNeedsToolResult) {
        if (lastResult.toolCallCount > 0) {
          log.info(
            '[TaskRunner] [stopAfterToolCall] Breaking sub-prompt chain after step ${i + 1} — no result consumer in next step',
          );
          break;
        }
      }
    }

    return LlmRunResult(
      content: lastResult?.content ?? '',
      success: lastResult?.success ?? false,
      error: lastResult?.error,
      promptTokens: totalPromptTokens,
      completionTokens: totalCompletionTokens,
      toolCallCount: totalToolCalls,
      sentChars: totalSentChars,
      messageCount: totalMessages,
    );
  }

  Future<TaskRunResult> _finish({
    required AgenticTask task,
    required TaskRunResult result,
    required DateTime startTime,
    required String logId,
    required ServerToolRegistry registry,
    String? effectiveProviderKey,
    String? effectiveModel,
    Directory? outputDir,
    String? combinedOutput,
    String? combinedExecutionLog,
  }) async {
    final endTime = DateTime.now();
    final durationMs = endTime.difference(startTime).inMilliseconds;
    final normalizedResultText = _normalizeResultMarkdownLinks(
      result.resultText,
    );
    final normalizedResult = normalizedResultText == result.resultText
        ? result
        : TaskRunResult(
            success: result.success,
            resultText: normalizedResultText,
            error: result.error,
            promptTokens: result.promptTokens,
            completionTokens: result.completionTokens,
            toolCallCount: result.toolCallCount,
            durationMs: result.durationMs,
            messageCount: result.messageCount,
            sentChars: result.sentChars,
          );

    // Dispose registry.
    try {
      await registry.dispose();
    } catch (_) {}

    // Write output files even for error-only runs so every execution leaves a trace.
    if (normalizedResult.resultText.isNotEmpty ||
        (normalizedResult.error?.isNotEmpty ?? false)) {
      await _writeOutputFiles(
        task: task,
        result: normalizedResult,
        durationMs: durationMs,
        outputDir: outputDir,
        combinedOutput: combinedOutput,
        combinedExecutionLog: combinedExecutionLog,
      );
    }

    // Update execution record.
    try {
      final nextRun = nextCronFire(task.executionPlan.cronExpression).toUtc();
      double? lastRequestCostUsd;
      double? sessionCostUsd;

      final providerKey = (effectiveProviderKey ?? '').trim().toLowerCase();
      final model = (effectiveModel ?? '').trim();
      if (providerKey.isNotEmpty && model.isNotEmpty) {
        try {
          await refreshModelTokenPrice(providerKey: providerKey, model: model);
        } catch (e) {
          log.warning(
            '[TaskRunner] Live model price refresh failed for $providerKey/$model: $e',
          );
        }

        final estimated = estimateTokenCostUsd(
          providerKey: providerKey,
          model: model,
          promptTokens: normalizedResult.promptTokens,
          completionTokens: normalizedResult.completionTokens,
        );

        if (estimated > 0) {
          lastRequestCostUsd = estimated;
          final prevSessionCost = task.execution.history.isNotEmpty
              ? (task.execution.history.first.sessionCostUsd ?? 0)
              : 0;
          sessionCostUsd = prevSessionCost + estimated;
        }
      }

      final updated = task.execution.recordRun(
        success: normalizedResult.success,
        result:
            normalizedResult.success && normalizedResult.resultText.isNotEmpty
            ? normalizedResult.resultText
            : null,
        error: normalizedResult.error,
        nextRun: nextRun,
        durationMs: durationMs,
        tokensUsed:
            normalizedResult.promptTokens + normalizedResult.completionTokens,
        toolCallCount: normalizedResult.toolCallCount,
        messageCount: normalizedResult.messageCount,
        sentChars: normalizedResult.sentChars,
        lastRequestCostUsd: lastRequestCostUsd,
        sessionCostUsd: sessionCostUsd,
      );
      await _db.updateExecution(task.id, updated);
    } catch (e) {
      log.warning('[TaskRunner] Failed to update execution record: $e');
    }

    // Complete scheduler log entry.
    await _logRun(
      id: logId,
      taskId: task.id,
      taskName: task.name,
      startedAt: startTime,
      endedAt: endTime,
      success: result.success,
      message: result.error,
    );

    log.info(
      '[TaskRunner] Task "${task.name}" done — '
      'success=${result.success} duration=${durationMs}ms '
      'tokens=${result.promptTokens + result.completionTokens}',
    );

    // Handle all post-execution notifications and task chaining
    try {
      await ServerNotificationService().handleTaskCompletion(
        task: task,
        success: normalizedResult.success,
        resultText: normalizedResult.resultText,
        errorText: normalizedResult.error,
      );
    } catch (e) {
      log.warning(
        '[TaskRunner] Error in notification/chaining handler for task "${task.name}": $e',
      );
    }

    return TaskRunResult(
      success: normalizedResult.success,
      resultText: normalizedResult.resultText,
      error: normalizedResult.error,
      promptTokens: normalizedResult.promptTokens,
      completionTokens: normalizedResult.completionTokens,
      toolCallCount: normalizedResult.toolCallCount,
      durationMs: durationMs,
      messageCount: normalizedResult.messageCount,
      sentChars: normalizedResult.sentChars,
    );
  }

  String _normalizeResultMarkdownLinks(String text) {
    if (text.isEmpty) return text;

    var normalized = text.replaceAllMapped(_boldWrappedMarkdownLinkPattern, (
      match,
    ) {
      final title = (match.group(1) ?? '').trim();
      final url = (match.group(2) ?? '').trim();
      if (title.isEmpty || url.isEmpty) return match.group(0) ?? '';
      return '[$title]($url)';
    });

    normalized = normalized.replaceAllMapped(
      RegExp(
        r'(\[[^\]]+\]\(https?:\/\/[^\s\)]+\))\*{1,3}',
        caseSensitive: false,
      ),
      (m) => m.group(1) ?? m.group(0) ?? '',
    );

    normalized = normalized.replaceAllMapped(
      RegExp(
        r'(https?:\/\/[^\s<>{}\[\]\|`^\\]+)\)\*{1,3}(?=[\s\.,;:!?]|$)',
        caseSensitive: false,
      ),
      (m) => m.group(1) ?? m.group(0) ?? '',
    );

    return normalized;
  }

  Future<String> _buildSystemPrompt(
    AgenticTask task, {
    TaskExecutor? executor,
  }) async {
    var prompt = (executor?.systemPrompt ?? task.systemPrompt ?? '').trim();
    if (prompt.isEmpty) {
      prompt =
          'You are a helpful AI assistant running scheduled tasks for the user.';
    }

    final skillDefId =
        executor?.skillDefId ??
        (task.agents.isNotEmpty ? task.agents.first.skillDefId : null);
    if (skillDefId != null && skillDefId.isNotEmpty) {
      try {
        final skillMap = await _db.getSkillDef(skillDefId);
        if (skillMap != null) {
          final skillDefStr = skillMap['skill_def']?.toString().trim();
          if (skillDefStr != null &&
              skillDefStr.isNotEmpty &&
              !prompt.contains(skillDefStr)) {
            prompt = '$prompt\n\n$skillDefStr';
          }
        }
      } catch (e) {
        log.warning(
          '[ServerTaskRunner] Could not load skill $skillDefId for server system prompt: $e',
        );
      }
    }

    final internalMcps = executor?.internalMcps ?? task.internalMcps;
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
            'Chart internal MCP is not available in headless server mode. '
            'Use bundled Matplotlib MCP tools instead (for example: '
            'matplotlib_create_line_plot, matplotlib_create_scatter_plot, matplotlib_create_bar_plot, matplotlib_statistical_summary).',
          );
      }
    }
    if (capabilityHints.isNotEmpty) {
      if (hasWebSearch) {
        capabilityHints.add(
          'Never output generic placeholders like "Link". Show readable title plus absolute URL.',
        );
      }
      final hintsBlock =
          'Enabled capabilities:\n- ${capabilityHints.join("\n- ")}';
      prompt = '$prompt\n\n$hintsBlock';
    }

    // Keep tool-argument behavior aligned with local app runtime prompts.
    prompt +=
        '\n\nWhen building tool arguments: include required parameters always; include optional parameters only if '
        'the user explicitly requested/provided them or if the tool skill/schema defines a default value. '
        'Never fabricate optional values.';

    // Inject stored user location coordinates if toolbox is enabled
    final toolboxDisabled = internalMcps.any(
      (m) => m.mcpType == 'toolbox' && !m.enabled,
    );
    final ds = ServerDataSourcesService.instance;
    if (!toolboxDisabled && ds.hasLocation) {
      final locCtx =
          'USER LOCATION: The user is currently at coordinates '
          '${ds.locationLatitude!.toStringAsFixed(5)}, ${ds.locationLongitude!.toStringAsFixed(5)}. '
          'When the user says "my location", "here", "near me" or "current position", use these coordinates. '
          'IMPORTANT: For travel searches (flights, trains, hotels, restaurants, weather, etc.) that require '
          'a city name, region, or airport code, first determine the nearest city and airport from these '
          'coordinates — do NOT use a default or example city like Los Angeles. Always derive the departure '
          'location from the user\'s actual coordinates.';
      prompt = '$prompt\n\n$locCtx';
    }

    prompt +=
        '\n\nCurrent date and time: ${DateTime.now().toIso8601String().substring(0, 16)} UTC';

    if (!prompt.contains(_formatInstruction)) {
      prompt += '\n\n$_formatInstruction';
    }

    if (task.stopAfterToolCall) {
      prompt +=
          '\n\nExecute exactly one tool call and return the raw result without further processing.';
    }

    return prompt;
  }

  String _filterSkillsForStep(String prompt, List<String> enabledToolNames) {
    const marker = '\n\nTool Hints:';
    final idx = prompt.indexOf(marker);
    if (idx < 0) return prompt; // no skills block present
    final base = prompt.substring(0, idx);
    if (enabledToolNames.isEmpty) {
      return base; // no-tools step → strip all skills
    }
    // Keep only bullet lines whose tool name is in the enabled set.
    final skillsSection = prompt.substring(idx + marker.length);
    final kept = <String>[];
    for (final line in skillsSection.split('\n')) {
      if (line.trim().isEmpty) continue;
      final match = RegExp(r'^[•]\s+(\S+?):\s').firstMatch(line.trim());
      if (match != null && enabledToolNames.contains(match.group(1))) {
        kept.add(line.trim());
      }
    }
    if (kept.isEmpty) return base;
    return '$base\n\nTool Hints:\n${kept.join('\n')}';
  }

  Future<void> _writeOutputFiles({
    required AgenticTask task,
    required TaskRunResult result,
    required int durationMs,
    Directory? outputDir,
    String? combinedOutput,
    String? combinedExecutionLog,
  }) async {
    try {
      final db = _db;
      final resolvedDir =
          outputDir ??
          await () async {
            final taskOutputDir = Directory(
              p.join(db.dataDir, 'output', task.id),
            );
            await taskOutputDir.create(recursive: true);

            final now = DateTime.now();
            final runDirName =
                '${now.year.toString().padLeft(4, '0')}'
                '${now.month.toString().padLeft(2, '0')}'
                '${now.day.toString().padLeft(2, '0')}'
                '${now.hour.toString().padLeft(2, '0')}'
                '${now.minute.toString().padLeft(2, '0')}'
                '${now.second.toString().padLeft(2, '0')}';
            final d = Directory(p.join(taskOutputDir.path, runDirName));
            await d.create(recursive: true);
            return d;
          }();

      final outputBody =
          combinedOutput ??
          (result.resultText.isNotEmpty
              ? result.resultText
              : (result.error ?? ''));
      final outputLogFile = File(p.join(resolvedDir.path, 'output.log'));
      await outputLogFile.writeAsString(outputBody, flush: true);

      await _extractAndSaveGeneratedFiles(
        outputDir: resolvedDir,
        resultText: result.resultText,
      );

      final String execLog;
      if (combinedExecutionLog != null && combinedExecutionLog.isNotEmpty) {
        execLog = combinedExecutionLog;
      } else {
        final execLogBuf = StringBuffer()
          ..writeln('# Execution Log')
          ..writeln('- task_id: ${task.id}')
          ..writeln('- task_name: ${task.name}')
          ..writeln('- timestamp: ${DateTime.now().toIso8601String()}')
          ..writeln('- success: ${result.success}')
          ..writeln('- duration_ms: $durationMs')
          ..writeln(
            '- tokens_used: ${result.promptTokens + result.completionTokens}',
          )
          ..writeln('- tool_calls: ${result.toolCallCount}');
        if (result.error != null && result.error!.isNotEmpty) {
          execLogBuf.writeln('- error: ${result.error}');
        }
        execLog = execLogBuf.toString();
      }

      final executionLogFile = File(p.join(resolvedDir.path, 'execution.log'));
      await executionLogFile.writeAsString(execLog, flush: true);

      log.info('[TaskRunner] Output written to ${resolvedDir.path}');
    } catch (e) {
      log.warning('[TaskRunner] Failed to write output files: $e');
    }
  }

  Future<void> _writeExecutorStepOutputFiles({
    required String taskId,
    required TaskExecutor executor,
    required String content,
    required bool success,
    required Directory outputDir,
  }) async {
    try {
      final cleanName = executor.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final stepLogFile = File(
        p.join(outputDir.path, '${cleanName}_output.log'),
      );
      await stepLogFile.writeAsString(content, flush: true);

      final htmlSections = _extractHtmlSections(content);
      for (int i = 0; i < htmlSections.length; i++) {
        // Write step-specific html file
        final stepHtmlName = htmlSections.length == 1
            ? '${cleanName}_output.html'
            : '${cleanName}_output_${i + 1}.html';
        final stepHtmlFile = File(p.join(outputDir.path, stepHtmlName));
        await stepHtmlFile.writeAsString(htmlSections[i], flush: true);
      }

      await _extractAndSaveGeneratedFiles(
        outputDir: outputDir,
        resultText: content,
      );
    } catch (e) {
      log.warning('[TaskRunner] Failed to write step output files: $e');
    }
  }

  /// Extract file mentions from result text and save referenced JSON/CSV/Excel files.
  /// Looks for patterns in output like "saved to filename.json" and creates placeholders.
  Future<void> _extractAndSaveGeneratedFiles({
    required Directory outputDir,
    required String resultText,
  }) async {
    try {
      // Decode embedded markdown data-URI files like:
      // [measurement_data.xlsx](data:application/vnd.openxmlformats-officedocument.spreadsheetml.sheet;base64,...)
      // so downstream channels (SFTP, ZIP output) can upload real files instead of only text logs.
      var embeddedIndex = 0;
      for (final match in _markdownDataUriPattern.allMatches(resultText)) {
        final rawName = (match.group(1) ?? '').trim();
        final dataUri = (match.group(2) ?? '').trim();
        if (dataUri.isEmpty) continue;

        final uri = Uri.tryParse(dataUri);
        final uriData = uri?.data;
        if (uriData == null) continue;

        final bytes = uriData.contentAsBytes();
        if (bytes.isEmpty) continue;

        final fallbackName =
            'embedded_file_${embeddedIndex + 1}${_defaultExtensionForMediaType(uriData.mimeType)}';
        final fileName = _sanitizeFileName(
          rawName.isNotEmpty ? rawName : fallbackName,
          fallbackName: fallbackName,
        );
        final file = File(p.join(outputDir.path, fileName));
        await file.writeAsBytes(bytes, flush: true);
        embeddedIndex++;
        log.info(
          '[TaskRunner] Extracted embedded file: $fileName (${bytes.length} bytes)',
        );
      }

      final patterns = [
        RegExp(
          r'''(?:saved|created|wrote|generated)\s+(?:to|as|in)?\s+["']?([a-zA-Z0-9_\-\.]+\.(?:json|csv|xlsx|xls|pdf|txt|md|xml))["']?''',
          caseSensitive: false,
        ),
        RegExp(
          r'''output:\s+["']?([a-zA-Z0-9_\-\.]+\.(?:json|csv|xlsx|xls|pdf|txt|md|xml))["']?''',
          caseSensitive: false,
        ),
        RegExp(
          r'''file:\s+["']?([a-zA-Z0-9_\-\.]+\.(?:json|csv|xlsx|xls|pdf|txt|md|xml))["']?''',
          caseSensitive: false,
        ),
      ];

      final extractedFiles = <String>{};
      for (final pattern in patterns) {
        for (final match in pattern.allMatches(resultText)) {
          final fileName = match.group(1);
          if (fileName != null && fileName.isNotEmpty) {
            extractedFiles.add(fileName);
          }
        }
      }

      for (final fileName in extractedFiles) {
        final file = File(p.join(outputDir.path, fileName));
        if (await file.exists()) continue;

        final lower = fileName.toLowerCase();
        if (lower.endsWith('.json')) {
          final jsonCandidate = _extractFirstJsonBlock(resultText);
          if (jsonCandidate != null) {
            await file.writeAsString(jsonCandidate, flush: true);
            log.info('[TaskRunner] Created JSON output file: $fileName');
            continue;
          }
        }

        final note =
            '# File marker: $fileName was generated by a tool during this execution.\n'
            '# This file was referenced in the task output but full content was not found in final text.\n'
            '# Check raw tool output or upload channels for full binary payload.';
        await file.writeAsString(note, flush: true);
        log.info('[TaskRunner] Created file marker for: $fileName');
      }
    } catch (e) {
      log.warning('[TaskRunner] Failed to extract generated files: $e');
    }
  }

  String _sanitizeFileName(String name, {required String fallbackName}) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return fallbackName;
    final cleaned = trimmed
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), '_');
    return cleaned.isEmpty ? fallbackName : cleaned;
  }

  String _defaultExtensionForMediaType(String? mediaType) {
    final mt = (mediaType ?? '').toLowerCase();
    if (mt.contains('spreadsheetml.sheet')) return '.xlsx';
    if (mt.contains('/pdf')) return '.pdf';
    if (mt.contains('/json')) return '.json';
    if (mt.contains('/csv') || mt.contains('comma-separated-values')) {
      return '.csv';
    }
    if (mt.contains('/png')) return '.png';
    if (mt.contains('/jpeg') || mt.contains('/jpg')) return '.jpg';
    if (mt.contains('/plain')) return '.txt';
    return '';
  }

  String? _extractFirstJsonBlock(String text) {
    final trimmed = text.trim();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        final decoded = jsonDecode(trimmed);
        return const JsonEncoder.withIndent('  ').convert(decoded);
      } catch (_) {}
    }

    final fenced = RegExp(
      r'```json\s*([\s\S]*?)```',
      caseSensitive: false,
    ).firstMatch(text)?.group(1)?.trim();
    if (fenced != null && fenced.isNotEmpty) {
      try {
        final decoded = jsonDecode(fenced);
        return const JsonEncoder.withIndent('  ').convert(decoded);
      } catch (_) {}
    }
    return null;
  }

  List<String> _extractHtmlSections(String text) {
    final trimmed = text.trim();
    final lower = trimmed.toLowerCase();
    if (trimmed.isEmpty || lower == 'no output') return const [];

    final sections = <String>[];

    // 1. Markdown code fence: ```html\n...\n```
    final fenceMatch = RegExp(
      r'```html\s*\n([\s\S]*?)\n?```',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (fenceMatch != null) {
      final extracted = fenceMatch.group(1)?.trim() ?? '';
      if (extracted.isNotEmpty) {
        sections.add(extracted);
        return sections;
      }
    }

    // 2. Raw HTML (starts with <!DOCTYPE html> or <html)
    if (lower.contains('<!doctype html') || lower.contains('<html')) {
      final htmlMatch = RegExp(
        r'(?:<!doctype\s+html[^>]*>\s*)?<html[\s\S]*?</html>',
        caseSensitive: false,
      ).firstMatch(trimmed);
      if (htmlMatch != null) {
        sections.add(htmlMatch.group(0)!.trim());
        return sections;
      }
      sections.add(trimmed);
      return sections;
    }

    // 3. Fallback: contains common HTML tags (div, table, p, h1, etc.)
    if (RegExp(
      r'<(div|span|table|p|h1|h2|h3|ul|ol|li|body)[\s>]',
      caseSensitive: false,
    ).hasMatch(lower)) {
      sections.add(trimmed);
      return sections;
    }

    return const [];
  }

  Future<void> _logRun({
    required String id,
    required String taskId,
    required String taskName,
    required DateTime startedAt,
    DateTime? endedAt,
    bool? success,
    String? message,
  }) async {
    try {
      await _db.logSchedulerRun(
        id: id,
        taskId: taskId,
        taskName: taskName,
        startedAt: startedAt,
        endedAt: endedAt,
        success: success,
        message: message,
      );
    } catch (e) {
      log.warning('[TaskRunner] Failed to write scheduler log: $e');
    }
  }
}

Future<bool> _evaluateCondition(
  String source,
  String operator,
  String value, {
  required ServerLlmSettingsService llmSettings,
  required ServerDatabaseAdapter db,
}) async {
  final src = source.trim();
  final val = value.trim();

  if (operator == 'always' || operator == 'sequential') {
    return true;
  }

  if (operator == 'llm_eval' || operator == 'evaluated_by_llm') {
    try {
      final runner = ServerLlmRunner(llmSettings);
      final emptyRegistry = ServerToolRegistry(db);

      final evaluationPrompt =
          'Analyze the following Task Result and check if the given Condition is met.\n'
          'Provide a brief one-line reasoning (perform any math/checks step-by-step), and then conclude with exactly "RESULT: TRUE" or "RESULT: FALSE".\n\n'
          'Condition: $val\n\n'
          'Task Result:\n$src\n\n'
          'Format:\n'
          'Reasoning: <brief reasoning>\n'
          'RESULT: <TRUE or FALSE>';

      final result = await runner.run(
        systemPrompt:
            'You are a strict logic evaluator. Reply with step-by-step reasoning first, then conclude with RESULT: TRUE or RESULT: FALSE.',
        userPrompt: evaluationPrompt,
        registry: emptyRegistry,
      );

      if (result.success && result.content.isNotEmpty) {
        final responseText = result.content.trim();

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
      }
    } catch (e) {
      log.warning('[TaskRunner] LLM condition evaluation failed: $e');
    }
    return false;
  }

  switch (operator) {
    case 'contains':
      return src.toLowerCase().contains(val.toLowerCase());
    case 'equals':
      return src.toLowerCase() == val.toLowerCase();
    case 'not_equals':
      return src.toLowerCase() != val.toLowerCase();
    case 'greater_than':
      final sNum = double.tryParse(src);
      final vNum = double.tryParse(val);
      return sNum != null && vNum != null && sNum > vNum;
    case 'less_than':
      final sNum = double.tryParse(src);
      final vNum = double.tryParse(val);
      return sNum != null && vNum != null && sNum < vNum;
    default:
      return false;
  }
}
