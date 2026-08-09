import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:tealkit/providers/sidebar_provider.dart';
import 'package:tealkit/widgets/global_agent_stats_widget.dart';
import 'package:tealkit/widgets/particle_background.dart';
import '../l10n/app_localizations.dart';
import 'package:uuid/uuid.dart';
import '../config/app_theme.dart';
import '../models/workflow_task.dart';
import '../services/app_logger.dart';
import '../models/mcp_models.dart';
import '../providers/active_task_provider.dart';
import '../providers/database_providers.dart';
import '../providers/server_mode_provider.dart';
import '../services/app_preferences_service.dart';
import '../services/email_delivery_service.dart';
import '../services/messaging_delivery_service.dart';
import '../services/scheduler_service.dart';
import '../services/server_api_client.dart';
import '../services/task_runner_service.dart';

import 'server_settings_screen.dart';
import 'workflow_edit_screen.dart';
import 'workflow_detail_screen.dart';
import '../services/workflow_export_service.dart';
import 'visual_builder_screen.dart';
import 'startup_wizard_screen.dart';
import '../widgets/example_picker_dialog.dart';
import '../widgets/server_status_banner.dart';

/// Task list screen — local-only, no server required.
/// Inspired by thiesai TaskSchedulerScreen but uses Sembast instead of HTTP API.
class WorkflowListScreen extends ConsumerStatefulWidget {
  const WorkflowListScreen({super.key});

  @override
  ConsumerState<WorkflowListScreen> createState() => _TaskListScreenState();
}

class _TaskListScreenState extends ConsumerState<WorkflowListScreen> {
  final _searchController = TextEditingController();
  final _horizontalScrollController =
      ScrollController(); // legacy, keep for compat
  late final ScrollController _headerHorzCtrl;
  late final ScrollController _bodyHorzCtrl;

  String _searchQuery = '';
  int _sortColumnIndex = 0; // 0=name, 1=updated
  bool _sortAscending = true;
  bool _scheduledOnly = false;
  final Set<String> _runningTaskIds = <String>{};
  Timer? _refreshTimer;
  // Android background-scheduling permission state
  bool _batteryOptimised = false; // true = NOT exempted (bad)
  bool _exactAlarmDenied = false; // true = SCHEDULE_EXACT_ALARM not granted
  bool _permissionsChecked = false;

