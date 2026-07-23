import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../config/app_theme.dart';
import '../models/workflow_task.dart';
import '../models/mcp_models.dart';
import '../providers/active_task_provider.dart';
import '../providers/database_providers.dart';
import '../providers/server_mode_provider.dart';
import '../providers/llm_settings_provider.dart';
import '../widgets/step_list_editor.dart';
import '../widgets/schedule_picker_dialog.dart';
import '../l10n/app_localizations.dart';
import '../services/app_preferences_service.dart';
import '../services/email_delivery_service.dart';
import '../services/messaging_delivery_service.dart';
import '../services/server_api_client.dart';
import '../services/task_runner_service.dart';
import '../services/llm_settings_service.dart';

import 'workflow_edit_screen.dart';
import '../widgets/llm_settings_form_widget.dart';
import '../mcp/internal_mcp_registry.dart';
import '../services/external_tools_settings_service.dart';
import '../services/github_mcp_library_service.dart';
import '../services/github_mcp_runtime_service.dart';
import '../models/github_mcp_server_definition.dart';
import '../mcp/servers/py_bridge_mcp_server.dart';
import '../models/function_hint.dart';
import '../services/function_hint_database_service.dart';

// ═══════════════════════════════════════════════════════════════════
// Custom Grid Painter
// ═══════════════════════════════════════════════════════════════════
class GridBackgroundPainter extends CustomPainter {
  final Brightness brightness;
  GridBackgroundPainter({required this.brightness});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = brightness == Brightness.dark
          ? Colors.white.withValues(alpha: 0.04)
          : Colors.black.withValues(alpha: 0.03)
      ..strokeWidth = 1;

    const step = 30.0;
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ═══════════════════════════════════════════════════════════════════
// Visual Builder Screen
// ═══════════════════════════════════════════════════════════════════
class VisualBuilderScreen extends ConsumerStatefulWidget {
  final WorkflowTask task;

  const VisualBuilderScreen({super.key, required this.task});

  @override
  ConsumerState<VisualBuilderScreen> createState() =>
      _VisualBuilderScreenState();
}

class _VisualBuilderScreenState extends ConsumerState<VisualBuilderScreen> {
  late WorkflowTask _task;
  final _transformationController = TransformationController();
  final _canvasKey = GlobalKey();

  // Execution state variables
  bool _isRunning = false;
  bool _isCancelRequested = false;
  final Map<String, String> _executorStatus =
      {}; // 'running', 'success', 'error', 'inactive'
  final List<_ExecEntry> _executionLogs = [];
  bool _showLogsFloat = false;
  final ScrollController _logScroll = ScrollController();
  StreamSubscription<ChatMessage>? _msgSub;
  double? _logLeft;
  double? _logTop;

