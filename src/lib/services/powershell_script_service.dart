import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'app_logger.dart';

// ═══════════════════════════════════════════════════════════════
// Model
// ═══════════════════════════════════════════════════════════════

class PowershellScript {
  final String id;
  final String name;
  final String description;
  final String content;
  final String generationSystemPrompt;
  final String generationPrompt;
  final DateTime createdAt;
  final DateTime updatedAt;

  const PowershellScript({
    required this.id,
    required this.name,
    required this.description,
    required this.content,
    required this.generationSystemPrompt,
    required this.generationPrompt,
    required this.createdAt,
    required this.updatedAt,
  });

  factory PowershellScript.create({
    required String name,
    required String description,
    required String content,
    String generationSystemPrompt = '',
    String generationPrompt = '',
  }) {
    final now = DateTime.now();
    return PowershellScript(
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

  PowershellScript copyWith({
    String? name,
    String? description,
    String? content,
    String? generationSystemPrompt,
    String? generationPrompt,
  }) {
    return PowershellScript(
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

  factory PowershellScript.fromJson(Map<String, dynamic> json) => PowershellScript(
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

class PowershellScriptService {
  PowershellScriptService._();
  static final PowershellScriptService instance = PowershellScriptService._();

  static const _kScripts = 'powershell_script_library_scripts';

  List<PowershellScript> _scripts = [];

  List<PowershellScript> get scripts {
    final sorted = List<PowershellScript>.from(_scripts);
    sorted.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return List.unmodifiable(sorted);
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kScripts);
      if (raw == null || raw.isEmpty) return;
      final list = jsonDecode(raw) as List<dynamic>;
      _scripts = list.whereType<Map<String, dynamic>>().map(PowershellScript.fromJson).toList();
      log.info('[PowershellScriptLibrary] Loaded ${_scripts.length} scripts');
    } catch (e) {
      log.error('[PowershellScriptLibrary] Failed to load: $e');
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kScripts, jsonEncode(_scripts.map((s) => s.toJson()).toList()));
  }

  Future<PowershellScript> addScript({
    required String name,
    required String description,
    required String content,
    String generationSystemPrompt = '',
    String generationPrompt = '',
  }) async {
    final script = PowershellScript.create(
      name: name,
      description: description,
      content: content,
      generationSystemPrompt: generationSystemPrompt,
      generationPrompt: generationPrompt,
    );
    _scripts.add(script);
    await _persist();
    log.info('[PowershellScriptLibrary] Added: ${script.name}');
    return script;
  }

  Future<void> updateScript(PowershellScript updated) async {
    final idx = _scripts.indexWhere((s) => s.id == updated.id);
    if (idx < 0) {
      log.warning('[PowershellScriptLibrary] updateScript – id not found: ${updated.id}');
      return;
    }
    _scripts[idx] = updated;
    await _persist();
    log.info('[PowershellScriptLibrary] Updated: ${updated.name}');
  }

  Future<void> deleteScript(String id) async {
    _scripts.removeWhere((s) => s.id == id);
    await _persist();
    log.info('[PowershellScriptLibrary] Deleted: $id');
  }

  PowershellScript? findById(String id) {
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
        final script = PowershellScript.fromJson(item);
        final idx = _scripts.indexWhere((s) => s.id == script.id || s.name == script.name);
        if (idx >= 0) {
          _scripts[idx] = script;
        } else {
          _scripts.add(script);
        }
        count++;
      } catch (e) {
        log.warning('[PowershellScriptLibrary] Skipped during import: $e');
      }
    }
    if (count > 0) await _persist();
    return count;
  }
}
