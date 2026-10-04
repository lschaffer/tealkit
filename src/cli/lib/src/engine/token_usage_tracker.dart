import 'dart:convert';
import 'package:dart_mcp_core/dart_mcp_core.dart';
import 'package:http/http.dart' as http;
import '../formatters/terminal_printer.dart';

/// Pricing rate and context specification for an LLM model.
typedef ModelRateInfo = ({
  double inputPerM,
  double outputPerM,
  int? contextWindow,
  String rateDescription,
});

/// Tracks token usage and calculates estimated API costs across an active session.
class TokenUsageTracker {
  int promptTokens = 0;
  int completionTokens = 0;
  int turnsCount = 0;

  int get totalTokens => promptTokens + completionTokens;

  /// Record token usage from an LLM response or turn.
  void recordUsage({required int prompt, required int completion}) {
    promptTokens += prompt;
    completionTokens += completion;
    turnsCount++;
  }

  /// Clears all accumulated token metrics (e.g. on /clear or /clear-session).
  void reset() {
    promptTokens = 0;
    completionTokens = 0;
    turnsCount = 0;
  }

  // In-memory cache for live public model pricing (e.g. from OpenRouter)
  static List<dynamic>? _liveModelsCache;
  static DateTime? _liveModelsFetchedAt;
  static const Duration _liveModelsTtl = Duration(hours: 1);

  // In-memory cache for resolved rates per model
  static final Map<String, ModelRateInfo> _rateResolutionCache = {};

  /// Format a context window token count into compact human readable format (e.g. 205k ctx, 1M ctx).
  static String formatContextWindow(int? contextWindow) {
    if (contextWindow == null || contextWindow <= 0) return '';
    if (contextWindow >= 1000000) {
      final m = (contextWindow / 1000000)
          .toStringAsFixed(1)
          .replaceAll(RegExp(r'\.0$'), '');
      return '${m}M ctx';
    }
    final k = (contextWindow / 1000).round();
    return '${k}k ctx';
  }

  /// Resolves pricing rates synchronously.
  ///
  /// Local models are free ($0.00). Proprietary and hosted models return null
  /// if not already resolved and cached from live providers or OpenRouter.
  static ModelRateInfo? getRates(LlmConfig config) {
    final provider = config.provider;

    // 1. Local models are free ($0.00)
    if (provider == LlmProvider.ollama || provider == LlmProvider.embedded) {
      return (
        inputPerM: 0.0,
        outputPerM: 0.0,
        contextWindow: null,
        rateDescription:
            'Local model (${provider.displayName}) — Free (\$0.00)',
      );
    }

    // Check cached resolution
    final cacheKey = '${config.provider.name}:${config.model.toLowerCase()}';
    if (_rateResolutionCache.containsKey(cacheKey)) {
      return _rateResolutionCache[cacheKey];
    }

    // No hardcoded model prices! Must be fetched live via provider API or web / OpenRouter.
    return null;
  }

