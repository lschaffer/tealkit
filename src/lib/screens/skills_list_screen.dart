import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
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
  final bool isCodingMode;
  final void Function(SkillDef skill)? onSkillSelected;

  const SkillsListScreen({
    super.key,
    this.selectionMode = false,
    this.isCodingMode = false,
    this.onSkillSelected,
  });

  static Future<SkillDef?> showPicker(
    BuildContext context, {
    bool isCodingMode = false,
  }) {
    return showDialog<SkillDef>(
      context: context,
      builder: (_) => Dialog.fullscreen(
        child: SkillsListScreen(
          selectionMode: true,
          isCodingMode: isCodingMode,
        ),
      ),
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


  bool get _isCodingModeActive => widget.isCodingMode;

  Future<void> _loadSkills() async {
    setState(() => _loading = true);
    try {
      _skills = await SkillDefDatabaseService.instance.getAllSkills();
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _generateSampleCodingSkills() async {
    setState(() => _loading = true);
    try {
      final existing = await SkillDefDatabaseService.instance.getAllSkills();
      final existingKeys = <String>{};
      for (final s in existing) {
        existingKeys.add(s.name.trim().toLowerCase());
        final match = RegExp(r'^name:\s*(.+)$', multiLine: true).firstMatch(s.skillDef);
        if (match != null) {
          existingKeys.add(match.group(1)!.trim().toLowerCase());
        }
      }

      final samples = _buildSampleCodingSkills();
      final toAdd = samples.where((sample) {
        final name = sample['name'] as String;
        final aliases = sample['aliases'] as List<String>;
        if (existingKeys.contains(name.trim().toLowerCase())) return false;
        for (final alias in aliases) {
          if (existingKeys.contains(alias.trim().toLowerCase())) return false;
        }
        return true;
      }).toList();

      if (toAdd.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Sample coding skills already exist (skipped duplicates).'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      } else {
        final now = DateTime.now();
        final addedNames = <String>[];
        for (final item in toAdd) {
          final skill = SkillDef(
            id: const Uuid().v4(),
            name: item['name'] as String,
            goal: item['goal'] as String,
            description: item['description'] as String,
            skillDef: item['skillDef'] as String,
            toolNames: List<String>.from(item['toolNames'] as List),
            createdAt: now,
            updatedAt: now,
          );
          await SkillDefDatabaseService.instance.saveSkill(skill);
          addedNames.add(skill.name);
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Added ${addedNames.length} sample coding skill(s): ${addedNames.join(", ")}'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
      await _loadSkills();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error generating skills: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> _buildSampleCodingSkills() {
    return [
      {
        'name': 'Generic Coding Agent',
        'aliases': ['coding-agent-skill', 'coding-agent', 'generic coding agent'],
        'goal': 'Autonomous coding agent for project exploration, architectural planning (tasks.md), surgical edits, and terminal verification.',
        'description': 'Autonomous coding agent for codebase exploration, task-based planning (tasks.md), surgical edits with fs_replace_text, and terminal verification.',
        'toolNames': ['fs_find', 'fs_read_file', 'fs_write_file', 'fs_replace_text', 'terminal_exec', 'web_search', 'fetch'],
        'skillDef': '''---
name: coding-agent-skill
description: Autonomous coding agent for project exploration, architectural planning (tasks.md), and verified implementation.
version: 1.0.0
author: TealKit Engineering
system_prompt: |
  You are an expert autonomous software engineer and architectural planner.

  Operational Workflow:
  1. EXPLORE FIRST: Discover project structure, build definitions, and source files using `fs_find` and `fs_read_file`.
  2. RESEARCH & WEB SEARCH: Use the built-in `web_search` and `fetch` tools to look up current documentation, package updates, migration guides, and solve unknown error messages.
  3. PLAN & TRACK: Create or update `tasks.md` in the workspace root with a Markdown checkbox checklist (`- [ ] item`).
  4. SURGICAL EDITS: When modifying existing files, use `fs_replace_text` with exact, unique context blocks. Use `fs_write_file` to create new files.
  5. VERIFY WITH TERMINAL: After editing code, execute build/test commands (`terminal_exec`) to ensure zero broken builds or regressions.
  6. UPDATE PROGRESS: Check off completed items in `tasks.md` (`- [x]`) as each task is verified.
  7. HOST OS ENVIRONMENT COMPATIBILITY:
     - Always respect the host operating system. On Windows, never use Linux/POSIX commands (`head`, `tail`, `cat`, `grep`, `ls`, `export`) or bash pipes. Use native flags (e.g., `git log -n 20`) or pure-Dart file tools (`fs_read_file`, `fs_find`).
prompts:
  - text: |
      Inspect the project repository in the current workspace.
      1. Discover project files, build manifests (e.g. *.csproj, pubspec.yaml, package.json), and documentation.
      2. Summarize the project stack, architecture, and entry points.
      3. If needed, use `web_search` or `fetch` to verify latest stable package versions or framework documentation.
    enabledToolNames:
      - fs_find
      - fs_read_file
      - web_search
      - fetch

  - text: |
      Based on the project structure:
      1. Create a `tasks.md` file in the workspace root outlining immediate improvements, upgrades, or requested features as pending checkbox tasks (`- [ ]`).
      2. If an implementation plan is needed, create `docs/implementation_plan.md` explaining the architectural rationale.
      3. Use `web_search` or `fetch` if any best practices, breaking changes, or library APIs need verification.

      Previous Findings:
      \${tool_result}
    enabledToolNames:
      - fs_write_file
      - fs_read_file
      - web_search
      - fetch

  - text: |
      Review `tasks.md` and execute the first pending task using `fs_replace_text` or `fs_write_file`.
      Verify the change with `terminal_exec` (e.g. running build/test), using `web_search` or `fetch` if unexpected build errors or compiler issues arise, and update `tasks.md` to check off the item (`- [x]`).
    enabledToolNames:
      - fs_read_file
      - fs_replace_text
      - fs_write_file
      - terminal_exec
      - web_search
      - fetch
---
# Generic Coding Agent Skill

Autonomous software engineering, architectural planning, and verified implementation.
''',
      },
      {
        'name': 'Dart & Flutter Engineer',
        'aliases': ['dart-flutter-engineer-skill', 'dart-engineer-skill', 'dart & flutter engineer', 'flutter engineer'],
        'goal': 'Specialized Dart & Flutter engineer for state management, widget architecture, dependencies, analysis, and test verification.',
        'description': 'Specialized Dart & Flutter engineer for state management (Riverpod/Bloc), widget architecture, dependencies, analysis (dart analyze), and testing (flutter test).',
        'toolNames': ['fs_find', 'fs_read_file', 'fs_write_file', 'fs_replace_text', 'terminal_exec', 'web_search', 'fetch'],
        'skillDef': '''---
name: dart-flutter-engineer-skill
description: Specialized Dart and Flutter engineering skill for widget architecture, state management (Riverpod/Bloc), package maintenance, and automated analysis and testing.
version: 1.0.0
author: TealKit Engineering
system_prompt: |
  You are an expert Dart and Flutter software engineer and mobile/desktop application architect.
  You understand modern Dart 3+ idioms (pattern matching, records, sealed classes), Flutter widgets, state management (Riverpod, Bloc, Provider), routing, and automated testing.

  Engineering Workflow:
  1. EXPLORE FLUTTER REPOSITORY:
     - Locate `pubspec.yaml`, `analysis_options.yaml`, `lib/main.dart`, and target platforms.
     - Inspect existing state management, architecture layers, and asset declarations.
  2. RESEARCH & COMPATIBILITY:
     - Use `web_search` and `fetch` to verify latest compatible package releases on pub.dev, migration guidelines, and breaking Flutter deprecations.
  3. ARCHITECTURE & TASK PLANNING:
     - Maintain `tasks.md` in the project root with clear checkbox items (`- [ ]`).
     - Decouple business logic and state notifiers from UI presentation widgets.
  4. SURGICAL CODING:
     - Use `fs_replace_text` for targeted updates to widgets, providers, and models.
     - Use `fs_write_file` for new widget components and unit/widget test files.
  5. VERIFY WITH FLUTTER & DART CLI:
     - Run `flutter pub get` via `terminal_exec` after modifying dependencies.
     - Run `dart analyze` via `terminal_exec` to ensure zero static analysis warnings or errors.
     - Run `flutter test` via `terminal_exec` to guarantee all test suites pass.
  6. HOST OS ENVIRONMENT COMPATIBILITY:
     - On Windows, never use Linux/POSIX commands (`grep`, `cat`, `ls`, `export`) or bash pipes. Use native flags or Dart tools (`fs_read_file`, `fs_find`).
prompts:
  - text: |
      Inspect the Flutter/Dart workspace:
      1. Use `fs_find` to discover `pubspec.yaml`, `analysis_options.yaml`, and `lib/**/*.dart`.
      2. Read `pubspec.yaml` using `fs_read_file` to determine Flutter SDK constraints, dependencies, and state management in use.
      3. Run `flutter --version` and `dart analyze` via `terminal_exec` to inspect the current environment and baseline health.
    enabledToolNames:
      - fs_find
      - fs_read_file
      - terminal_exec
      - web_search
      - fetch

  - text: |
      Based on the Flutter project architecture:
      1. Create or update `tasks.md` in the workspace root with pending implementation or refactoring steps (`- [ ]`).
      2. If third-party packages need updating, use `web_search` or `fetch` to confirm pub.dev compatibility.
      
      Previous Findings:
      \${tool_result}
    enabledToolNames:
      - fs_write_file
      - fs_read_file
      - web_search
      - fetch

  - text: |
      Execute the pending Flutter/Dart task:
      1. Apply code changes using `fs_replace_text` or `fs_write_file`.
      2. Run `dart analyze` and `flutter test` via `terminal_exec` to verify clean compilation and passing tests.
      3. Mark completed items in `tasks.md` (`- [x]`).
    enabledToolNames:
      - fs_read_file
      - fs_replace_text
      - fs_write_file
      - terminal_exec
      - web_search
      - fetch
---
# Dart & Flutter Engineer Skill

Specialized Dart and Flutter engineering skill for widget architecture, state management, and automated test verification.
''',
      },
      {
        'name': '.NET Engineer',
        'aliases': ['dotnet-engineer-skill', 'dotnet-engineer', '.net engineer', 'dotnet engineer'],
        'goal': 'Comprehensive .NET skill for WinForms modernization, backend services refactoring, unit & integration test generation, and automated project upgrades.',
        'description': 'Comprehensive .NET solutions architect for modern .NET (8/9/10), WinForms modernization, backend services refactoring, unit & integration test generation, and automated project upgrades.',
        'toolNames': ['fs_find', 'fs_read_file', 'fs_write_file', 'fs_replace_text', 'terminal_exec', 'web_search', 'fetch'],
        'skillDef': '''---
name: dotnet-engineer-skill
description: Comprehensive .NET skill for WinForms modernization, backend services refactoring, unit & integration test generation, and automated project upgrades.
version: 1.0.0
author: TealKit Engineering
system_prompt: |
  You are an expert .NET solutions architect, desktop application engineer, and test automation specialist.
  You understand modern .NET (including .NET 8 / 9 / 10), C#, legacy WinForms (.NET Framework and modern Windows Desktop SDK), ASP.NET Core, Background/Worker services, and testing frameworks (xUnit, NUnit, MSTest, Moq, NSubstitute, FluentAssertions).

  Engineering Workflow:
  1. DISCOVER & CLASSIFY: Inspect solutions (.sln), project files (.csproj), target frameworks, dependencies, and directory layouts.
  2. RESEARCH & COMPATIBILITY: Use the built-in `web_search` and `fetch` tools to look up breaking changes, NuGet package compatibility, and framework migration guides.
  3. PLAN & TRACK: Create or update `tasks.md` in the workspace root with a clear phase-by-phase checkbox checklist (`- [ ]`).
  4. WINFORMS MODERNIZATION:
     - Upgrade `<TargetFramework>` to modern .NET SDK (e.g. `net8.0-windows` or `net9.0-windows`).
     - Enable High-DPI support, nullable reference types, and C# latest features.
     - Decouple business/data logic from form event handlers into testable services (MVP / MVVM pattern).
  5. SERVICE TESTS GENERATION:
     - For services, controllers, handlers, and repositories, locate or create dedicated test projects.
     - Generate robust unit and integration tests covering positive paths, edge cases, error handling, cancellation tokens (`CancellationToken`), and mocked dependencies.
  6. VERIFY & VALIDATE:
     - Run `dotnet restore`, `dotnet build`, and `dotnet test` via `terminal_exec`.
     - Use `web_search` or `fetch` to troubleshoot obsolete API warnings or obscure build failures.
     - Ensure zero warnings/errors, and check off completed tasks (`- [x]`) in `tasks.md`.
  7. HOST OS ENVIRONMENT COMPATIBILITY:
     - Always respect the host operating system. On Windows, never use Linux/POSIX commands (`head`, `tail`, `cat`, `grep`, `ls`, `export`) or bash pipes. Use native flags or pure-Dart file tools (`fs_read_file`, `fs_find`).
prompts:
  - text: |
      Inspect the .NET workspace and classify all projects:
      1. Use `fs_find` to discover all `*.sln`, `*.csproj`, `global.json`, `Directory.Build.props`, and configuration files.
      2. Run `dotnet --list-sdks` and `dotnet --version` via `terminal_exec` to check installed SDKs and runtime environments.
      3. Read `.csproj` files with `fs_read_file` to determine target frameworks, project types, and test projects.
      4. Use `web_search` or `fetch` if any legacy package or third-party dependency requires modern alternatives.
    enabledToolNames:
      - fs_find
      - fs_read_file
      - terminal_exec
      - web_search
      - fetch

  - text: |
      Based on the discovered solution structure, create or update `tasks.md` in the workspace root:
      1. Upgrade Plan (TargetFramework bump, NuGet package updates, WinForms modern bootstrapping).
      2. Service Testing Plan (identify services lacking tests, setup test project, implement tests).
      3. Compilation & Verification (`dotnet build`, `dotnet test`).

      Previous Findings:
      \${tool_result}
    enabledToolNames:
      - fs_write_file
      - fs_read_file
      - web_search
      - fetch

  - text: |
      Execute the WinForms upgrade and service tests generation:
      1. Apply project file updates using `fs_replace_text`.
      2. For each identified business service, generate or update test files using `fs_write_file`.
      3. Run `dotnet build` and `dotnet test` via `terminal_exec`.
      4. If any compilation or test failure occurs, inspect errors, use `web_search` or `fetch`, apply surgical fixes with `fs_replace_text`, and re-test.
      5. Mark completed items in `tasks.md` as done (`- [x]`).
    enabledToolNames:
      - fs_read_file
      - fs_write_file
      - fs_replace_text
      - terminal_exec
      - web_search
      - fetch
---
# .NET Engineer Skill

Comprehensive .NET skill for WinForms modernization, backend services refactoring, unit & integration test generation, and automated project upgrades.
''',
      },
    ];
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
      if (picked.isEmpty) return;

      final file = picked.first;
      final List<int> bytes;
      try {
        bytes = await file.readAsBytes();
      } catch (_) {
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

    final isMobile = MediaQuery.of(context).size.width < 600;
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      useSafeArea: !isMobile,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          final content = Column(
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
          );

          if (isMobile) {
            return Dialog.fullscreen(
              child: Scaffold(
                appBar: AppBar(
                  leading: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                  title: const Text('Import Skill'),
                ),
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: content,
                ),
              ),
            );
          }

          return AlertDialog(
            title: const Text('Import Skill'),
            content: SizedBox(
              width: 450,
              child: content,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
            ],
          );
        },
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
    final bytes = Uint8List.fromList(utf8.encode(skill.skillDef));
    final uri = await FilePicker.saveFile(
      dialogTitle: 'Export Skill',
      fileName: '$safeName.md',
      bytes: bytes,
    );
    if (uri == null) return;
    final outputPath = uri.toFilePath();

    try {
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
          if (_isCodingModeActive)
            IconButton(
              icon: const Icon(Icons.code, color: Color(0xFFEA580C)),
              tooltip: 'Generate Sample Coding Skills',
              onPressed: _generateSampleCodingSkills,
            ),
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
                  if (_isCodingModeActive) ...[
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFEA580C),
                        foregroundColor: Colors.white,
                      ),
                      onPressed: _generateSampleCodingSkills,
                      icon: const Icon(Icons.code, size: 18),
                      label: const Text('Generate Sample Coding Skills'),
                    ),
                  ],
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
