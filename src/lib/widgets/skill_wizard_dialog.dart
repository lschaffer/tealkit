import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../config/app_theme.dart';
import '../mcp/internal_mcp_registry.dart';
import '../models/github_mcp_server_definition.dart';
import '../models/mcp_models.dart';
import '../models/workflow_task.dart';
import '../services/external_tools_settings_service.dart';
import '../services/github_mcp_library_service.dart';
import '../services/workflow_export_service.dart';
import '../providers/server_mode_provider.dart';
import '../providers/active_task_provider.dart';
import '../providers/llm_settings_provider.dart';
import '../services/llm_service.dart';

/// Result from the Skill Wizard dialog when "Apply" is pressed.
class SkillWizardResult {
  final String name;
  final String goal;
  final String skillContent;
  final Set<String> selectedMcpTypes;
  final Set<String> selectedExternalServerUrls;
  final bool toolboxEnabled;

  final String description;

  const SkillWizardResult({
    required this.name,
    required this.goal,
    this.description = '',
    required this.skillContent,
    required this.selectedMcpTypes,
    required this.selectedExternalServerUrls,
    this.toolboxEnabled = true,
  });
}

/// A wizard dialog for creating, importing, exporting, and applying
/// AgentSkills.io format skills. Used in both Playground and Workflow Editor.
///
/// Callers can pre-fill fields and provide an [onApply] callback.
/// When opened from a workflow editor agent, pass [prefillGoal] and
/// [prefillTools] to seed the dialog from the agent's context.
class SkillWizardDialog extends ConsumerStatefulWidget {
  /// Pre-filled name.
  final String? prefillName;

  /// Pre-filled goal description.
  final String? prefillGoal;

  /// Pre-filled skill markdown content.
  final String? prefillSkill;

  /// Pre-selected internal MCP types (e.g. 'weather', 'gmail').
  final Set<String>? prefillMcpTypes;

  /// Pre-selected external server URLs.
  final Set<String>? prefillExternalUrls;

  /// Whether toolbox is pre-enabled.
  final bool prefillToolboxEnabled;

  /// Called when the user presses "Apply".
  final void Function(SkillWizardResult result)? onApply;

  /// If true, the "goal" field is read-only (pre-filled from workflow context).
  final bool goalReadOnly;

  /// If true, the "Apply" button is hidden (e.g. when opened from Settings).
  final bool hideApply;

  /// Called when "Save" is pressed (persist mode). If provided, footer shows Save + Cancel instead of Apply.
  final void Function(SkillWizardResult result)? onSave;

  /// Called when "Cancel" is pressed (persist mode).
  final VoidCallback? onCancel;

  const SkillWizardDialog({
    super.key,
    this.prefillName,
    this.prefillGoal,
    this.prefillSkill,
    this.prefillMcpTypes,
    this.prefillExternalUrls,
    this.prefillToolboxEnabled = true,
    this.onApply,
    this.goalReadOnly = false,
    this.hideApply = false,
    this.onSave,
    this.onCancel,
  });

  @override
  ConsumerState<SkillWizardDialog> createState() => _SkillWizardDialogState();
}

