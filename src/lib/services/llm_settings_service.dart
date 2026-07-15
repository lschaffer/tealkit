import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../services/app_logger.dart';

// ═══════════════════════════════════════════════════════════════
// LLM Provider enum — matches TaskLlmConfig provider strings
// ═══════════════════════════════════════════════════════════════

enum LlmProvider {
  none,
  gemini,
  openai,
  claude,
  mistral,
  ollama,
  openaiCompatible,
  embedded;

  String get label {
    switch (this) {
      case LlmProvider.none:
        return '—';
      case LlmProvider.gemini:
        return 'Google Gemini';
      case LlmProvider.openai:
        return 'OpenAI';
      case LlmProvider.claude:
        return 'Anthropic Claude';
      case LlmProvider.mistral:
        return 'Mistral AI';
      case LlmProvider.ollama:
        return 'Ollama (local)';
      case LlmProvider.openaiCompatible:
        return 'OpenAI-compatible';
      case LlmProvider.embedded:
        return 'Embedded (on-device)';
    }
  }

  /// The string stored in TaskLlmConfig.provider
  String get configKey {
    switch (this) {
      case LlmProvider.none:
        return '';
      case LlmProvider.gemini:
        return 'gemini';
      case LlmProvider.openai:
        return 'openai';
      case LlmProvider.claude:
        return 'claude';
      case LlmProvider.mistral:
        return 'mistral';
      case LlmProvider.ollama:
        return 'ollama';
      case LlmProvider.openaiCompatible:
        return 'openai_compatible';
      case LlmProvider.embedded:
        return 'embedded';
    }
  }

  static LlmProvider fromConfigKey(String? key) {
    if (key == null || key.isEmpty) return LlmProvider.none;
    for (final p in LlmProvider.values) {
      if (p.configKey == key) return p;
    }
    return LlmProvider.none;
  }
}

// ═══════════════════════════════════════════════════════════════
// Default model suggestions per provider
// ═══════════════════════════════════════════════════════════════

const Map<LlmProvider, List<String>> defaultModels = {
  LlmProvider.gemini: [
    'gemini-2.5-flash',
    'gemini-2.5-flash-lite',
    'gemini-2.5-pro',
    'gemini-3.1-flash',
    'gemini-3.1-flash-lite',
    'gemini-3.1-pro',
  ],
  LlmProvider.openai: ['gpt-5', 'gpt-5-mini'],
  LlmProvider.claude: ['claude-sonnet-5'],
  LlmProvider.mistral: [
    'mistral-large-latest',
    'mistral-medium-latest',
    'mistral-small-latest',
  ],
  LlmProvider.ollama: [],
  LlmProvider.openaiCompatible: [],
  LlmProvider.embedded: [],
};

class ModelTokenPrice {
  final double inputPer1MUsd;
  final double outputPer1MUsd;

  const ModelTokenPrice({
    required this.inputPer1MUsd,
    required this.outputPer1MUsd,
  });
}

class _CachedModelPrice {
  final ModelTokenPrice price;
  final DateTime fetchedAt;
  final bool isLive;

  const _CachedModelPrice({
    required this.price,
    required this.fetchedAt,
    this.isLive = false,
  });
}

const Duration _livePriceTtl = Duration(hours: 12);
final Map<String, _CachedModelPrice> _liveModelPricingCache =
    <String, _CachedModelPrice>{};
const Duration _openRouterModelsTtl = Duration(minutes: 30);
DateTime? _openRouterModelsFetchedAt;
List<dynamic>? _openRouterModelsCache;

const Map<String, Map<String, ModelTokenPrice>> _modelPricingByProvider = {
  'gemini': {
    'gemini-2.5-flash': ModelTokenPrice(
      inputPer1MUsd: 0.15,
      outputPer1MUsd: 0.60,
    ),
  },
  'mistral': {
    'mistral-large-latest': ModelTokenPrice(
      inputPer1MUsd: 0.50,
      outputPer1MUsd: 1.50,
    ),
    'mistral-large': ModelTokenPrice(inputPer1MUsd: 0.50, outputPer1MUsd: 1.50),
    'mistral-large-2512': ModelTokenPrice(
      inputPer1MUsd: 0.50,
      outputPer1MUsd: 1.50,
    ),
    'mistral-medium-latest': ModelTokenPrice(
      inputPer1MUsd: 0.40,
      outputPer1MUsd: 2.00,
    ),
    'mistral-medium': ModelTokenPrice(
      inputPer1MUsd: 0.40,
      outputPer1MUsd: 2.00,
    ),
    'mistral-medium-2508': ModelTokenPrice(
      inputPer1MUsd: 0.40,
      outputPer1MUsd: 2.00,
    ),
    'mistral-small-latest': ModelTokenPrice(
      inputPer1MUsd: 0.10,
      outputPer1MUsd: 0.30,
    ),
    'mistral-small': ModelTokenPrice(inputPer1MUsd: 0.10, outputPer1MUsd: 0.30),
    'mistral-small-2506': ModelTokenPrice(
      inputPer1MUsd: 0.10,
      outputPer1MUsd: 0.30,
    ),
  },
};

String _normalizeModelName(String model) => model.trim().toLowerCase();

String _priceCacheKey({required String providerKey, required String model}) =>
    '${providerKey.trim().toLowerCase()}:${_normalizeModelName(model)}';

_CachedModelPrice? _getCachedLivePrice({
  required String providerKey,
  required String model,
}) {
  final key = _priceCacheKey(providerKey: providerKey, model: model);
  final cached = _liveModelPricingCache[key];
  if (cached == null) return null;
  if (DateTime.now().difference(cached.fetchedAt) > _livePriceTtl) return null;
  return cached;
}

bool isLiveCachedPrice({required String providerKey, required String model}) {
  final cached = _getCachedLivePrice(providerKey: providerKey, model: model);
  return cached?.isLive ?? false;
}

void _cacheLivePrice({
  required String providerKey,
  required String model,
  required ModelTokenPrice price,
  bool isLive = false,
}) {
  final now = DateTime.now();
  final directKey = _priceCacheKey(providerKey: providerKey, model: model);
  _liveModelPricingCache[directKey] = _CachedModelPrice(
    price: price,
    fetchedAt: now,
    isLive: isLive,
  );

  final normalizedModel = _normalizeModelName(model);
  if (normalizedModel.endsWith('-latest')) {
    final withoutLatest = normalizedModel.substring(
      0,
      normalizedModel.length - '-latest'.length,
    );
    final aliasKey = _priceCacheKey(
      providerKey: providerKey,
      model: withoutLatest,
    );
    _liveModelPricingCache[aliasKey] = _CachedModelPrice(
      price: price,
      fetchedAt: now,
      isLive: isLive,
    );
  } else {
    final aliasKey = _priceCacheKey(
      providerKey: providerKey,
      model: '$normalizedModel-latest',
    );
    _liveModelPricingCache[aliasKey] = _CachedModelPrice(
      price: price,
      fetchedAt: now,
      isLive: isLive,
    );
  }
}

double? _parseDouble(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString());
}

double _toPer1M(double value) {
  // OpenRouter pricing fields are USD/token in current schema.
  // Guard with heuristic to avoid multiplying values already in per-1M format.
  if (value <= 0.01) {
    return value * 1000000.0;
  }
  return value;
}

Future<List<dynamic>?> _loadOpenRouterModels() async {
  if (_openRouterModelsCache != null &&
      _openRouterModelsFetchedAt != null &&
      DateTime.now().difference(_openRouterModelsFetchedAt!) <=
          _openRouterModelsTtl) {
    return _openRouterModelsCache;
  }

  final response = await http
      .get(Uri.parse('https://openrouter.ai/api/v1/models'))
      .timeout(const Duration(seconds: 12));
  if (response.statusCode != 200) return null;

  final decoded = jsonDecode(response.body);
  if (decoded is! Map<String, dynamic>) return null;
  final data = decoded['data'];
  if (data is! List<dynamic>) return null;

  _openRouterModelsCache = data;
  _openRouterModelsFetchedAt = DateTime.now();
  return data;
}

