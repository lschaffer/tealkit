import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../l10n/app_localizations.dart';
import '../config/app_theme.dart';
import '../services/app_logger.dart';
import '../services/app_preferences_service.dart';
import '../services/embedded_llm/embedded_model_manager.dart';
import '../services/llm_settings_service.dart';
import '../services/llm_task_resync_service.dart';
import '../services/server_api_client.dart';
import 'embedded_llm/embedded_model_picker_widget.dart';
import 'llm_advanced_params_widget.dart';
import 'llm_settings_form_widget.dart';

/// Full-screen dialog for configuring default LLM settings.
///
/// Modelled after the ThiesAI LLMConfigDialog but adapted for
/// Mobile AI Agent.  Settings are persisted in secure storage.
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

  // ── LLM 1 state ──────────────────────────────────
  LlmProvider _provider = LlmProvider.none;
  final TextEditingController _modelCtrl = TextEditingController();
  final TextEditingController _apiKeyCtrl = TextEditingController();
  final TextEditingController _baseUrlCtrl = TextEditingController();
  final TextEditingController _temperatureCtrl = TextEditingController(
    text: '0.2',
  );
  final TextEditingController _maxTokensCtrl = TextEditingController(text: '0');
  final TextEditingController _maxToolOutputSizeCtrl = TextEditingController(
    text: '2560000',
  );
  final TextEditingController _tokenWarningThresholdCtrl =
      TextEditingController(text: '1500000');
  final TextEditingController _topKCtrl = TextEditingController();
  final TextEditingController _topPCtrl = TextEditingController();
  final TextEditingController _repeatPenaltyCtrl = TextEditingController();
  final TextEditingController _seedCtrl = TextEditingController();
  bool _saving = false;
  bool _priceLoading = false;
  bool _isSlm = false;
  bool _isMultiModal = true;
  bool _thinking = false;
  bool _useNativeToolCall = true;
  bool _useSafeToolCall = false;
  bool _isLightMode = false;
  bool _enableToolParameterAutoRecovery = true;
  Timer? _priceRefreshDebounce;

  // ── LLM 2 state ──────────────────────────────────
  LlmProvider _provider2 = LlmProvider.none;
  final TextEditingController _modelCtrl2 = TextEditingController();
  final TextEditingController _apiKeyCtrl2 = TextEditingController();
  final TextEditingController _baseUrlCtrl2 = TextEditingController();
  final TextEditingController _temperatureCtrl2 = TextEditingController(
    text: '0.2',
  );
  final TextEditingController _maxTokensCtrl2 = TextEditingController(
    text: '0',
  );
  final TextEditingController _maxToolOutputSizeCtrl2 = TextEditingController(
    text: '2560000',
  );
  final TextEditingController _tokenWarningThresholdCtrl2 =
      TextEditingController(text: '1500000');
  final TextEditingController _topKCtrl2 = TextEditingController();
  final TextEditingController _topPCtrl2 = TextEditingController();
  final TextEditingController _repeatPenaltyCtrl2 = TextEditingController();
  final TextEditingController _seedCtrl2 = TextEditingController();
  bool _isSlm2 = false;
  bool _isMultiModal2 = true;
  bool _thinking2 = false;
  bool _useNativeToolCall2 = true;
  bool _useSafeToolCall2 = false;

  // ── Embedded tab state ────────────────────────────
  /// Filename selected / preloaded in the standalone Embedded tab.
  String _embeddedModelFile = '';
  bool _showAdvancedEmbedded = false;

  // ── Ollama model lists ───────────────────────────

  bool _loading = true;
  bool _aiDataSharingConsent = false;

  bool get _isBaseUrlProvider =>
      _provider == LlmProvider.ollama ||
      _provider == LlmProvider.openaiCompatible ||
      _provider == LlmProvider.openai ||
      _provider == LlmProvider.mistral;

  bool get _isEmbeddedProvider => _provider == LlmProvider.embedded;

  bool get _isEmbeddedProvider2 => _provider2 == LlmProvider.embedded;

  bool get _isBaseUrlProvider2 =>
      _provider2 == LlmProvider.ollama ||
      _provider2 == LlmProvider.openaiCompatible ||
      _provider2 == LlmProvider.openai ||
      _provider2 == LlmProvider.mistral;

  @override
  @override
  void initState() {
    super.initState();
    _isLightMode = widget.isLightMode;
    _tabController = TabController(length: _isLightMode ? 2 : 3, vsync: this);
    // Re-load from secure storage to guarantee we have the latest values
    _initFromService();
  }

  Future<void> _initFromService() async {
    final s = widget.service;
    // Ensure local data is loaded (no-op if already loaded) — used as fallback.
    if (!s.isLoaded) {
      await s.load();
    }

    // In server mode: fetch settings from the remote server so the dialog always
    // shows what the server actually has, not a stale local copy.
    Map<String, dynamic> remote = {};
    if (widget.serverClient != null) {
      try {
        remote = await widget.serverClient!.getLlmSettings();
        log.info('[LLM Settings] Loaded settings from server.');
      } catch (e) {
        log.warning(
          '[LLM Settings] Failed to load from server — falling back to local: $e',
        );
      }
    }

    if (!mounted) return;
    final fromServer = remote.isNotEmpty;
    setState(() {
      if (fromServer) {
        // Populate from server values.
        _provider = LlmProvider.fromConfigKey(remote['provider'] as String?);
        _modelCtrl.text = remote['model'] as String? ?? '';
        _apiKeyCtrl.text = remote['api_key'] as String? ?? '';
        _baseUrlCtrl.text = remote['base_url'] as String? ?? '';
        _temperatureCtrl.text = (remote['temperature'] ?? s.temperature)
            .toString();
        _maxTokensCtrl.text = (remote['max_tokens'] ?? s.maxTokens).toString();
        _isSlm = remote['is_slm'] as bool? ?? false;
        _isMultiModal = remote['is_multi_modal'] as bool? ?? true;
        _useNativeToolCall = remote['use_native_tool_call'] as bool? ?? true;
        _useSafeToolCall = remote['use_safe_tool_call'] as bool? ?? false;
        // LLM 2
        _provider2 = LlmProvider.fromConfigKey(remote['provider2'] as String?);
        _modelCtrl2.text = remote['model2'] as String? ?? '';
        _apiKeyCtrl2.text = remote['api_key2'] as String? ?? '';
        _baseUrlCtrl2.text = remote['base_url2'] as String? ?? '';
        _temperatureCtrl2.text = (remote['temperature2'] ?? s.temperature2)
            .toString();
        _maxTokensCtrl2.text = (remote['max_tokens2'] ?? s.maxTokens2)
            .toString();
        _isSlm2 = remote['is_slm2'] as bool? ?? false;
        _isMultiModal2 = remote['is_multi_modal2'] as bool? ?? true;
        _useNativeToolCall2 = remote['use_native_tool_call2'] as bool? ?? true;
        _useSafeToolCall2 = remote['use_safe_tool_call2'] as bool? ?? false;
        _maxToolOutputSizeCtrl.text =
            (remote['max_tool_output_size'] ?? s.maxToolOutputSize).toString();
        _tokenWarningThresholdCtrl.text =
            (remote['token_warning_threshold'] ?? s.tokenWarningThreshold)
                .toString();
        _topKCtrl.text =
            remote['top_k']?.toString() ?? (s.topK?.toString() ?? '');
        _topPCtrl.text =
            remote['top_p']?.toString() ?? (s.topP?.toString() ?? '');
        _repeatPenaltyCtrl.text =
            remote['repeat_penalty']?.toString() ??
            (s.repeatPenalty?.toString() ?? '');
        _seedCtrl.text =
            remote['seed']?.toString() ?? (s.seed?.toString() ?? '');
        _maxToolOutputSizeCtrl2.text =
            (remote['max_tool_output_size2'] ?? s.maxToolOutputSize2)
                .toString();
        _tokenWarningThresholdCtrl2.text =
            (remote['token_warning_threshold2'] ?? s.tokenWarningThreshold2)
                .toString();
        _topKCtrl2.text =
            remote['top_k2']?.toString() ?? (s.topK2?.toString() ?? '');
        _topPCtrl2.text =
            remote['top_p2']?.toString() ?? (s.topP2?.toString() ?? '');
        _repeatPenaltyCtrl2.text =
            remote['repeat_penalty2']?.toString() ??
            (s.repeatPenalty2?.toString() ?? '');
        _seedCtrl2.text =
            remote['seed2']?.toString() ?? (s.seed2?.toString() ?? '');
        _thinking = remote.containsKey('thinking')
            ? (remote['thinking'] as bool? ?? false)
            : s.thinking;
        _thinking2 = remote.containsKey('thinking2')
            ? (remote['thinking2'] as bool? ?? false)
            : s.thinking2;
        _enableToolParameterAutoRecovery =
            remote.containsKey('enable_tool_parameter_auto_recovery')
            ? (remote['enable_tool_parameter_auto_recovery'] as bool? ?? true)
            : s.enableToolParameterAutoRecovery;
      } else {
        // Local mode or server unreachable — read from local secure storage.
        _provider = s.provider;
        _modelCtrl.text = s.getModelForProvider(_provider);
        _apiKeyCtrl.text = s.getApiKeyForProvider(_provider);
        _baseUrlCtrl.text = s.getBaseUrlForProvider(_provider);
        _temperatureCtrl.text = s.temperature.toString();
        _maxTokensCtrl.text = s.maxTokens.toString();
        _maxToolOutputSizeCtrl.text = s.maxToolOutputSize.toString();
        _tokenWarningThresholdCtrl.text = s.tokenWarningThreshold.toString();
        _topKCtrl.text = s.topK?.toString() ?? '';
        _topPCtrl.text = s.topP?.toString() ?? '';
        _repeatPenaltyCtrl.text = s.repeatPenalty?.toString() ?? '';
        _seedCtrl.text = s.seed?.toString() ?? '';
        // LLM 2
        _provider2 = s.provider2;
        _modelCtrl2.text = s.model2;
        _apiKeyCtrl2.text = s.apiKey2;
        _baseUrlCtrl2.text = s.baseUrl2;
        _temperatureCtrl2.text = s.temperature2.toString();
        _maxTokensCtrl2.text = s.maxTokens2.toString();
        _maxToolOutputSizeCtrl2.text = s.maxToolOutputSize2.toString();
        _tokenWarningThresholdCtrl2.text = s.tokenWarningThreshold2.toString();
        _topKCtrl2.text = s.topK2?.toString() ?? '';
        _topPCtrl2.text = s.topP2?.toString() ?? '';
        _repeatPenaltyCtrl2.text = s.repeatPenalty2?.toString() ?? '';
        _seedCtrl2.text = s.seed2?.toString() ?? '';
        _isSlm = s.isSlm;
        _isSlm2 = s.isSlm2;
        _isMultiModal = s.isMultiModal;
        _isMultiModal2 = s.isMultiModal2;
        _thinking = s.thinking;
        _thinking2 = s.thinking2;
        _useNativeToolCall = s.useNativeToolCall;
        _useNativeToolCall2 = s.useNativeToolCall2;
        _useSafeToolCall = s.useSafeToolCall;
        _useSafeToolCall2 = s.useSafeToolCall2;
        _enableToolParameterAutoRecovery = s.enableToolParameterAutoRecovery;
      }

      _aiDataSharingConsent =
          AppPreferencesService.instance.aiDataSharingConsent;
      _loading = false;
    });
    _schedulePriceRefresh();
    final canFetchLlm1 =
        _provider == LlmProvider.ollama ||
        (_provider != LlmProvider.none &&
            _provider != LlmProvider.embedded &&
            _provider != LlmProvider.claude &&
            _provider != LlmProvider.gemini &&
            _apiKeyCtrl.text.trim().isNotEmpty);
    final canFetchLlm2 =
        _provider2 == LlmProvider.ollama ||
        (_provider2 != LlmProvider.none &&
            _provider2 != LlmProvider.embedded &&
            _provider2 != LlmProvider.claude &&
            _provider2 != LlmProvider.gemini &&
            _apiKeyCtrl2.text.trim().isNotEmpty);
    if (canFetchLlm1) _fetchModels();
    if (canFetchLlm2) _fetchModels(forLlm2: true);
  }

  void _schedulePriceRefresh() {
    _priceRefreshDebounce?.cancel();
    if (_provider == LlmProvider.none ||
        _provider == LlmProvider.ollama ||
        _provider == LlmProvider.openaiCompatible ||
        _provider == LlmProvider.embedded) {
      if (mounted && _priceLoading) {
        setState(() => _priceLoading = false);
      }
      return;
    }

    final model = _modelCtrl.text.trim();
    if (model.isEmpty) {
      if (mounted && _priceLoading) {
        setState(() => _priceLoading = false);
      }
      return;
    }

    _priceRefreshDebounce = Timer(const Duration(milliseconds: 500), () async {
      if (!mounted) return;
      setState(() => _priceLoading = true);
      await refreshModelTokenPrice(
        providerKey: _provider.configKey,
        model: model,
      );
      if (!mounted) return;
      setState(() => _priceLoading = false);
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _priceRefreshDebounce?.cancel();
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
    _modelCtrl2.dispose();
    _apiKeyCtrl2.dispose();
    _baseUrlCtrl2.dispose();
    _temperatureCtrl2.dispose();
    _maxTokensCtrl2.dispose();
    _maxToolOutputSizeCtrl2.dispose();
    _tokenWarningThresholdCtrl2.dispose();
    _topKCtrl2.dispose();
    _topPCtrl2.dispose();
    _repeatPenaltyCtrl2.dispose();
    _seedCtrl2.dispose();
    super.dispose();
  }

  // ───────────────────────────────────────────────────
  // Test LLM 2
  // ───────────────────────────────────────────────────

  // ───────────────────────────────────────────────────
  // Fetch Ollama models
  // ───────────────────────────────────────────────────

  Future<void> _fetchModels({bool forLlm2 = false}) async {
    final provider = forLlm2 ? _provider2 : _provider;
    final baseUrl = forLlm2
        ? _baseUrlCtrl2.text.trim()
        : _baseUrlCtrl.text.trim();
    final apiKey = forLlm2 ? _apiKeyCtrl2.text.trim() : _apiKeyCtrl.text.trim();

    if (forLlm2) {
    } else {}

    try {
      final List<String> list = [];
      if (provider == LlmProvider.ollama) {
        final base = (baseUrl.isEmpty ? 'http://localhost:11434' : baseUrl)
            .replaceAll(RegExp(r'/+$'), '');
        final tagsBase = base.endsWith('/api') ? base : '$base/api';
        final url = Uri.parse('$tagsBase/tags');
        final headers = apiKey.isNotEmpty
            ? {'Authorization': 'Bearer $apiKey'}
            : <String, String>{};
        final resp = await http
            .get(url, headers: headers)
            .timeout(const Duration(seconds: 15));
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          throw Exception('HTTP ${resp.statusCode}');
        }
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final fetched = (data['models'] as List<dynamic>? ?? [])
            .map((m) => (m as Map<String, dynamic>)['name'] as String? ?? '')
            .where((n) => n.isNotEmpty)
            .toList();
        list.addAll(fetched);
      } else {
        var resolvedBaseUrl = baseUrl;
        if (resolvedBaseUrl.isEmpty) {
          if (provider == LlmProvider.openai) {
            resolvedBaseUrl = 'https://api.openai.com/v1';
          } else if (provider == LlmProvider.mistral) {
            resolvedBaseUrl = 'https://api.mistral.ai/v1';
          }
        }
        final base = resolvedBaseUrl.replaceAll(RegExp(r'/+$'), '');
        final url = Uri.parse('$base/models');
        final headers = {
          'Accept': 'application/json',
          if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
        };
        final resp = await http
            .get(url, headers: headers)
            .timeout(const Duration(seconds: 15));
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          throw Exception('HTTP ${resp.statusCode}');
        }
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final fetched = (data['data'] as List<dynamic>? ?? [])
            .map((m) => (m as Map<String, dynamic>)['id'] as String? ?? '')
            .where((n) => n.isNotEmpty)
            .toList();
        list.addAll(fetched);
      }

      if (mounted) {
        setState(() {
          if (forLlm2) {
            if (list.isNotEmpty && _modelCtrl2.text.trim().isEmpty) {
              _modelCtrl2.text = list.first;
            }
          } else {
            if (list.isNotEmpty && _modelCtrl.text.trim().isEmpty) {
              _modelCtrl.text = list.first;
            }
          }
        });
      }
    } catch (e) {
      if (mounted) {
        final providerLabel = provider.label;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not reach $providerLabel: $e'),
            backgroundColor: AppTheme.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          if (forLlm2) {
          } else {}
        });
      }
    }
  }

  // ───────────────────────────────────────────────────
  // Save
  // ───────────────────────────────────────────────────

  Future<bool> _ensureEmbeddedSelectionIsDownloaded() async {
    if (!_isEmbeddedProvider && !_isEmbeddedProvider2) return true;

    final missing = <String>[];

    Set<String> available;
    if (widget.serverClient != null) {
      final files = await widget.serverClient!.listServerModelFiles();
      available = files
          .map((f) => (f['filename'] as String? ?? '').trim())
          .where((name) => name.isNotEmpty)
          .toSet();
    } else {
      available = await EmbeddedModelManager.instance.listDownloadedFilenames();
    }

    final model1 = _modelCtrl.text.trim();
    if (_isEmbeddedProvider &&
        model1.isNotEmpty &&
        !available.contains(model1)) {
      missing.add(model1);
    }

    final model2 = _modelCtrl2.text.trim();
    if (_isEmbeddedProvider2 &&
        model2.isNotEmpty &&
        !available.contains(model2)) {
      missing.add(model2);
    }

    if (missing.isEmpty) return true;

    if (mounted) {
      final scope = widget.serverClient != null ? 'server' : 'device';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Embedded model not downloaded on $scope: ${missing.toSet().join(', ')}',
          ),
          backgroundColor: AppTheme.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
    return false;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final embeddedReady = await _ensureEmbeddedSelectionIsDownloaded();
    if (!embeddedReady) return;

    setState(() => _saving = true);

    try {
      if (widget.serverClient != null) {
        try {
          final llmPayload = <String, dynamic>{
            'provider': _provider.configKey,
            'model': _modelCtrl.text,
            'api_key': _isEmbeddedProvider ? '' : _apiKeyCtrl.text,
            'base_url': _isBaseUrlProvider ? _baseUrlCtrl.text : '',
            'temperature': double.tryParse(_temperatureCtrl.text) ?? 0.2,
            'max_tokens': int.tryParse(_maxTokensCtrl.text) ?? 0,
            'is_slm': _isSlm,
            'is_multi_modal': _isMultiModal,
            'thinking': _thinking,
            'use_native_tool_call': _useNativeToolCall,
            'use_safe_tool_call': _useSafeToolCall,
            'enable_tool_parameter_auto_recovery':
                _enableToolParameterAutoRecovery,
            'max_tool_output_size':
                int.tryParse(_maxToolOutputSizeCtrl.text) ?? 2560000,
            'token_warning_threshold':
                int.tryParse(_tokenWarningThresholdCtrl.text) ?? 1500000,
            'top_k': int.tryParse(_topKCtrl.text.trim()),
            'top_p': double.tryParse(_topPCtrl.text.trim()),
            'repeat_penalty': double.tryParse(_repeatPenaltyCtrl.text.trim()),
            'seed': int.tryParse(_seedCtrl.text.trim()),
            'provider2': _provider2.configKey,
            'model2': _modelCtrl2.text,
            'api_key2': _apiKeyCtrl2.text,
            'base_url2': _isBaseUrlProvider2 ? _baseUrlCtrl2.text : '',
            'temperature2': double.tryParse(_temperatureCtrl2.text) ?? 0.2,
            'max_tokens2': int.tryParse(_maxTokensCtrl2.text) ?? 0,
            'is_slm2': _isSlm2,
            'is_multi_modal2': _isMultiModal2,
            'thinking2': _thinking2,
            'use_native_tool_call2': _useNativeToolCall2,
            'use_safe_tool_call2': _useSafeToolCall2,
            'max_tool_output_size2':
                int.tryParse(_maxToolOutputSizeCtrl2.text) ?? 2560000,
            'token_warning_threshold2':
                int.tryParse(_tokenWarningThresholdCtrl2.text) ?? 1500000,
            'top_k2': int.tryParse(_topKCtrl2.text.trim()),
            'top_p2': double.tryParse(_topPCtrl2.text.trim()),
            'repeat_penalty2': double.tryParse(_repeatPenaltyCtrl2.text.trim()),
            'seed2': int.tryParse(_seedCtrl2.text.trim()),
          };
          await widget.serverClient!.putLlmSettings(llmPayload);
          widget.service.applyRemoteState(llmPayload);
          // Also save locally so that the client keeps API keys and configs for all providers in local secure storage
          await widget.service.save(
            provider: _provider,
            model: _modelCtrl.text,
            apiKey: _isEmbeddedProvider ? '' : _apiKeyCtrl.text,
            baseUrl: _isBaseUrlProvider ? _baseUrlCtrl.text : '',
            temperature: double.tryParse(_temperatureCtrl.text) ?? 0.2,
            maxTokens: int.tryParse(_maxTokensCtrl.text) ?? 0,
            maxToolOutputSize:
                int.tryParse(_maxToolOutputSizeCtrl.text) ?? 2560000,
            tokenWarningThreshold:
                int.tryParse(_tokenWarningThresholdCtrl.text) ?? 1500000,
            isSlm: _isSlm,
            isMultiModal: _isMultiModal,
            topK: int.tryParse(_topKCtrl.text.trim()),
            topP: double.tryParse(_topPCtrl.text.trim()),
            repeatPenalty: double.tryParse(_repeatPenaltyCtrl.text.trim()),
            seed: int.tryParse(_seedCtrl.text.trim()),
            thinking: _thinking,
            useNativeToolCall: _useNativeToolCall,
            useSafeToolCall: _useSafeToolCall,
            enableToolParameterAutoRecovery: _enableToolParameterAutoRecovery,
          );
          await widget.service.save2(
            provider: _provider2,
            model: _modelCtrl2.text,
            apiKey: _apiKeyCtrl2.text,
            baseUrl: _isBaseUrlProvider2 ? _baseUrlCtrl2.text : '',
            temperature: double.tryParse(_temperatureCtrl2.text) ?? 0.2,
            maxTokens: int.tryParse(_maxTokensCtrl2.text) ?? 0,
            maxToolOutputSize2:
                int.tryParse(_maxToolOutputSizeCtrl2.text) ?? 2560000,
            tokenWarningThreshold2:
                int.tryParse(_tokenWarningThresholdCtrl2.text) ?? 1500000,
            isSlm2: _isSlm2,
            isMultiModal2: _isMultiModal2,
            topK2: int.tryParse(_topKCtrl2.text.trim()),
            topP2: double.tryParse(_topPCtrl2.text.trim()),
            repeatPenalty2: double.tryParse(_repeatPenaltyCtrl2.text.trim()),
            seed2: int.tryParse(_seedCtrl2.text.trim()),
            thinking2: _thinking2,
            useNativeToolCall2: _useNativeToolCall2,
            useSafeToolCall2: _useSafeToolCall2,
          );
          // ignore: unawaited_futures
          LlmTaskResyncService.resyncLlm2Tasks();
          log.info(
            '[LLM Settings] Pushed updated settings to server and saved locally.',
          );
        } catch (e) {
          log.warning('[LLM Settings] Failed to push settings to server: $e');
        }
      } else {
        await widget.service.save(
          provider: _provider,
          model: _modelCtrl.text,
          apiKey: _isEmbeddedProvider ? '' : _apiKeyCtrl.text,
          baseUrl: _isBaseUrlProvider ? _baseUrlCtrl.text : '',
          temperature: double.tryParse(_temperatureCtrl.text) ?? 0.2,
          maxTokens: int.tryParse(_maxTokensCtrl.text) ?? 0,
          maxToolOutputSize:
              int.tryParse(_maxToolOutputSizeCtrl.text) ?? 2560000,
          tokenWarningThreshold:
              int.tryParse(_tokenWarningThresholdCtrl.text) ?? 1500000,
          isSlm: _isSlm,
          isMultiModal: _isMultiModal,
          topK: int.tryParse(_topKCtrl.text.trim()),
          topP: double.tryParse(_topPCtrl.text.trim()),
          repeatPenalty: double.tryParse(_repeatPenaltyCtrl.text.trim()),
          seed: int.tryParse(_seedCtrl.text.trim()),
          thinking: _thinking,
          useNativeToolCall: _useNativeToolCall,
          useSafeToolCall: _useSafeToolCall,
          enableToolParameterAutoRecovery: _enableToolParameterAutoRecovery,
        );
        await widget.service.save2(
          provider: _provider2,
          model: _modelCtrl2.text,
          apiKey: _apiKeyCtrl2.text,
          baseUrl: _isBaseUrlProvider2 ? _baseUrlCtrl2.text : '',
          temperature: double.tryParse(_temperatureCtrl2.text) ?? 0.2,
          maxTokens: int.tryParse(_maxTokensCtrl2.text) ?? 0,
          maxToolOutputSize2:
              int.tryParse(_maxToolOutputSizeCtrl2.text) ?? 2560000,
          tokenWarningThreshold2:
              int.tryParse(_tokenWarningThresholdCtrl2.text) ?? 1500000,
          isSlm2: _isSlm2,
          isMultiModal2: _isMultiModal2,
          topK2: int.tryParse(_topKCtrl2.text.trim()),
          topP2: double.tryParse(_topPCtrl2.text.trim()),
          repeatPenalty2: double.tryParse(_repeatPenaltyCtrl2.text.trim()),
          seed2: int.tryParse(_seedCtrl2.text.trim()),
          thinking2: _thinking2,
          useNativeToolCall2: _useNativeToolCall2,
          useSafeToolCall2: _useSafeToolCall2,
        );
        // ignore: unawaited_futures
        LlmTaskResyncService.resyncLlm2Tasks();
      }

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

  // ───────────────────────────────────────────────────
  // Clear
  // ───────────────────────────────────────────────────

  Future<void> _clear() async {
    final l = L.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.llmClearSettingsTitle),
        content: Text(l.llmClearSettingsMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.delete, style: TextStyle(color: AppTheme.error)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await widget.service.clear();
    if (mounted) {
      setState(() {
        _isSlm = false;
        _isMultiModal = true;
        _isMultiModal2 = true;
        _modelCtrl.text = '';
        _apiKeyCtrl.text = '';
        _baseUrlCtrl.text = '';
        _temperatureCtrl.text = '0.2';
        _maxTokensCtrl.text = '16384';
        _maxToolOutputSizeCtrl.text = '2560000';
        _tokenWarningThresholdCtrl.text = '1500000';
        _topKCtrl.text = '';
        _topPCtrl.text = '';
        _repeatPenaltyCtrl.text = '';
        _seedCtrl.text = '';
        _useNativeToolCall = true;
        _useNativeToolCall2 = true;
        _useSafeToolCall = false;
        _useSafeToolCall2 = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l.llmSettingsCleared),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  // ───────────────────────────────────────────────────
  // Build
  // ───────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final theme = Theme.of(context);
    final uiStyle = AppPreferencesService.instance.uiStyle;
    final isModern = uiStyle == 'modern';

    return Scaffold(
      appBar: AppBar(
        title: Text(l.llmSettings),
        actions: [
          if (!_loading && widget.service.isConfigured)
            IconButton(
              icon: Icon(Icons.delete_outline, color: AppTheme.error),
              tooltip: l.llmClearSettingsTitle,
              onPressed: _clear,
            ),
          const SizedBox(width: 8),
        ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            const Tab(text: 'LLM 1 (Primary)'),
            const Tab(text: 'LLM 2 (Coding)'),
            if (!_isLightMode) const Tab(text: 'Embedded'),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: AnimatedBuilder(
                animation: _tabController,
                builder: (context, _) => IndexedStack(
                  index: _tabController.index,
                  children: [
                    ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        // ── Info card ──────────────────────────
                        _buildConfigCard(
                          isModern: isModern,
                          theme: theme,
                          baseColor: isModern
                              ? const Color(0xFF7C3AED)
                              : AppTheme.primaryBlue,
                          classicBgColor: AppTheme.primaryBlue.withValues(
                            alpha: 0.08,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.info_outline,
                                  color: isModern
                                      ? const Color(0xFF7C3AED)
                                      : AppTheme.primaryBlue,
                                  size: 20,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    l.llmSettingsInfo,
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
                        const SizedBox(height: 12),

                        LlmSettingsFormWidget(
                          providerKey: _provider.configKey,
                          modelController: _modelCtrl,
                          apiKeyController: _apiKeyCtrl,
                          baseUrlController: _baseUrlCtrl,
                          temperatureController: _temperatureCtrl,
                          maxTokensController: _maxTokensCtrl,
                          isSlm: _isSlm,
                          isMultiModal: _isMultiModal,
                          thinking: _thinking,
                          useNativeToolCall: _useNativeToolCall,
                          useSafeToolCall: _useSafeToolCall,
                          enableToolParameterAutoRecovery:
                              _enableToolParameterAutoRecovery,
                          service: widget.service,
                          serverClient: widget.serverClient,
                          showConsent: true,
                          aiDataSharingConsent: _aiDataSharingConsent,
                          onAiDataSharingConsentChanged: (v) async {
                            await AppPreferencesService.instance
                                .setAiDataSharingConsent(v);
                            setState(() => _aiDataSharingConsent = v);
                          },
                          onProviderChanged: (key) {
                            setState(() {
                              _provider = LlmProvider.fromConfigKey(key);
                              _schedulePriceRefresh();
                            });
                          },
                          onModelChanged: (model) {
                            setState(() {
                              _schedulePriceRefresh();
                            });
                          },
                          onSlmChanged: (v) => setState(() => _isSlm = v),
                          onMultiModalChanged: (v) =>
                              setState(() => _isMultiModal = v),
                          onThinkingChanged: (v) =>
                              setState(() => _thinking = v),
                          onUseNativeToolCallChanged: (v) =>
                              setState(() => _useNativeToolCall = v),
                          onUseSafeToolCallChanged: (v) =>
                              setState(() => _useSafeToolCall = v),
                          showEmbeddedOption: !_isLightMode,
                          onEnableToolParameterAutoRecoveryChanged: (v) =>
                              setState(
                                () => _enableToolParameterAutoRecovery = v,
                              ),
                        ),

                        const SizedBox(height: 24),

                        // ── Save button ──────────────────────────
                        FilledButton.icon(
                          onPressed: _saving ? null : _save,
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
                        // Extra bottom padding so the button clears the Android navigation bar
                        const SizedBox(height: 24),
                      ],
                    ),
                    _buildLlm2Tab(l, theme),
                    if (!_isLightMode) _buildEmbeddedTab(l, theme),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildEmbeddedTab(L l, ThemeData theme) {
    final uiStyle = AppPreferencesService.instance.uiStyle;
    final isModern = uiStyle == 'modern';

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ── Info card ──────────────────────────
        _buildConfigCard(
          isModern: isModern,
          theme: theme,
          baseColor: isModern ? const Color(0xFF7C3AED) : AppTheme.primaryBlue,
          classicBgColor: AppTheme.primaryBlue.withValues(alpha: 0.08),
          child: Padding(
            padding: const EdgeInsets.all(12),
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
                    'app memory here — no need to open Playground or Agent Editor.',
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
        // ── Model picker (list + controls) ──────────────────────────
        EmbeddedModelPickerWidget(
          selectedFilename: _embeddedModelFile,
          serverClient: widget.serverClient,
          onFilenameSelected: (filename) =>
              setState(() => _embeddedModelFile = filename),
        ),
        const SizedBox(height: 16),
        // ── Advanced settings for the embedded provider ────────────
        if (_isEmbeddedProvider || _isEmbeddedProvider2) ...[
          SwitchListTile(
            title: Text('Advanced Settings', style: theme.textTheme.titleSmall),
            subtitle: const Text(
              'Temperature, max tokens, sampling parameters',
            ),
            value: _showAdvancedEmbedded,
            onChanged: (v) => setState(() => _showAdvancedEmbedded = v),
            activeTrackColor: AppTheme.primaryBlue,
            contentPadding: EdgeInsets.zero,
          ),
          if (_showAdvancedEmbedded) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _isEmbeddedProvider
                        ? _temperatureCtrl
                        : _temperatureCtrl2,
                    decoration: const InputDecoration(
                      labelText: 'Temperature',
                      hintText: '0.0 – 2.0',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.thermostat),
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    validator: (v) {
                      final d = double.tryParse(v ?? '');
                      if (d == null || d < 0 || d > 2) {
                        return 'Must be 0.0 – 2.0';
                      }
                      return null;
                    },
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextFormField(
                    controller: _isEmbeddedProvider
                        ? _maxTokensCtrl
                        : _maxTokensCtrl2,
                    decoration: const InputDecoration(
                      labelText: 'Max Tokens',
                      hintText: '0 = model default',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.data_usage),
                    ),
                    keyboardType: TextInputType.number,
                    validator: (v) {
                      final n = int.tryParse(v ?? '');
                      if (n == null || n < 0) return 'Must be 0 or positive';
                      return null;
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _isEmbeddedProvider
                  ? _maxToolOutputSizeCtrl
                  : _maxToolOutputSizeCtrl2,
              decoration: const InputDecoration(
                labelText: 'Max Tool Output Size (chars)',
                hintText: '0 = unlimited',
                helperText: 'Limit tool output size (0 = unlimited)',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.build_circle_outlined),
              ),
              keyboardType: TextInputType.number,
              validator: (v) {
                final n = int.tryParse(v ?? '');
                if (n == null || n < 0) return 'Enter 0 or a positive number';
                return null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _isEmbeddedProvider
                  ? _tokenWarningThresholdCtrl
                  : _tokenWarningThresholdCtrl2,
              decoration: const InputDecoration(
                labelText: 'Token Warning Threshold',
                hintText: 'e.g. 1500000',
                helperText: 'Cleanup suggestion after this many tokens',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.warning_amber_outlined),
              ),
              keyboardType: TextInputType.number,
              validator: (v) {
                final n = int.tryParse(v ?? '');
                if (n == null || n < 1000) return 'Must be at least 1000';
                return null;
              },
            ),
            const SizedBox(height: 16),
            LlmAdvancedParamsWidget(
              topKController: _isEmbeddedProvider ? _topKCtrl : _topKCtrl2,
              topPController: _isEmbeddedProvider ? _topPCtrl : _topPCtrl2,
              repeatPenaltyController: _isEmbeddedProvider
                  ? _repeatPenaltyCtrl
                  : _repeatPenaltyCtrl2,
              seedController: _isEmbeddedProvider ? _seedCtrl : _seedCtrl2,
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              title: const Text('Thinking / Reasoning'),
              subtitle: const Text(
                'Allow the model to emit internal thinking/reasoning tokens '
                '(e.g. <think> blocks). Disable to suppress output and reduce token usage.',
              ),
              value: _isEmbeddedProvider ? _thinking : _thinking2,
              onChanged: (v) => setState(
                () => _isEmbeddedProvider ? _thinking = v : _thinking2 = v,
              ),
              activeTrackColor: AppTheme.primaryBlue,
              contentPadding: EdgeInsets.zero,
            ),
          ],
        ] else ...[
          _buildConfigCard(
            isModern: isModern,
            theme: theme,
            baseColor: isModern
                ? const Color(0xFF7C3AED)
                : theme.colorScheme.primary,
            classicBgColor: theme.colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(
                    Icons.settings_outlined,
                    color: isModern
                        ? (theme.brightness == Brightness.dark
                              ? const Color(0xFF06B6D4)
                              : const Color(0xFF7C3AED))
                        : theme.colorScheme.onSurfaceVariant,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Set LLM 1 or LLM 2 provider to "Embedded" to configure '
                      'temperature, max tokens and sampling parameters here.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: isModern
                            ? (theme.brightness == Brightness.dark
                                  ? Colors.white
                                  : Colors.black87)
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildLlm2Tab(L l, ThemeData theme) {
    final uiStyle = AppPreferencesService.instance.uiStyle;
    final isModern = uiStyle == 'modern';

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildConfigCard(
          isModern: isModern,
          theme: theme,
          baseColor: isModern ? const Color(0xFF7C3AED) : AppTheme.primaryBlue,
          classicBgColor: AppTheme.primaryBlue.withValues(alpha: 0.08),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline,
                  color: isModern
                      ? const Color(0xFF7C3AED)
                      : AppTheme.primaryBlue,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Optional secondary LLM used for code generation (JS, Python, Shell). '
                    'If not configured, code generation falls back to LLM 1.',
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
        const SizedBox(height: 20),

        LlmSettingsFormWidget(
          providerKey: _provider2.configKey,
          modelController: _modelCtrl2,
          apiKeyController: _apiKeyCtrl2,
          baseUrlController: _baseUrlCtrl2,
          temperatureController: _temperatureCtrl2,
          maxTokensController: _maxTokensCtrl2,
          isSlm: _isSlm2,
          isMultiModal: _isMultiModal2,
          thinking: _thinking2,
          useNativeToolCall: _useNativeToolCall2,
          useSafeToolCall: _useSafeToolCall2,
          enableToolParameterAutoRecovery: true,
          service: widget.service,
          serverClient: widget.serverClient,
          onProviderChanged: (key) {
            setState(() {
              _provider2 = LlmProvider.fromConfigKey(key);
            });
          },
          onSlmChanged: (v) => setState(() => _isSlm2 = v),
          onMultiModalChanged: (v) => setState(() => _isMultiModal2 = v),
          onThinkingChanged: (v) => setState(() => _thinking2 = v),
          onUseNativeToolCallChanged: (v) =>
              setState(() => _useNativeToolCall2 = v),
          onUseSafeToolCallChanged: (v) =>
              setState(() => _useSafeToolCall2 = v),
          showEmbeddedOption: !_isLightMode,
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: _saving ? null : _save,
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
        // Extra bottom padding so the button clears the Android navigation bar
        const SizedBox(height: 24),
      ],
    );
  }

  // ── Helpers ──────────────────────────────────────

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
      return Card(color: classicBgColor, child: child);
    }
  }
}
