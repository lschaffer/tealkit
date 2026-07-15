import 'dart:convert';

import 'package:uuid/uuid.dart';

/// Describes a user-generated Python tool stored in DuckDB + on disk.
///
/// Each tool lives in its own folder:
///   app-support/py-tools/id/
///     main.py           – generated Python script (JSON-line stdio protocol)
///     requirements.txt  – pip dependencies
///     .venv/            – virtual environment (created during init)
///     .ready            – marker file: present once init succeeded
class PyToolDefinition {
  final String id;
  final String name;
  final String description;

  /// MCP-style inputSchema for the tool's single "execute" call.
  final Map<String, dynamic> inputSchema;

  /// Content of main.py.
  final String code;

  /// Content of requirements.txt (may be empty / just stdlib).
  final String requirements;

  /// Whether the .venv has been successfully initialised.
  final bool venvReady;

  final bool isActive;

  /// The user prompt that triggered LLM generation.
  final String generationPrompt;

  /// Last test args JSON string used in the test-run panel.
  final String testArgs;

  final DateTime createdAt;
  final DateTime updatedAt;

  const PyToolDefinition({
    required this.id,
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.code,
    required this.requirements,
    required this.venvReady,
    required this.isActive,
    required this.generationPrompt,
    this.testArgs = '',
    required this.createdAt,
    required this.updatedAt,
  });

  factory PyToolDefinition.create({
    required String name,
    required String description,
    required Map<String, dynamic> inputSchema,
    required String code,
    String requirements = '',
    String generationPrompt = '',
    String testArgs = '',
    bool isActive = true,
  }) {
    final now = DateTime.now();
    return PyToolDefinition(
      id: const Uuid().v4(),
      name: name,
      description: description,
      inputSchema: Map<String, dynamic>.from(inputSchema),
      code: code,
      requirements: requirements,
      venvReady: false,
      isActive: isActive,
      generationPrompt: generationPrompt,
      testArgs: testArgs,
      createdAt: now,
      updatedAt: now,
    );
  }

  PyToolDefinition copyWith({
    String? name,
    String? description,
    Map<String, dynamic>? inputSchema,
    String? code,
    String? requirements,
    bool? venvReady,
    bool? isActive,
    String? generationPrompt,
    String? testArgs,
  }) {
    return PyToolDefinition(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      inputSchema: inputSchema ?? this.inputSchema,
      code: code ?? this.code,
      requirements: requirements ?? this.requirements,
      venvReady: venvReady ?? this.venvReady,
      isActive: isActive ?? this.isActive,
      generationPrompt: generationPrompt ?? this.generationPrompt,
      testArgs: testArgs ?? this.testArgs,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'inputSchema': inputSchema,
    'code': code,
    'requirements': requirements,
    'venvReady': venvReady,
    'isActive': isActive,
    'generationPrompt': generationPrompt,
    'testArgs': testArgs,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory PyToolDefinition.fromJson(Map<String, dynamic> json) {
    Map<String, dynamic> schema;
    final raw = json['inputSchema'];
    if (raw is Map<String, dynamic>) {
      schema = raw;
    } else if (raw is String) {
      schema = (jsonDecode(raw) as Map<String, dynamic>?) ?? {};
    } else {
      schema = {};
    }

    return PyToolDefinition(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String? ?? '',
      inputSchema: schema,
      code: json['code'] as String? ?? '',
      requirements: json['requirements'] as String? ?? '',
      venvReady: json['venvReady'] as bool? ?? false,
      isActive: json['isActive'] as bool? ?? true,
      generationPrompt: json['generationPrompt'] as String? ?? '',
      testArgs: json['testArgs'] as String? ?? '',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? DateTime.now(),
    );
  }
}
