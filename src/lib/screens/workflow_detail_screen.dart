import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/app_localizations.dart';
import 'package:mime/mime.dart';
import 'package:open_file/open_file.dart';
import '../config/app_theme.dart';
import '../models/workflow_task.dart';
import '../providers/database_providers.dart';
import '../providers/server_mode_provider.dart';
import '../services/scheduler_log_service.dart';
import '../services/task_output_file_service.dart';
import '../services/app_preferences_service.dart';
import '../services/llm_settings_service.dart';

// ─── Conversation step model (for chat-style user output) ──────────────────
enum _ConvStepType { systemInfo, userPrompt, toolCall, toolResult, llmText }

class _ConvStep {
  final _ConvStepType type;
  final String text;
  final String? label;
  const _ConvStep(this.type, this.text, {this.label});
}

/// One run-directory entry under task_outputs/safeId_stamp/
class _OutputRunDir {
  final String path;
  final String label;
  final List<String> files;
  const _OutputRunDir(this.path, this.label, this.files);
}

/// Detail view for an [WorkflowTask].
/// Sections: General · Prompts · Schedule (with Last/Next Run) ·
///           LLM · MCP · Providers · Notifications ·
///           Raw Output · Output User · Output Files · Scheduler Log
class WorkflowDetailScreen extends ConsumerStatefulWidget {
  final WorkflowTask task;
  final bool isDialog;

  const WorkflowDetailScreen({super.key, required this.task, this.isDialog = false});

  @override
  ConsumerState<WorkflowDetailScreen> createState() => _TaskDetailScreenState();
}

