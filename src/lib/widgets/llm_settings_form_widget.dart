import 'dart:convert';
import 'package:material_ui/material_ui.dart';
import 'package:http/http.dart' as http;
import '../l10n/app_localizations.dart';
import '../config/app_theme.dart';
import '../services/llm_settings_service.dart';
import '../services/server_api_client.dart';
import 'embedded_llm/embedded_model_picker_widget.dart';
import 'llm_advanced_params_widget.dart';

/// A unified reusable form widget for configuring LLM settings.
/// Can be used for global settings, task overrides, and agent overrides.
class LlmSettingsFormWidget extends StatefulWidget {
  final String providerKey;
  final TextEditingController modelController;
  final TextEditingController apiKeyController;
  final TextEditingController baseUrlController;
  final TextEditingController temperatureController;
  final TextEditingController maxTokensController;
  final TextEditingController? topKController;
  final TextEditingController? topPController;
  final TextEditingController? repeatPenaltyController;
  final TextEditingController? seedController;
  final TextEditingController? maxToolOutputSizeController;
  final TextEditingController? nameController;
  final TextEditingController? tokenWarningThresholdController;

  final bool isSlm;
  final bool isMultiModal;
  final bool thinking;
  final bool useNativeToolCall;
  final bool useSafeToolCall;
  final bool enableToolParameterAutoRecovery;

  final LlmSettingsService service;
  final ServerApiClient? serverClient;

  // State callbacks
  final ValueChanged<String> onProviderChanged;
  final ValueChanged<String>? onModelChanged;
  final ValueChanged<bool> onSlmChanged;
  final ValueChanged<bool> onMultiModalChanged;
  final ValueChanged<bool> onThinkingChanged;
  final ValueChanged<bool> onUseNativeToolCallChanged;
  final ValueChanged<bool> onUseSafeToolCallChanged;
  final ValueChanged<bool>? onEnableToolParameterAutoRecoveryChanged;

  // Optional behavior configuration
  final VoidCallback? onApplyDefault;
  final bool showConsent;
  final bool aiDataSharingConsent;
  final ValueChanged<bool>? onAiDataSharingConsentChanged;
  final bool showLlm2Option;
  final bool showNoneOption;
  final bool showEmbeddedOption;

  const LlmSettingsFormWidget({
    super.key,
    this.nameController,
    required this.providerKey,
    required this.modelController,
    required this.apiKeyController,
    required this.baseUrlController,
    required this.temperatureController,
    required this.maxTokensController,
    this.topKController,
    this.topPController,
    this.repeatPenaltyController,
    this.seedController,
    this.maxToolOutputSizeController,
    this.tokenWarningThresholdController,
    required this.isSlm,
    required this.isMultiModal,
    required this.thinking,
    required this.useNativeToolCall,
    required this.useSafeToolCall,
    required this.enableToolParameterAutoRecovery,
    required this.service,
    this.serverClient,
    required this.onProviderChanged,
    this.onModelChanged,
    required this.onSlmChanged,
    required this.onMultiModalChanged,
    required this.onThinkingChanged,
    required this.onUseNativeToolCallChanged,
    required this.onUseSafeToolCallChanged,
    this.onEnableToolParameterAutoRecoveryChanged,
    this.onApplyDefault,
    this.showConsent = false,
    this.aiDataSharingConsent = false,
    this.onAiDataSharingConsentChanged,
    this.showLlm2Option = false,
    this.showEmbeddedOption = true,
    this.showNoneOption = true,
  });

  @override
  State<LlmSettingsFormWidget> createState() => _LlmSettingsFormWidgetState();
}

class _LlmSettingsFormWidgetState extends State<LlmSettingsFormWidget> {
  bool _fetchingModels = false;
  bool _testingConnection = false;
  bool _obscureKey = true;
  bool _showAdvanced = false;
  List<String> _fetchedModels = [];

  LlmProvider get _currentProvider {
    if (widget.providerKey == 'llm2') return LlmProvider.none;
    return LlmProvider.fromConfigKey(widget.providerKey);
  }

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

