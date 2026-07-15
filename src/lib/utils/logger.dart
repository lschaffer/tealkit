import '../services/app_logger.dart' as app_log;

/// Global logger instance compatible with thiesai code that uses `talker.xxx()`
final _appLog = app_log.log;
final talker = _TalkerBridge();

class _TalkerBridge {
  void info(String message) => _appLog.info(message);
  void debug(String message) => _appLog.verbose(message);
  void warning(String message) => _appLog.warning(message);
  void error(String message, [Object? error, StackTrace? stackTrace]) => _appLog.error(message, error, stackTrace);
  void verbose(String message) => _appLog.verbose(message);
  void good(String message) => _appLog.info(message);
  void log(String message) => _appLog.info(message);
}

/// Mixin providing structured logging methods for services.
/// Replaces ai_chat_core logging functionality.
mixin ServiceLogging {
  void logLLMRequest(String details) {
    talker.info('[LLM Request] $details');
  }

  void logLLMResponse(String details, {int? toolCallCount}) {
    final suffix = toolCallCount != null ? ' (tools: $toolCallCount)' : '';
    talker.info('[LLM Response] ${details.length > 100 ? '${details.substring(0, 100)}...' : details}$suffix');
  }

  void logWorkflowStep(String step, String message) {
    talker.info('[Workflow: $step] $message');
  }

  void logToolCall(String toolName, dynamic arguments) {
    talker.info('[Tool Call: $toolName] $arguments');
  }

  void logToolResult(String toolName, String details, {bool? isError}) {
    final prefix = isError == true ? '❌' : '✅';
    talker.info('$prefix [Tool Result: $toolName] ${details.length > 100 ? '${details.substring(0, 100)}...' : details}');
  }
}
