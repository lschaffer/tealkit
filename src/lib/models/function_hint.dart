import 'package:uuid/uuid.dart';

/// Represents a procedural skill document for a single MCP tool.
///
/// A skill tells the LLM *when* and *how* to use the tool effectively.
/// Two variants are stored:
///   • [skillText]    — rich, detailed guide for large models (≥ 7 B)
///   • [skillTextSlm] — compact, token-minimal guide for small models (< 7 B)
class FunctionHint {
  final String id;

  /// The MCP tool name this skill is for, e.g. `search_gmail`.
  final String toolName;

  /// The MCP server type (group), e.g. `gmail`, `chart`, `js_bridge`.
  final String mcpType;

  /// Full skill text for large models (no hard token limit).
  final String skillText;

  /// Compact skill text for SLM / embedded models (< 7 B).
  final String skillTextSlm;

  /// Whether this skill is injected into system prompts.
  final bool isEnabled;

  /// True when the user has manually edited/replaced the generated text.
  final bool isCustom;

  final DateTime generatedAt;
  final DateTime updatedAt;

  const FunctionHint({
    required this.id,
    required this.toolName,
    required this.mcpType,
    required this.skillText,
    required this.skillTextSlm,
    this.isEnabled = true,
    this.isCustom = false,
    required this.generatedAt,
    required this.updatedAt,
  });

  factory FunctionHint.create({
    required String toolName,
    required String mcpType,
    required String skillText,
    required String skillTextSlm,
    bool isEnabled = true,
  }) {
    final now = DateTime.now();
    return FunctionHint(
      id: const Uuid().v4(),
      toolName: toolName,
      mcpType: mcpType,
      skillText: skillText,
      skillTextSlm: skillTextSlm,
      isEnabled: isEnabled,
      isCustom: false,
      generatedAt: now,
      updatedAt: now,
    );
  }

  FunctionHint copyWith({String? skillText, String? skillTextSlm, bool? isEnabled, bool? isCustom}) {
    return FunctionHint(
      id: id,
      toolName: toolName,
      mcpType: mcpType,
      skillText: skillText ?? this.skillText,
      skillTextSlm: skillTextSlm ?? this.skillTextSlm,
      isEnabled: isEnabled ?? this.isEnabled,
      isCustom: isCustom ?? this.isCustom,
      generatedAt: generatedAt,
      updatedAt: DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'tool_name': toolName,
    'mcp_type': mcpType,
    'skill_text': skillText,
    'skill_text_slm': skillTextSlm,
    'is_enabled': isEnabled,
    'is_custom': isCustom,
    'generated_at': generatedAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };

  factory FunctionHint.fromJson(Map<String, dynamic> json) => FunctionHint(
    id: json['id'] as String,
    toolName: json['tool_name'] as String,
    mcpType: json['mcp_type'] as String,
    skillText: json['skill_text'] as String,
    skillTextSlm: json['skill_text_slm'] as String,
    isEnabled: (json['is_enabled'] as bool?) ?? true,
    isCustom: (json['is_custom'] as bool?) ?? false,
    generatedAt: DateTime.tryParse(json['generated_at'] as String? ?? '') ?? DateTime.now(),
    updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? '') ?? DateTime.now(),
  );
}
