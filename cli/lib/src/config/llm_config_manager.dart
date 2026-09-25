import 'dart:io';
import 'package:dart_mcp_core/dart_mcp_core.dart';
import 'package:yaml/yaml.dart';

import 'env_loader.dart';
import 'global_config.dart';

/// Represents a named LLM profile in llm.yaml.
class NamedLlmProfile {
  final String name;
  final LlmConfig config;
  final bool isDefault;

  const NamedLlmProfile({
    required this.name,
    required this.config,
    this.isDefault = false,
  });

  @override
  String toString() => '$name (${config.provider.displayName} / ${config.model})';
}

/// Manages loading and switching LLM profiles with global parameters and multi-model arrays.
class LlmConfigManager {
  /// Loads all configured LLM profiles from [configPath] or global fallback.
  static List<NamedLlmProfile> loadAllProfiles({
    String configPath = 'llm.yaml',
  }) {
    final file = GlobalConfigLocator.resolveConfigFile(configPath);
    if (!file.existsSync()) {
      return [_buildEnvFallbackProfile()];
    }

    final raw = file.readAsStringSync();
    final resolved = EnvLoader.substitute(raw, file.parent);
    final yaml = loadYaml(resolved);

    if (yaml == null || yaml is! YamlMap) {
      return [_buildEnvFallbackProfile()];
    }

    // 1. Extract global parameters (defaults for all models)
    final globalTemp = (yaml['temperature'] as num?)?.toDouble() ?? 0.2;
    var globalMaxTokens = (yaml['max_tokens'] as int?) ?? 8192;
    // Protect against unreasonable max_tokens values that break LLM APIs (e.g. 1000000)
    if (globalMaxTokens > 32768) {
      globalMaxTokens = 8192;
    }
    final globalMaxToolIterations =
        (yaml['max_tool_iterations'] as int?) ?? (yaml['max_tool_iteration'] as int?) ?? 100;

    final globalTopP = (yaml['top_p'] as num?)?.toDouble();
    final globalTopK = yaml['top_k'] as int?;
    final globalRepeatPenalty = (yaml['repeat_penalty'] as num?)?.toDouble();
    final globalSeed = yaml['seed'] as int?;
    final globalUseStreaming = yaml['use_streaming'] as bool? ?? false;
    final globalThinking = yaml['thinking'] as bool? ?? false;
    final globalUseNativeToolCall = yaml['use_native_tool_call'] as bool? ?? true;

    final profiles = <NamedLlmProfile>[];

    // 2. Check for multi-model array: `llms:`, `models:`, or `llm:`
    final modelsList = (yaml['llms'] ?? yaml['models'] ?? yaml['llm']) as YamlList?;

    if (modelsList != null && modelsList.isNotEmpty) {
      for (int i = 0; i < modelsList.length; i++) {
        final item = modelsList[i];
        if (item is! YamlMap) continue;

        final providerStr = (item['provider'] as String?)?.toLowerCase() ?? 'openai';
        final provider = _parseProvider(providerStr);
        final model = (item['model'] as String?) ?? 'gpt-4o-mini';

        final name = (item['name'] as String?)?.trim() ??
            (item['id'] as String?)?.trim() ??
            (providerStr == 'openai_compatible' ? model.split('/').last : providerStr);

        var itemMaxTokens = (item['max_tokens'] as int?) ?? globalMaxTokens;
        if (itemMaxTokens > 32768) {
          itemMaxTokens = 8192;
        }

        final itemMaxToolIterations = (item['max_tool_iterations'] as int?) ??
            (item['max_tool_iteration'] as int?) ??
            globalMaxToolIterations;

        final config = LlmConfig(
          provider: provider,
          model: model,
          apiKey: (item['api_key'] as String?) ?? (item['apiKey'] as String?) ?? '',
          baseUrl: (item['base_url'] as String?) ?? (item['baseUrl'] as String?) ?? '',
          temperature: (item['temperature'] as num?)?.toDouble() ?? globalTemp,
          maxTokens: itemMaxTokens,
          maxToolIterations: itemMaxToolIterations,
          topP: (item['top_p'] as num?)?.toDouble() ?? globalTopP,
          topK: (item['top_k'] as int?) ?? globalTopK,
          repeatPenalty: (item['repeat_penalty'] as num?)?.toDouble() ?? globalRepeatPenalty,
          seed: (item['seed'] as int?) ?? globalSeed,
          useStreaming: (item['use_streaming'] as bool?) ?? globalUseStreaming,
          thinking: (item['thinking'] as bool?) ?? globalThinking,
          useNativeToolCall: (item['use_native_tool_call'] as bool?) ?? globalUseNativeToolCall,
          isSlm: (item['is_slm'] as bool?) ?? (provider == LlmProvider.ollama),
        );

        profiles.add(
          NamedLlmProfile(
            name: name,
            config: config,
            isDefault: i == 0,
          ),
        );
      }
    }

    // 3. Fallback: single LLM format in root of YAML
    if (profiles.isEmpty && yaml.containsKey('provider')) {
      final providerStr = (yaml['provider'] as String?)?.toLowerCase() ?? 'openai';
      final provider = _parseProvider(providerStr);
      final model = (yaml['model'] as String?) ?? 'gpt-4o-mini';
      final name = (yaml['name'] as String?) ??
          (providerStr == 'openai_compatible' ? model.split('/').last : providerStr);

      final config = LlmConfig(
        provider: provider,
        model: model,
        apiKey: (yaml['api_key'] as String?) ?? '',
        baseUrl: (yaml['base_url'] as String?) ?? '',
        temperature: globalTemp,
        maxTokens: globalMaxTokens,
        maxToolIterations: globalMaxToolIterations,
        topP: globalTopP,
        topK: globalTopK,
        repeatPenalty: globalRepeatPenalty,
        seed: globalSeed,
        useStreaming: globalUseStreaming,
        thinking: globalThinking,
        useNativeToolCall: globalUseNativeToolCall,
        isSlm: yaml['is_slm'] as bool? ?? (provider == LlmProvider.ollama),
      );

      profiles.add(
        NamedLlmProfile(
          name: name,
          config: config,
          isDefault: true,
        ),
      );
    }

    if (profiles.isEmpty) {
      profiles.add(_buildEnvFallbackProfile());
    }

    return profiles;
  }

