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
import '../engine/skill_runner.dart';
import '../engine/subagent_helper.dart';
import '../engine/token_usage_tracker.dart';

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

  McpAgentEngine? _activeEngine;
  bool _isTurnActive = false;
  final Map<String, Completer<bool>> _pendingPermissions = {};
  final Set<String> _attachedSkills = {};
  int _sessionTurnCounter = 0;

  TealKitRpcEngine({
    required this.workspaceDir,
    this.customConfigPath,
    this.customInstructionsPath,
    this.llmPath = 'llm.yaml',
    this.initialLlmName,
    this.toolsPath = 'extern_mcp_tools.yaml',
    this.currentMode = CodingMode.code,
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

    final permissions = ToolPermissionSettings.load();
    final cliConfig = CliConfig.load();

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

    final resolvedLlmFile = GlobalConfigLocator.resolveConfigFile(llmPath);
    final resolvedMcpFile = GlobalConfigLocator.resolveConfigFile(toolsPath);

    // Send initial ready event
    _sendEvent('ready', {
      'version': '1.4.3',
      'workspace': workspaceDir,
      'mode': currentMode.name,
      'model': activeLlmName,
      'provider': activeLlmConfig.provider.displayName,
      'modelId': activeLlmConfig.model,
      'toolsCount': dartTools.length + mcpTools.length,
      'llmConfigPath': resolvedLlmFile.path,
      'mcpConfigPath': resolvedMcpFile.path,
      'activeSkills': _attachedSkills.toList(),
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
              'model': activeLlmName,
              'provider': activeLlmConfig.provider.displayName,
              'modelId': activeLlmConfig.model,
              'toolsCount': dartTools.length + mcpTools.length,
              'autoApproveWrite': permissions.autoApproveWrite,
              'autoApproveExecute': permissions.autoApproveExecute,
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
            final profileName = request['model'] as String? ?? request['profile'] as String? ?? '';
            try {
              final newConfig = runner.loadLlmConfig(targetName: profileName);
              activeLlmConfig = newConfig;
              activeLlmName = profileName;
              _sendEvent('model_changed', {
                'id': ?requestId,
                'profile': activeLlmName,
                'model': activeLlmConfig.model,
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
            currentMode = switch (newModeStr) {
              'architect' => CodingMode.architect,
              'ask' => CodingMode.ask,
              _ => CodingMode.code,
            };
            _sendEvent('mode_changed', {
              'id': ?requestId,
              'mode': currentMode.name,
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
            final count = await _archiveMemorySnapshot(
              workspaceDir: workspaceDir,
              history: history,
            );
            _sendEvent('memory_archived', {
              'id': ?requestId,
              'turnCount': count,
              'timestamp': DateTime.now().toIso8601String(),
            });

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
            final permReqId = request['requestId'] as String?;
            final allowed = request['allowed'] as bool? ?? false;
            if (permReqId != null &&
                _pendingPermissions.containsKey(permReqId)) {
              _pendingPermissions[permReqId]!.complete(allowed);
              _pendingPermissions.remove(permReqId);
            }

          case 'cancel':
            if (_isTurnActive && _activeEngine != null) {
              _log('Cancelling active agent turn on request');
              _activeEngine?.cancel('code_agent');
              _sendEvent('cancelled', {'id': ?requestId});
            }

          case 'clear_session':
            history.clear();
            _sendEvent('session_cleared', {'id': ?requestId});

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
                _ => CodingMode.code,
              };
            }

            final trimmedPrompt = promptText.trim();
            final turnId = requestId ?? 'turn_${DateTime.now().millisecondsSinceEpoch}';

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
                    'model': activeLlmConfig.model,
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
              _activeEngine?.cancel('code_agent');
              await Future.delayed(const Duration(milliseconds: 100));
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
    effectivePromptBuffer.write(promptText);
    final effectivePromptText = effectivePromptBuffer.toString();

    // Filter tools for ask mode
    List<McpLocalTool> activeDartTools = dartTools;
    if (currentMode == CodingMode.ask) {
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

        // In IDE / RPC mode, coding agents always use direct schemas so models
    // (Gemma, Qwen, DeepSeek, Claude, GPT) can directly invoke coding tools (fs_list_dir, terminal_exec, etc.)
    // unless progressive_tools is explicitly forced to 'on'.
    final isProgressiveActive = cliConfig.progressiveTools.toLowerCase().trim() == 'on' ||
        cliConfig.progressiveTools.toLowerCase().trim() == 'true';

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
        tokenThreshold: cliConfig.contextCompressionThreshold > 4000
            ? cliConfig.contextCompressionThreshold
            : (activeLlmConfig.isSlm ? 4000 : 16000),
        memoryStore: episodicMemoryStore,
      ),
      prompts: [SubPromptStep(text: effectivePromptText)],
      dartTools: effectiveDartTools,
      localServers: localServers.where((s) => s.isLocal).toList(),
      remoteServers: localServers.where((s) => !s.isLocal).toList(),
      initialMessages: initialTurnMessages,
      maxToolIterations: 400,
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
              final autoApproved = switch (riskLevel) {
                ToolRiskLevel.read => permissions.autoApproveRead,
                ToolRiskLevel.write => permissions.autoApproveWrite,
                ToolRiskLevel.execute => permissions.autoApproveExecute,
                ToolRiskLevel.network => permissions.autoApproveNetwork,
              };
              if (autoApproved) return true;

              final permReqId =
                  'perm_${DateTime.now().millisecondsSinceEpoch}_$toolName';
              final completer = Completer<bool>();
              _pendingPermissions[permReqId] = completer;
              _sendEvent('permission_request', {
                'requestId': permReqId,
                'id': permReqId,
                'tool': toolName,
                'toolName': toolName,
                'parameters': parameters,
                'risk': riskLevel.name,
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
