import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:dart_mcp_core/dart_mcp_core.dart';
import '../mcp/internal_mcp_registry.dart';
import '../mcp/internal_server_local_tool.dart';
import '../services/app_logger.dart';
import '../services/data_sources_settings_service.dart';

/// Helper that builds and aggregates all local Dart tools available in TealKit:
/// - 10-tool autonomous CodingTools suite (bound to a workspace directory)
/// - Document search MCP (DuckDB vector index)
/// - Web-crawl MCP (DuckDB web index)
/// - Desktop bridge tools (Python, JS, PowerShell, Local shell)
/// - Utilities (Weather, Chart, Mermaid, Toolbox, SSH)
class TealKitToolsBuilder {
  static List<McpLocalTool> buildAllTools({String? workspaceDirectory}) {
    final tools = <McpLocalTool>[];
    final addedNames = <String>{};

    void addTool(McpLocalTool tool) {
      if (!addedNames.contains(tool.name)) {
        tools.add(tool);
        addedNames.add(tool.name);
      }
    }

    void addServerTools(String serverType, {Map<String, dynamic>? initParams}) {
      try {
        final server = InternalMcpRegistry().create(serverType);
        if (server != null) {
          if (initParams != null && initParams.isNotEmpty) {
            server.initialize(initParams);
          }
          final serverTools = InternalServerLocalTool.adaptServer(server);
          for (final t in serverTools) {
            addTool(t);
          }
        }
      } catch (e) {
        log.warning('[TealKitToolsBuilder] Error adapting server $serverType: $e');
      }
    }

    // 1. Coding Tools Suite (10 tools) - Desktop only (Windows, macOS, Linux)
    if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      try {
        final codingTools = CodingTools.createAll(
          workingDirectory: workspaceDirectory ?? Directory.current.path,
        );
        for (final t in codingTools) {
          addTool(t);
        }
      } catch (e) {
        log.warning('[TealKitToolsBuilder] Could not register CodingTools: $e');
      }
    }

    // 2. Core Local RAG Servers
    final docPaths = DataSourcesSettingsService.instance.documentRootPaths.trim();
    addServerTools(
      'document',
      initParams: docPaths.isNotEmpty
          ? {'rootPath': docPaths, 'indexingStrategy': 'before_first_run'}
          : null,
    );
    final webUrls = DataSourcesSettingsService.instance.websiteIndexUrls.trim();
    addServerTools(
      'website_search',
      initParams: webUrls.isNotEmpty
          ? {'websiteUrls': webUrls, 'indexingStrategy': 'before_first_run'}
          : null,
    );

    // 3. Desktop Script Bridges
    if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      addServerTools('py_bridge');
      addServerTools('js_bridge');
      if (Platform.isWindows) {
        addServerTools('ps_bridge');
      }
      addServerTools('local_shell');
    }

    // 4. Productivity & Media Utilities
    addServerTools('chart');
    addServerTools('mermaid');
    addServerTools('toolbox');
    addServerTools('web_search');
    addServerTools('fetch');
    addServerTools('weather');
    addServerTools('ssh');
    addServerTools('excel');
    addServerTools('file');
    addServerTools('gmail');
    addServerTools('google_calendar');
    addServerTools('google_drive');

    log.info('[TealKitToolsBuilder] Initialized ${tools.length} local tools');
    return tools;
  }
}
