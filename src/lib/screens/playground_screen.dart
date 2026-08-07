// ignore_for_file: use_build_context_synchronously

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dartssh2/dartssh2.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Step;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/app_preferences_service.dart';
import '../l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../config/app_theme.dart';
import '../mcp/internal_mcp_registry.dart';
import '../mcp/servers/document_mcp_server.dart';
import '../mcp/servers/py_bridge_mcp_server.dart';
import '../mcp/servers/website_search_mcp_server.dart';
import '../models/workflow_task.dart';
import '../models/skill_def.dart';
import '../models/github_mcp_server_definition.dart';
import '../models/mcp_models.dart';
import '../providers/active_task_provider.dart';
import '../providers/llm_settings_provider.dart';
import '../services/chat_service.dart';
import '../services/data_sources_settings_service.dart';
import '../services/external_tools_settings_service.dart';
import '../services/github_mcp_library_service.dart';
import '../services/github_mcp_runtime_service.dart';
import '../services/workflow_export_service.dart';
import '../services/llm_settings_service.dart';
import '../services/embedded_llm/embedded_model_manager.dart';

import '../models/function_hint.dart';
import '../services/function_hint_database_service.dart';
import 'package:path_provider/path_provider.dart';
import '../utils/saf_bridge.dart';
import '../utils/storage_permission.dart';
import '../widgets/mcp_discover_sheet.dart';
import '../widgets/multimedia_input_widget.dart';
import '../widgets/multimedia_message_widget.dart';

import '../widgets/example_picker_dialog.dart';
import '../widgets/sftp_explorer_dialog.dart';
import '../widgets/tools_drawer.dart';
import '../widgets/tool_list_export_sheet.dart';
import '../widgets/skill_wizard_dialog.dart';
import 'skills_list_screen.dart';
import '../widgets/embedded_llm/embedded_model_picker_widget.dart';
import '../widgets/llm_advanced_params_widget.dart';
import '../widgets/step_list_editor.dart';
import '../widgets/particle_background.dart';
import 'external_tools_settings_screen.dart';
import 'script_library_screen.dart';
import 'js_tool_library_screen.dart';
import 'py_tool_library_screen.dart';
import 'powershell_tool_library_screen.dart';
import 'startup_wizard_screen.dart';
import 'workflow_edit_screen.dart';
import 'function_hints_screen.dart';
import '../providers/server_mode_provider.dart';
import '../providers/sidebar_provider.dart';
import '../providers/database_providers.dart';
import '../widgets/global_agent_stats_widget.dart';

/// Playground screen — a sandbox to try out prompts, tools, and system
/// instructions before scheduling a task.
///
/// Two launch modes:
/// 1. **From start screen** (no task): shows a setup panel for system prompt,
///    initial prompt, tool selection, and a "Generate" wizard button.
/// 2. **From task list/editor** (with task): pre-fills from task settings but
///    allows editing system prompt and tools at any time.
class PlaygroundScreen extends ConsumerStatefulWidget {
  /// Optional pre-existing task to initialise from.
  final WorkflowTask? task;

  const PlaygroundScreen({super.key, this.task});

  @override
  ConsumerState<PlaygroundScreen> createState() => _PlaygroundScreenState();
}

class _PlaygroundScreenState extends ConsumerState<PlaygroundScreen> {
  static const String _websiteSeedUrlsPrefsKey = 'playground_website_seed_urls';
  static const String _websiteMaxPagesPrefsKey = 'playground_website_max_pages';
  static const String _documentRootPathsPrefsKey =
      'playground_document_root_paths';
  static const String _documentFileTypesPrefsKey =
      'playground_document_file_types';

  /// All file types available as toggle chips in the Document Search config.
  static const List<String> _kDocFileTypes = [
    'pdf',
    'txt',
    'md',
    'doc',
    'docx',
    'xls',
    'xlsx',
    'csv',
    'ppt',
    'pptx',
    'rtf',
    'odt',
    'ods',
    'odp',
    'json',
    'xml',
    'html',
    'htm',
    'yaml',
    'yml',
    'log',
  ];
  static const String _kDefaultDocFileTypes =
      'pdf,txt,md,doc,docx,xls,xlsx,csv,ppt,pptx,rtf,json,xml,html,htm,log';

  // ── Setup fields ──
  final _systemPromptUserCtrl = TextEditingController();
  final _systemPromptSkillsCtrl = TextEditingController();
  final _initialPromptCtrl = TextEditingController();
  final _subjectCtrl = TextEditingController();
  final _websiteUrlCtrl = TextEditingController();
  final _websiteMaxPagesCtrl = TextEditingController(text: '100');
  final _sshHostCtrl = TextEditingController();
  final _sshPortCtrl = TextEditingController(text: '22');
  final _sshUsernameCtrl = TextEditingController();
  final _sshPasswordCtrl = TextEditingController();
  String _sshPrivateKeyPem = '';
  String _sshPrivateKeyFileName = '';

  // Generation counter to cancel stale concurrent _updateSkillsSection calls.
  int _skillsUpdateGeneration = 0;

  /// Combined prompt sent to the LLM: user text + auto-generated skills.
  String get _combinedSystemPrompt {
    final user = _systemPromptUserCtrl.text.trimRight();
    final skills = _systemPromptSkillsCtrl.text.trim();
    final activeSkillPrompt = _activeSkill?.skillContent.trim() ?? '';
    final parts = <String>[];
    if (user.isNotEmpty) parts.add(user);
    if (activeSkillPrompt.isNotEmpty) parts.add(activeSkillPrompt);
    if (skills.isNotEmpty) parts.add(skills);
    return parts.join('\n\n');
  }

  /// Splits a stored full system prompt into user + skills parts and
  /// populates the two controllers.
  void _loadSystemPrompt(String full) {
    // Match the skills marker even if it was written with a single newline or
    // extra whitespace (older saves may have used a different separator).
    var match = RegExp(r'\n+Tool Hints:\n').firstMatch(full);
    match ??= RegExp(r'\n+Tool Skills:\n').firstMatch(full);
    if (match != null) {
      _systemPromptUserCtrl.text = full.substring(0, match.start).trimRight();
      _systemPromptSkillsCtrl.text = full.substring(match.start + 1).trim();
    } else {
      _systemPromptUserCtrl.text = full;
      _systemPromptSkillsCtrl.text = '';
    }
  }

  // Internal MCP types the user has selected
  Set<String> _selectedMcpTypes = {};

  // Toolbox (always-on by default, can be disabled per session)
  bool _pgToolboxEnabled = true;

  // External MCP server URLs the user has selected
  Set<String> _selectedExternalServerUrls = {};

  int get _externalServerSelectionLimit => 100;

  // Per-MCP-type init params (e.g. rootPath for document search)
  final Map<String, Map<String, dynamic>> _mcpInitParams = {};

  // Chat state
  final List<ChatMessage> _messages = [];
  StreamSubscription<List<ChatMessage>>? _messagesSubscription;
  StreamSubscription<String>? _errorSubscription;
  ChatService? _subscribedChatService;
  bool _chatStarted = false;
  bool _isGenerating = false;
  bool _pgGenerateOnToolSelect = true;
  // Chat mode: no system prompt, no tools — pure LLM completion
  bool _chatMode = false;
  // Stop after tool call — use raw tool output as result (skip LLM re-processing)
  final bool _stopAfterToolCall = false;
  // Guard to show missing-skills warning at most once per session load.
  bool _skillsWarningShown = false;

  /// Pre-fill text for the chat input box after loading a saved setup.
  String? _pendingInputText;

  /// The workflow that was last loaded (if any). Used to offer in-place update on save.
  WorkflowTask? _activeLoadedWorkflow;

  /// The currently active skill (if any). Shown as a chip above the prompt.
  SkillWizardResult? _activeSkill;

  /// Incremented on each session load to force MultimediaInputWidget remount.
  final int _chatInputKey = 0;

  /// External controller for the chat input box.
  /// Allows reading current text for saving, and writing it for pre-filling.
  final TextEditingController _chatInputController = TextEditingController();

  // LLM selector: 1 = primary (LLM1), 2 = coding (LLM2), 3 = custom override
  int _selectedLlm = 1;
  double _chatFraction = 0.6;
  bool _logsAscending = false;
  DateTime? _logsClearedAt;
  late ScrollController _logsScrollController;
  int _lastLogsCount = 0;

  String? _lastCheckedModel;
  String? _lastCheckedProvider;
  bool _priceIsLive = false;

