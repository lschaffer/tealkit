import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/app_localizations.dart';
import 'package:uuid/uuid.dart';

import '../config/app_theme.dart';
import '../mcp/servers/js_bridge_mcp_server.dart';
import '../models/mcp_models.dart';
import '../providers/llm_settings_provider.dart';

import '../services/js_tool_library_service.dart';
import '../services/js_tool_runtime_service.dart';
import '../services/llm_service.dart';

import '../services/function_hint_generation_service.dart';
import '../services/task_runner_service.dart';
import '../providers/server_mode_provider.dart';
import '../widgets/code_editor_field.dart';
import '../widgets/function_hint_build_progress_dialog.dart';

class JsToolLibraryScreen extends ConsumerStatefulWidget {
  const JsToolLibraryScreen({super.key, this.onInsertToolPrompt});

  final void Function(String toolName)? onInsertToolPrompt;

  static Future<bool?> show(BuildContext context, {void Function(String toolName)? onInsertToolPrompt}) {
    return Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => JsToolLibraryScreen(onInsertToolPrompt: onInsertToolPrompt)));
  }

  @override
  ConsumerState<JsToolLibraryScreen> createState() => _JsToolLibraryScreenState();
}

class _JsToolLibraryScreenState extends ConsumerState<JsToolLibraryScreen> {
  bool _loading = true;
  bool _changed = false;
  List<JsToolDefinition> _tools = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _generateJsSkills() async {
    final client = ref.read(serverApiClientProvider);
    final bridge = JsBridgeMcpServer();
    await bridge.initialize({});
    final dynamicTools = bridge.tools.where((t) => t.name != 'list_js_tools' && t.name != 'run_js_tool').toList();
    if (dynamicTools.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No active JS tools to generate skills for.')));
      }
      return;
    }
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
      final generated = await FunctionHintGenerationService().generateSkillsForTools(dynamicTools, 'js_bridge');
      if (client != null) {
        for (final s in generated) {
          await client.saveSkill(s.toJson());
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Generated ${generated.length} skill${generated.length == 1 ? '' : 's'} for JS tools')));
      }
    } finally {
      if (mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _load() async {
    final client = (ref.read(serverModeProvider).value?.isRemote ?? false)
        ? ref.read(serverApiClientProvider)
        : null;
    await JsToolLibraryService.instance.load(client);
    if (!mounted) return;
    setState(() {
      _tools = List.from(JsToolLibraryService.instance.tools);
      _loading = false;
    });
  }

  void _refresh() {
    setState(() {
      _tools = List.from(JsToolLibraryService.instance.tools);
      _changed = true;
    });
  }

  Future<void> _loadSamples() async {
    final svc = JsToolLibraryService.instance;
    final samples = [
      JsToolDefinition.create(
        name: 'Timestamp Converter',
        description: 'Converts a Unix timestamp (seconds) to a human-readable UTC date/time string and vice-versa.',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'timestamp': {'type': 'number', 'description': 'Unix timestamp in seconds (omit to use current time).'},
            'dateString': {'type': 'string', 'description': 'ISO 8601 date string to convert to Unix timestamp (optional).'},
          },
          'required': [],
        },
        jsCode:
            r'''
const generatedTool = {
  name: "timestamp_converter",
  description: "Converts Unix timestamps to readable dates and vice-versa.",
  inputSchema: {
    type: "object",
    properties: {
      timestamp: { type: "number", description: "Unix timestamp in seconds" },
      dateString: { type: "string", description: "ISO 8601 string to convert to Unix timestamp" }
    }
  },
  execute: async (args) => {
    try {
      if (args.dateString) {
        const d = new Date(args.dateString);
        if (isNaN(d.getTime())) return JSON.stringify({ ok: false, error: "Invalid date string" });
        return JSON.stringify({ ok: true, unix: Math.floor(d.getTime() / 1000), iso: d.toISOString() });
      }
      const ts = typeof args.timestamp === "number" ? args.timestamp : Math.floor(Date.now() / 1000);
      const d = new Date(ts * 1000);
      return JSON.stringify({ ok: true, unix: ts, iso: d.toISOString(), utc: d.toUTCString() });
    } catch (e) {
      return JSON.stringify({ ok: false, error: String(e) });
    }
  }
};
'''
                .trim(),
      ),
      JsToolDefinition.create(
        name: 'Currency Converter',
        description: 'Converts an amount between two currencies using the free open.er-api.com exchange rates (no API key needed).',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'amount': {'type': 'number', 'description': 'Amount to convert.'},
            'from': {'type': 'string', 'description': 'Source currency code, e.g. USD.'},
            'to': {'type': 'string', 'description': 'Target currency code, e.g. EUR.'},
          },
          'required': ['amount', 'from', 'to'],
        },
        jsCode:
            r'''
const generatedTool = {
  name: "currency_converter",
  description: "Convert an amount between two currencies using free exchange rates (no API key).",
  inputSchema: {
    type: "object",
    properties: {
      amount: { type: "number", description: "Amount to convert" },
      from:   { type: "string", description: "Source currency code e.g. USD" },
      to:     { type: "string", description: "Target currency code e.g. EUR" }
    },
    required: ["amount", "from", "to"]
  },
  execute: async (args) => {
    try {
      const from = String(args.from).toUpperCase();
      const to   = String(args.to).toUpperCase();
      const amount = Number(args.amount);
      const res  = await fetch(`https://open.er-api.com/v6/latest/${from}`);
      const data = await res.json();
      if (data.result !== "success") return JSON.stringify({ ok: false, error: data["error-type"] || "API error" });
      const rate = data.rates[to];
      if (rate == null) return JSON.stringify({ ok: false, error: `Unknown currency: ${to}` });
      return JSON.stringify({ ok: true, from, to, amount, rate, converted: Math.round(amount * rate * 1e6) / 1e6 });
    } catch (e) {
      return JSON.stringify({ ok: false, error: String(e) });
    }
  }
};
'''
                .trim(),
      ),
      JsToolDefinition.create(
        name: 'City Geolocation',
        description:
            'Returns latitude, longitude, country and timezone for a city name using the free Open-Meteo geocoding API (no key needed).',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'city': {'type': 'string', 'description': 'City name to look up, e.g. "Berlin".'},
          },
          'required': ['city'],
        },
        jsCode:
            r'''
const generatedTool = {
  name: "city_geolocation",
  description: "Get latitude, longitude, country and timezone for a city (free, no API key).",
  inputSchema: {
    type: "object",
    properties: { city: { type: "string", description: "City name e.g. Berlin" } },
    required: ["city"]
  },
  execute: async (args) => {
    try {
      const city = String(args.city || "").trim();
      if (!city) return JSON.stringify({ ok: false, error: "city is required" });
      const url = `https://geocoding-api.open-meteo.com/v1/search?name=${encodeURIComponent(city)}&count=1&language=en&format=json`;
      const res  = await fetch(url);
      const data = await res.json();
      if (!data.results || data.results.length === 0) return JSON.stringify({ ok: false, error: `City not found: ${city}` });
      const r = data.results[0];
      return JSON.stringify({ ok: true, name: r.name, country: r.country, countryCode: r.country_code,
        latitude: r.latitude, longitude: r.longitude, timezone: r.timezone, population: r.population ?? null });
    } catch (e) {
      return JSON.stringify({ ok: false, error: String(e) });
    }
  }
};
'''
                .trim(),
      ),
    ];

    final existingNames = _tools.map((t) => t.name).toSet();
    int added = 0;
    final client = (ref.read(serverModeProvider).value?.isRemote ?? false)
        ? ref.read(serverApiClientProvider)
        : null;
    for (final def in samples) {
      if (existingNames.contains(def.name)) continue;
      await svc.addTool(
        name: def.name,
        description: def.description,
        inputSchema: def.inputSchema,
        jsCode: def.jsCode,
        client: client,
      );
      added++;
    }
    _refresh();
    if (mounted) {
      final msg = added == 0 ? 'All sample JS tools already exist.' : '$added sample JS tool${added == 1 ? '' : 's'} added.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
    }
  }

  Future<void> _openEditor({JsToolDefinition? existing}) async {
    // Gate new-tool creation for free users; editing existing is always allowed.
    final changed = await _JsToolEditorDialog.show(context, ref: ref, existing: existing, onInsertToolPrompt: widget.onInsertToolPrompt);
    if (changed == true) _refresh();
  }

  Future<void> _deleteTool(JsToolDefinition tool) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete JS tool'),
        content: Text('Delete "${tool.name}" from your JS tool library?'),
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
    await JsToolLibraryService.instance.deleteTool(tool.id, client);
    _refresh();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Deleted JS tool: ${tool.name}'), behavior: SnackBarBehavior.floating));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('JavaScript Tool Library'),
        leading: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop(_changed)),
        actions: [
          IconButton(
            icon: const Icon(Icons.psychology_outlined),
            tooltip: 'Generate skills for JS tools',
            onPressed: _tools.isEmpty ? null : _generateJsSkills,
          ),
          IconButton(icon: const Icon(Icons.science_outlined), tooltip: 'Load sample tools', onPressed: _loadSamples),
          IconButton(icon: const Icon(Icons.add), tooltip: 'New JS tool', onPressed: () => _openEditor()),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _tools.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.javascript, size: 64, color: Colors.grey[400]),
                  const SizedBox(height: 16),
                  Text('No JS tools yet', style: theme.textTheme.titleMedium?.copyWith(color: Colors.grey[500])),
                  const SizedBox(height: 8),
                  Text(
                    'Create your first generatedTool-based MCP tool.',
                    style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey[400]),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(onPressed: () => _openEditor(), icon: const Icon(Icons.add), label: const Text('Create JS tool')),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _loadSamples,
                    icon: const Icon(Icons.science_outlined, size: 18),
                    label: const Text('Load sample tools'),
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
                    backgroundColor: AppTheme.primaryBlue.withValues(alpha: 0.12),
                    child: const Icon(Icons.javascript, color: AppTheme.primaryBlue, size: 20),
                  ),
                  title: Row(
                    children: [
                      Expanded(
                        child: Text(tool.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                      ),
                      if (!tool.isActive)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(color: Colors.grey.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
                          child: const Text('Disabled', style: TextStyle(fontSize: 11)),
                        ),
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
}

class _JsToolEditorDialog extends ConsumerStatefulWidget {
  const _JsToolEditorDialog({this.existing, this.onInsertToolPrompt});

  final JsToolDefinition? existing;
  final void Function(String toolName)? onInsertToolPrompt;

  static Future<bool?> show(
    BuildContext context, {
    required WidgetRef ref,
    JsToolDefinition? existing,
    void Function(String toolName)? onInsertToolPrompt,
  }) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _JsToolEditorDialog(existing: existing, onInsertToolPrompt: onInsertToolPrompt),
    );
  }

  @override
  ConsumerState<_JsToolEditorDialog> createState() => _JsToolEditorDialogState();
}