class _TaskDetailScreenState extends ConsumerState<WorkflowDetailScreen> with WidgetsBindingObserver {
  late Future<List<SchedulerLogEntry>> _schedulerLogFuture;
  late Future<List<_OutputRunDir>> _outputFilesFuture;
  int _selectedExecIndex = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshAsyncData();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Auto-refresh logs and output files when the app returns to the foreground
  /// (e.g. after a background scheduled run completed while the screen was open).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      setState(() => _refreshAsyncData());
    }
  }

  void _refreshAsyncData() {
    _schedulerLogFuture = _loadSchedulerLogEntries();
    _outputFilesFuture = _loadOutputFiles();
  }

  Future<List<SchedulerLogEntry>> _loadSchedulerLogEntries() async {
    final mode = ref.read(serverModeProvider).value;
    final isRemote = mode?.isRemote ?? false;
    final client = ref.read(serverApiClientProvider);
    if (isRemote && client != null) {
      try {
        final response = await client.getSchedulerLog(limit: 100);
        final entriesRaw = response['entries'] as List<dynamic>? ?? const <dynamic>[];
        final mapped = <SchedulerLogEntry>[];
        for (final raw in entriesRaw) {
          if (raw is! Map) continue;
          final taskId = (raw['task_id'] as String?) ?? '';
          if (taskId != widget.task.id) continue;
          final taskName = (raw['task_name'] as String?) ?? widget.task.name;
          final startedAtRaw = raw['started_at']?.toString();
          final startedAt = DateTime.tryParse(startedAtRaw ?? '') ?? DateTime.now();
          final success = raw['success'] == true;
          final message = raw['message'] as String?;
          mapped.add(
            SchedulerLogEntry(
              timestamp: startedAt,
              taskId: taskId,
              taskName: taskName,
              event: success ? SchedulerEventType.completed : SchedulerEventType.failed,
              detail: message,
            ),
          );
        }
        return mapped;
      } catch (_) {
        // Fall back to local scheduler logs if server endpoint is unavailable.
      }
    }
    return SchedulerLogService().readForTask(widget.task.id);
  }

  Future<List<_OutputRunDir>> _loadOutputFiles() async {
    try {
      final mode = ref.read(serverModeProvider).value;
      final isRemote = mode?.isRemote ?? false;
      final client = ref.read(serverApiClientProvider);

      if (isRemote && client != null) {
        List<dynamic> filesRaw = const <dynamic>[];
        for (int attempt = 0; attempt < 3; attempt++) {
          final response = await client.getTaskOutputFiles(widget.task.id);
          filesRaw = response?['files'] as List<dynamic>? ?? const <dynamic>[];
          if (filesRaw.isNotEmpty) break;
          if (attempt < 2) {
            await Future.delayed(const Duration(seconds: 1));
          }
        }

        final byRun = <String, List<String>>{};

        for (final item in filesRaw) {
          if (item is! Map) continue;
          final runId = (item['timestamp'] as String?)?.trim() ?? '';
          final filename = ((item['filename'] as String?) ?? (item['name'] as String?) ?? '').trim();
          if (runId.isEmpty || filename.isEmpty) continue;
          byRun.putIfAbsent(runId, () => <String>[]).add(filename);
        }

        final runIds = byRun.keys.toList()..sort((a, b) => b.compareTo(a));
        final entries = <_OutputRunDir>[];
        for (final runId in runIds) {
          final files = (byRun[runId] ?? <String>[])..sort();
          entries.add(_OutputRunDir('remote/$runId', _formatRunLabel(runId), files));
        }
        return entries;
      }

      // Slug must match what _buildTaskOutputBundle / TaskOutputFileService use.
      final slug = widget.task.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
      final prefix = slug.isNotEmpty ? '${slug}_' : '';

      // Search both the configured global default dir and the internal fallback.
      final searchDirs = <Directory>{};
      final globalDefault = AppPreferencesService.instance.defaultOutputPath.trim();
      if (globalDefault.isNotEmpty) searchDirs.add(Directory(globalDefault));
      searchDirs.add(await TaskOutputFileService.getOutputDirectory());

      final entries = <_OutputRunDir>[];
      for (final dir in searchDirs) {
        if (!await dir.exists()) continue;
        await for (final entity in dir.list()) {
          if (entity is! Directory) continue;
          final dirName = entity.path.split(Platform.pathSeparator).last;
          if (prefix.isNotEmpty && !dirName.startsWith(prefix)) continue;

          // Label from the timestamp suffix: {slug}_{YYYYMMDD_HHmmss}
          final stamp = prefix.isNotEmpty ? dirName.substring(prefix.length) : dirName;
          final label = _formatRunLabel(stamp);

          // Avoid duplicates (same dir found in both search paths).
          if (entries.any((e) => e.path == entity.path)) continue;

          final fileList = <String>[];
          await for (final f in entity.list()) {
            if (f is File) fileList.add(f.path);
          }
          fileList.sort();
          entries.add(_OutputRunDir(entity.path, label, fileList));
        }
      }

      entries.sort((a, b) => b.path.compareTo(a.path)); // newest first
      return entries;
    } catch (_) {
      return [];
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (widget.isDialog) {
      return _buildContent(context);
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.task.name),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), tooltip: L.of(context).reload, onPressed: () => setState(() => _refreshAsyncData())),
        ],
      ),
      body: _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final l = L.of(context);
    final task = widget.task;
    final agents = task.agents;
    final selectedExec = (agents.isNotEmpty && _selectedExecIndex < agents.length)
        ? agents[_selectedExecIndex]
        : null;

    // Resolve task-id → task name for chain display
    final allTasks = switch (ref.watch(taskListProvider)) {
      AsyncData(:final value) => value,
      _ => const <WorkflowTask>[],
    };
    String resolveTaskName(String? id) {
      if (id == null || id.trim().isEmpty) return '—';
      try {
        return allTasks.firstWhere((t) => t.id == id).name;
      } catch (_) {
        return id;
      }
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (widget.isDialog) ...[
          Row(
            children: [
              Expanded(
                child: Text(task.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              ),
              IconButton(icon: const Icon(Icons.refresh), tooltip: l.reload, onPressed: () => setState(() => _refreshAsyncData())),
              IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
            ],
          ),
          const SizedBox(height: 8),
        ],

        // Status header
        _buildStatusHeader(isDark, l, task),
        const SizedBox(height: 16),

        // ── General ──────────────────────────────────────────────────────────
        _buildSection(
          context,
          icon: Icons.info_outline,
          title: l.detailGeneral,
          children: [
            _buildField(l.detailName, task.name),
            if (task.description != null) _buildField(l.detailDescription, task.description!),
            if (task.agentId != null) _buildField(l.detailAgentId, task.agentId!),
            _buildField(l.detailEnabled, task.enabled ? l.yes : l.no),
            if (task.tags.isNotEmpty) _buildField(l.detailTags, task.tags.join(', ')),
            _buildField(l.detailCreated, _formatDate(task.createdAt)),
            _buildField(l.detailUpdated, _formatDate(task.updatedAt)),
          ],
        ),

        // ── Prompts ──────────────────────────────────────────────────────────
        _buildSection(
          context,
          icon: Icons.edit_note,
          title: l.detailPrompts,
          children: [
            if (agents.isNotEmpty) ...[
              // Agent selector chip list
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: agents.asMap().entries.map((entry) {
                  final idx = entry.key;
                  final exec = entry.value;
                  final selected = _selectedExecIndex == idx;
                  return ChoiceChip(
                    label: Text(exec.name),
                    selected: selected,
                    onSelected: (val) {
                      if (val) {
                        setState(() {
                          _selectedExecIndex = idx;
                        });
                      }
                    },
                  );
                }).toList(),
              ),
              const SizedBox(height: 12),
              const Divider(),
              const SizedBox(height: 8),
            ],
            if (selectedExec != null) ...[
              if (selectedExec.systemPrompt != null && selectedExec.systemPrompt!.trim().isNotEmpty)
                _buildField(l.detailSystemPrompt, selectedExec.systemPrompt!),
              _buildField(l.detailPrompt, selectedExec.prompt),
              if (selectedExec.stopAfterToolCall)
                _buildField(l.stopAfterToolCall, l.yes),
            ] else ...[
              if (task.systemPrompt != null) _buildField(l.detailSystemPrompt, task.systemPrompt!),
              _buildField(l.detailPrompt, task.prompt),
            ],
          ],
        ),

        // ── Schedule + Last/Next Run ──────────────────────────────────────────
        _buildSection(
          context,
          icon: Icons.schedule,
          title: l.detailSchedule,
          children: [
            _buildField(l.detailCron, task.executionPlan.cronExpression, mono: true),
            if (task.executionPlan.scheduleHint != null) _buildField(l.detailHint, task.executionPlan.scheduleHint!),
            _buildField(l.detailMaxRetries, '${task.executionPlan.maxRetries}'),
            _buildField(l.detailRetryOnFailure, task.executionPlan.retryOnFailure ? l.yes : l.no),
            _buildField(l.detailRetryDelay, l.detailRetryDelayValue(task.executionPlan.retryDelayMinutes)),
            _buildField(l.detailExecuteImmediately, task.executionPlan.executeImmediately ? l.yes : l.no),
            const Divider(height: 16),
            _buildField(l.detailLastRun, task.execution.lastRun != null ? _formatDate(task.execution.lastRun!) : l.never),
            _buildField(l.detailNextRun, task.execution.nextRun != null ? _formatDate(task.execution.nextRun!) : l.never),
          ],
        ),

        // ── LLM Override ─────────────────────────────────────────────────────
        if ((selectedExec?.llmConfig ?? task.llmConfig) != null)
          Builder(
            builder: (context) {
              final cfg = (selectedExec?.llmConfig ?? task.llmConfig)!;
              final isLlm2 = cfg.provider == 'llm2';
              // When LLM2 is used, resolve the actual settings so the user can
              // see the effective model/temperature that was (or will be) used.
              final llm2 = isLlm2 ? LlmSettingsService.instance : null;
              final effectiveProvider = isLlm2 ? (llm2!.provider2.label) : cfg.provider;
              final effectiveModel = isLlm2 ? (cfg.model.isNotEmpty ? cfg.model : llm2!.model2) : cfg.model;
              final effectiveTemp = isLlm2 ? (cfg.temperature != 0.7 ? cfg.temperature : llm2!.temperature2) : cfg.temperature;
              final effectiveTokens = isLlm2 ? (cfg.maxTokens != 4096 ? cfg.maxTokens : llm2!.maxTokens2) : cfg.maxTokens;
              final effectiveBaseUrl = isLlm2 ? (cfg.baseUrl ?? (llm2!.baseUrl2.isNotEmpty ? llm2.baseUrl2 : null)) : cfg.baseUrl;
              return _buildSection(
                context,
                icon: Icons.smart_toy,
                title: l.detailLlmOverride,
                children: [
                  _buildField(l.detailProvider, effectiveProvider),
                  _buildField(l.detailModel, effectiveModel.isNotEmpty ? effectiveModel : '—'),
                  if (effectiveBaseUrl != null && effectiveBaseUrl.isNotEmpty) _buildField(l.detailBaseUrl, effectiveBaseUrl),
                  _buildField(l.detailTemperature, '$effectiveTemp'),
                  _buildField(l.detailMaxTokens, '$effectiveTokens'),
                  _buildField(l.detailApiKey, cfg.apiKey != null ? '••••••••' : l.apiKeyNotSet),
                  if (cfg.extraParams.isNotEmpty)
                    _buildField('Extra', cfg.extraParams.entries.map((e) => '${e.key}=${e.value}').join(', ')),
                ],
              );
            },
          ),

        // Task Chaining config
        if (task.chainConfig != null)
          _buildSection(
            context,
            icon: Icons.call_split,
            title: l.detailChainConfig,
            children: [
              if (task.chainConfig!.isSubtask) _buildField(l.detailChainIsSubtask, l.enabled),
              if (task.chainConfig!.triggerCondition != null) _buildField(l.detailChainCondition, task.chainConfig!.triggerCondition!),
              if (task.chainConfig!.onMatchTaskId != null)
                _buildField(l.detailChainOnMatch, resolveTaskName(task.chainConfig!.onMatchTaskId)),
              if (task.chainConfig!.onNoMatchTaskId != null)
                _buildField(l.detailChainOnNoMatch, resolveTaskName(task.chainConfig!.onNoMatchTaskId)),
            ],
          ),

        // Built-in MCP Tools
        if ((selectedExec?.internalMcps ?? task.internalMcps).isNotEmpty)
          _buildSection(
            context,
            icon: Icons.dns,
            title: l.detailBuiltInTools((selectedExec?.internalMcps ?? task.internalMcps).where((m) => m.enabled).length),
            children: (selectedExec?.internalMcps ?? task.internalMcps).map((m) => _buildField(m.label ?? m.mcpType, m.enabled ? l.enabled : l.disabled)).toList(),
          ),

        // External MCP Tools
        if ((selectedExec?.mcpTools ?? task.mcpTools).isNotEmpty)
          _buildSection(
            context,
            icon: Icons.extension,
            title: l.detailMcpTools((selectedExec?.mcpTools ?? task.mcpTools).length),
            children: (selectedExec?.mcpTools ?? task.mcpTools).map((t) => _buildMcpToolItem(context, t)).toList(),
          ),

        // Providers
        if (task.providers.hasAnyProvider)
          _buildSection(
            context,
            icon: Icons.cloud,
            title: l.detailProviders,
            children: [
              if (task.providers.email != null)
                _buildField(l.detailEmail, '${task.providers.email!.type} — ${task.providers.email!.authData.email ?? l.configured}'),
              if (task.providers.webSearch != null)
                _buildField(
                  l.detailWebSearch,
                  '${task.providers.webSearch!.type} (${l.webSearchMaxResults(task.providers.webSearch!.maxResults)})',
                ),
            ],
          ),

        // Agent Output & Notifications
        if (selectedExec != null && selectedExec.notification.hasAnyChannel)
          _buildSection(
            context,
            icon: Icons.notifications,
            title: '${selectedExec.name} Output & Notifications',
            children: _buildNotificationFields(l, selectedExec.notification),
          ),

        // Global Output & Notifications
        if (task.agents.length > 1 && task.notification.hasAnyChannel)
          _buildSection(
            context,
            icon: Icons.notifications_active,
            title: 'Global Output & Notifications',
            children: _buildNotificationFields(l, task.notification),
          ),

        // ── Run Statistics ───────────────────────────────────────────────────
        if (task.execution.history.isNotEmpty) _buildRunStatsSection(context, task),

        // ── Raw Output ───────────────────────────────────────────────────────
        _buildRawOutputSection(context, task),

        // ── Output User ──────────────────────────────────────────────────────
        _buildOutputUserSection(context, task),

        // ── Output Files ─────────────────────────────────────────────────────
        _buildOutputFilesSection(context),

        // ── Scheduler Log ────────────────────────────────────────────────────
        _buildSchedulerLogSection(context),

        const SizedBox(height: 40),
      ],
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Run statistics section
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildRunStatsSection(BuildContext context, WorkflowTask task) {
    final record = task.execution.history.first;
    final theme = Theme.of(context);

    String fmt(int? n) {
      if (n == null) return '—';
      if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
      if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
      return n.toString();
    }

    String dur(int? ms) {
      if (ms == null) return '—';
      if (ms >= 60000) return '${(ms / 60000).toStringAsFixed(1)} min';
      if (ms >= 1000) return '${(ms / 1000).toStringAsFixed(1)} s';
      return '$ms ms';
    }

    String usd(double? n) {
      if (n == null) return '—';
      if (n > 0 && n < 0.01) return '\$${n.toStringAsFixed(4)}';
      return '\$${n.toStringAsFixed(2)}';
    }

    final hasStats =
        record.tokensUsed != null ||
        record.sentChars != null ||
        record.toolCallCount != null ||
        record.messageCount != null ||
        record.lastRequestCostUsd != null ||
        record.sessionCostUsd != null;

    return _buildExpandableSection(
      context,
      icon: Icons.bar_chart_rounded,
      title: 'Last Run Statistics',
      initiallyExpanded: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _buildStatTile(
                  context,
                  icon: Icons.schedule_outlined,
                  label: 'Duration',
                  value: dur(record.durationMs),
                  color: theme.colorScheme.primary,
                ),
              ),
              Expanded(
                child: _buildStatTile(
                  context,
                  icon: record.success ? Icons.check_circle_outline : Icons.error_outline,
                  label: 'Status',
                  value: record.success ? 'Success' : 'Failed',
                  color: record.success ? Colors.green : theme.colorScheme.error,
                ),
              ),
            ],
          ),
          if (hasStats) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _buildStatTile(
                    context,
                    icon: Icons.blur_on_rounded,
                    label: 'Tokens used',
                    value: fmt(record.tokensUsed),
                    color: theme.colorScheme.secondary,
                  ),
                ),
                Expanded(
                  child: _buildStatTile(
                    context,
                    icon: Icons.upload_outlined,
                    label: 'Chars sent',
                    value: fmt(record.sentChars),
                    color: theme.colorScheme.tertiary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _buildStatTile(
                    context,
                    icon: Icons.build_outlined,
                    label: 'Tool calls',
                    value: fmt(record.toolCallCount),
                    color: theme.colorScheme.primary,
                  ),
                ),
                Expanded(
                  child: _buildStatTile(
                    context,
                    icon: Icons.chat_outlined,
                    label: 'Messages',
                    value: fmt(record.messageCount),
                    color: theme.colorScheme.secondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _buildStatTile(
                    context,
                    icon: Icons.attach_money_rounded,
                    label: 'Last price',
                    value: usd(record.lastRequestCostUsd),
                    color: theme.colorScheme.tertiary,
                  ),
                ),
                Expanded(
                  child: _buildStatTile(
                    context,
                    icon: Icons.account_balance_wallet_outlined,
                    label: 'Total price',
                    value: usd(record.sessionCostUsd),
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
            ),
          ] else
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                'No detailed statistics for this run (stats collected from newer runs).',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStatTile(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withAlpha(20),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withAlpha(60)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color),
                ),
                Text(label, style: TextStyle(fontSize: 10, color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // New output/log sections
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildRawOutputSection(BuildContext context, WorkflowTask task) {
    final l = L.of(context);
    final rawOutput = task.execution.history.isNotEmpty ? task.execution.history.first.rawOutput : null;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return _buildExpandableSection(
      context,
      icon: Icons.terminal,
      title: l.sectionRawOutput,
      initiallyExpanded: false,
      child: rawOutput != null && rawOutput.isNotEmpty
          ? Stack(
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 340),
                  child: SingleChildScrollView(
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(10, 10, 32, 10),
                      decoration: BoxDecoration(color: isDark ? Colors.black54 : Colors.grey[100], borderRadius: BorderRadius.circular(6)),
                      child: SelectableText(rawOutput, style: const TextStyle(fontSize: 11, fontFamily: 'monospace', height: 1.4)),
                    ),
                  ),
                ),
                Positioned(top: 4, right: 4, child: _copyButton(context, rawOutput)),
              ],
            )
          : Text(l.noRawOutput, style: TextStyle(fontSize: 13, color: Colors.grey[600])),
    );
  }

  Widget _buildOutputUserSection(BuildContext context, WorkflowTask task) {
    final l = L.of(context);
    final record = task.execution.history.isNotEmpty ? task.execution.history.first : null;
    final rawOutput = record?.rawOutput;
    final result = record?.result;
    final error = record?.error;

    // Parse rawOutput into chat steps; fall back to plain result/error text
    final steps = (rawOutput != null && rawOutput.isNotEmpty) ? _parseConversationSteps(rawOutput, result) : <_ConvStep>[];

    Widget child;
    if (steps.isNotEmpty) {
      child = ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 400),
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: steps.map((s) => _buildConvStep(context, s)).toList()),
        ),
      );
    } else if (result != null && result.isNotEmpty) {
      final displayResult = _prettyPrintIfJson(result);
      final isJson = displayResult != result; // was reformatted
      child = ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 300),
        child: SingleChildScrollView(
          child: SelectableText(displayResult, style: TextStyle(fontSize: 13, height: 1.5, fontFamily: isJson ? 'monospace' : null)),
        ),
      );
    } else if (error != null && error.isNotEmpty) {
      final cleanError = _extractCleanError(error);
      child = Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppTheme.error.withAlpha(20),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppTheme.error.withAlpha(80)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: AppTheme.error, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: SelectableText(cleanError, style: TextStyle(fontSize: 13, height: 1.5, color: AppTheme.error)),
            ),
          ],
        ),
      );
    } else {
      child = Text(l.noOutputUser, style: TextStyle(fontSize: 13, color: Colors.grey[600]));
    }

    return _buildExpandableSection(context, icon: Icons.person_outline, title: l.sectionOutputUser, initiallyExpanded: true, child: child);
  }

  Widget _buildOutputFilesSection(BuildContext context) {
    final l = L.of(context);
    return _buildExpandableSection(
      context,
      icon: Icons.folder_open,
      title: l.sectionOutputFiles,
      initiallyExpanded: true,
      child: FutureBuilder<List<_OutputRunDir>>(
        future: _outputFilesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator(strokeWidth: 2)),
            );
          }
          final runs = snapshot.data ?? [];
          if (runs.isEmpty) {
            return Text(l.noOutputFiles, style: TextStyle(fontSize: 13, color: Colors.grey[600]));
          }
          final visibleRuns = runs.take(5).toList();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: visibleRuns.map((run) => _buildOutputRunDir(context, run)).toList(),
          );
        },
      ),
    );
  }

  Widget _buildOutputRunDir(BuildContext context, _OutputRunDir run) {
    final l = L.of(context);
    final isRemote = ref.watch(serverModeProvider).value?.isRemote ?? false;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.outputFileRunDir(run.label), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
          const SizedBox(height: 4),
          if (run.files.isEmpty)
            Text(l.noOutputFiles, style: TextStyle(fontSize: 12, color: Colors.grey[500]))
          else
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: run.files.map((pathOrName) {
                final name = _basename(pathOrName);
                return ActionChip(
                  avatar: const Icon(Icons.insert_drive_file, size: 16),
                  label: Text(name, style: const TextStyle(fontSize: 12)),
                  tooltip: pathOrName,
                  onPressed: () async {
                    if (isRemote) {
                      await _openRemoteOutputFile(context, run, pathOrName);
                    } else {
                      await _openPath(context, pathOrName);
                    }
                  },
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                );
              }).toList(),
            ),
          const Divider(height: 12),
        ],
      ),
    );
  }

  Widget _buildSchedulerLogSection(BuildContext context) {
    final l = L.of(context);
    return _buildExpandableSection(
      context,
      icon: Icons.history_toggle_off,
      title: l.sectionSchedulerLog,
      initiallyExpanded: false,
      child: FutureBuilder<List<SchedulerLogEntry>>(
        future: _schedulerLogFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator(strokeWidth: 2)),
            );
          }
          final entries = snapshot.data ?? [];
          if (entries.isEmpty) {
            return Text(l.noSchedulerLog, style: TextStyle(fontSize: 13, color: Colors.grey[600]));
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: entries.map((e) => _buildSchedulerLogEntry(context, e)).toList(),
          );
        },
      ),
    );
  }

  Widget _buildSchedulerLogEntry(BuildContext context, SchedulerLogEntry entry) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final Color eventColor;
    switch (entry.event) {
      case SchedulerEventType.completed:
        eventColor = AppTheme.success;
      case SchedulerEventType.failed:
        eventColor = AppTheme.error;
      case SchedulerEventType.skipped:
        eventColor = Colors.orange;
      case SchedulerEventType.started:
        eventColor = AppTheme.primaryBlue;
      default:
        eventColor = isDark ? Colors.grey[400]! : Colors.grey[600]!;
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 72,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(color: eventColor.withAlpha(30), borderRadius: BorderRadius.circular(4)),
            child: Text(
              entry.eventLabel,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: eventColor),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_formatDate(entry.timestamp), style: TextStyle(fontSize: 11, color: isDark ? Colors.grey[400] : Colors.grey[600])),
                if (entry.detail != null)
                  Text(entry.detail!, style: TextStyle(fontSize: 12, color: isDark ? Colors.grey[300] : Colors.grey[700])),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Section shell helpers
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildSection(BuildContext context, {required IconData icon, required String title, required List<Widget> children}) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ExpansionTile(
        leading: Icon(icon, color: AppTheme.primaryBlue),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        initiallyExpanded: true,
        dense: true,
        minTileHeight: 44,
        expandedAlignment: Alignment.centerLeft,
        tilePadding: const EdgeInsets.symmetric(horizontal: 14),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
          ),
        ],
      ),
    );
  }

  Widget _buildField(String label, String value, {bool mono = false, bool isError = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: isError ? AppTheme.error : AppTheme.primaryBlue,
              fontSize: 12,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 4),
          SelectableText(
            value,
            style: TextStyle(fontSize: 13, fontFamily: mono ? 'monospace' : null, color: isError ? AppTheme.error : null),
          ),
        ],
      ),
    );
  }

  Widget _buildExpandableSection(
    BuildContext context, {
    required IconData icon,
    required String title,
    required Widget child,
    bool initiallyExpanded = true,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ExpansionTile(
        leading: Icon(icon, color: AppTheme.primaryBlue),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        initiallyExpanded: initiallyExpanded,
        dense: true,
        minTileHeight: 44,
        expandedAlignment: Alignment.centerLeft,
        tilePadding: const EdgeInsets.symmetric(horizontal: 14),
        children: [Padding(padding: const EdgeInsets.fromLTRB(14, 0, 14, 12), child: child)],
      ),
    );
  }

  Widget _copyButton(BuildContext context, String text) {
    final l = L.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () async {
          await Clipboard.setData(ClipboardData(text: text));
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.copiedToClipboard), duration: const Duration(seconds: 2)));
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(Icons.copy, size: 16, color: Colors.grey[500]),
        ),
      ),
    );
  }

  Widget _buildStatusHeader(bool isDark, L l, WorkflowTask task) {
    final hasError = task.execution.lastError != null && task.execution.consecutiveFailures > 0;
    final hasRun = task.execution.runCount > 0;
    Color statusColor;
    String statusText;
    IconData statusIcon;

    if (!task.enabled) {
      statusColor = Colors.grey;
      statusText = l.statusDisabled;
      statusIcon = Icons.pause_circle;
    } else if (hasError) {
      statusColor = AppTheme.error;
      statusText = l.statusFailedCount(task.execution.consecutiveFailures);
      statusIcon = Icons.error;
    } else if (hasRun) {
      statusColor = AppTheme.success;
      statusText = l.statusOk(task.execution.runCount);
      statusIcon = Icons.check_circle;
    } else {
      statusColor = AppTheme.warning;
      statusText = l.statusPendingNeverRun;
      statusIcon = Icons.schedule;
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: statusColor.withAlpha(30),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: statusColor.withAlpha(80)),
      ),
      child: Row(
        children: [
          Icon(statusIcon, color: statusColor, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  statusText,
                  style: TextStyle(fontWeight: FontWeight.bold, color: statusColor),
                ),
                if (task.executionPlan.scheduleHint != null)
                  Text(
                    task.executionPlan.scheduleHint!,
                    style: TextStyle(fontSize: 13, color: isDark ? Colors.grey[400] : Colors.grey[600]),
                  ),
              ],
            ),
          ),
          Text(
            task.executionPlan.cronExpression,
            style: TextStyle(fontFamily: 'monospace', fontSize: 13, color: isDark ? Colors.grey[400] : Colors.grey[600]),
          ),
        ],
      ),
    );
  }

  Widget _buildMcpToolItem(BuildContext context, McpToolConfig tool) {
    final l = L.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tool.name ?? tool.serverUrl, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          Text(
            '${tool.serverUrl} · tools: ${tool.enabledTools?.isEmpty ?? true ? l.allTools : tool.enabledTools!.join(", ")}',
            style: TextStyle(fontSize: 12, color: Colors.grey[500]),
          ),
        ],
      ),
    );
  }

  Future<void> _openPath(BuildContext context, String path) async {
    final l = L.of(context);
    try {
      final exists = await FileSystemEntity.type(path) != FileSystemEntityType.notFound;
      if (!exists) {
        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.pathNotFound)));
        return;
      }
      // Detect MIME type so Android can show the correct app-chooser
      // (e.g. "application/zip" for .zip files — without it Android's
      // ACTION_VIEW intent fails with "No app found").
      final mimeType = lookupMimeType(path);
      final result = await OpenFile.open(path, type: mimeType);
      if (result.type != ResultType.done && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.message)));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.openFailed(e.toString()))));
      }
    }
  }

  Future<void> _openRemoteOutputFile(BuildContext context, _OutputRunDir run, String pathOrName) async {
    final l = L.of(context);
    final client = ref.read(serverApiClientProvider);
    if (client == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Server is not connected')));
      }
      return;
    }

    try {
      final refData = _parseRemoteFileRef(run, pathOrName);
      final bytes = await client.downloadTaskOutputFile(widget.task.id, refData.$1, refData.$2);
      final mimeType = lookupMimeType(refData.$2, headerBytes: bytes.take(32).toList()) ?? 'application/octet-stream';

      if (_isTextLikeFile(refData.$2, mimeType)) {
        final text = utf8.decode(bytes, allowMalformed: true);
        final prettyText = refData.$2.toLowerCase().endsWith('.json') ? _prettyPrintIfJson(text) : text;
        if (!context.mounted) return;
        _showTextPreviewDialog(context, title: _basename(refData.$2), content: prettyText);
        return;
      }

      final safeName = _basename(refData.$2).replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      final outPath = '${Directory.systemTemp.path}${Platform.pathSeparator}${DateTime.now().millisecondsSinceEpoch}_$safeName';
      final outFile = File(outPath);
      await outFile.writeAsBytes(bytes, flush: true);

      final openResult = await OpenFile.open(outPath, type: mimeType);
      if (openResult.type != ResultType.done && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(openResult.message)));
      }
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.openFailed(e.toString()))));
    }
  }

  (String, String) _parseRemoteFileRef(_OutputRunDir run, String pathOrName) {
    final normalized = pathOrName.replaceAll('\\', '/').trim();
    final runId = run.path.replaceFirst('remote/', '').trim();

    if (normalized.startsWith('$runId/')) {
      return (runId, normalized.substring(runId.length + 1));
    }

    final slashIndex = normalized.indexOf('/');
    if (slashIndex > 0) {
      return (normalized.substring(0, slashIndex), normalized.substring(slashIndex + 1));
    }

    return (runId, normalized);
  }

  bool _isTextLikeFile(String fileName, String mimeType) {
    final lower = fileName.toLowerCase();
    if (mimeType.startsWith('text/')) return true;
    if (mimeType.contains('json') || mimeType.contains('xml') || mimeType.contains('javascript')) return true;
    return lower.endsWith('.json') ||
        lower.endsWith('.txt') ||
        lower.endsWith('.log') ||
        lower.endsWith('.md') ||
        lower.endsWith('.csv') ||
        lower.endsWith('.html') ||
        lower.endsWith('.htm');
  }

  void _showTextPreviewDialog(BuildContext context, {required String title, required String content}) {
    showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 640,
            child: SingleChildScrollView(
              child: SelectableText(content, style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.35)),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: content));
                if (context.mounted) {
                  Navigator.of(context).pop();
                }
              },
              child: const Text('Copy'),
            ),
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
          ],
        );
      },
    );
  }

  String _formatDate(DateTime dt) {
    final local = dt.isUtc ? dt.toLocal() : dt;
    return '${local.day.toString().padLeft(2, '0')}.${local.month.toString().padLeft(2, '0')}.${local.year} '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  String _formatRunLabel(String stamp) {
    try {
      // stamp format: YYYYMMDD_HHmmss or YYYYMMDDHHmmss
      final compact = stamp.replaceAll('_', '');
      if (compact.length < 12) return stamp;
      final year = compact.substring(0, 4);
      final month = compact.substring(4, 6);
      final day = compact.substring(6, 8);
      final hour = compact.substring(8, 10);
      final min = compact.substring(10, 12);
      return '$day.$month.$year $hour:$min';
    } catch (_) {
      return stamp;
    }
  }

  String _basename(String value) {
    final normalized = value.replaceAll('\\', '/');
    final parts = normalized.split('/');
    return parts.isEmpty ? value : parts.last;
  }

  /// Extracts a human-readable message from a potentially JSON-formatted error.
  String _extractCleanError(String error) {
    final t = error.trim();
    if (t.startsWith('{') || t.startsWith('[')) {
      try {
        final decoded = jsonDecode(t);
        if (decoded is Map) {
          final msg = decoded['error'] ?? decoded['message'] ?? decoded['detail'];
          if (msg != null) {
            final msgStr = msg.toString();
            final re = RegExp(r'message:\s*([^,}]+)');
            final m = re.firstMatch(msgStr);
            if (m != null) return m.group(1)?.trim() ?? msgStr;
            return msgStr;
          }
        }
      } catch (_) {
        final re = RegExp(r'"error"\s*:\s*"([^"]+)"');
        final m = re.firstMatch(t);
        if (m != null) return m.group(1) ?? error;
      }
      return error;
    }
    return t;
  }

  /// If [text] is a compact single-line JSON object/array, returns an indented
  /// human-readable version. Otherwise returns [text] unchanged.
  String _prettyPrintIfJson(String text) {
    final trimmed = text.trim();
    if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return text;
    if (trimmed.contains('\n')) return text; // already multi-line
    try {
      final decoded = jsonDecode(trimmed);
      const encoder = JsonEncoder.withIndent('  ');
      return encoder.convert(decoded);
    } catch (_) {
      return text;
    }
  }

  // ─── Conversation parser ────────────────────────────────────────────────────────────

  /// Parse the rawOutput markdown log into a list of conversation steps.
  /// [finalResult] is appended as the final LLM response if not already present.
  List<_ConvStep> _parseConversationSteps(String rawOutput, String? finalResult) {
    final steps = <_ConvStep>[];
    final lines = rawOutput.split('\n');
    int i = 0;
    String? timestamp, provider, model;
    String? pendingPrompt;
    bool foundFinalResponse = false;

    while (i < lines.length) {
      final line = lines[i];

      if (line.startsWith('**Timestamp:**')) {
        timestamp = line.replaceFirst('**Timestamp:**', '').trim();
        i++;
        continue;
      }
      if (line.startsWith('**Provider:**')) {
        provider = line.replaceFirst('**Provider:**', '').trim();
        i++;
        continue;
      }
      if (line.startsWith('**Model:**')) {
        model = line.replaceFirst('**Model:**', '').trim();
        i++;
        continue;
      }

      if (line.trim() == '### Prompt') {
        i++;
        // skip opening ```
        while (i < lines.length && lines[i].trim() != '```') {
          i++;
        }
        i++;
        final buf = StringBuffer();
        while (i < lines.length && lines[i].trim() != '```') {
          buf.writeln(lines[i]);
          i++;
        }
        pendingPrompt = buf.toString().trim();
        i++;
        continue;
      }

      if (line.startsWith('**Initial LLM Response:**') || line.startsWith('**Final Response:**')) {
        final isFinal = line.startsWith('**Final Response:**');
        if (isFinal) foundFinalResponse = true;
        i++;
        final buf = StringBuffer();
        while (i < lines.length) {
          final cur = lines[i];
          if (cur.startsWith('**') || cur.trim().startsWith('###') || cur.trim() == 'Function Calls:') break;
          if (cur.trim().isNotEmpty) buf.writeln(cur);
          i++;
        }
        final text = buf.toString().trim();
        // Filter out the placeholder text
        if (text.isNotEmpty && text != 'Calling tools to retrieve the requested information...') {
          steps.add(_ConvStep(_ConvStepType.llmText, text));
        }
        continue;
      }

      if (line.trim() == 'Function Calls:') {
        i++;
        while (i < lines.length && lines[i].trim().startsWith('- `')) {
          final m = RegExp(r'- `([^`]+)`').firstMatch(lines[i]);
          if (m != null) steps.add(_ConvStep(_ConvStepType.toolCall, m.group(1)!));
          i++;
        }
        continue;
      }

      if (line.startsWith('**Function Result (Iteration')) {
        final m = RegExp(r'`([^`]+)`\s*$').firstMatch(line);
        final toolName = m?.group(1) ?? 'tool';
        i++;
        while (i < lines.length && lines[i].trim() != '```') {
          i++;
        }
        i++; // skip opening ```
        // Collect all content lines inside the code block
        final contentLines = <String>[];
        while (i < lines.length && lines[i].trim() != '```') {
          contentLines.add(lines[i]);
          i++;
        }
        // Pretty-print JSON if one-liner, then take first 6 non-empty lines as preview
        final rawContent = contentLines.join('\n').trim();
        final pretty = _prettyPrintIfJson(rawContent);
        final previewLines = pretty.split('\n').where((l) => l.trim().isNotEmpty).take(6).join('\n');
        final preview = previewLines.length > 300 ? '${previewLines.substring(0, 300)}…' : previewLines;
        steps.add(_ConvStep(_ConvStepType.toolResult, preview.isEmpty ? '(empty)' : preview, label: toolName));
        i++;
        continue;
      }

      i++;
    }

    // Prepend system info
    final infoLines = <String>[];
    if (timestamp != null) infoLines.add(timestamp);
    if (provider != null && model != null) infoLines.add('$provider \u00b7 $model');
    if (infoLines.isNotEmpty) {
      steps.insert(0, _ConvStep(_ConvStepType.systemInfo, infoLines.join('  |  ')));
    }
    // Insert user prompt after system info
    if (pendingPrompt != null) {
      steps.insert(infoLines.isNotEmpty ? 1 : 0, _ConvStep(_ConvStepType.userPrompt, pendingPrompt));
    }

    // If rawOutput didn't capture the final response but we have the result text, append it
    if (!foundFinalResponse && finalResult != null && finalResult.trim().isNotEmpty) {
      steps.add(_ConvStep(_ConvStepType.llmText, _prettyPrintIfJson(finalResult.trim())));
    }

    return steps;
  }

  Widget _buildConvStep(BuildContext context, _ConvStep step) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    switch (step.type) {
      case _ConvStepType.systemInfo:
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            step.text,
            style: TextStyle(fontSize: 11, color: Colors.grey[isDark ? 400 : 500], fontFamily: 'monospace'),
          ),
        );

      case _ConvStepType.userPrompt:
        return _convRow(
          icon: Icons.person,
          iconColor: AppTheme.primaryBlue,
          bgColor: AppTheme.primaryBlue.withAlpha(15),
          borderColor: AppTheme.primaryBlue.withAlpha(60),
          text: step.text,
          isDark: isDark,
          maxLines: 4,
        );

      case _ConvStepType.toolCall:
        return _convRow(icon: Icons.build_outlined, iconColor: Colors.orange, text: '→ ${step.text}', isDark: isDark, compact: true);

      case _ConvStepType.toolResult:
        return _convRow(
          icon: Icons.key,
          iconColor: Colors.teal,
          text: step.label != null ? '${step.label}: ${step.text}' : step.text,
          isDark: isDark,
          compact: true,
          mono: true,
        );

      case _ConvStepType.llmText:
        return _convRow(
          icon: Icons.smart_toy,
          iconColor: AppTheme.success,
          bgColor: isDark ? Colors.black38 : Colors.grey[50],
          text: step.text,
          isDark: isDark,
        );
    }
  }

  Widget _convRow({
    required IconData icon,
    required Color iconColor,
    Color? bgColor,
    Color? borderColor,
    required String text,
    required bool isDark,
    bool compact = false,
    bool mono = false,
    int? maxLines,
  }) {
    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 4 : 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: iconColor),
          const SizedBox(width: 6),
          Expanded(
            child: Container(
              padding: compact ? const EdgeInsets.symmetric(vertical: 2) : const EdgeInsets.all(8),
              decoration: bgColor != null
                  ? BoxDecoration(
                      color: bgColor,
                      borderRadius: BorderRadius.circular(6),
                      border: borderColor != null ? Border.all(color: borderColor) : null,
                    )
                  : null,
              child: SelectableText(
                text,
                maxLines: maxLines,
                style: TextStyle(
                  fontSize: compact ? 11 : 13,
                  height: 1.4,
                  fontFamily: mono ? 'monospace' : null,
                  color: compact ? (isDark ? Colors.grey[300] : Colors.grey[700]) : null,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildNotificationFields(L l, TaskNotification notification) {
    return [
      if (notification.email != null) ...[
        _buildField(l.detailEmailTo, notification.email!.recipients.join(', ')),
        if (notification.email!.subject != null) _buildField(l.detailSubject, notification.email!.subject!),
        _buildField(l.detailSendWhen, notification.email!.sendCondition),
      ],
      if (notification.push != null) ...[
        _buildField(l.detailPush, notification.push!.enabled ? l.enabled : l.disabled),
        if (notification.push!.title != null) _buildField(l.detailPushTitle, notification.push!.title!),
      ],
      if (notification.download != null)
        _buildField(l.detailDownload, notification.download!.downloadPath ?? l.detailDefaultDownloads),
      if (notification.sftpOutput != null)
        _buildField(
          l.outputTypeSftp,
          '${notification.sftpOutput!.useConfiguredSshServer ? l.sftpUseConfiguredSshServer : notification.sftpOutput!.host}  →  ${notification.sftpOutput!.remotePath}',
        ),
      if (notification.upload != null)
        _buildField(
          l.detailUpload,
          [
            if (notification.upload!.googleDrive != null) 'Google Drive',
            if (notification.upload!.oneDrive != null) 'OneDrive',
            if (notification.upload!.sftp != null) 'SFTP',
          ].join(', '),
        ),
    ];
  }
}