bool _matchesProviderForModel({
  required String providerKey,
  required String idLower,
  required String nameLower,
}) {
  switch (providerKey) {
    case 'openai':
      return idLower.startsWith('openai/') ||
          idLower.contains('gpt') ||
          nameLower.contains('openai');
    case 'claude':
      return idLower.startsWith('anthropic/') ||
          idLower.contains('claude') ||
          nameLower.contains('claude');
    case 'mistral':
      return idLower.startsWith('mistral-ai/') ||
          idLower.startsWith('mistralai/') ||
          idLower.contains('mistral');
    case 'gemini':
      return idLower.startsWith('google/') ||
          idLower.contains('gemini') ||
          nameLower.contains('gemini');
    default:
      return true;
  }
}

Future<ModelTokenPrice?> _fetchOpenRouterLivePrice({
  required String providerKey,
  required String normalizedModel,
}) async {
  final models = await _loadOpenRouterModels();
  if (models == null || models.isEmpty) return null;

  final baseModel = normalizedModel.endsWith('-latest')
      ? normalizedModel.substring(0, normalizedModel.length - '-latest'.length)
      : normalizedModel;

  ModelTokenPrice? bestPrice;
  var bestScore = -1;

  for (final raw in models) {
    if (raw is! Map<String, dynamic>) continue;

    final idLower = (raw['id'] ?? '').toString().trim().toLowerCase();
    final nameLower = (raw['name'] ?? '').toString().trim().toLowerCase();
    if (idLower.isEmpty) continue;
    if (!_matchesProviderForModel(
      providerKey: providerKey,
      idLower: idLower,
      nameLower: nameLower,
    )) {
      continue;
    }

    final shortModel = idLower.contains('/')
        ? idLower.split('/').last
        : idLower;

    var score = 0;
    if (shortModel == normalizedModel) {
      score += 120;
    } else if (shortModel == baseModel) {
      score += 110;
    } else if (shortModel.startsWith('$baseModel-') ||
        shortModel.contains(baseModel)) {
      score += 80;
    } else if (nameLower.contains(baseModel)) {
      score += 60;
    } else {
      continue;
    }

    if (idLower.startsWith('$providerKey/')) {
      score += 30;
    }

    final pricing = raw['pricing'];
    if (pricing is! Map<String, dynamic>) continue;
    final promptRaw = _parseDouble(pricing['prompt'] ?? pricing['input']);
    final completionRaw = _parseDouble(
      pricing['completion'] ?? pricing['output'],
    );
    if (promptRaw == null || completionRaw == null) continue;

    final candidate = ModelTokenPrice(
      inputPer1MUsd: _toPer1M(promptRaw),
      outputPer1MUsd: _toPer1M(completionRaw),
    );

    if (score > bestScore) {
      bestScore = score;
      bestPrice = candidate;
    }
  }

  return bestPrice;
}

Future<ModelTokenPrice?> _fetchMistralLivePrice(String normalizedModel) async {
  final modelToUrl = <String, String>{
    'mistral-large': 'https://docs.mistral.ai/models/mistral-large-3-25-12',
    'mistral-large-latest':
        'https://docs.mistral.ai/models/mistral-large-3-25-12',
    'mistral-medium': 'https://docs.mistral.ai/models/mistral-medium-3-1-25-08',
    'mistral-medium-latest':
        'https://docs.mistral.ai/models/mistral-medium-3-1-25-08',
    'mistral-small': 'https://docs.mistral.ai/models/mistral-small-3-2-25-06',
    'mistral-small-latest':
        'https://docs.mistral.ai/models/mistral-small-3-2-25-06',
  };

  String? url;
  for (final entry in modelToUrl.entries) {
    if (normalizedModel.startsWith(entry.key)) {
      url = entry.value;
      break;
    }
  }
  if (url == null) return null;

  final response = await http
      .get(Uri.parse(url))
      .timeout(const Duration(seconds: 12));
  if (response.statusCode != 200) return null;

  final body = response.body;
  final match = RegExp(
    r'PRICE\s*\$\s*([0-9]+(?:\.[0-9]+)?)\s*/M TOKENS[\s\S]{0,300}?\$\s*([0-9]+(?:\.[0-9]+)?)\s*/M TOKENS',
    caseSensitive: false,
  ).firstMatch(body);
  if (match == null) return null;

  final input = double.tryParse(match.group(1) ?? '');
  final output = double.tryParse(match.group(2) ?? '');
  if (input == null || output == null) return null;
  return ModelTokenPrice(inputPer1MUsd: input, outputPer1MUsd: output);
}

Future<ModelTokenPrice?> refreshModelTokenPrice({
  required String providerKey,
  required String model,
}) async {
  final normalizedProvider = providerKey.trim().toLowerCase();
  final normalizedModel = _normalizeModelName(model);
  if (normalizedProvider.isEmpty || normalizedModel.isEmpty) return null;

  try {
    ModelTokenPrice? fetched;
    if (normalizedProvider != 'ollama' &&
        normalizedProvider != 'openai_compatible') {
      fetched = await _fetchOpenRouterLivePrice(
        providerKey: normalizedProvider,
        normalizedModel: normalizedModel,
      );
    }
    if (fetched == null && normalizedProvider == 'mistral') {
      fetched = await _fetchMistralLivePrice(normalizedModel);
    }
    if (fetched != null) {
      _cacheLivePrice(
        providerKey: normalizedProvider,
        model: normalizedModel,
        price: fetched,
        isLive: true,
      );
      return fetched;
    }
  } catch (e) {
    log.warning(
      '[LLM Pricing] Live price refresh failed for $normalizedProvider/$normalizedModel: $e',
    );
  }

  return getModelTokenPrice(
    providerKey: normalizedProvider,
    model: normalizedModel,
  );
}

ModelTokenPrice? getModelTokenPrice({
  required String providerKey,
  required String model,
}) {
  final normalizedProvider = providerKey.trim().toLowerCase();
  final normalizedModel = _normalizeModelName(model);

  final cachedLive = _getCachedLivePrice(
    providerKey: normalizedProvider,
    model: normalizedModel,
  );
  if (cachedLive != null) return cachedLive.price;

  final providerModels = _modelPricingByProvider[normalizedProvider];
  if (providerModels == null) return null;

  final direct = providerModels[normalizedModel];
  if (direct != null) return direct;

  // Model IDs change over time (e.g. adding/removing "-latest").
  // Try common aliases before giving up.
  if (normalizedModel.endsWith('-latest')) {
    final withoutLatest = normalizedModel.substring(
      0,
      normalizedModel.length - '-latest'.length,
    );
    final alias = providerModels[withoutLatest];
    if (alias != null) return alias;
  } else {
    final withLatest = '$normalizedModel-latest';
    final alias = providerModels[withLatest];
    if (alias != null) return alias;
  }

  return null;
}

double estimateTokenCostUsd({
  required String providerKey,
  required String model,
  required int promptTokens,
  required int completionTokens,
}) {
  final price = getModelTokenPrice(providerKey: providerKey, model: model);
  if (price == null) return 0;
  final inputCost = (promptTokens / 1000000) * price.inputPer1MUsd;
  final outputCost = (completionTokens / 1000000) * price.outputPer1MUsd;
  return inputCost + outputCost;
}

// ═══════════════════════════════════════════════════════════════
// Service – persists LLM settings in secure local storage
// ═══════════════════════════════════════════════════════════════

class LlmSettingsService extends ChangeNotifier {
  // Singleton for app-wide access
  static final LlmSettingsService instance = LlmSettingsService._();
  LlmSettingsService._();

  static const _storage = FlutterSecureStorage(aOptions: AndroidOptions());

  // On Linux the keyring may be locked (e.g. headless / VNC). Once we detect
  // that, we skip secure storage entirely and use shadow prefs for the remainder
  // of the app session — avoiding repeated unlock prompts and partial reads.
  bool _keyringUnavailable = false;