class _SkillWizardDialogState extends ConsumerState<SkillWizardDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _goalCtrl;
  late final TextEditingController _skillCtrl;

  late Set<String> _selectedMcpTypes;
  late Set<String> _selectedExternalServerUrls;
  late bool _toolboxEnabled;
  bool _isGenerating = false;

  List<GithubMcpServerDefinition> _remoteGithubMcpServers = const [];

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.prefillName ?? '');
    _goalCtrl = TextEditingController(text: widget.prefillGoal ?? '');
    _skillCtrl = TextEditingController(text: widget.prefillSkill ?? '');
    _selectedMcpTypes = Set<String>.from(widget.prefillMcpTypes ?? {});
    _selectedExternalServerUrls = Set<String>.from(
      widget.prefillExternalUrls ?? {},
    );
    _toolboxEnabled = widget.prefillToolboxEnabled;

    // Eagerly load GitHub MCP servers for the tool selector.
    final isServerMode = ref.read(serverModeProvider).value?.isRemote ?? false;
    Future.microtask(() async {
      final servers = await _getSelectableGithubMcpServers(isServerMode);
      if (mounted) {
        setState(() => _remoteGithubMcpServers = servers);
      }
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _goalCtrl.dispose();
    _skillCtrl.dispose();
    super.dispose();
  }

  Future<List<GithubMcpServerDefinition>> _getSelectableGithubMcpServers(
    bool isServerMode,
  ) async {
    if (!isServerMode) {
      return GithubMcpLibraryService.instance.activeServers;
    }

    final client = ref.read(serverApiClientProvider);
    if (client == null) return const [];

    try {
      final raw = await client.listRegistryServers();
      return raw
          .map(GithubMcpServerDefinition.fromJson)
          .where((s) => s.isInstalled && s.isActive)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  GithubMcpServerDefinition? _findGithubMcpById(String serverId) {
    try {
      return _remoteGithubMcpServers.firstWhere((s) => s.id == serverId);
    } catch (_) {
      return null;
    }
  }

  String _mcpTypeLabel(String type) {
    // Quick labels for built-in MCPs
    switch (type) {
      case 'weather':
        return 'Weather';
      case 'gmail':
        return 'Gmail';
      case 'google_calendar':
        return 'Google Calendar';
      case 'google_drive':
        return 'Google Drive';
      case 'onedrive':
        return 'OneDrive';
      case 'imap':
        return 'IMAP Email';
      case 'ssh':
        return 'Terminal';
      case 'local_shell':
        return 'Local Shell';
      case 'website_search':
        return 'Website Search';
      case 'document':
        return 'Document Search';
      case 'mermaid':
        return 'Mermaid Diagrams';
      case 'chart':
        return 'Charts';
      case 'excel':
        return 'Excel';
      case 'pdf':
        return 'PDF';
      case 'file':
        return 'File System';
      case 'home_assistant':
        return 'Home Assistant';
      case 'traffic':
        return 'Traffic';
      case 'github':
        return 'GitHub';
      case 'toolbox':
        return 'Toolbox';
      default:
        if (type.startsWith('gh_mcp_')) {
          final serverId = type.substring('gh_mcp_'.length);
          final def = _findGithubMcpById(serverId);
          return def?.displayName ?? 'MCP: $serverId';
        }
        return type;
    }
  }

  String _getExternalServerLabel(String url) {
    try {
      final servers = ExternalToolsSettingsService.instance.selectedServers;
      final config = servers.firstWhere(
        (s) => s.serverUrl == url,
        orElse: () => McpToolConfig(serverUrl: url),
      );
      if (config.name != null && config.name!.trim().isNotEmpty) {
        return config.name!.trim();
      }
    } catch (_) {}
    final host = Uri.tryParse(url)?.host;
    if (host != null && host.isNotEmpty) return host;
    return url;
  }

  // ── Export ───────────────────────────────────────────────────────────────

  Future<void> _onExport() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      _showSnack('Please enter a skill name before exporting.');
      return;
    }

    final skillContent = _skillCtrl.text.trim();
    if (skillContent.isEmpty) {
      _showSnack('Skill content is empty. Nothing to export.');
      return;
    }

    // Build a minimal WorkflowTask for export
    final internalMcps = _selectedMcpTypes.map((type) {
      return InternalMcpEntry(
        id: const Uuid().v4(),
        mcpType: type,
        enabled: true,
        initParams: const {},
      );
    }).toList();

    if (!_toolboxEnabled) {
      internalMcps.add(
        InternalMcpEntry(
          id: const Uuid().v4(),
          mcpType: 'toolbox',
          label: 'Toolbox',
          enabled: false,
          initParams: const {},
        ),
      );
    }

    final allServers = ExternalToolsSettingsService.instance.selectedServers;
    final mcpTools = _selectedExternalServerUrls.map((url) {
      return allServers.firstWhere(
        (s) => s.serverUrl == url,
        orElse: () => McpToolConfig(serverUrl: url),
      );
    }).toList();

    final agent = Agent(
      id: const Uuid().v4(),
      name: name,
      prompt: _goalCtrl.text.trim(),
      systemPrompt: skillContent,
      mcpTools: mcpTools,
      internalMcps: internalMcps,
    );

    final workflow = WorkflowTask(
      id: const Uuid().v4(),
      name: name,
      systemPrompt: skillContent,
      prompt: _goalCtrl.text.trim(),
      executionPlan: const ExecutionPlan(cronExpression: ''),
      internalMcps: internalMcps,
      mcpTools: mcpTools,
      agents: [agent],
    );

    final res = await WorkflowExportService.exportWorkflow(context, workflow);
    if (!mounted) return;
    if (res.error != null) {
      _showSnack('Export failed: ${res.error}', isError: true);
    } else if (res.savedPath != null) {
      _showSnack('Skill exported to: ${res.savedPath}');
    }
  }

  // ── Import ───────────────────────────────────────────────────────────────

  Future<void> _onImport() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip', 'md'],
        dialogTitle: 'Import Skill (agentskills.io format)',
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      final List<int> bytes;
      if (file.bytes != null) {
        bytes = file.bytes!;
      } else if (file.path != null) {
        bytes = await File(file.path!).readAsBytes();
      } else {
        throw Exception('Could not read file content.');
      }

      final serverClient =
          (ref.read(serverModeProvider).value?.isRemote ?? false)
          ? ref.read(serverApiClientProvider)
          : null;

      final task = await WorkflowExportService.parseWorkflowFile(
        bytes: bytes,
        filename: file.name,
        serverClient: serverClient,
      );

      setState(() {
        _nameCtrl.text = task.name;
        _goalCtrl.text = '';
        _skillCtrl.text = task.systemPrompt ?? task.prompt;
        _selectedMcpTypes = task.internalMcps
            .where((m) => m.enabled)
            .map((m) => m.mcpType)
            .toSet();
        _selectedExternalServerUrls = task.mcpTools
            .map((t) => t.serverUrl)
            .toSet();
        _toolboxEnabled = !(task.internalMcps.any(
          (m) => m.mcpType == 'toolbox' && !m.enabled,
        ));
      });

      if (mounted) {
        _showSnack('Skill "${task.name}" imported successfully.');
      }
    } catch (e) {
      if (mounted) {
        _showSnack('Import failed: $e', isError: true);
      }
    }
  }

  // ── Generate Skill via LLM ───────────────────────────────────────────────

  void _onSavePressed() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      _showSnack('Please enter a skill name.');
      return;
    }
    final result = SkillWizardResult(
      name: name,
      goal: _goalCtrl.text.trim(),
      description: '',
      skillContent: _skillCtrl.text.trim(),
      selectedMcpTypes: Set<String>.from(_selectedMcpTypes),
      selectedExternalServerUrls: Set<String>.from(
        _selectedExternalServerUrls,
      ),
      toolboxEnabled: _toolboxEnabled,
    );
    widget.onSave?.call(result);
    Navigator.of(context).pop(result);
  }

  Future<void> _doGenerateSkill() async {
    final goal = _goalCtrl.text.trim();
    if (goal.isEmpty) return;

    setState(() => _isGenerating = true);
    try {
      final skillName = _nameCtrl.text.trim();
      final toolNames = <String>[
        ..._selectedMcpTypes,
        ..._selectedExternalServerUrls,
      ];
      final toolsHint = toolNames.isNotEmpty
          ? '\nThe following tools are relevant: ${toolNames.join(', ')}. Include these in requires_toolsets.'
          : '';

      LLMService? llm;

      // 1) Try active task LLM first (playground/workflow editor context)
      final taskState = ref.read(activeTaskProvider);
      final chatService = taskState?.chatService;
      if (chatService != null && chatService.llmService.isConfigured) {
        llm = chatService.llmService;
      }

      // 2) Fall back: configure a new LLMService from LLM1 settings
      if (llm == null || !llm.isConfigured) {
        final settings = ref.read(llmSettingsProvider);
        if (settings.isConfigured) {
          llm = LLMService();
          final provider = settings.provider.configKey;
          final model = settings.model;
          final apiKey = settings.apiKey;
          final baseUrl = settings.baseUrl;
          final effectiveApiKey = apiKey;
          final effectiveBaseUrl = baseUrl;

          try {
            switch (provider.toLowerCase()) {
              case 'gemini':
              case 'google':
                await llm.initializeGemini(
                  apiKey: effectiveApiKey,
                  model: model,
                );
                break;
              case 'openai':
                await llm.initializeOpenAI(
                  apiKey: effectiveApiKey,
                  model: model,
                );
                break;
              case 'claude':
              case 'anthropic':
                await llm.initializeClaude(
                  apiKey: effectiveApiKey,
                  model: model,
                );
                break;
              case 'mistral':
                await llm.initializeOpenAICompatible(
                  baseUrl: effectiveBaseUrl.isNotEmpty
                      ? effectiveBaseUrl
                      : 'https://api.mistral.ai/v1',
                  apiKey: effectiveApiKey,
                  model: model,
                );
                break;
              case 'ollama':
                await llm.initializeOllama(
                  baseUrl: effectiveBaseUrl.isNotEmpty
                      ? effectiveBaseUrl
                      : 'http://localhost:11434/api',
                  model: model,
                );
                break;
              case 'openai_compatible':
                await llm.initializeOpenAICompatible(
                  baseUrl: effectiveBaseUrl,
                  apiKey: effectiveApiKey,
                  model: model,
                );
                break;
              default:
                llm = null;
            }
          } catch (_) {
            llm = null;
          }
        }
      }

      final String result;
      if (llm != null && llm.isConfigured) {
        result = await _callLlmForSkill(llm, goal, skillName, toolsHint);
      } else {
        result = _fallbackTemplate(skillName, goal);
      }

      if (mounted) setState(() => _skillCtrl.text = result);
    } catch (e) {
      _showSnack('Generation failed: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isGenerating = false);
    }
  }

  Future<String> _callLlmForSkill(
    LLMService llm,
    String goal,
    String skillName,
    String toolsHint,
  ) async {
    final metaPrompt =
        'Create a skill in AgentSkills.io format (YAML front matter + markdown body) '
        'for the following goal: "$goal".\n'
        'The skill name MUST be: "$skillName"\n\n'
        'Rules:\n'
        '- The skill must follow the agentskills.io specification:\n'
        '  * YAML front matter with name, description, version, author, license, platforms, metadata.hermes fields\n'
        '  * Markdown body with sections: Overview, When to Use, Prerequisites, Procedure, Pitfalls, Verification\n'
        '- Use exactly "$skillName" as the name field in YAML front matter\n'
        '- The name in YAML must be lowercase alphanumeric hyphenated; sanitize "$skillName" accordingly\n'
        '- Description should be one sentence summarizing the skill, NOT the goal\n'
        '- The Procedure section should contain clear step-by-step instructions\n'
        '- Include concrete command examples and code snippets where appropriate\n'
        '- Include a "Pitfalls" section with common errors in a markdown table\n'
        '- Output ONLY the complete SKILL.md content. No preamble, no explanations.\n'
        '- Start with "---" on the first line.'
        '$toolsHint';

    final response = await llm.generateChatCompletion(
      messages: [
        ChatMessage(
          id: const Uuid().v4(),
          role: ChatRole.system,
          content:
              'You generate high-quality AgentSkills.io skill definitions. Output valid YAML + markdown only.',
          timestamp: DateTime.now(),
        ),
        ChatMessage(
          id: const Uuid().v4(),
          role: ChatRole.user,
          content: metaPrompt,
          timestamp: DateTime.now(),
        ),
      ],
      maxTokens: 2000,
    );
    return response.content.trim();
  }

  String _fallbackTemplate(String skillName, String goal) {
    final safeName = skillName.isNotEmpty
        ? skillName
              .toLowerCase()
              .replaceAll(RegExp(r'[^a-z0-9\s]'), '')
              .replaceAll(RegExp(r'\s+'), '-')
              .trim()
        : goal
              .toLowerCase()
              .replaceAll(RegExp(r'[^a-z0-9\s]'), '')
              .replaceAll(RegExp(r'\s+'), '-')
              .trim();
    final displayName = skillName.isNotEmpty ? skillName : goal;
    return '---\nname: $safeName\ndescription: Skill for: $displayName\nversion: 1.0.0\nauthor: tealkit\nlicense: MIT\nplatforms: [linux, macos, windows, android, ios]\nmetadata:\n  hermes:\n    tags: [skill, automation]\n    category: data\n    requires_toolsets: []\n---\n\n# $displayName\n\n## Overview\nThis skill helps accomplish: $goal\n\n## When to Use\n- When you need to $goal\n\n## Prerequisites\n- Required tools and access\n\n## Procedure\n1. First step\n2. Second step\n3. Third step\n\n## Pitfalls\n| Problem | Cause | Fix |\n|---------|-------|-----|\n| Common issue | Root cause | Solution |\n\n## Verification\n- Check that the expected output is produced\n- Verify results are correct';
  }

  // ── Apply ────────────────────────────────────────────────────────────────

  void _onApply() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      _showSnack('Please enter a skill name.');
      return;
    }

    widget.onApply?.call(
      SkillWizardResult(
        name: name,
        goal: _goalCtrl.text.trim(),
        skillContent: _skillCtrl.text.trim(),
        selectedMcpTypes: Set<String>.from(_selectedMcpTypes),
        selectedExternalServerUrls: Set<String>.from(
          _selectedExternalServerUrls,
        ),
        toolboxEnabled: _toolboxEnabled,
      ),
    );

    Navigator.of(context).pop();
  }

  void _showSnack(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : null,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ── Tool Selection Dialog ────────────────────────────────────────────────

  Future<void> _showToolSelector() async {
    var tempSelection = Set<String>.from(_selectedMcpTypes);
    var tempExternalSelection = Set<String>.from(_selectedExternalServerUrls);
    var tempToolboxEnabled = _toolboxEnabled;

    final globalServers = ExternalToolsSettingsService.instance.selectedServers;
    final Map<String, McpToolConfig> combinedServers = {};
    for (final s in globalServers) {
      combinedServers[s.serverUrl] = s;
    }
    for (final url in _selectedExternalServerUrls) {
      if (!combinedServers.containsKey(url)) {
        combinedServers[url] = McpToolConfig(
          serverUrl: url,
          name: Uri.tryParse(url)?.host ?? url,
        );
      }
    }

    final ghServers = _remoteGithubMcpServers;
    final Map<String, GithubMcpServerDefinition> combinedGhServers = {};
    for (final s in ghServers) {
      combinedGhServers[s.id] = s;
    }
    for (final type in _selectedMcpTypes) {
      if (type.startsWith('gh_mcp_')) {
        final serverId = type.substring('gh_mcp_'.length);
        if (!combinedGhServers.containsKey(serverId)) {
          final def = _findGithubMcpById(serverId);
          combinedGhServers[serverId] =
              def ??
              GithubMcpServerDefinition(
                id: serverId,
                name: 'Remote MCP ($serverId)',
                displayName: 'Remote MCP ($serverId)',
                description: 'Remote GitHub MCP server',
                githubUrl: '',
                language: 'python',
                installType: 'uvx',
                packageName: '',
                createdAt: DateTime.now(),
                isInstalled: true,
                isActive: true,
              );
        }
      }
    }

    final result = await showDialog<(Set<String>, Set<String>, bool)>(
      context: context,
      builder: (ctx) {
        final screenSize = MediaQuery.of(ctx).size;
        final isMobile = screenSize.width < 600;

        return StatefulBuilder(
          builder: (ctx, setDialogState) => Dialog(
            insetPadding: isMobile
                ? EdgeInsets.zero
                : const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
            clipBehavior: Clip.antiAlias,
            shape: isMobile
                ? const RoundedRectangleBorder()
                : RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(28),
                  ),
            child: SizedBox(
              width: isMobile ? screenSize.width : 400,
              height: isMobile ? screenSize.height : null,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: isMobile ? MainAxisSize.max : MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Select Tools',
                      style: Theme.of(ctx).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 16),
                    Flexible(
                      child: ListView(
                        shrinkWrap: !isMobile,
                        children: [
                          // Toolbox
                          Card(
                            margin: const EdgeInsets.only(bottom: 4),
                            color: AppTheme.primaryBlue.withAlpha(18),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: CheckboxListTile(
                              secondary: Icon(
                                Icons.handyman_outlined,
                                color: tempToolboxEnabled
                                    ? AppTheme.primaryBlue
                                    : Colors.grey,
                              ),
                              title: Text(
                                'Toolbox',
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: tempToolboxEnabled
                                      ? null
                                      : Colors.grey,
                                ),
                              ),
                              subtitle: const Text(
                                'Time, location, geocoding, calculator',
                                style: TextStyle(fontSize: 11),
                              ),
                              value: tempToolboxEnabled,
                              onChanged: (val) {
                                setDialogState(() {
                                  tempToolboxEnabled = val ?? false;
                                });
                              },
                            ),
                          ),
                          const SizedBox(height: 8),
                          // Built-in tools
                          _toolSectionHeader(
                            ctx,
                            'BUILT-IN TOOLS',
                            Icons.extension,
                            AppTheme.primaryBlue,
                          ),
                          ...InternalMcpRegistry().availableServers
                              .where((info) => info.type != 'toolbox')
                              .map(
                                (info) => CheckboxListTile(
                                  dense: true,
                                  title: Text(_mcpTypeLabel(info.type)),
                                  subtitle: Text(
                                    info.description,
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                  value: tempSelection.contains(info.type),
                                  onChanged: (val) {
                                    setDialogState(() {
                                      if (val == true) {
                                        tempSelection.add(info.type);
                                      } else {
                                        tempSelection.remove(info.type);
                                      }
                                    });
                                  },
                                ),
                              ),
                          // Remote GitHub MCPs
                          if (combinedGhServers.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            _toolSectionHeader(
                              ctx,
                              'REMOTE MCP SERVERS',
                              Icons.cloud,
                              Colors.purple,
                            ),
                            ...combinedGhServers.entries.map((entry) {
                              final typeKey = 'gh_mcp_${entry.key}';
                              return CheckboxListTile(
                                dense: true,
                                title: Text(entry.value.displayName),
                                subtitle: Text(
                                  entry.value.description,
                                  style: const TextStyle(fontSize: 11),
                                ),
                                value: tempSelection.contains(typeKey),
                                onChanged: (val) {
                                  setDialogState(() {
                                    if (val == true) {
                                      tempSelection.add(typeKey);
                                    } else {
                                      tempSelection.remove(typeKey);
                                    }
                                  });
                                },
                              );
                            }),
                          ],
                          // External MCP servers
                          if (combinedServers.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            _toolSectionHeader(
                              ctx,
                              'EXTERNAL MCP SERVERS',
                              Icons.language,
                              Colors.teal,
                            ),
                            ...combinedServers.entries.map((entry) {
                              final url = entry.key;
                              final config = entry.value;
                              return CheckboxListTile(
                                dense: true,
                                title: Text(
                                  config.name ?? Uri.tryParse(url)?.host ?? url,
                                ),
                                subtitle: Text(
                                  url,
                                  style: const TextStyle(fontSize: 10),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                value: tempExternalSelection.contains(url),
                                onChanged: (val) {
                                  setDialogState(() {
                                    if (val == true) {
                                      tempExternalSelection.add(url);
                                    } else {
                                      tempExternalSelection.remove(url);
                                    }
                                  });
                                },
                              );
                            }),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(ctx).pop(),
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () => Navigator.of(ctx).pop((
                            tempSelection,
                            tempExternalSelection,
                            tempToolboxEnabled,
                          )),
                          child: const Text('Confirm'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );

    if (result != null && mounted) {
      setState(() {
        _selectedMcpTypes = result.$1;
        _selectedExternalServerUrls = result.$2;
        _toolboxEnabled = result.$3;
      });
    }
  }

  Widget _toolSectionHeader(
    BuildContext ctx,
    String label,
    IconData icon,
    Color color,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 2),
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: color,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screenSize = MediaQuery.of(context).size;
    final isMobile = screenSize.width < 600;
    final toolCount =
        _selectedMcpTypes.length +
        _selectedExternalServerUrls.length +
        (_toolboxEnabled ? 1 : 0);

    return Dialog(
      insetPadding: isMobile
          ? EdgeInsets.zero
          : EdgeInsets.symmetric(
              horizontal: screenSize.width * 0.025,
              vertical: screenSize.height * 0.025,
            ),
      clipBehavior: Clip.antiAlias,
      shape: isMobile
          ? const RoundedRectangleBorder()
          : RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: SizedBox(
        width: isMobile ? screenSize.width : screenSize.width * 0.95,
        height: isMobile ? screenSize.height : screenSize.height * 0.95,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Header ──
            Container(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
              child: Row(
                children: [
                  Icon(Icons.auto_awesome, color: AppTheme.primaryBlue),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Skill Wizard',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(),

            // ── Scrollable body ──
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Name (required)
                    TextField(
                      controller: _nameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Name *',
                        hintText: 'e.g. Weather Data Analyzer',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Goal
                    TextField(
                      controller: _goalCtrl,
                      readOnly: widget.goalReadOnly,
                      maxLines: 3,
                      decoration: InputDecoration(
                        labelText: 'Your Goal',
                        hintText:
                            'e.g. Getting log file information in a given directory',
                        border: const OutlineInputBorder(),
                        alignLabelWithHint: true,
                        isDense: true,
                        filled: widget.goalReadOnly,
                        fillColor: widget.goalReadOnly
                            ? theme.colorScheme.surfaceContainerHighest
                            : null,
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Tools selector (above generate button)
                    Row(
                      children: [
                        Icon(
                          Icons.build_outlined,
                          size: 16,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Tools',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '$toolCount selected',
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.outline,
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          onPressed: _showToolSelector,
                          icon: const Icon(Icons.tune, size: 16),
                          label: const Text('Select'),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 4,
                            ),
                            minimumSize: Size.zero,
                          ),
                        ),
                      ],
                    ),

                    // Show selected tools as chips
                    if (_selectedMcpTypes.isNotEmpty ||
                        _selectedExternalServerUrls.isNotEmpty ||
                        _toolboxEnabled)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            if (_toolboxEnabled)
                              Chip(
                                avatar: const Icon(
                                  Icons.handyman_outlined,
                                  size: 16,
                                ),
                                label: const Text('Toolbox'),
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                visualDensity: VisualDensity.compact,
                              ),
                            ..._selectedMcpTypes
                                .where((t) => t != 'toolbox')
                                .map(
                                  (type) => Chip(
                                    label: Text(_mcpTypeLabel(type)),
                                    materialTapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                    visualDensity: VisualDensity.compact,
                                    onDeleted: () {
                                      setState(() {
                                        _selectedMcpTypes.remove(type);
                                      });
                                    },
                                  ),
                                ),
                            ..._selectedExternalServerUrls.map((url) {
                              final label = _getExternalServerLabel(url);
                              return Chip(
                                label: Text(
                                  label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                visualDensity: VisualDensity.compact,
                                onDeleted: () {
                                  setState(() {
                                    _selectedExternalServerUrls.remove(url);
                                  });
                                },
                              );
                            }),
                          ],
                        ),
                      ),

                    const SizedBox(height: 8),

                    // Generate Skill button (below goal + tools)
                    if (!widget.goalReadOnly)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          onPressed:
                              (_isGenerating || _goalCtrl.text.trim().isEmpty)
                              ? null
                              : _doGenerateSkill,
                          icon: _isGenerating
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.auto_awesome, size: 16),
                          label: Text(
                            _isGenerating
                                ? 'Generating...'
                                : 'Generate Skill from Goal',
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.primaryBlue,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            minimumSize: Size.zero,
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),

                    // Skill content
                    TextField(
                      controller: _skillCtrl,
                      maxLines: 8,
                      decoration: const InputDecoration(
                        labelText: 'Skill',
                        hintText: 'AgentSkills.io formatted skill content...',
                        border: OutlineInputBorder(),
                        alignLabelWithHint: true,
                        isDense: true,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const Divider(),

            // ── Footer buttons ──
            // If onSave is set → Save | Cancel (persist mode).
            // Otherwise → Export | Import | Apply (full mode).
            if (widget.onSave != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton(
                      onPressed: () {
                        widget.onCancel?.call();
                        Navigator.of(context).pop();
                      },
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: _nameCtrl.text.trim().isNotEmpty
                          ? _onSavePressed
                          : null,
                      icon: const Icon(Icons.check, size: 16),
                      label: const Text('Save'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                      ),
                    ),
                  ],
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: isMobile
                    ? Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        alignment: WrapAlignment.end,
                        children: [
                          OutlinedButton.icon(
                            onPressed: _onExport,
                            icon: const Icon(Icons.ios_share, size: 16),
                            label: const Text('Export'),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              minimumSize: Size.zero,
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: _onImport,
                            icon: const Icon(
                              Icons.file_upload_outlined,
                              size: 16,
                            ),
                            label: const Text('Import'),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              minimumSize: Size.zero,
                            ),
                          ),
                          if (!widget.hideApply)
                            FilledButton.icon(
                              onPressed: _nameCtrl.text.trim().isNotEmpty
                                  ? _onApply
                                  : null,
                              icon: const Icon(Icons.check, size: 16),
                              label: const Text('Apply'),
                              style: FilledButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 6,
                                ),
                                minimumSize: Size.zero,
                              ),
                            ),
                        ],
                      )
                    : Row(
                        children: [
                          OutlinedButton.icon(
                            onPressed: _onExport,
                            icon: const Icon(Icons.ios_share, size: 16),
                            label: const Text('Export'),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: _onImport,
                            icon: const Icon(
                              Icons.file_upload_outlined,
                              size: 16,
                            ),
                            label: const Text('Import'),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                            ),
                          ),
                          if (!widget.hideApply) ...[
                            const Spacer(),
                            FilledButton.icon(
                              onPressed: _nameCtrl.text.trim().isNotEmpty
                                  ? _onApply
                                  : null,
                              icon: const Icon(Icons.check, size: 16),
                              label: const Text('Apply'),
                              style: FilledButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 8,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
              ),
          ],
        ),
      ),
    );
  }
}
