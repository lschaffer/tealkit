import 'dart:async';

import 'package:material_ui/material_ui.dart';
import '../l10n/app_localizations.dart';
import '../config/app_theme.dart';
import '../services/app_logger.dart';
import '../services/app_preferences_service.dart';
import '../services/llm_settings_service.dart';
import '../services/llm_task_resync_service.dart';
import '../services/server_api_client.dart';
import 'embedded_llm/embedded_model_picker_widget.dart';
import '../services/embedded_llm/embedded_llm_adapter.dart';
import 'llm_settings_form_widget.dart';

/// Full-screen dialog for configuring default LLM settings.
///
/// Refactored to a 2-tab structure:
/// 1. "LLMs" - A collection of user-defined named LLM profiles (Add, Edit, Clone, Delete).
/// 2. "Embedded" - On-device GGUF / llama.cpp model management.
class LlmSettingsDialog extends StatefulWidget {
  final LlmSettingsService service;
  final ServerApiClient? serverClient;
  final bool isLightMode;

  const LlmSettingsDialog({
    super.key,
    required this.service,
    this.serverClient,
    this.isLightMode = false,
  });

  /// Open the dialog and return `true` when saved, `null` when cancelled.
  static Future<bool?> show(
    BuildContext context,
    LlmSettingsService service, {
    ServerApiClient? serverClient,
    bool isLightMode = false,
  }) {
    return Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => LlmSettingsDialog(
          service: service,
          serverClient: serverClient,
          isLightMode: isLightMode,
        ),
      ),
    );
  }

  @override
  State<LlmSettingsDialog> createState() => _LlmSettingsDialogState();
}

