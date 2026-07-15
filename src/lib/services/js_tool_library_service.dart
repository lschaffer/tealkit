import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'app_logger.dart';
import 'server_api_client.dart';

class JsToolDefinition {
  final String id;
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
  final String jsCode;
  final String generationSystemPrompt;
  final String generationPrompt;
  final String testArgs;
  final bool isActive;
  final String cron;
  final String cronHint;
  final DateTime createdAt;
  final DateTime updatedAt;

  const JsToolDefinition({
    required this.id,
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.jsCode,
    required this.generationSystemPrompt,
    required this.generationPrompt,
    this.testArgs = '',
    required this.isActive,
    this.cron = '',
    this.cronHint = '',
    required this.createdAt,
    required this.updatedAt,
  });

  factory JsToolDefinition.create({
    required String name,
    required String description,
    required Map<String, dynamic> inputSchema,
    required String jsCode,
    String generationSystemPrompt = '',
    String generationPrompt = '',
    String testArgs = '',
    bool isActive = true,
    String cron = '',
    String cronHint = '',
  }) {
    final now = DateTime.now();
    return JsToolDefinition(
      id: const Uuid().v4(),
      name: name,
      description: description,
      inputSchema: Map<String, dynamic>.from(inputSchema),
      jsCode: jsCode,
      generationSystemPrompt: generationSystemPrompt,
      generationPrompt: generationPrompt,
      testArgs: testArgs,
      isActive: isActive,
      cron: cron,
      cronHint: cronHint,
      createdAt: now,
      updatedAt: now,
    );
  }

