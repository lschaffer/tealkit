import 'package:uuid/uuid.dart';

typedef ParamsEncryptor = Map<String, dynamic> Function(Map<String, dynamic> params);
typedef ParamsDecryptor = Map<String, dynamic> Function(Map<String, dynamic> params);


// ═══════════════════════════════════════════════════════════════
// MAIN MODEL: WorkflowTask
// ═══════════════════════════════════════════════════════════════

/// A scheduled AI agent task that connects to LLMs, tools, and services.
///
/// Document structure (stored as JSON in DuckDB):
/// ```
/// WorkflowTask
/// ├── id, name, description, agentId
/// ├── systemPrompt      (task-specific LLM instructions)
/// ├── prompt            (the actual task to execute)
/// ├── enabled
/// ├── executionPlan     (cron schedule, timezone, retry)
/// ├── llmConfig?        (override agent's default LLM, or null = inherit)
/// ├── mcpTools[]        (external MCP servers this task can use)
/// ├── internalMcps[]    (built-in MCP configs: weather, gmail, doc-search…)
/// ├── providers         (email, web search connections)
/// ├── execution         (runtime state: last/next run, results, errors)
/// ├── notification      (where to deliver results)
/// ├── chainConfig?      (task chaining: subtask flag, condition, follow-up task IDs)
/// └── createdAt, updatedAt
/// ```
class WorkflowTask {
  final String id;
  final String name;
  final String? description;
  final String? agentId; // null = standalone task

  // ── LLM Configuration ──
  /// Task-specific system prompt (injected before the task prompt).
  /// Example: "You are a price monitoring assistant. Always report in EUR."
  final String? systemPrompt;

  /// The actual task prompt to send to the LLM.
  /// Example: "Check my inbox for emails from the last 6 hours and summarize."
  final String prompt;

  /// Override the agent's LLM config for this task. Null = use agent's default.
  final TaskLlmConfig? llmConfig;

  final bool enabled;

  // ── Schedule ──
  final ExecutionPlan executionPlan;

  // ── Tools & Connections ──
  final List<McpToolConfig> mcpTools;

  /// Internal (built-in) MCP server configurations for this task.
  /// Each entry specifies an MCP type (e.g. 'weather', 'gmail') and init parameters.
  final List<InternalMcpEntry> internalMcps;

  final TaskProviders providers;

  // ── Runtime State ──
  final TaskExecution execution;

  // ── Output / Notification ──
  final TaskNotification notification;

  // ── Task Chaining ──
  /// Optional chaining configuration. When set, controls whether this task
  /// is a sub-task (not scheduled directly) and which tasks to trigger after
  /// this task completes (with optional LLM-evaluated condition).
  final TaskChainConfig? chainConfig;

  // ── Chat Mode ──
  /// When true: send messages directly to the LLM without any system prompt
  /// and without loading any MCP tools. Useful for pure formatting/conversion
  /// tasks with SLMs where tool overhead and complex context slow things down.
  final bool chatMode;

  // ── Stop After Tool Call ──
  /// When true: execute the first tool call but do NOT send the tool result
  /// back to the LLM. The raw tool output becomes the task result ([task_result])
  /// for any chained following agent.
  final bool stopAfterToolCall;

  // ── Metadata ──
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Tags for organizing/filtering tasks.
  final List<String> tags;

  // ── Orchestrator-Executor Fields ──
  final List<Agent> agents;
  final List<Edge> edges;

  List<Agent> get executors => agents;
  List<Edge> get routingRules => edges;

  WorkflowTask({
    required this.id,
    required this.name,
    this.description,
    this.agentId,
    this.systemPrompt,
    this.prompt = '',
    this.llmConfig,
    this.enabled = true,
    this.chatMode = false,
    this.stopAfterToolCall = false,
    required this.executionPlan,
    this.mcpTools = const [],
    this.internalMcps = const [],
    this.providers = const TaskProviders(),
    this.execution = const TaskExecution(),
    this.notification = const TaskNotification(),
    this.chainConfig,
    this.tags = const [],
    DateTime? createdAt,
    DateTime? updatedAt,
    List<Agent> agents = const [],
    List<Agent>? executors,
    List<Edge> edges = const [],
    List<Edge>? routingRules,
  }) : agents = executors ?? agents,
       edges = routingRules ?? edges,
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  /// Convenience: true if this task is a sub-task triggered by another task.
  bool get isSubtask => chainConfig?.isSubtask ?? false;

