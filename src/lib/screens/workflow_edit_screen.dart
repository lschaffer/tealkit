// ignore_for_file: unused_element

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart' hide Step;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../config/app_theme.dart';
import '../mcp/internal_mcp_registry.dart';
import '../mcp/servers/document_mcp_server.dart';
import '../mcp/servers/google_drive_mcp_server.dart';
import '../mcp/servers/py_bridge_mcp_server.dart';
import '../mcp/servers/website_search_mcp_server.dart';
import '../models/workflow_task.dart';
import '../models/github_mcp_server_definition.dart';
import '../models/mcp_models.dart';
import '../providers/active_task_provider.dart';
import '../providers/database_providers.dart';
import '../providers/llm_settings_provider.dart';
import '../services/app_logger.dart';
import '../services/data_sources_settings_service.dart';
import '../services/external_tools_settings_service.dart';

import 'package:path_provider/path_provider.dart';
import '../services/github_mcp_library_service.dart';
import '../services/github_mcp_runtime_service.dart';
import '../services/llm_settings_service.dart';
import '../utils/storage_permission.dart';
import '../widgets/mcp_discovery_dialog.dart';
import '../widgets/schedule_picker_dialog.dart';
import '../widgets/tool_list_export_sheet.dart';
import '../widgets/step_list_editor.dart';
import '../widgets/llm_settings_form_widget.dart';
import 'js_tool_library_screen.dart';
import 'local_shell_tool_library_screen.dart';
import 'py_tool_library_screen.dart';
import 'powershell_tool_library_screen.dart';
import 'script_library_screen.dart';
import 'function_hints_screen.dart';
import '../providers/server_mode_provider.dart';
import '../services/workflow_export_service.dart';

import '../models/function_hint.dart';
import '../services/function_hint_database_service.dart';
import '../l10n/app_localizations.dart';

/// Full-page editor for creating/editing an [WorkflowTask].
/// 7 tabs: Basic, Schedule, LLM, MCP Servers, Built-in MCPs, Data Sources, Notify.
class WorkflowEditScreen extends ConsumerStatefulWidget {
  final WorkflowTask? task;

  const WorkflowEditScreen({super.key, this.task});

  bool get isEditing => task != null;

  @override
  ConsumerState<WorkflowEditScreen> createState() => _TaskEditScreenState();
}

