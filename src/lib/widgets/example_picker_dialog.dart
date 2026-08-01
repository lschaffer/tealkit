import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_theme.dart';
import '../providers/server_mode_provider.dart';
import '../utils/example_tasks_service.dart';

/// A bottom sheet that shows predefined example tasks the user can pick from.
///
/// Usage:
/// ```dart
/// final example = await ExamplePickerDialog.show(context);
/// if (example != null) { /* apply example */ }
/// ```
class ExamplePickerDialog extends ConsumerStatefulWidget {
  const ExamplePickerDialog({super.key, this.requiredToolType, this.excludedToolType, this.title, this.subtitle});

  final String? requiredToolType;
  final String? excludedToolType;
  final String? title;
  final String? subtitle;

  /// Opens the picker and returns the selected [ExampleTask], or null if dismissed.
  static Future<ExampleTask?> show(
    BuildContext context, {
    String? requiredToolType,
    String? excludedToolType,
    String? title,
    String? subtitle,
  }) {
    return showModalBottomSheet<ExampleTask>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) =>
          ExamplePickerDialog(requiredToolType: requiredToolType, excludedToolType: excludedToolType, title: title, subtitle: subtitle),
    );
  }

  @override
  ConsumerState<ExamplePickerDialog> createState() => _ExamplePickerDialogState();
}

class _ExamplePickerDialogState extends ConsumerState<ExamplePickerDialog> {
  List<ExampleTask>? _examples;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final examples = await ExampleTasksService.load();
      if (mounted) setState(() => _examples = examples);
    } catch (e) {
      if (mounted) setState(() => _examples = []);
    }
  }

  List<ExampleTask> _filtered(String langCode) {
    var all = _examples ?? [];

    // In Light Server mode, hide heavy unavailable tools (document search, website search)
    final serverState = ref.read(serverModeProvider).value;
    if (serverState != null && serverState.isRemote && serverState.isLightMode) {
      all = all.where((e) => !e.tools.contains('document') && !e.tools.contains('website_search')).toList();
    }

    final byRequired = widget.requiredToolType == null ? all : all.where((e) => e.tools.contains(widget.requiredToolType)).toList();
    final byTool = widget.excludedToolType == null
        ? byRequired
        : byRequired.where((e) => !e.tools.contains(widget.excludedToolType)).toList();
    final byLang = byTool.where((e) => e.lang == langCode).toList();
    return byLang.isNotEmpty ? byLang : byTool;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final langCode = Localizations.localeOf(context).languageCode;
    final filtered = _filtered(langCode);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        return Column(
          children: [
            // Handle
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 10, bottom: 4),
                width: 40,
                height: 4,
                decoration: BoxDecoration(color: theme.colorScheme.onSurfaceVariant.withAlpha(100), borderRadius: BorderRadius.circular(2)),
              ),
            ),
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 12, 8),
              child: Row(
                children: [
                  Icon(Icons.lightbulb_outline, color: AppTheme.warning, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(widget.title ?? 'Example Tasks', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                widget.subtitle ?? 'Tap an example to load its prompt and tools into the current view.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 8),
            const Divider(height: 1),
            // List
            Expanded(
              child: _examples == null
                  ? const Center(child: CircularProgressIndicator())
                  : filtered.isEmpty
                  ? Center(
                      child: Text('No examples available.', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                    )
                  : ListView.separated(
                      controller: scrollController,
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                      itemCount: filtered.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final ex = filtered[index];
                        return _ExampleCard(example: ex, onTap: () => Navigator.of(context).pop(ex));
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

/// Card widget rendering a single [ExampleTask].
class _ExampleCard extends StatelessWidget {
  const _ExampleCard({required this.example, required this.onTap});

  final ExampleTask example;
  final VoidCallback onTap;

  static String _toolLabel(String type) => switch (type) {
    'js_bridge' => 'JavaScript Tools',
    'web_search' => 'Web Search',
    'weather' => 'Weather',
    'document' => 'Document Search',
    'file' => 'File Output',
    'pdf' => 'PDF Generator',
    'chart' => 'Chart Generator',
    'gmail' => 'Gmail',
    'website_search' => 'Website Search',
    'google_drive' => 'Google Drive',
    'onedrive' => 'OneDrive',
    _ => type,
  };

  static IconData _toolIcon(String type) => switch (type) {
    'js_bridge' => Icons.javascript,
    'web_search' => Icons.search,
    'weather' => Icons.wb_sunny_outlined,
    'document' => Icons.folder_open,
    'file' => Icons.save_alt,
    'pdf' => Icons.picture_as_pdf_outlined,
    'chart' => Icons.bar_chart,
    'gmail' => Icons.email_outlined,
    'website_search' => Icons.language,
    'google_drive' => Icons.cloud_outlined,
    'onedrive' => Icons.cloud_outlined,
    _ => Icons.extension,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasNote = example.note != null && example.note!.isNotEmpty;

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title row with language badge
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(example.title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // Tools chips
              if (example.tools.isNotEmpty) ...[
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: example.tools.map((t) {
                    return Chip(
                      label: Text(_toolLabel(t), style: const TextStyle(fontSize: 11)),
                      avatar: Icon(_toolIcon(t), size: 14),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      visualDensity: VisualDensity.compact,
                    );
                  }).toList(),
                ),
                const SizedBox(height: 8),
              ],

              // Prompt preview
              Text(
                example.prompt,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),

              // Note / warning
              if (hasNote) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppTheme.warning.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.warning.withValues(alpha: 0.35), width: 1),
                  ),
                  child: Text(example.note!, style: TextStyle(fontSize: 11, color: AppTheme.warning)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