  WorkflowTask copyWith({
    String? id,
    String? name,
    String? description,
    String? agentId,
    String? systemPrompt,
    String? prompt,
    TaskLlmConfig? llmConfig,
    bool? enabled,
    bool? chatMode,
    bool? stopAfterToolCall,
    ExecutionPlan? executionPlan,
    List<McpToolConfig>? mcpTools,
    List<InternalMcpEntry>? internalMcps,
    TaskProviders? providers,
    TaskExecution? execution,
    TaskNotification? notification,
    TaskChainConfig? chainConfig,
    bool clearChainConfig = false,
    List<String>? tags,
    List<Agent>? agents,
    List<Agent>? executors,
    List<Edge>? edges,
    List<Edge>? routingRules,
  }) {
    return WorkflowTask(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      agentId: agentId ?? this.agentId,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      prompt: prompt ?? this.prompt,
      llmConfig: llmConfig ?? this.llmConfig,
      enabled: enabled ?? this.enabled,
      chatMode: chatMode ?? this.chatMode,
      stopAfterToolCall: stopAfterToolCall ?? this.stopAfterToolCall,
      executionPlan: executionPlan ?? this.executionPlan,
      mcpTools: mcpTools ?? this.mcpTools,
      internalMcps: internalMcps ?? this.internalMcps,
      providers: providers ?? this.providers,
      execution: execution ?? this.execution,
      notification: notification ?? this.notification,
      chainConfig: clearChainConfig ? null : (chainConfig ?? this.chainConfig),
      tags: tags ?? this.tags,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
      agents: executors ?? agents ?? this.agents,
      edges: routingRules ?? edges ?? this.edges,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'agent_id': agentId,
    'system_prompt': systemPrompt,
    'prompt': prompt,
    'llm_config': llmConfig?.toJson(),
    'enabled': enabled,
    'chat_mode': chatMode,
    'stop_after_tool_call': stopAfterToolCall,
    'execution_plan': executionPlan.toJson(),
    'mcp_tools': mcpTools.map((t) => t.toJson()).toList(),
    'internal_mcps': internalMcps.map((m) => m.toJson()).toList(),
    'providers': providers.toJson(),
    'execution': execution.toJson(),
    'notification': notification.toJson(),
    'tags': tags,
    if (chainConfig != null) 'chain_config': chainConfig!.toJson(),
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'agents': agents.map((e) => e.toJson()).toList(),
    'edges': edges.map((r) => r.toJson()).toList(),
  };

  factory WorkflowTask.fromJson(Map<String, dynamic> json) {
    var rawExecutors = (json['agents'] ?? json['executors']) as List<dynamic>?;
    List<Agent> parsedExecutors = [];
    if (rawExecutors != null) {
      parsedExecutors = rawExecutors.map((e) => Agent.fromJson(e as Map<String, dynamic>)).toList();
    }

    // ON-THE-FLY MIGRATION: If agents list is empty but we have a flat prompt/config, migrate it!
    if (parsedExecutors.isEmpty && (json['prompt'] as String? ?? '').isNotEmpty) {
      final legacyNotification = json['notification'] != null
          ? TaskNotification.fromJson(json['notification'] as Map<String, dynamic>)
          : const TaskNotification();
      parsedExecutors = [
        Agent(
          id: const Uuid().v4(),
          name: json['name'] as String? ?? 'Executor',
          prompt: json['prompt'] as String? ?? '',
          systemPrompt: json['system_prompt'] as String?,
          llmConfig: json['llm_config'] != null
              ? TaskLlmConfig.fromJson(json['llm_config'] as Map<String, dynamic>)
              : null,
          mcpTools: (json['mcp_tools'] as List<dynamic>?)
                  ?.map((e) => McpToolConfig.fromJson(e as Map<String, dynamic>))
                  .toList() ??
              [],
          internalMcps: (json['internal_mcps'] as List<dynamic>?)
                  ?.map((e) => InternalMcpEntry.fromJson(e as Map<String, dynamic>))
                  .toList() ??
              [],
          chatMode: json['chat_mode'] as bool? ?? false,
          stopAfterToolCall: json['stop_after_tool_call'] as bool? ?? false,
          notification: legacyNotification,
        ),
      ];
    }

    var rawRouting = (json['edges'] ?? json['routing_rules']) as List<dynamic>?;
    List<Edge> parsedRouting = [];
    if (rawRouting != null) {
      parsedRouting = rawRouting.map((e) => Edge.fromJson(e as Map<String, dynamic>)).toList();
    }

    return WorkflowTask(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      agentId: json['agent_id'] as String?,
      systemPrompt: json['system_prompt'] as String?,
      prompt: json['prompt'] as String? ?? '',
      llmConfig: json['llm_config'] != null
          ? TaskLlmConfig.fromJson(json['llm_config'] as Map<String, dynamic>)
          : null,
      enabled: json['enabled'] as bool? ?? true,
      chatMode: json['chat_mode'] as bool? ?? false,
      stopAfterToolCall: json['stop_after_tool_call'] as bool? ?? false,
      executionPlan: ExecutionPlan.fromJson(
        json['execution_plan'] as Map<String, dynamic>,
      ),
      mcpTools:
          (json['mcp_tools'] as List<dynamic>?)
              ?.map((e) => McpToolConfig.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      internalMcps:
          (json['internal_mcps'] as List<dynamic>?)
              ?.map((e) => InternalMcpEntry.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      providers: json['providers'] != null
          ? TaskProviders.fromJson(json['providers'] as Map<String, dynamic>)
          : const TaskProviders(),
      execution: json['execution'] != null
          ? TaskExecution.fromJson(json['execution'] as Map<String, dynamic>)
          : const TaskExecution(),
      notification: json['notification'] != null
          ? TaskNotification.fromJson(
              json['notification'] as Map<String, dynamic>,
            )
          : const TaskNotification(),
      tags: (json['tags'] as List<dynamic>?)?.cast<String>() ?? [],
      chainConfig: json['chain_config'] != null
          ? TaskChainConfig.fromJson(json['chain_config'] as Map<String, dynamic>)
          : null,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      agents: parsedExecutors,
      edges: parsedRouting,
    );
  }

  @override
  String toString() => 'WorkflowTask($id, $name, enabled=$enabled)';
}

// ═══════════════════════════════════════════════════════════════
// EXECUTION PLAN (Scheduling)
// ═══════════════════════════════════════════════════════════════

class ExecutionPlan {
  /// Cron expression, e.g. "0 */6 * * *" = every 6 hours.
  final String cronExpression;

  /// IANA timezone, e.g. "Europe/Vienna". Null = device local.
  final String? timezone;

  /// Human-readable hint, e.g. "Every 6 hours".
  final String? scheduleHint;

  /// Retry on failure after delay.
  final bool retryOnFailure;
  final int maxRetries;
  final int retryDelayMinutes;

  /// Run immediately after creation (one-shot before schedule starts).
  final bool executeImmediately;

  const ExecutionPlan({
    required this.cronExpression,
    this.timezone,
    this.scheduleHint,
    this.retryOnFailure = false,
    this.maxRetries = 3,
    this.retryDelayMinutes = 15,
    this.executeImmediately = false,
  });

  /// Parse the cron expression into a repeat interval in minutes.
  ///
  /// Understood patterns:
  ///   `* * * * *`      → 1   (always mapped to minimum 15 on mobile)
  ///   `*/N * * * *`    → N
  ///   `0 * * * *`      → 60
  ///   `0 */N * * *`    → N × 60
  ///   `0 H * * *`      → 1440  (daily)
  ///   `0 H * * D`      → 10080 (weekly)
  ///   `0 H 1 * *`      → 43800 (monthly ~30.4 days)
  /// Anything else      → 1440  (fall back to daily)
  int get intervalMinutes {
    final parts = cronExpression.trim().split(RegExp(r'\s+'));
    if (parts.length < 5) return 1440;

    final minute = parts[0];
    final hour = parts[1];
    final dom = parts[2]; // day-of-month
    final month = parts[3];
    final dow = parts[4]; // day-of-week

    // Every N minutes: `*/N * * * *`
    if (minute.startsWith('*/')) {
      final n = int.tryParse(minute.substring(2));
      if (n != null &&
          n > 0 &&
          hour == '*' &&
          dom == '*' &&
          month == '*' &&
          dow == '*') {
        return n;
      }
    }
    // Every minute: `* * * * *`
    if (minute == '*' &&
        hour == '*' &&
        dom == '*' &&
        month == '*' &&
        dow == '*') {
      return 1;
    }
    // Hourly: `0 * * * *`
    if (minute == '0' &&
        hour == '*' &&
        dom == '*' &&
        month == '*' &&
        dow == '*') {
      return 60;
    }
    // Every N hours: `0 */N * * *`
    if (minute == '0' && hour.startsWith('*/')) {
      final n = int.tryParse(hour.substring(2));
      if (n != null && n > 0 && dom == '*' && month == '*' && dow == '*') {
        return n * 60;
      }
    }
    // Weekly (specific dow): `0 H * * D`
    if (minute == '0' &&
        dom == '*' &&
        month == '*' &&
        dow != '*' &&
        !dow.contains('/')) {
      return 10080; // 7 × 1440
    }
    // Monthly: `0 H 1 * *`  or  `0 H D * *`
    if (minute == '0' && dom != '*' && month == '*' && dow == '*') {
      return 43800; // ≈ 30.4 days
    }
    // Daily (fixed hour): `0 H * * *`
    if (minute == '0' &&
        !hour.contains('/') &&
        !hour.contains('*') &&
        dom == '*' &&
        month == '*' &&
        dow == '*') {
      return 1440;
    }
    return 1440; // default: daily
  }

  /// Effective interval on the given platform, respecting minimum constraints.
  int effectiveIntervalMinutes({bool isMobile = false}) {
    const mobileMin = 15;
    final i = intervalMinutes;
    return isMobile ? i.clamp(mobileMin, 999999) : i;
  }

  /// Human-readable display of this schedule.
  String get humanInterval {
    if (scheduleHint != null && scheduleHint!.isNotEmpty) return scheduleHint!;
    final m = intervalMinutes;
    if (m < 60) return 'Alle $m Minuten';
    if (m == 60) return 'Stündlich';
    if (m % 60 == 0 && m < 1440) return 'Alle ${m ~/ 60} Stunden';
    if (m == 1440) return 'Täglich';
    if (m == 10080) return 'Wöchentlich';
    if (m >= 43200) return 'Monatlich';
    return cronExpression;
  }

  Map<String, dynamic> toJson() => {
    'cron_expression': cronExpression,
    'timezone': timezone,
    'schedule_hint': scheduleHint,
    'retry_on_failure': retryOnFailure,
    'max_retries': maxRetries,
    'retry_delay_minutes': retryDelayMinutes,
    'execute_immediately': executeImmediately,
  };

  factory ExecutionPlan.fromJson(Map<String, dynamic> json) => ExecutionPlan(
    cronExpression: json['cron_expression'] as String,
    timezone: json['timezone'] as String?,
    scheduleHint: json['schedule_hint'] as String?,
    retryOnFailure: json['retry_on_failure'] as bool? ?? false,
    maxRetries: json['max_retries'] as int? ?? 3,
    retryDelayMinutes: json['retry_delay_minutes'] as int? ?? 15,
    executeImmediately: json['execute_immediately'] as bool? ?? false,
  );
}

// ═══════════════════════════════════════════════════════════════
// LLM CONFIG (task-level override)
// ═══════════════════════════════════════════════════════════════

class TaskLlmConfig {
  final String
  provider; // gemini | openai | claude | ollama | openai_compatible
  final String? baseUrl; // for Ollama / OpenAI-compatible
  final String? apiKey;
  final String model;
  final double temperature;
  final int maxTokens;

  /// Additional provider-specific parameters (top_p, top_k, etc.)
  /// Also includes 'use_native_tool_call' (bool) for per-task override.
  final Map<String, dynamic> extraParams;

  /// Convenience getter: whether native tool calling is enabled.
  /// Defaults to `true` when not explicitly set in [extraParams].
  bool get useNativeToolCall =>
      (extraParams['use_native_tool_call'] as bool?) ?? true;

  const TaskLlmConfig({
    required this.provider,
    this.baseUrl,
    this.apiKey,
    required this.model,
    this.temperature = 0.7,
    this.maxTokens = 0,
    this.extraParams = const {},
  });

  Map<String, dynamic> toJson() => {
    'provider': provider,
    'base_url': baseUrl,
    'api_key': apiKey,
    'model': model,
    'temperature': temperature,
    'max_tokens': maxTokens,
    'extra_params': extraParams,
  };

  factory TaskLlmConfig.fromJson(Map<String, dynamic> json) => TaskLlmConfig(
    provider: json['provider'] as String,
    baseUrl: json['base_url'] as String?,
    apiKey: json['api_key'] as String?,
    model: json['model'] as String,
    temperature: (json['temperature'] as num?)?.toDouble() ?? 0.7,
    maxTokens: json['max_tokens'] as int? ?? 0,
    extraParams: (json['extra_params'] as Map<String, dynamic>?) ?? const {},
  );
}

// ═══════════════════════════════════════════════════════════════
// MCP TOOLS
// ═══════════════════════════════════════════════════════════════

class McpToolConfig {
  final String serverUrl;
  final String? name; // display name
  final String? description; // short description for catalog UI
  final bool? isOnline; // catalog-reported health state (if available)
  final String? mcpEndpoint; // JSON-RPC endpoint path (default: /mcp)
  final String? specificationUrl; // OpenAPI/MCP spec URL (optional)
  final String?
  catalogPageUrl; // glama.ai / catalog info page (not the live endpoint)
  final String? apiKey;
  final String? apiPassword;

  /// Optional: only use specific tools from this server (null = all).
  final List<String>? enabledTools;

  /// Discovered tools/prompts/resources from the server (cached locally).
  final List<String> discoveredTools;
  final List<String> discoveredPrompts;
  final List<String> discoveredResources;

  /// Full tool schemas (name + description + inputSchema) cached when tools are
  /// discovered at runtime, used for offline skill generation.
  final List<Map<String, dynamic>> discoveredToolSchemas;

  const McpToolConfig({
    required this.serverUrl,
    this.name,
    this.description,
    this.isOnline,
    this.mcpEndpoint = '/mcp',
    this.specificationUrl,
    this.catalogPageUrl,
    this.apiKey,
    this.apiPassword,
    this.enabledTools,
    this.discoveredTools = const [],
    this.discoveredPrompts = const [],
    this.discoveredResources = const [],
    this.discoveredToolSchemas = const [],
  });

  McpToolConfig copyWith({
    String? serverUrl,
    String? name,
    String? description,
    bool? isOnline,
    String? mcpEndpoint,
    String? specificationUrl,
    String? catalogPageUrl,
    String? apiKey,
    String? apiPassword,
    List<String>? enabledTools,
    List<String>? discoveredTools,
    List<String>? discoveredPrompts,
    List<String>? discoveredResources,
    List<Map<String, dynamic>>? discoveredToolSchemas,
  }) {
    return McpToolConfig(
      serverUrl: serverUrl ?? this.serverUrl,
      name: name ?? this.name,
      description: description ?? this.description,
      isOnline: isOnline ?? this.isOnline,
      mcpEndpoint: mcpEndpoint ?? this.mcpEndpoint,
      specificationUrl: specificationUrl ?? this.specificationUrl,
      catalogPageUrl: catalogPageUrl ?? this.catalogPageUrl,
      apiKey: apiKey ?? this.apiKey,
      apiPassword: apiPassword ?? this.apiPassword,
      enabledTools: enabledTools ?? this.enabledTools,
      discoveredTools: discoveredTools ?? this.discoveredTools,
      discoveredPrompts: discoveredPrompts ?? this.discoveredPrompts,
      discoveredResources: discoveredResources ?? this.discoveredResources,
      discoveredToolSchemas:
          discoveredToolSchemas ?? this.discoveredToolSchemas,
    );
  }

  Map<String, dynamic> toJson() => {
    'server_url': serverUrl,
    'name': name,
    'description': description,
    'is_online': isOnline,
    'mcp_endpoint': mcpEndpoint,
    'specification_url': specificationUrl,
    'catalog_page_url': catalogPageUrl,
    'api_key': apiKey,
    'api_password': apiPassword,
    'enabled_tools': enabledTools,
    'discovered_tools': discoveredTools,
    'discovered_prompts': discoveredPrompts,
    'discovered_resources': discoveredResources,
    'discovered_tool_schemas': discoveredToolSchemas,
  };

  factory McpToolConfig.fromJson(Map<String, dynamic> json) => McpToolConfig(
    serverUrl: json['server_url'] as String,
    name: json['name'] as String?,
    description: json['description'] as String?,
    isOnline: json['is_online'] as bool?,
    mcpEndpoint: json['mcp_endpoint'] as String? ?? '/mcp',
    specificationUrl: json['specification_url'] as String?,
    catalogPageUrl: json['catalog_page_url'] as String?,
    apiKey: json['api_key'] as String?,
    apiPassword: json['api_password'] as String?,
    enabledTools: (json['enabled_tools'] as List<dynamic>?)?.cast<String>(),
    discoveredTools:
        (json['discovered_tools'] as List<dynamic>?)?.cast<String>() ??
        const [],
    discoveredPrompts:
        (json['discovered_prompts'] as List<dynamic>?)?.cast<String>() ??
        const [],
    discoveredResources:
        (json['discovered_resources'] as List<dynamic>?)?.cast<String>() ??
        const [],
    discoveredToolSchemas:
        (json['discovered_tool_schemas'] as List<dynamic>?)
            ?.map((e) => Map<String, dynamic>.from(e as Map))
            .toList() ??
        const [],
  );
}

// ═══════════════════════════════════════════════════════════════
// PROVIDERS (Email, Web Search)
// ═══════════════════════════════════════════════════════════════

class TaskProviders {
  final EmailProviderConfig? email;
  final WebSearchConfig? webSearch;

  /// Extensible: future providers (calendar, CRM, etc.)
  final Map<String, dynamic> custom;

  const TaskProviders({this.email, this.webSearch, this.custom = const {}});

  bool get hasAnyProvider =>
      email != null || webSearch != null || custom.isNotEmpty;

  TaskProviders copyWith({
    EmailProviderConfig? email,
    WebSearchConfig? webSearch,
    Map<String, dynamic>? custom,
  }) {
    return TaskProviders(
      email: email ?? this.email,
      webSearch: webSearch ?? this.webSearch,
      custom: custom ?? this.custom,
    );
  }

  /// Returns a copy with the email provider removed.
  TaskProviders withoutEmail() =>
      TaskProviders(webSearch: webSearch, custom: custom);

  /// Returns a copy with the web search provider removed.
  TaskProviders withoutWebSearch() =>
      TaskProviders(email: email, custom: custom);

  Map<String, dynamic> toJson() => {
    'email': email?.toJson(),
    'web_search': webSearch?.toJson(),
    'custom': custom,
  };

  factory TaskProviders.fromJson(Map<String, dynamic> json) => TaskProviders(
    email: json['email'] != null
        ? EmailProviderConfig.fromJson(json['email'] as Map<String, dynamic>)
        : null,
    webSearch: json['web_search'] != null
        ? WebSearchConfig.fromJson(json['web_search'] as Map<String, dynamic>)
        : null,
    custom: (json['custom'] as Map<String, dynamic>?) ?? {},
  );
}

/// Email provider — flexible auth: OAuth2 for Google/Microsoft, IMAP for others.
class EmailProviderConfig {
  /// google | microsoft | imap
  final String type;

  /// For IMAP: server URL. For Google/Microsoft: not needed (SDK handles it).
  final String? url;

  /// OAuth2 tokens (Google/Microsoft) or IMAP credentials.
  final EmailAuthData authData;

  const EmailProviderConfig({
    required this.type,
    this.url,
    required this.authData,
  });

  Map<String, dynamic> toJson() => {
    'type': type,
    'url': url,
    'auth_data': authData.toJson(),
  };

  factory EmailProviderConfig.fromJson(Map<String, dynamic> json) =>
      EmailProviderConfig(
        type: json['type'] as String,
        url: json['url'] as String?,
        authData: EmailAuthData.fromJson(
          json['auth_data'] as Map<String, dynamic>,
        ),
      );
}

/// Flexible email auth — shape varies by provider type.
class EmailAuthData {
  /// For OAuth2: access_token, refresh_token, expires_at
  /// For IMAP: user, password, port, use_ssl
  final Map<String, dynamic> data;

  const EmailAuthData({required this.data});

  // ── Convenience getters for OAuth2 ──
  String? get accessToken => data['access_token'] as String?;
  String? get refreshToken => data['refresh_token'] as String?;
  DateTime? get expiresAt => data['expires_at'] != null
      ? DateTime.tryParse(data['expires_at'] as String)
      : null;
  String? get email => data['email'] as String?;

  // ── Convenience getters for IMAP ──
  String? get user => data['user'] as String?;
  String? get password => data['password'] as String?;
  int? get port => data['port'] as int?;
  bool get useSsl => data['use_ssl'] as bool? ?? true;

  bool get isExpired {
    final exp = expiresAt;
    if (exp == null) return false;
    return DateTime.now().isAfter(exp);
  }

  Map<String, dynamic> toJson() => data;

  factory EmailAuthData.fromJson(Map<String, dynamic> json) =>
      EmailAuthData(data: Map<String, dynamic>.from(json));
}

class WebSearchConfig {
  /// serper | duckduckgo
  final String type;
  final String? apiKey;

  /// Google-specific: Programmable Search Engine ID.
  final String? searchEngineId;

  /// Max results per search.
  final int maxResults;

  const WebSearchConfig({
    required this.type,
    this.apiKey,
    this.searchEngineId,
    this.maxResults = 5,
  });

  Map<String, dynamic> toJson() => {
    'type': type,
    'api_key': apiKey,
    'search_engine_id': searchEngineId,
    'max_results': maxResults,
  };

  factory WebSearchConfig.fromJson(Map<String, dynamic> json) =>
      WebSearchConfig(
        type: json['type'] as String,
        apiKey: json['api_key'] as String?,
        searchEngineId: json['search_engine_id'] as String?,
        maxResults: json['max_results'] as int? ?? 5,
      );
}

// ═══════════════════════════════════════════════════════════════
// EXECUTION STATE (runtime tracking)
// ═══════════════════════════════════════════════════════════════

class TaskExecution {
  final DateTime? lastRun;
  final DateTime? nextRun;
  final String? lastResult;
  final String? lastError;
  final int runCount;
  final int consecutiveFailures;
  final bool isRunning;

  /// Recent execution history (last N runs, configurable).
  final List<TaskRunRecord> history;

  const TaskExecution({
    this.lastRun,
    this.nextRun,
    this.lastResult,
    this.lastError,
    this.runCount = 0,
    this.consecutiveFailures = 0,
    this.isRunning = false,
    this.history = const [],
  });

  TaskExecution recordRun({
    required bool success,
    String? result,
    String? error,
    DateTime? nextRun,
    int maxHistory = 50,
    List<String> outputFilePaths = const [],
    String? rawOutput,
    int? durationMs,
    int? tokensUsed,
    int? toolCallCount,
    int? messageCount,
    int? sentChars,
    double? lastRequestCostUsd,
    double? sessionCostUsd,
  }) {
    final record = TaskRunRecord(
      timestamp: DateTime.now().toUtc(),
      success: success,
      result: result,
      error: error,
      outputFilePaths: outputFilePaths,
      rawOutput: rawOutput,
      durationMs: durationMs,
      tokensUsed: tokensUsed,
      toolCallCount: toolCallCount,
      messageCount: messageCount,
      sentChars: sentChars,
      lastRequestCostUsd: lastRequestCostUsd,
      sessionCostUsd: sessionCostUsd,
    );
    final newHistory = [record, ...history].take(maxHistory).toList();

    return TaskExecution(
      lastRun: DateTime.now().toUtc(),
      nextRun: nextRun?.toUtc(),
      lastResult: result,
      lastError: success ? null : error,
      runCount: runCount + 1,
      consecutiveFailures: success ? 0 : consecutiveFailures + 1,
      isRunning: false,
      history: newHistory,
    );
  }

  Map<String, dynamic> toJson() => {
    'last_run': lastRun?.toIso8601String(),
    'next_run': nextRun?.toIso8601String(),
    'last_result': lastResult,
    'last_error': lastError,
    'run_count': runCount,
    'consecutive_failures': consecutiveFailures,
    'is_running': isRunning,
    'history': history.map((r) => r.toJson()).toList(),
  };

  factory TaskExecution.fromJson(Map<String, dynamic> json) => TaskExecution(
    lastRun: json['last_run'] != null
        ? DateTime.parse(json['last_run'] as String)
        : null,
    nextRun: json['next_run'] != null
        ? DateTime.parse(json['next_run'] as String)
        : null,
    lastResult: json['last_result'] as String?,
    lastError: json['last_error'] as String?,
    runCount: json['run_count'] as int? ?? 0,
    consecutiveFailures: json['consecutive_failures'] as int? ?? 0,
    isRunning: json['is_running'] as bool? ?? false,
    history:
        (json['history'] as List<dynamic>?)
            ?.map((e) => TaskRunRecord.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [],
  );
}

class TaskRunRecord {
  final DateTime timestamp;
  final bool success;
  final String? result;
  final String? error;
  final int? durationMs;
  final List<String> outputFilePaths;

  /// Full structured LLM interaction log (markdown format) — "Output Raw".
  final String? rawOutput;

  /// Execution statistics
  final int? tokensUsed;
  final int? toolCallCount;
  final int? messageCount;
  final int? sentChars;
  final double? lastRequestCostUsd;
  final double? sessionCostUsd;

  const TaskRunRecord({
    required this.timestamp,
    required this.success,
    this.result,
    this.error,
    this.durationMs,
    this.outputFilePaths = const [],
    this.rawOutput,
    this.tokensUsed,
    this.toolCallCount,
    this.messageCount,
    this.sentChars,
    this.lastRequestCostUsd,
    this.sessionCostUsd,
  });

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'success': success,
    'result': result,
    'error': error,
    'duration_ms': durationMs,
    'output_file_paths': outputFilePaths,
    if (rawOutput != null) 'raw_output': rawOutput,
    if (tokensUsed != null) 'tokens_used': tokensUsed,
    if (toolCallCount != null) 'tool_call_count': toolCallCount,
    if (messageCount != null) 'message_count': messageCount,
    if (sentChars != null) 'sent_chars': sentChars,
    if (lastRequestCostUsd != null) 'last_request_cost_usd': lastRequestCostUsd,
    if (sessionCostUsd != null) 'session_cost_usd': sessionCostUsd,
  };

  factory TaskRunRecord.fromJson(Map<String, dynamic> json) => TaskRunRecord(
    timestamp: DateTime.parse(json['timestamp'] as String),
    success: json['success'] as bool,
    result: json['result'] as String?,
    error: json['error'] as String?,
    durationMs: json['duration_ms'] as int?,
    outputFilePaths:
        (json['output_file_paths'] as List<dynamic>?)
            ?.map((e) => e as String)
            .toList() ??
        const [],
    rawOutput: json['raw_output'] as String?,
    tokensUsed: json['tokens_used'] as int?,
    toolCallCount: json['tool_call_count'] as int?,
    messageCount: json['message_count'] as int?,
    sentChars: json['sent_chars'] as int?,
    lastRequestCostUsd: (json['last_request_cost_usd'] as num?)?.toDouble(),
    sessionCostUsd: (json['session_cost_usd'] as num?)?.toDouble(),
  );
}

// ═══════════════════════════════════════════════════════════════
// NOTIFICATION (result delivery)
// ═══════════════════════════════════════════════════════════════

class TaskNotification {
  final EmailNotification? email;
  final DownloadNotification? download;
  final UploadNotification? upload;
  final PushNotification? push;

  /// Slack output channel – uses global DataSourcesSettingsService credentials.
  final SlackNotification? slack;

  /// WhatsApp output channel – uses global DataSourcesSettingsService credentials.
  final WhatsAppNotification? whatsApp;

  /// SFTP output channel – uploads result files to an SSH/SFTP server.
  final SftpOutputConfig? sftpOutput;

  final bool addExecutionLog;
  final bool zipOutputFiles;

  const TaskNotification({
    this.email,
    this.download,
    this.upload,
    this.push,
    this.slack,
    this.whatsApp,
    this.sftpOutput,
    this.addExecutionLog = false,
    this.zipOutputFiles = false,
  });

  bool get hasAnyChannel =>
      email != null ||
      download != null ||
      upload != null ||
      push != null ||
      slack != null ||
      whatsApp != null ||
      sftpOutput != null;

  Map<String, dynamic> toJson() => {
    'email': email?.toJson(),
    'download': download?.toJson(),
    'upload': upload?.toJson(),
    'push': push?.toJson(),
    'slack': slack?.toJson(),
    'whats_app': whatsApp?.toJson(),
    'sftp_output': sftpOutput?.toJson(),
    'add_execution_log': addExecutionLog,
    'zip_output_files': zipOutputFiles,
  };

  factory TaskNotification.fromJson(
    Map<String, dynamic> json,
  ) => TaskNotification(
    email: json['email'] != null
        ? EmailNotification.fromJson(json['email'] as Map<String, dynamic>)
        : null,
    download: json['download'] != null
        ? DownloadNotification.fromJson(
            json['download'] as Map<String, dynamic>,
          )
        : null,
    upload: json['upload'] != null
        ? UploadNotification.fromJson(json['upload'] as Map<String, dynamic>)
        : null,
    push: json['push'] != null
        ? PushNotification.fromJson(json['push'] as Map<String, dynamic>)
        : null,
    slack: json['slack'] != null
        ? SlackNotification.fromJson(json['slack'] as Map<String, dynamic>)
        : null,
    whatsApp: json['whats_app'] != null
        ? WhatsAppNotification.fromJson(
            json['whats_app'] as Map<String, dynamic>,
          )
        : null,
    sftpOutput: json['sftp_output'] != null
        ? SftpOutputConfig.fromJson(json['sftp_output'] as Map<String, dynamic>)
        : null,
    addExecutionLog: json['add_execution_log'] as bool? ?? false,
    zipOutputFiles: json['zip_output_files'] as bool? ?? false,
  );
}

class EmailNotification {
  /// Which email provider to send through (references TaskProviders.email,
  /// or a standalone SMTP config).
  final String? provider;
  final List<String> recipients;
  final String? subject;
  final bool withAttachment;

  /// Condition to trigger email: "always" | "on_error" | "on_change"
  final String sendCondition;

  /// Optional custom condition expression evaluated against the task output
  /// when [sendCondition] is "conditional".
  final String? conditionExpression;

  const EmailNotification({
    this.provider,
    required this.recipients,
    this.subject,
    this.withAttachment = true,
    this.sendCondition = 'always',
    this.conditionExpression,
  });

  Map<String, dynamic> toJson() => {
    'provider': provider,
    'recipients': recipients,
    'subject': subject,
    'with_attachment': withAttachment,
    'send_condition': sendCondition,
    if (conditionExpression != null)
      'condition_expression': conditionExpression,
  };

  factory EmailNotification.fromJson(Map<String, dynamic> json) =>
      EmailNotification(
        provider: json['provider'] as String?,
        recipients: (json['recipients'] as List<dynamic>).cast<String>(),
        subject: json['subject'] as String?,
        withAttachment: json['with_attachment'] as bool? ?? true,
        sendCondition: json['send_condition'] as String? ?? 'always',
        conditionExpression: json['condition_expression'] as String?,
      );
}

class DownloadNotification {
  /// Local path to save results. Null = platform default downloads folder.
  final String? downloadPath;

  /// File name pattern, e.g. "report_{date}.txt"
  final String? fileNamePattern;

  const DownloadNotification({this.downloadPath, this.fileNamePattern});

  Map<String, dynamic> toJson() => {
    'download_path': downloadPath,
    'file_name_pattern': fileNamePattern,
  };

  factory DownloadNotification.fromJson(Map<String, dynamic> json) =>
      DownloadNotification(
        downloadPath: json['download_path'] as String?,
        fileNamePattern: json['file_name_pattern'] as String?,
      );
}

class UploadNotification {
  final UploadTarget? googleDrive;
  final UploadTarget? oneDrive;
  final SftpTarget? sftp;

  const UploadNotification({this.googleDrive, this.oneDrive, this.sftp});

  Map<String, dynamic> toJson() => {
    'google_drive': googleDrive?.toJson(),
    'one_drive': oneDrive?.toJson(),
    'sftp': sftp?.toJson(),
  };

  factory UploadNotification.fromJson(Map<String, dynamic> json) =>
      UploadNotification(
        googleDrive: json['google_drive'] != null
            ? UploadTarget.fromJson(
                json['google_drive'] as Map<String, dynamic>,
              )
            : null,
        oneDrive: json['one_drive'] != null
            ? UploadTarget.fromJson(json['one_drive'] as Map<String, dynamic>)
            : null,
        sftp: json['sftp'] != null
            ? SftpTarget.fromJson(json['sftp'] as Map<String, dynamic>)
            : null,
      );
}

/// Cloud upload target (Google Drive, OneDrive).
class UploadTarget {
  final String? apiKey;
  final String? folderId; // target folder in cloud
  final String? folderPath; // human-readable path

  const UploadTarget({this.apiKey, this.folderId, this.folderPath});

  Map<String, dynamic> toJson() => {
    'api_key': apiKey,
    'folder_id': folderId,
    'folder_path': folderPath,
  };

  factory UploadTarget.fromJson(Map<String, dynamic> json) => UploadTarget(
    apiKey: json['api_key'] as String?,
    folderId: json['folder_id'] as String?,
    folderPath: json['folder_path'] as String?,
  );
}

/// SFTP upload target.
class SftpTarget {
  final String url;
  final int port;
  final String user;
  final String? password;
  final String? privateKey;
  final String remotePath;

  const SftpTarget({
    required this.url,
    this.port = 22,
    required this.user,
    this.password,
    this.privateKey,
    this.remotePath = '/',
  });

  Map<String, dynamic> toJson() => {
    'url': url,
    'port': port,
    'user': user,
    'password': password,
    'private_key': privateKey,
    'remote_path': remotePath,
  };

  factory SftpTarget.fromJson(Map<String, dynamic> json) => SftpTarget(
    url: json['url'] as String,
    port: json['port'] as int? ?? 22,
    user: json['user'] as String,
    password: json['password'] as String?,
    privateKey: json['private_key'] as String?,
    remotePath: json['remote_path'] as String? ?? '/',
  );
}

// ── SFTP output channel ───────────────────────────────────────────────────────

/// Configuration for writing task output to an SFTP server.
///
/// When [useConfiguredSshServer] is `true` the global SSH credentials from
/// [DataSourcesSettingsService] are used and [host], [port], [username] are
/// ignored.  Otherwise the custom fields apply.
///
/// [password] is intentionally excluded from vault / task-export backups
/// (the `ImportExportService._sanitize` method strips any key named `password`).
class SftpOutputConfig {
  /// If true: use the SSH server configured in Data Sources settings.
  final bool useConfiguredSshServer;

  /// Custom host (used when [useConfiguredSshServer] is false).
  final String host;

  /// Custom port (default 22, used when [useConfiguredSshServer] is false).
  final int port;

  /// Custom username (used when [useConfiguredSshServer] is false).
  final String username;

  /// Password — stored in the task record but stripped by export sanitizer.
  /// Null = no password / uses key-based auth from global settings.
  final String? password;

  /// Optional private key PEM for custom SFTP target.
  final String? privateKey;

  /// Target directory on the SFTP server (e.g. `/uploads/tealkit`).
  final String remotePath;

  /// When true, send a notification e-mail after a successful upload.
  final bool notifyByEmail;

  /// Recipient address for the notification e-mail.
  final String notifyEmailAddress;

  /// Subject of the notification e-mail.
  final String notifyEmailSubject;

  /// Body of the notification e-mail.  Empty = use built-in template.
  final String notifyEmailBody;

  const SftpOutputConfig({
    this.useConfiguredSshServer = true,
    this.host = '',
    this.port = 22,
    this.username = '',
    this.password,
    this.privateKey,
    this.remotePath = '/',
    this.notifyByEmail = false,
    this.notifyEmailAddress = '',
    this.notifyEmailSubject = '',
    this.notifyEmailBody = '',
  });

  Map<String, dynamic> toJson() => {
    'use_configured_ssh_server': useConfiguredSshServer,
    'host': host,
    'port': port,
    'username': username,
    'password': password, // stripped by ImportExportService._sanitize on export
    'private_key': privateKey,
    'remote_path': remotePath,
    'notify_by_email': notifyByEmail,
    'notify_email_address': notifyEmailAddress,
    'notify_email_subject': notifyEmailSubject,
    'notify_email_body': notifyEmailBody,
  };

  factory SftpOutputConfig.fromJson(Map<String, dynamic> json) =>
      SftpOutputConfig(
        useConfiguredSshServer:
            json['use_configured_ssh_server'] as bool? ?? true,
        host: json['host'] as String? ?? '',
        port: json['port'] as int? ?? 22,
        username: json['username'] as String? ?? '',
        password: json['password'] as String?,
        privateKey: json['private_key'] as String?,
        remotePath: json['remote_path'] as String? ?? '/',
        notifyByEmail: json['notify_by_email'] as bool? ?? false,
        notifyEmailAddress: json['notify_email_address'] as String? ?? '',
        notifyEmailSubject: json['notify_email_subject'] as String? ?? '',
        notifyEmailBody: json['notify_email_body'] as String? ?? '',
      );
}

class PushNotification {
  final bool enabled;
  final String? title;

  /// "always" | "on_error" | "on_success" | "on_change"
  final String condition;

  const PushNotification({
    this.enabled = true,
    this.title,
    this.condition = 'always',
  });

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'title': title,
    'condition': condition,
  };

  factory PushNotification.fromJson(Map<String, dynamic> json) =>
      PushNotification(
        enabled: json['enabled'] as bool? ?? true,
        title: json['title'] as String?,
        condition: json['condition'] as String? ?? 'always',
      );
}

class SlackNotification {
  /// "always" | "on_success" | "on_error"
  final String sendCondition;

  /// Override the global default channel (from DataSourcesSettingsService).
  /// Null = use global default.
  final String? overrideChannel;

  /// When true, include task output files as Slack file uploads
  /// (requires bot token; falls back to inline text when only webhook is set).
  final bool withAttachment;

  const SlackNotification({
    this.sendCondition = 'always',
    this.overrideChannel,
    this.withAttachment = true,
  });

  Map<String, dynamic> toJson() => {
    'send_condition': sendCondition,
    'override_channel': overrideChannel,
    'with_attachment': withAttachment,
  };

  factory SlackNotification.fromJson(Map<String, dynamic> json) =>
      SlackNotification(
        sendCondition: json['send_condition'] as String? ?? 'always',
        overrideChannel: json['override_channel'] as String?,
        withAttachment: json['with_attachment'] as bool? ?? true,
      );
}

class WhatsAppNotification {
  /// "always" | "on_success" | "on_error"
  final String sendCondition;

  /// Override the global default recipient number (international format, e.g. +43…).
  /// Null = use global default from DataSourcesSettingsService.
  final String? overrideRecipient;

  /// When true, send output files as WhatsApp document messages
  /// (each file is uploaded via the Media API then sent as a document).
  final bool withAttachment;

  const WhatsAppNotification({
    this.sendCondition = 'always',
    this.overrideRecipient,
    this.withAttachment = true,
  });

  Map<String, dynamic> toJson() => {
    'send_condition': sendCondition,
    'override_recipient': overrideRecipient,
    'with_attachment': withAttachment,
  };

  factory WhatsAppNotification.fromJson(Map<String, dynamic> json) =>
      WhatsAppNotification(
        sendCondition: json['send_condition'] as String? ?? 'always',
        overrideRecipient: json['override_recipient'] as String?,
        withAttachment: json['with_attachment'] as bool? ?? true,
      );
}

// ═══════════════════════════════════════════════════════════════
// INTERNAL MCP ENTRY (built-in MCP server config per task)
// ═══════════════════════════════════════════════════════════════

/// Configuration entry for a built-in internal MCP server attached to a task.
///
/// Each entry identifies the MCP type (e.g. 'weather', 'gmail', 'doc-search')
/// and provides the init parameters specific to that MCP server.
class InternalMcpEntry {
  static ParamsEncryptor? encryptor;
  static ParamsDecryptor? decryptor;
  /// Unique ID for this entry.
  final String id;

  /// MCP server type (matches [InternalMcpServer.type]).
  /// e.g. 'weather', 'gmail', 'doc-search', 'website-search'
  final String mcpType;

  /// Human-readable label for this config (optional, auto-derived if null).
  final String? label;

  /// Initialization parameters specific to this MCP type.
  /// e.g. for weather: { "location": "Vienna", "timezone": "Europe/Vienna" }
  final Map<String, dynamic> initParams;

  /// System prompt tailored for this MCP. Can be customised per task.
  final String? systemPrompt;

  /// Whether this internal MCP is active for the task.
  final bool enabled;

  const InternalMcpEntry({
    required this.id,
    required this.mcpType,
    this.label,
    this.initParams = const {},
    this.systemPrompt,
    this.enabled = true,
  });

  InternalMcpEntry copyWith({
    String? mcpType,
    String? label,
    Map<String, dynamic>? initParams,
    String? systemPrompt,
    bool? clearSystemPrompt,
    bool? enabled,
  }) {
    return InternalMcpEntry(
      id: id,
      mcpType: mcpType ?? this.mcpType,
      label: label ?? this.label,
      initParams: initParams ?? this.initParams,
      systemPrompt: clearSystemPrompt == true
          ? null
          : (systemPrompt ?? this.systemPrompt),
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'mcp_type': mcpType,
    'label': label,
    'init_params': encryptor != null ? encryptor!(initParams) : initParams,
    if (systemPrompt != null) 'system_prompt': systemPrompt,
    'enabled': enabled,
  };

  factory InternalMcpEntry.fromJson(Map<String, dynamic> json) =>
      InternalMcpEntry(
        id: json['id'] as String,
        mcpType: json['mcp_type'] as String,
        label: json['label'] as String?,
        initParams: decryptor != null
            ? decryptor!((json['init_params'] as Map<String, dynamic>?) ?? {})
            : ((json['init_params'] as Map<String, dynamic>?) ?? {}),
        systemPrompt: json['system_prompt'] as String?,
        enabled: json['enabled'] as bool? ?? true,
      );

  @override
  String toString() => 'InternalMcpEntry($mcpType, enabled=$enabled)';
}

// ═══════════════════════════════════════════════════════════════
// TASK CHAIN CONFIG
// ═══════════════════════════════════════════════════════════════

/// Controls how a task participates in chained / conditional execution.
///
/// A task can be either the **trigger** (parent) or the **subtask** (child):
///
/// Trigger task sets:
///   - [triggerCondition] — LLM-evaluated expression, e.g. "temperature < 10"
///   - [onMatchTaskId]    — task to run if condition is TRUE (or unconditionally
///                          if [triggerCondition] is null)
///   - [onNoMatchTaskId] — task to run if condition is FALSE  (optional "else")
///
/// Subtask sets:
///   - [isSubtask] = true  → task is NOT scheduled; only run by a parent task
///
/// In the child task's [WorkflowTask.prompt], you may use the placeholder
/// `\${task_result}` which will be replaced at runtime with the parent's
/// result text before execution.
class TaskChainConfig {
  /// If true, this task should only be triggered by another task, not the
  /// scheduler. Its cron schedule is stored but ignored at runtime.
  final bool isSubtask;

  /// LLM-evaluated condition. NULL = no gate → always chain immediately.
  /// Example: "temperature below 10 degrees"
  /// The LLM is given the parent task's result and must answer "true"/"false".
  final String? triggerCondition;

  /// ID of the task to run when [triggerCondition] is TRUE (or when there is
  /// no condition). NULL = no chained task on match.
  final String? onMatchTaskId;

  /// ID of the task to run when [triggerCondition] is FALSE. NULL = no "else".
  final String? onNoMatchTaskId;

  const TaskChainConfig({
    this.isSubtask = false,
    this.triggerCondition,
    this.onMatchTaskId,
    this.onNoMatchTaskId,
  });

  /// Whether this config has any chaining triggers configured.
  bool get hasChaining => onMatchTaskId != null || onNoMatchTaskId != null;

  TaskChainConfig copyWith({
    bool? isSubtask,
    String? triggerCondition,
    bool clearTriggerCondition = false,
    String? onMatchTaskId,
    bool clearOnMatchTaskId = false,
    String? onNoMatchTaskId,
    bool clearOnNoMatchTaskId = false,
  }) {
    return TaskChainConfig(
      isSubtask: isSubtask ?? this.isSubtask,
      triggerCondition: clearTriggerCondition
          ? null
          : (triggerCondition ?? this.triggerCondition),
      onMatchTaskId: clearOnMatchTaskId
          ? null
          : (onMatchTaskId ?? this.onMatchTaskId),
      onNoMatchTaskId: clearOnNoMatchTaskId
          ? null
          : (onNoMatchTaskId ?? this.onNoMatchTaskId),
    );
  }

  Map<String, dynamic> toJson() => {
    'is_subtask': isSubtask,
    if (triggerCondition != null) 'trigger_condition': triggerCondition,
    if (onMatchTaskId != null) 'on_match_task_id': onMatchTaskId,
    if (onNoMatchTaskId != null) 'on_no_match_task_id': onNoMatchTaskId,
  };

  factory TaskChainConfig.fromJson(Map<String, dynamic> json) =>
      TaskChainConfig(
        isSubtask: json['is_subtask'] as bool? ?? false,
        triggerCondition: json['trigger_condition'] as String?,
        onMatchTaskId: json['on_match_task_id'] as String?,
        onNoMatchTaskId: json['on_no_match_task_id'] as String?,
      );

  @override
  String toString() =>
      'TaskChainConfig(isSubtask=$isSubtask, condition=$triggerCondition, '
      'onMatch=$onMatchTaskId, onNoMatch=$onNoMatchTaskId)';
}

// ═══════════════════════════════════════════════════════════════
// EXECUTOR & ROUTING ENGINE
// ═══════════════════════════════════════════════════════════════

class Agent {
  final String id;
  final String name;
  final String? systemPrompt;
  final String prompt;
  final TaskLlmConfig? llmConfig;
  final List<McpToolConfig> mcpTools;
  final List<InternalMcpEntry> internalMcps;
  final bool chatMode;
  final bool stopAfterToolCall;
  final ExecutionPlan? executionPlan;
  final TaskNotification notification;
  final DateTime? lastRun;
  final DateTime? nextRun;

  const Agent({
    required this.id,
    required this.name,
    this.systemPrompt,
    required this.prompt,
    this.llmConfig,
    this.mcpTools = const [],
    this.internalMcps = const [],
    this.chatMode = false,
    this.stopAfterToolCall = false,
    this.executionPlan,
    this.notification = const TaskNotification(),
    this.lastRun,
    this.nextRun,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'system_prompt': systemPrompt,
        'prompt': prompt,
        'llm_config': llmConfig?.toJson(),
        'mcp_tools': mcpTools.map((t) => t.toJson()).toList(),
        'internal_mcps': internalMcps.map((m) => m.toJson()).toList(),
        'chat_mode': chatMode,
        'stop_after_tool_call': stopAfterToolCall,
        'notification': notification.toJson(),
        if (executionPlan != null) 'execution_plan': executionPlan!.toJson(),
        if (lastRun != null) 'last_run': lastRun!.toUtc().toIso8601String(),
        if (nextRun != null) 'next_run': nextRun!.toUtc().toIso8601String(),
      };

  factory Agent.fromJson(Map<String, dynamic> json) => Agent(
        id: json['id'] as String,
        name: json['name'] as String,
        systemPrompt: json['system_prompt'] as String?,
        prompt: json['prompt'] as String,
        llmConfig: json['llm_config'] != null
            ? TaskLlmConfig.fromJson(json['llm_config'] as Map<String, dynamic>)
            : null,
        mcpTools: (json['mcp_tools'] as List<dynamic>?)
                ?.map((e) => McpToolConfig.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
        internalMcps: (json['internal_mcps'] as List<dynamic>?)
                ?.map((e) => InternalMcpEntry.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
        chatMode: json['chat_mode'] as bool? ?? false,
        stopAfterToolCall: json['stop_after_tool_call'] as bool? ?? false,
        executionPlan: json['execution_plan'] != null
            ? ExecutionPlan.fromJson(json['execution_plan'] as Map<String, dynamic>)
            : null,
        notification: json['notification'] != null
            ? TaskNotification.fromJson(json['notification'] as Map<String, dynamic>)
            : const TaskNotification(),
        lastRun: json['last_run'] != null
            ? DateTime.parse(json['last_run'] as String).toLocal()
            : null,
        nextRun: json['next_run'] != null
            ? DateTime.parse(json['next_run'] as String).toLocal()
            : null,
      );

  Agent copyWith({
    String? name,
    String? systemPrompt,
    String? prompt,
    TaskLlmConfig? llmConfig,
    bool clearLlmConfig = false,
    List<McpToolConfig>? mcpTools,
    List<InternalMcpEntry>? internalMcps,
    bool? chatMode,
    bool? stopAfterToolCall,
    ExecutionPlan? executionPlan,
    bool clearExecutionPlan = false,
    TaskNotification? notification,
    DateTime? lastRun,
    DateTime? nextRun,
  }) {
    return Agent(
      id: id,
      name: name ?? this.name,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      prompt: prompt ?? this.prompt,
      llmConfig: clearLlmConfig ? null : (llmConfig ?? this.llmConfig),
      mcpTools: mcpTools ?? this.mcpTools,
      internalMcps: internalMcps ?? this.internalMcps,
      chatMode: chatMode ?? this.chatMode,
      stopAfterToolCall: stopAfterToolCall ?? this.stopAfterToolCall,
      executionPlan: clearExecutionPlan ? null : (executionPlan ?? this.executionPlan),
      notification: notification ?? this.notification,
      lastRun: lastRun ?? this.lastRun,
      nextRun: nextRun ?? this.nextRun,
    );
  }
}

class Edge {
  final String id;
  final String sourceAgentId;
  final String variable;
  final String operator;
  final String value;
  final String targetAgentId;

  String get sourceExecutorId => sourceAgentId;
  String get targetExecutorId => targetAgentId;

  const Edge({
    required this.id,
    String? sourceAgentId,
    String? sourceExecutorId,
    required this.variable,
    required this.operator,
    required this.value,
    String? targetAgentId,
    String? targetExecutorId,
  }) : sourceAgentId = sourceAgentId ?? sourceExecutorId ?? '',
       targetAgentId = targetAgentId ?? targetExecutorId ?? '';

  Map<String, dynamic> toJson() => {
        'id': id,
        'source_agent_id': sourceAgentId,
        'variable': variable,
        'operator': operator,
        'value': value,
        'target_agent_id': targetAgentId,
      };

  factory Edge.fromJson(Map<String, dynamic> json) => Edge(
        id: json['id'] as String,
        sourceAgentId: (json['source_agent_id'] ?? json['source_executor_id']) as String,
        variable: json['variable'] as String,
        operator: json['operator'] as String,
        value: json['value'] as String,
        targetAgentId: (json['target_agent_id'] ?? json['target_executor_id']) as String,
      );

  Edge copyWith({
    String? sourceAgentId,
    String? variable,
    String? operator,
    String? value,
    String? targetAgentId,
  }) {
    return Edge(
      id: id,
      sourceAgentId: sourceAgentId ?? this.sourceAgentId,
      variable: variable ?? this.variable,
      operator: operator ?? this.operator,
      value: value ?? this.value,
      targetAgentId: targetAgentId ?? this.targetAgentId,
    );
  }
}

