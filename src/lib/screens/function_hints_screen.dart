import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_theme.dart';
import '../mcp/internal_mcp_registry.dart';
import '../models/workflow_task.dart';
import '../models/function_hint.dart';
import '../providers/server_mode_provider.dart';
import '../services/external_tools_settings_service.dart';
import '../services/github_mcp_library_service.dart';
import '../services/server_api_client.dart';
import '../services/function_hint_database_service.dart';
import '../services/function_hint_generation_service.dart';
import '../widgets/function_hint_build_progress_dialog.dart';
import '../services/llm_settings_service.dart';

/// Screen for viewing and editing LLM-generated Tool Hints.
///
/// Skills are grouped by MCP server type. Each skill can be:
///   • Toggled enabled/disabled (affects injection into system prompts)
///   • Manually edited (full + SLM variants)
///   • Regenerated individually
class FunctionHintsScreen extends ConsumerStatefulWidget {
  const FunctionHintsScreen({super.key, this.autoRebuild = false, this.filter});

  /// When true the screen immediately triggers a full rebuild of all
  /// non-custom skills as if the user had tapped Rebuild → Add missing only.
  final bool autoRebuild;
  final String? filter;

  static Future<void> show(BuildContext context, {bool autoRebuild = false, String? filter}) {
    return Navigator.of(context).push(MaterialPageRoute(builder: (_) => FunctionHintsScreen(autoRebuild: autoRebuild, filter: filter)));
  }

  @override
  ConsumerState<FunctionHintsScreen> createState() => _SkillsScreenState();
}

class _SkillsScreenState extends ConsumerState<FunctionHintsScreen> {
  final FunctionHintDatabaseService _db = FunctionHintDatabaseService();

  List<FunctionHint> _skills = [];
  bool _loading = true;
  String _filter = '';
  bool _backgroundGenerating = false;
  final Set<String> _serverActiveMcpTypes = {};

  // Token-budget settings
  late final TextEditingController _llmTokenCtrl;
  late final TextEditingController _slmTokenCtrl;
  late final TextEditingController _searchCtrl;