class _TaskEditScreenState extends ConsumerState<WorkflowEditScreen>
    with TickerProviderStateMixin {
  static const String _websiteSeedUrlsPrefsKey = 'playground_website_seed_urls';
  // Global URLs from Data Sources settings, pre-populated into website_search tool
  static const String _websiteMaxPagesPrefsKey = 'playground_website_max_pages';

  // Website search editor state
  List<String> _globalWebsiteUrls = [];
  late TextEditingController _websiteUrlCtrl;

  // ─── Agents ──────────────────────────────────────
  late List<Agent> _executors;
  late List<Edge> _routingRules;
  int _selectedExecutorIndex = 0;
  int _activeSubSectionIndex = 0;
  late TextEditingController _executorNameCtrl;

  final _formKey = GlobalKey<FormState>();
  late TabController _tabController;
  late TaskNotification _globalNotification;

  // ─── Basic ──────────────────────────────────────────
  late TextEditingController _nameCtrl;
  late TextEditingController _descriptionCtrl;
  late TextEditingController _promptCtrl;
  late TextEditingController _systemPromptUserCtrl;
  late TextEditingController _systemPromptSkillsCtrl;
  late TextEditingController _agentIdCtrl;

  // ─── Schedule ───────────────────────────────────────
  late TextEditingController _cronCtrl;
  late TextEditingController _scheduleHintCtrl;
  late TextEditingController _maxRetriesCtrl;
  late TextEditingController _retryDelayCtrl;
  late TextEditingController _timeoutCtrl;

  // ─── LLM Config ────────────────────────────────────
  late TextEditingController _llmProviderCtrl;
  late TextEditingController _llmModelCtrl;
  late TextEditingController _llmApiKeyCtrl;
  late TextEditingController _llmBaseUrlCtrl;
  late TextEditingController _temperatureCtrl;
  late TextEditingController _maxTokensCtrl;
  late TextEditingController _maxToolOutputSizeCtrl;
  late TextEditingController _tokenWarningThresholdCtrl;
  late TextEditingController _topKCtrl;
  late TextEditingController _topPCtrl;
  late TextEditingController _repeatPenaltyCtrl;
  late TextEditingController _seedCtrl;
  bool _overrideLlm = false;
  bool _thinking = false;
  bool _useNativeToolCall = true;
  bool _useSafeToolCall = false;
  bool _isSlm = false;
  bool _isMultiModal = true;
  // Guard to show missing-skills warning at most once per task load.
  bool _skillsWarningShown = false;

  // ─── MCP Servers ────────────────────────────────────
  late List<McpToolConfig> _mcpServers;
  // Global external servers selected for this task (subset of ExternalToolsSettingsService)
  late Set<String> _selectedGlobalServerUrls;

  // ─── Internal (Built-in) MCPs ───────────────────────
  late List<InternalMcpEntry> _internalMcps;
  List<GithubMcpServerDefinition> _remoteGithubMcpServers = const [];
  final Map<String, List<String>> _prefetchedRemoteMcpTools = {};
  bool _toolboxEnabled = true;

  // Generation counter to cancel stale concurrent _updateSkillsSection calls.
  int _skillsUpdateGeneration = 0;

  // ─── Notifications ──────────────────────────────────
  late TextEditingController _emailToCtrl;
  late TextEditingController _emailSubjectCtrl;
  late TextEditingController _emailSendConditionCtrl;
  late TextEditingController _emailConditionExprCtrl;
  late TextEditingController _downloadPathCtrl;
  late TextEditingController _downloadFilePatternCtrl;
  late TextEditingController _pushTitleCtrl;
  late TextEditingController _pushTokenCtrl;
  late TextEditingController _slackChannelCtrl;
  late TextEditingController _whatsAppRecipientCtrl;
  bool _emailNotifyEnabled = false;
  bool _pushEnabled = false;
  bool _slackNotifyEnabled = false;
  String _slackSendCondition = 'always';
  bool _slackWithAttachment = false;
  bool _whatsAppNotifyEnabled = false;
  String _whatsAppSendCondition = 'always';
  bool _addExecutionLogToOutput = false;
  bool _zipOutputFiles = false;
  String _outputType = 'file';

  // ─── SFTP output ─────────────────────────────────────
  bool _sftpUseConfiguredSshServer = true;
  late TextEditingController _sftpHostCtrl;
  late TextEditingController _sftpPortCtrl;
  late TextEditingController _sftpUsernameCtrl;
  late TextEditingController _sftpPasswordCtrl;
  late TextEditingController _sftpRemotePathCtrl;
  String _sftpPrivateKeyPem = '';
  String _sftpPrivateKeyFileName = '';
  bool _sftpNotifyByEmail = false;
  late TextEditingController _sftpNotifyEmailAddressCtrl;
  late TextEditingController _sftpNotifyEmailSubjectCtrl;
  late TextEditingController _sftpNotifyEmailBodyCtrl;

  // ─── State ──────────────────────────────────────────
  bool _enabled = true;
  bool _chatMode = false;
  bool _isSaving = false;

  int get _externalServerSelectionLimit => 100;

  // ─── Task Chaining ──────────────────────────────────
  bool _isSubtask = false;
  bool _chainWithCondition = false;
  late TextEditingController _chainConditionCtrl;
  String? _chainOnMatchId;
  String? _chainOnNoMatchId;

  // ─── Execution ──────────────────────────────────────
  bool _stopAfterToolCall = false;

  // ─── Tools → system prompt auto-generation ──────────
  bool _generateSystemPromptOnToolSelect = true;

  /// Returns true when [model] name indicates a small/constrained LLM
  /// (parameter count ≤ 14B, or known small keywords).
  static bool _isSmallModelByName(String model) {
    final m = model.toLowerCase();
    final match = RegExp(
      r'(?:^|[:\-_.])([0-9]+\.?[0-9]*)b(?:\b|[-_])',
    ).firstMatch(m);
    if (match != null) {
      final params = double.tryParse(match.group(1)!);
      if (params != null && params <= 14) return true;
    }
    return m.contains('phi') ||
        m.contains('tiny') ||
        m.contains('nano') ||
        m.contains(':mini') ||
        m.contains('-mini') ||
        m.contains('tinyllama');
  }

  /// Collects non-empty advanced extra params into a Map for TaskLlmConfig.extraParams.
  Map<String, dynamic> _buildExtraParams() {
    final Map<String, dynamic> params = {};
    final topK = int.tryParse(_topKCtrl.text.trim());
    if (topK != null) params['top_k'] = topK;
    final topP = double.tryParse(_topPCtrl.text.trim());
    if (topP != null) params['top_p'] = topP;
    final rp = double.tryParse(_repeatPenaltyCtrl.text.trim());
    if (rp != null) params['repeat_penalty'] = rp;
    final seed = int.tryParse(_seedCtrl.text.trim());
    if (seed != null) params['seed'] = seed;
    final maxToolOutput = int.tryParse(_maxToolOutputSizeCtrl.text.trim());
    if (maxToolOutput != null) params['max_tool_output_size'] = maxToolOutput;
    final tokenWarningThreshold = int.tryParse(
      _tokenWarningThresholdCtrl.text.trim(),
    );
    if (tokenWarningThreshold != null) {
      params['token_warning_threshold'] = tokenWarningThreshold;
    }
    if (_thinking) params['thinking'] = true;
    params['use_native_tool_call'] = _useNativeToolCall;
    params['use_safe_tool_call'] = _useSafeToolCall;
    params['is_slm'] = _isSlm;
    params['is_multi_modal'] = _isMultiModal;
    return params;
  }

  // ── Skills-section helpers ────────────────────────────────────────────────

  /// The marker that separates the user-managed base prompt from the
  /// auto-managed "Tool Hints" block appended below it.
  static const _kSkillsMarker = '\n\nTool Hints:';

  /// Returns only the user-managed portion of [full] — everything **before**
  /// the auto-managed "Tool Hints:" block.
  String _extractBasePrompt(String full) {
    final idx = full.indexOf(_kSkillsMarker);
    return idx >= 0 ? full.substring(0, idx).trimRight() : full.trimRight();
  }

  /// Returns `true` when the currently effective LLM is a small / embedded
  /// model (so [FunctionHint.skillTextSlm] should be used).
  bool _isEffectiveSlm() {
    if (_overrideLlm) {
      if (_llmProviderCtrl.text.toLowerCase() == 'embedded') return true;
      if (_isSlm) return true;
      if (_llmModelCtrl.text.isNotEmpty) {
        return _isSmallModelByName(_llmModelCtrl.text);
      }
    }
    final taskState = ref.read(activeTaskProvider);
    final chatService = taskState?.chatService;
    if (chatService != null && chatService.llmService.isConfigured) {
      return chatService.llmService.isSlm;
    }
    return ref.read(llmSettingsProvider).isSlm;
  }

  /// Combined prompt sent to the LLM: user text + auto-generated skills.
  String get _combinedSystemPrompt {
    final user = _systemPromptUserCtrl.text.trimRight();
    final skills = _systemPromptSkillsCtrl.text.trim();
    if (skills.isEmpty) return user;
    return user.isEmpty ? skills : '$user\n\n$skills';
  }

  /// Splits a stored full system prompt into user + skills parts.
  void _loadSystemPrompt(String full) {
    // Match the skills marker even if it was written with a single newline or
    // extra whitespace (older saves may have used a different separator).
    final match = RegExp(r'\n+Tool Hints:\n').firstMatch(full);
    if (match != null) {
      _systemPromptUserCtrl.text = full.substring(0, match.start).trimRight();
      _systemPromptSkillsCtrl.text = full.substring(match.start + 1).trim();
    } else {
      _systemPromptUserCtrl.text = full;
      _systemPromptSkillsCtrl.text = '';
    }
  }

  /// Rebuilds the skills controller from the currently selected tools.
  Future<void> _updateSkillsSection() async {
    if (!mounted) return;
    final generation = ++_skillsUpdateGeneration;
    // Clear immediately so stale skills are never shown while regenerating.
    setState(() => _systemPromptSkillsCtrl.text = '');
    final enabledFilter = _enabledToolNamesFromPrompt(_promptCtrl.text);
    final skills = await _buildTaskSkillsBlock(
      isSlm: _isEffectiveSlm(),
      enabledFilter: enabledFilter,
    );
    if (!mounted || generation != _skillsUpdateGeneration) return;
    setState(() {
      _systemPromptSkillsCtrl.text = skills;
    });
  }

  /// Returns the union of per-step enabled tool names serialised in [promptText].
  /// Returns null when every step allows all tools (no restriction).
  /// Steps with no explicit restriction (null) are skipped so that explicitly
  /// restricted steps still filter the skills block.
  Set<String>? _enabledToolNamesFromPrompt(String promptText) {
    final steps = parseWorkflowSteps(promptText);
    if (steps.every((s) => s.enabledToolNames == null)) return null;
    final union = <String>{};
    for (final step in steps) {
      if (step.enabledToolNames == null) {
        continue; // all-tools step: don't restrict union
      }
      union.addAll(step.enabledToolNames!);
    }
    return union;
  }

  // ─────────────────────────────────────────────────────────────────────────

  /// Builds the topic string used for auto-generation, e.g. "Chart generator, Gmail expert"
  String _buildToolsTopicString() {
    final internalNames = _internalMcps
        .where((e) => !e.mcpType.startsWith('gh_mcp_'))
        .map((e) => e.label)
        .toList();
    final globalServers = ExternalToolsSettingsService.instance.selectedServers;
    final externalNames = _selectedGlobalServerUrls.map((url) {
      final s = globalServers.firstWhere(
        (s) => s.serverUrl == url,
        orElse: () => McpToolConfig(serverUrl: url),
      );
      return s.name ?? url;
    }).toList();
    final taskServerNames = _mcpServers
        .map((s) => s.name ?? s.serverUrl)
        .toList();
    final names = [...internalNames, ...externalNames, ...taskServerNames];
    if (names.isEmpty) return '';
    return '${names.join(', ')} expert';
  }

  /// Auto-generates a system prompt based on the currently selected tools and
  /// fills [_systemPromptCtrl]. No-op when [_generateSystemPromptOnToolSelect]
  /// is false.
  ///
  /// • If the user already has a base prompt → **only** the skills section is
  ///   refreshed (no LLM call, user text preserved).
  /// • If the base prompt is empty and tools are selected → the LLM generates
  ///   a compact base prompt, then the skills section is appended.
  /// • If no tools are selected → any leftover skills section is cleared.
  Future<void> _autoGenerateSystemPromptFromTools() async {
    if (!_generateSystemPromptOnToolSelect) return;

    // If the user already typed a base prompt, just refresh the skills section.
    final base = _systemPromptUserCtrl.text.trimRight();
    if (base.isNotEmpty) {
      await _updateSkillsSection();
      return;
    }

    // Base is empty. No tools → clear any leftover skills and return.
    final hasAnyTools =
        _internalMcps.isNotEmpty ||
        _selectedGlobalServerUrls.isNotEmpty ||
        _mcpServers.isNotEmpty;
    if (!hasAnyTools) {
      await _updateSkillsSection();
      return;
    }

    final topic = _buildToolsTopicString();
    final taskState = ref.read(activeTaskProvider);
    final chatService = taskState?.chatService;
    String result;
    if (chatService != null && chatService.llmService.isConfigured) {
      final llm = chatService.llmService;
      final llmSettings = ref.read(llmSettingsProvider);

      // Determine effective model info and whether it is a small/constrained LLM.
      bool isSmall = llm.isSlm;
      String modelInfo;
      if (_overrideLlm) {
        if (_llmProviderCtrl.text == 'llm2') {
          modelInfo =
              'LLM 2 (${llmSettings.provider2.label} / ${llmSettings.model2})';
          isSmall =
              llmSettings.isSlm2 || _isSmallModelByName(llmSettings.model2);
        } else if (_llmModelCtrl.text.isNotEmpty) {
          modelInfo = '${_llmProviderCtrl.text} / ${_llmModelCtrl.text}';
          isSmall = _isSmallModelByName(_llmModelCtrl.text);
        } else {
          modelInfo = '${llm.currentProvider.name} / ${llm.currentModel}';
        }
      } else {
        modelInfo = '${llm.currentProvider.name} / ${llm.currentModel}';
      }

      // For small/constrained models: generate a SHORT, tool-calling-focused prompt.
      // Long verbose prompts confuse small models and prevent them from calling tools.
      final String metaPrompt;
      if (isSmall) {
        metaPrompt =
            'Generate a SHORT system prompt (max 2 sentences, plain text) for a small language model ($modelInfo) '
            'that specialises in: "$topic".\n'
            'CRITICAL RULES for small model system prompts:\n'
            '- First sentence: state the role/specialisation briefly\n'
            '- Second sentence: instruct the model to call available tools immediately when asked — no explanation\n'
            '- Do NOT explain how tools work or list examples\n'
            '- No filler, no markdown, no quotes\n'
            'Output ONLY the prompt text.';
      } else {
        metaPrompt =
            'Write a system prompt for an AI assistant that specialises in: "$topic".\n'
            'STRICT OUTPUT RULES — violating any rule makes the output unusable:\n'
            '- Output ONLY the system prompt text itself, nothing else\n'
            '- Plain prose only: NO markdown, NO bullet points, NO numbered lists, NO bold/italic, NO headers\n'
            '- Maximum 3 sentences\n'
            '- No preamble, no closing remarks, no quotes around the output\n'
            'Write the system prompt now:';
      }

      try {
        final response = await llm.generateChatCompletion(
          messages: [
            ChatMessage(
              id: const Uuid().v4(),
              role: ChatRole.system,
              content:
                  'You write system prompts for AI assistants. Output only plain prose — no markdown, no lists, no headers.',
              timestamp: DateTime.now(),
            ),
            ChatMessage(
              id: const Uuid().v4(),
              role: ChatRole.user,
              content: metaPrompt,
              timestamp: DateTime.now(),
            ),
          ],
          maxTokens: 200,
        );
        result = response.content.trim();
        if (result.length > 2 &&
            ((result.startsWith('"') && result.endsWith('"')) ||
                (result.startsWith("'") && result.endsWith("'")))) {
          result = result.substring(1, result.length - 1).trim();
        }
        // Strip any markdown the LLM snuck in despite the instructions.
        result = result
            .replaceAll(RegExp(r'\*\*|__|\*|_'), '') // bold / italic
            .replaceAll(
              RegExp(r'^#{1,6}\s+', multiLine: true),
              '',
            ) // ATX headers
            .replaceAll(
              RegExp(r'^\s*[-*•]\s+', multiLine: true),
              '',
            ) // bullet leaders
            .replaceAll(
              RegExp(r'^\s*\d+\.\s+', multiLine: true),
              '',
            ) // numbered lists
            .replaceAll(
              RegExp(r'^\s*---+\s*$', multiLine: true),
              '',
            ) // horizontal rules
            .trim();
      } catch (_) {
        result =
            'You are a helpful AI assistant specialized in $topic. Provide accurate, concise responses. Use available tools when relevant.';
      }
    } else {
      result =
          'You are a helpful AI assistant specialized in $topic. Provide accurate, concise responses. Use available tools when relevant.';
    }

    // Set the generated base text, then rebuild the skills section.
    if (mounted) setState(() => _systemPromptUserCtrl.text = result);
    await _updateSkillsSection();
  }

  /// Fetches enabled skills from the DB for all currently selected tools.
  Future<String> _buildTaskSkillsBlock({
    bool isSlm = false,
    Set<String>? enabledFilter,
  }) async {
    final toolNames = <String>[];
    // Toolbox is always-on (tracked separately from _internalMcps).
    if (_toolboxEnabled) {
      final toolbox = InternalMcpRegistry().create('toolbox');
      if (toolbox != null) toolNames.addAll(toolbox.tools.map((t) => t.name));
    }
    // Internal MCPs (toolbox already excluded from _internalMcps by initState).
    for (final entry in _internalMcps.where((e) => e.enabled)) {
      if (entry.mcpType.startsWith('gh_mcp_')) {
        final serverId = entry.mcpType.substring('gh_mcp_'.length);
        toolNames.addAll(
          _prefetchedRemoteMcpTools[serverId] ?? const <String>[],
        );
        continue;
      }
      final server = InternalMcpRegistry().create(entry.mcpType);
      if (server != null) toolNames.addAll(server.tools.map((t) => t.name));
    }
    // Global (shared) external servers.
    final globalServers = ExternalToolsSettingsService.instance.selectedServers;
    for (final url in _selectedGlobalServerUrls) {
      final s = globalServers.firstWhere(
        (s) => s.serverUrl == url,
        orElse: () => McpToolConfig(serverUrl: url),
      );
      final names = s.discoveredTools.isNotEmpty
          ? s.discoveredTools
          : (_prefetchedRemoteMcpTools[url] ?? const <String>[]);
      toolNames.addAll(names);
    }
    // Task-specific MCP servers.
    for (final s in _mcpServers) {
      final names = s.discoveredTools.isNotEmpty
          ? s.discoveredTools
          : (_prefetchedRemoteMcpTools[s.serverUrl] ?? const <String>[]);
      toolNames.addAll(names);
    }
    if (toolNames.isEmpty) return '';
    // Apply per-step filter: only keep tools enabled in the prompt.
    final filtered = enabledFilter != null
        ? toolNames.where((t) => enabledFilter.contains(t)).toList()
        : toolNames;
    if (filtered.isEmpty) return '';
    try {
      final client = ref.read(serverApiClientProvider);
      final List<FunctionHint> skills;
      if (client != null) {
        final raw = await client.getAllSkills();
        final all = raw.map((j) => FunctionHint.fromJson(j)).toList();
        final filteredList = all
            .where((s) => s.isEnabled && filtered.contains(s.toolName))
            .toList();
        final seen = <String>{};
        skills = filteredList.where((s) => seen.add(s.toolName)).toList();
      } else {
        skills = await FunctionHintDatabaseService().getEnabledForTools(filtered);
      }
      if (!_skillsWarningShown && filtered.isNotEmpty) {
        final missing = filtered
            .where((t) => !skills.any((s) => s.toolName == t))
            .toList();
        if (missing.isNotEmpty) {
          _skillsWarningShown = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _showMissingSkillsWarning(missing);
          });
        }
      }
      if (skills.isEmpty) return '';
      final buffer = StringBuffer();
      buffer.writeln('Tool Hints:');
      for (final skill in skills) {
        final text = isSlm ? skill.skillTextSlm : skill.skillText;
        if (text.trim().isNotEmpty) {
          buffer.writeln('• ${skill.toolName}: ${text.trim()}');
        }
      }
      return buffer.toString().trim();
    } catch (_) {
      return '';
    }
  }

  void _showMissingSkillsWarning(List<String> missingTools) {
    if (!mounted) return;
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Missing Tool Hints'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              missingTools.length == 1
                  ? 'No skill found for 1 tool:'
                  : 'No skills found for ${missingTools.length} tools:',
            ),
            const SizedBox(height: 8),
            Text(
              missingTools.take(6).join('\n') +
                  (missingTools.length > 6 ? '\n…' : ''),
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            const Text(
              'Skills help the AI understand how to use tools effectively.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Dismiss'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Generate'),
          ),
        ],
      ),
    ).then((generate) {
      if (generate == true && mounted) {
        FunctionHintsScreen.show(context, autoRebuild: true);
      }
    });
  }

  void _insertScriptCallIntoPrompt(String scriptName) {
    final trimmed = scriptName.trim();
    if (trimmed.isEmpty) return;
    final insertText = 'execute script "$trimmed"';
    final current = _promptCtrl.text.trimRight();
    final updated = current.isEmpty ? insertText : '$current\n$insertText';
    _promptCtrl.text = updated;
    _promptCtrl.selection = TextSelection.collapsed(
      offset: _promptCtrl.text.length,
    );
  }

  void _insertJsToolCallIntoPrompt(String toolName) {
    final trimmed = toolName.trim();
    if (trimmed.isEmpty) return;
    final insertText = 'run JS tool "$trimmed" with args {}';
    final current = _promptCtrl.text.trimRight();
    final updated = current.isEmpty ? insertText : '$current\n$insertText';
    _promptCtrl.text = updated;
    _promptCtrl.selection = TextSelection.collapsed(
      offset: _promptCtrl.text.length,
    );
  }

  @override
  void initState() {
    super.initState();
    final t = widget.task;
    _globalNotification = t?.notification ?? const TaskNotification();

    if (t != null && t.agents.isNotEmpty) {
      _executors = List.from(t.agents);
      _routingRules = List.from(t.edges);
    } else {
      _executors = [
        Agent(
          id: const Uuid().v4(),
          name: t?.name ?? 'Agent 1',
          prompt: t?.prompt ?? '',
          systemPrompt: t?.systemPrompt,
          llmConfig: t?.llmConfig,
          mcpTools: t != null ? List.from(t.mcpTools) : const [],
          internalMcps: t != null ? List.from(t.internalMcps) : const [],
          chatMode: t?.chatMode ?? false,
          stopAfterToolCall: t?.stopAfterToolCall ?? false,
        ),
      ];
      _routingRules = [];
    }

    _selectedExecutorIndex = 0;
    _tabController = TabController(length: _executors.length, vsync: this);
    _tabController.addListener(_handleTabSelection);

    _executorNameCtrl = TextEditingController();

    // Basic
    _nameCtrl = TextEditingController(text: t?.name ?? '');
    _descriptionCtrl = TextEditingController(text: t?.description ?? '');
    _promptCtrl = TextEditingController();
    _systemPromptUserCtrl = TextEditingController();
    _systemPromptSkillsCtrl = TextEditingController();
    _agentIdCtrl = TextEditingController(text: t?.agentId ?? '');
    _enabled = t?.enabled ?? true;

    // Schedule
    _cronCtrl = TextEditingController(
      text: t?.executionPlan.cronExpression ?? '0 8 * * *',
    );
    _scheduleHintCtrl = TextEditingController(
      text: t?.executionPlan.scheduleHint ?? '',
    );
    _maxRetriesCtrl = TextEditingController(
      text: '${t?.executionPlan.maxRetries ?? 3}',
    );
    _retryDelayCtrl = TextEditingController(
      text: '${t?.executionPlan.retryDelayMinutes ?? 15}',
    );
    _timeoutCtrl = TextEditingController(text: '300');

    // LLM
    _overrideLlm = t?.llmConfig != null;
    _llmProviderCtrl = TextEditingController(
      text: t?.llmConfig?.provider ?? '',
    );
    _llmModelCtrl = TextEditingController(text: t?.llmConfig?.model ?? '');
    _llmApiKeyCtrl = TextEditingController(text: t?.llmConfig?.apiKey ?? '');
    _llmBaseUrlCtrl = TextEditingController(text: t?.llmConfig?.baseUrl ?? '');
    _temperatureCtrl = TextEditingController(
      text: '${t?.llmConfig?.temperature ?? 0.2}',
    );
    _maxTokensCtrl = TextEditingController(
      text: '${t?.llmConfig?.maxTokens ?? 0}',
    );
    final ep = t?.llmConfig?.extraParams ?? const <String, dynamic>{};
    _maxToolOutputSizeCtrl = TextEditingController(
      text: '${ep['max_tool_output_size'] ?? 2560000}',
    );
    _tokenWarningThresholdCtrl = TextEditingController(
      text: '${ep['token_warning_threshold'] ?? 1500000}',
    );
    _topKCtrl = TextEditingController(
      text: ep['top_k'] != null ? '${ep['top_k']}' : '',
    );
    _topPCtrl = TextEditingController(
      text: ep['top_p'] != null ? '${ep['top_p']}' : '',
    );
    _repeatPenaltyCtrl = TextEditingController(
      text: ep['repeat_penalty'] != null ? '${ep['repeat_penalty']}' : '',
    );
    _seedCtrl = TextEditingController(
      text: ep['seed'] != null ? '${ep['seed']}' : '',
    );
    _thinking = (ep['thinking'] as bool?) ?? false;
    _useNativeToolCall = (ep['use_native_tool_call'] as bool?) ?? true;
    _useSafeToolCall = (ep['use_safe_tool_call'] as bool?) ?? false;
    _isSlm = (ep['is_slm'] as bool?) ?? false;
    if (ep.containsKey('is_multi_modal')) {
      _isMultiModal = (ep['is_multi_modal'] as bool?) ?? true;
    } else if (t?.llmConfig != null) {
      final providerKey = t!.llmConfig!.provider;
      final providerEnum = LlmProvider.fromConfigKey(providerKey);
      _isMultiModal = LlmSettingsService.detectDefaultMultiModal(
        providerEnum,
        t.llmConfig!.model,
      );
    } else {
      _isMultiModal = true;
    }

    // MCP Servers — separate task-specific from global ones
    final globalUrls = ExternalToolsSettingsService.instance.selectedServers
        .map((s) => s.serverUrl)
        .toSet();
    final allMcpTools = List<McpToolConfig>.from(t?.mcpTools ?? []);
    _selectedGlobalServerUrls = allMcpTools
        .where((s) => globalUrls.contains(s.serverUrl))
        .map((s) => s.serverUrl)
        .toSet();
    _mcpServers = allMcpTools
        .where((s) => !globalUrls.contains(s.serverUrl))
        .toList();

    // Internal MCPs — strip toolbox from the list (tracked separately via _toolboxEnabled)
    _toolboxEnabled = !(t?.internalMcps ?? []).any(
      (m) => m.mcpType == 'toolbox' && !m.enabled,
    );
    _internalMcps = List<InternalMcpEntry>.from(
      t?.internalMcps ?? [],
    ).where((m) => m.mcpType != 'toolbox').toList();

    // Notifications
    _outputType = t?.notification.email != null
        ? 'email'
        : (t?.notification.sftpOutput != null ? 'sftp' : 'file');
    _emailNotifyEnabled = t?.notification.email != null;
    _emailToCtrl = TextEditingController(
      text: t?.notification.email?.recipients.join(', ') ?? '',
    );
    _emailSubjectCtrl = TextEditingController(
      text: t?.notification.email?.subject ?? '',
    );
    _emailSendConditionCtrl = TextEditingController(
      text: t?.notification.email?.sendCondition ?? 'always',
    );
    _emailConditionExprCtrl = TextEditingController(
      text: t?.notification.email?.conditionExpression ?? '',
    );
    _downloadPathCtrl = TextEditingController(
      text: t?.notification.download?.downloadPath ?? '',
    );
    _downloadFilePatternCtrl = TextEditingController(
      text:
          t?.notification.download?.fileNamePattern ?? 'task_result_{date}.txt',
    );
    _pushEnabled = t?.notification.push != null;
    _addExecutionLogToOutput = t?.notification.addExecutionLog ?? false;
    _zipOutputFiles = t?.notification.zipOutputFiles ?? false;
    _pushTitleCtrl = TextEditingController(
      text: t?.notification.push?.title ?? '',
    );
    _pushTokenCtrl = TextEditingController(text: '');
    _slackNotifyEnabled = t?.notification.slack != null;
    _slackSendCondition = t?.notification.slack?.sendCondition ?? 'always';
    _slackWithAttachment = t?.notification.slack?.withAttachment ?? false;
    _slackChannelCtrl = TextEditingController(
      text: t?.notification.slack?.overrideChannel ?? '',
    );
    _whatsAppNotifyEnabled = t?.notification.whatsApp != null;
    _whatsAppSendCondition =
        t?.notification.whatsApp?.sendCondition ?? 'always';
    _whatsAppRecipientCtrl = TextEditingController(
      text: t?.notification.whatsApp?.overrideRecipient ?? '',
    );

    // SFTP output
    final sftpCfg = t?.notification.sftpOutput;
    _sftpUseConfiguredSshServer = sftpCfg?.useConfiguredSshServer ?? true;
    _sftpHostCtrl = TextEditingController(text: sftpCfg?.host ?? '');
    _sftpPortCtrl = TextEditingController(text: '${sftpCfg?.port ?? 22}');
    _sftpUsernameCtrl = TextEditingController(text: sftpCfg?.username ?? '');
    _sftpPasswordCtrl = TextEditingController(text: sftpCfg?.password ?? '');
    _sftpPrivateKeyPem = sftpCfg?.privateKey ?? '';
    _sftpPrivateKeyFileName = _sftpPrivateKeyPem.isNotEmpty
        ? '(custom key loaded)'
        : '';
    _sftpRemotePathCtrl = TextEditingController(
      text: sftpCfg?.remotePath ?? '/',
    );
    _sftpNotifyByEmail = sftpCfg?.notifyByEmail ?? false;
    _sftpNotifyEmailAddressCtrl = TextEditingController(
      text: sftpCfg?.notifyEmailAddress ?? '',
    );
    _sftpNotifyEmailSubjectCtrl = TextEditingController(
      text: sftpCfg?.notifyEmailSubject ?? '',
    );
    _sftpNotifyEmailBodyCtrl = TextEditingController(
      text: sftpCfg?.notifyEmailBody ?? '',
    );

    // Chain config
    final chain = t?.chainConfig;
    _isSubtask = chain?.isSubtask ?? false;
    _chainConditionCtrl = TextEditingController(
      text: chain?.triggerCondition ?? '',
    );
    _chainWithCondition =
        chain?.triggerCondition != null && chain!.triggerCondition!.isNotEmpty;
    _chainOnMatchId = chain?.onMatchTaskId;
    _chainOnNoMatchId = chain?.onNoMatchTaskId;
    _stopAfterToolCall = t?.stopAfterToolCall ?? false;
    _websiteUrlCtrl = TextEditingController();

    Future.microtask(_loadPersistedWebsiteSearchForTaskEdit);
    Future.microtask(_refreshSelectableGithubMcpServers);
    Future.microtask(_eagerDiscoverSelectedRemoteMcpTools);

    // Load first executor's fields
    _loadExecutorState(0);

    // Always rebuild skills so stale/empty saved skills are refreshed
    // (e.g. old saves with empty skill block, or skills edited since last save).
    if (t != null) Future.microtask(_updateSkillsSection);
  }

  void _handleTabSelection() {
    if (_tabController.index != _selectedExecutorIndex) {
      _saveCurrentExecutorState();
      setState(() {
        _loadExecutorState(_tabController.index);
      });
    }
  }

  void _saveCurrentExecutorState() {
    if (_executors.isEmpty) return;
    final index = _selectedExecutorIndex;
    if (index < 0 || index >= _executors.length) return;

    final exec = _executors[index];

    final systemPrompt = _combinedSystemPrompt.isNotEmpty
        ? _combinedSystemPrompt.trim()
        : null;

    TaskLlmConfig? execLlm;
    if (_overrideLlm) {
      execLlm = TaskLlmConfig(
        provider: _llmProviderCtrl.text,
        baseUrl: _llmBaseUrlCtrl.text.isNotEmpty
            ? _llmBaseUrlCtrl.text.trim()
            : null,
        apiKey: _llmApiKeyCtrl.text.isNotEmpty
            ? _llmApiKeyCtrl.text.trim()
            : null,
        model: _llmModelCtrl.text.trim(),
        temperature: double.tryParse(_temperatureCtrl.text) ?? 0.7,
        maxTokens: int.tryParse(_maxTokensCtrl.text) ?? 0,
        extraParams: _buildExtraParams(),
      );
    }

    final updated = exec.copyWith(
      systemPrompt: systemPrompt?.trim(),
      prompt: _promptCtrl.text.trim(),
      llmConfig: execLlm,
      clearLlmConfig: !_overrideLlm,
      chatMode: _chatMode,
      stopAfterToolCall: _stopAfterToolCall,
      mcpTools: [
        ..._mcpServers,
        ...ExternalToolsSettingsService.instance.selectedServers.where(
          (s) => _selectedGlobalServerUrls.contains(s.serverUrl),
        ),
      ],
      internalMcps: List.from(_internalMcps),
      notification: _buildNotificationFromUi(),
    );
    _executors[index] = updated;
  }

  String _cleanPrompt(String p) {
    var s = p;
    final sepRegex = RegExp(
      r'^\+\+#\+\+(?:\[N(\d)\]|\[NT:([^\]]*)\])?(\[SATC\])?\s*',
      multiLine: false,
    );
    s = s.replaceFirst(sepRegex, '');
    return s.trim();
  }

  void _loadExecutorState(int index) {
    if (index < 0 || index >= _executors.length) return;
    _selectedExecutorIndex = index;
    final exec = _executors[index];

    _promptCtrl.text = exec.prompt;
    _loadSystemPrompt(exec.systemPrompt ?? '');
    _executorNameCtrl.text = exec.name;

    // LLM Config
    final llm = exec.llmConfig;
    if (llm != null) {
      _overrideLlm = true;
      _llmProviderCtrl.text = llm.provider;
      _llmBaseUrlCtrl.text = llm.baseUrl ?? '';
      _llmApiKeyCtrl.text = llm.apiKey ?? '';
      _llmModelCtrl.text = llm.model;
      _temperatureCtrl.text = llm.temperature.toString();
      _maxTokensCtrl.text = llm.maxTokens.toString();

      _topKCtrl.text = llm.extraParams['top_k']?.toString() ?? '';
      _topPCtrl.text = llm.extraParams['top_p']?.toString() ?? '';
      _repeatPenaltyCtrl.text =
          llm.extraParams['repeat_penalty']?.toString() ?? '';
      _seedCtrl.text = llm.extraParams['seed']?.toString() ?? '';
      _maxToolOutputSizeCtrl.text =
          llm.extraParams['max_tool_output_size']?.toString() ?? '';
      _tokenWarningThresholdCtrl.text =
          llm.extraParams['token_warning_threshold']?.toString() ?? '';
      _thinking = llm.extraParams['thinking'] as bool? ?? false;
      _useNativeToolCall =
          llm.extraParams['use_native_tool_call'] as bool? ?? true;
      _useSafeToolCall =
          llm.extraParams['use_safe_tool_call'] as bool? ?? false;
      _isSlm = llm.extraParams['is_slm'] as bool? ?? false;
      _isMultiModal = llm.extraParams['is_multi_modal'] as bool? ?? true;
    } else {
      _overrideLlm = false;
      _llmProviderCtrl.text = 'gemini';
      _llmBaseUrlCtrl.text = '';
      _llmApiKeyCtrl.text = '';
      _llmModelCtrl.text = '';
      _temperatureCtrl.text = '0.7';
      _maxTokensCtrl.text = '0';
      _topKCtrl.text = '';
      _topPCtrl.text = '';
      _repeatPenaltyCtrl.text = '';
      _seedCtrl.text = '';
      _maxToolOutputSizeCtrl.text = '';
      _tokenWarningThresholdCtrl.text = '';
      _thinking = false;
      _useNativeToolCall = true;
      _useSafeToolCall = false;
      _isSlm = false;
      _isMultiModal = true;
    }

    _chatMode = exec.chatMode;
    _stopAfterToolCall = exec.stopAfterToolCall;

    // Tools
    _mcpServers = List.from(exec.mcpTools);
    _internalMcps = List.from(exec.internalMcps);

    // Selected global servers
    final globalUrls = ExternalToolsSettingsService.instance.selectedServers
        .map((s) => s.serverUrl)
        .toSet();
    _selectedGlobalServerUrls = _mcpServers
        .map((s) => s.serverUrl)
        .where((url) => globalUrls.contains(url))
        .toSet();
    _mcpServers.removeWhere(
      (s) => _selectedGlobalServerUrls.contains(s.serverUrl),
    );

    _loadNotificationState(exec.notification);
  }

  TaskNotification _buildNotificationFromUi() {
    TaskNotification notification = TaskNotification();
    if (_outputType == 'email' && _emailToCtrl.text.isNotEmpty) {
      notification = TaskNotification(
        email: EmailNotification(
          recipients: _emailToCtrl.text
              .split(',')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList(),
          subject: _emailSubjectCtrl.text.isNotEmpty
              ? _emailSubjectCtrl.text.trim()
              : null,
          withAttachment: true,
          sendCondition: _emailSendConditionCtrl.text.isNotEmpty
              ? _emailSendConditionCtrl.text.trim()
              : 'always',
          conditionExpression: _emailConditionExprCtrl.text.trim().isNotEmpty
              ? _emailConditionExprCtrl.text.trim()
              : null,
        ),
        download: null,
        addExecutionLog: _addExecutionLogToOutput,
        zipOutputFiles: _zipOutputFiles,
      );
    }
    if (_outputType == 'file') {
      notification = TaskNotification(
        email: null,
        download: DownloadNotification(
          downloadPath: _downloadPathCtrl.text.trim().isEmpty
              ? null
              : _downloadPathCtrl.text.trim(),
          fileNamePattern: _downloadFilePatternCtrl.text.trim().isEmpty
              ? null
              : _downloadFilePatternCtrl.text.trim(),
        ),
        addExecutionLog: _addExecutionLogToOutput,
        zipOutputFiles: _zipOutputFiles,
      );
    }
    if (_outputType == 'sftp') {
      notification = TaskNotification(
        email: null,
        download: null,
        sftpOutput: SftpOutputConfig(
          useConfiguredSshServer: _sftpUseConfiguredSshServer,
          host: _sftpHostCtrl.text.trim(),
          port: int.tryParse(_sftpPortCtrl.text.trim()) ?? 22,
          username: _sftpUsernameCtrl.text.trim(),
          password: _sftpPasswordCtrl.text.isNotEmpty
              ? _sftpPasswordCtrl.text
              : null,
          privateKey: _sftpPrivateKeyPem.isNotEmpty ? _sftpPrivateKeyPem : null,
          remotePath: _sftpRemotePathCtrl.text.trim().isEmpty
              ? '/'
              : _sftpRemotePathCtrl.text.trim(),
          notifyByEmail: _sftpNotifyByEmail,
          notifyEmailAddress: _sftpNotifyEmailAddressCtrl.text.trim(),
          notifyEmailSubject: _sftpNotifyEmailSubjectCtrl.text.trim(),
          notifyEmailBody: _sftpNotifyEmailBodyCtrl.text.trim(),
        ),
        addExecutionLog: _addExecutionLogToOutput,
        zipOutputFiles: _zipOutputFiles,
      );
    }

    return TaskNotification(
      email: notification.email,
      download: notification.download,
      upload: notification.upload,
      sftpOutput: notification.sftpOutput,
      push: _pushEnabled
          ? PushNotification(
              title: _pushTitleCtrl.text.isNotEmpty
                  ? _pushTitleCtrl.text.trim()
                  : null,
            )
          : null,
      slack: _slackNotifyEnabled
          ? SlackNotification(
              sendCondition: _slackSendCondition,
              overrideChannel: _slackChannelCtrl.text.trim().isNotEmpty
                  ? _slackChannelCtrl.text.trim()
                  : null,
              withAttachment: _slackWithAttachment,
            )
          : null,
      whatsApp: _whatsAppNotifyEnabled
          ? WhatsAppNotification(
              sendCondition: _whatsAppSendCondition,
              overrideRecipient: _whatsAppRecipientCtrl.text.trim().isNotEmpty
                  ? _whatsAppRecipientCtrl.text.trim()
                  : null,
            )
          : null,
      addExecutionLog: _addExecutionLogToOutput,
      zipOutputFiles: _zipOutputFiles,
    );
  }

  void _loadNotificationState(TaskNotification notification) {
    _outputType = notification.email != null
        ? 'email'
        : (notification.sftpOutput != null
              ? 'sftp'
              : (notification.download != null ? 'file' : 'none'));
    _emailNotifyEnabled = notification.email != null;
    _emailToCtrl.text = notification.email?.recipients.join(', ') ?? '';
    _emailSubjectCtrl.text = notification.email?.subject ?? '';
    _emailSendConditionCtrl.text =
        notification.email?.sendCondition ?? 'always';
    _emailConditionExprCtrl.text =
        notification.email?.conditionExpression ?? '';

    _downloadPathCtrl.text = notification.download?.downloadPath ?? '';
    _downloadFilePatternCtrl.text =
        notification.download?.fileNamePattern ?? 'task_result_{date}.txt';

    _pushEnabled = notification.push != null;
    _pushTitleCtrl.text = notification.push?.title ?? '';

    _addExecutionLogToOutput = notification.addExecutionLog;
    _zipOutputFiles = notification.zipOutputFiles;

    _slackNotifyEnabled = notification.slack != null;
    _slackSendCondition = notification.slack?.sendCondition ?? 'always';
    _slackWithAttachment = notification.slack?.withAttachment ?? false;
    _slackChannelCtrl.text = notification.slack?.overrideChannel ?? '';

    _whatsAppNotifyEnabled = notification.whatsApp != null;
    _whatsAppSendCondition = notification.whatsApp?.sendCondition ?? 'always';
    _whatsAppRecipientCtrl.text =
        notification.whatsApp?.overrideRecipient ?? '';

    final sftp = notification.sftpOutput;
    _sftpUseConfiguredSshServer = sftp?.useConfiguredSshServer ?? true;
    _sftpHostCtrl.text = sftp?.host ?? '';
    _sftpPortCtrl.text = '${sftp?.port ?? 22}';
    _sftpUsernameCtrl.text = sftp?.username ?? '';
    _sftpPasswordCtrl.text = sftp?.password ?? '';
    _sftpPrivateKeyPem = sftp?.privateKey ?? '';
    _sftpPrivateKeyFileName = _sftpPrivateKeyPem.isNotEmpty
        ? '(custom key loaded)'
        : '';
    _sftpRemotePathCtrl.text = sftp?.remotePath ?? '/';
    _sftpNotifyByEmail = sftp?.notifyByEmail ?? false;
    _sftpNotifyEmailAddressCtrl.text = sftp?.notifyEmailAddress ?? '';
    _sftpNotifyEmailSubjectCtrl.text = sftp?.notifyEmailSubject ?? '';
    _sftpNotifyEmailBodyCtrl.text = sftp?.notifyEmailBody ?? '';
  }

  Future<void> _confirmDeleteExecutor(int index) async {
    if (_executors.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('An orchestrator must have at least one agent.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    final l = L.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Agent?'),
        content: Text(
          'Are you sure you want to delete "${_executors[index].name}"?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm == true) {
      _saveCurrentExecutorState();
      setState(() {
        final removedId = _executors[index].id;
        _executors.removeAt(index);
        _routingRules.removeWhere(
          (r) =>
              r.sourceAgentId == removedId ||
              r.targetAgentId == removedId,
        );

        if (_selectedExecutorIndex >= _executors.length) {
          _selectedExecutorIndex = _executors.length - 1;
        }

        final oldController = _tabController;
        oldController.removeListener(_handleTabSelection);
        _tabController = TabController(
          length: _executors.length,
          vsync: this,
          initialIndex: _selectedExecutorIndex,
        );
        _tabController.addListener(_handleTabSelection);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          oldController.dispose();
        });

        _loadExecutorState(_selectedExecutorIndex);
      });
    }
  }

  void _addExecutor() {
    _saveCurrentExecutorState();
    final newId = const Uuid().v4();
    final newName = 'Agent ${_executors.length + 1}';
    final newExec = Agent(
      id: newId,
      name: newName,
      prompt: '',
      systemPrompt: null,
      mcpTools: const [],
      internalMcps: const [],
    );
    setState(() {
      _executors.add(newExec);
      _selectedExecutorIndex = _executors.length - 1;

      final oldController = _tabController;
      oldController.removeListener(_handleTabSelection);
      _tabController = TabController(
        length: _executors.length,
        vsync: this,
        initialIndex: _selectedExecutorIndex,
      );
      _tabController.addListener(_handleTabSelection);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        oldController.dispose();
      });

      _loadExecutorState(_selectedExecutorIndex);
    });
  }

  Widget _buildAgentRoutingAndScheduling(Agent exec) {
    String routingType = 'sequential';
    if (exec.executionPlan != null) {
      routingType = 'scheduled';
    } else {
      final rules = _routingRules.where((r) => r.sourceAgentId == exec.id).toList();
      if (rules.isNotEmpty) {
        final first = rules.first;
        if (first.operator == 'stop') {
          routingType = 'none';
        } else {
          routingType = 'conditional';
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle('Routing Mode'),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: routingType,
          isExpanded: true,
          items: const [
            DropdownMenuItem(
              value: 'none',
              child: Text('None (Stops execution)'),
            ),
            DropdownMenuItem(
              value: 'sequential',
              child: Text('Sequential (Next agent)'),
            ),
            DropdownMenuItem(
              value: 'conditional',
              child: Text('Conditional (Branch)'),
            ),
            DropdownMenuItem(
              value: 'scheduled',
              child: Text('Scheduled (Independent)'),
            ),
          ],
          onChanged: (val) {
            if (val == null) return;
            setState(() {
              if (val == 'none') {
                _routingRules.removeWhere((r) => r.sourceAgentId == exec.id);
                _routingRules.add(
                  Edge(
                    id: const Uuid().v4(),
                    sourceAgentId: exec.id,
                    variable: 'task_result',
                    operator: 'stop',
                    value: '',
                    targetAgentId: '',
                  ),
                );
                _executors[_selectedExecutorIndex] = exec.copyWith(
                  clearExecutionPlan: true,
                );
              } else if (val == 'sequential') {
                _routingRules.removeWhere((r) => r.sourceAgentId == exec.id);
                _executors[_selectedExecutorIndex] = exec.copyWith(
                  clearExecutionPlan: true,
                );
              } else if (val == 'conditional') {
                _executors[_selectedExecutorIndex] = exec.copyWith(
                  clearExecutionPlan: true,
                );

                final otherExecutors = _executors
                    .where((e) => e.id != exec.id)
                    .toList();
                final targetId = otherExecutors.isNotEmpty
                    ? otherExecutors.first.id
                    : exec.id;

                _routingRules.removeWhere((r) => r.sourceAgentId == exec.id);
                _routingRules.add(
                  Edge(
                    id: const Uuid().v4(),
                    sourceAgentId: exec.id,
                    variable: 'task_result',
                    operator: 'contains',
                    value: '',
                    targetAgentId: targetId,
                  ),
                );
              } else if (val == 'scheduled') {
                _routingRules.removeWhere((r) => r.sourceAgentId == exec.id);
                _executors[_selectedExecutorIndex] = exec.copyWith(
                  executionPlan: const ExecutionPlan(
                    cronExpression: '0 8 * * *',
                  ),
                );
              }
            });
          },
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        const SizedBox(height: 16),

        if (routingType == 'conditional') ...[
          _buildConditionalRuleConfig(exec),
          const SizedBox(height: 16),
        ],

        if (routingType == 'scheduled' || _selectedExecutorIndex == 0) ...[
          _buildAgentSchedulePicker(exec),
        ] else ...[
          Card(
            color: Colors.orange.withValues(alpha: 0.1),
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.orange),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Scheduling is disabled because this agent is called sequentially or conditionally by a previous one.',
                      style: TextStyle(fontSize: 12, color: Colors.orange),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildConditionalRuleConfig(Agent exec) {
    final rules = _routingRules
        .where((r) => r.sourceAgentId == exec.id)
        .toList();
    final targetExecutors = _executors.where((e) => e.id != exec.id).toList();
    final l = L.of(context);

    if (targetExecutors.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          l.addAgentFirstWarning,
          style: const TextStyle(
            color: Colors.orange,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...rules.asMap().entries.map((entry) {
          final idx = entry.key;
          final rule = entry.value;
          final overallIndex = _routingRules.indexOf(rule);

          return Container(
            key: ValueKey(rule.id),
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Theme.of(context).dividerColor),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      l.conditionRuleHeader(idx + 1),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      onPressed: () {
                        setState(() {
                          _routingRules.removeAt(overallIndex);
                        });
                      },
                      tooltip: l.removeConditionRuleTooltip,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue:
                      targetExecutors.any((e) => e.id == rule.targetAgentId)
                      ? rule.targetAgentId
                      : targetExecutors.first.id,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: l.targetAgentLabel),
                  items: targetExecutors
                      .map(
                        (e) =>
                            DropdownMenuItem(value: e.id, child: Text(e.name)),
                      )
                      .toList(),
                  onChanged: (val) {
                    if (val == null) return;
                    setState(() {
                      _routingRules[overallIndex] = rule.copyWith(
                        targetAgentId: val,
                      );
                    });
                  },
                ),
                const SizedBox(height: 12),
                _buildOperatorAndValueRow(rule, overallIndex),
              ],
            ),
          );
        }),

        OutlinedButton.icon(
          onPressed: () {
            setState(() {
              _routingRules.add(
                Edge(
                  id: const Uuid().v4(),
                  sourceAgentId: exec.id,
                  variable: 'task_result',
                  operator: 'contains',
                  value: '',
                  targetAgentId: targetExecutors.first.id,
                ),
              );
            });
          },
          icon: const Icon(Icons.add),
          label: Text(l.addRoutingRuleLabel),
        ),
      ],
    );
  }

  Widget _buildOperatorAndValueRow(Edge rule, int overallIndex) {
    final l = L.of(context);
    final operators = [
      DropdownMenuItem(value: 'less', child: Text(l.operatorLess)),
      DropdownMenuItem(
        value: 'less_or_equals',
        child: Text(l.operatorLessOrEquals),
      ),
      DropdownMenuItem(value: 'equals', child: Text(l.operatorEquals)),
      DropdownMenuItem(value: 'not_equal', child: Text(l.operatorNotEqual)),
      DropdownMenuItem(
        value: 'greater_than',
        child: Text(l.operatorGreaterThan),
      ),
      DropdownMenuItem(
        value: 'greater_or_equals',
        child: Text(l.operatorGreaterOrEquals),
      ),
      DropdownMenuItem(value: 'contains', child: Text(l.operatorContains)),
      DropdownMenuItem(
        value: 'not_contains',
        child: Text(l.operatorNotContains),
      ),
      DropdownMenuItem(value: 'custom', child: Text(l.operatorCustom)),
      DropdownMenuItem(value: 'llm_eval', child: Text(l.operatorLlmEval)),
    ];

    final isCustom = rule.operator == 'custom';
    final isLlmEval = rule.operator == 'llm_eval';

    return Row(
      children: [
        Expanded(
          flex: 2,
          child: DropdownButtonFormField<String>(
            initialValue: rule.operator,
            isExpanded: true,
            decoration: InputDecoration(labelText: l.operatorLabel),
            items: operators,
            onChanged: (val) {
              if (val == null) return;
              setState(() {
                _routingRules[overallIndex] = rule.copyWith(
                  operator: val,
                  value: '',
                );
              });
            },
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 3,
          child: TextFormField(
            key: ValueKey('${rule.id}_val_${rule.operator}'),
            initialValue: rule.value,
            decoration: InputDecoration(
              labelText: isLlmEval
                  ? l.llmConditionLabel
                  : (isCustom ? l.customExpressionLabel : l.valueLabel),
              hintText: isLlmEval
                  ? l.llmConditionHint
                  : (isCustom ? l.customExpressionHint : l.valueHint),
            ),
            onChanged: (val) {
              _routingRules[overallIndex] = rule.copyWith(value: val.trim());
            },
          ),
        ),
      ],
    );
  }

  Widget _buildAgentSchedulePicker(Agent exec) {
    final int index = _executors.indexWhere((e) => e.id == exec.id);
    final bool isEnabled = _isAgentSchedulingEnabled(exec, index);
    print('[SCHEDULER_DIAGNOSTIC] index=$index, id=${exec.id}, _isSubtask=$_isSubtask, isEnabled=$isEnabled, agents=${_executors.map((e) => e.id).toList()}');

    final plan = isEnabled
        ? (exec.executionPlan ?? const ExecutionPlan(cronExpression: '0 8 * * *'))
        : const ExecutionPlan(cronExpression: '0 8 * * *');

    final l = L.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!isEnabled) ...[
          Card(
            color: Colors.orange.withValues(alpha: 0.1),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: Colors.orange),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l.schedulingDisabledWarning,
                      style: const TextStyle(fontSize: 12, color: Colors.orange),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        _sectionTitle(l.cronSchedule),
        const SizedBox(height: 8),
        TextFormField(
          key: ValueKey('cron_${exec.id}_${plan.cronExpression}'),
          initialValue: plan.cronExpression,
          enabled: isEnabled,
          decoration: InputDecoration(
            labelText: l.cronExpression,
            hintText: '0 8 * * *',
            suffixIcon: IconButton(
              icon: const Icon(Icons.calendar_month),
              onPressed: isEnabled ? () async {
                final res = await showDialog<Map<String, String>>(
                  context: context,
                  builder: (ctx) => SchedulePickerDialog(
                    initialCron: plan.cronExpression,
                    allowSubHourly: true,
                  ),
                );
                if (res != null && res['cron'] != null) {
                  final cronStr = res['cron']!;
                  final hintStr = res['hint'];
                  setState(() {
                    if (index == 0) {
                      _cronCtrl.text = cronStr;
                      _scheduleHintCtrl.text = hintStr ?? '';
                    }
                    _executors[index] = exec.copyWith(
                      executionPlan: ExecutionPlan(
                        cronExpression: cronStr,
                        scheduleHint: hintStr ?? plan.scheduleHint,
                        maxRetries: plan.maxRetries,
                        retryDelayMinutes: plan.retryDelayMinutes,
                      ),
                    );
                  });
                }
              } : null,
            ),
          ),
          onChanged: (val) {
            setState(() {
              if (index == 0) {
                _cronCtrl.text = val.trim();
              }
              _executors[index] = exec.copyWith(
                executionPlan: ExecutionPlan(
                  cronExpression: val.trim(),
                  scheduleHint: plan.scheduleHint,
                  maxRetries: plan.maxRetries,
                  retryDelayMinutes: plan.retryDelayMinutes,
                ),
              );
            });
          },
          style: const TextStyle(fontFamily: 'monospace'),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            { l.scheduleEveryNMinutes(15): '*/15 * * * *' },
            { l.cronHourly: '0 * * * *' },
            { l.cronDaily8am: '0 8 * * *' },
            { l.cronDaily6pm: '0 18 * * *' },
            { l.cronMonFri9am: '0 9 * * 1-5' },
            { l.cronWeeklyMon: '0 8 * * 1' },
            { l.cronMonthly1st: '0 8 1 * *' },
          ].map((presetMap) {
            final label = presetMap.keys.first;
            final cronVal = presetMap.values.first;
            return ActionChip(
              label: Text(label, style: const TextStyle(fontSize: 12)),
              onPressed: isEnabled ? () {
                setState(() {
                  if (index == 0) {
                    _cronCtrl.text = cronVal;
                    _scheduleHintCtrl.text = label;
                  }
                  _executors[index] = exec.copyWith(
                    executionPlan: ExecutionPlan(
                      cronExpression: cronVal,
                      scheduleHint: label,
                      maxRetries: plan.maxRetries,
                      retryDelayMinutes: plan.retryDelayMinutes,
                    ),
                  );
                });
              } : null,
              visualDensity: VisualDensity.compact,
            );
          }).toList(),
        ),
        const SizedBox(height: 12),
        TextFormField(
          key: ValueKey('hint_${exec.id}_${plan.scheduleHint}'),
          initialValue: plan.scheduleHint ?? '',
          enabled: isEnabled,
          decoration: InputDecoration(
            labelText: l.scheduleDescription,
            hintText: l.scheduleDescriptionHint,
          ),
          onChanged: (val) {
            setState(() {
              if (index == 0) {
                _scheduleHintCtrl.text = val.trim();
              }
              _executors[index] = exec.copyWith(
                executionPlan: ExecutionPlan(
                  cronExpression: plan.cronExpression,
                  scheduleHint: val.trim().isNotEmpty ? val.trim() : null,
                  maxRetries: plan.maxRetries,
                  retryDelayMinutes: plan.retryDelayMinutes,
                ),
              );
            });
          },
        ),
        const SizedBox(height: 24),
        _sectionTitle(l.errorHandling),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextFormField(
                key: ValueKey('retries_${exec.id}_${plan.maxRetries}'),
                initialValue: '${plan.maxRetries}',
                enabled: isEnabled,
                decoration: InputDecoration(labelText: l.maxRetries),
                keyboardType: TextInputType.number,
                onChanged: (val) {
                  final retries = int.tryParse(val) ?? 3;
                  setState(() {
                    if (index == 0) {
                      _maxRetriesCtrl.text = '$retries';
                    }
                    _executors[index] = exec.copyWith(
                      executionPlan: ExecutionPlan(
                        cronExpression: plan.cronExpression,
                        scheduleHint: plan.scheduleHint,
                        maxRetries: retries,
                        retryDelayMinutes: plan.retryDelayMinutes,
                      ),
                    );
                  });
                },
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: TextFormField(
                key: ValueKey('delay_${exec.id}_${plan.retryDelayMinutes}'),
                initialValue: '${plan.retryDelayMinutes}',
                enabled: isEnabled,
                decoration: InputDecoration(labelText: l.retryDelay),
                keyboardType: TextInputType.number,
                onChanged: (val) {
                  final delay = int.tryParse(val) ?? 15;
                  setState(() {
                    if (index == 0) {
                      _retryDelayCtrl.text = '$delay';
                    }
                    _executors[index] = exec.copyWith(
                      executionPlan: ExecutionPlan(
                        cronExpression: plan.cronExpression,
                        scheduleHint: plan.scheduleHint,
                        maxRetries: plan.maxRetries,
                        retryDelayMinutes: delay,
                      ),
                    );
                  });
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _refreshSelectableGithubMcpServers() async {
    final isServerMode = ref.read(serverModeProvider).value?.isRemote ?? false;
    if (!isServerMode) {
      if (mounted) {
        setState(() => _remoteGithubMcpServers = const []);
      }
      return;
    }

    final client = ref.read(serverApiClientProvider);
    if (client == null) return;

    try {
      final raw = await client.listRegistryServers();
      final defs = _dedupeGithubMcpServers(
        raw
            .map(GithubMcpServerDefinition.fromJson)
            .where((s) => s.isInstalled && s.isActive),
      );
      if (mounted) {
        setState(() => _remoteGithubMcpServers = defs);
      }
    } catch (e) {
      log.warning('[TaskEdit] Failed to load remote GitHub MCP servers: $e');
    }
  }

  List<GithubMcpServerDefinition> _dedupeGithubMcpServers(
    Iterable<GithubMcpServerDefinition> servers,
  ) {
    final seen = <String>{};
    final result = <GithubMcpServerDefinition>[];
    for (final s in servers) {
      final key = (s.packageName.isNotEmpty ? s.packageName : s.name)
          .toLowerCase();
      if (seen.add(key)) result.add(s);
    }
    return result;
  }

  Future<List<String>> _fetchRemoteMcpToolNames(String serverId) async {
    final client = ref.read(serverApiClientProvider);
    if (client == null) return const [];

    try {
      await client.startMcpServer(serverId);
    } catch (e) {
      // Non-fatal: server may already be started or temporarily unavailable.
      log.warning('[TaskEdit] startMcpServer warning for $serverId: $e');
    }

    try {
      final tools = await client.getMcpServerTools(serverId);
      final names =
          tools
              .map((t) => (t['name'] ?? '').toString().trim())
              .where((n) => n.isNotEmpty)
              .toSet()
              .toList()
            ..sort();
      return names;
    } catch (e) {
      log.warning('[TaskEdit] getMcpServerTools failed for $serverId: $e');
      return const [];
    }
  }

  bool _sameStringList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  String _githubMcpDisplayName(String serverId, {String? fallback}) {
    for (final def in _remoteGithubMcpServers) {
      if (def.id == serverId) return def.displayName;
    }
    final local = GithubMcpLibraryService.instance.findById(serverId);
    if (local != null) return local.displayName;
    return fallback ?? serverId;
  }

  Future<void> _eagerDiscoverSelectedRemoteMcpTools() async {
    final isServerMode = ref.read(serverModeProvider).value?.isRemote ?? false;
    if (!isServerMode) {
      // In local mode, eagerly discover selected local GitHub MCP tools in the background!
      for (final mcp in _internalMcps.where(
        (m) => m.enabled && m.mcpType.startsWith('gh_mcp_'),
      )) {
        final serverId = mcp.mcpType.substring('gh_mcp_'.length);
        final def = GithubMcpLibraryService.instance.findById(serverId);
        if (def != null && def.isInstalled) {
          if (_prefetchedRemoteMcpTools[serverId]?.isNotEmpty == true) continue;
          GithubMcpRuntimeService.instance.discoverLocalMcpTools(def).then((
            names,
          ) {
            if (names.isNotEmpty && mounted) {
              setState(() {
                _prefetchedRemoteMcpTools[serverId] = names;
              });
            }
          });
        }
      }
      return;
    }

    final client = ref.read(serverApiClientProvider);
    if (client == null) return;

    final extSvc = ExternalToolsSettingsService.instance;
    final updatedGlobalServers = List<McpToolConfig>.from(
      extSvc.selectedServers,
    );
    var globalChanged = false;

    for (final url in _selectedGlobalServerUrls) {
      final names = await _fetchRemoteMcpToolNames(url);
      if (names.isEmpty) continue;

      _prefetchedRemoteMcpTools[url] = names;

      final idx = updatedGlobalServers.indexWhere((s) => s.serverUrl == url);
      if (idx >= 0) {
        final cur = updatedGlobalServers[idx];
        if (!_sameStringList(cur.discoveredTools, names)) {
          updatedGlobalServers[idx] = cur.copyWith(discoveredTools: names);
          globalChanged = true;
        }
      }
    }

    final updatedTaskServers = List<McpToolConfig>.from(_mcpServers);
    var taskServersChanged = false;
    for (var i = 0; i < updatedTaskServers.length; i++) {
      final server = updatedTaskServers[i];
      final names = await _fetchRemoteMcpToolNames(server.serverUrl);
      if (names.isEmpty) continue;

      _prefetchedRemoteMcpTools[server.serverUrl] = names;
      if (!_sameStringList(server.discoveredTools, names)) {
        updatedTaskServers[i] = server.copyWith(discoveredTools: names);
        taskServersChanged = true;
      }
    }

    for (final mcp in _internalMcps.where(
      (m) => m.enabled && m.mcpType.startsWith('gh_mcp_'),
    )) {
      final serverId = mcp.mcpType.substring('gh_mcp_'.length);
      final names = await _fetchRemoteMcpToolNames(serverId);
      if (names.isNotEmpty) {
        _prefetchedRemoteMcpTools[serverId] = names;
      }
    }

    if (globalChanged) {
      // Server mode: keep remote state in-memory only on the client.
      extSvc.applyInMemory(selectedServers: updatedGlobalServers);
    }

    if (mounted && taskServersChanged) {
      setState(() {
        _mcpServers = updatedTaskServers;
      });
    }
  }

  Future<void> _loadPersistedWebsiteSearchForTaskEdit() async {
    try {
      // Primary source: global URLs from Data Sources settings (shared index).
      final ds = DataSourcesSettingsService.instance;
      if (!ds.isLoaded) await ds.load();
      final globalUrls = ds.websiteIndexUrls
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      if (mounted) setState(() => _globalWebsiteUrls = globalUrls);

      // Secondary source: extra playground-session URLs.
      final prefs = await SharedPreferences.getInstance();
      final extraRaw = (prefs.getString(_websiteSeedUrlsPrefsKey) ?? '');
      final extraUrls = extraRaw
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty && !globalUrls.contains(e))
          .toList();

      final savedMaxPages =
          (prefs.getInt(_websiteMaxPagesPrefsKey) ?? ds.websiteIndexMaxPages)
              .clamp(1, 1000);
      final websiteIdx = _internalMcps.indexWhere(
        (m) => m.mcpType == 'website_search',
      );
      if (websiteIdx < 0 || !mounted) return;

      final websiteEntry = _internalMcps[websiteIdx];
      final params = Map<String, dynamic>.from(websiteEntry.initParams);

      // Existing task-specific URLs (saved with the task).
      final existingRaw = (params['websiteUrls'] as String? ?? '').trim();
      final existingUrls = existingRaw
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();

      // Merge: global + (existing task-specific or playground extra), deduplicated.
      final mergedUrls = <String>[...globalUrls];
      for (final u in (existingUrls.isNotEmpty ? existingUrls : extraUrls)) {
        if (!mergedUrls.contains(u)) mergedUrls.add(u);
      }

      var changed = false;
      if (mergedUrls.isNotEmpty &&
          params['websiteUrls'] != mergedUrls.join(', ')) {
        params['websiteUrls'] = mergedUrls.join(', ');
        changed = true;
      }
      if (params['maxPages'] == null) {
        params['maxPages'] = savedMaxPages;
        changed = true;
      }

      if (!mounted) return;
      if (globalUrls.isNotEmpty || changed) {
        setState(() {
          if (changed) {
            _internalMcps[websiteIdx] = websiteEntry.copyWith(
              initParams: params,
            );
          } else {}
        });
      }
    } catch (_) {
      // Ignore persistence errors in editor prefill
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _nameCtrl.dispose();
    _descriptionCtrl.dispose();
    _promptCtrl.dispose();
    _systemPromptUserCtrl.dispose();
    _systemPromptSkillsCtrl.dispose();
    _agentIdCtrl.dispose();
    _cronCtrl.dispose();
    _scheduleHintCtrl.dispose();
    _maxRetriesCtrl.dispose();
    _retryDelayCtrl.dispose();
    _timeoutCtrl.dispose();
    _llmProviderCtrl.dispose();
    _llmModelCtrl.dispose();
    _llmApiKeyCtrl.dispose();
    _llmBaseUrlCtrl.dispose();
    _temperatureCtrl.dispose();
    _maxTokensCtrl.dispose();
    _maxToolOutputSizeCtrl.dispose();
    _tokenWarningThresholdCtrl.dispose();
    _topKCtrl.dispose();
    _topPCtrl.dispose();
    _repeatPenaltyCtrl.dispose();
    _seedCtrl.dispose();
    _emailToCtrl.dispose();
    _emailSubjectCtrl.dispose();
    _emailSendConditionCtrl.dispose();
    _emailConditionExprCtrl.dispose();
    _downloadPathCtrl.dispose();
    _downloadFilePatternCtrl.dispose();
    _pushTitleCtrl.dispose();
    _pushTokenCtrl.dispose();
    _slackChannelCtrl.dispose();
    _whatsAppRecipientCtrl.dispose();
    _sftpHostCtrl.dispose();
    _sftpPortCtrl.dispose();
    _sftpUsernameCtrl.dispose();
    _sftpPasswordCtrl.dispose();
    _sftpRemotePathCtrl.dispose();
    _sftpNotifyEmailAddressCtrl.dispose();
    _sftpNotifyEmailSubjectCtrl.dispose();
    _sftpNotifyEmailBodyCtrl.dispose();
    _chainConditionCtrl.dispose();
    _websiteUrlCtrl.dispose();
    super.dispose();
  }

  // ═══════════════════════════════════════════════════════
  // INTERACTIVE MODE
  // ═══════════════════════════════════════════════════════
  (WorkflowTask, TaskLlmOverrides) _buildTransientTaskAndOverrides() {
    _saveCurrentExecutorState();

    final exec = _executors[_selectedExecutorIndex];

    final List<InternalMcpEntry> agentInternalMcps = List.from(exec.internalMcps);
    if (!_toolboxEnabled) {
      agentInternalMcps.add(
        InternalMcpEntry(
          id: const Uuid().v4(),
          mcpType: 'toolbox',
          label: 'Toolbox',
          enabled: false,
          initParams: const {},
        ),
      );
    }

    // Build a transient WorkflowTask for testing ONLY the currently selected agent
    final task = WorkflowTask(
      id: widget.task?.id ?? const Uuid().v4(),
      name: _nameCtrl.text.trim().isEmpty ? 'Untitled' : _nameCtrl.text.trim(),
      prompt: exec.prompt,
      mcpTools: exec.mcpTools,
      internalMcps: agentInternalMcps,
      executionPlan: ExecutionPlan(cronExpression: _cronCtrl.text.trim()),
      agents: [exec],
      edges: const [],
      chatMode: exec.chatMode,
      stopAfterToolCall: exec.stopAfterToolCall,
      systemPrompt: exec.systemPrompt,
      llmConfig: exec.llmConfig,
    );

    final cfg = exec.llmConfig;
    final overrides = TaskLlmOverrides(
      systemPrompt: exec.systemPrompt?.trim().isNotEmpty == true
          ? exec.systemPrompt!.trim()
          : null,
      llmProvider: cfg != null && cfg.provider.isNotEmpty
          ? cfg.provider
          : null,
      llmModel: cfg != null && cfg.model.isNotEmpty
          ? cfg.model
          : null,
      llmApiKey: cfg?.apiKey?.isNotEmpty == true
          ? cfg!.apiKey
          : null,
      llmBaseUrl: cfg?.baseUrl?.isNotEmpty == true
          ? cfg!.baseUrl
          : null,
      temperature: cfg?.temperature,
      maxTokens: cfg?.maxTokens,
      maxToolOutputSize: cfg?.extraParams != null ? (cfg!.extraParams['max_tool_output_size'] as num?)?.toInt() : null,
      tokenWarningThreshold: cfg?.extraParams != null ? (cfg!.extraParams['token_warning_threshold'] as num?)?.toInt() : null,
      isMultiModal: cfg?.extraParams != null ? cfg!.extraParams['is_multi_modal'] as bool? : null,
    );

    return (task, overrides);
  }

  bool _validateLlmConfig() {
    if (_executors.isEmpty) return false;
    final exec = _executors[_selectedExecutorIndex];
    final settings = ref.read(llmSettingsProvider);
    final isRemote = ref.read(serverModeProvider).value?.isRemote ?? false;
    
    // Check if the current agent has overrides
    final hasOverride = exec.llmConfig != null;
    final provider = hasOverride ? exec.llmConfig!.provider : settings.provider.configKey;
    final model = hasOverride ? exec.llmConfig!.model : settings.model;
    
    if (!isRemote && (provider.isEmpty || provider == 'none' || model.isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Kein gültiges Modell konfiguriert. Bitte wählen Sie ein LLM-Modell in den Einstellungen.'),
          backgroundColor: Colors.red,
        ),
      );
      return false;
    }
    return true;
  }

  Future<void> _runPromptTest() async {
    if (!_validateLlmConfig()) return;

    final (task, overrides) = _buildTransientTaskAndOverrides();

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PromptTestDialog(task: task, overrides: overrides),
    );
  }

  // ═══════════════════════════════════════════════════════
  // SAVE
  // ═══════════════════════════════════════════════════════
  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final l = L.of(context);

    // Validate disk output folder is chosen when output type is 'file'.
    if (_outputType == 'file' && _downloadPathCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l.outputFolderRequired),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }

    if (_selectedGlobalServerUrls.length > _externalServerSelectionLimit) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'External MCP limit reached (${_selectedGlobalServerUrls.length}/$_externalServerSelectionLimit).',
          ),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }

    log.info(
      '[TaskEdit] Save started (${widget.isEditing ? "update" : "create"})',
    );
    setState(() => _isSaving = true);

    try {
      final now = DateTime.now();
      final tags = const <String>[];

      // Data Sources → auto-derived from selected tools + global DataSourcesSettingsService.
      // Gmail OAuth is injected whenever gmail/google_drive/google_calendar is selected OR
      // the task sends an email notification (both require the Google OAuth credentials).
      // Web search config is injected whenever the web_search tool is selected.
      final ds = DataSourcesSettingsService.instance;
      final hasGoogleTool = _internalMcps.any(
        (m) =>
            m.enabled &&
            const {
              'gmail',
              'google_drive',
              'google_calendar',
            }.contains(m.mcpType),
      );
      final needsEmail =
          (_outputType == 'email' && _emailToCtrl.text.isNotEmpty) ||
          hasGoogleTool;
      EmailProviderConfig? emailProvider;
      if (needsEmail && ds.isEmailConfigured) {
        emailProvider = EmailProviderConfig(
          type: 'google',
          authData: EmailAuthData(
            data: {
              'client_id': ds.gmailClientId,
              'client_secret': ds.gmailClientSecret,
              'access_token': ds.gmailAccessToken,
              'refresh_token': ds.gmailRefreshToken,
              if (ds.gmailTokenExpiry != null)
                'expires_at': ds.gmailTokenExpiry!.toIso8601String(),
              if (ds.gmailAccountEmail.isNotEmpty)
                'email': ds.gmailAccountEmail,
            },
          ),
        );
      }
      final hasWebSearch = _internalMcps.any(
        (m) => m.enabled && m.mcpType == 'web_search',
      );
      WebSearchConfig? webSearch;
      if (hasWebSearch && ds.isWebSearchConfigured) {
        webSearch = WebSearchConfig(
          type: switch (ds.webSearchProvider) {
            WebSearchProvider.serpapi => 'serpapi',
            WebSearchProvider.serper => 'serper',
            WebSearchProvider.custom => 'custom',
            _ => 'duckduckgo',
          },
          apiKey: ds.webSearchApiKey.isNotEmpty ? ds.webSearchApiKey : null,
          searchEngineId: null,
          maxResults: ds.webSearchMaxResults,
        );
      }

      _saveCurrentExecutorState();

      final TaskNotification finalTaskNotification;
      if (_executors.length > 1) {
        finalTaskNotification = _globalNotification;
      } else {
        finalTaskNotification = _executors.isNotEmpty
            ? _executors.first.notification
            : const TaskNotification();
      }

      final String combinedPrompt;
      final String? combinedSystemPrompt;
      if (_executors.length > 1) {
        final List<Step> workflowSteps = [];
        for (final exec in _executors) {
          final List<String> tabToolNames = [];
          for (final t in exec.mcpTools) {
            tabToolNames.addAll(t.discoveredTools);
          }
          for (final m in exec.internalMcps) {
            if (m.enabled) {
              final server = InternalMcpRegistry().create(m.mcpType);
              if (server != null) {
                tabToolNames.addAll(server.tools.map((t) => t.name));
              }
            }
          }

          final execSteps = parseWorkflowSteps(exec.prompt);
          for (int j = 0; j < execSteps.length; j++) {
            final s = execSteps[j];
            final stepTools = s.enabledToolNames ?? (tabToolNames.isNotEmpty ? tabToolNames : null);
            final stepSatc = s.stopAfterToolCall || (j == execSteps.length - 1 && exec.stopAfterToolCall);

            workflowSteps.add(Step(
              text: s.text,
              enabledToolNames: stepTools,
              stopAfterToolCall: stepSatc,
            ));
          }
        }
        combinedPrompt = serializeWorkflowSteps(workflowSteps);
        combinedSystemPrompt = _executors
            .map((e) => e.systemPrompt ?? '')
            .join('\n++#++\n');
      } else {
        combinedPrompt = _executors.isNotEmpty
            ? _executors.first.prompt
            : '';
        combinedSystemPrompt = _executors.isNotEmpty
            ? (_executors.first.systemPrompt ?? '')
            : null;
      }

      final firstExec = _executors.isNotEmpty ? _executors.first : null;
      final autoDerivedIsSubtask = _isSubtask;

      final List<McpToolConfig> taskMcpTools;
      final List<InternalMcpEntry> taskInternalMcps;
      if (_executors.length > 1) {
        final List<McpToolConfig> combinedMcpTools = [];
        final Set<String> seenUrls = {};
        for (final exec in _executors) {
          for (final tool in exec.mcpTools) {
            if (!seenUrls.contains(tool.serverUrl)) {
              seenUrls.add(tool.serverUrl);
              combinedMcpTools.add(tool);
            }
          }
        }
        taskMcpTools = combinedMcpTools;

        final List<InternalMcpEntry> combinedInternalMcps = [];
        final Set<String> seenTypes = {};
        for (final exec in _executors) {
          for (final entry in exec.internalMcps) {
            if (!seenTypes.contains(entry.mcpType)) {
              seenTypes.add(entry.mcpType);
              combinedInternalMcps.add(entry);
            }
          }
        }
        taskInternalMcps = combinedInternalMcps;
      } else {
        taskMcpTools = firstExec?.mcpTools ?? const [];
        taskInternalMcps = firstExec?.internalMcps ?? const [];
      }

      var task = WorkflowTask(
        id: widget.task?.id ?? const Uuid().v4(),
        name: _nameCtrl.text.trim(),
        description: _descriptionCtrl.text.isNotEmpty
            ? _descriptionCtrl.text.trim()
            : null,
        agentId: _agentIdCtrl.text.isNotEmpty ? _agentIdCtrl.text.trim() : null,
        systemPrompt: combinedSystemPrompt,
        prompt: combinedPrompt,
        llmConfig: firstExec?.llmConfig,
        enabled: _enabled,
        chatMode: firstExec?.chatMode ?? false,
        stopAfterToolCall: firstExec?.stopAfterToolCall ?? false,
        executionPlan: ExecutionPlan(
          cronExpression: _cronCtrl.text.trim(),
          scheduleHint: _scheduleHintCtrl.text.isNotEmpty
              ? _scheduleHintCtrl.text.trim()
              : null,
          maxRetries: int.tryParse(_maxRetriesCtrl.text) ?? 3,
          retryDelayMinutes: int.tryParse(_retryDelayCtrl.text) ?? 15,
        ),
        mcpTools: taskMcpTools,
        internalMcps: taskInternalMcps,
        providers: TaskProviders(email: emailProvider, webSearch: webSearch),
        notification: finalTaskNotification,
        tags: tags,
        chainConfig: _buildChainConfigFromUi(autoDerivedIsSubtask),
        execution: () {
          final oldExec = widget.task?.execution ?? const TaskExecution();
          // If the cron expression changed, clear nextRun so the new schedule
          // takes effect immediately without being blocked by the stale value.
          final oldCron = widget.task?.executionPlan.cronExpression ?? '';
          final newCron = _cronCtrl.text.trim();
          if (widget.task != null && oldCron != newCron) {
            log.info(
              '[TaskEdit] Cron changed "$oldCron" → "$newCron": clearing nextRun',
            );
            return TaskExecution(
              lastRun: oldExec.lastRun,
              nextRun: null, // cleared — recalculated after next run
              lastResult: oldExec.lastResult,
              lastError: oldExec.lastError,
              runCount: oldExec.runCount,
              consecutiveFailures: oldExec.consecutiveFailures,
              history: oldExec.history,
            );
          }
          return oldExec;
        }(),
        createdAt: widget.task?.createdAt ?? now,
        updatedAt: now,
        agents: _executors,
        edges: _routingRules,
      );

      log.info('[TaskEdit] Saving task: id=${task.id} name="${task.name}"');
      log.verbose('[TaskEdit] mcpServers: ${_mcpServers.length} servers');
      for (final s in _mcpServers) {
        log.verbose(
          '[TaskEdit]   MCP: ${s.name ?? "unnamed"} -> ${s.serverUrl}',
        );
      }
      log.verbose(
        '[TaskEdit] hasGoogleTool=$hasGoogleTool, hasWebSearch=$hasWebSearch, emailProvider=${emailProvider != null}, webSearch=${webSearch != null}',
      );
      log.verbose(
        '[TaskEdit] emailNotify=$_emailNotifyEnabled, push=$_pushEnabled',
      );
      log.verbose(
        '[TaskEdit] Task JSON: ${truncate(task.toJson().toString())}',
      );

      await ref.read(taskListProvider.notifier).saveTask(task);

      log.info('[TaskEdit] Task saved successfully');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(widget.isEditing ? l.taskUpdated : l.taskCreated),
            backgroundColor: AppTheme.success,
          ),
        );
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l.failedToSave(e.toString())),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isEditing ? l.editTask : l.newTask),
        actions: [
          if (widget.isEditing && widget.task != null)
            IconButton(
              icon: const Icon(
                Icons.ios_share,
                color: Colors.amber,
              ),
              tooltip: 'Export as Skill',
              onPressed: () async {
                final res = await WorkflowExportService.exportWorkflow(context, widget.task!);
                if (!mounted) return;
                if (res.error != null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Export failed: ${res.error}')),
                  );
                } else if (res.savedPath != null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Workflow exported to: ${res.savedPath}')),
                  );
                }
              },
            ),
          if (_isSaving)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.0),
              ),
            )
          else
            IconButton(
              onPressed: _save,
              icon: const Icon(Icons.save),
              tooltip: l.save,
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Form(
          key: _formKey,
          child: NestedScrollView(
            headerSliverBuilder: (context, innerBoxIsScrolled) {
              return [
                SliverToBoxAdapter(
                  child: Column(
                    children: [
                      _buildTopLevelProperties(l),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _StickyTabBarDelegate(
                    child: _buildAgentsTabBarRow(l),
                  ),
                ),
              ];
            },
            body: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 32),
              child: Column(
                children: [
                  if (_executors.isNotEmpty) _buildAgentEditorSpace(l),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopLevelProperties(L l) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${l.taskName} *',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                ),
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? l.nameRequired : null,
              ),
            ],
          ),
        ),
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: Theme.of(context).dividerColor),
          ),
          child: ExpansionTile(
            initiallyExpanded: false,
            title: Text(
              l.description,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: TextFormField(
                  controller: _descriptionCtrl,
                  decoration: InputDecoration(
                    hintText: l.descriptionHint,
                    border: const OutlineInputBorder(),
                  ),
                  maxLines: 3,
                ),
              ),
            ],
          ),
        ),
        if (_executors.length > 1)
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: Theme.of(context).dividerColor),
            ),
            child: ExpansionTile(
              initiallyExpanded: false,
              leading: const Icon(
                Icons.notifications_active,
                color: AppTheme.primaryBlue,
              ),
              title: const Text(
                'Global Output / Notifications',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              ),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: TaskNotificationEditor(
                    initialValue: _globalNotification,
                    onChanged: (val) {
                      _globalNotification = val;
                    },
                  ),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: SwitchListTile(
            title: Text(l.enabled),
            subtitle: Text(
              l.taskEnabledSubtitle,
              style: const TextStyle(fontSize: 11),
            ),
            value: _enabled,
            onChanged: (v) => setState(() => _enabled = v),
            activeTrackColor: AppTheme.primaryBlue,
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    );
  }

  void _renameAgent(int idx) async {
    final exec = _executors[idx];
    final ctrl = TextEditingController(text: exec.name);
    final l = L.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.renameAgentTitle),
        content: TextFormField(
          controller: ctrl,
          decoration: InputDecoration(labelText: l.agentNameLabel),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.renameLabel),
          ),
        ],
      ),
    );
    if (confirm == true && ctrl.text.trim().isNotEmpty) {
      setState(() {
        _executors[idx] = exec.copyWith(name: ctrl.text.trim());
        if (_selectedExecutorIndex == idx) {
          _executorNameCtrl.text = ctrl.text.trim();
        }
      });
    }
  }

  Widget _buildAgentsTabBarRow(L l) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? Colors.black.withValues(alpha: 0.2)
            : Colors.grey[200]!.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: TabBar(
              controller: _tabController,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              indicatorSize: TabBarIndicatorSize.tab,
              tabs: _executors.asMap().entries.map((entry) {
                final idx = entry.key;
                final exec = entry.value;
                return Tab(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        exec.name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      if (idx > 0) ...[
                        const SizedBox(width: 16),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 16),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          onPressed: () => _confirmDeleteExecutor(idx),
                          tooltip: l.removeAgentTooltip,
                        ),
                      ],
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
          IconButton(
            icon: const Icon(
              Icons.add_circle_outline,
              color: Color(0xFF7C3AED),
            ),
            onPressed: _addExecutor,
            tooltip: l.addAgentTooltip,
          ),
        ],
      ),
    );
  }

  bool _isAgentSchedulingEnabled(Agent exec, int index) {
    if (index == 0) return true;
    final isTarget = _routingRules.any((r) => r.targetAgentId == exec.id && r.operator != 'stop' && r.sourceAgentId != exec.id);
    return !isTarget;
  }

  bool _isUpstream(String candidateId, String currentId) {
    final visited = <String>{};
    bool dfs(String curr) {
      if (curr == currentId) return true;
      if (visited.contains(curr)) return false;
      visited.add(curr);
      final children = <String>[];
      final currRules = _routingRules.where((r) => r.sourceAgentId == curr).toList();
      if (currRules.isNotEmpty && currRules.first.operator != 'stop') {
        children.addAll(currRules.map((r) => r.targetAgentId).where((id) => id.isNotEmpty));
      } else if (currRules.isEmpty) {
        final idx = _executors.indexWhere((e) => e.id == curr);
        if (idx != -1 && idx < _executors.length - 1) {
          final nextId = _executors[idx + 1].id;
          final isTargetOfAnyRule = _routingRules.any((r) => r.targetAgentId == nextId && r.operator != 'stop');
          if (!isTargetOfAnyRule) {
            children.add(nextId);
          }
        }
      }
      for (final child in children) {
        if (dfs(child)) return true;
      }
      return false;
    }
    return dfs(candidateId);
  }

  void _cleanRoutingRulesForTarget(String targetId, String sourceId) {
    _routingRules.removeWhere((r) => r.targetAgentId == targetId && r.sourceAgentId != sourceId);
    
    // Also clean up executionPlan if it gets disabled
    for (int i = 0; i < _executors.length; i++) {
      final e = _executors[i];
      if (!_isAgentSchedulingEnabled(e, i) && e.executionPlan != null) {
        _executors[i] = e.copyWith(clearExecutionPlan: true);
      }
    }
  }


  Widget _buildDesktopSubSectionsTabBar(L l) {
    final sections = [
      l.tabBuiltIn,
      l.tabPrompts,
      l.tabLlm,
      l.routingModeLabel,
      l.tabSchedule,
      l.tabNotify,
    ];
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: sections.asMap().entries.map((entry) {
          final idx = entry.key;
          final label = entry.value;
          final isSelected = _activeSubSectionIndex == idx;

          return InkWell(
            onTap: () {
              setState(() {
                _activeSubSectionIndex = idx;
              });
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: isSelected
                        ? Theme.of(context).colorScheme.primary
                        : Colors.transparent,
                    width: 2.0,
                  ),
                ),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  color: isSelected
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(
                          context,
                        ).textTheme.bodyMedium?.color?.withValues(alpha: 0.6),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildActiveSubSectionContent(L l, Agent exec) {
    switch (_activeSubSectionIndex) {
      case 0: // Tools
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _buildInternalMcpContent(),
        );
      case 1: // Prompts
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildSystemPromptSection(),
            const SizedBox(height: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text(
                      l.taskPrompt,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Text(' *', style: TextStyle(color: Colors.red)),
                  ],
                ),
                const SizedBox(height: 8),
                StepListEditor(
                  controller: _promptCtrl,
                  minLines: 3,
                  maxLines: 8,
                  hintText: l.taskPromptHint,
                  availableToolGroups: _availableToolGroupsForSteps,
                  onToolSelectionChanged: _updateSkillsSection,
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? l.promptRequired : null,
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    onPressed: _runPromptTest,
                    icon: const Icon(Icons.play_circle_outline, size: 18),
                    label: const Text('Testen'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.primaryBlue,
                    ),
                  ),
                ),
              ],
            ),
          ],
        );
      case 2: // LLM
        return _buildLlmSettingsSection(l);
      case 3: // Routing
        return _buildAgentRoutingTab(l, exec);
      case 4: // Schedule
        return _buildAgentSchedulingTab(exec);
      case 5: // Output
        return _buildAgentOutputSection(exec);
      default:
        return const SizedBox();
    }
  }

  Widget _buildLlmSettingsSection(L l) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: _buildLlmContent(),
    );
  }

  Widget _buildAgentRoutingTab(L l, Agent exec) {
    final rules = _routingRules
        .where((r) => r.sourceAgentId == exec.id)
        .toList();
    final otherExecutors = _executors
        .where((e) => e.id != exec.id && !_isUpstream(e.id, exec.id))
        .toList();

    // Determine current routing type
    String currentRoutingType = 'none';
    if (rules.isNotEmpty) {
      final rule = rules.first;
      if (rule.operator == 'stop') {
        currentRoutingType = 'none';
      } else if (rule.operator == 'sequential' || rule.operator == 'always') {
        currentRoutingType = 'sequential';
      } else {
        currentRoutingType = 'conditional';
      }
    }

    final currentRule = rules.isNotEmpty ? rules.first : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle(l.nextStepRoutingTitle),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: currentRoutingType,
          isExpanded: true,
          items: const [
            DropdownMenuItem(
              value: 'none',
              child: Text('None (stops execution)'),
            ),
            DropdownMenuItem(
              value: 'sequential',
              child: Text('Sequential (next agent)'),
            ),
            DropdownMenuItem(
              value: 'conditional',
              child: Text('Conditional LLM'),
            ),
          ],
          onChanged: (val) {
            if (val == null) return;
            setState(() {
              if (val == 'none') {
                _routingRules.removeWhere((r) => r.sourceAgentId == exec.id);
                _routingRules.add(
                  Edge(
                    id: const Uuid().v4(),
                    sourceAgentId: exec.id,
                    variable: 'task_result',
                    operator: 'stop',
                    value: '',
                    targetAgentId: '',
                  ),
                );
                _executors[_selectedExecutorIndex] = exec.copyWith(clearExecutionPlan: true);
              } else if (val == 'sequential') {
                _executors[_selectedExecutorIndex] = exec.copyWith(clearExecutionPlan: true);
                final targetId = otherExecutors.isNotEmpty
                    ? otherExecutors.first.id
                    : exec.id;
                _routingRules.removeWhere((r) => r.sourceAgentId == exec.id);
                _routingRules.add(
                  Edge(
                    id: const Uuid().v4(),
                    sourceAgentId: exec.id,
                    variable: 'task_result',
                    operator: 'sequential',
                    value: '',
                    targetAgentId: targetId,
                  ),
                );
                if (targetId != exec.id) {
                  _cleanRoutingRulesForTarget(targetId, exec.id);
                }
              } else if (val == 'conditional') {
                _executors[_selectedExecutorIndex] = exec.copyWith(clearExecutionPlan: true);
                final targetId = otherExecutors.isNotEmpty
                    ? otherExecutors.first.id
                    : exec.id;
                _routingRules.removeWhere((r) => r.sourceAgentId == exec.id);
                _routingRules.add(
                  Edge(
                    id: const Uuid().v4(),
                    sourceAgentId: exec.id,
                    variable: 'task_result',
                    operator: 'llm_eval',
                    value: '',
                    targetAgentId: targetId,
                  ),
                );
                if (targetId != exec.id) {
                  _cleanRoutingRulesForTarget(targetId, exec.id);
                }
              }
            });
          },
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        const SizedBox(height: 16),
        if (currentRoutingType == 'sequential' && currentRule != null) ...[
          DropdownButtonFormField<String>(
            initialValue: otherExecutors.any((e) => e.id == currentRule.targetAgentId)
                ? currentRule.targetAgentId
                : (otherExecutors.isNotEmpty ? otherExecutors.first.id : exec.id),
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Target Agent',
              border: OutlineInputBorder(),
            ),
            items: otherExecutors.map((e) {
              return DropdownMenuItem(
                value: e.id,
                child: Text(e.name),
              );
            }).toList(),
            onChanged: (targetId) {
              if (targetId == null) return;
              setState(() {
                final ruleIdx = _routingRules.indexWhere((r) => r.id == currentRule.id);
                if (ruleIdx != -1) {
                  _routingRules[ruleIdx] = currentRule.copyWith(targetAgentId: targetId);
                }
                _cleanRoutingRulesForTarget(targetId, exec.id);
              });
            },
          ),
        ],

        if (currentRoutingType == 'conditional') ...[
          const Text(
            'Branching conditions (evaluated by LLM):',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          ...rules.asMap().entries.map((entry) {
            final idx = entry.key;
            final rule = entry.value;
            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              color: Colors.purple.withValues(alpha: 0.03),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: Colors.purple.withValues(alpha: 0.15)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Text('Branch #${idx + 1}', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.purple)),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, color: Colors.red, size: 18),
                          onPressed: () {
                            setState(() {
                              _routingRules.removeWhere((r) => r.id == rule.id);
                            });
                          },
                        )
                      ],
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: otherExecutors.any((e) => e.id == rule.targetAgentId)
                          ? rule.targetAgentId
                          : (otherExecutors.isNotEmpty ? otherExecutors.first.id : null),
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Target Agent', border: OutlineInputBorder()),
                      items: otherExecutors.map((e) {
                        return DropdownMenuItem(value: e.id, child: Text(e.name));
                      }).toList(),
                      onChanged: (val) {
                        if (val == null) return;
                        setState(() {
                          final ruleIdx = _routingRules.indexWhere((r) => r.id == rule.id);
                          if (ruleIdx != -1) {
                            _routingRules[ruleIdx] = rule.copyWith(targetAgentId: val);
                          }
                          _cleanRoutingRulesForTarget(val, exec.id);
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      initialValue: rule.value,
                      decoration: const InputDecoration(
                        labelText: 'Condition description',
                        hintText: 'e.g. average temperature is less than 0',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (val) {
                        setState(() {
                          final ruleIdx = _routingRules.indexWhere((r) => r.id == rule.id);
                          if (ruleIdx != -1) {
                            _routingRules[ruleIdx] = rule.copyWith(value: val.trim());
                          }
                        });
                      },
                    ),
                  ],
                ),
              ),
            );
          }),
          ElevatedButton.icon(
            onPressed: () {
              setState(() {
                final targetId = otherExecutors.isNotEmpty ? otherExecutors.first.id : exec.id;
                _routingRules.add(
                  Edge(
                    id: const Uuid().v4(),
                    sourceAgentId: exec.id,
                    variable: 'task_result',
                    operator: 'llm_eval',
                    value: '',
                    targetAgentId: targetId,
                  ),
                );
                if (targetId != exec.id) {
                  _cleanRoutingRulesForTarget(targetId, exec.id);
                }
              });
            },
            icon: const Icon(Icons.add),
            label: const Text('Add Branching Condition'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.purple,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildAgentSchedulingTab(Agent exec) {
    return _buildAgentSchedulePicker(exec);
  }

  Widget _buildAgentOutputSection(Agent exec) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: _buildNotifyContent(),
    );
  }

  Widget _buildAgentEditorSpace(L l) {
    final exec = _executors[_selectedExecutorIndex];
    final isDesktop = MediaQuery.of(context).size.width >= 600;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 16),
          TextFormField(
            controller: _executorNameCtrl,
            decoration: InputDecoration(
              labelText: l.agentNameLabel,
              border: const OutlineInputBorder(),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
            ),
            onChanged: (val) {
              if (val.trim().isNotEmpty) {
                setState(() {
                  _executors[_selectedExecutorIndex] = exec.copyWith(
                    name: val.trim(),
                  );
                });
              }
            },
          ),
          const SizedBox(height: 12),
          if (isDesktop) ...[
            _buildDesktopSubSectionsTabBar(l),
            const SizedBox(height: 16),
            _buildActiveSubSectionContent(l, exec),
          ] else ...[
            _buildExpansionSection(
              icon: Icons.extension,
              title: l.tabBuiltIn,
              children: _buildInternalMcpContent(),
            ),
            const SizedBox(height: 8),
            _buildExpansionSection(
              icon: Icons.edit_note,
              title: l.sectionPrompts,
              initiallyExpanded: true,
              children: [
                _buildSystemPromptSection(),
                const SizedBox(height: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Text(
                          l.taskPrompt,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const Spacer(),
                        Tooltip(
                          message: 'Prompts testen',
                          child: InkWell(
                            onTap: _runPromptTest,
                            borderRadius: BorderRadius.circular(20),
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.play_circle_outline,
                                    size: 16,
                                    color: AppTheme.primaryBlue,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    'Testen',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: AppTheme.primaryBlue,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Tooltip(
                          message: 'KI-Assistent: Prompt generieren',
                          child: InkWell(
                            onTap: () => _showPromptWizardDialog(
                              context,
                              _promptCtrl,
                              isSystemPrompt: false,
                            ),
                            borderRadius: BorderRadius.circular(20),
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.auto_awesome,
                                    size: 16,
                                    color: AppTheme.primaryBlue,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    'KI-Assistent',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: AppTheme.primaryBlue,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    StepListEditor(
                      controller: _promptCtrl,
                      minLines: 3,
                      maxLines: 8,
                      hintText: l.taskPromptHint,
                      availableToolGroups: _availableToolGroupsForSteps,
                      onToolSelectionChanged: _updateSkillsSection,
                      validator: (v) => (v == null || v.trim().isEmpty)
                          ? l.promptRequired
                          : null,
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            _buildExpansionSection(
              icon: Icons.smart_toy,
              title: l.tabLlm,
              children: _buildLlmContent(),
            ),
            const SizedBox(height: 8),
            _buildExpansionSection(
              icon: Icons.call_split,
              title: 'Routing',
              children: [_buildAgentRoutingTab(l, exec)],
            ),
            const SizedBox(height: 8),
            _buildExpansionSection(
              icon: Icons.schedule,
              title: l.tabSchedule,
              children: [_buildAgentSchedulingTab(exec)],
            ),
            const SizedBox(height: 8),
            _buildExpansionSection(
              icon: Icons.output,
              title: 'Output',
              children: [_buildAgentOutputSection(exec)],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildOrchestratorSettings(L l) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: _buildExpansionSection(
        icon: Icons.settings,
        title: 'Orchestrator Settings',
        children: [
          SwitchListTile(
            title: Text(l.enabled),
            subtitle: Text(l.taskEnabledSubtitle),
            value: _enabled,
            onChanged: (v) => setState(() => _enabled = v),
            activeTrackColor: AppTheme.primaryBlue,
            contentPadding: EdgeInsets.zero,
          ),
          SwitchListTile(
            title: const Text('Is Sub-task'),
            subtitle: const Text(
              'Triggered only by another task, not scheduled directly.',
            ),
            value: _isSubtask,
            onChanged: (v) => setState(() => _isSubtask = v),
            activeTrackColor: Colors.teal,
            contentPadding: EdgeInsets.zero,
          ),
        ],
      ),
    );
  }

  Widget _buildGlobalOutputSection(L l) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: _buildExpansionSection(
        icon: Icons.output,
        title: l.tabNotify,
        initiallyExpanded: false,
        children: _buildNotifyContent(),
      ),
    );
  }

  /// Desktop layout: horizontal tabs with swipeable tab views.
  Widget _buildDesktopBody() {
    return TabBarView(
      controller: _tabController,
      physics: const NeverScrollableScrollPhysics(),
      children: [
        _buildInternalMcpTab(),
        _buildBasicTab(),
        _buildScheduleTab(),

        _buildLlmTab(),
        _buildNotifyTab(),
      ],
    );
  }

  /// Mobile layout: vertical scrollable list of expandable tiles.
  Widget _buildMobileBody(L l) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return ListView(
      padding: EdgeInsets.fromLTRB(0, 8, 0, bottomInset + 16),
      children: [
        _buildExpansionSection(
          icon: Icons.edit_note,
          title: l.tabBasic,
          initiallyExpanded: true,
          children: _buildBasicContent(),
        ),
        _buildExpansionSection(
          icon: Icons.schedule,
          title: l.tabSchedule,
          children: [_buildScheduleWrapper()],
        ),

        _buildExpansionSection(
          icon: Icons.smart_toy,
          title: l.tabLlm,
          children: _buildLlmContent(),
        ),
        _buildExpansionSection(
          icon: Icons.output,
          title: l.tabNotify,
          initiallyExpanded: true,
          children: _buildNotifyContent(),
        ),
      ],
    );
  }

  /// A single expandable tile section for the mobile layout.
  Widget _buildExpansionSection({
    required IconData icon,
    required String title,
    required List<Widget> children,
    bool initiallyExpanded = false,
  }) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: Icon(icon, color: AppTheme.primaryBlue),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        initiallyExpanded: initiallyExpanded,
        dense: true,
        minTileHeight: 44,
        tilePadding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
        childrenPadding: const EdgeInsets.fromLTRB(12, 2, 12, 10),
        expandedAlignment: Alignment.centerLeft,
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  // ═══════════════════════════════════════════════════════
  // Tab 1: Basic
  // ═══════════════════════════════════════════════════════
  List<Widget> _buildBasicContent() {
    final l = L.of(context);
    return [
      _sectionTitle(l.sectionGeneral),
      const SizedBox(height: 12),
      SwitchListTile(
        title: Text(l.enabled),
        subtitle: Text(l.taskEnabledSubtitle),
        value: _enabled,
        onChanged: (v) => setState(() => _enabled = v),
        activeTrackColor: AppTheme.primaryBlue,
        contentPadding: EdgeInsets.zero,
      ),
      SwitchListTile(
        title: const Text('Chat mode'),
        subtitle: const Text(
          'Direct LLM chat — no system prompt, no tools. Ideal for SLMs doing simple tasks (formatting, translation, etc.)',
        ),
        value: _chatMode,
        onChanged: (v) => setState(() => _chatMode = v),
        activeTrackColor: Colors.orange,
        contentPadding: EdgeInsets.zero,
      ),
      const SizedBox(height: 24),
      ExpansionTile(
        leading: Icon(Icons.extension, color: AppTheme.primaryBlue),
        title: Text(
          l.tabBuiltIn,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        initiallyExpanded: false,
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(top: 4),
        expandedAlignment: Alignment.centerLeft,
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: _buildInternalMcpContent(),
      ),
      const SizedBox(height: 8),
      _sectionTitle(l.sectionPrompts),
      _buildSystemPromptSection(),
      const SizedBox(height: 12),
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                l.taskPrompt,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              Tooltip(
                message: 'Prompts testen',
                child: InkWell(
                  onTap: _runPromptTest,
                  borderRadius: BorderRadius.circular(20),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.play_circle_outline,
                          size: 16,
                          color: AppTheme.primaryBlue,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Testen',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppTheme.primaryBlue,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: 'KI-Assistent: Prompt generieren',
                child: InkWell(
                  onTap: () => _showPromptWizardDialog(
                    context,
                    _promptCtrl,
                    isSystemPrompt: false,
                  ),
                  borderRadius: BorderRadius.circular(20),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.auto_awesome,
                          size: 16,
                          color: AppTheme.primaryBlue,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'KI-Assistent',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppTheme.primaryBlue,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          StepListEditor(
            controller: _promptCtrl,
            minLines: 3,
            maxLines: 8,
            hintText: l.taskPromptHint,
            availableToolGroups: _availableToolGroupsForSteps,
            onToolSelectionChanged: _updateSkillsSection,
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? l.promptRequired : null,
          ),
        ],
      ),
    ];
  }

  Widget _buildBasicTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: _buildBasicContent(),
    );
  }

  // ═══════════════════════════════════════════════════════
  // Tab 2: Schedule
  // ═══════════════════════════════════════════════════════
  List<Widget> _buildScheduleContent() {
    final l = L.of(context);
    return [
      _sectionTitle(l.cronSchedule),
      TextFormField(
        controller: _cronCtrl,
        decoration: InputDecoration(
          labelText: l.cronExpression,
          hintText: '0 8 * * *',
          helperText: l.cronFormat,
          suffixIcon: IconButton(
            icon: const Icon(Icons.calendar_month),
            tooltip: l.schedulePickerTitle,
            onPressed: _showSchedulePickerDialog,
          ),
        ),
        validator: (v) =>
            (v == null || v.trim().isEmpty) ? l.cronRequired : null,
        style: const TextStyle(fontFamily: 'monospace'),
      ),
      const SizedBox(height: 8),
      _buildCronPresets(),
      const SizedBox(height: 12),
      const SizedBox(height: 24),
      _sectionTitle(l.errorHandling),
      Row(
        children: [
          Expanded(
            child: TextFormField(
              controller: _maxRetriesCtrl,
              decoration: InputDecoration(labelText: l.maxRetries),
              keyboardType: TextInputType.number,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: TextFormField(
              controller: _retryDelayCtrl,
              decoration: InputDecoration(labelText: l.retryDelay),
              keyboardType: TextInputType.number,
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      TextFormField(
        controller: _timeoutCtrl,
        decoration: InputDecoration(labelText: l.timeout, hintText: '300'),
        keyboardType: TextInputType.number,
      ),
    ];
  }

  Widget _buildScheduleWrapper() {
    if (_isSubtask) return _buildScheduleDisabledBanner();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: _buildScheduleContent(),
    );
  }

  Widget _buildScheduleTab() {
    if (_isSubtask) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: _buildScheduleDisabledBanner(),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: _buildScheduleContent(),
    );
  }

  Widget _buildScheduleDisabledBanner() {
    final l = L.of(context);
    return Card(
      color: AppTheme.primaryBlue.withAlpha(25),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.info_outline, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                l.scheduleDisabledSubtask,
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ═════════════════════════════════════════════════════════
  // Tab 2b: Task Chaining
  // ═════════════════════════════════════════════════════════

  /// Build [TaskChainConfig] from the current UI state, returning null if no chaining is set.
  TaskChainConfig? _buildChainConfigFromUi(bool autoDerivedIsSubtask) {
    if (!autoDerivedIsSubtask &&
        !_chainWithCondition &&
        _chainOnMatchId == null) {
      return null;
    }
    final condition = _chainWithCondition
        ? _chainConditionCtrl.text.trim()
        : null;
    return TaskChainConfig(
      isSubtask: autoDerivedIsSubtask,
      triggerCondition: condition?.isNotEmpty == true ? condition : null,
      onMatchTaskId: _chainOnMatchId,
      onNoMatchTaskId: _chainWithCondition ? _chainOnNoMatchId : null,
    );
  }

  /// Show a picker dialog listing subtasks and call [onPicked] with the chosen task's ID.
  Future<void> _pickChainTask(void Function(String) onPicked) async {
    final currentId = widget.task?.id;
    final allTasks = switch (ref.read(taskListProvider)) {
      AsyncData(:final value) =>
        value.where((t) => t.isSubtask && t.id != currentId).toList(),
      _ => const <WorkflowTask>[],
    };
    if (!mounted) return;
    final l = L.of(context);
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(l.chainPickTask),
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          content: SizedBox(
            width: 320,
            child: allTasks.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      l.noSubtasksAvailable,
                      style: Theme.of(ctx).textTheme.bodyMedium,
                    ),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: allTasks.length,
                    separatorBuilder: (separatorCtx, separatorIdx) =>
                        const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final t = allTasks[i];
                      return ListTile(
                        title: Text(
                          t.name,
                          style: const TextStyle(fontSize: 14),
                        ),
                        subtitle: Text(
                          t.id,
                          style: const TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                        ),
                        dense: true,
                        onTap: () {
                          onPicked(t.id);
                          Navigator.pop(ctx);
                        },
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l.cancel),
            ),
          ],
        );
      },
    );
  }

  /// A read-only picker row that shows [label] + the resolved task name for [taskId].
  Widget _buildTaskPickerRow({
    required String label,
    required String? taskId,
    required VoidCallback onPick,
    required VoidCallback onClear,
  }) {
    // Resolve task name from the cached task list.
    final taskName = taskId == null
        ? null
        : switch (ref.read(taskListProvider)) {
            AsyncData(:final value) =>
              value.where((t) => t.id == taskId).firstOrNull?.name,
            _ => null,
          };

    return InkWell(
      onTap: onPick,
      borderRadius: BorderRadius.circular(8),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (taskId != null)
                IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  tooltip: L.of(context).clear,
                  onPressed: onClear,
                ),
              IconButton(
                icon: const Icon(Icons.search, size: 20),
                tooltip: label,
                onPressed: onPick,
              ),
            ],
          ),
        ),
        child: Text(
          taskName ?? taskId ?? '—',
          style: TextStyle(
            fontSize: 14,
            color: taskId == null ? Colors.grey[500] : null,
          ),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  /// A banner shown at the top of Pro-only sections when the user is on the free tier.
  Widget _buildProFeatureBanner({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return GestureDetector(
      onTap: null,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.primaryBlue.withAlpha(18),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.primaryBlue.withAlpha(80)),
        ),
        child: Row(
          children: [
            Icon(
              Icons.workspace_premium,
              color: AppTheme.primaryBlue,
              size: 28,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: null,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                minimumSize: Size.zero,
              ),
              child: Text(
                'Upgrade',
                style: TextStyle(
                  color: AppTheme.primaryBlue,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<ToolGroup> get _availableToolGroupsForSteps {
    final groups = <ToolGroup>[];
    // Toolbox is always-on unless explicitly disabled
    if (_toolboxEnabled) {
      final toolbox = InternalMcpRegistry().create('toolbox');
      if (toolbox != null && toolbox.tools.isNotEmpty) {
        groups.add(
          ToolGroup(
            name: toolbox.displayName,
            toolNames: toolbox.tools.map((t) => t.name).toList(),
          ),
        );
      }
    }
    final activeMgr = ref.read(activeTaskProvider)?.mcpManager;
    for (final mcp in _internalMcps.where((m) => m.enabled)) {
      if (mcp.mcpType.startsWith('gh_mcp_')) {
        final serverId = mcp.mcpType.substring('gh_mcp_'.length);
        List<String> names = const [];
        if (activeMgr != null) {
          final clientDef = activeMgr.clients
              .where(
                (c) =>
                    c.name == 'internal_${mcp.mcpType}' ||
                    c.name == 'remote_$serverId',
              )
              .firstOrNull;
          if (clientDef != null) {
            names = clientDef.availableTools.map((t) => t.name).toList();
          }
        }
        if (names.isEmpty) {
          names = _prefetchedRemoteMcpTools[serverId] ?? const <String>[];
        }
        final displayName = _githubMcpDisplayName(
          serverId,
          fallback: mcp.label,
        );
        groups.add(ToolGroup(name: displayName, toolNames: names));
        continue;
      }
      final server = InternalMcpRegistry().create(mcp.mcpType);
      if (server != null && server.tools.isNotEmpty) {
        groups.add(
          ToolGroup(
            name: mcp.label ?? mcp.mcpType,
            toolNames: server.tools.map((t) => t.name).toList(),
          ),
        );
      }
    }
    final globalServers = ExternalToolsSettingsService.instance.selectedServers;
    for (final url in _selectedGlobalServerUrls) {
      final s = globalServers.firstWhere(
        (s) => s.serverUrl == url,
        orElse: () => McpToolConfig(serverUrl: url),
      );
      List<String> names = const [];
      if (activeMgr != null) {
        final clientDef = activeMgr.clients
            .where((c) => c.name == (s.name ?? Uri.parse(url).host))
            .firstOrNull;
        if (clientDef != null) {
          names = clientDef.availableTools.map((t) => t.name).toList();
        }
      }
      if (names.isEmpty) {
        names = s.discoveredTools.isNotEmpty
            ? s.discoveredTools
            : (_prefetchedRemoteMcpTools[url] ?? const <String>[]);
      }
      groups.add(ToolGroup(name: s.name ?? url, toolNames: names));
    }
    for (final server in _mcpServers) {
      List<String> names = const [];
      if (activeMgr != null) {
        final clientDef = activeMgr.clients
            .where(
              (c) =>
                  c.name == (server.name ?? Uri.parse(server.serverUrl).host),
            )
            .firstOrNull;
        if (clientDef != null) {
          names = clientDef.availableTools.map((t) => t.name).toList();
        }
      }
      if (names.isEmpty) {
        names = server.discoveredTools.isNotEmpty
            ? server.discoveredTools
            : (_prefetchedRemoteMcpTools[server.serverUrl] ?? const <String>[]);
      }
      groups.add(
        ToolGroup(name: server.name ?? server.serverUrl, toolNames: names),
      );
    }
    return groups;
  }

  /// Show the schedule picker dialog (accordion-style: Minutes, Hourly, Daily, Weekly, Monthly)
  void _showSchedulePickerDialog() {
    // Parse current cron to pre-select
    String? selectedCategory;
    final parts = _cronCtrl.text.trim().split(RegExp(r'\s+'));
    if (parts.length == 5) {
      // minutes: * * * * * or */N * * * *
      // A plain numeric minute with hour='*' is hourly, not minutes.
      if ((parts[0] == '*' || parts[0].contains('/')) &&
          parts[1] == '*' &&
          parts[2] == '*' &&
          parts[3] == '*' &&
          parts[4] == '*') {
        selectedCategory = 'minutes';
        // monthly: specific day-of-month, no day-of-week
      } else if (parts[4] == '*' &&
          parts[3] == '*' &&
          parts[2] != '*' &&
          !parts[2].contains('/')) {
        selectedCategory = 'monthly';
        // weekly: specific day-of-week
      } else if (parts[4] != '*') {
        selectedCategory = 'weekly';
        // hourly: hour is * or */N (e.g. 0 * * * * or 0 */6 * * *)
      } else if (parts[1] == '*' || parts[1].contains('/')) {
        selectedCategory = 'hourly';
        // daily: specific hour and minute
      } else {
        selectedCategory = 'daily';
      }
    }

    showDialog(
      context: context,
      builder: (ctx) => SchedulePickerDialog(
        initialCron: _cronCtrl.text.trim(),
        initialCategory: selectedCategory,
      ),
    ).then((result) {
      if (result != null && result is Map<String, String>) {
        setState(() {
          _cronCtrl.text = result['cron']!;
          _scheduleHintCtrl.text = result['hint'] ?? '';
        });
      }
    });
  }

  Widget _buildCronPresets() {
    final l = L.of(context);
    final presets = {
      l.scheduleEveryNMinutes(15): '*/15 * * * *',
      l.cronHourly: '0 * * * *',
      l.cronDaily8am: '0 8 * * *',
      l.cronDaily6pm: '0 18 * * *',
      l.cronMonFri9am: '0 9 * * 1-5',
      l.cronWeeklyMon: '0 8 * * 1',
      l.cronMonthly1st: '0 8 1 * *',
    };
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: presets.entries
          .map(
            (e) => ActionChip(
              label: Text(e.key, style: const TextStyle(fontSize: 12)),
              onPressed: () {
                _cronCtrl.text = e.value;
                _scheduleHintCtrl.text = e.key;
              },
              visualDensity: VisualDensity.compact,
            ),
          )
          .toList(),
    );
  }

  List<Widget> _buildLlmContent() {
    final l = L.of(context);
    final llmSettings = ref.read(llmSettingsProvider);
    final isServerMode = ref.watch(serverModeProvider).value?.isRemote ?? false;
    final serverClient = isServerMode ? ref.read(serverApiClientProvider) : null;

    return [
      _sectionTitle(l.llmOverride),
      SwitchListTile(
        title: Text(l.overrideDefaultLlm),
        subtitle: Text(l.overrideDefaultLlmSubtitle),
        value: _overrideLlm,
        onChanged: (v) {
          setState(() => _overrideLlm = v);
          _updateSkillsSection();
        },
        activeTrackColor: AppTheme.primaryBlue,
        contentPadding: EdgeInsets.zero,
      ),
      if (_overrideLlm) ...[
        LlmSettingsFormWidget(
          providerKey: _llmProviderCtrl.text.trim(),
          modelController: _llmModelCtrl,
          apiKeyController: _llmApiKeyCtrl,
          baseUrlController: _llmBaseUrlCtrl,
          temperatureController: _temperatureCtrl,
          maxTokensController: _maxTokensCtrl,
          isSlm: _isSlm,
          isMultiModal: _isMultiModal,
          thinking: _thinking,
          useNativeToolCall: _useNativeToolCall,
          useSafeToolCall: _useSafeToolCall,
          enableToolParameterAutoRecovery: true,
          service: llmSettings,
          serverClient: serverClient,
          showLlm2Option: true,
          showNoneOption: true,
          onApplyDefault: llmSettings.isConfigured
              ? () {
                  _applyLlmDefaults(llmSettings);
                }
              : null,
          onProviderChanged: (key) {
            setState(() {
              _llmProviderCtrl.text = key;
            });
            _updateSkillsSection();
          },
          onModelChanged: (model) {
            setState(() {});
          },
          onSlmChanged: (v) => setState(() => _isSlm = v),
          onMultiModalChanged: (v) => setState(() => _isMultiModal = v),
          onThinkingChanged: (v) => setState(() => _thinking = v),
          onUseNativeToolCallChanged: (v) =>
              setState(() => _useNativeToolCall = v),
          onUseSafeToolCallChanged: (v) =>
              setState(() => _useSafeToolCall = v),
        ),
      ],
    ];
  }

  Widget _buildLlmTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: _buildLlmContent(),
    );
  }

  Widget _buildDiscoveryInfo(McpToolConfig server) {
    final l = L.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l.discovered,
          style: TextStyle(
            fontSize: 12,
            color: Colors.grey[600],
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        if (server.discoveredTools.isNotEmpty) ...[
          Row(
            children: [
              Icon(Icons.build, size: 14, color: AppTheme.primaryBlue),
              const SizedBox(width: 4),
              Text(
                l.toolsCount(server.discoveredTools.length),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: server.discoveredTools
                .map(
                  (t) => Chip(
                    label: Text(t, style: const TextStyle(fontSize: 10)),
                    backgroundColor: AppTheme.primaryBlue.withAlpha(30),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 8),
        ],
        if (server.discoveredPrompts.isNotEmpty) ...[
          Row(
            children: [
              const Icon(Icons.chat, size: 14, color: Colors.orange),
              const SizedBox(width: 4),
              Text(
                l.promptsCount(server.discoveredPrompts.length),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          ...server.discoveredPrompts.map(
            (p) => Text('  · $p', style: const TextStyle(fontSize: 12)),
          ),
          const SizedBox(height: 8),
        ],
        if (server.discoveredResources.isNotEmpty) ...[
          Row(
            children: [
              const Icon(Icons.folder, size: 14, color: Colors.teal),
              const SizedBox(width: 4),
              Text(
                l.resourcesCount(server.discoveredResources.length),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          ...server.discoveredResources.map(
            (r) => Text('  · $r', style: const TextStyle(fontSize: 12)),
          ),
        ],
      ],
    );
  }

  // ─── MCP actions ────────────────────────────────────

  void _addMcpServer() {
    _showMcpEditDialog(null, -1);
  }

  void _editMcpServer(int index) {
    _showMcpEditDialog(_mcpServers[index], index);
  }

  void _removeMcpServer(int index) {
    setState(() => _mcpServers.removeAt(index));
  }

  Future<void> _testMcpServer(int index) async {
    final server = _mcpServers[index];
    final messenger = ScaffoldMessenger.of(context);

    messenger.showSnackBar(
      SnackBar(
        content: Text(
          L.of(context).testingServerMsg(server.name ?? server.serverUrl),
        ),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );

    try {
      final result = await ExternalToolsSettingsService.instance.testMcpServer(
        serverUrl: server.serverUrl,
        mcpEndpoint: server.mcpEndpoint,
      );
      if (!mounted) return;

      final success = result['success'] == true;
      final message = (result['message'] ?? '').toString();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            success ? L.of(context).mcpTestSuccessMsg(message) : message,
          ),
          backgroundColor: success ? AppTheme.success : AppTheme.error,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 6),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(L.of(context).mcpTestFailedMsg(e.toString())),
          backgroundColor: AppTheme.error,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  void _showMcpEditDialog(McpToolConfig? existing, int index) async {
    final l = L.of(context);
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final urlCtrl = TextEditingController(text: existing?.serverUrl ?? '');
    final endpointCtrl = TextEditingController(
      text: existing?.mcpEndpoint ?? '/mcp',
    );
    final specCtrl = TextEditingController(
      text: existing?.specificationUrl ?? '',
    );
    final keyCtrl = TextEditingController(text: existing?.apiKey ?? '');
    final pwdCtrl = TextEditingController(text: existing?.apiPassword ?? '');
    final formKey = GlobalKey<FormState>();

    final result = await showDialog<McpToolConfig>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing != null ? l.editMcpServer : l.addMcpServer),
        content: SizedBox(
          width: 400,
          child: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: nameCtrl,
                    decoration: InputDecoration(
                      labelText: l.serverName,
                      hintText: l.serverNameHint,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: urlCtrl,
                    decoration: InputDecoration(
                      labelText: l.serverUrl,
                      hintText: l.serverUrlHint,
                    ),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? l.urlRequired : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: endpointCtrl,
                    decoration: InputDecoration(
                      labelText: l.mcpEndpoint,
                      hintText: l.mcpEndpointHint,
                      helperText: l.mcpEndpointHelper,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: specCtrl,
                    decoration: InputDecoration(
                      labelText: l.specificationUrl,
                      hintText: l.specificationUrlHint,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: keyCtrl,
                    decoration: InputDecoration(
                      labelText: l.apiKey,
                      hintText: l.optional,
                    ),
                    obscureText: true,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: pwdCtrl,
                    decoration: InputDecoration(
                      labelText: l.apiPassword,
                      hintText: l.optional,
                    ),
                    obscureText: true,
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () {
              if (!formKey.currentState!.validate()) return;
              Navigator.pop(
                ctx,
                McpToolConfig(
                  serverUrl: urlCtrl.text.trim(),
                  name: nameCtrl.text.isNotEmpty ? nameCtrl.text.trim() : null,
                  mcpEndpoint: endpointCtrl.text.isNotEmpty
                      ? endpointCtrl.text.trim()
                      : '/mcp',
                  specificationUrl: specCtrl.text.isNotEmpty
                      ? specCtrl.text.trim()
                      : null,
                  apiKey: keyCtrl.text.isNotEmpty ? keyCtrl.text.trim() : null,
                  apiPassword: pwdCtrl.text.isNotEmpty
                      ? pwdCtrl.text.trim()
                      : null,
                  enabledTools: existing?.enabledTools,
                  discoveredTools: existing?.discoveredTools ?? const [],
                  discoveredPrompts: existing?.discoveredPrompts ?? const [],
                  discoveredResources:
                      existing?.discoveredResources ?? const [],
                ),
              );
            },
            child: Text(l.save),
          ),
        ],
      ),
    );

    if (result != null) {
      setState(() {
        if (index >= 0) {
          _mcpServers[index] = result;
        } else {
          _mcpServers.add(result);
        }
      });
    }

    // Defer disposal until after the dialog exit animation completes
    WidgetsBinding.instance.addPostFrameCallback((_) {
      nameCtrl.dispose();
      urlCtrl.dispose();
      endpointCtrl.dispose();
      specCtrl.dispose();
      keyCtrl.dispose();
      pwdCtrl.dispose();
    });
  }

  Future<void> _discoverMcpServer(int index) async {
    final server = _mcpServers[index];
    final result = await showDialog<McpToolConfig>(
      context: context,
      builder: (_) => McpDiscoveryDialog(server: server),
    );
    if (result != null) {
      setState(() => _mcpServers[index] = result);
    }
  }

  // ═══════════════════════════════════════════════════════
  // Tab 5: Built-in MCPs
  // ═══════════════════════════════════════════════════════

  /// Returns a locked tile card for a Pro-only MCP tool.
  Widget _buildLockedMcpTile(InternalMcpInfo info) {
    return Card(
      key: ValueKey('mcp_tile_${info.type}_locked'),
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: ListTile(
            leading: Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(_mcpIcon(info.iconName), color: Colors.grey[500]),
                Positioned(
                  right: -6,
                  bottom: -4,
                  child: Icon(Icons.lock, size: 12, color: Colors.grey[600]),
                ),
              ],
            ),
            title: Text(
              info.displayName,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: Colors.grey[500],
              ),
            ),
            subtitle: Text(
              info.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: Colors.grey[400]),
            ),
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppTheme.primaryBlue.withAlpha(25),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                'Pro',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.primaryBlue,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildInternalMcpContent() {
    final l = L.of(context);
    final registry = InternalMcpRegistry();
    final isServerMode = ref.read(serverModeProvider).value?.isRemote ?? false;

    final serverInfos = List<InternalMcpInfo>.from(registry.availableServers);
    if (isServerMode &&
        !serverInfos.any((server) => server.type == 'py_bridge')) {
      final pyBridge = PyBridgeMcpServer();
      serverInfos.add(
        InternalMcpInfo(
          type: pyBridge.type,
          displayName: pyBridge.displayName,
          description: pyBridge.description,
          iconName: pyBridge.iconName,
          initParamSchema: pyBridge.initParamSchema,
          defaultInitParams: pyBridge.defaultInitParams,
          defaultSystemPrompt: pyBridge.defaultSystemPrompt,
          toolCount: pyBridge.tools.length,
          toolNames: pyBridge.tools.map((tool) => tool.name).toList(),
        ),
      );
    }

    final available =
        serverInfos
            .where(
              (server) =>
                  server.type != 'toolbox' &&
                  server.type != 'traffic' &&
                  !server.type.startsWith('gh_mcp_') &&
                  !(isServerMode &&
                      (server.type == 'ps_bridge' || server.type == 'chart')),
            )
            .toList()
          ..sort((a, b) => a.displayName.compareTo(b.displayName));

    return [
      _sectionTitle(l.builtInMcpServers),
      const SizedBox(height: 4),
      Text(
        l.builtInMcpSubtitle,
        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
      ),
      const SizedBox(height: 12),

      // ── Generate system prompt checkbox ──────────────────────────────
      Card(
        margin: EdgeInsets.zero,
        color: AppTheme.primaryBlue.withAlpha(18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        child: CheckboxListTile(
          title: const Text(
            'Generate system prompt',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
          subtitle: const Text(
            'Auto-fill the system prompt based on selected tools',
            style: TextStyle(fontSize: 11),
          ),
          value: _generateSystemPromptOnToolSelect,
          onChanged: (v) =>
              setState(() => _generateSystemPromptOnToolSelect = v ?? true),
          activeColor: AppTheme.primaryBlue,
          controlAffinity: ListTileControlAffinity.leading,
          dense: true,
        ),
      ),
      const SizedBox(height: 16),

      // ── Toolbox (always-on but can be disabled) ──────────────────────
      Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: SwitchListTile(
          secondary: Icon(
            Icons.handyman_outlined,
            color: _toolboxEnabled ? AppTheme.primaryBlue : Colors.grey,
          ),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  'Toolbox',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: _toolboxEnabled ? null : Colors.grey,
                  ),
                ),
              ),
              if (_toolboxEnabled) ...[
                const SizedBox(width: 4),
                Chip(
                  label: const Text('7 tools', style: TextStyle(fontSize: 11)),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: AppTheme.primaryBlue.withAlpha(25),
                ),
              ],
            ],
          ),
          subtitle: const Text(
            'Time, timezone, location, geocoding, calculator — disable to reduce tool count for small models',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12),
          ),
          value: _toolboxEnabled,
          activeTrackColor: AppTheme.primaryBlue,
          onChanged: (val) => setState(() => _toolboxEnabled = val),
        ),
      ),

      // ── List of available internal MCPs ──
      ...available.map((info) {
        // Find existing config for this MCP type
        final existingIdx = _internalMcps.indexWhere(
          (m) => m.mcpType == info.type,
        );
        final isAdded = existingIdx >= 0;
        final entry = isAdded ? _internalMcps[existingIdx] : null;

        return Card(
          key: ValueKey('mcp_tile_${info.type}_$isAdded'),
          margin: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header row with inline switch ──
              SwitchListTile(
                secondary: Icon(
                  _mcpIcon(info.iconName),
                  color: isAdded ? AppTheme.primaryBlue : Colors.grey,
                ),
                title: Row(
                  children: [
                    Expanded(
                      child: Text(
                        info.displayName,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: isAdded ? null : Colors.grey,
                        ),
                      ),
                    ),
                    if (isAdded) ...[
                      const SizedBox(width: 4),
                      Chip(
                        label: Text(
                          l.toolsChip(info.toolCount),
                          style: const TextStyle(fontSize: 11),
                        ),
                        visualDensity: VisualDensity.compact,
                        backgroundColor: AppTheme.primaryBlue.withAlpha(25),
                      ),
                      const SizedBox(width: 2),
                      InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () {
                          final server = InternalMcpRegistry().create(
                            info.type,
                          );
                          if (server == null) return;
                          ToolListExportSheet.show(
                            context,
                            serverName: info.displayName,
                            tools: server.tools
                                .map(
                                  (t) => {
                                    'name': t.name,
                                    'description': t.description,
                                    'inputSchema': t.inputSchema,
                                  },
                                )
                                .toList(),
                          );
                        },
                        child: const Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(
                            Icons.model_training,
                            size: 16,
                            color: AppTheme.primaryBlue,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                subtitle: Text(
                  info.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
                value: isAdded,
                activeTrackColor: AppTheme.primaryBlue,
                onChanged: (val) {
                  setState(() {
                    if (val) {
                      // Attach: add with defaults
                      _internalMcps.add(
                        InternalMcpEntry(
                          id: const Uuid().v4(),
                          mcpType: info.type,
                          label: info.displayName,
                          initParams: Map<String, dynamic>.from(
                            info.defaultInitParams,
                          ),
                          systemPrompt: info.defaultSystemPrompt,
                          enabled: true,
                        ),
                      );
                    } else {
                      // Detach: remove entirely
                      final idx = _internalMcps.indexWhere(
                        (m) => m.mcpType == info.type,
                      );
                      if (idx >= 0) _internalMcps.removeAt(idx);
                    }
                  });
                  _autoGenerateSystemPromptFromTools();
                },
              ),

              // ── Config section — visible immediately when attached ──
              if (isAdded)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Divider(),
                      const SizedBox(height: 8),
                      Text(
                        l.configuration,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 16),
                      ..._buildInitParamFields(info, existingIdx),
                      const SizedBox(height: 12),

                      if (info.type == 'ssh')
                        Card(
                          margin: EdgeInsets.zero,
                          color: AppTheme.primaryBlue.withAlpha(12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.terminal,
                                  size: 18,
                                  color: AppTheme.primaryBlue,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    L.of(context).sshScriptLibraryNote,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                OutlinedButton.icon(
                                  onPressed: () async {
                                    final changed =
                                        await ScriptLibraryScreen.show(
                                          context,
                                          onInsertScriptPrompt:
                                              _insertScriptCallIntoPrompt,
                                        );
                                    if (changed == true && mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            L.of(context).scriptLibraryUpdated,
                                          ),
                                          behavior: SnackBarBehavior.floating,
                                        ),
                                      );
                                    }
                                  },
                                  icon: const Icon(Icons.open_in_new, size: 16),
                                  label: Text(L.of(context).openButtonLabel),
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (info.type == 'js_bridge')
                        Card(
                          margin: EdgeInsets.zero,
                          color: AppTheme.primaryBlue.withAlpha(12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.javascript,
                                  size: 18,
                                  color: AppTheme.primaryBlue,
                                ),
                                const SizedBox(width: 10),
                                const Expanded(
                                  child: Text(
                                    'Manage generated JavaScript tools used by the JS bridge MCP.',
                                  ),
                                ),
                                const SizedBox(width: 8),
                                OutlinedButton.icon(
                                  onPressed: () async {
                                    final changed =
                                        await JsToolLibraryScreen.show(
                                          context,
                                          onInsertToolPrompt:
                                              _insertJsToolCallIntoPrompt,
                                        );
                                    if (changed == true && mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            'JS tool library updated.',
                                          ),
                                          behavior: SnackBarBehavior.floating,
                                        ),
                                      );
                                    }
                                  },
                                  icon: const Icon(Icons.open_in_new, size: 16),
                                  label: Text(L.of(context).openButtonLabel),
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (info.type == 'ssh') const SizedBox(height: 12),
                      if (info.type == 'js_bridge') const SizedBox(height: 12),
                      if (info.type == 'py_bridge')
                        Card(
                          margin: EdgeInsets.zero,
                          color: Colors.green.withAlpha(12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.terminal,
                                  size: 18,
                                  color: Colors.green,
                                ),
                                const SizedBox(width: 10),
                                const Expanded(
                                  child: Text(
                                    'Manage generated Python tools running on this desktop machine.',
                                  ),
                                ),
                                const SizedBox(width: 8),
                                OutlinedButton.icon(
                                  onPressed: () async {
                                    final changed =
                                        await PyToolLibraryScreen.show(
                                          context,
                                          onInsertToolPrompt:
                                              _insertJsToolCallIntoPrompt,
                                        );
                                    if (changed == true && mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            'Python tool library updated.',
                                          ),
                                          behavior: SnackBarBehavior.floating,
                                        ),
                                      );
                                    }
                                  },
                                  icon: const Icon(Icons.open_in_new, size: 16),
                                  label: Text(L.of(context).openButtonLabel),
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (info.type == 'py_bridge') const SizedBox(height: 12),
                      if (info.type == 'ps_bridge')
                        Card(
                          margin: EdgeInsets.zero,
                          color: Colors.blueGrey.withAlpha(18),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.terminal,
                                  size: 18,
                                  color: Colors.blueGrey,
                                ),
                                const SizedBox(width: 10),
                                const Expanded(
                                  child: Text(
                                    'Manage saved PowerShell scripts running on this Windows machine.',
                                  ),
                                ),
                                const SizedBox(width: 8),
                                OutlinedButton.icon(
                                  onPressed: () async {
                                    final changed =
                                        await PowershellToolLibraryScreen.show(
                                          context,
                                        );
                                    if (changed == true && mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            'PowerShell tool library updated.',
                                          ),
                                          behavior: SnackBarBehavior.floating,
                                        ),
                                      );
                                    }
                                  },
                                  icon: const Icon(Icons.open_in_new, size: 16),
                                  label: Text(L.of(context).openButtonLabel),
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (info.type == 'ps_bridge') const SizedBox(height: 12),
                      if (info.type == 'local_shell')
                        Card(
                          margin: EdgeInsets.zero,
                          color: Colors.green.withAlpha(12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.terminal,
                                  size: 18,
                                  color: Colors.green,
                                ),
                                const SizedBox(width: 10),
                                const Expanded(
                                  child: Text(
                                    'Manage saved local shell scripts running on this Linux/macOS machine.',
                                  ),
                                ),
                                const SizedBox(width: 8),
                                OutlinedButton.icon(
                                  onPressed: () async {
                                    final changed =
                                        await LocalShellToolLibraryScreen.show(
                                          context,
                                        );
                                    if (changed == true && mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            'Local shell library updated.',
                                          ),
                                          behavior: SnackBarBehavior.floating,
                                        ),
                                      );
                                    }
                                  },
                                  icon: const Icon(Icons.open_in_new, size: 16),
                                  label: Text(L.of(context).openButtonLabel),
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (info.type == 'local_shell')
                        const SizedBox(height: 12),
                      Text(
                        l.mcpSystemPrompt,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l.mcpSystemPromptHelper,
                        style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                      ),
                      const SizedBox(height: 8),
                      TextFormField(
                        initialValue:
                            entry!.systemPrompt ?? info.defaultSystemPrompt,
                        decoration: InputDecoration(
                          border: const OutlineInputBorder(),
                          isDense: true,
                          hintText: l.mcpSystemPromptHint,
                          suffixIcon: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Copy / append main system prompt button
                              IconButton(
                                icon: const Icon(Icons.content_copy, size: 18),
                                tooltip: l.appendMainSystemPrompt,
                                onPressed: () {
                                  final mainPrompt = _combinedSystemPrompt
                                      .trim();
                                  if (mainPrompt.isEmpty) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(l.noMainSystemPrompt),
                                      ),
                                    );
                                    return;
                                  }
                                  final current =
                                      entry.systemPrompt ??
                                      info.defaultSystemPrompt;
                                  final appended = current.isNotEmpty
                                      ? '$current\n\n$mainPrompt'
                                      : mainPrompt;
                                  setState(() {
                                    _internalMcps[existingIdx] = entry.copyWith(
                                      systemPrompt: appended,
                                    );
                                  });
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(l.mainSystemPromptAppended),
                                    ),
                                  );
                                },
                              ),
                              // Reset to default button
                              if (entry.systemPrompt != null &&
                                  entry.systemPrompt !=
                                      info.defaultSystemPrompt)
                                IconButton(
                                  icon: const Icon(Icons.restart_alt, size: 18),
                                  tooltip: l.resetToDefault,
                                  onPressed: () {
                                    setState(() {
                                      _internalMcps[existingIdx] = entry
                                          .copyWith(
                                            systemPrompt:
                                                info.defaultSystemPrompt,
                                          );
                                    });
                                  },
                                ),
                            ],
                          ),
                        ),
                        maxLines: 4,
                        style: const TextStyle(fontSize: 13),
                        onChanged: (value) {
                          _internalMcps[existingIdx] = entry.copyWith(
                            systemPrompt: value,
                          );
                        },
                      ),
                      const SizedBox(height: 12),

                      // ── Tool list ──
                      Text(
                        l.availableTools,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: info.toolNames
                            .map(
                              (name) => Chip(
                                label: Text(
                                  name,
                                  style: const TextStyle(fontSize: 11),
                                ),
                                visualDensity: VisualDensity.compact,
                              ),
                            )
                            .toList(),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
            ],
          ),
        );
      }),

      if (available.isEmpty)
        Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              l.noBuiltInMcp,
              style: const TextStyle(color: Colors.grey),
            ),
          ),
        ),

      // ── Installed GitHub MCP servers ──
      ...() {
        final isServerMode =
            ref.watch(serverModeProvider).value?.isRemote ?? false;
        final ghServers = _dedupeGithubMcpServers(
          isServerMode
              ? _remoteGithubMcpServers
              : GithubMcpLibraryService.instance.activeServers,
        );
        if (ghServers.isEmpty) return <Widget>[];
        return <Widget>[
          const SizedBox(height: 24),
          Row(
            children: [
              Icon(Icons.hub_outlined, size: 15, color: Colors.teal[700]),
              const SizedBox(width: 6),
              Text(
                'INSTALLED MCP SERVERS',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Colors.teal[800],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Community MCP servers installed from the registry.',
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
          const SizedBox(height: 12),
          ...ghServers.map((def) {
            final key = 'gh_mcp_${def.id}';
            final existingIdx = _internalMcps.indexWhere(
              (m) => m.mcpType == key,
            );
            final isAdded = existingIdx >= 0;
            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              color: isAdded
                  ? Colors.teal.withAlpha(18)
                  : Colors.grey.withAlpha(12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: BorderSide(
                  color: isAdded
                      ? Colors.teal.withAlpha(100)
                      : Colors.grey.withAlpha(60),
                ),
              ),
              child: SwitchListTile(
                dense: true,
                secondary: Icon(
                  Icons.hub_outlined,
                  color: isAdded ? Colors.teal[700] : Colors.grey,
                  size: 20,
                ),
                title: Text(
                  def.displayName,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: isAdded ? null : Colors.grey,
                  ),
                ),
                subtitle: Text(
                  def.description,
                  style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                value: isAdded,
                activeThumbColor: Colors.teal[700],
                onChanged: (val) async {
                  setState(() {
                    if (val) {
                      _internalMcps.add(
                        InternalMcpEntry(
                          id: const Uuid().v4(),
                          mcpType: key,
                          label: def.displayName,
                          initParams: const {},
                          systemPrompt: def.description,
                          enabled: true,
                        ),
                      );
                    } else {
                      final idx = _internalMcps.indexWhere(
                        (m) => m.mcpType == key,
                      );
                      if (idx >= 0) _internalMcps.removeAt(idx);
                    }
                  });
                  await _eagerDiscoverSelectedRemoteMcpTools();
                  await _autoGenerateSystemPromptFromTools();
                },
              ),
            );
          }),
        ];
      }(),

      // ── Global MCP Servers (from settings) ──
      const SizedBox(height: 16),
      _buildGlobalMcpServersInfo(),
    ];
  }

  Widget _buildInternalMcpTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: _buildInternalMcpContent(),
    );
  }

  /// Shows global external MCP servers with per-task enable/disable toggles.
  Widget _buildGlobalMcpServersInfo() {
    final l = L.of(context);
    final externalServers =
        ExternalToolsSettingsService.instance.selectedServers;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.dns, size: 15, color: Colors.orange[700]),
            const SizedBox(width: 6),
            Text(
              L.of(context).externalMcpGlobalTitle,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Colors.orange[800],
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          L.of(context).externalMcpGlobalSubtitle,
          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
        ),
        const SizedBox(height: 10),
        Text(
          'Up to 100 external MCP servers can be selected per task.',
          style: TextStyle(fontSize: 11, color: Colors.grey[500]),
        ),
        const SizedBox(height: 8),
        if (externalServers.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              l.noGlobalMcpServers,
              style: TextStyle(fontSize: 12, color: Colors.grey[500]),
            ),
          )
        else
          ...externalServers.map((server) {
            final isSelected = _selectedGlobalServerUrls.contains(
              server.serverUrl,
            );
            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              color: isSelected
                  ? Colors.orange.withAlpha(25)
                  : Colors.grey.withAlpha(12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: BorderSide(
                  color: isSelected
                      ? Colors.orange.withAlpha(100)
                      : Colors.grey.withAlpha(60),
                ),
              ),
              child: SwitchListTile(
                dense: true,
                secondary: Icon(
                  Icons.dns,
                  color: isSelected ? Colors.orange[700] : Colors.grey,
                  size: 20,
                ),
                title: Text(
                  server.name ?? server.serverUrl,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: isSelected ? null : Colors.grey,
                  ),
                ),
                subtitle: Text(
                  server.serverUrl,
                  style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                value: isSelected,
                activeThumbColor: Colors.orange[700],
                onChanged: (val) async {
                  if (val == true &&
                      !isSelected &&
                      _selectedGlobalServerUrls.length >=
                          _externalServerSelectionLimit) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'External MCP limit reached ($_externalServerSelectionLimit).',
                        ),
                        backgroundColor: AppTheme.error,
                      ),
                    );
                    return;
                  }

                  setState(() {
                    if (val == true) {
                      _selectedGlobalServerUrls.add(server.serverUrl);
                    } else {
                      _selectedGlobalServerUrls.remove(server.serverUrl);
                    }
                  });
                  await _eagerDiscoverSelectedRemoteMcpTools();
                  await _autoGenerateSystemPromptFromTools();
                },
              ),
            );
          }),
      ],
    );
  }

  /// Build editable fields for init params based on the MCP's schema.
  List<Widget> _buildInitParamFields(InternalMcpInfo info, int entryIndex) {
    final l = L.of(context);
    final entry = _internalMcps[entryIndex];
    final fields = <Widget>[];

    // ── SSH: render dedicated credential card and skip generic loop ──
    if (info.type == 'ssh') {
      final ds = DataSourcesSettingsService.instance;
      final params = entry.initParams;

      void updateParam(String key, dynamic value) {
        final updated = Map<String, dynamic>.from(
          _internalMcps[entryIndex].initParams,
        );
        updated[key] = value;
        setState(() {
          _internalMcps[entryIndex] = _internalMcps[entryIndex].copyWith(
            initParams: updated,
          );
        });
      }

      fields.add(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Connection Override',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
            const SizedBox(height: 4),
            Text(
              'Leave fields empty to use global SSH settings.',
              style: TextStyle(fontSize: 11, color: Colors.grey[500]),
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: TextFormField(
                    key: ValueKey('ssh_host_${entry.id}'),
                    initialValue: params['host'] as String? ?? '',
                    decoration: InputDecoration(
                      labelText: 'Host / IP',
                      hintText: ds.sshHost.isNotEmpty
                          ? ds.sshHost
                          : '192.168.1.1',
                      helperText:
                          'Global: ${ds.sshHost.isNotEmpty ? ds.sshHost : "not set"}',
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 16,
                      ),
                    ),
                    onChanged: (v) => updateParam('host', v),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 90,
                  child: TextFormField(
                    key: ValueKey('ssh_port_${entry.id}'),
                    initialValue: () {
                      final v = params['port'];
                      if (v == null || v == 0) return '';
                      return v.toString();
                    }(),
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'Port',
                      hintText: '${ds.sshPort}',
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 16,
                      ),
                    ),
                    onChanged: (v) => updateParam('port', int.tryParse(v) ?? 0),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextFormField(
                    key: ValueKey('ssh_user_${entry.id}'),
                    initialValue: params['username'] as String? ?? '',
                    decoration: InputDecoration(
                      labelText: 'Username',
                      hintText: ds.sshUsername.isNotEmpty
                          ? ds.sshUsername
                          : 'root',
                      helperText:
                          'Global: ${ds.sshUsername.isNotEmpty ? ds.sshUsername : "not set"}',
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 16,
                      ),
                    ),
                    onChanged: (v) => updateParam('username', v),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextFormField(
                    key: ValueKey('ssh_pw_${entry.id}'),
                    initialValue: params['password'] as String? ?? '',
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      hintText: ds.sshPassword.isNotEmpty
                          ? '••••••'
                          : 'not set globally',
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 16,
                      ),
                    ),
                    onChanged: (v) => updateParam('password', v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Private key picker row
            StatefulBuilder(
              builder: (context, setRowState) {
                final keyName =
                    (params['_privateKeyFileName'] as String?) ?? '';
                return Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final result = await FilePicker.pickFiles(
                            type: FileType.any,
                            allowMultiple: false,
                            withData: true,
                          );
                          if (result != null &&
                              result.files.single.bytes != null) {
                            final content = utf8.decode(
                              result.files.single.bytes!,
                              allowMalformed: false,
                            );
                            updateParam('privateKey', content);
                            updateParam(
                              '_privateKeyFileName',
                              result.files.single.name,
                            );
                            setRowState(() {});
                          }
                        },
                        icon: const Icon(Icons.key, size: 16),
                        label: Text(
                          keyName.isNotEmpty
                              ? keyName
                              : (ds.sshPrivateKey.isNotEmpty
                                    ? '(global key set)'
                                    : 'Load Private Key (PEM)…'),
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                    if ((params['privateKey'] as String? ?? '').isNotEmpty) ...[
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Clear private key override',
                        icon: const Icon(Icons.clear, size: 16),
                        onPressed: () {
                          updateParam('privateKey', '');
                          updateParam('_privateKeyFileName', '');
                          setRowState(() {});
                        },
                      ),
                    ],
                  ],
                );
              },
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed: () => _testInternalSshConnection(
                  Map<String, dynamic>.from(
                    _internalMcps[entryIndex].initParams,
                  ),
                ),
                icon: const Icon(Icons.network_check),
                label: const Text('Test connection'),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
      return fields;
    }

    final rawProperties = info.initParamSchema['properties'];
    final properties = rawProperties is Map
        ? Map<String, dynamic>.from(rawProperties)
        : <String, dynamic>{};

    // Map raw param names to localized labels
    String localizedLabel(String paramName) {
      return switch (paramName) {
        'rootPath' => l.paramLabelRootPath,
        'fileTypes' => l.paramLabelFileTypes,
        'indexingStrategy' => l.paramLabelIndexingStrategy,
        'maxDocuments' => l.paramLabelMaxDocuments,
        'websiteUrls' => l.paramLabelWebsiteUrls,
        'maxPages' => l.paramLabelMaxPages,
        'provider' => l.searchProvider,
        'maxResults' => l.paramLabelMaxResults,
        'accessToken' => l.paramLabelAccessToken,
        'userId' => l.paramLabelUserId,
        _ => paramName,
      };
    }

    for (final paramEntry in properties.entries) {
      final paramName = paramEntry.key;
      if (info.type == 'gmail' && paramName == 'accessToken') {
        continue;
      }
      final rawSchema = paramEntry.value;
      final schema = rawSchema is Map
          ? Map<String, dynamic>.from(rawSchema)
          : <String, dynamic>{};
      final description = schema['description'] as String? ?? '';
      final defaultVal = info.defaultInitParams[paramName]?.toString() ?? '';
      final currentVal = entry.initParams[paramName]?.toString() ?? defaultVal;
      final friendlyLabel = localizedLabel(paramName);

      // ── Enum param ──
      final enumValues = schema['enum'] as List<dynamic>?;
      final isIndexingStrategy =
          paramName == 'indexingStrategy' &&
          (info.type == 'document' || info.type == 'website_search');
      final isEmbeddedMaxDocuments =
          info.type == 'document' && paramName == 'maxDocuments';

      if (isEmbeddedMaxDocuments) {
        continue;
      }

      if (isIndexingStrategy) {
        final maxDocsSchema = info.type == 'document'
            ? properties['maxDocuments'] as Map<String, dynamic>?
            : null;
        final maxDocsCurrent =
            entry.initParams['maxDocuments']?.toString() ??
            info.defaultInitParams['maxDocuments']?.toString() ??
            '1000';
        final maxDocsMin = (maxDocsSchema?['min'] as num?)?.toInt() ?? 1;
        final maxDocsMax = (maxDocsSchema?['max'] as num?)?.toInt() ?? 1000;

        fields.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: InputDecorator(
                        decoration: InputDecoration(
                          labelText: friendlyLabel,
                          helperText: description,
                          helperMaxLines: 3,
                          border: const OutlineInputBorder(),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Text(
                                currentVal == 'now'
                                    ? l.indexEachTime
                                    : l.indexFirstTime,
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                            Switch(
                              value: currentVal == 'now',
                              onChanged: (bool value) {
                                final params = Map<String, dynamic>.from(
                                  _internalMcps[entryIndex].initParams,
                                );
                                params['indexingStrategy'] = value
                                    ? 'now'
                                    : 'before_first_run';
                                setState(() {
                                  _internalMcps[entryIndex] =
                                      _internalMcps[entryIndex].copyWith(
                                        initParams: params,
                                      );
                                });
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (info.type == 'document') ...[
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 150,
                        child: TextFormField(
                          key: ValueKey('maxDocs_${entry.id}_$maxDocsCurrent'),
                          initialValue: maxDocsCurrent,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: l.paramLabelMaxDocuments,
                            border: const OutlineInputBorder(),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 16,
                            ),
                          ),
                          onChanged: (value) {
                            final parsed = int.tryParse(value);
                            if (parsed == null) return;
                            final clamped = parsed.clamp(
                              maxDocsMin,
                              maxDocsMax,
                            );
                            final params = Map<String, dynamic>.from(
                              _internalMcps[entryIndex].initParams,
                            );
                            params['maxDocuments'] = clamped;
                            _internalMcps[entryIndex] =
                                _internalMcps[entryIndex].copyWith(
                                  initParams: params,
                                );
                          },
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                _buildIndexingButton(entry, mcpType: info.type),
                if (_isReindexing) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    value: _indexTotal > 0 ? _indexedCount / _indexTotal : null,
                    minHeight: 6,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _indexTotal > 0
                        ? l.indexingProgress(_indexedCount, _indexTotal)
                        : l.reindexing,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey[400],
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (_indexCurrentFile.isNotEmpty)
                    Text(
                      l.indexingCurrentFile(_indexCurrentFile),
                      style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                ],
              ],
            ),
          ),
        );
        continue;
      }

      if (enumValues != null && enumValues.isNotEmpty) {
        final dropdownWidget = DropdownButtonFormField<String>(
          initialValue: enumValues.contains(currentVal)
              ? currentVal
              : enumValues.first.toString(),
          decoration: InputDecoration(
            labelText: friendlyLabel,
            helperText: description,
            helperMaxLines: 3,
            border: const OutlineInputBorder(),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 16,
            ),
          ),
          items: enumValues.map((v) {
            final val = v.toString();
            // Use friendly labels for known enum values
            final label = switch (val) {
              'now' => l.indexingStrategyNow,
              'before_first_run' => l.indexingStrategyLazy,
              'auto' => l.enumAuto,
              'serper' => 'Serper.dev',
              'google' => 'Serper.dev',
              'duckduckgo' => l.duckDuckGo,
              _ => val,
            };
            return DropdownMenuItem(
              value: val,
              child: Text(label, style: const TextStyle(fontSize: 13)),
            );
          }).toList(),
          onChanged: (value) {
            if (value == null) return;
            final params = Map<String, dynamic>.from(
              _internalMcps[entryIndex].initParams,
            );
            params[paramName] = value;
            setState(() {
              _internalMcps[entryIndex] = _internalMcps[entryIndex].copyWith(
                initParams: params,
              );
            });
          },
        );

        fields.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 24),
            child: dropdownWidget,
          ),
        );
        continue;
      }

      // ── Integer param (number box) ──
      if (schema['type'] == 'integer') {
        final maxVal = (schema['max'] as num?)?.toInt() ?? 1000;
        final minVal = (schema['min'] as num?)?.toInt() ?? 1;
        fields.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 24),
            child: TextFormField(
              initialValue: currentVal.isNotEmpty ? currentVal : defaultVal,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: friendlyLabel,
                helperText: '$description ($minVal–$maxVal)',
                helperMaxLines: 3,
                hintText: defaultVal.isNotEmpty
                    ? l.defaultPrefix(defaultVal)
                    : null,
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 16,
                ),
              ),
              onChanged: (value) {
                final parsed = int.tryParse(value);
                if (parsed == null) return;
                final clamped = parsed.clamp(minVal, maxVal);
                final params = Map<String, dynamic>.from(
                  _internalMcps[entryIndex].initParams,
                );
                params[paramName] = clamped;
                setState(() {
                  _internalMcps[entryIndex] = _internalMcps[entryIndex]
                      .copyWith(initParams: params);
                });
              },
            ),
          ),
        );
        continue;
      }

      // ── rootPath: multi-directory picker ──
      if (paramName == 'rootPath') {
        final selectedPaths = currentVal
            .split(';')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toSet();
        fields.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  friendlyLabel,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (description.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2, bottom: 4),
                    child: Text(
                      description,
                      style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                      maxLines: 3,
                    ),
                  ),
                const SizedBox(height: 4),
                // Show selected paths as removable chips
                if (selectedPaths.isNotEmpty) ...[
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: selectedPaths.map((p) {
                      final shortName = p.split('/').last;
                      return InputChip(
                        label: Text(
                          shortName,
                          style: const TextStyle(fontSize: 12),
                        ),
                        avatar: const Icon(Icons.folder, size: 16),
                        tooltip: p,
                        deleteIcon: const Icon(Icons.close, size: 16),
                        onDeleted: () {
                          final updated = Set<String>.from(selectedPaths)
                            ..remove(p);
                          final params = Map<String, dynamic>.from(
                            _internalMcps[entryIndex].initParams,
                          );
                          params[paramName] = updated.join(';');
                          setState(() {
                            _internalMcps[entryIndex] =
                                _internalMcps[entryIndex].copyWith(
                                  initParams: params,
                                );
                          });
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 8),
                ],
                // Summary chip row
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.withAlpha(80)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    selectedPaths.isEmpty
                        ? l.chooseDirectory
                        : '${selectedPaths.length} folder${selectedPaths.length > 1 ? 's' : ''} selected',
                    style: TextStyle(
                      fontSize: 13,
                      color: selectedPaths.isEmpty ? Colors.grey : null,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                if (ref.read(serverModeProvider).value?.isRemote ?? false) ...[
                  // ── Server mode: type path directly ──
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      icon: const Icon(
                        Icons.create_new_folder_outlined,
                        size: 18,
                      ),
                      label: const Text('Add server path'),
                      onPressed: () async {
                        final controller = TextEditingController();
                        final picked = await showDialog<String>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Add Folder or File'),
                            content: TextField(
                              controller: controller,
                              autofocus: true,
                              decoration: const InputDecoration(
                                hintText: '/home/user/documents',
                                labelText: 'Absolute path on server',
                              ),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.of(ctx).pop(),
                                child: const Text('Cancel'),
                              ),
                              TextButton(
                                onPressed: () {
                                  final v = controller.text.trim();
                                  Navigator.of(
                                    ctx,
                                  ).pop(v.isNotEmpty ? v : null);
                                },
                                child: const Text('Add'),
                              ),
                            ],
                          ),
                        );
                        controller.dispose();
                        if (picked == null || !mounted) return;
                        final updated = Set<String>.from(selectedPaths)
                          ..add(picked);
                        final params = Map<String, dynamic>.from(
                          _internalMcps[entryIndex].initParams,
                        );
                        params[paramName] = updated.join(';');
                        setState(() {
                          _internalMcps[entryIndex] = _internalMcps[entryIndex]
                              .copyWith(initParams: params);
                        });
                      },
                    ),
                  ),
                ] else ...[
                  Row(
                    children: [
                      // ── Browse Folder ──
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.folder_open, size: 18),
                          label: Text(l.chooseDirectory),
                          onPressed: () async {
                            if (Platform.isAndroid) {
                              final granted = await StoragePermission.request(
                                context,
                              );
                              if (!mounted || !granted) return;
                            }
                            if (selectedPaths.length >= 10) {
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Maximum 10 folders allowed'),
                                    duration: Duration(seconds: 2),
                                  ),
                                );
                              }
                              return;
                            }
                            final selected = await FilePicker.getDirectoryPath(
                              dialogTitle: l.chooseDirectory,
                            );
                            if (!mounted ||
                                selected == null ||
                                selected.trim().isEmpty) {
                              return;
                            }
                            final updated = Set<String>.from(selectedPaths)
                              ..add(selected);
                            final params = Map<String, dynamic>.from(
                              _internalMcps[entryIndex].initParams,
                            );
                            params[paramName] = updated.join(';');
                            setState(() {
                              _internalMcps[entryIndex] =
                                  _internalMcps[entryIndex].copyWith(
                                    initParams: params,
                                  );
                            });
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      // ── Pick Files (copies to internal storage — works on Android Downloads) ──
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.file_copy_outlined, size: 18),
                          label: const Text('Pick Files'),
                          onPressed: () async {
                            final result = await FilePicker.pickFiles(
                              allowMultiple: true,
                              type: FileType.custom,
                              allowedExtensions: const ['pdf', 'md', 'docx'],
                              withData: true,
                            );
                            if (!mounted ||
                                result == null ||
                                result.files.isEmpty) {
                              return;
                            }
                            final supportDir =
                                await getApplicationSupportDirectory();
                            final destDir = Directory(
                              '${supportDir.path}/tealkit_indexed_files',
                            );
                            await destDir.create(recursive: true);
                            int copied = 0;
                            for (final file in result.files) {
                              try {
                                final bytes = file.bytes;
                                final srcPath = file.path;
                                if (bytes != null) {
                                  await File(
                                    '${destDir.path}/${file.name}',
                                  ).writeAsBytes(bytes);
                                  copied++;
                                } else if (srcPath != null) {
                                  await File(
                                    srcPath,
                                  ).copy('${destDir.path}/${file.name}');
                                  copied++;
                                }
                              } catch (_) {}
                            }
                            if (copied == 0 || !mounted) return;
                            final updated = Set<String>.from(selectedPaths)
                              ..add(destDir.path);
                            final params = Map<String, dynamic>.from(
                              _internalMcps[entryIndex].initParams,
                            );
                            params[paramName] = updated.join(';');
                            setState(() {
                              _internalMcps[entryIndex] =
                                  _internalMcps[entryIndex].copyWith(
                                    initParams: params,
                                  );
                            });
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    '$copied file(s) copied — tap Reindex to update search',
                                  ),
                                ),
                              );
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                  // Quick-pick common directories on Android 9/10 (API < 30).
                  // On Android 11+, getCommonDirectories() returns [] so this is hidden;
                  // users pick folders via SAF through the Browse button above.
                  if (Platform.isAndroid)
                    FutureBuilder<List<(String, String)>>(
                      future: StoragePermission.getCommonDirectories(),
                      builder: (ctx, snap) {
                        if (!snap.hasData || snap.data!.isEmpty) {
                          return const SizedBox.shrink();
                        }
                        return Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Tap folders below to add/remove (Browse may block some on Android):',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey[500],
                                ),
                              ),
                              const SizedBox(height: 4),
                              Wrap(
                                spacing: 8,
                                runSpacing: 4,
                                children: snap.data!.map((dir) {
                                  final (label, path) = dir;
                                  final isSelected = selectedPaths.contains(
                                    path,
                                  );
                                  return FilterChip(
                                    avatar: Icon(
                                      isSelected
                                          ? Icons.check_circle
                                          : Icons.folder,
                                      size: 18,
                                      color: isSelected
                                          ? AppTheme.primaryBlue
                                          : null,
                                    ),
                                    selected: isSelected,
                                    showCheckmark: false,
                                    label: Text(
                                      label,
                                      style: TextStyle(
                                        fontWeight: isSelected
                                            ? FontWeight.bold
                                            : FontWeight.normal,
                                      ),
                                    ),
                                    backgroundColor: isSelected
                                        ? AppTheme.primaryBlue.withValues(
                                            alpha: 0.1,
                                          )
                                        : null,
                                    onSelected: (_) {
                                      final updated = Set<String>.from(
                                        selectedPaths,
                                      );
                                      if (isSelected) {
                                        updated.remove(path);
                                      } else {
                                        updated.add(path);
                                      }
                                      final params = Map<String, dynamic>.from(
                                        _internalMcps[entryIndex].initParams,
                                      );
                                      params[paramName] = updated.join(';');
                                      setState(() {
                                        _internalMcps[entryIndex] =
                                            _internalMcps[entryIndex].copyWith(
                                              initParams: params,
                                            );
                                      });
                                    },
                                  );
                                }).toList(),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                ], // end if (Platform.isAndroid)
              ], // end else (local mode)
            ),
          ),
        );
        continue;
      }

      // ── websiteUrls: chip list + add URL input (mirrors playground UI) ──
      if (paramName == 'websiteUrls' && info.type == 'website_search') {
        currentVal
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
        const maxUrls = 10;
        _normalizeWebsiteUrl(_websiteUrlCtrl.text);
        fields.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: StatefulBuilder(
              builder: (context, setInner) {
                final selUrls =
                    (entry.initParams['websiteUrls'] as String? ?? '')
                        .split(',')
                        .map((e) => e.trim())
                        .where((e) => e.isNotEmpty)
                        .toList();
                final typed = _normalizeWebsiteUrl(_websiteUrlCtrl.text);
                final canAddTyped =
                    typed != null &&
                    selUrls.length < maxUrls &&
                    !selUrls.contains(typed.toString());
                void saveUrls(List<String> urls) {
                  final params = Map<String, dynamic>.from(
                    _internalMcps[entryIndex].initParams,
                  );
                  params['websiteUrls'] = urls.join(', ');
                  setState(() {
                    _internalMcps[entryIndex] = _internalMcps[entryIndex]
                        .copyWith(initParams: params);
                  });
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      friendlyLabel,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (description.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2, bottom: 4),
                        child: Text(
                          description,
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey[500],
                          ),
                          maxLines: 3,
                        ),
                      ),
                    const SizedBox(height: 6),
                    if (selUrls.isNotEmpty) ...[
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: selUrls.map<Widget>((url) {
                          Uri? parsed;
                          try {
                            parsed = Uri.parse(
                              url.contains('://') ? url : 'https://\$url',
                            );
                          } catch (_) {}
                          final host = parsed?.host.isNotEmpty == true
                              ? parsed!.host
                              : url;
                          final isGlobal = _globalWebsiteUrls.contains(url);
                          if (isGlobal) {
                            return Tooltip(
                              message: '\$url (from Settings → Data Sources)',
                              child: Chip(
                                label: Text(
                                  host,
                                  style: const TextStyle(fontSize: 12),
                                ),
                                avatar: const Icon(Icons.settings, size: 14),
                                backgroundColor: Theme.of(context)
                                    .colorScheme
                                    .primaryContainer
                                    .withValues(alpha: 0.5),
                              ),
                            );
                          }
                          return InputChip(
                            label: Text(
                              host,
                              style: const TextStyle(fontSize: 12),
                            ),
                            avatar: const Icon(Icons.public, size: 16),
                            tooltip: url,
                            deleteIcon: const Icon(Icons.close, size: 16),
                            onDeleted: () {
                              final updated = List<String>.from(selUrls)
                                ..remove(url);
                              saveUrls(updated);
                            },
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 8),
                    ],
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final narrow = constraints.maxWidth < 480;
                        final addBtn = OutlinedButton.icon(
                          onPressed: canAddTyped
                              ? () {
                                  final normalized = typed.toString();
                                  final updated = List<String>.from(selUrls)
                                    ..add(normalized);
                                  saveUrls(updated);
                                  setInner(() => _websiteUrlCtrl.clear());
                                }
                              : null,
                          icon: const Icon(Icons.add, size: 18),
                          label: Text(l.addUrlButton),
                        );
                        final urlField = TextField(
                          controller: _websiteUrlCtrl,
                          decoration: InputDecoration(
                            border: const OutlineInputBorder(),
                            isDense: true,
                            labelText: l.websiteUrlLabel,
                            hintText: 'https://example.com/docs',
                            suffixIcon: const Icon(Icons.add_link),
                          ),
                          onChanged: (_) => setInner(() {}),
                          onSubmitted: (_) {
                            if (!canAddTyped) return;
                            final normalized = typed.toString();
                            final updated = List<String>.from(selUrls)
                              ..add(normalized);
                            saveUrls(updated);
                            setInner(() => _websiteUrlCtrl.clear());
                          },
                        );
                        if (narrow) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              urlField,
                              const SizedBox(height: 8),
                              addBtn,
                            ],
                          );
                        }
                        return Row(
                          children: [
                            Expanded(child: urlField),
                            const SizedBox(width: 8),
                            addBtn,
                          ],
                        );
                      },
                    ),
                    if (_websiteUrlCtrl.text.trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          typed == null
                              ? l.invalidWebsiteUrl
                              : canAddTyped
                              ? 'Ready to add.'
                              : 'URL already added or limit reached ($maxUrls).',
                          style: TextStyle(
                            fontSize: 11,
                            color: typed == null
                                ? AppTheme.error
                                : Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    if (_globalWebsiteUrls.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '${_globalWebsiteUrls.length} site${_globalWebsiteUrls.length == 1 ? '' : 's'} from Settings (locked). Add more above (max $maxUrls).',
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        );
        continue;
      }

      // ── Google Drive folderPath: add Browse button ──
      if (info.type == 'google_drive' && paramName == 'folderPath') {
        fields.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 24),
            child: TextFormField(
              key: ValueKey('folderPath_${entry.id}_$currentVal'),
              initialValue: currentVal,
              decoration: InputDecoration(
                labelText: friendlyLabel,
                helperText: description,
                helperMaxLines: 3,
                hintText: defaultVal.isNotEmpty
                    ? l.defaultPrefix(defaultVal)
                    : null,
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 16,
                ),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.folder_open),
                  tooltip: L.of(context).browseDriveTooltip,
                  onPressed: () => _showDriveFolderPicker(
                    parentContext: context,
                    entryIndex: entryIndex,
                    paramName: paramName,
                    currentPath: currentVal,
                  ),
                ),
              ),
              onChanged: (value) {
                final params = Map<String, dynamic>.from(
                  _internalMcps[entryIndex].initParams,
                );
                params[paramName] = value;
                _internalMcps[entryIndex] = _internalMcps[entryIndex].copyWith(
                  initParams: params,
                );
              },
            ),
          ),
        );
        continue;
      }

      fields.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 24),
          child: TextFormField(
            initialValue: currentVal,
            obscureText: schema['sensitive'] == true,
            decoration: InputDecoration(
              labelText: friendlyLabel,
              helperText: description,
              helperMaxLines: 3,
              hintText: defaultVal.isNotEmpty
                  ? l.defaultPrefix(defaultVal)
                  : null,
              border: const OutlineInputBorder(),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 16,
              ),
            ),
            onChanged: (value) {
              final params = Map<String, dynamic>.from(
                _internalMcps[entryIndex].initParams,
              );
              params[paramName] = value;
              _internalMcps[entryIndex] = _internalMcps[entryIndex].copyWith(
                initParams: params,
              );
            },
          ),
        ),
      );
    }

    return fields;
  }

  // ═══════════════════════════════════════════════════════
  // Apply default LLM settings from secure storage
  // ═══════════════════════════════════════════════════════
  void _applyLlmDefaults(LlmSettingsService settings) {
    final l = L.of(context);
    if (!settings.isConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l.llmNoDefaults),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    setState(() {
      _overrideLlm = true;
      _llmProviderCtrl.text = settings.provider.configKey;
      _llmModelCtrl.text = settings.model;
      _llmApiKeyCtrl.text = settings.apiKey;
      _llmBaseUrlCtrl.text = settings.baseUrl;
      _temperatureCtrl.text = settings.temperature.toString();
      _maxTokensCtrl.text = settings.maxTokens.toString();
      _maxToolOutputSizeCtrl.text = settings.maxToolOutputSize.toString();
      _tokenWarningThresholdCtrl.text = settings.tokenWarningThreshold
          .toString();
      _useNativeToolCall = settings.useNativeToolCall;
      _isSlm = settings.isSlm;
      _isMultiModal = settings.isMultiModal;
      _thinking = settings.thinking;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l.llmDefaultsApplied),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Build the compact Start/Stop button for inline placement beside the dropdown.
  bool _isReindexing = false;
  int _indexedCount = 0;
  int _indexTotal = 0;
  String _indexCurrentFile = '';
  DocumentMcpServer? _activeIndexServer;
  WebsiteSearchMcpServer? _activeWebIndexServer;

  /// Opens the Google Drive folder picker and writes the selected path back
  /// into [_internalMcps][entryIndex].initParams[paramName].
  Future<void> _showDriveFolderPicker({
    required BuildContext parentContext,
    required int entryIndex,
    required String paramName,
    required String currentPath,
  }) async {
    final selected = await showDialog<String?>(
      context: parentContext,
      builder: (_) => _DriveFolderPickerDialog(initialPath: currentPath),
    );
    if (selected == null || !mounted) return;
    setState(() {
      final params = Map<String, dynamic>.from(
        _internalMcps[entryIndex].initParams,
      );
      params[paramName] = selected;
      _internalMcps[entryIndex] = _internalMcps[entryIndex].copyWith(
        initParams: params,
      );
    });
  }

  Uri? _normalizeWebsiteUrl(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;
    try {
      final parsed = Uri.parse(
        value.contains('://') ? value : 'https://$value',
      );
      if ((parsed.scheme != 'http' && parsed.scheme != 'https') ||
          parsed.host.isEmpty) {
        return null;
      }
      return parsed.removeFragment();
    } catch (_) {
      return null;
    }
  }

  Widget _buildIndexingButton(
    InternalMcpEntry entry, {
    required String mcpType,
  }) {
    final l = L.of(context);
    final isDocument = mcpType == 'document';
    final isWebsite = mcpType == 'website_search';
    final rootPath = entry.initParams['rootPath'] as String? ?? '';
    final websiteUrls = entry.initParams['websiteUrls'] as String? ?? '';
    final hasRequiredInput = isDocument
        ? rootPath.trim().isNotEmpty
        : (isWebsite ? websiteUrls.trim().isNotEmpty : false);

    return SizedBox(
      height: 52,
      child: _isReindexing
          ? ElevatedButton.icon(
              onPressed: (isDocument || isWebsite)
                  ? () {
                      _activeIndexServer?.cancelIndexing();
                      _activeWebIndexServer?.cancelIndexing();
                    }
                  : null,
              icon: const Icon(Icons.stop, size: 18),
              label: Text(
                l.indexingStop,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.error,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 16),
              ),
            )
          : ElevatedButton.icon(
              onPressed: hasRequiredInput
                  ? () => _doReindex(entry, mcpType: mcpType)
                  : null,
              icon: const Icon(Icons.play_arrow, size: 18),
              label: Text(
                l.indexingStart,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: hasRequiredInput ? Colors.green : Colors.grey,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 16),
              ),
            ),
    );
  }

  Future<void> _doReindex(
    InternalMcpEntry entry, {
    required String mcpType,
  }) async {
    final l = L.of(context);

    // On Android, ensure storage permission before indexing documents
    if (Platform.isAndroid && mcpType == 'document') {
      final hasAccess = await StoragePermission.hasAccess();
      if (!hasAccess) {
        if (!mounted) return;
        final messenger = ScaffoldMessenger.of(context);
        final granted = await StoragePermission.request(context);
        if (!mounted || !granted) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(l.reindexFailed('Storage permission not granted')),
              backgroundColor: AppTheme.error,
            ),
          );
          return;
        }
      }
    }

    setState(() {
      _isReindexing = true;
      _indexedCount = 0;
      _indexTotal = 0;
      _indexCurrentFile = '';
    });

    try {
      final isDocument = mcpType == 'document';
      final server = isDocument
          ? DocumentMcpServer()
          : WebsiteSearchMcpServer();

      if (server is DocumentMcpServer) {
        _activeIndexServer = server;
        _activeWebIndexServer = null;
        server.onIndexProgress = (indexed, total, currentFile) {
          if (mounted) {
            setState(() {
              _indexedCount = indexed;
              _indexTotal = total;
              _indexCurrentFile = currentFile;
            });
          }
        };
      } else if (server is WebsiteSearchMcpServer) {
        _activeWebIndexServer = server;
        _activeIndexServer = null;
        server.onIndexProgress = (indexed, total, currentUrl) {
          if (mounted) {
            setState(() {
              _indexedCount = indexed;
              _indexTotal = total;
              _indexCurrentFile = currentUrl;
            });
          }
        };
      } else {
        _activeIndexServer = null;
        _activeWebIndexServer = null;
      }

      await server.initialize(entry.initParams);
      final result = await server.executeTool(
        isDocument ? 'reindex' : 'reindex_websites',
        {},
      );
      await server.dispose();
      _activeIndexServer = null;
      _activeWebIndexServer = null;

      if (!mounted) return;

      final wasCancelled = result['cancelled'] == true;

      if (result.containsKey('error')) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l.reindexFailed(result['error'] as String)),
            backgroundColor: AppTheme.error,
          ),
        );
      } else if (wasCancelled) {
        final count = result['indexed'] as int? ?? _indexedCount;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.indexingCancelled(count))));
      } else {
        final count =
            result['documentsIndexed'] as int? ??
            result['indexedPages'] as int? ??
            0;
        final ms = result['durationMs'] as int? ?? 0;
        final totalFileSize = result['totalFileSizeBytes'] as int? ?? 0;
        final indexSize = result['indexSizeBytes'] as int? ?? 0;
        final fileSizeKb = (totalFileSize / 1024).toStringAsFixed(1);
        final indexSizeKb = (indexSize / 1024).toStringAsFixed(1);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l.reindexComplete(count, ms, fileSizeKb, indexSizeKb),
            ),
          ),
        );
      }
    } catch (e) {
      _activeIndexServer = null;
      _activeWebIndexServer = null;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l.reindexFailed(e.toString())),
          backgroundColor: AppTheme.error,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isReindexing = false;
          _indexCurrentFile = '';
        });
      }
    }
  }

  /// Map icon name to Material icon.
  IconData _mcpIcon(String name) {
    return switch (name) {
      'cloud' => Icons.cloud,
      'description' => Icons.description,
      'email' => Icons.email,
      'search' => Icons.search,
      'language' => Icons.language,
      'build' => Icons.build,
      _ => Icons.extension,
    };
  }

  // ═══════════════════════════════════════════════════════
  // Tab 6: Notifications
  // ═══════════════════════════════════════════════════════
  List<Widget> _buildNotifyContent() {
    final l = L.of(context);
    final ds = DataSourcesSettingsService.instance;
    return [
      _sectionTitle(l.outputType),
      DropdownButtonFormField<String>(
        initialValue: _outputType,
        decoration: InputDecoration(labelText: l.outputType),
        items: [
          DropdownMenuItem(value: 'none', child: Text('None (No output)')),
          DropdownMenuItem(value: 'email', child: Text(l.outputTypeEmail)),
          DropdownMenuItem(value: 'file', child: Text(l.outputTypeFile)),
          DropdownMenuItem(value: 'sftp', child: Text(l.outputTypeSftp)),
        ],
        onChanged: (value) {
          if (value == null) return;
          setState(() {
            _outputType = value;
            if (_outputType != 'email') {
              _emailNotifyEnabled = false;
            }
          });
        },
      ),
      if (_outputType == 'email') ...[
        const SizedBox(height: 24),
        _sectionTitle(l.emailNotification),
        const SizedBox(height: 8),
        TextFormField(
          controller: _emailToCtrl,
          decoration: InputDecoration(
            labelText: l.toEmail,
            hintText: l.toEmailHint,
          ),
          keyboardType: TextInputType.emailAddress,
          validator: (v) {
            if (_outputType != 'email') return null;
            if (v == null || v.trim().isEmpty) return l.fieldRequired;
            final emails = v
                .split(',')
                .map((e) => e.trim())
                .where((e) => e.isNotEmpty);
            final emailRegex = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
            if (emails.isEmpty || emails.any((e) => !emailRegex.hasMatch(e))) {
              return l.invalidEmail;
            }
            return null;
          },
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _emailSubjectCtrl,
          decoration: InputDecoration(
            labelText: l.subject,
            hintText: l.subjectHint,
          ),
          validator: (v) {
            if (_outputType != 'email') return null;
            if (v == null || v.trim().isEmpty) return l.fieldRequired;
            return null;
          },
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: _emailSendConditionCtrl.text.isNotEmpty
              ? _emailSendConditionCtrl.text
              : 'always',
          decoration: InputDecoration(labelText: l.sendCondition),
          items: [
            DropdownMenuItem(value: 'always', child: Text(l.always)),
            DropdownMenuItem(value: 'on_success', child: Text(l.onSuccess)),
            DropdownMenuItem(value: 'on_failure', child: Text(l.onFailure)),
            DropdownMenuItem(value: 'on_change', child: Text(l.onResultChange)),
            const DropdownMenuItem(
              value: 'conditional',
              child: Text('Conditional (LLM)'),
            ),
          ],
          onChanged: (v) =>
              setState(() => _emailSendConditionCtrl.text = v ?? 'always'),
        ),
        if (_emailSendConditionCtrl.text == 'conditional') ...[
          const SizedBox(height: 8),
          TextFormField(
            controller: _emailConditionExprCtrl,
            decoration: const InputDecoration(
              labelText: 'Condition expression',
              hintText: 'e.g. output is TRUE or temperature > 10',
            ),
            validator: (v) {
              if (_outputType != 'email' ||
                  _emailSendConditionCtrl.text != 'conditional') {
                return null;
              }
              if (v == null || v.trim().isEmpty) {
                return 'Condition expression is required.';
              }
              return null;
            },
          ),
        ],
      ],
      if (_outputType == 'file') ...[
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextFormField(
                controller: _downloadPathCtrl,
                decoration: InputDecoration(
                  labelText: l.outputDirectory,
                  hintText: l.outputDirectoryHint,
                ),
                readOnly: true,
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 48,
              child: OutlinedButton(
                onPressed: _pickOutputDirectory,
                child: const Icon(Icons.folder_open),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          l.outputDirectoryNote,
          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _downloadFilePatternCtrl,
          decoration: InputDecoration(
            labelText: l.fileNamePattern,
            hintText: l.fileNamePatternHint('{date}'),
          ),
        ),
      ],
      if (_outputType == 'sftp') ...[
        const SizedBox(height: 12),
        CheckboxListTile(
          value: _sftpUseConfiguredSshServer,
          onChanged: (v) =>
              setState(() => _sftpUseConfiguredSshServer = v ?? true),
          title: Text(l.sftpUseConfiguredSshServer),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.trailing,
          dense: true,
        ),
        if (!_sftpUseConfiguredSshServer) ...[
          const SizedBox(height: 8),
          TextFormField(
            controller: _sftpHostCtrl,
            decoration: InputDecoration(
              labelText: l.sftpHost,
              hintText: 'sftp.example.com',
            ),
            validator: (v) {
              if (_outputType != 'sftp' || _sftpUseConfiguredSshServer) {
                return null;
              }
              if (v == null || v.trim().isEmpty) return l.fieldRequired;
              return null;
            },
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _sftpPortCtrl,
            decoration: InputDecoration(labelText: l.sftpPort),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _sftpUsernameCtrl,
            decoration: InputDecoration(labelText: l.sftpUsername),
            validator: (v) {
              if (_outputType != 'sftp' || _sftpUseConfiguredSshServer) {
                return null;
              }
              if (v == null || v.trim().isEmpty) return l.fieldRequired;
              return null;
            },
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _sftpPasswordCtrl,
            decoration: InputDecoration(labelText: l.sftpPassword),
            obscureText: true,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final result = await FilePicker.pickFiles(
                      type: FileType.any,
                      allowMultiple: false,
                      withData: true,
                    );
                    if (result == null || result.files.single.bytes == null) {
                      return;
                    }
                    final decoded = utf8.decode(
                      result.files.single.bytes!,
                      allowMalformed: false,
                    );
                    setState(() {
                      _sftpPrivateKeyPem = decoded;
                      _sftpPrivateKeyFileName = result.files.single.name;
                    });
                  },
                  icon: const Icon(Icons.key, size: 16),
                  label: Text(
                    _sftpPrivateKeyFileName.isNotEmpty
                        ? _sftpPrivateKeyFileName
                        : 'Load Private Key (PEM)…',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              if (_sftpPrivateKeyPem.isNotEmpty) ...[
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Clear private key',
                  icon: const Icon(Icons.clear, size: 16),
                  onPressed: () => setState(() {
                    _sftpPrivateKeyPem = '';
                    _sftpPrivateKeyFileName = '';
                  }),
                ),
              ],
            ],
          ),
        ],
        const SizedBox(height: 8),
        TextFormField(
          controller: _sftpRemotePathCtrl,
          decoration: InputDecoration(
            labelText: l.sftpRemotePath,
            hintText: l.sftpRemotePathHint,
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: OutlinedButton.icon(
            onPressed: _testSftpConnection,
            icon: const Icon(Icons.network_check),
            label: const Text('Test connection'),
          ),
        ),
        const SizedBox(height: 16),
        CheckboxListTile(
          value: _sftpNotifyByEmail,
          onChanged: (v) => setState(() => _sftpNotifyByEmail = v ?? false),
          title: Text(l.sftpNotifyByEmail),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.trailing,
          dense: true,
        ),
        if (_sftpNotifyByEmail) ...[
          const SizedBox(height: 8),
          TextFormField(
            controller: _sftpNotifyEmailAddressCtrl,
            decoration: InputDecoration(
              labelText: l.sftpNotifyEmailAddress,
              hintText: 'user@example.com',
            ),
            keyboardType: TextInputType.emailAddress,
            validator: (v) {
              if (_outputType != 'sftp' || !_sftpNotifyByEmail) return null;
              if (v == null || v.trim().isEmpty) return l.fieldRequired;
              return null;
            },
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _sftpNotifyEmailSubjectCtrl,
            decoration: InputDecoration(labelText: l.sftpNotifyEmailSubject),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _sftpNotifyEmailBodyCtrl,
            decoration: InputDecoration(
              labelText: l.sftpNotifyEmailBody,
              hintText: l.sftpNotifyEmailBodyHint,
            ),
            maxLines: 3,
          ),
        ],
      ],
      const SizedBox(height: 20),
      _sectionTitle(l.generatedFiles),
      CheckboxListTile(
        value: _addExecutionLogToOutput,
        onChanged: (v) => setState(() => _addExecutionLogToOutput = v ?? false),
        title: Text(l.addExecutionLogToOutput),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.trailing,
      ),
      CheckboxListTile(
        value: _zipOutputFiles,
        onChanged: (v) => setState(() => _zipOutputFiles = v ?? false),
        title: Text(l.zipOutputFiles),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.trailing,
      ),
      const SizedBox(height: 24),

      // ── Slack ──────────────────────────────────────────────────────
      _sectionTitle('Slack'),
      const SizedBox(height: 4),
      Text(
        ds.isSlackConfigured
            ? 'Uses globally configured Slack credentials.'
            : 'Configure Slack first in Data Sources settings.',
        style: TextStyle(
          fontSize: 12,
          color: ds.isSlackConfigured ? Colors.grey[500] : Colors.orange,
        ),
      ),
      const SizedBox(height: 8),
      SwitchListTile(
        value: _slackNotifyEnabled,
        onChanged: ds.isSlackConfigured
            ? (v) => setState(() => _slackNotifyEnabled = v)
            : null,
        title: const Text('Send to Slack'),
        contentPadding: EdgeInsets.zero,
        dense: true,
        controlAffinity: ListTileControlAffinity.trailing,
      ),
      if (_slackNotifyEnabled) ...[
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: _slackSendCondition,
          decoration: const InputDecoration(labelText: 'Send condition'),
          items: const [
            DropdownMenuItem(value: 'always', child: Text('Always')),
            DropdownMenuItem(
              value: 'on_success',
              child: Text('On success only'),
            ),
            DropdownMenuItem(value: 'on_error', child: Text('On error only')),
          ],
          onChanged: (v) => setState(() => _slackSendCondition = v ?? 'always'),
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: _slackChannelCtrl,
          decoration: const InputDecoration(
            labelText: 'Override channel (optional)',
            hintText:
                '#channel  ·  C0… (channel ID)  ·  U0… (your Member ID = DM to yourself)',
            helperText:
                'Leave blank to use the global default from Data Sources.',
            helperMaxLines: 2,
          ),
        ),
        const SizedBox(height: 4),
        CheckboxListTile(
          value: _slackWithAttachment,
          onChanged: (v) => setState(() => _slackWithAttachment = v ?? false),
          title: const Text('Include output files as attachments'),
          subtitle: const Text(
            'Requires bot token in Data Sources',
            style: TextStyle(fontSize: 11),
          ),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.trailing,
          dense: true,
        ),
      ],

      const SizedBox(height: 20),

      // ── WhatsApp ────────────────────────────────────────────────────
      _sectionTitle('WhatsApp'),
      const SizedBox(height: 4),
      Text(
        ds.isWhatsAppConfigured
            ? 'Uses globally configured WhatsApp Business credentials.'
            : 'Configure WhatsApp first in Data Sources settings.',
        style: TextStyle(
          fontSize: 12,
          color: ds.isWhatsAppConfigured ? Colors.grey[500] : Colors.orange,
        ),
      ),
      const SizedBox(height: 8),
      SwitchListTile(
        value: _whatsAppNotifyEnabled,
        onChanged: ds.isWhatsAppConfigured
            ? (v) => setState(() => _whatsAppNotifyEnabled = v)
            : null,
        title: const Text('Send to WhatsApp'),
        contentPadding: EdgeInsets.zero,
        dense: true,
        controlAffinity: ListTileControlAffinity.trailing,
      ),
      if (_whatsAppNotifyEnabled) ...[
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: _whatsAppSendCondition,
          decoration: const InputDecoration(labelText: 'Send condition'),
          items: const [
            DropdownMenuItem(value: 'always', child: Text('Always')),
            DropdownMenuItem(
              value: 'on_success',
              child: Text('On success only'),
            ),
            DropdownMenuItem(value: 'on_error', child: Text('On error only')),
          ],
          onChanged: (v) =>
              setState(() => _whatsAppSendCondition = v ?? 'always'),
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: _whatsAppRecipientCtrl,
          decoration: const InputDecoration(
            labelText: 'Override recipient number (optional)',
            hintText: '+43… — leave blank for global default',
          ),
          keyboardType: TextInputType.phone,
        ),
      ],
      const SizedBox(height: 24),
    ];
  }

  Widget _buildNotifyTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: _buildNotifyContent(),
    );
  }

  Future<void> _pickOutputDirectory() async {
    final selected = await FilePicker.getDirectoryPath(
      dialogTitle: L.of(context).chooseDirectory,
    );
    if (!mounted || selected == null || selected.isEmpty) return;
    setState(() {
      _downloadPathCtrl.text = selected;
    });
  }

  Future<void> _testSftpConnection() async {
    final ds = DataSourcesSettingsService.instance;
    if (!ds.isLoaded) {
      await ds.load();
    }

    final host = _sftpUseConfiguredSshServer
        ? ds.sshHost.trim()
        : _sftpHostCtrl.text.trim();
    final port = _sftpUseConfiguredSshServer
        ? ds.sshPort
        : (int.tryParse(_sftpPortCtrl.text.trim()) ?? 22);
    final username = _sftpUseConfiguredSshServer
        ? ds.sshUsername.trim()
        : _sftpUsernameCtrl.text.trim();
    final password = _sftpUseConfiguredSshServer
        ? ds.sshPassword
        : _sftpPasswordCtrl.text;
    final privateKey = _sftpUseConfiguredSshServer
        ? ds.sshPrivateKey.trim()
        : _sftpPrivateKeyPem.trim();
    final remotePath = _sftpRemotePathCtrl.text.trim().isEmpty
        ? '/'
        : _sftpRemotePathCtrl.text.trim();

    if (host.isEmpty || username.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('SFTP test failed: host and username are required.'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Testing SFTP connection...')));

    SSHClient? client;
    SftpClient? sftp;
    try {
      client = SSHClient(
        await SSHSocket.connect(
          host,
          port,
        ).timeout(const Duration(seconds: 12)),
        username: username,
        identities: privateKey.isNotEmpty
            ? SSHKeyPair.fromPem(privateKey)
            : null,
        onPasswordRequest: () => password,
      );
      await client.authenticated.timeout(const Duration(seconds: 12));
      sftp = await client.sftp().timeout(const Duration(seconds: 12));
      await sftp.listdir(remotePath).timeout(const Duration(seconds: 12));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('SFTP connection successful.'),
          backgroundColor: AppTheme.success,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('SFTP connection failed: $e'),
          backgroundColor: AppTheme.error,
        ),
      );
    } finally {
      try {
        sftp?.close();
      } catch (_) {}
      try {
        client?.close();
      } catch (_) {}
    }
  }

  Future<void> _testInternalSshConnection(Map<String, dynamic> params) async {
    final ds = DataSourcesSettingsService.instance;
    if (!ds.isLoaded) {
      await ds.load();
    }

    final host = ((params['host'] as String?) ?? '').trim().isNotEmpty
        ? ((params['host'] as String?) ?? '').trim()
        : ds.sshHost.trim();
    final rawPort = params['port'];
    final port = rawPort is int && rawPort > 0 ? rawPort : ds.sshPort;
    final username = ((params['username'] as String?) ?? '').trim().isNotEmpty
        ? ((params['username'] as String?) ?? '').trim()
        : ds.sshUsername.trim();
    final password = ((params['password'] as String?) ?? '').isNotEmpty
        ? (params['password'] as String?)!
        : ds.sshPassword;
    final privateKey =
        ((params['privateKey'] as String?) ?? '').trim().isNotEmpty
        ? ((params['privateKey'] as String?) ?? '').trim()
        : ds.sshPrivateKey.trim();

    if (host.isEmpty || username.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('SSH test failed: host and username are required.'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Testing SSH connection...')));

    SSHClient? client;
    try {
      client = SSHClient(
        await SSHSocket.connect(
          host,
          port,
        ).timeout(const Duration(seconds: 12)),
        username: username,
        identities: privateKey.isNotEmpty
            ? SSHKeyPair.fromPem(privateKey)
            : null,
        onPasswordRequest: () => password,
      );
      await client.authenticated.timeout(const Duration(seconds: 12));
      final session = await client
          .execute('echo tealkit_ssh_test_ok')
          .timeout(const Duration(seconds: 12));
      await utf8.decoder
          .bind(session.stdout)
          .join()
          .timeout(const Duration(seconds: 12));
      await utf8.decoder
          .bind(session.stderr)
          .join()
          .timeout(const Duration(seconds: 12));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('SSH connection successful.'),
          backgroundColor: AppTheme.success,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('SSH connection failed: $e'),
          backgroundColor: AppTheme.error,
        ),
      );
    } finally {
      try {
        client?.close();
      } catch (_) {}
    }
  }

  // ─── Helpers ─────────────────────────────────────────

  /// Builds a preview of the full effective system prompt that will be sent to
  /// the LLM, replicating the logic from [ActiveTaskNotifier.setTask].
  Future<String> _buildEffectiveSystemPromptPreview() async {
    final now = DateTime.now();
    const wd = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    const mo = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    final llmSettings = ref.read(llmSettingsProvider);
    final isCompact = llmSettings.isSlm;
    final dateHeader = isCompact
        ? 'TODAY: ${wd[now.weekday - 1]}, ${now.day} ${mo[now.month - 1]} ${now.year}, '
              '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}.'
        : 'CURRENT DATE/TIME: ${wd[now.weekday - 1]}, ${now.day} ${mo[now.month - 1]} ${now.year}, '
              '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')} local time. '
              'This is the authoritative current date — do NOT assume a different year from training data.';

    final userPromptText = _combinedSystemPrompt.trim();
    var preview = userPromptText.isEmpty
        ? dateHeader
        : '$dateHeader\n\n$userPromptText';

    if (!isCompact) {
      final toolboxPrompt = InternalMcpRegistry()
          .create('toolbox')
          ?.defaultSystemPrompt
          .trim();
      if (toolboxPrompt != null && toolboxPrompt.isNotEmpty) {
        preview = '$preview\n\n$toolboxPrompt';
      }
      const formatInstruction =
          'Output formatting: If the user requests a specific format, you can format the response accordingly '
          '(e.g., Markdown, HTML, JSON, CSV, plain text, table). '
          'Default to concise plain text when no specific format is requested.';
      preview = '$preview\n\n$formatInstruction';
    }

    // Capability hints
    final capabilityHints = <String>[];
    for (final entry in _internalMcps) {
      if (!entry.enabled) continue;
      switch (entry.mcpType) {
        case 'gmail':
          capabilityHints.add(
            isCompact
                ? 'Email: search_gmail(q, includeBody:true), get_gmail_message.'
                : 'Email: use search_gmail and get_gmail_message.',
          );
        case 'document':
          capabilityHints.add(
            isCompact
                ? 'Docs: search_documents, get_document_content.'
                : 'Local documents: use search_documents and get_document_content.',
          );
        case 'file':
          capabilityHints.add(
            isCompact
                ? 'Files: create_text_file to save output.'
                : 'File output: use create_text_file to create .txt/.md/.html files.',
          );
        case 'google_calendar':
          capabilityHints.add(
            isCompact
                ? 'Calendar: list_calendars, list_events, create_event, update_event, delete_event.'
                : 'Google Calendar tools available.',
          );
        case 'google_drive':
          capabilityHints.add(
            isCompact
                ? 'Drive: search_drive, read_drive_file.'
                : 'Google Drive: use search_drive and read_drive_file.',
          );
        case 'onedrive':
          capabilityHints.add(
            isCompact
                ? 'OneDrive: search_onedrive, read_onedrive_file.'
                : 'OneDrive: use search_onedrive and read_onedrive_file.',
          );
        case 'website_search':
          capabilityHints.add(
            isCompact
                ? 'Websites: search_indexed_websites, get_indexed_page.'
                : 'Indexed websites: use search_indexed_websites and get_indexed_page.',
          );
        case 'web_search':
          capabilityHints.add(
            isCompact
                ? 'Web: web_search for current info.'
                : 'Public web: use web_search for current/public information.',
          );
        case 'weather':
          capabilityHints.add('Weather: use weather tools.');
        case 'imap':
          capabilityHints.add(
            isCompact
                ? 'IMAP: search_emails, read_email.'
                : 'IMAP email: use search_emails then read_email.',
          );
        case 'chart':
          capabilityHints.add(
            isCompact
                ? 'Charts: create_chart_png.'
                : 'Charts: use create_chart_png to build PNG charts.',
          );
      }
    }
    if (capabilityHints.isNotEmpty) {
      preview =
          '$preview\n\nEnabled capabilities:\n- ${capabilityHints.join('\n- ')}';
    }

    // Skills (internal MCPs + external/global + task-specific servers)
    final hasSubstantialUserPrompt =
        userPromptText.contains('\n') || userPromptText.length > 50;
    if (!isCompact || hasSubstantialUserPrompt) {
      try {
        final toolNames = <String>[
          ..._internalMcps.where((e) => e.enabled).expand((e) {
            final server = InternalMcpRegistry().create(e.mcpType);
            return server?.tools.map((t) => t.name) ?? <String>[];
          }),
          ...ExternalToolsSettingsService.instance.selectedServers
              .where((s) => _selectedGlobalServerUrls.contains(s.serverUrl))
              .expand((s) => s.discoveredTools),
          ..._mcpServers.expand((s) => s.discoveredTools),
        ];
        if (toolNames.isNotEmpty) {
          final skills = await FunctionHintDatabaseService().getEnabledForTools(
            toolNames,
          );
          if (skills.isNotEmpty) {
            final skillLines = skills
                .map(
                  (s) =>
                      '• ${s.toolName}: ${isCompact ? s.skillTextSlm : s.skillText}',
                )
                .join('\n');
            preview = '$preview\n\nTool Hints:\n$skillLines';
          }
        }
      } catch (_) {}
    }

    return preview;
  }

  /// Shows a dialog with the full effective system prompt that will be sent.
  /// Allows editing the user-controlled portion and applying changes back.
  Future<void> _showFullPromptPreview() async {
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (ctx) => _SystemPromptPreviewDialog(
        initialUserText: _systemPromptUserCtrl.text,
        initialSkillsText: _systemPromptSkillsCtrl.text,
      ),
    );
    if (result != null && mounted) {
      final (userText, skillsText) = result;
      setState(() {
        _systemPromptUserCtrl.text = userText;
        _systemPromptSkillsCtrl.text = skillsText;
      });
    }
  }

  /// Skills textbox — auto-generated content, always visible below user prompt.
  Widget _buildSkillsTextbox() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              Icons.auto_fix_high_outlined,
              size: 13,
              color: Colors.grey[500],
            ),
            const SizedBox(width: 4),
            Text(
              'Tool Hints (auto-generated)',
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey[500],
                fontWeight: FontWeight.w500,
              ),
            ),
            const Spacer(),
            if (_systemPromptSkillsCtrl.text.isNotEmpty)
              InkWell(
                onTap: () => setState(() => _systemPromptSkillsCtrl.text = ''),
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.clear, size: 13, color: Colors.grey[500]),
                      const SizedBox(width: 2),
                      Text(
                        'Clear',
                        style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        TextField(
          controller: _systemPromptSkillsCtrl,
          maxLines: 5,
          minLines: 2,
          style: TextStyle(
            fontSize: 12,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            fontFamily: 'monospace',
          ),
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            isDense: true,
            contentPadding: const EdgeInsets.all(8),
            hintText: 'No Tool Hints loaded',
            hintStyle: TextStyle(fontSize: 12, color: Colors.grey[600]),
            filled: true,
            fillColor: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.4,
            ),
          ),
        ),
      ],
    );
  }

  /// System prompt field using StepListEditor (supports ++#++ multi-step sections).
  Widget _buildSystemPromptSection() {
    final l = L.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              l.systemPrompt,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            Tooltip(
              message: 'Preview full prompt',
              child: InkWell(
                onTap: _showFullPromptPreview,
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.preview_outlined,
                        size: 16,
                        color: Theme.of(context).colorScheme.secondary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Preview',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.secondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Tooltip(
              message: 'KI-Assistent: Prompt generieren',
              child: InkWell(
                onTap: () => _showPromptWizardDialog(
                  context,
                  _systemPromptUserCtrl,
                  isSystemPrompt: true,
                ),
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.auto_awesome,
                        size: 16,
                        color: AppTheme.primaryBlue,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'KI-Assistent',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppTheme.primaryBlue,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        TextFormField(
          controller: _systemPromptUserCtrl,
          minLines: 3,
          maxLines: 8,
          decoration: InputDecoration(
            hintText: l.systemPromptHint,
            border: const OutlineInputBorder(),
          ),
          onChanged: (_) => _updateSkillsSection(),
        ),
        const SizedBox(height: 8),
        _buildSkillsTextbox(),
      ],
    );
  }

  /// Prompt field with AI-wizard icon button in the header row.
  Widget _buildPromptSection({
    required String label,
    required String hint,
    required TextEditingController controller,
    required bool isSystemPrompt,
    int maxLines = 4,
    String? Function(String?)? validator,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            Tooltip(
              message: 'KI-Assistent: Prompt generieren',
              child: InkWell(
                onTap: () => _showPromptWizardDialog(
                  context,
                  controller,
                  isSystemPrompt: isSystemPrompt,
                ),
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.auto_awesome,
                        size: 16,
                        color: AppTheme.primaryBlue,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'KI-Assistent',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppTheme.primaryBlue,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        TextFormField(
          controller: controller,
          decoration: InputDecoration(hintText: hint, alignLabelWithHint: true),
          maxLines: maxLines,
          validator: validator,
        ),
      ],
    );
  }

  /// Full-screen prompt wizard dialog: enter a topic, generate a prompt suggestion.
  Future<void> _showPromptWizardDialog(
    BuildContext context,
    TextEditingController targetCtrl, {
    required bool isSystemPrompt,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (_) => PromptWizardDialog(
        // For system prompts, pass only the user-managed base (strip skills block)
        // so the wizard doesn't accidentally see or regenerate the auto-appended skills.
        initialText: targetCtrl.text,
        isSystemPrompt: isSystemPrompt,
        onAccept: (text) {
          targetCtrl.text = text;
          // Re-append the skills section based on the (potentially new) base text.
          if (isSystemPrompt) _updateSkillsSection();
        },
        taskRef: ref,
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.bold,
          color: AppTheme.primaryBlue,
        ),
      ),
    );
  }

  Widget _fieldRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 12))),
        ],
      ),
    );
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String text,
    String? subtitle,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        children: [
          Icon(icon, size: 48, color: Colors.grey[400]),
          const SizedBox(height: 12),
          Text(text, style: TextStyle(color: Colors.grey[600])),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: TextStyle(fontSize: 12, color: Colors.grey[500]),
            ),
          ],
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// System Prompt Preview Dialog
// ═══════════════════════════════════════════════════════════════════

