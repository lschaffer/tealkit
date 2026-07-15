import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'app_logger.dart';
import 'server_api_client.dart';

// ═══════════════════════════════════════════════════════════════
// Model
// ═══════════════════════════════════════════════════════════════

class ShellScript {
  final String id;
  final String name;
  final String description;
  final String content;
  final String generationSystemPrompt;
  final String generationPrompt;
  final DateTime createdAt;
  final DateTime updatedAt;
  // Per-script SSH override (empty = use global SSH settings)
  final String sshHost;
  final int sshPort;
  final String sshUsername;
  final String sshPassword;
  // Per-script execution timeout (default 120 s)
  final int timeoutSeconds;
  // Run script on local machine (Linux/macOS local mode only).
  final bool runLocally;

  const ShellScript({
    required this.id,
    required this.name,
    required this.description,
    required this.content,
    required this.generationSystemPrompt,
    required this.generationPrompt,
    required this.createdAt,
    required this.updatedAt,
    this.sshHost = '',
    this.sshPort = 22,
    this.sshUsername = '',
    this.sshPassword = '',
    this.timeoutSeconds = 120,
    this.runLocally = false,
  });

  factory ShellScript.create({
    required String name,
    required String description,
    required String content,
    String generationSystemPrompt = '',
    String generationPrompt = '',
    String sshHost = '',
    int sshPort = 22,
    String sshUsername = '',
    String sshPassword = '',
    int timeoutSeconds = 120,
    bool runLocally = false,
  }) {
    final now = DateTime.now();
    return ShellScript(
      id: const Uuid().v4(),
      name: name,
      description: description,
      content: content,
      generationSystemPrompt: generationSystemPrompt,
      generationPrompt: generationPrompt,
      createdAt: now,
      updatedAt: now,
      sshHost: sshHost,
      sshPort: sshPort,
      sshUsername: sshUsername,
      sshPassword: sshPassword,
      timeoutSeconds: timeoutSeconds,
      runLocally: runLocally,
    );
  }

  ShellScript copyWith({
    String? name,
    String? description,
    String? content,
    String? generationSystemPrompt,
    String? generationPrompt,
    String? sshHost,
    int? sshPort,
    String? sshUsername,
    String? sshPassword,
    int? timeoutSeconds,
    bool? runLocally,
  }) {
    return ShellScript(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      content: content ?? this.content,
      generationSystemPrompt: generationSystemPrompt ?? this.generationSystemPrompt,
      generationPrompt: generationPrompt ?? this.generationPrompt,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
      sshHost: sshHost ?? this.sshHost,
      sshPort: sshPort ?? this.sshPort,
      sshUsername: sshUsername ?? this.sshUsername,
      sshPassword: sshPassword ?? this.sshPassword,
      timeoutSeconds: timeoutSeconds ?? this.timeoutSeconds,
      runLocally: runLocally ?? this.runLocally,
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
    if (sshHost.isNotEmpty) 'sshHost': sshHost,
    if (sshPort != 22) 'sshPort': sshPort,
    if (sshUsername.isNotEmpty) 'sshUsername': sshUsername,
    if (sshPassword.isNotEmpty) 'sshPassword': sshPassword,
    if (timeoutSeconds != 120) 'timeoutSeconds': timeoutSeconds,
    if (runLocally) 'runLocally': runLocally,
  };

  factory ShellScript.fromJson(Map<String, dynamic> json) => ShellScript(
    id: json['id'] as String? ?? const Uuid().v4(),
    name: json['name'] as String? ?? '',
    description: json['description'] as String? ?? '',
    content: json['content'] as String? ?? '',
    generationSystemPrompt: json['generationSystemPrompt'] as String? ?? '',
    generationPrompt: json['generationPrompt'] as String? ?? '',
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
    updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? DateTime.now(),
    sshHost: json['sshHost'] as String? ?? '',
    sshPort: json['sshPort'] as int? ?? 22,
    sshUsername: json['sshUsername'] as String? ?? '',
    sshPassword: json['sshPassword'] as String? ?? '',
    timeoutSeconds: json['timeoutSeconds'] as int? ?? 120,
    runLocally: json['runLocally'] as bool? ?? false,
  );
}

// ═══════════════════════════════════════════════════════════════
// Service
// ═══════════════════════════════════════════════════════════════

class ScriptLibraryService {
  ScriptLibraryService._();
  static final ScriptLibraryService instance = ScriptLibraryService._();

  static const _kScripts = 'script_library_scripts';

  List<ShellScript> _scripts = [];

  /// Returns an unmodifiable view of all scripts, sorted by name.
  List<ShellScript> get scripts {
    final sorted = List<ShellScript>.from(_scripts);
    sorted.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return List.unmodifiable(sorted);
  }

