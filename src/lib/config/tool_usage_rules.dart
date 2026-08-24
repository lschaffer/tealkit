/// Simplified tool usage rules — no plugin-specific assets needed.
/// Provides basic tool guidance for the LLM.
class ToolUsageRules {
  static String pluginName = '';

  static Future<String> getSystemPrompt() async => '';
  static Future<String> getCriticalRules() async => '';
  static Future<String> getWorkflowInstructions() async => '';
  static Future<String> getExampleWorkflows() async => '';
  static Future<String> getCommonErrors() async => '';
  static Future<String> getMatplotlibRules() async => '';
  static Future<String> getLocationRules() async => '';
  static Future<String> getDeviceConfigRules() async => '';
  static Future<String> getToolCallFormat() async => '';
  static Future<String> getCorrectExamples() async => '';
  static Future<String> getWrongExamples() async => '';
  static Future<String> getMatplotlibExample() async => '';
  static Future<String> getNonToolExamples() async => '';
  static Future<String> getNewToolsGuide() async => '';
  static Future<String> getParameterDependencyRules() async => '';
  static Future<String> getFileSearchRules() async => '';
  static Future<String> getMeasurementDataRules() async => '';
  static Future<String> getAllInstructions() async => '';
}

/// Strict tool calling completion rules to prevent infinite loops and ensure
/// smaller models stop execution immediately once the user request is satisfied.
const String kToolCallingRulesInstructions = '''### Tool Calling Rules:
1. When you have sufficient data from tool calls to satisfy the user's request, provide the final answer directly to the user.
2. Once the final markdown answer is presented, STOP execution immediately. Do NOT call any further tools, do NOT plan extra steps, and do NOT simulate new user requests.''';

