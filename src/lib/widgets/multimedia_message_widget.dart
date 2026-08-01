import 'dart:convert';
import 'dart:math' as math;
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:mime/mime.dart';
import 'package:open_file/open_file.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/mcp_models.dart';
import '../services/chat_service.dart';
import '../mcp/servers/imap_mcp_server.dart';
import '../mcp/servers/pdf_mcp_server.dart';
import '../database/duckdb_service.dart';
import '../utils/logger.dart';
import '../services/app_preferences_service.dart';
import '../utils/saf_bridge.dart';
import 'download_progress_widget.dart';
import '../utils/html_renderer_stub.dart';

HttpServer? _previewServer;
int? _previewServerPort;

Future<int> _ensurePreviewServerRunning() async {
  if (_previewServer != null) return _previewServerPort!;
  _previewServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  _previewServerPort = _previewServer!.port;
  _previewServer!.listen((HttpRequest request) async {
    final path = request.uri.path;
    final fileName = path.replaceFirst('/', '');
    if (fileName.startsWith('preview_') && fileName.endsWith('.html')) {
      final tempDir = Directory.systemTemp;
      final file = File('${tempDir.path}/$fileName');
      if (await file.exists()) {
        request.response.headers.contentType = ContentType.html;
        request.response.headers.add('Access-Control-Allow-Origin', '*');
        await request.response.addStream(file.openRead());
        await request.response.close();
        return;
      }
    }
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  });
  return _previewServerPort!;
}

/// Source info for displaying file origin (local path, Drive, OneDrive).
class _FileSourceInfo {
  final String label;
  final IconData icon;
  final Color? iconColor;
  final Color badgeColor;

  const _FileSourceInfo({required this.label, required this.icon, this.iconColor, required this.badgeColor});
}

class _EmailListItem {
  final String id;
  final String threadId;
  final String subject;
  final String from;
  final String to;
  final String date;
  final String snippet;
  final String body;
  final String htmlBody;
  final bool hasAttachments;
  final int attachmentCount;
  final List<String> attachmentNames;

  /// IMAP folder name, populated for IMAP search results (empty for Gmail).
  final String folder;

  const _EmailListItem({
    required this.id,
    required this.threadId,
    required this.subject,
    required this.from,
    required this.to,
    required this.date,
    required this.snippet,
    required this.body,
    this.htmlBody = '',
    required this.hasAttachments,
    required this.attachmentCount,
    this.attachmentNames = const [],
    this.folder = '',
  });
}

/// Determine the source of a file path (local, Google Drive, OneDrive).
_FileSourceInfo _getFileSourceInfoStatic(String filePath) {
  if (SafBridge.isSafUri(filePath)) {
    return const _FileSourceInfo(
      label: 'document',
      icon: Icons.insert_drive_file,
      iconColor: Color(0xFF1565C0),
      badgeColor: Color(0xFF1565C0),
    );
  }
  if (filePath.startsWith('gdrive://') || filePath.startsWith('google_drive://')) {
    return const _FileSourceInfo(label: 'Drive', icon: Icons.add_to_drive, iconColor: Color(0xFF4285F4), badgeColor: Color(0xFF4285F4));
  }
  if (filePath.startsWith('onedrive://') || filePath.startsWith('ms_graph://')) {
    return const _FileSourceInfo(label: 'OneDrive', icon: Icons.cloud, iconColor: Color(0xFF0078D4), badgeColor: Color(0xFF0078D4));
  }

  final sep = filePath.contains('\\') ? '\\' : '/';
  final parts = filePath.split(sep).where((p) => p.isNotEmpty).toList();
  String label;
  if (parts.length >= 2) {
    label = parts[parts.length - 2];
  } else {
    label = 'local';
  }

  return _FileSourceInfo(label: label, icon: Icons.insert_drive_file, badgeColor: const Color(0xFF5F6368));
}

class MultimediaMessageWidget extends StatelessWidget {
  final ChatMessage message;
  final bool isUser;
  final bool enableHorizontalScrolling;
  static const String _internalSystemPromptActionType = 'internal_system_prompt';
  static final RegExp _extensionPattern = RegExp(r'^[a-z0-9]+$');
  static final RegExp _markdownDataUriPattern = RegExp(
    r'\[([^\]]+)\]\(\s*data:([^;\s\)]+);base64,([A-Za-z0-9+/=\s\r\n]+)\s*\)',
    dotAll: true,
    caseSensitive: false,
  );
  static const int _maxJsonDetectLength = 200000;

  const MultimediaMessageWidget({super.key, required this.message, required this.isUser, this.enableHorizontalScrolling = true});

