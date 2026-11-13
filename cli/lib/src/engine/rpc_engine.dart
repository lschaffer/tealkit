import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp_core/dart_mcp_core.dart';
import 'package:path/path.dart' as p;

import '../commands/code_command.dart';
import '../config/cli_config.dart';
import '../config/global_config.dart';
import '../config/llm_config_manager.dart';
import '../config/permission_settings.dart';
import '../config/server_config.dart';
import 'package:tealkit_api/tealkit_api.dart' hide ChatMessage, MCPTool, Agent, ChatRole;
import '../engine/builtin_mcp_servers.dart';
import '../engine/embedded/cli_embedded_llm_adapter.dart';
import '../engine/embedded/cli_embedded_model_manager.dart';
import '../engine/session_manager.dart';
import '../engine/skill_runner.dart';
import '../engine/subagent_helper.dart';
import '../engine/token_usage_tracker.dart';
import '../rag/rag_service.dart';

/// Headless JSON-RPC / NDJSON engine for IDE plugins (VS Code, Antigravity).
///
/// Communicates over stdio:
/// - Inbound (`stdin`): Line-delimited JSON commands.
/// - Outbound (`stdout`): Line-delimited JSON events.
/// - Diagnostics (`stderr`): Log and error messages.
class TealKitRpcEngine {
  final String workspaceDir;
  final String? customConfigPath;
  final String? customInstructionsPath;
  final String llmPath;
  final String? initialLlmName;
  final String toolsPath;
  CodingMode currentMode;
  final String? saveSessionPath;
  final String? loadSessionPath;
  final bool continueSession;
  final bool autoSaveSession;

  McpAgentEngine? _activeEngine;
  bool _isTurnActive = false;
  final Map<String, Completer<bool>> _pendingPermissions = {};
  final Map<String, ({String rawTool, String effectiveTool, ToolRiskLevel risk})> _pendingPermissionMeta = {};
  final Set<String> _alwaysApprovedTools = {};
  final Set<String> _attachedSkills = {};
  int _sessionTurnCounter = 0;
  String _activeSessionId = 'session_${DateTime.now().millisecondsSinceEpoch}';
  DateTime _activeSessionCreatedAt = DateTime.now();
  String _activeSessionTitle = 'TealKit Coding Session';
  String? _activeSessionFilePath;

  TealKitRpcEngine({
    required this.workspaceDir,
    this.customConfigPath,
    this.customInstructionsPath,
    this.llmPath = 'llm.yaml',
    this.initialLlmName,
    this.toolsPath = 'extern_mcp_tools.yaml',
    this.currentMode = CodingMode.code,
    this.saveSessionPath,
    this.loadSessionPath,
    this.continueSession = false,
    this.autoSaveSession = true,
  });

  void _sendEvent(String eventName, Map<String, dynamic> data) {
    try {
      final payload = jsonEncode(
        {'event': eventName, ...data},
        toEncodable: (nonEncodable) => nonEncodable.toString(),
      );
      stdout.writeln(payload);
    } catch (e) {
      stderr.writeln('[TealKit-RPC] Failed to encode event $eventName: $e');
    }
  }

  void _cancelPendingPermissions() {
    for (final completer in _pendingPermissions.values) {
      if (!completer.isCompleted) {
        completer.complete(false);
      }
    }
    _pendingPermissions.clear();
    _pendingPermissionMeta.clear();
  }

  bool _isRagConfigured(CliConfig cfg) {
    return cfg.rag.enabled &&
        (cfg.rag.folderSources.isNotEmpty || cfg.rag.webSources.isNotEmpty);
  }

  ({String effectiveTool, ToolRiskLevel risk, Map<String, dynamic> effectiveParams}) _resolveEffectiveToolAndRisk(
    String toolName,
    Map<String, dynamic> parameters,
    ToolRiskLevel defaultRisk,
    List<McpLocalTool> dartTools,
  ) {
    if (toolName == 'mcp_list_tools') {
      return (
        effectiveTool: 'mcp_list_tools',
        risk: ToolRiskLevel.read,
        effectiveParams: parameters,
      );
    }

    String effectiveName = toolName;
    Map<String, dynamic> effectiveParams = parameters;
    if (toolName == 'mcp_call_tool') {
      final innerName = (parameters['tool_name'] ?? parameters['name'] ?? '').toString().trim();
      if (innerName.isNotEmpty) {
        effectiveName = innerName;
      }
      final innerArgs = parameters['arguments'];
      if (innerArgs is Map) {
        effectiveParams = Map<String, dynamic>.from(innerArgs);
      }
    }

    for (final t in dartTools) {
      if (t.name == effectiveName) {
        return (
          effectiveTool: effectiveName,
          risk: t.riskLevel,
          effectiveParams: effectiveParams,
        );
      }
    }

    const readTools = {
      'fs_read_file',
      'fs_list_dir',
      'fs_find',
      'get_current_time',
      'get_timezone_info',
      'calculate',
      'sum_numbers',
      'search_documents',
      'get_document_content',
      'list_documents',
      'search_indexed_websites',
      'get_indexed_page',
      'list_indexed_pages',
      'recall_memory',
      'activate_skills',
      'deactivate_skills',
    };
    const writeTools = {
      'fs_write_file',
      'fs_replace_text',
      'fs_create_dir',
      'fs_move',
      'fs_delete',
      'store_memory',
      'create_mermaid_png',
    };
    const execTools = {
      'terminal_exec',
      'execute_command',
      'git_commit',
      'ssh_execute_command',
      'ssh_upload_file',
    };

    if (readTools.contains(effectiveName)) {
      return (effectiveTool: effectiveName, risk: ToolRiskLevel.read, effectiveParams: effectiveParams);
    }
    if (writeTools.contains(effectiveName)) {
      return (effectiveTool: effectiveName, risk: ToolRiskLevel.write, effectiveParams: effectiveParams);
    }
    if (execTools.contains(effectiveName)) {
      return (effectiveTool: effectiveName, risk: ToolRiskLevel.execute, effectiveParams: effectiveParams);
    }

    return (effectiveTool: effectiveName, risk: defaultRisk, effectiveParams: effectiveParams);
  }

  void _log(String message) {
    stderr.writeln('[TealKit-RPC] $message');
  }

  Future<void> run() async {
    _log('Initializing TealKit RPC engine for workspace: $workspaceDir');

    // 1. Load configurations
    final runner = SkillRunner(
      llmConfigPath: llmPath,
      toolsConfigPath: toolsPath,
      verbose: false,
    );

    final allProfiles = LlmConfigManager.loadAllProfiles(configPath: llmPath);
    String activeLlmName = initialLlmName ?? 'default';
    LlmConfig activeLlmConfig = runner.loadLlmConfig(
      targetName: initialLlmName,
    );

    NamedLlmProfile? activeProfile;
    for (final p in allProfiles) {
      if (p.config.model == activeLlmConfig.model &&
          p.config.provider == activeLlmConfig.provider) {
        activeLlmName = p.name;
        activeProfile = p;
        break;
      }
    }

    if (activeProfile != null &&
        activeProfile.config.provider == LlmProvider.embedded) {
      try {
        final filename = activeProfile.config.model;
        final manager = CliEmbeddedModelManager.instance;
        final isDownloaded = await manager.isModelDownloaded(filename);
        if (isDownloaded) {
          final file = await manager.getModelFile(filename);
          await CliEmbeddedLlmAdapter.instance.initialize(
            file.path,
            gpuLayers: activeProfile.gpuLayers ?? 0,
            contextSize: activeProfile.contextSize ?? 4096,
          );
          CliEmbeddedLlmAdapter.instance.registerWithMcpCore();
        }
      } catch (e) {
        _log('Embedded model initialization note: $e');
      }
    }

    var permissions = ToolPermissionSettings.load();
    var cliConfig = CliConfig.load();

    // 2. Initialize native tools bound to the workspace directory
    final builtinTools = BuiltinMcpServers.createAll();
    final allDartTools = [
      ...CodingTools.createAll(workingDirectory: workspaceDir),
      ...builtinTools,
    ];
    final dartTools = List<McpLocalTool>.from(allDartTools);

    // 3. Connect External MCP servers if configured
    var localServers = runner.loadMcpServers();
    var mcpManager = await runner.connectMcpServers(localServers, silent: true);
    var mcpTools = mcpManager.availableTools;

    final history = <ChatMessage>[];
    final episodicMemoryStore = EpisodicMemoryStore();
    final usageTracker = TokenUsageTracker();

    // Load initial or most recent session if requested
    String? initialSessionToLoad = loadSessionPath;
    if (initialSessionToLoad == null && continueSession) {
      final lastFile = SessionManager.findLastSessionFile(workspaceDir: workspaceDir);
      if (lastFile != null) {
        initialSessionToLoad = lastFile.path;
      }
    }
    if (initialSessionToLoad != null && File(initialSessionToLoad).existsSync()) {
      try {
        final loaded = await SessionManager.loadSession(initialSessionToLoad);
        if (loaded.messages.isNotEmpty) {
          history.addAll(loaded.messages);
          _activeSessionId = loaded.id;
          _activeSessionCreatedAt = loaded.createdAt;
          _activeSessionTitle = loaded.title;
          _activeSessionFilePath = initialSessionToLoad;
          _log('Restored session from $initialSessionToLoad (${history.length} messages)');
        }
      } catch (e) {
        _log('Could not load initial session $initialSessionToLoad: $e');
      }
    }

    final resolvedLlmFile = GlobalConfigLocator.resolveConfigFile(llmPath);
    final resolvedMcpFile = GlobalConfigLocator.resolveConfigFile(toolsPath);

    // Send initial ready event
    _sendEvent('ready', {
      'version': '1.4.5',
      'workspace': workspaceDir,
      'mode': currentMode.name,
      'ragConfigured': _isRagConfigured(cliConfig),
      'model': activeLlmName,
      'provider': activeLlmConfig.provider.displayName,
      'modelId': activeLlmConfig.model,
      'toolsCount': dartTools.length + mcpTools.length,
      'llmConfigPath': resolvedLlmFile.path,
      'mcpConfigPath': resolvedMcpFile.path,
      'activeSkills': _attachedSkills.toList(),
      'sessionId': _activeSessionId,
      'sessionTitle': _activeSessionTitle,
      'sessionFilePath': _activeSessionFilePath,
      'isTurnActive': _isTurnActive,
      'history': _serializeHistoryForUi(history),
    });

    // 4. Listen on stdin for line-delimited JSON commands
    final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());

