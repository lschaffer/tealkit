import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/server_config_service.dart';
import '../utils/server_logger.dart';

// ═══════════════════════════════════════════════════════════════
// LLM Provider enum
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

// ═══════════════════════════════════════════════════════════════
// Token pricing
// ═══════════════════════════════════════════════════════════════

class ModelTokenPrice {
  final double inputPer1MUsd;
  final double outputPer1MUsd;
  final int? contextWindow;

  const ModelTokenPrice({
    required this.inputPer1MUsd,
    required this.outputPer1MUsd,
    this.contextWindow,
  });

  String get formattedContextWindow {
    if (contextWindow == null || contextWindow! <= 0) return '';
    if (contextWindow! >= 1000000) {
      final m = (contextWindow! / 1000000).toStringAsFixed(1).replaceAll(RegExp(r'\.0$'), '');
      return '${m}M ctx';
    }
    final k = (contextWindow! / 1000).round();
    return '${k}k ctx';
  }
}

class _CachedModelPrice {
  final ModelTokenPrice price;
  final DateTime fetchedAt;

  const _CachedModelPrice({required this.price, required this.fetchedAt});
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
    'mistral-medium-latest': ModelTokenPrice(
      inputPer1MUsd: 0.40,
      outputPer1MUsd: 2.00,
    ),
    'mistral-medium': ModelTokenPrice(
      inputPer1MUsd: 0.40,
      outputPer1MUsd: 2.00,
    ),
    'mistral-small-latest': ModelTokenPrice(
      inputPer1MUsd: 0.10,
      outputPer1MUsd: 0.30,
    ),
    'mistral-small': ModelTokenPrice(inputPer1MUsd: 0.10, outputPer1MUsd: 0.30),
  },
};

String _normalizeModel(String m) => m.trim().toLowerCase();

String _priceCacheKey({required String providerKey, required String model}) =>
    '${providerKey.trim().toLowerCase()}:${_normalizeModel(model)}';

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

void _cacheLivePrice({
  required String providerKey,
  required String model,
  required ModelTokenPrice price,
}) {
  final now = DateTime.now();
  final directKey = _priceCacheKey(providerKey: providerKey, model: model);
  _liveModelPricingCache[directKey] = _CachedModelPrice(
    price: price,
    fetchedAt: now,
  );

  final normalizedModel = _normalizeModel(model);
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
    );
  } else {
    final aliasKey = _priceCacheKey(
      providerKey: providerKey,
      model: '$normalizedModel-latest',
    );
    _liveModelPricingCache[aliasKey] = _CachedModelPrice(
      price: price,
      fetchedAt: now,
    );
  }
}

double? _parseDouble(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString());
}

