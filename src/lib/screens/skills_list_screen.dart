import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../models/skill_def.dart';
import '../services/external_tools_settings_service.dart';
import '../services/skill_def_database_service.dart';
import '../widgets/skill_gallery_dialog.dart';
import '../widgets/skill_wizard_dialog.dart';

class SkillsListScreen extends ConsumerStatefulWidget {
  final bool selectionMode;
  final void Function(SkillDef skill)? onSkillSelected;

  const SkillsListScreen({
    super.key,
    this.selectionMode = false,
    this.onSkillSelected,
  });

  static Future<SkillDef?> showPicker(BuildContext context) {
    return showDialog<SkillDef>(
      context: context,
      builder: (_) =>
          Dialog.fullscreen(child: SkillsListScreen(selectionMode: true)),
    );
  }

  @override
  ConsumerState<SkillsListScreen> createState() => _SkillsListScreenState();
}

class _SkillsListScreenState extends ConsumerState<SkillsListScreen> {
  List<SkillDef> _skills = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSkills();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reload skills every time the screen becomes visible (e.g. navigated back to)
    _loadSkills();
  }

  Future<void> _loadSkills() async {
    setState(() => _loading = true);
    try {
      _skills = await SkillDefDatabaseService.instance.getAllSkills();
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  (Set<String>, Set<String>) _partitionTools(List<String> toolNames) {
    final mcpTypes = <String>{};
    final externalUrls = <String>{};
    final configuredUrls = ExternalToolsSettingsService.instance.selectedServers
        .map((s) => s.serverUrl)
        .toSet();
    for (final name in toolNames) {
      if (name.startsWith('http://') ||
          name.startsWith('https://') ||
          configuredUrls.contains(name)) {
        externalUrls.add(name);
      } else {
        mcpTypes.add(name);
      }
    }
    return (mcpTypes, externalUrls);
  }

  Future<void> _addNewSkill() async {
    final result = await showDialog<SkillWizardResult>(
      context: context,
      builder: (_) => SkillWizardDialog(onSave: (_) {}),
    );
    if (result != null && mounted) {
      final now = DateTime.now();
      final allTools = [
        ...result.selectedMcpTypes,
        ...result.selectedExternalServerUrls,
      ];
      final skill = SkillDef(
        id: const Uuid().v4(),
        name: result.name,
        goal: result.goal,
        description: result.description,
        skillDef: result.skillContent,
        toolNames: allTools,
        createdAt: now,
        updatedAt: now,
      );
      await SkillDefDatabaseService.instance.saveSkill(skill);
      await _loadSkills();
    }
  }

  Future<void> _editSkill(SkillDef skill) async {
    final (mcpTypes, externalUrls) = _partitionTools(skill.toolNames);
    final result = await showDialog<SkillWizardResult>(
      context: context,
      builder: (_) => SkillWizardDialog(
        prefillName: skill.name,
        prefillGoal: skill.goal,
        prefillSkill: skill.skillDef,
        prefillMcpTypes: mcpTypes,
        prefillExternalUrls: externalUrls,
        onSave: (_) {},
      ),
    );
    if (result != null && mounted) {
      final allTools = [
        ...result.selectedMcpTypes,
        ...result.selectedExternalServerUrls,
      ];
      final updated = skill.copyWith(
        name: result.name,
        goal: result.goal,
        description: result.description,
        skillDef: result.skillContent,
        toolNames: allTools,
      );
      await SkillDefDatabaseService.instance.saveSkill(updated);
      await _loadSkills();
    }
  }

  Future<void> _showImportDialog() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Import Skill'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'file'),
            child: const Row(
              children: [
                Icon(Icons.file_upload_outlined),
                SizedBox(width: 12),
                Text('Import from File'),
              ],
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'web'),
            child: const Row(
              children: [
                Icon(Icons.language),
                SizedBox(width: 12),
                Text('Import from URL'),
              ],
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'gallery'),
            child: const Row(
              children: [
                Icon(Icons.auto_awesome, color: Colors.amber),
                SizedBox(width: 12),
                Text('Skill Gallery'),
              ],
            ),
          ),
        ],
      ),
    );
    if (choice == 'file') {
      await _importFromFile();
    } else if (choice == 'web') {
      await _importFromWeb();
    } else if (choice == 'gallery') {
      await _importFromGallery();
    }
  }

  Future<void> _importFromGallery() async {
    await showDialog(
      context: context,
      builder: (_) => SkillGalleryDialog(
        onImport: (selected) async {
          Navigator.of(context).pop();
          debugPrint(
            '[SkillGallery] Received ${selected.length} items to import.',
          );
          if (selected.isEmpty && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'No downloadable skill content or URL found for the selected item.',
                ),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
          for (final item in selected) {
            try {
              final skill = await SkillDefDatabaseService.instance
                  .importFromFile(
                    bytes: item['bytes'] as List<int>,
                    filename: item['filename'] as String,
                  );
              debugPrint(
                '[SkillGallery] Successfully imported skill: ${skill.name}',
              );
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Skill "${skill.name}" imported.'),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            } catch (e) {
              debugPrint('[SkillGallery] Exception importing skill: $e');
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Import failed: $e'),
                    backgroundColor: Colors.red,
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            }
          }
          await _loadSkills();
        },
      ),
    );
  }

  Future<void> _importFromFile() async {
    try {
      final picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip', 'md'],
        dialogTitle: 'Import Skill',
      );
      if (picked == null || picked.files.isEmpty) return;

      final file = picked.files.first;
      final List<int> bytes;
      if (file.bytes != null) {
        bytes = file.bytes!;
      } else if (file.path != null) {
        bytes = await File(file.path!).readAsBytes();
      } else {
        throw Exception('Could not read file.');
      }

      final skill = await SkillDefDatabaseService.instance.importFromFile(
        bytes: bytes,
        filename: file.name,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Skill "${skill.name}" imported.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        await _loadSkills();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Import failed: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _importFromWeb() async {
    final urlCtrl = TextEditingController();

    const baseUrl =
        'https://raw.githubusercontent.com/lschaffer/tealkit/main/example_skills';
    final galleryItems = <String, Map<String, String>>{
      'Docker Management': {
        'url': '$baseUrl/docker-skills.md',
        'file': 'example_skills/docker-skills.md',
        'desc':
            'Manage Docker containers, images, volumes, networks, and Compose stacks.',
      },
      'DLU Weather Data Analysis': {
        'url': '$baseUrl/dlu-weather-data.md',
        'file': 'example_skills/dlu-weather-data.md',
        'desc': 'Parse weather sensor archive files on DLU devices.',
      },
      'Concept Diagrams': {
        'url': '$baseUrl/concept-diagram-skills.md',
        'file': 'example_skills/concept-diagram-skills.md',
        'desc': 'Generate concept diagrams and flowcharts using Mermaid.',
      },
      'Statistical Charts': {
        'url': '$baseUrl/statistical-charts-skills.md',
        'file': 'example_skills/statistical-charts-skills.md',
        'desc': 'Create statistical charts and data visualizations.',
      },
      'Disk Usage (TCloud)': {
        'url': '$baseUrl/disk_usage_chain_tcloud_skills.md',
        'file': 'example_skills/disk_usage_chain_tcloud_skills.md',
        'desc': 'Analyze disk usage with chained cloud operations.',
      },
    };

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Import Skill'),
          content: SizedBox(
            width: 450,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: urlCtrl,
                  decoration: const InputDecoration(
                    hintText: 'https://raw.githubusercontent.com/.../skill.md',
                    labelText: 'Import from URL',
                    border: OutlineInputBorder(),
                    isDense: true,
                    prefixIcon: Icon(Icons.link),
                  ),
                  onChanged: (_) => setD(() {}),
                ),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.tonalIcon(
                    onPressed: urlCtrl.text.trim().isEmpty
                        ? null
                        : () =>
                              Navigator.pop(ctx, {'url': urlCtrl.text.trim()}),
                    icon: const Icon(Icons.download, size: 16),
                    label: const Text('Fetch URL'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      minimumSize: Size.zero,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Divider(),
                const SizedBox(height: 8),
                const Text(
                  'Gallery',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
                const SizedBox(height: 8),
                ...galleryItems.entries.map(
                  (e) => ListTile(
                    dense: true,
                    leading: const Icon(
                      Icons.auto_awesome,
                      color: Colors.amber,
                      size: 20,
                    ),
                    title: Text(
                      e.key,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      e.value['desc']!,
                      style: const TextStyle(fontSize: 11),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.download, size: 18),
                    onTap: () => Navigator.pop(ctx, {'file': e.value['file']!}),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );

    if (result == null || !mounted) return;

    if (result['url'] != null) {
      final url = result['url'] as String;
      try {
        final response = await http.get(Uri.parse(url));
        if (response.statusCode != 200) {
          throw Exception('HTTP ${response.statusCode}');
        }
        final bytes = response.bodyBytes;
        final filename = url.split('/').last;
        final skill = await SkillDefDatabaseService.instance.importFromFile(
          bytes: bytes,
          filename: filename,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Skill "${skill.name}" imported.'),
              behavior: SnackBarBehavior.floating,
            ),
          );
          await _loadSkills();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Web import failed: $e'),
              backgroundColor: Colors.red,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    } else if (result['file'] != null) {
      final filePath = result['file'] as String;
      try {
        final file = File(filePath);
        if (!await file.exists()) throw Exception('File not found: $filePath');
        final bytes = await file.readAsBytes();
        final filename = filePath.split('/').last;
        final skill = await SkillDefDatabaseService.instance.importFromFile(
          bytes: bytes,
          filename: filename,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Skill "${skill.name}" imported.'),
              behavior: SnackBarBehavior.floating,
            ),
          );
          await _loadSkills();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Import failed: $e'),
              backgroundColor: Colors.red,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    }
  }

  Future<void> _exportSkill(SkillDef skill) async {
    final safeName = skill.name.replaceAll(RegExp(r'[^a-zA-Z0-9_\- ]'), '_');
    final bytes = utf8.encode(skill.skillDef);
    final outputPath = await FilePicker.saveFile(
      dialogTitle: 'Export Skill',
      fileName: '$safeName.md',
      bytes: bytes,
      type: FileType.custom,
      allowedExtensions: ['md'],
    );
    if (outputPath == null) return;

    try {
      // On desktop (non-mobile), write the file ourselves.
      // On mobile, FilePicker already wrote the bytes.
      if (outputPath.isNotEmpty) {
        await File(outputPath).writeAsString(skill.skillDef);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Exported to $outputPath'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Export failed: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _deleteSkill(SkillDef skill) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Skill'),
        content: Text('Delete "${skill.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await SkillDefDatabaseService.instance.deleteSkill(skill.id);
      await _loadSkills();
    }
  }

  void _applySkill(SkillDef skill) {
    if (widget.selectionMode) {
      widget.onSkillSelected?.call(skill);
      Navigator.of(context).pop(skill);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isWide = MediaQuery.of(context).size.width >= 700;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.selectionMode ? 'Select Skill' : 'Skills'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loadSkills,
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add Skill',
            onPressed: _addNewSkill,
          ),
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: 'Import Skill',
            onPressed: _showImportDialog,
          ),
          if (widget.selectionMode)
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(context).pop(),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _skills.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.auto_awesome, size: 48, color: Colors.grey[400]),
                  const SizedBox(height: 16),
                  Text(
                    'No skills yet',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: Colors.grey[600],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Create, import, or generate AgentSkills.io skills.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.grey[500],
                    ),
                  ),
                ],
              ),
            )
          : isWide
          ? _buildTable(theme)
          : _buildMobileList(theme),
    );
  }

  Widget _buildTable(ThemeData theme) {
    return SingleChildScrollView(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: MediaQuery.of(context).size.width,
          ),
          child: DataTable(
            columnSpacing: 20,
            headingRowColor: WidgetStateProperty.all(
              theme.colorScheme.surfaceContainerHighest,
            ),
            columns: [
              const DataColumn(label: Text('')),
              const DataColumn(label: Text('Name')),
              const DataColumn(label: Text('Description')),
              const DataColumn(label: Text('Tools')),
              const DataColumn(label: Text('Updated')),
            ],
            rows: _skills.map((s) => _buildTableRow(s, theme)).toList(),
          ),
        ),
      ),
    );
  }

  DataRow _buildTableRow(SkillDef skill, ThemeData theme) {
    final date =
        '${skill.updatedAt.year}-${skill.updatedAt.month.toString().padLeft(2, '0')}-${skill.updatedAt.day.toString().padLeft(2, '0')}';
    final desc = _extractDescription(skill);

    return DataRow(
      cells: [
        DataCell(
          Row(mainAxisSize: MainAxisSize.min, children: _buildActions(skill)),
        ),
        DataCell(
          SizedBox(
            width: 180,
            child: Text(
              skill.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ),
        DataCell(
          SizedBox(
            width: 300,
            child: Text(
              desc.isNotEmpty ? desc : '\u2014',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ),
        ),
        DataCell(
          Text(
            skill.toolNames.isEmpty
                ? '\u2014'
                : '${skill.toolNames.length} tools',
          ),
        ),
        DataCell(Text(date, style: const TextStyle(fontSize: 12))),
      ],
    );
  }

  Widget _buildMobileList(ThemeData theme) {
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _skills.length,
      itemBuilder: (_, i) => _buildMobileCard(_skills[i], theme),
    );
  }

  Widget _buildMobileCard(SkillDef skill, ThemeData theme) {
    final date =
        '${skill.updatedAt.year}-${skill.updatedAt.month.toString().padLeft(2, '0')}-${skill.updatedAt.day.toString().padLeft(2, '0')}';
    final desc = _extractDescription(skill);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.auto_awesome, color: Colors.amber[600], size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    skill.name,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (skill.toolNames.isNotEmpty)
                  Chip(
                    label: Text(
                      '${skill.toolNames.length} tools',
                      style: const TextStyle(fontSize: 10),
                    ),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            if (desc.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                desc,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.grey[600],
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 2),
            Text(date, style: TextStyle(fontSize: 11, color: Colors.grey[500])),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: _buildActions(skill),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildActions(SkillDef skill) {
    return [
      if (widget.selectionMode)
        IconButton(
          icon: Icon(
            Icons.check_circle_outline,
            color: Colors.green[600],
            size: 20,
          ),
          tooltip: 'Apply skill',
          onPressed: () => _applySkill(skill),
        ),
      IconButton(
        icon: const Icon(Icons.edit_outlined, size: 20),
        tooltip: 'Edit',
        onPressed: () => _editSkill(skill),
      ),
      IconButton(
        icon: const Icon(Icons.ios_share, size: 20),
        tooltip: 'Export',
        onPressed: () => _exportSkill(skill),
      ),
      IconButton(
        icon: const Icon(Icons.delete_outline, size: 20),
        tooltip: 'Delete',
        onPressed: () => _deleteSkill(skill),
      ),
    ];
  }

  static String _extractDescription(SkillDef skill) {
    if (skill.description.isNotEmpty) return skill.description;
    final content = skill.skillDef;
    if (!content.startsWith('---')) return '';
    final lines = content.split('\n');
    for (int i = 1; i < lines.length; i++) {
      if (lines[i].trim() == '---') break;
      final line = lines[i].trim();
      if (line.startsWith('description:')) {
        return line.substring('description:'.length).trim().replaceAll('"', '');
      }
    }
    return '';
  }
}
