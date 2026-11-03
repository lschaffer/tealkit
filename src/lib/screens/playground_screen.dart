import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_ui_mcp/flutter_ui_mcp.dart' hide Agent;
import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';

import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../models/workflow_task.dart';
import '../providers/database_providers.dart';
import '../providers/server_mode_provider.dart';
import '../providers/sidebar_provider.dart';
import '../services/llm_settings_service.dart';
import '../services/skill_def_database_service.dart';
import '../services/tealkit_database_storage_delegate.dart';
import '../services/tealkit_tools_builder.dart';
import '../widgets/tealkit_assistant_settings_dialog.dart';
import 'skills_list_screen.dart';

/// Redesigned Assistant / Playground screen for TealKit.
///
/// Built on [McpPlayground] with:
/// - Direct-to-chat layout, status badges, and collapsible Agent Inspector.
/// - Inherits TealKit's dark color theme (Navy/Cyan/Teal), eliminating brown/peach tones.
/// - Reconnects the hamburger button to toggle TealKit's main sidebar (Workflows, Assistent, Einstellungen).
/// - Seamless load/save of TealKit Workflows and Skills.
/// - Automatic synchronization of TealKit's active LLM provider, model, and credentials.
/// - Full Coding Agent Mode toggle (enable & disable) with the Thiescoder bottom mode selector bar.
class PlaygroundScreen extends ConsumerStatefulWidget {
  /// Optional pre-existing task to initialise from.
  final WorkflowTask? task;

  const PlaygroundScreen({super.key, this.task});

  @override
  ConsumerState<PlaygroundScreen> createState() => _PlaygroundScreenState();
}

class _PlaygroundScreenState extends ConsumerState<PlaygroundScreen> {
  static const List<String> _kCodingToolNames = [
    'fs_read_file',
    'fs_write_file',
    'fs_replace_text',
    'fs_find',
    'fs_list_dir',
    'fs_create_dir',
    'fs_move',
    'fs_delete',
    'terminal_exec',
    'fetch_web',
  ];

  static const List<String> _kRagToolNames = [
    'search_documents',
    'get_document_content',
    'list_documents',
    'search_indexed_websites',
    'get_indexed_page',
    'list_indexed_pages',
  ];

  late final TealKitDatabaseStorageDelegate _storageDelegate;
  late final PlaygroundController _controller;
  String _workspaceDirectory = Directory.current.path;
  late List<McpLocalTool> _localTools;

  bool _isCodingMode = false;
  String _codingSubMode = '/code';
  String? _previousSystemPrompt;
  Set<String>? _previousEnabledTools;

  @override
  void initState() {
    super.initState();
    _storageDelegate = TealKitDatabaseStorageDelegate();
    _refreshTools();

    final initialLlm = _storageDelegate.getTealKitLlmConfig();
    _controller = PlaygroundController(
      storageDelegate: _storageDelegate,
      initialLlmConfig: initialLlm,
      customLocalTools: _localTools,
    );
    _controller.workspaceDirectory = _workspaceDirectory;
    _controller.codingSubMode = _codingSubMode;
    _controller.permissions.reload();

    if (widget.task != null) {
      _applyWorkflowTask(widget.task!, _controller);
    }

    // Sync any external changes from TealKit's settings
    LlmSettingsService.instance.addListener(_onTealKitLlmSettingsChanged);
  }

  bool _isDisposed = false;

