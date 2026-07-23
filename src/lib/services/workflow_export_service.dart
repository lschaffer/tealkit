import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:yaml/yaml.dart';

import '../models/workflow_task.dart';
import '../repositories/i_task_repository.dart';
import 'app_logger.dart';
import 'llm_settings_service.dart';
import 'settings_vault_service.dart';
import 'py_tool_library_service.dart';
import '../models/py_tool_definition.dart';
import 'server_api_client.dart';

/// Service for exporting and importing Workflows in agentskills.io SKILL.md format.
class WorkflowExportService {
  WorkflowExportService._();

  static final _log = log;

  static const _sensitiveKeys = <String>{
    'api_key',
    'api_password',
    'password',
    'access_token',
    'refresh_token',
    'client_secret',
    'oauth_token',
    'id_token',
    'bearer_token',
    'smithery_api_key',
  };

  static const _capabilityMap = {
    'weather': 'weather_retrieval',
    'gmail': 'email_access',
    'website-search': 'web_search',
    'doc-search': 'document_search',
  };

  /// Sanitizes spaces and special characters for a valid filename.
  static String sanitizeFilename(String name) {
    return name
        .trim()
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '');
  }

  /// Sanitizes a workflow name to a lowercase alphanumeric hyphenated string
  /// compatible with the agentskills.io specification constraints.
  static String sanitizeSkillName(String name) {
    String cleaned = name
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    while (cleaned.startsWith('-')) {
      cleaned = cleaned.substring(1);
    }
    while (cleaned.endsWith('-')) {
      cleaned = cleaned.substring(0, cleaned.length - 1);
    }
    if (cleaned.isEmpty) cleaned = 'skill';
    return cleaned;
  }

  /// Analyzes the workflow to see if it uses any custom Python tools by name/prefix
  static List<PyToolDefinition> _getReferencedPythonTools(WorkflowTask workflow) {
    final referenced = <PyToolDefinition>[];
    final allTools = PyToolLibraryService.instance.tools;
    final targets = [
      workflow.prompt.toLowerCase(),
      if (workflow.description != null) workflow.description!.toLowerCase(),
      ...workflow.agents.map((a) => a.prompt.toLowerCase()),
      ...workflow.agents.map((a) => a.systemPrompt?.toLowerCase() ?? ''),
      ...workflow.agents.map((a) => a.name.toLowerCase()),
      ...workflow.agents.expand((a) => a.mcpTools.map((t) => t.name?.toLowerCase() ?? '')),
    ];

    for (final tool in allTools) {
      final dynName = 'py_${sanitizeSkillName(tool.name)}';
      final cleanDynName = dynName.replaceAll('-', '_');
      final rawName = tool.name.toLowerCase();

      bool isUsed = false;
      for (final target in targets) {
        if (target.contains(dynName.toLowerCase()) ||
            target.contains(cleanDynName.toLowerCase()) ||
            target.contains(rawName)) {
          isUsed = true;
          break;
        }
      }
      if (isUsed) {
        referenced.add(tool);
      }
    }
    return referenced;
  }

  static String _twoDigits(int n) => n >= 10 ? '$n' : '0$n';

  /// Styled dialog for renaming exported files
  static Future<String?> showFilenameDialog({
    required BuildContext context,
    required String title,
    required String defaultFilename,
    required String labelText,
    required String submitButtonText,
  }) async {
    final controller = TextEditingController(text: defaultFilename);
    String? errorText;

    return await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: labelText,
                  errorText: errorText,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final name = controller.text.trim();
                if (name.isEmpty) {
                  setState(() => errorText = 'Filename cannot be empty');
                  return;
                }
                Navigator.pop(ctx, name);
              },
              child: Text(submitButtonText),
            ),
          ],
        ),
      ),
    );
  }

  /// Exports a single workflow task as a Skill.md file or a ZIP bundle if scripts are used.
  static Future<({String? error, String? savedPath})> exportWorkflow(
    BuildContext context,
    WorkflowTask workflow, {
    bool forceZip = false,
  }) async {
    try {
      final pythonTools = _getReferencedPythonTools(workflow);
      final hasScripts = pythonTools.isNotEmpty || forceZip;

      // Step 1: Pick Directory
      final dirPath = await SettingsVaultService.instance.pickExportDirectory();
      if (dirPath == null) {
        return (error: null, savedPath: null); // cancelled
      }

      await Future.delayed(Duration.zero);
      if (!context.mounted) return (error: null, savedPath: null);

      // Step 2: Prompt Filename
      final defaultFilename = hasScripts
          ? '${sanitizeFilename(workflow.name)}_skills.zip'
          : '${sanitizeFilename(workflow.name)}_skills.md';

      final filename = await showFilenameDialog(
        context: context,
        title: 'Export Workflow to Skill',
        defaultFilename: defaultFilename,
        labelText: 'Filename',
        submitButtonText: 'Export',
      );
      if (filename == null) {
        return (error: null, savedPath: null); // cancelled
      }

      final String finalFilename;
      if (hasScripts) {
        finalFilename = filename.endsWith('.zip') ? filename : '$filename.zip';
      } else {
        finalFilename = filename.endsWith('.md') ? filename : '$filename.md';
      }
      final filePath = '$dirPath${Platform.pathSeparator}$finalFilename';

      final skillContent = _generateSkillContent(workflow, pythonTools);

      if (finalFilename.endsWith('.zip')) {
        // Zip mode: bundle SKILL.md and scripts/ folder
        final archive = Archive();
        final folderPrefix = '${sanitizeSkillName(workflow.name)}/';
        
        // Add SKILL.md
        final skillBytes = utf8.encode(skillContent);
        archive.addFile(ArchiveFile('${folderPrefix}SKILL.md', skillBytes.length, skillBytes));

        // Add scripts/
        for (final tool in pythonTools) {
          final scriptName = sanitizeSkillName(tool.name);
          final codeBytes = utf8.encode(tool.code);
          archive.addFile(ArchiveFile('${folderPrefix}scripts/$scriptName.py', codeBytes.length, codeBytes));

          if (tool.requirements.trim().isNotEmpty) {
            final reqBytes = utf8.encode(tool.requirements);
            archive.addFile(ArchiveFile('${folderPrefix}scripts/${scriptName}_requirements.txt', reqBytes.length, reqBytes));
          }
        }

        final zipBytes = ZipEncoder().encode(archive);
        await File(filePath).writeAsBytes(zipBytes);
      } else {
        // Flat markdown mode
        await File(filePath).writeAsString(skillContent);
      }

      _log.info('Workflow skill saved to $filePath');
      return (error: null, savedPath: filePath);
    } catch (e, st) {
      _log.error('Failed to export workflow: $e\n$st');
      return (error: e.toString(), savedPath: null);
    }
  }

  /// Exports all workflows to a folder selected by the user, packaged in a single ZIP.
  static Future<({String? error, int count})> exportAllWorkflows(
    BuildContext context,
    ITaskRepository repo,
  ) async {
    try {
      final workflows = await repo.getAllTasks();
      if (workflows.isEmpty) {
        return (error: 'No workflows to export.', count: 0);
      }

      // Step 1: Pick Directory
      final dirPath = await SettingsVaultService.instance.pickExportDirectory();
      if (dirPath == null) {
        return (error: null, count: 0); // user cancelled
      }

      await Future.delayed(Duration.zero);
      if (!context.mounted) return (error: null, count: 0);

      // Step 2: Prompt Filename
      final now = DateTime.now();
      final defaultFilename = 'tealkit_skills_export_${now.year}${_twoDigits(now.month)}${_twoDigits(now.day)}_${_twoDigits(now.hour)}${_twoDigits(now.minute)}.zip';

      final filename = await showFilenameDialog(
        context: context,
        title: 'Export Workflows to Skills',
        defaultFilename: defaultFilename,
        labelText: 'Filename',
        submitButtonText: 'Export',
      );
      if (filename == null) {
        return (error: null, count: 0); // user cancelled
      }

      final finalFilename = filename.endsWith('.zip') ? filename : '$filename.zip';
      final filePath = '$dirPath${Platform.pathSeparator}$finalFilename';

      final archive = Archive();
      int count = 0;

      for (final workflow in workflows) {
        final pythonTools = _getReferencedPythonTools(workflow);
        final skillContent = _generateSkillContent(workflow, pythonTools);
        final folderName = sanitizeSkillName(workflow.name);
        final folderPrefix = '$folderName/';

        // Add SKILL.md
        final skillBytes = utf8.encode(skillContent);
        archive.addFile(ArchiveFile('${folderPrefix}SKILL.md', skillBytes.length, skillBytes));

        // Add custom scripts if any
        for (final tool in pythonTools) {
          final scriptName = sanitizeSkillName(tool.name);
          final codeBytes = utf8.encode(tool.code);
          archive.addFile(ArchiveFile('${folderPrefix}scripts/$scriptName.py', codeBytes.length, codeBytes));

          if (tool.requirements.trim().isNotEmpty) {
            final reqBytes = utf8.encode(tool.requirements);
            archive.addFile(ArchiveFile('${folderPrefix}scripts/${scriptName}_requirements.txt', reqBytes.length, reqBytes));
          }
        }
        count++;
      }

      final zipBytes = ZipEncoder().encode(archive);
      await File(filePath).writeAsBytes(zipBytes);
      _log.info('Workflow skill batch saved to $filePath');
      return (error: null, count: count);
    } catch (e, st) {
      _log.error('Failed to batch export: $e\n$st');
      return (error: e.toString(), count: 0);
    }
  }

  /// Imports workflows from a TealKit-compatible SKILL.md file or a ZIP of skills.
  static Future<({String? error, List<WorkflowTask>? importedTasks})> importWorkflow(
    BuildContext context,
    ITaskRepository repo, {
    ServerApiClient? serverClient,
  }) async {
    try {
      final picked = await FilePicker.pickFiles(
        dialogTitle: 'Select TealKit Skill File or Zip',
        type: FileType.custom,
        allowedExtensions: ['md', 'zip'],
        allowMultiple: false,
        withData: true,
      );

      if (picked == null || picked.files.isEmpty) {
        return (error: null, importedTasks: null);
      }

      final file = picked.files.first;
      final importedTasks = <WorkflowTask>[];
      final archiveScripts = <String, Map<String, String>>{}; // folderPrefix -> (scriptName -> code/reqs)

      if (file.name.endsWith('.zip')) {
        final List<int> bytes;
        if (file.bytes != null) {
          bytes = file.bytes!;
        } else if (file.path != null) {
          bytes = await File(file.path!).readAsBytes();
        } else {
          return (error: 'Could not read zip file content.', importedTasks: null);
        }

        final archive = ZipDecoder().decodeBytes(bytes);

        // 1. Gather all files
        for (final archiveFile in archive) {
          if (!archiveFile.isFile) continue;
          final normalizedName = archiveFile.name.replaceAll('\\', '/');
          final pathParts = normalizedName.split('/');
          if (pathParts.isEmpty) continue;

          // Detect skill markdown files
          if (normalizedName.endsWith('SKILL.md') || normalizedName.endsWith('.md')) {
            final content = utf8.decode(archiveFile.content as List<int>);
            final task = parseSkillContent(content);
            if (task != null) {
              importedTasks.add(task);
            }
          }

          // Detect scripts
          if (normalizedName.contains('/scripts/')) {
            final folderPrefix = pathParts.first; // top level folder e.g. "battery-check"
            final fileName = pathParts.last;
            final fileContent = utf8.decode(archiveFile.content as List<int>);

            archiveScripts.putIfAbsent(folderPrefix, () => {});
            archiveScripts[folderPrefix]![fileName] = fileContent;
          }
        }

        if (importedTasks.isEmpty) {
          return (error: 'No valid SKILL.md/markdown workflow files found in the zip.', importedTasks: null);
        }
      } else {
        // Single md file
        final String content;
        if (file.bytes != null) {
          content = utf8.decode(file.bytes!);
        } else if (file.path != null) {
          content = await File(file.path!).readAsString();
        } else {
          return (error: 'Could not read file content.', importedTasks: null);
        }

        final task = parseSkillContent(content);
        if (task == null) {
          return (error: 'Failed to parse TealKit compatible SKILL.md format.', importedTasks: null);
        }
        importedTasks.add(task);
      }

      final savedTasks = <WorkflowTask>[];
      final existingTasks = await repo.getAllTasks();

      for (final task in importedTasks) {
        // 1. Handle restoring custom scripts for this workflow
        final folderPrefix = sanitizeSkillName(task.name);
        
        // Check if there are python tool definitions serialized in metadata
        // Since we parse metadata dynamically in _parseSkillContent (where they might already be added to the registry),
        // let's also scan archiveScripts in case of plain physical files.
        final localScripts = archiveScripts[folderPrefix];
        if (localScripts != null) {
          await PyToolLibraryService.instance.load(serverClient);
          for (final entry in localScripts.entries) {
            if (entry.key.endsWith('.py')) {
              final scriptName = entry.key.replaceAll('.py', '');
              final code = entry.value;
              final reqKey = '${scriptName}_requirements.txt';
              final requirements = localScripts[reqKey] ?? '';

              final inputSchema = {
                'type': 'object',
                'properties': {},
              };
              final newTool = PyToolDefinition.create(
                name: scriptName,
                description: 'Imported script tool from skill "${task.name}"',
                inputSchema: inputSchema,
                code: code,
                requirements: requirements,
              );

              final existingTool = PyToolLibraryService.instance.getByName(scriptName);
              final toolToSave = existingTool != null
                  ? PyToolDefinition(
                      id: existingTool.id,
                      name: newTool.name,
                      description: newTool.description,
                      inputSchema: newTool.inputSchema,
                      code: newTool.code,
                      requirements: newTool.requirements,
                      venvReady: false,
                      isActive: newTool.isActive,
                      generationPrompt: newTool.generationPrompt,
                      testArgs: newTool.testArgs,
                      createdAt: existingTool.createdAt,
                      updatedAt: DateTime.now(),
                    )
                  : newTool;
              await PyToolLibraryService.instance.save(toolToSave, serverClient);
            }
          }
        }

        // 2. Overwrite check by name (case-insensitive)
        WorkflowTask? existingMatch;
        for (final existingTask in existingTasks) {
          if (existingTask.name.trim().toLowerCase() == task.name.trim().toLowerCase()) {
            existingMatch = existingTask;
            break;
          }
        }

        if (existingMatch != null) {
          await Future.delayed(Duration.zero);
          if (!context.mounted) continue;

          final confirm = await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => AlertDialog(
              title: const Text('Confirm Overwrite'),
              content: Text('A workflow with the name "${task.name}" already exists. Do you want to overwrite it?'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Overwrite'),
                ),
              ],
            ),
          );

          if (confirm == true) {
            final updatedTask = task.copyWith(id: existingMatch.id);
            await repo.saveTask(updatedTask);
            savedTasks.add(updatedTask);
          }
        } else {
          await repo.saveTask(task);
          savedTasks.add(task);
        }
      }

      return (error: null, importedTasks: savedTasks);
    } catch (e, st) {
      _log.error('Failed to import workflow: $e\n$st');
      return (error: e.toString(), importedTasks: null);
    }
  }

  // ── Private Helpers ────────────────────────────────────────────────────────

  static String _generateSkillContent(WorkflowTask workflow, List<PyToolDefinition> pythonTools) {
    final s = LlmSettingsService.instance;

    // Determine compatibility
    final hasNativeTools = workflow.internalMcps.any((m) => m.enabled && m.mcpType != 'py_bridge');
    final compatibility = hasNativeTools ? 'TealKit-Native' : 'Universal';

    final requiredCapabilities = workflow.internalMcps
        .where((m) => m.enabled && m.mcpType != 'py_bridge')
        .map((m) => _capabilityMap[m.mcpType] ?? m.mcpType)
        .toList();

    final yamlMap = {
      'name': sanitizeSkillName(workflow.name),
      'description': workflow.description ?? '',
      'compatibility': compatibility,
      'metadata': {
        'original_name': workflow.name,
        'author': 'TealKit',
        'required_capabilities': requiredCapabilities,
        'llm_settings': {
          'provider': workflow.llmConfig?.provider ?? s.provider.configKey,
          'model': workflow.llmConfig?.model ?? s.model,
          'temperature': workflow.llmConfig?.temperature ?? s.temperature,
          'max_tokens': workflow.llmConfig?.maxTokens ?? s.maxTokens,
          'is_slm': (workflow.llmConfig?.extraParams['is_slm'] as bool?) ?? s.isSlm,
          'is_multi_modal': (workflow.llmConfig?.extraParams['is_multi_modal'] as bool?) ?? s.isMultiModal,
          'thinking': (workflow.llmConfig?.extraParams['thinking'] as bool?) ?? s.thinking,
          'use_native_tool_call': workflow.llmConfig?.useNativeToolCall ?? s.useNativeToolCall,
          'use_safe_tool_call': (workflow.llmConfig?.extraParams['use_safe_tool_call'] as bool?) ?? s.useSafeToolCall,
          'enable_tool_parameter_auto_recovery': s.enableToolParameterAutoRecovery,
        },
        'mcp_servers': workflow.mcpTools.map((t) => _sanitizeMcpConfig(t.toJson())).toList(),
        'python_tools': pythonTools.map((t) => t.toJson()).toList(),
        'workflow': {
          'prompt': workflow.prompt,
          'chat_mode': workflow.chatMode,
          'stop_after_tool_call': workflow.stopAfterToolCall,
          'agents': workflow.agents.map((a) => {
            'id': a.id,
            'name': a.name,
            'system_prompt': a.systemPrompt ?? '',
            'prompt': a.prompt,
            'chat_mode': a.chatMode,
            'stop_after_tool_call': a.stopAfterToolCall,
            'mcp_tools': a.mcpTools.map((t) => t.name).toList(),
            'internal_mcps': a.internalMcps.map((m) => m.mcpType).toList(),
          }).toList(),
          'edges': workflow.edges.map((e) => {
            'id': e.id,
            'source_agent_id': e.sourceAgentId,
            'variable': e.variable,
            'operator': e.operator,
            'value': e.value,
            'target_agent_id': e.targetAgentId,
          }).toList(),
        }
      }
    };

    final yamlString = _toYaml(yamlMap);

    final markdown = StringBuffer();
    markdown.writeln('---');
    markdown.writeln(yamlString.trim());
    markdown.writeln('---');
    markdown.writeln('# ${workflow.name}');
    markdown.writeln();
    if (workflow.description != null && workflow.description!.isNotEmpty) {
      markdown.writeln(workflow.description);
      markdown.writeln();
    }

    if (workflow.mcpTools.isNotEmpty || pythonTools.isNotEmpty) {
      markdown.writeln('## Required Tools');
      markdown.writeln('You must have the following MCP tools available:');
      for (final t in workflow.mcpTools) {
        markdown.writeln('- `${t.name}` (External MCP Server: ${t.serverUrl})');
      }
      for (final pt in pythonTools) {
        markdown.writeln('- `py_${sanitizeSkillName(pt.name).replaceAll("-", "_")}` (Custom Python Tool)');
      }
      markdown.writeln();
    }

    if (requiredCapabilities.isNotEmpty) {
      markdown.writeln('## Required Capabilities');
      markdown.writeln('This skill requires the following generic capabilities to be provided by the host:');
      for (final cap in requiredCapabilities) {
        markdown.writeln('- `$cap`');
      }
      markdown.writeln();
    }

    markdown.writeln('## Procedure');
    markdown.writeln(workflow.prompt);
    markdown.writeln();

    return markdown.toString();
  }

  static Map<String, dynamic> _sanitizeMcpConfig(Map<String, dynamic> config) {
    final sanitized = <String, dynamic>{};
    for (final entry in config.entries) {
      if (_sensitiveKeys.contains(entry.key)) continue;
      final val = entry.value;
      if (val is Map<String, dynamic>) {
        sanitized[entry.key] = _sanitizeMcpConfig(val);
      } else {
        sanitized[entry.key] = val;
      }
    }
    return sanitized;
  }

  static String _toYaml(dynamic value, {int indent = 0}) {
    final spaces = ' ' * indent;
    if (value is Map) {
      final buffer = StringBuffer();
      value.forEach((key, val) {
        if (val == null) return;
        if (val is Map || val is List) {
          buffer.writeln('$spaces$key:');
          buffer.write(_toYaml(val, indent: indent + 2));
        } else {
          buffer.writeln('$spaces$key: ${_escapeYamlValue(val)}');
        }
      });
      return buffer.toString();
    } else if (value is List) {
      final buffer = StringBuffer();
      for (final item in value) {
        if (item is Map) {
          final entrySpaces = ' ' * indent;
          final mapStr = _toYaml(item, indent: indent + 2).trimLeft();
          buffer.writeln('$entrySpaces- $mapStr');
        } else {
          buffer.writeln('${' ' * indent}- ${_escapeYamlValue(item)}');
        }
      }
      return buffer.toString();
    } else {
      return _escapeYamlValue(value);
    }
  }

  static String _escapeYamlValue(dynamic value) {
    if (value is String) {
      if (value.contains('\n') || value.contains('"') || value.contains(':') || value.contains('[') || value.contains(']')) {
        return jsonEncode(value);
      }
      return '"$value"';
    }
    return value.toString();
  }

  static dynamic _getValue(YamlMap doc, String key) {
    if (doc.containsKey(key)) {
      return doc[key];
    }
    final metadata = doc['metadata'];
    if (metadata is YamlMap && metadata.containsKey(key)) {
      return metadata[key];
    }
    return null;
  }

  static String? _parseMarkdownH1(String content) {
    for (final line in content.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith('# ')) {
        return trimmed.substring(2).trim();
      }
    }
    return null;
  }

  static WorkflowTask? parseSkillContent(String content) {
    final lines = content.split('\n');
    if (lines.isEmpty || lines.first.trim() != '---') {
      return null;
    }

    final yamlLines = <String>[];
    int dashIndex = -1;
    for (int i = 1; i < lines.length; i++) {
      if (lines[i].trim() == '---') {
        dashIndex = i;
        break;
      }
      yamlLines.add(lines[i]);
    }

    if (dashIndex == -1) return null;

    final yamlString = yamlLines.join('\n');
    final doc = loadYaml(yamlString);
    if (doc is! YamlMap) return null;

    final metadata = doc['metadata'] as YamlMap?;
    final name = metadata?['original_name']?.toString() ?? doc['name']?.toString() ?? _parseMarkdownH1(content) ?? 'Imported Skill';
    final description = doc['description']?.toString();

    // Parse custom python scripts if serialized
    final pyToolsData = metadata?['python_tools'];
    if (pyToolsData is YamlList) {
      Future.microtask(() async {
        await PyToolLibraryService.instance.load();
        for (final pt in pyToolsData) {
          if (pt is YamlMap) {
            // Reconstruct PyToolDefinition from YAML
            final Map<String, dynamic> schema;
            final rawSchema = pt['inputSchema'];
            if (rawSchema is YamlMap) {
              // Convert YamlMap to regular Map
              schema = jsonDecode(jsonEncode(rawSchema)) as Map<String, dynamic>;
            } else {
              schema = {};
            }

            final tool = PyToolDefinition(
              id: pt['id']?.toString() ?? pt['name']?.toString() ?? 'imported',
              name: pt['name']?.toString() ?? 'tool',
              description: pt['description']?.toString() ?? '',
              inputSchema: schema,
              code: pt['code']?.toString() ?? '',
              requirements: pt['requirements']?.toString() ?? '',
              venvReady: false,
              isActive: pt['isActive'] as bool? ?? true,
              generationPrompt: pt['generationPrompt']?.toString() ?? '',
              testArgs: pt['testArgs']?.toString() ?? '',
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
            );
            await PyToolLibraryService.instance.save(tool);
          }
        }
      });
    }

    // Parse LLM
    TaskLlmConfig? llmConfig;
    final llm = _getValue(doc, 'llm_settings');
    if (llm is YamlMap) {
      llmConfig = TaskLlmConfig(
        provider: llm['provider']?.toString() ?? '',
        model: llm['model']?.toString() ?? '',
        temperature: (llm['temperature'] as num?)?.toDouble() ?? 0.2,
        maxTokens: (llm['max_tokens'] as int?) ?? 0,
        extraParams: {
          'is_slm': llm['is_slm'] as bool? ?? false,
          'is_multi_modal': llm['is_multi_modal'] as bool? ?? true,
          'thinking': llm['thinking'] as bool? ?? false,
          'use_native_tool_call': llm['use_native_tool_call'] as bool? ?? true,
          'use_safe_tool_call': llm['use_safe_tool_call'] as bool? ?? false,
        },
      );
    }

    // Parse MCP Servers & Hermes / TealKit toolset requirements
    final mcpTools = <McpToolConfig>[];
    final servers = _getValue(doc, 'mcp_servers');
    if (servers is YamlList) {
      for (final s in servers) {
        if (s is YamlMap) {
          mcpTools.add(McpToolConfig(
            serverUrl: s['server_url']?.toString() ?? 'http://localhost:8000',
            name: s['name']?.toString() ?? 'mcp_server',
            description: s['description']?.toString(),
            mcpEndpoint: s['mcp_endpoint']?.toString() ?? '/mcp',
            apiKey: s['api_key']?.toString(),
          ));
        }
      }
    }

    final hermesMap = metadata?['hermes'];
    final hermesToolsets = hermesMap is YamlMap ? hermesMap['requires_toolsets'] : null;
    final reqCaps = metadata?['required_capabilities'];

    void addRequiredTool(String name) {
      final trimmed = name.trim();
      if (trimmed.isNotEmpty && !mcpTools.any((t) => t.name == trimmed)) {
        mcpTools.add(McpToolConfig(
          serverUrl: 'capability://$trimmed',
          name: trimmed,
          description: 'Required tool capability: $trimmed',
        ));
      }
    }

    if (hermesToolsets is YamlList) {
      for (final item in hermesToolsets) {
        addRequiredTool(item.toString());
      }
    }
    if (reqCaps is YamlList) {
      for (final item in reqCaps) {
        addRequiredTool(item.toString());
      }
    }

    // Parse Workflow details
    final workflowNode = _getValue(doc, 'workflow');
    final agents = <Agent>[];
    final edges = <Edge>[];
    String prompt = '';
    bool chatMode = false;
    bool stopAfterToolCall = false;

    if (workflowNode is YamlMap) {
      prompt = workflowNode['prompt']?.toString() ?? '';
      chatMode = workflowNode['chat_mode'] as bool? ?? false;
      stopAfterToolCall = workflowNode['stop_after_tool_call'] as bool? ?? false;

      final yamlAgents = workflowNode['agents'];
      if (yamlAgents is YamlList) {
        for (final a in yamlAgents) {
          if (a is YamlMap) {
            agents.add(Agent(
              id: a['id']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString(),
              name: a['name']?.toString() ?? 'Agent',
              systemPrompt: a['system_prompt']?.toString(),
              prompt: a['prompt']?.toString() ?? '',
              chatMode: a['chat_mode'] as bool? ?? false,
              stopAfterToolCall: a['stop_after_tool_call'] as bool? ?? false,
              mcpTools: (a['mcp_tools'] as YamlList?)?.map((name) {
                return mcpTools.firstWhere(
                  (t) => t.name == name.toString(),
                  orElse: () => McpToolConfig(
                    serverUrl: 'http://localhost:8000',
                    name: name.toString(),
                  ),
                );
              }).toList() ?? [],
            ));
          }
        }
      }

      final yamlEdges = workflowNode['edges'];
      if (yamlEdges is YamlList) {
        for (final e in yamlEdges) {
          if (e is YamlMap) {
            edges.add(Edge(
              id: e['id']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString(),
              sourceAgentId: e['source_agent_id']?.toString() ?? '',
              variable: e['variable']?.toString() ?? '',
              operator: e['operator']?.toString() ?? '',
              value: e['value']?.toString() ?? '',
              targetAgentId: e['target_agent_id']?.toString() ?? '',
            ));
          }
        }
      }
    }

    // Extract the markdown body (everything after the closing ---) as skill
    // context. For "Hermes-style" skills (e.g. docker-skills.md) that have no
    // workflow block this body IS the instructional system prompt that should
    // be injected when the skill is loaded into the Playground.
    // For skills that already define system_prompt inside workflow.agents we
    // leave systemPrompt null so the agent-level value takes priority.
    final bool hasAgentSystemPrompt =
        agents.any((a) => (a.systemPrompt?.isNotEmpty ?? false));
    String? skillBodySystemPrompt;
    if (!hasAgentSystemPrompt && workflowNode == null) {
      // Parse body: everything after the second '---' line
      final closingDash = dashIndex; // set earlier when parsing YAML
      final bodyLines = lines.sublist(closingDash + 1);
      final body = bodyLines.join('\n').trim();
      if (body.isNotEmpty) {
        skillBodySystemPrompt = body;
      }
    }

    return WorkflowTask(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      description: description,
      systemPrompt: skillBodySystemPrompt,
      prompt: prompt,
      chatMode: chatMode,
      stopAfterToolCall: stopAfterToolCall,
      llmConfig: llmConfig,
      mcpTools: mcpTools,
      executionPlan: const ExecutionPlan(cronExpression: '@manual'),
      agents: agents,
      edges: edges,
    );
  }

  /// Parses a file (either .zip containing skills.md/SKILL.md or a single .md file)
  /// and returns the parsed [WorkflowTask] after saving and synchronizing any included scripts.
  /// Throws descriptive exceptions on error.
  static Future<WorkflowTask> parseWorkflowFile({
    required List<int> bytes,
    required String filename,
    ServerApiClient? serverClient,
  }) async {
    final nameLower = filename.toLowerCase();
    if (nameLower.endsWith('.zip')) {
      final archive = ZipDecoder().decodeBytes(bytes);
      ArchiveFile? skillFile;
      final archiveScripts = <String, Map<String, String>>{}; // folderPrefix -> (scriptName -> code/reqs)

      for (final f in archive) {
        if (!f.isFile) continue;
        final normalizedName = f.name.replaceAll('\\', '/');
        final pathParts = normalizedName.split('/');
        if (pathParts.isEmpty) continue;

        final baseName = pathParts.last.toLowerCase();
        if (baseName == 'skill.md' || baseName == 'skills.md') {
          skillFile = f;
        }

        // Detect scripts
        if (normalizedName.contains('/scripts/')) {
          final folderPrefix = pathParts.first; // top level folder e.g. "battery-check"
          final fileName = pathParts.last;
          final fileContent = utf8.decode(f.content as List<int>);

          archiveScripts.putIfAbsent(folderPrefix, () => {});
          archiveScripts[folderPrefix]![fileName] = fileContent;
        }
      }

      if (skillFile == null) {
        for (final f in archive) {
          if (!f.isFile) continue;
          if (f.name.toLowerCase().endsWith('.md')) {
            skillFile = f;
            break;
          }
        }
      }

      if (skillFile == null) {
        throw Exception('Zip file does not contain skills.md or SKILL.md');
      }

      final content = utf8.decode(skillFile.content as List<int>);
      final task = parseSkillContent(content);
      if (task == null) {
        throw Exception('Failed to parse skills.md inside the zip. Invalid format.');
      }

      // Handle restoring custom scripts for this workflow
      final folderPrefix = sanitizeSkillName(task.name);
      final localScripts = archiveScripts[folderPrefix];
      if (localScripts != null) {
        await PyToolLibraryService.instance.load(serverClient);
        for (final entry in localScripts.entries) {
          if (entry.key.endsWith('.py')) {
            final scriptName = entry.key.replaceAll('.py', '');
            final code = entry.value;
            final reqKey = '${scriptName}_requirements.txt';
            final requirements = localScripts[reqKey] ?? '';

            final inputSchema = {
              'type': 'object',
              'properties': {},
            };
            final newTool = PyToolDefinition.create(
              name: scriptName,
              description: 'Imported script tool from skill "${task.name}"',
              inputSchema: inputSchema,
              code: code,
              requirements: requirements,
            );

            final existingTool = PyToolLibraryService.instance.getByName(scriptName);
            final toolToSave = existingTool != null
                ? PyToolDefinition(
                    id: existingTool.id,
                    name: newTool.name,
                    description: newTool.description,
                    inputSchema: newTool.inputSchema,
                    code: newTool.code,
                    requirements: newTool.requirements,
                    venvReady: false,
                    isActive: newTool.isActive,
                    generationPrompt: newTool.generationPrompt,
                    testArgs: newTool.testArgs,
                    createdAt: existingTool.createdAt,
                    updatedAt: DateTime.now(),
                  )
                : newTool;
            await PyToolLibraryService.instance.save(toolToSave, serverClient);
          }
        }
      }

      return task;
    } else if (nameLower.endsWith('.md')) {
      final content = utf8.decode(bytes);
      final task = parseSkillContent(content);
      if (task == null) {
        throw Exception('Failed to parse skill markdown file. Missing or invalid YAML frontmatter.');
      }
      return task;
    } else {
      throw Exception('Unsupported file type. Please select a .zip or .md file.');
    }
  }
}