  Future<List<String>> _fetchModels() async {
    setState(() => _fetchingModels = true);
    final provider = _currentProvider;
    try {
      final List<String> list = [];
      final baseUrl = widget.baseUrlController.text.trim();
      final apiKey = widget.apiKeyController.text.trim();

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
        if (provider == LlmProvider.mistral) {
          if (resolvedBaseUrl.isEmpty ||
              resolvedBaseUrl.contains('deepinfra') ||
              resolvedBaseUrl.contains('openai.com') ||
              resolvedBaseUrl.contains('localhost')) {
            resolvedBaseUrl = 'https://api.mistral.ai/v1';
          }
        } else if (resolvedBaseUrl.isEmpty) {
          if (provider == LlmProvider.openai) {
            resolvedBaseUrl = 'https://api.openai.com/v1';
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
          String detail = 'HTTP ${resp.statusCode}';
          try {
            final errJson = jsonDecode(resp.body);
            if (errJson is Map && errJson['message'] != null) {
              detail = 'HTTP ${resp.statusCode}: ${errJson['message']}';
            } else if (errJson is Map && errJson['detail'] != null) {
              detail = 'HTTP ${resp.statusCode}: ${errJson['detail']}';
            }
          } catch (_) {}
          throw Exception(detail);
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
          _fetchedModels = list;
          if (list.isNotEmpty && widget.modelController.text.trim().isEmpty) {
            widget.modelController.text = list.first;
            widget.onModelChanged?.call(list.first);
          }
        });

        // Background refresh price & context size for all fetched models
        for (final m in list) {
          refreshModelTokenPrice(providerKey: provider.configKey, model: m).then((_) {
            if (mounted) setState(() {});
          });
        }
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Successfully fetched ${list.length} models!'),
            backgroundColor: AppTheme.success,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return list;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not reach ${provider.label}: $e'),
            backgroundColor: AppTheme.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return _fetchedModels;
    } finally {
      if (mounted) {
        setState(() => _fetchingModels = false);
      }
    }
  }

