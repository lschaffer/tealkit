import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_ui_mcp/flutter_ui_mcp.dart' hide Agent;
import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';

import '../config/app_theme.dart';
import '../config/build_flavor.dart';
import '../l10n/app_localizations.dart';
import '../mcp/internal_mcp_registry.dart';
import '../models/workflow_task.dart' hide ChatRole;
import '../providers/database_providers.dart';
import '../providers/server_mode_provider.dart';
import '../providers/sidebar_provider.dart';
import '../services/data_sources_settings_service.dart';
import '../services/external_tools_settings_service.dart';
import '../services/github_mcp_library_service.dart';
import '../services/llm_settings_service.dart' as tk_llm;
import '../services/skill_def_database_service.dart';
import '../services/tealkit_database_storage_delegate.dart';
import '../services/tealkit_tools_builder.dart';
import '../widgets/tealkit_assistant_settings_dialog.dart';
import 'skills_list_screen.dart';
import 'package:path/path.dart' as p;
import '../services/session_service.dart';

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

enum _AssistantMode { coding, agent, chat }

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
    'fetch',
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
  String? _serverCodingRootDir;
  late List<McpLocalTool> _localTools;

  bool get _isDesktopPlatform =>
      !kIsWeb &&
      (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  bool get _isRemoteMobileCoding =>
      !_isDesktopPlatform &&
      (ref.read(serverModeProvider).value?.isRemote ?? false);

  bool _isCodingMode = false;
  String _codingSubMode = '/code';
  String? _previousSystemPrompt;
  Set<String>? _previousEnabledTools;
  bool _hasSessionLlmOverride = false;
  bool _pendingInitialTaskApply = false;

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
      _pendingInitialTaskApply = true;
      unawaited(_applyInitialTaskWhenReady(widget.task!));
    }

    // Sync any external changes from TealKit's settings
    tk_llm.LlmSettingsService.instance.addListener(_onTealKitLlmSettingsChanged);
    _controller.addListener(_onControllerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncRemoteCodingWorkspaceIfNeeded();
      _checkPromptContinueLastSession();
    });
  }

  Future<void> _applyInitialTaskWhenReady(WorkflowTask task) async {
    while (_controller.isLoading && !_isDisposed && mounted) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    if (_isDisposed || !mounted || !_pendingInitialTaskApply) return;
    _pendingInitialTaskApply = false;
    await _applyWorkflowTask(task, _controller);
  }

  bool _isDisposed = false;

  @override
  void dispose() {
    _isDisposed = true;
    tk_llm.LlmSettingsService.instance.removeListener(_onTealKitLlmSettingsChanged);
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    super.dispose();
  }

  void _syncDefaultLlmFromSettings() {
    if (_isDisposed || !mounted) return;
    final cfg = _storageDelegate.getTealKitLlmConfig();
    if (cfg == null) return;

    _controller.customLlmConfig = null;
    final active = _controller.activeLlmConfig;
    final isSame = active.id == cfg.id &&
        active.provider == cfg.provider &&
        active.model == cfg.model &&
        active.apiKey == cfg.apiKey &&
        active.baseUrl == cfg.baseUrl &&
        (active.temperature - cfg.temperature).abs() < 0.001 &&
        active.maxTokens == cfg.maxTokens;
    if (isSame && _controller.customLlmConfig == null) return;

    _controller.customLlmConfig = null;
    _controller.updateLlmConfig(cfg);
  }

  void _onTealKitLlmSettingsChanged() {
    if (_isDisposed || !mounted) return;
    // Do not clobber a temporal LLM override chosen for this Assistant session.
    if (_hasSessionLlmOverride) return;
    _syncDefaultLlmFromSettings();
  }

  void _refreshTools() {
    final serverClient = _isRemoteMobileCoding
        ? ref.read(serverApiClientProvider)
        : null;
    _localTools = TealKitToolsBuilder.buildAllTools(
      workspaceDirectory: _workspaceDirectory,
      serverClient: serverClient,
    );
    try {
      _controller.updateLocalTools(_localTools);
    } catch (_) {}
  }

  Future<void> _syncRemoteCodingWorkspaceIfNeeded() async {
    if (_isDisposed || !mounted || _isDesktopPlatform) return;
    final isRemote = ref.read(serverModeProvider).value?.isRemote ?? false;
    final serverClient = ref.read(serverApiClientProvider);
    if (!isRemote || serverClient == null) {
      if (_isCodingMode) {
        _exitCodingMode(context, showSnackbar: false);
      }
      _serverCodingRootDir = null;
      _refreshTools();
      return;
    }

    try {
      final info = await serverClient.getServerCodingWorkspace();
      final rootDir = (info['root_dir'] as String? ?? '').trim();
      if (rootDir.isNotEmpty && mounted) {
        setState(() {
          _serverCodingRootDir = rootDir;
          if (_workspaceDirectory.isEmpty ||
              _workspaceDirectory == Directory.current.path ||
              !_workspaceDirectory.startsWith(rootDir)) {
            _workspaceDirectory = rootDir;
          }
          _controller.workspaceDirectory = _workspaceDirectory;
          _refreshTools();
        });
        if (_isCodingMode) {
          _applyCodingSubMode(_codingSubMode);
        }
      }
    } catch (_) {
      // Server may not be reachable yet; will retry when entering Coding Mode.
    }
  }

  Future<void> _pickRemoteServerWorkspaceFolder() async {
    final serverClient = ref.read(serverApiClientProvider);
    if (serverClient == null) return;

    var currentDir = _workspaceDirectory.isNotEmpty
        ? _workspaceDirectory
        : (_serverCodingRootDir ?? '');
    String rootDir = _serverCodingRootDir ?? '';
    String? parentDir;
    List<Map<String, String>> subdirs = [];
    String? loadError;
    bool loading = true;

    Future<void> loadFolder(String? target, StateSetter setDialogState) async {
      setDialogState(() {
        loading = true;
        loadError = null;
      });
      try {
        final data = await serverClient.getServerCodingWorkspace(path: target);
        rootDir = (data['root_dir'] as String? ?? '').trim();
        currentDir = (data['current_dir'] as String? ?? rootDir).trim();
        parentDir = (data['parent_dir'] as String?)?.trim();
        final rawList = data['subdirectories'] as List? ?? const [];
        subdirs = rawList
            .whereType<Map>()
            .map(
              (m) => {
                'name': (m['name'] ?? '').toString(),
                'path': (m['path'] ?? '').toString(),
              },
            )
            .where((m) => m['path']!.isNotEmpty)
            .toList();
      } catch (e) {
        loadError = e.toString();
      } finally {
        setDialogState(() => loading = false);
      }
    }

    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) {
        bool initialized = false;
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            if (!initialized) {
              initialized = true;
              unawaited(loadFolder(currentDir.isNotEmpty ? currentDir : null, setDialogState));
            }
            return AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.folder_open, color: Color(0xFFEA580C), size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Select Server Workspace',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 360,
                height: 360,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      currentDir.isNotEmpty ? currentDir : 'Loading server root...',
                      style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 8),
                    if (parentDir != null && parentDir!.isNotEmpty)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.arrow_upward, size: 18),
                        title: const Text('.. (Parent folder)'),
                        onTap: loading ? null : () => loadFolder(parentDir, setDialogState),
                      ),
                    const Divider(height: 1),
                    Expanded(
                      child: loading
                          ? const Center(child: CircularProgressIndicator())
                          : loadError != null
                              ? Center(
                                  child: Text(
                                    loadError!,
                                    style: TextStyle(color: AppTheme.error, fontSize: 12),
                                  ),
                                )
                              : subdirs.isEmpty
                                  ? const Center(
                                      child: Text(
                                        'No subfolders here.\nYou can use this folder as workspace.',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                                      ),
                                    )
                                  : ListView.builder(
                                      itemCount: subdirs.length,
                                      itemBuilder: (_, i) {
                                        final entry = subdirs[i];
                                        return ListTile(
                                          dense: true,
                                          leading: const Icon(
                                            Icons.folder_outlined,
                                            color: Color(0xFFFB923C),
                                            size: 18,
                                          ),
                                          title: Text(entry['name']!),
                                          onTap: () => loadFolder(entry['path'], setDialogState),
                                        );
                                      },
                                    ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton.icon(
                  onPressed: currentDir.isEmpty
                      ? null
                      : () => Navigator.of(ctx).pop(currentDir),
                  icon: const Icon(Icons.check, size: 16),
                  label: const Text('Use this folder'),
                ),
              ],
            );
          },
        );
      },
    );

    if (selected != null && selected.isNotEmpty && mounted) {
      setState(() {
        if (rootDir.isNotEmpty) _serverCodingRootDir = rootDir;
        _workspaceDirectory = selected;
        _controller.workspaceDirectory = selected;
        _refreshTools();
      });
      _applyCodingSubMode(_codingSubMode);
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Coding Agent Mode Toggle & Sub-Modes
  // ─────────────────────────────────────────────────────────────

  void _onControllerChanged() {
    if (_isDisposed || !mounted) return;
    if (!_controller.isLoading && !_hasSessionLlmOverride) {
      final active = _controller.activeLlmConfig;
      final defaultProfileId = tk_llm.LlmSettingsService.instance.selectedProfile?.id;
      if (_controller.customLlmConfig != null ||
          active.id == '__session_custom__' ||
          (active.id != null &&
              active.id!.isNotEmpty &&
              defaultProfileId != null &&
              active.id != defaultProfileId)) {
        _hasSessionLlmOverride = true;
      }
    }
    if (_controller.messages.isNotEmpty && !_controller.isGenerating) {
      if (SessionService.instance.autoSaveEnabled) {
        SessionService.instance.autoSaveSession(
          messages: _controller.messages,
          mode: _isCodingMode ? 'code' : (_controller.chatMode ? 'chat' : 'agent'),
          llmModel: _controller.activeLlmConfig.model,
          workspaceDirectory: _isCodingMode ? _workspaceDirectory : null,
        );
      }
    }
  }

  Future<void> _saveSessionDialog() async {
    final sessionService = SessionService.instance;
    await sessionService.init();
    final messages = _controller.messages;
    if (messages.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No messages to save in current session.')),
        );
      }
      return;
    }
    final activeConfig = _controller.activeLlmConfig;
    final activeMode = _isCodingMode
        ? 'code'
        : (_controller.chatMode ? 'chat' : 'agent');
    final sessionData = SessionData(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: _isCodingMode
          ? p.basename(_workspaceDirectory.isNotEmpty ? _workspaceDirectory : 'TealKit Coder')
          : 'TealKit Assistant Session',
      mode: activeMode,
      createdAt: messages.first.timestamp,
      updatedAt: DateTime.now(),
      llmName: activeConfig.model.isNotEmpty ? activeConfig.model : activeConfig.provider.displayName,
      llmProvider: activeConfig.provider.name,
      llmModel: activeConfig.model,
      messages: List.from(messages),
    );

    final defaultDir = sessionService.resolveSessionsDirectory(
      workspaceDirectory: _isCodingMode ? _workspaceDirectory : null,
    );
    final defaultFileName = sessionService.generateFilename();
    final jsonBytes = Uint8List.fromList(
      utf8.encode(const JsonEncoder.withIndent('  ').convert(sessionData.toJson())),
    );

    try {
      final isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
      if (isMobile) {
        // On Android/iOS, FilePicker.saveFile opens the native SAF / Files
        // Save dialog (ACTION_CREATE_DOCUMENT on Android) where the user can
        // pick any folder (including Downloads/Documents) and edit the filename,
        // and writes `bytes` directly without needing MANAGE_EXTERNAL_STORAGE.
        final savedUri = await FilePicker.saveFile(
          dialogTitle: 'Save Session (.json)',
          fileName: defaultFileName,
          bytes: jsonBytes,
        );
        if (savedUri == null) return; // user cancelled
        if (mounted) {
          final displayTarget = savedUri.scheme == 'file'
              ? savedUri.toFilePath()
              : (savedUri.pathSegments.isNotEmpty
                    ? savedUri.pathSegments.last
                    : defaultFileName);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Session saved: $displayTarget'),
              backgroundColor: AppTheme.success,
            ),
          );
        }
      } else {
        final savedUri = await FilePicker.saveFile(
          dialogTitle: 'Save Session (.json)',
          fileName: defaultFileName,
          initialDirectory: Directory(defaultDir).existsSync() ? defaultDir : null,
          bytes: jsonBytes,
        );
        if (savedUri == null) return; // user cancelled
        final targetPath = savedUri.scheme == 'file'
            ? savedUri.toFilePath()
            : savedUri.toString();
        final savedFile = await sessionService.saveSession(sessionData, targetPath);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Session saved to ${savedFile.path}'),
              backgroundColor: AppTheme.success,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save session: $e'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  Future<void> _loadSessionDialog() async {
    final useCustom = !kIsWeb &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Select Saved Session (.json, .md)',
      type: useCustom ? FileType.custom : FileType.any,
      allowedExtensions: useCustom ? ['json', 'md'] : null,
    );
    if (result.isEmpty) return;
    final filePath = result.first.path;
    if (filePath == null) return;

    try {
      final session = await SessionService.instance.loadSession(filePath);
      _controller.loadMessages(session.messages, clearExisting: true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Restored session (${session.messages.length} messages loaded)'),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load session: $e'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  Future<void> _continueLastSession() async {
    final sessionService = SessionService.instance;
    await sessionService.init();
    final lastFile = sessionService.findLastSessionFile(
      workspaceDirectory: _isCodingMode ? _workspaceDirectory : null,
    );
    if (lastFile == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No previous session found to continue.')),
        );
      }
      return;
    }

    try {
      final session = await sessionService.loadSession(lastFile.path);
      _controller.loadMessages(session.messages, clearExisting: true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Continued session from ${p.basename(lastFile.path)} (${session.messages.length} messages)'),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to continue session: $e'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  Future<void> _checkPromptContinueLastSession() async {
    if (kIsWeb) return;

    final sessionService = SessionService.instance;
    await sessionService.init();
    if (!sessionService.promptContinueLastSession) return;
    if (_controller.messages.isNotEmpty) return;

    final lastFile = sessionService.findLastSessionFile(
      workspaceDirectory: _isCodingMode ? _workspaceDirectory : null,
    );
    if (lastFile == null || !mounted) return;

    final lastModified = lastFile.lastModifiedSync();
    final timeStr = '${lastModified.year}-${lastModified.month.toString().padLeft(2, '0')}-${lastModified.day.toString().padLeft(2, '0')} ${lastModified.hour.toString().padLeft(2, '0')}:${lastModified.minute.toString().padLeft(2, '0')}';

    final l = L.of(context);
    final shouldContinue = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.history_rounded, color: Color(0xFFFB923C)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l.continueLastSessionTitle,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.previousSessionFound),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p.basename(lastFile.path),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l.lastUpdatedAt(timeStr),
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.startNewSession),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.play_arrow_rounded, size: 16),
            label: Text(l.continueSession),
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );

    if (shouldContinue == true && mounted) {
      await _continueLastSession();
    }
  }

  _AssistantMode get _currentAssistantMode {
    if (_isCodingMode) return _AssistantMode.coding;
    return _controller.chatMode ? _AssistantMode.chat : _AssistantMode.agent;
  }

  void _exitCodingMode(BuildContext context, {bool showSnackbar = true}) {
    if (!_isCodingMode) return;
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
    _controller.toggleToolEnabled('fetch', false);
    _controller.toggleToolEnabled('fetch_web', false);
    setState(() {
      _isCodingMode = false;
    });
    if (showSnackbar && mounted) {
      final l = L.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('💻 ${l.codingAgentModeDisabled}'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _enterCodingMode(BuildContext context, {bool showSnackbar = true}) {
    if (_isCodingMode) return;
    _previousSystemPrompt = _controller.systemPrompt;
    _previousEnabledTools = Set<String>.from(_controller.enabledToolNames);

    if (_isRemoteMobileCoding) {
      _refreshTools();
      if (_serverCodingRootDir == null) {
        unawaited(_syncRemoteCodingWorkspaceIfNeeded());
      }
    }

    _controller.chatMode = false;
    for (final t in _kCodingToolNames) {
      _controller.toggleToolEnabled(t, true);
    }
    _applyCodingSubMode(_codingSubMode);

    setState(() {
      _isCodingMode = true;
    });
    if (showSnackbar && mounted) {
      final l = L.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('💻 ${l.codingAgentModeActivated}'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _selectAssistantMode(BuildContext context, _AssistantMode mode) {
    if (mode == _currentAssistantMode) return;
    switch (mode) {
      case _AssistantMode.coding:
        _enterCodingMode(context);
        break;
      case _AssistantMode.agent:
        _exitCodingMode(context, showSnackbar: false);
        setState(() {
          _controller.chatMode = false;
        });
        break;
      case _AssistantMode.chat:
        _exitCodingMode(context, showSnackbar: false);
        setState(() {
          _controller.chatMode = true;
        });
        break;
    }
  }

  void _applyCodingSubMode(String mode) {
    _controller.codingSubMode = mode;
    _controller.workspaceDirectory = _workspaceDirectory;

    final isWin = Platform.isWindows;
    final osNotice = _isRemoteMobileCoding
        ? 'REMOTE SERVER WORKSPACE: File operations (fs_*) and terminal_exec execute on the connected TealKit Server inside "$_workspaceDirectory" (under the server root directory).'
        : isWin
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
              isCodingMode: _isCodingMode,
              onSessionLlmChanged: (isOverride) {
                _hasSessionLlmOverride = isOverride;
              },
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
                isCodingMode: _isCodingMode,
                onSessionLlmChanged: (isOverride) {
                  _hasSessionLlmOverride = isOverride;
                },
                onClose: () => Navigator.of(ctx).pop(),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildAssistantModeDropdown(
    BuildContext context,
    PlaygroundController controller, {
    required bool canUseCodingMode,
    required bool isCompact,
  }) {
    final mode = _currentAssistantMode;
    final toolCount = controller.enabledToolNames.length;

    final ({
      String label,
      IconData icon,
      Color accent,
      Color textColor,
      Gradient? gradient,
      Color? bgColor,
      Color borderColor,
      double borderWidth,
      List<BoxShadow>? shadows,
    }) style = switch (mode) {
      _AssistantMode.coding => (
        label: isCompact ? 'Coding' : 'Coding $_codingSubMode',
        icon: Icons.terminal_rounded,
        accent: const Color(0xFFFB923C),
        textColor: const Color(0xFFFFEDD5),
        gradient: LinearGradient(
          colors: [
            const Color(0xFFEA580C).withValues(alpha: 0.34),
            const Color(0xFFF59E0B).withValues(alpha: 0.18),
          ],
        ),
        bgColor: null,
        borderColor: const Color(0xFFFB923C),
        borderWidth: 1.5,
        shadows: [
          BoxShadow(
            color: const Color(0xFFEA580C).withValues(alpha: 0.28),
            blurRadius: 8,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      _AssistantMode.agent => (
        label: isCompact ? 'Agent ($toolCount)' : 'Agent ($toolCount Tools)',
        icon: Icons.smart_toy_outlined,
        accent: const Color(0xFF38BDF8),
        textColor: const Color(0xFFBAE6FD),
        gradient: null,
        bgColor: const Color(0xFF0EA5E9).withValues(alpha: 0.16),
        borderColor: const Color(0xFF38BDF8).withValues(alpha: 0.55),
        borderWidth: 1.1,
        shadows: null,
      ),
      _AssistantMode.chat => (
        label: 'Chat',
        icon: Icons.chat_bubble_outline_rounded,
        accent: const Color(0xFFA5B4FC),
        textColor: const Color(0xFFE0E7FF),
        gradient: null,
        bgColor: const Color(0xFF6366F1).withValues(alpha: 0.14),
        borderColor: const Color(0xFF818CF8).withValues(alpha: 0.45),
        borderWidth: 1.0,
        shadows: null,
      ),
    };

    PopupMenuItem<_AssistantMode> buildMenuItem({
      required _AssistantMode value,
      required IconData icon,
      required Color color,
      required String title,
      required String subtitle,
    }) {
      final selected = mode == value;
      return PopupMenuItem<_AssistantMode>(
        value: value,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
          decoration: selected
              ? BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                )
              : null,
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: color.withValues(alpha: selected ? 0.8 : 0.35),
                  ),
                ),
                child: Icon(icon, size: 16, color: color),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: selected ? color : Colors.white,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF94A3B8),
                      ),
                    ),
                  ],
                ),
              ),
              if (selected) Icon(Icons.check_rounded, size: 16, color: color),
            ],
          ),
        ),
      );
    }

    return PopupMenuButton<_AssistantMode>(
      tooltip: 'Switch Assistant Mode',
      onSelected: (selected) => _selectAssistantMode(context, selected),
      position: PopupMenuPosition.under,
      itemBuilder: (ctx) => [
        if (canUseCodingMode)
          buildMenuItem(
            value: _AssistantMode.coding,
            icon: Icons.terminal_rounded,
            color: const Color(0xFFFB923C),
            title: 'Coding Mode',
            subtitle: _isRemoteMobileCoding
                ? 'Server workspace files, terminal & /code /plan /ask /rag'
                : 'Workspace files, terminal & /code /plan /ask /rag',
          ),
        buildMenuItem(
          value: _AssistantMode.agent,
          icon: Icons.smart_toy_outlined,
          color: const Color(0xFF38BDF8),
          title: 'Agent Mode',
          subtitle: 'Autonomous tool execution ($toolCount tools)',
        ),
        buildMenuItem(
          value: _AssistantMode.chat,
          icon: Icons.chat_bubble_outline_rounded,
          color: const Color(0xFFA5B4FC),
          title: 'Chat Mode',
          subtitle: 'Direct LLM conversation without tools',
        ),
      ],
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: isCompact ? 8 : 11,
          vertical: isCompact ? 4 : 5,
        ),
        decoration: BoxDecoration(
          gradient: style.gradient,
          color: style.bgColor,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: style.borderColor, width: style.borderWidth),
          boxShadow: style.shadows,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(style.icon, size: 14, color: style.accent),
            const SizedBox(width: 5),
            Text(
              style.label,
              style: TextStyle(
                fontSize: isCompact ? 11.5 : 12.5,
                fontWeight: mode == _AssistantMode.coding
                    ? FontWeight.w700
                    : FontWeight.w600,
                color: style.textColor,
              ),
            ),
            const SizedBox(width: 2),
            Icon(Icons.arrow_drop_down_rounded, size: 16, color: style.accent),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickModelSelector(
    BuildContext context,
    PlaygroundController controller, {
    double maxWidth = 150,
  }) {
    final activeConfig = controller.activeLlmConfig;
    final modelName = activeConfig.model.isNotEmpty
        ? activeConfig.model
        : (activeConfig.isConfigured ? activeConfig.provider.displayName : 'Select Model');

    final profiles = tk_llm.LlmSettingsService.instance.profiles
        .where(
          (p) =>
              BuildFlavor.supportsEmbeddedLlm ||
              p.provider != tk_llm.LlmProvider.embedded,
        )
        .toList();

    return PopupMenuButton<String>(
      tooltip: 'Quick Model Selector',
      position: PopupMenuPosition.over,
      onSelected: (value) {
        if (value == '__settings__') {
          _openAssistantSettingsDialog(context, controller, initialTab: 1);
          return;
        }
        final profile = tk_llm.LlmSettingsService.instance.getProfile(value);
        if (profile == null) return;
        final cfg = TealKitAssistantSettingsDialog.profileToLlmConfig(profile);
        controller.customLlmConfig = null;
        controller.updateLlmConfig(cfg);
        if (controller.llmConfigs.any(
          (c) => c.id == profile.id || c.profileId == profile.id,
        )) {
          controller.selectLlm(profile.id);
        }
        final defaultId = tk_llm.LlmSettingsService.instance.selectedProfileId;
        _hasSessionLlmOverride = profile.id != defaultId;
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Switched model to "${profile.name}" (${profile.model})'),
            duration: const Duration(seconds: 2),
          ),
        );
      },
      itemBuilder: (ctx) => [
        for (final p in profiles)
          PopupMenuItem<String>(
            value: p.id,
            child: Row(
              children: [
                Icon(
                  (activeConfig.id == p.id ||
                          (activeConfig.model == p.model &&
                              activeConfig.provider.name == p.provider.configKey))
                      ? Icons.check_circle_rounded
                      : Icons.smart_toy_outlined,
                  size: 16,
                  color: (activeConfig.id == p.id ||
                          (activeConfig.model == p.model &&
                              activeConfig.provider.name == p.provider.configKey))
                      ? const Color(0xFF38BDF8)
                      : const Color(0xFF94A3B8),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        p.name,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${p.provider.label} • ${p.model}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF94A3B8),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        if (profiles.isNotEmpty) const PopupMenuDivider(),
        const PopupMenuItem<String>(
          value: '__settings__',
          child: Row(
            children: [
              Icon(Icons.tune_rounded, size: 16, color: Color(0xFF2DD4BF)),
              SizedBox(width: 10),
              Text('Model & Provider Settings...'),
            ],
          ),
        ),
      ],
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
              constraints: BoxConstraints(maxWidth: maxWidth),
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
    );
  }

  List<Widget> _buildSessionActionButtons() => [
    IconButton(
      tooltip: 'Save Session (.json)',
      icon: const Icon(Icons.save_outlined, size: 17, color: Color(0xFF94A3B8)),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      onPressed: _saveSessionDialog,
    ),
    IconButton(
      tooltip: 'Load Session (.json, .md)',
      icon: const Icon(Icons.file_open_outlined, size: 17, color: Color(0xFF94A3B8)),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      onPressed: _loadSessionDialog,
    ),
    IconButton(
      tooltip: 'Continue Last Session',
      icon: const Icon(Icons.history_rounded, size: 17, color: Color(0xFFFB923C)),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      onPressed: _continueLastSession,
    ),
  ];

  Widget _buildEmptyChatWelcome(BuildContext context) {
    final l = L.of(context);
    final theme = Theme.of(context);
    final hasLlm = _controller.activeLlmConfig.isConfigured;
    final chatMode = _controller.chatMode;

    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(0, -0.25),
          radius: 1.0,
          colors: [
            (_isCodingMode
                    ? const Color(0xFFEA580C)
                    : AppTheme.primaryBlue)
                .withValues(alpha: 0.12),
            AppTheme.backgroundDark,
          ],
        ),
      ),
      child: Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 32.0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: (hasLlm
                              ? (_isCodingMode
                                  ? const Color(0xFFEA580C)
                                  : theme.colorScheme.primary)
                              : Colors.orange)
                          .withValues(alpha: 0.14),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      hasLlm
                          ? (_isCodingMode
                              ? Icons.terminal_rounded
                              : (chatMode
                                  ? Icons.chat_bubble_outline
                                  : Icons.smart_toy_outlined))
                          : Icons.tune_outlined,
                      size: 56,
                      color: hasLlm
                          ? (_isCodingMode
                              ? const Color(0xFFFB923C)
                              : theme.colorScheme.primary)
                          : Colors.orange,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    hasLlm ? l.assistantWelcomeTitle : l.assistantWelcomeSetupTitle,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    hasLlm
                        ? l.assistantWelcomeSubtitle
                        : l.assistantWelcomeSetupSubtitle,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (!hasLlm) ...[
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      icon: const Icon(Icons.settings),
                      label: Text(l.configureModelAndProvider),
                      onPressed: () => _openAssistantSettingsDialog(
                        context,
                        _controller,
                        initialTab: 1,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomUtilityBar(
    BuildContext context,
    PlaygroundController controller, {
    required bool canUseCodingMode,
  }) {
    if (canUseCodingMode && _isCodingMode) {
      return _buildCodingModeBar(context, controller);
    }

    final width = MediaQuery.sizeOf(context).width;
    final modelMaxWidth = width < 420 ? 155.0 : 220.0;

    return Container(
      width: double.infinity,
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
      child: Row(
        children: [
          Flexible(
            child: _buildQuickModelSelector(
              context,
              controller,
              maxWidth: modelMaxWidth,
            ),
          ),
          const SizedBox(width: 8),
          ..._buildSessionActionButtons(),
        ],
      ),
    );
  }

  Widget _buildCodingModeBar(BuildContext context, PlaygroundController controller) {
    final wsParts = _workspaceDirectory
        .split(Platform.pathSeparator)
        .where((s) => s.isNotEmpty)
        .toList();
    final wsName = wsParts.isNotEmpty ? wsParts.last : 'workspace';

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
                if (_isRemoteMobileCoding) {
                  await _pickRemoteServerWorkspaceFolder();
                  return;
                }
                final selected = await FilePicker.getDirectoryPath();
                if (selected != null && mounted) {
                  if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
                    try {
                      final dir = Directory(selected);
                      if (dir.existsSync()) {
                        Directory.current = dir;
                      }
                    } catch (_) {}
                  }
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

            // Active model quick selector pill: 🤖 <model> ▾
            _buildQuickModelSelector(context, controller, maxWidth: 130),

            const SizedBox(width: 10),

            // Session actions: Save, Load, Continue
            ..._buildSessionActionButtons(),
            const SizedBox(width: 4),

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
              onPressed: () => _exitCodingMode(context),
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
                  final firstAgent = task.agents.firstOrNull;
                  final effectivePrompt = task.prompt.isNotEmpty
                      ? task.prompt
                      : (firstAgent?.prompt ?? '');
                  final effectiveSysPrompt = task.systemPrompt?.isNotEmpty == true
                      ? task.systemPrompt!
                      : (firstAgent?.systemPrompt ?? '');
                  final promptText = effectivePrompt.isNotEmpty
                      ? '${l.initialPrompt}: $effectivePrompt'
                      : effectiveSysPrompt;
                  final effectiveInternalMcps =
                      firstAgent != null && firstAgent.internalMcps.isNotEmpty
                          ? firstAgent.internalMcps
                          : task.internalMcps;
                  final effectiveMcpTools =
                      firstAgent != null && firstAgent.mcpTools.isNotEmpty
                          ? firstAgent.mcpTools
                          : task.mcpTools;
                  final hasToolboxEnabled = !effectiveInternalMcps.any(
                    (m) => m.mcpType == 'toolbox' && !m.enabled,
                  );
                  final toolCount = effectiveInternalMcps
                          .where((m) => m.enabled && m.mcpType != 'toolbox')
                          .length +
                      effectiveMcpTools.length +
                      (hasToolboxEnabled ? 1 : 0);
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
    final firstAgent = task.agents.firstOrNull;

    // 1. System Prompt & Execution Flags
    final sysPrompt = (firstAgent?.systemPrompt?.isNotEmpty == true)
        ? firstAgent!.systemPrompt!
        : (task.systemPrompt ?? '');
    controller.systemPrompt = sysPrompt;
    controller.chatMode = firstAgent?.chatMode ?? task.chatMode;
    controller.stopAfterToolCall =
        firstAgent?.stopAfterToolCall ?? task.stopAfterToolCall;

    // 2. Chat Prompt
    final promptText = (firstAgent?.prompt.isNotEmpty == true)
        ? firstAgent!.prompt
        : task.prompt;
    if (promptText.isNotEmpty) {
      controller.setInputPrompt(promptText);
    }

    // 3. LLM Configuration (session-only override, never mutates LlmSettingsService)
    final llm = firstAgent?.llmConfig ?? task.llmConfig;
    if (llm != null && llm.provider.isNotEmpty && llm.provider != 'none') {
      _hasSessionLlmOverride = true;
      final llmService = tk_llm.LlmSettingsService.instance;
      final pid = llm.extraParams['profile_id'] as String?;
      final matchedProfile = (pid != null
              ? llmService.getProfile(pid)
              : null) ??
          llmService.profiles
              .where(
                (p) =>
                    p.provider.configKey == llm.provider &&
                    p.model == llm.model,
              )
              .firstOrNull;

      if (matchedProfile != null) {
        final cfg = TealKitDatabaseStorageDelegate.fromNamedProfile(
          matchedProfile,
        );
        controller.customLlmConfig = null;
        await controller.updateLlmConfig(cfg);
      } else {
        final tkProv = tk_llm.LlmProvider.fromConfigKey(llm.provider);
        final pgProv = TealKitDatabaseStorageDelegate.fromTealKitProvider(
          tkProv,
        );
        final label = llm.model.isNotEmpty ? llm.model : tkProv.label;
        final cfg = LlmConfig(
          id: '__session_custom__',
          name: 'Session ($label)',
          provider: pgProv,
          model: llm.model,
          apiKey: llm.apiKey ?? '',
          baseUrl: llm.baseUrl ?? '',
          temperature: llm.temperature,
          maxTokens: llm.maxTokens,
          isSlm: (llm.extraParams['is_slm'] as bool?) ?? false,
          isMultiModal: (llm.extraParams['is_multi_modal'] as bool?) ?? true,
          thinking: (llm.extraParams['thinking'] as bool?) ?? false,
          useNativeToolCall:
              (llm.extraParams['use_native_tool_call'] as bool?) ?? true,
          useSafeToolCall:
              (llm.extraParams['use_safe_tool_call'] as bool?) ?? false,
          maxToolOutputSize:
              (llm.extraParams['max_tool_output_size'] as num?)?.toInt() ??
                  2560000,
          tokenWarningThreshold:
              (llm.extraParams['token_warning_threshold'] as num?)?.toInt() ??
                  1500000,
          topK: (llm.extraParams['top_k'] as num?)?.toInt(),
          topP: (llm.extraParams['top_p'] as num?)?.toDouble(),
          repeatPenalty:
              (llm.extraParams['repeat_penalty'] as num?)?.toDouble(),
          seed: (llm.extraParams['seed'] as num?)?.toInt(),
        );
        controller.customLlmConfig = cfg;
        await controller.updateLlmConfig(cfg);
      }
    }

    // 4. Internal & External MCP Tools
    final effectiveInternalMcps =
        (firstAgent != null &&
                (firstAgent.internalMcps.isNotEmpty ||
                    task.internalMcps.isEmpty))
            ? firstAgent.internalMcps
            : task.internalMcps;
    final effectiveMcpTools =
        (firstAgent != null &&
                (firstAgent.mcpTools.isNotEmpty || task.mcpTools.isEmpty))
            ? firstAgent.mcpTools
            : task.mcpTools;

    final registry = InternalMcpRegistry();
    registry.registerGithubMcpServers();
    final availableByType = {
      for (final s in registry.availableServers) s.type: s,
    };

    final nextEnabledTools = <String>{};
    final hasKnownServerType = effectiveInternalMcps.any(
      (m) =>
          m.mcpType == 'toolbox' ||
          m.mcpType.startsWith('gh_mcp_') ||
          availableByType.containsKey(m.mcpType),
    );
    final toolboxExplicitlyDisabled = effectiveInternalMcps.any(
      (m) => m.mcpType == 'toolbox' && !m.enabled,
    );
    if (!toolboxExplicitlyDisabled &&
        (hasKnownServerType ||
            (effectiveInternalMcps.isEmpty && effectiveMcpTools.isNotEmpty))) {
      final tb = availableByType['toolbox'];
      if (tb != null) {
        nextEnabledTools.addAll(tb.toolNames);
      }
    }

    for (final mcp in effectiveInternalMcps) {
      if (!mcp.enabled || mcp.mcpType == 'toolbox') continue;
      if (mcp.mcpType.startsWith('gh_mcp_')) {
        nextEnabledTools.add(mcp.mcpType);
        final serverInfo = availableByType[mcp.mcpType];
        if (serverInfo != null) {
          final subset = (mcp.initParams['enabledTools'] as List?)
              ?.map((e) => e.toString())
              .where((s) => s.isNotEmpty)
              .toList();
          nextEnabledTools.addAll(
            subset != null && subset.isNotEmpty ? subset : serverInfo.toolNames,
          );
        }
      } else if (availableByType.containsKey(mcp.mcpType)) {
        final serverInfo = availableByType[mcp.mcpType]!;
        final subset = (mcp.initParams['enabledTools'] as List?)
            ?.map((e) => e.toString())
            .where((s) => s.isNotEmpty)
            .toList();
        nextEnabledTools.addAll(
          subset != null && subset.isNotEmpty ? subset : serverInfo.toolNames,
        );
      } else {
        // Legacy fallback when individual tool names were stored directly
        nextEnabledTools.add(mcp.mcpType);
      }
    }

    controller.updateEnabledTools(nextEnabledTools);

    final wantedUrls = effectiveMcpTools.map((m) => m.serverUrl).toSet();
    for (final srv in List<McpServerConfig>.from(controller.servers)) {
      if (srv.enabled && !wantedUrls.contains(srv.url)) {
        await controller.toggleServer(srv.id, false);
      }
    }
    for (final m in effectiveMcpTools) {
      final existing = controller.servers
          .where((s) => s.url == m.serverUrl)
          .firstOrNull;
      final serverId = existing?.id ?? m.serverUrl;
      if (existing != null) {
        if (!existing.enabled) {
          await controller.toggleServer(existing.id, true);
        }
      } else {
        await controller.addServer(
          McpServerConfig(
            id: serverId,
            name: m.name ?? m.serverUrl,
            url: m.serverUrl,
            mcpEndpoint: m.mcpEndpoint ?? '/mcp',
            apiKey: m.apiKey,
            apiPassword: m.apiPassword,
            enabled: true,
            description: m.description,
            isOnline: m.isOnline,
          ),
        );
      }

      if (m.enabledTools != null && m.enabledTools!.isNotEmpty) {
        final clientDef = controller.mcpClients
            .where((c) => c.name == serverId)
            .firstOrNull;
        final cached = await _storageDelegate.loadCachedServerTools(serverId);
        final knownForServer = <String>{
          ...m.discoveredTools,
          ...cached.map((t) => t.name),
          if (clientDef != null) ...clientDef.availableTools.map((t) => t.name),
        };
        final allowed = m.enabledTools!.toSet();
        for (final toolName in knownForServer) {
          controller.toggleToolEnabled(toolName, allowed.contains(toolName));
        }
      } else if (m.discoveredTools.isNotEmpty) {
        controller.toggleToolsEnabled(m.discoveredTools, true);
      }
    }

    // 5. Resolve & Set Active Skill
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

    String initialPrompt = controller.currentInputPrompt.trim();
    if (initialPrompt.isEmpty) {
      final lastUserMsg = controller.messages
          .where((m) => m.role.name == 'user' && m.content.trim().isNotEmpty)
          .lastOrNull;
      if (lastUserMsg != null) {
        initialPrompt = lastUserMsg.content.trim();
      }
    }

    final isMobile = MediaQuery.sizeOf(context).width < 700;
    final isRemote = ref.read(serverModeProvider).value?.isRemote ?? false;

    final savedResult = await showDialog<({String name, String prompt})>(
      context: context,
      builder: (_) => _SaveWorkflowDialog(
        initialName: l.newTask,
        initialPrompt: initialPrompt,
        isMobile: isMobile,
        isRemote: isRemote,
      ),
    );

    if (savedResult != null && mounted) {
      final name = savedResult.name;
      final savedPrompt = savedResult.prompt;
      if (name.isEmpty || savedPrompt.isEmpty) return;

      final activeTools = Set<String>.from(controller.enabledToolNames);
      final activeSkillId = controller.activeSkill?.id;

      // 1. Convert enabled tools into InternalMcpEntry servers (matching WorkflowEditScreen)
      final registry = InternalMcpRegistry();
      registry.registerGithubMcpServers();
      final availableServers = registry.availableServers;
      final ds = DataSourcesSettingsService.instance;
      final internalMcps = <InternalMcpEntry>[];

      final toolboxServer = availableServers
          .where((s) => s.type == 'toolbox')
          .firstOrNull;
      final isToolboxActive = activeTools.contains('toolbox') ||
          (toolboxServer != null &&
              toolboxServer.toolNames.any(activeTools.contains));
      if (!isToolboxActive) {
        internalMcps.add(
          InternalMcpEntry(
            id: const Uuid().v4(),
            mcpType: 'toolbox',
            label: 'Toolbox',
            enabled: false,
            initParams: const {},
          ),
        );
      }

      for (final server in availableServers) {
        if (server.type == 'toolbox' || server.type.startsWith('gh_mcp_')) {
          continue;
        }
        final bool isGroupActive;
        if (server.type == 'coding_tools') {
          isGroupActive = _isCodingMode ||
              activeTools.contains('coding_tools') ||
              server.toolNames
                  .where((n) => n != 'fetch' && n != 'fetch_web')
                  .any(activeTools.contains);
        } else {
          isGroupActive = activeTools.contains(server.type) ||
              server.toolNames.any(activeTools.contains);
        }
        if (!isGroupActive) continue;

        final initParams = Map<String, dynamic>.from(server.defaultInitParams);
        if (server.type == 'document' &&
            ds.documentRootPaths.trim().isNotEmpty) {
          initParams['rootPath'] = ds.documentRootPaths.trim();
        } else if (server.type == 'website_search') {
          if (ds.websiteIndexUrls.trim().isNotEmpty) {
            initParams['websiteUrls'] = ds.websiteIndexUrls
                .split(RegExp(r'[\r\n,]+'))
                .map((s) => s.trim())
                .where((s) => s.isNotEmpty)
                .toList();
          }
          initParams['maxPages'] = ds.websiteIndexMaxPages;
        } else if (server.type == 'coding_tools' &&
            _workspaceDirectory.trim().isNotEmpty) {
          initParams['workspace'] = _workspaceDirectory.trim();
        }

        final selectedInGroup = server.toolNames
            .where(activeTools.contains)
            .toList();
        if (selectedInGroup.isNotEmpty &&
            selectedInGroup.length < server.toolNames.length) {
          initParams['enabledTools'] = selectedInGroup;
        }

        internalMcps.add(
          InternalMcpEntry(
            id: const Uuid().v4(),
            mcpType: server.type,
            label: server.displayName,
            enabled: true,
            initParams: initParams,
          ),
        );
      }

      // Community / GitHub MCP servers (local & server mode)
      final ghTypes = <String>{
        ...activeTools.where((t) => t.startsWith('gh_mcp_')),
        ...availableServers
            .where(
              (s) =>
                  s.type.startsWith('gh_mcp_') &&
                  s.toolNames.any(activeTools.contains),
            )
            .map((s) => s.type),
      };
      for (final ghType in ghTypes) {
        final serverId = ghType.substring('gh_mcp_'.length);
        final localDef = GithubMcpLibraryService.instance.findById(serverId);
        final regInfo = availableServers
            .where((s) => s.type == ghType)
            .firstOrNull;
        internalMcps.add(
          InternalMcpEntry(
            id: const Uuid().v4(),
            mcpType: ghType,
            label: localDef?.displayName ?? regInfo?.displayName ?? serverId,
            enabled: true,
            initParams: const {},
          ),
        );
      }

      // 2. External HTTP MCP servers (custom + global ExternalToolsSettingsService)
      final globalServers = ExternalToolsSettingsService.instance.selectedServers;
      final mcpTools = <McpToolConfig>[];
      for (final srv in controller.servers) {
        if (!srv.enabled || srv.url.trim().isEmpty) continue;
        final globalMatch = globalServers
            .where((g) => g.serverUrl == srv.url)
            .firstOrNull;
        final clientDef = controller.mcpClients
            .where((c) => c.name == srv.id)
            .firstOrNull;
        final cached = await _storageDelegate.loadCachedServerTools(srv.id);
        final discoveredNames = <String>{
          if (globalMatch != null) ...globalMatch.discoveredTools,
          ...cached.map((t) => t.name),
          if (clientDef != null) ...clientDef.availableTools.map((t) => t.name),
        }.toList();

        final selectedExternalTools = discoveredNames
            .where(activeTools.contains)
            .toList();
        final enabledSubset = (selectedExternalTools.isNotEmpty &&
                selectedExternalTools.length < discoveredNames.length)
            ? selectedExternalTools
            : null;

        mcpTools.add(
          McpToolConfig(
            serverUrl: srv.url,
            name: srv.name.isNotEmpty ? srv.name : globalMatch?.name,
            description: srv.description ?? globalMatch?.description,
            isOnline: srv.isOnline ?? globalMatch?.isOnline,
            mcpEndpoint: srv.mcpEndpoint.isNotEmpty
                ? srv.mcpEndpoint
                : (globalMatch?.mcpEndpoint ?? '/mcp'),
            specificationUrl: globalMatch?.specificationUrl,
            catalogPageUrl: globalMatch?.catalogPageUrl,
            apiKey: srv.apiKey ?? globalMatch?.apiKey,
            apiPassword: srv.apiPassword ?? globalMatch?.apiPassword,
            enabledTools: enabledSubset,
            discoveredTools: discoveredNames,
            discoveredPrompts: globalMatch?.discoveredPrompts ?? const [],
            discoveredResources: globalMatch?.discoveredResources ?? const [],
            discoveredToolSchemas:
                globalMatch?.discoveredToolSchemas ?? const [],
          ),
        );
      }

      // 3. Auto-derived Data Source Providers (matching WorkflowEditScreen._save)
      final hasGoogleTool = internalMcps.any(
        (m) =>
            m.enabled &&
            const {
              'gmail',
              'google_drive',
              'google_calendar',
            }.contains(m.mcpType),
      );
      EmailProviderConfig? emailProvider;
      if (hasGoogleTool && ds.isEmailConfigured) {
        emailProvider = EmailProviderConfig(
          type: 'google',
          authData: EmailAuthData(
            data: {
              'client_id': ds.gmailClientId,
              'client_secret': ds.gmailClientSecret,
              'access_token': ds.gmailAccessToken,
              'refresh_token': ds.gmailRefreshToken,
              if (ds.gmailTokenExpiry != null)
                'expires_at': ds.gmailTokenExpiry!.toIso8601String(),
              if (ds.gmailAccountEmail.isNotEmpty)
                'email': ds.gmailAccountEmail,
            },
          ),
        );
      }
      final hasWebSearch = internalMcps.any(
        (m) => m.enabled && m.mcpType == 'web_search',
      );
      WebSearchConfig? webSearch;
      if (hasWebSearch && ds.isWebSearchConfigured) {
        webSearch = WebSearchConfig(
          type: switch (ds.webSearchProvider) {
            WebSearchProvider.serpapi => 'serpapi',
            WebSearchProvider.serper => 'serper',
            WebSearchProvider.custom => 'custom',
            _ => 'duckduckgo',
          },
          apiKey: ds.webSearchApiKey.isNotEmpty ? ds.webSearchApiKey : null,
          maxResults: ds.webSearchMaxResults,
        );
      }

      // 4. Active Session LLM Configuration
      final activeLlm = controller.activeLlmConfig;
      final tkProv = TealKitDatabaseStorageDelegate.toTealKitProvider(
        activeLlm.provider,
      );
      final llmService = tk_llm.LlmSettingsService.instance;
      tk_llm.NamedLlmProfile? matchedProfile;
      if (activeLlm.id != null &&
          activeLlm.id!.isNotEmpty &&
          activeLlm.id != '__session_custom__') {
        matchedProfile = llmService.getProfile(activeLlm.id!);
      }
      matchedProfile ??= (activeLlm.id == '__session_custom__')
          ? null
          : llmService.profiles
                .where(
                  (p) =>
                      p.provider == tkProv &&
                      p.model == activeLlm.model &&
                      p.baseUrl == activeLlm.baseUrl,
                )
                .firstOrNull;

      TaskLlmConfig? taskLlmConfig;
      if (tkProv != tk_llm.LlmProvider.none &&
          (activeLlm.model.trim().isNotEmpty ||
              tkProv == tk_llm.LlmProvider.embedded)) {
        taskLlmConfig = TaskLlmConfig(
          provider: tkProv.configKey,
          baseUrl: activeLlm.baseUrl.trim().isNotEmpty
              ? activeLlm.baseUrl.trim()
              : null,
          apiKey: activeLlm.apiKey.trim().isNotEmpty
              ? activeLlm.apiKey.trim()
              : null,
          model: activeLlm.model.trim(),
          temperature: activeLlm.temperature,
          maxTokens: activeLlm.maxTokens,
          extraParams: {
            if (matchedProfile != null) 'profile_id': matchedProfile.id,
            'is_slm': activeLlm.isSlm,
            'is_multi_modal': activeLlm.isMultiModal,
            'thinking': activeLlm.thinking,
            'use_native_tool_call': activeLlm.useNativeToolCall,
            'use_safe_tool_call': activeLlm.useSafeToolCall,
            'max_tool_output_size': activeLlm.maxToolOutputSize,
            'token_warning_threshold': activeLlm.tokenWarningThreshold,
            if (activeLlm.topK != null) 'top_k': activeLlm.topK,
            if (activeLlm.topP != null) 'top_p': activeLlm.topP,
            if (activeLlm.repeatPenalty != null)
              'repeat_penalty': activeLlm.repeatPenalty,
            if (activeLlm.seed != null) 'seed': activeLlm.seed,
          },
        );
      }

      final sysPrompt = controller.systemPrompt.trim().isNotEmpty
          ? controller.systemPrompt.trim()
          : null;

      final agent = Agent(
        id: const Uuid().v4(),
        name: name,
        prompt: savedPrompt,
        systemPrompt: sysPrompt,
        llmConfig: taskLlmConfig,
        mcpTools: mcpTools,
        internalMcps: internalMcps,
        chatMode: controller.chatMode,
        stopAfterToolCall: controller.stopAfterToolCall,
        skillDefId: activeSkillId,
      );

      final task = WorkflowTask(
        id: const Uuid().v4(),
        name: name,
        systemPrompt: sysPrompt,
        prompt: savedPrompt,
        llmConfig: taskLlmConfig,
        chatMode: controller.chatMode,
        stopAfterToolCall: controller.stopAfterToolCall,
        agents: [agent],
        mcpTools: mcpTools,
        internalMcps: internalMcps,
        providers: TaskProviders(email: emailProvider, webSearch: webSearch),
        enabled: true,
        executionPlan: const ExecutionPlan(cronExpression: ''),
      );

      try {
        await ref.read(taskListProvider.notifier).saveTask(task);
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
      } catch (e) {
        if (mounted) {
          final l = L.of(context);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l.failedToSave(e.toString())),
              backgroundColor: AppTheme.error,
            ),
          );
        }
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
    final skill = await SkillsListScreen.showPicker(
      context,
      isCodingMode: _isCodingMode,
    );
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
    ref.listen<AsyncValue<ServerModeState>>(serverModeProvider, (prev, next) {
      final prevVal = prev?.value;
      final nextVal = next.value;
      if (prevVal != null &&
          nextVal != null &&
          (prevVal.mode != nextVal.mode ||
              prevVal.serverUrl != nextVal.serverUrl)) {
        _hasSessionLlmOverride = false;
        _syncDefaultLlmFromSettings();
        unawaited(_syncRemoteCodingWorkspaceIfNeeded());
      }
    });

    final isRemoteServerMode = ref.watch(serverModeProvider).value?.isRemote ?? false;
    final isDesktopPlatform = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.macOS);
    final isDesktop = isDesktopPlatform && MediaQuery.of(context).size.width >= 900;
    final canUseCodingMode = isDesktop || isRemoteServerMode;

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
        emptyChatBuilder: (ctx) => _buildEmptyChatWelcome(ctx),
        settingsDialogBuilder: (ctx, ctrl, initialTab, onClose) {
          final size = MediaQuery.sizeOf(ctx);
          final isMobile = size.width < 700;
          if (isMobile) {
            return Dialog.fullscreen(
              child: TealKitAssistantSettingsDialog(
                controller: ctrl,
                initialTabIndex: initialTab,
                isCodingMode: _isCodingMode,
                onSessionLlmChanged: (isOverride) {
                  _hasSessionLlmOverride = isOverride;
                },
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
                  isCodingMode: _isCodingMode,
                  onSessionLlmChanged: (isOverride) {
                    _hasSessionLlmOverride = isOverride;
                  },
                  onClose: onClose,
                ),
              ),
            ),
          );
        },
        inputTopWidgetBuilder: (ctx, ctrl) {
          return _buildBottomUtilityBar(ctx, ctrl, canUseCodingMode: canUseCodingMode);
        },
        topBarBuilder: (ctx, controller, actions) {
          final l = L.of(ctx);
          final width = MediaQuery.sizeOf(ctx).width;
          final isCompactHeader = width < 600;
          return AppBar(
            titleSpacing: isCompactHeader ? 4 : null,
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
            title: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    l.playground,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  SizedBox(width: isCompactHeader ? 8 : 10),
                  _buildAssistantModeDropdown(
                    ctx,
                    controller,
                    canUseCodingMode: canUseCodingMode,
                    isCompact: isCompactHeader,
                  ),
                ],
              ),
            ),
            actions: [
              if (isCompactHeader)
                PopupMenuButton<String>(
                  tooltip: '${l.loadSavedWorkflow} / ${l.skillsManager}',
                  icon: const Icon(Icons.bookmarks_outlined),
                  onSelected: (val) {
                    if (val == 'load') {
                      _showLoadWorkflowDialog(ctx, controller);
                    } else if (val == 'save') {
                      _showSaveWorkflowDialog(ctx, controller);
                    } else if (val == 'skills') {
                      _openSkillsPicker(ctx, controller);
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'load',
                      child: Row(
                        children: [
                          const Icon(Icons.folder_open_outlined, size: 18),
                          const SizedBox(width: 10),
                          Text(l.loadSavedWorkflow),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'save',
                      child: Row(
                        children: [
                          const Icon(Icons.bookmark_add_outlined, size: 18),
                          const SizedBox(width: 10),
                          Text(l.saveCurrentAsWorkflow),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'skills',
                      child: Row(
                        children: [
                          const Icon(Icons.bolt_outlined, size: 18),
                          const SizedBox(width: 10),
                          Text(l.skillsManager),
                        ],
                      ),
                    ),
                  ],
                )
              else ...[
                // 1. Load Saved Workflow
                IconButton(
                  tooltip: l.loadSavedWorkflow,
                  icon: const Icon(Icons.folder_open_outlined),
                  onPressed: () => _showLoadWorkflowDialog(ctx, controller),
                ),

                // 2. Save as Workflow
                IconButton(
                  tooltip: l.saveCurrentAsWorkflow,
                  icon: const Icon(Icons.bookmark_add_outlined),
                  onPressed: () => _showSaveWorkflowDialog(ctx, controller),
                ),

                // 3. Skills Manager
                IconButton(
                  tooltip: l.skillsManager,
                  icon: const Icon(Icons.bolt_outlined),
                  onPressed: () => _openSkillsPicker(ctx, controller),
                ),
              ],

              // 4. Default Playground actions (Clear, Settings, Inspector toggle)
              ...actions.defaultActionWidgets,
            ],
          );
        },
      ),
    );
  }
}