  @override
  void initState() {
    super.initState();
    // Refresh task list whenever this screen is first shown (e.g. after vault restore).
    // Double post-frame defers past TickerMode route-transition to avoid Riverpod
    // "setState() or markNeedsBuild() called during build" on UncontrolledProviderScope.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.invalidate(taskListProvider);
      });
    });
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.toLowerCase();
      });
    });
    // Periodic refresh timer (runs every 6 seconds to update run statuses)
    _refreshTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (mounted) {
        final modeAsync = ref.read(serverModeProvider);
        final isRemote = modeAsync.value?.isRemote ?? false;
        if (isRemote) {
          ref.invalidate(taskListProvider);
        }
      }
    });
    // Linked horizontal scroll controllers: header stays in sync with body
    _headerHorzCtrl = ScrollController();
    _bodyHorzCtrl = ScrollController();
    _bodyHorzCtrl.addListener(() {
      if (_headerHorzCtrl.hasClients &&
          _headerHorzCtrl.offset != _bodyHorzCtrl.offset) {
        _headerHorzCtrl.jumpTo(_bodyHorzCtrl.offset);
      }
    });
    _headerHorzCtrl.addListener(() {
      if (_bodyHorzCtrl.hasClients &&
          _bodyHorzCtrl.offset != _headerHorzCtrl.offset) {
        _bodyHorzCtrl.jumpTo(_headerHorzCtrl.offset);
      }
    });
    if (!kIsWeb && Platform.isAndroid) {
      _checkSchedulerPermissions();
    }
  }

  Future<void> _checkSchedulerPermissions() async {
    final batteryStatus = await Permission.ignoreBatteryOptimizations.status;
    // ignoreBatteryOptimizations.isGranted means the app IS exempted — no warning needed.
    // .isDenied means optimisation is still active — background alarms may be killed.
    final batteryOptimised = batteryStatus.isDenied;

    bool exactAlarmDenied = false;
    // scheduleExactAlarm is only meaningful on Android 12+ (API 31+).
    try {
      final alarmStatus = await Permission.scheduleExactAlarm.status;
      exactAlarmDenied = alarmStatus.isDenied;
    } catch (_) {
      // Permission not available on this API level — ignore
    }

    if (mounted) {
      setState(() {
        _batteryOptimised = batteryOptimised;
        _exactAlarmDenied = exactAlarmDenied;
        _permissionsChecked = true;
      });
    }
  }

  Future<void> _requestBatteryOptimisationExemption() async {
    await Permission.ignoreBatteryOptimizations.request();
    if (mounted) await _checkSchedulerPermissions();
  }

  Future<void> _openAlarmSettings() async {
    await Permission.scheduleExactAlarm.request();
    if (mounted) await _checkSchedulerPermissions();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _searchController.dispose();
    _horizontalScrollController.dispose();
    _headerHorzCtrl.dispose();
    _bodyHorzCtrl.dispose();
    super.dispose();
  }

  /// Returns true when the task has a real cron schedule (not empty / @manual).
  bool _isScheduledTask(WorkflowTask task) {
    final cron = task.executionPlan.cronExpression.trim();
    return cron.isNotEmpty && cron != '@manual';
  }

  List<WorkflowTask> _filterAndSort(List<WorkflowTask> allTasks) {
    var filtered = allTasks;
    if (_searchQuery.isNotEmpty) {
      filtered = filtered
          .where(
            (t) =>
                t.name.toLowerCase().contains(_searchQuery) ||
                (t.description?.toLowerCase().contains(_searchQuery) ??
                    false) ||
                t.prompt.toLowerCase().contains(_searchQuery) ||
                t.tags.any((tag) => tag.toLowerCase().contains(_searchQuery)),
          )
          .toList();
    }
    if (_scheduledOnly) {
      // Keep only tasks with green clock: enabled + has cron schedule
      // Also keep subtasks whose master is enabled+scheduled
      filtered = filtered.where((t) {
        if (_isScheduledTask(t) && t.enabled) return true;
        // Keep subtask if its master is enabled+scheduled
        final cfg = t.chainConfig;
        if (cfg != null && cfg.isSubtask) {
          return allTasks.any(
            (m) =>
                _isScheduledTask(m) &&
                m.enabled &&
                m.chainConfig != null &&
                (m.chainConfig!.onMatchTaskId == t.id ||
                    m.chainConfig!.onNoMatchTaskId == t.id),
          );
        }
        return false;
      }).toList();
    }
    filtered.sort((a, b) {
      int cmp;
      if (_sortColumnIndex == 0) {
        cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      } else {
        cmp = a.updatedAt.compareTo(b.updatedAt);
      }
      return _sortAscending ? cmp : -cmp;
    });
    return filtered;
  }

  void _showSuccess(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: AppTheme.success),
    );
  }

  /// Re-syncs all tasks with the platform scheduler after a save/create/copy.
  Future<void> _resyncScheduler() async {
    final isRemote = ref.read(serverModeProvider).value?.isRemote ?? false;
    if (isRemote) return;
    final tasks = await ref.read(taskDatabaseServiceProvider).getAllTasks();
    await appScheduler.syncAllTasks(tasks);
  }

  Future<void> _browseExamples() async {
    // Free users are limited to 3 tasks.
    final example = await ExamplePickerDialog.show(
      context,
      excludedToolType: 'js_bridge',
    );
    if (example == null || !mounted) return;

    // Build a pre-filled WorkflowTask from the example
    final prefilledTask = WorkflowTask(
      id: const Uuid().v4(),
      name: example.title,
      prompt: example.prompt,
      systemPrompt: example.systemPrompt,
      enabled: false,
      executionPlan: const ExecutionPlan(cronExpression: '@manual'),
      internalMcps: example.tools
          .map(
            (type) => InternalMcpEntry(
              id: const Uuid().v4(),
              mcpType: type,
              label: type,
              enabled: true,
              initParams: const {},
            ),
          )
          .toList(),
    );

    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => WorkflowEditScreen(task: prefilledTask),
      ),
    );
    if (result == true) {
      ref.invalidate(taskListProvider);
      await _resyncScheduler();
    }
  }

  Future<void> _createTask() async {
    // Free users are limited to 3 tasks.
    if (!context.mounted) return;
    final result = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => const WorkflowEditScreen()));
    if (result == true) {
      ref.invalidate(taskListProvider);
      await _resyncScheduler();
    }
  }

  Future<void> _editTask(WorkflowTask task) async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => WorkflowEditScreen(task: task)),
    );
    if (result == true) {
      ref.invalidate(taskListProvider);
      await _resyncScheduler();
    }
  }

  Future<void> _copyTask(WorkflowTask task) async {
    final copy = WorkflowTask(
      id: const Uuid().v4(),
      name: '${task.name} (Copy)',
      description: task.description,
      agentId: task.agentId,
      systemPrompt: task.systemPrompt,
      prompt: task.prompt,
      llmConfig: task.llmConfig,
      enabled: false, // don't auto-enable copies
      executionPlan: task.executionPlan,
      mcpTools: task.mcpTools,
      providers: task.providers,
      notification: task.notification,
      tags: task.tags,
    );
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => WorkflowEditScreen(task: copy)),
    );
    if (result == true) {
      ref.invalidate(taskListProvider);
      await _resyncScheduler();
    }
  }

  void _showDetails(WorkflowTask task) {
    final isMobile = MediaQuery.of(context).size.width < 800;
    if (isMobile) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => WorkflowDetailScreen(task: task)),
      );
    } else {
      showDialog(
        context: context,
        builder: (_) => Dialog(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 800, maxHeight: 800),
            child: WorkflowDetailScreen(task: task, isDialog: true),
          ),
        ),
      );
    }
  }

  Future<void> _deleteTask(WorkflowTask task) async {
    final l = L.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l.deleteTask),
        content: Text(l.deleteTaskConfirm(task.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.error),
            child: Text(l.delete),
          ),
        ],
      ),
    );
    if (confirm == true) {
      try {
        await ref.read(taskListProvider.notifier).deleteTask(task.id);
        final isRemote = ref.read(serverModeProvider).value?.isRemote ?? false;
        if (!isRemote) {
          await appScheduler.cancelTask(task.id);
        }
        if (!mounted) return;
        _showSuccess(l.taskDeleted(task.name));
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Delete failed: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  Future<void> _toggleTask(WorkflowTask task) async {
    final newEnabled = !task.enabled;
    await ref.read(taskListProvider.notifier).toggleTask(task.id, newEnabled);
    final isRemote = ref.read(serverModeProvider).value?.isRemote ?? false;
    if (!isRemote) {
      if (newEnabled) {
        await appScheduler.scheduleTask(task.copyWith(enabled: true));
      } else {
        await appScheduler.cancelTask(task.id);
      }
    }
  }

  /// Opens a live execution-flow dialog for the task (used by the ▶ run button).
  Future<void> _executeTaskWithDialog(WorkflowTask task) async {
    if (_runningTaskIds.contains(task.id)) return;
    setState(() => _runningTaskIds.add(task.id));
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _ExecutionFlowDialog(task: task),
      );
    } finally {
      if (mounted) {
        setState(() => _runningTaskIds.remove(task.id));
        ref.invalidate(taskListProvider);
        try {
          await ref.read(taskListProvider.future);
        } catch (_) {
          // Keep the updated local UI state even if the post-run refresh fails.
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final isMobile = MediaQuery.of(context).size.width < 800;
    final uiStyle = AppPreferencesService.instance.uiStyle;
    final isModern = uiStyle == 'modern';

    final mainContent = Scaffold(
      backgroundColor: isModern ? Colors.transparent : null,
      appBar: AppBar(
        backgroundColor: isModern ? Colors.transparent : null,
        elevation: 0,
        title: Text(l.taskScheduler),
        leading: (isModern && MediaQuery.sizeOf(context).width > 1200)
            ? Consumer(
                builder: (context, ref, _) {
                  final isOpen = ref.watch(sidebarOpenProvider);
                  return IconButton(
                    icon: const Icon(Icons.menu),
                    onPressed: () {
                      ref.read(sidebarOpenProvider.notifier).state = !isOpen;
                    },
                  );
                },
              )
            : null,
        actions: [
          if (isModern && MediaQuery.sizeOf(context).width >= 1000) ...[
            const GlobalAgentStatsWidget(),
            const SizedBox(width: 8),
          ],
          // Server mode indicator + navigation
          Consumer(
            builder: (context, ref, _) {
              final modeAsync = ref.watch(serverModeProvider);
              final isRemote = modeAsync.value?.isRemote ?? false;
              // On mobile, hide the icon in local mode (it's the default — no need to clutter the AppBar)
              if (isMobile && !isRemote) return const SizedBox.shrink();
              return IconButton(
                icon: Icon(isRemote ? Icons.cloud : Icons.cloud_off_outlined),
                tooltip: isRemote
                    ? 'Remote mode — tap to change'
                    : 'Local mode — tap to connect to server',
                color: isRemote ? AppTheme.success : null,
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const ServerSettingsScreen(),
                  ),
                ),
              );
            },
          ),
          if (isMobile) ...[
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (value) async {
                switch (value) {
                  case 'examples':
                    _browseExamples();
                    break;
                  case 'talker_logs':
                    openTalkerScreen(context);
                    break;
                  case 'settings':
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const StartupWizardScreen(),
                      ),
                    );
                    break;
                  case 'refresh':
                    ref.invalidate(taskListProvider);
                    break;
                  case 'import':
                    final serverMode = ref.read(serverModeProvider).value;
                    final isRemote = serverMode?.isRemote ?? false;
                    final serverClient = isRemote
                        ? ref.read(serverApiClientProvider)
                        : null;
                    final res = await WorkflowExportService.importWorkflow(
                      context,
                      ref.read(taskRepositoryProvider),
                      serverClient: serverClient,
                    );
                    if (!mounted) return;
                    if (res.error != null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Import failed: ${res.error}')),
                      );
                    } else if (res.importedTasks != null &&
                        res.importedTasks!.isNotEmpty) {
                      final count = res.importedTasks!.length;
                      final message = count == 1
                          ? 'Workflow "${res.importedTasks!.first.name}" imported successfully.'
                          : 'Successfully imported $count workflows.';
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text(message)));
                      ref.invalidate(taskListProvider);
                    }
                    break;
                  case 'export_all':
                    final res = await WorkflowExportService.exportAllWorkflows(
                      context,
                      ref.read(taskRepositoryProvider),
                    );
                    if (!mounted) return;
                    if (res.error != null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Export failed: ${res.error}')),
                      );
                    } else if (res.count > 0) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            'Successfully exported ${res.count} workflows to Skills.',
                          ),
                        ),
                      );
                    }
                    break;
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'refresh',
                  child: Row(
                    children: [
                      const Icon(Icons.refresh, size: 20),
                      const SizedBox(width: 8),
                      Text(l.reload),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'examples',
                  child: Row(
                    children: [
                      const Icon(Icons.lightbulb_outline, size: 20),
                      const SizedBox(width: 8),
                      Text(l.browseExamples),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'talker_logs',
                  child: Row(
                    children: [
                      Icon(Icons.bug_report_outlined, size: 20),
                      SizedBox(width: 8),
                      Text('Talker Log Monitor'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'export_all',
                  child: Row(
                    children: [
                      Icon(Icons.download_for_offline, size: 20),
                      SizedBox(width: 8),
                      Text('Export Workflows to Skills'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'settings',
                  child: Row(
                    children: [
                      const Icon(Icons.settings, size: 20),
                      const SizedBox(width: 8),
                      Text(l.settings),
                    ],
                  ),
                ),
              ],
            ),
          ] else ...[
            IconButton(
              icon: const Icon(Icons.bug_report_outlined),
              tooltip: 'Talker Log Monitor',
              onPressed: () => openTalkerScreen(context),
            ),
            IconButton(
              icon: const Icon(Icons.lightbulb_outline),
              tooltip: l.browseExamplesTooltip,
              onPressed: _browseExamples,
            ),
            IconButton(
              icon: const Icon(Icons.settings),
              tooltip: l.settings,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const StartupWizardScreen()),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => ref.invalidate(taskListProvider),
              tooltip: l.reload,
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.import_export),
              tooltip: 'Workflow Import/Export',
              onSelected: (value) async {
                if (value == 'export_all') {
                  final res = await WorkflowExportService.exportAllWorkflows(
                    context,
                    ref.read(taskRepositoryProvider),
                  );
                  if (!mounted) return;
                  if (res.error != null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Export failed: ${res.error}')),
                    );
                  } else if (res.count > 0) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Successfully exported ${res.count} workflows to Skills.',
                        ),
                      ),
                    );
                  }
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'export_all',
                  child: Row(
                    children: [
                      Icon(Icons.download_for_offline, size: 20),
                      SizedBox(width: 8),
                      Text('Export Workflows to Skills'),
                    ],
                  ),
                ),
              ],
            ),
          ],
          if (isModern && MediaQuery.sizeOf(context).width < 1000) ...[
            const GlobalAgentStatsWidget(),
          ],
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          const ServerStatusBanner(),
          // Search bar + mobile filter
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: l.searchTasks,
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () => _searchController.clear(),
                            )
                          : null,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                if (isMobile) ...[
                  const SizedBox(width: 8),
                  DropdownButton<bool>(
                    value: _scheduledOnly,
                    underline: const SizedBox(),
                    borderRadius: BorderRadius.circular(8),
                    items: [
                      DropdownMenuItem(
                        value: false,
                        child: Text(
                          l.filterAllTasks,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      DropdownMenuItem(
                        value: true,
                        child: Text(
                          l.filterScheduledOnly,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                    onChanged: (v) =>
                        setState(() => _scheduledOnly = v ?? false),
                  ),
                ] else ...[
                  const SizedBox(width: 8),
                  FilterChip(
                    avatar: Icon(
                      Icons.schedule,
                      size: 16,
                      color: _scheduledOnly ? Colors.white : Colors.teal[300],
                    ),
                    label: Text(
                      l.filterScheduledOnly,
                      style: const TextStyle(fontSize: 12),
                    ),
                    selected: _scheduledOnly,
                    showCheckmark: false,
                    onSelected: (v) => setState(() => _scheduledOnly = v),
                    selectedColor: Colors.teal[700],
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          // Android background-scheduling permission warnings
          if (_permissionsChecked && _batteryOptimised)
            _SchedulerPermissionBanner(
              icon: Icons.battery_alert,
              message:
                  'Battery optimisation is active for TealKit. '
                  'Scheduled tasks may be delayed or skipped when the app is closed. '
                  'Tap to disable battery optimisation for this app.',
              actionLabel: 'Fix now',
              onAction: _requestBatteryOptimisationExemption,
              onDismiss: () => setState(() => _batteryOptimised = false),
            ),
          if (_permissionsChecked && _exactAlarmDenied)
            _SchedulerPermissionBanner(
              icon: Icons.alarm_off,
              message:
                  'Exact alarm permission is not granted. '
                  'Tasks scheduled for a specific time may not fire at the right moment. '
                  'Tap to open alarm settings.',
              actionLabel: 'Grant',
              onAction: _openAlarmSettings,
              onDismiss: () => setState(() => _exactAlarmDenied = false),
            ),
          // Task list
          Expanded(child: _buildBody(isMobile)),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _createTask,
        tooltip: l.newTask,
        backgroundColor: isModern ? const Color(0xFF7C3AED) : null,
        foregroundColor: isModern ? Colors.white : null,
        child: const Icon(Icons.add),
      ),
    );

    if (isModern) {
      return ParticleBackground(child: mainContent);
    }
    return mainContent;
  }

  Widget _buildBody(bool isMobile) {
    final taskListAsync = ref.watch(taskListProvider);

    return taskListAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            Text(L.of(context).failedToLoad(error.toString())),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => ref.invalidate(taskListProvider),
              child: Text(L.of(context).reload),
            ),
          ],
        ),
      ),
      data: (tasks) {
        if (tasks.isEmpty) {
          final l = L.of(context);
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.schedule, size: 64, color: Colors.grey),
                const SizedBox(height: 16),
                Text(l.noTasksYet, style: const TextStyle(fontSize: 18)),
                const SizedBox(height: 8),
                Text(
                  l.createScheduledTask,
                  style: const TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: _createTask,
                  icon: const Icon(Icons.add),
                  label: Text(l.createTask),
                ),
                const SizedBox(height: 12),
                Text(
                  l.orStartFromExample,
                  style: const TextStyle(color: Colors.grey, fontSize: 13),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _browseExamples,
                  icon: const Icon(Icons.lightbulb_outline, size: 18),
                  label: Text(l.browseExamples),
                ),
              ],
            ),
          );
        }

        final filtered = _filterAndSort(tasks);
        if (filtered.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.search_off, size: 48, color: Colors.grey),
                const SizedBox(height: 16),
                Text(L.of(context).noMatchingTasks),
              ],
            ),
          );
        }

        return isMobile
            ? _buildMobileList(filtered)
            : _buildDesktopTable(filtered);
      },
    );
  }

  // ─── Mobile: Card list ───────────────────────────────

  Widget _buildMobileList(List<WorkflowTask> tasks) {
    // Build id→task lookup and ordered/grouped rows.
    final taskById = {for (final t in tasks) t.id: t};
    final rows = _buildOrderedTaskRows(tasks);

    return ListView.builder(
      padding: const EdgeInsets.only(left: 8, right: 8, top: 4, bottom: 100),
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final r = rows[index];
        return _buildTaskCard(
          r.task,
          masterTask: r.masterTask,
          taskById: taskById,
        );
      },
    );
  }

  Widget _buildTaskCard(
    WorkflowTask task, {
    WorkflowTask? masterTask,
    Map<String, WorkflowTask>? taskById,
  }) {
    final l = L.of(context);
    final lastRun = task.execution.lastRun;
    final nextRun = task.execution.nextRun;
    final isScheduled = _isScheduledTask(task);
    final latestRunRecord = task.execution.history.isNotEmpty
        ? task.execution.history.first
        : null;
    final lastCostUsd = latestRunRecord?.lastRequestCostUsd;
    final totalCostUsd = latestRunRecord?.sessionCostUsd;
    final hasCostStats = lastCostUsd != null || totalCostUsd != null;

    final isMasterWithChain =
        masterTask == null && (task.chainConfig?.hasChaining ?? false);
    final isSubtask = masterTask != null;

    // Determine subtask name(s) for the master chain label
    String? chainTargetLabel;
    if (isMasterWithChain && taskById != null) {
      final names = <String>[];
      final cfg = task.chainConfig!;
      if (cfg.onMatchTaskId != null && taskById[cfg.onMatchTaskId!] != null) {
        names.add(taskById[cfg.onMatchTaskId!]!.name);
      }
      if (cfg.onNoMatchTaskId != null &&
          taskById[cfg.onNoMatchTaskId!] != null) {
        names.add(taskById[cfg.onNoMatchTaskId!]!.name);
      }
      if (names.isNotEmpty) chainTargetLabel = names.join(' / ');
    }

    // Card colour: subtle teal tint for chain members
    final isDarkCard = Theme.of(context).brightness == Brightness.dark;
    Color? cardColor;
    if (isMasterWithChain) {
      cardColor = isDarkCard
          ? const Color(0xff0d2e33)
          : const Color(0xffe0f4f6);
    }
    if (isSubtask) {
      cardColor = isDarkCard
          ? const Color(0xff0a2228)
          : const Color(0xffecf9fb);
    }

    final uiStyle = AppPreferencesService.instance.uiStyle;
    final isModern = uiStyle == 'modern';
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    Color? modernColor;
    if (isModern) {
      if (isSubtask) {
        modernColor = isDark
            ? const Color(0xFF06B6D4).withValues(alpha: 0.08)
            : const Color(0xFF34D399).withValues(alpha: 0.05);
      } else if (isMasterWithChain) {
        modernColor = isDark
            ? const Color(0xFF7C3AED).withValues(alpha: 0.12)
            : const Color(0xFF7C3AED).withValues(alpha: 0.08);
      } else {
        modernColor = isDark
            ? Colors.black.withValues(alpha: 0.25)
            : Colors.white.withValues(alpha: 0.65);
      }
    }

    BorderSide? modernBorderSide;
    if (isModern) {
      if (isSubtask) {
        modernBorderSide = BorderSide(
          color: (isDark ? const Color(0xFF06B6D4) : const Color(0xFF34D399))
              .withValues(alpha: 0.3),
          width: 1.2,
        );
      } else if (isMasterWithChain) {
        modernBorderSide = BorderSide(
          color: const Color(0xFF7C3AED).withValues(alpha: 0.4),
          width: 1.5,
        );
      } else {
        modernBorderSide = BorderSide(
          color: (isDark
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.black.withValues(alpha: 0.08)),
          width: 1.0,
        );
      }
    }

    return Card(
      margin: EdgeInsets.only(
        top: 4,
        bottom: 4,
        left: isSubtask ? 20 : 0, // indent subtask cards
        right: 0,
      ),
      color: isModern ? modernColor : cardColor,
      shape: isModern
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: modernBorderSide ?? BorderSide.none,
            )
          : (isSubtask
                ? RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(
                      color: Colors.teal.withAlpha(80),
                      width: 1,
                    ),
                  )
                : isMasterWithChain
                ? RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(
                      color: Colors.teal.withAlpha(120),
                      width: 1,
                    ),
                  )
                : null),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _showDetails(task),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Chain group header labels
              if (isMasterWithChain && chainTargetLabel != null) ...[
                Row(
                  children: [
                    Icon(
                      Icons.account_tree_outlined,
                      size: 12,
                      color: Colors.teal[400],
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '→ $chainTargetLabel',
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.teal[400],
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
              ],
              if (isSubtask) ...[
                Row(
                  children: [
                    Icon(
                      Icons.subdirectory_arrow_right,
                      size: 12,
                      color: Colors.teal[300],
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '↳ ${masterTask.name}',
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.teal[300],
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
              ],
              // Title row
              Row(
                children: [
                  Expanded(
                    child: Text(
                      task.name,
                      style: TextStyle(
                        fontWeight: !task.enabled || !isScheduled
                            ? FontWeight.normal
                            : FontWeight.bold,
                        fontSize: isSubtask ? 14 : 16,
                        color: isSubtask
                            ? (isDarkCard ? Colors.teal[200] : Colors.teal[700])
                            : !task.enabled
                            ? Colors.grey
                            : isScheduled
                            ? Colors.green[400]
                            : Colors.blue[300],
                      ),
                    ),
                  ),
                  _buildStatusChip(task, forceActive: isSubtask),
                ],
              ),
              if (task.description != null && task.description!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  task.description!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: isSubtask
                        ? (isDarkCard ? Colors.teal[100] : Colors.teal[600])
                        : !task.enabled
                        ? Colors.grey
                        : isScheduled
                        ? Colors.green[300]
                        : Colors.blue[200],
                  ),
                ),
              ],
              const SizedBox(height: 8),
              // Executor Chips
              if (task.agents.isNotEmpty) ...[
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: task.agents.map((exec) {
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: (isDark ? Colors.teal[900] : Colors.teal[50])!
                            .withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: (isDark
                              ? Colors.teal[700]
                              : Colors.teal[200])!,
                          width: 0.8,
                        ),
                      ),
                      child: Text(
                        exec.name.isNotEmpty ? exec.name : 'Agent',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: isDark ? Colors.teal[200] : Colors.teal[800],
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 8),
              ],
              // Schedule + meta (hidden for subtasks — they have no independent schedule)
              if (!isSubtask)
                Row(
                  children: [
                    Icon(Icons.schedule, size: 14, color: Colors.grey[500]),
                    const SizedBox(width: 4),
                    Text(
                      task.executionPlan.cronExpression,
                      style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                    ),
                    const Spacer(),
                    if (task.mcpTools.isNotEmpty) ...[
                      Icon(Icons.extension, size: 14, color: Colors.grey[500]),
                      const SizedBox(width: 2),
                      Text(
                        '${task.mcpTools.length}',
                        style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                      ),
                      const SizedBox(width: 8),
                    ],
                    if (task.notification.email != null &&
                        task.notification.email!.recipients.isNotEmpty) ...[
                      Icon(
                        Icons.email_outlined,
                        size: 14,
                        color: Colors.grey[500],
                      ),
                      const SizedBox(width: 4),
                    ],
                    if (task.notification.slack != null) ...[
                      Icon(
                        Icons.chat_bubble_outline,
                        size: 14,
                        color: Colors.grey[500],
                      ),
                      const SizedBox(width: 4),
                    ],
                    if (task.notification.whatsApp != null) ...[
                      Icon(
                        Icons.phone_android_outlined,
                        size: 14,
                        color: Colors.grey[500],
                      ),
                      const SizedBox(width: 4),
                    ],
                    if (task.notification.hasAnyChannel)
                      Icon(
                        Icons.notifications_active,
                        size: 14,
                        color: Colors.grey[500],
                      ),
                  ],
                ),
              if (lastRun != null || (!isSubtask && nextRun != null)) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    if (lastRun != null) ...[
                      Text(
                        L.of(context).lastRun(_formatDate(lastRun)),
                        style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                      ),
                      const SizedBox(width: 12),
                    ],
                    if (!isSubtask && nextRun != null)
                      Text(
                        L.of(context).nextRun(_formatDate(nextRun)),
                        style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                      ),
                  ],
                ),
              ],
              if (hasCostStats) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(
                      Icons.attach_money_rounded,
                      size: 14,
                      color: Colors.grey[500],
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '${l.costLastShort}: ${_formatUsdCompact(lastCostUsd)} · ${l.costTotalShort}: ${_formatUsdCompact(totalCostUsd)}',
                        style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              // Action buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  // Schedule-type state indicator (hidden for subtasks — they have no independent schedule)
                  if (!isSubtask)
                    IconButton(
                      icon: Icon(
                        isScheduled ? Icons.alarm : Icons.touch_app,
                        color: isScheduled
                            ? (task.enabled ? Colors.green : Colors.grey)
                            : Colors.grey,
                        size: 22,
                      ),
                      tooltip: isScheduled
                          ? '${task.enabled ? L.of(context).disable : L.of(context).enable} · ${task.executionPlan.cronExpression}'
                          : '${task.enabled ? L.of(context).disable : L.of(context).enable} · Manuell',
                      onPressed: () => _toggleTask(task),
                      visualDensity: VisualDensity.compact,
                    ),
                  IconButton(
                    icon: _runningTaskIds.contains(task.id)
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.play_arrow, size: 20),
                    tooltip: L.of(context).executeNow,
                    onPressed: _runningTaskIds.contains(task.id)
                        ? null
                        : () => _executeTaskWithDialog(task),
                    visualDensity: VisualDensity.compact,
                  ),

                  IconButton(
                    icon: const Icon(Icons.edit, size: 20),
                    tooltip: L.of(context).edit,
                    onPressed: () => _editTask(task),
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    icon: const Icon(Icons.schema_outlined, size: 20),
                    tooltip: 'Visual Builder',
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => VisualBuilderScreen(task: task),
                      ),
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 20),
                    tooltip: L.of(context).copy,
                    onPressed: () => _copyTask(task),
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    icon: Icon(Icons.delete, size: 20, color: AppTheme.error),
                    tooltip: L.of(context).delete,
                    onPressed: () => _deleteTask(task),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Desktop: DataTable ──────────────────────────────

  Widget _buildDesktopTable(List<WorkflowTask> tasks) {
    final l = L.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // ── Build an id→task lookup ─────────────────────────────────────────────
    final taskById = {for (final t in tasks) t.id: t};

    // ── Group tasks: each chain root immediately followed by subtasks in
    //    configured execution order (onMatch -> onNoMatch), regardless of name.
    final rows = _buildOrderedTaskRows(tasks);

    // ── Column widths ───────────────────────────────────────────────────────
    const double wAct = 260;
    const double wName = 320;
    const double wUpd = 130;
    const double wPro = 280;
    const double wSch = 160;
    const double wStat = 100;
    const double wEna = 120;
    const double wLast = 190;
    const double totalW =
        wAct + wName + wUpd + wPro + wSch + wStat + wEna + wLast;

    final uiStyle = AppPreferencesService.instance.uiStyle;
    final isModern = uiStyle == 'modern';

    // ── Colours ─────────────────────────────────────────────────────────────
    final headerBg = isModern
        ? (isDark
              ? Colors.black.withValues(alpha: 0.4)
              : Colors.white.withValues(alpha: 0.5))
        : (isDark ? Colors.grey[850]! : Colors.grey[200]!);
    final masterBg = isModern
        ? (isDark
              ? const Color(0xFF7C3AED).withValues(alpha: 0.15)
              : const Color(0xFF7C3AED).withValues(alpha: 0.08))
        : (isDark ? const Color(0xff0d2e33) : const Color(0xffe8f7f9));
    final subtaskBg = isModern
        ? (isDark
              ? const Color(0xFF06B6D4).withValues(alpha: 0.12)
              : const Color(0xFF34D399).withValues(alpha: 0.05))
        : (isDark ? const Color(0xff0a2228) : const Color(0xfff1fbfc));
    final evenBg = isModern
        ? (isDark
              ? Colors.black.withValues(alpha: 0.25)
              : Colors.white.withValues(alpha: 0.65))
        : (isDark ? const Color(0xff1a1a2e) : Colors.white);
    final oddBg = isModern
        ? (isDark
              ? Colors.black.withValues(alpha: 0.18)
              : Colors.white.withValues(alpha: 0.55))
        : (isDark ? const Color(0xff1e1e30) : const Color(0xfff9f9f9));

    final headerStyle = TextStyle(
      fontWeight: FontWeight.bold,
      color: isDark ? Colors.white : Colors.black87,
      fontSize: 13,
    );

    // ── Cell helper ─────────────────────────────────────────────────────────
    Widget cell(double w, Widget child) => SizedBox(
      width: w,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: child,
      ),
    );

    // ── Sortable header cell ─────────────────────────────────────────────────
    Widget sortCell(double w, String label, int col) {
      final active = _sortColumnIndex == col;
      return SizedBox(
        width: w,
        child: InkWell(
          onTap: () => setState(() {
            if (_sortColumnIndex == col) {
              _sortAscending = !_sortAscending;
            } else {
              _sortColumnIndex = col;
              _sortAscending = true;
            }
          }),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Text(label, style: headerStyle),
                if (active) ...[
                  const SizedBox(width: 4),
                  Icon(
                    _sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
                    size: 13,
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    // ── Header row ───────────────────────────────────────────────────────────
    Widget headerContent = SizedBox(
      width: totalW,
      height: 48,
      child: Row(
        children: [
          cell(wAct, Text(l.columnActions, style: headerStyle)),
          sortCell(wName, l.columnName, 0),
          sortCell(wUpd, l.columnUpdated, 1),
          cell(wPro, Text(l.tasks, style: headerStyle)),
          cell(wSch, Text(l.columnSchedule, style: headerStyle)),
          cell(wStat, Text(l.columnStatus, style: headerStyle)),
          cell(
            wEna,
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.schedule_outlined, size: 14),
                const SizedBox(width: 4),
                Text(l.columnEnabled, style: headerStyle),
              ],
            ),
          ),
          cell(wLast, Text(l.columnLastRun, style: headerStyle)),
        ],
      ),
    );

    // ── Data row builder ─────────────────────────────────────────────────────
    Widget buildDataRow(
      WorkflowTask task,
      WorkflowTask? masterTask,
      int depth,
      int index,
    ) {
      final isSubtask =
          masterTask != null || (task.chainConfig?.isSubtask ?? false);
      final isMasterWithChain =
          !isSubtask && (task.chainConfig?.hasChaining ?? false);

      String? chainLabel;
      if (isMasterWithChain) {
        final names = <String>[];
        final cfg = task.chainConfig!;
        if (cfg.onMatchTaskId != null && taskById[cfg.onMatchTaskId!] != null) {
          names.add(taskById[cfg.onMatchTaskId!]!.name);
        }
        if (cfg.onNoMatchTaskId != null &&
            taskById[cfg.onNoMatchTaskId!] != null) {
          names.add(taskById[cfg.onNoMatchTaskId!]!.name);
        }
        if (names.isNotEmpty) chainLabel = names.join(' / ');
      }

      final rowBg = isMasterWithChain
          ? masterBg
          : isSubtask
          ? subtaskBg
          : index.isEven
          ? evenBg
          : oddBg;

      return InkWell(
        onTap: () => _showDetails(task),
        child: Container(
          color: rowBg,
          height: 64,
          width: totalW,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Actions
              cell(
                wAct,
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit, size: 20),
                      tooltip: l.edit,
                      onPressed: () => _editTask(task),
                      visualDensity: VisualDensity.compact,
                    ),
                    IconButton(
                      icon: const Icon(Icons.schema_outlined, size: 20),
                      tooltip: 'Visual Builder',
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => VisualBuilderScreen(task: task),
                        ),
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                    IconButton(
                      icon: _runningTaskIds.contains(task.id)
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.play_arrow, size: 20),
                      tooltip: l.executeNow,
                      onPressed: _runningTaskIds.contains(task.id)
                          ? null
                          : () => _executeTaskWithDialog(task),
                      visualDensity: VisualDensity.compact,
                    ),

                    IconButton(
                      icon: const Icon(Icons.copy, size: 20),
                      tooltip: l.copy,
                      onPressed: () => _copyTask(task),
                      visualDensity: VisualDensity.compact,
                    ),
                    IconButton(
                      icon: Icon(Icons.delete, size: 20, color: AppTheme.error),
                      tooltip: l.delete,
                      onPressed: () => _deleteTask(task),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
              ),
              // Name
              cell(
                wName,
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (depth > 0) SizedBox(width: depth * 16.0),
                    if (_isScheduledTask(task))
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Icon(
                          Icons.schedule,
                          size: 14,
                          color: Colors.teal[400],
                        ),
                      )
                    else if (isSubtask)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Icon(
                          Icons.subdirectory_arrow_right,
                          size: 14,
                          color: Colors.teal[300],
                        ),
                      )
                    else if (isMasterWithChain)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Icon(
                          Icons.account_tree_outlined,
                          size: 14,
                          color: Colors.teal[400],
                        ),
                      ),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            task.name,
                            style: TextStyle(
                              fontWeight: isSubtask
                                  ? FontWeight.normal
                                  : (task.enabled
                                        ? FontWeight.w600
                                        : FontWeight.normal),
                              fontSize: isSubtask ? 12.5 : 14,
                              color: task.enabled
                                  ? (isSubtask ? Colors.grey[400] : null)
                                  : Colors.grey,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (isMasterWithChain && chainLabel != null)
                            Text(
                              '→ $chainLabel',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.teal[400],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          if (isSubtask && masterTask != null)
                            Text(
                              '↳ ${masterTask.name}',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.teal[300],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // Updated
              cell(
                wUpd,
                Text(
                  _formatDate(task.updatedAt),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              // Prompt
              cell(
                wPro,
                task.agents.isNotEmpty
                    ? Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: task.agents.map((exec) {
                          return Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color:
                                  (isDark ? Colors.teal[900] : Colors.teal[50])!
                                      .withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: (isDark
                                    ? Colors.teal[700]
                                    : Colors.teal[200])!,
                                width: 0.8,
                              ),
                            ),
                            child: Text(
                              exec.name.isNotEmpty ? exec.name : 'Agent',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                                color: isDark
                                    ? Colors.teal[200]
                                    : Colors.teal[800],
                              ),
                            ),
                          );
                        }).toList(),
                      )
                    : Text(
                        task.prompt.length > 80
                            ? '${task.prompt.substring(0, 80)}...'
                            : task.prompt,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.grey[600], fontSize: 13),
                      ),
              ),
              // Schedule
              cell(
                wSch,
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.executionPlan.cronExpression,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              // Status
              cell(wStat, _buildStatusChip(task)),
              // Enabled
              cell(
                wEna,
                Switch(
                  value: task.enabled,
                  onChanged: (_) => _toggleTask(task),
                  activeTrackColor: AppTheme.primaryBlue,
                ),
              ),
              // Last run
              cell(
                wLast,
                Builder(
                  builder: (context) {
                    final rec = task.execution.history.isNotEmpty
                        ? task.execution.history.first
                        : null;
                    final hasCosts =
                        rec?.lastRequestCostUsd != null ||
                        rec?.sessionCostUsd != null;
                    return Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          task.execution.lastRun != null
                              ? _formatDate(task.execution.lastRun!)
                              : l.never,
                          style: const TextStyle(fontSize: 12),
                        ),
                        if (hasCosts)
                          Text(
                            '${l.costLastShort}: ${_formatUsdCompact(rec?.lastRequestCostUsd)} · ${l.costTotalShort}: ${_formatUsdCompact(rec?.sessionCostUsd)}',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey[500],
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        // ── Sticky header ───────────────────────────────────────────────────
        Container(
          color: headerBg,
          child: SingleChildScrollView(
            controller: _headerHorzCtrl,
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            child: headerContent,
          ),
        ),
        const Divider(height: 1, thickness: 1),
        // ── Scrollable body (vertical) + synchronized horizontal scroll ─────
        Expanded(
          child: Scrollbar(
            controller: _bodyHorzCtrl,
            thumbVisibility: true,
            child: SingleChildScrollView(
              controller: _bodyHorzCtrl,
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: totalW,
                child: ListView.separated(
                  padding: const EdgeInsets.only(bottom: 80),
                  itemCount: rows.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, thickness: 1),
                  itemBuilder: (_, i) => buildDataRow(
                    rows[i].task,
                    rows[i].masterTask,
                    rows[i].depth,
                    i,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStatusChip(WorkflowTask task, {bool forceActive = false}) {
    final isRunning = task.execution.isRunning;
    final hasError = task.execution.lastError != null;
    final hasRun = task.execution.runCount > 0;

    String label;
    Color color;

    final l = L.of(context);
    if (isRunning) {
      label = 'RUNNING';
      color = AppTheme.primaryBlue;
    } else if (hasError && task.execution.consecutiveFailures > 0) {
      label = l.statusFailed;
      color = AppTheme.error;
    } else if (hasRun) {
      label = 'OK';
      color = AppTheme.success;
    } else {
      label = l.statusPending;
      color = AppTheme.warning;
    }

    final active = task.enabled || forceActive;
    final uiStyle = AppPreferencesService.instance.uiStyle;
    final isModern = uiStyle == 'modern';

    if (isModern) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: active
              ? color.withValues(alpha: 0.15)
              : color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active
                ? color.withValues(alpha: 0.4)
                : color.withValues(alpha: 0.2),
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.bold,
            color: active ? color : color.withValues(alpha: 0.6),
          ),
        ),
      );
    }

    return Chip(
      label: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          color: active ? Colors.white : Colors.white70,
        ),
      ),
      backgroundColor: active ? color : color.withAlpha(120),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }

  List<({WorkflowTask task, WorkflowTask? masterTask, int depth})>
  _buildOrderedTaskRows(List<WorkflowTask> tasks) {
    final taskById = {for (final t in tasks) t.id: t};
    final referencedIds = <String>{};

    for (final task in tasks) {
      final cfg = task.chainConfig;
      if (cfg == null || !cfg.hasChaining) continue;
      if (cfg.onMatchTaskId != null &&
          taskById.containsKey(cfg.onMatchTaskId)) {
        referencedIds.add(cfg.onMatchTaskId!);
      }
      if (cfg.onNoMatchTaskId != null &&
          taskById.containsKey(cfg.onNoMatchTaskId)) {
        referencedIds.add(cfg.onNoMatchTaskId!);
      }
    }

    final rows = <({WorkflowTask task, WorkflowTask? masterTask, int depth})>[];
    final placedIds = <String>{};

    void addWithChain(WorkflowTask task, WorkflowTask? parent, int depth) {
      if (placedIds.contains(task.id)) return;
      placedIds.add(task.id);
      rows.add((task: task, masterTask: parent, depth: depth));

      final cfg = task.chainConfig;
      if (cfg == null || !cfg.hasChaining) return;

      for (final nextId in [cfg.onMatchTaskId, cfg.onNoMatchTaskId]) {
        if (nextId == null) continue;
        final nextTask = taskById[nextId];
        if (nextTask == null) continue;
        addWithChain(nextTask, task, depth + 1);
      }
    }

    // Start with chain roots so subtasks never render before their master.
    for (final task in tasks) {
      if (referencedIds.contains(task.id)) continue;
      addWithChain(task, null, 0);
    }

    // Safety net for orphaned/cyclic references.
    for (final task in tasks) {
      if (!placedIds.contains(task.id)) {
        addWithChain(task, null, 0);
      }
    }

    return rows;
  }

  String _formatDate(DateTime dt) {
    final local = dt.isUtc ? dt.toLocal() : dt;
    return '${local.day.toString().padLeft(2, '0')}.${local.month.toString().padLeft(2, '0')}.${local.year} '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  String _formatUsdCompact(double? value) {
    if (value == null) return '—';
    if (value > 0 && value < 0.01) return '\$${value.toStringAsFixed(4)}';
    return '\$${value.toStringAsFixed(2)}';
  }
}

// ─── Top-level helper functions (pure — used by both _TaskListScreenState
// and _ExecutionFlowDialogState) ──────────────────────────────────────────────

List<EmailAttachmentPayload> _extractEmailAttachmentsFromMessages(
  List<ChatMessage> messages,
) {
  final attachments = <EmailAttachmentPayload>[];

  void tryAdd({
    required String? fileName,
    required String? mimeType,
    required String? base64Content,
  }) {
    if (fileName == null || fileName.trim().isEmpty) return;
    if (mimeType == null || mimeType.trim().isEmpty) return;
    if (base64Content == null || base64Content.trim().isEmpty) return;
    try {
      final bytes = base64Decode(base64Content.trim());
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

    for (final content in toolResult.content) {
      if (content.data != null && content.data!.isNotEmpty) {
        final mime = content.mimeType ?? 'application/octet-stream';
        final ext = _extensionForMime(mime);

        String? inferredName;
        for (final sibling in toolResult.content) {
          if (sibling.text == null || sibling.text!.trim().isEmpty) continue;
          try {
            final decoded = jsonDecode(sibling.text!);
            if (decoded is Map<String, dynamic> &&
                decoded['fileName'] != null) {
              inferredName = decoded['fileName'].toString().trim();
              break;
            }
          } catch (_) {}
          final m = RegExp(
            r'(?:file(?:\s*name)?|saved\s+(?:as|to)|output\s+(?:file\s+)?(?:is\s+)?|named)\s*[:\s]+([^\s,\n<>"\x27]+\.[a-zA-Z0-9]{1,6})',
            caseSensitive: false,
          ).firstMatch(sibling.text!);
          if (m != null && m.group(1) != null) {
            inferredName = m.group(1)!.trim();
            break;
          }
        }
        final generatedName =
            inferredName ??
            'task_output_${DateTime.now().millisecondsSinceEpoch}.$ext';
        tryAdd(
          fileName: generatedName,
          mimeType: mime,
          base64Content: content.data,
        );
      }

      final text = content.text;
      if (text == null || text.trim().isEmpty) continue;
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map<String, dynamic>) {
          if (decoded['fileName'] != null &&
              decoded['mimeType'] != null &&
              decoded['encoding'] == 'base64' &&
              decoded['content'] != null) {
            tryAdd(
              fileName: decoded['fileName'].toString(),
              mimeType: decoded['mimeType'].toString(),
              base64Content: decoded['content'].toString(),
            );
          }
          if (decoded['data'] is Map<String, dynamic>) {
            final data = decoded['data'] as Map<String, dynamic>;
            if (data['fileName'] != null &&
                data['mimeType'] != null &&
                data['encoding'] == 'base64' &&
                data['content'] != null) {
              tryAdd(
                fileName: data['fileName'].toString(),
                mimeType: data['mimeType'].toString(),
                base64Content: data['content'].toString(),
              );
            }
          }
        }
      } catch (_) {}
    }

    if (attachments.isNotEmpty) break;
  }

  return attachments;
}

bool _looksLikeHtml(String text) {
  final trimmed = text.trim().toLowerCase();
  if (trimmed.isEmpty) return false;
  if (trimmed.contains('<!doctype html') || trimmed.contains('<html')) {
    return true;
  }
  return RegExp(
    r'<(div|span|table|p|h1|h2|h3|ul|ol|li|body)[\s>]',
    caseSensitive: false,
  ).hasMatch(trimmed);
}

/// Builds a full execution log with the entire LLM conversation.
/// Tool results are shown but truncated to the first 15 lines.
String _buildExecutionLog({
  required WorkflowTask task,
  required bool taskSuccess,
  required List<Map<String, dynamic>> executedSteps,
}) {
  final now = DateTime.now().toIso8601String();
  final sb = StringBuffer();
  sb.writeln('# Execution Log');
  sb.writeln();
  sb.writeln('- **Task:** ${task.name}');
  sb.writeln('- **Timestamp:** $now');
  sb.writeln('- **Status:** ${taskSuccess ? 'success' : 'failure'}');
  sb.writeln();
  sb.writeln('## Conversation');
  sb.writeln();

  for (final step in executedSteps) {
    final exec = step['executor'] as Agent;
    final msgs = step['messages'] as List<ChatMessage>;
    sb.writeln(
      '================================================================',
    );
    sb.writeln('### Agent: ${exec.name}');
    sb.writeln(
      '================================================================',
    );
    sb.writeln();

    for (final msg in msgs) {
      if (msg.role == ChatRole.user) {
        sb.writeln('#### User');
        sb.writeln(msg.content.trim());
        sb.writeln();
      } else if (msg.role == ChatRole.assistant) {
        final text = msg.content.trim();
        if (text.isNotEmpty) {
          sb.writeln('#### Assistant');
          sb.writeln(text);
          sb.writeln();
        }
      } else if (msg.role == ChatRole.tool) {
        final toolName = msg.lastCalledToolName ?? 'tool';
        sb.writeln('#### Tool: $toolName');
        String toolText = msg.content.trim();
        if (toolText.isEmpty && msg.toolResult != null) {
          toolText = msg.toolResult!.content
              .where((c) => c.text != null && c.text!.isNotEmpty)
              .map((c) => c.text!.trim())
              .join('\n');
        }
        if (toolText.isNotEmpty) {
          final lines = toolText.split('\n');
          const maxLines = 15;
          if (lines.length <= maxLines) {
            sb.writeln(toolText);
          } else {
            sb.writeln(lines.take(maxLines).join('\n'));
            sb.writeln('... (${lines.length - maxLines} more lines truncated)');
          }
        }
        sb.writeln();
      }
    }
    sb.writeln();
  }

  return sb.toString();
}

/// Builds the output log: full user + assistant conversation, no tool results.
String _buildOutputLog({
  required WorkflowTask task,
  required List<Map<String, dynamic>> executedSteps,
}) {
  final sb = StringBuffer();
  sb.writeln('# Output Log: ${task.name}');
  sb.writeln();
  for (final step in executedSteps) {
    final exec = step['executor'] as Agent;
    final assistantText = step['assistantText'] as String;
    sb.writeln(
      '================================================================',
    );
    sb.writeln('### Agent: ${exec.name}');
    sb.writeln(
      '================================================================',
    );
    sb.writeln();
    sb.writeln(assistantText.trim());
    sb.writeln();
  }
  return sb.toString();
}

String _extensionForMime(String mime) {
  final lower = mime.toLowerCase();
  if (lower.contains('html')) return 'html';
  if (lower.contains('pdf')) return 'pdf';
  if (lower.contains('png')) return 'png';
  if (lower.contains('jpeg') || lower.contains('jpg')) return 'jpg';
  if (lower.contains('gif')) return 'gif';
  if (lower.contains('webp')) return 'webp';
  if (lower.contains('svg')) return 'svg';
  if (lower.contains('excel') ||
      lower.contains('spreadsheet') ||
      lower.contains('xls')) {
    return 'xlsx';
  }
  if (lower.contains('word') ||
      lower.contains('document') ||
      lower.contains('msword')) {
    return 'docx';
  }
  if (lower.contains('json')) return 'json';
  if (lower.contains('csv')) return 'csv';
  if (lower.contains('xml')) return 'xml';
  if (lower.startsWith('text/')) return 'txt';
  return 'bin';
}

String _slugifyName(String name) {
  var slug = name
      .toLowerCase()
      .replaceAll(RegExp(r'[^\w\s-]'), '')
      .replaceAll(RegExp(r'[\s]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  if (slug.length > 40) {
    slug = slug.substring(0, 40).replaceAll(RegExp(r'_+$'), '');
  }
  return slug.isEmpty ? 'output' : slug;
}

List<String> _extractHtmlSections(String text) {
  if (text.trim().isEmpty) return const [];
  final sections = <String>[];

  // 1. Check for markdown html code fences
  final fenceMatch = RegExp(
    r'```html\s*\n([\s\S]*?)\n?```',
    caseSensitive: false,
  );
  for (final match in fenceMatch.allMatches(text)) {
    final section = match.group(1)!.trim();
    if (section.isNotEmpty) sections.add(section);
  }
  if (sections.isNotEmpty) return sections;

  // 2. Raw HTML
  final htmlRegex = RegExp(
    r'(?:<!doctype\s+html[^>]*>\s*)?<html[\s\S]*?</html>',
    caseSensitive: false,
  );
  for (final match in htmlRegex.allMatches(text)) {
    final section = match.group(0)!.trim();
    if (section.isNotEmpty) sections.add(section);
  }
  if (sections.isEmpty && _looksLikeHtml(text)) sections.add(text.trim());
  return sections;
}

String _resolveOutputFileName(
  String pattern, {
  required String fallbackExtension,
}) {
  final now = DateTime.now();
  final date =
      '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
  final iso = now.toIso8601String().replaceAll(':', '-');
  var resolved = pattern
      .replaceAll('{date}', date)
      .replaceAll('{datetime}', iso)
      .replaceAll('{timestamp}', '${now.millisecondsSinceEpoch}')
      .trim();
  if (resolved.isEmpty) resolved = 'task_result_$date';
  resolved = resolved.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  if (!resolved.contains('.')) resolved = '$resolved.$fallbackExtension';
  return resolved;
}

Future<_GeneratedOutputBundle> _buildTaskOutputBundle({
  required WorkflowTask task,
  required List<Map<String, dynamic>> executedSteps,
  required bool taskSuccess,
}) async {
  try {
    final generatedFiles = <_GeneratedFile>[];
    final savedFilePaths = <String>[];

    // Extract binary attachments from all step messages
    final toolAttachments = <EmailAttachmentPayload>[];
    for (final step in executedSteps) {
      final msgs = step['messages'] as List<ChatMessage>;
      toolAttachments.addAll(_extractEmailAttachmentsFromMessages(msgs));
    }

    // Resolve output directory: task-level path → global default → OS documents/task_outputs
    final taskDirPath = (task.notification.download?.downloadPath ?? '').trim();
    final globalDefault = AppPreferencesService.instance.defaultOutputPath
        .trim();

    String resolvedDirPath;
    if (taskDirPath.isNotEmpty) {
      resolvedDirPath = taskDirPath;
    } else if (globalDefault.isNotEmpty) {
      resolvedDirPath = globalDefault;
    } else if (!kIsWeb) {
      final docs = await getApplicationDocumentsDirectory();
      resolvedDirPath = '${docs.path}${Platform.pathSeparator}task_outputs';
    } else {
      resolvedDirPath = '';
    }

    // Build slug+datetime for the run subfolder
    final now = DateTime.now();
    final dt =
        '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}'
        '_'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}';
    final taskSlug = _slugifyName(task.name);
    final runFolderName = taskSlug.isNotEmpty ? '${taskSlug}_$dt' : dt;

    Directory? outputDir;
    if (resolvedDirPath.isNotEmpty) {
      // Each run gets its own {slug}_{YYYYMMDD_HHmmss} subfolder
      final runDir = Directory(
        '$resolvedDirPath${Platform.pathSeparator}$runFolderName',
      );
      if (!await runDir.exists()) await runDir.create(recursive: true);
      outputDir = runDir;
    }

    // Output log: full user+assistant conversation (no tool results)
    final outputLogContent = _buildOutputLog(
      task: task,
      executedSteps: executedSteps,
    );
    generatedFiles.add(
      _GeneratedFile(
        name: 'output_log.md',
        mimeType: 'text/markdown',
        bytes: Uint8List.fromList(utf8.encode(outputLogContent)),
      ),
    );

    if (task.notification.addExecutionLog) {
      final execLog = _buildExecutionLog(
        task: task,
        taskSuccess: taskSuccess,
        executedSteps: executedSteps,
      );
      generatedFiles.add(
        _GeneratedFile(
          name: 'execution_log.md',
          mimeType: 'text/markdown',
          bytes: Uint8List.fromList(utf8.encode(execLog)),
        ),
      );
    }

    // Extract HTML sections for each executed step
    for (final step in executedSteps) {
      final exec = step['executor'] as Agent;
      final assistantText = step['assistantText'] as String;
      final htmlSections = _extractHtmlSections(assistantText);
      for (int i = 0; i < htmlSections.length; i++) {
        final suffix = htmlSections.length == 1 ? '' : '_${i + 1}';
        final cleanExecName = _slugifyName(exec.name);
        final htmlName = '${cleanExecName}_output$suffix.html';
        generatedFiles.add(
          _GeneratedFile(
            name: htmlName,
            mimeType: 'text/html',
            bytes: Uint8List.fromList(utf8.encode(htmlSections[i])),
          ),
        );
      }
    }

    generatedFiles.addAll(
      toolAttachments.map(
        (a) => _GeneratedFile(
          name: a.fileName,
          mimeType: a.mimeType,
          bytes: a.bytes,
        ),
      ),
    );

    if (generatedFiles.isEmpty) {
      generatedFiles.add(
        _GeneratedFile(
          name: _resolveOutputFileName(
            'result_{date}.txt',
            fallbackExtension: 'txt',
          ),
          mimeType: 'text/plain',
          bytes: Uint8List.fromList(utf8.encode('No output generated.')),
        ),
      );
    }

    if (outputDir != null) {
      for (final file in generatedFiles) {
        final localFile = File(
          '${outputDir.path}${Platform.pathSeparator}${file.name}',
        );
        await localFile.writeAsBytes(file.bytes, flush: true);
        savedFilePaths.add(localFile.path);
      }
    }

    List<EmailAttachmentPayload> emailAttachments;
    if (task.notification.zipOutputFiles && generatedFiles.isNotEmpty) {
      final archive = Archive();
      for (final file in generatedFiles) {
        archive.addFile(ArchiveFile(file.name, file.bytes.length, file.bytes));
      }
      final zipBytes = Uint8List.fromList(ZipEncoder().encode(archive));
      final zipName = _resolveOutputFileName(
        'task_output_{date}.zip',
        fallbackExtension: 'zip',
      );
      emailAttachments = [
        EmailAttachmentPayload(
          fileName: zipName,
          mimeType: 'application/zip',
          bytes: zipBytes,
        ),
      ];
      if (outputDir != null) {
        final zipPath = '${outputDir.path}${Platform.pathSeparator}$zipName';
        await File(zipPath).writeAsBytes(zipBytes, flush: true);
        savedFilePaths.add(zipPath);
      }
    } else {
      emailAttachments = generatedFiles
          .map(
            (f) => EmailAttachmentPayload(
              fileName: f.name,
              mimeType: f.mimeType,
              bytes: f.bytes,
            ),
          )
          .toList();
    }

    return _GeneratedOutputBundle(
      savedFilePaths: savedFilePaths,
      emailAttachments: emailAttachments,
    );
  } catch (e) {
    return _GeneratedOutputBundle(error: 'File output failed: $e');
  }
}

class _GeneratedOutputBundle {
  final List<String> savedFilePaths;
  final List<EmailAttachmentPayload> emailAttachments;
  final String? error;

  const _GeneratedOutputBundle({
    this.savedFilePaths = const [],
    this.emailAttachments = const [],
    this.error,
  });
}

class _GeneratedFile {
  final String name;
  final String mimeType;
  final Uint8List bytes;

  const _GeneratedFile({
    required this.name,
    required this.mimeType,
    required this.bytes,
  });
}

// ─── Execution Flow Dialog ──────────────────────────────────────────────────

/// Full-screen dialog that runs a task and shows the AI execution flow live.
// ─── Scheduler permission warning banner ─────────────────────────────────────

class _SchedulerPermissionBanner extends StatelessWidget {
  const _SchedulerPermissionBanner({
    required this.icon,
    required this.message,
    required this.actionLabel,
    required this.onAction,
    required this.onDismiss,
  });

  final IconData icon;
  final String message;
  final String actionLabel;
  final VoidCallback onAction;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Colors.orange, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 12, height: 1.4),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Colors.orange,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: onAction,
            child: Text(actionLabel, style: const TextStyle(fontSize: 12)),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            onPressed: onDismiss,
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }
}