  /// Attempts to fetch live pricing and context window:
  /// 1. Direct from Provider API / endpoint (e.g. DeepInfra, Mistral docs)
  /// 2. If not available from direct provider, query OpenRouter live catalog
  /// 3. Otherwise returns null (0 / no price available)
  static Future<ModelRateInfo?> getRatesAsync(LlmConfig config) async {
    final staticRate = getRates(config);
    if (staticRate != null) return staticRate;

    final cacheKey = '${config.provider.name}:${config.model.toLowerCase()}';
    final modelLower = config.model.toLowerCase();
    final baseModel = modelLower.contains('/')
        ? modelLower.split('/').last
        : modelLower;
    final baseUrl = config.baseUrl.toLowerCase();

    // ── 1. Direct Provider APIs & Web Specifications ──

    // A. DeepInfra (has public endpoint returning models with pricing and ctx)
    if (baseUrl.contains('deepinfra.com') || modelLower.contains('deepinfra')) {
      try {
        final deepInfraPrice = await _fetchDeepInfraPrice(config.model);
        if (deepInfraPrice != null) {
          final ctxDesc = deepInfraPrice.contextWindow != null
              ? '${formatContextWindow(deepInfraPrice.contextWindow)} • '
              : '';
          final rate = (
            inputPerM: deepInfraPrice.inputPerM,
            outputPerM: deepInfraPrice.outputPerM,
            contextWindow: deepInfraPrice.contextWindow,
            rateDescription:
                'provider price from DeepInfra ($ctxDesc\$${deepInfraPrice.inputPerM.toStringAsFixed(2)} / \$${deepInfraPrice.outputPerM.toStringAsFixed(2)} per 1M)',
          );
          _rateResolutionCache[cacheKey] = rate;
          return rate;
        }
      } catch (_) {}
    }

    // B. Mistral (from official docs/spec)
    if (config.provider == LlmProvider.mistral ||
        baseUrl.contains('mistral.ai') ||
        modelLower.contains('mistral')) {
      try {
        final mistralPrice = await _fetchMistralWebPrice(modelLower);
        if (mistralPrice != null) {
          final ctxDesc = mistralPrice.contextWindow != null
              ? '${formatContextWindow(mistralPrice.contextWindow)} • '
              : '';
          final rate = (
            inputPerM: mistralPrice.inputPerM,
            outputPerM: mistralPrice.outputPerM,
            contextWindow: mistralPrice.contextWindow,
            rateDescription:
                'provider price from Mistral ($ctxDesc\$${mistralPrice.inputPerM.toStringAsFixed(2)} / \$${mistralPrice.outputPerM.toStringAsFixed(2)} per 1M)',
          );
          _rateResolutionCache[cacheKey] = rate;
          return rate;
        }
      } catch (_) {}
    }

    // C. OpenAI (from official pricing documentation)
    if (config.provider == LlmProvider.openai ||
        baseUrl.contains('api.openai.com') ||
        modelLower.startsWith('gpt-') ||
        modelLower.startsWith('o1') ||
        modelLower.startsWith('o3')) {
      try {
        final openAiPrice = await _fetchOpenAiLivePrice(modelLower);
        if (openAiPrice != null) {
          final ctxDesc = openAiPrice.contextWindow != null
              ? '${formatContextWindow(openAiPrice.contextWindow)} • '
              : '';
          final rate = (
            inputPerM: openAiPrice.inputPerM,
            outputPerM: openAiPrice.outputPerM,
            contextWindow: openAiPrice.contextWindow,
            rateDescription:
                'provider price from OpenAI ($ctxDesc\$${openAiPrice.inputPerM.toStringAsFixed(2)} / \$${openAiPrice.outputPerM.toStringAsFixed(2)} per 1M)',
          );
          _rateResolutionCache[cacheKey] = rate;
          return rate;
        }
      } catch (_) {}
    }

    // D. Anthropic (from official pricing docs)
    if (config.provider == LlmProvider.claude ||
        baseUrl.contains('anthropic.com') ||
        modelLower.contains('claude')) {
      try {
        final claudePrice = await _fetchAnthropicLivePrice(modelLower);
        if (claudePrice != null) {
          final ctxDesc = claudePrice.contextWindow != null
              ? '${formatContextWindow(claudePrice.contextWindow)} • '
              : '';
          final rate = (
            inputPerM: claudePrice.inputPerM,
            outputPerM: claudePrice.outputPerM,
            contextWindow: claudePrice.contextWindow,
            rateDescription:
                'provider price from Anthropic ($ctxDesc\$${claudePrice.inputPerM.toStringAsFixed(2)} / \$${claudePrice.outputPerM.toStringAsFixed(2)} per 1M)',
          );
          _rateResolutionCache[cacheKey] = rate;
          return rate;
        }
      } catch (_) {}
    }

    // E. Google Gemini (from official Gemini pricing spec)
    if (config.provider == LlmProvider.gemini ||
        baseUrl.contains('generativelanguage.googleapis.com') ||
        modelLower.contains('gemini')) {
      try {
        final geminiPrice = await _fetchGoogleGeminiLivePrice(modelLower);
        if (geminiPrice != null) {
          final ctxDesc = geminiPrice.contextWindow != null
              ? '${formatContextWindow(geminiPrice.contextWindow)} • '
              : '';
          final rate = (
            inputPerM: geminiPrice.inputPerM,
            outputPerM: geminiPrice.outputPerM,
            contextWindow: geminiPrice.contextWindow,
            rateDescription:
                'provider price from Google ($ctxDesc\$${geminiPrice.inputPerM.toStringAsFixed(2)} / \$${geminiPrice.outputPerM.toStringAsFixed(2)} per 1M)',
          );
          _rateResolutionCache[cacheKey] = rate;
          return rate;
        }
      } catch (_) {}
    }

    // ── 2. OpenRouter Live Catalog Fallback ──
    try {
      if (_liveModelsCache == null ||
          _liveModelsFetchedAt == null ||
          DateTime.now().difference(_liveModelsFetchedAt!) > _liveModelsTtl) {
        final response = await http
            .get(Uri.parse('https://openrouter.ai/api/v1/models'))
            .timeout(const Duration(seconds: 5));
        if (response.statusCode == 200) {
          final decoded = jsonDecode(response.body);
          if (decoded is Map<String, dynamic> && decoded['data'] is List) {
            _liveModelsCache = decoded['data'] as List;
            _liveModelsFetchedAt = DateTime.now();
          }
        }
      }

      if (_liveModelsCache != null && _liveModelsCache!.isNotEmpty) {
        // Search by exact id, shortId, or base model
        for (final item in _liveModelsCache!) {
          if (item is! Map<String, dynamic>) continue;
          final id = (item['id'] ?? '').toString().toLowerCase();
          final shortId = id.contains('/') ? id.split('/').last : id;
          final name = (item['name'] ?? '').toString().toLowerCase();

          final withoutLatest = baseModel.endsWith('-latest')
              ? baseModel.substring(0, baseModel.length - '-latest'.length)
              : baseModel;
          if (id == modelLower ||
              shortId == baseModel ||
              id.endsWith('/$baseModel') ||
              shortId == modelLower ||
              shortId == withoutLatest ||
              id.endsWith('/$withoutLatest') ||
              shortId.startsWith(withoutLatest) ||
              name.contains(baseModel) ||
              name.contains(withoutLatest)) {
            final pricing = item['pricing'];
            if (pricing is Map<String, dynamic>) {
              final prompt = double.tryParse(
                (pricing['prompt'] ?? pricing['input'] ?? '').toString(),
              );
              final completion = double.tryParse(
                (pricing['completion'] ?? pricing['output'] ?? '').toString(),
              );
              final int? ctxLen = (item['context_length'] as num?)?.toInt();
              if (prompt != null && completion != null) {
                final inPerM = prompt * 1000000.0;
                final outPerM = completion * 1000000.0;
                final ctxDesc = ctxLen != null
                    ? '${formatContextWindow(ctxLen)} • '
                    : '';
                if (inPerM == 0.0 && outPerM == 0.0) {
                  final rate = (
                    inputPerM: 0.0,
                    outputPerM: 0.0,
                    contextWindow: ctxLen,
                    rateDescription: 'Free (openrouter price: $ctxDesc\$0.00)',
                  );
                  _rateResolutionCache[cacheKey] = rate;
                  return rate;
                }
                final rate = (
                  inputPerM: inPerM,
                  outputPerM: outPerM,
                  contextWindow: ctxLen,
                  rateDescription:
                      'openrouter price: $ctxDesc\$${inPerM.toStringAsFixed(2)} / \$${outPerM.toStringAsFixed(2)} per 1M',
                );
                _rateResolutionCache[cacheKey] = rate;
                return rate;
              }
            }
          }
        }
      }
    } catch (_) {
      // Ignore network failures and fall through to null
    }

    return null;
  }

