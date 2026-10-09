import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dart_mcp_core/dart_mcp_core.dart';

import '../config/llm_config_manager.dart';
import '../engine/builtin_mcp_servers.dart';
import '../engine/cli_attachment_helper.dart';
import '../engine/cli_clipboard_helper.dart';
import '../engine/embedded/cli_embedded_llm_adapter.dart';
import '../engine/embedded/cli_embedded_model_manager.dart';
import '../engine/mcp_manager_helper.dart';
import '../engine/session_manager.dart';
import '../engine/skill_runner.dart';
import '../engine/token_usage_tracker.dart';
import '../formatters/terminal_printer.dart';
import '../formatters/terminal_spinner.dart';

/// `tealkit chat [--skill <path>]`
class ChatCommand extends Command {
  @override
  final String name = 'chat';
  @override
  final String description =
      'Start an interactive multi-turn terminal agent session.';

  ChatCommand() {
    argParser.addOption(
      'skill',
      abbr: 's',
      help: 'Preload system prompt and tools from a SKILL.md file',
    );
    argParser.addOption(
      'llm',
      help: 'Path to custom llm.yaml configuration or model name',
      defaultsTo: 'llm.yaml',
    );
    argParser.addOption(
      'llm-name',
      help:
          'Select named LLM model profile from llm.yaml (e.g. ollama, deepseek, mistral)',
    );
    argParser.addOption(
      'tools',
      help: 'Path to custom extern_mcp_tools.yaml / mcp.yaml',
      defaultsTo: 'extern_mcp_tools.yaml',
    );
    argParser.addOption(
      'save-session',
      help: 'File path (.json or .md) to auto-save session transcript',
    );
    argParser.addOption(
      'load-session',
      help: 'File path (.json or .md) to load and continue a previous session',
    );
    argParser.addOption(
      'max-tool-iterations',
      abbr: 't',
      defaultsTo: '400',
      help:
          'Maximum tool calls per step before synthesizing final response (defaults to 400)',
    );
    argParser.addFlag(
      'verbose',
      abbr: 'v',
      negatable: false,
      help: 'Print verbose logs',
    );
    argParser.addFlag(
      'compact',
      defaultsTo: true,
      help: 'Compact display mode (hide file read contents, show only filename)',
    );
  }

  static const _helpText = '''
Commands:
  /llm                       List all configured LLM profiles and show active
  /llm <name> or /llm:<name> Switch active LLM profile (e.g. /llm:ollama, /llm mistral)
  /compact [on|off]          Toggle compact mode (hide file read contents, show only filenames)
  /install <name|all_mcp>    Install / load MCP server package & connect to session
  /uninstall <name|all_mcp>  Uninstall MCP server package from filesystem & disable in mcp.yaml
  /mcp_inspect [server_name] Inspect functions & schemas of enabled MCP servers
  /mcp_enable_fnc <srv> <f1,f2> Whitelist specific tools for an MCP server (temporary until exit/reset)
  /mcp_reset_fnc [server]    Reset tool filters and restore all MCP functions
  /save-session [path]       Save session transcript to .json or .md file
  /load-session <path>       Load and continue a saved session from .json or .md
  /clear-session, /clear     Clear conversation history and token statistics
  /estimated_costs, /costs   Display accumulated token usage and estimated API cost
  /session                   Display current session statistics and configuration
  /tools                     List available MCP and built-in tools
  /attach-file <path>        Attach a file (image, PDF, code, doc) to the next prompt
  /attach <path>             Alias for /attach-file
  /attach-clipboard          Attach image or text from system clipboard to the next prompt
  /paste, /clipboard         Alias for /attach-clipboard
  /attachments               List currently staged attachments
  /attach clear              Clear all staged attachments
  /system                    Display current system prompt
  /bye, /exit                Quit interactive chat
  /help, /?                  Show this help
''';

