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