  @override
  Widget build(BuildContext context) {
    // Internal system prompts are execution context and should not be shown in UI.
    if (message.role == ChatRole.system && message.actionType == _internalSystemPromptActionType) {
      return const SizedBox.shrink();
    }

    if (message.type == MessageType.download && message.content.startsWith('download_progress:')) {
      final fileName = message.content.substring('download_progress:'.length);

      return Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const CircleAvatar(
                  radius: 16,
                  backgroundColor: Colors.blue,
                  child: Icon(Icons.download, size: 16, color: Colors.white),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DownloadProgressWidget(messageId: message.id, fileName: fileName),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 40),
              child: Text(
                _formatTimestamp(message.timestamp),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7)),
              ),
            ),
          ],
        ),
      );
    }

    final isMobile = MediaQuery.of(context).size.width < 600;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: Column(
        crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          // Show avatar on top for mobile, side for desktop
          if (isMobile && !isUser) ...[_buildAvatar(context), const SizedBox(height: 4)],
          if (isMobile && isUser) ...[
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [_buildAvatar(context)]),
            const SizedBox(height: 4),
          ],
          Row(
            mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!isMobile && !isUser) _buildAvatar(context),
              if (!isMobile && !isUser) const SizedBox(width: 8),
              Flexible(
                child: Container(
                  constraints: BoxConstraints(
                    maxWidth: isMobile ? MediaQuery.of(context).size.width * 0.95 : MediaQuery.of(context).size.width * 0.75,
                  ),
                  child: _buildMessageContent(context),
                ),
              ),
              if (!isMobile && isUser) const SizedBox(width: 8),
              if (!isMobile && isUser) _buildAvatar(context),
            ],
          ),
          Padding(
            padding: EdgeInsets.only(top: 4, left: isUser ? 0 : 40, right: isUser ? 40 : 0),
            child: Row(
              mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _formatTimestamp(message.timestamp),
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7)),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: Icon(Icons.copy, size: 14, color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
                  onPressed: () => _copyToClipboard(context),
                  tooltip: 'Copy message',
                  constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                  padding: EdgeInsets.zero,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatar(BuildContext context) {
    IconData avatarIcon;
    Color backgroundColor;
    Color iconColor;

    if (isUser) {
      avatarIcon = Icons.person;
      backgroundColor = Theme.of(context).colorScheme.primary;
      iconColor = Theme.of(context).colorScheme.onPrimary;
    } else if (message.role == ChatRole.tool) {
      avatarIcon = Icons.build;
      backgroundColor = Theme.of(context).colorScheme.tertiary;
      iconColor = Theme.of(context).colorScheme.onTertiary;
    } else {
      avatarIcon = Icons.smart_toy;
      backgroundColor = Theme.of(context).colorScheme.secondary;
      iconColor = Theme.of(context).colorScheme.onSecondary;
    }

    return CircleAvatar(
      radius: 16,
      backgroundColor: backgroundColor,
      child: Icon(avatarIcon, size: 18, color: iconColor),
    );
  }

  Widget _buildMessageContent(BuildContext context) {
    switch (message.type) {
      case MessageType.text:
        return _buildTextMessage(context);
      case MessageType.image:
        return _buildImageMessage(context);
      case MessageType.file:
        return _buildFileMessage(context);
      case MessageType.audio:
        return _buildAudioMessage(context);
      case MessageType.video:
        return _buildVideoMessage(context);
      case MessageType.download:
        // Download messages are handled by ChatMessageWidget
        return _buildTextMessage(context);
    }
  }

  Widget _buildTextMessage(BuildContext context) {
    // For tool messages, show the tool result prominently
    if (message.role == ChatRole.tool && message.toolResult != null) {
      return _buildToolMessageContainer(context);
    }

    final uiStyle = AppPreferencesService.instance.uiStyle;
    final isModern = uiStyle == 'modern';
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Streaming placeholder: empty assistant message while tokens are arriving
    if (!isUser && message.role == ChatRole.assistant && message.content.isEmpty && message.actionType == null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: isModern
            ? BoxDecoration(
                color: isDark ? Colors.white.withValues(alpha: 0.04) : Colors.black.withValues(alpha: 0.03),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: isDark ? Colors.white10 : Colors.black12),
              )
            : BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
        child: const _TypingIndicator(),
      );
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: isModern
          ? BoxDecoration(
              color: isUser
                  ? (isDark ? const Color(0xFF7C3AED).withValues(alpha: 0.15) : const Color(0xFF7C3AED).withValues(alpha: 0.08))
                  : (isDark ? Colors.white.withValues(alpha: 0.04) : Colors.black.withValues(alpha: 0.03)),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isUser
                    ? (isDark ? const Color(0xFF7C3AED).withValues(alpha: 0.35) : const Color(0xFF7C3AED).withValues(alpha: 0.2))
                    : (isDark ? Colors.white10 : Colors.black12),
              ),
            )
          : BoxDecoration(
              color: isUser ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (message.content.isNotEmpty && !message.content.contains('Called tool:'))
            isUser ? _buildUserPromptText(context) : _buildMarkdownWithScrollableContent(context),
          // Add action button for system messages with actions (e.g., reset)
          if (message.actionType == 'reset') ...[
            const SizedBox(height: 12),
            Consumer<ChatService>(
              builder: (context, chatService, child) => FilledButton.icon(
                onPressed: () async {
                  await chatService.resetConversation();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Conversation reset successfully'),
                      backgroundColor: Colors.green,
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
                icon: const Icon(Icons.refresh),
                label: const Text('Reset Conversation'),
                style: FilledButton.styleFrom(backgroundColor: Colors.orange),
              ),
            ),
          ],
          if (message.toolResult != null) ...[
            const SizedBox(height: 8),
            _buildToolResult(context),
          ] else if (message.content.contains('Called tool:')) ...[
            const SizedBox(height: 8),
            _buildToolContentFromMessage(context),
          ] else if (message.role == ChatRole.tool) ...[
            const SizedBox(height: 8),
            _buildNoToolResult(context),
          ],
        ],
      ),
    );
  }

  Widget _buildImageMessage(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: isUser
            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.1)
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (message.attachments != null && message.attachments!.isNotEmpty) _buildImageAttachment(context, message.attachments!.first),
          if (message.content.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                message.content,
                style: TextStyle(color: isUser ? Theme.of(context).colorScheme.onPrimary : Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFileMessage(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isUser
            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.1)
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (message.attachments != null && message.attachments!.isNotEmpty) _buildFileAttachment(context, message.attachments!.first),
          if (message.content.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              message.content,
              style: TextStyle(color: isUser ? Theme.of(context).colorScheme.onPrimary : Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAudioMessage(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isUser
            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.1)
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.audiotrack, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message.attachments?.first.name ?? 'Audio file', style: Theme.of(context).textTheme.titleSmall),
                if (message.content.isNotEmpty) Text(message.content, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          IconButton(icon: const Icon(Icons.play_arrow), onPressed: () => _openFile(message.attachments?.first)),
        ],
      ),
    );
  }

  Widget _buildVideoMessage(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isUser
            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.1)
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.videocam, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message.attachments?.first.name ?? 'Video file', style: Theme.of(context).textTheme.titleSmall),
                if (message.content.isNotEmpty) Text(message.content, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          IconButton(icon: const Icon(Icons.play_arrow), onPressed: () => _openFile(message.attachments?.first)),
        ],
      ),
    );
  }

  Widget _buildImageAttachment(BuildContext context, MessageAttachment attachment) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
      child: Container(
        constraints: const BoxConstraints(maxHeight: 300, maxWidth: 400),
        child: Stack(
          children: [
            _buildImageWidget(attachment),
            // Export button overlay
            Positioned(
              top: 8,
              right: 8,
              child: Container(
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
                child: IconButton(
                  icon: const Icon(Icons.file_download, color: Colors.white, size: 20),
                  onPressed: () => _exportImage(context, attachment),
                  tooltip: 'Export Image',
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  padding: const EdgeInsets.all(4),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImageWidget(MessageAttachment attachment) {
    final path = attachment.path;

    // If bytes are available (web platform), use them
    if (attachment.bytes != null) {
      return Image.memory(
        attachment.bytes!,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) {
          return _buildImageError();
        },
      );
    }

    // Otherwise use path-based loading
    if (path.startsWith('http')) {
      return Image.network(
        path,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) {
          return _buildImageError();
        },
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) return child;
          return const Center(child: CircularProgressIndicator());
        },
      );
    } else if (path.startsWith('data:')) {
      // Handle data URLs (base64 encoded images)
      try {
        final commaIndex = path.indexOf(',');
        if (commaIndex > 0) {
          final base64Data = path.substring(commaIndex + 1);
          final bytes = base64Decode(base64Data);
          return Image.memory(
            bytes,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) {
              return _buildImageError();
            },
          );
        } else {
          return _buildImageError();
        }
      } catch (e) {
        return _buildImageError();
      }
    } else {
      try {
        final file = File(path);
        if (file.existsSync()) {
          return Image.file(
            file,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) {
              return _buildImageError();
            },
          );
        } else {
          return _buildImageError();
        }
      } catch (e) {
        return _buildImageError();
      }
    }
  }

  Widget _buildImageError() {
    return Container(
      height: 100,
      width: double.infinity,
      color: Colors.grey.withValues(alpha: 0.3),
      child: const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [Icon(Icons.broken_image, size: 32), SizedBox(height: 4), Text('Image not available')],
      ),
    );
  }

  Widget _buildFileAttachment(BuildContext context, MessageAttachment attachment) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_getFileIcon(attachment.name), size: 32, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(attachment.name, style: Theme.of(context).textTheme.titleSmall, overflow: TextOverflow.ellipsis),
                if (attachment.size != null)
                  Text(
                    _formatFileSize(attachment.size!),
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7)),
                  ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.download, color: Theme.of(context).colorScheme.primary),
            onPressed: () => _downloadAttachment(context, attachment),
            tooltip: 'Download file',
          ),
        ],
      ),
    );
  }

  Widget _buildToolResult(BuildContext context) {
    try {
      return _buildToolResultInner(context);
    } catch (e, stackTrace) {
      talker.error('Error rendering tool result: $e', stackTrace);
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.orange.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber_rounded, size: 16, color: Colors.orange[700]),
                const SizedBox(width: 8),
                Text(
                  'Render Error',
                  style: TextStyle(fontWeight: FontWeight.bold, color: Colors.orange[700]),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SelectableText(
              message.toolResult?.content.map((c) => c.text ?? '').join('\n') ?? 'No content',
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ],
        ),
      );
    }
  }

  Widget _buildToolResultInner(BuildContext context) {
    if (_isSearchGmailToolMessage()) {
      final combinedText = message.toolResult!.content.map((c) => c.text ?? '').join('\n');
      return _buildEmailListFromContent(context, combinedText);
    }

    // Check if there's any downloadable/viewable content to decide initial expansion state
    final resultText = message.toolResult!.content.map((c) => c.text ?? '').join('\n');
    final hasDownloadableContent = _hasDownloadableContent();

    return Container(
      decoration: BoxDecoration(
        color: message.toolResult!.isError ? Colors.red.withValues(alpha: 0.15) : Colors.green.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: message.toolResult!.isError ? Colors.red.withValues(alpha: 0.3) : Colors.green.withValues(alpha: 0.3)),
      ),
      child: ExpansionTile(
        initiallyExpanded: hasDownloadableContent, // Always expand if there's downloadable content
        tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        childrenPadding: const EdgeInsets.only(left: 12, right: 12, bottom: 12),
        iconColor: message.toolResult!.isError ? Colors.red[700] : Colors.green[700],
        collapsedIconColor: message.toolResult!.isError ? Colors.red[700] : Colors.green[700],
        subtitle: hasDownloadableContent
            ? Padding(
                padding: const EdgeInsets.only(left: 24, top: 4),
                child: Text(
                  _getDownloadableContentHint(),
                  style: const TextStyle(fontSize: 12, color: Colors.grey, fontStyle: FontStyle.italic),
                ),
              )
            : null,
        title: Row(
          children: [
            Icon(
              message.toolResult!.isError ? Icons.error_outline : Icons.check_circle_outline,
              size: 16,
              color: message.toolResult!.isError ? Colors.red[700] : Colors.green[700],
            ),
            const SizedBox(width: 8),
            Text(
              message.toolResult!.isError ? 'Tool Error' : 'Tool Result',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: message.toolResult!.isError ? Colors.red[700] : Colors.green[700],
              ),
            ),
            const SizedBox(width: 8),
            // Show content indicator if there are images or files
            if (hasDownloadableContent) ...[
              Icon(_getDownloadableContentIcon(), size: 14, color: Colors.blue[600]),
              const SizedBox(width: 4),
            ],
            Flexible(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: Colors.grey.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(10)),
                child: Text(
                  hasDownloadableContent ? '${resultText.length} chars + ${_getDownloadableContentCount()}' : '${resultText.length} chars',
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.grey[700], // Darker grey for better readability
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
        ),
        trailing: IconButton(
          icon: const Icon(Icons.copy, size: 16),
          onPressed: () => _copyToolResultToClipboard(context),
          tooltip: 'Copy result',
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          padding: EdgeInsets.zero,
        ),
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (message.toolResult!.content.isNotEmpty)
                ...message.toolResult!.content.map((content) => _buildToolContent(context, content))
              else
                Text(
                  '[Empty tool result]',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontStyle: FontStyle.italic,
                    color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildToolMessageContainer(BuildContext context) {
    // Special container for tool messages with proper toolResult
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.tertiary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).colorScheme.tertiary.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Tool call info header - collapsible
          _ToolCallHeader(content: message.content, colorScheme: Theme.of(context).colorScheme),
          // Tool result directly (already has its own ExpansionTile)
          if (message.toolResult != null)
            _buildToolResult(context)
          else
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'Tool executed but no result data available',
                style: TextStyle(fontStyle: FontStyle.italic, color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildToolContentFromMessage(BuildContext context) {
    // Display tool content that's embedded in the message content
    final content = message.content;

    // Check if content seems complete or truncated
    // Only flag as truncated if:
    // 1. Content is very short (< 200 chars) AND contains tool call marker
    // 2. OR content ends abruptly without closing structure
    final isLikelyTruncated =
        (content.length < 200 && content.contains('Called tool:')) ||
        (content.contains('Called tool:') && !content.contains('\n') && content.length < 500);

    return Container(
      decoration: BoxDecoration(
        color: isLikelyTruncated ? Colors.orange.withValues(alpha: 0.15) : Colors.blue.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: isLikelyTruncated ? Colors.orange.withValues(alpha: 0.3) : Colors.blue.withValues(alpha: 0.3)),
      ),
      child: ExpansionTile(
        initiallyExpanded: false,
        tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        childrenPadding: const EdgeInsets.only(left: 12, right: 12, bottom: 12),
        iconColor: isLikelyTruncated ? Colors.orange[700] : Colors.blue[700],
        collapsedIconColor: isLikelyTruncated ? Colors.orange[700] : Colors.blue[700],
        title: Row(
          children: [
            Icon(
              isLikelyTruncated ? Icons.warning : Icons.build,
              size: 16,
              color: isLikelyTruncated ? Colors.orange[700] : Colors.blue[700],
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                isLikelyTruncated ? 'Tool Call (Incomplete Results)' : 'Tool Calls & Results',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: isLikelyTruncated ? Colors.orange[700] : Colors.blue[700],
                ),
              ),
            ),
          ],
        ),
        children: [
          if (isLikelyTruncated) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(color: Colors.orange.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4)),
              child: Text(
                'âš ï¸ Tool results appear to be incomplete or truncated. Only LLM summary is shown.',
                style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: Colors.orange[700]),
              ),
            ),
          ],
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(6)),
            child: enableHorizontalScrolling
                ? LayoutBuilder(
                    builder: (context, constraints) {
                      return SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(minWidth: constraints.maxWidth),
                          child: SelectableText(content, style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
                        ),
                      );
                    },
                  )
                : SelectableText(content, style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
          ),
        ],
      ),
    );
  }

  Widget _buildNoToolResult(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 16, color: Colors.orange[700]),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Tool called but no result data available',
              style: TextStyle(fontSize: 14, fontStyle: FontStyle.italic, color: Colors.orange[700]),
            ),
          ),
        ],
      ),
    );
  }

  IconData _getFileIcon(String fileName) {
    final extension = fileName.toLowerCase().split('.').last;
    switch (extension) {
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'doc':
      case 'docx':
        return Icons.description;
      case 'xls':
      case 'xlsx':
        return Icons.table_chart;
      case 'txt':
        return Icons.text_snippet;
      case 'zip':
      case 'rar':
        return Icons.archive;
      default:
        return Icons.insert_drive_file;
    }
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String _formatTimestamp(DateTime timestamp) {
    final now = DateTime.now();
    final difference = now.difference(timestamp);

    if (difference.inDays > 0) {
      return '${timestamp.day}/${timestamp.month} ${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}';
    } else if (difference.inHours > 0) {
      return '${difference.inHours}h ago';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes}m ago';
    } else if (difference.inSeconds > 0) {
      return '${difference.inSeconds}s ago';
    } else {
      // Show milliseconds for very recent messages
      return '${difference.inMilliseconds}ms ago';
    }
  }

  /// Auto-linkify plain URLs in text to markdown format
  /// Converts: "URL: https://example.com" or "(https://example.com)"
  /// To: "[Link](https://example.com)"
  String _autoLinkifyUrls(String text) {
    talker.debug('Auto-linkifying URLs in text (length: ${text.length})');

    // First, handle "URL: " or "Link: " prefixes followed by URLs
    var linkified = text.replaceAllMapped(RegExp(r'(?:URL|Link|url|link)\s*:\s*(https?://[^\s\)\n]+)'), (match) {
      final url = match.group(1)!;
      talker.debug('Converting "URL: $url" to markdown link');
      return '[Link]($url)';
    });

    // Then handle remaining plain URLs (not already in markdown format)
    linkified = linkified.replaceAllMapped(RegExp(r'(?<!\]\()(?<!\[)https?://[^\s\)\n]+'), (match) {
      final url = match.group(0)!;
      // Check if it's already been converted or is part of markdown
      if (linkified.contains('($url)') || linkified.contains('[$url]')) {
        talker.debug('URL already in markdown format: $url');
        return url;
      }
      talker.debug('Converting plain URL to markdown link: $url');
      return '[Link]($url)';
    });

    if (linkified != text) {}

    return linkified;
  }

  /// Launch URL in external browser
  Future<void> _launchUrl(String? url) async {
    if (url == null || url.isEmpty) return;

    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        talker.warning('âš ï¸ Cannot launch URL: $url');
      }
    } catch (e) {
      talker.error('âŒ Error launching URL: $e');
    }
  }

  void _openFile(MessageAttachment? attachment) {
    if (attachment == null) return;

    // Here you could integrate with a file viewer or download functionality
    // For now, just log the action
    try {
      // You could use url_launcher or other packages to open files
      // Or implement file download functionality
    } catch (e) {
      talker.error('Failed to open file: $e');
    }
  }

  Future<void> _downloadAttachment(BuildContext context, MessageAttachment attachment) async {
    try {
      // If bytes are available, use them
      if (attachment.bytes != null) {
        await _downloadAttachmentDesktop(context, attachment.bytes!, attachment.name, attachment.mimeType ?? 'application/octet-stream');
      } else {
        // If no bytes, try to read from file path
        final file = File(attachment.path);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          if (!context.mounted) return;
          await _downloadAttachmentDesktop(context, bytes, attachment.name, attachment.mimeType ?? 'application/octet-stream');
        } else {
          throw Exception('File not found');
        }
      }
    } catch (e) {
      talker.error('Failed to download attachment: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to download file: $e'), backgroundColor: Colors.red));
      }
    }
  }

  Future<void> _downloadAttachmentDesktop(BuildContext context, Uint8List bytes, String fileName, String mimeType) async {
    final String? outputPath = await FilePicker.saveFile(dialogTitle: 'Save File', fileName: fileName);

    if (outputPath != null) {
      final file = File(outputPath);
      await file.writeAsBytes(bytes);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('File saved: ${file.path}'), backgroundColor: Colors.green));
      }
    }
  }

  void _copyToClipboard(BuildContext context) {
    String textToCopy = message.content;

    // For tool messages, include role information
    if (message.role == ChatRole.tool) {
      textToCopy = 'Tool Message:\n${message.content}';
    }

    Clipboard.setData(ClipboardData(text: textToCopy));

    // Determine the message type for the snackbar
    String messageType = message.role == ChatRole.tool
        ? 'Tool message'
        : message.role == ChatRole.user
        ? 'User message'
        : 'Assistant message';

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$messageType copied to clipboard'),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.only(bottom: MediaQuery.of(context).size.height - 100, left: 20, right: 20),
      ),
    );
  }

  void _copyToolResultToClipboard(BuildContext context) {
    if (message.toolResult == null) return;

    final resultText = message.toolResult!.content.map((c) => c.text ?? '').join('\n');
    Clipboard.setData(ClipboardData(text: resultText));

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Tool result copied to clipboard'),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.only(bottom: MediaQuery.of(context).size.height - 100, left: 20, right: 20),
      ),
    );
  }

  Widget _buildToolContent(BuildContext context, MCPContent content) {
    try {
      return _buildToolContentInner(context, content);
    } catch (e, stackTrace) {
      talker.error('Error rendering tool content: $e', stackTrace);
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: SelectableText(content.text ?? '[Error rendering content]', style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
      );
    }
  }

  Widget _buildToolContentInner(BuildContext context, MCPContent content) {
    // Detect actual content type and render accordingly
    final detectedType = _detectContentType(content);

    return Padding(padding: const EdgeInsets.only(bottom: 8), child: _buildStandardizedContent(context, content, detectedType));
  }

  String _detectContentType(MCPContent content) {
    // Check for filelist:// marker first
    if (content.type == 'text' && content.text != null && content.text!.contains('filelist://')) {
      return 'filelist';
    }

    // Check for JSON file list format (both array and object with results)
    if (content.type == 'text' && content.text != null) {
      final text = content.text!;
      // Quick pre-check for doclist regardless of length — only need to scan the
      // first few hundred chars to detect the JSON structure key.
      if (text.length > _maxJsonDetectLength) {
        final peek = text.substring(0, text.length.clamp(0, 500));
        if (peek.contains('"documents"')) return 'doclist';
        if (peek.contains('"results"')) return 'filelist';
      }
      if (text.length <= _maxJsonDetectLength) {
        try {
          final jsonData = jsonDecode(text);

          // Check for Gmail-like result object with messages array
          if (jsonData is Map && jsonData['messages'] is List) {
            final messages = (jsonData['messages'] as List)
                .whereType<Map>()
                .where((m) => m['id'] != null || m['subject'] != null || m['from'] != null)
                .toList();
            if (messages.isNotEmpty) {
              return 'emaillist';
            }
          }

          // Check for direct array format: ["file1.md", "file2.txt"]
          if (jsonData is List && jsonData.isNotEmpty && jsonData.first is String) {
            final firstResult = jsonData.first as String;
            final parts = firstResult.split('.');
            if (parts.length >= 2) {
              final extension = parts.last.toLowerCase();
              if (extension.length >= 2 && extension.length <= 5 && _extensionPattern.hasMatch(extension)) {
                return 'filelist';
              }
            }
          }

          // Check for object format: {"results": ["file1.md", "file2.txt"]}
          if (jsonData is Map && jsonData['results'] is List) {
            final results = jsonData['results'] as List;
            if (results.isNotEmpty) {
              String? firstResult;
              if (results.first is String) {
                firstResult = results.first as String;
              } else if (results.first is Map && results.first['filePath'] is String) {
                firstResult = results.first['filePath'] as String;
              } else if (results.first is Map && results.first['path'] is String) {
                firstResult = results.first['path'] as String;
              }
              if (firstResult != null) {
                final parts = firstResult.split('.');
                if (parts.length >= 2) {
                  final extension = parts.last.toLowerCase();
                  if (extension.length >= 2 && extension.length <= 5 && _extensionPattern.hasMatch(extension)) {
                    return 'filelist';
                  }
                }
              }
            }
          }

          // Check for Drive file/folder list: {"files": [{"id":..., "name":..., "mimeType":...}]}
          if (jsonData is Map && jsonData['files'] is List) {
            final files = jsonData['files'] as List;
            if (files.isNotEmpty && files.first is Map && files.first['name'] != null) {
              return 'drivelist';
            }
          }

          // Check for document list: {"documents": [{"filePath":..., "fileName":...}]}
          if (jsonData is Map && jsonData['documents'] is List) {
            final docs = jsonData['documents'] as List;
            if (docs.isNotEmpty && docs.first is Map && (docs.first['filePath'] != null || docs.first['fileName'] != null)) {
              return 'doclist';
            }
          }
        } catch (e) {
          // Not JSON, continue checking other types
        }
      }
    }

    // Check for HTML content
    if (content.type == 'text' && content.text != null && _isHtmlContent(content.text!)) {
      return 'html';
    }

    // Check for image content
    if (content.type == 'image' || content.mimeType?.startsWith('image/') == true) {
      return 'image';
    }

    // Check for file/document content (Excel, PDF, etc.)
    if (content.type == 'file' || content.type == 'document' || content.type == 'attachment') {
      return 'file';
    }

    // Check MIME type for spreadsheets, documents, PDFs
    if (content.mimeType != null) {
      final mime = content.mimeType!.toLowerCase();
      if (mime.contains('spreadsheet') ||
          mime.contains('excel') ||
          mime.contains('pdf') ||
          mime.contains('word') ||
          mime.contains('msword') ||
          mime.contains('document')) {
        return 'file';
      }
    }

    // Check text content for embedded file data (JSON with fileName/mimeType/content)
    if (content.type == 'text' && content.text != null) {
      try {
        final textLower = content.text!.toLowerCase();
        if ((textLower.contains('filename') || textLower.contains('"filename"')) &&
            (textLower.contains('mimetype') || textLower.contains('"mimetype"')) &&
            (textLower.contains('encoding') || textLower.contains('"encoding"'))) {
          // This is embedded file data in JSON
          return 'embedded_file';
        }
      } catch (e) {
        // Not JSON, continue as text
      }
    }

    // Default to text
    return 'text';
  }

  Widget _buildStandardizedContent(BuildContext context, MCPContent content, String detectedType) {
    switch (detectedType) {
      case 'filelist':
        return _buildFileListFromContent(context, content.text!);
      case 'drivelist':
        return _buildDriveFileList(context, content.text!);
      case 'doclist':
        return _buildDocumentFileList(context, content.text!);
      case 'emaillist':
        return _buildEmailListFromContent(context, content.text!);
      case 'image':
        return _buildStandardizedImage(context, content);
      case 'file':
        return _buildStandardizedFile(context, content);
      case 'embedded_file':
        return _buildEmbeddedFileFromText(context, content);
      case 'html':
        return _buildHtmlContentFromText(context, content.text ?? '');
      case 'text':
      default:
        return _buildJsonContent(context, content.text ?? '');
    }
  }

  List<_EmailListItem> _extractEmailsFromContent(String content) {
    try {
      final jsonData = jsonDecode(content);
      if (jsonData is! Map || jsonData['messages'] is! List) return const [];

      final messages = (jsonData['messages'] as List)
          .whereType<Map>()
          .map((m) {
            final subject = (m['subject'] ?? '').toString().trim();
            final from = (m['from'] ?? '').toString().trim();
            final to = (m['to'] ?? '').toString().trim();
            final date = (m['date'] ?? '').toString().trim();
            final snippet = (m['snippet'] ?? '').toString().trim();
            final body = (m['body'] ?? '').toString().trim();
            final htmlBody = (m['htmlBody'] ?? '').toString().trim();
            final id = (m['id'] ?? m['uid']?.toString() ?? '').toString().trim();
            final threadId = (m['threadId'] ?? '').toString().trim();
            final folder = (m['folder'] ?? '').toString().trim();
            final hasAttachments = m['hasAttachments'] == true;
            final attachmentCount = (m['attachmentCount'] as num?)?.toInt() ?? 0;
            final attachmentNames = (m['attachmentNames'] as List<dynamic>?)?.cast<String>() ?? const <String>[];

            return _EmailListItem(
              id: id,
              threadId: threadId,
              subject: subject.isEmpty ? '(no subject)' : subject,
              from: from,
              to: to,
              date: date,
              snippet: snippet,
              body: body,
              htmlBody: htmlBody,
              hasAttachments: hasAttachments,
              attachmentCount: attachmentCount,
              attachmentNames: attachmentNames,
              folder: folder,
            );
          })
          .where((e) => e.id.isNotEmpty || e.subject.isNotEmpty || e.snippet.isNotEmpty)
          .toList();

      return messages;
    } catch (_) {
      return _extractEmailsFromMapLikeText(content);
    }
  }

  List<_EmailListItem> _extractEmailsFromMapLikeText(String content) {
    if (!content.contains('messages:') || !content.contains('id:')) return const [];

    final messagesStart = content.indexOf('messages:');
    if (messagesStart < 0) return const [];

    final listStart = content.indexOf('[', messagesStart);
    final listEnd = content.lastIndexOf(']');
    if (listStart < 0 || listEnd <= listStart) return const [];

    final listText = content.substring(listStart + 1, listEnd);
    final blocks = RegExp(
      r'\{id:\s*[^\{\}]*?(?:\{[^\}]*\}[^\{\}]*)*\}',
      dotAll: true,
    ).allMatches(listText).map((m) => m.group(0) ?? '').where((b) => b.isNotEmpty).toList();

    final parsed = <_EmailListItem>[];
    for (final block in blocks) {
      final id = _extractMapLikeField(block, 'id');
      final threadId = _extractMapLikeField(block, 'threadId');
      final subject = _extractMapLikeField(block, 'subject');
      final from = _extractMapLikeField(block, 'from');
      final to = _extractMapLikeField(block, 'to');
      final date = _extractMapLikeField(block, 'date');
      final snippet = _extractMapLikeField(block, 'snippet');
      final body = _extractMapLikeField(block, 'body');
      final htmlBody = _extractMapLikeField(block, 'htmlBody');
      final hasAttachmentsRaw = _extractMapLikeField(block, 'hasAttachments').toLowerCase();
      final attachmentCountRaw = _extractMapLikeField(block, 'attachmentCount');

      final hasAttachments = hasAttachmentsRaw == 'true' || hasAttachmentsRaw == '1';
      final attachmentCount = int.tryParse(attachmentCountRaw) ?? 0;

      if (id.isEmpty && subject.isEmpty && snippet.isEmpty) {
        continue;
      }

      parsed.add(
        _EmailListItem(
          id: id,
          threadId: threadId,
          subject: subject.isEmpty ? '(no subject)' : subject,
          from: from,
          to: to,
          date: date,
          snippet: snippet,
          body: body,
          htmlBody: htmlBody,
          hasAttachments: hasAttachments,
          attachmentCount: attachmentCount,
        ),
      );
    }

    return parsed;
  }

  String _extractMapLikeField(String block, String field) {
    final keys = [
      'id',
      'threadId',
      'subject',
      'from',
      'to',
      'cc',
      'date',
      'snippet',
      'internalDate',
      'hasAttachments',
      'attachmentCount',
      'body',
      'htmlBody',
    ];

    final otherKeys = keys.where((k) => k != field).join('|');
    final regex = RegExp('$field\\s*:\\s*(.*?)(?=,\\s*(?:$otherKeys)\\s*:|\\s*\\})', dotAll: true);
    final match = regex.firstMatch(block);
    if (match == null) return '';
    return (match.group(1) ?? '').trim();
  }

  bool _isSearchGmailToolMessage() {
    final contentLower = message.content.toLowerCase();
    final toolLower = (message.lastCalledToolName ?? '').toLowerCase();

    if (contentLower.contains('called tool: search_gmail')) return true;
    if (toolLower == 'search_gmail') return true;

    if (message.toolResult != null) {
      final text = message.toolResult!.content.map((c) => c.text ?? '').join('\n').toLowerCase();
      if (text.contains('messages:') && text.contains('subject:') && text.contains('snippet:')) {
        return true;
      }
      if (text.contains('"messages"') && text.contains('"subject"')) {
        return true;
      }
    }

    return false;
  }

  Widget _buildEmailListFromContent(BuildContext context, String content) {
    final emails = _extractEmailsFromContent(content);
    if (emails.isEmpty) {
      if (_isSearchGmailToolMessage()) {
        return _buildPlainTextFallback(context, content);
      }
      return _buildJsonContent(context, content);
    }

    const maxVisibleEmails = 10;
    final hasMore = emails.length > maxVisibleEmails;
    final visibleEmails = hasMore ? emails.take(maxVisibleEmails).toList() : emails;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.email, size: 16, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 4),
              Text(
                'Emails (${emails.length})',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary),
              ),
              if (hasMore) ...[
                const Spacer(),
                IconButton(
                  icon: Icon(Icons.search, size: 18, color: Theme.of(context).colorScheme.primary),
                  onPressed: () => _showAllEmailsDialog(context, emails),
                  tooltip: 'View all emails',
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  padding: EdgeInsets.zero,
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          ...visibleEmails.map((email) => _buildEmailRow(context, email)),
          if (hasMore)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Showing ${visibleEmails.length} of ${emails.length} emails',
                style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic, color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPlainTextFallback(BuildContext context, String content) {
    final normalized = content.replaceAll('\r\n', '\n').trim();
    final preview = normalized.length > 4000 ? '${normalized.substring(0, 4000)}\n\n...[truncated]' : normalized;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2)),
      ),
      child: SelectableText(preview.isEmpty ? '(No email data available)' : preview, style: const TextStyle(fontSize: 12)),
    );
  }

  Widget _buildEmailRow(BuildContext context, _EmailListItem email) {
    final dateStr = _formatEmailDateTime(email.date);
    final fromStr = _cleanEmailAddress(email.from);
    final subjectStr = email.subject.trim().isNotEmpty ? email.subject : '(no subject)';
    final labelStyle = TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant, fontWeight: FontWeight.w500);
    final valueStyle = const TextStyle(fontSize: 13, fontWeight: FontWeight.w600);
    final primary = Theme.of(context).colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => _showEmailDetailDialog(context, email),
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            color: primary.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: primary.withValues(alpha: 0.2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Date row
              if (dateStr.isNotEmpty) _buildEmailMetaLine(context, 'Date', dateStr, labelStyle, valueStyle),
              // From row
              if (fromStr.isNotEmpty) _buildEmailMetaLine(context, 'From', fromStr, labelStyle, valueStyle),
              // Subject row
              _buildEmailMetaLine(context, 'Subject', subjectStr, labelStyle, valueStyle),
              // Attachment + open icon
              const SizedBox(height: 4),
              Row(
                children: [
                  if (email.hasAttachments || email.attachmentCount > 0) ...[
                    Icon(Icons.attach_file, size: 13, color: primary),
                    const SizedBox(width: 2),
                    Flexible(
                      child: Text(
                        email.attachmentNames.isNotEmpty
                            ? email.attachmentNames.first.contains(' (')
                                  ? email.attachmentNames.first.substring(0, email.attachmentNames.first.indexOf(' ('))
                                  : email.attachmentNames.first
                            : email.attachmentCount > 1
                            ? '${email.attachmentCount} Anhänge'
                            : '1 Anhang',
                        style: TextStyle(fontSize: 11, color: primary),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  const Spacer(),
                  Icon(Icons.open_in_new, size: 14, color: primary.withValues(alpha: 0.6)),
                  const SizedBox(width: 2),
                  Text('open', style: TextStyle(fontSize: 11, color: primary.withValues(alpha: 0.6))),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmailMetaLine(BuildContext context, String label, String value, TextStyle labelStyle, TextStyle valueStyle) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 52, child: Text(label, style: labelStyle)),
          Expanded(
            child: Text(value, style: valueStyle, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  void _showAllEmailsDialog(BuildContext context, List<_EmailListItem> allEmails) {
    showDialog<void>(
      context: context,
      builder: (ctx) {
        var query = '';
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final filtered = allEmails.where((email) {
              final q = query.trim().toLowerCase();
              if (q.isEmpty) return true;
              final haystack = '${email.subject} ${email.from} ${email.snippet} ${email.body}'.toLowerCase();
              return haystack.contains(q);
            }).toList();

            return Dialog(
              insetPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 24),
              clipBehavior: Clip.hardEdge,
              child: Column(
                children: [
                  // â”€â”€ Header row â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
                  Container(
                    decoration: BoxDecoration(
                      color: Theme.of(ctx).colorScheme.surface,
                      border: Border(bottom: BorderSide(color: Theme.of(ctx).colorScheme.outline.withValues(alpha: 0.2))),
                    ),
                    child: Row(
                      children: [
                        IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(ctx).pop()),
                        Icon(Icons.email, size: 18, color: Theme.of(ctx).colorScheme.primary),
                        const SizedBox(width: 6),
                        Text(
                          'Emails (${allEmails.length})',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Theme.of(ctx).colorScheme.primary),
                        ),
                      ],
                    ),
                  ),
                  // â”€â”€ Filter field â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: TextField(
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Filter emails\u2026',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (value) => setDialogState(() => query = value),
                    ),
                  ),
                  // â”€â”€ Email list â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
                  Expanded(
                    child: filtered.isEmpty
                        ? const Center(child: Text('No matching emails.'))
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            itemCount: filtered.length,
                            itemBuilder: (ctx, index) => _buildEmailRow(ctx, filtered[index]),
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showEmailDetailDialog(BuildContext context, _EmailListItem email) {
    final primary = Theme.of(context).colorScheme.primary;
    final isImapEmail = int.tryParse(email.id) != null;
    final needsFetch = isImapEmail && email.body.isEmpty && email.htmlBody.isEmpty;

    var loadedBody = email.body;
    var loadedHtmlBody = email.htmlBody;
    var isLoadingBody = needsFetch;
    var fetchTriggered = false;
    var loadError = '';
    void Function(void Function())? setDialogState_;

    Future<void> openInGmail() async {
      final url = Uri.parse('https://mail.google.com/mail/u/0/#all/');
      if (await canLaunchUrl(url)) await launchUrl(url, mode: LaunchMode.externalApplication);
    }

    Future<void> fetchImapBody() async {
      if (fetchTriggered) return;
      fetchTriggered = true;
      try {
        final uid = int.parse(email.id);
        final folder = email.folder.isEmpty ? 'INBOX' : email.folder;
        // Call ImapMcpServer directly — it reads credentials from the
        // settings singleton, so no Provider/BuildContext needed.
        final server = ImapMcpServer();
        await server.initialize({});
        final raw = await server.executeTool('read_email', {'uid': uid, 'folder': folder});
        final isError = raw['isError'] == true;
        final contentList = raw['content'] as List<dynamic>?;
        final text = contentList?.isNotEmpty == true ? (contentList!.first as Map<String, dynamic>)['text'] as String? ?? '' : '';
        if (isError) {
          loadError = text.isEmpty ? 'IMAP read error' : text;
        } else {
          final parsed = text.isNotEmpty ? jsonDecode(text) as Map<String, dynamic>? : null;
          if (parsed != null) {
            loadedBody = (parsed['body'] as String? ?? '').trim();
            loadedHtmlBody = (parsed['htmlBody'] as String? ?? '').trim();
            if (loadedBody.isEmpty && loadedHtmlBody.isEmpty) {
              loadError = 'Email body is empty.';
            }
          } else {
            loadError = 'Failed to parse email response.';
          }
        }
      } catch (e) {
        loadError = e.toString();
      }
      isLoadingBody = false;
      setDialogState_?.call(() {});
    }

    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 24),
        clipBehavior: Clip.hardEdge,
        child: StatefulBuilder(
          builder: (ctx, setState) {
            setDialogState_ = setState;
            if (needsFetch && !fetchTriggered) {
              WidgetsBinding.instance.addPostFrameCallback((_) => fetchImapBody());
            }
            final hasHtml = loadedHtmlBody.trim().isNotEmpty;
            final hasPlain = loadedBody.trim().isNotEmpty;
            final copyText = hasPlain ? loadedBody : (hasHtml ? loadedHtmlBody : email.snippet);
            return Column(
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: Theme.of(ctx).colorScheme.surface,
                    border: Border(bottom: BorderSide(color: Theme.of(ctx).colorScheme.outline.withValues(alpha: 0.2))),
                  ),
                  child: Row(
                    children: [
                      IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(ctx).pop()),
                      Expanded(
                        child: Text(
                          email.subject,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                        ),
                      ),
                      if (!isLoadingBody)
                        IconButton(
                          icon: const Icon(Icons.copy, size: 20),
                          tooltip: 'Kopieren',
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: copyText));
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('E-Mail-Inhalt kopiert')));
                          },
                        ),
                      if (!isImapEmail && email.id.isNotEmpty)
                        IconButton(icon: const Icon(Icons.open_in_new, size: 20), tooltip: 'In Gmail öffnen', onPressed: openInGmail),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (email.from.isNotEmpty) _buildEmailHeaderRow(context, 'From', email.from),
                        if (email.to.isNotEmpty) _buildEmailHeaderRow(context, 'To', email.to),
                        if (email.date.isNotEmpty) _buildEmailHeaderRow(context, 'Date', email.date),
                        if (email.hasAttachments || email.attachmentCount > 0 || email.attachmentNames.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Icon(Icons.attach_file, size: 15, color: primary),
                              const SizedBox(width: 4),
                              Text(
                                email.attachmentNames.isNotEmpty
                                    ? 'Anhänge ()'
                                    : email.attachmentCount > 1
                                    ? ' Anhänge'
                                    : '1 Anhang',
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: primary),
                              ),
                            ],
                          ),
                          if (email.attachmentNames.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              children: email.attachmentNames.map((name) {
                                final namePart = name.contains(' (') ? name.substring(0, name.indexOf(' (')) : name;
                                final icon = _attachmentIcon(name);
                                return InkWell(
                                  onTap: !isImapEmail && email.id.isNotEmpty ? openInGmail : null,
                                  borderRadius: BorderRadius.circular(20),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                    decoration: BoxDecoration(
                                      color: primary.withValues(alpha: 0.1),
                                      border: Border.all(color: primary.withValues(alpha: 0.3)),
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(icon, size: 13, color: primary),
                                        const SizedBox(width: 4),
                                        ConstrainedBox(
                                          constraints: const BoxConstraints(maxWidth: 240),
                                          child: Text(
                                            namePart,
                                            style: TextStyle(fontSize: 12, color: primary),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ] else ...[
                            const SizedBox(height: 4),
                            Text(
                              '→ In Gmail öffnen zum Herunterladen',
                              style: TextStyle(fontSize: 11, color: primary.withValues(alpha: 0.7)),
                            ),
                          ],
                        ],
                        const Divider(height: 24),
                        if (isLoadingBody)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 24),
                            child: Center(child: CircularProgressIndicator()),
                          )
                        else if (loadError.isNotEmpty)
                          Text('Fehler beim Laden: $loadError', style: const TextStyle(color: Colors.red))
                        else if (hasHtml)
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: ConstrainedBox(
                              constraints: BoxConstraints(minWidth: MediaQuery.of(context).size.width - 40),
                              child: HtmlRenderer(html: loadedHtmlBody),
                            ),
                          )
                        else if (hasPlain)
                          SelectableText(loadedBody, style: const TextStyle(fontSize: 13.5, height: 1.5))
                        else if (email.snippet.isNotEmpty)
                          SelectableText(email.snippet, style: const TextStyle(fontSize: 13.5, height: 1.5, fontStyle: FontStyle.italic))
                        else
                          const Text('(Kein E-Mail-Inhalt verfügbar)', style: TextStyle(fontStyle: FontStyle.italic)),
                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Returns an appropriate icon for a file attachment based on its name/type.
  static IconData _attachmentIcon(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('pdf')) return Icons.picture_as_pdf;
    if (lower.contains('jpg') || lower.contains('jpeg') || lower.contains('png') || lower.contains('gif') || lower.contains('image')) {
      return Icons.image;
    }
    if (lower.contains('xls') || lower.contains('spreadsheet') || lower.contains('csv')) return Icons.table_chart;
    if (lower.contains('doc') || lower.contains('word')) return Icons.description;
    if (lower.contains('zip') || lower.contains('rar') || lower.contains('tar')) return Icons.archive;
    if (lower.contains('mp4') || lower.contains('mov') || lower.contains('video')) return Icons.video_file;
    if (lower.contains('mp3') || lower.contains('audio')) return Icons.audio_file;
    return Icons.attach_file;
  }

  Widget _buildEmailHeaderRow(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 44,
            child: Text(
              '$label:',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(child: SelectableText(value, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }

  String _formatEmailDateTime(String rawDate) {
    if (rawDate.trim().isEmpty) return '';
    try {
      final parsed = DateTime.tryParse(rawDate);
      if (parsed == null) return rawDate;
      final local = parsed.toLocal();
      final yy = local.year.toString().padLeft(4, '0');
      final mm = local.month.toString().padLeft(2, '0');
      final dd = local.day.toString().padLeft(2, '0');
      final hh = local.hour.toString().padLeft(2, '0');
      final min = local.minute.toString().padLeft(2, '0');
      return '$yy-$mm-$dd $hh:$min';
    } catch (_) {
      return rawDate;
    }
  }

  String _cleanEmailAddress(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '';
    final match = RegExp(r'<([^>]+)>').firstMatch(trimmed);
    if (match != null) {
      return match.group(1)!.trim();
    }
    return trimmed;
  }

  Widget _buildBase64Image(BuildContext context, String base64Data, String? mimeType) {
    try {
      // Handle both data URLs and raw base64
      String actualBase64Data = base64Data;
      if (base64Data.startsWith('data:')) {
        // Extract base64 data from data URL
        final commaIndex = base64Data.indexOf(',');
        if (commaIndex != -1) {
          actualBase64Data = base64Data.substring(commaIndex + 1);
        }
      }

      debugPrint('MultimediaMessageWidget: Decoding base64 data of length: ${actualBase64Data.length}');

      // Decode base64 to bytes
      final bytes = base64Decode(actualBase64Data);

      return Container(
        constraints: const BoxConstraints(maxHeight: 400, maxWidth: double.infinity),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2)),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            bytes,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) {
              return Container(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.broken_image, size: 32, color: Colors.red),
                    const SizedBox(height: 8),
                    const Text('Failed to display image', style: TextStyle(color: Colors.red)),
                    if (mimeType != null) Text('MIME type: $mimeType', style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              );
            },
          ),
        ),
      );
    } catch (e) {
      debugPrint('MultimediaMessageWidget: Error decoding base64 image: $e');
      debugPrint('MultimediaMessageWidget: Base64 data sample: ${base64Data.substring(0, math.min(100, base64Data.length))}...');

      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error, color: Colors.red),
            const SizedBox(height: 8),
            const Text('Invalid base64 image data', style: TextStyle(color: Colors.red)),
            Text('Error: $e', style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
          ],
        ),
      );
    }
  }

  void _showFullScreenImage(BuildContext context, String base64Data) {
    // Remove data:image/png;base64, prefix if present
    String cleanBase64 = base64Data;
    if (cleanBase64.startsWith('data:image/png;base64,')) {
      cleanBase64 = cleanBase64.replaceFirst('data:image/png;base64,', '');
    }
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.black87,
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                panEnabled: true,
                boundaryMargin: const EdgeInsets.all(20),
                minScale: 0.5,
                maxScale: 4,
                child: Image.memory(base64Decode(cleanBase64), fit: BoxFit.contain),
              ),
            ),
            Positioned(
              top: 20,
              right: 20,
              child: IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close, color: Colors.white, size: 30),
                style: IconButton.styleFrom(backgroundColor: Colors.black54),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Standardized image display with fullscreen and download buttons
  Widget _buildStandardizedImage(BuildContext context, MCPContent content) {
    if (content.data == null) {
      return Text(
        '[Invalid image content - no data field]',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic, color: Colors.red),
      );
    }

    final imageWidget = _buildBase64Image(context, content.data!, content.mimeType);

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 4, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header for images with fullscreen and download buttons
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: const BorderRadius.only(topLeft: Radius.circular(12), topRight: Radius.circular(12)),
            ),
            child: Row(
              children: [
                Icon(Icons.image, size: 16, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  'Image',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w500, color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () {
                    // Show HTML preview
                    try {
                      String actualBase64Data = content.data!;
                      if (actualBase64Data.startsWith('data:')) {
                        final commaIndex = actualBase64Data.indexOf(',');
                        if (commaIndex != -1) {
                          actualBase64Data = actualBase64Data.substring(commaIndex + 1);
                        }
                      }
                      final mimeType = content.mimeType ?? 'image/png';
                      final htmlSnippet =
                          '<img src="data:$mimeType;base64,$actualBase64Data" alt="Embedded Image" style="max-width:100%; height:auto;" />';
                      _showHtmlPreview(context, htmlSnippet);
                    } catch (e) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text('Error: $e'), duration: const Duration(seconds: 2)));
                    }
                  },
                  icon: Icon(Icons.preview, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  tooltip: 'Preview HTML',
                ),
                IconButton(
                  onPressed: () async {
                    // Copy HTML embed code to clipboard
                    try {
                      String actualBase64Data = content.data!;
                      if (actualBase64Data.startsWith('data:')) {
                        final commaIndex = actualBase64Data.indexOf(',');
                        if (commaIndex != -1) {
                          actualBase64Data = actualBase64Data.substring(commaIndex + 1);
                        }
                      }
                      final mimeType = content.mimeType ?? 'image/png';
                      final htmlSnippet =
                          '<img src="data:$mimeType;base64,$actualBase64Data" alt="Embedded Image" style="max-width:100%; height:auto;" />';

                      await Clipboard.setData(ClipboardData(text: htmlSnippet));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('HTML embed code copied to clipboard'), duration: Duration(seconds: 2)));
                    } catch (e) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text('Error: $e'), duration: const Duration(seconds: 2)));
                    }
                  },
                  icon: Icon(Icons.code, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  tooltip: 'Copy HTML embed code',
                ),
                IconButton(
                  onPressed: () async {
                    // Download image
                    try {
                      String actualBase64Data = content.data!;
                      if (actualBase64Data.startsWith('data:')) {
                        final commaIndex = actualBase64Data.indexOf(',');
                        if (commaIndex != -1) {
                          actualBase64Data = actualBase64Data.substring(commaIndex + 1);
                        }
                      }
                      final bytes = base64Decode(actualBase64Data);
                      final extension = content.mimeType?.split('/').last ?? 'png';
                      final fileName = 'image_${DateTime.now().millisecondsSinceEpoch}.$extension';
                      final result = await _saveFileToDownloads(bytes, fileName);
                      if (!context.mounted) return;
                      if (result) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Image saved to Downloads: $fileName'), duration: const Duration(seconds: 2)),
                        );
                      } else {
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(const SnackBar(content: Text('Failed to save image'), duration: Duration(seconds: 2)));
                      }
                    } catch (e) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text('Error: $e'), duration: const Duration(seconds: 2)));
                    }
                  },
                  icon: Icon(Icons.download, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  tooltip: 'Download image',
                ),
                IconButton(
                  onPressed: () => _showFullScreenImage(context, content.data!),
                  icon: Icon(Icons.fullscreen, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  tooltip: 'Fullscreen',
                ),
              ],
            ),
          ),
          // Image content
          ClipRRect(
            borderRadius: const BorderRadius.only(bottomLeft: Radius.circular(12), bottomRight: Radius.circular(12)),
            child: imageWidget,
          ),
        ],
      ),
    );
  }

  /// Standardized file display with download button
  Widget _buildStandardizedFile(BuildContext context, MCPContent content) {
    if (content.data == null) {
      return _buildMCPFileAttachment(context, content);
    }

    // Determine file type, icon, and color based on MIME type
    IconData fileIcon;
    Color fileColor;
    String fileTypeLabel;
    String fileName;
    String fileExtension;

    final mimeType = content.mimeType ?? '';
    if (mimeType.contains('spreadsheet') || mimeType.contains('excel')) {
      fileIcon = Icons.table_chart;
      fileColor = Colors.green;
      fileTypeLabel = 'Excel file';
      fileExtension = 'xlsx';
    } else if (mimeType.contains('pdf')) {
      fileIcon = Icons.picture_as_pdf;
      fileColor = Colors.red;
      fileTypeLabel = 'PDF file';
      fileExtension = 'pdf';
    } else if (mimeType.contains('word') || mimeType.contains('msword')) {
      fileIcon = Icons.description;
      fileColor = Colors.blue;
      fileTypeLabel = 'Word document';
      fileExtension = 'docx';
    } else {
      fileIcon = Icons.insert_drive_file;
      fileColor = Theme.of(context).colorScheme.primary;
      fileTypeLabel = 'File';
      fileExtension = mimeType.split('/').last.split('.').last;
    }

    // Try to infer a meaningful filename from the content's text field (JSON or plain-text hint)
    String? hintedFileName;
    if (content.text != null && content.text!.isNotEmpty) {
      try {
        final decoded = jsonDecode(content.text!);
        if (decoded is Map<String, dynamic>) {
          final n = (decoded['fileName'] ?? decoded['filename'])?.toString().trim();
          if (n != null && n.isNotEmpty) hintedFileName = n;
        }
      } catch (_) {}
      if (hintedFileName == null) {
        final m = RegExp(
          '(?:file(?:\\s*name)?|saved\\s+(?:as|to)|output\\s+(?:file\\s+)?(?:is\\s+)?|named)\\s*[:\\s]+([^\\s,\\n<>"\'\\\\/:\\*\\?|]{1,80}\\.[a-zA-Z0-9]{1,6})',
          caseSensitive: false,
        ).firstMatch(content.text!);
        if (m != null) hintedFileName = m.group(1)?.trim();
      }
    }
    fileName = hintedFileName ?? 'download_${DateTime.now().millisecondsSinceEpoch}.$fileExtension';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () async {
              try {
                final bytes = base64Decode(content.data!);
                final result = await _saveFileToDownloads(bytes, fileName);
                if (!context.mounted) return;
                if (result) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text('File saved to Downloads: $fileName'), duration: const Duration(seconds: 2)));
                } else {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('Failed to save file'), duration: Duration(seconds: 2)));
                }
              } catch (e) {
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), duration: const Duration(seconds: 2)));
              }
            },
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: fileColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                    child: Icon(fileIcon, color: fileColor, size: 32),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          fileTypeLabel,
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          fileName,
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _formatFileSize(content.data!.length),
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(Icons.download, color: Theme.of(context).colorScheme.onPrimaryContainer, size: 24),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerRight,
          child: OutlinedButton.icon(
            onPressed: () => _shareBase64File(context, base64Data: content.data!, fileName: fileName, mimeType: mimeType),
            icon: const Icon(Icons.share, size: 16),
            label: const Text('Share'),
            style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
          ),
        ),
      ],
    );
  }

  /// Build embedded file from text content (JSON format)
  Widget _buildEmbeddedFileFromText(BuildContext context, MCPContent content) {
    try {
      // Parse the JSON and extract file data
      final embeddedFile = _extractEmbeddedFile(jsonDecode(content.text!));
      if (embeddedFile != null) {
        return _buildEmbeddedFileResponse(context, {}, embeddedFile);
      }
    } catch (e) {
      talker.error('Failed to parse embedded file from text: $e');
    }
    // Fallback to text display
    return _buildJsonContent(context, content.text ?? '');
  }

  /// Extract embedded file from JSON response (like Excel files)
  Map<String, dynamic>? _extractEmbeddedFile(dynamic jsonData) {
    if (jsonData is Map<String, dynamic>) {
      // Check for content array with nested text (MCP format: {content: [{type: "text", text: "{...}"}]})
      if (jsonData.containsKey('content') && jsonData['content'] is List) {
        final contentList = jsonData['content'] as List;

        for (var item in contentList) {
          if (item is Map<String, dynamic> && item['type'] == 'text' && item['text'] is String) {
            try {
              // Parse the nested JSON string
              final nestedText = item['text'] as String;
              final nestedJson = jsonDecode(nestedText);

              if (nestedJson is Map<String, dynamic>) {
                // Recursively check the nested JSON for file data
                final result = _extractEmbeddedFile(nestedJson);
                if (result != null) {
                  return result;
                }
              }
              // ignore: empty_catches
            } catch (e) {}
          }
        }
      }

      // Check for nested success/data structure first (like: {success: true, data: {...}, message: "..."})
      if (jsonData.containsKey('success') && jsonData['success'] == true && jsonData.containsKey('data')) {
        final data = jsonData['data'];
        if (data is Map<String, dynamic>) {
          // Check if data contains file metadata
          if (data.containsKey('fileName') &&
              data.containsKey('mimeType') &&
              data.containsKey('encoding') &&
              data['encoding'] == 'base64' &&
              data.containsKey('content')) {
            final mimeType = data['mimeType'].toString();
            if (!mimeType.startsWith('image/')) {
              final fileContent = data['content'].toString();
              if (fileContent.length > 50) {
                return {
                  'content': fileContent,
                  'mimeType': mimeType,
                  'fileName': data['fileName'] ?? 'file',
                  'size': data['size'] ?? fileContent.length,
                  'encoding': 'base64',
                  'message': jsonData['message'], // Get message from parent object
                };
              }
            }
          }
        }
      }

      // Check for direct file response with fileName, mimeType, size, encoding, and content
      if (jsonData.containsKey('fileName') &&
          jsonData.containsKey('mimeType') &&
          jsonData.containsKey('encoding') &&
          jsonData['encoding'] == 'base64') {
        // Check if it's a file type (Excel, PDF, etc.) not an image
        final mimeType = jsonData['mimeType'].toString();
        if (!mimeType.startsWith('image/')) {
          // The content should be in the JSON structure, let's extract it
          // Look for base64 content in various possible fields
          String? fileContent;

          // Try to find the base64 content in the JSON response
          // It might be directly in the response or nested
          if (jsonData.containsKey('content')) {
            fileContent = jsonData['content'].toString();
          } else if (jsonData.containsKey('data')) {
            fileContent = jsonData['data'].toString();
          } else if (jsonData.containsKey('file')) {
            fileContent = jsonData['file'].toString();
          } else if (jsonData.containsKey('fileContent')) {
            fileContent = jsonData['fileContent'].toString();
          }

          // If we couldn't find content in common fields, look for ANY very long string value
          // The base64 content might be under an unexpected key or even a numeric/empty key
          if (fileContent == null || fileContent.length < 100) {
            for (var entry in jsonData.entries) {
              if (entry.value is String) {
                final strValue = entry.value as String;
                if (strValue.length > 100 && entry.key != 'fileName' && entry.key != 'mimeType' && entry.key != 'message') {
                  // This is likely the base64 content
                  fileContent = strValue;
                  break;
                }
              }
            }
          }

          if (fileContent != null && fileContent.length > 50) {
            return {
              'content': fileContent,
              'mimeType': mimeType,
              'fileName': jsonData['fileName'] ?? 'file',
              'size': jsonData['size'] ?? fileContent.length,
              'encoding': 'base64',
              'message': jsonData['message'],
            };
          } else {
            talker.warning('🔍 MultimediaMessageWidget: File metadata found but no content detected!');
          }
        }
      }
    }

    return null;
  }

  /// Extract embedded image from JSON response (like Google Maps tool output)
  Map<String, dynamic>? _extractEmbeddedImage(dynamic jsonData) {
    if (jsonData is Map<String, dynamic>) {
      // Check for new format: {"content":[{"type":"image","image_url":"data:image/png;base64,..."}]}
      if (jsonData.containsKey('content')) {
        var content = jsonData['content'];

        // Handle array format with image objects
        if (content is List && content.isNotEmpty) {
          for (var item in content) {
            if (item is Map<String, dynamic>) {
              // Check for new image format: {"type":"image","image_url":"data:..."}
              if (item['type'] == 'image' && item['image_url'] is String) {
                final imageUrl = item['image_url'] as String;

                // Extract MIME type from data URL
                String mimeType = 'image/png'; // default
                if (imageUrl.startsWith('data:')) {
                  final mimeMatch = RegExp(r'data:([^;]+);').firstMatch(imageUrl);
                  if (mimeMatch != null) {
                    mimeType = mimeMatch.group(1)!;
                  }
                }

                return {
                  'content': imageUrl,
                  'mimeType': mimeType,
                  'fileName': item['alt_text'] ?? 'map_image',
                  'size': 0,
                  'encoding': 'base64',
                };
              }

              // Check for old text format with nested JSON
              if (item['type'] == 'text' && item['text'] is String) {
                try {
                  final nestedJson = jsonDecode(item['text'] as String);
                  final nestedResult = _extractEmbeddedImage(nestedJson);
                  if (nestedResult != null) return nestedResult;
                } catch (e) {
                  // Not nested JSON, continue with other checks
                }
              }
            }
          }
        }
      }

      // Check for Google Maps-style response (old format)
      if (jsonData['success'] == true && jsonData['data'] is Map<String, dynamic>) {
        final data = jsonData['data'] as Map<String, dynamic>;

        // Look for base64 image content
        if (data['content'] is String && data['mimeType'] is String && data['mimeType'].toString().startsWith('image/')) {
          String imageContent = data['content'] as String;

          // Handle different base64 formats
          if (data['encoding'] == 'base64' && !imageContent.startsWith('data:')) {
            // Raw base64 data, add proper data URL prefix
            imageContent = 'data:${data['mimeType']};base64,$imageContent';
          }

          return {
            'content': imageContent,
            'mimeType': data['mimeType'],
            'fileName': data['fileName'] ?? 'image',
            'size': data['size'] ?? 0,
            'markers': data['markers'],
            'mapConfig': data['mapConfig'],
          };
        }
      }

      // Check for other embedded image patterns
      if (jsonData.containsKey('image_data') || jsonData.containsKey('base64_image')) {
        // Handle other image response formats
        return {
          'content': jsonData['image_data'] ?? jsonData['base64_image'],
          'mimeType': jsonData['image_type'] ?? jsonData['mimeType'] ?? 'image/png',
          'fileName': jsonData['filename'] ?? jsonData['fileName'] ?? 'image',
        };
      }
    }

    return null;
  }

  /// Build response containing embedded image with JSON metadata
  Widget _buildEmbeddedImageResponse(BuildContext context, Map<String, dynamic> jsonData, Map<String, dynamic> imageData) {
    final content = imageData['content'] as String;
    final mimeType = imageData['mimeType'] as String;

    // Create MCPContent for the image
    final imageContent = MCPContent(type: 'image', data: content, mimeType: mimeType);

    // Show the image with standard display controls (fullscreen zoom, download, HTML export)
    return _buildStandardizedImage(context, imageContent);
  }

  /// Build response containing embedded file (Excel, PDF, etc.) with download capability
  Widget _buildEmbeddedFileResponse(BuildContext context, Map<String, dynamic> jsonData, Map<String, dynamic> fileData) {
    final content = fileData['content'] as String;
    final mimeType = fileData['mimeType'] as String;
    final fileName = fileData['fileName'] as String;
    final fileSize = fileData['size'] as int;
    final message = fileData['message'] as String?;

    // Determine file icon and color based on MIME type
    IconData fileIcon;
    Color fileColor;
    String fileTypeLabel;

    if (mimeType.contains('spreadsheet') || mimeType.contains('excel')) {
      fileIcon = Icons.table_chart;
      fileColor = Colors.green;
      fileTypeLabel = 'Excel file';
    } else if (mimeType.contains('pdf')) {
      fileIcon = Icons.picture_as_pdf;
      fileColor = Colors.red;
      fileTypeLabel = 'PDF file';
    } else if (mimeType.contains('word') || mimeType.contains('document')) {
      fileIcon = Icons.description;
      fileColor = Colors.blue;
      fileTypeLabel = 'Word document';
    } else {
      fileIcon = Icons.insert_drive_file;
      fileColor = Theme.of(context).colorScheme.primary;
      fileTypeLabel = 'File';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // File preview card with download button
        Card(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () async {
              // Decode base64 content
              try {
                final bytes = base64Decode(content);

                final result = await _saveFileToDownloads(bytes, fileName);
                if (!context.mounted) return;

                if (result) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('File saved to Downloads: $fileName'),
                      duration: const Duration(seconds: 3),
                      action: SnackBarAction(label: 'OK', onPressed: () {}),
                    ),
                  );
                } else {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('Failed to save file'), duration: Duration(seconds: 2)));
                }
              } catch (e) {
                talker.error('🔍 MultimediaMessageWidget: Error decoding/saving file: $e');
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), duration: const Duration(seconds: 2)));
              }
            },
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  // File icon
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: fileColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                    child: Icon(fileIcon, color: fileColor, size: 32),
                  ),
                  const SizedBox(width: 16),
                  // File info
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          fileTypeLabel,
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          fileName,
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _formatFileSize(fileSize),
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  // Download button
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(Icons.download, color: Theme.of(context).colorScheme.onPrimaryContainer, size: 24),
                  ),
                ],
              ),
            ),
          ),
        ),

        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerRight,
          child: Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () async {
                  try {
                    final bytes = base64Decode(content);
                    final result = await _saveFileToDownloads(bytes, fileName);
                    if (!context.mounted) return;
                    if (result) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text('File saved to Downloads: $fileName'), duration: const Duration(seconds: 2)));
                    } else {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('Failed to save file'), duration: Duration(seconds: 2)));
                    }
                  } catch (e) {
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), duration: const Duration(seconds: 2)));
                  }
                },
                icon: const Icon(Icons.download, size: 16),
                label: const Text('Download'),
                style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
              ),
              OutlinedButton.icon(
                onPressed: () => _shareBase64File(context, base64Data: content, fileName: fileName, mimeType: mimeType),
                icon: const Icon(Icons.share, size: 16),
                label: const Text('Share'),
                style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
              ),
            ],
          ),
        ),

        // Show message if available
        if (message != null && message.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2)),
            ),
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontStyle: FontStyle.italic,
                color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildMCPFileAttachment(BuildContext context, MCPContent content) {
    final mimeType = content.mimeType ?? 'application/octet-stream';
    final fileName = _getFileNameFromMimeType(mimeType);
    final fileIcon = _getFileIconFromMimeType(mimeType);
    final fileSize = content.data != null ? _formatFileSizeFromBase64Length((content.data!.length * 3 / 4).round()) : 'Unknown size';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(fileIcon, size: 32, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(fileName, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Text(
                  '$mimeType \u2022 $fileSize',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            onPressed: () => _downloadFile(context, content, fileName),
            icon: const Icon(Icons.download, size: 16),
            label: const Text('Download'),
            style: ElevatedButton.styleFrom(visualDensity: VisualDensity.compact),
          ),
        ],
      ),
    );
  }

  String _getFileNameFromMimeType(String mimeType) {
    switch (mimeType) {
      case 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet':
        return 'measurements_export.xlsx';
      case 'application/vnd.ms-excel':
        return 'measurements_export.xls';
      case 'text/csv':
        return 'measurements_export.csv';
      case 'application/pdf':
        return 'document.pdf';
      case 'image/png':
        return 'map.png';
      case 'image/jpeg':
        return 'map.jpg';
      default:
        return 'download_file';
    }
  }

  IconData _getFileIconFromMimeType(String mimeType) {
    if (mimeType.contains('spreadsheet') || mimeType.contains('excel')) {
      return Icons.table_chart;
    } else if (mimeType.contains('csv')) {
      return Icons.grid_on;
    } else if (mimeType.contains('pdf')) {
      return Icons.picture_as_pdf;
    } else if (mimeType.startsWith('image/')) {
      return Icons.image;
    } else if (mimeType.startsWith('text/')) {
      return Icons.description;
    }
    return Icons.attach_file;
  }

  String _formatFileSizeFromBase64Length(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Future<void> _downloadFile(BuildContext context, MCPContent content, String fileName) async {
    try {
      if (content.data == null) {
        throw Exception('No file data available');
      }

      // Desktop/mobile download using file picker
      await _downloadFileDesktop(context, content.data!, fileName, content.mimeType ?? 'application/octet-stream');

      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('File "$fileName" saved successfully'), backgroundColor: Colors.green));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Download failed: $e'), backgroundColor: Colors.red));
      }
    }
  }

  Future<void> _downloadFileDesktop(BuildContext context, String base64Data, String fileName, String mimeType) async {
    final bytes = base64Decode(base64Data);

    // Use file picker to save file
    String? outputFile = await FilePicker.saveFile(dialogTitle: 'Save file', fileName: fileName);

    if (outputFile != null) {
      final file = File(outputFile);
      await file.writeAsBytes(bytes);
    }
  }

  Future<bool> _saveFileToDownloads(Uint8List bytes, String fileName) async {
    try {
      // Desktop/mobile native app download using path_provider
      Directory? downloadsDir;
      try {
        downloadsDir = await getDownloadsDirectory();
      } catch (_) {
        downloadsDir = await getApplicationDocumentsDirectory();
      }

      if (downloadsDir == null) {
        talker.error('Could not access downloads directory');
        return false;
      }

      final filePath = '${downloadsDir.path}/$fileName';
      final file = File(filePath);
      await file.writeAsBytes(bytes);

      // Auto-open file with system viewer on mobile
      if (Platform.isAndroid || Platform.isIOS) {
        final result = await OpenFile.open(filePath);
        if (result.type != ResultType.done) {
          talker.warning('⚠️ Failed to auto-open file: ${result.message}');
        } else {}
      }

      return true;
    } catch (e) {
      talker.error('Save to downloads failed: $e');
      return false;
    }
  }

  Future<void> _shareBase64File(
    BuildContext context, {
    required String base64Data,
    required String fileName,
    required String mimeType,
  }) async {
    try {
      final bytes = base64Decode(base64Data);
      final tempDir = await getTemporaryDirectory();
      final safeName = fileName.trim().isNotEmpty ? fileName.trim() : 'shared_file';
      final tempFile = File('${tempDir.path}/${DateTime.now().microsecondsSinceEpoch}_$safeName');
      await tempFile.writeAsBytes(bytes, flush: true);

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(tempFile.path, mimeType: mimeType)],
          fileNameOverrides: [safeName],
          title: safeName,
          subject: safeName,
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Share failed: $e'), backgroundColor: Colors.red));
    }
  }

  // ----------------------------------------------------------------------------------------------------
  // Drive File/Folder List
  // ----------------------------------------------------------------------------------------------------

  /// Build a clickable file/folder list from a Google Drive JSON response.
  /// Expects JSON with a `"files"` array of objects with `name`, `mimeType`,
  /// and optionally `webViewLink`, `size`, `modifiedTime`.
  Widget _buildDriveFileList(BuildContext context, String content) {
    try {
      final jsonData = jsonDecode(content);
      if (jsonData is! Map || jsonData['files'] is! List) {
        return _buildJsonContent(context, content);
      }
      final files = (jsonData['files'] as List).whereType<Map>().toList();
      final folderPath = jsonData['folderPath']?.toString() ?? jsonData['query']?.toString() ?? 'Drive';
      final totalReturned = jsonData['returned'] ?? files.length;

      const maxVisible = 20;
      final hasMore = files.length > maxVisible;
      final visible = hasMore ? files.take(maxVisible).toList() : files;

      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.cloud, size: 16, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Google Drive \u2014 $folderPath ($totalReturned items)',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (hasMore)
                  IconButton(
                    icon: Icon(Icons.search, size: 18, color: Theme.of(context).colorScheme.primary),
                    onPressed: () => _showFullScreenOutput(context, const JsonEncoder.withIndent('  ').convert(jsonData)),
                    tooltip: 'View all',
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    padding: EdgeInsets.zero,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            ...visible.map((f) => _buildDriveFileRow(context, f)),
            if (hasMore)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Showing $maxVisible of ${files.length} items',
                  style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic, color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ),
          ],
        ),
      );
    } catch (e) {
      talker.warning('📄 Failed to parse Drive file list: $e');
      return _buildJsonContent(context, content);
    }
  }

  Widget _buildDriveFileRow(BuildContext context, Map<dynamic, dynamic> file) {
    final name = (file['name'] ?? '').toString();
    final mimeType = (file['mimeType'] ?? '').toString();
    final webLink = file['webViewLink']?.toString();
    final isFolder = mimeType == 'application/vnd.google-apps.folder';
    final sizeBytes = int.tryParse(file['size']?.toString() ?? '') ?? 0;
    final path = file['path']?.toString();

    // Pick icon and color based on mime type
    IconData icon;
    Color iconColor;
    if (isFolder) {
      icon = Icons.folder;
      iconColor = Colors.amber.shade700;
    } else if (mimeType.contains('pdf')) {
      icon = Icons.picture_as_pdf;
      iconColor = Colors.red.shade700;
    } else if (mimeType.contains('spreadsheet') || mimeType.contains('excel')) {
      icon = Icons.table_chart;
      iconColor = Colors.green.shade700;
    } else if (mimeType.contains('document') || mimeType.contains('word')) {
      icon = Icons.description;
      iconColor = Colors.blue.shade700;
    } else if (mimeType.contains('presentation') || mimeType.contains('powerpoint')) {
      icon = Icons.slideshow;
      iconColor = Colors.orange.shade700;
    } else if (mimeType.contains('image')) {
      icon = Icons.image;
      iconColor = Colors.purple.shade400;
    } else if (mimeType.contains('video')) {
      icon = Icons.videocam;
      iconColor = Colors.pink.shade400;
    } else if (mimeType.contains('audio')) {
      icon = Icons.audiotrack;
      iconColor = Colors.teal.shade400;
    } else {
      icon = Icons.insert_drive_file;
      iconColor = Theme.of(context).colorScheme.primary;
    }

    // Format size
    String sizeStr = '';
    if (!isFolder && sizeBytes > 0) {
      if (sizeBytes < 1024) {
        sizeStr = '$sizeBytes B';
      } else if (sizeBytes < 1024 * 1024) {
        sizeStr = '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
      } else {
        sizeStr = '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
      }
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        onTap: webLink != null ? () => _launchUrl(webLink) : null,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.04),
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: iconColor),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: webLink != null ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onSurface,
                        decoration: webLink != null ? TextDecoration.underline : null,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (path != null || sizeStr.isNotEmpty)
                      Text(
                        [?path, if (sizeStr.isNotEmpty) sizeStr].join(' • '),
                        style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.onSurfaceVariant),
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              if (webLink != null) Icon(Icons.open_in_new, size: 16, color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.6)),
            ],
          ),
        ),
      ),
    );
  }

  // ----------------------------------------------------------------------------------------------------
  // Document Search Result List
  // ----------------------------------------------------------------------------------------------------

  /// Build a clickable document list from a Document MCP server JSON response.
  /// Expects JSON with a `"documents"` array of objects with `filePath`, `fileName`.
  Widget _buildDocumentFileList(BuildContext context, String content) {
    try {
      final jsonData = jsonDecode(content);
      if (jsonData is! Map || jsonData['documents'] is! List) {
        // Also try 'results' key from search_documents
        if (jsonData is Map && jsonData['results'] is List) {
          final results = (jsonData['results'] as List).whereType<Map>().toList();
          final filePaths = results.where((r) => r['filePath'] is String).map((r) => r['filePath'] as String).toList();
          if (filePaths.isNotEmpty) {
            return _buildFileListClickable(context, filePaths);
          }
        }
        return _buildJsonContent(context, content);
      }
      final docs = (jsonData['documents'] as List).whereType<Map>().toList();
      final filePaths = docs.where((d) => d['filePath'] is String).map((d) => d['filePath'] as String).toList();
      if (filePaths.isEmpty) {
        return _buildJsonContent(context, content);
      }
      return _buildFileListClickable(context, filePaths);
    } catch (e) {
      talker.warning('📄 Failed to parse document file list: $e');
      return _buildJsonContent(context, content);
    }
  }

  // ----------------------------------------------------------------------------------------------------
  // General file list renderer (local / search results)
  // ----------------------------------------------------------------------------------------------------

  Widget _buildFileListFromContent(BuildContext context, String content) {
    List<String> filePaths = [];

    // Try parsing as JSON first
    try {
      final jsonData = jsonDecode(content);

      // Direct array format: ["file1.md", "file2.txt"]
      if (jsonData is List) {
        filePaths = jsonData.map((item) => item.toString()).toList();
      }
      // Object format: {"results": ["file1.md", "file2.txt"]}
      // Also handles: {"results": [{"filePath": "...", ...}, ...]}
      else if (jsonData is Map && jsonData['results'] is List) {
        final results = jsonData['results'] as List;
        if (results.isNotEmpty && results.first is Map) {
          // Object results -- extract filePath from each item
          filePaths = results
              .where((item) => item is Map && (item['filePath'] is String || item['path'] is String))
              .map((item) => (item['filePath'] ?? item['path']).toString())
              .toList();
        } else {
          filePaths = results.map((item) => item.toString()).toList();
        }
      }
      // Also check for 'documents' key: {"documents": [{"filePath": "...", ...}]}
      else if (jsonData is Map && jsonData['documents'] is List) {
        final docs = jsonData['documents'] as List;
        filePaths = docs
            .where((item) => item is Map && (item['filePath'] is String || item['path'] is String))
            .map((item) => (item['filePath'] ?? item['path']).toString())
            .toList();
      }
    } catch (e) {
      // Not JSON, try filelist:// format
      if (content.contains('filelist://')) {
        final markerIndex = content.indexOf('filelist://');
        final afterMarker = content.substring(markerIndex + 'filelist://'.length).trim();

        // Split by newlines and filter empty lines
        filePaths = afterMarker.split('\n').map((line) => line.trim()).where((line) => line.isNotEmpty && !line.startsWith('```')).toList();
      }
    }

    if (filePaths.isEmpty) {
      talker.warning('ðŸ“ No file paths found in content');
      return const SizedBox.shrink();
    }

    return _buildFileListClickable(context, filePaths);
  }

  /// Build file list widget with clickable download links
  /// When clicked, triggers chunked download via MCP server
  Widget _buildFileListClickable(BuildContext context, List<String> filePaths) {
    const maxVisibleFiles = 10; // Show first 10 files, rest in dialog
    final hasMore = filePaths.length >= maxVisibleFiles; // Show magnifier at threshold
    final visibleFiles = hasMore ? filePaths.take(maxVisibleFiles).toList() : filePaths;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.file_download, size: 16, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 4),
              Text(
                'Files (${filePaths.length})',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary),
              ),
              if (hasMore) ...[
                const Spacer(),
                IconButton(
                  icon: Icon(Icons.search, size: 18, color: Theme.of(context).colorScheme.primary),
                  onPressed: () => _showAllFilesDialog(context, filePaths),
                  tooltip: 'View all files',
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  padding: EdgeInsets.zero,
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          ...visibleFiles.map((filePath) {
            // Extract filename from path (handles SAF content:// URIs too)
            final filename = SafBridge.fileNameFromUri(filePath);

            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2)),
                ),
                child: Row(
                  children: [
                    InkWell(
                      onTap: () => _shareResolvedFile(context, filePath),
                      borderRadius: BorderRadius.circular(12),
                      child: Tooltip(
                        message: 'Share file',
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(Icons.share, size: 18, color: Theme.of(context).colorScheme.primary),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        filename,
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Theme.of(context).colorScheme.onSurface),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                    const SizedBox(width: 4),
                    InkWell(
                      onTap: () => _copyFolderPath(context, filePath),
                      borderRadius: BorderRadius.circular(12),
                      child: Tooltip(
                        message: 'Copy folder path',
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(Icons.folder_open, size: 18, color: Theme.of(context).colorScheme.primary),
                        ),
                      ),
                    ),
                    InkWell(
                      onTap: () => _showFileInfoDialog(context, filePath),
                      borderRadius: BorderRadius.circular(12),
                      child: Tooltip(
                        message: 'File details',
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(Icons.info_outline, size: 18, color: Theme.of(context).colorScheme.primary),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
          if (hasMore)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Showing ${visibleFiles.length} of ${filePaths.length} files',
                style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic, color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }

  /// Show full-screen dialog with all files in a searchable scrollable list
  void _showAllFilesDialog(BuildContext context, List<String> allFiles) {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close',
      barrierColor: Colors.black54,
      pageBuilder: (ctx, animation, secondaryAnimation) {
        return _FileListDialog(
          files: allFiles,
          onFileSelected: (filePath) {
            Navigator.of(ctx).pop();
            _triggerFileDownload(context, filePath);
          },
        );
      },
      transitionBuilder: (ctx, animation, secondaryAnimation, child) {
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
          child: child,
        );
      },
      transitionDuration: const Duration(milliseconds: 300),
    );
  }

  /// Copy the containing folder path to clipboard.
  Future<void> _copyFolderPath(BuildContext context, String filePath) async {
    try {
      var normalizedPath = filePath.replaceAll('/', Platform.pathSeparator).replaceAll('\\', Platform.pathSeparator);
      var file = File(normalizedPath);

      // Try DuckDB resolution if file not found
      if (!await file.exists()) {
        final resolved = await _resolveFilePathFromIndex(filePath);
        if (resolved != null) {
          normalizedPath = resolved.replaceAll('/', Platform.pathSeparator).replaceAll('\\', Platform.pathSeparator);
          file = File(normalizedPath);
        }
      }

      final folderPath = file.parent.path;
      await Clipboard.setData(ClipboardData(text: folderPath));
      if (context.mounted) {
        final messenger = ScaffoldMessenger.of(context);
        messenger.showSnackBar(
          SnackBar(
            content: Text('Copied: $folderPath'),
            duration: const Duration(seconds: 4),
            behavior: SnackBarBehavior.floating,
            action: SnackBarAction(
              label: 'OPEN',
              onPressed: () async {
                messenger.hideCurrentSnackBar();
                try {
                  final mimeType = lookupMimeType(normalizedPath);
                  final result = await OpenFile.open(normalizedPath, type: mimeType);
                  if (result.type != ResultType.done) {
                    messenger.showSnackBar(
                      SnackBar(content: Text(result.message), behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 3)),
                    );
                  }
                } catch (e) {
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text('Could not open file: $e'),
                      behavior: SnackBarBehavior.floating,
                      duration: const Duration(seconds: 3),
                    ),
                  );
                }
              },
            ),
          ),
        );
      }
    } catch (e) {
      talker.error('📁 Error copying folder path: $e');
    }
  }

  Future<void> _shareResolvedFile(BuildContext context, String filePath) async {
    try {
      var normalizedPath = filePath.replaceAll('/', Platform.pathSeparator).replaceAll('\\', Platform.pathSeparator);
      var file = File(normalizedPath);

      if (!await file.exists()) {
        final resolved = await _resolveFilePathFromIndex(filePath);
        if (resolved != null) {
          normalizedPath = resolved.replaceAll('/', Platform.pathSeparator).replaceAll('\\', Platform.pathSeparator);
          file = File(normalizedPath);
        }
      }

      if (!await file.exists()) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('File not found for sharing'), behavior: SnackBarBehavior.floating));
        return;
      }

      final fileName = normalizedPath.split(Platform.pathSeparator).last;
      await SharePlus.instance.share(ShareParams(files: [XFile(normalizedPath)], title: fileName, subject: fileName));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Share failed: $e'), backgroundColor: Colors.red));
    }
  }

  /// Show a detail dialog for a file: full path, folder, size, date, open button.
  Future<void> _showFileInfoDialog(BuildContext context, String filePath) async {
    // SAF content:// URIs cannot be accessed via dart:io File — handle separately.
    if (SafBridge.isSafUri(filePath)) {
      final filename = SafBridge.fileNameFromUri(filePath);
      // Decode the tree root as the "folder" display value.
      final folderDisplay = Uri.decodeFull(filePath);
      if (!context.mounted) return;
      showDialog<void>(
        context: context,
        builder: (ctx) {
          final theme = Theme.of(ctx);
          return AlertDialog(
            title: Row(
              children: [
                Icon(Icons.info_outline, size: 22, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                const Expanded(child: Text('File Info', style: TextStyle(fontSize: 18))),
              ],
            ),
            content: SizedBox(
              width: 400,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _fileInfoRow(theme, Icons.description, 'Name', filename, selectable: true),
                  const SizedBox(height: 12),
                  _fileInfoRow(theme, Icons.folder, 'Folder', folderDisplay, selectable: true),
                ],
              ),
            ),
            actions: [
              TextButton.icon(
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('Copy Path'),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: filePath));
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Path copied'), duration: Duration(seconds: 1), behavior: SnackBarBehavior.floating),
                  );
                },
              ),
              FilledButton.icon(
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Open File'),
                onPressed: () {
                  Navigator.pop(ctx);
                  _triggerFileDownload(context, filePath);
                },
              ),
            ],
          );
        },
      );
      return;
    }

    var normalizedPath = filePath.replaceAll('/', Platform.pathSeparator).replaceAll('\\', Platform.pathSeparator);
    var file = File(normalizedPath);

    // Resolve via DuckDB if needed
    if (!await file.exists()) {
      final resolved = await _resolveFilePathFromIndex(filePath);
      if (resolved != null) {
        normalizedPath = resolved.replaceAll('/', Platform.pathSeparator).replaceAll('\\', Platform.pathSeparator);
        file = File(normalizedPath);
      }
    }

    final exists = await file.exists();
    final filename = normalizedPath.split(Platform.pathSeparator).last;
    final folderPath = file.parent.path;
    String sizeStr = '\u2013';
    String dateStr = '\u2013';

    if (exists) {
      try {
        final stat = await file.stat();
        final bytes = stat.size;
        if (bytes < 1024) {
          sizeStr = '$bytes B';
        } else if (bytes < 1024 * 1024) {
          sizeStr = '${(bytes / 1024).toStringAsFixed(1)} KB';
        } else {
          sizeStr = '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
        }
        dateStr =
            '${stat.modified.day.toString().padLeft(2, '0')}.${stat.modified.month.toString().padLeft(2, '0')}.${stat.modified.year}  ${stat.modified.hour.toString().padLeft(2, '0')}:${stat.modified.minute.toString().padLeft(2, '0')}';
      } catch (_) {}
    }

    if (!context.mounted) return;

    showDialog<void>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.info_outline, size: 22, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              const Expanded(child: Text('File Info', style: TextStyle(fontSize: 18))),
            ],
          ),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _fileInfoRow(theme, Icons.description, 'Name', filename, selectable: true),
                const SizedBox(height: 12),
                _fileInfoRow(theme, Icons.folder, 'Folder', folderPath, selectable: true),
                const SizedBox(height: 12),
                _fileInfoRow(theme, Icons.straighten, 'Size', sizeStr),
                const SizedBox(height: 12),
                _fileInfoRow(theme, Icons.calendar_today, 'Modified', dateStr),
                if (!exists) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(Icons.warning_amber, size: 16, color: Colors.orange[700]),
                      const SizedBox(width: 6),
                      Text('File not found at this path', style: TextStyle(fontSize: 12, color: Colors.orange[700])),
                    ],
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton.icon(
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Copy Path'),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: normalizedPath));
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Path copied'), duration: Duration(seconds: 1), behavior: SnackBarBehavior.floating),
                );
              },
            ),
            FilledButton.icon(
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Open File'),
              onPressed: () {
                Navigator.pop(ctx);
                _triggerFileDownload(context, normalizedPath);
              },
            ),
          ],
        );
      },
    );
  }

  Widget _fileInfoRow(ThemeData theme, IconData icon, String label, String value, {bool selectable = false}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: theme.colorScheme.primary.withValues(alpha: 0.7)),
        const SizedBox(width: 8),
        SizedBox(
          width: 56,
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w600),
          ),
        ),
        Expanded(
          child: selectable
              ? SelectableText(value, style: const TextStyle(fontSize: 12))
              : Text(value, style: const TextStyle(fontSize: 12)),
        ),
      ],
    );
  }

  /// Open a local file with the system's default handler (cross-platform).
  /// If the path is just a filename, attempts to resolve it via DuckDB index.
  /// Falls back to "Save As" via file_picker if direct open fails.
  Future<void> _triggerFileDownload(BuildContext context, String filePath) async {
    // SAF content:// URIs must be opened via Intent on Android; skip File() operations.
    if (SafBridge.isSafUri(filePath)) {
      try {
        await SafBridge.openFile(filePath);
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Could not open file: $e'), backgroundColor: Theme.of(context).colorScheme.error));
        }
      }
      return;
    }

    // Normalize path separators for the current platform
    var normalizedPath = filePath.replaceAll('/', Platform.pathSeparator).replaceAll('\\', Platform.pathSeparator);

    var file = File(normalizedPath);
    if (!await file.exists()) {
      talker.warning('âš ï¸ File not found at path, trying DuckDB lookup: $normalizedPath');

      // Try to resolve via DuckDB document index (filename â†’ full path)
      final resolvedPath = await _resolveFilePathFromIndex(filePath);
      if (resolvedPath != null) {
        normalizedPath = resolvedPath.replaceAll('/', Platform.pathSeparator).replaceAll('\\', Platform.pathSeparator);
        file = File(normalizedPath);
      }

      if (!await file.exists()) {
        talker.warning('âš ï¸ File not found after DuckDB lookup: $normalizedPath');
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('File not found: ${normalizedPath.split(Platform.pathSeparator).last}'),
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
          );
        }
        return;
      }
    }

    try {
      final result = await OpenFile.open(normalizedPath);
      if (result.type != ResultType.done) {
        talker.warning('âš ï¸ Could not open file: ${result.message}');
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open file: ${result.message}')));
        }
      } else {}
    } catch (e) {
      talker.error('âŒ Failed to open file: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to open file: $e'), backgroundColor: Theme.of(context).colorScheme.error));
      }
    }
  }

  /// Resolve a filename (or partial path) to a full path via the DuckDB document_index.
  Future<String?> _resolveFilePathFromIndex(String fileNameOrPath) async {
    try {
      final db = DuckDbService();
      final fileName = fileNameOrPath.split('/').last.split('\\').last;
      final escapedName = fileName.replaceAll("'", "''");

      // Try exact filename match first
      var rows = await db.query("SELECT file_path FROM document_index WHERE file_name = '$escapedName' LIMIT 1");

      if (rows.isNotEmpty && rows.first[0] != null) {
        return rows.first[0].toString();
      }

      // Try case-insensitive match
      rows = await db.query("SELECT file_path FROM document_index WHERE LOWER(file_name) = LOWER('$escapedName') LIMIT 1");

      if (rows.isNotEmpty && rows.first[0] != null) {
        return rows.first[0].toString();
      }

      // Try partial path match (e.g. "Documents\\file.pdf")
      if (fileNameOrPath.contains('/') || fileNameOrPath.contains('\\')) {
        final escapedPath = fileNameOrPath.replaceAll("'", "''").replaceAll('\\', '/');
        rows = await db.query("SELECT file_path FROM document_index WHERE REPLACE(file_path, '\\\\', '/') LIKE '%$escapedPath' LIMIT 1");
        if (rows.isNotEmpty && rows.first[0] != null) {
          return rows.first[0].toString();
        }
      }

      return null;
    } catch (e) {
      talker.error('âŒ DuckDB lookup failed: $e');
      return null;
    }
  }

  Widget _buildJsonContent(BuildContext context, String text) {
    // Enhanced JSON detection and formatting for tool outputs
    String processedText = text;
    bool isFormatted = false;

    // Clean ANSI escape codes and other non-JSON characters
    String cleanedText = text;

    // Remove ANSI escape sequences (color codes, etc.)
    cleanedText = cleanedText.replaceAll(RegExp(r'\x1B\[[0-9;]*[mGKHf]'), '');

    // Remove emojis and other problematic Unicode characters that cause UTF-8 issues
    // This removes most emoji ranges and special characters
    cleanedText = cleanedText.replaceAll(RegExp(r'[\u{1F300}-\u{1F9FF}]', unicode: true), ''); // Emoji ranges
    cleanedText = cleanedText.replaceAll(RegExp(r'[\u{2600}-\u{26FF}]', unicode: true), ''); // Misc symbols
    cleanedText = cleanedText.replaceAll(RegExp(r'[\u{2700}-\u{27BF}]', unicode: true), ''); // Dingbats
    cleanedText = cleanedText.replaceAll(RegExp(r'[\u{FE00}-\u{FE0F}]', unicode: true), ''); // Variation selectors
    cleanedText = cleanedText.replaceAll(RegExp(r'[\u{1F000}-\u{1F02F}]', unicode: true), ''); // Mahjong tiles
    cleanedText = cleanedText.replaceAll(RegExp(r'[\u{1F0A0}-\u{1F0FF}]', unicode: true), ''); // Playing cards

    // Remove box drawing characters and other decorative characters
    cleanedText = cleanedText.replaceAll(RegExp(r'[\u{2500}-\u{257F}]', unicode: true), '');

    // Remove other control characters except newline, tab, carriage return
    cleanedText = cleanedText.replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '');

    // Remove replacement character (ï¿½) that might have been inserted
    cleanedText = cleanedText.replaceAll('\uFFFD', '');

    // First, unescape common escape sequences that might come from server responses
    String unescapedText = cleanedText.replaceAll('\\n', '\n').replaceAll('\\t', '\t').replaceAll('\\r', '\r').replaceAll('\\"', '"');

    try {
      // Try to parse as JSON first (silent attempt)
      // First try to parse the entire text as JSON
      final dynamic jsonData = jsonDecode(unescapedText.trim());

      // Check for embedded image data (like Google Maps response)
      final embeddedImage = _extractEmbeddedImage(jsonData);

      if (embeddedImage != null) {
        return _buildEmbeddedImageResponse(context, jsonData, embeddedImage);
      }

      // Check for embedded file data (like Excel files)
      final embeddedFile = _extractEmbeddedFile(jsonData);

      if (embeddedFile != null) {
        return _buildEmbeddedFileResponse(context, jsonData, embeddedFile);
      }

      // Format as regular JSON
      processedText = const JsonEncoder.withIndent('  ').convert(jsonData);
      isFormatted = true;
    } catch (e) {
      // JSON parsing failed - try fixing control characters or treat as plain text
      try {
        // Clean ANSI codes and control characters first
        String fixedText = cleanedText;
        // Fix common control character issues in JSON text fields
        fixedText = fixedText.replaceAllMapped(RegExp(r'"text":"([^"]*)"'), (match) {
          String textContent = match.group(1)!;
          // Escape control characters properly
          textContent = textContent.replaceAll('\n', '\\n').replaceAll('\r', '\\r').replaceAll('\t', '\\t').replaceAll('"', '\\"');
          return '"text":"$textContent"';
        });

        final dynamic jsonData = jsonDecode(fixedText.trim());

        // Check for embedded image data (like Google Maps response)
        final embeddedImage = _extractEmbeddedImage(jsonData);

        if (embeddedImage != null) {
          return _buildEmbeddedImageResponse(context, jsonData, embeddedImage);
        }

        // Check for embedded file data (like Excel files)
        final embeddedFile = _extractEmbeddedFile(jsonData);

        if (embeddedFile != null) {
          return _buildEmbeddedFileResponse(context, jsonData, embeddedFile);
        }

        // Format as regular JSON
        processedText = const JsonEncoder.withIndent('  ').convert(jsonData);
        isFormatted = true;
      } catch (fixError) {
        // Not JSON - will treat as plain text
      }

      // If direct parsing fails, look for JSON objects within the unescaped text
      final jsonPattern = RegExp(r'\{(?:[^{}]|{[^{}]*})*\}', multiLine: true, dotAll: true);
      final matches = jsonPattern.allMatches(unescapedText);

      if (matches.isNotEmpty) {
        // Try to format JSON objects found in the text
        StringBuffer buffer = StringBuffer();
        int lastEnd = 0;

        for (final match in matches) {
          // Add text before the JSON
          buffer.write(unescapedText.substring(lastEnd, match.start));

          try {
            // Try to parse and format the JSON
            final jsonStr = unescapedText.substring(match.start, match.end);
            final jsonData = jsonDecode(jsonStr);

            final formattedJson = const JsonEncoder.withIndent('  ').convert(jsonData);
            buffer.write(formattedJson);
            isFormatted = true;
          } catch (jsonError) {
            // If this JSON fragment can't be parsed, keep it as is
            buffer.write(unescapedText.substring(match.start, match.end));
          }

          lastEnd = match.end;
        }

        // Add any remaining text after the last JSON
        buffer.write(unescapedText.substring(lastEnd));
        processedText = buffer.toString();
      } else {
        // No JSON found, just use the unescaped text
        processedText = unescapedText;
      }
    }

    final outputLines = processedText.split('\n');
    const maxPreviewLines = 20;
    const maxPreviewChars = 5000;
    final shouldTruncate = outputLines.length > maxPreviewLines || processedText.length > maxPreviewChars;

    var previewText = processedText;
    if (shouldTruncate) {
      final limitedLines = outputLines.take(maxPreviewLines).join('\n');
      if (limitedLines.length > maxPreviewChars) {
        previewText = '${limitedLines.substring(0, maxPreviewChars)}\n...';
      } else {
        previewText = '$limitedLines\n...';
      }
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isFormatted)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Icon(Icons.code, size: 16, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 4),
                  Text(
                    'JSON Format',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: Icon(Icons.search, size: 18, color: Theme.of(context).colorScheme.primary),
                    onPressed: () => _showFullScreenOutput(context, processedText),
                    tooltip: 'View full screen',
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    padding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),
          if (!isFormatted && shouldTruncate)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Text(
                    'Preview (${outputLines.length} lines)',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: Icon(Icons.search, size: 18, color: Theme.of(context).colorScheme.primary),
                    onPressed: () => _showFullScreenOutput(context, processedText),
                    tooltip: 'View full screen',
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    padding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),
          // Word-wrapped text by default (no horizontal scrolling)
          SelectableText(previewText, style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
        ],
      ),
    );
  }

  /// Show full-screen dialog with scrollable output
  /// User prompt: show inline text if short; truncate + magnifier icon if long.
  static const int _promptTruncateThreshold = 300;

  Widget _buildUserPromptText(BuildContext context) {
    final content = message.content;
    final isModern = AppPreferencesService.instance.uiStyle == 'modern';
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final onPrimary = isModern
        ? (isDark ? const Color(0xFFE9D5FF) : const Color(0xFF581C87))
        : Theme.of(context).colorScheme.onPrimary;
    if (content.length <= _promptTruncateThreshold) {
      return SelectableText(content, style: TextStyle(color: onPrimary));
    }
    final preview = content.substring(0, _promptTruncateThreshold);
    final suppressed = content.length - _promptTruncateThreshold;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText('$preview...', style: TextStyle(color: onPrimary)),
        const SizedBox(height: 4),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('+$suppressed chars', style: TextStyle(color: onPrimary.withValues(alpha: 0.65), fontSize: 11)),
            const SizedBox(width: 4),
            GestureDetector(
              onTap: () => _showFullScreenPrompt(context, content),
              child: Tooltip(
                message: 'Show full prompt',
                child: Icon(Icons.search, size: 16, color: onPrimary.withValues(alpha: 0.85)),
              ),
            ),
          ],
        ),
      ],
    );
  }

  void _showFullScreenPrompt(BuildContext context, String text) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        insetPadding: EdgeInsets.zero,
        child: Container(
          width: MediaQuery.of(context).size.width,
          height: MediaQuery.of(context).size.height,
          color: Theme.of(context).colorScheme.surface,
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  border: Border(bottom: BorderSide(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2))),
                ),
                child: Row(
                  children: [
                    Icon(Icons.chat_bubble_outline, size: 20, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 8),
                    Text(
                      'Full Prompt (${text.length} chars)',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurface),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.copy),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: text));
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
                      },
                      tooltip: 'Copy',
                    ),
                    IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop(), tooltip: 'Close'),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(text, style: const TextStyle(fontSize: 14)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showFullScreenOutput(BuildContext context, String text) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        insetPadding: EdgeInsets.zero,
        child: Container(
          width: MediaQuery.of(context).size.width,
          height: MediaQuery.of(context).size.height,
          color: Theme.of(context).colorScheme.surface,
          child: Column(
            children: [
              // Header with close button
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  border: Border(bottom: BorderSide(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2))),
                ),
                child: Row(
                  children: [
                    Icon(Icons.code, size: 20, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 8),
                    Text(
                      'Tool Output',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurface),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.copy),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: text));
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
                      },
                      tooltip: 'Copy',
                    ),
                    IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop(), tooltip: 'Close'),
                  ],
                ),
              ),
              // Scrollable content
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(text, style: const TextStyle(fontSize: 13, fontFamily: 'monospace')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Save image file using file picker - works on web and desktop
  Future<void> _exportImage(BuildContext context, MessageAttachment attachment) async {
    try {
      Uint8List? imageBytes;
      String defaultFileName = attachment.name;

      // If bytes are available (web platform), use them directly
      if (attachment.bytes != null) {
        imageBytes = attachment.bytes;
      }
      // Get image bytes based on path type
      else if (attachment.path.startsWith('data:image/')) {
        // Handle data URLs (base64 encoded images)
        final commaIndex = attachment.path.indexOf(',');
        if (commaIndex > 0) {
          final base64Data = attachment.path.substring(commaIndex + 1);
          imageBytes = base64Decode(base64Data);
        }
      } else if (attachment.path.startsWith('http')) {
        // Handle network images - show info that this isn't supported yet
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Network image export not supported yet'), backgroundColor: Colors.orange));
        return;
      } else {
        // Handle local file paths
        try {
          final file = File(attachment.path);
          if (file.existsSync()) {
            imageBytes = await file.readAsBytes();
            // Extract filename from path if not already set
            if (defaultFileName.isEmpty) {
              defaultFileName = attachment.path.split('/').last;
              if (!defaultFileName.endsWith('.png')) {
                defaultFileName += '.png';
              }
            }
          }
        } catch (e) {
          talker.error('Error reading local file: $e');
        }
      }

      if (imageBytes == null) {
        throw Exception('Could not read image data');
      }

      // Desktop/Mobile: Use file picker to save the file
      String? outputPath = await FilePicker.saveFile(
        dialogTitle: 'Save Chart Image',
        fileName: defaultFileName,
        type: FileType.custom,
        allowedExtensions: ['png', 'jpg', 'jpeg'],
      );

      if (outputPath != null) {
        // Write the file
        final outputFile = File(outputPath);
        await outputFile.writeAsBytes(imageBytes);

        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Image saved to: $outputPath'), backgroundColor: Colors.green, duration: const Duration(seconds: 3)),
        );
      } else {
        // User cancelled the save dialog
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Export cancelled'), backgroundColor: Colors.orange));
      }
    } catch (e) {
      talker.error('Error exporting image: $e');
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export failed: ${e.toString()}'), backgroundColor: Colors.red));
    }
  }

  /// Extract base64 images from HTML content
  List<Map<String, String>> _extractBase64ImagesFromHtml(String htmlContent) {
    final images = <Map<String, String>>[];

    // Pattern to match img tags with base64 data
    final imgPattern = RegExp(
      r'<img[^>]+src=["'
      "'"
      r']data:(image/[^;]+);base64,([A-Za-z0-9+/=]+)["'
      "'"
      r'][^>]*>',
      multiLine: true,
      dotAll: true,
    );

    for (final match in imgPattern.allMatches(htmlContent)) {
      final mimeType = match.group(1) ?? 'image/png';
      final base64Data = match.group(2) ?? '';

      if (base64Data.isNotEmpty) {
        images.add({'mimeType': mimeType, 'base64': base64Data});
      }
    }

    return images;
  }

  /// Build image widget from base64 data with toolbar
  Widget _buildImageFromBase64(BuildContext context, String base64Data, String mimeType) {
    try {
      final bytes = base64Decode(base64Data);

      return Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header with toolbar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: const BorderRadius.only(topLeft: Radius.circular(12), topRight: Radius.circular(12)),
              ),
              child: Row(
                children: [
                  Icon(Icons.image, size: 16, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    'Chart Image',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w500, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                  const Spacer(),
                  // HTML Preview button
                  IconButton(
                    onPressed: () {
                      final htmlSnippet =
                          '<img src="data:$mimeType;base64,$base64Data" alt="Chart Image" style="max-width:100%; height:auto;" />';
                      _showHtmlPreview(context, htmlSnippet);
                    },
                    icon: Icon(Icons.preview, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    tooltip: 'Preview HTML',
                  ),
                  // Copy HTML embed code button
                  IconButton(
                    onPressed: () async {
                      final htmlSnippet =
                          '<img src="data:$mimeType;base64,$base64Data" alt="Chart Image" style="max-width:100%; height:auto;" />';
                      await Clipboard.setData(ClipboardData(text: htmlSnippet));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('HTML embed code copied to clipboard'), duration: Duration(seconds: 2)));
                    },
                    icon: Icon(Icons.code, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    tooltip: 'Copy HTML embed code',
                  ),
                  // Download button
                  IconButton(
                    onPressed: () async {
                      try {
                        final extension = mimeType.split('/').last;
                        final fileName = 'chart_${DateTime.now().millisecondsSinceEpoch}.$extension';
                        final result = await _saveFileToDownloads(bytes, fileName);
                        if (!context.mounted) return;
                        if (result) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Image saved to Downloads: $fileName'), duration: const Duration(seconds: 2)),
                          );
                        } else {
                          ScaffoldMessenger.of(
                            context,
                          ).showSnackBar(const SnackBar(content: Text('Failed to save image'), duration: Duration(seconds: 2)));
                        }
                      } catch (e) {
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(SnackBar(content: Text('Error: $e'), duration: const Duration(seconds: 2)));
                      }
                    },
                    icon: Icon(Icons.download, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    tooltip: 'Download image',
                  ),
                  // Fullscreen button
                  IconButton(
                    onPressed: () => _showFullScreenImage(context, 'data:$mimeType;base64,$base64Data'),
                    icon: Icon(Icons.fullscreen, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    tooltip: 'Fullscreen',
                  ),
                ],
              ),
            ),
            // Image content
            ClipRRect(
              borderRadius: const BorderRadius.only(bottomLeft: Radius.circular(12), bottomRight: Radius.circular(12)),
              child: Image.memory(
                bytes,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) {
                  return Container(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.broken_image, size: 32, color: Colors.red),
                        const SizedBox(height: 8),
                        Text('Failed to display image: $error', style: const TextStyle(color: Colors.red, fontSize: 12)),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      );
    } catch (e) {
      talker.error('Error building image from base64: $e');
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: Colors.red.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
        child: Text('Error loading image: $e', style: const TextStyle(color: Colors.red)),
      );
    }
  }

  /// Detect if content is HTML
  bool _isHtmlContent(String content) {
    // Detect only meaningful HTML snippets; avoid false positives from plain text/JSON.
    final lowerContent = content.toLowerCase();

    final hasDoctype = lowerContent.contains('<!doctype') || lowerContent.contains('<! doctype');
    final hasHtmlOpen = lowerContent.contains('<html');
    final hasHtmlClose = lowerContent.contains('</html>');
    final hasBodyOpen = lowerContent.contains('<body');
    final hasBodyClose = lowerContent.contains('</body>');
    final hasHeadOpen = lowerContent.contains('<head');
    final hasHeadClose = lowerContent.contains('</head>');
    final hasIframe = lowerContent.contains('<iframe');
    final hasIframeClose = lowerContent.contains('</iframe>');
    final hasIframeSrcdoc = lowerContent.contains('srcdoc=');
    final hasHtmlCodeBlock = lowerContent.contains("```html") && (hasDoctype || hasHtmlOpen || hasBodyOpen || hasIframe);
    final hasTablePair = lowerContent.contains('<table') && lowerContent.contains('</table>');

    // Strong detection only when structure is complete enough.
    final hasFullHtmlDoc = (hasDoctype || hasHtmlOpen) && (hasHtmlClose || (hasBodyOpen && hasBodyClose));
    final hasStructuredSection = (hasHeadOpen && hasHeadClose) || (hasBodyOpen && hasBodyClose) || hasTablePair;
    final hasValidIframe = hasIframe && (hasIframeClose || hasIframeSrcdoc);

    final isHtml = hasFullHtmlDoc || hasStructuredSection || hasValidIframe || hasHtmlCodeBlock;

    // Log what was detected
    if (isHtml) {
    } else {
      talker.warning(' HTML NOT detected. Content starts with: ${content.substring(0, content.length > 200 ? 200 : content.length)}');
    }

    return isHtml;
  }

  /// Extract HTML from content (handles text before/after HTML)
  String _extractHtmlContent(String content) {
    // 1. Check for ```html or ```xml or ```svg code blocks
    for (final pattern in [r'```html\s*(.*?)```', r'```xml\s*(.*?)```', r'```svg\s*(.*?)```', r'```\s*(<!DOCTYPE.*?)```', r'```\s*(<html.*?)```']) {
      final match = RegExp(pattern, multiLine: true, dotAll: true).firstMatch(content);
      if (match != null) {
        return match.group(1)!.trim();
      }
    }

    // 2. For DOCTYPE or full HTML documents, extract from first occurrence to last closing tag
    final lowerContent = content.toLowerCase();
    if (lowerContent.contains('<!doctype') || lowerContent.contains('<! doctype') || lowerContent.contains('<html')) {
      int firstDoctype = content.indexOf('<!DOCTYPE');
      if (firstDoctype < 0) firstDoctype = content.indexOf('<!doctype');
      if (firstDoctype < 0) firstDoctype = content.indexOf('<! DOCTYPE');
      if (firstDoctype < 0) firstDoctype = content.indexOf('<! doctype');

      final firstHtml = content.toLowerCase().indexOf('<html');
      final startIndex = firstDoctype >= 0 ? firstDoctype : (firstHtml >= 0 ? firstHtml : -1);

      if (startIndex >= 0) {
        final lastHtmlClose = content.toLowerCase().lastIndexOf('</html>');
        if (lastHtmlClose > startIndex) {
          return content.substring(startIndex, lastHtmlClose + 7);
        }
      }
    }

    // 3. For custom tags (SVG, Canvas, tables, divs, scripts, styles), extract from first opening tag to last closing tag
    final htmlTags = ['<table', '<div', '<tr>', '<svg', '<canvas', '<script', '<style', '<ul', '<ol', '<p', '<h1', '<h2', '<h3'];
    bool hasTag = false;
    for (final tag in htmlTags) {
      if (content.contains(tag)) {
        hasTag = true;
        break;
      }
    }

    if (hasTag) {
      final firstTag = content.indexOf('<');
      final lastTag = content.lastIndexOf('>');
      if (firstTag >= 0 && lastTag > firstTag) {
        return content.substring(firstTag, lastTag + 1);
      }
    }

    return content;
  }

  /// Show fullscreen HTML preview with integrated export
  void _showHtmlPreview(BuildContext context, String extractedHtml) {
    Future(() async {
      try {
        final tempDir = Directory.systemTemp;
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final fileName = 'preview_$timestamp.html';
        final tempFile = File('${tempDir.path}/$fileName');
        
        String finalHtml = extractedHtml;
        if (!finalHtml.toLowerCase().contains('<html')) {
          finalHtml = '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>HTML Preview</title>
  <style>
    body { 
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; 
      padding: 20px; 
      margin: 0;
      background-color: #f8f9fa;
    }
  </style>
</head>
<body>
  $finalHtml
</body>
</html>
''';
        }
        await tempFile.writeAsString(finalHtml);

        final port = await _ensurePreviewServerRunning();
        final uri = Uri.parse('http://localhost:$port/$fileName');

        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        } else {
          await launchUrl(uri);
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to open HTML in browser: $e')),
          );
        }
      }
    });

    if (1 == 2) {
      final previewHtml = _injectFullHeightStyles(extractedHtml);
    final now = DateTime.now();
    final defaultFilename =
        '_${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';
    final filenameController = TextEditingController(text: defaultFilename);
    String selectedPageSize = 'A4';
    bool isLandscape = true;
    double selectedScale = 1.0;
    final theme = Theme.of(context);
    bool isSettingsOpen = false;

    // Check if settings differ from defaults
    bool settingsChanged() {
      return selectedPageSize != 'A4' || !isLandscape || selectedScale != 1.0;
    }

    // Get settings tooltip text
    String getSettingsTooltip() {
      return 'PDF Settings:\n'
          'Page: $selectedPageSize\n'
          'Orientation: ${isLandscape ? 'Landscape' : 'Portrait'}\n'
          'Scale: ${(selectedScale * 100).toInt()}%';
    }

    showDialog(
      context: context,
      builder: (context) => Dialog(
        insetPadding: EdgeInsets.zero,
        backgroundColor: Colors.transparent,
        child: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            appBar: AppBar(
              title: const Text('HTML Preview'),
              actions: [
                // Filename input field
                SizedBox(
                  width: 200,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8.0),
                    child: TextField(
                      controller: filenameController,
                      decoration: const InputDecoration(
                        hintText: 'Enter filename',
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        suffixText: '.pdf',
                      ),
                      style: TextStyle(fontSize: 14, color: theme.colorScheme.onSurface),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Settings button with visual indicator when changed
                Tooltip(
                  message: getSettingsTooltip(),
                  preferBelow: true,
                  child: Container(
                    decoration: settingsChanged() ? BoxDecoration(color: theme.colorScheme.primaryContainer, shape: BoxShape.circle) : null,
                    child: IconButton(
                      icon: Icon(Icons.settings, color: settingsChanged() ? theme.colorScheme.primary : null),
                      onPressed: () {
                        setState(() => isSettingsOpen = !isSettingsOpen);
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Export button
                IconButton(
                  icon: const Icon(Icons.picture_as_pdf),
                  tooltip: 'Export to PDF',
                  onPressed: () async {
                    final filename = filenameController.text.trim();
                    if (filename.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter a filename')));
                      return;
                    }
                    await _exportHtmlToPdf(
                      context,
                      extractedHtml,
                      filename,
                      pageSize: selectedPageSize,
                      landscape: isLandscape,
                      scale: selectedScale,
                    );
                  },
                ),
                const SizedBox(width: 8),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
              ],
            ),
            body: isSettingsOpen
                ? SingleChildScrollView(
                    child: Center(
                      child: Card(
                        clipBehavior: Clip.antiAlias,
                        margin: const EdgeInsets.all(32),
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: SizedBox(
                            width: 420,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('PDF Export Settings', style: theme.textTheme.titleLarge),
                                const SizedBox(height: 24),
                                // Page Size
                                Text('Page Size', style: theme.textTheme.titleSmall),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 4,
                                  children: ['A2', 'A3', 'A4', 'A5', 'Letter', 'Legal', 'Tabloid']
                                      .map(
                                        (size) => ChoiceChip(
                                          label: Text(size),
                                          selected: selectedPageSize == size,
                                          onSelected: (_) => setState(() => selectedPageSize = size),
                                        ),
                                      )
                                      .toList(),
                                ),
                                const SizedBox(height: 16),
                                // Orientation
                                Text('Orientation', style: theme.textTheme.titleSmall),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 4,
                                  children: [
                                    ChoiceChip(
                                      label: const Text('Portrait'),
                                      selected: !isLandscape,
                                      onSelected: (_) => setState(() => isLandscape = false),
                                    ),
                                    ChoiceChip(
                                      label: const Text('Landscape'),
                                      selected: isLandscape,
                                      onSelected: (_) => setState(() => isLandscape = true),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 16),
                                // Scale
                                Text('Scale', style: theme.textTheme.titleSmall),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 4,
                                  children: [0.5, 0.75, 1.0, 1.25, 1.5]
                                      .map(
                                        (scale) => ChoiceChip(
                                          label: Text('${(scale * 100).toInt()}%'),
                                          selected: selectedScale == scale,
                                          onSelected: (_) => setState(() => selectedScale = scale),
                                        ),
                                      )
                                      .toList(),
                                ),
                                const SizedBox(height: 24),
                                // Close button
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: ElevatedButton(onPressed: () => setState(() => isSettingsOpen = false), child: const Text('Done')),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  )
                : HtmlWebView(html: previewHtml),
          ),
        ),
      ),
    );
    }
  }

  String _injectFullHeightStyles(String html) {
    const styles = '''
<style>
  html, body { height: 100%; margin: 0; }
  body { min-height: 100vh; }
  iframe { width: 100%; height: 100%; min-height: 100vh; }
  .folium-map { width: 100% !important; height: 100% !important; }
  div[style*="position:relative"][style*="padding-bottom"][style*="height:0"] {
    height: 100vh !important;
    padding-bottom: 0 !important;
  }
</style>
''';

    if (html.contains('<head>')) {
      return html.replaceFirst('<head>', '<head>\n$styles');
    }

    if (html.contains('<html>')) {
      return html.replaceFirst('<html>', '<html>\n<head>\n$styles</head>');
    }

    return '$styles\n$html';
  }

  /// Export HTML to PDF
  Future<void> _exportHtmlToPdf(
    BuildContext context,
    String extractedHtml,
    String filename, {
    String pageSize = 'A4',
    bool landscape = true,
    double scale = 1.0,
  }) async {
    try {
      // Calculate font sizes based on scale
      final baseFontSize = (8 * scale).toStringAsFixed(1);
      final headingFontSize = (10 * scale).toStringAsFixed(1);
      final padding = (4 * scale).toStringAsFixed(1);

      // Create a styled complete HTML document for PDF with proper table rendering
      final completeHtml =
          '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { 
      font-family: Arial, sans-serif; 
      padding: 10px; 
      font-size: ${baseFontSize}px;
      transform: scale($scale);
      transform-origin: top left;
    }
    h2, h3 { 
      color: #1a73e8; 
      margin-bottom: 8px;
      font-size: ${headingFontSize}px;
    }
    table { 
      width: 100%; 
      border-collapse: collapse; 
      margin: 10px 0;
      table-layout: fixed;
    }
    thead {
      display: table-header-group;
    }
    tbody {
      display: table-row-group;
    }
    tr {
      page-break-inside: avoid;
    }
    th, td { 
      padding: ${padding}px 3px;
      border: 1px solid #ddd; 
      text-align: left;
      font-size: ${baseFontSize}px;
      word-wrap: break-word;
      overflow: hidden;
    }
    th { 
      background: linear-gradient(to right, #6dd5ed 0%, #2193b0 100%);
      color: white; 
      font-weight: bold;
      font-size: ${baseFontSize}px;
    }
    tr:nth-child(even) { 
      background-color: #f8f9fa; 
    }
    @page {
      size: $pageSize ${landscape ? 'landscape' : 'portrait'};
      margin: 10mm;
    }
    @media print {
      thead { display: table-header-group; }
      tbody { display: table-row-group; }
      tr { page-break-inside: avoid; }
    }
  </style>
</head>
<body>
$extractedHtml
</body>
</html>
''';

      // Call PdfMcpServer directly — no need for it to be active in the playground.
      final pdfServer = PdfMcpServer();
      final result = await pdfServer.executeTool('generate_pdf', {
        'content': completeHtml,
        'format': pageSize,
        'landscape': landscape,
        'printBackground': true,
        if (scale != 1.0) 'scale': scale,
      });

      if (result['error'] != null) {
        throw Exception('PDF generation failed: ${result['error']}');
      }

      final pdfBase64 = result['content'] as String?;
      if (pdfBase64 == null || pdfBase64.isEmpty) {
        throw Exception('No PDF data received');
      }
      final pdfBytes = base64Decode(pdfBase64);

      // Save file and open with system viewer
      {
        Directory? downloadsDir;
        try {
          downloadsDir = await getDownloadsDirectory();
        } catch (_) {
          downloadsDir = await getApplicationDocumentsDirectory();
        }

        if (downloadsDir != null) {
          final filePath = '${downloadsDir.path}/${filename.trim()}.pdf';
          final file = File(filePath);
          await file.writeAsBytes(pdfBytes);

          // Open PDF with system default app
          final result = await OpenFile.open(filePath);
          if (result.type != ResultType.done) {
            talker.warning('âš ï¸ Failed to open PDF: ${result.message}');
          }
        }
      }

      // Show success message
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('PDF saved as ${filename.trim()}.pdf'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } catch (e) {
      talker.error('Failed to convert HTML to PDF: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to generate PDF: $e'), backgroundColor: Colors.red));
      }
    }
  }

  /// Build HTML content viewer
  Widget _buildHtmlContent(BuildContext context) {
    // Extract just the HTML part from the content
    final normalizedContent = _normalizeHtmlContent(message.content);
    final extractedHtml = _extractHtmlContent(normalizedContent);

    return _buildHtmlRenderer(context, extractedHtml);
  }

  Widget _buildHtmlContentFromText(BuildContext context, String content) {
    final normalizedContent = _normalizeHtmlContent(content);
    final extractedHtml = _extractHtmlContent(normalizedContent);
    final embedImages = _extractBase64ImagesFromHtml(normalizedContent);
    int htmlStart = -1;
    String textBefore = '';
    String textAfter = '';

    final lowerContent = normalizedContent.toLowerCase();

    if (normalizedContent.contains('```html')) {
      htmlStart = normalizedContent.indexOf('```html');
      final htmlEnd = normalizedContent.indexOf('```', htmlStart + 7);
      if (htmlStart >= 0 && htmlEnd > htmlStart) {
        textBefore = htmlStart > 0 ? normalizedContent.substring(0, htmlStart).trim() : '';
        textAfter = htmlEnd + 3 < normalizedContent.length ? normalizedContent.substring(htmlEnd + 3).trim() : '';
      }
    } else if (lowerContent.contains('<!doctype') || lowerContent.contains('<! doctype') || lowerContent.contains('<html')) {
      int firstDoctype = lowerContent.indexOf('<!doctype');
      if (firstDoctype < 0) {
        firstDoctype = lowerContent.indexOf('<! doctype');
      }
      final firstHtml = lowerContent.indexOf('<html');
      htmlStart = firstDoctype >= 0 ? firstDoctype : firstHtml;

      if (htmlStart >= 0) {
        textBefore = htmlStart > 0 ? normalizedContent.substring(0, htmlStart).trim() : '';
        final lastHtmlClose = lowerContent.lastIndexOf('</html>');
        if (lastHtmlClose > htmlStart) {
          textAfter = lastHtmlClose + 7 < normalizedContent.length ? normalizedContent.substring(lastHtmlClose + 7).trim() : '';
        }
      }
    } else if (normalizedContent.contains('<table') || normalizedContent.contains('<div')) {
      htmlStart = normalizedContent.indexOf('<');
      if (htmlStart >= 0) {
        textBefore = htmlStart > 0 ? normalizedContent.substring(0, htmlStart).trim() : '';
        final lastTag = normalizedContent.lastIndexOf('>');
        if (lastTag > htmlStart) {
          textAfter = lastTag + 1 < normalizedContent.length ? normalizedContent.substring(lastTag + 1).trim() : '';
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (textBefore.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: MarkdownBody(
              data: _autoLinkifyUrls(textBefore),
              styleSheet: MarkdownStyleSheet.fromTheme(
                Theme.of(
                  context,
                ).copyWith(textTheme: Theme.of(context).textTheme.apply(bodyColor: Theme.of(context).colorScheme.onSurfaceVariant)),
              ),
              selectable: true,
              onTapLink: (text, href, title) => _launchUrl(href),
            ),
          ),
        ...embedImages.map(
          (imageData) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _buildImageFromBase64(context, imageData['base64']!, imageData['mimeType']!),
          ),
        ),
        _buildHtmlRenderer(context, extractedHtml),
        if (textAfter.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: MarkdownBody(
              data: textAfter,
              styleSheet: MarkdownStyleSheet.fromTheme(
                Theme.of(
                  context,
                ).copyWith(textTheme: Theme.of(context).textTheme.apply(bodyColor: Theme.of(context).colorScheme.onSurfaceVariant)),
              ),
              selectable: true,
            ),
          ),
      ],
    );
  }

  String _normalizeHtmlContent(String content) {
    String normalized = content.trim();

    if (normalized.startsWith('"') && normalized.endsWith('"')) {
      try {
        final decoded = jsonDecode(normalized);
        if (decoded is String) {
          normalized = decoded;
        }
      } catch (_) {
        // Fall back to simple unescape below
      }
    }

    if (normalized.contains(r'\n') || normalized.contains(r'\t') || normalized.contains(r'\r') || normalized.contains(r'\"')) {
      normalized = normalized
          .replaceAll(r'\n', '\n')
          .replaceAll(r'\t', '\t')
          .replaceAll(r'\r', '\r')
          .replaceAll(r'\"', '"')
          .replaceAll(r'\\', '\\');
    }

    return normalized;
  }

  /// Render HTML content as text with Preview button
  Widget _buildHtmlRenderer(BuildContext context, String extractedHtml) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with buttons
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'HTML Content',
                style: TextStyle(fontWeight: FontWeight.bold, color: theme.colorScheme.primary),
              ),
              Row(
                children: [
                  IconButton(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: extractedHtml));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('HTML copied to clipboard'), duration: Duration(seconds: 2)));
                    },
                    icon: const Icon(Icons.copy_all, size: 18),
                    tooltip: 'Copy HTML',
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                  ),
                  const SizedBox(width: 4),
                  ElevatedButton.icon(
                    onPressed: () => _showHtmlPreview(context, extractedHtml),
                    icon: const Icon(Icons.open_in_browser, size: 18),
                    label: const Text('Show HTML'),
                    style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8)),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Divider(),
          const SizedBox(height: 8),
          if (extractedHtml.toLowerCase().contains('<script')) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.orange.shade200),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber, size: 16, color: Colors.orange.shade800),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'JavaScript is not active in preview. Click "Show HTML" to open the interactive version in your browser.',
                      style: TextStyle(fontSize: 11, color: Colors.orange.shade900),
                    ),
                  ),
                ],
              ),
            ),
          ],
          // HTML preview thumbnail
          _HtmlPreviewThumbnail(html: extractedHtml),
        ],
      ),
    );
  }

  /// Build markdown content with optional horizontal scrolling for tables
  Widget _buildMarkdownWithScrollableContent(BuildContext context) {
    final content = message.content;

    // Debug: Check HTML detection
    _isHtmlContent(content);
    if (content.isNotEmpty) {}

    // Check for file list marker "filelist://"
    if (content.contains('filelist://')) {
      // Extract file paths after the marker
      final markerIndex = content.indexOf('filelist://');
      final textBefore = markerIndex > 0 ? content.substring(0, markerIndex).trim() : '';
      final afterMarker = content.substring(markerIndex + 'filelist://'.length).trim();

      // Split by newlines and filter empty lines
      final filePaths = afterMarker
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty && !line.startsWith('```'))
          .toList();

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (textBefore.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: MarkdownBody(
                data: _autoLinkifyUrls(textBefore),
                styleSheet: MarkdownStyleSheet.fromTheme(
                  Theme.of(
                    context,
                  ).copyWith(textTheme: Theme.of(context).textTheme.apply(bodyColor: Theme.of(context).colorScheme.onSurfaceVariant)),
                ),
                selectable: true,
                onTapLink: (text, href, title) => _launchUrl(href),
              ),
            ),
          _buildFileListClickable(context, filePaths),
        ],
      );
    }

    // Handle markdown-embedded data URI file outputs, e.g.
    // [report.xlsx](data:application/vnd.openxmlformats-officedocument.spreadsheetml.sheet;base64,...)
    final embeddedDataUri = _extractEmbeddedDataUriFromMarkdown(content);
    if (embeddedDataUri != null && embeddedDataUri['content'] is String) {
      final beforeText = (embeddedDataUri['beforeText'] as String?) ?? '';
      final afterText = (embeddedDataUri['afterText'] as String?) ?? '';
      final mimeType = (embeddedDataUri['mimeType'] as String?) ?? 'application/octet-stream';
      final fileName = (embeddedDataUri['fileName'] as String?) ?? 'file';
      final payload = embeddedDataUri['content'] as String;
      final fileSize = (embeddedDataUri['size'] as int?) ?? payload.length;

      Widget embeddedWidget;
      if (mimeType.toLowerCase().startsWith('image/')) {
        embeddedWidget = _buildEmbeddedImageResponse(context, const {}, {
          'content': 'data:$mimeType;base64,$payload',
          'mimeType': mimeType,
        });
      } else {
        embeddedWidget = _buildEmbeddedFileResponse(context, const {}, {
          'content': payload,
          'mimeType': mimeType,
          'fileName': fileName,
          'size': fileSize,
          'message': 'File extracted from tool output',
        });
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (beforeText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: MarkdownBody(
                data: _autoLinkifyUrls(beforeText),
                styleSheet: MarkdownStyleSheet.fromTheme(
                  Theme.of(
                    context,
                  ).copyWith(textTheme: Theme.of(context).textTheme.apply(bodyColor: Theme.of(context).colorScheme.onSurfaceVariant)),
                ),
                selectable: true,
                onTapLink: (text, href, title) => _launchUrl(href),
              ),
            ),
          embeddedWidget,
          if (afterText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: MarkdownBody(
                data: _autoLinkifyUrls(afterText),
                styleSheet: MarkdownStyleSheet.fromTheme(
                  Theme.of(
                    context,
                  ).copyWith(textTheme: Theme.of(context).textTheme.apply(bodyColor: Theme.of(context).colorScheme.onSurfaceVariant)),
                ),
                selectable: true,
                onTapLink: (text, href, title) => _launchUrl(href),
              ),
            ),
        ],
      );
    }

    // Check if content is HTML and render accordingly
    if (_isHtmlContent(content)) {
      // Extract embedded images from HTML before rendering
      final embedImages = _extractBase64ImagesFromHtml(content);

      // Find where the HTML actually starts in the original content
      int htmlStart = -1;
      String textBefore = '';
      String textAfter = '';

      final lowerContent = content.toLowerCase();

      // Try different approaches to find HTML boundaries
      if (content.contains('```html')) {
        // Code block format
        htmlStart = content.indexOf('```html');
        final htmlEnd = content.indexOf('```', htmlStart + 7);
        if (htmlStart >= 0 && htmlEnd > htmlStart) {
          textBefore = htmlStart > 0 ? content.substring(0, htmlStart).trim() : '';
          textAfter = htmlEnd + 3 < content.length ? content.substring(htmlEnd + 3).trim() : '';
        }
      } else if (lowerContent.contains('<!doctype') || lowerContent.contains('<! doctype') || lowerContent.contains('<html')) {
        // Full HTML document - find using case-insensitive search
        int firstDoctype = lowerContent.indexOf('<!doctype');
        if (firstDoctype < 0) {
          firstDoctype = lowerContent.indexOf('<! doctype');
        }
        final firstHtml = lowerContent.indexOf('<html');
        htmlStart = firstDoctype >= 0 ? firstDoctype : firstHtml;

        if (htmlStart >= 0) {
          textBefore = htmlStart > 0 ? content.substring(0, htmlStart).trim() : '';
          final lastHtmlClose = lowerContent.lastIndexOf('</html>');
          if (lastHtmlClose > htmlStart) {
            textAfter = lastHtmlClose + 7 < content.length ? content.substring(lastHtmlClose + 7).trim() : '';
          }
        }
      } else if (content.contains('<table') || content.contains('<div')) {
        // Table or div content
        htmlStart = content.indexOf('<');
        if (htmlStart >= 0) {
          textBefore = htmlStart > 0 ? content.substring(0, htmlStart).trim() : '';
          final lastTag = content.lastIndexOf('>');
          if (lastTag > htmlStart) {
            textAfter = lastTag + 1 < content.length ? content.substring(lastTag + 1).trim() : '';
          }
        }
      }

      // Build column with text, message attachments (charts), extracted images from HTML, and HTML
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (textBefore.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: MarkdownBody(
                data: _autoLinkifyUrls(textBefore),
                styleSheet: MarkdownStyleSheet.fromTheme(
                  Theme.of(
                    context,
                  ).copyWith(textTheme: Theme.of(context).textTheme.apply(bodyColor: Theme.of(context).colorScheme.onSurfaceVariant)),
                ),
                selectable: true,
                onTapLink: (text, href, title) => _launchUrl(href),
              ),
            ),
          // Display message attachments (e.g., matplotlib charts) first
          if (message.attachments != null && message.attachments!.isNotEmpty)
            ...message.attachments!.map(
              (attachment) => Padding(padding: const EdgeInsets.only(bottom: 12), child: _buildImageAttachment(context, attachment)),
            ),
          // Display extracted base64 images from HTML with toolbars
          ...embedImages.map(
            (imageData) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _buildImageFromBase64(context, imageData['base64']!, imageData['mimeType']!),
            ),
          ),
          _buildHtmlContent(context),
          if (textAfter.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: MarkdownBody(
                data: textAfter,
                styleSheet: MarkdownStyleSheet.fromTheme(
                  Theme.of(
                    context,
                  ).copyWith(textTheme: Theme.of(context).textTheme.apply(bodyColor: Theme.of(context).colorScheme.onSurfaceVariant)),
                ),
                selectable: true,
              ),
            ),
        ],
      );
    }

    // Check if content contains file lists (like from list_all_files_recursive)
    final fileListInfo = _extractFileListFromMarkdown(content);
    if (fileListInfo != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Show the text before the file list
          if (fileListInfo['beforeText'] != null && fileListInfo['beforeText'].isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: MarkdownBody(
                data: _autoLinkifyUrls(fileListInfo['beforeText']),
                styleSheet: MarkdownStyleSheet.fromTheme(
                  Theme.of(
                    context,
                  ).copyWith(textTheme: Theme.of(context).textTheme.apply(bodyColor: Theme.of(context).colorScheme.onSurfaceVariant)),
                ),
                selectable: true,
                onTapLink: (text, href, title) => _launchUrl(href),
              ),
            ),
          // Show the file list with download controls
          _buildFileListClickable(context, fileListInfo['files']),
          // Show the text after the file list
          if (fileListInfo['afterText'] != null && fileListInfo['afterText'].isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: MarkdownBody(
                data: _autoLinkifyUrls(fileListInfo['afterText']),
                styleSheet: MarkdownStyleSheet.fromTheme(
                  Theme.of(
                    context,
                  ).copyWith(textTheme: Theme.of(context).textTheme.apply(bodyColor: Theme.of(context).colorScheme.onSurfaceVariant)),
                ),
                selectable: true,
                onTapLink: (text, href, title) => _launchUrl(href),
              ),
            ),
        ],
      );
    }

    // Check if content contains markdown tables
    final hasMarkdownTable =
        content.contains('|') && content.split('\n').any((line) => line.trim().startsWith('|') && line.trim().endsWith('|'));

    // Check if content has very wide lines that need scrolling (but not if it's just URLs/links)
    // final linkifiedContent = _autoLinkifyUrls(content);
    final hasWidelines = content.split('\n').any((line) => line.length > 150 && !line.contains('http'));

    // Check if content contains CSV data (comma or semicolon-separated values with multiple lines)
    final lines = content.split('\n');
    final hasCsvData =
        lines.length > 5 &&
        (lines.any((line) => (line.contains(',') || line.contains(';')) && (line.split(',').length >= 2 || line.split(';').length >= 2)) &&
            lines.where((line) => line.contains(',') || line.contains(';')).length > 3);

    // Detect CSV in code blocks ```csv
    final hasCsvBlock = content.contains('```csv');

    // Check for markdown links or URLs - these need MarkdownBody rendering to be clickable
    // CRITICAL: Check for both raw URLs (http) and markdown format links [text](url)
    final hasLinks = content.contains('http') || content.contains('[Link]') || RegExp(r'\[.+?\]\(https?://.+?\)').hasMatch(content);

    // Show magnifier for tables, wide content, or CSV data (but NOT for content with links)
    // PRIORITY: If content has links, always use MarkdownBody (else branch) to ensure clickability
    if ((hasMarkdownTable || hasWidelines || hasCsvData || hasCsvBlock) && !hasLinks) {
      // Create truncated version for display (first 12 lines for CSV, 10 for others)
      final maxLines = (hasCsvData || hasCsvBlock) ? 12 : 10;
      final isTruncated = lines.length > maxLines || content.length > 500;
      final truncatedContent = isTruncated
          ? lines.take(maxLines).join('\n') + (lines.length > maxLines ? '\n... [${lines.length - maxLines} more lines]' : '')
          : content;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Add magnifier icon for full-screen view
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              if (isTruncated)
                Text(
                  'Tap magnifier to view full content',
                  style: TextStyle(
                    fontSize: 11,
                    fontStyle: FontStyle.italic,
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              IconButton(
                icon: Icon(Icons.search, size: 20, color: Theme.of(context).colorScheme.primary),
                onPressed: () => _showFullScreenOutput(context, content),
                tooltip: 'View full screen',
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                padding: EdgeInsets.zero,
              ),
            ],
          ),
          // Truncated preview with monospace font for tables
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHigh.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2)),
            ),
            child: SelectableText(
              truncatedContent,
              style: TextStyle(fontSize: 12, fontFamily: 'monospace', color: Theme.of(context).colorScheme.onSurface),
            ),
          ),
        ],
      );
    } else {
      // For regular content without tables, use standard markdown rendering
      return MarkdownBody(
        data: _autoLinkifyUrls(content),
        styleSheet: MarkdownStyleSheet.fromTheme(
          Theme.of(
            context,
          ).copyWith(textTheme: Theme.of(context).textTheme.apply(bodyColor: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
        selectable: true,
        onTapLink: (text, href, title) => _launchUrl(href),
      );
    }
  }

  Map<String, dynamic>? _extractEmbeddedDataUriFromMarkdown(String content) {
    final match = _markdownDataUriPattern.firstMatch(content);
    if (match == null) return null;

    final fileName = (match.group(1) ?? 'file').trim();
    final mimeType = (match.group(2) ?? 'application/octet-stream').trim();
    final payload = (match.group(3) ?? '').replaceAll(RegExp(r'\s+'), '');

    // If payload is missing/placeholder text, fall back to normal markdown rendering.
    if (payload.isEmpty || payload.contains('omitted')) return null;

    final estimatedSize = ((payload.length * 3) / 4).floor();
    final beforeText = content.substring(0, match.start).trim();
    final afterText = content.substring(match.end).trim();

    return {
      'fileName': fileName,
      'mimeType': mimeType,
      'content': payload,
      'size': estimatedSize,
      'beforeText': beforeText,
      'afterText': afterText,
    };
  }

  /// Check if tool result contains downloadable content (images or file lists)
  bool _hasDownloadableContent() {
    if (message.toolResult == null) {
      talker.debug('_hasDownloadableContent: No tool result');
      return false;
    }

    if (_isSearchGmailToolMessage()) {
      talker.debug('_hasDownloadableContent: Gmail result -> skip downloadable/HTML detection');
      return false;
    }

    talker.debug('_hasDownloadableContent: Checking ${message.toolResult!.content.length} content items');

    // Check for direct images
    final hasImages = message.toolResult!.content.any(
      (content) => content.type == 'image' && content.data != null && content.data!.isNotEmpty,
    );
    if (hasImages) {
      talker.debug('_hasDownloadableContent: Found images');
      return true;
    }

    // Check for embedded images in JSON text content (e.g. charts, maps)
    for (final content in message.toolResult!.content) {
      if (content.text != null && content.text!.isNotEmpty) {
        // Check for HTML content (e.g. interactive maps)
        if (_isHtmlContent(content.text!)) {
          talker.debug('_hasDownloadableContent: Found HTML content');
          return true;
        }
        try {
          final jsonData = jsonDecode(content.text!);
          if (_extractEmbeddedImage(jsonData) != null) {
            talker.debug('_hasDownloadableContent: Found embedded image in JSON');
            return true;
          }
        } catch (_) {
          // Not JSON, continue
        }
      }
    }

    // Check for file lists in text content
    for (final content in message.toolResult!.content) {
      if (content.text != null && content.text!.isNotEmpty) {
        talker.debug('_hasDownloadableContent: Checking text content (${content.text!.length} chars)');
        try {
          final jsonData = jsonDecode(content.text!);
          talker.debug('_hasDownloadableContent: Parsed JSON: ${jsonData.runtimeType}');

          // Check for direct array format: ["file1.md", "file2.txt"]
          if (jsonData is List && jsonData.isNotEmpty && jsonData.first is String) {
            final firstResult = jsonData.first as String;
            talker.debug('_hasDownloadableContent: First result from array: $firstResult');
            final parts = firstResult.split('.');
            if (parts.length >= 2) {
              final extension = parts.last.toLowerCase();
              talker.debug('_hasDownloadableContent: Extension: $extension');
              if (extension.length >= 2 && extension.length <= 5 && _extensionPattern.hasMatch(extension)) {
                return true;
              }
            }
          }

          // Check for object format: {"results": [...]}, {"documents": [...]}, or Drive {"files": [...]}
          if (jsonData is Map && (jsonData['results'] is List || jsonData['documents'] is List || jsonData['files'] is List)) {
            final results = (jsonData['results'] ?? jsonData['documents'] ?? jsonData['files']) as List;
            talker.debug('_hasDownloadableContent: Found results list with ${results.length} items');
            if (results.isNotEmpty) {
              String? firstResult;
              if (results.first is String) {
                firstResult = results.first as String;
              } else if (results.first is Map) {
                final firstMap = results.first as Map;
                if (firstMap['filePath'] is String) {
                  firstResult = firstMap['filePath'] as String;
                } else if (firstMap['path'] is String) {
                  firstResult = firstMap['path'] as String;
                } else if (firstMap['name'] is String) {
                  firstResult = firstMap['name'] as String;
                }
              }
              if (firstResult != null) {
                talker.debug('_hasDownloadableContent: First result: $firstResult');
                final parts = firstResult.split('.');
                if (parts.length >= 2) {
                  final extension = parts.last.toLowerCase();
                  talker.debug('_hasDownloadableContent: Extension: $extension');
                  if (extension.length >= 2 && extension.length <= 5 && _extensionPattern.hasMatch(extension)) {
                    return true;
                  } else if (jsonData['files'] is List) {
                    // Google Drive folder lists may include folders (no extension) - still auto-expand
                    return true;
                  }
                }
              }
            }
          }
        } catch (e) {
          talker.debug('_hasDownloadableContent: Failed to parse JSON: $e');
          // Not JSON or invalid format, continue
        }
      }
    }

    talker.debug('_hasDownloadableContent: No downloadable content found');
    return false;
  }

  /// Get a hint about what downloadable content is available
  String _getDownloadableContentHint() {
    final images = message.toolResult!.content.where((c) => c.type == 'image' && c.data != null).length;
    int fileCount = 0;

    // Count files in file lists
    for (final content in message.toolResult!.content) {
      if (content.text != null) {
        try {
          final jsonData = jsonDecode(content.text!);
          if (jsonData is Map && (jsonData['results'] is List || jsonData['documents'] is List || jsonData['files'] is List)) {
            final results = (jsonData['results'] ?? jsonData['documents'] ?? jsonData['files']) as List;
            if (results.isNotEmpty &&
                (results.first is String ||
                    (results.first is Map &&
                        (results.first['filePath'] != null || results.first['path'] != null || results.first['name'] != null)))) {
              fileCount = results.length;
              break;
            }
          }
        } catch (e) {
          // Continue
        }
      }
    }

    if (images > 0 && fileCount > 0) {
      return 'Contains $images image${images > 1 ? 's' : ''} and $fileCount file${fileCount > 1 ? 's' : ''}';
    } else if (images > 0) {
      return 'Contains $images image${images > 1 ? 's' : ''}';
    } else if (fileCount > 0) {
      return 'Contains $fileCount downloadable file${fileCount > 1 ? 's' : ''}';
    }
    return 'Contains downloadable content';
  }

  /// Extract file list from markdown-formatted LLM output
  /// Returns a map with 'files', 'beforeText', and 'afterText' or null if no file list found
  Map<String, dynamic>? _extractFileListFromMarkdown(String content) {
    final lines = content.split('\n');
    final List<String> files = [];
    int fileListStartIndex = -1;
    int fileListEndIndex = -1;

    // Detect file lists: Look for bullet points or numbered items that are file paths
    // Formats supported:
    //   - file_path.ext                              (bullet point)
    //   * file_path.ext                              (bullet point)
    //   1. **filename.ext** (Path: C:\..., Size: ..) (numbered list from LLM)

    // Regex for numbered list items: "1. **filename.ext** (Path: C:\full\path, ...)"
    final numberedPathRegex = RegExp(r'^\d+\.\s+\*\*(.+?)\*\*\s*\(Path:\s*(.+?),');

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();

      // â”€â”€ Check for numbered list with "(Path: ...)" â”€â”€
      final numberedMatch = numberedPathRegex.firstMatch(line);
      if (numberedMatch != null) {
        final extractedPath = numberedMatch.group(2)!.trim();
        if (fileListStartIndex == -1) {
          fileListStartIndex = i;
        }
        fileListEndIndex = i;
        files.add(extractedPath);
        continue;
      }

      // â”€â”€ Check if this line is a bullet point that looks like a file path â”€â”€
      if ((line.startsWith('- ') || line.startsWith('* '))) {
        // Extract the potential file path
        String filePath = line.substring(2).trim(); // Remove "- " or "* "

        // Skip if this looks like a field label (contains : after bold markers **)
        // Example: "**Created (agd_created):** 2025-11-10"
        if (filePath.contains('**') && filePath.contains(':')) {
          continue;
        }

        // Skip if line contains a colon (likely a label: value format)
        if (filePath.contains(':')) {
          continue;
        }

        // File must have a valid extension at the end
        // Common file extensions: txt, md, pdf, docx, xlsx, csv, json, xml, etc.
        final validExtensions = [
          'txt',
          'md',
          'pdf',
          'doc',
          'docx',
          'xls',
          'xlsx',
          'csv',
          'json',
          'xml',
          'yml',
          'yaml',
          'html',
          'htm',
          'css',
          'js',
          'ts',
          'py',
          'java',
          'cpp',
          'c',
          'h',
          'zip',
          'tar',
          'gz',
          'png',
          'jpg',
          'jpeg',
          'gif',
          'svg',
          'mp4',
          'mp3',
          'wav',
        ];

        // Check if path ends with a valid extension
        bool hasValidExtension = false;
        for (final ext in validExtensions) {
          if (filePath.toLowerCase().endsWith('.$ext')) {
            hasValidExtension = true;
            break;
          }
        }

        // Only add if it has a valid file extension
        if (hasValidExtension) {
          if (fileListStartIndex == -1) {
            fileListStartIndex = i;
          }
          fileListEndIndex = i;
          files.add(filePath);
        }
      } else if (fileListStartIndex != -1 && files.length >= 2) {
        // We found a file list and now we've hit a non-file line
        break;
      } else if (fileListStartIndex != -1) {
        // Reset if we only found one file
        files.clear();
        fileListStartIndex = -1;
        fileListEndIndex = -1;
      }
    }

    // Return file list if we found at least 2 files
    if (files.length >= 2 && fileListStartIndex != -1) {
      final beforeText = fileListStartIndex > 0 ? lines.sublist(0, fileListStartIndex).join('\n').trim() : '';
      final afterText = fileListEndIndex < lines.length - 1 ? lines.sublist(fileListEndIndex + 1).join('\n').trim() : '';

      return {'files': files, 'beforeText': beforeText, 'afterText': afterText};
    }

    return null;
  }

  /// Get icon for downloadable content type
  IconData _getDownloadableContentIcon() {
    final hasImages = message.toolResult!.content.any((c) => c.type == 'image' && c.data != null);
    if (hasImages) return Icons.image;
    return Icons.file_download;
  }

  /// Get count description for downloadable content
  String _getDownloadableContentCount() {
    final images = message.toolResult!.content.where((c) => c.type == 'image' && c.data != null).length;
    int fileCount = 0;

    for (final content in message.toolResult!.content) {
      if (content.text != null) {
        try {
          final jsonData = jsonDecode(content.text!);
          if (jsonData is Map && (jsonData['results'] is List || jsonData['documents'] is List)) {
            final results = (jsonData['results'] ?? jsonData['documents']) as List;
            if (results.isNotEmpty &&
                (results.first is String ||
                    (results.first is Map && (results.first['filePath'] != null || results.first['path'] != null)))) {
              fileCount = results.length;
              break;
            }
          }
        } catch (e) {
          // Continue
        }
      }
    }

    if (images > 0 && fileCount > 0) {
      return '${images}img + ${fileCount}files';
    } else if (images > 0) {
      return 'image${images > 1 ? 's' : ''}';
    } else if (fileCount > 0) {
      return '${fileCount}file${fileCount > 1 ? 's' : ''}';
    }
    return 'content';
  }
}