class _LlmSettingsDialogState extends State<LlmSettingsDialog>
    with TickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  late final TabController _tabController;

  // ── Profiles state ───────────────────────────────
  List<NamedLlmProfile> _profiles = [];
  String _selectedProfileId = '';
  String? _editingProfileId; // null = list view, non-null = editing/adding

  // ── Active profile editing form state ────────────
  final TextEditingController _nameCtrl = TextEditingController();
  LlmProvider _provider = LlmProvider.none;
  final TextEditingController _modelCtrl = TextEditingController();
  final TextEditingController _apiKeyCtrl = TextEditingController();
  final TextEditingController _baseUrlCtrl = TextEditingController();
  final TextEditingController _temperatureCtrl = TextEditingController(text: '0.2');
  final TextEditingController _maxTokensCtrl = TextEditingController(text: '0');
  final TextEditingController _maxToolOutputSizeCtrl = TextEditingController(text: '2560000');
  final TextEditingController _tokenWarningThresholdCtrl = TextEditingController(text: '1500000');
  final TextEditingController _topKCtrl = TextEditingController();
  final TextEditingController _topPCtrl = TextEditingController();
  final TextEditingController _repeatPenaltyCtrl = TextEditingController();
  final TextEditingController _seedCtrl = TextEditingController();
  bool _isSlm = false;
  bool _isMultiModal = true;
  bool _thinking = false;
  bool _useNativeToolCall = true;
  bool _useSafeToolCall = false;

  // ── Global tool execution settings ───────────────
  bool _saving = false;
  bool _isLightMode = false;
  bool _enableToolParameterAutoRecovery = true;
  bool _injectToolCallingRules = true;
  bool _enable2ndStageToolFiltering = true;
  String _toolFilteringLlmSource = 'llm1';
  String _toolDeliveryStrategy = 'auto';
  bool _isGlobalSettingsExpanded = false;

  // ── Embedded tab state ────────────────────────────
  String _embeddedModelFile = '';

  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _isLightMode = widget.isLightMode;
    _tabController = TabController(length: _isLightMode ? 1 : 2, vsync: this);
    _initFromService();
  }

  Future<void> _initFromService() async {
    final s = widget.service;
    if (!s.isLoaded) {
      await s.load();
    }

    Map<String, dynamic> remote = {};
    if (widget.serverClient != null) {
      try {
        remote = await widget.serverClient!.getLlmSettings();
        log.info('[LLM Settings] Loaded settings from server.');
      } catch (e) {
        log.warning('[LLM Settings] Failed to load from server — falling back to local: $e');
      }
    }

    if (!mounted) return;
    setState(() {
      if (remote.isNotEmpty) {
        widget.service.applyRemoteState(remote);
      }
      _profiles = List.from(widget.service.profiles);
      _selectedProfileId = widget.service.selectedProfile?.id ??
          (_profiles.isNotEmpty ? _profiles.first.id : '');
      _enableToolParameterAutoRecovery = widget.service.enableToolParameterAutoRecovery;
      _injectToolCallingRules = widget.service.injectToolCallingRules;
      _enable2ndStageToolFiltering = widget.service.enable2ndStageToolFiltering;
      _toolFilteringLlmSource = widget.service.toolFilteringLlmSource;
      _toolDeliveryStrategy = widget.service.toolDeliveryStrategy;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _nameCtrl.dispose();
    _modelCtrl.dispose();
    _apiKeyCtrl.dispose();
    _baseUrlCtrl.dispose();
    _temperatureCtrl.dispose();
    _maxTokensCtrl.dispose();
    _maxToolOutputSizeCtrl.dispose();
    _tokenWarningThresholdCtrl.dispose();
    _topKCtrl.dispose();
    _topPCtrl.dispose();
    _repeatPenaltyCtrl.dispose();
    _seedCtrl.dispose();
    super.dispose();
  }

  void _startEditProfile(NamedLlmProfile profile) {
    setState(() {
      _editingProfileId = profile.id;
      _nameCtrl.text = profile.name;
      _provider = profile.provider;
      _modelCtrl.text = profile.model;
      _apiKeyCtrl.text = profile.apiKey;
      _baseUrlCtrl.text = profile.baseUrl;
      _temperatureCtrl.text = profile.temperature.toString();
      _maxTokensCtrl.text = profile.maxTokens.toString();
      _maxToolOutputSizeCtrl.text = profile.maxToolOutputSize.toString();
      _tokenWarningThresholdCtrl.text = profile.tokenWarningThreshold.toString();
      _topKCtrl.text = profile.topK?.toString() ?? '';
      _topPCtrl.text = profile.topP?.toString() ?? '';
      _repeatPenaltyCtrl.text = profile.repeatPenalty?.toString() ?? '';
      _seedCtrl.text = profile.seed?.toString() ?? '';
      _isSlm = profile.isSlm;
      _isMultiModal = profile.isMultiModal;
      _thinking = profile.thinking;
      _useNativeToolCall = profile.useNativeToolCall;
      _useSafeToolCall = profile.useSafeToolCall;
    });
  }

  void _startAddProfile() {
    final newId = 'llm_${DateTime.now().millisecondsSinceEpoch}';
    final count = _profiles.length + 1;
    setState(() {
      _editingProfileId = newId;
      _nameCtrl.text = 'LLM $count';
      _provider = LlmProvider.gemini;
      _modelCtrl.text = 'gemini-2.5-flash';
      _apiKeyCtrl.text = widget.service.getApiKeyForProvider(LlmProvider.gemini);
      _baseUrlCtrl.text = '';
      _temperatureCtrl.text = '0.2';
      _maxTokensCtrl.text = '0';
      _maxToolOutputSizeCtrl.text = '2560000';
      _tokenWarningThresholdCtrl.text = '1500000';
      _topKCtrl.clear();
      _topPCtrl.clear();
      _repeatPenaltyCtrl.clear();
      _seedCtrl.clear();
      _isSlm = false;
      _isMultiModal = true;
      _thinking = false;
      _useNativeToolCall = true;
      _useSafeToolCall = false;
    });
  }

  Future<void> _cloneProfile(NamedLlmProfile profile) async {
    final cloned = await widget.service.cloneProfile(profile.id);
    setState(() {
      _profiles = List.from(widget.service.profiles);
    });
    await _syncToServer();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Cloned "${profile.name}" to "${cloned.name}"'),
          action: SnackBarAction(
            label: 'Edit',
            onPressed: () => _startEditProfile(cloned),
          ),
        ),
      );
    }
  }

  Future<void> _deleteProfile(NamedLlmProfile profile) async {
    if (_profiles.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot delete the only LLM profile.')),
      );
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${profile.name}"?'),
        content: const Text('Are you sure you want to remove this LLM profile?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete', style: TextStyle(color: AppTheme.error)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await widget.service.deleteProfile(profile.id);
      setState(() {
        _profiles = List.from(widget.service.profiles);
        _selectedProfileId = widget.service.selectedProfile?.id ??
            (_profiles.isNotEmpty ? _profiles.first.id : '');
      });
      await _syncToServer();
    }
  }

  Future<void> _selectProfile(NamedLlmProfile profile) async {
    await widget.service.selectProfile(profile.id);
    setState(() {
      _selectedProfileId = profile.id;
    });
    await _syncToServer();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Active LLM set to "${profile.name}"')),
      );
    }
  }

  Future<void> _saveCurrentEditingProfile() async {
    if (!_formKey.currentState!.validate()) return;
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;

    final updated = NamedLlmProfile(
      id: _editingProfileId!,
      name: name,
      provider: _provider,
      model: _modelCtrl.text.trim(),
      apiKey: _provider == LlmProvider.embedded ? '' : _apiKeyCtrl.text.trim(),
      baseUrl: _baseUrlCtrl.text.trim(),
      temperature: double.tryParse(_temperatureCtrl.text) ?? 0.2,
      maxTokens: int.tryParse(_maxTokensCtrl.text) ?? 0,
      maxToolOutputSize: int.tryParse(_maxToolOutputSizeCtrl.text) ?? 2560000,
      tokenWarningThreshold: int.tryParse(_tokenWarningThresholdCtrl.text) ?? 1500000,
      isSlm: _isSlm,
      isMultiModal: _isMultiModal,
      thinking: _thinking,
      useNativeToolCall: _useNativeToolCall,
      useSafeToolCall: _useSafeToolCall,
      topK: int.tryParse(_topKCtrl.text.trim()),
      topP: double.tryParse(_topPCtrl.text.trim()),
      repeatPenalty: double.tryParse(_repeatPenaltyCtrl.text.trim()),
      seed: int.tryParse(_seedCtrl.text.trim()),
    );

    await widget.service.saveProfile(updated);
    setState(() {
      _profiles = List.from(widget.service.profiles);
      _editingProfileId = null;
    });
    await _syncToServer();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved profile "$name"')),
      );
    }
  }

  Future<void> _syncToServer() async {
    if (widget.serverClient == null) return;
    try {
      final active = widget.service.selectedProfile ??
          (_profiles.isNotEmpty ? _profiles.first : null);
      final coding = _profiles.length > 1 ? _profiles[1] : active;

      final llmPayload = <String, dynamic>{
        'profiles': _profiles.map((p) => p.toJson()).toList(),
        'selected_profile_id': _selectedProfileId,
        'provider': active?.provider.configKey ?? '',
        'model': active?.model ?? '',
        'api_key': active?.apiKey ?? '',
        'base_url': active?.baseUrl ?? '',
        'temperature': active?.temperature ?? 0.2,
        'max_tokens': active?.maxTokens ?? 0,
        'is_slm': active?.isSlm ?? false,
        'is_multi_modal': active?.isMultiModal ?? true,
        'thinking': active?.thinking ?? false,
        'use_native_tool_call': active?.useNativeToolCall ?? true,
        'use_safe_tool_call': active?.useSafeToolCall ?? false,
        'enable_tool_parameter_auto_recovery': _enableToolParameterAutoRecovery,
        'inject_tool_calling_rules': _injectToolCallingRules,
        'enable_2nd_stage_tool_filtering': _enable2ndStageToolFiltering,
        'tool_filtering_llm_source': _toolFilteringLlmSource,
        'tool_delivery_strategy': _toolDeliveryStrategy,
        'max_tool_output_size': active?.maxToolOutputSize ?? 2560000,
        'token_warning_threshold': active?.tokenWarningThreshold ?? 1500000,
        'top_k': active?.topK,
        'top_p': active?.topP,
        'repeat_penalty': active?.repeatPenalty,
        'seed': active?.seed,
        'provider2': coding?.provider.configKey ?? '',
        'model2': coding?.model ?? '',
        'api_key2': coding?.apiKey ?? '',
        'base_url2': coding?.baseUrl ?? '',
        'temperature2': coding?.temperature ?? 0.2,
        'max_tokens2': coding?.maxTokens ?? 0,
        'is_slm2': coding?.isSlm ?? false,
        'is_multi_modal2': coding?.isMultiModal ?? true,
        'thinking2': coding?.thinking ?? false,
        'use_native_tool_call2': coding?.useNativeToolCall ?? true,
        'use_safe_tool_call2': coding?.useSafeToolCall ?? false,
        'max_tool_output_size2': coding?.maxToolOutputSize ?? 2560000,
        'token_warning_threshold2': coding?.tokenWarningThreshold ?? 1500000,
        'top_k2': coding?.topK,
        'top_p2': coding?.topP,
        'repeat_penalty2': coding?.repeatPenalty,
        'seed2': coding?.seed,
      };
      await widget.serverClient!.putLlmSettings(llmPayload);
      widget.service.applyRemoteState(llmPayload);
      // ignore: unawaited_futures
      LlmTaskResyncService.resyncLlm2Tasks();
      log.info('[LLM Settings] Synced all profiles and global execution settings to server.');
    } catch (e) {
      log.warning('[LLM Settings] Failed to sync to server: $e');
    }
  }

  Future<void> _saveAllSettings() async {
    setState(() => _saving = true);
    try {
      await widget.service.setInjectToolCallingRules(_injectToolCallingRules);
      await widget.service.setEnable2ndStageToolFiltering(_enable2ndStageToolFiltering);
      await widget.service.setToolFilteringLlmSource(_toolFilteringLlmSource);
      await widget.service.setToolDeliveryStrategy(_toolDeliveryStrategy);
      await _syncToServer();

      if (mounted) {
        final l = L.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l.llmSettingsSaved),
            behavior: SnackBarBehavior.floating,
          ),
        );
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      log.error('[LLM Settings] save error: $e');
      if (mounted) {
        final l = L.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l.llmSettingsSaveFailed(e.toString())),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final theme = Theme.of(context);
    final uiStyle = AppPreferencesService.instance.uiStyle;
    final isModern = uiStyle == 'modern';
    final isMobile = MediaQuery.of(context).size.width < 600;

    return Scaffold(
      appBar: AppBar(
        title: Text(l.llmSettings),
        actions: [
          if (_editingProfileId == null)
            IconButton(
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.check),
              tooltip: l.save,
              onPressed: _saving ? null : _saveAllSettings,
            ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            const Tab(text: 'LLMs'),
            if (!_isLightMode) const Tab(text: 'Embedded'),
          ],
        ),
      ),
      bottomNavigationBar: _editingProfileId != null
          ? null
          : SafeArea(
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: isMobile ? 5 : 16,
                  vertical: 8,
                ),
                child: FilledButton.icon(
                  onPressed: _saving ? null : _saveAllSettings,
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.save),
                  label: Text(l.save),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    backgroundColor: AppTheme.primaryBlue,
                  ),
                ),
              ),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: _editingProfileId != null
                  ? _buildProfileEditView(theme, isModern)
                  : AnimatedBuilder(
                      animation: _tabController,
                      builder: (context, _) => IndexedStack(
                        index: _tabController.index,
                        children: [
                          _buildProfilesListView(theme, isModern),
                          if (!_isLightMode) _buildEmbeddedTab(l, theme),
                        ],
                      ),
                    ),
            ),
    );
  }

  // ───────────────────────────────────────────────────
  // Tab 1 View: LLMs List
  // ───────────────────────────────────────────────────

  Widget _buildProfilesListView(ThemeData theme, bool isModern) {
    final isMobile = MediaQuery.of(context).size.width < 600;

    return ListView(
      padding: EdgeInsets.symmetric(
        horizontal: isMobile ? 5 : 16,
        vertical: isMobile ? 8 : 16,
      ),
      children: [
        _buildGlobalSettingsSection(theme, isModern),
        SizedBox(height: isMobile ? 10 : 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Configured LLMs',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Define and manage models for Assistant and Workflows.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            FilledButton.icon(
              onPressed: _startAddProfile,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add LLM'),
              style: FilledButton.styleFrom(
                backgroundColor: isModern
                    ? const Color(0xFF7C3AED)
                    : AppTheme.primaryBlue,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),

        if (_profiles.isEmpty)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                'No LLMs configured yet. Click "+ Add LLM" to get started.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          )
        else
          ..._profiles.map((p) => _buildProfileCard(p, theme, isModern)),

        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildProfileCard(
    NamedLlmProfile profile,
    ThemeData theme,
    bool isModern,
  ) {
    final isMobile = MediaQuery.of(context).size.width < 600;
    final isActive = profile.id == _selectedProfileId;

    return Padding(
      padding: EdgeInsets.only(bottom: isMobile ? 8 : 12),
      child: _buildConfigCard(
        isModern: isModern,
        theme: theme,
        baseColor: isActive
            ? (isModern ? const Color(0xFF7C3AED) : AppTheme.primaryBlue)
            : theme.colorScheme.outlineVariant,
        classicBgColor: isActive
            ? AppTheme.primaryBlue.withValues(alpha: 0.06)
            : theme.colorScheme.surface,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: isMobile ? 8 : 14,
            vertical: isMobile ? 10 : 14,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: (isActive
                            ? (isModern
                                ? const Color(0xFF7C3AED)
                                : AppTheme.primaryBlue)
                            : theme.colorScheme.surfaceContainerHighest)
                        .withValues(alpha: 0.2),
                    child: Icon(
                      _providerIcon(profile.provider),
                      color: isActive
                          ? (isModern
                              ? const Color(0xFF7C3AED)
                              : AppTheme.primaryBlue)
                          : theme.colorScheme.onSurfaceVariant,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                profile.name,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (isActive) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: AppTheme.success.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: AppTheme.success.withValues(alpha: 0.4),
                                    width: 1,
                                  ),
                                ),
                                child: Text(
                                  'Active / Primary',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: AppTheme.success,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${profile.provider.label} • ${profile.model.isEmpty ? "No model selected" : profile.model}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (!isActive)
                    TextButton.icon(
                      onPressed: () => _selectProfile(profile),
                      icon: const Icon(Icons.check_circle_outline, size: 16),
                      label: const Text('Set Active'),
                    ),
                  IconButton(
                    icon: const Icon(Icons.copy_outlined, size: 18),
                    tooltip: 'Duplicate / Clone',
                    onPressed: () => _cloneProfile(profile),
                  ),
                  IconButton(
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    tooltip: 'Edit Profile',
                    onPressed: () => _startEditProfile(profile),
                  ),
                  IconButton(
                    icon: Icon(Icons.delete_outline, size: 18, color: AppTheme.error),
                    tooltip: 'Delete Profile',
                    onPressed: () => _deleteProfile(profile),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ───────────────────────────────────────────────────
  // Tab 1 Subview: Edit Profile
  // ───────────────────────────────────────────────────

  Widget _buildProfileEditView(ThemeData theme, bool isModern) {
    final isMobile = MediaQuery.of(context).size.width < 600;

    return ListView(
      padding: EdgeInsets.symmetric(
        horizontal: isMobile ? 5 : 16,
        vertical: isMobile ? 8 : 16,
      ),
      children: [
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back),
              tooltip: 'Back to LLMs list',
              onPressed: () => setState(() => _editingProfileId = null),
            ),
            const SizedBox(width: 8),
            Text(
              'Edit Profile',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        LlmSettingsFormWidget(
          nameController: _nameCtrl,
          providerKey: _provider.configKey,
          modelController: _modelCtrl,
          apiKeyController: _apiKeyCtrl,
          baseUrlController: _baseUrlCtrl,
          temperatureController: _temperatureCtrl,
          maxTokensController: _maxTokensCtrl,
          topKController: _topKCtrl,
          topPController: _topPCtrl,
          repeatPenaltyController: _repeatPenaltyCtrl,
          seedController: _seedCtrl,
          maxToolOutputSizeController: _maxToolOutputSizeCtrl,
          tokenWarningThresholdController: _tokenWarningThresholdCtrl,
          isSlm: _isSlm,
          isMultiModal: _isMultiModal,
          thinking: _thinking,
          useNativeToolCall: _useNativeToolCall,
          useSafeToolCall: _useSafeToolCall,
          enableToolParameterAutoRecovery: _enableToolParameterAutoRecovery,
          service: widget.service,
          serverClient: widget.serverClient,
          showEmbeddedOption: !_isLightMode,
          onProviderChanged: (key) {
            setState(() {
              _provider = LlmProvider.fromConfigKey(key);
            });
          },
          onSlmChanged: (v) => setState(() => _isSlm = v),
          onMultiModalChanged: (v) => setState(() => _isMultiModal = v),
          onThinkingChanged: (v) => setState(() => _thinking = v),
          onUseNativeToolCallChanged: (v) => setState(() => _useNativeToolCall = v),
          onUseSafeToolCallChanged: (v) => setState(() => _useSafeToolCall = v),
        ),

        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => setState(() => _editingProfileId = null),
                child: const Text('Cancel'),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: FilledButton.icon(
                onPressed: _saveCurrentEditingProfile,
                icon: const Icon(Icons.check),
                label: const Text('Save Profile'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.primaryBlue,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  // ───────────────────────────────────────────────────
  // Tab 2 View: Embedded
  // ───────────────────────────────────────────────────

  Widget _buildEmbeddedTab(L l, ThemeData theme) {
    final uiStyle = AppPreferencesService.instance.uiStyle;
    final isModern = uiStyle == 'modern';
    final isMobile = MediaQuery.of(context).size.width < 600;

    return ListView(
      padding: EdgeInsets.symmetric(
        horizontal: isMobile ? 5 : 16,
        vertical: isMobile ? 8 : 16,
      ),
      children: [
        _buildGlobalSettingsSection(theme, isModern),
        SizedBox(height: isMobile ? 10 : 16),
        _buildConfigCard(
          isModern: isModern,
          theme: theme,
          baseColor: isModern ? const Color(0xFF7C3AED) : AppTheme.primaryBlue,
          classicBgColor: AppTheme.primaryBlue.withValues(alpha: 0.08),
          child: Padding(
            padding: EdgeInsets.all(isMobile ? 8 : 12),
            child: Row(
              children: [
                Icon(
                  Icons.memory,
                  color: isModern
                      ? const Color(0xFF7C3AED)
                      : AppTheme.primaryBlue,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Manage on-device GGUF models. Download and preload a model into '
                    'app memory here — available across Assistant and Workflows.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: isModern
                          ? const Color(0xFF7C3AED)
                          : AppTheme.primaryBlue,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        EmbeddedModelPickerWidget(
          selectedFilename: _embeddedModelFile,
          serverClient: widget.serverClient,
          onFilenameSelected: (filename) =>
              setState(() => _embeddedModelFile = filename),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  // ───────────────────────────────────────────────────
  // Global Execution & Tool Calling Rules
  // ───────────────────────────────────────────────────

  Widget _buildGlobalSettingsSection(ThemeData theme, bool isModern) {
    final isMobile = MediaQuery.of(context).size.width < 600;
    return _buildConfigCard(
      isModern: isModern,
      theme: theme,
      baseColor: isModern ? const Color(0xFF7C3AED) : AppTheme.primaryBlue,
      classicBgColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: isMobile ? 8 : 14,
          vertical: isMobile ? 6 : 10,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: () => setState(() => _isGlobalSettingsExpanded = !_isGlobalSettingsExpanded),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.rule_outlined,
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Global Tool Rules & Strategy',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (!_isGlobalSettingsExpanded)
                            Text(
                              'Strategy: ${_toolDeliveryStrategy.toUpperCase()} • Tool Rules: ${_injectToolCallingRules ? "Active" : "Off"}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontSize: 11,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
                    Icon(
                      _isGlobalSettingsExpanded ? Icons.expand_less : Icons.expand_more,
                      size: 22,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
            if (_isGlobalSettingsExpanded) ...[
              const SizedBox(height: 6),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text(
                  'Inject Tool Calling Rules',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                ),
                subtitle: const Text(
                  'Appends strict completion rules to system prompts so smaller models stop calling tools once the answer is ready',
                  style: TextStyle(fontSize: 11.5),
                ),
                value: _injectToolCallingRules,
                onChanged: (val) =>
                    setState(() => _injectToolCallingRules = val ?? true),
                controlAffinity: ListTileControlAffinity.leading,
              ),
              const Divider(height: 12),
              _buildToolFilteringSection(theme),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildToolFilteringSection(ThemeData theme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 600;

        final dropdownItems = _profiles.map((p) {
          return DropdownMenuItem<String>(
            value: p.id,
            child: Text(p.name),
          );
        }).toList();

        if (dropdownItems.isEmpty) {
          dropdownItems.add(const DropdownMenuItem(value: 'llm1', child: Text('LLM 1 (Primary)')));
        }

        final currentLlmValue = dropdownItems.any((item) => item.value == _toolFilteringLlmSource)
            ? _toolFilteringLlmSource
            : dropdownItems.first.value;

        final filterLlmWidget = DropdownButtonFormField<String>(
          isExpanded: true,
          initialValue: currentLlmValue,
          decoration: const InputDecoration(
            labelText: 'Tool Filter Model',
            border: OutlineInputBorder(),
            isDense: true,
            prefixIcon: Icon(Icons.psychology_outlined, size: 20),
          ),
          items: dropdownItems.map((item) {
            final child = item.child;
            if (child is Text) {
              return DropdownMenuItem<String>(
                value: item.value,
                child: Text(child.data ?? '', overflow: TextOverflow.ellipsis),
              );
            }
            return item;
          }).toList(),
          selectedItemBuilder: (context) {
            return dropdownItems.map((item) {
              final child = item.child;
              final text = child is Text ? (child.data ?? '') : (item.value ?? '');
              return Text(text, overflow: TextOverflow.ellipsis);
            }).toList();
          },
          onChanged: (val) {
            if (val != null) setState(() => _toolFilteringLlmSource = val);
          },
        );

        final strategyDropdown = DropdownButtonFormField<String>(
          isExpanded: true,
          initialValue: _toolDeliveryStrategy,
          decoration: const InputDecoration(
            labelText: 'Tool Delivery Strategy',
            border: OutlineInputBorder(),
            isDense: true,
            prefixIcon: Icon(Icons.hub_outlined, size: 20),
          ),
          items: const [
            DropdownMenuItem(
              value: 'auto',
              child: Text(
                'Auto (Progressive for SLMs / >25 tools)',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            DropdownMenuItem(
              value: 'progressive',
              child: Text(
                'Progressive Discovery (mcp_list_tools, mcp_call_tool)',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            DropdownMenuItem(
              value: 'prefilter',
              child: Text(
                '2nd-Stage LLM Prefilter',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            DropdownMenuItem(
              value: 'direct',
              child: Text(
                'Direct Schemas (All tools in context)',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          selectedItemBuilder: (context) => const [
            Text('Auto (Progressive for SLMs / >25 tools)', overflow: TextOverflow.ellipsis),
            Text('Progressive Discovery (mcp_list_tools, mcp_call_tool)', overflow: TextOverflow.ellipsis),
            Text('2nd-Stage LLM Prefilter', overflow: TextOverflow.ellipsis),
            Text('Direct Schemas (All tools in context)', overflow: TextOverflow.ellipsis),
          ],
          onChanged: (val) {
            if (val != null) {
              setState(() {
                _toolDeliveryStrategy = val;
                if (val == 'prefilter') {
                  _enable2ndStageToolFiltering = true;
                } else if (val == 'direct' || val == 'progressive') {
                  _enable2ndStageToolFiltering = false;
                }
              });
            }
          },
        );

        NamedLlmProfile? activeProfile;
        for (final p in _profiles) {
          if (p.id == _selectedProfileId) {
            activeProfile = p;
            break;
          }
        }
        activeProfile ??= widget.service.selectedProfile ?? (_profiles.isNotEmpty ? _profiles.first : null);

        final isEmbeddedLoaded = EmbeddedLlmAdapter.instance.isLoaded;
        final embeddedPath = EmbeddedLlmAdapter.instance.loadedModelPath ?? _embeddedModelFile;
        final isEmbedded = activeProfile?.provider == LlmProvider.embedded || (activeProfile == null && isEmbeddedLoaded);

        final String activeModelName;
        if (isEmbedded && embeddedPath.isNotEmpty) {
          activeModelName = embeddedPath.split(RegExp(r'[\\/]')).last;
        } else if (activeProfile != null && activeProfile.model.isNotEmpty) {
          activeModelName = activeProfile.model;
        } else if (activeProfile != null && activeProfile.name.isNotEmpty) {
          activeModelName = activeProfile.name;
        } else {
          activeModelName = 'Active Model';
        }

        final isSlm = isEmbedded ||
            (activeProfile?.isSlm ?? false) ||
            RegExp(r'(?:^|[:\-_.])([0-9]+\.?[0-9]*)b(?:\b|-)', caseSensitive: false)
                .hasMatch(activeModelName.toLowerCase()) ||
            activeModelName.toLowerCase().contains('phi') ||
            activeModelName.toLowerCase().contains('mini') ||
            activeModelName.toLowerCase().contains('tiny');

        final String recommendedStrategy = isSlm ? 'prefilter' : 'progressive';
        final String recommendedTitle = isSlm ? '2nd-Stage LLM Prefilter' : 'Progressive Discovery';
        final bool isCurrentRecommended = _toolDeliveryStrategy == recommendedStrategy;

        final String recommendationReason = isSlm
            ? 'Local SLMs (like $activeModelName) have 2K–4K context limits and struggle with multi-step tool discovery. 2nd-Stage Prefilter uses a secondary LLM to preselect candidate tools upfront, feeding only 1–2 exact schemas directly.'
            : 'Frontier cloud LLMs (like $activeModelName) excel at autonomous tool exploration. Progressive Discovery passes only 2 meta-tools (~220 tokens total), saving >90% tokens and cost without an extra filter pass.';

        final strategyDescription = switch (_toolDeliveryStrategy) {
          'prefilter' =>
            '• 2nd-Stage Prefilter: Runs an upfront secondary LLM call (e.g. Hetzner, Gemini Flash) to preselect matching tools before the main turn.\n'
            '  ✓ Best for: Local GGUF / Embedded models & SLMs (≤14B) to prevent 4K context overflows and ensure direct tool calls.\n'
            '  ℹ️ Requires: A capable Tool Filter Model configured below.',
          'progressive' =>
            '• Progressive Discovery: Injects only 2 meta-tools (~220 tokens total). Discovers and executes tools on-demand via mcp_list_tools & mcp_call_tool.\n'
            '  ✓ Best for: High-capacity cloud models (DeepSeek, Claude, GPT, Gemini) with strong reasoning.\n'
            '  ⚠️ Avoid for 3B/7B SLMs: Small models may hallucinate search filters or blow context.',
          'direct' =>
            '• Direct Schemas: Passes all enabled tool definitions directly in context on every turn.\n'
            '  ✓ Best for: Small tool sets (<15 tools) or coding mode.\n'
            '  ⚠️ Warning: 20+ tools can easily exceed the 4K context limits of local embedded models.',
          _ =>
            '• Auto Mode: Automatically selects Progressive Discovery for cloud models or >25 tools, and direct schemas otherwise.\n'
            '  💡 Note for Local Models: For embedded SLMs with >15 tools, 2nd-Stage LLM Prefilter is strongly recommended over Auto.',
        };

        final showFilterModelSelector = _toolDeliveryStrategy == 'prefilter' || _toolDeliveryStrategy == 'auto';

        final isMobile = MediaQuery.of(context).size.width < 600;

        return Container(
          padding: EdgeInsets.all(isMobile ? 8 : 12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.explore_outlined,
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Tool Delivery & Discovery Strategy',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (isCompact) ...[
                strategyDropdown,
                if (showFilterModelSelector) ...[
                  const SizedBox(height: 10),
                  filterLlmWidget,
                ],
              ] else ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: strategyDropdown),
                    if (showFilterModelSelector) ...[
                      const SizedBox(width: 12),
                      Expanded(flex: 2, child: filterLlmWidget),
                    ],
                  ],
                ),
              ],
              const SizedBox(height: 10),
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: isMobile ? 8 : 10,
                  vertical: isMobile ? 6 : 8,
                ),
                decoration: BoxDecoration(
                  color: isCurrentRecommended
                      ? theme.colorScheme.primaryContainer.withValues(alpha: 0.25)
                      : theme.colorScheme.tertiaryContainer.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isCurrentRecommended
                        ? theme.colorScheme.primary.withValues(alpha: 0.4)
                        : theme.colorScheme.tertiary.withValues(alpha: 0.4),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      isCurrentRecommended ? Icons.check_circle_outline : Icons.lightbulb_outline,
                      size: 16,
                      color: isCurrentRecommended
                          ? theme.colorScheme.primary
                          : theme.colorScheme.tertiary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Recommended for $activeModelName (${isSlm ? "Local SLM" : "Cloud LLM"}): $recommendedTitle',
                            style: theme.textTheme.labelMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: isCurrentRecommended
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.tertiary,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            recommendationReason,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 11,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Text(
                strategyDescription,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 11.5,
                  height: 1.35,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ── Helpers ──────────────────────────────────────

  IconData _providerIcon(LlmProvider p) {
    switch (p) {
      case LlmProvider.none:
        return Icons.block;
      case LlmProvider.gemini:
        return Icons.auto_awesome;
      case LlmProvider.openai:
        return Icons.psychology;
      case LlmProvider.claude:
        return Icons.chat;
      case LlmProvider.mistral:
        return Icons.rocket_launch;
      case LlmProvider.ollama:
        return Icons.computer;
      case LlmProvider.openaiCompatible:
        return Icons.api;
      case LlmProvider.embedded:
        return Icons.memory;
    }
  }

  Widget _buildConfigCard({
    required Widget child,
    required Color baseColor,
    required Color classicBgColor,
    required bool isModern,
    ThemeData? theme,
  }) {
    if (isModern) {
      final isDark = (theme ?? Theme.of(context)).brightness == Brightness.dark;
      return Container(
        decoration: BoxDecoration(
          color: isDark
              ? baseColor.withValues(alpha: 0.08)
              : baseColor.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: baseColor.withValues(alpha: 0.35),
            width: 1.2,
          ),
        ),
        child: child,
      );
    } else {
      final isMobile = MediaQuery.of(context).size.width < 600;
      return Card(
        margin: isMobile
            ? const EdgeInsets.symmetric(horizontal: 0, vertical: 4)
            : const EdgeInsets.all(4.0),
        color: classicBgColor,
        child: child,
      );
    }
  }
}
