import 'dart:convert';

import 'package:uuid/uuid.dart';

/// Represents an MCP server sourced from the GitHub/community registry.
///
/// Supports two install strategies for Python servers (v1):
///   - **uvx**  : `uvx <packageName> [launchArgs]` — preferred (no explicit venv)
///   - **pip**  : creates `.venv`, `pip install <packageName>`, then
///                `<venv>/python -m <entryPoint> [launchArgs]`
///
/// Node.js support is deferred to v2.
///
/// Once installed the server is launched as a child process that speaks the
/// MCP stdio protocol (JSON-RPC 2.0, newline-delimited).
class GithubMcpServerDefinition {
  final String id;

  /// Package/repo name, e.g. `mcp-server-filesystem`.
  final String name;

  /// Human-readable label, e.g. "Filesystem".
  final String displayName;

  final String description;

  final String githubUrl;

  /// Language tag — `"python"` only in v1.
  final String language;

  /// How to install: `"uvx"` | `"pip"`.
  final String installType;

  /// PyPI package name used for `uvx install` or `pip install`.
  final String packageName;

  /// The module / entry-point to invoke, e.g. `mcp_server_filesystem`.
  /// - For **uvx**: this becomes the `uvx <entryPoint>` command.
  /// - For **pip**: this is passed as `python -m <entryPoint>`.
  /// If null, falls back to [packageName].
  final String? entryPoint;

  /// Additional command-line arguments appended after the entry-point.
  /// May contain placeholders like `{{allowed_dirs}}` that map to [envVars].
  final List<String> launchArgs;

  /// Environment-variable names that the server requires (e.g. `BRAVE_API_KEY`).
  final List<String> requiredEnvVars;

  /// User-configured values for [requiredEnvVars] (and any extra args).
  /// Stored encrypted in DuckDB.
  final Map<String, String> envVars;

  /// UI category tag for filtering (e.g. "files", "databases", "web").
  final String category;

  /// Whether the server is installed locally.
  final bool isInstalled;

  /// Whether the server is enabled and will be registered with the MCP manager.
  final bool isActive;

  /// True when the server was added via the "Install Manually" dialog and is
  /// therefore shown in the My Servers tab. Registry-installed servers
  /// (GitHub, Glama, Smithery …) have this set to false.
  final bool isManual;

  final DateTime? installedAt;
  final DateTime createdAt;

  const GithubMcpServerDefinition({
    required this.id,
    required this.name,
    required this.displayName,
    required this.description,
    required this.githubUrl,
    required this.language,
    required this.installType,
    required this.packageName,
    this.entryPoint,
    this.launchArgs = const [],
    this.requiredEnvVars = const [],
    this.envVars = const {},
    this.category = 'other',
    this.isInstalled = false,
    this.isActive = false,
    this.isManual = false,
    this.installedAt,
    required this.createdAt,
  });

  /// Create a new definition from a registry entry (not yet installed).
  factory GithubMcpServerDefinition.fromRegistryEntry(Map<String, dynamic> json) {
    return GithubMcpServerDefinition(
      id: const Uuid().v4(),
      name: json['name'] as String,
      displayName: json['displayName'] as String? ?? json['name'] as String,
      description: json['description'] as String? ?? '',
      githubUrl: json['githubUrl'] as String? ?? '',
      language: json['language'] as String? ?? 'python',
      installType: json['installType'] as String? ?? 'uvx',
      packageName: json['packageName'] as String,
      entryPoint: json['entryPoint'] as String?,
      launchArgs: _parseStringList(json['launchArgs']),
      requiredEnvVars: _parseStringList(json['requiredEnvVars']),
      envVars: {},
      category: json['category'] as String? ?? 'other',
      isInstalled: false,
      isActive: false,
      installedAt: null,
      createdAt: DateTime.now(),
    );
  }

  static List<String> _parseStringList(dynamic raw) {
    if (raw == null) return [];
    if (raw is List) return raw.map((e) => e.toString()).toList();
    if (raw is String && raw.trim().isNotEmpty) return jsonDecode(raw) as List<String>;
    return [];
  }

  GithubMcpServerDefinition copyWith({
    String? displayName,
    String? description,
    List<String>? launchArgs,
    List<String>? requiredEnvVars,
    Map<String, String>? envVars,
    String? category,
    bool? isInstalled,
    bool? isActive,
    bool? isManual,
    DateTime? installedAt,
  }) {
    return GithubMcpServerDefinition(
      id: id,
      name: name,
      displayName: displayName ?? this.displayName,
      description: description ?? this.description,
      githubUrl: githubUrl,
      language: language,
      installType: installType,
      packageName: packageName,
      entryPoint: entryPoint,
      launchArgs: launchArgs ?? this.launchArgs,
      requiredEnvVars: requiredEnvVars ?? this.requiredEnvVars,
      envVars: envVars ?? this.envVars,
      category: category ?? this.category,
      isInstalled: isInstalled ?? this.isInstalled,
      isActive: isActive ?? this.isActive,
      isManual: isManual ?? this.isManual,
      installedAt: installedAt ?? this.installedAt,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'displayName': displayName,
    'description': description,
    'githubUrl': githubUrl,
    'language': language,
    'installType': installType,
    'packageName': packageName,
    'entryPoint': entryPoint,
    'launchArgs': launchArgs,
    'requiredEnvVars': requiredEnvVars,
    'envVars': envVars,
    'category': category,
    'isInstalled': isInstalled,
    'isActive': isActive,
    'isManual': isManual,
    'installedAt': installedAt?.toIso8601String(),
    'createdAt': createdAt.toIso8601String(),
  };

  factory GithubMcpServerDefinition.fromJson(Map<String, dynamic> json) {
    return GithubMcpServerDefinition(
      id: json['id'] as String,
      name: json['name'] as String,
      displayName: json['displayName'] as String? ?? json['name'] as String,
      description: json['description'] as String? ?? '',
      githubUrl: json['githubUrl'] as String? ?? '',
      language: json['language'] as String? ?? 'python',
      installType: json['installType'] as String? ?? 'uvx',
      packageName: json['packageName'] as String,
      entryPoint: json['entryPoint'] as String?,
      launchArgs: _parseStringList(json['launchArgs']),
      requiredEnvVars: _parseStringList(json['requiredEnvVars']),
      envVars: _parseStringMap(json['envVars']),
      category: json['category'] as String? ?? 'other',
      isInstalled: json['isInstalled'] as bool? ?? false,
      isActive: json['isActive'] as bool? ?? false,
      isManual: json['isManual'] as bool? ?? false,
      installedAt: json['installedAt'] != null ? DateTime.tryParse(json['installedAt'] as String) : null,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
    );
  }

  static Map<String, String> _parseStringMap(dynamic raw) {
    if (raw == null) return {};
    if (raw is Map<String, String>) return raw;
    if (raw is Map) return Map<String, String>.from(raw.map((k, v) => MapEntry(k.toString(), v.toString())));
    if (raw is String && raw.trim().isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, String>.from(decoded.map((k, v) => MapEntry(k.toString(), v.toString())));
    }
    return {};
  }

  /// The effective entry-point command (falls back to packageName).
  String get effectiveEntryPoint => entryPoint ?? packageName;
}
