// ignore_for_file: use_build_context_synchronously

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/app_localizations.dart';
import 'package:uuid/uuid.dart';

import '../config/app_theme.dart';
import '../models/mcp_models.dart';
import '../models/py_tool_definition.dart';
import '../providers/llm_settings_provider.dart';
import '../providers/server_mode_provider.dart';
import '../services/server_api_client.dart';
import '../services/app_logger.dart';

import '../services/llm_service.dart';

import '../services/py_tool_library_service.dart';
import '../services/py_tool_runtime_service.dart';
import '../services/task_runner_service.dart';

// ─── List screen ──────────────────────────────────────────────────────────────

class PyToolLibraryScreen extends ConsumerStatefulWidget {
  const PyToolLibraryScreen({super.key, this.onInsertToolPrompt});

  final void Function(String toolName)? onInsertToolPrompt;

  /// Opens the screen. Desktop-only call sites should guard with
  /// Platform.isWindows / isMacOS / isLinux before calling.
  static Future<bool?> show(BuildContext context, {void Function(String toolName)? onInsertToolPrompt}) {
    return Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => PyToolLibraryScreen(onInsertToolPrompt: onInsertToolPrompt)));
  }

  @override
  ConsumerState<PyToolLibraryScreen> createState() => _PyToolLibraryScreenState();
}

