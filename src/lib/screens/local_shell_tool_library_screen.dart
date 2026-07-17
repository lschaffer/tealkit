// ignore_for_file: use_build_context_synchronously

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/app_localizations.dart';
import 'package:uuid/uuid.dart';

import '../config/app_theme.dart';
import '../models/mcp_models.dart';
import '../providers/llm_settings_provider.dart';
import '../services/app_logger.dart';
import '../services/llm_service.dart';
import '../services/local_shell_script_service.dart';
import '../services/task_runner_service.dart';

// ═══════════════════════════════════════════════════════════════
// Local Shell Script Library Screen — Linux / macOS only
// ═══════════════════════════════════════════════════════════════

class LocalShellToolLibraryScreen extends ConsumerStatefulWidget {
  const LocalShellToolLibraryScreen({super.key});

  /// Push the screen. Guard with Platform.isLinux || Platform.isMacOS at call site.
  static Future<bool?> show(BuildContext context) {
    return Navigator.of(context).push<bool>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const LocalShellToolLibraryScreen()));
  }

  @override
  ConsumerState<LocalShellToolLibraryScreen> createState() => _LocalShellToolLibraryScreenState();
}

class _LocalShellToolLibraryScreenState extends ConsumerState<LocalShellToolLibraryScreen> {
  bool _loading = true;
  List<LocalShellScript> _scripts = [];
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await LocalShellScriptService.instance.load();
    if (!mounted) return;
    final list = List<LocalShellScript>.from(LocalShellScriptService.instance.scripts);
    list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    setState(() {
      _scripts = list;
      _loading = false;
    });
  }

  void _refresh() {
    final list = List<LocalShellScript>.from(LocalShellScriptService.instance.scripts);
    list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    setState(() {
      _scripts = list;
      _changed = true;
    });
  }

  Future<void> _openEditor({LocalShellScript? existing}) async {
    final result = await _LocalShellEditorDialog.show(context, ref: ref, existing: existing);
    if (result == true) _refresh();
  }

  Future<void> _deleteScript(LocalShellScript script) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Local Shell Script'),
        content: Text('Delete "${script.name}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(L.of(context).cancel)),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(L.of(context).delete, style: const TextStyle(color: AppTheme.error)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await LocalShellScriptService.instance.deleteScript(script.id);
    _refresh();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Deleted: ${script.name}'), behavior: SnackBarBehavior.floating));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Local Shell Script Library'),
        leading: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop(_changed)),
        actions: [IconButton(icon: const Icon(Icons.add), tooltip: 'New local shell script', onPressed: () => _openEditor())],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _scripts.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.terminal, size: 64, color: Colors.grey[400]),
                  const SizedBox(height: 16),
                  Text('No local shell scripts yet', style: theme.textTheme.titleMedium?.copyWith(color: Colors.grey[500])),
                  const SizedBox(height: 8),
                  Text(
                    'Create local bash/sh scripts to run on this machine.',
                    style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey[400]),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: () => _openEditor(),
                    icon: const Icon(Icons.add),
                    label: const Text('Create Local Shell Script'),
                  ),
                ],
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _scripts.length,
              separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
              itemBuilder: (ctx, i) {
                final s = _scripts[i];
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Colors.green.withValues(alpha: 0.12),
                    child: const Icon(Icons.terminal, color: Colors.green, size: 20),
                  ),
                  title: Text(s.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: s.description.isNotEmpty
                      ? Text(s.description, maxLines: 1, overflow: TextOverflow.ellipsis)
                      : Text('${'\n'.allMatches(s.content).length + 1} lines', style: TextStyle(color: Colors.grey[500], fontSize: 12)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        tooltip: 'Edit',
                        onPressed: () => _openEditor(existing: s),
                      ),
                      IconButton(
                        icon: Icon(Icons.delete_outline, color: AppTheme.error),
                        tooltip: 'Delete',
                        onPressed: () => _deleteScript(s),
                      ),
                    ],
                  ),
                  onTap: () => _openEditor(existing: s),
                );
              },
            ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Local Shell Editor Dialog
// ═══════════════════════════════════════════════════════════════

class _LocalShellEditorDialog extends ConsumerStatefulWidget {
  const _LocalShellEditorDialog({this.existing});

  final LocalShellScript? existing;