  Future<void> _testConnection() async {
    setState(() => _testingConnection = true);
    try {
      final provider = _currentProvider;
      final apiKey = widget.apiKeyController.text.trim();
      final baseUrl = widget.baseUrlController.text.trim();

      bool success = false;
      String? errorMsg;

      switch (provider) {
        case LlmProvider.ollama:
          final ollamaBase =
              (baseUrl.isEmpty ? 'http://localhost:11434' : baseUrl).replaceAll(
                RegExp(r'/+$'),
                '',
              );
          final ollamaTagsBase = ollamaBase.endsWith('/api')
              ? ollamaBase
              : '$ollamaBase/api';
          final ollamaUrl = Uri.parse('$ollamaTagsBase/tags');
          final ollamaHeaders = apiKey.isNotEmpty
              ? {'Authorization': 'Bearer $apiKey'}
              : <String, String>{};
          final ollamaResp = await http
              .get(ollamaUrl, headers: ollamaHeaders)
              .timeout(const Duration(seconds: 15));
          success = ollamaResp.statusCode >= 200 && ollamaResp.statusCode < 300;
          if (success) {
            try {
              final data = jsonDecode(ollamaResp.body) as Map<String, dynamic>;
              final ollamaTagList = (data['models'] as List<dynamic>? ?? [])
                  .map(
                    (m) => (m as Map<String, dynamic>)['name'] as String? ?? '',
                  )
                  .where((n) => n.isNotEmpty)
                  .toList();
              if (mounted) setState(() => _fetchedModels = ollamaTagList);
              final entered = widget.modelController.text.trim();
              if (entered.isNotEmpty &&
                  ollamaTagList.isNotEmpty &&
                  !ollamaTagList.contains(entered)) {
                errorMsg =
                    'Ollama reachable ✓ but model "$entered" not found.\nAvailable: ${ollamaTagList.take(5).join(', ')}${ollamaTagList.length > 5 ? '…' : ''}';
                success = false;
              }
            } catch (_) {}
          } else {
            errorMsg = 'HTTP ${ollamaResp.statusCode}';
          }
          break;
        case LlmProvider.openaiCompatible:
          final base = baseUrl.isEmpty ? 'http://localhost:8080/v1' : baseUrl;
          final url = Uri.parse('$base/models');
          final headers = apiKey.isNotEmpty
              ? {'Authorization': 'Bearer $apiKey'}
              : <String, String>{};
          final resp = await http
              .get(url, headers: headers)
              .timeout(const Duration(seconds: 15));
          success = resp.statusCode >= 200 && resp.statusCode < 300;
          if (success) {
            try {
              final data = jsonDecode(resp.body) as Map<String, dynamic>;
              final list = (data['data'] as List<dynamic>? ?? [])
                  .map(
                    (m) => (m as Map<String, dynamic>)['id'] as String? ?? '',
                  )
                  .where((n) => n.isNotEmpty)
                  .toList();
              if (mounted) setState(() => _fetchedModels = list);
              final entered = widget.modelController.text.trim();
              if (entered.isNotEmpty &&
                  list.isNotEmpty &&
                  !list.contains(entered)) {
                errorMsg =
                    'Server reachable ✓ but model "$entered" not found.\nAvailable: ${list.take(5).join(', ')}${list.length > 5 ? '…' : ''}';
                success = false;
              }
            } catch (_) {}
          } else {
            errorMsg = 'HTTP ${resp.statusCode}';
          }
          break;
        case LlmProvider.openai:
          final url = Uri.parse('https://api.openai.com/v1/models');
          final resp = await http
              .get(url, headers: {'Authorization': 'Bearer $apiKey'})
              .timeout(const Duration(seconds: 15));
          success = resp.statusCode >= 200 && resp.statusCode < 300;
          if (success) {
            try {
              final data = jsonDecode(resp.body) as Map<String, dynamic>;
              final list = (data['data'] as List<dynamic>? ?? [])
                  .map(
                    (m) => (m as Map<String, dynamic>)['id'] as String? ?? '',
                  )
                  .where((n) => n.isNotEmpty)
                  .toList();
              if (mounted) setState(() => _fetchedModels = list);
              final entered = widget.modelController.text.trim();
              if (entered.isNotEmpty &&
                  list.isNotEmpty &&
                  !list.contains(entered)) {
                errorMsg =
                    'Server reachable ✓ but model "$entered" not found.\nAvailable: ${list.take(5).join(', ')}${list.length > 5 ? '…' : ''}';
                success = false;
              }
            } catch (_) {}
          } else {
            errorMsg = 'HTTP ${resp.statusCode}';
          }
          break;
        case LlmProvider.gemini:
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
          var base = baseUrl.isEmpty ? 'https://api.mistral.ai/v1' : baseUrl;
          if (base.contains('deepinfra') || base.contains('openai.com') || base.contains('localhost')) {
            base = 'https://api.mistral.ai/v1';
          }
          final url = Uri.parse('$base/models');
          final resp = await http
              .get(url, headers: {'Authorization': 'Bearer $apiKey'})
              .timeout(const Duration(seconds: 15));
          success = resp.statusCode >= 200 && resp.statusCode < 300;
          if (success) {
            try {
              final data = jsonDecode(resp.body) as Map<String, dynamic>;
              final list = (data['data'] as List<dynamic>? ?? [])
                  .map(
                    (m) => (m as Map<String, dynamic>)['id'] as String? ?? '',
                  )
                  .where((n) => n.isNotEmpty)
                  .toList();
              if (mounted) setState(() => _fetchedModels = list);
              final entered = widget.modelController.text.trim();
              if (entered.isNotEmpty &&
                  list.isNotEmpty &&
                  !list.contains(entered)) {
                errorMsg =
                    'Server reachable ✓ but model "$entered" not found.\nAvailable: ${list.take(5).join(', ')}${list.length > 5 ? '…' : ''}';
                success = false;
              }
            } catch (_) {}
          } else {
            try {
              final errJson = jsonDecode(resp.body);
              if (errJson is Map && errJson['message'] != null) {
                errorMsg = 'HTTP ${resp.statusCode}: ${errJson['message']}';
              } else if (errJson is Map && errJson['detail'] != null) {
                errorMsg = 'HTTP ${resp.statusCode}: ${errJson['detail']}';
              } else if (errJson is Map && errJson['error'] != null) {
                final err = errJson['error'];
                errorMsg = err is Map && err['message'] != null
                    ? 'HTTP ${resp.statusCode}: ${err['message']}'
                    : 'HTTP ${resp.statusCode}: $err';
              } else {
                final text = resp.body.trim();
                final snippet = text.length > 120 ? '${text.substring(0, 120)}…' : text;
                errorMsg = 'HTTP ${resp.statusCode}: $snippet';
              }
            } catch (_) {
              errorMsg = 'HTTP ${resp.statusCode}';
            }
          }
          break;
        case LlmProvider.embedded:
          success = true;
          break;
        case LlmProvider.none:
          break;
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              success
                  ? '${provider.label} connection successful ✓'
                  : 'Connection failed: ${errorMsg ?? 'unknown error'}',
            ),
            backgroundColor: success ? AppTheme.success : AppTheme.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Connection failed: $e'),
            backgroundColor: AppTheme.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _testingConnection = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final provider = _currentProvider;
    final isEmbedded = provider == LlmProvider.embedded;

    final requiresBaseUrl =
        provider == LlmProvider.ollama ||
        provider == LlmProvider.openaiCompatible ||
        provider == LlmProvider.openai ||
        provider == LlmProvider.mistral;

    final hasDedicatedApiKeyField =
        provider != LlmProvider.none && provider != LlmProvider.embedded;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Apply Defaults (Task/Agent override) ──────────────────
        if (widget.onApplyDefault != null) ...[
          OutlinedButton.icon(
            onPressed: widget.onApplyDefault,
            icon: const Icon(Icons.auto_fix_high, size: 18),
            label: Text(l.llmApplyDefaults),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.primaryBlue,
              side: BorderSide(
                color: AppTheme.primaryBlue.withValues(alpha: 0.5),
              ),
              minimumSize: const Size.fromHeight(48),
            ),
          ),
          const SizedBox(height: 16),
        ],


        if (widget.nameController != null) ...[
          Text(
            'Name',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: widget.nameController,
            decoration: const InputDecoration(
              hintText: 'e.g. LLM 1, Fast Assistant, DeepSeek Coder',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.label_outline, size: 20),
            ),
          ),
          const SizedBox(height: 16),
        ],