  @override
  void dispose() {
    _isDisposed = true;
    LlmSettingsService.instance.removeListener(_onTealKitLlmSettingsChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onTealKitLlmSettingsChanged() {
    if (_isDisposed || !mounted) return;
    final cfg = _storageDelegate.getTealKitLlmConfig();
    if (cfg == null) return;

    final active = _controller.activeLlmConfig;
    final isSame = active.provider == cfg.provider &&
        active.model == cfg.model &&
        active.apiKey == cfg.apiKey &&
        active.baseUrl == cfg.baseUrl &&
        (active.temperature - cfg.temperature).abs() < 0.001 &&
        active.maxTokens == cfg.maxTokens;
    if (isSame) return;

    _controller.updateLlmConfig(cfg);
  }

  void _refreshTools() {
    _localTools = TealKitToolsBuilder.buildAllTools(
      workspaceDirectory: _workspaceDirectory,
    );
  }

  // ─────────────────────────────────────────────────────────────
  // Coding Agent Mode Toggle & Sub-Modes
  // ─────────────────────────────────────────────────────────────

  Future<void> _toggleCodingAgentMode(BuildContext context) async {
    if (_isCodingMode) {
      // ── Disable Coding Agent Mode ──
      if (_previousSystemPrompt != null) {
        _controller.systemPrompt = _previousSystemPrompt!;
      }
      if (_previousEnabledTools != null) {
        for (final tool in _kCodingToolNames) {
          if (!_previousEnabledTools!.contains(tool)) {
            _controller.toggleToolEnabled(tool, false);
          }
        }
      }
      setState(() {
        _isCodingMode = false;
      });
      if (mounted) {
        final l = L.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('💻 ${l.codingAgentModeDisabled}'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    // ── Enable Coding Agent Mode ──
    final theme = Theme.of(context);
    final isMobile = MediaQuery.sizeOf(context).width < 700;

    Widget buildActivationContent(BuildContext ctx) {
      final l = L.of(ctx);
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l.codingAgentDescription,
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 16),
          Text(
            l.activeWorkspaceDirectory,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 12,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.folder_outlined, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _workspaceDirectory,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    final selected = await FilePicker.getDirectoryPath();
                    if (selected != null && ctx.mounted) {
                      setState(() {
                        _workspaceDirectory = selected;
                        _controller.workspaceDirectory = selected;
                        _refreshTools();
                      });
                      Navigator.pop(ctx, true);
                    }
                  },
                  child: Text(l.change),
                ),
              ],
            ),
          ),
        ],
      );
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final l = L.of(ctx);
        if (isMobile) {
          return Dialog.fullscreen(
            child: Scaffold(
              appBar: AppBar(
                title: Text(l.activateCodingAgent),
                leading: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(ctx, false),
                ),
              ),
              body: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      buildActivationContent(ctx),
                      const Spacer(),
                      FilledButton.icon(
                        icon: const Icon(Icons.check, size: 16),
                        label: Text(l.activateCodingAgent),
                        onPressed: () => Navigator.pop(ctx, true),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }

        return AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.terminal_rounded, color: Color(0xFF2DD4BF), size: 24),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l.activateCodingAgentMode,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: buildActivationContent(ctx),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l.cancel),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.check, size: 16),
              label: Text(l.activateCodingAgent),
              onPressed: () => Navigator.pop(ctx, true),
            ),
          ],
        );
      },
    );

    if (confirmed == true && mounted) {
      _previousSystemPrompt = _controller.systemPrompt;
      _previousEnabledTools = Set<String>.from(_controller.enabledToolNames);

      for (final t in _kCodingToolNames) {
        _controller.toggleToolEnabled(t, true);
      }

      _applyCodingSubMode(_codingSubMode);

      setState(() {
        _isCodingMode = true;
      });

      final l = L.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('💻 ${l.codingAgentModeActivated}'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _applyCodingSubMode(String mode) {
    _controller.codingSubMode = mode;
    _controller.workspaceDirectory = _workspaceDirectory;

    final isWin = Platform.isWindows;
    final osNotice = isWin
        ? 'HOST OS: Windows (${Platform.operatingSystemVersion}). Terminal commands execute via CMD/PowerShell. '
          'Do NOT use Linux commands like "cat", "grep", "ls -la", "touch". Use pure-Dart tools (fs_read_file, fs_find).'
        : 'HOST OS: POSIX (${Platform.operatingSystem}). Standard shell commands supported.';

    if (mode == '/rag') {
      // 1. Strictly disable all filesystem and terminal tools in RAG mode
      for (final t in _kCodingToolNames) {
        _controller.toggleToolEnabled(t, false);
      }
      // 2. Ensure all Document & Web-Crawl RAG tools are enabled
      for (final t in _kRagToolNames) {
        _controller.toggleToolEnabled(t, true);
      }

      _controller.systemPrompt =
          'You are a dedicated Knowledge Base & Documentation Assistant operating in workspace: "$_workspaceDirectory".\n'
          'YOUR ROLE: Answer user questions grounded strictly in local indexed documents and crawled websites.\n\n'
          'STRICT TOOL POLICY (MANDATORY):\n'
          '1. You MUST ONLY use document search tools (search_documents, get_document_content, list_documents) '
          'and web crawl tools (search_indexed_websites, get_indexed_page, list_indexed_pages).\n'
          '2. NEVER use filesystem tools (fs_list_dir, fs_find, fs_read_file) or terminal commands. '
          'Do NOT attempt to inspect the filesystem directly.\n'
          '3. If a document query yields no matches initially, refine search keywords, try synonyms, '
          'or use list_documents to see available files.\n'
          '4. Always cite specific document names and return factual excerpts.';
      return;
    }

    if (mode == '/ask') {
      // Exploration / Q&A: Disable file modifications & terminal commands
      for (final t in ['fs_write_file', 'fs_replace_text', 'terminal_exec', 'execute_command', 'git_commit']) {
        _controller.toggleToolEnabled(t, false);
      }
      // Enable read-only tools and web search
      for (final t in ['fs_read_file', 'fs_find', 'fs_list_dir', 'web_search', 'fetch_web']) {
        _controller.toggleToolEnabled(t, true);
      }

      _controller.systemPrompt =
          'You are an expert Codebase Explainer & Researcher operating in workspace: "$_workspaceDirectory".\n'
          'YOUR ROLE: Answer questions about code logic, architectural design, data flows, and dependencies.\n'
          'Use read-only inspection tools (fs_read_file, fs_find, fs_list_dir, web_search, fetch_web) to provide precise, referenced answers.\n'
          'NOTE: File modifications and terminal commands are disabled in /ask mode.';
      return;
    }

    // For non-RAG, non-ask modes (/code, /plan): ensure coding tools are active
    for (final t in _kCodingToolNames) {
      _controller.toggleToolEnabled(t, true);
    }

    switch (mode) {
      case '/plan':
        _controller.systemPrompt =
            'You are an autonomous Software Architect operating in workspace: "$_workspaceDirectory".\n'
            '$osNotice\n\n'
            'YOUR ROLE: Analyze code, design solutions, explore structure, and create implementation plans.\n'
            'ALLOWED ACTIONS: You may inspect files, search the web, and create or update planning documents (`tasks.md`, `implementation_plan.md`, `*.md`, `*.txt`, `*.yaml`).\n'
            'STRICT GUARD: You are FORBIDDEN from modifying source code files (.dart, .c, .cpp, .py, .js, .ts, etc.). Direct source code modifications will be blocked by the system until switching to /code mode.';
        break;
      case '/code':
      default:
        _controller.systemPrompt =
            'You are an autonomous Senior Software Engineer & Coding Agent operating in workspace: "$_workspaceDirectory".\n'
            '$osNotice\n\n'
            'CORE OPERATING INSTRUCTIONS:\n'
            '1. Always inspect and read existing files before modifying or overwriting.\n'
            '2. Prefer targeted text replacements (`fs_replace_text`) over full rewrites for large files.\n'
            '3. Test commands carefully and provide structured summaries of all code edits.\n'
            '4. If complex tasks require planning, decompose steps cleanly before execution.';
        break;
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Thiescoder Coding Mode Bottom Bar (Image 5)
  // ─────────────────────────────────────────────────────────────

  Widget _buildSubModePill(String mode, String label, IconData icon) {
    final isSelected = _codingSubMode == mode;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () {
        setState(() => _codingSubMode = mode);
        _applyCodingSubMode(mode);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFEA580C) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 13,
              color: isSelected ? Colors.white : const Color(0xFF94A3B8),
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected ? Colors.white : const Color(0xFF94A3B8),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openAssistantSettingsDialog(
    BuildContext context,
    PlaygroundController controller, {
    int initialTab = 0,
  }) {
    final size = MediaQuery.sizeOf(context);
    final isMobile = size.width < 700;
    showDialog(
      context: context,
      builder: (ctx) {
        if (isMobile) {
          return Dialog.fullscreen(
            child: TealKitAssistantSettingsDialog(
              controller: controller,
              initialTabIndex: initialTab,
              onClose: () => Navigator.of(ctx).pop(),
            ),
          );
        }
        return Dialog(
          insetPadding: EdgeInsets.symmetric(
            horizontal: size.width * 0.025,
            vertical: size.height * 0.025,
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: SizedBox(
            width: size.width * 0.95,
            height: size.height * 0.95,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: TealKitAssistantSettingsDialog(
                controller: controller,
                initialTabIndex: initialTab,
                onClose: () => Navigator.of(ctx).pop(),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCodingModeBar(BuildContext context, PlaygroundController controller) {
    final wsParts = _workspaceDirectory
        .split(Platform.pathSeparator)
        .where((s) => s.isNotEmpty)
        .toList();
    final wsName = wsParts.isNotEmpty ? wsParts.last : 'workspace';

    final activeConfig = controller.activeLlmConfig;
    final modelName = activeConfig.model.isNotEmpty
        ? activeConfig.model
        : (activeConfig.isConfigured ? activeConfig.provider.displayName : 'deepseek');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withValues(alpha: 0.95),
        border: Border(
          top: BorderSide(
            color: const Color(0xFF222B45).withValues(alpha: 0.8),
            width: 1,
          ),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            // Mode pills group: [ </code | 📐 /plan | ❓ /ask | 🚫 /rag ]
            Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFF334155), width: 0.8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildSubModePill('/code', '</code', Icons.code_rounded),
                  _buildSubModePill('/plan', '/plan', Icons.architecture_rounded),
                  _buildSubModePill('/ask', '/ask', Icons.help_outline_rounded),
                  _buildSubModePill('/rag', '/rag', Icons.do_not_disturb_on_outlined),
                ],
              ),
            ),
            const SizedBox(width: 8),

            // Workspace directory button: 📁 <folder> ▾ with orange outline
            InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () async {
                final selected = await FilePicker.getDirectoryPath();
                if (selected != null && mounted) {
                  setState(() {
                    _workspaceDirectory = selected;
                    _controller.workspaceDirectory = selected;
                    _refreshTools();
                  });
                  _applyCodingSubMode(_codingSubMode);
                }
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFFEA580C), width: 1.2),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.folder_outlined, size: 14, color: Color(0xFFEA580C)),
                    const SizedBox(width: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 130),
                      child: Text(
                        wsName,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFFFB923C),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.arrow_drop_down, size: 14, color: Color(0xFFFB923C)),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),

            // Active model badge: 🤖 <model> ▾ (Click to open LLM configuration)
            InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => _openAssistantSettingsDialog(context, controller, initialTab: 1),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFF334155), width: 0.8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.smart_toy_outlined, size: 14, color: Color(0xFF94A3B8)),
                    const SizedBox(width: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 120),
                      child: Text(
                        modelName,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFFE2E8F0),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.arrow_drop_down, size: 14, color: Color(0xFF94A3B8)),
                  ],
                ),
              ),
            ),

            const SizedBox(width: 12),

            // Stats badge: Turns: ∞ • Tools: N
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFF334155), width: 0.8),
              ),
              child: Text(
                L.of(context).turnsAndTools(controller.enabledToolNames.length),
                style: const TextStyle(
                  fontSize: 11,
                  color: Color(0xFF94A3B8),
                ),
              ),
            ),
            const SizedBox(width: 8),

            // Close / Exit coding mode button ✕
            IconButton(
              tooltip: L.of(context).disableCodingAgentMode,
              icon: const Icon(Icons.close, size: 16, color: Color(0xFF94A3B8)),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
              onPressed: () => _toggleCodingAgentMode(context),
            ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────
  // Workflow Load & Save Dialogs
  // ─────────────────────────────────────────────────────────────

  Future<void> _showLoadWorkflowDialog(
    BuildContext context,
    PlaygroundController controller,
  ) async {
    final l = L.of(context);
    final repo = ref.read(taskRepositoryProvider);
    final isRemote = ref.read(serverModeProvider).value?.isRemote ?? false;
    final tasks = await repo.getAllTasks();
    if (!context.mounted) return;

    if (tasks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isRemote
                ? l.noSavedWorkflowsRemote
                : l.noSavedWorkflowsLocal,
          ),
        ),
      );
      return;
    }

    final isMobile = MediaQuery.sizeOf(context).width < 700;

    final selectedTask = await showDialog<WorkflowTask>(
      context: context,
      useSafeArea: !isMobile,
      builder: (ctx) {
        final l = L.of(ctx);
        String searchQuery = '';
        return StatefulBuilder(
          builder: (ctx, setDlgState) {
            final filteredTasks = searchQuery.isEmpty
                ? tasks
                : tasks.where((t) {
                    final q = searchQuery.toLowerCase();
                    return t.name.toLowerCase().contains(q) ||
                        (t.description?.toLowerCase().contains(q) ?? false) ||
                        t.prompt.toLowerCase().contains(q);
                  }).toList();

            Widget buildWorkflowList() {
              if (filteredTasks.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Text(
                      l.noMatchingTasks,
                      style: const TextStyle(color: Colors.grey),
                    ),
                  ),
                );
              }
              return ListView.separated(
                shrinkWrap: !isMobile,
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: filteredTasks.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (ctx, index) {
                  final task = filteredTasks[index];
                  final promptText = task.systemPrompt?.isNotEmpty == true
                      ? task.systemPrompt!
                      : '${l.initialPrompt}: ${task.prompt}';
                  final toolCount = task.internalMcps.length + task.mcpTools.length;
                  final subtitleText = toolCount > 0
                      ? '${l.toolsSelected(toolCount)} • $promptText'
                      : promptText;
                  return ListTile(
                    leading: const Icon(Icons.account_tree_outlined),
                    title: Text(
                      task.name,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      subtitleText,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 18),
                          tooltip: l.deleteTask,
                          onPressed: () async {
                            final confirm = await showDialog<bool>(
                              context: ctx,
                              builder: (c) => AlertDialog(
                                title: Text(l.deleteTask),
                                content: Text(l.deleteTaskConfirm(task.name)),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(c, false),
                                    child: Text(l.cancel),
                                  ),
                                  FilledButton(
                                    style: FilledButton.styleFrom(backgroundColor: Colors.red),
                                    onPressed: () => Navigator.pop(c, true),
                                    child: Text(l.delete),
                                  ),
                                ],
                              ),
                            );
                            if (confirm == true) {
                              await repo.deleteTask(task.id);
                              ref.invalidate(taskListProvider);
                              setDlgState(() {
                                tasks.removeWhere((t) => t.id == task.id);
                              });
                            }
                          },
                        ),
                        const Icon(Icons.chevron_right, size: 18),
                      ],
                    ),
                    onTap: () => Navigator.pop(ctx, task),
                  );
                },
              );
            }

            final searchBar = Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: TextField(
                decoration: InputDecoration(
                  hintText: l.searchTasks,
                  prefixIcon: const Icon(Icons.search, size: 20),
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onChanged: (val) {
                  setDlgState(() {
                    searchQuery = val.trim();
                  });
                },
              ),
            );

            if (isMobile) {
              return Dialog.fullscreen(
                child: Scaffold(
                  appBar: AppBar(
                    title: Row(
                      children: [
                        Expanded(
                          child: Text(
                            l.loadWorkflow,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: isRemote ? Colors.purple.withAlpha(50) : Colors.teal.withAlpha(50),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isRemote ? Colors.purple : Colors.teal,
                              width: 0.8,
                            ),
                          ),
                          child: Text(
                            isRemote ? l.serverBadge : l.localBadge,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: isRemote ? Colors.purpleAccent : Colors.tealAccent,
                            ),
                          ),
                        ),
                      ],
                    ),
                    leading: IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ),
                  body: SafeArea(
                    child: Column(
                      children: [
                        searchBar,
                        Expanded(child: buildWorkflowList()),
                      ],
                    ),
                  ),
                ),
              );
            }

            return AlertDialog(
              title: Row(
                children: [
                  const Icon(Icons.folder_open_outlined, size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l.loadSavedWorkflow,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: isRemote ? Colors.purple.withAlpha(50) : Colors.teal.withAlpha(50),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isRemote ? Colors.purple : Colors.teal,
                        width: 0.8,
                      ),
                    ),
                    child: Text(
                      isRemote ? l.serverBadge : l.localBadge,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: isRemote ? Colors.purpleAccent : Colors.tealAccent,
                      ),
                    ),
                  ),
                ],
              ),
              content: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520, maxHeight: 450),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    searchBar,
                    Flexible(child: buildWorkflowList()),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(l.cancel),
                ),
              ],
            );
          },
        );
      },
    );

    if (selectedTask != null && mounted) {
      await _applyWorkflowTask(selectedTask, controller);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('✔ ${l.loadedWorkflow(selectedTask.name)}')),
        );
      }
    }
  }

  Future<void> _applyWorkflowTask(
    WorkflowTask task,
    PlaygroundController controller,
  ) async {
    // 1. System Prompt
    if (task.systemPrompt?.isNotEmpty == true) {
      controller.systemPrompt = task.systemPrompt!;
    }

    // 2. Chat Prompt
    final promptText = task.prompt.isNotEmpty
        ? task.prompt
        : (task.agents.isNotEmpty ? task.agents.first.prompt : '');
    if (promptText.isNotEmpty) {
      controller.setInputPrompt(promptText);
    }

    // 3. MCP & Internal Tools
    if (task.mcpTools.isNotEmpty) {
      for (final m in task.mcpTools) {
        final name = m.name;
        if (name != null && name.isNotEmpty) {
          controller.toggleToolEnabled(name, true);
        }
      }
    }
    for (final mcp in task.internalMcps) {
      controller.toggleToolEnabled(mcp.mcpType, true);
    }

    // 4. Resolve & Set Active Skill
    final skillId = task.agents
        .map((a) => a.skillDefId)
        .firstWhere((id) => id != null && id.isNotEmpty, orElse: () => null);

    SkillDef? matchedSkill;
    if (skillId != null) {
      final match = controller.skills.where((s) => s.id == skillId).toList();
      if (match.isNotEmpty) {
        matchedSkill = match.first;
      } else {
        final tkSkill = await SkillDefDatabaseService.instance.getSkill(skillId);
        if (tkSkill != null) {
          matchedSkill = SkillDef(
            id: tkSkill.id,
            name: tkSkill.name,
            goal: tkSkill.goal,
            description: tkSkill.description,
            skillDef: tkSkill.skillDef,
            toolNames: tkSkill.toolNames,
            createdAt: tkSkill.createdAt,
            updatedAt: tkSkill.updatedAt,
          );
        }
      }
    }

    if (matchedSkill == null) {
      final match = controller.skills.where(
        (s) => s.name.trim().toLowerCase() == task.name.trim().toLowerCase(),
      ).toList();
      if (match.isNotEmpty) {
        matchedSkill = match.first;
      }
    }

    controller.setActiveSkill(matchedSkill);
  }

  Future<void> _showSaveWorkflowDialog(
    BuildContext context,
    PlaygroundController controller,
  ) async {
    final l = L.of(context);
    final nameCtrl = TextEditingController(text: l.newTask);
    final isMobile = MediaQuery.sizeOf(context).width < 700;
    final isRemote = ref.read(serverModeProvider).value?.isRemote ?? false;

    Widget buildSaveForm(BuildContext ctx) {
      final l = L.of(ctx);
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isRemote
                ? l.saveWorkflowRemoteDesc
                : l.saveWorkflowLocalDesc,
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: nameCtrl,
            decoration: InputDecoration(
              labelText: l.workflowName,
              border: const OutlineInputBorder(),
            ),
            autofocus: true,
          ),
        ],
      );
    }

    final shouldSave = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final l = L.of(ctx);
        if (isMobile) {
          return Dialog.fullscreen(
            child: Scaffold(
              appBar: AppBar(
                title: Text(l.saveAsTask),
                leading: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(ctx, false),
                ),
                actions: [
                  Padding(
                    padding: const EdgeInsets.only(right: 12.0),
                    child: FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text(l.save),
                    ),
                  ),
                ],
              ),
              body: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: buildSaveForm(ctx),
                ),
              ),
            ),
          );
        }

        return AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.bookmark_add_outlined, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l.saveCurrentAsWorkflow,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: buildSaveForm(ctx),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(isRemote ? l.saveToServer : l.saveToDatabase),
            ),
          ],
        );
      },
    );

    if (shouldSave == true && mounted) {
      final name = nameCtrl.text.trim();
      if (name.isEmpty) return;

      final activeTools = controller.enabledToolNames;
      final currentPrompt = controller.currentInputPrompt.trim();
      final activeSkillId = controller.activeSkill?.id;
      final task = WorkflowTask(
        id: const Uuid().v4(),
        name: name,
        systemPrompt: controller.systemPrompt,
        prompt: currentPrompt,
        agents: [
          Agent(
            id: const Uuid().v4(),
            name: name,
            prompt: currentPrompt,
            systemPrompt: controller.systemPrompt,
            skillDefId: activeSkillId,
          ),
        ],
        internalMcps: activeTools
            .map((t) => InternalMcpEntry(
                  id: const Uuid().v4(),
                  mcpType: t,
                  enabled: true,
                ))
            .toList(),
        enabled: true,
        executionPlan: const ExecutionPlan(cronExpression: ''),
      );

      final repo = ref.read(taskRepositoryProvider);
      await repo.saveTask(task);
      ref.invalidate(taskListProvider);

      if (mounted) {
        final l = L.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isRemote
                  ? '✔ ${l.workflowSavedRemote(name)}'
                  : '✔ ${l.workflowSavedLocal(name)}',
            ),
          ),
        );
      }
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Skills Picker Integration
  // ─────────────────────────────────────────────────────────────

  Future<void> _openSkillsPicker(
    BuildContext context,
    PlaygroundController controller,
  ) async {
    final skill = await SkillsListScreen.showPicker(context);
    if (skill != null && mounted) {
      if (skill.skillDef.isNotEmpty) {
        controller.systemPrompt = skill.skillDef;
      }
      for (final tool in skill.toolNames) {
        controller.toggleToolEnabled(tool, true);
      }
      controller.setActiveSkill(SkillDef(
        id: skill.id,
        name: skill.name,
        goal: skill.goal,
        description: skill.description,
        skillDef: skill.skillDef,
        toolNames: skill.toolNames,
        createdAt: skill.createdAt,
        updatedAt: skill.updatedAt,
      ));
      final l = L.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('✔ ${l.appliedSkill(skill.name)}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDesktopPlatform = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.macOS);
    final isDesktop = isDesktopPlatform && MediaQuery.of(context).size.width >= 900;

    // TealKit unified dark color theme inherited across all dialogs, popups, and components
    final tealKitTheme = ThemeData.dark().copyWith(
      scaffoldBackgroundColor: AppTheme.backgroundDark,
      cardColor: AppTheme.surfaceDark,
      colorScheme: const ColorScheme.dark(
        surface: AppTheme.surfaceDark,
        surfaceContainer: AppTheme.surfaceDark,
        surfaceContainerHigh: Color(0xFF162544),
        surfaceContainerHighest: AppTheme.cardDark,
        surfaceContainerLow: Color(0xFF0D1B33),
        surfaceContainerLowest: AppTheme.backgroundDark,
        primary: AppTheme.primaryBlue,
        secondary: AppTheme.accent,
        onSurface: AppTheme.textOnDark,
        onPrimary: Colors.white,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppTheme.backgroundDark,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      drawerTheme: const DrawerThemeData(
        backgroundColor: AppTheme.surfaceDark,
      ),
      popupMenuTheme: const PopupMenuThemeData(
        color: AppTheme.surfaceDark,
        surfaceTintColor: Colors.transparent,
        textStyle: TextStyle(color: AppTheme.textOnDark),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppTheme.surfaceDark,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );

    return Theme(
      data: tealKitTheme,
      child: McpPlayground(
        controller: _controller,
        storageDelegate: _storageDelegate,
        customLocalTools: _localTools,
        showDrawer: false, // Prevents internal drawer; hamburger toggles TealKit's main sidebar!
        showAgentInspector: true,
        enableLogging: true,
        showSystemPromptTemplates: false,
        showWorkflowActions: false,
        showSkillsControls: false,
        settingsDialogBuilder: (ctx, ctrl, initialTab, onClose) {
          final size = MediaQuery.sizeOf(ctx);
          final isMobile = size.width < 700;
          if (isMobile) {
            return Dialog.fullscreen(
              child: TealKitAssistantSettingsDialog(
                controller: ctrl,
                initialTabIndex: initialTab,
                onClose: onClose,
              ),
            );
          }
          return Dialog(
            insetPadding: EdgeInsets.symmetric(
              horizontal: size.width * 0.025,
              vertical: size.height * 0.025,
            ),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: SizedBox(
              width: size.width * 0.95,
              height: size.height * 0.95,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: TealKitAssistantSettingsDialog(
                  controller: ctrl,
                  initialTabIndex: initialTab,
                  onClose: onClose,
                ),
              ),
            ),
          );
        },
        inputTopWidgetBuilder: (ctx, ctrl) {
          if (!isDesktop || !_isCodingMode) return const SizedBox.shrink();
          return _buildCodingModeBar(ctx, ctrl);
        },
        topBarBuilder: (ctx, controller, actions) {
          final l = L.of(ctx);
          return AppBar(
            // Reconnected leading hamburger button to toggle TealKit's sidebar
            leading: Builder(
              builder: (navCtx) {
                final route = ModalRoute.of(navCtx);
                final canGoBack =
                    route != null && !route.isFirst && Navigator.of(navCtx).canPop();
                if (canGoBack) {
                  return IconButton(
                    icon: const Icon(Icons.arrow_back),
                    tooltip: l.back,
                    onPressed: () => Navigator.of(navCtx).maybePop(),
                  );
                }
                return Consumer(
                  builder: (context, ref, _) {
                    final isOpen = ref.watch(sidebarOpenProvider);
                    return IconButton(
                      icon: const Icon(Icons.menu),
                      tooltip: l.toggleTealKitMenu,
                      onPressed: () {
                        ref.read(sidebarOpenProvider.notifier).state = !isOpen;
                      },
                    );
                  },
                );
              },
            ),
            title: actions.defaultTitleWidget,
            actions: [
              // 1. Dedicated Coding Agent Button (Toggleable on Desktop)
              if (isDesktop)
                IconButton(
                  tooltip: _isCodingMode
                      ? l.codingAgentModeActiveTooltip
                      : l.activateCodingAgentMode,
                  icon: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Icon(
                        Icons.terminal_rounded,
                        color: _isCodingMode
                            ? const Color(0xFFEA580C)
                            : const Color(0xFF2DD4BF),
                      ),
                      if (_isCodingMode)
                        Positioned(
                          right: -2,
                          top: -2,
                          child: Container(
                            width: 7,
                            height: 7,
                            decoration: const BoxDecoration(
                              color: Color(0xFFEA580C),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                    ],
                  ),
                  onPressed: () => _toggleCodingAgentMode(ctx),
                ),

              // 2. Load Saved Workflow
              IconButton(
                tooltip: l.loadSavedWorkflow,
                icon: const Icon(Icons.folder_open_outlined),
                onPressed: () => _showLoadWorkflowDialog(ctx, controller),
              ),

              // 3. Save as Workflow
              IconButton(
                tooltip: l.saveCurrentAsWorkflow,
                icon: const Icon(Icons.bookmark_add_outlined),
                onPressed: () => _showSaveWorkflowDialog(ctx, controller),
              ),

              // 4. Skills Manager
              IconButton(
                tooltip: l.skillsManager,
                icon: const Icon(Icons.bolt_outlined),
                onPressed: () => _openSkillsPicker(ctx, controller),
              ),

              // 5. Default Playground actions (Clear, Settings, Inspector toggle)
              ...actions.defaultActionWidgets,
            ],
          );
        },
      ),
    );
  }
}