  // Shadow key prefix in SharedPreferences — used as background fallback when
  // FlutterSecureStorage is not yet migrated to custom ciphers in the isolate.
  static const _kShadowPrefix = '_llm_shadow_';

  // ── Storage keys ──────────────────────────────────
  static const _kProvider = 'llm_provider';
  static const _kModel = 'llm_model';
  static const _kApiKey = 'llm_api_key';
  static const _kBaseUrl = 'llm_base_url';
  static const _kTemperature = 'llm_temperature';
  static const _kMaxTokens = 'llm_max_tokens';
  static const _kMaxToolOutputSize = 'llm_max_tool_output_size';
  static const _kTokenWarningThreshold = 'llm_token_warning_threshold';
  static const _kMigrated = 'llm_migrated_to_secure';
  static const _kIsSlm = 'llm_is_slm';
  static const _kIsMultiModal = 'llm_is_multi_modal';
  static const _kTopK = 'llm_top_k';
  static const _kTopP = 'llm_top_p';
  static const _kRepeatPenalty = 'llm_repeat_penalty';
  static const _kSeed = 'llm_seed';
  static const _kThinking = 'llm_thinking';
  static const _kUseNativeToolCall = 'llm_use_native_tool_call';
  static const _kUseSafeToolCall = 'llm_use_safe_tool_call';
  static const _kEnableToolParameterAutoRecovery = 'llm_enable_tool_parameter_auto_recovery';

  // ── LLM 2 (coding) storage keys ───────────────────
  static const _kProvider2 = 'llm2_provider';
  static const _kModel2 = 'llm2_model';
  static const _kApiKey2 = 'llm2_api_key';
  static const _kBaseUrl2 = 'llm2_base_url';
  static const _kTemperature2 = 'llm2_temperature';
  static const _kMaxTokens2 = 'llm2_max_tokens';
  static const _kMaxToolOutputSize2 = 'llm2_max_tool_output_size';
  static const _kTokenWarningThreshold2 = 'llm2_token_warning_threshold';
  static const _kIsSlm2 = 'llm2_is_slm';
  static const _kIsMultiModal2 = 'llm2_is_multi_modal';
  static const _kTopK2 = 'llm2_top_k';
  static const _kTopP2 = 'llm2_top_p';
  static const _kRepeatPenalty2 = 'llm2_repeat_penalty';
  static const _kSeed2 = 'llm2_seed';
  static const _kThinking2 = 'llm2_thinking';
  static const _kUseNativeToolCall2 = 'llm2_use_native_tool_call';
  static const _kUseSafeToolCall2 = 'llm2_use_safe_tool_call';

  // ── State ─────────────────────────────────────────
  LlmProvider _provider = LlmProvider.none;
  String _model = '';
  String _apiKey = '';
  String _baseUrl = '';
  double _temperature = 0.2;
  int _maxTokens = 0;
  int _maxToolOutputSize = 2560000;
  int _tokenWarningThreshold = 1500000;
  bool _isSlm = false;
  bool _isMultiModal = true;
  int? _topK;
  double? _topP;
  double? _repeatPenalty;
  int? _seed;
  bool _thinking = false;
  bool _useNativeToolCall = true;
  bool _useSafeToolCall = false;
  bool _enableToolParameterAutoRecovery = true;
  bool _loaded = false;

  // ── LLM 2 state ───────────────────────────────────
  LlmProvider _provider2 = LlmProvider.none;
  String _model2 = '';
  String _apiKey2 = '';
  String _baseUrl2 = '';
  double _temperature2 = 0.2;
  int _maxTokens2 = 0;
  int _maxToolOutputSize2 = 2560000;
  int _tokenWarningThreshold2 = 1500000;
  bool _isSlm2 = false;
  bool _isMultiModal2 = true;
  int? _topK2;
  double? _topP2;
  double? _repeatPenalty2;
  int? _seed2;
  bool _thinking2 = false;
  bool _useNativeToolCall2 = true;
  bool _useSafeToolCall2 = false;

  // ── Getters ───────────────────────────────────────
  LlmProvider get provider => _provider;
  String get model => _model;
  String get apiKey => _apiKey;
  String get baseUrl => _baseUrl;
  double get temperature => _temperature;
  int get maxTokens => _maxTokens;

  /// Maximum characters returned from a single tool call (0 = unlimited).
  int get maxToolOutputSize => _maxToolOutputSize;

  /// Show context-cleanup suggestion after this many tokens in the conversation.
  int get tokenWarningThreshold => _tokenWarningThreshold;

  /// Whether LLM 1 is a Small Language Model (use shorter/simpler system prompts).
  bool get isSlm => _isSlm;

  /// Whether LLM 1 is a Multi-Modal model.
  bool get isMultiModal => _isMultiModal;

  int? get topK => _topK;
  double? get topP => _topP;
  double? get repeatPenalty => _repeatPenalty;
  int? get seed => _seed;

  /// Whether the model is allowed to produce thinking/reasoning output.
  /// Default false — thinking is suppressed.
  bool get thinking => _thinking;

  /// Whether Ollama should use native tool call capabilities or text tools.
  bool get useNativeToolCall => _useNativeToolCall;

  /// Whether Ollama should use grammar-constrained decoding ("safe mode").
  bool get useSafeToolCall => _useSafeToolCall;

  /// Whether LLM should automatically recover from tool parameter validation errors.
  bool get enableToolParameterAutoRecovery => _enableToolParameterAutoRecovery;

  /// Whether LLM 2 is a Small Language Model.
  bool get isSlm2 => _isSlm2;

  /// Whether LLM 2 is a Multi-Modal model.
  bool get isMultiModal2 => _isMultiModal2;

  int? get topK2 => _topK2;
  double? get topP2 => _topP2;
  double? get repeatPenalty2 => _repeatPenalty2;
  int? get seed2 => _seed2;

  /// Whether LLM 2 is allowed to produce thinking/reasoning output.
  bool get thinking2 => _thinking2;

  /// Whether Ollama for LLM 2 should use native tool call capabilities or text tools.
  bool get useNativeToolCall2 => _useNativeToolCall2;

  /// Whether Ollama for LLM 2 should use grammar-constrained decoding ("safe mode").
  bool get useSafeToolCall2 => _useSafeToolCall2;

  bool get isLoaded => _loaded;

  static bool detectDefaultMultiModal(LlmProvider provider, String modelName) {
    if (provider == LlmProvider.gemini ||
        provider == LlmProvider.openai ||
        provider == LlmProvider.claude ||
        provider == LlmProvider.mistral ||
        provider == LlmProvider.openaiCompatible) {
      return true;
    }
    final lower = modelName.toLowerCase();
    return lower.contains('vision') ||
        lower.contains('llava') ||
        lower.contains('minicpm') ||
        lower.contains('paligemma') ||
        lower.contains('bakllava');
  }

  String getApiKeyForProvider(LlmProvider provider) {
    if (provider == _provider) return _apiKey;
    final key = _apiKeysByProvider[provider.configKey];
    return key ?? '';
  }

  String getBaseUrlForProvider(LlmProvider provider) {
    if (provider == _provider) return _baseUrl;
    final url = _baseUrlsByProvider[provider.configKey];
    if (url != null && url.isNotEmpty) return url;
    return provider == LlmProvider.mistral ? 'https://api.mistral.ai/v1' : '';
  }

  /// True when the minimum viable config is present (provider + model + credentials).
  bool get isConfigured {
    if (_provider == LlmProvider.none || _model.isEmpty) return false;
    // Embedded provider only needs a model filename (no API key or base URL).
    if (_provider == LlmProvider.embedded) return true;
    // Ollama doesn't require an API key
    if (_provider == LlmProvider.ollama ||
        _provider == LlmProvider.openaiCompatible) {
      return _baseUrl.isNotEmpty;
    }
    return _apiKey.isNotEmpty;
  }

