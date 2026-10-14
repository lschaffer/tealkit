import '../services/llm_settings_service.dart' show LlmProvider;

/// A named, reusable LLM profile configuration.
///
/// Enables users to define multiple LLMs (e.g. "Fast Assistant", "Deep Reasoner", "Local Coder")
/// and select them conveniently in the Assistant and Workflow editors.
class NamedLlmProfile {
  final String id;
  final String name;
  final LlmProvider provider;
  final String model;
  final String apiKey;
  final String baseUrl;
  final double temperature;
  final int maxTokens;
  final int maxToolOutputSize;
  final int tokenWarningThreshold;
  final bool isSlm;
  final bool isMultiModal;
  final bool thinking;
  final bool useNativeToolCall;
  final bool useSafeToolCall;
  final int? topK;
  final double? topP;
  final double? repeatPenalty;
  final int? seed;

  const NamedLlmProfile({
    required this.id,
    required this.name,
    required this.provider,
    required this.model,
    this.apiKey = '',
    this.baseUrl = '',
    this.temperature = 0.2,
    this.maxTokens = 0,
    this.maxToolOutputSize = 2560000,
    this.tokenWarningThreshold = 1500000,
    this.isSlm = false,
    this.isMultiModal = true,
    this.thinking = false,
    this.useNativeToolCall = true,
    this.useSafeToolCall = false,
    this.topK,
    this.topP,
    this.repeatPenalty,
    this.seed,
  });

  bool get isConfigured => provider != LlmProvider.none && model.trim().isNotEmpty;

  NamedLlmProfile copyWith({
    String? id,
    String? name,
    LlmProvider? provider,
    String? model,
    String? apiKey,
    String? baseUrl,
    double? temperature,
    int? maxTokens,
    int? maxToolOutputSize,
    int? tokenWarningThreshold,
    bool? isSlm,
    bool? isMultiModal,
    bool? thinking,
    bool? useNativeToolCall,
    bool? useSafeToolCall,
    int? topK,
    double? topP,
    double? repeatPenalty,
    int? seed,
  }) {
    return NamedLlmProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      provider: provider ?? this.provider,
      model: model ?? this.model,
      apiKey: apiKey ?? this.apiKey,
      baseUrl: baseUrl ?? this.baseUrl,
      temperature: temperature ?? this.temperature,
      maxTokens: maxTokens ?? this.maxTokens,
      maxToolOutputSize: maxToolOutputSize ?? this.maxToolOutputSize,
      tokenWarningThreshold: tokenWarningThreshold ?? this.tokenWarningThreshold,
      isSlm: isSlm ?? this.isSlm,
      isMultiModal: isMultiModal ?? this.isMultiModal,
      thinking: thinking ?? this.thinking,
      useNativeToolCall: useNativeToolCall ?? this.useNativeToolCall,
      useSafeToolCall: useSafeToolCall ?? this.useSafeToolCall,
      topK: topK ?? this.topK,
      topP: topP ?? this.topP,
      repeatPenalty: repeatPenalty ?? this.repeatPenalty,
      seed: seed ?? this.seed,
    );
  }

  /// Duplicates this profile with a new ID and suggested copy name.
  NamedLlmProfile clone({String? newId, String? newName}) {
    return copyWith(
      id: newId ?? '${id}_copy_${DateTime.now().millisecondsSinceEpoch}',
      name: newName ?? '$name (Copy)',
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'provider': provider.configKey,
    'model': model,
    'api_key': apiKey,
    'base_url': baseUrl,
    'temperature': temperature,
    'max_tokens': maxTokens,
    'max_tool_output_size': maxToolOutputSize,
    'token_warning_threshold': tokenWarningThreshold,
    'is_slm': isSlm,
    'is_multi_modal': isMultiModal,
    'thinking': thinking,
    'use_native_tool_call': useNativeToolCall,
    'use_safe_tool_call': useSafeToolCall,
    if (topK != null) 'top_k': topK,
    if (topP != null) 'top_p': topP,
    if (repeatPenalty != null) 'repeat_penalty': repeatPenalty,
    if (seed != null) 'seed': seed,
  };

  factory NamedLlmProfile.fromJson(Map<String, dynamic> json) {
    return NamedLlmProfile(
      id: (json['id'] as String?) ?? 'llm_${DateTime.now().millisecondsSinceEpoch}',
      name: (json['name'] as String?) ?? 'LLM',
      provider: LlmProvider.fromConfigKey(json['provider'] as String?),
      model: (json['model'] as String?) ?? '',
      apiKey: (json['api_key'] as String?) ?? '',
      baseUrl: (json['base_url'] as String?) ?? '',
      temperature: (json['temperature'] as num?)?.toDouble() ?? 0.2,
      maxTokens: (json['max_tokens'] as int?) ?? 0,
      maxToolOutputSize: (json['max_tool_output_size'] as int?) ?? 2560000,
      tokenWarningThreshold: (json['token_warning_threshold'] as int?) ?? 1500000,
      isSlm: (json['is_slm'] as bool?) ?? false,
      isMultiModal: (json['is_multi_modal'] as bool?) ?? true,
      thinking: (json['thinking'] as bool?) ?? false,
      useNativeToolCall: (json['use_native_tool_call'] as bool?) ?? true,
      useSafeToolCall: (json['use_safe_tool_call'] as bool?) ?? false,
      topK: json['top_k'] as int?,
      topP: (json['top_p'] as num?)?.toDouble(),
      repeatPenalty: (json['repeat_penalty'] as num?)?.toDouble(),
      seed: json['seed'] as int?,
    );
  }
}
