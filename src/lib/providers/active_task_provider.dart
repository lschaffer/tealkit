import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../mcp/internal_mcp_client_adapter.dart';
import '../mcp/internal_mcp_registry.dart';
import '../models/workflow_task.dart';
import '../models/step_types.dart';
import '../services/app_logger.dart';
import '../services/chat_service.dart';
import '../services/data_sources_settings_service.dart';
import '../services/external_tools_settings_service.dart';
import '../services/llm_settings_service.dart';
import '../services/llm_service.dart';
import '../services/location_service.dart';
import '../services/embedded_llm/embedded_model_manager.dart';
import '../services/mcp_client.dart';
import '../services/multi_mcp_manager.dart';
import '../services/server_api_client.dart';
import '../services/server_mcp_proxy_client.dart';
import '../services/function_hint_database_service.dart';
import 'llm_settings_provider.dart';
import 'server_mode_provider.dart';

// ═══════════════════════════════════════════════════════════
// STATE
// ═══════════════════════════════════════════════════════════

/// Represents the full state of the currently active task including
/// all services needed for the interactive chat view.
class ActiveTaskState {
  /// The task being tested/chatted with.
  final WorkflowTask task;

  /// Current initialization phase.
  final ActiveTaskPhase phase;

  /// Human-readable status message.
  final String statusMessage;

  /// Error message if initialization failed.
  final String? error;

  /// Number of MCP tools discovered.
  final int toolCount;

  /// The MCP manager holding both external and internal MCP clients.
  final MultiMCPManager? mcpManager;

  /// The chat service wired to the MCP manager + LLM.
  final ChatService? chatService;

  /// The LLM service configured for this task.
  final LLMService? llmService;

  /// The effective system prompt (task + internal MCP prompts merged).
  final String? effectiveSystemPrompt;

  /// Loading progress (0.0–1.0) while an embedded model is being loaded into memory.
  final double? loadingProgress;

  const ActiveTaskState({
    required this.task,
    this.phase = ActiveTaskPhase.idle,
    this.statusMessage = '',
    this.error,
    this.toolCount = 0,
    this.mcpManager,
    this.chatService,
    this.llmService,
    this.effectiveSystemPrompt,
    this.loadingProgress,
  });

  bool get isInitializing =>
      phase == ActiveTaskPhase.configuringLlm ||
      phase == ActiveTaskPhase.connectingExternalMcp ||
      phase == ActiveTaskPhase.connectingInternalMcp;

  bool get isReady => phase == ActiveTaskPhase.ready;
  bool get hasError => error != null;

  ActiveTaskState copyWith({
    WorkflowTask? task,
    ActiveTaskPhase? phase,
    String? statusMessage,
    String? error,
    int? toolCount,
    MultiMCPManager? mcpManager,
    ChatService? chatService,
    LLMService? llmService,
    String? effectiveSystemPrompt,
    double? loadingProgress,
    bool clearLoadingProgress = false,
  }) {
    return ActiveTaskState(
      task: task ?? this.task,
      phase: phase ?? this.phase,
      statusMessage: statusMessage ?? this.statusMessage,
      error: error,
      toolCount: toolCount ?? this.toolCount,
      mcpManager: mcpManager ?? this.mcpManager,
      chatService: chatService ?? this.chatService,
      llmService: llmService ?? this.llmService,
      effectiveSystemPrompt:
          effectiveSystemPrompt ?? this.effectiveSystemPrompt,
      loadingProgress: clearLoadingProgress
          ? null
          : (loadingProgress ?? this.loadingProgress),
    );
  }
}

enum ActiveTaskPhase {
  idle,
  configuringLlm,
  connectingExternalMcp,
  connectingInternalMcp,
  ready,
  error,
}

// ═══════════════════════════════════════════════════════════
// LLM OVERRIDES (passed from the task editor, may differ from saved task)
// ═══════════════════════════════════════════════════════════

class TaskLlmOverrides {
  final String? llmProvider;
  final String? llmModel;
  final String? llmApiKey;
  final String? llmBaseUrl;
  final double? temperature;
  final int? maxTokens;
  final int? maxToolOutputSize;
  final int? tokenWarningThreshold;
  final String? systemPrompt;
  final bool? isMultiModal;

  const TaskLlmOverrides({
    this.llmProvider,
    this.llmModel,
    this.llmApiKey,
    this.llmBaseUrl,
    this.temperature,
    this.maxTokens,
    this.maxToolOutputSize,
    this.tokenWarningThreshold,
    this.systemPrompt,
    this.isMultiModal,
  });
}

// ═══════════════════════════════════════════════════════════
// PROVIDER (keepAlive = true)
// ═══════════════════════════════════════════════════════════

final activeTaskProvider =
    NotifierProvider<ActiveTaskNotifier, ActiveTaskState?>(
      ActiveTaskNotifier.new,
    );

class ActiveTaskNotifier extends Notifier<ActiveTaskState?> {
  static const String _formatInstruction =
      'Output formatting: If the user requests a specific format, you can format the response accordingly '
      '(e.g., Markdown, HTML, JSON, CSV, plain text, table). '
      'Default to concise plain text when no specific format is requested.';

  /// Overrides passed from the task editor (not yet persisted).
  TaskLlmOverrides? _overrides;

  @override
  ActiveTaskState? build() {
    // keepAlive: Riverpod NotifierProvider is kept alive by default
    // when used with NotifierProvider (not autoDispose).
    ref.keepAlive();
    return null; // No active task initially
  }

  // ─── Public API ───────────────────────────────────────