  // ── LLM 2 getters ─────────────────────────────────
  LlmProvider get provider2 => _provider2;
  String get model2 => _model2;
  String get apiKey2 => _apiKey2;
  String get baseUrl2 => _baseUrl2;
  double get temperature2 => _temperature2;
  int get maxTokens2 => _maxTokens2;
  int get maxToolOutputSize2 => _maxToolOutputSize2;
  int get tokenWarningThreshold2 => _tokenWarningThreshold2;

  bool get isConfigured2 {
    if (_provider2 == LlmProvider.none || _model2.isEmpty) return false;
    if (_provider2 == LlmProvider.ollama ||
        _provider2 == LlmProvider.openaiCompatible) {
      return _baseUrl2.isNotEmpty;
    }
    return _apiKey2.isNotEmpty;
  }

  final Map<String, String> _apiKeysByProvider = <String, String>{};
  final Map<String, String> _baseUrlsByProvider = <String, String>{};
  final Map<String, String> _modelsByProvider = <String, String>{};

  String _providerApiKeyStorageKey(LlmProvider provider) =>
      '${_kApiKey}_${provider.configKey}';

  String _providerBaseUrlStorageKey(LlmProvider provider) =>
      '${_kBaseUrl}_${provider.configKey}';

  String _providerModelStorageKey(LlmProvider provider) =>
      '${_kModel}_${provider.configKey}';

  String getModelForProvider(LlmProvider provider) {
    if (provider == _provider) return _model;
    final model = _modelsByProvider[provider.configKey];
    if (model != null && model.isNotEmpty) return model;

    final suggestions = defaultModels[provider] ?? const <String>[];
    if (suggestions.isNotEmpty) return suggestions.first;
    return '';
  }

  Future<void> _loadProviderScopedSecrets() async {
    _apiKeysByProvider.clear();
    _baseUrlsByProvider.clear();
    _modelsByProvider.clear();
    for (final provider in LlmProvider.values) {
      if (provider == LlmProvider.none) continue;
      final providerApiKey = await _storage.read(
        key: _providerApiKeyStorageKey(provider),
      );
      if (providerApiKey != null && providerApiKey.isNotEmpty) {
        _apiKeysByProvider[provider.configKey] = providerApiKey;
      }

      final providerBaseUrl = await _storage.read(
        key: _providerBaseUrlStorageKey(provider),
      );
      if (providerBaseUrl != null && providerBaseUrl.isNotEmpty) {
        _baseUrlsByProvider[provider.configKey] = providerBaseUrl;
      }

      final providerModel = await _storage.read(
        key: _providerModelStorageKey(provider),
      );
      if (providerModel != null && providerModel.isNotEmpty) {
        _modelsByProvider[provider.configKey] = providerModel;
      }
    }
  }

  /// Apply server-backed LLM settings to the in-memory model only.
  ///
  /// This is used in remote/server mode so the app reflects the authoritative
  /// server configuration without writing into local secure storage.
  void applyRemoteState(Map<String, dynamic> remote) {
    final resolvedProvider = LlmProvider.fromConfigKey(
      remote['provider'] as String?,
    );
    final resolvedModel = (remote['model'] as String?) ?? '';
    final resolvedApiKey = (remote['api_key'] as String?) ?? '';
    final resolvedBaseUrl = (remote['base_url'] as String?) ?? '';

    _provider = resolvedProvider;
    _model = resolvedModel;
    _apiKey = resolvedApiKey;
    _baseUrl = resolvedBaseUrl;
    _temperature = (remote['temperature'] as num?)?.toDouble() ?? 0.2;
    _maxTokens = (remote['max_tokens'] as int?) ?? 0;
    _maxToolOutputSize =
        (remote['max_tool_output_size'] as int?) ?? _maxToolOutputSize;
    _tokenWarningThreshold =
        (remote['token_warning_threshold'] as int?) ?? _tokenWarningThreshold;
    _isSlm = remote['is_slm'] as bool? ?? false;
    _isMultiModal = remote['is_multi_modal'] as bool? ?? true;
    _thinking = remote['thinking'] as bool? ?? false;
    _useNativeToolCall = remote['use_native_tool_call'] as bool? ?? true;
    _useSafeToolCall = remote['use_safe_tool_call'] as bool? ?? false;
    _enableToolParameterAutoRecovery = remote['enable_tool_parameter_auto_recovery'] as bool? ?? true;
    _topK = (remote['top_k'] as int?) ?? _topK;
    _topP = (remote['top_p'] as num?)?.toDouble() ?? _topP;
    _repeatPenalty =
        (remote['repeat_penalty'] as num?)?.toDouble() ?? _repeatPenalty;
    _seed = (remote['seed'] as int?) ?? _seed;

    if (resolvedProvider != LlmProvider.none) {
      _modelsByProvider[resolvedProvider.configKey] = resolvedModel;
      _apiKeysByProvider[resolvedProvider.configKey] = resolvedApiKey;
      _baseUrlsByProvider[resolvedProvider.configKey] = resolvedBaseUrl;
    }

    _provider2 = LlmProvider.fromConfigKey(remote['provider2'] as String?);
    _model2 = (remote['model2'] as String?) ?? '';
    _apiKey2 = (remote['api_key2'] as String?) ?? '';
    _baseUrl2 = (remote['base_url2'] as String?) ?? '';
    _temperature2 = (remote['temperature2'] as num?)?.toDouble() ?? 0.2;
    _maxTokens2 = (remote['max_tokens2'] as int?) ?? 0;
    _maxToolOutputSize2 =
        (remote['max_tool_output_size2'] as int?) ?? _maxToolOutputSize2;
    _tokenWarningThreshold2 =
        (remote['token_warning_threshold2'] as int?) ?? _tokenWarningThreshold2;
    _isSlm2 = remote['is_slm2'] as bool? ?? false;
    _isMultiModal2 = remote['is_multi_modal2'] as bool? ?? true;
    _thinking2 = remote['thinking2'] as bool? ?? false;
    _useNativeToolCall2 = remote['use_native_tool_call2'] as bool? ?? true;
    _useSafeToolCall2 = remote['use_safe_tool_call2'] as bool? ?? false;
    _topK2 = (remote['top_k2'] as int?) ?? _topK2;
    _topP2 = (remote['top_p2'] as num?)?.toDouble() ?? _topP2;
    _repeatPenalty2 =
        (remote['repeat_penalty2'] as num?)?.toDouble() ?? _repeatPenalty2;
    _seed2 = (remote['seed2'] as int?) ?? _seed2;

    _loaded = true;
    notifyListeners();
  }