  /// Direct API lookup for DeepInfra pricing & context length
  static Future<({double inputPerM, double outputPerM, int? contextWindow})?>
  _fetchDeepInfraPrice(String model) async {
    final response = await http
        .get(Uri.parse('https://api.deepinfra.com/models/list'))
        .timeout(const Duration(seconds: 4));
    if (response.statusCode != 200) return null;

    final decoded = jsonDecode(response.body);
    if (decoded is! List) return null;

    final targetLower = model.toLowerCase();
    final targetShort = targetLower.contains('/')
        ? targetLower.split('/').last
        : targetLower;

    for (final item in decoded) {
      if (item is! Map<String, dynamic>) continue;
      final mName = (item['model_name'] ?? item['name'] ?? '')
          .toString()
          .toLowerCase();
      final mShort = mName.contains('/') ? mName.split('/').last : mName;

      if (mName == targetLower || mShort == targetShort) {
        final pricing = item['pricing'];
        final num? rawTokens = item['max_tokens'] ?? item['context_length'];
        final int? maxTokens = rawTokens?.toInt();
        if (pricing is Map<String, dynamic>) {
          final inTokens = double.tryParse(
            (pricing['input'] ?? pricing['prompt'] ?? '').toString(),
          );
          final outTokens = double.tryParse(
            (pricing['output'] ?? pricing['completion'] ?? '').toString(),
          );
          if (inTokens != null && outTokens != null) {
            final inPerM = inTokens <= 0.01 ? inTokens * 1000000.0 : inTokens;
            final outPerM = outTokens <= 0.01
                ? outTokens * 1000000.0
                : outTokens;
            return (
              inputPerM: inPerM,
              outputPerM: outPerM,
              contextWindow: maxTokens,
            );
          }
        }
      }
    }
    return null;
  }