/// Collapsible tool call header widget
class _ToolCallHeader extends StatefulWidget {
  final String content;
  final ColorScheme colorScheme;

  const _ToolCallHeader({required this.content, required this.colorScheme});

  @override
  State<_ToolCallHeader> createState() => _ToolCallHeaderState();
}

class _ToolCallHeaderState extends State<_ToolCallHeader> {
  late bool _isExpanded;

  @override
  void initState() {
    super.initState();
    _isExpanded = false;
  }

  String get _singleLineContent {
    // Replace all newlines (both actual \n and escaped \\n) with spaces for single-line display
    return widget.content
        .replaceAll('\\n', ' ') // Handle escaped newlines
        .replaceAll('\n', ' ') // Handle actual newlines
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  bool get _hasMultipleLines {
    // Check for both actual newlines and escaped \\n sequences
    return widget.content.contains('\n') || widget.content.contains('\\n');
  }

  void _toggleExpanded() {
    setState(() {
      _isExpanded = !_isExpanded;
    });
  }

  void _showFullDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.build_circle, color: widget.colorScheme.tertiary),
            const SizedBox(width: 8),
            const Text('Tool Call Details'),
          ],
        ),
        content: SizedBox(
          width: MediaQuery.of(context).size.width * 0.7,
          child: SingleChildScrollView(
            child: SelectableText(widget.content, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: widget.content));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Tool call copied to clipboard')));
            },
            child: const Text('Copy'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: _hasMultipleLines ? _toggleExpanded : null,
      onLongPress: _hasMultipleLines ? _showFullDialog : null,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: widget.colorScheme.tertiary.withValues(alpha: 0.1),
          borderRadius: const BorderRadius.only(topLeft: Radius.circular(12), topRight: Radius.circular(12)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.build_circle, size: 20, color: widget.colorScheme.tertiary),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _isExpanded ? widget.content : _singleLineContent,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: widget.colorScheme.onSurfaceVariant,
                      fontFamily: _isExpanded ? 'monospace' : null,
                    ),
                    maxLines: _isExpanded ? null : 3,
                    overflow: _isExpanded ? null : TextOverflow.ellipsis,
                  ),
                  if (_hasMultipleLines && !_isExpanded) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Tap to expand \u2022 Long press for dialog',
                      style: TextStyle(
                        fontSize: 11,
                        fontStyle: FontStyle.italic,
                        color: widget.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (_hasMultipleLines)
              Icon(
                _isExpanded ? Icons.expand_less : Icons.expand_more,
                size: 20,
                color: widget.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
              ),
          ],
        ),
      ),
    );
  }
}

