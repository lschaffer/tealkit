import 'dart:io';

import 'package:flutter/foundation.dart';

import '../services/app_logger.dart';
import 'internal_mcp_server.dart';
import 'servers/document_mcp_server.dart';
import 'servers/file_mcp_server.dart';
import 'servers/gmail_mcp_server.dart';
import 'servers/google_calendar_mcp_server.dart';
import 'servers/imap_mcp_server.dart';
import 'servers/google_drive_mcp_server.dart';
import 'servers/pdf_mcp_server.dart';
import 'servers/chart_mcp_server.dart';
import 'servers/excel_mcp_server.dart';
import 'servers/mermaid_mcp_server.dart';
import 'servers/toolbox_mcp_server.dart';
import 'servers/weather_mcp_server.dart';
import 'servers/web_search_mcp_server.dart';
import 'servers/js_bridge_mcp_server.dart';
import 'servers/py_bridge_mcp_server.dart';
import 'servers/ps_bridge_mcp_server.dart';
import 'servers/local_shell_mcp_server.dart';
import 'servers/ssh_mcp_server.dart';
import 'servers/website_search_mcp_server.dart';
import 'servers/home_assistant_mcp_server.dart';
import 'servers/github_mcp_bridge_server.dart';
import '../services/github_mcp_library_service.dart';

/// Registry of all available internal MCP servers.
///
/// Provides:
///   • Discovery of available internal MCPs
///   • Factory creation of MCP server instances
///   • Metadata for UI display (names, descriptions, schemas)
class InternalMcpRegistry {
  // ── Singleton ──
  static final InternalMcpRegistry _instance = InternalMcpRegistry._internal();
  factory InternalMcpRegistry() => _instance;
  InternalMcpRegistry._internal() {
    _registerBuiltInServers();
  }

  /// Map of type → factory function
  final Map<String, InternalMcpServer Function()> _factories = {};

  /// Register all built-in MCP servers.
  void _registerBuiltInServers() {
    register('weather', () => WeatherMcpServer());
    register('document', () => DocumentMcpServer());
    register('gmail', () => GmailMcpServer());
    register('google_calendar', () => GoogleCalendarMcpServer());
    register('imap', () => ImapMcpServer());
    register('website_search', () => WebsiteSearchMcpServer());
    register('web_search', () => WebSearchMcpServer());
    register('google_drive', () => GoogleDriveMcpServer());
    register('toolbox', () => ToolboxMcpServer());
    register('pdf', () => PdfMcpServer());
    register('file', () => FileMcpServer());
    register('chart', () => ChartMcpServer());
    register('ssh', () => SshMcpServer());
    register('excel', () => ExcelMcpServer());
    register('home_assistant', () => HomeAssistantMcpServer());
    register('mermaid', () => MermaidMcpServer());
    register('js_bridge', () => JsBridgeMcpServer());

    // Desktop-only: Python tools bridge (Windows, macOS, Linux — never mobile/web)
    if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      register('py_bridge', () => PyBridgeMcpServer());
    }

    // Linux/macOS-only: local shell script execution
    if (!kIsWeb && (Platform.isLinux || Platform.isMacOS)) {
      register('local_shell', () => LocalShellMcpServer());
    }

    // Windows-only: PowerShell tools bridge
    if (!kIsWeb && Platform.isWindows) {
      register('ps_bridge', () => PsBridgeMcpServer());
    }

    log.info('[MCP Registry] Registered ${_factories.length} internal MCP servers: ${_factories.keys.join(', ')}');
  }

  /// Register all active GitHub MCP servers from the library.
  /// Call this after [GithubMcpLibraryService] has been loaded.
  void registerGithubMcpServers() {
    if (kIsWeb) return;
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) return;

    final active = GithubMcpLibraryService.instance.activeServers;
    for (final def in active) {
      final key = 'gh_mcp_${def.id}';
      if (!_factories.containsKey(key)) {
        register(key, () => GithubMcpBridgeServer(def));
        log.info('[MCP Registry] Registered GitHub MCP: $key (${def.displayName})');
      }
    }
  }

  /// Remove a previously registered GitHub MCP server by its definition id.
  void unregisterGithubMcpServer(String defId) {
    final key = 'gh_mcp_$defId';
    _factories.remove(key);
    log.info('[MCP Registry] Unregistered GitHub MCP: $key');
  }

  /// Register a new internal MCP server type.
  void register(String type, InternalMcpServer Function() factory) {
    _factories[type] = factory;
  }

  /// Get all available MCP server types.
  List<String> get availableTypes => _factories.keys.toList();

  /// Create a new instance of an internal MCP server by type.
  InternalMcpServer? create(String type) {
    final factory = _factories[type];
    if (factory == null) {
      log.warning('[MCP Registry] Unknown MCP type: $type');
      return null;
    }
    return factory();
  }

  /// Get metadata for all available internal MCP servers (for UI display).
  List<InternalMcpInfo> get availableServers {
    return _factories.entries.map((entry) {
      final server = entry.value();
      return InternalMcpInfo(
        type: server.type,
        displayName: server.displayName,
        description: server.description,
        iconName: server.iconName,
        initParamSchema: server.initParamSchema,
        defaultInitParams: server.defaultInitParams,
        defaultSystemPrompt: server.defaultSystemPrompt,
        toolCount: server.tools.length,
        toolNames: server.tools.map((t) => t.name).toList(),
      );
    }).toList();
  }

  /// Check if a type is registered.
  bool hasType(String type) => _factories.containsKey(type);
}

/// Read-only info about an available internal MCP server (for UI display).
class InternalMcpInfo {
  final String type;
  final String displayName;
  final String description;
  final String iconName;
  final Map<String, dynamic> initParamSchema;
  final Map<String, dynamic> defaultInitParams;
  final String defaultSystemPrompt;
  final int toolCount;
  final List<String> toolNames;

  const InternalMcpInfo({
    required this.type,
    required this.displayName,
    required this.description,
    required this.iconName,
    required this.initParamSchema,
    required this.defaultInitParams,
    required this.defaultSystemPrompt,
    required this.toolCount,
    required this.toolNames,
  });
}
