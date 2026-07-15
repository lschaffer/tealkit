import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../l10n/app_localizations.dart';
import '../config/app_theme.dart';
import '../services/llm_settings_service.dart';
import '../services/server_api_client.dart';
import 'embedded_llm/embedded_model_picker_widget.dart';

/// A unified reusable form widget for configuring LLM settings.
/// Can be used for global settings, task overrides, and agent overrides.
class LlmSettingsFormWidget extends StatefulWidget {
  final String providerKey;
  final TextEditingController modelController;
  final TextEditingController apiKeyController;
  final TextEditingController baseUrlController;
  final TextEditingController temperatureController;
  final TextEditingController maxTokensController;

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

  const LlmSettingsFormWidget({
    super.key,
    required this.providerKey,
    required this.modelController,
    required this.apiKeyController,
    required this.baseUrlController,
    required this.temperatureController,
    required this.maxTokensController,
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

  Future<void> _fetchModels() async {
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
          _fetchedModels = list;
          if (list.isNotEmpty && widget.modelController.text.trim().isEmpty) {
            widget.modelController.text = list.first;
            widget.onModelChanged?.call(list.first);
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Successfully fetched ${list.length} models!'),
            backgroundColor: AppTheme.success,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
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
          final base = baseUrl.isEmpty ? 'https://api.mistral.ai/v1' : baseUrl;
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
            errorMsg = 'HTTP ${resp.statusCode}';
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
        provider == LlmProvider.mistral;

    final hasDedicatedApiKeyField =
        provider != LlmProvider.none &&
        provider != LlmProvider.ollama &&
        provider != LlmProvider.openaiCompatible &&
        provider != LlmProvider.embedded;

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

        // ── Consent Card (Global) ────────────────────────────────────
        if (widget.showConsent) ...[
          Card(
            color: AppTheme.warning.withValues(alpha: 0.08),
            shape: RoundedRectangleBorder(
              side: BorderSide(color: AppTheme.warning.withValues(alpha: 0.2)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.privacy_tip_outlined,
                        color: AppTheme.warning,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'AI Data Sharing Consent',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'When enabled, your prompts, attachments, and tool outputs may be sent to the selected AI provider '
                    '(for example OpenAI, Google, Anthropic, or other remote endpoints) to generate responses.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    value: widget.aiDataSharingConsent,
                    title: const Text(
                      'Allow sending my prompts/data to AI providers',
                    ),
                    subtitle: const Text(
                      'Required for remote AI usage. You can disable this any time.',
                    ),
                    onChanged: widget.onAiDataSharingConsentChanged,
                  ),
                ],
              ),
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
              final savedBaseUrl = widget.service.getBaseUrlForProvider(
                newProvider,
              );
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
            Autocomplete<String>(
              initialValue: widget.modelController.value,
              optionsBuilder: (textEditingValue) {
                final isFetchable =
                    provider == LlmProvider.ollama ||
                    provider == LlmProvider.openaiCompatible ||
                    provider == LlmProvider.openai ||
                    provider == LlmProvider.mistral;
                final models = (isFetchable && _fetchedModels.isNotEmpty)
                    ? _fetchedModels
                    : (defaultModels[provider] ?? const <String>[]);
                if (textEditingValue.text.isEmpty) {
                  return models;
                }
                return models.where(
                  (m) => m.toLowerCase().contains(
                    textEditingValue.text.toLowerCase(),
                  ),
                );
              },
              fieldViewBuilder: (ctx, controller, focusNode, onSubmitted) {
                if (controller.text != widget.modelController.text) {
                  controller.value = TextEditingValue(
                    text: widget.modelController.text,
                    selection: TextSelection.collapsed(
                      offset: widget.modelController.text.length,
                    ),
                  );
                }
                return TextFormField(
                  controller: controller,
                  focusNode: focusNode,
                  onChanged: (value) {
                    widget.modelController.text = value;
                    widget.onModelChanged?.call(value);
                    widget.onMultiModalChanged(
                      LlmSettingsService.detectDefaultMultiModal(
                        provider,
                        value,
                      ),
                    );
                  },
                  decoration: InputDecoration(
                    hintText: l.llmModelHint,
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.model_training),
                  ),
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? l.llmModelRequired : null,
                );
              },
              onSelected: (v) {
                widget.modelController.text = v;
                widget.onModelChanged?.call(v);
                widget.onMultiModalChanged(
                  LlmSettingsService.detectDefaultMultiModal(provider, v),
                );
              },
            ),

            // ── Fetch & Test Buttons ─────────────────────────────────
            const SizedBox(height: 8),
            Row(
              children: [
                if (provider == LlmProvider.ollama ||
                    provider == LlmProvider.openaiCompatible ||
                    provider == LlmProvider.openai ||
                    provider == LlmProvider.mistral) ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _fetchingModels ? null : _fetchModels,
                      icon: _fetchingModels
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh, size: 18),
                      label: Text(
                        _fetchedModels.isEmpty
                            ? 'Fetch models'
                            : 'Refresh (${_fetchedModels.length})',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
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
                    label: Text(_testingConnection ? 'Testing…' : 'Test API'),
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
                      onChanged: (v) =>
                          widget.onEnableToolParameterAutoRecoveryChanged?.call(v ?? false),
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
}
