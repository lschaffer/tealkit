import 'dart:convert';
import 'package:tealkit_api/tealkit_api.dart';

/// Represents an executable TealKit workflow exposed to MCP clients.
class TealKitWorkflow {
  final String id;
  final String name;
  final String description;
  final List<WorkflowVariable> variables;
  final Future<String> Function(Map<String, dynamic> args) runner;

  TealKitWorkflow({
    required this.id,
    required this.name,
    required this.description,
    this.variables = const [],
    required this.runner,
  });

  /// Factory creating [TealKitWorkflow] from a remote [WorkflowTask].
  factory TealKitWorkflow.fromTask(
    WorkflowTask task,
    Future<String> Function(Map<String, dynamic> args) runner,
  ) {
    return TealKitWorkflow(
      id: task.id,
      name: task.name,
      description: task.description ?? 'TealKit remote task: ${task.name}',
      variables: [
        WorkflowVariable(
          key: 'payload',
          description: 'Input arguments or context JSON for the workflow task',
          type: 'string',
          required: false,
        ),
      ],
      runner: runner,
    );
  }
}

/// Variable/parameter definition for an MCP workflow tool.
class WorkflowVariable {
  final String key;
  final String description;
  final String type; // 'string', 'number', 'boolean', 'array', 'object'
  final bool required;
  final dynamic defaultValue;

  WorkflowVariable({
    required this.key,
    required this.description,
    this.type = 'string',
    this.required = true,
    this.defaultValue,
  });
}

/// Dynamic JSON Schema generator compliant with the Model Context Protocol (MCP) tool specification.
class WorkflowSchemaGenerator {
  /// Sanitizes workflow names into valid MCP tool identifiers: `^[a-zA-Z0-9_-]{1,64}$`.
  static String sanitizeToolName(String name) {
    var sanitized = name
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'_+'), '_');

    while (sanitized.startsWith('_')) {
      sanitized = sanitized.substring(1);
    }
    while (sanitized.endsWith('_')) {
      sanitized = sanitized.substring(0, sanitized.length - 1);
    }
    if (sanitized.isEmpty) {
      sanitized = 'workflow';
    }

    final toolName = 'wf_$sanitized';
    return toolName.length > 64 ? toolName.substring(0, 64) : toolName;
  }

  /// Converts a [TealKitWorkflow] into an MCP tool definition map.
  static Map<String, dynamic> toMcpTool(TealKitWorkflow workflow) {
    final properties = <String, dynamic>{};
    final requiredKeys = <String>[];

    for (final v in workflow.variables) {
      properties[v.key] = {
        'type': v.type,
        'description': v.description,
        if (v.defaultValue != null) 'default': v.defaultValue,
      };
      if (v.required) {
        requiredKeys.add(v.key);
      }
    }

    // Default fallback property if the workflow defines no explicit parameters
    if (properties.isEmpty) {
      properties['input'] = {
        'type': 'string',
        'description': 'Input prompt, arguments, or context payload for this workflow',
      };
    }

    return {
      'name': sanitizeToolName(workflow.name),
      'description': workflow.description.isNotEmpty
          ? workflow.description
          : 'Runs TealKit workflow: ${workflow.name}',
      'inputSchema': {
        'type': 'object',
        'properties': properties,
        'required': requiredKeys.isNotEmpty
            ? requiredKeys
            : (properties.containsKey('input') ? ['input'] : []),
      },
    };
  }
}
