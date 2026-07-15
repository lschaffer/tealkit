// ignore_for_file: use_build_context_synchronously

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/app_localizations.dart';
import 'package:uuid/uuid.dart';

import '../config/app_theme.dart';
import '../models/mcp_models.dart';
import '../providers/llm_settings_provider.dart';
import '../services/app_logger.dart';
import '../services/llm_service.dart';
import '../services/powershell_script_service.dart';
import '../services/task_runner_service.dart';

// ═══════════════════════════════════════════════════════════════
// PowerShell Script Library Screen  — Windows only
// ═══════════════════════════════════════════════════════════════

class PowershellToolLibraryScreen extends ConsumerStatefulWidget {
  const PowershellToolLibraryScreen({super.key});

  /// Push the screen. Guard with Platform.isWindows at the call site.
  static Future<bool?> show(BuildContext context) {
    return Navigator.of(context).push<bool>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const PowershellToolLibraryScreen()));
  }

  @override
  ConsumerState<PowershellToolLibraryScreen> createState() => _PowershellToolLibraryScreenState();
}

class _PowershellToolLibraryScreenState extends ConsumerState<PowershellToolLibraryScreen> {
  bool _loading = true;
  List<PowershellScript> _scripts = [];
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await PowershellScriptService.instance.load();
    if (!mounted) return;
    setState(() {
      _scripts = List.from(PowershellScriptService.instance.scripts);
      _loading = false;
    });
  }

  void _refresh() {
    setState(() {
      _scripts = List.from(PowershellScriptService.instance.scripts);
      _changed = true;
    });
  }

  Future<void> _openEditor({PowershellScript? existing}) async {
    final result = await _PowershellEditorDialog.show(context, ref: ref, existing: existing);
    if (result == true) _refresh();
  }

  Future<void> _deleteScript(PowershellScript script) async {
    final l = L.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.psDeleteScriptTitle),
        content: Text(l.psDeleteScriptConfirm(script.name)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.cancel)),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.delete, style: const TextStyle(color: AppTheme.error)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await PowershellScriptService.instance.deleteScript(script.id);
    _refresh();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(L.of(context).psScriptDeleted(script.name)), behavior: SnackBarBehavior.floating));
    }
  }

  Future<void> _loadSamples() async {
    final svc = PowershellScriptService.instance;
    final samples = [
      (
        name: 'Windows System Info',
        description: 'Displays OS version, build, CPU, RAM, hostname and username.',
        content:
            r'''
# Windows System Information
$os  = Get-WmiObject Win32_OperatingSystem
$cpu = Get-WmiObject Win32_Processor | Select-Object -First 1
$ram = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)

Write-Host "=== Windows System Information ===" -ForegroundColor Cyan
Write-Host "OS:       $($os.Caption) (Build $($os.BuildNumber))"
Write-Host "Version:  $($os.Version)"
Write-Host "CPU:      $($cpu.Name)"
Write-Host "RAM:      $ram GB"
Write-Host "Hostname: $env:COMPUTERNAME"
Write-Host "User:     $env:USERNAME"
'''
                .trim(),
      ),
      (
        name: 'Last Windows Updates',
        description: 'Shows the 5 most recently installed Windows updates.',
        content:
            r'''
# Last installed Windows Updates
$session  = New-Object -ComObject Microsoft.Update.Session
$searcher = $session.CreateUpdateSearcher()
$history  = $searcher.QueryHistory(0, 20)

Write-Host "=== Last Windows Updates ===" -ForegroundColor Cyan
$history |
  Where-Object { $_.ResultCode -eq 2 } |
  Select-Object -First 5 |
  ForEach-Object {
    $date = $_.Date.ToString("yyyy-MM-dd HH:mm")
    Write-Host "$date  $($_.Title)"
  }
'''
                .trim(),
      ),
      (
        name: 'Fetch Website Status',
        description: 'HTTP GET a URL and print status code, content-type, page title and size.',
        content:
            r'''
# Fetch a website and display status + metadata
param(
    [string]$Url = "https://www.example.com"
)

# Ensure the URL has a scheme
if ($Url -notmatch '^https?://') { $Url = "https://$Url" }

try {
    $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 10
    Write-Host "URL:          $Url"
    Write-Host "Status:       $($r.StatusCode) $($r.StatusDescription)"
    Write-Host "Content-Type: $($r.Headers["Content-Type"])"
    if ($r.Content -match "<title[^>]*>([^<]+)</title>") {
        Write-Host "Title:        $($Matches[1].Trim())"
    }
    Write-Host "Size:         $([math]::Round($r.RawContentLength / 1KB, 1)) KB"
} catch {
    Write-Host "Error: $_" -ForegroundColor Red
}
'''
                .trim(),
      ),
    ];

    final existingNames = _scripts.map((s) => s.name).toSet();
    int added = 0;
    for (final s in samples) {
      if (existingNames.contains(s.name)) continue;
      await svc.addScript(name: s.name, description: s.description, content: s.content);
      added++;
    }
    _refresh();
    if (mounted) {
      final msg = added == 0 ? 'All sample scripts already exist.' : L.of(context).psSamplesLoadedMsg(added);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = L.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l.psScriptLibraryTitle),
        leading: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop(_changed)),
        actions: [
          IconButton(icon: const Icon(Icons.science_outlined), tooltip: l.psLoadSamplesTooltip, onPressed: _loadSamples),
          IconButton(icon: const Icon(Icons.add), tooltip: l.psNewScriptTooltip, onPressed: () => _openEditor()),
        ],
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
                  Text(l.psNoScriptsYet, style: theme.textTheme.titleMedium?.copyWith(color: Colors.grey[500])),
                  const SizedBox(height: 8),
                  Text(l.psCreateFirstScriptHint, style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey[400])),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _loadSamples,
                        icon: const Icon(Icons.science_outlined, size: 18),
                        label: Text(l.psLoadSamplesTooltip),
                      ),
                      const SizedBox(width: 12),
                      FilledButton.icon(onPressed: () => _openEditor(), icon: const Icon(Icons.add), label: Text(l.psCreateScriptButton)),
                    ],
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
                    backgroundColor: Colors.blue.withValues(alpha: 0.12),
                    child: const Icon(Icons.terminal, color: Colors.blue, size: 20),
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
                        tooltip: l.editScriptTooltip,
                        onPressed: () => _openEditor(existing: s),
                      ),
                      IconButton(
                        icon: Icon(Icons.delete_outline, color: AppTheme.error),
                        tooltip: l.deleteScriptTooltip,
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
// PowerShell Editor Dialog
// ═══════════════════════════════════════════════════════════════

class _PowershellEditorDialog extends ConsumerStatefulWidget {
  const _PowershellEditorDialog({this.existing});

  final PowershellScript? existing;

  static Future<bool?> show(BuildContext context, {required WidgetRef ref, PowershellScript? existing}) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PowershellEditorDialog(existing: existing),
    );
  }

  @override
  ConsumerState<_PowershellEditorDialog> createState() => _PowershellEditorDialogState();
}

