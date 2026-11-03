import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dart_mcp_core/dart_mcp_core.dart';
import 'package:flutter_ui_mcp_core/flutter_ui_mcp_core.dart';

import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../database/duckdb_service.dart';
import '../mcp/internal_mcp_registry.dart';
import '../mcp/servers/document_mcp_server.dart';
import '../mcp/servers/website_search_mcp_server.dart';
import '../providers/llm_settings_provider.dart';
import '../services/data_sources_settings_service.dart';
import '../services/llm_settings_service.dart' as tk_llm;
import '../models/named_llm_profile.dart';
import '../models/subagent_definition.dart';
import '../services/subagent_database_service.dart';
import '../utils/storage_permission.dart';
import 'agent_llm_selector_widget.dart';

/// Custom settings dialog for TealKit Assistant mode.
///
/// Combines the full power of:
/// 1. Agent & Tools configuration from [PlaygroundController].
/// 2. TealKit's multi-LLM profile array ([AgentLlmSelectorWidget]) with on-device Embedded GGUF models.
/// 3. MCP Servers management and Registry tabs.
class TealKitAssistantSettingsDialog extends ConsumerStatefulWidget {
  final PlaygroundController controller;
  final int initialTabIndex;
  final VoidCallback? onClose;
  final List<SystemPromptTemplate>? systemPromptTemplates;
  final bool? showSystemPromptTemplates;

  const TealKitAssistantSettingsDialog({
    super.key,
    required this.controller,
    this.initialTabIndex = 0,
    this.onClose,
    this.systemPromptTemplates,
    this.showSystemPromptTemplates,
  });

  @override
  ConsumerState<TealKitAssistantSettingsDialog> createState() =>
      _TealKitAssistantSettingsDialogState();
}