  // ── Load from secure storage ──────────────────
  Future<void> load() async {
    // On Linux, probe keyring availability once and bypass secure storage if locked.
    if (Platform.isLinux && !_keyringUnavailable) {
      try {
        await _storage.read(key: 'ping');
      } catch (_) {
        _keyringUnavailable = true;
        log.warning(
          '[LLM Settings] Keyring unavailable on Linux — using shadow prefs exclusively',
        );
      }
    }
    if (_keyringUnavailable) {
      await _loadFromShadowPrefs();
      _loaded = true;
      notifyListeners();
      return;
    }
    try {
      // Step 1: one-time migration from plaintext SharedPreferences into legacy storage
      await _migrateFromSharedPreferences();

      _provider = LlmProvider.fromConfigKey(
        await _storage.read(key: _kProvider),
      );
      _model = await _storage.read(key: _kModel) ?? '';
      await _loadProviderScopedSecrets();
      final providerModel = _modelsByProvider[_provider.configKey];
      if (_model.isEmpty && providerModel != null && providerModel.isNotEmpty) {
        _model = providerModel;
      }
      _apiKey = getApiKeyForProvider(_provider);
      _baseUrl = getBaseUrlForProvider(_provider);
      if (_apiKey.isEmpty) {
        _apiKey = await _storage.read(key: _kApiKey) ?? '';
      }
      if (_baseUrl.isEmpty) {
        _baseUrl = await _storage.read(key: _kBaseUrl) ?? '';
      }
      _temperature =
          double.tryParse(await _storage.read(key: _kTemperature) ?? '') ?? 0.2;
      _maxTokens =
          int.tryParse(await _storage.read(key: _kMaxTokens) ?? '') ?? 0;
      _maxToolOutputSize =
          int.tryParse(await _storage.read(key: _kMaxToolOutputSize) ?? '') ??
          2560000;
      _tokenWarningThreshold =
          int.tryParse(
            await _storage.read(key: _kTokenWarningThreshold) ?? '',
          ) ??
          1500000;
      _isSlm = (await _storage.read(key: _kIsSlm)) == 'true';
      _isMultiModal = (await _storage.read(key: _kIsMultiModal)) != 'false';
      _useNativeToolCall =
          (await _storage.read(key: _kUseNativeToolCall)) != 'false';
      _useSafeToolCall =
          (await _storage.read(key: _kUseSafeToolCall)) == 'true';
      _enableToolParameterAutoRecovery =
          (await _storage.read(key: _kEnableToolParameterAutoRecovery)) != 'false';
      final topKRaw = await _storage.read(key: _kTopK);
      _topK = topKRaw != null ? int.tryParse(topKRaw) : null;
      final topPRaw = await _storage.read(key: _kTopP);
      _topP = topPRaw != null ? double.tryParse(topPRaw) : null;
      final rpRaw = await _storage.read(key: _kRepeatPenalty);
      _repeatPenalty = rpRaw != null ? double.tryParse(rpRaw) : null;
      final seedRaw = await _storage.read(key: _kSeed);
      _seed = seedRaw != null ? int.tryParse(seedRaw) : null;
      _thinking = (await _storage.read(key: _kThinking)) == 'true';

      // Load LLM 2 settings (non-critical — ignore if absent)
      try {
        _provider2 = LlmProvider.fromConfigKey(
          await _storage.read(key: _kProvider2),
        );
        _model2 = await _storage.read(key: _kModel2) ?? '';
        _apiKey2 = await _storage.read(key: _kApiKey2) ?? '';
        _baseUrl2 = await _storage.read(key: _kBaseUrl2) ?? '';
        if (_provider2 == LlmProvider.mistral && _baseUrl2.isEmpty) {
          _baseUrl2 = 'https://api.mistral.ai/v1';
        }
        _temperature2 =
            double.tryParse(await _storage.read(key: _kTemperature2) ?? '') ??
            0.2;
        _maxTokens2 =
            int.tryParse(await _storage.read(key: _kMaxTokens2) ?? '') ?? 0;
        _maxToolOutputSize2 =
            int.tryParse(
              await _storage.read(key: _kMaxToolOutputSize2) ?? '',
            ) ??
            2560000;
        _tokenWarningThreshold2 =
            int.tryParse(
              await _storage.read(key: _kTokenWarningThreshold2) ?? '',
            ) ??
            1500000;
        _isSlm2 = (await _storage.read(key: _kIsSlm2)) == 'true';
        _isMultiModal2 = (await _storage.read(key: _kIsMultiModal2)) != 'false';
        final topK2Raw = await _storage.read(key: _kTopK2);
        _topK2 = topK2Raw != null ? int.tryParse(topK2Raw) : null;
        final topP2Raw = await _storage.read(key: _kTopP2);
        _topP2 = topP2Raw != null ? double.tryParse(topP2Raw) : null;
        final rp2Raw = await _storage.read(key: _kRepeatPenalty2);
        _repeatPenalty2 = rp2Raw != null ? double.tryParse(rp2Raw) : null;
        final seed2Raw = await _storage.read(key: _kSeed2);
        _seed2 = seed2Raw != null ? int.tryParse(seed2Raw) : null;
        _thinking2 = (await _storage.read(key: _kThinking2)) == 'true';
        _useNativeToolCall2 =
            (await _storage.read(key: _kUseNativeToolCall2)) != 'false';
        _useSafeToolCall2 =
            (await _storage.read(key: _kUseSafeToolCall2)) == 'true';
      } catch (_) {}

      // Fallback: if LLM2 failed to load from secure storage (e.g. the background
      // isolate's cipher hasn't been initialised yet), recover from shadow prefs so
      // background heartbeat tasks that use LLM2 are not wrongly rejected as
      // "LLM not configured".
      if (_provider2 == LlmProvider.none) {
        await _loadLlm2FromShadowPrefs();
      }

      final requiresApiKey =
          _provider != LlmProvider.none &&
          _provider != LlmProvider.ollama &&
          _provider != LlmProvider.openaiCompatible &&
          _provider != LlmProvider.embedded;
      final requiresBaseUrl =
          _provider == LlmProvider.ollama ||
          _provider == LlmProvider.openaiCompatible ||
          _provider == LlmProvider.mistral;

      if (_provider == LlmProvider.none ||
          (requiresApiKey && _apiKey.isEmpty) ||
          (requiresBaseUrl && _baseUrl.isEmpty)) {
        // SecureStorage returned nothing useful — try SharedPreferences shadow copy.
        // This happens on the first WorkManager background isolate run before the
        // flutter_secure_storage custom-cipher migration has been triggered in foreground.
        await _loadFromShadowPrefs();
      } else {
        // Write/refresh the SharedPreferences shadow so the background fallback stays current.
        // Awaited for the same reason as in save(): guarantee the shadow is on-disk before
        // load() returns, so any background isolate starting immediately after sees fresh data.
        await _writeShadowPrefs();
      }

      _loaded = true;
      log.info(
        '[LLM Settings] Loaded – provider=${_provider.configKey}, model=$_model (shadow=${_provider != LlmProvider.none})',
      );
      notifyListeners();
    } catch (e) {
      log.error('[LLM Settings] Failed to load: $e');
      // On Linux the keyring may be locked — storage.read() throws instead of
      // returning null. Fall back to the SharedPreferences shadow copy so the
      // app still shows the configured state.
      if (Platform.isLinux) {
        try {
          await _loadFromShadowPrefs();
          log.info(
            '[LLM Settings] Recovered from keyring error via shadow prefs – provider=${_provider.configKey}',
          );
        } catch (e2) {
          log.warning('[LLM Settings] Shadow fallback also failed: $e2');
        }
      }
      _loaded = true;
      notifyListeners();
    }
  }