class _JsToolEditorDialogState extends ConsumerState<_JsToolEditorDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _descCtrl;
  late final TextEditingController _codeCtrl;
  late final TextEditingController _generatePromptCtrl;
  late final TextEditingController _systemPromptCtrl;
  late final TextEditingController _testArgsCtrl;

  bool _saving = false;
  bool _generating = false;
  bool _testing = false;
  bool _active = true;
  // 'llm1' = global LLM 1, 'llm2' = global LLM 2, 'task' = task LLM
  String _codeLlmChoice = 'llm1';

  String? _validationSummary;
  List<String> _validationErrors = const [];
  List<String> _validationWarnings = const [];

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _nameCtrl = TextEditingController(text: existing?.name ?? '');
    _descCtrl = TextEditingController(text: existing?.description ?? '');
    _codeCtrl = TextEditingController(text: existing?.jsCode ?? _defaultToolTemplate);
    _generatePromptCtrl = TextEditingController(text: existing?.generationPrompt ?? '');
    _systemPromptCtrl = TextEditingController(text: existing?.generationSystemPrompt ?? _defaultGenerationSystemPrompt);
    final savedJsArgs = existing?.testArgs ?? '';
    _testArgsCtrl = TextEditingController(
      text: savedJsArgs.isNotEmpty ? savedJsArgs : _extractJsDefaultArgs(existing?.jsCode ?? _defaultToolTemplate),
    );
    _active = existing?.isActive ?? true;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _codeCtrl.dispose();
    _generatePromptCtrl.dispose();
    _systemPromptCtrl.dispose();
    _testArgsCtrl.dispose();
    super.dispose();
  }

  Future<void> _importFromFile() async {
    final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['js'], withData: true);
    if (picked == null || picked.files.isEmpty) return;
    final file = picked.files.first;

    String? content;
    if (file.bytes != null) {
      content = utf8.decode(file.bytes!, allowMalformed: true);
    } else if (file.path != null) {
      content = await File(file.path!).readAsString();
    }
    if (content == null || content.trim().isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Selected file is empty.')));
      return;
    }

    setState(() {
      _codeCtrl.text = content!;
      if (_nameCtrl.text.trim().isEmpty) {
        _nameCtrl.text = (file.name.split('.').first).trim();
      }
    });
  }

  Future<void> _generateWithAi() async {
    final prompt = _generatePromptCtrl.text.trim();
    if (prompt.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Describe what the JS tool should do.')));
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

    // Fallback: LLM 1 → LLM 2 (LLM2 is disabled in restricted post-trial mode)
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L.of(context).noLlmForScript), backgroundColor: Colors.orange));
      return;
    }

    setState(() => _generating = true);
    try {
      final systemPrompt = _systemPromptCtrl.text.trim().isNotEmpty ? _systemPromptCtrl.text.trim() : _defaultGenerationSystemPrompt;

      final userPrompt =
          'Build a pure JavaScript tool for this task:\n$prompt\n\n'
          'Constraints:\n'
          '- Use ES6 syntax only\n'
          '- No external dependencies\n'
          '- Define exactly one object named generatedTool\n'
          '- Use this exact contract: const generatedTool = { name, description, inputSchema, execute: async (args) => string }\n'
          '- include an explicit JSON schema in inputSchema\n'
          '- handle errors with try/catch and return JSON string with ok:false and error\n'
          '- keep code concise and readable\n'
          '- output only JavaScript code';

      final response = await effectiveLlm.generateChatCompletion(
        messages: [
          ChatMessage(id: const Uuid().v4(), role: ChatRole.system, content: systemPrompt, timestamp: DateTime.now()),
          ChatMessage(id: const Uuid().v4(), role: ChatRole.user, content: userPrompt, timestamp: DateTime.now()),
        ],
        maxTokens: 1800,
      );

      var code = response.content.trim();
      if (code.startsWith('```')) {
        final lines = code.split('\n');
        code = lines.skip(1).where((l) => !l.startsWith('```')).join('\n').trim();
      }

      code = _normalizeGeneratedToolCode(code);

      setState(() {
        _codeCtrl.text = code;
      });
      // Infer test args in background — silent, non-blocking
      _inferJsonTestArgs(code, effectiveLlm, language: 'JavaScript').ignore();

      await _validateCode();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('JS generation failed: $e'), backgroundColor: AppTheme.error));
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  // ─── Sync param extraction (no LLM) ─────────────────────────────────────

  /// Parses the `inputSchema.properties` block and builds a JSON example object.
  static String _extractJsDefaultArgs(String code) {
    const fallback = '{\n  "input": "hello world"\n}';
    // Find the start of the inputSchema object.
    final schemaMatch = RegExp(r'inputSchema\s*:', caseSensitive: false).firstMatch(code);
    if (schemaMatch == null) return fallback;

    // Find "properties :" inside the inputSchema.
    final afterSchema = code.substring(schemaMatch.start);
    final propsMatch = RegExp(r'properties\s*:\s*\{', caseSensitive: false).firstMatch(afterSchema);
    if (propsMatch == null) return fallback;

    // Find the matching closing brace for the properties block.
    final propStart = schemaMatch.start + propsMatch.end;
    int depth = 1;
    int i = propStart;
    while (i < code.length && depth > 0) {
      if (code[i] == '{') {
        depth++;
      } else if (code[i] == '}') {
        depth--;
      }
      i++;
    }
    final propsBlock = code.substring(propStart, i - 1);

    // Each property has the form: name: { ... } or "name": { ... }
    final props = <String, Object?>{};
    final propRe = RegExp(
      r'["'
      "'"
      r']?([A-Za-z_][A-Za-z0-9_]*)["'
      "'"
      r']?\s*:\s*\{([^{}]*)\}',
    );
    for (final m in propRe.allMatches(propsBlock)) {
      final propName = m.group(1)!;
      final propDef = m.group(2)!;

      // Look for an explicit default value.
      final defMatch = RegExp(r"""["']?default["']?\s*:\s*["']?([^,}\n"']+)["']?""", caseSensitive: false).firstMatch(propDef);
      if (defMatch != null) {
        final rawDef = defMatch.group(1)!.trim();
        props[propName] =
            num.tryParse(rawDef) ??
            (rawDef == 'true'
                ? true
                : rawDef == 'false'
                ? false
                : rawDef);
        continue;
      }

      // Fall back to a type-based placeholder.
      final typeMatch = RegExp(
        r'["'
        "'"
        r']?type["'
        "'"
        r']?\s*:\s*["'
        "'"
        r']([^"'
        "'"
        r']+)["'
        "'"
        r']',
      ).firstMatch(propDef);
      switch (typeMatch?.group(1)) {
        case 'integer':
          props[propName] = 0;
        case 'number':
          props[propName] = 0;
        case 'boolean':
          props[propName] = false;
        case 'array':
          props[propName] = <dynamic>[];
        default:
          props[propName] = '';
      }
    }

    if (props.isEmpty) return fallback;
    return const JsonEncoder.withIndent('  ').convert(props);
  }

  // ─── Infer test args ────────────────────────────────────────────────────

  Future<void> _inferJsonTestArgs(String code, LLMService llm, {String language = 'JavaScript'}) async {
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
                'Analyze this $language tool\'s inputSchema and execute function and return ONLY a compact JSON object with '
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

  String _normalizeGeneratedToolCode(String code) {
    var normalized = code.trim();

    if (normalized.startsWith('```')) {
      final lines = normalized.split('\n');
      normalized = lines.skip(1).where((l) => !l.startsWith('```')).join('\n').trim();
    }

    normalized = normalized.replaceAll(RegExp(r'^\s*export\s+default\s+', multiLine: true), '');
    normalized = normalized.replaceAll(RegExp(r'^\s*export\s+', multiLine: true), '');

    if (!RegExp(r'\bgeneratedTool\b').hasMatch(normalized)) {
      final objectDecl = RegExp(r'\b(const|let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\{', multiLine: true);
      final match = objectDecl.firstMatch(normalized);
      if (match != null) {
        final variableName = match.group(2)!;
        normalized = normalized.replaceFirst(RegExp('\\b$variableName\\b'), 'generatedTool');
      }
    }

    return normalized;
  }

  Future<void> _validateCode() async {
    final validation = await JsToolRuntimeService.instance.validateToolCode(_codeCtrl.text);

    setState(() {
      _validationErrors = validation.errors;
      _validationWarnings = validation.warnings;
      _validationSummary = validation.valid
          ? 'Valid generatedTool ${validation.runtimeAvailable ? '(sandbox checked)' : '(static checks only)'}'
          : 'Validation failed';
      if (validation.valid) {
        if (_nameCtrl.text.trim().isEmpty && validation.toolName != null && validation.toolName!.isNotEmpty) {
          _nameCtrl.text = validation.toolName!;
        }
        if (_descCtrl.text.trim().isEmpty && validation.description != null && validation.description!.isNotEmpty) {
          _descCtrl.text = validation.description!;
        }
      }
    });
  }

  Future<void> _runSandboxTest() async {
    final toolName = _nameCtrl.text.trim();

    // Pre-fill with LLM-inferred or manually saved args.
    final argsCtrl = TextEditingController(text: _testArgsCtrl.text.trim());

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Sandbox Test${toolName.isNotEmpty ? ": $toolName" : ""}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Parameters (JSON object):',
              style: Theme.of(ctx).textTheme.bodySmall?.copyWith(color: Theme.of(ctx).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: argsCtrl,
              minLines: 3,
              maxLines: 6,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(hintText: '{"input": "hello world"}', border: OutlineInputBorder()),
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

    Map<String, dynamic> args;
    try {
      final parsed = jsonDecode(argsStr.isEmpty ? '{}' : argsStr);
      if (parsed is! Map<String, dynamic>) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Test args must be a JSON object.')));
        return;
      }
      args = parsed;
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Invalid JSON in test args.')));
      return;
    }

    setState(() => _testing = true);
    final result = await JsToolRuntimeService.instance.testExecute(jsCode: _codeCtrl.text, args: args, timeoutMs: 8000);
    if (!mounted) return;
    setState(() => _testing = false);

    _showTestOutputDialog(context, result);
  }

  void _showTestOutputDialog(BuildContext context, dynamic result) {
    final toolName = _nameCtrl.text.trim();
    final isSuccess = result.success == true;
    final error = result.error as String?;
    final output = result.result;
    final logs = result.logs as List<dynamic>? ?? const [];
    final durationMs = result.durationMs as int?;

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
                                ? 'Sandbox Test${toolName.isNotEmpty ? ": $toolName" : ""} — Success${durationMs != null ? " (${durationMs}ms)" : ""}'
                                : 'Sandbox Test${toolName.isNotEmpty ? ": $toolName" : ""} — Failed',
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
                            _JsOutputBox(text: error ?? ''),
                          ] else ...[
                            const Text('Output:', style: TextStyle(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 4),
                            _JsOutputBox(text: output is String ? output : const JsonEncoder.withIndent('  ').convert(output)),
                          ],
                          if (logs.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            const Text('Console logs:', style: TextStyle(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 4),
                            _JsOutputBox(text: logs.join('\n')),
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

  Future<void> _save() async {
    if (_nameCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Tool name is required.')));
      return;
    }

    setState(() => _saving = true);
    try {
      final validation = await JsToolRuntimeService.instance.validateToolCode(_codeCtrl.text);
      if (!validation.valid) {
        setState(() {
          _validationErrors = validation.errors;
          _validationWarnings = validation.warnings;
          _validationSummary = 'Validation failed';
        });
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Fix validation errors before saving.')));
        return;
      }

      final schema = validation.inputSchema ?? <String, dynamic>{'type': 'object', 'properties': {}};
      // User's explicit edits in the name/description fields always take precedence;
      // fall back to what the JS code declares only if the fields are empty.
      final normalizedName = _nameCtrl.text.trim().isNotEmpty ? _nameCtrl.text.trim() : (validation.toolName?.trim() ?? '');
      final normalizedDesc = _descCtrl.text.trim().isNotEmpty ? _descCtrl.text.trim() : (validation.description?.trim() ?? '');

      final genPrompt = _generatePromptCtrl.text.trim();
      final client = (ref.read(serverModeProvider).value?.isRemote ?? false)
          ? ref.read(serverApiClientProvider)
          : null;
      if (widget.existing != null) {
        await JsToolLibraryService.instance.updateTool(
          widget.existing!.copyWith(
            name: normalizedName,
            description: normalizedDesc,
            inputSchema: schema,
            jsCode: _codeCtrl.text,
            generationSystemPrompt: _systemPromptCtrl.text.trim(),
            isActive: _active,
            cron: widget.existing!.cron,
            cronHint: widget.existing!.cronHint,
            generationPrompt: genPrompt.isNotEmpty ? genPrompt : null,
            testArgs: _testArgsCtrl.text.trim(),
          ),
          client,
        );
      } else {
        await JsToolLibraryService.instance.addTool(
          name: normalizedName,
          description: normalizedDesc,
          inputSchema: schema,
          jsCode: _codeCtrl.text,
          generationSystemPrompt: _systemPromptCtrl.text.trim(),
          isActive: _active,
          cron: '',
          cronHint: '',
          generationPrompt: genPrompt,
          testArgs: _testArgsCtrl.text.trim(),
          client: client,
        );
      }

      if (mounted) Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.existing == null;
    final screenSize = MediaQuery.of(context).size;
    final isMobile = screenSize.width < 600;

    final body = Column(
      mainAxisSize: isMobile ? MainAxisSize.max : MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
          child: Row(
            children: [
              const Icon(Icons.javascript, color: AppTheme.primaryBlue),
              const SizedBox(width: 12),
              Text(isNew ? 'New JS Tool' : 'Edit JS Tool', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
              const Spacer(),
              IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop(false)),
            ],
          ),
        ),
        const Divider(height: 1),
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
                  subtitle: const Text('Disabled tools are stored but not exposed to MCP runtime.'),
                  value: _active,
                  onChanged: (value) => setState(() => _active = value),
                ),
                const SizedBox(height: 12),
                Card(
                  color: AppTheme.primaryBlue.withValues(alpha: 0.06),
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
                                'Describe the inputs and the expected output. Example: "Accept a city name and return its latitude, longitude and country from a geocoding API."',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 8),
                        const SizedBox(height: 8),
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
                        Row(
                          children: [
                            FilledButton.icon(
                              onPressed: _generating ? null : _generateWithAi,
                              icon: _generating
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                    )
                                  : const Icon(Icons.auto_awesome, size: 16),
                              label: const Text('Generate'),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton.icon(
                              onPressed: _importFromFile,
                              icon: const Icon(Icons.upload_file, size: 16),
                              label: const Text('Import .js'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Text('JavaScript Code', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                CodeEditorField(controller: _codeCtrl, language: 'js', title: 'JavaScript Code', previewLines: 18),
                const SizedBox(height: 10),
                Row(
                  children: [
                    OutlinedButton.icon(onPressed: _validateCode, icon: const Icon(Icons.rule, size: 16), label: const Text('Validate')),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: _testing ? null : _runSandboxTest,
                      icon: _testing
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.play_arrow, size: 16),
                      label: const Text('Sandbox Test'),
                    ),
                  ],
                ),
                if (_validationSummary != null) ...[
                  const SizedBox(height: 8),
                  Text(_validationSummary!, style: TextStyle(color: _validationErrors.isEmpty ? Colors.green : AppTheme.error)),
                ],
                if (_validationErrors.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  ..._validationErrors.map((e) => Text('• $e', style: const TextStyle(color: AppTheme.error, fontSize: 12))),
                ],
                if (_validationWarnings.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  ..._validationWarnings.map((w) => Text('• $w', style: const TextStyle(color: Colors.orange, fontSize: 12))),
                ],
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
                        const SnackBar(content: Text('Inserted JS tool call hint into prompt.'), behavior: SnackBarBehavior.floating),
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
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(L.of(context).cancel)),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.save),
                label: Text(isNew ? 'Create JS Tool' : L.of(context).save),
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

  static const String _defaultToolTemplate = '''const generatedTool = {
  name: "example_tool",
  description: "Example generated tool",
  inputSchema: {
    type: "object",
    properties: {
      input: { type: "string", description: "Input text" }
    },
    required: ["input"]
  },
  execute: async (args) => {
    try {
      const input = String(args?.input ?? "");
      return JSON.stringify({ ok: true, echoed: input });
    } catch (error) {
      return JSON.stringify({ ok: false, error: String(error?.message || error) });
    }
  }
};
''';

  static const String _defaultGenerationSystemPrompt =
      'You are a JavaScript MCP tool generator. Produce production-safe, dependency-free JavaScript only. '
      'Return ONLY code, no markdown fences. '
      'Your output must define exactly one object named generatedTool with shape: '
      'const generatedTool = { name, description, inputSchema, execute: async (args) => string }; '
      'No imports, no require, no process, no fs. '
      'Use standard JavaScript APIs — use fetch when REST calls are needed. '
      'execute(args) must return a JSON string via JSON.stringify(...) or a plain string.';
}

class _JsOutputBox extends StatelessWidget {
  const _JsOutputBox({required this.text});
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
