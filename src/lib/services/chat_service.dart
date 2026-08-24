import 'dart:async';
import 'dart:math' as math;
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/mcp_models.dart';
import '../config/tool_usage_rules.dart';
import 'multi_mcp_manager.dart';
import 'llm_service.dart';
import 'llm_settings_service.dart';
import 'file_download_service.dart';
import 'location_service.dart';
import '../utils/tool_router.dart';
import '../utils/llm_tool_selector.dart';
import '../utils/logger.dart';
import '../models/step_types.dart';
import '../models/workflow_task.dart';

/// Stub for plugin prompts (replaces ai_chat_ProjectPrompts)
class ProjectPrompts {
  final String? systemPrompt;
  final String? systemPromptSuffix;
  final String? warmupPrompt;
  ProjectPrompts({
    this.systemPrompt,
    this.systemPromptSuffix,
    this.warmupPrompt,
  });
}

/// Processing types for different stages of chat processing
enum ProcessingType { none, llm, mcp }

/// Chat service that coordinates between MCP client and LLM
class ChatService extends ChangeNotifier with ServiceLogging {
  static const String _horizontalScrollingKey = 'enable_horizontal_scrolling';
  static const String _showToolMessagesKey = 'show_tool_messages';
  static const String _internalSystemPromptActionType =
      'internal_system_prompt';
  static final RegExp _extensionPattern = RegExp(r'^[a-z0-9]+$');

  final MCPClientInterface mcpClient;
  List<MCPTool> get availableTools => mcpClient.availableTools;
  final LLMService llmService;
  final LocationService locationService;
  final String? Function()? getWarmupPrompt;
  final ProjectPrompts? Function()? getPluginPrompts;
  final Future<void> Function(String)?
  reloadPluginPrompts; // Callback to reload plugin prompts for model
  final String?
  pluginAssetBasePath; // e.g., 'assets/wsagrarai/prompts' or 'assets/documentai/prompts' (DEPRECATED - use plugin reload instead)
  /// When true: skip system prompt, warmup, tools, and location injection.
  /// Messages are sent directly to the LLM with no extra context.
  final bool chatMode;

  /// When true: execute the first tool call but do NOT send its result back to
  /// the LLM. The agentic loop stops after the tool returns.
  final bool stopAfterToolCall;
  late final FileDownloadService? _fileDownloadService;
  ToolRouter? _toolRouter;
  int _toolRouterToolCount =
      0; // Track how many tools the router was initialized with
  final List<ChatMessage> _messages = [];
  final StreamController<List<ChatMessage>> _messagesController =
      StreamController<List<ChatMessage>>.broadcast();
  final StreamController<ChatMessage> _messageController =
      StreamController<ChatMessage>.broadcast();
  final StreamController<String> _errorNotificationController =
      StreamController<String>.broadcast();
  final StreamController<String?> _emptyResponseController =
      StreamController<String?>.broadcast();
  final Uuid _uuid = const Uuid();

  // Conversation tracking
  final String _conversationId = const Uuid().v4();

  // Store completed download info by message ID
  final Map<String, DownloadProgress> _completedDownloads = {};

  // Track last called tool name for context in message rendering
  String? _lastCalledToolName;
  String? _lastGmailQuery;
  String? _lastWebSearchQuery;

  ProcessingType _processingType = ProcessingType.none;
  // Tool message visibility control
  bool _showToolMessages = true;
  // Horizontal scrolling preference for wide content
  bool _enableHorizontalScrolling = false;
  // Cached warmup prompt
  String? _warmupPrompt;

  // Track if warmup/priming is in progress
  bool _isPriming = false;
  // Timer for debouncing MCP initialization
  Timer? _mcpInitTimer;
  // Timer for debouncing semantic filtering initialization
  Timer? _semanticInitTimer;
  // Chunking configuration
  // 50,000 chars â‰ˆ 12,500 tokens, optimized for modern LLMs with large context windows
  // If you experience issues (timeouts, errors), decrease this to 30000 or 20000
  // Chunking progress
  final double _chunkingProgress = 0.0;
  final bool _isChunking = false;
  // Sub-prompt separator — delegates to the canonical regex in sub_prompt_types.dart
  // which supports both legacy [N0] and new [NT:tool1|tool2] formats.
  static RegExp get _subPromptSepRegex => stepSepRegex;

  /// Filters the "Tool Hints:" block in [prompt] so that only skills whose
  /// tool name appears in [enabledToolNames] are kept.
  ///
  /// * [enabledToolNames] empty  → strips the skills block entirely (no-tools step).
  /// * [enabledToolNames] non-empty → keeps only matching bullet lines.
  /// * No skills block present → prompt returned unchanged.
  ///
  /// The base prompt text before the skills block is always preserved verbatim.
  static String _filterSkillsForStep(
    String prompt,
    List<String> enabledToolNames,
  ) {
    var idx = prompt.indexOf('\n\nTool Hints:');
    var markerLength = '\n\nTool Hints:'.length;
    if (idx < 0) {
      idx = prompt.indexOf('\n\nTool Skills:');
      markerLength = '\n\nTool Skills:'.length;
    }
    if (idx < 0) return prompt; // no skills block present
    final base = prompt.substring(0, idx);
    if (enabledToolNames.isEmpty) {
      return base; // no-tools step → strip all skills
    }
    // Keep only bullet lines whose tool name is in the enabled set.
    final skillsSection = prompt.substring(idx + markerLength);
    final kept = <String>[];
    for (final line in skillsSection.split('\n')) {
      if (line.trim().isEmpty) continue;
      final match = RegExp(r'^[*•]\s+(\S+?):\s').firstMatch(line.trim());
      if (match != null && enabledToolNames.contains(match.group(1))) {
        kept.add(line.trim());
      }
    }
    if (kept.isEmpty) return base;
    return '$base\n\nTool Hints:\n${kept.join('\n')}';
  }

  // Cancellation flag for multi-step tasks
  bool _isCancelled = false;
  // When true for a single step inside _processSubPrompts, halt after first tool call
  bool _subPromptStopAfterToolCall = false;
  // Index into the non-system messages list where the current sub-prompt step started.
  // -1 means no sub-prompt is running (include all history).
  int _subPromptContextStartCount = -1;
  // Enabled tool names for the currently-executing sub-prompt step.
  // null = all tools, [] = no tools, [...] = specific tools.
  List<String>? _subPromptEnabledTools;
  // Disposed flag – prevents notifyListeners() / stream writes after dispose()
  bool _isDisposed = false;
  // Retry counter for empty responses
  int _currentRetryCount = 0;
  // Tool iteration counter to prevent infinite loops
  int _toolIterationCount = 0;
  static const int _maxToolIterations =
      10; // Maximum 10 tool iterations per user request
  bool _forceNoToolCallsNextTurn = false;
  String? _forcedNoToolHintNextTurn;

  // Track executed tool signatures/IDs in the current chat turn to prevent loops
  final Set<String> _executedToolCallSignatures = {};
  final Set<String> _executedToolCallIds = {};
  // Streaming placeholder: when Ollama is streaming, we add an assistant message up-front
  // and update it in real-time. _streamingPlaceholderId tracks that message so
  // _addMessage() can replace it seamlessly when the final response is committed.
  String? _streamingPlaceholderId;
  // Track cumulative tokens used in conversation
  int _cumulativeTokens = 0;
  int _cumulativePromptTokens = 0;
  int _cumulativeCompletionTokens = 0;
  int _lastRequestPromptTokens = 0;
  int _lastRequestCompletionTokens = 0;
  int _lastRequestTotalTokens = 0;
  bool _lastRequestUsageEstimated = false;
  int _estimatedUsageRequests = 0;
  double _lastRequestCostUsd = 0;
  double _sessionCostUsd = 0;
  // Track cumulative characters sent to LLM in this session
  int _totalSentChars = 0;
  // Stream controller for cleanup suggestion
  final StreamController<bool> _cleanupSuggestionController =
      StreamController<bool>.broadcast();
  // Track parameter validation retries (per tool call iteration)
  int _paramValidationRetryCount = 0;
  int _capabilityRefusalRetryCount = 0;
  // Semantic filtering initialization state
  bool _isInitializingSemanticFiltering = false;
  bool _isWaitingForServers = false; // True during debounce period
  String _semanticFilteringStatus = '';
  // Conversation priming state (for native tool calling providers)
  bool _isConversationPrimed = false;
  // Flag to trigger soft reset after LLM response completes
  bool _resetAfterResponse = false;
  // LLM provider change debounce
  Timer? _llmProviderChangeTimer;
  bool _lastLlmConfiguredState = false;
  // Track last model for prompt reloading
  String? _lastLoadedModel;

  final WorkflowTask Function()? getTask;

  ChatService({
    required this.mcpClient,
    required this.locationService,
    required this.llmService,
    this.getWarmupPrompt,
    this.getPluginPrompts,
    this.reloadPluginPrompts,
    this.pluginAssetBasePath,
    this.chatMode = false,
    this.stopAfterToolCall = false,
    this.getTask,
  }) {
    // Initialize FileDownloadService with the MCP client
    _fileDownloadService = FileDownloadService(mcpClient);
    talker.info(' FileDownloadService initialized with MCP client');

    // ToolRouter will be initialized lazily when tools are first needed
    // Load saved preferences
    _loadPreferences();
    // Load warmup prompt and initialize chat
    _loadWarmupAndInitialize();
    // Fetch user location on startup (non-blocking)
    _fetchLocationOnStartup();

    // Listen for MCP tool changes and reinitialize when tools become available
    mcpClient.addListener(_onMcpToolsChanged);

    // Listen for LLM provider changes and initialize chat when configured
    llmService.addListener(_onLlmProviderChanged);
  }

  /// Called when MCP tools change (servers connect/disconnect)
  void _onMcpToolsChanged() {
    final currentToolCount = mcpClient.availableTools.length;
    talker.info('ðŸ”„ MCP tools changed, available tools: $currentToolCount');

    // Cancel any pending semantic filtering timer
    _semanticInitTimer?.cancel();
    _isWaitingForServers = false; // Reset waiting state

    // NOTE: Semantic filtering is now lazy-loaded on first user message (Phase 3)
    // No longer pre-initialized during app startup
    talker.info(
      ' Tools available, semantic filtering will initialize on first user message',
    );

    // Cancel any pending chat init timer
    _mcpInitTimer?.cancel();

    if (mcpClient.availableTools.isNotEmpty && !_isConversationPrimed) {
      // Only initialize if LLM provider is already selected
      if (!llmService.isConfigured) {
        talker.info(
          'â¸ï¸ Tools available but no LLM provider selected yet, skipping initialization',
        );
        return;
      }

      // Guard: don't schedule _initializeChat while sendMessage() is running.
      // The 1-second timer can fire mid-execution (during the LLM tool loop)
      // and set _isConversationPrimed = true, which strips the system prompt
      // from the second _processLLMResponse() call, causing an empty final answer.
      if (isProcessing) {
        talker.info(
          'Skipping _initializeChat timer – sendMessage already in progress',
        );
        return;
      }

      // Debounce: wait 1 second for more servers to connect before initializing
      talker.info('Waiting for more servers to connect...');
      _mcpInitTimer = Timer(const Duration(seconds: 1), () async {
        // Re-check: abort if processing started while the timer was pending
        if (isProcessing) {
          talker.info(
            'Aborting _initializeChat – sendMessage started during debounce',
          );
          return;
        }
        talker.info(
          ' Tools now available (${mcpClient.availableTools.length}), initializing chat with system prompt...',
        );
        await _initializeChat();
      });
    }
  }

  /// Called when LLM provider changes (configured/changed)
  Future<void> _onLlmProviderChanged() async {
    // Debounce: ignore rapid-fire notifications during initialization
    final currentConfigState = llmService.isConfigured;
    if (_lastLlmConfiguredState == currentConfigState) {
      // State hasn't changed, ignore this notification
      return;
    }

    _lastLlmConfiguredState = currentConfigState;
    _llmProviderChangeTimer?.cancel();
    _llmProviderChangeTimer = Timer(const Duration(milliseconds: 500), () async {
      if (_isDisposed) return;
      talker.info(
        'ðŸ”„ LLM provider changed, configured: ${llmService.isConfigured}',
      );

      // If LLM is now configured and we have tools but haven't initialized yet
      if (llmService.isConfigured &&
          mcpClient.availableTools.isNotEmpty &&
          !_isConversationPrimed) {
        talker.info(
          ' LLM provider now configured, reloading warmup and initializing chat...',
        );
        // Reload warmup prompt before initializing to get fresh content
        await _loadWarmupPrompt();
        await _initializeChat();
      }
    });
  }

  /// Load warmup prompt and then initialize chat
  Future<void> _loadWarmupAndInitialize() async {
    talker.info('ðŸ”„ Starting warmup and initialization...');
    await _loadWarmupPrompt();
    talker.info('ðŸ“‹ Warmup loaded, waiting for MCP servers to connect...');
    // Don't call _initializeChat() here - let the MCP listener handle it
    // This ensures we wait for all MCP servers to connect and load their tools
  }

  /// Fetch location on startup without blocking
  void _fetchLocationOnStartup() {
    locationService
        .getCurrentLocation()
        .then((position) {
          if (position != null) {
            talker.info(
              'Location obtained on startup: ${position.latitude}, ${position.longitude}',
            );
          } else {
            talker.info('Location not available on startup');
          }
        })
        .catchError((e) {
          talker.warning('Failed to get location on startup: $e');
        });
  }

