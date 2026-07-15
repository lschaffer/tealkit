import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'app_logger.dart';

// ═══════════════════════════════════════════════════════════════
// Model
// ═══════════════════════════════════════════════════════════════

class LocalShellScript {
  final String id;
  final String name;
  final String description;
  final String content;
  final String generationSystemPrompt;
  final String generationPrompt;
  final DateTime createdAt;
  final DateTime updatedAt;

  const LocalShellScript({
    required this.id,
    required this.name,
    required this.description,
    required this.content,
    required this.generationSystemPrompt,
    required this.generationPrompt,
    required this.createdAt,
    required this.updatedAt,
  });

  factory LocalShellScript.create({
    required String name,
    required String description,
    required String content,
    String generationSystemPrompt = '',
    String generationPrompt = '',
  }) {
    final now = DateTime.now();
    return LocalShellScript(
      id: const Uuid().v4(),
      name: name,
      description: description,
      content: content,
      generationSystemPrompt: generationSystemPrompt,
      generationPrompt: generationPrompt,
      createdAt: now,
      updatedAt: now,
    );
  }

  LocalShellScript copyWith({
    String? name,
    String? description,
    String? content,
    String? generationSystemPrompt,
    String? generationPrompt,
  }) {
    return LocalShellScript(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      content: content ?? this.content,
      generationSystemPrompt: generationSystemPrompt ?? this.generationSystemPrompt,
      generationPrompt: generationPrompt ?? this.generationPrompt,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'content': content,
    'generationSystemPrompt': generationSystemPrompt,
    'generationPrompt': generationPrompt,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory LocalShellScript.fromJson(Map<String, dynamic> json) => LocalShellScript(
    id: json['id'] as String? ?? const Uuid().v4(),
    name: json['name'] as String? ?? '',
    description: json['description'] as String? ?? '',
    content: json['content'] as String? ?? '',
    generationSystemPrompt: json['generationSystemPrompt'] as String? ?? '',
    generationPrompt: json['generationPrompt'] as String? ?? '',
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
    updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? DateTime.now(),
  );
}

// ═══════════════════════════════════════════════════════════════
// Service
// ═══════════════════════════════════════════════════════════════

class LocalShellScriptService {
  LocalShellScriptService._();
  static final LocalShellScriptService instance = LocalShellScriptService._();

  static const _kScripts = 'local_shell_script_library_scripts';

  List<LocalShellScript> _scripts = [];

  List<LocalShellScript> get scripts {
    final sorted = List<LocalShellScript>.from(_scripts);
    sorted.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return List.unmodifiable(sorted);
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kScripts);
      if (raw == null || raw.isEmpty) return;
      final list = jsonDecode(raw) as List<dynamic>;
      _scripts = list.whereType<Map<String, dynamic>>().map(LocalShellScript.fromJson).toList();
      log.info('[LocalShellScriptLibrary] Loaded ${_scripts.length} scripts');
    } catch (e) {
      log.error('[LocalShellScriptLibrary] Failed to load: $e');
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kScripts, jsonEncode(_scripts.map((s) => s.toJson()).toList()));
  }

  Future<LocalShellScript> addScript({
    required String name,
    required String description,
    required String content,
    String generationSystemPrompt = '',
    String generationPrompt = '',
  }) async {
    final script = LocalShellScript.create(
      name: name,
      description: description,
      content: content,
      generationSystemPrompt: generationSystemPrompt,
      generationPrompt: generationPrompt,
    );
    _scripts.add(script);
    await _persist();
    log.info('[LocalShellScriptLibrary] Added: ${script.name}');
    return script;
  }

  Future<void> updateScript(LocalShellScript updated) async {
    final idx = _scripts.indexWhere((s) => s.id == updated.id);
    if (idx < 0) {
      log.warning('[LocalShellScriptLibrary] updateScript – id not found: ${updated.id}');
      return;
    }
    _scripts[idx] = updated;
    await _persist();
    log.info('[LocalShellScriptLibrary] Updated: ${updated.name}');
  }

  Future<void> deleteScript(String id) async {
    _scripts.removeWhere((s) => s.id == id);
    await _persist();
    log.info('[LocalShellScriptLibrary] Deleted: $id');
  }

  LocalShellScript? findById(String id) {
    try {
      return _scripts.firstWhere((s) => s.id == id);
    } catch (_) {
      return null;
    }
  }

