import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../config/app_theme.dart';
import '../database/legacy_duckdb_migrator.dart';
import '../database/task_database_service.dart';
import '../mcp/internal_mcp_registry.dart';
import '../providers/database_providers.dart';
import '../services/app_logger.dart';
import '../services/github_mcp_library_service.dart';
import '../services/scheduler_service.dart';

/// Modal startup dialog shown when an unmigrated `mobile_ai_agent.duckdb` is
/// detected: displays live progress while converting to SQLite, then shows the
/// final migration summary or error details (with Retry).
class DatabaseUpgradeDialog extends ConsumerStatefulWidget {
  const DatabaseUpgradeDialog({super.key});

  static bool _checkedThisSession = false;

  /// Checks if a legacy DuckDB file needs migration and opens the upgrade dialog.
  static Future<void> checkAndRunIfNeeded(
    BuildContext context,
    WidgetRef ref,
  ) async {
    if (_checkedThisSession) return;
    _checkedThisSession = true;

    try {
      final hasPending = await LegacyDuckDbBridgeMigrator.hasPendingMigration();
      if (!hasPending || !context.mounted) return;

      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const DatabaseUpgradeDialog(),
      );
    } catch (e) {
      log.error('[DB-Upgrade] Failed checking pending DuckDB migration: $e');
    }
  }

  @override
  ConsumerState<DatabaseUpgradeDialog> createState() =>
      _DatabaseUpgradeDialogState();
}

class _DatabaseUpgradeDialogState extends ConsumerState<DatabaseUpgradeDialog> {
  bool _running = true;
  String _stepText = 'Starting DuckDB → SQLite database upgrade...';
  DatabaseMigrationReport? _report;
  String? _error;

  @override
  void initState() {
    super.initState();
    _startMigration();
  }

  Future<void> _startMigration() async {
    setState(() {
      _running = true;
      _error = null;
      _report = null;
      _stepText = 'Starting DuckDB → SQLite database upgrade...';
    });

    try {
      final report = await LegacyDuckDbBridgeMigrator.migrate(
        onProgress: (step) {
          if (mounted) {
            setState(() => _stepText = step);
          }
        },
      );

      // Refresh in-memory caches & Riverpod providers with migrated SQLite data
      try {
        await GithubMcpLibraryService.instance.load();
        InternalMcpRegistry().registerGithubMcpServers();
        final tasks = await TaskDatabaseService().getAllTasks();
        await appScheduler.syncAllTasks(tasks);
      } catch (e) {
        log.warning('[DB-Upgrade] Post-migration service reload warning: $e');
      }

      if (mounted) {
        ref.invalidate(taskListProvider);
        setState(() {
          _running = false;
          _report = report;
        });
      }
    } catch (e, st) {
      log.error('[DB-Upgrade] Migration failed: $e\n$st');
      if (mounted) {
        setState(() {
          _running = false;
          _error = e.toString();
        });
      }
    }
  }

  Widget _buildBody(ThemeData theme) {
    if (_running) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          const CircularProgressIndicator(),
          const SizedBox(height: 18),
          Text(
            _stepText,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Migrating workflows, skills, MCP settings, and sub-agents to the lightweight SQLite + Vector engine. Please wait...',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    }

    if (_error != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'An error occurred while converting your legacy DuckDB database. Your original database file was kept untouched.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.error.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.error.withValues(alpha: 0.4)),
            ),
            child: SelectableText(
              _error!,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ],
      );
    }

    final r = _report!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Your local data has been migrated to SQLite successfully and the legacy DuckDB file has been archived (.migrated.bak).',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 14),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.5,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _statRow('Workflows / Tasks', r.tasksMigrated),
              _statRow('Skills (AgentSkills)', r.skillsMigrated),
              _statRow('Specialized Sub-Agents', r.subagentsMigrated),
              _statRow('Task MCP Configurations', r.mcpConfigsMigrated),
              _statRow(
                'Python Tools & GitHub MCPs',
                r.pyToolsMigrated + r.githubMcpsMigrated,
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'Note: LLM profiles, API keys, and credentials remain intact in secure storage. Local document/website search indexes were skipped and can be re-indexed anytime in Data Sources.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _statRow(String label, int count) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(child: Text(label, style: const TextStyle(fontSize: 13))),
        Text(
          '$count',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isMobile = MediaQuery.sizeOf(context).width < 700;

    final IconData titleIcon = _running
        ? Icons.storage_rounded
        : (_error != null ? Icons.error_outline : Icons.check_circle_outline);
    final Color iconColor = _running
        ? AppTheme.primaryBlue
        : (_error != null ? AppTheme.error : AppTheme.success);
    final String titleText = _running
        ? 'Upgrading Local Database'
        : (_error != null
              ? 'Database Upgrade Failed'
              : 'Database Upgrade Complete');

    final actions = <Widget>[
      if (!_running && _error != null) ...[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton.icon(
          onPressed: _startMigration,
          icon: const Icon(Icons.refresh, size: 16),
          label: const Text('Retry'),
        ),
      ] else if (!_running)
        FilledButton.icon(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.check, size: 16),
          label: const Text('Continue'),
        ),
    ];

    if (isMobile) {
      return Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: false,
            title: Row(
              children: [
                Icon(titleIcon, color: iconColor, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(titleText, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: _buildBody(theme),
            ),
          ),
          bottomNavigationBar: actions.isEmpty
              ? null
              : SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 10,
                      children: actions,
                    ),
                  ),
                ),
        ),
      );
    }

    return AlertDialog(
      title: Row(
        children: [
          Icon(titleIcon, color: iconColor, size: 24),
          const SizedBox(width: 10),
          Expanded(child: Text(titleText, overflow: TextOverflow.ellipsis)),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: SingleChildScrollView(child: _buildBody(theme)),
      ),
      actions: actions,
    );
  }
}
