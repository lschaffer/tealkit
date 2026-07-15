import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/database_providers.dart';
import '../utils/cron_utils.dart';
import '../models/workflow_task.dart';

class GlobalAgentStatsWidget extends ConsumerWidget {
  const GlobalAgentStatsWidget({super.key});

  bool _isScheduledTask(WorkflowTask task) {
    final cron = task.executionPlan.cronExpression.trim();
    return cron.isNotEmpty && cron != '@manual';
  }

  String _formatDate(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasksAsync = ref.watch(taskListProvider);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final screenWidth = MediaQuery.sizeOf(context).width;

    return tasksAsync.when(
      data: (tasks) {
        final total = tasks.length;
        final scheduledTasks = tasks.where((t) => t.enabled && _isScheduledTask(t)).toList();
        final scheduled = scheduledTasks.length;

        DateTime? nextRun;
        WorkflowTask? nextTask;
        for (final t in scheduledTasks) {
          try {
            final next = nextCronFire(t.executionPlan.cronExpression.trim());
            if (nextRun == null || next.isBefore(nextRun)) {
              nextRun = next;
              nextTask = t;
            }
          } catch (_) {}
        }

        final tooltipMsg = nextTask != null
            ? 'Next Agent Scheduled:\n'
                'Name: ${nextTask.name}\n'
                'Model: ${nextTask.llmConfig?.model ?? "Inherited"}\n'
                'Prompt: ${nextTask.prompt.length > 150 ? "${nextTask.prompt.substring(0, 150)}..." : nextTask.prompt}'
            : '';

        if (screenWidth < 1000) {
          return PopupMenuButton<void>(
            icon: Icon(
              Icons.insights_outlined,
              color: isDark ? const Color(0xFF06B6D4) : const Color(0xFF7C3AED),
            ),
            tooltip: 'Agent Statistics',
            itemBuilder: (context) => [
              PopupMenuItem(
                enabled: false,
                child: Row(
                  children: [
                    Icon(Icons.smart_toy_outlined, size: 16, color: isDark ? const Color(0xFF06B6D4) : const Color(0xFF7C3AED)),
                    const SizedBox(width: 8),
                    Text(
                      'Total: $total',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuItem(
                enabled: false,
                child: Row(
                  children: [
                    Icon(Icons.schedule_outlined, size: 16, color: isDark ? const Color(0xFF34D399) : Colors.green[600]),
                    const SizedBox(width: 8),
                    Text(
                      'Scheduled: $scheduled',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuItem(
                enabled: false,
                child: Tooltip(
                  message: tooltipMsg,
                  child: Row(
                    children: [
                      Icon(Icons.update_outlined, size: 16, color: Colors.orange[400]),
                      const SizedBox(width: 8),
                      Text(
                        nextRun != null ? 'Next: ${_formatDate(nextRun)}' : 'Next: Never',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        }

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: isDark ? Colors.white.withValues(alpha: 0.04) : Colors.black.withValues(alpha: 0.03),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark ? Colors.white10 : Colors.black12,
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.smart_toy_outlined, size: 14, color: isDark ? const Color(0xFF06B6D4) : const Color(0xFF7C3AED)),
              const SizedBox(width: 6),
              Text(
                'Total: $total',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  color: isDark ? Colors.white70 : Colors.black87,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                height: 12,
                width: 1,
                color: isDark ? Colors.white24 : Colors.black12,
              ),
              const SizedBox(width: 8),
              Icon(Icons.schedule_outlined, size: 14, color: isDark ? const Color(0xFF34D399) : Colors.green[600]),
              const SizedBox(width: 6),
              Text(
                'Scheduled: $scheduled',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  color: isDark ? Colors.white70 : Colors.black87,
                ),
              ),
              if (nextRun != null) ...[
                const SizedBox(width: 8),
                Container(
                  height: 12,
                  width: 1,
                  color: isDark ? Colors.white24 : Colors.black12,
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: tooltipMsg,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.update_outlined, size: 14, color: Colors.orange[400]),
                      const SizedBox(width: 6),
                      Text(
                        'Next: ${_formatDate(nextRun)}',
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                          color: isDark ? Colors.white70 : Colors.black87,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (err, stack) => const SizedBox.shrink(),
    );
  }
}