  /// Resolves an [LlmConfig] from a target name, file path, or default.
  static LlmConfig resolveConfig({
    String? nameOrPath,
    String configPath = 'llm.yaml',
  }) {
    // If nameOrPath points to an existing file or has .yaml extension, load from file
    if (nameOrPath != null &&
        nameOrPath.trim().isNotEmpty &&
        (nameOrPath.endsWith('.yaml') ||
            nameOrPath.endsWith('.yml') ||
            File(nameOrPath).existsSync())) {
      final profiles = loadAllProfiles(configPath: nameOrPath);
      return profiles.first.config;
    }

    final profiles = loadAllProfiles(configPath: configPath);
    if (profiles.isEmpty) {
      return _buildEnvFallbackProfile().config;
    }

    if (nameOrPath == null || nameOrPath.trim().isEmpty) {
      return profiles.first.config;
    }

    final query = nameOrPath.trim().toLowerCase();
    // 1. Exact name match
    for (final p in profiles) {
      if (p.name.toLowerCase() == query) return p.config;
    }

    // 2. Provider match
    for (final p in profiles) {
      if (p.config.provider.configKey == query ||
          p.config.provider.name.toLowerCase() == query) {
        return p.config;
      }
    }

    // 3. Substring / model match
    for (final p in profiles) {
      if (p.name.toLowerCase().contains(query) ||
          p.config.model.toLowerCase().contains(query)) {
        return p.config;
      }
    }

    // Fallback: return default
    return profiles.first.config;
  }

  static LlmProvider _parseProvider(String str) {
    return switch (str.toLowerCase()) {
      'claude' || 'anthropic' => LlmProvider.claude,
      'gemini' || 'google' => LlmProvider.gemini,
      'ollama' => LlmProvider.ollama,
      'openai_compatible' || 'openaicompatible' || 'deepseek' || 'deepinfra' =>
        LlmProvider.openaiCompatible,
      'mistral' => LlmProvider.mistral,
      _ => LlmProvider.openai,
    };
  }

  static NamedLlmProfile _buildEnvFallbackProfile() {
    final dotEnv = EnvLoader.loadDotEnv();
    final apiKey = dotEnv['OPENAI_API_KEY'] ??
        dotEnv['ANTHROPIC_API_KEY'] ??
        dotEnv['GEMINI_API_KEY'] ??
        dotEnv['MISTRAL_API_KEY'] ??
        '';

    var provider = LlmProvider.openai;
    var model = 'gpt-4o-mini';
    var name = 'openai';

    if (dotEnv.containsKey('ANTHROPIC_API_KEY')) {
      provider = LlmProvider.claude;
      model = 'claude-3-5-sonnet-20241022';
      name = 'claude';
    } else if (dotEnv.containsKey('GEMINI_API_KEY')) {
      provider = LlmProvider.gemini;
      model = 'gemini-1.5-flash';
      name = 'gemini';
    } else if (dotEnv.containsKey('MISTRAL_API_KEY')) {
      provider = LlmProvider.mistral;
      model = 'mistral-medium-latest';
      name = 'mistral';
    }

    final config = LlmConfig(
      provider: provider,
      model: dotEnv['LLM_MODEL'] ?? model,
      apiKey: apiKey,
      baseUrl: dotEnv['LLM_BASE_URL'] ?? '',
      temperature: 0.2,
      maxTokens: 4096,
    );

    return NamedLlmProfile(name: name, config: config, isDefault: true);
  }
}
