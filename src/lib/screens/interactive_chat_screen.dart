import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';


import '../config/app_theme.dart';
import '../models/mcp_models.dart';
import '../providers/active_task_provider.dart';
import '../providers/server_mode_provider.dart';
import '../services/chat_service.dart';
import '../widgets/multimedia_input_widget.dart';
import '../widgets/multimedia_message_widget.dart';
import '../widgets/sftp_explorer_dialog.dart';
import 'js_tool_library_screen.dart';
import 'local_shell_tool_library_screen.dart';
import 'script_library_screen.dart';
import '../l10n/app_localizations.dart';

/// Interactive chat screen for testing a task configuration before scheduling.
///
/// Reads all state (task, MCP manager, ChatService) from the Riverpod
/// [activeTaskProvider], which must be populated via `setTask()` before
/// navigating here.
class InteractiveChatScreen extends ConsumerStatefulWidget {
  const InteractiveChatScreen({super.key});

  @override
  ConsumerState<InteractiveChatScreen> createState() => _InteractiveChatScreenState();
}

class _InteractiveChatScreenState extends ConsumerState<InteractiveChatScreen> {
  final List<ChatMessage> _messages = [];
  StreamSubscription<List<ChatMessage>>? _messagesSubscription;
  StreamSubscription<String>? _errorSubscription;
  bool _subscribedToChat = false;

  @override
  void dispose() {
    _messagesSubscription?.cancel();
    _errorSubscription?.cancel();
    super.dispose();
  }