  @override
  void initState() {
    super.initState();
    _llmTokenCtrl = TextEditingController();
    _slmTokenCtrl = TextEditingController();
    _searchCtrl = TextEditingController(text: widget.filter ?? '');
    _filter = widget.filter ?? '';
    _loadSettings();
    _loadSkills();
    if (widget.autoRebuild) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _triggerAutoRebuild());
    }
    // If skill generation is already running in the background (e.g. triggered
    // by the startup prompt), show an in-screen progress banner and
    // auto-reload the list when it finishes.
    if (FunctionHintGenerationService.instance.isBusy) {
      _backgroundGenerating = true;
      FunctionHintGenerationService.instance.completionNotifier.addListener(_onBackgroundGenerationDone);
    }
  }

  @override
  void dispose() {
    FunctionHintGenerationService.instance.completionNotifier.removeListener(_onBackgroundGenerationDone);
    _llmTokenCtrl.dispose();
    _slmTokenCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Called when the background generation pass (started before the screen was
  /// opened) finishes.  Removes the banner and reloads the skill list.
  void _onBackgroundGenerationDone() {
    if (!mounted) return;
    FunctionHintGenerationService.instance.completionNotifier.removeListener(_onBackgroundGenerationDone);
    setState(() => _backgroundGenerating = false);
    _loadSkills();
  }

  Future<void> _loadSettings() async {
    final svc = FunctionHintGenerationService();
    await svc.loadTokenSettings();
    if (mounted) {
      _llmTokenCtrl.text = svc.maxTokensLlm.toString();
      _slmTokenCtrl.text = svc.maxTokensSlm.toString();
    }
  }

  Future<void> _saveSettings() async {
    final llm = int.tryParse(_llmTokenCtrl.text) ?? FunctionHintGenerationService.defaultMaxTokensLlm;
    final slm = int.tryParse(_slmTokenCtrl.text) ?? FunctionHintGenerationService.defaultMaxTokensSlm;
    await FunctionHintGenerationService().saveTokenSettings(llm, slm);
    // Reflect clamped values back into controllers
    if (mounted) {
      _llmTokenCtrl.text = FunctionHintGenerationService().maxTokensLlm.toString();
      _slmTokenCtrl.text = FunctionHintGenerationService().maxTokensSlm.toString();
    }
  }

  /// Called from the startup "Generate Now" flow — add missing skills only.
  Future<void> _triggerAutoRebuild() async {
    if (!mounted) return;
    final client = ref.read(serverApiClientProvider);
    if (client != null) {
      await _runServerBuild(client, addMissingOnly: true);
    } else {
      // If another caller is already generating, wait for it to finish.
      while (FunctionHintGenerationService().isBusy) {
        await Future.delayed(const Duration(milliseconds: 300));
        if (!mounted) return;
      }
      await _runLocalBuild(() => FunctionHintGenerationService().ensureSkillsForBuiltInTools());
    }
  }

  Future<void> _loadSkills() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final client = ref.read(serverApiClientProvider);
      final List<FunctionHint> all;
      if (client != null) {
        final raw = await client.getAllSkills();
        all = raw.map((j) => FunctionHint.fromJson(j)).toList();

        final active = <String>{};
        try {
          active.addAll(InternalMcpRegistry().availableTypes);
          final githubServers = await client.listRegistryServers();
          for (final s in githubServers) {
            if (s['isActive'] == true) {
              active.add('gh_mcp_${s['id']}');
            }
          }
          final extToolsSettings = await client.getExternalToolsSettings();
          final selectedServers = extToolsSettings['selectedServers'] as List?;
          if (selectedServers != null) {
            for (final srv in selectedServers) {
              if (srv is Map) {
                final serverUrl = (srv['serverUrl'] ?? '').toString().trim().toLowerCase();
                if (serverUrl.isNotEmpty) {
                  final raw = serverUrl.replaceAll(RegExp(r'[^a-z0-9]+'), '_');
                  active.add('ext_${raw.length > 40 ? raw.substring(0, 40) : raw}');
                }
              }
            }
          }
        } catch (e) {
          debugPrint('Failed to load active MCP types from server: $e');
        }
        if (mounted) {
          setState(() {
            _serverActiveMcpTypes
              ..clear()
              ..addAll(active);
          });
        }
      } else {
        all = await _db.getAll();
      }
      if (mounted) setState(() => _skills = all);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggleEnabled(FunctionHint skill) async {
    final updated = skill.copyWith(isEnabled: !skill.isEnabled);
    final client = ref.read(serverApiClientProvider);
    if (client != null) {
      await client.saveSkill(updated.toJson());
    } else {
      await _db.save(updated);
    }
    if (mounted) {
      setState(() {
        final idx = _skills.indexWhere((s) => s.id == skill.id);
        if (idx != -1) _skills[idx] = updated;
      });
    }
  }

  Future<void> _regenerateOne(FunctionHint skill) async {
    final client = ref.read(serverApiClientProvider);
    if (client != null) {
      // Trigger server-side single-tool regeneration and reload.
      try {
        await client.buildServerSkills(addMissingOnly: false, toolName: skill.toolName, mcpType: skill.mcpType);
        await _loadSkills();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Server regeneration failed: $e'), duration: const Duration(seconds: 3)));
        }
      }
      return;
    }

    final llmSettings = LlmSettingsService.instance;
    if (!llmSettings.isLoaded) await llmSettings.load();
    if (!llmSettings.isConfigured) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('LLM 1 (Primary Model) must be configured/accepted in Settings to build skills.'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
      return;
    }

    final registry = InternalMcpRegistry();
    final server = registry.create(skill.mcpType);
    if (server == null) return;
    final tool = server.tools.where((t) => t.name == skill.toolName).firstOrNull;
    if (tool == null) return;

    setState(() {
      final idx = _skills.indexWhere((s) => s.id == skill.id);
      if (idx != -1) _skills[idx] = skill.copyWith();
    });

    final result = await FunctionHintGenerationService().regenerateSkillForTool(tool, skill.mcpType);
    if (result != null && mounted) {
      setState(() {
        final idx = _skills.indexWhere((s) => s.id == skill.id);
        if (idx != -1) _skills[idx] = result;
      });
    }
  }

  Future<void> _regenerateAll() async {
    if (FunctionHintGenerationService().isBusy) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Generation in progress — the list will reload automatically when done.'),
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }
    final client = ref.read(serverApiClientProvider);
    if (client == null) {
      final llmSettings = LlmSettingsService.instance;
      if (!llmSettings.isLoaded) await llmSettings.load();
      if (!llmSettings.isConfigured) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('LLM 1 (Primary Model) must be configured/accepted in Settings to build skills.'),
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
          );
        }
        return;
      }
    }
    if (client != null) {
      await _runServerBuild(client, addMissingOnly: false, clearBeforeBuild: true, clearCustom: false);
    } else {
      // Delete all non-custom skills so they get re-created.
      for (final s in _skills.where((s) => !s.isCustom)) {
        await _db.deleteByToolName(s.toolName);
      }
      await _runLocalBuild(() => FunctionHintGenerationService().ensureSkillsForBuiltInTools());
    }
  }

  /// Full rebuild: scan all registered MCP tools and either overwrite every
  /// skill or only add skills for tools that have none yet.
  Future<void> _rebuildAll() async {
    if (FunctionHintGenerationService().isBusy) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Generation in progress — the list will reload automatically when done.'),
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }
    final client = ref.read(serverApiClientProvider);
    if (client == null) {
      final llmSettings = LlmSettingsService.instance;
      if (!llmSettings.isLoaded) await llmSettings.load();
      if (!llmSettings.isConfigured) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('LLM 1 (Primary Model) must be configured/accepted in Settings to build skills.'),
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
          );
        }
        return;
      }
    }
    // Three-way dialog: overwrite-all / add-missing / cancel
    final choice = await showDialog<_RebuildChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rebuild function hints'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Choose how to rebuild hints for all registered MCP tools.'),
            const SizedBox(height: 8),
            _RebuildOptionTile(
              icon: Icons.delete_sweep_outlined,
              title: 'Overwrite all hints',
              subtitle: 'Delete every hint (including custom ones) and regenerate all from scratch.',
              onTap: () => Navigator.pop(ctx, _RebuildChoice.overwriteAll),
            ),
            _RebuildOptionTile(
              icon: Icons.add_circle_outline,
              title: 'Add missing hints only',
              subtitle: 'Keep existing hints. Generate only for tools that have no hint yet.',
              onTap: () => Navigator.pop(ctx, _RebuildChoice.addMissing),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (FunctionHintGenerationService().isBusy) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Skill generation is already running — please wait.'), duration: Duration(seconds: 2)));
      }
      return;
    }

    if (client != null) {
      if (choice == _RebuildChoice.overwriteAll) {
        await _runServerBuild(client, addMissingOnly: false, clearBeforeBuild: true, clearCustom: true);
      } else {
        await _runServerBuild(client, addMissingOnly: true, clearBeforeBuild: false, clearCustom: false);
      }
    } else {
      if (choice == _RebuildChoice.overwriteAll) {
        for (final s in _skills) {
          await _db.deleteByToolName(s.toolName);
        }
      }
      await _runLocalBuild(() => FunctionHintGenerationService().ensureSkillsForBuiltInTools());
    }
  }

  // ── Build helpers ────────────────────────────────────────────────────────────

  /// Show progress dialog and run a local [FunctionHintGenerationService] build.
  Future<void> _runLocalBuild(Future<void> Function() buildFn) async {
    if (!mounted) return;
    // Yield one frame so any previously dismissed route (popup menu, choice
    // dialog) is fully removed from the navigator before we push the progress
    // dialog.  Without this, showDialog can silently fail on iPad / desktop.
    await Future.delayed(Duration.zero);
    if (!mounted) return;
    unawaited(
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => FunctionHintBuildProgressDialog(
          progressNotifier: FunctionHintGenerationService().progressNotifier,
          onCancel: FunctionHintGenerationService().cancelGeneration,
        ),
      ),
    );
    try {
      await buildFn();
      await _loadSkills();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Skill generation failed: $e'), duration: const Duration(seconds: 4)));
      }
    } finally {
      if (mounted) Navigator.of(context).pop();
    }
  }

  /// Trigger a server-side build and show a polling progress dialog.
  Future<void> _runServerBuild(
    ServerApiClient client, {
    required bool addMissingOnly,
    bool clearBeforeBuild = false,
    bool clearCustom = false,
  }) async {
    if (!mounted) return;
    // Yield one frame so any previously dismissed route (popup menu, choice
    // dialog) is fully removed from the navigator before we push the progress
    // dialog.  Without this, showDialog can silently fail on iPad / desktop.
    await Future.delayed(Duration.zero);
    if (!mounted) return;
    // Local notifier updated by polling loop.
    final notifier = ValueNotifier<FunctionHintProgress>(const FunctionHintProgress());
    bool cancelled = false;

    unawaited(
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => FunctionHintBuildProgressDialog(progressNotifier: notifier, onCancel: () => cancelled = true),
      ),
    );

    try {
      await client.buildServerSkills(
        addMissingOnly: addMissingOnly,
        clearBeforeBuild: clearBeforeBuild,
        clearCustom: clearCustom,
      );
      // Poll until the server reports it has finished.
      while (mounted && !cancelled) {
        await Future.delayed(const Duration(milliseconds: 600));
        try {
          final status = await client.getServerSkillsBuildStatus(timeout: const Duration(seconds: 8));
          notifier.value = FunctionHintProgress(
            total: (status['total'] as num?)?.toInt() ?? 0,
            processed: (status['processed'] as num?)?.toInt() ?? 0,
            currentTool: status['current_tool'] as String? ?? '',
          );
          if (status['running'] != true) break;
        } catch (_) {
          // Tolerate transient network errors during polling.
        }
      }
      await _loadSkills();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Server skill build failed: $e'), duration: const Duration(seconds: 4)));
      }
    } finally {
      notifier.dispose();
      if (mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _openEditor(FunctionHint skill) async {
    final result = await showDialog<FunctionHint>(
      context: context,
      builder: (_) => _SkillEditDialog(skill: skill),
    );
    if (result != null) {
      final client = ref.read(serverApiClientProvider);
      if (client != null) {
        await client.saveSkill(result.toJson());
      } else {
        await _db.save(result);
      }
      if (mounted) {
        setState(() {
          final idx = _skills.indexWhere((s) => s.id == result.id);
          if (idx != -1) _skills[idx] = result;
        });
      }
    }
  }

  // ── Active-type helpers ──────────────────────────────────────────────────────

  /// Same normalization used in external_tools_settings_screen.dart.
  static String _extMcpTypeKey(McpToolConfig server) {
    final raw = server.serverUrl.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    return 'ext_${raw.length > 40 ? raw.substring(0, 40) : raw}';
  }

  /// Returns the set of currently active mcpType identifiers:
  ///   • built-in registry types (incl. any registered GitHub MCPs)
  ///   • active GitHub MCP library entries  (gh_mcp_<id>)
  ///   • selected external/remote servers   (ext_<url>)
  Set<String> _getActiveMcpTypes() {
    final client = ref.read(serverApiClientProvider);
    if (client != null) {
      return _serverActiveMcpTypes;
    }
    final active = <String>{};
    active.addAll(InternalMcpRegistry().availableTypes);
    for (final def in GithubMcpLibraryService.instance.activeServers) {
      active.add('gh_mcp_${def.id}');
    }
    for (final srv in ExternalToolsSettingsService.instance.selectedServers) {
      active.add(_extMcpTypeKey(srv));
    }
    return active;
  }

  // ── Delete / prune ───────────────────────────────────────────────────────────

  Future<void> _deleteSkill(FunctionHint skill) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove skill'),
        content: Text('Delete the skill for "${skill.toolName}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Theme.of(ctx).colorScheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final client = ref.read(serverApiClientProvider);
    if (client != null) {
      await client.deleteSkill(skill.id);
    } else {
      await _db.delete(skill.id);
    }
    setState(() => _skills.removeWhere((s) => s.id == skill.id));

    // After removing, silently clean up any remaining skills
    // for MCP servers that are no longer registered.
    await _pruneOrphanedSkills(silent: true);
  }

  /// Finds and removes skills whose MCP server type is no longer registered.
  ///
  /// [silent] = true : auto-remove without a confirmation dialog (used after a
  ///                    single-skill delete to catch other orphans in one go).
  /// [silent] = false : show a preview dialog before removing (menu-driven).
  Future<void> _pruneOrphanedSkills({bool silent = false}) async {
    final activeTypes = _getActiveMcpTypes();
    final orphanedTypes = _skills.map((s) => s.mcpType).toSet().difference(activeTypes);

    if (orphanedTypes.isEmpty) {
      if (!silent && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('No orphaned skills found.'), duration: Duration(seconds: 2)));
      }
      return;
    }

    if (!silent) {
      final typeList = orphanedTypes.map((t) => '  • $t').join('\n');
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Remove orphaned hints'),
          content: Text('Hints for ${orphanedTypes.length} deregistered server(s) will be deleted:\n\n$typeList'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    final client = ref.read(serverApiClientProvider);
    final toRemove = _skills.where((s) => orphanedTypes.contains(s.mcpType)).toList();
    for (final s in toRemove) {
      if (client != null) {
        await client.deleteSkill(s.id);
      } else {
        await _db.delete(s.id);
      }
    }
    setState(() => _skills.removeWhere((s) => orphanedTypes.contains(s.mcpType)));

    if (!silent && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Removed ${toRemove.length} skills for ${orphanedTypes.length} deregistered server(s).'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Group skills by mcpType
    final filtered = _filter.isEmpty
        ? _skills
        : _skills
              .where(
                (s) => s.toolName.toLowerCase().contains(_filter.toLowerCase()) || s.mcpType.toLowerCase().contains(_filter.toLowerCase()),
              )
              .toList();

    final grouped = <String, List<FunctionHint>>{};
    for (final s in filtered) {
      grouped.putIfAbsent(s.mcpType, () => []).add(s);
    }
    final sortedTypes = grouped.keys.toList()..sort();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Function Hints'),
        backgroundColor: AppTheme.primaryBlue,
        foregroundColor: Colors.white,
        actions: [
          PopupMenuButton<_SkillAction>(
            icon: const Icon(Icons.more_vert),
            tooltip: 'Options',
            onSelected: (action) {
              switch (action) {
                case _SkillAction.regenerate:
                  _regenerateAll();
                case _SkillAction.rebuild:
                  _rebuildAll();
                case _SkillAction.pruneOrphaned:
                  _pruneOrphanedSkills();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: _SkillAction.regenerate,
                child: ListTile(
                  leading: Icon(Icons.refresh),
                  title: Text('Regenerate non-custom'),
                  subtitle: Text('Re-generate auto hints, keep custom ones'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: _SkillAction.rebuild,
                child: ListTile(
                  leading: Icon(Icons.build_circle_outlined),
                  title: Text('Rebuild (scan all tools)'),
                  subtitle: Text('Overwrite all  •  or  •  add missing only'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: _SkillAction.pruneOrphaned,
                child: ListTile(
                  leading: Icon(Icons.cleaning_services_outlined),
                  title: Text('Remove orphaned function hints'),
                  subtitle: Text('Delete hints for deregistered MCP servers'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // ── Background-generation progress banner ───────────────────────────
                if (_backgroundGenerating)
                  ValueListenableBuilder<FunctionHintProgress>(
                    valueListenable: FunctionHintGenerationService.instance.progressNotifier,
                    builder: (context, progress, _) {
                      final fraction = progress.total > 0 ? progress.processed / progress.total : null;
                      return _GenerationBanner(progress: progress, fraction: fraction);
                    },
                  ),
                // ── Token-budget settings ───────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: _TokenField(
                          label: 'Max tokens – LLM (full skill)',
                          controller: _llmTokenCtrl,
                          hint: '${FunctionHintGenerationService.defaultMaxTokensLlm}',
                          onEditingComplete: _saveSettings,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _TokenField(
                          label: 'Max tokens – SLM (compact)',
                          controller: _slmTokenCtrl,
                          hint: '${FunctionHintGenerationService.defaultMaxTokensSlm}',
                          onEditingComplete: _saveSettings,
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  child: TextField(
                    controller: _searchCtrl,
                    decoration: InputDecoration(
                      hintText: 'Filter by tool or server…',
                      prefixIcon: const Icon(Icons.search),
                      border: const OutlineInputBorder(),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    onChanged: (v) => setState(() => _filter = v),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: Text(
                    '${_skills.length} function hints — enabled hints are injected into system prompts for tasks that use those tools.',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                  ),
                ),
                Expanded(
                  child: filtered.isEmpty
                      ? Center(
                          child: Text(
                            'No function hints yet.\nStart a chat to trigger auto-generation.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium,
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.only(bottom: 24),
                          itemCount: sortedTypes.length,
                          itemBuilder: (ctx, i) {
                            final type = sortedTypes[i];
                            final items = grouped[type]!;
                            return _GroupSection(
                              type: type,
                              skills: items,
                              onToggle: _toggleEnabled,
                              onEdit: _openEditor,
                              onRegenerate: _regenerateOne,
                              onDelete: _deleteSkill,
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Background-generation progress banner

class _GenerationBanner extends StatelessWidget {
  final FunctionHintProgress progress;
  final double? fraction; // null → indeterminate

  const _GenerationBanner({required this.progress, this.fraction});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final label = progress.total > 0 ? 'Generating skills… ${progress.processed}/${progress.total}' : 'Generating skills…';
    final sub = progress.currentTool.isNotEmpty ? progress.currentTool : null;

    return Material(
      color: cs.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: cs.onPrimaryContainer)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.bodySmall?.copyWith(color: cs.onPrimaryContainer, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            LinearProgressIndicator(value: fraction, backgroundColor: cs.primary.withValues(alpha: 0.2), color: cs.primary),
            if (sub != null) ...[
              const SizedBox(height: 2),
              Text(
                sub,
                style: theme.textTheme.labelSmall?.copyWith(color: cs.onPrimaryContainer.withValues(alpha: 0.75)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────

class _GroupSection extends StatelessWidget {
  final String type;
  final List<FunctionHint> skills;
  final Future<void> Function(FunctionHint) onToggle;
  final Future<void> Function(FunctionHint) onEdit;
  final Future<void> Function(FunctionHint) onRegenerate;
  final Future<void> Function(FunctionHint) onDelete;

  const _GroupSection({
    required this.type,
    required this.skills,
    required this.onToggle,
    required this.onEdit,
    required this.onRegenerate,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            type.toUpperCase().replaceAll('_', ' '),
            style: theme.textTheme.labelSmall?.copyWith(color: AppTheme.primaryBlue, fontWeight: FontWeight.bold, letterSpacing: 1.2),
          ),
        ),
        ...skills.map(
          (s) => _SkillTile(
            skill: s,
            onToggle: () => onToggle(s),
            onEdit: () => onEdit(s),
            onRegenerate: () => onRegenerate(s),
            onDelete: () => onDelete(s),
          ),
        ),
      ],
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────

enum _SkillAction { regenerate, rebuild, pruneOrphaned }

enum _RebuildChoice { overwriteAll, addMissing }

// ──────────────────────────────────────────────────────────────────────────────

/// Tappable card-style option inside the rebuild dialog.
class _RebuildOptionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _RebuildOptionTile({required this.icon, required this.title, required this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border.all(color: theme.dividerColor),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(icon, size: 22, color: AppTheme.primaryBlue),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────

class _SkillTile extends StatelessWidget {
  final FunctionHint skill;
  final VoidCallback onToggle;
  final VoidCallback onEdit;
  final VoidCallback onRegenerate;
  final VoidCallback onDelete;

  const _SkillTile({required this.skill, required this.onToggle, required this.onEdit, required this.onRegenerate, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                skill.isEnabled ? Icons.lightbulb : Icons.lightbulb_outline,
                color: skill.isEnabled ? Colors.amber[600] : theme.hintColor,
                size: 22,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  skill.toolName,
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500, color: skill.isEnabled ? null : theme.hintColor),
                ),
              ),
              Switch(value: skill.isEnabled, onChanged: (_) => onToggle(), materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 30),
            child: Text(
              skill.skillTextSlm,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (skill.isCustom)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Tooltip(
                    message: 'Custom (manually edited)',
                    child: Icon(Icons.edit_note, size: 16, color: theme.hintColor),
                  ),
                ),
              IconButton(icon: const Icon(Icons.edit_outlined, size: 18), tooltip: 'Edit skill', onPressed: onEdit),
              IconButton(icon: const Icon(Icons.refresh, size: 18), tooltip: 'Regenerate', onPressed: onRegenerate),
              IconButton(
                icon: Icon(Icons.delete_outline, size: 18, color: Theme.of(context).colorScheme.error),
                tooltip: 'Remove skill',
                onPressed: onDelete,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────

/// Compact numeric text field for token-budget settings.
class _TokenField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String hint;
  final VoidCallback onEditingComplete;

  const _TokenField({required this.label, required this.controller, required this.hint, required this.onEditingComplete});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      textInputAction: TextInputAction.done,
      onEditingComplete: onEditingComplete,
      onTapOutside: (_) => onEditingComplete(),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────

class _SkillEditDialog extends StatefulWidget {
  final FunctionHint skill;
  const _SkillEditDialog({required this.skill});

  @override
  State<_SkillEditDialog> createState() => _SkillEditDialogState();
}

class _SkillEditDialogState extends State<_SkillEditDialog> {
  late final TextEditingController _fullCtrl;
  late final TextEditingController _slmCtrl;

  @override
  void initState() {
    super.initState();
    _fullCtrl = TextEditingController(text: widget.skill.skillText);
    _slmCtrl = TextEditingController(text: widget.skill.skillTextSlm);
  }

  @override
  void dispose() {
    _fullCtrl.dispose();
    _slmCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 32),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Title bar ──
            Container(
              decoration: BoxDecoration(
                color: AppTheme.primaryBlue,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
              ),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  Expanded(
                    child: Text(widget.skill.toolName, style: theme.textTheme.titleMedium?.copyWith(color: Colors.white)),
                  ),
                ],
              ),
            ),
            // ── Body ──
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Full skill (for large models ≥ 7B)', style: theme.textTheme.labelMedium),
                    const SizedBox(height: 6),
                    Expanded(
                      child: TextField(
                        controller: _fullCtrl,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        decoration: const InputDecoration(border: OutlineInputBorder(), contentPadding: EdgeInsets.all(10)),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text('Compact skill (for SLM / embedded < 7B)', style: theme.textTheme.labelMedium),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _slmCtrl,
                      maxLines: 4,
                      decoration: const InputDecoration(border: OutlineInputBorder(), contentPadding: EdgeInsets.all(10)),
                    ),
                  ],
                ),
              ),
            ),
            // ── Actions ──
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () {
                      final updated = widget.skill.copyWith(
                        skillText: _fullCtrl.text.trim(),
                        skillTextSlm: _slmCtrl.text.trim(),
                        isCustom: true,
                      );
                      Navigator.of(context).pop(updated);
                    },
                    child: const Text('Save'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