/// Dialog widget for saving the current Assistant session as a workflow.
/// Owns its [TextEditingController] instances so they are disposed only after
/// the route's exit transition finishes and the widget unmounts.
class _SaveWorkflowDialog extends StatefulWidget {
  final String initialName;
  final String initialPrompt;
  final bool isMobile;
  final bool isRemote;

  const _SaveWorkflowDialog({
    required this.initialName,
    required this.initialPrompt,
    required this.isMobile,
    required this.isRemote,
  });

  @override
  State<_SaveWorkflowDialog> createState() => _SaveWorkflowDialogState();
}

class _SaveWorkflowDialogState extends State<_SaveWorkflowDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _promptCtrl;
  String? _nameError;
  String? _promptError;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.initialName);
    _promptCtrl = TextEditingController(text: widget.initialPrompt);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _promptCtrl.dispose();
    super.dispose();
  }

  void _validateAndClose(BuildContext context) {
    final l = L.of(context);
    final name = _nameCtrl.text.trim();
    final prompt = _promptCtrl.text.trim();
    final nErr = name.isEmpty ? l.nameRequired : null;
    final pErr = prompt.isEmpty ? l.promptRequired : null;
    if (nErr != null || pErr != null) {
      setState(() {
        _nameError = nErr;
        _promptError = pErr;
      });
      return;
    }
    FocusScope.of(context).unfocus();
    Navigator.pop(context, (name: name, prompt: prompt));
  }

  void _cancel(BuildContext context) {
    FocusScope.of(context).unfocus();
    Navigator.pop(context);
  }

  Widget _buildSaveForm(BuildContext context) {
    final l = L.of(context);
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.isRemote ? l.saveWorkflowRemoteDesc : l.saveWorkflowLocalDesc,
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _nameCtrl,
            decoration: InputDecoration(
              labelText: l.workflowName,
              errorText: _nameError,
              border: const OutlineInputBorder(),
            ),
            autofocus: widget.initialPrompt.isNotEmpty,
            onChanged: (_) {
              if (_nameError != null) {
                setState(() => _nameError = null);
              }
            },
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _promptCtrl,
            minLines: 3,
            maxLines: 6,
            autofocus: widget.initialPrompt.isEmpty,
            decoration: InputDecoration(
              labelText: l.taskPrompt,
              hintText: l.taskPromptHint,
              errorText: _promptError,
              alignLabelWithHint: true,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) {
              if (_promptError != null) {
                setState(() => _promptError = null);
              }
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    if (widget.isMobile) {
      return Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(
            title: Text(l.saveAsTask),
            leading: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => _cancel(context),
            ),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 12.0),
                child: FilledButton(
                  onPressed: () => _validateAndClose(context),
                  child: Text(l.save),
                ),
              ),
            ],
          ),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: _buildSaveForm(context),
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
        constraints: const BoxConstraints(maxWidth: 480),
        child: _buildSaveForm(context),
      ),
      actions: [
        TextButton(
          onPressed: () => _cancel(context),
          child: Text(l.cancel),
        ),
        FilledButton(
          onPressed: () => _validateAndClose(context),
          child: Text(widget.isRemote ? l.saveToServer : l.saveToDatabase),
        ),
      ],
    );
  }
}