  /// Subscribe to the ChatService streams once it becomes available.
  void _subscribeToChatService(ChatService chatService) {
    if (_subscribedToChat) return;
    _subscribedToChat = true;

    _messagesSubscription = chatService.messagesStream.listen((msgs) {
      if (mounted) {
        setState(
          () => _messages
            ..clear()
            ..addAll(msgs),
        );
      }
    });
    _errorSubscription = chatService.errorNotificationStream.listen((err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err), backgroundColor: AppTheme.error));
      }
    });

    // Auto-start prompt sequence if there are no messages yet!
    if (chatService.messages.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final taskState = ref.read(activeTaskProvider);
        if (taskState != null && chatService.messages.isEmpty) {
          chatService.sendChatMessage(ChatMessage(
            id: const Uuid().v4(),
            content: taskState.task.prompt,
            role: ChatRole.user,
            timestamp: DateTime.now(),
          ));
        }
      });
    }
  }

  void _onSendMessage(ChatMessage message, ChatService chatService) {
    chatService.sendChatMessage(message);
  }

  Future<void> _resetChatSession(ActiveTaskState taskState) async {
    final chatService = taskState.chatService;
    if (chatService == null) return;

    await chatService.resetConversation();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L.of(context).chatSessionReset)));

    // Auto-restart prompt sequence after reset!
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (chatService.messages.isEmpty) {
        chatService.sendChatMessage(ChatMessage(
          id: const Uuid().v4(),
          content: taskState.task.prompt,
          role: ChatRole.user,
          timestamp: DateTime.now(),
        ));
      }
    });
  }

  void _showToolsDialog(ActiveTaskState taskState) {
    final l = L.of(context);
    final tools = List<MCPTool>.from(taskState.mcpManager?.availableTools ?? const <MCPTool>[])..sort((a, b) => a.name.compareTo(b.name));
    var filter = '';

    showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final filteredTools = tools.where((tool) {
              final q = filter.trim().toLowerCase();
              if (q.isEmpty) return true;
              final haystack = '${tool.name} ${tool.description ?? ''}'.toLowerCase();
              return haystack.contains(q);
            }).toList();

            return AlertDialog(
              title: Text(l.interactiveToolsAvailable(taskState.toolCount)),
              content: SizedBox(
                width: 640,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      decoration: InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: L.of(context).filterToolsHint,
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (value) => setDialogState(() => filter = value),
                    ),
                    const SizedBox(height: 12),
                    if (filteredTools.isEmpty)
                      Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: Text(l.interactiveNoTools))
                    else
                      Flexible(
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: filteredTools.length,
                          separatorBuilder: (_, _) => const Divider(height: 16),
                          itemBuilder: (context, index) {
                            final tool = filteredTools[index];
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SelectableText(tool.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                                if ((tool.description ?? '').trim().isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(tool.description!.trim(), style: Theme.of(context).textTheme.bodySmall),
                                ],
                              ],
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
              actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l.close))],
            );
          },
        );
      },
    );
  }

  void _showSystemPromptDialog(String prompt) {
    final l = L.of(context);
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;
    final dialogWidth = screenWidth > 800 ? 680.0 : screenWidth * 0.95;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        insetPadding: EdgeInsets.symmetric(horizontal: screenWidth * 0.02, vertical: 24),
        title: Text(l.interactiveSystemPromptLocked),
        content: SizedBox(
          width: dialogWidth,
          height: screenHeight * 0.7, // Add explicit height to make scrollable
          child: SingleChildScrollView(child: SelectableText(prompt)),
        ),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l.close))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final theme = Theme.of(context);
    final taskState = ref.watch(activeTaskProvider);

    // Guard: no active task
    if (taskState == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l.interactiveModeTitle)),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.warning_amber_rounded, size: 64, color: theme.colorScheme.error),
              const SizedBox(height: 16),
              Text(l.noActiveTask, style: theme.textTheme.bodyLarge, textAlign: TextAlign.center),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.arrow_back),
                label: Text(L.of(context).close),
              ),
            ],
          ),
        ),
      );
    }

    // Subscribe to chat service when it becomes available
    if (taskState.chatService != null) {
      _subscribeToChatService(taskState.chatService!);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(l.interactiveModeTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.restart_alt),
            tooltip: l.resetChatSessionTooltip,
            onPressed: taskState.chatService == null ? null : () => _resetChatSession(taskState),
          ),
          if (taskState.task.internalMcps.any((m) => m.mcpType == 'ssh' && m.enabled)) ...[
            IconButton(
              icon: const Icon(Icons.terminal),
              tooltip: l.scriptLibraryTooltip,
              onPressed: () => ScriptLibraryScreen.show(context),
            ),
            if (taskState.mcpManager != null)
              IconButton(
                icon: const Icon(Icons.folder_open),
                tooltip: 'SFTP Explorer',
                onPressed: () => SftpExplorerDialog.show(
                  context,
                  taskState.mcpManager!,
                  isServerMode: ref.read(serverModeProvider).value?.isRemote ?? false,
                ),
              ),
          ],
          if (taskState.task.internalMcps.any((m) => m.mcpType == 'js_bridge' && m.enabled))
            IconButton(
              icon: const Icon(Icons.javascript),
              tooltip: 'JavaScript Tool Library',
              onPressed: () => JsToolLibraryScreen.show(context),
            ),
          if (taskState.task.internalMcps.any((m) => m.mcpType == 'local_shell' && m.enabled))
            IconButton(
              icon: const Icon(Icons.terminal),
              tooltip: 'Local Shell Script Library',
              onPressed: () => LocalShellToolLibraryScreen.show(context),
            ),
          if (taskState.toolCount > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: ActionChip(
                avatar: const Icon(Icons.build, size: 16),
                label: Text('${taskState.toolCount}'),
                visualDensity: VisualDensity.compact,
                onPressed: () => _showToolsDialog(taskState),
              ),
            ),
        ],
      ),
      body: taskState.hasError
          ? _buildErrorState(theme, taskState.error!)
          : taskState.isInitializing
          ? _buildLoadingState(theme, taskState)
          : _buildChatBody(theme, taskState),
    );
  }

  Widget _buildErrorState(ThemeData theme, String error) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 64, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text(error, textAlign: TextAlign.center, style: theme.textTheme.bodyLarge),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back),
              label: Text(L.of(context).close),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingState(ThemeData theme, ActiveTaskState taskState) {
    // Show which phase we are in
    final phaseLabel = switch (taskState.phase) {
      ActiveTaskPhase.configuringLlm => L.of(context).phaseConfiguringLlm,
      ActiveTaskPhase.connectingExternalMcp => L.of(context).phaseConnectingExternalMcp,
      ActiveTaskPhase.connectingInternalMcp => L.of(context).phaseConnectingInternalMcp,
      _ => taskState.statusMessage,
    };

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 24),
          Text(phaseLabel, style: theme.textTheme.bodyLarge),
          if (taskState.loadingProgress != null) ...[
            const SizedBox(height: 16),
            SizedBox(
              width: 240,
              // llamadart gives no intermediate callbacks — show indeterminate
              // bar at 0% so it doesn't look permanently frozen.
              child: LinearProgressIndicator(value: taskState.loadingProgress! > 0.0 ? taskState.loadingProgress : null),
            ),
            const SizedBox(height: 8),
            Text(
              taskState.loadingProgress! > 0.0
                  ? L.of(context).loadingModelProgress((taskState.loadingProgress! * 100).round())
                  : L.of(context).loadingModelProgress(0).replaceFirst('0%', '…'),
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildChatBody(ThemeData theme, ActiveTaskState taskState) {
    final l = L.of(context);
    final chatService = taskState.chatService!;
    final effectiveSystemPrompt = taskState.effectiveSystemPrompt;

    return Column(
      children: [
        // System prompt info bar
        if (effectiveSystemPrompt != null && effectiveSystemPrompt.isNotEmpty)
          Material(
            color: theme.colorScheme.primaryContainer.withAlpha(80),
            child: InkWell(
              onTap: () => _showSystemPromptDialog(effectiveSystemPrompt),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    Icon(Icons.lock_outline, size: 16, color: theme.colorScheme.onPrimaryContainer),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l.interactiveSystemPromptLocked,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onPrimaryContainer),
                      ),
                    ),
                    Icon(Icons.info_outline, size: 16, color: theme.colorScheme.onPrimaryContainer),
                  ],
                ),
              ),
            ),
          ),

        // Messages list
        Expanded(
          child: _messages.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.chat_bubble_outline, size: 64, color: theme.colorScheme.outline),
                        const SizedBox(height: 16),
                        Text(
                          l.interactiveReady,
                          style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.outline),
                          textAlign: TextAlign.center,
                        ),
                        if (taskState.toolCount == 0) ...[
                          const SizedBox(height: 8),
                          Text(l.interactiveNoTools, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
                        ],
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  itemCount: _messages.length,
                  itemBuilder: (context, index) {
                    final message = _messages[_messages.length - 1 - index];
                    final isUser = message.role == ChatRole.user;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: MultimediaMessageWidget(message: message, isUser: isUser, enableHorizontalScrolling: true),
                    );
                  },
                ),
        ),

        // Input area
        MultimediaInputWidget(
          chatService: chatService,
          onSendMessage: (msg) => _onSendMessage(msg, chatService),
          isEnabled: !chatService.isProcessing,
          initialText: null,
        ),
      ],
    );
  }
}