class _PyToolLibraryScreenState extends ConsumerState<PyToolLibraryScreen> {
  bool _loading = true;
  bool _changed = false;
  List<PyToolDefinition> _tools = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final client = (ref.read(serverModeProvider).value?.isRemote ?? false)
        ? ref.read(serverApiClientProvider)
        : null;
    await PyToolLibraryService.instance.load(client);
    if (!mounted) return;
    final list = List<PyToolDefinition>.from(PyToolLibraryService.instance.tools);
    list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    setState(() {
      _tools = list;
      _loading = false;
    });
  }

  void _refresh() {
    final list = List<PyToolDefinition>.from(PyToolLibraryService.instance.tools);
    list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    setState(() {
      _tools = list;
      _changed = true;
    });
  }

  Future<void> _openEditor({PyToolDefinition? existing}) async {
    final changed = await _PyToolEditorDialog.show(context, ref: ref, existing: existing, onInsertToolPrompt: widget.onInsertToolPrompt);
    if (changed == true) _refresh();
  }

  Future<void> _loadSamples() async {
    final svc = PyToolLibraryService.instance;
    final samples = [
      PyToolDefinition.create(
        name: 'System Info',
        description: 'Returns OS name, version, CPU count, total RAM and hostname.',
        inputSchema: const {'type': 'object', 'properties': {}},
        code:
            '''
import sys, json, platform, socket, os

def execute(args: dict) -> dict:
    import psutil
    mem = psutil.virtual_memory()
    return {
        "os": platform.system(),
        "os_version": platform.version(),
        "machine": platform.machine(),
        "hostname": socket.gethostname(),
        "cpu_count": os.cpu_count(),
        "ram_total_gb": round(mem.total / (1024 ** 3), 2),
        "ram_used_percent": mem.percent,
    }

def _main():
    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
            result  = execute(request.get("args", {}))
            print(json.dumps({"success": True, "result": result}), flush=True)
        except Exception as exc:
            print(json.dumps({"success": False, "error": str(exc)}), flush=True)

if __name__ == "__main__":
    _main()
'''
                .trim(),
        requirements: 'psutil',
      ),
      PyToolDefinition.create(
        name: 'Fetch Web Page',
        description: 'HTTP GET a URL and return status code, content-type, page title and byte size.',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'url': {'type': 'string', 'description': 'URL to fetch (must start with http/https).'},
          },
          'required': ['url'],
        },
        code:
            r'''
import sys, json, urllib.request, re

def execute(args: dict) -> dict:
    url = args.get("url", "").strip()
    if not url.startswith(("http://", "https://")):
        return {"error": "url must start with http:// or https://"}
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=10) as resp:
        body = resp.read()
        ct   = resp.headers.get("Content-Type", "")
        title = ""
        m = re.search(rb"<title[^>]*>([^<]+)</title>", body, re.IGNORECASE)
        if m:
            title = m.group(1).decode("utf-8", errors="replace").strip()
        return {
            "status": resp.status,
            "content_type": ct,
            "title": title,
            "size_bytes": len(body),
        }

def _main():
    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
            result  = execute(request.get("args", {}))
            print(json.dumps({"success": True, "result": result}), flush=True)
        except Exception as exc:
            print(json.dumps({"success": False, "error": str(exc)}), flush=True)

if __name__ == "__main__":
    _main()
'''
                .trim(),
        requirements: '',
      ),
      PyToolDefinition.create(
        name: 'List Directory',
        description: 'Lists files and folders at a given local path with sizes and modification dates.',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'path': {'type': 'string', 'description': 'Absolute path to list (defaults to user home).'},
          },
          'required': [],
        },
        code:
            '''
import sys, json, os, pathlib, datetime

def execute(args: dict) -> dict:
    root = pathlib.Path(args.get("path", "") or pathlib.Path.home())
    if not root.exists():
        return {"error": f"Path does not exist: {root}"}
    entries = []
    for p in sorted(root.iterdir(), key=lambda x: (x.is_file(), x.name.lower())):
        stat = p.stat()
        entries.append({
            "name"    : p.name,
            "type"    : "file" if p.is_file() else "dir",
            "size"    : stat.st_size if p.is_file() else None,
            "modified": datetime.datetime.fromtimestamp(stat.st_mtime).isoformat(timespec="seconds"),
        })
    return {"path": str(root), "count": len(entries), "entries": entries}

def _main():
    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
            result  = execute(request.get("args", {}))
            print(json.dumps({"success": True, "result": result}), flush=True)
        except Exception as exc:
            print(json.dumps({"success": False, "error": str(exc)}), flush=True)

if __name__ == "__main__":
    _main()
'''
                .trim(),
        requirements: '',
      ),
    ];

    final existingNames = _tools.map((t) => t.name).toSet();
    int added = 0;
    final client = (ref.read(serverModeProvider).value?.isRemote ?? false)
        ? ref.read(serverApiClientProvider)
        : null;
    for (final def in samples) {
      if (existingNames.contains(def.name)) continue;
      await svc.save(def, client);
      added++;
    }
    _refresh();
    if (mounted) {
      final msg = added == 0 ? 'All sample Python tools already exist.' : '$added sample Python tool${added == 1 ? '' : 's'} added.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
    }
  }

  Future<void> _deleteTool(PyToolDefinition tool) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Python tool'),
        content: Text('Delete "${tool.name}" and its virtual environment from disk?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(L.of(context).cancel)),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: AppTheme.error)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final client = (ref.read(serverModeProvider).value?.isRemote ?? false)
        ? ref.read(serverApiClientProvider)
        : null;
    await PyToolLibraryService.instance.delete(tool.id, client);
    _refresh();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Deleted Python tool: ${tool.name}'), behavior: SnackBarBehavior.floating));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Python Tool Library'),
        leading: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop(_changed)),
        actions: [
          IconButton(icon: const Icon(Icons.science_outlined), tooltip: 'Load sample tools', onPressed: _loadSamples),
          IconButton(icon: const Icon(Icons.add), tooltip: 'New Python tool', onPressed: () => _openEditor()),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _tools.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.terminal, size: 64, color: Colors.grey[400]),
                  const SizedBox(height: 16),
                  Text('No Python tools yet', style: theme.textTheme.titleMedium?.copyWith(color: Colors.grey[500])),
                  const SizedBox(height: 8),
                  Text(
                    'Let the AI generate a Python tool for any task.',
                    style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey[400]),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _loadSamples,
                        icon: const Icon(Icons.science_outlined, size: 18),
                        label: const Text('Load samples'),
                      ),
                      const SizedBox(width: 12),
                      FilledButton.icon(
                        onPressed: () => _openEditor(),
                        icon: const Icon(Icons.add),
                        label: const Text('Create Python tool'),
                      ),
                    ],
                  ),
                ],
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _tools.length,
              separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
              itemBuilder: (ctx, index) {
                final tool = _tools[index];
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Colors.green.withValues(alpha: 0.12),
                    child: Icon(Icons.terminal, color: tool.venvReady ? Colors.green : Colors.orange, size: 20),
                  ),
                  title: Row(
                    children: [
                      Expanded(
                        child: Text(tool.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                      ),
                      if (!tool.isActive) _badge('Disabled', Colors.grey),
                      if (!tool.venvReady) _badge('Not init', Colors.orange),
                    ],
                  ),
                  subtitle: tool.description.isNotEmpty
                      ? Text(tool.description, maxLines: 1, overflow: TextOverflow.ellipsis)
                      : Text('Updated ${tool.updatedAt.toLocal()}', style: TextStyle(color: Colors.grey[500], fontSize: 12)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => _openEditor(existing: tool),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, color: AppTheme.error),
                        onPressed: () => _deleteTool(tool),
                      ),
                    ],
                  ),
                  onTap: () => _openEditor(existing: tool),
                );
              },
            ),
    );
  }

  Widget _badge(String label, Color color) => Container(
    margin: const EdgeInsets.only(left: 6),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
    child: Text(label, style: TextStyle(fontSize: 11, color: color)),
  );
}