  void _checkAndRefreshPrice(String providerKey, String model) {
    if (providerKey.isEmpty || model.isEmpty || model == 'unknown') return;
    if (_lastCheckedModel == model && _lastCheckedProvider == providerKey) {
      return;
    }

    _lastCheckedModel = model;
    _lastCheckedProvider = providerKey;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      refreshModelTokenPrice(providerKey: providerKey, model: model).then((_) {
        if (!mounted) return;
        setState(() {
          _priceIsLive = isLiveCachedPrice(
            providerKey: providerKey,
            model: model,
          );
        });
      });
    });
  }

  // Custom LLM override (mirror of task editor)
  bool _overrideLlm = false;
  bool _showCustomLlmAdvanced = false;
  bool _testingLlmConnection = false;
  bool _customThinking = false;
  bool _customUseNativeToolCall = true;
  bool _customIsSlm = false;
  bool _customIsMultiModal = true;
  late TextEditingController _llmProviderCtrl;
  late TextEditingController _llmModelCtrl;
  late TextEditingController _llmApiKeyCtrl;
  late TextEditingController _llmBaseUrlCtrl;
  late TextEditingController _playgroundTemperatureCtrl;
  late TextEditingController _playgroundMaxTokensCtrl;
  late TextEditingController _playgroundMaxToolOutputSizeCtrl;
  late TextEditingController _playgroundTokenWarningThresholdCtrl;
  late TextEditingController _topKCtrl;
  late TextEditingController _topPCtrl;
  late TextEditingController _repeatPenaltyCtrl;
  late TextEditingController _seedCtrl;

  // Website search: global URLs from Settings (always pre-populated, shown locked)
  List<String> _globalWebsiteUrls = [];

  // Document search: global paths from Settings (always pre-populated, shown locked)
  List<String> _globalDocumentPaths = [];

  // Document indexing state
  bool _isIndexing = false;
  bool _isWebsiteIndexing = false;
  int _indexedCount = 0;
  int _indexTotal = 0;
  String _indexCurrentFile = '';
  int _websiteLastIndexedCount = -1; // -1 = never indexed
  DocumentMcpServer? _activeIndexServer;
  WebsiteSearchMcpServer? _activeWebIndexServer;

  // Available internal MCP types from registry
  late final List<InternalMcpInfo> _availableMcpInfos;
  List<GithubMcpServerDefinition> _remoteGithubMcpServers = const [];
  final Map<String, List<String>> _prefetchedRemoteMcpTools = {};

  Future<List<String>> _fetchRemoteMcpToolNames(String serverId) async {
    final client = ref.read(serverApiClientProvider);
    if (client == null) return const [];

    try {
      await client.startMcpServer(serverId);
    } catch (e) {
      // Server may already be running (409) or temporarily unavailable.
      // Continue and still try to query tools for immediate editor feedback.
      debugPrint('[Playground] startMcpServer warning for $serverId: $e');
    }

    try {
      final tools = await client.getMcpServerTools(serverId);
      final names =
          tools
              .map((t) => (t['name'] ?? '').toString().trim())
              .where((n) => n.isNotEmpty)
              .toSet()
              .toList()
            ..sort();
      return names;
    } catch (e) {
      debugPrint('[Playground] getMcpServerTools failed for $serverId: $e');
      return const [];
    }
  }

  Future<void> _eagerDiscoverSelectedRemoteMcpTools() async {
    final isServerMode = ref.read(serverModeProvider).value?.isRemote ?? false;
    if (!isServerMode) {
      // In local mode, eagerly discover selected local GitHub MCP tools in the background!
      for (final type in _selectedMcpTypes.where(
        (t) => t.startsWith('gh_mcp_'),
      )) {
        final serverId = type.substring('gh_mcp_'.length);
        final def = _findGithubMcpById(serverId);
        if (def != null && def.isInstalled) {
          if (_prefetchedRemoteMcpTools[serverId]?.isNotEmpty == true) continue;
          GithubMcpRuntimeService.instance.discoverLocalMcpTools(def).then((
            names,
          ) {
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

    final extSvc = ExternalToolsSettingsService.instance;
    final updatedServers = List<McpToolConfig>.from(extSvc.selectedServers);
    bool serverListChanged = false;

    // Discover selected external MCP server tools from the remote server.
    for (final url in _selectedExternalServerUrls) {
      final names = await _fetchRemoteMcpToolNames(url);
      if (names.isEmpty) continue;

      _prefetchedRemoteMcpTools[url] = names;

      final idx = updatedServers.indexWhere((s) => s.serverUrl == url);
      if (idx >= 0) {
        final cur = updatedServers[idx];
        if (!listEquals(cur.discoveredTools, names)) {
          updatedServers[idx] = cur.copyWith(discoveredTools: names);
          serverListChanged = true;
        }
      }
    }

    // Discover selected GitHub MCP tools from the remote server.
    for (final type in _selectedMcpTypes.where(
      (t) => t.startsWith('gh_mcp_'),
    )) {
      final serverId = type.substring('gh_mcp_'.length);
      final names = await _fetchRemoteMcpToolNames(serverId);
      if (names.isNotEmpty) {
        _prefetchedRemoteMcpTools[serverId] = names;
      }
    }

    if (serverListChanged) {
      // Server mode: keep remote settings in-memory only (no local persistence).
      extSvc.applyInMemory(selectedServers: updatedServers);
    }

    if (mounted) {
      setState(() {});
    }
  }

  @override
  void initState() {
    super.initState();
    final serverState = ref.read(serverModeProvider).value;
    final isLightServer =
        serverState != null && serverState.isRemote && serverState.isLightMode;

    _availableMcpInfos =
        InternalMcpRegistry().availableServers
            .where(
              (s) =>
                  s.type != 'toolbox' &&
                  s.type != 'traffic' &&
                  !s.type.startsWith('gh_mcp_') &&
                  (!isLightServer ||
                      (s.type != 'document' && s.type != 'website_search')),
            )
            .toList()
          ..sort((a, b) => a.displayName.compareTo(b.displayName));

    _llmProviderCtrl = TextEditingController();
    _llmModelCtrl = TextEditingController();
    _llmApiKeyCtrl = TextEditingController();
    _llmBaseUrlCtrl = TextEditingController();
    _playgroundTemperatureCtrl = TextEditingController(text: '0.2');
    _playgroundMaxTokensCtrl = TextEditingController();
    _playgroundMaxToolOutputSizeCtrl = TextEditingController();
    _playgroundTokenWarningThresholdCtrl = TextEditingController();
    _topKCtrl = TextEditingController();
    _topPCtrl = TextEditingController();
    _repeatPenaltyCtrl = TextEditingController();
    _seedCtrl = TextEditingController();

    if (widget.task != null) {
      _initFromTask(widget.task!);
    }
    final configuredMaxPages = _mcpInitParams['website_search']?['maxPages'];
    if (configuredMaxPages is int) {
      _websiteMaxPagesCtrl.text = configuredMaxPages.toString();
    }

    _loadPersistedWebsiteSearchSettings();
    _loadPersistedDocumentSearchSettings();
    _initSshControllers();
    _logsScrollController = ScrollController();
  }

  void _initSshControllers() {
    final ds = DataSourcesSettingsService.instance;
    final sshParams = _mcpInitParams['ssh'];
    _sshHostCtrl.text = (sshParams?['host'] as String?) ?? ds.sshHost;
    _sshPortCtrl.text = ((sshParams?['port'] as int?) ?? ds.sshPort).toString();
    _sshUsernameCtrl.text =
        (sshParams?['username'] as String?) ?? ds.sshUsername;
    _sshPasswordCtrl.text =
        (sshParams?['password'] as String?) ?? ds.sshPassword;
    _sshPrivateKeyPem =
        (sshParams?['privateKey'] as String?) ?? ds.sshPrivateKey;
    _sshPrivateKeyFileName = _sshPrivateKeyPem.isNotEmpty
        ? '(custom key loaded)'
        : '';
  }

  Future<void> _testSshOverrideConnection() async {
    final host = _sshHostCtrl.text.trim();
    final port = int.tryParse(_sshPortCtrl.text.trim()) ?? 22;
    final username = _sshUsernameCtrl.text.trim();
    final password = _sshPasswordCtrl.text;
    final privateKey = _sshPrivateKeyPem.trim();

    if (host.isEmpty || username.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('SSH test failed: host and username are required.'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }

    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Testing SSH connection...')));

    SSHClient? client;
    try {
      client = SSHClient(
        await SSHSocket.connect(
          host,
          port,
        ).timeout(const Duration(seconds: 12)),
        username: username,
        identities: privateKey.isNotEmpty
            ? SSHKeyPair.fromPem(privateKey)
            : null,
        onPasswordRequest: () => password,
      );
      await client.authenticated.timeout(const Duration(seconds: 12));
      final session = await client
          .execute('echo tealkit_ssh_test_ok')
          .timeout(const Duration(seconds: 12));
      await session.stdout.drain<void>();
      await session.stderr.drain<void>();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('SSH connection successful.'),
          backgroundColor: AppTheme.success,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('SSH connection failed: $e'),
          backgroundColor: AppTheme.error,
        ),
      );
    } finally {
      try {
        client?.close();
      } catch (_) {}
    }
  }

  Future<void> _loadPersistedDocumentSearchSettings() async {
    try {
      // Primary source: global paths from Data Sources settings (already configured/indexed).
      final ds = DataSourcesSettingsService.instance;
      if (!ds.isLoaded) await ds.load();
      final globalPaths = ds.documentRootPaths
          .split(';')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();

      // Secondary source: extra paths added specifically in this playground/task session.
      final prefs = await SharedPreferences.getInstance();
      final extraRaw = (prefs.getString(_documentRootPathsPrefsKey) ?? '')
          .trim();
      final extraPaths = extraRaw
          .split(';')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty && !globalPaths.contains(e))
          .toList();

      if (!mounted) return;

      final existingRawRootPaths =
          (_mcpInitParams['document']?['rootPath'] as String? ?? '').trim();
      final hasTaskSpecificRootPath =
          widget.task != null && existingRawRootPaths.isNotEmpty;

      // For a task run: keep task-specific paths but also inject any global ones missing.
      final existingPaths = existingRawRootPaths
          .split(';')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();

      // Merge: global + (task-specific or extra), deduplicated.
      final mergedPaths = <String>[...globalPaths];
      for (final p in (hasTaskSpecificRootPath ? existingPaths : extraPaths)) {
        if (!mergedPaths.contains(p)) mergedPaths.add(p);
      }

      final savedFileTypes = (prefs.getString(_documentFileTypesPrefsKey) ?? '')
          .trim();

      setState(() {
        _globalDocumentPaths = List<String>.from(globalPaths);
        final merged = <String, dynamic>{...(_mcpInitParams['document'] ?? {})};
        if (mergedPaths.isNotEmpty) {
          merged['rootPath'] = mergedPaths.join(';');
        }
        merged['indexingStrategy'] =
            merged['indexingStrategy'] ?? 'before_first_run';
        if (savedFileTypes.isNotEmpty) {
          merged['fileTypes'] = savedFileTypes;
        } else {
          merged.putIfAbsent('fileTypes', () => _kDefaultDocFileTypes);
        }
        _mcpInitParams['document'] = merged;
      });
    } catch (_) {
      // Ignore persistence load failures
    }
  }

  Future<void> _loadPersistedWebsiteSearchSettings() async {
    try {
      // Primary source: global URLs from Data Sources settings (already indexed).
      final ds = DataSourcesSettingsService.instance;
      if (!ds.isLoaded) await ds.load();
      final globalUrls = ds.websiteIndexUrls
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();

      // Secondary source: extra URLs added in this playground session.
      final prefs = await SharedPreferences.getInstance();
      final extraRaw = prefs.getString(_websiteSeedUrlsPrefsKey) ?? '';
      final extraUrls = extraRaw
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty && !globalUrls.contains(e))
          .toList();

      final savedMaxPages =
          (prefs.getInt(_websiteMaxPagesPrefsKey) ?? ds.websiteIndexMaxPages)
              .clamp(1, 1000);

      if (!mounted) return;

      // For a task run: keep task-specific URLs but also inject any global ones missing.
      final existingRawUrls =
          (_mcpInitParams['website_search']?['websiteUrls'] as String? ?? '')
              .trim();
      final existingUrls = existingRawUrls
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();

      // Merge: global + (task-specific or extra), deduplicated.
      final mergedUrls = <String>[...globalUrls];
      for (final u in (widget.task != null ? existingUrls : extraUrls)) {
        if (!mergedUrls.contains(u)) mergedUrls.add(u);
      }

      setState(() {
        _globalWebsiteUrls = List<String>.from(globalUrls);
        final merged = <String, dynamic>{
          ...(_mcpInitParams['website_search'] ?? {}),
        };
        if (mergedUrls.isNotEmpty) {
          merged['websiteUrls'] = mergedUrls.join(', ');
        }
        merged['indexingStrategy'] =
            merged['indexingStrategy'] ?? 'before_first_run';
        merged['maxPages'] = (merged['maxPages'] as int?) ?? savedMaxPages;
        _mcpInitParams['website_search'] = merged;
        _websiteMaxPagesCtrl.text = (merged['maxPages'] as int).toString();
      });
    } catch (_) {
      // Ignore persistence load failures
    }
  }

  Future<void> _savePersistedWebsiteSearchSettings({
    List<String>? urls,
    int? maxPages,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawFromState =
          (_mcpInitParams['website_search']?['websiteUrls'] as String? ?? '')
              .trim();
      final allUrls =
          urls ??
          rawFromState
              .split(',')
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList();
      // Only persist the extra (non-global) URLs; global ones come from DataSourcesSettingsService.
      final extraUrls = allUrls
          .where((u) => !_globalWebsiteUrls.contains(u))
          .toList();
      final effectiveMaxPages =
          (maxPages ??
                  (_mcpInitParams['website_search']?['maxPages'] as int?) ??
                  100)
              .clamp(1, 1000);

      await prefs.setString(_websiteSeedUrlsPrefsKey, extraUrls.join(', '));
      await prefs.setInt(_websiteMaxPagesPrefsKey, effectiveMaxPages);
    } catch (_) {
      // Ignore persistence save failures
    }
  }

  Future<void> _savePersistedDocumentSearchSettings({
    String? rootPath,
    String? fileTypes,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawFromState =
          (_mcpInitParams['document']?['rootPath'] as String? ?? '').trim();
      final allPaths = (rootPath ?? rawFromState)
          .split(';')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      // Only persist the extra (non-global) paths; global ones come from DataSourcesSettingsService.
      final extraPaths = allPaths
          .where((p) => !_globalDocumentPaths.contains(p))
          .toList();
      await prefs.setString(_documentRootPathsPrefsKey, extraPaths.join(';'));
      final rawFileTypesFromState =
          (_mcpInitParams['document']?['fileTypes'] as String? ?? '').trim();
      final effectiveFileTypes = (fileTypes ?? rawFileTypesFromState).trim();
      if (effectiveFileTypes.isNotEmpty) {
        await prefs.setString(_documentFileTypesPrefsKey, effectiveFileTypes);
      }
    } catch (_) {
      // Ignore persistence save failures
    }
  }

  Future<void> _initFromTask(WorkflowTask task) async {
    _activeLoadedWorkflow = task;
    _loadSystemPrompt(task.systemPrompt ?? '');
    _initialPromptCtrl.text = task.prompt;
    if (task.internalMcps.isNotEmpty) {
      _selectedMcpTypes = task.internalMcps
          .where((m) => m.enabled)
          .map((m) => m.mcpType)
          .where((t) => t != 'traffic')
          .toSet();
      _pgToolboxEnabled = !(task.internalMcps.any(
        (m) => m.mcpType == 'toolbox' && !m.enabled,
      ));
    }
    if (task.mcpTools.isNotEmpty) {
      _selectedExternalServerUrls = task.mcpTools
          .map((t) => t.serverUrl)
          .toSet();
    }
    _prefetchedRemoteMcpTools.clear();
    final isServerMode = ref.read(serverModeProvider).value?.isRemote ?? false;
    Future.microtask(() => _getSelectableGithubMcpServers(isServerMode));
    for (final toolConfig in task.mcpTools) {
      if (toolConfig.discoveredTools.isNotEmpty) {
        _prefetchedRemoteMcpTools[toolConfig.serverUrl] = List<String>.from(
          toolConfig.discoveredTools,
        );
      }
    }
    for (final mcp in task.internalMcps.where((m) => m.enabled)) {
      if (mcp.initParams.isNotEmpty) {
        _mcpInitParams[mcp.mcpType] = Map<String, dynamic>.from(mcp.initParams);
      }
    }
    // Restore LLM override from task
    final llmCfg = task.llmConfig;
    if (llmCfg != null &&
        llmCfg.provider.isNotEmpty &&
        llmCfg.provider != 'llm2') {
      final skillProvider = LlmProvider.fromConfigKey(llmCfg.provider);

      bool isAvailable = true;
      if (skillProvider == LlmProvider.none) {
        isAvailable = false;
      } else if (skillProvider == LlmProvider.embedded) {
        final serverState = ref.read(serverModeProvider).value;
        if (serverState?.isLightMode == true) {
          isAvailable = false;
        } else if (serverState?.isRemote == true) {
          isAvailable = llmCfg.model.isNotEmpty;
        } else {
          final downloaded = await EmbeddedModelManager.instance
              .listDownloadedFilenames();
          if (llmCfg.model.isEmpty ||
              (!downloaded.contains(llmCfg.model) &&
                  !downloaded.any((f) => f.contains(llmCfg.model)))) {
            isAvailable = false;
          }
        }
      } else {
        // Check if API key or base URL is present for this provider
        final key = llmCfg.apiKey?.isNotEmpty == true
            ? llmCfg.apiKey!
            : LlmSettingsService.instance.getApiKeyForProvider(skillProvider);
        final baseUrl = llmCfg.baseUrl?.isNotEmpty == true
            ? llmCfg.baseUrl!
            : LlmSettingsService.instance.getBaseUrlForProvider(skillProvider);

        final requiresApiKey =
            skillProvider != LlmProvider.ollama &&
            skillProvider != LlmProvider.openaiCompatible;
        final requiresBaseUrl =
            skillProvider == LlmProvider.ollama ||
            skillProvider == LlmProvider.openaiCompatible ||
            skillProvider == LlmProvider.mistral;

        if (llmCfg.model.isEmpty ||
            (requiresApiKey && key.isEmpty) ||
            (requiresBaseUrl && baseUrl.isEmpty)) {
          isAvailable = false;
        }
      }

      if (!isAvailable) {
        // Show dialog warning and fallback
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            final loc = L.of(context);
            showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text(loc.llmWarning),
                content: Text(
                  loc.skillLlmNotConfigured(skillProvider.label, llmCfg.model),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('OK'),
                  ),
                ],
              ),
            );
          }
        });

        _overrideLlm = false;
        _llmProviderCtrl.text = '';
        _llmModelCtrl.text = '';
        _llmApiKeyCtrl.text = '';
        _llmBaseUrlCtrl.text = '';
      } else {
        _overrideLlm = true;
        _llmProviderCtrl.text = llmCfg.provider;
        _llmModelCtrl.text = llmCfg.model;
        _llmApiKeyCtrl.text = llmCfg.apiKey?.isNotEmpty == true
            ? llmCfg.apiKey!
            : LlmSettingsService.instance.getApiKeyForProvider(skillProvider);
        _llmBaseUrlCtrl.text = llmCfg.baseUrl?.isNotEmpty == true
            ? llmCfg.baseUrl!
            : LlmSettingsService.instance.getBaseUrlForProvider(skillProvider);
        _playgroundTemperatureCtrl.text = llmCfg.temperature.toString();
        _playgroundMaxTokensCtrl.text = llmCfg.maxTokens.toString();
        _playgroundMaxToolOutputSizeCtrl.text =
            (llmCfg.extraParams['max_tool_output_size'] ?? 2560000).toString();
        _playgroundTokenWarningThresholdCtrl.text =
            (llmCfg.extraParams['token_warning_threshold'] ?? 1500000)
                .toString();
        _customUseNativeToolCall =
            (llmCfg.extraParams['use_native_tool_call'] as bool?) ?? true;
        _customIsSlm = (llmCfg.extraParams['is_slm'] as bool?) ?? false;
        _customIsMultiModal =
            (llmCfg.extraParams['is_multi_modal'] as bool?) ?? true;
        _customThinking = (llmCfg.extraParams['thinking'] as bool?) ?? false;
      }
    } else if (llmCfg?.provider == 'llm2') {
      _selectedLlm = 2;
    } else {
      _overrideLlm = false;
    }
    // Rebuild skills section so stale/empty saved skills are refreshed.
    _skillsWarningShown = false;

    // Collect required internal MCP types from task + agent internalMcps
    final requiredMcpTypes = <String>{};
    for (final m in task.internalMcps) {
      if (m.enabled) requiredMcpTypes.add(m.mcpType);
    }
    for (final a in task.agents) {
      for (final m in a.internalMcps) {
        if (m.enabled) requiredMcpTypes.add(m.mcpType);
      }
    }

    if (requiredMcpTypes.isNotEmpty) {
      // Check which tools are already enabled
      final enabledTypes = Set<String>.from(_selectedMcpTypes);
      final missingTypes = requiredMcpTypes
          .where((t) => !enabledTypes.contains(t))
          .toList();

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _showRequiredToolsDialog(missingTypes, requiredMcpTypes.toList());
        }
      });
    } else {
      // No required tools — stay on init screen, don't auto-start
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _eagerDiscoverSelectedRemoteMcpTools();
        _updateSkillsSection();
      });
    }
  }

  /// Shows a dialog listing required tools from the imported skill
  /// with options to enable them.
  Future<void> _showRequiredToolsDialog(
    List<String> missingTypes,
    List<String> allRequired,
  ) async {
    final loc = L.of(context);
    final theme = Theme.of(context);

    // Human-readable labels for common MCP types
    const typeLabels = <String, String>{
      'web_search': 'Web Search',
      'weather': 'Weather',
      'ssh': 'SSH / Remote Shell',
      'imap': 'Email (IMAP)',
      'gmail': 'Gmail',
      'google_calendar': 'Google Calendar',
      'google_drive': 'Google Drive',
      'home_assistant': 'Home Assistant',
      'website_search': 'Website Index Search',
      'document': 'Document Search',
      'chart': 'Chart Generation',
      'mermaid': 'Mermaid Diagrams',
      'file': 'File Operations',
      'excel': 'Excel Operations',
      'js_bridge': 'JavaScript Tools',
      'py_bridge': 'Python Tools',
      'toolbox': 'Toolbox',
    };

    String labelFor(String type) =>
        typeLabels[type] ?? type.replaceAll('_', ' ');

    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final toEnable = List<String>.from(missingTypes);
          return AlertDialog(
            title: Text(loc.toolWarning),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'This skill requires the following capabilities:',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  ...allRequired.map((type) {
                    final isMissing = missingTypes.contains(type);
                    return CheckboxListTile(
                      value: !isMissing || toEnable.contains(type),
                      onChanged: isMissing
                          ? (v) {
                              setDialogState(() {
                                if (v == true) {
                                  toEnable.add(type);
                                } else {
                                  toEnable.remove(type);
                                }
                              });
                            }
                          : null,
                      title: Text(labelFor(type)),
                      subtitle: Text(
                        isMissing ? 'Not currently enabled' : 'Already enabled',
                        style: TextStyle(
                          color: isMissing ? Colors.orange : Colors.green,
                          fontSize: 12,
                        ),
                      ),
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                    );
                  }),
                  if (missingTypes.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          Icon(
                            Icons.check_circle,
                            color: Colors.green,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Text('All required tools are already enabled.'),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Skip'),
              ),
              FilledButton(
                onPressed: () {
                  // Apply selected tools
                  setState(() {
                    for (final t in toEnable) {
                      if (!_selectedMcpTypes.contains(t)) {
                        _selectedMcpTypes.add(t);
                      }
                    }
                  });
                  Navigator.of(ctx).pop(true);
                },
                child: Text(
                  missingTypes.isEmpty
                      ? 'Done'
                      : 'Enable Selected (${toEnable.length})',
                ),
              ),
            ],
          );
        },
      ),
    );

    // Stay on init screen — do NOT auto-start chat
    if (mounted) {
      _eagerDiscoverSelectedRemoteMcpTools();
      _updateSkillsSection();
    }
  }

  @override
  void dispose() {
    _messagesSubscription?.cancel();
    _errorSubscription?.cancel();
    _systemPromptUserCtrl.dispose();
    _systemPromptSkillsCtrl.dispose();
    _initialPromptCtrl.dispose();
    _subjectCtrl.dispose();
    _websiteUrlCtrl.dispose();
    _websiteMaxPagesCtrl.dispose();
    _sshHostCtrl.dispose();
    _sshPortCtrl.dispose();
    _sshUsernameCtrl.dispose();
    _sshPasswordCtrl.dispose();
    _chatInputController.dispose();
    _logsScrollController.dispose();
    _llmProviderCtrl.dispose();
    _llmModelCtrl.dispose();
    _llmApiKeyCtrl.dispose();
    _llmBaseUrlCtrl.dispose();
    _playgroundTemperatureCtrl.dispose();
    _playgroundMaxTokensCtrl.dispose();
    _playgroundMaxToolOutputSizeCtrl.dispose();
    _playgroundTokenWarningThresholdCtrl.dispose();
    _topKCtrl.dispose();
    _topPCtrl.dispose();
    _repeatPenaltyCtrl.dispose();
    _seedCtrl.dispose();
    super.dispose();
  }

  Future<void> _testPlaygroundLlmConnection() async {
    setState(() => _testingLlmConnection = true);
    try {
      final provider = LlmProvider.fromConfigKey(_llmProviderCtrl.text.trim());
      String apiKey = _llmApiKeyCtrl.text.trim();
      final baseUrl = _llmBaseUrlCtrl.text.trim();

      // Fallback to settings-configured API key / baseUrl if empty
      if (apiKey.isEmpty) {
        apiKey = LlmSettingsService.instance.getApiKeyForProvider(provider);
      }
      String resolvedBaseUrl = baseUrl;
      if (resolvedBaseUrl.isEmpty) {
        resolvedBaseUrl = LlmSettingsService.instance.getBaseUrlForProvider(
          provider,
        );
      }

      bool success = false;
      String? errorMsg;

      switch (provider) {
        case LlmProvider.ollama:
          final ollamaBase =
              (resolvedBaseUrl.isEmpty
                      ? 'http://localhost:11434'
                      : resolvedBaseUrl)
                  .replaceAll(RegExp(r'/+$'), '');
          final ollamaTagsBase = ollamaBase.endsWith('/api')
              ? ollamaBase
              : '$ollamaBase/api';
          final url = Uri.parse('$ollamaTagsBase/tags');
          final headers = apiKey.isNotEmpty
              ? {'Authorization': 'Bearer $apiKey'}
              : <String, String>{};
          final resp = await http
              .get(url, headers: headers)
              .timeout(const Duration(seconds: 15));
          success = resp.statusCode >= 200 && resp.statusCode < 300;
          if (!success) errorMsg = 'HTTP ${resp.statusCode}';
          break;
        case LlmProvider.openaiCompatible:
          final base = resolvedBaseUrl.isEmpty
              ? 'http://localhost:8080/v1'
              : resolvedBaseUrl;
          final url = Uri.parse('$base/models');
          final headers = apiKey.isNotEmpty
              ? {'Authorization': 'Bearer $apiKey'}
              : <String, String>{};
          final resp = await http
              .get(url, headers: headers)
              .timeout(const Duration(seconds: 15));
          success = resp.statusCode >= 200 && resp.statusCode < 300;
          if (!success) errorMsg = 'HTTP ${resp.statusCode}';
          break;
        case LlmProvider.openai:
          final url = Uri.parse('https://api.openai.com/v1/models');
          final resp = await http
              .get(url, headers: {'Authorization': 'Bearer $apiKey'})
              .timeout(const Duration(seconds: 15));
          success = resp.statusCode >= 200 && resp.statusCode < 300;
          if (!success) errorMsg = 'HTTP ${resp.statusCode}';
          break;
        case LlmProvider.gemini:
          if (apiKey.isEmpty) {
            errorMsg =
                'API key is empty. Please provide a valid Gemini API key.';
            success = false;
            break;
          }
          final url = Uri.parse(
            'https://generativelanguage.googleapis.com/v1beta/models?key=$apiKey',
          );
          final resp = await http.get(url).timeout(const Duration(seconds: 15));
          success = resp.statusCode >= 200 && resp.statusCode < 300;
          if (!success) errorMsg = 'HTTP ${resp.statusCode}';
          break;
        case LlmProvider.claude:
          final url = Uri.parse('https://api.anthropic.com/v1/models');
          final resp = await http
              .get(
                url,
                headers: {
                  'x-api-key': apiKey,
                  'anthropic-version': '2023-06-01',
                },
              )
              .timeout(const Duration(seconds: 15));
          success = resp.statusCode >= 200 && resp.statusCode < 300;
          if (!success) errorMsg = 'HTTP ${resp.statusCode}';
          break;
        case LlmProvider.mistral:
          final base = resolvedBaseUrl.isEmpty
              ? 'https://api.mistral.ai/v1'
              : resolvedBaseUrl;
          final url = Uri.parse(
            '${base.replaceAll(RegExp(r'/+$'), '')}/models',
          );
          final resp = await http
              .get(url, headers: {'Authorization': 'Bearer $apiKey'})
              .timeout(const Duration(seconds: 15));
          success = resp.statusCode >= 200 && resp.statusCode < 300;
          if (!success) errorMsg = 'HTTP ${resp.statusCode}';
          break;
        default:
          errorMsg = 'Unsupported provider for testing';
          break;
      }

      if (mounted) {
        if (success) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${provider.label} connection successful ✓'),
              backgroundColor: Colors.green,
              behavior: SnackBarBehavior.floating,
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Connection failed: ${errorMsg ?? "Unknown error"}',
              ),
              backgroundColor: Colors.red,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Connection failed: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _testingLlmConnection = false);
      }
    }
  }

  Uri? _normalizeWebsiteUrl(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;
    try {
      final parsed = Uri.parse(
        value.contains('://') ? value : 'https://$value',
      );
      if ((parsed.scheme != 'http' && parsed.scheme != 'https') ||
          parsed.host.isEmpty) {
        return null;
      }
      return parsed.removeFragment();
    } catch (_) {
      return null;
    }
  }

  // ── Load example task ──

  Future<void> _loadExample() async {
    final example = await ExamplePickerDialog.show(
      context,
      excludedToolType: 'js_bridge',
      title: 'Example Tasks',
      subtitle:
          'Tap an example to load its prompt and tools into the current view.',
    );
    if (example == null || !mounted) return;
    setState(() {
      _initialPromptCtrl.text = example.prompt;
      _selectedMcpTypes = Set<String>.from(
        example.tools.where((t) => t != 'traffic'),
      );
      if (example.systemPrompt != null && example.systemPrompt!.isNotEmpty) {
        _loadSystemPrompt(example.systemPrompt!);
      }
      // Keep any existing document search paths already configured
    });
    // Refresh skills to match the newly selected tools.
    _updateSkillsSection();
  }

  bool _addWebsiteFromInput(List<String> selectedUrls) {
    final parsed = _normalizeWebsiteUrl(_websiteUrlCtrl.text);
    if (parsed == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L.of(context).invalidWebsiteUrl),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return false;
    }

    final normalized = parsed.toString();
    final updated = List<String>.from(selectedUrls);
    if (!updated.contains(normalized)) {
      const maxUrls = 10;
      if (updated.length >= maxUrls) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(L.of(context).maxWebsitesReached),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return false;
      }
      updated.add(normalized);
      setState(() {
        _mcpInitParams['website_search'] = {
          ...(_mcpInitParams['website_search'] ?? {}),
          'websiteUrls': updated.join(', '),
          'indexingStrategy':
              _mcpInitParams['website_search']?['indexingStrategy'] ??
              'before_first_run',
          'maxPages': _mcpInitParams['website_search']?['maxPages'] ?? 100,
        };
        _websiteUrlCtrl.clear();
      });
      _savePersistedWebsiteSearchSettings(urls: updated);
      return true;
    }

    return true;
  }

  List<Widget> _buildCustomLlmPanel(LlmSettingsService llmSettings) {
    final isServerMode = ref.watch(serverModeProvider).value?.isRemote ?? false;
    final serverClient = isServerMode
        ? ref.read(serverApiClientProvider)
        : null;
    final selectedProvider = LlmProvider.fromConfigKey(
      _llmProviderCtrl.text.trim(),
    );
    final requiresBaseUrl =
        selectedProvider == LlmProvider.ollama ||
        selectedProvider == LlmProvider.openaiCompatible ||
        selectedProvider == LlmProvider.mistral;
    final hasDedicatedApiKeyField =
        selectedProvider != LlmProvider.ollama &&
        selectedProvider != LlmProvider.openaiCompatible;

    return [
      const SizedBox(height: 12),
      if (llmSettings.isConfigured) ...[
        OutlinedButton.icon(
          onPressed: () {
            setState(() {
              _llmProviderCtrl.text = llmSettings.provider.configKey;
              _llmModelCtrl.text = llmSettings.model;
              _llmApiKeyCtrl.text = llmSettings.apiKey;
              _llmBaseUrlCtrl.text = llmSettings.baseUrl;
              _playgroundTemperatureCtrl.text = llmSettings.temperature
                  .toString();
              _playgroundMaxTokensCtrl.text = llmSettings.maxTokens.toString();
              _playgroundMaxToolOutputSizeCtrl.text = llmSettings
                  .maxToolOutputSize
                  .toString();
              _playgroundTokenWarningThresholdCtrl.text = llmSettings
                  .tokenWarningThreshold
                  .toString();
              _customUseNativeToolCall = llmSettings.useNativeToolCall;
              _customIsSlm = llmSettings.isSlm;
              _customIsMultiModal = llmSettings.isMultiModal;
              _customThinking = llmSettings.thinking;
            });
          },
          icon: const Icon(Icons.auto_fix_high, size: 18),
          label: const Text('Apply defaults from settings'),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppTheme.primaryBlue,
            side: BorderSide(
              color: AppTheme.primaryBlue.withValues(alpha: 0.5),
            ),
          ),
        ),
        const SizedBox(height: 12),
      ],
      DropdownButtonFormField<String>(
        key: ValueKey('pg_llm_provider_${_llmProviderCtrl.text}'),
        initialValue: _llmProviderCtrl.text.isNotEmpty
            ? _llmProviderCtrl.text
            : null,
        decoration: InputDecoration(labelText: 'Provider'),
        items: [
          const DropdownMenuItem(value: 'openai', child: Text('OpenAI')),
          const DropdownMenuItem(value: 'gemini', child: Text('Google Gemini')),
          const DropdownMenuItem(
            value: 'claude',
            child: Text('Anthropic Claude'),
          ),
          const DropdownMenuItem(value: 'mistral', child: Text('Mistral AI')),
          const DropdownMenuItem(
            value: 'ollama',
            child: Text('Ollama (local)'),
          ),
          const DropdownMenuItem(
            value: 'openai_compatible',
            child: Text('OpenAI-compatible'),
          ),
          const DropdownMenuItem(
            value: 'embedded',
            child: Text('Embedded (on-device)'),
          ),
        ],
        onChanged: (v) {
          setState(() {
            final providerKey = v ?? '';
            _llmProviderCtrl.text = providerKey;
            if (providerKey == 'embedded') {
              _llmApiKeyCtrl.text = '';
              _llmBaseUrlCtrl.text = '';
              _playgroundMaxTokensCtrl.text = '4096';
              return;
            }
            final provider = LlmProvider.fromConfigKey(providerKey);
            final providerNeedsBaseUrl =
                provider == LlmProvider.ollama ||
                provider == LlmProvider.openaiCompatible ||
                provider == LlmProvider.mistral;
            final defaults = defaultModels[provider] ?? const <String>[];
            if (_llmModelCtrl.text.trim().isEmpty && defaults.isNotEmpty) {
              _llmModelCtrl.text = defaults.first;
            }
            _customIsMultiModal = LlmSettingsService.detectDefaultMultiModal(
              provider,
              _llmModelCtrl.text,
            );
            final pk = llmSettings.getApiKeyForProvider(provider);
            if (pk.isNotEmpty) _llmApiKeyCtrl.text = pk;
            if (providerNeedsBaseUrl) {
              final bu = llmSettings.getBaseUrlForProvider(provider);
              if (bu.isNotEmpty) _llmBaseUrlCtrl.text = bu;
            } else {
              _llmBaseUrlCtrl.clear();
            }
          });
          _updateSkillsSection();
        },
      ),
      const SizedBox(height: 12),
      if (_llmProviderCtrl.text == 'embedded') ...[
        EmbeddedModelPickerWidget(
          selectedFilename: _llmModelCtrl.text,
          serverClient: serverClient,
          onFilenameSelected: (filename) {
            setState(() {
              _llmModelCtrl.text = filename;
              _customIsMultiModal = LlmSettingsService.detectDefaultMultiModal(
                LlmProvider.fromConfigKey(_llmProviderCtrl.text.trim()),
                filename,
              );
            });
            _updateSkillsSection();
          },
        ),
      ] else ...[
        Autocomplete<String>(
          initialValue: TextEditingValue(text: _llmModelCtrl.text),
          optionsBuilder: (textEditingValue) {
            final provider = LlmProvider.fromConfigKey(
              _llmProviderCtrl.text.trim(),
            );
            if (provider == LlmProvider.ollama ||
                provider == LlmProvider.openaiCompatible) {
              return const Iterable<String>.empty();
            }
            final suggestions = defaultModels[provider] ?? const <String>[];
            if (textEditingValue.text.trim().isEmpty) return suggestions;
            final q = textEditingValue.text.toLowerCase();
            return suggestions.where((m) => m.toLowerCase().contains(q));
          },
          fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
            if (controller.text != _llmModelCtrl.text) {
              controller.value = TextEditingValue(
                text: _llmModelCtrl.text,
                selection: TextSelection.collapsed(
                  offset: _llmModelCtrl.text.length,
                ),
              );
            }
            return TextFormField(
              controller: controller,
              focusNode: focusNode,
              onChanged: (value) {
                _llmModelCtrl.text = value;
                setState(() {
                  _customIsMultiModal =
                      LlmSettingsService.detectDefaultMultiModal(
                        LlmProvider.fromConfigKey(_llmProviderCtrl.text.trim()),
                        value,
                      );
                });
              },
              decoration: const InputDecoration(
                labelText: 'Model',
                hintText: 'e.g. gpt-4o, gemini-2.0-flash',
              ),
            );
          },
          onSelected: (value) {
            setState(() {
              _llmModelCtrl.text = value;
              _customIsMultiModal = LlmSettingsService.detectDefaultMultiModal(
                LlmProvider.fromConfigKey(_llmProviderCtrl.text.trim()),
                value,
              );
            });
            _updateSkillsSection();
          },
        ),
        const SizedBox(height: 12),
        if (hasDedicatedApiKeyField)
          TextFormField(
            controller: _llmApiKeyCtrl,
            decoration: const InputDecoration(
              labelText: 'API Key',
              hintText: 'Leave empty to use key from settings',
            ),
            obscureText: true,
          ),
        if (requiresBaseUrl) ...[
          const SizedBox(height: 12),
          TextFormField(
            controller: _llmBaseUrlCtrl,
            decoration: const InputDecoration(
              labelText: 'Base URL',
              hintText: 'Leave empty for default endpoint',
            ),
          ),
          if (!hasDedicatedApiKeyField) ...[
            const SizedBox(height: 12),
            TextFormField(
              controller: _llmApiKeyCtrl,
              decoration: const InputDecoration(
                labelText: 'API Key',
                hintText: 'Optional for this provider',
              ),
              obscureText: true,
            ),
          ],
        ],
        if (selectedProvider != LlmProvider.none &&
            selectedProvider != LlmProvider.embedded) ...[
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: _testingLlmConnection
                ? null
                : _testPlaygroundLlmConnection,
            icon: _testingLlmConnection
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                : const Icon(Icons.wifi, size: 16),
            label: Text(_testingLlmConnection ? 'Testing...' : 'Test API'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryBlue,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ],
      SwitchListTile(
        title: Text(L.of(context).llmAdvancedSettings),
        value: _showCustomLlmAdvanced,
        onChanged: (v) => setState(() => _showCustomLlmAdvanced = v),
        activeTrackColor: AppTheme.primaryBlue,
        contentPadding: EdgeInsets.zero,
      ),
      if (_showCustomLlmAdvanced) ...[
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: _playgroundTemperatureCtrl,
                decoration: const InputDecoration(labelText: 'Temperature'),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: TextFormField(
                controller: _playgroundMaxTokensCtrl,
                decoration: InputDecoration(
                  labelText: 'Max tokens',
                  helperText: _llmProviderCtrl.text == 'embedded'
                      ? 'Limited by context window'
                      : null,
                  helperStyle: const TextStyle(fontSize: 11),
                ),
                keyboardType: TextInputType.number,
                readOnly: _llmProviderCtrl.text == 'embedded',
                style: _llmProviderCtrl.text == 'embedded'
                    ? TextStyle(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.45),
                      )
                    : null,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _playgroundMaxToolOutputSizeCtrl,
          decoration: const InputDecoration(
            labelText: 'Max Tool Output Size (chars)',
            hintText: '0 = unlimited',
            helperText: 'Limit tool output size (0 = unlimited)',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.build_circle_outlined),
          ),
          keyboardType: TextInputType.number,
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _playgroundTokenWarningThresholdCtrl,
          decoration: const InputDecoration(
            labelText: 'Token Warning Threshold',
            hintText: 'e.g. 1500000',
            helperText: 'Cleanup suggestion after this many tokens',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.warning_amber_outlined),
          ),
          keyboardType: TextInputType.number,
        ),
        const SizedBox(height: 16),
        LlmAdvancedParamsWidget(
          topKController: _topKCtrl,
          topPController: _topPCtrl,
          repeatPenaltyController: _repeatPenaltyCtrl,
          seedController: _seedCtrl,
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          title: const Text('Thinking / Reasoning'),
          subtitle: const Text(
            'Allow the model to emit internal thinking/reasoning tokens '
            '(e.g. <think> blocks, QwQ, DeepSeek-R1). Disable to suppress '
            'thinking output and reduce token usage.',
          ),
          value: _customThinking,
          onChanged: (v) => setState(() => _customThinking = v),
          activeTrackColor: AppTheme.primaryBlue,
          contentPadding: EdgeInsets.zero,
        ),
      ],
      // ── Native tool call switch (Ollama only, outside advanced) ──
      if (selectedProvider == LlmProvider.ollama) ...[
        const SizedBox(height: 8),
        SwitchListTile.adaptive(
          value: _customUseNativeToolCall,
          onChanged: (v) => setState(() => _customUseNativeToolCall = v),
          title: Text(
            L.of(context).llmUseNativeToolCall,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(L.of(context).llmUseNativeToolCallDescription),
          activeTrackColor: AppTheme.primaryBlue,
          contentPadding: EdgeInsets.zero,
        ),
        const SizedBox(height: 12),
      ],
      if (selectedProvider != LlmProvider.none) ...[
        CheckboxListTile(
          value: _customIsSlm,
          onChanged: (v) => setState(() => _customIsSlm = v ?? false),
          title: const Text(
            'Small Language Model (SLM)',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: const Text(
            'Use a shorter, directive system prompt that forces immediate tool calls. '
            'Recommended for local/small models (Ollama, Phi, Mistral-small, etc.).',
          ),
          activeColor: AppTheme.primaryBlue,
          controlAffinity: ListTileControlAffinity.leading,
          dense: true,
          contentPadding: EdgeInsets.zero,
        ),
        CheckboxListTile(
          value: _customIsMultiModal,
          onChanged: (v) => setState(() => _customIsMultiModal = v ?? false),
          title: const Text(
            'Multi-Modal Model',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: const Text(
            'Enable multimodal features (attachments, images). '
            'If disabled, the attachment button will be hidden for this model.',
          ),
          activeColor: AppTheme.primaryBlue,
          controlAffinity: ListTileControlAffinity.leading,
          dense: true,
          contentPadding: EdgeInsets.zero,
        ),
        const SizedBox(height: 16),
      ],
    ];
  }

  TaskLlmConfig? _buildPlaygroundLlmConfig() {
    if (_overrideLlm && _llmProviderCtrl.text.isNotEmpty) {
      final selectedProvider = LlmProvider.fromConfigKey(
        _llmProviderCtrl.text.trim(),
      );
      final requiresBaseUrl =
          selectedProvider == LlmProvider.ollama ||
          selectedProvider == LlmProvider.openaiCompatible ||
          selectedProvider == LlmProvider.mistral;
      final temp =
          double.tryParse(_playgroundTemperatureCtrl.text.trim()) ?? 0.2;
      final maxTok = int.tryParse(_playgroundMaxTokensCtrl.text.trim()) ?? 0;
      final extraParams = <String, dynamic>{};
      final topK = int.tryParse(_topKCtrl.text.trim());
      if (topK != null) extraParams['top_k'] = topK;
      final topP = double.tryParse(_topPCtrl.text.trim());
      if (topP != null) extraParams['top_p'] = topP;
      final rep = double.tryParse(_repeatPenaltyCtrl.text.trim());
      if (rep != null) extraParams['repeat_penalty'] = rep;
      final seed = int.tryParse(_seedCtrl.text.trim());
      if (seed != null) extraParams['seed'] = seed;
      final maxToolOutput = int.tryParse(
        _playgroundMaxToolOutputSizeCtrl.text.trim(),
      );
      if (maxToolOutput != null) {
        extraParams['max_tool_output_size'] = maxToolOutput;
      }
      final tokenWarningThreshold = int.tryParse(
        _playgroundTokenWarningThresholdCtrl.text.trim(),
      );
      if (tokenWarningThreshold != null) {
        extraParams['token_warning_threshold'] = tokenWarningThreshold;
      }
      if (_customThinking) extraParams['thinking'] = true;
      extraParams['use_native_tool_call'] = _customUseNativeToolCall;
      extraParams['is_slm'] = _customIsSlm;
      extraParams['is_multi_modal'] = _customIsMultiModal;
      return TaskLlmConfig(
        provider: _llmProviderCtrl.text.trim(),
        model: _llmModelCtrl.text.trim(),
        apiKey: _llmApiKeyCtrl.text.trim().isNotEmpty
            ? _llmApiKeyCtrl.text.trim()
            : null,
        baseUrl: requiresBaseUrl && _llmBaseUrlCtrl.text.trim().isNotEmpty
            ? _llmBaseUrlCtrl.text.trim()
            : null,
        temperature: temp,
        maxTokens: maxTok,
        extraParams: extraParams,
      );
    }
    if (_selectedLlm == 2) {
      return const TaskLlmConfig(provider: 'llm2', model: '');
    }
    return null;
  }

  // ── Start/Reset chat ──

  Future<void> _startChat() async {
    if (!mounted) return;

    final systemPrompt = _combinedSystemPrompt.trim();
    final initialPrompt = _initialPromptCtrl.text.trim();

    // Build a temporary WorkflowTask for the active task provider
    final task = WorkflowTask(
      id: const Uuid().v4(),
      name: 'Playground',
      systemPrompt: systemPrompt.isEmpty ? null : systemPrompt,
      prompt: initialPrompt.isEmpty ? 'Hello' : initialPrompt,
      executionPlan: const ExecutionPlan(cronExpression: ''),
      llmConfig: _buildPlaygroundLlmConfig(),
      chatMode: _chatMode,
      stopAfterToolCall: _stopAfterToolCall,
      internalMcps: _chatMode
          ? const []
          : [
              ..._selectedMcpTypes.map((type) {
                return InternalMcpEntry(
                  id: const Uuid().v4(),
                  mcpType: type,
                  enabled: true,
                  initParams: _mcpInitParams[type] ?? {},
                );
              }),
              if (!_pgToolboxEnabled)
                InternalMcpEntry(
                  id: const Uuid().v4(),
                  mcpType: 'toolbox',
                  label: 'Toolbox',
                  enabled: false,
                  initParams: const {},
                ),
            ],
      mcpTools: _chatMode
          ? const []
          : ExternalToolsSettingsService.instance.selectedServers
                .where((s) => _selectedExternalServerUrls.contains(s.serverUrl))
                .toList(),
    );

    // Cancel previous subscriptions
    _messagesSubscription?.cancel();
    _errorSubscription?.cancel();
    _subscribedChatService = null;
    _messages.clear();

    setState(() => _chatStarted = true);

    await ref.read(activeTaskProvider.notifier).setTask(task);

    // Pre-fill the chat input with the initial prompt — but do NOT auto-send.
    // The user can review/edit the text before sending.
    if (initialPrompt.isNotEmpty && mounted) {
      _chatInputController.text = initialPrompt;
      _chatInputController.selection = TextSelection.collapsed(
        offset: initialPrompt.length,
      );
    }
  }

  Future<void> _resetChat() async {
    final taskState = ref.read(activeTaskProvider);
    try {
      if (taskState?.chatService != null) {
        await taskState!.chatService!.resetConversation();
      }
    } catch (_) {
      // Service may have been disposed already; proceed with UI reset
    }
    if (!mounted) return;
    // Re-init with current settings
    _messagesSubscription?.cancel();
    _errorSubscription?.cancel();
    _subscribedChatService = null;
    _messages.clear();
    _logsClearedAt = null;
    setState(() {
      _chatStarted = false;
    });
  }

  void _resetPlayground() {
    setState(() {
      _activeLoadedWorkflow = null;
      _subjectCtrl.clear();
      _systemPromptUserCtrl.clear();
      _systemPromptSkillsCtrl.clear();
      _chatInputController.clear();
      _messages.clear();
      _chatStarted = false;
      _selectedMcpTypes.clear();
      _selectedExternalServerUrls.clear();
      _pgToolboxEnabled = true;
    });
    _updateSkillsSection();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Playground reset to initial state.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ── Save Skill / Workflow ──

  Future<void> _saveSetup() async {
    final canSave =
        (_systemPromptUserCtrl.text.isNotEmpty ||
            _systemPromptSkillsCtrl.text.isNotEmpty) ||
        _initialPromptCtrl.text.isNotEmpty ||
        _chatInputController.text.isNotEmpty ||
        _messages.any((m) => m.role == ChatRole.user) ||
        _selectedMcpTypes.isNotEmpty ||
        _selectedExternalServerUrls.isNotEmpty;
    if (!canSave) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Nothing to save — add a system prompt, initial prompt, or select tools first.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    // Capture initial prompt (supporting multi-turn prompts)
    String initialPrompt;
    if (_chatStarted) {
      final List<Step> steps = [];
      for (final msg in _messages) {
        if (msg.role == ChatRole.user) {
          final text = msg.content.trim();
          if (text.isNotEmpty && !text.startsWith('Tool result data:')) {
            if (text.contains('++#++')) {
              steps.addAll(parseWorkflowSteps(text));
            } else {
              final toolNames = msg.availableTools?.map((t) => t.name).toList();
              steps.add(Step(text: text, enabledToolNames: toolNames));
            }
          }
        }
      }

      final typed = _chatInputController.text.trim();
      if (typed.isNotEmpty) {
        if (typed.contains('++#++')) {
          steps.addAll(parseWorkflowSteps(typed));
        } else {
          final currentTools = _subscribedChatService?.availableTools
              .map((t) => t.name)
              .toList();
          steps.add(Step(text: typed, enabledToolNames: currentTools));
        }
      }

      if (steps.isEmpty) {
        initialPrompt = '';
      } else {
        initialPrompt = serializeWorkflowSteps(steps);
      }
    } else {
      initialPrompt = _initialPromptCtrl.text.trim();
    }

    // Ensure the latest SSH settings from controllers are saved in _mcpInitParams
    if (_selectedMcpTypes.contains('ssh')) {
      _mcpInitParams['ssh'] = {
        'host': _sshHostCtrl.text.trim(),
        'port': int.tryParse(_sshPortCtrl.text.trim()) ?? 22,
        'username': _sshUsernameCtrl.text.trim(),
        'password': _sshPasswordCtrl.text,
        'privateKey': _sshPrivateKeyPem,
        '_privateKeyFileName': _sshPrivateKeyFileName,
      };
    }
    final maxPagesVal = int.tryParse(_websiteMaxPagesCtrl.text.trim());
    if (maxPagesVal != null) {
      _mcpInitParams['website_search'] = {
        ...(_mcpInitParams['website_search'] ?? {}),
        'maxPages': maxPagesVal,
      };
    }

    bool saveAsWorkflow = true;
    bool saveAsSkill = false;

    final result =
        await showDialog<
          ({String name, bool saveAsWorkflow, bool saveAsSkill})
        >(
          context: context,
          builder: (ctx) {
            final nameCtrl = TextEditingController(
              text: _activeLoadedWorkflow?.name ?? '',
            );
            return StatefulBuilder(
              builder: (context, setStateDialog) {
                final nameText = nameCtrl.text.trim();
                final isSubmitEnabled =
                    nameText.isNotEmpty && (saveAsWorkflow || saveAsSkill);
                return AlertDialog(
                  title: const Text('Save Skill / Workflow'),
                  content: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Name of the skill:'),
                        const SizedBox(height: 6),
                        TextField(
                          controller: nameCtrl,
                          autofocus: true,
                          maxLength: 60,
                          decoration: const InputDecoration(
                            hintText: 'e.g. Research assistant',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          onChanged: (_) {
                            setStateDialog(() {});
                          },
                        ),
                        const SizedBox(height: 12),
                        CheckboxListTile(
                          title: const Text('Save as workflow'),
                          value: saveAsWorkflow,
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          onChanged: (val) {
                            setStateDialog(() {
                              saveAsWorkflow = val ?? false;
                            });
                          },
                        ),
                        CheckboxListTile(
                          title: const Text('Save as skill (create ZIP)'),
                          value: saveAsSkill,
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          onChanged: (val) {
                            setStateDialog(() {
                              saveAsSkill = val ?? false;
                            });
                          },
                        ),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: isSubmitEnabled
                          ? () => Navigator.pop(ctx, (
                              name: nameCtrl.text.trim(),
                              saveAsWorkflow: saveAsWorkflow,
                              saveAsSkill: saveAsSkill,
                            ))
                          : null,
                      child: const Text('Save'),
                    ),
                  ],
                );
              },
            );
          },
        );

    if (result == null || !mounted) return;

    // Build InternalMcpEntry list from playground tool selection + init params.
    final internalMcps = _selectedMcpTypes.map((type) {
      final params = Map<String, dynamic>.from(
        _mcpInitParams[type] ?? const <String, dynamic>{},
      );
      return InternalMcpEntry(
        id: const Uuid().v4(),
        mcpType: type,
        initParams: params,
        enabled: true,
      );
    }).toList();
    if (!_pgToolboxEnabled) {
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

    // Build McpToolConfig list from selected external server URLs.
    final allServers = ExternalToolsSettingsService.instance.selectedServers;
    final mcpTools = _selectedExternalServerUrls.map((url) {
      return allServers.firstWhere(
        (s) => s.serverUrl == url,
        orElse: () => McpToolConfig(serverUrl: url),
      );
    }).toList();

    // Map playground LLM Settings into TaskLlmConfig
    TaskLlmConfig? llmConfig;
    if (_overrideLlm) {
      llmConfig = TaskLlmConfig(
        provider: _llmProviderCtrl.text.trim(),
        model: _llmModelCtrl.text.trim(),
        apiKey: _llmApiKeyCtrl.text.isNotEmpty ? _llmApiKeyCtrl.text : null,
        baseUrl: _llmBaseUrlCtrl.text.isNotEmpty ? _llmBaseUrlCtrl.text : null,
        temperature: double.tryParse(_playgroundTemperatureCtrl.text) ?? 0.7,
        maxTokens: int.tryParse(_playgroundMaxTokensCtrl.text) ?? 2000,
        extraParams: {
          'max_tool_output_size':
              int.tryParse(_playgroundMaxToolOutputSizeCtrl.text) ?? 2560000,
          'token_warning_threshold':
              int.tryParse(_playgroundTokenWarningThresholdCtrl.text) ??
              1500000,
          'use_native_tool_call': _customUseNativeToolCall,
          'is_slm': _customIsSlm,
          'is_multi_modal': _customIsMultiModal,
          'thinking': _customThinking,
        },
      );
    } else if (_selectedLlm == 2) {
      llmConfig = const TaskLlmConfig(provider: 'llm2', model: 'coding-model');
    }

    final String agentId = const Uuid().v4();
    final agent = Agent(
      id: agentId,
      name: result.name,
      prompt: initialPrompt,
      systemPrompt: _combinedSystemPrompt.trim().isNotEmpty
          ? _combinedSystemPrompt.trim()
          : null,
      llmConfig: llmConfig,
      mcpTools: mcpTools,
      internalMcps: internalMcps,
      chatMode: _chatMode,
      stopAfterToolCall: _stopAfterToolCall,
    );

    final workflow = WorkflowTask(
      id: const Uuid().v4(),
      name: result.name,
      systemPrompt: _combinedSystemPrompt.trim().isNotEmpty
          ? _combinedSystemPrompt.trim()
          : null,
      prompt: initialPrompt,
      executionPlan: const ExecutionPlan(cronExpression: '0 8 * * *'),
      internalMcps: internalMcps,
      mcpTools: mcpTools,
      llmConfig: llmConfig,
      chatMode: _chatMode,
      stopAfterToolCall: _stopAfterToolCall,
      agents: [agent],
    );

    if (result.saveAsSkill) {
      final exportResult = await WorkflowExportService.exportWorkflow(
        context,
        workflow,
        forceZip: true,
      );
      if (mounted) {
        if (exportResult.error != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to export skill: ${exportResult.error}'),
              backgroundColor: Colors.red,
              behavior: SnackBarBehavior.floating,
            ),
          );
        } else if (exportResult.savedPath != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Skill exported to: ${exportResult.savedPath}'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    }

    if (result.saveAsWorkflow) {
      await ref.read(taskListProvider.notifier).saveTask(workflow);
      setState(() {
        _activeLoadedWorkflow = workflow;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Workflow "${workflow.name}" saved successfully.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        // Open the workflow editor
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => WorkflowEditScreen(task: workflow)),
        );
      }
    }
  }

  // ── Load Workflows ──

  Future<void> _showSetupSessionsDialog() async {
    // Make sure we have the latest task list loaded
    await ref.read(taskListProvider.notifier).refresh();
    if (!mounted) return;

    final WorkflowTask? selectedWorkflow = await showDialog<WorkflowTask>(
      context: context,
      builder: (ctx) => const _LoadWorkflowsDialog(),
    );

    if (selectedWorkflow != null && mounted) {
      await _initFromTask(selectedWorkflow);
      await _updateSkillsSection();
    }
  }

  // ── Skill Wizard ──

  Future<void> _showSkillsPicker() async {
    final selected = await SkillsListScreen.showPicker(context);
    if (selected != null && mounted) {
      _applySkillDef(selected);
    }
  }

  (Set<String>, Set<String>) _partitionTools(List<String> toolNames) {
    final mcpTypes = <String>{};
    final externalUrls = <String>{};
    final configuredUrls = ExternalToolsSettingsService.instance.selectedServers
        .map((s) => s.serverUrl)
        .toSet();
    for (final name in toolNames) {
      if (name.startsWith('http://') ||
          name.startsWith('https://') ||
          configuredUrls.contains(name)) {
        externalUrls.add(name);
      } else {
        mcpTypes.add(name);
      }
    }
    return (mcpTypes, externalUrls);
  }

  void _applySkillDef(SkillDef skill) {
    final (mcpTypes, externalUrls) = _partitionTools(skill.toolNames);
    setState(() {
      _activeSkill = SkillWizardResult(
        name: skill.name,
        goal: skill.goal,
        description: skill.description,
        skillContent: skill.skillDef,
        selectedMcpTypes: mcpTypes,
        selectedExternalServerUrls: externalUrls,
        toolboxEnabled: true,
      );

      if (mcpTypes.isNotEmpty) {
        _selectedMcpTypes = mcpTypes;
      }
      if (externalUrls.isNotEmpty) {
        _selectedExternalServerUrls = externalUrls;
      }
    });
    _updateSkillsSection();
  }

  Future<void> _showSkillWizardDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => SkillWizardDialog(
        prefillName: _activeSkill?.name,
        prefillGoal: _activeSkill?.goal,
        prefillSkill: _activeSkill?.skillContent,
        prefillMcpTypes: _activeSkill?.selectedMcpTypes,
        prefillExternalUrls: _activeSkill?.selectedExternalServerUrls,
        prefillToolboxEnabled: _activeSkill?.toolboxEnabled ?? true,
        onApply: (result) => _applySkillFromWizard(result),
      ),
    );
  }

  void _applySkillFromWizard(SkillWizardResult result) {
    // Store skill state — do NOT modify prompt/system prompt directly.
    // Instead, show a chip above the prompt.
    setState(() {
      _activeSkill = result;

      // Set tools from the skill
      if (result.selectedMcpTypes.isNotEmpty) {
        _selectedMcpTypes = Set<String>.from(result.selectedMcpTypes);
      }
      if (result.selectedExternalServerUrls.isNotEmpty) {
        _selectedExternalServerUrls = Set<String>.from(
          result.selectedExternalServerUrls,
        );
      }
      _pgToolboxEnabled = result.toolboxEnabled;
    });

    // Refresh skills section
    _updateSkillsSection();
  }

  // ── Chat subscription ──

  void _subscribeToChatService(ChatService chatService) {
    // Guard by instance — re-subscribe if the chatService has changed (e.g. after task
    // editor interactive mode creates a new ChatService on the shared provider).
    if (_subscribedChatService == chatService) return;
    _messagesSubscription?.cancel();
    _errorSubscription?.cancel();
    _subscribedChatService = chatService;

    _messagesSubscription = chatService.messagesStream.listen((msgs) {
      if (mounted) {
        setState(
          () => _messages
            ..clear()
            ..addAll(msgs),
        );
      }
    });
    _errorSubscription = chatService.errorNotificationStream.listen((err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(err), backgroundColor: AppTheme.error),
        );
      }
    });
  }

  void _onSendMessage(ChatMessage message, ChatService chatService) async {
    final ready = await _ensureDocumentIndexReadyBeforeSend();
    if (!ready || !mounted) return;
    chatService.sendChatMessage(message);
  }

  Future<bool> _ensureDocumentIndexReadyBeforeSend() async {
    if (!_selectedMcpTypes.contains('document')) return true;

    final rawParams = _mcpInitParams['document'] ?? const <String, dynamic>{};
    final params = <String, dynamic>{...rawParams};
    final rootPath = (params['rootPath'] as String? ?? '').trim();
    final indexingStrategy =
        (params['indexingStrategy'] as String? ?? 'before_first_run').trim();

    if (rootPath.isEmpty || indexingStrategy != 'before_first_run') return true;

    try {
      final probe = DocumentMcpServer();
      await probe.initialize(params);
      final alreadyIndexed = probe.isIndexed;
      await probe.dispose();
      if (alreadyIndexed) return true;
    } catch (_) {
      // Fall back to the existing lazy behavior if the probe fails.
      return true;
    }

    return _runDocumentIndexWithProgressDialog();
  }

  Future<bool> _runDocumentIndexWithProgressDialog() async {
    if (!mounted) return false;

    var dialogOpen = true;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          final l = L.of(ctx);
          final theme = Theme.of(ctx);
          return PopScope(
            canPop: false,
            child: AlertDialog(
              title: Row(
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Text(l.reindexing),
                ],
              ),
              content: StreamBuilder<int>(
                stream: Stream<int>.periodic(
                  const Duration(milliseconds: 150),
                  (tick) => tick,
                ),
                builder: (context, snapshot) {
                  final progress = _indexTotal > 0
                      ? (_indexedCount / _indexTotal).clamp(0.0, 1.0)
                      : null;
                  final current = _indexCurrentFile.trim();

                  return SizedBox(
                    width: 320,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        LinearProgressIndicator(value: progress),
                        const SizedBox(height: 10),
                        Text(
                          _indexTotal > 0
                              ? l.indexingProgress(_indexedCount, _indexTotal)
                              : l.reindexing,
                          style: theme.textTheme.bodySmall,
                        ),
                        if (current.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            current.split(Platform.pathSeparator).last,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
              actions: [
                TextButton.icon(
                  onPressed: () => _activeIndexServer?.cancelIndexing(),
                  icon: const Icon(Icons.stop, size: 16),
                  label: Text(l.indexingStop),
                ),
              ],
            ),
          );
        },
      ).then((_) {
        dialogOpen = false;
      }),
    );

    await Future<void>.delayed(Duration.zero);
    final success = await _doDocumentIndex();

    if (mounted && dialogOpen) {
      Navigator.of(context, rootNavigator: true).pop();
      dialogOpen = false;
    }
    return success;
  }

  // ── Generate system prompt via LLM ──

  // ── Skills-section helpers (Playground) ───────────────────────────────────

  /// Rebuilds the skills controller from the currently selected tools.
  /// [sourceText] overrides the prompt text used to extract per-step tool
  /// filters — defaults to [_initialPromptCtrl.text] (setup screen path).
  /// Pass [_chatInputController.text] when called from the active chat view.
  Future<void> _updateSkillsSection([String? sourceText]) async {
    if (!mounted) return;
    final generation = ++_skillsUpdateGeneration;
    // Clear immediately so stale skills are never shown while regenerating.
    setState(() => _systemPromptSkillsCtrl.text = '');
    final enabledFilter = _enabledToolNamesFromPrompt(
      sourceText ?? _initialPromptCtrl.text,
    );
    final skills = await _buildSkillsBlock(enabledFilter: enabledFilter);
    // Discard stale results from concurrent calls.
    if (!mounted || generation != _skillsUpdateGeneration) return;
    setState(() {
      _systemPromptSkillsCtrl.text = skills;
    });
  }

  /// Returns the union of per-step enabled tool names serialised in [promptText].
  /// Returns null when every step allows all tools (no restriction), meaning
  /// all available tools should be included.
  /// Steps with no explicit restriction (null) are skipped so that explicitly
  /// restricted steps still filter the skills block.
  Set<String>? _enabledToolNamesFromPrompt(String promptText) {
    final steps = parseWorkflowSteps(promptText);
    if (steps.every((s) => s.enabledToolNames == null)) return null;
    final union = <String>{};
    for (final step in steps) {
      if (step.enabledToolNames == null) {
        continue; // all-tools step: don't restrict union
      }
      union.addAll(step.enabledToolNames!);
    }
    return union;
  }

  /// Returns true when the currently effective LLM is a small/embedded model.
  bool _isEffectiveSlm() {
    if (_overrideLlm) {
      if (_llmProviderCtrl.text.toLowerCase() == 'embedded') return true;
      if (_customIsSlm) return true;
      if (_llmModelCtrl.text.isNotEmpty) {
        return _isSmallModelByName(_llmModelCtrl.text);
      }
    }
    if (_selectedLlm == 2) {
      final s = ref.read(llmSettingsProvider);
      return s.isSlm2 || _isSmallModelByName(s.model2);
    }
    final taskState = ref.read(activeTaskProvider);
    final chatService = taskState?.chatService;
    if (chatService != null && chatService.llmService.isConfigured) {
      return chatService.llmService.isSlm;
    }
    return ref.read(llmSettingsProvider).isSlm;
  }

  static bool _isSmallModelByName(String model) {
    final m = model.toLowerCase();
    final match = RegExp(
      r'(?:^|[:\-_.])([0-9]+\.?[0-9]*)b(?:\b|[-_])',
    ).firstMatch(m);
    if (match != null) {
      final params = double.tryParse(match.group(1)!);
      if (params != null && params <= 14) return true;
    }
    return m.contains('phi') ||
        m.contains('tiny') ||
        m.contains('nano') ||
        m.contains(':mini') ||
        m.contains('-mini') ||
        m.contains('tinyllama');
  }

  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _generateSystemPrompt() async {
    final subject = _subjectCtrl.text.trim();
    if (subject.isEmpty) return;

    // If the user already has a base prompt, only refresh the skills section.
    final existingBase = _systemPromptUserCtrl.text.trimRight();
    if (existingBase.isNotEmpty) {
      await _updateSkillsSection();
      return;
    }

    // Split subject on inline ++#++ separator to support per-sub-prompt system prompts.
    final subjectParts = subject
        .split('++#++')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final isMultiPart = subjectParts.length > 1;

    String fallback(String s) =>
        'You are a helpful AI assistant specialized in $s. '
        'Provide accurate, concise answers. Use available tools when relevant.';

    final llmSettings = ref.read(llmSettingsProvider);
    if (!llmSettings.isConfigured) {
      setState(() {
        _systemPromptUserCtrl.text = subjectParts
            .map(fallback)
            .join('\n++#++\n');
      });
      return;
    }

    setState(() => _isGenerating = true);

    try {
      // Use the active task's LLM when available
      final taskState = ref.read(activeTaskProvider);
      final chatService = taskState?.chatService;

      final generatedParts = <String>[];

      for (final part in subjectParts) {
        var generated = fallback(part);

        if (chatService != null && chatService.llmService.isConfigured) {
          final isSlm = chatService.llmService.isSlm;
          final slmConstraint = isSlm
              ? 'IMPORTANT: The target is a small language model (SLM) with limited context. '
                    'Generate an ULTRA-SHORT system prompt: max 2 sentences, under 60 words. '
                    'Use dense, compressed language — no filler, no pleasantries, no repetition.\n'
              : '';
          // For multi-part subjects each section should be a short focused prompt.
          final lengthConstraint = isMultiPart
              ? 'Generate a SHORT, focused system prompt (1-3 sentences) '
              : 'Generate a concise system prompt ';
          final activeLlm = chatService.llmService;
          final metaPrompt =
              '$slmConstraint${lengthConstraint}for the following subject: "$part". '
              'The selected LLM is ${activeLlm.currentProvider.name} / ${activeLlm.currentModel}. '
              'Return ONLY the system prompt text, nothing else.';

          final response = await chatService.llmService.generateChatCompletion(
            messages: [
              ChatMessage(
                id: const Uuid().v4(),
                role: ChatRole.system,
                content:
                    'You generate high-quality system prompts. Output plain prompt text only.',
                timestamp: DateTime.now(),
              ),
              ChatMessage(
                id: const Uuid().v4(),
                role: ChatRole.user,
                content: metaPrompt,
                timestamp: DateTime.now(),
              ),
            ],
          );

          final cleaned = _cleanGeneratedPrompt(response.content);
          if (cleaned.isNotEmpty) generated = cleaned;
        }

        generatedParts.add(generated);
      }

      if (!mounted) return;

      // Set the generated base text, then rebuild the skills section.
      setState(() {
        _systemPromptUserCtrl.text = generatedParts.join('\n++#++\n');
      });
      await _updateSkillsSection();
    } catch (_) {
      if (!mounted) return;
      final fallbackText = subjectParts.map(fallback).join('\n++#++\n');
      setState(() => _systemPromptUserCtrl.text = fallbackText);
      await _updateSkillsSection().catchError((_) {});
    } finally {
      if (mounted) setState(() => _isGenerating = false);
    }
  }

  /// Fetches enabled skills from the DB for all currently selected tools
  /// and formats them as a compact guidance block.
  /// [enabledFilter]: when non-null, only tools in this set are included.
  Future<String> _buildSkillsBlock({Set<String>? enabledFilter}) async {
    // Collect all tool names from selected internal MCPs and external servers.
    final toolNames = <String>[];
    // Toolbox is always-on in playground (matches _availableToolGroupsForSteps).
    if (_pgToolboxEnabled) {
      final toolbox = InternalMcpRegistry().create('toolbox');
      if (toolbox != null) toolNames.addAll(toolbox.tools.map((t) => t.name));
    }
    // Other selected internal MCPs — skip 'toolbox' to avoid duplicates when it
    // also appears in _selectedMcpTypes (e.g. loaded from a saved task).
    for (final type in _selectedMcpTypes.where((t) => t != 'toolbox')) {
      final server = InternalMcpRegistry().create(type);
      if (server != null) toolNames.addAll(server.tools.map((t) => t.name));
    }
    final allExtServers = ExternalToolsSettingsService.instance.selectedServers;
    for (final url in _selectedExternalServerUrls) {
      final s = allExtServers.firstWhere(
        (s) => s.serverUrl == url,
        orElse: () => McpToolConfig(serverUrl: url),
      );
      toolNames.addAll(s.discoveredTools);
    }
    if (toolNames.isEmpty) return '';

    // Apply per-step filter: only keep tools that are enabled in the prompt.
    final filtered = enabledFilter != null
        ? toolNames.where((t) => enabledFilter.contains(t)).toList()
        : toolNames;
    if (filtered.isEmpty) return '';

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
    if (!_skillsWarningShown && filtered.isNotEmpty) {
      final missing = filtered
          .where((t) => !skills.any((s) => s.toolName == t))
          .toList();
      if (missing.isNotEmpty) {
        _skillsWarningShown = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _showMissingSkillsWarning(missing);
        });
      }
    }
    if (skills.isEmpty) return '';

    final isSlm = _isEffectiveSlm();

    // SLMs have very limited context windows. Use compact SLM skill variants
    // instead of the full descriptions to save space.
    final buffer = StringBuffer();
    buffer.writeln('Tool Hints:');
    for (final skill in skills) {
      final text = isSlm ? skill.skillTextSlm : skill.skillText;
      if (text.trim().isNotEmpty) {
        buffer.writeln('• ${skill.toolName}: ${text.trim()}');
      }
    }
    return buffer.toString().trim();
  }

  void _showMissingSkillsWarning(List<String> missingTools) {
    if (!mounted) return;
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Missing Tool Hints'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              missingTools.length == 1
                  ? 'No skill found for 1 tool:'
                  : 'No skills found for ${missingTools.length} tools:',
            ),
            const SizedBox(height: 8),
            Text(
              missingTools.take(6).join('\n') +
                  (missingTools.length > 6 ? '\n…' : ''),
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            const Text(
              'Skills help the AI understand how to use tools effectively.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Dismiss'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Generate'),
          ),
        ],
      ),
    ).then((generate) {
      if (generate == true && mounted) {
        FunctionHintsScreen.show(context, autoRebuild: true);
      }
    });
  }

  /// Builds the read-only (but manually editable) skills textbox shown below
  /// the user prompt. Always visible so users know where auto-skills appear.
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

  String _cleanGeneratedPrompt(String raw) {
    var text = raw.trim();
    if (text.startsWith('```')) {
      text = text.replaceFirst(RegExp(r'^```[a-zA-Z]*\s*'), '');
      text = text.replaceFirst(RegExp(r'\s*```$'), '');
      text = text.trim();
    }
    if ((text.startsWith('"') && text.endsWith('"')) ||
        (text.startsWith('\'') && text.endsWith('\''))) {
      text = text.substring(1, text.length - 1).trim();
    }
    return text;
  }

  // ── Tool selection dialog ──

  Future<void> _showToolSelectionDialog() async {
    final l = L.of(context);
    final isServerMode = ref.read(serverModeProvider).value?.isRemote ?? false;
    var tempSelection = Set<String>.from(_selectedMcpTypes);
    var tempExternalSelection = Set<String>.from(_selectedExternalServerUrls);
    var tempToolboxEnabled = _pgToolboxEnabled;

    final globalServers = ExternalToolsSettingsService.instance.selectedServers;
    final Map<String, McpToolConfig> combinedServers = {};
    for (final s in globalServers) {
      combinedServers[s.serverUrl] = s;
    }
    for (final url in _selectedExternalServerUrls) {
      if (!combinedServers.containsKey(url)) {
        combinedServers[url] = McpToolConfig(
          serverUrl: url,
          name: Uri.tryParse(url)?.host ?? url,
        );
      }
    }

    final ghServers = await _getSelectableGithubMcpServers(isServerMode);
    final Map<String, GithubMcpServerDefinition> combinedGhServers = {};
    for (final s in ghServers) {
      combinedGhServers[s.id] = s;
    }
    for (final type in _selectedMcpTypes) {
      if (type.startsWith('gh_mcp_')) {
        final serverId = type.substring('gh_mcp_'.length);
        if (!combinedGhServers.containsKey(serverId)) {
          final def = _findGithubMcpById(serverId);
          combinedGhServers[serverId] =
              def ??
              GithubMcpServerDefinition(
                id: serverId,
                name: 'Remote MCP ($serverId)',
                displayName: 'Remote MCP ($serverId)',
                description: 'Remote GitHub MCP server',
                githubUrl: '',
                language: 'python',
                installType: 'uvx',
                packageName: '',
                createdAt: DateTime.now(),
                isInstalled: true,
                isActive: true,
              );
        }
      }
    }

    showDialog<(Set<String>, Set<String>, bool)>(
      context: context,
      builder: (ctx) {
        final screenSize = MediaQuery.of(ctx).size;
        final isMobile = screenSize.width < 600;

        return StatefulBuilder(
          builder: (ctx, setDialogState) => Dialog(
            insetPadding: isMobile
                ? EdgeInsets.zero
                : const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
            clipBehavior: Clip.antiAlias,
            shape: isMobile
                ? const RoundedRectangleBorder()
                : RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(28),
                  ),
            child: SizedBox(
              width: isMobile ? screenSize.width : 400,
              height: isMobile ? screenSize.height : null,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: isMobile ? MainAxisSize.max : MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.selectTools,
                      style: Theme.of(ctx).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 16),
                    Flexible(
                      child: ListView(
                        shrinkWrap: !isMobile,
                        children: [
                          // ── Built-in tools section ──
                          _dialogSectionHeader(
                            ctx,
                            l.toolSelectionBuiltIn,
                            Icons.extension,
                            AppTheme.primaryBlue,
                          ),
                          // ── Toolbox (first item, always-on by default) ──
                          Card(
                            margin: const EdgeInsets.only(bottom: 4),
                            color: AppTheme.primaryBlue.withAlpha(18),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: CheckboxListTile(
                              secondary: Icon(
                                Icons.handyman_outlined,
                                color: tempToolboxEnabled
                                    ? AppTheme.primaryBlue
                                    : Colors.grey,
                              ),
                              title: Text(
                                'Toolbox',
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: tempToolboxEnabled
                                      ? null
                                      : Colors.grey,
                                ),
                              ),
                              subtitle: Text(
                                'Time, location, geocoding, calculator',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey[500],
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              value: tempToolboxEnabled,
                              activeColor: AppTheme.primaryBlue,
                              onChanged: (v) => setDialogState(
                                () => tempToolboxEnabled = v ?? true,
                              ),
                            ),
                          ),
                          ..._availableMcpInfosForMode(isServerMode).map((
                            info,
                          ) {
                            return CheckboxListTile(
                              title: Text(info.displayName),
                              subtitle: Text(
                                info.description,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey[500],
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              value: tempSelection.contains(info.type),
                              onChanged: (v) => setDialogState(() {
                                if (v == true) {
                                  tempSelection.add(info.type);
                                } else {
                                  tempSelection.remove(info.type);
                                }
                              }),
                              secondary: null,
                            );
                          }),
                          // ── External MCP servers section ──
                          if (combinedServers.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            _dialogSectionHeader(
                              ctx,
                              l.toolSelectionExternal,
                              Icons.dns,
                              Colors.orange,
                            ),
                            ...combinedServers.values.map((server) {
                              return CheckboxListTile(
                                title: Text(
                                  server.name ?? server.serverUrl,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                subtitle: Text(
                                  server.serverUrl,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey[500],
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                value: tempExternalSelection.contains(
                                  server.serverUrl,
                                ),
                                activeColor: Colors.orange,
                                checkColor: Colors.white,
                                onChanged: (v) {
                                  if (v == true &&
                                      !tempExternalSelection.contains(
                                        server.serverUrl,
                                      ) &&
                                      tempExternalSelection.length >=
                                          _externalServerSelectionLimit) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          'External MCP limit reached ($_externalServerSelectionLimit).',
                                        ),
                                        backgroundColor: AppTheme.error,
                                      ),
                                    );
                                    return;
                                  }

                                  setDialogState(() {
                                    if (v == true) {
                                      tempExternalSelection.add(
                                        server.serverUrl,
                                      );
                                    } else {
                                      tempExternalSelection.remove(
                                        server.serverUrl,
                                      );
                                    }
                                  });
                                },
                                secondary: const Icon(
                                  Icons.dns,
                                  size: 20,
                                  color: Colors.orange,
                                ),
                              );
                            }),
                          ],
                          // ── Installed GitHub MCP servers section ──
                          ...() {
                            if (combinedGhServers.isEmpty) return <Widget>[];
                            return <Widget>[
                              const SizedBox(height: 8),
                              _dialogSectionHeader(
                                ctx,
                                'Installed MCP Servers',
                                Icons.hub_outlined,
                                Colors.teal,
                              ),
                              ...combinedGhServers.values.map((def) {
                                final key = 'gh_mcp_${def.id}';
                                return CheckboxListTile(
                                  title: Text(
                                    def.displayName,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  subtitle: Text(
                                    def.description,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey[500],
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  value: tempSelection.contains(key),
                                  activeColor: Colors.teal,
                                  checkColor: Colors.white,
                                  onChanged: (v) => setDialogState(() {
                                    if (v == true) {
                                      tempSelection.add(key);
                                    } else {
                                      tempSelection.remove(key);
                                    }
                                  }),
                                  secondary: const Icon(
                                    Icons.hub_outlined,
                                    size: 20,
                                    color: Colors.teal,
                                  ),
                                );
                              }),
                            ];
                          }(),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: Text(l.cancel),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () => Navigator.pop(ctx, (
                            tempSelection,
                            tempExternalSelection,
                            tempToolboxEnabled,
                          )),
                          child: const Text('OK'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    ).then((result) async {
      if (result != null && mounted) {
        // Capture old selection before applying changes.
        final oldMcpTypes = Set<String>.from(_selectedMcpTypes);
        final oldExtUrls = Set<String>.from(_selectedExternalServerUrls);
        final oldToolbox = _pgToolboxEnabled;
        setState(() {
          _selectedMcpTypes = result.$1.where((t) => t != 'traffic').toSet();
          _selectedExternalServerUrls = result.$2;
          _pgToolboxEnabled = result.$3;
        });
        // Only react when the selection actually changed — prevents the skills
        // section from being silently refreshed when the user opens and closes
        // the dialog without making any changes (e.g. after a chat has run).
        final selectionChanged =
            _selectedMcpTypes.length != oldMcpTypes.length ||
            !_selectedMcpTypes.containsAll(oldMcpTypes) ||
            _selectedExternalServerUrls.length != oldExtUrls.length ||
            !_selectedExternalServerUrls.containsAll(oldExtUrls) ||
            _pgToolboxEnabled != oldToolbox;
        if (_pgGenerateOnToolSelect && selectionChanged) {
          await _eagerDiscoverSelectedRemoteMcpTools();
          final hasTools =
              _selectedMcpTypes.isNotEmpty ||
              _selectedExternalServerUrls.isNotEmpty;
          final base = _systemPromptUserCtrl.text.trimRight();
          if (base.isNotEmpty || !hasTools || _activeLoadedWorkflow != null) {
            // Base exists, all tools removed, or a workflow is loaded → only refresh skills section.
            _updateSkillsSection();
          } else if (hasTools) {
            // No base yet → auto-populate subject and generate a full prompt.
            final internalNames = _selectedMcpTypes.map(
              (t) => _mcpTypeLabel(t),
            );
            final allExtServers =
                ExternalToolsSettingsService.instance.selectedServers;
            final externalNames = _selectedExternalServerUrls.map((url) {
              final s = allExtServers.firstWhere(
                (s) => s.serverUrl == url,
                orElse: () => McpToolConfig(serverUrl: url),
              );
              return s.name ?? url;
            });
            final allNames = [...internalNames, ...externalNames];
            if (_subjectCtrl.text.trim().isEmpty && allNames.isNotEmpty) {
              _subjectCtrl.text = '${allNames.join(', ')} assistant';
            }
            _generateSystemPrompt();
          }
        }
      }
    });
  }

  Widget _dialogSectionHeader(
    BuildContext ctx,
    String label,
    IconData icon,
    Color color,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 2),
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: color,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }

  List<ToolGroup> get _availableToolGroupsForSteps {
    final groups = <ToolGroup>[];
    // Toolbox is always-on in playground (unless disabled)
    if (_pgToolboxEnabled) {
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
    // Active MCP manager from the current (or last) session — used to look up
    // gh_mcp_ tool names even when _chatStarted is false (e.g. after a reset).
    final activeMgr = ref.read(activeTaskProvider)?.mcpManager;
    for (final type in _selectedMcpTypes) {
      if (type.startsWith('gh_mcp_')) {
        // gh_mcp_ servers discover tools at runtime via an external process.
        // We can't get tool names from a fresh (uninitialized) server instance,
        // so fall back to the active session's MCP manager when available.
        final serverId = type.substring('gh_mcp_'.length);
        List<String> toolNames = const [];
        if (activeMgr != null) {
          final clientDef = activeMgr.clients
              .where(
                (c) =>
                    c.name == 'internal_$type' || c.name == 'remote_$serverId',
              )
              .firstOrNull;
          if (clientDef != null) {
            toolNames = clientDef.availableTools.map((t) => t.name).toList();
          }
        }
        if (toolNames.isEmpty) {
          toolNames = _prefetchedRemoteMcpTools[serverId] ?? const [];
        }
        // Always include the group (like external servers) so the per-step
        // toolbox icon is visible even before the server has finished init.
        final def = _findGithubMcpById(serverId);
        groups.add(
          ToolGroup(
            name: def?.displayName ?? _mcpTypeLabel(type),
            toolNames: toolNames,
          ),
        );
        continue;
      }
      final server = InternalMcpRegistry().create(type);
      if (server != null && server.tools.isNotEmpty) {
        groups.add(
          ToolGroup(
            name: _mcpTypeLabel(type),
            toolNames: server.tools.map((t) => t.name).toList(),
          ),
        );
      }
    }
    final allServers = ExternalToolsSettingsService.instance.selectedServers;
    for (final url in _selectedExternalServerUrls) {
      final s = allServers.firstWhere(
        (s) => s.serverUrl == url,
        orElse: () => McpToolConfig(serverUrl: url),
      );
      List<String> names = const [];
      if (activeMgr != null) {
        final clientDef = activeMgr.clients
            .where((c) => c.name == (s.name ?? Uri.parse(url).host))
            .firstOrNull;
        if (clientDef != null) {
          names = clientDef.availableTools.map((t) => t.name).toList();
        }
      }
      if (names.isEmpty) {
        names = s.discoveredTools.isNotEmpty
            ? s.discoveredTools
            : (_prefetchedRemoteMcpTools[url] ?? const <String>[]);
      }
      // Include the group even when tools haven't been discovered yet (server not connected).
      // This ensures the per-step tool icon is always visible when a server is selected.
      groups.add(ToolGroup(name: s.name ?? url, toolNames: names));
    }
    return groups;
  }

  String _mcpTypeLabel(String type) {
    if (type.startsWith('gh_mcp_')) {
      final id = type.substring('gh_mcp_'.length);
      final def = _findGithubMcpById(id);
      if (def != null) return def.displayName;
    }
    return switch (type) {
      'chart' => 'Chart generator',
      'pdf' => 'Pdf generator',
      'mermaid' => 'Mermaid diagram',
      'js_bridge' => 'JavaScript bridge',
      'py_bridge' => 'Python tools',
      'ps_bridge' => 'PowerShell tools',
      'ssh' => 'SSH / Shell',
      'file' => 'File output',
      'weather' => 'Weather',
      'document' => 'Document Search',
      'gmail' => 'Gmail',
      'website_search' => 'Website Search',
      'web_search' => 'Web Search',
      'google_drive' => 'Google Drive',
      'onedrive' => 'OneDrive',
      _ => type,
    };
  }

  GithubMcpServerDefinition? _findGithubMcpById(String id) {
    for (final def in _remoteGithubMcpServers) {
      if (def.id == id) return def;
    }
    return GithubMcpLibraryService.instance.findById(id);
  }

  Future<List<GithubMcpServerDefinition>> _getSelectableGithubMcpServers(
    bool isServerMode,
  ) async {
    if (!isServerMode) {
      _remoteGithubMcpServers = const [];
      return _dedupeGithubMcpServers(
        GithubMcpLibraryService.instance.activeServers,
      );
    }

    final client = ref.read(serverApiClientProvider);
    if (client == null) return const [];

    try {
      final raw = await client.listRegistryServers();
      final defs = _dedupeGithubMcpServers(
        raw
            .map(GithubMcpServerDefinition.fromJson)
            .where((s) => s.isInstalled && s.isActive),
      );
      if (mounted) {
        setState(() {
          _remoteGithubMcpServers = defs;
        });
      }
      return defs;
    } catch (_) {
      return const [];
    }
  }

  List<GithubMcpServerDefinition> _dedupeGithubMcpServers(
    Iterable<GithubMcpServerDefinition> servers,
  ) {
    final seen = <String>{};
    final result = <GithubMcpServerDefinition>[];
    for (final s in servers) {
      final key = (s.packageName.isNotEmpty ? s.packageName : s.name)
          .toLowerCase();
      if (seen.add(key)) result.add(s);
    }
    return result;
  }

  List<InternalMcpInfo> _availableMcpInfosForMode(bool isServerMode) {
    final infos = List<InternalMcpInfo>.from(_availableMcpInfos);

    // In server mode, Python tools run on the remote server, so py_bridge
    // should be selectable even when the app itself runs on mobile.
    if (isServerMode && !infos.any((info) => info.type == 'py_bridge')) {
      final pyBridge = PyBridgeMcpServer();
      infos.add(
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

    final isLightMode = ref.read(serverModeProvider).value?.isLightMode == true;

    return infos.where((info) {
      // Any server mode: hide google services and pdf (not available on remote server)
      if (isServerMode) {
        if (info.type == 'gmail' ||
            info.type == 'google_calendar' ||
            info.type == 'google_drive' ||
            info.type == 'pdf' ||
            info.type == 'ps_bridge' ||
            info.type == 'chart') {
          return false;
        }
      }
      // Server light: additionally hide document, excel, website search
      if (isServerMode && isLightMode) {
        if (info.type == 'document' ||
            info.type == 'excel' ||
            info.type == 'website_search') {
          return false;
        }
      }
      return true;
    }).toList();
  }

  // ── Toolbox editor dialog (modify tools in active session) ──

  Future<void> _showToolboxEditorDialog() async {
    final l = L.of(context);
    final isServerMode = ref.read(serverModeProvider).value?.isRemote ?? false;
    var tempSelection = Set<String>.from(_selectedMcpTypes);
    var tempExternalSelection = Set<String>.from(_selectedExternalServerUrls);
    var tempToolboxEnabled = _pgToolboxEnabled;
    final externalServers =
        ExternalToolsSettingsService.instance.selectedServers;
    final ghServers = await _getSelectableGithubMcpServers(isServerMode);

    showDialog<(Set<String>, Set<String>, bool)>(
      context: context,
      builder: (ctx) {
        final screenSize = MediaQuery.of(ctx).size;
        final isMobile = screenSize.width < 600;

        return StatefulBuilder(
          builder: (ctx, setDialogState) => Dialog(
            insetPadding: isMobile
                ? EdgeInsets.zero
                : const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
            clipBehavior: Clip.antiAlias,
            shape: isMobile
                ? const RoundedRectangleBorder()
                : RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(28),
                  ),
            child: SizedBox(
              width: isMobile ? screenSize.width : 400,
              height: isMobile ? screenSize.height : null,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: isMobile ? MainAxisSize.max : MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.selectTools,
                      style: Theme.of(ctx).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l.toolboxChangesWarning,
                      style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                    ),
                    const SizedBox(height: 16),
                    Flexible(
                      child: ListView(
                        shrinkWrap: !isMobile,
                        children: [
                          // ── Built-in tools section ──
                          _dialogSectionHeader(
                            ctx,
                            l.toolSelectionBuiltIn,
                            Icons.extension,
                            AppTheme.primaryBlue,
                          ),
                          // ── Toolbox (first item, always-on by default) ──
                          Card(
                            margin: const EdgeInsets.only(bottom: 4),
                            color: AppTheme.primaryBlue.withAlpha(18),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: CheckboxListTile(
                              secondary: Icon(
                                Icons.handyman_outlined,
                                color: tempToolboxEnabled
                                    ? AppTheme.primaryBlue
                                    : Colors.grey,
                              ),
                              title: Text(
                                'Toolbox',
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: tempToolboxEnabled
                                      ? null
                                      : Colors.grey,
                                ),
                              ),
                              subtitle: Text(
                                'Time, location, geocoding, calculator',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey[500],
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              value: tempToolboxEnabled,
                              activeColor: AppTheme.primaryBlue,
                              onChanged: (v) => setDialogState(
                                () => tempToolboxEnabled = v ?? true,
                              ),
                            ),
                          ),
                          ..._availableMcpInfosForMode(isServerMode).map((
                            info,
                          ) {
                            return CheckboxListTile(
                              title: Text(info.displayName),
                              subtitle: Text(
                                info.description,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey[500],
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              value: tempSelection.contains(info.type),
                              onChanged: (v) => setDialogState(() {
                                if (v == true) {
                                  tempSelection.add(info.type);
                                } else {
                                  tempSelection.remove(info.type);
                                }
                              }),
                              secondary: null,
                            );
                          }),
                          // ── External MCP servers section ──
                          if (externalServers.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            _dialogSectionHeader(
                              ctx,
                              l.toolSelectionExternal,
                              Icons.dns,
                              Colors.orange,
                            ),
                            ...externalServers.map((server) {
                              return CheckboxListTile(
                                title: Text(
                                  server.name ?? server.serverUrl,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                subtitle: Text(
                                  server.serverUrl,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey[500],
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                value: tempExternalSelection.contains(
                                  server.serverUrl,
                                ),
                                activeColor: Colors.orange,
                                checkColor: Colors.white,
                                onChanged: (v) {
                                  if (v == true &&
                                      !tempExternalSelection.contains(
                                        server.serverUrl,
                                      ) &&
                                      tempExternalSelection.length >=
                                          _externalServerSelectionLimit) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          'External MCP limit reached ($_externalServerSelectionLimit).',
                                        ),
                                        backgroundColor: AppTheme.error,
                                      ),
                                    );
                                    return;
                                  }

                                  setDialogState(() {
                                    if (v == true) {
                                      tempExternalSelection.add(
                                        server.serverUrl,
                                      );
                                    } else {
                                      tempExternalSelection.remove(
                                        server.serverUrl,
                                      );
                                    }
                                  });
                                },
                                secondary: const Icon(
                                  Icons.dns,
                                  size: 20,
                                  color: Colors.orange,
                                ),
                              );
                            }),
                          ],
                          // ── Installed GitHub MCP servers section ──
                          ...() {
                            if (ghServers.isEmpty) return <Widget>[];
                            return <Widget>[
                              const SizedBox(height: 8),
                              _dialogSectionHeader(
                                ctx,
                                'Installed MCP Servers',
                                Icons.hub_outlined,
                                Colors.teal,
                              ),
                              ...ghServers.map((def) {
                                final key = 'gh_mcp_${def.id}';
                                return CheckboxListTile(
                                  title: Text(
                                    def.displayName,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  subtitle: Text(
                                    def.description,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey[500],
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  value: tempSelection.contains(key),
                                  activeColor: Colors.teal,
                                  checkColor: Colors.white,
                                  onChanged: (v) => setDialogState(() {
                                    if (v == true) {
                                      tempSelection.add(key);
                                    } else {
                                      tempSelection.remove(key);
                                    }
                                  }),
                                  secondary: const Icon(
                                    Icons.hub_outlined,
                                    size: 20,
                                    color: Colors.teal,
                                  ),
                                );
                              }),
                            ];
                          }(),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: Text(l.cancel),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () => Navigator.pop(ctx, (
                            tempSelection,
                            tempExternalSelection,
                            tempToolboxEnabled,
                          )),
                          child: Text(l.applyAndReset),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    ).then((result) async {
      if (result != null && mounted) {
        // Capture old selection before applying changes.
        final oldMcpTypes = Set<String>.from(_selectedMcpTypes);
        final oldExtUrls = Set<String>.from(_selectedExternalServerUrls);
        final oldToolbox = _pgToolboxEnabled;
        setState(() {
          _selectedMcpTypes = result.$1.where((t) => t != 'traffic').toSet();
          _selectedExternalServerUrls = result.$2;
          _pgToolboxEnabled = result.$3;
        });
        // Only reset/restart the chat when the selection actually changed.
        final selectionChanged =
            _selectedMcpTypes.length != oldMcpTypes.length ||
            !_selectedMcpTypes.containsAll(oldMcpTypes) ||
            _selectedExternalServerUrls.length != oldExtUrls.length ||
            !_selectedExternalServerUrls.containsAll(oldExtUrls) ||
            _pgToolboxEnabled != oldToolbox;
        if (selectionChanged) {
          await _eagerDiscoverSelectedRemoteMcpTools();
          await _updateSkillsSection();
          await _resetChat();
          await _startChat();
        }
      }
    });
  }

  // ── Show available tools from active task ──

  void _showActiveToolsDialog(ActiveTaskState taskState) {
    final l = L.of(context);
    final tools = List<MCPTool>.from(
      taskState.mcpManager?.availableTools ?? const <MCPTool>[],
    )..sort((a, b) => a.name.compareTo(b.name));

    showDialog<void>(
      context: context,
      builder: (ctx) {
        final screenSize = MediaQuery.of(ctx).size;
        final isMobile = screenSize.width < 600;

        return Dialog(
          insetPadding: isMobile
              ? EdgeInsets.zero
              : const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
          clipBehavior: Clip.antiAlias,
          shape: isMobile
              ? const RoundedRectangleBorder()
              : RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
          child: SizedBox(
            width: isMobile ? screenSize.width : 640,
            height: isMobile ? screenSize.height : null,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: isMobile ? MainAxisSize.max : MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.toolsSelected(tools.length),
                    style: Theme.of(ctx).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 16),
                  Flexible(
                    child: tools.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            child: Text(l.noToolsAvailable),
                          )
                        : ListView.separated(
                            shrinkWrap: !isMobile,
                            itemCount: tools.length,
                            separatorBuilder: (_, a) =>
                                const Divider(height: 16),
                            itemBuilder: (ctx2, index) {
                              final tool = tools[index];
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SelectableText(
                                    tool.name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 14,
                                    ),
                                  ),
                                  if ((tool.description ?? '')
                                      .trim()
                                      .isNotEmpty) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      tool.description!.trim(),
                                      style: Theme.of(ctx2).textTheme.bodySmall,
                                    ),
                                  ],
                                ],
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: Text(l.close),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ═══════════════════════════════════════════════════
  // BUILD
  // ═══════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final theme = Theme.of(context);
    final uiStyle = AppPreferencesService.instance.uiStyle;
    final isModern = uiStyle == 'modern';
    final taskState = ref.watch(activeTaskProvider);
    final isServerMode = ref.watch(serverModeProvider).value?.isRemote ?? false;
    final showScriptLibrary = _selectedMcpTypes.contains('ssh');
    final showJsToolLibrary = _selectedMcpTypes.contains('js_bridge');
    final showPyToolLibrary = _selectedMcpTypes.contains('py_bridge');
    final showPsToolLibrary =
        _selectedMcpTypes.contains('ps_bridge') && !isServerMode;

    // If the active task was cleared externally (e.g. WorkflowEditScreen's interactive mode
    // called clearTask()), and we had a chat running, reset back to the setup view rather
    // than showing a permanent spinner.  Use ref.listen so this fires on the transition,
    // not on every rebuild.
    ref.listen<ActiveTaskState?>(activeTaskProvider, (prev, next) {
      if (next == null && _chatStarted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          // Re-check in the callback: the state might have been immediately replaced by a
          // new setTask() call (e.g. playground re-initialising its own task).
          if (mounted && _chatStarted && ref.read(activeTaskProvider) == null) {
            _messagesSubscription?.cancel();
            _errorSubscription?.cancel();
            _subscribedChatService = null;
            setState(() {
              _chatStarted = false;
              _messages.clear();
            });
          }
        });
      }
    });

    // Subscribe to chat service when available
    if (taskState?.chatService != null) {
      _subscribeToChatService(taskState!.chatService!);
    }

    final mainContent = Scaffold(
      backgroundColor: isModern ? Colors.transparent : null,
      appBar: AppBar(
        backgroundColor: isModern ? Colors.transparent : null,
        elevation: 0,
        title: Text(
          _activeLoadedWorkflow != null
              ? '${l.playground} - ${_activeLoadedWorkflow!.name}'
              : l.playground,
        ),
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
          // Server mode cloud indicator — always visible when in remote mode
          Consumer(
            builder: (context, ref, _) {
              final serverState = ref.watch(serverModeProvider).value;
              if (serverState == null || !serverState.isRemote) {
                return const SizedBox.shrink();
              }
              return IconButton(
                icon: Icon(
                  serverState.isConnected ? Icons.cloud : Icons.cloud_outlined,
                ),
                tooltip: serverState.isConnected
                    ? 'Server connected: ${serverState.serverUrl}'
                    : 'Server mode — not connected',
                color: serverState.isConnected ? AppTheme.success : null,
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const StartupWizardScreen(),
                  ),
                ),
              );
            },
          ),
          ..._buildAppBarActions(
            context,
            l,
            taskState,
            showScriptLibrary,
            showJsToolLibrary,
            showPyToolLibrary,
            showPsToolLibrary,
          ),
          if (isModern && MediaQuery.sizeOf(context).width < 1000) ...[
            const GlobalAgentStatsWidget(),
            const SizedBox(width: 8),
          ],
        ],
      ),
      body: _chatStarted
          ? _buildChatView(theme, taskState)
          : _buildSetupView(theme),
    );

    if (isModern) {
      return ParticleBackground(child: mainContent);
    }
    return mainContent;
  }

  /// Builds the AppBar action list.
  /// On narrow screens (< 480 px) all but the two most-used icons are collapsed
  /// into a labelled overflow popup menu.
  List<Widget> _buildAppBarActions(
    BuildContext context,
    dynamic l,
    dynamic taskState,
    bool showScriptLibrary,
    bool showJsToolLibrary,
    bool showPyToolLibrary,
    bool showPsToolLibrary,
  ) {
    final isWide = MediaQuery.sizeOf(context).width >= 480;

    // ── Define all actions ────────────────────────────────────────────────
    // Each entry: (icon, label, onTap, [alwaysShow])
    // alwaysShow = pin to bar even on narrow screens
    final actions =
        <({IconData icon, String label, VoidCallback onTap, bool pin})>[
          (
            icon: Icons.build_outlined,
            label: l.selectTools,
            onTap: _chatStarted
                ? _showToolboxEditorDialog
                : _showToolSelectionDialog,
            pin: true, // always visible
          ),
          if (_chatStarted) ...[
            (
              icon: Icons.restart_alt,
              label: l.resetChat,
              onTap: _resetChat,
              pin: true, // always visible
            ),
          ] else ...[
            (
              icon: Icons.restart_alt,
              label: l.resetPlayground,
              onTap: _resetPlayground,
              pin: true, // always visible
            ),
          ],
          (
            icon: Icons.auto_awesome,
            label: 'Skills',
            onTap: _showSkillsPicker,
            pin: true,
          ),
          (
            icon: Icons.bookmarks_outlined,
            label: l.loadWorkflowsAndImportSkills,
            onTap: _showSetupSessionsDialog,
            pin: true,
          ),
          (
            icon: Icons.save_outlined,
            label: 'Save Skill / Workflow',
            onTap: _saveSetup,
            pin: false,
          ),
          (
            icon: Icons.settings,
            label: l.settings,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const StartupWizardScreen()),
            ),
            pin: false,
          ),
          if (showScriptLibrary)
            (
              icon: Icons.terminal,
              label: l.scriptLibraryTooltip,
              onTap: () async {
                final changed = await ScriptLibraryScreen.show(context);
                if (changed == true && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(l.scriptLibraryUpdated),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                }
              },
              pin: false,
            ),
          if (showJsToolLibrary)
            (
              icon: Icons.javascript,
              label: 'JS Tool Library',
              onTap: () async {
                final changed = await JsToolLibraryScreen.show(context);
                if (changed == true && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('JS tool library updated.'),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                }
              },
              pin: false,
            ),
          if (showPyToolLibrary)
            (
              icon: Icons.terminal,
              label: 'Python Tool Library',
              onTap: () async {
                final changed = await PyToolLibraryScreen.show(context);
                if (changed == true && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Python tool library updated.'),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                }
              },
              pin: false,
            ),
          if (showPsToolLibrary)
            (
              icon: Icons.terminal,
              label: 'PowerShell Tool Library',
              onTap: () async {
                final changed = await PowershellToolLibraryScreen.show(context);
                if (changed == true && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('PowerShell tool library updated.'),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                }
              },
              pin: false,
            ),
          if (showScriptLibrary && _chatStarted)
            (
              icon: Icons.folder_open,
              label: 'SFTP Explorer',
              onTap: () {
                final mgr = taskState?.mcpManager;
                if (mgr == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('SFTP not connected yet')),
                  );
                  return;
                }
                SftpExplorerDialog.show(
                  context,
                  mgr,
                  isServerMode:
                      ref.read(serverModeProvider).value?.isRemote ?? false,
                );
              },
              pin: false,
            ),
          if (_chatStarted &&
              (taskState?.mcpManager?.allAvailableTools.isNotEmpty ?? false))
            (
              icon: Icons.model_training,
              label: 'Export tool list for training',
              onTap: () {
                final mgr = taskState?.mcpManager;
                if (mgr == null) return;
                showDialog(
                  context: context,
                  builder: (_) => TrainingExportDialog(mcpManager: mgr),
                );
              },
              pin: false,
            ),
        ];

    if (isWide) {
      // All icons visible
      return actions
          .map(
            (a) => IconButton(
              icon: Icon(a.icon),
              tooltip: a.label,
              onPressed: a.onTap,
            ),
          )
          .toList();
    }

    // Narrow: pinned icons + overflow popup
    final pinned = actions.where((a) => a.pin).toList();
    final overflow = actions.where((a) => !a.pin).toList();

    return [
      ...pinned.map(
        (a) => IconButton(
          icon: Icon(a.icon),
          tooltip: a.label,
          onPressed: a.onTap,
        ),
      ),
      if (overflow.isNotEmpty)
        PopupMenuButton<int>(
          icon: const Icon(Icons.more_vert),
          tooltip: 'More',
          itemBuilder: (ctx) {
            final isDark = Theme.of(ctx).brightness == Brightness.dark;
            final iconColor = isDark ? Colors.teal[200] : Colors.teal[700];
            return overflow
                .asMap()
                .entries
                .map(
                  (e) => PopupMenuItem<int>(
                    value: e.key,
                    onTap: e.value.onTap,
                    child: Row(
                      children: [
                        Icon(e.value.icon, size: 20, color: iconColor),
                        const SizedBox(width: 12),
                        Text(e.value.label),
                      ],
                    ),
                  ),
                )
                .toList();
          },
        ),
    ];
  }

  // ── Setup view (before chat starts) ──

  Widget _buildSetupView(ThemeData theme) {
    final l = L.of(context);
    final uiStyle = AppPreferencesService.instance.uiStyle;
    final isModern = uiStyle == 'modern';

    final bottomPad = MediaQuery.of(context).padding.bottom;
    return ListView(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottomPad),
      children: [
        // Hint card
        isModern
            ? Container(
                decoration: BoxDecoration(
                  color: (theme.brightness == Brightness.dark
                      ? const Color(0xFF7C3AED).withValues(alpha: 0.08)
                      : const Color(0xFF7C3AED).withValues(alpha: 0.05)),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: const Color(0xFF7C3AED).withValues(alpha: 0.3),
                    width: 1.2,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.science_outlined,
                        color: Color(0xFF7C3AED),
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          l.playgroundHint,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: const Color(0xFF7C3AED),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            : Card(
                color: AppTheme.primaryBlue.withAlpha(20),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Icon(
                        Icons.science_outlined,
                        color: AppTheme.primaryBlue,
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          l.playgroundHint,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: AppTheme.primaryBlue,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
        // Examples button
        Row(
          children: [
            Expanded(
              child: Text(
                l.orStartFromExample,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            TextButton.icon(
              onPressed: _loadExample,
              icon: const Icon(Icons.lightbulb_outline, size: 18),
              label: Text(l.browseExamples),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Tool selection
        Text(
          l.selectTools,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            ..._selectedMcpTypes
                .where(
                  (type) =>
                      !(ref.read(serverModeProvider).value?.isRemote == true &&
                          type == 'ps_bridge'),
                )
                .map((type) {
                  if (type.startsWith('gh_mcp_')) {
                    final id = type.substring('gh_mcp_'.length);
                    final ghDef = _findGithubMcpById(id);
                    return InputChip(
                      label: Text(_mcpTypeLabel(type)),
                      deleteIcon: const Icon(Icons.close, size: 16),
                      onDeleted: () => setState(() {
                        _selectedMcpTypes.remove(type);
                        _mcpInitParams.remove(type);
                      }),
                      onPressed: ghDef != null
                          ? () => showMcpDiscoverSheet(context, ghDef)
                          : null,
                    );
                  }
                  // For library-backed tools show a tappable chip that opens the
                  // respective editor/library screen directly (no overflow needed).
                  VoidCallback? onChipPressed;
                  if (type == 'ssh') {
                    onChipPressed = () async {
                      final changed = await ScriptLibraryScreen.show(context);
                      if (changed == true && mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(l.scriptLibraryUpdated),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      }
                    };
                  } else if (type == 'js_bridge') {
                    onChipPressed = () async {
                      final changed = await JsToolLibraryScreen.show(context);
                      if (changed == true && mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('JS tool library updated.'),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      }
                    };
                  } else if (type == 'py_bridge') {
                    onChipPressed = () async {
                      final changed = await PyToolLibraryScreen.show(context);
                      if (changed == true && mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Python tool library updated.'),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      }
                    };
                  } else if (type == 'ps_bridge') {
                    onChipPressed = () async {
                      final changed = await PowershellToolLibraryScreen.show(
                        context,
                      );
                      if (changed == true && mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('PowerShell tool library updated.'),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      }
                    };
                  }
                  if (onChipPressed != null) {
                    return InputChip(
                      avatar: const Icon(Icons.model_training, size: 14),
                      label: Text(_mcpTypeLabel(type)),
                      deleteIcon: const Icon(Icons.close, size: 16),
                      onDeleted: () => setState(() {
                        _selectedMcpTypes.remove(type);
                        _mcpInitParams.remove(type);
                      }),
                      onPressed: () {
                        final server = InternalMcpRegistry().create(type);
                        String editorLabel = 'Tool Editor';
                        IconData editorIcon = Icons.edit;
                        if (type == 'ssh') {
                          editorLabel = 'SSH Script Editor';
                          editorIcon = Icons.code;
                        } else if (type == 'js_bridge') {
                          editorLabel = 'JS Tool Editor';
                          editorIcon = Icons.javascript;
                        } else if (type == 'py_bridge') {
                          editorLabel = 'Python Tool Editor';
                          editorIcon = Icons.terminal;
                        } else if (type == 'ps_bridge') {
                          editorLabel = 'PowerShell Tool Editor';
                          editorIcon = Icons.terminal;
                        }

                        showDialog(
                          context: context,
                          builder: (context) {
                            return AlertDialog(
                              title: Text(_mcpTypeLabel(type)),
                              content: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  ListTile(
                                    leading: const Icon(Icons.download),
                                    title: const Text('Export Tools'),
                                    onTap: () {
                                      Navigator.of(context).pop();
                                      if (server == null) return;
                                      ToolListExportSheet.show(
                                        context,
                                        serverName: server.displayName,
                                        tools: server.tools
                                            .map(
                                              (t) => {
                                                'name': t.name,
                                                'description': t.description,
                                                'inputSchema': t.inputSchema,
                                              },
                                            )
                                            .toList(),
                                      );
                                    },
                                  ),
                                  ListTile(
                                    leading: Icon(editorIcon),
                                    title: Text(editorLabel),
                                    onTap: () {
                                      Navigator.of(context).pop();
                                      onChipPressed?.call();
                                    },
                                  ),
                                ],
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(context).pop(),
                                  child: const Text('Abbrechen'),
                                ),
                              ],
                            );
                          },
                        );
                      },
                    );
                  }
                  return InputChip(
                    avatar: const Icon(Icons.model_training, size: 14),
                    label: Text(_mcpTypeLabel(type)),
                    deleteIcon: const Icon(Icons.close, size: 16),
                    onDeleted: () => setState(() {
                      _selectedMcpTypes.remove(type);
                      _mcpInitParams.remove(type);
                    }),
                    onPressed: () {
                      final server = InternalMcpRegistry().create(type);
                      if (server == null) return;
                      ToolListExportSheet.show(
                        context,
                        serverName: server.displayName,
                        tools: server.tools
                            .map(
                              (t) => {
                                'name': t.name,
                                'description': t.description,
                                'inputSchema': t.inputSchema,
                              },
                            )
                            .toList(),
                      );
                    },
                  );
                }),
            ..._selectedExternalServerUrls.map((url) {
              final server = ExternalToolsSettingsService
                  .instance
                  .selectedServers
                  .where((s) => s.serverUrl == url)
                  .firstOrNull;
              final label = server?.name ?? url;
              return InputChip(
                avatar: const Icon(Icons.dns, size: 14, color: Colors.orange),
                label: Text(
                  label,
                  style: const TextStyle(color: Colors.orange),
                ),
                side: const BorderSide(color: Colors.orange, width: 1),
                deleteIcon: const Icon(
                  Icons.close,
                  size: 16,
                  color: Colors.orange,
                ),
                onDeleted: () {
                  setState(() => _selectedExternalServerUrls.remove(url));
                  _updateSkillsSection();
                },
                onPressed: server != null
                    ? () => showMcpToolsViewerScreen(context, server)
                    : null,
              );
            }),
            ActionChip(
              avatar: const Icon(Icons.add, size: 18),
              label: Text(l.selectTools),
              onPressed: _showToolSelectionDialog,
            ),
          ],
        ),

        // MCP init params (e.g. root directory for document search)
        ..._buildMcpInitParamWidgets(theme, l),

        const SizedBox(height: 8),

        // Auto-generate system prompt on tool change
        isModern
            ? Container(
                decoration: BoxDecoration(
                  color: theme.brightness == Brightness.dark
                      ? const Color(0xFF7C3AED).withValues(alpha: 0.08)
                      : const Color(0xFF7C3AED).withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: const Color(0xFF7C3AED).withValues(alpha: 0.3),
                    width: 1.2,
                  ),
                ),
                child: Material(
                  color: Colors.transparent,
                  clipBehavior: Clip.antiAlias,
                  borderRadius: BorderRadius.circular(16),
                  child: CheckboxListTile(
                    title: const Text(
                      'Generate system prompt',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    subtitle: const Text(
                      'Auto-fill the system prompt based on selected tools',
                      style: TextStyle(fontSize: 11),
                    ),
                    value: _pgGenerateOnToolSelect,
                    onChanged: (v) =>
                        setState(() => _pgGenerateOnToolSelect = v ?? true),
                    activeColor: const Color(0xFF7C3AED),
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                  ),
                ),
              )
            : Card(
                margin: EdgeInsets.zero,
                color: AppTheme.primaryBlue.withAlpha(18),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                child: CheckboxListTile(
                  title: const Text(
                    'Generate system prompt',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                  subtitle: const Text(
                    'Auto-fill the system prompt based on selected tools',
                    style: TextStyle(fontSize: 11),
                  ),
                  value: _pgGenerateOnToolSelect,
                  onChanged: (v) =>
                      setState(() => _pgGenerateOnToolSelect = v ?? true),
                  activeColor: AppTheme.primaryBlue,
                  controlAffinity: ListTileControlAffinity.leading,
                  dense: true,
                ),
              ),
        const SizedBox(height: 8),

        // Chat mode toggle
        isModern
            ? Container(
                decoration: BoxDecoration(
                  color: theme.brightness == Brightness.dark
                      ? const Color(0xFF06B6D4).withValues(alpha: 0.08)
                      : const Color(0xFF34D399).withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color:
                        (theme.brightness == Brightness.dark
                                ? const Color(0xFF06B6D4)
                                : const Color(0xFF34D399))
                            .withValues(alpha: 0.3),
                    width: 1.2,
                  ),
                ),
                child: Material(
                  color: Colors.transparent,
                  clipBehavior: Clip.antiAlias,
                  borderRadius: BorderRadius.circular(16),
                  child: CheckboxListTile(
                    title: const Text(
                      'Chat mode',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    subtitle: const Text(
                      'Direct LLM chat — no system prompt, no tools. Fastest for SLMs doing simple tasks (formatting, translation, etc.)',
                      style: TextStyle(fontSize: 11),
                    ),
                    value: _chatMode,
                    onChanged: (v) => setState(() => _chatMode = v ?? false),
                    activeColor: theme.brightness == Brightness.dark
                        ? const Color(0xFF06B6D4)
                        : const Color(0xFF34D399),
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                  ),
                ),
              )
            : Card(
                margin: EdgeInsets.zero,
                color: Colors.orange.withAlpha(18),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                child: CheckboxListTile(
                  title: const Text(
                    'Chat mode',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                  subtitle: const Text(
                    'Direct LLM chat — no system prompt, no tools. Fastest for SLMs doing simple tasks (formatting, translation, etc.)',
                    style: TextStyle(fontSize: 11),
                  ),
                  value: _chatMode,
                  onChanged: (v) => setState(() => _chatMode = v ?? false),
                  activeColor: Colors.orange,
                  controlAffinity: ListTileControlAffinity.leading,
                  dense: true,
                ),
              ),
        const SizedBox(height: 8),

        // System prompt (hidden in chat mode)
        if (!_chatMode) ...[
          Text(
            l.systemPrompt,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          // Subject + Generate wizard
          TextField(
            controller: _subjectCtrl,
            decoration: InputDecoration(
              labelText: l.promptSubject,
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: IconButton(
                  onPressed: _isGenerating ? null : _generateSystemPrompt,
                  tooltip: l.generatePrompt,
                  style: IconButton.styleFrom(
                    backgroundColor: AppTheme.primaryBlue,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: AppTheme.primaryBlue.withValues(
                      alpha: 0.4,
                    ),
                    padding: const EdgeInsets.all(8),
                    minimumSize: const Size(36, 36),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  icon: _isGenerating
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.auto_awesome, size: 20),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l.generateSystemPromptHint,
            style: TextStyle(fontSize: 11, color: Colors.grey[500]),
          ),
          const SizedBox(height: 12),
          StepListEditor(
            controller: _systemPromptUserCtrl,
            chatMode: _chatMode,
            availableToolGroups: const [],
            minLines: 3,
            maxLines: 8,
            hintText: l.systemPrompt,
            onToolSelectionChanged: _updateSkillsSection,
          ),
          const SizedBox(height: 8),
          _buildSkillsTextbox(),
          const SizedBox(height: 12),
        ], // end if (!_chatMode)
        // LLM selector
        Builder(
          builder: (context) {
            final llmSettings = ref.watch(llmSettingsProvider);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'LLM',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                // Segmented: LLM1 / LLM2 / Custom
                SegmentedButton<int>(
                  segments: [
                    ButtonSegment(
                      value: 1,
                      label: Text('LLM 1  (${llmSettings.model})'),
                      icon: const Icon(Icons.auto_awesome, size: 16),
                    ),
                    if (llmSettings.isConfigured2)
                      ButtonSegment(
                        value: 2,
                        label: Text('LLM 2  (${llmSettings.model2})'),
                        icon: const Icon(Icons.code, size: 16),
                      ),
                    const ButtonSegment(
                      value: 3,
                      label: Text('Custom'),
                      icon: Icon(Icons.tune, size: 16),
                    ),
                  ],
                  selected: {_overrideLlm ? 3 : _selectedLlm},
                  onSelectionChanged: (s) {
                    final v = s.first;
                    setState(() {
                      if (v == 3) {
                        _overrideLlm = true;
                      } else {
                        _overrideLlm = false;
                        _selectedLlm = v;
                      }
                    });
                    _updateSkillsSection();
                  },
                  style: SegmentedButton.styleFrom(
                    selectedBackgroundColor: AppTheme.primaryBlue,
                    selectedForegroundColor: Colors.white,
                  ),
                ),
                // ── Custom LLM panel (mirrors task editor) ──
                if (_overrideLlm) ..._buildCustomLlmPanel(llmSettings),
                const SizedBox(height: 12),
              ],
            );
          },
        ),

        // Active skill chip
        if (_activeSkill != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                Expanded(
                  child: Card(
                    color: Colors.amber.withAlpha(25),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side: BorderSide(color: Colors.amber.withAlpha(80)),
                    ),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: _showSkillWizardDialog,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.auto_awesome,
                              color: Colors.amber,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Skill: ${_activeSkill!.name}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const Icon(
                              Icons.chevron_right,
                              size: 18,
                              color: Colors.amber,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Remove skill',
                  onPressed: () {
                    setState(() => _activeSkill = null);
                    _updateSkillsSection();
                  },
                ),
              ],
            ),
          ),

        // Initial prompt
        Text(
          l.initialPrompt,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        StepListEditor(
          controller: _initialPromptCtrl,
          chatMode: _chatMode,
          availableToolGroups: _availableToolGroupsForSteps,
          onToolSelectionChanged: _updateSkillsSection,
          minLines: 2,
          maxLines: 8,
          hintText: l.initialPromptHint,
        ),
        const SizedBox(height: 16),

        // Start button
        FilledButton.icon(
          onPressed: _isWebsiteIndexing ? null : _startChat,
          icon: const Icon(Icons.play_arrow),
          label: Text(l.startPlayground),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            backgroundColor: AppTheme.primaryBlue,
          ),
        ),
      ],
    );
  }

  // ── MCP init parameter widgets (directory pickers, etc.) ──

  List<Widget> _buildMcpInitParamWidgets(ThemeData theme, L l) {
    final widgets = <Widget>[];

    // Document Search → rootPath directory picker
    if (_selectedMcpTypes.contains('document')) {
      final currentPath =
          _mcpInitParams['document']?['rootPath'] as String? ?? '';
      final selectedPaths = currentPath
          .split(';')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toSet();
      widgets.add(const SizedBox(height: 16));
      widgets.add(
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.folder_outlined,
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${_mcpTypeLabel('document')} — ${l.chooseDirectory}',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Show global (settings) paths as locked chips + extra paths as removable chips.
                if (selectedPaths.isNotEmpty) ...[
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      // Locked chips for Settings paths
                      ..._globalDocumentPaths.where(selectedPaths.contains).map(
                        (p) {
                          final shortName = SafBridge.labelFromUri(p);
                          return Tooltip(
                            message: p,
                            child: Chip(
                              label: Text(
                                shortName,
                                style: const TextStyle(fontSize: 12),
                              ),
                              avatar: const Icon(Icons.folder, size: 16),
                              side: BorderSide(
                                color: theme.colorScheme.primary.withValues(
                                  alpha: 0.4,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                      // Removable chips for extra paths
                      ...selectedPaths
                          .where((p) => !_globalDocumentPaths.contains(p))
                          .map((p) {
                            final shortName = SafBridge.labelFromUri(p);
                            return InputChip(
                              label: Text(
                                shortName,
                                style: const TextStyle(fontSize: 12),
                              ),
                              avatar: const Icon(Icons.folder, size: 16),
                              tooltip: p,
                              deleteIcon: const Icon(Icons.close, size: 16),
                              onDeleted: () {
                                final updated = Set<String>.from(selectedPaths)
                                  ..remove(p);
                                setState(() {
                                  _mcpInitParams['document'] = {
                                    ...(_mcpInitParams['document'] ?? {}),
                                    'rootPath': updated.join(';'),
                                  };
                                });
                                _savePersistedDocumentSearchSettings(
                                  rootPath: updated.join(';'),
                                );
                              },
                            );
                          }),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
                // Status container — only shown when nothing selected yet
                if (selectedPaths.isEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: theme.colorScheme.outline.withAlpha(120),
                      ),
                      borderRadius: BorderRadius.circular(8),
                      color: theme.colorScheme.surfaceContainerHighest
                          .withAlpha(80),
                    ),
                    child: Text(
                      l.chooseDirectory,
                      style: TextStyle(
                        fontSize: 13,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                if (ref.read(serverModeProvider).value?.isRemote ?? false) ...[
                  // ── Server mode: type path directly ──
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      icon: const Icon(
                        Icons.create_new_folder_outlined,
                        size: 18,
                      ),
                      label: const Text('Add server path'),
                      onPressed: () async {
                        String typedPath = '';
                        final picked = await showDialog<String>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Add Folder or File'),
                            content: TextField(
                              autofocus: true,
                              onChanged: (v) => typedPath = v,
                              onSubmitted: (_) {
                                final v = typedPath.trim();
                                Navigator.of(ctx).pop(v.isNotEmpty ? v : null);
                              },
                              decoration: const InputDecoration(
                                hintText: '/home/user/documents',
                                labelText: 'Absolute path on server',
                              ),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.of(ctx).pop(),
                                child: const Text('Cancel'),
                              ),
                              TextButton(
                                onPressed: () {
                                  final v = typedPath.trim();
                                  Navigator.of(
                                    ctx,
                                  ).pop(v.isNotEmpty ? v : null);
                                },
                                child: const Text('Add'),
                              ),
                            ],
                          ),
                        );
                        if (picked == null || !mounted) return;
                        final updated = Set<String>.from(selectedPaths)
                          ..add(picked);
                        setState(() {
                          _mcpInitParams['document'] = {
                            ...(_mcpInitParams['document'] ?? {}),
                            'rootPath': updated.join(';'),
                          };
                        });
                        _savePersistedDocumentSearchSettings(
                          rootPath: updated.join(';'),
                        );
                      },
                    ),
                  ),
                ] else ...[
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.folder_open, size: 18),
                          label: Text(l.chooseDirectory),
                          onPressed: () => _pickRootDirectory('document'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.file_copy_outlined, size: 18),
                          label: const Text('Pick Files'),
                          onPressed: () async {
                            final result = await FilePicker.pickFiles(
                              allowMultiple: true,
                              type: FileType.custom,
                              allowedExtensions: ['pdf', 'md', 'docx'],
                              withData: true,
                            );
                            if (result == null || result.files.isEmpty) return;
                            final appDir =
                                await getApplicationSupportDirectory();
                            final destDir = Directory(
                              '${appDir.path}/tealkit_indexed_files',
                            );
                            await destDir.create(recursive: true);
                            int copied = 0;
                            for (final f in result.files) {
                              final bytes = f.bytes;
                              final name = f.name;
                              if (bytes != null) {
                                await File(
                                  '${destDir.path}/$name',
                                ).writeAsBytes(bytes);
                                copied++;
                              } else if (f.path != null) {
                                await File(
                                  f.path!,
                                ).copy('${destDir.path}/$name');
                                copied++;
                              }
                            }
                            final updated = Set<String>.from(selectedPaths)
                              ..add(destDir.path);
                            setState(() {
                              _mcpInitParams['document'] = {
                                ...(_mcpInitParams['document'] ?? {}),
                                'rootPath': updated.join(';'),
                              };
                            });
                            _savePersistedDocumentSearchSettings(
                              rootPath: updated.join(';'),
                            );
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    '$copied file(s) copied — tap Reindex to update search',
                                  ),
                                ),
                              );
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                  // Quick-pick common directories on Android 9/10 (API < 30).
                  // On Android 11+, getCommonDirectories() returns [] so this is hidden;
                  // users pick folders via SAF through the Browse button above.
                  if (Platform.isAndroid) ...[
                    FutureBuilder<List<(String, String)>>(
                      future: StoragePermission.getCommonDirectories(),
                      builder: (ctx, snap) {
                        if (!snap.hasData || snap.data!.isEmpty) {
                          return const SizedBox.shrink();
                        }
                        return Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Tap folders below to add/remove (Browse may block some on Android):',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Wrap(
                                spacing: 8,
                                runSpacing: 4,
                                children: snap.data!.map((dir) {
                                  final (label, path) = dir;
                                  final isSelected = selectedPaths.contains(
                                    path,
                                  );
                                  return FilterChip(
                                    avatar: Icon(
                                      isSelected
                                          ? Icons.check_circle
                                          : Icons.folder,
                                      size: 18,
                                      color: isSelected
                                          ? AppTheme.primaryBlue
                                          : null,
                                    ),
                                    selected: isSelected,
                                    showCheckmark: false,
                                    label: Text(
                                      label,
                                      style: TextStyle(
                                        fontWeight: isSelected
                                            ? FontWeight.bold
                                            : FontWeight.normal,
                                      ),
                                    ),
                                    backgroundColor: isSelected
                                        ? AppTheme.primaryBlue.withValues(
                                            alpha: 0.1,
                                          )
                                        : null,
                                    onSelected: (_) {
                                      final updated = Set<String>.from(
                                        selectedPaths,
                                      );
                                      if (isSelected) {
                                        updated.remove(path);
                                      } else {
                                        updated.add(path);
                                      }
                                      setState(() {
                                        _mcpInitParams['document'] = {
                                          ...(_mcpInitParams['document'] ?? {}),
                                          'rootPath': updated.join(';'),
                                        };
                                      });
                                      _savePersistedDocumentSearchSettings(
                                        rootPath: updated.join(';'),
                                      );
                                    },
                                  );
                                }).toList(),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ], // end if (Platform.isAndroid)
                ], // end else (local mode)
                const SizedBox(height: 12),
                // ── File type toggles ──────────────────────────────────────
                Builder(
                  builder: (context) {
                    final rawFt =
                        _mcpInitParams['document']?['fileTypes'] as String? ??
                        _kDefaultDocFileTypes;
                    final selectedFt = rawFt
                        .split(',')
                        .map((e) => e.trim().toLowerCase())
                        .where((e) => e.isNotEmpty)
                        .toSet();
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              'File Types to Index',
                              style: theme.textTheme.labelMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const Spacer(),
                            TextButton(
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: () {
                                final defaults = _kDefaultDocFileTypes;
                                setState(() {
                                  _mcpInitParams['document'] = {
                                    ...(_mcpInitParams['document'] ?? {}),
                                    'fileTypes': defaults,
                                  };
                                });
                                _savePersistedDocumentSearchSettings(
                                  fileTypes: defaults,
                                );
                              },
                              child: Text(
                                'Reset',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ),
                            TextButton(
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: () {
                                final all = _kDocFileTypes.join(',');
                                setState(() {
                                  _mcpInitParams['document'] = {
                                    ...(_mcpInitParams['document'] ?? {}),
                                    'fileTypes': all,
                                  };
                                });
                                _savePersistedDocumentSearchSettings(
                                  fileTypes: all,
                                );
                              },
                              child: Text(
                                'All',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: _kDocFileTypes.map((ext) {
                            final isSelected = selectedFt.contains(ext);
                            return FilterChip(
                              label: Text(
                                '.$ext',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: isSelected
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                              ),
                              selected: isSelected,
                              showCheckmark: false,
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              selectedColor: theme.colorScheme.primaryContainer,
                              onSelected: (on) {
                                final updated = Set<String>.from(selectedFt);
                                if (on) {
                                  updated.add(ext);
                                } else {
                                  updated.remove(ext);
                                }
                                final typesStr = updated.join(',');
                                setState(() {
                                  _mcpInitParams['document'] = {
                                    ...(_mcpInitParams['document'] ?? {}),
                                    'fileTypes': typesStr,
                                  };
                                });
                                _savePersistedDocumentSearchSettings(
                                  fileTypes: typesStr,
                                );
                              },
                            );
                          }).toList(),
                        ),
                        const SizedBox(height: 10),
                      ],
                    );
                  },
                ),
                // Indexer button + progress
                _buildDocumentIndexerWidget(theme, l, currentPath),
                if (currentPath.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'Select one or more directories for document search. Indexing is optional but enables semantic search.',
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    // Website Search → seed URL list + index button
    if (_selectedMcpTypes.contains('website_search')) {
      final rawUrls =
          _mcpInitParams['website_search']?['websiteUrls'] as String? ?? '';
      final maxPages =
          ((_mcpInitParams['website_search']?['maxPages'] as int?) ??
                  int.tryParse(_websiteMaxPagesCtrl.text.trim()) ??
                  100)
              .clamp(1, 1000);
      final selectedUrls = rawUrls
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .take(3)
          .toList();
      final typedParsed = _normalizeWebsiteUrl(_websiteUrlCtrl.text);
      final typedUrlValid = typedParsed != null;
      const maxUrls = 10;
      final canAddTypedUrl =
          typedParsed != null &&
          selectedUrls.length < maxUrls &&
          !selectedUrls.contains(typedParsed.toString());
      final canIndexNow = selectedUrls.isNotEmpty || canAddTypedUrl;

      widgets.add(const SizedBox(height: 16));
      widgets.add(
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.language,
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${_mcpTypeLabel('website_search')} — Seed Websites',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (selectedUrls.isNotEmpty) ...[
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: selectedUrls.map<Widget>((url) {
                      Uri? parsed;
                      try {
                        parsed = Uri.parse(
                          url.contains('://') ? url : 'https://$url',
                        );
                      } catch (_) {
                        parsed = null;
                      }
                      final host = parsed?.host.isNotEmpty == true
                          ? parsed!.host
                          : url;
                      final isGlobal = _globalWebsiteUrls.contains(url);
                      if (isGlobal) {
                        return Tooltip(
                          message:
                              '$url (configured in Settings → Data Sources)',
                          child: Chip(
                            label: Text(
                              host,
                              style: const TextStyle(fontSize: 12),
                            ),
                            avatar: const Icon(Icons.settings, size: 14),
                            backgroundColor: Theme.of(context)
                                .colorScheme
                                .primaryContainer
                                .withValues(alpha: 0.5),
                          ),
                        );
                      }
                      return InputChip(
                        label: Text(host, style: const TextStyle(fontSize: 12)),
                        avatar: const Icon(Icons.public, size: 16),
                        tooltip: url,
                        deleteIcon: const Icon(Icons.close, size: 16),
                        onDeleted: () {
                          final updated = List<String>.from(selectedUrls)
                            ..remove(url);
                          setState(() {
                            _mcpInitParams['website_search'] = {
                              ...(_mcpInitParams['website_search'] ?? {}),
                              'websiteUrls': updated.join(', '),
                            };
                          });
                          _savePersistedWebsiteSearchSettings(urls: updated);
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 8),
                ],
                TextField(
                  controller: _websiteUrlCtrl,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    isDense: true,
                    labelText: l.websiteUrlLabel,
                    hintText: 'https://example.com/docs',
                    suffixIcon: const Icon(Icons.add_link),
                  ),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (value) {
                    if (value.trim().isEmpty) return;
                    _addWebsiteFromInput(selectedUrls);
                  },
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _websiteMaxPagesCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    isDense: true,
                    labelText: l.maxPagesLabel,
                    hintText: '100',
                    helperText: 'Default: 100 (allowed: 1 - 1000)',
                  ),
                  onChanged: (value) {
                    final parsed = int.tryParse(value.trim());
                    if (parsed == null) {
                      setState(() {
                        _mcpInitParams['website_search'] = {
                          ...(_mcpInitParams['website_search'] ?? {}),
                          'maxPages': 100,
                        };
                      });
                      _savePersistedWebsiteSearchSettings(maxPages: 100);
                      return;
                    }
                    final clamped = parsed.clamp(1, 1000);
                    setState(() {
                      _mcpInitParams['website_search'] = {
                        ...(_mcpInitParams['website_search'] ?? {}),
                        'maxPages': clamped,
                      };
                    });
                    _savePersistedWebsiteSearchSettings(maxPages: clamped);
                  },
                ),
                const SizedBox(height: 6),
                if (_websiteUrlCtrl.text.trim().isNotEmpty)
                  Text(
                    !typedUrlValid
                        ? 'Typed URL is invalid.'
                        : canAddTypedUrl
                        ? 'Ready to add and index this URL.'
                        : 'URL already selected or max websites reached.',
                    style: TextStyle(
                      fontSize: 11,
                      color: !typedUrlValid
                          ? AppTheme.error
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                if (_websiteUrlCtrl.text.trim().isNotEmpty)
                  const SizedBox(height: 6),
                Text(
                  _globalWebsiteUrls.isNotEmpty
                      ? '${_globalWebsiteUrls.length} site${_globalWebsiteUrls.length == 1 ? '' : 's'} from Settings · add more below (max $maxUrls). Max pages: $maxPages.'
                      : 'Add up to $maxUrls sites. Indexed pages are stored in DuckDB. Max pages: $maxPages.',
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 10),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final narrow = constraints.maxWidth < 560;

                    final addButton = OutlinedButton.icon(
                      onPressed: _isWebsiteIndexing || !canAddTypedUrl
                          ? null
                          : () => _addWebsiteFromInput(selectedUrls),
                      icon: const Icon(Icons.add, size: 18),
                      label: Text(l.addUrlButton),
                    );

                    final indexButton = _isWebsiteIndexing
                        ? ElevatedButton.icon(
                            onPressed: () {
                              _activeWebIndexServer?.cancelIndexing();
                            },
                            icon: const Icon(Icons.stop, size: 18),
                            label: Text(l.indexingStop),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.error,
                              foregroundColor: Colors.white,
                            ),
                          )
                        : ElevatedButton.icon(
                            onPressed: !canIndexNow
                                ? null
                                : () async {
                                    if (selectedUrls.isEmpty) {
                                      final added = _addWebsiteFromInput(
                                        selectedUrls,
                                      );
                                      if (!added) return;
                                    }
                                    await _doWebsiteIndex();
                                  },
                            icon: const Icon(Icons.play_arrow, size: 18),
                            label: Text(l.indexingStart),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: canIndexNow
                                  ? Colors.green
                                  : Colors.grey,
                              foregroundColor: Colors.white,
                            ),
                          );

                    // Progress / result indicator shown below the button row
                    final progressWidget = _isWebsiteIndexing
                        ? Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    value: _indexTotal > 0
                                        ? (_indexedCount / _indexTotal).clamp(
                                            0.0,
                                            1.0,
                                          )
                                        : null,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _indexTotal > 0
                                        ? 'Indexing $_indexedCount / $_indexTotal pages…'
                                        : 'Indexing…',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          )
                        : _websiteLastIndexedCount >= 0
                        ? Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.check_circle_outline,
                                  size: 16,
                                  color: Colors.green[400],
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '$_websiteLastIndexedCount page${_websiteLastIndexedCount == 1 ? '' : 's'} indexed',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.green[400],
                                  ),
                                ),
                              ],
                            ),
                          )
                        : const SizedBox.shrink();

                    if (narrow) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              addButton,
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  selectedUrls.isEmpty && !canAddTypedUrl
                                      ? l.noWebsitesSelected
                                      : l.websitesSelectedCount(
                                          selectedUrls.length,
                                        ),
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          SizedBox(width: double.infinity, child: indexButton),
                          progressWidget,
                        ],
                      );
                    }

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            addButton,
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                selectedUrls.isEmpty && !canAddTypedUrl
                                    ? l.noWebsitesSelected
                                    : l.websitesSelectedCount(
                                        selectedUrls.length,
                                      ),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            indexButton,
                          ],
                        ),
                        progressWidget,
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      );
    }

    // SSH credentials override
    if (_selectedMcpTypes.contains('ssh')) {
      widgets.add(const SizedBox(height: 16));
      widgets.add(
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.terminal,
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'SSH — Connection Override',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Leave empty to use global SSH settings.',
                  style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _sshHostCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Host / IP',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (v) => setState(() {
                          _mcpInitParams['ssh'] = {
                            ...(_mcpInitParams['ssh'] ?? {}),
                            'host': v,
                          };
                        }),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _sshPortCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Port',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.number,
                        onChanged: (v) => setState(() {
                          _mcpInitParams['ssh'] = {
                            ...(_mcpInitParams['ssh'] ?? {}),
                            'port': int.tryParse(v) ?? 22,
                          };
                        }),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _sshUsernameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Username',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(() {
                    _mcpInitParams['ssh'] = {
                      ...(_mcpInitParams['ssh'] ?? {}),
                      'username': v,
                    };
                  }),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _sshPasswordCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(() {
                    _mcpInitParams['ssh'] = {
                      ...(_mcpInitParams['ssh'] ?? {}),
                      'password': v,
                    };
                  }),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final result = await FilePicker.pickFiles(
                            type: FileType.any,
                            allowMultiple: false,
                            withData: true,
                          );
                          if (result == null ||
                              result.files.single.bytes == null) {
                            return;
                          }
                          final keyText = utf8.decode(
                            result.files.single.bytes!,
                            allowMalformed: false,
                          );
                          setState(() {
                            _sshPrivateKeyPem = keyText;
                            _sshPrivateKeyFileName = result.files.single.name;
                            _mcpInitParams['ssh'] = {
                              ...(_mcpInitParams['ssh'] ?? {}),
                              'privateKey': keyText,
                              '_privateKeyFileName': result.files.single.name,
                            };
                          });
                        },
                        icon: const Icon(Icons.key, size: 16),
                        label: Text(
                          _sshPrivateKeyFileName.isNotEmpty
                              ? _sshPrivateKeyFileName
                              : 'Load Private Key (PEM)…',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    if (_sshPrivateKeyPem.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Clear private key',
                        icon: const Icon(Icons.clear, size: 16),
                        onPressed: () => setState(() {
                          _sshPrivateKeyPem = '';
                          _sshPrivateKeyFileName = '';
                          _mcpInitParams['ssh'] = {
                            ...(_mcpInitParams['ssh'] ?? {}),
                            'privateKey': '',
                            '_privateKeyFileName': '',
                          };
                        }),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton.icon(
                    onPressed: _testSshOverrideConnection,
                    icon: const Icon(Icons.network_check),
                    label: const Text('Test connection'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Web Search → SerpApi/Serper warning when not configured
    if (_selectedMcpTypes.contains('web_search')) {
      final ds = DataSourcesSettingsService.instance;
      final hasPremiumSearch =
          (ds.webSearchProvider == WebSearchProvider.serpapi ||
              ds.webSearchProvider == WebSearchProvider.serper ||
              ds.webSearchProvider == WebSearchProvider.custom) &&
          ds.isWebSearchConfigured;

      if (!hasPremiumSearch) {
        widgets.add(const SizedBox(height: 16));
        widgets.add(
          Card(
            color: AppTheme.warning.withValues(alpha: 0.10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: AppTheme.warning.withValues(alpha: 0.40),
                width: 1,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    color: AppTheme.warning,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'SerpApi or Serper.dev recommended',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: AppTheme.warning,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Web search falls back to DuckDuckGo. For flight searches, current news, or '
                          'product prices, configure SerpApi (serpapi.com) or Serper.dev in '
                          'Settings → Data Sources. Both offer a free tier.',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.warning,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }
    }

    return widgets;
  }

  Future<void> _doWebsiteIndex() async {
    final l = L.of(context);
    final websiteParams =
        _mcpInitParams['website_search'] ?? const <String, dynamic>{};
    final websiteUrls = (websiteParams['websiteUrls'] as String? ?? '').trim();
    if (websiteUrls.isEmpty) return;

    final server = WebsiteSearchMcpServer();
    server.onIndexProgress = (indexed, total, currentUrl) {
      if (mounted) {
        setState(() {
          _indexedCount = indexed;
          _indexTotal = total;
          _indexCurrentFile = currentUrl;
        });
      }
    };
    _activeWebIndexServer = server;
    setState(() {
      _isWebsiteIndexing = true;
      _websiteLastIndexedCount = -1;
    });
    try {
      await server.initialize(websiteParams);
      final result = await server.executeTool('reindex_websites', {});
      await server.dispose();
      _activeWebIndexServer = null;

      if (!mounted) return;
      final wasCancelled = result['cancelled'] == true;
      if (wasCancelled) {
        final count = result['indexedPages'] as int? ?? 0;
        if (mounted) setState(() => _websiteLastIndexedCount = count);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l.indexingCancelled(count)),
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else if (result.containsKey('error')) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l.reindexFailed(result['error'] as String)),
            backgroundColor: AppTheme.error,
          ),
        );
      } else {
        await _savePersistedWebsiteSearchSettings();
        final count = result['indexedPages'] as int? ?? 0;
        final ms = result['durationMs'] as int? ?? 0;
        if (mounted) setState(() => _websiteLastIndexedCount = count);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l.websiteIndexComplete(count, ms)),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      _activeWebIndexServer = null;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l.reindexFailed(e.toString())),
          backgroundColor: AppTheme.error,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isWebsiteIndexing = false;
          _indexedCount = 0;
          _indexTotal = 0;
          _indexCurrentFile = '';
        });
      }
    }
  }

  Widget _buildDocumentIndexerWidget(ThemeData theme, L l, String rootPath) {
    final hasPath = rootPath.trim().isNotEmpty;

    if (_isIndexing) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_indexTotal > 0)
                      LinearProgressIndicator(
                        value: _indexedCount / _indexTotal,
                      )
                    else
                      const LinearProgressIndicator(),
                    const SizedBox(height: 4),
                    Text(
                      _indexTotal > 0
                          ? l.indexingProgress(_indexedCount, _indexTotal)
                          : l.reindexing,
                      style: const TextStyle(fontSize: 12),
                    ),
                    if (_indexCurrentFile.isNotEmpty)
                      Text(
                        _indexCurrentFile.split(Platform.pathSeparator).last,
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: () {
                  _activeIndexServer?.cancelIndexing();
                },
                icon: const Icon(Icons.stop, size: 18),
                label: Text(l.indexingStop),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.error,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ],
      );
    }

    final lastIndexed =
        DataSourcesSettingsService.instance.documentIndexLastIndexedAt;
    String? lastIndexedLabel;
    if (lastIndexed != null) {
      final diff = DateTime.now().difference(lastIndexed);
      if (diff.inMinutes < 1) {
        lastIndexedLabel = 'just now';
      } else if (diff.inHours < 1) {
        lastIndexedLabel = '${diff.inMinutes}m ago';
      } else if (diff.inDays < 1) {
        lastIndexedLabel = '${diff.inHours}h ago';
      } else if (diff.inDays < 7) {
        lastIndexedLabel = '${diff.inDays}d ago';
      } else {
        lastIndexedLabel =
            '${lastIndexed.year}-${lastIndexed.month.toString().padLeft(2, '0')}-${lastIndexed.day.toString().padLeft(2, '0')}';
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Index documents for semantic search (optional)',
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (lastIndexedLabel != null) ...[
              const SizedBox(height: 2),
              Row(
                children: [
                  Icon(
                    Icons.history,
                    size: 12,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Last indexed: $lastIndexedLabel',
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        ElevatedButton.icon(
          onPressed: hasPath ? _doDocumentIndex : null,
          icon: const Icon(Icons.play_arrow, size: 18),
          label: Text(l.indexingStart),
          style: ElevatedButton.styleFrom(
            backgroundColor: hasPath ? Colors.green : Colors.grey,
            foregroundColor: Colors.white,
          ),
        ),
      ],
    );
  }

  Future<bool> _doDocumentIndex() async {
    final l = L.of(context);
    final rootPath = _mcpInitParams['document']?['rootPath'] as String? ?? '';
    if (rootPath.trim().isEmpty) return false;

    // On Android, ensure storage permission
    if (Platform.isAndroid) {
      final hasAccess = await StoragePermission.hasAccess();
      if (!hasAccess) {
        if (!mounted) return false;
        final granted = await StoragePermission.request(context);
        if (!mounted || !granted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l.reindexFailed('Storage permission not granted')),
              backgroundColor: AppTheme.error,
            ),
          );
          return false;
        }
      }
    }

    setState(() {
      _isIndexing = true;
      _indexedCount = 0;
      _indexTotal = 0;
      _indexCurrentFile = '';
    });

    try {
      final server = DocumentMcpServer();
      _activeIndexServer = server;
      server.onIndexProgress = (indexed, total, currentFile) {
        if (mounted) {
          setState(() {
            _indexedCount = indexed;
            _indexTotal = total;
            _indexCurrentFile = currentFile;
          });
        }
      };

      await server.initialize(
        _mcpInitParams['document'] ?? {'rootPath': rootPath},
      );
      final result = await server.executeTool('reindex', {});
      await server.dispose();
      _activeIndexServer = null;

      if (!mounted) return false;

      final wasCancelled = result['cancelled'] == true;
      if (result.containsKey('error')) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l.reindexFailed(result['error'] as String)),
            backgroundColor: AppTheme.error,
          ),
        );
        return false;
      } else if (wasCancelled) {
        final count = result['indexed'] as int? ?? _indexedCount;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.indexingCancelled(count))));
        return false;
      } else {
        await _savePersistedDocumentSearchSettings(rootPath: rootPath);
        final count = result['documentsIndexed'] as int? ?? 0;
        final ms = result['durationMs'] as int? ?? 0;
        final totalFileSize = result['totalFileSizeBytes'] as int? ?? 0;
        final indexSize = result['indexSizeBytes'] as int? ?? 0;
        final fileSizeKb = (totalFileSize / 1024).toStringAsFixed(1);
        final indexSizeKb = (indexSize / 1024).toStringAsFixed(1);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l.reindexComplete(count, ms, fileSizeKb, indexSizeKb),
            ),
          ),
        );
        return true;
      }
    } catch (e) {
      _activeIndexServer = null;
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l.reindexFailed(e.toString())),
          backgroundColor: AppTheme.error,
        ),
      );
      return false;
    } finally {
      if (mounted) {
        setState(() {
          _isIndexing = false;
          _indexCurrentFile = '';
        });
      }
    }
  }

  Future<void> _pickRootDirectory(String mcpType) async {
    // On Android, ensure storage permission first
    if (Platform.isAndroid) {
      final granted = await StoragePermission.request(context);
      if (!mounted || !granted) return;
    }
    final selected = await FilePicker.getDirectoryPath(
      dialogTitle: L.of(context).chooseDirectory,
    );
    if (!mounted || selected == null || selected.trim().isEmpty) return;
    // Append to existing paths (avoid duplicates)
    final existing = (_mcpInitParams[mcpType]?['rootPath'] as String? ?? '')
        .split(';')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet();
    existing.add(selected);
    setState(() {
      _mcpInitParams[mcpType] = {
        ...(_mcpInitParams[mcpType] ?? {}),
        'rootPath': existing.join(';'),
      };
    });
    if (mcpType == 'document') {
      _savePersistedDocumentSearchSettings(rootPath: existing.join(';'));
    }
  }

  // ── Chat view (after chat starts) ──

  Widget _buildChatView(ThemeData theme, ActiveTaskState? taskState) {
    final l = L.of(context);

    if (taskState == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (taskState.hasError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: 64,
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                taskState.error!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _resetChat,
                icon: const Icon(Icons.restart_alt),
                label: Text(l.resetChat),
              ),
            ],
          ),
        ),
      );
    }

    if (taskState.isInitializing) {
      final phaseLabel = switch (taskState.phase) {
        ActiveTaskPhase.configuringLlm => L.of(context).phaseConfiguringLlm,
        ActiveTaskPhase.connectingExternalMcp =>
          L.of(context).phaseConnectingExternalMcp,
        ActiveTaskPhase.connectingInternalMcp =>
          L.of(context).phaseConnectingInternalMcp,
        _ => taskState.statusMessage,
      };

      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Text(phaseLabel, style: theme.textTheme.bodyLarge),
            if (taskState.loadingProgress != null) ...[
              const SizedBox(height: 16),
              SizedBox(
                width: 240,
                // llamadart gives no intermediate callbacks — show indeterminate
                // bar at 0% so it doesn't look permanently frozen.
                child: LinearProgressIndicator(
                  value: taskState.loadingProgress! > 0.0
                      ? taskState.loadingProgress
                      : null,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                taskState.loadingProgress! > 0.0
                    ? L
                          .of(context)
                          .loadingModelProgress(
                            (taskState.loadingProgress! * 100).round(),
                          )
                    : L
                          .of(context)
                          .loadingModelProgress(0)
                          .replaceFirst('0%', '…'),
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      );
    }

    final chatService = taskState.chatService!;
    final uiStyle = AppPreferencesService.instance.uiStyle;
    final isDesktop =
        uiStyle == 'modern' && MediaQuery.sizeOf(context).width >= 900;

    Widget chatContent = Column(
      children: [
        // Active skill chip (shown in chat view too)
        if (_activeSkill != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: Card(
                    color: Colors.amber.withAlpha(25),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side: BorderSide(color: Colors.amber.withAlpha(80)),
                    ),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: _showSkillWizardDialog,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.auto_awesome,
                              color: Colors.amber,
                              size: 16,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Skill: ${_activeSkill!.name}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const Icon(
                              Icons.chevron_right,
                              size: 16,
                              color: Colors.amber,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  tooltip: 'Remove skill',
                  onPressed: () {
                    setState(() => _activeSkill = null);
                    _updateSkillsSection();
                  },
                ),
              ],
            ),
          ),
        // System prompt info bar (tap to view/edit)
        if (taskState.effectiveSystemPrompt != null &&
            taskState.effectiveSystemPrompt!.isNotEmpty)
          Material(
            color: theme.colorScheme.primaryContainer.withAlpha(80),
            child: InkWell(
              onTap: () =>
                  _showEditSystemPromptDialog(taskState.effectiveSystemPrompt!),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.edit_note,
                      size: 16,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l.systemPromptTapToEdit(l.systemPrompt),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                    if (taskState.toolCount > 0)
                      Builder(
                        builder: (ctx) {
                          // Show the union of per-step enabled tools when steps restrict tools,
                          // otherwise fall back to the total available tools count.
                          final stepFilter = _enabledToolNamesFromPrompt(
                            _chatInputController.text,
                          );
                          final displayCount = stepFilter != null
                              ? stepFilter.length
                              : taskState.toolCount;
                          return ActionChip(
                            label: Text(l.toolsSelected(displayCount)),
                            avatar: const Icon(Icons.build, size: 16),
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            onPressed: () => _showActiveToolsDialog(taskState),
                          );
                        },
                      ),
                  ],
                ),
              ),
            ),
          ),

        // Session usage stats bar
        ListenableBuilder(
          listenable: chatService,
          builder: (context, _) {
            final tokens = chatService.cumulativeTokens;
            final sentChars = chatService.totalSentChars;
            final stats = chatService.getChatStats();
            final toolCalls = stats['toolCalls'] as int? ?? 0;
            final threshold = chatService.llmService.tokenWarningThreshold;
            final isWarning = tokens > 0 && tokens >= threshold;

            if (tokens == 0 && sentChars == 0) return const SizedBox.shrink();

            return Container(
              color: isWarning
                  ? theme.colorScheme.errorContainer.withAlpha(200)
                  : theme.colorScheme.surfaceContainerHighest.withAlpha(120),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  if (isWarning) ...[
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 14,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: 4),
                  ],
                  Icon(
                    Icons.blur_on_rounded,
                    size: 14,
                    color: isWarning
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _formatCompactNumber(tokens),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: isWarning
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurfaceVariant,
                      fontWeight: isWarning
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                  const SizedBox(width: 2),
                  Text(
                    'tokens',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: isWarning
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurfaceVariant.withAlpha(160),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Icon(
                    Icons.upload_outlined,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${_formatCompactNumber(sentChars)} chars sent',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (toolCalls > 0) ...[
                    const SizedBox(width: 12),
                    Icon(
                      Icons.build_outlined,
                      size: 14,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '$toolCalls tool calls',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  IconButton(
                    icon: const Icon(Icons.query_stats, size: 16),
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Session statistics',
                    onPressed: () => _showSessionStatsDialog(chatService),
                  ),
                  const Spacer(),
                  if (isWarning)
                    Text(
                      'Token limit reached',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.error,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                ],
              ),
            );
          },
        ),

        // Playground hint
        if (_messages.isEmpty)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Card(
              color: AppTheme.accent.withAlpha(20),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  l.playgroundHint,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppTheme.accent,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),

        // Messages list
        Expanded(
          child: _messages.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.chat_bubble_outline,
                        size: 64,
                        color: theme.colorScheme.outline,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        l.chatSendHint,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  itemCount: _messages.length,
                  itemBuilder: (context, index) {
                    final message = _messages[_messages.length - 1 - index];
                    final isUser = message.role == ChatRole.user;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: MultimediaMessageWidget(
                        message: message,
                        isUser: isUser,
                        enableHorizontalScrolling: true,
                      ),
                    );
                  },
                ),
        ),

        // Input area
        MultimediaInputWidget(
          key: ValueKey(_chatInputKey),
          chatService: chatService,
          onSendMessage: (msg) => _onSendMessage(msg, chatService),
          isEnabled: !chatService.isProcessing,
          initialText: _pendingInputText,
          controller: _chatInputController,
          onToolSelectionChanged: () =>
              _updateSkillsSection(_chatInputController.text),
        ),
      ],
    );

    if (isDesktop) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final totalWidth = constraints.maxWidth;
          final minChatWidth = 300.0;
          final minInspectorWidth = 250.0;

          double chatWidth = totalWidth * _chatFraction;
          if (chatWidth < minChatWidth) {
            chatWidth = minChatWidth;
          }
          if (totalWidth - chatWidth - 8 < minInspectorWidth) {
            chatWidth = totalWidth - minInspectorWidth - 8;
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: chatWidth, child: chatContent),
              GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragUpdate: (details) {
                  setState(() {
                    _chatFraction += details.delta.dx / totalWidth;
                    if (_chatFraction < 0.2) _chatFraction = 0.2;
                    if (_chatFraction > 0.85) _chatFraction = 0.85;
                  });
                },
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeLeftRight,
                  child: Container(
                    width: 8,
                    color: theme.dividerColor.withValues(alpha: 0.1),
                    child: Center(
                      child: Container(width: 1, color: theme.dividerColor),
                    ),
                  ),
                ),
              ),
              Expanded(child: _buildDesktopInspector(theme, chatService)),
            ],
          );
        },
      );
    }
    return chatContent;
  }

  Widget _buildDesktopInspector(ThemeData theme, ChatService chatService) {
    final stats = chatService.getChatStats();
    final model = (stats['model'] as String?) ?? 'unknown';
    final tokens = chatService.cumulativeTokens;
    final toolCalls = stats['toolCalls'] as int? ?? 0;
    final threshold = chatService.llmService.tokenWarningThreshold;
    final progress = threshold > 0 ? (tokens / threshold).clamp(0.0, 1.0) : 0.0;
    final isWarning = tokens >= threshold;

    final providerKey = (stats['providerKey'] as String?) ?? '';
    final price = getModelTokenPrice(providerKey: providerKey, model: model);
    _checkAndRefreshPrice(providerKey, model);
    final isEmbedded =
        chatService.llmService.currentProvider.name == 'embedded';
    final isOllama = chatService.llmService.currentProvider.name == 'ollama';
    final isSlm = chatService.llmService.isSlm;
    final showCost = price != null && !isEmbedded && !isOllama && !isSlm;

    return Container(
      color: theme.scaffoldBackgroundColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Inspector Header
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const Icon(Icons.analytics_outlined, color: Color(0xFF7C3AED)),
                const SizedBox(width: 8),
                Text(
                  'Agent Inspector',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: chatService.isProcessing
                        ? Colors.green
                        : Colors.grey,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  chatService.isProcessing ? 'Processing' : 'Idle',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.grey,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Model info card
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Active Model',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: Colors.grey,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            model,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Provider: ${chatService.llmService.currentProvider.name}',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Token Usage card
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Token Usage',
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: Colors.grey,
                                ),
                              ),
                              Text(
                                '$tokens / $threshold',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          LinearProgressIndicator(
                            value: progress,
                            color: isWarning
                                ? Colors.red
                                : const Color(0xFF7C3AED),
                            backgroundColor: Colors.grey.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          if (showCost) ...[
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          'Price/1M: \$${price.inputPer1MUsd.toStringAsFixed(2)} in / \$${price.outputPer1MUsd.toStringAsFixed(2)} out',
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                color: theme
                                                    .colorScheme
                                                    .onSurfaceVariant
                                                    .withValues(alpha: 0.7),
                                                fontSize: 11,
                                              ),
                                        ),
                                      ),
                                      if (_priceIsLive) ...[
                                        const SizedBox(width: 4),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 4,
                                            vertical: 1,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.green.withValues(
                                              alpha: 0.15,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                            border: Border.all(
                                              color: Colors.green.withValues(
                                                alpha: 0.4,
                                              ),
                                            ),
                                          ),
                                          child: const Text(
                                            'live',
                                            style: TextStyle(
                                              fontSize: 9,
                                              color: Colors.green,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                Text(
                                  'Cost: ${_formatUsd((stats['sessionCostUsd'] as double?) ?? 0)}',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: const Color(0xFF7C3AED),
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Execution stats row
                  Row(
                    children: [
                      Expanded(
                        child: Card(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Tool Calls',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: Colors.grey,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '$toolCalls',
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Card(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Sent Chars',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: Colors.grey,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  _formatCompactNumber(
                                    chatService.totalSentChars,
                                  ),
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Live logs header with sorting/clearing controls
                  Row(
                    children: [
                      Text(
                        'Live Execution Logs',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: Icon(
                          _logsAscending
                              ? Icons.arrow_upward
                              : Icons.arrow_downward,
                        ),
                        tooltip: _logsAscending ? 'Ascending' : 'Descending',
                        visualDensity: VisualDensity.compact,
                        onPressed: () {
                          setState(() {
                            _logsAscending = !_logsAscending;
                          });
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.clear_all),
                        tooltip: 'Clear logs',
                        visualDensity: VisualDensity.compact,
                        onPressed: () {
                          setState(() {
                            _logsClearedAt = DateTime.now();
                          });
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // Logs list builder/container (Expanded to occupy all available space at bottom!)
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: theme.brightness == Brightness.dark
                            ? Colors.black26
                            : Colors.grey[100],
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: theme.dividerColor),
                      ),
                      child: ListenableBuilder(
                        listenable: chatService,
                        builder: (context, _) {
                          final List<_ExecEntry> entries = [];
                          for (final msg in _messages) {
                            if (_logsClearedAt != null &&
                                !msg.timestamp.isAfter(_logsClearedAt!)) {
                              continue;
                            }
                            switch (msg.role) {
                              case ChatRole.system:
                                final content = msg.content.trim();
                                if (content.isNotEmpty) {
                                  final oneLine = content.replaceAll('\n', ' ');
                                  final preview = oneLine.length > 80
                                      ? '${oneLine.substring(0, 80)}…'
                                      : oneLine;
                                  entries.add(
                                    _ExecEntry(
                                      type: 'system',
                                      text: 'System prompt: $preview',
                                      details: content,
                                      timestamp: msg.timestamp,
                                    ),
                                  );
                                }
                                break;
                              case ChatRole.user:
                                final content = msg.content.trim();
                                if (content.isNotEmpty) {
                                  entries.add(
                                    _ExecEntry(
                                      type: 'info',
                                      text: 'User prompt: $content',
                                      timestamp: msg.timestamp,
                                    ),
                                  );
                                }
                                break;
                              case ChatRole.assistant:
                                final content = msg.content.trim();
                                const toolCallingPlaceholder =
                                    'Calling tools to retrieve the requested information...';
                                if (content.isNotEmpty &&
                                    content != toolCallingPlaceholder) {
                                  if (content.toLowerCase().startsWith(
                                    'ai error',
                                  )) {
                                    entries.add(
                                      _ExecEntry(
                                        type: 'error',
                                        text: content,
                                        timestamp: msg.timestamp,
                                      ),
                                    );
                                  } else {
                                    entries.add(
                                      _ExecEntry(
                                        type: 'assistant',
                                        text: content,
                                        timestamp: msg.timestamp,
                                      ),
                                    );
                                  }
                                }
                                break;
                              case ChatRole.tool:
                                final name = msg.lastCalledToolName ?? 'Tool';
                                final argsRaw =
                                    msg.content.contains('\nArguments: ')
                                    ? msg.content
                                          .split('\nArguments: ')
                                          .last
                                          .trim()
                                    : '';
                                final argsPreview = argsRaw.length > 100
                                    ? '${argsRaw.substring(0, 100)}…'
                                    : argsRaw;
                                final raw =
                                    msg.toolResult?.content.isNotEmpty == true
                                    ? (msg.toolResult!.content.first.text ?? '')
                                    : '';
                                final resultPreview = raw.length > 150
                                    ? '${raw.substring(0, 150)}…'
                                    : raw;
                                final lines = [
                                  if (argsPreview.isNotEmpty)
                                    '$name($argsPreview)'
                                  else
                                    name,
                                  if (resultPreview.isNotEmpty)
                                    '→ $resultPreview',
                                ];
                                entries.add(
                                  _ExecEntry(
                                    type: 'tool',
                                    text: lines.join('\n'),
                                    details: raw.isNotEmpty ? raw : null,
                                    timestamp: msg.timestamp,
                                  ),
                                );
                                break;
                            }
                          }

                          if (entries.isEmpty) {
                            return const Center(
                              child: Text(
                                'No playground logs yet.',
                                style: TextStyle(
                                  color: Colors.grey,
                                  fontSize: 12,
                                ),
                              ),
                            );
                          }

                          if (_logsAscending &&
                              entries.length != _lastLogsCount) {
                            _lastLogsCount = entries.length;
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (_logsScrollController.hasClients) {
                                _logsScrollController.animateTo(
                                  _logsScrollController
                                      .position
                                      .maxScrollExtent,
                                  duration: const Duration(milliseconds: 200),
                                  curve: Curves.easeOut,
                                );
                              }
                            });
                          } else if (!_logsAscending) {
                            _lastLogsCount = entries.length;
                          }

                          return ListView.builder(
                            controller: _logsScrollController,
                            padding: const EdgeInsets.all(8),
                            itemCount: entries.length,
                            itemBuilder: (context, idx) {
                              final entry = _logsAscending
                                  ? entries[idx]
                                  : entries[entries.length - 1 - idx];
                              return _buildEntryTile(
                                entry,
                                theme.brightness == Brightness.dark,
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Format a number compactly: 1234 → "1,234", 1200000 → "1.2M"
  String _formatCompactNumber(int n) {
    if (n >= 1000000) {
      final m = n / 1000000;
      return '${m.toStringAsFixed(m >= 10 ? 1 : 2)}M';
    }
    if (n >= 1000) {
      final k = n / 1000;
      return '${k.toStringAsFixed(k >= 100
          ? 0
          : k >= 10
          ? 1
          : 1)}K';
    }
    return n.toString();
  }

  String _formatUsd(double value) => '\$${value.toStringAsFixed(4)}';

  void _showSessionStatsDialog(ChatService chatService) {
    final stats = chatService.getChatStats();
    final providerKey = (stats['providerKey'] as String?) ?? '';
    final model = (stats['model'] as String?) ?? '';
    final lastRequestUsageEstimated =
        (stats['lastRequestUsageEstimated'] as bool?) ?? false;
    final estimatedUsageRequests =
        (stats['estimatedUsageRequests'] as int?) ?? 0;
    final price = getModelTokenPrice(providerKey: providerKey, model: model);

    showDialog<void>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return AlertDialog(
          title: const Text('Session statistics'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Provider: ${chatService.llmService.currentProvider.name}',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 4),
                Text('Model: $model', style: theme.textTheme.bodyMedium),
                if (estimatedUsageRequests > 0) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: theme.colorScheme.error.withValues(alpha: 0.45),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          size: 16,
                          color: theme.colorScheme.onErrorContainer,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            lastRequestUsageEstimated
                                ? 'Usage source: Estimated for latest request'
                                : 'Usage source: Mixed (estimated requests: $estimatedUsageRequests)',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onErrorContainer,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const Divider(height: 20),
                Text(
                  'Cumulative Tokens: ${stats['cumulativeTokens'] ?? 0}',
                  style: theme.textTheme.bodyMedium,
                ),
                Text(
                  'Prompt Tokens: ${stats['cumulativePromptTokens'] ?? 0}',
                  style: theme.textTheme.bodyMedium,
                ),
                Text(
                  'Completion Tokens: ${stats['cumulativeCompletionTokens'] ?? 0}',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  'Last Request Tokens: ${stats['lastRequestTokens'] ?? 0}',
                  style: theme.textTheme.bodyMedium,
                ),
                Text(
                  'Last Request Cost: ${_formatUsd((stats['lastRequestCostUsd'] as double?) ?? 0)}',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'Session Cost (est.): ${_formatUsd((stats['sessionCostUsd'] as double?) ?? 0)}',
                  style: theme.textTheme.bodyMedium,
                ),
                if (price != null) ...[
                  const Divider(height: 20),
                  Text('Price / 1M tokens', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(
                    'Input: \$${price.inputPer1MUsd.toStringAsFixed(2)}',
                    style: theme.textTheme.bodyMedium,
                  ),
                  Text(
                    'Output: \$${price.outputPer1MUsd.toStringAsFixed(2)}',
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showEditSystemPromptDialog(String ignored) async {
    // Show the dialog with the current (live) system prompt content — do NOT
    // re-run _updateSkillsSection here because _chatInputController holds the
    // new-message draft (usually empty), which has no per-step tool filters and
    // would replace the correct skills that were built from the initial prompt
    // when the chat started.
    if (!mounted) return;
    showDialog<(String, String)>(
      context: context,
      builder: (ctx) => _SystemPromptEditDialog(
        userPrompt: _systemPromptUserCtrl.text,
        skillsPrompt: _systemPromptSkillsCtrl.text,
      ),
    ).then((result) async {
      if (result != null && mounted) {
        setState(() {
          _systemPromptUserCtrl.text = result.$1;
          _systemPromptSkillsCtrl.text = result.$2;
        });
        await _resetChat();
        await _startChat();
      }
    });
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
}

// -- Private helper: system-prompt edit dialog ---------------------------

class _SystemPromptEditDialog extends StatefulWidget {
  final String userPrompt;
  final String skillsPrompt;
  const _SystemPromptEditDialog({
    required this.userPrompt,
    required this.skillsPrompt,
  });

  @override
  State<_SystemPromptEditDialog> createState() =>
      _SystemPromptEditDialogState();
}

class _SystemPromptEditDialogState extends State<_SystemPromptEditDialog> {
  late final TextEditingController _userCtrl;
  late final TextEditingController _skillsCtrl;
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    _userCtrl = TextEditingController(text: widget.userPrompt);
    _skillsCtrl = TextEditingController(text: widget.skillsPrompt);
  }

  @override
  void dispose() {
    _userCtrl.dispose();
    _skillsCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final theme = Theme.of(context);
    final screenSize = MediaQuery.of(context).size;
    final isMobile = screenSize.width < 600;
    final effectiveMaximized = _isMaximized || isMobile;

    return Dialog(
      insetPadding: effectiveMaximized
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      clipBehavior: Clip.antiAlias,
      shape: effectiveMaximized
          ? const RoundedRectangleBorder()
          : RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: SizedBox(
        width: effectiveMaximized ? screenSize.width : 680,
        height: effectiveMaximized ? screenSize.height : null,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: effectiveMaximized
                ? MainAxisSize.max
                : MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l.systemPrompt,
                      style: theme.textTheme.headlineSmall,
                    ),
                  ),
                  if (!isMobile)
                    IconButton(
                      icon: Icon(
                        _isMaximized ? Icons.fullscreen_exit : Icons.fullscreen,
                      ),
                      tooltip: _isMaximized ? 'Restore' : 'Maximize',
                      onPressed: () =>
                          setState(() => _isMaximized = !_isMaximized),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Flexible(
                flex: 3,
                child: TextField(
                  controller: _userCtrl,
                  maxLines: effectiveMaximized ? null : 8,
                  expands: effectiveMaximized,
                  textAlignVertical: TextAlignVertical.top,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    labelText: l.systemPrompt,
                    alignLabelWithHint: true,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // Skills section
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
                  if (_skillsCtrl.text.isNotEmpty)
                    InkWell(
                      onTap: () => setState(() => _skillsCtrl.text = ''),
                      borderRadius: BorderRadius.circular(4),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.clear,
                              size: 13,
                              color: Colors.grey[500],
                            ),
                            const SizedBox(width: 2),
                            Text(
                              'Clear',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey[500],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Flexible(
                flex: 2,
                child: TextField(
                  controller: _skillsCtrl,
                  maxLines: effectiveMaximized ? null : 5,
                  expands: effectiveMaximized,
                  textAlignVertical: TextAlignVertical.top,
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
                    fillColor: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.4),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(l.cancel),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, (
                      _userCtrl.text,
                      _skillsCtrl.text,
                    )),
                    child: Text(l.applyAndReset),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
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

class _LoadWorkflowsDialog extends ConsumerStatefulWidget {
  const _LoadWorkflowsDialog();

  @override
  ConsumerState<_LoadWorkflowsDialog> createState() =>
      _LoadWorkflowsDialogState();
}

class _LoadWorkflowsDialogState extends ConsumerState<_LoadWorkflowsDialog> {
  late final TextEditingController _searchController;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.trim().toLowerCase();
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final allTasks = ref.watch(taskListProvider).value ?? [];
    // Filter showing only the workflows with one agent!
    final workflows = allTasks
        .where((task) => task.agents.length == 1)
        .toList();

    // Sort by name case-insensitively
    workflows.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );

    // Filter by search query
    final filteredWorkflows = _searchQuery.isEmpty
        ? workflows
        : workflows.where((task) {
            return task.name.toLowerCase().contains(_searchQuery) ||
                (task.description?.toLowerCase().contains(_searchQuery) ??
                    false) ||
                task.prompt.toLowerCase().contains(_searchQuery);
          }).toList();

    final l = L.of(context);

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 560,
          minHeight: MediaQuery.sizeOf(context).height * 0.78,
          maxHeight: MediaQuery.sizeOf(context).height * 0.78,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.max,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 8, 0),
              child: Row(
                children: [
                  const Icon(Icons.bookmarks_outlined),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Load Workflows',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 20),
            // Search field
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: l.searchTasks,
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () => _searchController.clear(),
                        )
                      : null,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
            if (filteredWorkflows.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                child: Text(
                  _searchQuery.isNotEmpty
                      ? 'No matching workflows found.'
                      : 'No saved workflows yet.\nUse "Save Skill / Workflow" in the toolbar to save the current tools & prompts.',
                  textAlign: TextAlign.center,
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: filteredWorkflows.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (ctx, i) {
                    final task = filteredWorkflows[i];
                    final toolCount =
                        task.internalMcps.length + task.mcpTools.length;
                    final date =
                        '${task.createdAt.year}-${task.createdAt.month.toString().padLeft(2, '0')}-${task.createdAt.day.toString().padLeft(2, '0')}';
                    final promptPreview = task.prompt.isNotEmpty
                        ? '"${task.prompt.substring(0, task.prompt.length.clamp(0, 60))}${task.prompt.length > 60 ? '…' : ''}"'
                        : null;
                    return ListTile(
                      title: Text(
                        task.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        [
                          date,
                          '$toolCount tool${toolCount == 1 ? '' : 's'}',
                          ?promptPreview,
                        ].join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                      onTap: () => Navigator.pop(context, task),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline, size: 20),
                        tooltip: 'Delete',
                        onPressed: () async {
                          final confirm = await showDialog<bool>(
                            context: context,
                            builder: (c) => AlertDialog(
                              title: const Text('Delete Workflow'),
                              content: Text('Delete "${task.name}"?'),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(c, false),
                                  child: const Text('Cancel'),
                                ),
                                FilledButton(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: Colors.red,
                                  ),
                                  onPressed: () => Navigator.pop(c, true),
                                  child: const Text('Delete'),
                                ),
                              ],
                            ),
                          );
                          if (confirm == true && context.mounted) {
                            await ref
                                .read(taskListProvider.notifier)
                                .deleteTask(task.id);
                          }
                        },
                      ),
                    );
                  },
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