  /// Write a shadow copy to SharedPreferences for reliable background access.
  Future<void> _writeShadowPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('${_kShadowPrefix}provider', _provider.configKey);
      await prefs.setString('${_kShadowPrefix}model', _model);
      await prefs.setString('${_kShadowPrefix}apiKey', _apiKey);
      await prefs.setString('${_kShadowPrefix}baseUrl', _baseUrl);
      await prefs.setDouble('${_kShadowPrefix}temperature', _temperature);
      await prefs.setInt('${_kShadowPrefix}maxTokens', _maxTokens);
      await prefs.setInt(
        '${_kShadowPrefix}maxToolOutputSize',
        _maxToolOutputSize,
      );
      await prefs.setInt(
        '${_kShadowPrefix}tokenWarningThreshold',
        _tokenWarningThreshold,
      );
      // LLM 2 shadow — only write when provider2 is configured so that a
      // background isolate which failed to read LLM2 from secure storage doesn't
      // overwrite a previously valid shadow entry with 'none'.
      await prefs.setBool('${_kShadowPrefix}isSlm', _isSlm);
      await prefs.setBool('${_kShadowPrefix}isMultiModal', _isMultiModal);
      await prefs.setBool('${_kShadowPrefix}thinking', _thinking);
      await prefs.setBool(
        '${_kShadowPrefix}useNativeToolCall',
        _useNativeToolCall,
      );
      if (_provider2 != LlmProvider.none) {
        await prefs.setString(
          '${_kShadowPrefix}provider2',
          _provider2.configKey,
        );
        await prefs.setString('${_kShadowPrefix}model2', _model2);
        await prefs.setString('${_kShadowPrefix}apiKey2', _apiKey2);
        await prefs.setString('${_kShadowPrefix}baseUrl2', _baseUrl2);
        await prefs.setDouble('${_kShadowPrefix}temperature2', _temperature2);
        await prefs.setInt('${_kShadowPrefix}maxTokens2', _maxTokens2);
        await prefs.setInt(
          '${_kShadowPrefix}maxToolOutputSize2',
          _maxToolOutputSize2,
        );
        await prefs.setInt(
          '${_kShadowPrefix}tokenWarningThreshold2',
          _tokenWarningThreshold2,
        );
        await prefs.setBool('${_kShadowPrefix}isSlm2', _isSlm2);
        await prefs.setBool('${_kShadowPrefix}isMultiModal2', _isMultiModal2);
        await prefs.setBool(
          '${_kShadowPrefix}useNativeToolCall2',
          _useNativeToolCall2,
        );
        await prefs.setBool(
          '${_kShadowPrefix}useSafeToolCall2',
          _useSafeToolCall2,
        );
      }
      await prefs.setBool('${_kShadowPrefix}isSlm', _isSlm);
      await prefs.setBool('${_kShadowPrefix}thinking', _thinking);
      await prefs.setBool(
        '${_kShadowPrefix}useNativeToolCall',
        _useNativeToolCall,
      );
      await prefs.setBool('${_kShadowPrefix}useSafeToolCall', _useSafeToolCall);
      await prefs.setBool('${_kShadowPrefix}enableToolParameterAutoRecovery', _enableToolParameterAutoRecovery);
      if (_provider2 != LlmProvider.none) {
        await prefs.setBool('${_kShadowPrefix}thinking2', _thinking2);
        await prefs.setBool(
          '${_kShadowPrefix}useNativeToolCall2',
          _useNativeToolCall2,
        );
        await prefs.setBool(
          '${_kShadowPrefix}useSafeToolCall2',
          _useSafeToolCall2,
        );
      }
    } catch (e) {
      log.warning('[LLM Settings] Shadow write failed (non-fatal): $e');
    }
  }

  /// Read settings from SharedPreferences shadow copy (background fallback).
  Future<void> _loadFromShadowPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final p = prefs.getString('${_kShadowPrefix}provider') ?? '';
      if (p.isEmpty || p == 'none') {
        return; // shadow is also empty — no config yet
      }
      _provider = LlmProvider.fromConfigKey(p);
      _model = prefs.getString('${_kShadowPrefix}model') ?? _model;
      _apiKey = prefs.getString('${_kShadowPrefix}apiKey') ?? _apiKey;
      _baseUrl = prefs.getString('${_kShadowPrefix}baseUrl') ?? _baseUrl;
      _temperature =
          prefs.getDouble('${_kShadowPrefix}temperature') ?? _temperature;
      _maxTokens = prefs.getInt('${_kShadowPrefix}maxTokens') ?? _maxTokens;
      _maxToolOutputSize =
          prefs.getInt('${_kShadowPrefix}maxToolOutputSize') ??
          _maxToolOutputSize;
      _tokenWarningThreshold =
          prefs.getInt('${_kShadowPrefix}tokenWarningThreshold') ??
          _tokenWarningThreshold;
      _isSlm = prefs.getBool('${_kShadowPrefix}isSlm') ?? _isSlm;
      _isMultiModal =
          prefs.getBool('${_kShadowPrefix}isMultiModal') ?? _isMultiModal;
      _thinking = prefs.getBool('${_kShadowPrefix}thinking') ?? _thinking;
      _useNativeToolCall =
          prefs.getBool('${_kShadowPrefix}useNativeToolCall') ??
          _useNativeToolCall;
      _useSafeToolCall =
          prefs.getBool('${_kShadowPrefix}useSafeToolCall') ?? _useSafeToolCall;
      _enableToolParameterAutoRecovery =
          prefs.getBool('${_kShadowPrefix}enableToolParameterAutoRecovery') ?? _enableToolParameterAutoRecovery;
      if (_apiKey.isNotEmpty) {
        _apiKeysByProvider[_provider.configKey] = _apiKey;
      }
      if (_baseUrl.isNotEmpty) {
        _baseUrlsByProvider[_provider.configKey] = _baseUrl;
      }
      if (_model.isNotEmpty) {
        _modelsByProvider[_provider.configKey] = _model;
      }
      if (_provider == LlmProvider.mistral && _baseUrl.isEmpty) {
        _baseUrl = 'https://api.mistral.ai/v1';
      }
      // LLM 2 shadow
      final p2 = prefs.getString('${_kShadowPrefix}provider2') ?? '';
      if (p2.isNotEmpty && p2 != 'none') {
        _provider2 = LlmProvider.fromConfigKey(p2);
        _model2 = prefs.getString('${_kShadowPrefix}model2') ?? _model2;
        _apiKey2 = prefs.getString('${_kShadowPrefix}apiKey2') ?? _apiKey2;
        _baseUrl2 = prefs.getString('${_kShadowPrefix}baseUrl2') ?? _baseUrl2;
        _temperature2 =
            prefs.getDouble('${_kShadowPrefix}temperature2') ?? _temperature2;
        _maxTokens2 =
            prefs.getInt('${_kShadowPrefix}maxTokens2') ?? _maxTokens2;
        _maxToolOutputSize2 =
            prefs.getInt('${_kShadowPrefix}maxToolOutputSize2') ??
            _maxToolOutputSize2;
        _tokenWarningThreshold2 =
            prefs.getInt('${_kShadowPrefix}tokenWarningThreshold2') ??
            _tokenWarningThreshold2;
        _isSlm2 = prefs.getBool('${_kShadowPrefix}isSlm2') ?? _isSlm2;
        _isMultiModal2 =
            prefs.getBool('${_kShadowPrefix}isMultiModal2') ?? _isMultiModal2;
        _thinking2 = prefs.getBool('${_kShadowPrefix}thinking2') ?? _thinking2;
        _useNativeToolCall2 =
            prefs.getBool('${_kShadowPrefix}useNativeToolCall2') ??
            _useNativeToolCall2;
        _useSafeToolCall2 =
            prefs.getBool('${_kShadowPrefix}useSafeToolCall2') ??
            _useSafeToolCall2;
        if (_provider2 == LlmProvider.mistral && _baseUrl2.isEmpty) {
          _baseUrl2 = 'https://api.mistral.ai/v1';
        }
      }
      log.info(
        '[LLM Settings] Loaded from SharedPreferences shadow – provider=${_provider.configKey}',
      );
    } catch (e) {
      log.warning('[LLM Settings] Shadow read failed (non-fatal): $e');
    }
  }

  /// Loads only LLM2 settings from the SharedPreferences shadow copy.
  /// Called after a silent LLM2 secure-storage failure (common in background
  /// isolates where the custom cipher hasn't been initialised yet for LLM2 keys).
  Future<void> _loadLlm2FromShadowPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final p2 = prefs.getString('${_kShadowPrefix}provider2') ?? '';
      if (p2.isEmpty || p2 == 'none') return;
      _provider2 = LlmProvider.fromConfigKey(p2);
      _model2 = prefs.getString('${_kShadowPrefix}model2') ?? _model2;
      _apiKey2 = prefs.getString('${_kShadowPrefix}apiKey2') ?? _apiKey2;
      _baseUrl2 = prefs.getString('${_kShadowPrefix}baseUrl2') ?? _baseUrl2;
      _temperature2 =
          prefs.getDouble('${_kShadowPrefix}temperature2') ?? _temperature2;
      _maxTokens2 = prefs.getInt('${_kShadowPrefix}maxTokens2') ?? _maxTokens2;
      _maxToolOutputSize2 =
          prefs.getInt('${_kShadowPrefix}maxToolOutputSize2') ??
          _maxToolOutputSize2;
      _tokenWarningThreshold2 =
          prefs.getInt('${_kShadowPrefix}tokenWarningThreshold2') ??
          _tokenWarningThreshold2;
      _isSlm2 = prefs.getBool('${_kShadowPrefix}isSlm2') ?? _isSlm2;
      _isMultiModal2 =
          prefs.getBool('${_kShadowPrefix}isMultiModal2') ?? _isMultiModal2;
      _useNativeToolCall2 =
          prefs.getBool('${_kShadowPrefix}useNativeToolCall2') ??
          _useNativeToolCall2;
      _useSafeToolCall2 =
          prefs.getBool('${_kShadowPrefix}useSafeToolCall2') ??
          _useSafeToolCall2;
      if (_provider2 == LlmProvider.mistral && _baseUrl2.isEmpty) {
        _baseUrl2 = 'https://api.mistral.ai/v1';
      }
      log.info(
        '[LLM Settings] LLM2 recovered from shadow – provider2=${_provider2.configKey}',
      );
    } catch (e) {
      log.warning('[LLM Settings] LLM2 shadow read failed (non-fatal): $e');
    }
  }

  /// Migrate existing plaintext SharedPreferences to secure storage (one-time).
  Future<void> _migrateFromSharedPreferences() async {
    try {
      final migrated = await _storage.read(key: _kMigrated);
      if (migrated == 'true') return; // already migrated

      final prefs = await SharedPreferences.getInstance();
      final oldProvider = prefs.getString(_kProvider);
      if (oldProvider == null || oldProvider.isEmpty) {
        // Nothing to migrate
        await _storage.write(key: _kMigrated, value: 'true');
        return;
      }

      log.info(
        '[LLM Settings] Migrating from SharedPreferences to secure storage...',
      );
      await _storage.write(key: _kProvider, value: oldProvider);
      final oldModel = prefs.getString(_kModel);
      if (oldModel != null) await _storage.write(key: _kModel, value: oldModel);
      final oldKey = prefs.getString(_kApiKey);
      if (oldKey != null) await _storage.write(key: _kApiKey, value: oldKey);
      final oldUrl = prefs.getString(_kBaseUrl);
      if (oldUrl != null) await _storage.write(key: _kBaseUrl, value: oldUrl);
      final oldTemp = prefs.getDouble(_kTemperature);
      if (oldTemp != null) {
        await _storage.write(key: _kTemperature, value: oldTemp.toString());
      }
      final oldTokens = prefs.getInt(_kMaxTokens);
      if (oldTokens != null) {
        await _storage.write(key: _kMaxTokens, value: oldTokens.toString());
      }

      // Clean up plaintext keys
      await prefs.remove(_kProvider);
      await prefs.remove(_kModel);
      await prefs.remove(_kApiKey);
      await prefs.remove(_kBaseUrl);
      await prefs.remove(_kTemperature);
      await prefs.remove(_kMaxTokens);

      await _storage.write(key: _kMigrated, value: 'true');
      log.info('[LLM Settings] Migration complete');
    } catch (e) {
      log.error('[LLM Settings] Migration failed (non-fatal): $e');
    }
  }

  // ── Save per-provider secrets (called from vault restore) ──────────────
  /// Persist API keys / base URLs for providers OTHER than the currently
  /// active one.  The active provider's credentials are already written by
  /// [save]; this method fills in the rest so a full vault round-trip
  /// restores every provider's stored credentials.
  ///
  /// [data] is the `perProvider` map straight from the vault payload:
  ///   `{ "gemini": { "apiKey": "...", "baseUrl": "" }, "openai": { ... } }`
  Future<void> savePerProviderSecrets(
    Map<String, Map<String, dynamic>> data,
  ) async {
    for (final entry in data.entries) {
      final provider = LlmProvider.fromConfigKey(entry.key);
      if (provider == LlmProvider.none || provider == _provider) {
        continue; // active already saved by save()
      }
      final apiKey = (entry.value['apiKey'] as String?)?.trim() ?? '';
      final baseUrl = (entry.value['baseUrl'] as String?)?.trim() ?? '';
      try {
        if (apiKey.isNotEmpty) {
          await _storage.write(
            key: _providerApiKeyStorageKey(provider),
            value: apiKey,
          );
          _apiKeysByProvider[provider.configKey] = apiKey;
        }
        if (baseUrl.isNotEmpty) {
          await _storage.write(
            key: _providerBaseUrlStorageKey(provider),
            value: baseUrl,
          );
          _baseUrlsByProvider[provider.configKey] = baseUrl;
        }
      } catch (e) {
        log.warning(
          '[LLM Settings] savePerProviderSecrets: failed for ${provider.configKey}: $e',
        );
      }
    }
  }

  // ── Save all settings ─────────────────────────────
  Future<void> save({
    required LlmProvider provider,
    required String model,
    required String apiKey,
    required String baseUrl,
    required double temperature,
    required int maxTokens,
    required int maxToolOutputSize,
    required int tokenWarningThreshold,
    bool isSlm = false,
    bool isMultiModal = true,
    int? topK,
    double? topP,
    double? repeatPenalty,
    int? seed,
    bool thinking = false,
    bool useNativeToolCall = true,
    bool useSafeToolCall = false,
    bool enableToolParameterAutoRecovery = true,
  }) async {
    _provider = provider;
    _isMultiModal = isMultiModal;
    _model = model.trim();
    _apiKey = apiKey.trim();
    _baseUrl = baseUrl.trim();
    if (_provider == LlmProvider.mistral && _baseUrl.isEmpty) {
      _baseUrl = 'https://api.mistral.ai/v1';
    }
    _temperature = temperature.clamp(0.0, 2.0);
    _maxTokens = maxTokens.clamp(0, 2000000);
    _maxToolOutputSize = maxToolOutputSize.clamp(0, 10000000);
    _tokenWarningThreshold = tokenWarningThreshold.clamp(1000, 10000000);
    _isSlm = isSlm;
    _topK = topK;
    _topP = topP;
    _repeatPenalty = repeatPenalty;
    _seed = seed;
    _thinking = thinking;
    _useNativeToolCall = useNativeToolCall;
    _useSafeToolCall = useSafeToolCall;
    _enableToolParameterAutoRecovery = enableToolParameterAutoRecovery;

    if (_keyringUnavailable) {
      await _writeShadowPrefs();
      notifyListeners();
      return;
    }
    try {
      await _storage.write(key: _kProvider, value: provider.configKey);
      await _storage.write(key: _kModel, value: _model);
      await _storage.write(
        key: _providerModelStorageKey(provider),
        value: _model,
      );
      await _storage.write(key: _kApiKey, value: _apiKey);
      await _storage.write(key: _kBaseUrl, value: _baseUrl);
      await _storage.write(
        key: _providerApiKeyStorageKey(provider),
        value: _apiKey,
      );
      await _storage.write(
        key: _providerBaseUrlStorageKey(provider),
        value: _baseUrl,
      );
      _modelsByProvider[provider.configKey] = _model;
      _apiKeysByProvider[provider.configKey] = _apiKey;
      _baseUrlsByProvider[provider.configKey] = _baseUrl;
      await _storage.write(key: _kTemperature, value: _temperature.toString());
      await _storage.write(key: _kMaxTokens, value: _maxTokens.toString());
      await _storage.write(
        key: _kMaxToolOutputSize,
        value: _maxToolOutputSize.toString(),
      );
      await _storage.write(
        key: _kTokenWarningThreshold,
        value: _tokenWarningThreshold.toString(),
      );
      await _storage.write(key: _kIsSlm, value: _isSlm.toString());
      await _storage.write(
        key: _kIsMultiModal,
        value: _isMultiModal.toString(),
      );
      if (_topK != null) {
        await _storage.write(key: _kTopK, value: _topK.toString());
      } else {
        await _storage.delete(key: _kTopK);
      }
      if (_topP != null) {
        await _storage.write(key: _kTopP, value: _topP.toString());
      } else {
        await _storage.delete(key: _kTopP);
      }
      if (_repeatPenalty != null) {
        await _storage.write(
          key: _kRepeatPenalty,
          value: _repeatPenalty.toString(),
        );
      } else {
        await _storage.delete(key: _kRepeatPenalty);
      }
      if (_seed != null) {
        await _storage.write(key: _kSeed, value: _seed.toString());
      } else {
        await _storage.delete(key: _kSeed);
      }
      await _storage.write(key: _kThinking, value: _thinking.toString());
      await _storage.write(
        key: _kUseNativeToolCall,
        value: _useNativeToolCall.toString(),
      );
      await _storage.write(
        key: _kUseSafeToolCall,
        value: _useSafeToolCall.toString(),
      );
      await _storage.write(
        key: _kEnableToolParameterAutoRecovery,
        value: _enableToolParameterAutoRecovery.toString(),
      );

      log.info(
        '[LLM Settings] Saved – provider=${provider.configKey}, model=$_model',
      );
      // Keep SharedPreferences shadow in sync for background isolate fallback.
      // Must be awaited so the shadow is guaranteed to be written before save()
      // returns — preventing a race where a background isolate fires before the
      // unawaited future completes and falls back to a stale/empty shadow.
      await _writeShadowPrefs();
      notifyListeners();
    } catch (e) {
      if (Platform.isLinux) {
        // Keyring unavailable (e.g. VNC/headless) — persist via SharedPreferences shadow.
        log.warning(
          '[LLM Settings] Keyring unavailable on Linux, using shadow prefs: $e',
        );
        await _writeShadowPrefs();
        notifyListeners();
        return;
      }
      log.error('[LLM Settings] Failed to save: $e');
      rethrow;
    }
  }

  // ── Save LLM 2 settings ───────────────────────────
  Future<void> save2({
    required LlmProvider provider,
    required String model,
    required String apiKey,
    required String baseUrl,
    required double temperature,
    required int maxTokens,
    int maxToolOutputSize2 = 2560000,
    int tokenWarningThreshold2 = 1500000,
    bool isSlm2 = false,
    bool isMultiModal2 = true,
    int? topK2,
    double? topP2,
    double? repeatPenalty2,
    int? seed2,
    bool thinking2 = false,
    bool useNativeToolCall2 = true,
    bool useSafeToolCall2 = false,
  }) async {
    _provider2 = provider;
    _isMultiModal2 = isMultiModal2;
    _model2 = model.trim();
    _apiKey2 = apiKey.trim();
    _baseUrl2 = baseUrl.trim();
    if (_provider2 == LlmProvider.mistral && _baseUrl2.isEmpty) {
      _baseUrl2 = 'https://api.mistral.ai/v1';
    }
    _temperature2 = temperature.clamp(0.0, 2.0);
    _maxTokens2 = maxTokens.clamp(0, 2000000);
    _maxToolOutputSize2 = maxToolOutputSize2.clamp(0, 100000000);
    _tokenWarningThreshold2 = tokenWarningThreshold2.clamp(1000, 100000000);
    _isSlm2 = isSlm2;
    _topK2 = topK2;
    _topP2 = topP2;
    _repeatPenalty2 = repeatPenalty2;
    _seed2 = seed2;
    _thinking2 = thinking2;
    _useNativeToolCall2 = useNativeToolCall2;
    _useSafeToolCall2 = useSafeToolCall2;
    if (_keyringUnavailable) {
      await _writeShadowPrefs();
      notifyListeners();
      return;
    }
    try {
      await _storage.write(key: _kProvider2, value: provider.configKey);
      await _storage.write(key: _kModel2, value: _model2);
      await _storage.write(key: _kApiKey2, value: _apiKey2);
      await _storage.write(key: _kBaseUrl2, value: _baseUrl2);
      await _storage.write(
        key: _kTemperature2,
        value: _temperature2.toString(),
      );
      await _storage.write(key: _kMaxTokens2, value: _maxTokens2.toString());
      await _storage.write(
        key: _kMaxToolOutputSize2,
        value: _maxToolOutputSize2.toString(),
      );
      await _storage.write(
        key: _kTokenWarningThreshold2,
        value: _tokenWarningThreshold2.toString(),
      );
      await _storage.write(key: _kIsSlm2, value: _isSlm2.toString());
      await _storage.write(
        key: _kIsMultiModal2,
        value: _isMultiModal2.toString(),
      );
      if (_topK2 != null) {
        await _storage.write(key: _kTopK2, value: _topK2.toString());
      } else {
        await _storage.delete(key: _kTopK2);
      }
      if (_topP2 != null) {
        await _storage.write(key: _kTopP2, value: _topP2.toString());
      } else {
        await _storage.delete(key: _kTopP2);
      }
      if (_repeatPenalty2 != null) {
        await _storage.write(
          key: _kRepeatPenalty2,
          value: _repeatPenalty2.toString(),
        );
      } else {
        await _storage.delete(key: _kRepeatPenalty2);
      }
      if (_seed2 != null) {
        await _storage.write(key: _kSeed2, value: _seed2.toString());
      } else {
        await _storage.delete(key: _kSeed2);
      }
      await _storage.write(key: _kThinking2, value: _thinking2.toString());
      await _storage.write(
        key: _kUseNativeToolCall2,
        value: _useNativeToolCall2.toString(),
      );
      await _storage.write(
        key: _kUseSafeToolCall2,
        value: _useSafeToolCall2.toString(),
      );
      await _writeShadowPrefs();
      log.info(
        '[LLM Settings] Saved LLM2 – provider=${provider.configKey}, model=$_model2',
      );
      notifyListeners();
    } catch (e) {
      if (Platform.isLinux) {
        log.warning(
          '[LLM Settings] Keyring unavailable on Linux, LLM2 using shadow prefs: $e',
        );
        await _writeShadowPrefs();
        notifyListeners();
        return;
      }
      log.error('[LLM Settings] Failed to save LLM2: $e');
      rethrow;
    }
  }

  /// Clear all stored settings.
  Future<void> clear() async {
    _provider = LlmProvider.none;
    _model = '';
    _apiKey = '';
    _baseUrl = '';
    _temperature = 0.2;
    _maxTokens = 0;
    _maxToolOutputSize = 2560000;
    _tokenWarningThreshold = 1500000;
    try {
      await _storage.delete(key: _kProvider);
      await _storage.delete(key: _kModel);
      await _storage.delete(key: _kApiKey);
      await _storage.delete(key: _kBaseUrl);
      for (final provider in LlmProvider.values) {
        if (provider == LlmProvider.none) continue;
        await _storage.delete(key: _providerModelStorageKey(provider));
        await _storage.delete(key: _providerApiKeyStorageKey(provider));
        await _storage.delete(key: _providerBaseUrlStorageKey(provider));
      }
      _modelsByProvider.clear();
      _apiKeysByProvider.clear();
      _baseUrlsByProvider.clear();
      await _storage.delete(key: _kTemperature);
      await _storage.delete(key: _kMaxTokens);
      await _storage.delete(key: _kMaxToolOutputSize);
      await _storage.delete(key: _kTokenWarningThreshold);
      _useNativeToolCall = true;
      _useNativeToolCall2 = true;
      _useSafeToolCall = false;
      _useSafeToolCall2 = false;
      await _storage.delete(key: _kUseNativeToolCall);
      await _storage.delete(key: _kUseNativeToolCall2);
      await _storage.delete(key: _kUseSafeToolCall);
      await _storage.delete(key: _kUseSafeToolCall2);
      // Clear shadow too.
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('${_kShadowPrefix}provider');
        await prefs.remove('${_kShadowPrefix}model');
        await prefs.remove('${_kShadowPrefix}apiKey');
        await prefs.remove('${_kShadowPrefix}baseUrl');
        await prefs.remove('${_kShadowPrefix}temperature');
        await prefs.remove('${_kShadowPrefix}maxTokens');
        await prefs.remove('${_kShadowPrefix}maxToolOutputSize');
        await prefs.remove('${_kShadowPrefix}tokenWarningThreshold');
        await prefs.remove('${_kShadowPrefix}useNativeToolCall');
        await prefs.remove('${_kShadowPrefix}useNativeToolCall2');
        await prefs.remove('${_kShadowPrefix}useSafeToolCall');
        await prefs.remove('${_kShadowPrefix}useSafeToolCall2');
      } catch (_) {}
      log.info('[LLM Settings] Cleared');
    } catch (e) {
      log.error('[LLM Settings] Failed to clear: $e');
    }
    notifyListeners();
  }
}