// ─── Execution flow dialog ────────────────────────────────────────────────────

class _ExecutionFlowDialog extends ConsumerStatefulWidget {
  final WorkflowTask task;
  const _ExecutionFlowDialog({required this.task});

  @override
  ConsumerState<_ExecutionFlowDialog> createState() =>
      _ExecutionFlowDialogState();
}

class _ExecutionFlowDialogState extends ConsumerState<_ExecutionFlowDialog> {
  final List<_ExecEntry> _entries = [];
  bool _done = false;
  bool _success = false;
  StreamSubscription<ChatMessage>? _msgSub;
  final ScrollController _scroll = ScrollController();

  void _addEntry(String type, String text, {String? details}) {
    if (!mounted) return;
    setState(
      () => _entries.add(
        _ExecEntry(
          type: type,
          text: text,
          details: details,
          timestamp: DateTime.now(),
        ),
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void initState() {
    super.initState();
    // Defer provider modification past the build phase — Riverpod forbids
    // mutating a provider inside initState/build/dispose/didUpdateWidget.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _run();
    });
  }

  @override
  void dispose() {
    _msgSub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final serverMode = ref.read(serverModeProvider).value;
    final isRemote = serverMode?.isRemote ?? false;
    final serverClient = isRemote ? ref.read(serverApiClientProvider) : null;
    if (isRemote && serverClient != null) {
      await _runRemote(serverClient);
    } else {
      await _runLocal();
    }
  }

  // ── Remote (server mode) execution ──────────────────────────────────────

  Future<void> _runRemote(ServerApiClient serverClient) async {
    final l = L.of(context);
    try {
      _addEntry('info', l.execInitializing);
      final taskId = widget.task.id;
      final runRequestedAt = DateTime.now().toUtc();

      // Snapshot lastRun before triggering so we can detect completion.
      final taskBefore = await serverClient.getTask(taskId);
      final lastRunBefore = taskBefore?.execution.lastRun;

      _addEntry('info', 'Sending task to server...');
      await serverClient.runTask(taskId);

      _addEntry('info', 'Waiting for server result...');

      // Poll until execution.lastRun advances, with a longer timeout for
      // long-running server tasks (indexing, large tool chains, etc.).
      const pollInterval = Duration(seconds: 3);
      const pollRequestTimeout = Duration(seconds: 10);
      const timeout = Duration(minutes: 45);
      final deadline = DateTime.now().add(timeout);
      WorkflowTask? completed;
      var sawTaskRunning = false;
      var pollErrors = 0;
      var displayedLiveLogs = 0;

      while (DateTime.now().isBefore(deadline)) {
        await Future.delayed(pollInterval);
        WorkflowTask? polled;
        bool? isRunning;
        try {
          polled = await serverClient.getTask(
            taskId,
            timeout: pollRequestTimeout,
          );
          isRunning = await serverClient.getTaskRunStatus(
            taskId,
            timeout: pollRequestTimeout,
          );
          pollErrors = 0;
        } catch (e) {
          pollErrors++;
          if (pollErrors == 1 || pollErrors % 5 == 0) {
            final reason = e is TimeoutException
                ? 'temporary network delay'
                : e.toString();
            _addEntry(
              'info',
              'Server poll delayed ($pollErrors), retrying: $reason',
            );
          }
          continue;
        }

        // Fetch and append live logs
        try {
          final logsResponse = await serverClient.getTaskExecutionLogs(
            taskId,
            timeout: pollRequestTimeout,
          );
          final liveLogs = logsResponse?['live_logs'] as List<dynamic>?;
          if (liveLogs != null && liveLogs.length > displayedLiveLogs) {
            for (int k = displayedLiveLogs; k < liveLogs.length; k++) {
              final line = liveLogs[k].toString();
              if (line.contains(']')) {
                final lineNoPrefix = line
                    .substring(line.indexOf(']') + 1)
                    .trim();
                if (lineNoPrefix.startsWith('System Prompt:')) {
                  final content = lineNoPrefix
                      .substring('System Prompt:'.length)
                      .trim();
                  _addEntry(
                    'system',
                    'System prompt: ${content.substring(0, content.length > 150 ? 150 : content.length)}...',
                    details: content,
                  );
                } else if (lineNoPrefix.startsWith('User Prompt:')) {
                  final content = lineNoPrefix
                      .substring('User Prompt:'.length)
                      .trim();
                  _addEntry('info', 'User prompt: $content');
                } else if (lineNoPrefix.startsWith('Assistant:')) {
                  final content = lineNoPrefix
                      .substring('Assistant:'.length)
                      .trim();
                  _addEntry('assistant', content);
                } else if (lineNoPrefix.startsWith('Calling tool "')) {
                  final match = RegExp(
                    r'Calling tool "([^"]+)" with arguments: (.*)',
                  ).firstMatch(lineNoPrefix);
                  if (match != null) {
                    final toolName = match.group(1)!;
                    _addEntry('info', 'Calling tool "$toolName"');
                  } else {
                    _addEntry('info', lineNoPrefix);
                  }
                } else if (lineNoPrefix.startsWith('Tool "') &&
                    lineNoPrefix.contains('" returned:')) {
                  final match = RegExp(
                    r'Tool "([^"]+)" returned: (.*)',
                  ).firstMatch(lineNoPrefix);
                  if (match != null) {
                    final toolName = match.group(1)!;
                    final resultText = match.group(2)!;
                    _addEntry(
                      'tool',
                      'Tool "$toolName" returned',
                      details: resultText,
                    );
                  } else {
                    _addEntry('tool', lineNoPrefix);
                  }
                } else {
                  _addEntry('info', lineNoPrefix);
                }
              } else {
                _addEntry('info', line);
              }
            }
            displayedLiveLogs = liveLogs.length;
          }
        } catch (_) {
          // Ignore logs polling error to not break main task polling loop
        }
        if (polled == null) break;

        if (isRunning == true) {
          sawTaskRunning = true;
        }

        final lastRunNow = polled.execution.lastRun;
        if (lastRunNow != null && lastRunNow != lastRunBefore) {
          completed = polled;
        }

        // Wait for the server's active-run state to clear. This prevents
        // premature completion while post-run chaining is still executing.
        if (isRunning == false && (sawTaskRunning || completed != null)) {
          completed ??= polled;
          break;
        }
      }

      // Always try to fetch server-side details, but do not fail the whole
      // manual run if one of these auxiliary endpoints is temporarily slow.
      const detailTimeout = Duration(seconds: 15);
      Map<String, dynamic>? output;
      Map<String, dynamic>? logsResponse;
      Map<String, dynamic>? outputFilesResponse;
      Map<String, dynamic>? schedulerLogResponse;

      try {
        output = await serverClient.getTaskOutput(
          taskId,
          timeout: detailTimeout,
        );
      } catch (e) {
        _addEntry('info', 'Server output fetch delayed: $e');
      }
      try {
        logsResponse = await serverClient.getTaskExecutionLogs(
          taskId,
          timeout: detailTimeout,
        );
      } catch (e) {
        _addEntry('info', 'Server execution log fetch delayed: $e');
      }
      try {
        outputFilesResponse = await serverClient.getTaskOutputFiles(
          taskId,
          timeout: detailTimeout,
        );
      } catch (e) {
        _addEntry('info', 'Server output file list fetch delayed: $e');
      }
      try {
        schedulerLogResponse = await serverClient.getSchedulerLog(
          limit: 100,
          timeout: detailTimeout,
        );
      } catch (e) {
        _addEntry('info', 'Server scheduler log fetch delayed: $e');
      }

      final resultText = output?['text'] as String? ?? '';
      final historyRaw =
          logsResponse?['execution_history'] as List<dynamic>? ??
          const <dynamic>[];
      final history = historyRaw.whereType<Map<String, dynamic>>().toList();
      final outputFilesRaw =
          outputFilesResponse?['files'] as List<dynamic>? ?? const <dynamic>[];
      final outputFiles = outputFilesRaw
          .whereType<Map<String, dynamic>>()
          .toList();
      final schedulerEntriesRaw =
          schedulerLogResponse?['entries'] as List<dynamic>? ??
          const <dynamic>[];
      final schedulerEntries = schedulerEntriesRaw
          .whereType<Map<String, dynamic>>()
          .toList();

      if (completed == null) {
        WorkflowTask? latestTask;
        try {
          latestTask = await serverClient.getTask(
            taskId,
            timeout: pollRequestTimeout,
          );
        } catch (_) {
          latestTask = null;
        }
        final latestLastRun = latestTask?.execution.lastRun;
        final sawRunAdvance =
            latestLastRun != null && latestLastRun != lastRunBefore;

        final lastServerEntry = history.isNotEmpty ? history.first : null;
        final entryStampRaw = lastServerEntry?['timestamp'] as String?;
        final entryStamp = entryStampRaw != null
            ? DateTime.tryParse(entryStampRaw)?.toUtc()
            : null;
        final sawRecentHistory =
            lastServerEntry != null &&
            (entryStamp == null ||
                !entryStamp.isBefore(
                  runRequestedAt.subtract(const Duration(minutes: 1)),
                ));

        if (sawRunAdvance || sawRecentHistory) {
          completed = latestTask ?? taskBefore ?? widget.task;
          _addEntry(
            'info',
            'Server finished after delayed state propagation. Showing latest logs/output.',
          );
        } else {
          _addEntry('error', 'Timed out waiting for server result.');
          if (mounted) {
            setState(() {
              _done = true;
              _success = false;
            });
          }
          return;
        }
      }

      final lastServerEntry = history.isNotEmpty ? history.first : null;
      final bool? serverSuccess = lastServerEntry?['success'] as bool?;
      final taskSuccess =
          serverSuccess ??
          (completed.execution.lastError == null &&
              completed.execution.lastRun != null);

      if (history.isNotEmpty) {
        final durationMs = (lastServerEntry?['duration_ms'] as num?)?.toInt();
        final tokensUsed = (lastServerEntry?['tokens_used'] as num?)?.toInt();
        final toolCalls = (lastServerEntry?['tool_calls'] as num?)?.toInt();
        final stamp = (lastServerEntry?['timestamp'] as String?) ?? '-';
        _addEntry(
          'info',
          'Server execution log: $stamp | duration=${durationMs ?? '-'}ms | tokens=${tokensUsed ?? '-'} | tools=${toolCalls ?? '-'}',
        );
      } else {
        _addEntry('info', 'Server execution log: no entries returned');
      }

      if (schedulerEntries.isNotEmpty) {
        final matching = schedulerEntries
            .where((e) => (e['task_id'] as String?) == taskId)
            .toList();
        if (matching.isNotEmpty) {
          final latest = matching.first;
          final startedAt = (latest['started_at'] as String?) ?? '-';
          final msg = (latest['message'] as String?) ?? '';
          final ok = (latest['success'] as bool?) == true;
          _addEntry(
            'info',
            'Server scheduler: ${ok ? 'success' : 'failed'} at $startedAt${msg.isNotEmpty ? ' | $msg' : ''}',
          );
        }
      }

      if (outputFiles.isNotEmpty) {
        final top = outputFiles
            .take(5)
            .map((f) {
              final name = (f['filename'] as String?) ?? 'unknown';
              final size = (f['size'] as num?)?.toInt() ?? 0;
              return '$name (${size}B)';
            })
            .join(', ');
        _addEntry('info', 'Server output files (${outputFiles.length}): $top');
      } else {
        _addEntry('info', 'Server output files: none');
      }

      final resultFromLog = (lastServerEntry?['result'] as String?) ?? '';
      final effectiveResultText = resultText.isNotEmpty
          ? resultText
          : resultFromLog;
      if (effectiveResultText.isNotEmpty) {
        _addEntry('assistant', effectiveResultText);
      }

      if (taskSuccess) {
        _addEntry('success', l.execCompleted);
      } else {
        final errFromLog = (lastServerEntry?['error'] as String?);
        final err =
            errFromLog ?? completed.execution.lastError ?? l.execNoResponse;
        _addEntry('error', l.execAiError(err));
      }

      if (mounted) {
        setState(() {
          _done = true;
          _success = taskSuccess;
        });
      }
    } catch (e) {
      _addEntry('error', l.execError(e.toString()));
      if (mounted) {
        setState(() {
          _done = true;
          _success = false;
        });
      }
    }
  }

  // ── Local execution ──────────────────────────────────────────────────────

  Future<void> _runLocal() async {
    final l = L.of(context);
    try {
      _addEntry('info', l.execInitializing);

      // Get agents to run.
      final List<Agent> executorsToRun = widget.task.agents.isNotEmpty
          ? widget.task.agents
          : [
              Agent(
                id: 'default',
                name: widget.task.name,
                prompt: widget.task.prompt,
                systemPrompt: widget.task.systemPrompt,
                llmConfig: widget.task.llmConfig,
                mcpTools: widget.task.mcpTools,
                internalMcps: widget.task.internalMcps,
                chatMode: widget.task.chatMode,
                stopAfterToolCall: widget.task.stopAfterToolCall,
              ),
            ];

      final Map<String, Agent> executorMap = {
        for (final e in executorsToRun) e.id: e,
      };
      Agent currentExecutor = executorsToRun.first;
      String previousStepOutput = '';
      int stepsExecuted = 0;
      bool taskSuccess = true;
      String assistantText = '';
      final List<ChatMessage> messages = [];
      final executedSteps = <Map<String, dynamic>>[];

      int accumulatedPromptTokens = 0;
      int accumulatedCompletionTokens = 0;
      int accumulatedToolCallCount = 0;

      while (stepsExecuted < 50) {
        stepsExecuted++;
        final stepStartTime = DateTime.now();
        final execName = currentExecutor.name;
        _addEntry(
          'info',
          '\n================================================================\n'
              '▶ AGENT RUNNING: "$execName"\n'
              '================================================================',
        );
        _addEntry('info', '[$execName] ${l.execInitializing}');

        final tempTask = WorkflowTask(
          id: widget.task.id,
          name: currentExecutor.name,
          prompt: currentExecutor.prompt,
          systemPrompt: currentExecutor.systemPrompt,
          llmConfig: currentExecutor.llmConfig,
          mcpTools: currentExecutor.mcpTools,
          internalMcps: currentExecutor.internalMcps,
          chatMode: currentExecutor.chatMode,
          stopAfterToolCall: currentExecutor.stopAfterToolCall,
          executionPlan: widget.task.executionPlan,
          providers: widget.task.providers,
        );

        final activeNotifier = ref.read(activeTaskProvider.notifier);
        await activeNotifier.setTask(tempTask);
        final active = ref.read(activeTaskProvider);
        final chatService = active?.chatService;
        if (chatService == null || !(active?.isReady ?? false)) {
          throw Exception(l.execNotReady);
        }

        final sysPrompt = active?.effectiveSystemPrompt ?? '';
        if (sysPrompt.isNotEmpty) {
          final oneLine = sysPrompt.replaceAll('\n', ' ');
          final preview = oneLine.length > 80
              ? '${oneLine.substring(0, 80)}\u2026'
              : oneLine;
          _addEntry(
            'system',
            '[$execName] System prompt: $preview',
            details: sysPrompt,
          );
        }

        // Subscribe to live message stream for this step
        await _msgSub?.cancel();
        _msgSub = chatService.messageStream.listen((msg) {
          switch (msg.role) {
            case ChatRole.assistant:
              if (msg.content.trim().isNotEmpty) {
                _addEntry('assistant', '[$execName] ${msg.content.trim()}');
              }
              break;
            case ChatRole.user:
              if (msg.content.trim().isNotEmpty) {
                final preview = msg.content.trim().replaceAll('\n', ' ');
                final shortPreview = preview.length > 120
                    ? '${preview.substring(0, 120)}…'
                    : preview;
                _addEntry(
                  'info',
                  '[$execName] Sending prompt to AI: $shortPreview',
                );
              }
              break;
            case ChatRole.tool:
              final name = msg.lastCalledToolName ?? 'Tool';
              final argsRaw = msg.content.contains('\nArguments: ')
                  ? msg.content.split('\nArguments: ').last.trim()
                  : '';
              final argsPreview = argsRaw.length > 100
                  ? '${argsRaw.substring(0, 100)}\u2026'
                  : argsRaw;
              final raw = msg.toolResult?.content.isNotEmpty == true
                  ? (msg.toolResult!.content.first.text ?? '')
                  : '';
              final resultPreview = raw.length > 150
                  ? '${raw.substring(0, 150)}\u2026'
                  : raw;
              final lines = [
                if (argsPreview.isNotEmpty) '$name($argsPreview)' else name,
                if (resultPreview.isNotEmpty) '\u2192 $resultPreview',
              ];
              _addEntry(
                'tool',
                '[$execName] ${lines.join('\n')}',
                details: raw.isNotEmpty ? raw : null,
              );
            default:
              break;
          }
        });

        _addEntry('info', '[$execName] ${l.execSendingPrompt}');

        // Replace variables in prompt
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

        await chatService.sendMessage(promptToRun);
        await Future.delayed(const Duration(milliseconds: 100));
        await _msgSub?.cancel();
        _msgSub = null;

        final stepMessages = chatService.messages;
        messages.addAll(stepMessages);

        final stepStats = chatService.getChatStats();
        accumulatedPromptTokens += stepStats['prompt_tokens'] as int? ?? 0;
        accumulatedCompletionTokens +=
            stepStats['completion_tokens'] as int? ?? 0;
        accumulatedToolCallCount += stepStats['tool_call_count'] as int? ?? 0;

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

        assistantText = lastAssistant?.content.trim() ?? '';
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

        if (currentExecutor.stopAfterToolCall &&
            !currentExecutor.prompt.contains('++#++')) {
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
          taskSuccess = false;
          _addEntry(
            'error',
            assistantText.isEmpty
                ? 'Empty response from LLM'
                : l.execAiError(assistantText),
          );
          executedSteps.add({
            'executor': currentExecutor,
            'messages': List<ChatMessage>.from(stepMessages),
            'assistantText': assistantText,
            'startTime': stepStartTime,
          });
          break;
        }

        previousStepOutput = assistantText;
        executedSteps.add({
          'executor': currentExecutor,
          'messages': List<ChatMessage>.from(stepMessages),
          'assistantText': assistantText,
          'startTime': stepStartTime,
        });

        // Clean up connections for the step before continuing
        final mcpManager = active?.mcpManager;
        if (mcpManager != null) {
          await mcpManager.clear();
        }

        // Dynamic Routing
        String? nextExecutorId;
        final rules = widget.task.edges
            .where((r) => r.sourceAgentId == currentExecutor.id)
            .toList();
        for (final rule in rules) {
          final valueToCheck = previousStepOutput;
          final met = await evaluateCondition(
            llmService: active!.llmService!,
            locationService: active.chatService!.locationService,
            mcpManager: active.mcpManager!,
            source: valueToCheck,
            operator: rule.operator,
            value: rule.value,
          );
          if (met) {
            nextExecutorId = rule.targetAgentId;
            _addEntry(
              'info',
              '[$execName] Routing condition met: ${rule.variable} ${rule.operator} ${rule.value}. Routing to $nextExecutorId',
            );
            break;
          }
        }

        if (nextExecutorId != null) {
          if (executorMap.containsKey(nextExecutorId)) {
            currentExecutor = executorMap[nextExecutorId]!;
          } else {
            _addEntry(
              'info',
              '[$execName] Routed target executor $nextExecutorId not found in agents list. Terminating.',
            );
            break;
          }
        } else {
          if (rules.isNotEmpty) {
            _addEntry(
              'info',
              '[$execName] No routing conditions met for conditional step. Terminating.',
            );
            break;
          }
          final currentIndex = executorsToRun.indexOf(currentExecutor);
          if (currentIndex != -1 && currentIndex + 1 < executorsToRun.length) {
            final nextExec = executorsToRun[currentIndex + 1];
            if (nextExec.executionPlan != null) {
              _addEntry(
                'info',
                '[$execName] Next executor "${nextExec.name}" is scheduled independently. Stopping sequential run.',
              );
              break;
            }
            currentExecutor = nextExec;
          } else {
            break;
          }
        }
      }

      final chatStats = {
        'cumulativeTokens':
            accumulatedPromptTokens + accumulatedCompletionTokens,
        'toolCalls': accumulatedToolCallCount,
        'totalMessages': messages.length,
        'totalSentChars': 0,
        'lastRequestCostUsd': 0.0,
        'sessionCostUsd': 0.0,
      };

      if (taskSuccess) {
        _addEntry('success', l.execCompleted);
      }

      final combinedOutputLog = _buildOutputLog(
        task: widget.task,
        executedSteps: executedSteps,
      );

      // Build output bundle (generates .md, .html, execution_log as needed)
      final outputBundle = await _buildTaskOutputBundle(
        task: widget.task,
        executedSteps: executedSteps,
        taskSuccess: taskSuccess,
      );

      // Show saved file paths in the dialog
      for (final path in outputBundle.savedFilePaths) {
        _addEntry('success', 'Saved: $path');
      }

      // Email delivery
      try {
        final emailOutcome = await EmailDeliveryService().sendTaskResult(
          task: widget.task,
          taskSuccess: taskSuccess,
          resultText: combinedOutputLog,
          errorText: taskSuccess
              ? null
              : (combinedOutputLog.isNotEmpty
                    ? combinedOutputLog
                    : l.execNoLlmResponse),
          attachments: outputBundle.emailAttachments,
        );
        if (emailOutcome.attempted) {
          _addEntry(
            emailOutcome.sent ? 'success' : 'error',
            emailOutcome.sent
                ? (emailOutcome.message != null
                      ? l.execEmailSentWithMsg(emailOutcome.message!)
                      : l.execEmailSent)
                : l.execEmailError(emailOutcome.message ?? 'Unknown error'),
          );
        }
      } catch (e) {
        _addEntry('error', l.execEmailError(e.toString()));
      }

      // Slack delivery
      if (widget.task.notification.slack != null) {
        try {
          final slackOutcome = await MessagingDeliveryService()
              .sendSlackTaskResult(
                task: widget.task,
                taskSuccess: taskSuccess,
                resultText: combinedOutputLog,
                errorText: taskSuccess ? null : combinedOutputLog,
                attachments: outputBundle.emailAttachments,
              );
          if (slackOutcome.attempted) {
            _addEntry(
              slackOutcome.sent ? 'success' : 'error',
              slackOutcome.sent
                  ? 'Slack: sent'
                  : 'Slack: ${slackOutcome.message ?? "failed"}',
            );
          }
        } catch (e) {
          _addEntry('error', 'Slack error: $e');
        }
      }

      // WhatsApp delivery
      if (widget.task.notification.whatsApp != null) {
        try {
          final waOutcome = await MessagingDeliveryService()
              .sendWhatsAppTaskResult(
                task: widget.task,
                taskSuccess: taskSuccess,
                resultText: combinedOutputLog,
                errorText: taskSuccess ? null : combinedOutputLog,
                attachments: outputBundle.emailAttachments,
              );
          if (waOutcome.attempted) {
            _addEntry(
              waOutcome.sent ? 'success' : 'error',
              waOutcome.sent
                  ? 'WhatsApp: sent'
                  : 'WhatsApp: ${waOutcome.message ?? "failed"}',
            );
          }
        } catch (e) {
          _addEntry('error', 'WhatsApp error: $e');
        }
      }

      // SFTP upload
      if (widget.task.notification.sftpOutput != null) {
        try {
          await TaskRunnerService().uploadToSftp(
            task: widget.task,
            sftpCfg: widget.task.notification.sftpOutput!,
            attachments: outputBundle.emailAttachments,
          );
          _addEntry('success', 'SFTP: uploaded');
        } catch (e) {
          _addEntry('error', 'SFTP error: $e');
          log.warning('[ExecDialog] SFTP upload failed: $e');
        }
      }

      // Save execution record to DB
      try {
        final execution = widget.task.execution.recordRun(
          success: taskSuccess,
          result: taskSuccess && combinedOutputLog.isNotEmpty
              ? combinedOutputLog
              : null,
          error: taskSuccess
              ? null
              : (combinedOutputLog.isNotEmpty
                    ? combinedOutputLog
                    : l.execNoLlmResponse),
          maxHistory: 10,
          tokensUsed: chatStats['cumulativeTokens'] as int?,
          toolCallCount: chatStats['toolCalls'] as int?,
          messageCount: chatStats['totalMessages'] as int?,
          sentChars: chatStats['totalSentChars'] as int?,
          lastRequestCostUsd: (chatStats['lastRequestCostUsd'])?.toDouble(),
          sessionCostUsd: (chatStats['sessionCostUsd'])?.toDouble(),
        );
        await ref
            .read(taskDatabaseServiceProvider)
            .updateExecution(widget.task.id, execution);
      } catch (e) {
        log.warning('[ExecDialog] Failed to save execution: $e');
      }

      if (taskSuccess) _addEntry('success', l.execCompleted);

      // Task chaining — evaluate condition and trigger chained subtask
      if (taskSuccess && (widget.task.chainConfig?.hasChaining ?? false)) {
        _addEntry('info', l.execCheckChain);
        try {
          await TaskRunnerService().runChainIfConfigured(
            widget.task,
            TaskRunResult(success: true, resultText: assistantText),
          );
          _addEntry('success', l.execChainDone);
        } catch (e) {
          _addEntry('error', l.execChainError(e.toString()));
        }
      }

      if (mounted) {
        setState(() {
          _done = true;
          _success = taskSuccess;
        });
      }
    } catch (e) {
      await _msgSub?.cancel();
      _msgSub = null;

      // Save error to DB
      try {
        final execution = widget.task.execution.recordRun(
          success: false,
          error: e.toString(),
          maxHistory: 10,
        );
        await ref
            .read(taskDatabaseServiceProvider)
            .updateExecution(widget.task.id, execution);
      } catch (_) {}

      _addEntry('error', l.execError(e.toString()));
      if (mounted) {
        setState(() {
          _done = true;
          _success = false;
        });
      }
    }
  }

  Widget _buildContent(BuildContext context, bool isDark) {
    return Column(
      children: [
        // ── Header ────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
          child: Row(
            children: [
              Icon(
                _done
                    ? (_success ? Icons.check_circle : Icons.error)
                    : Icons.play_circle,
                color: _done
                    ? (_success ? Colors.green : Colors.red)
                    : Colors.blue,
                size: 22,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.task.name,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy_all, size: 20),
                tooltip: 'Copy log to clipboard',
                onPressed: () {
                  final text = _entries
                      .map(
                        (e) =>
                            '[${e.timestamp.toIso8601String().substring(11, 19)}] ${e.text}${e.details != null ? '\n${e.details}' : ''}',
                      )
                      .join('\n');
                  Clipboard.setData(ClipboardData(text: text));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Execution log copied to clipboard'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
              ),
              if (!_done)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        // ── Log list ──────────────────────────────────────────────────
        Expanded(
          child: _entries.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(40),
                    child: CircularProgressIndicator(),
                  ),
                )
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: _entries.length,
                  itemBuilder: (_, i) => _buildEntryTile(_entries[i], isDark),
                ),
        ),
        const Divider(height: 1),
        // ── Footer ────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _done ? () => Navigator.of(context).pop() : null,
                child: const Text('Schließen'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<ActiveTaskState?>(activeTaskProvider, (prev, next) {
      if (next == null) return;
      if (next.isInitializing &&
          next.statusMessage.isNotEmpty &&
          next.statusMessage != (prev?.statusMessage ?? '')) {
        _addEntry('info', next.statusMessage);
      }
    });

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isMobile = MediaQuery.of(context).size.width < 600;

    if (isMobile) {
      return Dialog.fullscreen(
        child: SafeArea(child: _buildContent(context, isDark)),
      );
    }

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 680,
          maxHeight: MediaQuery.of(context).size.height * 0.82,
        ),
        child: _buildContent(context, isDark),
      ),
    );
  }

