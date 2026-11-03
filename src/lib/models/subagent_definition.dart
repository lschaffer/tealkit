/// Subagent definition model for specialized sub-agents used by DelegateTaskTool.
class SubAgentDefinition {
  final String key;
  final String name;
  final String description;
  final String model;
  final String systemPrompt;
  final List<String> tools;
  final int maxTurns;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const SubAgentDefinition({
    required this.key,
    this.name = '',
    this.description = '',
    this.model = 'default',
    this.systemPrompt = '',
    this.tools = const [],
    this.maxTurns = 8,
    this.createdAt,
    this.updatedAt,
  });

  String get displayName => name.trim().isNotEmpty ? name : key;

  Map<String, dynamic> toJson() => {
        'key': key,
        'name': name,
        'description': description,
        'model': model,
        'system_prompt': systemPrompt,
        'tools': tools,
        'max_turns': maxTurns,
        'created_at': createdAt?.toIso8601String(),
        'updated_at': updatedAt?.toIso8601String(),
      };

  factory SubAgentDefinition.fromJson(Map<String, dynamic> json) {
    final rawTools = json['tools'];
    List<String> toolsList = const [];
    if (rawTools is List) {
      toolsList = rawTools.map((e) => e.toString().trim()).where((s) => s.isNotEmpty).toList();
    }

    final maxTurnsVal = json['max_turns'] ?? json['maxTurns'];
    final parsedMaxTurns = maxTurnsVal is int
        ? maxTurnsVal
        : int.tryParse(maxTurnsVal?.toString() ?? '8') ?? 8;

    return SubAgentDefinition(
      key: (json['key'] ?? '').toString().trim(),
      name: (json['name'] ?? '').toString().trim(),
      description: (json['description'] ?? '').toString().trim(),
      model: (json['model'] ?? 'default').toString().trim(),
      systemPrompt: (json['system_prompt'] ?? json['systemPrompt'] ?? '').toString(),
      tools: toolsList,
      maxTurns: parsedMaxTurns,
      createdAt: json['created_at'] != null ? DateTime.tryParse(json['created_at'].toString()) : null,
      updatedAt: json['updated_at'] != null ? DateTime.tryParse(json['updated_at'].toString()) : null,
    );
  }

  SubAgentDefinition copyWith({
    String? key,
    String? name,
    String? description,
    String? model,
    String? systemPrompt,
    List<String>? tools,
    int? maxTurns,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return SubAgentDefinition(
      key: key ?? this.key,
      name: name ?? this.name,
      description: description ?? this.description,
      model: model ?? this.model,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      tools: tools ?? this.tools,
      maxTurns: maxTurns ?? this.maxTurns,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// Inbuilt predefined sub-agents from ThiesCoder / TealKit.
  static const List<SubAgentDefinition> predefined = [
    SubAgentDefinition(
      key: 'unit_tester',
      name: 'Automated Unit Test Specialist',
      description: 'Automated unit test specialist: generates, updates, and executes test suites',
      model: 'default',
      systemPrompt: '''You are an expert test engineer and QA specialist.
Your task is to analyze code, write robust and comprehensive unit tests (covering happy paths, edge cases, and failure modes), and execute them to verify test suite health.
Follow standard test frameworks for the target project (e.g. xUnit for .NET, pytest for Python, test/flutter_test for Dart).
Always execute the test runner via terminal to verify all tests pass before completing.''',
      tools: ['fs_read_file', 'fs_replace_text', 'fs_write_file', 'terminal_exec', 'fs_list_dir'],
      maxTurns: 10,
    ),
    SubAgentDefinition(
      key: 'git_auditor',
      name: 'Git Status, Diff & Commit Auditor',
      description: 'Git repository auditor: inspects status, diffs, branch health, and formats commits',
      model: 'default',
      systemPrompt: '''You are an expert Git and version control auditor.
Your job is to inspect git status, review branch diffs, detect untracked or dangling files, ensure working tree hygiene, and prepare clean, conventional commit messages.
Never force-push or destroy uncommitted work.
Report a clean breakdown of modified, added, and deleted files with recommendations.''',
      tools: ['terminal_exec', 'fs_read_file', 'fs_list_dir'],
      maxTurns: 6,
    ),
    SubAgentDefinition(
      key: 'web_search',
      name: 'Web Search Specialist',
      description: 'Autonomous web search specialist: queries online documentation, APIs, and web results',
      model: 'default',
      systemPrompt: '''You are a specialized web research assistant.
Your task is to search the web for relevant information, answer queries, verify facts, and synthesize online results.
Provide concise, accurate answers with citations and links.''',
      tools: ['web_search'],
      maxTurns: 8,
    ),
    SubAgentDefinition(
      key: 'web_researcher',
      name: 'Technical Web Researcher',
      description: 'Technical web researcher: queries online documentation, APIs, and release notes',
      model: 'default',
      systemPrompt: '''You are a specialized technical documentation and web researcher.
Your task is to search the web for API documentation, libraries, release notes, and solutions to technical errors or deprecations.
Synthesize your findings concisely with direct links, code snippets, and citations.''',
      tools: ['web_search', 'fs_read_file'],
      maxTurns: 8,
    ),
    SubAgentDefinition(
      key: 'code_scout',
      name: 'Fast Codebase Explorer & Architecture Scout',
      description: 'Fast codebase explorer and caller hierarchy / symbol scout',
      systemPrompt: '''You are a specialized codebase exploration and symbol search agent.
Your objective is to quickly locate symbols, caller hierarchies, interface implementations, and architectural structure without modifying any code.
Return concise, structured findings with exact file paths and line numbers.''',
      tools: ['fs_find', 'fs_read_file', 'fs_list_dir'],
      maxTurns: 8,
    ),
    SubAgentDefinition(
      key: 'c_analyzer',
      name: 'Embedded C/C++ Firmware & Warning Specialist',
      description: 'C/C++ firmware static analyzer and compiler warning expert',
      systemPrompt: '''You are an expert embedded C/C++ systems engineer.
Analyze source files and header files for compiler warnings, buffer overflows,
pointer safety, signed/unsigned mismatches, and missing NULL checks.
Be concise: return only file paths, line numbers, and actionable fixes.''',
      tools: ['fs_read_file', 'fs_find', 'fs_list_dir'],
      maxTurns: 8,
    ),
  ];
}