        // ── Provider ─────────────────────────────────────────────────
        Text(
          l.llmProviderLabel,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          isExpanded: true,
          initialValue: widget.providerKey.isNotEmpty
              ? widget.providerKey
              : (widget.showNoneOption ? '' : null),
          decoration: InputDecoration(
            prefixIcon: Icon(_providerIcon(provider)),
            border: const OutlineInputBorder(),
            helperText: provider == LlmProvider.embedded
                ? 'Embedded models will be downloaded to server host storage (/data/models).'
                : null,
            helperMaxLines: 2,
          ),
          items: [
            if (widget.showNoneOption)
              const DropdownMenuItem(value: '', child: Text('—')),
            const DropdownMenuItem(value: 'openai', child: Text('OpenAI')),
            const DropdownMenuItem(
              value: 'gemini',
              child: Text('Google Gemini'),
            ),
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
            if (widget.showEmbeddedOption)
              const DropdownMenuItem(
                value: 'embedded',
                child: Text('Embedded (on-device)'),
              ),
            if (widget.showLlm2Option)
              const DropdownMenuItem(
                value: 'llm2',
                child: Text('LLM 2 (from settings)'),
              ),
          ],
          onChanged: (v) {
            final newKey = v ?? '';
            widget.onProviderChanged(newKey);

            if (newKey == 'llm2') {
              final settings = widget.service;
              if (settings.isConfigured2) {
                widget.modelController.text = settings.model2;
                widget.apiKeyController.text = settings.apiKey2;
                widget.baseUrlController.text = settings.baseUrl2;
                widget.temperatureController.text = settings.temperature2
                    .toString();
                widget.maxTokensController.text = settings.maxTokens2
                    .toString();
                widget.onModelChanged?.call(settings.model2);
                widget.onSlmChanged(settings.isSlm2);
                widget.onMultiModalChanged(settings.isMultiModal2);
              }
              return;
            }

            final newProvider = LlmProvider.fromConfigKey(newKey);
            if (newProvider == LlmProvider.embedded) {
              widget.apiKeyController.clear();
              widget.baseUrlController.clear();
              widget.maxTokensController.text = '4096';
              final defaultModel =
                  defaultModels[LlmProvider.embedded]?.first ?? '';
              widget.modelController.text = defaultModel;
              widget.onModelChanged?.call(defaultModel);
              widget.onMultiModalChanged(
                LlmSettingsService.detectDefaultMultiModal(
                  LlmProvider.embedded,
                  defaultModel,
                ),
              );
              return;
            }

            if (newProvider == LlmProvider.none) {
              widget.modelController.clear();
              widget.apiKeyController.clear();
              widget.baseUrlController.clear();
              widget.temperatureController.text = '0.2';
              widget.maxTokensController.text = '0';
              widget.onModelChanged?.call('');
              return;
            }

            final savedModel = widget.service.getModelForProvider(newProvider);
            final defaults = defaultModels[newProvider] ?? const <String>[];
            final finalModel = savedModel.isNotEmpty
                ? savedModel
                : (defaults.isNotEmpty ? defaults.first : '');

            widget.modelController.text = finalModel;
            widget.onModelChanged?.call(finalModel);

            final savedApiKey = widget.service.getApiKeyForProvider(
              newProvider,
            );
            widget.apiKeyController.text = savedApiKey;

            final providerNeedsBaseUrl =
                newProvider == LlmProvider.ollama ||
                newProvider == LlmProvider.openaiCompatible ||
                newProvider == LlmProvider.mistral;
            if (providerNeedsBaseUrl) {
              var savedBaseUrl = widget.service.getBaseUrlForProvider(
                newProvider,
              );
              if (newProvider == LlmProvider.mistral) {
                if (savedBaseUrl.isEmpty ||
                    savedBaseUrl.contains('deepinfra') ||
                    savedBaseUrl.contains('openai.com') ||
                    savedBaseUrl.contains('localhost')) {
                  savedBaseUrl = 'https://api.mistral.ai/v1';
                }
              }
              widget.baseUrlController.text = savedBaseUrl;
            } else {
              widget.baseUrlController.clear();
            }

            widget.onMultiModalChanged(
              LlmSettingsService.detectDefaultMultiModal(
                newProvider,
                finalModel,
              ),
            );
          },
        ),