// ─── Editor dialog ────────────────────────────────────────────────────────────

class _PyToolEditorDialog extends ConsumerStatefulWidget {
  const _PyToolEditorDialog({this.existing, this.onInsertToolPrompt});

  final PyToolDefinition? existing;
  final void Function(String toolName)? onInsertToolPrompt;

  static Future<bool?> show(
    BuildContext context, {
    required WidgetRef ref,
    PyToolDefinition? existing,
    void Function(String toolName)? onInsertToolPrompt,
  }) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PyToolEditorDialog(existing: existing, onInsertToolPrompt: onInsertToolPrompt),
    );
  }

  @override
  ConsumerState<_PyToolEditorDialog> createState() => _PyToolEditorDialogState();
}

class _PyToolEditorDialogState extends ConsumerState<_PyToolEditorDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _descCtrl;
  late final TextEditingController _codeCtrl;
  late final TextEditingController _reqsCtrl;
  late final TextEditingController _generatePromptCtrl;
  late final TextEditingController _testArgsCtrl;

  bool _saving = false;
  bool _generating = false;
  bool _initialising = false;
  bool _testing = false;
  bool _active = true;
  // 'llm1' = global LLM 1, 'llm2' = global LLM 2, 'task' = task LLM
  String _codeLlmChoice = 'llm1';

  String? _initStatusMessage;
  Color _initStatusColor = Colors.green;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameCtrl = TextEditingController(text: e?.name ?? '');
    _descCtrl = TextEditingController(text: e?.description ?? '');
    _codeCtrl = TextEditingController(text: e?.code.isNotEmpty == true ? e!.code : _defaultCodeTemplate);
    _reqsCtrl = TextEditingController(text: e?.requirements ?? '');
    _generatePromptCtrl = TextEditingController(text: e?.generationPrompt ?? '');
    final savedPyArgs = e?.testArgs ?? '';
    _testArgsCtrl = TextEditingController(
      text: savedPyArgs.isNotEmpty && savedPyArgs != '{}'
          ? savedPyArgs
          : _extractPyDefaultArgs(e?.code.isNotEmpty == true ? e!.code : _defaultCodeTemplate),
    );
    _active = e?.isActive ?? true;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _codeCtrl.dispose();
    _reqsCtrl.dispose();
    _generatePromptCtrl.dispose();
    _testArgsCtrl.dispose();
    super.dispose();
  }

  // ─── Generate with AI ────────────────────────────────────────────────────

  Future<void> _generateWithAi() async {
    final prompt = _generatePromptCtrl.text.trim();
    if (prompt.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Describe what the Python tool should do.')));
      return;
    }

    final llmSettings = ref.read(llmSettingsProvider);
    LLMService? effectiveLlm;

    // Explicit per-choice LLM setup — no silent fallback so the user can see
    // exactly which model is used and get a clear error if it is not configured.
    if (_codeLlmChoice == 'llm1') {
      if (!llmSettings.isConfigured) {
        log.warning('[PyTool] Generate: LLM 1 chosen but not configured');
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('LLM 1 (Primary) is not configured. Open LLM Settings or choose LLM 2.'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 6),
          ),
        );
        return;
      }
      final llm1 = LLMService();
      await TaskRunnerService.configureLlmFromParams(
        llmService: llm1,
        providerKey: llmSettings.provider.configKey,
        model: llmSettings.model,
        apiKey: llmSettings.apiKey,
        baseUrl: llmSettings.baseUrl,
      );
      if (llm1.isConfigured) effectiveLlm = llm1;
    } else if (_codeLlmChoice == 'llm2') {
      if (!llmSettings.isConfigured2) {
        log.warning('[PyTool] Generate: LLM 2 chosen but not configured');
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('LLM 2 (Coding) is not configured. Open LLM Settings or choose LLM 1.'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 6),
          ),
        );
        return;
      }
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
      log.warning('[PyTool] Generate: could not configure LLM (choice=$_codeLlmChoice)');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L.of(context).noLlmForScript), backgroundColor: Colors.orange));
      return;
    }

    log.info('[PyTool] Generate starting — LLM: $_codeLlmChoice (${effectiveLlm.currentProvider.name} / ${effectiveLlm.currentModel})');

    setState(() => _generating = true);
    try {
      final userPrompt =
          'Create a TealKit Python Tool for this task:\n$prompt\n\n'
          'Requirements:\n'
          '- Return ONLY the JSON object (no markdown fences)\n'
          '- The code must follow the template structure with the _main() stdio section at the bottom unchanged\n'
          '- Fill in the execute(args) function with the tool logic\n'
          '- Add any needed imports at the top\n'
          '- List only third-party pip packages in requirements (leave empty if only stdlib needed)';

      final response = await effectiveLlm.generateChatCompletion(
        messages: [
          ChatMessage(id: const Uuid().v4(), role: ChatRole.system, content: pyToolGenerationSystemPrompt, timestamp: DateTime.now()),
          ChatMessage(id: const Uuid().v4(), role: ChatRole.user, content: userPrompt, timestamp: DateTime.now()),
        ],
        maxTokens: 2400,
      );

      var raw = response.content.trim();
      // Strip markdown fences if the LLM ignored the instruction
      if (raw.startsWith('```')) {
        final lines = raw.split('\n');
        raw = lines.skip(1).where((l) => !l.startsWith('```')).join('\n').trim();
      }
      // Extract the first complete JSON object in case of preamble/postamble text
      final jsonStart = raw.indexOf('{');
      final jsonEnd = raw.lastIndexOf('}');
      if (jsonStart != -1 && jsonEnd > jsonStart) {
        raw = raw.substring(jsonStart, jsonEnd + 1);
      }

      // Parse the JSON response
      final Map<String, dynamic> parsed;
      try {
        parsed = jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('AI returned non-JSON output. Try again or refine your prompt.'), backgroundColor: AppTheme.error),
        );
        return;
      }

      var generatedCode = (parsed['code'] as String? ?? '').trim();

      // Always strip everything from the first _main / TEALKIT section marker and
      // re-append the canonical footer — this prevents  LLMs from writing their own
      // (often broken) protocol variants.
      const tealKitFooter =
          '\n\n'
          '# ===== TEALKIT STDIO PROTOCOL (DO NOT EDIT BELOW) =====\n'
          'import sys\n'
          'import json\n'
          '\n'
          'def _main():\n'
          '    for raw_line in sys.stdin:\n'
          '        line = raw_line.strip()\n'
          '        if not line:\n'
          '            continue\n'
          '        try:\n'
          '            request = json.loads(line)\n'
          '            result  = execute(request.get("args", {}))\n'
          '            print(json.dumps({"success": True,  "result": result}), flush=True)\n'
          '        except Exception as exc:\n'
          '            print(json.dumps({"success": False, "error":  str(exc)}), flush=True)\n'
          '\n'
          '\n'
          'if __name__ == "__main__":\n'
          '    _main()\n';

      // Strip any pre-existing _main / TEALKIT block that the LLM may have invented.
      final mainIdx = generatedCode.indexOf('\ndef _main():');
      final tealIdx = generatedCode.indexOf('# ===== TEALKIT');
      final jsonLineIdx = generatedCode.indexOf('# JSON-LINE STDIO');
      final cutPoint = [
        if (mainIdx != -1) mainIdx,
        if (tealIdx != -1) tealIdx,
        if (jsonLineIdx != -1) jsonLineIdx,
      ].fold<int>(-1, (best, idx) => best == -1 ? idx : (idx < best ? idx : best));
      if (cutPoint != -1) {
        generatedCode = generatedCode.substring(0, cutPoint).trimRight();
      }
      generatedCode += tealKitFooter;

      setState(() {
        if (_nameCtrl.text.trim().isEmpty) _nameCtrl.text = (parsed['name'] as String? ?? '').trim();
        if (_descCtrl.text.trim().isEmpty) _descCtrl.text = (parsed['description'] as String? ?? '').trim();
        _codeCtrl.text = generatedCode;
        _reqsCtrl.text = (parsed['requirements'] as String? ?? '').trim();
      });
      // Infer test args in background — silent, non-blocking
      _inferJsonTestArgs(generatedCode, effectiveLlm, language: 'python').ignore();
    } catch (e) {
      log.error('[PyTool] Generate failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Generation failed: $e'), backgroundColor: AppTheme.error, duration: const Duration(seconds: 8)),
      );
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  // ─── Sync param extraction (no LLM) ─────────────────────────────────────

  /// Parses `args.get('key', default)` patterns and returns a JSON object string.
  static String _extractPyDefaultArgs(String code) {
    final props = <String, Object?>{};
    final re = RegExp(r'''args\.get\(\s*['"]([^'"]+)['"]\s*,\s*([^)]+?)\s*\)''', dotAll: true);
    for (final m in re.allMatches(code)) {
      final key = m.group(1)!;
      final rawVal = m.group(2)!.trim();
      if (rawVal == 'True' || rawVal == 'true') {
        props[key] = true;
      } else if (rawVal == 'False' || rawVal == 'false') {
        props[key] = false;
      } else if (rawVal == 'None' || rawVal == 'null') {
        props[key] = null;
      } else {
        final n = num.tryParse(rawVal);
        if (n != null) {
          props[key] = n;
        } else {
          // Strip surrounding quotes and unescape double-backslash.
          var s = rawVal.replaceAll(RegExp(r'''^\'|\'\'$|^\'|\'\'$|^["']|["']$'''), '');
          s = s.replaceAll(RegExp(r'''^['"]|['"]$'''), '');
          props[key] = s;
        }
      }
    }
    if (props.isEmpty) return '{}';
    return const JsonEncoder.withIndent('  ').convert(props);
  }

  // ─── Infer test args ────────────────────────────────────────────────────

  Future<void> _inferJsonTestArgs(String code, LLMService llm, {String language = 'python'}) async {
    try {
      final resp = await llm.generateChatCompletion(
        messages: [
          ChatMessage(
            id: const Uuid().v4(),
            role: ChatRole.system,
            content: 'You are a test-data generator. Respond with ONLY a JSON object — no markdown, no explanation.',
            timestamp: DateTime.now(),
          ),
          ChatMessage(
            id: const Uuid().v4(),
            role: ChatRole.user,
            content:
                'Analyze this $language tool\'s execute(args) function/inputSchema and return ONLY a compact JSON object with '
                'realistic example values for the args parameter. No markdown, no explanation.\n\n$code',
            timestamp: DateTime.now(),
          ),
        ],
        maxTokens: 200,
      );
      var raw = resp.content.trim();
      if (raw.startsWith('```')) {
        raw = raw.split('\n').skip(1).where((l) => !l.startsWith('```')).join('\n').trim();
      }
      final s = raw.indexOf('{');
      final e = raw.lastIndexOf('}');
      if (s == -1 || e <= s) return;
      final pretty = const JsonEncoder.withIndent('  ').convert(jsonDecode(raw.substring(s, e + 1)));
      if (mounted) setState(() => _testArgsCtrl.text = pretty);
    } catch (_) {
      // silently ignore — test args remain at their current value
    }
  }

  // ─── Init venv ───────────────────────────────────────────────────────────

  Future<void> _initVenv() async {
    // Save first so definition is persisted locally (and synced if server mode)
    final saved = await _saveToLibrary(silent: true);
    if (saved == null) return;

    setState(() {
      _initialising = true;
      _initStatusMessage = null;
    });

    // In Server Mode: sync tool to server then trigger remote venv init.
    final serverClient = ref.read(serverApiClientProvider);
    final isRemote = ref.read(serverModeProvider).value?.isRemote ?? false;
    if (isRemote && serverClient != null) {
      await _initVenvOnServer(saved, serverClient);
      return;
    }

    final err = await PyToolRuntimeService.instance.initTool(
      saved,
      onProgress: (p) {
        if (mounted) setState(() => _initStatusMessage = p.message);
      },
    );

    if (!mounted) return;
    setState(() {
      _initialising = false;
      if (err == null) {
        _initStatusMessage = 'Virtual environment ready.';
        _initStatusColor = Colors.green;
      } else {
        _initStatusMessage = err;
        _initStatusColor = AppTheme.error;
      }
    });

    // Refresh the parent list to reflect the updated venvReady state
    if (mounted && err == null) {
      final parentState = context.findAncestorStateOfType<_PyToolLibraryScreenState>();
      parentState?._refresh();
    }
  }

  Future<void> _initVenvOnServer(PyToolDefinition def, ServerApiClient serverClient) async {
    try {
      if (mounted) setState(() => _initStatusMessage = 'Syncing tool to server…');
      // Push definition to server
      await serverClient.syncPyTools([
        {
          'id': def.id,
          'name': def.name,
          'description': def.description,
          'inputSchema': def.inputSchema,
          'code': def.code,
          'requirements': def.requirements,
          'venvReady': false,
          'isActive': def.isActive,
          'generationPrompt': def.generationPrompt,
        },
      ]);
      if (mounted) setState(() => _initStatusMessage = 'Initializing virtual environment on server…');
      final result = await serverClient.initPyTool(def.id);
      if (!mounted) return;
      final success = result['success'] == true;
      final message = success
          ? (result['message']?.toString() ?? 'Virtual environment ready on server.')
          : (result['error']?.toString() ?? 'Server venv init failed.');
      final logLines = result['log'] as List<dynamic>?;
      final detail = logLines != null && logLines.isNotEmpty ? '\n${logLines.join('\n')}' : '';

      // Update the in-memory cache so the list immediately shows "Ready"
      if (success) {
        await PyToolLibraryService.instance.setVenvReady(def.id, ready: true);
      }

      setState(() {
        _initialising = false;
        _initStatusMessage = '$message$detail';
        _initStatusColor = success ? Colors.green : AppTheme.error;
      });

      // Refresh the parent list to reflect the updated venvReady state
      if (mounted) {
        final parentState = context.findAncestorStateOfType<_PyToolLibraryScreenState>();
        parentState?._refresh();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _initialising = false;
        _initStatusMessage = 'Server venv init failed: $e';
        _initStatusColor = AppTheme.error;
      });
    }
  }

  // ─── Test execution ───────────────────────────────────────────────────────

  Future<void> _runTest() async {
    final toolName = _nameCtrl.text.trim();

    // Re-extract live defaults from the current editor so a freshly generated
    // script gets its defaults even before the first save/reopen.
    final liveArgs = _extractPyDefaultArgs(_codeCtrl.text);
    final currentArgs = _testArgsCtrl.text.trim();
    final argsCtrl = TextEditingController(text: currentArgs.isNotEmpty && currentArgs != '{}' ? currentArgs : liveArgs);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Test Run${toolName.isNotEmpty ? ": $toolName" : ""}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Parameters (JSON object or key=value pairs):',
              style: Theme.of(ctx).textTheme.bodySmall?.copyWith(color: Theme.of(ctx).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: argsCtrl,
              minLines: 3,
              maxLines: 6,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(hintText: '{"folder": "C:\\\\temp", "months": 12}', border: OutlineInputBorder()),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.play_arrow, size: 18),
            label: const Text('Run test'),
            style: FilledButton.styleFrom(backgroundColor: AppTheme.primaryBlue),
          ),
        ],
      ),
    );

    // Persist whatever the user typed for the next open.
    final argsStr = argsCtrl.text.trim();
    Future.delayed(const Duration(milliseconds: 500), argsCtrl.dispose);
    if (confirmed != true || !mounted) return;
    _testArgsCtrl.text = argsStr;

    // Parse the args.
    Map<String, dynamic> args;
    if (argsStr.isEmpty) {
      args = {};
    } else if (argsStr.startsWith('{')) {
      try {
        final parsed = jsonDecode(argsStr);
        if (parsed is! Map<String, dynamic>) throw const FormatException('not an object');
        args = parsed;
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Invalid JSON. Use key=value pairs or a JSON object.')));
        }
        return;
      }
    } else {
      args = {};
      for (final part in argsStr.split(RegExp(r'\s+'))) {
        final eq = part.indexOf('=');
        if (eq > 0) {
          final key = part.substring(0, eq);
          final val = part.substring(eq + 1);
          try {
            args[key] = jsonDecode(val);
          } catch (_) {
            args[key] = val;
          }
        }
      }
    }

    // Ensure saved & init'd.
    final saved = await _saveToLibrary(silent: true);
    if (saved == null) return;

    final serverMode = ref.read(serverModeProvider).value;
    final isRemote = serverMode?.isRemote ?? false;

    if (!isRemote && !saved.venvReady) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Run "Init venv" first before testing.'), backgroundColor: Colors.orange));
      return;
    }

    setState(() => _testing = true);
    Map<String, dynamic> result;
    log.info('[PyTool] Test run starting — tool: "$toolName" args: ${jsonEncode(args)}');
    try {
      if (isRemote) {
        final api = ServerApiClient(serverUrl: serverMode!.serverUrl, apiKey: serverMode.apiKey.isNotEmpty ? serverMode.apiKey : null);
        result = await api.runPyTool(saved.id, args, timeoutSeconds: 60);
      } else {
        final output = await PyToolRuntimeService.instance.execute(saved, args, timeout: const Duration(seconds: 60));
        result = {'success': true, 'result': output};
      }
      log.info('[PyTool] Test run succeeded — tool: "$toolName"');
    } on PyToolError catch (e) {
      log.error('[PyTool] Test run PyToolError — tool: "$toolName": ${e.message}');
      result = {'success': false, 'error': e.message};
    } catch (e) {
      log.error('[PyTool] Test run unexpected error — tool: "$toolName": $e');
      result = {'success': false, 'error': e.toString()};
    } finally {
      if (mounted) setState(() => _testing = false);
    }

    if (!mounted) return;
    _showTestOutputDialog(context, result);
  }

  void _showTestOutputDialog(BuildContext context, Map<String, dynamic> result) {
    final toolName = _nameCtrl.text.trim();
    final isSuccess = result['success'] == true;
    final error = result['error'] as String?;
    final output = result['result'];

    showDialog<void>(
      context: context,
      builder: (ctx) {
        final screenSize = MediaQuery.of(ctx).size;
        final isMobile = screenSize.width < 600;
        return Dialog(
          insetPadding: isMobile ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          clipBehavior: Clip.antiAlias,
          shape: isMobile ? const RoundedRectangleBorder() : null,
          child: SizedBox(
            width: isMobile ? screenSize.width : 680,
            height: isMobile ? screenSize.height : null,
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
                    child: Row(
                      children: [
                        Icon(
                          isSuccess ? Icons.check_circle_outline : Icons.error_outline,
                          color: isSuccess ? Colors.green : AppTheme.error,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            isSuccess
                                ? 'Test Run${toolName.isNotEmpty ? ": $toolName" : ""} — Success'
                                : 'Test Run${toolName.isNotEmpty ? ": $toolName" : ""} — Failed',
                            style: Theme.of(ctx).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(ctx).pop()),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (!isSuccess) ...[
                            Text(
                              'Error:',
                              style: TextStyle(color: AppTheme.error, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 4),
                            _PyOutputBox(text: error ?? ''),
                          ] else ...[
                            const Text('Output:', style: TextStyle(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 4),
                            _PyOutputBox(text: const JsonEncoder.withIndent('  ').convert(output)),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [FilledButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Close'))],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ─── Save ─────────────────────────────────────────────────────────────────

  /// Saves to library and returns the saved definition, or null on error.
  Future<PyToolDefinition?> _saveToLibrary({bool silent = false}) async {
    if (_nameCtrl.text.trim().isEmpty) {
      if (!silent) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Tool name is required.')));
      }
      return null;
    }

    final lib = PyToolLibraryService.instance;
    final existing = widget.existing;

    PyToolDefinition def;
    final genPrompt = _generatePromptCtrl.text.trim();
    if (existing != null) {
      // Read venvReady from the live service cache so we don't overwrite a
      // freshly initialised venv with the stale value from widget.existing.
      final liveVenvReady = lib.getById(existing.id)?.venvReady ?? existing.venvReady;
      def = existing.copyWith(
        name: _nameCtrl.text.trim(),
        description: _descCtrl.text.trim(),
        code: _codeCtrl.text,
        requirements: _reqsCtrl.text,
        isActive: _active,
        generationPrompt: genPrompt.isNotEmpty ? genPrompt : null,
        testArgs: _testArgsCtrl.text.trim(),
        venvReady: liveVenvReady,
      );
    } else {
      // Check if already saved in a prior silent call (same dialog session)
      final existingById = lib.getByName(_nameCtrl.text.trim()) ?? lib.getById(_resolvedTempId ?? '');
      if (existingById != null) {
        def = existingById.copyWith(
          name: _nameCtrl.text.trim(),
          description: _descCtrl.text.trim(),
          code: _codeCtrl.text,
          requirements: _reqsCtrl.text,
          isActive: _active,
          generationPrompt: genPrompt.isNotEmpty ? genPrompt : null,
          testArgs: _testArgsCtrl.text.trim(),
        );
      } else {
        def = PyToolDefinition.create(
          name: _nameCtrl.text.trim(),
          description: _descCtrl.text.trim(),
          inputSchema: const {'type': 'object', 'properties': {}},
          code: _codeCtrl.text,
          requirements: _reqsCtrl.text,
          isActive: _active,
          generationPrompt: genPrompt,
          testArgs: _testArgsCtrl.text.trim(),
        );
        _resolvedTempId = def.id;
      }
    }

    final client = (ref.read(serverModeProvider).value?.isRemote ?? false)
        ? ref.read(serverApiClientProvider)
        : null;
    return lib.save(def, client);
  }

  String? _resolvedTempId;

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final saved = await _saveToLibrary();
      if (saved != null && mounted) Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isNew = widget.existing == null;
    final screenSize = MediaQuery.of(context).size;
    final isMobile = screenSize.width < 600;

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
              Text(isNew ? 'New Python Tool' : 'Edit Python Tool', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
              const Spacer(),
              IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop(false)),
            ],
          ),
        ),
        const Divider(height: 1),

        // ── Scrollable form ──
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  controller: _nameCtrl,
                  decoration: const InputDecoration(labelText: 'Tool Name', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _descCtrl,
                  decoration: const InputDecoration(labelText: 'Description', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Enabled'),
                  subtitle: const Text('Disabled tools are stored but not exposed to the MCP runtime.'),
                  value: _active,
                  onChanged: (v) => setState(() => _active = v),
                ),
                const SizedBox(height: 12),

                // ── AI generation card ──
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
                          controller: _generatePromptCtrl,
                          minLines: 3,
                          maxLines: 6,
                          decoration: const InputDecoration(
                            labelText: 'What should this tool do?',
                            hintText:
                                'Example: "Copy all *.log files from C:\\app\\logs to \\\\server\\shared\\logs and return how many were copied."',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Text('Generate with:', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                            const SizedBox(width: 8),
                            DropdownButton<String>(
                              value: _codeLlmChoice,
                              isDense: true,
                              underline: const SizedBox(),
                              items: [
                                DropdownMenuItem(value: 'llm1', child: Text('LLM 1 (Primary)')),
                                const DropdownMenuItem(value: 'llm2', child: Text('LLM 2 (Coding)')),
                              ],
                              onChanged: (v) => setState(() => _codeLlmChoice = v ?? 'llm1'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          style: FilledButton.styleFrom(backgroundColor: Colors.green),
                          onPressed: _generating ? null : _generateWithAi,
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

                // ── Python code editor ──
                const Text('Python Code (main.py)', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                _codeBox(_codeCtrl, lines: 22),
                const SizedBox(height: 14),

                // ── requirements.txt ──
                const Text('requirements.txt', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                _codeBox(_reqsCtrl, lines: 5, hint: 'Leave empty if only stdlib is needed.\nExample:\nrequests\npyarrow==15.0.0'),
                const SizedBox(height: 16),

                // ── Init venv ──
                const Divider(),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.settings_suggest, size: 18, color: Colors.green),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Init virtual environment', style: TextStyle(fontWeight: FontWeight.w600)),
                          Text(
                            'Creates .venv and installs requirements.txt. Must run at least once before use.',
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: _initialising ? null : _initVenv,
                      icon: _initialising
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.play_circle_outline, size: 16),
                      label: const Text('Init venv'),
                    ),
                  ],
                ),
                if (_initStatusMessage != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    _initStatusMessage!,
                    style: TextStyle(fontSize: 12, color: _initStatusColor, fontFamily: 'monospace'),
                  ),
                ],
                const SizedBox(height: 14),

                // ── Test execution ──
                const Divider(),
                const SizedBox(height: 8),
                const Text('Test Run', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                OutlinedButton.icon(
                  onPressed: _testing ? null : _runTest,
                  icon: _testing
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.play_arrow, size: 16),
                  label: const Text('Run test'),
                ),

                // ── Insert into prompt ──
                if (widget.onInsertToolPrompt != null) ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () {
                      final name = _nameCtrl.text.trim();
                      if (name.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Tool name is required.')));
                        return;
                      }
                      widget.onInsertToolPrompt?.call(name);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Inserted Python tool call hint into prompt.'), behavior: SnackBarBehavior.floating),
                      );
                      Navigator.of(context).pop(false);
                    },
                    icon: const Icon(Icons.add_circle_outline, size: 18),
                    label: const Text('Insert into prompt'),
                  ),
                ],
              ],
            ),
          ),
        ),

        // ── Footer buttons ──
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
                label: Text(isNew ? 'Create Python Tool' : L.of(context).save),
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

  Widget _codeBox(TextEditingController ctrl, {required int lines, String? hint}) => Container(
    decoration: BoxDecoration(
      color: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF1E1E2E) : const Color(0xFFF5F5F5),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: Theme.of(context).dividerColor),
    ),
    child: TextField(
      controller: ctrl,
      maxLines: lines,
      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
      decoration: InputDecoration(
        contentPadding: const EdgeInsets.all(12),
        border: InputBorder.none,
        hintText: hint,
        hintStyle: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.grey),
      ),
    ),
  );

  static const String _defaultCodeTemplate = r'''#!/usr/bin/env python3
"""
TealKit Python Tool
===================
<describe your tool here>
"""
import sys
import json

# Add your imports here


def execute(args: dict) -> object:
    """
    Implement your tool logic here.
    Return any JSON-serialisable value.
    Raise an exception to signal an error.
    """
    # TODO: implement
    return {"message": "not implemented"}


# ── JSON-line stdio protocol – do not modify below ────────────────────────────
def _main():
    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
            result  = execute(request.get("args", {}))
            print(json.dumps({"success": True,  "result": result}), flush=True)
        except Exception as exc:
            print(json.dumps({"success": False, "error":  str(exc)}), flush=True)

if __name__ == "__main__":
    _main()
''';
}

class _PyOutputBox extends StatelessWidget {
  const _PyOutputBox({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1A1A2E) : const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: SelectableText(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
    );
  }
}