  /// Set a new active task and start initialization.
  ///
  /// Call this when the user selects a task or presses "Interactive Mode"
  /// in the task editor.
  Future<void> setTask(WorkflowTask task, {TaskLlmOverrides? overrides}) async {
    // Dispose previous state if any
    _disposeCurrentState();

    _overrides = overrides;

    state = ActiveTaskState(
      task: task,
      phase: ActiveTaskPhase.configuringLlm,
      statusMessage: 'Configuring LLM…',
    );

    await _initialize(task);
  }

  /// Clear the active task and dispose all services.
  void clearTask() {
    _disposeCurrentState();
    state = null;
  }

  // ─── Initialization pipeline ──────────────────────────

  Future<void> _initialize(WorkflowTask task) async {
    final llmService = LLMService();
    final locationService = LocationService();
    final mcpManager = MultiMCPManager();

    try {
      // 1. Configure LLM
      state = state!.copyWith(
        phase: ActiveTaskPhase.configuringLlm,
        statusMessage: 'Configuring LLM…',
        clearLoadingProgress: true,
      );
      await _configureLlm(llmService, task);

      if (!llmService.isConfigured) {
        state = state!.copyWith(
          phase: ActiveTaskPhase.error,
          error:
              'No LLM configured. Please set up an LLM provider in Settings or in the task LLM override.',
          mcpManager: mcpManager,
          llmService: llmService,
        );
        return;
      }

      // Bridge the user-configured SLM checkbox from LlmSettingsService into the
      // fresh LLMService instance as a fallback.
      // Primary SLM detection is model-name based (≤14B params → isSlm=true) or
      // embedded provider — both handled by LLMService.isSlm after _configureLlm.
      // The user checkbox (LlmSettingsService.isSlm, secure-storage 'llm_is_slm')
      // is an additional override for edge cases where name-detection doesn't fire.
      {
        final settings = ref.read(llmSettingsProvider);
        final originalProvider =
            (_overrides?.llmProvider ?? task.llmConfig?.provider ?? '')
                .toLowerCase();
        final usingLlm2 = originalProvider == 'llm2';
        final settingsSlm = usingLlm2 ? settings.isSlm2 : settings.isSlm;
        if (settingsSlm && !llmService.useSimplifiedPrompts) {
          llmService.setUseSimplifiedPrompts(true);
        }
        log.info(
          '[ActiveTask] SLM detection: isSlm=${llmService.isSlm}'
          ' useSimplifiedPrompts=${llmService.useSimplifiedPrompts}'
          ' settingsCheckbox=$settingsSlm usingLlm2=$usingLlm2',
        );
      }

      // Chat mode: bypass system prompt and MCP tools entirely.
      if (task.chatMode) {
        final chatService = ChatService(
          mcpClient: mcpManager,
          llmService: llmService,
          locationService: locationService,
          getPluginPrompts: () => ProjectPrompts(systemPrompt: ''),
          chatMode: true,
          getTask: () => state?.task ?? task,
        );
        state = state!.copyWith(
          chatService: chatService,
          llmService: llmService,
          mcpManager: mcpManager,
          effectiveSystemPrompt: '',
          phase: ActiveTaskPhase.ready,
          statusMessage: 'Ready — chat mode (no tools)',
          toolCount: 0,
        );
        log.info('[ActiveTask] Chat mode — no system prompt, no tools');
        return;
      }

      // 2. Build effective system prompt.
      // Keep this intentionally compact: task-level prompt (editable) + one
      // concise toolbox guidance line. Avoid appending all MCP prompts because
      // stacked persona text can conflict and confuse tool selection.
      final isCompact = llmService.useSimplifiedPrompts || llmService.isSlm;
      var effectiveSystemPrompt =
          (_overrides?.systemPrompt ?? task.systemPrompt ?? '').trim();

      // Toolbox is considered enabled unless there is an explicit disabled entry.
      // (Older tasks and playground tasks that didn't select toolbox have no entry
      //  at all — treat those as implicitly enabled for backward compatibility.)
      final toolboxDisabled = task.internalMcps.any(
        (m) => m.mcpType == 'toolbox' && !m.enabled,
      );

      // Skip verbose toolbox guidance and format instruction for compact/SLM models
      // — they add significant token overhead that hurts small models.
      // Also skip when the user has explicitly deselected the toolbox.
      if (!isCompact && !toolboxDisabled) {
        final toolboxPrompt = InternalMcpRegistry()
            .create('toolbox')
            ?.defaultSystemPrompt
            .trim();
        if (toolboxPrompt != null && toolboxPrompt.isNotEmpty) {
          final base = effectiveSystemPrompt.trim();
          effectiveSystemPrompt = base.isEmpty
              ? toolboxPrompt
              : '$base\n\n$toolboxPrompt';
        }
        effectiveSystemPrompt = _withFormatInstruction(effectiveSystemPrompt);
      } else if (!isCompact && toolboxDisabled) {
        // Still apply format instruction even without toolbox prompt.
        effectiveSystemPrompt = _withFormatInstruction(effectiveSystemPrompt);
      }
      effectiveSystemPrompt = _stripGeneratedCapabilitiesBlock(
        effectiveSystemPrompt,
      );
      // Strip any existing Tool Hints section — it will be re-injected below
      // with the correct per-step filter, preventing double-injection when the
      // task's saved systemPrompt already contains a skills block from the editor.
      effectiveSystemPrompt = _stripToolSkillsSection(effectiveSystemPrompt);

      // Compute the union of per-step enabled tool names from the task prompt.
      // stepToolFilter == null → no restriction (every step allows all tools).
      // stepToolFilter != null → only tools that appear in at least one
      //   explicitly-restricted step are included.
      Set<String>? stepToolFilter;
      {
        final steps = parseWorkflowSteps(task.prompt);
        if (steps.any((s) => s.enabledToolNames != null)) {
          final union = <String>{};
          for (final s in steps) {
            if (s.enabledToolNames == null) {
              continue; // all-tools step → no restriction added
            }
            union.addAll(s.enabledToolNames!);
          }
          stepToolFilter = union;
        }
      }

      final capabilityHints = <String>[];
      var hasWebSearchCapability = false;
      for (final entry in task.internalMcps) {
        if (!entry.enabled) continue;
        switch (entry.mcpType) {
          case 'gmail':
            capabilityHints.add(
              isCompact
                  ? 'Email: search_gmail(q, includeBody:true), get_gmail_message.'
                  : 'Email: use search_gmail (q: Gmail query syntax, includeBody: true to get full text for summarization) '
                        'and get_gmail_message for a single message. '
                        'Supports: from:, to:, subject:, after:YYYY/MM/DD, before:YYYY/MM/DD, newer_than:Nd, has:attachment, keyword search.',
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
                  : 'File output: use create_text_file to create .txt/.md/.html files from source content.',
            );
          case 'google_calendar':
            capabilityHints.add(
              isCompact
                  ? 'Calendar: list_calendars, list_events, create_event, update_event, delete_event. Times: ISO 8601 with TZ.'
                  : 'Google Calendar: use list_calendars to see calendars, '
                        'list_events (calendarId, timeMin, timeMax, q) to fetch events, '
                        'create_event (summary, start, end) to add events, '
                        'update_event to modify, delete_event to remove. '
                        'Times must be ISO 8601 with timezone (e.g. 2026-02-24T10:00:00+01:00).',
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
            hasWebSearchCapability = true;
            capabilityHints.add(
              isCompact
                  ? 'Websites: search_indexed_websites, get_indexed_page. Link every URL.'
                  : 'Indexed websites: use search_indexed_websites and get_indexed_page. '
                        'Always format every result URL as a Markdown link [Page Title](https://...) '
                        'so the user can tap it directly — never output a bare URL string.',
            );
          case 'web_search':
            hasWebSearchCapability = true;
            capabilityHints.add(
              isCompact
                  ? 'Web: web_search for current info. Include full URL per result.'
                  : 'Public web: use web_search for current/public information. '
                        'When returning results, always include the full URL (https://...) for each item.',
            );
          case 'weather':
            capabilityHints.add(
              isCompact
                  ? 'Weather: use weather tools.'
                  : 'Weather: use weather tools for forecasts and conditions.',
            );
          case 'imap':
            capabilityHints.add(
              isCompact
                  ? 'IMAP: search_emails(from, to, subject, since/before YYYY-MM-DD), read_email(uid, folder).'
                  : 'IMAP email: use search_emails (params: from, to, subject, body, since/before YYYY-MM-DD, unseen bool, folder default INBOX, maxResults) '
                        'to find emails, then read_email (uid, folder) to get the full body. '
                        'Use list_folders to see available mailboxes. '
                        'Use the CURRENT DATE/TIME already provided in the system context to compute since/before date filter values.',
            );
          case 'chart':
            capabilityHints.add(
              isCompact
                  ? 'Charts: create_chart_png (line, bar, area, pie, scatter, histogram, statistics_summary).'
                  : 'Charts: use create_chart_png to build PNG charts. '
                        'Supported chartTypes: line, bar, area, pie, scatter, histogram, statistics_summary. '
                        'Provide xAxis labels, series data, optional title, xAxisTitle, yAxisTitle. '
                        'Use statistics_summary for a 4-panel dashboard.',
            );
        }
      }

      if (hasWebSearchCapability) {
        capabilityHints.add(
          isCompact
              ? 'No generic link placeholders. Always show title + URL.'
              : 'Never output generic placeholders like "Link". Show readable title plus absolute URL.',
        );
      }

      if (capabilityHints.isNotEmpty) {
        final base = effectiveSystemPrompt.trim();
        final hintsBlock =
            'Enabled capabilities:\n- ${capabilityHints.join('\n- ')}';
        effectiveSystemPrompt = base.isEmpty
            ? hintsBlock
            : '$base\n\n$hintsBlock';
      }

      // ── Inject Tool Hints for tools enabled in this task ─────────────
      // For compact/SLM: only inject mini skills when the user has written a
      // substantive custom system prompt (multi-line or >50 chars) — signals
      // they actually care about tool guidance. Plain playground / empty prompt
      // gets no skills at all.
      final userPromptText =
          (_overrides?.systemPrompt ?? task.systemPrompt ?? '').trim();
      final hasSubstantialUserPrompt =
          userPromptText.contains('\n') || userPromptText.length > 50;
      final shouldInjectSkills = !isCompact || hasSubstantialUserPrompt;
      if (shouldInjectSkills) {
        try {
          // Gather tool names from explicitly enabled MCPs.
          final allTaskMcpToolNames = task.internalMcps
              .where((e) => e.enabled)
              .expand((e) {
                final server = InternalMcpRegistry().create(e.mcpType);
                return server?.tools.map((t) => t.name) ?? <String>[];
              })
              .toList();
          // Also include toolbox tools unless toolbox was explicitly disabled.
          if (!toolboxDisabled) {
            final toolboxServer = InternalMcpRegistry().create('toolbox');
            if (toolboxServer != null) {
              allTaskMcpToolNames.addAll(
                toolboxServer.tools.map((t) => t.name),
              );
            }
          }
          // Apply per-step filter: only inject skills for tools that appear in
          // at least one step's explicit tool selection.
          final taskMcpToolNames = stepToolFilter != null
              ? allTaskMcpToolNames
                    .where((n) => stepToolFilter!.contains(n))
                    .toList()
              : allTaskMcpToolNames;
          if (taskMcpToolNames.isNotEmpty) {
            final skills = await FunctionHintDatabaseService().getEnabledForTools(
              taskMcpToolNames,
            );
            if (skills.isNotEmpty) {
              // For compact models always use the short SLM text.
              final useSlmText =
                  isCompact ||
                  llmService.useSimplifiedPrompts ||
                  llmService.isSlm;
              final skillLines = skills
                  .map((s) {
                    final text = useSlmText ? s.skillTextSlm : s.skillText;
                    return '• ${s.toolName}: $text';
                  })
                  .join('\n');
              final base = effectiveSystemPrompt.trim();
              effectiveSystemPrompt = base.isEmpty
                  ? 'Tool Hints:\n$skillLines'
                  : '$base\n\nTool Hints:\n$skillLines';
            }
          }
        } catch (e) {
          log.warning(
            '[ActiveTask] Failed to inject Tool Hints (non-fatal): $e',
          );
        }
      }

      // 3. Create ChatService (before MCP connects so listeners are ready)
      // NOTE: getPluginPrompts reads from `state?.effectiveSystemPrompt` dynamically
      // so that skill injections that happen post-connect (step 4b) are picked up
      // without recreating the ChatService.
      final chatService = ChatService(
        mcpClient: mcpManager,
        llmService: llmService,
        locationService: locationService,
        getPluginPrompts: () =>
            ProjectPrompts(systemPrompt: state?.effectiveSystemPrompt ?? ''),
        stopAfterToolCall: task.stopAfterToolCall,
        getTask: () => state?.task ?? task,
      );

      state = state!.copyWith(
        chatService: chatService,
        llmService: llmService,
        mcpManager: mcpManager,
        effectiveSystemPrompt: effectiveSystemPrompt,
      );

      // 4. Connect external MCP servers
      state = state!.copyWith(
        phase: ActiveTaskPhase.connectingExternalMcp,
        statusMessage: 'Connecting external MCP servers…',
      );
      await _connectExternalMcps(mcpManager, task);

      // 4b. Inject skills for just-connected external MCP tools.
      // External MCPs connect AFTER the system prompt is first built, so their
      // Tool Hints must be appended here once the clients are live.
      if (shouldInjectSkills) {
        try {
          final allExtToolNames = mcpManager.clients
              .expand((c) => c.availableTools.map((t) => t.name))
              .toList();
          // Apply the same per-step filter used for internal MCP skills.
          final extToolNames = stepToolFilter != null
              ? allExtToolNames
                    .where((n) => stepToolFilter!.contains(n))
                    .toList()
              : allExtToolNames;
          if (extToolNames.isNotEmpty) {
            final useSlmText =
                isCompact ||
                llmService.useSimplifiedPrompts ||
                llmService.isSlm;
            final extSkills = await FunctionHintDatabaseService().getEnabledForTools(
              extToolNames,
            );
            if (extSkills.isNotEmpty) {
              final newLines = extSkills
                  .where(
                    (s) => (useSlmText ? s.skillTextSlm : s.skillText)
                        .trim()
                        .isNotEmpty,
                  )
                  .map((s) {
                    final text = useSlmText ? s.skillTextSlm : s.skillText;
                    return '• ${s.toolName}: $text';
                  })
                  .join('\n');
              if (newLines.isNotEmpty) {
                final cur = (state?.effectiveSystemPrompt ?? '').trim();
                final updated = cur.contains('Tool Hints:')
                    ? '$cur\n$newLines'
                    : '$cur\n\nTool Hints:\n$newLines';
                state = state!.copyWith(effectiveSystemPrompt: updated);
              }
            }
          }
        } catch (e) {
          log.warning(
            '[ActiveTask] Failed to inject external Tool Hints (non-fatal): $e',
          );
        }
      }

      // 5. Connect internal MCP servers (with timeout so UI never hangs)
      state = state!.copyWith(
        phase: ActiveTaskPhase.connectingInternalMcp,
        statusMessage: 'Initializing built-in tools…',
      );
      await _connectInternalMcps(mcpManager, task);

      // 6. Done
      final toolCount = mcpManager.availableTools.length;
      state = state!.copyWith(
        phase: ActiveTaskPhase.ready,
        statusMessage: 'Ready — $toolCount tools available',
        toolCount: toolCount,
      );

      log.info(
        '[ActiveTask] Initialized — $toolCount tools, LLM: ${llmService.currentProvider.name}',
      );
    } catch (e, st) {
      log.error('[ActiveTask] Initialization failed: $e', e, st);
      state = ActiveTaskState(
        task: task,
        phase: ActiveTaskPhase.error,
        error: e.toString(),
        mcpManager: mcpManager,
        llmService: llmService,
      );
    }
  }

  String _withFormatInstruction(String? prompt) {
    final base = (prompt ?? '').trim();
    if (base.contains(_formatInstruction)) {
      return base;
    }
    return base.isEmpty ? _formatInstruction : '$base\n\n$_formatInstruction';
  }

  String _stripGeneratedCapabilitiesBlock(String? prompt) {
    final base = (prompt ?? '').trim();
    const marker = 'Enabled capabilities:';
    final markerIndex = base.indexOf(marker);
    if (markerIndex < 0) {
      return base;
    }
    return base.substring(0, markerIndex).trimRight();
  }

  /// Strips any existing "Tool Hints:" section from a system prompt so it can
  /// be re-injected fresh without duplication.
  String _stripToolSkillsSection(String prompt) {
    var base = prompt.trim();
    for (final marker in ['Tool Hints:', 'Tool Skills:']) {
      final doubleNewlineIdx = base.indexOf('\n\n$marker');
      if (doubleNewlineIdx >= 0) {
        base = base.substring(0, doubleNewlineIdx).trimRight();
      } else {
        final singleNewlineIdx = base.indexOf('\n$marker');
        if (singleNewlineIdx >= 0) {
          base = base.substring(0, singleNewlineIdx).trimRight();
        } else if (base.startsWith(marker)) {
          base = '';
        }
      }
    }
    return base;
  }

  String _normalizeModelToken(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  Future<String> _resolveRemoteEmbeddedModel(
    ServerApiClient api,
    String requestedModel,
  ) async {
    final requested = requestedModel.trim();
    if (requested.isEmpty) return requested;

    try {
      final files = await api.listServerModelFiles();
      final names = files
          .map((f) => (f['filename'] as String? ?? '').trim())
          .where((n) => n.isNotEmpty)
          .toList(growable: false);

      if (names.isEmpty) return requested;

      for (final name in names) {
        if (name == requested) return name;
      }

      for (final name in names) {
        if (name.toLowerCase() == requested.toLowerCase()) return name;
      }

      final wanted = _normalizeModelToken(requested);
      if (wanted.isEmpty) return requested;

      for (final name in names) {
        if (_normalizeModelToken(name) == wanted) return name;
      }

      for (final name in names) {
        final normalized = _normalizeModelToken(name);
        if (normalized.contains(wanted) || wanted.contains(normalized)) {
          return name;
        }
      }
    } catch (e) {
      log.warning(
        '[ActiveTask] Could not resolve remote embedded model "$requested": $e',
      );
    }

    return requested;
  }

  // ─── LLM configuration ───────────────────────────────

  Future<void> _configureLlm(LLMService llmService, WorkflowTask task) async {
    // In server mode, route ALL LLM calls through the server proxy so that the
    // server's configured provider and API key are used exclusively.
    final modeState = ref.read(serverModeProvider).value;
    if (modeState != null && modeState.isRemote) {
      final api = ServerApiClient(
        serverUrl: modeState.serverUrl,
        apiKey: modeState.apiKey.isNotEmpty ? modeState.apiKey : null,
      );
      final llmInfo = await api.getLlmSettings();
      // Preserve the task-specified model when one is explicitly stored.
      final requestedProvider =
          (_overrides?.llmProvider ?? task.llmConfig?.provider ?? '')
              .toLowerCase();
      final requestedModel =
          (_overrides?.llmModel ?? task.llmConfig?.model ?? '').trim();
      final isLlm2 = requestedProvider == 'llm2';
      final serverProvider =
          (isLlm2 ? llmInfo['provider2'] : llmInfo['provider']) as String? ??
          '';
      final explicitEmbeddedOverride =
          requestedProvider == 'embedded' && requestedModel.isNotEmpty;
      final forceMistralCompat =
          !explicitEmbeddedOverride &&
          serverProvider.toLowerCase() == 'mistral';
      final serverModel =
          (isLlm2 ? llmInfo['model2'] : llmInfo['model']) as String? ??
          'remote-model';
      final effectiveModel = explicitEmbeddedOverride
          ? await _resolveRemoteEmbeddedModel(api, requestedModel)
          : (requestedModel.isNotEmpty ? requestedModel : serverModel);
      final requestedApiKey = _overrides?.llmApiKey ?? task.llmConfig?.apiKey;
      final requestedBaseUrl = _overrides?.llmBaseUrl ?? task.llmConfig?.baseUrl;
      final proxyBase =
          '${modeState.serverUrl.trimRight().replaceAll(RegExp(r'/+$'), '')}/api/v1/${isLlm2 ? 'llm2' : 'llm'}';
      await llmService.initializeOpenAICompatible(
        baseUrl: proxyBase,
        apiKey: modeState.apiKey.isNotEmpty ? modeState.apiKey : null,
        model: effectiveModel,
        forceMistralCompat: forceMistralCompat,
        targetProvider: requestedProvider,
        targetBaseUrl: requestedBaseUrl,
        targetApiKey: requestedApiKey,
      );
      log.info(
        '[ActiveTask] Server mode — LLM proxy: $proxyBase, model: $effectiveModel'
        '${explicitEmbeddedOverride ? ' (custom embedded override)' : ''}',
      );
      return;
    }

    // Priority: editor overrides → task.llmConfig → global defaults
    String? provider = _overrides?.llmProvider ?? task.llmConfig?.provider;
    String? model = _overrides?.llmModel ?? task.llmConfig?.model;
    String? apiKey = _overrides?.llmApiKey ?? task.llmConfig?.apiKey;
    String? baseUrl = _overrides?.llmBaseUrl ?? task.llmConfig?.baseUrl;
    final settings = ref.read(llmSettingsProvider);

    // Read native tool call preference: per-task override > global settings
    bool useNativeToolCall;
    if (task.llmConfig != null) {
      useNativeToolCall = task.llmConfig!.useNativeToolCall;
    } else {
      useNativeToolCall = settings.useNativeToolCall;
    }

    // If provider is 'llm2', substitute with actual LLM2 settings
    if (provider?.toLowerCase() == 'llm2') {
      provider = settings.provider2.configKey;
      // Only override model/apiKey/baseUrl if not explicitly overridden
      if (model == null || model.isEmpty) model = settings.model2;
      if (apiKey == null || apiKey.isEmpty) apiKey = settings.apiKey2;
      if (baseUrl == null || baseUrl.isEmpty) baseUrl = settings.baseUrl2;
      useNativeToolCall = settings.useNativeToolCall2;
    }

    // Fall back to global defaults
    if (provider == null || provider.isEmpty) {
      provider = settings.provider.configKey;
      model = settings.model;
      apiKey = settings.apiKey;
      baseUrl = settings.baseUrl;
      useNativeToolCall = settings.useNativeToolCall;
    }

    final resolvedProvider = LlmProvider.fromConfigKey(provider);
    if ((apiKey == null || apiKey.isEmpty) &&
        resolvedProvider != LlmProvider.none) {
      apiKey = settings.getApiKeyForProvider(resolvedProvider);
    }
    if ((baseUrl == null || baseUrl.isEmpty) &&
        resolvedProvider != LlmProvider.none) {
      baseUrl = settings.getBaseUrlForProvider(resolvedProvider);
    }

    if (provider.isEmpty || provider == 'none') return;

    final cfgExtraParams =
        task.llmConfig?.extraParams ?? const <String, dynamic>{};
    final int? effectiveMaxTokens =
        _overrides?.maxTokens ?? task.llmConfig?.maxTokens;
    final int? effectiveMaxToolOutputSize =
        _overrides?.maxToolOutputSize ??
        (cfgExtraParams['max_tool_output_size'] as num?)?.toInt();
    final int? effectiveTokenWarningThreshold =
        _overrides?.tokenWarningThreshold ??
        (cfgExtraParams['token_warning_threshold'] as num?)?.toInt();

    if (provider.isEmpty || provider == 'none') return;

    try {
      switch (provider.toLowerCase()) {
        case 'gemini':
        case 'google':
          await llmService.initializeGemini(
            apiKey: apiKey ?? '',
            model: model ?? 'gemini-2.5-flash',
          );
          break;
        case 'openai':
          await llmService.initializeOpenAI(
            apiKey: apiKey ?? '',
            model: model ?? 'gpt-4o-mini',
          );
          break;
        case 'claude':
        case 'anthropic':
          await llmService.initializeClaude(
            apiKey: apiKey ?? '',
            model: model ?? 'claude-3-5-sonnet-20241022',
          );
          break;
        case 'mistral':
          await llmService.initializeOpenAICompatible(
            baseUrl: baseUrl?.trim().isNotEmpty == true
                ? baseUrl!.trim()
                : 'https://api.mistral.ai/v1',
            apiKey: apiKey,
            model: model ?? 'mistral-large',
          );
          break;
        case 'ollama':
          await llmService.initializeOllama(
            baseUrl: baseUrl ?? 'http://localhost:11434/api',
            model: model ?? 'llama3.1:latest',
            apiKey: apiKey,
            useNativeToolCall: useNativeToolCall,
          );
          break;
        case 'openai_compatible':
        case 'openaicompatible':
          await llmService.initializeOpenAICompatible(
            baseUrl: baseUrl ?? '',
            apiKey: apiKey,
            model: model ?? 'local-model',
          );
          break;
        case 'embedded':
          if (model != null && model.isNotEmpty) {
            final fullPath = await EmbeddedModelManager.instance
                .fullPathForFilename(model);
            if (!await File(fullPath).exists()) {
              throw StateError(
                'Embedded model file not found: $model\nPlease re-download the model in Settings → On-device models.',
              );
            }
            final gpuLayers = await EmbeddedModelManager.instance.getGpuLayers(
              model,
            );
            await llmService.initializeEmbedded(
              modelPath: fullPath,
              gpuLayers: gpuLayers,
              onProgress: (p) {
                // llamadart loadModel has no intermediate callbacks — progress jumps
                // straight from 0 → 1. Show plain "Loading model…" at p=0 so the
                // task dialog doesn't display a misleading frozen "0%" entry.
                final pct = p > 0.0 ? ' ${(p * 100).toStringAsFixed(0)}%' : '';
                state = state?.copyWith(
                  loadingProgress: p,
                  statusMessage: 'Loading model…$pct',
                );
              },
            );
            state = state?.copyWith(clearLoadingProgress: true);
          }
          break;
        default:
          log.warning('[ActiveTask] Unsupported LLM provider: $provider');
          break;
      }

      final extraParams = task.llmConfig?.extraParams ?? const <String, dynamic>{};
      final bool resolvedIsMultiModal = _overrides?.isMultiModal ??
          (extraParams['is_multi_modal'] as bool?) ??
          (() {
            final lowerProvider = provider?.toLowerCase() ?? '';
            if (lowerProvider == 'llm2') {
              return settings.isMultiModal2;
            }
            final providerEnum = LlmProvider.fromConfigKey(lowerProvider);
            if (providerEnum == LlmProvider.embedded) {
              return LlmSettingsService.detectDefaultMultiModal(LlmProvider.embedded, model ?? '');
            }
            if (providerEnum == settings.provider) {
              return settings.isMultiModal;
            }
            return LlmSettingsService.detectDefaultMultiModal(providerEnum, model ?? '');
          })();
      llmService.setIsMultiModal(resolvedIsMultiModal);

      llmService.applySessionLimits(
        maxTokens: effectiveMaxTokens,
        maxToolOutputChars: effectiveMaxToolOutputSize,
        tokenWarningThreshold: effectiveTokenWarningThreshold,
      );

      log.info('[ActiveTask] LLM configured: $provider / $model (isMultiModal: $resolvedIsMultiModal)');
    } catch (e) {
      log.error('[ActiveTask] LLM config failed: $e');
      rethrow;
    }
  }

  // ─── External MCP servers ────────────────────────────

  Future<void> _connectExternalMcps(
    MultiMCPManager manager,
    WorkflowTask task,
  ) async {
    final extSvc = ExternalToolsSettingsService.instance;
    if (!extSvc.isLoaded) await extSvc.load();

    for (final serverConfig in task.mcpTools) {
      final baseUrl = serverConfig.serverUrl.trim().replaceAll(
        RegExp(r'/+$'),
        '',
      );
      var endpoint = (serverConfig.mcpEndpoint ?? '/mcp').trim();
      if (endpoint.isEmpty) endpoint = '/mcp';
      if (!endpoint.startsWith('/')) endpoint = '/$endpoint';

      // MCPClient.connect() internally chains: _testConnection (up to 20 s),
      // _initialize (30 s) and _loadCapabilities/tools-list (30 s).
      // The outer timeout is a safety net only and must be larger than the
      // sum of those inner timeouts.
      const outerTimeout = Duration(seconds: 90);

      bool succeeded = false;

      // Attempt to connect; on first *non-timeout* failure for a Smithery URL
      // invalidate the stale cached connection and retry once with a freshly
      // created Smithery managed-connection.  Timeout errors mean the server
      // is simply slow, not that the connection ID is stale — no retry needed.
      for (int attempt = 1; attempt <= 2 && !succeeded; attempt++) {
        try {
          // For Smithery servers: resolve to managed-connection proxy URL
          final (resolvedBase, resolvedKey) = await extSvc
              .resolveSmitheryEndpoint(baseUrl, serverConfig.apiKey);
          // Don't append endpoint if the URL path already includes /mcp.
          // Use URI path inspection so embedded ?api_key= query params don't break the check.
          final parsedResolved = Uri.parse(resolvedBase);
          final url = parsedResolved.path.toLowerCase().endsWith('/mcp')
              ? resolvedBase
              : parsedResolved
                    .replace(path: parsedResolved.path + endpoint)
                    .toString();

          final client = MCPClient(url, bearerToken: resolvedKey);
          // onTimeout must throw so the catch block prevents registering a
          // disconnected (0-tool) client.
          await client.connect().timeout(
            outerTimeout,
            onTimeout: () {
              throw TimeoutException(
                '[ActiveTask] Timeout connecting to MCP: ${serverConfig.name ?? url}',
                outerTimeout,
              );
            },
          );

          manager.registerClient(
            MCPClientDef(
              name: serverConfig.name ?? Uri.parse(url).host,
              client: client,
              displayName: serverConfig.name,
            ),
          );
          log.info(
            '[ActiveTask] Connected to MCP: ${serverConfig.name ?? url}',
          );
          succeeded = true;

          // Persist the discovered tool names back to ExternalToolsSettingsService
          // so the per-step tool selector in playground setup mode shows real tools.
          final toolNames = client.availableTools.map((t) => t.name).toList();
          if (toolNames.isNotEmpty) {
            final existing = extSvc.selectedServers.firstWhere(
              (s) => s.serverUrl == serverConfig.serverUrl,
              orElse: () => serverConfig,
            );
            if (!listEquals(existing.discoveredTools, toolNames)) {
              final toolSchemas = client.availableTools
                  .map((t) => t.toJson())
                  .toList();
              unawaited(
                extSvc.upsertSelectedServer(
                  existing.copyWith(
                    discoveredTools: toolNames,
                    discoveredToolSchemas: toolSchemas,
                  ),
                ),
              );
            }
          }
        } catch (e) {
          final isSmithery = baseUrl.toLowerCase().contains('smithery.ai');
          // e may be a wrapped Exception rather than a raw TimeoutException,
          // so check both the runtime type and the message string.
          final isTimeout =
              e is TimeoutException ||
              e.toString().toLowerCase().contains('timeoutexception');
          if (attempt == 1 && isSmithery && !isTimeout) {
            // Fast failure usually means a stale Smithery managed-connection ID.
            // Invalidate and retry with a freshly created connection.
            log.warning(
              '[ActiveTask] MCP ${serverConfig.name ?? baseUrl} failed (attempt $attempt): $e — invalidating Smithery connection and retrying…',
            );
            await extSvc.invalidateSmitheryConnection(baseUrl);
          } else {
            log.warning(
              '[ActiveTask] Failed MCP ${serverConfig.name ?? serverConfig.serverUrl}: $e',
            );
          }
        }
      }
    }
  }

  // ─── Internal (built-in) MCP servers ─────────────────

  Future<void> _connectInternalMcps(
    MultiMCPManager manager,
    WorkflowTask task,
  ) async {
    final registry = InternalMcpRegistry();
    final ds = DataSourcesSettingsService.instance;
    if (!ds.isLoaded) {
      await ds.load();
    }

    // Always-on toolbox MCP (time/timezone/location/geocoding utilities)
    // — unless the task has explicitly disabled it (toolbox entry with enabled:false)
    final toolboxDisabled = task.internalMcps.any(
      (m) => m.mcpType == 'toolbox' && !m.enabled,
    );
    if (!toolboxDisabled) {
      try {
        final toolbox = registry.create('toolbox');
        if (toolbox != null) {
          await toolbox
              .initialize(const {'timezone': 'local'})
              .timeout(
                const Duration(seconds: 10),
                onTimeout: () {
                  log.warning(
                    '[ActiveTask] Timeout initializing internal MCP: toolbox',
                  );
                },
              );

          final toolboxAdapter = InternalMcpClientAdapter(toolbox);
          await toolboxAdapter.connect().timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              log.warning(
                '[ActiveTask] Timeout connecting internal MCP adapter: toolbox',
              );
            },
          );

          manager.registerClient(
            MCPClientDef(
              name: 'internal_toolbox',
              client: toolboxAdapter,
              displayName: toolbox.displayName,
            ),
          );

          log.info(
            '[ActiveTask] Internal MCP ready: ${toolbox.displayName} (${toolboxAdapter.availableTools.length} tools)',
          );
        }
      } catch (e) {
        log.warning('[ActiveTask] Failed internal MCP toolbox: $e');
      }
    }

    for (final entry in task.internalMcps) {
      if (!entry.enabled) continue;
      if (entry.mcpType == 'toolbox') continue;
      try {
        // In Server Mode, GitHub MCP entries are hosted on the remote server,
        // not in the local InternalMcpRegistry.
        if (entry.mcpType.startsWith('gh_mcp_')) {
          final modeState = ref.read(serverModeProvider).value;
          final isRemote = modeState?.isRemote == true;
          final serverId = entry.mcpType.substring('gh_mcp_'.length).trim();
          if (isRemote && serverId.isNotEmpty) {
            final api = ServerApiClient(
              serverUrl: modeState!.serverUrl,
              apiKey: modeState.apiKey.isNotEmpty ? modeState.apiKey : null,
            );
            final proxyClient = ServerMcpProxyClient(
              api: api,
              serverId: serverId,
            );
            await proxyClient.connect();
            manager.registerClient(
              MCPClientDef(
                name: 'remote_$serverId',
                client: proxyClient,
                displayName: entry.label ?? 'Remote MCP ($serverId)',
              ),
            );
            log.info(
              '[ActiveTask] Remote MCP ready: $serverId (${proxyClient.availableTools.length} tools)',
            );
            continue;
          }
        }

        // In Server Mode, script/code execution MCPs should run against the
        // remote server runtime, not the local app runtime.
        const remoteInternalProxyTypes = <String>{
          'ssh',
          'js_bridge',
          'py_bridge',
          'ps_bridge',
        };
        if (remoteInternalProxyTypes.contains(entry.mcpType)) {
          final modeState = ref.read(serverModeProvider).value;
          if (modeState?.isRemote == true) {
            final api = ServerApiClient(
              serverUrl: modeState!.serverUrl,
              apiKey: modeState.apiKey.isNotEmpty ? modeState.apiKey : null,
            );
            final proxyClient = ServerMcpProxyClient(
              api: api,
              serverId: entry.mcpType,
              initParams: entry.initParams,
            );
            await proxyClient.connect();
            manager.registerClient(
              MCPClientDef(
                name: 'remote_${entry.mcpType}',
                client: proxyClient,
                displayName: entry.label ?? entry.mcpType,
              ),
            );
            log.info(
              '[ActiveTask] Remote ${entry.mcpType} MCP ready (${proxyClient.availableTools.length} tools)',
            );
            continue;
          }
        }

        final server = registry.create(entry.mcpType);
        if (server == null) {
          log.warning(
            '[ActiveTask] Unknown internal MCP type: ${entry.mcpType}',
          );
          continue;
        }

        final initParams = Map<String, dynamic>.from(entry.initParams);
        if (entry.mcpType == 'gmail' || entry.mcpType == 'google_calendar') {
          if (ds.isGmailAccessTokenExpired) {
            final refresh = await ds.refreshGmailAccessToken();
            if (refresh['success'] != true) {
              log.warning(
                '[ActiveTask] Google token refresh failed before MCP init: ${refresh['error']}',
              );
            }
          }

          final token = ds.gmailAccessToken.trim();
          if (token.isNotEmpty) {
            initParams['accessToken'] = token;
          }
          if (entry.mcpType == 'gmail' &&
              (initParams['userId']?.toString().trim().isEmpty ?? true)) {
            initParams['userId'] = 'me';
          }
        }

        if (entry.mcpType == 'document' || entry.mcpType == 'website_search') {
          final currentStrategy =
              (initParams['indexingStrategy']?.toString().trim() ?? '')
                  .toLowerCase();
          if (currentStrategy != 'before_first_run') {
            initParams['indexingStrategy'] = 'before_first_run';
            log.info(
              '[ActiveTask] Overriding ${entry.mcpType} indexingStrategy to before_first_run for interactive mode',
            );
          }
        }

        // Timeout initialization to prevent the spinner from hanging forever.
        // For gh_mcp_ servers (external processes like puppeteer) the first launch
        // can take 30+ seconds (npm/npx downloads). We keep the short timeout so
        // the UI becomes interactive quickly, but we hold a reference to the
        // original future and refresh the adapter's tool list once initialization
        // completes in the background.
        final initFuture = server.initialize(initParams);
        await initFuture.timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            log.warning(
              '[ActiveTask] Timeout initializing internal MCP: ${entry.mcpType}',
            );
          },
        );

        final adapter = InternalMcpClientAdapter(server);
        await adapter.connect().timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            log.warning(
              '[ActiveTask] Timeout connecting internal MCP adapter: ${entry.mcpType}',
            );
          },
        );

        manager.registerClient(
          MCPClientDef(
            name: 'internal_${entry.mcpType}',
            client: adapter,
            displayName: entry.label ?? server.displayName,
          ),
        );

        log.info(
          '[ActiveTask] Internal MCP ready: ${server.displayName} '
          '(${adapter.availableTools.length} tools)',
        );

        // If the server is still initializing (tools empty after connect), wire
        // up a background callback that refreshes the adapter once init finishes.
        // This is important for gh_mcp_ servers that start external processes.
        if (adapter.availableTools.isEmpty) {
          initFuture
              .then((_) {
                adapter.refreshTools();
                if (adapter.availableTools.isNotEmpty) {
                  log.info(
                    '[ActiveTask] Background MCP init complete: ${entry.mcpType} '
                    '(${adapter.availableTools.length} tools)',
                  );
                }
              })
              .catchError((e) {
                log.warning(
                  '[ActiveTask] Background MCP init error: ${entry.mcpType}: $e',
                );
              });
        }
      } catch (e) {
        log.warning('[ActiveTask] Failed internal MCP ${entry.mcpType}: $e');
        // Don't rethrow — continue with remaining MCPs
      }
    }
  }

  // ─── Cleanup ──────────────────────────────────────────

  void _disposeCurrentState() {
    final prev = state;
    if (prev == null) return;

    // Dispose MCP clients
    if (prev.mcpManager != null) {
      for (final clientDef in prev.mcpManager!.clients) {
        try {
          clientDef.client.dispose();
        } catch (_) {}
      }
      prev.mcpManager!.dispose();
    }

    prev.llmService?.dispose();

    if (prev.chatService != null) {
      try {
        prev.chatService!.dispose();
      } catch (_) {}
    }
  }
}
