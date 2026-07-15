import 'package:flutter/material.dart';

import '../services/function_hint_generation_service.dart';

/// A non-dismissable progress dialog for skill build operations.
///
/// Attach to a [ValueNotifier<FunctionHintProgress>] (e.g. from
/// [FunctionHintGenerationService.progressNotifier] or a locally-created notifier
/// that is updated by polling a server build-status endpoint).
///
/// Usage:
/// ```dart
/// unawaited(showDialog(
///   context: context,
///   barrierDismissible: false,
///   builder: (_) => FunctionHintBuildProgressDialog(
///     progressNotifier: FunctionHintGenerationService().progressNotifier,
///     onCancel: FunctionHintGenerationService().cancelGeneration,
///   ),
/// ));
/// try {
///   await FunctionHintGenerationService().ensureSkillsForBuiltInTools();
/// } finally {
///   if (context.mounted) Navigator.of(context).pop();
/// }
/// ```
class FunctionHintBuildProgressDialog extends StatelessWidget {
  const FunctionHintBuildProgressDialog({super.key, required this.progressNotifier, this.onCancel});

  final ValueNotifier<FunctionHintProgress> progressNotifier;

  /// Called when the user taps Cancel.  May be null to hide the button.
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('Building function hints…'),
        content: ValueListenableBuilder<FunctionHintProgress>(
          valueListenable: progressNotifier,
          builder: (_, progress, _) {
            final fraction = progress.total > 0 ? progress.processed / progress.total : null;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(value: fraction),
                const SizedBox(height: 12),
                Text('${progress.processed} / ${progress.total} tools', style: Theme.of(context).textTheme.bodyMedium),
                if (progress.currentTool.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    progress.currentTool,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 16),
                const Center(child: CircularProgressIndicator()),
              ],
            );
          },
        ),
        actions: onCancel == null ? null : [TextButton(onPressed: onCancel, child: const Text('Cancel'))],
      ),
    );
  }
}