  @override
  Future<void> run() async {
    final skillPath = argResults?['skill'] as String?;
    final llmPath = argResults?['llm'] as String? ?? 'llm.yaml';
    final explicitLlmName = argResults?['llm-name'] as String?;
    final toolsPath =
        argResults?['tools'] as String? ?? 'extern_mcp_tools.yaml';
    String? autoSavePath = argResults?['save-session'] as String?;
    final loadSessionPath = argResults?['load-session'] as String?;
    final verbose = argResults?['verbose'] as bool? ?? false;
    var compactMode = argResults?['compact'] as bool? ?? true;

    final runner = SkillRunner(
      llmConfigPath: llmPath,
      toolsConfigPath: toolsPath,
      verbose: verbose,
    );

    // Resolve initial LLM config
    final targetLlm =
        explicitLlmName ??
        (llmPath != 'llm.yaml' &&
                !llmPath.endsWith('.yaml') &&
                !llmPath.endsWith('.yml') &&
                !File(llmPath).existsSync()
            ? llmPath
            : null);
    LlmConfig activeLlmConfig = runner.loadLlmConfig(targetName: targetLlm);
    String activeLlmName = targetLlm ?? 'default';

    final allProfiles = LlmConfigManager.loadAllProfiles(configPath: llmPath);
    NamedLlmProfile? activeProfile;
    for (final p in allProfiles) {
      if (p.config.model == activeLlmConfig.model &&
          p.config.provider == activeLlmConfig.provider) {
        activeLlmName = p.name;
        activeProfile = p;
        break;
      }
    }

    Future<void> ensureEmbeddedModelLoaded(NamedLlmProfile profile) async {
      if (profile.config.provider != LlmProvider.embedded) return;
      final filename = profile.config.model;
      final manager = CliEmbeddedModelManager.instance;
      final isDownloaded = await manager.isModelDownloaded(filename);

      if (!isDownloaded) {
        stdout.writeln(
          TerminalPrinter.yellow(
            '⬇ Embedded model "$filename" not found locally in ~/.tealkit/models/.',
          ),
        );
        stdout.writeln(
          TerminalPrinter.dim(
            '  Downloading from HuggingFace (${profile.repo ?? "direct URL"})...',
          ),
        );
        final spinner = TerminalProgress('Downloading model...');
        spinner.start();
        try {
          await manager.ensureModelDownloaded(
            modelFilename: filename,
            repo: profile.repo,
            directUrl: profile.config.baseUrl.isNotEmpty ? profile.config.baseUrl : null,
            onProgress: (p, status) {
              final pct = (p * 100).toStringAsFixed(1);
              spinner.start('Downloading model: $status ($pct%)');
            },
          );
          spinner.stop();
          stdout.writeln(TerminalPrinter.green('✔ Download complete: $filename'));
        } catch (e) {
          spinner.stop();
          stderr.writeln(TerminalPrinter.red('❌ Failed to download model: $e'));
          rethrow;
        }
      }

      final file = await manager.getModelFile(filename);
      stdout.writeln(TerminalPrinter.dim('  Initializing llamadart engine with: ${file.path}...'));
      await CliEmbeddedLlmAdapter.instance.initialize(
        file.path,
        gpuLayers: profile.gpuLayers ?? 0,
        contextSize: profile.contextSize ?? 4096,
      );
      CliEmbeddedLlmAdapter.instance.registerWithMcpCore();
      stdout.writeln(TerminalPrinter.green('✔ Embedded model ready for inference.'));
    }

    if (activeProfile != null && activeProfile.config.provider == LlmProvider.embedded) {
      try {
        await ensureEmbeddedModelLoaded(activeProfile);
      } catch (_) {}
    }

    var localServers = runner.loadMcpServers();

    String systemPrompt =
        'You are a helpful AI assistant. Use available tools when needed.';
    String sessionTitle = 'TealKit Interactive Agent Chat';

    if (skillPath != null) {
      try {
        final manifest = runner.parseSkillFile(skillPath);
        if (manifest.systemPrompt.trim().isNotEmpty) {
          systemPrompt = manifest.systemPrompt;
        }
        sessionTitle = 'Chat: ${manifest.name}';
      } catch (e) {
        stderr.writeln(
          TerminalPrinter.yellow(
            'Warning: Could not load skill "$skillPath": $e',
          ),
        );
      }
    }

    final conversation = <ChatMessage>[];
    final usageTracker = TokenUsageTracker();

    if (loadSessionPath != null) {
      try {
        final session = await SessionManager.loadSession(loadSessionPath);
        conversation.addAll(session.messages);
        stdout.writeln(
          TerminalPrinter.green(
            '✔ Loaded session from "$loadSessionPath" (${conversation.length} messages restored).',
          ),
        );
        autoSavePath ??= loadSessionPath;
      } catch (e) {
        stderr.writeln(
          TerminalPrinter.yellow(
            'Warning: Could not load session from "$loadSessionPath": $e',
          ),
        );
      }
    }

    TerminalPrinter.printBanner(sessionTitle, [
      'LLM Profile : $activeLlmName (${activeLlmConfig.provider.displayName} / ${activeLlmConfig.model})',
      'MCP Servers : ${localServers.length} configured',
      'Compact Mode: ${compactMode ? "ON" : "OFF"}',
      if (autoSavePath != null) 'Session File: $autoSavePath',
      'Commands    : Type /help for slash commands, /exit to quit',
    ]);

    if (conversation.isNotEmpty) {
      TerminalPrinter.renderSessionHistory(
        conversation,
        mode: 'chat',
        compact: compactMode,
      );
      stdout.writeln('');
    }

    var mcpManager = await runner.connectMcpServers(localServers);

    // Built-in tools (web_search, mermaid, toolbox, ssh)
    final builtinTools = BuiltinMcpServers.createAll();
    final allDartTools = List<McpLocalTool>.from(builtinTools);
    final dartTools = List<McpLocalTool>.from(builtinTools);

    // Track original tools per server for /mcp_enable_fnc and /mcp_reset_fnc
    final originalServerTools = <String, List<MCPTool>>{};
    for (final clientDef in mcpManager.clients) {
      originalServerTools[clientDef.label.toLowerCase()] = List<MCPTool>.from(
        clientDef.availableTools,
      );
    }
    final activeFilters = <String, Set<String>>{};

    stdout.writeln('');
    final pendingAttachments = <CliAttachment>[];
    final defaultWorkspaceDir = Directory.current.path;

    try {
      while (true) {
        final attachBadge = pendingAttachments.isNotEmpty
            ? ' (${pendingAttachments.length} att)'
            : '';
        stdout.write(TerminalPrinter.cyan('chat$attachBadge > '));
        final rawInput = stdin.readLineSync();
        if (rawInput == null) break;

        final input = rawInput.trim();
        if (input.isEmpty) continue;

        if (input == '/bye' || input == '/exit') break;
        if (input == '/help' || input == '/?') {
          stdout.writeln(_helpText);
          continue;
        }

        // ── Attachment Commands ──
        if (input.startsWith('/attach-file') ||
            (input.startsWith('/attach') && !input.startsWith('/attach-clipboard') && !input.startsWith('/attachments'))) {
          final parts = input.split(RegExp(r'\s+'));
          if (parts.length < 2) {
            stdout.writeln('Usage: /attach-file <file_path> or /attach clear');
            stdout.writeln('');
            continue;
          }

          final arg = parts.sublist(1).join(' ').trim();
          if (arg == 'clear' || arg == 'reset') {
            pendingAttachments.clear();
            stdout.writeln(TerminalPrinter.green('✔ Cleared all staged attachments.'));
            stdout.writeln('');
            continue;
          }

          try {
            final att = await CliAttachmentHelper.fromFile(arg, workspaceDir: defaultWorkspaceDir);
            pendingAttachments.add(att);
            stdout.writeln(
              TerminalPrinter.green('✔ Attached: ${att.name} (${att.mimeType}, ${att.sizeLabel})'),
            );
            if (att.isImage) {
              stdout.writeln(TerminalPrinter.dim('  (Image will be sent as multi-modal visual context)'));
            } else {
              stdout.writeln(TerminalPrinter.dim('  (Text/document content will be injected into prompt)'));
            }
          } catch (e) {
            stderr.writeln(TerminalPrinter.red('Error attaching file: $e'));
          }
          stdout.writeln('');
          continue;
        }

        if (input == '/attach-clipboard' || input == '/paste' || input == '/clipboard') {
          try {
            stdout.writeln(TerminalPrinter.dim('Checking system clipboard...'));
            final clipData = await CliClipboardHelper.getClipboardContent();
            if (clipData == null) {
              stdout.writeln(TerminalPrinter.yellow('Clipboard is empty or format unsupported.'));
            } else if (clipData.isImage && clipData.imageBytes != null) {
              final att = CliAttachmentHelper.fromBytes(
                bytes: clipData.imageBytes!,
                name: 'clipboard_image.png',
                path: clipData.imagePath ?? 'clipboard_image.png',
                mimeType: clipData.mimeType,
              );
              pendingAttachments.add(att);
              stdout.writeln(
                TerminalPrinter.green('✔ Attached image from clipboard: ${att.name} (${att.sizeLabel})'),
              );
            } else if (clipData.text != null && clipData.text!.isNotEmpty) {
              final bytes = utf8.encode(clipData.text!);
              final att = CliAttachmentHelper.fromBytes(
                bytes: bytes,
                name: 'clipboard_text.txt',
                path: 'clipboard_text.txt',
                mimeType: 'text/plain',
                textContent: clipData.text,
              );
              pendingAttachments.add(att);
              stdout.writeln(
                TerminalPrinter.green('✔ Attached text from clipboard (${clipData.text!.length} chars)'),
              );
            }
          } catch (e) {
            stderr.writeln(TerminalPrinter.red('Error accessing clipboard: $e'));
          }
          stdout.writeln('');
          continue;
        }

        if (input == '/attachments') {
          if (pendingAttachments.isEmpty) {
            stdout.writeln('No staged attachments. Use /attach-file <path> or /attach-clipboard to attach.');
          } else {
            stdout.writeln(TerminalPrinter.bold('--- Staged Attachments (${pendingAttachments.length}) ---'));
            for (int i = 0; i < pendingAttachments.length; i++) {
              final att = pendingAttachments[i];
              stdout.writeln('  [${i + 1}] ${att.name} (${att.mimeType}, ${att.sizeLabel})');
            }
            stdout.writeln(TerminalPrinter.dim('Attachments will be included with your next prompt. Use "/attach clear" to remove.'));
          }
          stdout.writeln('');
          continue;
        }

        // ── LLM Model Listing & Switching (/llm, /llm:<name>, /llm <name>) ──
        if (input.startsWith('/llm')) {
          String? target;
          if (input.startsWith('/llm:')) {
            target = input.substring(5).trim();
          } else {
            final parts = input.split(RegExp(r'\s+'));
            if (parts.length > 1) {
              target = parts.sublist(1).join(' ').trim();
            }
          }

          final profiles = LlmConfigManager.loadAllProfiles(
            configPath: llmPath,
          );

          if (target == null || target.isEmpty) {
            stdout.writeln(
              TerminalPrinter.bold('--- Configured LLM Profiles ---'),
            );
            for (final p in profiles) {
              final isCurrent =
                  (p.name == activeLlmName) ||
                  (p.config.model == activeLlmConfig.model &&
                      p.config.provider == activeLlmConfig.provider);
              final marker = isCurrent
                  ? TerminalPrinter.green('* [ACTIVE]')
                  : ' ';
              final rates = await TokenUsageTracker.getRatesAsync(p.config);
              final badgeParts = <String>[];
              if (rates?.contextWindow != null) {
                badgeParts.add(
                  TokenUsageTracker.formatContextWindow(rates!.contextWindow),
                );
              }
              if (rates != null &&
                  rates.inputPerM == 0.0 &&
                  rates.outputPerM == 0.0) {
                badgeParts.add("Free");
              } else if (rates != null) {
                badgeParts.add(
                  r"$" +
                      rates.inputPerM.toStringAsFixed(2) +
                      r"/$" +
                      rates.outputPerM.toStringAsFixed(2),
                );
              }
              final badgeStr = badgeParts.isNotEmpty
                  ? TerminalPrinter.cyan(" [${badgeParts.join(" • ")}]")
                  : "";
              stdout.writeln(
                '  $marker ${TerminalPrinter.bold(p.name.padRight(12))} : ${p.config.provider.displayName} / ${p.config.model}$badgeStr (temp: ${p.config.temperature}, max_tokens: ${p.config.maxTokens})',
              );
            }
            stdout.writeln('--------------------------------');
            stdout.writeln(
              TerminalPrinter.dim(
                'Usage: /llm <name> or /llm:<name> (e.g. /llm:ollama, /llm deepseek)',
              ),
            );
            stdout.writeln('');
            continue;
          }

          try {
            final newConfig = LlmConfigManager.resolveConfig(
              nameOrPath: target,
              configPath: llmPath,
            );
            activeLlmConfig = newConfig;
            activeLlmName = target;
            NamedLlmProfile? matchingProfile;
            for (final p in profiles) {
              if (p.name.toLowerCase() == target.toLowerCase()) {
                activeLlmName = p.name;
                matchingProfile = p;
                break;
              }
            }
            if (matchingProfile != null && matchingProfile.config.provider == LlmProvider.embedded) {
              await ensureEmbeddedModelLoaded(matchingProfile);
            }
            stdout.writeln(
              TerminalPrinter.green(
                '✔ Switched LLM to: $activeLlmName (${activeLlmConfig.provider.displayName} / ${activeLlmConfig.model})',
              ),
            );
          } catch (e) {
            stderr.writeln(TerminalPrinter.red('Error switching LLM: $e'));
          }
          stdout.writeln('');
          continue;
        }

        // ── MCP Uninstall / Remove (/uninstall <name|all_mcp>) ──
        if (input.startsWith('/uninstall')) {
          final parts = input.split(RegExp(r'\s+'));
          if (parts.length < 2) {
            stdout.writeln('Usage: /uninstall <server_name|server_id|all_mcp>');
            stdout.writeln(
              TerminalPrinter.dim(
                'Available MCP servers: ${localServers.map((s) => s.name).join(", ")}',
              ),
            );
            stdout.writeln('');
            continue;
          }

          final target = parts.sublist(1).join(' ').trim();
          stdout.writeln(
            TerminalPrinter.bold(
              'Uninstalling MCP server(s) matching "$target"...',
            ),
          );
          final results = await McpManagerHelper.uninstallServers(
            targetQuery: target,
            configuredServers: localServers,
            mcpManager: mcpManager,
            verbose: verbose,
          );

          if (results.isNotEmpty) {
            final tools = mcpManager.availableTools;
            stdout.writeln(
              TerminalPrinter.green(
                '✔ MCP server uninstalled. Remaining MCP tools: ${tools.length} (${tools.map((t) => t.name).join(", ")})',
              ),
            );
          }
          stdout.writeln('');
          continue;
        }

        if (input.startsWith('/install')) {
          final parts = input.split(RegExp(r'\s+'));
          if (parts.length < 2) {
            stdout.writeln('Usage: /install <server_name|server_id|all_mcp>');
            stdout.writeln(
              TerminalPrinter.dim(
                'Configured MCP servers: ${localServers.map((s) => s.name).join(", ")}',
              ),
            );
            stdout.writeln('');
            continue;
          }

          final target = parts.sublist(1).join(' ').trim();
          stdout.writeln(
            TerminalPrinter.bold(
              'Installing / loading MCP server(s) matching "$target"...',
            ),
          );
          final results = await McpManagerHelper.installServers(
            targetQuery: target,
            configuredServers: localServers,
            mcpManager: mcpManager,
            verbose: verbose,
          );

          if (results.any((r) => r.success)) {
            final tools = mcpManager.availableTools;
            stdout.writeln(
              TerminalPrinter.green(
                '✔ MCP server ready. Active MCP tools: ${tools.length} (${tools.map((t) => t.name).join(", ")})',
              ),
            );
          }
          stdout.writeln('');
          continue;
        }

        // ── MCP Inspect: /mcp_inspect [server_name] ──
        if (input.startsWith('/mcp_inspect')) {
          final parts = input.split(RegExp(r'\s+'));
          final serverQuery = parts.length > 1
              ? parts[1].trim().toLowerCase()
              : null;

          stdout.writeln(
            TerminalPrinter.bold('--- MCP Function & Schema Inspector ---'),
          );

          // 1. External MCP Servers
          bool foundAny = false;
          for (final clientDef in mcpManager.clients) {
            final sName = clientDef.label;
            if (serverQuery != null &&
                !sName.toLowerCase().contains(serverQuery) &&
                !clientDef.name.toLowerCase().contains(serverQuery)) {
              continue;
            }
            foundAny = true;
            final original =
                originalServerTools[sName.toLowerCase()] ??
                originalServerTools[clientDef.name.toLowerCase()] ??
                clientDef.availableTools;
            final activeSet =
                activeFilters[sName.toLowerCase()] ??
                activeFilters[clientDef.name.toLowerCase()];
            final filterBadge = activeSet != null
                ? TerminalPrinter.yellow(
                    ' [RESTRICTED: ${activeSet.length}/${original.length} tools visible]',
                  )
                : TerminalPrinter.green(
                    ' [ALL ${original.length} tools active]',
                  );

            stdout.writeln(
              '\n${TerminalPrinter.bold("● External Server:")} ${TerminalPrinter.cyan(sName)}$filterBadge',
            );
            final isLocal = clientDef.client is LocalMCPClient;
            stdout.writeln(
              '  Transport: ${isLocal ? "stdio (${clientDef.url})" : "remote (${clientDef.url})"}',
            );

            for (final tool in original) {
              final isEnabled =
                  activeSet == null || activeSet.contains(tool.name);
              final statusIcon = isEnabled
                  ? TerminalPrinter.green('✔')
                  : TerminalPrinter.red('✖ (hidden)');
              stdout.writeln(
                '  $statusIcon ${TerminalPrinter.bold(tool.name)}: ${tool.description ?? "(no description)"}',
              );
              if (tool.inputSchema != null &&
                  (tool.inputSchema as Map).isNotEmpty) {
                final schemaStr = jsonEncode(tool.inputSchema);
                final preview = schemaStr.length > 120
                    ? '${schemaStr.substring(0, 117)}...'
                    : schemaStr;
                stdout.writeln(
                  '      ${TerminalPrinter.dim("Schema: $preview")}',
                );
              }
            }
          }

          // 2. Built-in Tools (web_search, mermaid, toolbox, ssh)
          final builtinGroups = <String, List<McpLocalTool>>{
            'web_search': [BuiltinMcpServers.createWebSearchTool()],
            'mermaid': [BuiltinMcpServers.createMermaidTool()],
            'toolbox': BuiltinMcpServers.createToolboxTools(),
            'ssh': BuiltinMcpServers.createSshTools(),
          };

          for (final entry in builtinGroups.entries) {
            final bName = entry.key;
            if (serverQuery != null &&
                !bName.toLowerCase().contains(serverQuery)) {
              continue;
            }
            foundAny = true;
            final bTools = entry.value;
            final activeSet = activeFilters[bName.toLowerCase()];
            final filterBadge = activeSet != null
                ? TerminalPrinter.yellow(
                    ' [RESTRICTED: ${activeSet.length}/${bTools.length} tools visible]',
                  )
                : TerminalPrinter.green(' [ALL ${bTools.length} tools active]');

            stdout.writeln(
              '\n${TerminalPrinter.bold("● Built-in Server:")} ${TerminalPrinter.cyan(bName)}$filterBadge',
            );
            stdout.writeln('  Integration: Native TealKit Tool');

            for (final tool in bTools) {
              final isEnabled =
                  activeSet == null || activeSet.contains(tool.name);
              final statusIcon = isEnabled
                  ? TerminalPrinter.green('✔')
                  : TerminalPrinter.red('✖ (hidden)');
              stdout.writeln(
                '  $statusIcon ${TerminalPrinter.bold(tool.name)}: ${tool.description}',
              );
              final schemaStr = jsonEncode(tool.inputSchema);
              final preview = schemaStr.length > 120
                  ? '${schemaStr.substring(0, 117)}...'
                  : schemaStr;
              stdout.writeln(
                '      ${TerminalPrinter.dim("Schema: $preview")}',
              );
            }
          }

          if (!foundAny) {
            stdout.writeln(
              'No MCP server or built-in service found matching "$serverQuery".',
            );
            stdout.writeln(
              TerminalPrinter.dim(
                'Available: ${[...mcpManager.clients.map((c) => c.label), ...builtinGroups.keys].join(", ")}',
              ),
            );
          }

          stdout.writeln('----------------------------------------');
          stdout.writeln(
            TerminalPrinter.dim(
              'Tip: Use /mcp_enable_fnc <server> <tool1,tool2> to restrict visible functions.',
            ),
          );
          stdout.writeln(
            TerminalPrinter.dim(
              '     Use /mcp_reset_fnc [server] to restore all functions.',
            ),
          );
          stdout.writeln('');
          continue;
        }

        // ── MCP Enable Function: /mcp_enable_fnc <server> <tool1,tool2,...> ──
        if (input.startsWith('/mcp_enable_fnc') ||
            input.startsWith('/mcp_enable')) {
          final parts = input.split(RegExp(r'\s+'));
          if (parts.length < 3) {
            stdout.writeln(
              'Usage: /mcp_enable_fnc <server_name> <func1,func2,...>',
            );
            stdout.writeln('Example: /mcp_enable_fnc fetch fetch');
            stdout.writeln(
              'Example: /mcp_enable_fnc toolbox calculate,get_current_time',
            );
            stdout.writeln('');
            continue;
          }

          final serverName = parts[1].trim().toLowerCase();
          final rawFuncs = parts.sublist(2).join(',').split(',');
          final allowedTools = rawFuncs
              .map((f) => f.trim())
              .where((f) => f.isNotEmpty)
              .toSet();

          bool applied = false;

          // Check external MCP servers
          for (final clientDef in mcpManager.clients) {
            final label = clientDef.label.toLowerCase();
            final idName = clientDef.name.toLowerCase();
            if (label == serverName ||
                label.contains(serverName) ||
                idName == serverName ||
                idName.contains(serverName)) {
              final orig =
                  originalServerTools[label] ??
                  originalServerTools[idName] ??
                  clientDef.availableTools;
              final filtered = orig
                  .where((t) => allowedTools.contains(t.name))
                  .toList();
              if (filtered.isEmpty) {
                stdout.writeln(
                  TerminalPrinter.yellow(
                    'Warning: None of [${allowedTools.join(", ")}] match tools in server "${clientDef.label}".',
                  ),
                );
                stdout.writeln(
                  TerminalPrinter.dim(
                    'Available in ${clientDef.label}: ${orig.map((t) => t.name).join(", ")}',
                  ),
                );
              } else {
                clientDef.cachedTools = filtered;
                activeFilters[label] = allowedTools;
                activeFilters[idName] = allowedTools;
                stdout.writeln(
                  TerminalPrinter.green(
                    '✔ Server "${clientDef.label}" restricted to [${filtered.map((t) => t.name).join(", ")}] until /bye or reset.',
                  ),
                );
                applied = true;
              }
            }
          }

          // Check built-in servers (web_search, mermaid, toolbox, ssh)
          final builtinGroups = <String, List<McpLocalTool>>{
            'web_search': [BuiltinMcpServers.createWebSearchTool()],
            'mermaid': [BuiltinMcpServers.createMermaidTool()],
            'toolbox': BuiltinMcpServers.createToolboxTools(),
            'ssh': BuiltinMcpServers.createSshTools(),
          };

          for (final entry in builtinGroups.entries) {
            final bName = entry.key;
            if (bName.toLowerCase() == serverName ||
                bName.toLowerCase().contains(serverName)) {
              final orig = entry.value;
              final matched = orig
                  .where((t) => allowedTools.contains(t.name))
                  .toList();
              if (matched.isEmpty) {
                stdout.writeln(
                  TerminalPrinter.yellow(
                    'Warning: None of [${allowedTools.join(", ")}] match tools in built-in "$bName".',
                  ),
                );
                stdout.writeln(
                  TerminalPrinter.dim(
                    'Available in $bName: ${orig.map((t) => t.name).join(", ")}',
                  ),
                );
              } else {
                activeFilters[bName.toLowerCase()] = allowedTools;
                // Recompute dartTools
                dartTools.clear();
                for (final bEntry in builtinGroups.entries) {
                  final bFilter = activeFilters[bEntry.key.toLowerCase()];
                  if (bFilter != null) {
                    dartTools.addAll(
                      bEntry.value.where((t) => bFilter.contains(t.name)),
                    );
                  } else {
                    dartTools.addAll(bEntry.value);
                  }
                }
                stdout.writeln(
                  TerminalPrinter.green(
                    '✔ Built-in "$bName" restricted to [${matched.map((t) => t.name).join(", ")}] until /bye or reset.',
                  ),
                );
                applied = true;
              }
            }
          }

          if (!applied) {
            stdout.writeln(
              TerminalPrinter.red('Error: Server "$serverName" not found.'),
            );
            stdout.writeln(
              TerminalPrinter.dim(
                'Available servers: ${[...mcpManager.clients.map((c) => c.label), ...builtinGroups.keys].join(", ")}',
              ),
            );
          }
          stdout.writeln('');
          continue;
        }

        // ── MCP Reset Functions: /mcp_reset_fnc [server] ──
        if (input.startsWith('/mcp_reset_fnc') ||
            input.startsWith('/mcp_reset')) {
          final parts = input.split(RegExp(r'\s+'));
          final serverQuery = parts.length > 1
              ? parts[1].trim().toLowerCase()
              : null;

          final builtinGroups = <String, List<McpLocalTool>>{
            'web_search': [BuiltinMcpServers.createWebSearchTool()],
            'mermaid': [BuiltinMcpServers.createMermaidTool()],
            'toolbox': BuiltinMcpServers.createToolboxTools(),
            'ssh': BuiltinMcpServers.createSshTools(),
          };

          if (serverQuery == null || serverQuery == 'all') {
            // Reset all external
            for (final clientDef in mcpManager.clients) {
              final orig =
                  originalServerTools[clientDef.label.toLowerCase()] ??
                  originalServerTools[clientDef.name.toLowerCase()];
              if (orig != null) {
                clientDef.cachedTools = List<MCPTool>.from(orig);
              }
            }
            activeFilters.clear();

            // Reset all built-in
            dartTools.clear();
            dartTools.addAll(allDartTools);

            stdout.writeln(
              TerminalPrinter.green(
                '✔ All MCP tool filters reset. All tools restored to active visibility.',
              ),
            );
          } else {
            bool resetFound = false;
            // Reset specific external
            for (final clientDef in mcpManager.clients) {
              final label = clientDef.label.toLowerCase();
              final idName = clientDef.name.toLowerCase();
              if (label == serverQuery ||
                  label.contains(serverQuery) ||
                  idName == serverQuery ||
                  idName.contains(serverQuery)) {
                final orig =
                    originalServerTools[label] ?? originalServerTools[idName];
                if (orig != null) {
                  clientDef.cachedTools = List<MCPTool>.from(orig);
                }
                activeFilters.remove(label);
                activeFilters.remove(idName);
                stdout.writeln(
                  TerminalPrinter.green(
                    '✔ Server "${clientDef.label}" filters reset. All ${orig?.length ?? 0} tools restored.',
                  ),
                );
                resetFound = true;
              }
            }

            // Reset specific built-in
            for (final entry in builtinGroups.entries) {
              if (entry.key.toLowerCase() == serverQuery ||
                  entry.key.toLowerCase().contains(serverQuery)) {
                activeFilters.remove(entry.key.toLowerCase());
                dartTools.clear();
                for (final bEntry in builtinGroups.entries) {
                  final bFilter = activeFilters[bEntry.key.toLowerCase()];
                  if (bFilter != null) {
                    dartTools.addAll(
                      bEntry.value.where((t) => bFilter.contains(t.name)),
                    );
                  } else {
                    dartTools.addAll(bEntry.value);
                  }
                }
                stdout.writeln(
                  TerminalPrinter.green(
                    '✔ Built-in "${entry.key}" filters reset. All ${entry.value.length} tools restored.',
                  ),
                );
                resetFound = true;
              }
            }

            if (!resetFound) {
              stdout.writeln(
                TerminalPrinter.red(
                  'Error: Server "$serverQuery" not found to reset.',
                ),
              );
            }
          }
          stdout.writeln('');
          continue;
        }

        // ── Session Management: /save-session, /load-session, /clear-session, /session ──
        if (input.startsWith('/save-session') || input.startsWith('/save')) {
          final parts = input.split(RegExp(r'\s+'));
          String targetPath;
          if (parts.length > 1) {
            targetPath = parts.sublist(1).join(' ').trim();
          } else if (autoSavePath != null) {
            targetPath = autoSavePath;
          } else {
            final timestamp = DateTime.now()
                .toIso8601String()
                .replaceAll(':', '-')
                .split('.')
                .first;
            targetPath = 'chat-session-$timestamp.json';
          }

          try {
            final session = SessionData(
              id: DateTime.now().millisecondsSinceEpoch.toString(),
              title: 'TealKit Chat Session',
              mode: 'chat',
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
              llmName: activeLlmName,
              llmProvider: activeLlmConfig.provider.displayName,
              llmModel: activeLlmConfig.model,
              messages: conversation,
            );
            final savedFile = await SessionManager.saveSession(
              session,
              targetPath,
            );
            autoSavePath = savedFile.path;
            stdout.writeln(
              TerminalPrinter.green(
                '✔ Session saved successfully to "${savedFile.path}" (${conversation.length} messages recorded).',
              ),
            );
          } catch (e) {
            stderr.writeln(TerminalPrinter.red('Error saving session: $e'));
          }
          stdout.writeln('');
          continue;
        }

        if (input.startsWith('/load-session') || input.startsWith('/load')) {
          final parts = input.split(RegExp(r'\s+'));
          if (parts.length < 2) {
            stdout.writeln('Usage: /load-session <path-to-session.json-or-md>');
            stdout.writeln('');
            continue;
          }

          final targetPath = parts.sublist(1).join(' ').trim();
          try {
            final session = await SessionManager.loadSession(targetPath);
            conversation.clear();
            conversation.addAll(session.messages);
            autoSavePath = targetPath;
            stdout.writeln(
              TerminalPrinter.green(
                '✔ Restored session from "$targetPath" (${conversation.length} messages loaded).',
              ),
            );
            stdout.writeln('');
            TerminalPrinter.renderSessionHistory(
              conversation,
              mode: 'chat',
              compact: compactMode,
            );
          } catch (e) {
            stderr.writeln(TerminalPrinter.red('Error loading session: $e'));
          }
          stdout.writeln('');
          continue;
        }

        if (input.startsWith('/compact')) {
          final parts = input.split(RegExp(r'\s+'));
          if (parts.length > 1) {
            final arg = parts[1].toLowerCase();
            if (arg == 'on' || arg == 'true' || arg == '1' || arg == 'enable') {
              compactMode = true;
              stdout.writeln(
                TerminalPrinter.green(
                  '✔ Compact mode enabled (file contents hidden when reading, showing filename only).',
                ),
              );
            } else if (arg == 'off' || arg == 'false' || arg == '0' || arg == 'disable') {
              compactMode = false;
              stdout.writeln(
                TerminalPrinter.yellow(
                  '✔ Compact mode disabled (file read contents will be displayed).',
                ),
              );
            } else if (arg == 'status') {
              stdout.writeln(
                'Compact mode is currently: ${compactMode ? TerminalPrinter.green("ON") : TerminalPrinter.yellow("OFF")}',
              );
            } else {
              stdout.writeln('Usage: /compact on | off');
            }
          } else {
            compactMode = !compactMode;
            stdout.writeln(
              compactMode
                  ? TerminalPrinter.green(
                      '✔ Compact mode enabled (file contents hidden when reading, showing filename only).',
                    )
                  : TerminalPrinter.yellow(
                      '✔ Compact mode disabled (file read contents will be displayed).',
                    ),
            );
          }
          stdout.writeln('');
          continue;
        }

        if (input == '/clear-session' || input == '/clear') {
          conversation.clear();
          usageTracker.reset();
          stdout.writeln(
            TerminalPrinter.dim(
              'Conversation history and token/cost statistics cleared.',
            ),
          );
          stdout.writeln('');
          continue;
        }

        if (input == '/estimated_costs' ||
            input == '/costs' ||
            input == '/cost' ||
            input == '/tokens' ||
            input == '/usage') {
          stdout.writeln(
            await usageTracker.formatReportAsync(
              activeLlmConfig,
              modelDisplayName: activeLlmName,
            ),
          );
          stdout.writeln('');
          continue;
        }

        if (input == '/session') {
          final rates = await TokenUsageTracker.getRatesAsync(activeLlmConfig);
          final estCost = usageTracker.calculateEstimatedCost(
            activeLlmConfig,
            rates: rates,
          );
          final costStr = estCost != null
              ? 'est. \$${estCost.toStringAsFixed(6)}'
              : 'cost N/A';

          stdout.writeln(TerminalPrinter.bold('--- Session Information ---'));
          stdout.writeln(
            '  Active LLM       : $activeLlmName (${activeLlmConfig.provider.displayName} / ${activeLlmConfig.model})',
          );
          stdout.writeln('  History Messages : ${conversation.length}');
          stdout.writeln('  Compact Mode     : ${compactMode ? "ON" : "OFF"}');
          stdout.writeln(
            '  Tokens Tracked   : ${usageTracker.totalTokens} ($costStr)',
          );
          stdout.writeln(
            '  Auto-Save File   : ${autoSavePath ?? "(not set, use /save-session <path>)"}',
          );
          stdout.writeln('---------------------------');
          stdout.writeln('');
          continue;
        }

        if (input == '/tools') {
          if (dartTools.isNotEmpty) {
            stdout.writeln(
              TerminalPrinter.bold(
                'Built-in TealKit Tools (${dartTools.length}):',
              ),
            );
            for (final t in dartTools) {
              stdout.writeln(
                '  • ${TerminalPrinter.cyan(t.name)} (${t.riskLevel.name}) — ${t.description}',
              );
            }
            stdout.writeln('');
          }
          final tools = mcpManager.availableTools;
          if (tools.isEmpty) {
            stdout.writeln('No external MCP tools connected.');
            stdout.writeln(
              TerminalPrinter.dim(
                'Tip: Check mcp.yaml or run with "tealkit chat --verbose" for diagnostics.',
              ),
            );
          } else {
            stdout.writeln(
              TerminalPrinter.bold('External MCP Tools (${tools.length}):'),
            );
            for (final t in tools) {
              stdout.writeln(
                '  • ${TerminalPrinter.green(t.name)} — ${t.description ?? "(no description)"}',
              );
            }
          }
          stdout.writeln('');
          continue;
        }

        if (input == '/system') {
          stdout.writeln(TerminalPrinter.bold('System prompt:'));
          stdout.writeln(systemPrompt);
          stdout.writeln('');
          continue;
        }

        // ── Process Staged Attachments ──
        final effectivePromptBuffer = StringBuffer();
        final messageAttachments = <MessageAttachment>[];

        if (pendingAttachments.isNotEmpty) {
          effectivePromptBuffer.writeln('User Attachments:');
          for (final att in pendingAttachments) {
            if (att.isImage) {
              effectivePromptBuffer.writeln('- [Image Attachment: ${att.name}] (${att.mimeType}, ${att.sizeLabel})');
              messageAttachments.add(att.toMessageAttachment());
            } else {
              effectivePromptBuffer.writeln('\n[Attached File: ${att.name}]');
              effectivePromptBuffer.writeln('--- CONTENT START ---');
              effectivePromptBuffer.writeln(att.extractedText ?? '[Binary/unreadable file content: ${att.sizeLabel}]');
              effectivePromptBuffer.writeln('--- CONTENT END ---\n');
            }
          }
          effectivePromptBuffer.writeln('\nMessage:');
        }
        effectivePromptBuffer.write(input);
        final effectivePromptText = effectivePromptBuffer.toString();

        final cliMaxToolIterations = int.tryParse(
          argResults?['max-tool-iterations'] as String? ?? '',
        );

        final initialTurnMessages = <ChatMessage>[...conversation];
        if (messageAttachments.isNotEmpty) {
          initialTurnMessages.add(
            ChatMessage(
              id: 'turn_att_${DateTime.now().millisecondsSinceEpoch}',
              content: effectivePromptText,
              role: ChatRole.user,
              timestamp: DateTime.now(),
              attachments: messageAttachments,
            ),
          );
        }

        final agent = Agent(
          key: 'chat_agent',
          name: 'Chat Agent',
          llmConfig: activeLlmConfig,
          systemPrompt: systemPrompt,
          prompts: messageAttachments.isNotEmpty
              ? [const SubPromptStep(text: '')]
              : [SubPromptStep(text: effectivePromptText)],
          dartTools: dartTools,
          localServers: [],
          initialMessages: initialTurnMessages,
          maxToolIterations: cliMaxToolIterations,
        );

        final engine = McpAgentEngine();
        engine.setAgents([agent]);

        bool turnSuccess = false;
        String lastAssistantResponse = '';
        final spinner = TerminalProgress('Thinking...');
        spinner.start();

        try {
          final subscription = engine.agentEvents.listen((event) {
            switch (event) {
              case AgentLogEvent(:final message):
                if (verbose) {
                  spinner.clear();
                  stdout.writeln(TerminalPrinter.dim('[log] $message'));
                  spinner.start('Thinking...');
                }
              case AgentToolResultEvent(
                :final toolName,
                :final parameters,
                :final result,
              ):
                spinner.clear();
                TerminalPrinter.printToolCall(
                  toolName: toolName,
                  argumentsJson: jsonEncode(parameters),
                  result: result,
                  compact: compactMode,
                );
                spinner.start('Thinking...');
              case AgentAssistantResultEvent(:final response):
                spinner.clear();
                lastAssistantResponse = response;
                stdout.writeln('');
                stdout.writeln(response.trim());
                stdout.writeln('');
              case AgentErrorEvent(:final error):
                spinner.clear();
                stderr.writeln(TerminalPrinter.red('❌ ERROR: $error'));
              case AgentFinalResultEvent(:final response, :final messages):
                spinner.stop();
                if (response.isNotEmpty) {
                  lastAssistantResponse = response;
                }
                if (messages.isNotEmpty) {
                  conversation.clear();
                  conversation.addAll(messages);
                }
              case AgentUsageEvent(
                :final promptTokens,
                :final completionTokens,
              ):
                usageTracker.recordUsage(
                  prompt: promptTokens,
                  completion: completionTokens,
                );
              case AgentTextChunkEvent():
                spinner.clear();
                break;
            }
          });

          try {
            await engine.run(agent.key, mcpManager: mcpManager);
            turnSuccess = true;
          } catch (e, stack) {
            spinner.stop();
            stderr.writeln('');
            stderr.writeln(
              TerminalPrinter.red('❌ Execution Error during turn:'),
            );
            stderr.writeln(TerminalPrinter.yellow('   $e'));
            if (e.toString().contains('400') ||
                e.toString().contains('context_length') ||
                e.toString().contains('max_tokens')) {
              stderr.writeln(
                TerminalPrinter.dim(
                  '   Tip: The model returned a request error. Check max_tokens or use /clear-session to reset history.',
                ),
              );
            }
            if (verbose) {
              stderr.writeln(TerminalPrinter.dim('\nStacktrace:\n$stack'));
            } else {
              stderr.writeln(
                TerminalPrinter.dim(
                  '   (Run with --verbose for complete debug logs)',
                ),
              );
            }
          } finally {
            spinner.stop();
            await Future.delayed(const Duration(milliseconds: 50));
            await subscription.cancel();
          }
        } finally {
          await engine.dispose();
        }

        if (turnSuccess) {
          if (conversation.isEmpty) {
            conversation.add(
              ChatMessage(
                id: DateTime.now().millisecondsSinceEpoch.toString(),
                content: input,
                role: ChatRole.user,
                timestamp: DateTime.now(),
              ),
            );
            if (lastAssistantResponse.isNotEmpty) {
              conversation.add(
                ChatMessage(
                  id: (DateTime.now().millisecondsSinceEpoch + 1).toString(),
                  content: lastAssistantResponse,
                  role: ChatRole.assistant,
                  timestamp: DateTime.now(),
                ),
              );
            }
          }
          pendingAttachments.clear();

          if (autoSavePath != null) {
            try {
              final session = SessionData(
                id: DateTime.now().millisecondsSinceEpoch.toString(),
                title: 'TealKit Chat Session',
                mode: 'chat',
                createdAt: DateTime.now(),
                updatedAt: DateTime.now(),
                llmName: activeLlmName,
                llmProvider: activeLlmConfig.provider.displayName,
                llmModel: activeLlmConfig.model,
                messages: conversation,
              );
              await SessionManager.saveSession(session, autoSavePath);
            } catch (_) {}
          }
        }
      }
    } finally {
      stdout.writeln('');
      stdout.writeln('Disconnecting MCP servers...');
      await mcpManager.disconnectAll();
      mcpManager.dispose();
      stdout.writeln(TerminalPrinter.green('Goodbye!'));
    }
  }
}