        if (widget.providerKey == 'llm2') ...[
          const SizedBox(height: 12),
          Card(
            color: AppTheme.primaryBlue.withValues(alpha: 0.07),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.info_outline,
                    size: 16,
                    color: AppTheme.primaryBlue,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l.llm2SettingsOverrideHint,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],

        if (provider != LlmProvider.none) ...[
          const SizedBox(height: 16),

          // ── Model picker or name field ─────────────────────────────
          if (isEmbedded) ...[
            EmbeddedModelPickerWidget(
              selectedFilename: widget.modelController.text,
              serverClient: widget.serverClient,
              onFilenameSelected: (filename) {
                widget.modelController.text = filename;
                widget.onModelChanged?.call(filename);
              },
            ),
          ] else ...[
            Text(
              l.llmModelLabel,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Builder(
              builder: (context) {
                final isFetchable =
                    provider == LlmProvider.ollama ||
                    provider == LlmProvider.openaiCompatible ||
                    provider == LlmProvider.openai ||
                    provider == LlmProvider.mistral;
                final models = (isFetchable && _fetchedModels.isNotEmpty)
                    ? _fetchedModels
                    : (defaultModels[provider] ?? const <String>[]);

                final hasSelection = widget.modelController.text.trim().isNotEmpty;
                final displayText = hasSelection
                    ? widget.modelController.text.trim()
                    : 'Select or search model...';

                final helperText = models.isNotEmpty
                    ? '${models.length} models available. Tap to choose or search.'
                    : 'Tap reload to fetch models from endpoint, or tap to search/enter custom name.';

                return InkWell(
                  onTap: () => _openModelSearchPicker(context, models),
                  borderRadius: BorderRadius.circular(4),
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: l.llmModelLabel,
                      border: const OutlineInputBorder(),
                      isDense: true,
                      helperText: helperText,
                      prefixIcon: const Icon(Icons.model_training),
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (provider != LlmProvider.none && provider != LlmProvider.embedded)
                            IconButton(
                              icon: _fetchingModels
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  : const Icon(Icons.refresh_rounded, size: 20),
                              tooltip: 'Fetch / Reload models from endpoint',
                              onPressed: _fetchingModels ? null : _fetchModels,
                            ),
                          IconButton(
                            icon: const Icon(Icons.arrow_drop_down, size: 22),
                            tooltip: 'Select model',
                            onPressed: () => _openModelSearchPicker(context, models),
                          ),
                        ],
                      ),
                    ),
                    child: Text(
                      displayText,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: hasSelection ? FontWeight.w600 : FontWeight.normal,
                        color: hasSelection
                            ? Theme.of(context).textTheme.bodyMedium?.color
                            : Theme.of(context).hintColor,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                );
              },
            ),

            // ── Test Connection Button ──────────────────────────────
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _testingConnection ? null : _testConnection,
                    icon: _testingConnection
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.wifi_tethering, size: 18),
                    label: Text(_testingConnection ? 'Testing…' : 'Test API Connection'),
                  ),
                ),
              ],
            ),
          ],

          // ── API Key ────────────────────────────────────────────────
          if (hasDedicatedApiKeyField) ...[
            const SizedBox(height: 16),
            Text(
              l.llmApiKeyLabel,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: widget.apiKeyController,
              obscureText: _obscureKey,
              decoration: InputDecoration(
                hintText: _apiKeyHint(provider),
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.key),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscureKey ? Icons.visibility : Icons.visibility_off,
                  ),
                  onPressed: () => setState(() => _obscureKey = !_obscureKey),
                ),
              ),
            ),
          ],

          // ── Base URL ───────────────────────────────────────────────
          if (requiresBaseUrl) ...[
            const SizedBox(height: 16),
            Text(
              l.llmBaseUrlLabel,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: widget.baseUrlController,
              decoration: InputDecoration(
                hintText: _baseUrlHint(provider),
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.link),
              ),
            ),
          ],

          // ── Advanced Parameters Toggle ─────────────────────────────
          const SizedBox(height: 16),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: _showAdvanced,
            title: const Text('Advanced Settings'),
            onChanged: (v) => setState(() => _showAdvanced = v),
          ),

          if (_showAdvanced) ...[
            const SizedBox(height: 8),
            Card(
              elevation: 0,
              color: isDark ? Colors.grey[900] : Colors.grey[100],
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: widget.isSlm,
                      title: const Text('Small Language Model (SLM)'),
                      subtitle: const Text(
                        'Optimizes system prompt behavior for smaller/local models.',
                      ),
                      onChanged: (v) => widget.onSlmChanged(v ?? false),
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: widget.isMultiModal,
                      title: const Text('Multi-Modal Model'),
                      subtitle: const Text(
                        'Enables sending image attachments and binary data.',
                      ),
                      onChanged: (v) => widget.onMultiModalChanged(v ?? false),
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: widget.thinking,
                      title: const Text('Thinking / Reasoning'),
                      subtitle: const Text(
                        'Enables extended reasoning output on supported models.',
                      ),
                      onChanged: (v) => widget.onThinkingChanged(v ?? false),
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: widget.useNativeToolCall,
                      title: const Text('Native Tool Call'),
                      subtitle: const Text(
                        'Uses provider\'s structured function calling format.',
                      ),
                      onChanged: (v) =>
                          widget.onUseNativeToolCallChanged(v ?? false),
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: widget.useSafeToolCall,
                      title: const Text('Safe Tool Call'),
                      subtitle: const Text(
                        'Requires verification before running tools.',
                      ),
                      onChanged: (v) =>
                          widget.onUseSafeToolCallChanged(v ?? false),
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: widget.enableToolParameterAutoRecovery,
                      title: const Text('Tool Parameter Auto-Recovery'),
                      subtitle: const Text(
                        'Allows LLM to recover from parameter schema errors. Disable for smaller/local models to avoid loops.',
                      ),
                      onChanged: (v) => widget
                          .onEnableToolParameterAutoRecoveryChanged
                          ?.call(v ?? false),
                    ),
                    const Divider(height: 24),
                    TextFormField(
                      controller: widget.temperatureController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Temperature (e.g. 0.2)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: widget.maxTokensController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Max Tokens (0 = default)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (widget.maxToolOutputSizeController != null) ...[
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: widget.maxToolOutputSizeController,
                        decoration: const InputDecoration(
                          labelText: 'Max Tool Output Size (chars)',
                          hintText: 'e.g. 2560000',
                          helperText:
                              'Limits MCP tool result size to prevent context overflow',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.data_usage_outlined),
                        ),
                        keyboardType: TextInputType.number,
                      ),
                    ],
                    if (widget.tokenWarningThresholdController != null) ...[
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: widget.tokenWarningThresholdController,
                        decoration: const InputDecoration(
                          labelText: 'Token Warning Threshold',
                          hintText: 'e.g. 1500000',
                          helperText: 'Cleanup suggestion after this many tokens',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.warning_amber_outlined),
                        ),
                        keyboardType: TextInputType.number,
                      ),
                    ],
                    if (widget.topKController != null &&
                        widget.topPController != null &&
                        widget.repeatPenaltyController != null &&
                        widget.seedController != null) ...[
                      const SizedBox(height: 16),
                      LlmAdvancedParamsWidget(
                        topKController: widget.topKController!,
                        topPController: widget.topPController!,
                        repeatPenaltyController:
                            widget.repeatPenaltyController!,
                        seedController: widget.seedController!,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ],
      ],
    );
  }

  String _apiKeyHint(LlmProvider p) {
    switch (p) {
      case LlmProvider.gemini:
        return 'AIza...';
      case LlmProvider.openai:
        return 'sk-...';
      case LlmProvider.claude:
        return 'sk-ant-...';
      case LlmProvider.mistral:
        return 'mistral-...';
      default:
        return 'Enter API Key';
    }
  }

  String _baseUrlHint(LlmProvider p) {
    switch (p) {
      case LlmProvider.ollama:
        return 'http://localhost:11434';
      case LlmProvider.openaiCompatible:
        return 'http://localhost:8080/v1';
      case LlmProvider.mistral:
        return 'https://api.mistral.ai/v1';
      default:
        return 'https://...';
    }
  }

  void _openModelSearchPicker(BuildContext context, List<String> models) {
    final isMobile = MediaQuery.sizeOf(context).width < 600;
    final currentSelected = widget.modelController.text.trim();

    void onSelected(String model) {
      widget.modelController.text = model;
      widget.onModelChanged?.call(model);
      widget.onMultiModalChanged(
        LlmSettingsService.detectDefaultMultiModal(_currentProvider, model),
      );
      Navigator.of(context).pop();
    }

    if (isMobile) {
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Theme.of(context).colorScheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (ctx) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(ctx).height * 0.75,
            ),
            child: _ModelSearchPickerContent(
              models: models,
              initialSelected: currentSelected,
              onSelected: onSelected,
              onReload: _fetchModels,
              provider: _currentProvider,
              onClose: () => Navigator.of(ctx).pop(),
            ),
          ),
        ),
      );
    } else {
      showDialog(
        context: context,
        builder: (ctx) => Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: 550,
              maxHeight: 550,
            ),
            child: _ModelSearchPickerContent(
              models: models,
              initialSelected: currentSelected,
              onSelected: onSelected,
              onReload: _fetchModels,
              provider: _currentProvider,
              onClose: () => Navigator.of(ctx).pop(),
            ),
          ),
        ),
      );
    }
  }
}

