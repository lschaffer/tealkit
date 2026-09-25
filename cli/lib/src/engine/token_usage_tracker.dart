import 'package:dart_mcp_core/dart_mcp_core.dart';
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

  /// Calculates pricing rates (per 1 million tokens in USD).
  static ({double inputPerM, double outputPerM, String rateDescription}) getRates(
    LlmConfig config,
  ) {
    final modelLower = config.model.toLowerCase();
    final provider = config.provider;

    if (provider == LlmProvider.ollama || provider == LlmProvider.embedded) {
      return (
        inputPerM: 0.0,
        outputPerM: 0.0,
        rateDescription: 'Local model ($provider) — Free (\$0.00)',
      );
    }

    if (provider == LlmProvider.openaiCompatible ||
        modelLower.contains('deepseek') ||
        config.baseUrl.contains('deepinfra')) {
      return (
        inputPerM: 0.14,
        outputPerM: 0.28,
        rateDescription: r'DeepSeek / DeepInfra @ $0.14 / $0.28 per 1M',
      );
    }

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

    if (provider == LlmProvider.gemini || modelLower.contains('gemini')) {
      return (
        inputPerM: 0.075,
        outputPerM: 0.30,
        rateDescription: r'Google Gemini 1.5 Flash @ $0.075 / $0.30 per 1M',
      );
    }

    if (provider == LlmProvider.openai || modelLower.contains('gpt-4')) {
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

    // Default fallback rate (standard affordable API tier)
    return (
      inputPerM: 0.20,
      outputPerM: 0.80,
      rateDescription: r'Standard Tier @ $0.20 / $0.80 per 1M',
    );
  }

  /// Calculates total estimated cost in USD.
  double calculateEstimatedCost(LlmConfig config) {
    final rates = getRates(config);
    final inCost = (promptTokens / 1000000.0) * rates.inputPerM;
    final outCost = (completionTokens / 1000000.0) * rates.outputPerM;
    return inCost + outCost;
  }

  /// Generates a formatted summary string.
  String formatReport(LlmConfig config, {String? modelDisplayName}) {
    final rates = getRates(config);
    final totalCost = calculateEstimatedCost(config);
    final name = modelDisplayName ?? '${config.provider.displayName} / ${config.model}';

    final buffer = StringBuffer();
    buffer.writeln(TerminalPrinter.bold('─── Token Usage & Estimated Cost ───'));
    buffer.writeln('  Active LLM       : $name');
    buffer.writeln('  Pricing Rate     : ${rates.rateDescription}');
    buffer.writeln('  Turns Completed  : $turnsCount');
    buffer.writeln('  Input Tokens     : ${_formatNumber(promptTokens)}');
    buffer.writeln('  Output Tokens    : ${_formatNumber(completionTokens)}');
    buffer.writeln('  Total Tokens     : ${TerminalPrinter.cyan(_formatNumber(totalTokens))}');
    buffer.writeln(
      '  Estimated Cost   : ${TerminalPrinter.bold(TerminalPrinter.green('\$${totalCost.toStringAsFixed(6)}'))}',
    );
    buffer.writeln('────────────────────────────────────');
    return buffer.toString();
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