  static Future<({double inputPerM, double outputPerM, int? contextWindow})?>
  _fetchMistralWebPrice(String normalizedModel) async {
    final response = await http
        .get(
          Uri.parse(
            'https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json',
          ),
        )
        .timeout(const Duration(seconds: 4));
    if (response.statusCode != 200) return null;

    final data = jsonDecode(response.body);
    if (data is! Map<String, dynamic>) return null;

    final target = normalizedModel.toLowerCase();
    final baseTarget = target.endsWith('-latest')
        ? target.substring(0, target.length - '-latest'.length)
        : target;

    for (final entry in data.entries) {
      final key = entry.key.toLowerCase();
      if (key == target ||
          key == 'mistral/$target' ||
          key == 'mistralai/$target' ||
          key == 'mistral/$baseTarget' ||
          key == 'mistralai/$baseTarget' ||
          (key.startsWith('mistral/') && key.contains(baseTarget))) {
        final val = entry.value;
        if (val is Map<String, dynamic>) {
          final inCost = double.tryParse(
            (val['input_cost_per_token'] ?? '').toString(),
          );
          final outCost = double.tryParse(
            (val['output_cost_per_token'] ?? '').toString(),
          );
          final num? rawTokens = val['max_input_tokens'] ?? val['max_tokens'];
          final int? ctxLen = rawTokens?.toInt();
          if (inCost != null && outCost != null) {
            return (
              inputPerM: inCost * 1000000.0,
              outputPerM: outCost * 1000000.0,
              contextWindow: ctxLen ?? 128000,
            );
          }
        }
      }
    }
    return null;
  }

  /// Live web pricing for OpenAI from official pricing documentation
  static Future<({double inputPerM, double outputPerM, int? contextWindow})?>
  _fetchOpenAiLivePrice(String model) async {
    final response = await http
        .get(
          Uri.parse(
            'https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json',
          ),
        )
        .timeout(const Duration(seconds: 4));
    if (response.statusCode != 200) return null;

    final data = jsonDecode(response.body);
    if (data is! Map<String, dynamic>) return null;

    final target = model.toLowerCase();
    for (final entry in data.entries) {
      final key = entry.key.toLowerCase();
      if (key == target ||
          key == 'openai/$target' ||
          key.endsWith('/$target')) {
        final val = entry.value;
        if (val is Map<String, dynamic>) {
          final inCost = double.tryParse(
            (val['input_cost_per_token'] ?? '').toString(),
          );
          final outCost = double.tryParse(
            (val['output_cost_per_token'] ?? '').toString(),
          );
          final num? rawTokens = val['max_input_tokens'] ?? val['max_tokens'];
          final int? ctxLen = rawTokens?.toInt();
          if (inCost != null && outCost != null) {
            return (
              inputPerM: inCost * 1000000.0,
              outputPerM: outCost * 1000000.0,
              contextWindow: ctxLen,
            );
          }
        }
      }
    }
    return null;
  }

  /// Live web pricing for Anthropic from official repository specs
  static Future<({double inputPerM, double outputPerM, int? contextWindow})?>
  _fetchAnthropicLivePrice(String model) async {
    final response = await http
        .get(
          Uri.parse(
            'https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json',
          ),
        )
        .timeout(const Duration(seconds: 4));
    if (response.statusCode != 200) return null;

    final data = jsonDecode(response.body);
    if (data is! Map<String, dynamic>) return null;

    final target = model.toLowerCase();
    for (final entry in data.entries) {
      final key = entry.key.toLowerCase();
      if (key == target ||
          key == 'anthropic/$target' ||
          (key.contains('claude') && key.contains(target))) {
        final val = entry.value;
        if (val is Map<String, dynamic>) {
          final inCost = double.tryParse(
            (val['input_cost_per_token'] ?? '').toString(),
          );
          final outCost = double.tryParse(
            (val['output_cost_per_token'] ?? '').toString(),
          );
          final num? rawTokens = val['max_input_tokens'] ?? val['max_tokens'];
          final int? ctxLen = rawTokens?.toInt();
          if (inCost != null && outCost != null) {
            return (
              inputPerM: inCost * 1000000.0,
              outputPerM: outCost * 1000000.0,
              contextWindow: ctxLen,
            );
          }
        }
      }
    }
    return null;
  }

