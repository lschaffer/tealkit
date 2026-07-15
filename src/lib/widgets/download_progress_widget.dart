import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/file_download_service.dart';
import '../services/chat_service.dart';

/// A widget that displays download progress in real-time
/// by listening to ChatService changes
class DownloadProgressWidget extends StatelessWidget {
  final String messageId;
  final String fileName;

  const DownloadProgressWidget({
    super.key,
    required this.messageId,
    required this.fileName,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatService>(
      builder: (context, chatService, child) {
        final progress = chatService.getDownloadProgress(messageId);

        if (progress == null) {
          return _buildLoadingCard(context);
        }

        if (progress.isComplete) {
          return _buildCompleteCard(context, progress);
        }

        return _buildProgressCard(context, progress);
      },
    );
  }

  Widget _buildLoadingCard(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Starting download: $fileName',
                style: const TextStyle(fontSize: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompleteCard(BuildContext context, DownloadProgress progress) {
    final theme = Theme.of(context);
    final totalMB = (progress.totalBytes / (1024 * 1024)).toStringAsFixed(2);
    return Card(
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Row(
          children: [
            Icon(Icons.check_circle, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    ' Downloaded: $fileName',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Size: $totalMB MB',
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                  if (progress.savedPath != null && progress.savedPath != 'null')
                    Text(
                      'Saved to: ${progress.savedPath}',
                      style: TextStyle(
                        fontSize: 10,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressCard(BuildContext context, DownloadProgress progress) {
    final percent = progress.progressPercent;
    final downloadedMB = (progress.downloadedBytes / (1024 * 1024)).toStringAsFixed(2);
    final totalMB = (progress.totalBytes / (1024 * 1024)).toStringAsFixed(2);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.download, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    fileName,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${percent.toStringAsFixed(1)}%',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: percent / 100,
              backgroundColor: Colors.grey.shade200,
              valueColor: AlwaysStoppedAnimation<Color>(
                Theme.of(context).primaryColor,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '$downloadedMB MB / $totalMB MB',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