class _ModelSearchPickerContent extends StatefulWidget {
  final List<String> models;
  final String initialSelected;
  final ValueChanged<String> onSelected;
  final Future<List<String>> Function()? onReload;
  final LlmProvider provider;
  final VoidCallback? onClose;

  const _ModelSearchPickerContent({
    required this.models,
    required this.initialSelected,
    required this.onSelected,
    this.onReload,
    required this.provider,
    this.onClose,
  });

  @override
  State<_ModelSearchPickerContent> createState() =>
      _ModelSearchPickerContentState();
}

class _ModelSearchPickerContentState extends State<_ModelSearchPickerContent> {
  final TextEditingController _searchCtrl = TextEditingController();
  late List<String> _currentModels;
  bool _isReloading = false;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _currentModels = List.from(widget.models);
    if (_currentModels.isEmpty && widget.onReload != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _handleReload();
      });
    }
  }

  Future<void> _handleReload() async {
    if (widget.onReload == null || _isReloading) return;
    setState(() => _isReloading = true);
    try {
      final updated = await widget.onReload!();
      if (mounted) {
        setState(() {
          _currentModels = List.from(updated);
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isReloading = false);
      }
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filtered = _filter.isEmpty
        ? _currentModels
        : _currentModels
            .where((m) => m.toLowerCase().contains(_filter.toLowerCase()))
            .toList();

    final showCustomOption = _filter.trim().isNotEmpty &&
        !_currentModels.any(
          (m) => m.toLowerCase() == _filter.trim().toLowerCase(),
        );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Row(
            children: [
              const Icon(Icons.psychology_outlined, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _isReloading
                      ? 'Select Model (Loading...)'
                      : 'Select Model (${_currentModels.length} available)',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (widget.onReload != null)
                IconButton(
                  icon: _isReloading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded, size: 20),
                  tooltip: 'Reload models from endpoint',
                  onPressed: _isReloading ? null : _handleReload,
                ),
              if (widget.onClose != null)
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: widget.onClose,
                ),
            ],
          ),
        ),
        // Search field
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: TextField(
            controller: _searchCtrl,
            autofocus: true,
            decoration: InputDecoration(
              hintText: 'Search models...',
              prefixIcon: const Icon(Icons.search, size: 18),
              suffixIcon: _filter.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 16),
                      onPressed: () {
                        setState(() {
                          _searchCtrl.clear();
                          _filter = '';
                        });
                      },
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            ),
            onChanged: (val) {
              setState(() {
                _filter = val;
              });
            },
          ),
        ),
        const SizedBox(height: 6),
        if (_isReloading && _currentModels.isNotEmpty)
          const LinearProgressIndicator(minHeight: 2),
        const Divider(height: 1),
        // Custom model entry option if search text doesn't match list
        if (showCustomOption) ...[
          Material(
            color: theme.colorScheme.primaryContainer.withValues(alpha: 0.25),
            child: ListTile(
              dense: true,
              leading: const Icon(
                Icons.add_circle_outline,
                color: Colors.blueAccent,
              ),
              title: Text(
                'Use custom: "${_filter.trim()}"',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: const Text('Select to enter this model name manually'),
              onTap: () => widget.onSelected(_filter.trim()),
            ),
          ),
          const Divider(height: 1),
        ],
        // Models list
        Flexible(
          child: filtered.isEmpty && !showCustomOption
              ? Padding(
                  padding: const EdgeInsets.all(28.0),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_isReloading) ...[
                          const SizedBox(
                            width: 32,
                            height: 32,
                            child: CircularProgressIndicator(strokeWidth: 3),
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'Loading available models...',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'Connecting to endpoint and fetching model catalog...',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                        ] else ...[
                          Icon(
                            _currentModels.isEmpty
                                ? Icons.cloud_download_outlined
                                : Icons.search_off_rounded,
                            size: 40,
                            color: Colors.grey,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _currentModels.isEmpty
                                ? 'No models loaded yet'
                                : 'No models found matching "${_filter.trim()}"',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _currentModels.isEmpty
                                ? 'Tap reload to fetch models from the endpoint, or type a custom name in the search box above.'
                                : 'You can type this name in the search bar and select "Use custom" to use it.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                          if (_currentModels.isEmpty && widget.onReload != null) ...[
                            const SizedBox(height: 16),
                            FilledButton.tonalIcon(
                              onPressed: _isReloading ? null : _handleReload,
                              icon: _isReloading
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  : const Icon(Icons.refresh_rounded, size: 16),
                              label: Text(_isReloading ? 'Fetching...' : 'Reload Models'),
                            ),
                          ],
                        ],
                      ],
                    ),
                  ),
                )
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: filtered.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (ctx, index) {
                    final model = filtered[index];
                    final isSelected = model == widget.initialSelected;
                    final isMulti = LlmSettingsService.detectDefaultMultiModal(
                      widget.provider,
                      model,
                    );
                    final price = getModelTokenPrice(
                      providerKey: widget.provider.configKey,
                      model: model,
                    );
                    return ListTile(
                      dense: true,
                      selected: isSelected,
                      title: Text(
                        model,
                        style: TextStyle(
                          fontWeight:
                              isSelected ? FontWeight.bold : FontWeight.w500,
                        ),
                      ),
                      subtitle: price != null && price.formattedContextWindow.isNotEmpty
                          ? Text(
                              '${price.formattedContextWindow} • in \$${price.inputPer1MUsd.toStringAsFixed(2)} / out \$${price.outputPer1MUsd.toStringAsFixed(2)}',
                              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                            )
                          : null,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isMulti) ...[
                            const Icon(
                              Icons.visibility_outlined,
                              size: 15,
                              color: Colors.blueAccent,
                            ),
                            const SizedBox(width: 6),
                          ],
                          if (isSelected)
                            const Icon(
                              Icons.check,
                              size: 18,
                              color: Colors.green,
                            ),
                        ],
                      ),
                      onTap: () => widget.onSelected(model),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