  static Future<bool?> show(BuildContext context, {required WidgetRef ref, LocalShellScript? existing}) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _LocalShellEditorDialog(existing: existing),
    );
  }

  @override
  ConsumerState<_LocalShellEditorDialog> createState() => _LocalShellEditorDialogState();
}

class _LocalShellEditorDialogState extends ConsumerState<_LocalShellEditorDialog> {
  static const _defaultGenerationSystemPrompt =
      'You are an expert Linux/Unix shell scripting assistant. '
      'Generate clean, production-quality bash/sh scripts with correct syntax. '
      'Validate the script mentally before output. '
      'Output only the script code, no preamble or explanation. '
      'Do NOT wrap the output in markdown code fences.';

  late final TextEditingController _nameCtrl;
  late final TextEditingController _descCtrl;
  late final TextEditingController _contentCtrl;
  late final TextEditingController _generatePromptCtrl;
  late final TextEditingController _systemPromptCtrl;

  bool _saving = false;
  bool _generating = false;
  bool _testing = false;
  String _codeLlmChoice = 'llm1';

  bool get _canTestRun => Platform.isLinux || Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    final s = widget.existing;
    _nameCtrl = TextEditingController(text: s?.name ?? '');
    _descCtrl = TextEditingController(text: s?.description ?? '');
    _contentCtrl = TextEditingController(text: s?.content ?? '');
    _generatePromptCtrl = TextEditingController(text: s?.generationPrompt ?? '');
    _systemPromptCtrl = TextEditingController(
      text: s?.generationSystemPrompt.isNotEmpty == true ? s!.generationSystemPrompt : _defaultGenerationSystemPrompt,
    );
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _contentCtrl.dispose();
    _generatePromptCtrl.dispose();
    _systemPromptCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Script name is required.'), backgroundColor: Colors.orange));
      return;
    }
    setState(() => _saving = true);
    try {
      final svc = LocalShellScriptService.instance;
      final genPrompt = _generatePromptCtrl.text.trim();
      if (widget.existing != null) {
        await svc.updateScript(
          widget.existing!.copyWith(
            name: name,
            description: _descCtrl.text.trim(),
            content: _contentCtrl.text,
            generationSystemPrompt: _systemPromptCtrl.text.trim(),
            generationPrompt: genPrompt.isNotEmpty ? genPrompt : null,
          ),
        );
      } else {
        await svc.addScript(
          name: name,
          description: _descCtrl.text.trim(),
          content: _contentCtrl.text,
          generationSystemPrompt: _systemPromptCtrl.text.trim(),
          generationPrompt: genPrompt,
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Save failed: ${e.toString()}'), backgroundColor: AppTheme.error));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _generateScript() async {
    final prompt = _generatePromptCtrl.text.trim();
    if (prompt.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Describe what the script should do.'), backgroundColor: Colors.orange));
      return;
    }

    final llmSettings = ref.read(llmSettingsProvider);
    LLMService? effectiveLlm;

    if (_codeLlmChoice == 'llm2' && llmSettings.isConfigured2) {
      final llm2 = LLMService();
      await TaskRunnerService.configureLlmFromParams(
        llmService: llm2,
        providerKey: llmSettings.provider2.configKey,
        model: llmSettings.model2,
        apiKey: llmSettings.apiKey2,
        baseUrl: llmSettings.baseUrl2,
      );
      if (llm2.isConfigured) effectiveLlm = llm2;
    }

    if (effectiveLlm == null) {
      if (llmSettings.isConfigured) {
        final fallback = LLMService();
        await fallback.loadSavedProviderAndModel();
        if (fallback.isConfigured) effectiveLlm = fallback;
      } else if (llmSettings.isConfigured2) {
        final llm2 = LLMService();
        await TaskRunnerService.configureLlmFromParams(
          llmService: llm2,
          providerKey: llmSettings.provider2.configKey,
          model: llmSettings.model2,
          apiKey: llmSettings.apiKey2,
          baseUrl: llmSettings.baseUrl2,
        );
        if (llm2.isConfigured) effectiveLlm = llm2;
      }
    }

    if (effectiveLlm == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No LLM configured.'), backgroundColor: Colors.orange));
      return;
    }

    setState(() => _generating = true);
    try {
      final metaPrompt =
          'Generate a Linux/Unix bash shell script that does the following:\n\n$prompt\n\n'
          'Rules:\n'
          '- Output ONLY the bash script, starting with #!/bin/bash\n'
          '- Handle errors with set -e and appropriate error messages\n'
          '- Do NOT include any explanation outside the script itself\n'
          '- Do NOT wrap the output in markdown code fences';

      final systemPrompt = _systemPromptCtrl.text.trim().isNotEmpty ? _systemPromptCtrl.text.trim() : _defaultGenerationSystemPrompt;

      final response = await effectiveLlm.generateChatCompletion(
        messages: [
          ChatMessage(id: const Uuid().v4(), role: ChatRole.system, content: systemPrompt, timestamp: DateTime.now()),
          ChatMessage(id: const Uuid().v4(), role: ChatRole.user, content: metaPrompt, timestamp: DateTime.now()),
        ],
        maxTokens: 1024,
      );

      var script = response.content.trim();
      if (script.startsWith('```')) {
        final lines = script.split('\n');
        script = lines.skip(1).where((l) => !l.startsWith('```')).join('\n').trim();
      }

      if (mounted) {
        setState(() => _contentCtrl.text = script);
        if (_nameCtrl.text.isEmpty) {
          final firstLine = prompt.split('\n').first;
          _nameCtrl.text = firstLine.length > 40 ? '${firstLine.substring(0, 37)}...' : firstLine;
          _descCtrl.text = prompt.length > 120 ? '${prompt.substring(0, 117)}...' : prompt;
        }
      }
    } catch (e) {
      log.error('[LocalShellLibrary] LLM generation failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Generation failed: ${e.toString()}'), backgroundColor: AppTheme.error));
      }
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<void> _testRun() async {
    if (!_canTestRun) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Local shell execution requires Linux or macOS.'), backgroundColor: Colors.orange));
      return;
    }
    final content = _contentCtrl.text.trim();
    if (content.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Script content is empty.'), backgroundColor: Colors.orange));
      return;
    }

    final argsCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Test Run'),
        content: TextField(
          controller: argsCtrl,
          decoration: const InputDecoration(
            labelText: 'Arguments (optional)',
            hintText: 'space-separated, e.g. /tmp 6',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Run')),
        ],
      ),
    );
    if (confirmed != true) return;
    final args = argsCtrl.text.trim();

    setState(() => _testing = true);
    try {
      final result = await LocalShellScriptService.runContent(_contentCtrl.text, args: args, timeoutSeconds: 60);
      if (!mounted) return;
      await _showRunResult(result);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Test run failed: $e'), backgroundColor: AppTheme.error));
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _showRunResult(Map<String, dynamic> result) async {
    final error = result['error'] as String?;
    final exitCode = result['exitCode'] as int?;
    final stdout = (result['stdout'] as String? ?? '').trim();
    final stderr = (result['stderr'] as String? ?? '').trim();
    final success = result['success'] as bool? ?? false;

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(
              error != null
                  ? Icons.error
                  : success
                  ? Icons.check_circle
                  : Icons.cancel,
              color: error != null
                  ? AppTheme.error
                  : success
                  ? Colors.green
                  : Colors.orange,
              size: 20,
            ),
            const SizedBox(width: 8),
            Text(
              error != null
                  ? 'Run Failed'
                  : success
                  ? 'Run Succeeded'
                  : 'Run Completed (non-zero)',
            ),
          ],
        ),
        content: SizedBox(
          width: 600,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (error != null) ...[
                  const Text('Error:', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  _codeBox(ctx, error, isError: true),
                ] else ...[
                  Text('Exit code: $exitCode', style: TextStyle(fontSize: 12, color: success ? Colors.green : Colors.orange)),
                  if (stdout.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    const Text('stdout:', style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    _codeBox(ctx, stdout),
                  ],
                  if (stderr.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    const Text('stderr:', style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    _codeBox(ctx, stderr, isError: true),
                  ],
                  if (stdout.isEmpty && stderr.isEmpty)
                    const Text(
                      '(no output)',
                      style: TextStyle(fontStyle: FontStyle.italic, color: Colors.grey),
                    ),
                ],
              ],
            ),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }

  Widget _codeBox(BuildContext ctx, String text, {bool isError = false}) {
    final theme = Theme.of(ctx);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.brightness == Brightness.dark ? const Color(0xFF1E1E2E) : const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: isError ? AppTheme.error.withValues(alpha: 0.4) : theme.dividerColor),
      ),
      child: SelectableText(
        text,
        style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: isError ? AppTheme.error : null),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isNew = widget.existing == null;
    final screenSize = MediaQuery.of(context).size;
    final isMobile = screenSize.width < 600;
    final llmSettings = ref.watch(llmSettingsProvider);
    final llmReady = llmSettings.isConfigured || llmSettings.isConfigured2;

    final body = Column(
      mainAxisSize: isMobile ? MainAxisSize.max : MainAxisSize.min,
      children: [
        // ── Header ──
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
          child: Row(
            children: [
              const Icon(Icons.terminal, color: Colors.green),
              const SizedBox(width: 12),
              Text(
                isNew ? 'New Local Shell Script' : 'Edit Local Shell Script',
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
              ),
              const Spacer(),
              IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop(false)),
            ],
          ),
        ),
        const Divider(height: 1),
        // ── Scrollable body ──
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  controller: _nameCtrl,
                  decoration: const InputDecoration(labelText: 'Script Name', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _descCtrl,
                  decoration: const InputDecoration(labelText: 'Description', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 16),

                // ── AI generation ──
                Card(
                  color: Colors.green.withValues(alpha: 0.06),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Generate with AI', style: TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _systemPromptCtrl,
                          minLines: 2,
                          maxLines: 4,
                          decoration: const InputDecoration(
                            labelText: 'Generation System Prompt',
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _generatePromptCtrl,
                          minLines: 3,
                          maxLines: 6,
                          decoration: const InputDecoration(
                            labelText: 'What should this script do?',
                            hintText: 'e.g. "Check disk usage and alert if any partition is over 90%"',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Text('Generate with:', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
                            const SizedBox(width: 8),
                            DropdownButton<String>(
                              value: _codeLlmChoice,
                              isDense: true,
                              underline: const SizedBox(),
                              items: const [
                                DropdownMenuItem(value: 'llm1', child: Text('LLM 1 (Primary)')),
                                DropdownMenuItem(value: 'llm2', child: Text('LLM 2 (Coding)')),
                              ],
                              onChanged: (v) => setState(() => _codeLlmChoice = v ?? 'llm1'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          style: FilledButton.styleFrom(backgroundColor: Colors.green),
                          onPressed: _generating || !llmReady ? null : _generateScript,
                          icon: _generating
                              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : const Icon(Icons.auto_awesome, size: 16),
                          label: const Text('Generate'),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // ── Code editor ──
                const Text('Shell Script Code', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Container(
                  decoration: BoxDecoration(
                    color: theme.brightness == Brightness.dark ? const Color(0xFF1E1E2E) : const Color(0xFFF5F5F5),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: theme.dividerColor),
                  ),
                  child: TextField(
                    controller: _contentCtrl,
                    maxLines: 20,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                    decoration: const InputDecoration(
                      contentPadding: EdgeInsets.all(12),
                      border: InputBorder.none,
                      hintText: '#!/bin/bash\n# Write your shell script here\necho "Hello from shell!"',
                      hintStyle: TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.grey),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // ── Test run ──
                const Divider(),
                const SizedBox(height: 8),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: (_testing || _generating || !_canTestRun) ? null : _testRun,
                      icon: _testing
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.play_arrow, size: 16),
                      label: Text(_testing ? 'Running…' : 'Test Run'),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      _canTestRun ? 'Runs locally on this machine' : 'Requires Linux or macOS',
                      style: TextStyle(fontSize: 11, color: Colors.grey[500], fontStyle: FontStyle.italic),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),

        // ── Footer ──
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(L.of(context).cancel)),
              const SizedBox(width: 8),
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: Colors.green),
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.save),
                label: Text(isNew ? 'Create Script' : L.of(context).save),
              ),
            ],
          ),
        ),
      ],
    );

    return Dialog(
      insetPadding: isMobile ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      clipBehavior: Clip.antiAlias,
      shape: isMobile ? const RoundedRectangleBorder() : null,
      child: SizedBox(
        width: isMobile ? screenSize.width : screenSize.width * 0.9,
        height: isMobile ? screenSize.height : screenSize.height * 0.9,
        child: SafeArea(
          child: body,
        ),
      ),
    );
  }
}
