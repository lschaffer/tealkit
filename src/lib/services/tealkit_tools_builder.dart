import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:dart_mcp_core/dart_mcp_core.dart';
import 'package:tealkit_api/tealkit_api.dart';
import '../mcp/internal_mcp_registry.dart';
import '../mcp/internal_server_local_tool.dart';
import '../mcp/remote_coding_tool.dart';
import '../services/app_logger.dart';
import '../services/data_sources_settings_service.dart';

/// Helper that builds and aggregates all local Dart tools available in TealKit:
/// - 10-tool autonomous CodingTools suite (local on desktop, or remote via TealKit Server on mobile)
/// - Document search MCP (SQLite vector + FTS5 index)
/// - Web-crawl MCP (SQLite web index)
/// - Desktop bridge tools (Python, JS, PowerShell, Local shell)
/// - Built-in AI Image Generator (`generate_image`) & GitHub REST API (`github_*`)
/// - Utilities (Weather, Chart, Mermaid, Toolbox, SSH)
class TealKitToolsBuilder {
  static List<McpLocalTool> buildAllTools({
    String? workspaceDirectory,
    ServerApiClient? serverClient,
  }) {
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

    final isDesktop =
        !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

    // 1. Coding Tools Suite (10 tools)
    // - Desktop: local workspace filesystem & terminal
    // - Mobile in Server Mode: sandboxed remote server coding tools rooted at server files_dir
    if (isDesktop) {
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
    } else if (serverClient != null) {
      try {
        final remoteCodingTools = RemoteCodingTool.createAll(
          serverClient: serverClient,
          workspaceDirectory: workspaceDirectory ?? '',
        );
        for (final t in remoteCodingTools) {
          addTool(t);
        }
      } catch (e) {
        log.warning('[TealKitToolsBuilder] Could not register RemoteCodingTools: $e');
      }
    }

    // 1b. Built-in AI Image Generator (Dart-native GenerateImageTool from dart_mcp_core)
    addTool(GenerateImageTool());

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
    if (isDesktop) {
      addServerTools('py_bridge');
      addServerTools('js_bridge');
      if (Platform.isWindows) {
        addServerTools('ps_bridge');
      }
      addServerTools('local_shell');
    }

    // 4. Productivity & Media Utilities
    addServerTools('github');
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