class _PowershellEditorDialogState extends ConsumerState<_PowershellEditorDialog> {
  static const _defaultGenerationSystemPrompt =
      'You are an expert Windows PowerShell scripting assistant. '
      'Generate clean, production-quality PowerShell scripts with correct syntax. '
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
  String _suggestedTestArgs = '';

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
    // Pre-fill test args from the param() block so the user sees the syntax.
    _suggestedTestArgs = _extractDefaultPsArgs(s?.content ?? '');
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
    final l = L.of(context);
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.psScriptNameRequired), backgroundColor: Colors.orange));
      return;
    }
    setState(() => _saving = true);
    try {
      final svc = PowershellScriptService.instance;
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.psSaveFailed(e.toString())), backgroundColor: AppTheme.error));
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L.of(context).psNoLlmConfigured), backgroundColor: Colors.orange));
      return;
    }

    setState(() => _generating = true);
    try {
      final metaPrompt =
          'Generate a Windows PowerShell script that does the following:\n\n$prompt\n\n'
          'Rules:\n'
          '- Output ONLY the PowerShell script code\n'
          '- Use proper error handling (try/catch or -ErrorAction Stop)\n'
          '- Do NOT include markdown code fences\n'
          '- Keep the script concise and readable';

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
      log.error('[PowershellLibrary] LLM generation failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(L.of(context).psGenerationFailed(e.toString())), backgroundColor: AppTheme.error));
      }
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  // ─── Sync param extraction (no LLM) ─────────────────────────────────────

  /// Parses the `param()` block and returns a PS argument string like:
  /// `-Folder 'C:\Temp' -Months 12`
  static String _extractDefaultPsArgs(String content) {
    if (content.isEmpty) return '';
    final lc = content.toLowerCase();
    final paramIdx = lc.indexOf('param');
    if (paramIdx < 0) return '';
    final openParen = content.indexOf('(', paramIdx);
    if (openParen < 0) return '';

    // Find the matching closing paren for the full param() block.
    int depth = 0;
    int i = openParen;
    while (i < content.length) {
      if (content[i] == '(') {
        depth++;
      } else if (content[i] == ')') {
        depth--;
        if (depth == 0) break;
      }
      i++;
    }
    final paramBlock = content.substring(openParen + 1, i);

    // Split on top-level commas (ignore commas inside nested () or []).
    final rawParams = <String>[];
    int parenDepth = 0;
    int start = 0;
    for (int j = 0; j < paramBlock.length; j++) {
      final ch = paramBlock[j];
      if (ch == '(' || ch == '[') {
        parenDepth++;
      } else if (ch == ')' || ch == ']') {
        parenDepth--;
      } else if (ch == ',' && parenDepth == 0) {
        rawParams.add(paramBlock.substring(start, j));
        start = j + 1;
      }
    }
    rawParams.add(paramBlock.substring(start));

    final parts = <String>[];
    for (final raw in rawParams) {
      final p = raw.trim();
      if (p.isEmpty) continue;

      // Extract the variable name (last $Name in the declaration).
      final nameMatch = RegExp(r'\$([A-Za-z][A-Za-z0-9_]*)').firstMatch(p);
      if (nameMatch == null) continue;
      final name = nameMatch.group(1)!;

      // Skip [switch] params — they are just flags and default to $false.
      final lcP = p.toLowerCase();
      if (lcP.contains('[switch]') || lcP.contains('[switchparameter]')) continue;

      // Extract the default value (everything after `=` up to end-of-line or comment).
      final defMatch = RegExp(r'\$[A-Za-z][A-Za-z0-9_]*\s*=\s*(.+?)(?:\s*#.*)?$', multiLine: true).firstMatch(p);
      if (defMatch != null) {
        var defStr = defMatch.group(1)!.trim().replaceAll(RegExp(r',\s*$'), '').trim();
        if (defStr.startsWith('"') || defStr.startsWith("'")) {
          // String literal — unwrap and re-wrap with single quotes.
          final unquoted = defStr.replaceAll(RegExp(r'''^["']|["']$'''), '');
          parts.add("-$name '$unquoted'");
        } else {
          parts.add('-$name $defStr');
        }
      } else {
        // No default — emit a type-appropriate placeholder.
        final typeMatch = RegExp(r'\[([A-Za-z][A-Za-z0-9.]*)\]\s*\$$name', caseSensitive: false).firstMatch(p);
        final psType = typeMatch?.group(1)?.toLowerCase();
        switch (psType) {
          case 'int':
          case 'int32':
          case 'long':
            parts.add('-$name 0');
          case 'bool':
          case 'boolean':
            parts.add('-$name \$false');
          default:
            parts.add('-$name ""');
        }
      }
    }
    return parts.join(' ');
  }

  Future<void> _testRun() async {
    final l = L.of(context);
    final content = _contentCtrl.text.trim();
    if (content.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.psNoScriptContent), backgroundColor: Colors.orange));
      return;
    }

    // Only available on Windows (enforced at screen level but double-check)
    if (kIsWeb || !Platform.isWindows) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.psWindowsOnlyTest), backgroundColor: Colors.orange));
      return;
    }

    final scriptName = _nameCtrl.text.trim();
    // Always re-extract from the current editor content so a newly generated
    // script gets its defaults even before the first save/reopen.
    final liveArgs = _extractDefaultPsArgs(content);
    if (liveArgs.isNotEmpty) _suggestedTestArgs = liveArgs;
    final argsCtrl = TextEditingController(text: _suggestedTestArgs);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${l.psTestRunTitle}${scriptName.isNotEmpty ? ": $scriptName" : ""}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.psTestRunParams, style: Theme.of(ctx).textTheme.bodySmall?.copyWith(color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            TextField(
              controller: argsCtrl,
              decoration: const InputDecoration(hintText: 'e.g. -Verbose -Path C:\\temp', border: OutlineInputBorder()),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.cancel)),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.play_arrow, size: 18),
            label: Text(l.psTestRunTitle),
            style: FilledButton.styleFrom(backgroundColor: AppTheme.primaryBlue),
          ),
        ],
      ),
    );
    final argsStr = argsCtrl.text.trim();
    Future.delayed(const Duration(milliseconds: 500), argsCtrl.dispose);
    if (confirmed != true || !mounted) return;

    setState(() => _testing = true);
    Map<String, dynamic> result;
    Directory? tempDir;
    Process? process;
    try {
      // Write script to temp .ps1 file as-is so that [CmdletBinding()]/param()
      // remain on line 1 (PowerShell requires them before any executable code).
      tempDir = await Directory.systemTemp.createTemp('ps_test_');
      final tempFile = File('${tempDir.path}\\test.ps1');
      await tempFile.writeAsString(content, encoding: utf8);

      // Set UTF-8 encoding via -Command wrapper, then call the script file so
      // that any param() block receives arguments correctly.
      final escapedPath = tempFile.path.replaceAll("'", "''");
      final callCmd = "& '$escapedPath'${argsStr.isNotEmpty ? ' $argsStr' : ''}";
      final fullCmd =
          '[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; '
          '\$OutputEncoding=[System.Text.Encoding]::UTF8; '
          '$callCmd';

      final psArgs = <String>['-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', fullCmd];

      log.info('[PS Test Run] Starting: powershell.exe ${psArgs.join(' ')}');

      // Use Process.start so we can close stdin immediately (prevents PowerShell
      // from hanging when mandatory parameters are missing — it would otherwise
      // wait for interactive input forever).
      process = await Process.start('powershell.exe', psArgs, runInShell: false);
      await process.stdin.close();

      final stdoutBuf = StringBuffer();
      final stderrBuf = StringBuffer();

      // Use .listen() (not .forEach()) so we never await stream completion —
      // on Windows, stdout/stderr pipes may not signal close until after
      // exitCode resolves, causing Forever.wait() to hang even after process exit.
      final stdoutSub = process.stdout.transform(utf8.decoder).listen(stdoutBuf.write);
      final stderrSub = process.stderr.transform(utf8.decoder).listen(stderrBuf.write);

      const timeoutSeconds = 120;
      int? exitCode;
      try {
        exitCode = await process.exitCode.timeout(const Duration(seconds: timeoutSeconds));
        // Brief drain: let any bytes still in the pipe buffer reach the listeners.
        await Future<void>.delayed(const Duration(milliseconds: 150));
        log.info('[PS Test Run] Completed with exit code $exitCode');
        result = {'stdout': stdoutBuf.toString(), 'stderr': stderrBuf.toString(), 'exitCode': exitCode};
      } on TimeoutException {
        log.warning('[PS Test Run] Timed out after ${timeoutSeconds}s — killing process');
        process.kill();
        result = {'error': 'Script timed out after ${timeoutSeconds}s', 'isTimeout': true};
      } finally {
        await stdoutSub.cancel();
        await stderrSub.cancel();
        tempDir.delete(recursive: true).catchError((_) => Directory(''));
      }
    } catch (e) {
      log.error('[PS Test Run] Error: $e');
      result = {'error': e.toString()};
    } finally {
      process = null;
      if (mounted) setState(() => _testing = false);
    }

    if (!mounted) return;
    _showTestOutputDialog(context, result);
  }

  void _showTestOutputDialog(BuildContext context, Map<String, dynamic> result) {
    final l = L.of(context);
    final isError = result.containsKey('error');
    final stdout = result['stdout'] as String? ?? '';
    final stderr = result['stderr'] as String? ?? '';
    final exitCode = result['exitCode'] as int?;
    final error = result['error'] as String?;
    final isTimeout = result['isTimeout'] == true;

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
                          isError ? Icons.error_outline : (exitCode == 0 ? Icons.check_circle_outline : Icons.warning_amber_outlined),
                          color: isError || (exitCode != null && exitCode != 0) ? AppTheme.error : Colors.green,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            isError ? l.psTestRunFailed : l.psTestOutput(exitCode ?? 0),
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
                          if (isError) ...[
                            Text(
                              'Error:',
                              style: TextStyle(color: AppTheme.error, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 4),
                            _OutputBox(text: error ?? ''),
                            if (isTimeout) ...[
                              const SizedBox(height: 12),
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: Colors.orange.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.tips_and_updates_outlined, color: Colors.orange, size: 18),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        'No output in 120 seconds. Try regenerating the script with AI to fix any issues.',
                                        style: TextStyle(color: Colors.orange.shade800, fontSize: 13),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ] else ...[
                            if (stdout.isNotEmpty) ...[
                              const Text('stdout:', style: TextStyle(fontWeight: FontWeight.bold)),
                              const SizedBox(height: 4),
                              _OutputBox(text: stdout),
                              if (stderr.isNotEmpty) const SizedBox(height: 12),
                            ],
                            if (stderr.isNotEmpty) ...[
                              Text(
                                'stderr:',
                                style: TextStyle(color: AppTheme.error, fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 4),
                              _OutputBox(text: stderr),
                            ],
                            if (stdout.isEmpty && stderr.isEmpty) const Text('(no output)', style: TextStyle(color: Colors.grey)),
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
                      children: [FilledButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(l.close))],
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

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
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
              const Icon(Icons.terminal, color: Colors.blue),
              const SizedBox(width: 12),
              Text(
                isNew ? l.psNewScriptDialogTitle : l.psEditScriptDialogTitle,
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
                  color: Colors.blue.withValues(alpha: 0.06),
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
                            hintText: 'e.g. "List all services that are stopped and export to CSV"',
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
                          style: FilledButton.styleFrom(backgroundColor: Colors.blue),
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
                const Text('PowerShell Code', style: TextStyle(fontWeight: FontWeight.w600)),
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
                      hintText: '# Write your PowerShell script here\nWrite-Host "Hello from PowerShell!"',
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
                      onPressed: _testing ? null : _testRun,
                      icon: _testing
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.play_arrow, size: 16),
                      label: Text(l.psTestRunTitle),
                    ),
                    const SizedBox(width: 12),
                    Text(l.psRunsLocally, style: TextStyle(fontSize: 11, color: Colors.grey[500])),
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
                style: FilledButton.styleFrom(backgroundColor: Colors.blue),
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.save),
                label: Text(isNew ? l.psCreateScriptButton : l.save),
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

// ─────────────────────────────────────────────────────────────────────────────

class _OutputBox extends StatelessWidget {
  const _OutputBox({required this.text});
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