  /// Live web pricing for Google Gemini from official repository specs
  static Future<({double inputPerM, double outputPerM, int? contextWindow})?>
  _fetchGoogleGeminiLivePrice(String model) async {
    final response = await http
        .get(
          Uri.parse(
            'https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json',
          ),
        )
        .timeout(const Duration(seconds: 4));
    if (response.statusCode != 200) return null;

    final data = jsonDecode(response.body);
    if (data is! Map<String, dynamic>) return null;

    final target = model.toLowerCase();
    for (final entry in data.entries) {
      final key = entry.key.toLowerCase();
      if (key == target ||
          key == 'gemini/$target' ||
          (key.contains('gemini') && key.contains(target))) {
        final val = entry.value;
        if (val is Map<String, dynamic>) {
          final inCost = double.tryParse(
            (val['input_cost_per_token'] ?? '').toString(),
          );
          final outCost = double.tryParse(
            (val['output_cost_per_token'] ?? '').toString(),
          );
          final num? rawTokens = val['max_input_tokens'] ?? val['max_tokens'];
          final int? ctxLen = rawTokens?.toInt();
          if (inCost != null && outCost != null) {
            return (
              inputPerM: inCost * 1000000.0,
              outputPerM: outCost * 1000000.0,
              contextWindow: ctxLen,
            );
          }
        }
      }
    }
    return null;
  }

  /// Calculates total estimated cost in USD, or returns `null` if pricing is unavailable.
  double? calculateEstimatedCost(LlmConfig config, {ModelRateInfo? rates}) {
    final activeRates = rates ?? getRates(config);
    if (activeRates == null) return null;
    final inCost = (promptTokens / 1000000.0) * activeRates.inputPerM;
    final outCost = (completionTokens / 1000000.0) * activeRates.outputPerM;
    return inCost + outCost;
  }

  /// Generates a formatted summary string synchronously.
  String formatReport(
    LlmConfig config, {
    String? modelDisplayName,
    ModelRateInfo? rates,
  }) {
    final resolvedRates = rates ?? getRates(config);
    final totalCost = calculateEstimatedCost(config, rates: resolvedRates);
    final displayName =
        modelDisplayName ?? '${config.provider.displayName} / ${config.model}';

    final buffer = StringBuffer();
    buffer.writeln(
      TerminalPrinter.bold('─── Token Usage & Estimated Cost ───'),
    );
    buffer.writeln(
      '  Active LLM       : $displayName (${config.provider.displayName} / ${config.model})',
    );
    if (resolvedRates?.contextWindow != null) {
      buffer.writeln(
        '  Context Window   : ${formatContextWindow(resolvedRates!.contextWindow)}',
      );
    }
    if (resolvedRates != null) {
      buffer.writeln('  Pricing Rate     : ${resolvedRates.rateDescription}');
    } else {
      buffer.writeln(
        '  Pricing Rate     : ${TerminalPrinter.dim("None (no price available)")}',
      );
    }
    buffer.writeln('  Turns Completed  : $turnsCount');
    buffer.writeln('  Input Tokens     : ${_formatNumber(promptTokens)}');
    buffer.writeln('  Output Tokens    : ${_formatNumber(completionTokens)}');
    buffer.writeln(
      '  Total Tokens     : ${TerminalPrinter.cyan(_formatNumber(totalTokens))}',
    );
    if (totalCost != null) {
      buffer.writeln(
        '  Estimated Cost   : ${TerminalPrinter.bold(TerminalPrinter.green('\$${totalCost.toStringAsFixed(6)}'))}',
      );
    } else {
      buffer.writeln(
        '  Estimated Cost   : ${TerminalPrinter.dim("None (no price available)")}',
      );
    }
    buffer.writeln('────────────────────────────────────');
    return buffer.toString();
  }

  /// Generates a formatted summary string asynchronously (attempting to fetch public pricing).
  Future<String> formatReportAsync(
    LlmConfig config, {
    String? modelDisplayName,
  }) async {
    final resolvedRates = await getRatesAsync(config);
    return formatReport(
      config,
      modelDisplayName: modelDisplayName,
      rates: resolvedRates,
    );
  }

  static String _formatNumber(int n) {
    final s = n.toString();
    final buffer = StringBuffer();
    int count = 0;
    for (int i = s.length - 1; i >= 0; i--) {
      buffer.write(s[i]);
      count++;
      if (count % 3 == 0 && i > 0) {
        buffer.write(',');
      }
    }
    return buffer.toString().split('').reversed.join('');
  }
}
