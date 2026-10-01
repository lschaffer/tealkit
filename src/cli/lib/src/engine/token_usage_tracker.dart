import 'dart:convert';
import 'package:dart_mcp_core/dart_mcp_core.dart';
import 'package:http/http.dart' as http;
import '../formatters/terminal_printer.dart';

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

  /// Resolves pricing rates (per 1 million tokens in USD).
  ///
  /// Returns `null` if pricing cannot be determined for the active model.
  static ({double inputPerM, double outputPerM, String rateDescription})? getRates(
    LlmConfig config,
  ) {
    final modelLower = config.model.toLowerCase();
    final provider = config.provider;

    if (provider == LlmProvider.ollama || provider == LlmProvider.embedded) {
      return (
        inputPerM: 0.0,
        outputPerM: 0.0,
        rateDescription: 'Local model (${provider.displayName}) — Free (\$0.00)',
      );
    }

    // Explicit Qwen model pricing when known
    if (modelLower.contains('qwen')) {
      if (modelLower.contains('max')) {
        return (
          inputPerM: 1.60,
          outputPerM: 6.40,
          rateDescription: r'Qwen Max @ $1.60 / $6.40 per 1M',
        );
      } else if (modelLower.contains('plus')) {
        return (
          inputPerM: 0.40,
          outputPerM: 1.20,
          rateDescription: r'Qwen Plus @ $0.40 / $1.20 per 1M',
        );
      } else if (modelLower.contains('turbo')) {
        return (
          inputPerM: 0.05,
          outputPerM: 0.20,
          rateDescription: r'Qwen Turbo @ $0.05 / $0.20 per 1M',
        );
      } else if (modelLower.contains('72b')) {
        return (
          inputPerM: 0.35,
          outputPerM: 0.40,
          rateDescription: r'Qwen 2.5 72B @ $0.35 / $0.40 per 1M',
        );
      } else if (modelLower.contains('32b') || modelLower.contains('14b') || modelLower.contains('7b')) {
        return (
          inputPerM: 0.10,
          outputPerM: 0.20,
          rateDescription: r'Qwen Small/Medium @ $0.10 / $0.20 per 1M',
        );
      }
    }

    // DeepSeek / DeepInfra
    if (modelLower.contains('deepseek') || config.baseUrl.contains('deepinfra')) {
      return (
        inputPerM: 0.14,
        outputPerM: 0.28,
        rateDescription: r'DeepSeek / DeepInfra @ $0.14 / $0.28 per 1M',
      );
    }

    // Mistral
    if (provider == LlmProvider.mistral || modelLower.contains('mistral')) {
      if (modelLower.contains('large')) {
        return (
          inputPerM: 2.00,
          outputPerM: 6.00,
          rateDescription: r'Mistral Large @ $2.00 / $6.00 per 1M',
        );
      }
      return (
        inputPerM: 0.40,
        outputPerM: 1.20,
        rateDescription: r'Mistral Medium @ $0.40 / $1.20 per 1M',
      );
    }

    // Claude / Anthropic
    if (provider == LlmProvider.claude || modelLower.contains('claude')) {
      if (modelLower.contains('sonnet')) {
        return (
          inputPerM: 3.00,
          outputPerM: 15.00,
          rateDescription: r'Claude 3.5 Sonnet @ $3.00 / $15.00 per 1M',
        );
      } else if (modelLower.contains('haiku')) {
        return (
          inputPerM: 0.80,
          outputPerM: 4.00,
          rateDescription: r'Claude 3.5 Haiku @ $0.80 / $4.00 per 1M',
        );
      }
      return (
        inputPerM: 3.00,
        outputPerM: 15.00,
        rateDescription: r'Anthropic Claude @ $3.00 / $15.00 per 1M',
      );
    }

    // Gemini
    if (provider == LlmProvider.gemini || modelLower.contains('gemini')) {
      return (
        inputPerM: 0.075,
        outputPerM: 0.30,
        rateDescription: r'Google Gemini 1.5 Flash @ $0.075 / $0.30 per 1M',
      );
    }

    // OpenAI
    if (provider == LlmProvider.openai || modelLower.contains('gpt-')) {
      if (modelLower.contains('gpt-4o-mini')) {
        return (
          inputPerM: 0.15,
          outputPerM: 0.60,
          rateDescription: r'OpenAI GPT-4o-mini @ $0.15 / $0.60 per 1M',
        );
      }
      return (
        inputPerM: 2.50,
        outputPerM: 10.00,
        rateDescription: r'OpenAI GPT-4o @ $2.50 / $10.00 per 1M',
      );
    }

    // Unknown or unlisted model: do not invent default price!
    return null;
  }

  /// Attempts to fetch live pricing from OpenRouter public API if static rates are null.
  static Future<({double inputPerM, double outputPerM, String rateDescription})?> getRatesAsync(
    LlmConfig config,
  ) async {
    final staticRate = getRates(config);
    if (staticRate != null) return staticRate;

    // Try fetching from public OpenRouter models API
    try {
      if (_liveModelsCache == null ||
          _liveModelsFetchedAt == null ||
          DateTime.now().difference(_liveModelsFetchedAt!) > _liveModelsTtl) {
        final response = await http
            .get(Uri.parse('https://openrouter.ai/api/v1/models'))
            .timeout(const Duration(seconds: 4));
        if (response.statusCode == 200) {
          final decoded = jsonDecode(response.body);
          if (decoded is Map<String, dynamic> && decoded['data'] is List) {
            _liveModelsCache = decoded['data'] as List;
            _liveModelsFetchedAt = DateTime.now();
          }
        }
      }

      if (_liveModelsCache != null && _liveModelsCache!.isNotEmpty) {
        final modelLower = config.model.toLowerCase();
        final baseModel = modelLower.contains('/') ? modelLower.split('/').last : modelLower;

        for (final item in _liveModelsCache!) {
          if (item is! Map<String, dynamic>) continue;
          final id = (item['id'] ?? '').toString().toLowerCase();
          final shortId = id.contains('/') ? id.split('/').last : id;
          final name = (item['name'] ?? '').toString().toLowerCase();

          if (shortId == baseModel || id == modelLower || name.contains(baseModel)) {
            final pricing = item['pricing'];
            if (pricing is Map<String, dynamic>) {
              final prompt = double.tryParse((pricing['prompt'] ?? pricing['input'] ?? '').toString());
              final completion = double.tryParse((pricing['completion'] ?? pricing['output'] ?? '').toString());
              if (prompt != null && completion != null) {
                final inPerM = prompt * 1000000.0;
                final outPerM = completion * 1000000.0;
                return (
                  inputPerM: inPerM,
                  outputPerM: outPerM,
                  rateDescription: 'Public avg @ \$${inPerM.toStringAsFixed(2)} / \$${outPerM.toStringAsFixed(2)} per 1M',
                );
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

  /// Calculates total estimated cost in USD, or returns `null` if pricing is unavailable.
  double? calculateEstimatedCost(
    LlmConfig config, {
    ({double inputPerM, double outputPerM, String rateDescription})? rates,
  }) {
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
    ({double inputPerM, double outputPerM, String rateDescription})? rates,
  }) {
    final resolvedRates = rates ?? getRates(config);
    final totalCost = calculateEstimatedCost(config, rates: resolvedRates);
    final displayName = modelDisplayName ?? '${config.provider.displayName} / ${config.model}';

    final buffer = StringBuffer();
    buffer.writeln(TerminalPrinter.bold('─── Token Usage & Estimated Cost ───'));
    buffer.writeln('  Active LLM       : $displayName (${config.provider.displayName} / ${config.model})');
    buffer.writeln(
      '  Pricing Rate     : ${resolvedRates?.rateDescription ?? TerminalPrinter.dim("Not available (free or unlisted model)")}',
    );
    buffer.writeln('  Turns Completed  : $turnsCount');
    buffer.writeln('  Input Tokens     : ${_formatNumber(promptTokens)}');
    buffer.writeln('  Output Tokens    : ${_formatNumber(completionTokens)}');
    buffer.writeln('  Total Tokens     : ${TerminalPrinter.cyan(_formatNumber(totalTokens))}');
    if (totalCost != null) {
      buffer.writeln(
        '  Estimated Cost   : ${TerminalPrinter.bold(TerminalPrinter.green('\$${totalCost.toStringAsFixed(6)}'))}',
      );
    } else {
      buffer.writeln(
        '  Estimated Cost   : ${TerminalPrinter.dim("Not available")}',
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
    return formatReport(config, modelDisplayName: modelDisplayName, rates: resolvedRates);
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