  String _formatTimestamp(DateTime dt) {
    final hour = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    final sec = dt.second.toString().padLeft(2, '0');
    return '[$hour:$min:$sec]';
  }

  Widget _buildEntryTile(_ExecEntry e, bool isDark) {
    final (IconData icon, Color color, bool bold) = switch (e.type) {
      'assistant' => (Icons.smart_toy_outlined, Colors.blue.shade300, false),
      'tool' => (Icons.build_outlined, Colors.orange.shade400, false),
      'system' => (Icons.lock_outline, Colors.purple.shade300, false),
      'success' => (Icons.check_circle_outline, Colors.green, true),
      'error' => (Icons.error_outline, Colors.red, false),
      _ /* info */ => (Icons.info_outline, Colors.grey, false),
    };

    final tile = Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 15, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '${_formatTimestamp(e.timestamp)} ',
                    style: TextStyle(
                      color: Colors.grey[500],
                      fontSize: 11,
                      fontWeight: FontWeight.normal,
                    ),
                  ),
                  TextSpan(
                    text: e.text,
                    style: TextStyle(
                      fontSize: 13,
                      color: e.type == 'error'
                          ? Colors.red[300]
                          : isDark
                          ? Colors.grey[200]
                          : null,
                      fontWeight: bold ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Tap-to-expand icon for entries with details (system prompt, full tool result)
          if (e.details != null)
            GestureDetector(
              onTap: () => showDialog<void>(
                context: context,
                builder: (_) => AlertDialog(
                  title: Text(
                    e.type == 'system' ? 'System Prompt' : 'Full Result',
                  ),
                  content: SingleChildScrollView(
                    child: SelectableText(
                      e.details!,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.only(left: 4, top: 1),
                child: Icon(
                  Icons.open_in_full,
                  size: 13,
                  color: Colors.grey[500],
                ),
              ),
            ),
        ],
      ),
    );

    return tile;
  }
}

class _ExecEntry {
  final String type; // info | assistant | tool | system | success | error
  final String text;
  final String?
  details; // Full text shown on tap (system prompt, full tool result)
  final DateTime timestamp;
  const _ExecEntry({
    required this.type,
    required this.text,
    this.details,
    required this.timestamp,
  });
}