class _TealKitAssistantSettingsDialogState
    extends ConsumerState<TealKitAssistantSettingsDialog> {
  final _formKey = GlobalKey<FormState>();

  // ─── Agent & Tools tab controllers ───
  late final TextEditingController _systemPromptCtrl;
  late bool _chatMode;

  // ─── LLM tab controllers (for raw/custom provider override) ───
  String? _selectedProfileId;
  String _selectedProviderKey = 'gemini';
  bool _isCustomOverride = false;
  LlmProvider _customProvider = LlmProvider.gemini;

  final _modelCtrl = TextEditingController();
  final _apiKeyCtrl = TextEditingController();
  final _baseUrlCtrl = TextEditingController();
  final _tempCtrl = TextEditingController(text: '0.2');
  final _maxTokensCtrl = TextEditingController(text: '0');
  final _maxToolOutputSizeCtrl = TextEditingController(text: '2560000');
  final _tokenWarningThresholdCtrl = TextEditingController(text: '1500000');
  final _topKCtrl = TextEditingController();
  final _topPCtrl = TextEditingController();
  final _repeatPenaltyCtrl = TextEditingController();
  final _seedCtrl = TextEditingController();

  bool _isSlm = false;
  bool _isMultiModal = true;
  bool _thinking = false;
  bool _useNativeToolCall = true;
  bool _useSafeToolCall = false;
  bool _useStreaming = false;

  final Map<LlmProvider, _FieldCache> _providerCache = {};
  final Set<String> _expandedToolGroups = {};

  // ─── Document indexing state ───
  bool _isIndexingDocuments = false;
  int _docIndexedCount = 0;
  int _docIndexTotal = 0;
  String _docIndexCurrentFile = '';
  DocumentMcpServer? _activeDocIndexServer;
  DateTime? _docLastIndexed;

  // ─── Website search indexing state ───
  bool _isIndexingWebsites = false;
  int _webIndexedCount = 0;
  int _webIndexTotal = 0;
  String _webIndexCurrentUrl = '';
  WebsiteSearchMcpServer? _activeWebIndexServer;
  DateTime? _webLastIndexed;
  final TextEditingController _websiteUrlInputCtrl = TextEditingController();
  late final TextEditingController _websiteMaxPagesCtrl;

  IconData _mcpIcon(String name) {
    return switch (name) {
      'cloud' => Icons.cloud,
      'description' => Icons.description,
      'email' || 'mail' => Icons.email,
      'search' => Icons.search,
      'language' => Icons.language,
      'build' => Icons.handyman_outlined,
      'terminal' || 'code' => Icons.terminal,
      _ => Icons.extension,
    };
  }

  @override
  void initState() {
    super.initState();
    _docLastIndexed =
        DataSourcesSettingsService.instance.documentIndexLastIndexedAt;
    _webLastIndexed =
        DataSourcesSettingsService.instance.websiteIndexLastIndexedAt;
    _websiteMaxPagesCtrl = TextEditingController(
      text: DataSourcesSettingsService.instance.websiteIndexMaxPages.toString(),
    );
    _loadWebsiteMaxPages();
    _loadIndexTimestampsFromDb();
    widget.controller.permissions.reload();
    _systemPromptCtrl = TextEditingController(
      text: widget.controller.systemPrompt,
    );
    _chatMode = widget.controller.chatMode;
    widget.controller.addListener(_onControllerChange);

    _syncFromCurrentLlm();
  }

  Future<void> _loadIndexTimestampsFromDb() async {
    try {
      final db = DuckDbService();
      if (_docLastIndexed == null) {
        final rows = await db.query(
          "SELECT MAX(indexed_at) FROM document_index WHERE content_text IS NOT NULL AND content_text != ''",
        );
        if (rows.isNotEmpty &&
            rows.first.isNotEmpty &&
            rows.first.first != null) {
          final raw = rows.first.first.toString();
          final parsed = DateTime.tryParse(raw);
          if (parsed != null && mounted) {
            setState(() => _docLastIndexed = parsed);
          }
        }
      }
      if (_webLastIndexed == null) {
        final rows = await db.query(
          "SELECT MAX(indexed_at) FROM website_index WHERE content_text IS NOT NULL AND content_text != ''",
        );
        if (rows.isNotEmpty &&
            rows.first.isNotEmpty &&
            rows.first.first != null) {
          final raw = rows.first.first.toString();
          final parsed = DateTime.tryParse(raw);
          if (parsed != null && mounted) {
            setState(() => _webLastIndexed = parsed);
          }
        }
      }
    } catch (_) {}
  }

  String _formatLastIndexed(DateTime? dt) {
    if (dt == null) return 'Never indexed';
    final local = dt.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    final ss = local.second.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm:$ss';
  }

  @override
  void dispose() {
    _activeDocIndexServer?.cancelIndexing();
    _activeWebIndexServer?.cancelIndexing();
    _websiteUrlInputCtrl.dispose();
    _websiteMaxPagesCtrl.dispose();
    widget.controller.removeListener(_onControllerChange);
    _systemPromptCtrl.dispose();
    _modelCtrl.dispose();
    _apiKeyCtrl.dispose();
    _baseUrlCtrl.dispose();
    _tempCtrl.dispose();
    _maxTokensCtrl.dispose();
    _maxToolOutputSizeCtrl.dispose();
    _tokenWarningThresholdCtrl.dispose();
    _topKCtrl.dispose();
    _topPCtrl.dispose();
    _repeatPenaltyCtrl.dispose();
    _seedCtrl.dispose();
    super.dispose();
  }

  void _onControllerChange() {
    if (mounted) setState(() {});
  }

  void _syncFromCurrentLlm() {
    final llmSettings = ref.read(llmSettingsProvider);
    final activeConfig = widget.controller.activeLlmConfig;

    // Check if active matches any configured TealKit profile
    NamedLlmProfile? matchingProfile;
    if (llmSettings.selectedProfile != null &&
        _matchesProfile(activeConfig, llmSettings.selectedProfile!)) {
      matchingProfile = llmSettings.selectedProfile;
    } else {
      for (final p in llmSettings.profiles) {
        if (_matchesProfile(activeConfig, p)) {
          matchingProfile = p;
          break;
        }
      }
    }

    if (matchingProfile != null) {
      _selectedProfileId = matchingProfile.id;
      _isCustomOverride = false;
    } else {
      _selectedProfileId = null;
      _isCustomOverride = true;
      _selectedProviderKey = activeConfig.provider.name;
      _customProvider = activeConfig.provider;
      _modelCtrl.text = activeConfig.model;
      _apiKeyCtrl.text = activeConfig.apiKey;
      _baseUrlCtrl.text = activeConfig.baseUrl;
      _tempCtrl.text = activeConfig.temperature.toString();
      _maxTokensCtrl.text = activeConfig.maxTokens.toString();
      _isSlm = activeConfig.isSlm;
      _isMultiModal = activeConfig.isMultiModal;
      _thinking = activeConfig.thinking;
      _useNativeToolCall = activeConfig.useNativeToolCall;
      _useSafeToolCall = activeConfig.useSafeToolCall;
      _useStreaming = activeConfig.useStreaming;
    }
  }

  bool _matchesProfile(LlmConfig config, NamedLlmProfile profile) {
    return _toTealKitProvider(config.provider) == profile.provider &&
        config.model == profile.model;
  }

  static LlmConfig profileToLlmConfig(NamedLlmProfile profile) {
    return LlmConfig(
      provider: _fromTealKitProvider(profile.provider),
      model: profile.model,
      apiKey: profile.apiKey,
      baseUrl: profile.baseUrl,
      temperature: profile.temperature,
      maxTokens: profile.maxTokens,
      maxToolOutputSize: profile.maxToolOutputSize,
      tokenWarningThreshold: profile.tokenWarningThreshold,
      isSlm: profile.isSlm,
      isMultiModal: profile.isMultiModal,
      thinking: profile.thinking,
      useNativeToolCall: profile.useNativeToolCall,
      useSafeToolCall: profile.useSafeToolCall,
      topK: profile.topK,
      topP: profile.topP,
      repeatPenalty: profile.repeatPenalty,
      seed: profile.seed,
    );
  }

  static LlmProvider _fromTealKitProvider(tk_llm.LlmProvider p) {
    switch (p) {
      case tk_llm.LlmProvider.none:
        return LlmProvider.none;
      case tk_llm.LlmProvider.gemini:
        return LlmProvider.gemini;
      case tk_llm.LlmProvider.openai:
        return LlmProvider.openai;
      case tk_llm.LlmProvider.claude:
        return LlmProvider.claude;
      case tk_llm.LlmProvider.mistral:
        return LlmProvider.mistral;
      case tk_llm.LlmProvider.ollama:
        return LlmProvider.ollama;
      case tk_llm.LlmProvider.openaiCompatible:
        return LlmProvider.openaiCompatible;
      case tk_llm.LlmProvider.embedded:
        return LlmProvider.embedded;
    }
  }

  static tk_llm.LlmProvider _toTealKitProvider(LlmProvider p) {
    switch (p) {
      case LlmProvider.none:
        return tk_llm.LlmProvider.none;
      case LlmProvider.gemini:
        return tk_llm.LlmProvider.gemini;
      case LlmProvider.openai:
        return tk_llm.LlmProvider.openai;
      case LlmProvider.claude:
        return tk_llm.LlmProvider.claude;
      case LlmProvider.mistral:
        return tk_llm.LlmProvider.mistral;
      case LlmProvider.ollama:
        return tk_llm.LlmProvider.ollama;
      case LlmProvider.openaiCompatible:
        return tk_llm.LlmProvider.openaiCompatible;
      case LlmProvider.embedded:
        return tk_llm.LlmProvider.embedded;
    }
  }

  static LlmProvider _providerKeyToLlmProvider(String key) {
    switch (key) {
      case 'gemini':
        return LlmProvider.gemini;
      case 'openai':
        return LlmProvider.openai;
      case 'claude':
        return LlmProvider.claude;
      case 'mistral':
        return LlmProvider.mistral;
      case 'ollama':
        return LlmProvider.ollama;
      case 'openai_compatible':
        return LlmProvider.openaiCompatible;
      case 'embedded':
        return LlmProvider.embedded;
      default:
        return LlmProvider.none;
    }
  }

  void _applySelectedProfile(String profileId) {
    final llmSettings = ref.read(llmSettingsProvider);
    final profile = llmSettings.getProfile(profileId);
    if (profile == null) return;

    llmSettings.selectProfile(profileId);
    final cfg = profileToLlmConfig(profile);
    widget.controller.updateLlmConfig(cfg);
    widget.controller.customLlmConfig = null;

    setState(() {
      _selectedProfileId = profileId;
      _isCustomOverride = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Switched to "${profile.name}" (${profile.model})'),
      ),
    );
  }

  Future<void> _saveCustomLlmSettings() async {
    final tempVal = double.tryParse(_tempCtrl.text.trim()) ?? 0.2;
    final maxTokensVal = int.tryParse(_maxTokensCtrl.text.trim()) ?? 0;
    final maxToolSizeVal =
        int.tryParse(_maxToolOutputSizeCtrl.text.trim()) ?? 2560000;
    final tokenWarningVal =
        int.tryParse(_tokenWarningThresholdCtrl.text.trim()) ?? 1500000;

    final customConfig = LlmConfig(
      provider: _customProvider,
      model: _modelCtrl.text.trim(),
      apiKey: _apiKeyCtrl.text.trim(),
      baseUrl: _baseUrlCtrl.text.trim(),
      temperature: tempVal,
      maxTokens: maxTokensVal,
      maxToolOutputSize: maxToolSizeVal,
      tokenWarningThreshold: tokenWarningVal,
      topP: double.tryParse(_topPCtrl.text.trim()),
      topK: int.tryParse(_topKCtrl.text.trim()),
      repeatPenalty: double.tryParse(_repeatPenaltyCtrl.text.trim()),
      seed: int.tryParse(_seedCtrl.text.trim()),
      isSlm: _isSlm,
      isMultiModal: _isMultiModal,
      thinking: _thinking,
      useNativeToolCall: _useNativeToolCall,
      useSafeToolCall: _useSafeToolCall,
      useStreaming: _useStreaming,
    );

    await widget.controller.updateLlmConfig(customConfig);
    widget.controller.customLlmConfig = customConfig;

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Custom LLM override applied.')),
      );
    }
  }

  Future<void> _testMcpServerConnection(McpServerConfig server) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator()),
    );
    try {
      final tempClient = MCPClient(
        server.url,
        mcpEndpoint: server.mcpEndpoint,
        bearerToken: server.apiKey,
        apiPassword: server.apiPassword,
      );
      await tempClient.connect().timeout(const Duration(seconds: 10));
      final toolsCount = tempClient.availableTools.length;
      tempClient.dispose();

      await widget.controller.updateServer(server.copyWith(isOnline: true));

      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Successfully connected to ${server.name}! ($toolsCount tools found)',
          ),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      await widget.controller.updateServer(server.copyWith(isOnline: false));
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to connect: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _discoverServerTools(McpServerConfig server) async {
    await ServerToolsDialog.show(context, server, widget.controller);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = L.of(context);
    final llmSettings = ref.watch(llmSettingsProvider);
    final isDesktop =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.macOS);
    final tabCount = isDesktop ? 4 : 3;

    return DefaultTabController(
      initialIndex: widget.initialTabIndex.clamp(0, tabCount - 1),
      length: tabCount,
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  children: [
                    const Icon(Icons.settings_outlined),
                    const SizedBox(width: 8),
                    Text(
                      'Assistant Settings',
                      style: theme.textTheme.titleMedium,
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        if (widget.onClose != null) {
                          widget.onClose!();
                        } else if (Navigator.of(context).canPop()) {
                          Navigator.of(context).pop();
                        }
                      },
                    ),
                  ],
                ),
              ),
              TabBar(
                labelColor: theme.colorScheme.primary,
                unselectedLabelColor: Colors.grey,
                indicatorSize: TabBarIndicatorSize.tab,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [
                  const Tab(
                    icon: Icon(Icons.smart_toy_outlined),
                    text: 'Agent & Tools',
                  ),
                  const Tab(
                    icon: Icon(Icons.psychology_outlined),
                    text: 'LLM Settings',
                  ),
                  const Tab(
                    icon: Icon(Icons.hub_outlined),
                    text: 'MCP Servers',
                  ),
                  if (isDesktop)
                    const Tab(
                      icon: Icon(Icons.app_registration_outlined),
                      text: 'Registry',
                    ),
                ],
              ),
              const Divider(height: 1),
              Expanded(
                child: TabBarView(
                  children: [
                    // Tab 0: Agent & Tools
                    _buildAgentAndToolsTab(theme, l),

                    // Tab 1: LLM Settings (Multi-LLM profiles from TealKit)
                    _buildLlmTab(theme, llmSettings),

                    // Tab 2: MCP Servers
                    _buildMcpServersTab(theme),

                    // Tab 3: Registry (if desktop)
                    if (isDesktop)
                      McpServerRegistryTab(controller: widget.controller),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────
  // Tab 1: LLM Settings with TealKit Multi-LLM Profiles & Selector
  // ─────────────────────────────────────────────────────────────

  Widget _buildLlmTab(ThemeData theme, tk_llm.LlmSettingsService llmSettings) {
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          // TealKit unified AgentLlmSelectorWidget
          AgentLlmSelectorWidget(
            llmSettings: llmSettings,
            selectedProfileId: _isCustomOverride ? null : _selectedProfileId,
            selectedProviderKey: _selectedProviderKey,
            showEmbeddedOption: true,
            onProfileSelected: (profileId) {
              if (profileId != null) {
                _applySelectedProfile(profileId);
              } else {
                setState(() {
                  _isCustomOverride = true;
                });
              }
            },
            onProviderSelected: (providerKey) {
              setState(() {
                _isCustomOverride = true;
                _selectedProfileId = null;
                _selectedProviderKey = providerKey;
                _customProvider = _providerKeyToLlmProvider(providerKey);
              });
            },
            editablePanel: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Custom / Inline LLM Override',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 12),
                        LlmConfigForm(
                          provider: _customProvider,
                          onProviderChanged: (val) {
                            _providerCache[_customProvider] = _FieldCache(
                              model: _modelCtrl.text,
                              apiKey: _apiKeyCtrl.text,
                              baseUrl: _baseUrlCtrl.text,
                            );
                            final cached = _providerCache[val];
                            if (cached != null) {
                              _modelCtrl.text = cached.model;
                              _apiKeyCtrl.text = cached.apiKey;
                              _baseUrlCtrl.text = cached.baseUrl;
                            } else {
                              _modelCtrl.clear();
                              _apiKeyCtrl.clear();
                              _baseUrlCtrl.clear();
                            }
                            setState(() {
                              _customProvider = val;
                              _selectedProviderKey = val.name;
                            });
                          },
                          modelCtrl: _modelCtrl,
                          apiKeyCtrl: _apiKeyCtrl,
                          baseUrlCtrl: _baseUrlCtrl,
                        ),
                        if (_customProvider != LlmProvider.none) ...[
                          const SizedBox(height: 12),
                          ExpansionTile(
                            title: const Text(
                              'Advanced Hyperparameters & Flags',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            tilePadding: EdgeInsets.zero,
                            children: [
                              LlmAdvancedSettingsForm(
                                tempCtrl: _tempCtrl,
                                maxTokensCtrl: _maxTokensCtrl,
                                maxToolOutputSizeCtrl: _maxToolOutputSizeCtrl,
                                tokenWarningThresholdCtrl:
                                    _tokenWarningThresholdCtrl,
                                topKCtrl: _topKCtrl,
                                topPCtrl: _topPCtrl,
                                repeatPenaltyCtrl: _repeatPenaltyCtrl,
                                seedCtrl: _seedCtrl,
                                thinking: _thinking,
                                onThinkingChanged: (val) =>
                                    setState(() => _thinking = val),
                                isSlm: _isSlm,
                                onIsSlmChanged: (val) =>
                                    setState(() => _isSlm = val),
                                isMultiModal: _isMultiModal,
                                onIsMultiModalChanged: (val) =>
                                    setState(() => _isMultiModal = val),
                                useNativeToolCall: _useNativeToolCall,
                                onUseNativeToolCallChanged: (val) =>
                                    setState(() => _useNativeToolCall = val),
                                useStreaming: _useStreaming,
                                onUseStreamingChanged: (val) =>
                                    setState(() => _useStreaming = val),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          FilledButton.icon(
                            onPressed: _saveCustomLlmSettings,
                            icon: const Icon(Icons.check, size: 16),
                            label: const Text('Apply Custom Settings'),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────
  // Document Search Folders & Indexing Helpers
  // ─────────────────────────────────────────────────────────────

  List<String> _getDocumentPaths() {
    final raw = DataSourcesSettingsService.instance.documentRootPaths;
    return raw
        .split(';')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
  }

  Future<void> _updateDocumentPaths(List<String> paths) async {
    final joined = paths.toSet().join(';');
    await DataSourcesSettingsService.instance.saveDocumentIndex(
      rootPaths: joined,
    );
    if (mounted) setState(() {});
  }

  Future<void> _browseDocumentFolder() async {
    if (Platform.isAndroid) {
      final granted = await StoragePermission.request(context);
      if (!mounted || !granted) return;
    }
    final selected = await FilePicker.getDirectoryPath(
      dialogTitle: 'Select Document Folder',
    );
    if (selected != null && selected.trim().isNotEmpty && mounted) {
      final current = _getDocumentPaths();
      if (!current.contains(selected)) {
        await _updateDocumentPaths([...current, selected]);
      }
    }
  }

  Future<void> _addDocumentPathManual() async {
    final ctrl = TextEditingController();
    final path = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Document Path'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'C:\\Users\\name\\Documents or /home/...',
            labelText: 'Absolute folder path',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (path != null && path.isNotEmpty && mounted) {
      final current = _getDocumentPaths();
      if (!current.contains(path)) {
        await _updateDocumentPaths([...current, path]);
      }
    }
  }

  Future<void> _pickDocumentFiles() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf', 'md', 'docx', 'txt', 'xlsx', 'csv'],
    );
    if (result.isEmpty || !mounted) return;

    final supportDir = await getApplicationSupportDirectory();
    final destDir = Directory('${supportDir.path}/tealkit_indexed_files');
    await destDir.create(recursive: true);

    int copied = 0;
    for (final f in result) {
      try {
        final name = f.name;
        if (f.path != null) {
          await File(f.path!).copy('${destDir.path}/$name');
        } else {
          final bytes = await f.readAsBytes();
          await File('${destDir.path}/$name').writeAsBytes(bytes);
        }
        copied++;
      } catch (_) {}
    }

    if (copied > 0 && mounted) {
      final current = _getDocumentPaths();
      if (!current.contains(destDir.path)) {
        await _updateDocumentPaths([...current, destDir.path]);
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '$copied file(s) imported. Tap "Reindex Documents Now" to update index.',
          ),
        ),
      );
    }
  }

  Future<void> _reindexDocuments() async {
    final paths = _getDocumentPaths();
    if (paths.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please add at least one folder before indexing.'),
        ),
      );
      return;
    }

    if (Platform.isAndroid) {
      final granted = await StoragePermission.request(context);
      if (!mounted || !granted) return;
    }

    setState(() {
      _isIndexingDocuments = true;
      _docIndexedCount = 0;
      _docIndexTotal = 0;
      _docIndexCurrentFile = '';
    });

    final server = DocumentMcpServer();
    _activeDocIndexServer = server;
    server.onIndexProgress = (indexed, total, currentFile) {
      if (mounted) {
        setState(() {
          _docIndexedCount = indexed;
          _docIndexTotal = total;
          _docIndexCurrentFile = currentFile;
        });
      }
    };

    try {
      await server.initialize({
        'rootPath': paths.join(';'),
        'indexingStrategy': 'before_first_run',
      });
      final res = await server.executeTool('reindex', {});
      if (mounted) {
        setState(() {
          _isIndexingDocuments = false;
          _activeDocIndexServer = null;
        });
        if (res.containsKey('error') && res['error'] != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Reindex error: ${res['error']}'),
              backgroundColor: Colors.red,
            ),
          );
        } else {
          final now = DateTime.now();
          setState(() {
            _docLastIndexed = now;
          });
          await DataSourcesSettingsService.instance.saveDocumentIndex(
            rootPaths: paths.join(';'),
            lastIndexedAt: now,
          );
          final count = res['indexedCount'] ?? res['count'] ?? _docIndexedCount;
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('✔ Successfully indexed $count document(s).'),
                backgroundColor: Colors.green,
              ),
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isIndexingDocuments = false;
          _activeDocIndexServer = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Reindex failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Widget _buildDocumentFolderSection(ThemeData theme) {
    final paths = _getDocumentPaths();

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.folder_special_outlined,
                size: 18,
                color: Color(0xFF60A5FA),
              ),
              const SizedBox(width: 8),
              Text(
                'Indexed Document Folders',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: const Color(0xFF60A5FA),
                ),
              ),
              const Spacer(),
              if (paths.isNotEmpty)
                Text(
                  '${paths.length} folder${paths.length > 1 ? 's' : ''}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Local folders scanned for PDF, Markdown, DOCX, XLSX, TXT, and CSV documents.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.grey,
                  ),
                ),
              ),
              if (_docLastIndexed != null) ...[
                const SizedBox(width: 8),
                Icon(Icons.schedule, size: 12, color: Colors.grey[400]),
                const SizedBox(width: 4),
                Text(
                  'Last indexed: ${_formatLastIndexed(_docLastIndexed)}',
                  style: TextStyle(fontSize: 11, color: Colors.grey[400]),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),

          // Folder chips
          if (paths.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow.withValues(
                  alpha: 0.5,
                ),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white10),
              ),
              child: const Row(
                children: [
                  Icon(Icons.folder_off_outlined, size: 16, color: Colors.grey),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'No folders configured. Add folders below to index documents for search.',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                ],
              ),
            )
          else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: paths.map((p) {
                final shortName =
                    p
                        .split(RegExp(r'[\\/]'))
                        .where((s) => s.isNotEmpty)
                        .lastOrNull ??
                    p;
                return InputChip(
                  avatar: const Icon(
                    Icons.folder,
                    size: 15,
                    color: Color(0xFF60A5FA),
                  ),
                  label: Text(shortName, style: const TextStyle(fontSize: 12)),
                  tooltip: p,
                  deleteIcon: const Icon(Icons.close, size: 14),
                  onDeleted: () {
                    final updated = List<String>.from(paths)..remove(p);
                    _updateDocumentPaths(updated);
                  },
                );
              }).toList(),
            ),

          const SizedBox(height: 10),

          // Action buttons row: Browse Folder | Add Path | Pick Files
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.folder_open, size: 16),
                label: const Text('Browse Folder...'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                ),
                onPressed: _browseDocumentFolder,
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.create_new_folder_outlined, size: 16),
                label: const Text('Add Path...'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                ),
                onPressed: _addDocumentPathManual,
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.file_copy_outlined, size: 16),
                label: const Text('Pick Files...'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                ),
                onPressed: _pickDocumentFiles,
              ),
            ],
          ),

          const SizedBox(height: 12),

          // Reindex section / Live progress bar
          if (_isIndexingDocuments) ...[
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.primaryBlue.withAlpha(80)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _docIndexTotal > 0
                              ? 'Indexing $_docIndexedCount / $_docIndexTotal: $_docIndexCurrentFile'
                              : 'Scanning & building DuckDB vector index...',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        icon: const Icon(
                          Icons.stop,
                          size: 14,
                          color: Colors.redAccent,
                        ),
                        label: const Text(
                          'Stop',
                          style: TextStyle(
                            color: Colors.redAccent,
                            fontSize: 11,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                        ),
                        onPressed: () =>
                            _activeDocIndexServer?.cancelIndexing(),
                      ),
                    ],
                  ),
                  if (_docIndexTotal > 0) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: _docIndexedCount / _docIndexTotal,
                      backgroundColor: Colors.white10,
                    ),
                  ],
                ],
              ),
            ),
          ] else ...[
            if (_docLastIndexed != null) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    const Icon(
                      Icons.check_circle_outline,
                      size: 14,
                      color: Color(0xFF34D399),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Last indexed: ${_formatLastIndexed(_docLastIndexed)}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF34D399),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Reindex Documents Now'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.primaryBlue,
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: paths.isNotEmpty ? _reindexDocuments : null,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────
  // Web-Crawl (Website Search) Seed URLs & Indexing Helpers
  // ─────────────────────────────────────────────────────────────

  Future<void> _loadWebsiteMaxPages() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getInt('playground_website_max_pages');
      if (saved != null && saved > 0 && mounted) {
        _websiteMaxPagesCtrl.text = saved.clamp(1, 1000).toString();
      }
    } catch (_) {}
  }

  int _getWebsiteMaxPages() {
    final text = _websiteMaxPagesCtrl.text.trim();
    final parsed = int.tryParse(text);
    if (parsed != null && parsed > 0) {
      return parsed.clamp(1, 1000);
    }
    return DataSourcesSettingsService.instance.websiteIndexMaxPages.clamp(
      1,
      1000,
    );
  }

  void _onWebsiteMaxPagesChanged(String val) {
    final parsed = int.tryParse(val.trim());
    if (parsed != null && parsed > 0) {
      final clamped = parsed.clamp(1, 1000);
      DataSourcesSettingsService.instance.saveWebsiteIndex(
        urls: _getWebsiteUrls().join(', '),
        maxPages: clamped,
        cron: DataSourcesSettingsService.instance.websiteIndexCron,
        lastIndexedAt: _webLastIndexed,
      );
      SharedPreferences.getInstance()
          .then((prefs) {
            prefs.setInt('playground_website_max_pages', clamped);
          })
          .catchError((_) {});
    }
  }

  List<String> _getWebsiteUrls() {
    final raw = DataSourcesSettingsService.instance.websiteIndexUrls;
    return raw
        .split(RegExp(r'[,;\n]'))
        .map((u) => u.trim())
        .where((u) => u.isNotEmpty)
        .toList();
  }

  Future<void> _updateWebsiteUrls(List<String> urls) async {
    final joined = urls.toSet().join(', ');
    final maxPages = _getWebsiteMaxPages();
    await DataSourcesSettingsService.instance.saveWebsiteIndex(
      urls: joined,
      maxPages: maxPages,
      cron: DataSourcesSettingsService.instance.websiteIndexCron,
      lastIndexedAt: _webLastIndexed,
    );
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('playground_website_max_pages', maxPages);
    } catch (_) {}
    if (mounted) setState(() {});
  }

  void _addWebsiteUrl() {
    final text = _websiteUrlInputCtrl.text.trim();
    if (text.isEmpty) return;
    String url = text;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    try {
      final parsed = Uri.parse(url);
      if (parsed.host.isEmpty) return;
      final current = _getWebsiteUrls();
      if (!current.contains(url)) {
        _updateWebsiteUrls([...current, url]);
      }
      _websiteUrlInputCtrl.clear();
    } catch (_) {}
  }

  Future<void> _reindexWebsites() async {
    final urls = _getWebsiteUrls();
    if (urls.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please add at least one website URL before crawling.'),
        ),
      );
      return;
    }

    final maxPages = _getWebsiteMaxPages();

    setState(() {
      _isIndexingWebsites = true;
      _webIndexedCount = 0;
      _webIndexTotal = 0;
      _webIndexCurrentUrl = '';
    });

    final server = WebsiteSearchMcpServer();
    _activeWebIndexServer = server;
    server.onIndexProgress = (indexed, total, currentUrl) {
      if (mounted) {
        setState(() {
          _webIndexedCount = indexed;
          _webIndexTotal = total;
          _webIndexCurrentUrl = currentUrl;
        });
      }
    };

    try {
      await server.initialize({
        'websiteUrls': urls.join(', '),
        'maxPages': maxPages,
        'indexingStrategy': 'before_first_run',
      });
      final res = await server.executeTool('reindex_websites', {
        'maxPages': maxPages,
      });
      if (mounted) {
        setState(() {
          _isIndexingWebsites = false;
          _activeWebIndexServer = null;
        });
        if (res.containsKey('error') && res['error'] != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Crawl error: ${res['error']}'),
              backgroundColor: Colors.red,
            ),
          );
        } else {
          final now = DateTime.now();
          setState(() {
            _webLastIndexed = now;
          });
          await DataSourcesSettingsService.instance.saveWebsiteIndex(
            urls: urls.join(', '),
            maxPages: maxPages,
            cron: DataSourcesSettingsService.instance.websiteIndexCron,
            lastIndexedAt: now,
          );
          try {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setInt('playground_website_max_pages', maxPages);
          } catch (_) {}
          final count = res['indexedCount'] ?? res['count'] ?? _webIndexedCount;
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  '✔ Successfully crawled & indexed $count web page(s) (max $maxPages per site).',
                ),
                backgroundColor: Colors.green,
              ),
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isIndexingWebsites = false;
          _activeWebIndexServer = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Web-crawl failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Widget _buildWebsiteSearchSection(ThemeData theme) {
    final l = L.of(context);
    final urls = _getWebsiteUrls();

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.public, size: 18, color: Color(0xFF06B6D4)),
              const SizedBox(width: 8),
              Text(
                'Indexed Websites / Seed URLs',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: const Color(0xFF06B6D4),
                ),
              ),
              const Spacer(),
              if (urls.isNotEmpty)
                Text(
                  '${urls.length} site${urls.length > 1 ? 's' : ''}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Seed website URLs and documentation portals crawled into DuckDB for vector/keyword search.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.grey,
                  ),
                ),
              ),
              if (_webLastIndexed != null) ...[
                const SizedBox(width: 8),
                Icon(Icons.schedule, size: 12, color: Colors.grey[400]),
                const SizedBox(width: 4),
                Text(
                  'Last crawled: ${_formatLastIndexed(_webLastIndexed)}',
                  style: TextStyle(fontSize: 11, color: Colors.grey[400]),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),

          // URL chips
          if (urls.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow.withValues(
                  alpha: 0.5,
                ),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white10),
              ),
              child: const Row(
                children: [
                  Icon(Icons.link_off_outlined, size: 16, color: Colors.grey),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'No websites configured. Add URLs below to crawl and index web pages.',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                ],
              ),
            )
          else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: urls.map((u) {
                String label = u;
                try {
                  final parsed = Uri.parse(u);
                  final host = parsed.host;
                  final path = parsed.path.trim();
                  label = (path.isEmpty || path == '/') ? host : '$host$path';
                } catch (_) {}
                return InputChip(
                  avatar: const Icon(
                    Icons.public,
                    size: 15,
                    color: Color(0xFF06B6D4),
                  ),
                  label: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: Text(
                      label,
                      style: const TextStyle(fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  tooltip: u,
                  deleteIcon: const Icon(Icons.close, size: 14),
                  onDeleted: () {
                    final updated = List<String>.from(urls)..remove(u);
                    _updateWebsiteUrls(updated);
                  },
                );
              }).toList(),
            ),

          const SizedBox(height: 12),

          // Add URL Input field & button
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _websiteUrlInputCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Website URL',
                    hintText: 'https://example.com/docs',
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    prefixIcon: Icon(Icons.add_link, size: 18),
                  ),
                  onSubmitted: (_) => _addWebsiteUrl(),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add URL'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                ),
                onPressed: _addWebsiteUrl,
              ),
            ],
          ),

          const SizedBox(height: 12),

          // Max pages to be indexed input field & stepper
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _websiteMaxPagesCtrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  enabled: !_isIndexingWebsites,
                  decoration: InputDecoration(
                    labelText: l.maxPagesToBeIndexed,
                    hintText: '100',
                    helperText: l.maxPagesCrawledHelper,
                    isDense: true,
                    border: const OutlineInputBorder(),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    prefixIcon: const Icon(
                      Icons.format_list_numbered,
                      size: 18,
                    ),
                    suffixIcon: _websiteMaxPagesCtrl.text != '100'
                        ? IconButton(
                            icon: const Icon(Icons.restore, size: 18),
                            tooltip: l.resetToDefaultCount('100'),
                            onPressed: _isIndexingWebsites
                                ? null
                                : () {
                                    _websiteMaxPagesCtrl.text = '100';
                                    _onWebsiteMaxPagesChanged('100');
                                    setState(() {});
                                  },
                          )
                        : null,
                  ),
                  onChanged: (val) {
                    _onWebsiteMaxPagesChanged(val);
                    setState(() {});
                  },
                ),
              ),
              const SizedBox(width: 8),
              Container(
                height: 42,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: theme.colorScheme.outlineVariant.withAlpha(120),
                  ),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.remove, size: 16),
                      tooltip: 'Decrease by 25',
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.all(8),
                      onPressed: _isIndexingWebsites
                          ? null
                          : () {
                              final current = _getWebsiteMaxPages();
                              final newVal = (current - 25).clamp(1, 1000);
                              _websiteMaxPagesCtrl.text = newVal.toString();
                              _onWebsiteMaxPagesChanged(newVal.toString());
                              setState(() {});
                            },
                    ),
                    const SizedBox(
                      height: 20,
                      child: VerticalDivider(width: 1),
                    ),
                    IconButton(
                      icon: const Icon(Icons.add, size: 16),
                      tooltip: 'Increase by 25',
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.all(8),
                      onPressed: _isIndexingWebsites
                          ? null
                          : () {
                              final current = _getWebsiteMaxPages();
                              final newVal = (current + 25).clamp(1, 1000);
                              _websiteMaxPagesCtrl.text = newVal.toString();
                              _onWebsiteMaxPagesChanged(newVal.toString());
                              setState(() {});
                            },
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // Reindex / Live crawl progress bar
          if (_isIndexingWebsites) ...[
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: const Color(0xFF06B6D4).withAlpha(80),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _webIndexTotal > 0
                              ? 'Crawling $_webIndexedCount / $_webIndexTotal: $_webIndexCurrentUrl'
                              : 'Discovering & crawling web pages...',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        icon: const Icon(
                          Icons.stop,
                          size: 14,
                          color: Colors.redAccent,
                        ),
                        label: const Text(
                          'Stop',
                          style: TextStyle(
                            color: Colors.redAccent,
                            fontSize: 11,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                        ),
                        onPressed: () =>
                            _activeWebIndexServer?.cancelIndexing(),
                      ),
                    ],
                  ),
                  if (_webIndexTotal > 0) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: _webIndexedCount / _webIndexTotal,
                      backgroundColor: Colors.white10,
                      valueColor: const AlwaysStoppedAnimation(
                        Color(0xFF06B6D4),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ] else ...[
            if (_webLastIndexed != null) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    const Icon(
                      Icons.check_circle_outline,
                      size: 14,
                      color: Color(0xFF34D399),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Last crawled: ${_formatLastIndexed(_webLastIndexed)}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF34D399),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.travel_explore_outlined, size: 16),
                label: const Text('Crawl & Index Websites Now'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF0D9488),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: urls.isNotEmpty ? _reindexWebsites : null,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────
  // Tab 0: Agent & Tools Tab
  // ─────────────────────────────────────────────────────────────

  Widget _buildAgentAndToolsTab(ThemeData theme, L l) {
    final isDesktopPlatform = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.macOS);
    final isMobile = !isDesktopPlatform || MediaQuery.sizeOf(context).width < 700;

    const codingToolNames = {
      'fs_read_file',
      'fs_write_file',
      'fs_replace_text',
      'fs_find',
      'fs_list_dir',
      'fs_move_file',
      'fs_delete_file',
      'terminal_exec',
    };

    final rawLocalTools = widget.controller.localTools;
    final localTools = isMobile
        ? rawLocalTools.where((t) => !codingToolNames.contains(t.name)).toList()
        : rawLocalTools;

    final mcpTools = widget.controller.mcpManager.availableTools;
    final allAvailableNames = <String>{
      ...localTools.map((t) => t.name),
      ...mcpTools.map((t) => t.name),
    };
    final activeCount = widget.controller.enabledToolNames
        .where((name) => allAvailableNames.contains(name))
        .length;
    final totalTools = allAvailableNames.length;

    return ListView(
      padding: const EdgeInsets.all(16.0),
      children: [
        // Mode Selector Card
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      _chatMode
                          ? Icons.chat_bubble_outline
                          : Icons.smart_toy_outlined,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      l.operationMode,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Builder(
                  builder: (ctx) {
                    Widget buildModeButton({
                      required bool isSelected,
                      required IconData icon,
                      required String label,
                      required VoidCallback onTap,
                    }) {
                  return InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: onTap,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        vertical: 10,
                        horizontal: 8,
                      ),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? theme.colorScheme.primaryContainer
                            : theme.colorScheme.surfaceContainerHighest
                                  .withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: isSelected
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outlineVariant.withValues(
                                  alpha: 0.4,
                                ),
                          width: isSelected ? 1.5 : 1,
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            icon,
                            size: 18,
                            color: isSelected
                                ? theme.colorScheme.onPrimaryContainer
                                : null,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                color: isSelected
                                    ? theme.colorScheme.onPrimaryContainer
                                    : null,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }

                return LayoutBuilder(
                  builder: (context, constraints) {
                    final isNarrow = isMobile || constraints.maxWidth < 360;
                    if (isNarrow) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          buildModeButton(
                            isSelected: !_chatMode,
                            icon: Icons.smart_toy_outlined,
                            label: l.agentMode,
                            onTap: () {
                              setState(() {
                                _chatMode = false;
                                widget.controller.chatMode = false;
                              });
                            },
                          ),
                          const SizedBox(height: 8),
                          buildModeButton(
                            isSelected: _chatMode,
                            icon: Icons.chat_bubble_outline,
                            label: l.directChat,
                            onTap: () {
                              setState(() {
                                _chatMode = true;
                                widget.controller.chatMode = true;
                              });
                            },
                          ),
                        ],
                      );
                    }

                    return Row(
                      children: [
                        Expanded(
                          child: buildModeButton(
                            isSelected: !_chatMode,
                            icon: Icons.smart_toy_outlined,
                            label: l.agentMode,
                            onTap: () {
                              setState(() {
                                _chatMode = false;
                                widget.controller.chatMode = false;
                              });
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: buildModeButton(
                            isSelected: _chatMode,
                            icon: Icons.chat_bubble_outline,
                            label: l.directChat,
                            onTap: () {
                              setState(() {
                                _chatMode = true;
                                widget.controller.chatMode = true;
                              });
                            },
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
                const SizedBox(height: 8),
                Text(
                  _chatMode ? l.directChatDesc : l.agentModeDesc,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),

        // System Prompt Card
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.edit_note, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l.systemPromptPersona,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_systemPromptCtrl.text.isNotEmpty)
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 4,
                          ),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: const Icon(Icons.clear, size: 14),
                        label: const Text(
                          'Clear',
                          style: TextStyle(fontSize: 12),
                        ),
                        onPressed: () {
                          setState(() {
                            _systemPromptCtrl.clear();
                            widget.controller.systemPrompt = '';
                          });
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _systemPromptCtrl,
                  maxLines: 5,
                  minLines: 3,
                  onChanged: (val) {
                    widget.controller.systemPrompt = val;
                  },
                  decoration: InputDecoration(
                    hintText: l.assistantSystemPromptHint,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.all(12),
                  ),
                ),
                if ((widget.showSystemPromptTemplates ??
                        widget.controller.showSystemPromptTemplates) &&
                    (widget.systemPromptTemplates ??
                            widget.controller.systemPromptTemplates ??
                            kDefaultSystemPromptTemplates)
                        .isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    l.quickPersonaTemplates,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final tpl
                          in (widget.systemPromptTemplates ??
                              widget.controller.systemPromptTemplates ??
                              kDefaultSystemPromptTemplates))
                        ActionChip(
                          avatar: tpl.icon != null
                              ? Icon(tpl.icon, size: 14)
                              : null,
                          label: Text(
                            tpl.label,
                            style: const TextStyle(fontSize: 11),
                          ),
                          onPressed: () {
                            setState(() {
                              _systemPromptCtrl.text = tpl.prompt;
                              widget.controller.systemPrompt = tpl.prompt;
                            });
                          },
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),

        if (!isMobile) ...[
          // Tool Permissions Card (Human-in-the-Loop) - Hidden in mobile mode
          _buildToolPermissionsCard(theme, l),
          const SizedBox(height: 12),
        ],

        // Specialized Sub-Agents Card (DelegateTaskTool) - Shown in mobile mode with web_search
        _buildSpecializedSubAgentsCard(theme, l, isMobile: isMobile),
        const SizedBox(height: 12),

        // ── Tools Section Header ──────────────────────────
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.handyman_outlined,
                    color: AppTheme.primaryBlue,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Tools ($activeCount / $totalTools Active)',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              if (totalTools > 0) ...[
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () {
                        final allNames = <String>{
                          ...localTools.map((t) => t.name),
                          ...mcpTools.map((t) => t.name),
                        };
                        setState(() {
                          widget.controller.updateEnabledTools(allNames);
                        });
                      },
                      child: const Text(
                        'Enable All',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                    const SizedBox(width: 4),
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () {
                        setState(() {
                          widget.controller.updateEnabledTools({});
                        });
                      },
                      child: const Text(
                        'Disable All',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        if (_chatMode) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8.0),
            child: Text(
              l.toolsBypassedInDirectChat,
              style: TextStyle(
                color: Colors.orange.shade700,
                fontSize: 12,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ],
        const SizedBox(height: 6),

        // ── Available Tool Groups (Matching Workflow Editor) ──
        Builder(
          builder: (context) {
            final registry = InternalMcpRegistry();
            final serverInfos = List<InternalMcpInfo>.from(
              registry.availableServers,
            );
            final seenMcpTypes = <String>{};
            final available = serverInfos
                .where(
                  (server) =>
                      seenMcpTypes.add(server.type) &&
                      server.type != 'traffic' &&
                      !server.type.startsWith('gh_mcp_') &&
                      (!isMobile || server.type != 'coding_tools'),
                )
                .toList();

            final toolboxInfo = available
                .where((s) => s.type == 'toolbox')
                .firstOrNull;
            final otherServers =
                available.where((s) => s.type != 'toolbox').toList()
                  ..sort((a, b) => a.displayName.compareTo(b.displayName));
            final sortedServers = [?toolboxInfo, ...otherServers];

            final allClaimedNames = <String>{};
            for (final s in sortedServers) {
              allClaimedNames.addAll(s.toolNames);
            }
            final unclaimedLocalTools = localTools
                .where((t) => !allClaimedNames.contains(t.name))
                .where((t) => !isMobile || !codingToolNames.contains(t.name))
                .toList();

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 1. Built-in Internal MCP Groups
                for (final info in sortedServers) ...[
                  Builder(
                    builder: (ctx) {
                      final groupToolNames = info.toolNames;
                      final enabledCount = groupToolNames
                          .where(
                            (name) => widget.controller.enabledToolNames
                                .contains(name),
                          )
                          .length;
                      final isGroupEnabled = enabledCount > 0;
                      final isExpanded = _expandedToolGroups.contains(
                        info.type,
                      );

                      return Card(
                        key: ValueKey('group_tile_${info.type}'),
                        margin: const EdgeInsets.only(bottom: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SwitchListTile(
                              secondary: Icon(
                                _mcpIcon(info.iconName),
                                color: isGroupEnabled
                                    ? AppTheme.primaryBlue
                                    : Colors.grey,
                              ),
                              title: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      info.displayName,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        color: isGroupEnabled
                                            ? null
                                            : Colors.grey,
                                      ),
                                    ),
                                  ),
                                  if (groupToolNames.isNotEmpty) ...[
                                    const SizedBox(width: 4),
                                    Chip(
                                      label: Text(
                                        enabledCount == groupToolNames.length
                                            ? '${groupToolNames.length} tools'
                                            : '$enabledCount / ${groupToolNames.length} tools',
                                        style: const TextStyle(fontSize: 11),
                                      ),
                                      visualDensity: VisualDensity.compact,
                                      backgroundColor: AppTheme.primaryBlue
                                          .withAlpha(25),
                                    ),
                                  ],
                                  const SizedBox(width: 4),
                                  InkWell(
                                    borderRadius: BorderRadius.circular(16),
                                    onTap: () {
                                      setState(() {
                                        if (isExpanded) {
                                          _expandedToolGroups.remove(info.type);
                                        } else {
                                          _expandedToolGroups.add(info.type);
                                        }
                                      });
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.all(4),
                                      child: Icon(
                                        isExpanded
                                            ? Icons.expand_less
                                            : Icons.expand_more,
                                        size: 20,
                                        color: Colors.grey,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              subtitle: Text(
                                info.description,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                              value: isGroupEnabled,
                              activeTrackColor: AppTheme.primaryBlue,
                              onChanged: (val) {
                                setState(() {
                                  for (final toolName in groupToolNames) {
                                    widget.controller.toggleToolEnabled(
                                      toolName,
                                      val,
                                    );
                                  }
                                });
                              },
                            ),
                            if (isExpanded) ...[
                              const Divider(height: 1),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  8,
                                  16,
                                  12,
                                ),
                                child: Column(
                                  children: [
                                    if (info.type == 'document') ...[
                                      _buildDocumentFolderSection(theme),
                                      const Divider(height: 16),
                                    ],
                                    if (info.type == 'website_search') ...[
                                      _buildWebsiteSearchSection(theme),
                                      const Divider(height: 16),
                                    ],
                                    for (final toolName in groupToolNames) ...[
                                      Builder(
                                        builder: (ctx) {
                                          final localTool = localTools
                                              .where((t) => t.name == toolName)
                                              .firstOrNull;
                                          final desc =
                                              localTool?.description ?? '';
                                          return CheckboxListTile(
                                            dense: true,
                                            contentPadding: EdgeInsets.zero,
                                            title: Text(
                                              toolName,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w600,
                                                fontSize: 13,
                                              ),
                                            ),
                                            subtitle: desc.isNotEmpty
                                                ? Text(
                                                    desc,
                                                    maxLines: 2,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                      fontSize: 11,
                                                    ),
                                                  )
                                                : null,
                                            value: widget
                                                .controller
                                                .enabledToolNames
                                                .contains(toolName),
                                            onChanged: (val) {
                                              setState(() {
                                                widget.controller
                                                    .toggleToolEnabled(
                                                      toolName,
                                                      val ?? false,
                                                    );
                                              });
                                            },
                                          );
                                        },
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
                ],

                // 2. Unclaimed Local Tools
                if (unclaimedLocalTools.isNotEmpty) ...[
                  Builder(
                    builder: (ctx) {
                      final enabledCount = unclaimedLocalTools
                          .where(
                            (t) => widget.controller.enabledToolNames.contains(
                              t.name,
                            ),
                          )
                          .length;
                      final isEnabled = enabledCount > 0;
                      final isExpanded = _expandedToolGroups.contains(
                        '__unclaimed__',
                      );

                      return Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SwitchListTile(
                              secondary: Icon(
                                Icons.extension,
                                color: isEnabled
                                    ? AppTheme.primaryBlue
                                    : Colors.grey,
                              ),
                              title: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      'Other Local Tools',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        color: isEnabled ? null : Colors.grey,
                                      ),
                                    ),
                                  ),
                                  Chip(
                                    label: Text(
                                      enabledCount == unclaimedLocalTools.length
                                          ? '${unclaimedLocalTools.length} tools'
                                          : '$enabledCount / ${unclaimedLocalTools.length} tools',
                                      style: const TextStyle(fontSize: 11),
                                    ),
                                    visualDensity: VisualDensity.compact,
                                    backgroundColor: AppTheme.primaryBlue
                                        .withAlpha(25),
                                  ),
                                  const SizedBox(width: 4),
                                  InkWell(
                                    borderRadius: BorderRadius.circular(16),
                                    onTap: () {
                                      setState(() {
                                        if (isExpanded) {
                                          _expandedToolGroups.remove(
                                            '__unclaimed__',
                                          );
                                        } else {
                                          _expandedToolGroups.add(
                                            '__unclaimed__',
                                          );
                                        }
                                      });
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.all(4),
                                      child: Icon(
                                        isExpanded
                                            ? Icons.expand_less
                                            : Icons.expand_more,
                                        size: 20,
                                        color: Colors.grey,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              subtitle: const Text(
                                'Additional standalone workspace and system tools',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 12),
                              ),
                              value: isEnabled,
                              activeTrackColor: AppTheme.primaryBlue,
                              onChanged: (val) {
                                setState(() {
                                  for (final t in unclaimedLocalTools) {
                                    widget.controller.toggleToolEnabled(
                                      t.name,
                                      val,
                                    );
                                  }
                                });
                              },
                            ),
                            if (isExpanded) ...[
                              const Divider(height: 1),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  8,
                                  16,
                                  12,
                                ),
                                child: Column(
                                  children: [
                                    for (final tool in unclaimedLocalTools)
                                      CheckboxListTile(
                                        dense: true,
                                        contentPadding: EdgeInsets.zero,
                                        title: Text(
                                          tool.name,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 13,
                                          ),
                                        ),
                                        subtitle: Text(
                                          tool.description,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 11),
                                        ),
                                        value: widget
                                            .controller
                                            .enabledToolNames
                                            .contains(tool.name),
                                        onChanged: (val) {
                                          setState(() {
                                            widget.controller.toggleToolEnabled(
                                              tool.name,
                                              val ?? false,
                                            );
                                          });
                                        },
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
                ],

                // 3. Remote MCP Server Tools
                if (mcpTools.isNotEmpty) ...[
                  Builder(
                    builder: (ctx) {
                      final enabledCount = mcpTools
                          .where(
                            (t) => widget.controller.enabledToolNames.contains(
                              t.name,
                            ),
                          )
                          .length;
                      final isEnabled = enabledCount > 0;
                      final isExpanded = _expandedToolGroups.contains(
                        '__mcp_remote__',
                      );

                      return Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SwitchListTile(
                              secondary: Icon(
                                Icons.hub_outlined,
                                color: isEnabled
                                    ? AppTheme.primaryBlue
                                    : Colors.grey,
                              ),
                              title: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      'MCP Server Tools',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        color: isEnabled ? null : Colors.grey,
                                      ),
                                    ),
                                  ),
                                  Chip(
                                    label: Text(
                                      enabledCount == mcpTools.length
                                          ? '${mcpTools.length} tools'
                                          : '$enabledCount / ${mcpTools.length} tools',
                                      style: const TextStyle(fontSize: 11),
                                    ),
                                    visualDensity: VisualDensity.compact,
                                    backgroundColor: AppTheme.primaryBlue
                                        .withAlpha(25),
                                  ),
                                  const SizedBox(width: 4),
                                  InkWell(
                                    borderRadius: BorderRadius.circular(16),
                                    onTap: () {
                                      setState(() {
                                        if (isExpanded) {
                                          _expandedToolGroups.remove(
                                            '__mcp_remote__',
                                          );
                                        } else {
                                          _expandedToolGroups.add(
                                            '__mcp_remote__',
                                          );
                                        }
                                      });
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.all(4),
                                      child: Icon(
                                        isExpanded
                                            ? Icons.expand_less
                                            : Icons.expand_more,
                                        size: 20,
                                        color: Colors.grey,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              subtitle: const Text(
                                'Tools discovered from connected remote MCP servers',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 12),
                              ),
                              value: isEnabled,
                              activeTrackColor: AppTheme.primaryBlue,
                              onChanged: (val) {
                                setState(() {
                                  for (final t in mcpTools) {
                                    widget.controller.toggleToolEnabled(
                                      t.name,
                                      val,
                                    );
                                  }
                                });
                              },
                            ),
                            if (isExpanded) ...[
                              const Divider(height: 1),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  8,
                                  16,
                                  12,
                                ),
                                child: Column(
                                  children: [
                                    for (final tool in mcpTools)
                                      CheckboxListTile(
                                        dense: true,
                                        contentPadding: EdgeInsets.zero,
                                        title: Text(
                                          tool.name,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 13,
                                          ),
                                        ),
                                        subtitle: tool.description != null
                                            ? Text(
                                                tool.description!,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontSize: 11,
                                                ),
                                              )
                                            : null,
                                        value: widget
                                            .controller
                                            .enabledToolNames
                                            .contains(tool.name),
                                        onChanged: (val) {
                                          setState(() {
                                            widget.controller.toggleToolEnabled(
                                              tool.name,
                                              val ?? false,
                                            );
                                          });
                                        },
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: () {
            widget.controller.systemPrompt = _systemPromptCtrl.text.trim();
            widget.controller.chatMode = _chatMode;
            if (widget.onClose != null) {
              widget.onClose!();
            } else if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            }
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(l.agentSettingsApplied)));
          },
          icon: const Icon(Icons.check),
          label: Text(l.saveAndApplyAgentSettings),
        ),
      ],
    );
  }

  Widget _buildToolPermissionsCard(ThemeData theme, L l) {
    final perms = widget.controller.permissions;
    const orangeColor = Color(0xFFF95721);

    Widget buildSwitchRow(
      String title,
      bool value,
      ValueChanged<bool> onChanged,
    ) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                title,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
            Switch(
              value: value,
              activeThumbColor: orangeColor,
              activeTrackColor: orangeColor.withValues(alpha: 0.5),
              onChanged: onChanged,
            ),
          ],
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.security, color: orangeColor, size: 20),
                const SizedBox(width: 8),
                Text(
                  l.toolPermissionsHitl,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: orangeColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              l.toolPermissionsHitlDesc,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            buildSwitchRow(l.autoApproveReadTools, perms.autoApproveRead, (
              val,
            ) {
              setState(() {
                perms.autoApproveRead = val;
              });
              perms.save();
            }),
            buildSwitchRow(l.autoApproveWriteTools, perms.autoApproveWrite, (
              val,
            ) {
              setState(() {
                perms.autoApproveWrite = val;
              });
              perms.save();
            }),
            buildSwitchRow(
              l.autoApproveExecutionTools,
              perms.autoApproveExecute,
              (val) {
                setState(() {
                  perms.autoApproveExecute = val;
                });
                perms.save();
              },
            ),
            buildSwitchRow(
              l.autoApproveNetworkTools,
              perms.autoApproveNetwork,
              (val) {
                setState(() {
                  perms.autoApproveNetwork = val;
                });
                perms.save();
              },
            ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────
  // Specialized Sub-Agents Card (DelegateTaskTool)
  // ─────────────────────────────────────────────────────────────

  Widget _buildSpecializedSubAgentsCard(
    ThemeData theme,
    L l, {
    bool isMobile = false,
  }) {
    const orangeColor = Color(0xFFF95721);
    final subagentsAsync = ref.watch(subagentsListProvider);

    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withAlpha(35),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: theme.colorScheme.outlineVariant.withAlpha(50)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(
              left: 16,
              right: 16,
              top: 14,
              bottom: 6,
            ),
            child: Row(
              children: [
                const Icon(Icons.people_outline, color: orangeColor, size: 20),
                const SizedBox(width: 8),
                Text(
                  subagentsAsync.when(
                    data: (list) {
                      final count = isMobile
                          ? list
                              .where(
                                (s) =>
                                    s.key == 'web_search' ||
                                    s.key == 'web_researcher',
                              )
                              .length
                          : list.length;
                      return 'Specialized Sub-Agents ($count)';
                    },
                    loading: () => 'Specialized Sub-Agents (...)',
                    error: (_, _) => 'Specialized Sub-Agents',
                  ),
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final isNarrow = constraints.maxWidth < 450;
                final actions = Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    OutlinedButton.icon(
                      icon: const Icon(
                        Icons.auto_awesome,
                        size: 14,
                        color: orangeColor,
                      ),
                      label: const Text(
                        'Generate Sample Subagents',
                        style: TextStyle(fontSize: 12),
                      ),
                      onPressed: () async {
                        final added = await ref
                            .read(subagentsListProvider.notifier)
                            .generateSamples();
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                added > 0
                                    ? 'Generated $added sample sub-agents.'
                                    : 'All sample sub-agents already exist in database.',
                              ),
                            ),
                          );
                        }
                      },
                    ),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: orangeColor,
                      ),
                      icon: const Icon(Icons.add, size: 14),
                      label: const Text(
                        'Add Subagent',
                        style: TextStyle(fontSize: 12),
                      ),
                      onPressed: () => _showSubAgentDialog(context, null),
                    ),
                  ],
                );

                if (isNarrow) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Subagents available for DelegateTaskTool:',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                      const SizedBox(height: 8),
                      actions,
                    ],
                  );
                }

                return Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Subagents available for DelegateTaskTool:',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    actions,
                  ],
                );
              },
            ),
          ),
          subagentsAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(24.0),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (err, _) => Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                'Failed to load subagents: $err',
                style: const TextStyle(color: Colors.red),
              ),
            ),
            data: (subagents) {
              final displayedSubagents = isMobile
                  ? subagents
                      .where(
                        (s) =>
                            s.key == 'web_search' ||
                            s.key == 'web_researcher',
                      )
                      .toList()
                  : subagents;

              if (displayedSubagents.isEmpty) {
                return Container(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest.withAlpha(
                      40,
                    ),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: theme.colorScheme.outlineVariant.withAlpha(60),
                    ),
                  ),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isMobile
                              ? Icons.travel_explore
                              : Icons.smart_toy_outlined,
                          size: 36,
                          color: orangeColor,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          isMobile
                              ? 'No Web Search Sub-Agent Configured'
                              : 'No Specialized Sub-Agents Configured',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 6),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 480),
                          child: Text(
                            isMobile
                                ? 'Generate the Web Search subagent (web_search) for autonomous online queries.'
                                : 'Click below to generate sample subagents for automated unit testing (unit_tester), '
                                    'git repository audits (git_auditor), technical web research (web_researcher), '
                                    'codebase exploration (code_scout), and embedded firmware (c_analyzer).',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: orangeColor,
                          ),
                          icon: const Icon(Icons.auto_awesome, size: 16),
                          label: Text(
                            isMobile
                                ? 'Generate Web Search Subagent'
                                : 'Generate Sample Subagents',
                          ),
                          onPressed: () => ref
                              .read(subagentsListProvider.notifier)
                              .generateSamples(),
                        ),
                      ],
                    ),
                  ),
                );
              }

              return Column(
                children: displayedSubagents.map((s) {
                  return Card(
                    margin: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    elevation: 0,
                    color: theme.colorScheme.surfaceContainerHighest.withAlpha(
                      50,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: BorderSide(
                        color: theme.colorScheme.outlineVariant.withAlpha(40),
                      ),
                    ),
                    child: ListTile(
                      leading: const Icon(
                        Icons.smart_toy_outlined,
                        color: orangeColor,
                      ),
                      title: Text(
                        s.key,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      subtitle: Text(
                        'Model: ${s.model} • Max Turns: ${s.maxTurns}\n${s.description}',
                        style: const TextStyle(fontSize: 11),
                      ),
                      isThreeLine: s.description.isNotEmpty,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            tooltip: 'Edit Subagent',
                            onPressed: () => _showSubAgentDialog(context, s),
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.delete_outline,
                              size: 18,
                              color: Colors.redAccent,
                            ),
                            tooltip: 'Delete Subagent',
                            onPressed: () async {
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: Text('Delete subagent "${s.key}"?'),
                                  content: const Text(
                                    'This action will remove the subagent from the database.',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(ctx, false),
                                      child: const Text('Cancel'),
                                    ),
                                    FilledButton(
                                      style: FilledButton.styleFrom(
                                        backgroundColor: Colors.redAccent,
                                      ),
                                      onPressed: () => Navigator.pop(ctx, true),
                                      child: const Text('Delete'),
                                    ),
                                  ],
                                ),
                              );
                              if (confirm == true) {
                                await ref
                                    .read(subagentsListProvider.notifier)
                                    .remove(s.key);
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              );
            },
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Future<void> _showSubAgentDialog(
    BuildContext context,
    SubAgentDefinition? initial,
  ) async {
    final isEdit = initial != null;
    final keyCtrl = TextEditingController(text: initial?.key ?? '');
    final nameCtrl = TextEditingController(text: initial?.name ?? '');
    final modelCtrl = TextEditingController(text: initial?.model ?? 'default');
    final descCtrl = TextEditingController(text: initial?.description ?? '');
    final promptCtrl = TextEditingController(text: initial?.systemPrompt ?? '');
    final maxTurnsCtrl = TextEditingController(
      text: (initial?.maxTurns ?? 8).toString(),
    );
    List<String> selectedTools = List<String>.from(initial?.tools ?? const []);

    final isDesktopPlatform = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.macOS);
    final isMobile =
        !isDesktopPlatform || MediaQuery.sizeOf(context).width < 700;

    const codingTools = {
      'fs_read_file',
      'fs_write_file',
      'fs_replace_text',
      'terminal_exec',
      'fs_list_dir',
      'fs_find',
      'fs_move_file',
      'fs_delete_file',
    };

    final availableTools = isMobile
        ? [
            'web_search',
            'fetch',
            ...selectedTools.where(
              (t) =>
                  !codingTools.contains(t) &&
                  t != 'web_search' &&
                  t != 'fetch',
            ),
          ]
        : [
            'fs_read_file',
            'fs_write_file',
            'fs_replace_text',
            'terminal_exec',
            'fs_list_dir',
            'fs_find',
            'web_search',
            'fetch',
          ];

    final llmSettings = ref.read(llmSettingsProvider);
    final availableProfiles = llmSettings.profiles;

    String? selectedProfileValue;
    final currentModel = modelCtrl.text.trim();
    if (currentModel == 'default' || currentModel.isEmpty) {
      selectedProfileValue = 'default';
    } else {
      final match = availableProfiles
          .where(
            (p) =>
                p.model == currentModel ||
                p.name == currentModel ||
                p.id == currentModel,
          )
          .firstOrNull;
      if (match != null) {
        selectedProfileValue =
            match.id;
      } else {
        selectedProfileValue = '__custom__';
      }
    }

    String? selectedTemplateKey;

    Future<void> onSave(BuildContext ctx) async {
      final k = keyCtrl.text.trim();
      if (k.isEmpty) return;

      final def = SubAgentDefinition(
        key: k,
        name: nameCtrl.text.trim(),
        description: descCtrl.text.trim(),
        model: modelCtrl.text.trim().isEmpty
            ? 'default'
            : modelCtrl.text.trim(),
        systemPrompt: promptCtrl.text.trim(),
        tools: selectedTools,
        maxTurns: int.tryParse(maxTurnsCtrl.text.trim()) ?? 8,
      );

      await ref.read(subagentsListProvider.notifier).save(def);
      if (ctx.mounted) Navigator.pop(ctx);
    }

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) {
          final formContent = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Template Dropdown
              DropdownButtonFormField<String>(
                initialValue: selectedTemplateKey,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Choose Template / Inbuilt Sub-Agent',
                  prefixIcon: Icon(Icons.auto_awesome, size: 18),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  const DropdownMenuItem(
                    value: null,
                    child: Text(
                      'Custom Sub-Agent',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  ...SubAgentDefinition.predefined.map(
                    (p) => DropdownMenuItem(
                      value: p.key,
                      child: Text(
                        '${p.displayName} (${p.key})',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
                onChanged: (val) {
                  setDlgState(() {
                    selectedTemplateKey = val;
                    if (val != null) {
                      final tmpl = SubAgentDefinition.predefined
                          .firstWhere((p) => p.key == val);
                      if (!isEdit) keyCtrl.text = tmpl.key;
                      nameCtrl.text = tmpl.name;
                      descCtrl.text = tmpl.description;
                      promptCtrl.text = tmpl.systemPrompt;
                      maxTurnsCtrl.text = tmpl.maxTurns.toString();
                      selectedTools = isMobile
                          ? List<String>.from(
                              tmpl.tools.where((t) => !codingTools.contains(t)),
                            )
                          : List<String>.from(tmpl.tools);
                      if (isMobile && selectedTools.isEmpty) {
                        selectedTools = ['web_search'];
                      }
                    }
                  });
                },
              ),
              const SizedBox(height: 12),

              if (!isEdit) ...[
                TextFormField(
                  controller: keyCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Subagent Key (Identifier)',
                    hintText: 'e.g. unit_tester, git_auditor',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
              ],

              TextFormField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Display Name',
                  hintText: 'e.g. Automated Unit Test Specialist',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),

              DropdownButtonFormField<String>(
                initialValue: selectedProfileValue,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Assignee (LLM Profile)',
                  prefixIcon: Icon(Icons.psychology_outlined, size: 18),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  const DropdownMenuItem(
                    value: 'default',
                    child: Text(
                      'Default (Active Model)',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  ...availableProfiles.map((p) {
                    final val = p.id;
                    return DropdownMenuItem(
                      value: val,
                      child: Text(
                        '${p.name.isNotEmpty ? p.name : (p.model.isNotEmpty ? p.model : p.id)}${p.model.isNotEmpty && p.model != p.name ? ' (${p.model})' : ''} [${p.provider.label}]',
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  }),
                  const DropdownMenuItem(
                    value: '__custom__',
                    child: Text(
                      'Custom Model Identifier...',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
                onChanged: (val) {
                  setDlgState(() {
                    selectedProfileValue = val;
                    if (val != null && val != '__custom__') {
                      if (val == 'default') {
                        modelCtrl.text = 'default';
                      } else {
                        final prof = availableProfiles
                            .where((p) => p.id == val)
                            .firstOrNull;
                        if (prof != null) {
                          modelCtrl.text = prof.model.isNotEmpty
                              ? prof.model
                              : prof.name;
                        } else {
                          modelCtrl.text = val;
                        }
                      }
                    }
                  });
                },
              ),
              if (selectedProfileValue == '__custom__') ...[
                const SizedBox(height: 8),
                TextFormField(
                  controller: modelCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Custom Model Name',
                    hintText: 'e.g. gemma-4-31b-it, deepseek-coder',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ],
              const SizedBox(height: 12),

              TextFormField(
                controller: maxTurnsCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Max Turns',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),

              TextFormField(
                controller: descCtrl,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  hintText:
                      'Brief summary of what this subagent specializes in',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),

              TextFormField(
                controller: promptCtrl,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'System Prompt / Persona',
                  hintText:
                      'Specialized instructions and constraints for this sub-agent...',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),

              const Text(
                'Allowed Tools (Whitelist):',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: availableTools.map((tool) {
                  final isSel = selectedTools.contains(tool);
                  return FilterChip(
                    label: Text(
                      tool,
                      style: const TextStyle(fontSize: 11),
                    ),
                    selected: isSel,
                    onSelected: (sel) {
                      setDlgState(() {
                        if (sel) {
                          selectedTools.add(tool);
                        } else {
                          selectedTools.remove(tool);
                        }
                      });
                    },
                  );
                }).toList(),
              ),
            ],
          );

          if (isMobile) {
            return Dialog.fullscreen(
              child: Scaffold(
                appBar: AppBar(
                  leading: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                  title: Text(
                    isEdit
                        ? 'Edit Sub-Agent: ${initial.key}'
                        : 'Add Subagent Role',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  actions: [
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilledButton(
                        onPressed: () => onSave(ctx),
                        child: Text(isEdit ? 'Save' : 'Add'),
                      ),
                    ),
                  ],
                ),
                body: SafeArea(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16.0),
                    child: formContent,
                  ),
                ),
              ),
            );
          }

          return AlertDialog(
            title: Text(
              isEdit ? 'Edit Sub-Agent: ${initial.key}' : 'Add Subagent Role',
            ),
            content: SizedBox(
              width: 540,
              child: SingleChildScrollView(
                child: formContent,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => onSave(ctx),
                child: const Text('Save Subagent'),
              ),
            ],
          );
        },
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────
  // Tab 2: MCP Servers Tab
  // ─────────────────────────────────────────────────────────────

  Widget _buildMcpServersTab(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(16.0),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'CONFIGURED MCP SERVERS',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.add_link, size: 24),
              tooltip: 'Add / Catalog MCP',
              onPressed: () => RemoteMcpDialog.show(context, widget.controller),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (widget.controller.servers.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24.0),
            child: Center(
              child: Text(
                'No HTTP MCP servers configured.',
                style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
              ),
            ),
          )
        else
          ...widget.controller.servers.map((server) {
            final statusColor = server.isOnline == true
                ? Colors.green
                : (server.isOnline == false ? Colors.red : Colors.grey);
            final statusLabel = server.isOnline == true
                ? 'Online'
                : (server.isOnline == false ? 'Offline' : 'Unknown');
            final apiKeyStatus = (server.apiKey ?? '').trim().isNotEmpty
                ? 'API key configured'
                : 'API key missing';

            return Card(
              margin: const EdgeInsets.symmetric(vertical: 6),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Tooltip(
                          message: 'Server Status: $statusLabel',
                          child: Icon(
                            Icons.circle,
                            size: 10,
                            color: statusColor,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Transform.scale(
                          scale: 0.8,
                          child: Switch(
                            value: server.enabled,
                            onChanged: (val) =>
                                widget.controller.toggleServer(server.id, val),
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.list_alt, size: 20),
                          tooltip: 'Discover Tools',
                          onPressed: () => _discoverServerTools(server),
                        ),
                        IconButton(
                          icon: const Icon(Icons.edit_outlined, size: 20),
                          tooltip: 'Edit Server',
                          onPressed: () => EditMcpServerDialog.show(
                            context,
                            server,
                            widget.controller,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.wifi_tethering, size: 20),
                          tooltip: 'Test Connection',
                          onPressed: () => _testMcpServerConnection(server),
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.delete_outline,
                            color: Colors.red,
                            size: 20,
                          ),
                          tooltip: 'Remove',
                          onPressed: () =>
                              widget.controller.removeServer(server.id),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      server.name,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      [
                        if (server.description != null &&
                            server.description!.trim().isNotEmpty)
                          server.description!.trim(),
                        '${server.url}${server.mcpEndpoint}',
                        'Cloud MCP - $statusLabel',
                        apiKeyStatus,
                      ].join('\n'),
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.8,
                        ),
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
      ],
    );
  }
}

class _FieldCache {
  final String model;
  final String apiKey;
  final String baseUrl;

  const _FieldCache({
    required this.model,
    required this.apiKey,
    required this.baseUrl,
  });
}