    await for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      Map<String, dynamic> request;
      try {
        request = jsonDecode(trimmed) as Map<String, dynamic>;
      } catch (e) {
        _sendEvent('error', {'message': 'Invalid JSON request: $e'});
        continue;
      }

      final action = request['action'] as String? ?? '';
      final requestId = request['id'] as String?;

      try {
        switch (action) {
          case 'ping':
            _sendEvent('pong', {
              'id': ?requestId,
              'time': DateTime.now().toIso8601String(),
            });

          case 'get_status':
            _sendEvent('status', {
              'id': ?requestId,
              'workspace': workspaceDir,
              'mode': currentMode.name,
              'ragConfigured': _isRagConfigured(cliConfig),
              'model': activeLlmName,
              'provider': activeLlmConfig.provider.displayName,
              'modelId': activeLlmConfig.model,
              'toolsCount': dartTools.length + mcpTools.length,
              'autoApproveRead': permissions.autoApproveRead,
              'autoApproveWrite': permissions.autoApproveWrite,
              'autoApproveExecute': permissions.autoApproveExecute,
              'autoApproveNetwork': permissions.autoApproveNetwork,
              'llmConfigPath': resolvedLlmFile.path,
              'mcpConfigPath': resolvedMcpFile.path,
            });

          case 'get_config':
            _sendEvent('config_data', {
              'id': ?requestId,
              'llmPath': resolvedLlmFile.path,
              'mcpPath': resolvedMcpFile.path,
              'llmContent': resolvedLlmFile.existsSync() ? resolvedLlmFile.readAsStringSync() : '',
              'mcpContent': resolvedMcpFile.existsSync() ? resolvedMcpFile.readAsStringSync() : '',
            });

          case 'reload_config':
            try {
              cliConfig = CliConfig.load();
              permissions = ToolPermissionSettings.load();
              if (currentMode == CodingMode.rag && !_isRagConfigured(cliConfig)) {
                currentMode = CodingMode.code;
              }
              _sendEvent('config_reloaded', {
                'id': ?requestId,
                'compressionThreshold': cliConfig.contextCompressionThreshold,
                'maxToolIterations': cliConfig.maxToolIterations,
                'enablePlanning': cliConfig.enablePlanning,
                'compactTools': cliConfig.compactTools,
                'ragConfigured': _isRagConfigured(cliConfig),
                'mode': currentMode.name,
              });
            } catch (e) {
              _sendEvent('error', {'id': ?requestId, 'message': 'Failed to reload config.yaml: $e'});
            }

          case 'reload_mcp':
            try {
              localServers = runner.loadMcpServers();
              mcpManager = await runner.connectMcpServers(localServers, silent: true);
              mcpTools = mcpManager.availableTools;
              _sendEvent('status', {
                'id': ?requestId,
                'workspace': workspaceDir,
                'mode': currentMode.name,
                'model': activeLlmName,
                'provider': activeLlmConfig.provider.displayName,
                'modelId': activeLlmConfig.model,
                'toolsCount': dartTools.length + mcpTools.length,
                'autoApproveWrite': permissions.autoApproveWrite,
                'autoApproveExecute': permissions.autoApproveExecute,
                'llmConfigPath': resolvedLlmFile.path,
                'mcpConfigPath': resolvedMcpFile.path,
              });
            } catch (e) {
              _sendEvent('error', {'id': ?requestId, 'message': 'Failed to reload MCP servers: $e'});
            }

          case 'save_llm_config':
            final content = request['content'] as String?;
            final targetPath = request['path'] as String? ?? resolvedLlmFile.path;
            if (content != null) {
              final f = File(targetPath);
              f.parent.createSync(recursive: true);
              f.writeAsStringSync(content);
              try {
                allProfiles.clear();
                allProfiles.addAll(LlmConfigManager.loadAllProfiles(configPath: llmPath));
              } catch (_) {}
              _sendEvent('llm_config_saved', {
                'id': ?requestId,
                'path': targetPath,
                'models': allProfiles.map((p) => {
                  'name': p.name,
                  'provider': p.config.provider.displayName,
                  'model': p.config.model,
                  'isDefault': p.name == activeLlmName,
                }).toList(),
              });
            }

          case 'save_mcp_config':
            final content = request['content'] as String?;
            final targetPath = request['path'] as String? ?? resolvedMcpFile.path;
            if (content != null) {
              final f = File(targetPath);
              f.parent.createSync(recursive: true);
              f.writeAsStringSync(content);
              try {
                localServers = runner.loadMcpServers();
                mcpManager = await runner.connectMcpServers(localServers, silent: true);
                mcpTools = mcpManager.availableTools;
              } catch (_) {}
              _sendEvent('mcp_config_saved', {
                'id': ?requestId,
                'path': targetPath,
                'toolsCount': dartTools.length + mcpTools.length,
              });
            }

          case 'list_models':
            try {
              allProfiles.clear();
              allProfiles.addAll(LlmConfigManager.loadAllProfiles(configPath: llmPath));
              for (final p in allProfiles) {
                if (p.name == activeLlmName) {
                  activeLlmConfig = p.config;
                  break;
                }
              }
            } catch (_) {}

            final profilesList = await Future.wait(allProfiles.map((p) async {
              final isCurrent = (p.name == activeLlmName);
              final rates = await TokenUsageTracker.getRatesAsync(p.config);
              final badgeParts = <String>[];
              if (rates?.contextWindow != null) {
                badgeParts.add(TokenUsageTracker.formatContextWindow(rates!.contextWindow));
              }
              if (rates != null && rates.inputPerM == 0.0 && rates.outputPerM == 0.0) {
                badgeParts.add('Free');
              } else if (rates != null && (rates.inputPerM > 0 || rates.outputPerM > 0)) {
                badgeParts.add('\$${rates.inputPerM.toStringAsFixed(2)}/\$${rates.outputPerM.toStringAsFixed(2)}');
              }
              final ctxAndPricing = badgeParts.isNotEmpty ? badgeParts.join(' \u2022 ') : null;

              return {
                'name': p.name,
                'provider': p.config.provider.displayName,
                'model': p.config.model,
                'baseUrl': p.config.baseUrl,
                'isDefault': isCurrent,
                'temperature': p.config.temperature,
                'maxTokens': p.config.maxTokens,
                'contextWindow': rates?.contextWindow != null ? TokenUsageTracker.formatContextWindow(rates!.contextWindow) : null,
                'pricing': (rates != null && rates.inputPerM == 0.0 && rates.outputPerM == 0.0)
                    ? 'Free'
                    : (rates != null ? '\$${rates.inputPerM.toStringAsFixed(2)}/\$${rates.outputPerM.toStringAsFixed(2)}' : null),
                'ctxAndPricing': ctxAndPricing,
              };
            }));
            _sendEvent('models', {'id': ?requestId, 'models': profilesList});

          case 'set_model':
            final profileName = (request['model'] as String? ?? request['profile'] as String? ?? '').trim();
            if (profileName.isEmpty) break;
            try {
              final newConfig = runner.loadLlmConfig(targetName: profileName);
              activeLlmConfig = newConfig;
              activeLlmName = profileName;
              _sendEvent('model_changed', {
                'id': ?requestId,
                'profile': activeLlmName,
                'model': activeLlmName,
                'modelId': activeLlmConfig.model,
                'provider': activeLlmConfig.provider.displayName,
              });
            } catch (e) {
              _sendEvent('error', {
                'id': ?requestId,
                'message': 'Failed to switch model to $profileName: $e',
              });
            }

          case 'set_mode':
            final newModeStr = request['mode'] as String? ?? 'code';
            if (newModeStr == 'rag') {
              cliConfig = CliConfig.load();
              if (_isRagConfigured(cliConfig)) {
                currentMode = CodingMode.rag;
              } else {
                currentMode = CodingMode.code;
              }
            } else {
              currentMode = switch (newModeStr) {
                'architect' => CodingMode.architect,
                'ask' => CodingMode.ask,
                _ => CodingMode.code,
              };
            }
            _sendEvent('mode_changed', {
              'id': ?requestId,
              'mode': currentMode.name,
              'ragConfigured': _isRagConfigured(cliConfig),
            });

          case 'attach_skill':
            final skillName = (request['name'] ?? request['skill'])?.toString();
            if (skillName != null && skillName.isNotEmpty) {
              _attachedSkills.add(skillName);
              _sendEvent('skills_changed', {
                'id': ?requestId,
                'activeSkills': _attachedSkills.toList(),
                'attached': skillName,
              });
            }

          case 'detach_skill':
            final skillName = (request['name'] ?? request['skill'])?.toString();
            if (skillName != null) {
              _attachedSkills.remove(skillName);
              _sendEvent('skills_changed', {
                'id': ?requestId,
                'activeSkills': _attachedSkills.toList(),
                'detached': skillName,
              });
            }

          case 'list_skills':
            final skills = _discoverSkills(runner);
            for (final s in skills) {
              s['isAttached'] = _attachedSkills.contains(s['name']);
            }
            _sendEvent('skills', {
              'id': ?requestId,
              'skills': skills,
              'activeSkills': _attachedSkills.toList(),
            });

          case 'archive_memory':
            if (history.isNotEmpty) {
              final count = await _archiveMemorySnapshot(
                workspaceDir: workspaceDir,
                history: history,
              );
              _sendEvent('memory_archived', {
                'id': ?requestId,
                'turnCount': count,
                'timestamp': DateTime.now().toIso8601String(),
              });
            } else {
              _sendEvent('memory_archives', {
                'id': ?requestId,
                'archives': _listMemoryArchives(workspaceDir),
              });
            }

          case 'get_memory_archives':
            final archives = _listMemoryArchives(workspaceDir);
            _sendEvent('memory_archives', {
              'id': ?requestId,
              'archives': archives,
            });

          case 'get_server_config':
            final serverManager = ServerConfigManager();
            final profiles = serverManager.loadProfiles();
            final active = serverManager.getActiveProfile();
            _sendEvent('server_config', {
              'id': ?requestId,
              'configPath': serverManager.file.path,
              'activeProfile': active?.toMap(),
              'profiles': profiles.map((p) => p.toMap()).toList(),
            });

          case 'save_server_config':
            final profileMap = request['profile'] as Map<String, dynamic>?;
            if (profileMap != null) {
              final serverManager = ServerConfigManager();
              final newProfile = ServerProfile(
                name: profileMap['name'] as String? ?? 'Default',
                url: profileMap['url'] as String? ?? 'http://localhost:7771',
                apiKey: profileMap['apiKey'] as String? ?? profileMap['api_key'] as String? ?? '',
                isActive: profileMap['isActive'] as bool? ?? profileMap['is_active'] as bool? ?? true,
              );
              _saveServerProfile(serverManager, newProfile);
              final profiles = serverManager.loadProfiles();
              _sendEvent('server_config', {
                'id': ?requestId,
                'configPath': serverManager.file.path,
                'profiles': profiles.map((p) => p.toMap()).toList(),
              });
            }

          case 'list_workflows':
            try {
              final serverManager = ServerConfigManager();
              final profile = serverManager.getActiveProfile();
              if (profile == null) {
                _sendEvent('workflows', {
                  'id': ?requestId,
                  'workflows': [],
                  'error': 'No active server profile found in server.yaml',
                });
              } else {
                final client = ServerApiClient(
                  serverUrl: profile.url,
                  apiKey: profile.apiKey.isNotEmpty ? profile.apiKey : null,
                );
                final tasks = await client.getAllTasks();
                final wfList = tasks.map((t) => {
                  'id': t.id,
                  'name': t.name,
                  'enabled': t.enabled,
                  'agentsCount': t.agents.length,
                  'internalMcps': t.internalMcps.map((m) => m.mcpType).toList(),
                }).toList();
                _sendEvent('workflows', {
                  'id': ?requestId,
                  'workflows': wfList,
                  'serverUrl': profile.url,
                });
              }
            } catch (e) {
              _sendEvent('workflows', {
                'id': ?requestId,
                'workflows': [],
                'error': e.toString(),
              });
            }

          case 'run_workflow':
            try {
              final workflowId = (request['workflowId'] ?? request['id'])?.toString();
              if (workflowId == null) {
                _sendEvent('error', {'id': ?requestId, 'message': 'Workflow ID required.'});
              } else {
                final serverManager = ServerConfigManager();
                final profile = serverManager.getActiveProfile();
                if (profile == null) throw StateError('No active server profile.');
                final client = ServerApiClient(
                  serverUrl: profile.url,
                  apiKey: profile.apiKey.isNotEmpty ? profile.apiKey : null,
                );
                final runId = await client.runTask(workflowId);
                _sendEvent('workflow_run_started', {
                  'id': ?requestId,
                  'workflowId': workflowId,
                  'runId': runId,
                });
              }
            } catch (e) {
              _sendEvent('error', {'id': ?requestId, 'message': 'Failed to run workflow: $e'});
            }

          case 'get_workflow_status':
            try {
              final workflowId = (request['workflowId'] ?? request['id'])?.toString();
              if (workflowId == null) {
                _sendEvent('error', {'id': ?requestId, 'message': 'Workflow ID required.'});
              } else {
                final serverManager = ServerConfigManager();
                final profile = serverManager.getActiveProfile();
                if (profile == null) throw StateError('No active server profile.');
                final client = ServerApiClient(
                  serverUrl: profile.url,
                  apiKey: profile.apiKey.isNotEmpty ? profile.apiKey : null,
                );
                final running = await client.getTaskRunStatus(workflowId);
                Map<String, dynamic>? latestLog;
                if (!running) {
                  try {
                    final logsResp = await client.getTaskExecutionLogs(workflowId) ?? {};
                    final logsList = logsResp['logs'] ?? logsResp['executions'] ?? logsResp['items'];
                    if (logsList is List && logsList.isNotEmpty && logsList.first is Map) {
                      latestLog = Map<String, dynamic>.from(logsList.first as Map);
                    }
                  } catch (_) {}
                }
                _sendEvent('workflow_status', {
                  'id': ?requestId,
                  'workflowId': workflowId,
                  'running': running,
                  'latestLog': latestLog,
                });
              }
            } catch (e) {
              _sendEvent('workflow_status', {
                'id': ?requestId,
                'workflowId': (request['workflowId'] ?? request['id'])?.toString(),
                'running': false,
                'error': e.toString(),
              });
            }

          case 'get_workflow_logs':
            try {
              final workflowId = (request['workflowId'] ?? request['id'])?.toString();
              if (workflowId == null) {
                _sendEvent('error', {'id': ?requestId, 'message': 'Workflow ID required.'});
              } else {
                final serverManager = ServerConfigManager();
                final profile = serverManager.getActiveProfile();
                if (profile == null) throw StateError('No active server profile.');
                final client = ServerApiClient(
                  serverUrl: profile.url,
                  apiKey: profile.apiKey.isNotEmpty ? profile.apiKey : null,
                );
                Map<String, dynamic> logsResp = {};
                Map<String, dynamic> outputResp = {};
                bool running = false;
                try {
                  running = await client.getTaskRunStatus(workflowId);
                } catch (_) {}
                try {
                  logsResp = await client.getTaskExecutionLogs(workflowId) ?? {};
                } catch (e) {
                  logsResp = {'error': e.toString()};
                }
                try {
                  outputResp = await client.getTaskOutput(workflowId) ?? {};
                } catch (e) {
                  outputResp = {'error': e.toString()};
                }
                _sendEvent('workflow_logs', {
                  'id': ?requestId,
                  'workflowId': workflowId,
                  'running': running,
                  'logs': logsResp,
                  'output': outputResp,
                });
              }
            } catch (e) {
              _sendEvent('workflow_logs', {
                'id': ?requestId,
                'workflowId': (request['workflowId'] ?? request['id'])?.toString(),
                'error': e.toString(),
              });
            }

          case 'cancel_workflow':
            try {
              final workflowId = (request['workflowId'] ?? request['id'])?.toString();
              if (workflowId != null) {
                final serverManager = ServerConfigManager();
                final profile = serverManager.getActiveProfile();
                if (profile != null) {
                  final client = ServerApiClient(
                    serverUrl: profile.url,
                    apiKey: profile.apiKey.isNotEmpty ? profile.apiKey : null,
                  );
                  await client.cancelTask(workflowId);
                  _sendEvent('workflow_status', {
                    'id': ?requestId,
                    'workflowId': workflowId,
                    'running': false,
                    'cancelled': true,
                  });
                }
              }
            } catch (e) {
              _sendEvent('error', {'id': ?requestId, 'message': 'Failed to cancel workflow: $e'});
            }

          case 'list_mcp_tools':
            final toolsInfo = <Map<String, dynamic>>[];
            for (final t in dartTools) {
              toolsInfo.add({
                'name': t.name,
                'description': t.description,
                'isNative': true,
              });
            }
            for (final t in mcpTools) {
              toolsInfo.add({
                'name': t.name,
                'description': t.description,
                'isNative': false,
              });
            }
            _sendEvent('mcp_tools', {'id': ?requestId, 'tools': toolsInfo});

          case 'permission_response':
            final permReqId = (request['requestId'] ?? request['id'])?.toString();
            final allowed = (request['allowed'] ?? request['approved']) as bool? ?? false;
            final always = request['always'] as bool? ?? false;
            final meta = permReqId != null ? _pendingPermissionMeta[permReqId] : null;
            if (always && allowed) {
              final toolName = (request['tool'] ?? request['toolName'] ?? meta?.effectiveTool ?? '').toString().trim();
              if (toolName.isNotEmpty) {
                _alwaysApprovedTools.add(toolName);
              }
              if (meta != null) {
                _alwaysApprovedTools.add(meta.rawTool);
                _alwaysApprovedTools.add(meta.effectiveTool);
              }
              final reqRiskStr = (request['risk'] ?? meta?.risk.name ?? '').toString().toLowerCase();
              final resolvedRisk = switch (reqRiskStr) {
                'read' => ToolRiskLevel.read,
                'write' => ToolRiskLevel.write,
                'network' => ToolRiskLevel.network,
                'execute' => ToolRiskLevel.execute,
                _ => _resolveEffectiveToolAndRisk(toolName, const {}, ToolRiskLevel.execute, dartTools).risk,
              };
              switch (resolvedRisk) {
                case ToolRiskLevel.read:
                  permissions.autoApproveRead = true;
                  permissions.autoApproveRead = true;
                case ToolRiskLevel.write:
                  permissions.autoApproveWrite = true;
                  permissions.autoApproveWrite = true;
                case ToolRiskLevel.execute:
                  permissions.autoApproveExecute = true;
                  permissions.autoApproveExecute = true;
                case ToolRiskLevel.network:
                  permissions.autoApproveNetwork = true;
                  permissions.autoApproveNetwork = true;
              }
              permissions.save();
              try {
                  // config.yaml synced via permissions.save()
              } catch (_) {}
              _sendEvent('permissions_updated', {
                'autoApproveRead': permissions.autoApproveRead,
                'autoApproveWrite': permissions.autoApproveWrite,
                'autoApproveExecute': permissions.autoApproveExecute,
                'autoApproveNetwork': permissions.autoApproveNetwork,
              });
            }
            if (permReqId != null &&
                _pendingPermissions.containsKey(permReqId)) {
              _pendingPermissions[permReqId]!.complete(allowed);
              _pendingPermissions.remove(permReqId);
              _pendingPermissionMeta.remove(permReqId);
            } else if (_pendingPermissions.isNotEmpty) {
              final firstKey = _pendingPermissions.keys.first;
              _pendingPermissions[firstKey]!.complete(allowed);
              _pendingPermissions.remove(firstKey);
              _pendingPermissionMeta.remove(firstKey);
            }

          case 'set_permissions':
            final autoWrite = request['autoApproveWrite'] as bool?;
            final autoExec = request['autoApproveExecute'] as bool?;
            if (autoWrite != null) permissions.autoApproveWrite = autoWrite;
            if (autoExec != null) permissions.autoApproveExecute = autoExec;
            permissions.save();
            _sendEvent('permissions_updated', {
              'id': ?requestId,
              'autoApproveWrite': permissions.autoApproveWrite,
              'autoApproveExecute': permissions.autoApproveExecute,
            });

          case 'cancel':
            if (_isTurnActive) {
              _log('Cancelling active agent turn on request');
              _cancelPendingPermissions();
              _activeEngine?.cancel('code_agent');
              _sendEvent('cancelled', {'id': ?requestId});
            }

          case 'clear_session':
          case 'new_session':
            history.clear();
            _activeSessionId = 'session_${DateTime.now().millisecondsSinceEpoch}';
            _activeSessionCreatedAt = DateTime.now();
            _activeSessionTitle = 'TealKit Coding Session';
            _activeSessionFilePath = null;
            _sendEvent('session_cleared', {
              'id': ?requestId,
              'sessionId': _activeSessionId,
            });

          case 'get_session_history':
            _sendEvent('session_loaded', {
              'id': ?requestId,
              'sessionId': _activeSessionId,
              'title': _activeSessionTitle,
              'filePath': _activeSessionFilePath,
              'isTurnActive': _isTurnActive,
              'messages': _serializeHistoryForUi(history),
            });

          case 'list_sessions':
            final sessions = await _listSavedSessions(workspaceDir);
            _sendEvent('sessions_list', {
              'id': ?requestId,
              'activeSessionId': _activeSessionId,
              'sessions': sessions,
            });

          case 'load_session':
            final targetPath = request['path'] as String?;
            if (targetPath != null && File(targetPath).existsSync()) {
              try {
                final loaded = await SessionManager.loadSession(targetPath);
                history.clear();
                history.addAll(loaded.messages);
                _activeSessionId = loaded.id;
                _activeSessionCreatedAt = loaded.createdAt;
                _activeSessionTitle = loaded.title;
                _activeSessionFilePath = targetPath;
                _sendEvent('session_loaded', {
                  'id': ?requestId,
                  'sessionId': _activeSessionId,
                  'title': _activeSessionTitle,
                  'filePath': _activeSessionFilePath,
                  'isTurnActive': _isTurnActive,
                  'messages': _serializeHistoryForUi(history),
                });
              } catch (e) {
                _sendEvent('error', {
                  'id': ?requestId,
                  'message': 'Failed to load session: $e',
                });
              }
            }

          case 'delete_session':
            final targetPath = request['path'] as String?;
            if (targetPath != null) {
              try {
                final f = File(targetPath);
                if (f.existsSync()) f.deleteSync();
                if (_activeSessionFilePath == targetPath) {
                  _activeSessionFilePath = null;
                }
              } catch (_) {}
              final sessions = await _listSavedSessions(workspaceDir);
              _sendEvent('sessions_list', {
                'id': ?requestId,
                'activeSessionId': _activeSessionId,
                'sessions': sessions,
              });
            }

          case 'prompt':
            final promptText = request['text'] as String? ?? request['prompt'] as String? ?? '';
            final contextFiles =
                (request['contextFiles'] as List?)
                    ?.map((e) => e.toString())
                    .toList() ??
                const <String>[];
            final overrideMode = request['mode'] as String?;
            if (overrideMode != null) {
              currentMode = switch (overrideMode) {
                'architect' => CodingMode.architect,
                'ask' => CodingMode.ask,
                'rag' => _isRagConfigured(cliConfig) ? CodingMode.rag : CodingMode.code,
                _ => CodingMode.code,
              };
            }

            final trimmedPrompt = promptText.trim();
            final turnId = requestId ?? 'turn_${DateTime.now().millisecondsSinceEpoch}';

            if (trimmedPrompt.startsWith('/reindex')) {
              _sendEvent('start', {'id': turnId, 'prompt': promptText});
              cliConfig = CliConfig.load();
              final ragService = RagService(cliConfig.rag);
              try {
                final res = await ragService.reindex(
                  onProgress: (current, total, status) {
                    _sendEvent('log', {'id': turnId, 'message': 'Indexing [$current/$total] $status'});
                  },
                );
                final stats = res['stats'] as Map<String, dynamic>;
                final msg = '✔ **RAG Indexing completed in ${res['duration_seconds']}s**\n'
                    '- Evaluated: `${res['evaluated']}` | Updated: `${res['updated']}` | Unchanged: `${res['skipped']}` | New Chunks: `${res['new_chunks']}`\n'
                    '- Total Documents: `${stats['document_count']}` | Total Chunks: `${stats['chunk_count']}` | DB Size: `${stats['file_size_mb']} MB`';
                _sendEvent('chunk', {'id': turnId, 'text': msg});
                _sendEvent('done', {'id': turnId, 'response': msg, 'usage': {'promptTokens': 0, 'completionTokens': 0, 'totalTokens': 0}});
              } catch (e) {
                _sendEvent('error', {'id': turnId, 'message': 'RAG indexing failed: $e'});
              } finally {
                ragService.dispose();
              }
              break;
            }

            if (trimmedPrompt == '/rag' || trimmedPrompt.startsWith('/rag ')) {
              _sendEvent('start', {'id': turnId, 'prompt': promptText});
              cliConfig = CliConfig.load();
              final parts = trimmedPrompt.split(RegExp(r'\s+'));
              final sub = parts.length > 1 ? parts[1].toLowerCase() : 'status';
              final ragService = RagService(cliConfig.rag);
              try {
                if (sub == 'search' && parts.length > 2) {
                  final query = parts.sublist(2).join(' ').trim();
                  final results = await ragService.search(query, limit: cliConfig.rag.maxChunks);
                  final sb = StringBuffer('### 📚 RAG Search Results for `"$query"`\n\n');
                  if (results.isEmpty) {
                    sb.writeln('_No matching chunks found in RAG index. Run `/reindex` after configuring folders/web URLs in Settings._');
                  } else {
                    for (int i = 0; i < results.length; i++) {
                      final r = results[i];
                      final scoreStr = (r.score * 100).toStringAsFixed(1);
                      final title = r.documentTitle ?? r.documentUri;
                      sb.writeln('**[${i + 1}] $title** (${r.matchType.toUpperCase()}, $scoreStr%, ${r.locationLabel})');
                      sb.writeln('- Source: `${r.terminalLocation}`');
                      final snippet = r.content.length > 280 ? '${r.content.substring(0, 280)}...' : r.content;
                      sb.writeln('> ${snippet.replaceAll("\n", " ")}\n');
                    }
                  }
                  final outText = sb.toString();
                  _sendEvent('chunk', {'id': turnId, 'text': outText});
                  _sendEvent('done', {'id': turnId, 'response': outText, 'usage': {'promptTokens': 0, 'completionTokens': 0, 'totalTokens': 0}});
                } else {
                  ragService.init();
                  final stats = ragService.database.getStats();
                  final outText = '### 📚 Local RAG Status\n'
                      '- **Enabled**: `${cliConfig.rag.enabled}` (Configured: `${_isRagConfigured(cliConfig)}`)\n'
                      '- **Database**: `${stats['database_path']}` (`${stats['file_size_mb']} MB`)\n'
                      '- **Documents**: `${stats['document_count']}` | **Chunks**: `${stats['chunk_count']}` (Vectors: `${stats['vector_count']}`)\n'
                      '- **Search Mode**: `${cliConfig.rag.searchMode}` | **Embedder**: `${cliConfig.rag.embeddingProvider}`\n'
                      '- **Folder Sources**: `${cliConfig.rag.folderSources.isEmpty ? "(none)" : cliConfig.rag.folderSources.join(", ")}`\n'
                      '- **Web Sources**: `${cliConfig.rag.webSources.isEmpty ? "(none)" : cliConfig.rag.webSources.join(", ")}`\n\n'
                      '_Tip: Use `/reindex` to build/update the index or `/rag search <query>` to test retrieval._';
                  _sendEvent('chunk', {'id': turnId, 'text': outText});
                  _sendEvent('done', {'id': turnId, 'response': outText, 'usage': {'promptTokens': 0, 'completionTokens': 0, 'totalTokens': 0}});
                }
              } catch (e) {
                _sendEvent('error', {'id': turnId, 'message': 'RAG error: $e'});
              } finally {
                ragService.dispose();
              }
              break;
            }

            if (trimmedPrompt == '/llm' || trimmedPrompt == '/models' || trimmedPrompt.startsWith('/llm:') || (trimmedPrompt.startsWith('/llm ') && !trimmedPrompt.startsWith('/llm.yaml'))) {
              String? target;
              if (trimmedPrompt.startsWith('/llm:')) {
                target = trimmedPrompt.substring(5).trim();
              } else if (trimmedPrompt.startsWith('/llm ')) {
                target = trimmedPrompt.substring(5).trim();
              }

              if (target != null && target.isNotEmpty) {
                try {
                  final newConfig = runner.loadLlmConfig(targetName: target);
                  activeLlmConfig = newConfig;
                  activeLlmName = target;
                  final rates = await TokenUsageTracker.getRatesAsync(activeLlmConfig);
                  final badgeParts = <String>[];
                  if (rates?.contextWindow != null) {
                    badgeParts.add(TokenUsageTracker.formatContextWindow(rates!.contextWindow));
                  }
                  if (rates != null && rates.inputPerM == 0.0 && rates.outputPerM == 0.0) {
                    badgeParts.add('Free');
                  } else if (rates != null) {
                    badgeParts.add('\$${rates.inputPerM.toStringAsFixed(2)}/\$${rates.outputPerM.toStringAsFixed(2)}');
                  }
                  final badgeStr = badgeParts.isNotEmpty ? ' [${badgeParts.join(' \u2022 ')}]' : '';
                  final msg = 'Switched active LLM to: **$target** (${activeLlmConfig.provider.displayName} / ${activeLlmConfig.model})$badgeStr (temp: ${activeLlmConfig.temperature}, max_tokens: ${activeLlmConfig.maxTokens})';
                  _sendEvent('chunk', {'id': turnId, 'text': msg});
                  _sendEvent('done', {'id': turnId, 'response': msg, 'usage': {'promptTokens': 0, 'completionTokens': 0, 'totalTokens': 0}});
                  _sendEvent('model_changed', {
                    'id': turnId,
                    'profile': activeLlmName,
                    'model': activeLlmName,
                    'modelId': activeLlmConfig.model,
                    'provider': activeLlmConfig.provider.displayName,
                  });
                } catch (e) {
                  _sendEvent('error', {'id': turnId, 'message': 'Failed to switch model to $target: $e'});
                }
                break;
              }

              final buffer = StringBuffer();
              buffer.writeln('### Configured LLM Profiles');
              buffer.writeln('```text');
              for (final p in allProfiles) {
                final isCurrent = (p.name == activeLlmName);
                final marker = isCurrent ? '* [ACTIVE]' : '          ';
                final rates = await TokenUsageTracker.getRatesAsync(p.config);
                final badgeParts = <String>[];
                if (rates?.contextWindow != null) {
                  badgeParts.add(TokenUsageTracker.formatContextWindow(rates!.contextWindow));
                }
                if (rates != null && rates.inputPerM == 0.0 && rates.outputPerM == 0.0) {
                  badgeParts.add('Free');
                } else if (rates != null) {
                  badgeParts.add('\$${rates.inputPerM.toStringAsFixed(2)}/\$${rates.outputPerM.toStringAsFixed(2)}');
                }
                final badgeStr = badgeParts.isNotEmpty ? ' [${badgeParts.join(' \u2022 ')}]' : '';
                buffer.writeln('$marker ${p.name.padRight(16)} : ${p.config.provider.displayName} / ${p.config.model}$badgeStr (temp: ${p.config.temperature}, max_tokens: ${p.config.maxTokens})');
              }
              buffer.writeln('```');
              buffer.writeln('*Tip: Use `/llm <name>` or the dropdown selector to switch models.*');
              final outText = buffer.toString();
              _sendEvent('chunk', {'id': turnId, 'text': outText});
              _sendEvent('done', {'id': turnId, 'response': outText, 'usage': {'promptTokens': 0, 'completionTokens': 0, 'totalTokens': 0}});
              break;
            }

            if (_isTurnActive) {
              _log('Turn already active, cancelling previous turn before starting new prompt');
              _cancelPendingPermissions();
              _activeEngine?.cancel('code_agent');
              await Future.delayed(const Duration(milliseconds: 150));
            }

            unawaited(_executePromptTurn(
              promptText: promptText,
              contextFiles: contextFiles,
              turnId:
                  requestId ?? 'turn_${DateTime.now().millisecondsSinceEpoch}',
              runner: runner,
              activeLlmConfig: activeLlmConfig,
              activeLlmName: activeLlmName,
              allProfiles: allProfiles,
              dartTools: dartTools,
              localServers: localServers,
              mcpTools: mcpTools,
              history: history,
              episodicMemoryStore: episodicMemoryStore,
              usageTracker: usageTracker,
              cliConfig: cliConfig,
              permissions: permissions,
            ));

          case 'exit':
            _log('Exiting RPC engine on request');
            exit(0);

          default:
            _sendEvent('error', {
              'id': ?requestId,
              'message': 'Unknown action: $action',
            });
        }
      } catch (e, stack) {
        _log('Error handling action $action: $e\n$stack');
        _sendEvent('error', {
          'id': ?requestId,
          'message': 'Internal error: $e',
        });
      }
    }
  }

  Future<void> _executePromptTurn({
    required String promptText,
    required List<String> contextFiles,
    required String turnId,
    required SkillRunner runner,
    required LlmConfig activeLlmConfig,
    required String activeLlmName,
    required List<NamedLlmProfile> allProfiles,
    required List<McpLocalTool> dartTools,
    required List<McpServerConfig> localServers,
    required List<MCPTool> mcpTools,
    required List<ChatMessage> history,
    required EpisodicMemoryStore episodicMemoryStore,
    required TokenUsageTracker usageTracker,
    required CliConfig cliConfig,
    required ToolPermissionSettings permissions,
  }) async {
    _sendEvent('start', {'id': turnId, 'prompt': promptText});

    // Build effective prompt with context files if supplied
    final effectivePromptBuffer = StringBuffer();
    if (contextFiles.isNotEmpty) {
      effectivePromptBuffer.writeln('Active Context Files:');
      for (final filePath in contextFiles) {
        final absPath = p.isAbsolute(filePath)
            ? filePath
            : p.join(workspaceDir, filePath);
        final f = File(absPath);
        if (f.existsSync()) {
          final content = f.readAsStringSync();
          effectivePromptBuffer.writeln('--- $filePath ---');
          effectivePromptBuffer.writeln(content);
          effectivePromptBuffer.writeln('--- end $filePath ---');
        }
      }
      effectivePromptBuffer.writeln('');
    }

    // Inject local RAG context when in RAG mode or when RAG is enabled and configured
    if ((currentMode == CodingMode.rag || cliConfig.rag.enabled) &&
        _isRagConfigured(cliConfig)) {
      final ragService = RagService(cliConfig.rag);
      try {
        final ragContext = await ragService.buildPromptContext(promptText);
        if (ragContext != null && ragContext.isNotEmpty) {
          _sendEvent('log', {
            'id': turnId,
            'message': '📚 RAG: Retrieved relevant context from indexed documents',
          });
          effectivePromptBuffer.writeln(ragContext);
          effectivePromptBuffer.writeln('');
        }
      } catch (e) {
        _log('RAG retrieval note: $e');
      } finally {
        ragService.dispose();
      }
    }

    effectivePromptBuffer.write(promptText);
    final effectivePromptText = effectivePromptBuffer.toString();

    // Filter tools for ask/rag mode
    List<McpLocalTool> activeDartTools = dartTools;
    if (currentMode == CodingMode.ask || currentMode == CodingMode.rag) {
      activeDartTools = dartTools.where((t) {
        final isWriteOrExec =
            t.name == "fs_write_file" ||
            t.name == "fs_replace_text" ||
            t.name == "execute_command" ||
            t.name == "terminal_exec" ||
            t.name == "git_commit";
        return !isWriteOrExec;
      }).toList();
    }

    // Build subagents
    final subAgents = SubAgentHelper.buildSubAgents(
      allProfiles: allProfiles,
      activeProfileName: activeLlmName,
      configuredSubagents: cliConfig.subagents,
      availableTools: activeDartTools,
      localServers: localServers.where((s) => s.isLocal).toList(),
      remoteServers: localServers.where((s) => !s.isLocal).toList(),
    );
    final subAgentKeys = subAgents.map((a) => a.key).toList();

    // Build system prompt
    final userInstructions = _loadWorkspaceInstructions();
    final attachedSkillInstructions = StringBuffer();
    if (_attachedSkills.isNotEmpty) {
      final allDiscovered = _discoverSkills(runner);
      for (final s in allDiscovered) {
        if (_attachedSkills.contains(s['name'])) {
          final skillPath = s['path'] as String?;
          if (skillPath != null && File(skillPath).existsSync()) {
            try {
              final manifest = runner.parseSkillFile(skillPath);
              attachedSkillInstructions.writeln('\n--- [Attached Skill: ${manifest.name}] ---');
              if (manifest.systemPrompt.isNotEmpty) {
                attachedSkillInstructions.writeln(manifest.systemPrompt);
              }
            } catch (_) {}
          }
        }
      }
    }

    final combinedInstructions = userInstructions + attachedSkillInstructions.toString();
    final systemPrompt = _buildSystemPrompt(
      mode: currentMode,
      workspaceDir: workspaceDir,
      userInstructions: combinedInstructions,
    );

    final initialTurnMessages = <ChatMessage>[...history];

    // In IDE / RPC mode, coding agents expose native workspace tools directly so models
    // can invoke fs_read_file, fs_list_dir, terminal_exec without mcp_call_tool wrapping.
    // Only enable progressive discovery if there are many external MCP tools (> 20) and progressive_tools is 'on'.
    final isProgressiveActive = mcpTools.length > 20 &&
        (cliConfig.progressiveTools.toLowerCase().trim() == 'on' ||
            cliConfig.progressiveTools.toLowerCase().trim() == 'true');

    final availableSkillNames = _discoverSkills(runner).map((s) => s['name'] as String).toList();
    final activateTool = ActivateSkillsTool(
      availableSkills: availableSkillNames,
      onActivate: (skills) async {
        _attachedSkills.addAll(skills);
        _sendEvent('skills_changed', {
          'id': turnId,
          'activeSkills': _attachedSkills.toList(),
          'activated': skills,
        });
        return 'Skills dynamically activated: ${skills.join(", ")}';
      },
    );
    final deactivateTool = DeactivateSkillsTool(
      onDeactivate: (skills) async {
        _attachedSkills.removeAll(skills);
        _sendEvent('skills_changed', {
          'id': turnId,
          'activeSkills': _attachedSkills.toList(),
          'deactivated': skills,
        });
        return 'Skills deactivated: ${skills.join(", ")}';
      },
    );

    final effectiveDartTools = List<McpLocalTool>.from(activeDartTools);
    effectiveDartTools.add(activateTool);
    effectiveDartTools.add(deactivateTool);

    final agent = Agent(
      key: 'code_agent',
      name: 'Coding Assistant',
      llmConfig: activeLlmConfig,
      systemPrompt: systemPrompt,
      enablePlanning: cliConfig.enablePlanning,
      progressiveMcpDiscovery: isProgressiveActive,
      enableDelegation: true,
      subAgentKeys: subAgentKeys,
      contextCompressor: ContextCompressor(
        tokenThreshold: cliConfig.contextCompressionThreshold > 8000
            ? cliConfig.contextCompressionThreshold
            : (activeLlmConfig.isSlm ? 12000 : 32000),
        memoryStore: episodicMemoryStore,
      ),
      prompts: [SubPromptStep(text: effectivePromptText)],
      dartTools: effectiveDartTools,
      localServers: localServers.where((s) => s.isLocal).toList(),
      remoteServers: localServers.where((s) => !s.isLocal).toList(),
      initialMessages: initialTurnMessages,
      maxToolIterations: cliConfig.maxToolIterations > 0
          ? cliConfig.maxToolIterations
          : 100,
    );

    final engine = McpAgentEngine();
    engine.setAgents([agent, ...subAgents]);
    _activeEngine = engine;
    _isTurnActive = true;

    String finalResponse = '';

    try {
      final subscription = engine.agentEvents.listen((event) {
        try {
          switch (event) {
            case AgentLogEvent(:final message):
              _sendEvent('log', {'id': turnId, 'message': message});

            case AgentTextChunkEvent(:final chunk):
              finalResponse += chunk;
              _sendEvent('chunk', {'id': turnId, 'text': chunk});

            case AgentAssistantResultEvent(:final response):
              if (finalResponse.trim().isEmpty) {
                finalResponse = response;
                _sendEvent('chunk', {'id': turnId, 'text': response});
              }

            case AgentToolResultEvent(
              :final toolName,
              :final parameters,
              :final result,
            ):
              _sendEvent('tool_result', {
                'id': turnId,
                'tool': toolName,
                'parameters': parameters,
                'output': result,
              });

              // Detect and emit diff events for file modifications
              if (toolName == 'fs_replace_text' || toolName == 'fs_write_file') {
                final targetPath = parameters['path'] as String?;
                if (targetPath != null) {
                  final absPath = p.isAbsolute(targetPath)
                      ? targetPath
                      : p.join(workspaceDir, targetPath);
                  final f = File(absPath);
                  if (f.existsSync()) {
                    _sendEvent('diff', {
                      'id': turnId,
                      'path': targetPath,
                      'modified': f.readAsStringSync(),
                    });
                  }
                }
              }

            case AgentPlanEvent(:final plan):
              _sendEvent('plan', {'id': turnId, 'plan': plan});

            case AgentSubAgentStartedEvent(:final subAgentKey, :final task):
              _sendEvent('subagent_start', {
                'id': turnId,
                'subagent': subAgentKey,
                'task': task,
              });

            case AgentSubAgentCompletedEvent(:final subAgentKey):
              _sendEvent('subagent_done', {
                'id': turnId,
                'subagent': subAgentKey,
              });

            case AgentContextCompressedEvent(
              :final originalTokens,
              :final compressedTokens,
              :final compressedTurnCount,
            ):
              _sendEvent('context_compressed', {
                'id': turnId,
                'originalTokens': originalTokens,
                'compressedTokens': compressedTokens,
                'compressedTurnCount': compressedTurnCount,
              });

            case AgentMemoryRetrievedEvent(
              :final archiveId,
              :final recalledTurnCount,
              :final query,
            ):
              _sendEvent('memory_retrieved', {
                'id': turnId,
                'archiveId': archiveId,
                'recalledTurnCount': recalledTurnCount,
                'query': query,
              });

            case AgentSkillsChangedEvent(:final activeSkills):
              _attachedSkills.clear();
              _attachedSkills.addAll(activeSkills);
              _sendEvent('skills_changed', {
                'id': turnId,
                'activeSkills': activeSkills,
              });

            case AgentUsageEvent(:final promptTokens, :final completionTokens):
              usageTracker.recordUsage(
                prompt: promptTokens,
                completion: completionTokens,
              );
              _sendEvent('usage', {
                'id': turnId,
                'promptTokens': promptTokens,
                'completionTokens': completionTokens,
              });

            case AgentErrorEvent(:final error):
              _sendEvent('error', {'id': turnId, 'message': error.toString()});

            case AgentFinalResultEvent(:final response, :final messages):
              if (finalResponse.trim().isEmpty && response.trim().isNotEmpty) {
                finalResponse = response;
                _sendEvent('chunk', {'id': turnId, 'text': response});
              }
              history.clear();
              history.addAll(messages);

            default:
              break;
          }
        } catch (e) {
          _sendEvent('error', {'id': turnId, 'message': e.toString()});
        }
      }, onError: (err) {
        _sendEvent('error', {'id': turnId, 'message': err.toString()});
      });

      await engine.run(
        agent.key,
        onToolApproval:
            ({
              required String toolName,
              required Map<String, dynamic> parameters,
              required ToolRiskLevel riskLevel,
            }) async {
              final resolved = _resolveEffectiveToolAndRisk(
                toolName,
                parameters,
                riskLevel,
                effectiveDartTools,
              );
              final effectiveTool = resolved.effectiveTool;
              final effectiveRisk = resolved.risk;
              final effectiveParams = resolved.effectiveParams;

              if (_alwaysApprovedTools.contains(toolName) ||
                  _alwaysApprovedTools.contains(effectiveTool)) {
                return true;
              }

              final autoApproved = switch (effectiveRisk) {
                ToolRiskLevel.read => permissions.autoApproveRead,
                ToolRiskLevel.write => permissions.autoApproveWrite,
                ToolRiskLevel.execute => permissions.autoApproveExecute,
                ToolRiskLevel.network => permissions.autoApproveNetwork,
              };
              if (autoApproved) return true;

              final permReqId =
                  'perm_${DateTime.now().millisecondsSinceEpoch}_$effectiveTool';
              final completer = Completer<bool>();
              _pendingPermissions[permReqId] = completer;
              _pendingPermissionMeta[permReqId] = (
                rawTool: toolName,
                effectiveTool: effectiveTool,
                risk: effectiveRisk,
              );
              _sendEvent('permission_request', {
                'requestId': permReqId,
                'id': permReqId,
                'tool': effectiveTool,
                'toolName': effectiveTool,
                'rawTool': toolName,
                'parameters': effectiveParams,
                'risk': effectiveRisk.name,
              });
              return await completer.future;
            },
      );

      await subscription.cancel();

      if (finalResponse.trim().isEmpty) {
        for (final m in history.reversed) {
          if (m.role == ChatRole.assistant && m.content.trim().isNotEmpty) {
            finalResponse = m.content;
            _sendEvent('chunk', {'id': turnId, 'text': finalResponse});
            break;
          }
        }
      }

      _sendEvent('done', {
        'id': turnId,
        'response': finalResponse,
        'usage': {
          'promptTokens': usageTracker.promptTokens,
          'completionTokens': usageTracker.completionTokens,
          'totalTokens': usageTracker.totalTokens,
        },
      });
    } catch (e) {
      _sendEvent('error', {'id': turnId, 'message': e.toString()});
    } finally {
      _isTurnActive = false;
      _activeEngine = null;
      _cancelPendingPermissions();
      try {
        await engine.dispose();
      } catch (_) {}

      // Auto-save session transcript if enabled
      if (history.isNotEmpty && (autoSaveSession || cliConfig.autoSaveSession || saveSessionPath != null)) {
        try {
          await _autoSaveActiveSession(
            workspaceDir: workspaceDir,
            history: history,
            activeLlmName: activeLlmName,
            activeLlmConfig: activeLlmConfig,
          );
        } catch (e) {
          _log('Session auto-save warning: $e');
        }
      }

      // Periodic episodic memory auto-archiving every 8 turns
      _sessionTurnCounter++;
      if (_sessionTurnCounter >= 8 && history.isNotEmpty) {
        _sessionTurnCounter = 0;
        try {
          await _archiveMemorySnapshot(
            workspaceDir: workspaceDir,
            history: history,
          );
          _sendEvent('memory_archived', {
            'periodic': true,
            'turnCount': history.length,
            'timestamp': DateTime.now().toIso8601String(),
          });
        } catch (_) {}
      }
    }
  }

  List<Map<String, dynamic>> _serializeHistoryForUi(List<ChatMessage> history) {
    final result = <Map<String, dynamic>>[];
    for (final m in history) {
      if (m.role == ChatRole.system) continue;
      result.add({
        'id': m.id,
        'role': m.role.name,
        'type': m.type.name,
        'content': m.content,
        'toolName': m.toolName,
        'toolArguments': m.toolArguments,
        'timestamp': m.timestamp.toIso8601String(),
      });
    }
    return result;
  }

  Future<void> _autoSaveActiveSession({
    required String workspaceDir,
    required List<ChatMessage> history,
    required String activeLlmName,
    required LlmConfig activeLlmConfig,
  }) async {
    if (history.isEmpty) return;

    // Derive a clean session title from the first user prompt
    if (_activeSessionTitle == 'TealKit Coding Session') {
      for (final m in history) {
        if (m.role == ChatRole.user && m.content.trim().isNotEmpty) {
          var firstLine = m.content.trim().split('\n').first.trim();
          if (firstLine.startsWith('Active Context Files:')) {
            final parts = m.content.split('--- end ');
            firstLine = parts.last.split('\n').skip(1).join(' ').trim();
          }
          if (firstLine.length > 60) {
            firstLine = '${firstLine.substring(0, 57)}...';
          }
          if (firstLine.isNotEmpty) {
            _activeSessionTitle = firstLine;
          }
          break;
        }
      }
    }

    String targetPath;
    if (saveSessionPath != null && saveSessionPath!.trim().isNotEmpty) {
      targetPath = saveSessionPath!;
    } else if (_activeSessionFilePath != null && _activeSessionFilePath!.isNotEmpty) {
      targetPath = _activeSessionFilePath!;
    } else {
      final sessionsDir = Directory(p.join(workspaceDir, '.tealkit', 'sessions'));
      if (!sessionsDir.existsSync()) {
        sessionsDir.createSync(recursive: true);
      }
      targetPath = p.join(sessionsDir.path, 'tealkitcoder_${_activeSessionId}.json');
      _activeSessionFilePath = targetPath;
    }

    final sessionData = SessionData(
      id: _activeSessionId,
      title: _activeSessionTitle,
      mode: currentMode.name,
      createdAt: _activeSessionCreatedAt,
      updatedAt: DateTime.now(),
      llmName: activeLlmName,
      llmProvider: activeLlmConfig.provider.displayName,
      llmModel: activeLlmConfig.model,
      messages: history,
    );

    await SessionManager.saveSession(sessionData, targetPath);
    _sendEvent('session_saved', {
      'sessionId': _activeSessionId,
      'title': _activeSessionTitle,
      'path': targetPath,
      'turnCount': history.length,
      'updatedAt': sessionData.updatedAt.toIso8601String(),
    });
  }

  Future<List<Map<String, dynamic>>> _listSavedSessions(String workspaceDir) async {
    final searchDirs = <String>{
      p.join(workspaceDir, '.tealkit', 'sessions'),
      p.join(workspaceDir, 'sessions'),
    };
    final list = <Map<String, dynamic>>[];
    final seenPaths = <String>{};

    for (final dirPath in searchDirs) {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) continue;
      try {
        for (final entity in dir.listSync()) {
          if (entity is File) {
            final normPath = p.normalize(entity.path);
            if (!seenPaths.add(normPath)) continue;
            final ext = p.extension(normPath).toLowerCase();
            if (ext != '.json' && ext != '.md') continue;
            try {
              final session = await SessionManager.loadSession(normPath);
              if (session.messages.isEmpty) continue;
              list.add({
                'id': session.id,
                'title': session.title,
                'mode': session.mode,
                'llmName': session.llmName ?? '',
                'llmModel': session.llmModel ?? '',
                'createdAt': session.createdAt.toIso8601String(),
                'updatedAt': session.updatedAt.toIso8601String(),
                'turnCount': session.messages.where((m) => m.role == ChatRole.user || m.role == ChatRole.assistant).length,
                'messageCount': session.messages.length,
                'path': normPath,
                'isCurrent': _activeSessionFilePath != null && p.normalize(_activeSessionFilePath!) == normPath,
              });
            } catch (_) {}
          }
        }
      } catch (_) {}
    }

    list.sort((a, b) => (b['updatedAt'] as String).compareTo(a['updatedAt'] as String));
    return list;
  }

  Future<int> _archiveMemorySnapshot({
    required String workspaceDir,
    required List<ChatMessage> history,
  }) async {
    if (history.isEmpty) return 0;
    final memoryDir = Directory(p.join(workspaceDir, '.tealkit', 'memory'));
    if (!memoryDir.existsSync()) memoryDir.createSync(recursive: true);

    final archiveId = 'mem_${DateTime.now().millisecondsSinceEpoch}';
    final archiveFile = File(p.join(memoryDir.path, '$archiveId.json'));

    final turnsData = history.map((m) => {
      'role': m.role.name,
      'content': m.content,
      'timestamp': m.timestamp.toIso8601String(),
    }).toList();

    archiveFile.writeAsStringSync(jsonEncode({
      'archiveId': archiveId,
      'timestamp': DateTime.now().toIso8601String(),
      'turnCount': history.length,
      'turns': turnsData,
    }));

    return history.length;
  }

  List<Map<String, dynamic>> _listMemoryArchives(String workspaceDir) {
    final memoryDir = Directory(p.join(workspaceDir, '.tealkit', 'memory'));
    if (!memoryDir.existsSync()) return [];

    final list = <Map<String, dynamic>>[];
    for (final f in memoryDir.listSync()) {
      if (f is File && f.path.endsWith('.json')) {
        try {
          final data = jsonDecode(f.readAsStringSync());
          if (data is Map<String, dynamic>) {
            list.add({
              'archiveId': data['archiveId'] ?? p.basenameWithoutExtension(f.path),
              'timestamp': data['timestamp'] ?? f.lastModifiedSync().toIso8601String(),
              'turnCount': data['turnCount'] ?? (data['turns'] as List?)?.length ?? 0,
              'path': f.path,
            });
          }
        } catch (_) {}
      }
    }
    list.sort((a, b) => (b['timestamp'] as String).compareTo(a['timestamp'] as String));
    return list;
  }

  void _saveServerProfile(ServerConfigManager manager, ServerProfile profile) {
    final profiles = manager.loadProfiles();
    final idx = profiles.indexWhere((p) => p.name == profile.name);
    if (idx >= 0) {
      profiles[idx] = profile;
    } else {
      profiles.add(profile);
    }
    if (profile.isActive) {
      for (int i = 0; i < profiles.length; i++) {
        if (profiles[i].name != profile.name) {
          profiles[i] = profiles[i].copyWith(isActive: false);
        }
      }
    }
    final sb = StringBuffer('# TealKit CLI Server Connection Profiles\nservers:\n');
    for (final p in profiles) {
      sb.writeln('  - name: "${p.name}"');
      sb.writeln('    url: "${p.url}"');
      sb.writeln('    api_key: "${p.apiKey}"');
      sb.writeln('    is_active: ${p.isActive}');
    }
    manager.file.writeAsStringSync(sb.toString());
  }

  List<Map<String, dynamic>> _discoverSkills(SkillRunner runner) {
    final searchDirs = [
      ...GlobalConfigLocator.resolveSkillDirectories().map((d) => d.path),
      p.join(workspaceDir, 'skills'),
      p.join(workspaceDir, '.tealkit', 'skills'),
    ];

    final skillFiles = <File>[];
    final seen = <String>{};

    for (final dirPath in searchDirs) {
      final dir = Directory(dirPath);
      if (dir.existsSync()) {
        for (final entity in dir.listSync(recursive: false)) {
          if (entity is File && entity.path.endsWith('.md')) {
            if (seen.add(entity.path)) {
              skillFiles.add(entity);
            }
          }
        }
      }
    }

    final result = <Map<String, dynamic>>[];
    for (final file in skillFiles) {
      try {
        final manifest = runner.parseSkillFile(file.path);
        result.add({
          'name': manifest.name,
          'description': manifest.description,
          'version': manifest.version,
          'path': file.path,
          'steps': manifest.promptSteps.length,
          'tools': manifest.tools,
        });
      } catch (_) {}
    }
    return result;
  }

  String _loadWorkspaceInstructions() {
    if (customInstructionsPath != null &&
        File(customInstructionsPath!).existsSync()) {
      return File(customInstructionsPath!).readAsStringSync().trim();
    }
    for (final filename in ['tealkit_agent.md', 'AGENTS.md', 'CLAUDE.md']) {
      final file = File(p.join(workspaceDir, filename));
      if (file.existsSync()) {
        return file.readAsStringSync().trim();
      }
    }
    return '';
  }

  String _buildSystemPrompt({
    required CodingMode mode,
    required String workspaceDir,
    required String userInstructions,
  }) {
    final buffer = StringBuffer();
    final isWin = Platform.isWindows;
    final os = Platform.operatingSystem;
    final osEnv = isWin
        ? 'HOST ENVIRONMENT: Windows (${Platform.operatingSystemVersion})\n'
              '- Shell commands run under Windows (cmd.exe / PowerShell).\n'
              '- NEVER execute Linux/POSIX-specific utilities such as `head`, `tail`, `cat`, `grep`, `ls`, `export`, or bash pipe filters.\n'
              '- Always use native tool arguments (e.g. `git log -n 20` or `git status --short`) or built-in file tools (`fs_read_file`, `fs_find`).'
        : 'HOST ENVIRONMENT: $os (${Platform.operatingSystemVersion})\n'
              '- Shell commands run under POSIX shell (/bin/sh).';

    buffer.writeln('''
You are an expert autonomous software engineer and coding assistant inside the TealKit CLI environment.
Working Directory: $workspaceDir
$osEnv

Operating Principles:
1. EXPLORE FIRST: Discover project files, frameworks, build systems, and versions using `fs_find` and `fs_read_file`.
2. RESEARCH & WEB SEARCH: When needing documentation, latest library APIs, or troubleshooting errors, use the built-in `web_search` tool (powered by web_search.yaml / DuckDuckGo).
3. SURGICAL EDITS: When modifying existing files, use `fs_replace_text` with unique context blocks instead of rewriting full files whenever possible. Use `fs_write_file` to create new files.
4. VERIFY WITH TERMINAL: After code changes, execute build and test commands (e.g. `dotnet build`, `dart test`, `npm test`) using `terminal_exec`. Respect host OS commands!
5. FORMATTING: Use clean markdown, diff blocks, and concise technical explanations.
''');

    switch (mode) {
      case CodingMode.architect:
        buffer.writeln('''
CURRENT MODE: 📐 ARCHITECT (Planning & Analysis Mode)
- Your goal is to inspect the codebase, perform architectural review, design systems, and draft implementation plans.
- DO NOT modify production source code in this mode.
- ALWAYS create or update `tasks.md` in the workspace root with a Markdown checkbox checklist (`- [ ] task description`).
- When asked for an implementation plan, create or update `implementation_plan.md` or a requested document with clear rationale, affected files, and verification steps.
- Conclude by asking the user if they approve the plan and want to switch to `/code` mode to begin execution.
''');
        break;
      case CodingMode.code:
        buffer.writeln('''
CURRENT MODE: 💻 CODE (Implementation Mode)
- Your goal is to implement, refactor, and fix code according to specifications.
- If `tasks.md` exists in the workspace, check it for pending tasks `- [ ]`.
- As you complete and verify each task with `terminal_exec`, update `tasks.md` using `fs_replace_text` to check off the completed item (`- [x]`).
- Always run the relevant build or test command after editing code to ensure you did not introduce syntax errors or broken imports.
''');
        break;
      case CodingMode.ask:
        buffer.writeln('''
CURRENT MODE: 💬 ASK (Q&A & Exploration Mode)
- Your goal is to answer questions, explain concepts, and explore code without making changes.
- Read-only tools (`fs_find`, `fs_read_file`) and informative commands (`terminal_exec` for git log / status) are preferred.
''');
        break;
      case CodingMode.rag:
        buffer.writeln('''
CURRENT MODE: 📚 RAG (Knowledge & Document Search Mode)
- Your goal is to synthesize accurate answers grounded in retrieved local documents, indexed websites, and workspace files.
- Always cite the source document or URL when using retrieved RAG context chunks.
- Combine retrieved RAG knowledge with workspace exploration (`fs_find`, `fs_read_file`) when answering technical or architectural questions.
''');
        break;
    }

    if (userInstructions.isNotEmpty) {
      buffer.writeln('''
==============================
WORKSPACE CUSTOM INSTRUCTIONS (from tealkit_agent.md):
$userInstructions
==============================
''');
    }

    return buffer.toString();
  }
}