  JsToolDefinition copyWith({
    String? name,
    String? description,
    Map<String, dynamic>? inputSchema,
    String? jsCode,
    String? generationSystemPrompt,
    String? generationPrompt,
    String? testArgs,
    bool? isActive,
    String? cron,
    String? cronHint,
  }) {
    return JsToolDefinition(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      inputSchema: inputSchema ?? this.inputSchema,
      jsCode: jsCode ?? this.jsCode,
      generationSystemPrompt: generationSystemPrompt ?? this.generationSystemPrompt,
      generationPrompt: generationPrompt ?? this.generationPrompt,
      testArgs: testArgs ?? this.testArgs,
      isActive: isActive ?? this.isActive,
      cron: cron ?? this.cron,
      cronHint: cronHint ?? this.cronHint,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'inputSchema': inputSchema,
    'jsCode': jsCode,
    'generationSystemPrompt': generationSystemPrompt,
    'generationPrompt': generationPrompt,
    'testArgs': testArgs,
    'isActive': isActive,
    'cron': cron,
    'cronHint': cronHint,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory JsToolDefinition.fromJson(Map<String, dynamic> json) {
    final rawSchema = json['inputSchema'];
    final schema = rawSchema is Map ? rawSchema.cast<String, dynamic>() : <String, dynamic>{'type': 'object', 'properties': {}};
    return JsToolDefinition(
      id: json['id'] as String? ?? const Uuid().v4(),
      name: json['name'] as String? ?? 'unnamed_tool',
      description: json['description'] as String? ?? '',
      inputSchema: schema,
      jsCode: json['jsCode'] as String? ?? '',
      generationSystemPrompt: json['generationSystemPrompt'] as String? ?? '',
      generationPrompt: json['generationPrompt'] as String? ?? '',
      testArgs: json['testArgs'] as String? ?? '',
      isActive: json['isActive'] as bool? ?? true,
      cron: json['cron'] as String? ?? '',
      cronHint: json['cronHint'] as String? ?? '',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? DateTime.now(),
    );
  }
}

class JsToolLibraryService {
  JsToolLibraryService._();
  static final JsToolLibraryService instance = JsToolLibraryService._();

  static const _kTools = 'js_tool_library_tools';
  List<JsToolDefinition> _tools = [];

  List<JsToolDefinition> get tools {
    final sorted = List<JsToolDefinition>.from(_tools);
    sorted.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return List.unmodifiable(sorted);
  }

  List<JsToolDefinition> get activeTools => tools.where((t) => t.isActive).toList();

  Future<void> load([ServerApiClient? client]) async {
    if (client != null) {
      try {
        final list = await client.getJsTools();
        _tools = list.map(JsToolDefinition.fromJson).toList();
        log.info('[JsToolLibrary] Loaded ${_tools.length} remote tools');
      } catch (e) {
        log.error('[JsToolLibrary] Failed to load remote tools: $e');
      }
      return;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kTools);
      if (raw == null || raw.isEmpty) return;
      final list = jsonDecode(raw) as List<dynamic>;
      _tools = list.whereType<Map<String, dynamic>>().map(JsToolDefinition.fromJson).toList();
      log.info('[JsToolLibrary] Loaded ${_tools.length} tools');
    } catch (e) {
      log.error('[JsToolLibrary] Failed to load: $e');
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kTools, jsonEncode(_tools.map((t) => t.toJson()).toList()));
  }

  Future<JsToolDefinition> addTool({
    required String name,
    required String description,
    required Map<String, dynamic> inputSchema,
    required String jsCode,
    String generationSystemPrompt = '',
    String generationPrompt = '',
    String testArgs = '',
    bool isActive = true,
    String cron = '',
    String cronHint = '',
    ServerApiClient? client,
  }) async {
    final tool = JsToolDefinition.create(
      name: name,
      description: description,
      inputSchema: inputSchema,
      jsCode: jsCode,
      generationSystemPrompt: generationSystemPrompt,
      generationPrompt: generationPrompt,
      testArgs: testArgs,
      isActive: isActive,
      cron: cron,
      cronHint: cronHint,
    );
    _tools.add(tool);
    if (client != null) {
      try {
        await client.syncJsTools(exportToJson());
        log.info('[JsToolLibrary] Remotely added/synced tool: ${tool.name}');
      } catch (e) {
        log.error('[JsToolLibrary] Failed to sync remote js_tool add: $e');
      }
    } else {
      await _persist();
    }
    log.info('[JsToolLibrary] Added tool: ${tool.name} (${tool.id})');
    return tool;
  }

  Future<void> updateTool(JsToolDefinition updated, [ServerApiClient? client]) async {
    final index = _tools.indexWhere((t) => t.id == updated.id);
    if (index < 0) return;
    _tools[index] = updated;
    if (client != null) {
      try {
        await client.syncJsTools(exportToJson());
        log.info('[JsToolLibrary] Remotely updated/synced tool: ${updated.name}');
      } catch (e) {
        log.error('[JsToolLibrary] Failed to sync remote js_tool update: $e');
      }
    } else {
      await _persist();
    }
    log.info('[JsToolLibrary] Updated tool: ${updated.name}');
  }

  Future<void> deleteTool(String id, [ServerApiClient? client]) async {
    _tools.removeWhere((t) => t.id == id);
    if (client != null) {
      try {
        await client.syncJsTools(exportToJson());
        log.info('[JsToolLibrary] Remotely deleted/synced tool: $id');
      } catch (e) {
        log.error('[JsToolLibrary] Failed to sync remote js_tool delete: $e');
      }
    } else {
      await _persist();
    }
    log.info('[JsToolLibrary] Deleted tool: $id');
  }

  JsToolDefinition? findById(String id) {
    try {
      return _tools.firstWhere((t) => t.id == id);
    } catch (_) {
      return null;
    }
  }

  JsToolDefinition? findByName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    final exact = _tools.where((t) => t.name == trimmed).toList();
    if (exact.isNotEmpty) return exact.first;
    final lower = trimmed.toLowerCase();
    final ci = _tools.where((t) => t.name.toLowerCase() == lower).toList();
    return ci.isNotEmpty ? ci.first : null;
  }

  List<Map<String, dynamic>> exportToJson() => _tools.map((t) => t.toJson()).toList();

  Future<int> importFromJson(List<dynamic> list) async {
    int count = 0;
    for (final item in list) {
      if (item is! Map<String, dynamic>) continue;
      try {
        final tool = JsToolDefinition.fromJson(item);
        final idx = _tools.indexWhere((existing) => existing.id == tool.id || existing.name == tool.name);
        if (idx >= 0) {
          _tools[idx] = tool;
        } else {
          _tools.add(tool);
        }
        count++;
      } catch (e) {
        log.warning('[JsToolLibrary] Skipped tool during import: $e');
      }
    }
    if (count > 0) await _persist();
    log.info('[JsToolLibrary] Imported $count tools');
    return count;
  }
}