  @override
  void initState() {
    super.initState();
    _task = widget.task;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _centerCanvas();
    });
  }

  @override
  void dispose() {
    _msgSub?.cancel();
    _logScroll.dispose();
    super.dispose();
  }

  void _centerCanvas() {
    if (!mounted) return;
    final renderBox = context.findRenderObject() as RenderBox?;
    final canvasBox =
        _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null || canvasBox == null) return;

    final viewportSize = renderBox.size;
    final canvasSize = canvasBox.size;

    final x = (viewportSize.width - canvasSize.width) / 2;
    final y = (viewportSize.height - canvasSize.height) / 2;

    _transformationController.value = Matrix4.identity()
      ..setTranslationRaw(x, y, 0.0);
  }

  Future<void> _reloadTask() async {
    final repo = ref.read(taskRepositoryProvider);
    final updated = await repo.getTask(_task.id);
    if (updated != null) {
      setState(() {
        _task = updated;
      });
    }
  }

  Future<void> _openOrchestratorEditor() async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => WorkflowEditScreen(task: _task)),
    );
    if (result == true) {
      await _reloadTask();
    }
  }

  Future<void> _addAgent() async {
    final newId = const Uuid().v4();
    final newName = 'Agent ${_task.agents.length + 1}';
    final newExec = Agent(
      id: newId,
      name: newName,
      prompt: '',
      llmConfig: null,
      mcpTools: const [],
      internalMcps: const [],
    );

    final updatedRules = List<Edge>.from(_task.edges);
    if (_task.agents.isNotEmpty) {
      final lastExec = _task.agents.last;
      final hasExistingRules = updatedRules.any(
        (r) => r.sourceAgentId == lastExec.id,
      );
      if (!hasExistingRules) {
        updatedRules.add(
          Edge(
            id: const Uuid().v4(),
            sourceAgentId: lastExec.id,
            variable: 'task_result',
            operator: 'sequential',
            value: '',
            targetAgentId: newId,
          ),
        );
      }
    }

    final updatedTask = _task.copyWith(
      agents: [..._task.agents, newExec],
      edges: updatedRules,
    );

    await ref.read(taskListProvider.notifier).saveTask(updatedTask);
    setState(() {
      _task = updatedTask;
    });

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Added new agent: $newName')));
  }

  List<String> _getChildren(String nodeId) {
    if (nodeId == 'orchestrator') {
      if (_task.agents.isNotEmpty) {
        return [_task.agents.first.id];
      }
      return const [];
    }

    // Find routing targets for this agent
    final rules = _task.edges
        .where((r) => r.sourceAgentId == nodeId)
        .toList();
    if (rules.isNotEmpty) {
      if (rules.first.operator == 'stop') {
        return const [];
      }
      return rules
          .map((r) => r.targetAgentId)
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList();
    }

    // Default sequential flow to the next index
    final idx = _task.agents.indexWhere((e) => e.id == nodeId);
    if (idx != -1 && idx < _task.agents.length - 1) {
      final nextExec = _task.agents[idx + 1];
      final nextId = nextExec.id;
      final isTargetOfAnyRule = _task.edges.any(
        (r) => r.targetAgentId == nextId && r.operator != 'stop',
      );
      final isNextScheduled = nextExec.executionPlan != null;
      print(
        '[VisualBuilder] nodeId: $nodeId, nextId: $nextId, isTargetOfAnyRule: $isTargetOfAnyRule, isNextScheduled: $isNextScheduled',
      );
      if (!isTargetOfAnyRule && !isNextScheduled) {
        return [nextId];
      }
    }

    return const [];
  }

  Widget _buildAgentPicture(String name, int index) {
    final gradients = [
      const RadialGradient(
        colors: [Color(0xFF8B5CF6), Color(0xFF6D28D9)],
        center: Alignment.topLeft,
        radius: 1.0,
      ),
      const RadialGradient(
        colors: [Color(0xFF06B6D4), Color(0xFF0891B2)],
        center: Alignment.topLeft,
        radius: 1.0,
      ),
      const RadialGradient(
        colors: [Color(0xFF10B981), Color(0xFF047857)],
        center: Alignment.topLeft,
        radius: 1.0,
      ),
      const RadialGradient(
        colors: [Color(0xFFF59E0B), Color(0xFFD97706)],
        center: Alignment.topLeft,
        radius: 1.0,
      ),
      const RadialGradient(
        colors: [Color(0xFFEC4899), Color(0xFFBE185D)],
        center: Alignment.topLeft,
        radius: 1.0,
      ),
    ];

    final icons = [
      Icons.smart_toy_rounded,
      Icons.psychology_rounded,
      Icons.explore_rounded,
      Icons.insights_rounded,
      Icons.analytics_rounded,
    ];

    final gradient = gradients[index % gradients.length];
    final icon = icons[index % icons.length];

    return Container(
      width: 60,
      height: 60,
      decoration: BoxDecoration(
        gradient: gradient,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 6,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Center(child: Icon(icon, size: 32, color: Colors.white)),
    );
  }

  Widget _buildNodeCard(String nodeId) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textTheme = Theme.of(context).textTheme;

    if (nodeId == 'orchestrator') {
      final bool showEntrypointProgress = _isRunning &&
          !_executorStatus.values.any((status) => status == 'running');
      final String progressText = 'Thinking...';

      final orchestratorCard = Card(
        elevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: const Color(0xFF7C3AED).withValues(alpha: 0.4),
            width: 1.5,
          ),
        ),
        color: isDark ? const Color(0xFF1E1E2E) : Colors.white,
        child: Container(
          width: 250,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.hub_outlined,
                    color: AppTheme.primaryBlue,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Orchestrator',
                      style: textTheme.labelSmall?.copyWith(
                        color: AppTheme.primaryBlue,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.edit, size: 18),
                    onPressed: _openOrchestratorEditor,
                    tooltip: 'Edit task in full editor',
                    constraints: const BoxConstraints(),
                    padding: EdgeInsets.zero,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _task.name,
                style: textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (_task.description != null &&
                  _task.description!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  _task.description!,
                  style: textTheme.bodySmall?.copyWith(color: Colors.grey[500]),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const Divider(height: 20),
              ElevatedButton.icon(
                onPressed: _isRunning ? null : _addAgent,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add Agent'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryBlue,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                ),
              ),
            ],
          ),
        ),
      );

      return Stack(
        children: [
          orchestratorCard,
          if (showEntrypointProgress)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const CircularProgressIndicator(color: Color(0xFF7C3AED)),
                      const SizedBox(height: 8),
                      Text(
                        progressText,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      );
    }

    final idx = _task.agents.indexWhere((e) => e.id == nodeId);
    if (idx == -1) return const SizedBox();
    final exec = _task.agents[idx];

    final status = _executorStatus[exec.id];
    final bool isRunning = status == 'running';
    final bool isSuccess = status == 'success';
    final bool isError = status == 'error';
    final bool isInactive = status == 'inactive';

    final cardWidget = Card(
      elevation: 4,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isDark
              ? Colors.teal[800]!.withValues(alpha: 0.5)
              : Colors.teal[200]!.withValues(alpha: 0.5),
          width: 1,
        ),
      ),
      color: isDark ? const Color(0xFF1E282D) : const Color(0xFFF0FDF4),
      child: Container(
        width: 230,
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            _buildAgentPicture(exec.name, idx),
            const SizedBox(height: 12),
            Text(
              exec.name,
              style: textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Text(
              exec.prompt.isNotEmpty ? exec.prompt : 'No instructions set',
              style: textTheme.bodySmall?.copyWith(color: Colors.grey[500]),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
            const Divider(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _openAgentEditor(exec),
                  icon: const Icon(Icons.tune, size: 14),
                  label: const Text('Configure'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.teal[700],
                    side: BorderSide(color: Colors.teal[400]!),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                  ),
                ),
                if (idx > 0)
                  IconButton(
                    icon: const Icon(
                      Icons.delete_outline,
                      color: Colors.redAccent,
                      size: 20,
                    ),
                    onPressed: () => _deleteAgent(idx),
                    tooltip: 'Delete agent',
                  ),
              ],
            ),
          ],
        ),
      ),
    );

    return Stack(
      children: [
        cardWidget,
        // Top Right - Prompt Note Icon
        Positioned(
          top: 6,
          right: 6,
          child: Material(
            type: MaterialType.transparency,
            child: IconButton(
              icon: const Icon(
                Icons.note_alt_outlined,
                size: 18,
                color: Colors.teal,
              ),
              onPressed: () {
                showDialog<void>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text('Prompt: ${exec.name}'),
                    content: SingleChildScrollView(
                      child: SelectableText(
                        exec.prompt.isNotEmpty ? exec.prompt : 'No prompt set',
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                );
              },
              tooltip: 'Show Prompt',
              constraints: const BoxConstraints(),
              padding: const EdgeInsets.all(4),
            ),
          ),
        ),
        // Bottom Right - Output Channel Icon
        Positioned(
          bottom: 6,
          right: 6,
          child: Material(
            type: MaterialType.transparency,
            child: _buildOutputChannelIcon(context, exec),
          ),
        ),
        // Execution overlay status
        if (isRunning) ...[
          (() {
            final (provider, model) = _resolveLlmInfo(exec);
            return Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const CircularProgressIndicator(color: Colors.teal),
                        const SizedBox(height: 8),
                        const Text(
                          'Running...',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '$provider: $model',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.8),
                            fontSize: 10,
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          })(),
        ],
        if (isSuccess || isError || isInactive)
          Positioned(
            top: 6,
            left: 6,
            child: Material(
              type: MaterialType.transparency,
              child: IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                icon: Icon(
                  isSuccess
                      ? Icons.check_circle
                      : (isError ? Icons.error : Icons.remove_circle_outline),
                  color: isSuccess
                      ? Colors.green
                      : (isError ? Colors.red : Colors.grey),
                  size: 24,
                ),
                onPressed: () => _showAgentLogs(exec),
                tooltip: isSuccess
                    ? 'Success (View logs)'
                    : (isError ? 'Failed (View logs)' : 'Inactive (View logs)'),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _deleteAgent(int index) async {
    final exec = _task.agents[index];
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Agent'),
        content: Text('Are you sure you want to delete "${exec.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final updatedExecutors = List<Agent>.from(_task.agents)
      ..removeAt(index);
    // Cleanup rules
    final updatedRules = _task.edges
        .where(
          (r) => r.sourceAgentId != exec.id && r.targetAgentId != exec.id,
        )
        .toList();

    final updatedTask = _task.copyWith(
      agents: updatedExecutors,
      edges: updatedRules,
    );
    await ref.read(taskListProvider.notifier).saveTask(updatedTask);
    setState(() {
      _task = updatedTask;
    });
  }

  Future<void> _openAgentEditor(Agent exec) async {
    final updated = await Navigator.of(context).push<WorkflowTask>(
      MaterialPageRoute(
        builder: (_) => AgentEditScreen(executor: exec, parentTask: _task),
      ),
    );
    if (updated != null) {
      setState(() {
        _task = updated;
      });
      await _reloadTask();
    }
  }

  Widget _buildReferenceNode(String nodeId) {
    final idx = _task.agents.indexWhere((e) => e.id == nodeId);
    final name = idx != -1 ? _task.agents[idx].name : 'Unknown';

    return ActionChip(
      avatar: const Icon(Icons.link, size: 14),
      label: Text('Loop back to $name'),
      onPressed: () {},
      backgroundColor: Colors.teal[50],
    );
  }

  Widget _buildConnectionLine(
    String parentId,
    String childId, {
    required bool isVertical,
    bool skipLine = false,
  }) {
    final rules = _task.edges
        .where(
          (r) =>
              r.sourceAgentId == parentId && r.targetAgentId == childId,
        )
        .toList();
    final rule = rules.isNotEmpty ? rules.first : null;

    IconData iconData = isVertical ? Icons.arrow_downward : Icons.arrow_forward;
    Color iconColor = Colors.teal;
    String tooltipText = 'Sequential Flow';

    if (parentId == 'orchestrator') {
      iconData = isVertical ? Icons.arrow_downward : Icons.arrow_forward;
      iconColor = AppTheme.primaryBlue;
      tooltipText = 'Entrypoint';
    } else if (rule != null) {
      if (rule.operator == 'llm_eval' || rule.operator == 'evaluated_by_llm') {
        iconData = Icons.auto_awesome;
        iconColor = Colors.purple;
        tooltipText = rule.value;
      } else if (rule.operator == 'sequential' || rule.operator == 'always') {
        iconData = isVertical ? Icons.arrow_downward : Icons.arrow_forward;
        iconColor = Colors.teal;
        tooltipText = 'Sequential Flow';
      } else {
        iconData = Icons.call_split;
        iconColor = Colors.orange;
        tooltipText = rule.value;
      }
    }

    final iconWidget = Tooltip(
      message: tooltipText,
      triggerMode: TooltipTriggerMode.tap,
      child: Container(
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          color: iconColor.withValues(alpha: 0.15),
          shape: BoxShape.circle,
          border: Border.all(color: iconColor, width: 1.2),
        ),
        child: Icon(iconData, size: 14, color: iconColor),
      ),
    );

    if (skipLine) {
      return isVertical
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 2, height: 10, color: Colors.teal[300]),
                iconWidget,
                Container(width: 2, height: 10, color: Colors.teal[300]),
              ],
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 10, height: 2, color: Colors.teal[300]),
                iconWidget,
                Container(width: 10, height: 2, color: Colors.teal[300]),
              ],
            );
    }

    return isVertical
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 2, height: 15, color: Colors.teal[300]),
              iconWidget,
              Container(width: 2, height: 15, color: Colors.teal[300]),
            ],
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 15, height: 2, color: Colors.teal[300]),
              iconWidget,
              Container(width: 15, height: 2, color: Colors.teal[300]),
            ],
          );
  }

  Widget _buildLinesAndChildrenVertical(
    String parentId,
    List<String> childrenIds,
    Set<String> visited,
  ) {
    if (childrenIds.length == 1) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildConnectionLine(parentId, childrenIds.first, isVertical: true),
          _buildNodeTree(childrenIds.first, visited),
        ],
      );
    }

    final lineDown = Container(width: 2, height: 20, color: Colors.teal[300]);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        lineDown,
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: childrenIds.map((childId) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 262,
                  child: Row(
                    children: [
                      Expanded(
                        child: Container(
                          height: 2,
                          color: childId == childrenIds.first
                              ? Colors.transparent
                              : Colors.teal[300],
                        ),
                      ),
                      Container(width: 2, height: 10, color: Colors.teal[300]),
                      Expanded(
                        child: Container(
                          height: 2,
                          color: childId == childrenIds.last
                              ? Colors.transparent
                              : Colors.teal[300],
                        ),
                      ),
                    ],
                  ),
                ),
                _buildConnectionLine(
                  parentId,
                  childId,
                  isVertical: true,
                  skipLine: true,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _buildNodeTree(childId, visited),
                ),
              ],
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildLinesAndChildrenHorizontal(
    String parentId,
    List<String> childrenIds,
    Set<String> visited,
  ) {
    if (childrenIds.length == 1) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildConnectionLine(parentId, childrenIds.first, isVertical: false),
          _buildNodeTree(childrenIds.first, visited),
        ],
      );
    }

    final lineRight = Container(width: 20, height: 2, color: Colors.teal[300]);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        lineRight,
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: childrenIds.map((childId) {
            return IntrinsicHeight(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Column(
                    children: [
                      Expanded(
                        child: Container(
                          width: 2,
                          color: childId == childrenIds.first
                              ? Colors.transparent
                              : Colors.teal[300],
                        ),
                      ),
                      Container(width: 10, height: 2, color: Colors.teal[300]),
                      Expanded(
                        child: Container(
                          width: 2,
                          color: childId == childrenIds.last
                              ? Colors.transparent
                              : Colors.teal[300],
                        ),
                      ),
                    ],
                  ),
                  _buildConnectionLine(
                    parentId,
                    childId,
                    isVertical: false,
                    skipLine: true,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: _buildNodeTree(childId, visited),
                  ),
                ],
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildNodeTree(String nodeId, Set<String> visited) {
    if (visited.contains(nodeId)) {
      return _buildReferenceNode(nodeId);
    }
    visited.add(nodeId);

    final nodeWidget = _buildNodeCard(nodeId);
    final children = _getChildren(nodeId);

    if (children.isEmpty) {
      return nodeWidget;
    }

    final isMobile = MediaQuery.of(context).size.width < 800;

    return isMobile
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              nodeWidget,
              _buildLinesAndChildrenVertical(nodeId, children, visited),
            ],
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              nodeWidget,
              _buildLinesAndChildrenHorizontal(nodeId, children, visited),
            ],
          );
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final Set<String> visited = {};
    final rootTree = _buildNodeTree('orchestrator', visited);

    final unvisitedIds = _task.agents
        .map((e) => e.id)
        .where((id) => !visited.contains(id))
        .toList();

    Widget canvasContent;
    if (unvisitedIds.isEmpty) {
      canvasContent = rootTree;
    } else {
      final unvisitedTrees = unvisitedIds.map((id) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: _buildNodeTree(id, Set<String>.from(visited)),
        );
      }).toList();

      final isMobile = MediaQuery.of(context).size.width < 800;

      canvasContent = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          rootTree,
          const SizedBox(height: 60),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  color: Colors.orange,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  'Disconnected / Independent Flows (${unvisitedIds.length})',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.orange,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          if (isMobile)
            Column(mainAxisSize: MainAxisSize.min, children: unvisitedTrees)
          else
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: unvisitedTrees,
            ),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('Visual Builder: ${_task.name}'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () async {
            if (_isRunning) {
              await _cancelTaskExecution();
            }
            if (context.mounted) {
              Navigator.of(context).pop();
            }
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _isRunning ? null : _addAgent,
            tooltip: 'Add agent',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _isRunning ? null : _reloadTask,
            tooltip: 'Refresh view',
          ),
          IconButton(
            icon: _isRunning
                ? const Icon(Icons.stop, color: Colors.red)
                : const Icon(Icons.play_arrow, color: Colors.green),
            onPressed: _isRunning ? _cancelTaskExecution : _executeTask,
            tooltip: _isRunning ? l.cancelExecution : 'Execute task',
          ),
          IconButton(
            icon: const Icon(Icons.receipt_long),
            onPressed: _showLogWindow,
            tooltip: 'Show execution log',
          ),
        ],
      ),
      body: PopScope(
        canPop: true,
        onPopInvokedWithResult: (didPop, result) {
          if (_isRunning) {
            unawaited(_cancelTaskExecution());
          }
        },
        child: SafeArea(
          child: Stack(
          children: [
            InteractiveViewer(
              transformationController: _transformationController,
              boundaryMargin: const EdgeInsets.all(1000),
              minScale: 0.2,
              maxScale: 2.0,
              constrained: false,
              child: CustomPaint(
                key: _canvasKey,
                painter: GridBackgroundPainter(
                  brightness: Theme.of(context).brightness,
                ),
                child: Container(
                  padding: const EdgeInsets.all(250),
                  child: canvasContent,
                ),
              ),
            ),
            if (_showLogsFloat && MediaQuery.of(context).size.width >= 800)
              _buildFloatingLogWindow(context),
          ],
        ),
      ),
    ),
  );
}

  Widget _buildOutputChannelIcon(BuildContext context, Agent exec) {
    IconData icon;
    Color color;
    String label;
    String details;

    final notif = exec.notification;
    if (notif.download != null) {
      icon = Icons.file_download_outlined;
      color = Colors.teal;
      label = 'File Output';
      details =
          'Download Path: ${notif.download!.downloadPath ?? "(Default downloads folder)"}\nFileName Pattern: ${notif.download!.fileNamePattern ?? "result_{date}.txt"}\nZip Output: ${notif.zipOutputFiles}\nAdd Log: ${notif.addExecutionLog}';
    } else if (notif.sftpOutput != null) {
      icon = Icons.upload_file_outlined;
      color = Colors.indigo;
      label = 'SFTP Output';
      details =
          'Remote Path: ${notif.sftpOutput!.remotePath}\nUse global settings: ${notif.sftpOutput!.useConfiguredSshServer}\nCustom host: ${notif.sftpOutput!.useConfiguredSshServer ? "No" : notif.sftpOutput!.host}';
    } else if (notif.email != null) {
      icon = Icons.email_outlined;
      color = Colors.blue;
      label = 'Email';
      details =
          'Send to: ${notif.email!.recipients.join(", ")}\nSubject: ${notif.email!.subject ?? "(Auto-generated)"}\nCondition: ${notif.email!.sendCondition}';
    } else if (notif.slack != null) {
      icon = Icons.chat_bubble_outline;
      color = Colors.teal;
      label = 'Slack';
      details =
          'Channel: ${notif.slack!.overrideChannel ?? "(Global default)"}\nCondition: ${notif.slack!.sendCondition}';
    } else if (notif.whatsApp != null) {
      icon = Icons.phone_android_outlined;
      color = Colors.green;
      label = 'WhatsApp';
      details =
          'Recipient: ${notif.whatsApp!.overrideRecipient ?? "(Global default)"}\nCondition: ${notif.whatsApp!.sendCondition}';
    } else if (notif.push != null) {
      icon = Icons.notifications_active_outlined;
      color = Colors.orange;
      label = 'Push Notification';
      details =
          'Title: ${notif.push!.title ?? "(Auto-generated)"}\nCondition: ${notif.push!.condition}';
    } else {
      icon = Icons.folder_open;
      color = Colors.grey;
      label = 'Local Only';
      details = 'No external output channel configured. Results saved locally.';
    }

    return IconButton(
      icon: Icon(icon, size: 18, color: color),
      onPressed: () {
        showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Output Channel: $label'),
            content: Text(details),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          ),
        );
      },
      tooltip: 'Output Channel details',
      constraints: const BoxConstraints(),
      padding: const EdgeInsets.all(4),
    );
  }

  void _showLogWindow() {
    final isMobile = MediaQuery.of(context).size.width < 800;
    if (isMobile) {
      showDialog<void>(
        context: context,
        builder: (context) {
          final isDark = Theme.of(context).brightness == Brightness.dark;
          return Dialog.fullscreen(
            child: Scaffold(
              appBar: AppBar(
                title: const Text('Execution Log'),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.copy),
                    onPressed: () => _copyLogsToClipboard(),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              body: _executionLogs.isEmpty
                  ? const Center(child: Text('No log entries yet.'))
                  : ListView.builder(
                      controller: _logScroll,
                      padding: const EdgeInsets.all(12),
                      itemCount: _executionLogs.length,
                      itemBuilder: (context, i) =>
                          _buildEntryTile(_executionLogs[i], isDark),
                    ),
            ),
          );
        },
      );
    } else {
      setState(() {
        _showLogsFloat = !_showLogsFloat;
      });
    }
  }

  Widget _buildFloatingLogWindow(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    final double initialLeft = screenWidth - 440;
    final double initialTop = screenHeight - 650;

    return StatefulBuilder(
      builder: (context, setLocalState) {
        final double left = _logLeft ?? initialLeft;
        final double top = _logTop ?? initialTop;

        return Positioned(
          left: left,
          top: top,
          child: Card(
            elevation: 12,
            shadowColor: Colors.black.withValues(alpha: 0.3),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(
                color: isDark ? Colors.grey[800]! : Colors.grey[200]!,
                width: 1,
              ),
            ),
            color: isDark ? const Color(0xFF1E1E2E) : Colors.white,
            child: SizedBox(
              width: 400,
              height: 480,
              child: Column(
                children: [
                  GestureDetector(
                    onPanUpdate: (details) {
                      setLocalState(() {
                        _logLeft = ((_logLeft ?? initialLeft) + details.delta.dx).clamp(
                          0.0,
                          screenWidth - 400.0,
                        );
                        _logTop = ((_logTop ?? initialTop) + details.delta.dy).clamp(
                          0.0,
                          screenHeight - 480.0,
                        );
                      });
                    },
                    onPanEnd: (_) {
                      setState(() {});
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.primaryBlue,
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(16),
                        ),
                      ),
                      child: Row(
                        children: [
                      const Icon(
                        Icons.receipt_long,
                        color: Colors.white,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'Execution Log',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(
                          Icons.copy,
                          color: Colors.white,
                          size: 18,
                        ),
                        onPressed: () => _copyLogsToClipboard(),
                        constraints: const BoxConstraints(),
                        padding: EdgeInsets.zero,
                      ),
                      const SizedBox(width: 12),
                      IconButton(
                        icon: const Icon(
                          Icons.close,
                          color: Colors.white,
                          size: 18,
                        ),
                        onPressed: () {
                          setState(() {
                            _showLogsFloat = false;
                          });
                        },
                        constraints: const BoxConstraints(),
                        padding: EdgeInsets.zero,
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: _executionLogs.isEmpty
                    ? const Center(child: Text('No log entries yet.'))
                    : ListView.builder(
                        controller: _logScroll,
                        padding: const EdgeInsets.all(12),
                        itemCount: _executionLogs.length,
                        itemBuilder: (context, i) =>
                            _buildEntryTile(_executionLogs[i], isDark),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
      },
    );
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

    return Padding(
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
  }

  String _formatTimestamp(DateTime dt) {
    final hour = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    final sec = dt.second.toString().padLeft(2, '0');
    return '[$hour:$min:$sec]';
  }

  (String, String) _resolveLlmInfo(Agent exec) {
    final settings = ref.read(llmSettingsProvider);
    String? provider = exec.llmConfig?.provider;
    String? model = exec.llmConfig?.model;

    if (provider?.toLowerCase() == 'llm2') {
      provider = settings.provider2.configKey;
      if (model == null || model.isEmpty) model = settings.model2;
    }

    if (provider == null || provider.isEmpty) {
      provider = settings.provider.configKey;
      model = settings.model;
    }

    final resolvedProvider = LlmProvider.fromConfigKey(provider);
    final String displayProvider;
    switch (resolvedProvider) {
      case LlmProvider.gemini:
        displayProvider = 'Gemini';
      case LlmProvider.openai:
        displayProvider = 'OpenAI';
      case LlmProvider.claude:
        displayProvider = 'Claude';
      case LlmProvider.mistral:
        displayProvider = 'Mistral';
      case LlmProvider.ollama:
        displayProvider = 'Ollama';
      case LlmProvider.openaiCompatible:
        displayProvider = 'OpenAI-Compatible';
      case LlmProvider.embedded:
        displayProvider = 'Embedded';
      default:
        displayProvider = provider.toUpperCase();
    }

    final displayModel = (model == null || model.isEmpty) ? 'default' : model;
    return (displayProvider, displayModel);
  }

  void _copyLogsToClipboard({List<_ExecEntry>? customLogs}) {
    final sb = StringBuffer();
    final logsToCopy = customLogs ?? _executionLogs;
    for (final e in logsToCopy) {
      final timeStr = _formatTimestamp(e.timestamp);
      sb.writeln('$timeStr ${e.text}');
      if (e.details != null && e.details!.isNotEmpty) {
        sb.writeln('Details:\n${e.details}');
      }
      sb.writeln();
    }

    final logText = sb.toString().trim();
    if (logText.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No log entries to copy')),
      );
      return;
    }

    Clipboard.setData(ClipboardData(text: logText));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Logs copied to clipboard')),
    );
  }

  void _addEntry(String type, String text, {String? details}) {
    if (!mounted) return;
    setState(() {
      _executionLogs.add(
        _ExecEntry(
          type: type,
          text: text,
          details: details,
          timestamp: DateTime.now(),
        ),
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.animateTo(
          _logScroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _addRemoteLog(String line) {
    String cleanLine = line;
    if (line.contains(']')) {
      cleanLine = line.substring(line.indexOf(']') + 1).trim();
    }

    String? matchedExecutorId;
    for (final exec in _task.agents) {
      if (cleanLine.startsWith('[${exec.name}]') ||
          line.contains('Executing step "${exec.name}"') ||
          cleanLine.contains('Executing step "${exec.name}"')) {
        matchedExecutorId = exec.id;
        break;
      }
    }

    if (matchedExecutorId != null) {
      setState(() {
        for (final key in _executorStatus.keys.toList()) {
          final val = _executorStatus[key];
          if (val == 'running' && key != matchedExecutorId) {
            _executorStatus[key] = 'success';
          }
        }
        _executorStatus[matchedExecutorId!] = 'running';
      });
    }

    _addEntry('info', line);
  }

  Future<void> _cancelTaskExecution() async {
    _addEntry('error', 'Cancellation requested...');
    setState(() {
      _isCancelRequested = true;
    });

    final serverMode = ref.read(serverModeProvider).value;
    final isRemote = serverMode?.isRemote ?? false;

    if (isRemote) {
      final serverClient = ref.read(serverApiClientProvider);
      if (serverClient != null) {
        try {
          await serverClient.cancelTask(_task.id);
          _addEntry('error', 'Sent cancel request to server.');
        } catch (e) {
          _addEntry('error', 'Failed to send cancel request to server: $e');
        }
      }
    } else {
      final active = ref.read(activeTaskProvider);
      active?.chatService?.stopProcessing();
      _addEntry('error', 'Canceled local chat service processing.');
    }
  }

  void _showAgentLogs(Agent exec) {
    final isMobile = MediaQuery.of(context).size.width < 800;
    final l = L.of(context);
    final matchedLogs = _executionLogs.where((entry) {
      final lowerText = entry.text.toLowerCase();
      final lowerExec = exec.name.toLowerCase();
      return lowerText.contains('[$lowerExec]') ||
             lowerText.contains('executing step "$lowerExec"') ||
             lowerText.contains('step "$lowerExec"');
    }).toList();

    if (isMobile) {
      showDialog<void>(
        context: context,
        builder: (context) {
          final isDark = Theme.of(context).brightness == Brightness.dark;
          return Dialog.fullscreen(
            child: Scaffold(
              appBar: AppBar(
                title: Text(exec.name),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.copy),
                    onPressed: () => _copyLogsToClipboard(customLogs: matchedLogs),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              body: matchedLogs.isEmpty
                  ? Center(child: Text(l.noAgentLogs))
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: matchedLogs.length,
                      itemBuilder: (context, i) =>
                          _buildEntryTile(matchedLogs[i], isDark),
                    ),
            ),
          );
        },
      );
    } else {
      showDialog<void>(
        context: context,
        builder: (context) {
          final isDark = Theme.of(context).brightness == Brightness.dark;
          return AlertDialog(
            title: Text(l.agentLogsTitle(exec.name)),
            content: SizedBox(
              width: 600,
              height: 400,
              child: matchedLogs.isEmpty
                  ? Center(child: Text(l.noAgentLogs))
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: matchedLogs.length,
                      itemBuilder: (context, i) =>
                          _buildEntryTile(matchedLogs[i], isDark),
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => _copyLogsToClipboard(customLogs: matchedLogs),
                child: const Text('Copy Logs'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          );
        },
      );
    }
  }

  Future<void> _executeTask() async {
    if (_isRunning) return;
    setState(() {
      _isRunning = true;
      _isCancelRequested = false;
      _executorStatus.clear();
      _executionLogs.clear();
      _showLogsFloat = true;
    });

    final serverMode = ref.read(serverModeProvider).value;
    final isRemote = serverMode?.isRemote ?? false;
    final serverClient = isRemote ? ref.read(serverApiClientProvider) : null;

    if (isRemote && serverClient != null) {
      await _runRemote(serverClient);
    } else {
      await _runLocal();
    }
  }

  Future<void> _runRemote(ServerApiClient serverClient) async {
    final l = L.of(context);
    try {
      _addEntry('info', l.execInitializing);
      final taskId = _task.id;
      final runRequestedAt = DateTime.now().toUtc();

      final taskBefore = await serverClient.getTask(taskId);
      final lastRunBefore = taskBefore?.execution.lastRun;

      _addEntry('info', 'Sending task to server...');
      await serverClient.runTask(taskId);

      _addEntry('info', 'Waiting for server result...');

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

        try {
          final logsResponse = await serverClient.getTaskExecutionLogs(
            taskId,
            timeout: pollRequestTimeout,
          );
          final liveLogs = logsResponse?['live_logs'] as List<dynamic>?;
          if (liveLogs != null && liveLogs.length > displayedLiveLogs) {
            for (int k = displayedLiveLogs; k < liveLogs.length; k++) {
              final line = liveLogs[k].toString();
              _addRemoteLog(line);
            }
            displayedLiveLogs = liveLogs.length;
          }
        } catch (_) {}

        if (polled == null) break;

        if (isRunning == true) {
          sawTaskRunning = true;
        }

        final lastRunNow = polled.execution.lastRun;
        if (lastRunNow != null && lastRunNow != lastRunBefore) {
          completed = polled;
        }

        if (isRunning == false && (sawTaskRunning || completed != null)) {
          completed ??= polled;
          break;
        }
      }

      const detailTimeout = Duration(seconds: 15);
      Map<String, dynamic>? output;
      Map<String, dynamic>? logsResponse;

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

      final resultText = output?['text'] as String? ?? '';
      final historyRaw =
          logsResponse?['execution_history'] as List<dynamic>? ??
          const <dynamic>[];
      final history = historyRaw.whereType<Map<String, dynamic>>().toList();

      if (completed == null) {
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

        if (sawRecentHistory) {
          completed = taskBefore ?? _task;
        } else {
          _addEntry('error', 'Timed out waiting for server result.');
          setState(() {
            _isRunning = false;
            for (final key in _executorStatus.keys.toList()) {
              if (_executorStatus[key] == 'running') {
                _executorStatus[key] = 'error';
              }
            }
          });
          return;
        }
      }



      final lastServerEntry = history.isNotEmpty ? history.first : null;
      final bool? serverSuccess = lastServerEntry?['success'] as bool?;
      final taskSuccess =
          serverSuccess ??
          (completed.execution.lastError == null &&
              completed.execution.lastRun != null);

      final resultFromLog = (lastServerEntry?['result'] as String?) ?? '';
      final effectiveResultText = resultText.isNotEmpty
          ? resultText
          : resultFromLog;
      if (effectiveResultText.isNotEmpty) {
        _addEntry('assistant', effectiveResultText);
      }

      if (taskSuccess) {
        _addEntry('success', l.execCompleted);
        setState(() {
          for (final key in _executorStatus.keys.toList()) {
            if (_executorStatus[key] == 'running') {
              _executorStatus[key] = 'success';
            }
          }
        });
      } else {
        final err = completed.execution.lastError ?? l.execNoResponse;
        _addEntry('error', l.execAiError(err));
        setState(() {
          for (final key in _executorStatus.keys.toList()) {
            if (_executorStatus[key] == 'running') {
              _executorStatus[key] = 'error';
            }
          }
        });
      }
    } catch (e) {
      _addEntry('error', l.execError(e.toString()));
      setState(() {
        for (final key in _executorStatus.keys.toList()) {
          if (_executorStatus[key] == 'running') {
            _executorStatus[key] = 'error';
          }
        }
      });
    } finally {
      setState(() {
        _isRunning = false;
        for (final exec in _task.agents) {
          if (_executorStatus[exec.id] == null) {
            _executorStatus[exec.id] = 'inactive';
          }
        }
      });
    }
  }

  Future<void> _runLocal() async {
    final l = L.of(context);
    try {
      _addEntry('info', l.execInitializing);

      final List<Agent> executorsToRun = _task.agents.isNotEmpty
          ? _task.agents
          : [
              Agent(
                id: 'default',
                name: _task.name,
                prompt: _task.prompt,
                systemPrompt: _task.systemPrompt,
                llmConfig: _task.llmConfig,
                mcpTools: _task.mcpTools,
                internalMcps: _task.internalMcps,
                chatMode: _task.chatMode,
                stopAfterToolCall: _task.stopAfterToolCall,
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

      while (stepsExecuted < 50) {
        if (_isCancelRequested) {
          _addEntry('error', 'Execution cancelled by user.');
          taskSuccess = false;
          break;
        }
        stepsExecuted++;
        final stepStartTime = DateTime.now();
        final execId = currentExecutor.id;
        final execName = currentExecutor.name;

        setState(() {
          _executorStatus[execId] = 'running';
        });
        _addEntry('info', '[$execName] ${l.execInitializing}');

        final tempTask = WorkflowTask(
          id: _task.id,
          name: currentExecutor.name,
          prompt: currentExecutor.prompt,
          systemPrompt: currentExecutor.systemPrompt,
          llmConfig: currentExecutor.llmConfig,
          mcpTools: currentExecutor.mcpTools,
          internalMcps: currentExecutor.internalMcps,
          chatMode: currentExecutor.chatMode,
          stopAfterToolCall: currentExecutor.stopAfterToolCall,
          executionPlan: _task.executionPlan,
          providers: _task.providers,
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
                _addEntry('info', '[$execName] Sending prompt to AI: $shortPreview');
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

        if (_isCancelRequested || chatService.isCancelled) {
          _addEntry('error', 'Execution cancelled by user.');
          taskSuccess = false;
          setState(() {
            _executorStatus[execId] = 'error';
          });
          break;
        }

        final stepMessages = chatService.messages;
        messages.addAll(stepMessages);

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
          setState(() {
            _executorStatus[execId] = 'error';
          });
          _addEntry(
            'error',
            assistantText.isEmpty
                ? 'Empty response from LLM'
                : l.execAiError(assistantText),
          );
          try {
            await TaskRunnerService().deliverExecutorOutput(
              task: _task,
              executor: currentExecutor,
              result: TaskRunResult(
                success: false,
                resultText: assistantText,
                error: assistantText.isEmpty
                    ? 'Empty response from LLM'
                    : assistantText,
              ),
              capturedMessages: stepMessages,
              startTime: stepStartTime,
              llmService: active!.llmService!,
            );
          } catch (_) {}
          break;
        }

        previousStepOutput = assistantText;

        setState(() {
          _executorStatus[execId] = 'success';
        });

        try {
          final paths = await TaskRunnerService().deliverExecutorOutput(
            task: _task,
            executor: currentExecutor,
            result: TaskRunResult(success: true, resultText: assistantText),
            capturedMessages: stepMessages,
            startTime: stepStartTime,
            llmService: active!.llmService!,
          );
          for (final path in paths) {
            _addEntry('success', 'Saved: $path');
          }
        } catch (e) {
          _addEntry('error', 'Output delivery failed: $e');
        }

        final mcpManager = active?.mcpManager;
        if (mcpManager != null) {
          await mcpManager.clear();
        }

        String? nextExecutorId;
        final rules = _task.edges
            .where((r) => r.sourceAgentId == currentExecutor.id)
            .toList();
        final hasStopRule = rules.any((r) => r.operator == 'stop');

        if (rules.isNotEmpty && !hasStopRule) {
          for (final rule in rules) {
            final valueToCheck = previousStepOutput;
            _addEntry('info', '[$execName] Evaluating routing condition: "${rule.value}"');
            final met = await evaluateCondition(
              llmService: active!.llmService!,
              locationService: active.chatService!.locationService,
              mcpManager: active.mcpManager!,
              source: valueToCheck,
              operator: rule.operator,
              value: rule.value,
            );
            _addEntry('info', '[$execName] Condition "${rule.value}" result: ${met ? "MET (True)" : "NOT MET (False)"}');
            if (met) {
              nextExecutorId = rule.targetAgentId;
              _addEntry(
                'info',
                '[$execName] Routing condition met. Routing to $nextExecutorId',
              );
              break;
            }
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
          if (hasStopRule) {
            break;
          }
          if (rules.isNotEmpty && !hasStopRule) {
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



      if (taskSuccess) {
        _addEntry('success', l.execCompleted);
      }

      final outputBundle = await _buildTaskOutputBundle(
        task: _task,
        resultText: assistantText,
        messages: messages,
        taskSuccess: taskSuccess,
      );

      for (final path in outputBundle.savedFilePaths) {
        _addEntry('success', 'Saved: $path');
      }

      try {
        final emailOutcome = await EmailDeliveryService().sendTaskResult(
          task: _task,
          taskSuccess: taskSuccess,
          resultText: assistantText,
          errorText: taskSuccess
              ? null
              : (assistantText.isNotEmpty
                    ? assistantText
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

      if (_task.notification.slack != null) {
        try {
          final slackOutcome = await MessagingDeliveryService()
              .sendSlackTaskResult(
                task: _task,
                taskSuccess: taskSuccess,
                resultText: assistantText,
                errorText: taskSuccess ? null : assistantText,
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

      if (_task.notification.whatsApp != null) {
        try {
          final waOutcome = await MessagingDeliveryService()
              .sendWhatsAppTaskResult(
                task: _task,
                taskSuccess: taskSuccess,
                resultText: assistantText,
                errorText: taskSuccess ? null : assistantText,
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
    } catch (e) {
      _addEntry('error', l.execError(e.toString()));
    } finally {
      await _msgSub?.cancel();
      _msgSub = null;
      ref.read(activeTaskProvider.notifier).clearTask();
      setState(() {
        _isRunning = false;
        for (final exec in _task.agents) {
          if (_executorStatus[exec.id] == 'running') {
            _executorStatus[exec.id] = 'error';
          }
          if (_executorStatus[exec.id] == null) {
            _executorStatus[exec.id] = 'inactive';
          }
        }
      });
    }
  }
}

// ═══════════════════════════════════════════════════════════════════
// Agent Editor Dialog (Full Screen)
// ═══════════════════════════════════════════════════════════════════
// Agent Editor Dialog (Full Screen)
// ═══════════════════════════════════════════════════════════════════
class AgentEditScreen extends ConsumerStatefulWidget {
  final Agent executor;
  final WorkflowTask parentTask;

  const AgentEditScreen({
    super.key,
    required this.executor,
    required this.parentTask,
  });

  @override
  ConsumerState<AgentEditScreen> createState() => _AgentEditScreenState();
}

class _AgentEditScreenState extends ConsumerState<AgentEditScreen>
    with SingleTickerProviderStateMixin {
  late TabController _subTabController;

  // Controllers
  late TextEditingController _nameCtrl;
  late TextEditingController _systemPromptCtrl;
  late TextEditingController _systemPromptSkillsCtrl;
  late TextEditingController _promptCtrl;
  int _skillsUpdateGeneration = 0;

  // LLM Config Controllers
  bool _overrideLlm = false;
  late TextEditingController _llmProviderCtrl;
  late TextEditingController _llmBaseUrlCtrl;
  late TextEditingController _llmApiKeyCtrl;
  late TextEditingController _llmModelCtrl;
  late TextEditingController _temperatureCtrl;
  late TextEditingController _maxTokensCtrl;
  bool _isSlm = false;
  bool _isMultiModal = true;
  bool _thinking = false;
  bool _useNativeToolCall = true;
  bool _useSafeToolCall = false;

  // Routing Configuration
  String _routingType = 'none';
  String? _targetExecutorId;
  late List<Edge> _localRules;
  late TextEditingController _cronExpressionCtrl;
  late TextEditingController _scheduleHintCtrl;
  late TextEditingController _maxRetriesCtrl;
  late TextEditingController _retryDelayCtrl;

  // Tools Configuration
  bool _toolboxEnabled = true;
  late List<InternalMcpEntry> _localInternalMcps;
  late List<McpToolConfig> _localMcpTools;
  late Set<String> _selectedGlobalServerUrls;
  List<GithubMcpServerDefinition> _remoteGithubMcpServers = const [];
  final Map<String, List<String>> _prefetchedRemoteMcpTools = {};

  // Output Configuration
  String _outputType = 'none';
  late TextEditingController _emailToCtrl;
  late TextEditingController _emailSubjectCtrl;
  late TextEditingController _emailSendConditionCtrl;
  late TextEditingController _slackChannelCtrl;
  String _slackSendCondition = 'always';
  late TextEditingController _whatsappRecipientCtrl;
  String _whatsappSendCondition = 'always';
  late TextEditingController _pushTitleCtrl;
  String _pushSendCondition = 'always';

  // File download output
  late TextEditingController _downloadPathCtrl;
  late TextEditingController _fileNamePatternCtrl;
  bool _zipOutputFiles = false;
  bool _addExecutionLog = false;

  // SFTP output
  bool _sftpUseConfiguredSshServer = true;
  late TextEditingController _sftpHostCtrl;
  late TextEditingController _sftpPortCtrl;
  late TextEditingController _sftpUsernameCtrl;
  late TextEditingController _sftpPasswordCtrl;
  late TextEditingController _sftpRemotePathCtrl;
  String _sftpPrivateKeyPem = '';

  @override
  void initState() {
    super.initState();
    _subTabController = TabController(length: 6, vsync: this);

    _nameCtrl = TextEditingController(text: widget.executor.name);
    _systemPromptCtrl = TextEditingController();
    _systemPromptSkillsCtrl = TextEditingController();
    _loadSystemPrompt(widget.executor.systemPrompt ?? '');
    _promptCtrl = TextEditingController(text: widget.executor.prompt);

    // AI Overrides initialization
    final llm = widget.executor.llmConfig;
    if (llm != null) {
      _overrideLlm = true;
      _llmProviderCtrl = TextEditingController(text: llm.provider);
      _llmBaseUrlCtrl = TextEditingController(text: llm.baseUrl ?? '');
      _llmApiKeyCtrl = TextEditingController(text: llm.apiKey ?? '');
      _llmModelCtrl = TextEditingController(text: llm.model);
      _temperatureCtrl = TextEditingController(
        text: llm.temperature.toString(),
      );
      _maxTokensCtrl = TextEditingController(text: llm.maxTokens.toString());
      _isSlm = llm.extraParams['is_slm'] as bool? ?? false;
      _isMultiModal = llm.extraParams['is_multi_modal'] as bool? ?? true;
      _thinking = llm.extraParams['thinking'] as bool? ?? false;
      _useNativeToolCall = llm.extraParams['use_native_tool_call'] as bool? ?? true;
      _useSafeToolCall = llm.extraParams['use_safe_tool_call'] as bool? ?? false;
    } else {
      _overrideLlm = false;
      _llmProviderCtrl = TextEditingController(text: 'gemini');
      _llmBaseUrlCtrl = TextEditingController();
      _llmApiKeyCtrl = TextEditingController();
      _llmModelCtrl = TextEditingController();
      _temperatureCtrl = TextEditingController(text: '0.2');
      _maxTokensCtrl = TextEditingController(text: '0');
      _isSlm = false;
      _isMultiModal = true;
      _thinking = false;
      _useNativeToolCall = true;
      _useSafeToolCall = false;
    }

    // Tools initialization
    _toolboxEnabled = !widget.executor.internalMcps.any(
      (m) => m.mcpType == 'toolbox' && !m.enabled,
    );
    _localInternalMcps = List<InternalMcpEntry>.from(
      widget.executor.internalMcps,
    ).where((m) => m.mcpType != 'toolbox').toList();

    // Populate missing internal MCP servers as disabled (so they are showable in checklist)
    final registry = InternalMcpRegistry();
    final serverInfos = List<InternalMcpInfo>.from(registry.availableServers);
    for (final info in serverInfos) {
      if (info.type == 'toolbox' || info.type == 'traffic' || info.type.startsWith('gh_mcp_')) continue;
      if (!_localInternalMcps.any((m) => m.mcpType == info.type)) {
        _localInternalMcps.add(InternalMcpEntry(
          id: const Uuid().v4(),
          mcpType: info.type,
          label: info.displayName,
          enabled: false,
          initParams: const {},
        ));
      }
    }

    _localMcpTools = List<McpToolConfig>.from(widget.executor.mcpTools);
    final globalUrls = ExternalToolsSettingsService.instance.selectedServers
        .map((s) => s.serverUrl)
        .toSet();
    _selectedGlobalServerUrls = _localMcpTools
        .where((s) => globalUrls.contains(s.serverUrl))
        .map((s) => s.serverUrl)
        .toSet();

    Future.microtask(() async {
      await _loadRemoteGithubMcpServers();
      await _eagerDiscoverSelectedRemoteMcpTools();
    });

    // Routing initialization
    _localRules = widget.parentTask.edges
        .where((r) => r.sourceAgentId == widget.executor.id)
        .toList();

    final bool isFirstAgent =
        widget.executor.id == widget.parentTask.agents.first.id;
    final plan = isFirstAgent
        ? widget.parentTask.executionPlan
        : widget.executor.executionPlan;

    if (plan != null) {
      _cronExpressionCtrl = TextEditingController(text: plan.cronExpression);
      _scheduleHintCtrl = TextEditingController(text: plan.scheduleHint ?? '');
      _maxRetriesCtrl = TextEditingController(text: '${plan.maxRetries}');
      _retryDelayCtrl = TextEditingController(
        text: '${plan.retryDelayMinutes}',
      );
    } else {
      _cronExpressionCtrl = TextEditingController(text: '0 8 * * *');
      _scheduleHintCtrl = TextEditingController(text: '');
      _maxRetriesCtrl = TextEditingController(text: '3');
      _retryDelayCtrl = TextEditingController(text: '15');
    }

    if (_localRules.isNotEmpty) {
      final first = _localRules.first;
      if (first.operator == 'stop') {
        _routingType = 'none';
      } else if (first.operator == 'sequential' || first.operator == 'always') {
        _routingType = 'sequential';
        _targetExecutorId = first.targetAgentId;
      } else {
        _routingType = 'conditional';
      }
    } else {
      _routingType = 'none';
    }

    // Output/Notification initialization
    final notif = widget.executor.notification;
    if (notif.email != null) {
      _outputType = 'email';
      _emailToCtrl = TextEditingController(
        text: notif.email!.recipients.join(', '),
      );
      _emailSubjectCtrl = TextEditingController(
        text: notif.email!.subject ?? '',
      );
      _emailSendConditionCtrl = TextEditingController(
        text: notif.email!.sendCondition,
      );
    } else {
      _emailToCtrl = TextEditingController();
      _emailSubjectCtrl = TextEditingController();
      _emailSendConditionCtrl = TextEditingController(text: 'always');
    }

    if (notif.slack != null) {
      if (_outputType == 'none') _outputType = 'slack';
      _slackChannelCtrl = TextEditingController(
        text: notif.slack!.overrideChannel ?? '',
      );
      _slackSendCondition = notif.slack!.sendCondition;
    } else {
      _slackChannelCtrl = TextEditingController();
      _slackSendCondition = 'always';
    }

    if (notif.whatsApp != null) {
      if (_outputType == 'none') _outputType = 'whatsapp';
      _whatsappRecipientCtrl = TextEditingController(
        text: notif.whatsApp!.overrideRecipient ?? '',
      );
      _whatsappSendCondition = notif.whatsApp!.sendCondition;
    } else {
      _whatsappRecipientCtrl = TextEditingController();
      _whatsappSendCondition = 'always';
    }

    if (notif.push != null) {
      if (_outputType == 'none') _outputType = 'push';
      _pushTitleCtrl = TextEditingController(text: notif.push!.title ?? '');
      _pushSendCondition = notif.push!.condition;
    } else {
      _pushTitleCtrl = TextEditingController();
      _pushSendCondition = 'always';
    }

    final download = widget.executor.notification.download;
    if (download != null) {
      if (_outputType == 'none') _outputType = 'download';
      _downloadPathCtrl = TextEditingController(
        text: download.downloadPath ?? '',
      );
      _fileNamePatternCtrl = TextEditingController(
        text: download.fileNamePattern ?? '',
      );
    } else {
      _downloadPathCtrl = TextEditingController();
      _fileNamePatternCtrl = TextEditingController();
    }
    _zipOutputFiles = widget.executor.notification.zipOutputFiles;
    _addExecutionLog = widget.executor.notification.addExecutionLog;

    final sftp = widget.executor.notification.sftpOutput;
    if (sftp != null) {
      if (_outputType == 'none') _outputType = 'sftp';
      _sftpUseConfiguredSshServer = sftp.useConfiguredSshServer;
      _sftpHostCtrl = TextEditingController(text: sftp.host);
      _sftpPortCtrl = TextEditingController(text: sftp.port.toString());
      _sftpUsernameCtrl = TextEditingController(text: sftp.username);
      _sftpPasswordCtrl = TextEditingController(text: sftp.password ?? '');
      _sftpRemotePathCtrl = TextEditingController(text: sftp.remotePath);
      _sftpPrivateKeyPem = sftp.privateKey ?? '';
    } else {
      _sftpUseConfiguredSshServer = true;
      _sftpHostCtrl = TextEditingController();
      _sftpPortCtrl = TextEditingController(text: '22');
      _sftpUsernameCtrl = TextEditingController();
      _sftpPasswordCtrl = TextEditingController();
      _sftpRemotePathCtrl = TextEditingController(text: '/');
      _sftpPrivateKeyPem = '';
    }
  }

  Future<void> _loadRemoteGithubMcpServers() async {
    final isServerMode = ref.read(serverModeProvider).value?.isRemote ?? false;
    if (!isServerMode) return;
    final client = ref.read(serverApiClientProvider);
    if (client == null) return;
    try {
      final raw = await client.listRegistryServers();
      final defs = raw
          .map(GithubMcpServerDefinition.fromJson)
          .where((s) => s.isInstalled && s.isActive)
          .toList();
      if (mounted) {
        setState(() => _remoteGithubMcpServers = defs);
      }
    } catch (e) {
      print('[AgentEdit] Failed to load remote GitHub MCP servers: $e');
    }
  }

  Future<List<String>> _fetchRemoteMcpToolNames(String serverId) async {
    final client = ref.read(serverApiClientProvider);
    if (client == null) return const [];
    try {
      await client.startMcpServer(serverId);
    } catch (e) {
      print('[AgentEdit] startMcpServer warning for $serverId: $e');
    }
    try {
      final tools = await client.getMcpServerTools(serverId);
      final names = tools
          .map((t) => (t['name'] ?? '').toString().trim())
          .where((n) => n.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
      return names;
    } catch (e) {
      print('[AgentEdit] getMcpServerTools failed for $serverId: $e');
      return const [];
    }
  }

  Future<void> _eagerDiscoverSelectedRemoteMcpTools() async {
    final isServerMode = ref.read(serverModeProvider).value?.isRemote ?? false;
    if (!isServerMode) {
      // In local mode, discover local GitHub MCP tools
      for (final mcp in _localInternalMcps.where(
        (m) => m.enabled && m.mcpType.startsWith('gh_mcp_'),
      )) {
        final serverId = mcp.mcpType.substring('gh_mcp_'.length);
        final def = GithubMcpLibraryService.instance.findById(serverId);
        if (def != null && def.isInstalled) {
          if (_prefetchedRemoteMcpTools[serverId]?.isNotEmpty == true) continue;
          GithubMcpRuntimeService.instance.discoverLocalMcpTools(def).then((names) {
            if (names.isNotEmpty && mounted) {
              setState(() {
                _prefetchedRemoteMcpTools[serverId] = names;
              });
            }
          });
        }
      }
      return;
    }

    final client = ref.read(serverApiClientProvider);
    if (client == null) return;

    for (final url in _selectedGlobalServerUrls) {
      final names = await _fetchRemoteMcpToolNames(url);
      if (names.isEmpty) continue;
      _prefetchedRemoteMcpTools[url] = names;
      final idx = _localMcpTools.indexWhere((s) => s.serverUrl == url);
      if (idx >= 0) {
        if (!_sameStringList(_localMcpTools[idx].discoveredTools, names)) {
          setState(() {
            _localMcpTools[idx] = _localMcpTools[idx].copyWith(discoveredTools: names);
          });
        }
      } else {
        setState(() {
          _localMcpTools.add(McpToolConfig(
            name: Uri.tryParse(url)?.host ?? 'Global Server',
            serverUrl: url,
            discoveredTools: names,
          ));
        });
      }
    }

    for (final mcp in _localInternalMcps.where(
      (m) => m.enabled && m.mcpType.startsWith('gh_mcp_'),
    )) {
      final serverId = mcp.mcpType.substring('gh_mcp_'.length);
      final names = await _fetchRemoteMcpToolNames(serverId);
      if (names.isNotEmpty) {
        setState(() {
          _prefetchedRemoteMcpTools[serverId] = names;
        });
      }
    }
  }

  bool _sameStringList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _loadSystemPrompt(String full) {
    var match = RegExp(r'\n+Tool Hints:\n').firstMatch(full);
    match ??= RegExp(r'\n+Tool Skills:\n').firstMatch(full);
    if (match != null) {
      _systemPromptCtrl.text = full.substring(0, match.start).trimRight();
      _systemPromptSkillsCtrl.text = full.substring(match.start + 1).trim();
    } else {
      _systemPromptCtrl.text = full;
      _systemPromptSkillsCtrl.text = '';
    }
  }

  Future<void> _updateSkillsSection() async {
    if (!mounted) return;
    final generation = ++_skillsUpdateGeneration;
    setState(() => _systemPromptSkillsCtrl.text = '');
    final enabledFilter = _enabledToolNamesFromPrompt(_promptCtrl.text);
    final skills = await _buildTaskSkillsBlock(
      isSlm: _isEffectiveSlm(),
      enabledFilter: enabledFilter,
    );
    if (!mounted || generation != _skillsUpdateGeneration) return;
    setState(() {
      _systemPromptSkillsCtrl.text = skills;
    });
  }

  bool _isEffectiveSlm() {
    if (_overrideLlm) return _isSlm;
    return ref.read(llmSettingsProvider).isSlm;
  }

  Set<String>? _enabledToolNamesFromPrompt(String promptText) {
    if (!promptText.contains('++#++')) return null;
    final sep = RegExp(r'\+\+#\+\+');
    final steps = promptText.split(sep);
    final ntPattern = RegExp(r'\[NT:\s*([^\]]+)\]', caseSensitive: false);
    final Set<String> allToolNames = {};
    bool hasAnyExplicitTools = false;

    for (final step in steps) {
      final match = ntPattern.firstMatch(step);
      if (match != null) {
        hasAnyExplicitTools = true;
        final listStr = match.group(1)!;
        final tools = listStr.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty);
        allToolNames.addAll(tools);
      }
    }
    return hasAnyExplicitTools ? allToolNames : null;
  }

  Future<String> _buildTaskSkillsBlock({
    bool isSlm = false,
    Set<String>? enabledFilter,
  }) async {
    final toolNames = <String>[];
    if (_toolboxEnabled) {
      final toolbox = InternalMcpRegistry().create('toolbox');
      if (toolbox != null) toolNames.addAll(toolbox.tools.map((t) => t.name));
    }
    for (final entry in _localInternalMcps.where((e) => e.enabled)) {
      if (entry.mcpType.startsWith('gh_mcp_')) {
        final serverId = entry.mcpType.substring('gh_mcp_'.length);
        toolNames.addAll(
          _prefetchedRemoteMcpTools[serverId] ?? const <String>[],
        );
        continue;
      }
      final server = InternalMcpRegistry().create(entry.mcpType);
      if (server != null) toolNames.addAll(server.tools.map((t) => t.name));
    }
    final globalServers = ExternalToolsSettingsService.instance.selectedServers;
    for (final url in _selectedGlobalServerUrls) {
      final s = globalServers.firstWhere(
        (s) => s.serverUrl == url,
        orElse: () => McpToolConfig(serverUrl: url),
      );
      final names = s.discoveredTools.isNotEmpty
          ? s.discoveredTools
          : (_prefetchedRemoteMcpTools[url] ?? const <String>[]);
      toolNames.addAll(names);
    }
    if (toolNames.isEmpty) return '';
    final filtered = enabledFilter != null
        ? toolNames.where((t) => enabledFilter.contains(t)).toList()
        : toolNames;
    if (filtered.isEmpty) return '';
    try {
      final client = ref.read(serverApiClientProvider);
      final List<FunctionHint> skills;
      if (client != null) {
        final raw = await client.getAllSkills();
        final all = raw.map((j) => FunctionHint.fromJson(j)).toList();
        final filteredList = all
            .where((s) => s.isEnabled && filtered.contains(s.toolName))
            .toList();
        final seen = <String>{};
        skills = filteredList.where((s) => seen.add(s.toolName)).toList();
      } else {
        skills = await FunctionHintDatabaseService().getEnabledForTools(filtered);
      }
      if (skills.isEmpty) return '';
      final buffer = StringBuffer();
      buffer.writeln('Tool Hints:');
      for (final skill in skills) {
        final text = isSlm ? skill.skillTextSlm : skill.skillText;
        if (text.trim().isNotEmpty) {
          buffer.writeln('• ${skill.toolName}: ${text.trim()}');
        }
      }
      return buffer.toString().trim();
    } catch (_) {
      return '';
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _systemPromptCtrl.dispose();
    _systemPromptSkillsCtrl.dispose();
    _promptCtrl.dispose();
    _llmProviderCtrl.dispose();
    _llmBaseUrlCtrl.dispose();
    _llmApiKeyCtrl.dispose();
    _llmModelCtrl.dispose();
    _temperatureCtrl.dispose();
    _maxTokensCtrl.dispose();
    _cronExpressionCtrl.dispose();
    _scheduleHintCtrl.dispose();
    _maxRetriesCtrl.dispose();
    _retryDelayCtrl.dispose();
    _emailToCtrl.dispose();
    _emailSubjectCtrl.dispose();
    _emailSendConditionCtrl.dispose();
    _slackChannelCtrl.dispose();
    _whatsappRecipientCtrl.dispose();
    _pushTitleCtrl.dispose();
    _downloadPathCtrl.dispose();
    _fileNamePatternCtrl.dispose();
    _sftpHostCtrl.dispose();
    _sftpPortCtrl.dispose();
    _sftpUsernameCtrl.dispose();
    _sftpPasswordCtrl.dispose();
    _sftpRemotePathCtrl.dispose();
    _subTabController.dispose();
    super.dispose();
  }

  List<ToolGroup> get _availableToolGroups {
    final groups = <ToolGroup>[];
    
    // Add toolbox tools if toolbox is enabled
    if (_toolboxEnabled) {
      final toolbox = InternalMcpRegistry().create('toolbox');
      if (toolbox != null && toolbox.tools.isNotEmpty) {
        groups.add(
          ToolGroup(
            name: toolbox.displayName,
            toolNames: toolbox.tools.map((t) => t.name).toList(),
          ),
        );
      }
    }

    final internalMcps = _localInternalMcps;
    final mcpTools = _localMcpTools;

    for (final mcp in internalMcps.where((m) => m.enabled)) {
      final server = InternalMcpRegistry().create(mcp.mcpType);
      if (server != null && server.tools.isNotEmpty) {
        groups.add(
          ToolGroup(
            name: mcp.label ?? mcp.mcpType,
            toolNames: server.tools.map((t) => t.name).toList(),
          ),
        );
      } else if (mcp.mcpType.startsWith('gh_mcp_')) {
        // Local GitHub MCP server tools
        final serverId = mcp.mcpType.substring('gh_mcp_'.length);
        final list = _prefetchedRemoteMcpTools[serverId];
        if (list != null && list.isNotEmpty) {
          groups.add(
            ToolGroup(
              name: mcp.label ?? mcp.mcpType,
              toolNames: list,
            ),
          );
        }
      }
    }

    for (final s in mcpTools) {
      if (!_selectedGlobalServerUrls.contains(s.serverUrl)) continue;
      List<String> names = s.discoveredTools;
      if (names.isEmpty) {
        final activeMgr = ref.read(activeTaskProvider)?.mcpManager;
        if (activeMgr != null) {
          final clientDef = activeMgr.clients
              .where(
                (c) =>
                    c.name == (s.name ?? Uri.tryParse(s.serverUrl)?.host ?? ''),
              )
              .firstOrNull;
          if (clientDef != null) {
            names = clientDef.availableTools.map((t) => t.name).toList();
          }
        }
      }
      groups.add(ToolGroup(name: s.name ?? s.serverUrl, toolNames: names));
    }
    return groups;
  }

  bool _isAgentSchedulingEnabled() {
    final isFirstAgent =
        widget.executor.id == widget.parentTask.agents.first.id;
    if (isFirstAgent) return true;
    final isTarget = widget.parentTask.edges.any(
      (r) =>
          r.targetAgentId == widget.executor.id &&
          r.operator != 'stop' &&
          r.sourceAgentId != widget.executor.id,
    );
    return !isTarget;
  }

  bool _isUpstream(String candidateId, String currentId) {
    final visited = <String>{};
    bool dfs(String curr) {
      if (curr == currentId) return true;
      if (visited.contains(curr)) return false;
      visited.add(curr);
      final children = <String>[];
      final currRules = (curr == widget.executor.id)
          ? _localRules
          : widget.parentTask.edges
                .where((r) => r.sourceAgentId == curr)
                .toList();
      if (currRules.isNotEmpty && currRules.first.operator != 'stop') {
        children.addAll(
          currRules.map((r) => r.targetAgentId).where((id) => id.isNotEmpty),
        );
      } else if (currRules.isEmpty) {
        final idx = widget.parentTask.agents.indexWhere((e) => e.id == curr);
        if (idx != -1 && idx < widget.parentTask.agents.length - 1) {
          final nextId = widget.parentTask.agents[idx + 1].id;
          final isTargetOfAnyRule = widget.parentTask.edges.any(
            (r) => r.targetAgentId == nextId && r.operator != 'stop',
          );
          if (!isTargetOfAnyRule) {
            children.add(nextId);
          }
        }
      }
      for (final child in children) {
        if (dfs(child)) return true;
      }
      return false;
    }

    return dfs(candidateId);
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;

    final bool isFirstAgent =
        widget.executor.id == widget.parentTask.agents.first.id;

    Map<String, dynamic> buildExtraParams() {
      final Map<String, dynamic> params = {};
      if (_thinking) params['thinking'] = true;
      params['use_native_tool_call'] = _useNativeToolCall;
      params['use_safe_tool_call'] = _useSafeToolCall;
      params['is_slm'] = _isSlm;
      params['is_multi_modal'] = _isMultiModal;
      return params;
    }

    // Build LLM Config
    TaskLlmConfig? llmConfig;
    if (_overrideLlm) {
      llmConfig = TaskLlmConfig(
        provider: _llmProviderCtrl.text.trim(),
        model: _llmModelCtrl.text.trim(),
        apiKey: _llmApiKeyCtrl.text.trim().isNotEmpty
            ? _llmApiKeyCtrl.text.trim()
            : null,
        baseUrl: _llmBaseUrlCtrl.text.trim().isNotEmpty
            ? _llmBaseUrlCtrl.text.trim()
            : null,
        temperature: double.tryParse(_temperatureCtrl.text) ?? 0.2,
        maxTokens: int.tryParse(_maxTokensCtrl.text) ?? 0,
        extraParams: buildExtraParams(),
      );
    }

    // Build Execution Plan if enabled
    ExecutionPlan? executionPlan;
    if (_isAgentSchedulingEnabled()) {
      executionPlan = ExecutionPlan(
        cronExpression: _cronExpressionCtrl.text.trim(),
        scheduleHint: _scheduleHintCtrl.text.trim().isNotEmpty
            ? _scheduleHintCtrl.text.trim()
            : null,
        maxRetries: int.tryParse(_maxRetriesCtrl.text) ?? 3,
        retryDelayMinutes: int.tryParse(_retryDelayCtrl.text) ?? 15,
      );
    }

    // Build Output Notification settings
    final notification = TaskNotification(
      zipOutputFiles: _zipOutputFiles,
      addExecutionLog: _addExecutionLog,
      download: _outputType == 'download'
          ? DownloadNotification(
              downloadPath: _downloadPathCtrl.text.trim().isNotEmpty
                  ? _downloadPathCtrl.text.trim()
                  : null,
              fileNamePattern: _fileNamePatternCtrl.text.trim().isNotEmpty
                  ? _fileNamePatternCtrl.text.trim()
                  : null,
            )
          : null,
      sftpOutput: _outputType == 'sftp'
          ? SftpOutputConfig(
              useConfiguredSshServer: _sftpUseConfiguredSshServer,
              host: _sftpHostCtrl.text.trim(),
              port: int.tryParse(_sftpPortCtrl.text) ?? 22,
              username: _sftpUsernameCtrl.text.trim(),
              password: _sftpPasswordCtrl.text.trim().isNotEmpty
                  ? _sftpPasswordCtrl.text.trim()
                  : null,
              privateKey: _sftpPrivateKeyPem.trim().isNotEmpty
                  ? _sftpPrivateKeyPem.trim()
                  : null,
              remotePath: _sftpRemotePathCtrl.text.trim().isNotEmpty
                  ? _sftpRemotePathCtrl.text.trim()
                  : '/',
            )
          : null,
      email: _outputType == 'email'
          ? EmailNotification(
              recipients: _emailToCtrl.text
                  .split(',')
                  .map((s) => s.trim())
                  .where((s) => s.isNotEmpty)
                  .toList(),
              subject: _emailSubjectCtrl.text.trim().isNotEmpty
                  ? _emailSubjectCtrl.text.trim()
                  : null,
              sendCondition: _emailSendConditionCtrl.text.trim(),
              withAttachment: true,
            )
          : null,
      slack: _outputType == 'slack'
          ? SlackNotification(
              sendCondition: _slackSendCondition.trim(),
              overrideChannel: _slackChannelCtrl.text.trim().isNotEmpty
                  ? _slackChannelCtrl.text.trim()
                  : null,
              withAttachment: true,
            )
          : null,
      whatsApp: _outputType == 'whatsapp'
          ? WhatsAppNotification(
              sendCondition: _whatsappSendCondition.trim(),
              overrideRecipient: _whatsappRecipientCtrl.text.trim().isNotEmpty
                  ? _whatsappRecipientCtrl.text.trim()
                  : null,
              withAttachment: true,
            )
          : null,
      push: _outputType == 'push'
          ? PushNotification(
              title: _pushTitleCtrl.text.trim().isNotEmpty
                  ? _pushTitleCtrl.text.trim()
                  : null,
              condition: _pushSendCondition.trim(),
            )
          : null,
    );

    // Update routing rules in parent task
    final updatedRules = widget.parentTask.edges
        .where((r) => r.sourceAgentId != widget.executor.id)
        .toList();

    if (_routingType == 'none') {
      updatedRules.add(
        Edge(
          id: const Uuid().v4(),
          sourceAgentId: widget.executor.id,
          variable: 'task_result',
          operator: 'stop',
          value: '',
          targetAgentId: '',
        ),
      );
    } else if (_routingType == 'sequential' && _targetExecutorId != null) {
      updatedRules.removeWhere(
        (r) =>
            r.targetAgentId == _targetExecutorId &&
            r.sourceAgentId != widget.executor.id,
      );
      updatedRules.add(
        Edge(
          id: const Uuid().v4(),
          sourceAgentId: widget.executor.id,
          variable: 'task_result',
          operator: 'sequential',
          value: '',
          targetAgentId: _targetExecutorId!,
        ),
      );
    } else if (_routingType == 'conditional') {
      final targetIds = _localRules.map((r) => r.targetAgentId).toSet();
      updatedRules.removeWhere(
        (r) =>
            targetIds.contains(r.targetAgentId) &&
            r.sourceAgentId != widget.executor.id,
      );
      final mappedRules = _localRules
          .map((r) => r.copyWith(operator: 'llm_eval'))
          .toList();
      updatedRules.addAll(mappedRules);
    }

    final savedInternalMcps = List<InternalMcpEntry>.from(_localInternalMcps);
    if (!_toolboxEnabled) {
      savedInternalMcps.add(
        InternalMcpEntry(
          id: const Uuid().v4(),
          mcpType: 'toolbox',
          label: 'Toolbox',
          enabled: false,
          initParams: const {},
        ),
      );
    }

    final savedMcpTools = _localMcpTools
        .where((t) => _selectedGlobalServerUrls.contains(t.serverUrl))
        .toList();

    String getCombinedSystemPrompt() {
      final user = _systemPromptCtrl.text.trimRight();
      final skills = _systemPromptSkillsCtrl.text.trim();
      if (skills.isEmpty) return user;
      return user.isEmpty ? skills : '$user\n\n$skills';
    }

    final updatedExec = widget.executor.copyWith(
      name: name,
      systemPrompt: getCombinedSystemPrompt(),
      prompt: _promptCtrl.text.trim(),
      llmConfig: llmConfig,
      clearLlmConfig: !_overrideLlm,
      executionPlan: isFirstAgent ? null : executionPlan,
      clearExecutionPlan: !isFirstAgent && !_isAgentSchedulingEnabled(),
      internalMcps: savedInternalMcps,
      mcpTools: savedMcpTools,
      notification: notification,
    );

    final agents = widget.parentTask.agents.map((e) {
      if (e.id == widget.executor.id) {
        return updatedExec;
      }
      final isFirst = e.id == widget.parentTask.agents.first.id;
      if (!isFirst) {
        final isTarget = updatedRules.any(
          (r) =>
              r.targetAgentId == e.id &&
              r.operator != 'stop' &&
              r.sourceAgentId != e.id,
        );
        if (isTarget && e.executionPlan != null) {
          return e.copyWith(clearExecutionPlan: true);
        }
      }
      return e;
    }).toList();

    ExecutionPlan taskExecutionPlan = widget.parentTask.executionPlan;
    if (isFirstAgent && executionPlan != null) {
      taskExecutionPlan = executionPlan;
    }

    final updatedTask = widget.parentTask.copyWith(
      agents: agents,
      edges: updatedRules,
      executionPlan: taskExecutionPlan,
    );

    await ref.read(taskListProvider.notifier).saveTask(updatedTask);
    Navigator.of(context).pop(updatedTask);
  }

  // ── Sub-widgets panels ──────────────────────────────────────────

  Widget _buildToolsTabContent() {
    final registry = InternalMcpRegistry();
    final isServerMode = ref.read(serverModeProvider).value?.isRemote ?? false;

    final serverInfos = List<InternalMcpInfo>.from(registry.availableServers);
    if (isServerMode &&
        !serverInfos.any((server) => server.type == 'py_bridge')) {
      final pyBridge = PyBridgeMcpServer();
      serverInfos.add(
        InternalMcpInfo(
          type: pyBridge.type,
          displayName: pyBridge.displayName,
          description: pyBridge.description,
          iconName: pyBridge.iconName,
          initParamSchema: pyBridge.initParamSchema,
          defaultInitParams: pyBridge.defaultInitParams,
          defaultSystemPrompt: pyBridge.defaultSystemPrompt,
          toolCount: pyBridge.tools.length,
          toolNames: pyBridge.tools.map((tool) => tool.name).toList(),
        ),
      );
    }

    final availableBuiltins = serverInfos
        .where(
          (server) =>
              server.type != 'toolbox' &&
              server.type != 'traffic' &&
              !server.type.startsWith('gh_mcp_') &&
              !(isServerMode &&
                  (server.type == 'ps_bridge' || server.type == 'chart')),
        )
        .toList()
      ..sort((a, b) => a.displayName.compareTo(b.displayName));

    final globalServers = ExternalToolsSettingsService.instance.selectedServers;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Toolbox Section ──
          SwitchListTile(
            title: const Text(
              'Standard Toolbox',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
            subtitle: const Text(
              'General tools: date, time, battery level, etc.',
              style: TextStyle(fontSize: 12),
            ),
            value: _toolboxEnabled,
            onChanged: (val) {
              setState(() {
                _toolboxEnabled = val;
              });
            },
            activeThumbColor: AppTheme.primaryBlue,
            contentPadding: EdgeInsets.zero,
          ),
          const Divider(),
          const SizedBox(height: 12),

          // ── Built-in MCP Servers Section ──
          const Text(
            'Built-in MCP Servers',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
          const SizedBox(height: 8),
          ...availableBuiltins.map((info) {
            final idx = _localInternalMcps.indexWhere(
              (m) => m.mcpType == info.type,
            );
            final isEnabled = idx >= 0
                ? _localInternalMcps[idx].enabled
                : false;
            return CheckboxListTile(
              title: Text(info.displayName),
              subtitle: Text(
                info.description,
                style: const TextStyle(fontSize: 11),
              ),
              value: isEnabled,
              onChanged: (val) {
                if (val == null) return;
                setState(() {
                  if (idx >= 0) {
                    _localInternalMcps[idx] = _localInternalMcps[idx].copyWith(
                      enabled: val,
                    );
                  } else {
                    _localInternalMcps.add(
                      InternalMcpEntry(
                        id: const Uuid().v4(),
                        mcpType: info.type,
                        enabled: val,
                        label: info.displayName,
                      ),
                    );
                  }
                });
              },
              activeColor: AppTheme.primaryBlue,
              dense: true,
              contentPadding: EdgeInsets.zero,
            );
          }),
          const Divider(),
          const SizedBox(height: 12),

          // ── Global MCP Servers Section ──
          const Text(
            'Global MCP Servers',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
          const SizedBox(height: 8),
          if (globalServers.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8.0),
              child: Text(
                'No global MCP servers configured. Add them in Settings.',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
            )
          else
            ...globalServers.map((s) {
              final isEnabled = _selectedGlobalServerUrls.contains(s.serverUrl);
              return CheckboxListTile(
                title: Text(s.name ?? 'Global Server'),
                subtitle: Text(
                  s.serverUrl,
                  style: const TextStyle(fontSize: 11),
                ),
                value: isEnabled,
                onChanged: (val) async {
                  if (val == null) return;
                  setState(() {
                    if (val) {
                      _selectedGlobalServerUrls.add(s.serverUrl);
                    } else {
                      _selectedGlobalServerUrls.remove(s.serverUrl);
                    }
                  });
                  if (val) {
                    await _eagerDiscoverSelectedRemoteMcpTools();
                  }
                },
                activeColor: AppTheme.primaryBlue,
                dense: true,
                contentPadding: EdgeInsets.zero,
              );
            }),
          const Divider(),
          const SizedBox(height: 12),

          // ── GitHub MCP Servers Section ──
          const Text(
            'GitHub MCP Servers',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
          const SizedBox(height: 8),
          if (isServerMode) ...[
            if (_remoteGithubMcpServers.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8.0),
                child: Text(
                  'No remote GitHub MCP servers registry found.',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
              )
            else
              ..._remoteGithubMcpServers.map((def) {
                final key = 'gh_mcp_${def.id}';
                final idx = _localInternalMcps.indexWhere((m) => m.mcpType == key);
                final isEnabled = idx >= 0 ? _localInternalMcps[idx].enabled : false;
                return CheckboxListTile(
                  title: Text(def.name),
                  subtitle: Text(
                    def.githubUrl,
                    style: const TextStyle(fontSize: 11),
                  ),
                  value: isEnabled,
                  onChanged: (val) async {
                    if (val == null) return;
                    setState(() {
                      if (idx >= 0) {
                        _localInternalMcps[idx] = _localInternalMcps[idx].copyWith(enabled: val);
                      } else {
                        _localInternalMcps.add(InternalMcpEntry(
                          id: const Uuid().v4(),
                          mcpType: key,
                          label: def.name,
                          enabled: val,
                          initParams: const {},
                        ));
                      }
                    });
                    if (val) {
                      await _eagerDiscoverSelectedRemoteMcpTools();
                    }
                  },
                  activeColor: AppTheme.primaryBlue,
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                );
              }),
          ] else ...[
            FutureBuilder<List<GithubMcpServerDefinition>>(
              future: Future.value(GithubMcpLibraryService.instance.installedServers),
              builder: (context, snapshot) {
                final list = snapshot.data ?? [];
                if (list.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8.0),
                    child: Text(
                      'No local GitHub MCP servers installed. Add them in Settings.',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  );
                }
                return Column(
                  children: list.map((def) {
                    final key = 'gh_mcp_${def.id}';
                    final idx = _localInternalMcps.indexWhere((m) => m.mcpType == key);
                    final isEnabled = idx >= 0 ? _localInternalMcps[idx].enabled : false;
                    return CheckboxListTile(
                      title: Text(def.name),
                      subtitle: Text(
                        def.githubUrl,
                        style: const TextStyle(fontSize: 11),
                      ),
                      value: isEnabled,
                      onChanged: (val) async {
                        if (val == null) return;
                        setState(() {
                          if (idx >= 0) {
                            _localInternalMcps[idx] = _localInternalMcps[idx].copyWith(enabled: val);
                          } else {
                            _localInternalMcps.add(InternalMcpEntry(
                              id: const Uuid().v4(),
                              mcpType: key,
                              label: def.name,
                              enabled: val,
                              initParams: const {},
                            ));
                          }
                        });
                        if (val) {
                          await _eagerDiscoverSelectedRemoteMcpTools();
                        }
                      },
                      activeColor: AppTheme.primaryBlue,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                    );
                  }).toList(),
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSkillsTextbox() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              Icons.auto_fix_high_outlined,
              size: 13,
              color: Colors.grey[500],
            ),
            const SizedBox(width: 4),
            Text(
              'Tool Hints (auto-generated)',
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey[500],
                fontWeight: FontWeight.w500,
              ),
            ),
            const Spacer(),
            if (_systemPromptSkillsCtrl.text.isNotEmpty)
              InkWell(
                onTap: () => setState(() => _systemPromptSkillsCtrl.text = ''),
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.clear, size: 13, color: Colors.grey[500]),
                      const SizedBox(width: 2),
                      Text(
                        'Clear',
                        style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        TextField(
          controller: _systemPromptSkillsCtrl,
          maxLines: 5,
          minLines: 2,
          readOnly: true,
          style: TextStyle(
            fontSize: 12,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            fontFamily: 'monospace',
          ),
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            isDense: true,
            contentPadding: const EdgeInsets.all(8),
            hintText: 'No Tool Hints loaded',
            hintStyle: TextStyle(fontSize: 12, color: Colors.grey[600]),
            filled: true,
            fillColor: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.4,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPromptsTabContent() {
    final l = L.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              l.systemPromptTitleLabel,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => PromptWizardDialog(
                  initialText: _systemPromptCtrl.text,
                  isSystemPrompt: true,
                  onAccept: (txt) =>
                      setState(() => _systemPromptCtrl.text = txt),
                  taskRef: ref,
                ),
              ),
              icon: const Icon(Icons.auto_awesome, size: 14),
              label: const Text('AI Assistant'),
            ),
          ],
        ),
        TextFormField(
          controller: _systemPromptCtrl,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: 'e.g. You are a helpful weather expert...',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        _buildSkillsTextbox(),
        const SizedBox(height: 16),
        Row(
          children: [
            Text(
              l.taskPrompt,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => PromptWizardDialog(
                  initialText: _promptCtrl.text,
                  isSystemPrompt: false,
                  onAccept: (txt) {
                    setState(() => _promptCtrl.text = txt);
                    _updateSkillsSection();
                  },
                  taskRef: ref,
                ),
              ),
              icon: const Icon(Icons.auto_awesome, size: 14),
              label: const Text('AI Assistant'),
            ),
          ],
        ),
        StepListEditor(
          controller: _promptCtrl,
          minLines: 3,
          maxLines: 8,
          availableToolGroups: _availableToolGroups,
        ),
      ],
    );
  }

  Widget _buildLlmTabContent() {
    final settings = ref.read(llmSettingsProvider);
    final isServerMode = ref.watch(serverModeProvider).value?.isRemote ?? false;
    final serverClient = isServerMode ? ref.read(serverApiClientProvider) : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          title: const Text('Override LLM settings'),
          subtitle: const Text(
            'Enable customized model settings for this agent',
          ),
          value: _overrideLlm,
          onChanged: (val) {
            setState(() => _overrideLlm = val);
            _updateSkillsSection();
          },
          activeTrackColor: AppTheme.primaryBlue,
          contentPadding: EdgeInsets.zero,
        ),
        if (_overrideLlm) ...[
          LlmSettingsFormWidget(
            providerKey: _llmProviderCtrl.text.trim(),
            modelController: _llmModelCtrl,
            apiKeyController: _llmApiKeyCtrl,
            baseUrlController: _llmBaseUrlCtrl,
            temperatureController: _temperatureCtrl,
            maxTokensController: _maxTokensCtrl,
            isSlm: _isSlm,
            isMultiModal: _isMultiModal,
            thinking: _thinking,
            useNativeToolCall: _useNativeToolCall,
            useSafeToolCall: _useSafeToolCall,
            enableToolParameterAutoRecovery: true,
            service: settings,
            serverClient: serverClient,
            showLlm2Option: true,
            showNoneOption: true,
            onProviderChanged: (key) {
              setState(() {
                _llmProviderCtrl.text = key;
              });
            },
            onSlmChanged: (v) {
              setState(() => _isSlm = v);
              _updateSkillsSection();
            },
            onMultiModalChanged: (v) => setState(() => _isMultiModal = v),
            onThinkingChanged: (v) => setState(() => _thinking = v),
            onUseNativeToolCallChanged: (v) =>
                setState(() => _useNativeToolCall = v),
            onUseSafeToolCallChanged: (v) =>
                setState(() => _useSafeToolCall = v),
          ),
        ],
      ],
    );
  }

  Widget _buildRoutingTabContent(List<Agent> otherExecutors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          initialValue: _routingType,
          decoration: const InputDecoration(
            labelText: 'Next Step Routing',
            border: OutlineInputBorder(),
          ),
          items: const [
            DropdownMenuItem(
              value: 'none',
              child: Text('None (Stops execution)'),
            ),
            DropdownMenuItem(
              value: 'sequential',
              child: Text('Sequential (Route to target)'),
            ),
            DropdownMenuItem(
              value: 'conditional',
              child: Text('Conditional LLM (Multiple targets)'),
            ),
          ],
          onChanged: (val) {
            if (val == null) return;
            setState(() {
              _routingType = val;
              if (val == 'sequential' &&
                  _targetExecutorId == null &&
                  otherExecutors.isNotEmpty) {
                _targetExecutorId = otherExecutors.first.id;
              }
              if (val == 'conditional' && _localRules.isEmpty) {
                _localRules.add(
                  Edge(
                    id: const Uuid().v4(),
                    sourceAgentId: widget.executor.id,
                    variable: 'task_result',
                    operator: 'llm_eval',
                    value: '',
                    targetAgentId: otherExecutors.isNotEmpty
                        ? otherExecutors.first.id
                        : widget.executor.id,
                  ),
                );
              }
            });
          },
        ),
        const SizedBox(height: 16),
        if (_routingType == 'sequential') ...[
          DropdownButtonFormField<String>(
            initialValue: otherExecutors.any((e) => e.id == _targetExecutorId)
                ? _targetExecutorId
                : (otherExecutors.isNotEmpty ? otherExecutors.first.id : null),
            decoration: const InputDecoration(
              labelText: 'Target Agent',
              border: OutlineInputBorder(),
            ),
            items: otherExecutors.map((e) {
              return DropdownMenuItem(value: e.id, child: Text(e.name));
            }).toList(),
            onChanged: (val) => setState(() => _targetExecutorId = val),
          ),
        ],
        if (_routingType == 'conditional') ...[
          const Text(
            'Branching conditions (evaluated by LLM):',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          ..._localRules.asMap().entries.map((entry) {
            final idx = entry.key;
            final rule = entry.value;
            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              color: Colors.purple.withValues(alpha: 0.03),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: Colors.purple.withValues(alpha: 0.15)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Text(
                          'Branch #${idx + 1}',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.purple,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(
                            Icons.delete_outline,
                            color: Colors.red,
                            size: 18,
                          ),
                          onPressed: () {
                            setState(() {
                              _localRules.removeAt(idx);
                            });
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue:
                          otherExecutors.any(
                            (e) => e.id == rule.targetAgentId,
                          )
                          ? rule.targetAgentId
                          : (otherExecutors.isNotEmpty
                                ? otherExecutors.first.id
                                : null),
                      decoration: const InputDecoration(
                        labelText: 'Target Agent',
                        border: OutlineInputBorder(),
                      ),
                      items: otherExecutors.map((e) {
                        return DropdownMenuItem(
                          value: e.id,
                          child: Text(e.name),
                        );
                      }).toList(),
                      onChanged: (val) {
                        if (val == null) return;
                        setState(() {
                          _localRules[idx] = rule.copyWith(
                            targetAgentId: val,
                          );
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      initialValue: rule.value,
                      decoration: const InputDecoration(
                        labelText: 'Condition description',
                        hintText: 'e.g. average temperature is less than 0',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (val) {
                        setState(() {
                          _localRules[idx] = rule.copyWith(value: val.trim());
                        });
                      },
                    ),
                  ],
                ),
              ),
            );
          }),
          ElevatedButton.icon(
            onPressed: () {
              setState(() {
                _localRules.add(
                  Edge(
                    id: const Uuid().v4(),
                    sourceAgentId: widget.executor.id,
                    variable: 'task_result',
                    operator: 'llm_eval',
                    value: '',
                    targetAgentId: otherExecutors.isNotEmpty
                        ? otherExecutors.first.id
                        : widget.executor.id,
                  ),
                );
              });
            },
            icon: const Icon(Icons.add),
            label: const Text('Add Branching Condition'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.purple,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildScheduleTabContent() {
    final bool isEnabled = _isAgentSchedulingEnabled();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!isEnabled) ...[
          Card(
            color: Colors.orange.withValues(alpha: 0.1),
            margin: const EdgeInsets.only(bottom: 16),
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.orange),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Scheduling is disabled because this agent is called sequentially or conditionally by a previous one.',
                      style: TextStyle(fontSize: 12, color: Colors.orange),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        const Text(
          'Cron Schedule',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: _cronExpressionCtrl,
          enabled: isEnabled,
          decoration: InputDecoration(
            labelText: 'Cron Expression',
            hintText: 'e.g. */5 * * * * or 0 8 * * *',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: const Icon(Icons.calendar_month),
              onPressed: isEnabled
                  ? () async {
                      final res = await showDialog<Map<String, String>>(
                        context: context,
                        builder: (context) => SchedulePickerDialog(
                          initialCron: _cronExpressionCtrl.text,
                          allowSubHourly: true,
                        ),
                      );
                      if (res != null && res['cron'] != null) {
                        setState(() {
                          _cronExpressionCtrl.text = res['cron']!;
                        });
                      }
                    }
                  : null,
            ),
          ),
          style: const TextStyle(fontFamily: 'monospace'),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children:
              [
                {'Every 15 minutes': '*/15 * * * *'},
                {'Hourly': '0 * * * *'},
                {'Daily 8am': '0 8 * * *'},
                {'Daily 6pm': '0 18 * * *'},
                {'Mon-Fri 9am': '0 9 * * 1-5'},
                {'Weekly (Mon)': '0 8 * * 1'},
                {'Monthly 1st': '0 8 1 * *'},
              ].map((presetMap) {
                final label = presetMap.keys.first;
                final cronVal = presetMap.values.first;
                return ActionChip(
                  label: Text(label, style: const TextStyle(fontSize: 12)),
                  onPressed: isEnabled
                      ? () {
                          setState(() {
                            _cronExpressionCtrl.text = cronVal;
                            _scheduleHintCtrl.text = label;
                          });
                        }
                      : null,
                  visualDensity: VisualDensity.compact,
                );
              }).toList(),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _scheduleHintCtrl,
          enabled: isEnabled,
          decoration: const InputDecoration(
            labelText: 'Schedule Description',
            hintText: 'e.g. Daily at 8:00 AM',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          'Error Handling',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: _maxRetriesCtrl,
                enabled: isEnabled,
                decoration: const InputDecoration(
                  labelText: 'Max Retries',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: TextFormField(
                controller: _retryDelayCtrl,
                enabled: isEnabled,
                decoration: const InputDecoration(
                  labelText: 'Retry Delay (min)',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildOutputTabContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          initialValue: ['none', 'download', 'sftp', 'email', 'slack', 'whatsapp', 'push'].contains(_outputType)
              ? _outputType
              : 'none',
          decoration: const InputDecoration(
            labelText: 'Output Channel',
            border: OutlineInputBorder(),
          ),
          items: const [
            DropdownMenuItem(
              value: 'none',
              child: Text('None (Save locally only)'),
            ),
            DropdownMenuItem(
              value: 'download',
              child: Text('File Output (Save to disk)'),
            ),
            DropdownMenuItem(
              value: 'sftp',
              child: Text('SFTP Output (Upload to server)'),
            ),
            DropdownMenuItem(value: 'email', child: Text('Email Alert')),
            DropdownMenuItem(value: 'slack', child: Text('Slack Alert')),
            DropdownMenuItem(value: 'whatsapp', child: Text('WhatsApp Alert')),
            DropdownMenuItem(
              value: 'push',
              child: Text('Device Push Notification'),
            ),
          ],
          onChanged: (val) {
            if (val == null) return;
            setState(() {
              _outputType = val;
            });
          },
        ),
        if (_outputType == 'download') ...[
          const SizedBox(height: 16),
          TextFormField(
            controller: _downloadPathCtrl,
            decoration: const InputDecoration(
              labelText: 'Download Path (empty = default downloads folder)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _fileNamePatternCtrl,
            decoration: const InputDecoration(
              labelText: 'File Name Pattern (e.g. report_{date}.txt)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          CheckboxListTile(
            value: _zipOutputFiles,
            onChanged: (v) => setState(() => _zipOutputFiles = v ?? false),
            title: const Text('Zip Output Files'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.trailing,
            dense: true,
          ),
          CheckboxListTile(
            value: _addExecutionLog,
            onChanged: (v) => setState(() => _addExecutionLog = v ?? false),
            title: const Text('Add Execution Log'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.trailing,
            dense: true,
          ),
        ],
        if (_outputType == 'sftp') ...[
          const SizedBox(height: 16),
          CheckboxListTile(
            value: _sftpUseConfiguredSshServer,
            onChanged: (v) =>
                setState(() => _sftpUseConfiguredSshServer = v ?? true),
            title: const Text(
              'Use Global SSH Server configured in Data Sources',
            ),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.trailing,
            dense: true,
          ),
          if (!_sftpUseConfiguredSshServer) ...[
            const SizedBox(height: 12),
            TextFormField(
              controller: _sftpHostCtrl,
              decoration: const InputDecoration(
                labelText: 'SFTP Host',
                hintText: 'sftp.example.com',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _sftpPortCtrl,
              decoration: const InputDecoration(
                labelText: 'SFTP Port',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _sftpUsernameCtrl,
              decoration: const InputDecoration(
                labelText: 'SFTP Username',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _sftpPasswordCtrl,
              decoration: const InputDecoration(
                labelText: 'SFTP Password',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
            ),
            const SizedBox(height: 12),
            TextFormField(
              initialValue: _sftpPrivateKeyPem,
              decoration: const InputDecoration(
                labelText: 'Private Key PEM (optional)',
                border: OutlineInputBorder(),
              ),
              maxLines: 4,
              onChanged: (v) => _sftpPrivateKeyPem = v.trim(),
            ),
          ],
          const SizedBox(height: 12),
          TextFormField(
            controller: _sftpRemotePathCtrl,
            decoration: const InputDecoration(
              labelText: 'Remote Directory Path (e.g. /uploads)',
              border: OutlineInputBorder(),
            ),
          ),
        ],
        if (_outputType == 'email') ...[
          const SizedBox(height: 16),
          TextFormField(
            controller: _emailToCtrl,
            decoration: const InputDecoration(
              labelText: 'Receiver Addresses (comma separated)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _emailSubjectCtrl,
            decoration: const InputDecoration(
              labelText: 'Subject Line',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: ['always', 'on_success', 'on_failure'].contains(_emailSendConditionCtrl.text)
                ? _emailSendConditionCtrl.text
                : 'always',
            decoration: const InputDecoration(
              labelText: 'Send Condition',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: 'always', child: Text('Always')),
              DropdownMenuItem(value: 'on_success', child: Text('On success')),
              DropdownMenuItem(value: 'on_failure', child: Text('On failure')),
            ],
            onChanged: (v) => _emailSendConditionCtrl.text = v ?? 'always',
          ),
        ],
        if (_outputType == 'slack') ...[
          const SizedBox(height: 16),
          TextFormField(
            controller: _slackChannelCtrl,
            decoration: const InputDecoration(
              labelText: 'Slack Override Channel (e.g. #general, optional)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: ['always', 'on_success', 'on_failure'].contains(_slackSendCondition)
                ? _slackSendCondition
                : 'always',
            decoration: const InputDecoration(
              labelText: 'Send Condition',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: 'always', child: Text('Always')),
              DropdownMenuItem(value: 'on_success', child: Text('On success')),
              DropdownMenuItem(value: 'on_failure', child: Text('On failure')),
            ],
            onChanged: (v) =>
                setState(() => _slackSendCondition = v ?? 'always'),
          ),
        ],
        if (_outputType == 'whatsapp') ...[
          const SizedBox(height: 16),
          TextFormField(
            controller: _whatsappRecipientCtrl,
            decoration: const InputDecoration(
              labelText: 'WhatsApp Override Recipient (e.g. +43..., optional)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: ['always', 'on_success', 'on_failure'].contains(_whatsappSendCondition)
                ? _whatsappSendCondition
                : 'always',
            decoration: const InputDecoration(
              labelText: 'Send Condition',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: 'always', child: Text('Always')),
              DropdownMenuItem(value: 'on_success', child: Text('On success')),
              DropdownMenuItem(value: 'on_failure', child: Text('On failure')),
            ],
            onChanged: (v) =>
                setState(() => _whatsappSendCondition = v ?? 'always'),
          ),
        ],
        if (_outputType == 'push') ...[
          const SizedBox(height: 16),
          TextFormField(
            controller: _pushTitleCtrl,
            decoration: const InputDecoration(
              labelText: 'Push Notification Title (optional)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: ['always', 'on_success', 'on_failure'].contains(_pushSendCondition)
                ? _pushSendCondition
                : 'always',
            decoration: const InputDecoration(
              labelText: 'Send Condition',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: 'always', child: Text('Always')),
              DropdownMenuItem(value: 'on_success', child: Text('On success')),
              DropdownMenuItem(value: 'on_failure', child: Text('On failure')),
            ],
            onChanged: (v) =>
                setState(() => _pushSendCondition = v ?? 'always'),
          ),
        ],
      ],
    );
  }

  Widget _buildExpansionSection({
    required IconData icon,
    required String title,
    required Widget child,
    bool initiallyExpanded = false,
  }) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: Icon(icon, color: AppTheme.primaryBlue),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        initiallyExpanded: initiallyExpanded,
        dense: true,
        minTileHeight: 44,
        tilePadding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
        childrenPadding: const EdgeInsets.fromLTRB(12, 2, 12, 10),
        expandedAlignment: Alignment.centerLeft,
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: [child],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final otherExecutors = widget.parentTask.agents
        .where(
          (e) =>
              e.id != widget.executor.id &&
              !_isUpstream(e.id, widget.executor.id),
        )
        .toList();

    final isMobile = MediaQuery.of(context).size.width < 800;

    return Scaffold(
      appBar: AppBar(
        title: Text('Edit Agent: ${widget.executor.name}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            onPressed: _save,
            tooltip: 'Save Agent',
          ),
        ],
        bottom: !isMobile
            ? TabBar(
                controller: _subTabController,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: const [
                  Tab(icon: Icon(Icons.extension), text: 'Tools'),
                  Tab(icon: Icon(Icons.edit_note), text: 'Prompts'),
                  Tab(icon: Icon(Icons.smart_toy), text: 'LLM Override'),
                  Tab(icon: Icon(Icons.call_split), text: 'Routing'),
                  Tab(icon: Icon(Icons.schedule), text: 'Schedule'),
                  Tab(icon: Icon(Icons.output), text: 'Output'),
                ],
              )
            : null,
      ),
      body: SafeArea(
        child: isMobile
            ? ListView(
                padding: const EdgeInsets.symmetric(vertical: 12),
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    child: TextFormField(
                      controller: _nameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Agent Name',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  _buildExpansionSection(
                    icon: Icons.extension,
                    title: 'Tools',
                    initiallyExpanded: true,
                    child: _buildToolsTabContent(),
                  ),
                  _buildExpansionSection(
                    icon: Icons.edit_note,
                    title: 'Prompts',
                    initiallyExpanded: true,
                    child: _buildPromptsTabContent(),
                  ),
                  _buildExpansionSection(
                    icon: Icons.smart_toy,
                    title: 'LLM',
                    child: _buildLlmTabContent(),
                  ),
                  _buildExpansionSection(
                    icon: Icons.call_split,
                    title: 'Routing',
                    child: _buildRoutingTabContent(otherExecutors),
                  ),
                  _buildExpansionSection(
                    icon: Icons.schedule,
                    title: 'Schedule',
                    child: _buildScheduleTabContent(),
                  ),
                  _buildExpansionSection(
                    icon: Icons.output,
                    title: 'Output',
                    child: _buildOutputTabContent(),
                  ),
                ],
              )
            : TabBarView(
                controller: _subTabController,
                children: [
                  SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: _buildToolsTabContent(),
                  ),
                  SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextFormField(
                          controller: _nameCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Agent Name',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 16),
                        _buildPromptsTabContent(),
                      ],
                    ),
                  ),
                  SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: _buildLlmTabContent(),
                  ),
                  SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: _buildRoutingTabContent(otherExecutors),
                  ),
                  SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: _buildScheduleTabContent(),
                  ),
                  SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: _buildOutputTabContent(),
                  ),
                ],
              ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Execution helpers and data structures
// ═══════════════════════════════════════════════════════════════════

class _ExecEntry {
  final String type;
  final String text;
  final String? details;
  final DateTime timestamp;

  _ExecEntry({
    required this.type,
    required this.text,
    this.details,
    required this.timestamp,
  });
}

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

String _buildExecutionLog({
  required WorkflowTask task,
  required bool taskSuccess,
  required List<ChatMessage> messages,
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

  for (final msg in messages) {
    if (msg.role == ChatRole.user) {
      sb.writeln('### User');
      sb.writeln(msg.content.trim());
      sb.writeln();
    } else if (msg.role == ChatRole.assistant) {
      final text = msg.content.trim();
      if (text.isNotEmpty) {
        sb.writeln('### Assistant');
        sb.writeln(text);
        sb.writeln();
      }
    } else if (msg.role == ChatRole.tool) {
      final toolName = msg.lastCalledToolName ?? 'tool';
      sb.writeln('### Tool: $toolName');
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

  return sb.toString();
}

String _buildOutputLog({
  required WorkflowTask task,
  required List<ChatMessage> messages,
}) {
  final sb = StringBuffer();
  sb.writeln('# Output Log: ${task.name}');
  sb.writeln();
  for (final msg in messages) {
    if (msg.role == ChatRole.user) {
      sb.writeln('### User');
      sb.writeln(msg.content.trim());
      sb.writeln();
    } else if (msg.role == ChatRole.assistant) {
      final text = msg.content.trim();
      if (text.isNotEmpty) {
        sb.writeln('### Assistant');
        sb.writeln(text);
        sb.writeln();
      }
    }
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
  required String resultText,
  required List<ChatMessage> messages,
  required bool taskSuccess,
}) async {
  try {
    final generatedFiles = <_GeneratedFile>[];
    final savedFilePaths = <String>[];
    final toolAttachments = _extractEmailAttachmentsFromMessages(messages);
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
      final runDir = Directory(
        '$resolvedDirPath${Platform.pathSeparator}$runFolderName',
      );
      if (!await runDir.exists()) await runDir.create(recursive: true);
      outputDir = runDir;
    }

    final outputLogContent = _buildOutputLog(task: task, messages: messages);
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
        messages: messages,
      );
      generatedFiles.add(
        _GeneratedFile(
          name: 'execution_log.md',
          mimeType: 'text/markdown',
          bytes: Uint8List.fromList(utf8.encode(execLog)),
        ),
      );
    }

    final htmlSections = _extractHtmlSections(resultText);
    for (int i = 0; i < htmlSections.length; i++) {
      final htmlName = htmlSections.length == 1
          ? 'output.html'
          : 'output_${i + 1}.html';
      generatedFiles.add(
        _GeneratedFile(
          name: htmlName,
          mimeType: 'text/html',
          bytes: Uint8List.fromList(utf8.encode(htmlSections[i])),
        ),
      );
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