  /// Load preferences from SharedPreferences
  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _showToolMessages = prefs.getBool(_showToolMessagesKey) ?? true;
      _enableHorizontalScrolling =
          prefs.getBool(_horizontalScrollingKey) ?? false;
      notifyListeners();
    } catch (e) {
      debugPrint('Failed to load chat preferences: $e');
    }
  }

  // Getters
  List<ChatMessage> get messages => List.unmodifiable(_messages);
  Stream<List<ChatMessage>> get messagesStream => _messagesController.stream;
  Stream<ChatMessage> get messageStream => _messageController.stream;
  Stream<String> get errorNotificationStream =>
      _errorNotificationController.stream;
  Stream<String?> get emptyResponseStream => _emptyResponseController.stream;
  Stream<bool> get cleanupSuggestion => _cleanupSuggestionController.stream;
  bool get isProcessing => _processingType != ProcessingType.none;
  ProcessingType get processingType => _processingType;
  bool get showToolMessages => _showToolMessages;
  bool get enableHorizontalScrolling => _enableHorizontalScrolling;
  double get chunkingProgress => _chunkingProgress;
  bool get isChunking => _isChunking;
  bool get isCancelled => _isCancelled;
  bool get isInitializingSemanticFiltering =>
      _isInitializingSemanticFiltering || _isWaitingForServers;
  String get semanticFilteringStatus => _semanticFilteringStatus;
  int get currentRetryCount => _currentRetryCount;
  bool get isPriming => _isPriming;
  int get cumulativeTokens => _cumulativeTokens;
  int get cumulativePromptTokens => _cumulativePromptTokens;
  int get cumulativeCompletionTokens => _cumulativeCompletionTokens;
  int get lastRequestPromptTokens => _lastRequestPromptTokens;
  int get lastRequestCompletionTokens => _lastRequestCompletionTokens;
  int get lastRequestTotalTokens => _lastRequestTotalTokens;
  bool get lastRequestUsageEstimated => _lastRequestUsageEstimated;
  int get estimatedUsageRequests => _estimatedUsageRequests;
  double get lastRequestCostUsd => _lastRequestCostUsd;
  double get sessionCostUsd => _sessionCostUsd;
  int get totalSentChars => _totalSentChars;

  String _providerKeyForPricing() {
    switch (llmService.currentProvider) {
      case LLMProvider.gemini:
        return 'gemini';
      case LLMProvider.openai:
        return 'openai';
      case LLMProvider.claude:
        return 'claude';
      case LLMProvider.ollama:
        return 'ollama';
      case LLMProvider.openaiCompatible:
        return llmService.currentModel.toLowerCase().contains('mistral')
            ? 'mistral'
            : 'openai_compatible';
      case LLMProvider.embedded:
        return ''; // On-device — no cloud pricing.
      case LLMProvider.none:
        return '';
    }
  }

  /// Retry the last LLM request after empty response
  Future<void> retryLastRequest() async {
    if (isProcessing) {
      talker.warning('Cannot retry - already processing');
      return;
    }

    talker.info('ðŸ”„ Retrying last request...');

    // Add retry message
    final retryMessage = ChatMessage(
      id: _uuid.v4(),
      content: 'ðŸ”„ Retrying request...',
      role: ChatRole.system,
      timestamp: DateTime.now(),
    );
    _addMessage(retryMessage);

    _processingType = ProcessingType.llm;
    notifyListeners();

    try {
      await _processLLMResponse();
    } catch (e) {
      talker.error('Retry failed: $e');
      final errorMessage = ChatMessage(
        id: _uuid.v4(),
        content: 'Retry failed: ${e.toString()}',
        role: ChatRole.assistant,
        timestamp: DateTime.now(),
      );
      _addMessage(errorMessage);
    } finally {
      _processingType = ProcessingType.none;
      notifyListeners();
    }
  }

  /// Stop/cancel current processing
  void stopProcessing() {
    if (isProcessing) {
      _isCancelled = true;
      talker.warning('Processing canceled by user');

      // Add cancellation message
      final cancelMessage = ChatMessage(
        id: _uuid.v4(),
        content: '**Task Canceled**\n\nProcessing was stopped by user.',
        role: ChatRole.system,
        timestamp: DateTime.now(),
      );
      _addMessage(cancelMessage);

      // Reset processing state
      _processingType = ProcessingType.none;
      notifyListeners();
    }
  }

  /// Get download progress for a specific message ID
  DownloadProgress? getDownloadProgress(String messageId) {
    return _completedDownloads[messageId];
  }

  /// Set whether to show tool messages in chat
  void setShowToolMessages(bool show) {
    if (_showToolMessages != show) {
      _showToolMessages = show;
      _saveShowToolMessagesPreference(show);
      notifyListeners();
      // Refresh the messages stream to update visibility
      _messagesController.add(List.unmodifiable(_messages));
    }
  }

  /// Set whether to enable horizontal scrolling for wide content
  void setEnableHorizontalScrolling(bool enable) {
    if (_enableHorizontalScrolling != enable) {
      _enableHorizontalScrolling = enable;
      _saveHorizontalScrollingPreference(enable);
      notifyListeners();
      // Refresh the messages stream to update display
      _messagesController.add(List.unmodifiable(_messages));
    }
  }

  /// Save horizontal scrolling preference to SharedPreferences
  Future<void> _saveHorizontalScrollingPreference(bool enable) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_horizontalScrollingKey, enable);
    } catch (e) {
      debugPrint('Failed to save horizontal scrolling preference: $e');
    }
  }

  /// Save show tool messages preference to SharedPreferences
  Future<void> _saveShowToolMessagesPreference(bool show) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_showToolMessagesKey, show);
    } catch (e) {
      debugPrint('Failed to save show tool messages preference: $e');
    }
  }

  /// Filter out <think> blocks from streaming content so they never appear in
  /// the real-time placeholder UI. Removes complete `<think>…</think>` blocks
  /// and also removes any open (not-yet-closed) block from `<think>` to end.
  static String _filterThinkBlocksForStreaming(String text) {
    // Remove complete blocks first
    var result = text.replaceAll(
      RegExp(r'<think>.*?</think>', caseSensitive: false, dotAll: true),
      '',
    );
    // Remove any open/incomplete block (from <think> to end of string)
    result = result.replaceAll(
      RegExp(r'<think>.*', caseSensitive: false, dotAll: true),
      '',
    );
    return result.trim();
  }

  /// Clean assistant response content to remove system instructions that shouldn't be visible to users
  String _cleanAssistantResponse(String content) {
    String cleanedContent = content;

    // Clean XML tool calls so raw JSON and tags are not shown in UI chat bubbles
    cleanedContent = cleanedContent
        .replaceAll(
          RegExp(
            r'<tool_call>\s*[\s\S]*?\s*</tool_call>',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
    cleanedContent = cleanedContent
        .replaceAll(RegExp(r'</?tool_call>', caseSensitive: false), '')
        .trim();

    // Clean direct JSON tool calls so they are not shown in UI chat bubbles
    int jsonIndex = 0;
    while ((jsonIndex = cleanedContent.indexOf('{', jsonIndex)) != -1) {
      try {
        final jsonStr = _extractBalancedJson(
          cleanedContent.substring(jsonIndex),
        );
        if (jsonStr.isNotEmpty) {
          final decoded = jsonDecode(jsonStr);
          if (decoded is Map<String, dynamic>) {
            final inner = decoded['tool_call'] is Map<String, dynamic>
                ? decoded['tool_call'] as Map<String, dynamic>
                : decoded;
            final toolName = inner['name'] as String?;
            final arguments =
                (inner['arguments'] ?? inner['parameters'])
                    as Map<String, dynamic>?;
            if (toolName != null && toolName.isNotEmpty && arguments != null) {
              cleanedContent = cleanedContent.replaceFirst(jsonStr, '');
              // Reset index to start as string length changed
              jsonIndex = 0;
              continue;
            }
          }
        }
      } catch (_) {}
      jsonIndex++;
    }
    cleanedContent = cleanedContent.trim();

    // Remove <think> blocks if enabled (default true)
    talker.debug(
      'ðŸ§¹ Cleaning response: hideThinkBlocks=${llmService.hideThinkBlocks}, content length=${content.length}',
    );
    if (llmService.hideThinkBlocks) {
      talker.info('ðŸ§¹ Removing <think> blocks from response...');
      // Remove <think>...</think> blocks (case-insensitive, handles multiline)
      final beforeLength = cleanedContent.length;
      cleanedContent = cleanedContent
          .replaceAll(
            RegExp(r'<think>.*?</think>', caseSensitive: false, dotAll: true),
            '',
          )
          .trim();
      // Also remove standalone tags in case they're malformed
      cleanedContent = cleanedContent
          .replaceAll(RegExp(r'</?think>', caseSensitive: false), '')
          .trim();
      final afterLength = cleanedContent.length;
      if (beforeLength != afterLength) {
        talker.info(
          ' Removed ${beforeLength - afterLength} characters of <think> content',
        );
      } else {
        talker.debug('No <think> blocks found to remove');
      }
    } else {
      talker.debug('Think block hiding is disabled');
    }

    // List of patterns that indicate system instructions leaking into user-visible content
    final systemInstructionPatterns = <Pattern>[
      RegExp(
        r'If you have completed the request,.*?summarize.*?user-friendly way\.?',
        caseSensitive: false,
        dotAll: true,
      ),
      RegExp(
        r'If you have completed the request, summarize the results in a user-friendly way\.',
        caseSensitive: false,
      ),
      RegExp(
        r'If the request is fully completed,.*?provide.*?response.*?user\.?',
        caseSensitive: false,
        dotAll: true,
      ),
      RegExp(
        r'IMPORTANT:.*?Do not add.*?fields\.?',
        caseSensitive: false,
        dotAll: true,
      ),
      RegExp(r'CRITICAL.*?SCHEMA.*?:', caseSensitive: false, dotAll: true),
      RegExp(
        r'Remember:.*?tool assistance\.?',
        caseSensitive: false,
        dotAll: true,
      ),
      RegExp(
        r'Based on these tool execution results.*?:',
        caseSensitive: false,
        dotAll: true,
      ),
      // Catch large blocks of instructions (common in verbose AI responses)
      RegExp(
        r'Otherwise, provide a concise.*?Final check:.*?comparison of multiple devices\?',
        caseSensitive: false,
        dotAll: true,
      ),
      RegExp(
        r'DO NOT include any details about tool calls.*?Final check:.*?',
        caseSensitive: false,
        dotAll: true,
      ),
      // Catch repetitive "Do not..." instruction blocks
      RegExp(
        r'Do not include any tool code.*?(?:Do not.*?){5,}',
        caseSensitive: false,
        dotAll: true,
      ),
      RegExp(r'(?:DO NOT [^.!?]+[.!?]\s*){5,}', caseSensitive: false),
      RegExp(r'(?:Do not [^.!?]+[.!?]\s*){5,}', caseSensitive: false),
      // Catch "Final check:" instruction blocks
      RegExp(
        r'Final check:.*?(?:If so, you must.*?\.)',
        caseSensitive: false,
        dotAll: true,
      ),
    ];

    // Remove system instruction patterns
    for (final pattern in systemInstructionPatterns) {
      cleanedContent = cleanedContent.replaceAll(pattern, '').trim();
    }

    // Strip thought_signature from LLM text output - it should only appear in tool call arguments
    // Some LLMs incorrectly dump the thought_signature as their text response
    cleanedContent = cleanedContent
        .replaceAll(
          RegExp(r'thought_signature:\s*\S+', caseSensitive: false),
          '',
        )
        .trim();
    cleanedContent = cleanedContent
        .replaceAll(
          RegExp(r'"?thought_signature"?\s*:\s*"[^"]*"', caseSensitive: false),
          '',
        )
        .trim();

    // Strip leaked channel-thought/debug blocks (e.g. "<|channel|>thought ...")
    // that some models output in plain text.
    final beforeChannelStripLength = cleanedContent.length;
    cleanedContent = cleanedContent
        .replaceAll(
          RegExp(
            r'<\|channel\|>\s*thought[\s\S]*?(?=<\|channel\|>\s*(?:assistant|final)|$)',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
    cleanedContent = cleanedContent
        .replaceAll(
          RegExp(r'<\|channel\|>\s*thought', caseSensitive: false),
          '',
        )
        .trim();
    if (beforeChannelStripLength != cleanedContent.length) {
      talker.info(
        '🧹 Removed leaked channel-thought text from assistant response',
      );
    }

    // Strip embedded base64 data URIs (e.g. chart images [here](data:;base64,...)) to prevent
    // bloating conversation history sent to the LLM on subsequent turns.
    cleanedContent = _stripEmbeddedBase64(cleanedContent);

    // Remove excessive whitespace and empty lines
    cleanedContent = cleanedContent.replaceAll(RegExp(r'\n\s*\n\s*\n'), '\n\n');
    cleanedContent = cleanedContent.trim();

    // AUTO-FIX: If LLM forgot to add filelist:// marker, detect file lists and add it
    // Check if response looks like a file list without the marker
    if (!cleanedContent.contains('filelist://')) {
      // Check if last tool was a content-search tool (returns results with snippets, not file lists)
      // Drive tools like search_drive and list_drive_folder return actual file lists that SHOULD be converted
      // SSH tools return REMOTE file paths — never treat these as local downloadable files
      const contentSearchTools = [
        'search_documents',
        'search_gmail',
        'web_search',
        'search_websites',
      ];
      const remoteFilesTools = [
        'list_directory',
        'execute_command',
        'run_script',
        'read_file',
        'download_file',
        'upload_file',
        'list_scripts',
      ];
      final isContentSearchTool = contentSearchTools.contains(
        _lastCalledToolName,
      );
      final isRemoteFilesTool = remoteFilesTools.contains(_lastCalledToolName);

      if (isContentSearchTool) {
        talker.info(
          'Last tool was a content-search tool ($_lastCalledToolName) - keeping as search results, NOT converting to file list',
        );
        return cleanedContent; // Keep as-is for search results
      }

      if (isRemoteFilesTool) {
        talker.info(
          'Last tool was a remote-files tool ($_lastCalledToolName) - paths are remote, NOT converting to local file list',
        );
        return cleanedContent; // Keep as-is for remote (SSH) results
      }

      // Pattern: Lines that look like file paths (contain / or \, have extension like .docx, .pdf, etc.)
      final lines = cleanedContent.split('\n');
      var consecutiveFilePaths = 0;
      var firstFileLineIndex = -1;
      var hasNonFileContent = false;

      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trim();
        // Remove markdown list markers
        final cleanLine = line.replaceAll(RegExp(r'^\*\s*|\*\*|`'), '').trim();

        // Skip empty lines
        if (cleanLine.isEmpty) continue;

        // Check if line looks like a file path
        if (cleanLine.contains('/') || cleanLine.contains('\\')) {
          final hasExtension = RegExp(
            r'\.(docx?|xlsx?|pptx?|pdf|txt|json|xml|csv|log|md)$',
            caseSensitive: false,
          ).hasMatch(cleanLine);
          if (hasExtension) {
            if (firstFileLineIndex == -1) firstFileLineIndex = i;
            consecutiveFilePaths++;
          }
        } else if (cleanLine.length > 20) {
          // Line has substantial non-file content
          hasNonFileContent = true;
        }
      }

      // Only convert to file list if we have at least 2 file paths and minimal other content
      if (consecutiveFilePaths >= 2 && !hasNonFileContent) {
        talker.info(
          'ðŸ”§ AUTO-FIX: Detected file list without filelist:// marker (found $consecutiveFilePaths file paths)',
        );

        // Extract just the file paths
        final filePaths = <String>[];
        for (final line in lines) {
          final cleanLine = line
              .replaceAll(RegExp(r'^\*\s*|\*\*|`'), '')
              .trim();
          if ((cleanLine.contains('/') || cleanLine.contains('\\')) &&
              RegExp(
                r'\.(docx?|xlsx?|pptx?|pdf|txt|json|xml|csv|log|md)$',
                caseSensitive: false,
              ).hasMatch(cleanLine)) {
            filePaths.add(cleanLine);
          }
        }

        // Rebuild response with filelist:// marker
        cleanedContent = 'filelist://\n${filePaths.join('\n')}';
        talker.info(
          ' AUTO-FIX: Added filelist:// marker to response with ${filePaths.length} files',
        );
      }
    }

    return cleanedContent;
  }

  /// Initialize tool router in background for semantic filtering
  Future<void> _initializeToolRouter() async {
    // Check if router exists and was initialized with the current tool count
    if (_toolRouter != null &&
        _toolRouterToolCount == mcpClient.availableTools.length) {
      talker.info(
        ' Tool router already initialized with $_toolRouterToolCount tools',
      );
      return;
    }

    // If tool count changed, reinitialize
    if (_toolRouter != null &&
        _toolRouterToolCount != mcpClient.availableTools.length) {
      talker.info(
        'ðŸ”„ Tool count changed from $_toolRouterToolCount to ${mcpClient.availableTools.length}, reinitializing router...',
      );
      _toolRouter = null; // Reset to trigger reinitialization
    }

    try {
      _isInitializingSemanticFiltering = true;
      _semanticFilteringStatus =
          'Initializing server-side semantic filtering...';
      notifyListeners();

      talker.info('ðŸ§  Semantic filtering initializing (server-side)...');

      // Fetch tools with pre-computed embeddings from embedding server
      _semanticFilteringStatus =
          'Fetching pre-computed tool embeddings from server...';
      notifyListeners();

      final toolsWithEmbeddings = await mcpClient.availableToolsWithEmbeddings;
      final toolDefs = ToolRouter.fromMCPTools(toolsWithEmbeddings);

      _toolRouter = ToolRouter(toolDefs);

      _semanticFilteringStatus =
          'Keyword-based tool filtering for ${toolDefs.length} tools...';
      notifyListeners();

      _toolRouterToolCount = toolsWithEmbeddings.length; // Store count
      _isInitializingSemanticFiltering = false;
      _isWaitingForServers = false; // Clear waiting state
      _semanticFilteringStatus = '';
      talker.info('Semantic filtering ready with $_toolRouterToolCount tools');

      // Force immediate UI update
      notifyListeners();

      // Give UI thread a chance to process the update
      await Future.delayed(Duration.zero);

      talker.info('$_toolRouterToolCount tools loaded');
    } catch (e, stack) {
      _isInitializingSemanticFiltering = false;
      _isWaitingForServers = false; // Clear waiting state on error too
      _semanticFilteringStatus = '';
      notifyListeners();

      talker.error('Failed to initialize tool router: $e');
      talker.error('Stack: $stack');
      _toolRouter = null; // Reset on error
    }
  }

  /// Initialize chat with system message about available tools
  Future<void> _initializeChat() async {
    talker.info(
      'ðŸ”§ _initializeChat: Starting... Available tools: ${mcpClient.availableTools.length}',
    );

    // Guard: Don't initialize if already primed
    if (_isConversationPrimed) {
      talker.info('â­ï¸ _initializeChat: Already primed, skipping');
      return;
    }

    if (mcpClient.availableTools.isNotEmpty) {
      talker.info(
        ' _initializeChat: Tools available, checking if priming needed...',
      );

      final currentProvider = llmService.currentProvider;
      final supportsNativeTools = _providerSupportsNativeTools(currentProvider);

      final routedEmbeddedViaOpenAiCompatible =
          currentProvider == LLMProvider.openaiCompatible &&
          llmService.currentModel.toLowerCase().endsWith('.gguf');

      if (supportsNativeTools &&
          currentProvider != LLMProvider.gemini &&
          currentProvider != LLMProvider.embedded &&
          currentProvider != LLMProvider.openaiCompatible &&
          !routedEmbeddedViaOpenAiCompatible) {
        // For native tool calling providers (OpenAI, Claude):
        // Send a standalone "priming" message with system prompt ONLY (no user message, no tools)
        // This initializes the conversation context without increasing per-message overhead
        //
        // IMPORTANT: Gemini is excluded:
        // - Gemini requires at least one user message (will throw "contents is not specified" error)
        talker.info(
          'ðŸŽ¯ Native tool calling provider detected - sending priming message',
        );
        // CRITICAL: Must await priming to complete before user can send messages
        // Otherwise first message will be sent WITHOUT system prompt/tool capabilities
        await _sendPrimingMessage();
      } else if (currentProvider == LLMProvider.gemini ||
          currentProvider == LLMProvider.embedded ||
          currentProvider == LLMProvider.openaiCompatible ||
          routedEmbeddedViaOpenAiCompatible) {
        // For Gemini, Embedded, and OpenAI-compatible: Don't send priming message, system prompt will be sent with first user message.
        // Also skip priming when OpenAI-compatible transport uses a GGUF model because
        // server-side embedded auto-routing rejects system-only priming requests.
        final reason = routedEmbeddedViaOpenAiCompatible
            ? 'openai-compatible + GGUF model (server embedded auto-route)'
            : currentProvider.name;
        talker.info(
          'ðŸŽ¯ $reason detected - skipping priming (system prompt will be sent with first user message)',
        );
        _isConversationPrimed =
            true; // Mark as primed to avoid repeated attempts
      } else {
        // For non-native providers: use traditional system prompt approach
        // Reload warmup if model changed
        final currentModel = llmService.currentModel.toLowerCase();
        if (currentModel != _lastLoadedModel) {
          talker.info('ðŸ”„ Model changed, reloading warmup prompt...');
          await _loadWarmupPrompt();
        }

        const includeWarmup = true;
        final systemPromptContent = _buildSystemPrompt(
          includeWarmup: includeWarmup,
        );

        final systemMessage = ChatMessage(
          id: _uuid.v4(),
          content: systemPromptContent,
          role: ChatRole.system,
          timestamp: DateTime.now(),
          availableTools: mcpClient.availableTools,
          actionType: _internalSystemPromptActionType,
        );

        _addMessage(systemMessage);
        talker.info(
          ' _initializeChat: System message added with ${mcpClient.availableTools.length} tools',
        );
      }
    } else {
      talker.warning(
        'âš ï¸ _initializeChat: No tools available, skipping system prompt',
      );
    }
  }

  /// Prepare conversation for native tool calling providers
  /// Sends system + warmup prompt WITHOUT tools to initialize the conversation
  Future<void> _sendPrimingMessage() async {
    talker.info('ðŸŽ¯ Sending priming message (system + warmup, NO tools)');

    // Set priming flag to show UI feedback
    _isPriming = true;
    notifyListeners();

    // Reload warmup if model changed
    final currentModel = llmService.currentModel.toLowerCase();
    if (currentModel != _lastLoadedModel) {
      talker.info('ðŸ”„ Model changed, reloading warmup prompt...');
      await _loadWarmupPrompt();
    }

    // Build system prompt with warmup but NO tools
    final systemPromptContent = _buildSystemPrompt(includeWarmup: true);

    final primingMessage = ChatMessage(
      id: _uuid.v4(),
      content: systemPromptContent,
      role: ChatRole.system,
      timestamp: DateTime.now(),
    );

    try {
      // Send ONLY system prompt to LLM (no user message, no tools)
      // Note: We don't add this to _messages here because it will be added
      // with the first user message when the conversation actually starts
      await llmService.generateChatCompletion(
        messages: [primingMessage],
        availableTools: [], // NO TOOLS during priming
      );

      talker.info(
        ' Priming complete - LLM initialized with system prompt (no tools)',
      );
      _isConversationPrimed = true;
    } catch (e) {
      talker.error(' Priming failed: $e');
      // Show error to user
      final errorMessage = ChatMessage(
        id: _uuid.v4(),
        content: 'Failed to initialize chat: ${e.toString().split('\n').first}',
        role: ChatRole.system,
        timestamp: DateTime.now(),
      );
      _addMessage(errorMessage);
      // Don't set _isConversationPrimed - will retry with first user message
    } finally {
      // Clear priming flag
      _isPriming = false;
      if (!_isDisposed) notifyListeners();
    }
  }

  /// Load warmup prompt from assets
  Future<void> _loadWarmupPrompt() async {
    try {
      talker.info('ðŸ” _loadWarmupPrompt: Starting...');

      // Detect current model for model-specific prompts
      final modelName = llmService.currentModel.toLowerCase();
      _lastLoadedModel = modelName; // Track loaded model

      // STEP 1: Call plugin's reloadPromptsForModel to load model-specific prompts
      if (reloadPluginPrompts != null) {
        talker.info('ðŸ“ž Calling plugin.reloadPromptsForModel($modelName)');
        await reloadPluginPrompts!(modelName);
        talker.info('âœ… Plugin prompts reloaded for model');
      } else {
        talker.warning(
          'âš ï¸ reloadPluginPrompts callback is NULL - cannot reload model-specific prompts',
        );
      }

      // STEP 2: Get warmup prompt from plugin (now loaded with model-specific version)
      if (getWarmupPrompt != null) {
        talker.info(
          'ðŸ“ž _loadWarmupPrompt: Calling getWarmupPrompt callback...',
        );
        _warmupPrompt = getWarmupPrompt!();
        talker.info(
          'ðŸ“¥ _loadWarmupPrompt: Received warmup: ${_warmupPrompt?.length ?? 0} chars',
        );
        if (_warmupPrompt != null && _warmupPrompt!.isNotEmpty) {
          talker.info(
            'âœ… Warmup prompt loaded from plugin: ${_warmupPrompt!.length} chars',
          );
        } else {
          talker.warning('âš ï¸ _loadWarmupPrompt: Warmup was null or empty');
        }
      } else {
        talker.warning(
          'âš ï¸ _loadWarmupPrompt: getWarmupPrompt callback is NULL',
        );
      }
    } catch (e) {
      talker.warning('âš ï¸ Failed to load warmup prompt: $e');
      _warmupPrompt = null;
    }
  }

  /// Build system prompt with available MCP tools.
  /// [pluginSystemPromptOverride] replaces the plugin's own systemPrompt for this call only.
  String _buildSystemPrompt({
    bool includeWarmup = true,
    String? pluginSystemPromptOverride,
  }) {
    // Chat mode: no system prompt at all — raw LLM completion
    if (chatMode) return '';

    final buffer = StringBuffer();

    // Get current provider for provider-specific logic
    final currentProvider = llmService.currentProvider;
    final currentModelLower = llmService.currentModel.toLowerCase();
    final isMistralPrompt =
        currentProvider == LLMProvider.openaiCompatible &&
        currentModelLower.contains('mistral');

    // CRITICAL: System prompt MUST come BEFORE warmup
    // System prompt contains the rules, warmup demonstrates the pattern
    // This order is essential for prompt caching and autonomous chaining

    // Debug: Log SLM detection
    talker.info(
      '🔍 SLM Check: provider=$currentProvider, model=$currentModelLower',
    );
    talker.info(
      '🔍 isSlm=${llmService.isSlm}, useSimplifiedPrompts=${llmService.useSimplifiedPrompts}',
    );

    final stepEnabledTools = _subPromptEnabledTools;
    final bool hasTools = stepEnabledTools != null
        ? stepEnabledTools.isNotEmpty
        : mcpClient.availableTools.isNotEmpty;

    if (includeWarmup &&
        (llmService.useSimplifiedPrompts || llmService.isSlm)) {
      talker.info('🤏 Using SLM system prompt (hasTools=$hasTools)');
      final now = DateTime.now();
      final weekdays = [
        'Monday',
        'Tuesday',
        'Wednesday',
        'Thursday',
        'Friday',
        'Saturday',
        'Sunday',
      ];
      final months = [
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
      if (hasTools) {
        buffer.writeln('You are a helpful AI assistant with access to tools.');
        buffer.writeln();
        buffer.writeln('RULES (follow strictly):');
        buffer.writeln(
          '1. When the user asks for information or an action, CALL A TOOL IMMEDIATELY. Do NOT write "I will first…" or describe what you plan to do.',
        );
        buffer.writeln('2. Never say "I will call tool X". Just call it.');
        buffer.writeln(
          '3. After you receive a tool result, use it to answer the user directly and concisely.',
        );
        buffer.writeln('4. If no tool is needed, answer directly.');
        buffer.writeln(
          '5. Do not repeat tool call arguments in your final reply.',
        );
        buffer.writeln(
          '6. When a tool has parameters, extract ALL values the user provided and pass them as arguments. '
          'Example: user says "folder C:\\temp, months 6" → call with {"folder":"C:\\\\temp","months":6}. '
          'Never call with empty {} if the user gave values. '
          'For OPTIONAL parameters: include them only when the user explicitly asked/provided them, '
          'or when Tool Hints/input schema defines a default value for that parameter. '
          'Do not invent optional values.',
        );
        buffer.writeln(
          '7. Each tool execution result is returned in a JSON structure: {"tool": "name", "id": "unique_id", "tool_executed": true, "tool_result": ...}. '
          'Once a tool has been successfully executed (tool_executed is true), you must NEVER call that tool with the same "id" or parameters again. '
          'Instead, formulate your final response to the user using the result provided in tool_result.',
        );
        buffer.writeln();
        buffer.writeln('TOOL CALL FORMAT (use this exact format):');
        buffer.writeln(
          'tool_call: {"name": "tool_name", "arguments": {"param1": "value1", "param2": 123}}',
        );
        buffer.writeln(
          'Always use this JSON format. Do not use alternative formats.',
        );
      } else {
        buffer.writeln('You are a helpful AI assistant.');
        buffer.writeln();
        buffer.writeln('RULES (follow strictly):');
        buffer.writeln(
          '1. Answer the user directly, concisely, and accurately.',
        );
        buffer.writeln(
          '2. Answer directly based on the provided conversation context. Do not make any tool calls or write "tool_call".',
        );
      }
      buffer.writeln();
      buffer.writeln(
        'TODAY: ${weekdays[now.weekday - 1]}, ${now.day} ${months[now.month - 1]} ${now.year}, ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')} local time.',
      );
      buffer.writeln();
      // Include any plugin system prompt so task-specific instructions still apply
      if (getPluginPrompts != null) {
        final pluginPrompts = getPluginPrompts!();
        if (pluginPrompts != null) {
          String base =
              (pluginSystemPromptOverride ?? pluginPrompts.systemPrompt)
                  ?.trim() ??
              '';
          // Strip any pre-baked "Tool Hints:" or "Tool Skills:" block — SLMs receive compact TOOL PARAMETERS below.
          var skillsIdx = base.lastIndexOf('\n\nTool Hints:');
          if (skillsIdx < 0) {
            skillsIdx = base.lastIndexOf('\n\nTool Skills:');
          }
          if (skillsIdx >= 0) {
            base = base.substring(0, skillsIdx).trim();
          } else if (base.startsWith('Tool Hints:') || base.startsWith('Tool Skills:')) {
            base = '';
          }
          if (base.isNotEmpty) {
            buffer.writeln('---');
            buffer.writeln(base);
            buffer.writeln();
          }
        }
      }
      // Compact plain-text tool parameter listing — helps small models map user
      // natural language values to the correct JSON argument keys.
      // When a sub-prompt step restricts tools, only list those tools to save tokens.
      if (hasTools) {
        final toolsWithParams = mcpClient.availableTools.where((t) {
          if (stepEnabledTools != null && !stepEnabledTools.contains(t.name)) {
            return false;
          }
          final props = t.inputSchema?['properties'];
          return props is Map && (props).isNotEmpty;
        }).toList();
        if (toolsWithParams.isNotEmpty) {
          buffer.writeln('═══════════════════════════════════════════════');
          buffer.writeln(
            '🔧 TOOL CALL FORMAT (use this format if tool call is needed):',
          );
          buffer.writeln(
            'tool_call: {"name": "tool_name", "arguments": {"param1": "value1", "param2": 123}}',
          );
          buffer.writeln(
            '⚠️  Always use this JSON format. Do NOT use key=value format.',
          );
          buffer.writeln('═══════════════════════════════════════════════');
          buffer.writeln();
          buffer.writeln(
            'TOOL PARAMETERS (use these key names in tool arguments):',
          );
          for (final tool in toolsWithParams) {
            final props = (tool.inputSchema!['properties'] as Map)
                .cast<String, dynamic>();
            final required =
                ((tool.inputSchema!['required'] as List?)?.cast<String>() ?? [])
                    .toSet();
            final params = props.entries
                .map((e) {
                  final def = (e.value as Map).cast<String, dynamic>();
                  final type = def['type'] as String? ?? 'string';
                  final desc = def['description'] as String?;
                  final opt = required.contains(e.key) ? '' : '?';
                  return '${e.key}$opt:$type${desc != null ? '($desc)' : ''}';
                })
                .join(', ');
            buffer.writeln('${tool.name}: $params');
          }
          buffer.writeln();
        }
      }
      if (LlmSettingsService.instance.injectToolCallingRules) {
        buffer.writeln(kToolCallingRulesInstructions);
        buffer.writeln();
      }
      return buffer.toString();
    }

    // STEP 1: Add system prompt (now includes model-specific version from plugin)
    if (getPluginPrompts != null) {
      talker.info(
        '🔍 _buildSystemPrompt: Calling getPluginPrompts callback...',
      );
      final pluginPrompts = getPluginPrompts!();
      talker.info(
        '📥 _buildSystemPrompt: Received pluginPrompts: ${pluginPrompts != null ? "NOT NULL" : "NULL"}',
      );
      if (pluginPrompts != null) {
        final basePrompt =
            pluginSystemPromptOverride ?? pluginPrompts.systemPrompt ?? '';
        talker.info(
          'Adding PLUGIN system prompt FIRST (${basePrompt.length} chars)',
        );
        buffer.writeln(basePrompt);
        buffer.writeln();
        if (hasTools) {
          buffer.writeln('═══════════════════════════════════════════════');
          buffer.writeln(
            '🔧 TOOL CALL FORMAT (use this format if tool call is needed):',
          );
          buffer.writeln(
            'tool_call: {"name": "tool_name", "arguments": {"param1": "value1", "param2": 123}}',
          );
          buffer.writeln(
            '⚠️  Always use this JSON format. Do NOT use key=value format.',
          );
          buffer.writeln('═══════════════════════════════════════════════');
          buffer.writeln();
        }
        buffer.writeln('---');
        buffer.writeln();
      } else {
        talker.warning('⚠️  Plugin prompts getter returned NULL!');
        buffer.writeln(
          'You are a helpful AI assistant. You can engage in natural conversations, answer questions, and help with various tasks.',
        );
        buffer.writeln();
        buffer.writeln('---');
        buffer.writeln();
      }
    } else {
      talker.warning(
        '⚠️  getPluginPrompts is NULL and no model-specific system prompt!',
      );
      buffer.writeln(
        'You are a helpful AI assistant. You can engage in natural conversations, answer questions, and help with various tasks.',
      );
      buffer.writeln();
      buffer.writeln('---');
      buffer.writeln();
    }

    // STEP 2: Add warmup examples AFTER system prompt (if requested)
    if (includeWarmup && _warmupPrompt != null && _warmupPrompt!.isNotEmpty) {
      talker.info(
        'ðŸ“š Adding warmup examples AFTER system prompt (${_warmupPrompt!.length} chars)',
      );
      buffer.writeln(_warmupPrompt);
      buffer.writeln();
      buffer.writeln('---');
      buffer.writeln();
    } else if (!includeWarmup) {
      talker.info('â­ï¸ Skipping warmup prompt (includeWarmup=false)');
    } else {
      talker.warning('âš ï¸ Warmup prompt is NULL or empty!');
    }

    // Add tool usage guidance for native tool calling providers
    if (currentProvider == LLMProvider.openai ||
        currentProvider == LLMProvider.gemini ||
        currentProvider == LLMProvider.ollama ||
        currentProvider == LLMProvider.openaiCompatible) {
      buffer.writeln();
    }

    // Add tool-aware email hints
    final toolNames = mcpClient.availableTools.map((t) => t.name).toSet();
    final hasGmail = toolNames.any((n) => n.contains('gmail'));
    final hasImap = toolNames.any(
      (n) => n == 'search_emails' || n == 'list_folders' || n == 'read_email',
    );
    if (hasGmail) {
      buffer.writeln(
        'For email requests, use Gmail tools (search_gmail, get_gmail_message).',
      );
      buffer.writeln(
        'When the user wants to read, extract or summarize email content, always call search_gmail with includeBody:true so the full text is available.',
      );
      buffer.writeln(
        'Gmail q parameter supports: from:, to:, subject:, after:YYYY/MM/DD, before:YYYY/MM/DD, newer_than:Nd, older_than:Nd, has:attachment, is:unread.',
      );
    }
    if (hasImap) {
      buffer.writeln(
        'For email requests, use IMAP tools (search_emails, read_email, list_folders).',
      );
      buffer.writeln(
        'search_emails supports filters: from, to, subject, body, since/before (YYYY-MM-DD format), unseen (bool), folder (default INBOX), maxResults.',
      );
      buffer.writeln(
        'After search_emails, call read_email with the uid and folder from the result to get the full email body.',
      );
      buffer.writeln(
        'For since/before date filters, derive YYYY-MM-DD values from the CURRENT DATE/TIME already provided above — do not call any time tool.',
      );
    }
    if (!hasGmail && !hasImap) {
      buffer.writeln(
        'For email requests, use available email tools if present.',
      );
    }
    buffer.writeln(
      'For document requests, use document/drive tools when available.',
    );
    buffer.writeln(
      'If no relevant tool exists, then explain the limitation briefly.',
    );
    buffer.writeln();

    // Add user location context if available and location tools are present
    final position = locationService.lastKnownPosition;
    bool hasLocationTool = false;
    if (_subPromptEnabledTools != null) {
      hasLocationTool = _subPromptEnabledTools!.any(
        (name) => name == 'get_current_location' || name == 'geocode_city',
      );
    } else {
      hasLocationTool = mcpClient.availableTools.any(
        (t) => t.name == 'get_current_location' || t.name == 'geocode_city',
      );
    }
    if (position != null && hasLocationTool) {
      buffer.writeln(
        'USER LOCATION: The user is currently at coordinates ${position.latitude.toStringAsFixed(5)}, ${position.longitude.toStringAsFixed(5)}',
      );
      buffer.writeln(
        'When the user asks for "devices near me", "my location", or "current location", use these coordinates.',
      );
      buffer.writeln(
        'IMPORTANT: For travel searches (flights, trains, hotels, restaurants, weather, etc.) that require a city name, region, or airport code, '
        'first determine the nearest city and airport from these coordinates — do NOT use a default or example city like Los Angeles. '
        'Always derive the departure location from the user\'s actual coordinates.',
      );
      buffer.writeln();
    }

    // Inject current date/time so the LLM never needs to ask the user for it
    final now = DateTime.now();
    final weekdays = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    final months = [
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
    buffer.writeln(
      'CURRENT DATE/TIME: ${weekdays[now.weekday - 1]}, ${now.day} ${months[now.month - 1]} ${now.year}, '
      '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')} local time. '
      'Use this for any date calculations ("last 7 days", "next week", "today", etc.) — never ask the user for the current date. '
      'Do NOT call get_current_time or any other tool to obtain the current date/time; it is already provided here.',
    );
    buffer.writeln();

    // Note: Tool list is NOT included in system prompt since tools are sent via native API
    // Gemini receives tool definitions separately with each request
    buffer.writeln(
      'CAPABILITY POLICY: Determine what you can do from the provided tools at runtime, not from role wording.',
    );
    buffer.writeln('Do NOT claim inability if a relevant tool is available.');

    buffer.writeln(
      'You have access to tools for data retrieval and processing.',
    );
    buffer.writeln('Use them appropriately based on user requests.');
    buffer.writeln(
      'When building tool arguments: include required parameters always; include optional parameters only if '
      'the user explicitly requested/provided them or if the tool skill/schema defines a default value. '
      'Never fabricate optional values.',
    );
    buffer.writeln(
      'If you must emit a text fallback tool call instead of a native function call, the arguments must still be a valid JSON object. '
      'Do not write parameters as free-form key=value text.',
    );
    buffer.writeln();

    if (isMistralPrompt) {
      buffer.writeln('MISTRAL TOOL-CALLING RULES (STRICT):');
      buffer.writeln(
        '- If a tool result message is present, the tool call is already completed.',
      );
      buffer.writeln(
        '- Never say "I will continue once it completes" when a tool result exists.',
      );
      buffer.writeln(
        '- Use the latest tool result content immediately to provide the final answer now.',
      );
      buffer.writeln(
        '- Do NOT repeat an identical tool call with identical arguments unless user explicitly asks to rerun it.',
      );
      buffer.writeln(
        '- If result is unclear, ask one concise clarification question instead of re-calling the same tool.',
      );
      buffer.writeln();
    }

    // Append available tools and their parameters if native tool calling is disabled.
    final supportsNativeTools = _providerSupportsNativeTools(currentProvider);
    if (!supportsNativeTools) {
      final stepEnabledTools = _subPromptEnabledTools;
      final toolsToInject = mcpClient.availableTools.where((t) {
        if (stepEnabledTools != null && !stepEnabledTools.contains(t.name)) {
          return false;
        }
        return true;
      }).toList();

      if (toolsToInject.isNotEmpty) {
        buffer.writeln('═══════════════════════════════════════════════');
        buffer.writeln('🔧 AVAILABLE TOOLS AND PARAMETERS:');
        buffer.writeln('═══════════════════════════════════════════════');
        for (final tool in toolsToInject) {
          buffer.writeln('Tool: ${tool.name}');
          if (tool.description != null && tool.description!.isNotEmpty) {
            buffer.writeln('Description: ${tool.description}');
          }
          final props = tool.inputSchema?['properties'];
          if (props is Map && props.isNotEmpty) {
            buffer.writeln('Parameters:');
            final required =
                ((tool.inputSchema!['required'] as List?)?.cast<String>() ?? [])
                    .toSet();
            for (final entry in (props).entries) {
              final paramName = entry.key as String;
              final paramDef =
                  (entry.value as Map<dynamic, dynamic>?)
                      ?.cast<String, dynamic>() ??
                  {};
              final type = paramDef['type'] as String? ?? 'any';
              final desc = paramDef['description'] as String? ?? '';
              final isRequired = required.contains(paramName)
                  ? 'required'
                  : 'optional';
              buffer.writeln('  - $paramName ($type, $isRequired): $desc');
            }
          } else {
            buffer.writeln('Parameters: none');
          }
          buffer.writeln();
        }
      }
    }

    // Append tool loop prevention instructions to standard system prompt
    buffer.writeln('STRICT TOOL CALL LOOPS PREVENTION RULES:');
    buffer.writeln(
      '1. Each tool result you receive is wrapped in a JSON structure: {"tool": "name", "id": "unique_id", "tool_executed": true, "tool_result": ...}.',
    );
    buffer.writeln(
      '2. Once a tool call has been executed successfully (you see "tool_executed": true for a specific "id" or parameter combination), you must NEVER call that tool with the same "id" or same arguments again.',
    );
    buffer.writeln(
      '3. Instead of repeating the tool call, use the tool results already present in the chat history to formulate your final response to the user.',
    );
    buffer.writeln();

    if (LlmSettingsService.instance.injectToolCallingRules) {
      buffer.writeln(kToolCallingRulesInstructions);
      buffer.writeln();
    }

    final finalPrompt = buffer.toString();
    talker.info('ðŸ“ Total system prompt length: ${finalPrompt.length} chars');

    return finalPrompt;
  }

  /// Execute a tool directly without LLM (for button actions)
  Future<void> executeDirectToolCall({
    required String toolName,
    required Map<String, dynamic> arguments,
    required String userPrompt,
  }) async {
    if (isProcessing) {
      throw Exception('Already processing a message');
    }

    _processingType = ProcessingType.mcp;
    notifyListeners();

    try {
      // Add user message to show what action was requested (except for downloads - they have their own widget)
      if (toolName != 'download_file') {
        final userMessage = ChatMessage(
          id: _uuid.v4(),
          content: userPrompt,
          role: ChatRole.user,
          timestamp: DateTime.now(),
          availableTools: mcpClient.availableTools.toList(),
        );

        _addMessage(userMessage);
      } else {
        talker.info(
          'Skipping user message for download_file - download widget will show progress',
        );
      }

      // Special handling for download_file with chunked download service
      MCPToolResult toolResult;
      if (toolName == 'download_file') {
        if (_fileDownloadService != null) {
          talker.info(
            'Using FileDownloadService for chunked download (executeTool)',
          );
          try {
            toolResult = await _executeChunkedDownload(arguments);
            talker.info(' _executeChunkedDownload completed successfully');
          } catch (downloadError, downloadStack) {
            talker.error(' _executeChunkedDownload threw exception!');
            talker.error('Error: $downloadError');
            talker.error('Stack: $downloadStack');

            final errorMessage = ChatMessage(
              id: _uuid.v4(),
              content: 'Error executing $toolName: $downloadError',
              role: ChatRole.assistant,
              timestamp: DateTime.now(),
            );
            _addMessage(errorMessage);
            return;
          }
        } else {
          talker.warning(
            'âš ï¸ FileDownloadService is null! Using direct MCP call (executeTool)',
          );
          toolResult = await mcpClient.callTool(toolName, arguments);
        }
      } else {
        // Create and execute the tool call directly
        toolResult = await mcpClient.callTool(toolName, arguments);
      }

      if (toolResult.isError) {
        talker.error(' Tool result has isError=true');
        talker.error(
          'Tool result content: ${toolResult.content.firstOrNull?.text}',
        );

        final errorMessage = ChatMessage(
          id: _uuid.v4(),
          content:
              'Error executing $toolName: ${toolResult.content.firstOrNull?.text ?? "Tool execution failed"}',
          role: ChatRole.assistant,
          timestamp: DateTime.now(),
        );
        _addMessage(errorMessage);
        return;
      }

      // Skip LLM follow-up for download_file (we already show progress messages)
      if (toolName == 'download_file') {
        talker.info(
          'Skipping LLM follow-up and tool message for download_file - progress widget already shown',
        );
        return;
      }

      // Add a tool message first (hidden from UI unless debug mode is on)
      if (_showToolMessages) {
        final toolMessage = ChatMessage(
          id: _uuid.v4(),
          content:
              'Called tool: $toolName\nArguments: ${jsonEncode(arguments)}',
          role: ChatRole.tool,
          timestamp: DateTime.now(),
          toolResult: toolResult,
        );
        _addMessage(toolMessage);
      }

      // Generate LLM follow-up response like the normal flow does
      await _generateDirectToolFollowUp(
        toolName,
        toolResult,
        userPrompt,
        arguments,
      );
    } catch (e) {
      final errorMessage = ChatMessage(
        id: _uuid.v4(),
        content: 'Error executing tool: ${e.toString()}',
        role: ChatRole.assistant,
        timestamp: DateTime.now(),
      );
      _addMessage(errorMessage);
      talker.error('Direct tool execution error: $e');
    } finally {
      _processingType = ProcessingType.none;
      notifyListeners();
    }
  }

  /// Check if a prompt should be handled as a direct tool call
  Map<String, dynamic>? _getDirectActionForPrompt(String content) {
    final lowerContent = content.toLowerCase().trim();

    talker.info('Checking for direct action. Content: "$lowerContent"');

    // Check for download file request
    if (content.startsWith('Download file: ')) {
      final filePath = content.substring('Download file: '.length).trim();
      talker.info('Direct action matched: download_file with path: $filePath');
      return {
        'tool': 'download_file',
        'arguments': {'file_path': filePath, 'as_base64': true},
      };
    }

    // Map German and English prompts to direct tool calls
    if (lowerContent == 'alle aktiven gerÃ¤te abrufen' ||
        lowerContent == 'get all active devices') {
      talker.info('Direct action matched: get_all_devices');
      return {
        'tool': 'get_all_devices',
        'arguments': {'onlyActives': '1'},
      };
    }

    if (lowerContent.startsWith('get devices around') ||
        lowerContent.startsWith('gerÃ¤te um')) {
      // For location-based queries, we still need LLM to convert location to coordinates
      return null;
    }

    talker.info('No direct action matched, will use LLM');
    // Add more direct mappings as needed
    return null;
  }

  /// Generate LLM follow-up response for direct tool execution
  Future<void> _generateDirectToolFollowUp(
    String toolName,
    MCPToolResult toolResult,
    String originalPrompt, [
    Map<String, dynamic>? toolArguments,
  ]) async {
    talker.info(
      'Generating LLM follow-up for direct tool execution: $toolName',
    );

    try {
      // Build context for the LLM about what tool was executed and what data it returned
      final contextMessages = <ChatMessage>[
        ChatMessage(
          id: _uuid.v4(),
          content: 'User requested: $originalPrompt',
          role: ChatRole.user,
          timestamp: DateTime.now(),
        ),
        ChatMessage(
          id: _uuid.v4(),
          content:
              'I executed the tool "$toolName" and got the following result data. Please provide a comprehensive and user-friendly summary of this information.',
          role: ChatRole.assistant,
          timestamp: DateTime.now(),
        ),
      ];

      // Add tool result context - FILTER OUT BINARY CONTENT!
      final toolResultText = toolResult.content
          .where((content) {
            // CRITICAL: Exclude if has binary data field
            if (content.data != null && content.data!.isNotEmpty) {
              talker.warning(
                'ðŸš« Filtered binary DATA field from direct follow-up: ${content.data!.length} chars',
              );
              return false;
            }

            // Exclude binary content by MIME type
            if (content.mimeType != null) {
              final mime = content.mimeType!.toLowerCase();
              if (mime.startsWith(
                    'application/vnd.',
                  ) || // Office documents (Excel, Word, etc.)
                  mime.startsWith('application/octet-stream') ||
                  mime.startsWith('application/zip') ||
                  mime.startsWith('application/x-') ||
                  mime.contains('spreadsheet') ||
                  mime.contains('officedocument')) {
                talker.warning(
                  'ðŸš« Filtered binary MIME from direct follow-up: $mime',
                );
                return false;
              }
            }

            // Exclude if type is 'image'
            if (content.type == 'image') {
              talker.warning('ðŸš« Filtered image from direct follow-up');
              return false;
            }

            // Only include if has text
            final hasText = content.text != null && content.text!.isNotEmpty;
            if (!hasText) {
              talker.warning('ðŸš« Filtered content (no text)');
            }
            return hasText;
          })
          .map((content) {
            // CRITICAL: Strip binary content from JSON responses
            String text = content.text!;

            if (text.trimLeft().startsWith('{') && text.length > 10000) {
              try {
                final json = jsonDecode(text);
                if (json is Map &&
                    json['data'] is Map &&
                    json['data']['content'] is String) {
                  final contentLength =
                      (json['data']['content'] as String).length;
                  if (contentLength > 5000) {
                    talker.warning(
                      'STRIPPING $contentLength char binary from direct follow-up',
                    );

                    final summary = {
                      'success': json['success'],
                      'message':
                          'File ready. DO NOT generate binary/base64 content. Just confirm file availability.',
                    };

                    text = jsonEncode(summary);
                    talker.info(
                      'âœ… Replaced with ${text.length} char summary',
                    );
                  }
                }
              } catch (e) {
                // Keep original
              }
            }

            // Filter file lists - send only count to LLM, not full file list
            // Strip file output content (base64-encoded files from output:file)
            text = _stripFileOutputContent(text, toolArguments);
            final filtered = _filterFileListForLLM(
              MCPContent(
                type: content.type,
                text: text,
                mimeType: content.mimeType,
              ),
            );
            // Strip embedded base64 data URIs (e.g., [file.xlsx](data:...;base64,...))
            return _stripEmbeddedBase64(filtered.text!);
          })
          .join('\n');

      // Don't truncate - send full content to LLM
      // The maxToolOutputChars setting already handles size limits globally
      contextMessages.add(
        ChatMessage(
          id: _uuid.v4(),
          content: 'Tool result data:\n$toolResultText',
          role: ChatRole.user,
          timestamp: DateTime.now(),
        ),
      );

      // Get LLM response
      final llmResponse = await llmService.generateChatCompletion(
        messages: contextMessages,
      );

      // Check if tool result contains file list - if so, don't attach it to assistant message
      // to avoid showing files twice (once in tool result, once in assistant response)
      bool hasFileList = false;
      for (final content in toolResult.content) {
        final (isFileList, _) = _checkFileList(content);
        if (isFileList) {
          hasFileList = true;
          break;
        }
      }

      // Create the final assistant message with LLM response (cleaned of think blocks)
      final cleanedLLMResponse = _cleanAssistantResponse(llmResponse.content);
      final assistantMessage = ChatMessage(
        id: _uuid.v4(),
        content: cleanedLLMResponse,
        role: ChatRole.assistant,
        timestamp: DateTime.now(),
        toolResult: hasFileList
            ? null
            : toolResult, // Don't attach tool result if it's a file list (already shown in tool message)
      );

      _addMessage(assistantMessage);
    } catch (e) {
      talker.error('Failed to generate LLM follow-up for direct tool: $e');

      // Fallback to basic summary if LLM fails
      final fallbackMessage = ChatMessage(
        id: _uuid.v4(),
        content:
            'Tool executed successfully. The results are available in the expandable section below.',
        role: ChatRole.assistant,
        timestamp: DateTime.now(),
        toolResult: toolResult,
      );
      _addMessage(fallbackMessage);
    }
  }

  /// Send a user message and get AI response
  Future<void> sendMessage(String content) async {
    if (isProcessing) {
      throw Exception('Already processing a message');
    }

    // Reset tool iteration counter and last tool call for new user message
    _toolIterationCount = 0;
    _currentRetryCount = 0; // Reset retry counter for new user message
    _paramValidationRetryCount = 0; // Reset parameter validation retry counter
    _capabilityRefusalRetryCount = 0;
    _executedToolCallSignatures.clear();
    _executedToolCallIds.clear();

    // Check for <reset> token - strip it and flag for post-response reset
    if (content.trimRight().endsWith('<reset>')) {
      content = content
          .trimRight()
          .substring(0, content.trimRight().length - '<reset>'.length)
          .trimRight();
      _resetAfterResponse = true;
      talker.info(
        'ðŸ”„ <reset> token detected - will soft-reset after LLM response',
      );
    }

    // Log user prompt (first 100 chars)
    final promptPreview = content.length > 100
        ? '${content.substring(0, 100)}...'
        : content;
    talker.info('ðŸ“ User prompt: $promptPreview');

    // Sub-prompt sequence: split on ++#++[Nn]? (standalone line) and execute
    // sequentially. If the marker exists, always route through sub-prompt
    // processing, even for a single step.
    if (_subPromptSepRegex.hasMatch(content)) {
      final steps = parseWorkflowSteps(
        content,
      ).where((s) => s.text.isNotEmpty).toList();
      if (steps.isNotEmpty) {
        talker.info(
          'Processing as sub-prompt sequence (${steps.length} steps)',
        );
        await _processSubPrompts(steps);
        return;
      }
    }

    // Check if this is a direct action that should bypass LLM
    final directAction = _getDirectActionForPrompt(content);
    if (directAction != null) {
      await executeDirectToolCall(
        toolName: directAction['tool']!,
        arguments: directAction['arguments']!,
        userPrompt: content,
      );
      return;
    }

    _processingType = ProcessingType.llm;
    notifyListeners();

    try {
      final userMessage = ChatMessage(
        id: _uuid.v4(),
        content: content,
        role: ChatRole.user,
        timestamp: DateTime.now(),
        availableTools: mcpClient.availableTools.toList(),
      );

      _addMessage(userMessage);

      // Get LLM response with retry for UNEXPECTED_TOOL_CALL
      await _processLLMResponseWithRetry();
    } catch (e) {
      // Add user-friendly error message
      String errorText;
      if (e.toString().contains('API key')) {
        final prefs = await SharedPreferences.getInstance();
        final isServer = (prefs.getString('server_mode') ?? 'local') == 'remote';
        errorText = isServer
            ? 'Please configure your LLM API key in settings (tap the settings gear in the top bar).'
            : 'Please configure your LLM API key in settings (tap the AI icon in the top bar).';
      } else if (e.toString().contains('model') &&
          e.toString().contains('not found')) {
        errorText =
            'The selected AI model is not available. Please try a different model in settings.';
      } else if (e.toString().contains('504') ||
          e.toString().contains('Gateway Time-out')) {
        errorText =
            'â±ï¸ Request timeout: The AI model took too long to respond (>60s). This usually means:\n'
            '- The model is processing a very complex request\n'
            '- The server is overloaded\n'
            '- Try simplifying your request or try again later';
      } else if (e.toString().contains('overloaded')) {
        errorText =
            'The Gemini API is overloaded. The system already retried automatically 5 times. Please wait a few minutes and try again.';
      } else if (e.toString().contains('quota') ||
          e.toString().contains('limit')) {
        errorText =
            'API quota exceeded. Please check your API usage or try again later.';
      } else if (e.toString().contains('connection') ||
          e.toString().contains('network')) {
        errorText =
            'Network connection error. Please check your internet connection and try again.';
      } else {
        errorText =
            'AI Error: ${e.toString().replaceAll('Exception:', '').trim()}';
      }

      final errorMessage = ChatMessage(
        id: _uuid.v4(),
        content: errorText,
        role: ChatRole.assistant,
        timestamp: DateTime.now(),
      );

      _addMessage(errorMessage);
      talker.error('Chat error: $e');
    } finally {
      _processingType = ProcessingType.none;
      // Check if soft reset was requested via <reset> token
      if (_resetAfterResponse) {
        _resetAfterResponse = false;
        await softResetConversation();
      }
      notifyListeners();
    }
  }

  /// Send a ChatMessage object (supports multimedia) and get AI response
  Future<void> sendChatMessage(ChatMessage message) async {
    talker.info(
      'ðŸš€ sendChatMessage called: content="${message.content.substring(0, math.min(50, message.content.length))}..."',
    );

    if (isProcessing) {
      throw Exception('Already processing a message');
    }

    // Sub-prompt sequence: split on ++#++[Nn]? (standalone line) and execute
    // sequentially. If the marker exists, always route through sub-prompt
    // processing, even for a single step.
    if (_subPromptSepRegex.hasMatch(message.content)) {
      final steps = parseWorkflowSteps(
        message.content,
      ).where((s) => s.text.isNotEmpty).toList();
      if (steps.isNotEmpty) {
        talker.info(
          'Processing as sub-prompt sequence (${steps.length} steps)',
        );
        await _processSubPrompts(steps);
        return;
      }
    }

    // Check for <reset> token in message content
    if (message.content.trimRight().endsWith('<reset>')) {
      final strippedContent = message.content
          .trimRight()
          .substring(0, message.content.trimRight().length - '<reset>'.length)
          .trimRight();
      message = ChatMessage(
        id: message.id,
        content: strippedContent,
        role: message.role,
        timestamp: message.timestamp,
        availableTools: message.availableTools,
        toolResult: message.toolResult,
        attachments: message.attachments,
        type: message.type,
        lastCalledToolName: message.lastCalledToolName,
        processAsMultiStep: message.processAsMultiStep,
        actionType: message.actionType,
      );
      _resetAfterResponse = true;
      talker.info(
        'ðŸ”„ <reset> token detected in ChatMessage - will soft-reset after LLM response',
      );
    }

    talker.info('ðŸ’¬ Processing as single message');
    _processingType = ProcessingType.llm;
    notifyListeners();

    try {
      // Add user message
      _addMessage(message);

      // Get LLM response
      await _processLLMResponse();
    } catch (e) {
      // Add user-friendly error message
      String errorText;
      if (e.toString().contains('API key')) {
        final prefs = await SharedPreferences.getInstance();
        final isServer = (prefs.getString('server_mode') ?? 'local') == 'remote';
        errorText = isServer
            ? 'Please configure your LLM API key in settings (tap the settings gear in the top bar).'
            : 'Please configure your LLM API key in settings (tap the AI icon in the top bar).';
      } else if (e.toString().contains('model') &&
          e.toString().contains('not found')) {
        errorText =
            'The selected AI model is not available. Please try a different model in settings.';
      } else if (e.toString().contains('504') ||
          e.toString().contains('Gateway Time-out')) {
        errorText =
            'â±ï¸ Request timeout: The AI model took too long to respond (>60s). This usually means:\n'
            '- The model is processing a very complex request\n'
            '- The server is overloaded\n'
            '- Try simplifying your request or try again later';
      } else if (e.toString().contains('quota') ||
          e.toString().contains('limit')) {
        errorText =
            'API quota exceeded. Please check your API usage or try again later.';
      } else if (e.toString().contains('connection') ||
          e.toString().contains('network')) {
        errorText =
            'Network connection error. Please check your internet connection and try again.';
      } else {
        errorText =
            'AI Error: ${e.toString().replaceAll('Exception:', '').trim()}';
      }

      final errorMessage = ChatMessage(
        id: _uuid.v4(),
        content: errorText,
        role: ChatRole.assistant,
        timestamp: DateTime.now(),
      );

      _addMessage(errorMessage);
      talker.error('Chat error: $e');
    } finally {
      _processingType = ProcessingType.none;
      // Check if soft reset was requested via <reset> token
      if (_resetAfterResponse) {
        _resetAfterResponse = false;
        await softResetConversation();
      }
      notifyListeners();
    }
  }

  /// Execute sub-prompts separated by [subPromptSepRegex] (++#++[NT:...] or legacy [Nn]) sequentially.
  ///
  /// If a sub-prompt contains `${tool_result}` or `[tool_result]`, the raw tool
  /// output of the immediately preceding step is substituted. When the next step
  /// needs that injection the current step is run in *stop-after-tool-call* mode:
  /// the tool output is captured directly without being forwarded to the LLM.
  Future<void> _processSubPrompts(List<Step> subPrompts) async {
    _processingType = ProcessingType.llm;
    notifyListeners();

    String? lastToolOutput;
    String? lastTaskResult;

    // Split the plugin system prompt on the same separator so each step can have
    // its own system instructions. Falls back to a single shared section.
    final List<String> sysPromptParts = () {
      final raw = getPluginPrompts?.call()?.systemPrompt?.trim() ?? '';
      if (raw.isEmpty) return <String>[];
      final parts = parseWorkflowSteps(
        raw,
      ).where((s) => s.text.isNotEmpty).map((s) => s.text).toList();
      return parts;
    }();
    if (sysPromptParts.length > 1 &&
        sysPromptParts.length < subPrompts.length) {
      talker.warning(
        'System prompt has ${sysPromptParts.length} sections but there are ${subPrompts.length} sub-prompts. '
        'Extra steps will reuse the last section.',
      );
    }

    try {
      _toolIterationCount = 0;
      _capabilityRefusalRetryCount = 0;
      _isCancelled = false;
      _executedToolCallSignatures.clear();
      _executedToolCallIds.clear();

      int currentIdx = 0;
      int stepsExecuted = 0;
      while (currentIdx < subPrompts.length && stepsExecuted < 50) {
        final i = currentIdx;
        stepsExecuted++;
        if (_isCancelled) {
          talker.info('Sub-prompt execution cancelled at step ${i + 1}');
          break;
        }

        final stepMode = subPrompts[i].enabledToolNames;
        String prompt = subPrompts[i].text;

        // Inject outputs captured from the previous step.
        final bool hasPlaceholder = subPrompts[i].text.contains('tool_result') ||
            subPrompts[i].text.contains('tool_output') ||
            subPrompts[i].text.contains('task_result') ||
            subPrompts[i].text.contains('task_output');
        final String? previousOutput = lastToolOutput ?? lastTaskResult;

        if (lastToolOutput != null) {
          prompt = prompt
              .replaceAll(r'${tool_result}', lastToolOutput)
              .replaceAll('[tool_result]', lastToolOutput)
              .replaceAll(r'$(tool_result)', lastToolOutput)
              .replaceAll(r'${tool_output}', lastToolOutput)
              .replaceAll('[tool_output]', lastToolOutput)
              .replaceAll(r'$(tool_output)', lastToolOutput);
          lastToolOutput = null;
        }
        if (lastTaskResult != null) {
          prompt = prompt
              .replaceAll(r'${task_result}', lastTaskResult)
              .replaceAll('[task_result]', lastTaskResult)
              .replaceAll(r'$(task_result)', lastTaskResult)
              .replaceAll(r'${task_output}', lastTaskResult)
              .replaceAll('[task_output]', lastTaskResult)
              .replaceAll(r'$(task_output)', lastTaskResult);
          lastTaskResult = null;
        }

        if (!hasPlaceholder && previousOutput != null && previousOutput.trim().isNotEmpty) {
          prompt = '$prompt\n\n[Context from previous step]:\n$previousOutput';
        }

        // If the NEXT step references any result/output placeholder, run this step in
        // stop-after-tool-call mode so the raw output is captured.
        final bool nextNeedsToolResult =
            (i + 1 < subPrompts.length) &&
            (subPrompts[i + 1].text.contains('tool_result') ||
                subPrompts[i + 1].text.contains('tool_output') ||
                subPrompts[i + 1].text.contains('task_result') ||
                subPrompts[i + 1].text.contains('task_output'));

        // --- Clean session: mark where this step's messages begin ---
        // Only non-system messages are sent to the LLM; capture count before adding anything.
        _subPromptContextStartCount = _messages
            .where((m) => m.role != ChatRole.system)
            .length;

        // --- System prompt splitting + per-step skills filtering ---
        // stepMode == null  → all tools (no filtering needed)
        // stepMode == []    → no tools  (strip the skills block)
        // stepMode == [..] → specific tools (keep only those skills)
        final bool hasMultiSysParts = sysPromptParts.length > 1;
        final bool needsSkillsFilter = stepMode != null;

        if (hasMultiSysParts || needsSkillsFilter) {
          // Pick the base system prompt section for this step.
          final String rawSection = sysPromptParts.isNotEmpty
              ? sysPromptParts[i < sysPromptParts.length
                    ? i
                    : sysPromptParts.length - 1]
              : '';

          // Apply per-step skills filter (no-op when stepMode is null).
          final String stepSysSection = needsSkillsFilter
              ? _filterSkillsForStep(rawSection, stepMode)
              : rawSection;

          final now = DateTime.now();
          final weekdays = [
            'Monday',
            'Tuesday',
            'Wednesday',
            'Thursday',
            'Friday',
            'Saturday',
            'Sunday',
          ];
          final months = [
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
          final dateHeader =
              'CURRENT DATE/TIME: ${weekdays[now.weekday - 1]}, ${now.day} ${months[now.month - 1]} ${now.year}, '
              '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')} local time.';

          final bool hasTools = stepMode != null
              ? stepMode.isNotEmpty
              : mcpClient.availableTools.isNotEmpty;

          // Add TOOL CALL FORMAT instructions or no-tool rules for sub-prompts
          final formatInstructions = hasTools
              ? '''

═══════════════════════════════════════════════
🔧 TOOL CALL FORMAT (use this format if tool call is needed):
tool_call: {"name": "tool_name", "arguments": {"param1": "value1", "param2": 123}}
⚠️  Always use this JSON format. Do NOT use key=value format.
═══════════════════════════════════════════════
'''
              : '''

RULES (follow strictly):
1. Answer the user directly, concisely, and accurately.
2. Answer directly based on the provided conversation context. Do not make any tool calls or write "tool_call".
''';

          final stepSysContent = stepSysSection.isNotEmpty
              ? '$dateHeader$formatInstructions\n$stepSysSection'
              : '$dateHeader$formatInstructions';
          _addMessage(
            ChatMessage(
              id: _uuid.v4(),
              content: stepSysContent,
              role: ChatRole.system,
              timestamp: DateTime.now(),
              actionType: _internalSystemPromptActionType,
            ),
          );
          talker.info(
            'Sub-prompt ${i + 1}: injected step-specific system prompt'
            '${needsSkillsFilter ? " (skills filtered to: $stepMode)" : ""}'
            ' (${stepSysContent.length} chars)',
          );
        }

        final int msgsBefore = _messages.length;

        _addMessage(
          ChatMessage(
            id: _uuid.v4(),
            content: prompt,
            role: ChatRole.user,
            timestamp: DateTime.now(),
            availableTools: mcpClient.availableTools.toList(),
          ),
        );

        talker.info(
          'Sub-prompt ${i + 1}/${subPrompts.length} (stopAfterTool=$nextNeedsToolResult'
          '${subPrompts[i].stopAfterToolCall ? " +perStep" : ""}'
          ', cleanContextFrom=$_subPromptContextStartCount)',
        );
        _toolIterationCount = 0;
        // Stop the LLM loop after the first tool call if the next step needs
        // the raw tool output (${tool_result}), the global flag is set, OR the
        // per-step flag is set on this step.
        _subPromptStopAfterToolCall =
            nextNeedsToolResult || subPrompts[i].stopAfterToolCall;
        _subPromptEnabledTools = stepMode;
        talker.info('Sub-prompt ${i + 1}: enabledTools=$stepMode');
        try {
          await _processLLMResponse();
        } finally {
          _subPromptStopAfterToolCall = false;
          _subPromptEnabledTools = null;
        }

        // Capture step output for ${tool_result} and ${task_result} substitution.
        // ${tool_result}: captured only when the next step declares a dependency on it.
        // ${task_result}: always captured — the last meaningful output of this step
        //                  (tool result text, or the model's text response if no tool ran).
        {
          final newMsgs = _messages.skip(msgsBefore).toList();
          final toolTexts = newMsgs
              .where((m) => m.role == ChatRole.tool)
              .expand((m) => m.toolResult?.content ?? <MCPContent>[])
              .where((c) => c.text != null && c.text!.isNotEmpty)
              .map((c) => c.text!)
              .join('\n\n');
          final assistantTexts = newMsgs
              .where(
                (m) => m.role == ChatRole.assistant && m.content.isNotEmpty,
              )
              .map((m) => m.content)
              .join('\n\n');
          final stepOutput = toolTexts.isNotEmpty
              ? toolTexts
              : (assistantTexts.isNotEmpty ? assistantTexts : null);
          if (stepOutput != null) {
            lastTaskResult = stepOutput;
            if (nextNeedsToolResult) {
              lastToolOutput = stepOutput;
              talker.info(
                'Captured step output for \${tool_result}/\${task_result} (${stepOutput.length} chars)',
              );
            } else {
              talker.info(
                'Captured step output for \${task_result} (${stepOutput.length} chars)',
              );
            }
          }
          // When the task-level stopAfterToolCall flag is set, stop the sub-prompt chain
          // after a tool call unless the next step will consume the result via
          // ${tool_result} or ${task_result} (intentional piping).
          if (stopAfterToolCall && subPrompts.length == 1) {
            if (newMsgs.any((m) => m.role == ChatRole.tool)) {
              talker.info(
                '[stopAfterToolCall] Breaking sub-prompt chain after step ${i + 1}',
              );
              break;
            }
          }

          currentIdx = i + 1;
        }
      }

      talker.info('Sub-prompt sequence completed');
    } catch (e) {
      _subPromptContextStartCount = -1;
      String errorText;
      if (e.toString().contains('API key')) {
        final prefs = await SharedPreferences.getInstance();
        final isServer = (prefs.getString('server_mode') ?? 'local') == 'remote';
        errorText = isServer
            ? 'Please configure your LLM API key in settings (tap the settings gear in the top bar).'
            : 'Please configure your LLM API key in settings (tap the AI icon in the top bar).';
      } else if (e.toString().contains('model') &&
          e.toString().contains('not found')) {
        errorText =
            'The selected AI model is not available. Please try a different model in settings.';
      } else if (e.toString().contains('quota') ||
          e.toString().contains('limit')) {
        errorText =
            'API quota exceeded. Please check your API usage or try again later.';
      } else if (e.toString().contains('connection') ||
          e.toString().contains('network')) {
        errorText =
            'Network connection error. Please check your internet connection and try again.';
      } else {
        final errMsg = e.toString().replaceAll('Exception:', '').trim();
        errorText = 'Sub-prompt error: $errMsg';
      }
      _addMessage(
        ChatMessage(
          id: _uuid.v4(),
          content: errorText,
          role: ChatRole.assistant,
          timestamp: DateTime.now(),
        ),
      );
      talker.error('Sub-prompt execution error: $e');
    } finally {
      _processingType = ProcessingType.none;
      _subPromptStopAfterToolCall = false;
      _subPromptContextStartCount = -1;
      notifyListeners();
    }
  }

  /// Process LLM response and handle tool calls
  Future<void> _processLLMResponse() async {
    talker.info(
      'ðŸ”„ _processLLMResponse called - messages count: ${_messages.length}, isConversationPrimed: $_isConversationPrimed',
    );

    final forceNoToolCallsThisTurn = _forceNoToolCallsNextTurn;
    final forcedNoToolHintThisTurn = _forcedNoToolHintNextTurn;
    if (forceNoToolCallsThisTurn) {
      talker.warning(
        '🧭 Forcing no-tool follow-up turn to synthesize final answer from existing tool results',
      );
      _forceNoToolCallsNextTurn = false;
      _forcedNoToolHintNextTurn = null;
    }

    // Guard: when stopAfterToolCall is set, never call the LLM to synthesise a tool
    // result. The agentic loop was already halted in _handleToolCalls; any unexpected
    // re-entry here would produce unwanted synthesis (observed on embedded models).
    if (stopAfterToolCall && _subPromptContextStartCount == -1) {
      final nonSystem = _messages
          .where((m) => m.role != ChatRole.system)
          .toList();
      if (nonSystem.isNotEmpty && nonSystem.last.role == ChatRole.tool) {
        talker.warning(
          '[stopAfterToolCall] Aborting LLM call — last message is tool result, no synthesis wanted',
        );
        _processingType = ProcessingType.none;
        _toolIterationCount = 0;
        notifyListeners();
        return;
      }
    }

    if (!llmService.isConfigured) {
      throw Exception('LLM service not configured');
    }

    // Get all chat messages for LLM
    // For agentic loops, system prompt must be sent on EVERY request to remind LLM of autonomous chaining rules
    // OpenAI-compatible APIs are stateless anyway, so always include system prompt
    final currentProvider = llmService.currentProvider;
    final supportsNativeTools = _providerSupportsNativeTools(currentProvider);

    List<ChatMessage> chatMessages;
    talker.info(
      'ðŸ” Checking conversation state: primed=$_isConversationPrimed, provider=$currentProvider, supportsNative=$supportsNativeTools, messages=${_messages.length}',
    );

    if (supportsNativeTools &&
        _isConversationPrimed &&
        currentProvider == LLMProvider.gemini) {
      // Only Gemini can skip system messages after priming (uses systemInstruction parameter)
      // All other providers (OpenAI, Claude, OpenAI-compatible) need system prompt for agentic loops
      final allGeminiNonSystem = _messages
          .where((m) => m.role != ChatRole.system)
          .toList();
      chatMessages =
          _subPromptContextStartCount >= 0 &&
              _subPromptContextStartCount <= allGeminiNonSystem.length
          ? allGeminiNonSystem.sublist(_subPromptContextStartCount)
          : allGeminiNonSystem;
      talker.info(
        'ðŸ“¤ Using primed conversation (${chatMessages.length} messages, system prompt skipped for Gemini)',
      );
    } else {
      // Include all messages BUT filter to keep only ONE system message (the most recent one)
      // This prevents duplicate system messages from accumulating
      final allMessages = List<ChatMessage>.from(_messages);
      // Find the LAST system message (most recent priming)
      ChatMessage? lastSystemMessage;
      int lastSystemIndex = -1;
      for (int i = allMessages.length - 1; i >= 0; i--) {
        if (allMessages[i].role == ChatRole.system) {
          lastSystemMessage = allMessages[i];
          lastSystemIndex = i;
          break;
        }
      }

      // Build message list: ONE system message at beginning + all non-system messages
      chatMessages = [];
      if (lastSystemMessage != null) {
        chatMessages.add(lastSystemMessage);
        talker.info(
          '📝 Using most recent system message from index $lastSystemIndex (${lastSystemMessage.content.length} chars):\n${lastSystemMessage.content}',
        );
      } else {
        // No system message found - create one (e.g., after reset or first message)
        talker.info(
          '🆕 No system message found - creating new one for first request after reset',
        );
        final systemPromptContent = _buildSystemPrompt(includeWarmup: true);
        final newSystemMessage = ChatMessage(
          id: _uuid.v4(),
          content: systemPromptContent,
          role: ChatRole.system,
          timestamp: DateTime.now(),
          actionType: _internalSystemPromptActionType,
        );
        _addMessage(newSystemMessage);
        chatMessages.add(newSystemMessage);
        talker.info(
          '📋 Created new system message (${systemPromptContent.length} chars)',
        );
      }

      // Add all non-system messages in original order (limited to current sub-prompt step if active)
      final allNonSystem = allMessages
          .where((m) => m.role != ChatRole.system)
          .toList();
      if (_subPromptContextStartCount >= 0 &&
          _subPromptContextStartCount <= allNonSystem.length) {
        chatMessages.addAll(allNonSystem.sublist(_subPromptContextStartCount));
      } else {
        chatMessages.addAll(allNonSystem);
      }

      talker.info(
        '📤 Including system prompt for agentic loop (1 system + ${chatMessages.length - 1} other = ${chatMessages.length} total messages)',
      );
    }

    // OPTIMIZATION: Inject user location AFTER the first system message (tool definitions)
    // This allows Ollama to cache the static tool definitions that appear first
    // Dynamic data (location, timestamp) should come after static content for better caching
    final position = locationService.lastKnownPosition;
    bool hasLocationTool = false;
    if (_subPromptEnabledTools != null) {
      hasLocationTool = _subPromptEnabledTools!.any(
        (name) => name == 'get_current_location' || name == 'geocode_city',
      );
    } else {
      hasLocationTool = mcpClient.availableTools.any(
        (t) => t.name == 'get_current_location' || t.name == 'geocode_city',
      );
    }
    if (position != null && !supportsNativeTools && hasLocationTool) {
      // Only inject location for non-native tools (native tools don't have system prompt with tool definitions)
      // Find the index after the first system message (which contains tool definitions)
      int insertIndex = 0;
      for (int i = 0; i < chatMessages.length; i++) {
        if (chatMessages[i].role == ChatRole.system) {
          insertIndex = i + 1; // Insert AFTER the system prompt
          break;
        }
      }

      // Add location context after the static system prompt
      chatMessages.insert(
        insertIndex,
        ChatMessage(
          id: _uuid.v4(),
          content:
              'USER LOCATION: The user is currently at coordinates ${position.latitude.toStringAsFixed(5)}, ${position.longitude.toStringAsFixed(5)}. '
              'When the user asks for "devices near me", "my location", "current location", or similar, use these coordinates. '
              'IMPORTANT: For travel searches (flights, trains, hotels, restaurants, weather, etc.) that require a city name, region, or airport code, '
              'first determine the nearest city and airport from these coordinates — do NOT use a default or example city like Los Angeles. '
              'Always derive the departure location from the user\'s actual coordinates.',
          role: ChatRole.system,
          timestamp: DateTime.now(),
        ),
      );
      talker.info(
        'Injected user location into LLM context (after static system prompt for caching): ${position.latitude}, ${position.longitude}',
      );
    }

    if (forceNoToolCallsThisTurn &&
        forcedNoToolHintThisTurn != null &&
        forcedNoToolHintThisTurn.trim().isNotEmpty) {
      chatMessages.add(
        ChatMessage(
          id: _uuid.v4(),
          content: forcedNoToolHintThisTurn,
          role: ChatRole.user,
          timestamp: DateTime.now(),
        ),
      );
      talker.info(
        '🧭 Added transient no-tool hint to outbound prompt (not persisted in chat history)',
      );
    }

    logWorkflowStep(
      'LLM Generation',
      'Requesting completion for: ${chatMessages.isNotEmpty ? '${chatMessages.last.content.substring(0, math.min(100, chatMessages.last.content.length))}...' : 'no messages'}',
    );

    // Get the last user message for tool filtering - search from the end backwards
    ChatMessage? lastUserMessage;
    for (int i = chatMessages.length - 1; i >= 0; i--) {
      if (chatMessages[i].role == ChatRole.user) {
        final content = chatMessages[i].content.trim();
        if (content.isNotEmpty &&
            !content.startsWith('🚨 CRITICAL:') &&
            !content.contains('<!DOCTYPE') &&
            !content.contains('RAW HTML code ONLY')) {
          lastUserMessage = chatMessages[i];
          break;
        } else {
          talker.warning(
            '⚠️ Skipping user message with system-like content: ${content.substring(0, math.min(50, content.length))}...',
          );
        }
      }
    }

    lastUserMessage ??= _messages
        .where((m) => m.role == ChatRole.user)
        .lastOrNull;
    lastUserMessage ??= chatMessages.last;

    // Determine if we should send tools based on provider capabilities
    List<MCPTool>? toolsToSend;

    if (supportsNativeTools) {
      if (mcpClient.availableTools.isNotEmpty) {
        final totalTools = mcpClient.availableTools.length;

        // Build semantic query from original user message + most recent tool call context
        String semanticQuery = lastUserMessage.content;
        if (_toolIterationCount > 0 && _toolIterationCount <= 2) {
          final lastToolMessage = chatMessages.lastWhere(
            (m) =>
                m.role == ChatRole.tool && m.lastCalledToolName != null,
            orElse: () => chatMessages.last,
          );
          if (lastToolMessage.role == ChatRole.tool &&
              lastToolMessage.lastCalledToolName != null) {
            semanticQuery +=
                '\nLast tool: ${lastToolMessage.lastCalledToolName}';
            talker.info(
              '🔄 Enhanced semantic query with last tool: ${lastToolMessage.lastCalledToolName}',
            );
          }
        }

        // For small toolsets (<= 20 tools):
        if (totalTools <= 20) {
          List<MCPTool> tools = mcpClient.availableTools.toList();
          // If > 5 tools and 2nd stage LLM tool filtering is enabled, filter down
          if (llmService.enable2ndStageToolFiltering && totalTools > 5) {
            try {
              talker.info('🧠 [Stage 2] Running LLM tool selection on $totalTools tools...');
              tools = await LLMToolSelector.filterTools(
                query: semanticQuery,
                candidateTools: tools,
                llmService: llmService,
              );
            } catch (e) {
              talker.warning('LLM tool selection failed, using all tools: $e');
              tools = mcpClient.availableTools.toList();
            }
          }

          if (tools.isEmpty) {
            talker.info('📭 Tool filtering returned 0 tools - query does not require tools');
            toolsToSend = [];
          } else {
            tools.sort((a, b) => a.name.compareTo(b.name));
            toolsToSend = tools;
            talker.info(
              'Using ${toolsToSend.length} tools for small toolset (${toolsToSend.map((t) => t.name).join(", ")})',
            );
          }
        } else {
          // Large toolsets (> 20 tools): Use Stage 1 semantic router + Stage 2 LLM selector
          if (_toolRouter == null && !_isInitializingSemanticFiltering) {
            talker.info(
              '🚀 First user message detected, initializing semantic filtering...',
            );
            try {
              await _initializeToolRouter();
            } catch (e) {
              talker.error('Failed to initialize semantic filtering: $e');
            }
          }

          if (_toolRouter != null) {
            try {
              final k = math.max(
                1,
                (mcpClient.availableTools.length * 0.6).round(),
              );

              talker.info(
                '🔍 Semantic filtering: Query="${semanticQuery.substring(0, math.min(150, semanticQuery.length))}..."',
              );
              final selectedToolDefs = await _toolRouter!.selectTools(
                semanticQuery,
                topK: k,
              );
              final candidateTools = mcpClient.availableTools
                  .where(
                    (tool) =>
                        selectedToolDefs.any((def) => def.name == tool.name),
                  )
                  .toList();

              List<MCPTool> filteredTools = candidateTools;

              // Stage 2: LLM Tool Selector (if enabled and tool count > 5)
              if (llmService.enable2ndStageToolFiltering && candidateTools.length > 5) {
                talker.info('🧠 [Stage 2] Running LLM tool selection on ${candidateTools.length} candidate tools...');
                filteredTools = await LLMToolSelector.filterTools(
                  query: semanticQuery,
                  candidateTools: candidateTools,
                  llmService: llmService,
                );
              }

              if (filteredTools.isEmpty && candidateTools.isNotEmpty && !llmService.enable2ndStageToolFiltering) {
                talker.warning(
                  'Semantic filtering returned 0 tools; falling back to all available tools',
                );
                final allTools = mcpClient.availableTools.toList();
                allTools.sort((a, b) => a.name.compareTo(b.name));
                toolsToSend = allTools;
                talker.info(
                  'Fallback prompt sent with ${allTools.length} tools',
                );
              } else if (filteredTools.isEmpty) {
                talker.info('📭 Tool filtering returned 0 tools - query does not require tools');
                toolsToSend = [];
              } else {
                filteredTools.sort((a, b) => a.name.compareTo(b.name));
                toolsToSend = filteredTools;
                talker.info(
                  '[ToolFilter] Filter selected ${filteredTools.length} tools (${filteredTools.map((t) => t.name).join(", ")})',
                );
              }
            } catch (e) {
              talker.warning('Semantic filtering failed, using all tools: $e');
              final allTools = mcpClient.availableTools.toList();
              allTools.sort((a, b) => a.name.compareTo(b.name));
              toolsToSend = allTools;
            }
          } else {
            // Router not ready yet
            List<MCPTool> tools = mcpClient.availableTools.toList();
            if (llmService.enable2ndStageToolFiltering && tools.length > 5) {
              try {
                talker.info('🧠 [Stage 2] Router not ready; running direct LLM tool selection on ${tools.length} available tools...');
                tools = await LLMToolSelector.filterTools(
                  query: semanticQuery,
                  candidateTools: tools,
                  llmService: llmService,
                );
              } catch (_) {}
            }
            tools.sort((a, b) => a.name.compareTo(b.name));
            toolsToSend = tools;
            talker.info(
              '⏳ Using ${toolsToSend.length} tools (${toolsToSend.map((t) => t.name).join(", ")})',
            );
          }
        }
      } else {
        toolsToSend = null;
      }
    } else {
      // Providers without native tool APIs: tools are in system prompt
      toolsToSend = null;
    }

    if (forceNoToolCallsThisTurn) {
      toolsToSend = null;
      talker.info('🔒 Tools disabled for this turn (forced final response)');
    }

    // Sub-prompt per-step tool-mode override.
    // For named-tools steps, this is authoritative: bypass semantic filtering
    // output and send exactly the selected tool set (if available).
    final enabledTools = _subPromptEnabledTools;
    if (enabledTools != null) {
      if (enabledTools.isEmpty) {
        toolsToSend = null;
        talker.info('[SubPrompt] noTools step — tool calls disabled');
      } else {
        final constrained = mcpClient.availableTools
            .where((t) => enabledTools.contains(t.name))
            .toList();
        constrained.sort((a, b) => a.name.compareTo(b.name));
        toolsToSend = constrained;
        talker.info(
          '[SubPrompt] namedTools step — forcing ${toolsToSend.length} tools (${toolsToSend.map((t) => t.name).join(", ")})',
        );
      }
    }

    final outboundToolCount = toolsToSend?.length ?? 0;
    talker.info(
      '[LLM Request] Outbound tools: $outboundToolCount (available: ${mcpClient.availableTools.length})',
    );
    logLLMRequest(
      'Chat completion with ${chatMessages.length} messages and $outboundToolCount outbound tools '
      '(available: ${mcpClient.availableTools.length})',
    );

    // Debug: Log attachments in messages before sending to LLM
    for (final msg in chatMessages) {
      if (msg.attachments != null && msg.attachments!.isNotEmpty) {
        talker.info(
          'Message "${msg.content.substring(0, math.min(50, msg.content.length))}..." has ${msg.attachments!.length} attachment(s):',
        );
        for (final att in msg.attachments!) {
          talker.info('   - ${att.name} (${att.mimeType})');
          talker.info(
            '     Bytes: ${att.bytes != null ? "${att.bytes!.length} bytes" : "NULL!!!"}',
          );
        }
      }
    }

    // Track characters sent in this LLM request
    final sentCharsThisRequest = chatMessages.fold<int>(
      0,
      (sum, m) => sum + m.content.length,
    );
    _totalSentChars += sentCharsThisRequest;

    // All providers support streaming. Add a placeholder message so the UI shows tokens as they arrive.
    // The placeholder will be seamlessly replaced by the committed final message in _addMessage().
    void Function(String chunk)? streamChunkCallback;
    if (llmService.currentProvider != LLMProvider.none) {
      final placeholderId = _uuid.v4();
      _streamingPlaceholderId = placeholderId;
      String streamedContent = '';
      final placeholderMsg = ChatMessage(
        id: placeholderId,
        content: '',
        role: ChatRole.assistant,
        timestamp: DateTime.now(),
      );
      _messages.add(placeholderMsg);
      _messagesController.add(List.unmodifiable(_messages));
      notifyListeners();
      streamChunkCallback = (String chunk) {
        streamedContent += chunk;
        // Filter <think> blocks from the streaming display so they are never
        // shown to the user in real-time (the final committed message is also
        // cleaned by _cleanAssistantResponse).
        final displayContent = llmService.hideThinkBlocks
            ? _filterThinkBlocksForStreaming(streamedContent)
            : streamedContent;
        final idx = _messages.indexWhere((m) => m.id == placeholderId);
        if (idx != -1) {
          _messages[idx] = ChatMessage(
            id: placeholderId,
            content: displayContent,
            role: ChatRole.assistant,
            timestamp: _messages[idx].timestamp,
          );
          _messagesController.add(List.unmodifiable(_messages));
          notifyListeners();
        }
      };
    }

    // Generate LLM response
    LLMResponse response;
    try {
      response = await llmService.generateChatCompletion(
        messages: chatMessages,
        availableTools: toolsToSend,
        forceNoToolCalls: forceNoToolCallsThisTurn,
        onStreamChunk: streamChunkCallback,
      );
    } catch (e) {
      // Clean up streaming placeholder on error
      if (_streamingPlaceholderId != null) {
        _messages.removeWhere((m) => m.id == _streamingPlaceholderId);
        _streamingPlaceholderId = null;
        _messagesController.add(List.unmodifiable(_messages));
        notifyListeners();
      }
      talker.error('âš ï¸ LLM generation failed: $e');
      rethrow; // Re-throw to let higher level handle the error
    }

    // Track cumulative tokens. Some streaming providers omit usage metadata,
    // so we estimate token counts from character length as a fallback.
    int promptTokens = response.usage.promptTokens;
    int completionTokens = response.usage.completionTokens;
    int tokensUsed = response.usage.totalTokens;

    if (tokensUsed <= 0) {
      _lastRequestUsageEstimated = true;
      _estimatedUsageRequests += 1;
      final estimatedPrompt = (sentCharsThisRequest / 4).ceil();
      final estimatedCompletion = (response.content.length / 4).ceil();
      promptTokens = promptTokens > 0 ? promptTokens : estimatedPrompt;
      completionTokens = completionTokens > 0
          ? completionTokens
          : estimatedCompletion;
      tokensUsed = promptTokens + completionTokens;
      talker.info(
        '📐 Usage metadata missing from provider response - using estimate: '
        'prompt=$promptTokens, completion=$completionTokens, total=$tokensUsed',
      );
    } else {
      _lastRequestUsageEstimated = false;
    }

    _lastRequestPromptTokens = promptTokens;
    _lastRequestCompletionTokens = completionTokens;
    _lastRequestTotalTokens = tokensUsed;

    _cumulativePromptTokens += promptTokens;
    _cumulativeCompletionTokens += completionTokens;
    _cumulativeTokens += tokensUsed;

    final providerKey = _providerKeyForPricing();
    if (providerKey.isNotEmpty) {
      _lastRequestCostUsd = estimateTokenCostUsd(
        providerKey: providerKey,
        model: llmService.currentModel,
        promptTokens: promptTokens,
        completionTokens: completionTokens,
      );
      _sessionCostUsd += _lastRequestCostUsd;
    } else {
      _lastRequestCostUsd = 0;
    }

    notifyListeners(); // Notify UI to update token display
    if (tokensUsed > 0) {
      talker.info('ðŸ“Š Tokens: +$tokensUsed (cumulative: $_cumulativeTokens)');
    } else {
      talker.warning(
        'âš ï¸ LLM response has 0 tokens - this may indicate missing usage metadata',
      );
    }

    logLLMResponse(response.content, toolCallCount: response.toolCalls.length);

    // Log LLM response with preview
    final hasToolCalls = response.toolCalls.isNotEmpty;
    final contentPreview = response.content.length > 150
        ? '${response.content.substring(0, 150)}...'
        : response.content;
    if (hasToolCalls) {
      talker.info(
        'ðŸ¤– LLM response: tool calls (${response.toolCalls.length}) - ${response.toolCalls.map((t) => t.name).join(", ")}',
      );
    } else if (contentPreview.trim().isNotEmpty) {
      talker.info('ðŸ¤– LLM response: $contentPreview');
    }

    // Check for hallucinated tool calling (says "Calling tools" but no actual tool_calls)
    // This should stop immediately instead of retrying
    final contentLower = response.content.toLowerCase();
    final isHallucinatedToolCall =
        (contentLower.contains('calling tool') ||
            contentLower.contains('call tool')) &&
        response.toolCalls.isEmpty &&
        response.content.trim().isNotEmpty;

    if (isHallucinatedToolCall) {
      talker.error(
        'âš ï¸ LLM hallucinated tool calling (said "${response.content.trim()}" but returned no tool_calls)',
      );
      talker.error(
        'âŒ STOPPING EXECUTION - No retry for hallucinated tool calls',
      );
      final errorMessage = ChatMessage(
        id: _uuid.v4(),
        content:
            'Error: The model said it would call tools but did not return any tool calls.\n\n'
            'This indicates the model cannot properly handle this request. Please:\n'
            '- Try rephrasing your request\n'
            '- Use a different model\n'
            '- Break your request into smaller steps',
        role: ChatRole.assistant,
        timestamp: DateTime.now(),
      );
      _addMessage(errorMessage);
      _currentRetryCount = 0;
      notifyListeners();
      return;
    }

    // Check if response is empty - this indicates a problem with the request/prompt
    if (response.content.trim().isEmpty && response.toolCalls.isEmpty) {
      talker.error(
        'âš ï¸ LLM returned empty response with finishReason=${response.finishReason}',
      );
      talker.error('   Chat messages sent: ${chatMessages.length}');
      talker.error('   Tools sent: ${toolsToSend?.length ?? 0}');
      talker.error(
        '   Total message chars: ${chatMessages.map((m) => m.content.length).fold(0, (a, b) => a + b)}',
      );

      // Check for error in finishReason
      final finishReason = response.finishReason.toLowerCase();
      if (finishReason.contains('error') ||
          finishReason.contains('safety') ||
          finishReason.contains('blocked')) {
        talker.error(
          'âŒ Error detected in finishReason: ${response.finishReason}',
        );
        final errorMessage = ChatMessage(
          id: _uuid.v4(),
          content:
              'Error: The request was blocked or failed. Reason: ${response.finishReason}\n\n'
              'This usually means:\n'
              '- Safety filters triggered\n'
              '- Content policy violation\n'
              '- API error\n\n'
              'Please try rephrasing your request or ask for help.',
          role: ChatRole.assistant,
          timestamp: DateTime.now(),
        );
        _addMessage(errorMessage);
        _currentRetryCount = 0;
        notifyListeners();
        return;
      }

      // Auto-retry logic: try once with corrective prompt
      if (_currentRetryCount < 1) {
        talker.warning(
          'ðŸ”„ Empty response detected - attempting auto-retry with corrective prompt',
        );
        _currentRetryCount++;

        // Add corrective system message
        final correctionMessage = ChatMessage(
          id: _uuid.v4(),
          content:
              'âš ï¸ CORRECTION: You returned an empty response. '
              'Please use proper function calling format with correct parameter replacement. '
              'All tool parameters must be filled with actual values from context - never use placeholders. '
              'Retry the request using the available tools correctly.',
          role: ChatRole.system,
          timestamp: DateTime.now(),
        );
        _addMessage(correctionMessage);

        // Retry LLM response
        await _processLLMResponse();
        return;
      }

      // Max retries reached - show error message
      talker.error('âŒ Max retries reached for empty response');
      final errorMessage = ChatMessage(
        id: _uuid.v4(),
        content:
            'The assistant returned an empty response after retry. This may indicate:\n'
            '- Tool output too large\n'
            '- Context window exceeded\n'
            '- Prompt structure issue\n\n'
            'Please try simplifying your request or ask for help.',
        role: ChatRole.assistant,
        timestamp: DateTime.now(),
      );
      _addMessage(errorMessage);
      _currentRetryCount = 0;
      notifyListeners();
      return; // Exit early
    }

    // Reset retry count on successful response
    _currentRetryCount = 0;
    notifyListeners();

    // Check if response contains malformed tool calls (XML-style or other unsupported formats)
    if (response.toolCalls.isEmpty &&
        _containsMalformedToolCall(response.content)) {
      talker.warning(
        'Detected malformed tool call in LLM response, providing guidance',
      );

      // Add the invalid response as a message first
      final invalidMessage = ChatMessage(
        id: _uuid.v4(),
        content: response.content,
        role: ChatRole.assistant,
        timestamp: DateTime.now(),
      );
      _addMessage(invalidMessage);

      // Determine the specific error type
      final errorType = _detectToolCallErrorType(response.content);
      final errorMessage = _getToolCallErrorMessage(errorType);

      // Send correction instruction
      final correctionMessage = ChatMessage(
        id: _uuid.v4(),
        content: errorMessage,
        role: ChatRole.system,
        timestamp: DateTime.now(),
      );
      _addMessage(correctionMessage);

      // Retry LLM response
      await _processLLMResponse();
      return;
    }

    // Check if LLM wants to use tools
    if (response.toolCalls.isNotEmpty) {
      talker.info('Processing ${response.toolCalls.length} tool calls');

      // CRITICAL: Add the AI's tool-calling response to messages FIRST
      // This is required for LangChain pattern: user msg â†’ AI tool call â†’ tool result â†’ final response
      // Clean the content to remove <think> blocks if enabled
      final cleanedToolCallContent = _cleanAssistantResponse(
        response.content.isNotEmpty
            ? response.content
            : 'Calling tools to retrieve the requested information...',
      );
      final aiToolCallMessage = ChatMessage(
        id: _uuid.v4(),
        content: cleanedToolCallContent.isNotEmpty
            ? cleanedToolCallContent
            : 'Calling tools to retrieve the requested information...',
        role: ChatRole.assistant,
        timestamp: DateTime.now(),
      );
      _addMessage(aiToolCallMessage);
      talker.info(
        ' Added AI tool-calling message to conversation (cleaned: ${response.content.length} â†’ ${cleanedToolCallContent.length} chars)',
      );

      try {
        await _handleToolCalls(response);
        talker.info('âœ… Tool call handling completed successfully');
      } catch (e, stackTrace) {
        talker.error('âŒ CRITICAL ERROR in _handleToolCalls: $e');
        talker.error('Stack trace: $stackTrace');

        // Add error message to chat
        final errorMessage = ChatMessage(
          id: _uuid.v4(),
          content:
              'âš ï¸ **Critical Error During Tool Execution**\n\n'
              'An unexpected error occurred while processing tool calls:\n\n'
              '$e\n\n'
              'Please try again or contact support if the issue persists.',
          role: ChatRole.system,
          timestamp: DateTime.now(),
        );
        _addMessage(errorMessage);

        // Reset processing state
        _processingType = ProcessingType.none;
        _toolIterationCount = 0;
        notifyListeners();
        return;
      }
    } else {
      // Check if response contains text-formatted tool calls (fallback for LLMs that don't use structured tool calls)
      final textToolCalls = _parseTextToolCalls(response.content);
      if (textToolCalls.isNotEmpty) {
        talker.info(
          'Detected ${textToolCalls.length} text-formatted tool calls, converting to structured format',
        );
        // Create a new response with structured tool calls
        final structuredResponse = LLMResponse(
          content: response.content,
          toolCalls: textToolCalls,
          finishReason: response.finishReason,
          usage: response.usage,
        );

        try {
          await _handleToolCalls(structuredResponse);
          talker.info(
            'âœ… Text-formatted tool call handling completed successfully',
          );
        } catch (e, stackTrace) {
          talker.error(
            'âŒ CRITICAL ERROR in _handleToolCalls (text-formatted): $e',
          );
          talker.error('Stack trace: $stackTrace');

          final errorMessage = ChatMessage(
            id: _uuid.v4(),
            content:
                'âš ï¸ **Critical Error During Tool Execution**\n\n'
                'An unexpected error occurred while processing text-formatted tool calls:\n\n'
                '$e',
            role: ChatRole.system,
            timestamp: DateTime.now(),
          );
          _addMessage(errorMessage);

          _processingType = ProcessingType.none;
          _toolIterationCount = 0;
          notifyListeners();
          return;
        }
      } else {
        // Add assistant response (cleaned of system instructions)
        final cleanedContent = _cleanAssistantResponse(response.content);

        // If cleaned content is empty but we have tool calls, don't show empty response
        if (cleanedContent.trim().isEmpty && response.toolCalls.isNotEmpty) {
          talker.info(
            'Cleaned content is empty but has tool calls, processing tools without showing empty response',
          );
          // Process tool calls directly
          try {
            await _handleToolCalls(response);
            talker.info(
              'âœ… Empty content tool call handling completed successfully',
            );
          } catch (e, stackTrace) {
            talker.error(
              'âŒ CRITICAL ERROR in _handleToolCalls (empty content): $e',
            );
            talker.error('Stack trace: $stackTrace');

            final errorMessage = ChatMessage(
              id: _uuid.v4(),
              content:
                  'âš ï¸ **Critical Error During Tool Execution**\n\n'
                  'An unexpected error occurred:\n\n'
                  '$e',
              role: ChatRole.system,
              timestamp: DateTime.now(),
            );
            _addMessage(errorMessage);

            _processingType = ProcessingType.none;
            _toolIterationCount = 0;
            notifyListeners();
          }
          return;
        }

        // If cleaned content is empty and no tool calls, show original content
        final finalContent = cleanedContent.trim().isEmpty
            ? response.content
            : cleanedContent;

        // Generic fallback: if tools are available but the model refuses capability,
        // retry once with a strict correction prompt.
        if (response.toolCalls.isEmpty &&
            _shouldRetryOnCapabilityRefusal(
              lastUserMessage.content,
              finalContent,
            )) {
          if (_capabilityRefusalRetryCount < 1) {
            _capabilityRefusalRetryCount++;
            talker.warning(
              '🔁 Capability-refusal detected despite available tools; retrying once with strict tool-use correction',
            );

            final correctionMessage = ChatMessage(
              id: _uuid.v4(),
              content:
                  'CORRECTION: Relevant tools are available in this session. '
                  'Do NOT claim inability or lack of access. '
                  'If the request needs external data/actions, call the appropriate tool now. '
                  'Only answer directly without tools when no tool is required.',
              role: ChatRole.system,
              timestamp: DateTime.now(),
            );
            _addMessage(correctionMessage);
            await _processLLMResponse();
            return;
          }
        }

        // Deterministic fallback: if user asked for emails, Gmail tool is available,
        // and the model still returns a capability-refusal text, force a Gmail search
        // tool call instead of accepting the refusal.
        if (response.toolCalls.isEmpty &&
            _shouldForceGmailSearch(lastUserMessage.content, finalContent)) {
          final forcedQuery = _buildGmailQueryFromUserMessage(
            lastUserMessage.content,
            fallbackQuery: _lastGmailQuery,
          );
          _lastGmailQuery = forcedQuery;
          talker.warning(
            '🔁 Forcing Gmail tool call due to capability-refusal response. Query: $forcedQuery',
          );

          final forcedResponse = LLMResponse(
            content: 'Calling tools to retrieve the requested information...',
            toolCalls: [
              LLMToolCall(
                name: 'search_gmail',
                arguments: {
                  'q': forcedQuery,
                  'includeBody': true,
                  'maxResults': 20,
                },
              ),
            ],
            usage: response.usage,
            finishReason: 'forced_tool_call',
          );

          await _handleToolCalls(forcedResponse);
          return;
        }

        // Deterministic fallback: for follow-up display intents like "show them"
        // after an email search, force another Gmail search using last known query
        // so the result appears as clickable tool output.
        if (response.toolCalls.isEmpty &&
            _shouldForceGmailListDisplay(
              lastUserMessage.content,
              finalContent,
            )) {
          final forcedQuery = _buildGmailQueryFromUserMessage(
            lastUserMessage.content,
            fallbackQuery: _lastGmailQuery,
          );
          _lastGmailQuery = forcedQuery;
          talker.warning(
            '🔁 Forcing Gmail list display tool call. Query: $forcedQuery',
          );

          final forcedResponse = LLMResponse(
            content: 'Calling tools to retrieve the requested information...',
            toolCalls: [
              LLMToolCall(
                name: 'search_gmail',
                arguments: {
                  'q': forcedQuery,
                  'includeBody': true,
                  'maxResults': 20,
                },
              ),
            ],
            usage: response.usage,
            finishReason: 'forced_tool_call',
          );

          await _handleToolCalls(forcedResponse);
          return;
        }

        // Deterministic fallback: if user asked for document search, the tool exists,
        // and the model still responds with capability-refusal text, force document search.
        if (response.toolCalls.isEmpty &&
            _shouldForceDocumentSearch(lastUserMessage.content, finalContent)) {
          final forcedQuery = _buildDocumentSearchQueryFromUserMessage(
            lastUserMessage.content,
          );
          talker.warning(
            '🔁 Forcing document search tool call due to capability-refusal response. Query: $forcedQuery',
          );

          final forcedResponse = LLMResponse(
            content: 'Calling tools to retrieve the requested information...',
            toolCalls: [
              LLMToolCall(
                name: 'search_documents',
                arguments: {
                  'query': forcedQuery,
                  'mode': 'semantic',
                  'maxResults': 10,
                },
              ),
            ],
            usage: response.usage,
            finishReason: 'forced_tool_call',
          );

          await _handleToolCalls(forcedResponse);
          return;
        }

        // CRITICAL: Detect if LLM keeps saying "Calling tools..." without actually calling tools
        // This creates an infinite loop where it announces tool calls but never makes them
        if (finalContent.toLowerCase().contains('calling tools') &&
            response.toolCalls.isEmpty) {
          talker.error(
            'âš ï¸ LLM said "Calling tools..." but did NOT make any tool calls!',
          );
          talker.error(
            '   This is a critical error - LLM should either call tools OR respond directly',
          );
          talker.error(
            '   Clearing message and adding strong corrective prompt',
          );

          // Don't even add this broken message
          // Instead, add strong corrective message immediately
          final correctionMessage = ChatMessage(
            id: _uuid.v4(),
            content:
                'âš ï¸ CRITICAL ERROR: You output text "Calling tools to retrieve the requested information..." '
                'but you did NOT actually call any tools!\n\n'
                'YOU MUST use STRUCTURED function calling format.\n'
                'DO NOT output "Calling tools..." as text - either call tools properly OR answer the user directly.\n\n'
                'Available tools were provided to you. If you need to call them:\n'
                '1. Use the functionCall mechanism (not text)\n'
                '2. Fill ALL required parameters with ACTUAL values from context\n'
                '3. Extract values from previous tool results\n\n'
                'If you cannot call tools, answer the user\'s question directly instead.',
            role: ChatRole.system,
            timestamp: DateTime.now(),
          );
          _addMessage(correctionMessage);

          // Retry immediately
          await _processLLMResponse();
          return;
        }

        final assistantMessage = ChatMessage(
          id: _uuid.v4(),
          content: finalContent,
          role: ChatRole.assistant,
          timestamp: DateTime.now(),
        );

        _addMessage(assistantMessage);

        // Check if token threshold exceeded - suggest cleanup as inline message
        final tokenThreshold = llmService.tokenWarningThreshold;
        if (_cumulativeTokens >= tokenThreshold) {
          talker.info(
            'ðŸ§¹ Token threshold reached ($_cumulativeTokens tokens) - adding cleanup suggestion message',
          );

          // Add cleanup suggestion as a system message in chat
          final cleanupMessage = ChatMessage(
            id: _uuid.v4(),
            content:
                'ðŸ§¹ **Chat Cleanup Suggested**\n\n'
                'Token threshold reached ($_cumulativeTokens tokens used).\n\n'
                'Reset the conversation to:\n'
                '- Clear conversation history\n'
                '- Reduce token usage\n'
                '- Start fresh for the next task',
            role: ChatRole.system,
            actionType: 'reset', // Enable reset button
            timestamp: DateTime.now(),
          );
          _addMessage(cleanupMessage);

          // Note: do NOT reset _cumulativeTokens — keep counting and re-warn as needed
        }

        // Reset iteration counter when LLM gives final answer (no tool calls)
        _toolIterationCount = 0;
        talker.info('âœ… Final answer received - iteration counter reset');

        // For Gemini: mark conversation as primed after first response
        // (system prompt was sent with first user message, now skip it for subsequent messages)
        if (!_isConversationPrimed &&
            llmService.currentProvider == LLMProvider.gemini) {
          _isConversationPrimed = true;
          talker.info(
            'ðŸŽ¯ Gemini conversation now primed - subsequent messages will skip system prompt',
          );
        }
      }
    }
  }

  bool _shouldForceGmailSearch(String userText, String assistantText) {
    if (!_hasToolNamed('search_gmail')) return false;
    if (!_looksLikeEmailIntent(userText)) return false;

    final lower = assistantText.toLowerCase();
    final refusalSignals = [
      "can't access your emails",
      "cannot access your emails",
      "can't help you with that",
      'capabilities are limited',
      'limited to the tools i have been provided',
      'i can only',
      // New refusal patterns observed in production
      'available tools lack the desired functionality',
      'tools lack',
      'cannot fulfill this request',
      'i cannot fulfill',
      'i can not search in emails',
      'i can not search emails',
      'can not search in emails',
      'can not search emails',
      'i am unable to search',
      'unable to search your emails',
      'unable to access your emails',
      'i am sorry, i cannot',
      // German refusal variants
      'kann keine e-mails suchen',
      'kann keine mails suchen',
      'kann keine emails suchen',
      'kann ich nicht suchen',
      'werkzeuge fehlen',
      'keine e-mail-suche',
    ];

    return refusalSignals.any(lower.contains);
  }

  bool _shouldForceGmailListDisplay(String userText, String assistantText) {
    if (!_hasToolNamed('search_gmail')) return false;
    if ((_lastGmailQuery ?? '').trim().isEmpty) return false;

    final lowerUser = userText.toLowerCase();
    final lowerAssistant = assistantText.toLowerCase();

    final displayIntent =
        lowerUser.contains('show them') ||
        lowerUser.contains('list them') ||
        lowerUser.contains('show all') ||
        lowerUser.contains('display') ||
        RegExp(r'\b(show|list|open)\b').hasMatch(lowerUser);

    final alreadyDisplayed = lowerAssistant.contains(
      'called tool: search_gmail',
    );
    return displayIntent && !alreadyDisplayed;
  }

  bool _looksLikeEmailIntent(String text) {
    final lower = text.toLowerCase();
    if (lower.contains('email') ||
        lower.contains('emails') ||
        lower.contains('gmail') ||
        lower.contains('inbox') ||
        lower.contains('mail') ||
        lower.contains('mails')) {
      return true;
    }
    // Detect "suche von X@domain" / "from X@domain" patterns (email address present)
    if (RegExp(
      r'[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}',
    ).hasMatch(text)) {
      return true;
    }
    return false;
  }

  bool _hasToolNamed(String name) {
    return mcpClient.availableTools.any((tool) => tool.name == name);
  }

  bool _shouldRetryOnCapabilityRefusal(String userText, String assistantText) {
    if (mcpClient.availableTools.isEmpty) return false;

    final lower = assistantText.toLowerCase();
    final refusalSignals = [
      "can't access",
      'cannot access',
      "can't retrieve",
      'cannot retrieve',
      'without access to real-time data',
      'without external tools',
      'i can only',
      'capabilities are limited',
      'limited to the tools i have been provided',
      'tools lack',
      'cannot fulfill this request',
      'i cannot fulfill',
      'i am unable to',
      'unable to',
      'i am sorry, i cannot',
      'ich kann nicht',
      'kein zugriff',
      'ohne externe tools',
      'nicht moeglich',
      'nicht möglich',
    ];

    final userLower = userText.toLowerCase();
    final likelyToolIntent =
        userLower.contains('forecast') ||
        userLower.contains('weather') ||
        userLower.contains('run') ||
        userLower.contains('script') ||
        userLower.contains('search') ||
        userLower.contains('near me') ||
        userLower.contains('email') ||
        userLower.contains('plot') ||
        userLower.contains('statistical') ||
        userLower.contains('tool');

    return likelyToolIntent && refusalSignals.any(lower.contains);
  }

  bool _shouldForceDocumentSearch(String userText, String assistantText) {
    if (!_hasToolNamed('search_documents')) return false;
    if (!_looksLikeDocumentIntent(userText)) return false;

    final lower = assistantText.toLowerCase();
    final refusalSignals = [
      "can't search documents",
      'cannot search documents',
      "can't search in documents",
      'cannot search in documents',
      "can't perform full-text search",
      'cannot perform full-text search',
      "can't create text files",
      'cannot create text files',
      'i can only',
      'capabilities are limited',
      'limited to the tools i have been provided',
      'kann keine dokumente durchsuchen',
      'kann keine volltextsuche',
      'funktionen sind auf',
      // General refusal patterns shared with Gmail
      'available tools lack the desired functionality',
      'tools lack',
      'cannot fulfill this request',
      'i cannot fulfill',
      'i am unable to',
      'unable to search',
      'i am sorry, i cannot',
    ];

    return refusalSignals.any(lower.contains);
  }

  bool _looksLikeDocumentIntent(String text) {
    final lower = text.toLowerCase();
    return lower.contains('document') ||
        lower.contains('documents') ||
        lower.contains('dokument') ||
        lower.contains('dokumente') ||
        lower.contains('pdf') ||
        lower.contains('docx') ||
        lower.contains('search') ||
        lower.contains('suche');
  }

  String _buildDocumentSearchQueryFromUserMessage(String userText) {
    final raw = userText.trim();
    if (raw.isEmpty) return 'documents';

    final quotedMatch = RegExp(r'"([^"]+)"').firstMatch(raw);
    if (quotedMatch != null) {
      final q = quotedMatch.group(1)?.trim();
      if (q != null && q.isNotEmpty) return q;
    }

    final normalized = raw
        .replaceAll(
          RegExp(
            r'\b(suche|such|search|find|look for|in documents|in dokumenten|dokumente|documents?)\b',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(
          RegExp(
            r'\b(danach|then|anschließend|and then|und dann|erstelle|create)\b.*$',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(RegExp(r'[^\p{L}\p{N}\s_-]', unicode: true), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    if (normalized.isNotEmpty) {
      return normalized.length > 120
          ? normalized.substring(0, 120).trim()
          : normalized;
    }

    return raw.length > 120 ? raw.substring(0, 120).trim() : raw;
  }

  // Month name → month number. German-specific names only (shared names like april/august already in English block).
  static const _monthMap = {
    // English
    'january': 1, 'february': 2, 'march': 3, 'april': 4,
    'may': 5, 'june': 6, 'july': 7, 'august': 8,
    'september': 9, 'october': 10, 'november': 11, 'december': 12,
    // German-specific (only those that differ from English)
    'januar': 1, 'februar': 2, 'märz': 3, 'maerz': 3,
    'mai': 5, 'juni': 6, 'juli': 7,
    'oktober': 10, 'dezember': 12,
  };

  /// Build a Gmail q-parameter from a natural-language user message.
  String _buildGmailQueryFromUserMessage(
    String userText, {
    String? fallbackQuery,
  }) {
    final raw = userText.trim();
    final lower = raw.toLowerCase();
    final parts = <String>[];

    // ── 1. from: / von: sender ────────────────────────────────────────────────
    // Matches: "von x@y.z", "from x@y.z", "von joerg.p@thiesclima.com"
    final fromEmailMatch = RegExp(
      r'(?:^|\s)(?:von|from)\s+([a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,})',
      caseSensitive: false,
    ).firstMatch(raw);
    if (fromEmailMatch != null) {
      parts.add('from:${fromEmailMatch.group(1)}');
    } else {
      // Plain email address anywhere in text
      final emailMatch = RegExp(
        r'[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}',
      ).firstMatch(raw);
      if (emailMatch != null) {
        parts.add('from:${emailMatch.group(0)}');
      }
    }

    // ── 2. Date range ─────────────────────────────────────────────────────────
    // Check for explicit newer_than syntax first
    final newerThanMatch = RegExp(
      r'newer\s*:?\s*than\s*(\d+)\s*([hdm])',
    ).firstMatch(lower);
    if (newerThanMatch != null) {
      parts.add(
        'newer_than:${newerThanMatch.group(1)}${newerThanMatch.group(2)}',
      );
    } else {
      // Month + year: "februar 2026", "in February 2026", "im März 2026"
      final monthPat = _monthMap.keys.join('|');
      final monthYearMatch = RegExp(
        '(?:im?\\s+)?($monthPat)\\s+(\\d{4})',
        caseSensitive: false,
      ).firstMatch(lower);
      if (monthYearMatch != null) {
        final monthName = monthYearMatch.group(1)!.toLowerCase();
        final year = int.parse(monthYearMatch.group(2)!);
        final month = _monthMap[monthName]!;
        final nextMonth = month == 12 ? 1 : month + 1;
        final nextYear = month == 12 ? year + 1 : year;
        parts.add(
          'after:${year.toString()}/${month.toString().padLeft(2, '0')}/01'
          ' before:${nextYear.toString()}/${nextMonth.toString().padLeft(2, '0')}/01',
        );
      } else if (lower.contains('today')) {
        parts.add('newer_than:1d');
      } else if (lower.contains('yesterday')) {
        parts.add('newer_than:2d older_than:1d');
      } else if (lower.contains('last hour')) {
        parts.add('newer_than:1h');
      }
    }

    // ── 3. Content keyword ────────────────────────────────────────────────────
    // Matches: "containing text X", "contains X", "mit text X", "mit textteil X",
    //          "enthält X", "enthalten X", "the word X", "keyword X"
    final contentMatch = RegExp(
      r'(?:containing(?:\s+text)?|contains(?:\s+text)?|mit\s+(?:text|textteil|dem\s+wort|wort)|'
      'the\\s+word|keyword|enth\u00e4lt|enthalten|mit\\s+inhalt)'
      r'\s+([^\s"'
      "'"
      r',.;!?]+)',
      caseSensitive: false,
    ).firstMatch(raw);
    if (contentMatch != null) {
      final kw = contentMatch.group(1)?.trim();
      if (kw != null && kw.isNotEmpty) parts.add(kw);
    } else {
      // Fallback: quoted literal
      final quotedMatch = RegExp(r'"([^"]+)"').firstMatch(raw);
      if (quotedMatch != null) {
        final term = quotedMatch.group(1)?.trim();
        if (term != null && term.isNotEmpty) parts.add('"$term"');
      }
    }

    final query = parts.join(' ').trim();
    if (query.isNotEmpty) return query;

    final fallback = fallbackQuery?.trim() ?? '';
    if (fallback.isNotEmpty) return fallback;
    return 'newer_than:1d';
  }

  Map<String, dynamic> _normalizeToolArguments(
    String toolName,
    Map<String, dynamic> args,
  ) {
    if (toolName != 'search_gmail') return args;

    final q = (args['q'] as String?)?.trim();
    if (q == null || q.isEmpty) return args;

    var normalized = _normalizeGmailDateShortcuts(q);
    normalized = _normalizeGmailMonthYear(normalized);

    final patched = Map<String, dynamic>.from(args);
    var changed = false;

    if (normalized != q) {
      patched['q'] = normalized;
      talker.info(
        '🛡️ Normalized Gmail query before tool execution: "$q" -> "$normalized"',
      );
      changed = true;
    }

    // Auto-inject includeBody:true when user message suggests content extraction/summarization
    if (patched['includeBody'] != true) {
      final lastUserMsg = _messages.lastWhere(
        (m) => m.role == ChatRole.user,
        orElse: () => ChatMessage(
          id: '',
          content: '',
          role: ChatRole.user,
          timestamp: DateTime.now(),
        ),
      );
      final lower = lastUserMsg.content.toLowerCase();
      final wantsBody =
          lower.contains('summar') ||
          lower.contains('zusammenfass') ||
          lower.contains('extract') ||
          lower.contains('extrahier') ||
          lower.contains('read') ||
          lower.contains('lesen') ||
          lower.contains('content') ||
          lower.contains('inhalt') ||
          lower.contains('text') ||
          lower.contains('body') ||
          lower.contains('full') ||
          lower.contains('details') ||
          lower.contains('containing') ||
          lower.contains('enthalten') ||
          lower.contains('enthält');
      if (wantsBody) {
        patched['includeBody'] = true;
        talker.info(
          '🛡️ Auto-injected includeBody:true for Gmail based on user intent',
        );
        changed = true;
      }
    }

    return changed ? patched : args;
  }

  Map<String, dynamic> _repairMissingRequiredToolArgs(
    String toolName,
    Map<String, dynamic> args,
  ) {
    if (toolName == 'matplotlib_statistical_summary') {
      final incomingData = args['data'];
      if (incomingData is List && incomingData.isNotEmpty) {
        return args;
      }

      final repairedData = _extractNumericSeriesFromRecentToolResults();
      if (repairedData.isNotEmpty) {
        final patched = Map<String, dynamic>.from(args);
        patched['data'] = repairedData;
        talker.warning(
          '🛠️ Repaired empty matplotlib_statistical_summary.data from recent tool result (${repairedData.length} values)',
        );
        return patched;
      }

      return args;
    }

    if (toolName != 'web_search') return args;

    final existingQuery = (args['query'] as String?)?.trim();
    if (existingQuery != null && existingQuery.isNotEmpty) {
      return args;
    }

    final lastUserMessage = _messages.lastWhere(
      (m) => m.role == ChatRole.user,
      orElse: () => ChatMessage(
        id: '',
        content: '',
        role: ChatRole.user,
        timestamp: DateTime.now(),
      ),
    );

    final rebuiltQuery = _buildWebSearchQueryFromUserMessage(
      lastUserMessage.content,
      fallbackQuery: _lastWebSearchQuery,
    );
    if (rebuiltQuery.isEmpty) {
      return args;
    }

    final patched = Map<String, dynamic>.from(args);
    patched['query'] = rebuiltQuery;
    talker.warning(
      '🛠️ Repaired missing web_search.query from user context: "$rebuiltQuery"',
    );
    return patched;
  }

  List<double> _extractNumericSeriesFromRecentToolResults() {
    for (final message in _messages.reversed) {
      if (message.role != ChatRole.tool || message.toolResult == null) continue;

      for (final content in message.toolResult!.content) {
        final text = content.text?.trim();
        if (text == null || text.isEmpty || !text.startsWith('{')) continue;

        try {
          final decoded = jsonDecode(text);
          final series = _extractPreferredNumericSeries(decoded);
          if (series.isNotEmpty) {
            return series;
          }
        } catch (_) {
          // Ignore non-JSON tool texts.
        }
      }
    }

    return const [];
  }

  List<double> _extractPreferredNumericSeries(dynamic decoded) {
    // Prefer known weather arrays first, then fall back to any numeric list.
    final weatherCandidates = <String>[
      'temperature_2m',
      'apparent_temperature',
      'relative_humidity_2m',
      'wind_speed_10m',
      'precipitation',
      'precipitation_probability',
    ];

    if (decoded is Map) {
      final hourly = decoded['hourly'];
      if (hourly is Map) {
        for (final key in weatherCandidates) {
          final values = _toNumericList(hourly[key]);
          if (values.length >= 3) return values;
        }
      }
    }

    final fallback = _findFirstNumericList(decoded);
    return fallback.length >= 3 ? fallback : const [];
  }

  List<double> _findFirstNumericList(dynamic value) {
    final direct = _toNumericList(value);
    if (direct.isNotEmpty) return direct;

    if (value is Map) {
      for (final entry in value.entries) {
        final found = _findFirstNumericList(entry.value);
        if (found.isNotEmpty) return found;
      }
    } else if (value is List) {
      for (final item in value) {
        final found = _findFirstNumericList(item);
        if (found.isNotEmpty) return found;
      }
    }

    return const [];
  }

  List<double> _toNumericList(dynamic value) {
    if (value is! List || value.isEmpty) return const [];

    final out = <double>[];
    for (final item in value) {
      if (item is num) {
        out.add(item.toDouble());
      } else {
        return const [];
      }
    }
    return out;
  }

  String _buildWebSearchQueryFromUserMessage(
    String userText, {
    String? fallbackQuery,
  }) {
    final query = userText.trim();
    if (query.isNotEmpty) return query;

    final fallback = fallbackQuery?.trim() ?? '';
    if (fallback.isNotEmpty) return fallback;

    return '';
  }

  bool _isBlockedSftpExplorerToolCall(
    String toolName,
    Map<String, dynamic> args,
  ) {
    return false;
  }

  /// Replace natural-language month+year in an LLM-generated Gmail query with
  /// proper after:/before: syntax.
  String _normalizeGmailMonthYear(String query) {
    final monthPat = _monthMap.keys.join('|');
    return query.replaceAllMapped(
      RegExp('(?:im?\\s+)?($monthPat)\\s+(\\d{4})', caseSensitive: false),
      (m) {
        final monthName = m.group(1)!.toLowerCase();
        final year = int.tryParse(m.group(2) ?? '');
        if (year == null) return m.group(0)!;
        final month = _monthMap[monthName];
        if (month == null) return m.group(0)!;
        final nextMonth = month == 12 ? 1 : month + 1;
        final nextYear = month == 12 ? year + 1 : year;
        return 'after:${year.toString()}/${month.toString().padLeft(2, '0')}/01'
            ' before:${nextYear.toString()}/${nextMonth.toString().padLeft(2, '0')}/01';
      },
    );
  }

  String _normalizeGmailDateShortcuts(String query) {
    var normalized = query.trim();
    if (normalized.isEmpty) return normalized;

    final lower = normalized.toLowerCase();

    if (RegExp(r'\bafter:yesterday\b').hasMatch(lower) &&
        RegExp(r'\bbefore:today\b').hasMatch(lower)) {
      normalized = normalized.replaceAll(
        RegExp(r'\bafter:yesterday\b', caseSensitive: false),
        '',
      );
      normalized = normalized.replaceAll(
        RegExp(r'\bbefore:today\b', caseSensitive: false),
        '',
      );
      normalized = '$normalized newer_than:2d older_than:1d';
    } else {
      normalized = normalized.replaceAll(
        RegExp(r'\bafter:today\b', caseSensitive: false),
        'newer_than:1d',
      );
      normalized = normalized.replaceAll(
        RegExp(r'\bbefore:today\b', caseSensitive: false),
        'older_than:1d',
      );
      normalized = normalized.replaceAll(
        RegExp(r'\bafter:yesterday\b', caseSensitive: false),
        'newer_than:2d',
      );
      normalized = normalized.replaceAll(
        RegExp(r'\bbefore:yesterday\b', caseSensitive: false),
        'older_than:2d',
      );
    }

    normalized = normalized.replaceAll(RegExp(r'\s+'), ' ').trim();
    return normalized;
  }

  /// Check if response contains malformed tool calls (various unsupported formats)
  bool _containsMalformedToolCall(String content) {
    // Check for XML-style function calls: <function=name>...</function>
    if (RegExp(
      r'<function\s*=\s*\w+>',
      caseSensitive: false,
    ).hasMatch(content)) {
      return true;
    }

    // Check for tool_code format: {"tool_code": "..."}
    if (RegExp(
      r'''["']tool_code["']\s*:\s*["']''',
      caseSensitive: false,
      multiLine: true,
    ).hasMatch(content)) {
      return true;
    }

    // Check for other common malformed formats
    // <tool>name</tool> or [TOOL:name] etc.
    if (RegExp(
      r'<tool>\w+</tool>|<function>\w+</function>|\[TOOL:\w+\]',
      caseSensitive: false,
    ).hasMatch(content)) {
      return true;
    }

    return false;
  }

  /// Detect the specific type of tool call error
  String _detectToolCallErrorType(String content) {
    if (RegExp(
      r'<function\s*=\s*\w+>',
      caseSensitive: false,
    ).hasMatch(content)) {
      return 'xml_function';
    }
    if (RegExp(
      r'''["']tool_code["']\s*:\s*["']''',
      caseSensitive: false,
    ).hasMatch(content)) {
      return 'tool_code';
    }
    if (RegExp(
      r'<tool>\w+</tool>|<function>\w+</function>',
      caseSensitive: false,
    ).hasMatch(content)) {
      return 'xml_tags';
    }
    return 'unknown';
  }

  /// Get appropriate error message for tool call format error
  String _getToolCallErrorMessage(String errorType) {
    final buffer = StringBuffer();

    buffer.writeln(
      ' CRITICAL ERROR: Your model does not properly support native function calling!',
    );
    buffer.writeln();

    switch (errorType) {
      case 'xml_function':
        buffer.writeln(
          'You are outputting XML-style function calls like: <function=read_files>{"args"}<function>',
        );
        buffer.writeln(
          'This format is NOT supported by the native tool calling API.',
        );
        break;
      case 'tool_code':
        buffer.writeln(
          'You are using the format: {"tool_code": "print(...)"} which does NOT work.',
        );
        break;
      case 'xml_tags':
        buffer.writeln(
          'You are using XML tags like <tool>name</tool> which are NOT supported.',
        );
        break;
      default:
        buffer.writeln('You are using an unsupported tool calling format.');
    }

    buffer.writeln();
    buffer.writeln(
      'WARNING: YOUR CURRENT MODEL (${llmService.currentModel}) IS NOT SUITABLE FOR TOOL CALLING.',
    );
    buffer.writeln();
    buffer.writeln(
      ' SOLUTION: Switch to a model specifically trained for function calling:',
    );
    buffer.writeln();
    buffer.writeln('Recommended Ollama models:');
    buffer.writeln('  - llama3.1:70b-instruct-fp16 (NOT llama3.2)');
    buffer.writeln('  - mistral:latest or mixtral:latest');
    buffer.writeln('  - qwen2.5:latest (excellent function calling)');
    buffer.writeln('  - command-r:latest (designed for tool use)');
    buffer.writeln();
    buffer.writeln('For OpenAI Compatible providers (DeepInfra, etc.):');
    buffer.writeln('  - meta-llama/Meta-Llama-3.1-70B-Instruct');
    buffer.writeln('  - mistralai/Mixtral-8x7B-Instruct-v0.1');
    buffer.writeln();
    buffer.writeln(
      'To change models: Open Settings -> LLM Configuration -> Select a function-calling model',
    );
    buffer.writeln();
    buffer.writeln(
      'NOTE: Llama 3.2 was NOT trained for function calling and will produce malformed tool calls.',
    );

    return buffer.toString();
  }

  /// Process LLM response with retry mechanism for UNEXPECTED_TOOL_CALL errors
  Future<void> _processLLMResponseWithRetry({int maxRetries = 2}) async {
    int retries = 0;

    while (retries <= maxRetries) {
      try {
        await _processLLMResponse();
        return; // Success, exit retry loop
      } catch (e) {
        if (e.toString().contains('UNEXPECTED_TOOL_CALL') &&
            retries < maxRetries) {
          retries++;
          logWorkflowStep(
            'Retry Attempt',
            'UNEXPECTED_TOOL_CALL error, retry $retries/$maxRetries',
          );
          talker.warning(
            'UNEXPECTED_TOOL_CALL error, retrying... Attempt $retries/$maxRetries',
          );

          // Brief delay before retry
          await Future.delayed(const Duration(milliseconds: 500));
          continue;
        }

        // If it's not an UNEXPECTED_TOOL_CALL error, or we've exhausted retries, rethrow
        rethrow;
      }
    }
  }

  /// Handle tool calls from LLM
  Future<void> _handleToolCalls(LLMResponse response) async {
    // Increment iteration counter
    _toolIterationCount++;

    // Check iteration limit to prevent infinite loops
    if (_toolIterationCount > _maxToolIterations) {
      talker.error(
        'âš ï¸ Max tool iterations ($_maxToolIterations) reached - stopping agentic loop',
      );
      _processingType = ProcessingType.none;
      _toolIterationCount = 0; // Reset for next user message
      notifyListeners();

      final errorMessage = ChatMessage(
        id: _uuid.v4(),
        content:
            'Maximum tool iteration limit reached. Please refine your request or ask for help.',
        role: ChatRole.assistant,
        timestamp: DateTime.now(),
      );
      _addMessage(errorMessage);
      return;
    }

    // Switch to MCP processing mode
    _processingType = ProcessingType.mcp;
    notifyListeners();

    talker.info(
      'Starting tool call handling for ${response.toolCalls.length} tools (iteration $_toolIterationCount/$_maxToolIterations)',
    );

    // Check if LLM response text contains invalid tool_code format
    if (response.content.contains('"tool_code"')) {
      talker.error('CRITICAL: LLM used INVALID "tool_code" format');
      talker.error('Only "tool_call" format is supported');

      // Create error message to send back to LLM
      const errorResult = MCPToolResult(
        content: [
          MCPContent(
            type: 'text',
            text: '''ERROR: You used the WRONG format! 

FORBIDDEN FORMAT (what you did):
{"tool_code": "print(matplotlib_create_line_plot(...))"}

REQUIRED FORMAT (what you must use):
{
  "tool_call": {
    "name": "matplotlib_create_line_plot",
    "arguments": {"datasets": [...], ...}
  }
}

CRITICAL RULES:
1. NEVER use "tool_code" - it does NOT work
2. NEVER use print() statements
3. ALWAYS use "tool_call" with "name" and "arguments"
4. Execute the tool call again using the CORRECT format shown above''',
          ),
        ],
        isError: true,
      );

      final errorMessage = ChatMessage(
        id: _uuid.v4(),
        content:
            'Invalid tool format detected. Please retry with correct "tool_call" format.',
        role: ChatRole.tool,
        timestamp: DateTime.now(),
        toolResult: errorResult,
      );

      _addMessage(errorMessage);

      // Retry LLM call with error feedback
      talker.warning('Retrying LLM call due to invalid tool_code format...');
      await _processLLMResponse();
      return;
    }

    final toolResults = <MCPToolResult>[];

    // Execute each tool call
    for (final toolCall in response.toolCalls) {
      logToolCall(toolCall.name, toolCall.arguments);

      // Log tool call with parameters preview
      final argsPreview = jsonEncode(toolCall.arguments);
      final argsShort = argsPreview.length > 80
          ? '${argsPreview.substring(0, 80)}...'
          : argsPreview;
      talker.info('ðŸ”§ Tool call: ${toolCall.name}($argsShort)');

      // Clean up tool name - remove any server prefixes that LLM might have added
      String cleanToolName = toolCall.name;
      if (cleanToolName.startsWith('WSAgrar.')) {
        cleanToolName = cleanToolName.replaceFirst('WSAgrar.', '');
        talker.warning(
          'Removed WSAgrar prefix from tool name: ${toolCall.name} -> $cleanToolName',
        );
      }
      if (cleanToolName.startsWith('matplotlib.')) {
        cleanToolName = cleanToolName.replaceFirst('matplotlib.', '');
        talker.warning(
          'Removed matplotlib prefix from tool name: ${toolCall.name} -> $cleanToolName',
        );
      }

      try {
        final normalizedArgs = _normalizeToolArguments(
          cleanToolName,
          toolCall.arguments,
        );
        final toolSignature = '$cleanToolName|${jsonEncode(normalizedArgs)}';

        final hasDuplicateId =
            toolCall.id != null && _executedToolCallIds.contains(toolCall.id);
        final hasDuplicateSignature = _executedToolCallSignatures.contains(
          toolSignature,
        );

        if (hasDuplicateId || hasDuplicateSignature) {
          talker.warning(
            '⚠️ Repeated tool call detected for "$cleanToolName" (duplicate ID: $hasDuplicateId, duplicate signature: $hasDuplicateSignature). '
            'Intercepting and forcing finalization turn.',
          );

          _forceNoToolCallsNextTurn = true;
          _forcedNoToolHintNextTurn =
              'The tool "$cleanToolName" has already been successfully executed with these parameters. '
              'Do NOT call this tool or any other tool again. Use the tool results in the history to write your final response now.';

          final loopCorrectionText =
              'The tool "$cleanToolName" was already executed successfully and its return data is already in the conversation above. '
              'Do NOT call "$cleanToolName" with identical parameters again. '
              'If you need another tool to complete the task, call the next tool now. '
              'Otherwise, use the existing results in context to formulate your final response immediately.';

          final errorResult = MCPToolResult(
            content: [MCPContent(type: 'text', text: loopCorrectionText)],
            isError: false,
          );

          final toolCallId = toolCall.id ?? _uuid.v4();
          final structuredResponse = {
            'tool': cleanToolName,
            'id': toolCallId,
            'tool_executed': true,
            'tool_result': loopCorrectionText,
          };
          final structuredContent = jsonEncode(structuredResponse);

          final toolMessage = ChatMessage(
            id: toolCallId,
            content: structuredContent,
            role: ChatRole.tool,
            timestamp: DateTime.now(),
            toolResult: errorResult,
            lastCalledToolName: cleanToolName,
          );
          _addMessage(toolMessage);

          try {
            await _processLLMResponse();
          } catch (e) {
            talker.error('Forced loop finalization turn failed: $e');
            final loopGuardMessage = ChatMessage(
              id: _uuid.v4(),
              content:
                  '⚠️ **Stopped a repeated tool loop**\n\n'
                  'The tool `$cleanToolName` was requested repeatedly. '
                  'A forced finalization attempt failed.',
              role: ChatRole.system,
              timestamp: DateTime.now(),
            );
            _addMessage(loopGuardMessage);
            _processingType = ProcessingType.none;
            _toolIterationCount = 0;
            notifyListeners();
          }
          return;
        }

        if (toolCall.id != null) {
          _executedToolCallIds.add(toolCall.id!);
        }
        _executedToolCallSignatures.add(toolSignature);

        // Check if cleaned tool exists
        final toolExists = mcpClient.availableTools.any(
          (t) => t.name == cleanToolName,
        );

        if (!toolExists) {
          // Tool doesn't exist - create error result immediately
          talker.error('Tool "$cleanToolName" not found in available tools');
          talker.info(
            'Available tools: ${mcpClient.availableTools.map((t) => t.name).join(", ")}',
          );

          final errorResult = MCPToolResult(
            content: [
              MCPContent(
                type: 'text',
                text:
                    'Error: Tool "$cleanToolName" does not exist. Available tools: ${mcpClient.availableTools.map((t) => t.name).take(10).join(", ")}${mcpClient.availableTools.length > 10 ? "..." : ""}',
              ),
            ],
            isError: true,
          );

          toolResults.add(errorResult);

          final errorMessage = ChatMessage(
            id: _uuid.v4(),
            content:
                'Tool error: "$cleanToolName" is not available. Please use one of the available tools.',
            role: ChatRole.tool,
            timestamp: DateTime.now(),
            toolResult: errorResult,
          );

          _addMessage(errorMessage);
          continue; // Skip to next tool
        }

        // VALIDATE PARAMETERS AGAINST SCHEMA
        final tool = mcpClient.availableTools.firstWhere(
          (t) => t.name == cleanToolName,
        );

        // Remap Python reserved-word aliases (e.g. "from_" → "from", "id_" → "id")
        // before validation so the LLM is not penalised for that naming quirk.
        final schemaFixedArgs = _remapPythonKeywordAliases(
          normalizedArgs,
          tool,
        );
        final coercedArgs = _coerceToolArgumentsToSchema(
          cleanToolName,
          schemaFixedArgs,
          tool,
        );
        final repairedArgs = _repairMissingRequiredToolArgs(
          cleanToolName,
          coercedArgs,
        );

        final paramValidationError = _validateToolParameters(
          cleanToolName,
          repairedArgs,
          tool,
        );

        if (paramValidationError != null) {
          talker.error(
            'Parameter validation failed for $cleanToolName: $paramValidationError',
          );

          final errorResult = MCPToolResult(
            content: [MCPContent(type: 'text', text: paramValidationError)],
            isError: true,
          );

          toolResults.add(errorResult);

          final errorMessage = ChatMessage(
            id: _uuid.v4(),
            content: paramValidationError,
            role: ChatRole.tool,
            timestamp: DateTime.now(),
            toolResult: errorResult,
          );

          _addMessage(errorMessage);

          final autoRecovery =
              LlmSettingsService.instance.enableToolParameterAutoRecovery;
          if (autoRecovery && _paramValidationRetryCount == 0) {
            talker.warning(
              '⚠️ Parameter validation error detected - will retry once with corrective prompt',
            );
            _paramValidationRetryCount++;
          }

          continue; // Skip to next tool - LLM will retry with correct parameters
        }

        // Auto-convert search_file_name to list_all_files_recursive for file listings
        // This handles cases where LLM uses the wrong tool despite instructions
        Map<String, dynamic> toolArguments = repairedArgs;

        if (_isBlockedSftpExplorerToolCall(cleanToolName, toolArguments)) {
          talker.warning(
            'Blocked SFTP explorer tool for Free plan: $cleanToolName',
          );

          final errorResult = MCPToolResult(
            content: const [
              MCPContent(
                type: 'text',
                text:
                    'SFTP Explorer is a Pro feature. Upgrade to Pro to browse, read, upload, or download via SSH/SFTP tools.',
              ),
            ],
            isError: true,
          );

          toolResults.add(errorResult);

          final errorMessage = ChatMessage(
            id: toolCall.id ?? _uuid.v4(),
            content: 'Tool blocked by plan: $cleanToolName requires Pro.',
            role: ChatRole.tool,
            timestamp: DateTime.now(),
            toolResult: errorResult,
          );

          _addMessage(errorMessage);
          continue;
        }

        talker.info(
          'ðŸ”§ Processing tool: $cleanToolName with arguments: ${toolCall.arguments.keys.toList()}',
        );

        // Special handling for download_file.
        // SSH/SFTP download_file uses 'path' argument — route through MCP tool directly (SFTP).
        // HTTP-based download_file uses 'file_path' — use FileDownloadService.
        MCPToolResult result;
        if (cleanToolName == 'download_file') {
          final isSftpDownload =
              toolArguments.containsKey('path') &&
              !toolArguments.containsKey('file_path');
          if (!isSftpDownload && _fileDownloadService != null) {
            talker.info('Using FileDownloadService for chunked download');
            result = await _executeChunkedDownload(toolArguments);
          } else {
            talker.info(
              'Using direct MCP call for SFTP/SSH download_file (path=${toolArguments['path']})',
            );
            final rawSftpResult = await mcpClient.callTool(
              cleanToolName,
              toolArguments,
            );
            // Save to device and replace binary result with clean summary for LLM.
            result = await _handleSftpDownloadResult(
              rawSftpResult,
              toolArguments['path'] as String? ?? '',
            );
          }
        } else {
          // Call the MCP tool with cleaned name
          result = await mcpClient.callTool(cleanToolName, toolArguments);
        }

        // DEBUG: Log tool result structure
        talker.info(
          'ðŸ” Tool result has ${result.content.length} content items:',
        );
        for (int i = 0; i < result.content.length; i++) {
          final c = result.content[i];
          talker.info(
            '  [$i] type="${c.type}", mimeType="${c.mimeType ?? "none"}", hasData=${c.data != null}, dataLength=${c.data?.length ?? 0}, hasText=${c.text != null}, textLength=${c.text?.length ?? 0}',
          );
        }

        // CRITICAL: Filter binary content from result BEFORE adding to toolResults
        // This prevents binary data from being sent to LLM in follow-up response
        final filteredResultForLLM = MCPToolResult(
          content: result.content
              .where((c) {
                // CRITICAL: Exclude if has binary data field (base64)
                if (c.data != null && c.data!.isNotEmpty) {
                  talker.warning(
                    'ðŸš« BLOCKED binary DATA field from LLM: ${c.data!.length} chars, mimeType="${c.mimeType ?? "none"}"',
                  );
                  return false;
                }

                // Exclude binary content by MIME type
                if (c.mimeType != null) {
                  final mime = c.mimeType!.toLowerCase();
                  if (mime.startsWith('application/vnd.') || // Office documents
                      mime.startsWith('application/octet-stream') ||
                      mime.startsWith('application/zip') ||
                      mime.startsWith('application/x-') ||
                      mime.contains('spreadsheet') ||
                      mime.contains('officedocument')) {
                    talker.warning('ðŸš« BLOCKED binary MIME from LLM: $mime');
                    return false;
                  }
                }

                // Exclude images
                if (c.type == 'image') {
                  talker.warning('ðŸš« BLOCKED image type from LLM');
                  return false;
                }

                // Only include if has text content
                if (c.text == null || c.text!.isEmpty) {
                  talker.warning('ðŸš« BLOCKED (no text content)');
                  return false;
                }

                talker.info(
                  'âœ… ALLOWING text to LLM: ${c.text!.length} chars',
                );
                return true;
              })
              .map((c) {
                // Replace full directory listing with a short summary for LLM.
                // The full listing is shown interactively in the UI; there is no
                // need to send every entry to the model.
                if ((cleanToolName == 'list_directory' ||
                        cleanToolName == 'list_files') &&
                    c.text != null) {
                  try {
                    final j = jsonDecode(c.text!) as Map<String, dynamic>;
                    if (j['entries'] is List) {
                      final entries = j['entries'] as List;
                      final dirCount = entries
                          .where((e) => e is Map && e['isDirectory'] == true)
                          .length;
                      final fileCount = entries.length - dirCount;
                      final summary = jsonEncode({
                        'path': j['path'],
                        'count': entries.length,
                        'directories': dirCount,
                        'files': fileCount,
                        'note':
                            'Full listing rendered in UI. Do not repeat the file list.',
                      });
                      talker.info(
                        '📁 Truncated directory listing for LLM: ${entries.length} entries → summary',
                      );
                      return MCPContent(
                        type: c.type,
                        text: summary,
                        mimeType: c.mimeType,
                      );
                    }
                  } catch (_) {}
                }
                return c;
              })
              .map((c) {
                // CRITICAL: Strip binary content from JSON responses
                String text = c.text!;

                // Check if this looks like a JSON response with binary content
                if (text.trimLeft().startsWith('{') && text.length > 10000) {
                  try {
                    final json = jsonDecode(text);
                    if (json is Map &&
                        json['data'] is Map &&
                        json['data']['content'] is String) {
                      final contentLength =
                          (json['data']['content'] as String).length;
                      if (contentLength > 5000) {
                        // This is likely base64 binary - strip it
                        talker.warning(
                          'STRIPPING $contentLength char binary content from tool result',
                        );

                        final summary = {
                          'success': json['success'],
                          'message':
                              'File ready for download. DO NOT generate or provide binary/base64 content. Just confirm the file is available.',
                        };

                        text = jsonEncode(summary);
                        talker.info(
                          'âœ… Replaced with ${text.length} char summary',
                        );
                      }
                    }
                  } catch (e) {
                    // Keep original if not parseable
                  }
                }

                return MCPContent(
                  type: c.type,
                  text: text,
                  mimeType: c.mimeType,
                );
              })
              .map((c) {
                // Strip file output content (base64-encoded files from output:file)
                final strippedFile = _stripFileOutputContent(
                  c.text!,
                  toolArguments,
                );
                return MCPContent(
                  type: c.type,
                  text: strippedFile,
                  mimeType: c.mimeType,
                );
              })
              .map((c) {
                // Strip embedded base64 data URIs (e.g., [file.xlsx](data:...;base64,...))
                final stripped = _stripEmbeddedBase64(c.text!);
                return MCPContent(
                  type: c.type,
                  text: stripped,
                  mimeType: c.mimeType,
                );
              })
              .toList(),
          isError: result.isError,
        );

        toolResults.add(filteredResultForLLM); // Add FILTERED result for LLM

        // CRITICAL: Check if filtering removed ALL content - this breaks the agentic loop!
        if (filteredResultForLLM.content.isEmpty) {
          talker.error(
            'ðŸš¨ CRITICAL BUG DETECTED: Filtering removed ALL content from tool result!',
          );
          talker.error(
            '   Original result had ${result.content.length} content items',
          );
          talker.error(
            '   This will break the agentic loop - adding placeholder content',
          );

          // Add a placeholder text content so LLM knows the tool executed successfully
          final placeholderResult = MCPToolResult(
            content: [
              MCPContent(
                type: 'text',
                text:
                    'Tool "$cleanToolName" executed successfully. Result contained binary/non-text data that was filtered out for LLM processing.',
              ),
            ],
            isError: false,
          );

          // Replace the empty result with placeholder
          toolResults[toolResults.length - 1] = placeholderResult;
          talker.warning(
            'âœ… Replaced empty result with placeholder text for LLM',
          );
        }

        logToolResult(
          cleanToolName,
          'Success: ${result.content.length} content items',
        );

        // Calculate total character count of the FILTERED tool result that is sent to the LLM
        // (raw result may contain large binary/base64 payloads intended only for UI download)
        int totalResultChars = 0;
        for (final content in filteredResultForLLM.content) {
          if (content.text != null) {
            totalResultChars += content.text!.length;
          } else if (content.data != null) {
            // Binary file/resource payloads are kept for UI download and stripped from LLM context,
            // so they should not trigger conversation cancellation.
            final mime = (content.mimeType ?? '').toLowerCase();
            final isBinaryResource =
                content.type == 'resource' ||
                content.type == 'file' ||
                mime.contains('pdf') ||
                mime.contains('excel') ||
                mime.contains('spreadsheet');

            if (!isBinaryResource) {
              // Estimate base64 data size (roughly 1.33x original) for non-file binary payloads
              totalResultChars += (content.data!.length * 1.33).round();
            }
          }
        }

        // Check if tool output exceeds the configured limit
        final maxOutputChars = llmService.maxToolOutputChars;
        if (maxOutputChars > 0 && totalResultChars > maxOutputChars) {
          talker.error(
            'Tool output too large: $totalResultChars chars (limit: $maxOutputChars)',
          );

          // Create error result explaining the size issue
          final sizeErrorResult = MCPToolResult(
            content: [
              MCPContent(
                type: 'text',
                text:
                    'TOOL OUTPUT TOO LARGE\n\n'
                    'The tool "$cleanToolName" returned $totalResultChars characters, which exceeds the configured limit of $maxOutputChars characters.\n\n'
                    'CONVERSATION CANCELLED\n\n'
                    'This prevents sending excessive data to the LLM, which would:\n'
                    '- Consume unnecessary tokens and increase cost\n'
                    '- Slow down processing significantly\n'
                    '- Likely get truncated anyway\n\n'
                    'RECOMMENDED ACTIONS:\n'
                    '1. Use more specific query parameters to reduce result size\n'
                    '2. Request data for a shorter time period\n'
                    '3. Increase the limit in Settings > LLM Configuration > Advanced Settings > Max Tool Output Size\n'
                    '4. Process data in smaller chunks\n\n'
                    'Current limit: $maxOutputChars characters (~${(maxOutputChars / 4).round()} tokens)',
              ),
            ],
            isError: true,
          );

          // Add error message to chat
          final errorMessage = ChatMessage(
            id: _uuid.v4(),
            content:
                'WARNING: Tool output too large ($totalResultChars chars, limit: $maxOutputChars chars). Conversation cancelled to prevent excessive token usage.',
            role: ChatRole.assistant,
            timestamp: DateTime.now(),
            toolResult: sizeErrorResult,
          );

          _addMessage(errorMessage);

          // Stop processing - don't send to LLM
          _processingType = ProcessingType.none;
          notifyListeners();
          return;
        }

        talker.info(
          ' Tool output size: $totalResultChars chars (within limit: ${maxOutputChars > 0 ? "$maxOutputChars chars" : "unlimited"})',
        );

        // Log tool response with preview (first 100 chars of first text content)
        String responsePreview = 'Success';
        if (result.content.isNotEmpty) {
          final firstContent = result.content.first;
          if (firstContent.text != null && firstContent.text!.isNotEmpty) {
            responsePreview = firstContent.text!.length > 100
                ? '${firstContent.text!.substring(0, 100)}...'
                : firstContent.text!;
          } else if (firstContent.data != null) {
            responsePreview =
                'Binary data (${firstContent.mimeType ?? "unknown type"})';
          }
        }
        talker.info(' Tool response: $responsePreview');

        // Track last called tool for context
        _lastCalledToolName = cleanToolName;
        if (cleanToolName == 'search_gmail') {
          final q = toolArguments['q']?.toString().trim() ?? '';
          if (q.isNotEmpty) {
            _lastGmailQuery = q;
          }
        } else if (cleanToolName == 'web_search') {
          final q = toolArguments['query']?.toString().trim() ?? '';
          if (q.isNotEmpty) {
            _lastWebSearchQuery = q;
          }
        }

        // If the tool returned binary file data, stop further tool calls next turn.
        // This prevents the LLM from hallucinating follow-up tool calls after a file is created.
        if (result.content.any((c) => c.data != null && c.data!.isNotEmpty)) {
          talker.info(
            'Binary file returned by "$cleanToolName" - forcing no-tool final turn',
          );
          _forceNoToolCallsNextTurn = true;
          _forcedNoToolHintNextTurn =
              'The file was created successfully and is available to the user. '
              'Provide a short confirmation message only. Do NOT call any more tools.';
        }

        // Add tool call message (use original name for display but cleaned name for execution)
        // IMPORTANT: For native tool calling, the message ID must match the tool call ID
        // so that LangChain can correlate tool results with their original calls
        // SKIP tool message for download_file - it has special UI handling with progress widget
        if (cleanToolName != 'download_file') {
          final toolMessage = ChatMessage(
            id:
                toolCall.id ??
                _uuid
                    .v4(), // Use the tool call ID from LLM response, fallback to UUID
            content:
                'Called tool: $cleanToolName\nArguments: ${jsonEncode(toolArguments)}',
            role: ChatRole.tool,
            timestamp: DateTime.now(),
            toolResult:
                result, // Use ORIGINAL result WITH full content for user display
            lastCalledToolName: _lastCalledToolName,
          );
          _addMessage(toolMessage);
        } else {
          talker.info(
            'Skipping tool message for $cleanToolName - special UI handling',
          );
        }
      } catch (e) {
        // Add tool error message
        logToolResult(cleanToolName, e.toString(), isError: true);

        // Check if this is a parameter validation error
        final isParameterValidationError = e.toString().contains(
          'Parameter validation',
        );

        final errorResult = MCPToolResult(
          content: [
            MCPContent(type: 'text', text: 'Error calling $cleanToolName: $e'),
          ],
          isError: true,
        );

        toolResults.add(errorResult);

        final errorMessage = ChatMessage(
          id:
              toolCall.id ??
              _uuid.v4(), // Match tool call ID for native tool calling
          content: 'Tool error: ${toolCall.name} failed with: $e',
          role: ChatRole.tool,
          timestamp: DateTime.now(),
          toolResult: errorResult,
        );

        _addMessage(errorMessage);

        // If parameter validation error and first attempt, allow retry
        if (isParameterValidationError && _paramValidationRetryCount == 0) {
          talker.warning(
            'âš ï¸ Parameter validation error detected - will retry once with corrective prompt',
          );
          _paramValidationRetryCount++;
          // Don't set hasToolError flag - allow continuation to LLM for retry
        }
      }
    }

    // Check if any tool execution failed - if so, stop processing
    // Exception: Parameter validation errors get ONE retry
    final hasToolError = toolResults.any((result) {
      if (result.isError != true) return false;

      // Check if this is a parameter validation error
      final errorText = result.content.firstOrNull?.text ?? '';
      final isParamValidationError = errorText.contains('Parameter validation');

      // Allow first parameter validation error to continue for retry
      if (isParamValidationError && _paramValidationRetryCount == 1) {
        return false; // Don't count as blocking error on first occurrence
      }

      return true; // All other errors or second validation error stops processing
    });

    if (hasToolError) {
      talker.error(
        '\u{1F6D1} Tool execution failed - stopping agentic loop (one tool returned an error)',
      );

      // Collect error details from failed tools to show the user
      final errorDetails = toolResults
          .where((r) => r.isError == true)
          .map((r) => r.content.firstOrNull?.text ?? 'Unknown tool error')
          .join('\n');

      // Replace last 'Calling tools...' placeholder with the actual error,
      // or add a new system message if no placeholder exists.
      final placeholderIdx = _messages.lastIndexWhere(
        (m) =>
            (m.role == ChatRole.assistant || m.role == ChatRole.system) &&
            m.content.contains(
              'Calling tools to retrieve the requested information...',
            ),
      );
      final errorContent = '❌ **Tool execution failed**\n\n$errorDetails';
      if (placeholderIdx != -1) {
        _messages[placeholderIdx] = ChatMessage(
          id: _messages[placeholderIdx].id,
          content: errorContent,
          role: ChatRole.system,
          timestamp: _messages[placeholderIdx].timestamp,
        );
      } else {
        _addMessage(
          ChatMessage(
            id: _uuid.v4(),
            content: errorContent,
            role: ChatRole.system,
            timestamp: DateTime.now(),
          ),
        );
      }

      _processingType = ProcessingType.none;
      _toolIterationCount = 0;
      _paramValidationRetryCount = 0; // Reset retry counter
      notifyListeners();
      return;
    }
    // AGENTIC LOOP: Continue with LLM processing, tools still enabled
    // The system prompt contains autonomous chaining rules, no need for additional reminders
    talker.info(
      'ðŸ”„ Tool execution complete, continuing agentic loop (iteration $_toolIterationCount/$_maxToolIterations)',
    );
    talker.info('   Tool results collected: ${toolResults.length}');
    talker.info('   hasToolError check: $hasToolError');
    for (int i = 0; i < toolResults.length; i++) {
      final result = toolResults[i];
      talker.info(
        '   Result[$i]: isError=${result.isError}, contentItems=${result.content.length}',
      );
    }

    // CRITICAL: Check iteration limit BEFORE continuing to prevent infinite loops
    if (_toolIterationCount >= _maxToolIterations) {
      talker.error(
        'âš ï¸ Max tool iterations ($_maxToolIterations) reached BEFORE next LLM call - stopping agentic loop',
      );
      _processingType = ProcessingType.none;
      _toolIterationCount = 0; // Reset for next user message
      notifyListeners();

      final errorMessage = ChatMessage(
        id: _uuid.v4(),
        content:
            'âš ï¸ **Maximum Tool Iteration Limit Reached**\n\n'
            'The AI attempted too many tool calls in a row (limit: $_maxToolIterations iterations).\n\n'
            'This usually happens when:\n'
            '- The request is too complex and needs to be broken down\n'
            '- The AI is stuck in a loop calling the same tools repeatedly\n'
            '- Missing required data prevents the AI from completing the task\n\n'
            'Please try:\n'
            '- Breaking your request into smaller, simpler steps\n'
            '- Providing more specific information\n'
            '- Asking for help with a different approach',
        role: ChatRole.system,
        timestamp: DateTime.now(),
      );
      _addMessage(errorMessage);
      return;
    }

    // QWEN WORKAROUND: Qwen can only make ~2 tool calls per turn
    // For OpenAI-compatible providers, automatically continue after tool execution
    // This allows Qwen to chain more than 2 tool calls by making multiple turns
    final currentProvider = llmService.currentProvider;
    if (currentProvider == LLMProvider.openaiCompatible &&
        response.toolCalls.length >= 2) {
      talker.info(
        'âš¡ OpenAI-compatible provider detected with ${response.toolCalls.length} tool calls - auto-continuing for Qwen multi-step support',
      );
    }

    // stopAfterToolCall: halt after the first tool round-trip.
    if ((stopAfterToolCall && _subPromptContextStartCount == -1) ||
        _subPromptStopAfterToolCall) {
      talker.info('Stop after tool call — halting agentic loop');
      _processingType = ProcessingType.none;
      _toolIterationCount = 0;
      notifyListeners();
      return;
    }

    // CRITICAL: Ensure we continue the agentic loop
    talker.info(
      'ðŸ”„ CONTINUING TO NEXT LLM CALL - Tool iteration $_toolIterationCount/$_maxToolIterations',
    );

    try {
      await _processLLMResponse();
      talker.info('âœ… Next LLM call completed successfully');
    } catch (e, stackTrace) {
      talker.error(
        'âŒ CRITICAL: Exception during agentic loop continuation: $e',
      );
      talker.error('Stack trace: $stackTrace');

      // Add error message to chat
      final errorMessage = ChatMessage(
        id: _uuid.v4(),
        content:
            'âš ï¸ **Error During Tool Processing Chain**\n\n'
            'An error occurred while continuing the conversation after tool execution:\n\n'
            '$e\n\n'
            'The conversation has been stopped. Please try again or rephrase your request.',
        role: ChatRole.system,
        timestamp: DateTime.now(),
      );
      _addMessage(errorMessage);

      // Reset processing state
      _processingType = ProcessingType.none;
      _toolIterationCount = 0;
      notifyListeners();

      rethrow; // Re-throw to ensure error is not silently swallowed
    }
  }

  /// Check if MCPContent contains a file list (array of file paths)
  /// Returns tuple: (isFileList, fileCount)
  (bool, int) _checkFileList(MCPContent content) {
    if (content.text == null) return (false, 0);

    try {
      final jsonData = jsonDecode(content.text!);

      List<dynamic>? fileList;

      // Check for direct array format: ["file1.docx", "file2.pdf"]
      if (jsonData is List) {
        fileList = jsonData;
      }
      // Check for object with results: {"results": ["file1.docx", "file2.pdf"]}
      else if (jsonData is Map && jsonData['results'] is List) {
        fileList = jsonData['results'] as List;
      }

      if (fileList != null && fileList.isNotEmpty) {
        // Check if it's a file list (array of strings with file extensions)
        final firstItem = fileList.first;
        String? firstPath;

        // Handle string paths
        if (firstItem is String) {
          firstPath = firstItem;
        }
        // Handle object with path: {"path": "file.docx", ...}
        else if (firstItem is Map && firstItem['path'] is String) {
          firstPath = firstItem['path'] as String;
        }
        // Handle search results: {"file": "file.docx", "line_number": "123", "line": "..."}
        // These should NOT be treated as file lists - they are search results
        else if (firstItem is Map &&
            firstItem['file'] is String &&
            (firstItem['line'] != null || firstItem['line_number'] != null)) {
          talker.info(
            'ðŸ“„ Detected search results (not a file list), will send full content to LLM',
          );
          return (
            false,
            0,
          ); // Not a simple file list - it's search results with context
        }

        if (firstPath != null) {
          // Check if it looks like a file path with valid extension
          final parts = firstPath.split('.');
          if (parts.length >= 2) {
            final extension = parts.last.toLowerCase();
            // Valid file extension: 2-5 characters, alphanumeric
            if (extension.length >= 2 &&
                extension.length <= 5 &&
                _extensionPattern.hasMatch(extension)) {
              talker.info(
                'ðŸ“„ Detected file list with ${fileList.length} files, first: $firstPath',
              );
              return (true, fileList.length);
            }
          }
        }
      }
    } catch (e) {
      // Not JSON or not our format
    }

    return (false, 0);
  }

  /// Strip file output content (base64-encoded files) from tool results before sending to LLM.
  /// When tools return files (output: file), the content is base64-encoded and useless for LLM processing.
  /// The file is already displayed to the user via the tool result widget.
  String _stripFileOutputContent(String text, Map<String, dynamic>? arguments) {
    // If tool was called with output: file, replace entire content with summary
    if (arguments != null && arguments['output'] == 'file') {
      final format = arguments['format'] ?? 'data';
      final filename = arguments['filename'] ?? 'file';
      talker.warning(
        '🚫 STRIPPED file output content ($format) from LLM: ${text.length} chars',
      );
      return 'Tool returned a $format file for "$filename" (${text.length} chars). The file is displayed to the user. Do NOT reproduce the file content. Just confirm the file is ready.';
    }

    // Also detect base64-encoded content even without output:file flag
    // Base64 text is long runs of [A-Za-z0-9+/=] with no spaces
    if (text.length > 500) {
      // Check if the text itself is base64 (no JSON wrapper)
      final trimmed = text.trim();
      if (RegExp(r'^[A-Za-z0-9+/=\r\n]{200,}$').hasMatch(trimmed)) {
        talker.warning(
          'ðŸš« STRIPPED raw base64 content from LLM: ${text.length} chars',
        );
        return 'Tool returned a file (${text.length} chars, base64-encoded). The file is displayed to the user. Do NOT reproduce the file content.';
      }

      // Check if JSON contains large base64 field
      if (trimmed.startsWith('{')) {
        try {
          final json = jsonDecode(trimmed);
          if (json is Map) {
            final stripped = _stripBase64FieldsFromJson(json);
            if (stripped != null) return jsonEncode(stripped);
          }
        } catch (_) {}
      }
    }

    return text;
  }

  /// Recursively check JSON map for large base64-like string values and replace them
  Map<String, dynamic>? _stripBase64FieldsFromJson(Map json) {
    bool modified = false;
    final result = <String, dynamic>{};

    for (final entry in json.entries) {
      if (entry.value is String) {
        final str = entry.value as String;
        if (str.length > 500 &&
            RegExp(r'^[A-Za-z0-9+/=\r\n]{200,}$').hasMatch(str.trim())) {
          result[entry.key] = '[file content removed - ${str.length} chars]';
          modified = true;
          talker.warning(
            'ðŸš« STRIPPED base64 field "${entry.key}" from JSON: ${str.length} chars',
          );
        } else {
          result[entry.key] = entry.value;
        }
      } else if (entry.value is Map) {
        final innerStripped = _stripBase64FieldsFromJson(entry.value as Map);
        if (innerStripped != null) {
          result[entry.key] = innerStripped;
          modified = true;
        } else {
          result[entry.key] = entry.value;
        }
      } else {
        result[entry.key] = entry.value;
      }
    }

    return modified ? result : null;
  }

  /// Strip embedded base64 data URIs from text content before sending to LLM.
  /// Matches patterns like: [filename.xlsx](data:application/...;base64,...) or [here](data:;base64,...)
  /// Replaces with plain text so the model does not echo a fake markdown download link.
  static final _embeddedBase64Pattern = RegExp(
    r'\[([^\]]+)\]\(\s*data:[^;\s\)]*;base64,[A-Za-z0-9+/=\s\r\n]+\s*\)',
    dotAll: true,
    caseSensitive: false,
  );

  String _stripEmbeddedBase64(String text) {
    if (!text.contains('base64,')) return text;

    final stripped = text.replaceAllMapped(_embeddedBase64Pattern, (match) {
      final fileName = match.group(1) ?? 'file';
      talker.warning(
        'ðŸš« STRIPPED embedded base64 file from LLM text: $fileName (${match.group(0)!.length} chars)',
      );
      return 'File generated: $fileName (binary content removed from LLM context).';
    });

    if (stripped.length < text.length) {
      talker.info(
        'âœ… Reduced text from ${text.length} to ${stripped.length} chars by stripping embedded base64',
      );
    }
    return stripped;
  }

  /// Filter file list content for LLM - send full list (with truncation for very large lists)
  /// Returns modified content or original if not a file list
  MCPContent _filterFileListForLLM(MCPContent content) {
    final (isFileList, fileCount) = _checkFileList(content);

    if (!isFileList) {
      return content; // Not a file list, return original
    }

    // Send the full file list to LLM so it can analyze file names
    // Only truncate if list is extremely large (>500 files)
    const maxFiles = 500;
    if (fileCount > maxFiles) {
      try {
        final jsonData = jsonDecode(content.text!);
        List<dynamic>? fileList;

        if (jsonData is List) {
          fileList = jsonData;
        } else if (jsonData is Map && jsonData['results'] is List) {
          fileList = jsonData['results'] as List;
        }

        if (fileList != null) {
          final truncated = fileList.take(maxFiles).toList();
          final truncatedJson = jsonData is List
              ? truncated
              : {'results': truncated};
          final truncatedText =
              '${jsonEncode(truncatedJson)}\n\n[Note: Showing first $maxFiles of $fileCount files. ${fileCount - maxFiles} files truncated.]';

          talker.info(
            'ðŸ“„ Sending truncated file list to LLM: $maxFiles of $fileCount files',
          );
          return MCPContent(
            type: content.type,
            text: truncatedText,
            data: content.data,
            mimeType: content.mimeType,
          );
        }
      } catch (e) {
        talker.error('Failed to truncate file list: $e');
      }
    }

    // Send full file list to LLM
    talker.info(
      'ðŸ“„ Sending full file list to LLM: $fileCount files for analysis',
    );
    return content; // Return original content with full file list
  }

  /// Validate tool parameters against schema
  /// Returns error message if validation fails, null if valid
  /// Remaps parameter names that are Python reserved-word variants (trailing `_`)
  /// to the canonical names defined in the tool schema.
  ///
  /// Example: `from_` → `from`, `id_` → `id`
  /// Only remaps when the plain version exists in the schema and the
  /// trailing-underscore version does NOT.
  /// Remaps semantically-close but schema-invalid parameter names that small models
  /// tend to generate. Two heuristic rules, applied only when the key is absent from
  /// the schema and the target key is not already present:
  ///
  /// **Rule 1 – prefix match**: the wrong key starts with a valid schema key followed
  /// by `_` (e.g. `output_format` → `output`).
  ///
  /// **Rule 2 – suffix match**: the last underscore-separated word of the wrong key
  /// matches (case-insensitively) the suffix of *exactly one* valid schema key
  /// (e.g. `station_name` → `dluName` because "name" == suffix of "dluName").
  Map<String, dynamic> _remapPythonKeywordAliases(
    Map<String, dynamic> arguments,
    MCPTool tool,
  ) {
    final rawProps = tool.inputSchema?['properties'];
    final properties = rawProps == null
        ? null
        : (rawProps is Map<String, dynamic>
              ? rawProps
              : Map<String, dynamic>.from(rawProps as Map));
    if (properties == null) return arguments;

    final validNames = properties.keys.toSet();
    Map<String, dynamic>? patched;

    for (final key in arguments.keys.toList()) {
      if (key.endsWith('_')) {
        final plain = key.substring(0, key.length - 1);
        if (validNames.contains(plain) && !validNames.contains(key)) {
          patched ??= Map<String, dynamic>.from(arguments);
          patched[plain] = patched.remove(key);
          talker.info(
            '🔧 Remapped Python alias "$key" → "$plain" for tool "${tool.name}"',
          );
        }
      }
    }

    return patched ?? arguments;
  }

  Map<String, dynamic> _coerceToolArgumentsToSchema(
    String toolName,
    Map<String, dynamic> arguments,
    MCPTool tool,
  ) {
    final inputSchema = tool.inputSchema;
    final rawProps = inputSchema?['properties'];
    if (inputSchema == null || rawProps == null) {
      return arguments;
    }

    final properties = rawProps is Map<String, dynamic>
        ? rawProps
        : Map<String, dynamic>.from(rawProps as Map);
    Map<String, dynamic>? patched;

    for (final entry in arguments.entries) {
      final schema = properties[entry.key];
      if (schema is! Map) {
        continue;
      }

      final coerced = _coerceValueToSchema(
        entry.value,
        Map<String, dynamic>.from(schema),
      );
      if (coerced != entry.value) {
        patched ??= Map<String, dynamic>.from(arguments);
        patched[entry.key] = coerced;
      }
    }

    if (patched != null) {
      talker.info('🔧 Coerced tool arguments to schema for "$toolName"');
    }

    return patched ?? arguments;
  }

  dynamic _coerceValueToSchema(dynamic value, Map<String, dynamic> schema) {
    if (value == null) {
      return null;
    }

    final type = _primarySchemaType(schema);
    if (type == null) {
      return value;
    }

    switch (type) {
      case 'object':
        final objectValue = _coerceObjectValue(value, schema);
        return objectValue ?? value;
      case 'array':
        final arrayValue = _coerceArrayValue(value, schema);
        return arrayValue ?? value;
      case 'integer':
        return _coerceIntegerValue(value) ?? value;
      case 'number':
        return _coerceNumberValue(value) ?? value;
      case 'boolean':
        return _coerceBooleanValue(value) ?? value;
      case 'string':
        if (value is String) {
          return value;
        }
        return value.toString();
      default:
        return value;
    }
  }

  Map<String, dynamic>? _coerceObjectValue(
    dynamic value,
    Map<String, dynamic> schema,
  ) {
    Map<String, dynamic>? objectValue;

    if (value is Map<String, dynamic>) {
      objectValue = Map<String, dynamic>.from(value);
    } else if (value is Map) {
      objectValue = Map<String, dynamic>.from(value);
    } else if (value is String) {
      final trimmed = value.trim();
      if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
        try {
          final decoded = jsonDecode(trimmed);
          if (decoded is Map) {
            objectValue = Map<String, dynamic>.from(decoded);
          }
        } catch (_) {}
      }
    }

    if (objectValue == null) {
      return null;
    }

    final rawProps = schema['properties'];
    if (rawProps is! Map) {
      return objectValue;
    }

    final properties = rawProps is Map<String, dynamic>
        ? rawProps
        : Map<String, dynamic>.from(rawProps);
    for (final key in objectValue.keys.toList()) {
      final childSchema = properties[key];
      if (childSchema is Map) {
        objectValue[key] = _coerceValueToSchema(
          objectValue[key],
          Map<String, dynamic>.from(childSchema),
        );
      }
    }

    return objectValue;
  }

  List<dynamic>? _coerceArrayValue(dynamic value, Map<String, dynamic> schema) {
    List<dynamic>? arrayValue;

    if (value is List<dynamic>) {
      arrayValue = List<dynamic>.from(value);
    } else if (value is List) {
      arrayValue = List<dynamic>.from(value);
    } else if (value is String) {
      final trimmed = value.trim();
      if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
        try {
          final decoded = jsonDecode(trimmed);
          if (decoded is List) {
            arrayValue = List<dynamic>.from(decoded);
          }
        } catch (_) {}
      }

      arrayValue ??= _splitLooseArrayString(trimmed);
    }

    if (arrayValue == null) {
      return null;
    }

    final itemSchemaRaw = schema['items'];
    if (itemSchemaRaw is Map) {
      final itemSchema = Map<String, dynamic>.from(itemSchemaRaw);
      return arrayValue
          .map((item) => _coerceValueToSchema(item, itemSchema))
          .toList();
    }

    return arrayValue;
  }

  List<dynamic> _splitLooseArrayString(String input) {
    if (input.isEmpty) {
      return <dynamic>[];
    }

    final parts = input
        .split(RegExp(r'\s*(?:,|\||;|\n)\s*'))
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();

    if (parts.length <= 1) {
      return <dynamic>[input];
    }

    return parts;
  }

  int? _coerceIntegerValue(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt() == value ? value.toInt() : null;
    }
    if (value is String) {
      return int.tryParse(value.trim());
    }
    return null;
  }

  num? _coerceNumberValue(dynamic value) {
    if (value is num) {
      return value;
    }
    if (value is String) {
      return num.tryParse(value.trim());
    }
    return null;
  }

  bool? _coerceBooleanValue(dynamic value) {
    if (value is bool) {
      return value;
    }
    if (value is num) {
      if (value == 1) return true;
      if (value == 0) return false;
    }
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      switch (normalized) {
        case 'true':
        case 'yes':
        case '1':
        case 'on':
          return true;
        case 'false':
        case 'no':
        case '0':
        case 'off':
          return false;
      }
    }
    return null;
  }

  String? _primarySchemaType(Map<String, dynamic> schema) {
    final rawType = schema['type'];
    if (rawType is String && rawType.isNotEmpty) {
      return rawType;
    }
    if (rawType is List) {
      for (final entry in rawType) {
        if (entry is String && entry != 'null' && entry.isNotEmpty) {
          return entry;
        }
      }
    }
    if (schema['properties'] is Map) {
      return 'object';
    }
    if (schema['items'] is Map) {
      return 'array';
    }
    return null;
  }

  String _describeValueType(dynamic value) {
    if (value == null) return 'null';
    if (value is bool) return 'boolean';
    if (value is int) return 'integer';
    if (value is num) return 'number';
    if (value is String) return 'string';
    if (value is List) return 'array';
    if (value is Map) return 'object';
    return value.runtimeType.toString();
  }

  String _formatPrescriptiveError({
    required String what,
    required String why,
    required String how,
  }) {
    return '''
### Tool Call Validation Failure
- **What failed**: $what
- **Why it failed**: $why
- **How to fix it**: $how
''';
  }

  ValidationError? _validateValueAgainstSchema(
    String path,
    dynamic value,
    Map<String, dynamic> schema,
  ) {
    if (value == null) {
      return null;
    }

    final type = _primarySchemaType(schema);
    if (type != null) {
      switch (type) {
        case 'object':
          if (value is! Map) {
            return ValidationError(
              what: 'Type validation failed for parameter "$path"',
              why: 'Expected an object, but got ${_describeValueType(value)}',
              how:
                  'Please provide a valid JSON object map for "$path" and try again.',
            );
          }
          final rawProps = schema['properties'];
          if (rawProps is Map) {
            final properties = rawProps is Map<String, dynamic>
                ? rawProps
                : Map<String, dynamic>.from(rawProps);
            for (final entry in value.entries) {
              final childSchema = properties[entry.key];
              if (childSchema is Map) {
                final nestedError = _validateValueAgainstSchema(
                  '$path.${entry.key}',
                  entry.value,
                  Map<String, dynamic>.from(childSchema),
                );
                if (nestedError != null) {
                  return nestedError;
                }
              }
            }
          }
          break;
        case 'array':
          if (value is! List) {
            return ValidationError(
              what: 'Type validation failed for parameter "$path"',
              why: 'Expected an array, but got ${_describeValueType(value)}',
              how:
                  'Please wrap the items in a JSON array list for "$path" and try again.',
            );
          }
          final itemSchemaRaw = schema['items'];
          if (itemSchemaRaw is Map) {
            final itemSchema = Map<String, dynamic>.from(itemSchemaRaw);
            for (int index = 0; index < value.length; index++) {
              final nestedError = _validateValueAgainstSchema(
                '$path[$index]',
                value[index],
                itemSchema,
              );
              if (nestedError != null) {
                return nestedError;
              }
            }
          }
          break;
        case 'integer':
          if (value is! int) {
            return ValidationError(
              what: 'Type validation failed for parameter "$path"',
              why:
                  'Expected an integer, but got ${_describeValueType(value)} (value: "$value")',
              how:
                  'Convert the value of "$path" to a whole number integer (e.g. 42) and try again.',
            );
          }
          break;
        case 'number':
          if (value is! num) {
            return ValidationError(
              what: 'Type validation failed for parameter "$path"',
              why:
                  'Expected a number/float, but got ${_describeValueType(value)} (value: "$value")',
              how:
                  'Provide a valid numeric value for "$path" (e.g. 3.14) and try again.',
            );
          }
          break;
        case 'boolean':
          if (value is! bool) {
            return ValidationError(
              what: 'Type validation failed for parameter "$path"',
              why:
                  'Expected a boolean, but got ${_describeValueType(value)} (value: "$value")',
              how:
                  'Provide either true or false (without quotes) for "$path" and try again.',
            );
          }
          break;
        case 'string':
          if (value is! String) {
            return ValidationError(
              what: 'Type validation failed for parameter "$path"',
              why:
                  'Expected a string, but got ${_describeValueType(value)} (value: "$value")',
              how:
                  'Provide a valid text string (e.g. "example") for "$path" and try again.',
            );
          }
          break;
      }
    }

    final enumValues = schema['enum'];
    if (enumValues is List &&
        enumValues.isNotEmpty &&
        !enumValues.contains(value)) {
      return ValidationError(
        what: 'Constraint validation failed for parameter "$path"',
        why:
            'Received value "$value" which is not in the allowed list of options.',
        how:
            'Choose one of the following valid options for "$path": ${enumValues.join(", ")}',
      );
    }

    return null;
  }

  String? _validateToolParameters(
    String toolName,
    Map<String, dynamic> arguments,
    MCPTool tool,
  ) {
    try {
      final inputSchema = tool.inputSchema;
      if (inputSchema == null || inputSchema['properties'] == null) {
        // No schema to validate against
        return null;
      }

      final rawProps = inputSchema['properties'] as Map;
      final properties = rawProps is Map<String, dynamic>
          ? rawProps
          : Map<String, dynamic>.from(rawProps);
      final requiredParams =
          (inputSchema['required'] as List<dynamic>?)?.cast<String>() ?? [];
      final validParamNames = properties.keys.toSet();

      // Check for wrong parameter names (case-sensitive)
      final providedParams = arguments.keys.toSet();
      final wrongParams = providedParams.difference(validParamNames);

      final autoRecovery =
          LlmSettingsService.instance.enableToolParameterAutoRecovery;
      final severity = autoRecovery ? '[RECOVERABLE]' : '[UNRECOVERABLE]';

      if (wrongParams.isNotEmpty) {
        return '$severity\n${_formatPrescriptiveError(what: 'Invalid parameter names used for tool "$toolName"', why: 'The parameter(s) ${wrongParams.map((p) => '"$p"').join(", ")} do not exist in the tool\'s schema.', how: 'Remove these invalid parameters and only use parameters defined in the schema: ${validParamNames.map((p) => '"$p"').join(", ")}.')}';
      }

      // Check for missing required parameters.
      final missingRequired = requiredParams
          .where((param) => !providedParams.contains(param))
          .toList();
      if (missingRequired.isNotEmpty) {
        return '$severity\n${_formatPrescriptiveError(what: 'Missing required parameters for tool "$toolName"', why: 'The following required parameter(s) were not supplied: ${missingRequired.map((p) => '"$p"').join(", ")}.', how: 'Add the missing required parameters with valid values to your request and try again.')}';
      }

      for (final entry in arguments.entries) {
        final schema = properties[entry.key];
        if (schema is! Map) {
          continue;
        }

        final error = _validateValueAgainstSchema(
          entry.key,
          entry.value,
          Map<String, dynamic>.from(schema),
        );
        if (error != null) {
          return '$severity\n${_formatPrescriptiveError(what: error.what, why: error.why, how: error.how)}';
        }
      }

      // Validation passed
      return null;
    } catch (e) {
      talker.warning('Error validating parameters for $toolName: $e');
      // Don't block tool execution on validation errors
      return null;
    }
  }

  /// Parse text-formatted tool calls from LLM response content.
  ///
  /// Handles two primary formats (tried in order):
  ///  1. Python call syntax      : `tool_call: name("arg1", 1, kwarg=val)`
  ///  2. Training-target JSON    : `tool_call: {"name":"...","arguments":{...}}`
  ///  3. Legacy format           : `Called tool: name\nArguments: {json}`
  List<LLMToolCall> _parseTextToolCalls(String content) {
    // Strip <think>...</think> blocks so inner model-debug text doesn't interfere.
    final cleaned = content
        .replaceAll(
          RegExp(r'<think>.*?</think>', dotAll: true, caseSensitive: false),
          '',
        )
        .trim();

    // ── Format 0: XML-style tool calls: <tool_call>...</tool_call> ──────────
    final xmlToolCallPattern = RegExp(
      r'<tool_call>\s*(.*?)\s*</tool_call>',
      dotAll: true,
      caseSensitive: false,
    );
    final xmlMatches = xmlToolCallPattern.allMatches(cleaned);
    for (final match in xmlMatches) {
      try {
        final jsonStr = match.group(1)?.trim() ?? '';
        if (jsonStr.isNotEmpty) {
          final decoded = jsonDecode(jsonStr);
          if (decoded is Map<String, dynamic>) {
            final inner = decoded['tool_call'] is Map<String, dynamic>
                ? decoded['tool_call'] as Map<String, dynamic>
                : decoded;
            final toolName = inner['name'] as String?;
            final arguments =
                (inner['arguments'] ?? inner['parameters'])
                    as Map<String, dynamic>?;
            if (toolName != null && toolName.isNotEmpty && arguments != null) {
              talker.info(
                '[parseToolCall] XML-style tool call: $toolName (${arguments.length} args)',
              );
              return [LLMToolCall(name: toolName, arguments: arguments)];
            }
          }
        }
      } catch (e) {
        talker.warning(
          '[parseToolCall] Failed to parse XML-style tool call JSON: $e',
        );
      }
    }

    // ── Format 0.5: Direct Raw JSON tool calls: {"name": ..., "arguments": ...} ──
    int directJsonIndex = 0;
    while ((directJsonIndex = cleaned.indexOf('{', directJsonIndex)) != -1) {
      try {
        final jsonStr = _extractBalancedJson(
          cleaned.substring(directJsonIndex),
        );
        if (jsonStr.isNotEmpty) {
          final decoded = jsonDecode(jsonStr);
          if (decoded is Map<String, dynamic>) {
            final inner = decoded['tool_call'] is Map<String, dynamic>
                ? decoded['tool_call'] as Map<String, dynamic>
                : decoded;
            final toolName = inner['name'] as String?;
            final arguments =
                (inner['arguments'] ?? inner['parameters'])
                    as Map<String, dynamic>?;
            if (toolName != null && toolName.isNotEmpty && arguments != null) {
              talker.info(
                '[parseToolCall] Direct JSON tool call: $toolName (${arguments.length} args)',
              );
              return [LLMToolCall(name: toolName, arguments: arguments)];
            }
          }
        }
      } catch (_) {
        // Ignore and check next brace
      }
      directJsonIndex++;
    }

    // ── Format 1: Python call syntax: tool[_ ]call: name(args)  ─────────────
    // e.g. tool_call: get_devices_by_name("Lengden", 1, -1, fields="name,id")
    final pyCallRe = RegExp(
      r'tool[_ ]?call\s*:?\s*([\w]+)\s*\(',
      caseSensitive: false,
    );
    for (final m in pyCallRe.allMatches(cleaned)) {
      final toolName = m.group(1)!;
      // Find matching ')' respecting quotes and nested parens.
      final argsStr = _extractBalancedParens(cleaned, m.end - 1);
      if (argsStr != null) {
        try {
          final arguments = _parsePyCallArgs(toolName, argsStr);
          talker.info(
            '[parseToolCall] Python-call format: $toolName (${arguments.length} args)',
          );
          return [LLMToolCall(name: toolName, arguments: arguments)];
        } catch (e) {
          talker.warning(
            '[parseToolCall] Failed to parse Python-call args: $e',
          );
        }
      }
    }

    // ── Format 2: tool_call: {json}  (training-target, underscore) ──────────
    // Also accepts "tool call:" (space) followed by a JSON object.
    final jsonCallPattern = RegExp(
      r'tool[_ ]call\s*:\s*(\{.*\})',
      caseSensitive: false,
      dotAll: true,
    );
    for (final match in jsonCallPattern.allMatches(cleaned)) {
      try {
        final payload = jsonDecode(match.group(1)!) as Map<String, dynamic>;
        final toolName = payload['name'] as String?;
        if (toolName != null && toolName.isNotEmpty) {
          final arguments =
              (payload['arguments'] as Map<String, dynamic>?) ?? {};
          talker.info(
            '[parseToolCall] Training-format tool call: $toolName (${arguments.length} args)',
          );
          return [LLMToolCall(name: toolName, arguments: arguments)];
        }
      } catch (e) {
        talker.warning('[parseToolCall] Failed to parse tool_call JSON: $e');
      }
    }

    // ── Format 3: Called tool: name\nArguments: {json}  (legacy) ──────
    final legacyPattern = RegExp(
      r'Called tool:\s*([\w]+)\s*\nArguments:\s*(\{.*?\})',
      caseSensitive: false,
      dotAll: true,
    );
    for (final match in legacyPattern.allMatches(cleaned)) {
      try {
        final toolName = match.group(1)!.trim();
        final arguments = jsonDecode(match.group(2)!) as Map<String, dynamic>;
        talker.info('[parseToolCall] Legacy tool call: $toolName');
        return [LLMToolCall(name: toolName, arguments: arguments)];
      } catch (e) {
        // Ignore, try next pattern
      }
    }

    // No tool calls found
    return [];
  }

  /// Find the content inside the balanced parentheses that start at [openPos].
  /// Returns the string between `(` and its matching `)`, or null on failure.
  String? _extractBalancedParens(String s, int openPos) {
    if (openPos >= s.length || s[openPos] != '(') return null;
    int depth = 0;
    bool inDouble = false, inSingle = false;
    for (int i = openPos; i < s.length; i++) {
      final c = s[i];
      if (c == r'\' && (inDouble || inSingle)) {
        i++;
        continue;
      }
      if (c == '"' && !inSingle) {
        inDouble = !inDouble;
        continue;
      }
      if (c == "'" && !inDouble) {
        inSingle = !inSingle;
        continue;
      }
      if (!inDouble && !inSingle) {
        if (c == '(') {
          depth++;
        } else if (c == ')') {
          depth--;
          if (depth == 0) return s.substring(openPos + 1, i);
        }
      }
    }
    return null;
  }

  /// Extract balanced JSON from a string starting with '{'
  /// Handles nested braces, arrays, and strings properly
  String _extractBalancedJson(String text) {
    if (text.isEmpty || !text.startsWith('{')) return '';

    int braceCount = 0;
    bool inString = false;
    bool escaped = false;

    for (int i = 0; i < text.length; i++) {
      final char = text[i];

      if (escaped) {
        escaped = false;
        continue;
      }

      if (char == '\\') {
        escaped = true;
        continue;
      }

      if (char == '"') {
        inString = !inString;
        continue;
      }

      if (!inString) {
        if (char == '{') {
          braceCount++;
        } else if (char == '}') {
          braceCount--;
          if (braceCount == 0) {
            return text.substring(0, i + 1);
          }
        }
      }
    }

    return ''; // No balanced JSON found
  }

  /// Parse Python-style call arguments `"arg1", 1, -1, key=val` into a map.
  /// Positional args are mapped to parameter names from the tool schema when
  /// available, falling back to `arg0`, `arg1`, … otherwise.
  Map<String, dynamic> _parsePyCallArgs(String toolName, String argsStr) {
    final tokens = _splitCallArgs(argsStr);

    // Look up ordered parameter names from the tool schema.
    final paramNames = <String>[];
    final tool = mcpClient.availableTools
        .where((t) => t.name == toolName)
        .firstOrNull;
    if (tool?.inputSchema != null) {
      final props = tool!.inputSchema!['properties'] as Map<String, dynamic>?;
      if (props != null) paramNames.addAll(props.keys);
    }

    final result = <String, dynamic>{};
    int positionalIdx = 0;
    for (final token in tokens) {
      if (token.isEmpty) continue;
      // Keyword arg: word = value
      final kwMatch = RegExp(
        r'^(\w+)\s*=\s*(.+)$',
        dotAll: true,
      ).firstMatch(token);
      if (kwMatch != null) {
        result[kwMatch.group(1)!] = _parseArgValue(kwMatch.group(2)!.trim());
      } else {
        // Positional arg
        final name = positionalIdx < paramNames.length
            ? paramNames[positionalIdx]
            : 'arg$positionalIdx';
        result[name] = _parseArgValue(token);
        positionalIdx++;
      }
    }
    return result;
  }

  /// Split a comma-separated argument string, respecting quotes and brackets.
  List<String> _splitCallArgs(String argsStr) {
    final tokens = <String>[];
    final cur = StringBuffer();
    int depth = 0;
    bool inDouble = false, inSingle = false;
    for (int i = 0; i < argsStr.length; i++) {
      final c = argsStr[i];
      if (c == r'\' && (inDouble || inSingle)) {
        cur.write(c);
        i++;
        if (i < argsStr.length) cur.write(argsStr[i]);
        continue;
      }
      if (c == '"' && !inSingle) {
        inDouble = !inDouble;
        cur.write(c);
        continue;
      }
      if (c == "'" && !inDouble) {
        inSingle = !inSingle;
        cur.write(c);
        continue;
      }
      if (!inDouble && !inSingle) {
        if (c == '(' || c == '[' || c == '{') {
          depth++;
        } else if (c == ')' || c == ']' || c == '}') {
          depth--;
        } else if (c == ',' && depth == 0) {
          tokens.add(cur.toString().trim());
          cur.clear();
          continue;
        }
      }
      cur.write(c);
    }
    final last = cur.toString().trim();
    if (last.isNotEmpty) tokens.add(last);
    return tokens;
  }

  /// Convert a raw token from key=value argument parsing to a Dart value.
  dynamic _parseArgValue(String raw) {
    if (raw.isEmpty) return '';
    // Quoted string
    if ((raw.startsWith('"') && raw.endsWith('"')) ||
        (raw.startsWith("'") && raw.endsWith("'"))) {
      return raw
          .substring(1, raw.length - 1)
          .replaceAll(r'\"', '"')
          .replaceAll(r"\'", "'")
          .replaceAll(r'\t', '\t')
          .replaceAll(r'\n', '\n');
    }
    // Python/JSON booleans and null
    if (raw == 'True' || raw == 'true') return true;
    if (raw == 'False' || raw == 'false') return false;
    if (raw == 'None' || raw == 'null') return null;
    // Numbers
    final asInt = int.tryParse(raw);
    if (asInt != null) return asInt;
    final asDouble = double.tryParse(raw);
    if (asDouble != null) return asDouble;
    // Array (best-effort JSON; replace single quotes for Python lists)
    if (raw.startsWith('[') && raw.endsWith(']')) {
      try {
        return jsonDecode(raw.replaceAll("'", '"'));
      } catch (_) {}
    }
    return raw;
  }

  /// Add message to chat and notify listeners
  void _addMessage(ChatMessage message) {
    talker.info(
      'Adding message: ${message.role.name} - ${message.content.length} chars - ID: ${message.id}',
    );

    // Debug: Log attachments when message is added
    if (message.attachments != null && message.attachments!.isNotEmpty) {
      talker.info(
        'ðŸ“Ž Message has ${message.attachments!.length} attachment(s):',
      );
      for (final att in message.attachments!) {
        talker.info('   - ${att.name} (${att.mimeType})');
        talker.info(
          '     Bytes: ${att.bytes != null ? "${att.bytes!.length} bytes" : "NULL"}',
        );
      }
    }

    // If a streaming placeholder exists and this is an assistant/system message, replace it
    // in-place so the streamed preview transitions smoothly to the final committed content.
    if (_streamingPlaceholderId != null &&
        (message.role == ChatRole.assistant ||
            message.role == ChatRole.system)) {
      final idx = _messages.indexWhere((m) => m.id == _streamingPlaceholderId);
      if (idx != -1) {
        _messages[idx] = message;
        _streamingPlaceholderId = null;
        talker.info('Replaced streaming placeholder with committed message');
        _messagesController.add(List.unmodifiable(_messages));
        _messageController.add(message);
        notifyListeners();
        return;
      }
      _streamingPlaceholderId = null;
    }

    _messages.add(message);
    talker.info('Total messages now: ${_messages.length}');
    _messagesController.add(List.unmodifiable(_messages));
    _messageController.add(message);
    notifyListeners();
  }

  /// Clear chat history
  Future<void> clearChat() async {
    _messages.clear();
    await _initializeChat();
    _messagesController.add(List.unmodifiable(_messages));
    notifyListeners();
  }

  /// Soft reset - resets LLM context but keeps messages visible on screen
  /// Used by the "reset" token feature to start fresh context after a response
  Future<void> softResetConversation() async {
    talker.info(
      'ðŸ”„ Soft-resetting conversation - keeping messages on screen',
    );

    // Stop any ongoing processing
    if (isProcessing) {
      stopProcessing();
    }

    // Clear processing state
    _processingType = ProcessingType.none;

    // Reset priming state BEFORE clearing so _initializeChat can re-prime
    _isConversationPrimed = false;

    // Clear all messages (LLM context) but do NOT update the UI stream
    // This means the screen keeps showing old messages, but next LLM call starts fresh
    _messages.clear();

    // Reinitialize with fresh system prompt
    await _initializeChat();

    // Reset counters
    _toolIterationCount = 0;
    _cumulativeTokens = 0;
    _cumulativePromptTokens = 0;
    _cumulativeCompletionTokens = 0;
    _lastRequestPromptTokens = 0;
    _lastRequestCompletionTokens = 0;
    _lastRequestTotalTokens = 0;
    _lastRequestUsageEstimated = false;
    _estimatedUsageRequests = 0;
    _lastRequestCostUsd = 0;
    _sessionCostUsd = 0;
    _totalSentChars = 0;

    talker.info(
      'ðŸ”„ Soft reset complete - context cleared, messages kept on screen',
    );
    // Intentionally NOT calling _messagesController.add() to keep UI unchanged
  }

  /// Reset conversation - clears all messages and reinitializes
  Future<void> resetConversation() async {
    talker.info('ðŸ”„ Resetting conversation - clearing all messages');

    // Stop any ongoing processing
    if (isProcessing) {
      stopProcessing();
    }

    // Clear processing state
    _processingType = ProcessingType.none;

    // Clear ALL messages to avoid conversation structure issues
    _messages.clear();

    // Reinitialize chat with fresh system prompt
    await _initializeChat();
    if (_isDisposed) return;

    // Update UI
    _messagesController.add(List.unmodifiable(_messages));

    // Reset counters
    _toolIterationCount = 0;
    _cumulativeTokens = 0;
    _cumulativePromptTokens = 0;
    _cumulativeCompletionTokens = 0;
    _lastRequestPromptTokens = 0;
    _lastRequestCompletionTokens = 0;
    _lastRequestTotalTokens = 0;
    _lastRequestUsageEstimated = false;
    _estimatedUsageRequests = 0;
    _lastRequestCostUsd = 0;
    _sessionCostUsd = 0;
    _totalSentChars = 0;

    // Reset priming state so system prompt is sent with next message
    _isConversationPrimed = false;

    talker.info(
      'ðŸ”„ Conversation reset complete - all messages cleared and reinitialized, duplicate tracking cleared',
    );
    notifyListeners();
  }

  /// Restores a list of previously exported [ChatMessage]s into the conversation.
  /// The system message produced by [_initializeChat] is kept; exported messages
  /// are appended after it, then the UI stream is updated.
  void restoreMessages(List<ChatMessage> exportedMessages) {
    if (exportedMessages.isEmpty) return;

    // Keep any existing system messages that were set up by _initializeChat
    final systemMsgs = _messages
        .where((m) => m.role == ChatRole.system)
        .toList();
    _messages.clear();
    _messages.addAll(systemMsgs);

    for (final msg in exportedMessages) {
      if (msg.role != ChatRole.system) {
        _messages.add(msg);
      }
    }

    _messagesController.add(List.unmodifiable(_messages));
    notifyListeners();
  }

  /// Get current conversation ID
  String get conversationId => _conversationId;

  /// Check if a provider supports native tool/function calling API
  /// (vs including tools in system prompt)
  bool _providerSupportsNativeTools(LLMProvider provider) {
    switch (provider) {
      case LLMProvider.gemini:
        return true; // Gemini supports function calling API
      case LLMProvider.openai:
        return true; // OpenAI supports function calling API
      case LLMProvider.claude:
        return true; // Claude supports tool use API
      case LLMProvider.ollama:
        return llmService
            .useNativeToolCall; // Ollama supports tool calling if enabled
      case LLMProvider.openaiCompatible:
        return true; // OpenAI-compatible providers (DeepInfra, etc.) support function calling
      case LLMProvider.embedded:
        return true; // Embedded (on-device) supports native tool calling via llamadart
      case LLMProvider.none:
        return false;
    }
  }

  /// Export chat history
  List<Map<String, dynamic>> exportChat() {
    return _messages.map((m) => m.toJson()).toList();
  }

  /// Import chat history
  void importChat(List<Map<String, dynamic>> chatData) {
    _messages.clear();

    for (final messageData in chatData) {
      try {
        final message = ChatMessage.fromJson(messageData);
        _messages.add(message);
      } catch (e) {
        talker.error('Error importing message: $e');
      }
    }

    _messagesController.add(List.unmodifiable(_messages));
  }

  /// Get chat statistics
  Map<String, dynamic> getChatStats() {
    final userMessages = _messages.where((m) => m.role == ChatRole.user).length;
    final assistantMessages = _messages
        .where((m) => m.role == ChatRole.assistant)
        .length;
    final toolCalls = _messages.where((m) => m.role == ChatRole.tool).length;

    talker.debug(
      'ðŸ“Š getChatStats() called - _cumulativeTokens = $_cumulativeTokens',
    );

    return {
      'totalMessages': _messages.length,
      'userMessages': userMessages,
      'assistantMessages': assistantMessages,
      'toolCalls': toolCalls,
      'cumulativeTokens': _cumulativeTokens,
      'cumulativePromptTokens': _cumulativePromptTokens,
      'cumulativeCompletionTokens': _cumulativeCompletionTokens,
      'lastRequestPromptTokens': _lastRequestPromptTokens,
      'lastRequestCompletionTokens': _lastRequestCompletionTokens,
      'lastRequestTokens': _lastRequestTotalTokens,
      'lastRequestUsageEstimated': _lastRequestUsageEstimated,
      'estimatedUsageRequests': _estimatedUsageRequests,
      'lastRequestCostUsd': _lastRequestCostUsd,
      'sessionCostUsd': _sessionCostUsd,
      'providerKey': _providerKeyForPricing(),
      'model': llmService.currentModel,
      'totalSentChars': _totalSentChars,
      'availableTools': mcpClient.availableTools.length,
      'mcpConnected': mcpClient.isConnected,
      'llmConfigured': llmService.isConfigured,
    };
  }

  /// Regenerate last response
  Future<void> regenerateLastResponse() async {
    if (isProcessing) {
      throw Exception('Already processing a message');
    }

    // Remove last assistant message if it exists
    if (_messages.isNotEmpty && _messages.last.role == ChatRole.assistant) {
      _messages.removeLast();
    }

    // Regenerate response
    await _processLLMResponse();
  }

  /// Generate chart from measurement data
  Future<void> generateChart({
    required String deviceId,
    required String configId,
    String chartType = 'line',
    String title = 'Measurement Data Chart',
  }) async {
    try {
      // Get measurement data using MCP tools
      final measurementTool = mcpClient.availableTools.firstWhere(
        (tool) => tool.name == 'get_table_measurement_data',
        orElse: () => throw Exception('Measurement tool not available'),
      );

      final result = await mcpClient.callTool(measurementTool.name, {
        'agdId': int.parse(deviceId),
        'cfgId': int.parse(configId),
        'hour': 24, // Last 24 hours
        'isDesc': true,
        'limit': 100,
      });

      // Parse measurement data and create chart
      if (result.content.isNotEmpty && result.content.first.text != null) {
        final measurementText = result.content.first.text!;

        // Create chart HTML
        final chartHtml = await llmService.generateChartHtml(
          data: _parseMeasurementDataForChart(measurementText),
          chartType: chartType,
          title: title,
        );

        // Save chart HTML to temporary file
        final tempDir = await getTemporaryDirectory();
        final chartFile = File(
          '${tempDir.path}/chart_${DateTime.now().millisecondsSinceEpoch}.html',
        );
        await chartFile.writeAsString(chartHtml);
        final chartFilePath = chartFile.path;

        // Add chart message to chat
        final chartMessage = ChatMessage(
          id: _uuid.v4(),
          content: 'Here\'s your chart:',
          role: ChatRole.assistant,
          timestamp: DateTime.now(),
          attachments: [
            MessageAttachment(
              id: _uuid.v4(),
              type: AttachmentType.html,
              name: 'chart.html',
              path: chartFilePath,
              mimeType: 'text/html',
            ),
          ],
        );

        _addMessage(chartMessage);
      }
    } catch (e) {
      talker.error('Chart generation failed: $e');
      final errorMessage = ChatMessage(
        id: _uuid.v4(),
        content: 'Failed to generate chart: $e',
        role: ChatRole.assistant,
        timestamp: DateTime.now(),
      );
      _addMessage(errorMessage);
    }
  }

  /// Parse measurement data for chart generation
  Map<String, dynamic> _parseMeasurementDataForChart(String measurementData) {
    // Simple parsing - in reality, you'd want more sophisticated parsing
    final lines = measurementData.split('\n');
    final labels = <String>[];
    final values = <double>[];

    for (final line in lines.skip(1)) {
      // Skip header
      final parts = line.split(',');
      if (parts.length >= 2) {
        labels.add(parts[0]); // Timestamp
        values.add(double.tryParse(parts[1]) ?? 0.0); // Value
      }
    }

    return {
      'labels': labels,
      'datasets': [
        {
          'label': 'Measurement Values',
          'data': values,
          'borderColor': 'rgb(75, 192, 192)',
          'backgroundColor': 'rgba(75, 192, 192, 0.2)',
          'tension': 0.1,
        },
      ],
    };
  }

  /// Execute file download using chunked download service
  Future<MCPToolResult> _executeChunkedDownload(
    Map<String, dynamic> arguments,
  ) async {
    talker.info(
      'ðŸš€ _executeChunkedDownload called with arguments: $arguments',
    );

    try {
      // SSH tool uses 'path', file download tools may use 'file_path' — accept both
      final filePath = (arguments['path'] ?? arguments['file_path']) as String;
      final fileName = filePath.split('/').last;
      final asBase64 = arguments['as_base64'] as bool? ?? true;

      talker.info(
        'Starting chunked download for: $filePath (asBase64: $asBase64)',
      );

      // Create download message with stream
      final downloadMessageId = _uuid.v4();

      // Create initial download message BEFORE starting download
      final downloadMessage = ChatMessage(
        id: downloadMessageId,
        content:
            'download_progress:$fileName', // Special marker for download widget
        role: ChatRole.assistant,
        timestamp: DateTime.now(),
        type: MessageType.download,
      );
      _addMessage(downloadMessage);

      talker.info('ðŸ”½ Starting download for: $filePath, fileName: $fileName');

      // Execute download WITHOUT storing stream - let service handle everything
      DownloadProgress? finalProgress;

      try {
        // Download directly without exposing stream to widget
        await for (final progress in _fileDownloadService!.downloadFile(
          filePath: filePath,
          saveAsFileName: fileName,
          asBase64: asBase64,
        )) {
          talker.debug(
            'Progress: ${progress.progressPercent.toStringAsFixed(1)}%',
          );

          // Store latest progress for widget to display
          _completedDownloads[downloadMessageId] = progress;
          notifyListeners(); // Notify widget to update

          // Always store the latest progress - the last one will have savedPath
          // Don't break - let stream complete naturally to save the file!
          finalProgress = progress;
        }
      } catch (e) {
        talker.error('Download stream error: $e');
        _completedDownloads.remove(downloadMessageId);
        notifyListeners();
        rethrow;
      }

      if (finalProgress == null) {
        throw Exception('Download failed - no final progress received');
      }

      talker.info(
        'Download complete! Size: ${finalProgress.totalBytes} bytes, savedPath: ${finalProgress.savedPath}',
      );

      // Return result with metadata (not base64 data, to keep LLM context small)
      return MCPToolResult(
        content: [
          MCPContent(
            type: 'text',
            text: jsonEncode({
              'file_name': fileName,
              'file_size': finalProgress.totalBytes,
              'mime_type': finalProgress.mimeType ?? 'application/octet-stream',
              'saved_path': finalProgress.savedPath ?? '',
              'status': 'completed',
            }),
          ),
        ],
      );
    } catch (e, stackTrace) {
      talker.error('Chunked download failed: $e');
      talker.error('Stack trace: $stackTrace');

      return MCPToolResult(
        content: [MCPContent(type: 'text', text: 'Download failed: $e')],
        isError: true,
      );
    }
  }

  // ───────────────────────────────────────────────────────────────────────
  // SFTP download helper
  // ───────────────────────────────────────────────────────────────────────

  /// Handles an SFTP `download_file` result from the agentic loop:
  /// saves the file to the device Downloads folder, adds a visible chat
  /// message, and returns a binary-free summary so the LLM stops looping.
  Future<MCPToolResult> _handleSftpDownloadResult(
    MCPToolResult rawResult,
    String remotePath,
  ) async {
    if (rawResult.isError) return rawResult;

    try {
      // The InternalMcpClientAdapter puts base64 in MCPContent.data (type:'file')
      // when the SSH server responds with {encoding:'base64', content:..., mimeType:...}.
      // Fall back to JSON text path for other server implementations.
      String? b64;
      String? fileName;

      final fileContent = rawResult.content.firstWhere(
        (c) => c.type == 'file' && c.data != null && c.data!.isNotEmpty,
        orElse: () => MCPContent(type: 'text', text: null),
      );

      if (fileContent.data != null) {
        // Adapter path: base64 is directly in .data
        b64 = fileContent.data;
        fileName = remotePath.split('/').last;
      } else {
        // JSON text fallback
        final text = rawResult.content.firstOrNull?.text ?? '';
        if (text.isEmpty) {
          return MCPToolResult(
            content: [
              MCPContent(
                type: 'text',
                text: '{"error":"download_file: empty response"}',
              ),
            ],
            isError: true,
          );
        }
        final json = jsonDecode(text) as Map<String, dynamic>;
        if (json['error'] != null) {
          return MCPToolResult(
            content: [MCPContent(type: 'text', text: json['error'].toString())],
            isError: true,
          );
        }
        b64 = json['content'] as String?;
        fileName = (json['fileName'] as String?) ?? remotePath.split('/').last;
      }

      if (b64 == null || b64.isEmpty) {
        return MCPToolResult(
          content: [
            MCPContent(
              type: 'text',
              text: 'download_file: no content in response',
            ),
          ],
          isError: true,
        );
      }
      final bytes = base64Decode(b64);

      // Save to device — dialog on desktop, direct-to-Downloads on mobile
      // (FilePicker.saveFile returns null on Android even on success, so we skip
      // the dialog there and save directly to the standard Downloads folder.)
      String? savedPath;
      try {
        final isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
        if (isMobile) {
          // Mobile: always save to Downloads — no dialog needed
          late Directory dir;
          if (Platform.isAndroid) {
            dir = Directory('/storage/emulated/0/Download');
            if (!await dir.exists()) {
              dir =
                  (await getExternalStorageDirectory()) ??
                  await getApplicationDocumentsDirectory();
            }
          } else {
            dir = await getApplicationDocumentsDirectory();
          }
          final outFile = File('${dir.path}/$fileName');
          await outFile.writeAsBytes(bytes, flush: true);
          savedPath = outFile.path;
          talker.info(
            'SFTP download saved (mobile): $savedPath (${bytes.length} bytes)',
          );
        } else {
          // Desktop: ask the user where to save
          final pickedPath = await FilePicker.saveFile(
            dialogTitle: 'Save downloaded file',
            fileName: fileName,
          );
          if (pickedPath != null) {
            await File(pickedPath).writeAsBytes(bytes, flush: true);
            savedPath = pickedPath;
            talker.info(
              'SFTP download saved (desktop): $savedPath (${bytes.length} bytes)',
            );
          } else {
            talker.info(
              'SFTP download: user cancelled save dialog for $fileName',
            );
          }
        }
      } catch (e) {
        talker.error('SFTP download save failed: $e');
      }

      // Build human-readable summary for display (shown as tool result in chat)
      final displayMsg = savedPath != null
          ? 'Downloaded $fileName (${_formatBytes(bytes.length)}) - saved to $savedPath'
          : 'Downloaded $fileName (${_formatBytes(bytes.length)}) - not saved (cancelled or error)';

      // NOTE: Do NOT call _addMessage() here — injecting an assistant-role message
      // between the tool result and the next LLM call breaks Mistral/OpenAI message
      // ordering (error 3230: "Expected last role User or Tool, got assistant").
      // The display text is returned inside the MCPToolResult so it shows in chat
      // as a tool message and is correctly positioned in the LLM history.

      // Return clean JSON summary for LLM — no binary content
      return MCPToolResult(
        content: [
          MCPContent(
            type: 'text',
            text:
                '$displayMsg\n\n${jsonEncode({'success': savedPath != null, 'fileName': fileName, 'bytes': bytes.length, 'savedTo': savedPath, 'message': savedPath != null ? 'File downloaded and saved to $savedPath. No further action needed.' : 'File was downloaded but the user cancelled the save dialog.'})}',
          ),
        ],
        isError: false,
      );
    } catch (e) {
      talker.error('SFTP download handling error: $e');
      // Fall back to original result but strip the binary to prevent LLM loop
      return MCPToolResult(
        content: [
          MCPContent(
            type: 'text',
            text: '{"error": "Download processing failed: $e"}',
          ),
        ],
        isError: true,
      );
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)}GB';
  }

  /// Dispose of the service
  @override
  void dispose() {
    _isDisposed = true;
    mcpClient.removeListener(_onMcpToolsChanged);
    llmService.removeListener(_onLlmProviderChanged);
    _mcpInitTimer?.cancel();
    _semanticInitTimer?.cancel();
    _llmProviderChangeTimer?.cancel();
    _cleanupSuggestionController.close();
    _messagesController.close();
    _messageController.close();
    _errorNotificationController.close();
    super.dispose();
  }
}

class ValidationError {
  final String what;
  final String why;
  final String how;
  ValidationError({required this.what, required this.why, required this.how});
}