class _SystemPromptPreviewDialog extends StatefulWidget {
  const _SystemPromptPreviewDialog({
    required this.initialUserText,
    required this.initialSkillsText,
  });

  final String initialUserText;
  final String initialSkillsText;

  @override
  State<_SystemPromptPreviewDialog> createState() =>
      _SystemPromptPreviewDialogState();
}

class _SystemPromptPreviewDialogState
    extends State<_SystemPromptPreviewDialog> {
  late final TextEditingController _userCtrl;
  late final TextEditingController _skillsCtrl;
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    _userCtrl = TextEditingController(text: widget.initialUserText);
    _skillsCtrl = TextEditingController(text: widget.initialSkillsText);
  }

  @override
  void dispose() {
    _userCtrl.dispose();
    _skillsCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final isMobile = screenSize.width < 600;
    final effectiveMax = _isMaximized || isMobile;
    final theme = Theme.of(context);
    return Dialog(
      insetPadding: effectiveMax
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      clipBehavior: Clip.antiAlias,
      shape: effectiveMax
          ? const RoundedRectangleBorder()
          : RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: SizedBox(
        width: effectiveMax ? screenSize.width : 720,
        height: effectiveMax ? screenSize.height : screenSize.height * 0.8,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.preview_outlined, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'System Prompt Preview / Edit',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  if (!isMobile)
                    IconButton(
                      icon: Icon(
                        _isMaximized ? Icons.fullscreen_exit : Icons.fullscreen,
                      ),
                      tooltip: _isMaximized ? 'Restore' : 'Maximize',
                      onPressed: () =>
                          setState(() => _isMaximized = !_isMaximized),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _userCtrl,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'System Prompt',
                    alignLabelWithHint: true,
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(
                    Icons.auto_fix_high_outlined,
                    size: 13,
                    color: Colors.grey[500],
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Tool Hints (auto-generated)',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey[500],
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const Spacer(),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _skillsCtrl,
                    builder: (_, val, _) => val.text.isNotEmpty
                        ? InkWell(
                            onTap: () => _skillsCtrl.text = '',
                            borderRadius: BorderRadius.circular(4),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.clear,
                                    size: 13,
                                    color: Colors.grey[500],
                                  ),
                                  const SizedBox(width: 2),
                                  Text(
                                    'Clear',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey[500],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _skillsCtrl,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    fontFamily: 'monospace',
                  ),
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    isDense: true,
                    contentPadding: const EdgeInsets.all(8),
                    hintText: 'No Tool Hints loaded',
                    hintStyle: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    filled: true,
                    fillColor: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.4),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Close'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    icon: const Icon(Icons.check, size: 16),
                    label: const Text('Apply to prompt'),
                    onPressed: () => Navigator.pop(context, (
                      _userCtrl.text,
                      _skillsCtrl.text,
                    )),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Prompt Wizard Dialog
// ═══════════════════════════════════════════════════════════════════
class PromptWizardDialog extends StatefulWidget {
  final String initialText;
  final bool isSystemPrompt;
  final ValueChanged<String> onAccept;
  final WidgetRef taskRef;

  const PromptWizardDialog({
    super.key,
    required this.initialText,
    required this.isSystemPrompt,
    required this.onAccept,
    required this.taskRef,
  });

  @override
  State<PromptWizardDialog> createState() => PromptWizardDialogState();
}

class PromptWizardDialogState extends State<PromptWizardDialog> {
  late final TextEditingController _themaCtrl;
  late final TextEditingController _resultCtrl;
  bool _isGenerating = false;

  @override
  void initState() {
    super.initState();
    _themaCtrl = TextEditingController();
    _resultCtrl = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _themaCtrl.dispose();
    _resultCtrl.dispose();
    super.dispose();
  }

  Future<void> _doGenerate() async {
    final thema = _themaCtrl.text.trim();
    if (thema.isEmpty) return;
    setState(() => _isGenerating = true);
    try {
      final taskState = widget.taskRef.read(activeTaskProvider);
      final chatService = taskState?.chatService;

      String result;
      if (chatService != null && chatService.llmService.isConfigured) {
        final llm = chatService.llmService;
        final promptRole = widget.isSystemPrompt
            ? 'system prompt (persona/role/constraints)'
            : 'task prompt (step-by-step instructions for what to do)';
        final isSlm = llm.isSlm;
        final slmConstraint = isSlm
            ? '- SMALL LANGUAGE MODEL target: keep the output ULTRA-SHORT (max 2 sentences, <60 words). Use compressed, terse language. No filler.\n'
            : '- Max 4 sentences, plain text only\n';
        final metaPrompt =
            'Generate a concise, clear $promptRole for the topic: "$thema".\n'
            'Target LLM: ${llm.currentProvider.name} / ${llm.currentModel}.\n'
            'Rules:\n'
            '- Be specific, actionable, and relevant to the topic\n'
            '- No filler phrases or unnecessary explanations\n'
            '- Output ONLY the role/persona/constraint text. Do NOT include tool instructions, skill descriptions, or "Tool Hints:" blocks.\n'
            '$slmConstraint'
            'Output ONLY the prompt text. No preamble, no quotes.';

        final response = await llm.generateChatCompletion(
          messages: [
            ChatMessage(
              id: const Uuid().v4(),
              role: ChatRole.system,
              content:
                  'You generate high-quality prompts for AI assistants. Output prompt text only.',
              timestamp: DateTime.now(),
            ),
            ChatMessage(
              id: const Uuid().v4(),
              role: ChatRole.user,
              content: metaPrompt,
              timestamp: DateTime.now(),
            ),
          ],
          maxTokens: 150,
        );
        result = response.content.trim();
        if (result.length > 2 &&
            ((result.startsWith('"') && result.endsWith('"')) ||
                (result.startsWith("'") && result.endsWith("'")))) {
          result = result.substring(1, result.length - 1).trim();
        }
      } else {
        result = widget.isSystemPrompt
            ? 'You are a helpful AI assistant specialized in $thema. Provide accurate, concise responses. Use available tools when relevant.'
            : 'Please analyze and process the following task related to $thema. Be thorough but concise in your answer.';
      }

      if (mounted) setState(() => _resultCtrl.text = result);
    } catch (_) {
      // ignore
    } finally {
      if (mounted) setState(() => _isGenerating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screenH = MediaQuery.of(context).size.height;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 32),
      child: SizedBox(
        height: screenH * 0.80,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Title bar
            Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(12),
                ),
              ),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  Icon(
                    Icons.auto_awesome,
                    size: 18,
                    color: AppTheme.primaryBlue,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.isSystemPrompt
                          ? 'System-Prompt Assistent'
                          : 'Aufgaben-Prompt Assistent',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // Body
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Gib ein kurzes Thema ein und klicke auf Generieren für einen KI-generierten '
                      '${widget.isSystemPrompt ? 'System-Prompt' : 'Aufgaben-Prompt'}.',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _themaCtrl,
                      autofocus: true,
                      decoration: InputDecoration(
                        labelText: L.of(context).generatePromptTopicHint,
                        border: const OutlineInputBorder(),
                        isDense: true,
                        suffixIcon: Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: IconButton(
                            onPressed: _isGenerating ? null : _doGenerate,
                            tooltip: L.of(context).generatePrompt,
                            style: IconButton.styleFrom(
                              backgroundColor: AppTheme.primaryBlue,
                              foregroundColor: Colors.white,
                              disabledBackgroundColor: AppTheme.primaryBlue
                                  .withValues(alpha: 0.4),
                              padding: const EdgeInsets.all(8),
                              minimumSize: const Size(36, 36),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            icon: _isGenerating
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(Icons.auto_awesome, size: 20),
                          ),
                        ),
                      ),
                      onSubmitted: (_) => _doGenerate(),
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: TextField(
                        controller: _resultCtrl,
                        decoration: InputDecoration(
                          labelText: widget.isSystemPrompt
                              ? L.of(context).systemPromptTitleLabel
                              : L.of(context).taskPromptTitleLabel,
                          border: const OutlineInputBorder(),
                          alignLabelWithHint: true,
                        ),
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        OutlinedButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: Text(L.of(context).cancel),
                        ),
                        const SizedBox(width: 8),
                        ListenableBuilder(
                          listenable: _resultCtrl,
                          builder: (_, _) => FilledButton.icon(
                            onPressed: _resultCtrl.text.trim().isEmpty
                                ? null
                                : () {
                                    widget.onAccept(_resultCtrl.text);
                                    Navigator.of(context).pop();
                                  },
                            icon: const Icon(Icons.check, size: 18),
                            label: Text(L.of(context).applyLabel),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Schedule picker dialog is defined in lib/widgets/schedule_picker_dialog.dart
// (public SchedulePickerDialog class, supports allowSubHourly parameter)

// ═════════════════════════════════════════════════════════════════════════════
// Google Drive folder-picker dialog
// ═════════════════════════════════════════════════════════════════════════════

class _DriveFolderPickerDialog extends StatefulWidget {
  final String initialPath;
  const _DriveFolderPickerDialog({required this.initialPath});

  @override
  State<_DriveFolderPickerDialog> createState() =>
      _DriveFolderPickerDialogState();
}

class _DriveFolderPickerDialogState extends State<_DriveFolderPickerDialog> {
  late String _currentPath;
  List<String> _folders = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _currentPath = widget.initialPath;
    _loadFolders();
  }

  Future<void> _loadFolders() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    final result = await GoogleDriveMcpServer.listSubfolders(
      _currentPath.isEmpty ? null : _currentPath,
    );
    if (!mounted) return;
    setState(() {
      _isLoading = false;
      if (result['error'] != null) {
        _error = result['error'] as String;
      } else {
        _folders = List<String>.from(result['folders'] as List);
      }
    });
  }

  void _navigateInto(String folderName) {
    setState(() {
      _currentPath = _currentPath.isEmpty
          ? folderName
          : '$_currentPath/$folderName';
      _folders = [];
    });
    _loadFolders();
  }

  void _navigateUp() {
    final parts = _currentPath.split('/')..removeLast();
    setState(() {
      _currentPath = parts.join('/');
      _folders = [];
    });
    _loadFolders();
  }

  @override
  Widget build(BuildContext context) {
    final breadcrumb = _currentPath.isEmpty
        ? 'My Drive'
        : 'My Drive / ${_currentPath.replaceAll('/', ' / ')}';
    return AlertDialog(
      contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      title: Row(
        children: [
          const Icon(Icons.add_to_drive, color: Colors.blue),
          const SizedBox(width: 8),
          Text(
            L.of(context).googleDriveLabel,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ],
      ),
      content: SizedBox(
        width: 360,
        height: 380,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (_currentPath.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.arrow_back, size: 20),
                    onPressed: _navigateUp,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                  ),
                Expanded(
                  child: Text(
                    breadcrumb,
                    style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const Divider(height: 8),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Center(
                      child: Text(
                        _error!,
                        style: const TextStyle(color: Colors.red, fontSize: 13),
                        textAlign: TextAlign.center,
                      ),
                    )
                  : _folders.isEmpty
                  ? Center(
                      child: Text(
                        L.of(context).noSubfoldersLabel,
                        style: TextStyle(color: Colors.grey[500], fontSize: 13),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _folders.length,
                      itemBuilder: (_, i) => ListTile(
                        dense: true,
                        leading: const Icon(
                          Icons.folder,
                          color: Colors.orange,
                          size: 22,
                        ),
                        title: Text(
                          _folders[i],
                          style: const TextStyle(fontSize: 14),
                        ),
                        trailing: const Icon(Icons.chevron_right, size: 18),
                        onTap: () => _navigateInto(_folders[i]),
                      ),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: Text(L.of(context).cancel),
        ),
        FilledButton.icon(
          onPressed: _isLoading
              ? null
              : () => Navigator.pop(context, _currentPath),
          icon: const Icon(Icons.check, size: 18),
          label: Text(
            _currentPath.isEmpty
                ? L.of(context).selectRootLabel
                : L.of(context).selectHereLabel,
          ),
        ),
      ],
    );
  }
}

class _StickyTabBarDelegate extends SliverPersistentHeaderDelegate {
  final Widget child;
  _StickyTabBarDelegate({required this.child});

  @override
  double get minExtent => 56.0;
  @override
  double get maxExtent => 56.0;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      alignment: Alignment.center,
      child: child,
    );
  }

  @override
  bool shouldRebuild(_StickyTabBarDelegate oldDelegate) {
    return oldDelegate.child != child;
  }
}

class TaskNotificationEditor extends StatefulWidget {
  final TaskNotification initialValue;
  final ValueChanged<TaskNotification> onChanged;

  const TaskNotificationEditor({
    super.key,
    required this.initialValue,
    required this.onChanged,
  });

  @override
  State<TaskNotificationEditor> createState() => _TaskNotificationEditorState();
}

class _TaskNotificationEditorState extends State<TaskNotificationEditor> {
  late String _outputType;
  late TextEditingController _emailToCtrl;
  late TextEditingController _emailSubjectCtrl;
  late TextEditingController _emailSendConditionCtrl;
  late TextEditingController _emailConditionExprCtrl;

  late TextEditingController _downloadPathCtrl;
  late TextEditingController _downloadFilePatternCtrl;

  late bool _sftpUseConfiguredSshServer;
  late TextEditingController _sftpHostCtrl;
  late TextEditingController _sftpPortCtrl;
  late TextEditingController _sftpUsernameCtrl;
  late TextEditingController _sftpPasswordCtrl;
  late String _sftpPrivateKeyPem;
  late TextEditingController _sftpRemotePathCtrl;
  late bool _sftpNotifyByEmail;
  late TextEditingController _sftpNotifyEmailAddressCtrl;
  late TextEditingController _sftpNotifyEmailSubjectCtrl;
  late TextEditingController _sftpNotifyEmailBodyCtrl;

  late bool _slackNotifyEnabled;
  late String _slackSendCondition;
  late TextEditingController _slackChannelCtrl;
  late bool _slackWithAttachment;

  late bool _whatsAppNotifyEnabled;
  late String _whatsAppSendCondition;
  late TextEditingController _whatsAppRecipientCtrl;

  late bool _addExecutionLog;
  late bool _zipOutputFiles;

  @override
  void initState() {
    super.initState();
    final n = widget.initialValue;

    _outputType = n.email != null
        ? 'email'
        : (n.sftpOutput != null
              ? 'sftp'
              : (n.download != null ? 'file' : 'none'));

    _emailToCtrl = TextEditingController(
      text: n.email?.recipients.join(', ') ?? '',
    );
    _emailSubjectCtrl = TextEditingController(text: n.email?.subject ?? '');
    _emailSendConditionCtrl = TextEditingController(
      text: n.email?.sendCondition ?? 'always',
    );
    _emailConditionExprCtrl = TextEditingController(
      text: n.email?.conditionExpression ?? '',
    );

    _downloadPathCtrl = TextEditingController(
      text: n.download?.downloadPath ?? '',
    );
    _downloadFilePatternCtrl = TextEditingController(
      text: n.download?.fileNamePattern ?? 'task_result_{date}.txt',
    );

    final sftp = n.sftpOutput;
    _sftpUseConfiguredSshServer = sftp?.useConfiguredSshServer ?? true;
    _sftpHostCtrl = TextEditingController(text: sftp?.host ?? '');
    _sftpPortCtrl = TextEditingController(text: '${sftp?.port ?? 22}');
    _sftpUsernameCtrl = TextEditingController(text: sftp?.username ?? '');
    _sftpPasswordCtrl = TextEditingController(text: sftp?.password ?? '');
    _sftpPrivateKeyPem = sftp?.privateKey ?? '';
    _sftpRemotePathCtrl = TextEditingController(text: sftp?.remotePath ?? '/');
    _sftpNotifyByEmail = sftp?.notifyByEmail ?? false;
    _sftpNotifyEmailAddressCtrl = TextEditingController(
      text: sftp?.notifyEmailAddress ?? '',
    );
    _sftpNotifyEmailSubjectCtrl = TextEditingController(
      text: sftp?.notifyEmailSubject ?? '',
    );
    _sftpNotifyEmailBodyCtrl = TextEditingController(
      text: sftp?.notifyEmailBody ?? '',
    );

    _slackNotifyEnabled = n.slack != null;
    _slackSendCondition = n.slack?.sendCondition ?? 'always';
    _slackWithAttachment = n.slack?.withAttachment ?? false;
    _slackChannelCtrl = TextEditingController(
      text: n.slack?.overrideChannel ?? '',
    );

    _whatsAppNotifyEnabled = n.whatsApp != null;
    _whatsAppSendCondition = n.whatsApp?.sendCondition ?? 'always';
    _whatsAppRecipientCtrl = TextEditingController(
      text: n.whatsApp?.overrideRecipient ?? '',
    );

    _addExecutionLog = n.addExecutionLog;
    _zipOutputFiles = n.zipOutputFiles;
  }

  @override
  void dispose() {
    _emailToCtrl.dispose();
    _emailSubjectCtrl.dispose();
    _emailSendConditionCtrl.dispose();
    _emailConditionExprCtrl.dispose();
    _downloadPathCtrl.dispose();
    _downloadFilePatternCtrl.dispose();
    _sftpHostCtrl.dispose();
    _sftpPortCtrl.dispose();
    _sftpUsernameCtrl.dispose();
    _sftpPasswordCtrl.dispose();
    _sftpNotifyEmailAddressCtrl.dispose();
    _sftpNotifyEmailSubjectCtrl.dispose();
    _sftpNotifyEmailBodyCtrl.dispose();
    _slackChannelCtrl.dispose();
    _whatsAppRecipientCtrl.dispose();
    super.dispose();
  }

  void _notifyChanged() {
    widget.onChanged(
      TaskNotification(
        email: _outputType == 'email' && _emailToCtrl.text.isNotEmpty
            ? EmailNotification(
                recipients: _emailToCtrl.text
                    .split(',')
                    .map((s) => s.trim())
                    .where((s) => s.isNotEmpty)
                    .toList(),
                subject: _emailSubjectCtrl.text.isNotEmpty
                    ? _emailSubjectCtrl.text.trim()
                    : null,
                withAttachment: true,
                sendCondition: _emailSendConditionCtrl.text.isNotEmpty
                    ? _emailSendConditionCtrl.text.trim()
                    : 'always',
                conditionExpression:
                    _emailConditionExprCtrl.text.trim().isNotEmpty
                    ? _emailConditionExprCtrl.text.trim()
                    : null,
              )
            : null,
        download: _outputType == 'file'
            ? DownloadNotification(
                downloadPath: _downloadPathCtrl.text.trim().isEmpty
                    ? null
                    : _downloadPathCtrl.text.trim(),
                fileNamePattern: _downloadFilePatternCtrl.text.trim().isEmpty
                    ? null
                    : _downloadFilePatternCtrl.text.trim(),
              )
            : null,
        sftpOutput: _outputType == 'sftp'
            ? SftpOutputConfig(
                useConfiguredSshServer: _sftpUseConfiguredSshServer,
                host: _sftpHostCtrl.text.trim(),
                port: int.tryParse(_sftpPortCtrl.text.trim()) ?? 22,
                username: _sftpUsernameCtrl.text.trim(),
                password: _sftpPasswordCtrl.text.isNotEmpty
                    ? _sftpPasswordCtrl.text
                    : null,
                privateKey: _sftpPrivateKeyPem.isNotEmpty
                    ? _sftpPrivateKeyPem
                    : null,
                remotePath: _sftpRemotePathCtrl.text.trim().isEmpty
                    ? '/'
                    : _sftpRemotePathCtrl.text.trim(),
                notifyByEmail: _sftpNotifyByEmail,
                notifyEmailAddress: _sftpNotifyEmailAddressCtrl.text.trim(),
                notifyEmailSubject: _sftpNotifyEmailSubjectCtrl.text.trim(),
                notifyEmailBody: _sftpNotifyEmailBodyCtrl.text.trim(),
              )
            : null,
        push: null,
        slack: _slackNotifyEnabled
            ? SlackNotification(
                sendCondition: _slackSendCondition,
                overrideChannel: _slackChannelCtrl.text.trim().isNotEmpty
                    ? _slackChannelCtrl.text.trim()
                    : null,
                withAttachment: _slackWithAttachment,
              )
            : null,
        whatsApp: _whatsAppNotifyEnabled
            ? WhatsAppNotification(
                sendCondition: _whatsAppSendCondition,
                overrideRecipient: _whatsAppRecipientCtrl.text.trim().isNotEmpty
                    ? _whatsAppRecipientCtrl.text.trim()
                    : null,
              )
            : null,
        addExecutionLog: _addExecutionLog,
        zipOutputFiles: _zipOutputFiles,
      ),
    );
  }

  Future<void> _pickOutputDirectory() async {
    final selected = await FilePicker.getDirectoryPath(
      dialogTitle: 'Choose directory',
    );
    if (!mounted || selected == null || selected.isEmpty) return;
    setState(() {
      _downloadPathCtrl.text = selected;
    });
    _notifyChanged();
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle(l.outputType),
        DropdownButtonFormField<String>(
          initialValue: _outputType,
          decoration: InputDecoration(labelText: l.outputType),
          items: const [
            DropdownMenuItem(value: 'none', child: Text('None (No output)')),
            DropdownMenuItem(value: 'email', child: Text('Email notification')),
            DropdownMenuItem(
              value: 'file',
              child: Text('Save to local folder'),
            ),
            DropdownMenuItem(
              value: 'sftp',
              child: Text('Upload to SFTP server'),
            ),
          ],
          onChanged: (value) {
            if (value == null) return;
            setState(() {
              _outputType = value;
            });
            _notifyChanged();
          },
        ),
        if (_outputType == 'email') ...[
          const SizedBox(height: 16),
          _sectionTitle(l.emailNotification),
          const SizedBox(height: 8),
          TextFormField(
            controller: _emailToCtrl,
            decoration: InputDecoration(
              labelText: l.toEmail,
              hintText: l.toEmailHint,
            ),
            keyboardType: TextInputType.emailAddress,
            onChanged: (_) => _notifyChanged(),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _emailSubjectCtrl,
            decoration: InputDecoration(
              labelText: l.subject,
              hintText: l.subjectHint,
            ),
            onChanged: (_) => _notifyChanged(),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _emailSendConditionCtrl.text,
            decoration: InputDecoration(labelText: l.sendCondition),
            items: [
              DropdownMenuItem(value: 'always', child: Text(l.always)),
              DropdownMenuItem(value: 'on_success', child: Text(l.onSuccess)),
              DropdownMenuItem(value: 'on_failure', child: Text(l.onFailure)),
              DropdownMenuItem(
                value: 'on_change',
                child: Text(l.onResultChange),
              ),
              const DropdownMenuItem(
                value: 'conditional',
                child: Text('Conditional (LLM)'),
              ),
            ],
            onChanged: (val) {
              if (val != null) {
                setState(() {
                  _emailSendConditionCtrl.text = val;
                });
                _notifyChanged();
              }
            },
          ),
          if (_emailSendConditionCtrl.text == 'conditional') ...[
            const SizedBox(height: 12),
            TextFormField(
              controller: _emailConditionExprCtrl,
              decoration: const InputDecoration(
                labelText: 'Condition Expression',
                hintText: 'e.g. output is TRUE or temperature > 10',
              ),
              onChanged: (_) => _notifyChanged(),
            ),
          ],
        ],
        if (_outputType == 'file') ...[
          const SizedBox(height: 16),
          _sectionTitle(l.outputDirectory),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _downloadPathCtrl,
                  decoration: InputDecoration(
                    labelText: l.outputDirectory,
                    hintText: l.outputDirectoryHint,
                  ),
                  onChanged: (_) => _notifyChanged(),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _pickOutputDirectory,
                child: const Text('Pick'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _downloadFilePatternCtrl,
            decoration: const InputDecoration(labelText: 'File Name Pattern'),
            onChanged: (_) => _notifyChanged(),
          ),
        ],
        if (_outputType == 'sftp') ...[
          const SizedBox(height: 16),
          _sectionTitle('SFTP Output Config'),
          SwitchListTile(
            title: const Text('Use global SSH/SFTP server credentials'),
            value: _sftpUseConfiguredSshServer,
            onChanged: (val) {
              setState(() {
                _sftpUseConfiguredSshServer = val;
              });
              _notifyChanged();
            },
          ),
          if (!_sftpUseConfiguredSshServer) ...[
            const SizedBox(height: 8),
            TextFormField(
              controller: _sftpHostCtrl,
              decoration: const InputDecoration(labelText: 'SFTP Host'),
              onChanged: (_) => _notifyChanged(),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _sftpPortCtrl,
              decoration: const InputDecoration(labelText: 'SFTP Port'),
              keyboardType: TextInputType.number,
              onChanged: (_) => _notifyChanged(),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _sftpUsernameCtrl,
              decoration: const InputDecoration(labelText: 'SFTP Username'),
              onChanged: (_) => _notifyChanged(),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _sftpPasswordCtrl,
              decoration: const InputDecoration(labelText: 'SFTP Password'),
              obscureText: true,
              onChanged: (_) => _notifyChanged(),
            ),
          ],
          const SizedBox(height: 8),
          TextFormField(
            controller: _sftpRemotePathCtrl,
            decoration: const InputDecoration(labelText: 'SFTP Remote Path'),
            onChanged: (_) => _notifyChanged(),
          ),
        ],
        const Divider(height: 32),
        _sectionTitle('Additional Channels & Settings'),
        SwitchListTile(
          title: const Text('Notify via Slack'),
          value: _slackNotifyEnabled,
          onChanged: (val) {
            setState(() {
              _slackNotifyEnabled = val;
            });
            _notifyChanged();
          },
        ),
        if (_slackNotifyEnabled) ...[
          Padding(
            padding: const EdgeInsets.only(left: 16.0),
            child: Column(
              children: [
                TextFormField(
                  controller: _slackChannelCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Override Slack Channel (e.g. #general)',
                  ),
                  onChanged: (_) => _notifyChanged(),
                ),
                SwitchListTile(
                  title: const Text('Attach execution log files'),
                  value: _slackWithAttachment,
                  onChanged: (val) {
                    setState(() {
                      _slackWithAttachment = val;
                    });
                    _notifyChanged();
                  },
                ),
              ],
            ),
          ),
        ],
        SwitchListTile(
          title: const Text('Notify via WhatsApp'),
          value: _whatsAppNotifyEnabled,
          onChanged: (val) {
            setState(() {
              _whatsAppNotifyEnabled = val;
            });
            _notifyChanged();
          },
        ),
        if (_whatsAppNotifyEnabled) ...[
          Padding(
            padding: const EdgeInsets.only(left: 16.0),
            child: TextFormField(
              controller: _whatsAppRecipientCtrl,
              decoration: const InputDecoration(
                labelText: 'Override WhatsApp Recipient (e.g. 43664...)',
              ),
              onChanged: (_) => _notifyChanged(),
            ),
          ),
        ],
        const SizedBox(height: 12),
        SwitchListTile(
          title: Text(l.addExecutionLogToOutput),
          value: _addExecutionLog,
          onChanged: (val) {
            setState(() {
              _addExecutionLog = val;
            });
            _notifyChanged();
          },
        ),
        SwitchListTile(
          title: Text(l.zipOutputFiles),
          value: _zipOutputFiles,
          onChanged: (val) {
            setState(() {
              _zipOutputFiles = val;
            });
            _notifyChanged();
          },
        ),
      ],
    );
  }
}

class _PromptTestDialog extends ConsumerStatefulWidget {
  final WorkflowTask task;
  final TaskLlmOverrides overrides;

  const _PromptTestDialog({
    required this.task,
    required this.overrides,
  });

  @override
  ConsumerState<_PromptTestDialog> createState() => _PromptTestDialogState();
}

class _PromptTestDialogState extends ConsumerState<_PromptTestDialog> {
  final List<ChatMessage> _messages = [];
  StreamSubscription<List<ChatMessage>>? _messagesSub;
  StreamSubscription<String>? _errorSub;
  bool _running = false;
  bool _done = false;
  String _status = 'Initializing test session...';
  String? _initError;
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _startTest();
    });
  }

  @override
  void dispose() {
    _messagesSub?.cancel();
    _errorSub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _startTest() async {
    setState(() {
      _running = true;
      _status = 'Configuring test runner and tools...';
    });

    final activeNotifier = ref.read(activeTaskProvider.notifier);
    activeNotifier.clearTask();

    // Start loading the task
    try {
      await activeNotifier.setTask(widget.task, overrides: widget.overrides);
      final activeState = ref.read(activeTaskProvider);
      
      if (activeState == null) {
        throw StateError('Could not initialize active task state.');
      }

      if (activeState.hasError) {
        throw StateError(activeState.error!);
      }

      // Check if LLM is actually configured
      if (activeState.llmService == null || !activeState.llmService!.isConfigured) {
        throw StateError('No LLM configured. Please check your settings or overrides.');
      }

      // Once the provider is ready, subscribe to ChatService
      final chatService = activeState.chatService;
      if (chatService == null) {
        throw StateError('ChatService is not initialized.');
      }

      // Subscribe to messages stream
      _messagesSub = chatService.messagesStream.listen((msgs) {
        if (mounted) {
          setState(() {
            _messages.clear();
            _messages.addAll(msgs);
          });
          _scrollToBottom();
        }
      });

      // Subscribe to errors stream
      _errorSub = chatService.errorNotificationStream.listen((err) {
        if (mounted) {
          setState(() {
            _done = true;
            _running = false;
            _status = 'Error during prompt execution: $err';
          });
        }
      });

      // Auto-start prompt sequence
      setState(() {
        _status = 'Running prompt steps...';
      });
      await chatService.sendChatMessage(ChatMessage(
        id: const Uuid().v4(),
        content: widget.task.prompt,
        role: ChatRole.user,
        timestamp: DateTime.now(),
      ));

      setState(() {
        _done = true;
        _running = false;
        _status = 'Prompt sequence completed successfully.';
      });

    } catch (e) {
      if (mounted) {
        setState(() {
          _done = true;
          _running = false;
          _initError = e.toString();
          _status = 'Initialization failed: $e';
        });
      }
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Widget _buildContent(BuildContext context, bool isDark) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Row(
            children: [
              Icon(Icons.play_circle_outline, color: theme.colorScheme.primary, size: 24),
              const SizedBox(width: 8),
              Text(
                'Prompt Execution Test',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              if (_running)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (_done)
                const Icon(Icons.check_circle, color: Colors.green, size: 18),
            ],
          ),
        ),
        const Divider(height: 1),
        
        // Status bar
        Container(
          color: isDark ? Colors.grey[900] : Colors.grey[100],
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            _status,
            style: TextStyle(
              fontSize: 12,
              fontStyle: FontStyle.italic,
              color: _initError != null ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const Divider(height: 1),

        // Message output log
        Expanded(
          child: _messages.isEmpty && _initError == null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      Text(
                        'Initializing agent runtime...',
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: _messages.length,
                  itemBuilder: (_, i) => _buildMessageTile(_messages[i], isDark),
                ),
        ),
        const Divider(height: 1),

        // Footer
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () {
                  ref.read(activeTaskProvider.notifier).clearTask();
                  Navigator.of(context).pop();
                },
                child: const Text('Close'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMessageTile(ChatMessage msg, bool isDark) {
    final (IconData icon, Color color) = switch (msg.role) {
      ChatRole.user => (Icons.person_outline, Colors.blue),
      ChatRole.assistant => (Icons.smart_toy_outlined, Colors.green),
      ChatRole.system => (Icons.lock_outline, Colors.purple),
      ChatRole.tool => (Icons.build_outlined, Colors.orange),
    };

    final contentText = msg.content;
    
    // Nice style container for each message/log entry
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withValues(alpha: 0.03) : Colors.black.withValues(alpha: 0.02),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDark ? Colors.white.withValues(alpha: 0.06) : Colors.black.withValues(alpha: 0.05),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  msg.role.name.toUpperCase(),
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  contentText,
                  style: TextStyle(
                    fontSize: 13,
                    fontFamily: msg.role == ChatRole.tool ? 'monospace' : null,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isMobile = MediaQuery.of(context).size.width < 600;

    if (isMobile) {
      return Dialog.fullscreen(
        child: SafeArea(child: _buildContent(context, isDark)),
      );
    }

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 680,
          maxHeight: MediaQuery.of(context).size.height * 0.82,
        ),
        child: _buildContent(context, isDark),
      ),
    );
  }
}