/// Widget for rendering HTML content (web and native)
class HtmlWebView extends StatelessWidget {
  final String html;

  const HtmlWebView({super.key, required this.html});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: HtmlRenderer(html: html),
    );
  }
}

/// Searchable file list dialog
class _FileListDialog extends StatefulWidget {
  final List<String> files;
  final Function(String) onFileSelected;

  const _FileListDialog({required this.files, required this.onFileSelected});

  @override
  State<_FileListDialog> createState() => _FileListDialogState();
}

class _FileListDialogState extends State<_FileListDialog> {
  final _searchController = TextEditingController();
  List<String> _filteredFiles = [];

  _FileSourceInfo _getFileSourceInfo(String filePath) => _getFileSourceInfoStatic(filePath);

  @override
  void initState() {
    super.initState();
    _filteredFiles = widget.files;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _filterFiles(String query) {
    setState(() {
      if (query.isEmpty) {
        _filteredFiles = widget.files;
      } else {
        _filteredFiles = widget.files.where((file) => file.toLowerCase().contains(query.toLowerCase())).toList();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop(), tooltip: 'Close'),
        title: Row(
          children: [
            Icon(Icons.folder_open, size: 20, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
            Text('All Files (${widget.files.length})'),
          ],
        ),
        elevation: 1,
      ),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchController,
              autofocus: false,
              decoration: InputDecoration(
                hintText: 'Search files...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          _filterFiles('');
                        },
                      )
                    : null,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
              onChanged: _filterFiles,
            ),
          ),
          // Results count
          if (_searchController.text.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Found ${_filteredFiles.length} of ${widget.files.length} files',
                  style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ),
            ),
          const SizedBox(height: 8),
          // File list
          Expanded(
            child: _filteredFiles.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.search_off, size: 48, color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
                        const SizedBox(height: 16),
                        Text('No files found', style: TextStyle(fontSize: 16, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _filteredFiles.length,
                    itemBuilder: (context, index) {
                      final filePath = _filteredFiles[index];
                      final filename = SafBridge.fileNameFromUri(filePath);
                      final sourceInfo = _getFileSourceInfo(filePath);

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Tooltip(
                          message: filePath,
                          waitDuration: const Duration(milliseconds: 400),
                          child: InkWell(
                            onTap: () => widget.onFileSelected(filePath),
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.05),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2)),
                              ),
                              child: Row(
                                children: [
                                  Icon(sourceInfo.icon, size: 24, color: sourceInfo.iconColor ?? Theme.of(context).colorScheme.primary),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Row(
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: sourceInfo.badgeColor.withValues(alpha: 0.15),
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: Text(
                                            sourceInfo.label,
                                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: sourceInfo.badgeColor),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            filename,
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w500,
                                              color: Theme.of(context).colorScheme.onSurface,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Icon(Icons.open_in_new, size: 20, color: Theme.of(context).colorScheme.primary),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Widget that displays a preview of HTML content
class _HtmlPreviewThumbnail extends StatelessWidget {
  final String html;

  const _HtmlPreviewThumbnail({required this.html});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      height: 300,
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.3)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SingleChildScrollView(child: HtmlRenderer(html: html)),
      ),
    );
  }
}

/// Animated three-dot typing indicator shown while the LLM is streaming tokens.
class _TypingIndicator extends StatefulWidget {
  const _TypingIndicator();

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            // Each dot gets a delayed phase: 0, 0.33, 0.66
            final phase = (i / 3.0);
            final value = ((_controller.value - phase) % 1.0);
            // Bounce: 0→1→0 mapped through a sine curve
            final opacity = (math.sin(value * math.pi)).clamp(0.2, 1.0);
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 2),
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: color.withValues(alpha: opacity),
                shape: BoxShape.circle,
              ),
            );
          }),
        );
      },
    );
  }
}