  // ── Load ─────────────────────────────────────────────────────

  Future<void> load([ServerApiClient? client]) async {
    if (client != null) {
      try {
        final list = await client.getShellScripts();
        _scripts = list.map(ShellScript.fromJson).toList();
        log.info('[ScriptLibrary] Loaded ${_scripts.length} remote scripts');
      } catch (e) {
        log.error('[ScriptLibrary] Failed to load remote scripts: $e');
      }
      return;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kScripts);
      if (raw == null || raw.isEmpty) return;
      final list = jsonDecode(raw) as List<dynamic>;
      _scripts = list.whereType<Map<String, dynamic>>().map(ShellScript.fromJson).toList();
      log.info('[ScriptLibrary] Loaded ${_scripts.length} scripts');
    } catch (e) {
      log.error('[ScriptLibrary] Failed to load: $e');
    }
  }

  // ── Persist ───────────────────────────────────────────────────

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kScripts, jsonEncode(_scripts.map((s) => s.toJson()).toList()));
  }

  // ── CRUD ──────────────────────────────────────────────────────

  Future<ShellScript> addScript({
    required String name,
    required String description,
    required String content,
    String generationSystemPrompt = '',
    String generationPrompt = '',
    String sshHost = '',
    int sshPort = 22,
    String sshUsername = '',
    String sshPassword = '',
    int timeoutSeconds = 120,
    bool runLocally = false,
    ServerApiClient? client,
  }) async {
    final script = ShellScript.create(
      name: name,
      description: description,
      content: content,
      generationSystemPrompt: generationSystemPrompt,
      generationPrompt: generationPrompt,
      sshHost: sshHost,
      sshPort: sshPort,
      sshUsername: sshUsername,
      sshPassword: sshPassword,
      timeoutSeconds: timeoutSeconds,
      runLocally: runLocally,
    );
    _scripts.add(script);
    if (client != null) {
      try {
        await client.syncShellScripts(exportToJson());
        log.info('[ScriptLibrary] Remotely added script: ${script.name}');
      } catch (e) {
        log.error('[ScriptLibrary] Failed to sync remote script add: $e');
      }
    } else {
      await _persist();
    }
    log.info('[ScriptLibrary] Added script: ${script.name} (${script.id})');
    return script;
  }

  /// Replaces the script with the same id.
  Future<void> updateScript(ShellScript updated, [ServerApiClient? client]) async {
    final idx = _scripts.indexWhere((s) => s.id == updated.id);
    if (idx < 0) {
      log.warning('[ScriptLibrary] updateScript – id not found: ${updated.id}');
      return;
    }
    _scripts[idx] = updated;
    if (client != null) {
      try {
        await client.syncShellScripts(exportToJson());
        log.info('[ScriptLibrary] Remotely updated script: ${updated.name}');
      } catch (e) {
        log.error('[ScriptLibrary] Failed to sync remote script update: $e');
      }
    } else {
      await _persist();
    }
    log.info('[ScriptLibrary] Updated script: ${updated.name}');
  }

  Future<void> deleteScript(String id, [ServerApiClient? client]) async {
    _scripts.removeWhere((s) => s.id == id);
    if (client != null) {
      try {
        await client.syncShellScripts(exportToJson());
        log.info('[ScriptLibrary] Remotely deleted script: $id');
      } catch (e) {
        log.error('[ScriptLibrary] Failed to sync remote script deletion: $e');
      }
    } else {
      await _persist();
    }
    log.info('[ScriptLibrary] Deleted script: $id');
  }

  ShellScript? findById(String id) {
    try {
      return _scripts.firstWhere((s) => s.id == id);
    } catch (_) {
      return null;
    }
  }

  // ── Backup helpers ────────────────────────────────────────────

  /// Returns all scripts serialised as a JSON-safe list (for export).
  List<Map<String, dynamic>> exportToJson() => _scripts.map((s) => s.toJson()).toList();

  /// Import scripts from a parsed JSON list.  Skips duplicates (same id).
  /// Returns the number of newly imported scripts.
  Future<int> importFromJson(List<dynamic> list) async {
    int count = 0;
    for (final item in list) {
      if (item is! Map<String, dynamic>) continue;
      try {
        final script = ShellScript.fromJson(item);
        final idx = _scripts.indexWhere((s) => s.id == script.id || s.name == script.name);
        if (idx >= 0) {
          _scripts[idx] = script;
        } else {
          _scripts.add(script);
        }
        count++;
      } catch (e) {
        log.warning('[ScriptLibrary] Skipped script during import: $e');
      }
    }
    if (count > 0) await _persist();
    log.info('[ScriptLibrary] Imported $count scripts');
    return count;
  }
}