  List<Map<String, dynamic>> exportToJson() => _scripts.map((s) => s.toJson()).toList();

  Future<int> importFromJson(List<dynamic> list) async {
    int count = 0;
    for (final item in list) {
      if (item is! Map<String, dynamic>) continue;
      try {
        final script = LocalShellScript.fromJson(item);
        final idx = _scripts.indexWhere((s) => s.id == script.id || s.name == script.name);
        if (idx >= 0) {
          _scripts[idx] = script;
        } else {
          _scripts.add(script);
        }
        count++;
      } catch (e) {
        log.warning('[LocalShellScriptLibrary] Skipped during import: $e');
      }
    }
    if (count > 0) await _persist();
    return count;
  }

  // ─────────────────────────────────────────────────────────────
  // Execution
  // ─────────────────────────────────────────────────────────────

  /// Run a saved [script] as a temporary bash script on the local machine.
  /// Only available on Linux and macOS.
  Future<Map<String, dynamic>> runScript(LocalShellScript script, {String args = '', int timeoutSeconds = 120}) {
    return runContent(script.content, args: args, timeoutSeconds: timeoutSeconds, scriptId: script.id, scriptName: script.name);
  }

  /// Write [content] to a temp file and execute it as a bash script locally.
  /// Only available on Linux and macOS.
  static Future<Map<String, dynamic>> runContent(
    String content, {
    String args = '',
    int timeoutSeconds = 60,
    String scriptId = '',
    String scriptName = '',
  }) async {
    if (!Platform.isLinux && !Platform.isMacOS) {
      return {'error': 'Local shell execution is only supported on Linux and macOS.'};
    }
    File? tempFile;
    Directory? tempDir;
    try {
      tempDir = await Directory.systemTemp.createTemp('tealkit_local_');
      final suffix = scriptId.isNotEmpty ? scriptId.replaceAll('-', '').substring(0, 12) : 'test';
      tempFile = File('${tempDir.path}${Platform.pathSeparator}$suffix.sh');
      await tempFile.writeAsString(content);

      final chmod = await Process.run('chmod', ['+x', tempFile.path]);
      if (chmod.exitCode != 0) {
        return {'error': 'chmod failed (exit ${chmod.exitCode})', 'stderr': chmod.stderr.toString()};
      }

      final argList = _splitArgs(args);
      final proc = await Process.run(
        '/bin/bash',
        [tempFile.path, ...argList],
        runInShell: false,
      ).timeout(Duration(seconds: timeoutSeconds), onTimeout: () => throw TimeoutException('Script timed out after ${timeoutSeconds}s'));

      log.info('[LocalShellScriptLibrary] Executed script "$scriptName" – exit ${proc.exitCode}');
      return {
        if (scriptId.isNotEmpty) 'scriptId': scriptId,
        if (scriptName.isNotEmpty) 'scriptName': scriptName,
        'exitCode': proc.exitCode,
        'stdout': proc.stdout.toString(),
        'stderr': proc.stderr.toString(),
        'success': proc.exitCode == 0,
        'argsUsed': args,
        'executionMode': 'local',
      };
    } catch (e) {
      log.error('[LocalShellScriptLibrary] Execution failed: $e');
      return {'error': 'Local script execution failed: $e'};
    } finally {
      try {
        if (tempFile != null && tempFile.existsSync()) await tempFile.delete();
        if (tempDir != null && tempDir.existsSync()) await tempDir.delete();
      } catch (_) {}
    }
  }

  /// Split a space-separated args string honouring single/double quotes.
  static List<String> _splitArgs(String args) {
    if (args.trim().isEmpty) return [];
    final result = <String>[];
    final buf = StringBuffer();
    String? quote;
    for (var i = 0; i < args.length; i++) {
      final c = args[i];
      if (quote != null) {
        if (c == quote) {
          quote = null;
        } else {
          buf.write(c);
        }
      } else if (c == '"' || c == "'") {
        quote = c;
      } else if (c == ' ' || c == '\t') {
        if (buf.isNotEmpty) {
          result.add(buf.toString());
          buf.clear();
        }
      } else {
        buf.write(c);
      }
    }
    if (buf.isNotEmpty) result.add(buf.toString());
    return result;
  }
}