double _toPer1M(double value) {
  // OpenRouter pricing fields are typically USD/token.
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

    final contextLength = (raw['context_length'] as num?)?.toInt();
    final candidate = ModelTokenPrice(
      inputPer1MUsd: _toPer1M(promptRaw),
      outputPer1MUsd: _toPer1M(completionRaw),
      contextWindow: contextLength,
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
  return ModelTokenPrice(inputPer1MUsd: input, outputPer1MUsd: output, contextWindow: 128000);
}

Future<ModelTokenPrice?> refreshModelTokenPrice({
  required String providerKey,
  required String model,
}) async {
  final normalizedProvider = providerKey.trim().toLowerCase();
  final normalizedModel = _normalizeModel(model);
  if (normalizedModel.isEmpty) return null;

  final shortModel = normalizedModel.contains('/')
      ? normalizedModel.split('/').last
      : normalizedModel;

  try {
    ModelTokenPrice? fetched;
    if (normalizedProvider != 'ollama' && normalizedProvider != 'embedded') {
      fetched = await _fetchOpenRouterLivePrice(
        providerKey: normalizedProvider,
        normalizedModel: normalizedModel,
      );
      fetched ??= await _fetchOpenRouterLivePrice(
        providerKey: normalizedProvider,
        normalizedModel: shortModel,
      );
    }
    if (fetched == null && normalizedProvider == 'mistral') {
      fetched = await _fetchMistralLivePrice(normalizedModel) ??
          await _fetchMistralLivePrice(shortModel);
    }
    if (fetched != null) {
      _cacheLivePrice(
        providerKey: normalizedProvider,
        model: normalizedModel,
        price: fetched,
      );
      if (shortModel != normalizedModel) {
        _cacheLivePrice(
          providerKey: normalizedProvider,
          model: shortModel,
          price: fetched,
        );
      }
      return fetched;
    }
  } catch (e) {
    log.warning(
      '[Server LLM Pricing] Live refresh failed for $normalizedProvider/$normalizedModel: $e',
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
  final np = providerKey.trim().toLowerCase();
  final nm = _normalizeModel(model);
  if (nm.isEmpty) return null;

  var cachedLive = _getCachedLivePrice(providerKey: np, model: nm);
  if (cachedLive != null) return cachedLive.price;

  final shortModel = nm.contains('/') ? nm.split('/').last : nm;
  if (shortModel != nm) {
    cachedLive = _getCachedLivePrice(providerKey: np, model: shortModel);
    if (cachedLive != null) return cachedLive.price;
  }

  for (final entry in _liveModelPricingCache.entries) {
    final keyParts = entry.key.split(':');
    if (keyParts.length == 2) {
      final cachedModel = keyParts[1];
      final cachedShort = cachedModel.contains('/')
          ? cachedModel.split('/').last
          : cachedModel;
      if (cachedModel == nm ||
          cachedShort == shortModel ||
          cachedModel.endsWith('/$shortModel') ||
          shortModel.endsWith('/$cachedModel')) {
        if (DateTime.now().difference(entry.value.fetchedAt) <= _livePriceTtl) {
          return entry.value.price;
        }
      }
    }
  }

  final map = _modelPricingByProvider[np];
  if (map != null) {
    final direct = map[nm] ?? map[shortModel];
    if (direct != null) return direct;
  }

  final baseName = shortModel.endsWith('-latest')
      ? shortModel.substring(0, shortModel.length - '-latest'.length)
      : shortModel;

  for (final providerMap in _modelPricingByProvider.values) {
    final found = providerMap[baseName] ??
        providerMap['$baseName-latest'] ??
        providerMap[nm] ??
        providerMap[shortModel];
    if (found != null) return found;
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
  return (promptTokens / 1000000) * price.inputPer1MUsd +
      (completionTokens / 1000000) * price.outputPer1MUsd;
}

// ═══════════════════════════════════════════════════════════════
// Server LLM Settings Service — plain class, no ChangeNotifier
// ═══════════════════════════════════════════════════════════════

class ServerLlmSettingsService {
  static final ServerLlmSettingsService instance = ServerLlmSettingsService._();
  ServerLlmSettingsService._();

  // ── Storage keys ──────────────────────────────────
  static const _kProvider = 'llm_provider';
  static const _kModel = 'llm_model';
  static const _kApiKey = 'llm_api_key';
  static const _kBaseUrl = 'llm_base_url';
  static const _kTemperature = 'llm_temperature';
  static const _kMaxTokens = 'llm_max_tokens';
  static const _kMaxToolOutputSize = 'llm_max_tool_output_size';
  static const _kTokenWarningThreshold = 'llm_token_warning_threshold';
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
  static const _kInjectToolCallingRules = 'llm_inject_tool_calling_rules';

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
  bool _injectToolCallingRules = true;

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

  // Per-provider stored values
  final Map<String, String> _apiKeysByProvider = {};
  final Map<String, String> _baseUrlsByProvider = {};
  final Map<String, String> _modelsByProvider = {};

  // ── Getters ───────────────────────────────────────
  LlmProvider get provider => _provider;
  String get model => _model;
  String get apiKey => _apiKey;
  String get baseUrl => _baseUrl;
  double get temperature => _temperature;
  int get maxTokens => _maxTokens;
  int get maxToolOutputSize => _maxToolOutputSize;
  int get tokenWarningThreshold => _tokenWarningThreshold;
  bool get isSlm => _isSlm;
  bool get isMultiModal => _isMultiModal;
  int? get topK => _topK;
  double? get topP => _topP;
  double? get repeatPenalty => _repeatPenalty;
  int? get seed => _seed;
  bool get thinking => _thinking;
  bool get useNativeToolCall => _useNativeToolCall;
  bool get useSafeToolCall => _useSafeToolCall;
  bool get enableToolParameterAutoRecovery => _enableToolParameterAutoRecovery;
  bool get injectToolCallingRules => _injectToolCallingRules;

  LlmProvider get provider2 => _provider2;
  String get model2 => _model2;
  String get apiKey2 => _apiKey2;
  String get baseUrl2 => _baseUrl2;
  double get temperature2 => _temperature2;
  int get maxTokens2 => _maxTokens2;
  int get maxToolOutputSize2 => _maxToolOutputSize2;
  int get tokenWarningThreshold2 => _tokenWarningThreshold2;
  bool get isSlm2 => _isSlm2;
  bool get isMultiModal2 => _isMultiModal2;
  int? get topK2 => _topK2;
  double? get topP2 => _topP2;
  double? get repeatPenalty2 => _repeatPenalty2;
  int? get seed2 => _seed2;
  bool get thinking2 => _thinking2;
  bool get useNativeToolCall2 => _useNativeToolCall2;
  bool get useSafeToolCall2 => _useSafeToolCall2;

  bool get isConfigured {
    if (_provider == LlmProvider.none || _model.isEmpty) return false;
    if (_provider == LlmProvider.embedded) return true;
    if (_provider == LlmProvider.ollama ||
        _provider == LlmProvider.openaiCompatible) {
      return _baseUrl.isNotEmpty;
    }
    return _apiKey.isNotEmpty;
  }

  bool get isConfigured2 {
    if (_provider2 == LlmProvider.none || _model2.isEmpty) return false;
    if (_provider2 == LlmProvider.embedded) return true;
    if (_provider2 == LlmProvider.ollama ||
        _provider2 == LlmProvider.openaiCompatible) {
      return _baseUrl2.isNotEmpty;
    }
    return _apiKey2.isNotEmpty;
  }

  String getApiKeyForProvider(LlmProvider p) {
    if (p == _provider) return _apiKey;
    return _apiKeysByProvider[p.configKey] ?? '';
  }

  String getBaseUrlForProvider(LlmProvider p) {
    if (p == _provider) return _baseUrl;
    final url = _baseUrlsByProvider[p.configKey];
    if (url != null && url.isNotEmpty) return url;
    return p == LlmProvider.mistral ? 'https://api.mistral.ai/v1' : '';
  }

  String getModelForProvider(LlmProvider p) {
    if (p == _provider) return _model;
    final m = _modelsByProvider[p.configKey];
    if (m != null && m.isNotEmpty) return m;
    final suggestions = defaultModels[p] ?? [];
    return suggestions.isNotEmpty ? suggestions.first : '';
  }

  // ── Load ─────────────────────────────────────────
  Future<void> load() async {
    final cfg = ServerConfigService();
    _provider = LlmProvider.fromConfigKey(
      cfg.getSecret(_kProvider) ?? cfg.getString(_kProvider),
    );
    _model = cfg.getSecret(_kModel) ?? cfg.getString(_kModel) ?? '';
    _apiKey = cfg.getSecret(_kApiKey) ?? '';
    _baseUrl = cfg.getSecret(_kBaseUrl) ?? cfg.getString(_kBaseUrl) ?? '';
    _temperature = double.tryParse(cfg.getString(_kTemperature) ?? '') ?? 0.2;
    _maxTokens = int.tryParse(cfg.getString(_kMaxTokens) ?? '') ?? 0;
    _maxToolOutputSize =
        int.tryParse(cfg.getString(_kMaxToolOutputSize) ?? '') ?? 2560000;
    _tokenWarningThreshold =
        int.tryParse(cfg.getString(_kTokenWarningThreshold) ?? '') ?? 1500000;
    _isSlm = cfg.getBool(_kIsSlm) ?? false;
    _isMultiModal = cfg.getBool(_kIsMultiModal) ?? true;
    _topK = cfg.getInt(_kTopK);
    _topP = cfg.getDouble(_kTopP);
    _repeatPenalty = cfg.getDouble(_kRepeatPenalty);
    _seed = cfg.getInt(_kSeed);
    _thinking = cfg.getBool(_kThinking) ?? false;
    _useNativeToolCall = cfg.getBool(_kUseNativeToolCall) ?? true;
    _enableToolParameterAutoRecovery = cfg.getBool(_kEnableToolParameterAutoRecovery) ?? true;
    _injectToolCallingRules = cfg.getBool(_kInjectToolCallingRules) ?? true;

    // Per-provider scoped secrets
    for (final p in LlmProvider.values) {
      if (p == LlmProvider.none) continue;
      final k = cfg.getSecret('${_kApiKey}_${p.configKey}');
      if (k != null && k.isNotEmpty) _apiKeysByProvider[p.configKey] = k;
      final bu =
          cfg.getSecret('${_kBaseUrl}_${p.configKey}') ??
          cfg.getString('${_kBaseUrl}_${p.configKey}');
      if (bu != null && bu.isNotEmpty) _baseUrlsByProvider[p.configKey] = bu;
      final m =
          cfg.getSecret('${_kModel}_${p.configKey}') ??
          cfg.getString('${_kModel}_${p.configKey}');
      if (m != null && m.isNotEmpty) _modelsByProvider[p.configKey] = m;
    }

    // LLM 2
    _provider2 = LlmProvider.fromConfigKey(
      cfg.getSecret(_kProvider2) ?? cfg.getString(_kProvider2),
    );
    _model2 = cfg.getSecret(_kModel2) ?? cfg.getString(_kModel2) ?? '';
    _apiKey2 = cfg.getSecret(_kApiKey2) ?? '';
    _baseUrl2 = cfg.getSecret(_kBaseUrl2) ?? cfg.getString(_kBaseUrl2) ?? '';
    if (_provider2 == LlmProvider.mistral && _baseUrl2.isEmpty) {
      _baseUrl2 = 'https://api.mistral.ai/v1';
    }
    _temperature2 = double.tryParse(cfg.getString(_kTemperature2) ?? '') ?? 0.2;
    _maxTokens2 = int.tryParse(cfg.getString(_kMaxTokens2) ?? '') ?? 0;
    _maxToolOutputSize2 =
        int.tryParse(cfg.getString(_kMaxToolOutputSize2) ?? '') ?? 2560000;
    _tokenWarningThreshold2 =
        int.tryParse(cfg.getString(_kTokenWarningThreshold2) ?? '') ?? 1500000;
    _isSlm2 = cfg.getBool(_kIsSlm2) ?? false;
    _isMultiModal2 = cfg.getBool(_kIsMultiModal2) ?? true;
    _topK2 = cfg.getInt(_kTopK2);
    _topP2 = cfg.getDouble(_kTopP2);
    _repeatPenalty2 = cfg.getDouble(_kRepeatPenalty2);
    _seed2 = cfg.getInt(_kSeed2);
    _thinking2 = cfg.getBool(_kThinking2) ?? false;
    _useNativeToolCall2 = cfg.getBool(_kUseNativeToolCall2) ?? true;

    log.info(
      '[LLM Settings] Loaded – provider=${_provider.configKey}, model=$_model',
    );
  }

  // ── Save helpers ─────────────────────────────────
  Future<void> setProvider(LlmProvider p) async {
    _provider = p;
    await ServerConfigService().setSecret(_kProvider, p.configKey);
  }

  Future<void> setModel(String m) async {
    _model = m;
    await ServerConfigService().setSecret(_kModel, m);
  }

  Future<void> setApiKey(String key) async {
    _apiKey = key;
    await ServerConfigService().setSecret(_kApiKey, key);
    if (_provider != LlmProvider.none) {
      _apiKeysByProvider[_provider.configKey] = key;
      await ServerConfigService().setSecret(
        '${_kApiKey}_${_provider.configKey}',
        key,
      );
    }
  }

  Future<void> setBaseUrl(String url) async {
    _baseUrl = url;
    await ServerConfigService().setSecret(_kBaseUrl, url);
  }

  Future<void> setTemperature(double v) async {
    _temperature = v;
    await ServerConfigService().setString(_kTemperature, v.toString());
  }

  Future<void> setTemperature2(double v) async {
    _temperature2 = v;
    await ServerConfigService().setString(_kTemperature2, v.toString());
  }

  Future<void> setMaxTokens(int v) async {
    _maxTokens = v;
    await ServerConfigService().setString(_kMaxTokens, v.toString());
  }

  Future<void> setMaxTokens2(int v) async {
    _maxTokens2 = v;
    await ServerConfigService().setString(_kMaxTokens2, v.toString());
  }

  Future<void> setProvider2(LlmProvider p) async {
    _provider2 = p;
    await ServerConfigService().setSecret(_kProvider2, p.configKey);
  }

  Future<void> setModel2(String m) async {
    _model2 = m;
    await ServerConfigService().setSecret(_kModel2, m);
  }

  Future<void> setApiKey2(String key) async {
    _apiKey2 = key;
    await ServerConfigService().setSecret(_kApiKey2, key);
  }

  Future<void> setBaseUrl2(String url) async {
    _baseUrl2 = url;
    await ServerConfigService().setSecret(_kBaseUrl2, url);
  }

  Future<void> setThinking(bool value) async {
    _thinking = value;
    await ServerConfigService().setBool(_kThinking, value);
  }

  Future<void> setThinking2(bool value) async {
    _thinking2 = value;
    await ServerConfigService().setBool(_kThinking2, value);
  }

  Future<void> setUseNativeToolCall(bool value) async {
    _useNativeToolCall = value;
    await ServerConfigService().setBool(_kUseNativeToolCall, value);
  }

  Future<void> setUseNativeToolCall2(bool value) async {
    _useNativeToolCall2 = value;
    await ServerConfigService().setBool(_kUseNativeToolCall2, value);
  }

  Future<void> setUseSafeToolCall(bool value) async {
    _useSafeToolCall = value;
    await ServerConfigService().setBool(_kUseSafeToolCall, value);
  }

  Future<void> setEnableToolParameterAutoRecovery(bool value) async {
    _enableToolParameterAutoRecovery = value;
    await ServerConfigService().setBool(_kEnableToolParameterAutoRecovery, value);
  }

  Future<void> setInjectToolCallingRules(bool value) async {
    _injectToolCallingRules = value;
    await ServerConfigService().setBool(_kInjectToolCallingRules, value);
  }

  Future<void> setUseSafeToolCall2(bool value) async {
    _useSafeToolCall2 = value;
    await ServerConfigService().setBool(_kUseSafeToolCall2, value);
  }

  Future<void> setMaxToolOutputSize(int v) async {
    _maxToolOutputSize = v;
    await ServerConfigService().setString(_kMaxToolOutputSize, v.toString());
  }

  Future<void> setMaxToolOutputSize2(int v) async {
    _maxToolOutputSize2 = v;
    await ServerConfigService().setString(_kMaxToolOutputSize2, v.toString());
  }

  Future<void> setTokenWarningThreshold(int v) async {
    _tokenWarningThreshold = v;
    await ServerConfigService().setString(
      _kTokenWarningThreshold,
      v.toString(),
    );
  }

  Future<void> setTokenWarningThreshold2(int v) async {
    _tokenWarningThreshold2 = v;
    await ServerConfigService().setString(
      _kTokenWarningThreshold2,
      v.toString(),
    );
  }

  Future<void> setIsSlm(bool v) async {
    _isSlm = v;
    await ServerConfigService().setBool(_kIsSlm, v);
  }

  Future<void> setIsSlm2(bool v) async {
    _isSlm2 = v;
    await ServerConfigService().setBool(_kIsSlm2, v);
  }

  Future<void> setIsMultiModal(bool v) async {
    _isMultiModal = v;
    await ServerConfigService().setBool(_kIsMultiModal, v);
  }

  Future<void> setIsMultiModal2(bool v) async {
    _isMultiModal2 = v;
    await ServerConfigService().setBool(_kIsMultiModal2, v);
  }

  Future<void> setTopK(int? v) async {
    _topK = v;
    if (v == null) {
      await ServerConfigService().remove(_kTopK);
    } else {
      await ServerConfigService().setInt(_kTopK, v);
    }
  }

  Future<void> setTopK2(int? v) async {
    _topK2 = v;
    if (v == null) {
      await ServerConfigService().remove(_kTopK2);
    } else {
      await ServerConfigService().setInt(_kTopK2, v);
    }
  }

  Future<void> setTopP(double? v) async {
    _topP = v;
    if (v == null) {
      await ServerConfigService().remove(_kTopP);
    } else {
      await ServerConfigService().setDouble(_kTopP, v);
    }
  }

  Future<void> setTopP2(double? v) async {
    _topP2 = v;
    if (v == null) {
      await ServerConfigService().remove(_kTopP2);
    } else {
      await ServerConfigService().setDouble(_kTopP2, v);
    }
  }

  Future<void> setRepeatPenalty(double? v) async {
    _repeatPenalty = v;
    if (v == null) {
      await ServerConfigService().remove(_kRepeatPenalty);
    } else {
      await ServerConfigService().setDouble(_kRepeatPenalty, v);
    }
  }

  Future<void> setRepeatPenalty2(double? v) async {
    _repeatPenalty2 = v;
    if (v == null) {
      await ServerConfigService().remove(_kRepeatPenalty2);
    } else {
      await ServerConfigService().setDouble(_kRepeatPenalty2, v);
    }
  }

  Future<void> setSeed(int? v) async {
    _seed = v;
    if (v == null) {
      await ServerConfigService().remove(_kSeed);
    } else {
      await ServerConfigService().setInt(_kSeed, v);
    }
  }

  Future<void> setSeed2(int? v) async {
    _seed2 = v;
    if (v == null) {
      await ServerConfigService().remove(_kSeed2);
    } else {
      await ServerConfigService().setInt(_kSeed2, v);
    }
  }
}
